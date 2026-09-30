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

static func _path(key: String) -> String:
	for i in ICONS:
		if i[0] == key: return i[2]
	return ""

static func saved() -> String:
	var file := FileAccess.open(FILE, FileAccess.READ)
	if file == null: return DEFAULT
	var data = JSON.parse_string(file.get_as_text())
	var key: String = String(data.get("icon", DEFAULT)) if data is Dictionary else DEFAULT
	return key if _path(key) != "" else DEFAULT

## Set the running app's icon and remember the choice. Returns false for an
## unknown key; a platform with no settable icon (web) still saves it.
static func apply(key: String, persist := true) -> bool:
	var p := _path(key)
	if p == "": return false
	if DisplayServer.has_feature(DisplayServer.FEATURE_ICON):
		var tex := load(p) as Texture2D
		if tex != null: DisplayServer.set_icon(tex.get_image())
	if persist:
		var data := {}
		var file := FileAccess.open(FILE, FileAccess.READ)
		if file != null:
			var old = JSON.parse_string(file.get_as_text())
			if old is Dictionary: data = old
			file.close()
		data.icon = key
		file = FileAccess.open(FILE, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(data, "\t"))
	return true

## A small, properly filtered copy for the settings swatch — the 512 px import
## drawn straight into 28 px would alias, since it carries no mipmaps.
static func thumb(key: String, px: int) -> Texture2D:
	var tex := load(_path(key)) as Texture2D
	if tex == null: return null
	var img := tex.get_image()
	img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)
