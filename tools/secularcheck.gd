extends SceneTree
# Secular terms against their sources (docs/physics/secular.md): Hut's (1981) tidal
# de/dt and da/dt, total angular momentum with the spin, adiabatic widening under a
# wind, Hurley's overflow rate with mass and momentum conserved, and the rates and
# clocks in Structure. The GDScript kernel is checked here; nbodycheck holds the
# native one to it.
# Godot --headless --path . --script res://tools/secularcheck.gd

var checks := 0
var failures := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond: failures += 1
	print("%s %s" % ["ok  " if cond else "FAIL", what])

func body(id: int, spec: Dictionary) -> Body:
	var b := Derive.new_body(id, spec)
	b.contact_au = Derive.contact_au(b, spec)
	return b

func pair(m1: float, m2: float, a: float, e: float, t1: Dictionary, t2: Dictionary) -> Array:
	var k := Presets.kepler(m1 + m2, a, e, 0.0, 0.0)
	var p := DVec3.from_array(k.pos); var v := DVec3.from_array(k.vel)
	var A := body(1, U.merged(t1, {"mass": m1, "pos": p.scaled(-m2 / (m1 + m2)).to_array(), "vel": v.scaled(-m2 / (m1 + m2)).to_array()}))
	var B := body(2, U.merged(t2, {"mass": m2, "pos": p.scaled(m1 / (m1 + m2)).to_array(), "vel": v.scaled(m1 / (m1 + m2)).to_array()}))
	for b in [A, B]:
		b.wind_mdot = 0.0; b.donor = false; b.tide_k2 = 0.0
	return [A, B]

## Osculating [a, e, n, |h|] of b about o.
func elements(b: Body, o: Body) -> Array:
	var r := DVec3.new().sub_vectors(b.pos, o.pos)
	var v := DVec3.new().sub_vectors(b.vel, o.vel)
	var mu := Physics.G * (b.mass + o.mass)
	var a := 1.0 / (2.0 / r.length() - v.length_sq() / mu)
	var h := r.cross(v).length()
	return [a, sqrt(maxf(0.0, 1.0 - h * h / (mu * a))), sqrt(mu / (a * a * a)), h]

func run(bodies: Array, years: float, h: float) -> void:
	var t := 0.0
	while t < years:
		var dt := minf(years - t, 100.0 * h)
		var r := Derive.step_physics(bodies, dt, h, 0.0)
		t += float(r.stepped)
		if float(r.stepped) <= 0.0: break

func hut_rates(kt: float, q: float, R: float, a: float, e: float, w_over_n: float) -> Array:
	var e2 := e * e
	var s := 1.0 - e2
	var f1 := 1.0 + 15.5 * e2 + 255.0 / 8.0 * e2 * e2 + 185.0 / 16.0 * pow(e2, 3.0) + 25.0 / 64.0 * pow(e2, 4.0)
	var f2 := 1.0 + 7.5 * e2 + 45.0 / 8.0 * e2 * e2 + 5.0 / 16.0 * pow(e2, 3.0)
	var f3 := 1.0 + 3.75 * e2 + 15.0 / 8.0 * e2 * e2 + 5.0 / 64.0 * pow(e2, 3.0)
	var f4 := 1.0 + 1.5 * e2 + 0.125 * e2 * e2
	var c := kt * q * (1.0 + q) * pow(R / a, 8.0)
	var dadt := -6.0 * c * a / pow(s, 7.5) * (f1 - pow(s, 1.5) * f2 * w_over_n)
	var dedt := -27.0 * c * e / pow(s, 6.5) * (f3 - 11.0 / 18.0 * pow(s, 1.5) * f4 * w_over_n)
	return [dadt, dedt]

