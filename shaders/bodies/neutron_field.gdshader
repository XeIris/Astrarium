// DIPOLE FIELD LINES, glowing from trapped plasma, brightness falling as 1/r
// (brilliant at the poles). Tubes are CCW-wound and single-sided, so Godot's CW front
// faces mean cull_front. The product uColor·a·min(a, 1) is formed here and blended
// ONE, ONE.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_front;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(0.45, 0.72, 1.0);
uniform float uAlpha = 0.6;
uniform float uR = 1.0;

varying float vFall;

void vertex() {
	// the attribute is already in the dipole's own frame, centred on the star,
	// so its length is the distance from the centre in scene units.
	float rr = length(VERTEX) / max(uR, 1e-5);
	vFall = 1.0 / (0.25 + rr * rr * 0.55);
}

void fragment() {
	float a = clamp(vFall * uAlpha, 0.0, 6.0);
	float srcA = min(a, 1.0);
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(srcA * srcA, 0.0, 0.0);
	} else {
		ALBEDO = uColor * a * srcA;
	}
	ALPHA = 0.0;
}
