/* ASTRARIUM NATIVE: the N-body sub-step loop in C.
 *
 * GDScript runs the O(N²) pair loops 24–125× slower than V8 did (the `solar`
 * preset cost 33.5 ms of physics a frame), so this one hot loop (dynamic step,
 * velocity-Verlet, GW back-reaction, collision test) runs natively. It is
 * sim/physics.gd + sim/derive.gd line for line; those stay the reference and the
 * fallback, and sim/nbody.gd uses whichever is present.
 *
 * Plain C against the raw GDExtension interface: one static method, one `cc`
 * line (build.sh), no godot-cpp.
 *
 * ARITHMETIC PARITY. Expressions keep the reference's evaluation order, compiled
 * with -ffp-contract=off (no fused a·b + c), pow() where the reference used it,
 * so runs take the same sub-steps and agree to rounding (tools/nbodycheck.gd).
 *
 * THE CONTRACT (sim/nbody.gd builds and reads it):
 *   step(state: PackedFloat64Array) -> PackedFloat64Array (same layout)
 *   header  [0] length   [1] n bodies   [2] remaining sim dt (yr, in/out)
 *           [3] max step [4] gw boost   [5] guard (sub-steps so far, in/out)
 *           [6] stepped (out)           [7] merger events (out)
 *   body k at HDR + k·STRIDE:
 *           px py pz vx vy vz mass rs is_bh softening radius contact_au
 *           emits_gw alive (then 2 spare)
 *   events at HDR + n·STRIDE: (survivor k, absorbed k, separation) × up to n
 * It integrates until the time is used up, the 8000-step guard trips, or a
 * sub-step produced a merger, then returns so the orchestrator can run
 * handle_merger (which changes horizons and types and removes bodies) and call
 * again with what remains. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "gdextension_interface.h"

#define HDR 8
#define STRIDE 16
#define STEP_GUARD 8000

enum { PX, PY, PZ, VX, VY, VZ, MASS, RS, ISBH, SOFT, RADIUS, CONTACT, EMITSGW, ALIVE };

static const double G = 4.0 * 3.141592653589793 * 3.141592653589793;   /* 4π², as (4·π)·π */
static const double C_LIGHT = 63241.077;

/* NaN-propagating min/max (fmin/fmax would drop NaN). */
static double jmin(double a, double b) { if (isnan(a) || isnan(b)) return NAN; return a < b ? a : b; }
static double jmax(double a, double b) { if (isnan(a) || isnan(b)) return NAN; return a > b ? a : b; }
/* `a || b` over numbers: 0 and NaN are falsy. */
static double jor(double a, double b) { return (a != 0.0 && !isnan(a)) ? a : b; }

typedef struct { double ax, ay, az, px, py, pz; } Scratch;

/* |acceleration| imparted by body s at separation dist (Physics._pull_mag). */
static double pull_mag(const double *s, double dist) {
	double GM = G * s[MASS];
	if (s[ISBH] != 0.0) {
		double denom = jmax(dist - s[RS], s[RS] * 0.05);
		return GM / (denom * denom);
	}
	/* Legacy extended-source field for pairs involving a black hole. */
	double soft = jor(s[SOFT], s[RADIUS] * 0.5 + 1e-4);
	double d2 = dist * dist + soft * soft;
	return GM / d2;
}

