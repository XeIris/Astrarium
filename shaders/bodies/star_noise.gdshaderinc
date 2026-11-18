// Noise and radiometry shared by the photosphere, the corona and the prominences.
// The hash is integer (PCG3D, Jarzynski & Olano 2020): granulation is sampled at
// hundreds of cells per radius, where a sin() hash loses its precision and tiles.
#ifndef STAR_NOISE_INC
#define STAR_NOISE_INC

uvec3 sn_pcg3d(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> uvec3(16u);
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return v;
}
// Cell hash; the offset keeps negative lattice coordinates distinct.
vec3 sn_hash3(vec3 i) { return vec3(sn_pcg3d(uvec3(ivec3(i) + 65536)) >> uvec3(8u)) / 16777216.0; }
float sn_hash(vec3 i) { return sn_hash3(i).x; }

float sn_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(sn_hash(i),                       sn_hash(i + vec3(1.0, 0.0, 0.0)), f.x),
	               mix(sn_hash(i + vec3(0.0, 1.0, 0.0)), sn_hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(sn_hash(i + vec3(0.0, 0.0, 1.0)), sn_hash(i + vec3(1.0, 0.0, 1.0)), f.x),
	               mix(sn_hash(i + vec3(0.0, 1.0, 1.0)), sn_hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

float sn_fbm(vec3 p, int oct) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= oct) break;
		v += a * sn_noise(p);
		p = p * 2.03 + vec3(1.7, 9.2, 4.1);
		a *= 0.5;
	}
	return v;
}

// Worley F1, F2 with feature points that wander on closed paths, so cells change shape
// without popping. Returns (F1, F2).
vec2 sn_cells(vec3 p, float t) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	float f1 = 8.0;
	float f2 = 8.0;
	for (int x = -1; x <= 1; x++)
	for (int y = -1; y <= 1; y++)
	for (int z = -1; z <= 1; z++) {
		vec3 g = vec3(float(x), float(y), float(z));
		vec3 h = sn_hash3(i + g);
		vec3 o = 0.5 + 0.42 * sin(t * (0.7 + 0.6 * h.zxy) + 6.2831853 * h);
		float d = length(g + o - f);
		if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
	}
	return vec2(f1, f2);
}

// A granule field with zero mean and unit variance: each cell domed, brightest over its
// upflow and darkening into a narrow lane. The mean (0.33) and spread (0.195) are
// measured over the lattice.
float sn_granule(vec2 c) {
	float u = c.x / max(c.x + c.y, 1e-6);
	float dome = pow(max(1.0 - 2.0 * u, 0.0), 0.55);
	float lane = clamp((c.y - c.x) / 0.12, 0.0, 1.0);
	return (dome * (0.55 + 0.45 * lane) - 0.33) / 0.195;
}

// B_λ(T)/B_λ(T0) at the sRGB primaries' effective wavelengths (612, 549, 465 nm).
// Spots, faculae and flare kernels take their colour and contrast from this.
const vec3 SN_C2_LAMBDA = vec3(23510.0, 26208.0, 30942.0);   // hc/(kλ), K
vec3 sn_planck_ratio(float T, float T0) {
	return (exp(SN_C2_LAMBDA / max(T0, 800.0)) - 1.0) / (exp(SN_C2_LAMBDA / max(T, 800.0)) - 1.0);
}

#endif
