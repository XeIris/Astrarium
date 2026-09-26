// The legacy star's opaque core (sim/bodies.js starMaterial). It wrote alpha
// 1.0 — no temperature — so the temperature pass publishes TEMP_NO_DATA and the
// imaging bands infer T from its colour, exactly as they did for it on the web.
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://shaders/bodies/star_basic.gdshaderinc"

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(TEMP_NO_DATA, 0.0, 0.0);
	} else {
		ALBEDO = star_basic_color();
	}
}
