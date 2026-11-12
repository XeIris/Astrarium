/* Native N-body loop; sim/physics.gd and sim/derive.gd remain the fallback.
 * Preserve arithmetic order and -ffp-contract=off for tools/nbodycheck.gd parity.
 * Buffer contract (sim/nbody.gd builds and reads it):
 *   step(state: PackedFloat64Array) -> PackedFloat64Array (same layout)
 *   header  [0] length   [1] n bodies   [2] remaining sim dt (yr, in/out)
 *           [3] max step [4] gw boost   [5] guard (sub-steps so far, in/out)
 *           [6] accepted call time (in/out)  [7] merger events (out)
 *           [8] resolution limited (out) [9] requested call time (in)
 *           [10] secular evolution on (in) [11] spare
 *   body k at HDR + k·STRIDE:
 *           px py pz vx vy vz mass rs is_bh softening radius contact_au
 *           emits_gw alive post_newtonian, then the secular terms:
 *           wind Ṁ (M☉/yr) k2 time-lag (yr) spin Ω (rad/yr, in/out) I/M (AU²)
 *           donor, mass gained and mass given by Roche-lobe overflow (M☉, out), spare
 *   events at HDR + n·STRIDE: (survivor k, absorbed k, separation) × up to n
 * It integrates until the time is used up, the 8000-step guard trips, or a
 * sub-step produced a merger, then returns so the orchestrator can run
 * handle_merger (which changes horizons and types and removes bodies) and call
 * again with what remains. */
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include <math.h>
#include <float.h>
#include <stdlib.h>
#include <string.h>
#include "gdextension_interface.h"

#define HDR 12
#define STRIDE 24
#define STEP_GUARD 8000

enum { PX, PY, PZ, VX, VY, VZ, MASS, RS, ISBH, SOFT, RADIUS, CONTACT, EMITSGW, ALIVE, PN,
       MDOT, K2, LAG, SPIN, IOM, DONOR, GAINED, SHED };

static const double G = 4.0 * 3.141592653589793 * 3.141592653589793;   /* 4π², as (4·π)·π */
/* Rocketry.C_MS · Rocketry.YR_S / Rocketry.AU_M, in the same order as Physics.C. */
static const double C_LIGHT = 299792458.0 * 31558196.01824108 / 1.495978707e11;

/* NaN-propagating min/max (fmin/fmax would drop NaN). */
static double jmin(double a, double b) { if (isnan(a) || isnan(b)) return NAN; return a < b ? a : b; }
static double jmax(double a, double b) { if (isnan(a) || isnan(b)) return NAN; return a > b ? a : b; }
/* `a || b` over numbers: 0 and NaN are falsy. */
static double jor(double a, double b) { return (a != 0.0 && !isnan(a)) ? a : b; }

typedef struct { double ax, ay, az, px, py, pz, old_pos[3], old_vel[3], w[3]; } Scratch;

static double distance_xyz(double x, double y, double z) {
	double squared = x * x + y * y + z * z;
	if (isfinite(squared) && squared >= DBL_MIN) return sqrt(squared);
	double scale = jmax(fabs(x), jmax(fabs(y), fabs(z)));
	if (scale == 0.0 || !isfinite(scale)) return scale;
	x /= scale; y /= scale; z /= scale;
	return scale * sqrt(x * x + y * y + z * z);
}

static double scaled_acceleration(double mass, double dist, double softened) {
	double factors[] = {G, mass, dist, softened, softened, softened};
	double mantissa = 1.0;
	int exponent = 0;
	for (int i = 0; i < 6; i++) {
		if (!isfinite(factors[i]) || factors[i] <= 0.0) return NAN;
		int shift;
		double value = frexp(factors[i], &shift) * 2.0;
		shift--;
		if (i < 3) { mantissa *= value; exponent += shift; }
		else { mantissa /= value; exponent -= shift; }
	}
	while (mantissa < 1.0) { mantissa *= 2.0; exponent--; }
	while (mantissa >= 2.0) { mantissa *= 0.5; exponent++; }
	double result = scalbn(mantissa, exponent);
	return isfinite(result) ? result : NAN;
}

static int finite_state(const double *B, int n) {
	for (int k = 0; k < n; k++) {
		const double *b = B + k * STRIDE;
		if (b[ALIVE] == 0.0) continue;
		if (!isfinite(b[MASS]) || b[MASS] <= 0.0) return 0;
		for (int c = PX; c <= VZ; c++) if (!isfinite(b[c])) return 0;
	}
	return 1;
}

static void restore_step(double *B, int n, const Scratch *S) {
	for (int k = 0; k < n; k++) {
		double *b = B + k * STRIDE;
		if (b[ALIVE] == 0.0) continue;
		for (int c = 0; c < 3; c++) { b[PX+c] = S[k].old_pos[c]; b[VX+c] = S[k].old_vel[c]; }
	}
}

/* Physics._pn_set and Physics._eih, operation for operation: the EIH 1PN terms on top
 * of the Newtonian accelerations in S. Buffers grow and are kept between calls. */
static const double PN_LIMIT = 0.1;
static unsigned char *pn_ok = NULL;
static double *pn_phi = NULL, *pn_aN = NULL;
static int pn_cap = 0;

/* `reuse`: pn_ok and pn_phi already hold this position's set (the substep's second pass). */
static void eih(const double *B, int n, Scratch *S, int reuse) {
	if (!reuse) {
	if (n > pn_cap) {
		free(pn_ok); free(pn_phi); free(pn_aN);
		pn_ok = (unsigned char *)malloc((size_t)n);
		pn_phi = (double *)malloc((size_t)n * sizeof(double));
		pn_aN = (double *)malloc((size_t)n * 3 * sizeof(double));
		if (!pn_ok || !pn_phi || !pn_aN) { pn_cap = 0; return; }
		pn_cap = n;
	}
	for (int k = 0; k < n; k++) {
		const double *b = B + k * STRIDE;
		pn_ok[k] = (b[ALIVE] != 0.0 && b[PN] != 0.0 && (b[ISBH] != 0.0 || b[SOFT] == 0.0)) ? 1 : 0;
	}
	double limit = PN_LIMIT * C_LIGHT * C_LIGHT;
	for (int i = 0; i < n; i++) {
		for (int j = i + 1; j < n; j++) {
			if (pn_ok[i] == 0 || pn_ok[j] == 0) continue;
			const double *a = B + i * STRIDE, *b = B + j * STRIDE;
			double r = distance_xyz(b[PX] - a[PX], b[PY] - a[PY], b[PZ] - a[PZ]);
			if (!(G * (a[MASS] + b[MASS]) / r < limit)) { pn_ok[i] = 0; pn_ok[j] = 0; }
		}
	}
	for (int i = 0; i < n; i++) {
		pn_phi[i] = 0.0;
		if (pn_ok[i] == 0) continue;
		const double *a = B + i * STRIDE;
		double sum = 0.0;
		for (int l = 0; l < n; l++) {
			if (l == i || pn_ok[l] == 0) continue;
			const double *b = B + l * STRIDE;
			sum += G * b[MASS] / distance_xyz(b[PX] - a[PX], b[PY] - a[PY], b[PZ] - a[PZ]);
		}
		pn_phi[i] = sum;
	}
	}
	if (pn_cap < n) return;
	for (int k = 0; k < n; k++) { pn_aN[k * 3] = S[k].ax; pn_aN[k * 3 + 1] = S[k].ay; pn_aN[k * 3 + 2] = S[k].az; }
	double c2 = C_LIGHT * C_LIGHT;
	for (int i = 0; i < n; i++) {
		if (pn_ok[i] == 0) continue;
		const double *a = B + i * STRIDE;
		double vi2 = a[VX] * a[VX] + a[VY] * a[VY] + a[VZ] * a[VZ];
		double cx = 0.0, cy = 0.0, cz = 0.0;
		for (int j = 0; j < n; j++) {
			if (j == i || pn_ok[j] == 0) continue;
			const double *b = B + j * STRIDE;
			double dx = b[PX] - a[PX], dy = b[PY] - a[PY], dz = b[PZ] - a[PZ];
			double r = distance_xyz(dx, dy, dz);
			double mu = G * b[MASS];
			double inv_r3 = 1.0 / (r * r * r);
			double ajx = pn_aN[j * 3], ajy = pn_aN[j * 3 + 1], ajz = pn_aN[j * 3 + 2];
			double vj2 = b[VX] * b[VX] + b[VY] * b[VY] + b[VZ] * b[VZ];
			double vivj = a[VX] * b[VX] + a[VY] * b[VY] + a[VZ] * b[VZ];
			double nvj = -(dx * b[VX] + dy * b[VY] + dz * b[VZ]) / r;
			double xa = dx * ajx + dy * ajy + dz * ajz;
			double coef = -4.0 * pn_phi[i] - pn_phi[j] + vi2 + 2.0 * vj2 - 4.0 * vivj - 1.5 * nvj * nvj + 0.5 * xa;
			double t1 = mu * inv_r3 * coef;
			double s = -(dx * (4.0 * a[VX] - 3.0 * b[VX]) + dy * (4.0 * a[VY] - 3.0 * b[VY]) + dz * (4.0 * a[VZ] - 3.0 * b[VZ]));
			double t2 = mu * inv_r3 * s;
			double t3 = 3.5 * mu / r;
			cx += t1 * dx + t2 * (a[VX] - b[VX]) + t3 * ajx;
			cy += t1 * dy + t2 * (a[VY] - b[VY]) + t3 * ajy;
			cz += t1 * dz + t2 * (a[VZ] - b[VZ]) + t3 * ajz;
		}
		cx /= c2; cy /= c2; cz /= c2;
		if (isfinite(cx) && isfinite(cy) && isfinite(cz)) { S[i].ax += cx; S[i].ay += cy; S[i].az += cz; }
	}
}

