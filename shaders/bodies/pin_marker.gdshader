// A pin stuck in a world. Unshaded and bright, since it has to read against any ground; the
// temperature pass discards it, as a mark on the picture rather than a thing with a temperature.
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(0.95, 0.04, 0.03);

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	ALBEDO = uColor;
}
