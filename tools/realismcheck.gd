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
	var expect_steam := (absorbed - Climate.OLR_LIMIT) * 100.0 * Climate.YEAR_S / Climate.OCEAN_COLUMN_LATENT
	print("REALISMCHECK CLIMATE hot_T=%s steam=%s expected=%s era=%s" % [hot.T, hot.steam, expect_steam, hot.era.key])
	check("1.5 S⊕ runs away: the ocean boils at the latent-heat rate", near(hot.steam, expect_steam, 0.03))
	check("the surface follows the boiling curve", absf(hot.T - Climate.boiling_point(hot.steam)) < 1e-6 and hot.T > 373.0)
	check("water is conserved between ocean, steam and space", absf(hot.ocean + hot.steam + hot.lost - 1.0) < 1e-12 and hot.lost > 0.0)
	check("the era says runaway greenhouse", hot.era.key == "RUNAWAY")
	star_hot.luminosity = 0.8
	for i in 4000: hot.step(0.25, planet, [star_hot])
	print("REALISMCHECK CLIMATE cooled_T=%s steam=%s" % [hot.T, hot.steam])
	check("steam rains back out when the star dims, less what escaped", hot.steam == 0.0 and absf(hot.ocean + hot.lost - 1.0) < 1e-12 and hot.T < 300.0)
	# Hydrogen escape: today's Earth loses next to nothing; at the moist-greenhouse limit
	# an ocean goes in ~4 Gyr (Kasting 1988), and the cap holds a runaway to the energy limit.
	var t_ocean := func(t: float, s: float) -> float: return Climate.OCEAN_H_PER_M2 / earth.hydrogen_escape(t, s) / Climate.YEAR_S
	check("Earth today keeps its ocean for > 10¹² yr (%s yr)" % U.expo(t_ocean.call(288.0, 1.0), 1), t_ocean.call(288.0, 1.0) > 1e12)
	check("at 340 K the ocean escapes in %s Gyr (Kasting: ~4)" % U.fixed(t_ocean.call(340.0, 1.0) / 1e9, 1), t_ocean.call(340.0, 1.0) > 2e9 and t_ocean.call(340.0, 1.0) < 8e9)
	check("a runaway escapes at the energy limit", absf(hot.hydrogen_escape(400.0, 1.5) - Climate.ESCAPE_ENERGY_CAP * 1.5) < 1.0)
	var moist := Climate.new({"mixedLayer": 12.0, "T0": 345.0, "albedoBase": 0.306, "albedoIce": 0.45})
	check("a wet stratosphere at 345 K is a moist greenhouse", moist.classify(345.0).key == "MOIST")
	# Long enough to dry: 1.5 S⊕ for 10 Gyr in 2 Myr steps leaves no water, and with it no runaway cap.
	var gone := Climate.new({"mixedLayer": 12.0, "T0": 288.0, "albedoBase": 0.306, "albedoIce": 0.45})
	for i in 5000: gone.step(2e6, planet, [mk.call(1.0, 1.5)])
	check("an ocean in a runaway for 10 Gyr escapes entirely, and the cap goes with it", gone.ocean + gone.steam == 0.0 and absf(gone.lost - 1.0) < 1e-9 and gone.olr(400.0) > Climate.OLR_LIMIT)
	# 270 bar by Clausius–Clapeyron at constant L, near water's 647 K critical point.
	check("whole ocean as steam boils at ~651 K", absf(Climate.boiling_point(1.0) - 651.3) < 0.5)
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
		while f.get_position() + 16 <= f.get_length():
			f.get_float(); f.get_float()
			var v := f.get_float()
			var bv := f.get_float()
			if v < 8.0: counts[i] += 1
			if i == 1 and not (is_finite(bv) and bv > -0.5 and bv < 2.5): colour_ok = false
	var total: int = counts[0] + counts[1]
	check("BSC5 + Gaia DR3: %d stars brighter than V = 8 (%d from Gaia)" % [total, counts[1]], total > 38000 and total < 48000 and counts[1] > 25000)
	check("every Gaia star has a colour", colour_ok)
	check("the catalogues replace all six procedural tiers", BrightStars.catalogue_tiers() == 6)

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
	ice_lines()
	hovering_blueshift()
	star_catalogues()
	presets_survive_loading()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("REALISMCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
