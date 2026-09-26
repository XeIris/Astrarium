// ============================================================================
// THE BACKGROUND — temperature pass. What the web build's backdrop and lens
// resolve wrote into ALPHA, written into COLOR.r (see PORT_GUIDE.md).
//
// A pixel with no emitter on it is SKY_ALPHA rather than 1.0: the sky is
// composited in the current band already, so the remap must pass it through
// rather than infer a temperature from it.
//
// ONE ALPHA, TWO POSSIBLE SOURCES. A pixel looking through a partly
// transparent disc holds both, and it is labelled by whichever DOMINATES it —
// the disc's luminance-weighted contribution is just the luminance of what it
// accumulated, so the two are directly comparable. Without the comparison the
// thin outer disc took the label on any emission at all and deleted whole
// star-field pixels from every non-visible band.
// ============================================================================
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
