#include <limits.h>
#include <stdlib.h>
#include "kernels.h"

/* GalEddington builds the potential in GDScript. Here the input is length, grid
 * count, speed row count, speed samples per row, then psi, dρ/dψ, row psi.
 * The output follows those inputs: f at each grid point and a CDF per row. */
static double distribution_at(double e, const double *psi, const double *f, int n) {
	if (e <= psi[n - 1]) return 0.0;
	if (e >= psi[0]) return f[0];
	int lo = 0, hi = n - 1;
	while (hi - lo > 1) {
		int mid = (lo + hi) >> 1;
		if (psi[mid] > e) lo = mid;
		else hi = mid;
	}
	double w = (e - psi[hi]) / (psi[lo] - psi[hi]);
	return f[hi] + w * (f[lo] - f[hi]);
}

void astrarium_galaxy_eddington(double *state) {
	if (!(state[1] >= 2 && state[1] <= state[0] && state[2] >= 1 && state[2] <= state[0]
		&& state[3] >= 2 && state[3] <= state[0])) return;
	int n = (int)state[1], rows = (int)state[2], samples = (int)state[3];
	if (n != state[1] || rows != state[2] || samples != state[3]) return;
	long long length = EDD_HDR + 3LL * n + rows + (long long)rows * samples;
	if (length > INT_MAX || length != state[0]) return;
	const double *psi = state + EDD_HDR;
	const double *drho = psi + n;
	const double *row_psi = drho + n;
	double *f = state + EDD_HDR + 2 * n + rows;
	double *cdf = f + n;
	double *integral = malloc((size_t)n * sizeof(double));
	if (!integral) return;

	for (int k = 0; k < n; k++) {
		double e = psi[k];
		double sum = 0.0;
		for (int j = k; j < n - 1; j++) {
			double g = 0.5 * (drho[j] + drho[j + 1]);
			sum += g * 2.0 * (sqrt(jmax(e - psi[j + 1], 0.0)) - sqrt(jmax(e - psi[j], 0.0)));
		}
		integral[k] = sum;
	}
	for (int k = 0; k < n; k++) {
		int lo = k > 0 ? k - 1 : 0;
		int hi = k < n - 1 ? k + 1 : n - 1;
		f[k] = jmax((integral[lo] - integral[hi]) / (psi[lo] - psi[hi]), 0.0);
	}
	free(integral);

	for (int j = 0; j < rows; j++) {
		double *row = cdf + j * samples;
		double acc = 0.0, prev = 0.0;
		row[0] = 0.0;
		for (int q = 1; q < samples; q++) {
			double u = (double)q / (samples - 1);
			double p = u * u * distribution_at(row_psi[j] * (1.0 - u * u), psi, f, n);
			acc += 0.5 * (p + prev) / (samples - 1);
			prev = p;
			row[q] = acc;
		}
		for (int q = 0; q < samples; q++) row[q] /= jmax(acc, 1e-300);
	}
	state[0] = 0.0;
}
