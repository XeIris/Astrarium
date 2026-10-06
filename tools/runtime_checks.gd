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
	lessons.store = ""
	lessons.progress = {"done": {}, "last": null}
	var keys: Array = Presets.PRESET_ORDER
	var baseline := []
	var failures := []
	for pass_i in 5:
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

# Post-warmup growth fails; --verbose additionally exposes leaks on shutdown.
func _soak_check() -> void:
	stage.set_process(false)
	stage.set_process_input(false)
	stage.set_process_unhandled_input(false)
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
				if b.type == "star": stage.edit_body(b, {"mass": b.mass * 1.1}); stage.edit_body(b, {"mass": b.mass / 1.1})
			for i in 10: stage.animate(1.0 / 60.0),
		"true_scale": func():
			stage.set_true_scale(true); for i in 5: stage.animate(1.0 / 60.0)
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
				stage.live_editor._last_apply = Time.get_ticks_msec()
				stage.live_editor.queue({"spinFrac": 0.3})
				stage.remove_body(body.id)
				if stage.live_editor.pending != null or stage.live_editor.body != null:
					failures.append("editor: removed body retained pending work"),
		"paint": func():
			var b: Body = stage.get_stars()[0] if not stage.get_stars().is_empty() else state.bodies[0]
			state.focus_id = b.id
			for k in ["ring", "belt", "cloud", "clear"]: stage._on_paint(k)
			for i in 5: stage.animate(1.0 / 60.0),
		"xsec": func():
			var b: Body = state.bodies[0]
			state.focus_id = b.id
			stage.open_cross_section(true); for i in 5: stage.animate(1.0 / 60.0)
			stage.open_cross_section(false),
		"cam_modes": func():
			for m in ["free", "surface", "orbit"]:
				stage.set_cam_mode(m); for i in 5: stage.animate(1.0 / 60.0),
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
		"start_screen": func():
			stage.quit_to_start(); await stage.get_tree().process_frame
			stage._start("sandbox"); stage.load_preset("solar"); stage.set_process(false),
	}
	for key in only:
		if not feats.has(key):
			printerr("SOAK FAILED: unknown feature ", key)
			stage.get_tree().quit(1)
			return
	stage.load_preset("solar")
	for i in 5: await stage.get_tree().process_frame
	for key in feats:
		if not only.is_empty() and not only.has(key): continue
		var counts := []
		var baseline := []
		for r in rounds:
			# Dynamic readouts shape new font-cache entries if the scenario keeps advancing.
			stage.hud_acc = 0.0
			if key != "start_screen": stage.load_preset("solar")
			# Quick-spawn palettes and placement use the global RNG, outside preset seeding.
			seed(int(_cmd.seed))
			await feats[key].call()
			for i in 3: await stage.get_tree().process_frame
			await stage.get_tree().create_timer(3.0).timeout
			for i in 2: await stage.get_tree().process_frame
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

# Exercise renderer/view teardown; --verbose must report no shutdown leaks.
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
