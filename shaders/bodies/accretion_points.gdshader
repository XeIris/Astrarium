// ============================================================================
// ACCRETION STREAM — the GPU point pool of sim/bodies.js's AccretionStream.
// CUSTOM0.x is the particle's alpha (its remaining life). Points shrink with
// distance (uSize·alpha / depth, clamped at depth 0.5) and are round, fading
// linearly to the rim.
//
// BLENDING: web AdditiveBlending with (uColor, a) — colour gains uColor·a,
// alpha a². The product is formed here and blended ONE, ONE
// (blend_premul_alpha, ALPHA = 0; PORT_GUIDE.md §6).
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(1.0);
uniform float uSize = 60.0;

varying float vA;

void vertex() {
	vA = CUSTOM0.x;
	vec4 mv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POINT_SIZE = uSize * vA / max(-mv.z, 0.5);
}

void fragment() {
	float d = length(POINT_COORD - 0.5);
	if (d > 0.5) discard;
	float a = vA * (1.0 - d * 2.0);
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(a * a, 0.0, 0.0);
	} else {
		ALBEDO = uColor * a;
	}
	ALPHA = 0.0;
}
