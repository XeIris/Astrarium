class_name U
extends RefCounted

# Helpers for idioms whose obvious GDScript translation is wrong:
#   U.nz(a, b)       null-coalesce (Dictionary.get only defaults a missing key)
#   U.fixed(x, n)    fixed decimals
#   U.expo(x, n)     exponent form, "5.0e-3"
#   U.grouped(x)     thousands separators, "1,000,000"
#   U.jround(x)      .5 rounds toward +∞ (round() goes away from zero)
#   U.log10, U.cbrt  (cbrt keeps the sign, unlike pow(x, 1/3))
#   U.lin(0xRRGGBB)  sRGB hex → linear Color; every colour reaching a uniform or
#                    light goes through this (or a `source_color` uniform)
#   U.smooth(x, lo, hi)  smoothstep with x FIRST (Godot's takes it last)

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
	# -0.00 prints as "-0.00", intentionally.
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

## A raw (unconverted) hex, for colours never colour-managed: canvas gradients,
## sprite gradient stops, CSS strings.
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
