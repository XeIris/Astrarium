extends Node

# ============================================================================
# THE HUD HARNESS — the Godot half of the HUD's side-by-side check.
#
#   node tools/uitest.shots.mjs /tmp/ui/shots.json
#   PORT=8797 WEB_ROOT=<checkout> node tools/webref.mjs /tmp/ui/shots.json /tmp/ui/web
#   Godot --path . res://tools/uitest.tscn -- fix=/tmp/ui/web state=sandbox out=/tmp/ui/godot/sandbox.png
#
# For a state it reads the web page's own fixture (<state>.json, written by
# uitest.dump.js), puts the web frame WITH ITS HUD HIDDEN (<state>.bare.png)
# behind the Godot HUD, feeds the Hud the same data through the same API the
# orchestrator uses, and screenshots the root viewport at the page's size. The
# pair <state>.png / out can then be flipped between, or diffed: everything in
# the picture that is not the HUD is the same pixels in both.
#
# It also checks the layout as NUMBERS: the fixture carries the page's measured
# rect of every panel, tab and marked element, and the matching Godot rects are
# printed beside them with the difference (`rects=1`).
#
# THE COMMITTED SET is tools/ref/ui: for each state <state>.web.png (the
# page, 3D canvas hidden so the HUD sits on --bg), <state>.godot.png (this
# harness's output) and <state>.json (the fixture). Re-run any of them with
#   Godot --path . res://tools/uitest.tscn -- fix=res://tools/ref/ui state=trisolaris out=/tmp/t.png rects=1
# and flip or diff against <state>.web.png. Regenerate the set with
# `uitest.shots.mjs --flat` → webref.mjs → this harness.
#
# Also printed every run: the overlap check of the left column's chain (the
# AGENTS.md standing check), the cost of a full and an incremental HUD layout,
# and with selftest=1 a pass/fail walk of the orchestrator-facing API.
#
# Args: fix=<dir> state=<name> out=<png> [bg=0] [blur=0] [sb=1 scrollbars]
#       [frames=N] [rects=1] [selftest=1]
# ============================================================================

var args := {}
var hud: Hud
var d: Dictionary
var frame := 0
var frames := 40

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	frames = int(args.get("frames", "40"))
	var fix := str(args.get("fix", ""))
	var state := str(args.get("state", "sandbox"))
	var f := FileAccess.open(fix.path_join(state + ".json"), FileAccess.READ)
	if f == null:
		push_error("uitest: no fixture " + fix.path_join(state + ".json"))
		get_tree().quit(1)
		return
	d = JSON.parse_string(f.get_as_text())
	var w := int(d.w); var h := int(d.h)
	# CSS px = logical px: the canvas is laid out at the page's size whatever
	# the display's scale, and the screenshot is taken at that size.
	var win := get_window()
	win.content_scale_factor = 1.0
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.content_scale_size = Vector2i(w, h)
	win.size = Vector2i(w, h)
	HudBlur.enabled = args.get("blur", "1") != "0"
	# webref runs Chrome with --hide-scrollbars; match it unless asked not to
	El.scrollbars = args.get("sb", "0") == "1"

	var bg := ColorRect.new()
	bg.color = HudTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	if args.get("bg", "1") != "0" and FileAccess.file_exists(fix.path_join(state + ".bare.png")):
		var img := Image.load_from_file(fix.path_join(state + ".bare.png"))
		if img:
			var tr := TextureRect.new()
			tr.texture = ImageTexture.create_from_image(img)
			tr.set_anchors_preset(Control.PRESET_FULL_RECT)
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			add_child(tr)
	hud = Hud.new()
	add_child(hud)
	_apply()

