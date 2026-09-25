class_name Hud
extends Control

# ============================================================================
# THE HUD — blackhole_sim.html's markup, blackhole_sim.css's rules, and the DOM
# half of blackhole_sim.js, as one Control.
# ----------------------------------------------------------------------------
# Every panel, control and caption of the page is an El (ui/widgets/el.gd), a
# node that carries one element's computed style and is laid out by CSS's own
# rules. The tree below is the HTML's tree, element for element and in the same
# order, so reading this file against blackhole_sim.html is a diff; the styles
# are blackhole_sim.css's (ui/hud_css.gd). Anything that is an `id` in the page
# is registered under that id, and the orchestrator reaches it through
# set_text / set_shown / set_active exactly as blackhole_sim.js reached it
# through document.getElementById.
#
# WHAT MOVED IN HERE from blackhole_sim.js, so the orchestrator does NOT do it:
#   * renderPresetGroups, including the search box, the <details> groups and
#     their remembered open state — the Hud only reports preset_chosen(key);
#   * refreshUI's markup (render_body_list), updateHUD's sun rows and climate
#     block (render_sun_list, update_climate) and drawClimateChart;
#   * toast, setPanelOpen, layoutLeftColumn — all of it, measured — and the
#     tabs a collapsed panel leaves behind;
#   * groupControlSections / setSectionOpen / applySectionModes, with
#     SECTION_MODE and OPEN_BY_DEFAULT, and the section heads' click;
#   * setHudHidden's class, the mode switch's visuals, the settings pages;
#   * every range input's value label and its formatter (timeLabel, the
#     toExponential of the step cap, °, d, m, ×) on user input;
#   * the markup of the band grid, the craft grid, the model viewer's chips,
#     list and stage rows, the sky environment and amplitude rows.
# The orchestrator keeps every DECISION: what a click means, which panels a
# mode opens, what the values are. It hears about input through the signals
# below and answers through the methods.
#
# The HUD sits over the 3D view as a full-rect Control that ignores the mouse
# itself; only the panels and their controls stop it. A click, drag or wheel on
# empty screen therefore reaches the orchestrator's _unhandled_input.
# ============================================================================

# ---- Hud → orchestrator ------------------------------------------------------------
signal start_chosen(mode: String)
signal mode_chosen(mode: String)
signal preset_chosen(key: String)
signal body_focus(id: int)
signal body_remove(id: int)
signal spawn(type: String)
signal paint(kind: String)
signal clear_bodies()
signal delete_focus()
signal xsec_open()
signal xsec_closed()
signal cam_mode(mode: String)
signal view_toggle(which: String)
signal reset_view()
signal band_chosen(i: int)
signal time_regime(name: String)
signal slider(id: String, value: float)
signal sky_solo(name: String)
signal sky_reset()
signal sky_adv_clear()
signal fx_reset()
signal sim_reset()
signal climate_reset()
signal craft_launch(key: String)
signal craft_hover(key: String)
signal flight_exit()
signal flight_cam_cycle()
signal warp_step(dir: int)
signal model_open()
signal model_close()
signal model_show(key: String)
signal model_deploy(on: bool)
signal model_spin(on: bool)
signal model_fly()
signal panel_changed(id: String, open: bool)
## The lesson card's own buttons (the course UI, written elsewhere, listens).
signal lesson_back()
signal lesson_next()
signal lesson_close()

const T = preload("res://ui/theme.gd")
const C = preload("res://ui/hud_css.gd")

# The control column's sections, by mode. See applySectionModes.
# Spaceflight is for FLYING. Not one of the orrery's controls belongs in it:
# the scenario list, the interior editor, the painter, the spawner, the body
# list, the imaging bands, the camera modes and — above all — the time-scale
# slider are all things you do to a universe you are looking at, and none of
# them mean anything while you are holding a vehicle down on a pad.
const SECTION_MODE := {
	"Central Singularity": "sandbox", "Suns": "sandbox", "Climate": "sandbox",
	"Imaging Band": "sandbox", "View & Camera": "sandbox", "Time": "sandbox",
	"Focused Object": "sandbox", "Object Foundry": "sandbox", "Painter": "sandbox",
	"Spaceflight": "flight", "Quick Spawn": "sandbox", "Bodies": "sandbox",
}
const OPEN_BY_DEFAULT := {
	"sandbox": ["Suns", "Imaging Band", "View & Camera", "Bodies"],
	# A lesson's own card already carries the narration, so the column beside it
	# opens with the two things lessons most often ask you to reach for.
	"learn": ["Imaging Band", "View & Camera"],
	"flight": ["Spaceflight"],
}
const STEP_GUARD := 8000

# ---- registries -----------------------------------------------------------------------------
var ids := {}            # element id → El
var run_ids := {}        # id of an inline <span> → [El, run]
var sels := {}           # "[data-x=v]" or id → Array of El
var sliders := {}        # range id → RangeInput
var val_fmt := {}        # range id → Callable(v) -> String (its "-val" label)
var roots: Array = []    # positioned elements, laid out by _layout_all
var collapsed := {}      # panel id → true
var body := {}           # the <body> classes: flight-mode, learn-mode, model-open, hud-hidden, …
var sections: Array = [] # {title, head, wrap, host, arrow}
var tabs := {}           # panel id → its tab
var hidden_flags := {}   # El → {inline, mode, closed}
var app_mode := "sandbox"

var hud_hidden := false
var _mounts := {}
var _open_groups := {}   # preset group ids opened by hand
var _groups: Array = []
var _presets := {}
var _active_preset := ""
var _band_count := 0
var _sun_rows: Array = []
var _flare_els: Array = []
var _toast_tween: Tween = null
var _toast_timer := 0.0
var _toast_x := 0.0
var _time := 0.0
var _envs: Array = []
var _params: Array = []
var _last_size := Vector2.ZERO

# elements the layout needs by name
var title_block: El
var settings_panel: El
var scenario_panel: El
var course_panel: El
var lesson_card: El
var control_panel: El
var model_panel: El
var xsec_panel: El
var flight_panel: El
var tab_col: El
var tab_right: El
var readout: El
var hint: El
var toast_el: El
var start_screen: El
var start_cards: El
var corners: Array = []

## The lesson card's parts, for the course UI to fill.
var lc := {}

func _init() -> void:
	name = "Hud"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = T.theme()

func _ready() -> void:
	_build()
	# both start open — this also seeds the class the hint's position keys off
	for id in ["settingsPanel", "scenarioPanel", "controlPanel"]:
		set_panel_open(id, true)
	# The flight panel starts closed and only opens when there is a vessel; the
	# cross-section starts closed and has no tab — it is opened from a body.
	set_panel_open("flightPanel", false)
	set_panel_open("xsecPanel", false)
	set_app_mode("sandbox")
	_layout_all()

# =============================================================================================
# BUILDERS
# =============================================================================================

func E(parent: Node, style: Dictionary = {}, text = null, id := "", vars: Array = []) -> El:
	var e := El.new(style, vars)
	if text is String:
		e.runs = [{"t": text}]
	elif text is Array:
		e.runs = text
	parent.add_child(e)
	if id != "":
		reg(id, e)
	return e

## A <button>. `sel` registers it under an id or a "[data-x=v]" selector.
func B(parent: Node, style: Dictionary, text, sel := "", vars: Array = [], tip := "") -> El:
	var e := E(parent, style, text, "", vars)
	e.make_clickable(tip)
	if sel != "":
		reg(sel, e)
	return e

func reg(key: String, e: El) -> void:
	if not key.begins_with("["):
		ids[key] = e
		e.el_id = key
	if not sels.has(key):
		sels[key] = []
	sels[key].append(e)

func root(e: El) -> El:
	e.is_root = true
	roots.append(e)
	# A panel takes the pointer: a click on it never becomes a pick in the 3D
	# view behind it, and a wheel over it scrolls it (the page's panels are
	# pointer-events:none themselves but every child is auto, which is the
	# same thing everywhere but their padding).
	if e.base.has("blur") and not e.clickable:
		e.mouse_filter = Control.MOUSE_FILTER_STOP
	return e

func _h3(parent: Node, text: String, first := false, id := "") -> El:
	return E(parent, C.h3(first), text, id)

## .panel-head: the heading and a ✕ that collapses the panel.
func _panel_head(p: El, title: String, close_id: String, tip := "Collapse (H hides everything)") -> El:
	var head := E(p, C.PANEL_HEAD)
	E(head, C.merge(C.h3(true), {"grow": 1.0, "basis": 0.0, "minw": 0.0}), title)
	var x := B(head, C.panel_close(), "✕", "", [["hover", C.PANEL_CLOSE_HOVER]], tip)
	x.pressed.connect(func(): _close_pressed(close_id))
	return head

func _close_pressed(id: String) -> void:
	if id == "modelPanel":
		model_close.emit()
		return
	set_panel_open(id, false)
	if id == "xsecPanel":
		xsec_closed.emit()

func _note(parent: Node, runs: Array, extra := {}) -> El:
	return E(parent, C.merge(C.section_note(), extra), runs)

static func _t(s: String, extra := {}) -> Dictionary:
	var r := {"t": s}
	r.merge(extra, true)
	return r

## A control-column range row: label · slider · value.
func _row(parent: Node, id: String, label: String, tip: String, mn: float, mx: float, v: float, st: float,
		val_text: String, row_id := "", fmt: Callable = Callable()) -> El:
	var row := E(parent, C.ROW, null, row_id)
	var ls := C.ROW_LABEL.duplicate()
	if tip != "":
		ls.merge(C.ROW_LABEL_TITLE, true)
	var lab := E(row, ls, label)
	if tip != "":
		lab.tooltip_text = tip
		lab.mouse_filter = Control.MOUSE_FILTER_PASS
		lab.mouse_default_cursor_shape = Control.CURSOR_HELP
	_range(row, id, C.ROW_RANGE, mn, mx, v, st, fmt)
	E(row, C.ROW_VAL, val_text, id + "-val")
	return row

## A settings-panel range row: label and value on one line, slider under them.
func _set_row(parent: Node, id: String, label: String, tip: String, mn: float, mx: float, v: float, st: float,
		val_text: String, fmt: Callable = Callable()) -> El:
	var row := E(parent, {"mb": 13.0})
	var head := E(row, {"display": "flex", "ai": "baseline", "gapc": 8.0})
	var ls := C.merge(C.ROW_LABEL, {"grow": 1.0, "shrink": 1.0, "basis": 0.0, "minw": 0.0})
	if tip != "":
		ls.merge(C.ROW_LABEL_TITLE, true)
		ls["as"] = "baseline"
	var lab := E(head, ls, label)
	# grid-area 1/1: the label's cell is the whole 1fr track, but its dotted
	# border is its own box, which is only as wide as the text
	lab.set_style({"fit": true})
	if tip != "":
		lab.tooltip_text = tip
		lab.mouse_filter = Control.MOUSE_FILTER_PASS
		lab.mouse_default_cursor_shape = Control.CURSOR_HELP
	E(head, C.merge(C.ROW_VAL, {"minw": 0.0}), val_text, id + "-val")
	_range(row, id, {"wp": 1.0, "mt": 8.0}, mn, mx, v, st, fmt)
	return row

func _range(parent: Node, id: String, style: Dictionary, mn: float, mx: float, v: float, st: float,
		fmt: Callable = Callable()) -> RangeInput:
	var r := RangeInput.new(style)
	r.setup(mn, mx, st, v)
	r.input_id = id
	parent.add_child(r)
	if id != "":
		reg(id, r)
		sliders[id] = r
		if fmt.is_valid():
			val_fmt[id] = fmt
		r.changed.connect(_on_slider.bind(id))
	return r

