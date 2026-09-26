class_name LightCurve
extends RefCounted

# ============================================================================
# PHOTOMETER — the light curve and the radial velocity, measured
# ----------------------------------------------------------------------------
# Almost everything known about planets around other stars was learned from two
# numbers that a telescope can actually get: how bright the star is, and how
# fast it is moving toward or away. Neither one is a picture of a planet. So
# this instrument does not draw a planet either — it points at the running
# simulation from wherever the camera is and measures those two numbers, frame
# by frame, exactly as an observatory would.
#
# WHAT IT MEASURES
#
#   FLUX. Sum the luminosity of every star, subtract whatever is blocked. A
#   body of radius r crossing a star of radius R blocks the overlap of two
#   circles in the plane of the sky — but not uniformly, because a star is
#   LIMB DARKENED: you see deeper, hotter gas at the centre of the disc and
#   shallower, cooler gas at the edge, so the middle of the disc is brighter.
#   The linear law
#
#       I(μ)/I(0) = 1 − u(1 − μ),      μ = cos(angle from disc centre)
#
#   with u ≈ 0.6 for a solar-type star in visible light, is what gives a real
#   transit its rounded bottom instead of a flat one. It is integrated here by
#   sampling the planet's disc rather than by a closed form, because the closed
#   form only exists for the linear law and the sampling is honest for any of
#   them.
#
#   RADIAL VELOCITY. The component of a star's own velocity along the line of
#   sight. A star with a planet does not sit still — both orbit their common
#   centre of mass — and that motion is a Doppler shift in every line in its
#   spectrum. The amplitude is small: 127 m/s for a hot Jupiter, 9 cm/s for an
#   Earth. This reads it straight off the integrator's velocity vector, which
#   is why it agrees with the transit: the same orbit produces both.
#
# THE OBSERVER IS THE CAMERA. Not a fixed axis — the camera. That is not a
# shortcut, it is the lesson: a transit requires the orbit to be edge-on to
# whoever is looking, and for an Earth at 1 AU round a Sun-like star the
# chance of that is R☉/a = 0.47%. Climbing out of the orbital plane and
# watching the dips disappear is the fastest way to understand why the
# thousands of planets we know about are a biased sample of the ones there are.
#
# The observer is taken to be at INFINITY — the direction to the camera is
# used, but not its distance. A real one is parsecs away, which is far enough
# that every body in the system is at the same distance to one part in 10⁵.
#
# THE PORT. Positions and velocities are the integrator's DVec3s (doubles), and
# the line of sight is a DVec3 too, so the arithmetic is the web build's to the
# last bit. The chart is a Control's _draw() at the canvas's own 340 × 210
# backing size, scaled to whatever width the card gives it — the CSS scaled the
# canvas bitmap the same way (`width: 100%; height: auto`).
# ============================================================================

const AU_PER_YR_TO_MS := 1.495978707e11 / 3.15576e7   # 4740.57 m/s

# Sample points over a unit disc, spiralled so they are equal-area rather than
# bunched at the middle. 96 of them resolve a 1% transit to better than a part
# in 10³, which is finer than the chart can draw.
static var DISC_SAMPLES: Array = _disc_samples()

static func _disc_samples() -> Array:
	var pts: Array = []
	var n := 96
	var golden := PI * (3.0 - sqrt(5.0))
	for i in n:
		var r := sqrt((i + 0.5) / n)
		var th := i * golden
		pts.append(Vector2(r * cos(th), r * sin(th)))   # Vector2 is only the pair; the maths is in doubles below
	return pts

const LIMB_U := 0.6

static func _lum(b) -> float:
	return float(b.luminosity) if b.luminosity != null else 0.0

static func _intensity(x: float, y: float, R: float) -> float:
	var q2 := (x * x + y * y) / (R * R)
	return 1.0 - LIMB_U * (1.0 - sqrt(1.0 - q2)) if q2 < 1.0 else 0.0

static func _contains(p: Dictionary, x: float, y: float) -> bool:
	return (x - p.x) * (x - p.x) + (y - p.y) * (y - p.y) <= p.r * p.r

