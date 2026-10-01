class_name HudSlider
extends Range

# The HUD's range input: a 2 px track in border-strong and a 12 px accent square
# turned 45°, whose centre runs from 6 px to width − 6. A Range rather than an
# HSlider, whose minimum height is its grabber's (17 px, which would make every row
# taller) and which turns wheel scrolls over it into value changes.
#
# `moved` fires on the user's moves only; set_v() moves it silently. Values snap
# to `snap` from min_value without the binary tail (0.30000000000000004).

signal moved(value: float)

var snap := 0.01
## Horizontal margin inside the control's own rect (a row slider's 2 px).
var inset := 0.0
var _drag := false

func _init(mn := 0.0, mx := 1.0, st := 0.01, v := 0.0) -> void:
	step = 0.0
	min_value = mn
	max_value = mx
	snap = st
	set_v(v)
	custom_minimum_size = Vector2(48, 2)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_NONE
	value_changed.connect(func(_v): queue_redraw())

func set_v(v: float) -> void:
	set_value_no_signal(snapped_value(v))
	queue_redraw()

func snapped_value(v: float) -> float:
	v = clampf(v, min_value, max_value)
	if snap > 0.0:
		v = clampf(min_value + roundf((v - min_value) / snap) * snap, min_value, max_value)
		var dec := 0
		var s := snap
		while dec < 8 and absf(s - roundf(s)) > 1e-9:
			s *= 10.0; dec += 1
		v = snappedf(v, pow(10.0, -dec)) if dec > 0 else roundf(v)
	return v

## The thumb overhangs the 2 px track; it has to be grabbable where it is drawn.
func _has_point(p: Vector2) -> bool:
	return Rect2(Vector2(0, -8), Vector2(size.x, size.y + 16)).has_point(p)

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag = e.pressed
		if e.pressed:
			_set_from_x(e.position.x)
		accept_event()
	elif e is InputEventMouseMotion and _drag:
		_set_from_x(e.position.x)
		accept_event()

func _set_from_x(x: float) -> void:
	var t := clampf((x - inset - 6.0) / maxf(size.x - 2.0 * inset - 12.0, 1.0), 0.0, 1.0)
	var v := snapped_value(min_value + t * (max_value - min_value))
	if v != value:
		set_value_no_signal(v)
		queue_redraw()
		moved.emit(v)
		value_changed.emit(v)

func frac() -> float:
	return 0.0 if max_value <= min_value else (value - min_value) / (max_value - min_value)

func _draw() -> void:
	var w := size.x - 2.0 * inset
	draw_rect(Rect2(inset, size.y * 0.5 - 1.0, w, 2.0), HudTheme.BORDER_STRONG)
	var cx := inset + 6.0 + frac() * maxf(w - 12.0, 0.0)
	var cy := size.y * 0.5
	var h := 6.0 * sqrt(2.0)
	draw_colored_polygon(PackedVector2Array([Vector2(cx, cy - h), Vector2(cx + h, cy), Vector2(cx, cy + h), Vector2(cx - h, cy)]), HudTheme.ACCENT)