static void compute_accel(double *B, int n, Scratch *S) {
	for (int k = 0; k < n; k++) { S[k].ax = 0.0; S[k].ay = 0.0; S[k].az = 0.0; }
	for (int i = 0; i < n; i++) {
		double *a = B + i * STRIDE;
		if (a[ALIVE] == 0.0) continue;
		for (int j = i + 1; j < n; j++) {
			double *b = B + j * STRIDE;
			if (b[ALIVE] == 0.0) continue;
			double rx = b[PX] - a[PX], ry = b[PY] - a[PY], rz = b[PZ] - a[PZ];
			double dist = sqrt(rx * rx + ry * ry + rz * rz);
			if (dist < 1e-9) continue;
			double inv = 1.0 / dist;
			rx *= inv; ry *= inv; rz *= inv;          /* unit vector a→b */
			double fA, fB;
			if (a[ISBH] != 0.0 || b[ISBH] != 0.0) {
				fA = pull_mag(b, dist);
				fB = pull_mag(a, dist);
			} else {
				double sa = jor(a[SOFT], a[RADIUS] * 0.5 + 1e-4);
				double sb = jor(b[SOFT], b[RADIUS] * 0.5 + 1e-4);
				double d2 = dist * dist + 0.5 * (sa * sa + sb * sb);
				double kernel = G * dist / (d2 * sqrt(d2));
				fA = kernel * b[MASS];
				fB = kernel * a[MASS];
			}
			S[i].ax += rx * fA; S[i].ay += ry * fA; S[i].az += rz * fA;
			S[j].ax += rx * -fB; S[j].ay += ry * -fB; S[j].az += rz * -fB;
		}
	}
}

/* Smallest resolved-needs timescale among bodies (Derive.dynamic_step). */
static double dynamic_step(const double *B, int n, double max_step) {
	double t_min = max_step;
	for (int i = 0; i < n; i++) {
		const double *a = B + i * STRIDE;
		if (a[ALIVE] == 0.0) continue;
		for (int j = i + 1; j < n; j++) {
			const double *b = B + j * STRIDE;
			if (b[ALIVE] == 0.0) continue;
			double dx = a[PX] - b[PX], dy = a[PY] - b[PY], dz = a[PZ] - b[PZ];
			double sep = sqrt(dx * dx + dy * dy + dz * dz);
			double mu = G * (a[MASS] + b[MASS]);
			double t_fall = sqrt((sep * sep * sep) / jmax(mu, 1e-9));     /* free-fall time */
			double ux = a[VX] - b[VX], uy = a[VY] - b[VY], uz = a[VZ] - b[VZ];
			double vrel = sqrt(ux * ux + uy * uy + uz * uz);
			double t_fly = sep / jmax(vrel, 1e-6);                         /* crossing time */
			t_min = jmin(t_min, jmin(0.05 * t_fall, 0.08 * t_fly));
		}
	}
	return jmax(t_min, 1e-8);
}

/* One velocity-Verlet step, in the reference's rounding order. */
static void integrate(double *B, int n, double dt, Scratch *S) {
	compute_accel(B, n, S);
	double h2 = 0.5 * dt * dt;
	for (int k = 0; k < n; k++) {
		double *b = B + k * STRIDE;
		if (b[ALIVE] == 0.0) continue;
		b[PX] += b[VX] * dt; b[PY] += b[VY] * dt; b[PZ] += b[VZ] * dt;
		b[PX] += S[k].ax * h2; b[PY] += S[k].ay * h2; b[PZ] += S[k].az * h2;
		S[k].px = S[k].ax; S[k].py = S[k].ay; S[k].pz = S[k].az;
	}
	compute_accel(B, n, S);
	double hd = 0.5 * dt;
	for (int k = 0; k < n; k++) {
		double *b = B + k * STRIDE;
		if (b[ALIVE] == 0.0) continue;
		b[VX] += (S[k].px + S[k].ax) * hd;
		b[VY] += (S[k].py + S[k].ay) * hd;
		b[VZ] += (S[k].pz + S[k].az) * hd;
	}
}

