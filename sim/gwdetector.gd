class_name GWDetector
extends RefCounted

# Circular, leading-quadrupole strain estimate from live masses and AU separation.
# Ideal orientation and phase-derived time; see docs/physics/compact-dynamics.md.

const G_SI := 6.67430e-11
const C := 2.99792458e8
const M_SUN := Structure.M_SUN
const AU_M := 1.495978707e11
const MPC_M := 3.0857e22

# LIGO's band: seismic noise below 20 Hz (hence LISA), shot noise above a few kHz.
const BAND_LO := 20.0
const BAND_HI := 2000.0

# Selects the two heaviest compact bodies; it does not establish a bound binary.
static func find_binary(bodies: Array) -> Variant:
	var live: Array = []
	for b in bodies:
		if b.alive != false and (b.type == "bh" or b.type == "neutron"):
			live.append(b)
	# sort_custom is not stable, so ties (an equal-mass pair) break on the
	# original order explicitly.
	var ix := {}
	for i in live.size(): ix[live[i]] = i
	live.sort_custom(func(a, b): return a.mass > b.mass or (a.mass == b.mass and ix[a] < ix[b]))
	if live.size() < 2: return null
	return {"a": live[0], "b": live[1]}

# One reading. `distMpc` is where the source is put — 410 Mpc is GW150914's
# measured luminosity distance, 40 Mpc is GW170817's.
static func strain_of(pair, opts: Dictionary = {}) -> Variant:
	if pair == null: return null
	var dist_mpc: float = float(opts.get("distMpc", 410.0))
	var incl: float = float(opts.get("incl", 0.0))
	var a = pair.a
	var b = pair.b
	var m1: float = a.mass
	var m2: float = b.mass
	var Msun := m1 + m2
	var r_sim: float = a.pos.distance_to(b.pos)
	if not (r_sim > 0.0): return null

	var r_au := r_sim
	var r := r_au * AU_M                                     # metres

	var M := Msun * M_SUN
	var mu := (m1 * m2 / Msun) * M_SUN
	var D := dist_mpc * MPC_M

	var omega := sqrt(G_SI * M / (r * r * r))                # rad/s, orbital
	var f_gw := omega / PI                                   # twice the orbital frequency
	var h0 := 4.0 * G_SI * G_SI * mu * M / (C * C * C * C * D * r)

	# The chirp mass: the one mass combination the early inspiral determines.
	var Mc := pow(m1 * m2, 3.0 / 5.0) / pow(Msun, 1.0 / 5.0)

	return {
		"m1": m1, "m2": m2, "Msun": Msun, "Mc": Mc, "rAU": r_au, "rSchwarz": r_au / Physics.schwarzschild(Msun),
		"omega": omega, "fGW": f_gw, "h0": h0, "distMpc": dist_mpc,
		"hPlus": h0 * (1.0 + cos(incl) * cos(incl)) / 2.0,
		"hCross": h0 * cos(incl),
		"inBand": f_gw >= BAND_LO and f_gw <= BAND_HI,
	}

# THE CHIRP IT ENDS IN, at the pair's true masses: the leading-order (quadrupole,
# Newtonian) inspiral, f(τ) = (5/τ)^⅜ (GM_c/c³)^−⅝ / 8π and h = 4(GM_c/c²)^⅚(πf/c)^⅔/D,
# from 20 Hz to the remnant-free ISCO, f = c³/(6^1.5 πGM); then the remnant's l = m = 2
# ringdown, Mω = 1.5251 − 1.1568(1 − j)^0.1292 and Q = 0.7 + 1.4187(1 − j)^−0.499
# (Berti, Cardoso & Will 2006), joined in amplitude and phase. The plunge and merger
# between them need numerical relativity and are not drawn; the peak lands too early
# and too low (68 Hz against GW150914's ~150 Hz).
const T_SUN := 4.925490947e-6       # GM☉/c³, s
const F_LOW := 20.0