/* Physics.compute_newtonian. */
static int compute_newtonian(double *B, int n, Scratch *S) {
	for (int k = 0; k < n; k++) { S[k].ax = 0.0; S[k].ay = 0.0; S[k].az = 0.0; }
	for (int i = 0; i < n; i++) {
		double *a = B + i * STRIDE;
		if (a[ALIVE] == 0.0) continue;
		for (int j = i + 1; j < n; j++) {
			double *b = B + j * STRIDE;
			if (b[ALIVE] == 0.0) continue;
			double rx = b[PX] - a[PX], ry = b[PY] - a[PY], rz = b[PZ] - a[PZ];
			double dist = distance_xyz(rx, ry, rz);
			if (dist == 0.0) continue;
			if (!isfinite(dist)) return 0;
			double inv = 1.0 / dist;
			double kernel, denominator, sa = 0.0, sb = 0.0;
			if (a[ISBH] != 0.0 || b[ISBH] != 0.0) {
				/* Weak-field point masses; horizons determine contact only. */
				denominator = dist * dist;
				kernel = G / denominator;
			} else {
				sa = a[SOFT];
				sb = b[SOFT];
				double d2 = dist * dist + 0.5 * (sa * sa + sb * sb);
				denominator = d2 * sqrt(d2);
				kernel = G * dist / denominator;
			}
			double fA = kernel * b[MASS], fB = kernel * a[MASS];
			if (!isfinite(fA) || !isfinite(fB) || fA == 0.0 || fB == 0.0 || (kernel > 0.0 && kernel < DBL_MIN) || denominator < DBL_MIN || !isfinite(inv)) {
				double softened = dist;
				if (a[ISBH] == 0.0 && b[ISBH] == 0.0) {
					double scale = jmax(dist, jmax(fabs(sa), fabs(sb)));
					double r = dist / scale, s1 = sa / scale, s2 = sb / scale;
					softened = scale * sqrt(r * r + 0.5 * (s1 * s1 + s2 * s2));
				}
				fA = scaled_acceleration(b[MASS], dist, softened);
				fB = scaled_acceleration(a[MASS], dist, softened);
				if (!isfinite(fA) || !isfinite(fB)) return 0;
				rx /= dist; ry /= dist; rz /= dist;
			} else {
				rx *= inv; ry *= inv; rz *= inv;          /* unit vector a→b */
			}
			S[i].ax += rx * fA; S[i].ay += ry * fA; S[i].az += rz * fA;
			S[j].ax += rx * -fB; S[j].ay += ry * -fB; S[j].az += rz * -fB;
		}
	}
	for (int k = 0; k < n; k++) if (!isfinite(S[k].ax) || !isfinite(S[k].ay) || !isfinite(S[k].az)) return 0;
	return 1;
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
			double sep = distance_xyz(dx, dy, dz);
			double mu = G * (a[MASS] + b[MASS]);
			if (!isfinite(sep) || !isfinite(mu) || mu <= 0.0) return NAN;
			double fall_squared = (sep * sep * sep) / mu;
			double t_fall = sqrt(fall_squared);
			if (sep > 0.0 && (fall_squared == 0.0 || !isfinite(fall_squared))) t_fall = (sqrt(sep) / sqrt(mu)) * sep;
			double ux = a[VX] - b[VX], uy = a[VY] - b[VY], uz = a[VZ] - b[VZ];
			double vrel = distance_xyz(ux, uy, uz);
			if (!isfinite(vrel)) return NAN;
			double t_fly = vrel > 0.0 ? sep / vrel : INFINITY;
			t_min = jmin(t_min, jmin(0.05 * t_fall, 0.08 * t_fly));
		}
	}
	return t_min;
}

/* Physics.YOSHIDA_W1 / W0: fourth-order composition of leapfrog substeps. */
static const double YOSHIDA_W1 = 1.3512071919596578;
static const double YOSHIDA_W0 = 1.0 - 2.0 * 1.3512071919596578;

/* Physics._leapfrog_substep: drift–kick–drift, the kick's 1PN term at the mean velocity. */
static int leapfrog_substep(double *B, int n, double dt, Scratch *S, int pn) {
	double half = 0.5 * dt;
	for (int k = 0; k < n; k++) {
		double *b = B + k * STRIDE;
		if (b[ALIVE] == 0.0) continue;
		b[PX] += b[VX] * half; b[PY] += b[VY] * half; b[PZ] += b[VZ] * half;
	}
	if (!finite_state(B, n) || !compute_newtonian(B, n, S)) return 0;
	if (pn) {
		for (int k = 0; k < n; k++) {
			double *b = B + k * STRIDE;
			if (b[ALIVE] == 0.0) continue;
			S[k].px = S[k].ax; S[k].py = S[k].ay; S[k].pz = S[k].az;
			S[k].w[0] = b[VX]; S[k].w[1] = b[VY]; S[k].w[2] = b[VZ];
		}
		eih(B, n, S, 0);
		for (int k = 0; k < n; k++) {
			double *b = B + k * STRIDE;
			if (b[ALIVE] == 0.0) continue;
			b[VX] = S[k].w[0] + S[k].ax * half; b[VY] = S[k].w[1] + S[k].ay * half; b[VZ] = S[k].w[2] + S[k].az * half;
			S[k].ax = S[k].px; S[k].ay = S[k].py; S[k].az = S[k].pz;
		}
		eih(B, n, S, 1);
		for (int k = 0; k < n; k++) {
			double *b = B + k * STRIDE;
			if (b[ALIVE] == 0.0) continue;
			b[VX] = S[k].w[0]; b[VY] = S[k].w[1]; b[VZ] = S[k].w[2];
		}
	}
	for (int k = 0; k < n; k++) {
		double *b = B + k * STRIDE;
		if (b[ALIVE] == 0.0) continue;
		b[VX] += S[k].ax * dt; b[VY] += S[k].ay * dt; b[VZ] += S[k].az * dt;
		b[PX] += b[VX] * half; b[PY] += b[VY] * half; b[PZ] += b[VZ] * half;
	}
	return finite_state(B, n);
}