func _on_slider(v: float, id: String) -> void:
	if val_fmt.has(id):
		set_text(id + "-val", val_fmt[id].call(v))
	slider.emit(id, v)

# =============================================================================================
# THE PAGE
# =============================================================================================

func _build() -> void:
	# .corner — z-index 5, under everything
	for k in ["tl", "tr", "bl", "br"]:
		var s := {"w": 14.0, "h": 14.0}
		var b := T.BORDER_STRONG
		match k:
			"tl": s.merge({"bt": 1.0, "bl": 1.0, "bct": b, "bcl": b})
			"tr": s.merge({"bt": 1.0, "br": 1.0, "bct": b, "bcr": b})
			"bl": s.merge({"bb": 1.0, "bl": 1.0, "bcb": b, "bcl": b})
			"br": s.merge({"bb": 1.0, "br": 1.0, "bcb": b, "bcr": b})
		var c := root(E(self, s))
		c.set_meta("corner", k)
		corners.append(c)
	_build_flight_panel()     # z-index 6: under the other panels
	_build_title_block()
	_build_settings()
	_build_scenario()
	_build_course()
	_build_lesson_card()
	_build_control_panel()
	_build_model_panel()
	_build_xsec_panel()
	_build_tabs()
	_build_readout()
	_build_hint()
	_build_start()
	toast_el = root(E(self, {"bg": T.PANEL, "b": [1, T.BORDER_STRONG], "blur": 10.0, "p": [9, 16], "c": T.TEXT,
		"fs": 10.0, "ls": C.em(0.14, 10), "up": true, "ta": "center", "op": 0.0}, "", "toast"))

# ---- title block: the mode switch ---------------------------------------------------------
func _build_title_block() -> void:
	title_block = root(E(self, {}))
	var ms := E(title_block, {"display": "flex", "gapc": 4.0, "mt": 9.0})
	for m in [["sandbox", "Sandbox"], ["learn", "Learn"], ["flight", "Spaceflight"]]:
		var b := B(ms, C.ms_btn(), m[1], "[data-mode=%s]" % m[0],
			[["hover", {"c": T.TEXT, "bcol": T.BORDER_STRONG}], ["on", C.MS_ON]])
		b.pressed.connect(func(): mode_chosen.emit(m[0]))

# ---- SETTINGS -----------------------------------------------------------------------------
func _build_settings() -> void:
	var p := root(E(self, C.panel(268.0), null, "settingsPanel"))
	settings_panel = p
	_panel_head(p, "Settings", "settingsPanel")
	var tabsrow := E(p, {"display": "flex", "gapc": 4.0, "mb": 10.0}, null, "setTabs")
	for t in [["sky", "Sky"], ["render", "Render"], ["sim", "Sim"]]:
		var b := B(tabsrow, C.set_tab(), t[1], "[data-set=%s]" % t[0],
			[["hover", {"c": T.TEXT}], ["on", C.SET_TAB_ON]])
		b.pressed.connect(func(): set_settings_page(t[0]))

	# SKY
	var sky := E(p, {})
	sky.set_meta("page", "sky")
	_note(sky, [_t("Where you are looking from. The environments are POPULATIONS and they superpose — a globular cluster still has the galaxy behind it — so the weights add rather than crossfade. Shape (band thickness, bulge size, plane concentration) is the one galaxy you are in, so those take the weighted mean instead.")])
	E(sky, {}, null, "skyEnvList")
	_set_row(sky, "skyTilt", "Plane tilt", "Tilt of the galactic plane relative to the scene. This places your VIEW of the galaxy, not you.",
		0, 1.57, 0.34, 0.01, "0.34", func(v): return U.fixed(v, 2))
	_set_row(sky, "skyRoll", "Plane roll", "Roll about the vertical. Swings the band round the horizon.",
		0, 6.28, 0.9, 0.01, "0.90", func(v): return U.fixed(v, 2))
	var adv_btn := B(sky, C.ghost_btn(), "Component amplitudes ▸", "skyAdvOpen", [["hover", C.GHOST_HOVER]])
	var adv := E(sky, {}, null, "skyAdv")
	_hide(adv, "inline", true)
	adv_btn.pressed.connect(func():
		var open := not adv.visible
		_hide(adv, "inline", not open)
		adv_btn.set_text("Component amplitudes ▾" if open else "Component amplitudes ▸"))
	B(sky, C.ghost_btn(), "Reset to scenario’s sky", "skyReset", [["hover", C.GHOST_HOVER]]).pressed.connect(func(): sky_reset.emit())

	# RENDER
	var ren := E(p, {})
	ren.set_meta("page", "render")
	_note(ren, [_t("Every heavy pass here is fullscreen, so the top two sliders multiply the whole frame cost. Bloom is the instrument’s point-spread function and runs after the spectral remap, which is why it spreads what the band actually images rather than what the eye would see.")])
	_set_row(ren, "renderScale", "Render scale", "Framebuffer scale. Every heavy pass here is fullscreen, so this multiplies the whole frame cost — 1.5x is 2.25x the pixels of 1.0x. Turn it up for screenshots, down for frame rate.",
		0.5, 2, 1, 0.05, "1.00x", func(v): return U.fixed(minf(_dpr(), v), 2) + "x")
	_set_row(ren, "lensScale", "Lens detail", "Resolution of the geodesic marcher, as a fraction of the display. The star field is always evaluated at full resolution, so this trades sharpness of the disc and the shadow edge — not the stars — for a large amount of frame time.",
		0.25, 1, 0.5, 0.05, "0.50x", func(v): return U.fixed(v, 2) + "x")
	_set_row(ren, "fxBloom", "Bloom", "Strength of the bloom added back over the frame.", 0, 1.2, 0.55, 0.01, "0.55", func(v): return U.fixed(v, 2))
	_set_row(ren, "fxThreshold", "Bloom threshold", "Luminance above which a pixel blooms. Lower catches more of the frame; the knee keeps the transition soft.", 0, 4, 1, 0.05, "1.00", func(v): return U.fixed(v, 2))
	_set_row(ren, "fxRadius", "Bloom radius", "Spread of the upsample filter — how far the glow reaches.", 0.2, 2.5, 1, 0.05, "1.00", func(v): return U.fixed(v, 2))
	_set_row(ren, "fxVignette", "Vignette", "Corner falloff. An instrument artefact, not a physical one.", 0, 1, 0.35, 0.01, "0.35", func(v): return U.fixed(v, 2))
	_set_row(ren, "fxGrain", "Grain", "Sensor grain. Breaks up the banding a smooth HDR gradient shows on an 8-bit display.", 0, 0.1, 0.02, 0.002, "0.020", func(v): return U.fixed(v, 3))
	B(ren, C.ghost_btn(), "Reset rendering", "fxReset", [["hover", C.GHOST_HOVER]]).pressed.connect(func(): fx_reset.emit())

	# SIM
	var sim := E(p, {})
	sim.set_meta("page", "sim")
	_note(sim, [_t("The integrator is velocity-Verlet in AU, M"), _t("☉", {"sub": true, "fs": 7.917}), _t(" and years with "),
		_t("G", {"fi": true}), _t(" = 4π². The step cap is the one setting that changes the ANSWER rather than the picture: a close pass is only resolved if the step is short compared with the time spent in it.")])
	_set_row(sim, "maxStep", "Max step", "Longest integrator step, in years. Lower is more accurate and slower; too high and a close encounter is stepped straight over, which shows up as energy appearing from nowhere.",
		-5, -1, -2.3, 0.05, "5.0e-3 yr", func(v): return U.expo(pow(10.0, v), 1) + " yr")
	_set_row(sim, "gwBoost", "GW boost", "Multiplier on the gravitational-wave radiation reaction. 1 is the real rate; presets raise it so an inspiral that truly takes megayears is watchable. 0 turns the back-reaction off entirely.",
		0, 6, 0, 0.05, "off", func(v): return (U.fixed(v, 2) + "×") if v != 0.0 else "off")
	var sg := E(sim, C.merge(C.STAT_GRID, {"mt": 10.0}))
	for kv in [["steps/frame", "setSteps"], ["energy drift", "setDrift"]]:
		var cell := E(sg, C.STAT_CELL)
		E(cell, C.STAT_K, kv[0])
		E(cell, C.STAT_V, "—", kv[1], [["warn", {"c": T.WARN}]])
	_note(sim, [_t("Drift is the relative change in total energy since the scenario loaded. It is the honest measure of whether the step is short enough: a stable hierarchy holds ~1e-7 over tens of thousands of years, and a number climbing through 1e-3 means the cap is too long for what the bodies are currently doing.")])
	B(sim, C.ghost_btn(), "Reset to scenario’s values", "simReset", [["hover", C.GHOST_HOVER]]).pressed.connect(func(): sim_reset.emit())
	set_settings_page("sky")

## Settings is three pages rather than one long stack: the three groups are
## consulted at different times — sky when composing a shot, render when the
## frame rate is wrong, sim when a result looks wrong.
func set_settings_page(page: String) -> void:
	for k in settings_panel.get_children():
		if k is El and k.has_meta("page"):
			_hide(k, "inline", k.get_meta("page") != page)
	for t in ["sky", "render", "sim"]:
		for b in sels.get("[data-set=%s]" % t, []):
			b.set_state("on", t == page)

func _dpr() -> float:
	return get_window().content_scale_factor if is_inside_tree() else 1.0

# ---- SCENARIO -----------------------------------------------------------------------------
var _search: TextField
var _search_clear: El
var _preset_list: El
var _preset_empty: El

func _build_scenario() -> void:
	var p := root(E(self, C.panel(232.0), null, "scenarioPanel"))
	scenario_panel = p
	_panel_head(p, "Scenario", "scenarioPanel")
	E(p, {"fs": 12.0, "c": T.TEXT, "ls": C.em(0.04, 12), "mt": -4.0, "mb": 9.0, "pb": 8.0, "bb": 1.0, "bcb": T.BORDER},
		"Black Hole Sandbox", "presetName")
	var ps := E(p, {"mb": 10.0})
	_search = TextField.new({"b": [1, T.BORDER], "bg": T.rgba(0, 0, 0, 0.18), "p": [8, 28, 8, 9], "fs": 10.0,
		"ls": C.em(0.04, 10), "c": T.TEXT},
		[["focus", {"bcol": T.ACCENT_2, "outline_ring": 1.0, "ring": T.rgba(78, 168, 255, 0.14)}]],
		"Search scenarios / categories")
	ps.add_child(_search)
	reg("presetSearch", _search)
	_search.text_changed.connect(func(_t): _render_presets())
	_search_clear = B(_search, C.button({"bg": T.CLEAR, "b": [0, T.CLEAR], "c": T.TEXT_DIM, "ff": "mono", "fs": 10.0,
		"lh": 1.0, "p": 3}), "✕", "presetSearchClear", [["hover", {"c": T.TEXT}]])
	_search_clear.set_meta("abs", true)
	_search_clear.pressed.connect(func():
		_search.edit.text = ""
		_render_presets()
		_search.edit.grab_focus())
	_preset_list = E(p, {"display": "grid", "cols": [1.0], "gapr": 5.0}, null, "presetList")
	_preset_empty = E(p, {"p": [10, 8], "b": [1, T.BORDER], "c": T.TEXT_DIM, "fs": 10.0, "ta": "center", "fi": true},
		"No matching scenarios", "presetEmpty")
	_hide(_preset_empty, "inline", true)
	E(p, {"mt": 9.0, "fs": 10.0, "lh": 1.55, "c": T.TEXT_DIM, "bl": 2.0, "bcl": T.ACCENT_2, "pl": 8.0}, "", "blurb")

