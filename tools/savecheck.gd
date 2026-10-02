extends SceneTree

# Isolated fixtures exercise POSIX publication and the Windows backup protocol.
# Run: Godot --headless --path . --script res://tools/savecheck.gd
const JsonFile = preload("res://core/json_file.gd")
var failures: Array[String] = []
var checks := 0
var folder := ""

class ScriptErrors extends Logger:
	var errors: Array[String] = []
	func _log_error(_function: String, file: String, line: int, code: String, rationale: String,
			_notify: bool, kind: int, _traces: Array[ScriptBacktrace]) -> void:
		if kind == ERROR_TYPE_SCRIPT:
			errors.append("%s:%d: %s" % [file, line, rationale if rationale != "" else code])
	func _log_message(_message: String, _error: bool) -> void:
		pass

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func put(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		failures.append("Cannot create fixture: " + path)
		return
	file.store_string(content)
	file.close()

func content(path: String) -> String:
	return FileAccess.get_file_as_string(path)

func same_json(a, b) -> bool:
	return JSON.parse_string(JSON.stringify(a)) == JSON.parse_string(JSON.stringify(b))

func fail_at(operations: Array) -> Callable:
	return func(operation: String, _from: String, _to: String) -> Error:
		return ERR_CANT_CREATE if operations.has(operation) else OK

func no_temps() -> bool:
	for name in DirAccess.get_files_at(folder):
		if ".tmp." in name: return false
	return true

func publication() -> void:
	var path := folder.path_join("atomic.json")
	var old := {"number": 42, "array": [1, false], "nested": {"keep": "yes"}}
	var newer := {"number": 12, "array": [2, true], "nested": {"keep": "new"}}
	expect(JsonFile.write_dict(path, old).error == OK, "integer/nested JSON verifies after decoding")
	var original := content(path)
	for backup_mode in [false, true]:
		for operations in [["write"], ["replace"], ["backup"]]:
			var result := JsonFile.write_dict(path, newer, backup_mode, fail_at(operations))
			if not backup_mode and operations == ["backup"]:
				expect(result.error == OK, "POSIX does not rename the old file away")
				JsonFile.write_dict(path, old)
			else:
				expect(result.error != OK and content(path) == original, "failure preserves old JSON: %s/%s" % [backup_mode, operations])
			expect(no_temps() and not FileAccess.file_exists(path + ".bak"), "normal failure leaves no temp or backup")
	var corrupt_write := func(operation: String, from: String, _to: String) -> Error:
		if operation == "write": put(from, '{"truncated":')
		return OK
	expect(JsonFile.write_dict(path, newer, false, corrupt_write).error != OK and content(path) == original and no_temps(), "verification rejects truncated temporary data before publication")
	var failed := JsonFile.write_dict(path, newer, true, fail_at(["replace", "restore"]))
	expect(failed.error != OK and not FileAccess.file_exists(path) and content(path + ".bak") == original, "failed restoration retains last valid backup")
	expect(no_temps(), "failed restoration cleans temporary save")
	expect(JsonFile.write_dict(path, newer).error != OK, "unresolved backup blocks later publication")
	var recovered := JsonFile.read_dict(path)
	expect(recovered.error == OK and same_json(recovered.data, old) and content(path) == original, "missing primary recovers interrupted backup")
	expect(JsonFile.write_dict(path, newer, true).error == OK and same_json(JsonFile.read_dict(path).data, newer), "backup publication succeeds and removes backup")
	expect(no_temps() and not FileAccess.file_exists(path + ".bak"), "successful publication leaves no debris")
	DirAccess.rename_absolute(path, path + ".bak")
	put(path, '{"truncated":')
	recovered = JsonFile.read_dict(path)
	expect(recovered.error == OK and recovered.pending and same_json(recovered.data, newer), "corrupt primary uses backup without overwriting evidence")
	expect(content(path) == '{"truncated":' and FileAccess.file_exists(path + ".bak"), "recovery retains both files for repair")
	expect(JsonFile.write_dict(path, old, false, Callable(), true).error == OK, "explicit Reset resolves pending recovery")
	expect(same_json(JsonFile.read_dict(path).data, old) and not FileAccess.file_exists(path + ".bak"), "Reset publishes before deleting recovery backup")
	JsonFile.write_dict(path, newer)
	JsonFile.write_dict(path + ".bak", old)
	var destructive_replace := func(operation: String, _from: String, to: String) -> Error:
		if operation != "replace": return OK
		if FileAccess.file_exists(to): DirAccess.remove_absolute(to)
		return ERR_CANT_CREATE
	expect(JsonFile.write_dict(path, old, true, destructive_replace, true).error != OK and same_json(JsonFile.read_dict(path).data, newer), "destructive Windows publication failure retains latest primary despite stale backup")
	JsonFile.write_dict(path + ".bak", old)
	expect(JsonFile.write_dict(path, old, true, fail_at(["cleanup"]), true).error != OK and same_json(JsonFile.read_dict(path).data, newer) and FileAccess.file_exists(path + ".bak"), "failed stale-backup cleanup refuses Reset without changing either file")
	DirAccess.remove_absolute(path + ".bak")
	put(path, '{"wrongSchema":true}')
	JsonFile.write_dict(path + ".bak", old)
	var has_number := func(data: Dictionary) -> bool: return data.has("number")
	expect(JsonFile.write_dict(path, newer, true, destructive_replace, true, has_number).error != OK and same_json(JsonFile.read_dict(path, has_number).data, old), "schema-invalid primary cannot displace last valid backup on failed Reset")

func controls() -> void:
	var path := folder.path_join("controls.json")
	var bindings := ControlBindings.new(path)
	expect(bindings.bind("reset_view", [KEY_T, false, false, false]), "valid binding saves")
	var reload := ControlBindings.new(path)
	expect(reload.bindings.reset_view[0] == KEY_T, "binding round trips")
	expect(reload.bind("reset_view", reload.bindings.free_view), "conflicting keys swap")
	expect(reload.bindings.free_view[0] == KEY_T and reload.bindings.reset_view[0] == KEY_F, "swap preserves both actions")
	expect(not reload.bind("pause", [KEY_ESCAPE, false, false, false]), "Settings reserved key rejected")
	expect(not reload.bind("pause", [KEY_P, 0, false, false]), "non-boolean modifier rejected")
	expect(not reload.bind("pause", [1.5, false, false, false]), "fractional key rejected")
	expect(reload.bind("move_forward", [KEY_I, true, true, true]) and reload.bindings.move_forward == [KEY_I, false, false, false], "held movement keys normalize modifiers")
	var before := reload.bindings.duplicate(true)
	reload.file_path = folder.path_join("missing/controls.json")
	expect(not reload.bind("reset_view", [KEY_T, false, false, false]) and reload.bindings == before, "failed save rolls back changed bindings")
	expect(not reload.reset() and reload.bindings == before, "failed Reset preserves in-memory bindings")
	put(path, '{"pause":')
	var corrupt := ControlBindings.new(path)
	var original := content(path)
	for attempt in 2:
		expect(not corrupt.bind("reset_view", [KEY_T, false, false, false]) and "Reset bindings" in corrupt.last_error, "blocked save repeats actionable diagnostic")
	expect(content(path) == original and corrupt.bindings == ControlBindings.DEFAULTS, "malformed controls remain untouched")
	expect(corrupt.reset() and ControlBindings.new(path).bindings == ControlBindings.DEFAULTS, "explicit Reset repairs malformed controls")
	put(path, JSON.stringify({"pause": [KEY_F, false, false, false]}))
	var invalid := ControlBindings.new(path)
	expect(invalid._save_blocked and invalid.bindings == ControlBindings.DEFAULTS, "conflicting loaded keys reject the entire candidate")
	put(path, JSON.stringify({"stage": [KEY_CTRL, true, true, true]}))
	invalid = ControlBindings.new(path)
	expect(invalid._save_blocked, "standalone modifier conflicts cannot hide behind ignored modifier flags")
	put(path + ".bak", '{"pause":[0,false,false,false]}')
	DirAccess.remove_absolute(path)
	invalid = ControlBindings.new(path)
	expect(invalid._save_blocked and not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".bak"), "invalid-schema backup is not promoted or deleted")
	expect(invalid.reset() and not FileAccess.file_exists(path + ".bak"), "explicit Reset replaces invalid-schema backup safely")
	JsonFile.write_dict(path, ControlBindings.DEFAULTS)
	DirAccess.rename_absolute(path, path + ".bak")
	var resumed := ControlBindings.new(path)
	expect(not resumed._save_blocked and resumed.bindings == ControlBindings.DEFAULTS and FileAccess.file_exists(path), "valid controls recover after interrupted publication")
	JsonFile.write_dict(path + ".bak", ControlBindings.DEFAULTS)
	put(path, '{"pause": [0,false,false,false]}')
	resumed = ControlBindings.new(path)
	expect(resumed._save_blocked and FileAccess.file_exists(path + ".bak"), "schema-invalid primary retains valid fallback and blocks autosave")
	expect(resumed.reset() and not FileAccess.file_exists(path + ".bak"), "controls Reset resolves fallback without silent autosave")

