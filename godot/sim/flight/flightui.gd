class_name FlightUI
extends RefCounted

# ============================================================================
# FLIGHT INSTRUMENTS — port of sim/flight/flightui.js.
# ----------------------------------------------------------------------------
# A navball, a telemetry block, a stage stack, two clocks and a targeting menu.
#
# THE NAVBALL is the one instrument worth building properly, because it is the
# only one that answers the question a pilot actually has — "which way am I
# pointing, relative to where I am going and to the ground below" — in a single
# glance. It is drawn as a true orthographic projection of a sphere fixed in the
# SURFACE frame, seen from the vehicle's own nose:
#
#   · a great circle (the horizon) projects to an ellipse whose semi-minor axis
#     is R·|n·z|, where n is the local up expressed in view coordinates;
#   · a small circle at latitude φ (a pitch line) projects to an ellipse of
#     semi-axes R·cos φ, offset R·sin φ along the projection of n.
#
# Both fall out of the same three lines, which is why the ladder stays correct
# at any attitude instead of being faked with a tilted straight line.
#
# THE TWO CLOCKS are the other thing this UI exists for. MET is the vehicle's
# own proper time and UT is coordinate time; the readout between them is their
# accumulated difference, which is microseconds in low orbit — where it is
# exactly the GPS correction — and years at relativistic speed. Same number.
#
# GODOT NOTES
#   · The markup is blackhole_sim.css's .fl-* rules as El style dictionaries
#     (ui/widgets/el.gd), the same way ui/hud.gd builds every other panel, so
#     the panel lays out and styles like the page. The DOM rebuilt its grid,
#     stage stack and log with innerHTML every frame; here the elements are
#     built once and only their text and state change.
#   · The navball's canvas is a 188 px El whose own background is the
#     .fl-navball disc (#05080e, border-radius 50% — which also CLIPS the
#     canvas, so it clips its children here). Its two hemispheres are a
#     canvas_item shader (shaders/flight/navball.gdshader: the even-odd fill is
#     an XOR); the ladder, meridians, horizon, markers, reticle, bezel and the
#     pitch/heading numbers are _draw() calls with the canvas's own arithmetic.
#   · planHTML / cruiseHTML return HTML in the web build. Here they return a
#     small DATA description ({kind, rows, note, bar}) that the panel turns
#     into elements — the same content, and the same split of who decides it.
#   · The <select> is an El that opens a PopupMenu.
# ============================================================================

const MARKERS := [
	{"key": "prograde",   "glyph": "⊙", "color": 0xffe27a},
	{"key": "retrograde", "glyph": "⊘", "color": 0xffe27a},
	{"key": "normal",     "glyph": "▲", "color": 0xc08cff},
	{"key": "antinormal", "glyph": "▼", "color": 0xc08cff},
	{"key": "radial",     "glyph": "◆", "color": 0x6fd3ff},
	{"key": "target",     "glyph": "⬟", "color": 0x8cffb0},
	{"key": "node",       "glyph": "✦", "color": 0x5fe0ff},
]

const MODES := [
	["prograde", "PRO"], ["retrograde", "RETRO"], ["normal", "NML"], ["antinormal", "ANML"],
	["radial", "RAD"], ["antiradial", "ARAD"], ["target", "TGT"], ["off", "OFF"],
]
const PROGRAMS := [
	["ascent", "Launch to orbit", "Vertical rise, pitch program inside an angle-of-attack limit, then a closed loop on the climb rate until apoapsis reaches its target."],
	["circularize", "Circularize", "Coast to the apsis and fly an insertion burn — steered live, because a long burn is not an impulse."],
	["transfer", "Transfer to target", "Hohmann to the selected body, with the launch window computed and waited for."],
	["deorbit", "Deorbit", "Drop periapsis into the atmosphere (or into the ground, where there is no atmosphere)."],
	["land", "Land (airless)", "Apollo's own P63 / P64 / P66 sequence, on its published gate conditions."],
	["hoverslam", "Propulsive landing", "Entry burn, then a hoverslam: ignition altitude solved from v²/2(F/m − g) every step."],
	["edl", "Entry, descent & landing", "Aeroshell, supersonic parachute, backshell separation, powered descent, sky crane."],
	["cruise", "Interstellar cruise", "Leave the system on the exact constant-proper-acceleration solution: accelerate, coast, flip and burn. Two clocks, and the sky aberrates."],
]

# ---- colours of the .fl-* rules (sRGB, as the page draws them) ---------------
static func _c(h: int, a: float = 1.0) -> Color: return HudTheme.hexc(h, a)
static func _rgba(r: int, g: int, b: int, a: float) -> Color: return HudTheme.rgba(r, g, b, a)

const K_COL := 0x6f86a0
const V_COL := 0xdbeaff

