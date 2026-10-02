class_name Hud
extends Control

# THE HUD: every panel, control and caption, as Godot Controls styled by
# ui/theme.gd. Elements with an id are registered under it, and the orchestrator
# reaches them through set_text / set_shown / set_active; it hears input through the
# signals below. The orchestrator keeps every decision.
#
# The HUD owns the panels, the measured left column (tabs for collapsed panels),
# section folding and modes, settings pages, range labels and formatters, and the
# preset, body, sun, band, craft, model-viewer and sky rows.
#
# A full-rect Control that ignores the mouse, so input on empty screen reaches the
# orchestrator's _unhandled_input.

signal start_chosen(mode: String)
signal quit_to_start()
signal quit_app()
signal binding_chosen(action: String)
signal bindings_reset()
signal app_icon_chosen(key: String)
signal mesh_style_chosen(style: String)
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
signal render_quality_chosen(quality: String)
signal lighting_quality_chosen(quality: String)
signal lighting_effect_chosen(effect: String)
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
signal model_backdrop(light: bool)
signal model_fly()
signal panel_changed(id: String, open: bool)
## The lesson card's own buttons (the course UI, written elsewhere, listens).
signal lesson_back()
signal lesson_next()
signal lesson_close()

const T = preload("res://ui/theme.gd")

# Control column sections by mode. Spaceflight hides every orrery control.
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
# the climate badge's colours per era
const ERA := {
	"era-stable": {"c": Color(0x4e / 255.0, 0xe3 / 255.0, 0x9a / 255.0), "bg": T.CLEAR},
	"era-cold": {"c": Color(0x6f / 255.0, 0xb6 / 255.0, 1.0), "bg": T.CLEAR},
	"era-freeze": {"c": Color(0xb9 / 255.0, 0xe2 / 255.0, 1.0), "bg": Color(120 / 255.0, 190 / 255.0, 1.0, 0.10)},
	"era-hot": {"c": Color(1.0, 0xab / 255.0, 0x52 / 255.0), "bg": T.CLEAR},
	"era-scorch": {"c": Color(1.0, 0x5a / 255.0, 0x4a / 255.0), "bg": Color(1.0, 70 / 255.0, 50 / 255.0, 0.12)},
}

# text styles
const H3 := {"fs": 10.0, "ls": 2.0, "up": true, "c": T.TEXT_DIM, "fw": 500}
const NOTE := {"fs": 9.5, "c": T.TEXT_DIM, "lh": 1.55}
const ROW_LABEL := {"fs": 11.0, "c": T.TEXT_DIM}
const ROW_VAL := {"fs": 11.0, "c": T.ACCENT}
const STAT_K := {"fs": 10.0, "c": T.TEXT_DIM}
const STAT_V := {"fs": 11.0, "c": T.ACCENT}

# registries
var ids := {}            # element id → Control
var sels := {}           # "[data-x=v]" or id → Array of Control
var sliders := {}        # range id → HudSlider
var val_fmt := {}        # range id → Callable(v) -> String (its "-val" label)
var collapsed := {}      # panel id → true
var body := {}           # mode classes: flight-mode, learn-mode, model-open, hud-hidden
var sections: Array = [] # {title, head, wrap, host, arrow, label, open}
var tabs := {}           # panel id → its tab
var hidden_flags := {}   # Control → {reason: hidden}
var app_mode := "sandbox"

var hud_hidden := false
var _mounts := {}
var _open_groups := {}   # preset group ids opened by hand
var _groups: Array = []
var _presets := {}
var _active_preset := ""
var _band_count := 0
var _sun_rows: Array = []
var _toast_tween: Tween = null
var _toast_timer := 0.0
var _time := 0.0
var _envs: Array = []
var _params: Array = []
var _layout_pending := false

# elements the layout needs by name
var settings_panel: HudPanel
var settings_backdrop: ColorRect
var settings_open := false
var scenario_panel: HudPanel
var course_panel: HudPanel
var lesson_card: HudPanel
var _lc_scroll: CapScroll
var control_panel: HudPanel
var model_panel: HudPanel
var xsec_panel: HudPanel
var flight_panel: HudPanel
var tab_col: VBoxContainer
var tab_right: HudButton
var readout: VBoxContainer
var toast_el: PanelContainer
var _toast_label: Label
var start_screen: Control
var start_cards: HudGrid
var _start_inner: VBoxContainer
var binding_buttons := {}
var _start_tween: Tween = null
var _start_generation := 0
var corners: Array = []
var _pages: Array = []

## The lesson card's parts, for the course UI to fill.
var lc := {}

func _init() -> void:
	name = "Hud"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = T.theme()

func _ready() -> void:
	_build()
	for id in ["scenarioPanel", "controlPanel"]:
		set_panel_open(id, true)
	set_panel_open("settingsPanel", false)
	# The flight panel only opens when there is a vessel; the cross-section has no
	# tab — it is opened from a body.
	set_panel_open("flightPanel", false)
	set_panel_open("xsecPanel", false)
	set_app_mode("sandbox")
	_layout_all()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_queue_layout()

# BUILDERS

# The builders below are static so the modules that fill the HUD's mounts (the
# Foundry, the flight instruments, the course) build with the same pieces.

## A label in a text style (T.style keys); `wrap` breaks it to the width it is given.
static func label(parent: Node, text: String, st: Dictionary, wrap := false) -> Label:
	var l: Label = Prose.new() if wrap else Label.new()
	l.set_meta("st", st)
	T.apply_label(l, st)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		(l as Prose).say(text)
		T.hang(l, st)
	else:
		l.text = text
	if parent != null:
		parent.add_child(l)
	return l

func L(parent: Node, text: String, st: Dictionary, id := "", wrap := false) -> Label:
	var l := label(parent, text, st, wrap)
	if id != "":
		reg(id, l)
	return l

## Text with inline runs, as BBCode ([b], [i], [color], [font_size]).
func RT(parent: Node, bbcode: String, st: Dictionary, id := "") -> RichTextLabel:
	var r := rich_in(parent, bbcode, st)
	if id != "":
		reg(id, r)
	return r

static func rich_in(parent: Node, bbcode: String, st: Dictionary) -> RichTextLabel:
	var r := rich(bbcode, st)
	if parent != null:
		parent.add_child(r)
	return r

## Plain text made safe for BBCode.
static func esc(s: String) -> String:
	return s.replace("[", "[lb]")

static func rich(bbcode: String, st: Dictionary) -> RichTextLabel:
	var r := Prose.Rich.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.selection_enabled = false
	var s := T.style(st)
	r.add_theme_font_override("normal_font", T.text_font(s))
	r.add_theme_font_override("bold_font", T.text_font(U.merged(s, {"fw": 700})))
	r.add_theme_font_override("italics_font", T.text_font(U.merged(s, {"fi": true})))
	r.add_theme_font_override("bold_italics_font", T.text_font(U.merged(s, {"fw": 700, "fi": true})))
	r.add_theme_font_override("mono_font", T.text_font(U.merged(s, {"ff": "mono"})))
	for k in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		r.add_theme_font_size_override(k, T.px(float(s.fs)))
	r.add_theme_color_override("default_color", s.c)
	r.add_theme_constant_override("line_separation", 0)
	r.say(bbcode)
	T.hang(r, s)
	return r

## A button of a theme kind; `sel` registers it under an id or a "[data-x=v]" selector.
func B(parent: Node, kind: String, text: String, sel := "", tip := "") -> HudButton:
	var b := HudButton.new(kind, text, tip)
	if parent != null:
		parent.add_child(b)
	if sel != "":
		reg(sel, b)
	return b

## A box of a look (T.stylebox keys) around one child. Prose goes through a stack,
## which gives it its overhang.
static func frame(child: Control, look: Dictionary) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", T.stylebox(look))
	if child is Prose or child is Prose.Rich:
		var s := HudStack.new(false)
		s.add_child(child)
		child = s
	if child != null:
		p.add_child(child)
	return p

func reg(key: String, e: Control) -> void:
	if not key.begins_with("["):
		ids[key] = e
	if not sels.has(key):
		sels[key] = []
	sels[key].append(e)

## Margins on a child; untyped, so a caller can go on to `.pressed` or `.text`.
static func m(c, mt := 0.0, mb := 0.0):
	HudStack.m(c, mt, mb)
	return c

static func stack(parent: Node, mt := 0.0, mb := 0.0) -> HudStack:
	var s := HudStack.new(true)
	HudStack.m(s, mt, mb)
	if parent != null:
		parent.add_child(s)
	return s

static func grid(parent: Node, cols: Array, hgap: float, vgap: float, mt := 0.0, mb := 0.0) -> HudGrid:
	var g := HudGrid.new(cols, hgap, vgap)
	HudStack.m(g, mt, mb)
	if parent != null:
		parent.add_child(g)
	return g

static func hbox(parent: Node, sep: float, mt := 0.0, mb := 0.0) -> HudRow:
	var h := HudRow.new(sep)
	HudStack.m(h, mt, mb)
	if parent != null:
		parent.add_child(h)
	return h

## `.panel h3`: a heading on a bottom rule; 20 px above it unless it comes first.
func _h3(parent: Node, text: String, first := false, id := "") -> PanelContainer:
	var f := frame(L(null, text, H3, id), {"bw": 0, "bb": 1, "bc": T.BORDER, "pad": [0, 0, 6, 0]})
	m(f, 0.0 if first else 20.0, 10.0)
	parent.add_child(f)
	return f

## The panel head: the heading and a ✕ that collapses the panel.
func _panel_head(p: HudPanel, title: String, close_id: String, tip := "Collapse (H hides everything)") -> HudRow:
	var head := hbox(p.body, 8.0)
	head.add_child(_head_title(title))
	var x := B(head, "PanelClose", "✕", "", tip)
	x.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	x.pressed.connect(_close_pressed.bind(close_id))
	return head

## The head's title on its rule. The row aligns baselines, and the ✕ beside it has
## the deeper one (a 12 px glyph under 2 px of padding), so the title sits 3 px down.
func _head_title(title: String) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mc.add_theme_constant_override("margin_top", 3)
	# the heading's own 10 px margin is inside the row, so it never collapses
	mc.add_theme_constant_override("margin_bottom", 10)
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.add_child(frame(L(null, title, H3), {"bw": 0, "bb": 1, "bc": T.BORDER, "pad": [0, 0, 6, 0]}))
	return mc

func _close_pressed(id: String) -> void:
	if id == "modelPanel":
		model_close.emit()
		return
	set_panel_open(id, false)
	if id == "xsecPanel":
		xsec_closed.emit()

func _note(parent: Node, text: String, extra_mb := 10.0) -> Label:
	return m(L(parent, text, NOTE, "", true), 0.0, extra_mb) as Label

func _rnote(parent: Node, bbcode: String) -> RichTextLabel:
	return m(RT(parent, bbcode, NOTE), 0.0, 10.0) as RichTextLabel

