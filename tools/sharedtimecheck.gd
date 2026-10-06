extends Node

const Catch = preload("res://tools/coursecheck.gd").Catch
class SmallSteps extends Vessel:
	func step_bound() -> float:
		return 1.0 / 4096.0

class CountGuidance extends Guidance.Autopilot:
	var updates := 0
	func update(dt: float) -> void:
		updates += 1
		super.update(dt)

var stage: Node
var checks := 0
var failures := 0
var logger := Catch.new()
var benchmark_only := false

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func frame(label: String, dt: float, truncated := false) -> float:
	var ship: Vessel = stage.flight.vessel
	var coord := ship.coord
	var years: float = stage.state.sim_years
	var parent: Body = ship.parent
	var parent_pos := parent.pos.clone()
	var head := parent.trail_head
	var requested: float = dt * stage.flight.warp() if not stage.state.paused else 0.0
	stage.animate(dt)
	var elapsed := ship.coord - coord
	var world: float = (stage.state.sim_years - years) * Rocketry.YR_S
	check(label + " synchronized coordinate clocks", absf(elapsed - world) <= maxf(1e-7, absf(world) * 2e-11))
	check(label + " world budget remains per frame", stage.state.last_steps <= Derive.STEP_GUARD)
	check(label + " trail committed once", parent.trail_head == (head + (1 if world > 0.0 else 0)) % parent.trail_max)
	if truncated: check(label + " truncates requested time", elapsed > 0.0 and elapsed < requested)
	if world > 0.0: check(label + " moving parent advanced", parent.pos.distance_to(parent_pos) > 0.0)
	else: check(label + " paused parent unchanged", parent.pos.distance_to(parent_pos) == 0.0)
	return elapsed

func orbit(vehicle := "saturnv") -> void:
	stage.flight.begin(vehicle, {"body": "Earth", "mode": "orbit", "alt": 400000.0, "phase": 0.0})
	stage.flight.autopilot = null
	stage.state.paused = false
	stage.flight.set_warp(0)

