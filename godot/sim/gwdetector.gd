class_name GWDetector
extends RefCounted

# ============================================================================
# GRAVITATIONAL-WAVE DETECTOR — the strain, and what a detector does with it
# ----------------------------------------------------------------------------
# Two masses in orbit radiate gravitational waves, which is not a metaphor for
# anything: the orbit really does shrink, and the energy really does leave. The
# sim already integrates that — applyGWReaction() in sim/physics.js applies the
# leading-order (2.5-PN) energy loss as a drag, which is why the inspiral in
# #bhmerger accelerates instead of repeating. What this module does is read the
# SAME binary and work out what a detector on Earth would record.
#
# WHAT A DETECTOR RECORDS is not energy, or a photograph — it is a STRAIN: a
# fractional change in length, h = ΔL/L. For a circular binary seen at
# inclination ι and distance D,
#
#     h₊ = (4 G² μ M / c⁴ D r) · (1+cos²ι)/2 · cos 2Φ
#     h× = (4 G² μ M / c⁴ D r) · cos ι       · sin 2Φ
#
# with M the total mass, μ = m₁m₂/M the reduced mass, r the separation and Φ
# the orbital phase. Two things in that expression do all the teaching:
#
#   · The wave is at TWICE the orbital frequency. A binary is symmetric under a
#     half turn — swap the two stars and the mass distribution is the same — so
#     the quadrupole comes back to itself twice per orbit.
#   · h falls as 1/D, not as 1/D². Gravitational-wave astronomy measures an
#     amplitude, not a power, so doubling a detector's sensitivity doubles its
#     reach and so multiplies the volume it can see by eight.
#
# THE SCALE PROBLEM, AND HOW IT IS HANDLED HONESTLY. The scenario draws a
# 36 M☉ black hole's horizon at 0.02 AU so that you can see it; the real one is
# 106 km, twenty-eight thousand times smaller. A strain computed from the drawn
# separation would be true of nothing. So the mapping used here is the one
# invariant both versions share:
#
#     THE DRAWN BINARY AND THE REAL ONE ARE AT THE SAME FRACTION OF THEIR OWN
#     MERGER SEPARATION.
#
# The sim merges its pair when they touch; a real compact binary merges at
# about one Schwarzschild radius of the total mass. Dividing one by the other
# gives a single scale factor, applied to the separation — and then the
# frequency, the amplitude and the chirp rate are all the real ones, sweeping
# up through the detector band exactly as the picture spirals in. The detector
# clock is derived the same way: the orbital PHASE is the thing the two
# versions share, so equivalent time advances by ΔΦ/ω_real. The accelerated
# reaction in the demo is NOT a physical chirp rate; merger/ringdown and
# detector antenna response are outside this illustrative model.
# ============================================================================

const G_SI := 6.67430e-11
const C := 2.99792458e8
const M_SUN := 1.98892e30
const AU_M := 1.495978707e11
const MPC_M := 3.0857e22

# LIGO's useful band. Below 20 Hz it is buried in seismic noise (which is why a
# detector on the ground can never see the year-long early inspiral, and why
# LISA has to be in space); above a few kHz the laser's own shot noise wins.
const BAND_LO := 20.0
const BAND_HI := 2000.0

# ----------------------------------------------------------------------------
# Pick the binary: the two heaviest bodies that are close enough together to be
# a pair rather than two unrelated objects in the same scene.
# ----------------------------------------------------------------------------
static func find_binary(bodies: Array) -> Variant:
	var live: Array = []
	for b in bodies:
		if b.alive != false and (b.type == "bh" or b.type == "neutron"):
			live.append(b)
	# Array.sort is stable in JS and a merge sort; sort_custom is not stable,
	# so ties (an equal-mass pair) break on the original order explicitly.
	var ix := {}
	for i in live.size(): ix[live[i]] = i
	live.sort_custom(func(a, b): return a.mass > b.mass or (a.mass == b.mass and ix[a] < ix[b]))
	if live.size() < 2: return null
	return {"a": live[0], "b": live[1]}

