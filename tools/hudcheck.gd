extends Node

# THE HUD CHECK: the real orchestrator (main.tscn) at content scale 1, put into a
# named HUD state and screenshotted after fixed steps, so two builds' shots differ
# only where the HUD does. `htest=1` walks the controls with real mouse and key
# events and checks that main's state follows; `hperf=1` times whole frames with
# the HUD shown and hidden. `hlayout=1` checks narrow layouts at scales 1/1.5/2.
#
#   Godot --path . --resolution 1280x720 res://tools/hudcheck.tscn -- \
#         hstate=sandbox hout=/abs/x.png [hframes=45] [htest=1] [hperf=1]
#
# States: sandbox allopen allbottom foundry xsec closed settings_sky
# settings_render settings_sim settings_precision settings_controls search zoo learn lesson_hr
# lesson_photometer lesson_gw lesson_cutaway lesson_fig flight ascent model start
# toast hidden. Args are h-prefixed: main.gd reads its own from the same line.

var args := {}
var main: Node
var hud: Control
var n := 0
var frames := 45
var fails := 0
var passes := 0
var mouse_inside := false

func _ready() -> void:
	get_window().mouse_entered.connect(func(): mouse_inside = true)
	get_window().mouse_exited.connect(func(): mouse_inside = false)
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	frames = int(args.get("hframes", "45"))
	var requested_size := get_window().size
	if args.get("assets", "1") == "0":
		for id in CraftAssets.CRAFT_ASSETS: CraftAssets.CACHE[id] = null
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	var win := get_window()
	main.configure_window_scale(float(args.get("hscale", "1.0")))
	win.size = requested_size.max(win.min_size)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	hud = main.hud
	main.lessons.store = ""
	main.lessons.progress = {"done": {}, "last": null}
	if args.get("htest", "0") == "1" or args.get("hlayout", "0") == "1":
		var temp_dir := OS.get_environment("TMPDIR")
		if temp_dir.is_empty(): temp_dir = OS.get_environment("TEMP")
		if temp_dir.is_empty(): temp_dir = "/tmp"
		main.controls = ControlBindings.new("")
		main.controls.file_path = temp_dir.path_join("astrarium-hudcheck-controls-%d.json" % OS.get_process_id())
		hud.update_binding_labels(main.controls.bindings)
	await get_tree().process_frame
	await _setup(str(args.get("hstate", "sandbox")))
	if args.get("assets", "1") == "0":
		if main.flight.craft != null: check("procedural flight craft selected", not main.flight.craft.authored)
		if main.model_view.craft != null: check("procedural studio craft selected", not main.model_view.craft.authored)
		check("authored cache disabled", CraftAssets.PENDING.is_empty() and CraftAssets.CACHE.values().all(func(model): return model == null))
	print("HUDCHECK CONFIG assets=%s state=%s" % ["procedural" if args.get("assets", "1") == "0" else "optional-authored", args.get("hstate", "sandbox")])
	if args.get("htest", "0") == "1":
		await _interaction_walk()
		print("HUDCHECK TEST %d passed, %d failed" % [passes, fails])
	if args.get("hlayout", "0") == "1":
		await _layout_walk()
		print("HUDCHECK LAYOUT %d passed, %d failed" % [passes, fails])
	if args.get("hperf", "0") == "1":
		await _perf()
	if args.has("hdump"):
		await _steps(5)
		_dump(hud.get_el(str(args.hdump)), 0)
	if args.has("hout"):
		for i in frames:
			main.frame(1.0 / 60.0)
			await get_tree().process_frame
		if str(args.get("hstate", "")) != "toast":
			_quiet_toast()
		else:
			hud.set_text("fps", "60")
		if str(args.get("hstate", "")) == "settings_precision":
			main.state.last_steps = Derive.STEP_GUARD
			main.step_physics(1e-6, true)
			main.update_sim_stats()
		main.set_process(false)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var save_error := get_viewport().get_texture().get_image().save_png(str(args.hout))
		if save_error == OK:
			print("HUDCHECK saved ", args.hout)
		else:
			fails += 1
			printerr("HUDCHECK failed to save ", args.hout, ": ", error_string(save_error))
	get_tree().quit(1 if fails > 0 else 0)