static int integrate(double *B, int n, double dt, Scratch *S) {
	int pn = 0;
	for (int k = 0; k < n; k++) {
		const double *b = B + k * STRIDE;
		if (b[ALIVE] != 0.0 && b[PN] != 0.0) pn = 1;
	}
	for (int k = 0; k < n; k++) for (int c = 0; c < 3; c++) {
		S[k].old_pos[c] = B[k*STRIDE+PX+c]; S[k].old_vel[c] = B[k*STRIDE+VX+c];
	}
	const double w[3] = { YOSHIDA_W1, YOSHIDA_W0, YOSHIDA_W1 };
	for (int s = 0; s < 3; s++)
		if (!leapfrog_substep(B, n, w[s] * dt, S, pn)) { restore_step(B, n, S); return 0; }
	for (int k = 0; k < n; k++) {
		const double *b = B + k * STRIDE;
		if (b[ALIVE] == 0.0) continue;
		/* Accept no time when a force-free mover's entire drift disappears. */
		if (S[k].ax == 0.0 && S[k].ay == 0.0 && S[k].az == 0.0 &&
			(S[k].old_vel[0] != 0.0 || S[k].old_vel[1] != 0.0 || S[k].old_vel[2] != 0.0) &&
			b[PX] == S[k].old_pos[0] && b[PY] == S[k].old_pos[1] && b[PZ] == S[k].old_pos[2]) {
			restore_step(B, n, S); return 0;
		}
	}
	return 1;
}

