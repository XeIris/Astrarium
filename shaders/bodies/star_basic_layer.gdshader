// The legacy star's "gassy outer layer": the same shader, additive, on a
// sphere 1.08× the core. Its material.opacity = 0.25 was a no-op — a
// ShaderMaterial ignores opacity and this one wrote alpha 1.0 — so the web
// added the layer's full colour; so does this (ONE, ONE via premul, ALPHA 0).
// Temperature pass: AdditiveBlending's alpha a² + d with a = 1.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_back;

#include "res://shaders/bodies/star_basic.gdshaderinc"

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = star_basic_color();
	}
	ALPHA = 0.0;
}
