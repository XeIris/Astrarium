extends RefCounted

# Same-directory publication is atomic on POSIX. Godot's Windows rename deletes
# existing destinations, so Windows retains a recovery backup across publication.
static func read_dict(path: String, validate: Callable = Callable()) -> Dictionary:
	var result := _read_valid(path, validate)
	var backup := path + ".bak"
	if result.error == OK or not FileAccess.file_exists(backup): return result
	var recovered := _read_valid(backup, validate)
	if recovered.error != OK: return recovered if result.error == ERR_FILE_NOT_FOUND else result
	if result.error == ERR_FILE_NOT_FOUND:
		var err := DirAccess.rename_absolute(backup, path)
		if err == OK:
			recovered.message = "Recovered interrupted save from %s." % backup
			return recovered
	recovered.pending = true
	recovered.message = "Using recovery file %s; repair %s before saving. %s" % [backup, path, result.message]
	return recovered

# Call only after the consumer validates the primary file's application schema.
static func finish_recovery(path: String) -> Error:
	return DirAccess.remove_absolute(path + ".bak") if FileAccess.file_exists(path + ".bak") else OK

# fault(operation, from, to) is an optional check-only seam for I/O failures.
static func write_dict(path: String, data: Dictionary, use_backup: bool = false, fault: Callable = Callable(), reset: bool = false, validate: Callable = Callable()) -> Dictionary:
	var backup := path + ".bak"
	if FileAccess.file_exists(backup) and not reset:
		return _result(ERR_ALREADY_EXISTS, "Recovery file %s must be resolved before saving %s." % [backup, path])
	# A valid primary is newer than a leftover recovery file. Preserve that primary
	# in the Windows backup step, including a Reset that fails during publication.
	if FileAccess.file_exists(backup) and _read_valid(path, validate).error == OK:
		var cleanup: Error = fault.call("cleanup", backup, path) if fault.is_valid() else OK
		if cleanup == OK: cleanup = DirAccess.remove_absolute(backup)
		if cleanup != OK:
			return _result(cleanup, "Cannot resolve recovery file %s: %s. Previous data was retained." % [backup, error_string(cleanup)])
	var temp := path + ".tmp." + Crypto.new().generate_random_bytes(12).hex_encode()
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null: return _failure(path, temp, FileAccess.get_open_error(), "create temporary file")
	var serialized := JSON.stringify(data, "\t")
	file.store_string(serialized)
	file.flush()
	var err := file.get_error()
	if err == OK and fault.is_valid(): err = fault.call("write", temp, path)
	file.close()
	if err != OK: return _failure(path, temp, err, "write temporary file")
	var verified := _read_one(temp)
	# JSON decodes all numbers as floats; compare in that representation.
	if verified.error != OK or verified.data != JSON.parse_string(serialized) or FileAccess.get_file_as_string(temp) != serialized:
		return _failure(path, temp, ERR_FILE_CORRUPT, "verify temporary JSON")
	var backed_up := FileAccess.file_exists(backup)
	if not backed_up and (use_backup or OS.get_name() == "Windows") and FileAccess.file_exists(path):
		err = _rename("backup", path, backup, fault)
		if err != OK: return _failure(path, temp, err, "retain previous save")
		backed_up = true
	err = _rename("replace", temp, path, fault)
	if err != OK:
		var detail := "publish new save"
		if backed_up:
			# Never overwrite a file created by another writer while ours was absent.
			var restored := ERR_ALREADY_EXISTS if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path) else _rename("restore", backup, path, fault)
			if restored != OK: detail += "; previous save remains at " + backup
		return _failure(path, temp, err, detail)
	if backed_up and DirAccess.remove_absolute(backup) != OK:
		return _result(OK, "Saved %s, but recovery backup %s could not be removed." % [path, backup])
	return _result(OK)

static func _read_valid(path: String, validate: Callable) -> Dictionary:
	var result := _read_one(path)
	if result.error == OK and validate.is_valid() and not validate.call(result.data):
		return _result(ERR_INVALID_DATA, "Invalid saved fields in %s." % path)
	return result

static func _read_one(path: String) -> Dictionary:
	if not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path): return _result(ERR_FILE_NOT_FOUND)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return _result(FileAccess.get_open_error(), "Cannot read %s: %s." % [path, error_string(FileAccess.get_open_error())])
	var text := file.get_as_text()
	var err := file.get_error()
	file.close()
	if err != OK and err != ERR_FILE_EOF: return _result(err, "Cannot read %s: %s." % [path, error_string(err)])
	var parser := JSON.new()
	err = parser.parse(text)
	if err != OK: return _result(err, "Invalid JSON in %s at line %d: %s." % [path, parser.get_error_line(), parser.get_error_message()])
	if not parser.data is Dictionary: return _result(ERR_INVALID_DATA, "Expected a JSON object in %s." % path)
	return _result(OK, "", parser.data)

static func _rename(operation: String, from: String, to: String, fault: Callable) -> Error:
	if fault.is_valid():
		var err: Error = fault.call(operation, from, to)
		if err != OK: return err
	return DirAccess.rename_absolute(from, to)

static func _failure(path: String, temp: String, err: Error, operation: String) -> Dictionary:
	var message := "Cannot save %s (%s): %s. Previous data was retained." % [path, operation, error_string(err)]
	if FileAccess.file_exists(temp) and DirAccess.remove_absolute(temp) != OK:
		message += " Remove temporary file %s when the folder is writable." % temp
	return _result(err, message)

static func _result(err: Error, message: String = "", data = null) -> Dictionary:
	return {"error": err, "message": message, "data": data, "pending": false}
