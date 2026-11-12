extends RefCounted

# Development checks use the real stage and are excluded from exports.
var stage: Node
var state: SimState
var lessons: LessonUI.Course
var flight: Spaceflight
var hud: Hud
var _cmd: Dictionary

func _init(main: Node) -> void:
	stage = main
	state = main.state
	lessons = main.lessons
	flight = main.flight
	hud = main.hud
	_cmd = main._cmd

# Yield rendered frames so the wrapper can detect first-use shader errors.
func _preset_check() -> void:
	stage.set_process(false)
	var rows := []
	var errs := []
	var expected_mergers := ["nsmerger", "binarystar", "stellar_zoo"]
	for key in Presets.PRESET_ORDER:
		print("PRESETCHECK BEGIN ", key)
		stage.load_preset(key)
		var n0 := state.bodies.size()
		for i in 60:
			stage.animate(1.0 / 60.0)
			await stage.get_tree().process_frame
		var n1 := state.bodies.size()
		rows.append("%s: %d->%d" % [key, n0, n1])
		# These scenarios intentionally contain contact mergers.
		if n1 < n0 and not expected_mergers.has(key):
			errs.append("%s: lost %d bodies in one second (%s)" % [key, n0 - n1, Presets.PRESETS[key].name])
		for b in state.bodies:
			if not b.pos.is_finite_v() or not b.vel.is_finite_v() or not is_finite(b.mass):
				errs.append("%s: nonfinite state for body %d" % [key, b.id])
		print("PRESETCHECK END ", key)
	print("PRESETCHECK ROWS ", " | ".join(rows))
	print("PRESETCHECK LOST ", errs)
	print("PRESETCHECK DONE ", Presets.PRESET_ORDER.size())
	stage.get_tree().quit(1 if not errs.is_empty() else 0)

