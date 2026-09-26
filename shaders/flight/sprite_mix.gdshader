// The SCATTERING sprites (the launch smoke): passThroughAlpha(m) in
// sim/flight/plume.js — RGB = src·α + dst·(1 − α). blend_mix is exactly that
// for colour, and what it does to alpha is what the local pass needs: smoke
// is real alumina and real droplets, and it COVERS what is behind it, the
// orrery included. See sprite.gdshaderinc.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;
#include "res://shaders/flight/sprite.gdshaderinc"

void fragment() {
	vec4 t = sprite_texel();
	float a = t.a * opacity;
	if (a <= 0.0) discard;
	ALBEDO = tint * t.rgb;
	ALPHA = a;
}
