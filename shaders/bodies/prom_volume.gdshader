// PLASMA ON THE FIELD as a volume: loop arcades, flux ropes and hedgerow prominences.
// What a telescope records is the line-of-sight integral of emission and absorption
// through plasma threaded on the field; much of what reads as a loop is a fold in a
// sheet of emission seen edge-on (Malanushenko et al. 2022). So the density lives in
// field-aligned coordinates (ridged noise stretched along the field makes wrinkled,
// field-aligned sheets), and is marched from the camera through a box in the arcade's
// frame, stopped at the photosphere and the depth buffer. Cool (10⁴ K) material is
// optically thick in the lines: it glows off the limb and absorbs against the disc, a
// filament. Hot loops are thin. blend_premul_alpha: the colour pass writes emission
// over the transmitted background (rgb + dst·(1 − a)); the temperature pass replaces.
// Geometry from sim/prominence.gd; physics in docs/physics/stellar-surfaces.md.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, fog_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler3D uNoise : filter_linear, repeat_enable;

// The box the march runs through, in the arcade's frame (the star's centre at (0, −uR, 0)).
uniform vec3 uBoxMin = vec3(-1.0);
uniform vec3 uBoxMax = vec3(1.0);
uniform float uR = 1.0;
// 0: loops across the neutral line; 1: a flux rope along it; 2: a hedgerow curtain.
uniform float uKind = 0.0;
// In stellar radii. Arcade: (half-length, half-width, outer loop height, apex shear).
// Rope: (half-length, axis height, tube radius, writhe). Hedgerow: (half-length,
// thickness, height, sway).
uniform vec4 uGeo = vec4(0.3, 0.1, 0.2, 0.0);
// (strand frequency in noise tiles per stellar radius, twist turns end to end, axis
// shear across the neutral line, inner loop of an arcade as a fraction of the outer)
uniform vec4 uGeo2 = vec4(20.0, 0.5, 0.0, 0.35);
uniform float uErupt = 0.0;
uniform float uTime = 0.0;
uniform float uAmp = 1.0;
// 0: brightest at the feet (an impulsive flare); 1: along the loop and at the top.
uniform float uApex = 0.0;
// Condensations streaming along the field, in loop lengths per second.
uniform float uFlow = 0.35;
// Visible-light gain: coronal loops are nearly invisible in white light.
uniform float uGlow = 1.0;
// Line opacity at unit density, per stellar radius; 0 for hot, thin loops.
uniform float uKappa = 0.0;
// How far a hot loop system has cooled toward chromospheric temperatures (0..1): its
// colour follows, from the hot footpoint colour to the line emission's.
uniform float uCooled = 0.0;
uniform float uPlasmaT = 1.0e4;
uniform float uSeed = 0.0;
uniform vec3 uCool = vec3(1.0, 0.30, 0.09);
uniform vec3 uHot = vec3(1.0);

varying vec3 vObj;
varying flat vec3 vCam;
varying flat float vScale;

// Display brightness of optically thick material (its source function) and of thin
// emission per unit emission measure, both before uGlow.
const float SRC = 2.2;
const float THIN = 110.0;
// The share of the disc's light the cool material can hide: prominences are thick in
// the lines and thin in the continuum, so a filament darkens only the line light.
const float LINE_SHARE = 0.65;

void vertex() {
	// A unit box (±0.5), stretched over the bounds; back faces, so it covers every pixel
	// the volume can reach, the camera inside it or not.
	vObj = mix(uBoxMin, uBoxMax, VERTEX + 0.5);
	VERTEX = vObj;
	vCam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vScale = length(MODEL_MATRIX[0].xyz);
}

// White-noise jitter: an ordered dither shows as a cross-hatch where a ray only grazes thin
// strands.
float jitter(vec2 p) {
	uvec2 q = uvec2(ivec2(p) + 32768);
	uint h = q.x * 1664525u + q.y * 22695477u + 1013904223u;
	h ^= h >> 16u; h *= 2246822519u; h ^= h >> 13u;
	return float(h & 0xffffffu) / 16777216.0;
}

