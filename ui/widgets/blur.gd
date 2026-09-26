class_name HudBlur
extends RefCounted

# ============================================================================
# backdrop-filter: blur(σ) — and the start screen's radial gradient over it.
#
# CSS blurs the backdrop with a Gaussian of standard deviation σ px and then
# paints the element's own (translucent) background on top. Here the screen
# behind the panel is read through hint_screen_texture WITH MIPMAPS: a 7 × 7
# tap Gaussian spaced σ/2 apart, read from the mip whose texels are about that
# spacing, is a σ-wide Gaussian for 49 taps a pixel instead of the (6σ)² a
# direct kernel would need. The tint (the panel's rgba background) is then
# mixed over it exactly as CSS composites a background over a filtered
# backdrop. Everything is in the canvas's own sRGB space, as the browser's is.
# ============================================================================

## The HUD test harness turns this off to compare against flat backgrounds.
static var enabled := true
static var _shader: Shader = null

static func shader() -> Shader:
	if _shader != null:
		return _shader
	_shader = Shader.new()
	_shader.code = """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec4 tint = vec4(0.0);
uniform float sigma = 10.0;        // CSS px
uniform float px_scale = 1.0;      // physical px per CSS px
// radial-gradient(RX RY at CX CY, inner, outer) — the start screen. mode 1.
uniform int mode = 0;
uniform vec4 inner = vec4(0.0);
uniform vec4 outer = vec4(0.0);
uniform vec2 centre = vec2(0.5, 0.4);
uniform vec2 radii = vec2(1.2, 0.9);
varying vec2 local_uv;
void vertex() { local_uv = UV; }
void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	float s = sigma * px_scale;
	float step_px = s * 0.5;
	float lod = max(log2(max(step_px, 1.0)) - 0.5, 0.0);
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int i = -3; i <= 3; i++) {
		for (int j = -3; j <= 3; j++) {
			vec2 o = vec2(float(i), float(j)) * step_px;
			float w = exp(-dot(o, o) / (2.0 * s * s));
			acc += textureLod(screen_tex, SCREEN_UV + o * px, lod).rgb * w;
			wsum += w;
		}
	}
	vec3 blur = acc / wsum;
	vec4 top = tint;
	if (mode == 1) {
		// the ending shape is an ellipse of the given radii (fractions of the
		// box) centred at `centre`; colour runs from inner at 0 to outer at 1
		vec2 d = (local_uv - centre) / radii;
		float t = clamp(length(d), 0.0, 1.0);
		// CSS interpolates gradients in premultiplied sRGB
		vec4 a = vec4(inner.rgb * inner.a, inner.a);
		vec4 b = vec4(outer.rgb * outer.a, outer.a);
		vec4 m = mix(a, b, t);
		top = vec4(m.a > 0.0 ? m.rgb / m.a : vec3(0.0), m.a);
	}
	COLOR = vec4(mix(blur, top.rgb, top.a), 1.0);
}
"""
	return _shader