## A label whose title is a tooltip, underlined with dots as `label[title]` is.
class TipLabel extends Label:
	var full := true
	func _init(tip: String, whole := true) -> void:
		tooltip_text = tip
		full = whole
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_default_cursor_shape = Control.CURSOR_HELP
	func _draw() -> void:
		var w := size.x
		if not full and label_settings != null:
			w = minf(w, label_settings.font.get_string_size(text.to_upper() if uppercase else text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_settings.font_size).x)
		var x := 0.0
		var col: Color = label_settings.font_color if label_settings else T.TEXT_DIM
		while x < w:
			draw_rect(Rect2(x, size.y - 1.0, minf(1.0, w - x), 1.0), col)
			x += 2.0

static func tip_label(parent: Node, text: String, st: Dictionary, tip: String, whole := true) -> Label:
	var l: Label = TipLabel.new(tip, whole) if tip != "" else Label.new()
	l.set_meta("st", st)
	T.apply_label(l, st)
	l.text = text
	if tip == "":
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		# the dotted border is part of the label's box, a pixel below the text
		l.custom_minimum_size.y = T.line_h(st) + 1.0
		l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	parent.add_child(l)
	return l

## A control-column range row: label · slider · value.
func _row(parent: Node, id: String, text: String, tip: String, mn: float, mx: float, v: float, st: float,
		val_text: String, row_id := "", fmt: Callable = Callable()) -> HudRow:
	var r := _range(null, id, mn, mx, v, st, fmt)
	r.inset = 2.0
	var parts := range_row(parent, text, tip, r, val_text)
	if row_id != "":
		reg(row_id, parts.row)
	reg(id + "-val", parts.val)
	return parts.row

## A range row: the label (its title a tooltip), the control, and the readout.
static func range_row(parent: Node, text: String, tip: String, control: Control, val_text = null, mb := 10.0) -> Dictionary:
	var row := hbox(parent, 10.0, 0.0, mb)
	var lab := tip_label(row, text, ROW_LABEL, tip)
	lab.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	var val: Label = null
	if val_text != null:
		val = label(row, str(val_text), ROW_VAL)
		val.custom_minimum_size.x = 60.0
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return {"row": row, "label": lab, "val": val}

## A settings-panel range row: label and value on one line, slider under them.
func _set_row(parent: Node, id: String, text: String, tip: String, mn: float, mx: float, v: float, st: float,
		val_text: String, fmt: Callable = Callable()) -> HudStack:
	var row := stack(parent, 0.0, 13.0)
	row.collapse = false
	var head := hbox(row, 8.0)
	var lab := tip_label(head, text, ROW_LABEL, tip, false)
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.size_flags_vertical = Control.SIZE_SHRINK_END
	var val := L(head, val_text, ROW_VAL, id + "-val")
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.size_flags_vertical = Control.SIZE_SHRINK_END
	m(_range(row, id, mn, mx, v, st, fmt), 8.0)
	return row

func _range(parent: Node, id: String, mn: float, mx: float, v: float, st: float,
		fmt: Callable = Callable()) -> HudSlider:
	var r := HudSlider.new(mn, mx, st, v)
	if parent != null:
		parent.add_child(r)
	if id != "":
		reg(id, r)
		sliders[id] = r
		if fmt.is_valid():
			val_fmt[id] = fmt
		r.moved.connect(_on_slider.bind(id))
	return r

func _on_slider(v: float, id: String) -> void:
	if val_fmt.has(id):
		set_text(id + "-val", val_fmt[id].call(v))
	slider.emit(id, v)

# BUILDING THE HUD

func _build() -> void:
	for k in ["tl", "tr", "bl", "br"]:
		var c := Corner.new(k)
		add_child(c)
		corners.append(c)
	_build_flight_panel()     # under the other panels
	_build_settings()
	_build_scenario()
	_build_course()
	_build_lesson_card()
	_build_control_panel()
	_build_model_panel()
	_build_xsec_panel()
	_build_tabs()
	_build_readout()
	_build_start()
	_build_toast()
	move_child(settings_backdrop, get_child_count() - 1)
	move_child(settings_panel, get_child_count() - 1)

## A panel the left column or the control column places.
func _panel(id: String, padding: Array = [16, 16, 16, 16]) -> HudPanel:
	var p := HudPanel.new(padding)
	add_child(p)
	reg(id, p)
	p.pad.minimum_size_changed.connect(_queue_layout)
	return p

class Corner extends Control:
	var k := "tl"
	func _init(which: String) -> void:
		k = which
		size = Vector2(14, 14)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var c := T.BORDER_STRONG
		draw_rect(Rect2(0, 0 if k.begins_with("t") else 13, 14, 1), c)
		draw_rect(Rect2(0 if k.ends_with("l") else 13, 0, 1, 14), c)

# SETTINGS
func _build_settings() -> void:
	settings_backdrop = ColorRect.new()
	settings_backdrop.color = T.rgba(2, 4, 9, 0.78)
	settings_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	settings_backdrop.visible = false
	add_child(settings_backdrop)
	reg("settingsBackdrop", settings_backdrop)
	var p := _panel("settingsPanel")
	settings_panel = p
	_panel_head(p, "Settings", "settingsPanel", "Close settings (Esc)")
	var tabsrow := hbox(p.body, 4.0, 0.0, 10.0)
	reg("setTabs", tabsrow)
	for t in [["sky", "Sky"], ["render", "Render"], ["sim", "Sim"], ["controls", "Controls"]]:
		var b := B(tabsrow, "SetTab", t[1], "[data-set=%s]" % t[0])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(set_settings_page.bind(t[0]))

	# SKY
	var sky := _page(p, "sky")
	_note(sky, "Where you are looking from. The environments are POPULATIONS and they superpose — a globular cluster still has the galaxy behind it — so the weights add rather than crossfade. Shape (band thickness, bulge size, plane concentration) is the one galaxy you are in, so those take the weighted mean instead.")
	reg("skyEnvList", stack(sky))
	_set_row(sky, "skyTilt", "Plane tilt", "Tilt of the galactic plane relative to the scene. This places your VIEW of the galaxy, not you.",
		0, 1.57, 0.34, 0.01, "0.34", func(v): return U.fixed(v, 2))
	_set_row(sky, "skyRoll", "Plane roll", "Roll about the vertical. Swings the band round the horizon.",
		0, 6.28, 0.9, 0.01, "0.90", func(v): return U.fixed(v, 2))
	var adv_btn := m(B(sky, "Ghost", "Component amplitudes ▸", "skyAdvOpen"), 0.0, 10.0) as HudButton
	var adv := stack(sky)
	reg("skyAdv", adv)
	_hide(adv, "inline", true)
	adv_btn.pressed.connect(func():
		var open := not adv.visible
		_hide(adv, "inline", not open)
		adv_btn.set_label("Component amplitudes ▾" if open else "Component amplitudes ▸"))
	m(B(sky, "Ghost", "Reset to scenario’s sky", "skyReset"), 0.0, 10.0).pressed.connect(func(): sky_reset.emit())

	# RENDER
	var ren := _page(p, "render")
	_note(ren, "Choose a preset for frame rate and image quality. High adds photo-style craft and launchpad materials. Advanced controls expose resolution and post-processing settings.")
	_h3(ren, "Rendering quality")
	var quality_choices := grid(ren, [1.0, 1.0, 1.0], 6.0, 0.0, 0.0, 10.0)
	for q in [["low", "Low"], ["medium", "Medium"], ["high", "High"]]:
		B(quality_choices, "Toggle", q[1], "[data-render-quality=%s]" % q[0]).pressed.connect(func(): render_quality_chosen.emit(q[0]))
	var advanced_btn := B(ren, "Toggle", "☐ Advanced rendering controls", "renderAdvancedToggle")
	advanced_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var advanced := stack(ren, 10.0)
	reg("renderAdvanced", advanced)
	_hide(advanced, "inline", true)
	advanced_btn.pressed.connect(func():
		var on := not advanced.visible
		_hide(advanced, "inline", not on)
		advanced_btn.set_label("☑ Advanced rendering controls" if on else "☐ Advanced rendering controls")
		set_active("renderAdvancedToggle", on))
	_set_row(advanced, "renderScale", "Render scale", "Framebuffer scale. 1.5x draws 2.25 times as many pixels as 1.0x, subject to the display cap.",
		0.5, 2, 1, 0.05, "1.00x", func(v): return U.fixed(minf(_dpr(), v), 2) + "x")
	_set_row(advanced, "lensScale", "Lens detail", "Resolution of the black-hole geodesic marcher as a fraction of the display.",
		0.25, 1, 0.5, 0.05, "0.50x", func(v): return U.fixed(v, 2) + "x")
	_set_row(advanced, "fxBloom", "Bloom", "Strength of the bloom added back over the frame.", 0, 1.2, 0.55, 0.01, "0.55", func(v): return U.fixed(v, 2))
	_set_row(advanced, "fxThreshold", "Bloom threshold", "Luminance above which a pixel blooms.", 0, 4, 1, 0.05, "1.00", func(v): return U.fixed(v, 2))
	_set_row(advanced, "fxRadius", "Bloom radius", "Spread of the upsample filter.", 0.2, 2.5, 1, 0.05, "1.00", func(v): return U.fixed(v, 2))
	_set_row(advanced, "fxVignette", "Vignette", "Corner falloff.", 0, 1, 0.35, 0.01, "0.35", func(v): return U.fixed(v, 2))
	_set_row(advanced, "fxGrain", "Grain", "Sensor grain.", 0, 0.1, 0.02, 0.002, "0.020", func(v): return U.fixed(v, 3))
	_set_row(advanced, "fxExposure", "Exposure", "Camera exposure before the filmic tone curve. Flight receives a small daylight calibration.",
		0.5, 2.0, 1.0, 0.025, "1.00", func(v): return U.fixed(v, 2))
	_h3(ren, "Lighting detail")
	_note(ren, "Flight and the craft studio use shadow maps and screen-space lighting. Reflections apply to the craft studio only. These are not hardware ray tracing.")
	var lighting_choices := grid(ren, [1.0, 1.0, 1.0, 1.0], 6.0, 0.0, 0.0, 10.0)
	for q in [["low", "Low"], ["medium", "Medium"], ["high", "High"], ["custom", "Custom"]]:
		B(lighting_choices, "Toggle", q[1], "[data-lighting-quality=%s]" % q[0]).pressed.connect(func(): lighting_quality_chosen.emit(q[0]))
	var raw := grid(ren, [1.0, 1.0], 6.0, 6.0, 0.0, 10.0)
	reg("lightingRaw", raw)
	_hide(raw, "inline", true)
	for effect in [["shadows", "Shadows"], ["ao", "Ambient occlusion"], ["reflections", "Studio reflections"], ["indirect", "Indirect light"]]:
		B(raw, "Toggle", effect[1], "[data-light-effect=%s]" % effect[0]).pressed.connect(func(): lighting_effect_chosen.emit(effect[0]))
	_h3(ren, "Spacetime mesh")
	var mesh_choices := grid(ren, [1.0, 1.0], 6.0, 0.0, 0.0, 10.0)
	B(mesh_choices, "Toggle", "Connected grid", "[data-mesh-style=lines]").pressed.connect(func(): mesh_style_chosen.emit("lines"))
	B(mesh_choices, "Toggle", "Dots", "[data-mesh-style=dots]").pressed.connect(func(): mesh_style_chosen.emit("dots"))
	m(B(ren, "Ghost", "Reset rendering", "fxReset"), 0.0, 10.0).pressed.connect(func(): fx_reset.emit())

	# SIM
	var sim := _page(p, "sim")
	_rnote(sim, "The integrator is velocity-Verlet in AU, M[font_size=8]☉[/font_size] and years with [i]G[/i] = 4π². The step cap is the one setting that changes the ANSWER rather than the picture: a close pass is only resolved if the step is short compared with the time spent in it.")
	_set_row(sim, "maxStep", "Max step", "Longest integrator step, in years. Lower is more accurate and slower; too high and a close encounter is stepped straight over, which shows up as energy appearing from nowhere.",
		-5, -1, -2.3, 0.05, "5.0e-3 yr", func(v): return U.expo(pow(10.0, v), 1) + " yr")
	_set_row(sim, "gwBoost", "GW boost", "Multiplier on the gravitational-wave radiation reaction. 1 is the real rate; presets raise it so an inspiral that truly takes megayears is watchable. 0 turns the back-reaction off entirely.",
		0, 6, 0, 0.05, "off", func(v): return (U.fixed(v, 2) + "×") if v != 0.0 else "off")
	var sg := grid(sim, [1.0, 1.0], 10.0, 5.0, 10.0, 12.0)
	for kv in [["steps/frame", "setSteps"], ["energy drift", "setDrift"]]:
		_stat(sg, kv[0], kv[1])
	_note(sim, "Drift is the relative energy change since loading or a body-count change. For ordinary bodies with fixed masses and softening, it measures integration error. Black-hole and gravitational-wave scenarios show ≈ because their energy diagnostic is approximate. Edits and accretion also change the energy budget.")
	m(B(sim, "Ghost", "Reset to scenario’s values", "simReset"), 0.0, 10.0).pressed.connect(func(): sim_reset.emit())

	# CONTROLS
	var controls := _page(p, "controls")
	m(B(controls, "Ghost", "Quit to start", "quitToStart"), 0.0, 10.0).pressed.connect(func(): quit_to_start.emit())
	m(B(controls, "Action", "Quit app", "quitApp"), 8.0).pressed.connect(func(): quit_app.emit())
	_h3(controls, "App icon")
	var icon_choices := grid(controls, [1.0, 1.0], 6.0, 6.0, 0.0, 8.0)
	for icon in AppIcon.ICONS:
		var row := hbox(null, 8.0)
		var b := BoxButton.new("ToggleIcon", row)
		row.add_child(IconSwatch.new(AppIcon.thumb(icon[0], 56)))
		var l := L(row, icon[1], {"fs": 10.0, "ls": 1.0, "up": true, "c": T.TEXT_DIM})
		l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		b.tint(l)
		icon_choices.add_child(b)
		reg("[data-app-icon=%s]" % icon[0], b)
		b.pressed.connect(func(): app_icon_chosen.emit(icon[0]))
	_note(controls, "Mouse: drag to look or orbit, scroll to zoom, click to focus an object.")
	_note(controls, "Select a key to change it. Bindings are saved automatically. Esc always opens Settings.")
	reg("bindingList", stack(controls))
	m(B(controls, "Ghost", "Reset all bindings", "bindingsReset"), 0.0, 10.0).pressed.connect(func(): bindings_reset.emit())
	set_settings_page("sky")

