class_name ControlBindings
extends RefCounted

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
		["flight_camera", "Cycle flight camera"]]],
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
}

const DEFAULT_FILE := "user://controls.json"
var file_path := DEFAULT_FILE
var bindings: Dictionary = DEFAULTS.duplicate(true)

func _init(path := DEFAULT_FILE) -> void:
	file_path = path
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null: return
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary: return
	for action in DEFAULTS:
		var b = data.get(action)
		if b is Array and b.size() == 4 and (b[0] is int or b[0] is float) and b[0] > 0:
			bindings[action] = [int(b[0]), bool(b[1]), bool(b[2]), bool(b[3])]

func save() -> void:
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(bindings, "\t"))

func reset() -> void:
	bindings = DEFAULTS.duplicate(true)
	save()

func bind(action: String, binding: Array) -> bool:
	if not bindings.has(action): return false
	if action.begins_with("move_"):
		binding = [binding[0], false, false, false]
	if action != "settings" and int(binding[0]) == KEY_ESCAPE: return false
	var old: Array = bindings[action]
	for other in bindings:
		if other != action and _same_context(action, other) and bindings[other] == binding:
			if action == "settings" or other == "settings": return false
			bindings[other] = old
	bindings[action] = binding
	save()
	return true

func _same_context(a: String, b: String) -> bool:
	if a == "settings" or b == "settings": return true
	var af := _is_flight(a)
	var bf := _is_flight(b)
	return af == bf or a == "pause" or b == "pause"

func _is_flight(action: String) -> bool:
	return ["warp_down", "warp_up", "throttle_cut", "throttle_full", "throttle_up",
		"throttle_down", "stage", "gear", "flight_camera"].has(action)

func matches(action: String, event: InputEventKey) -> bool:
	var b: Array = bindings[action]
	var code := event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if code != int(b[0]): return false
	if code == KEY_SHIFT or code == KEY_CTRL or code == KEY_ALT: return true
	return event.shift_pressed == b[1] and event.ctrl_pressed == b[2] and event.alt_pressed == b[3]

func held(action: String, keys: Dictionary) -> bool:
	var b: Array = bindings[action]
	return bool(keys.get(int(b[0]), false))
