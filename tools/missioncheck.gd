extends Node

# MISSION CHECK: flies whole missions through the real orchestrator with no input
# (sim/flight/mission.gd) and rejects any that does not end where it should. Also a
# lone Starship from orbit through its own return (`bellyflop`): deorbit, belly-first
# entry, flip and landing burn, which must touch down inside 1 m/s. And the Shuttle
# from Pad 39A to orbit and back to Kennedy (`glide` with a launch site), both orbiter
# cases through the rollout to wheel stop. And what becomes of the Shuttle's dropped
# stages (`shuttle_fates`, Fall).
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
	# A windowed check still gets the desktop's keys while it has focus, and Space
	# pauses: a paused flight never fails, it waits out the frame cap.
	get_viewport().set_disable_input(true)
	# The solar preset draws each planet's phase; fixed, so a failure repeats.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	Presets.rand_override = func(): return rng.randf()
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
		["lunar_orbit", "saturnv", {"mode": "orbit", "alt": 185000.0, "inc": 28.5, "phase": 0.0}, "Moon", "orbit", false],
		["lunar_landing", "lm", {"mode": "orbit", "phase": 0.0}, "Moon", "land", false],
		["skip_moon", "saturnv", {"mode": "pad"}, "Moon", "orbit", true],
	]
	if args.get("long", "0") == "1":
		cases.append(["mars_orbit", "saturnv", {"mode": "orbit", "alt": 200000.0, "inc": 0.0, "phase": 0.0}, "Mars", "orbit", false])
	# check.py runs one case per process and compares this list with its own.
	print("MISSION CHECK CASES %s" % ",".join(cases.map(func(c): return c[0]) + ["ship_return", "orbiter_return", "orbiter_return_2x", "orbiter_home", "shuttle_fates"]))
	var only: Array = str(args.get("only", "")).split(",", false)
	for c in cases:
		if not only.is_empty() and not only.has(c[0]): continue
		await _fly(c[0], c[1], c[2], c[3], c[4], c[5])
	if only.is_empty() or only.has("ship_return"): await _ship_return()
	if only.is_empty() or only.has("orbiter_return"): await _orbiter_return()
	if only.is_empty() or only.has("orbiter_return_2x"): await _orbiter_return("orbiter_return_2x", 1)
	if only.is_empty() or only.has("orbiter_home"): await _orbiter_home()
	if only.is_empty() or only.has("shuttle_fates"): await _shuttle_fates()
	print("MISSION CHECK DONE failures=%d" % failures)
	# A lambda left in a static var aborts the engine at exit.
	Presets.rand_override = Callable()
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
	f.begin("starship", {"mode": "orbit", "alt": 200000.0, "inc": 28.5, "phase": 0.0})
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
		_fail("ship_return", _stuck(f, v))
	else:
		print("MISSION ship_return ok — touchdown %s m/s vertical, %s m/s lateral, %d frames" % [
			U.fixed(absf(float(v.landed_at.vVert)), 2), U.fixed(float(v.landed_at.vHoriz), 2), frames])
	main.end_flight()

## A lone orbiter from a 300 km orbit: deorbit, the 40° entry with its roll
## reversals, the glide slopes, a touchdown on the main gear inside its rating and the
## rollout to wheel stop. `air_warp` is the warp rung flown below 120 km: 1 (2×, the
## most the panel allows in the air) must land as well as 1×.
func _orbiter_return(id := "orbiter_return", air_warp := 0) -> void:
	main.load_preset("solar")
	await CraftAssets.craft_models_ready(["shuttle"])
	var f = main.flight
	f.begin("shuttle", {"mode": "orbit", "alt": 300000.0, "inc": 51.6, "phase": 0.0})
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
		f.set_warp(3 if v.altitude() > 120000.0 else air_warp)
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
		_fail(id, _stuck(f, v))
	elif reversals < 2 or not v.stages[2].gear_out:
		_fail(id, "%d roll reversals, gear %s" % [reversals, "down" if v.stages[2].gear_out else "up"])
	elif not _touchdown_speed_ok(v):
		_fail(id, "touched down at %s kt" % U.fixed(float(v.landed_at.vHoriz) / 0.514444, 0))
	elif _rollout_error(v) != "":
		_fail(id, _rollout_error(v))
	else:
		print("MISSION %s ok — touchdown %s m/s sink, %s m/s ground speed, %d reversals, %s, %d frames" % [id,
			U.fixed(absf(float(v.landed_at.vVert)), 2), U.fixed(float(v.landed_at.vHoriz), 1), reversals, _rollout_summary(v), frames])
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
		_fail("orbiter_home", "%s, %s km from the pad" % [_stuck(f, v), U.fixed(miss, 1)])
	elif miss > 10.0:
		_fail("orbiter_home", "landed %s km from the pad" % U.fixed(miss, 1))
	elif not _touchdown_speed_ok(v):
		_fail("orbiter_home", "touched down at %s kt" % U.fixed(float(v.landed_at.vHoriz) / 0.514444, 0))
	elif _rollout_error(v) != "":
		_fail("orbiter_home", _rollout_error(v))
	else:
		print("MISSION orbiter_home ok — touchdown %s km from the pad, %s m/s sink, %s m/s ground speed, %s, %d frames" % [
			U.fixed(miss, 2), U.fixed(absf(float(v.landed_at.vVert)), 2), U.fixed(float(v.landed_at.vHoriz), 1), _rollout_summary(v), frames])
	main.end_flight()

