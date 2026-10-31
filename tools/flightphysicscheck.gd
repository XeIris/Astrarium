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

	# The deorbit predictor's coast: the conic without zonal terms, stopping where the
	# radius falls through entry interface.
	var vd := vessel_at(earth, [earth])
	vd.place_in_orbit(290000.0, 51.6, 0.0)
	vd.v.scale_in(0.9915)
	var el_d := Orbit.elements(vd.r, vd.v, mu_e)
	var r_ei := float(vd.env.radius) + 121920.0
	var cr := DVec3.new(); var cv := DVec3.new(); var kr := DVec3.new(); var kv := DVec3.new()
	var t_k := Orbit.time_to_radius_descending(el_d, mu_e, r_ei)
	Orbit.propagate(vd.r, vd.v, mu_e, t_k, kr, kv)
	var t_c := Orbit.zonal_coast(vd.r, vd.v, mu_e, null, 6000.0, cr, cv, r_ei)
	check("the zonal coast without zonal terms reaches entry interface when the conic does (%.3f s, %.2f m off it)" % [t_c - t_k, cr.length() - r_ei],
		absf(t_c - t_k) < 0.01 and absf(cr.length() - r_ei) < 0.1)
	Orbit.zonal_coast(vd.r, vd.v, mu_e, null, float(el_d.period) * 0.4, cr, cv)
	Orbit.propagate(vd.r, vd.v, mu_e, float(el_d.period) * 0.4, kr, kv)
	check("and carries a state for a span as the conic does (%.2f m)" % cr.distance_to(kr), cr.distance_to(kr) < 5.0)

	# The sky's multiple scattering: positive, bluer than red at the ground by day, and a
	# gain below single scattering's 15 so the noon zenith keeps its calibration.
	var psi := func(j: int, i: int, c: int) -> float: return float(SkyMS.PSI[(j * SkyMS.N_MU + i) * 3 + c])
	check("multiple scattering lights the ground-level noon sky, bluer than red",
		psi.call(0, SkyMS.N_MU - 1, 1) > 0.0 and psi.call(0, SkyMS.N_MU - 1, 2) > psi.call(0, SkyMS.N_MU - 1, 0))
	check("the sky table is %d × %d RGB" % [SkyMS.N_MU, SkyMS.N_H], SkyMS.PSI.size() == SkyMS.N_MU * SkyMS.N_H * 3 and SkyMS.GAIN > 5.0 and SkyMS.GAIN < 15.0)

	# A stage's Cd table replaces the generic curve.
	var table := { "source": "test", "rows": [[0.0, 0.2], [1.0, 0.6], [3.0, 0.3]] }
	check("a Cd table interpolates by Mach", absf(Rocketry.drag_coefficient(2.0, table) - 0.45) < 1e-12 and Rocketry.drag_coefficient(9.0, table) == 0.3)
	var tables := 0
	var sourced := true
	for key in Vehicles.VEHICLES:
		for st in Vehicles.VEHICLES[key].stages:
			for k in ["cdTable", "cdBase"]:
				var t = st.get(k)
				if t == null: continue
				tables += 1
				var rows: Array = t.rows
				sourced = sourced and str(t.get("source", "")) != "" and rows.size() >= 2
				for i in range(1, rows.size()): sourced = sourced and float(rows[i][0]) > float(rows[i - 1][0])
	check("every vehicle drag table names its source and ascends in Mach (%d tables)" % tables, sourced and tables >= 4)
	check("the S-IC's table peaks transonic and turns negative with the plume past Mach 7",
		Rocketry.drag_coefficient(1.2, Vehicles.SATURN_SIC_CA) > 0.8 and Rocketry.drag_coefficient(7.5, Vehicles.SATURN_SIC_CA) < 0.0)

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

	azimuths()
	aerocapture()
	aerobraking()
	lagrange()
	skies()
	tesseral()
	thermosphere()
	blackout()
	print("flightphysicscheck: %s" % ("PASS" if fails == 0 else "%d FAIL" % fails))
	quit(1 if fails > 0 else 0)

