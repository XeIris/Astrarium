// The additive sprites (engine glow, RCS puffs): RGB = src·srcα + dst, blended ONE,
// ONE (blend_premul_alpha, ALPHA = 0), adding light without coverage. See
// sprite.gdshaderinc.
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
