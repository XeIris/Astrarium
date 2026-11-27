class_name SaveCodec
extends RefCounted

# Plain values to JSON and back, keeping what JSON loses: an int stays an int
# (`{"@i": "42"}`, since Godot reads every JSON number as a float and a world's climate
# draw is keyed on its seed's text), a non-finite float survives (`{"@f": "inf"}`), and a
# double Godot's JSON would not read back bit for bit is kept as its IEEE-754 bytes
# (`{"@d": "<16 hex>"}`); its decimal parser is not correctly rounded. Anything that is
# not null, a bool, a number, a string, an array or a string-keyed dictionary cannot be
# saved. Pure.

const INT := "@i"
const FLOAT := "@f"
const DOUBLE := "@d"
const MAX_DEPTH := 48

## {value, error}: a JSON-safe copy of `v`, or an error naming the first value that is not.
static func encode(v: Variant) -> Dictionary:
	var err: Array = []
	var out: Variant = _enc(v, "save", err, 0)
	return {"value": out if err.is_empty() else null, "error": "" if err.is_empty() else str(err[0])}

## {value, error}: what encode() wrote, or an error naming the first malformed value.
static func decode(v: Variant) -> Dictionary:
	var err: Array = []
	var out: Variant = _dec(v, "save", err, 0)
	return {"value": out if err.is_empty() else null, "error": "" if err.is_empty() else str(err[0])}

static func _enc(v: Variant, at: String, err: Array, depth: int) -> Variant:
	if not err.is_empty(): return null
	if depth > MAX_DEPTH:
		err.append("%s is nested too deeply" % at)
		return null
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING: return v
		TYPE_STRING_NAME: return String(v)
		TYPE_INT: return {INT: str(v)}
		TYPE_FLOAT:
			if not is_finite(v): return {FLOAT: "nan" if is_nan(v) else ("inf" if v > 0.0 else "-inf")}
			var back = JSON.parse_string(JSON.stringify(v, "", false, true))
			if back is float and bits(back) == bits(v): return v
			return {DOUBLE: bits(v)}
		TYPE_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_INT32_ARRAY, \
				TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_BYTE_ARRAY:
			var a := []
			var i := 0
			for x in v:
				a.append(_enc(x, "%s[%d]" % [at, i], err, depth + 1))
				i += 1
			return a
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				if typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME:
					err.append("%s has a key that is not text (%s)" % [at, str(k)])
					return null
				var key := String(k)
				if key.begins_with("@"):
					err.append("%s.%s: keys starting with @ are reserved" % [at, key])
					return null
				d[key] = _enc(v[k], "%s.%s" % [at, key], err, depth + 1)
			return d
	err.append("%s cannot be saved (%s)" % [at, type_string(typeof(v))])
	return null

static func _dec(v: Variant, at: String, err: Array, depth: int) -> Variant:
	if not err.is_empty(): return null
	if depth > MAX_DEPTH:
		err.append("%s is nested too deeply" % at)
		return null
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING: return v
		TYPE_FLOAT:
			if is_finite(v): return v
			err.append("%s is not a finite number" % at)
			return null
		TYPE_INT: return float(v)
		TYPE_ARRAY:
			var a := []
			var i := 0
			for x in v:
				a.append(_dec(x, "%s[%d]" % [at, i], err, depth + 1))
				i += 1
			return a
		TYPE_DICTIONARY:
			if v.size() == 1 and v.has(INT):
				var s = v[INT]
				if not s is String or not _int64_text(s):
					err.append("%s is not a saved integer" % at)
					return null
				return (s as String).to_int()
			if v.size() == 1 and v.has(DOUBLE):
				var h = v[DOUBLE]
				# Sixteen hex digits and nothing else: hex_decode() reads a sign as no bytes at all.
				if not h is String or not _HEX16.search(h):
					err.append("%s is not a saved number" % at)
					return null
				var x := (h as String).hex_decode().decode_double(0)
				if not is_finite(x):
					err.append("%s is not a finite number" % at)
					return null
				return x
			if v.size() == 1 and v.has(FLOAT):
				match v[FLOAT]:
					"nan": return NAN
					"inf": return INF
					"-inf": return -INF
				err.append("%s is not a saved number" % at)
				return null
			var d := {}
			for k in v:
				if String(k).begins_with("@"):
					err.append("%s.%s is not a known tag" % [at, k])
					return null
				d[k] = _dec(v[k], "%s.%s" % [at, k], err, depth + 1)
			return d
	err.append("%s has a value JSON cannot hold" % at)
	return null

static var _HEX16 := RegEx.create_from_string("^[0-9a-fA-F]{16}$")
static var _INT := RegEx.create_from_string("^-?(0|[1-9][0-9]{0,18})$")

## A signed 64-bit integer as str() writes it. Checked as text: to_int() past the range
## returns INT64_MAX instead of failing.
static func _int64_text(s: String) -> bool:
	if not _INT.search(s): return false
	var digits := s.trim_prefix("-")
	if digits.length() < 19: return true
	return digits <= ("9223372036854775808" if s.begins_with("-") else "9223372036854775807")

## A double's eight bytes as hex, little-endian.
static func bits(x: float) -> String:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, x)
	return b.hex_encode()
