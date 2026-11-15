/* Publishes the numeric kernels through Godot's PackedFloat64Array ABI. */
#include <limits.h>
#include <string.h>
#include "gdextension_interface.h"
#include "kernels.h"

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
typedef void (*Runner)(double *);

static void step_into(GDExtensionConstTypePtr in, GDExtensionUninitializedTypePtr out, Runner fn, int min_len) {
	const GDExtensionConstTypePtr args[1] = { in };
	pf64_copy(out, args);
	const double *src = pf64_idx_c(in, 0);
	if (!src || !(src[0] >= min_len && src[0] <= INT_MAX)) return;
	int len = (int)src[0];
	if (src[0] != len || !pf64_idx_c(in, len - 1)) return;
	/* Writing through `out` detaches its storage from the caller's, so the kernel runs on
	 * the copy in place. */
	double *dst = pf64_idx((GDExtensionTypePtr)out, 0);
	if (dst) fn(dst);
}

/* The library's own libm on probe arguments, for galaxycheck: the tracer kernel can be
 * bit-identical to GDScript only where both call the same libm (MinGW's differs from
 * the engine's on Windows). Records of (function, a, b, result) after A[0] = length:
 * 0 sin, 1 cos, 2 tan, 3 exp, 4 log, 5 atan2(a, b), 6 tanh, 7 pow(a, b), 8 sqrt. */
static void run_libm(double *A) {
	int len = (int)A[0];
	for (int i = 1; i + 3 < len; i += 4) {
		double a = A[i + 1], b = A[i + 2], r;
		switch ((int)A[i]) {
		case 0: r = sin(a); break;
		case 1: r = cos(a); break;
		case 2: r = tan(a); break;
		case 3: r = exp(a); break;
		case 4: r = log(a); break;
		case 5: r = atan2(a, b); break;
		case 6: r = tanh(a); break;
		case 7: r = pow(a, b); break;
		case 8: r = sqrt(a); break;
		default: r = 0.0; break;
		}
		A[i + 3] = r;
	}
}

static int tracer_tag = 1;
static int libm_tag = 2;
static int encounter_tag = 3;
static int live_tag = 4;
static int flight_zonal_tag = 5;
static int eddington_tag = 6;

/* Method userdata selects the kernel. NULL is step2. */
static void dispatch(void *ud, GDExtensionConstTypePtr in, GDExtensionUninitializedTypePtr out) {
	if (ud == &tracer_tag) step_into(in, out, astrarium_galaxy_tracers, TR_PAT);
	else if (ud == &libm_tag) step_into(in, out, run_libm, 5);
	else if (ud == &encounter_tag) step_into(in, out, astrarium_galaxy_encounter, EN_HDR);
	else if (ud == &live_tag) step_into(in, out, astrarium_galaxy_live, LV_HDR);
	else if (ud == &eddington_tag) step_into(in, out, astrarium_galaxy_eddington, EDD_HDR);
	else if (ud == &flight_zonal_tag) {
		if (pf64_idx_c(in, FZ_SIZE - 1)) step_into(in, out, astrarium_flight_zonal, FZ_SIZE);
		else { const GDExtensionConstTypePtr args[1] = { in }; pf64_copy(out, args); }
	}
	else step_into(in, out, astrarium_nbody, NB_HDR);
}

static void m_ptrcall(void *ud, GDExtensionClassInstancePtr inst, const GDExtensionConstTypePtr *args, GDExtensionTypePtr r_ret) {
	(void)inst;
	/* r_ret holds a constructed (empty) array: release it, then build in place. */
	pf64_dtor(r_ret);
	dispatch(ud, args[0], r_ret);
}

static void m_call(void *ud, GDExtensionClassInstancePtr inst, const GDExtensionConstVariantPtr *args, GDExtensionInt argc, GDExtensionVariantPtr r_ret, GDExtensionCallError *err) {
	(void)inst;
	if (argc < 1) { err->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS; err->expected = 1; return; }
	PF64 in, out;
	pf64_from_variant(&in, (GDExtensionVariantPtr)args[0]);
	dispatch(ud, &in, &out);
	variant_from_pf64(r_ret, &out);
	pf64_dtor(&in);
	pf64_dtor(&out);
	err->error = GDEXTENSION_CALL_OK;
}

static void free_instance(void *ud, GDExtensionClassInstancePtr inst) { (void)ud; (void)inst; }

static SName sn_class, sn_parent, sn_method, sn_tracers, sn_libm, sn_encounter, sn_live, sn_flight_zonal, sn_eddington, sn_arg, sn_empty;

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
	sn_new(&sn_method, "step2", 1);
	sn_new(&sn_tracers, "tracers", 1);
	sn_new(&sn_libm, "libm", 1);
	sn_new(&sn_encounter, "encounter", 1);
	sn_new(&sn_live, "live", 1);
	sn_new(&sn_flight_zonal, "flight_zonal", 1);
	sn_new(&sn_eddington, "galaxy_eddington", 1);
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
	mi.name = &sn_tracers;
	mi.method_userdata = &tracer_tag;
	reg_method(lib, &sn_class, &mi);
	mi.name = &sn_libm;
	mi.method_userdata = &libm_tag;
	reg_method(lib, &sn_class, &mi);
	mi.name = &sn_encounter;
	mi.method_userdata = &encounter_tag;
	reg_method(lib, &sn_class, &mi);
	mi.name = &sn_live;
	mi.method_userdata = &live_tag;
	reg_method(lib, &sn_class, &mi);
	mi.name = &sn_flight_zonal;
	mi.method_userdata = &flight_zonal_tag;
	reg_method(lib, &sn_class, &mi);
	mi.name = &sn_eddington;
	mi.method_userdata = &eddington_tag;
	reg_method(lib, &sn_class, &mi);
}

static void deinitialize(void *ud, GDExtensionInitializationLevel level) { (void)ud; (void)level; }

#ifdef _WIN32
__declspec(dllexport)
#else
__attribute__((visibility("default")))
#endif
GDExtensionBool astrarium_native_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_init) {
	gp = p_get_proc_address;
	lib = p_library;
	r_init->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_init->userdata = NULL;
	r_init->initialize = initialize;
	r_init->deinitialize = deinitialize;
	return 1;
}