func _page(p: HudPanel, page: String) -> HudStack:
	var s := HudStack.new(false)
	s.set_meta("page", page)
	p.body.add_child(s)
	_pages.append(s)
	return s

func _stat(parent: Node, k: String, id: String) -> HudRow:
	var cell := hbox(parent, 6.0)
	var kl := L(cell, k, STAT_K)
	kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var v := L(cell, "—", STAT_V, id)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return cell

func build_bindings(groups: Array, bindings: Dictionary) -> void:
	var host: HudStack = ids.bindingList
	_clear(host)
	binding_buttons.clear()
	for group in groups:
		_h3(host, group[0])
		for row in group[1]:
			var action: String = row[0]
			var line := hbox(host, 12.0, 0.0, 7.0)
			var l := L(line, row[1], {"fs": 10.0, "c": T.TEXT_DIM})
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var button := B(line, "Toggle", binding_label(bindings[action]), "[data-binding=%s]" % action)
			button.pressed.connect(_on_binding_pressed.bind(action))
			binding_buttons[action] = button

func _on_binding_pressed(action: String) -> void:
	binding_chosen.emit(action)

func binding_label(binding: Array) -> String:
	var key := OS.get_keycode_string(int(binding[0]))
	if key == "": key = str(binding[0])
	if int(binding[0]) == KEY_SHIFT or int(binding[0]) == KEY_CTRL or int(binding[0]) == KEY_ALT:
		return key
	return ("Ctrl + " if binding[2] else "") + ("Shift + " if binding[1] else "") + key

func show_binding_capture(action: String) -> void:
	if binding_buttons.has(action): binding_buttons[action].set_label("Press a key…")

func update_binding_labels(bindings: Dictionary) -> void:
	for id in binding_buttons:
		binding_buttons[id].set_label(binding_label(bindings[id]))

## Settings has four pages: sky, render, sim and controls.
func set_settings_page(page: String) -> void:
	for k in _pages:
		_hide(k, "inline", k.get_meta("page") != page)
	for t in ["sky", "render", "sim", "controls"]:
		for b in sels.get("[data-set=%s]" % t, []):
			b.set_active(t == page)

func _dpr() -> float:
	return get_window().content_scale_factor if is_inside_tree() else 1.0

## Free a container's children now (a rebuilt list must not be seen twice).
static func _clear(c: Node) -> void:
	for k in c.get_children():
		c.remove_child(k)
		k.queue_free()

# SCENARIO
var _search: LineEdit
var _search_clear: HudButton
var _preset_list: VBoxContainer
var _preset_empty: PanelContainer
var _preset_empty_label: Label

func _build_scenario() -> void:
	var p := _panel("scenarioPanel")
	scenario_panel = p
	_panel_head(p, "Scenario", "scenarioPanel")
	p.body.add_child(m(frame(L(null, "Black Hole Sandbox", {"fs": 12.0, "c": T.TEXT, "ls": 0.48}, "presetName"),
		{"bw": 0, "bb": 1, "bc": T.BORDER, "pad": [0, 0, 8, 0]}), -4.0, 9.0))
	_search = LineEdit.new()
	_search.placeholder_text = "Search scenarios / categories"
	_search.flat = false
	_search.focus_mode = Control.FOCUS_CLICK
	_search.caret_blink = true
	_search.context_menu_enabled = false
	_search.mouse_default_cursor_shape = Control.CURSOR_IBEAM
	m(_search, 0.0, 10.0)
	p.body.add_child(_search)
	reg("presetSearch", _search)
	_search.text_changed.connect(func(_t): _render_presets())
	_search_clear = B(_search, "Clear", "✕", "presetSearchClear")
	# inside the field's right padding, centred on it
	var place_clear := func():
		var s := _search_clear.get_combined_minimum_size()
		_search_clear.size = s
		_search_clear.position = Vector2(_search.size.x - 7.0 - s.x, roundf((_search.size.y - s.y) * 0.5))
	_search.resized.connect(place_clear)
	_search_clear.minimum_size_changed.connect(place_clear)
	_search_clear.pressed.connect(func():
		_search.text = ""
		_render_presets()
		_search.grab_focus())
	_preset_list = VBoxContainer.new()
	_preset_list.add_theme_constant_override("separation", 5)
	_preset_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.body.add_child(_preset_list)
	reg("presetList", _preset_list)
	var empty := L(null, "No matching scenarios", {"fs": 10.0, "c": T.TEXT_DIM, "fi": true}, "", true)
	_preset_empty_label = empty
	empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	T.unhang(empty)
	_preset_empty = frame(empty, {"bc": T.BORDER, "pad": [10, 8, 10, 8]})
	p.body.add_child(_preset_empty)
	reg("presetEmpty", _preset_empty)
	_hide(_preset_empty, "inline", true)
	var blurb := L(null, "", {"fs": 10.0, "lh": 1.55, "c": T.TEXT_DIM}, "blurb", true)
	p.body.add_child(m(frame(blurb, {"bw": 0, "bl": 2, "bc": T.ACCENT_2, "pad": [0, 0, 0, 8]}), 9.0))

# COURSE
func _build_course() -> void:
	var p := _panel("coursePanel")
	course_panel = p
	_panel_head(p, "Course", "coursePanel")
	reg("courseMount", stack(p.body))

# THE LESSON CARD frame: head, the text and instrument columns (which scroll when
# the card is at its height cap), and the foot with the step dots.
func _build_lesson_card() -> void:
	var c := HudPanel.new([13, 15, 11, 15], false, T.PANEL, T.BORDER_STRONG, 12.0)
	add_child(c)
	reg("lessonCard", c)
	lesson_card = c
	c.pad.minimum_size_changed.connect(_queue_layout)
	var head := hbox(c.body, 10.0, 0.0, 9.0)
	# the ✕ beside it has the deeper baseline, as in a panel head
	var hm := MarginContainer.new()
	hm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hm.add_theme_constant_override("margin_top", 3)
	hm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(hm)
	var hl := hbox(hm, 10.0)
	lc.crumb = label(hl, "", {"fs": 10.0, "c": T.ACCENT, "ls": 0.5, "up": true})
	lc.crumb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lc.crumb.clip_text = true
	lc.count = label(hl, "", {"fs": 10.0, "c": T.TEXT_DIM})
	lc.close = B(head, "PanelClose", "✕", "", "Leave this lesson")
	lc.close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	lc.close.pressed.connect(func(): lesson_close.emit())
	var cols := CardCols.new()
	_lc_scroll = CapScroll.new(1000.0, cols)
	c.body.add_child(m(_lc_scroll, 0.0, 9.0))
	lc.cols = _lc_scroll
	lc.main = cols.main
	lc.title = m(label(cols.main, "", {"ff": "disp", "fs": 16.0, "fw": 600, "c": T.hexc(0xe6ecf6)}, true), 0.0, 7.0)
	lc.text = HudStack.new(false)
	cols.main.add_child(lc.text)
	lc.media = cols.media
	_hide(lc.media, "inline", true)
	var foot := hbox(c.body, 12.0)
	lc.back = B(foot, "LcNav", "← Back")
	lc.back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lc.back.pressed.connect(func(): lesson_back.emit())
	lc.dots = hbox(foot, 5.0)
	lc.dots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lc.next = B(foot, "LcNext", "Next →")
	lc.next.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lc.next.pressed.connect(func(): lesson_next.emit())
	_mounts["lessonCard"] = c
	_hide(c, "inline", true)

## Text first, instrument second, as a wrapping flex row: side by side (bases 260
## and 240 px, growing 3 : 1) when both fit, else stacked, so the half on top is
## the half you have to read.
class CardCols extends Container:
	const GAP := 15.0
	var main := HudStack.new(false)
	var media := HudStack.new(false)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(main)
		add_child(media)

	func _rects(w: float) -> Array:
		var mh := main.get_combined_minimum_size().y
		if not media.visible:
			return [Rect2(0, 0, w, mh), Rect2(), mh]
		var dh := media.get_combined_minimum_size().y
		if w >= 260.0 + GAP + 240.0:
			var free := w - 260.0 - GAP - 240.0
			var mw := 260.0 + free * 0.75
			var h := maxf(mh, dh)
			return [Rect2(0, 0, mw, h), Rect2(mw + GAP, 0, w - mw - GAP, h), h]
		return [Rect2(0, 0, w, mh), Rect2(0, mh + GAP, w, dh), mh + GAP + dh]

	func _get_minimum_size() -> Vector2:
		return Vector2(0, _rects(size.x)[2])

	func _notification(what: int) -> void:
		if what == NOTIFICATION_SORT_CHILDREN:
			var r := _rects(size.x)
			fit_child_in_rect(main, r[0])
			if media.visible: fit_child_in_rect(media, r[1])

