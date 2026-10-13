extends Node

# MISSION CHECK: flies whole missions through the real orchestrator with no input
# (sim/flight/mission.gd) and rejects any that does not end where it should. Also a
# lone Starship from orbit through its own return (`bellyflop`): deorbit, belly-first
# entry, flip and landing burn, which must touch down inside 1 m/s. And the Shuttle
# from Pad 39A to orbit and back to Kennedy (`glide` with a launch site).
#   Godot --path . res://tools/missioncheck.tscn -- [only=name,name] [long=1]
# `long=1` adds Earth orbit → Mars orbit (about ten minutes).

var args := {}
var main: Node
var failures := 0
var dt := 1.0 / 60.0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	PlanetMaps.synchronous = true
	main = Node.new()
	main.name = "Main"
	main.set_script(load("res://main.gd"))
	add_child(main)
	main.set_process(false)
	for i in 4: await get_tree().process_frame
	# Off the title screen, or its reel takes the stage (and the flight) back.
	main._start("sandbox")
	var cases := [
		["launch_orbit", "saturnv", {"mode": "pad"}, "Earth", "orbit", false],
		["lunar_orbit", "saturnv", {"mode": "orbit", "alt": 185000.0, "inc": 28.5}, "Moon", "orbit", false],
		["lunar_landing", "lm", {"mode": "orbit"}, "Moon", "land", false],
		["skip_moon", "saturnv", {"mode": "pad"}, "Moon", "orbit", true],
	]
	if args.get("long", "0") == "1":
		cases.append(["mars_orbit", "saturnv", {"mode": "orbit", "alt": 200000.0, "inc": 0.0}, "Mars", "orbit", false])
	var only: Array = str(args.get("only", "")).split(",", false)
	for c in cases:
		if not only.is_empty() and not only.has(c[0]): continue
		await _fly(c[0], c[1], c[2], c[3], c[4], c[5])
	if only.is_empty() or only.has("ship_return"): await _ship_return()
	if only.is_empty() or only.has("orbiter_return"): await _orbiter_return()
	if only.is_empty() or only.has("orbiter_home"): await _orbiter_home()
	print("MISSION CHECK DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _fly(id: String, craft: String, opts: Dictionary, dest: String, goal: String, skip: bool) -> void:
	main.load_preset("solar")
	await CraftAssets.craft_models_ready([craft])
	var f = main.flight
	f.begin(craft, opts)
	main.set_cam_mode("flight")
	for i in 30: main.animate(dt)
	var m = f.start_mission(dest, goal)
	if m == null or m.failed != "":
		_fail(id, "did not start: %s" % (m.failed if m else "no mission"))
		main.end_flight()
		return
	if skip: m.skip()
	# A generous cap in frames: the slowest case (Mars) waits a year for its window
	# and still finishes well inside it.
	var frames := 0
	while not m.done and m.failed == "" and frames < 600000:
		main.animate(dt)
		frames += 1
		if frames % 600 == 0: await get_tree().process_frame
	var v: Vessel = f.vessel
	var why := ""
	if m.failed != "": why = m.failed
	elif not m.done: why = "unfinished after %d frames (%s)" % [frames, m.status]
	elif goal == "land":
		if v.phase != Vessel.PHASE.LANDED or v.parent.name != dest: why = "not landed on %s (%s)" % [dest, v.phase]
	else:
		var el := Orbit.elements(v.r, v.v, Rocketry.GM_SUN * v.parent.mass)
		var alt := (float(el.rp) - float(v.env.radius)) / 1000.0
		if v.parent.name != dest: why = "around %s, not %s" % [v.parent.name, dest]
		elif float(el.e) > 0.05 or alt < 50.0: why = "orbit %s km periapsis, e %s" % [U.fixed(alt, 0), U.fixed(el.e, 3)]
	if why != "": _fail(id, why)
	else: print("MISSION %s ok — %s, %s, Δv left %s, %d frames" % [id, m.title(), v.parent.name, FlightUI.fmt_speed(v.delta_v_remaining(0.0)), frames])
	main.end_flight()

## Starship's ship alone in a 200 km orbit with 40 t of landing propellant (what a
## real one comes home with), through the return program.
func _ship_return() -> void:
	main.load_preset("solar")
	await CraftAssets.craft_models_ready(["starship"])
	var f = main.flight
	f.begin("starship", {"mode": "orbit", "alt": 200000.0, "inc": 28.5})
	main.set_cam_mode("flight")
	for i in 5: main.animate(dt)
	var v: Vessel = f.vessel
	v.stage(true)
	v.stages[1].prop = 40000.0
	f.run_program("bellyflop")
	var frames := 0
	while frames < 400000 and v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED:
		# Warp through the coast to the air; physics rate inside it.
		f.set_warp(3 if v.altitude() > 90000.0 else 0)
		main.animate(dt)
		frames += 1
		if frames % 600 == 0: await get_tree().process_frame
	if v.phase != Vessel.PHASE.LANDED:
		_fail("ship_return", "%s (%s)" % [v.phase, v.failure])
	else:
		print("MISSION ship_return ok — touchdown %s m/s vertical, %s m/s lateral, %d frames" % [
			U.fixed(absf(float(v.landed_at.vVert)), 2), U.fixed(float(v.landed_at.vHoriz), 2), frames])
	main.end_flight()

## A lone orbiter from a 300 km orbit: deorbit, the 40° entry with its roll
## reversals, the glide slopes and a touchdown on the main gear inside its rating.
func _orbiter_return() -> void:
	main.load_preset("solar")
	await CraftAssets.craft_models_ready(["shuttle"])
	var f = main.flight
	f.begin("shuttle", {"mode": "orbit", "alt": 300000.0, "inc": 51.6})
	main.set_cam_mode("flight")
	for i in 5: main.animate(dt)
	var v: Vessel = f.vessel
	v.stage(true)
	v.stage(true)
	f.run_program("glide")
	var rp := v.r.clone()
	var arc := 0.0
	var arc_taem := -1.0
	var t0 := v.met
	var frames := 0
	var reversals := 0
	var seen := 0
	while frames < 600000 and v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED:
		f.set_warp(3 if v.altitude() > 120000.0 else 0)
		main.animate(dt)
		frames += 1
		arc += DQuat.angle_between(rp, v.r); rp.copy_from(v.r)
		if arc_taem < 0.0 and f.autopilot.state_name == "taem": arc_taem = arc
		while seen < v.events.size():
			var msg := str(v.events[seen].msg)
			seen += 1
			if args.has("verbose"): print("ORBITER T+%s %s" % [U.fixed(float(v.events[seen - 1].t), 0), msg])
			if msg.begins_with("Roll reversal"): reversals += 1
		if args.has("verbose") and frames % 600 == 0 and v.altitude() < 130000.0:
			var t: Dictionary = v.telemetry
			print("ORBITER   %s km  %s m/s  M %s  q %s kPa  drag %s  vs %s  %s" % [U.fixed(v.altitude() / 1000.0, 1),
				U.fixed(float(t.speed), 0), U.fixed(float(t.mach), 1), U.fixed(float(t.q) / 1000.0, 2),
				U.fixed(float(t.drag) / v.mass, 1), U.fixed(float(t.vertical), 0), f.autopilot.status])
		if frames % 600 == 0: await get_tree().process_frame
	if args.has("verbose"):
		print("ORBITER deorbit→touchdown %s s, %s° round the planet, TAEM→touchdown %s°" % [U.fixed(v.met - t0, 0),
			U.fixed(rad_to_deg(arc), 1), U.fixed(rad_to_deg(arc - arc_taem), 2)])
	if v.phase != Vessel.PHASE.LANDED:
		_fail("orbiter_return", "%s (%s)" % [v.phase, v.failure])
	elif reversals < 2 or not v.stages[2].gear_out:
		_fail("orbiter_return", "%d roll reversals, gear %s" % [reversals, "down" if v.stages[2].gear_out else "up"])
	elif not _touchdown_speed_ok(v):
		_fail("orbiter_return", "touched down at %s kt" % U.fixed(float(v.landed_at.vHoriz) / 0.514444, 0))
	else:
		print("MISSION orbiter_return ok — touchdown %s m/s sink, %s m/s ground speed, %d reversals, %d frames" % [
			U.fixed(absf(float(v.landed_at.vVert)), 2), U.fixed(float(v.landed_at.vHoriz), 1), reversals, frames])
	main.end_flight()

## The Shuttle from Pad 39A to orbit, then `glide`: it waits for the deorbit
## opportunity that brings Kennedy within reach and lands within 10 km of the pad.
func _orbiter_home() -> void:
	main.load_preset("solar")
	await CraftAssets.craft_models_ready(["shuttle"])
	var f = main.flight
	f.begin("shuttle", {"mode": "pad"})
	main.set_cam_mode("flight")
	for i in 5: main.animate(dt)
	var v: Vessel = f.vessel
	f.run_program("ascent")
	var frames := 0
	var gliding := false
	var seen := 0
	while frames < 600000 and v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED:
		var ap = f.autopilot
		if not gliding and ap.program == null and f.count == null and v.phase == Vessel.PHASE.ORBIT:
			gliding = true
			f.run_program("glide")
		# 100× while waiting for the opportunity, 10× on unpowered coasts above the air.
		var w := 0
		if gliding and ap.state_name == "deorbit" and ap.node == null: w = 5
		elif v.altitude() > 125000.0 and v.throttle == 0.0 and not ap.burning: w = 3
		if f.warp_index() != w: f.set_warp(w)
		main.animate(dt)
		frames += 1
		while seen < v.events.size():
			if args.has("verbose"): print("HOME T+%s %s" % [U.fixed(float(v.events[seen].t), 0), str(v.events[seen].msg)])
			seen += 1
		if frames % 600 == 0: await get_tree().process_frame
	var pad = v.site_at(v.coord, DVec3.new())
	var miss := float(v.env.radius) * DQuat.angle_between(v.r, pad) / 1000.0 if pad != null else INF
	if v.phase != Vessel.PHASE.LANDED:
		_fail("orbiter_home", "%s (%s), %s km from the pad" % [v.phase, v.failure, U.fixed(miss, 1)])
	elif miss > 10.0:
		_fail("orbiter_home", "landed %s km from the pad" % U.fixed(miss, 1))
	elif not _touchdown_speed_ok(v):
		_fail("orbiter_home", "touched down at %s kt" % U.fixed(float(v.landed_at.vHoriz) / 0.514444, 0))
	else:
		print("MISSION orbiter_home ok — touchdown %s km from the pad, %s m/s sink, %s m/s ground speed, %d frames" % [
			U.fixed(miss, 2), U.fixed(absf(float(v.landed_at.vVert)), 2), U.fixed(float(v.landed_at.vHoriz), 1), frames])
	main.end_flight()

## Inside the flown touchdown range, 195–215 kt, in still air at sea level.
func _touchdown_speed_ok(v: Vessel) -> bool:
	var kt := float(v.landed_at.vHoriz) / 0.514444
	return kt >= 195.0 and kt <= 215.0

func _fail(id: String, why: String) -> void:
	failures += 1
	printerr("MISSION CHECK FAIL %s: %s" % [id, why])
