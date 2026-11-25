class_name Jsonc
extends RefCounted

# JSON with // and /* */ comments and trailing commas, for hand-written scenario files.
# Godot's JSON accepts neither comments nor reports duplicate keys (it keeps the last).
# Numbers decode as floats, as JSON.parse_string does.

## Returns { data, error: "" or a message, line, col, lines: {path: line} }.
## `lines` maps every value's path ("bodies[2].orbit.a") to its 1-based line.
static func parse(text: String) -> Dictionary:
	var p := _Parser.new(text)
	var data = p.value("")
	if p.err.is_empty():
		p.skip()
		if p.i < p.n: p.fail("unexpected text after the end of the document")
	return {"data": data if p.err.is_empty() else null, "error": p.err, "line": p.err_line, "col": p.err_col, "lines": p.lines}

class _Parser:
	var s: String
	var n: int
	var i := 0
	var line := 1
	var line_start := 0
	var err := ""
	var err_line := 0
	var err_col := 0
	var lines := {}

	func _init(text: String) -> void:
		s = text
		n = text.length()

	func fail(msg: String) -> void:
		if not err.is_empty(): return
		err = msg
		err_line = line
		err_col = i - line_start + 1

	func ch(k: int = 0) -> int:
		return s.unicode_at(i + k) if i + k < n else 0

	func advance() -> void:
		if ch() == 10:
			line += 1
			line_start = i + 1
		i += 1

	# Whitespace and comments.
	func skip() -> void:
		while i < n:
			var c := ch()
			if c == 32 or c == 9 or c == 10 or c == 13 or c == 0xFEFF:
				advance()
			elif c == 47 and ch(1) == 47:
				while i < n and ch() != 10: advance()
			elif c == 47 and ch(1) == 42:
				advance(); advance()
				while i < n and not (ch() == 42 and ch(1) == 47): advance()
				if i >= n:
					fail("unterminated /* comment")
					return
				advance(); advance()
			else:
				return

	func value(path: String) -> Variant:
		skip()
		if not err.is_empty(): return null
		lines[path] = line
		var c := ch()
		if c == 123: return object(path)
		if c == 91: return array(path)
		if c == 34: return string()
		if c == 45 or (c >= 48 and c <= 57): return number()
		for word in ["true", "false", "null"]:
			if s.substr(i, word.length()) == word and not _ident(ch(word.length())):
				for k in word.length(): advance()
				return true if word == "true" else (false if word == "false" else null)
		var end := i
		while end < n and _ident(s.unicode_at(end)): end += 1
		fail("expected a value, got \"%s\"" % s.substr(i, maxi(1, end - i)) if i < n else "expected a value, got the end of the file")
		return null

	static func _ident(c: int) -> bool:
		return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95

	func object(path: String) -> Variant:
		var out := {}
		advance()
		while true:
			skip()
			if not err.is_empty(): return null
			if ch() == 125:
				advance()
				return out
			if ch() != 34:
				fail("expected a quoted key or }")
				return null
			var key_line := line
			var key = string()
			if not err.is_empty(): return null
			if out.has(key):
				line = key_line
				fail("duplicate key \"%s\"" % key)
				return null
			skip()
			if ch() != 58:
				fail("expected : after \"%s\"" % key)
				return null
			advance()
			var child := ("%s.%s" % [path, key]) if not path.is_empty() else String(key)
			out[key] = value(child)
			if not err.is_empty(): return null
			skip()
			if ch() == 44:
				advance()
			elif ch() != 125:
				fail("expected , or } after \"%s\"" % key)
				return null
		return out

	func array(path: String) -> Variant:
		var out := []
		advance()
		while true:
			skip()
			if not err.is_empty(): return null
			if ch() == 93:
				advance()
				return out
			out.append(value("%s[%d]" % [path, out.size()]))
			if not err.is_empty(): return null
			skip()
			if ch() == 44:
				advance()
			elif ch() != 93:
				fail("expected , or ]")
				return null
		return out

	func string() -> Variant:
		advance()
		var parts := PackedStringArray()
		var start := i
		while true:
			if i >= n:
				fail("unterminated string")
				return null
			var c := ch()
			if c == 34:
				parts.append(s.substr(start, i - start))
				advance()
				return "".join(parts)
			if c == 10:
				fail("line break inside a string")
				return null
			if c == 92:
				parts.append(s.substr(start, i - start))
				advance()
				var e := ch()
				match e:
					34: parts.append("\"")
					92: parts.append("\\")
					47: parts.append("/")
					98: parts.append("\b")
					102: parts.append("\f")
					110: parts.append("\n")
					114: parts.append("\r")
					116: parts.append("\t")
					117:
						var hex := s.substr(i + 1, 4)
						if hex.length() != 4 or not hex.is_valid_hex_number():
							fail("\\u needs four hex digits")
							return null
						parts.append(String.chr(hex.hex_to_int()))
						for k in 4: advance()
					_:
						fail("unknown escape \\%s" % String.chr(e))
						return null
				advance()
				start = i
				continue
			advance()
		return null

	func number() -> Variant:
		var start := i
		if ch() == 45: advance()
		if ch() == 48:
			advance()
		elif ch() >= 49 and ch() <= 57:
			while ch() >= 48 and ch() <= 57: advance()
		else:
			fail("a number needs digits")
			return null
		if ch() == 46:
			advance()
			if not (ch() >= 48 and ch() <= 57):
				fail("a number needs digits after the point")
				return null
			while ch() >= 48 and ch() <= 57: advance()
		if ch() == 101 or ch() == 69:
			advance()
			if ch() == 43 or ch() == 45: advance()
			if not (ch() >= 48 and ch() <= 57):
				fail("an exponent needs digits")
				return null
			while ch() >= 48 and ch() <= 57: advance()
		if _ident(ch()):
			fail("unexpected character in a number")
			return null
		return Jsonc.decimal(s.substr(start, i - start))

