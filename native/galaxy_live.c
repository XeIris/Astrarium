#include <stdlib.h>
#include <string.h>
#include "kernels.h"

/* Live galaxies: every particle pulls on every other through a Barnes–Hut octree of
 * monopole cells with Plummer softening, kick–drift–kick at a fixed step.
 * sim/galaxy/gal_live.gd is the twin and builds and traverses the same tree in the
 * same order. Each particle's force is summed by one thread alone, so the result does
 * not depend on how many threads ran.
 * Buffer: [0] length [1] n [2] k steps [3] dt [4] θ [5] G [6] accelerations valid
 * (in/out) [7] potentials wanted [8] luminous count nl [9] threads (in: 0 for all
 * cores; out: used, or −1 when a step could not allocate its tree and the run stopped
 * there, with [2] the steps completed), then LV_STRIDE per particle: x y z vx vy vz ax ay az m ε φ, then
 * 2·nl doubles holding the first nl particles' float32 (x, y, z, tag) for drawing. */
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
	double m, cx, cy, cz, ropen2, eps;
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

/* First moments are needed only by the parent during the build. Keep them off
 * the nodes walked by the force workers and sum children in octant order. */
static void lv_fill(LvTree *T, int nd, int lo, int hi, double x0, double y0, double z0,
		double half, int depth, double moment[3]) {
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
			double child_moment[3];
			lv_fill(T, first + k, a, a + cnt[c], x0 + ((c & 1) ? h : -h),
				y0 + ((c & 2) ? h : -h), z0 + ((c & 4) ? h : -h), h, depth + 1, child_moment);
			if (T->failed) return;
			const LvNode *C = &T->nodes[first + k];
			m += C->m;
			sx += child_moment[0]; sy += child_moment[1]; sz += child_moment[2];
			if (C->eps > eps) eps = C->eps;
			a += cnt[c];
			k++;
		}
	}
	LvNode *N = &T->nodes[nd];
	N->m = m; N->eps = eps;
	moment[0] = sx; moment[1] = sy; moment[2] = sz;
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
	double moment[3];
	lv_fill(T, root, 0, n, 0.5 * (lo[0] + hi[0]), 0.5 * (lo[1] + hi[1]), 0.5 * (lo[2] + hi[2]), half, 0, moment);
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

typedef struct {
	double x[LV_GROUP], y[LV_GROUP], z[LV_GROUP], e[LV_GROUP];
	double ax[LV_GROUP], ay[LV_GROUP], az[LV_GROUP];
} LvTargets;

static inline void lv_accumulate(LvTargets *B, int k, double cx, double cy, double cz, double gm, double eq) {
	for (int a = 0; a < k; a++) {
		double s = B->e[a] > eq ? B->e[a] : eq;
		double dx = cx - B->x[a], dy = cy - B->y[a], dz = cz - B->z[a];
		double r2 = dx * dx + dy * dy + dz * dz + s * s;
		double r = LV_SQRT(r2);
		double f = gm / (r2 * r);
		B->ax[a] += f * dx; B->ay[a] += f * dy; B->az[a] += f * dz;
	}
}

/* Accept a cell when its opening sphere misses the whole group's box. The order
 * of accepted sources is also the summation order, with or without a list. */
static void lv_walk(const LvTree *T, const double *P, int g, LvList *list, LvTargets *targets, double G) {
	const LvNode *Gn = &T->nodes[g];
	const double *p0 = P + LV_STRIDE * T->idx[Gn->lo];
	double lx = p0[0], ly = p0[1], lz = p0[2], hx = p0[0], hy = p0[1], hz = p0[2];
	for (int q = Gn->lo; q < Gn->hi; q++) {
		const double *p = P + LV_STRIDE * T->idx[q];
		if (targets) {
			int a = q - Gn->lo;
			targets->x[a] = p[0]; targets->y[a] = p[1]; targets->z[a] = p[2]; targets->e[a] = p[10];
			targets->ax[a] = 0.0; targets->ay[a] = 0.0; targets->az[a] = 0.0;
		}
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
	int count = Gn->hi - Gn->lo;
	if (list) list->len = 0;
	while (sp > 0) {
		const LvNode *N = &T->nodes[stack[--sp]];
		double gx = lv_gap(N->cx, lx, hx), gy = lv_gap(N->cy, ly, hy), gz = lv_gap(N->cz, lz, hz);
		if (gx * gx + gy * gy + gz * gz > N->ropen2) {
			if (targets) lv_accumulate(targets, count, N->cx, N->cy, N->cz, G * N->m, N->eps);
			else lv_push(list, N->cx, N->cy, N->cz, N->m, N->eps, -1);
		} else if (N->count == 0) {
			for (int q = N->lo; q < N->hi; q++) {
				int j = T->idx[q];
				const double *pj = P + LV_STRIDE * j;
				if (targets) lv_accumulate(targets, count, pj[0], pj[1], pj[2], G * pj[9], pj[10]);
				else lv_push(list, pj[0], pj[1], pj[2], pj[9], pj[10], j);
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
		int node = F->groups[g];
		const LvNode *group = &F->T->nodes[node];
		/* Keep the list for potential diagnostics or a depth-capped leaf that
		 * needs multiple blocks of targets. Ordinary force groups stream it. */
		if (!F->want_phi && group->hi - group->lo <= LV_GROUP) {
			LvTargets targets;
			lv_walk(F->T, F->P, node, NULL, &targets, F->G);
			for (int q = group->lo; q < group->hi; q++) {
				double *p = F->P + LV_STRIDE * F->T->idx[q];
				int a = q - group->lo;
				p[6] = targets.ax[a]; p[7] = targets.ay[a]; p[8] = targets.az[a];
			}
		} else {
			lv_walk(F->T, F->P, node, &L, NULL, F->G);
			if (L.failed) { atomic_store(&F->failed, 1); break; }
			lv_group(F->T, F->P, node, &L, F->G, F->want_phi);
		}
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

void astrarium_galaxy_live(double *A) {
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
