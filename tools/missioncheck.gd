extends Node

# MISSION CHECK: flies whole missions through the real orchestrator with no input
# (sim/flight/mission.gd) and rejects any that does not end where it should.
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

func _fail(id: String, why: String) -> void:
	failures += 1
	printerr("MISSION CHECK FAIL %s: %s" % [id, why])
