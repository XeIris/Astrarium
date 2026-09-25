// ============================================================================
// A CORONAL MASS EJECTION SHELL — port of cmeMaterial() in sim/star_visual.js.
// The three-part structure and the path-length weighting are explained in the
// header block above createStarVisual's CME pool (sim/star_visual.gd).
//
// BLENDING. Additive colour, alpha REPLACED — the flare-plasma row of the
// temperature table (PORT_GUIDE.md §6): blend_premul_alpha with ALPHA = 0 in
// the colour pass (c = s + d) and ALPHA = 1 in the temperature pass
// (r = code), the same as sim/prominence.gd's emission pass.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(1.0);
uniform vec3 uDir = vec3(0.0, 1.0, 0.0);
uniform float uAlpha = 1.0;
uniform float uWidth = 0.5;
uniform float uTime = 0.0;
uniform float uSeed = 0.0;
uniform float uRimPow = 1.7;
uniform float uFil = 5.0;
uniform float uPlasmaT = 1.6e6;

varying vec3 vObj;
varying vec3 vVN;
varying vec3 vVP;

void vertex() {
	vObj = normalize(VERTEX);
	vVN = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	vVP = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hsh(vec3 p) { return fract(sin(dot(p, vec3(17.1, 113.5, 7.9))) * 43758.5453); }
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hsh(i), hsh(i + vec3(1.0, 0.0, 0.0)), f.x), mix(hsh(i + vec3(0.0, 1.0, 0.0)), hsh(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(hsh(i + vec3(0.0, 0.0, 1.0)), hsh(i + vec3(1.0, 0.0, 1.0)), f.x), mix(hsh(i + vec3(0.0, 1.0, 1.0)), hsh(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}
float fbm(vec3 p0) {
	vec3 p = p0;
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * vnoise(p); p *= 2.2; a *= 0.5; }
	return v;
}

void fragment() {
	float c = dot(vObj, normalize(uDir));
	// The cone has soft flanks: the field opens gradually, it does not end.
	float cone = smoothstep(1.0 - uWidth, 1.0 - uWidth * 0.35, c);
	if (cone <= 0.002) discard;

	// Path length through a thin shell. This is the whole difference
	// between a crescent and an arc with legs.
	vec3 N = normalize(vVN);
	vec3 V = normalize(-vVP);
	float rim = pow(1.0 - abs(dot(N, V)), uRimPow);

	// Streamer-like striations: the ejecta is threaded on the field it
	// dragged out with it, so the structure is RADIAL.
	float n = fbm(vObj * uFil + vec3(uSeed) + uTime * 0.2);
	float a = cone * rim * uAlpha * (0.20 + n * 1.25);
	if (a < 0.003) discard;
	// Published temperature: a CME front is ~1.5 MK compressed corona and
	// its core is the ~10 kK prominence material it carried out, which is
	// why the two look nothing alike outside the visible.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(temp_code(uPlasmaT), 0.0, 0.0);
		ALPHA = 1.0;
	} else {
		ALBEDO = uColor * a * 2.0;
		ALPHA = 0.0;
	}
}
