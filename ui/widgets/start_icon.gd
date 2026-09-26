class_name StartIcon
extends El

# ============================================================================
# The three start-card icons, drawn from the SVG in blackhole_sim.html. Each
# is a 64-unit viewBox shown at 46 px in `currentColor` (the accent); the
# shapes below are the SVG's own, coordinate for coordinate — ellipses and
# circles as they are, the arcs and cubic paths flattened to polylines.
# ============================================================================

var kind := "sandbox"

func _init(k: String) -> void:
	kind = k
	super({"w": 46.0, "h": 46.0, "mb": 14.0})

static func _ellipse(c: Vector2, rx: float, ry: float, n := 72) -> PackedVector2Array:
	var p := PackedVector2Array()
	for i in n + 1:
		var a := TAU * i / n
		p.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return p

static func _cubic(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, n := 16) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(1, n + 1):
		var t := float(i) / n
		var u := 1.0 - t
		out.append(u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3)
	return out

func _draw_extra() -> void:
	var col: Color = HudTheme.ACCENT
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(46.0 / 64.0, 46.0 / 64.0))
	var c := Vector2(32, 32)
	match kind:
		"sandbox":
			draw_polyline(_ellipse(c, 26, 10), col, 1.6, true)
			draw_polyline(_ellipse(c, 15, 24), Color(col, 0.55), 1.2, true)
			draw_circle(c, 6.5, col, true, -1.0, true)
			draw_circle(Vector2(58, 32), 2.6, col, true, -1.0, true)
			draw_circle(Vector2(32, 8), 2.0, Color(col, 0.7), true, -1.0, true)
		"learn":
			draw_polyline(_ellipse(c, 19, 19), col, 1.6, true)
			draw_polyline(_ellipse(c, 19, 7), Color(col, 0.75), 1.1, true)
			# M13 32 a19 19 0 0 1 38 0, rotated 60° about the centre: the upper
			# half of the r = 19 circle, tipped over
			var arc := PackedVector2Array()
			for i in 49:
				var a := PI + PI * i / 48.0
				var p := Vector2(cos(a), sin(a)) * 19.0
				arc.append(c + p.rotated(deg_to_rad(60.0)))
			draw_polyline(arc, Color(col, 0.45), 1.1, true)
			draw_circle(c, 3.4, col, true, -1.0, true)
			draw_circle(Vector2(51, 32), 2.2, Color(col, 0.8), true, -1.0, true)
		"flight":
			# M32 4 c7 8 10 18 10 28 v12 H22 V32 C22 22 25 12 32 4 z
			var body := PackedVector2Array([Vector2(32, 4)])
			body.append_array(_cubic(Vector2(32, 4), Vector2(39, 12), Vector2(42, 22), Vector2(42, 32)))
			body.append(Vector2(42, 44)); body.append(Vector2(22, 44)); body.append(Vector2(22, 32))
			body.append_array(_cubic(Vector2(22, 32), Vector2(22, 22), Vector2(25, 12), Vector2(32, 4)))
			draw_polyline(body, col, 1.6, true)
			# M22 40 l-8 10 h8 z   M42 40 l8 10 h-8 z
			draw_colored_polygon(PackedVector2Array([Vector2(22, 40), Vector2(14, 50), Vector2(22, 50)]), Color(col, 0.8))
			draw_colored_polygon(PackedVector2Array([Vector2(42, 40), Vector2(50, 50), Vector2(42, 50)]), Color(col, 0.8))
			draw_circle(Vector2(32, 24), 3.4, col, true, -1.0, true)
			# M27 50 c2 5 3 8 5 10 2-2 3-5 5-10 z
			var flame := PackedVector2Array([Vector2(27, 50)])
			flame.append_array(_cubic(Vector2(27, 50), Vector2(29, 55), Vector2(30, 58), Vector2(32, 60)))
			flame.append_array(_cubic(Vector2(32, 60), Vector2(34, 58), Vector2(35, 55), Vector2(37, 50)))
			draw_colored_polygon(flame, Color(col, 0.55))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
