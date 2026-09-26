class_name RangeInput
extends El

# ============================================================================
# <input type="range">, drawn the way blackhole_sim.css draws it:
#
#   input[type=range]  appearance none, height 2px, background border-strong
#   ::-webkit-slider-thumb  12 × 12 accent square, rotate(45deg)
#
# With appearance:none the box IS the track — 2 px tall — and the thumb
# overhangs it by 5 px either side (which is why the settings panel gives
# these a margin). WebKit keeps the thumb's box inside the track, so its
# centre runs from 6 px to (width − 6 px). The intrinsic width is WebKit's
# 129 px, and it matters: a flex:1 range in a .row cannot shrink below it,
# which is why the Ocean depth row's value is pushed past the panel's edge on
# the web page too.
#
# `changed(value)` fires on every move, as the DOM `input` event does; a value
# written with set_value() fires nothing.
# ============================================================================

signal changed(value: float)

var vmin := 0.0
var vmax := 1.0
var step := 0.01
var value := 0.0
var input_id := ""
var _drag := false

func _init(style: Dictionary = {}, vars: Array = []) -> void:
	var s := {"h": 2.0, "bg": HudTheme.BORDER_STRONG, "iw": 129.0}
	s.merge(style, true)
	super(s, vars)
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

func setup(mn: float, mx: float, st: float, v: float) -> RangeInput:
	vmin = mn; vmax = mx; step = st
	set_value(v)
	return self

func set_value(v: float) -> void:
	value = _snap_step(v)
	queue_redraw()

func _snap_step(v: float) -> float:
	v = clampf(v, vmin, vmax)
	if step > 0.0:
		v = vmin + roundf((v - vmin) / step) * step
		v = clampf(v, vmin, vmax)
		# kill the binary tail a step multiple leaves (0.30000000000000004)
		var dec := 0
		var s := step
		while dec < 8 and absf(s - roundf(s)) > 1e-9:
			s *= 10.0; dec += 1
		v = snappedf(v, pow(10.0, -dec)) if dec > 0 else roundf(v)
	return v

func frac() -> float:
	return 0.0 if vmax <= vmin else (value - vmin) / (vmax - vmin)

## The thumb overhangs the 2 px box; it has to be grabbable where it is drawn.
func _has_point(p: Vector2) -> bool:
	return Rect2(Vector2(0, -8), Vector2(size.x, size.y + 16)).has_point(p)

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_drag = e.pressed
		if e.pressed:
			_set_from_x(e.position.x)
		accept_event()
	elif e is InputEventMouseMotion and _drag:
		_set_from_x(e.position.x)
		accept_event()

func _set_from_x(x: float) -> void:
	var t := clampf((x - 6.0) / maxf(size.x - 12.0, 1.0), 0.0, 1.0)
	var v := _snap_step(vmin + t * (vmax - vmin))
	if v != value:
		value = v
		queue_redraw()
		changed.emit(value)

func _draw_extra() -> void:
	var cx := 6.0 + frac() * maxf(size.x - 12.0, 0.0)
	var cy := size.y * 0.5
	var h := 6.0 * sqrt(2.0)
	var pts := PackedVector2Array([Vector2(cx, cy - h), Vector2(cx + h, cy), Vector2(cx, cy + h), Vector2(cx - h, cy)])
	draw_colored_polygon(pts, HudTheme.ACCENT)
