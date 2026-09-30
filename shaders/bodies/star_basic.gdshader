// The legacy star's opaque core. It publishes TEMP_NO_DATA, so the imaging bands
// infer T from its colour.
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