func _apply() -> void:
	# the page's panels
	hud.set_app_mode(str(d.get("mode", "sandbox")))
	var col: Array = d.get("collapsed", [])
	for id in ["settingsPanel", "scenarioPanel", "coursePanel", "controlPanel", "flightPanel", "xsecPanel"]:
		hud.set_panel_open(id, not col.has(id))
	hud.set_shown("modelPanel", not col.has("modelPanel"))
	hud.set_model_open(str(d.get("bodyClass", "")).contains("model-open"))
	if not d.get("startShown", false):
		hud.start_screen.visible = false
	# data
	hud.build_band_grid(d.bands)
	hud.set_band(int(d.band), d.bands[int(d.band)])
	hud.build_sky_settings(d.envs, d.params)
	hud.sync_sky_controls(d.sky, d.skyEff)
	# the page only has the MATCHING buttons in it while a search is active, so
	# the catalogue itself comes from the unfiltered sandbox fixture
	var cat := d
	var cf := FileAccess.open(str(args.get("fix", "")).path_join("sandbox.json"), FileAccess.READ)
	if cf != null and str(d.get("search", "")) != "":
		cat = JSON.parse_string(cf.get_as_text())
	var presets := {}
	for k in cat.presets:
		presets[k] = cat.presets[k]
	d.groups = cat.groups
	for g in d.groups:
		if g.open and str(d.get("search", "")) == "":
			hud._open_groups[g.id] = true
	hud.render_preset_groups(d.groups, presets, str(d.presetKey))
	if str(d.get("search", "")) != "":
		hud.set_search(str(d.search))
	hud.render_body_list(d.bodies, d.focusId)
	var suns: Array = []
	for s in d.suns:
		var s2: Dictionary = s.duplicate()
		s2.color = Color(s.color[0], s.color[1], s.color[2])
		suns.append(s2)
	hud.render_sun_list(suns)
	if d.climate != null:
		hud.update_climate(d.climate)
	hud.render_craft_grid(d.crafts)
	hud.render_model_grid(d.models)
	if d.has("modelStats"):
		hud.show_model_stats(d.modelStats)
	# every leaf's text and every slider, as the page has them
	for id in d.text:
		var t := str(d.text[id])
		if hud.sliders.has(id):
			hud.set_slider(id, float(t))
		elif hud.ids.has(id) or hud.run_ids.has(id):
			hud.set_text(id, t)
	# the elements the orchestrator shows and hides inline
	for id in ["massRow", "discRow", "tempRow", "climatePanel", "camSurface", "skyRow", "focusPanel", "flightRow", "bhPanel", "starPanel"]:
		if d.shown.has(id) and (hud.app_mode != "flight" or id in ["flightRow"]):
			hud.set_shown(id, d.shown[id])
	# button states and the texts that go with them
	for a in d.active:
		var sel := str(a.sel)
		hud.set_active(sel, a.on)
		if sel.begins_with("[data-view=") or sel in ["camSurface", "flightCam", "skyAdvOpen", "mvDeploy", "mvSpin"]:
			hud.set_button_text(sel, str(a.text))
	# folded sections, as the page has them
	for s in d.sections:
		for sec in hud.sections:
			if str(s.title).begins_with(sec.title) and s.shown:
				hud.set_section_open(sec, s.open)
	hud.set_settings_page(str(d.get("setPage", "sky")))
	if d.get("skyAdvOpen", false):
		hud.get_el("skyAdvOpen").pressed.emit()
	if d.get("toast", null) != null:
		hud.toast(str(d.toast), 100000)

func _process(_dt: float) -> void:
	frame += 1
	if frame == 3:
		# arrows rotate over 0.16 s, the toast fades over 0.35 s: settle them
		pass
	if frame == frames:
		if args.get("rects", "0") == "1":
			_print_rects()
		_check_overlaps()
		_time_layout()
		if args.get("selftest", "0") == "1":
			_selftest()
		if args.has("out"):
			var img := get_viewport().get_texture().get_image()
			if img.get_width() != int(d.w):
				img.resize(int(d.w), int(d.h), Image.INTERPOLATE_LANCZOS)
			img.save_png(str(args.out))
			print("uitest: saved ", args.out, " ", img.get_size())
		get_tree().quit()

func _el_for(sel: String) -> Control:
	var m := {"#settingsPanel": hud.settings_panel, "#scenarioPanel": hud.scenario_panel, "#coursePanel": hud.course_panel,
		"#controlPanel": hud.control_panel, "#modelPanel": hud.model_panel, "#xsecPanel": hud.xsec_panel,
		"#flightPanel": hud.flight_panel, ".title-block": hud.title_block, "#readout": hud.readout, "#hint": hud.hint,
		"#toast": hud.toast_el, "#lessonCard": hud.lesson_card, ".tab-col": hud.tab_col, "#panelTabs .tab-right": hud.tab_right,
		".start-cards": hud.start_cards, ".mode-switch": hud.title_block.get_child(0),
		".start-inner": hud.start_cards.get_parent(), ".start-title": hud.start_cards.get_parent().get_child(1)}
	if m.has(sel):
		return m[sel]
	if sel.begins_with("#"):
		return hud.get_el(sel.substr(1))
	if sel.begins_with("[data-open="):
		var arr: Array = hud.sels.get(sel, [])
		return arr[0] if not arr.is_empty() else null
	if sel.begins_with("sec:"):
		for sec in hud.sections:
			if sel.substr(4).begins_with(sec.title):
				return sec.head
		return null
	return null