## The Shuttle from the pad until its dropped stages are down. Each booster must stay
## drawn to splashdown, run its recovery at the flown altitudes and speeds and hang
## under three open mains; the tank must leave MECO on a low perigee and break up in
## the air. Flown values and tolerances: docs/physics/srb-separation.md#check and
## stage-separation.md (the tank).
func _shuttle_fates() -> void:
	const FT := 0.3048
	const MPH := 0.44704
	main.load_preset("solar")
	await CraftAssets.craft_models_ready(["shuttle"])
	var f = main.flight
	f.begin("shuttle", {"mode": "pad"})
	main.set_cam_mode("flight")
	for i in 5: main.animate(dt)
	var v: Vessel = f.vessel
	var mu := Rocketry.GM_SUN * v.parent.mass
	var R := float(v.env.radius)
	f.run_program("ascent")
	var seen := {}            # every main piece: {vacuum apogee at hand-off, perigee, mains seen open}
	var parts := []           # what the boosters shed
	var why := []
	var frames := 0
	while frames < 600000:
		var ap = f.autopilot
		var low := false
		for fl: Fall in f.falls:
			if fl.follow and fl.state == "fall" and fl.altitude(v) < 130000.0: low = true
		# Physics rate while anything is coming down; 10× on coasts above the air, 100× in orbit.
		var w := 0
		if not low and v.altitude() > 125000.0 and v.throttle == 0.0 and not ap.burning:
			w = 5 if v.phase == Vessel.PHASE.ORBIT and ap.program == null else 3
		if f.warp_index() != w: f.set_warp(w)
		main.animate(dt)
		frames += 1
		for fl: Fall in f.falls:
			if fl.follow and not seen.has(fl):
				var el := Orbit.elements(fl.r, fl.v, mu)
				seen[fl] = {"apo": float(el.ra) - R, "peri": float(el.rp) - R, "mains": 0, "open": 0.0}
			elif not fl.follow and not parts.has(fl):
				parts.append(fl)
		for fl: Fall in seen:
			var rec: Dictionary = seen[fl]
			# Drawn until it is down: placed in the local scene and visible, its body with it.
			if fl.ended < 0.0 and fl.state != "gone" and not rec.has("vanished"):
				if not (f.falls.has(fl) and fl.holder.is_inside_tree() and fl.holder.visible and fl.body.get_parent() == fl.holder):
					why.append("%s vanished at %s km before it was down" % [fl.name, U.fixed(fl.altitude(v) / 1000.0, 1)])
					rec.vanished = true
			# Afloat, it stays drawn for Fall.LINGER s.
			if fl.ended >= 0.0 and not rec.has("kept") and not f.falls.has(fl):
				rec.kept = fl.t - fl.ended
			for ch: Dictionary in fl.chutes:
				if ch.key != "mains": continue
				rec.mains = maxi(rec.mains, (ch.nodes as Array).filter(func(n): return is_instance_valid(n) and n.is_inside_tree()).size())
				rec.open = maxf(rec.open, fl.open_fraction(ch))
		var all_down := not seen.is_empty() and seen.keys().all(func(fl): return fl.ended >= 0.0 or fl.state == "gone" or seen[fl].has("vanished"))
		if seen.size() >= 3 and all_down: break
		if frames % 600 == 0: await get_tree().process_frame
	var boosters := seen.keys().filter(func(fl): return fl.data.has("mains"))
	var tank := seen.keys().filter(func(fl): return fl.data.has("breakup"))
	if boosters.size() != 2: why.append("%d boosters flown on their own, not 2" % boosters.size())
	if tank.size() != 1: why.append("the tank was not flown on its own")
	var near := func(x: float, want: float, tol: float) -> bool: return absf(x - want) <= tol * absf(want)
	for b: Fall in boosters:
		var rec: Dictionary = seen[b]
		var order := ["apogee", "noseCap", "drogue", "frustum", "mains", "splashdown"]
		var got := b.events.map(func(e): return e.name)
		if got != order:
			why.append("%s ran %s, not %s" % [b.name, got, order])
			continue
		var e := {}
		for x: Dictionary in b.events: e[x.name] = x
		var ap: Dictionary = e.apogee
		var cap: Dictionary = e.noseCap
		var dro: Dictionary = e.drogue
		var fru: Dictionary = e.frustum
		var spl: Dictionary = e.splashdown
		var checks := [
			# The fall is answerable for coasting to the vacuum apogee, the ascent for
			# where that is.
			["apogee vs its vacuum apogee", ap.alt, rec.apo, 0.10],
			["apogee at 238,000 ft", ap.alt, 238000.0 * FT, 0.08],
			["apogee at T+196 s", float(ap.met) - v.t0, 196.0, 0.08],
			["splashdown at T+414 s", float(spl.met) - v.t0, 414.0, 0.08],
			["nose cap at 16,000 ft", cap.alt, 16000.0 * FT, 0.02],
			["nose cap at 360 mph", cap.speed, 360.0 * MPH, 0.15],
			["drogue at 15,530 ft", dro.alt, 15530.0 * FT, 0.03],
			["frustum at 6,450 ft", fru.alt, 6450.0 * FT, 0.02],
			["frustum at 250 mph", fru.speed, 250.0 * MPH, 0.15],
			["splashdown at 50 mph", spl.speed, 50.0 * MPH, 0.12],
			["nose cap to frustum in 22 s", float(fru.t) - float(cap.t), 22.0, 0.25],
			["frustum to splashdown in 43 s", float(spl.t) - float(fru.t), 43.0, 0.20],
		]
		for c: Array in checks:
			if not near.call(float(c[1]), float(c[2]), float(c[3])):
				why.append("%s: %s is %s, want %s ±%d%%" % [b.name, c[0], U.fixed(float(c[1]), 1), U.fixed(float(c[2]), 1), int(float(c[3]) * 100.0)])
		if int(rec.mains) != 3 or float(rec.open) < 0.999:
			why.append("%s: %d main chutes drawn, %s open" % [b.name, rec.mains, U.fixed(float(rec.open), 2)])
		if b.state != "rest" or float(rec.get("kept", INF)) < Fall.LINGER - 0.5:
			why.append("%s afloat for %s s, state %s" % [b.name, U.fixed(float(rec.get("kept", INF)), 0), b.state])
		print("MISSION shuttle_fates %s: apogee %s km at T+%s (vacuum %s), nose cap %s m/s, frustum %s m/s, splashdown %s m/s at T+%s" % [
			b.name, U.fixed(float(ap.alt) / 1000.0, 1), U.fixed(float(ap.met) - v.t0, 0), U.fixed(float(rec.apo) / 1000.0, 1),
			U.fixed(float(cap.speed), 0), U.fixed(float(fru.speed), 0), U.fixed(float(spl.speed), 1), U.fixed(float(spl.met) - v.t0, 0)])
	# The pieces a booster sheds: the frustum comes down on the drogue (KSC: 40 mph), the cap sinks.
	var frusta := parts.filter(func(fl): return fl.name.ends_with("frustum"))
	if frusta.size() != 2: why.append("%d frustums afloat, not 2" % frusta.size())
	for fr: Fall in frusta:
		var s = fr.event("splashdown")
		if s == null or not near.call(float(s.speed), 40.0 * MPH, 0.15):
			why.append("%s splashdown %s" % [fr.name, "missing" if s == null else U.fixed(float(s.speed), 1) + " m/s, want 17.9 ±15%"])
	var caps := parts.filter(func(fl): return fl.name.ends_with("nosecap"))
	if caps.size() != 2 or caps.any(func(fl): return fl.state != "gone" or fl.event("splashdown") == null):
		why.append("%d nose caps came off, and each must sink at the sea" % caps.size())
	for t: Fall in tank:
		var rec: Dictionary = seen[t]
		var brk = t.event("breakup")
		if not near.call(float(rec.peri), 48.0 * 1852.0, 0.12):
			why.append("tank left MECO on a %s km perigee, want 89 ±12%%" % U.fixed(float(rec.peri) / 1000.0, 0))
		if brk == null:
			why.append("the tank never broke up (%s)" % t.state)
		else:
			var geo = f.geo_of(t.r)
			print("MISSION shuttle_fates tank: %s × %s km at hand-off (vacuum), apogee %s km, breakup %s km at T+%s min, %s" % [
				U.fixed(float(rec.apo) / 1000.0, 0), U.fixed(float(rec.peri) / 1000.0, 0),
				U.fixed(float(t.event("apogee").alt) / 1000.0, 0) if t.event("apogee") != null else "?",
				U.fixed(float(brk.alt) / 1000.0, 1), U.fixed((float(brk.met) - v.t0) / 60.0, 0), geo])
			if not near.call(float(brk.alt), 247935.0 * FT, 0.01): why.append("tank breakup at %s m" % U.fixed(float(brk.alt), 0))
			if geo == null or _over_land(geo): why.append("tank broke up over land at %s" % geo)
	if not why.is_empty():
		_fail("shuttle_fates", "; ".join(why))
	else:
		print("MISSION shuttle_fates ok — boosters recovered, tank broken up, %d frames" % frames)
	main.end_flight()

