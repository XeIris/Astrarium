extends Node

# ============================================================================
# THE HUD HARNESS — the Godot half of the HUD's side-by-side check.
#
#   node godot/tools/uitest.shots.mjs /tmp/ui/shots.json
#   PORT=8797 WEB_ROOT=<checkout> node godot/tools/webref.mjs /tmp/ui/shots.json /tmp/ui/web
#   Godot --path godot res://tools/uitest.tscn -- fix=/tmp/ui/web state=sandbox out=/tmp/ui/godot/sandbox.png
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
# Args: fix=<dir> state=<name> out=<png> [bg=0] [blur=0] [frames=N] [rects=1]
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
	add_child(bg)
	if args.get("bg", "1") != "0":
		var img := Image.load_from_file(fix.path_join(state + ".bare.png"))
		if img:
			var tr := TextureRect.new()
			tr.texture = ImageTexture.create_from_image(img)
			tr.set_anchors_preset(Control.PRESET_FULL_RECT)
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
	var presets := {}
	for k in d.presets:
		presets[k] = d.presets[k]
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