func _print_rects() -> void:
	var worst := 0.0
	for sel in d.rects:
		var r: Array = d.rects[sel]
		var e := _el_for(sel)
		if e == null or not e.is_visible_in_tree():
			print("  %-28s web %s  godot —" % [sel, str(r)])
			continue
		var g := e.get_global_rect()
		var dv := [g.position.x - r[0], g.position.y - r[1], g.size.x - r[2], g.size.y - r[3]]
		var m := 0.0
		for v in dv: m = maxf(m, absf(v))
		worst = maxf(worst, m)
		print("  %-28s web [%6.1f %6.1f %6.1f %6.1f]  godot [%6.1f %6.1f %6.1f %6.1f]  Δ %s" % [sel, r[0], r[1], r[2], r[3],
			g.position.x, g.position.y, g.size.x, g.size.y, "ok" if m < 1.01 else "%.1f" % m])
	print("uitest: worst rect delta %.1f px" % worst)

## The standing check on the left column (AGENTS.md): whatever is open or
## collapsed, no two of the HUD's positioned boxes may overlap.
func _check_overlaps() -> void:
	var boxes := [hud.title_block, hud.settings_panel, hud.scenario_panel, hud.course_panel, hud.flight_panel,
		hud.xsec_panel, hud.model_panel, hud.tab_col, hud.control_panel, hud.tab_right, hud.readout, hud.hint]
	var bad := 0
	for i in boxes.size():
		for j in range(i + 1, boxes.size()):
			var a: El = boxes[i]; var b: El = boxes[j]
			if not a.is_visible_in_tree() or not b.is_visible_in_tree() or a.size.y <= 0.0 or b.size.y <= 0.0:
				continue
			if a.get_global_rect().grow(-0.5).intersects(b.get_global_rect().grow(-0.5)):
				print("uitest: OVERLAP %s / %s" % [a.el_id, b.el_id])
				bad += 1
	print("uitest: overlaps %d" % bad)

func _time_layout() -> void:
	var t0 := Time.get_ticks_usec()
	for i in 10:
		hud.relayout()
	print("uitest: full HUD layout %.2f ms" % ((Time.get_ticks_usec() - t0) / 10000.0))
	# the common case: a readout and a sun row change, as updateHUD does
	t0 = Time.get_ticks_usec()
	for i in 10:
		hud.set_text("fps", str(60 + i))
		hud.set_text("simClock", "%d yr" % i)
		hud._layout_all()
	print("uitest: incremental HUD layout %.2f ms" % ((Time.get_ticks_usec() - t0) / 10000.0))