## {t: PackedFloat64Array (s, 0 at the ISCO), h: PackedFloat64Array, fIsco, fQnm, tau,
## mFinal, spin, tIn} for masses m1, m2 (M☉) at dist_mpc, n samples in all.
static func chirp_template(m1: float, m2: float, dist_mpc: float, n := 600) -> Dictionary:
	var M := m1 + m2
	var eta := m1 * m2 / (M * M)
	var mc := pow(m1 * m2, 0.6) / pow(M, 0.2)
	var tc := T_SUN * mc
	var D := dist_mpc * MPC_M
	var f_isco := 1.0 / (pow(6.0, 1.5) * PI * T_SUN * M)
	var tau_of := func(f: float) -> float: return 5.0 * tc * pow(8.0 * PI * tc * f, -8.0 / 3.0)
	var t_in: float = tau_of.call(F_LOW) - tau_of.call(f_isco)
	var mf := M * (1.0 - Physics.merger_radiated_fraction(eta))
	var j := Physics.merger_spin(eta)
	var w := 1.5251 - 1.1568 * pow(1.0 - j, 0.1292)
	var Q := 0.7 + 1.4187 * pow(1.0 - j, -0.4990)
	var f_qnm := w / (TAU * T_SUN * mf)
	var tau_d := 2.0 * Q / w * T_SUN * mf
	var ts := PackedFloat64Array()
	var hs := PackedFloat64Array()
	var amp := func(f: float) -> float:
		return 4.0 * pow(G_SI * mc * M_SUN / (C * C), 5.0 / 3.0) * pow(PI * f / C, 2.0 / 3.0) / D
	var phase := func(tau: float) -> float: return -2.0 * pow(tau / (5.0 * tc), 0.625)
	var tau_end: float = tau_of.call(f_isco)
	var ph_end: float = phase.call(tau_end)
	# Inspiral sampled in log of the time left, so the last cycles get their share.
	var n_in := int(n * 0.75)
	for i in n_in:
		var tau: float = tau_end + t_in * pow(1.0 - float(i) / n_in, 3.0)
		var f := pow(5.0 * tc / tau, 0.375) / (8.0 * PI * tc)
		ts.append(tau_end - tau)
		hs.append(amp.call(f) * cos(phase.call(tau)))
	var a0: float = amp.call(f_isco)
	for i in n - n_in:
		var t := 6.0 * tau_d * float(i) / (n - n_in)
		ts.append(t)
		hs.append(a0 * exp(-t / tau_d) * cos(ph_end + TAU * f_qnm * t))
	return {"t": ts, "h": hs, "fIsco": f_isco, "fQnm": f_qnm, "tau": tau_d, "mFinal": mf, "spin": j, "tIn": t_in}

## Peters (1964): seconds to coalescence of a binary of m1, m2 (M☉), semi-major axis
## a_au and eccentricity e, (5/256)c⁵a⁴/(G³m₁m₂M)·(1 − e²)^3.5, the high-e limit's
## scaling; within ~20% of the full integral below e = 0.8.
static func peters_time(m1: float, m2: float, a_au: float, e := 0.0) -> float:
	var G3 := pow(G_SI, 3.0) * m1 * m2 * (m1 + m2) * pow(M_SUN, 3.0)
	return 5.0 / 256.0 * pow(C, 5.0) * pow(a_au * AU_M, 4.0) / G3 * pow(maxf(1.0 - e * e, 0.0), 3.5)

# The instrument: a strain trace on a real-seconds axis and the stretched L.
# opts: canvas (Control), width/height (backing, 340 × 210), armM, distMpc.
static func create_gw_detector(opts: Dictionary) -> Detector:
	return Detector.new(opts)

