class_name TitleLogo
extends Control

# The ASTRARIUM wordmark: hairline geometric capitals (the A drawn as Λ), an orbit
# arc round the word with a planet on it, and a four-point star over the middle.
# Drawn as strokes so it scales without a font. Units are cap heights, y down.

const WORD := "ASTRARIUM"
## Each letter's width, cap heights.
const WIDTH := {"A": 1.0, "S": 0.62, "T": 0.84, "R": 0.66, "I": 0.0, "U": 0.78, "M": 0.98}
## Gap between letters, cap heights; the wordmark is tracked very wide.
const GAP := 1.02
## The wordmark sits this many cap heights below the top: room for the arc and star.
const TOP := 4.1
const BOTTOM := 3.0

var color := Color(1.0, 1.0, 1.0, 0.94)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

static func word_units() -> float:
	var w := 0.0
	for ch in WORD: w += WIDTH[ch]
	return w + GAP * (WORD.length() - 1)

## Height for a width, so the layout can size the control.
static func height_for(width: float) -> float:
	return width / word_units() * (TOP + 1.0 + BOTTOM)

static func _arc(c: Vector2, rx: float, ry: float, a0: float, a1: float, n := 24) -> PackedVector2Array:
	var p := PackedVector2Array()
	for i in n + 1:
		var a := lerpf(a0, a1, float(i) / n)
		p.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return p

## A letter's strokes in its own box (x 0..WIDTH, y 0 top..1 baseline).
static func strokes(ch: String) -> Array:
	match ch:
		"A": return [PackedVector2Array([Vector2(0, 1), Vector2(0.5, 0), Vector2(1, 1)])]
		"S":
			var top := _arc(Vector2(0.31, 0.25), 0.31, 0.25, deg_to_rad(-28.0), deg_to_rad(-270.0))
			var low := _arc(Vector2(0.31, 0.75), 0.31, 0.25, deg_to_rad(-90.0), deg_to_rad(152.0))
			top.append_array(low.slice(1))
			return [top]
		"T": return [PackedVector2Array([Vector2(0, 0), Vector2(0.84, 0)]), PackedVector2Array([Vector2(0.42, 0), Vector2(0.42, 1)])]
		"R":
			var bowl := PackedVector2Array([Vector2(0, 1), Vector2(0, 0), Vector2(0.4, 0)])
			bowl.append_array(_arc(Vector2(0.4, 0.26), 0.26, 0.26, deg_to_rad(-90.0), deg_to_rad(90.0), 16))
			bowl.append(Vector2(0, 0.52))
			return [bowl, PackedVector2Array([Vector2(0.3, 0.52), Vector2(0.66, 1)])]
		"I": return [PackedVector2Array([Vector2(0, 0), Vector2(0, 1)])]
		"U":
			var u := PackedVector2Array([Vector2(0, 0)])
			u.append_array(_arc(Vector2(0.39, 0.61), 0.39, 0.39, PI, 0.0, 20))
			u.append(Vector2(0.78, 0))
			return [u]
		"M": return [PackedVector2Array([Vector2(0, 1), Vector2(0, 0), Vector2(0.49, 0.78), Vector2(0.98, 0), Vector2(0.98, 1)])]
	return []

func _draw() -> void:
	var cap := size.x / word_units()
	if cap <= 0.0: return
	var line := maxf(1.1, cap * 0.05)
	var base_y := TOP * cap
	var x := 0.0
	for ch in WORD:
		for s: PackedVector2Array in strokes(ch):
			var pts := PackedVector2Array()
			for p in s: pts.append(Vector2(x, base_y) + p * cap)
			draw_polyline(pts, color, line, true)
		x += (WIDTH[ch] + GAP) * cap

	# The orbit: a circle round the middle of the word, bright over the top and
	# fading down each side, broken where it meets the planet.
	var c := Vector2(size.x * 0.5, base_y + cap * 0.5)
	var r := size.x * 0.255
	var n := 160
	var planet_a := deg_to_rad(-27.0)
	for i in n:
		var a0 := lerpf(deg_to_rad(-215.0), deg_to_rad(42.0), float(i) / n)
		var a1 := lerpf(deg_to_rad(-215.0), deg_to_rad(42.0), float(i + 1) / n)
		var am := (a0 + a1) * 0.5
		if absf(am - planet_a) < deg_to_rad(2.4): continue
		# Alpha: full over the top, falling to nothing at the ends.
		var k := clampf(1.0 - absf(am - deg_to_rad(-88.0)) / deg_to_rad(128.0), 0.0, 1.0)
		var alpha := pow(k, 1.6) * 0.85
		if alpha < 0.01: continue
		draw_line(c + Vector2(cos(a0), sin(a0)) * r, c + Vector2(cos(a1), sin(a1)) * r,
			Color(color, alpha), maxf(1.0, line * 0.7), true)
	var planet := c + Vector2(cos(planet_a), sin(planet_a)) * r
	draw_circle(planet, cap * 0.12, color, true, -1.0, true)

	# The star: four concave points, the vertical pair longer, and a faint halo.
	var sc := Vector2(c.x, base_y - cap * 1.05)
	var sy := cap * 0.62
	var sx := cap * 0.46
	draw_circle(sc, cap * 0.36, Color(color, 0.06), true, -1.0, true)
	draw_circle(sc, cap * 0.16, Color(color, 0.12), true, -1.0, true)
	var star := PackedVector2Array()
	var tips := [Vector2(0, -sy), Vector2(sx, 0), Vector2(0, sy), Vector2(-sx, 0)]
	for i in 4:
		var t0: Vector2 = tips[i]
		var t1: Vector2 = tips[(i + 1) % 4]
		# A quadratic pulled toward the centre gives the concave flank.
		for j in 8:
			var f := float(j) / 8.0
			var q := (1.0 - f) * (1.0 - f) * t0 + 2.0 * (1.0 - f) * f * Vector2.ZERO + f * f * t1
			star.append(sc + q)
	draw_colored_polygon(star, color)