func tides() -> void:
	# A hot Jupiter's own tide, its lag raised until it circularises in ~2000 orbits.
	var bs := pair(1.0, 1e-3, 0.05, 0.2, {"type": "star", "name": "Host"}, {"type": "gas-giant", "name": "Planet", "radiusKm": 1.0e5})
	var star: Body = bs[0]; var pl: Body = bs[1]
	var el := elements(pl, star)
	var period := TAU / float(el[2])
	pl.tide_k2 = 0.5
	# A heavier spin, so it settles over tens of orbits (as Hut's orbit average assumes)
	# rather than following θ̇ within one; it starts pseudo-synchronous, his eq. 42.
	pl.tide_iom *= 100.0
	var e2 := 0.04
	pl.spin_omega = float(el[2]) * (1.0 + 7.5 * e2 + 45.0 / 8.0 * e2 * e2 + 5.0 / 16.0 * pow(e2, 3.0)) \
		/ (pow(1.0 - e2, 1.5) * (1.0 + 3.0 * e2 + 0.375 * e2 * e2))
	var base := Structure.tidal_timescales(pl.mass, pl.radius, pl.tide_k2, 1.0, pl.tide_iom / (pl.radius * pl.radius), star.mass, 0.05)
	pl.tide_lag = float(base.circ) / (2000.0 * period)
	var I := pl.mass * pl.tide_iom
	var L0 := _orbital_l(bs) + I * pl.spin_omega
	var e0 := float(el[1]); var a0 := float(el[0])
	run(bs, 40.0 * period, period / 400.0)
	var el1 := elements(pl, star)
	var e1 := float(el1[1]); var a1 := float(el1[0])
	var L1 := _orbital_l(bs) + I * pl.spin_omega
	ok(absf(L1 - L0) <= 1e-10 * absf(L0), "orbit + spin angular momentum kept (%s relative)" % [U.expo((absf(L1 - L0) / absf(L0)), 2)])
	var em := 0.5 * (e0 + e1); var am := 0.5 * (a0 + a1)
	var kt := 0.5 * pl.tide_k2 * Physics.G * pl.mass * pl.tide_lag / pow(pl.radius, 3.0)
	var w := pl.spin_omega / sqrt(Physics.G * 1.001 / pow(am, 3.0))
	var hut := hut_rates(kt, star.mass / pl.mass, pl.radius, am, em, w)
	var dedt := (e1 - e0) / (40.0 * period)
	var dadt := (a1 - a0) / (40.0 * period)
	ok(dedt < 0.0 and absf(dedt / float(hut[1]) - 1.0) < 0.05, "de/dt %s against Hut's %s" % [U.expo(dedt, 4), U.expo(hut[1], 4)])
	ok(dadt < 0.0 and absf(dadt / float(hut[0]) - 1.0) < 0.08, "da/dt %s against Hut's %s" % [U.expo(dadt, 4), U.expo(hut[0], 4)])
	ok(absf(w - 1.242) < 0.05, "the spin stays pseudo-synchronous (Ω/n = %.3f, Hut: 1.242)" % [w])

	# Despin: a fast rotator slows toward n on the timescale tidal_timescales gives.
	bs = pair(1.0, 1e-3, 0.05, 0.0, {"type": "star", "name": "Host"}, {"type": "gas-giant", "name": "Planet", "radiusKm": 1.0e5})
	star = bs[0]; pl = bs[1]
	el = elements(pl, star)
	period = TAU / float(el[2])
	pl.tide_k2 = 0.5
	pl.spin_omega = 3.0 * float(el[2])
	base = Structure.tidal_timescales(pl.mass, pl.radius, pl.tide_k2, 1.0, pl.tide_iom / (pl.radius * pl.radius), star.mass, 0.05)
	pl.tide_lag = float(base.lock) / (50.0 * period)
	run(bs, 5.0 * period, period / 400.0)
	var n := float(elements(pl, star)[2])
	var want := 1.0 + 2.0 * exp(-0.1)
	ok(absf(pl.spin_omega / n - want) < 0.02 * want, "despin Ω/n %.4f after 0.1 lock times, want %.4f" % [pl.spin_omega / n, want])

func _orbital_l(bs: Array) -> float:
	var M := 0.0
	var com := DVec3.new(); var vcom := DVec3.new()
	for b: Body in bs:
		M += b.mass; com.add_scaled_in(b.pos, b.mass); vcom.add_scaled_in(b.vel, b.mass)
	com.scale_in(1.0 / M); vcom.scale_in(1.0 / M)
	var L := DVec3.new()
	for b: Body in bs:
		var r := DVec3.new().sub_vectors(b.pos, com); var v := DVec3.new().sub_vectors(b.vel, vcom)
		L.add_scaled_in(r.cross(v), b.mass)
	return L.length()

func winds() -> void:
	# 20% of the star blown off over a thousand orbits: a·M is an adiabatic invariant.
	var bs := pair(1.0, 3e-6, 1.0, 0.0, {"type": "star", "name": "Sun"}, {"type": "planet", "name": "World"})
	var star: Body = bs[0]; var pl: Body = bs[1]
	star.wind_mdot = 0.2 / 1000.0
	var aM0 := float(elements(pl, star)[0]) * (star.mass + pl.mass)
	run(bs, 1000.0, 1.0 / 200.0)
	var el := elements(pl, star)
	var aM1 := float(el[0]) * (star.mass + pl.mass)
	ok(absf(star.mass - 0.8) < 1e-9, "the wind took 20%% (M = %.6f)" % [star.mass])
	ok(absf(aM1 / aM0 - 1.0) < 2e-3, "a·M kept to %s as the orbit widened to %.4f AU" % [U.expo(absf(aM1 / aM0 - 1.0), 2), el[0]])
	ok(float(el[1]) < 2e-3, "the orbit stays circular (e = %s)" % [U.expo(el[1], 2)])

