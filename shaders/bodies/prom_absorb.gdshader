// THE ARCADE IN ABSORPTION: a filament against the photosphere. blend_mix for the
// dark material, leaving the temperature untouched (the photosphere behind has
// published its own), so the temperature pass discards.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

#include "res://shaders/bodies/prom_arcade.gdshaderinc"

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	vec3 col; float fp; float onDisc;
	float a = arcade_weight(col, fp, onDisc);
	// A filament is darkest where the column through it is longest, which is
	// along its spine and at its top — the footpoint brightening belongs to
	// emission, not to absorption.
	a *= onDisc * (1.0 - 0.45 * fp);
	if (a < 0.010) discard;
	// In absorption the filament is dark and slightly red — it is cool
	// material in front of a hot continuum, not a shadow, so it never goes
	// fully black.
	ALBEDO = uCool * 0.18;
	ALPHA = clamp(a * 0.55, 0.0, 0.80);
}
