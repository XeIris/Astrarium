class_name FlightUI
extends RefCounted

# Native flight instruments and controls through Hud builders/theme.
# Telemetry keeps coordinate and proper clocks separate; see sim/flight/AGENTS.md.

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
	["catch", "Booster return & tower catch", "Super Heavy from its post-boostback apogee: no entry burn, a 13-engine landing burn, the centre three to hover beside the tower, then onto the arms."],
	["edl", "Entry, descent & landing", "Aeroshell, supersonic parachute, backshell separation, powered descent, sky crane."],
	["cruise", "Interstellar cruise", "Fly to the target on the exact constant-proper-acceleration solution: accelerate, coast, flip and burn. Pick a star (★) or a planet under Target first — with none picked it flies the mission. Two clocks, and the sky aberrates."],
]

# colours (sRGB)
static func _c(h: int, a: float = 1.0) -> Color: return HudTheme.hexc(h, a)
static func _rgba(r: int, g: int, b: int, a: float) -> Color: return HudTheme.rgba(r, g, b, a)

const K_COL := 0x6f86a0
const V_COL := 0xdbeaff

# Formatters. Distances span from metres on the pad to light years in cruise,
# so there is one function and it picks the unit rather than the caller.
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

## The clock difference, readable from nanoseconds on the pad to years in cruise.
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

## A mass ratio: plain while it reads as fuel, powers of ten after.
static func fmt_ratio(x: float) -> String:
	if not is_finite(x): return "∞"
	if x < 10.0: return U.fixed(x, 1)
	if x < 1e4: return U.grouped(x)
	return U.expo(x, 1).replace("e+", "×10^")

# THE PLAN BLOCKS — planHTML / cruiseHTML as data.
## The transfer plan, showing both Δv numbers (departure burn and heliocentric),
## which differ by the Oberth saving.
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

## An interstellar destination before departure: the crossing solved from this
## ship's tanks.
static func mission_block(name: String, ly: float, plan: Dictionary) -> Dictionary:
	if not plan.get("feasible", false):
		return {"kind": "none", "text": "%s is %s ly away, and this ship cannot stop there: its tanks hold rapidity %s of the %s a crossing needs." % [
			name, U.fixed(ly, 2), U.fixed(plan.budget, 2), U.fixed(plan.get("flipPhi", 0.0), 2)]}
	return {"kind": "rows", "rows": [
		["distance", "%s ly" % U.fixed(ly, 2)],
		["profile", "flip-and-burn" if plan.mode == "flip" else "accelerate–coast–decelerate"],
		["peak β", U.fixed(plan.betaMax, 4)], ["peak γ", U.fixed(plan.gammaMax, 3)],
		["ship clock", Relativity.fmt_years(plan.tauS / Relativity.YEAR_S)],
		["Earth clock", Relativity.fmt_years(plan.coordS / Relativity.YEAR_S)],
	], "note": "Press Interstellar cruise to go. The ship waits for its orbit to carry it clear of the planet, then burns; time warp is set to fit the trip."}

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

# THE NAVBALL
class Navball extends Control:
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
		custom_minimum_size = Vector2(W, H)
		size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# the disc clips what is drawn in it
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

	func _draw() -> void:
		draw_circle(Vector2(W, H) * 0.5, W * 0.5, HudTheme.hexc(0x05080e), true, -1.0, true)

	##   q        vessel attitude (body +Y is the nose)
	##   up_w     local up, world
	##   north_w  local north, world
	##   v        {prograde, retrograde, ...} world directions to mark
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

	## An ellipse centred at `c`, semi-axes (rx, ry), rotated by `rot`, clipped to
	## the ball.
	func _ellipse(c: Vector2, rx: float, ry: float, rot: float, col: Color, width: float, clip_r: float) -> void:
		var centre := Vector2(W / 2.0, H / 2.0)
		# A great circle seen edge-on is the rim: draw exactly its inner half.
		if c.distance_to(centre) < 0.01 and minf(rx, ry) >= clip_r * 0.999:
			over.draw_arc(centre, clip_r - width * 0.25, 0.0, TAU, 256, col, width * 0.5, true)
			return
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
			# centred on the em box's middle
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

## A rounded box drawn by hand: the tapes and the cruise bar.
static func _box(ci: CanvasItem, r: Rect2, bg: Color, border: Color, rad: int) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(rad)
	sb.anti_aliasing = true
	sb.anti_aliasing_size = 0.6
	ci.draw_style_box(sb, r)

