extends Node

# Section 6 additions of the 2026-10-30 fidelity review against independent numbers:
# the Page–Thorne disc, tidal disruption, natal kicks, the runaway greenhouse and
# habitable zone, and the secular events (novae, accretion-driven Type Ia, a star's
# end of life by age). Events run through the stage's structural-limit path.
const Catch = preload("res://tools/coursecheck.gd").Catch
var catcher := Catch.new()
var stage: Node
var checks := 0
var failures := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func near(a: float, b: float, rel: float) -> bool:
	return absf(a - b) <= rel * absf(b)

func page_thorne() -> void:
	var t0 := Physics.page_thorne_terms(0.0)
	var t1 := Physics.page_thorne_terms(0.998)
	# Peak at 9.55 M for a* = 0; efficiencies 1 − √(8/9) and 0.321 (Bardeen et al. 1972).
	check("Page–Thorne peak at 9.55 M for a* = 0", absf(float(t0.peak_r) - 9.552) < 0.02)
	check("a* = 0 efficiency 5.72%", absf(float(t0.eta) - (1.0 - sqrt(8.0 / 9.0))) < 1e-4)
	check("a* = 0.998 efficiency 32.1%", absf(float(t1.eta) - 0.321) < 2e-3)
	check("a* = 0.998 ISCO 1.237 M", absf(float(t1.isco) - 1.2370) < 1e-3)
	check("flux vanishes at the ISCO", Physics.page_thorne_flux(float(t1.isco), t1) == 0.0)
	# Far out the flux is Newtonian, 3GMṀ/(8πr³), with the zero-torque factor 1 − √(r_in/r).
	var r := 1.0e6
	check("far-field flux tends to r⁻³", near(Physics.page_thorne_flux(r, t0) * r * r * r, 1.0 - sqrt(6.0 / r), 2e-3))
	var ratio := Derive.disc_peak_temp(10.0, 0.998) / Derive.disc_peak_temp(10.0)
	print("REALISMCHECK DISC tpeak_ratio_0.998=%s" % ratio)
	check("spin heats the disc at a fixed Eddington ratio", ratio > 2.7 and ratio < 2.9)
	check("no spin, no change", Derive.disc_peak_temp(10.0, 0.0) == Derive.disc_peak_temp(10.0))

func disruption_radii() -> void:
	var r_moon := 1737.4 * Physics.AU_PER_KM
	var m_e := 1.0 / 332946.0487
	var r_d := Structure.disruption_radius("world", m_e / 81.30057, r_moon, m_e)
	# The classical fluid Roche limit of the Moon round the Earth: 18 470 km (2.9 R⊕).
	check("Moon's fluid Roche limit ~18 400 km", near(r_d / Physics.AU_PER_KM, 18400.0, 0.01))
	var r_ph := 11.08 * Physics.AU_PER_KM
	var m_mars := 3.227e-7
	check("Phobos is held by strength (rigid 1.26)", near(Structure.disruption_radius("world", 5.6e-15, r_ph, m_mars),
		1.26 * r_ph * pow(m_mars / 5.6e-15, 1.0 / 3.0), 1e-9))
	var sun := Physics.AU_PER_RSUN
	check("Sun round 10⁶ M☉: r_t/1.85 = 54 R☉", near(Structure.disruption_radius("star", 1.0, sun, 1e6) / sun, 100.0 / 1.85, 1e-6))
	check("M dwarf disrupts at r_t/0.9", near(Structure.disruption_radius("star", 0.2, sun * 0.2, 1e6) / (sun * 0.2), pow(5e6, 1.0 / 3.0) / 0.9, 1e-6))
	check("a black hole is never disrupted", Structure.disruption_radius("bh", 10.0, 1e-7, 1e6) == 0.0)

func structural_pass() -> void:
	for b in stage.state.bodies.duplicate(): stage.check_structural_limits(b)

func momentum(bodies: Array) -> DVec3:
	var p := DVec3.new()
	for b: Body in bodies:
		if b.alive: p.add_scaled_in(b.vel, b.mass)
	return p

func body(name: String) -> Body:
	return stage.state.body_named(name)

func tidal_events() -> void:
	var sun := Physics.AU_PER_RSUN
	# A star on a parabolic pass at 5 R☉ round a 10⁴ M☉ hole (r_d = 11.6 R☉, contact 1 R☉),
	# stepped finely and in a single step that jumps over the pericentre.
	for coarse in [false, true]:
		stage.clear_bodies()
		var M := 1.0e4
		var q := 5.0 * sun
		var r0 := 60.0 * sun
		# Parabola: r = 2q/(1 + cos ν); v² = 2GM/r; flight-path angle from tan γ = sin ν/(1 + cos ν).
		var nu := -acos(2.0 * q / r0 - 1.0)
		var v := sqrt(2.0 * Physics.G * M / r0)
		var gam := atan2(sin(nu), 1.0 + cos(nu))
		var rx := r0 * cos(nu)
		var ry := r0 * sin(nu)
		var th := nu + PI / 2.0 - gam
		stage.spawn_body({"type": "bh", "name": "IMBH", "mass": M, "pos": [0, 0, 0], "vel": [0, 0, 0]})
		stage.spawn_body({"type": "star", "name": "Victim", "mass": 1.0, "pos": [rx, 0.0, ry], "vel": [v * cos(th), 0.0, v * sin(th)]})
		var hole := body("IMBH")
		# The frame before, as in the stage's loop: it records the inbound radial velocity.
		structural_pass()
		var p0 := DVec3.new()
		var star_v := DVec3.new()
		var star_m := 1.0
		# Time to pericentre for a parabola: t = √(2q³/GM)·(D + D³/3), D = tan(ν/2).
		var D := tan(-nu / 2.0)
		var tp := sqrt(2.0 * q * q * q / (Physics.G * M)) * (D + D * D * D / 3.0)
		var steps := 1 if coarse else 400
		var closest := INF
		for i in steps:
			stage.step_physics(tp * 1.6 / steps)
			if body("Victim"):
				closest = minf(closest, body("Victim").pos.distance_to(hole.pos))
				p0 = momentum(stage.state.bodies)
				star_v = body("Victim").vel.clone()
				star_m = body("Victim").mass
			structural_pass()
			if body("Victim") == null: break
		var label := "coarse" if coarse else "fine"
		print("REALISMCHECK TDE %s closest_rsun=%s hole_mass=%s" % [label, closest / sun, hole.mass])
		check("%s pass: the star is disrupted" % label, body("Victim") == null)
		check("%s pass: half the star is accreted" % label, absf(hole.mass - (M + 0.5)) < 1e-9)
		var p1 := momentum(stage.state.bodies)
		# Overflow on the way in has already moved a little of the star to the hole.
		check("%s pass: the hole carries its momentum and the bound half's" % label,
			p1.distance_to(p0.clone().add_scaled_in(star_v, -0.5 * star_m)) < 1e-12 * star_v.length())
		if not coarse:
			check("fine pass: disrupted before contact, outside r_d at the last check", closest > sun)
	# A moon inside its planet's Roche limit becomes a ring; the planet keeps the mass.
	stage.clear_bodies()
	var m_e := 1.0 / 332946.0487
	var r_e := 6371.0 * Physics.AU_PER_KM
	stage.spawn_body({"type": "planet", "name": "Host", "mass": m_e, "radiusKm": 6371.0, "pos": [0, 0, 0], "vel": [0, 0, 0]})
	var a := 2.0 * r_e
	stage.spawn_body({"type": "planet", "name": "Moonlet", "mass": m_e / 81.3, "radiusKm": 1737.0,
		"pos": [a, 0, 0], "vel": [0, 0, sqrt(Physics.G * m_e / a)]})
	var rings_before: int = stage.painter.items.size()
	structural_pass()
	check("moon inside the Roche limit is torn apart", body("Moonlet") == null)
	check("the planet keeps all the debris mass", absf(body("Host").mass - m_e * (1.0 + 1.0 / 81.3)) < 1e-18)
	check("the debris is painted as a ring", stage.painter.items.size() == rings_before + 1)
	# A neutron star fed past the TOV mass by a disrupted M dwarf collapses.
	stage.clear_bodies()
	stage.spawn_body({"type": "neutron", "name": "Feeder", "mass": 2.1, "pos": [0, 0, 0], "vel": [0, 0, 0]})
	var r_star: float = Structure.structure_of({"type": "star", "mass": 0.3}).radiusAU
	stage.spawn_body({"type": "star", "name": "Dwarf", "mass": 0.3, "pos": [r_star * 1.6, 0, 0], "vel": [0, 0, 0]})
	structural_pass()
	structural_pass()
	var feeder := body("Feeder")
	check("M dwarf disrupted by the neutron star", body("Dwarf") == null)
	check("neutron star fed past TOV collapses to a black hole", feeder != null and feeder.type == "bh"
		and absf(feeder.mass - 2.25) < 1e-12)

