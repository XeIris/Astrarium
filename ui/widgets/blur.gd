class_name HudBlur
extends RefCounted

# The panels' frosted backdrop. The screen behind is read through hint_screen_texture with mipmaps: a 7 × 7 tap
# Gaussian spaced σ/2 from the matching mip is a σ-wide blur for 49 taps. The
# panel's rgba background is mixed over it in sRGB.

## Off, panels draw their flat background instead.
static var enabled := true
static var _shader: Shader = null

## A backdrop behind `c`'s own drawing (its border and text draw over it), sized to
## it by anchors.
static func attach(c: Control, tint: Color, sigma := 10.0) -> Backdrop:
	var r := Backdrop.new()
	r.tint = tint
	r.sigma = sigma
	c.add_child(r, false, Node.INTERNAL_MODE_FRONT)
	r.visible = enabled
	return r

class Backdrop extends ColorRect:
	var tint := Color.TRANSPARENT
	var sigma := 10.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		show_behind_parent = true
		set_anchors_preset(Control.PRESET_FULL_RECT)
		var m := ShaderMaterial.new()
		m.shader = HudBlur.shader()
		material = m

	func _notification(what: int) -> void:
		if what == NOTIFICATION_ENTER_TREE or what == NOTIFICATION_RESIZED:
			var m: ShaderMaterial = material
			m.set_shader_parameter("tint", tint)
			m.set_shader_parameter("sigma", sigma)
			m.set_shader_parameter("px_scale", get_window().content_scale_factor if is_inside_tree() else 1.0)

static func shader() -> Shader:
	if _shader != null:
		return _shader
	_shader = Shader.new()
	_shader.code = """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec4 tint = vec4(0.0);
uniform float sigma = 10.0;        // logical px
uniform float px_scale = 1.0;      // physical px per logical px
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
	COLOR = vec4(mix(blur, tint.rgb, tint.a), 1.0);
}
"""
	return _shader
