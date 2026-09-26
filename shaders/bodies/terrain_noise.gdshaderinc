// ============================================================================
// NOISE — the port of sim/terrain.js's NOISE_GLSL, split out of
// terrain.gdshaderinc because the cloud deck, the gas giants and the rings
// need the noise without the terrain (the web build imported NOISE_GLSL on
// its own for exactly those three).
//
// Value noise on a 3D domain. Sampling in 3D on the unit sphere is what keeps
// the surface free of the seam and the polar pinch that any equirectangular
// texture has; there is no (u, v) anywhere in the procedural path.
//
// PORT NOTE — sstep(). GLSL leaves smoothstep() UNDEFINED when edge0 >= edge1,
// and the web build leans on the reversed form everywhere ("1 at a, falling to
// 0 at b"). WebGL gets the textbook formula from every driver, so that is what
// the pictures were tuned against; sstep() IS that formula, written out, so a
// driver that takes the spec at its word cannot quietly change the answer.
// Every smoothstep in the body shaders goes through it.
// ============================================================================
#ifndef TERRAIN_NOISE_INC
#define TERRAIN_NOISE_INC

float sstep(float e0, float e1, float x) {
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

float hash(vec3 p) { return fract(sin(dot(p, vec3(17.1, 113.5, 7.9))) * 43758.5453); }
vec3 hash33(vec3 p) {
	return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)),
	                      dot(p, vec3(269.5, 183.3, 246.1)),
	                      dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
}
float noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i),                       hash(i + vec3(1.0, 0.0, 0.0)), f.x),
	               mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),
	               mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}
float fbm(vec3 p, int oct) {
	float v = 0.0;
	float a = 0.5;
	vec3 q = p;
	for (int i = 0; i < 8; i++) { if (i >= oct) break; v += a * noise(q); q *= 2.03; a *= 0.5; }
	return v;
}
// Ridged noise: |noise| folded about its midline, which turns the smooth
// humps of fBm into creased lines. Mountain chains are creases.
float ridged(vec3 p, int oct) {
	float v = 0.0;
	float a = 0.5;
	vec3 q = p;
	for (int i = 0; i < 8; i++) { if (i >= oct) break; v += a * (1.0 - abs(noise(q) * 2.0 - 1.0)); q *= 2.11; a *= 0.5; }
	return v;
}
// Domain warp — displace the sample point by another noise field before
// evaluating. Un-warped fBm is isotropic and reads as cloud; warped fBm has
// the stretched, folded, sheared look of material that has been moved
// around, which is what crust is.
vec3 warp(vec3 p, float amt) {
	return p + amt * vec3(fbm(p + 19.3, 4), fbm(p + 41.7, 4), fbm(p + 73.1, 4));
}

#endif
