#include <stdlib.h>
#include "kernels.h"
#include "workers.h"

/* Galactic tracers (sim/galaxy/gal_tracers.gd is the GDScript twin; the two
 * must stay bit-identical, so every expression keeps its order there).
 * Massless particles in a static axisymmetric potential plus rotating patterns,
 * drift–kick–drift at a fixed step, each tracer taking all k steps in turn.
 * Buffer: [0] length, [1] n, [2] k, [3] dt, [4] t_start, [5] patterns, [6] table
 * size, [7] steps taken so far, [8..20] the axisymmetric kernel (GalPotential.Kernel),
 * then 12 per pattern,
 * the bulge table and its derivative, positions, velocities and work, n each ×3,
 * ×3 and ×1. Work accumulates ∫∂Φ/∂t dt, so E − W is each tracer's invariant. */
#define TR_AXIS 8
#define TR_PSTRIDE 12
#define TR_TERMS 6
#define TR_WORKERS 4
#define TR_PARALLEL_MIN 24000

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

typedef struct {
	double *data;
	const double *growth;
	int start, end;
} TracerBatch;

static void tr_integrate(const TracerBatch *batch) {
	double *A = batch->data;
	const double *G = batch->growth;
	int n = (int)A[1], k = (int)A[2], np = (int)A[5], tn = (int)A[6];
	double dt = A[3], h = dt * 0.5;
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
	for (int i = batch->start; i < batch->end; i++) {
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
				const double *gg = G + (s * np + j) * TR_TERMS;
				double gs = gg[0];
				if (gs == 0.0 && gg[1] == 0.0) continue;
				double R2 = x * x + z * z;
				double R = sqrt(R2);
				if (P[0] == 0.0) {
					/* Dehnen bar: Φ = A Q h(r), Q = (x² − z²) cos 2φb + 2xz sin 2φb, h = g(r)/r². */
					if (r < 1e-9) continue;
					double rb = P[6], rb3 = gg[4], c2 = gg[2], s2 = gg[3];
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
					double nn = P[6], sa = gg[4], ta = gg[5], r0 = P[8], rs = P[9], H = P[10];
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
}

static WORKER_RETURN tr_worker(void *arg) {
	tr_integrate((const TracerBatch *)arg);
	return WORKER_DONE;
}

void astrarium_galaxy_tracers(double *A) {
	int n = (int)A[1], k = (int)A[2], np = (int)A[5], tn = (int)A[6];
	/* The buffer is exactly its header's counts long, or nothing is touched. */
	long long need = TR_PAT + (long long)TR_PSTRIDE * np + 2LL * tn + 7LL * n;
	if (n < 0 || k < 0 || np < 0 || tn < 0 || need != (long long)A[0]) return;
	double dt = A[3], t_start = A[4];
	/* A step's time from its index, so it does not depend on how steps are batched. */
	double steps0 = A[7];
	/* Share the pattern's phase, growth and shape terms across all tracers. */
	double *G = (double *)calloc((size_t)k * (size_t)np * (size_t)TR_TERMS + 1, sizeof(double));
	if (!G) return;
	for (int s = 0; s < k; s++) {
		double tm = t_start + (steps0 + (double)s + 0.5) * dt;
		for (int j = 0; j < np; j++) {
			const double *P = A + TR_PAT + TR_PSTRIDE * j;
			double ang = P[2] + P[1] * tm;
			double *g = G + (s * np + j) * TR_TERMS;
			g[0] = tr_growth(P, tm);
			g[1] = tr_growth_rate(P, tm);
			if (P[0] == 0.0) {
				g[2] = cos(2.0 * ang);
				g[3] = sin(2.0 * ang);
				g[4] = P[6] * P[6] * P[6];
			} else {
				g[2] = ang;
				g[4] = sin(P[7]);
				g[5] = tan(P[7]);
			}
		}
	}
	/* One tracer owns its state for the entire batch. Use spare cores when
	 * that work can pay for creating workers, including its pattern forces. */
	int threads = 1;
	if (n >= 64 && (double)n * k * (np + 1.0) >= TR_PARALLEL_MIN) {
		threads = worker_cores();
		if (threads > TR_WORKERS) threads = TR_WORKERS;
	}
	TracerBatch slices[TR_WORKERS];
	WorkerThread workers[TR_WORKERS - 1];
	int started[TR_WORKERS - 1];
	for (int i = 0; i < threads; i++) {
		slices[i] = (TracerBatch){A, G, (int)((long long)i * n / threads),
			(int)((long long)(i + 1) * n / threads)};
	}
	for (int i = 0; i < threads - 1; i++) {
		started[i] = worker_start(&workers[i], tr_worker, &slices[i]);
	}
	tr_integrate(&slices[threads - 1]);
	for (int i = 0; i < threads - 1; i++) {
		if (started[i]) worker_join(workers[i]);
		else tr_integrate(&slices[i]);
	}
	free(G);
}
