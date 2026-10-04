class_name MassCurve
extends CrossSection.BitmapCanvas

# Hypothetical mass edits supply the curve; the canonical body supplies its handle.
# Regime boundaries are sampled from Structure rather than copied thresholds.

const N := 240                 # samples across the range
const PAD_L := 34.0
const PAD_R := 10.0
const PAD_T := 14.0
const PAD_B := 22.0

# Colour per resulting type, so the curve changes colour at an ignition threshold.
const TYPE_COLOR := {
	"planet": 0x7fb2e0, "world": 0x7fb2e0, "gas-giant": 0xd9a15e, "star": 0xffd27f,
	"white-dwarf": 0xcfe4ff, "neutron": 0xa8d8ff, "bh": 0xb98cff,
}
const DEAD := Color(1.0, 110 / 255.0, 110 / 255.0, 0.85)

## fires with the picked mass (M☉) on press and on every drag move
signal picked(mass: float)

var on_pick: Callable = Callable()
var spec = null                          # Dictionary or null
var range_ := [-6.0, 1.0]
var samples: Array = []                  # {lm, ly, type} or null
var marks: Array = []                    # {lm, label, type, bad}
var view := [-6.0, 1.0]
var dead: Array = []                     # [lo, hi] spans with no equilibrium
var focus := false                       # zoomed to the nearest boundary
var _cache_key := ""
var _draw_key := ""
var _view_key := ""
var _live_structure: Dictionary = {}
var _down := false

static func type_color(t) -> Color:
	return HudTheme.hexc(TYPE_COLOR.get(t, 0x9fc4ff))

func _init(bg_col := HudTheme.CLEAR, border_col := HudTheme.CLEAR, w := 330.0, h := 152.0) -> void:
	super(w, h, bg_col, border_col)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_HSIZE

func _X(lm: float) -> float:
	return PAD_L + (lm - view[0]) / (view[1] - view[0]) * (bw - PAD_L - PAD_R)

func _unX(px: float) -> float:
	return view[0] + (px - PAD_L) / (bw - PAD_L - PAD_R) * (view[1] - view[0])

static func _with_mass(s: Dictionary, m: float) -> Dictionary:
	var o := s.duplicate()
	# The curve predicts a mass edit, which replaces measured values with the model.
	for field in Derive.MASS_EDIT_MEASUREMENTS:
		o.erase(field)
	o["mass"] = m
	return o

# A regime is what the model says the object IS at that mass — its type plus
# the verdict on whether it can hold itself up. A change in either is a line.
static func regime_key(st: Dictionary) -> String:
	var v = st.get("verdict")
	var state = v.get("state") if v is Dictionary else null
	return "%s|%s" % [st.get("type"), state if state != null else Structure.VERDICT.ok]

# A boundary's name: the verdict label if there is one ("TOV limit exceeded"), else
# the new object's label ("Brown dwarf").
static func regime_label(st: Dictionary) -> String:
	var v = st.get("verdict")
	var lab = st.get("label")
	var own := str(lab) if (lab != null and str(lab) != "") else str(st.get("type"))
	# A reclassification's verdict label is the generic word "Reclassified"; the
	# interesting half is what it became, which is the structure's own label.
	var rf = st.get("reclassifiedFrom")
	if rf != null and str(rf) != "": return own
	if v is Dictionary and v.get("state") != Structure.VERDICT.ok and v.get("label") != null and str(v.label) != "":
		return str(v.label)
	return own

static func _bad(st: Dictionary) -> bool:
	var v = st.get("verdict")
	return v is Dictionary and v.get("state") != Structure.VERDICT.ok

static func fmt_mass_short(m: float) -> String:
	# Plain scientific notation at the top of the range (the BH slider reaches 1e9).
	if m >= 1e6:
		var e := CrossSection.decade(m)
		return "%se%d M☉" % [Structure._num(float(U.prec(m / pow(10.0, e), 2))), e]
	if m >= 0.02: return "%s M☉" % (U.fixed(m, 2) if m < 10.0 else U.prec(m, 3))
	if m / Structure.M_JUP_SUN >= 0.3: return "%s M_J" % U.fixed(m / Structure.M_JUP_SUN, 1)
	return "%s M⊕" % U.prec(m / Structure.M_EARTH_SUN, 2)

# Radius axis labels. One unit for the whole axis, chosen from what the curve
# actually covers — km for compact objects, R⊕ for planets, R☉ for stars.
static func radius_unit(max_au: float) -> Dictionary:
	if max_au < 3e-5: return {"k": 1.0 / Physics.AU_PER_KM, "name": "km"}
	if max_au < 4e-3: return {"k": 1.0 / (6.371e6 / 1000.0 * Physics.AU_PER_KM), "name": "R⊕"}
	return {"k": 1.0 / Physics.AU_PER_RSUN, "name": "R☉"}

