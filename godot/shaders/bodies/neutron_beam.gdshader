// ============================================================================
// PULSAR BEAM — port of BEAM_VERT / BEAM_FRAG in sim/neutron_visual.js.
// Hollow, filamentary emission cone along +Y of its own frame (apex at the
// star, mouth at +uLength).
//
// BLENDING. Web: AdditiveBlending (SRC_ALPHA, ONE) with gl_FragColor =
// (uColor·a·2.4, 0.75a) — colour gains uColor·a·2.4·0.75a, alpha (0.75a)².
// The product is formed here and blended ONE, ONE (blend_premul_alpha,
// ALPHA = 0; PORT_GUIDE.md §6).
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(0.45, 0.72, 1.0);
uniform float uAlpha = 0.45;
uniform float uTime = 0.0;
uniform float uOpen = 1.0;
uniform float uLength = 1.0;

varying vec3 vObj;
varying float vAxial;

void vertex() {
	vObj = VERTEX;
	vAxial = clamp(VERTEX.y / max(uLength, 1e-4), 0.0, 1.0);
}

float hsh(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hsh(i), hsh(i + vec2(1.0, 0.0)), f.x), mix(hsh(i + vec2(0.0, 1.0)), hsh(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p0) {
	vec2 p = p0;
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * vnoise(p); p *= 2.2; a *= 0.5; }
	return v;
}

void fragment() {
	// radial position across the cone wall, 0 = axis, 1 = mouth
	float rr = length(vObj.xz) / max(uOpen, 1e-3);

	// HOLLOW: emission comes from the last open field lines, so the wall is
	// bright and the axis is comparatively empty.
	float q = (rr - 0.72) / 0.30;
	float wall = exp(-q * q);
	float q2 = rr / 0.55;
	wall += exp(-q2 * q2) * 0.22;

	// filamentary structure streaming outward along the beam
	float ang = atan(vObj.z, vObj.x);
	float fil = 0.45 + 0.75 * fbm(vec2(ang * 3.5, vAxial * 4.0 - uTime * 1.8));

	// fade out along the length — the beam is not a solid rod
	float fall = exp(-vAxial * 1.9) * smoothstep(0.0, 0.06, vAxial);

	float a = wall * fil * fall * uAlpha;
	float srcA = a * 0.75;
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(srcA * srcA, 0.0, 0.0);
	} else {
		ALBEDO = uColor * a * 2.4 * srcA;
	}
	ALPHA = 0.0;
}
