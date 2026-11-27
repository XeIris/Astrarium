class_name SaveBrowser
extends Control

# The saved games of one kind (sim/save_store.gd) over a dimmed frame: load one, or save
# the scene into one of its ten slots, and rename or delete either way. Overwriting,
# deleting, renaming and loading over a scene in play each ask first. The exit prompt
# uses the same card. Renames and deletes touch only the files; main saves and loads.

signal save_chosen(kind: String, slot: int, name: String)
signal load_chosen(kind: String, slot: int)
signal closed()

const KICK := {"fs": 9.0, "ls": 3.0, "up": true, "c": HudTheme.TEXT_DIM, "fw": 500}
const TITLE := {"fs": 17.0, "ls": 3.0, "up": true, "c": HudTheme.ACCENT, "lh": 1.2}
const NAME := {"fs": 12.0, "c": HudTheme.ACCENT}
const META := {"fs": 9.5, "c": HudTheme.TEXT_DIM, "lh": 1.45}
const BAD := {"fs": 9.5, "c": HudTheme.WARN, "lh": 1.45}
const TEXT := {"fs": 11.0, "c": HudTheme.TEXT, "lh": 1.5}
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var kind := "sandbox"
var mode := "load"              # "load" or "save"
var sort_by := "date"
## Loading would replace a scene in play, so it asks first.
var live_scene := false
## Save mode: {name, summary} of the scene that would be saved.
var offer := {}
var entries: Array = []
## The view on the card: list, name, confirm or prompt.
var view := ""
var _error := ""
var _back := Callable()         # what Esc does on a confirm or prompt
var _field: LineEdit = null

var _backdrop: ColorRect
var card: HudPanel

func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop = ColorRect.new()
	_backdrop.color = HudTheme.rgba(2, 4, 9, 0.8)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)
	card = HudPanel.new([20, 22, 20, 22])
	add_child(card)
	card.pad.minimum_size_changed.connect(_layout)

## Open on the slots of `k` (SaveStore.KINDS) to load (`m` "load") or to save `scene` into.
func open(k: String, m: String, scene := {}, in_play := false) -> void:
	kind = k
	mode = m
	offer = scene
	live_scene = in_play
	_error = ""
	visible = true
	refresh()

func close() -> void:
	if not visible: return
	visible = false
	_field = null
	view = ""
	closed.emit()

## Re-read the slots and show the list, with `error` over it if a save or load failed.
func refresh(error := "") -> void:
	_error = error
	entries = SaveStore.list(kind)
	_show_list()

func show_error(msg: String) -> void:
	refresh(msg)

# VIEWS

func _clear() -> void:
	_field = null
	for c in card.body.get_children():
		card.body.remove_child(c)
		c.queue_free()

func _head(kick: String, title: String) -> void:
	Hud.label(card.body, kick, KICK)
	HudStack.m(Hud.label(card.body, title, TITLE), 6.0, 14.0)

func _button(parent: Node, k: String, text: String, sel: String, on: Callable) -> HudButton:
	var b := HudButton.new(k, text)
	b.set_meta("sel", sel)
	b.pressed.connect(on)
	parent.add_child(b)
	return b

func _show_list() -> void:
	view = "list"
	_back = Callable()
	_clear()
	var label: String = SaveStore.KINDS.get(kind, kind)
	_head("%s · %s" % [label, "save game" if mode == "save" else "load game"],
		"Choose a slot" if mode == "save" else "Saved games")
	if _error != "":
		HudStack.m(Hud.label(card.body, _error, BAD, true), 0.0, 12.0)
	var used := entries.filter(func(e): return e.status != "empty").size()
	if mode == "save":
		HudStack.m(Hud.label(card.body, "Saving: %s" % str(offer.get("summary", "")), META, true), 0.0, 4.0)
		var note := "%d of %d slots used." % [used, SaveStore.SLOTS]
		if used >= SaveStore.SLOTS: note += " Overwrite one, or delete one first."
		HudStack.m(Hud.label(card.body, note, META, true), 0.0, 14.0)
		for e in entries: _row(e)
	else:
		var sort := Hud.hbox(card.body, 6.0, 0.0, 12.0)
		var by_date := _button(sort, "Toggle", "Newest first", "saveSortDate", func(): _sort("date"))
		var by_name := _button(sort, "Toggle", "By name", "saveSortName", func(): _sort("name"))
		by_date.set_active(sort_by == "date")
		by_name.set_active(sort_by == "name")
		var shown := SaveStore.sorted(entries, sort_by)
		if shown.is_empty():
			HudStack.m(Hud.label(card.body, "No %s games are saved yet. Save one from Settings › Saves while you play." % label.to_lower(), META, true), 0.0, 10.0)
		for e in shown: _row(e)
	var foot := Hud.hbox(card.body, 8.0, 10.0, 0.0)
	_button(foot, "Ghost", "Close", "saveClose", close)