# Normalized Legendre values, −∇ of the tesseral potential, a turned body turning its
# field, and the size of the Moon's mascons and Earth's C22.
func tesseral() -> void:
	var sp := 0.3; var cp := sqrt(1.0 - sp * sp)
	var P := Rocketry._legendre(3, sp, cp)
	var want := [1.0, sqrt(3.0) * sp, sqrt(3.0) * cp, sqrt(5.0) * 0.5 * (3.0 * sp * sp - 1.0), sqrt(15.0) * sp * cp,
		sqrt(15.0) * 0.5 * cp * cp, 0.0, 0.0, 0.0, sqrt(35.0 / 8.0) * cp * cp * cp]
	var worst := 0.0
	for k in want.size():
		if k in [6, 7, 8]: continue
		worst = maxf(worst, absf(P[k] - float(want[k])))
	check("normalized P̄nm against closed forms", worst < 1e-12, worst)
	for name in ["Earth", "Moon"]:
		var f: Dictionary = Rocketry.TESSERAL[name]
		var mu := 3.986004418e14 if name == "Earth" else LunarGravity.GM
		var R := float(f.R)
		var bad := 0.0
		for p in [DVec3.new(1.05, -0.3, 0.4), DVec3.new(-0.2, 0.9, 0.6), DVec3.new(0.5, 0.1, -1.0)]:
			var pp: DVec3 = DQuat.nrm(p.clone()).scale_in(R * 1.06)
			var th := 0.7
			var a := Rocketry.tesseral_accel(f, mu, pp, th, DVec3.new())
			var e := 0.5
			var g := DVec3.new()
			for ax in 3:
				var d := DVec3.new(e if ax == 0 else 0.0, e if ax == 1 else 0.0, e if ax == 2 else 0.0)
				var u1 := Rocketry.tesseral_potential(f, mu, pp.clone().add_in(d), th)
				var u0 := Rocketry.tesseral_potential(f, mu, pp.clone().sub_in(d), th)
				g.set(["x", "y", "z"][ax], -(u1 - u0) / (2.0 * e))
			bad = maxf(bad, g.sub_in(a).length() / a.length())
			# Turning the body by δ and the point with it leaves the field's pull turned by δ.
			var dl := 0.4
			var q := DVec3.new(pp.x * cos(dl) - pp.z * sin(dl), pp.y, pp.x * sin(dl) + pp.z * cos(dl))
			var b := Rocketry.tesseral_accel(f, mu, q, th + dl, DVec3.new())
			var bb := DVec3.new(a.x * cos(dl) - a.z * sin(dl), a.y, a.x * sin(dl) + a.z * cos(dl))
			bad = maxf(bad, bb.sub_in(b).length() / a.length())
		check("%s tesseral field is −∇Φ and turns with the body" % name, bad < 1e-5, bad)
	# Mascons: the degree-16 field's pull 100 km over the Moon is a few hundred mGal.
	var moon: Dictionary = Rocketry.TESSERAL.Moon
	var big := 0.0
	for i in 64:
		var lon := TAU * i / 64.0
		for lat in [-0.6, -0.2, 0.2, 0.6]:
			var pp := DVec3.new(cos(lat) * cos(lon), -sin(lat), cos(lat) * sin(lon)).scale_in(LunarGravity.R_REF + 1.0e5)
			big = maxf(big, Rocketry.tesseral_accel(moon, LunarGravity.GM, pp, 0.0, DVec3.new()).length())
	check("the Moon's tesseral pull at 100 km peaks at 10–100 mGal·10 (%.0f mGal)" % (big * 1e5), big > 1e-3 and big < 1e-2)
	# Earth's C22 at LEO: 3·μ/r²·(R/r)²·C22 (unnormalized), within a factor of the
	# sectoral term alone.
	var e_f: Dictionary = Rocketry.TESSERAL.Earth
	var rr := DVec3.new(6.778e6, 0.0, 0.0)
	var c22 := Rocketry.tesseral_accel(e_f, 3.986004418e14, rr, 0.0, DVec3.new()).length()
	var c22u := sqrt(pow(2.43938357328e-6, 2.0) + pow(1.40027370385e-6, 2.0)) * sqrt(5.0 / 12.0)
	var expect := 3.0 * 3.986004418e14 / (rr.x * rr.x) * pow(6378136.3 / rr.x, 2.0) * c22u * 3.0
	check("Earth's C22 at 400 km is ~1e-4 m/s² (%s)" % U.expo(c22, 2), c22 > 0.2 * expect and c22 < 2.0 * expect)

