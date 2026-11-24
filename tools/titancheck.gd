extends Node

# TITAN CHECK: Titan in the Titan expedition, and what comes down on it (docs/physics/rotorcraft.md#titan).
# Dragonfly flies its entry, opens its chute at Huygens' Mach 1.5, leaves its backshell and lands itself on the
# drawn ground; it is then flown up, across and down. The Titan Mare Explorer comes down on Ligeia Mare and
# floats (docs/physics/ocean.md#the-titan-mare-explorer). The Survey Shuttle comes in from orbit and rolls to a
# stop. Drawn and undrawn descents land alike, and nothing of the surface outlives the flights.
#   Godot --headless --path . res://tools/titancheck.tscn

var main: Node
var failures := 0
var checks := 0

func check(what: String, ok: bool) -> void:
	checks += 1
	if ok: print("TITANCHECK ok   ", what)
	else:
		failures += 1
		printerr("TITANCHECK FAIL ", what)

func _ready() -> void:
	PlanetMaps.synchronous = true
	get_viewport().set_disable_input(true)
	main = Node.new()
	main.name = "Main"
	main.set_script(load("res://main.gd"))
	add_child(main)
	main.set_process(false)
	for i in 4: await get_tree().process_frame
	SurfaceStats.reset()
	await _dragonfly()
	await _parity()
	await _time()
	await _ranger()
	main.flight.teardown()
	var c := SurfaceStats.calls
	check("every ground, sea and site was let go (grounds %d/%d, seas %d/%d, sites %d/%d)" % [int(c.get("ground_init", 0)),
		int(c.get("ground_dispose", 0)), int(c.get("sea_init", 0)), int(c.get("sea_dispose", 0)), int(c.get("site_init", 0)), int(c.get("site_dispose", 0))],
		int(c.get("ground_init", 0)) > 0 and c.get("ground_init", 0) == c.get("ground_dispose", 0) and int(c.get("sea_init", 0)) > 0
		and c.get("sea_init", 0) == c.get("sea_dispose", 0) and c.get("site_init", 0) == c.get("site_dispose", 0))
	print("TITANCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

func _events(v: Vessel) -> Array:
	return v.events.map(func(e): return str(e.msg))

func _first(log_: Array, head: String) -> String:
	for m in log_:
		if str(m).begins_with(head): return m
	return ""

# From the top of Titan's air to the dunes, undrawn.
func _down(drawn: bool) -> Spaceflight:
	var err: String = await main.jump_scenario("dragonfly:entry")
	if err != "":
		check("dragonfly:entry: jump (%s)" % err, false)
		return null
	var f: Spaceflight = main.flight
	main.set_drawn(drawn)
	# Huygens took two and a half hours under its chutes; this flies it at 20×.
	f.dev_warp = 20.0
	var n := 0
	while not (f.heli != null and f.flying) and f.vessel.phase != Vessel.PHASE.DESTROYED and n < 60000:
		main.step_flight(0.05)
		n += 1
	f.dev_warp = 0.0
	main.set_drawn(true)
	return f

func _dragonfly() -> void:
	var f := await _down(false)
	if f == null: return
	var v := f.vessel
	var b: Body = v.parent
	check("Titan stands in the expedition: %s km, g %s m/s², %s bar at the surface" % [U.fixed(b.radius * Rocketry.AU_M / 1000.0, 1),
		U.fixed(float(v.env.gSurf), 3), U.fixed(Rocketry.pressure(v.env.atm, 0.0) / 1e5, 3)],
		b.name == "Titan" and absf(float(v.env.gSurf) - 1.352) < 0.01)
	var log_ := _events(v)
	var chute := _first(log_, "Parachute deploy")
	var mach := float(chute.get_slice("Mach ", 1).get_slice(",", 0)) if chute.contains("Mach ") else 0.0
	check("its chute opens at Huygens' Mach 1.5 (%s)" % chute, absf(mach - 1.5) < 0.05)
	check("it leaves the backshell and lands itself (%s; %s)" % [_first(log_, "Released"), _first(log_, "Dragonfly down")],
		f.heli != null and f.flying and f.heli.on_ground and not f.heli.crashed)
	if f.heli == null: return
	var h := f.heli
	f.rover_keys = false
	for i in 100: main.step_flight(0.05)
	# The crust here is far rougher than Titan's dunes, so a foot may hang over a dip: it must rest still and
	# upright, on feet that are on the drawn triangles.
	var gaps := []
	for leg: Vector3 in h.spec.legs:
		var p := DQuat.rotate(DVec3.from_v3(leg), h.q).add_in(h.pos)
		gaps.append(absf(p.y - h.ground.height(-p.x, p.z)))
	gaps.sort()
	var tilt := rad_to_deg(acos(clampf(DQuat.rotate(DVec3.new(0, 1, 0), h.q).y, -1.0, 1.0)))
	check("it rests on the drawn ground (a foot within %s m, the next %s m; tilted %s°)" % [U.fixed(gaps[0], 4), U.fixed(gaps[1], 2), U.fixed(tilt, 0)],
		gaps[0] < 0.02 and tilt < 35.0 and h.vel.length() < 0.05)
	# Up, across at full speed, and down again.
	f.rover_keys = false
	main.set_drawn(false)
	var run := func(s: float) -> void:
		for i in int(s / 0.05): main.step_flight(0.05)
	h.cmd_climb = 1.0
	run.call(25.0)
	h.cmd_climb = 0.0
	run.call(3.0)
	var up := h.height_above_ground()
	h.cmd_fwd = 1.0
	var low := INF
	for k in 40:
		run.call(1.0)
		low = minf(low, h.height_above_ground())
	var speed := Vector2(h.vel.x, h.vel.z).length()
	h.cmd_fwd = 0.0
	run.call(20.0)
	h.cmd_climb = -1.0
	run.call(60.0)
	h.cmd_climb = 0.0
	run.call(3.0)
	main.set_drawn(true)
	check("it flies: %s m up, %s m/s at the last over the hills, never under %s m, %s kW at the battery" % [U.fixed(up, 1), U.fixed(speed, 1),
		U.fixed(low, 1), U.fixed(h.power_w / 1000.0, 2)], up > 40.0 and speed > 3.0 and low > 3.0 and not h.crashed)
	check("and stands again (%s m/s)" % U.fixed(h.vel.length(), 3), h.on_ground and not h.crashed and h.vel.length() < 0.1)
	f.teardown()

func _parity() -> void:
	var out := []
	for drawn in [false, true]:
		var f := await _down(drawn)
		if f == null or f.heli == null:
			check("parity: down (%s)" % ("drawn" if drawn else "undrawn"), false)
			return
		out.append([f.vessel.coord, f.heli.pos.to_v3(), f.heli.t])
		f.teardown()
	var d: float = (out[0][1] as Vector3).distance_to(out[1][1])
	check("drawn and undrawn come down alike (%s s apart, %s m)" % [U.fixed(absf(out[0][0] - out[1][0]), 3), U.expo(d, 1)],
		absf(out[0][0] - out[1][0]) < 1e-6 and d < 1e-6)

# TiME from the top of Titan's air to Ligeia Mare at 20×, then a minute afloat at 1×: drawn when `drawn`.
func _time_down(drawn: bool) -> Spaceflight:
	var err: String = await main.jump_scenario("time:entry")
	if err != "":
		check("time:entry: jump (%s)" % err, false)
		return null
	var f: Spaceflight = main.flight
	main.set_drawn(drawn)
	f.dev_warp = 20.0
	var n := 0
	while not f.vessel.afloat() and f.vessel.phase != Vessel.PHASE.DESTROYED and n < 60000:
		main.step_flight(0.05)
		n += 1
	f.dev_warp = 0.0
	for i in 1200: main.step_flight(0.05)
	main.set_drawn(true)
	return f

func _time() -> void:
	var f := await _time_down(false)
	if f == null: return
	var v := f.vessel
	var log_ := _events(v)
	var chute := _first(log_, "Parachute deploy")
	var mach := float(chute.get_slice("Mach ", 1).get_slice(",", 0)) if chute.contains("Mach ") else 0.0
	check("TiME's main opens at Huygens' Mach 1.5 and its stabiliser at 110 km (%s; %s)" % [chute, _first(log_, "Main chutes")],
		absf(mach - 1.5) < 0.05 and _first(log_, "Main chutes") != "")
	var sea: SurfaceSea = v.sea
	check("it comes down on Ligeia Mare (%s)" % _first(log_, "Ligeia Mare at"), v.afloat() and sea != null and sea.pin != null
		and str(sea.pin.ground.get("mare", "")) == "Ligeia Mare")
	if not v.afloat(): return
	var splash := _first(log_, "Splashdown")
	var speed := float(splash.get_slice("— ", 1).get_slice(" m/s", 0)) if splash.contains("— ") else 0.0
	check("it splashes down at Huygens' 4.5 m/s (%s)" % splash, absf(speed - 4.5) < 0.6 and sea.floater.peak_accel / 9.81 < 5.0)
	var fl := sea.floater
	var want := TimeCapsule.MASS / float(sea.liquid.rho)
	check("it floats upright on methane, %s m³ of it displaced against m/ρ %s m³ (heel %s°)" % [U.fixed(fl.displaced, 3), U.fixed(want, 3),
		U.fixed(sea.heel(), 1)], sea.heel() < 20.0 and absf(fl.displaced / want - 1.0) < 0.15 and str(sea.liquid.name) == "liquid methane")
	var w := sea.weather.now()
	var lm := 0.2 * float(w.wind) * float(w.wind) / 1.352
	check("on Ligeia's waves: Hs %s m in %s m/s of wind, against Lorenz & Mann's 0.2U²/g %s m, %s m deep" % [U.fixed(sea.field.hs(), 2),
		U.fixed(float(w.wind), 1), U.fixed(lm, 2), U.fixed(sea.depth, 0)], sea.field.calm() or absf(sea.field.hs() / lm - 1.0) < 0.3)
	print("TITANCHECK note TiME: %s" % f.sea_readout())
	var at := [v.coord, Vector3(fl.p[0], fl.p[1], fl.p[2])]
	f.teardown()
	var g := await _time_down(true)
	if g == null or not g.vessel.afloat():
		check("TiME drawn: afloat", false)
		return
	var gf: Floater = g.vessel.sea.floater
	var d: float = (at[1] as Vector3).distance_to(Vector3(gf.p[0], gf.p[1], gf.p[2]))
	check("drawn and undrawn come down on the sea alike (%s s apart, %s m)" % [U.fixed(absf(float(at[0]) - g.vessel.coord), 3), U.expo(d, 1)],
		absf(float(at[0]) - g.vessel.coord) < 1e-6 and d < 1e-6)
	g.teardown()

func _ranger() -> void:
	var err: String = await main.jump_scenario("ranger:titan_orbit")
	if err != "":
		check("ranger:titan_orbit: jump (%s)" % err, false)
		return
	var f: Spaceflight = main.flight
	main.set_drawn(false)
	f.dev_warp = 20.0
	var n := 0
	while _first(_events(f.vessel), "Wheel stop") == "" and f.vessel.phase != Vessel.PHASE.DESTROYED and n < 40000:
		main.step_flight(0.05)
		n += 1
	f.dev_warp = 0.0
	main.set_drawn(true)
	var log_ := _events(f.vessel)
	check("the Survey Shuttle comes in from Titan orbit and stops (%s)" % _first(log_, "Wheel stop"),
		_first(log_, "Wheel stop") != "" and f.vessel.phase != Vessel.PHASE.DESTROYED)
	print("TITANCHECK note the Survey Shuttle: %s; %s" % [_first(log_, "Deorbit burn — ignition"), _first(log_, "Main gear touchdown")])
	f.teardown()