func _sort(by: String) -> void:
	sort_by = by
	_show_list()

func _row(e: Dictionary) -> void:
	var box := Hud.stack(null)
	var f := Hud.frame(box, {"bc": HudTheme.BORDER, "pad": [10, 12, 10, 12]})
	HudStack.m(f, 0.0, 8.0)
	card.body.add_child(f)
	var slot := int(e.slot)
	var top := Hud.hbox(box, 10.0)
	match str(e.status):
		"empty":
			var n := Hud.label(top, "Slot %d · empty" % (slot + 1), META)
			n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			_button(top, "Secondary", "Save here", "saveHere%d" % slot, func(): _save_new(slot))
		"bad":
			var n := Hud.label(top, str(e.name) if str(e.name) != "" else "Unreadable save", BAD)
			n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			_button(top, "Action", "Delete", "saveDelete%d" % slot, func(): _delete(e))
			HudStack.m(Hud.label(box, "Slot %d · %s" % [slot + 1, str(e.error)], BAD, true), 6.0, 0.0)
			if mode == "save":
				HudStack.m(Hud.label(box, "Delete it to use this slot.", META, true), 4.0, 0.0)
		_:
			var n := Hud.label(top, str(e.name), NAME)
			n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			n.clip_text = true
			if mode == "save":
				_button(top, "Secondary", "Overwrite", "saveOverwrite%d" % slot, func(): _overwrite(e))
			else:
				_button(top, "Primary", "Load", "saveLoad%d" % slot, func(): _load(e))
			_button(top, "Ghost", "Rename", "saveRename%d" % slot, func(): _rename(e))
			_button(top, "Action", "Delete", "saveDelete%d" % slot, func(): _delete(e))
			HudStack.m(Hud.label(box, "Slot %d · %s" % [slot + 1, when(float(e.saved))], META), 6.0, 0.0)
			if str(e.summary) != "": HudStack.m(Hud.label(box, str(e.summary), META, true), 2.0, 0.0)

## A local date and time: "27 Nov 2026, 14:05".
static func when(unix: float) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(int(unix) + bias)
	return "%d %s %d, %02d:%02d" % [d.day, MONTHS[clampi(int(d.month) - 1, 0, 11)], d.year, d.hour, d.minute]

## Ask for a name, then `on_ok(name)`. Enter takes it; Esc goes back to the list.
func _ask_name(kick: String, title: String, initial: String, ok_label: String, on_ok: Callable) -> void:
	view = "name"
	_back = _show_list
	_clear()
	_head(kick, title)
	_field = LineEdit.new()
	_field.text = initial
	_field.max_length = SaveStore.NAME_MAX
	_field.placeholder_text = "Name this save"
	_field.caret_blink = true
	_field.custom_minimum_size = Vector2(0, 28)
	HudStack.m(_field, 0.0, 6.0)
	card.body.add_child(_field)
	var err := Hud.label(card.body, "", BAD, true)
	var submit := func(_t = ""):
		var name := _field.text.strip_edges() if _field != null else ""
		var why := SaveStore.name_error(name)
		if why != "":
			(err as Prose).say(why)
			return
		on_ok.call(name)
	_field.text_submitted.connect(submit)
	var foot := Hud.hbox(card.body, 8.0, 12.0, 0.0)
	_button(foot, "Primary", ok_label, "saveNameOk", submit)
	_button(foot, "Ghost", "Cancel", "saveNameCancel", _show_list)
	(func():
		if _field != null and is_instance_valid(_field):
			_field.grab_focus()
			_field.select_all()).call_deferred()

