// ============================================================================
// THE ARCADE IN EMISSION — a prominence, seen against the sky off the limb.
// ----------------------------------------------------------------------------
// Additive colour, but alpha REPLACED rather than summed: alpha is not
// opacity in this renderer, it is the published temperature channel that
// sim/spectrum.gd images the frame from. In Godot that is the flare-plasma row
// of the temperature table (PORT_GUIDE.md §6): blend_premul_alpha with
// ALPHA = 0 in the colour pass (c = s + d, the web's ONE, ONE) and ALPHA = 1
// in the temperature pass (r = code — the web's blendDstAlpha = ZERO).
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/bodies/prom_arcade.gdshaderinc"

void fragment() {
	vec3 col; float fp; float onDisc;
	float a = arcade_weight(col, fp, onDisc);
	a *= 1.0 - onDisc;
	if (a < 0.004) discard;
	// Published temperature, log-encoded, for sim/spectrum.gd. Flare plasma
	// reaches 10^7 K, which is precisely why a flare is an X-RAY source and
	// barely a visible-light one — so this is what makes an eruption show up
	// in the X-ray band as the brightest thing on the star. The channel is
	// written rather than accumulated (see the blend mode), or adding it to
	// the photosphere's own published value would destroy both.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(temp_code(uPlasmaT), 0.0, 0.0);
		ALPHA = 1.0;
	} else {
		ALBEDO = col * a * 1.7;
		ALPHA = 0.0;
	}
}
