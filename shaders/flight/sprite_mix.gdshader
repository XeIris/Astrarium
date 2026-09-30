// The scattering sprites (launch smoke): RGB = src·α + dst·(1 − α). blend_mix's
// coverage is right: smoke hides what is behind it. See sprite.gdshaderinc.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;
#include "res://shaders/flight/sprite.gdshaderinc"

// The light falling on the smoke (Plume.daylight): a launch cloud in the
// shadow of a cumulus, or at dusk, is not the white it is at noon.
uniform float uLight = 1.0;

void fragment() {
	vec4 t = sprite_texel();
	float a = t.a * opacity;
	if (a <= 0.0) discard;
	ALBEDO = tint * t.rgb * uLight;
	ALPHA = a;
}