## Ask before `on_ok`. Cancel and Esc call `on_cancel`, or go back to the list.
func confirm(kick: String, title: String, text: String, ok_label: String, on_ok: Callable, danger := false, on_cancel := Callable()) -> void:
	view = "confirm"
	visible = true
	_back = on_cancel if on_cancel.is_valid() else _show_list
	_clear()
	_head(kick, title)
	HudStack.m(Hud.label(card.body, text, TEXT, true), 0.0, 14.0)
	var foot := Hud.hbox(card.body, 8.0)
	_button(foot, "Action" if danger else "Primary", ok_label, "saveConfirmOk", on_ok)
	_button(foot, "Ghost", "Cancel", "saveConfirmCancel", _back)

## A card of its own: `buttons` is [[label, kind, Callable]], the last of them what Esc does.
func prompt(kick: String, title: String, text: String, buttons: Array) -> void:
	view = "prompt"
	visible = true
	_clear()
	_head(kick, title)
	HudStack.m(Hud.label(card.body, text, TEXT, true), 0.0, 14.0)
	var foot := Hud.hbox(card.body, 8.0)
	for i in buttons.size():
		var b: Array = buttons[i]
		_button(foot, str(b[1]), str(b[0]), "savePrompt%d" % i, b[2])
	_back = buttons[-1][2] if not buttons.is_empty() else close

# ACTIONS

func _save_new(slot: int) -> void:
	_ask_name("Slot %d" % (slot + 1), "Name this save", str(offer.get("name", "")), "Save",
		func(n: String): save_chosen.emit(kind, slot, n))

func _overwrite(e: Dictionary) -> void:
	var slot := int(e.slot)
	confirm("Slot %d" % (slot + 1), "Overwrite this save?",
		"“%s” is replaced by the scene you are in. This cannot be undone." % e.name, "Overwrite",
		func(): _ask_name("Slot %d" % (slot + 1), "Name this save", str(e.name), "Save",
			func(n: String): save_chosen.emit(kind, slot, n)), true)

func _rename(e: Dictionary) -> void:
	var slot := int(e.slot)
	_ask_name("Slot %d" % (slot + 1), "Rename this save", str(e.name), "Rename", func(n: String):
		if n == str(e.name):
			_show_list()
			return
		confirm("Slot %d" % (slot + 1), "Rename this save?", "Rename “%s” to “%s”?" % [e.name, n], "Rename", func():
			var r := SaveStore.rename(kind, slot, n)
			refresh("" if r.ok else "Could not rename it: %s" % r.error)))

func _delete(e: Dictionary) -> void:
	var slot := int(e.slot)
	var what := "“%s”" % e.name if str(e.name) != "" else "this unreadable save"
	confirm("Slot %d" % (slot + 1), "Delete this save?", "Delete %s? It is gone for good; this cannot be undone." % what, "Delete", func():
		var err := SaveStore.delete(kind, slot)
		refresh("" if err == OK else "Could not delete it: %s" % error_string(err)), true)

func _load(e: Dictionary) -> void:
	var slot := int(e.slot)
	if not live_scene:
		load_chosen.emit(kind, slot)
		return
	confirm("Slot %d" % (slot + 1), "Load this save?",
		"“%s” replaces the scene you are in. Save first if you want to keep it." % e.name, "Load",
		func(): load_chosen.emit(kind, slot))

# INPUT AND LAYOUT

func _input(e: InputEvent) -> void:
	if not visible or not e is InputEventKey: return
	var k := e as InputEventKey
	if not k.pressed or k.echo or k.keycode != KEY_ESCAPE: return
	get_viewport().set_input_as_handled()
	if view == "list": close()
	elif _back.is_valid(): _back.call()
	else: close()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED: _layout()

func _layout() -> void:
	var W := size.x
	var H := size.y
	if W <= 0.0: return
	_backdrop.position = Vector2.ZERO
	_backdrop.size = Vector2(W, H)
	var w := roundf(clampf(W * 0.46, 420.0, 600.0))
	card.size = Vector2(w, 0.0)
	var h := minf(card.natural_height(), roundf(H * 0.84))
	card.size = Vector2(w, h)
	card.position = Vector2(roundf((W - w) * 0.5), roundf((H - h) * 0.5))
