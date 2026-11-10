// A galaxy's unresolved starlight (sim/galaxy/gal_visual.gd): the luminosity density
// of its model integrated along each view ray, I = ∫ j ds / 4π, on a box drawn from
// inside (front faces culled) so it works from outside the galaxy and within it.
// Stars nearer than uRes and heavier than GalPopulation.M_RESOLVED are drawn one by
// one (galaxy_stars.gdshader); inside uRes the glow keeps only the lighter stars'
// share (uFaint), so the two add up to the same flux.
//
// Samples are uniform in u = asinh((s − s_c)/scale) about the ray's crossing of the
// plane (disc) or its closest approach to the centre (spheroid): dense where the
// light is, so a thin disc seen face-on is sampled through its layer.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_front;

#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/galaxy/gal_model.gdshaderinc"

uniform vec3 uCamLocal = vec3(0.0, 0.0, 60.0);
uniform vec3 uBox = vec3(30.0, 4.0, 30.0);
uniform float uSphereR = 8.0;
uniform float uRes = 0.0;
// Share of each population's light in stars too faint to resolve: (disc, spheroid).
uniform vec2 uFaint = vec2(1.0);
// Pixel value per L☉ kpc⁻² sr⁻¹ (the sky's star calibration, sim/galaxy/gal_visual.gd).
uniform float uGain = 1.0;
uniform vec3 uDiscCol = vec3(1.0);
uniform vec3 uSphereCol = vec3(1.0);
// galaxylookcheck only: no light nearer than this.
uniform float uInner = 0.0;

const int N_DISC = 40;
const int N_SPHERE = 24;

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

// ∫ j ds over [t0, t1], uniform in asinh((t − tc)/sc).
float march_disc(vec3 o, vec3 d, float t0, float t1, float tc, float sc, float jit, float faint) {
	float u0 = asinh((t0 - tc) / sc);
	float u1 = asinh((t1 - tc) / sc);
	float du = (u1 - u0) / float(N_DISC);
	float acc = 0.0;
	for (int i = 0; i < N_DISC; i++) {
		float u = u0 + (float(i) + jit) * du;
		float t = tc + sc * sinh(u);
		acc += gal_disc_j(o + d * t) * sc * cosh(u) * (t < uRes ? faint : 1.0) * step(uInner, t);
	}
	return acc * du;
}

float march_sphere(vec3 o, vec3 d, float t0, float t1, float tc, float sc, float jit, float faint) {
	float u0 = asinh((t0 - tc) / sc);
	float u1 = asinh((t1 - tc) / sc);
	float du = (u1 - u0) / float(N_SPHERE);
	float acc = 0.0;
	for (int i = 0; i < N_SPHERE; i++) {
		float u = u0 + (float(i) + jit) * du;
		float t = tc + sc * sinh(u);
		acc += gal_sphere_j(o + d * t) * sc * cosh(u) * (t < uRes ? faint : 1.0) * step(uInner, t);
	}
	return acc * du;
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	// Camera-relative world direction, then galaxy-local (the model has no scale).
	vec3 dw = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	vec3 d = normalize(transpose(mat3(MODEL_MATRIX)) * dw);
	vec3 o = uCamLocal;
	// Interleaved gradient noise: a per-pixel offset that the bloom and the eye average.
	float jit = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float disc = 0.0;
	vec2 tb = box_hit(o, d, uBox);
	tb.x = max(tb.x, 0.0);
	if (tb.y > tb.x && uDisc.x > 0.0) {
		float sc = max(uDisc.z, 0.05) / max(abs(d.y), 1e-4);
		float tc = clamp(-o.y / (abs(d.y) > 1e-6 ? d.y : 1e-6), tb.x, tb.y);
		disc = march_disc(o, d, tb.x, tb.y, tc, sc, jit, uFaint.x);
	}
	float sph = 0.0;
	vec2 ts = sphere_hit(o, d, uSphereR);
	ts.x = max(ts.x, 0.0);
	if (ts.y > ts.x && uSphere.y > 0.0) {
		float sc = max(uSphere.x < 0.5 ? uSphere.w * 0.3 : uSphere.z * 0.5, 0.02);
		float tc = clamp(-dot(o, d), ts.x, ts.y);
		sph = march_sphere(o, d, ts.x, ts.y, tc, sc, jit, uFaint.y);
	}
	ALBEDO = (disc * uDiscCol + sph * uSphereCol) * uGain;
}