# Roche-lobe overflow through the stage's loop, then each event it can lead to. A real
# nova cycle is ~10⁶ orbits of a cataclysmic variable, so the envelope is set, not grown.
func secular_events() -> void:
	stage.clear_bodies()
	var donor_r := 0.6 * Physics.AU_PER_RSUN
	var sep := donor_r / (1.5 * Structure.roche_lobe_fraction(0.6))
	var vrel := sqrt(Physics.G * 1.6 / sep)
	stage.spawn_body({"type": "white-dwarf", "name": "Dwarf", "mass": 1.0, "pos": [0, 0, 0], "vel": [0, 0, 0]})
	stage.spawn_body({"type": "star", "name": "Donor", "mass": 0.6, "radiusSun": 0.6, "pos": [sep, 0, 0], "vel": [0, 0, vrel]})
	var wd := body("Dwarf")
	var m_tot: float = wd.mass + body("Donor").mass
	for i in 20:
		stage.step_physics(2e-6)
		structural_pass()
	var rate := float(wd.extra.get("accretionRate", 0.0))
	print("REALISMCHECK overflow rate=%s regime=%s envelope=%s" % [rate, wd.extra.get("accretionRegime"), wd.extra.get("novaEnvelope")])
	check("an overflowing donor feeds the dwarf at Hurley's rate (R/R_L ≈ 1.5)", rate > 4e-8 and rate < 1.2e-7)
	check("below the steady-burning rate the hydrogen piles up for a nova", wd.extra.get("accretionRegime") == "nova"
		and float(wd.extra.get("novaEnvelope", 0.0)) > 0.0)
	check("overflow keeps the system's mass", absf(wd.mass + body("Donor").mass - m_tot) < 1e-14)
	var ign := Structure.nova_ignition_mass(wd.mass, wd.radius)
	wd.extra.novaEnvelope = ign * 1.01
	var m0 := wd.mass
	structural_pass()
	check("an envelope at ignition pressure goes off as a nova and is thrown off", int(wd.extra.get("novae", 0)) == 1
		and absf(wd.mass - (m0 - ign * 1.01)) < 1e-15 and float(wd.extra.novaEnvelope) == 0.0)
	# In the steady window the dwarf keeps what lands, and at Chandrasekhar it detonates.
	wd.mass = Structure.LIMITS.chandrasekhar - 1e-12
	structural_pass()
	wd.gained = 5e-7 * 1e-3
	wd.mass += wd.gained
	stage._step_secular(1e-3)
	check("steady burning keeps the accreted mass", wd.extra.get("accretionRegime") == "steady"
		and wd.mass >= Structure.LIMITS.chandrasekhar)
	structural_pass()
	check("accretion to the Chandrasekhar mass ends in a Type Ia with nothing left", body("Dwarf") == null)
	# A star that runs off the end of its track ends by age, as end_state_of says.
	stage.clear_bodies()
	stage.spawn_body({"type": "star", "name": "Old", "mass": 1.0, "phase": 1.9999, "pos": [0, 0, 0], "vel": [0, 0, 0]})
	var old := body("Old")
	stage._step_secular(float(old.structure.msLifetime) * 0.001)
	structural_pass()
	check("a 1 M☉ star at the end of its track leaves a white dwarf", old.type == "white-dwarf")

func natal_kicks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var n := 20000
	var mean := 0.0
	for i in n: mean += Structure.natal_kick_kms("neutron", 1.4, rng).length()
	mean /= n
	# A Maxwellian's mean speed is 2σ√(2/π).
	print("REALISMCHECK KICK mean_kms=%s" % mean)
	check("neutron-star kicks have the Hobbs mean (423 km/s)", near(mean, 2.0 * 265.0 * sqrt(2.0 / PI), 0.02))
	var a := RandomNumberGenerator.new(); a.seed = 3
	var b := RandomNumberGenerator.new(); b.seed = 3
	var kb := Structure.natal_kick_kms("bh", 7.0, b)
	check("black-hole kick is the momentum-conserving share", Structure.natal_kick_kms("neutron", 1.4, a).is_equal_approx(kb * 5.0))
	check("a white dwarf gets no kick", Structure.natal_kick_kms("white-dwarf", 0.6, rng) == Vector3.ZERO)
	# A 15 + 1 M☉ binary: the collapse leaves 1.62 M☉, losing over half the mass, so the
	# pair comes apart whatever the kick.
	stage.clear_bodies()
	var m1 := 15.0
	var m2 := 1.0
	var sep := 0.5
	var v := sqrt(Physics.G * (m1 + m2) / sep)
	stage.spawn_body({"type": "star", "name": "Primary", "mass": m1, "pos": [-sep * m2 / (m1 + m2), 0, 0], "vel": [0, 0, -v * m2 / (m1 + m2)]})
	stage.spawn_body({"type": "star", "name": "Partner", "mass": m2, "pos": [sep * m1 / (m1 + m2), 0, 0], "vel": [0, 0, v * m1 / (m1 + m2)]})
	var p := body("Primary")
	var v_before := p.vel.clone()
	stage.core_collapse(p)
	p = body("Primary")
	var q := body("Partner")
	var dv := DVec3.new().sub_vectors(p.vel, v_before).length() * Rocketry.AU_M / 1000.0 / Rocketry.YR_S
	print("REALISMCHECK KICK remnant=%s mass=%s dv_kms=%s" % [p.type, p.mass, dv])
	check("core collapse kicks the neutron star", p.type == "neutron" and dv > 1.0)
	var rel_v := DVec3.new().sub_vectors(p.vel, q.vel)
	var energy := 0.5 * rel_v.length_sq() - Physics.G * (p.mass + q.mass) / p.pos.distance_to(q.pos)
	check("losing over half the mass unbinds the binary (Blaauw)", energy > 0.0)

# Budyko–Sellers: today's ice edge, the snowball below a few per cent less sunlight,
# the hysteresis that keeps it frozen at today's, and ice at the equator past 54.7°.
func ice_lines() -> void:
	var s2 := RockyVisual.insolation_s2(deg_to_rad(23.44))
	var A := 0.61 * Climate.SIGMA * pow(288.15, 4.0) - LatitudeEBM.B * 15.0
	var e := LatitudeEBM.new()
	e.settle(Climate.S0 / 4.0, s2, A)
	var lat := rad_to_deg(asin(e.ice_edge()))
	print("REALISMCHECK EBM edge_deg=%s mean_c=%s" % [lat, e.mean_c()])
	check("today's ice edge sits near 72° (North et al. 1981)", lat > 66.0 and lat < 78.0)
	var f := 1.0
	while f > 0.7 and not e.snowball():
		f -= 0.005
		e.settle(Climate.S0 / 4.0 * f, s2, A)
	var freeze := f
	e.settle(Climate.S0 / 4.0, s2, A)
	var stays := e.snowball()
	while f < 1.6 and e.snowball():
		f += 0.01
		e.settle(Climate.S0 / 4.0 * f, s2, A)
	print("REALISMCHECK EBM snowball_below=%s thaws_above=%s" % [freeze, f])
	check("a few per cent less sunlight freezes it to the equator", freeze > 0.85 and freeze < 0.97)
	check("hysteresis: a snowball stays frozen at today's sunlight", stays)
	check("and thaws only far above it", f > 1.2)
	var tilted := LatitudeEBM.new()
	tilted.settle(Climate.S0 / 4.0 * 0.95, RockyVisual.insolation_s2(deg_to_rad(80.0)), A)
	check("past 54.7° obliquity the poles are the warm end", tilted.T[LatitudeEBM.N - 1] > tilted.T[0])
	# The 0-D climate follows a snowball into deep freeze.
	var sun := Body.new()
	sun.name = "Sun"; sun.type = "star"; sun.mass = 1.0; sun.luminosity = 0.85; sun.teff = 5772.0
	sun.pos = DVec3.new(1.0, 0.0, 0.0)
	var planet := Body.new()
	planet.pos = DVec3.new()
	planet.spec = {"obliquity": deg_to_rad(23.44)}
	var cold := Climate.new({"mixedLayer": 12.0, "T0": 288.0, "albedoBase": 0.306, "albedoIce": 0.45})
	for i in 400: cold.step(1.0, planet, [sun])
	print("REALISMCHECK EBM climate T=%s snowball=%s era=%s" % [cold.T, cold.snowball, cold.era.key])
	check("the climate model freezes with its snowball", cold.snowball and cold.era.key == "DEEP_FREEZE" and cold.ice == 1.0)

