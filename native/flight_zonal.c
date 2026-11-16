#include <string.h>
#include "kernels.h"

/* Flight prediction, in metres and seconds. Keep operation order with Orbit._zonal_step
 * and Rocketry.zonal_accel. Guidance makes a whole prediction per call, over hundreds
 * of RK4 steps, so no per-stage state crosses the extension boundary. */
enum { FZ_EXTREMES = 0, FZ_PEAK = 1, FZ_COAST = 2 };

static double fz_radius(const double p[3]) {
	return sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
}

static void fz_accel(const double p[3], double mu, const double field[4], double a[3]) {
	double r2 = p[0] * p[0] + p[1] * p[1] + p[2] * p[2];
	double g = -mu / (r2 * sqrt(r2));
	for (int i = 0; i < 3; ++i) a[i] = p[i] * g;
	if (field[0] == 0.0) return;
	double x = p[0], y = p[2], z = -p[1];
	r2 = x * x + y * y + z * z;
	if (r2 < 1.0) return;
	double r = sqrt(r2), s = z / r, s2 = s * s;
	double re_r = field[0] / r;
	g = mu / r2;
	double j2 = field[1] * re_r * re_r;
	double j3 = field[2] * re_r * re_r * re_r;
	double j4 = field[3] * re_r * re_r * re_r * re_r;
	double fxy = -g * (1.5 * j2 * (1.0 - 5.0 * s2) + 2.5 * j3 * (3.0 * s - 7.0 * s2 * s)
		- 1.875 * j4 * (1.0 - 14.0 * s2 + 21.0 * s2 * s2));
	double fz = -g * (1.5 * j2 * (3.0 - 5.0 * s2) * s + 2.5 * j3 * (6.0 * s2 - 7.0 * s2 * s2 - 0.6)
		- 1.875 * j4 * s * (5.0 - 70.0 / 3.0 * s2 + 21.0 * s2 * s2));
	a[0] += fxy * x / r;
	a[2] += fxy * y / r;
	a[1] -= fz;
}

static void fz_step(double s[6], double mu, const double field[4], double h) {
	double k[4][6];
	for (int stage = 0; stage < 4; ++stage) {
		double tmp[6];
		double f = stage < 3 ? 0.5 : 1.0;
		for (int i = 0; i < 6; ++i)
			tmp[i] = s[i] + (stage > 0 ? k[stage - 1][i] * h * f : 0.0);
		for (int i = 0; i < 3; ++i) k[stage][i] = tmp[i + 3];
		fz_accel(tmp, mu, field, k[stage] + 3);
	}
	for (int i = 0; i < 6; ++i)
		s[i] += h / 6.0 * (k[0][i] + 2.0 * k[1][i] + 2.0 * k[2][i] + k[3][i]);
}

/* [length, request, μ, R, J2..4, span, step, stop radius, r xyz, v xyz,
 * result (time or lowest radius), highest radius]. A zero reference radius
 * selects a point mass. The coast writes its final state back to the r/v slots. */
void astrarium_flight_zonal(double *A) {
	if (A[0] != FZ_SIZE) return;
	double mu = A[2], span = A[7], h = A[8], target = A[9];
	if (!(h > 0.0) || !isfinite(span) || (span > 0.0 && !(span / h < 0x1p53))) {
		A[16] = A[1] == FZ_COAST ? INFINITY : NAN;
		A[17] = NAN;
		return;
	}
	const double *field = A + 3;
	double *s = A + 10;
	if (A[1] == FZ_EXTREMES || A[1] == FZ_PEAK) {
		double prev = fz_radius(s), lo = prev, hi = prev;
		int rising = 0;
		for (double steps = ceil(span / h); steps > 0.0; --steps) {
			fz_step(s, mu, field, h);
			double radius = fz_radius(s);
			if (A[1] == FZ_PEAK && rising && radius < prev) break;
			rising = rising || radius > prev;
			prev = radius;
			lo = jmin(lo, radius); hi = jmax(hi, radius);
		}
		A[16] = lo; A[17] = hi;
	} else if (A[1] == FZ_COAST) {
		double t = 0.0;
		while (t < span) {
			double dt = jmin(h, span - t), prev[6];
			if (target > 0.0) memcpy(prev, s, sizeof prev);
			fz_step(s, mu, field, dt);
			if (target > 0.0) {
				double r1 = fz_radius(s);
				if (r1 < target) {
					double r0 = fz_radius(prev);
					double t1 = dt * (r0 - target) / jmax(r0 - r1, 1e-9);
					fz_step(prev, mu, field, t1);
					double rr = fz_radius(prev);
					double rate = (prev[0] * prev[3] + prev[1] * prev[4] + prev[2] * prev[5]) / rr;
					if (rate < 0.0) {
						double t2 = (rr - target) / -rate;
						fz_step(prev, mu, field, t2);
						t1 += t2;
					}
					memcpy(s, prev, sizeof prev);
					A[16] = t + t1;
					return;
				}
			}
			t += dt;
		}
		A[16] = target <= 0.0 ? t : INFINITY;
	}
}