# The thermosphere against US76 at F10.7 = 150, its spread with activity, and the
# decay of a 400 km orbit against da/dt = −ρ·√(μa)·C_dA/m.
func thermosphere() -> void:
	var atm: Dictionary = Rocketry.ATMOSPHERES.Earth
	var worst := 0.0
	for h in [200e3, 300e3, 400e3, 500e3, 600e3]:
		Rocketry.f107 = 0.0
		var us := Rocketry.density(atm, h)
		Rocketry.f107 = 150.0
		worst = maxf(worst, absf(Rocketry.density(atm, h) / us - 1.0))
	check("Bates–Walker at F10.7 = 150 follows US76 within 20%% at 200–600 km (%.2f)" % worst, worst < 0.2)
	Rocketry.f107 = 70.0
	var lo := Rocketry.density(atm, 400e3)
	Rocketry.f107 = 250.0
	var hi := Rocketry.density(atm, 400e3)
	check("400 km density spans 10–30× from solar minimum to maximum (%.1f×)" % (hi / lo), hi / lo > 10.0 and hi / lo < 30.0)
	# Decay on rails at 400 km over two days at three activities. Osculating a carries
	# km of J2 wobble, the same in each run, so the differences between runs are drag's:
	# they must scale as the densities' differences.
	var decay := {}
	var rho := {}
	for f in [70.0, 150.0, 250.0]:
		Rocketry.f107 = f
		rho[f] = Rocketry.density(atm, 400e3)
		var earth := body("Earth", Rocketry.M_EARTH_SUN, 6371.0)
		var v := vessel_at(earth, [earth])
		v.place_in_orbit(400000.0, 51.6, 0.0)
		var mu: float = v.env.mu
		var a0 := float(Orbit.elements(v.r, v.v, Rocketry.effective_mu(v.env.zonal, mu, v.r, v.v)).a)
		for i in 2 * 720: v.step(120.0, {"rails": true})
		decay[f] = a0 - float(Orbit.elements(v.r, v.v, Rocketry.effective_mu(v.env.zonal, mu, v.r, v.v)).a)
	var got := (float(decay[250.0]) - float(decay[70.0])) / (float(decay[150.0]) - float(decay[70.0]))
	var want := (float(rho[250.0]) - float(rho[70.0])) / (float(rho[150.0]) - float(rho[70.0]))
	check("an active Sun decays a 400 km orbit %.0f m more in 2 days than a quiet one; scaling %.2f against the densities' %.2f" % [
		float(decay[250.0]) - float(decay[70.0]), got, want], float(decay[250.0]) > float(decay[70.0]) + 100.0 and absf(got / want - 1.0) < 0.1)
	Rocketry.f107 = 0.0