# ============================================================================
# Formatters. Distances span from metres on the pad to light years in cruise,
# so there is one function and it picks the unit rather than the caller.
# ============================================================================
static func fmt_dist(m: float) -> String:
	if not is_finite(m): return "—"
	var a := absf(m)
	if a < 1000.0: return "%s m" % U.fixed(m, 0)
	if a < 1e6: return "%s km" % U.fixed(m / 1000.0, 2)
	if a < 1.4e11: return "%s km" % U.fixed(m / 1000.0, 0)
	if a < 9.4e15: return "%s AU" % U.fixed(m / 1.495978707e11, 3)
	return "%s ly" % U.fixed(m / 9.4607304725808e15, 3)

static func fmt_speed(v: float) -> String:
	if not is_finite(v): return "—"
	return ("%s m/s" % U.fixed(v, 1)) if absf(v) < 1000.0 else ("%s km/s" % U.fixed(v / 1000.0, 3))

static func fmt_mass_t(kg: float) -> String:
	if kg > 1e6: return "%s kt" % U.fixed(kg / 1e6, 2)
	if kg > 1000.0: return "%s t" % U.fixed(kg / 1000.0, 1)
	return "%s kg" % U.fixed(kg, 0)

## The clock-difference readout. This is the whole point of carrying two
## clocks, and it has to stay readable across twelve orders of magnitude:
## nanoseconds on the pad, tens of microseconds a day in low orbit (the GPS
## number), years in interstellar cruise.
static func fmt_clock_delta(s: float) -> String:
	var a := absf(s)
	var sign := "−" if s < 0.0 else "+"
	if a < 1e-9: return "%s%s ps" % [sign, U.fixed(a * 1e12, 2)]
	if a < 1e-6: return "%s%s ns" % [sign, U.fixed(a * 1e9, 2)]
	if a < 1e-3: return "%s%s µs" % [sign, U.fixed(a * 1e6, 3)]
	if a < 1.0: return "%s%s ms" % [sign, U.fixed(a * 1e3, 3)]
	if a < 60.0: return "%s%s s" % [sign, U.fixed(a, 3)]
	if a < 86400.0: return sign + Guidance.fmt_dur(a)
	return sign + Relativity.fmt_years(a / (365.25 * 86400.0))

## A mass ratio, which for a relativistic rocket is an exponential and can run
## to any number of digits. Quoted plainly while it reads as a quantity of fuel
## and in powers of ten once it does not.
static func fmt_ratio(x: float) -> String:
	if not is_finite(x): return "∞"
	if x < 10.0: return U.fixed(x, 1)
	if x < 1e4: return U.grouped(x)
	return U.expo(x, 1).replace("e+", "×10^")

# ============================================================================
# THE PLAN BLOCKS — planHTML / cruiseHTML as data.
# ============================================================================
## The transfer-plan block, written out in full because the two Δv numbers in
## an interplanetary plan are not the same number and confusing them is the
## classic way to be 2 km/s wrong.
static func plan_block(plan, target_name) -> Dictionary:
	if plan == null:
		return {"kind": "none", "text": "No solution to %s from here." % (target_name if target_name else "target")}
	if plan.get("kind") == "hohmann":
		return {"kind": "rows", "rows": [
			["departure Δv", fmt_speed(plan.dv1)], ["arrival Δv", fmt_speed(plan.dv2)],
			["total", fmt_speed(plan.dv)], ["flight time", Guidance.fmt_dur(plan.tof)],
			["phase angle", "%s°" % U.fixed(plan.phase * 180.0 / PI, 1)],
			["window in", Guidance.fmt_dur(plan.waitS)], ["window repeats", Guidance.fmt_dur(plan.synodic)],
		]}
	return {"kind": "rows", "rows": [
		["escape burn", fmt_speed(plan.dvBurn)], ["v∞ needed", fmt_speed(plan.vInf)],
		["heliocentric Δv", fmt_speed(plan.dvHelio)], ["flight time", Guidance.fmt_dur(plan.tof)],
	], "note": "The burn is smaller than the heliocentric Δv it buys — that difference is the Oberth effect, and it is why the departure is made at periapsis."}

## The interstellar readout — a different instrument, because in cruise nothing
## on the orbital panel means anything.
static func cruise_block(r) -> Dictionary:
	if r == null: return {}
	var plan: Dictionary = r.plan
	var total := float(r.totalLy)
	var pct := (float(r.travelledLy) / maxf(total, 1e-9)) * 100.0
	var burn := float(U.nz(plan.get("burnLy"), 0.0))
	var note := ""
	if plan.mode == "flip":
		note = "Flip-and-burn: accelerating to the midpoint and decelerating after it — the fastest crossing this Δv allows."
	else:
		note = "Accelerate–coast–decelerate. The tanks hold rapidity %s of the %s a flip-and-burn needs, which is %s× more mass, so the ship burns to β = %s, coasts %s ly and turns over." % [
			U.fixed(plan.budget, 2), U.fixed(plan.flipPhi, 2), fmt_ratio(r.flipMassRatio), U.fixed(plan.betaMax, 3), U.fixed(plan.coastLy, 2)]
	return {"kind": "cruise",
		"bar": [pct, burn / total * 100.0, 100.0 - burn / total * 100.0],
		"grid": [
			["phase", str(r.leg)], ["β = v/c", U.fixed(r.beta, 6)], ["γ", U.fixed(r.gamma, 4)],
			["acceleration", "%s g" % U.fixed(r.accelG, 2)], ["travelled", "%s ly" % U.fixed(r.travelledLy, 4)],
			["remaining", "%s ly" % U.fixed(r.remainingLy, 4)], ["ship clock", Relativity.fmt_years(r.shipYears)],
			["Earth clock", Relativity.fmt_years(r.coordYears)], ["time dilation", "%s×" % U.fixed(r.dilation, 4)],
			["astrophage", "%s%%" % U.fixed(r.propFrac * 100.0, 2)],
		], "note": note}

