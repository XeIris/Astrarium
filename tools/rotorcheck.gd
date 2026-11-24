extends SceneTree

# The rotorcraft, headless: rotors against momentum theory and the flown record, and the flight software
# flying Ingenuity on Mars and Dragonfly on Titan over planes. docs/physics/rotorcraft.md#what-tests-it.
# Run: python3 tools/check.py --only rotorcheck

var checks := 0
var failures := 0

func ok(name: String, pass_: bool, detail: String) -> void:
	checks += 1
	if not pass_: failures += 1
	print("ROTORCHECK %s %s: %s" % ["ok" if pass_ else "FAIL", name, detail])

func note(name: String, detail: String) -> void:
	print("ROTORCHECK note %s: %s" % [name, detail])

func _init() -> void:
	_mars()
	_titan()
	_fly(Rotorcraft.INGENUITY, 3.71, 0.0165, 230.0, "Ingenuity on Mars")
	_fly(Rotorcraft.DRAGONFLY, 1.352, 5.4, 194.0, "Dragonfly on Titan")
	print("ROTORCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

# Ingenuity's air: about 1.5% of Earth's at Jezero during its flights (NASA's "less than 1 percent as dense" is the
# datum's average; Jezero is 2.6 km under it). An input here.
const JEZERO_RHO := 0.0165

func _mars() -> void:
	var c := Rotorcraft.new(Rover.PlaneGround.new(), 3.71, JEZERO_RHO, 230.0, Rotorcraft.INGENUITY)
	var weight := 1.8 * 3.71
	var p := c.hover_power(weight)
	var rotor_area := PI * 0.605 * 0.605
	var ideal := pow(weight, 1.5) / sqrt(2.0 * JEZERO_RHO * rotor_area)
	var induced := 0.0
	for r in c.rotors:
		var tip := r.omega * 0.605
		induced += Rotorcraft.KAPPA * Rotorcraft.KAPPA_COAX * (r.thrust / (JEZERO_RHO * rotor_area * tip * tip)) * r.lam * JEZERO_RHO * rotor_area * tip * tip * tip
	ok("Ingenuity's induced power is momentum theory's", absf(induced / (Rotorcraft.KAPPA * Rotorcraft.KAPPA_COAX * ideal) - 1.0) < 0.01,
		"%s W against κ·κ_coax·T^1.5/√(2ρA) = %s W" % [U.fixed(induced, 1), U.fixed(Rotorcraft.KAPPA * Rotorcraft.KAPPA_COAX * ideal, 1)])
	var elec := p / 0.75 + 30.0
	ok("Ingenuity hovers on the power it flew on", elec > 200.0 and elec < 500.0,
		"%s W at the battery (%s W at the shafts), collective %s°; NASA: about 350 W in flight" % [U.fixed(elec, 0), U.fixed(p, 0),
		U.fixed(rad_to_deg(c.rotors[0].theta), 1)])
	ok("its tips run near Mach 0.7", absf(c.tip_mach() - 0.7) < 0.05, "Mach %s at 2537 rpm" % U.fixed(c.tip_mach(), 2))
	# The most it can lift: collective at its stop.
	var lift := 0.0
	for m in range(10, 120):
		c.hover_power(m * 0.1 * 3.71)
		var sat := false
		for r in c.rotors: sat = sat or r.saturated
		if sat: break
		lift = m * 0.1
	note("Ingenuity's ceiling", "it can hover %s kg at Jezero's density, its collective at the stop" % U.fixed(lift, 1))

func _titan() -> void:
	var c := Rotorcraft.new(Rover.PlaneGround.new(), 1.352, 5.4, 194.0, Rotorcraft.DRAGONFLY)
	var weight := 875.0 * 1.352
	var p := c.hover_power(weight)
	# Lorenz et al. 2018: a 420 kg concept at about 10 m/s needs a little over 2 kW. The same rotors and air,
	# the concept's weight, in forward flight at 10 m/s: the induced power falls as the disc meets new air.
	var light := Rotorcraft.new(Rover.PlaneGround.new(), 1.352, 5.4, 194.0, Rotorcraft.DRAGONFLY)
	for pp in 4: light._pair_state(pp, 420.0 * 1.352 / 4.0, 0.0, 0.0, 10.0)
	var cruise := 0.5 * 5.4 * 0.8 * 1000.0
	for r in light.rotors: cruise += r.power
	note("a 420 kg Dragonfly at 10 m/s", "%s kW at the shafts and against its drag; Lorenz et al. 2018: a little over 2 kW" % U.fixed(cruise / 1000.0, 2))
	var area := 4.0 * PI * 0.675 * 0.675
	var ideal := pow(weight, 1.5) / sqrt(2.0 * 5.4 * area)
	note("Dragonfly hovering", "%s kW at the shafts, %s rpm; ideal %s kW on its four discs" % [U.fixed(p / 1000.0, 2),
		U.fixed(c.rotors[0].omega * 60.0 / TAU, 0), U.fixed(ideal / 1000.0, 2)])
	# A small rotor's figure of merit, ideal over actual power, is 0.5–0.75 (Leishman).
	var fm := ideal / p
	ok("Dragonfly hovers within its rotors' limits on Titan", not c.rotors.any(func(r): return r.saturated) and fm > 0.4 and fm < 0.8,
		"%s kW, figure of merit %s, tip Mach %s" % [U.fixed(p / 1000.0, 2), U.fixed(fm, 2), U.fixed(c.tip_mach(), 2)])

func _fly(spec: Dictionary, g: float, rho: float, a: float, label: String) -> void:
	var c := Rotorcraft.new(Rover.PlaneGround.new(), g, rho, a, spec)
	c.place(0.0, 0.0, 0.0)
	c.armed = true
	var e0 := c.energy_wh
	c.advance(2.0)
	ok("%s rests on its legs" % label, c.on_ground and absf(c.vel.y) < 0.01, "%s m up" % U.fixed(c.height_above_ground(), 3))
	# Up at its climb rate for 4 s, then hold.
	c.cmd_climb = 1.0
	c.advance(6.0)
	c.cmd_climb = 0.0
	c.advance(12.0)
	var h := c.height_above_ground()
	c.advance(16.0)
	ok("%s climbs and holds its height" % label, h > 3.0 and absf(c.height_above_ground() - h) < 0.3 and absf(c.vel.y) < 0.1,
		"%s m after the climb, %s m four seconds later" % [U.fixed(h, 2), U.fixed(c.height_above_ground(), 2)])
	# Ahead at full stick, for long enough to get there at its tilt limit in its world's gravity.
	c.cmd_fwd = 1.0
	var reach := 15.0 + 2.0 * float(spec.v_max) / (g * tan(float(spec.tilt_max)))
	c.advance(16.0 + reach)
	var t_off := 16.0 + reach
	var v := Vector2(c.vel.x, c.vel.z).length()
	var hd := c.heading()
	ok("%s flies ahead at its top speed" % label, absf(v - float(spec.v_max)) < 0.15 * float(spec.v_max) and absf(hd) < 0.05,
		"%s m/s against %s, heading %s°" % [U.fixed(v, 2), spec.v_max, U.fixed(rad_to_deg(hd), 1)])
	c.cmd_fwd = 0.0
	c.cmd_yaw = 1.0
	# A quarter turn at its top rate.
	var t_turn := PI * 0.5 / float(spec.yaw_max)
	c.advance(t_off + t_turn)
	var turned := rad_to_deg(c.heading())
	ok("%s turns right when asked" % label, turned > 30.0 and turned < 120.0,
		"%s° in %s s, a quarter turn at its top %s°/s" % [U.fixed(turned, 0), U.fixed(t_turn, 1), U.fixed(rad_to_deg(float(spec.yaw_max)), 0)])
	c.cmd_yaw = 0.0
	c.advance(t_off + 20.0)
	c.cmd_climb = -1.0
	c.advance(t_off + 44.0)
	c.cmd_climb = 0.0
	c.advance(t_off + 48.0)
	ok("%s comes down and stands" % label, c.on_ground and not c.crashed and c.vel.length() < 0.05,
		"on its legs %s, %s m/s" % [c.on_ground, U.fixed(c.vel.length(), 3)])
	note("%s's flight" % label, "%s of %s Wh in %s s, %s m from where it took off" % [U.fixed(e0 - c.energy_wh, 2), U.fixed(e0, 0), U.fixed(c.t, 0),
		U.fixed(Vector2(c.pos.x, c.pos.z).length(), 0)])
