extends SceneTree

# ============================================================================
# FLOAT-LITERAL CHECK. Godot's decimal → double conversion (the GDScript
# parser's and String.to_float's) is NOT always correctly rounded: it reads
# `1.98892e30` as 1.9889200000000002e30, one ULP above what V8 (and IEEE)
# give. A constant that is one ULP off is invisible until a quantity lands
# exactly on a threshold — 3.5 M_J = the giant degeneracy line was the case
# that found it. literalcheck.mjs extracts every float literal from the given
# .gd files; this script converts each the way the parser does and writes the
# doubles back so Node can compare them with its own, correctly rounded parse.
#   node tools/literalcheck.mjs sim/*.gd
# ============================================================================
func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var lits: Array = JSON.parse_string(FileAccess.get_file_as_string(args["in"]))
	var out := []
	for s in lits:
		# bit-exact: the double's 8 bytes, as hex
		var b := PackedByteArray(); b.resize(8); b.encode_double(0, String(s).to_float())
		out.append(b.hex_encode())
	var f := FileAccess.open(args["out"], FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	quit()