# Radio blackout from the equilibrium shock layer: on along the Shuttle's and Apollo's
# entries where they lost contact, off in orbit and below Mach 8.
func blackout() -> void:
	var atm: Dictionary = Rocketry.ATMOSPHERES.Earth
	var crit := Ionisation.critical_density()
	check("S-band's critical density is 6.5e16 e⁻/m³", absf(crit / 6.49e16 - 1.0) < 0.01, crit)
	var cases := [["Shuttle 80 km, 7.4 km/s", 80e3, 7400.0, true], ["Shuttle 65 km, 6.2 km/s", 65e3, 6200.0, true],
		["Apollo 70 km, 10 km/s", 70e3, 10000.0, true], ["orbit 200 km, 7.8 km/s", 200e3, 7800.0, false],
		["Shuttle 40 km, 2.0 km/s", 40e3, 2000.0, false]]
	for c in cases:
		var ne := Ionisation.shock_layer_ne(atm, float(c[1]), float(c[2]))
		check("%s: %s (%s e⁻/m³)" % [c[0], "blackout" if c[3] else "contact", U.expo(ne, 1)], (ne > crit) == bool(c[3]))
	var sh := Ionisation.normal_shock(Rocketry.density(atm, 80e3), Rocketry.temperature(atm, 80e3), 10800.0)
	check("lunar-return shock layer near 10 000 K in equilibrium (%d K)" % int(sh.T), float(sh.T) > 8000.0 and float(sh.T) < 12500.0)
	check("Mars air is outside the model", Ionisation.shock_layer_ne(Rocketry.ATMOSPHERES.Mars, 40e3, 5000.0) == 0.0)

# Range-safety windows: the Cape's own targets, Vandenberg's south-going polar branch,
# Baikonur's floor of 51.6°, and the window's edge when a target is outside it.
func azimuths() -> void:
	var cases := [
		["Cape to 51.6°", 28.6, 51.6, 44.9, false], ["Cape to 32.5°", 28.6, 32.5, 73.9, false],
		["Cape to a polar orbit: held at 35°", 28.6, 90.0, 35.0, true],
		["Vandenberg to sun-synchronous 98°: south-southwest", 34.7, 98.0, 189.6, false],
		["Baikonur to 51.6°", 45.9, 51.6, 63.3, false], ["Baikonur to 46°: held at 63.3°", 45.9, 46.0, 63.3, true],
		["Starbase is unrestricted", 26.0, 28.5, 77.9, false]]
	for c in cases:
		var p := Rocketry.launch_azimuth(deg_to_rad(float(c[1])), float(c[2]))
		var az := rad_to_deg(float(p.az))
		check("%s (%.1f°)" % [c[0], az], absf(az - float(c[3])) < 0.6 and bool(p.limited) == bool(c[4]))

# Lagrange points: textbook distances, zero net force in the rotating frame at all
# five, and halo orbits that close with their known periods.
func lagrange() -> void:
	var mu_se := Rocketry.M_EARTH_SUN * 1.0123 / (1.0 + Rocketry.M_EARTH_SUN * 1.0123)
	var mu_em := 0.0121506
	var g_se := Lagrange.gammas(mu_se)
	var g_em := Lagrange.gammas(mu_em)
	check("Sun–Earth L2 lies 1.51 million km beyond Earth (%.0f km)" % (float(g_se[1]) * Rocketry.AU_M / 1000.0),
		absf(float(g_se[1]) * Rocketry.AU_M / 1.5077e9 - 1.0) < 0.005)
	check("Earth–Moon L1 lies 326 400 km from Earth (%.0f km)" % ((1.0 - float(g_em[0])) * 384400.0),
		absf((1.0 - float(g_em[0])) * 384400.0 - 326400.0) < 500.0)
	var worst := 0.0
	for xy in [[1.0 - mu_em - float(g_em[0]), 0.0], [1.0 - mu_em + float(g_em[1]), 0.0], [-mu_em - float(g_em[2]), 0.0],
			[0.5 - mu_em, sqrt(3.0) / 2.0], [0.5 - mu_em, -sqrt(3.0) / 2.0]]:
		var d := Lagrange._deriv(PackedFloat64Array([xy[0], xy[1], 0.0, 0.0, 0.0, 0.0]), mu_em)
		worst = maxf(worst, Vector2(d[3], d[4]).length())
	check("all five points are equilibria of the rotating frame", worst < 1e-12, worst)
	var h := Lagrange.halo(mu_se, 1, 5.0e8 / Rocketry.AU_M)
	var days := float(h.get("period", 0.0)) / TAU * 365.25
	check("a JWST-sized Sun–Earth L2 halo (Az 500 000 km) has a ~180 d period (%.1f d)" % days, days > 175.0 and days < 185.0)
	var e := Lagrange.halo(mu_em, 1, 1.5e7 / 3.844e8)
	var ed := float(e.get("period", 0.0)) / TAU * 27.3217
	check("a small Earth–Moon L2 halo has a ~14.8 d period (%.2f d)" % ed, ed > 14.0 and ed < 15.5)
	if not h.is_empty():
		var s: PackedFloat64Array = h.state
		var st := s
		var n := 4000
		for i in n: st = Lagrange._rk4(st, float(h.period) / n, mu_se)
		var miss := Vector3(st[0] - s[0], st[1] - s[1], st[2] - s[2]).length() * Rocketry.AU_M / 1000.0
		check("the halo closes after one period (%.1f km)" % miss, miss < 50.0)