float tex(vec3 p) { return texture(uNoise, p).r; }

// Plasma on the field is filamentary at every scale and fills little of its volume, so a
// sight line through it crosses bright strands and dark gaps rather than averaging to a
// fog. Three scales: clumps a few to a structure, sheets (the ridges of the noise, where
// it crosses its mean, are surfaces; stretched along the field they become field-aligned
// sheets that fold, and brighten where a sight line runs along one), and finer threads.
// `soft` (0..1) blunts what falls below a pixel into the glow it averages to.
float plasma(vec3 p, float sharp, float soft) {
	float big = 0.3 + 0.7 * smoothstep(0.3, 0.75, tex(p * 0.21 + vec3(0.71, 0.13, 0.42)));
	float k = mix(sharp, 1.5, soft);
	float med = 1.0 - abs(2.0 * tex(p) - 1.0);
	float fine = 1.0 - abs(2.0 * tex(p * vec3(2.31, 2.17, 1.43) + vec3(0.31, 0.57, 0.11)) - 1.0);
	return big * (0.025 + pow(med, k) + 0.6 * pow(fine, k * 1.5) * (1.0 - 0.7 * soft));
}

// Flux tubes: where two families of sheets cross, a line; stretched along the field, a
// strand. A loop arcade is a bundle of these.
float tubes(vec3 p, float sharp, float soft) {
	float big = 0.35 + 0.65 * smoothstep(0.3, 0.75, tex(p * 0.23 + vec3(0.19, 0.83, 0.47)));
	float k = mix(sharp, 1.2, soft);
	float a = 1.0 - abs(2.0 * tex(p) - 1.0);
	float b = 1.0 - abs(2.0 * tex(p * vec3(1.37, 1.41, 1.0) + vec3(0.53, 0.29, 0.61)) - 1.0);
	return big * (0.05 + pow(a * b, k));
}

// Flat coordinates: x along the neutral line, h height, z across it, in stellar radii
// (the inverse of the gnomonic map the geometry is written in).
vec3 flat_of(vec3 p) {
	vec3 q = (p - vec3(0.0, -uR, 0.0)) / uR;
	float rr = length(q);
	vec3 d = q / rr;
	float dy = max(d.y, 1e-3);
	return vec3(d.x / dy, rr - 1.0, d.z / dy);
}

// Each structure returns its envelope alone when `full` is false (no texture reads), else
// its density.

// Loops across the neutral line, nested: field line ρ is a semi-ellipse of half-width
// ρW and height ρH, its apex sheared along the line.
float arcade(vec3 f, bool full, float soft, out float s, out float fp, out float lit) {
	float L = uGeo.x, W = uGeo.y, H = uGeo.z;
	float h = max(f.y, 0.0);
	float zw = f.z / W, hh = h / H;
	float rho = length(vec2(zw, hh));
	float th = atan(hh, -zw);
	s = th / PI;
	lit = 1.0;
	fp = exp(-s * 5.5) + exp(-(1.0 - s) * 5.5);
	float x0 = f.x - uGeo.w * sin(th) * rho;
	float xe = x0 / L;
	float span = 0.5 * (W + H);
	if (abs(xe) > 1.0) return 0.0;
	// The neutral line has ends, and the field closes down lower at them.
	float rr = rho / (0.42 + 0.58 * sqrt(max(1.0 - xe * xe, 0.0)));
	float env = smoothstep(uGeo2.w - 0.2, uGeo2.w + 0.05, rr) * (1.0 - smoothstep(0.7, 1.05, rr))
	          * (1.0 - smoothstep(0.8, 1.0, abs(xe)));
	if (!full || env < 0.01) return env;
	float K = uGeo2.x;
	vec3 q = vec3(x0 * K, rr * span * K * 0.8, s * 0.45) + uSeed;
	// Successive reconnection builds the arcade in generations: nested shells of loops,
	// each rippled along the neutral line, threaded with strands.
	float gen = rr * 4.5 + 1.3 * (tex(vec3(x0 * K * 0.15, rr * 1.3, 0.6) + uSeed) - 0.5);
	float shell = 0.5 + 0.5 * cos(2.0 * PI * gen);
	shell *= shell * shell;
	float n = (0.2 + shell) * (0.2 + 2.2 * tubes(q, 2.2, soft));
	// Each loop lights a little after its neighbour along the neutral line.
	float stagger = clamp(uAmp * 2.5 - abs(xe) * 0.55, 0.0, 1.0);
	float along = mix(0.30 + 0.70 * fp, 0.40 + 0.45 * sin(PI * s) + 0.35 * fp, uApex);
	// Coronal rain: condensations fall from the top down both legs.
	float u = abs(s - 0.5);
	float knot = tex(vec3(x0 * K * 0.5, rr * 2.7, u * 6.0 - uTime * uFlow * 1.8) + uSeed * 1.3);
	float flow = 0.5 + 1.1 * smoothstep(0.5, 0.78, knot);
	lit = along * stagger;
	return env * n * flow * smoothstep(0.0, 0.004, f.y);
}