## Show the card with an instrument column or not.
func set_lesson_media(on: bool) -> void:
	_hide(lc.media, "inline", not on)

## A new step starts at the top of its text.
func lesson_scroll_top() -> void:
	_lc_scroll.scroll_vertical = 0

# CONTROLS
## groupControlSections: a heading that folds everything under it.
## `host` is the block the heading and body go in, `box` the control that shows
## or hides with the section's mode (the host itself, or its frame).
func _section(parent: Node, title: String, head_extra: Array = [], host: Node = null, kind := "SectionHead", box: Control = null) -> HudStack:
	var holder: Node = host if host else parent
	var row := hbox(null, 6.0)
	var head := BoxButton.new(kind, row)
	m(head, 0.0 if host else 20.0, 10.0)
	# a heading, not an inline button: its margins collapse with its neighbours'
	head.set_meta("block", true)
	var arrow := L(row, "▸", {"fs": 9.0, "c": T.TEXT_DIM})
	arrow.size_flags_vertical = Control.SIZE_SHRINK_END
	arrow.rotation_degrees = 90.0
	arrow.resized.connect(func(): arrow.pivot_offset = arrow.size * 0.5)
	var tl := head.tint(L(row, title, H3))
	tl.size_flags_vertical = Control.SIZE_SHRINK_END
	for r in head_extra:
		(r as Control).size_flags_vertical = Control.SIZE_SHRINK_END
		row.add_child(r)
	holder.add_child(head)
	var wrap := stack(holder)
	var sec := {"title": title, "head": head, "wrap": wrap, "host": box if box else host, "arrow": arrow, "label": tl, "open": true}
	sections.append(sec)
	head.pressed.connect(func(): set_section_open(sec, not sec.open))
	return wrap

func set_section_open(sec: Dictionary, open: bool) -> void:
	sec.open = open
	_hide(sec.wrap, "closed", not open)
	var a: Label = sec.arrow
	var tw := create_tween()
	tw.tween_property(a, "rotation_degrees", 90.0 if open else 0.0, 0.16)

func section(title: String) -> Dictionary:
	for s in sections:
		if s.title == title:
			return s
	return {}

## Section modes use a hide reason, not the element's own visibility, since the
## climate and focus blocks drive their own.
func apply_section_modes(mode: String) -> void:
	# Learn mode gets the sandbox's sections (lessons send you to them); only the
	# defaults differ.
	var effective := "sandbox" if mode == "learn" else mode
	for sec in sections:
		var want: String = SECTION_MODE.get(sec.title, "both")
		var show := want == "both" or want == effective
		var host: Control = sec.host if sec.host else sec.head
		_hide(host, "mode", not show)
		if not sec.host:
			_hide(sec.wrap, "mode", not show)
		if show:
			set_section_open(sec, (OPEN_BY_DEFAULT.get(mode, []) as Array).has(sec.title))

func _build_control_panel() -> void:
	var p := _panel("controlPanel")
	control_panel = p
	_panel_head(p, "Controls", "controlPanel")
	var b := p.body

	# Central Singularity
	var s := _section(b, "Central Singularity")
	reg("bhPanel", sections[-1].head)
	_row(s, "mass", "Mass (M☉)", "", 1, 50, 10, 0.1, "10.0", "massRow", func(v): return U.fixed(v, 1))
	_row(s, "disc", "Accretion Disc", "", 0, 1, 0.9, 0.01, "0.90", "discRow", func(v): return U.fixed(v, 2))
	_row(s, "temp", "Disc Temp", "", 0, 1, 0.6, 0.01, "0.60", "tempRow", func(v): return U.fixed(v, 2))

	# Suns
	s = _section(b, "Suns")
	reg("starPanel", sections[-1].head)
	var sl := VBoxContainer.new()
	sl.add_theme_constant_override("separation", 6)
	sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m(sl, 0.0, 14.0)
	s.add_child(sl)
	reg("sunList", sl)

	# Climate — a self-contained block, heading first
	var cp := stack(b)
	reg("climatePanel", cp)
	var clock := L(null, "0 yr", {"fs": 10.0, "c": T.ACCENT_2, "ls": 0.5}, "simClock")
	s = _section(b, "Climate", [clock], cp)
	var era: Dictionary = ERA["era-stable"]
	var badge_l := L(null, "Stable Era", {"fs": 12.0, "ls": 2.16, "up": true, "c": era.c}, "eraLabel")
	badge_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var badge := frame(badge_l, {"bc": era.c, "pad": [7, 7, 7, 7]})
	s.add_child(m(badge, 0.0, 4.0))
	reg("eraBadge", badge)
	m(L(s, "", {"fs": 10.0, "c": T.TEXT_DIM, "lh": 1.5}, "eraDesc", true), 0.0, 10.0)
	var chart := ClimateChart.new()
	s.add_child(chart)
	reg("climateChart", chart)
	var key := hbox(s, 12.0, 5.0, 10.0)
	for kk in [[T.hexc(0xff6a5a), "surface temp"], [T.rgba(255, 190, 90, 0.8), "insolation"]]:
		var item := hbox(key, 4.0)
		var sw := ColorRect.new()
		sw.color = kk[0]
		sw.custom_minimum_size = Vector2(9, 2)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		item.add_child(sw)
		L(item, kk[1], {"fs": 9.0, "c": T.TEXT_DIM})
	var sg := grid(s, [1.0, 1.0], 10.0, 5.0, 0.0, 12.0)
	for kv in [["temp", "cTemp"], ["flux", "cFlux"], ["ice", "cIce"], ["cloud", "cCloud"], ["τ response", "cTau"], ["range", "cExtremes"]]:
		_stat(sg, kv[0], kv[1])
	_row(s, "mixed", "Ocean depth", "Depth of the ocean mixed layer — the planet's thermal flywheel. Shallow oceans let the temperature whip around with the orbit; deep ones damp it.",
		2, 120, 12, 1, "12 m", "", func(v): return U.fixed(v, 0) + " m")
	_row(s, "greenhouse", "Greenhouse ε", "Effective emissivity. Lower = stronger greenhouse = warmer world. 0.61 reproduces Earth.",
		0.3, 1, 0.61, 0.01, "0.61", "", func(v): return U.fixed(v, 2))
	m(B(s, "Ghost", "Reset Climate to 15 °C", "climateReset"), 0.0, 10.0).pressed.connect(func(): climate_reset.emit())
	_hide(cp, "inline", true)

	# Imaging Band
	s = _section(b, "Imaging Band")
	reg("bandGrid", grid(s, [1.0, 1.0, 1.0, 1.0], 4.0, 4.0))
	var bn := L(null, "", {"fs": 9.5, "lh": 1.55, "c": T.TEXT_DIM}, "bandNote", true)
	s.add_child(m(frame(bn, {"bw": 0, "bl": 2, "bc": T.BORDER_STRONG, "pad": [0, 0, 0, 8]}), 8.0))

	# View & Camera
	s = _section(b, "View & Camera")
	var tr := grid(s, [1.0, 1.0], 6.0, 6.0, 0.0, 8.0)
	for v in [["mesh", "Mesh ON"], ["lens", "Lens ON"]]:
		var bt := B(tr, "Toggle", v[1], "[data-view=%s]" % v[0])
		bt.set_active(true)
		bt.pressed.connect(func(): view_toggle.emit(v[0]))
	tr = grid(s, [1.0, 1.0], 6.0, 6.0, 0.0, 8.0)
	B(tr, "Toggle", "Sizes: Boosted", "[data-view=scale]",
		"Real: bodies are drawn at their true physical radius, so a planet is a point of light until you fly to it. Boosted: radii are exaggerated so the system is readable at a glance.").pressed.connect(func(): view_toggle.emit("scale"))
	tr = grid(s, [1.0, 1.0], 6.0, 6.0, 0.0, 8.0)
	var bo := B(tr, "Toggle", "Orbit", "camOrbit")
	bo.set_active(true)
	bo.pressed.connect(func(): cam_mode.emit("orbit"))
	B(tr, "Toggle", "Free Fly", "camFree").pressed.connect(func(): cam_mode.emit("free"))
	var bs := B(tr, "Toggle", "Stand on it", "camSurface")
	bs.pressed.connect(func(): cam_mode.emit("surface"))
	_hide(bs, "inline", true)
	m(B(s, "Ghost", "Reset View", "resetView"), 0.0, 10.0).pressed.connect(func(): reset_view.emit())
	_rnote(s, "Render scale and lens detail moved to [b]Settings › Render[/b], top left — they are properties of the renderer rather than of this view, and they survive a scenario change.")
	var sky_row := stack(s)
	reg("skyRow", sky_row)
	_row(sky_row, "lat", "Latitude", "Where on the planet you are standing. High latitudes see the suns skim the horizon.",
		-80, 80, 22, 1, "22°", "", func(v): return str(int(U.jround(v))) + "°")
	_row(sky_row, "daylen", "Day length", "Length of the planet's rotation period. Shorter = the suns race across the sky.",
		0.5, 30, 4.06, 0.1, "4.1 d", "", func(v): return U.fixed(v, 1) + " d")
	_hide(sky_row, "inline", true)

	# Time
	s = _section(b, "Time")
	var tg := grid(s, [1.0, 1.0, 1.0, 1.0], 4.0, 4.0, 0.0, 12.0)
	for t in [["sunset", "Sunset", "A single sunset, at a watchable pace. One rotation ≈ 45 s."],
			["day", "Days", "Days flick past. One rotation ≈ 8 s."],
			["season", "Seasons", "One orbit ≈ 90 s — watch a Chaotic Era arrive."],
			["era", "Eras", "Centuries per minute — the long climate record."]]:
		B(tg, "TimeBtn", t[1], "[data-time=%s]" % t[0], t[2]).pressed.connect(func(): time_regime.emit(t[0]))
	_row(s, "timescale", "Time scale", "Simulated years per real second.", -5, 1.3, -0.46, 0.01, "0.35 yr/s", "",
		func(v): return time_label(clampf(pow(10.0, v), 1e-5, 20.0)))
	_row(s, "speed", "Sim Speed", "", 0, 4, 1, 0.05, "1.00", "", func(v): return U.fixed(v, 2))

	# Focused Object — self-contained
	var fstack := HudStack.new(false)
	var fp := frame(fstack, {"bc": T.ACCENT_2, "pad": [10, 10, 10, 10]})
	b.add_child(m(fp, 18.0))
	reg("focusPanel", fp)
	s = _section(b, "Focused Object", [], fstack, "SectionHeadFocus", fp)
	m(sections[-1].head, 0.0, 8.0)
	m(L(s, "—", {"fs": 11.0, "c": T.TEXT, "ls": 0.55}, "focusName"), 0.0, 8.0)
	m(B(s, "Ghost", "Cross-section & edit ▸", "xsecOpen"), 0.0, 10.0).pressed.connect(func(): xsec_open.emit())
	B(s, "Action", "Delete Object", "delFocus").pressed.connect(func(): delete_focus.emit())
	_hide(fp, "inline", true)

	# Object Foundry
	s = _section(b, "Object Foundry")
	_note(s, "Four inputs, no menu of outcomes. Everything below — the size, the colour, the shape, the verdict — is derived from mass, spin, composition and age by the same interior model the rest of the sim runs on.")
	reg("foundry", stack(s))

	# Painter
	s = _section(b, "Painter")
	_note(s, "Adds the things that are made of too many pieces to integrate — rings, belts, ejecta. They are test particles on real Keplerian orbits, so a ring shears the way a ring does and a belt has its resonance gaps. Acts on the focused body.")
	var ag := grid(s, [1.0, 1.0], 6.0, 6.0)
	for pt in [["ring", "◎", "Ring", "A ring can only exist INSIDE the Roche limit, where tides beat self-gravity and the material cannot collect into a moon. The span is computed from the body's own density, not chosen."],
			["belt", "⋰", "Belt", "An asteroid belt, with Kirkwood gaps cleared at the 3:1, 5:2, 7:3 and 2:1 resonances with the next body out."],
			["cloud", "◍", "Ejecta", "An expanding shell of ejecta. Optically thin, so it limb-brightens into a rim, and homologous, so it expands without changing shape."],
			["clear", "✕", "Clear paint", ""]]:
		_add_btn(ag, pt[1], pt[2], "[data-paint=%s]" % pt[0], pt[3]).pressed.connect(func(): paint.emit(pt[0]))

	# Spaceflight
	s = _section(b, "Spaceflight")
	_rnote(s, "Real vehicles, real stage masses, real engines. A stage's Δv is computed from its own dry and propellant mass, so if a rocket cannot reach orbit here it could not reach orbit. Time runs [b]1:1[/b] — one second per second — until you warp it yourself.")
	reg("craftGrid", grid(s, [1.0, 1.0], 5.0, 5.0, 8.0, 4.0))
	m(B(s, "Ghost", "Model viewer ▸", "modelOpen"), 0.0, 10.0).pressed.connect(func(): model_open.emit())
	var fr := grid(s, [1.0, 1.0], 6.0, 6.0, 0.0, 8.0)
	reg("flightRow", fr)
	B(fr, "Toggle", "Cam: Chase", "flightCam", "Chase · Orbit · Cockpit · Pad").pressed.connect(func(): flight_cam_cycle.emit())
	B(fr, "Toggle", "Exit flight", "flightExit").pressed.connect(func(): flight_exit.emit())
	_hide(fr, "inline", true)

	# Quick Spawn
	s = _section(b, "Quick Spawn")
	tr = grid(s, [1.0, 1.0], 6.0, 6.0, 0.0, 8.0)
	B(tr, "Toggle", "Spawn: In orbit", "[data-view=spawnrest]",
		"At rest: a new body is placed where you are looking with exactly zero velocity, and only moves if gravity moves it. In orbit: it arrives on a circular orbit about the heaviest body present, which is the only start that does not immediately fall in.") \
		.pressed.connect(func(): view_toggle.emit("spawnrest"))
	ag = grid(s, [1.0, 1.0], 6.0, 6.0)
	for sp in [["planet", "·", "Rocky Planet"], ["gas-giant", "○", "Gas Giant"], ["star", "☉", "Star"], ["neutron", "◉", "Neutron Star"]]:
		_add_btn(ag, sp[1], sp[2], "[data-spawn=%s]" % sp[0]).pressed.connect(func(): spawn.emit(sp[0]))
	m(B(s, "Action", "Clear All Bodies", "clear"), 8.0).pressed.connect(func(): clear_bodies.emit())

	# Bodies
	var count := L(null, "(0)", {"fs": 10.0, "ls": 2.0, "c": T.ACCENT}, "count")
	s = _section(b, "Bodies", [count])
	var list := CapScroll.new(148.0, VBoxContainer.new())
	(list.content as VBoxContainer).add_theme_constant_override("separation", 0)
	s.add_child(frame(list, {"bc": T.BORDER}))
	reg("bodyList", list.content)
	render_body_list([], -1)

