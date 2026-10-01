class_name CapScroll
extends ScrollContainer

# A scroll box as tall as its content up to `cap` px, which ScrollContainer can't
# be on its own (its minimum height is 0 whenever it may scroll vertically).

var cap := 150.0
var content: Control

func _init(max_h := 150.0, c: Control = null) -> void:
	cap = max_h
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	follow_focus = false
	content = c if c != null else HudStack.new(false)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(content)
	content.minimum_size_changed.connect(_fit)
	_fit()

func _fit() -> void:
	var h := minf(content.get_combined_minimum_size().y, cap)
	if absf(custom_minimum_size.y - h) > 0.01:
		custom_minimum_size.y = h
