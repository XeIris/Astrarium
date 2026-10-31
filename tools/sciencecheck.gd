extends SceneTree

# Synthetic and frozen-state instrument checks, plus live numerical convergence.
# Godot --headless --path . --script res://tools/sciencecheck.gd
# Add -- compatibility=web to strictly compare obsolete live trajectories too;
# corrected force/contact models intentionally differ from that frozen run.

var fails := 0
var rows := 0

func check(name: String, ok: bool, value = null) -> void:
	rows += 1
	if not ok: fails += 1
	print("%s %s%s" % ["ok  " if ok else "FAIL", name, "" if value == null else "  (%s)" % str(value)])

static func rel_err(a: float, b: float) -> float:
	if a == b: return 0.0
	return absf(a - b) / maxf(maxf(absf(a), absf(b)), 1e-300)

func body(name: String, radius: float, pos: Array, lum = 0.0) -> Body:
	var b := Body.new()
	b.name = name; b.radius = radius; b.luminosity = lum; b.alive = true
	b.pos = DVec3.new(pos[0], pos[1], pos[2]); b.vel = DVec3.new()
	return b

func from_fixture(arr: Array) -> Array:
	var out: Array = []
	for d in arr:
		var b := Body.new()
		# JSON drops what JS left undefined (a hole has no `radius`), and the
		# Body defaults are the same zeros the JS `||` fallbacks read.
		b.name = d.name; b.type = d.type; b.mass = d.mass
		b.radius = float(U.nz(d.get("radius"), 0.0)); b.rs = float(U.nz(d.get("rs"), 0.0))
		b.contact_au = float(U.nz(d.get("contactAU"), 0.0)); b.luminosity = d.get("luminosity"); b.alive = d.get("alive", true)
		b.pos = DVec3.new(d.pos[0], d.pos[1], d.pos[2]); b.vel = DVec3.new(d.vel[0], d.vel[1], d.vel[2])
		out.append(b)
	return out

func build(key: String) -> Array:
	var p: Dictionary = Presets.PRESETS[key]
	var out := []
	var id := 1
	for spec in p.build.call():
		var b := Derive.new_body(id, spec); id += 1
		b.contact_au = Derive.contact_au(b, spec)
		out.append(b)
	return out

func load_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f else null

func sample_live(substeps: int) -> Dictionary:
	var bodies := build("edu_transit")
	var deepest := 0.0
	var lo := INF
	var hi := -INF
	var worst_rv := 0.0
	var peak: Array = []
	for i in 5000:
		for step in substeps: Physics.integrate(bodies, 1e-5 / substeps)
		var m := LightCurve.measure(bodies, DVec3.new(0.0, 0.0, 1.0))
		var depth: float = 1.0 - m.rel
		if depth > deepest:
			deepest = depth
			peak.clear()
			for b: Body in bodies:
				peak.append(body(b.name, b.radius, b.pos.to_array(), b.luminosity))
		lo = minf(lo, m.rv)
		hi = maxf(hi, m.rv)
		# Independent SI projection along +z, positive for recession.
		var expected: float = -bodies[0].vel.z * 149597870700.0 / 31557600.0
		worst_rv = maxf(worst_rv, absf(m.rv - expected))
	return {"depth": deepest, "K": (hi - lo) / 2.0, "rv_error": worst_rv, "peak": peak}

func transit_quadrature(bodies: Array) -> float:
	var star: Body = bodies[0]
	var blocked := 0.0
	# Integrate in polar coordinates over each smaller occulter, independently of
	# the instrument's golden-angle sample pattern; the live peak has no overlaps.
	for i in range(1, bodies.size()):
		var planet: Body = bodies[i]
		var dx := planet.pos.x - star.pos.x
		var dy := planet.pos.y - star.pos.y
		if planet.pos.z <= star.pos.z or sqrt(dx * dx + dy * dy) >= star.radius + planet.radius: continue
		var intensity := 0.0
		for ring in 64:
			var r := planet.radius * sqrt((ring + 0.5) / 64.0)
			for angle in 256:
				var theta := TAU * (angle + 0.5) / 256.0
				var x := dx + r * cos(theta)
				var y := dy + r * sin(theta)
				var q := (x * x + y * y) / (star.radius * star.radius)
				if q < 1.0: intensity += 0.4 + 0.6 * sqrt(1.0 - q)
		blocked += planet.radius * planet.radius / (star.radius * star.radius) * intensity / (64.0 * 256.0 * 0.8)
	return blocked