func _add_btn(parent: Node, sym: String, label: String, sel: String, tip := "") -> BoxButton:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	var b := BoxButton.new("Add", col, tip)
	var sl := L(col, sym, {"fs": 16.0, "c": T.ACCENT})
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var ll := b.tint(L(col, label, {"fs": 10.0, "ls": 0.8, "up": true, "c": T.TEXT}))
	ll.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(b)
	reg(sel, b)
	return b

# MODEL VIEWER
func _build_model_panel() -> void:
	var p := _panel("modelPanel")
	model_panel = p
	var head := _panel_head(p, "Model viewer", "modelPanel", "Close")
	reg("modelClose", head.get_child(1))
	m(L(p.body, "—", {"fs": 14.0, "c": T.ACCENT, "ls": 0.56}, "mvName"), 0.0, 10.0)
	reg("mvGrid", grid(p.body, [1.0, 1.0], 4.0, 4.0, 0.0, 12.0))
	var mc := HudStack.new(false)
	p.body.add_child(m(frame(mc, {"bw": 0, "bt": 1, "bc": T.BORDER, "pad": [10, 0, 0, 0]}), 0.0, 10.0))
	var sl := hbox(mc, 8.0, 0.0, 8.0)
	var el := L(sl, "Exploded", {"fs": 10.0, "c": T.TEXT_DIM})
	el.custom_minimum_size.x = 62.0
	var r := _range(sl, "mvExplode", 0, 1, 0, 0.01)
	r.inset = 2.0
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tr := grid(mc, [1.0, 1.0], 6.0, 6.0, 0.0, 8.0)
	var dep := B(tr, "ToggleFlat", "Deployed", "mvDeploy", "Legs, fins, arrays and radiators in their deployed position")
	dep.set_active(true)
	dep.pressed.connect(func():
		dep.set_active(not dep.active)
		model_deploy.emit(dep.active))
	var spin := B(tr, "ToggleFlat", "Turntable", "mvSpin", "Idle turntable")
	spin.pressed.connect(func():
		spin.set_active(not spin.active)
		model_spin.emit(spin.active))
	var bg := B(tr, "ToggleFlat", "Light", "mvLight", "Light backdrop instead of the dark studio")
	bg.pressed.connect(func():
		bg.set_active(not bg.active)
		model_backdrop.emit(bg.active))
	reg("mvList", grid(p.body, [1.0, 1.0], 10.0, 3.0, 0.0, 12.0))
	reg("mvStages", stack(p.body))
	m(B(p.body, "Action", "Fly this vehicle", "mvFly"), 8.0).pressed.connect(func(): model_fly.emit())
	_hide(p, "inline", true)

# CROSS-SECTION frame
func _build_xsec_panel() -> void:
	var p := _panel("xsecPanel")
	xsec_panel = p
	_panel_head(p, "Cross-section", "xsecPanel", "Close")
	m(L(p.body, "—", {"fs": 11.0, "c": T.ACCENT, "ls": 0.88, "up": true}, "xsecName"), 0.0, 8.0)
	# the live editor's box: a 1 px border with a 2 px accent rule down its left
	var ed := HudStack.new(false)
	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in [["margin_top", 9], ["margin_right", 10], ["margin_bottom", 2], ["margin_left", 10]]:
		pad.add_theme_constant_override(side[0], side[1])
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(ed)
	var rule := ColorRect.new()
	rule.color = T.ACCENT
	rule.custom_minimum_size.x = 2.0
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := hbox(null, 0.0)
	row.add_child(rule)
	row.add_child(pad)
	var box := frame(row, {"bg": Color(1, 1, 1, 0.02), "bc": T.BORDER, "bl": 0})
	p.body.add_child(m(box, 0.0, 10.0))
	reg("xsecEdit", box)
	_note(ed, "Editing is the same operation as building — the object is re-derived and its limits rechecked immediately. The curve is R(M) for this body's own composition and spin; drag the handle along it. Dashed lines are where the model changes its mind about what this is.", 9.0)
	reg("liveEdit", stack(ed))
	# the inspector builds its canvas, legend, verdict, facts and notes in here
	reg("xsecCanvas", stack(p.body))

# FLIGHT frame
func _build_flight_panel() -> void:
	var p := _panel("flightPanel", [16, 16, 16, 16])
	flight_panel = p
	var head := hbox(p.body, 8.0)
	head.add_child(_head_title("Flight"))
	var warp := hbox(head, 4.0)
	warp.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var wd := B(warp, "Warp", "◂", "[data-warp=-1]", "Slow time (,)")
	wd.custom_minimum_size = Vector2(20, 18)
	wd.pressed.connect(func(): warp_step.emit(-1))
	var wl := L(warp, "1×", {"fs": 11.0, "c": T.ACCENT}, "warpLabel")
	wl.custom_minimum_size.x = 46.0
	wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var wu := B(warp, "Warp", "▸", "[data-warp=1]", "Speed time (.)")
	wu.custom_minimum_size = Vector2(20, 18)
	wu.pressed.connect(func(): warp_step.emit(1))
	var gap := Control.new()
	gap.custom_minimum_size.x = 6.0
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	warp.add_child(gap)
	var x := B(head, "PanelClose", "✕", "", "Collapse")
	x.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	x.pressed.connect(func(): set_panel_open("flightPanel", false))
	reg("flightHud", stack(p.body))

# tabs
func _tab(text: String, id: String) -> HudButton:
	var b := HudButton.new("PanelTab", text)
	HudBlur.attach(b, T.PANEL, 10.0)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reg("[data-open=%s]" % id, b)
	b.pressed.connect(func(): set_panel_open(id, true))
	tabs[id] = b
	_hide(b, "inline", true)
	return b

func _build_tabs() -> void:
	tab_col = VBoxContainer.new()
	tab_col.add_theme_constant_override("separation", 6)
	tab_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tab_col)
	for t in [["scenarioPanel", "▸ Scenario"], ["coursePanel", "▸ Course"], ["flightPanel", "▸ Flight"]]:
		tab_col.add_child(_tab(t[1], t[0]))
	tab_col.minimum_size_changed.connect(_queue_layout)
	tab_right = _tab("Controls ◂", "controlPanel")
	add_child(tab_right)

# readout
func _build_readout() -> void:
	readout = VBoxContainer.new()
	readout.add_theme_constant_override("separation", 0)
	readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(readout)
	reg("readout", readout)
	var dim := {"fs": 10.0, "c": T.TEXT_DIM, "lh": 1.7, "ls": 0.8}
	var v := U.merged(dim, {"c": T.ACCENT_2})
	for line in [[["band ", dim], ["VIS", v, "bandLabel"], [" · ", dim], ["0.00", v, "rs"], [" r_s AU · ISCO ", dim], ["0.00", v, "isco"]],
			[["bodies ", dim], ["0", v, "bc"], [" consumed ", dim], ["0", v, "cc"]],
			[["fps ", dim], ["--", v, "fps"]]]:
		var row := hbox(readout, 0.0)
		for run in line:
			L(row, run[0], run[1], run[2] if run.size() > 2 else "")
	readout.minimum_size_changed.connect(_queue_layout)

