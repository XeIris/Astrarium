extends SceneTree

# Production Spaceflight guidance with live parents; the frozen runner deliberately uses static bodies.
#   Godot --headless --path . --script res://tools/sharedflightcheck.gd [-- only=saturnv,shuttle]
const Catch = preload("res://tools/coursecheck.gd").Catch
class Driver extends Spaceflight:
	func _init(_ctx: Dictionary) -> void:
		pass
	func update_visual(_dt: float, _seconds: float) -> void:
		pass

func number(bits: String) -> float:
	return bits.hex_decode().decode_double(0)

func _init() -> void:
	var logger := Catch.new()
	OS.add_logger(logger)
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/fixtures/flight_fixture.json"))
	var failures := 0
	var completed := 0
	var wanted: Array = ["saturnv", "falcon9", "shuttle", "starship"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("only="): wanted = Array(a.substr(5).split(",", false)).filter(func(id): return wanted.has(id))
	for sc in fixture.scenarios:
		if not wanted.has(sc.id): continue
		var flight := Driver.new({})
		flight.state = SimState.new()
		for spec in fixture.bodies:
			var b := Body.new()
			b.id = flight.state.bodies.size(); b.name = spec.name; b.type = spec.type
			b.mass = number(spec.h.mass); b.radius = number(spec.h.radius)
			b.day_length = spec.dayLength
			b.pos.set_v(number(spec.h.pos[0]), number(spec.h.pos[1]), number(spec.h.pos[2]))
			b.vel.set_v(number(spec.h.vel[0]), number(spec.h.vel[1]), number(spec.h.vel[2]))
			flight.state.bodies.append(b)
		var earth: Body = flight.body_named("Earth")
		var start_pos := earth.pos.clone()
		var ship := Vessel.new({"vehicle": Vehicles.VEHICLES[sc.vehicle], "parent": earth, "bodies": flight.bodies()})
		ship.vehicle_key = sc.vehicle
		ship.place_on_pad(25.99684 if sc.vehicle == "starship" else 28.608402, flight.morning_longitude(earth))
		flight.vessel = ship; flight.active = true
		flight.autopilot = Guidance.Autopilot.new(ship)
		flight.autopilot.mode = Guidance.MODE.PROGRADE
		flight.start_count()
		var world := func(seconds: float) -> float:
			var result := NBody.step_physics(flight.state.bodies, seconds / Rocketry.YR_S, 1e-4, 0.0, Callable(), flight.state.last_steps)
			flight.state.last_steps = result.steps
			flight.state.advance_years(result.stepped)
			return result.stepped * Rocketry.YR_S
		var frames := 0
		var worst_clock_error := 0.0
		var finite := true
		var start := Time.get_ticks_usec()
		while frames < int(sc.maxFrames):
			var coast: bool = flight.autopilot.program == "circularize" and ship.throttle == 0.0
			flight.set_warp(Spaceflight.WARPS.find(int(sc.get("coastWarp", 1) if coast else sc.get("warp", 1))))
			flight.state.last_steps = 0
			flight.update(number(fixture.dt), null, world)
			finite = finite and is_finite(ship.coord) and is_finite(ship.met) and is_finite(flight.state.sim_years)
			worst_clock_error = maxf(worst_clock_error, absf(ship.coord - flight.state.sim_years * Rocketry.YR_S))
			frames += 1
			if ship.phase == Vessel.PHASE.DESTROYED or (flight.autopilot.program == null and flight.count == null and ship.phase == Vessel.PHASE.ORBIT): break
		var valid: bool = ship.phase == Vessel.PHASE.ORBIT and flight.autopilot.program == null and frames < int(sc.maxFrames)
		valid = valid and is_finite(ship.telemetry.apo) and is_finite(ship.telemetry.peri)
		var target: float = flight.autopilot.ascent.targetApo
		valid = valid and absf(ship.telemetry.apo - target) < 3000.0
		# The production circularize law stops at 92% of the target periapsis.
		valid = valid and ship.telemetry.peri >= target * 0.92 - 3000.0 and ship.telemetry.peri <= ship.telemetry.apo
		valid = valid and finite
		valid = valid and earth.pos.distance_to(start_pos) > 0.0 and worst_clock_error < 1e-5
		# A timed second plane (the Saturn V's S-II aft interstage) drops within two frames
		# of `afterBelow` after the stage below it.
		for st in ship.stages:
			var j = st.spec.get("jettisonAt")
			if j == null or j.get("afterBelow") == null: continue
			var gap: float = st.dropped_met - ship.stages[st.index - 1].dropped_met
			var on_time: bool = st.dropped_met >= 0.0 and ship.stages[st.index - 1].dropped_met >= 0.0 \
				and gap >= float(j.afterBelow) and gap < float(j.afterBelow) + 2.0 * number(fixture.dt)
			if not on_time: print("SHARED FLIGHT %s %s dropped %s s after the stage below" % [sc.id, st.spec.key, gap])
			valid = valid and on_time
		if not valid: failures += 1
		completed += 1
		print("SHARED FLIGHT %s %s frames=%s met=%s apo=%s peri=%s clock_error=%s wall_ms=%s" % [sc.id, "PASS" if valid else "FAIL", frames, ship.met, ship.telemetry.apo, ship.telemetry.peri, worst_clock_error, (Time.get_ticks_usec() - start) / 1000.0])
	var errors := logger.take()
	for error in errors: printerr("SHARED FLIGHT ENGINE ", error)
	failures += errors.size()
	if wanted.is_empty() or completed != wanted.size(): failures += 1
	OS.remove_logger(logger)
	print("SHARED FLIGHT DONE failures=", failures)
	quit(1 if failures else 0)
