// The ADDITIVE sprites (engine glow, RCS puffs): passThroughAlpha(m, true) in
// sim/flight/plume.js — RGB = src·srcα + dst, alpha left alone. Formed here and
// blended ONE, ONE (blend_premul_alpha, ALPHA = 0), so it adds light without
// covering the orrery behind it. See sprite.gdshaderinc.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;
#include "res://shaders/flight/sprite.gdshaderinc"

void fragment() {
	vec4 t = sprite_texel();
	float a = t.a * opacity;
	if (a <= 0.0) discard;
	ALBEDO = tint * t.rgb * a;
	ALPHA = 0.0;
}
