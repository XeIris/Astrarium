class_name HudSelect
extends OptionButton

# A choice from a short list, as [[value, label], ...]. `chosen` fires on the user's
# pick only; set_value() changes it silently.

signal chosen(value: String)

var options: Array = []
var value := ""

func _init(kind := "FdSelect") -> void:
	theme_type_variation = kind
	focus_mode = Control.FOCUS_NONE
	fit_to_longest_item = false
	clip_text = true
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	item_selected.connect(_on_item)

func set_options(opts: Array, current := "") -> void:
	options = opts
	clear()
	for i in opts.size():
		add_item(str(opts[i][1]), i)
	set_value(current if current != "" or opts.is_empty() else str(opts[0][0]))

func set_value(v: String) -> void:
	value = v
	for i in options.size():
		if options[i][0] == v:
			if selected != i: select(i)
			return

func _on_item(i: int) -> void:
	value = str(options[i][0])
	chosen.emit(value)