# START SCREEN
func _build_start() -> void:
	start_screen = Control.new()
	start_screen.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(start_screen)
	reg("startScreen", start_screen)
	_start_inner = VBoxContainer.new()
	_start_inner.add_theme_constant_override("separation", 30)
	_start_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	start_screen.add_child(_start_inner)
	var title := L(_start_inner, "ASTRARIUM", {"ff": "mono", "fw": 700, "fs": 42.0, "lh": 1.2, "ls": 9.24, "c": T.hexc(0xdfe6f0)})
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	start_cards = HudGrid.new([1.0, 1.0, 1.0], 16.0, 16.0)
	_start_inner.add_child(start_cards)
	_start_inner.minimum_size_changed.connect(_queue_layout)
	for c in [["sandbox", "Sandbox", "Build and break systems. N-body gravity, real interiors, black holes, climate, and the imaging bands to look at it all in."],
			["learn", "Learn astronomy", "A beginner’s course, thirty-five lessons, built on the same physics as the rest of this. Seasons and moon phases through to gravitational waves — in order, or jump to what you came for."],
			["flight", "Spaceflight", "Fly real vehicles off a real pad. Staging, guidance, landings, time dilation — and a model viewer to see what you are flying."]]:
		var col := HudStack.new(false)
		var card := BoxButton.new("Start", col)
		# a block button centres its content in the row's height
		card.center = true
		card.set_meta("start", c[0])
		col.add_child(m(StartIcon.new(c[0]), 0.0, 14.0))
		m(L(col, c[1], {"fs": 15.0, "ls": 0.9, "c": T.hexc(0xe6ecf4)}), 0.0, 8.0)
		L(col, c[2], {"fs": 11.0, "lh": 1.65, "c": T.TEXT_DIM}, "", true)
		start_cards.add_child(card)
		reg("[data-start=%s]" % c[0], card)
		card.pressed.connect(func(): start_chosen.emit(c[0]))

## Fade the start screen out (opacity and a 3% scale over 0.4 s), then remove it.
func dismiss_start() -> void:
	if not start_screen.visible:
		return
	_start_generation += 1
	var generation := _start_generation
	# the cards fade out with it and must not take a click while they do
	start_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	start_screen.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
	start_screen.pivot_offset = size * 0.5
	if _start_tween: _start_tween.kill()
	_start_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_start_tween.tween_property(start_screen, "modulate:a", 0.0, 0.4)
	_start_tween.tween_property(start_screen, "scale", Vector2(1.03, 1.03), 0.4)
	get_tree().create_timer(0.42).timeout.connect(func():
		if generation == _start_generation: start_screen.visible = false)

func show_start() -> void:
	_start_generation += 1
	if _start_tween: _start_tween.kill()
	start_screen.visible = true
	start_screen.modulate.a = 1.0
	start_screen.scale = Vector2.ONE
	start_screen.mouse_filter = Control.MOUSE_FILTER_STOP
	start_screen.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED
	_queue_layout()

func set_settings_open(open: bool) -> void:
	settings_open = open
	settings_backdrop.visible = open
	set_panel_open("settingsPanel", open)

# toast
func _build_toast() -> void:
	_toast_label = Label.new()
	var st := {"fs": 10.0, "ls": 1.4, "up": true, "c": T.TEXT}
	_toast_label.set_meta("st", st)
	T.apply_label(_toast_label, st)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_el = frame(_toast_label, {"bg": T.CLEAR if HudBlur.enabled else T.PANEL, "bc": T.BORDER_STRONG, "pad": [9, 16, 9, 16]})
	HudBlur.attach(toast_el, T.PANEL, 10.0)
	toast_el.modulate.a = 0.0
	add_child(toast_el)
	toast_el.minimum_size_changed.connect(_queue_layout)
	reg("toast", _toast_label)

## Transient message, at the top of the free band between the panels.
func toast(msg: String, ms := 2200) -> void:
	_toast_label.text = msg
	_layout_all()
	if _toast_tween: _toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(toast_el, "modulate:a", 1.0, 0.35)
	_toast_timer = ms / 1000.0

# VISIBILITY

## An element can be hidden for several independent reasons (inline, mode, folded
## section) and shows only when none holds, so no writer undoes another's.
func _hide(e: Control, why: String, hidden: bool) -> void:
	if not hidden_flags.has(e):
		for k in hidden_flags.keys():
			if not is_instance_valid(k): hidden_flags.erase(k)
		hidden_flags[e] = {}
	hidden_flags[e][why] = hidden
	var vis := true
	for k in hidden_flags[e]:
		if hidden_flags[e][k]:
			vis = false
	if e.visible != vis:
		e.visible = vis
		_queue_layout()

func _apply_body_classes() -> void:
	var fl := body.has("flight-mode")
	var le := body.has("learn-mode")
	var mo := body.has("model-open")
	var hh := body.has("hud-hidden")
	for r in [scenario_panel, course_panel, lesson_card, control_panel, model_panel, xsec_panel, flight_panel, tab_col, tab_right, readout]:
		_hide(r, "hud", hh)
	# In flight mode the orrery's own instruments are gone, not folded: the
	# scenario list, its tab and the cross-section.
	_hide(scenario_panel, "cls", fl or le)
	_hide(xsec_panel, "cls", fl)
	_hide(tabs.scenarioPanel, "cls", fl or le)
	# ...and the flight panel's tab has nothing to reopen in the sandbox.
	_hide(tabs.flightPanel, "cls", not fl)
	_hide(course_panel, "cls", not le)
	_hide(tabs.coursePanel, "cls", not le)
	# The model viewer takes the frame, tabs included.
	_hide(tab_col, "cls", mo)
	_hide(tab_right, "cls", mo)

func _set_body(cls: String, on: bool) -> void:
	if on: body[cls] = true
	else: body.erase(cls)

# THE ORCHESTRATOR's API

## A panel's own collapsed state, and the tab it leaves behind.
func set_panel_open(id: String, open: bool) -> void:
	if id == "settingsPanel":
		settings_open = open
		settings_backdrop.visible = open
	var p: Control = ids.get(id)
	if p == null:
		return
	if open: collapsed.erase(id)
	else: collapsed[id] = true
	_hide(p, "inline", not open)
	if tabs.has(id):
		_hide(tabs[id], "inline", open)
	if id == "controlPanel":
		_set_body("panel-open-right", open)
	if id == "xsecPanel":
		_set_body("xsec-open", open)
	_queue_layout()
	panel_changed.emit(id, open)

func is_collapsed(id: String) -> bool:
	return collapsed.has(id)

## The section filter for a mode. Which panels a mode opens stays with the
## orchestrator (it calls set_panel_open).
func set_app_mode(mode: String) -> void:
	app_mode = mode
	apply_section_modes(mode)
	_set_body("flight-mode", mode == "flight")
	_set_body("learn-mode", mode == "learn")
	_apply_body_classes()

## The studio takes the frame, and the tabs go with it.
func set_model_open(on: bool) -> void:
	_set_body("model-open", on)
	_apply_body_classes()

## H hides the HUD. One flag, so every panel keeps the state that IS its collapsed
## state and comes back exactly as it was.
func set_hud_hidden(hidden: bool) -> void:
	hud_hidden = hidden
	_set_body("hud-hidden", hidden)
	_apply_body_classes()

func mount(n: String) -> Control:
	return _mounts.get(n, ids.get(n))

func get_el(id: String) -> Control:
	return ids.get(id)

func _targets(sel: String) -> Array:
	var s := sel.replace("\"", "").replace("'", "")
	if s.begins_with("#"): s = s.substr(1)
	var out: Array = []
	for e in sels.get(s, []):
		if is_instance_valid(e): out.append(e)
	return out

## Text of any element by id — including every "<range>-val".
func set_text(id: String, text: String) -> void:
	for e in _targets(id):
		if e is HudButton:
			(e as HudButton).set_label(text)
		elif e is Prose:
			(e as Prose).say(text)
		elif e is Prose.Rich:
			(e as Prose.Rich).say(text)
		elif e is Label:
			if (e as Label).text != text: (e as Label).text = text
		elif e is RichTextLabel:
			(e as RichTextLabel).text = text

func set_shown(id: String, shown: bool) -> void:
	for e in _targets(id):
		_hide(e, "inline", not shown)
	if id == "modelPanel" or id == "xsecPanel" or id == "flightPanel":
		if shown: collapsed.erase(id)
		else: collapsed[id] = true

## A button's active state, by id or by "[data-x=v]".
func set_active(sel: String, on: bool) -> void:
	for e in _targets(sel):
		if e is HudButton:
			(e as HudButton).set_active(on)

func set_button_text(sel: String, text: String) -> void:
	for e in _targets(sel):
		if e is HudButton: (e as HudButton).set_label(text)

## A range input's value, WITHOUT an input event (the orchestrator's own write).
func set_slider(id: String, value: float, label_text = null) -> void:
	var r: HudSlider = sliders.get(id)
	if r: r.set_v(value)
	if label_text != null:
		set_text(id + "-val", str(label_text))

## Move a slider AS IF the user had — the learner sees it move and every downstream
## binding fires.
func drive_slider(id: String, value: float) -> void:
	var r: HudSlider = sliders.get(id)
	if r == null:
		return
	r.set_v(value)
	_on_slider(r.value, id)

func get_slider(id: String) -> float:
	var r: HudSlider = sliders.get(id)
	return r.value if r else 0.0

## The step counter goes red, and says why, when the integrator hit its guard.
func set_warn(id: String, on: bool, tooltip := "") -> void:
	for e in _targets(id):
		if e is Label:
			var st: Dictionary = (e.get_meta("st", STAT_V) as Dictionary).duplicate()
			st.c = T.WARN if on else STAT_V.c
			T.apply_label(e, st)
		e.tooltip_text = tooltip
		e.mouse_filter = Control.MOUSE_FILTER_PASS if tooltip != "" else Control.MOUSE_FILTER_IGNORE

## The display half of the sim stats: steps (capped at the guard) and drift.
func set_sim_stats(steps: int, drift_rel: float) -> void:
	var capped := steps >= STEP_GUARD
	set_text("setSteps", ("%d capped" % steps) if capped else str(steps))
	set_warn("setSteps", capped, "The integrator hit its 8000 sub-step guard. The answer is still correct — it advances the clock by what it actually integrated — but simulated time is now running slower than the Time panel says. Raise the step cap." if capped else "")
	set_text("setDrift", "0" if drift_rel < 1e-12 else U.expo(drift_rel, 1))

func pointer_over_ui() -> bool:
	var h := get_viewport().gui_get_hovered_control()
	return h != null and h != self and is_ancestor_of(h)

# presets
func render_preset_groups(groups: Array, presets: Dictionary, active_key: String) -> void:
	_groups = groups
	_presets = presets
	_active_preset = active_key
	_render_presets()