/* 2.5-PN radiation reaction as a drag (Physics GW reaction). */
static void apply_gw(double *B, int n, double dt, double boost) {
	static double G4 = 0.0, C5 = 0.0;
	if (G4 == 0.0) { G4 = pow(G, 4.0); C5 = pow(C_LIGHT, 5.0); }
	for (int i = 0; i < n; i++) {
		double *a = B + i * STRIDE;
		if (a[ALIVE] == 0.0 || a[EMITSGW] == 0.0) continue;
		for (int j = i + 1; j < n; j++) {
			double *b = B + j * STRIDE;
			if (b[ALIVE] == 0.0 || b[EMITSGW] == 0.0) continue;
			double rx = b[PX] - a[PX], ry = b[PY] - a[PY], rz = b[PZ] - a[PZ];
			double r = sqrt(rx * rx + ry * ry + rz * rz);
			double cSum = jor(jor(a[CONTACT], a[RADIUS]), a[RS]) + jor(jor(b[CONTACT], b[RADIUS]), b[RS]);
			if (r > 400.0 * cSum || r < cSum * 0.5) continue;
			double vx = b[VX] - a[VX], vy = b[VY] - a[VY], vz = b[VZ] - a[VZ];
			double m1 = a[MASS], m2 = b[MASS], M = m1 + m2, mu = m1 * m2 / M;
			double dEdt = (32.0 / 5.0) * G4 * m1 * m1 * m2 * m2 * M / (C5 * pow(r, 5.0)) * boost;
			double vrelMag = jmax(sqrt(vx * vx + vy * vy + vz * vz), 1e-6);
			double dragAcc = dEdt / (mu * vrelMag);
			double maxKick = 0.0025 * vrelMag;
			if (dragAcc * dt > maxKick) dragAcc = maxKick / dt;
			double s = 1.0 / vrelMag;
			vx *= s; vy *= s; vz *= s;
			double ka = dragAcc * (mu / m1) * dt;
			double kb = -dragAcc * (mu / m2) * dt;
			a[VX] += vx * ka; a[VY] += vy * ka; a[VZ] += vz * ka;
			b[VX] += vx * kb; b[VY] += vy * kb; b[VZ] += vz * kb;
		}
	}
}

/* Collision / accretion resolution (Physics collisions). */
static int resolve_collisions(double *B, int n, double *ev) {
	int count = 0;
	for (int i = 0; i < n; i++) {
		double *a = B + i * STRIDE;
		if (a[ALIVE] == 0.0) continue;
		for (int j = i + 1; j < n; j++) {
			double *b = B + j * STRIDE;
			if (b[ALIVE] == 0.0) continue;
			double dx = b[PX] - a[PX], dy = b[PY] - a[PY], dz = b[PZ] - a[PZ];
			double d = sqrt(dx * dx + dy * dy + dz * dz);
			double ca = a[ISBH] != 0.0 ? a[RS] : jor(a[CONTACT], a[RADIUS]);
			double cb = b[ISBH] != 0.0 ? b[RS] : jor(b[CONTACT], b[RADIUS]);
			if (d > ca + cb) continue;
			int big = a[MASS] >= b[MASS] ? i : j;
			int small = big == i ? j : i;
			double *g = B + big * STRIDE, *s = B + small * STRIDE;
			double M = g[MASS] + s[MASS];
			double invM = 1.0 / M;
			for (int c = 0; c < 3; c++) {
				g[VX + c] = (g[VX + c] * g[MASS] + s[VX + c] * s[MASS]) * invM;
				g[PX + c] = (g[PX + c] * g[MASS] + s[PX + c] * s[MASS]) * invM;
			}
			g[MASS] = M;
			s[ALIVE] = 0.0;
			if (count < n) {
				ev[count * 3 + 0] = (double)big;
				ev[count * 3 + 1] = (double)small;
				ev[count * 3 + 2] = d;
			}
			count++;
			if (a[ALIVE] == 0.0) break;
		}
	}
	return count;
}