# ---- COURSE -------------------------------------------------------------------------------
func _build_course() -> void:
	var p := root(E(self, C.panel(250.0), null, "coursePanel"))
	course_panel = p
	_panel_head(p, "Course", "coursePanel")
	_mounts["courseMount"] = E(p, {}, null, "courseMount")

# ---- the LESSON CARD frame ----------------------------------------------------------------
func _build_lesson_card() -> void:
	var c := root(E(self, {"bg": T.PANEL, "b": [1, T.BORDER_STRONG], "blur": 12.0, "p": [13, 15, 11, 15],
		"display": "flex", "dir": "column", "gapr": 9.0}, null, "lessonCard"))
	lesson_card = c
	var head := E(c, {"display": "flex", "ai": "baseline", "gapc": 10.0})
	lc.crumb = E(head, {"grow": 1.0, "basis": 0.0, "minw": 0.0, "fs": 10.0, "c": T.ACCENT, "ls": C.em(0.05, 10), "up": true}, "")
	lc.count = E(head, {"fs": 10.0, "c": T.TEXT_DIM}, "")
	lc.close = B(head, C.panel_close(), "✕", "", [["hover", C.PANEL_CLOSE_HOVER]], "Leave this lesson")
	lc.close.pressed.connect(func(): lesson_close.emit())
	# Text FIRST, instrument second: when the card is too narrow the row wraps,
	# and the half that ends up on top is the half you have to read.
	lc.cols = E(c, {"display": "flex", "wrap": true, "gapc": 15.0, "gapr": 15.0, "scroll": true, "sbw": 4.0})
	lc.main = E(lc.cols, {"grow": 3.0, "shrink": 1.0, "basis": 260.0, "minw": 0.0})
	lc.title = E(lc.main, {"ff": "disp", "fs": 16.0, "fw": 600, "c": T.hexc(0xe6ecf6), "mb": 7.0}, "")
	# The one place in this HUD that is prose: the display face, a real line
	# height, and a 68-character measure.
	lc.text = E(lc.main, {"ff": "disp", "fs": 13.5, "lh": 1.62, "c": T.TEXT, "maxw": 68 * 13.5 * 0.5})
	lc.media = E(lc.cols, {"grow": 1.0, "shrink": 1.0, "basis": 240.0, "minw": 170.0})
	_hide(lc.media, "inline", true)
	var foot := E(c, {"display": "flex", "ai": "center", "gapc": 12.0})
	lc.back = B(foot, C.lc_nav(), "← Back", "", [["hover", {"bcol": T.ACCENT, "c": T.ACCENT}], ["disabled", {"op": 0.3}]])
	lc.back.pressed.connect(func(): lesson_back.emit())
	lc.dots = E(foot, {"grow": 1.0, "display": "flex", "gapc": 5.0, "ai": "center"})
	lc.next = B(foot, C.merge(C.lc_nav(), {"bg": T.ACCENT, "c": T.hexc(0x0a0c12), "bcol": T.ACCENT}), "Next →")
	lc.next.pressed.connect(func(): lesson_next.emit())
	_mounts["lessonCard"] = c
	_hide(c, "inline", true)

## Show the card with an instrument column (`.lesson-card.has-media`) or not.
func set_lesson_media(on: bool) -> void:
	_hide(lc.media, "inline", not on)

## Rebuild the step dots: n of them, `seen` up to and `on` at index i.
func set_lesson_dots(n: int, i: int, seen: int) -> void:
	lc.dots.touch()
	for k in lc.dots.get_children():
		lc.dots.remove_child(k)
		k.queue_free()
	for d in n:
		var dot := E(lc.dots, {"w": 7.0, "h": 7.0, "b": [1, T.BORDER_STRONG], "rad": 3.5},
			null, "", [["seen", {"bg": T.rgba(180, 200, 230, 0.35)}], ["on", {"bg": T.ACCENT, "bcol": T.ACCENT}]])
		dot.set_state("seen", d <= seen)
		dot.set_state("on", d == i)
		dot.make_clickable()

# ---- CONTROLS -------------------------------------------------------------------------------
func _section(parent: El, title: String, head_runs: Array = [], host: El = null) -> El:
	# groupControlSections: the heading gains an arrow and a click, and
	# everything under it moves into a body that folds.
	var head := E(host if host else parent, C.merge(C.h3(host != null), {"display": "flex", "ai": "baseline", "gapc": 6.0}),
		null, "", [["hover", {"c": T.ACCENT}]])
	head.make_hoverable()
	head.mouse_filter = Control.MOUSE_FILTER_PASS
	head.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var arrow := E(head, {"fs": 9.0, "c": T.TEXT_DIM, "rot": 90.0}, "▸")
	var tl := E(head, {}, title)
	for r in head_runs:
		head.add_child(r)
	var wrap := E(host if host else parent, {})
	var sec := {"title": title, "head": head, "wrap": wrap, "host": host, "arrow": arrow, "label": tl}
	sections.append(sec)
	head.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			head.accept_event()
			if not e.pressed:
				set_section_open(sec, not sec.open))
	sec.open = true
	return wrap

func set_section_open(sec: Dictionary, open: bool) -> void:
	sec.open = open
	_hide(sec.wrap, "closed", not open)
	var a: El = sec.arrow
	var tw := create_tween()
	tw.tween_method(func(v): a.set_style({"rot": v}), float(a.g("rot")), 90.0 if open else 0.0, 0.16)

func section(title: String) -> Dictionary:
	for s in sections:
		if s.title == title:
			return s
	return {}

## applySectionModes: a CLASS, not an inline display — the climate block and
## the focused-object block drive their own display, and whichever of two
## writers wrote last would win.
func apply_section_modes(mode: String) -> void:
	# Learn mode is the sandbox with a course over it, and the lessons send you
	# to these controls by name, so it gets the sandbox's sections; only what it
	# opens BY DEFAULT differs.
	var effective := "sandbox" if mode == "learn" else mode
	for sec in sections:
		var want: String = SECTION_MODE.get(sec.title, "both")
		var show := want == "both" or want == effective
		var host: El = sec.host if sec.host else sec.head
		_hide(host, "mode", not show)
		if not sec.host:
			_hide(sec.wrap, "mode", not show)
		if show:
			set_section_open(sec, (OPEN_BY_DEFAULT.get(mode, []) as Array).has(sec.title))

