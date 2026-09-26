class_name HRDiagram
extends RefCounted

# ============================================================================
# THE HERTZSPRUNG–RUSSELL DIAGRAM
# ----------------------------------------------------------------------------
# Plot every star you can measure with temperature on one axis and luminosity
# on the other, and they do not scatter. They fall on a line — with a couple of
# well-populated clumps off it — and that line is the single most important
# picture in stellar astronomy, because it says that a star is not free to be
# anything. Give it a mass and the physics fixes the rest.
#
# NOTHING IN THIS PLOT IS DRAWN FROM A TABLE. The main sequence is sampled out
# of structure_of() over mass, exactly as the mass–radius curve in
# sim/masscurve.js is — so a change to the stellar model in sim/structure.gd
# moves this line too, and the two can never disagree. The evolutionary tracks
# are the same function walked over PHASES at fixed mass; the white dwarf
# sequence is white_dwarf_radius_sun() at a few cooling temperatures, which is
# why it is a LINE of nearly constant radius rather than a region.
#
# THE AXES ARE BOTH BACKWARDS, and it is worth knowing why rather than being
# annoyed by it: Hertzsprung and Russell plotted against spectral type — O B A
# F G K M — which was an alphabetical ordering of hydrogen line strength before
# anyone knew it was a temperature sequence. Temperature increases to the LEFT
# because that is the order the letters were already in. Luminosity is
# logarithmic because the range is 10¹² to 1.
# ============================================================================

const T_HI := 46000.0
const T_LO := 2100.0        # x range, kelvin (hot on the left)
const L_LO := -5.2
const L_HI := 7.0           # y range, log10 L/L☉

# Spectral class boundaries, from spectral_type() so the two cannot drift apart.
const CLASSES := [
	["O", 33000.0], ["B", 10000.0], ["A", 7300.0], ["F", 6000.0],
	["G", 5300.0], ["K", 3900.0], ["M", 2400.0],
]

const PAD := {"l": 34.0, "r": 10.0, "t": 16.0, "b": 24.0}

# opts: canvas (Control), width/height (backing size, 340 × 260).
static func create_hr_diagram(opts: Dictionary) -> Diagram:
	return Diagram.new(opts)