# THE TAPES: throttle and vertical speed. A fill, a centre line, a mark and a label
# inside a clipped, rounded box.
class Tape extends Control:
	var label := ""
	var is_vs := false
	var frac := 0.0            # throttle 0..1, or the V/S mark's bottom as a fraction

	func _init(lbl: String, vs: bool) -> void:
		label = lbl; is_vs = vs
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func set_frac(f: float) -> void:
		if absf(f - frac) > 1e-4:
			frac = f
			queue_redraw()

	func _draw() -> void:
		FlightUI._box(self, Rect2(Vector2.ZERO, size), HudTheme.rgba(8, 14, 24, 0.7), HudTheme.rgba(120, 190, 255, 0.20), 3)
		# the padding box: inside the 1 px border
		var inner := Rect2(Vector2(1, 1), size - Vector2(2, 2))
		if not is_vs:
			# a vertical gradient, #2a7fd0 at the foot to #7fd0ff at the top of the fill
			var h := inner.size.y * frac
			if h > 0.0:
				var y0 := inner.end.y - h
				var c0 := HudTheme.hexc(0x2a7fd0); var c1 := HudTheme.hexc(0x7fd0ff)
				var pts := PackedVector2Array([Vector2(inner.position.x, y0), Vector2(inner.end.x, y0),
					Vector2(inner.end.x, inner.end.y), Vector2(inner.position.x, inner.end.y)])
				draw_polygon(pts, PackedColorArray([c1, c1, c0, c0]))
		else:
			# a dashed 1 px line at 50%
			var y := roundf(inner.position.y + inner.size.y * 0.5)
			var x := inner.position.x
			var dc := HudTheme.rgba(120, 190, 255, 0.35)
			while x < inner.end.x:
				draw_rect(Rect2(x, y, minf(3.0, inner.end.x - x), 1.0), dc)
				x += 6.0
			# the mark: 2 px tall, its foot at frac, with a glow
			var yb := inner.end.y - inner.size.y * frac
			var r := Rect2(inner.position.x + 2.0, yb - 2.0, inner.size.x - 4.0, 2.0)
			for i in 4:
				var g := 1.5 * (i + 1)
				draw_rect(r.grow(g), HudTheme.rgba(255, 207, 77, 0.7 * 0.12 * (1.0 - i / 4.0)))
			draw_rect(r, HudTheme.hexc(0xffcf4d))
		# the label: 2 px off the foot, centred, 8.5 px, letter-spacing .08em
		var st := {"fs": 8.5, "ls": 0.68}
		var f := HudTheme.text_font(st)
		var fs := HudTheme.px(8.5)
		var tw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var by := inner.end.y - 2.0 - f.get_descent(fs)
		draw_string(f, Vector2(inner.position.x + roundf((inner.size.x - tw) * 0.5), roundf(by)), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HudTheme.hexc(0x7d93ae))

# A STAGE ROW: a proportional bar behind the name, the propellant and the engine count.
class StageRow extends PanelContainer:
	var frac := 0.0
	var live := false
	var n: Span
	var m: Span
	var e: Span = null

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		Hud.m(self, 0.0, 2.0)
		add_theme_stylebox_override("panel", HudTheme.stylebox({"bg": HudTheme.rgba(12, 20, 32, 0.7), "bw": 0, "rad": 3, "pad": [3, 6, 3, 6]}))
		clip_contents = true

	func _draw() -> void:
		# the bar: full height, frac of the width, over the background
		var w := size.x * frac
		if w > 0.0:
			draw_rect(Rect2(0, 0, w, size.y), HudTheme.rgba(60, 190, 130, 0.30) if live else HudTheme.rgba(60, 130, 200, 0.28))

## A label whose text can be struck through (a separated stage).
class Span extends Label:
	var strike := false
	func _draw() -> void:
		if not strike or label_settings == null: return
		var f := label_settings.font
		var fs := label_settings.font_size
		var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var x := size.x - w if horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT else 0.0
		var y := roundf(f.get_ascent(fs) - HudTheme.metrics(f).x * float(fs) * 0.3)
		draw_rect(Rect2(x, y, w, 1.0), label_settings.font_color)

# THE PANEL
const K := {"fs": 10.0, "c": 0x6f86a0}
const V := {"fs": 10.0, "c": 0xdbeaff}
const NOTE := {"mt": 5.0, "fs": 9.5, "lh": 1.35, "c": 0x7d93ae, "fi": true}

