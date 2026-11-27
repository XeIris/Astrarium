class_name SaveStore
extends RefCounted

# Saved games: ten slots for each kind of game, one JSON file per slot under
# `dir/<kind>/`. A file is read whole, its envelope checked and its state validated
# (SaveGame.validate) before anything uses it; one that does not pass is listed with its
# reason and can still be deleted. Format: docs/save-format.md.

const JsonFile = preload("res://core/json_file.gd")
const FORMAT := 1
const SLOTS := 10
const MAX_BYTES := 64 * 1024 * 1024
## The limit in force: MAX_BYTES, which a check lowers to test it without writing 64 MB.
static var max_bytes := MAX_BYTES
const NAME_MAX := 48
const SUMMARY_MAX := 400
## Separate slots per kind; Spaceflight and Planetary exploration share nothing yet.
const KINDS := {"sandbox": "Sandbox", "spaceflight": "Spaceflight", "planetary": "Planetary exploration"}
const TOP_KEYS := ["format", "kind", "name", "saved", "summary", "state"]
## Checks point this at a temporary directory so they never read or write the player's.
static var dir := "user://saves"

static func path_of(kind: String, slot: int) -> String:
	return dir.path_join(kind).path_join("slot_%02d.json" % (slot + 1))

## "" or why `name` cannot name a save.
static func name_error(name: String) -> String:
	var n := name.strip_edges()
	if n.is_empty(): return "Give the save a name."
	if n.length() > NAME_MAX: return "A name has at most %d characters." % NAME_MAX
	for i in n.length():
		if n.unicode_at(i) < 32 or n.unicode_at(i) == 127: return "A name cannot contain control characters."
	return ""

static func _slot_error(kind: String, slot: int) -> String:
	if not KINDS.has(kind): return "There is no save kind \"%s\"." % kind
	if slot < 0 or slot >= SLOTS: return "There is no slot %d." % (slot + 1)
	return ""

## Every slot of `kind` in slot order: {slot, status: empty|ok|bad, name, saved (Unix s),
## summary, error}. A bad slot's name is its file's, when that much still reads.
static func list(kind: String) -> Array:
	var out := []
	for slot in SLOTS:
		var e := {"slot": slot, "status": "empty", "name": "", "saved": 0.0, "summary": "", "error": ""}
		var path := path_of(kind, slot)
		if FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak"):
			var r := _read_raw(kind, slot)
			e.status = "ok" if r.ok else "bad"
			e.error = r.error
			var d: Dictionary = r.raw
			if d.get("name") is String: e.name = str(d.name).left(NAME_MAX)
			if d.get("saved") is float and is_finite(float(d.saved)): e.saved = float(d.saved)
			if d.get("summary") is String: e.summary = str(d.summary).left(SUMMARY_MAX)
		out.append(e)
	return out

## Filled and unreadable slots for a load list: newest first (`by` "date") or by name,
## the unreadable ones last.
static func sorted(entries: Array, by: String) -> Array:
	var out := entries.filter(func(e): return e.status != "empty")
	out.sort_custom(func(a, b):
		if (a.status == "bad") != (b.status == "bad"): return b.status == "bad"
		if by == "name":
			var c := str(a.name).naturalnocasecmp_to(str(b.name))
			if c != 0: return c < 0
		elif a.saved != b.saved:
			return a.saved > b.saved
		return int(a.slot) < int(b.slot))
	return out

## The first empty slot of `kind`, or −1 when all ten are filled.
static func first_free(kind: String) -> int:
	for e in list(kind):
		if e.status == "empty": return int(e.slot)
	return -1

## {ok, error, save}: the slot's envelope with its state decoded.
static func read(kind: String, slot: int) -> Dictionary:
	var r := _read_raw(kind, slot)
	if not r.ok: return {"ok": false, "error": r.error, "save": {}}
	var save: Dictionary = r.raw.duplicate()
	save.state = r.state
	return {"ok": true, "error": "", "save": save}

## {ok, error}. Writes beside the slot and renames over it, so a failed save leaves the
## slot as it was. `saved` < 0 stamps the current time.
static func write(kind: String, slot: int, name: String, summary: String, state: Dictionary, saved := -1.0) -> Dictionary:
	var why := _slot_error(kind, slot)
	if why == "": why = name_error(name)
	if why != "": return {"ok": false, "error": why}
	var enc := SaveCodec.encode(state)
	if enc.error != "": return {"ok": false, "error": "This scene cannot be saved: %s." % enc.error}
	var data := {"format": FORMAT, "kind": kind, "name": name.strip_edges(),
		"saved": saved if saved >= 0.0 else Time.get_unix_time_from_system(),
		"summary": summary.left(SUMMARY_MAX), "state": enc.value}
	return _publish(kind, slot, data)