func _build_control_panel() -> void:
	var p := root(E(self, C.panel(300.0), null, "controlPanel"))
	control_panel = p
	var maxh_note := p
	_panel_head(p, "Controls", "controlPanel")

	# Central Singularity
	var s := _section(p, "Central Singularity")
	reg("bhPanel", sections[-1].head)
	_row(s, "mass", "Mass (M☉)", "", 1, 50, 10, 0.1, "10.0", "massRow", func(v): return U.fixed(v, 1))
	_row(s, "disc", "Accretion Disc", "", 0, 1, 0.9, 0.01, "0.90", "discRow", func(v): return U.fixed(v, 2))
	_row(s, "temp", "Disc Temp", "", 0, 1, 0.6, 0.01, "0.60", "tempRow", func(v): return U.fixed(v, 2))

	# Suns
	s = _section(p, "Suns")
	reg("starPanel", sections[-1].head)
	E(s, {"display": "flex", "dir": "column", "gapr": 6.0, "mb": 14.0}, null, "sunList")

	# Climate — a self-contained block: its own div, heading first
	var cp := E(p, {}, null, "climatePanel")
	var clock := E(null if false else self, {"c": T.ACCENT_2, "fw": 400, "ls": C.em(0.05, 10)}, "0 yr", "simClock")
	remove_child(clock)
	s = _section(p, "Climate", [clock], cp)
	E(s, {"ta": "center", "p": 7, "mb": 4.0, "fs": 12.0, "ls": C.em(0.18, 12), "up": true, "b": [1, HudCss.ERA["era-stable"].c],
		"c": HudCss.ERA["era-stable"].c}, "Stable Era", "eraBadge")
	E(s, {"fs": 10.0, "c": T.TEXT_DIM, "lh": 1.5, "mb": 10.0}, "", "eraDesc")
	var chart := ClimateChart.new()
	s.add_child(chart)
	reg("climateChart", chart)
	var key := E(s, {"display": "flex", "gapc": 12.0, "mt": 5.0, "mb": 10.0, "fs": 9.0, "c": T.TEXT_DIM})
	for kk in [[T.hexc(0xff6a5a), "surface temp"], [T.rgba(255, 190, 90, 0.8), "insolation"]]:
		var item := _Swatch.new({"pl": 13.0}, kk[0])
		item.runs = [{"t": kk[1]}]
		key.add_child(item)
	var sg := E(s, C.STAT_GRID)
	for kv in [["temp", "cTemp"], ["flux", "cFlux"], ["ice", "cIce"], ["cloud", "cCloud"], ["τ response", "cTau"], ["range", "cExtremes"]]:
		var cell := E(sg, C.STAT_CELL)
		E(cell, C.STAT_K, kv[0])
		E(cell, C.STAT_V, "—", kv[1])
	_row(s, "mixed", "Ocean depth", "Depth of the ocean mixed layer — the planet's thermal flywheel. Shallow oceans let the temperature whip around with the orbit; deep ones damp it.",
		2, 120, 12, 1, "12 m", "", func(v): return U.fixed(v, 0) + " m")
	_row(s, "greenhouse", "Greenhouse ε", "Effective emissivity. Lower = stronger greenhouse = warmer world. 0.61 reproduces Earth.",
		0.3, 1, 0.61, 0.01, "0.61", "", func(v): return U.fixed(v, 2))
	B(s, C.ghost_btn(), "Reset Climate to 15 °C", "climateReset", [["hover", C.GHOST_HOVER]]).pressed.connect(func(): climate_reset.emit())
	_hide(cp, "inline", true)

	# Imaging Band
	s = _section(p, "Imaging Band")
	E(s, {"display": "grid", "cols": [1.0, 1.0, 1.0, 1.0], "gapc": 4.0, "gapr": 4.0}, null, "bandGrid")
	E(s, {"mt": 8.0, "fs": 9.5, "lh": 1.55, "c": T.TEXT_DIM, "bl": 2.0, "bcl": T.BORDER_STRONG, "pl": 8.0}, "", "bandNote")

	# View & Camera
	s = _section(p, "View & Camera")
	var tvars := [["hover", C.TOGGLE_HOVER], ["active", C.TOGGLE_ACTIVE]]
	var tr := E(s, C.TOGGLE_ROW)
	for v in [["mesh", "Mesh ON"], ["lens", "Lens ON"]]:
		var b := B(tr, C.toggle_btn(), v[1], "[data-view=%s]" % v[0], tvars)
		b.set_state("active", true)
		b.pressed.connect(func(): view_toggle.emit(v[0]))
	tr = E(s, C.TOGGLE_ROW)
	B(tr, C.toggle_btn(), "Sizes: Boosted", "[data-view=scale]", tvars,
		"Real: bodies are drawn at their true physical radius, so a planet is a point of light until you fly to it. Boosted: radii are exaggerated so the system is readable at a glance.").pressed.connect(func(): view_toggle.emit("scale"))
	tr = E(s, C.TOGGLE_ROW)
	var bo := B(tr, C.toggle_btn(), "Orbit", "camOrbit", tvars)
	bo.set_state("active", true)
	bo.pressed.connect(func(): cam_mode.emit("orbit"))
	B(tr, C.toggle_btn(), "Free Fly", "camFree", tvars).pressed.connect(func(): cam_mode.emit("free"))
	var bs := B(tr, C.toggle_btn(), "Stand on it", "camSurface", tvars)
	bs.pressed.connect(func(): cam_mode.emit("surface"))
	_hide(bs, "inline", true)
	B(s, C.ghost_btn(), "Reset View", "resetView", [["hover", C.GHOST_HOVER]]).pressed.connect(func(): reset_view.emit())
	_note(s, [_t("Render scale and lens detail moved to "), _t("Settings › Render", {"fw": 700}),
		_t(", top left — they are properties of the renderer rather than of this view, and they survive a scenario change.")])
	var sky_row := E(s, {}, null, "skyRow")
	_row(sky_row, "lat", "Latitude", "Where on the planet you are standing. High latitudes see the suns skim the horizon.",
		-80, 80, 22, 1, "22°", "", func(v): return str(int(U.jround(v))) + "°")
	_row(sky_row, "daylen", "Day length", "Length of the planet's rotation period. Shorter = the suns race across the sky.",
		0.5, 30, 4.06, 0.1, "4.1 d", "", func(v): return U.fixed(v, 1) + " d")
	_hide(sky_row, "inline", true)

	# Time
	s = _section(p, "Time")
	var tg := E(s, {"display": "grid", "cols": [1.0, 1.0, 1.0, 1.0], "gapc": 4.0, "gapr": 4.0, "mb": 12.0})
	for t in [["sunset", "Sunset", "A single sunset, at a watchable pace. One rotation ≈ 45 s."],
			["day", "Days", "Days flick past. One rotation ≈ 8 s."],
			["season", "Seasons", "One orbit ≈ 90 s — watch a Chaotic Era arrive."],
			["era", "Eras", "Centuries per minute — the long climate record."]]:
		B(tg, C.time_btn(), t[1], "[data-time=%s]" % t[0], [["hover", C.TOGGLE_HOVER], ["active", C.BLUE_ACTIVE]], t[2]) \
			.pressed.connect(func(): time_regime.emit(t[0]))
	_row(s, "timescale", "Time scale", "Simulated years per real second.", -5, 1.3, -0.46, 0.01, "0.35 yr/s", "",
		func(v): return time_label(clampf(pow(10.0, v), 1e-5, 20.0)))
	_row(s, "speed", "Sim Speed", "", 0, 4, 1, 0.05, "1.00", "", func(v): return U.fixed(v, 2))

	# Focused Object — self-contained
	var fp := E(p, {"mt": 18.0, "b": [1, T.ACCENT_2], "p": 10}, null, "focusPanel")
	s = _section(p, "Focused Object", [], fp)
	sections[-1].head.set_style({"c": T.ACCENT_2, "mb": 8.0})
	E(s, {"fs": 11.0, "c": T.TEXT, "mb": 8.0, "ls": C.em(0.05, 11)}, "—", "focusName")
	B(s, C.ghost_btn(), "Cross-section & edit ▸", "xsecOpen", [["hover", C.GHOST_HOVER]]).pressed.connect(func(): xsec_open.emit())
	B(s, C.merge(C.action_btn(), {"mt": 0.0}), "Delete Object", "delFocus", [["hover", C.ACTION_HOVER]]).pressed.connect(func(): delete_focus.emit())
	_hide(fp, "inline", true)

	# Object Foundry
	s = _section(p, "Object Foundry")
	_note(s, [_t("Four inputs, no menu of outcomes. Everything below — the size, the colour, the shape, the verdict — is derived from mass, spin, composition and age by the same interior model the rest of the sim runs on.")])
	_mounts["foundry"] = E(s, {}, null, "foundry")

	# Painter
	s = _section(p, "Painter")
	_note(s, [_t("Adds the things that are made of too many pieces to integrate — rings, belts, ejecta. They are test particles on real Keplerian orbits, so a ring shears the way a ring does and a belt has its resonance gaps. Acts on the focused body.")])
	var ag := E(s, {"display": "grid", "cols": [1.0, 1.0], "gapc": 6.0, "gapr": 6.0})
	for pt in [["ring", "◎", "Ring", "A ring can only exist INSIDE the Roche limit, where tides beat self-gravity and the material cannot collect into a moon. The span is computed from the body's own density, not chosen."],
			["belt", "⋰", "Belt", "An asteroid belt, with Kirkwood gaps cleared at the 3:1, 5:2, 7:3 and 2:1 resonances with the next body out."],
			["cloud", "◍", "Ejecta", "An expanding shell of ejecta. Optically thin, so it limb-brightens into a rim, and homologous, so it expands without changing shape."],
			["clear", "✕", "Clear paint", ""]]:
		var b := _add_btn(ag, pt[1], pt[2], "[data-paint=%s]" % pt[0], pt[3])
		b.pressed.connect(func(): paint.emit(pt[0]))

	# Spaceflight
	s = _section(p, "Spaceflight")
	_note(s, [_t("Real vehicles, real stage masses, real engines. A stage's Δv is computed from its own dry and propellant mass, so if a rocket cannot reach orbit here it could not reach orbit. Time runs "),
		_t("1:1", {"fw": 700}), _t(" — one second per second — until you warp it yourself.")])
	E(s, {"display": "grid", "cols": [1.0, 1.0], "gapc": 5.0, "gapr": 5.0, "m": [8, 0, 4, 0]}, null, "craftGrid")
	B(s, C.ghost_btn(), "Model viewer ▸", "modelOpen", [["hover", C.GHOST_HOVER]]).pressed.connect(func(): model_open.emit())
	var fr := E(s, C.TOGGLE_ROW, null, "flightRow")
	B(fr, C.toggle_btn(), "Cam: Chase", "flightCam", tvars, "Chase · Orbit · Cockpit · Pad").pressed.connect(func(): flight_cam_cycle.emit())
	B(fr, C.toggle_btn(), "Exit flight", "flightExit", tvars).pressed.connect(func(): flight_exit.emit())
	_hide(fr, "inline", true)

	# Quick Spawn
	s = _section(p, "Quick Spawn")
	tr = E(s, C.TOGGLE_ROW)
	B(tr, C.toggle_btn(), "Spawn: In orbit", "[data-view=spawnrest]", tvars,
		"At rest: a new body is placed where you are looking with exactly zero velocity, and only moves if gravity moves it. In orbit: it arrives on a circular orbit about the heaviest body present, which is the only start that does not immediately fall in.") \
		.pressed.connect(func(): view_toggle.emit("spawnrest"))
	ag = E(s, {"display": "grid", "cols": [1.0, 1.0], "gapc": 6.0, "gapr": 6.0})
	for sp in [["planet", "·", "Rocky Planet"], ["gas-giant", "○", "Gas Giant"], ["star", "☉", "Star"], ["neutron", "◉", "Neutron Star"]]:
		_add_btn(ag, sp[1], sp[2], "[data-spawn=%s]" % sp[0]).pressed.connect(func(): spawn.emit(sp[0]))
	B(s, C.action_btn(), "Clear All Bodies", "clear", [["hover", C.ACTION_HOVER]]).pressed.connect(func(): clear_bodies.emit())

	# Bodies
	var count := E(self, {"c": T.ACCENT}, "(0)", "count")
	remove_child(count)
	s = _section(p, "Bodies", [count])
	E(s, {"maxh": 150.0, "scroll": true, "sbw": 3.0, "b": [1, T.BORDER]}, null, "bodyList")
	render_body_list([], -1)

func _add_btn(parent: El, sym: String, label: String, sel: String, tip := "") -> El:
	var b := B(parent, C.add_btn(), null, sel, [["hover", C.ADD_HOVER]], tip)
	E(b, {"fs": 16.0, "c": T.ACCENT}, sym)
	E(b, {}, label)
	return b

## A .chart-key entry: the 9 × 2 swatch (vertical-align: middle) and a label.
class _Swatch extends El:
	var sw: Color
	func _init(style: Dictionary, col: Color) -> void:
		super(style)
		sw = col
	func _draw_extra() -> void:
		if _lines.is_empty():
			return
		var fs := gf("fs")
		var xh := 0.53 * fs          # Menlo's x-height
		var by: float = gf("pt") + _lines[0].top + _lines[0].base
		draw_rect(_snap(Rect2(0, by - xh * 0.5 - 1.0, 9, 2)), sw)

# ---- MODEL VIEWER -------------------------------------------------------------------------
func _build_model_panel() -> void:
	var p := root(E(self, C.panel(268.0), null, "modelPanel"))
	model_panel = p
	_panel_head(p, "Model viewer", "modelPanel", "Close")
	reg("modelClose", p.get_child(0).get_child(1))
	E(p, {"fs": 14.0, "c": T.ACCENT, "mb": 10.0, "ls": C.em(0.04, 14)}, "—", "mvName")
	E(p, {"display": "grid", "cols": [1.0, 1.0], "gapc": 4.0, "gapr": 4.0, "mb": 12.0}, null, "mvGrid")
	var mc := E(p, {"bt": 1.0, "bct": T.BORDER, "pt": 10.0, "mb": 10.0})
	var sl := E(mc, {"display": "flex", "ai": "center", "gapc": 8.0, "fs": 10.0, "c": T.TEXT_DIM, "mb": 8.0})
	E(sl, {"minw": 62.0}, "Exploded")
	_range(sl, "mvExplode", {"grow": 1.0, "shrink": 1.0, "basis": 0.0, "m": 2}, 0, 1, 0, 0.01)
	var tr := E(mc, C.TOGGLE_ROW)
	var tvars := [["hover", C.TOGGLE_HOVER], ["active", C.TOGGLE_ACTIVE]]
	# `.toggle-btn.on` has no rule in the stylesheet: the page marks these two
	# with `on`, and they look the same either way. Faithfully so here.
	tvars = [["hover", C.TOGGLE_HOVER], ["on", {}]]
	var dep := B(tr, C.toggle_btn(), "Deployed", "mvDeploy", tvars, "Legs, fins, arrays and radiators in their deployed position")
	dep.set_state("on", true)
	dep.pressed.connect(func():
		dep.set_state("on", not dep.has_state("on"))
		model_deploy.emit(dep.has_state("on")))
	var spin := B(tr, C.toggle_btn(), "Turntable", "mvSpin", tvars, "Idle turntable")
	spin.pressed.connect(func():
		spin.set_state("on", not spin.has_state("on"))
		model_spin.emit(spin.has_state("on")))
	E(p, {"display": "grid", "cols": [1.0, 1.0], "gapr": 3.0, "gapc": 10.0, "mb": 12.0}, null, "mvList")
	E(p, {}, null, "mvStages")
	B(p, C.action_btn(), "Fly this vehicle", "mvFly", [["hover", C.ACTION_HOVER]]).pressed.connect(func(): model_fly.emit())
	_hide(p, "inline", true)

# ---- CROSS-SECTION frame ----------------------------------------------------------------------
func _build_xsec_panel() -> void:
	var p := root(E(self, C.panel(348.0), null, "xsecPanel"))
	xsec_panel = p
	_panel_head(p, "Cross-section", "xsecPanel", "Close")
	E(p, {"fs": 11.0, "c": T.ACCENT, "ls": C.em(0.08, 11), "mb": 8.0, "up": true}, "—", "xsecName")
	var ed := E(p, {"b": [1, T.BORDER], "bl": 2.0, "bcl": T.ACCENT, "bg": Color(1, 1, 1, 0.02), "p": [9, 10, 2, 10], "mb": 10.0}, null, "xsecEdit")
	_note(ed, [_t("Editing is the same operation as building — the object is re-derived and its limits rechecked immediately. The curve is R(M) for this body's own composition and spin; drag the handle along it. Dashed lines are where the model changes its mind about what this is.")], {"mb": 9.0})
	_mounts["liveEdit"] = E(ed, {}, null, "liveEdit")
	# the two canvases: width 100%, height auto, so their height follows the
	# bitmap's aspect (330 × 260 and 330 × 26)
	_mounts["xsecCanvas"] = E(p, {"aspect": 260.0 / 330.0, "b": [1, T.BORDER], "bg": T.rgba(0, 0, 0, 0.42)}, null, "xsecCanvas")
	_mounts["xsecLegend"] = E(p, {"aspect": 26.0 / 330.0, "m": [4, 0, 8, 0]}, null, "xsecLegend")
	_mounts["xsecVerdict"] = E(p, {}, null, "xsecVerdict")
	_mounts["xsecFacts"] = E(p, {}, null, "xsecFacts")
	_mounts["xsecNotes"] = E(p, {}, null, "xsecNotes")