# The nearest double to a JSON number. String.to_float can be an ulp off, which would
# make a file's starting state differ from the build it was written from.
static var _pow10 := _make_pow10()
static func _make_pow10() -> PackedFloat64Array:
	var p := PackedFloat64Array([1.0])
	for k in 22: p.append(p[-1] * 10.0)   # exact through 1e22
	return p

static func decimal(text: String) -> float:
	var neg := text.begins_with("-")
	var t := text.substr(1) if neg else text
	var e := 0
	var epos := t.findn("e")
	if epos >= 0:
		var digits := t.substr(epos + 1)
		var eneg := digits.begins_with("-")
		digits = digits.trim_prefix("-").trim_prefix("+").lstrip("0")
		# A longer exponent is past either end of the range, and would overflow to_int.
		e = 100000 if digits.length() > 6 else digits.to_int()
		if eneg: e = -e
		t = t.substr(0, epos)
	var dot := t.find(".")
	if dot >= 0:
		e -= t.length() - dot - 1
		t = t.substr(0, dot) + t.substr(dot + 1)
	t = t.lstrip("0")
	while t.length() > 1 and t.ends_with("0"):
		t = t.substr(0, t.length() - 1)
		e += 1
	# Zero is negated at run time: GDScript pools equal constants, and a -0.0 literal
	# (== 0.0) would make every 0.0 in this function negative.
	var x := 0.0
	if t.is_empty() or t == "0": return -x if neg else x
	# Midpoints between doubles have at most 767 significant digits, so the digits past
	# MAX_DIGITS matter only as "something more": one sticky 1 keeps the rounding.
	if t.length() > MAX_DIGITS:
		var rest := t.substr(MAX_DIGITS)
		e += rest.length()
		t = t.substr(0, MAX_DIGITS)
		if not rest.lstrip("0").is_empty():
			t += "1"
			e -= 1
	var mag := t.length() + e   # 10^(mag − 1) ≤ |x| < 10^mag
	if mag > 310: x = INF
	elif mag < -323: x = 0.0   # under half the smallest subnormal
	elif t.length() <= 15 and absi(e) <= 22:
		# Clinger's fast path: both operands exact, so one rounding.
		x = float(t.to_int()) * _pow10[e] if e >= 0 else float(t.to_int()) / _pow10[-e]
	else:
		var lead := t.substr(0, 17)
		x = _nearest(_big_digits(t), e, _scaled(float(lead.to_int()), e + t.length() - lead.length()))
	return -x if neg else x