# The physical skies' colours, single-scattered on the CPU from SkyMS.ATMOS as the dome
# does it: Earth's blue zenith, Mars's butterscotch noon and blue sunset round the sun,
# Titan's orange haze; and the storm index the aurora follows.
func _sky(a: Dictionary, R: float, d: Vector3, s: Vector3) -> Vector3:
	var top: float = R + float(a.top)
	var o := Vector3(0.0, R, 0.0)
	var b := o.dot(d)
	var t1 := -b + sqrt(b * b - (o.dot(o) - top * top))
	var mu := d.dot(s)
	var pr := 3.0 / (16.0 * PI) * (1.0 + mu * mu)
	var g: Vector3 = a.g
	var pm := Vector3.ZERO
	for c in 3: pm[c] = (1.0 - g[c] * g[c]) / (4.0 * PI * pow(maxf(1.0 + g[c] * g[c] - 2.0 * g[c] * mu, 1e-4), 1.5))
	var tau := Vector3.ZERO
	var L := Vector3.ZERO
	var n := 64
	for i in n:
		var ds := t1 / n
		var p := o + d * ((i + 0.5) * ds)
		var z := p.length() - R
		var dr := exp(-z / float(a.HR)); var dm := exp(-z / float(a.HM))
		var e: Vector3 = a.betaR * dr + a.betaMExt * dm
		# Sun path, 32 steps.
		var ts := Vector3.ZERO
		var bs := p.dot(s)
		var ts1 := -bs + sqrt(maxf(bs * bs - (p.dot(p) - top * top), 0.0))
		for k in 32:
			var q := p + s * ((k + 0.5) * ts1 / 32.0)
			var zq := q.length() - R
			ts += (a.betaR * exp(-zq / float(a.HR)) + a.betaMExt * exp(-zq / float(a.HM))) * (ts1 / 32.0)
		var tr := Vector3(exp(-tau.x - 0.5 * e.x * ds - ts.x), exp(-tau.y - 0.5 * e.y * ds - ts.y), exp(-tau.z - 0.5 * e.z * ds - ts.z))
		L += tr * (a.betaR * dr * pr + a.betaM * dm * pm) * ds
		tau += e * ds
	return L