func _ready() -> void:
	benchmark_only = OS.get_cmdline_user_args().has("bench=1")
	if OS.get_cmdline_user_args().has("native=0"): NBody._native = 0
	var procedural := OS.get_cmdline_user_args().has("assets=0")
	if procedural:
		for id in CraftAssets.CRAFT_ASSETS: CraftAssets.CACHE[id] = null
	if OS.get_cmdline_user_args().has("native=1"):
		check("requested native kernel available", NBody.native_available())
	OS.add_logger(logger)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("sandbox")
	stage.lessons.store = ""
	stage.load_preset("solar")
	orbit()
	if procedural: check("procedural craft selected", not stage.flight.craft.authored)
	print("SHARED TIME CONFIG assets=%s native=%s fixed_dt=%.9f" % ["procedural" if procedural else "optional-authored", NBody.native_available(), 1.0 / 60.0])
	for i in 60: stage.animate(1.0 / 60.0)
	var start := Time.get_ticks_usec()
	for i in 240: stage.animate(1.0 / 60.0)
	print("SHARED TIME BENCH solar-orbit CPU ms/frame=", float(Time.get_ticks_usec() - start) / 240000.0)
	if benchmark_only:
		stage.flight.begin("falcon9", {"body": "Earth", "mode": "pad"})
		if procedural: check("procedural ascent craft selected", not stage.flight.craft.authored)
		stage.flight.start_count()
		for i in 900: stage.animate(1.0 / 60.0)
		start = Time.get_ticks_usec()
		for i in 1800: stage.animate(1.0 / 60.0)
		print("SHARED TIME BENCH falcon9-ascent CPU ms/frame=", float(Time.get_ticks_usec() - start) / 1800000.0)
	if not benchmark_only:
		frame("ordinary orbit", 1.0 / 60.0)
		stage.state.paused = true
		frame("paused", 0.5)
		stage.state.paused = false
		stage.flight.set_warp(5)
		frame("analytic rails", 0.1)
		stage.state.max_step = 1e-8
		stage.flight.set_warp(9)
		frame("world guard on rails", 0.1, true)
		stage.state.max_step = 1e-4
		orbit()
		var old: Vessel = stage.flight.vessel
		var small := SmallSteps.new({"vehicle": old.vehicle, "parent": old.parent, "bodies": old.bodies})
		small.place_in_orbit(400000.0)
		stage.flight.vessel = small
		frame("vessel guard", 2.0, true)
		check("vessel guard visible", small.step_guard_hit)
		var guidance := CountGuidance.new(small)
		stage.flight.autopilot = guidance
		stage.flight.count = {"t": 10.0, "lead": 8.9, "lit": false, "called": {}}
		var no_world := func(_seconds: float) -> float: return 0.0
		stage.flight.update(1.0, null, no_world)
		check("zero accepted time leaves guidance untouched", guidance.updates == 0)
		check("zero accepted time leaves countdown untouched", stage.flight.count.t == 10.0)
		stage.state.paused = true
		frame("paused guidance", 1.0)
		check("pause leaves guidance and countdown untouched", guidance.updates == 0 and stage.flight.count.t == 10.0)
		stage.state.paused = false
		var accepted := frame("accepted guidance", 1.0, true)
		check("guidance runs once despite many integration intervals", guidance.updates == 1)
		check("countdown uses only accepted coordinate time", absf(stage.flight.count.t - (10.0 - accepted)) < 1e-9)
		orbit()
		var ship: Vessel = stage.flight.vessel
		ship.r.set_v(7e6, 0.0, 0.0)
		ship.v.set_v(0.0, 0.0, 0.0)
		var failed_seconds := 1e9
		for i in 12:
			if not Orbit.propagate(ship.r, ship.v, ship.env.mu, failed_seconds, DVec3.new(), DVec3.new()): break
			failed_seconds *= 10.0
		check("failed conic fixture actually fails", not Orbit.propagate(ship.r, ship.v, ship.env.mu, failed_seconds, DVec3.new(), DVec3.new()))
		stage.flight.set_warp(9)
		frame("failed rails fallback", failed_seconds / stage.flight.warp(), true)
		orbit("hailmary")
		frame("before cruise", 0.1)
		var coord_before: float = stage.flight.vessel.coord
		stage.flight.begin_cruise(null, 1.5, stage.flight.missions()[0])
		# A deterministic outward line bypasses the orbital wait for departure.
		if stage.flight.cruise == null:
			var mission: Dictionary = stage.flight.missions()[0]
			stage.flight.vessel.r.copy_from(stage.flight.mission_direction(mission)).scale_in(7e6)
			stage.flight.begin_cruise(null, 1.5, mission)
		check("cruise entered", stage.flight.cruise != null)
		if stage.flight.cruise != null:
			check("cruise transition preserves clock", stage.flight.vessel.coord == coord_before)
			stage.flight.set_warp(9)
			stage.state.max_step = 1e-8
			frame("cruise world guard", 0.1, true)
			check("cruise guard visible", stage.flight.cruise.time_limited)
			stage.state.paused = true
			frame("paused cruise", 1.0)
			stage.state.paused = false
			stage.flight.cruise = null
			stage.flight.cruise_ctx = null
			stage.flight.vessel.throttle = 0.0
			stage.flight.set_warp(0)
			frame("return to local flight", 0.01)
		stage.state.max_step = 1e-4
		orbit("hailmary")
		frame("before lunar transfer", 0.1)
		var moon: Body = stage.flight.body_named("Moon")
		stage.flight.vessel.r.copy_from(moon.pos).sub_in(stage.flight.vessel.parent.pos).scale_in(Rocketry.AU_M)
		DQuat.set_len(stage.flight.vessel.r, 7e6)
		stage.flight.begin_cruise(moon, 1.5)
		check("lunar transfer entered", stage.flight.cruise != null)
		if stage.flight.cruise != null:
			var tau: float = stage.flight.cruise.plan.tauS
			stage.flight.set_warp(9)
			frame("cruise arrival", tau * 1.01 / stage.flight.warp())
			check("arrival returns to destination orbit", stage.flight.cruise == null and stage.flight.vessel.parent == moon and stage.flight.vessel.phase == Vessel.PHASE.ORBIT)
		stage.flight.vessel.parent.alive = false
		for body in stage.state.bodies: body.alive = false
		var stopped: float = stage.flight.vessel.coord
		stage.flight.update(1.0, null, stage._advance_flight_world)
		check("missing parent stops flight", not stage.flight.active and stage.flight.vessel.coord == stopped)
	var errors := logger.take()
	for error in errors: print("SHARED TIME ENGINE ", error)
	check("no engine errors", errors.is_empty())
	print("SHARED TIME DONE checks=%d failures=%d" % [checks, failures])
	OS.remove_logger(logger)
	get_tree().quit(1 if failures else 0)