/* Illustrative quadrupole-power drag; window, boost and kick cap alter rates. */
static void apply_gw(double *B, int n, double dt, double boost) {
	static double G3 = 0.0, C5 = 0.0;
	if (G3 == 0.0) { G3 = pow(G, 3.0); C5 = pow(C_LIGHT, 5.0); }
	for (int i = 0; i < n; i++) {
		double *a = B + i * STRIDE;
		if (a[ALIVE] == 0.0 || a[EMITSGW] == 0.0) continue;
		for (int j = i + 1; j < n; j++) {
			double *b = B + j * STRIDE;
			if (b[ALIVE] == 0.0 || b[EMITSGW] == 0.0) continue;
			double rx = b[PX] - a[PX], ry = b[PY] - a[PY], rz = b[PZ] - a[PZ];
			double r = distance_xyz(rx, ry, rz);
			double cSum = jor(jor(a[CONTACT], a[RADIUS]), a[RS]) + jor(jor(b[CONTACT], b[RADIUS]), b[RS]);
			if (r > 400.0 * cSum || r < cSum * 0.5) continue;
			double vx = b[VX] - a[VX], vy = b[VY] - a[VY], vz = b[VZ] - a[VZ];
			double m1 = a[MASS], m2 = b[MASS], M = m1 + m2, mu = m1 * m2 / M;
			/* Physics.apply_gw_reaction: Peters & Mathews instantaneous power. */
			double v2 = vx * vx + vy * vy + vz * vz;
			double rdot = (rx * vx + ry * vy + rz * vz) / r;
			double dEdt = (8.0 / 15.0) * G3 * m1 * m1 * m2 * m2 * (12.0 * v2 - 11.0 * rdot * rdot) / (C5 * pow(r, 4.0)) * boost;
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

/* Physics.apply_secular, operation for operation: winds, Hut's tides, Roche-lobe
 * overflow. Derivations: docs/physics/secular.md. */
static const double TIDE_REACH = 200.0;
static void apply_secular(double *B, int n, double dt) {
	for (int k = 0; k < n; k++) {
		double *b = B + k * STRIDE;
		if (b[ALIVE] == 0.0 || !(b[MDOT] > 0.0)) continue;
		double dm = jmin(b[MDOT] * dt, 0.001 * b[MASS]);
		b[MASS] -= dm;
	}
	for (int i = 0; i < n; i++) {
		double *a = B + i * STRIDE;
		if (a[ALIVE] == 0.0 || !(a[K2] > 0.0) || !(a[LAG] > 0.0) || !(a[RADIUS] > 0.0) || !(a[IOM] > 0.0)) continue;
		for (int j = 0; j < n; j++) {
			double *b = B + j * STRIDE;
			if (j == i || b[ALIVE] == 0.0) continue;
			double rx = b[PX] - a[PX], ry = b[PY] - a[PY], rz = b[PZ] - a[PZ];
			double r = distance_xyz(rx, ry, rz);
			double R = a[RADIUS];
			if (!(r > R) || r > TIDE_REACH * R) continue;
			double vx = b[VX] - a[VX], vy = b[VY] - a[VY], vz = b[VZ] - a[VZ];
			double ux = rx / r, uy = ry / r, uz = rz / r;
			double rdot = ux * vx + uy * vy + uz * vz;
			double hx = ry * vz - rz * vy, hy = rz * vx - rx * vz, hz = rx * vy - ry * vx;
			double h = distance_xyz(hx, hy, hz);
			double mi = a[MASS], mj = b[MASS];
			double A = 1.5 * a[K2] * G * mj * mj * pow(R, 5.0) * a[LAG] / pow(r, 7.0);
			double inv_mu = 1.0 / mi + 1.0 / mj;
			double fr = -3.0 * A * rdot / r;
			if (fabs(fr * inv_mu * dt) > 0.5 * fabs(rdot)) fr = -0.5 * rdot / (inv_mu * dt);
			double tx = 0.0, ty = 0.0, tz = 0.0, ft = 0.0;
			if (h > 0.0) {
				double w = a[SPIN] - h / (r * r);
				ft = A * w;
				double dW = (r * ft * dt / (mi * a[IOM]) + ft * inv_mu * dt / r);
				if (fabs(dW) > 0.5 * fabs(w)) ft *= 0.5 * fabs(w) / fabs(dW);
				/* θ̂ = ĥ × r̂, the direction of orbital motion */
				tx = (hy * uz - hz * uy) / h; ty = (hz * ux - hx * uz) / h; tz = (hx * uy - hy * ux) / h;
			}
			double fx = fr * ux + ft * tx, fy = fr * uy + ft * ty, fz = fr * uz + ft * tz;
			double kb = dt / mj, ka = dt / mi;
			b[VX] += fx * kb; b[VY] += fy * kb; b[VZ] += fz * kb;
			a[VX] -= fx * ka; a[VY] -= fy * ka; a[VZ] -= fz * ka;
			a[SPIN] -= r * ft * dt / (mi * a[IOM]);
		}
	}
	for (int d = 0; d < n; d++) {
		double *b = B + d * STRIDE;
		if (b[ALIVE] == 0.0 || b[DONOR] == 0.0 || !(b[RADIUS] > 0.0)) continue;
		int best = -1;
		double pull = 0.0, sep = 0.0;
		for (int k = 0; k < n; k++) {
			double *o = B + k * STRIDE;
			if (k == d || o[ALIVE] == 0.0) continue;
			double r = distance_xyz(o[PX] - b[PX], o[PY] - b[PY], o[PZ] - b[PZ]);
			if (!(r > 0.0)) continue;
			double t = o[MASS] / (r * r * r);
			if (t > pull) { pull = t; best = k; sep = r; }
		}
		if (best < 0) continue;
		double *a = B + best * STRIDE;
		/* Eggleton (1983) */
		double q = b[MASS] / a[MASS];
		double q13 = pow(q, 1.0 / 3.0), q23 = q13 * q13;
		double RL = sep * 0.49 * q23 / (0.6 * q23 + log(1.0 + q13));
		if (!(b[RADIUS] > RL)) continue;
		/* Hurley, Tout & Pols (2002) eq. 58 */
		double x = log(b[RADIUS] / RL), mm = jmin(b[MASS], 5.0);
		double dm = jmin(3e-6 * mm * mm * x * x * x * dt, 0.001 * b[MASS]);
		double ma = a[MASS] + dm;
		a[VX] = (a[MASS] * a[VX] + dm * b[VX]) / ma;
		a[VY] = (a[MASS] * a[VY] + dm * b[VY]) / ma;
		a[VZ] = (a[MASS] * a[VZ] + dm * b[VZ]) / ma;
		a[MASS] = ma;
		b[MASS] -= dm;
		a[GAINED] += dm;
		b[SHED] += dm;
	}
}

/* Collision / accretion resolution (Physics collisions). */
static int resolve_collisions(double *B, int n, double *ev, int *limited) {
	int count = 0;
	for (int i = 0; i < n; i++) {
		double *a = B + i * STRIDE;
		if (a[ALIVE] == 0.0) continue;
		for (int j = i + 1; j < n; j++) {
			double *b = B + j * STRIDE;
			if (b[ALIVE] == 0.0) continue;
			double dx = b[PX] - a[PX], dy = b[PY] - a[PY], dz = b[PZ] - a[PZ];
			double d = distance_xyz(dx, dy, dz);
			double ca = a[ISBH] != 0.0 ? a[RS] : jor(a[CONTACT], a[RADIUS]);
			double cb = b[ISBH] != 0.0 ? b[RS] : jor(b[CONTACT], b[RADIUS]);
			if (!isfinite(d) || !isfinite(ca + cb)) { *limited = 1; return count; }
			if (d > ca + cb) continue;
			int big = a[MASS] >= b[MASS] ? i : j;
			int small = big == i ? j : i;
			double *g = B + big * STRIDE, *s = B + small * STRIDE;
			double M = g[MASS] + s[MASS];
			double invM = 1.0 / M, pos[3], vel[3];
			if (!isfinite(M) || M <= 0.0) { *limited = 1; return count; }
			for (int c = 0; c < 3; c++) {
				vel[c] = (g[VX + c] * g[MASS] + s[VX + c] * s[MASS]) * invM;
				pos[c] = (g[PX + c] * g[MASS] + s[PX + c] * s[MASS]) * invM;
				if (!isfinite(vel[c]) || !isfinite(pos[c])) { *limited = 1; return count; }
			}
			for (int c = 0; c < 3; c++) { g[PX+c] = pos[c]; g[VX+c] = vel[c]; }
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
	double remaining = A[2], requested = A[9], max_step = A[3], gw = A[4];
	int secular = A[10] != 0.0;
	int guard = (int)A[5];
	double stepped = A[6];
	int events = 0;
	double *B = A + HDR;
	double *ev = A + HDR + n * STRIDE;
	Scratch *S = (Scratch *)calloc((size_t)(n > 0 ? n : 1), sizeof(Scratch));
	int limited = 0;
	if (!isfinite(remaining) || !isfinite(requested) || !isfinite(stepped) || !isfinite(max_step) || !isfinite(gw) || max_step <= 0.0 || !finite_state(B, n)) limited = 1;
	if (!limited && remaining > 0.0 && guard < STEP_GUARD) events = resolve_collisions(B, n, ev, &limited);
	while (!limited && events == 0 && remaining > 0.0 && guard < STEP_GUARD) {
		double h = jmin(jmin(remaining, requested - stepped), dynamic_step(B, n, max_step));
		if (!isfinite(h) || h <= 0.0 || !isfinite(stepped + h) || stepped + h <= stepped) { limited = 1; break; }
		if (!integrate(B, n, h, S)) { limited = 1; break; }
		if (gw != 0.0) apply_gw(B, n, h, gw);
		if (!finite_state(B, n)) { restore_step(B, n, S); limited = 1; break; }
		if (secular) apply_secular(B, n, h);
		guard++;
		stepped += h;
		remaining = jmin(remaining - h, requested - stepped);
		events = resolve_collisions(B, n, ev, &limited);
	}
	free(S);
	A[2] = remaining; A[5] = (double)guard; A[6] = stepped; A[7] = (double)events; A[8] = (double)limited;
}

/* ============================================================================
 * Galactic tracers (sim/galaxy/gal_tracers.gd is the GDScript twin; the two
 * must stay bit-identical, so every expression keeps its order there).
 * Massless particles in a static axisymmetric potential plus rotating patterns,
 * drift–kick–drift at a fixed step, each tracer taking all k steps in turn.
 * Buffer: [0] length, [1] n, [2] k, [3] dt, [4] t_start, [5] patterns, [6] table
 * size, [7] steps taken so far, [8..20] the axisymmetric kernel (GalPotential.Kernel),
 * then 12 per pattern,
 * the bulge table and its derivative, positions, velocities and work, n each ×3,
 * ×3 and ×1. Work accumulates ∫∂Φ/∂t dt, so E − W is each tracer's invariant.
 * ========================================================================== */
#define TR_AXIS 8
#define TR_PAT 21
#define TR_PSTRIDE 12

static double log_cosh(double x) {
	double a = fabs(x);
	return a + log(1.0 + exp(-2.0 * a)) - log(2.0);
}

/* Dehnen's (2000) growth factor and its rate. */
static double tr_growth(const double *P, double t) {
	double t0 = P[4], tg = P[5];
	if (t <= t0) return 0.0;
	if (t >= t0 + tg) return 1.0;
	double xi = 2.0 * (t - t0) / tg - 1.0;
	return 3.0 / 16.0 * pow(xi, 5.0) - 5.0 / 8.0 * pow(xi, 3.0) + 15.0 / 16.0 * xi + 0.5;
}

static double tr_growth_rate(const double *P, double t) {
	double t0 = P[4], tg = P[5];
	if (t <= t0 || t >= t0 + tg) return 0.0;
	double xi = 2.0 * (t - t0) / tg - 1.0;
	return (15.0 / 16.0 * pow(xi, 4.0) - 15.0 / 8.0 * xi * xi + 15.0 / 16.0) * 2.0 / tg;
}

static void run_tracers(double *A) {
	int n = (int)A[1], k = (int)A[2], np = (int)A[5], tn = (int)A[6];
	/* The buffer is exactly its header's counts long, or nothing is touched. */
	long long need = TR_PAT + (long long)TR_PSTRIDE * np + 2LL * tn + 7LL * n;
	if (n < 0 || k < 0 || np < 0 || tn < 0 || need != (long long)A[0]) return;
	double dt = A[3], t_start = A[4], h = dt * 0.5;
	/* A step's time from its index, so it does not depend on how steps are batched. */
	double steps0 = A[7];
	const double *X = A + TR_AXIS;
	double mn_gm = X[0], mn_a = X[1], mn_b2 = X[2];
	double s1_gm = X[3], s1_a = X[4], s2_gm = X[6], s2_a = X[7];
	int s1_nfw = X[5] != 0.0, s2_nfw = X[8] != 0.0;
	double th = X[9], tr0 = X[10], tgm = X[11], talpha = X[12];
	const double *tb = A + TR_PAT + TR_PSTRIDE * np;
	const double *td = tb + tn;
	double *pos = (double *)(td + tn);
	double *vel = pos + 3 * n;
	double *work = vel + 3 * n;
	int has_tab = tn > 0;
	/* Per step and pattern: growth, its rate, and the pattern's angle terms. */
	double *G = (double *)calloc((size_t)k * (size_t)np * 4 + 1, sizeof(double));
	if (!G) return;
	for (int s = 0; s < k; s++) {
		double tm = t_start + (steps0 + (double)s + 0.5) * dt;
		for (int j = 0; j < np; j++) {
			const double *P = A + TR_PAT + TR_PSTRIDE * j;
			double ang = P[2] + P[1] * tm;
			double *g = G + (s * np + j) * 4;
			g[0] = tr_growth(P, tm);
			g[1] = tr_growth_rate(P, tm);
			if (P[0] == 0.0) { g[2] = cos(2.0 * ang); g[3] = sin(2.0 * ang); }
			else { g[2] = ang; g[3] = 0.0; }
		}
	}
	for (int i = 0; i < n; i++) {
		int c = i * 3;
		double x = pos[c], y = pos[c + 1], z = pos[c + 2];
		double vx = vel[c], vy = vel[c + 1], vz = vel[c + 2];
		double w = work[i];
		for (int s = 0; s < k; s++) {
			x += vx * h; y += vy * h; z += vz * h;
			double ax = 0.0, ay = 0.0, az = 0.0;
			if (mn_gm != 0.0) {
				double zb = sqrt(y * y + mn_b2);
				double sa = mn_a + zb;
				double d = x * x + z * z + sa * sa;
				double f = -mn_gm / (d * sqrt(d));
				ax += f * x; ay += f * y * sa / zb; az += f * z;
			}
			double r2 = x * x + y * y + z * z;
			double r = sqrt(r2);
			double m = 0.0;
			if (s1_gm != 0.0) {
				double q = r / s1_a;
				if (s1_nfw) m += q > 1e-4 ? s1_gm * (log(1.0 + q) - q / (1.0 + q)) : s1_gm * q * q * (0.5 - q * 2.0 / 3.0);
				else m += s1_gm * r2 / ((r + s1_a) * (r + s1_a));
			}
			if (s2_gm != 0.0) {
				double q = r / s2_a;
				if (s2_nfw) m += q > 1e-4 ? s2_gm * (log(1.0 + q) - q / (1.0 + q)) : s2_gm * q * q * (0.5 - q * 2.0 / 3.0);
				else m += s2_gm * r2 / ((r + s2_a) * (r + s2_a));
			}
			if (has_tab) {
				if (r <= tr0) {
					m += tb[0] * pow(r / tr0, 3.0 - talpha);
				} else {
					double u = log(r / tr0) / th;
					int j = (int)u;
					if (j >= tn - 1) {
						m += tgm;
					} else {
						double ww = u - (double)j;
						double w2 = ww * ww;
						double w3 = w2 * ww;
						m += (2.0 * w3 - 3.0 * w2 + 1.0) * tb[j] + (w3 - 2.0 * w2 + ww) * th * td[j]
							+ (-2.0 * w3 + 3.0 * w2) * tb[j + 1] + (w3 - w2) * th * td[j + 1];
					}
				}
			}
			if (r > 0.0) {
				double g = -m / (r2 * r);
				ax += g * x; ay += g * y; az += g * z;
			}
			double dphidt = 0.0;
			for (int j = 0; j < np; j++) {
				const double *P = A + TR_PAT + TR_PSTRIDE * j;
				const double *gg = G + (s * np + j) * 4;
				double gs = gg[0];
				if (gs == 0.0 && gg[1] == 0.0) continue;
				double R2 = x * x + z * z;
				double R = sqrt(R2);
				if (P[0] == 0.0) {
					/* Dehnen bar: Φ = A Q h(r), Q = (x² − z²) cos 2φb + 2xz sin 2φb, h = g(r)/r². */
					if (r < 1e-9) continue;
					double rb = P[6], rb3 = rb * rb * rb, c2 = gg[2], s2 = gg[3];
					double Q = (x * x - z * z) * c2 + 2.0 * x * z * s2;
					double hh, dh;
					if (r >= rb) { hh = -rb3 / (r2 * r2 * r); dh = 5.0 * rb3 / (r2 * r2 * r2); }
					else { hh = r / rb3 - 2.0 / r2; dh = 1.0 / rb3 + 4.0 / (r2 * r); }
					double Ab = gs * P[3];
					double radial = Ab * Q * dh / r;
					ax -= Ab * hh * (2.0 * x * c2 + 2.0 * z * s2) + radial * x;
					ay -= radial * y;
					az -= Ab * hh * (-2.0 * z * c2 + 2.0 * x * s2) + radial * z;
					double full = P[3] * Q * hh;
					double dfull = P[3] * hh * -2.0 * (2.0 * x * z * c2 - (x * x - z * z) * s2);
					dphidt += gg[1] * full - gs * P[1] * dfull;
				} else {
					/* Cox & Gómez spiral, one term. */
					if (R < 1e-6) continue;
					double nn = P[6], sa = sin(P[7]), ta = tan(P[7]), r0 = P[8], rs = P[9], H = P[10];
					double K = nn / (R * sa);
					double dK = -K / R;
					double q = K * H;
					double dq = dK * H;
					double B = q * (1.0 + 0.4 * q);
					double dB = dq * (1.0 + 0.8 * q);
					double den = 1.0 + 0.3 * q;
					double D = (1.0 + q + 0.3 * q * q) / den;
					double dD = ((1.0 + 0.6 * q) * den - 0.3 * (1.0 + q + 0.3 * q * q)) / (den * den) * dq;
					double gam = nn * (atan2(z, x) - gg[2] + log(R / r0) / ta);
					double xx = K * y / B;
					double lc = log_cosh(xx);
					double thx = tanh(xx);
					double S = exp(-B * lc);
					double f = exp(-(R - r0) / rs) / (K * D);
					double As = gs * P[3];
					double cg = cos(gam), sg = sin(gam);
					double df_f = -1.0 / rs - dK / K - dD / D;
					double dS_S = -dB * lc - thx * y * (dK - K * dB / B);
					double g_R = nn / (R * ta);
					double dPhi_dR = -As * f * S * (df_f * cg - g_R * sg + dS_S * cg);
					double dPhi_dphi = As * f * nn * sg * S;
					double dPhi_dy = As * f * cg * S * K * thx;
					ax -= dPhi_dR * x / R - dPhi_dphi * z / R2;
					ay -= dPhi_dy;
					az -= dPhi_dR * z / R + dPhi_dphi * x / R2;
					double full = -P[3] * f * cg * S;
					double dfull = P[3] * f * nn * sg * S;
					dphidt += gg[1] * full - gs * P[1] * dfull;
				}
			}
			w += dphidt * dt;
			vx += ax * dt; vy += ay * dt; vz += az * dt;
			x += vx * h; y += vy * h; z += vz * h;
		}
		pos[c] = x; pos[c + 1] = y; pos[c + 2] = z;
		vel[c] = vx; vel[c + 1] = vy; vel[c + 2] = vz;
		work[i] = w;
	}
	free(G);
}

/* ============================================================================
 * Galaxy encounters (sim/galaxy/gal_encounter.gd is the GDScript twin; the two must
 * stay bit-identical, so every expression keeps its order there; only sqrt is called).
 * Massless stars in rigid galaxies about moving centres, drift–kick–drift at a fixed
 * step. Buffer: [0] length, [1] n, [2] k, [3] dt, [4] galaxies, EN_STRIDE per galaxy
 * (halo G M, a; disc G M, a, b; bulge G M, a; axes x, y, z), the centres at each
 * mid-step (k × galaxies × 3), positions and velocities (n × 3 each), then 2n doubles
 * the kernel fills with each star's float32 (x, y, z, galaxy) for drawing.
 * ========================================================================== */
#define EN_HDR 5
#define EN_STRIDE 16

static void en_accel(const double *P, double px, double py, double pz, double cx, double cy, double cz, double *acc) {
	double dx = px - cx, dy = py - cy, dz = pz - cz;
	double r = sqrt(dx * dx + dy * dy + dz * dz);
	if (r < 1e-6) return;
	double ax = 0.0, ay = 0.0, az = 0.0;
	for (int k = 0; k <= 5; k += 5) {
		double gmk = P[k];
		if (gmk != 0.0) {
			double ak = P[k + 1];
			double f = -gmk / (r * (r + ak) * (r + ak));
			ax += f * dx; ay += f * dy; az += f * dz;
		}
	}
	double gd = P[2];
	if (gd != 0.0) {
		const double *B = P + 7;
		double lx = dx * B[0] + dy * B[1] + dz * B[2];
		double ly = dx * B[3] + dy * B[4] + dz * B[5];
		double lz = dx * B[6] + dy * B[7] + dz * B[8];
		double b = P[4];
		double zb = sqrt(ly * ly + b * b);
		double sa = P[3] + zb;
		double q = lx * lx + lz * lz + sa * sa;
		double f = -gd / (q * sqrt(q));
		double fx = f * lx, fy = f * ly * sa / zb, fz = f * lz;
		ax += fx * B[0] + fy * B[3] + fz * B[6];
		ay += fx * B[1] + fy * B[4] + fz * B[7];
		az += fx * B[2] + fy * B[5] + fz * B[8];
	}
	acc[0] += ax; acc[1] += ay; acc[2] += az;
}

static void run_encounter(double *A) {
	int n = (int)A[1], k = (int)A[2], ng = (int)A[4];
	long long need = EN_HDR + (long long)EN_STRIDE * ng + 3LL * k * ng + 8LL * n;
	if (n < 0 || k < 0 || ng < 0 || need != (long long)A[0]) return;
	double dt = A[3], h = dt * 0.5;
	const double *G = A + EN_HDR;
	const double *mids = G + EN_STRIDE * ng;
	double *pos = (double *)(mids + k * ng * 3);
	double *vel = pos + 3 * n;
	for (int i = 0; i < n; i++) {
		int c = i * 3;
		double x = pos[c], y = pos[c + 1], z = pos[c + 2];
		double vx = vel[c], vy = vel[c + 1], vz = vel[c + 2];
		for (int s = 0; s < k; s++) {
			x += vx * h; y += vy * h; z += vz * h;
			double acc[3] = {0.0, 0.0, 0.0};
			for (int g = 0; g < ng; g++) {
				const double *P = G + EN_STRIDE * g;
				if (P[0] == 0.0 && P[2] == 0.0 && P[5] == 0.0) continue;
				const double *m = mids + (s * ng + g) * 3;
				en_accel(P, x, y, z, m[0], m[1], m[2], acc);
			}
			vx += acc[0] * dt; vy += acc[1] * dt; vz += acc[2] * dt;
			x += vx * h; y += vy * h; z += vz * h;
		}
		pos[c] = x; pos[c + 1] = y; pos[c + 2] = z;
		vel[c] = vx; vel[c + 1] = vy; vel[c + 2] = vz;
	}
	float *draw = (float *)(vel + 3 * n);
	for (int i = 0; i < n; i++) {
		draw[4 * i] = (float)pos[3 * i];
		draw[4 * i + 1] = (float)pos[3 * i + 1];
		draw[4 * i + 2] = (float)pos[3 * i + 2];
	}
}

/* ============================================================================
 * Live galaxies: every particle pulls on every other through a Barnes–Hut octree of
 * monopole cells with Plummer softening, kick–drift–kick at a fixed step.
 * sim/galaxy/gal_live.gd is the twin and builds and traverses the same tree in the
 * same order. Each particle's force is summed by one thread alone, so the result does
 * not depend on how many threads ran.
 * Buffer: [0] length [1] n [2] k steps [3] dt [4] θ [5] G [6] accelerations valid
 * (in/out) [7] potentials wanted [8] luminous count nl [9] threads (in: 0 for all
 * cores; out: used, or −1 when a step could not allocate its tree and the run stopped
 * there, with [2] the steps completed), then LV_STRIDE per particle: x y z vx vy vz ax ay az m ε φ, then
 * 2·nl doubles holding the first nl particles' float32 (x, y, z, tag) for drawing.
 * ========================================================================== */
#define LV_HDR 10
#define LV_STRIDE 12
#define LV_LEAF 8
#define LV_DEPTH 48
#define LV_GROUP 32
/* IEEE sqrt is correctly rounded, so the instruction gives libm's (and GDScript's) bits,
 * and the force loop vectorises around it. */
#define LV_SQRT __builtin_sqrt

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif
#include <stdatomic.h>

typedef struct {
	double m, sx, sy, sz, cx, cy, cz, ropen2, eps;
	int first, count, lo, hi;
} LvNode;

typedef struct {
	LvNode *nodes;
	int nn, cap;
	int *idx, *tmp;
	const double *P;
	double theta;
	int failed;
} LvTree;

/* A new node's index, or −1 (and T->failed) when the nodes cannot grow. */
static int lv_node(LvTree *T) {
	if (T->nn == T->cap) {
		int cap = T->cap ? 2 * T->cap : 1024;
		LvNode *grown = (LvNode *)realloc(T->nodes, sizeof(LvNode) * (size_t)cap);
		if (!grown) { T->failed = 1; return -1; }
		T->nodes = grown;
		T->cap = cap;
	}
	memset(&T->nodes[T->nn], 0, sizeof(LvNode));
	return T->nn++;
}

/* Node `nd` holds idx[lo, hi) in the cube about (x0, y0, z0) of half-side `half`. */
static void lv_fill(LvTree *T, int nd, int lo, int hi, double x0, double y0, double z0, double half, int depth) {
	const double *P = T->P;
	double m = 0.0, sx = 0.0, sy = 0.0, sz = 0.0, eps = 0.0;
	T->nodes[nd].lo = lo;
	T->nodes[nd].hi = hi;
	if (hi - lo <= LV_LEAF || depth >= LV_DEPTH) {
		for (int q = lo; q < hi; q++) {
			const double *p = P + LV_STRIDE * T->idx[q];
			m += p[9];
			sx += p[9] * p[0]; sy += p[9] * p[1]; sz += p[9] * p[2];
			if (p[10] > eps) eps = p[10];
		}
	} else {
		int cnt[8] = {0}, off[8];
		for (int q = lo; q < hi; q++) {
			const double *p = P + LV_STRIDE * T->idx[q];
			cnt[(p[0] >= x0) | ((p[1] >= y0) << 1) | ((p[2] >= z0) << 2)]++;
		}
		int o = lo, kids = 0;
		for (int c = 0; c < 8; c++) { off[c] = o; o += cnt[c]; if (cnt[c]) kids++; }
		for (int q = lo; q < hi; q++) {
			int j = T->idx[q];
			const double *p = P + LV_STRIDE * j;
			T->tmp[off[(p[0] >= x0) | ((p[1] >= y0) << 1) | ((p[2] >= z0) << 2)]++] = j;
		}
		memcpy(T->idx + lo, T->tmp + lo, sizeof(int) * (size_t)(hi - lo));
		int first = T->nn;
		for (int c = 0; c < kids; c++) if (lv_node(T) < 0) return;
		T->nodes[nd].first = first;
		T->nodes[nd].count = kids;
		double h = 0.5 * half;
		int k = 0, a = lo;
		for (int c = 0; c < 8; c++) {
			if (!cnt[c]) continue;
			lv_fill(T, first + k, a, a + cnt[c], x0 + ((c & 1) ? h : -h), y0 + ((c & 2) ? h : -h), z0 + ((c & 4) ? h : -h), h, depth + 1);
			if (T->failed) return;
			a += cnt[c];
			k++;
		}
		for (int c = 0; c < kids; c++) {
			const LvNode *C = &T->nodes[first + c];
			m += C->m;
			sx += C->sx; sy += C->sy; sz += C->sz;
			if (C->eps > eps) eps = C->eps;
		}
	}
	LvNode *N = &T->nodes[nd];
	N->m = m; N->sx = sx; N->sy = sy; N->sz = sz; N->eps = eps;
	N->cx = sx / m; N->cy = sy / m; N->cz = sz / m;
	double dx = N->cx - x0, dy = N->cy - y0, dz = N->cz - z0;
	/* Opened when nearer than side/θ plus the centre of mass's offset from the cube's
	 * centre, so a particle inside the cube always opens it (θ ≤ 1). */
	double ropen = 2.0 * half / T->theta + sqrt(dx * dx + dy * dy + dz * dz);
	N->ropen2 = ropen * ropen;
}

static void lv_build(LvTree *T, const double *P, int n, double theta) {
	T->P = P;
	T->theta = theta;
	T->nn = 0;
	T->idx = (int *)malloc(sizeof(int) * (size_t)n);
	T->tmp = (int *)malloc(sizeof(int) * (size_t)n);
	if (!T->idx || !T->tmp) { T->failed = 1; return; }
	double lo[3] = {P[0], P[1], P[2]}, hi[3] = {P[0], P[1], P[2]};
	for (int i = 0; i < n; i++) {
		T->idx[i] = i;
		for (int c = 0; c < 3; c++) {
			double v = P[LV_STRIDE * i + c];
			if (v < lo[c]) lo[c] = v;
			if (v > hi[c]) hi[c] = v;
		}
	}
	double half = 0.0;
	for (int c = 0; c < 3; c++) if (0.5 * (hi[c] - lo[c]) > half) half = 0.5 * (hi[c] - lo[c]);
	if (half <= 0.0) half = 1.0;
	int root = lv_node(T);
	if (root < 0) return;
	lv_fill(T, root, 0, n, 0.5 * (lo[0] + hi[0]), 0.5 * (lo[1] + hi[1]), 0.5 * (lo[2] + hi[2]), half, 0);
}

static void lv_free(LvTree *T) {
	free(T->nodes); free(T->idx); free(T->tmp);
	T->nodes = NULL; T->idx = T->tmp = NULL; T->cap = T->nn = 0;
}

typedef struct {
	const LvTree *T;
	double *P;
	double G;
	const int *groups;
	int ngroups, want_phi;
	atomic_int next;
	atomic_int failed;
} LvForces;

/* The groups: the highest nodes holding at most LV_GROUP particles, in tree order. Each
 * walks the tree once for all its particles (Barnes 1990). */
static void lv_groups(const LvTree *T, int nd, int *out, int *count) {
	const LvNode *N = &T->nodes[nd];
	if (N->hi - N->lo <= LV_GROUP || N->count == 0) { out[(*count)++] = nd; return; }
	for (int c = 0; c < N->count; c++) lv_groups(T, N->first + c, out, count);
}

static double lv_gap(double c, double lo, double hi) {
	return c < lo ? lo - c : (c > hi ? c - hi : 0.0);
}

/* An interaction list, gathered: each source's position, mass, softening and particle
 * index (−1 for a cell). */
typedef struct { double *x, *y, *z, *m, *e; int *j; int len, cap, failed; } LvList;

static int lv_grow(void **p, size_t bytes) {
	void *q = realloc(*p, bytes);
	if (!q) return 0;
	*p = q;
	return 1;
}

/* A failed allocation keeps the list as it was and marks it failed. */
static void lv_push(LvList *L, double x, double y, double z, double m, double e, int j) {
	if (L->failed) return;
	if (L->len == L->cap) {
		int cap = L->cap ? 2 * L->cap : 4096;
		size_t d = sizeof(double) * (size_t)cap;
		int ok = lv_grow((void **)&L->x, d) & lv_grow((void **)&L->y, d) & lv_grow((void **)&L->z, d)
			& lv_grow((void **)&L->m, d) & lv_grow((void **)&L->e, d) & lv_grow((void **)&L->j, sizeof(int) * (size_t)cap);
		if (!ok) { L->failed = 1; return; }
		L->cap = cap;
	}
	L->x[L->len] = x; L->y[L->len] = y; L->z[L->len] = z;
	L->m[L->len] = m; L->e[L->len] = e; L->j[L->len] = j;
	L->len++;
}

/* Group g's interaction list: a cell is taken whole when the group's bounding box lies
 * outside its opening sphere, so it would be for every particle in the group. */
static void lv_list(const LvTree *T, const double *P, int g, LvList *L) {
	const LvNode *Gn = &T->nodes[g];
	const double *p0 = P + LV_STRIDE * T->idx[Gn->lo];
	double lx = p0[0], ly = p0[1], lz = p0[2], hx = p0[0], hy = p0[1], hz = p0[2];
	for (int q = Gn->lo; q < Gn->hi; q++) {
		const double *p = P + LV_STRIDE * T->idx[q];
		if (p[0] < lx) lx = p[0];
		if (p[0] > hx) hx = p[0];
		if (p[1] < ly) ly = p[1];
		if (p[1] > hy) hy = p[1];
		if (p[2] < lz) lz = p[2];
		if (p[2] > hz) hz = p[2];
	}
	int stack[LV_DEPTH * 8 + 8];
	int sp = 0;
	stack[sp++] = 0;
	L->len = 0;
	while (sp > 0) {
		const LvNode *N = &T->nodes[stack[--sp]];
		double gx = lv_gap(N->cx, lx, hx), gy = lv_gap(N->cy, ly, hy), gz = lv_gap(N->cz, lz, hz);
		if (gx * gx + gy * gy + gz * gz > N->ropen2) {
			lv_push(L, N->cx, N->cy, N->cz, N->m, N->eps, -1);
		} else if (N->count == 0) {
			for (int q = N->lo; q < N->hi; q++) {
				int j = T->idx[q];
				const double *pj = P + LV_STRIDE * j;
				lv_push(L, pj[0], pj[1], pj[2], pj[9], pj[10], j);
			}
		} else {
			for (int c = N->count - 1; c >= 0; c--) stack[sp++] = N->first + c;
		}
	}
}

/* Every particle of group g against its list, the list outermost so the group's particles
 * vectorise while each keeps its own order of summation. A particle meets itself at zero
 * separation, softened (ε > 0), and gains exactly nothing; only the potential skips it. */
static void lv_group(const LvTree *T, double *P, int g, const LvList *L, double G, int want_phi) {
	const LvNode *Gn = &T->nodes[g];
	for (int b = Gn->lo; b < Gn->hi; b += LV_GROUP) {
		int k = Gn->hi - b < LV_GROUP ? Gn->hi - b : LV_GROUP;
		double x[LV_GROUP], y[LV_GROUP], z[LV_GROUP], e[LV_GROUP];
		double ax[LV_GROUP], ay[LV_GROUP], az[LV_GROUP], phi[LV_GROUP];
		int id[LV_GROUP];
		for (int a = 0; a < k; a++) {
			id[a] = T->idx[b + a];
			const double *p = P + LV_STRIDE * id[a];
			x[a] = p[0]; y[a] = p[1]; z[a] = p[2]; e[a] = p[10];
			ax[a] = 0.0; ay[a] = 0.0; az[a] = 0.0; phi[a] = 0.0;
		}
		for (int q = 0; q < L->len; q++) {
			double cx = L->x[q], cy = L->y[q], cz = L->z[q], gm = G * L->m[q], eq = L->e[q];
			for (int a = 0; a < k; a++) {
				double s = e[a] > eq ? e[a] : eq;
				double dx = cx - x[a], dy = cy - y[a], dz = cz - z[a];
				double r2 = dx * dx + dy * dy + dz * dz + s * s;
				double r = LV_SQRT(r2);
				double f = gm / (r2 * r);
				ax[a] += f * dx; ay[a] += f * dy; az[a] += f * dz;
			}
			if (want_phi) {
				for (int a = 0; a < k; a++) {
					if (L->j[q] == id[a]) continue;
					double s = e[a] > eq ? e[a] : eq;
					double dx = cx - x[a], dy = cy - y[a], dz = cz - z[a];
					phi[a] -= gm / LV_SQRT(dx * dx + dy * dy + dz * dz + s * s);
				}
			}
		}
		for (int a = 0; a < k; a++) {
			double *p = P + LV_STRIDE * id[a];
			p[6] = ax[a]; p[7] = ay[a]; p[8] = az[a];
			if (want_phi) p[11] = phi[a];
		}
	}
}

static void lv_worker_body(LvForces *F) {
	LvList L;
	memset(&L, 0, sizeof L);
	for (;;) {
		int g = atomic_fetch_add(&F->next, 1);
		if (g >= F->ngroups) break;
		lv_list(F->T, F->P, F->groups[g], &L);
		if (L.failed) { atomic_store(&F->failed, 1); break; }
		lv_group(F->T, F->P, F->groups[g], &L, F->G, F->want_phi);
	}
	free(L.x); free(L.y); free(L.z); free(L.m); free(L.e); free(L.j);
}

#ifdef _WIN32
static DWORD WINAPI lv_worker(LPVOID arg) { lv_worker_body((LvForces *)arg); return 0; }
#else
static void *lv_worker(void *arg) { lv_worker_body((LvForces *)arg); return NULL; }
#endif

static int lv_cores(void) {
#ifdef _WIN32
	SYSTEM_INFO si;
	GetSystemInfo(&si);
	return (int)si.dwNumberOfProcessors;
#else
	long c = sysconf(_SC_NPROCESSORS_ONLN);
	return c > 0 ? (int)c : 1;
#endif
}

/* Forces on every particle from a fresh tree; returns the threads used, or 0 when an
 * allocation failed and the forces are incomplete. */
static int lv_forces(double *P, int n, double theta, double G, int want_phi, int threads) {
	LvTree T;
	memset(&T, 0, sizeof T);
	lv_build(&T, P, n, theta);
	int *groups = T.failed ? NULL : (int *)malloc(sizeof(int) * (size_t)T.nn);
	if (!groups) { lv_free(&T); return 0; }
	int ng = 0;
	lv_groups(&T, 0, groups, &ng);
	LvForces F;
	F.T = &T; F.P = P; F.G = G; F.groups = groups; F.ngroups = ng; F.want_phi = want_phi;
	atomic_init(&F.next, 0);
	atomic_init(&F.failed, 0);
	int nt = threads > 0 ? threads : lv_cores();
	if (nt > 64) nt = 64;
	if (nt > ng) nt = ng;
	if (nt < 1) nt = 1;
#ifdef _WIN32
	HANDLE th[64];
	for (int t = 1; t < nt; t++) th[t] = CreateThread(NULL, 0, lv_worker, &F, 0, NULL);
	lv_worker_body(&F);
	for (int t = 1; t < nt; t++) { WaitForSingleObject(th[t], INFINITE); CloseHandle(th[t]); }
#else
	pthread_t th[64];
	int started[64] = {0};
	for (int t = 1; t < nt; t++) started[t] = pthread_create(&th[t], NULL, lv_worker, &F) == 0;
	lv_worker_body(&F);
	for (int t = 1; t < nt; t++) if (started[t]) pthread_join(th[t], NULL);
#endif
	free(groups);
	lv_free(&T);
	return atomic_load(&F.failed) ? 0 : nt;
}

static void run_live(double *A) {
	int n = (int)A[1], k = (int)A[2], nl = (int)A[8];
	double dt = A[3], theta = A[4], G = A[5], h = 0.5 * dt;
	int want_phi = A[7] != 0.0, threads = (int)A[9];
	double *P = A + LV_HDR;
	long long need = LV_HDR + (long long)LV_STRIDE * n + 2LL * nl;
	if (n <= 0 || k < 0 || nl < 0 || nl > n || need != (long long)A[0]) return;
	int used = 1;
	if (A[6] == 0.0) {
		used = lv_forces(P, n, theta, G, want_phi, threads);
		if (!used) { A[2] = 0.0; A[9] = -1.0; return; }
		A[6] = 1.0;
	}
	for (int s = 0; s < k; s++) {
		for (int i = 0; i < n; i++) {
			double *p = P + LV_STRIDE * i;
			p[3] += p[6] * h; p[4] += p[7] * h; p[5] += p[8] * h;
			p[0] += p[3] * dt; p[1] += p[4] * dt; p[2] += p[5] * dt;
		}
		used = lv_forces(P, n, theta, G, want_phi, threads);
		if (!used) { A[2] = (double)s; A[6] = 0.0; A[9] = -1.0; return; }
		for (int i = 0; i < n; i++) {
			double *p = P + LV_STRIDE * i;
			p[3] += p[6] * h; p[4] += p[7] * h; p[5] += p[8] * h;
		}
	}
	A[9] = (double)used;
	float *draw = (float *)(P + LV_STRIDE * n);
	for (int i = 0; i < nl && i < n; i++) {
		draw[4 * i] = (float)P[LV_STRIDE * i];
		draw[4 * i + 1] = (float)P[LV_STRIDE * i + 1];
		draw[4 * i + 2] = (float)P[LV_STRIDE * i + 2];
	}
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

/* ============================================================================
 * GDExtension plumbing — one abstract class with static methods: step2 (the N-body
 * kernel), tracers (the galactic tracers), libm (run_libm), encounter (run_encounter)
 * and live (run_live).
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
typedef void (*Runner)(double *);

static void step_into(GDExtensionConstTypePtr in, GDExtensionUninitializedTypePtr out, Runner fn, int min_len) {
	const GDExtensionConstTypePtr args[1] = { in };
	pf64_copy(out, args);
	const double *src = pf64_idx_c(in, 0);
	if (!src) return;
	int len = (int)src[0];
	if (len < min_len) return;
	/* Writing through `out` detaches its storage from the caller's, so the kernel runs on
	 * the copy in place. */
	double *dst = pf64_idx((GDExtensionTypePtr)out, 0);
	if (dst) fn(dst);
}

static int tracer_tag = 1;
static int libm_tag = 2;
static int encounter_tag = 3;
static int live_tag = 4;

/* Method userdata selects the kernel: NULL is step2, then the tracers and libm. */
static void dispatch(void *ud, GDExtensionConstTypePtr in, GDExtensionUninitializedTypePtr out) {
	if (ud == &tracer_tag) step_into(in, out, run_tracers, TR_PAT);
	else if (ud == &libm_tag) step_into(in, out, run_libm, 5);
	else if (ud == &encounter_tag) step_into(in, out, run_encounter, EN_HDR);
	else if (ud == &live_tag) step_into(in, out, run_live, LV_HDR);
	else step_into(in, out, run, HDR);
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

static SName sn_class, sn_parent, sn_method, sn_tracers, sn_libm, sn_encounter, sn_live, sn_arg, sn_empty;

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
