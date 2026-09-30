// ACCRETION STREAM points (sim/bodies.gd AccretionStream). CUSTOM0.x is the
// particle's alpha (remaining life). Size uSize·alpha / depth (depth clamped at 0.5),
// round, fading to the rim. Colour uColor·a formed here and blended ONE, ONE.
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
