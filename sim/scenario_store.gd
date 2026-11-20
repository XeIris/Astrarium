class_name ScenarioStore
extends RefCounted

# Uploaded scenario files: a copy of each, kept as written (comments included), listed
# in the Custom group. The original file is never touched.

const GROUP := "custom"
const PREFIX := "custom_"
## Checks point this at a temporary directory so they never read or write the user's.
static var dir := "user://scenarios"

## The same file name always gives the same key, and two names never share one: a name
## that had to be lower-cased or have characters replaced carries a hash of itself.
static func key_for(path: String) -> String:
	var stem := path.get_file().get_basename()
	var out := ""
	for i in stem.length():
		var c := stem[i].to_lower()
		out += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "_"
	if out != stem or out.is_empty(): out += "_" + stem.sha256_text().substr(0, 8)
	return PREFIX + out

static func path_of(key: String) -> String:
	return dir.path_join(key + ".jsonc")

## Every stored file as a preset; one that no longer reads keeps its errors and loads nothing.
static func load_all() -> Dictionary:
	var out := {}
	if not DirAccess.dir_exists_absolute(dir): return out
	for name in DirAccess.get_files_at(dir):
		if not name.ends_with(".jsonc"): continue
		var key := name.get_basename()
		var r := ScenarioFile.read(dir.path_join(name))
		out[key] = _entry(key, r)
	return out

static func _entry(key: String, r: Dictionary) -> Dictionary:
	if r.ok:
		var p: Dictionary = r.preset
		p.group = GROUP
		return p
	return {"name": key.trim_prefix(PREFIX).replace("_", " "), "group": GROUP, "errors": r.errors}

## Validates `path` and, if it reads, copies it in, replacing a copy of the same name.
## Returns { ok, key, preset, errors }.
static func add(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return {"ok": false, "errors": ["cannot open the file: %s" % error_string(FileAccess.get_open_error())]}
	if f.get_length() > ScenarioFile.MAX_BYTES:
		return {"ok": false, "errors": ["the file is larger than %d MB" % (ScenarioFile.MAX_BYTES / 1048576)]}
	var text := f.get_as_text()
	f.close()
	var r := ScenarioFile.from_text(text)
	if not r.ok: return {"ok": false, "errors": r.errors}
	var key := key_for(path)
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK: return {"ok": false, "errors": ["cannot create %s: %s" % [dir, error_string(err)]]}
	# Written beside the copy and renamed over it, so a failed write leaves the old one.
	var part := path_of(key) + ".part"
	var out := FileAccess.open(part, FileAccess.WRITE)
	if out == null: return {"ok": false, "errors": ["cannot save the copy: %s" % error_string(FileAccess.get_open_error())]}
	var wrote := out.store_string(text)
	out.flush()
	wrote = wrote and out.get_error() == OK
	out.close()
	err = DirAccess.rename_absolute(part, path_of(key)) if wrote else ERR_FILE_CANT_WRITE
	if err != OK:
		DirAccess.remove_absolute(part)
		return {"ok": false, "errors": ["cannot save the copy: %s" % error_string(err)]}
	r.preset.file = path_of(key)
	return {"ok": true, "key": key, "preset": _entry(key, r), "errors": []}

static func remove(key: String) -> Error:
	return DirAccess.remove_absolute(path_of(key)) if FileAccess.file_exists(path_of(key)) else ERR_FILE_NOT_FOUND