# ---- FLIGHT frame -----------------------------------------------------------------------------
func _build_flight_panel() -> void:
	var p := root(E(self, C.panel(306.0), null, "flightPanel"))
	flight_panel = p
	var head := E(p, C.PANEL_HEAD)
	E(head, C.merge(C.h3(true), {"grow": 1.0, "basis": 0.0, "minw": 0.0}), "Flight")
	var warp := E(head, {"display": "flex", "ai": "center", "gapc": 4.0, "mlauto": true, "mr": 6.0})
	B(warp, C.merge(C.warp_btn(), {"ff": "lucida"}), "◂", "[data-warp=-1]", [["hover", {"bcol": T.ACCENT}]], "Slow time (,)").pressed.connect(func(): warp_step.emit(-1))
	E(warp, {"fs": 11.0, "c": T.ACCENT, "minw": 46.0, "ta": "center"}, "1×", "warpLabel")
	B(warp, C.merge(C.warp_btn(), {"ff": "lucida"}), "▸", "[data-warp=1]", [["hover", {"bcol": T.ACCENT}]], "Speed time (.)").pressed.connect(func(): warp_step.emit(1))
	B(head, C.panel_close(), "✕", "", [["hover", C.PANEL_CLOSE_HOVER]], "Collapse").pressed.connect(func(): set_panel_open("flightPanel", false))
	_mounts["flightHud"] = E(p, {}, null, "flightHud")

# ---- tabs ------------------------------------------------------------------------------------
func _build_tabs() -> void:
	tab_col = root(E(self, {"display": "flex", "dir": "column", "ai": "start", "gapr": 6.0}))
	for t in [["settingsPanel", "▸ Settings"], ["scenarioPanel", "▸ Scenario"], ["coursePanel", "▸ Course"], ["flightPanel", "▸ Flight"]]:
		var b := B(tab_col, C.panel_tab(), t[1], "[data-open=%s]" % t[0], [["hover", C.PANEL_TAB_HOVER]])
		b.pressed.connect(func(): set_panel_open(t[0], true))
		tabs[t[0]] = b
		_hide(b, "inline", true)
	tab_right = root(B(self, C.panel_tab(), "Controls ◂", "[data-open=controlPanel]", [["hover", C.PANEL_TAB_HOVER]]))
	tab_right.pressed.connect(func(): set_panel_open("controlPanel", true))
	tabs["controlPanel"] = tab_right
	_hide(tab_right, "inline", true)

# ---- readout & hint ---------------------------------------------------------------------------
func _build_readout() -> void:
	readout = root(E(self, {"fs": 10.0, "c": T.TEXT_DIM, "lh": 1.7, "ls": C.em(0.08, 10)}, null, "readout"))
	var v := {"c": T.ACCENT_2}
	_rich(readout, [_t("band"), _t(" "), _t("VIS", C.merge(v, {"id": "bandLabel"})), _t(" · "), _t("0.00", C.merge(v, {"id": "rs"})),
		_t(" r_s AU · ISCO "), _t("0.00", C.merge(v, {"id": "isco"}))])
	_rich(readout, [_t("bodies "), _t("0", C.merge(v, {"id": "bc"})), _t(" consumed "), _t("0", C.merge(v, {"id": "cc"}))])
	_rich(readout, [_t("fps "), _t("--", C.merge(v, {"id": "fps"}))])

func _rich(parent: El, runs: Array, style := {}) -> El:
	var e := E(parent, style, runs)
	for r in runs:
		if r.has("id"):
			run_ids[r.id] = [e, r]
	return e

func _build_hint() -> void:
	hint = root(E(self, {"fs": 10.0, "c": T.TEXT_DIM, "ta": "right", "lh": 1.6, "ls": C.em(0.08, 10)}, null, "hint"))
	_hint_runs()

const KBD := {"pt": 1, "pb": 1, "pl": 5, "pr": 5, "bw": 1, "bc": HudTheme.BORDER_STRONG, "ml": 2, "mr": 2}

func _k(t: String, cls := "") -> Dictionary:
	return {"t": t, "box": KBD, "fs": 9.0, "c": T.TEXT, "cls": cls}

## Key hints, split by mode: a key that does nothing here is not a hint.
func _hint_runs() -> void:
	var fl := body.has("flight-mode")
	var sb := not fl
	var r: Array = []
	r.append_array([_k("drag"), _t(" look · "), _k("scroll"), _t(" zoom/speed · "), _k("click"), _t(" focus object"), {"br": true}])
	if sb:
		r.append_array([_k("V"), _t(" stand on the planet · "), _k("F"), _t(" free cam · "), _k("WASD"), _t(" fly"), {"br": true}])
	r.append_array([_k("R"), _t(" reset · "), _k("space"), _t(" pause")])
	if sb:
		r.append_array([_t(" · "), _k("del"), _t(" remove")])
	r.append({"br": true})
	r.append_array([_k("H"), _t(" hide all panels")])
	if sb:
		r.append_array([_t(" · "), _k("1"), _t("–"), _k("7"), _t(" imaging band")])
	if fl:
		var c := {"c": T.hexc(0x7d93ae)}
		r.append_array([{"br": true}, _k("Z"), _t("/", c), _k("X"), _t(" full/cut throttle · ", c), _k("shift+space"), _t(" stage · ", c),
			_k(","), _t("/", c), _k("."), _t(" time warp · ", c), _k("C"), _t(" flight camera", c)])
	hint.set_runs(r)

# ---- START SCREEN -----------------------------------------------------------------------------
class _StartEl extends El:
	func _blur_extra(m: ShaderMaterial) -> void:
		m.set_shader_parameter("mode", 1)
		m.set_shader_parameter("inner", Color(14 / 255.0, 18 / 255.0, 28 / 255.0, 0.90))
		m.set_shader_parameter("outer", Color(4 / 255.0, 5 / 255.0, 9 / 255.0, 0.985))
		m.set_shader_parameter("centre", Vector2(0.5, 0.4))
		# radial-gradient(120% 90% at 50% 40%) — the ellipse's radii
		m.set_shader_parameter("radii", Vector2(1.2, 0.9))

func _build_start() -> void:
	start_screen = _StartEl.new({"blur": 3.0, "bg": T.rgba(4, 5, 9, 0.95)})
	add_child(start_screen)
	reg("startScreen", start_screen)
	root(start_screen)
	start_screen.mouse_filter = Control.MOUSE_FILTER_STOP
	var inner := E(start_screen, {"ta": "center"})
	inner.set_meta("inner", true)
	E(inner, {"fs": 10.0, "ls": C.em(0.42, 10), "c": T.TEXT_DIM}, "ASTRARIUM")
	E(inner, {"ff": "disp", "fw": 300, "fs": 30.0, "lh": 1.28, "m": [14, 0, 12, 0], "ls": C.em(0.01, 30), "c": T.hexc(0xdfe6f0)},
		[_t("A relativistic orrery"), {"br": true}, _t("and a spaceflight simulator")])
	E(inner, {"fs": 12.0, "lh": 1.7, "c": T.TEXT_DIM, "maxw": 620.0, "mauto": true, "mb": 30.0},
		[_t("Real gravity in AU, M"), _t("☉", {"sub": true, "fs": 10.0}), _t(" and years with "), _t("G", {"c": T.ACCENT}),
		_t(" = 4π². Real vehicles in metres and seconds. Pick where to start — you can switch at any time.")])
	start_cards = E(inner, {"display": "grid", "cols": [1.0, 1.0, 1.0], "gapc": 16.0, "gapr": 16.0})
	for c in [["sandbox", "Sandbox", "Build and break systems. N-body gravity, real interiors, black holes, climate, and the imaging bands to look at it all in."],
			["learn", "Learn astronomy", "A beginner’s course, thirty-five lessons, built on the same physics as the rest of this. Seasons and moon phases through to gravitational waves — in order, or jump to what you came for."],
			["flight", "Spaceflight", "Fly real vehicles off a real pad. Staging, guidance, landings, time dilation — and a model viewer to see what you are flying."]]:
		var card := B(start_cards, C.button({"display": "block", "ta": "left", "bg": T.rgba(12, 15, 23, 0.85), "b": [1, T.BORDER],
			"p": [22, 22, 20, 22], "c": T.TEXT, "ff": "mono", "fs": 13.333, "fit": false}), null, "[data-start=%s]" % c[0],
			[["hover", {"bcol": T.ACCENT, "bg": T.rgba(20, 24, 34, 0.9)}]])
		card.set_meta("start", c[0])
		card.add_child(StartIcon.new(c[0]))
		E(card, {"fs": 15.0, "ls": C.em(0.06, 15), "mb": 8.0, "c": T.hexc(0xe6ecf4)}, c[1])
		E(card, {"fs": 11.0, "lh": 1.65, "c": T.TEXT_DIM}, c[2])
		card.pressed.connect(func(): start_chosen.emit(c[0]))
	E(inner, {"mt": 26.0, "fs": 10.0, "ls": C.em(0.08, 10), "c": T.rgba(106, 115, 130, 0.75)},
		"Everything is derived, nothing is scripted — if a rocket cannot reach orbit here, it could not reach orbit.")

## Fade the start screen out (`.start.gone`: opacity and a 3% scale over 0.4 s)
## and take it out of the page 420 ms later. The orchestrator calls this; the
## cards only report which one was chosen.
func dismiss_start() -> void:
	if not start_screen.visible:
		return
	start_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	start_screen.pivot_offset = size * 0.5
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(start_screen, "modulate:a", 0.0, 0.4)
	tw.tween_property(start_screen, "scale", Vector2(1.03, 1.03), 0.4)
	get_tree().create_timer(0.42).timeout.connect(func(): start_screen.visible = false)

func show_start() -> void:
	start_screen.visible = true
	start_screen.modulate.a = 1.0
	start_screen.scale = Vector2.ONE
	start_screen.mouse_filter = Control.MOUSE_FILTER_STOP
	El.any_dirty = true

# =============================================================================================
# VISIBILITY
# =============================================================================================

## One element can be hidden for several independent reasons — its own inline
## display, a mode class, a folded section — and it shows only when none holds.
## This is the port of "a class, not an inline display": no writer can undo
## another's reason by accident.
func _hide(e: El, why: String, hidden: bool) -> void:
	if not hidden_flags.has(e):
		hidden_flags[e] = {}
	hidden_flags[e][why] = hidden
	var vis := true
	for k in hidden_flags[e]:
		if hidden_flags[e][k]:
			vis = false
	if e.visible != vis:
		e.visible = vis
		e.touch()
		El.any_dirty = true

