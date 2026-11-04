class_name PlateView
extends Control

# A simulated detector frame with its scale bar and the sky's directions: north up, east left.

const AS_BARS := [0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 3600.0, 7200.0]
var texture: Texture2D = null
var field := 0.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(258, 258)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

## `field_as` is the frame's width in arcseconds.
func show_frame(t: Texture2D, field_as: float) -> void:
	texture = t
	field = field_as
	queue_redraw()

## Stays square at whatever width the panel gives it.
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and absf(custom_minimum_size.y - size.x) > 0.5 and size.x > 1.0:
		custom_minimum_size.y = size.x
		update_minimum_size()

static func _bar_text(a: float) -> String:
	if a >= 3600.0: return "%d°" % int(a / 3600.0)
	if a >= 60.0: return "%d′" % int(a / 60.0)
	return "%s″" % String.num(a, 1 if a < 1.0 else 0)

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, Vector2(size.x, size.x))
	draw_rect(r, Color(0.0, 0.0, 0.0, 0.9))
	var font := get_theme_default_font()
	if texture == null:
		var msg := "No frame yet"
		var w := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(font, r.get_center() + Vector2(-w * 0.5, 4.0), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, HudTheme.TEXT_DIM)
		draw_rect(r, HudTheme.BORDER, false, 1.0)
		return
	draw_texture_rect(texture, r, false)
	draw_rect(r, HudTheme.BORDER, false, 1.0)
	var col := Color(1.0, 0.82, 0.45, 0.95)
	# The largest round length under a third of the frame.
	var bar := 0.0
	for a: float in AS_BARS:
		if a <= field / 3.0: bar = a
	if bar > 0.0:
		var px := bar / field * size.x
		var y := size.x - 12.0
		draw_line(Vector2(10.0, y), Vector2(10.0 + px, y), col, 1.5)
		draw_string(font, Vector2(10.0, y - 5.0), _bar_text(bar), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
	var o := Vector2(size.x - 14.0, size.x - 14.0)
	draw_line(o, o + Vector2(0.0, -22.0), col, 1.2)
	draw_line(o, o + Vector2(-22.0, 0.0), col, 1.2)
	draw_string(font, o + Vector2(-4.0, -25.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)
	draw_string(font, o + Vector2(-33.0, 4.0), "E", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)
