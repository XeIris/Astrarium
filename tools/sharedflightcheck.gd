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
		if not a.begins_with("only="): continue
		var known := wanted
		var asked := Array(a.substr(5).split(",", false))
		wanted = asked.filter(func(id): return known.has(id))
		for id in asked.filter(func(id): return not known.has(id)):
			printerr("SHARED FLIGHT unknown only= id ", id)
			failures += 1
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
		var staged := []
		var worst_clock_error := 0.0
		var finite := true
		var start := Time.get_ticks_usec()
		while frames < int(sc.maxFrames):
			# Paced as Mission._pace paces it: coast warp only while apoapsis is more than
			# 150 s off, so the insertion burn is flown at 1× and cut off within a frame.
			var coast: bool = flight.autopilot.program == "circularize" and ship.throttle == 0.0 \
				and ship.telemetry.has("el") and Orbit.time_to_apoapsis(ship.telemetry.el, ship.env.mu) > 150.0
			flight.set_warp(Spaceflight.WARPS.find(int(sc.get("coastWarp", 1) if coast else sc.get("warp", 1))))
			flight.state.last_steps = 0
			flight.update(number(fixture.dt), null, world)
			finite = finite and is_finite(ship.coord) and is_finite(ship.met) and is_finite(flight.state.sim_years)
			worst_clock_error = maxf(worst_clock_error, absf(ship.coord - flight.state.sim_years * Rocketry.YR_S))
			frames += 1
			if staged.is_empty() and ship.stages[0].dropped_met >= 0.0:
				staged = [ship.stages[0].dropped_met - ship.t0, ship.altitude()]
			if ship.phase == Vessel.PHASE.DESTROYED or (flight.autopilot.program == null and flight.count == null and ship.phase == Vessel.PHASE.ORBIT): break
		var valid: bool = ship.phase == Vessel.PHASE.ORBIT and flight.autopilot.program == null and frames < int(sc.maxFrames)
		valid = valid and is_finite(ship.telemetry.apo) and is_finite(ship.telemetry.peri)
		var target: float = flight.autopilot.ascent.targetApo
		# J2's short-period terms swing a near-circular orbit's osculating apsides by
		# ±6 km, so the gates read the highest and lowest altitudes flown over the next
		# revolution (a coast with the world held, which an hour and a half allows).
		var hi := -INF
		var lo := INF
		var period: float = ship.telemetry.el.period if is_finite(float(ship.telemetry.el.period)) else 5400.0
		var coasted := 0.0
		while valid and coasted < period:
			coasted += ship.step(10.0)
			hi = maxf(hi, ship.altitude()); lo = minf(lo, ship.altitude())
		# J2's short-period radial swing, ~J2·R²/a·sin²i: 1.5 km at 28.5°, 4 km at 51.6°.
		var a_m := float(ship.env.radius) + target
		var swing := 1.08262668e-3 * pow(6378137.0, 2.0) / a_m * pow(sin(deg_to_rad(float(ship.telemetry.inc))), 2.0)
		valid = valid and absf(hi - target) < 3000.0 + swing
		# The production circularize law stops at 92% of the target periapsis.
		valid = valid and lo >= target * 0.92 - 3000.0 - swing and lo <= hi
		valid = valid and finite
		valid = valid and earth.pos.distance_to(start_pos) > 0.0 and worst_clock_error < 1e-5
		# A timed second plane (the Saturn V's S-II aft interstage) drops within two frames
		# of `afterBelow` after the stage below it.
		var timed := 0
		for st in ship.stages:
			var j = st.spec.get("jettisonAt")
			if j == null or j.get("afterBelow") == null: continue
			timed += 1
			var gap: float = st.dropped_met - ship.stages[st.index - 1].dropped_met
			var on_time: bool = st.dropped_met >= 0.0 and ship.stages[st.index - 1].dropped_met >= 0.0 \
				and gap >= float(j.afterBelow) and gap < float(j.afterBelow) + 2.0 * number(fixture.dt)
			if not on_time: print("SHARED FLIGHT %s %s dropped %s s after the stage below" % [sc.id, st.spec.key, gap])
			valid = valid and on_time
		# The Shuttle's first stage against JSC-10559 table 2.2-I: SRB separation at
		# 47.3 km, T+124 s, and max-q about 33 kPa, held down by the SSMEs' throttle
		# bucket (docs/physics/srb-separation.md#ascent).
		if sc.id == "shuttle":
			var stage_ok: bool = not staged.is_empty() and absf(float(staged[1]) - 47300.0) < 1000.0 and absf(float(staged[0]) - 124.0) < 2.0
			var q_ok: bool = ship.max_q > 30e3 and ship.max_q < 35e3
			if not stage_ok: print("SHARED FLIGHT shuttle SRB separation %s (T+ s, m), want T+124 s at 47.3 km" % [staged])
			if not q_ok: print("SHARED FLIGHT shuttle max-q %.1f kPa at T+%.1f s, want 30–35 kPa" % [ship.max_q / 1000.0, ship.max_q_t])
			valid = valid and stage_ok and q_ok
		# The orbit against Earth's IAU equator in orrery axes, so the frame is under test
		# and not only the vessel's own pole. The ascent flies the target's azimuth, so it
		# reaches the target inclination, or the pad's latitude if that is higher (the
		# Eastern Range's window allows every target here).
		var lat: float = ship.launch_site.lat
		var h := ship.to_world(ship.r.cross(ship.v), DVec3.new())
		var inc := rad_to_deg(acos(clampf(DQuat.nrm(h).dot(Rocketry.equatorial_dir(0.0, PI / 2.0)), -1.0, 1.0)))
		var want_inc := maxf(float(flight.autopilot.ascent.inclination), rad_to_deg(absf(lat)))
		if absf(inc - want_inc) > 0.2:
			print("SHARED FLIGHT %s inclination %.2f° to Earth's equator, want %.2f°" % [sc.id, inc, want_inc])
			valid = false
		if sc.id == "saturnv" and timed == 0:
			print("SHARED FLIGHT saturnv has no timed second separation plane")
			valid = false
		if not valid: failures += 1
		completed += 1
		print("SHARED FLIGHT %s %s frames=%s met=%s apo=%s peri=%s highest=%s lowest=%s inc=%.3f clock_error=%s wall_ms=%s" % [sc.id, "PASS" if valid else "FAIL", frames, ship.met, ship.telemetry.apo, ship.telemetry.peri, hi, lo, inc, worst_clock_error, (Time.get_ticks_usec() - start) / 1000.0])
	var errors := logger.take()
	for error in errors: printerr("SHARED FLIGHT ENGINE ", error)
	failures += errors.size()
	if wanted.is_empty() or completed != wanted.size(): failures += 1
	OS.remove_logger(logger)
	print("SHARED FLIGHT DONE failures=", failures)
	quit(1 if failures else 0)