func overflow() -> void:
	ok(absf(Structure.roche_lobe_fraction(1.0) - 0.3789) < 1e-3, "Eggleton's lobe at q = 1 is 0.379 a (%.4f)" % [Structure.roche_lobe_fraction(1.0)])
	ok(absf(Structure.roche_lobe_fraction(0.1) - 0.2068) < 2e-3, "and 0.207 a at q = 0.1 (%.4f)" % Structure.roche_lobe_fraction(0.1))
	var donor_r := 0.6 * Physics.AU_PER_RSUN
	var sep := 0.9 * donor_r / Structure.roche_lobe_fraction(0.6)
	var bs := pair(0.6, 1.0, sep, 0.0, {"type": "star", "name": "Donor", "radiusSun": 0.6}, {"type": "white-dwarf", "name": "Dwarf"})
	var d: Body = bs[0]; var w: Body = bs[1]
	d.donor = true
	var m0 := d.mass + w.mass
	var p0 := d.vel.scaled(d.mass).add_in(w.vel.scaled(w.mass))
	var dt := 1e-6
	Physics.apply_secular(bs, dt)
	var x := log(1.0 / 0.9)
	var want := 3e-6 * 0.36 * x * x * x * dt
	var p1 := d.vel.scaled(d.mass).add_in(w.vel.scaled(w.mass))
	ok(absf(w.gained / want - 1.0) < 1e-9 and d.shed == w.gained, "overflow at R = R_L/0.9 moves Hurley's %s M☉ (%s)" % [U.expo(want, 3), U.expo(w.gained, 3)])
	ok(absf(d.mass + w.mass - m0) <= 1e-15 * m0, "mass kept")
	ok(p1.sub_in(p0).length() <= 1e-14 * d.mass * d.vel.length(), "momentum kept")

func rates() -> void:
	var sun := Structure.structure_of({"type": "star", "mass": 1.0})
	ok(float(sun.secular.windMdot) > 1.5e-14 and float(sun.secular.windMdot) < 3e-14, "the Sun's wind %s M☉/yr" % [U.expo(sun.secular.windMdot, 2)])
	var rsg := Structure.structure_of({"type": "star", "mass": 15.0, "phase": 1.8})
	ok(float(rsg.secular.windMdot) > 1e-7 and float(rsg.secular.windMdot) < 1e-4, "a 15 M☉ supergiant's Reimers wind %s M☉/yr" % [U.expo(rsg.secular.windMdot, 2)])
	var ostar := Structure.structure_of({"type": "star", "mass": 40.0, "phase": 0.3})
	ok(float(ostar.secular.windMdot) > 1e-7 and float(ostar.secular.windMdot) < 3e-5, "a 40 M☉ O star's Vink wind %s M☉/yr" % [U.expo(ostar.secular.windMdot, 2)])
	var earth := Structure.structure_of({"type": "planet", "mass": Rocketry.M_EARTH_SUN, "radiusKm": 6371.0})
	var moon := Structure.structure_of({"type": "planet", "mass": 3.694e-8, "radiusKm": 1737.4})
	ok(absf(float(moon.secular.k2) - 0.024) < 0.006, "the Moon's elastic k2 %.4f (GRAIL 0.024)" % [moon.secular.k2])
	ok(float(earth.secular.k2) > 0.3, "a uniform Earth is softer than the real, layered one (k2 %.3f; Earth's spec states 0.299)" % [earth.secular.k2])
	var wd := Structure.structure_of({"type": "white-dwarf", "mass": 1.0})
	var ign := Structure.nova_ignition_mass(1.0, float(wd.radiusAU))
	ok(ign > 3e-5 and ign < 3e-4, "nova ignition at 1 M☉: %s M☉ (Yaron et al. 2005: ~1e-4)" % [U.expo(ign, 2)])
	ok(Structure.accretion_regime(1.0, 1e-9).regime == "nova" and Structure.accretion_regime(1.0, 3e-7).regime == "steady"
		and Structure.accretion_regime(1.0, 1e-5).regime == "wind", "nova, steady and wind regimes at 1e-9, 3e-7, 1e-5 M☉/yr")
	var f := Structure.phase_after(0.5, 0.5 * 1e10, 1e10)
	ok(absf(f - 1.0) < 1e-9, "half a main-sequence lifetime takes the mid-MS Sun to TAMS (f = %.6f)" % [f])
	var g := Structure.phase_after(1.0, 0.22 * 1e10, 1e10)
	ok(absf(g - 1.45) < 1e-9, "and 2.2 Gyr more to the RGB tip (f = %.6f)" % [g])

func _init() -> void:
	Physics.secular = true
	# 1PN conserves its own angular momentum, not the Newtonian one summed here.
	Physics.post_newtonian = false
	tides()
	winds()
	overflow()
	rates()
	print("SECULARCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
