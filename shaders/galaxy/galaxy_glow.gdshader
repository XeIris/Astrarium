// A galaxy's unresolved starlight (sim/galaxy/gal_visual.gd): the luminosity density
// of its model integrated along each view ray, I = ∫ j ds / 4π, on a box drawn from
// inside (front faces culled) so it works from outside the galaxy and within it.
// Stars nearer than uRes and heavier than GalPopulation.M_RESOLVED are drawn one by
// one (galaxy_stars.gdshader); inside uRes the glow keeps only the lighter stars'
// share (uFaint), so the two add up to the same flux.
//
// Samples are uniform in u = asinh((s − s_c)/scale) about the ray's crossing of the
// plane (disc) or its closest approach to the centre (spheroid): dense where the
// light is, so a thin disc seen face-on is sampled through its layer. Dust lies in the
// disc's layer: the disc march carries its optical depth front to back, per channel
// (uExt, A_λ/A_V), and the spheroid's samples read it there.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_front;

#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/galaxy/gal_model.gdshaderinc"

uniform vec3 uCamLocal = vec3(0.0, 0.0, 60.0);
uniform vec3 uBox = vec3(30.0, 4.0, 30.0);
uniform float uSphereR = 8.0;
uniform float uSphereCore = 0.5;
uniform float uRes = 0.0;
// Share of each population's light in stars too faint to resolve: (disc, spheroid).
uniform vec2 uFaint = vec2(1.0);
// Pixel value per L☉ kpc⁻² sr⁻¹ (the sky's star calibration, sim/galaxy/gal_visual.gd).
uniform float uGain = 1.0;
// One pixel's angle (rad): the interstellar medium's finest drawn octave.
uniform float uPix = 1e-3;
uniform vec3 uDiscCol = vec3(1.0);
uniform vec3 uSphereCol = vec3(1.0);
uniform vec3 uYoungCol = vec3(1.0);
// Extinction in the red, green and blue channels relative to V.
uniform vec3 uExt = vec3(0.748, 1.0, 1.324);
// galaxylookcheck only: no light nearer than this.
uniform float uInner = 0.0;
// The real far stars' light seen from the Sun (sim/galaxy/gal_neighbourhood.gd), given up
// by the glow: radiance on galactic (l, b), the Sun's axes, and pixel value per radiance
// times the set's weight (0: none).
// Read by hand (cat_map): wrapped in longitude, clamped in latitude, so a pole never
// borrows the other pole's light as a wrapping sampler would.
uniform sampler2D uCatMap : filter_nearest, repeat_disable;

vec3 cat_map(vec2 uv) {
	ivec2 size = textureSize(uCatMap, 0);
	vec2 p = uv * vec2(size) - 0.5;
	vec2 f = p - floor(p);
	int x0 = int(floor(p.x));
	x0 = ((x0 % size.x) + size.x) % size.x;
	int x1 = (x0 + 1) % size.x;
	int y0 = clamp(int(floor(p.y)), 0, size.y - 1);
	int y1 = clamp(int(floor(p.y)) + 1, 0, size.y - 1);
	vec3 a = mix(texelFetch(uCatMap, ivec2(x0, y0), 0).rgb, texelFetch(uCatMap, ivec2(x1, y0), 0).rgb, f.x);
	vec3 b = mix(texelFetch(uCatMap, ivec2(x0, y1), 0).rgb, texelFetch(uCatMap, ivec2(x1, y1), 0).rgb, f.x);
	return mix(a, b, f.y);
}
uniform mat3 uSunBasis = mat3(1.0);
uniform float uCatGain = 0.0;
// The thinnest dust layer's scale height (kpc); large where there is none thinner.
uniform float uThin = 1e9;

const int N_DISC = 32;
// The asinh scale (kpc) about the camera for rays from inside the disc's layer.
const float SC_INSIDE = 0.5;
const int N_SPHERE = 16;

vec2 box_hit(vec3 o, vec3 d, vec3 b) {
	vec3 inv = 1.0 / d;
	vec3 t1 = (-b - o) * inv;
	vec3 t2 = (b - o) * inv;
	vec3 lo = min(t1, t2);
	vec3 hi = max(t1, t2);
	return vec2(max(max(lo.x, lo.y), lo.z), min(min(hi.x, hi.y), hi.z));
}

