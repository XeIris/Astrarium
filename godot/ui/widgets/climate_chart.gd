class_name ClimateChart
extends El

# ============================================================================
# drawClimateChart, ported line for line.
#
# A scrolling record of insolation and temperature. The point of the chart is
# to make the lag visible: the temperature curve is a smoothed, delayed echo of
# the flux curve, and the delay is the ocean's thermal inertia.
#
# The web canvas is a 290 × 86 bitmap shown at `width: 100%; height: 86px`
# inside a 1 px border, so it is drawn at 290 × 86 and SCALED into the
# content box — the page squeezes it horizontally by the same factor, and the
# arithmetic below is the canvas's own, in bitmap pixels.
# ============================================================================

const CW := 290.0
const CH := 86.0

var history: Array = []     # [[t, S, T], ...]

func _init(style: Dictionary = {}) -> void:
	var s := {"h": 86.0, "b": [1, HudTheme.BORDER], "bg": HudTheme.rgba(0, 0, 0, 0.35)}
	s.merge(style, true)
	super(s)

func set_history(h: Array) -> void:
	history = h
	queue_redraw()

static func fmt_years(y: float) -> String:
	if y < 1.0: return "%s d" % U.fixed(y * 365.25, 1)
	if y < 1000.0: return "%s yr" % U.fixed(y, 2)
	return "%s kyr" % U.fixed(y / 1000.0, 2)

func _draw_extra() -> void:
	var hist := history
	if hist.size() < 2:
		return
	var inner := Rect2(Vector2(gf("bl"), gf("bt")), size - Vector2(gf("bl") + gf("br"), gf("bt") + gf("bb")))
	var k := Vector2(inner.size.x / CW, inner.size.y / CH)
	draw_set_transform(inner.position, 0.0, k)
	var w := CW; var h := CH
	var t0: float = hist[0][0]; var t1: float = hist[-1][0]
	var span := maxf(t1 - t0, 1e-6)
	var s_max := 0.5; var t_min := 200.0; var t_max := 340.0
	for r in hist:
		s_max = maxf(s_max, r[1]); t_min = minf(t_min, r[2]); t_max = maxf(t_max, r[2])
	t_min -= 6.0; t_max += 6.0
	var X := func(t: float) -> float: return (t - t0) / span * w
	var Ys := func(s: float) -> float: return h - (s / (s_max * 1.1)) * h
	var Yt := func(t: float) -> float: return h - (t - t_min) / (t_max - t_min) * h

	# habitable band (liquid water at the surface)
	var y_top: float = Yt.call(305.0); var y_bot: float = Yt.call(273.0)
	draw_rect(Rect2(0, y_top, w, maxf(y_bot - y_top, 1.0)), Color(80 / 255.0, 200 / 255.0, 140 / 255.0, 0.10))
	draw_line(Vector2(0, y_bot), Vector2(w, y_bot), Color(80 / 255.0, 200 / 255.0, 140 / 255.0, 0.35), 1.0)

	# insolation (filled)
	var poly := PackedVector2Array([Vector2(X.call(hist[0][0]), h)])
	var line := PackedVector2Array()
	for r in hist:
		var p := Vector2(X.call(r[0]), Ys.call(r[1]))
		poly.append(p); line.append(p)
	poly.append(Vector2(X.call(t1), h))
	# the area under the curve, as a strip of quads (a canvas fill of one
	# polygon, without triangulating a shape that may touch itself)
	for i in range(1, poly.size() - 2):
		var a := poly[i]; var b := poly[i + 1]
		draw_colored_polygon(PackedVector2Array([a, b, Vector2(b.x, h), Vector2(a.x, h)]), Color(1.0, 190 / 255.0, 90 / 255.0, 0.16))
	draw_polyline(line, Color(1.0, 190 / 255.0, 90 / 255.0, 0.75), 1.2, true)

	# temperature
	var tl := PackedVector2Array()
	for r in hist:
		tl.append(Vector2(X.call(r[0]), Yt.call(r[2])))
	draw_polyline(tl, HudTheme.hexc(0xff6a5a), 1.6, true)

	var f := HudTheme.font("mono")
	var lc := Color(160 / 255.0, 180 / 255.0, 210 / 255.0, 0.55)
	draw_string(f, Vector2(4, 10), "%s window" % fmt_years(span), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, lc)
	draw_string(f, Vector2(4, h - 4), "peak %s S⊕" % U.fixed(s_max, 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, lc)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
