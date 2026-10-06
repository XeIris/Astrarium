// THE BACKGROUND, temperature pass: the backdrop's and lens resolve's temperature
// code in COLOR.r (docs/godot.md). A pixel with no emitter is SKY_ALPHA, not 1.0,
// so the remap passes it through.
//
// A pixel seen through partly transparent disc gets whichever source dominates its
// luminance (the disc's accumulated luminance vs the sky's); otherwise the thin
// outer disc would label, and delete, star pixels in every non-visible band.
shader_type sky;

#include "res://shaders/sky/sky.gdshaderinc"

uniform bool u_lens = false;
uniform sampler2D t_march0 : filter_linear, repeat_disable;
uniform sampler2D t_march1 : filter_linear, repeat_disable;

void sky() {
	if (AT_CUBEMAP_PASS || !u_lens) {
		COLOR = vec3(SKY_ALPHA, 0.0, 0.0);
	} else {
		vec4 m0 = texture(t_march0, SCREEN_UV);
		vec4 m1 = texture(t_march1, SCREEN_UV);
		float tr = m0.a;
		vec3 d = normalize(normalize(EYEDIR) + m1.xyz);
		vec3 ddx = dFdx(d), ddy = dFdy(d);
		vec3 skyCol = vec3(0.0);
		if (tr > 0.001) skyCol = tr * skyRadiance(d, ddx, ddy);
		float tWeight = dot(m0.rgb, vec3(0.2126, 0.7152, 0.0722));
		float skyLum  = dot(skyCol, vec3(0.2126, 0.7152, 0.0722));
		bool discWins = m1.a > 0.0 && tWeight > skyLum;
		float a = discWins ? clamp(m1.a / 25.33, 0.0, 0.98) : SKY_ALPHA;
		COLOR = vec3(a, 0.0, 0.0);
	}
}
