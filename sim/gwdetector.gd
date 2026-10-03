class_name GWDetector
extends RefCounted

# Circular, leading-quadrupole strain estimate from live masses and AU separation.
# Ideal orientation and phase-derived time; see docs/physics/compact-dynamics.md.

const G_SI := 6.67430e-11
const C := 2.99792458e8
const M_SUN := 1.98892e30
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
		var trace_h := H - arm_h - gap
		var dim := Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.6)
		var lab := Color(190 / 255.0, 205 / 255.0, 230 / 255.0, 0.85)

		# ---- strain trace
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

		# ---- the interferometer, arms stretched with bounded adaptive gain; the readout
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

	# An integer prints without ".0".
	static func _num(x: float) -> String:
		return str(int(x)) if x == floorf(x) and absf(x) < 1e15 else str(x)