static void run(double *A) {
	int n = (int)A[1];
	double remaining = A[2], max_step = A[3], gw = A[4];
	int guard = (int)A[5];
	double stepped = 0.0;
	int events = 0;
	double *B = A + HDR;
	double *ev = A + HDR + n * STRIDE;
	Scratch *S = (Scratch *)calloc((size_t)(n > 0 ? n : 1), sizeof(Scratch));
	while (remaining > 1e-12 && guard < STEP_GUARD) {
		guard++;
		double h = jmin(remaining, dynamic_step(B, n, max_step));
		integrate(B, n, h, S);
		if (gw != 0.0) apply_gw(B, n, h, gw);
		events = resolve_collisions(B, n, ev);
		remaining -= h;
		stepped += h;
		if (events > 0) break;
	}
	free(S);
	A[2] = remaining; A[5] = (double)guard; A[6] = stepped; A[7] = (double)events;
}

/* ============================================================================
 * GDExtension plumbing — one abstract class with one static method.
 * ========================================================================== */
static GDExtensionInterfaceGetProcAddress gp;
static GDExtensionClassLibraryPtr lib;
static GDExtensionPtrConstructor pf64_copy;
static GDExtensionPtrDestructor pf64_dtor;
static GDExtensionInterfacePackedFloat64ArrayOperatorIndex pf64_idx;
static GDExtensionInterfacePackedFloat64ArrayOperatorIndexConst pf64_idx_c;
static GDExtensionVariantFromTypeConstructorFunc variant_from_pf64;
static GDExtensionTypeFromVariantConstructorFunc pf64_from_variant;

/* Opaque storage for engine objects whose size the API dump states. */
typedef struct { _Alignas(8) unsigned char b[16]; } PF64;
typedef struct { _Alignas(8) unsigned char b[8]; } SName;

/* Copy `in` into `out` (constructed here), run, write back through the
 * copy-on-write accessor so the caller's array is untouched. */
static void step_into(GDExtensionConstTypePtr in, GDExtensionUninitializedTypePtr out) {
	const GDExtensionConstTypePtr args[1] = { in };
	pf64_copy(out, args);
	const double *src = pf64_idx_c(in, 0);
	if (!src) return;
	int len = (int)src[0];
	if (len < HDR) return;
	double *buf = (double *)malloc(sizeof(double) * (size_t)len);
	for (int i = 0; i < len; i++) buf[i] = *pf64_idx_c(in, i);
	run(buf);
	double *dst = pf64_idx((GDExtensionTypePtr)out, 0);
	if (dst) memcpy(dst, buf, sizeof(double) * (size_t)len);
	free(buf);
}

static void m_ptrcall(void *ud, GDExtensionClassInstancePtr inst, const GDExtensionConstTypePtr *args, GDExtensionTypePtr r_ret) {
	(void)ud; (void)inst;
	/* r_ret holds a constructed (empty) array: release it, then build in place. */
	pf64_dtor(r_ret);
	step_into(args[0], r_ret);
}

static void m_call(void *ud, GDExtensionClassInstancePtr inst, const GDExtensionConstVariantPtr *args, GDExtensionInt argc, GDExtensionVariantPtr r_ret, GDExtensionCallError *err) {
	(void)ud; (void)inst;
	if (argc < 1) { err->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; err->expected = 1; return; }
	PF64 in, out;
	pf64_from_variant(&in, (GDExtensionVariantPtr)args[0]);
	step_into(&in, &out);
	variant_from_pf64(r_ret, &out);
	pf64_dtor(&in);
	pf64_dtor(&out);
	err->error = GDEXTENSION_CALL_OK;
}

static void free_instance(void *ud, GDExtensionClassInstancePtr inst) { (void)ud; (void)inst; }

static SName sn_class, sn_parent, sn_method, sn_arg, sn_empty;

