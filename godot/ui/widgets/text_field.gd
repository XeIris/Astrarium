class_name TextField
extends El

# ============================================================================
# <input type="search"> — the scenario search. The El draws the field (border,
# background, the accent-2 focus ring); a borderless LineEdit inside it does
# the editing, placed on the content box so its text sits where the input's
# does. The line box is the input's own: `line-height: normal` at 10 px.
# ============================================================================

signal text_changed(text: String)

var edit: LineEdit

func _init(style: Dictionary = {}, vars: Array = [], placeholder := "") -> void:
	super(style, vars)
	edit = LineEdit.new()
	edit.placeholder_text = placeholder
	edit.flat = true
	edit.focus_mode = Control.FOCUS_CLICK
	edit.caret_blink = true
	edit.context_menu_enabled = false
	edit.add_theme_constant_override("minimum_character_width", 0)
	edit.focus_entered.connect(func(): set_state("focus", true))
	edit.focus_exited.connect(func(): set_state("focus", false))
	edit.text_changed.connect(func(t): text_changed.emit(t))
	add_child(edit, false, Node.INTERNAL_MODE_BACK)
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_default_cursor_shape = Control.CURSOR_IBEAM

func _layout_content(cw: float, o: Vector2) -> float:
	var f := HudTheme.font("mono")
	var fs := gf("fs")
	var ad := HudTheme.asc_desc(f, fs)
	var lh := ad.x + ad.y
	edit.add_theme_font_size_override("font_size", int(roundf(fs)))
	edit.position = o + Vector2(0, (lh - edit.get_combined_minimum_size().y) * 0.5)
	edit.size = Vector2(cw, edit.get_combined_minimum_size().y)
	return lh

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		edit.grab_focus()
		accept_event()