## {ok, error}. The save keeps its date and its contents.
static func rename(kind: String, slot: int, name: String) -> Dictionary:
	var why := name_error(name)
	if why != "": return {"ok": false, "error": why}
	var r := _read_raw(kind, slot)
	if not r.ok: return {"ok": false, "error": r.error}
	var data: Dictionary = r.raw.duplicate()
	data.name = name.strip_edges()
	return _publish(kind, slot, data)

## OK, or why the slot's file is still there. Recovery files go with it.
static func delete(kind: String, slot: int) -> Error:
	if _slot_error(kind, slot) != "": return ERR_INVALID_PARAMETER
	var path := path_of(kind, slot)
	var err := OK
	for p in [path, path + ".bak"]:
		if FileAccess.file_exists(p):
			var e := DirAccess.remove_absolute(p)
			if e != OK: err = e
	return err

static func _publish(kind: String, slot: int, data: Dictionary) -> Dictionary:
	# A file the reader would refuse must not replace the slot it would have overwritten.
	var bytes := JSON.stringify(data, "\t", true, true).to_utf8_buffer().size()
	if bytes > max_bytes:
		return {"ok": false, "error": "The save is %s MB, over the %s MB a slot holds." % [U.fixed(bytes / 1048576.0, 1), U.fixed(max_bytes / 1048576.0, 1)]}
	var folder := path_of(kind, slot).get_base_dir()
	var err := DirAccess.make_dir_recursive_absolute(folder)
	if err != OK: return {"ok": false, "error": "Cannot create %s: %s." % [folder, error_string(err)]}
	# reset: a stale recovery file must not lock a slot the player chose to write.
	var r := JsonFile.write_dict(path_of(kind, slot), data, false, Callable(), true, Callable(), true)
	return {"ok": r.error == OK, "error": str(r.message) if r.error != OK else ""}

# {ok, error, raw, state}: the parsed file, its envelope checked and its state decoded.
static func _read_raw(kind: String, slot: int) -> Dictionary:
	var out := {"ok": false, "error": "", "raw": {}, "state": {}}
	var why := _slot_error(kind, slot)
	if why != "":
		out.error = why
		return out
	var path := path_of(kind, slot)
	var limit := "larger than %s MB" % U.fixed(max_bytes / 1048576.0, 1)
	if _too_big(path):
		out.error = "The file is %s." % limit
		return out
	var r: Dictionary
	if _too_big(path + ".bak"):
		# JsonFile falls back to the recovery file, and may rename it into place, only when the
		# slot's own file does not read; so that is the only case where its size refuses the slot.
		r = JsonFile._read_one(path)
		if r.error != OK:
			out.error = "The file does not read, and its recovery file is %s." % limit
			return out
	else:
		r = JsonFile.read_dict(path)
	if r.error != OK:
		var reason := str(r.message).replace(path, path.get_file()) if str(r.message) != "" else error_string(r.error)
		out.error = "The file does not read: %s" % reason
		return out
	var d: Dictionary = r.data
	out.raw = d
	out.error = envelope_error(d, kind)
	if out.error != "": return out
	var dec := SaveCodec.decode(d.state)
	if dec.error != "":
		out.error = "The saved state is damaged: %s." % dec.error
		return out
	out.state = dec.value
	var invalid := SaveGame.validate(kind, out.state)
	if invalid != "":
		out.error = "The saved state does not fit: %s" % invalid
		return out
	out.ok = true
	return out

static func _too_big(p: String) -> bool:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null: return false
	var n := f.get_length()
	f.close()
	return n > max_bytes

## "" or what is wrong with a parsed save file's envelope.
static func envelope_error(d: Dictionary, kind: String) -> String:
	for k in d:
		if k not in TOP_KEYS: return "Unknown field \"%s\"." % str(k)
	for k in TOP_KEYS:
		if not d.has(k): return "The file has no \"%s\"." % k
	if not (d.format is float) or not is_finite(float(d.format)) or float(d.format) != floorf(float(d.format)):
		return "The format is not a number."
	if int(d.format) > FORMAT: return "Saved by a newer version of Astrarium (format %d)." % int(d.format)
	if int(d.format) != FORMAT: return "Unsupported save format %d." % int(d.format)
	if d.kind != kind:
		return "This is a %s save, not a %s one." % [KINDS.get(str(d.kind), str(d.kind)), KINDS.get(kind, kind)]
	if not d.name is String: return "The name is not text."
	var n := name_error(str(d.name))
	if n != "": return n
	if not (d.saved is float) or not is_finite(float(d.saved)) or float(d.saved) < 0.0: return "The save date is not valid."
	if not d.summary is String: return "The description is not text."
	if not d.state is Dictionary: return "The saved state is missing."
	return ""