func _apply_body_classes() -> void:
	var fl := body.has("flight-mode")
	var le := body.has("learn-mode")
	var mo := body.has("model-open")
	var hh := body.has("hud-hidden")
	# body.hud-hidden .hud { display: none }
	for r in roots:
		if r == toast_el or r == start_screen or corners.has(r):
			continue
		_hide(r, "hud", hh)
	# In flight mode the orrery's own instruments are not merely folded — they
	# are gone: the scenario list, its tab, and the cross-section.
	_hide(scenario_panel, "cls", fl or le)
	_hide(xsec_panel, "cls", fl)
	_hide(tabs.scenarioPanel, "cls", fl or le)
	# ...and the flight panel's tab has nothing to reopen in the sandbox.
	_hide(tabs.flightPanel, "cls", not fl)
	_hide(course_panel, "cls", not le)
	_hide(tabs.coursePanel, "cls", not le)
	# In Learn mode the bottom-centre band belongs to the lesson.
	_hide(hint, "cls", le)
	# The model viewer takes the FRAME, tabs included.
	_hide(tab_col, "cls", mo)
	_hide(tab_right, "cls", mo)
	_hint_runs()

func _set_body(cls: String, on: bool) -> void:
	if on: body[cls] = true
	else: body.erase(cls)

# =============================================================================================
# THE ORCHESTRATOR's API
# =============================================================================================

## setPanelOpen: a panel's own collapsed state, and the tab it leaves behind.
func set_panel_open(id: String, open: bool) -> void:
	var p: El = ids.get(id)
	if p == null:
		return
	if open: collapsed.erase(id)
	else: collapsed[id] = true
	_hide(p, "inline", not open)
	if tabs.has(id):
		_hide(tabs[id], "inline", open)
	# the key hint sits in the bottom-right corner; give it the corner back
	# when the control panel is not occupying it
	if id == "controlPanel":
		_set_body("panel-open-right", open)
	# the left column is a stack: the editor being open squeezes the settings
	if id == "xsecPanel":
		_set_body("xsec-open", open)
	El.any_dirty = true
	panel_changed.emit(id, open)

func is_collapsed(id: String) -> bool:
	return collapsed.has(id)

## The mode switch's visuals and the section filter. Which panels a mode
## opens stays with the orchestrator (it calls set_panel_open).
func set_app_mode(mode: String) -> void:
	app_mode = mode
	for m in ["sandbox", "learn", "flight"]:
		for b in sels.get("[data-mode=%s]" % m, []):
			b.set_state("on", m == mode)
	apply_section_modes(mode)
	_set_body("flight-mode", mode == "flight")
	_set_body("learn-mode", mode == "learn")
	_apply_body_classes()

## body.model-open: the studio takes the frame, and the tabs go with it.
func set_model_open(on: bool) -> void:
	_set_body("model-open", on)
	_apply_body_classes()

## H hides the HUD. One class, so every panel keeps the state that IS its
## collapsed state and comes back exactly as it was.
func set_hud_hidden(hidden: bool) -> void:
	hud_hidden = hidden
	_set_body("hud-hidden", hidden)
	_apply_body_classes()
	if hidden:
		toast("HUD hidden — press H to restore")

func mount(n: String) -> Control:
	return _mounts.get(n, ids.get(n))

func get_el(id: String) -> El:
	return ids.get(id)

func _targets(sel: String) -> Array:
	var s := sel.replace("\"", "").replace("'", "")
	if s.begins_with("#"): s = s.substr(1)
	if sels.has(s): return sels[s]
	if run_ids.has(s): return []
	return []

## Text of any element or inline span by id — including every "<range>-val".
func set_text(id: String, text: String) -> void:
	if run_ids.has(id):
		var pr: Array = run_ids[id]
		if pr[1].t != text:
			pr[1].t = text
			(pr[0] as El)._invalidate()
			(pr[0] as El).touch()
		return
	for e in _targets(id):
		if e is RangeInput:
			continue
		e.set_text(text)

func set_shown(id: String, shown: bool) -> void:
	for e in _targets(id):
		_hide(e, "inline", not shown)
	if id == "modelPanel" or id == "xsecPanel" or id == "flightPanel":
		if shown: collapsed.erase(id)
		else: collapsed[id] = true

## `.active` / `.on` on a button, by id or by "[data-x=v]" — whichever of the
## two classes that element's stylesheet rules are written against.
func set_active(sel: String, on: bool) -> void:
	for e in _targets(sel):
		var has_on := false
		for v in e.variants:
			if v[0] == "on": has_on = true
		e.set_state("on" if has_on else "active", on)
		if e.has_state("tri"):
			e.set_state("triactive", on)

func set_button_text(sel: String, text: String) -> void:
	for e in _targets(sel):
		e.set_text(text)

## A range input's value, WITHOUT an input event (the orchestrator's own write).
func set_slider(id: String, value: float, label_text = null) -> void:
	var r: RangeInput = sliders.get(id)
	if r: r.set_value(value)
	if label_text != null:
		set_text(id + "-val", str(label_text))

## setControl: move a slider AS IF the user had — the learner sees it move and
## every downstream binding fires.
func drive_slider(id: String, value: float) -> void:
	var r: RangeInput = sliders.get(id)
	if r == null:
		return
	r.set_value(value)
	_on_slider(r.value, id)

func get_slider(id: String) -> float:
	var r: RangeInput = sliders.get(id)
	return r.value if r else 0.0

## The step counter goes red, and says why, when the integrator hit its guard.
func set_warn(id: String, on: bool, tooltip := "") -> void:
	for e in _targets(id):
		e.set_state("warn", on)
		e.tooltip_text = tooltip
		e.mouse_filter = Control.MOUSE_FILTER_PASS if tooltip != "" else Control.MOUSE_FILTER_IGNORE

## updateSimStats' display half: steps (capped at the guard) and drift.
func set_sim_stats(steps: int, drift_rel: float) -> void:
	var capped := steps >= STEP_GUARD
	set_text("setSteps", ("%d capped" % steps) if capped else str(steps))
	set_warn("setSteps", capped, "The integrator hit its 8000 sub-step guard. The answer is still correct — it advances the clock by what it actually integrated — but simulated time is now running slower than the Time panel says. Raise the step cap." if capped else "")
	set_text("setDrift", "0" if drift_rel < 1e-12 else U.expo(drift_rel, 1))

func pointer_over_ui() -> bool:
	var h := get_viewport().gui_get_hovered_control()
	return h != null and h != self and is_ancestor_of(h)

# ---- toast -------------------------------------------------------------------------------------
## Transient message, at the top of the free band between the panels.
func toast(msg: String, ms := 2200) -> void:
	toast_el.set_text(msg)
	# placed in whatever gap the panels have left, computed as it appears
	_layout_all()
	if _toast_tween: _toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(toast_el, "modulate:a", 1.0, 0.35)
	_toast_timer = ms / 1000.0

# ---- presets -------------------------------------------------------------------------------------
func render_preset_groups(groups: Array, presets: Dictionary, active_key: String) -> void:
	_groups = groups
	_presets = presets
	_active_preset = active_key
	_render_presets()

## renderPresetGroups. Search owns the open state while active, so every
## matching category stays visible; groups opened by hand are remembered when
## the query is cleared.
func _render_presets() -> void:
	var q := _search.edit.text.strip_edges().to_lower()
	var searching := q.length() > 0
	for k in _preset_list.get_children():
		_preset_list.remove_child(k)
		k.queue_free()
	_preset_list.touch()
	for sel in sels.keys():
		if str(sel).begins_with("[data-preset="):
			sels.erase(sel)
	var visible_groups := 0
	for g in _groups:
		var gid: String = g.id
		var gtext := ("%s %s" % [gid, g.label]).to_lower()
		var gmatch := searching and gtext.contains(q)
		var keys: Array = []
		for key in g.get("keys", []):
			if not searching or gmatch or ("%s %s" % [key, _presets.get(key, {}).get("name", key)]).to_lower().contains(q):
				keys.append(key)
		if keys.is_empty():
			continue
		visible_groups += 1
		var cnt := ("%d/%d" % [keys.size(), g.keys.size()]) if searching and not gmatch else str(g.keys.size())
		var open := searching or _open_groups.has(gid)
		var det := E(_preset_list, {"b": [1, T.BORDER], "minw": 0.0})
		var summ := E(det, {"display": "flex", "ai": "center", "gapc": 7.0, "p": [8, 9], "c": T.TEXT_DIM, "fs": 10.0,
			"ls": C.em(0.1, 10), "up": true}, null, "",
			[["open", {"c": T.TEXT, "bg": Color(1, 1, 1, 0.025), "bb": 1.0, "bcb": T.BORDER}],
			["hover", {"c": T.TEXT, "bg": T.rgba(180, 200, 230, 0.06)}]])
		summ.make_clickable()
		summ.set_state("open", open)
		E(summ, {"c": T.ACCENT_2, "fs": 11.0, "lh": 1.0}, "▸", "", [["open", {}]]).set_meta("marker", true)
		var mk: El = summ.get_child(0)
		if open:
			mk.set_style({"c": T.ACCENT})
			mk.set_text("▾")
		E(summ, {"grow": 1.0, "basis": 0.0, "minw": 0.0}, g.label)
		E(summ, {"c": T.TEXT_DIM, "fs": 9.0, "ls": C.em(0.04, 9)}, cnt)
		var items := E(det, {"display": "grid", "cols": [1.0], "gapr": 5.0, "p": 5})
		_hide(items, "closed", not open)
		for key in keys:
			var tri: bool = gid == "trisolaris"
			var b := B(items, C.preset_btn(), _presets.get(key, {}).get("name", key), "[data-preset=%s]" % key,
				[["hover", {"c": T.TEXT, "bcol": T.BORDER_STRONG}], ["active", C.BLUE_ACTIVE],
				["tri", {"bcol": T.rgba(255, 170, 70, 0.4), "c": T.hexc(0xffc98a)}],
				["triactive", {"bg": T.ACCENT, "c": Color.BLACK, "bcol": T.ACCENT}]])
			b.set_state("tri", tri)
			b.set_state("active", key == _active_preset)
			b.set_state("triactive", tri and key == _active_preset)
			b.pressed.connect(func(): preset_chosen.emit(key))
		summ.pressed.connect(func():
			if searching:
				return
			if _open_groups.has(gid): _open_groups.erase(gid)
			else: _open_groups[gid] = true
			_render_presets())
	_hide(_preset_list, "inline", visible_groups == 0)
	_hide(_preset_empty, "inline", visible_groups != 0)
	if searching:
		_preset_empty.set_text("No scenarios or categories match \"%s\"" % _search.edit.text.strip_edges())
	_hide(_search_clear, "inline", not searching)
	El.any_dirty = true

## Mark the running scenario in the list (loadPreset's `[data-preset]` toggle).
func set_active_preset(key: String) -> void:
	_active_preset = key
	for sel in sels.keys():
		if str(sel).begins_with("[data-preset="):
			var k := str(sel).trim_prefix("[data-preset=").trim_suffix("]")
			for b in sels[sel]:
				b.set_state("active", k == key)
				b.set_state("triactive", b.has_state("tri") and k == key)

func open_preset_group(gid: String, open := true) -> void:
	if open: _open_groups[gid] = true
	else: _open_groups.erase(gid)
	_render_presets()

func set_search(text: String) -> void:
	_search.edit.text = text
	_render_presets()

# ---- refreshUI's body list -------------------------------------------------------------------------
func render_body_list(bodies: Array, focus_id) -> void:
	var list: El = ids.bodyList
	list.touch()
	for k in list.get_children():
		if k is El:
			list.remove_child(k)
			k.queue_free()
	if bodies.is_empty():
		E(list, {"p": 10, "c": T.TEXT_DIM, "ta": "center", "fs": 10.0, "fi": true}, "— empty —")
		return
	for i in bodies.size():
		var bd: Dictionary = bodies[i]
		var bid: int = bd.id
		var it := E(list, {"display": "flex", "jc": "space-between", "ai": "center", "p": [6, 8],
			"bb": 0.0 if i == bodies.size() - 1 else 1.0, "bcb": T.BORDER, "fs": 10.0}, null, "",
			[["sel", {"bg": T.rgba(78, 168, 255, 0.12)}], ["hover", {"bg": T.rgba(180, 200, 230, 0.06)}]])
		it.make_clickable()
		it.set_state("sel", focus_id != null and int(focus_id) == bid)
		it.pressed.connect(func(): body_focus.emit(bid))
		E(it, {"c": T.TEXT_DIM, "ls": 1.0}, "#%d %s" % [bid, bd.name])
		var rm := B(it, C.button({"bg": T.CLEAR, "b": [0, T.CLEAR], "c": T.WARN, "ff": "mono", "fs": 12.0, "lh": 12.0}), "✕")
		rm.pressed.connect(func(): body_remove.emit(bid))

