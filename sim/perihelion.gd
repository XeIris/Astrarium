class_name Perihelion
extends RefCounted

# Apsidal precession, measured: the longitude of perihelion of a body about the
# heaviest one, from the live state's Laplace–Runge–Lenz vector every frame, and its
# rate by least squares over the samples (arcsec per Julian century).

const T = preload("res://ui/theme.gd")
const ARCSEC := 180.0 / PI * 3600.0
const CENTURY := 100.0 * 365.25 / 365.2568984   # Julian century in orrery years

## The longitude of perihelion (rad) of `b` about `primary`, measured in the plane
## of `b`'s orbit from the orrery's +X axis projected into it, and the eccentricity.
static func longitude(b: Body, primary: Body) -> Array:
	var r := b.pos.clone().sub_in(primary.pos)
	var v := b.vel.clone().sub_in(primary.vel)
	var mu := Physics.G * (b.mass + primary.mass)
	var h := r.cross(v)
	var e := v.cross(h).scale_in(1.0 / mu).sub_in(r.clone().normalize_in())
	var n := h.clone().normalize_in()
	var x := DVec3.new(1.0, 0.0, 0.0)
	x.sub_in(n.scaled(x.dot(n)))
	if x.length_sq() < 1e-12: x.set_v(0.0, 0.0, 1.0)
	x.normalize_in()
	var y := n.cross(x)
	return [atan2(e.dot(y), e.dot(x)), e.length()]

static func create(opts: Dictionary) -> Meter:
	return Meter.new(opts)

class Meter extends RefCounted:
	var canvas: Control
	var W := 340.0
	var H := 210.0
	var target := "Mercury"
	var ts := PackedFloat64Array()   # orrery years
	var ws := PackedFloat64Array()   # unwrapped longitude, rad
	var _last := NAN

	func _init(opts: Dictionary) -> void:
		canvas = opts.get("canvas")
		W = float(opts.get("width", W)); H = float(opts.get("height", H))
		target = str(opts.get("target", target))

	func reset() -> void:
		ts.clear(); ws.clear(); _last = NAN

	## Take one reading at orrery time `t`.
	func sample(bodies: Array, t: float) -> void:
		var b = null
		var primary = null
		for x in bodies:
			if not x.alive: continue
			if x.name == target: b = x
			if primary == null or x.mass > primary.mass: primary = x
		if b == null or primary == null or b == primary: return
		if not ts.is_empty() and t <= ts[ts.size() - 1]:
			if t < ts[ts.size() - 1]: reset()   # time went back: a new run
			else: return
		var w: float = Perihelion.longitude(b, primary)[0]
		if not is_nan(_last): w = _last + wrapf(w - _last, -PI, PI)
		_last = w
		ts.append(t); ws.append(w)
		if ts.size() > 4000:
			# Keep every other sample: the fit's span, not its density, sets its precision.
			var t2 := PackedFloat64Array(); var w2 := PackedFloat64Array()
			for i in range(0, ts.size(), 2):
				t2.append(ts[i]); w2.append(ws[i])
			ts = t2; ws = w2

	## The least-squares rate, arcsec per Julian century, or NAN with too little span.
	func rate() -> float:
		var n := ts.size()
		if n < 8 or ts[n - 1] - ts[0] < 1.0: return NAN
		var mt := 0.0; var mw := 0.0
		for i in n: mt += ts[i]; mw += ws[i]
		mt /= n; mw /= n
		var sxy := 0.0; var sxx := 0.0
		for i in n:
			sxy += (ts[i] - mt) * (ws[i] - mw); sxx += (ts[i] - mt) * (ts[i] - mt)
		return sxy / sxx * ARCSEC * Perihelion.CENTURY

	func span_years() -> float:
		return ts[ts.size() - 1] - ts[0] if ts.size() > 1 else 0.0

	func draw() -> void:
		if canvas == null: return
		canvas.queue_redraw()
		if not canvas.draw.is_connected(_paint): canvas.draw.connect(_paint)

	func _paint() -> void:
		var ci := canvas
		Canvas2D.begin(ci, W)
		Canvas2D.fill_rect(ci, 0.0, 0.0, W, H, T.rgba(4, 6, 10, 0.55))
		var n := ts.size()
		var pad := 26.0
		if n >= 2:
			var t0 := ts[0]
			var span := maxf(ts[n - 1] - t0, 1e-6)
			var lo := INF; var hi := -INF
			for i in n:
				var a := (ws[i] - ws[0]) * ARCSEC
				lo = minf(lo, a); hi = maxf(hi, a)
			if hi - lo < 1.0: hi = lo + 1.0
			var pts := PackedVector2Array()
			for i in n:
				var a := (ws[i] - ws[0]) * ARCSEC
				pts.append(Vector2(pad + (ts[i] - t0) / span * (W - 2.0 * pad), H - pad - (a - lo) / (hi - lo) * (H - 2.0 * pad)))
			Canvas2D.stroke_path(ci, pts, T.ACCENT, 1.5)
			Canvas2D.fill_text(ci, "%+.1f″" % hi, 4.0, pad + 4.0, 9.0, T.TEXT_DIM)
			Canvas2D.fill_text(ci, "%+.1f″" % lo, 4.0, H - pad, 9.0, T.TEXT_DIM)
			Canvas2D.fill_text(ci, "%.0f yr" % span, W - pad, H - 8.0, 9.0, T.TEXT_DIM, "right")
		Canvas2D.fill_text(ci, "%s's perihelion, ″ from the first reading" % target, pad, 14.0, 9.5, T.TEXT)
		Canvas2D.end(ci)
