// The test particles the rotation curve is measured from (sim/galaxy/gal_tracers.gd),
// as markers a few pixels wide: an overlay that shows the motion, not starlight.
// Positions are galaxy-local kpc written each frame; COLOR is the population's.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uSize = 3.0;
uniform float uOpacity = 1.0;

varying vec3 vCol;

void vertex() {
	vCol = COLOR.rgb * uOpacity;
	POINT_SIZE = uSize;
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	float r = length(POINT_COORD - 0.5) * 2.0;
	if (r > 1.0) discard;
	ALBEDO = vCol * (1.0 - r * r);
}