class Detector extends RefCounted:
	var canvas: Control
	var W := 340.0
	var H := 210.0
	var arm_m := 4000.0
	var dist_mpc := 410.0
	var hs: Array = []
	var ts: Array = []
	# 200 samples (one per frame, ~15 per wave cycle), so individual oscillations show.
	const SPAN := 200
	var phase := 0.0          # accumulated orbital phase, radians
	var last_theta = null     # last measured orbital angle, for unwrapping
	var t_real := 0.0         # detector clock, seconds
	var last = null
	var chirp = null           # chirp_template for the last pair seen
	var masses := Vector2.ZERO
	var t_merge := INF         # Peters, s, for the live orbit

	func _init(opts: Dictionary) -> void:
		canvas = opts.get("canvas")
		W = float(opts.get("width", 340.0))
		H = float(opts.get("height", 210.0))
		arm_m = float(opts.get("armM", 4000.0))
		dist_mpc = float(opts.get("distMpc", 410.0))
		if canvas:
			canvas.draw.connect(_paint)

	func reset() -> void:
		hs.clear(); ts.clear(); phase = 0.0; last_theta = null; t_real = 0.0; last = null

	func sample(bodies: Array) -> Variant:
		var pair = GWDetector.find_binary(bodies)
		var s = GWDetector.strain_of(pair, {"distMpc": dist_mpc})
		last = s
		if s == null: return null
		var mm := Vector2(pair.a.mass, pair.b.mass)
		if chirp == null or mm.distance_to(masses) > 1e-6 * mm.length():
			masses = mm
			chirp = GWDetector.chirp_template(mm.x, mm.y, dist_mpc)
		var rel: DVec3 = pair.b.pos.clone().sub_in(pair.a.pos)
		var vr: DVec3 = pair.b.vel.clone().sub_in(pair.a.vel)
		var el := Orbit.elements(rel, vr, Physics.G * (mm.x + mm.y))
		t_merge = GWDetector.peters_time(mm.x, mm.y, float(el.a), float(el.e)) if float(el.e) < 1.0 else INF

		# The orbital angle in the orbital plane. Unwrapped so the phase is
		# monotonic even though atan2 is not.
		var a = pair.a
		var b = pair.b
		var dx: float = b.pos.x - a.pos.x
		var dz: float = b.pos.z - a.pos.z
		var theta := atan2(dz, dx)
		if last_theta != null:
			var d: float = theta - float(last_theta)
			while d > PI: d -= 2.0 * PI
			while d < -PI: d += 2.0 * PI
			if absf(d) < 1e-12: return s
			phase += d
			# Circular estimate time from projected phase, not the simulation clock.
			t_real += absf(d) / float(s.omega)
		last_theta = theta

		hs.append(float(s.hPlus) * cos(2.0 * phase))
		ts.append(t_real)
		if hs.size() > SPAN:
			hs.pop_front(); ts.pop_front()
		return s

	func draw() -> void:
		if canvas: canvas.queue_redraw()

	func _paint() -> void:
		Canvas2D.begin(canvas, W)
		var arm_h := 78.0
		var gap := 10.0
		var chirp_h := 46.0 if chirp != null else 0.0
		var trace_h := H - arm_h - gap - chirp_h
		var dim := Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.6)
		var lab := Color(190 / 255.0, 205 / 255.0, 230 / 255.0, 0.85)

		# strain trace
		var amp := maxf(absf(float(last.hPlus)), 1e-300) if last != null else 1.0
		for h in hs: amp = maxf(amp, absf(h))
		Canvas2D.stroke_rect(canvas, 0.5, 0.5, W - 1.0, trace_h - 1.0, Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.16), 1.0)
		Canvas2D.line(canvas, 0.0, trace_h / 2.0, W, trace_h / 2.0, Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.12), 1.0)

		if hs.size() > 1:
			var pts := PackedVector2Array()
			var tspan := maxf(float(ts[-1]) - float(ts[0]), 1e-12)
			for i in hs.size():
				var x := (float(ts[i]) - float(ts[0])) / tspan * W
				var y := trace_h / 2.0 - (float(hs[i]) / amp) * (trace_h / 2.0 - 8.0)
				pts.append(Vector2(x, y))
			Canvas2D.stroke_path(canvas, pts, Color.html("#8fe0c0"), 1.3)
		else:
			Canvas2D.fill_text(canvas, "waiting for a binary…", 10.0, 20.0, 10.0, Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.55))

		Canvas2D.fill_text(canvas, "strain  h(t)", 6.0, 12.0, 10.0, lab)
		Canvas2D.fill_text(canvas, "±%s" % U.expo(amp, 2), W - 6.0, 12.0, 10.0, dim, "right")
		if ts.size() > 1:
			var span := float(ts[-1]) - float(ts[0])
			var span_text := U.expo(span, 2) if span >= 1e6 else U.fixed(span, 3)
			Canvas2D.fill_text(canvas, "%s s (circular estimate)" % span_text, W - 6.0, trace_h - 6.0, 10.0, dim, "right")

		if chirp != null:
			_paint_chirp(trace_h + 2.0, chirp_h - 4.0, dim, lab)
			trace_h += chirp_h

		# the interferometer, arms stretched with bounded adaptive gain; the readout
		# gives the real displacement per arm, h L / 2.
		var h: float = float(last.hPlus) * cos(2.0 * phase) if last != null else 0.0
		var y0 := trace_h + gap
		var cx := 54.0
		var cy := y0 + arm_h - 16.0
		var L := 46.0
		# Adaptive gain keeps the schematic visible and bounded; the readout is physical.
		var stretch := 0.3 * tanh(h / amp)
		var ex := 1.0 + stretch
		var ey := 1.0 - stretch
		var arm_c := Color(140 / 255.0, 200 / 255.0, 1.0, 0.85)
		Canvas2D.line(canvas, cx, cy, cx + L * ex, cy, arm_c, 2.0)
		Canvas2D.line(canvas, cx, cy, cx, cy - L * ey, arm_c, 2.0)
		Canvas2D.fill_rect(canvas, cx - 3.0, cy - 3.0, 6.0, 6.0, Color.html("#ffd28a"))
		var mir := Color(190 / 255.0, 205 / 255.0, 230 / 255.0, 0.9)
		Canvas2D.fill_rect(canvas, cx + L * ex - 2.0, cy - 5.0, 3.0, 10.0, mir)
		Canvas2D.fill_rect(canvas, cx - 5.0, cy - L * ey - 1.0, 10.0, 3.0, mir)

		var tx := cx + L + 26.0
		if last != null:
			var dL := absf(h) * arm_m / 2.0
			var fgw: float = last.fGW
			Canvas2D.fill_text(canvas, "f_GW  %s Hz" % (U.expo(fgw, 2) if fgw < 1.0 else U.fixed(fgw, 1)), tx, y0 + 14.0, 10.0, lab)
			Canvas2D.fill_text(canvas, "h     %s" % U.expo(float(last.h0), 2), tx, y0 + 28.0, 10.0, lab)
			Canvas2D.fill_text(canvas, "ΔL    %s m  (%s km arm)" % [U.expo(dL, 2), _num(arm_m / 1000.0)], tx, y0 + 42.0, 10.0, lab)
			Canvas2D.fill_text(canvas, "M_c   %s M☉ at %s Mpc" % [U.fixed(float(last.Mc), 1), _num(float(last.distMpc))], tx, y0 + 56.0, 10.0, lab)
			var band_txt: String
			if last.inBand: band_txt = "● in the LIGO band"
			elif fgw < GWDetector.BAND_LO: band_txt = "○ below %d Hz — seismic noise" % int(GWDetector.BAND_LO)
			else: band_txt = "○ above %d Hz — shot noise" % int(GWDetector.BAND_HI)
			Canvas2D.fill_text(canvas, band_txt, tx, y0 + 70.0, 10.0,
				Color.html("#8fe0c0") if last.inBand else Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.55))
		else:
			Canvas2D.fill_text(canvas, "no binary in this scenario", tx, y0 + 14.0, 10.0, lab)
		Canvas2D.end(canvas)

	## The template's last 0.25 s before the ISCO and its ringdown, under the live trace.
	func _paint_chirp(y: float, h: float, dim: Color, lab: Color) -> void:
		var c: Dictionary = chirp
		var t0 := -minf(0.25, float(c.tIn))
		var t1 := 6.0 * float(c.tau)
		var amp := 1e-300
		for v in c.h: amp = maxf(amp, absf(v))
		var pts := PackedVector2Array()
		for i in (c.t as PackedFloat64Array).size():
			var t: float = c.t[i]
			if t < t0: continue
			pts.append(Vector2(6.0 + (t - t0) / (t1 - t0) * (W - 12.0), y + h * 0.5 - float(c.h[i]) / amp * h * 0.45))
		Canvas2D.stroke_path(canvas, pts, Color.html("#ffd28a"), 1.1)
		var left := "Peters: merges in %s" % (_years(t_merge) if is_finite(t_merge) else "— (unbound)")
		Canvas2D.fill_text(canvas, left, 6.0, y + 10.0, 9.0, lab)
		Canvas2D.fill_text(canvas, "ringdown %s Hz, τ %s ms · %s M☉, a* %s" % [U.fixed(float(c.fQnm), 0), U.fixed(float(c.tau) * 1000.0, 1),
			U.fixed(float(c.mFinal), 1), U.fixed(float(c.spin), 2)], W - 6.0, y + h - 2.0, 9.0, dim, "right")

	static func _years(s: float) -> String:
		var y := s / Rocketry.YR_S
		if y < 1.0: return "%s s" % U.expo(s, 2)
		return "%s yr" % (U.expo(y, 2) if y >= 1e4 else U.fixed(y, 1))

	# An integer prints without ".0".
	static func _num(x: float) -> String:
		return str(int(x)) if x == floorf(x) and absf(x) < 1e15 else str(x)