// A flux rope along the neutral line: threads wound about an arched axis, the cool
// material lying in the dips of the twisted field below it and the cavity above nearly
// empty. As it erupts the twist turns into writhe (the axis kinks into an S), the
// threads fray, and the material drains down the legs.
float rope(vec3 f, bool full, float soft, out float s, out float fp, out float lit) {
	float Lh = uGeo.x, H = uGeo.y, A = uGeo.z;
	float h = max(f.y, 0.0);
	vec2 e = vec2(f.x / Lh, h / H);
	float th = atan(e.y, -e.x);
	s = th / PI;
	lit = 1.0;
	fp = exp(-s * 6.0) + exp(-(1.0 - s) * 6.0);
	vec2 ax = vec2(-Lh * cos(th), H * sin(th));
	float u = (length(e) - 1.0) * length(ax);
	float v = f.z - (-uGeo2.z * cos(th) + uGeo.w * sin(2.0 * th));
	float a0 = A * (0.45 + 0.55 * sin(th));
	float r = length(vec2(u, v));
	float a = r / a0;
	// Out to where the tube's profile has fallen to ~0.3%.
	float k = mix(2.2, 1.1, uErupt);
	if (a * a * k > 5.8) return 0.0;
	if (!full) return 1.0;
	float tw = -2.0 * PI * uGeo2.y * s;
	vec2 w = mat2(vec2(cos(tw), sin(tw)), vec2(-sin(tw), cos(tw))) * vec2(u, v);
	float K = uGeo2.x;
	vec3 q = vec3(w * K * 0.55, s * 0.9) + uSeed;
	float n = plasma(q, 2.6 + 2.0 * uErupt, soft);
	// The tube's edge breaks into separate strands as it expands.
	float tube = exp(-a * a * k) * (0.55 + 0.7 * tex(q * 0.31 + 0.5));
	float dip = mix(1.0, 0.25 + 0.75 * smoothstep(0.45, -0.55, u / max(r, 1e-6)), 0.7 * (1.0 - uErupt));
	float drain = tex(vec3(w * K * 0.4, abs(s - 0.5) * 5.0 - uTime * uFlow * 1.5) + uSeed * 0.7);
	float flow = 0.45 + 1.0 * smoothstep(0.48, 0.78, drain);
	// An erupting rope drains: the legs stay lit, the apex thins.
	float legs = mix(1.0, 0.35 + 0.65 * abs(s * 2.0 - 1.0), clamp(uErupt * 0.7, 0.0, 1.0));
	// The event's fade is the material draining away, not dimming.
	return tube * n * dip * flow * legs * clamp(uAmp * 1.4, 0.0, 1.0) * smoothstep(0.0, 0.004, f.y);
}

