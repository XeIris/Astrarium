class_name U
extends RefCounted

# ============================================================================
# JAVASCRIPT-COMPATIBILITY HELPERS.
# ----------------------------------------------------------------------------
# The port is line-by-line, and a handful of JS idioms have no one-token
# GDScript equivalent or — worse — have one that means something different.
# Every one of these exists because the obvious translation is WRONG:
#
#   `a ?? b`            → U.nz(a, b)      (Dictionary.get only covers a MISSING
#                                          key; a key present with null is not
#                                          defaulted by it, and ?? does default it)
#   `x.toFixed(n)`      → U.fixed(x, n)
#   `x.toExponential(n)`→ U.expo(x, n)    ("5.0e-3", JS's exact spelling)
#   `x.toLocaleString()`→ U.grouped(x)    ("1,000,000")
#   `Math.round(x)`     → U.jround(x)     (JS rounds .5 toward +∞; Godot's
#                                          round() goes away from zero)
#   `Math.log10`        → U.log10
#   `Math.cbrt`         → U.cbrt          (keeps the sign, unlike pow(x, 1/3))
#   `new THREE.Color(0xRRGGBB)` → U.lin(0xRRGGBB)
#                         three r160 has ColorManagement ON: a hex colour is
#                         sRGB and is converted to LINEAR on construction. A
#                         Godot Color(hex) is not converted. Every colour that
#                         reaches a shader uniform or a light has to go through
#                         this (or use a `: source_color` uniform, which does
#                         the same conversion on the GPU side).
#   `THREE.MathUtils.smoothstep(x, lo, hi)` → U.smooth(x, lo, hi)
#                         NOTE the argument order: THREE's takes x FIRST, and
#                         Godot's smoothstep(from, to, x) takes it last.
# ============================================================================

const LN10 := 2.302585092994046

static func nz(v, d):
	return d if v == null else v

static func log10(x: float) -> float:
	return log(x) / LN10

static func cbrt(x: float) -> float:
	return pow(x, 1.0 / 3.0) if x >= 0.0 else -pow(-x, 1.0 / 3.0)

static func jround(x: float) -> float:
	return floor(x + 0.5)

static func smooth(x: float, lo: float, hi: float) -> float:
	# THREE.MathUtils.smoothstep(x, min, max)
	if x <= lo: return 0.0
	if x >= hi: return 1.0
	var t := (x - lo) / (hi - lo)
	return t * t * (3.0 - 2.0 * t)

static func fixed(x: float, n: int) -> String:
	if not is_finite(x):
		return "NaN" if is_nan(x) else ("Infinity" if x > 0 else "-Infinity")
	var s := ("%." + str(n) + "f") % x
	# JS prints -0.00 as "-0.00" too, so no special case is needed there.
	return s

## Number.prototype.toExponential(n): "5.0e-3", "1.2e+4".
static func expo(x: float, n: int) -> String:
	if x == 0.0:
		return ("%." + str(n) + "f") % 0.0 + "e+0"
	if not is_finite(x):
		return "NaN" if is_nan(x) else ("Infinity" if x > 0 else "-Infinity")
	var e := int(floor(log10(absf(x))))
	var m := x / pow(10.0, e)
	# rounding can carry the mantissa to 10.0
	var ms := ("%." + str(n) + "f") % m
	if absf(float(ms)) >= 10.0:
		e += 1
		m = x / pow(10.0, e)
		ms = ("%." + str(n) + "f") % m
	return "%se%s%d" % [ms, "+" if e >= 0 else "-", absi(e)]

## Number.prototype.toPrecision(n) — significant figures.
static func prec(x: float, n: int) -> String:
	if x == 0.0: return fixed(0.0, max(n - 1, 0))
	var e := int(floor(log10(absf(x))))
	if e < -6 or e >= n:
		return expo(x, n - 1)
	return fixed(x, max(n - 1 - e, 0))

## toLocaleString() for an integer-valued number in en-US: "1,000,000".
static func grouped(x: float) -> String:
	var neg := x < 0.0
	var s := str(int(absf(jround(x))))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if neg else "") + out

## sRGB hex → linear Color, exactly as `new THREE.Color(hex)` does it.
static func lin(hex: int) -> Color:
	return Color.hex((hex << 8) | 0xff).srgb_to_linear()

## linear Color → the sRGB hex THREE's Color.getHex() would give.
static func hex_of(c: Color) -> int:
	var s := c.linear_to_srgb()
	return (clampi(int(round(s.r * 255.0)), 0, 255) << 16) | (clampi(int(round(s.g * 255.0)), 0, 255) << 8) | clampi(int(round(s.b * 255.0)), 0, 255)

## "#rrggbb" of a linear colour, as THREE's getHexString() (sRGB).
static func css_of(c: Color) -> String:
	return "#%06x" % hex_of(c)

## A raw (unconverted) hex, for the few places the web used a hex WITHOUT going
## through THREE.Color — canvas gradients, CanvasTexture pixels, CSS strings.
static func raw(hex: int, a: float = 1.0) -> Color:
	var c := Color.hex((hex << 8) | 0xff)
	c.a = a
	return c

## Vector3().randomDirection() — uniform on the sphere.
static func random_dir() -> Vector3:
	var u := randf() * 2.0 - 1.0
	var t := randf() * TAU
	var c := sqrt(1.0 - u * u)
	return Vector3(c * cos(t), u, c * sin(t))

static func random_ddir() -> DVec3:
	var u := randf() * 2.0 - 1.0
	var t := randf() * TAU
	var c := sqrt(1.0 - u * u)
	return DVec3.new(c * cos(t), u, c * sin(t))

## Array.prototype.find for Arrays of objects: first element for which f is true.
static func find(arr: Array, f: Callable):
	for e in arr:
		if f.call(e):
			return e
	return null

## Deep-ish merge of option dictionaries: `{...a, ...b}`.
static func merged(a: Dictionary, b: Dictionary) -> Dictionary:
	var o := a.duplicate()
	for k in b:
		o[k] = b[k]
	return o