# ============================================================================
# THE NAVBALL
# ============================================================================
class Navball extends El:
	const W := 188.0
	const H := 188.0
	var fill: ColorRect
	var over: Control
	var fill_mat: ShaderMaterial
	# the last draw() inputs
	var fwd := Vector3(0, 1, 0)
	var rgt := Vector3(1, 0, 0)
	var upv := Vector3(0, 0, -1)
	var up := Vector3(0, 1, 0)
	var north := Vector3(0, 0, 1)
	var vecs := {}
	var roll = null

	func _init() -> void:
		# .fl-navball: 188×188, border-radius 50%, background #05080e, flex none
		super({"w": W, "h": H, "rad": 94.0, "bg": HudTheme.hexc(0x05080e), "grow": 0.0, "shrink": 0.0})
		# border-radius on a <canvas> clips what it draws
		clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		fill = ColorRect.new()
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.size = Vector2(W, H)
		fill_mat = ShaderMaterial.new()
		fill_mat.shader = load("res://shaders/flight/navball.gdshader")
		fill_mat.set_shader_parameter("uSky", HudTheme.hexc(0x2a4d78))
		fill_mat.set_shader_parameter("uGround", HudTheme.hexc(0x6b5334))
		fill.material = fill_mat
		add_child(fill)
		over = Control.new()
		over.mouse_filter = Control.MOUSE_FILTER_IGNORE
		over.size = Vector2(W, H)
		over.draw.connect(_draw_over)
		add_child(over)

	## @param q      vessel attitude (body +Y is the nose), Quaternion
	## @param up_w   local up, world
	## @param north_w local north, world
	## @param v      {prograde, retrograde, ...} world directions to mark
	func draw_ball(q: Quaternion, up_w: Vector3, north_w: Vector3, v: Dictionary, extra: Dictionary = {}) -> void:
		# View basis: the camera looks along the vehicle's nose (+Y in body space).
		fwd = q * Vector3(0, 1, 0)          # into the screen
		rgt = q * Vector3(1, 0, 0)          # screen right
		upv = q * Vector3(0, 0, -1)         # screen up
		up = up_w; north = north_w; vecs = v
		roll = extra.get("roll")
		var R := minf(W, H) * 0.44
		var n := to_view(up)
		var nxy := Vector2(n.x, n.y).length()
		var ang := atan2(n.y, n.x) if nxy > 1e-6 else 0.0
		fill_mat.set_shader_parameter("uR", R)
		fill_mat.set_shader_parameter("uAng", ang)
		fill_mat.set_shader_parameter("uA", R * absf(n.z))
		fill_mat.set_shader_parameter("uLeft", 1.0 if n.x >= 0.0 else 0.0)
		over.queue_redraw()

	## world → view (x right, y up, z toward the viewer, i.e. −forward)
	func to_view(w: Vector3) -> Vector3:
		return Vector3(w.dot(rgt), w.dot(upv), -w.dot(fwd))

	## An ellipse centred at `c`, semi-axes (rx, ry), rotated by `rot` as the
	## canvas's rotate() turns it, clipped to the ball as ctx.clip() did.
	func _ellipse(c: Vector2, rx: float, ry: float, rot: float, col: Color, width: float, clip_r: float) -> void:
		var centre := Vector2(W / 2.0, H / 2.0)
		var cr := cos(rot); var sr := sin(rot)
		var seg := PackedVector2Array()
		var steps := 256
		for i in steps + 1:
			var t := float(i) / steps * TAU
			var lx := rx * cos(t); var ly := ry * sin(t)
			var p := c + Vector2(lx * cr - ly * sr, lx * sr + ly * cr)
			if p.distance_to(centre) <= clip_r:
				seg.append(p)
			else:
				if seg.size() > 1: over.draw_polyline(seg, col, width, true)
				seg = PackedVector2Array()
		if seg.size() > 1: over.draw_polyline(seg, col, width, true)

	func _draw_over() -> void:
		var R := minf(W, H) * 0.44
		var cx := W / 2.0; var cy := H / 2.0
		var n := to_view(up)
		var nxy := Vector2(n.x, n.y).length()
		var ang := atan2(n.y, n.x) if nxy > 1e-6 else 0.0
		# pitch ladder: small circles every 15°, projected the same way
		for p in range(-75, 76, 15):
			if p == 0: continue
			var s := sin(p * PI / 180.0); var c := cos(p * PI / 180.0)
			var col := HudTheme.rgba(200, 225, 255, 0.42) if p > 0 else HudTheme.rgba(255, 210, 170, 0.34)
			_ellipse(Vector2(cx + n.x * R * s, cy - n.y * R * s), R * c * absf(n.z), R * c, ang, col, 1.0, R)
		# horizon line, drawn last so it sits on top
		_ellipse(Vector2(cx, cy), R * absf(n.z), R, ang, HudTheme.rgba(255, 255, 255, 0.85), 1.6, R)
		# meridians every 45°, for heading
		var e := up.cross(north).normalized()
		for h in range(0, 360, 45):
			var a := h * PI / 180.0
			var m := north * cos(a) + e * sin(a)
			var mv := to_view(m)
			var mxy := Vector2(mv.x, mv.y).length()
			var ma := atan2(mv.y, mv.x) if mxy > 1e-6 else 0.0
			var col := HudTheme.rgba(255, 255, 255, 0.55) if h == 0 else HudTheme.rgba(255, 255, 255, 0.16)
			_ellipse(Vector2(cx, cy), R * absf(mv.z), R, ma, col, 1.4 if h == 0 else 1.0, R)
		# markers
		var sys := HudTheme.font("sys")
		var gsz := int(U.jround(R * 0.26))
		for M in MARKERS:
			var w = vecs.get(M.key)
			if w == null: continue
			var v := to_view(w)
			var x := cx + v.x * R; var y := cy - v.y * R
			var col := HudTheme.hexc(M.color, 1.0 if v.z > 0.0 else 0.30)
			var tw := sys.get_string_size(M.glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, gsz).x
			# textBaseline 'middle': the em box's middle on y
			var asc := sys.get_ascent(gsz); var desc := sys.get_descent(gsz)
			over.draw_string(sys, Vector2(x - tw * 0.5, y + (asc - desc) * 0.5), M.glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, gsz, col)
		# the fixed reticle: where the nose is pointing, always dead centre
		var ret := HudTheme.hexc(0xffcf4d)
		over.draw_line(Vector2(cx - R * 0.20, cy), Vector2(cx - R * 0.06, cy), ret, 2.0, true)
		over.draw_line(Vector2(cx + R * 0.06, cy), Vector2(cx + R * 0.20, cy), ret, 2.0, true)
		over.draw_line(Vector2(cx, cy - R * 0.14), Vector2(cx, cy - R * 0.05), ret, 2.0, true)
		over.draw_arc(Vector2(cx, cy), R * 0.045, 0.0, TAU, 24, ret, 2.0, true)
		# bezel
		over.draw_arc(Vector2(cx, cy), R + 1.0, 0.0, TAU, 128, HudTheme.rgba(120, 190, 255, 0.45), 2.0, true)
		# pitch / heading numbers
		var pitch := asin(clampf(fwd.dot(up), -1.0, 1.0)) * 180.0 / PI
		var hdg := atan2(fwd.dot(e), fwd.dot(north)) * 180.0 / PI
		if hdg < 0.0: hdg += 360.0
		var mono := HudTheme.font("mono", 600)
		var fsz := int(U.jround(R * 0.17))
		var tc := HudTheme.hexc(0xcfe6ff)
		over.draw_string(mono, Vector2(4, H - 6), "%s%s°" % ["+" if pitch >= 0.0 else "", U.fixed(pitch, 0)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, tc)
		var ht := "%s°" % U.fixed(hdg, 0)
		var hw := mono.get_string_size(ht, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz).x
		over.draw_string(mono, Vector2(W - 4 - hw, H - 6), ht, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, tc)
		if roll != null:
			var rt := "%s°r" % U.fixed(roll, 0)
			var rw := mono.get_string_size(rt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz).x
			over.draw_string(mono, Vector2(W / 2.0 - rw * 0.5, H - 6), rt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, tc)

# ============================================================================
# THE TAPES — .fl-throttle and .fl-vs: a fill, a centre line, a marker and a
# label, all absolutely positioned inside a clipped, rounded box.
# ============================================================================
class Tape extends El:
	var label := ""
	var is_vs := false
	var frac := 0.0            # throttle 0..1, or the V/S mark's bottom as a fraction

	func _init(lbl: String, vs: bool) -> void:
		label = lbl; is_vs = vs
		super({"grow": 1.0, "shrink": 1.0, "basis": 0.0, "b": [1, HudTheme.rgba(120, 190, 255, 0.20)],
			"rad": 3.0, "bg": HudTheme.rgba(8, 14, 24, 0.7), "clip": true})

	func set_frac(f: float) -> void:
		if absf(f - frac) > 1e-4:
			frac = f
			queue_redraw()

	func _draw_extra() -> void:
		# the padding box: inset by the 1 px border
		var inner := Rect2(Vector2(1, 1), size - Vector2(2, 2))
		if not is_vs:
			# linear-gradient(0deg, #2a7fd0, #7fd0ff) over the fill's own height
			var h := inner.size.y * frac
			if h > 0.0:
				var y0 := inner.end.y - h
				var c0 := HudTheme.hexc(0x2a7fd0); var c1 := HudTheme.hexc(0x7fd0ff)
				var pts := PackedVector2Array([Vector2(inner.position.x, y0), Vector2(inner.end.x, y0),
					Vector2(inner.end.x, inner.end.y), Vector2(inner.position.x, inner.end.y)])
				draw_polygon(pts, PackedColorArray([c1, c1, c0, c0]))
		else:
			# ::before — a dashed 1 px line at 50%
			var y := roundf(inner.position.y + inner.size.y * 0.5)
			var x := inner.position.x
			var dc := HudTheme.rgba(120, 190, 255, 0.35)
			while x < inner.end.x:
				draw_rect(Rect2(x, y, minf(3.0, inner.end.x - x), 1.0), dc)
				x += 6.0
			# the mark: left/right 2 px, 2 px tall, bottom at frac, with a glow
			var yb := inner.end.y - inner.size.y * frac
			var r := Rect2(inner.position.x + 2.0, yb - 2.0, inner.size.x - 4.0, 2.0)
			for i in 4:
				var g := 1.5 * (i + 1)
				draw_rect(r.grow(g), HudTheme.rgba(255, 207, 77, 0.7 * 0.12 * (1.0 - i / 4.0)))
			draw_rect(r, HudTheme.hexc(0xffcf4d))
		# the label: absolute, bottom 2 px, centred, 8.5 px, letter-spacing .08em
		var f := HudTheme.font("mono")
		var fs := 8.5
		var ls := 0.08 * fs
		var tw := HudTheme.text_w(f, label, fs, ls) - ls
		var ad := HudTheme.asc_desc(f, fs)
		var by := inner.end.y - 2.0 - ad.y
		_draw_chars(f, label, Vector2(inner.position.x + (inner.size.x - tw) * 0.5, by), fs, ls, HudTheme.hexc(0x7d93ae))

# ============================================================================
# A STAGE ROW — .fl-stage: a proportional bar behind three spans.
# ============================================================================
class StageRow extends El:
	var frac := 0.0
	var live := false
	var n: El
	var m: El
	var e: El
	var strike := false

	func _init() -> void:
		super({"display": "flex", "ai": "center", "gapc": 6.0, "fs": 10.0, "p": [3, 6], "mb": 2.0,
			"rad": 3.0, "bg": HudTheme.rgba(12, 20, 32, 0.7), "clip": true})

	func _draw_extra() -> void:
		# .fl-stage-bar i: full height, width%, over the padding box
		var w := size.x * frac
		if w > 0.0:
			draw_rect(Rect2(0, 0, w, size.y), HudTheme.rgba(60, 190, 130, 0.30) if live else HudTheme.rgba(60, 130, 200, 0.28))

## A span whose text can be struck through (text-decoration: line-through,
## which .fl-stage.gone puts on every descendant's text).
class Span extends El:
	var strike := false
	func _draw_extra() -> void:
		if not strike or _lines.is_empty(): return
		var font := HudTheme.font(g("ff"), int(g("fw")))
		var fs := gf("fs")
		var ln = _lines[0]
		var by: float = gf("bt") + gf("pt") + ln.top + ln.base
		var y := roundf(by - HudTheme.metrics(font).x * fs * 0.3)
		var w := 0.0
		for it in ln.items: w = maxf(w, it.x + it.a.w)
		draw_rect(Rect2(ln.off, y, w, 1.0), g("c"))

## .fl-target: a <select>. Chrome draws the value and a chevron.
class Select extends El:
	var popup: PopupMenu
	var options: Array = []     # [value, label]
	var value := ""
	signal changed(v: String)

	func _init() -> void:
		super({"wp": 1.0, "p": [4, 6], "fs": 10.5, "c": HudTheme.hexc(0xcfe6ff), "bg": HudTheme.rgba(12, 20, 32, 0.85),
			"b": [1, HudTheme.rgba(120, 190, 255, 0.22)], "rad": 3.0, "nw": true})
		make_clickable()
		popup = PopupMenu.new()
		add_child(popup)
		popup.id_pressed.connect(func(i: int):
			value = options[i][0]
			set_text(options[i][1])
			changed.emit(value))
		pressed.connect(func():
			popup.clear()
			for i in options.size(): popup.add_item(options[i][1], i)
			popup.position = Vector2i(get_screen_position() + Vector2(0, size.y))
			popup.popup())

	func set_options(opts: Array, current: String) -> void:
		options = opts
		value = current
		var label: String = opts[0][1] if not opts.is_empty() else ""
		for o in opts:
			if o[0] == current: label = o[1]
		set_text(label)

	func _draw_extra() -> void:
		# the chevron, 10 px from the right edge
		var c: Color = g("c")
		var x := size.x - 12.0; var y := size.y * 0.5
		draw_polyline(PackedVector2Array([Vector2(x - 3.5, y - 2.0), Vector2(x, y + 1.5), Vector2(x + 3.5, y - 2.0)]), c, 1.2, true)

# ============================================================================
# THE PANEL
# ============================================================================
var root: Control
var hooks: Dictionary
var nav: Navball
var thr: Tape
var vs: Tape
var status_el: El
var grid: El
var grid_v: Array = []          # value El per row
var grid_k: Array = []
var met_v: El
var ut_v: El
var dt_v: El
var stages_el: El
var stage_rows: Array = []
var mode_btns := {}
var prog_btns := {}
var target_sel: Select
var plan_el: El
var plan_key := ""
var log_el: El
var last_log := -1

static func _el(parent: Node, style: Dictionary, text = null, vars: Array = []) -> El:
	var e := El.new(style, vars)
	if text is String: e.runs = [{"t": text}]
	elif text is Array: e.runs = text
	parent.add_child(e)
	return e

static func _kv(parent: Node, k: String, v: String, cell: Dictionary = {}) -> Array:
	var d := _el(parent, HudCss.merge({"display": "flex", "jc": "space-between", "gapc": 6.0}, cell))
	var ke := _el(d, {"c": HudTheme.hexc(K_COL)}, k)
	var ve := _el(d, {"c": HudTheme.hexc(V_COL)}, v)
	return [ke, ve]

static func _section(parent: Node, t: String) -> El:
	# .fl-section
	return _el(parent, {"mt": 10.0, "mb": 4.0, "fs": 9.5, "ls": 0.12 * 9.5, "up": true, "c": HudTheme.hexc(K_COL),
		"bb": 1.0, "bcb": HudTheme.rgba(120, 190, 255, 0.14), "pb": 3.0}, t)

static func create_flight_hud(r: Control, h: Dictionary) -> FlightUI:
	return FlightUI.new(r, h)

func _init(r: Control, h: Dictionary) -> void:
	root = r
	hooks = h
	for c in root.get_children(): c.queue_free()
	# .fl-top
	var top := _el(root, {"display": "flex", "gapc": 8.0, "ai": "stretch", "mt": 6.0, "mb": 8.0})
	nav = Navball.new()
	top.add_child(nav)
	var tape := _el(top, {"display": "flex", "gapc": 6.0, "grow": 1.0, "shrink": 1.0})
	thr = Tape.new("THR", false); tape.add_child(thr)
	vs = Tape.new("V/S", true); tape.add_child(vs)
	# .fl-status
	status_el = _el(root, {"fs": 10.5, "c": HudTheme.hexc(0xa8c4e0), "bg": HudTheme.rgba(10, 20, 34, 0.7),
		"bl": 2.0, "bcl": HudTheme.ACCENT, "p": [4, 7], "minh": 15.0 + 8.0, "mb": 7.0},
		"", [["fail", {"bcl": HudTheme.hexc(0xff5a4a), "c": HudTheme.hexc(0xffb0a6)}],
			["good", {"bcl": HudTheme.hexc(0x57d98a), "c": HudTheme.hexc(0xb6f0cd)}]])
	# .fl-grid
	grid = _el(root, {"display": "grid", "cols": [1.0, 1.0], "gapr": 1.0, "gapc": 8.0, "fs": 10.0})
	for i in 20:
		var kv := _kv(grid, "", "")
		grid_k.append(kv[0]); grid_v.append(kv[1])
	# .fl-clocks
	var clocks := _el(root, {"m": [8, 0], "p": [6, 7], "b": [1, HudTheme.rgba(120, 190, 255, 0.18)], "rad": 4.0,
		"bg": HudTheme.rgba(8, 14, 24, 0.6)})
	met_v = _kv(clocks, "MET · ship", "—", {"fs": 10.0, "gapc": 0.0})[1]
	ut_v = _kv(clocks, "UT · coordinate", "—", {"fs": 10.0, "gapc": 0.0})[1]
	dt_v = _kv(clocks, "ship − ground", "—", {"fs": 10.0, "gapc": 0.0, "mt": 3.0, "pt": 3.0, "bt": 1.0,
		"bct": HudTheme.rgba(120, 190, 255, 0.2)})[1]
	dt_v.set_style({"c": HudTheme.hexc(0xffcf4d)})
	_section(root, "Stages")
	stages_el = _el(root, {})
	_section(root, "Autopilot")
	var modes := _el(root, {"display": "grid", "cols": [1.0, 1.0, 1.0, 1.0], "gapc": 3.0, "gapr": 3.0})
	for md in MODES:
		var b := _el(modes, HudCss.button({"p": [4, 2], "fs": 9.0, "ls": 0.04 * 9.0, "b": [1, HudTheme.rgba(120, 190, 255, 0.2)],
			"rad": 3.0, "bg": HudTheme.rgba(20, 32, 50, 0.55), "c": HudTheme.hexc(0xa8c4e0)}), md[1],
			[["hover", {"bcol": HudTheme.ACCENT}], ["on", {"bg": HudTheme.rgba(40, 90, 140, 0.85), "c": HudTheme.hexc(0xeaf4ff), "bcol": HudTheme.ACCENT}]])
		b.make_clickable()
		var key: String = md[0]
		b.pressed.connect(func(): if hooks.has("setMode"): hooks.setMode.call(key))
		mode_btns[key] = b
	var progs := _el(root, {"display": "grid", "cols": [1.0], "gapr": 3.0, "mt": 5.0})
	for pg in PROGRAMS:
		var b := _el(progs, HudCss.button({"p": [5, 8], "fs": 10.0, "ta": "left", "b": [1, HudTheme.rgba(120, 190, 255, 0.2)],
			"rad": 3.0, "bg": HudTheme.rgba(20, 32, 50, 0.55), "c": HudTheme.hexc(0xcfe6ff)}), pg[1],
			[["hover", {"bcol": HudTheme.ACCENT, "bg": HudTheme.rgba(30, 52, 80, 0.7)}], ["on", {"bg": HudTheme.rgba(40, 90, 140, 0.85), "bcol": HudTheme.ACCENT}]])
		b.make_clickable(pg[2])
		var key: String = pg[0]
		b.pressed.connect(func(): if hooks.has("runProgram"): hooks.runProgram.call(key))
		prog_btns[key] = b
	_section(root, "Target")
	target_sel = Select.new()
	root.add_child(target_sel)
	target_sel.set_options([["", "— none —"]], "")
	target_sel.changed.connect(func(v: String): if hooks.has("setTarget"): hooks.setTarget.call(v))
	plan_el = _el(root, {})
	_section(root, "Flight log")
	log_el = _el(root, {"fs": 9.5, "lh": 1.4, "maxh": 116.0, "scroll": true})
	log_el.make_hoverable()
	log_el.mouse_filter = Control.MOUSE_FILTER_STOP

func set_targets(names: Array, current) -> void:
	var opts := [["", "— none —"]]
	for n in names: opts.append([n, n])
	target_sel.set_options(opts, current if current != null else "")

## `s`: {vessel, telemetry, up: Vector3, north: Vector3, markers: {key: Vector3},
## status, mode, program, warp, parentName, plan: Dictionary (plan_block /
## cruise_block), roll}
func update(s: Dictionary) -> void:
	var t: Dictionary = s.telemetry
	var v: Vessel = s.vessel
	nav.draw_ball(v.q.to_quaternion(), s.up, s.north, s.markers, {"roll": s.get("roll")})
	status_el.set_text(str(s.status))
	status_el.set_state("fail", v.failure != null)
	status_el.set_state("good", v.failure == null and v.phase == "landed")

	thr.set_frac(float(U.jround(v.throttle * 100.0)) / 100.0)
	var vsv := clampf(float(U.nz(t.get("vertical"), 0.0)) / 400.0, -1.0, 1.0)
	vs.set_frac(float(U.fixed(50.0 + vsv * 46.0, 1)) / 100.0)

	var tf := func(k: String) -> float: return float(U.nz(t.get(k), 0.0))
	var mach: float = tf.call("mach")
	var period = t.get("period")
	var rows := [
		["altitude", fmt_dist(tf.call("alt"))],
		["speed", fmt_speed(tf.call("speed"))],
		["vertical", fmt_speed(tf.call("vertical"))],
		["apoapsis", fmt_dist(t.apo) if is_finite(float(U.nz(t.get("apo"), INF))) else "escape"],
		["periapsis", fmt_dist(float(U.nz(t.get("peri"), NAN)))],
		["period", Guidance.fmt_dur(period) if period != null and period != 0.0 and is_finite(period) else "—"],
		["eccentricity", U.fixed(tf.call("ecc"), 4)],
		["inclination", "%s°" % U.fixed(tf.call("inc"), 2)],
		["dyn. pressure", "%s kPa" % U.fixed(tf.call("q") / 1000.0, 2)],
		["mach", "—" if mach < 0.01 else U.fixed(mach, 2)],
		["g-load", "%s g" % U.fixed(tf.call("gees"), 2)],
		["heat flux", "%s W/cm²" % U.fixed(tf.call("heat") / 1e4, 1)],
		["mass", fmt_mass_t(tf.call("mass"))],
		["thrust", "%s kN" % U.fixed(tf.call("thrust") / 1e3, 0)],
		["TWR", U.fixed(tf.call("twr"), 2)],
		["Isp", "%s s" % U.fixed(tf.call("isp"), 0)],
		["Δv remaining", fmt_speed(tf.call("dv"))],
		["downrange", fmt_dist(tf.call("downrange"))],
		["warp", "%s×" % str(s.warp)],
		["body", str(s.parentName)],
	]
	for i in rows.size():
		(grid_k[i] as El).set_text(rows[i][0])
		(grid_v[i] as El).set_text(rows[i][1])

	met_v.set_text(Guidance.fmt_dur(v.met))
	ut_v.set_text(Guidance.fmt_dur(v.coord))
	dt_v.set_text(fmt_clock_delta(v.clock_delta))

	_update_stages(v)

	for k in mode_btns: (mode_btns[k] as El).set_state("on", k == s.get("mode"))
	for k in prog_btns: (prog_btns[k] as El).set_state("on", k == s.get("program"))

	_update_plan(s.get("plan", {}))

	if v.events.size() != last_log:
		last_log = v.events.size()
		for c in log_el.get_children():
			log_el.remove_child(c); c.queue_free()
		var ev: Array = v.events.slice(-9)
		ev.reverse()
		for e in ev:
			_el(log_el, {"c": HudTheme.hexc(0xa8c4e0), "p": [1, 0], "bb": 1.0, "bcb": HudTheme.rgba(120, 190, 255, 0.06)},
				[{"t": Guidance.fmt_dur(e.t), "c": HudTheme.hexc(0x5f7590), "box": {"mr": 5.0}}, {"t": " " + str(e.msg)}])

func _update_stages(v: Vessel) -> void:
	if stage_rows.size() != v.stages.size():
		for c in stages_el.get_children():
			stages_el.remove_child(c); c.queue_free()
		stage_rows.clear()
		for st in v.stages:
			var row := StageRow.new()
			stages_el.add_child(row)
			row.n = Span.new({"grow": 1.0, "shrink": 1.0, "c": HudTheme.hexc(0xcfe6ff)}, [["live", {"c": HudTheme.hexc(0x9ff0c0)}], ["pending", {"c": HudTheme.hexc(0x8fa8c4)}]])
			row.m = Span.new({"c": HudTheme.hexc(0x8fa8c4)})
			row.add_child(row.n); row.add_child(row.m)
			if st.spec.get("count", 0):
				row.e = Span.new({"c": HudTheme.hexc(0x8fa8c4), "minw": 26.0, "ta": "right"})
				row.add_child(row.e)
			stage_rows.append(row)
	for i in v.stages.size():
		var st = v.stages[i]
		var row: StageRow = stage_rows[i]
		var frac: float = st.prop / st.prop0 if st.prop0 > 0.0 else 0.0
		var cls: String = "gone" if not st.attached else (("spent" if st.spent else "live") if st.ignited else "pending")
		row.frac = float(U.fixed(frac * 100.0, 1)) / 100.0
		row.live = cls == "live"
		row.queue_redraw()
		row.set_style({"op": 0.28 if cls == "gone" else (0.55 if cls == "spent" else 1.0)})
		row.n.set_state("live", cls == "live")
		row.n.set_state("pending", cls == "pending")
		row.n.set_text(str(st.spec.name))
		row.m.set_text(fmt_mass_t(st.prop) if st.prop0 > 0.0 else fmt_mass_t(st.spec.dry))
		if row.e != null: row.e.set_text("%d/%d" % [st.live, st.spec.count])
		for sp in [row.n, row.m, row.e]:
			if sp != null and sp.strike != (cls == "gone"):
				sp.strike = cls == "gone"
				sp.queue_redraw()

func _update_plan(p: Dictionary) -> void:
	var key := JSON.stringify(p)
	if key == plan_key: return
	plan_key = key
	for c in plan_el.get_children():
		plan_el.remove_child(c); c.queue_free()
	if p.is_empty(): return
	var note_style := {"mt": 5.0, "fs": 9.5, "lh": 1.35, "c": HudTheme.hexc(0x7d93ae), "fi": true}
	match p.kind:
		"none":
			_el(plan_el, note_style, str(p.text))
		"rows":
			var body := _el(plan_el, {"display": "grid", "cols": [1.0], "gapr": 1.0, "fs": 10.0, "mt": 5.0})
			for r in p.rows: _kv(body, r[0], r[1], {"gapc": 0.0})
			if p.has("note"): _el(body, note_style, str(p.note))
		"cruise":
			var wrap := _el(plan_el, {})
			var bar := CruiseBar.new(p.bar)
			wrap.add_child(bar)
			var g := _el(wrap, {"display": "grid", "cols": [1.0, 1.0], "gapr": 1.0, "gapc": 8.0, "fs": 10.0})
			for r in p.grid: _kv(g, r[0], r[1])
			_el(wrap, note_style, str(p.note))

## .fl-cruise-bar: progress with the two burn markers.
class CruiseBar extends El:
	var vals: Array
	func _init(v: Array) -> void:
		vals = v
		super({"h": 8.0, "rad": 4.0, "bg": HudTheme.rgba(12, 20, 32, 0.9), "b": [1, HudTheme.rgba(120, 190, 255, 0.2)], "m": [6, 0, 8, 0]})
	func _draw_extra() -> void:
		var inner := Rect2(Vector2(1, 1), size - Vector2(2, 2))
		var w := inner.size.x * clampf(float(vals[0]) / 100.0, 0.0, 1.0)
		if w > 0.0:
			var c0 := HudTheme.hexc(0x2a7fd0); var c1 := HudTheme.hexc(0x7fd0ff)
			draw_polygon(PackedVector2Array([inner.position, inner.position + Vector2(w, 0), inner.position + Vector2(w, inner.size.y), inner.position + Vector2(0, inner.size.y)]),
				PackedColorArray([c0, c1, c1, c0]))
		for i in [1, 2]:
			var x := inner.position.x + inner.size.x * float(vals[i]) / 100.0
			draw_rect(Rect2(x, inner.position.y - 3.0, 1.0, 14.0), HudTheme.rgba(255, 207, 77, 0.8))