// A hedgerow prominence (Berger et al. 2008, 2010): a thin curtain of near-vertical
// threads with a ragged top and material falling through it, standing on feet in the
// chromosphere, with a dark bubble at its base from which plumes rise (Rayleigh–Taylor).
float hedge(vec3 f, bool full, float soft, out float s, out float fp, out float lit) {
	float Lh = uGeo.x, Th = uGeo.y, H = uGeo.z;
	float xe = f.x / Lh;
	fp = 0.0;
	lit = 1.0;
	s = f.y / H;
	if (abs(xe) > 1.0 || f.y < 0.0 || f.y > 1.75 * H) return 0.0;
	if (abs(f.z) > uGeo.w + 2.2 * Th) return 0.0;
	if (!full) return 1.0;
	float env = sqrt(max(1.0 - xe * xe, 0.0));
	float top = H * pow(env, 0.6) * (0.45 + 1.1 * tex(vec3(f.x * 2.2 + uSeed, 0.3, uTime * 0.004)));
	s = f.y / max(top, 1e-5);
	if (s > 1.15) return 0.0;
	float zc = uGeo.w * (tex(vec3(f.x * 2.6 + uSeed, f.y * 3.5, 0.7)) - 0.5) * 2.0;
	float dz = (f.z - zc) / Th;
	float sheet = exp(-dz * dz);
	if (sheet < 0.01) return 0.0;
	float K = uGeo2.x;
	// Threads nearly vertical, so the noise is stretched along h; the pattern falls.
	vec3 q = vec3(f.x * K, f.z * K * 0.6, f.y * K * 0.10 + uTime * uFlow * 0.35) + uSeed;
	float n = plasma(q, 3.0, soft) + 0.05;
	float knot = tex(vec3(f.x * K * 0.6, f.z * K * 0.4, f.y * K * 0.35 + uTime * uFlow * 1.4) + uSeed * 2.1);
	n *= 0.55 + 1.1 * smoothstep(0.5, 0.8, knot);
	// The bubble under it and the dark plumes rising from it.
	float xb = Lh * (tex(vec3(uSeed * 0.37, 0.11, 0.9)) - 0.5);
	float rb = 0.32 * H;
	float bub = 1.0 - smoothstep(0.75, 1.0, length(vec2((f.x - xb) / (1.4 * rb), f.y / rb)));
	float plume = smoothstep(0.56, 0.74, tex(vec3(f.x * K * 0.22, f.y * K * 0.06 - uTime * uFlow * 0.25, 0.37) + uSeed))
	            * (1.0 - smoothstep(0.25, 0.7, s)) * (1.0 - smoothstep(rb * 0.8, rb * 3.0, abs(f.x - xb)));
	// Feet: down near the chromosphere the curtain stands on a few barbs.
	float feet = mix(smoothstep(0.52, 0.68, tex(vec3(f.x * 5.0 + uSeed, 0.9, 0.1))), 1.0, smoothstep(0.04, 0.28, s));
	return sheet * n * (1.0 - smoothstep(0.72, 1.08, s)) * (1.0 - 0.92 * bub) * (1.0 - 0.8 * plume) * feet;
}

// Returns the density (structure: what absorbs, and emits as its square) and writes `lit`,
// the excitation along the field (heating at the feet, the order loops light in).
float density(vec3 f, bool full, float soft, out float s, out float fp, out float lit) {
	lit = 1.0;
	if (uKind > 1.5) return hedge(f, full, soft, s, fp, lit);
	if (uKind > 0.5) return rope(f, full, soft, s, fp, lit);
	return arcade(f, full, soft, s, fp, lit);
}

