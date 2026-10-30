// THE ARCADE IN EMISSION: a prominence against the sky. Additive colour, temperature
// replaced: blend_premul_alpha with ALPHA = 0 in the colour pass (c = s + d) and
// ALPHA = 1 in the temperature pass (r = code), on the disc too.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/bodies/prom_arcade.gdshaderinc"

void fragment() {
	vec3 col; float fp; float onDisc;
	float a = arcade_weight(col, fp, onDisc);
	// Publish the temperature on the disc as well as off it: flare and active-region
	// loops are the brightest things on the star in X-ray wherever they are, and cool
	// filament material in front of the disc is dark there. Written, not accumulated,
	// or it would corrupt the photosphere's own value.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		if (a < 0.08) discard;
		ALBEDO = vec3(temp_code(uPlasmaT), 0.0, 0.0);
		ALPHA = 1.0;
	} else {
		// In visible light only off the limb; on the disc the absorbing pass draws it.
		a *= 1.0 - onDisc;
		if (a < 0.004) discard;
		ALBEDO = col * a * 1.7 * uGlow;
		ALPHA = 0.0;
	}
}
