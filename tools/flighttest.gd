extends Node

# ============================================================================
# FLIGHT TEST — drives the REAL orchestrator (main.gd) through a scripted
# spaceflight scenario and writes frames and telemetry, for side-by-side
# comparison with the web build (tools/flightshots.json through webref.mjs).
#
#   Godot --path . res://tools/flighttest.tscn -- scen=sv_launch out=/abs/dir/ \
#         seed=7 [only=name,name]
#
# The scenarios live in tools/flight_scenarios.json, which tools/flightshots.mjs
# also reads to write the web build's shot list — one table, two runners. Each
# is a list of steps:
#   ["launch", key]                   main.launch_craft(key) (await its mesh)
#   ["begin", key, opts]              flight.begin(key, opts) directly
#   ["booster"]                       register the lone Falcon 9 booster
#   ["init", {alt, vVert, vHoriz}]    set r, v, q as tools/flightref.mjs does
#   ["program", name]                 the flight panel's program button
#   ["cam", mode] / ["warp", i]
#   ["frames", n]                     n fixed steps of main.animate(dt)
#   ["shot", name, hud?]              write <out>/<name>.png (+ .json telemetry)
#
# main.gd reads its own command line, so pass the scenario's world there:
#   preset=solar seed=<table seed> mode=flight   (tools/flightshots.sh does)
# ============================================================================

## The scenario table is shared with the web side (tools/flightshots.mjs).
const SCENARIO_FILE := "res://tools/flight_scenarios.json"
var SCENARIOS := {}

var args := {}
var main: Node
var dt := 1.0 / 60.0
var out := "/tmp/"

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	out = str(args.get("out", "/tmp/"))
	if not out.ends_with("/"): out += "/"
	DirAccess.make_dir_recursive_absolute(out)
	# Only when asked: str(1.0/60.0) prints 13 digits, and parsing that back is
	# 3e-15 off the web's 1/60 — 1e-5 s after an hour of 10⁶× warp, enough to
	# land a readout on the other side of a whole minute.
	if args.has("dt"): dt = float(args.dt)
	PlanetMaps.synchronous = true
	main = Node.new()
	main.name = "Main"
	main.set_script(load("res://main.gd"))
	add_child(main)
	main.set_process(false)
	await _run()

func step(n: int) -> void:
	for i in n:
		main.animate(dt)
		if i % 600 == 599:
			await get_tree().process_frame

func _flight():
	return main.flight

func _run() -> void:
	# let the boot settle (the start screen dismissal, the first launch)
	for i in 4: await get_tree().process_frame
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(str(args.get("table", SCENARIO_FILE))))
	SCENARIOS = table.scenarios
	var only: Array = str(args.get("scen", "sv_launch")).split(",")
	for name in only:
		var steps: Array = SCENARIOS[name]
		for s in steps:
			await _do(s)
	get_tree().quit()

func _do(s: Array) -> void:
	var f = _flight()
	match s[0]:
		"launch":
			await main.launch_craft(s[1])
		"begin":
			await CraftAssets.craft_models_ready([s[1] if s[1] != "f9booster" else "falcon9"])
			f.begin(s[1], s[2])
			main.set_cam_mode("flight")
			main.sync_warp_label()
		"booster":
			# A lone booster is the Falcon 9's own first stage with only its
			# landing reserve in the tanks (tools/flightref.mjs's f9booster).
			var veh: Dictionary = Vehicles.VEHICLES.falcon9.duplicate()
			veh.id = "f9booster"
			var s0: Dictionary = veh.stages[0].duplicate()
			s0.prop = 411000.0 * 0.15
			veh.stages = [s0]
			Vehicles.VEHICLES["f9booster"] = veh
		"init":
			var i: Dictionary = s[1]
			var v: Vessel = f.vessel
			var env: Dictionary = v.env
			var Rr: float = env.radius + i.alt
			var r := DVec3.new(Rr, 0.0, 0.0)
			var up := DQuat.nrm(r.clone())
			var east := DQuat.nrm(DVec3.new().cross_vectors(DVec3.new(0.0, -1.0, 0.0), up))
			var surf := DVec3.new(0.0, -float(env.rotRate), 0.0).cross(r)
			var vel := up.scaled(i.vVert).add_scaled_in(east, i.vHoriz).add_in(surf)
			var air := DQuat.nrm(vel.sub(surf)).negate_in()
			v.r.copy_from(r); v.v.copy_from(vel)
			v.q.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), air)
		"program":
			f.run_program(s[1])
		"cam":
			f.set_camera_mode(s[1])
		"warp":
			f.set_warp(int(s[1]))
		"frames":
			await step(int(s[1]))
		"dump":
			_dump()
		"nomap":
			# Debug: fly on the procedural ground alone, without the Earth map.
			f.local._earth_color = null
		"exit":
			main.end_flight()
		"close":
			main.set_panel_open(s[1], false)
		"shot":
			await _shot(s[1], s.size() > 2 and s[2])

## Diagnostics: the vessel's state and every body's offset from its parent.
func _dump() -> void:
	var v: Vessel = _flight().vessel
	if v == null:
		print("dump: no vessel"); return
	print("dump: met=%.4f |r|=%.1f R=%.1f alt=%.2f |v|=%.3f phase=%s parent=%s" % [v.met, v.r.length(), v.env.radius, v.altitude(), v.v.length(), v.phase, v.parent.name])
	for b in v.bodies:
		var d: float = b.pos.distance_to(v.parent.pos) * Rocketry.AU_M
		print("   body ", b.name, " alive=", b.alive, " mass=", b.mass, " d=", d, " m radius=", b.radius, " AU")

func _shot(name: String, with_hud: bool) -> void:
	var v = _flight().vessel
	var t: Dictionary = v.telemetry if v != null else {}
	var tel := {"met": v.met if v else 0.0, "coord": v.coord if v else 0.0, "alt": t.get("alt"), "speed": t.get("speed"), "q": t.get("q"),
		"mach": t.get("mach"), "thr": v.throttle if v else 0.0, "mass": t.get("mass"), "apo": t.get("apo"),
		"peri": t.get("peri"), "phase": v.phase if v else "", "cam": _flight().camera_mode(),
		"status": _flight().autopilot.status if _flight().autopilot else ""}
	var fj := FileAccess.open(out + name + ".json", FileAccess.WRITE)
	fj.store_string(JSON.stringify(tel, " "))
	fj.close()
	if with_hud:
		# The toast's lifetime is wall-clock, which the two runners do not share.
		main.hud.toast_el.visible = false
		# The HUD's own fades (the start screen, a panel opening) run on the
		# wall clock, and a few hundred fixed steps take almost none of it.
		await get_tree().create_timer(1.0).timeout
		# the same frame twice: the whole window (3D + HUD), then the 3D alone
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out + name + ".hud.png")
	var done := [false]
	var grab := func(img: Image):
		if done[0]: return
		img.save_png(out + name + ".png")
		done[0] = true
	main.pipe.capture_next(grab)
	# A capture request has been seen to go unanswered once in a few hundred
	# (the compositor hook skipped a frame); ask again rather than hang.
	var waited := 0
	while not done[0]:
		await get_tree().process_frame
		waited += 1
		if waited % 60 == 0:
			main.pipe.capture_next(grab)
	print("flighttest: ", name, " ", tel)
