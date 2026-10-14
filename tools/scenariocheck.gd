extends Node

# SCENARIO CHECK: every registered flight scenario (sim/flight/scenarios.gd) jumped to
# through main.jump_scenario, checked against its declared conditions at the hand-over
# and again after a second of drawn flight. `replay=1` also flies each fast-forwarded
# scenario as played, at 60 fps from its base, to the same condition, and compares
# (docs/flight-scenarios.md has the tolerances).
#   Godot --headless --path . res://tools/scenariocheck.tscn -- [only=shuttle:taem,lm] [replay=1]
# `only` takes vehicle:id or a whole vehicle. `inject_bad=1` must fail.

var args := {}
var main: Node
var failures := 0
var checked := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	PlanetMaps.synchronous = true
	get_viewport().set_disable_input(true)
	main = Node.new()
	main.name = "Main"
	main.set_script(load("res://main.gd"))
	add_child(main)
	main.set_process(false)
	for i in 4: await get_tree().process_frame
	var only: Array = str(args.get("only", "")).split(",", false)
	for key in FlightScenarios.vehicles():
		for sc: Dictionary in FlightScenarios.list(key):
			var spec := "%s:%s" % [key, sc.id]
			if not only.is_empty() and not only.has(spec) and not only.has(key): continue
			await _check(spec, sc)
	if args.get("inject_bad", "0") == "1":
		# A misspelt name and an impossible condition must both be rejected.
		var err: String = await main.jump_scenario("shuttle:no_such_moment")
		_expect_fail("unknown scenario", err)
		var bad: Dictionary = FlightScenarios.find("lm", "approach").duplicate(true)
		bad.expect = {"alt": [0.0, 1.0]}
		await _check("lm:approach (injected)", bad, false)
	print("SCENARIOCHECK DONE scenarios=%d failures=%d" % [checked, failures])
	Presets.rand_override = Callable()
	get_tree().quit(1 if failures > 0 else 0)

func _check(spec: String, sc: Dictionary, by_name := true) -> void:
	checked += 1
	var t0 := Time.get_ticks_msec()
	var err: String = await main.jump_scenario(spec if by_name else "%s:%s" % [sc.vehicle, sc.id])
	var ms := Time.get_ticks_msec() - t0
	if err != "":
		_fail(spec, "jump failed: %s" % err)
		return
	var f: Spaceflight = main.flight
	var why := _expect(f, sc.expect)
	var at := _summary(f)
	var handed := _state(f)
	# A second of drawn flight from the hand-over: still flying, still finite.
	for i in 60: main.animate(1.0 / 60.0)
	var v := f.vessel
	if why == "" and (v == null or v.phase == Vessel.PHASE.DESTROYED or not is_finite(v.r.length()) or not is_finite(v.v.length())):
		why = "lost within a second of the hand-over (%s)" % (v.failure if v != null else "no vessel")
	if why != "":
		_fail(spec, "%s — at hand-over %s" % [why, at])
	else:
		print("SCENARIO CHECK %s ok — %s, %d ms" % [spec, at, ms])
	var rp := FlightScenarios.replay_of(sc)
	if args.get("replay", "0") == "1" and by_name and not (rp.until as Dictionary).is_empty():
		await _replay(spec, sc, rp, handed)

## The declared conditions, "" when they hold.
func _expect(f: Spaceflight, e: Dictionary) -> String:
	var v := f.vessel
	var t: Dictionary = v.telemetry
	var air := v.airspeed(v.r, v.v, DVec3.new()).length()
	var vals := {"alt": v.altitude(), "speed": v.v.length(), "airspeed": air, "q": float(t.get("q", 0.0)),
		"count": float(f.count.t) if f.count != null else -1.0}
	for k in e:
		var want = e[k]
		match k:
			"alt", "speed", "airspeed", "q", "count":
				if float(vals[k]) < float(want[0]) or float(vals[k]) > float(want[1]):
					return "%s %s outside [%s, %s]" % [k, U.fixed(float(vals[k]), 1), want[0], want[1]]
			"phase":
				if v.phase != str(want): return "phase %s, want %s" % [v.phase, want]
			"program":
				if str(f.autopilot.program) != str(want): return "program %s, want %s" % [f.autopilot.program, want]
			"state":
				if str(f.autopilot.state_name) != str(want): return "state %s, want %s" % [f.autopilot.state_name, want]
			"attached", "gone":
				for key in want:
					var st = FlightScenarios._stage(v, str(key))
					if st == null or st.attached != (k == "attached"): return "%s is not %s" % [key, k]
	return ""

