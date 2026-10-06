// THE ARCADE IN EMISSION: a prominence against the sky. Additive colour, temperature
// replaced: blend_premul_alpha with ALPHA = 0 in the colour pass (c = s + d) and
// ALPHA = 1 in the temperature pass (r = code).
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/bodies/prom_arcade.gdshaderinc"

void fragment() {
	vec3 col; float fp; float onDisc;
	float a = arcade_weight(col, fp, onDisc);
	a *= 1.0 - onDisc;
	if (a < 0.004) discard;
	// Publish the temperature: flare plasma reaches 10⁷ K, so an eruption is the
	// brightest thing on the star in X-ray. Written, not accumulated, or it would corrupt
	// the photosphere's own value.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(temp_code(uPlasmaT), 0.0, 0.0);
		ALPHA = 1.0;
	} else {
		ALBEDO = col * a * 1.7;
		ALPHA = 0.0;
	}
}
