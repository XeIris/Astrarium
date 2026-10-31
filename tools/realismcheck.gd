extends Node

# Section 6 additions of the 2026-10-30 fidelity review against independent numbers:
# the Page–Thorne disc, tidal disruption, natal kicks, and the runaway greenhouse and
# habitable zone. Events run through the stage's structural-limit path.
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
			structural_pass()
			if body("Victim") == null: break
		var label := "coarse" if coarse else "fine"
		print("REALISMCHECK TDE %s closest_rsun=%s hole_mass=%s" % [label, closest / sun, hole.mass])
		check("%s pass: the star is disrupted" % label, body("Victim") == null)
		check("%s pass: half the star is accreted" % label, absf(hole.mass - (M + 0.5)) < 1e-9)
		var p1 := momentum(stage.state.bodies)
		check("%s pass: the hole carries its momentum and the bound half's" % label,
			p1.distance_to(p0.clone().add_scaled_in(star_v, -0.5)) < 1e-12 * star_v.length())
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
	check("water is conserved between ocean and steam", absf(hot.ocean + hot.steam - 1.0) < 1e-12)
	check("the era says runaway greenhouse", hot.era.key == "RUNAWAY")
	star_hot.luminosity = 0.8
	for i in 4000: hot.step(0.25, planet, [star_hot])
	print("REALISMCHECK CLIMATE cooled_T=%s steam=%s" % [hot.T, hot.steam])
	check("steam rains back out when the star dims", hot.steam == 0.0 and absf(hot.ocean - 1.0) < 1e-12 and hot.T < 300.0)
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
	climate()
	presets_survive_loading()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("REALISMCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