vec2 sphere_hit(vec3 o, vec3 d, float r) {
	float b = dot(o, d);
	float c = dot(o, o) - r * r;
	float h = b * b - c;
	if (h < 0.0) return vec2(1.0, 0.0);
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}

const int N_TAU = N_DISC + 1;

// Disc and young light through the disc's layer with its dust, front to back, in two
// legs: N_NEAR samples even in s up to uRes, where the drawn stars take over, and the
// rest uniform in asinh about the plane crossing beyond it. Fills the optical depth at
// each sample boundary (tv) and the legs' parameters (leg: t0, dn, tm, t1; arc: tc, sc,
// u0, du) for the spheroid's march, which inverts them rather than storing boundaries.
const int N_NEAR = 4;
vec3 march_disc(vec3 o, vec3 d, float t0, float t1, float tc, float sc, float jit, float faint,
		vec2 ism, inout float tv[N_TAU], out vec4 leg, out vec4 arc) {
	vec3 acc = vec3(0.0);
	float tau = 0.0;
	vec3 trans = vec3(1.0);
	float tm = clamp(uRes, t0, t1);
	float u0 = asinh((tm - tc) / sc);
	float u1 = asinh((t1 - tc) / sc);
	float du = (u1 - u0) / float(N_DISC - N_NEAR);
	float dn = (tm - t0) / float(N_NEAR);
	leg = vec4(t0, dn, tm, t1);
	arc = vec4(tc, sc, u0, du);
	for (int i = 0; i < N_DISC; i++) {
		bool near_leg = i < N_NEAR;
		tv[i] = tau;
		float t;
		float ds;
		if (near_leg) {
			t = t0 + (float(i) + jit) * dn;
			ds = dn;
		} else {
			float u = u0 + (float(i - N_NEAR) + jit) * du;
			t = tc + sc * sinh(u);
			ds = sc * cosh(u) * du;
		}
		vec3 p = o + d * t;
		float near = (t < uRes ? faint : 1.0) * step(uInner, t);
		float jd;
		float jy;
		float dk;
		gal_disc_sample(p, jd, jy, dk);
		dk *= gal_ism_dust(ism.x);
		jy *= ism.y;
		// Within a step of optical depth k the light is attenuated by its mean,
		// (T − T e^{−k})/k, exactly for a uniform step: long steps through dense dust
		// then neither overshoot nor flicker with the jitter. T carries over, one exp a step.
		vec3 kc = dk * ds * uExt;
		vec3 t_next = trans * exp(-kc);
		vec3 att = mix(trans * (vec3(1.0) - 0.5 * kc), (trans - t_next) / max(kc, vec3(1e-6)), step(vec3(1e-4), kc));
		acc += (jd * near * uDiscCol + jy * step(uInner, t) * uYoungCol) * ds * att;
		trans = t_next;
		tau += dk * ds;
	}
	tv[N_DISC] = tau;
	return acc;
}

// The disc march's optical depth at t, linear in each leg's own parameter between its
// boundaries.
float tau_at(float t, float tv[N_TAU], vec4 leg, vec4 arc) {
	if (t <= leg.x) return 0.0;
	if (t >= leg.w) return tv[N_DISC];
	float x = t < leg.z ? (t - leg.x) / max(leg.y, 1e-9)
		: float(N_NEAR) + (asinh((t - arc.x) / arc.y) - arc.z) / max(arc.w, 1e-9);
	x = clamp(x, 0.0, float(N_DISC) - 1e-3);
	int i = int(x);
	return mix(tv[i], tv[i + 1], x - float(i));
}