func skies() -> void:
	var up := Vector3.UP
	var e: Vector3 = _sky(SkyMS.ATMOS.earth, 6.371e6, up, Vector3(cos(deg_to_rad(60.0)), sin(deg_to_rad(60.0)), 0.0))
	check("Earth's noon zenith is blue (B/R %.2f)" % (e.z / e.x), e.z / e.x > 2.0)
	var m: Vector3 = _sky(SkyMS.ATMOS.mars, 3.3895e6, up, Vector3(cos(deg_to_rad(60.0)), sin(deg_to_rad(60.0)), 0.0))
	check("Mars's noon zenith is butterscotch (B/R %.2f)" % (m.z / m.x), m.z / m.x < 0.75)
	var sun := Vector3(cos(deg_to_rad(2.0)), sin(deg_to_rad(2.0)), 0.0)
	var near: Vector3 = _sky(SkyMS.ATMOS.mars, 3.3895e6, Vector3(cos(deg_to_rad(7.0)), sin(deg_to_rad(7.0)), 0.0), sun)
	var away: Vector3 = _sky(SkyMS.ATMOS.mars, 3.3895e6, Vector3(-cos(deg_to_rad(20.0)), sin(deg_to_rad(20.0)), 0.0), sun)
	check("a Martian sunset is blue round the sun (B/R %.2f) and tan opposite (%.2f)" % [near.z / near.x, away.z / away.x],
		near.z / near.x > 1.0 and away.z / away.x < 0.6)
	var t: Vector3 = _sky(SkyMS.ATMOS.titan, 2.5747e6, up, Vector3(cos(deg_to_rad(50.0)), sin(deg_to_rad(50.0)), 0.0))
	check("Titan's haze leaves an orange zenith (G/R %.2f, B/R %.3f)" % [t.y / t.x, t.z / t.x], t.y / t.x < 0.6 and t.z / t.x < 0.1)
	var act := Stellar.ActivityModel.new(1.0, func(): return 0.5)
	check("a quiet Sun holds Kp at 2", Stellar.storm_kp(act) == 2.0)
	act.cmes.append({"t": 0.002, "energy": 3.0 * act.activity + 0.15})
	var before := Stellar.storm_kp(act)
	act.cmes[0].t = 0.0055
	var arrived := Stellar.storm_kp(act)
	act.cmes[0].t = 0.0055 + 0.0027 * 3.0
	var later := Stellar.storm_kp(act)
	check("a CME lifts Kp only once it arrives, then fades (%.1f, %.1f, %.1f)" % [before, arrived, later], before == 2.0 and arrived > 7.0 and later < 3.0)

# Aerocapture at Mars: the periapsis search leaves a 500 km apoapsis by its predictor,
# and the vessel's own integration through the same pass (heat shield first, every
# force accel() has) agrees with it.
func aerocapture() -> void:
	var mars := body("Mars", 3.2271e-7, 3389.5)
	# Starship's ship alone with landing propellant, the vehicle built to aerocapture at Mars.
	var v := Vessel.new({ "vehicle": Vehicles.VEHICLES.starship, "parent": mars, "bodies": [mars], "payload": 0.0 })
	v.stage(true)
	for st in v.stages:
		if st.attached: st.prop = minf(st.prop, 40000.0)
	var mu: float = v.env.mu
	var R := float(v.env.radius)
	# A 3 km/s hyperbola, 8000 km out and falling in.
	var vinf := 3000.0
	var r0 := 8.0e6
	var rp0 := R + 300e3
	var E := 0.5 * vinf * vinf
	var h := rp0 * sqrt(2.0 * (E + mu / rp0))
	var vr0 := sqrt(2.0 * (E + mu / r0))
	var vt := h / r0
	v.r.set_v(r0, 0.0, 0.0)
	v.v.set_v(-sqrt(vr0 * vr0 - vt * vt), 0.0, vt)
	v.phase = Vessel.PHASE.ORBIT
	var ra_want := R + 500e3
	var rp := Mission.aero_periapsis(v, v.r, v.v, mu, v.env, ra_want)
	check("Mars aerocapture corridor found (periapsis %.1f km)" % ((rp - R) / 1000.0), rp > R + 10e3 and rp < R + float(v.env.atm.top))
	# Aim the hyperbola there as the trim would, and fly it.
	v.v.copy_from(Mission.aimed_velocity(v.r, v.v, mu, rp))
	var pred := Orbit.aero_pass(v.r, v.v, mu, R, v.env.atm, float(v.env.rotRate), Mission.ballistic(v), v.diameter * 0.5, v.env.zonal)
	var ra_pred := float(Orbit.elements(pred.r, pred.v, mu).ra)
	var top := float(v.env.atm.top)
	var entered := false
	for i in 400000:
		var dir := DQuat.nrm(v.airspeed(v.r, v.v, DVec3.new()).scale_in(-1.0))
		v.q = DQuat.new().set_from_unit_vectors(Vessel.BODY_FWD, dir)
		v.omega.set_v(0.0, 0.0, 0.0)
		var alt := v.altitude()
		if alt < top: entered = true
		elif entered and v.r.dot(v.v) > 0.0: break
		v.step(0.5 if alt < top * 1.1 else 30.0)
		if v.phase == Vessel.PHASE.DESTROYED: break
	var ra_flown := float(Orbit.elements(v.r, v.v, mu).ra)
	check("the predictor's apoapsis %.0f km, flown %.0f km, asked %.0f km" % [(ra_pred - R) / 1000.0, (ra_flown - R) / 1000.0, (ra_want - R) / 1000.0],
		absf(ra_pred - ra_want) < 30e3 and absf(ra_flown - ra_pred) < 0.1 * (ra_pred - R) and v.phase != Vessel.PHASE.DESTROYED)

