extends SceneTree

# The flight frame is the parent's equatorial frame (Rocketry.spin_frame):
#   Godot --headless --path . --script res://tools/spinframecheck.gd
# Seasons at the pad, the Moon's inclination to Earth's equator, RA/Dec against the
# launch site, and a rebase between two poles and back.

const DAY_CY := 1.0 / 36525.0

var checks := 0
var failures := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("SPINFRAMECHECK FAIL ", what)

func solar(t_cy: float) -> Array:
	var out := []
	for spec in Presets._build_solar(t_cy):
		out.append(Derive.new_body(out.size(), spec))
	return out

func named(bodies: Array, n: String) -> Body:
	for b in bodies:
		if b.name == n: return b
	return null

func ship_at(bodies: Array, home: String) -> Vessel:
	return Vessel.new({"vehicle": Vehicles.VEHICLES.saturnv, "parent": named(bodies, home), "bodies": bodies})

## The Sun's declination from its ecliptic longitude, sin δ = sin ε sin λ: written
## from the orrery's ecliptic axes, not through the frame under test.
func declination(earth: Body, sun: Body) -> float:
	var d := DVec3.new().sub_vectors(sun.pos, earth.pos)
	var lam := atan2(d.z, d.x)
	return asin(sin(Rocketry.OBLIQUITY_J2000) * sin(lam))