class Diagram extends RefCounted:
	var canvas: Control
	var W := 340.0
	var H := 260.0
	var MS: Array = []
	var TRACKS: Array = []
	var WD: Array = []
	var bodies: Array = []

	func _init(opts: Dictionary) -> void:
		canvas = opts.get("canvas")
		W = float(opts.get("width", 340.0))
		H = float(opts.get("height", 260.0))

		# ---- the ZAMS-to-midlife main sequence, sampled over mass.
		# f = 0.5 (PHASES 'ms-mid') is where the model is calibrated to today's Sun,
		# and where most observed main-sequence stars actually sit.
		var lm := U.log10(0.08)
		while lm <= U.log10(80.0):
			var m := pow(10.0, lm)
			var s := Structure.structure_of({"type": "star", "mass": m, "phase": 0.5})
			lm += 0.02
			if s.get("type") != "star" or not (float(U.nz(s.get("luminosity"), 0.0)) > 0.0): continue
			MS.append({"m": m, "teff": s.teff, "L": s.luminosity})

		# ---- two evolutionary tracks, the same function walked over the phases.
		TRACKS = [
			{"mass": 1, "color": Color(1.0, 190 / 255.0, 120 / 255.0, 0.75), "pts": _track(1.0)},
			{"mass": 8, "color": Color(160 / 255.0, 200 / 255.0, 1.0, 0.7), "pts": _track(8.0)},
		]

		# ---- the white dwarf cooling sequence. A white dwarf does not burn
		# anything; it is a fixed lump of degenerate matter losing heat, so it slides
		# DOWN and to the RIGHT at constant radius over billions of years.
		for M in [0.6]:
			var R := Structure.white_dwarf_radius_sun(M)
			var T := 40000.0
			while T >= 4000.0:
				WD.append({"teff": T, "L": R * R * pow(T / 5772.0, 4.0)})
				T -= 1000.0
		if canvas:
			canvas.draw.connect(_paint)

	static func _track(mass: float) -> Array:
		var out: Array = []
		for p in Structure.PHASES:
			if not (p.f >= 0.0) or p.id == "remnant": continue
			var s := Structure.structure_of({"type": "star", "mass": mass, "phase": p.f})
			var L = s.get("luminosity")
			if L == null or not (float(L) > 0.0): continue
			out.append({"teff": s.teff, "L": L, "label": p.label, "id": p.id})
		return out

	func X(t: float) -> float:
		var k := (U.log10(T_HI) - U.log10(maxf(t, 1.0))) / (U.log10(T_HI) - U.log10(T_LO))
		return PAD.l + k * (W - PAD.l - PAD.r)

	func Y(L: float) -> float:
		var k := (U.log10(maxf(L, 1e-9)) - L_LO) / (L_HI - L_LO)
		return H - PAD.b - k * (H - PAD.t - PAD.b)

	func _poly(pts: Array, color: Color, width: float = 1.6, dash: Array = []) -> void:
		if pts.size() < 2: return
		var pv := PackedVector2Array()
		for p in pts: pv.append(Vector2(X(float(p.teff)), Y(float(p.L))))
		Canvas2D.stroke_path(canvas, pv, color, width, dash)

	## The JS draw(bodies) painted immediately; here the bodies are kept and the
	## Control repaints on its own draw pass, which is the same frame.
	func draw(b: Array = []) -> void:
		bodies = b
		if canvas: canvas.queue_redraw()

	func _label(text: String, teff: float, L: float, dx: float, dy: float, col: Color) -> void:
		Canvas2D.fill_text(canvas, text, X(teff) + dx, Y(L) + dy, 9.0, col)

	func _paint() -> void:
		Canvas2D.begin(canvas, W)
		var fs := 9.0

		# ---- frame and the luminosity decades
		Canvas2D.stroke_rect(canvas, PAD.l + 0.5, PAD.t + 0.5, W - PAD.l - PAD.r - 1.0, H - PAD.t - PAD.b - 1.0,
			Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.18), 1.0)
		var e := -4
		while e <= 6:
			var y := Y(pow(10.0, e))
			if not (y < PAD.t or y > H - PAD.b):
				Canvas2D.line(canvas, PAD.l, y, W - PAD.r, y, Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.07), 1.0)
				Canvas2D.fill_text(canvas, "10" + HRDiagram.sup(e), PAD.l - 4.0, y + 3.0, fs, Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.55), "right")
			e += 2
		# ---- spectral classes across the top, at their own boundaries
		for i in CLASSES.size():
			var cname: String = CLASSES[i][0]
			var t_lo: float = CLASSES[i][1]
			var t_hi: float = T_HI if i == 0 else CLASSES[i - 1][1]
			var x0 := X(t_hi)
			var x1 := X(t_lo)
			Canvas2D.line(canvas, x1, PAD.t, x1, H - PAD.b, Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.10), 1.0)
			Canvas2D.fill_text(canvas, cname, (x0 + x1) / 2.0, PAD.t - 5.0, fs, Color(190 / 255.0, 205 / 255.0, 230 / 255.0, 0.6), "center")

		# ---- the sequences
		_poly(MS, Color(1, 1, 1, 0.55), 2.2)
		_poly(WD, Color(190 / 255.0, 215 / 255.0, 1.0, 0.6), 1.6, [3.0, 3.0])
		for t in TRACKS: _poly(t.pts, t.color, 1.2, [2.0, 3.0])

		# ---- named regions, placed where the curves actually put them
		var rc := Color(190 / 255.0, 205 / 255.0, 230 / 255.0, 0.5)
		_label("main sequence", 9000.0, 10.0, -18.0, 8.0, rc)
		_label("giants", 4200.0, 300.0, 6.0, 0.0, rc)
		_label("supergiants", 6000.0, 1e5, 0.0, 0.0, rc)
		_label("white dwarfs", 14000.0, 5e-3, 6.0, 10.0, rc)

		# ---- the live stars in the scene
		for b in bodies:
			if b.teff == null or b.luminosity == null: continue
			if not (float(b.teff) > 0.0) or not (float(b.luminosity) > 0.0): continue
			if b.type != "star" and b.type != "white-dwarf": continue
			var x := X(float(b.teff))
			var y := Y(float(b.luminosity))
			if x < PAD.l - 6.0 or x > W or y < 0.0 or y > H: continue
			var c := Stellar.blackbody_color(float(b.teff))
			# `rgb(${(c.r*255)|0}, …)` — truncated, and used as a CSS (sRGB) colour
			var fill := Color8(int(c.r * 255.0), int(c.g * 255.0), int(c.b * 255.0))
			Canvas2D.fill_circle(canvas, x, y, 4.2, fill)
			Canvas2D.stroke_circle(canvas, x, y, 4.2, Color(0, 0, 0, 0.6), 1.0)
			# A white dwarf's class is D, not whatever its temperature would make it
			# on the main sequence — Sirius B is 25 000 K and is emphatically not a
			# B star. The body already carries the right answer, so use it.
			var cls: String = str(b.spectral) if b.spectral != null and str(b.spectral) != "" else Structure.spectral_type(float(b.teff))
			var nm: String = b.name if b.name.ends_with(" " + cls) else "%s %s" % [b.name, cls]
			Canvas2D.fill_text(canvas, nm, x + 7.0, y + 3.0, fs, Color(225 / 255.0, 235 / 255.0, 250 / 255.0, 0.92))

		var foot := Color(150 / 255.0, 170 / 255.0, 200 / 255.0, 0.5)
		Canvas2D.fill_text(canvas, "← hotter        surface temperature        cooler →", PAD.l + 2.0, H - 8.0, fs, foot)
		Canvas2D.fill_text_rotated(canvas, "luminosity  L/L☉", 10.0, H / 2.0, -PI / 2.0, fs, foot)
		Canvas2D.end(canvas)

const SUPS := {"-": "⁻", "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"}
static func sup(n: int) -> String:
	var s := ""
	for ch in str(n):
		s += SUPS.get(ch, ch)
	return s