## Whether the Earth map's land mask has land at (lat, lon), degrees.
func _over_land(geo: Vector2) -> bool:
	var img: Image = (load("res://assets/planet-maps/earth-land.png") as Texture2D).get_image()
	if img.is_compressed(): img.decompress()
	var x := clampi(int((geo.y / 360.0 + 0.5) * img.get_width()), 0, img.get_width() - 1)
	var y := clampi(int((0.5 - geo.x / 180.0) * img.get_height()), 0, img.get_height() - 1)
	return img.get_pixel(x, y).r > 0.5

## Inside the flown touchdown range, 195–215 kt, in still air at sea level.
func _touchdown_speed_ok(v: Vessel) -> bool:
	var kt := float(v.landed_at.vHoriz) / 0.514444
	return kt >= 195.0 and kt <= 215.0

## The rollout against the flown ones (docs/physics/orbiter-entry.md#rollout): stopped
## on the ground; the nose gear down at 130–170 KEAS (typically 150; 147 and 158 on
## STS-50 and -49); the drag chute out and jettisoned; wheel stop 6,000–11,000 ft from
## main-gear touchdown (JSC-23266's nominal 6,500 ft less its 500 ft dispersion, to just
## past the longest flown at Kennedy, 10,708 ft). "" when it passes.
func _rollout_error(v: Vessel) -> String:
	var rs: Vessel.Rollout = v.rolling
	if rs == null or rs.stop == null: return "no rollout to wheel stop"
	if rs.ngtd == null: return "stopped with the nose gear up"
	var ng := float(rs.ngtd.eas) / 0.514444
	if ng < 130.0 or ng > 170.0: return "nose gear touchdown at %s KEAS" % U.fixed(ng, 0)
	# Ground effect lets the flare end lower than the 12° the polar alone needs; flown
	# touchdowns were near 8°, and 14.6° scrapes the tail (JSC-23266 §4.7).
	var pitch := rad_to_deg(rs.theta_td)
	if pitch > 11.0: return "touchdown pitch %s°" % U.fixed(pitch, 1)
	if rs.chute_t < 0.0 or not rs.chute_gone: return "drag chute %s" % ("never deployed" if rs.chute_t < 0.0 else "not jettisoned")
	var ft := float(rs.stop.x) / 0.3048
	if ft < 6000.0 or ft > 11000.0: return "rollout %s ft" % U.fixed(ft, 0)
	return ""

func _rollout_summary(v: Vessel) -> String:
	var rs: Vessel.Rollout = v.rolling
	return "pitch %s° at touchdown, nose gear %s KEAS at %s s, wheel stop %s ft in %s s" % [U.fixed(rad_to_deg(rs.theta_td), 1),
		U.fixed(float(rs.ngtd.eas) / 0.514444, 0), U.fixed(float(rs.ngtd.t), 1), U.fixed(float(rs.stop.x) / 0.3048, 0),
		U.fixed(float(rs.stop.t), 0)]

## Where an unfinished flight stopped: the vessel phase (which stays `orbit` from an
## orbit start until touchdown), the program and its state, and the clock.
func _stuck(f, v: Vessel) -> String:
	var ap = f.autopilot
	return "%s%s, %s in state %s at %s km, T+%s s%s: %s" % [v.phase, " (%s)" % v.failure if v.failure != null else "",
		ap.program, ap.state_name, U.fixed(v.altitude() / 1000.0, 1), U.fixed(v.met, 0),
		", paused" if main.state.paused else "", ap.status]

func _fail(id: String, why: String) -> void:
	failures += 1
	printerr("MISSION CHECK FAIL %s: %s" % [id, why])