# Aerobraking at Mars without a heat shield: the walk-in periapsis peaks at the target
# pressure, and passes flown by the vessel take the apoapsis down by what the
# predictor says each one should.
func aerobraking() -> void:
	var mars := body("Mars", 3.2271e-7, 3389.5)
	var v := Vessel.new({ "vehicle": Vehicles.VEHICLES.ioncruiser, "parent": mars, "bodies": [mars], "payload": 0.0 })
	v.phase = Vessel.PHASE.ORBIT
	var mu: float = v.env.mu
	var R := float(v.env.radius)
	var ra := R + 10000e3
	var rp := Mission.aerobrake_periapsis(v.env, ra)
	var vp2 := mu * 2.0 * ra / (rp * (rp + ra))
	var q := 0.5 * Rocketry.density(v.env.atm, rp - R) * vp2
	check("aerobraking walk-in at %.1f km peaks at %.2f Pa" % [(rp - R) / 1000.0, q], absf(q / Mission.AEROBRAKE_Q - 1.0) < 0.02 and rp - R > 80e3)
	v.r.set_v(rp, 0.0, 0.0)
	v.v.set_v(0.0, 0.0, sqrt(vp2))
	var top := float(v.env.atm.top)
	var ras := [ra]
	var inside := false
	var guard := 0
	while ras.size() < 6 and guard < 2000000 and v.phase != Vessel.PHASE.DESTROYED:
		guard += 1
		var alt := v.altitude()
		if alt < top:
			var dir := DQuat.nrm(v.airspeed(v.r, v.v, DVec3.new()).scale_in(-1.0))
			v.q = DQuat.new().set_from_unit_vectors(Vessel.BODY_FWD, dir)
			v.omega.set_v(0.0, 0.0, 0.0)
			v.step(0.5)
			inside = true
		else:
			if inside:
				ras.append(float(Orbit.elements(v.r, v.v, mu).ra))
				inside = false
			v.step(minf(120.0, v.rail_step()), {"rails": true})
	var falling := v.phase != Vessel.PHASE.DESTROYED and ras.size() == 6
	for i in range(1, ras.size()): falling = falling and float(ras[i]) < float(ras[i - 1])
	check("five passes take the apoapsis down %.0f → %.0f km, intact" % [(float(ras[0]) - R) / 1000.0, (float(ras[ras.size() - 1]) - R) / 1000.0], falling)
	# The planner's closed-form pass: Δv = ρ_p v_p √(2π r_p H)/β.
	var H := Rocketry.scale_height(v.env.atm, rp - R)
	var dv := Rocketry.density(v.env.atm, rp - R) * sqrt(vp2) * sqrt(TAU * rp * H) / Mission.ballistic(v)
	var e := 0.5 * pow(sqrt(vp2) - dv, 2.0) - mu / rp
	var d_ra := ra - (2.0 * (-mu / (2.0 * e)) - rp)
	# The first pass started at periapsis, so it was half a pass; the second is whole.
	var flown := float(ras[1]) - float(ras[2])
	check("the planner's pass takes %.2f km off the apoapsis, the flown one %.2f km" % [d_ra / 1000.0, flown / 1000.0], absf(d_ra / flown - 1.0) < 0.35)