func _steps(k: int) -> void:
	for i in k:
		if main.is_processing(): main.frame(1.0 / 60.0)
		else: main.animate(1.0 / 60.0)
		await get_tree().process_frame

## The toast and the fps readout run on wall time; pin them so two runs compare.
func _quiet_toast() -> void:
	var t: Control = hud.toast_el
	if t: t.modulate.a = 0.0
	hud.set_text("fps", "60")

# ---- states --------------------------------------------------------------------
func _start(mode: String, preset := "solar") -> void:
	main.load_preset(preset)
	main._start(mode)
	await _steps(3)

func _open_all_sections() -> void:
	for sec in hud.sections:
		var head: Control = sec.head
		if head.is_visible_in_tree() or (sec.get("host") != null and (sec.host as Control).is_visible_in_tree()):
			hud.set_section_open(sec, true)

func _lesson_with(what: String) -> Array:
	for e in Lessons.LESSON_ORDER:
		var steps: Array = Lessons.find_lesson(e.key).lesson.steps
		for i in steps.size():
			if what == "fig" and steps[i].get("fig") != null: return [e.key, i]
			if steps[i].get("instrument") == what: return [e.key, i]
	return []

func _setup(s: String) -> void:
	match s:
		"sandbox": await _start("sandbox")
		"zoo": await _start("sandbox", "stellar_zoo")
		"allopen", "allbottom":
			await _start("sandbox")
			_open_all_sections()
			await _steps(3)
			if s == "allbottom": _scroll_panel(hud.control_panel, 1.0)
		"foundry":
			await _start("sandbox")
			hud.set_section_open(hud.section("Object Foundry"), true)
			await _steps(2)
			_reveal(hud.mount("foundry"))
		"xsec":
			await _start("sandbox")
			main._stage_set_focus("Earth")
			main.open_cross_section(true)
		"closed":
			await _start("sandbox")
			main.set_panel_open("scenarioPanel", false)
			main.set_panel_open("controlPanel", false)
		"settings_sky", "settings_render", "settings_sim", "settings_controls", "settings_precision":
			await _start("sandbox")
			hud.set_settings_open(true)
			hud.set_settings_page("sim" if s == "settings_precision" else s.substr(9))
			if s == "settings_precision":
				main.state.max_step = 0.0
				main.step_physics(1e-6)
				main.state.paused = true
				main.update_sim_stats()
			if s == "settings_render":
				_find("renderAdvancedToggle").pressed.emit()
		"search":
			await _start("sandbox")
			hud.set_search("tri")
		"learn": await _start("learn")
		"lesson_hr", "lesson_photometer", "lesson_gw", "lesson_cutaway", "lesson_fig":
			await _start("learn")
			var ls := _lesson_with(s.substr(7))
			main.lessons.open_lesson(ls[0], ls[1])
		"flight", "ascent":
			main.last_craft = "saturnv"
			await _start("flight")
			for i in 30:
				if main.flight.vessel != null: break
				await get_tree().process_frame
			if s == "ascent":
				main.flight.run_program("ascent")
				await _steps(1500)
		"model":
			await _start("sandbox")
			main._on_model_open()
			for i in 30: await get_tree().process_frame
		"start":
			await _start("sandbox")
			main.quit_to_start()
		"toast":
			await _start("sandbox")
			main.toast("Scenario loaded — this is a toast", 100000)
		"hidden":
			await _start("sandbox")
			main.set_hud_hidden(true)
	await _steps(2)

# ---- element access and real input ---------------------------------------------
func _find(sel: String) -> Control:
	var t: Array = hud._targets(sel)
	return t[0] if not t.is_empty() else null

## Scroll whatever panel holds `c` so that it is on screen.
func _reveal(c: Control) -> void:
	var p := c.get_parent()
	while p != null and p != hud:
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(c)
			return
		p = p.get_parent()

func _scroll_panel(panel: Control, frac: float) -> void:
	for sc in panel.find_children("*", "ScrollContainer", true, false):
		var bar := (sc as ScrollContainer).get_v_scroll_bar()
		(sc as ScrollContainer).scroll_vertical = int(frac * (bar.max_value - bar.page))
		return