func _init() -> void:
	var deg := 180.0 / PI
	var eps := Rocketry.OBLIQUITY_J2000

	# Earth's frame is J2000 equatorial in orrery axes: the equinox stays on +X and the
	# pole leans toward ecliptic longitude 90° (+Z).
	var earth0 := named(solar(0.0), "Earth")
	var f := Rocketry.spin_frame(earth0)
	var x := DQuat.rotate(DVec3.new(1.0, 0.0, 0.0), f)
	var pole := DQuat.rotate(DVec3.new(0.0, -1.0, 0.0), f)
	check(x.distance_to(DVec3.new(1.0, 0.0, 0.0)) < 1e-12, "Earth frame keeps the equinox on +X")
	check(pole.distance_to(DVec3.new(0.0, -cos(eps), sin(eps))) < 1e-12, "Earth's pole is ε from the ecliptic pole, toward +Z")

	# A star's RA/Dec is its longitude/latitude in Earth's frame, as a launch site's are.
	var w := solar(0.0)
	var ship := ship_at(w, "Earth")
	for star in [[6.752, -16.716], [14.66, -60.83], [2.53, 89.26], [18.6, 38.78], [0.0, 0.0]]:
		var d := ship.to_local(Spaceflight.mission_direction({"ra": star[0], "dec": star[1]}), DVec3.new())
		check(absf(asin(-d.y) * deg - float(star[1])) < 1e-9, "RA/Dec %s: latitude %.9f° is the declination" % [star, asin(-d.y) * deg])
		if absf(float(star[1])) < 89.0:
			var lon := atan2(d.z, d.x) * deg
			check(absf(angle_difference(deg_to_rad(lon), deg_to_rad(float(star[0]) * 15.0))) * deg < 1e-9,
				"RA/Dec %s: longitude %.9f° is the right ascension" % [star, lon])

	# Seasons: the subsolar latitude is the Sun's declination, through the year; a pad at
	# 28.5° N sees the noon sun 90° − |28.5° − δ| up.
	var lo := INF
	var hi := -INF
	var noon_lo := INF
	var noon_hi := -INF
	for i in 48:
		var bodies := solar(float(i) * 365.25 / 48.0 * DAY_CY)
		var earth := named(bodies, "Earth")
		var sun := named(bodies, "Sun")
		var v := ship_at(bodies, "Earth")
		var s := DQuat.nrm(v.body_offset(sun, DVec3.new()))
		var sub_lat := asin(-s.y)
		var dec := declination(earth, sun)
		check(absf(sub_lat - dec) < 0.002, "day %d: subsolar latitude %.3f° is the declination %.3f°" % [i, sub_lat * deg, dec * deg])
		lo = minf(lo, sub_lat); hi = maxf(hi, sub_lat)
		v.place_on_pad(28.5, atan2(s.z, s.x) * deg)
		var el := 90.0 - acos(DQuat.nrm(v.r.clone()).dot(s)) * deg
		noon_lo = minf(noon_lo, el); noon_hi = maxf(noon_hi, el)
	check(hi * deg > 23.0 and lo * deg < -23.0, "the subsolar latitude spans the tropics: %.2f° to %.2f°" % [lo * deg, hi * deg])
	check(noon_hi > 84.0 and noon_lo < 38.5, "noon at a 28.5° N pad: %.1f° to %.1f°" % [noon_lo, noon_hi])
	print("SPINFRAMECHECK seasons subsolar %.2f°..%.2f°, 28.5° N noon sun %.1f°..%.1f°" % [lo * deg, hi * deg, noon_lo, noon_hi])

	# The Moon's orbit is 5.1° from the ecliptic and 18.3°–28.6° from Earth's equator over
	# the 18.6-year nodal cycle.
	var inc_lo := INF
	var inc_hi := -INF
	for i in 24:
		var bodies := solar(float(i) * 18.6 / 24.0 * 365.25 * DAY_CY)
		var v := ship_at(bodies, "Earth")
		var moon := named(bodies, "Moon")
		var earth := named(bodies, "Earth")
		var r := v.body_offset(moon, DVec3.new())
		var vv := v.to_local(DVec3.new().sub_vectors(moon.vel, earth.vel).scale_in(Rocketry.AU_M / Rocketry.YR_S), DVec3.new())
		var inc: float = Orbit.elements(r, vv, Rocketry.GM_SUN * (earth.mass + moon.mass)).inc * deg
		inc_lo = minf(inc_lo, inc); inc_hi = maxf(inc_hi, inc)
		if i == 0: print("SPINFRAMECHECK Moon at J2000: %.2f° to Earth's equator" % inc)
	check(inc_lo > 18.0 and inc_hi < 29.0 and inc_lo < 19.0 and inc_hi > 28.0, "Moon to the equator over a nodal cycle: %.2f° to %.2f°" % [inc_lo, inc_hi])
	print("SPINFRAMECHECK Moon to Earth's equator %.2f°..%.2f°" % [inc_lo, inc_hi])

	# A rebase between two poles turns the state and the attitude into the new frame:
	# the same world position, velocity and pointing, and back again.
	var bodies := solar(0.0)
	var v := ship_at(bodies, "Earth")
	var moon := named(bodies, "Moon")
	v.r.copy_from(v.body_offset(moon, DVec3.new())).scale_in(0.97)
	v.v.set_v(120.0, -340.0, 910.0)
	v.q.set_from_axis_angle(DQuat.nrm(DVec3.new(0.3, 0.5, -0.8)), 1.1)
	var turned := []
	v.on_rebase = func(t: DQuat) -> void: turned.append(t)
	var w0 := v.world_pos()
	var nose0 := v.to_world(v.forward(DVec3.new()), DVec3.new())
	var r0 := v.r.clone()
	var v0 := v.v.clone()
	var q0 := v.q.clone()
	v.rebase(moon)
	check(v.world_pos().distance_to(w0) * Rocketry.AU_M < 1e-3, "rebase keeps the world position")
	check(v.to_world(v.forward(DVec3.new()), DVec3.new()).distance_to(nose0) < 1e-12, "rebase keeps the world pointing")
	check(turned.size() == 1, "rebase between poles reports its turn")
	v.rebase(named(bodies, "Earth"))
	check(v.r.distance_to(r0) < 1e-3 and v.v.distance_to(v0) < 1e-9 and absf(v.q.dot(q0)) > 1.0 - 1e-15, "rebase there and back restores the state")

	print("SPINFRAMECHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