# ---- updateHUD: suns --------------------------------------------------------------------------------
## rows: [{name, cls, mass, teff, dist_au, intensity, color (LINEAR), flaring}]
func render_sun_list(rows: Array) -> void:
	var list: El = ids.sunList
	while _sun_rows.size() < rows.size():
		var row := E(list, {"display": "grid", "cols": [-10.0, 1.0], "gapr": 1.0, "gapc": 8.0, "ai": "center",
			"p": [6, 8], "b": [1, T.BORDER], "bg": Color(1, 1, 1, 0.015)})
		var dot := E(row, {"w": 9.0, "h": 9.0, "area": [0, 0], "glow": 8.0, "bg": Color.WHITE})
		var sn := E(row, {"area": [1, 0], "fs": 11.0, "c": T.TEXT, "ls": C.em(0.04, 11)}, "")
		var sc := E(row, {"area": [1, 1], "fs": 9.5, "c": T.TEXT_DIM}, "")
		var sf := E(row, {"area": [1, 2], "fs": 9.5, "c": T.ACCENT_2}, "")
		_sun_rows.append([row, dot, sn, sc, sf])
	for i in _sun_rows.size():
		var r: Array = _sun_rows[i]
		var on := i < rows.size()
		_hide(r[0], "inline", not on)
		if not on:
			continue
		var s: Dictionary = rows[i]
		var col: Color = s.color
		# '#' + color.getHexString(): the sun's LINEAR colour, encoded to sRGB
		var css := Color.html(U.css_of(col))
		r[1].set_style({"bg": css})
		r[2].set_text(str(s.name))
		r[3].set_text("%s · %s M☉ · %d K" % [s.get("cls", ""), U.fixed(float(s.mass), 2), int(U.jround(float(s.teff)))])
		var runs: Array = [{"t": "%s AU · %s S⊕" % [U.fixed(float(s.dist_au), 2), U.fixed(float(s.intensity), 2)]}]
		if s.get("flaring", false):
			runs.append({"t": "FLARE", "c": Color.BLACK, "fs": 8.5, "ls": C.em(0.1, 8.5), "pulse": true,
				"box": {"bg": T.hexc(0xffcc44), "pl": 4, "pr": 4, "ml": 4}})
		r[4].set_runs(runs)

# ---- updateHUD: climate ---------------------------------------------------------------------------------
## cl: {label, cls, desc, celsius, S, ice, clouds, tauYears, Tmin, Tmax, history}
func update_climate(cl: Dictionary) -> void:
	var badge: El = ids.eraBadge
	var era: Dictionary = HudCss.ERA.get(cl.get("cls", "era-stable"), HudCss.ERA["era-stable"])
	badge.set_style({"c": era.c, "bcol": era.c, "bg": era.bg})
	badge.set_text(str(cl.get("label", "")))
	set_text("eraDesc", str(cl.get("desc", "")))
	set_text("cTemp", "%s °C" % U.fixed(cl.celsius, 1))
	set_text("cFlux", "%s S⊕" % U.fixed(cl.S, 2))
	set_text("cIce", "%s %%" % U.fixed(cl.ice * 100.0, 0))
	set_text("cCloud", "%s %%" % U.fixed(cl.clouds * 100.0, 0))
	set_text("cTau", "%s yr" % U.fixed(cl.tauYears, 2))
	set_text("cExtremes", "%s … %s °C" % [U.fixed(cl.Tmin - 273.15, 0), U.fixed(cl.Tmax - 273.15, 0)])
	(ids.climateChart as ClimateChart).set_history(cl.get("history", []))

static func fmt_years(y: float) -> String:
	return ClimateChart.fmt_years(y)

static func time_label(yr_per_sec: float) -> String:
	if yr_per_sec < 3e-3: return "%s hr/s" % U.fixed(yr_per_sec * 365.25 * 24.0, 2)
	if yr_per_sec < 1.0: return "%s d/s" % U.fixed(yr_per_sec * 365.25, 2)
	return "%s yr/s" % U.fixed(yr_per_sec, 1)

# ---- imaging band ------------------------------------------------------------------------------------------
func build_band_grid(bands: Array) -> void:
	var g: El = ids.bandGrid
	for i in bands.size():
		var b := B(g, C.band_btn(), str(bands[i].short), "[data-band=%d]" % i,
			[["hover", C.TOGGLE_HOVER], ["active", C.BLUE_ACTIVE]], str(bands[i].get("note", "")))
		b.pressed.connect(func(): band_chosen.emit(i))
	_band_count = bands.size()

func set_band(i: int, band: Dictionary) -> void:
	for k in _band_count:
		set_active("[data-band=%d]" % k, k == i)
	set_text("bandNote", str(band.get("note", "")))
	set_text("bandLabel", str(band.get("short", "")))

# ---- sky settings --------------------------------------------------------------------------------------------
## The environment rows and the amplitude rows, built from the sky module's
## own lists — a sixth environment grows a row here without this file changing.
func build_sky_settings(envs, params: Array) -> void:
	# SkyModel.SKY_ENVIRONMENTS is a Dictionary in web order; its keys are the rows
	if envs is Dictionary:
		envs = (envs as Dictionary).keys()
	_envs = envs; _params = params
	var list: El = ids.skyEnvList
	for name in envs:
		var row := E(list, {"mb": 13.0})
		var head := E(row, {"display": "flex", "jc": "space-between", "ai": "baseline", "gapc": 6.0, "fs": 11.0, "c": T.TEXT_DIM, "mb": 2.0},
			null, "", [["on", {"c": T.TEXT}]])
		reg("[data-env=%s]" % name, head)
		var left := E(head, {"display": "flex", "ai": "baseline"})
		E(left, {}, str(name))
		var solo := B(left, C.button({"bg": T.CLEAR, "b": [0, T.CLEAR], "p": [0, 0, 0, 6], "ff": "mono", "fs": 9.0,
			"ls": C.em(0.08, 9), "c": T.TEXT_DIM, "up": true}), "solo", "[data-solo=%s]" % name, [["hover", {"c": T.ACCENT}]],
			"Show this environment alone")
		solo.pressed.connect(func(): sky_solo.emit(name))
		E(head, {"ff": "mono", "fs": 10.0, "c": T.ACCENT}, "0.00", "env-w:" + str(name), [["off", {"c": T.TEXT_DIM}]])
		_range(row, "env:" + str(name), {"wp": 1.0, "mt": 8.0}, 0, 3, 0, 0.05,
			func(v): return U.fixed(v, 2) if v > 0.0 else "—")
		val_fmt.erase("env:" + str(name))
	var adv: El = ids.skyAdv
	for pm in params:
		var add: bool = pm.get("add", true)
		var tip := "An amount of something — blends by ADDING, because two populations along one line of sight superpose." if add \
			else "A shape of the one galaxy you are in — blends by weighted MEAN, because there is only one galactic plane."
		_set_row(adv, "skyp:" + str(pm.key), str(pm.label), tip, 0, float(pm.max), 0, float(pm.max) / 200.0, "0")
	B(adv, C.ghost_btn(), "Unpin all — back to the blend", "skyAdvClear", [["hover", C.GHOST_HOVER]]).pressed.connect(func(): sky_adv_clear.emit())

## syncSkyControls. `eff` is the blend's output merged with the live spec's
## pinned values; `skip_inputs` updates only the numbers, never a slider under
## the pointer.
func sync_sky_controls(sky: Dictionary, eff: Dictionary, skip_inputs := false) -> void:
	var env: Dictionary = sky.get("env", {})
	for name in _envs:
		var w := float(env.get(name, 0.0))
		for h in sels.get("[data-env=%s]" % name, []):
			h.set_state("on", w > 0.0)
		for e in _targets("env-w:" + str(name)):
			e.set_state("off", w <= 0.0)
		set_text("env-w:" + str(name), U.fixed(w, 2) if w > 0.0 else "—")
		if not skip_inputs:
			set_slider("env:" + str(name), w)
	for pm in _params:
		var v := float(eff.get(pm.key, 0.0))
		var pinned := sky.has(pm.key)
		set_text("skyp:%s-val" % pm.key, (U.fixed(v, 3) if float(pm.max) <= 1.5 else U.fixed(v, 2)) + (" ·" if pinned else ""))
		if not skip_inputs:
			set_slider("skyp:" + str(pm.key), minf(v, float(pm.max)))
	if not skip_inputs:
		set_slider("skyTilt", float(sky.get("tilt", 0.34)))
		set_slider("skyRoll", float(sky.get("roll", 0.9)))
	set_text("skyTilt-val", U.fixed(float(sky.get("tilt", 0.34)), 2))
	set_text("skyRoll-val", U.fixed(float(sky.get("roll", 0.9)), 2))

# ---- spaceflight ---------------------------------------------------------------------------------------------
## rows: [{key, name, desc ("2.86 kt · 14.3 km/s · launch"), blurb}]
func render_craft_grid(rows: Array) -> void:
	var g: El = ids.craftGrid
	g.touch()
	for k in g.get_children():
		g.remove_child(k); k.queue_free()
	for r in rows:
		var key: String = r.key
		var b := B(g, C.craft_btn(), null, "[data-craft=%s]" % key, [["hover", C.CRAFT_HOVER], ["on", C.CRAFT_ON]], str(r.get("blurb", "")))
		E(b, {"fw": 600, "c": T.hexc(0xdbeaff)}, str(r.name))
		E(b, {"c": T.hexc(0x7d93ae), "fs": 9.5}, str(r.desc))
		b.pressed.connect(func(): craft_launch.emit(key))
		# Warm the mesh on hover: pointing at a button is a reliable signal that
		# it is about to be pressed.
		b.mouse_entered.connect(func(): craft_hover.emit(key))

func render_model_grid(list: Array) -> void:
	var g: El = ids.mvGrid
	g.touch()
	for k in g.get_children():
		g.remove_child(k); k.queue_free()
	for v in list:
		var key: String = v.key
		B(g, C.mv_chip(), str(v.name), "[data-mv=%s]" % key, [["hover", C.TOGGLE_HOVER], ["on", C.MV_CHIP_ON]]) \
			.pressed.connect(func(): model_show.emit(key))

static func mv_mass(kg: float) -> String:
	if kg >= 1e6: return "%s kt" % U.fixed(kg / 1e6, 2)
	if kg >= 1e3: return "%s t" % U.fixed(kg / 1e3, 1)
	return "%s kg" % U.fixed(kg, 0)