# ----------------------------------------------------------------------------
# One measurement of the system as seen from direction `u` (a unit vector from
# the system TOWARD the observer).
#
# Returns the total flux in solar luminosities as seen from unit distance, the
# same normalised by the unobscured total, the radial velocity of the brightest
# star in m/s (positive = receding), and a list of what is currently in front
# of what.
# ----------------------------------------------------------------------------
static func measure(bodies: Array, u: DVec3) -> Dictionary:
	# A basis for the plane of the sky. Any two vectors perpendicular to u will
	# do — the measurement cannot depend on which, and does not.
	var e1 := DVec3.new(0.0, 1.0, 0.0)
	if absf(e1.dot(u)) > 0.9: e1.set_v(1.0, 0.0, 0.0)
	e1 = e1.cross(u).normalized()
	var e2 := u.cross(e1).normalized()

	var stars: Array = []
	var occulters: Array = []
	for b in bodies:
		if b.alive == false or not (b.radius > 0.0): continue
		occulters.append(b)
		if _lum(b) > 0.0: stars.append(b)

	var flux := 0.0
	var total := 0.0
	var events: Array = []
	var d := DVec3.new()
	for s in stars:
		total += _lum(s)
		var blocked := 0.0
		var R: float = s.radius
		var projected: Array = []
		for p in occulters:
			if p == s: continue
			d.sub_vectors(p.pos, s.pos)
			if d.dot(u) <= 0.0: continue
			var x := d.dot(e1)
			var y := d.dot(e2)
			var r: float = p.radius
			if sqrt(x * x + y * y) >= R + r: continue
			projected.append({"p": p, "x": x, "y": y, "r": r})
		var big := false
		for p in projected:
			if p.r >= R: big = true
		if big:
			# Sample the smaller disc. Sampling a huge occulter can miss the star
			# entirely, turning a total eclipse into no eclipse. Count the union of
			# silhouettes, including luminous companions, without double subtraction.
			var all := 0.0
			var hidden := 0.0
			for sp in DISC_SAMPLES:
				var x: float = sp.x * R
				var y: float = sp.y * R
				var I := _intensity(x, y, R)
				all += I
				for p in projected:
					if _contains(p, x, y):
						hidden += I
						break
			blocked = hidden / all
			for p in projected: events.append({"star": s, "body": p.p})
		else:
			for i in projected.size():
				var p: Dictionary = projected[i]
				var acc := 0.0
				for sp in DISC_SAMPLES:
					var x: float = p.x + sp.x * p.r
					var y: float = p.y + sp.y * p.r
					var covered := false
					for j in i:
						if _contains(projected[j], x, y):
							covered = true
							break
					if covered: continue
					acc += _intensity(x, y, R)
				var cover: float = p.r * p.r * acc / (DISC_SAMPLES.size() * R * R * (1.0 - LIMB_U / 3.0))
				blocked += cover
				if cover > 1e-7: events.append({"star": s, "body": p.p, "depth": cover})
		flux += _lum(s) * maxf(0.0, 1.0 - blocked)

	# The radial velocity of the brightest star: what a spectrograph would put a
	# number on, since it is the one whose lines dominate the spectrum.
	var bright = null
	for s in stars:
		if bright == null or _lum(s) > _lum(bright): bright = s
	var rv: float = -bright.vel.dot(u) * AU_PER_YR_TO_MS if bright != null else 0.0

	return {"flux": flux, "rel": flux / total if total > 0.0 else 1.0, "rv": rv, "events": events, "star": bright, "total": total}

# ----------------------------------------------------------------------------
# The rolling chart. Two traces share one time axis, because the whole point is
# that the dip and the wobble come from the same orbit: the transit happens at
# the moment the star's radial velocity passes through zero going the right way.
#
# opts: canvas (a Control to paint into), width/height (the backing size the
# web canvas had, 340 × 210), span.
# ----------------------------------------------------------------------------
static func create_photometer(opts: Dictionary) -> Photometer:
	return Photometer.new(opts)