## Preset groups. Search owns the open state while active; hand-opened groups are
## remembered when the query clears.
func _render_presets() -> void:
	var q := _search.text.strip_edges().to_lower()
	var searching := q.length() > 0
	_clear(_preset_list)
	for sel in sels.keys():
		if str(sel).begins_with("[data-preset=") or str(sel).begins_with("[data-group="):
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
		var det := VBoxContainer.new()
		det.add_theme_constant_override("separation", 0)
		_preset_list.add_child(frame(det, {"bc": T.BORDER}))
		var row := hbox(null, 7.0)
		var summ := BoxButton.new("GroupHead", row)
		summ.set_active(open)
		var mk := L(row, "▾" if open else "▸", {"fs": 11.0, "lh": 1.0, "c": T.ACCENT if open else T.ACCENT_2})
		mk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var tl := summ.tint(L(row, g.label, {"fs": 10.0, "ls": 1.0, "up": true, "c": T.TEXT_DIM}, "", true))
		tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var cl := L(row, cnt, {"fs": 9.0, "ls": 0.36, "c": T.TEXT_DIM})
		cl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		det.add_child(summ)
		reg("[data-group=%s]" % gid, summ)
		var items := VBoxContainer.new()
		items.add_theme_constant_override("separation", 5)
		items.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var pad := MarginContainer.new()
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for side in ["margin_top", "margin_right", "margin_bottom", "margin_left"]:
			pad.add_theme_constant_override(side, 5)
		pad.add_child(items)
		det.add_child(pad)
		pad.visible = open
		for key in keys:
			var tri: bool = gid == "trisolaris"
			var b := B(items, "PresetTri" if tri else "Preset", _presets.get(key, {}).get("name", key), "[data-preset=%s]" % key)
			b.set_active(key == _active_preset)
			b.pressed.connect(func(): preset_chosen.emit(key))
		summ.pressed.connect(func():
			if searching:
				return
			if _open_groups.has(gid): _open_groups.erase(gid)
			else: _open_groups[gid] = true
			_render_presets.call_deferred())
	_hide(_preset_list, "inline", visible_groups == 0)
	_hide(_preset_empty, "inline", visible_groups != 0)
	if searching:
		(_preset_empty_label as Prose).say("No scenarios or categories match \"%s\"" % _search.text.strip_edges())
	_hide(_search_clear, "inline", not searching)

## Mark the running scenario in the list.
func set_active_preset(key: String) -> void:
	_active_preset = key
	for sel in sels.keys():
		if str(sel).begins_with("[data-preset="):
			var k := str(sel).trim_prefix("[data-preset=").trim_suffix("]")
			for b in sels[sel]:
				if is_instance_valid(b): b.set_active(k == key)

func open_preset_group(gid: String, open := true) -> void:
	if open: _open_groups[gid] = true
	else: _open_groups.erase(gid)
	_render_presets()

func set_search(text: String) -> void:
	_search.text = text
	_render_presets()

# the body list
func render_body_list(bodies: Array, focus_id) -> void:
	var list: VBoxContainer = ids.bodyList
	_clear(list)
	if bodies.is_empty():
		var e := L(null, "— empty —", {"fs": 10.0, "c": T.TEXT_DIM, "fi": true})
		e.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		list.add_child(frame(e, {"bw": 0, "pad": [10, 10, 10, 10]}))
		return
	for i in bodies.size():
		var bd: Dictionary = bodies[i]
		var bid: int = bd.id
		var row := hbox(null, 6.0)
		var it := BoxButton.new("BodyItemLast" if i == bodies.size() - 1 else "BodyItem", row)
		it.set_active(focus_id != null and int(focus_id) == bid)
		it.pressed.connect(func(): body_focus.emit(bid))
		var nl := L(row, "#%d %s" % [bid, bd.name], {"fs": 10.0, "c": T.TEXT_DIM, "ls": 1.0})
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		nl.clip_text = true
		var rm := B(row, "Remove", "✕")
		rm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		rm.pressed.connect(func(): body_remove.emit(bid))
		list.add_child(it)

# suns
## A sun's colour dot with its glow (box-shadow 0 0 8px), level with the name line.
class SunDot extends Control:
	var col := Color.WHITE
	func _init() -> void:
		custom_minimum_size = Vector2(10, 13)
		size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var c := Vector2(4.5, 6.5)
		for i in 8:
			var t := (i + 1) / 8.0
			draw_circle(c, 4.5 + 8.0 * t, Color(col, 0.16 * (1.0 - t) * (1.0 - t)), true, -1.0, true)
		draw_circle(c, 4.5, col, true, -1.0, true)

## rows: [{name, cls, mass, teff, dist_au, intensity, color (LINEAR), flaring}]
func render_sun_list(rows: Array) -> void:
	var list: VBoxContainer = ids.sunList
	while _sun_rows.size() < rows.size():
		var h := hbox(null, 8.0)
		var fr := frame(h, {"bg": Color(1, 1, 1, 0.015), "bc": T.BORDER, "pad": [6, 8, 6, 8]})
		list.add_child(fr)
		var dot := SunDot.new()
		h.add_child(dot)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 1)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(col)
		var sn := L(col, "", {"fs": 11.0, "c": T.TEXT, "ls": 0.44})
		var sc := L(col, "", {"fs": 9.5, "c": T.TEXT_DIM})
		var fl := hbox(col, 4.0)
		var sf := L(fl, "", {"fs": 9.5, "c": T.ACCENT_2})
		var fb := frame(L(null, "FLARE", {"fs": 8.5, "ls": 0.85, "c": Color.BLACK}), {"bg": T.hexc(0xffcc44), "bw": 0, "pad": [0, 4, 0, 4]})
		fb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		fl.add_child(fb)
		_sun_rows.append([fr, dot, sn, sc, sf, fb])
	for i in _sun_rows.size():
		var r: Array = _sun_rows[i]
		var on := i < rows.size()
		_hide(r[0], "inline", not on)
		if not on:
			continue
		var s: Dictionary = rows[i]
		# the sun's colour is linear; Controls take sRGB
		var css := Color.html(U.css_of(s.color))
		if (r[1] as SunDot).col != css:
			(r[1] as SunDot).col = css
			(r[1] as SunDot).queue_redraw()
		_set_label(r[2], str(s.name))
		_set_label(r[3], "%s · %s M☉ · %d K" % [s.get("cls", ""), U.fixed(float(s.mass), 2), int(U.jround(float(s.teff)))])
		_set_label(r[4], "%s AU · %s S⊕" % [U.fixed(float(s.dist_au), 2), U.fixed(float(s.intensity), 2)])
		(r[5] as Control).visible = bool(s.get("flaring", false))

static func _set_label(l: Label, t: String) -> void:
	if l.text != t: l.text = t

# climate
## cl: {label, cls, desc, celsius, S, ice, clouds, tauYears, Tmin, Tmax, history}
func update_climate(cl: Dictionary) -> void:
	var era: Dictionary = ERA.get(cl.get("cls", "era-stable"), ERA["era-stable"])
	var badge: PanelContainer = ids.eraBadge
	if badge.get_meta("era", "") != cl.get("cls", "era-stable"):
		badge.set_meta("era", cl.get("cls", "era-stable"))
		badge.add_theme_stylebox_override("panel", T.stylebox({"bg": era.bg, "bc": era.c, "pad": [7, 7, 7, 7]}))
		T.apply_label(ids.eraLabel, {"fs": 12.0, "ls": 2.16, "up": true, "c": era.c})
	set_text("eraLabel", str(cl.get("label", "")))
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

# imaging band
func build_band_grid(bands: Array) -> void:
	var g: HudGrid = ids.bandGrid
	for i in bands.size():
		B(g, "Band", str(bands[i].short), "[data-band=%d]" % i, str(bands[i].get("note", ""))).pressed.connect(func(): band_chosen.emit(i))
	_band_count = bands.size()

func set_band(i: int, band: Dictionary) -> void:
	for k in _band_count:
		set_active("[data-band=%d]" % k, k == i)
	set_text("bandNote", str(band.get("note", "")))
	set_text("bandLabel", str(band.get("short", "")))

# sky settings
## The environment rows and the amplitude rows, built from the sky module's own
## lists — a sixth environment grows a row here without this file changing.
func build_sky_settings(envs, params: Array) -> void:
	if envs is Dictionary:
		envs = (envs as Dictionary).keys()
	_envs = envs; _params = params
	var list: HudStack = ids.skyEnvList
	for name in envs:
		var row := stack(list, 0.0, 13.0)
		row.collapse = false
		var head := hbox(row, 6.0, 0.0, 2.0)
		var left := hbox(head, 0.0)
		left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var nl := L(left, str(name), {"fs": 11.0, "c": T.TEXT_DIM})
		reg("[data-env=%s]" % name, nl)
		var solo := B(left, "Solo", "solo", "[data-solo=%s]" % name, "Show this environment alone")
		solo.size_flags_vertical = Control.SIZE_SHRINK_END
		solo.pressed.connect(func(): sky_solo.emit(name))
		var wl := L(head, "0.00", {"fs": 10.0, "c": T.ACCENT}, "env-w:" + str(name))
		wl.size_flags_vertical = Control.SIZE_SHRINK_END
		m(_range(row, "env:" + str(name), 0, 3, 0, 0.05), 8.0)
	var adv: HudStack = ids.skyAdv
	for pm in params:
		var add: bool = pm.get("add", true)
		var tip := "An amount of something — blends by ADDING, because two populations along one line of sight superpose." if add \
			else "A shape of the one galaxy you are in — blends by weighted MEAN, because there is only one galactic plane."
		_set_row(adv, "skyp:" + str(pm.key), str(pm.label), tip, 0, float(pm.max), 0, float(pm.max) / 200.0, "0")
	m(B(adv, "Ghost", "Unpin all — back to the blend", "skyAdvClear"), 0.0, 10.0).pressed.connect(func(): sky_adv_clear.emit())

## `eff` is the blend merged with pinned values; `skip_inputs` updates only the
## numbers, never a slider under the pointer.
func sync_sky_controls(sky: Dictionary, eff: Dictionary, skip_inputs := false) -> void:
	var env: Dictionary = sky.get("env", {})
	for name in _envs:
		var w := float(env.get(name, 0.0))
		for h in _targets("[data-env=%s]" % name):
			T.apply_label(h, {"fs": 11.0, "c": T.TEXT if w > 0.0 else T.TEXT_DIM})
		for e in _targets("env-w:" + str(name)):
			T.apply_label(e, {"fs": 10.0, "c": T.ACCENT if w > 0.0 else T.TEXT_DIM})
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

# spaceflight
## rows: [{key, name, desc ("2.86 kt · 14.3 km/s · launch"), blurb}]
func render_craft_grid(rows: Array) -> void:
	var g: HudGrid = ids.craftGrid
	_clear(g)
	for r in rows:
		var key: String = r.key
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)
		var b := BoxButton.new("Craft", col, str(r.get("blurb", "")))
		L(col, str(r.name), {"fs": 10.5, "lh": 1.25, "fw": 600, "c": T.hexc(0xdbeaff)}, "", true)
		L(col, str(r.desc), {"fs": 9.5, "lh": 1.25, "c": T.hexc(0x7d93ae)}, "", true)
		g.add_child(b)
		reg("[data-craft=%s]" % key, b)
		b.pressed.connect(func(): craft_launch.emit(key))
		# Warm the mesh on hover: pointing at a button is a reliable signal that it
		# is about to be pressed.
		b.mouse_entered.connect(func(): craft_hover.emit(key))

