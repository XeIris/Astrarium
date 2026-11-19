#include <string.h>
#include "kernels.h"

/* Galaxy encounters (sim/galaxy/gal_encounter.gd is the GDScript twin; the two must
 * stay bit-identical, so every expression keeps its order there; only sqrt is called).
 * Massless stars in rigid galaxies about moving centres, drift–kick–drift at a fixed
 * step. Buffer: [0] length, [1] n, [2] k, [3] dt, [4] galaxies, EN_STRIDE per galaxy
 * (halo G M, a; disc G M, a, b; bulge G M, a; axes x, y, z), the centres at each
 * mid-step (k × galaxies × 3), positions and velocities (n × 3 each), then 2n doubles
 * the kernel fills with each star's float32 (x, y, z, galaxy) for drawing. */
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

void astrarium_galaxy_encounter(double *A) {
	if (!kernel_count(A[1]) || !kernel_count(A[2]) || !kernel_count(A[4])) return;
	int n = (int)A[1], k = (int)A[2], ng = (int)A[4];
	long long fixed = EN_HDR + (long long)EN_STRIDE * ng + 8LL * n;
	if (fixed > A[0] || (ng > 0 && k > (A[0] - fixed) / (3LL * ng))) return;
	if (fixed + 3LL * k * ng != A[0]) return;
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
	unsigned char *draw = (unsigned char *)(vel + 3 * n);
	for (int i = 0; i < n; i++) {
		float xyz[3] = {(float)pos[3 * i], (float)pos[3 * i + 1], (float)pos[3 * i + 2]};
		memcpy(draw + 4 * sizeof(float) * i, xyz, sizeof xyz);
	}
}