class Photometer extends RefCounted:
	var canvas: Control
	var W := 340.0
	var H := 210.0
	var span := 520
	var t: Array = []
	var f: Array = []
	var v: Array = []
	var mode := "both"
	var last := {"rel": 1.0, "rv": 0.0, "events": []}

	func _init(opts: Dictionary) -> void:
		canvas = opts.get("canvas")
		W = float(opts.get("width", 340.0))
		H = float(opts.get("height", 210.0))
		span = int(opts.get("span", 520))
		if canvas:
			canvas.draw.connect(_paint)

	func reset() -> void:
		t.clear(); f.clear(); v.clear()

	func sample(bodies: Array, u: DVec3, clock: float) -> Dictionary:
		var m := LightCurve.measure(bodies, u)
		last = m
		if not t.is_empty() and clock == t[-1]:
			f[-1] = m.rel; v[-1] = m.rv
			return m
		t.append(clock); f.append(m.rel); v.append(m.rv)
		if t.size() > span:
			t.pop_front(); f.pop_front(); v.pop_front()
		return m

	func set_mode(m: String) -> void:
		mode = m

	func draw() -> void:
		if canvas: canvas.queue_redraw()

	func depth_ppm() -> int:
		var lo := 1.0
		for y in f:
			if y < lo: lo = y
		return int(U.jround((1.0 - lo) * 1e6))

	func amplitude() -> float:
		var lo := INF
		var hi := -INF
		for y in v:
			if y < lo: lo = y
			if y > hi: hi = y
		return (hi - lo) / 2.0 if is_finite(lo) else 0.0

	func _trace(x0: float, y0: float, w: float, h: float, ys: Array, label: String, unit: String, color: Color, floor_: float, digits: int) -> void:
		var lo := INF
		var hi := -INF
		for y in ys:
			if y < lo: lo = y
			if y > hi: hi = y
		if not is_finite(lo):
			lo = 0.0; hi = 1.0
		# A pad of at least `floor` keeps a flat trace from being amplified into
		# noise: with no planet transiting, the flux is 1.000000 and an autoscale
		# that fits the range would draw the last bit of floating-point as a
		# mountain range. A real photometer has a noise floor for the same reason.
		var mid := (lo + hi) / 2.0
		var half_raw := maxf((hi - lo) / 2.0, floor_ / 2.0)
		var half := half_raw * 1.25
		lo = mid - half; hi = mid + half

		Canvas2D.stroke_rect(canvas, x0 + 0.5, y0 + 0.5, w - 1.0, h - 1.0, Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.16), 1.0)
		var pts := PackedVector2Array()
		var tspan := maxf(float(t[-1]) - float(t[0]), 1e-12)
		for i in ys.size():
			var px := x0 + (float(t[i]) - float(t[0])) / tspan * w
			var py := y0 + h - ((float(ys[i]) - lo) / (hi - lo)) * h
			pts.append(Vector2(px, py))
		Canvas2D.stroke_path(canvas, pts, color, 1.4)

		Canvas2D.fill_text(canvas, label, x0 + 6.0, y0 + 12.0, 10.0, Color(190 / 255.0, 205 / 255.0, 230 / 255.0, 0.85))
		var dim := Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.6)
		Canvas2D.fill_text(canvas, U.fixed(hi, digits) + unit, x0 + w - 6.0, y0 + 12.0, 10.0, dim, "right")
		Canvas2D.fill_text(canvas, U.fixed(lo, digits) + unit, x0 + w - 6.0, y0 + h - 5.0, 10.0, dim, "right")

	func _paint() -> void:
		Canvas2D.begin(canvas, W)
		if t.size() < 2:
			Canvas2D.fill_text(canvas, "collecting…", 12.0, 22.0, 11.0, Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.55))
			Canvas2D.end(canvas)
			return
		var pad := 8.0
		var two := mode == "both"
		var h := (H - pad * 3.0) / 2.0 if two else H - pad * 2.0
		if mode != "rv":
			_trace(pad, pad, W - pad * 2.0, h, f, "relative flux", "", Color.html("#ffd28a"), 4e-4, 5)
		if mode != "flux":
			_trace(pad, pad * 2.0 + h if two else pad, W - pad * 2.0, h, v, "radial velocity", " m/s", Color.html("#7fc4ff"), 2.0, 1)
		Canvas2D.end(canvas)
