#ifndef ASTRARIUM_KERNELS_H
#define ASTRARIUM_KERNELS_H

#include <limits.h>
#include <math.h>

enum { NB_HDR = 12, TR_PAT = 21, EN_HDR = 5, LV_HDR = 10, FZ_SIZE = 18, EDD_HDR = 4 };

void astrarium_nbody(double *state);
void astrarium_galaxy_tracers(double *state);
void astrarium_galaxy_encounter(double *state);
void astrarium_galaxy_eddington(double *state);
void astrarium_galaxy_live(double *state);
void astrarium_flight_zonal(double *state);

/* Validate serialized counts before converting or using them in offsets. */
static inline int kernel_count(double value) {
	return value >= 0.0 && value <= INT_MAX && value == (double)(int)value;
}

/* NaN-propagating min/max (fmin/fmax would drop NaN). */
static inline double jmin(double a, double b) { if (isnan(a) || isnan(b)) return NAN; return a < b ? a : b; }
static inline double jmax(double a, double b) { if (isnan(a) || isnan(b)) return NAN; return a > b ? a : b; }

#endif
