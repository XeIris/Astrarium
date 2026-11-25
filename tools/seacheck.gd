extends Node

# SEA CHECK: a vehicle built to float comes down on the sea it draws (sim/surface/surface_sea.gd,
# docs/physics/ocean.md#coming-down-at-sea). Apollo's command module flies its entry to the Pacific; the sea
# is stood on before it arrives, the Floater takes it the last metres and holds it on the same field the GPU
# draws, the bags right it, drawn and undrawn flights float alike, and nothing of the sea outlives the flight.
# Other Earth flights never make a sea.
#   Godot --headless --path . res://tools/seacheck.tscn

var main: Node
var failures := 0
var checks := 0

func check(what: String, ok: bool) -> void:
	checks += 1
	if ok: print("SEACHECK ok   ", what)
	else:
		failures += 1
		printerr("SEACHECK FAIL ", what)

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
	await _splashdown()
	await _parity()
	await _others()
	main.flight.teardown()
	var c := SurfaceStats.calls
	check("every sea was let go (%d made, %d let go; sites %d/%d)" % [int(c.get("sea_init", 0)), int(c.get("sea_dispose", 0)),
		int(c.get("site_init", 0)), int(c.get("site_dispose", 0))],
		int(c.get("sea_init", 0)) > 0 and c.get("sea_init", 0) == c.get("sea_dispose", 0) and c.get("site_init", 0) == c.get("site_dispose", 0))
	print("SEACHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

# Fly undrawn from the mains to `afloat_s` seconds on the sea.
func _fly(drawn: bool, afloat_s: float) -> Vessel:
	var err: String = await main.jump_scenario("apollocm:mains")
	if err != "":
		check("apollocm:mains: jump (%s)" % err, false)
		return null
	var v: Vessel = main.flight.vessel
	main.set_drawn(drawn)
	var n := 0
	while not v.afloat() and v.phase != Vessel.PHASE.DESTROYED and n < 20000:
		main.step_flight(0.05)
		n += 1
	var until := v.coord + afloat_s
	while v.afloat() and v.coord < until and n < 60000:
		main.step_flight(0.05)
		n += 1
	main.set_drawn(true)
	return v

func _splashdown() -> void:
	var v := await _fly(false, 30.0)
	if v == null: return
	var sea: SurfaceSea = v.sea
	check("the sea was stood on before the capsule reached it (%s)" % ("adopted" if sea != null and sea.adopted else "no sea"),
		sea != null and sea.adopted and v.afloat())
	if not v.afloat(): return
	var f := sea.floater
	var log_ := []
	for e in v.events: log_.append(str(e.msg))
	var splash := log_.filter(func(m): return m.begins_with("Splashdown"))
	check("it came down at Apollo's 22 mph under its mains (an input: %s)" % (splash[0] if not splash.is_empty() else "no splashdown logged"),
		absf(sea.splash_v - 9.83) < 1.0)
	print("SEACHECK note the splash: peak %s g; Apollo's design load was not published to compare" % U.fixed(f.peak_accel / 9.81, 1))
	# Where it floats, the field it reads is the field drawn: its probes against OceanField at its own time.
	sea.field.snapshot(f.t)
	var x := f.p[0]; var z := f.p[2]
	var probe := f.water(x, z)[0]
	var exact := sea.field.height_at(x, z)
	check("the water under it is the drawn sea's (probes %s m, the field %s m; Hs %s m)" % [U.fixed(probe, 3), U.fixed(exact, 3), U.fixed(sea.field.hs(), 2)],
		absf(probe - exact) < 0.1 * sea.field.hs() + 0.02)
	check("afloat: it displaces its own weight, averaged over the waves (%s m³ against %s)" % [U.fixed(f.displaced, 2), U.fixed(Capsule.MASS / 1025.0, 2)],
		f.displaced > 0.5 * Capsule.MASS / 1025.0 and f.displaced < 1.6 * Capsule.MASS / 1025.0)
	print("SEACHECK note it floats %s, heel %s°, %s m from where it came down" % ["Stable II" if sea.heel() > 90.0 else "Stable I", U.fixed(sea.heel(), 0),
		U.fixed(sea.drift(), 0)])
	main.flight.key_action("gear")
	var start := v.coord
	var upright := -1.0
	var n := 0
	while v.coord - start < Capsule.INFLATE_S + 360.0 and n < 30000:
		main.set_drawn(false)
		main.step_flight(0.25)
		n += 1
		if sea.heel() < 30.0 and upright < 0.0 and v.coord - start > 1.0: upright = v.coord - start
	main.set_drawn(true)
	check("G inflates the bags and it stands upright (%s s after the compressors start; heel %s°)" % [U.fixed(upright, 0), U.fixed(sea.heel(), 0)],
		upright > 0.0 and sea.heel() < 30.0)
	main.flight.teardown()

func _parity() -> void:
	var out := []
	for drawn in [false, true]:
		var v := await _fly(drawn, 20.0)
		if v == null or not v.afloat():
			check("parity: afloat (%s)" % ("drawn" if drawn else "undrawn"), false)
			return
		var f := v.sea.floater
		out.append([v.coord, f.p.duplicate(), f.rot.duplicate()])
		main.flight.teardown()
	var dp := 0.0
	for i in 3: dp = maxf(dp, absf(out[0][1][i] - out[1][1][i]))
	var dr := 0.0
	for i in 9: dr = maxf(dr, absf(out[0][2][i] - out[1][2][i]))
	check("drawn and undrawn float alike (%s s apart, %s m, %s in attitude)" % [U.fixed(absf(out[0][0] - out[1][0]), 3), U.expo(dp, 1), U.expo(dr, 1)],
		absf(out[0][0] - out[1][0]) < 1e-6 and dp < 1e-9 and dr < 1e-9)

# Vehicles not built to float make no sea on Earth.
func _others() -> void:
	var before := int(SurfaceStats.calls.get("sea_init", 0))
	var err: String = await main.jump_scenario("falcon9:landing_burn")
	check("falcon9:landing_burn: jump (%s)" % (err if err != "" else "ok"), err == "")
	if err != "": return
	var v: Vessel = main.flight.vessel
	for i in 60: main.animate(1.0 / 60.0)
	check("a booster over the sea makes no sea model", v.sea == null and int(SurfaceStats.calls.get("sea_init", 0)) == before)