static void initialize(void *ud, GDExtensionInitializationLevel level) {
	(void)ud;
	if (level != GDEXTENSION_INITIALIZATION_SCENE) return;
	GDExtensionInterfaceStringNameNewWithLatin1Chars sn_new = (GDExtensionInterfaceStringNameNewWithLatin1Chars)gp("string_name_new_with_latin1_chars");
	GDExtensionInterfaceVariantGetPtrConstructor get_ctor = (GDExtensionInterfaceVariantGetPtrConstructor)gp("variant_get_ptr_constructor");
	GDExtensionInterfaceVariantGetPtrDestructor get_dtor = (GDExtensionInterfaceVariantGetPtrDestructor)gp("variant_get_ptr_destructor");
	GDExtensionInterfaceGetVariantFromTypeConstructor get_vft = (GDExtensionInterfaceGetVariantFromTypeConstructor)gp("get_variant_from_type_constructor");
	GDExtensionInterfaceGetVariantToTypeConstructor get_vtt = (GDExtensionInterfaceGetVariantToTypeConstructor)gp("get_variant_to_type_constructor");
	GDExtensionInterfaceClassdbRegisterExtensionClass6 reg_class = (GDExtensionInterfaceClassdbRegisterExtensionClass6)gp("classdb_register_extension_class6");
	GDExtensionInterfaceClassdbRegisterExtensionClassMethod reg_method = (GDExtensionInterfaceClassdbRegisterExtensionClassMethod)gp("classdb_register_extension_class_method");
	pf64_idx = (GDExtensionInterfacePackedFloat64ArrayOperatorIndex)gp("packed_float64_array_operator_index");
	pf64_idx_c = (GDExtensionInterfacePackedFloat64ArrayOperatorIndexConst)gp("packed_float64_array_operator_index_const");
	if (!sn_new || !get_ctor || !get_dtor || !get_vft || !get_vtt || !reg_class || !reg_method || !pf64_idx || !pf64_idx_c) return;
	pf64_copy = get_ctor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY, 1);
	pf64_dtor = get_dtor(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY);
	variant_from_pf64 = get_vft(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY);
	pf64_from_variant = get_vtt(GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY);

	sn_new(&sn_class, "NBodyKernel", 1);
	sn_new(&sn_parent, "Object", 1);
	sn_new(&sn_method, "step", 1);
	sn_new(&sn_arg, "state", 1);
	sn_new(&sn_empty, "", 1);

	GDExtensionClassCreationInfo6 ci;
	memset(&ci, 0, sizeof ci);
	ci.is_abstract = 1;
	ci.is_exposed = 1;
	ci.free_instance_func = free_instance;
	reg_class(lib, &sn_class, &sn_parent, &ci);

	/* hint_string is a String; an empty one is a null pointer's worth of data */
	static unsigned char empty_string[8];
	memset(empty_string, 0, sizeof empty_string);
	GDExtensionPropertyInfo ret = { GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY, &sn_empty, &sn_empty, 0, empty_string, 6 };
	GDExtensionPropertyInfo arg = { GDEXTENSION_VARIANT_TYPE_PACKED_FLOAT64_ARRAY, &sn_arg, &sn_empty, 0, empty_string, 6 };
	GDExtensionClassMethodArgumentMetadata meta = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	GDExtensionClassMethodInfo mi;
	memset(&mi, 0, sizeof mi);
	mi.name = &sn_method;
	mi.call_func = m_call;
	mi.ptrcall_func = m_ptrcall;
	mi.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL | GDEXTENSION_METHOD_FLAG_STATIC;
	mi.has_return_value = 1;
	mi.return_value_info = &ret;
	mi.return_value_metadata = meta;
	mi.argument_count = 1;
	mi.arguments_info = &arg;
	mi.arguments_metadata = &meta;
	reg_method(lib, &sn_class, &mi);
}

static void deinitialize(void *ud, GDExtensionInitializationLevel level) { (void)ud; (void)level; }

__attribute__((visibility("default")))
GDExtensionBool astrarium_native_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_init) {
	gp = p_get_proc_address;
	lib = p_library;
	r_init->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_init->userdata = NULL;
	r_init->initialize = initialize;
	r_init->deinitialize = deinitialize;
	return 1;
}