func _push(e: InputEvent) -> void:
	if e is InputEventMouse and not mouse_inside:
		get_viewport().notify_mouse_entered()
		mouse_inside = true
	get_viewport().push_input(e, true)

func _click_at(p: Vector2) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = p
		e.global_position = p
		_push(e)
	# Native mouse-exit notifications must not split the synthetic click.
	await get_tree().process_frame

func _move(p: Vector2, rel := Vector2.ZERO, held := true) -> void:
	var m := InputEventMouseMotion.new()
	m.position = p
	m.global_position = p
	m.relative = rel
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	_push(m)
	await get_tree().process_frame

func _click(c: Control) -> bool:
	if c == null or not c.is_visible_in_tree():
		if args.get("hverbose", "0") == "1":
			var why := "null" if c == null else "hidden"
			if c != null:
				var p: Node = c
				while p != null and p is CanvasItem and (p as CanvasItem).visible: p = p.get_parent()
				why += " (by %s)" % p
			print("    click skipped: ", why)
		return false
	_reveal(c)
	await _steps(2)
	var r := c.get_global_rect()
	await _move(r.get_center(), Vector2.ZERO, false)
	var under := get_viewport().gui_get_hovered_control()
	if args.get("hverbose", "0") == "1":
		print("    click %s %s at %s → under %s (%s) target? %s; sections open %s" % [c.get_class(), _text_of(c).left(20), r.get_center(), under,
			_text_of(under).left(20) if under else "", under == c, hud.sections.map(func(s): return int(s.open))])
	await _click_at(r.get_center())
	await _steps(1)
	return true

func _drag(c: Control, f0: float, f1: float) -> void:
	_reveal(c)
	await _steps(2)
	var r := c.get_global_rect()
	var y := r.get_center().y
	var p0 := Vector2(r.position.x + r.size.x * f0, y)
	var p1 := Vector2(r.position.x + r.size.x * f1, y)
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT; e.pressed = true; e.position = p0; e.global_position = p0
	_push(e)
	await get_tree().process_frame
	for i in 6:
		await _move(p0.lerp(p1, (i + 1) / 6.0), (p1 - p0) / 6.0)
	var u: InputEventMouseButton = e.duplicate()
	u.pressed = false; u.position = p1; u.global_position = p1
	_push(u)
	await _steps(2)

func _wheel_at(p: Vector2, down := true) -> void:
	await _move(p, Vector2.ZERO, false)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
		e.pressed = pressed
		e.factor = 1.0
		e.position = p
		e.global_position = p
		_push(e)
	await _steps(2)
	# Native mouse-exit notifications can clear hover while the wheel settles.
	var hover := InputEventMouseMotion.new()
	hover.position = p; hover.global_position = p
	_push(hover)

func _key(code: Key, shift := false) -> void:
	for pressed in [true, false]:
		var k := InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.pressed = pressed
		k.shift_pressed = shift
		_push(k)
	await get_tree().process_frame

func _type(text: String) -> void:
	for ch in text:
		var k := InputEventKey.new()
		k.keycode = OS.find_keycode_from_string(ch.to_upper())
		k.unicode = ch.unicode_at(0)
		k.pressed = true
		_push(k)
		var u: InputEventKey = k.duplicate()
		u.pressed = false
		_push(u)
		await get_tree().process_frame

func _text_of(c: Control) -> String:
	if c == null: return "<null>"
	if c.has_method("get_text"): return str(c.get_text())
	if "text" in c: return str(c.text)
	return ""

func check(name: String, ok: bool) -> void:
	if ok: passes += 1
	else: fails += 1
	print("  %s %s" % ["PASS" if ok else "FAIL", name])

