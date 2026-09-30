// The legacy star's gassy outer layer: the same shader, additive (ONE, ONE via
// premul, ALPHA 0), on a sphere 1.08× the core, at full colour. Temperature pass:
// a² + d with a = 1.
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