const MAX_DIGITS := 800

# v·10^k in steps, so the scale neither overflows nor underflows on the way.
static func _scaled(v: float, k: int) -> float:
	if absi(k) <= 22: return v * _pow10[k] if k >= 0 else v / _pow10[-k]
	while k != 0:
		var step := clampi(k, -150, 150)
		v *= pow(10.0, step)
		k -= step
	return v

# digits·10^e (digits a bignum) to the nearest double, starting a few ulps away.
static func _nearest(digits: Array, e: int, approx: float) -> float:
	var c := approx
	# pow() differs by platform in its last bit, so near either end the estimate can
	# overflow or underflow; start from the end it passed.
	if is_inf(c): c = _from_bits(0x7FEFFFFFFFFFFFFF)
	if c <= 0.0: c = _from_bits(1)
	for _guard in 64:
		var up := _next(c, 1)
		var cmp_up := _cmp_mid(digits, e, c)
		if cmp_up > 0 or (cmp_up == 0 and _odd(c)):
			c = up
			if is_inf(c): return c
			continue
		if c == 0.0: break
		var down := _next(c, -1)
		var cmp_down := _cmp_mid(digits, e, down)
		if cmp_down < 0 or (cmp_down == 0 and _odd(c)):
			c = down
			continue
		break
	return c

static func _bits(x: float) -> int:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, x)
	return b.decode_s64(0)

static func _from_bits(i: int) -> float:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_s64(0, i)
	return b.decode_double(0)

static func _next(x: float, dir: int) -> float:
	return _from_bits(_bits(x) + dir)

static func _odd(x: float) -> bool:
	return _bits(x) & 1 == 1

# Sign of digits·10^e − the midpoint between `lo` and the next double up, compared exactly.
static func _cmp_mid(digits: Array, e: int, lo: float) -> int:
	var bits := _bits(lo)
	var field := (bits >> 52) & 0x7FF
	var mant := bits & 0xFFFFFFFFFFFFF
	var k: int
	if field == 0: k = -1074
	else:
		mant |= 1 << 52
		k = field - 1075
	# midpoint = (2·mant + 1)·2^(k−1)
	var left := digits.duplicate()
	var right := _big(2 * mant + 1)
	var two := k - 1
	if e >= 0: _mul_pow10(left, e)
	else: _mul_pow10(right, -e)
	if two >= 0: _mul_pow2(right, two)
	else: _mul_pow2(left, -two)
	return _cmp(left, right)

const LIMB := 16777216   # 2^24

static func _big(v: int) -> Array:
	var out := []
	while v > 0:
		out.append(v % LIMB)
		v /= LIMB
	return out

static func _big_digits(t: String) -> Array:
	var out := []
	for i in range(0, t.length(), 7):
		var chunk := t.substr(i, 7)
		_mul_small(out, int(pow(10, chunk.length())))
		var carry := chunk.to_int()
		var j := 0
		while carry > 0:
			if j == out.size(): out.append(0)
			var sum: int = out[j] + carry
			out[j] = sum % LIMB
			carry = sum / LIMB
			j += 1
	return out

static func _mul_small(a: Array, k: int) -> void:
	var carry := 0
	for i in a.size():
		var t: int = a[i] * k + carry
		a[i] = t % LIMB
		carry = t / LIMB
	while carry > 0:
		a.append(carry % LIMB)
		carry /= LIMB

static func _mul_pow10(a: Array, n: int) -> void:
	while n >= 7:
		_mul_small(a, 10000000)
		n -= 7
	if n > 0: _mul_small(a, int(pow(10, n)))

static func _mul_pow2(a: Array, n: int) -> void:
	while n >= 23:
		_mul_small(a, 1 << 23)
		n -= 23
	if n > 0: _mul_small(a, 1 << n)

static func _cmp(a: Array, b: Array) -> int:
	if a.size() != b.size(): return 1 if a.size() > b.size() else -1
	for i in range(a.size() - 1, -1, -1):
		if a[i] != b[i]: return 1 if a[i] > b[i] else -1
	return 0
