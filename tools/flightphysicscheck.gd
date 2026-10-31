extends SceneTree

# Gravity-field, aerothermal, wind and planner models of the flight frame, each
# against an analytic expectation or a finer integration.
# Godot --headless --path . --script res://tools/flightphysicscheck.gd

var fails := 0

func check(name: String, ok: bool, value = null) -> void:
	if not ok: fails += 1
	print("%s %s%s" % ["ok  " if ok else "FAIL", name, "" if value == null else "  (%s)" % str(value)])

func body(name: String, mass_sun: float, radius_km: float, pos_m: DVec3 = DVec3.new(), vel_ms: DVec3 = DVec3.new()) -> Body:
	var b := Body.new()
	b.name = name; b.mass = mass_sun; b.radius = radius_km * Physics.AU_PER_KM; b.alive = true
	b.pos = pos_m.scaled(1.0 / Rocketry.AU_M)
	b.vel = vel_ms.scaled(Rocketry.YR_S / Rocketry.AU_M)
	return b

func vessel_at(parent: Body, bodies: Array) -> Vessel:
	return Vessel.new({ "vehicle": Vehicles.VEHICLES.ioncruiser, "parent": parent, "bodies": bodies, "payload": 0.0 })

## Right ascension of the ascending node about the flight pole (−Y), rad.
static func node_of(r: DVec3, v: DVec3) -> float:
	var h := DVec3.new().cross_vectors(r, v)
	return atan2(h.x, -h.z)