static func _st(d: Dictionary) -> Dictionary:
	var o := d.duplicate()
	if o.get("c") is int: o.c = HudTheme.hexc(o.c)
	o.erase("mt")
	return o

var root: Control
var hooks: Dictionary
var nav: Navball
var thr: Tape
var vs: Tape
var status_box: PanelContainer
var status_el: Prose
var _status_cls := "?"
var grid: HudGrid
var grid_v: Array = []          # value label per row
var grid_k: Array = []
var met_v: KV
var ut_v: KV
var dt_v: KV
var stages_el: HudStack
var stage_rows: Array = []
var mode_btns := {}
var prog_btns := {}
var target_sel: HudSelect
var plan_el: HudStack
var plan_key := ""
var log_el: VBoxContainer
var last_log := -1
var rec_v: Array = []           # the records strip's value cells (see flight_records)

## A key and its value at the cell's two edges. Short of room, both shrink in
## proportion to their width, no narrower than their longest word, and wrap (a
## flex row with space-between, which no stock container lays out).
class KV extends Container:
	var k: Prose
	var v: Prose
	var gap := 6.0

	func _init(kt: String, vt: String, key_st: Dictionary, val_st: Dictionary, g := 6.0) -> void:
		gap = g
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		k = Hud.label(self, "", key_st, true) as Prose
		v = Hud.label(self, "", val_st, true) as Prose
		set_k(kt); set_v(vt)

	func set_k(t: String) -> void:
		if k.said() != t:
			k.say(t)
			update_minimum_size(); queue_sort()

	func set_v(t: String) -> void:
		# a word joiner keeps "km/s" whole, as the design breaks only at spaces
		t = t.replace("/", "/\u2060")
		if v.said() != t:
			v.say(t)
			update_minimum_size(); queue_sort()

	## [max-content, min-content] width of a label's text.
	static func _widths(l: Prose) -> Vector2:
		var f := l.label_settings.font
		var fs := l.label_settings.font_size
		var t := l.said()
		var longest := 0.0
		for w in t.split(" ", false):
			longest = maxf(longest, f.get_string_size(w, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		return Vector2(f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x, longest)

	func _split() -> Array:
		var a := _widths(k)
		var b := _widths(v)
		var room := size.x - gap
		if a.x + b.x <= room:
			return [a.x, b.x]
		var over := a.x + b.x - room
		var wk := maxf(a.x - over * a.x / (a.x + b.x), a.y)
		var wv := room - wk
		if wv < b.y:
			wv = b.y
			wk = maxf(room - wv, a.y)
		return [wk, wv]

	func _get_minimum_size() -> Vector2:
		var a := _widths(k)
		var b := _widths(v)
		return Vector2(a.y + gap + b.y, maxf(k.get_combined_minimum_size().y, v.get_combined_minimum_size().y))

	func _notification(what: int) -> void:
		if what == NOTIFICATION_SORT_CHILDREN:
			var w := _split()
			fit_child_in_rect(k, Rect2(0, 0, w[0] + k.hang, k.get_combined_minimum_size().y))
			fit_child_in_rect(v, Rect2(size.x - w[1], 0, w[1] + v.hang, v.get_combined_minimum_size().y))
			update_minimum_size()

static func _kv(parent: Node, k: String, v: String, gap := 6.0) -> KV:
	var kv := KV.new(k, v, _st(K), _st(V), gap)
	parent.add_child(kv)
	return kv

static func _section(parent: Node, t: String) -> void:
	var l := Hud.label(null, t, {"fs": 9.5, "ls": 1.14, "up": true, "c": HudTheme.hexc(K_COL)})
	parent.add_child(Hud.m(Hud.frame(l, {"bw": 0, "bb": 1, "bc": HudTheme.rgba(120, 190, 255, 0.14), "pad": [0, 0, 3, 0]}), 10.0, 4.0))

static func create_flight_hud(r: Control, h: Dictionary) -> FlightUI:
	return FlightUI.new(r, h)

func _init(r: Control, h: Dictionary) -> void:
	root = r
	hooks = h
	for c in root.get_children(): c.queue_free()
	var top := Hud.hbox(root, 8.0, 6.0, 8.0)
	nav = Navball.new()
	top.add_child(nav)
	var tape := Hud.hbox(top, 6.0)
	tape.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thr = Tape.new("THR", false); tape.add_child(thr)
	vs = Tape.new("V/S", true); tape.add_child(vs)
	status_el = Hud.label(null, "", {"fs": 10.5, "c": HudTheme.hexc(0xa8c4e0)}, true) as Prose
	status_el.custom_minimum_size.y = 15.0
	status_box = Hud.m(Hud.frame(status_el, {}), 0.0, 7.0)
	root.add_child(status_box)
	_set_status("")
	grid = Hud.grid(root, [1.0, 1.0], 8.0, 1.0)
	for i in 20:
		var kv := _kv(grid, "", "")
		grid_k.append(kv); grid_v.append(kv)
	var clocks := HudStack.new(false)
	root.add_child(Hud.m(Hud.frame(clocks, {"bg": HudTheme.rgba(8, 14, 24, 0.6), "bc": HudTheme.rgba(120, 190, 255, 0.18), "rad": 4, "pad": [6, 7, 6, 7]}), 8.0, 8.0))
	met_v = _kv(clocks, "MET · ship", "—", 0.0)
	ut_v = _kv(clocks, "UT · coordinate", "—", 0.0)
	var dkv := KV.new("ship − ground", "—", _st(K), _st({"fs": 10.0, "c": 0xffcf4d}), 0.0)
	clocks.add_child(Hud.m(Hud.frame(dkv, {"bw": 0, "bt": 1, "bc": HudTheme.rgba(120, 190, 255, 0.2), "pad": [3, 0, 0, 0]}), 3.0))
	dt_v = dkv
	_section(root, "Stages")
	stages_el = Hud.stack(root)
	_section(root, "Autopilot")
	var modes := Hud.grid(root, [1.0, 1.0, 1.0, 1.0], 3.0, 3.0)
	for md in MODES:
		var b := HudButton.new("FlMode", md[1])
		modes.add_child(b)
		b.pressed.connect(_on_mode.bind(md[0]))
		mode_btns[md[0]] = b
	var progs := Hud.grid(root, [1.0], 0.0, 3.0, 5.0)
	for pg in PROGRAMS:
		var b := HudButton.new("FlProg", pg[1], pg[2])
		progs.add_child(b)
		b.pressed.connect(_on_program.bind(pg[0]))
		prog_btns[pg[0]] = b
	_section(root, "Target")
	target_sel = HudSelect.new("FlSelect")
	root.add_child(target_sel)
	target_sel.set_options([["", "— none —"]], "")
	target_sel.chosen.connect(_on_target)
	plan_el = Hud.stack(root)
	_section(root, "Flight log")
	var recs := Hud.grid(root, [1.0, 1.0], 8.0, 1.0, 0.0, 5.0)
	for rec in flight_records(null):
		rec_v.append(_kv(recs, rec[0], rec[1]))
	var log_scroll := CapScroll.new(150.0, VBoxContainer.new())
	log_el = log_scroll.content
	log_el.add_theme_constant_override("separation", 0)
	root.add_child(log_scroll)

func _on_mode(key: String) -> void:
	if hooks.has("setMode"): hooks.setMode.call(key)

func _on_program(key: String) -> void:
	if hooks.has("runProgram"): hooks.runProgram.call(key)

func _on_target(v: String) -> void:
	if hooks.has("setTarget"): hooks.setTarget.call(v)

## The status line's look: plain, failed or landed.
func _set_status(cls: String) -> void:
	if cls == _status_cls and status_box.has_theme_stylebox_override("panel"):
		return
	_status_cls = cls
	var bar: int = {"fail": 0xff5a4a, "good": 0x57d98a}.get(cls, -1)
	var text: int = {"fail": 0xffb0a6, "good": 0xb6f0cd}.get(cls, 0xa8c4e0)
	status_box.add_theme_stylebox_override("panel", HudTheme.stylebox({"bg": HudTheme.rgba(10, 20, 34, 0.7), "bw": 0, "bl": 2,
		"bc": HudTheme.ACCENT if bar < 0 else HudTheme.hexc(bar), "pad": [4, 7, 4, 7]}))
	HudTheme.apply_label(status_el, {"fs": 10.5, "c": HudTheme.hexc(text)})

func set_targets(names: Array, current) -> void:
	var opts := [["", "— none —"]]
	for n in names: opts.append([n, n])
	target_sel.set_options(opts, current if current != null else "")

## `s`: {vessel, telemetry, up: Vector3, north: Vector3, markers: {key: Vector3},
## status, mode, program, warp, parentName, plan (plan_block / cruise_block), roll}
func update(s: Dictionary) -> void:
	var t: Dictionary = s.telemetry
	var v: Vessel = s.vessel
	nav.draw_ball(v.q.to_quaternion(), s.up, s.north, s.markers, {"roll": s.get("roll")})
	status_el.say(str(s.status))
	_set_status("fail" if v.failure != null else ("good" if v.phase == "landed" else ""))

	thr.set_frac(float(U.jround(v.throttle * 100.0)) / 100.0)
	var vsv := clampf(float(U.nz(t.get("vertical"), 0.0)) / 400.0, -1.0, 1.0)
	vs.set_frac(float(U.fixed(50.0 + vsv * 46.0, 1)) / 100.0)

	var tf := func(k: String) -> float: return float(U.nz(t.get(k), 0.0))
	# Missing telemetry reads as a dash (in cruise there is no altitude about a parent).
	var tn := func(k: String) -> float: return float(U.nz(t.get(k), NAN))
	var mach: float = tf.call("mach")
	var period = t.get("period")
	var rows := [
		["altitude", fmt_dist(tn.call("alt"))],
		["speed", fmt_speed(tn.call("speed"))],
		["vertical", fmt_speed(tn.call("vertical"))],
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
	if s.get("cruise", false):
		# In cruise the parent-relative orbit and TWR are meaningless; the cruise
		# block replaces them.
		for i in [4, 5, 6, 7, 14, 17]: rows[i][1] = "—"
		# A photon drive's Δv in units of c is the rapidity left.
		rows[16][1] = "%s c" % U.fixed(tf.call("dv") / 299792458.0, 3)
	for i in rows.size():
		(grid_k[i] as KV).set_k(rows[i][0])
		(grid_v[i] as KV).set_v(rows[i][1])

	met_v.set_v(Guidance.fmt_dur(v.met))
	ut_v.set_v(Guidance.fmt_dur(v.coord))
	dt_v.set_v(fmt_clock_delta(v.clock_delta))

	_update_stages(v)

	for k in mode_btns: (mode_btns[k] as HudButton).set_active(k == s.get("mode"))
	for k in prog_btns: (prog_btns[k] as HudButton).set_active(k == s.get("program"))

	_update_plan(s.get("plan", {}))

	# The flight's records: the numbers a post-flight report leads with.
	var recs := flight_records(v)
	for i in recs.size(): (rec_v[i] as KV).set_v(recs[i][1])

	if v.events.size() != last_log:
		last_log = v.events.size()
		Hud._clear(log_el)
		var ev: Array = v.events.slice(-40)
		ev.reverse()
		var tcol := HudTheme.hexc(0x5f7590).to_html(false)
		for e in ev:
			var r := Hud.rich("[color=#%s]%s[/color]  %s" % [tcol, Guidance.fmt_dur(e.t), Hud.esc(str(e.msg))],
				{"fs": 9.5, "lh": 1.4, "c": HudTheme.hexc(0xa8c4e0)})
			log_el.add_child(Hud.frame(r, {"bw": 0, "bb": 1, "bc": HudTheme.rgba(120, 190, 255, 0.06), "pad": [1, 0, 1, 0]}))

static func _put(l: Label, t: String) -> void:
	if l is Prose:
		(l as Prose).say(t)
	elif l.text != t:
		l.text = t

## The flight log's records strip (four numbers). `v` null gives the labels with
## empty values.
static func flight_records(v) -> Array:
	if v == null: return [["max-Q", "—"], ["peak g", "—"], ["top Mach", "—"], ["peak heating", "—"]]
	return [
		["max-Q", ("%s kPa · T+%s s" % [U.fixed(v.max_q / 1000.0, 1), U.fixed(v.max_q_t, 0)]) if v.max_q > 100.0 else "—"],
		["peak g", "%s g" % U.fixed(v.max_g, 2)],
		["top Mach", U.fixed(v.max_mach, 2) if v.max_mach > 0.01 else "—"],
		["peak heating", ("%s W/cm²" % U.fixed(v.peak_heat / 1e4, 1)) if v.peak_heat > 100.0 else "—"],
	]

func _update_stages(v: Vessel) -> void:
	if stage_rows.size() != v.stages.size():
		Hud._clear(stages_el)
		stage_rows.clear()
		for st in v.stages:
			var row := StageRow.new()
			stages_el.add_child(row)
			var h := Hud.hbox(row, 6.0)
			row.n = Span.new(); h.add_child(row.n)
			row.n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.n.clip_text = true
			row.m = Span.new(); h.add_child(row.m)
			if st.spec.get("count", 0):
				row.e = Span.new(); h.add_child(row.e)
				row.e.custom_minimum_size.x = 26.0
				row.e.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				HudTheme.apply_label(row.e, {"fs": 10.0, "c": HudTheme.hexc(0x8fa8c4)})
			HudTheme.apply_label(row.m, {"fs": 10.0, "c": HudTheme.hexc(0x8fa8c4)})
			stage_rows.append(row)
	for i in v.stages.size():
		var st = v.stages[i]
		var row: StageRow = stage_rows[i]
		var frac: float = st.prop / st.prop0 if st.prop0 > 0.0 else 0.0
		var cls: String = "gone" if not st.attached else (("spent" if st.spent else "live") if st.ignited else "pending")
		var f := float(U.fixed(frac * 100.0, 1)) / 100.0
		if f != row.frac or row.live != (cls == "live"):
			row.frac = f
			row.live = cls == "live"
			row.queue_redraw()
		row.modulate.a = 0.28 if cls == "gone" else (0.55 if cls == "spent" else 1.0)
		var nc := 0x9ff0c0 if cls == "live" else (0x8fa8c4 if cls == "pending" else 0xcfe6ff)
		HudTheme.apply_label(row.n, {"fs": 10.0, "c": HudTheme.hexc(nc)})
		_put(row.n, str(st.spec.name))
		_put(row.m, fmt_mass_t(st.prop) if st.prop0 > 0.0 else fmt_mass_t(st.spec.dry))
		if row.e != null: _put(row.e, "%d/%d" % [st.live, st.spec.count])
		for sp in [row.n, row.m, row.e]:
			if sp != null and sp.strike != (cls == "gone"):
				sp.strike = cls == "gone"
				sp.queue_redraw()

func _update_plan(p: Dictionary) -> void:
	var key := JSON.stringify(p)
	if key == plan_key: return
	plan_key = key
	Hud._clear(plan_el)
	if p.is_empty(): return
	match p.kind:
		"none":
			Hud.m(Hud.label(plan_el, str(p.text), _st(NOTE), true), 5.0)
		"rows":
			var body := Hud.grid(plan_el, [1.0], 0.0, 1.0, 5.0)
			for r in p.rows: _kv(body, r[0], r[1], 0.0)
			if p.has("note"): Hud.m(Hud.label(body, str(p.note), _st(NOTE), true), 5.0)
		"cruise":
			var wrap := Hud.stack(plan_el)
			wrap.add_child(Hud.m(CruiseBar.new(p.bar), 6.0, 8.0))
			var g := Hud.grid(wrap, [1.0, 1.0], 8.0, 1.0)
			for r in p.grid: _kv(g, r[0], r[1])
			Hud.m(Hud.label(wrap, str(p.note), _st(NOTE), true), 5.0)

## Progress across an interstellar crossing, with the two burn markers.
class CruiseBar extends Control:
	var vals: Array
	func _init(v: Array) -> void:
		vals = v
		custom_minimum_size.y = 8.0
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		FlightUI._box(self, Rect2(Vector2.ZERO, size), HudTheme.rgba(12, 20, 32, 0.9), HudTheme.rgba(120, 190, 255, 0.2), 4)
		var inner := Rect2(Vector2(1, 1), size - Vector2(2, 2))
		var w := inner.size.x * clampf(float(vals[0]) / 100.0, 0.0, 1.0)
		if w > 0.0:
			var c0 := HudTheme.hexc(0x2a7fd0); var c1 := HudTheme.hexc(0x7fd0ff)
			draw_polygon(PackedVector2Array([inner.position, inner.position + Vector2(w, 0), inner.position + Vector2(w, inner.size.y), inner.position + Vector2(0, inner.size.y)]),
				PackedColorArray([c0, c1, c1, c0]))
		for i in [1, 2]:
			var x := inner.position.x + inner.size.x * float(vals[i]) / 100.0
			draw_rect(Rect2(x, inner.position.y - 3.0, 1.0, 14.0), HudTheme.rgba(255, 207, 77, 0.8))