# ---- the interaction walk --------------------------------------------------------
func _interaction_walk() -> void:
	var st = main.state
	hud.set_settings_open(false)
	await _start("sandbox")
	st.paused = true
	st.speed = 1.0
	for sec in ["View & Camera", "Imaging Band", "Time", "Suns"]:
		hud.set_section_open(hud.section(sec), true)
	await _steps(3)

	# View & Camera
	var was: bool = st.true_scale
	await _click(_find("[data-view=scale]"))
	check("Sizes button toggles true scale", st.true_scale != was)
	check("…and relabels itself", _text_of(_find("[data-view=scale]")).to_lower().contains("real" if st.true_scale else "boosted"))
	await _click(_find("[data-view=scale]"))
	check("…and back", st.true_scale == was)
	var lens: bool = st.show_lens
	await _click(_find("[data-view=lens]"))
	check("Lens button toggles the lens", st.show_lens != lens)
	await _click(_find("camFree"))
	check("Free Fly sets the camera mode", st.cam_mode == "free")
	await _click(_find("camOrbit"))
	check("Orbit sets it back", st.cam_mode == "orbit")

	# bands and time
	await _click(_find("[data-band=5]"))
	check("band button 5 sets the band", st.band == 5)
	await _click(_find("[data-band=3]"))
	check("band button 3 sets the band", st.band == 3)
	var ts: float = st.time_scale
	await _click(_find("[data-time=day]"))
	check("Days regime changes the time scale", st.time_scale != ts)

	# sliders: a real drag
	var sp: float = st.speed
	await _drag(_find("speed"), 0.2, 0.8)
	check("dragging Sim Speed changes state.speed (%s → %s)" % [sp, st.speed], absf(st.speed - sp) > 0.1)
	check("…and its value label follows", _text_of(_find("speed-val")) == U.fixed(st.speed, 2))
	var tsl: float = st.time_scale
	await _drag(_find("timescale"), 0.8, 0.3)
	check("dragging Time scale changes the time scale", st.time_scale < tsl)
	hud.drive_slider("speed", 1.0)
	check("drive_slider moves state as if dragged", absf(st.speed - 1.0) < 1e-6)

	# section folding
	var sec: Dictionary = hud.section("Suns")
	var open: bool = sec.open
	_reveal(sec.head)
	await _click(sec.head)
	check("a section head folds/unfolds on click", sec.open != open)
	await _click(sec.head)
	check("…and again", sec.open == open)

	# the camera does not hear the pointer over a panel
	var cp: Control = hud.control_panel
	var pr := cp.get_global_rect()
	var over := pr.position + Vector2(pr.size.x * 0.5, minf(pr.size.y * 0.6, 400.0))
	var r0: float = main.cam.radius
	await _wheel_at(over)
	check("pointer_over_ui() is true over the control panel", hud.pointer_over_ui())
	check("the wheel over a panel does not zoom the camera", absf(main.cam.radius - r0) < 1e-9)
	var empty := Vector2(pr.position.x - 200.0, get_viewport().get_visible_rect().size.y * 0.55)
	await _wheel_at(empty)
	check("pointer_over_ui() is false over empty screen", not hud.pointer_over_ui())
	check("the wheel over empty screen zooms", absf(main.cam.radius - r0) > 1e-9)
	var th: float = main.cam.theta
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT; e.pressed = true; e.position = over; e.global_position = over
	_push(e)
	for i in 5: await _move(over + Vector2(0, 8 * (i + 1)), Vector2(0, 8))
	var u: InputEventMouseButton = e.duplicate(); u.pressed = false
	_push(u)
	await _steps(1)
	check("a drag that starts on a panel does not orbit the camera", absf(main.cam.theta - th) < 1e-9)
	if not cp.find_children("*", "ScrollContainer", true, false).is_empty():
		_open_all_sections()
		await _steps(3)
		var y0 := _panel_scroll(cp)
		await _wheel_at(over)
		check("the wheel scrolls an overflowing panel", _panel_scroll(cp) > y0)
		_scroll_panel(cp, 0.0)
		await _steps(2)

	# collapse and tabs
	await _click(_panel_close(cp))
	check("the ✕ collapses the control panel", hud.is_collapsed("controlPanel") and not cp.visible)
	var tab: Control = hud.tab_right
	check("…and leaves its tab", tab.is_visible_in_tree())
	await _click(tab)
	check("the tab reopens it", not hud.is_collapsed("controlPanel") and cp.visible)
	await _click(_panel_close(hud.scenario_panel))
	check("the scenario panel collapses to a tab", hud.is_collapsed("scenarioPanel"))
	await _click(hud.tabs["scenarioPanel"])
	check("its tab reopens it", not hud.is_collapsed("scenarioPanel"))

	# the preset search, typed
	var search := _search_edit()
	await _click(search)
	await _type("vega")
	await _steps(2)
	check("typing filters the scenario list", _find("[data-preset=vega]") != null and _find("[data-preset=solar]") == null)
	await _click(_find("[data-preset=vega]"))
	check("clicking a filtered preset loads it", st.preset_key == "vega")
	await _click(_find("presetSearchClear"))
	check("the search ✕ clears the query", _search_text() == "")
	await _click_at(empty)
	check("clicking the view takes the keyboard back from the search box", not search.has_focus())
	hud.open_preset_group("stellar-systems")
	await _steps(2)
	await _click(_find("[data-preset=solar]"))
	check("a preset inside an opened group loads", st.preset_key == "solar")

	# Esc settings, pages, bindings
	await _key(KEY_ESCAPE)
	check("Esc opens Settings", hud.settings_open and hud.settings_panel.is_visible_in_tree())
	await _click(_find("[data-set=render]"))
	await _click(_find("[data-render-quality=low]"))
	check("a render quality button sets the quality", main.render_quality == "low")
	await _click(_find("[data-render-quality=medium]"))
	await _click(_find("[data-set=controls]"))
	var bb: Control = hud.binding_buttons.get("pause")
	await _click(bb)
	check("a binding button enters capture", main.capture_action == "pause" and _text_of(bb).to_lower().contains("press a key"))
	await _key(KEY_K)
	check("the next key is bound", main.controls.bindings["pause"][0] == KEY_K and main.capture_action == "")
	check("…and the button says so", _text_of(bb).ends_with("K"))
	await _click(_find("bindingsReset"))
	check("reset restores the default", main.controls.bindings["pause"][0] != KEY_K)
	await _key(KEY_ESCAPE)
	check("Esc closes Settings", not hud.settings_open and not hud.settings_panel.is_visible_in_tree())

	# focus panel and cross-section
	main._stage_set_focus("Earth")
	hud.set_section_open(hud.section("Focused Object"), true)
	await _steps(3)
	await _click(_find("xsecOpen"))
	check("Cross-section & edit opens the cross-section", main.xsec_open and hud.xsec_panel.is_visible_in_tree())
	await _click(_panel_close(hud.xsec_panel))
	check("its ✕ closes it", not main.xsec_open and not hud.xsec_panel.is_visible_in_tree())

	# the model viewer
	hud.set_section_open(hud.section("Spaceflight"), true)
	main.set_app_mode("flight", {"quiet": true})
	await _steps(3)
	await _click(_find("modelOpen"))
	for i in 20: await get_tree().process_frame
	check("Model viewer ▸ opens the studio", main.model_open and hud.model_panel.is_visible_in_tree())
	await _click(_find("[data-mv=falcon9]"))
	for i in 20: await get_tree().process_frame
	check("a model chip shows that vehicle", _text_of(_find("mvName")).to_lower().contains("falcon"))
	await _click(_find("modelClose"))
	check("the model panel's ✕ closes the studio", not main.model_open)

	# flight: launch from the grid, then the program buttons
	await _click(_find("[data-craft=saturnv]"))
	for i in 60:
		if main.flight.vessel != null: break
		await get_tree().process_frame
	await _steps(3)
	check("a craft button launches it", main.flight.active and main.flight.vessel != null)
	check("the flight panel opens", hud.flight_panel.is_visible_in_tree())
	var fui = main.flight.hud
	await _click(fui.prog_btns["ascent"])
	await _steps(5)
	check("Launch to orbit starts the count", main.flight.count != null or main.flight.autopilot.program == "ascent")
	await _click(fui.mode_btns["prograde"])
	await _steps(2)
	check("an autopilot mode button sets the mode", main.flight.autopilot.mode == "prograde")
	var w0: int = main.flight.warp_idx
	await _click(_find("[data-warp=1]"))
	check("the warp ▸ steps the warp", main.flight.warp_idx != w0 or _text_of(_find("warpLabel")) != "1×")
	await _click(_find("flightExit"))
	await _steps(3)
	check("Exit flight ends it", not main.flight.active)
	main.set_app_mode("sandbox")
	await _steps(3)

	# the course: the card's own buttons
	var L = main.lessons
	L.store = ""
	main.set_app_mode("learn")
	await _steps(5)
	var k0 = L.key
	check("Learn opens a lesson", k0 != null and hud.lesson_card.is_visible_in_tree())
	await _click(hud.lc.next)
	check("Next → steps forward", L.step_ix == 1)
	await _click(hud.lc.back)
	check("← Back steps back", L.step_ix == 0)
	await _click(hud.lc.dots.get_child(1))
	check("a step dot jumps to its step", L.step_ix == 1)
	await _click(hud.lc.close)
	check("the card's ✕ leaves the lesson", L.key == null and not hud.lesson_card.is_visible_in_tree())
	main.set_app_mode("sandbox")
	await _steps(3)