## Drive the API the orchestrator uses and check what comes back out.
func _selftest() -> void:
	var got := {}
	var ok := [0, 0]
	var check := func(name: String, cond: bool):
		ok[0 if cond else 1] += 1
		print("  %s %s" % ["PASS" if cond else "FAIL", name])
	hud.slider.connect(func(id, v): got["slider"] = [id, v])
	hud.preset_chosen.connect(func(k): got["preset"] = k)
	hud.panel_changed.connect(func(id, o): got["panel"] = [id, o])
	hud.band_chosen.connect(func(i): got["band"] = i)
	hud.start_chosen.connect(func(m): got["start"] = m)
	hud.drive_slider("mass", 20.04)
	check.call("drive_slider emits slider(id, value) snapped to the step", got.get("slider", []) == ["mass", 20.0])
	check.call("drive_slider writes the value label", hud.get_el("mass-val").get_text() == "20.0")
	hud.drive_slider("timescale", 0.0)
	check.call("timescale label is timeLabel(10^v)", hud.get_el("timescale-val").get_text() == "1.0 yr/s")
	hud.drive_slider("maxStep", -3.0)
	check.call("maxStep label is toExponential", hud.get_el("maxStep-val").get_text() == "1.0e-3 yr")
	hud.set_text("fxBloom-val", "0.77")
	check.call("set_text on a -val label", hud.get_el("fxBloom-val").get_text() == "0.77")
	hud.set_text("bandLabel", "X-RAY")
	check.call("set_text on an inline span (readout)", hud.run_ids["bandLabel"][1].t == "X-RAY")
	hud.set_active("[data-view=scale]", true)
	check.call("set_active by [data-x=v]", hud.sels["[data-view=scale]"][0].has_state("active"))
	hud.set_active("[data-view='mesh']", false)
	check.call("set_active tolerates quotes", not hud.sels["[data-view=mesh]"][0].has_state("active"))
	hud.set_button_text("camOrbit", "Orbit!")
	check.call("set_button_text by id", hud.get_el("camOrbit").get_text() == "Orbit!")
	hud.set_panel_open("scenarioPanel", false)
	check.call("set_panel_open collapses and emits", hud.is_collapsed("scenarioPanel") and got.get("panel", []) == ["scenarioPanel", false])
	check.call("a collapsed panel leaves its tab", hud.tabs["scenarioPanel"].visible)
	hud.tabs["scenarioPanel"].pressed.emit()
	check.call("its tab reopens it", not hud.is_collapsed("scenarioPanel"))
	var pb: Array = hud.sels.get("[data-preset=vega]", [])
	if not pb.is_empty():
		pb[0].pressed.emit()
		check.call("a preset button emits preset_chosen", got.get("preset", "") == "vega")
	var bb: Array = hud.sels.get("[data-band=5]", [])
	bb[0].pressed.emit()
	check.call("a band button emits band_chosen", got.get("band", -1) == 5)
	hud.set_model_open(true)
	check.call("model-open hides the tab stack", not hud.tab_col.visible)
	hud.set_model_open(false)
	hud.set_hud_hidden(true)
	check.call("hud-hidden hides the panels, not the toast", not hud.control_panel.visible and hud.toast_el.get_text() == "HUD hidden — press H to restore")
	hud.set_hud_hidden(false)
	hud.set_app_mode("flight")
	check.call("flight mode drops the scenario panel", not hud.scenario_panel.visible)
	check.call("flight mode shows only the Spaceflight section", hud.section("Spaceflight").head.visible and not hud.section("Suns").head.visible)
	hud.set_app_mode("sandbox")
	var sc: Array = hud.sels["[data-start=learn]"]
	sc[0].pressed.emit()
	check.call("a start card emits start_chosen", got.get("start", "") == "learn")
	check.call("mount points exist", hud.mount("foundry") != null and hud.mount("liveEdit") != null and hud.mount("flightHud") != null \
		and hud.mount("courseMount") != null and hud.mount("xsecCanvas") != null and hud.mount("lessonCard") != null)
	# real mouse input through the viewport: a click lands on the button under
	# it, a click on empty screen falls through to _unhandled_input, and the
	# wheel over an overflowing panel scrolls it rather than the view
	hud.relayout()
	var vis_band: El = hud.sels["[data-band=2]"][0]
	if vis_band.is_visible_in_tree():
		got.erase("band")
		_click(vis_band.get_global_rect().get_center())
		check.call("a real click on a band button reaches it", got.get("band", -1) == 2)
	_unhandled = 0
	_click(Vector2(640, 300))
	check.call("a click on empty screen falls through to the 3D view", _unhandled >= 2)
	_unhandled = 0
	_click(hud.control_panel.get_global_rect().position + Vector2(150, 200))
	check.call("a click on a panel does not", _unhandled == 0)
	var cp := hud.control_panel
	if cp.overflowing:
		var before := cp.scroll_y
		var we := InputEventMouseButton.new()
		we.button_index = MOUSE_BUTTON_WHEEL_DOWN
		we.pressed = true
		we.factor = 1.0
		we.position = cp.get_global_rect().position + Vector2(150, 300)
		get_viewport().push_input(we, true)
		# a wheel notch is a press AND a release, as a real mouse sends it —
		# without the release the panel keeps the mouse focus
		var wr: InputEventMouseButton = we.duplicate()
		wr.pressed = false
		get_viewport().push_input(wr, true)
		check.call("the wheel scrolls an overflowing panel", cp.scroll_y > before)
	var r: RangeInput = hud.sliders["speed"]
	if r.is_visible_in_tree():
		got.erase("slider")
		_click(r.get_global_rect().position + Vector2(r.size.x * 0.75, 1))
		check.call("a click on a range track moves it and emits", got.get("slider", [""])[0] == "speed")
	var sec: Dictionary = hud.section("Suns")
	cp.scroll_y = 0.0
	cp.touch()
	hud.relayout()
	var was: bool = sec.open
	_click(sec.head.get_global_rect().get_center())
	check.call("a section head folds/unfolds on click", sec.open != was)
	print("uitest: selftest %d passed, %d failed" % [ok[0], ok[1]])

var _unhandled := 0

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		_unhandled += 1

func _click(p: Vector2) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = p
		e.global_position = p
		get_viewport().push_input(e, true)