func _init() -> void:
	# Zonal acceleration is minus the gradient of the zonal potential.
	for name in ["Earth", "Mars", "Moon"]:
		var z: Dictionary = Rocketry.ZONAL[name]
		var mu := 3.986e14 if name == "Earth" else (4.283e13 if name == "Mars" else 4.903e12)
		var worst := 0.0
		for p in [DVec3.new(7.0e6, -2.0e6, 1.0e6), DVec3.new(1.0e6, 6.9e6, -3.0e5), DVec3.new(-4.0e6, -4.5e6, 3.0e6)]:
			var pp: DVec3 = p.scaled(float(z.R) / 6.378e6 * 1.1)
			var a := Rocketry.zonal_accel(z, mu, pp, DVec3.new())
			var e := 1.0
			var g := DVec3.new(
				-(Rocketry.zonal_potential(z, mu, pp.clone().add_in(DVec3.new(e, 0, 0))) - Rocketry.zonal_potential(z, mu, pp.clone().sub_in(DVec3.new(e, 0, 0)))) / (2.0 * e),
				-(Rocketry.zonal_potential(z, mu, pp.clone().add_in(DVec3.new(0, e, 0))) - Rocketry.zonal_potential(z, mu, pp.clone().sub_in(DVec3.new(0, e, 0)))) / (2.0 * e),
				-(Rocketry.zonal_potential(z, mu, pp.clone().add_in(DVec3.new(0, 0, e))) - Rocketry.zonal_potential(z, mu, pp.clone().sub_in(DVec3.new(0, 0, e)))) / (2.0 * e))
			worst = maxf(worst, g.sub_in(a).length() / a.length())
		check("%s zonal acceleration is −∇Φ" % name, worst < 1e-5, worst)

	# ISS nodal regression: dΩ/dt = −3/2·n·J2·(R/a)²·cos i ≈ −5°/day.
	var earth := body("Earth", Rocketry.M_EARTH_SUN, 6371.0)
	for rails in [false, true]:
		var v := vessel_at(earth, [earth])
		v.place_in_orbit(400000.0, 51.6, 0.0)
		var a0 := v.r.length()
		var n0 := node_of(v.r, v.v)
		for i in 1440: v.step(60.0, { "rails": rails })
		var dnode := wrapf(node_of(v.r, v.v) - n0, -PI, PI) * 180.0 / PI
		var mu: float = v.env.mu
		var want := -1.5 * sqrt(mu / pow(a0, 3.0)) * 1.08262668e-3 * pow(6378137.0 / a0, 2.0) * cos(deg_to_rad(51.6)) * 86400.0 * 180.0 / PI
		check("ISS node regresses %.3f°/day (J2 alone: %.3f) %s" % [dnode, want, "on rails" if rails else "under RK4"],
			absf(dnode / want - 1.0) < 0.03 and dnode < -4.8 and dnode > -5.3)

	# Stage interpolation: a coast past a moving Moon, at the 60 s substep, against 1 s.
	var moon_r := 384400e3
	var mu_em := Rocketry.GM_SUN * Rocketry.M_EARTH_SUN * (1.0 + 0.0123)
	var w := sqrt(mu_em / pow(moon_r, 3.0))
	var finals := []
	for mode in ["fine", "interp", "end"]:
		var e2 := body("Earth", Rocketry.M_EARTH_SUN, 6371.0)
		var m2 := body("Moon", Rocketry.M_EARTH_SUN * 0.0123, 1737.4)
		var t := [0.0]
		var place := func() -> void:
			var th: float = w * t[0]
			m2.pos = DVec3.new(moon_r * cos(th), 0.0, moon_r * sin(th)).scale_in(1.0 / Rocketry.AU_M)
			m2.vel = DVec3.new(-moon_r * w * sin(th), 0.0, moon_r * w * cos(th)).scale_in(Rocketry.YR_S / Rocketry.AU_M)
		place.call()
		var v := vessel_at(e2, [e2, m2])
		v.place_in_orbit(300000e3, 0.0, 0.25)
		v.v.scale_in(0.9)
		v.interpolate_stages = mode != "end"
		var adv := func(sec: float) -> float:
			t[0] += sec
			place.call()
			return sec
		var frame := 1.0 if mode == "fine" else 600.0
		var total := 0.0
		while total < 2.0 * 86400.0 - 1e-6:
			total += v.step(frame, { "advance_world": adv })
		finals.append(v.r.clone())
	var err_i: float = (finals[1] as DVec3).clone().sub_in(finals[0]).length()
	var err_e: float = (finals[2] as DVec3).clone().sub_in(finals[0]).length()
	check("RK4 stages that see the Moon move cut the coast error (%s m vs %s m)" % [String.num_scientific(err_i), String.num_scientific(err_e)], err_i < 0.3 * err_e)

	# Radiative heating: none below the tables, rising steeply, Stardust-like at 12.6 km/s.
	var air = Rocketry.flight_env(earth).atm
	check("no shock-layer radiation at orbital speed", Rocketry.radiative_heat_flux(1e-4, 7800.0, 1.0, air) == 0.0)
	var q_sd := Rocketry.radiative_heat_flux(1e-4, 12600.0, 0.23, air) / 1e4
	check("Stardust-like entry radiates 100–300 W/cm² (%.0f)" % q_sd, q_sd > 100.0 and q_sd < 300.0)
	check("radiation grows with speed", Rocketry.radiative_heat_flux(3e-4, 11000.0, 2.0, air) > Rocketry.radiative_heat_flux(3e-4, 10000.0, 2.0, air))
	var mars := body("Mars", 3.2271e-7, 3389.5)
	var co2 = Rocketry.flight_env(mars).atm
	check("Mars entry at 7.5 km/s radiates in CO₂", Rocketry.radiative_heat_flux(3e-4, 7500.0, 1.0, co2) > 0.0)
	check("Mars and Venus use the CO₂ Sutton–Graves constant", Rocketry.heat_flux(1e-4, 6000.0, 1.0, co2) > Rocketry.heat_flux(1e-4, 6000.0, 1.0, air) * 1.08)

	# Wind: the jet at 12 km near 35°, easterly trades at the equator, still air aloft.
	check("a 35 m/s westerly jet at 12 km, 35° N", absf(Rocketry.zonal_wind(air, 12000.0, deg_to_rad(35.0)) - 35.0) < 1.0)
	check("easterly trade winds at the equator", Rocketry.zonal_wind(air, 500.0, 0.0) < -4.0)
	check("no wind at 60 km", absf(Rocketry.zonal_wind(air, 60000.0, deg_to_rad(35.0))) < 0.5)
	Rocketry.winds_enabled = true
	var vw := vessel_at(earth, [earth])
	vw.place_on_pad(35.0, 0.0)
	vw.r.scale_in((6371e3 + 12000.0) / vw.r.length())
	var still := DVec3.new().set_v(0.0, -float(vw.env.rotRate), 0.0).cross_vectors(DVec3.new().set_v(0.0, -float(vw.env.rotRate), 0.0), vw.r)
	var rel := vw.airspeed(vw.r, still, DVec3.new())
	check("the airspeed of a body turning with the ground is the jet", absf(rel.length() - 35.0) < 1.0, rel.length())
	check("the ground velocity of that body is zero: wheels and sites see no wind", vw.ground_velocity(vw.r, still, DVec3.new()).length() < 1e-9)
	Rocketry.winds_enabled = false
	check("winds are off unless asked for", vw.airspeed(vw.r, still, DVec3.new()).length() < 1e-6)

	# The coast's flown extremes: a conic's apsides without zonal terms; under J2 the
	# peak of a coast from 112 km moves by km (the cutoff's correction).
	var ve := vessel_at(earth, [earth])
	ve.place_in_orbit(112000.0, 28.5, 0.0)
	ve.v.scale_in(1.0062)
	var mu_e: float = ve.env.mu
	var el0 := Orbit.elements(ve.r, ve.v, mu_e)
	var flat := Orbit.zonal_extremes(ve.r, ve.v, mu_e, null, float(el0.period), false, 5.0)
	check("without zonal terms the flown extremes are the conic's apsides (%.1f, %.1f m)" % [flat[0] - float(el0.rp), flat[1] - float(el0.ra)],
		absf(flat[0] - float(el0.rp)) < 5.0 and absf(flat[1] - float(el0.ra)) < 5.0)
	var peak := Orbit.zonal_extremes(ve.r, ve.v, mu_e, ve.env.zonal, float(el0.period), true, 5.0)
	var el_j := Orbit.elements(ve.r, ve.v, Rocketry.effective_mu(ve.env.zonal, mu_e, ve.r, ve.v))
	check("under J2 the coast's peak differs from the averaged conic's apoapsis by km (%.0f m)" % (peak[1] - float(el_j.ra)),
		absf(peak[1] - float(el_j.ra)) > 500.0 and absf(peak[1] - float(el_j.ra)) < 15000.0)

	# The sky's multiple scattering: positive, bluer than red at the ground by day, and a
	# gain below single scattering's 15 so the noon zenith keeps its calibration.
	var psi := func(j: int, i: int, c: int) -> float: return float(SkyMS.PSI[(j * SkyMS.N_MU + i) * 3 + c])
	check("multiple scattering lights the ground-level noon sky, bluer than red",
		psi.call(0, SkyMS.N_MU - 1, 1) > 0.0 and psi.call(0, SkyMS.N_MU - 1, 2) > psi.call(0, SkyMS.N_MU - 1, 0))
	check("the sky table is %d × %d RGB" % [SkyMS.N_MU, SkyMS.N_H], SkyMS.PSI.size() == SkyMS.N_MU * SkyMS.N_H * 3 and SkyMS.GAIN > 5.0 and SkyMS.GAIN < 15.0)

	# A stage's Cd table replaces the generic curve.
	var table := { "source": "test", "rows": [[0.0, 0.2], [1.0, 0.6], [3.0, 0.3]] }
	check("a Cd table interpolates by Mach", absf(Rocketry.drag_coefficient(2.0, table) - 0.45) < 1e-12 and Rocketry.drag_coefficient(9.0, table) == 0.3)

	# Porkchop against Hohmann on circular coplanar orbits.
	var mu_s := Rocketry.GM_SUN
	var r1 := Rocketry.AU_M
	var r2 := 1.524 * Rocketry.AU_M
	var h := Orbit.hohmann(mu_s, r1, r2)
	var p_e := DVec3.new(r1, 0.0, 0.0)
	var v_e := DVec3.new(0.0, 0.0, sqrt(mu_s / r1))
	var th0 := deg_to_rad(10.0)
	var p_m := DVec3.new(r2 * cos(th0), 0.0, r2 * sin(th0))
	var v_m := DVec3.new(-sin(th0), 0.0, cos(th0)).scale_in(sqrt(mu_s / r2))
	var deps := []
	for i in 120: deps.append(float(h.synodic) * 1.1 * i / 119.0)
	var tofs := []
	for j in 21: tofs.append(float(h.tof) * lerpf(0.8, 1.2, j / 20.0))
	var pc := Orbit.porkchop(p_e, v_e, mu_s, p_m, v_m, mu_s, mu_s, deps, tofs, func(a: float, b: float) -> float: return a + b)
	var wait := Mission.window_wait(th0, h.phase, sqrt(mu_s / pow(r1, 3.0)), sqrt(mu_s / pow(r2, 3.0)))
	check("porkchop's best Δv is within 3%% of Hohmann's (%.0f vs %.0f m/s)" % [pc.best.cost, h.dv], absf(pc.best.cost / h.dv - 1.0) < 0.03)
	check("porkchop's window opens with Hohmann's (%.1f vs %.1f d)" % [pc.best.t_dep / 86400.0, wait / 86400.0], absf(pc.best.t_dep - wait) < 0.03 * float(h.synodic))
	# Mars's real eccentricity moves the window and its cost away from the circular estimate.
	var e_m := 0.0934
	var rp := 1.5237 * Rocketry.AU_M * (1.0 - e_m)
	var p_me := DVec3.new(rp * cos(th0), 0.0, rp * sin(th0))
	var v_me := DVec3.new(-sin(th0), 0.0, cos(th0)).scale_in(sqrt(mu_s * (1.0 + e_m) / rp))
	var pce := Orbit.porkchop(p_e, v_e, mu_s, p_me, v_me, mu_s, mu_s, deps, tofs, func(a: float, b: float) -> float: return a + b)
	check("an eccentric Mars moves the best window by days (%.1f d)" % ((pce.best.t_dep - pc.best.t_dep) / 86400.0), absf(pce.best.t_dep - pc.best.t_dep) > 2.0 * 86400.0)

	print("flightphysicscheck: %s" % ("PASS" if fails == 0 else "%d FAIL" % fails))
	quit(1 if fails > 0 else 0)