func _panel_scroll(p: Control) -> float:
	for sc in p.find_children("*", "ScrollContainer", true, false):
		return float((sc as ScrollContainer).scroll_vertical)
	return 0.0

func _layout_walk() -> void:
	check("automatic scale fits a smaller usable display", is_equal_approx(main.fitted_window_scale(2.0, Vector2i(1280, 720)), 1.2))
	for usable in [Vector2i(1280, 720), Vector2i(1000, 1000), Vector2i(903, 1000)]:
		main.configure_window_scale(main.fitted_window_scale(2.0, usable))
		check("fitted physical minimum fits %s usable pixels" % usable, get_window().min_size.x <= usable.x and get_window().min_size.y <= usable.y)
	check("automatic scale retains native scale when it fits", main.fitted_window_scale(2.0, Vector2i(2560, 1538)) == 2.0)
	var fits := true
	for width in range(900, 4001):
		var minimum: Vector2i = main.minimum_window_size(main.fitted_window_scale(4.0, Vector2i(width, 4000)))
		if minimum.x > width or minimum.y > 4000: fits = false; break
	check("fitted minimum stays inside usable widths 900 through 4000", fits)
	for scale in [1.0, 1.5, 2.0]:
		for logical in [Vector2i(900, 600), Vector2i(1024, 600), Vector2i(1041, 600), Vector2i(1078, 600), Vector2i(1280, 600)]:
			# Retina windows have even physical widths; scale 2 preserves logical 1041.
			if logical.x == 1041:
				if scale != 2.0: continue
			elif logical.x > 1024 and scale != 1.0: continue
			main.configure_window_scale(scale)
			get_window().size = Vector2i((Vector2(logical) * scale).ceil())
			await _steps(8)
			var tag := "%dx%d scale %.1f" % [logical.x, logical.y, scale]
			print("HUDCHECK LAYOUT CONFIG ", tag, " physical=", get_window().size, " logical=", hud.size)
			check(tag + " logical viewport", hud.size.is_equal_approx(Vector2(logical)))
			await _start("learn")
			var L = main.lessons
			L.open_lesson(Lessons.LESSON_ORDER[0].key, 0)
			for module in Lessons.MODULES: L.open[module.id] = true
			L.render_panel()
			await _steps(8)
			check(tag + " lesson leaves both columns unobscured", not hud.lesson_card.get_global_rect().intersects(hud.course_panel.get_global_rect()) and not hud.lesson_card.get_global_rect().intersects(hud.control_panel.get_global_rect()))
			var full_width: bool = is_equal_approx(hud.lesson_card.size.x, hud.size.x - 32.0)
			check(tag + " lesson leaves the readout band clear", not hud.lesson_card.get_global_rect().intersects(hud.readout.get_global_rect()) and (not full_width or hud.lesson_card.get_global_rect().end.y <= hud.readout.position.y - 12.0 + 0.5))
			var last: Control = null
			for c in hud.course_panel.find_children("*", "Control", true, false):
				if c is BoxButton and c.kind in ["LessonItem", "LessonDone"]: last = c
			await _click(last)
			check(tag + " bottom course lesson can be clicked", L.key == Lessons.LESSON_ORDER[-1].key)
			L.open_lesson(Lessons.LESSON_ORDER[0].key, 0)
			await _steps(5)
			await _click(hud.lc.next)
			check(tag + " lesson Next can be clicked", L.step_ix == 1)
			await _click(hud.lc.close)
			check(tag + " lesson Close can be clicked", L.key == null)
			await _setup("lesson_cutaway")
			await _steps(5)
			var editor: Control = hud.xsec_panel
			check(tag + " cutaway editor and controls do not overlap the lesson", editor.is_visible_in_tree() and editor.size.y > 60.0 and not editor.get_global_rect().intersects(hud.lesson_card.get_global_rect()) and not hud.control_panel.get_global_rect().intersects(hud.lesson_card.get_global_rect()))
			await _click(_panel_close(editor))
			check(tag + " cutaway editor Close can be clicked", not main.xsec_open)

			main.last_craft = "saturnv"
			await _start("flight")
			for i in 60:
				if main.flight.vessel != null: break
				await get_tree().process_frame
			await _steps(5)
			check(tag + " flight started", main.flight.vessel != null)
			await _click(main.flight.hud.prog_btns["ascent"])
			check(tag + " launch program can be clicked", main.flight.count != null or main.flight.autopilot.program == "ascent")
			await _click(main.flight.hud.mode_btns["prograde"])
			check(tag + " attitude mode can be clicked", main.flight.autopilot.mode == "prograde")
			var warp: int = main.flight.warp_idx
			await _click(_find("[data-warp=1]"))
			check(tag + " forward warp can be clicked", main.flight.warp_idx != warp)
			await _click(_find("flightExit"))
			check(tag + " flight exit can be clicked", not main.flight.active)

