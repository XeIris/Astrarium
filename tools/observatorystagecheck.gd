extends SceneTree

# The Observatory on the real stage (docs/physics/observatory.md):
#   Godot --headless --path . --script res://tools/observatorystagecheck.gd
# How the mode meets the rest of the program: which scenario and camera requests it
# refuses or ends on, what it restores on the way out, and whether the running clock
# keeps the sky on its sources. The sky itself is observatorycheck's.

var stage: Node
var checks := 0
var failures := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("OBSERVATORYSTAGECHECK FAIL ", what)

func frames(n := 2) -> void:
	for i in n:
		stage.animate(1.0 / 60.0)
		await process_frame

func enter() -> void:
	if not stage.at_start: stage.quit_to_start()
	await process_frame
	stage._start("observatory", true)
	await frames(3)

func sandbox() -> void:
	stage.quit_to_start()
	await process_frame
	stage._start("sandbox")
	await frames(2)

func _initialize() -> void:
	stage = load("res://main.tscn").instantiate()
	root.add_child(stage)
	await process_frame
	stage.set_process(false)
	await scenario_choice()
	await star_epochs()
	await leaving()
	await view_keys()
	await custom_height()
	await running_clock()
	await held_seasons()
	await a_frame()
	# Last, as it frees the stage: a frame in flight is waited out on the way down.
	var desk: ObservatoryInstruments = stage.observatory.desk
	check(desk.expose() == "", "a second frame starts")
	root.remove_child(stage)
	stage.free()
	check(not desk.is_exposing(), "shutting down waits out a frame in flight")
	print("OBSERVATORYSTAGECHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

# The scenario list is not offered, and a scenario reached some other way ends the mode:
# its clock would otherwise read a Sun the new scenario does not have (any script error
# fails this check in check.py).
func scenario_choice() -> void:
	await enter()
	var hud = stage.hud
	check(not hud.tabs.scenarioPanel.is_visible_in_tree(), "the scenario tab is hidden in the Observatory")
	check(not hud.scenario_panel.is_visible_in_tree(), "the scenario panel is hidden in the Observatory")
	hud.preset_chosen.emit("sandbox")
	check(not stage.observatory.active and stage.state.app_mode == "sandbox", "another scenario leaves the mode")
	check(stage.state.preset_key == "sandbox" and stage.state.cam_mode == "orbit", "and the scenario takes the stage (%s, %s)" % [stage.state.preset_key, stage.state.cam_mode])
	await frames(2)
	check(is_finite(stage.state.sim_years), "the clock is finite after the scenario")
	check(hud.scenario_panel.is_visible_in_tree(), "the scenario panel returns with the sandbox")

# reset_stage frees the catalogue, so a new one must be carried to the date.
func star_epochs() -> void:
	await enter()
	var o: Observatory = stage.observatory
	var first: float = stage.bright_stars.year
	check(is_finite(first), "the stars are carried to the date (%s)" % first)
	await sandbox()
	check(stage.bright_stars == null, "the sandbox frees the catalogue")
	await enter()
	check(stage.bright_stars != null and absf(stage.bright_stars.year - EarthFrame.year_of(o.tt())) < 0.51,
		"a rebuilt catalogue is carried to the date on re-entry (%s)" % stage.bright_stars.year)
	# The overlay's figures cost milliseconds: they move no more often than the stars do.
	o.set_rate("pause")
	var at: float = o.overlay.year
	o.set_civil(o.civil() + 30.0)
	await frames(2)
	check(o.overlay.year == at, "a month does not recompute the figures")
	o.set_civil(o.civil() + 365.25)
	check(o.overlay.year != at, "a year does")

# What the mode changed goes back when it ends, by either way out.
func leaving() -> void:
	await sandbox()
	var want_scale: float = stage.state.time_scale
	stage.observer.fov = 41.0
	var want_fov: float = stage.observer.fov
	stage.state.paused = false
	await enter()
	var o: Observatory = stage.observatory
	o.set_rate("pause")
	stage.set_app_mode("sandbox")
	await frames(2)
	var earth: Body = stage.state.body_named("Earth")
	check(earth != null and earth.viz.group.visible, "Earth is drawn again after the mode")
	check(not stage.state.paused, "pausing the Observatory does not pause the sandbox")
	check(stage.observer.fov == want_fov, "the surface view's field returns: %s, want %s" % [stage.observer.fov, want_fov])
	var preset_scale: float = float(stage.state.preset.get("timeScale", 2.0))
	check(stage.state.time_scale == preset_scale, "the solar preset's clock returns: %s, want %s" % [stage.state.time_scale, preset_scale])
	check(want_scale > 0.0, "the sandbox had a clock")
	await enter()
	stage.observatory.set_rate("pause")
	await sandbox()
	check(not stage.state.paused, "quitting from a paused Observatory does not pause the next sandbox")

## A press of `action`'s binding through the stage's own key handler.
func press(action: String) -> void:
	var b: Array = stage.controls.bindings[action]
	var e := InputEventKey.new()
	e.pressed = true
	e.physical_keycode = b[0]
	e.shift_pressed = b[1]; e.ctrl_pressed = b[2]; e.alt_pressed = b[3]
	stage._key(e)

func view_keys() -> void:
	await enter()
	for action in ["free_view", "surface_view"]:
		press(action)
		check(stage.state.cam_mode == "surface", "%s leaves the Observatory's camera alone (%s)" % [action, stage.state.cam_mode])
	var o: Observatory = stage.observatory
	o.open_picker()
	await frames(2)
	for action in ["free_view", "surface_view"]:
		press(action)
		check(stage.state.cam_mode == "surface" and o.picking, "%s leaves the picker's film alone" % action)
	await picker_keys()
	await sandbox()
	press("free_view")
	check(stage.state.cam_mode == "free", "the same key still works in the sandbox")
	press("free_view")

# The picker's keys are bindings like any other: rebound, the old key does nothing.
func picker_keys() -> void:
	var o: Observatory = stage.observatory
	var input := func(code: int) -> void:
		var e := InputEventKey.new()
		e.pressed = true
		e.physical_keycode = code
		stage._input(e)
	var saved: Dictionary = stage.controls.bindings
	stage.controls.bindings = saved.duplicate(true)
	stage.controls.bindings.site_next = [KEY_N, false, false, false]
	stage.controls.bindings.site_observe = [KEY_O, false, false, false]
	input.call(KEY_RIGHT)
	check(o._swap == "", "the old key for the next site is released")
	input.call(KEY_N)
	check(o._swap != "", "the rebound key moves to the next site")
	input.call(KEY_ENTER)
	check(o.picking, "the old key for Observe is released")
	input.call(KEY_O)
	check(not o.picking, "the rebound key observes")
	stage.controls.bindings = saved

# A custom site has no terrain tile: its air and ground come from its stated height.
func custom_height() -> void:
	await enter()
	var o: Observatory = stage.observatory
	o.set_custom(10.0, 20.0, 4000.0)
	await frames(2)
	check(absf(o._local_pos.y - 4002.0) < 0.01, "the eye stands on a custom site's height: %.1f m" % o._local_pos.y)
	check(o.site_scene.patch_y == 4000.0, "the ground is at that height: %.1f m" % o.site_scene.patch_y)
	o.set_custom(NAN, NAN, 0.0)
	await frames(2)
	check(absf(o._local_pos.y - 2.0) < 0.01, "and follows it down: %.1f m" % o._local_pos.y)

# 30 days at the clock: the Moon stays on its theory, the date does not jump, and the
# camera is where the site is on the Earth that was just restated.
func running_clock() -> void:
	await enter()
	var o: Observatory = stage.observatory
	o.set_rate("pause")
	o.set_civil(Observatory.julian_day(2026, 11, 5))
	var hour := 3600.0 / Rocketry.YR_S
	var t0 := o.tt()
	var worst := 0.0
	var worst_jump := 0.0
	var moon: Body = stage.state.body_named("Moon")
	var earth: Body = stage.state.body_named("Earth")
	for i in 720:
		var before := o.tt()
		stage.step_physics(hour)
		stage._commit_positions(true)
		stage.animate(0.0)
		worst_jump = maxf(worst_jump, absf(o.tt() - before - 1.0 / 24.0))
		var at := Observatory.solar_state(o.tt())
		var want: DVec3 = at.Moon[0].sub(at.Earth[0]).normalized()
		worst = maxf(worst, rad_to_deg(acos(clampf(moon.pos.sub(earth.pos).normalized().dot(want), -1.0, 1.0))))
	await process_frame
	check(worst < 0.005, "the Moon stays on LunarTheory over 30 days: worst %.4f°" % worst)
	check(worst_jump < 1e-3, "the clock runs through the restatements: worst %s days off" % String.num_scientific(worst_jump))
	check(absf(o.tt() - t0 - 30.0) < 1e-2, "30 days passed: %.4f" % (o.tt() - t0))
	# The eye: Earth plus the site's offset; the Moon seen from it, with its parallax.
	var k: float = stage.state.scene_scale
	var eye: DVec3 = earth.scene_pos.add(EarthFrame.to_scene(o.frame.offset).scaled(k / Rocketry.AU_M))
	check(stage.cam_pos.distance_to(eye) / k * Rocketry.AU_M < 1.0, "the camera stands at the site: %.3f m off" % (stage.cam_pos.distance_to(eye) / k * Rocketry.AU_M))
	var seen: DVec3 = moon.scene_pos.sub(stage.cam_pos).normalized()
	var geo: DVec3 = moon.scene_pos.sub(earth.scene_pos).normalized()
	var parallax := rad_to_deg(acos(clampf(seen.dot(geo), -1.0, 1.0)))
	print("OBSERVATORYSTAGECHECK Moon off LunarTheory: worst %.4f° over 30 days; parallax now %.3f°" % [worst, parallax])
	check(parallax > 0.0 and parallax < 1.1, "the Moon's parallax from the site: %.3f°" % parallax)
	await sandbox()

# A frame's maps and catalogues are loaded before its worker starts, since an exported
# build's maps need the main thread: a worker asking would hang on a frame it can't get.
func a_frame() -> void:
	await enter()
	var o: Observatory = stage.observatory
	o.set_rate("pause")
	o.set_site("paranal")
	o.set_date_text("2026-11-05 08:30")
	await frames(2)
	var desk: ObservatoryInstruments = o.desk
	desk.set_instrument("fors2")
	desk.exposure = 0.01
	desk.nd = 5.0
	check(desk.set_target_text("Jupiter"), "Jupiter is a target")
	PlanetDisc._maps.clear()
	var why := desk.expose()
	check(why == "", "Jupiter's frame starts: %s" % why)
	check(PlanetDisc._maps.has("Jupiter"), "its map is on the main thread before the worker reads it")
	check(not SkyField._v.is_empty(), "so are the catalogues")
	desk.finish_into_frame()
	check(not desk.frame.is_empty(), "the frame arrives")

# The season follows the surface as drawn. Held to Earth's real axis, as a flight or the
# Observatory holds a world, uDecl is the Sun's real declination; once the hold lapses it is
# the orrery's own tilt again, with nothing left of the hold.
func held_seasons() -> void:
	await sandbox()
	stage.load_preset("solar")
	stage.state.paused = true
	var earth: Body = stage.state.body_named("Earth")
	var sun: Body = stage.state.body_named("Sun")
	var viz = earth.viz.inner if earth.viz is Bodies.AccretionWrap else earth.viz
	var pole := EarthFrame.to_scene(DVec3.new(0.0, 0.0, 1.0)).to_v3()
	var x := EarthFrame.to_scene(DVec3.new(1.0, 0.0, 0.0)).to_v3()
	for date: Array in [[2026, 12, 21], [2026, 6, 21]]:
		stage.restate_solar(Observatory.julian_day(date[0], date[1], date[2]))
		var want: float = EarthFrame.from_scene(sun.pos.sub(earth.pos)).normalized().z
		for i in 3:
			viz.hold_surface(Basis(x, pole, x.cross(pole)))
			stage.animate(1.0 / 60.0)
			await process_frame
		var got: float = viz.surf_mat.get_shader_parameter("uDecl")
		check(absf(got - want) < 1e-3, "%s: a held Earth's season %.3f against the Sun's sin δ %.3f" % [date, got, want])
		await frames(3)
		var free: float = viz.surf_mat.get_shader_parameter("uDecl")
		var d: Vector3 = sun.pos.sub(earth.pos).normalized().to_v3()
		check(viz.surface.basis.y.dot(Vector3.UP) > 0.9999, "the hold leaves no tilt on the surface")
		check(absf(free - (viz.tilt_q * Vector3.UP).dot(d)) < 1e-3, "%s: the free season is the orrery's tilt again: %.3f" % [date, free])
	stage.state.paused = false