void fragment() {
	bool temp = is_temp_pass(CAMERA_VISIBLE_LAYERS);
	// Hot, thin loops are all but invisible in white light; they are drawn where they
	// show, in the bands the temperature pass feeds.
	if (!temp && uGlow < 0.05 && uKappa <= 0.0) discard;
	vec3 ro = vCam;
	vec3 rd = normalize(vObj - vCam);
	vec3 inv = 1.0 / (rd + vec3(1e-12));
	vec3 ta = (uBoxMin - ro) * inv, tb = (uBoxMax - ro) * inv;
	vec3 tlo = min(ta, tb), thi = max(ta, tb);
	float t0 = max(max(max(tlo.x, tlo.y), tlo.z), 0.0);
	float t1 = min(min(thi.x, thi.y), thi.z);
	// The photosphere ends the ray, and so does anything nearer in the depth buffer.
	vec3 oc = ro - vec3(0.0, -uR, 0.0);
	float bq = dot(oc, rd);
	float disc = bq * bq - (dot(oc, oc) - uR * uR);
	if (disc > 0.0) {
		float ts = -bq - sqrt(disc);
		if (ts > 0.0) t1 = min(t1, ts);
	}
	float d = texture(uDepth, SCREEN_UV).r;
	vec4 vv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	t1 = min(t1, length(vv.xyz / vv.w) / max(vScale, 1e-12));
	if (t1 <= t0) discard;
	// Whether the disc is behind this ray, from its closest approach to the centre.
	float b = sqrt(max(dot(oc, oc) - bq * bq, 0.0));
	float onDisc = bq < 0.0 ? 1.0 - smoothstep(uR * 0.985, uR * 1.01, b) : 0.0;

	// One pixel at the volume, in stellar radii, and the noise feature it is set against.
	float pxA = 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
	float K = uGeo2.x;
	// The rope's strands are drawn at 0.55 of the strand frequency.
	float feature = 0.25 / (K * (uKind > 0.5 && uKind < 1.5 ? 0.55 : 1.0));
	// Even steps a fraction of a strand apart (no finer than a pixel), as many as the chord
	// needs up to a cap; the envelope test is cheap, so density is only read inside it.
	// The temperature pass needs only the coverage, so it takes long steps.
	float dtf = max(feature * 0.4 * uR, 0.6 * pxA * 0.5 * (t0 + t1));
	int N = temp ? 24 : clamp(int(ceil((t1 - t0) / dtf)), 24, 112);
	float dt = (t1 - t0) / float(N);
	float ds = dt / uR;
	float jit = jitter(FRAGCOORD.xy);
	float hotK = uKind > 1.5 ? 0.0 : (uKind > 0.5 ? 0.35 : 0.75);
	// Loops are thin and need the gain; prominence material is seen by its opacity.
	float thinK = THIN * (uKind > 0.5 ? 1.0 : 1.3);
	vec3 col = vec3(0.0);
	float T = 1.0;
	float em = 0.0;
	float sd; float fpd; float ld;
	for (int i = 0; i < 112; i++) {
		if (i >= N) break;
		float tt = t0 + (float(i) + jit) * dt;
		vec3 f = flat_of(ro + rd * tt);
		if (density(f, false, 0.0, sd, fpd, ld) <= 0.0) continue;
		float pix = pxA * tt / uR;
		float soft = smoothstep(0.35, 1.4, pix / feature);
		float s; float fp; float lit;
		float n = density(f, true, soft, s, fp, lit);
		if (n < 1e-3) continue;
		// Hot where the beam lands, cool higher up.
		float hm = uKind > 0.5 ? hotK * fp * fp : clamp(hotK * fp + 0.25 * uErupt, 0.0, 1.0);
		vec3 c = mix(uCool, uHot, hm * (1.0 - 0.8 * uCooled));
		float a = 1.0 - exp(-uKappa * n * ds);
		float thin = n * n * ds * lit;
		col += T * c * (SRC * a * lit + thinK * thin);
		em += T * thin;
		T *= 1.0 - a;
		if (T < 0.03) break;
	}
	float cover = 1.0 - T;
	if (temp) {
		// Flare and active-region loops are the brightest things on the star in X-ray
		// wherever they are; cool material in front of the disc leaves the photosphere's
		// value.
		if (max(cover, em * 18.0) < 0.12 || (uPlasmaT < 1.0e5 && onDisc > 0.5)) discard;
		ALBEDO = vec3(temp_code(uPlasmaT), 0.0, 0.0);
		ALPHA = 1.0;
	} else {
		// In front of the disc the material's own light is the disc's, scattered, and
		// below it: a filament.
		col *= uGlow * mix(1.0, 0.1, onDisc);
		if (max(col.r, cover) < 0.002) discard;
		ALBEDO = col;
		ALPHA = cover * LINE_SHARE;
	}
}