# The separation at which THIS simulation will call it a merger: the sum of the
# radii the collision test actually uses.
static func _contact_au(b) -> float:
	if b.contact_au > 0.0: return b.contact_au
	if b.radius > 0.0: return b.radius
	if b.rs > 0.0: return b.rs
	return 1e-9

# ----------------------------------------------------------------------------
# One reading. `distMpc` is where the source is put — 410 Mpc is GW150914's
# measured luminosity distance, 40 Mpc is GW170817's.
# ----------------------------------------------------------------------------
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

	# The merger-referenced mapping described in the header.
	var merge_sim := _contact_au(a) + _contact_au(b)
	var merge_real := Physics.schwarzschild(Msun)            # AU
	var scale := merge_real / maxf(merge_sim, 1e-12)
	var r_au := r_sim * scale
	var r := r_au * AU_M                                     # metres

	var M := Msun * M_SUN
	var mu := (m1 * m2 / Msun) * M_SUN
	var D := dist_mpc * MPC_M

	var omega := sqrt(G_SI * M / (r * r * r))                # rad/s, orbital
	var f_gw := omega / PI                                   # twice the orbital frequency
	var h0 := 4.0 * G_SI * G_SI * mu * M / (C * C * C * C * D * r)

	# The chirp mass is the ONE combination of the two masses the waveform
	# actually determines, which is why every detection is quoted with one:
	# the early inspiral depends on m1 and m2 only through M_c.
	var Mc := pow(m1 * m2, 3.0 / 5.0) / pow(Msun, 1.0 / 5.0)

	return {
		"m1": m1, "m2": m2, "Msun": Msun, "Mc": Mc, "rAU": r_au, "rSchwarz": r_au / merge_real,
		"omega": omega, "fGW": f_gw, "h0": h0, "distMpc": dist_mpc,
		"hPlus": h0 * (1.0 + cos(incl) * cos(incl)) / 2.0,
		"hCross": h0 * cos(incl),
		"inBand": f_gw >= BAND_LO and f_gw <= BAND_HI,
	}

# ----------------------------------------------------------------------------
# The instrument: a strain trace on a real-seconds axis, plus the L-shaped
# interferometer whose arms it is stretching.
# opts: canvas (Control), width/height (backing size, 340 × 210), armM, distMpc.
# ----------------------------------------------------------------------------
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
	# 200 samples across the chart. A sample is one FRAME, and
	# at the pace these lessons run there are about thirty frames per orbit —
	# fifteen per wave cycle, since the wave is at twice the orbital frequency.
	# At 600 the cycles are four pixels apart and the chirp renders as a solid
	# block; at 200 you can see the individual oscillations tighten, which is
	# the entire thing the plot is for.
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
			# The detector's own clock. ΔΦ is shared between the drawn binary and
			# the real one; dividing by the REAL angular rate turns it into real
			# seconds, which is what makes the trace a waveform and not a picture.
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
		var amp := 1e-24
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
		Canvas2D.fill_text(canvas, "±%s×10⁻²¹" % U.fixed(amp * 1e21, 2), W - 6.0, 12.0, 10.0, dim, "right")
		if ts.size() > 1:
			Canvas2D.fill_text(canvas, "%s s of detector time" % U.fixed(float(ts[-1]) - float(ts[0]), 3), W - 6.0, trace_h - 6.0, 10.0, dim, "right")

		# ---- the interferometer, with its arms stretched by the current strain.
		# The schematic exaggerates the strain with bounded, adaptive gain; the
		# readout gives physical displacement per arm, h L / 2.
		var h: float = float(last.hPlus) * cos(2.0 * phase) if last != null else 0.0
		var y0 := trace_h + gap
		var cx := 54.0
		var cy := y0 + arm_h - 16.0
		var L := 46.0
		# Keep the schematic inside its box at high strain; report the actual
		# displacement numerically. A fixed 10^23 gain inverted the arms.
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

	# A JS number in a template literal: 4, not 4.0.
	static func _num(x: float) -> String:
		return str(int(x)) if x == floorf(x) and absf(x) < 1e15 else str(x)
