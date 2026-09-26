// ============================================================================
// DIPOLE FIELD LINES — port of FIELD_VERT / FIELD_FRAG in sim/neutron_visual.js.
// ----------------------------------------------------------------------------
// Field lines glow from the plasma trapped on them, which is densest close to
// the star. A flat additive tube lands in a uniform mid-grey and reads as a
// plastic pipe; brightness falling as 1/r makes the same geometry read as
// something luminous, brilliant at the poles and fading into the dark.
//
// The tubes are built in THREE's winding (counter-clockwise front faces) and
// the web material was single-sided (FrontSide). Godot's front faces are
// clockwise, so the same outward faces are culled here with cull_front.
// BLENDING: web AdditiveBlending with (uColor·a, min(a,1)); the product is
// formed here and blended ONE, ONE (PORT_GUIDE.md §6).
// ============================================================================
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