func _init() -> void:
	var strict_compatibility := OS.get_cmdline_user_args().has("compatibility=web")
	# ---- 1. synthetic
	var star := body("star", 1.0, [0, 0, 0], 1.0)
	var p := body("planet", 0.1, [0, 0, 2])
	var u := DVec3.new(0, 0, 1)
	var m := LightCurve.measure([star, p], u)
	check("central limb-darkened transit", absf((1.0 - m.rel) - 0.012481) < 0.00001, 1.0 - m.rel)
	check("face-on has no transit", LightCurve.measure([star, p], DVec3.new(0, 1, 0)).rel == 1.0)
	var twin := body("twin", 0.1, [0, 0, 2])
	check("overlapping silhouettes counted once", absf(LightCurve.measure([star, p, twin], u).rel - m.rel) < 1e-10)
	check("large occulter total eclipse", LightCurve.measure([star, body("large", 100.0, [0, 0, 2])], u).rel == 0.0)
	check("luminous companion eclipse", LightCurve.measure([star, body("companion", 2.0, [0, 0, 2], 0.5)], u).rel == 1.0 / 3.0)
	var bh := build("bhmerger")
	var pair = GWDetector.find_binary(bh)
	var h = GWDetector.strain_of(pair)
	var h2 = GWDetector.strain_of(pair, {"distMpc": 820.0})
	check("GW amplitude scales as inverse distance", absf(h.h0 / h2.h0 - 2.0) < 1e-12)
	star.type = "star"; p.type = "planet"
	check("GW ignores noncompact objects", GWDetector.find_binary([star, p]) == null)
	# Independently evaluated SI circular-quadrupole values at 410 Mpc from IAU GM☉; see compact-dynamics.md.
	for golden in [["bhmerger", 0.45, 1.6926054461555222e-6, 1.0691175614746418e-26],
		["nsmerger", 0.35, 5.12147167838531e-7, 2.5773369785549405e-29]]:
		var bodies := build(golden[0])
		var pr = GWDetector.find_binary(bodies)
		var reading: Dictionary = GWDetector.strain_of(pr)
		check("%s physical separation" % golden[0], rel_err(reading.rAU, golden[1]) < 1e-12)
		check("%s circular frequency SI golden" % golden[0], rel_err(reading.fGW, golden[2]) < 1e-12)
		check("%s quadrupole amplitude SI golden" % golden[0], rel_err(reading.h0, golden[3]) < 1e-12)
		for b: Body in bodies:
			b.radius *= 100.0; b.contact_au *= 200.0; b.rs *= 300.0; b.radius_scene = 999.0
		var resized: Dictionary = GWDetector.strain_of(pr)
		check("%s strain independent of contact/render sizes" % golden[0], resized == reading)
		pr.b.pos = pr.a.pos.add(pr.b.pos.sub(pr.a.pos).scaled(2.0))
		var wider: Dictionary = GWDetector.strain_of(pr)
		check("%s frequency/amplitude separation scaling" % golden[0], rel_err(wider.fGW / reading.fGW, 1.0 / sqrt(8.0)) < 1e-12 and rel_err(wider.h0 / reading.h0, 0.5) < 1e-12)

	# ---- 2. fixture replay
	var fx = load_json("res://tools/fixtures/course/instruments.json")
	if fx == null:
		check("fixture present", false)
	else:
		for key in ["edu_transit", "alphacen", "sirius"]:
			var bodies := from_fixture(fx[key].bodies)
			var worst := 0.0
			var ev_ok := true
			for r in fx[key].rows:
				var uu := DVec3.new(r.u[0], r.u[1], r.u[2])
				var g := LightCurve.measure(bodies, uu)
				worst = maxf(worst, rel_err(g.rel, r.rel))
				worst = maxf(worst, rel_err(g.flux, r.flux))
				worst = maxf(worst, absf(g.rv - r.rv) / maxf(absf(r.rv), 1.0))
				if g.events.size() != int(r.events): ev_ok = false
			check("photometer replay %s (%d sight lines): worst rel err" % [key, fx[key].rows.size()], worst < 1e-9 and ev_ok, worst)
		for key in ["bhmerger", "nsmerger"]:
			var bodies := from_fixture(fx[key].bodies)
			var pr = GWDetector.find_binary(bodies)
			var same_pair: bool = pr != null and [pr.a.name, pr.b.name] == fx[key].pair
			var worst := 0.0
			for pair_case in [["s410", {}], ["s40i", {"distMpc": 40.0, "incl": 0.5}]]:
				var want: Dictionary = fx[key][pair_case[0]]
				var got: Dictionary = GWDetector.strain_of(pr, pair_case[1])
				for k in ["Mc", "rAU", "rSchwarz", "omega", "fGW", "h0", "hPlus", "hCross"]:
					worst = maxf(worst, rel_err(float(got[k]), float(want[k])))
				if bool(got.inBand) != bool(want.inBand): worst = INF
			check("GW frozen pair selection %s" % key, same_pair)
			print("SCIENCECHECK COMPATIBILITY GW %s separation_mapping_rel=%s strict=%s" % [key, worst, strict_compatibility])
			if strict_compatibility:
				check("GW replay %s: obsolete contact-scaled strain" % key, worst < 1e-10, worst)

	var coarse := sample_live(1)
	var medium := sample_live(2)
	var fine := sample_live(4)
	check("live hot Jupiter transit depth in (0.019, 0.022)", coarse.depth > 0.019 and coarse.depth < 0.022, coarse.depth)
	check("live hot Jupiter RV amplitude in (145, 160)", coarse.K > 145.0 and coarse.K < 160.0, coarse.K)
	check("live radial velocity matches SI projection", coarse.rv_error < 1e-10, coarse.rv_error)
	var oracle := transit_quadrature(fine.peak)
	check("live transit peak agrees with independent quadrature", rel_err(fine.depth, oracle) < 5e-4, rel_err(fine.depth, oracle))
	for key in ["depth", "K"]:
		var coarse_gap := absf(float(coarse[key]) - float(medium[key]))
		var fine_gap := absf(float(medium[key]) - float(fine[key]))
		check("live %s converges under timestep halving" % key, fine_gap <= 0.5 * coarse_gap + 1e-12 and rel_err(float(medium[key]), float(fine[key])) < 1e-4, {"coarse_gap": coarse_gap, "fine_gap": fine_gap})
	var sci = load_json("res://tools/fixtures/course/science.json")
	var web_depth := -1.0
	var web_k := -1.0
	if sci:
		for r in sci.rows:
			if r.name == "live hot Jupiter transit depth": web_depth = float(r.value)
			if r.name == "live hot Jupiter RV amplitude": web_k = float(r.value)
	check("frozen live trajectory fixture present", web_depth > 0.0 and web_k > 0.0)
	if web_depth > 0.0 and web_k > 0.0:
		var depth_difference := rel_err(coarse.depth, web_depth)
		var rv_difference := rel_err(coarse.K, web_k)
		print("SCIENCECHECK COMPATIBILITY web depth_rel=%s K_rel=%s strict=%s" % [depth_difference, rv_difference, strict_compatibility])
		if strict_compatibility:
			check("depth matches the frozen web trajectory", depth_difference < 1e-6, depth_difference)
			check("K matches the frozen web trajectory", rv_difference < 1e-6, rv_difference)

	# ---- 4. the HR diagram's main sequence is structure_of, and passes the Sun
	var hr := HRDiagram.create_hr_diagram({})
	var near_sun := false
	for q in hr.MS:
		if absf(q.m - 1.0) < 0.03 and absf(q.teff - 5772.0) < 150.0 and absf(q.L - 1.0) < 0.1: near_sun = true
	check("HR main sequence sampled from structure_of passes the Sun (%d samples)" % hr.MS.size(), near_sun)

	# ---- 5. reference atmospheres, stellar data and remnants against their sources
	var earth: Dictionary = Rocketry.ATMOSPHERES.Earth
	# US Standard Atmosphere 1976, geometric altitude: ρ kg/m³, T K.
	for row in [[11e3, 0.3639, 216.77], [50e3, 1.027e-3, 270.65], [80e3, 1.846e-5, 198.64],
			[100e3, 5.604e-7, 195.08], [120e3, 2.222e-8, 360.0], [400e3, 2.803e-12, 995.83]]:
		check("US76 density at %d km" % int(row[0] / 1000.0), rel_err(Rocketry.density(earth, row[0]), row[1]) < 0.012, Rocketry.density(earth, row[0]))
		check("US76 temperature at %d km" % int(row[0] / 1000.0), absf(Rocketry.temperature(earth, row[0]) - row[2]) < 1.0, Rocketry.temperature(earth, row[0]))
	check("US76 sound speed at 50 km is 329.8 m/s", absf(Rocketry.speed_of_sound(earth, 50e3) - 329.8) < 0.5)
	check("thin air above the sensible top", Rocketry.density(earth, 300e3) > 0.0 and Rocketry.density(earth, 1001e3) == 0.0)
	var venus := Rocketry.flight_env(Derive.new_body(0, {"type": "planet", "name": "Venus", "mass": 1.0 / 408523.719, "radiusKm": 6051.8})).atm as Dictionary
	# VIRA (Seiff et al. 1985): 1.066 bar at 350.5 K is 1.589 kg/m³ of CO₂ at 50 km.
	check("VIRA density at 50 km in Venus's own gravity", rel_err(Rocketry.density(venus, 50e3), 1.589) < 0.03, Rocketry.density(venus, 50e3))
	check("Venus turns once in its 243-day sidereal day", absf(absf(float(Rocketry.SURFACES.Venus.day)) / 86400.0 - 243.0226) < 1e-3)
	for row in [[0.1, 6.0e12], [1.0, 1.0e10], [20.0, 8.1e6], [120.0, 2.8e6]]:
		var t := Structure.main_sequence_lifetime(row[0], Structure.base_luminosity(row[0], 0.014))
		check("main-sequence lifetime of %s M☉" % row[0], rel_err(t, row[1]) < 1e-9, t)
	check("Eddington luminosity for X = 0.7", rel_err(Structure.eddington_luminosity(1.0), 4.0 * PI * Rocketry.GM_SUN * Rocketry.C_MS / 0.034 / Structure.L_SUN) < 0.002)
	check("Cummings IFMR: 8 M☉ leaves 1.33 M☉", absf(Structure.white_dwarf_final_mass(8.0) - 1.327) < 0.002)
	check("0.6 M☉ white dwarf near 0.0125 R☉", absf(Structure.white_dwarf_radius_sun(0.6) - 0.0125) < 0.0003, Structure.white_dwarf_radius_sun(0.6))
	check("2.08 M☉ neutron star inside NICER's 12.4 +1.3/−1.0 km", absf(Structure.neutron_radius_km(2.08) - 12.4) < 1.0, Structure.neutron_radius_km(2.08))
	check("equal-mass merger radiates 4.8% and spins to 0.686", absf(Physics.merger_radiated_fraction(0.25) - 0.0484) < 5e-4 and absf(Physics.merger_spin(0.25) - 0.686) < 2e-3)
	check("equal-mass merger has no recoil", Physics.merger_kick_kms(0.25) == 0.0)
	var sun_c := Stellar.blackbody_color(5772.0)
	var d65 := Stellar.blackbody_color(6500.0)
	check("the Sun is a faint warm white", sun_c.r == 1.0 and sun_c.g > 0.85 and sun_c.b > 0.78 and sun_c.b < sun_c.g)
	check("6500 K is near white", minf(d65.g, d65.b) > 0.93)

	check("200 M☉ at solar Z ends as a black hole, not a pair-instability SN", Structure.end_state_of(200.0, 0.014).type == "bh")
	check("200 M☉ at Z☉/20 is pair-unstable", Structure.end_state_of(200.0, 0.0007).type == "none")
	var p_a := TAU / Stellar.rotation_rate(2.0) * 365.25
	check("a 2 M☉ star above the Kraft break turns in about a day (%.2f d)" % p_a, p_a > 0.3 and p_a < 1.5)
	check("the Sun keeps its 25-day rotation", absf(TAU / Stellar.rotation_rate(1.0) * 365.25 - 25.0) < 0.5)
	var tip := Structure.structure_of({"type": "star", "mass": 1.0, "phase": 1.45})
	check("the Sun's RGB tip near 160 R☉ and 2500 L☉", tip.radiusSun > 120.0 and tip.radiusSun < 200.0 and tip.luminosity > 1500.0 and tip.luminosity < 3500.0)
	# Minimal cooling, iron envelope (Yakovlev & Pethick 2004, fig. 2): log Teff∞
	# ≈ 6.1 at 1e3 yr, 5.9–6.0 at 1e5 yr, then the photon era drops it steeply.
	var ns_r := Structure.neutron_radius_km(1.4)
	var cool_log := func(age: float) -> float: return log(float(Structure.neutron_cooling(1.4, ns_r, age).teffInf)) / log(10.0)
	check("a 1 kyr neutron star near log Teff∞ 6.1 (%.2f)" % cool_log.call(1e3), absf(cool_log.call(1e3) - 6.1) < 0.12)
	check("a 100 kyr neutron star near log Teff∞ 5.9 (%.2f)" % cool_log.call(1e5), absf(cool_log.call(1e5) - 5.9) < 0.15)
	check("a 1 Myr neutron star has entered the photon era (%.2f)" % cool_log.call(1e6), cool_log.call(1e6) < 5.6 and cool_log.call(1e6) > 5.0)
	var young := Structure.neutron_cooling(1.4, ns_r, 3.0)
	var old := Structure.neutron_cooling(1.4, ns_r, 1e4)
	check("a young crust is hotter than the core; a relaxed one is isothermal", young.crustT > young.coreT * 1.5 and absf(old.crustT / old.coreT - 1.0) < 1e-6)
	var ns_layers: Array = Structure.structure_of({"type": "neutron", "mass": 1.4, "ageYr": 1e4}).layers
	check("a relaxed neutron star's crust is no hotter than its core", float(ns_layers[2].T) <= float(ns_layers[0].T) and float(ns_layers[4].T) < float(ns_layers[3].T))
	# Peters–Mathews power on a circle is the circular quadrupole formula.
	var gw_a := Body.new(); var gw_b := Body.new()
	for gw in [gw_a, gw_b]:
		gw.type = "bh"; gw.mass = 10.0; gw.emits_gw = true; gw.alive = true; gw.rs = Physics.schwarzschild(10.0)
	var sep := 1e-4                        # inside the 400-contact-radius drag window
	var vc := Physics.circular_speed(20.0, sep)
	gw_a.pos = DVec3.new(-sep / 2.0, 0.0, 0.0); gw_b.pos = DVec3.new(sep / 2.0, 0.0, 0.0)
	gw_a.vel = DVec3.new(0.0, 0.0, -vc / 2.0); gw_b.vel = DVec3.new(0.0, 0.0, vc / 2.0)
	var e_before := 0.5 * 10.0 * (gw_a.vel.length_sq() + gw_b.vel.length_sq())
	var tiny_dt := 1e-12
	Physics.apply_gw_reaction([gw_a, gw_b], tiny_dt, 1.0)
	var e_after := 0.5 * 10.0 * (gw_a.vel.length_sq() + gw_b.vel.length_sq())
	var p_circ := 32.0 / 5.0 * pow(Physics.G, 4.0) * 1e4 * 20.0 / (pow(Physics.C, 5.0) * pow(sep, 5.0))
	check("instantaneous GW power is the circular value on a circle", rel_err((e_before - e_after) / tiny_dt, p_circ) < 1e-3, [(e_before - e_after) / tiny_dt, p_circ])

	print("sciencecheck: %d checks, %d failed" % [rows, fails])
	quit(1 if fails > 0 else 0)
