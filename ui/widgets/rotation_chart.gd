class_name GalCurveChart
extends HudCanvas

# A galaxy's rotation curve as an instrument: the model's circular speed and its
# parts, the curve measured from the live tracers (GalCurve), and the one Eilers et
# al. (2019) measured from Gaia and APOGEE. Drawn on a 300 × 190 bitmap.

const CW := 300.0
const CH := 190.0
const R_MAX := 26.0
const V_MAX := 300.0
const PAD_L := 30.0
const PAD_B := 20.0
const PAD_T := 8.0
const PAD_R := 6.0

var model := PackedVector2Array()
var parts := {}             # name → PackedVector2Array
var gas := {}
var stars := {}
var jeans := PackedFloat64Array()
var show_reference := true
var show_parts := true

func _init() -> void:
	super(CH / CW, -1.0, HudTheme.rgba(0, 0, 0, 0.35), HudTheme.BORDER)

## Measure the tracers now and redraw. The model curves are drawn once per potential.
func measure(tr: GalTracers, pot: GalPotential) -> void:
	if model.is_empty():
		for i in 104:
			model.append(Vector2(0.25 * float(i + 1), GalUnits.kms(pot.vc(0.25 * float(i + 1)))))
		# Each part's curve is built whole and then stored: a packed array in a dictionary is a
		# value, so appending to it there would change a copy.
		for p in pot.parts:
			var curve := PackedVector2Array()
			for i in 104:
				var R := 0.25 * float(i + 1)
				curve.append(Vector2(R, GalUnits.kms(pot.vc_of(String(p.name), R))))
			parts[p.name] = curve
	var gi := tr.population_index("gas")
	var si := tr.population_index("thin disc")
	# Bins inside a population's guiding-centre range: nearer its edges a ring holds
	# only stars at the ends of their orbits.
	if gi >= 0:
		var gp: Dictionary = tr.populations[gi]
		gas = GalCurve.measure(tr, gi, float(gp.rmin) + 1.0, minf(float(gp.rmax), R_MAX) - 1.0)
	if si >= 0:
		var sp: Dictionary = tr.populations[si]
		stars = GalCurve.measure(tr, si, float(sp.rmin) + 2.0, float(sp.rmax) - 2.0)
		jeans = GalCurve.jeans_vc(stars)
	queue_redraw()

func _xy(R: float, v: float) -> Vector2:
	return Vector2(PAD_L + R / R_MAX * (CW - PAD_L - PAD_R), CH - PAD_B - v / V_MAX * (CH - PAD_B - PAD_T))

func _draw_content() -> void:
	var box := inner()
	draw_set_transform(box.position, 0.0, Vector2(box.size.x / CW, box.size.y / CH))
	var dim := HudTheme.rgba(150, 170, 200, 0.35)
	var label := HudTheme.rgba(190, 205, 230, 0.8)
	var f := Canvas2D.font()
	for v in [0, 100, 200, 300]:
		var a := _xy(0.0, float(v))
		draw_line(a, _xy(R_MAX, float(v)), dim if v > 0 else label, 1.0)
		draw_string(f, a + Vector2(-26.0, 3.5), str(v), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, label)
	for R in [0, 5, 10, 15, 20, 25]:
		var a := _xy(float(R), 0.0)
		draw_line(a, a + Vector2(0.0, 3.0), label, 1.0)
		draw_string(f, a + Vector2(-4.0, 13.0), str(R), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, label)
	draw_string(f, Vector2(CW - 62.0, CH - 3.0), "R (kpc)", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, label)
	draw_string(f, Vector2(PAD_L + 4.0, PAD_T + 9.0), "vc (km/s)", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, label)
	if show_parts:
		var cols := {"bulge": HudTheme.rgba(255, 190, 120, 0.55), "disc": HudTheme.rgba(140, 200, 255, 0.55), "halo": HudTheme.rgba(200, 160, 255, 0.55)}
		for k in parts:
			var pts := PackedVector2Array()
			for p in parts[k]: pts.append(_xy(p.x, p.y))
			Canvas2D.stroke_path(self, pts, cols.get(k, dim), 1.0, [3.0, 3.0])
	if show_reference:
		var grey := HudTheme.rgba(220, 220, 220, 0.75)
		for row in GalCurve.EILERS_2019:
			var p := _xy(float(row[0]), float(row[1]))
			draw_line(_xy(float(row[0]), float(row[1]) - float(row[2])), _xy(float(row[0]), float(row[1]) + float(row[3])), grey, 1.0)
			draw_rect(Rect2(p - Vector2(1.5, 1.5), Vector2(3.0, 3.0)), grey)
	var pts := PackedVector2Array()
	for p in model: pts.append(_xy(p.x, p.y))
	if pts.size() > 1: draw_polyline(pts, HudTheme.rgba(255, 255, 255, 0.9), 1.4, true)
	_points(gas, PackedFloat64Array(), GalaxyVisual.TRACER_COLORS.gas, false)
	_points(stars, PackedFloat64Array(), GalaxyVisual.TRACER_COLORS.disc, false)
	_points(stars, jeans, GalaxyVisual.TRACER_COLORS.disc, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _points(m: Dictionary, override: PackedFloat64Array, col: Color, hollow: bool) -> void:
	if m.is_empty(): return
	for i in (m.R as PackedFloat64Array).size():
		var v: float = override[i] if not override.is_empty() else m.v[i]
		var p := _xy(m.R[i], v)
		if hollow:
			draw_arc(p, 2.4, 0.0, TAU, 12, col, 1.0, true)
		else:
			var e: float = m.err[i]
			draw_line(_xy(m.R[i], v - e), _xy(m.R[i], v + e), col, 1.0)
			draw_circle(p, 1.8, col, true, -1.0, true)
