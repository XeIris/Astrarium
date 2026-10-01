class_name HudCanvas
extends Control

# A drawn box in the HUD: a fixed height, or one proportional to its width (`aspect`
# = h / w, a canvas at 100% width). Draws its background and border, then
# _draw_content(), which subclasses override.

var aspect := 0.0
var fixed_h := -1.0
var bg := HudTheme.CLEAR
var border := HudTheme.CLEAR
var _w := -1.0

func _init(asp := 0.0, h := -1.0, bg_col := HudTheme.CLEAR, border_col := HudTheme.CLEAR) -> void:
	aspect = asp
	fixed_h = h
	bg = bg_col
	border = border_col
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_aspect(a: float) -> void:
	aspect = a
	update_minimum_size()

func _get_minimum_size() -> Vector2:
	if fixed_h >= 0.0:
		return Vector2(0, fixed_h)
	return Vector2(0, roundf(size.x * aspect))

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and aspect > 0.0 and absf(size.x - _w) > 0.01:
		_w = size.x
		update_minimum_size()

## The content box, inside the 1 px border.
func inner() -> Rect2:
	var b := 1.0 if border.a > 0.0 else 0.0
	return Rect2(Vector2(b, b), size - Vector2(2 * b, 2 * b))

## A rect on whole device pixels, as a compositor places a bitmap.
func snap_rect(r: Rect2) -> Rect2:
	var gp := get_global_transform().origin
	var x0 := roundf(gp.x + r.position.x) - gp.x
	var y0 := roundf(gp.y + r.position.y) - gp.y
	var x1 := roundf(gp.x + r.end.x) - gp.x
	var y1 := roundf(gp.y + r.end.y) - gp.y
	return Rect2(x0, y0, x1 - x0, y1 - y0)

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if bg.a > 0.0:
		draw_rect(r, bg)
	if border.a > 0.0:
		draw_rect(r.grow(-0.5), border, false, 1.0)
	_draw_content()

func _draw_content() -> void:
	pass
