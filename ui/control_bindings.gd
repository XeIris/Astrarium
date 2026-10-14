class_name ControlBindings
extends RefCounted

signal persistence_failed(message: String)
const JsonFile = preload("res://core/json_file.gd")

# Physical keys keep the same position across keyboard layouts. The last three
# values are Shift, Ctrl and Alt modifiers; a modifier used alone ignores them.
const GROUPS := [
	["General", [["settings", "Settings"], ["pause", "Pause simulation"],
		["reset_view", "Reset camera"], ["free_view", "Free camera"],
		["surface_view", "Surface view"], ["hide_hud", "Hide HUD"],
		["delete_body", "Remove focused object"]]],
	["Imaging", [["band_1", "Band 1"], ["band_2", "Band 2"],
		["band_3", "Band 3"], ["band_4", "Band 4"], ["band_5", "Band 5"],
		["band_6", "Band 6"], ["band_7", "Band 7"]]],
	["Free camera", [["move_forward", "Move forward"], ["move_back", "Move back"],
		["move_left", "Move left"], ["move_right", "Move right"],
		["move_up", "Move up"], ["move_down", "Move down"],
		["move_fast", "Move faster"]]],
	["Spaceflight", [["warp_down", "Slow time"], ["warp_up", "Speed time"],
		["throttle_cut", "Cut throttle"], ["throttle_full", "Full throttle"],
		["throttle_up", "Increase throttle"], ["throttle_down", "Decrease throttle"],
		["stage", "Separate stage"], ["gear", "Toggle gear"],
		["flight_camera", "Cycle flight camera"], ["flight_follow", "Follow a dropped stage"],
		["space_map", "Space map"]]],
]

const DEFAULTS := {
	"settings": [KEY_ESCAPE, false, false, false],
	"pause": [KEY_SPACE, false, false, false],
	"reset_view": [KEY_R, false, false, false],
	"free_view": [KEY_F, false, false, false],
	"surface_view": [KEY_V, false, false, false],
	"hide_hud": [KEY_H, false, false, false],
	"delete_body": [KEY_BACKSPACE, false, false, false],
	"band_1": [KEY_1, false, false, false],
	"band_2": [KEY_2, false, false, false],
	"band_3": [KEY_3, false, false, false],
	"band_4": [KEY_4, false, false, false],
	"band_5": [KEY_5, false, false, false],
	"band_6": [KEY_6, false, false, false],
	"band_7": [KEY_7, false, false, false],
	"move_forward": [KEY_W, false, false, false],
	"move_back": [KEY_S, false, false, false],
	"move_left": [KEY_A, false, false, false],
	"move_right": [KEY_D, false, false, false],
	"move_up": [KEY_E, false, false, false],
	"move_down": [KEY_Q, false, false, false],
	"move_fast": [KEY_SHIFT, false, false, false],
	"warp_down": [KEY_COMMA, false, false, false],
	"warp_up": [KEY_PERIOD, false, false, false],
	"throttle_cut": [KEY_X, false, false, false],
	"throttle_full": [KEY_Z, false, false, false],
	"throttle_up": [KEY_SHIFT, false, false, false],
	"throttle_down": [KEY_CTRL, false, false, false],
	"stage": [KEY_SPACE, true, false, false],
	"gear": [KEY_G, false, false, false],
	"flight_camera": [KEY_C, false, false, false],
	"flight_follow": [KEY_B, false, false, false],
	"space_map": [KEY_M, false, false, false],
}

const DEFAULT_FILE := "user://controls.json"
var file_path := DEFAULT_FILE
var bindings: Dictionary = DEFAULTS.duplicate(true)
var last_error := ""
var _save_blocked := false
var _blocked_reason := ""

func _init(path := DEFAULT_FILE) -> void:
	file_path = path
	if file_path == "": return
	var result := JsonFile.read_dict(file_path, _valid_saved_bindings)
	if result.error == ERR_FILE_NOT_FOUND: return
	if result.error != OK:
		_save_blocked = true
		_blocked_reason = result.message + " Defaults are active; repair the file or Reset bindings before saving."
		_report(_blocked_reason)
		return
	bindings = _with_saved(result.data)
	for action in DEFAULTS:
		if not result.data.has(action) and bindings[action] != DEFAULTS[action]:
			_report("%s is new; its default key was taken, so it is on %s." % [action, OS.get_keycode_string(int(bindings[action][0]))])
	_save_blocked = result.pending
	if result.pending: _blocked_reason = result.message + " Repair the file or Reset bindings before saving."
	if result.message != "": _report(result.message)
	if not result.pending and JsonFile.finish_recovery(file_path) != OK:
		_report("Controls loaded, but recovery file %s.bak could not be removed; make its folder writable." % file_path)
	var unknown: Array = []
	for action in result.data:
		if not DEFAULTS.has(action): unknown.append(str(action))
	if not unknown.is_empty(): _report("Ignored unknown controls in %s: %s." % [file_path, ", ".join(unknown)])