func course() -> void:
	var path := folder.path_join("progress.json")
	var lesson: String = Lessons.MODULES[0].id + "/" + Lessons.MODULES[0].lessons[0].id
	var messages: Array = []
	var controller := LessonUI.Course.new({"store": path, "stage": {"toast": func(message): messages.append(message)}})
	controller.progress = {"done": {lesson: true}, "last": lesson}
	expect(controller._save_progress(), "course progress saves")
	var loaded := LessonUI.Course.new({"store": path})
	expect(loaded.progress == controller.progress, "course progress round trips")
	controller.store = folder.path_join("missing/progress.json")
	var previous := controller.progress.duplicate(true)
	controller._reset_progress()
	expect(controller.progress == previous and not messages.is_empty(), "failed course Reset retains progress and displays error")
	put(path, '{"done":{"unknown":17},"last":null}')
	var malformed := content(path)
	loaded = LessonUI.Course.new({"store": path, "stage": {"toast": func(message): messages.append(message)}})
	expect(loaded._save_blocked and not loaded._save_progress() and content(path) == malformed, "invalid progress schema blocks automatic overwrite")
	loaded._reset_progress()
	expect(not loaded._save_blocked and JsonFile.read_dict(path).data == {"done": {}, "last": null}, "course Reset repairs invalid schema")
	put(path, '{"done":{')
	JsonFile.write_dict(path + ".bak", previous)
	loaded = LessonUI.Course.new({"store": path})
	expect(loaded.progress == previous and loaded._save_blocked, "valid course fallback remains usable with saving paused")
	loaded._reset_progress()
	expect(not loaded._save_blocked and not FileAccess.file_exists(path + ".bak"), "course Reset resolves recovery backup")
	JsonFile.write_dict(path, {"done": {"unknown/retired": true, lesson: true}, "last": "unknown/retired"})
	loaded = LessonUI.Course.new({"store": path})
	expect(loaded.progress.done == {lesson: true} and loaded.progress.last == null and loaded.last_error != "", "unavailable lesson IDs are ignored visibly")
	var memory_only := LessonUI.Course.new({"store": ""})
	expect(memory_only._save_progress(), "checks can disable progress persistence")