func _panel_close(p: Control) -> Control:
	for b in p.find_children("*", "", true, false):
		if b is Control and (b as Control).is_visible_in_tree() and _text_of(b) == "✕":
			return b
	return null

func _search_edit() -> LineEdit:
	return hud.get_el("presetSearch") as LineEdit

func _search_text() -> String:
	return str(_search_edit().text)

## The rect of every visible Control under `c`, to the depth of `hdepth`.
func _dump(c: Node, depth: int) -> void:
	if c == null or depth > int(args.get("hdepth", "6")): return
	if c is Control and (c as Control).is_visible_in_tree():
		var r := (c as Control).get_global_rect()
		print("%s%s %s [%.1f %.1f %.1f %.1f] min %s %s" % ["  ".repeat(depth), c.get_class(), c.get_script().resource_path.get_file() if c.get_script() else "",
			r.position.x, r.position.y, r.size.x, r.size.y, (c as Control).get_combined_minimum_size(), _text_of(c as Control).left(24)])
		if c is Label and (c as Label).autowrap_mode != TextServer.AUTOWRAP_OFF:
			print("%s  lines %d hang %s" % ["  ".repeat(depth), (c as Label).get_line_count(), c.get("hang")])
		for k in c.get_children():
			_dump(k, depth + 1)

# ---- frame timing ------------------------------------------------------------------
func _perf() -> void:
	var processing: bool = main.is_processing()
	main.set_process(false)
	var clock: float = main.state.time
	await _steps(120)
	var shown: Array = []
	var hidden: Array = []
	for block in 8:
		var on := block % 2 == 0
		hud.visible = on
		await _steps(5)
		var t := Time.get_ticks_usec()
		for i in 60:
			main.animate(1.0 / 60.0)
			await get_tree().process_frame
			var now := Time.get_ticks_usec()
			(shown if on else hidden).append((now - t) / 1000.0)
			t = now
	check("performance frames advance the simulation clock once each", absf(main.state.time - clock - 640.0 / 60.0) < 1e-7)
	hud.visible = true
	main.set_process(processing)
	print("HUDCHECK PERF %s shown %s hidden %s" % [args.get("hstate", ""), _stats(shown), _stats(hidden)])

static func _stats(a: Array) -> String:
	var s := a.duplicate()
	s.sort()
	var sum := 0.0
	for v in s: sum += v
	return "mean %.2f p99 %.2f max %.2f ms" % [sum / s.size(), s[ceili(s.size() * 0.99) - 1], s[-1]]