vec3 march_sphere(vec3 o, vec3 d, float t0, float t1, float tc, float sc, float jit, float faint,
		float tv[N_TAU], vec4 leg, vec4 arc) {
	float u0 = asinh((t0 - tc) / sc);
	float u1 = asinh((t1 - tc) / sc);
	float du = (u1 - u0) / float(N_SPHERE);
	vec3 acc = vec3(0.0);
	for (int i = 0; i < N_SPHERE; i++) {
		float u = u0 + (float(i) + jit) * du;
		float t = tc + sc * sinh(u);
		acc += gal_sphere_j(o + d * t) * sc * cosh(u) * (t < uRes ? faint : 1.0) * step(uInner, t)
			* exp(-tau_at(t, tv, leg, arc) * uExt);
	}
	return acc * du;
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	// Camera-relative world direction, then galaxy-local (the model has no scale).
	vec3 dw = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	vec3 d = normalize(transpose(mat3(MODEL_MATRIX)) * dw);
	vec3 o = uCamLocal;
	// A per-pixel offset from an integer hash: structured noise (interleaved gradient)
	// reads as hatching across a thin dust lane, white noise as grain.
	uvec2 px = uvec2(FRAGCOORD.xy);
	uint hh = px.x * 1973u + px.y * 9277u + 26699u;
	hh = (hh ^ (hh >> 16u)) * 2246822519u;
	hh = (hh ^ (hh >> 13u)) * 3266489917u;
	hh ^= hh >> 16u;
	float jit = float(hh >> 8u) * (1.0 / 16777216.0);
	vec3 disc = vec3(0.0);
	float tv[N_TAU];
	for (int i = 0; i < N_TAU; i++) tv[i] = 0.0;
	// No disc crossing: tau_at reads zero everywhere.
	vec4 leg = vec4(1e30);
	vec4 arc = vec4(0.0, 1.0, 0.0, 1.0);
	vec2 tbx = box_hit(o, d, uBox);
	tbx.x = max(tbx.x, 0.0);
	// A spheroid alone (NGC 5195, M87) has nothing in the disc's layer to march.
	bool disc_on = uDisc.x > 0.0 || uDiscMap.x > 0.0 || uYoung.x > 0.0 || uSpiral.x > 0.0
		|| uDust.x > 0.0 || uDustMap.x > 0.0 || uRing[0].z > 0.0;
	if (disc_on && tbx.y > tbx.x) {
		// Sampled on the thinner of the disc's light and its dust layer, so a 20 pc dust
		// lane is not stepped over.
		float sc = max(min(uDisc.z, uThin), 0.005) / max(abs(d.y), 1e-4);
		float tc = clamp(-o.y / (abs(d.y) > 1e-6 ? d.y : 1e-6), tbx.x, tbx.y);
		// The medium below the map, seen from outside its layer, where the ray crosses the
		// plane: a tilted thick layer does not smear it and the march adds no grain.
		bool outside = abs(o.y) > uISMLayer.y;
		// From inside, a ray along the plane crosses it far off or not at all: the samples
		// gather about the camera instead, where its dust and light change most (32 samples
		// spread evenly over the box's chord missed the near dust by up to 11 %).
		if (!outside) {
			sc = min(sc, SC_INSIDE);
			tc = tbx.x;
		}
		vec2 ism = outside ? gal_ism(o + d * tc, tc * uPix) : vec2(1.0);
		disc = march_disc(o, d, tbx.x, tbx.y, tc, sc, jit, uFaint.x, ism, tv, leg, arc);
	}
	vec3 sph = vec3(0.0);
	vec2 ts = sphere_hit(o, d, uSphereR);
	ts.x = max(ts.x, 0.0);
	if (ts.y > ts.x && uSphere.y > 0.0) {
		// About each spheroid's core: 0.3 cutoff radii, half a Hernquist scale, or for a measured
		// profile uSphereCore.
		float sc = max(uSphere.x < 0.5 ? uSphere.w * 0.3 : (uSphere.x < 1.5 ? uSphere.z * 0.5 : uSphereCore), 0.02);
		float tc = clamp(-dot(o, d), ts.x, ts.y);
		sph = march_sphere(o, d, ts.x, ts.y, tc, sc, jit, uFaint.y, tv, leg, arc);
	}
	vec3 col = (disc + sph * uSphereCol) * uGain;
	if (uCatGain > 0.0) {
		vec3 s = transpose(uSunBasis) * d;
		vec2 uv = vec2(fract(atan(-s.z, s.x) / 6.2831853), 0.5 - asin(clamp(s.y, -1.0, 1.0)) / 3.1415927);
		col = max(col - uCatGain * cat_map(uv), vec3(0.0));
	}
	ALBEDO = col;
}