func icon() -> void:
	var previous_path := AppIcon.file_path
	var path := folder.path_join("app.json")
	AppIcon.file_path = path
	JsonFile.write_dict(path, {"icon": "ember", "otherSetting": 42})
	expect(AppIcon.saved() == "ember" and AppIcon.apply("bluehot"), "icon choice saves")
	expect(same_json(JsonFile.read_dict(path).data, {"icon": "bluehot", "otherSetting": 42}), "icon save retains unrelated settings")
	put(path, '{"icon":')
	var malformed := content(path)
	expect(AppIcon.saved() == AppIcon.DEFAULT and not AppIcon.apply("ember") and "Repair" in AppIcon.last_error, "malformed icon save blocks with visible repair instruction")
	expect(content(path) == malformed, "icon save preserves malformed evidence")
	put(path, '{"icon":"unknown"}')
	expect(not AppIcon.apply("ember"), "unknown saved icon rejects automatic overwrite")
	AppIcon.file_path = folder.path_join("missing/app.json")
	expect(not AppIcon.apply("ember") and AppIcon.last_error != "", "failed icon publication reports failure")
	AppIcon.file_path = previous_path
	AppIcon.last_error = ""

func _init() -> void:
	var script_errors := ScriptErrors.new()
	OS.add_logger(script_errors)
	folder = OS.get_temp_dir().path_join("astrarium-savecheck-" + Crypto.new().generate_random_bytes(12).hex_encode())
	if DirAccess.make_dir_absolute(folder) != OK:
		push_error("Cannot create temporary fixture directory")
		quit(1)
		return
	publication()
	controls()
	course()
	icon()
	failures.append_array(script_errors.errors)
	OS.remove_logger(script_errors)
	expect(no_temps(), "all consumer operations leave no temporary files")
	for name in DirAccess.get_files_at(folder): DirAccess.remove_absolute(folder.path_join(name))
	DirAccess.remove_absolute(folder)
	for failure in failures: push_error(failure)
	print("SAVECHECK %d/%d checks passed (POSIX + simulated backup protocol)." % [checks - failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