func render_model_grid(list: Array) -> void:
	var g: HudGrid = ids.mvGrid
	_clear(g)
	for v in list:
		var key: String = v.key
		B(g, "MvChip", str(v.name), "[data-mv=%s]" % key).pressed.connect(func(): model_show.emit(key))

static func mv_mass(kg: float) -> String:
	if kg >= 1e6: return "%s kt" % U.fixed(kg / 1e6, 2)
	if kg >= 1e3: return "%s t" % U.fixed(kg / 1e3, 1)
	return "%s kg" % U.fixed(kg, 0)

## st = {key?, name, height, gross, dv, twr, rows: [{name, L, D, dry, prop, engine,
## thrust, isp, dv}]}
func show_model_stats(st: Dictionary) -> void:
	set_text("mvName", str(st.name))
	if st.has("key"):
		for sel in sels.keys():
			if str(sel).begins_with("[data-mv="):
				for b in _targets(sel):
					b.set_active(sel == "[data-mv=%s]" % st.key)
	var list: HudGrid = ids.mvList
	_clear(list)
	for kv in [["height", "%s m" % U.fixed(st.height, 1)], ["gross", mv_mass(st.gross)],
			["ideal Δv", "%s km/s" % U.fixed(st.dv / 1000.0, 2)], ["pad TWR", U.fixed(st.twr, 2) if st.twr > 0.0 else "—"]]:
		var cell := hbox(list, 4.0)
		var kl := L(cell, kv[0], {"fs": 10.0, "c": T.TEXT_DIM})
		kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		L(cell, kv[1], {"fs": 10.0, "c": T.TEXT})
	var stg: HudStack = ids.mvStages
	_clear(stg)
	var i := 0
	for r in st.get("rows", []):
		i += 1
		var s := HudStack.new(false)
		stg.add_child(m(frame(s, {"bw": 0, "bl": 2, "bc": T.BORDER_STRONG, "pad": [5, 0, 5, 8]}), 0.0, 6.0))
		var top := hbox(s, 6.0)
		var il := L(top, str(i), {"fs": 11.0, "c": T.ACCENT})
		il.size_flags_vertical = Control.SIZE_SHRINK_END
		var nl := L(top, str(r.name), {"fs": 11.0, "c": T.TEXT})
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.size_flags_vertical = Control.SIZE_SHRINK_END
		var dl := L(top, "%s km/s" % U.fixed(r.dv / 1000.0, 2), {"fs": 10.0, "c": T.ACCENT_2})
		dl.size_flags_vertical = Control.SIZE_SHRINK_END
		L(s, "%s × %s m · %s dry + %s prop" % [U.fixed(r.L, 1), U.fixed(r.D, 1), mv_mass(r.dry), mv_mass(r.prop)], {"fs": 9.5, "c": T.TEXT_DIM, "lh": 1.5}, "", true)
		var eng := str(r.engine)
		if float(r.get("thrust", 0.0)) > 0.0:
			eng += " · %s MN vac · Isp %s s" % [U.fixed(r.thrust / 1e6, 2), U.fixed(r.isp, 0)]
		L(s, eng, {"fs": 9.5, "c": T.TEXT_DIM, "lh": 1.5}, "", true)

# LAYOUT — the left column, the control column and the free band between them

func _process(dt: float) -> void:
	_time += dt
	if _toast_timer > 0.0:
		_toast_timer -= dt
		if _toast_timer <= 0.0:
			if _toast_tween: _toast_tween.kill()
			_toast_tween = create_tween()
			_toast_tween.tween_property(toast_el, "modulate:a", 0.0, 0.35)
	# the FLARE badge pulses: opacity 1 → 0.45 → 1 over 0.7 s, eased
	var ph := fmod(_time, 0.7) / 0.7
	var tt := 1.0 - absf(2.0 * ph - 1.0)
	var ease := tt * tt * (3.0 - 2.0 * tt)
	for r in _sun_rows:
		var fb: Control = r[5]
		if fb.is_visible_in_tree():
			fb.modulate.a = 1.0 - 0.55 * ease
	# Once a frame at most: a panel's height feeds back into its width (a
	# scrollbar), and a re-placement inside the same message flush could cycle.
	if _layout_pending:
		_layout_all()

func layout_left_column() -> void:
	_layout_all()

## A complete relayout (a resize, a font change).
func relayout() -> void:
	_layout_all()

func _queue_layout() -> void:
	_layout_pending = true

func _shown(e: Control) -> bool:
	return e != null and e.is_visible_in_tree() and e.size.y > 0.0

## Place a panel at its content's height, capped at `maxh`.
func _place(p: HudPanel, x: float, y: float, w: float, maxh := -1.0) -> void:
	p.position = Vector2(x, y)
	if not p.visible:
		return
	if absf(p.size.x - w) > 0.01:
		p.size = Vector2(w, p.size.y)
	var h := p.natural_height()
	if maxh >= 0.0:
		h = minf(h, maxh)
	p.size = Vector2(w, maxf(h, 0.0))

func _fit(c: Control, x: float, y: float) -> void:
	c.position = Vector2(x, y)
	c.size = c.get_combined_minimum_size()

func _layout_all() -> void:
	_layout_pending = false
	var W := size.x
	var H := size.y
	if W <= 0.0 or H <= 0.0:
		return
	for c in corners:
		var k: String = c.k
		c.position = Vector2(10 if k.ends_with("l") else W - 24, 10 if k.begins_with("t") else H - 24)
	settings_backdrop.position = Vector2.ZERO
	settings_backdrop.size = Vector2(W, H)
	_fit(readout, 20, 0)
	readout.position.y = H - 18 - readout.size.y
	# The column's own top and bottom edges are measured, not assumed.
	var col_top := 18.0
	var hud_bottom := roundf(readout.size.y) + 30.0 if _shown(readout) else 30.0

	# Settings is a centred Esc overlay; the scenario column starts at the top.
	var sw := minf(460.0, W - 48.0)
	_place(settings_panel, (W - sw) * 0.5, 0, sw, H - 72.0)
	settings_panel.position.y = roundf((H - settings_panel.size.y) * 0.5)
	_fit(tab_col, 20, col_top)
	# A collapsed panel leaves a tab at the top of the column, so the first free y
	# is the bottom of that stack, not the bare top of the column.
	var any_tab := false
	for t in tab_col.get_children():
		if (t as Control).visible: any_tab = true
	var free := roundf(tab_col.position.y + tab_col.size.y) + 12.0 if any_tab and tab_col.is_visible_in_tree() else col_top
	_place(scenario_panel, 20, free, 232, H - free - hud_bottom)
	_place(course_panel, 20, free, 250, H - free - hud_bottom)
	var top: Control = null
	for p in [scenario_panel, course_panel]:
		if _shown(p):
			top = p; break
	var y := roundf(top.position.y + top.size.y) + 12.0 if top else free
	var xsec_top := y
	_place(flight_panel, 12, y, 306, H - y - hud_bottom)
	if _shown(flight_panel):
		xsec_top = roundf(flight_panel.position.y + flight_panel.size.y) + 12.0
	_place(xsec_panel, 20, xsec_top, 348, H - xsec_top - hud_bottom)
	_place(model_panel, 20, col_top, 268, H - col_top - hud_bottom)
	_place(control_panel, W - 18 - 300, 18, 300, H - 36)
	_fit(tab_right, 0, col_top)
	tab_right.position.x = W - 18 - tab_right.size.x

	# The toast sits at the top of the free band, not the middle of the window.
	var band_l := 16.0
	for e in [settings_panel, scenario_panel, course_panel, model_panel, flight_panel, xsec_panel]:
		if not _shown(e): continue
		if e.position.y < col_top + 48.0:
			band_l = maxf(band_l, e.position.x + e.size.x + 16.0)
	if any_tab and _shown(tab_col):
		band_l = maxf(band_l, tab_col.position.x + tab_col.size.x + 16.0)
	var band_r := control_panel.position.x - 16.0 if _shown(control_panel) else W - 16.0
	var toast_x := roundf((band_l + band_r) * 0.5)
	var tmax := minf(420.0, 0.76 * W)
	var tf: Font = _toast_label.label_settings.font
	var tw := tf.get_string_size(_toast_label.text.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, _toast_label.label_settings.font_size).x + 34.0
	toast_el.size = Vector2(minf(ceilf(tw), tmax), 0)
	toast_el.size = Vector2(toast_el.size.x, toast_el.get_combined_minimum_size().y)
	toast_el.position = Vector2(toast_x - toast_el.size.x * 0.5, col_top)

	# The lesson card gets its own band, measured over every left panel.
	var card_l := 16.0
	for e in [settings_panel, scenario_panel, course_panel, flight_panel, xsec_panel]:
		if _shown(e): card_l = maxf(card_l, e.position.x + e.size.x + 16.0)
	if any_tab and _shown(tab_col):
		card_l = maxf(card_l, tab_col.position.x + tab_col.size.x + 16.0)
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
	# the text scrolls inside the card once the card reaches its cap
	var fixed := lesson_card.natural_height() - _lc_scroll.custom_minimum_size.y
	if absf(_lc_scroll.cap - maxf(cmax - fixed, 40.0)) > 0.5:
		_lc_scroll.cap = maxf(cmax - fixed, 40.0)
		_lc_scroll._fit()
	_place(lesson_card, cx, 0, cw)
	lesson_card.position.y = H - 16.0 - lesson_card.size.y

	# the start screen
	start_screen.position = Vector2.ZERO
	start_screen.size = Vector2(W, H)
	start_screen.pivot_offset = Vector2(W, H) * 0.5
	_start_cards_responsive(W)
	var iw := minf(860.0, 0.9 * W)
	_start_inner.size = Vector2(iw, 0)
	var ih := _start_inner.get_combined_minimum_size().y
	_start_inner.position = Vector2(roundf((W - iw) * 0.5), roundf((H - ih) * 0.5))
	_start_inner.size = Vector2(iw, ih)

## Three doors, stepping down rather than wrapping to an orphan: at 1040 px the
## course card goes full width above the other two, at 720 px one column.
func _start_cards_responsive(W: float) -> void:
	var cards := start_cards.get_children()
	var learn := cards_by("learn")
	if W > 1040.0:
		if start_cards.cols.size() != 3: start_cards.set_cols([1.0, 1.0, 1.0])
		for c in cards: c.set_meta("span", 1)
		start_cards.move_child(learn, 1)
	elif W > 720.0:
		if start_cards.cols.size() != 2: start_cards.set_cols([1.0, 1.0])
		start_cards.move_child(learn, 0)
		for c in cards: c.set_meta("span", 2 if c == learn else 1)
	else:
		if start_cards.cols.size() != 1: start_cards.set_cols([1.0])
		for c in cards: c.set_meta("span", 1)
	start_cards.queue_sort()

func cards_by(k: String) -> Node:
	for c in start_cards.get_children():
		if c.get_meta("start", "") == k:
			return c
	return null

func _input(e: InputEvent) -> void:
	# Clicking anywhere but the search box gives the keyboard back to the view.
	if e is InputEventMouseButton and e.pressed and _search and _search.has_focus():
		if not _search.get_global_rect().has_point(e.position):
			_search.release_focus()