func _resample() -> void:
	var inputs := _with_mass(spec, 0.0)
	inputs.erase("mass")
	var key := var_to_str([inputs, view])
	if key == _cache_key:
		return
	_cache_key = key
	samples = []; marks = []; dead = []
	var prev_key = null
	var dead_from = null
	for i in N:
		var lm: float = view[0] + (view[1] - view[0]) * i / (N - 1)
		var m := pow(10.0, lm)
		var st := Structure.structure_of(_with_mass(spec, m))
		var r := CrossSection.num(st.get("radiusAU"))
		var k := regime_key(st)
		if prev_key != null and k != prev_key:
			marks.append({"lm": lm, "label": regime_label(st), "type": st.get("type"), "bad": _bad(st)})
		prev_key = k
		# A mass with no equilibrium radius is a gap in the curve, not a zero.
		if not (r > 0.0):
			if dead_from == null: dead_from = lm
			samples.append(null)
		else:
			if dead_from != null:
				dead.append([dead_from, lm]); dead_from = null
			samples.append({"lm": lm, "ly": U.log10(r), "type": st.get("type")})
	if dead_from != null: dead.append([dead_from, view[1]])

# The nearest regime boundary to a given mass — what "focus" zooms to, and
# what the readout names so you know which cliff you are walking toward.
func nearest_mark(lm: float):
	var best = null
	var d := INF
	for mk in marks:
		var dd := absf(float(mk.lm) - lm)
		if dd < d:
			d = dd; best = mk
	return best

func _paint(ci: CanvasItem) -> void:
	var W := bw; var H := bh
	var plotH := H - PAD_T - PAD_B
	if spec == null:
		return
	_resample()

	var live: Array = samples.filter(func(s): return s != null)
	if live.is_empty():
		return
	var y0 := INF; var y1 := -INF
	for s in live:
		y0 = minf(y0, s.ly); y1 = maxf(y1, s.ly)
	var handle_structure := _live_structure if not _live_structure.is_empty() else Structure.structure_of(spec)
	var handle_radius := CrossSection.num(handle_structure.get("radiusAU"))
	if handle_radius > 0.0:
		# A measured body may sit beyond the modeled radii along its mass-edit curve.
		y0 = minf(y0, U.log10(handle_radius)); y1 = maxf(y1, U.log10(handle_radius))
	# A flat curve (a neutron star barely changes radius over its whole range)
	# would otherwise be drawn with the noise amplified to fill the panel.
	if y1 - y0 < 0.5:
		var c := (y0 + y1) / 2.0
		y0 = c - 0.25; y1 = c + 0.25
	var padY := (y1 - y0) * 0.12
	y0 -= padY; y1 += padY
	var Y := func(ly: float) -> float: return PAD_T + (1.0 - (ly - y0) / (y1 - y0)) * plotH

	# decade grid. Log axes are only honest if the reader can see the
	# decades, so both sets of gridlines are drawn at powers of ten.
	var grid := Color8(140, 170, 210, 26)
	var lab := Color8(150, 175, 210, 140)
	var unit := radius_unit(pow(10.0, y1))
	for d in range(int(ceil(y0)), int(floor(y1)) + 1):
		var y: float = Y.call(float(d))
		ci.draw_line(Vector2(PAD_L, y), Vector2(W - PAD_R, y), grid, 1.0, true)
		var v := pow(10.0, d) * float(unit.k)
		var t := U.expo(v, 0).replace("e+", "e") if (v >= 1e4 or v < 0.01) else Structure._num(float(U.prec(v, 2)))
		CrossSection.fill_text(ci, t, PAD_L - 4.0, y, 9, lab, "right", "middle")
	CrossSection.fill_text(ci, unit.name, 2, PAD_T - 6.0, 9, lab, "left", "middle")
	# Every decade gets a gridline; only some get a label (30 px per decade).
	var per_decade := _X(1.0) - _X(0.0)
	var label_every := maxi(1, int(ceil(56.0 / maxf(per_decade, 1.0))))
	for d in range(int(ceil(view[0])), int(floor(view[1])) + 1):
		var x := _X(float(d))
		ci.draw_line(Vector2(x, PAD_T), Vector2(x, H - PAD_B), grid, 1.0, true)
		if posmod(d, label_every) != 0: continue
		CrossSection.fill_text(ci, fmt_mass_short(pow(10.0, d)), x, H - PAD_B + 4.0, 9, Color8(150, 175, 210, 115), "center", "top")

	# dead zones: masses with no equilibrium at all
	for ab in dead:
		ci.draw_rect(Rect2(_X(ab[0]), PAD_T, maxf(_X(ab[1]) - _X(ab[0]), 1.5), plotH), Color8(255, 90, 90, 26))

	# regime boundaries, drawn before the curve so the curve sits on top
	for mk in marks:
		var x := _X(mk.lm)
		if x < PAD_L or x > W - PAD_R: continue
		var c := Color8(255, 120, 120, 191) if mk.bad else Color8(150, 200, 255, 140)
		CrossSection.stroke_line(ci, Vector2(x, PAD_T), Vector2(x, H - PAD_B), c, 1.0, [3.0, 3.0])

	# the curve, coloured by what the object IS at that mass
	var run: Array = []
	var flush := func(r: Array) -> void:
		if r.size() < 2: return
		var pts := PackedVector2Array()
		for s in r: pts.append(Vector2(_X(s.lm), Y.call(s.ly)))
		ci.draw_polyline(pts, type_color(r[0].type), 2.0, true)
	for s in samples:
		if s == null:
			flush.call(run); run = []
			continue
		if not run.is_empty() and run[-1].type != s.type:
			var last = run[-1]
			flush.call(run); run = [last]
		run.append(s)
	flush.call(run)

	# boundary labels last, alternating two rows; a label that would still overlap
	# is dropped.
	var row_end := [-1e9, -1e9]
	for mk in marks:
		var x := _X(mk.lm)
		if x < PAD_L or x > W - PAD_R: continue
		var txt: String = mk.label if mk.label.length() <= 20 else mk.label.substr(0, 19) + "…"
		var w := CrossSection.text_w(txt, 9)
		var row := 0 if row_end[0] <= row_end[1] else 1
		if x < row_end[row] + 6.0: continue
		var tx := minf(x + 3.0, W - PAD_R - w - 1.0)
		row_end[row] = tx + w
		var ty := PAD_T + 1.0 + row * 12.0
		ci.draw_rect(Rect2(tx - 2.0, ty, w + 4.0, 11.0), Color8(8, 10, 16, 184))
		CrossSection.fill_text(ci, txt, tx, ty + 1.0, 9, HudTheme.hexc(0xff9a9a) if mk.bad else HudTheme.hexc(0xa9cdf5), "left", "top")

	# The measured live handle may differ from the hypothetical mass-edit curve.
	var lm := U.log10(float(spec.mass))
	if lm >= view[0] and lm <= view[1]:
		var x := _X(lm)
		CrossSection.stroke_line(ci, Vector2(x, PAD_T), Vector2(x, H - PAD_B), Color(1, 1, 1, 0.35), 1.0, [2.0, 3.0])
		if handle_radius > 0.0:
			var y: float = Y.call(U.log10(handle_radius))
			ci.draw_circle(Vector2(x, y), 4.5, Color.WHITE, true, -1.0, true)
			ci.draw_arc(Vector2(x, y), 4.5, 0.0, TAU, 32, DEAD if _bad(handle_structure) else type_color(handle_structure.get("type")), 2.0, true)