func _summary(f: Spaceflight) -> String:
	var v := f.vessel
	return "%s km, %s m/s air, %s/%s, %s, T+%s s" % [U.fixed(v.altitude() / 1000.0, 2),
		U.fixed(v.airspeed(v.r, v.v, DVec3.new()).length(), 0), f.autopilot.program, f.autopilot.state_name,
		v.phase, U.fixed(v.met - v.t0, 1)]

## The same flight played: from the base it stands in for, frames of 1/60 s at the
## warp FlightScenarios.played_warp picks, no coast on rails, to the same condition.
## Compared with what the jump handed over; TOLERANCE is the documented agreement.
func _replay(spec: String, sc: Dictionary, rp: Dictionary, j: Dictionary) -> void:
	var f: Spaceflight = main.flight
	main.end_flight()
	main.scenario_world()
	FlightScenarios.build(main, {"vehicle": sc.vehicle, "base": rp.base})
	main.set_cam_mode("flight")
	var from: int = f.vessel.events.size()
	var hit := -1.0
	var frames := 0
	var dt := 1.0 / 60.0
	var t0 := Time.get_ticks_msec()
	while frames < 3000000:
		var v := f.vessel
		if v == null or not f.active or v.phase == Vessel.PHASE.DESTROYED: break
		if hit < 0.0 and FlightScenarios.reached(f, rp.until, from): hit = v.met
		if hit >= 0.0 and v.met - hit >= float(sc.after): break
		var want := FlightScenarios.played_warp(f)
		if f.warp_index() != want: f.set_warp(want)
		main.state.time += dt
		var cs: float = main.step_flight(dt)
		f.fast_forward = 2
		f.update_visual(dt, cs)
		frames += 1
		if frames % 20000 == 0: await get_tree().process_frame
	f.fast_forward = 0
	if f.vessel == null or hit < 0.0:
		_fail(spec, "replay never reached %s" % rp.until)
		return
	var r := _state(f)
	var lines := []
	var bad := []
	for k in ["alt", "speed", "fpa", "mass", "t"]:
		if k == "t" and sc.base.has("replay"): continue
		var d := float(j[k]) - float(r[k])
		lines.append("%s %s / %s" % [k, U.fixed(float(j[k]), 1), U.fixed(float(r[k]), 1)])
		var tol: Array = sc.get("tol", {}).get(k, TOLERANCE[k])
		if absf(d) > float(tol[0]) + float(tol[1]) * absf(float(r[k])): bad.append("%s off by %s" % [k, U.fixed(d, 2)])
	print("SCENARIO REPLAY %s jump / played: %s (%d frames, %d ms)" % [spec, ", ".join(lines), frames, Time.get_ticks_msec() - t0])
	if not bad.is_empty(): _fail(spec, "differs from the played flight: %s" % ", ".join(bad))

## Agreement with the played flight at the same condition: [absolute, relative].
## docs/flight-scenarios.md explains each.
const TOLERANCE := {"alt": [500.0, 0.03], "speed": [20.0, 0.03], "fpa": [1.0, 0.0], "mass": [100.0, 0.003], "t": [1.0, 0.01]}

func _state(f: Spaceflight) -> Dictionary:
	var v := f.vessel
	var air := v.airspeed(v.r, v.v, DVec3.new())
	var up := DQuat.nrm(v.r.clone())
	return {"t": v.met - v.t0, "alt": v.altitude(), "speed": air.length(),
		"fpa": rad_to_deg(asin(clampf(air.dot(up) / maxf(air.length(), 1e-9), -1.0, 1.0))), "mass": v.mass}

func _expect_fail(what: String, err: String) -> void:
	checked += 1
	if err == "": _fail(what, "was accepted")
	else: print("SCENARIO CHECK %s rejected as it should be: %s" % [what, err])

func _fail(spec: String, why: String) -> void:
	failures += 1
	printerr("SCENARIO CHECK FAIL %s: %s" % [spec, why])
