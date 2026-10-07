class_name HudPanel
extends PanelContainer

# A HUD panel: a 1 px border over a blurred backdrop, and a `body` stack inside the
# padding. With `scrolls`, the padding scrolls with the content and the 4 px thumb
# sits on the inner border edge. The HUD sizes it: natural_height() is its content's
# height, which the left column caps at the space that is left.
#
# It takes the pointer: clicks don't pick through it and a wheel over it never
# reaches the camera, whether or not it has anything to scroll.

var body: HudStack
var scroll: ScrollContainer = null
var pad: MarginContainer
var backdrop: HudBlur.Backdrop = null

func _init(padding: Array = [16, 16, 16, 16], scrolls := true, bg := HudTheme.PANEL, border := HudTheme.BORDER, blur := 10.0) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_force_pass_scroll_events = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = HudTheme.CLEAR if blur > 0.0 and HudBlur.enabled else bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_content_margin_all(1)
	add_theme_stylebox_override("panel", sb)
	if blur > 0.0:
		backdrop = HudBlur.attach(self, bg, blur)
	pad = MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in 4:
		pad.add_theme_constant_override(["margin_top", "margin_right", "margin_bottom", "margin_left"][i], int(padding[i]))
	body = HudStack.new(false)
	pad.add_child(body)
	if scrolls:
		scroll = ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		# Reserve the thumb's width even when hidden. Otherwise wrapped content
		# re-wraps as the thumb appears, its height crosses the fit, and the
		# panel alternates between two heights every frame.
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_RESERVE
		scroll.follow_focus = false
		scroll.mouse_filter = Control.MOUSE_FILTER_PASS
		add_child(scroll)
		scroll.add_child(pad)
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		add_child(pad)

## Height with nothing clipped, at the current width.
func natural_height() -> float:
	return pad.get_combined_minimum_size().y + 2.0

func overflowing() -> bool:
	return scroll != null and natural_height() > size.y + 0.5

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var b := (e as InputEventMouseButton).button_index
		if b == MOUSE_BUTTON_WHEEL_UP or b == MOUSE_BUTTON_WHEEL_DOWN or b == MOUSE_BUTTON_WHEEL_LEFT or b == MOUSE_BUTTON_WHEEL_RIGHT:
			accept_event()
	elif e is InputEventPanGesture:
		accept_event()
