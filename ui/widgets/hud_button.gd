class_name HudButton
extends Button

# A HUD button of one kind (HudTheme.KINDS, a Theme type variation). Its active
# state is the "<kind>On" variation, set by the orchestrator rather than toggled by
# the click, since main decides what a press means. Kinds marked `up` show their
# text in capitals (Button has no text-transform).

var kind := "Toggle"
var active := false
var _label := ""

func _init(k := "Toggle", t := "", tip := "") -> void:
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	set_kind(k)
	set_label(t)
	if tip != "":
		tooltip_text = tip

func set_kind(k: String) -> void:
	kind = k
	alignment = HudTheme.kind_align(k)
	# a list button's text wraps to its cell rather than widening it
	if bool((HudTheme.KINDS.get(k, {}).get("base", {}) as Dictionary).get("wrap", false)):
		autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_restyle()

func set_label(t: String) -> void:
	_label = t
	text = t.to_upper() if HudTheme.kind_up(kind) else t

func get_label() -> String:
	return _label

func set_active(on: bool) -> void:
	if active == on:
		return
	active = on
	_restyle()

func set_enabled(on: bool) -> void:
	disabled = not on
	modulate.a = 1.0 if on else 0.3
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if on else Control.CURSOR_ARROW

func _restyle() -> void:
	var on := active and (HudTheme.KINDS[kind] as Dictionary).has("on")
	theme_type_variation = kind + ("On" if on else "")