# interaction: dragging the handle is the same edit as the mass slider.
func _pick(p: Vector2) -> void:
	var px := to_bitmap(p).x
	var lm := minf(maxf(_unX(px), view[0]), view[1])
	var m := pow(10.0, lm)
	picked.emit(m)
	if on_pick.is_valid(): on_pick.call(m)

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_down = e.pressed
		if e.pressed: _pick(e.position)
		accept_event()
	elif e is InputEventMouseMotion and _down:
		_pick(e.position)
		accept_event()

## True while the pointer holds the handle.
func is_dragging() -> bool:
	return _down

# spec: the body's current parameters (type, mass, spinFrac, composition…).
# range: [log10 lo, log10 hi] of the type's full mass range.
# live_structure: optional canonical model for the handle, including measured values.
func draw_curve(new_spec: Dictionary, new_range = null, live_structure: Dictionary = {}) -> void:
	var next_range = new_range if new_range != null else range_
	var key := var_to_str([new_spec, next_range, focus])
	var same_live := is_same(live_structure, _live_structure) or (live_structure.is_empty() and _live_structure.is_empty())
	if key == _draw_key and same_live:
		return
	_draw_key = key
	_live_structure = live_structure
	spec = new_spec.duplicate(true)
	range_ = next_range.duplicate()
	var lm := U.log10(float(spec.mass))
	var view_key := var_to_str([_with_mass(spec, float(spec.mass)), range_, focus])
	if focus and view_key != _view_key:
		# Zoomed: the nearest boundary and the body in one ±0.35 dex window.
		view = [minf(lm, range_[0]), maxf(lm, range_[1])]
		_resample()
		var mk = nearest_mark(lm)
		var c: float = (float(mk.lm) + lm) / 2.0 if mk != null else lm
		var half := maxf(0.35, absf(float(mk.lm) - lm) * 0.75 + 0.2 if mk != null else 0.35)
		view = [c - half, c + half]
	elif not focus:
		view = [minf(range_[0], lm - 0.02), maxf(range_[1], lm + 0.02)]
	_view_key = view_key
	repaint()

func set_focus(v: bool) -> void:
	focus = v

# What the body is closest to becoming, for the caption. Needs draw_curve() first.
func nearest(mass: float):
	if spec != null: _resample()
	var lm := U.log10(mass)
	var mk = nearest_mark(lm)
	if mk == null: return null
	return {"label": mk.label, "mass": pow(10.0, mk.lm), "above": float(mk.lm) < lm, "bad": mk.bad}