# A scenario of one Sun and `worlds` at their orbits, with a home world if one is given.
func load_worlds(worlds: Array) -> bool:
	Presets.PRESETS["__worlds"] = {"name": "worlds", "sceneScale": 4.0, "camRadius": 20.0, "maxStep": 5e-3,
		"climate": {"mixedLayer": 12.0, "T0": 288.0},
		"build": func() -> Array:
			var bodies: Array = [{"type": "star", "name": "Sun", "mass": 1.0, "radiusSun": 1.0, "teff": 5772.0, "luminosity": 1.0,
				"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0]}]
			for w: Dictionary in worlds:
				bodies.append(Presets.orbiter(1.0, float(w.a), U.merged({"mass": 3.0035e-6, "radiusKm": 6371.0}, w.spec), float(w.get("angle", 0.0))))
			return bodies}
	var ok: bool = stage.load_preset("__worlds")
	Presets.PRESETS.erase("__worlds")
	return ok

func run_frames(n: int, dt: float) -> void:
	for i in n: stage.step_physics(dt)

func inputs_of(cl: Climate) -> Array:
	return [cl.mixed_layer, cl.pressures.duplicate(), cl.albedo_base, cl.albedo_ice, cl.wet, cl.land, cl.ocean_depth, cl.salinity]

func balance_K(S: float, albedo: float, eps: float) -> float:
	return pow((1.0 - albedo) * S * Climate.S0 / (4.0 * eps * Climate.SIGMA), 0.25)

func each_world_settles() -> void:
	var dry := U.merged(AIRLESS, {"type": "planet", "oceans": false, "mixedLayer": 2.0, "albedoBase": 0.3, "T0": 288.0})
	check("two-world scenario loads", load_worlds([
		{"a": 0.7, "spec": U.merged(dry, {"name": "Near"})},
		{"a": 1.6, "angle": 2.0, "spec": U.merged(dry, {"name": "Far"})}]))
	var inner: Climate = stage.state.body_named("Near").climate
	var far: Climate = stage.state.body_named("Far").climate
	check("the worlds start at the same stated temperature", absf(inner.T - 288.0) < 0.01 and absf(far.T - 288.0) < 0.01)
	run_frames(300, 0.01)
	print("REALISMCHECK WORLDS near_T=%s far_T=%s" % [inner.T, far.T])
	check("two distances settle to different temperatures", inner.T - far.T > 80.0)
	check("the near world settles to its own balance", near(inner.T, balance_K(inner.S, 0.3, 1.0), 2e-3))
	check("the far world settles to its own balance", near(far.T, balance_K(far.S, 0.3, 1.0), 2e-3))
	check("the ratio is the inverse square law's", near(inner.T / far.T, sqrt(1.6 / 0.7), 5e-3))
	check("a dry world is named as one", inner.era.key == "DRY" and inner.ocean == 0.0 and inner.ice == 0.0)

	var wet := U.merged(Climate.EARTH_AIR, {"type": "planet", "oceans": true, "mixedLayer": 12.0, "albedoBase": 0.306, "albedoIce": 0.45})
	check("wet scenario loads", load_worlds([
		{"a": 1.0, "spec": U.merged(wet, {"name": "Temperate"})},
		{"a": 2.2, "angle": 2.0, "spec": U.merged(wet, {"name": "Frozen"})}]))
	var warm: Climate = stage.state.body_named("Temperate").climate
	var cold: Climate = stage.state.body_named("Frozen").climate
	run_frames(300, 0.02)
	print("REALISMCHECK WORLDS warm_T=%s %s cold_T=%s %s" % [warm.T, warm.era.key, cold.T, cold.era.key])
	check("each ocean world finds its own climate", warm.era.key == "STABLE" and cold.era.key == "DEEP_FREEZE" and cold.snowball and not warm.snowball)

func same_seed_same_worlds() -> void:
	var sparse := [{"a": 0.4, "spec": {"type": "planet", "name": "Inner", "mass": 1.66e-7, "radiusKm": 2439.7}},
		{"a": 1.0, "angle": 1.0, "spec": {"type": "planet", "name": "Middle"}},
		{"a": 1.5, "angle": 2.0, "spec": {"type": "planet", "name": "Outer", "seed": 41}},
		{"a": 2.0, "angle": 3.0, "spec": {"type": "world", "name": "Wide"}},
		{"a": 3.0, "angle": 4.0, "spec": {"type": "planet", "name": "Far"}}]
	var run := func() -> Array:
		load_worlds(sparse)
		run_frames(90, 0.01)
		var out := []
		for b: Body in stage.state.bodies:
			if b.climate != null: out.append([b.name, inputs_of(b.climate), b.climate.T, b.climate.time, b.climate.pending])
		return out
	var first: Array = run.call()
	check("every rocky world has a climate", first.size() == 5)
	check("the same scenario gives the same worlds, to the bit", run.call() == first)
	stage._cmd["seed"] = "11"
	var other: Array = run.call()
	stage._cmd.erase("seed")
	var differ := 0
	for i in first.size():
		if other[i][1] != first[i][1]: differ += 1
	print("REALISMCHECK WORLDS seed_changes=%d of %d" % [differ, first.size()])
	check("the run's seed= changes the draw", differ >= 3)
	load_worlds(sparse)
	var a: Array = inputs_of(stage.state.body_named("Outer").climate)
	var renamed := sparse.duplicate(true)
	renamed[2].spec.name = "Renamed"
	load_worlds(renamed)
	check("a spec seed outranks the name", a == inputs_of(stage.state.body_named("Renamed").climate))
	renamed[1].spec.name = "Also renamed"
	var middle: Array = first[1][1]
	load_worlds(renamed)
	check("without a spec seed the name is the seed", middle != inputs_of(stage.state.body_named("Also renamed").climate))

func stated_values_win() -> void:
	var seeded := {"type": "planet", "name": "Same", "seed": 7}
	load_worlds([{"a": 1.0, "spec": seeded}])
	var cl: Climate = stage.state.body_named("Same").climate
	var drawn := inputs_of(cl)
	load_worlds([{"a": 1.0, "spec": U.merged(seeded, {"pCO2": 0.7})}])
	cl = stage.state.body_named("Same").climate
	check("a stated value overrides only itself", cl.pressures.pCO2 == 0.7 and cl.pressures.pN2 == drawn[1].pN2 and cl.mixed_layer == drawn[0] and cl.albedo_base == drawn[2])
	load_worlds([{"a": 1.0, "spec": U.merged(seeded, {"albedo": 0.4})}])
	check("a body's albedo is the climate's ice-free base", stage.state.body_named("Same").climate.albedo_base == 0.4)
	load_worlds([{"a": 1.0, "spec": U.merged(seeded, {"albedo": 0.4, "albedoBase": 0.2})}])
	check("albedoBase outranks albedo", stage.state.body_named("Same").climate.albedo_base == 0.2)
	load_worlds([{"a": 1.0, "spec": U.merged(seeded, {"T0": 150.0})}])
	cl = stage.state.body_named("Same").climate
	check("a stated T0 starts both models there", absf(cl.T - 150.0) < 1e-2 and absf(cl.ebm.T[0] + 123.15) < 1e-2)
	load_worlds([{"a": 1.0, "spec": seeded}])
	var b: Body = stage.state.body_named("Same")
	stage.edit_body(b, {"pCO2": 0.33})
	check("an edit overrides the draw", b.climate.pressures.pCO2 == 0.33 and b.spec.pCO2 == 0.33)
	stage.edit_body(b, {"pCO2": null})
	check("unsetting an edit returns to the draw", inputs_of(b.climate) == drawn)
	for bad: Dictionary in [{"greenhuose": 0.5}, {"greenhouse": 0.5}, {"mixedLayer": -1.0}]:
		Presets.PRESETS["__bad"] = {"name": "bad", "sceneScale": 1.0, "camRadius": 1.0, "climate": bad,
			"build": func() -> Array: return [{"type": "world", "home": true}]}
		check("a preset's climate block is validated: %s" % bad, not stage.load_preset("__bad"))
	Presets.PRESETS.erase("__bad")

func draw_ranges() -> void:
	var m_e := 1.0 / 332946.0487
	# Mass, radius km, insolation; solar-system anchors of the shoreline's calibration.
	var kept := {"Earth": [m_e, 6371.0, 1.0], "Venus": [1.0 / 408523.719, 6051.8, 1.91], "Titan": [6.76e-8, 2574.7, 0.011]}
	var lost := {"Moon": [m_e / 81.3, 1737.4, 1.0], "Mercury": [1.0 / 6023657.33, 2439.7, 6.67], "Callisto": [5.41e-8, 2410.0, 0.037]}
	for n in kept:
		check("%s lies above the shoreline" % n, ClimateInputs.retention(kept[n][0], kept[n][1] * Physics.AU_PER_KM, kept[n][2]) > 0.2)
	for n in lost:
		check("%s lies below the shoreline" % n, ClimateInputs.retention(lost[n][0], lost[n][1] * Physics.AU_PER_KM, lost[n][2]) < 0.0)
	var mars := ClimateInputs.retention(1.0 / 3098703.59, 3389.5 * Physics.AU_PER_KM, 0.43)
	var earth := ClimateInputs.retention(m_e, 6371.0 * Physics.AU_PER_KM, 1.0)
	print("REALISMCHECK DRAW mars_x=%s earth_x=%s" % [mars, earth])
	check("the shoreline is pinned to Mars", absf(mars) < 0.02)
	check("Earth's retention is 1", absf(earth - 1.0) < 0.1)
	var bad := 0
	var wet_above_runaway := 0
	var wet_below_shoreline := 0
	for me in [0.01, 0.1, 0.5, 1.0, 5.0, 10.0]:
		var mass := float(me) * m_e
		var radius := Scale.physical_radius_au("planet", mass, null)
		for S in [0.0, 1e-3, 0.1, 0.43, 1.0, 1.04, 1.5, 5.0, 30.0]:
			var x := ClimateInputs.retention(mass, radius, S)
			for i in 64:
				var d := ClimateInputs.draw("w%d" % i, 3, mass, radius, S, 1.05)
				if not ClimateInputs.input_error(d).is_empty() or float(d.albedoBase) + float(d.albedoIce) > 1.0: bad += 1
				if d.oceans and S > 1.05: wet_above_runaway += 1
				if d.oceans and x < 0.0: wet_below_shoreline += 1
				if not d.oceans and d.albedoIce != 0.0: bad += 1
	check("every draw is inside the input domain", bad == 0)
	check("nothing draws an ocean above the runaway limit", wet_above_runaway == 0)
	check("nothing draws an ocean below the shoreline", wet_below_shoreline == 0)
	var r_small := 2439.7 * Physics.AU_PER_KM
	var r_earth := 6371.0 * Physics.AU_PER_KM
	var count_wet := func(mass: float, radius: float, S: float) -> int:
		var w := 0
		for i in 200:
			if ClimateInputs.draw("n%d" % i, 0, mass, radius, S, 1.05).oceans: w += 1
		return w
	check("a small hot world keeps nothing", count_wet.call(1.66e-7, r_small, 6.67) == 0
		and float(ClimateInputs.draw("n", 0, 1.66e-7, r_small, 6.67, 1.05).pCO2) == 0.0)
	var earths: int = count_wet.call(m_e, r_earth, 1.0)
	print("REALISMCHECK DRAW earths_wet=%d of 200" % earths)
	check("most Earths keep their oceans, some do not", earths > 150 and earths < 200)
	check("a hot heavy world can be a Venus", float(ClimateInputs.draw("v", 0, m_e, r_earth, 1.91, 1.05).pCO2) >= 10.0)

func solar_system() -> void:
	check("solar preset loads", stage.load_preset("solar"))
	for n in ["Mercury", "Venus", "Earth", "Moon", "Mars", "Pluto"]:
		check("%s has a climate" % n, stage.state.body_named(n).climate != null)
	for n in ["Sun", "Jupiter", "Neptune"]:
		check("%s has none" % n, stage.state.body_named(n).climate == null)
	check("no home world in this scenario", stage.get_home() == null)
	# NSSDC fact sheets (the Moon's is its black-body figure), against the mean over a few
	# orbits: a thin dry layer follows Mercury's and Mars's eccentric sunlight.
	var measured := {"Mercury": [440.0, 0.03], "Venus": [737.0, 0.01], "Earth": [288.0, 0.015], "Moon": [270.4, 0.015], "Mars": [214.0, 0.03]}
	var sum := {}
	for n in measured: sum[n] = 0.0
	var frames := 150
	for i in frames:
		stage.step_physics(0.02)
		for n in measured: sum[n] += stage.state.body_named(n).climate.T / frames
	for n in measured:
		var cl: Climate = stage.state.body_named(n).climate
		print("REALISMCHECK SOLAR %s mean_T=%s S=%s era=%s" % [n, sum[n], cl.S, cl.era.key])
		check("%s settles near its measured temperature" % n, near(sum[n], measured[n][0], measured[n][1]))
	var pluto: Climate = stage.state.body_named("Pluto").climate
	print("REALISMCHECK SOLAR Pluto T=%s S=%s" % [pluto.T, pluto.S])
	check("Pluto stays in its own balance", near(pluto.T, balance_K(pluto.S, 0.52, 1.0), 0.01))
	check("Earth alone is wet", stage.state.body_named("Earth").climate.wet and not stage.state.body_named("Mars").climate.wet)
	check("Earth is in its stable era", stage.state.body_named("Earth").climate.era.key == "STABLE")

# The home world's climate must stay the model it was: step a bare one beside it, frame by frame.
func home_is_unchanged() -> void:
	for key in ["trisolaris", "edu_seasons"]:
		check("%s loads" % key, stage.load_preset(key))
		var home: Body = stage.get_home()
		var cl: Climate = home.climate
		var bare := Climate.new(Presets.PRESETS[key].climate)
		bare.step(1e-6, home, stage.get_stars())
		var dt: float = float(stage.state.time_scale) / 60.0
		var same := true
		for i in 600:
			var accepted: float = stage.step_physics(dt)
			bare.step(accepted, home, stage.get_stars())
			same = same and bare.T == cl.T and bare.ice == cl.ice and bare.ocean == cl.ocean and bare.clouds == cl.clouds
		print("REALISMCHECK HOME %s T=%s bare=%s" % [key, cl.T, bare.T])
		check("%s's home climate is the bare model to the bit" % key, same and bare.ebm.T == cl.ebm.T and bare.history == cl.history)
	# A home world is today's Earth where its preset says nothing: NSSDC's 288 K, and the
	# latitude model's own 72° (North, Cahalan & Coakley), at one solar constant.
	check("edu_seasons loads", stage.load_preset("edu_seasons"))
	var earth: Body = stage.get_home()
	var dt: float = float(stage.state.time_scale) / 60.0
	var mean := 0.0
	var frames := 3000
	for i in frames:
		stage.step_physics(dt)
		mean += earth.climate.T / frames
	var edge_deg := rad_to_deg(asin(earth.climate.ice_edge))
	print("REALISMCHECK HOME earth mean=%s S=%s edge=%s" % [mean, earth.climate.S, edge_deg])
	check("a home Earth settles at NSSDC's 288 K", absf(mean - 288.0) < 1.5)
	check("with no ice to speak of in its global ramp and an ice line at 72°", earth.climate.era.key == "STABLE" and absf(edge_deg - 72.0) < 3.0)
	check("a home world's model is today's air over today's sea", Climate.HOME_INPUTS.albedoBase == 0.306 and Climate.HOME_INPUTS.pCO2 == Climate.EARTH_AIR.pCO2 and Climate.HOME_INPUTS.pN2 == Climate.EARTH_AIR.pN2)

func home_removed() -> void:
	check("home scenario loads", load_worlds([
		{"a": 1.0, "spec": {"type": "world", "name": "Home", "home": true}},
		{"a": 0.6, "angle": 1.0, "spec": {"type": "planet", "name": "Inner"}},
		{"a": 1.7, "angle": 2.0, "spec": {"type": "planet", "name": "Outer"}},
		{"a": 3.0, "angle": 3.0, "spec": {"type": "planet", "name": "Far"}},
		{"a": 4.0, "angle": 4.0, "spec": {"type": "planet", "name": "Further"}}]))
	var home: Body = stage.get_home()
	check("the home world is home", home != null and home.name == "Home")
	run_frames(10, 0.01)
	stage.remove_body(home.id)
	check("the home world is gone", stage.get_home() == null)
	var worlds := []
	var at := []
	for n in ["Inner", "Outer", "Far", "Further"]:
		var cl: Climate = stage.state.body_named(n).climate
		worlds.append(cl)
		at.append(cl.time)
	check("no world to read, so the panel hides", stage.climate_world() == null and not stage.hud.ids.climatePanel.visible)
	var t0: float = stage.state.sim_years
	run_frames(60, 0.01)
	var ran := true
	for i in worlds.size():
		ran = ran and worlds[i].time > at[i] and is_finite(worlds[i].T)
		# The clock is the same for all of them, stepped or owed.
		ran = ran and absf(worlds[i].time + worlds[i].pending - stage.state.sim_years) < 1e-5
	print("REALISMCHECK HOME removed sim=%s since=%s" % [stage.state.sim_years, stage.state.sim_years - t0])
	check("the other climates keep running", ran)
	stage.set_follow(stage.state.body_named("Far"))
	check("focusing a world brings the panel to it", stage.climate_world().name == "Far")
	run_frames(1, 0.01)
	check("the panel's world owes nothing", stage.state.body_named("Far").climate.pending == 0.0)

	# A statement about water decides which world the rest is drawn for, either way.
	load_worlds([{"a": 1.0, "spec": {"type": "planet", "name": "Dry", "seed": 1, "oceans": false}},
		{"a": 0.3, "spec": {"type": "planet", "name": "Wet", "seed": 1, "oceans": true, "mass": 1.66e-7, "radiusKm": 2439.7}}])
	var dry: Climate = stage.state.body_named("Dry").climate
	var sea: Climate = stage.state.body_named("Wet").climate
	check("a stated dry world draws no ice and a thin layer", dry.albedo_ice == 0.0 and dry.mixed_layer <= 3.0)
	check("a stated ocean draws an ocean's layer and ice", sea.wet and sea.mixed_layer >= 10.0 and sea.albedo_ice >= 0.3)

func climates_follow_type() -> void:
	stage.clear_bodies()
	var gas: Body = stage.spawn_body({"type": "gas-giant"})
	check("a gas giant has no climate", gas.climate == null)
	var rock: Body = stage.spawn_body({"type": "planet", "pos": [2.0, 0.0, 0.0]})
	check("a spawned planet has one", rock.climate != null)
	stage.transmute(rock, "bh", null)
	check("a world that collapses loses it", rock.climate == null)
	stage.clear_bodies()

func stiff_worlds_stay_finite() -> void:
	var star := Body.new()
	star.type = "star"; star.mass = 1.0; star.luminosity = 1.0; star.teff = 5772.0; star.name = "Sun"
	var rock := Body.new()
	rock.type = "planet"; rock.mass = 3e-6; rock.name = "Rock"
	rock.pos = DVec3.new(1.0, 0.0, 0.0)
	var dry := Climate.new(U.merged(AIRLESS, {"oceans": false, "mixedLayer": 0.1, "albedoBase": 0.1, "albedoIce": 0.0, "T0": 3.0}))
	for dt in [1e-6, 0.02, 1.0, 100.0, 1e4]:
		dry.step(float(dt), rock, [star])
		check("a dry world is stable at %s yr per step" % dt, is_finite(dry.T) and dry.T >= 3.0 and dry.T < 300.0)
	check("a long step lands on the balance", near(dry.T, balance_K(1.0, 0.1, 1.0), 1e-3))
	# Dense CO₂ and thin air on a thin layer, at any frame length: the kinks in the fits included.
	for air: Dictionary in [VENUS_AIR, MARS_AIR, {"pCO2": 8.0, "pN2": 1.0}]:
		for s in [0.3, 1.0, 3.0]:
			var rocky := Climate.new(U.merged(AIRLESS, U.merged(air, {"oceans": false, "mixedLayer": 0.1, "albedoBase": 0.2, "albedoIce": 0.0, "T0": 200.0})))
			var sun := Body.new()
			sun.type = "star"; sun.mass = 1.0; sun.teff = 5772.0; sun.name = "Sun"; sun.luminosity = s
			for dt in [1e-6, 0.02, 1.0, 100.0, 1e4]: rocky.step(float(dt), rock, [sun])
			var absorbed: float = 0.8 * s * Climate.S0 / 4.0
			check("a dry column lands on its balance: %s at %s" % [air.keys().size(), s], is_finite(rocky.T) and absf(rocky.olr(rocky.T) - absorbed) < 0.01 * absorbed)
	var thin := Climate.new({"mixedLayer": 0.1, "albedoBase": 0.306, "albedoIce": 0.45})
	var lo := INF
	var hi := -INF
	for i in 200:
		thin.step(5.0, rock, [star])
		if i > 100:
			lo = minf(lo, thin.T); hi = maxf(hi, thin.T)
	print("REALISMCHECK STIFF wet T=[%s, %s]" % [lo, hi])
	check("a thin wet layer holds its balance at 5 yr per step", is_finite(thin.T) and hi - lo < 1.0 and near(thin.T, 287.0, 0.02))
	var start := Climate.new(U.merged(AIRLESS, {"oceans": false, "albedoBase": 0.3, "albedoIce": 0.0}))
	check("the warmest balance solves the energy equation", near(start.equilibrium_T(1.0), balance_K(1.0, 0.3, 1.0), 1e-6))
	check("no light leaves the floor", start.equilibrium_T(0.0) == 3.0)
	var thick := Climate.new(U.merged(AIRLESS, U.merged(VENUS_AIR, {"oceans": false, "albedoBase": 0.77, "albedoIce": 0.0})))
	thick.set_world(1.0 / 408523.719, 6051.8 * Physics.AU_PER_KM)
	check("a thick column's warmest balance is found too", near(thick.equilibrium_T(1.91), 737.0, 0.01))
	var boiling := Climate.new({"albedoBase": 0.1, "albedoIce": 0.0})
	check("a wet world's start stops at its boiling point", near(boiling.equilibrium_T(3.0), boiling.boiling_point(0.0), 1e-9))

const AIRLESS := {"pN2": 0.0, "pO2": 0.0, "pAr": 0.0, "pCO2": 0.0, "pCH4": 0.0, "pSO2": 0.0}
const VENUS_AIR := {"pCO2": 88.78, "pN2": 3.22, "pAr": 0.00644, "pSO2": 0.0138}
const MARS_AIR := {"pCO2": 6.048e-3, "pN2": 1.647e-4, "pAr": 1.234e-4, "pO2": 1.018e-5}

# What the column radiates, against what it was fitted to and what it was not.
func composition() -> void:
	var earth := Climate.new({"albedoBase": 0.306, "mixedLayer": 12.0})
	var target := 0.61 * Climate.SIGMA * pow(288.15, 4.0)
	var slope := (earth.olr(289.15) - earth.olr(287.15)) * 0.5
	print("REALISMCHECK AIR earth olr=%s target=%s slope=%s T=%s" % [earth.olr(288.15), target, slope, earth.equilibrium_T(1.0)])
	check("today's air radiates what pins the latitude model's ice line", near(earth.olr(288.15), target, 1e-4))
	check("its slope is the latitude model's B", near(slope, LatitudeEBM.B, 0.01))
	check("today's air settles Earth near 288 K", near(earth.equilibrium_T(1.0), 288.0, 0.005))
	# Independent of those fits.
	var doubled := Climate.new({"albedoBase": 0.306, "pCO2": Climate.EARTH_AIR.pCO2 * 2.0})
	var forcing := earth.olr(288.15) - doubled.olr(288.15)
	print("REALISMCHECK AIR doubling=%s" % forcing)
	check("doubling CO₂ is Myhre's 5.35·ln 2", near(forcing, 5.35 * log(2.0), 0.02))
	var two_bar := Atmosphere.new({"pCO2": 1.9, "pN2": 0.1}, 3.73).olr(250.0)
	print("REALISMCHECK AIR kopparapu_2bar_250K=%s (86–88.4)" % two_bar)
	check("2 bar of CO₂ at 250 K on a Mars is Kopparapu's line-by-line 86–88 W/m²", two_bar > 86.0 * 0.92 and two_bar < 88.4 * 1.08)
	# Kopparapu's Fig. 5a, read off the plot: 273 K, wet, over 1 bar of N₂.
	for row in [[1.0, 112.0], [3.0, 88.0], [10.0, 67.0], [35.0, 65.0]]:
		var dense := Atmosphere.new({"pN2": 1.0, "pCO2": row[0]}, Atmosphere.G_EARTH).olr(273.0, 1.0)
		print("REALISMCHECK AIR %s bar CO₂ at 273 K: %s (%s)" % [row[0], dense, row[1]])
		check("%s bar of CO₂ at 273 K lies within 25%% of Kopparapu's curve" % row[0], near(dense, row[1], 0.25))
	var previous := INF
	var falling := true
	for p in [1e-6, 1e-4, 1e-2, 0.1, 1.0, 10.0, 100.0]:
		var o := Atmosphere.new({"pN2": 1.0, "pCO2": p}, Atmosphere.G_EARTH).olr(288.0, 1.0)
		falling = falling and o <= previous
		previous = o
	check("more CO₂ never radiates more", falling)
	# Broadening: the same mixing ratio under thinner air traps less; so does a stronger pull.
	var thick_air := Atmosphere.new({"pN2": 1.0, "pCO2": 1e-3}, Atmosphere.G_EARTH)
	var thin_air := Atmosphere.new({"pN2": 0.1, "pCO2": 1e-4}, Atmosphere.G_EARTH)
	check("thin air broadens the bands less", thin_air.olr(288.0) > thick_air.olr(288.0))
	check("a stronger pull holds a thinner column", Atmosphere.new({"pN2": 1.0, "pCO2": 1e-3}, 20.0).olr(288.0) > thick_air.olr(288.0))
	check("thin air's water closes at a warmer level", thin_air.olr(288.0, 1.0) > thick_air.olr(288.0, 1.0))
	check("no gas radiates as a black body", near(Atmosphere.new({}, 9.82).olr(300.0), Climate.SIGMA * pow(300.0, 4.0), 1e-12))
	# The fits pin each measured world on its own column, so these are identities of the
	# constants: what they catch is a column or constant that moves. What says the constants
	# mean something is the emission level, which should sit inside Venus's cloud deck (VIRA,
	# the deck's 48–70 km assumed).
	var venus := Atmosphere.new(VENUS_AIR, 8.87)
	var mars := Atmosphere.new(MARS_AIR, 3.73)
	check("Venus's air balances NSSDC's 737 K", near(venus.olr(737.0), (1.0 - 0.77) * 2601.3 / 4.0, 0.01))
	check("Mars's air balances NSSDC's 214 K", near(mars.olr(214.0), (1.0 - 0.25) * 586.2 / 4.0, 0.001))
	var level: float = 92.0 * pow(venus.emit_k, 1.0 / venus.kappa)
	var vira: Dictionary = Rocketry.ATMOSPHERES.Venus.duplicate()
	vira.g = 8.87; vira.R = 6051800.0
	var deck := [Rocketry.pressure(vira, 70e3) * 1e-5, Rocketry.pressure(vira, 48e3) * 1e-5]
	print("REALISMCHECK AIR venus emission level=%s bar, deck %s" % [level, deck])
	check("Venus radiates from inside its cloud deck", level > deck[0] and level < deck[1])
	check("without its SO₂ Venus could not reach 737 K", Atmosphere.new({"pCO2": 88.78, "pN2": 3.22}, 8.87).olr(737.0) > 400.0)
	# Mean molecular mass against NSSDC's, which the fits never saw.
	var earth_air := Atmosphere.new(Climate.EARTH_AIR, 9.82)
	check("Earth's mean molecular mass is NSSDC's", near(earth_air.mean_molar * 1000.0, 28.97, 2e-3))
	check("Venus's mean molecular mass is NSSDC's", near(venus.mean_molar * 1000.0, 43.45, 2e-3))
	check("Mars's mean molecular mass is NSSDC's", near(mars.mean_molar * 1000.0, 43.49, 2e-3))

func gas_column_look() -> void:
	var earth := Atmosphere.new(Climate.EARTH_AIR, 9.82)
	var venus := Atmosphere.new(VENUS_AIR, 8.87)
	var mars := Atmosphere.new(MARS_AIR, 3.73)
	print("REALISMCHECK SKY tau earth=%s venus=%s mars=%s" % [earth.tau550, venus.tau550, mars.tau550])
	check("Earth's column has its 0.097 of Rayleigh depth at 550 nm", near(earth.tau550, 0.097, 0.01))
	check("CO₂ scatters ~2.5 times air (Kopparapu)", near(Atmosphere.GASES.pCO2.rayleigh / (earth.tau550 / earth.column_molecules(earth.p_dry)), 2.5, 0.05))
	var e: Dictionary = earth.limb()
	var v: Dictionary = venus.limb()
	var m: Dictionary = mars.limb()
	print("REALISMCHECK SKY limb earth=%s venus=%s mars=%s" % [e, v, m])
	check("Earth's sky is the look it had", near(e.thick, 1.0, 1e-3) and absf(e.tint.x - 1.0) < 1e-3 and absf(e.tint.z - 1.0) < 1e-3)
	check("Venus's gas gives the depth its look was authored at", near(v.thick, 2.4, 0.05))
	check("a thick sky has lost its blue", v.tint.x > 1.5 and v.tint.z < 0.7)
	check("a thin sky is the bluer", m.tint.z > 1.2 and m.tint.x < 1.0)
	check("Mars's gas alone is nearly nothing, as dust makes its sky", m.thick < 0.05)
	check("nothing scatters nothing", Atmosphere.new({}, 9.82).limb().thick == 0.0)
	check("steam thickens a sky", earth.limb(10.0).thick > 1.5)
	var cl := Climate.new()
	var serial := cl.sky_serial
	cl.apply_inputs({"pN2": 5.0})
	check("an edit of the air moves the sky", cl.sky_serial != serial and float(cl.sky.thick) > 1.0)
	serial = cl.sky_serial
	var rock := Body.new()
	rock.type = "planet"; rock.mass = 3e-6; rock.pos = DVec3.new(1.0, 0.0, 0.0)
	var star := Body.new()
	star.type = "star"; star.mass = 1.0; star.luminosity = 1.0; star.teff = 5772.0; star.name = "Sun"
	cl.step(1e-3, rock, [star])
	check("a quiet step leaves it alone", cl.sky_serial == serial)

	# What a vessel flies through: the column, against NSSDC's own numbers.
	load_worlds([{"a": 1.0, "spec": U.merged(Climate.EARTH_AIR, {"type": "planet", "name": "Elsewhere", "T0": 288.0, "oceans": false, "pO2": 0.21243})},
		{"a": 3.0, "spec": U.merged(AIRLESS, {"type": "planet", "name": "Bare"})}])
	var atm = Rocketry.flight_env(stage.state.body_named("Elsewhere")).atm
	print("REALISMCHECK SKY flight %s" % [atm])
	check("an uncatalogued world flies through its own column", near(atm.p0, 101400.0, 0.01))
	check("at NSSDC's density and scale height", near(atm.rho0, 1.217, 0.03) and near(atm.layers[0].H, 8500.0, 0.03))
	check("with a diatomic's γ", near(atm.gamma, 1.4, 0.01))
	check("and the sky's depth from its Rayleigh column", near(atm.skyThick, 1.0, 0.02))
	check("no air, no atmosphere", Rocketry.flight_env(stage.state.body_named("Bare")).atm == null)
	stage.edit_body(stage.state.body_named("Elsewhere"), {"pCO2": 10.0})
	check("an edit reaches the flight column", Rocketry.flight_env(stage.state.body_named("Elsewhere")).atm.p0 > 1e6)
	check("a catalogued world keeps its measured one", stage.load_preset("solar")
		and Rocketry.flight_env(stage.state.body_named("Earth")).atm.has("thermo")
		and Rocketry.flight_env(stage.state.body_named("Venus")).atm.p0 == 9.21e6)

func water() -> void:
	var mk := func(x: float, L: float) -> Body:
		var s := Body.new()
		s.name = "Sun"; s.type = "star"; s.mass = 1.0; s.luminosity = L; s.teff = 5772.0
		s.pos = DVec3.new(x, 0.0, 0.0)
		return s
	var here := Body.new()
	here.pos = DVec3.new()
	var settle := func(cl: Climate, L: float, steps := 800, dt := 0.1) -> void:
		var star: Body = mk.call(1.0, L)
		for i in steps: cl.step(dt, here, [star])

	# Salinity.
	check("sea water freezes at −1.9 °C", near(Climate.freezing_point(35.0) - 273.15, -1.92, 0.01))
	check("fresh water at 0 °C", Climate.freezing_point(0.0) == 273.15)
	check("brine lower still", Climate.freezing_point(230.0) < Climate.freezing_point(100.0) and Climate.freezing_point(100.0) < Climate.freezing_point(35.0))
	var fresh := Climate.new({"salinity": 0.0, "albedoBase": 0.306})
	var sea := Climate.new({"salinity": 35.0, "albedoBase": 0.306})
	var brine := Climate.new({"salinity": 230.0, "albedoBase": 0.306})
	check("the ice's onset moves with the freezing point", near(fresh.albedo(278.0).ice * 45.0, 1.92, 0.01))
	check("sea water's onset stays at 278 K", sea.albedo(278.0).ice == 0.0 and sea.ebm.t_ice == LatitudeEBM.T_ICE)
	check("brine holds off the ice", brine.albedo(270.0).ice == 0.0 and sea.albedo(270.0).ice > 0.0)
	check("the latitude model's edge moves with it", absf(brine.ebm.t_ice - (LatitudeEBM.T_ICE + Climate.freezing_point(230.0) - Climate.freezing_point(35.0))) < 1e-9)
	# The same world and light: which side of freezing it lands on is the salt's doing.
	var cases := {}
	for s in [0.0, 230.0]:
		var cl := Climate.new({"salinity": s, "albedoBase": 0.306, "T0": 280.0, "mixedLayer": 5.0})
		settle.call(cl, 0.945, 2000, 0.05)
		cases[s] = cl
		print("REALISMCHECK WATER salinity=%s T=%s ice=%s edge=%s era=%s" % [s, cl.T, cl.ice, cl.ice_edge, cl.era.key])
	check("salt decides whether a marginal world freezes", cases[0.0].ice > cases[230.0].ice)

	# The states.
	var dry := Climate.new({"oceans": false})
	settle.call(dry, 1.0)
	check("no ocean is a dry world", dry.era.key == "DRY" and dry.ocean == 0.0 and dry.ice == 0.0 and dry.water_column == 0.0)
	check("all land is a dry world", Climate.new({"land": 1.0}).classify(288.0).key == "DRY" and not Climate.new({"land": 1.0}).wet)
	check("no depth is a dry world", Climate.new({"oceanDepth": 0.0}).classify(288.0).key == "DRY")
	var global_sea := Climate.new({"land": 0.0, "albedoBase": 0.306, "mixedLayer": 12.0})
	settle.call(global_sea, 1.0)
	print("REALISMCHECK WATER global T=%s era=%s" % [global_sea.T, global_sea.era.label])
	check("no land is a global ocean", global_sea.era.key == "WATER_WORLD" and global_sea.era.label == "Global ocean")
	var shell := Climate.new({"land": 0.0, "albedoBase": 0.306, "mixedLayer": 12.0, "T0": 250.0})
	settle.call(shell, 0.2)
	print("REALISMCHECK WATER shell T=%s era=%s ice=%s" % [shell.T, shell.era.label, shell.ice])
	check("frozen over with no land is an ice shell", shell.era.key == "ICE_SHELL" and shell.ice == 1.0 and shell.era.label == "Ice shell")
	check("and its water is still all there", shell.ocean == 1.0 and shell.water_column > 0.0)
	var frozen := Climate.new({"land": 0.3, "albedoBase": 0.306, "mixedLayer": 12.0, "T0": 250.0})
	settle.call(frozen, 0.2)
	check("frozen over with continents is a deep freeze", frozen.era.key == "DEEP_FREEZE")
	var wet_earth := Climate.new({"albedoBase": 0.306, "mixedLayer": 12.0})
	settle.call(wet_earth, 1.0)
	check("Earth is the stable era", wet_earth.era.key == "STABLE")
	# So little water that the air holds it all: no sea, whatever the flag says, until it is cold.
	var damp := Climate.new({"oceanDepth": 1e-5, "land": 0.0, "albedoBase": 0.306})
	print("REALISMCHECK WATER damp column=%s vapour288=%s" % [damp.water_column, damp.vapour_column(288.0)])
	check("the air can hold a small inventory", damp.wet and damp.classify(288.0).key == "DRY" and damp.albedo(277.5).ice == 0.0)
	check("until it is cold enough to stand as frost", damp.albedo(220.0).ice > 0.0)
	var slight := Climate.new({"oceanDepth": 1e-6, "land": 0.0})
	check("a few grams hardly close the water bands", slight.olr(288.0) > wet_earth.olr(288.0) + 40.0)
	check("a land world's dry sky is weaker than a wet one's", Climate.new({"land": 0.98}).olr(288.0) > wet_earth.olr(288.0) + 40.0)

	# The inventory, from the depth and the world's own gravity.
	var earthly := Climate.new()
	check("Earth's sea is 2.7e6 kg/m²", near(earthly.water_column, 2.7e6, 0.01))
	check("all of it as steam is ~265 bar", near(earthly.steam_bar, 265.0, 0.01))
	var small := Climate.new({"oceanDepth": 0.37})
	check("a tenth of the sea weighs a tenth", near(small.steam_bar, earthly.steam_bar * 0.1, 1e-9))
	check("a tenth of the sea boils at its own lower pressure", small.boiling_point(1.0) < earthly.boiling_point(1.0) - 100.0)
	var light := Climate.new()
	light.set_world(3.0035e-6 / 8.0, 6371.0 * Physics.AU_PER_KM / 2.0)
	print("REALISMCHECK WATER half g=%s steam_bar=%s" % [light.gravity, light.steam_bar])
	check("half the gravity is half the steam's weight", near(light.gravity, 4.91, 0.01) and near(light.steam_bar, earthly.steam_bar * 0.5, 0.01))
	check("the bare model is Earth's", earthly.gravity == Atmosphere.G_EARTH)
	var boil_big := Climate.new({"albedoBase": 0.306, "T0": 400.0, "mixedLayer": 12.0})
	var boil_small := Climate.new({"albedoBase": 0.306, "T0": 400.0, "mixedLayer": 12.0, "oceanDepth": 0.37})
	settle.call(boil_big, 1.5, 100, 1.0)
	settle.call(boil_small, 1.5, 100, 1.0)
	print("REALISMCHECK WATER steam big=%s small=%s T=%s/%s" % [boil_big.steam, boil_small.steam, boil_big.T, boil_small.T])
	check("the same flux boils a small sea ten times the faster", near(boil_small.steam, boil_big.steam * 10.0, 0.03))
	check("each sits on its own saturation curve", absf(boil_big.T - boil_big.boiling_point(boil_big.steam)) < 1e-6 and absf(boil_small.T - boil_small.boiling_point(boil_small.steam)) < 1e-6)
	check("and the kilograms agree", near(boil_small.steam * boil_small.water_column, boil_big.steam * boil_big.water_column, 0.03))
	# Conservation through a boil, a rain-out and an escape; the last in a small sea.
	var cycle := Climate.new({"albedoBase": 0.306, "mixedLayer": 12.0, "oceanDepth": 0.01, "land": 0.0})
	var worst := 0.0
	for L in [1.5, 0.8, 1.5]:
		var star: Body = mk.call(1.0, L)
		for i in 400:
			cycle.step(25.0, here, [star])
			worst = maxf(worst, absf(cycle.ocean + cycle.steam + cycle.lost - 1.0))
	print("REALISMCHECK WATER cycle worst=%s ocean=%s steam=%s lost=%s" % [worst, cycle.ocean, cycle.steam, cycle.lost])
	check("water is conserved through boiling, rain and escape", worst < 1e-11)
	# Escape: gravity sets both limits, the inventory the time it takes.
	var deep_well := Climate.new()
	deep_well.set_world(3.0035e-6 * 8.0, 6371.0 * Physics.AU_PER_KM * 2.0)
	check("a deeper well caps the energy-limited flux lower", near(deep_well.hydrogen_escape(600.0, 1.5) * 4.0, earthly.hydrogen_escape(600.0, 1.5), 1e-3))
	check("Earth's cap is its 1.6e15 m⁻²s⁻¹", near(earthly.hydrogen_escape(600.0, 1.0), 1.6e15, 0.05))
	var gone := Climate.new({"albedoBase": 0.306, "oceanDepth": 0.037})
	for i in 500: gone.step(2e5, here, [mk.call(1.0, 1.5)])
	print("REALISMCHECK WATER gone ocean=%s lost=%s era=%s" % [gone.ocean, gone.lost, gone.era.key])
	check("a world that loses its water is named dry", gone.ocean + gone.steam == 0.0 and near(gone.lost, 1.0, 1e-9) and gone.era.key == "DRY")
	check("and has no ice left", gone.albedo(200.0).ice == 0.0)
	# Thin air boils low, and the vapour raises the pressure it boils at: the state feeding itself.
	var thin := Climate.new({"pN2": 0.01, "pO2": 0.0, "pAr": 0.0, "pCO2": 0.0, "pCH4": 0.0, "albedoBase": 0.306, "mixedLayer": 12.0})
	check("thin air's boiling point is low", thin.boiling_point(0.0) < 320.0)
	settle.call(thin, 2.5, 400, 5.0)
	print("REALISMCHECK WATER thin T=%s steam=%s bar=%s era=%s" % [thin.T, thin.steam, thin.steam * thin.steam_bar, thin.era.key])
	check("the vapour raises it", thin.steam > 0.0 and thin.boiling_point(thin.steam) > thin.boiling_point(0.0))
	check("and steam rules the sky", thin.era.key == "RUNAWAY")
	# The mixed layer is part of the sea, not deeper than it.
	check("a mixed layer cannot outrun its sea", Climate.new({"mixedLayer": 100.0, "oceanDepth": 0.01}).heat_capacity == 10.0 * Climate.RHO_CW)

func drawn_water_and_air() -> void:
	var m_e := 1.0 / 332946.0487
	var r_e := 6371.0 * Physics.AU_PER_KM
	# The streams phase 1 drew must not move when new fields join them (values from that build).
	var d := ClimateInputs.draw("Pinned", 0, m_e, r_e, 1.0, 1.05, true)
	print("REALISMCHECK DRAWN %s" % d)
	check("an old stream stays where it was", absf(d.albedoBase - 0.278302165586501) < 1e-12 and absf(d.albedoIce - 0.310982827609405) < 1e-12
		and absf(d.mixedLayer - 19.323062981392461) < 1e-10)
	var co2_at := func(S: float) -> float:
		var sum := 0.0
		for i in 24: sum += log(float(ClimateInputs.draw("c%d" % i, 0, m_e, r_e, S, 1.05, true).pCO2))
		return exp(sum / 24.0)
	print("REALISMCHECK DRAWN co2 at S 1.0=%s 0.8=%s 0.5=%s" % [co2_at.call(1.0), co2_at.call(0.8), co2_at.call(0.5)])
	check("a dimmer star's ocean world holds more CO₂", co2_at.call(0.5) > co2_at.call(0.8) and co2_at.call(0.8) > 10.0 * co2_at.call(1.0))
	var liquid := 0
	var unsettled := 0
	load_worlds([{"a": sqrt(1.0 / 0.6), "spec": {"type": "planet", "name": "Outer", "seed": 1, "oceans": true, "mass": m_e, "radiusKm": 6371.0}}])
	var outer: Climate = stage.state.body_named("Outer").climate
	print("REALISMCHECK DRAWN outer S=%s T=%s co2=%s era=%s" % [outer.S, outer.T, outer.pressures.pCO2, outer.era.key])
	check("the draw's CO₂ keeps a 0.6 S⊕ ocean world liquid", outer.T > 273.0 and outer.ice < 0.5)
	for i in 64:
		var v := ClimateInputs.draw("v%d" % i, 0, m_e, r_e, 1.91, 1.05, false)
		if not ClimateInputs.input_error(v).is_empty(): unsettled += 1
		if float(v.pCO2) < 10.0: unsettled += 1
		var w := ClimateInputs.draw("w%d" % i, 0, m_e, r_e, 0.9, 1.05, true)
		if float(w.land) < 0.0 or float(w.land) > 0.7 or float(w.oceanDepth) <= 0.0 or float(w.salinity) < 5.0: unsettled += 1
		if float(w.land) == 0.0: liquid += 1
		if float(w.pN2) < 0.3 or float(w.pCO2) > 8.0: unsettled += 1
	check("thick, wet and land rows stay in their ranges", unsettled == 0)
	check("some drawn worlds have no land", liquid > 0 and liquid < 24)
	var bare := ClimateInputs.draw("n", 0, 1.66e-7, 2439.7 * Physics.AU_PER_KM, 6.67, 1.05)
	check("nothing is drawn for an airless world", bare.pCO2 == 0.0 and bare.pN2 == 0.0)
	# No preset may still state the old single number.
	for key in Presets.PRESET_ORDER:
		var preset: Dictionary = Presets.PRESETS[key]
		check("%s states no ε" % key, not preset.get("climate", {}).has("greenhouse"))

func climate() -> void:
	var mk := func(x: float, L: float) -> Body:
		var s := Body.new()
		s.name = "Sun"; s.type = "star"; s.mass = 1.0; s.luminosity = L; s.teff = 5772.0
		s.pos = DVec3.new(x, 0.0, 0.0)
		return s
	var planet := Body.new()
	planet.pos = DVec3.new()
	var earth := Climate.new({"mixedLayer": 12.0, "T0": 288.0, "albedoBase": 0.306 - 0.0, "albedoIce": 0.45})
	for i in 200: earth.step(0.05, planet, [mk.call(1.0, 1.0)])
	print("REALISMCHECK CLIMATE earth_T=%s olr=%s" % [earth.T, earth.olr(earth.T)])
	check("Earth at 1 S⊕ stays below the runaway limit", earth.steam == 0.0 and earth.olr(earth.T) < Climate.OLR_LIMIT)
	var hot := Climate.new({"mixedLayer": 12.0, "T0": 288.0, "albedoBase": 0.306, "albedoIce": 0.45})
	var star_hot: Body = mk.call(1.0, 1.5)
	for i in 400: hot.step(0.25, planet, [star_hot])
	var absorbed := (1.0 - 0.306) * hot.S * Climate.S0 / 4.0
	var expect_steam := (absorbed - Climate.OLR_LIMIT) * 100.0 * Climate.YEAR_S / (hot.water_column * Climate.L_VAPOUR)
	print("REALISMCHECK CLIMATE hot_T=%s steam=%s expected=%s era=%s" % [hot.T, hot.steam, expect_steam, hot.era.key])
	check("1.5 S⊕ runs away: the ocean boils at the latent-heat rate", near(hot.steam, expect_steam, 0.03))
	check("the surface follows the boiling curve", absf(hot.T - hot.boiling_point(hot.steam)) < 1e-6 and hot.T > 373.0)
	check("water is conserved between ocean, steam and space", absf(hot.ocean + hot.steam + hot.lost - 1.0) < 1e-12 and hot.lost > 0.0)
	check("the era says runaway greenhouse", hot.era.key == "RUNAWAY")
	star_hot.luminosity = 0.8
	for i in 4000: hot.step(0.25, planet, [star_hot])
	print("REALISMCHECK CLIMATE cooled_T=%s steam=%s" % [hot.T, hot.steam])
	check("steam rains back out when the star dims, less what escaped", hot.steam == 0.0 and absf(hot.ocean + hot.lost - 1.0) < 1e-12 and hot.T < 300.0)
	# Hydrogen escape: today's Earth loses next to nothing; at the moist-greenhouse limit
	# an ocean goes in ~4 Gyr (Kasting 1988), and the cap holds a runaway to the energy limit.
	var t_ocean := func(t: float, s: float) -> float: return earth.water_column * Climate.H_PER_KG_WATER / earth.hydrogen_escape(t, s) / Climate.YEAR_S
	check("Earth today keeps its ocean for > 10¹² yr (%s yr)" % U.expo(t_ocean.call(288.0, 1.0), 1), t_ocean.call(288.0, 1.0) > 1e12)
	check("at 340 K the ocean escapes in %s Gyr (Kasting: ~4)" % U.fixed(t_ocean.call(340.0, 1.0) / 1e9, 1), t_ocean.call(340.0, 1.0) > 2e9 and t_ocean.call(340.0, 1.0) < 8e9)
	check("a runaway escapes at the energy limit", absf(hot.hydrogen_escape(400.0, 1.5) - Climate.ESCAPE_ENERGY / Climate.PHI_EARTH * 1.5) < 1.0)
	var moist := Climate.new({"mixedLayer": 12.0, "T0": 345.0, "albedoBase": 0.306, "albedoIce": 0.45})
	check("a wet stratosphere at 345 K is a moist greenhouse", moist.classify(345.0).key == "MOIST")
	# Long enough to dry: 1.5 S⊕ for 10 Gyr in 2 Myr steps leaves no water, and with it no runaway cap.
	var gone := Climate.new({"mixedLayer": 12.0, "T0": 288.0, "albedoBase": 0.306, "albedoIce": 0.45})
	for i in 5000: gone.step(2e6, planet, [mk.call(1.0, 1.5)])
	check("an ocean in a runaway for 10 Gyr escapes entirely, and the cap goes with it", gone.ocean + gone.steam == 0.0 and absf(gone.lost - 1.0) < 1e-9 and gone.olr(400.0) > Climate.OLR_LIMIT)
	# ~265 bar by Clausius–Clapeyron at constant L, near water's 647 K critical point.
	check("whole ocean as steam boils at ~650 K", absf(earth.boiling_point(1.0) - 650.0) < 1.0)
	var dry := Climate.new({"oceans": false})
	check("a dry world has no runaway cap", dry.olr(400.0) > Climate.OLR_LIMIT)
	# Kopparapu et al. (2013): the Sun's moist and maximum greenhouse limits at 0.99 and 1.70 AU.
	check("HZ moist greenhouse at 0.99 AU for the Sun", absf(1.0 / sqrt(Climate.hz_flux("moist", 5780.0)) - 0.993) < 2e-3)
	check("HZ maximum greenhouse at 1.70 AU for the Sun", absf(1.0 / sqrt(Climate.hz_flux("maximum", 5780.0)) - 1.705) < 3e-3)
	check("HZ edges move in for a cool star", Climate.hz_flux("runaway", 3000.0) < 0.9 and Climate.hz_flux("maximum", 3000.0) < 0.25)
	earth.step(1e-3, planet, [mk.call(1.0, 1.0)])
	var hz := earth.habitable_zone()
	check("the climate reads the dominant star's zone", absf(float(hz.teff) - 5772.0) < 1e-9 and hz.inner > 1.0 and hz.outer < 0.4)

# A distant star's near-radial relative orbit has a tiny osculating periapsis; only a
# pass that fits in the interval counts. One second of each preset through the
# frame loop, as presetcheck runs it, less the presets built to merge.
func presets_survive_loading() -> void:
	stage.state.paused = false
	for key in Presets.PRESET_ORDER:
		stage.load_preset(key)
		var n: int = stage.state.bodies.size()
		for i in 60: stage.animate(1.0 / 60.0)
		if key in ["nsmerger", "binarystar", "stellar_zoo"]: continue
		check("preset %s: no body lost in its first second" % key, stage.state.bodies.size() == n)
	stage.state.paused = true

# A static observer at r sees light from infinity blueshifted by 1/√(1 − r_s/r): 1.118
# at 5 r_s; the same on a spinning hole's axis, where f = 2Mr/(r² + a²); 1 far away.
func hovering_blueshift() -> void:
	var g := LensPass.grav_shift([{"pos": Vector3(10.0, 0.0, 0.0), "rs": 2.0, "spin": 0.0}])
	check("hovering at 5 r_s the sky is blueshifted %.4f (1/√0.8 = 1.1180)" % g, absf(g - 1.0 / sqrt(0.8)) < 1e-6)
	var ga := LensPass.grav_shift([{"pos": Vector3(0.0, 10.0, 0.0), "rs": 2.0, "spin": 0.9}])
	check("on a Kerr hole's axis f = 2r/(r² + a²)", absf(ga - 1.0 / sqrt(1.0 - 20.0 / (100.0 + 0.81))) < 1e-6)
	check("far from the hole the shift vanishes", absf(LensPass.grav_shift([{"pos": Vector3(1e6, 0.0, 0.0), "rs": 2.0}]) - 1.0) < 1e-5)

# BSC5 and Gaia DR3 together: about 41 000–45 000 stars brighter than V = 8 over the
# whole sky (Allen's Astrophysical Quantities), every one with a finite colour, and the
# procedural sky handing all six of its tiers to them.
func star_catalogues() -> void:
	var counts := [0, 0]
	var colour_ok := true
	for i in 2:
		var f := FileAccess.open([BrightStars.DATA, BrightStars.DATA_FAINT][i], FileAccess.READ)
		if f == null: continue
		while f.get_position() + BrightStars.RECORD <= f.get_length():
			f.get_float(); f.get_float()
			var v := f.get_float()
			var bv := f.get_float()
			f.get_float(); f.get_float()
			if v < 8.0: counts[i] += 1
			if i == 1 and not (is_finite(bv) and bv > -0.5 and bv < 2.5): colour_ok = false
	var total: int = counts[0] + counts[1]
	check("BSC5 + Gaia DR3: %d stars brighter than V = 8 (%d from Gaia)" % [total, counts[1]], total > 38000 and total < 48000 and counts[1] > 25000)
	check("every Gaia star has a colour", colour_ok)
	check("the catalogues replace all six procedural tiers", BrightStars.catalogue_tiers() == 6)

# What the sky shader actually receives once the frame loop has run, in every sky
# material: the catalogue's tiers where it draws, and the whole procedural sky elsewhere.
# The rest of this check runs in the hangar, whose frames return before the sky.
func live_sky_tiers() -> void:
	stage.close_hangar()
	stage.set_app_mode("sandbox")
	stage.load_preset("solar")
	stage.animate(1.0 / 60.0)
	check_first_tier("solar, visible light", BrightStars.catalogue_tiers())
	stage.set_band(5)
	stage.animate(1.0 / 60.0)
	check_first_tier("solar, X-ray (no catalogue in this band)", 0)
	stage.set_band(Spectrum.VISIBLE_BAND)
	stage.animate(1.0 / 60.0)
	check_first_tier("solar, back in visible light", BrightStars.catalogue_tiers())
	stage.load_preset("vega")
	stage.animate(1.0 / 60.0)
	check_first_tier("a scene off the real galactic frame", 0)

func check_first_tier(where: String, expected: int) -> void:
	var seen := {}
	for m in stage.pipe.sky_materials: seen[m.get_shader_parameter("uFirstTier")] = true
	check("%s: the sky draws from tier %d (uFirstTier %s)" % [where, expected, seen.keys()], seen.keys() == [expected])

func _ready() -> void:
	OS.add_logger(catcher)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	for i in 2: await get_tree().process_frame
	stage._start("blank")
	stage.set_process(false)
	stage.state.paused = true
	page_thorne()
	disruption_radii()
	tidal_events()
	natal_kicks()
	secular_events()
	climate()
	composition()
	gas_column_look()
	water()
	drawn_water_and_air()
	ice_lines()
	each_world_settles()
	same_seed_same_worlds()
	stated_values_win()
	draw_ranges()
	solar_system()
	home_is_unchanged()
	home_removed()
	climates_follow_type()
	stiff_worlds_stay_finite()
	hovering_blueshift()
	star_catalogues()
	presets_survive_loading()
	live_sky_tiers()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("REALISMCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