# Compare settled lifecycle counts after one cache-warming pass.
func _leak_check() -> void:
	stage.set_process(false)
	_isolate_input()
	lessons.store = ""
	lessons.progress = {"done": {}, "last": null}
	var keys: Array = Presets.PRESET_ORDER
	var frames_start := _frame_counts()
	var baseline := []
	var failures := []
	for pass_i in 5:
		# Star flares draw from the global RNG, and a FLARE badge first shown in a
		# later pass adds a font size cache. Seeded passes repeat the same work.
		seed(int(_cmd.get("seed", 0)))
		stage.hud_acc = 0.0
		for key in keys:
			stage.load_preset(key)
			for i in 10: stage.animate(1.0 / 60.0)
			await stage.get_tree().process_frame
		stage.load_preset("solar")
		for i in 3: await stage.get_tree().process_frame
		for k in ["falcon9", "saturnv"]:
			await stage.launch_craft(k)
			for i in 20: await stage.get_tree().process_frame
			stage.end_flight()
			for i in 3: await stage.get_tree().process_frame
		# Toast and fade lifetimes use wall time.
		await stage.get_tree().create_timer(5.0).timeout
		# A timed-out SceneTreeTimer is released after the frame's callbacks.
		for i in 2: await stage.get_tree().process_frame
		var marked := false
		for i in 600:
			marked = _mark_input()
			if marked: break
			await stage.get_tree().process_frame
		if not marked:
			printerr("LEAKCHECK FAILED: OS input arrived in every frame for 600 frames")
			stage.get_tree().quit(1)
			return
		if not _drew_since(frames_start, "LEAKCHECK"): return
		frames_start = _frame_counts()
		_fill_glyph_caches()
		var current := [int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))]
		if pass_i == 0:
			baseline = current
		else:
			for metric in 4:
				if current[metric] > baseline[metric]:
					failures.append("pass %d metric %s grew %d->%d" % [pass_i,
						["objects", "resources", "nodes", "orphans"][metric], baseline[metric], current[metric]])
		print("LEAKCHECK pass %d objects=%d resources=%d nodes=%d vmem=%.1fMB" % [pass_i,
			Performance.get_monitor(Performance.OBJECT_COUNT),
			Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
	print("LEAKCHECK FAILURES ", failures)
	print("LEAKCHECK DONE")
	stage.get_tree().quit(1 if not failures.is_empty() else 0)

# Holds a transient state until the renderer has drawn it. Awaiting process_frame is not
# enough: a covered window keeps processing without drawing. Headless never draws.
func _drawn_frame() -> void:
	var drawn := Engine.get_frames_drawn()
	var deadline := Time.get_ticks_msec() + 10000
	await stage.get_tree().process_frame
	if DisplayServer.get_name() == "headless": return
	while Engine.get_frames_drawn() == drawn:
		if Time.get_ticks_msec() >= deadline:
			printerr("SOAK FAILED: no frame drawn in 10 s; is the window covered?")
			stage.get_tree().quit(1)
			return
		await stage.get_tree().process_frame

# Post-warmup growth fails; --verbose additionally exposes leaks on shutdown.
func _soak_check() -> void:
	stage.set_process(false)
	stage.set_process_input(false)
	stage.set_process_unhandled_input(false)
	_isolate_input()
	if not _cmd.has("seed"): _cmd.seed = 0
	lessons.store = ""
	lessons.progress = {"done": {}, "last": null}
	var rounds := int(_cmd.get("rounds", 4))
	if rounds < 3:
		printerr("SOAK FAILED: at least three rounds are required")
		stage.get_tree().quit(1)
		return
	var only: PackedStringArray = str(_cmd.get("soak", "")).split(",", false)
	var failures := []
	var fallback_assets: bool = str(_cmd.get("soakassets", "1")) == "0"
	if fallback_assets:
		for key in Vehicles.VEHICLES: CraftAssets.CACHE[key] = null
	var feats := {
		"spawn_remove": func():
			for t in ["star", "planet", "gas-giant", "bh", "neutron", "white-dwarf", "world"]:
				stage.spawn_orbiting(t)
			for i in 20: stage.animate(1.0 / 60.0)
			await _drawn_frame()
			while state.bodies.size() > 1: stage.remove_body(state.bodies[-1].id)
			# Flashes age in animate(), so a wall-clock wait cannot settle them.
			var was_paused: bool = state.paused
			state.paused = true
			for i in 900:
				if stage.flashes.is_empty(): break
				stage.animate(1.0 / 60.0)
			state.paused = was_paused
			if not stage.flashes.is_empty(): failures.append("spawn_remove: flashes did not settle"),
		"edit_mass": func():
			for b in state.bodies.duplicate():
				if b.type == "star":
					stage.edit_body(b, {"mass": b.mass * 1.1})
					for i in 5: stage.animate(1.0 / 60.0)
					await _drawn_frame()
					stage.edit_body(b, {"mass": b.mass / 1.1})
			for i in 10: stage.animate(1.0 / 60.0),
		"true_scale": func():
			stage.set_true_scale(true); for i in 5: stage.animate(1.0 / 60.0)
			await _drawn_frame()
			stage.set_true_scale(false); for i in 5: stage.animate(1.0 / 60.0),
		"editor": func():
			for spec in [{"type": "star", "mass": 1.0, "radiusSun": 100.0},
				{"type": "neutron", "mass": 1.4}, {"type": "planet", "mass": 3e-6},
				{"type": "bh", "mass": 1e-15}]:
				stage.clear_bodies()
				var body: Body = stage.spawn_body(spec)
				state.focus_id = body.id
				stage.open_cross_section()
				stage.live_editor.curve.set_focus(true)
				for spin in [0.1, 0.2]:
					stage.edit_body(body, {"spinFrac": spin})
					stage.show_cross_section(body)
					stage.live_editor.sync(body)
					await stage.get_tree().process_frame
				stage.edit_body(body, {"name": "Edited", "pos": [1.0, 2.0, 3.0], "vel": [0.1, 0.0, 0.0]})
				stage.edit_body(body, {"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0]})
				if body.climate != null:
					var comp: CompositionEditor = stage.live_editor.comp
					comp._on_mix("venus")
					stage.live_editor._flush()
					stage.live_editor.sync(body)
					comp._on_remove("pSO2")
					comp._on_mix("earth")
					stage.live_editor._flush()
					stage.live_editor.sync(body)
					await stage.get_tree().process_frame
				stage.live_editor._last_apply = Time.get_ticks_msec()
				stage.live_editor.queue({"spinFrac": 0.3})
				stage.remove_body(body.id)
				if stage.live_editor.pending != null or stage.live_editor.body != null:
					failures.append("editor: removed body retained pending work")
			for mix in ["earth", "venus", "bare", Composition.DRAWN]:
				stage.foundry.set_type("planet")
				stage.foundry.comp._on_mix(mix)
				stage.foundry.update()
				await stage.get_tree().process_frame,
		"paint": func():
			var b: Body = stage.get_stars()[0] if not stage.get_stars().is_empty() else state.bodies[0]
			state.focus_id = b.id
			for k in ["ring", "belt", "cloud"]: stage._on_paint(k)
			for i in 5: stage.animate(1.0 / 60.0)
			await _drawn_frame()
			stage._on_paint("clear")
			for i in 5: stage.animate(1.0 / 60.0),
		"xsec": func():
			var b: Body = state.bodies[0]
			state.focus_id = b.id
			stage.open_cross_section(true); for i in 5: stage.animate(1.0 / 60.0)
			await _drawn_frame()
			stage.open_cross_section(false),
		"cam_modes": func():
			# Solar has no home world, so its surface mode falls back to orbit.
			stage.load_preset("trisolaris")
			for m in ["free", "surface", "orbit"]:
				stage.set_cam_mode(m); for i in 5: stage.animate(1.0 / 60.0)
				if state.cam_mode != m: failures.append("cam_modes: %s fell back to %s" % [m, state.cam_mode])
				await _drawn_frame(),
		"quality": func():
			for q in ["high", "low", "medium"]:
				stage.set_render_quality(q); stage.set_lighting_quality("high" if q == "high" else "low")
				await stage.get_tree().process_frame
			for i in 4: stage.set_band(i); await stage.get_tree().process_frame
			stage.set_band(0),
		"lessons": func():
			lessons.progress = {"done": {}, "last": null}
			stage.set_app_mode("learn", {"quiet": true})
			for e in Lessons.LESSON_ORDER:
				var steps: Array = Lessons.find_lesson(e.key).lesson.steps
				for si in steps.size():
					lessons.open_lesson(e.key, si)
					for i in 2: stage.animate(1.0 / 60.0)
				await stage.get_tree().process_frame
			stage.set_app_mode("sandbox"),
		"model_viewer": func():
			CraftAssets.craft_models_ready(Vehicles.VEHICLES.keys())
			for k in Vehicles.VEHICLES:
				stage.show_model(k)
				if fallback_assets and stage.model_view.craft.authored:
					failures.append("model_viewer: expected fallback for " + str(k))
				for i in 5:
					stage.animate(1.0 / 60.0)
					await stage.get_tree().process_frame
			stage.close_model_viewer(),
		"flight_stage": func():
			await stage.launch_craft("saturnv")
			state.paused = false
			flight.run_program("ascent")
			for i in 900: stage.animate(1.0 / 60.0)
			if not flight.active or flight.vessel.met < 14.9 or flight.vessel.phase != Vessel.PHASE.ASCENT:
				failures.append("flight_stage: ascent did not execute")
			for s in 3:
				# A fueled, burning stage refuses separation; exhaust it to exercise the transition.
				flight.vessel.current_stage.prop = 0.0
				flight.key_action("stage")
				for i in 30: stage.animate(1.0 / 60.0)
			if flight.vessel.stage_events != 3:
				failures.append("flight_stage: expected three separations, got %d" % flight.vessel.stage_events)
			stage._on_flight_cam_cycle(); stage._on_flight_cam_cycle()
			for i in 5: await stage.get_tree().process_frame
			stage.end_flight()
			hud.toast("", 1)
			var deadline := Time.get_ticks_msec() + 3000
			while hud._toast_timer > 0.0 or (hud._toast_tween and hud._toast_tween.is_running()):
				await stage.get_tree().process_frame
				if Time.get_ticks_msec() >= deadline:
					printerr("SOAK FAILED: flight notification did not settle")
					stage.get_tree().quit(1)
					return,
		"flight_catch": func():
			# The program button restarts the flight as a booster coming home to a
			# tower, which builds the complex and its arms mid-flight.
			await stage.launch_craft("starship")
			state.paused = false
			flight.run_program("catch")
			for i in 300: stage.animate(1.0 / 60.0)
			if flight.vessel.catch_tower == null or flight.site == null or flight.autopilot.program != "catch":
				failures.append("flight_catch: the return did not start")
			stage.end_flight()
			hud.toast("", 1)
			var deadline := Time.get_ticks_msec() + 3000
			while hud._toast_timer > 0.0 or (hud._toast_tween and hud._toast_tween.is_running()):
				await stage.get_tree().process_frame
				if Time.get_ticks_msec() >= deadline:
					printerr("SOAK FAILED: flight notification did not settle")
					stage.get_tree().quit(1)
					return,
		"scenario": func():
			# Developer jumps: an ascent fast-forwarded through a separation (its falling
			# stage and trail laid undrawn) and a built booster return.
			for spec in ["falcon9:fairing", "starship:tower_catch"]:
				if await stage.jump_scenario(spec) != "": failures.append("scenario: %s did not jump" % spec)
				for i in 30: stage.animate(1.0 / 60.0)
			# Left in flight mode: the first switch from the sandbox shapes the flight
			# HUD's text once, which is not the jump's to answer for.
			stage.end_flight()
			hud.toast("", 1)
			var deadline := Time.get_ticks_msec() + 3000
			while hud._toast_timer > 0.0 or (hud._toast_tween and hud._toast_tween.is_running()):
				await stage.get_tree().process_frame
				if Time.get_ticks_msec() >= deadline:
					printerr("SOAK FAILED: scenario notification did not settle")
					stage.get_tree().quit(1)
					return,
		"showcase": func():
			for name in ["Earth", "Mars"]:
				stage.set_app_mode("showcase", {"body": name})
				for i in 30: stage.animate(1.0 / 60.0)
				for pins in 3:
					stage.showcase.drop_pin()
					for i in 5: stage.animate(1.0 / 60.0)
				await _drawn_frame()
				stage.set_app_mode("sandbox")
				for i in 5: stage.animate(1.0 / 60.0),
		"surface": func():
			for name in ["Earth", "Mars"]:
				stage.set_app_mode("showcase", {"body": name})
				stage.showcase.drop_pin()
				stage.showcase.stand()
				stage.showcase.visit.site.finish_now()
				for i in 20: stage.animate(1.0 / 60.0)
				await _drawn_frame()
				stage.showcase.leave_surface()
				stage.set_app_mode("sandbox")
				for i in 5: stage.animate(1.0 / 60.0),
		"observatory": func():
			# Enter, every site, dates at both ends of the range and past it, the overlays,
			# a running clock, and back out.
			stage.set_app_mode("observatory")
			var o: Observatory = stage.observatory
			# Round the picker, its fades and each site's film.
			for step in 3:
				o.picker_step(1)
				for i in 40: stage.animate(1.0 / 60.0)
				await _drawn_frame()
			o.observe()
			for key in ObservatorySites.ORDER:
				o.set_site(key)
				for d in ["1926-01-01 03:00", "2126-12-31 22:00", "2400-06-21 00:00"]:
					o.set_date_text(d)
					for i in 3: stage.animate(1.0 / 60.0)
			o.set_custom(10.0, 20.0, 100.0)
			for i in 3: stage.animate(1.0 / 60.0)
			for v in ["lines", "names", "bounds"]: stage._on_obs_action("view", v)
			o.set_rate("3600x")
			for i in 10: stage.animate(1.0 / 60.0)
			await _drawn_frame()
			for v in ["lines", "names", "bounds"]: stage._on_obs_action("view", v)
			# The desk: an optical frame held beside a radio map, and away again.
			o.set_rate("pause")
			o.set_site("paranal")
			o.set_date_text("2026-11-05 02:00")
			for i in 3: stage.animate(1.0 / 60.0)
			o.desk.set_instrument("fors2")
			o.desk.exposure = 0.01
			o.desk.nd = 5.0
			o.desk.set_target_text("Saturn")
			o.desk.expose()
			o.desk.finish_into_frame()
			o.desk.hold()
			o.desk.set_instrument("lovell_l")
			o.desk.set_target_text("Cas A")
			o.desk.expose()
			o.desk.finish_into_frame()
			for i in 3: stage.animate(1.0 / 60.0)
			await _drawn_frame()
			o.desk.release_hold()
			stage.set_app_mode("sandbox"),
		"galaxy": func():
			# In from the orrery, every framing, layer and rate, the tracers stepping, and
			# out again through an orrery scenario.
			stage.load_preset("gal_milkyway")
			var g: GalaxyScene = stage.galaxy
			g.wait_tracers()
			for f in ["whole", "face", "edge", "sun", "centre"]:
				stage._on_galaxy_action("frame", f)
				for i in 6: stage.animate(1.0 / 60.0)
				await _drawn_frame()
			for l in ["tracers", "stars", "glow", "tracers", "stars", "glow"]:
				stage._on_galaxy_action("layer", l)
				stage.animate(1.0 / 60.0)
			for r in [20.0, 0.0, 5.0]:
				stage._on_galaxy_action("rate", r)
				for i in 4: stage.animate(1.0 / 60.0)
			stage._on_slider("galExposure", 0.5)
			stage._on_slider("galExposure", 0.0)
			# Every landmark flown to and framed.
			for lm in GalLandmarks.of("milky_way"):
				stage._on_galaxy_action("landmark", String(lm.id))
				for i in 3: stage.animate(1.0 / 60.0)
				await _drawn_frame()
			# Reset view and sky inside the scene, which has no orrery preset to read.
			stage._on_reset_view()
			stage._on_sky_reset()
			stage.animate(1.0 / 60.0)
			await _drawn_frame()
			if g.tracers == null or g.tracers.steps == 0: failures.append("galaxy: the tracers did not step")
			stage.load_preset("solar")
			if g.active or g.visual != null: failures.append("galaxy: the scene outlived the switch to solar"),
		"start_screen": func():
			stage.quit_to_start(); await stage.get_tree().process_frame
			stage._start("sandbox"); stage.load_preset("solar"); stage.set_process(false),
	}
	for key in only:
		if not feats.has(key):
			printerr("SOAK FAILED: unknown feature ", key)
			stage.get_tree().quit(1)
			return
	# check.py runs one feature per process and compares this list with its own.
	print("SOAK FEATURES ", ",".join(feats.keys()))
	stage.load_preset("solar")
	for i in 5: await stage.get_tree().process_frame
	for key in feats:
		if not only.is_empty() and not only.has(key): continue
		var counts := []
		var baseline := []
		for r in rounds:
			var frames_start := _frame_counts()
			# Dynamic readouts shape new font-cache entries if the scenario keeps advancing.
			stage.hud_acc = 0.0
			if key != "start_screen": stage.load_preset("solar")
			# Quick-spawn palettes and placement use the global RNG, outside preset seeding.
			seed(int(_cmd.seed))
			await feats[key].call()
			for i in 3: await stage.get_tree().process_frame
			await stage.get_tree().create_timer(3.0).timeout
			for i in 2: await stage.get_tree().process_frame
			var marked := false
			for i in 600:
				marked = _mark_input()
				if marked: break
				await stage.get_tree().process_frame
			if not marked:
				printerr("SOAK FAILED: OS input arrived in every frame for 600 frames")
				stage.get_tree().quit(1)
				return
			if not _drew_since(frames_start, "SOAK"): return
			_fill_glyph_caches()
			var current := [int(Performance.get_monitor(Performance.OBJECT_COUNT)),
				int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
				int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
				int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))]
			counts.append("%d/%d/%d/%d" % current)
			if r == 0:
				baseline = current
			else:
				for metric in 4:
					if current[metric] > baseline[metric]:
						failures.append("%s round %d metric %s grew %d->%d" % [key, r,
							["objects", "resources", "nodes", "orphans"][metric], baseline[metric], current[metric]])
		print("SOAK %-14s %s" % [key, "  ".join(counts)])
	print("SOAK FAILURES ", failures)
	print("SOAK DONE")
	stage.get_tree().quit(1 if not failures.is_empty() else 0)

func _frame_counts() -> Array[int]:
	return [Engine.get_process_frames(), Engine.get_frames_drawn()]

# macOS stops drawing a fully covered window but the main loop runs on, so a covered
# run would otherwise pass without touching the GPU. A ratio, as a slow machine draws
# every frame it processes. Quits with a failure when the window did not draw.
func _drew_since(start: Array[int], check: String) -> bool:
	var counts := _frame_counts()
	var processed: int = counts[0] - start[0]
	var drawn: int = counts[1] - start[1]
	if DisplayServer.get_name() == "headless" or drawn * 2 >= processed:
		return true
	printerr("%s FAILED: drew %d of %d frames; is the window covered?" % [check, drawn, processed])
	stage.get_tree().quit(1)
	return false

# The check window still receives the desktop pointer, and keys while it has focus.
# Hovering the GUI creates state (hover LabelSettings, a 2D space state, timers), so
# measurements ignore input.
func _isolate_input() -> void:
	stage.get_viewport().set_disable_input(true)
	# window_input still fires with input disabled.
	stage.get_window().window_input.connect(_on_window_input)

var _input_frame := -1
var _marker_id := 0

func _on_window_input(e: InputEvent) -> void:
	if e.get_instance_id() != _marker_id: _input_frame = Engine.get_process_frames()

# Debug builds keep every event parsed in the latest frame that had input (Input's
# same-frame reuse guard) until a later frame parses one, so the last OS burst stays
# alive. OS events are parsed before scripts run, so in a frame without any, one
# off-window motion leaves the guard holding just it. Callers await between tries
# themselves: an awaiting helper holds an extra GDScriptFunctionState when it waits.
func _mark_input() -> bool:
	if _input_frame == Engine.get_process_frames():
		return false
	var e := InputEventMouseMotion.new()
	e.position = Vector2(-1, -1)
	e.global_position = e.position
	_marker_id = e.get_instance_id()
	Input.parse_input_event(e)
	Input.flush_buffered_events()
	return true

# HUD faces use quarter-pixel positioning, so the TextServer caches each glyph once
# per phase it is drawn at, and a full cache page adds an Image and an ImageTexture.
# Body ids are session-unique, so "#<id> NAME" headings land on new phases every
# round. Rasterizing every phase at each size already in use makes the cache's
# bounded fill a warm-up; new sizes, faces and glyphs outside this set still count.
const _GLYPH_WARMUP_EXTRA := "☉⊕−–—…→←"

func _fill_glyph_caches() -> void:
	var ts := TextServerManager.get_primary_interface()
	var chars := ""
	for c in range(0x20, 0x7f): chars += char(c)
	for c in range(0xa1, 0x100): chars += char(c)
	chars += _GLYPH_WARMUP_EXTRA
	# Shaping gives the glyphs actually drawn: tabular-figure alternates, fallbacks.
	var glyphs := {}
	for f in HudTheme._fonts.values():
		var line := TextLine.new()
		line.add_string(chars, f, 16)
		for g in ts.shaped_text_get_glyphs(line.get_rid()):
			if not glyphs.has(g.font_rid): glyphs[g.font_rid] = {}
			glyphs[g.font_rid][int(g.index)] = true
	for rid in glyphs:
		for info in ts.font_get_size_cache_info(rid):
			for index in glyphs[rid]:
				for phase in 4:
					var g: int = index | (phase << 27)
					ts.font_render_glyph(rid, info.size_px, g)
					# Uploads the page, which a draw would otherwise do later.
					ts.font_get_glyph_texture_rid(rid, info.size_px, g)

# Exercise renderer/view teardown; --verbose must report no shutdown leaks.
# No _drew_since: this ends in about 3 s, and a covered window was still drawing until then.
func _shutdown_check() -> void:
	stage.load_preset("solar")
	for i in 5: await stage.get_tree().process_frame
	for v in [0.9, 0.75, 0.6, 0.5, 0.65, 0.8, 1.0]:
		stage._on_slider("renderScale", v)
		await stage.get_tree().process_frame
	for e in Lessons.LESSON_ORDER:
		var steps: Array = Lessons.find_lesson(e.key).lesson.steps
		var si := steps.find_custom(func(s): return str(s).contains("cutaway"))
		if si >= 0:
			lessons.open_lesson(e.key, si)
			print("SHUTDOWNCHECK cutaway lesson ", e.key, " step ", si)
			break
	for i in 10: await stage.get_tree().process_frame
	stage.open_model_world()
	for i in 10: await stage.get_tree().process_frame
	await stage.launch_craft("saturnv")
	if not flight.active or flight.craft == null:
		printerr("SHUTDOWNCHECK FAILED: flight did not start")
		stage.get_tree().quit(1)
		return
	for i in 60: await stage.get_tree().process_frame
	print("SHUTDOWNCHECK DONE")
	stage.get_tree().quit()
