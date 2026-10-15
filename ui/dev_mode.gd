class_name DevMode
extends RefCounted

# The Developer switch in Settings › Controls, saved in user://app.json beside the
# app icon (AppIcon.file_path, so a check that moves one moves both). Off unless
# saved on. It only adds a Settings page, so an export ships it harmlessly; the
# labs that live in tools/ hide themselves there.

const JsonFile = preload("res://core/json_file.gd")
static var last_error := ""

static func _valid(data: Dictionary) -> bool:
	return not data.has("developer") or data.developer is bool

static func enabled() -> bool:
	var result := JsonFile.read_dict(AppIcon.file_path, _valid)
	return result.error == OK and bool(result.data.get("developer", false))

## Remember the switch. False when the file could not be written (last_error says why);
## the switch still applies for this run.
static func save(on: bool) -> bool:
	last_error = ""
	var result := JsonFile.read_dict(AppIcon.file_path, _valid)
	if result.pending or (result.error != OK and result.error != ERR_FILE_NOT_FOUND):
		last_error = "Developer mode not saved: repair %s first." % AppIcon.file_path
		return false
	var data: Dictionary = result.data if result.error == OK else {}
	data.developer = on
	result = JsonFile.write_dict(AppIcon.file_path, data)
	last_error = result.message
	return result.error == OK
