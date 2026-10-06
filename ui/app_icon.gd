class_name AppIcon
extends RefCounted

# THE APP ICON, chosen at runtime. Ray-traced SVGs from tools/icon_trace.mjs,
# imported at svg/scale = 8 (512 px). icon.svg is the default and the export bundle's;
# a running app can only replace its window/dock icon, so the choice is re-applied on
# launch from user://app.json.

## [key, label, resource]. Keep in step with ICONS in tools/icon_trace.mjs.
const ICONS := [
	["ember", "Ember", "res://assets/icons/ember.svg"],
	["bluehot", "Blue-hot", "res://assets/icons/bluehot.svg"],
]
const DEFAULT := "ember"
const FILE := "user://app.json"
const JsonFile = preload("res://core/json_file.gd")
static var file_path := FILE
static var last_error := ""

static func _path(key: String) -> String:
	for i in ICONS:
		if i[0] == key: return i[2]
	return ""

static func saved() -> String:
	var result := _load_saved()
	return str(result.data.get("icon", DEFAULT)) if result.error == OK else DEFAULT

static func _valid_saved(data: Dictionary) -> bool:
	return not data.has("icon") or (data.icon is String and _path(data.icon) != "")

static func _load_saved() -> Dictionary:
	last_error = ""
	var result := JsonFile.read_dict(file_path, _valid_saved)
	if result.error != OK and result.error != ERR_FILE_NOT_FOUND:
		last_error = result.message + " Repair %s before changing the saved icon." % file_path
	elif result.pending:
		last_error = result.message + " Repair %s before changing the saved icon." % file_path
	elif result.error == OK:
		last_error = result.message
		if JsonFile.finish_recovery(file_path) != OK:
			last_error = "Icon loaded, but recovery file %s.bak could not be removed; make its folder writable." % file_path
	if last_error != "": push_warning(last_error)
	return result

## Set the running app's icon and remember the choice. Returns false for an
## unknown key or failed save; a platform with no settable icon still saves it.
static func apply(key: String, persist := true) -> bool:
	var p := _path(key)
	if p == "":
		last_error = "Unknown app icon: %s." % key
		return false
	if persist:
		var result := _load_saved()
		if result.pending or (result.error != OK and result.error != ERR_FILE_NOT_FOUND): return false
		var data: Dictionary = result.data if result.error == OK else {}
		data.icon = key
		result = JsonFile.write_dict(file_path, data)
		last_error = result.message
		if last_error != "": push_warning(last_error)
		if result.error != OK: return false
	if DisplayServer.has_feature(DisplayServer.FEATURE_ICON):
		var tex := load(p) as Texture2D
		if tex != null: DisplayServer.set_icon(tex.get_image())
	return true

## A small, properly filtered copy for the settings swatch — the 512 px import
## drawn straight into 28 px would alias, since it carries no mipmaps.
static func thumb(key: String, px: int) -> Texture2D:
	var tex := load(_path(key)) as Texture2D
	if tex == null: return null
	var img := tex.get_image()
	img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)