## showModel's markup: st = {key?, name, height, gross, dv, twr, rows: [{name,
## L, D, dry, prop, engine, thrust, isp, dv}]}
func show_model_stats(st: Dictionary) -> void:
	set_text("mvName", str(st.name))
	if st.has("key"):
		for sel in sels.keys():
			if str(sel).begins_with("[data-mv="):
				for b in sels[sel]:
					b.set_state("on", sel == "[data-mv=%s]" % st.key)
	var list: El = ids.mvList
	list.touch()
	ids.mvStages.touch()
	for k in list.get_children():
		list.remove_child(k); k.queue_free()
	for kv in [["height", "%s m" % U.fixed(st.height, 1)], ["gross", mv_mass(st.gross)],
			["ideal Δv", "%s km/s" % U.fixed(st.dv / 1000.0, 2)], ["pad TWR", U.fixed(st.twr, 2) if st.twr > 0.0 else "—"]]:
		var cell := E(list, {"display": "flex", "jc": "space-between", "fs": 10.0})
		E(cell, {"c": T.TEXT_DIM}, kv[0])
		E(cell, {"c": T.TEXT}, kv[1])
	var stg: El = ids.mvStages
	for k in stg.get_children():
		stg.remove_child(k); k.queue_free()
	var i := 0
	for r in st.get("rows", []):
		i += 1
		var s := E(stg, {"bl": 2.0, "bcl": T.BORDER_STRONG, "p": [5, 0, 5, 8], "mb": 6.0})
		var top := E(s, {"display": "flex", "ai": "baseline", "gapc": 6.0, "fs": 11.0})
		E(top, {"c": T.ACCENT}, str(i))
		E(top, {"grow": 1.0, "basis": 0.0, "minw": 0.0, "c": T.TEXT}, str(r.name))
		E(top, {"c": T.ACCENT_2, "fs": 10.0}, "%s km/s" % U.fixed(r.dv / 1000.0, 2))
		E(s, {"fs": 9.5, "c": T.TEXT_DIM, "lh": 1.5}, "%s × %s m · %s dry + %s prop" % [U.fixed(r.L, 1), U.fixed(r.D, 1), mv_mass(r.dry), mv_mass(r.prop)])
		var eng := str(r.engine)
		if float(r.get("thrust", 0.0)) > 0.0:
			eng += " · %s MN vac · Isp %s s" % [U.fixed(r.thrust / 1e6, 2), U.fixed(r.isp, 0)]
		E(s, {"fs": 9.5, "c": T.TEXT_DIM, "lh": 1.5}, eng)

# =============================================================================================
# LAYOUT — layoutLeftColumn and every position:fixed rule
# =============================================================================================

func _process(dt: float) -> void:
	_time += dt
	if _toast_timer > 0.0:
		_toast_timer -= dt
		if _toast_timer <= 0.0:
			if _toast_tween: _toast_tween.kill()
			_toast_tween = create_tween()
			_toast_tween.tween_property(toast_el, "modulate:a", 0.0, 0.35)
	# @keyframes flare-pulse { 0%, 100% { opacity: 1 } 50% { opacity: .45 } },
	# 0.7 s ease-in-out
	var ph := fmod(_time, 0.7) / 0.7
	var tt := 1.0 - absf(2.0 * ph - 1.0)
	var ease := tt * tt * (3.0 - 2.0 * tt)
	for r in _sun_rows:
		var sf: El = r[4]
		if sf.visible and sf.runs.size() > 1:
			sf.pulse = 1.0 - 0.55 * ease
			sf.queue_redraw()
	if size != _last_size:
		_last_size = size
		_full = true
		El.any_dirty = true
	if El.any_dirty:
		_layout_all()

func layout_left_column() -> void:
	_layout_all()

func _fit_w(e: El, avail: float) -> float:
	return minf(e.max_content_w(), avail)

func _shown(e: El) -> bool:
	return e != null and e.is_visible_in_tree() and e.size.y > 0.0

func _set_quiet(e: El, k: String, v) -> void:
	e.base[k] = v
	e.cs[k] = v

## Place a positioned element; lay it out again only if something in it
## changed or it is being given a different width or height cap. The HUD's
## texts change ten times a second (updateHUD), and re-laying out every panel
## for a sun row's flux is most of a frame's layout budget for nothing.
func _lay(e: El, x: float, y: float, w: float, maxh := -1.0) -> void:
	_set_quiet(e, "maxh", maxh)
	e.position = Vector2(x, y)
	if not e.visible:
		e.size = Vector2(w, 0)
		e.set_meta("lk", null)
		return
	var key := [w, maxh]
	if _full or _dirty.has(e) or e.get_meta("lk", null) != key:
		e._ldirty = true
		e.layout(w)
		e.set_meta("lk", key)

var _dirty := {}
var _full := true

## A complete relayout of every element (a resize, a font change).
func relayout() -> void:
	_full = true
	_layout_all()

func _layout_all() -> void:
	_dirty = El.dirty_roots.duplicate()
	El.any_dirty = false
	El.dirty_roots.clear()
	var W := size.x
	var H := size.y
	if W <= 0.0 or H <= 0.0:
		return
	# corners
	for c in corners:
		var k: String = c.get_meta("corner")
		c.layout(14)
		c.position = Vector2(10 if k.ends_with("l") else W - 24, 10 if k.begins_with("t") else H - 24)
	# .title-block { top: 18px; left: 20px }
	_lay(title_block, 20, 18, _fit_w(title_block, W - 20))
	# .readout { bottom: 18px; left: 20px }
	_lay(readout, 20, 0, _fit_w(readout, W - 20))
	readout.position.y = H - 18 - readout.size.y
	# The column's own top and bottom edges are MEASURED, not assumed.
	var col_top := roundf(title_block.position.y + title_block.size.y) + 12.0 if _shown(title_block) else 18.0
	var hud_bottom := roundf(readout.size.y) + 30.0 if _shown(readout) else 30.0

	# Settings is the head of the column and everything below hangs off its
	# MEASURED bottom — the tab stack included.
	var set_max := minf(H - col_top - hud_bottom, 0.58 * H)
	if body.has("xsec-open"):
		set_max = 0.40 * H
	_lay(settings_panel, 20, col_top, 268, set_max)
	var tab_top := roundf(settings_panel.position.y + settings_panel.size.y) + 12.0 if _shown(settings_panel) else col_top
	_lay(tab_col, 20, tab_top, _fit_w(tab_col, W - 20))
	# A collapsed panel leaves a tab behind at the top of the column, so the
	# first free y is the bottom of that stack, not the bare top of the column.
	var free := roundf(tab_col.position.y + tab_col.size.y) + 12.0 if _shown(tab_col) else tab_top
	_lay(scenario_panel, 20, free, 232, H - free - hud_bottom)
	_lay(course_panel, 20, free, 250, H - free - hud_bottom)
	var top: El = null
	for p in [scenario_panel, course_panel]:
		if _shown(p):
			top = p; break
	var y := roundf(top.position.y + top.size.y) + 12.0 if top else free
	var xsec_top := y
	_lay(flight_panel, 12, y, 306, H - y - hud_bottom)
	if _shown(flight_panel):
		xsec_top = roundf(flight_panel.position.y + flight_panel.size.y) + 12.0
	_lay(xsec_panel, 20, xsec_top, 348, H - xsec_top - hud_bottom)
	_lay(model_panel, 20, col_top, 268, H - col_top - hud_bottom)
	# the control column and its tab
	_lay(control_panel, W - 18 - 300, 18, 300, H - 36)
	_lay(tab_right, 0, col_top, _fit_w(tab_right, W))
	tab_right.position.x = W - 18 - tab_right.size.x

	# The toast sits at the top of the FREE BAND, not the middle of the window.
	var band_l := 16.0
	for e in [settings_panel, scenario_panel, course_panel, model_panel, flight_panel, xsec_panel, tab_col]:
		if not _shown(e): continue
		if e.position.y < col_top + 48.0:
			band_l = maxf(band_l, e.position.x + e.size.x + 16.0)
	var band_r := control_panel.position.x - 16.0 if _shown(control_panel) else W - 16.0
	var toast_x := roundf((band_l + band_r) * 0.5)
	var tmax := minf(420.0, 0.76 * W)
	_lay(toast_el, 0, col_top, _fit_w(toast_el, tmax))
	toast_el.position.x = toast_x - toast_el.size.x * 0.5

	# The lesson card gets its own band, measured over every left panel.
	var card_l := 16.0
	for e in [settings_panel, scenario_panel, course_panel, flight_panel, xsec_panel, tab_col]:
		if _shown(e): card_l = maxf(card_l, e.position.x + e.size.x + 16.0)
	var card_r := roundf(maxf(W - band_r, 16.0))
	card_l = roundf(card_l)
	var cmax := minf(0.42 * H, 380.0)
	var cw: float
	var cx: float
	if W <= 1040.0:
		cx = 16.0; cw = W - 32.0
	else:
		var avail := W - card_l - card_r
		cw = maxf(minf(avail, 880.0), 360.0)
		cx = card_l + maxf((avail - cw) * 0.5, 0.0)
	_lay(lesson_card, cx, 0, cw, cmax)
	lesson_card.position.y = H - 16.0 - lesson_card.size.y

	# The key hint WRAPS rather than reaching the left column's panels.
	var clear := readout.position.x + readout.size.x if _shown(readout) else 20.0
	clear = roundf(clear)
	for e in [settings_panel, scenario_panel, xsec_panel, flight_panel, model_panel]:
		if _shown(e): clear = maxf(clear, roundf(e.position.x + e.size.x))
	var hint_clear := clear + 24.0
	var right := 336.0 if body.has("panel-open-right") else 18.0
	var hmax := W - right - hint_clear
	_lay(hint, 0, 0, _fit_w(hint, maxf(hmax, 0.0)))
	hint.position = Vector2(W - right - hint.size.x, H - 18.0 - hint.size.y)

	# the start screen
	start_screen.position = Vector2.ZERO
	start_screen.pivot_offset = Vector2(W, H) * 0.5
	var inner: El = start_screen.get_child(0) as El
	for k in start_screen.get_children():
		if k is El and k.has_meta("inner"): inner = k
	_start_cards_responsive(W)
	start_cards._ldirty = true
	inner._ldirty = true
	var iw := minf(860.0, 0.9 * W)
	var ih := inner.layout(iw)
	inner.position = Vector2((W - iw) * 0.5, (H - ih) * 0.5)
	start_screen.size = Vector2(W, H)
	start_screen._sync_blur()
	start_screen.queue_redraw()
	# the scenario search's ✕ is absolutely positioned inside the field
	if _search_clear.visible:
		_search_clear.layout(_search_clear.max_content_w())
		_search_clear.position = Vector2(_search.size.x - 1 - 6 - _search_clear.size.x, (_search.size.y - _search_clear.size.y) * 0.5)
	El.any_dirty = false
	El.dirty_roots.clear()
	_full = false

## Three doors, stepping down rather than wrapping to an orphan: at 1040 px the
## course card goes full width above the other two, at 720 px one column.
func _start_cards_responsive(W: float) -> void:
	var cards := start_cards.get_children()
	if W > 1040.0:
		_set_quiet(start_cards, "cols", [1.0, 1.0, 1.0])
		for c in cards:
			c.base.erase("span"); c.cs.erase("span")
		start_cards.move_child(cards_by("learn"), 1)
	elif W > 720.0:
		_set_quiet(start_cards, "cols", [1.0, 1.0])
		start_cards.move_child(cards_by("learn"), 0)
		for c in cards:
			var sp := 2 if c.get_meta("start") == "learn" else 1
			c.base["span"] = sp; c.cs["span"] = sp
	else:
		_set_quiet(start_cards, "cols", [1.0])
		for c in cards:
			c.base.erase("span"); c.cs.erase("span")

func cards_by(k: String) -> Node:
	for c in start_cards.get_children():
		if c.get_meta("start", "") == k:
			return c
	return null

func _input(e: InputEvent) -> void:
	# Clicking anywhere but the search box gives the keyboard back to the view.
	if e is InputEventMouseButton and e.pressed and _search and _search.edit.has_focus():
		if not _search.get_global_rect().has_point(e.position):
			_search.edit.release_focus()