func save(reset_file := false) -> bool:
	if file_path == "": return true
	if _save_blocked:
		_report(_blocked_reason)
		return false
	for action in DEFAULTS:
		if _validated_binding(action, bindings.get(action)).is_empty():
			_report("Cannot save %s: invalid binding for %s." % [file_path, action])
			return false
	var invalid := _conflict(bindings)
	if invalid != "":
		_report("Cannot save %s: %s." % [file_path, invalid])
		return false
	var result := JsonFile.write_dict(file_path, bindings, false, Callable(), reset_file, _valid_saved_bindings)
	if result.error != OK:
		_report(result.message)
		return false
	last_error = ""
	if result.message != "": _report(result.message)
	return true

func reset() -> bool:
	var previous := bindings
	var blocked := _save_blocked
	bindings = DEFAULTS.duplicate(true)
	_save_blocked = false
	if save(true):
		_blocked_reason = ""
		return true
	bindings = previous
	_save_blocked = blocked
	return false

func bind(action: String, binding: Array) -> bool:
	last_error = ""
	if not DEFAULTS.has(action):
		last_error = "Unknown control action: %s." % action
		return false
	var validated := _validated_binding(action, binding)
	if validated.is_empty():
		last_error = "Invalid key or modifiers for %s." % action
		return false
	var previous := bindings
	var candidate := bindings.duplicate(true)
	var old: Array = candidate[action]
	for other in candidate:
		if other != action and _same_context(action, other) and candidate[other] == validated:
			if action == "settings" or other == "settings":
				last_error = "Choose a key not reserved for Settings."
				return false
			candidate[other] = old
	candidate[action] = validated
	var invalid := _conflict(candidate)
	if invalid != "":
		last_error = invalid
		return false
	bindings = candidate
	if save(): return true
	bindings = previous
	return false

func _valid_saved_bindings(data: Dictionary) -> bool:
	var candidate := _with_saved(data)
	return not candidate.is_empty() and _conflict(candidate) == ""

## Actions added after controls.json first shipped. A file written before them cannot
## hold them, so their defaults give way to its keys rather than reject it.
const ADDED := ["space_map", "flight_follow"]

## A saved file's bindings, with defaults for what it leaves out. An ADDED action it
## lacks keeps its default key unless the file already uses it in the same context;
## then it takes the first free letter, digit or function key. Any other conflict still
## rejects the file. Empty when a saved binding is invalid.
func _with_saved(data: Dictionary) -> Dictionary:
	var candidate := {}
	for action in DEFAULTS:
		if not data.has(action): continue
		var validated := _validated_binding(action, data[action])
		if validated.is_empty(): return {}
		candidate[action] = validated
	for action in DEFAULTS:
		if not candidate.has(action) and not ADDED.has(action): candidate[action] = (DEFAULTS[action] as Array).duplicate()
	for action in ADDED:
		if candidate.has(action): continue
		var want: Array = (DEFAULTS[action] as Array).duplicate()
		if _taken(candidate, action, want):
			for code in range(KEY_A, KEY_Z + 1) + range(KEY_0, KEY_9 + 1) + range(KEY_F1, KEY_F12 + 1):
				want = [code, false, false, false]
				if not _taken(candidate, action, want): break
		candidate[action] = want
	return candidate

func _taken(candidate: Dictionary, action: String, binding: Array) -> bool:
	for other in candidate:
		if other != action and _same_context(action, other) and candidate[other] == binding: return true
	return false

func _validated_binding(action: String, value) -> Array:
	if not value is Array or value.size() != 4: return []
	var code = value[0]
	if not (code is int or code is float) or not is_finite(float(code)) or float(code) != floorf(float(code)) or code <= 0 or code > KEY_CODE_MASK: return []
	for i in range(1, 4):
		if not value[i] is bool: return []
	if action != "settings" and int(code) == KEY_ESCAPE: return []
	if action.begins_with("move_") or int(code) in [KEY_SHIFT, KEY_CTRL, KEY_ALT]: return [int(code), false, false, false]
	return [int(code), value[1], value[2], value[3]]

func _conflict(candidate: Dictionary) -> String:
	var actions := DEFAULTS.keys()
	for i in actions.size():
		for j in range(i + 1, actions.size()):
			if _same_context(actions[i], actions[j]) and candidate[actions[i]] == candidate[actions[j]]:
				return "%s and %s use the same key" % [actions[i], actions[j]]
	return ""

func _report(message: String) -> void:
	if message == last_error: return
	last_error = message
	push_warning(message)
	persistence_failed.emit(message)

func _same_context(a: String, b: String) -> bool:
	if a == "settings" or b == "settings": return true
	var af := _is_flight(a)
	var bf := _is_flight(b)
	return af == bf or a == "pause" or b == "pause"

func _is_flight(action: String) -> bool:
	return ["warp_down", "warp_up", "throttle_cut", "throttle_full", "throttle_up",
		"throttle_down", "stage", "gear", "flight_camera", "flight_follow"].has(action)

func matches(action: String, event: InputEventKey) -> bool:
	var b: Array = bindings[action]
	var code := event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if code != int(b[0]): return false
	if code == KEY_SHIFT or code == KEY_CTRL or code == KEY_ALT: return true
	return event.shift_pressed == b[1] and event.ctrl_pressed == b[2] and event.alt_pressed == b[3]

func held(action: String, keys: Dictionary) -> bool:
	var b: Array = bindings[action]
	return bool(keys.get(int(b[0]), false))
