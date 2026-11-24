extends SceneTree

# ROVER CHECK: the LRV's physics (sim/surface/rover.gd) against what the Apollo crews and engineers recorded,
# on planes in lunar gravity. None of the record is an input. docs/physics/rover.md.
#   Godot --headless --path . --script res://tools/rovercheck.gd

const G := 1.62
var failures := 0
var checks := 0

func check(what: String, ok: bool) -> void:
	checks += 1
	if ok: print("ROVERCHECK ok   ", what)
	else:
		failures += 1
		printerr("ROVERCHECK FAIL ", what)

func _init() -> void:
	sinkage()
	speed()
	slopes()
	turning()
	parked()
	repeat()
	dust()
	perseverance()
	arm()
	print("ROVERCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _rover(slope := 0.0, toward := 0.0) -> Rover:
	var r := Rover.new(Rover.PlaneGround.new(slope, toward), G)
	r.place(0.0, 0.0, 0.0)
	return r

func _mean_sinkage(r: Rover, which := -1) -> float:
	var s := 0.0
	var n := 0
	for i in r.wheels.size():
		if which >= 0 and i != which: continue
		s += (r.wheels[i] as Rover.Wheel).sinkage
		n += 1
	return s / maxf(n, 1)

# Standing loaded on level ground: the rigid wheel's closed form, against the half-inch tracks the crews left.
func sinkage() -> void:
	var r := _rover()
	var z := _mean_sinkage(r)
	var weight := float(r.spec.mass) * G
	var closed := r.sinkage_for(weight / 4.0)
	check("at rest the wheels carry the vehicle (%s of %s N)" % [U.fixed(_load(r), 0), U.fixed(weight, 0)],
		absf(_load(r) - weight) < 0.02 * weight)
	check("they sink %s cm, Bekker's closed form for a quarter of the load (%s cm)" % [U.fixed(z * 100.0, 2), U.fixed(closed * 100.0, 2)],
		absf(z - closed) < 0.05 * closed)
	check("against tracks about half an inch (1.27 cm) deep on level ground (Smithsonian, the spare LRV wheel): %s cm; the rigid wheel overstates a wire-mesh tyre's" % U.fixed(z * 100.0, 2),
		z > 0.006 and z < 0.025)

func _load(r: Rover) -> float:
	var s := 0.0
	for wh: Rover.Wheel in r.wheels: s += wh.load
	return s

# Full throttle on the level: the top speed, the slip at it, and how soon 10 km/h comes.
func speed() -> void:
	var r := _rover()
	r.throttle = 1.0
	var t10 := -1.0
	var d10 := 0.0
	var start := r.pos.clone()
	for i in 60 * 60:
		r.advance(1.0 / 60.0)
		if t10 < 0.0 and r.speed() >= 10.0 / 3.6:
			t10 = r.time
			d10 = r.pos.sub(start).length()
	var v := r.speed() * 3.6
	var slip := 0.0
	for wh: Rover.Wheel in r.wheels: slip = maxf(slip, absf(wh.slip))
	check("full throttle on the level: %s km/h (Apollo 15 reached 13 on the level)" % U.fixed(v, 1), v > 10.0 and v < 16.5)
	check("with little wheel slip at it: %s%% (the crews: \"very little wheel slippage\")" % U.fixed(slip * 100.0, 1), slip < 0.08)
	check("10 km/h in %s m, %s s (\"approximately three vehicle lengths\", 9.3 m)" % [U.fixed(d10, 1), U.fixed(t10 - 1200.0 * Rover.DT, 1)],
		t10 > 0.0 and d10 > 4.0 and d10 < 25.0)

# Up a slope, and across one.
func slopes() -> void:
	var climb := func(deg: float) -> float:
		var r := _rover(deg_to_rad(deg), 0.0)
		r.throttle = 1.0
		for i in 60 * 40: r.advance(1.0 / 60.0)
		return r.speed() * 3.6
	var v15: float = climb.call(15.0)
	check("full throttle climbs 15°: %s km/h" % U.fixed(v15, 1), v15 > 0.8)
	# A known shortfall, printed and not judged: the straight torque–speed line (Rover.drive_torque) gives a
	# series motor too little torque at low speed. Apollo 16 climbed with the pitch gauge pegged at 20°.
	print("ROVERCHECK note full throttle up 20°: %s km/h; the crews climbed 20°" % U.fixed(climb.call(20.0), 1))
	# Across 15°: the ground rises toward the west, so the right (east) wheels are downhill.
	var x := _rover(deg_to_rad(15.0), -PI * 0.5)
	var up_side := (_mean_sinkage(x, 0) + _mean_sinkage(x, 2)) * 0.5
	var down := (_mean_sinkage(x, 1) + _mean_sinkage(x, 3)) * 0.5
	check("parked across 15° the downhill wheels sink %s cm, the uphill %s cm (Apollo 15: deeper downhill, \"perhaps up to 3 or 4 cm\" on steep slopes)" % [
		U.fixed(down * 100.0, 2), U.fixed(up_side * 100.0, 2)], down > 1.15 * up_side)

# The turning circle at walking pace, and the rear breaking out when turned hard at 10 km/h.
func turning() -> void:
	var r := _rover()
	r.steer = 1.0
	r.throttle = 0.25
	var pts: Array = []
	for i in 60 * 40:
		r.advance(1.0 / 60.0)
		if i > 60 * 10 and i % 30 == 0: pts.append(Vector2(r.pos.x, r.pos.z))
	var radius := _circle_radius(pts)
	check("full lock at %s km/h turns on a %s m radius (NSSDC: a 3.1 m steering radius)" % [U.fixed(r.speed() * 3.6, 1), U.fixed(radius, 2)],
		radius > 2.6 and radius < 3.8)
	for case in [[4.0, false], [10.0, true]]:
		var t := _rover()
		t.throttle = 1.0
		while t.speed() < float(case[0]) / 3.6 and t.time < 60.0: t.advance(1.0 / 60.0)
		t.throttle = 0.3
		t.steer = 1.0
		var worst := 0.0
		for i in 60 * 3:
			t.advance(1.0 / 60.0)
			for k in [2, 3]: worst = maxf(worst, absf((t.wheels[k] as Rover.Wheel).side_slip))
		var deg := rad_to_deg(worst)
		if case[1]:
			check("hard over at 10 km/h the rear slides %s° (Apollo 15: a breakout of the rear wheels at 10 km/h)" % U.fixed(deg, 1), deg > 12.0)
		else:
			check("hard over at 4 km/h the rear holds within %s°" % U.fixed(deg, 1), deg < 12.0)

func _circle_radius(pts: Array) -> float:
	var c := Vector2.ZERO
	for p in pts: c += p
	c /= maxf(pts.size(), 1)
	# Least squares (Kåsa): fit x² + y² + Dx + Ey + F = 0 about the mean.
	var suu := 0.0; var svv := 0.0; var suv := 0.0; var suuu := 0.0; var svvv := 0.0; var suvv := 0.0; var svuu := 0.0
	for p: Vector2 in pts:
		var u := p.x - c.x
		var v := p.y - c.y
		suu += u * u; svv += v * v; suv += u * v
		suuu += u * u * u; svvv += v * v * v; suvv += u * v * v; svuu += v * u * u
	var a := 0.5 * (suuu + suvv)
	var b := 0.5 * (svvv + svuu)
	var det := suu * svv - suv * suv
	if absf(det) < 1e-9: return INF
	var uc := (a * svv - b * suv) / det
	var vc := (b * suu - a * suv) / det
	return sqrt(uc * uc + vc * vc + (suu + svv) / pts.size())

# Parked on a slope with the controller centred: the brake holds it.
func parked() -> void:
	var r := _rover(deg_to_rad(15.0), 0.0)
	var at := r.pos.clone()
	for i in 60 * 20: r.advance(1.0 / 60.0)
	var moved := r.pos.sub(at).length()
	check("parked on 15° with the controller centred it holds (%s m in 20 s)" % U.fixed(moved, 3), moved < 0.2)

# Fixed steps: the same drive twice is the same drive.
func repeat() -> void:
	var a := _drive()
	var b := _drive()
	check("the same drive twice ends at the same place (%s m apart)" % U.expo(a.sub(b).length(), 1), a.sub(b).length() == 0.0)

func _drive() -> DVec3:
	var r := _rover(deg_to_rad(5.0), 0.7)
	r.throttle = 0.8
	r.steer = 0.4
	for i in 60 * 15: r.advance(1.0 / 60.0)
	return r.pos.clone()

# A grain in vacuum flies the exact parabola, and the roostertail rises as high as the rim speed makes it.
func dust() -> void:
	var d := RoverDust.new(G, 0.0, 3)
	d._add(Vector3.ZERO, Vector3(0.0, 2.0, 1.0), 0.0)
	var top := 0.0
	var t := 0.0
	while d.count > 0 and t < 10.0:
		d._fly(1.0 / 60.0)
		t += 1.0 / 60.0
		if d.count > 0: top = maxf(top, d.pos[0].y)
	check("a grain thrown up at 2 m/s in vacuum rises %s m (v²/2g: %s m) and lands after %s s (2v/g: %s s)" % [U.fixed(top, 4),
		U.fixed(4.0 / (2.0 * G), 4), U.fixed(t, 2), U.fixed(4.0 / G, 2)], absf(top - 4.0 / (2.0 * G)) < 0.005 and absf(t - 4.0 / G) < 0.05)
	# From rest to full speed on the level: the highest grain, and how far ahead of its wheel any lands.
	var r := _rover()
	var dd := RoverDust.new(G, 0.0, 5)
	r.throttle = 1.0
	var high := 0.0
	for i in 60 * 20:
		r.advance(1.0 / 60.0)
		dd.step(r, 1.0 / 60.0)
		for k in dd.count: high = maxf(high, dd.pos[k].y - dd.floor_y[k])
	check("accelerating from rest the roostertail stands %s m high (Apollo 15: about 3 m, during acceleration)" % U.fixed(high, 2), high > 1.5 and high < 5.0)

# Perseverance in Martian sand (M90), at Mars's gravity: what its pages and Curiosity's soil studies say.
func perseverance() -> void:
	const GM := 3.71
	var mk := func(slope := 0.0, toward := 0.0) -> Rover:
		var r := Rover.new(Rover.PlaneGround.new(slope, toward), GM, Rover.PERSEVERANCE, Rover.MARS_SAND)
		r.place(0.0, 0.0, 0.0)
		return r
	var r: Rover = mk.call()
	var share := float(r.spec.mass) * GM / 6.0
	var z := _mean_sinkage(r)
	check("Perseverance stands on six wheels (%s of %s N)" % [U.fixed(_load(r), 0), U.fixed(share * 6.0, 0)], absf(_load(r) - share * 6.0) < 0.02 * share * 6.0)
	check("sinking %s cm into dune sand, Bekker's %s cm; Curiosity's wheels went in about 1 cm on Gale's firmer ground (Arvidson et al. 2014)" % [
		U.fixed(z * 100.0, 2), U.fixed(r.sinkage_for(share) * 100.0, 2)], absf(z - r.sinkage_for(share)) < 0.05 * r.sinkage_for(share) and z > 0.005 and z < 0.04)
	r.throttle = 1.0
	for i in 60 * 120: r.advance(1.0 / 60.0)
	var v := r.speed() * 3600.0
	var lev_slip := 0.0
	for wh: Rover.Wheel in r.wheels: lev_slip += wh.slip / 6.0
	check("driving on level sand at %s m/h: NASA's 152 m/h on flat, hard ground less its %s%% slip in sand" % [U.fixed(v, 0), U.fixed(lev_slip * 100.0, 1)],
		absf(v - 152.0 * (1.0 - lev_slip)) < 3.0 and v <= 152.5)
	for deg in [15.0, 25.0]:
		var c: Rover = mk.call(deg_to_rad(deg), 0.0)
		c.throttle = 1.0
		for i in 60 * 120: c.advance(1.0 / 60.0)
		var slip := 0.0
		for wh: Rover.Wheel in c.wheels: slip += absf(wh.slip) / 6.0
		if deg == 15.0:
			check("up 15° of sand at %s m/h, slipping %s%%" % [U.fixed(c.speed() * 3600.0, 0), U.fixed(slip * 100.0, 0)], c.speed() > 0.0 and slip < 0.5)
		else:
			print("ROVERCHECK note up 25° of sand: %s m/h, slipping %s%%" % [U.fixed(c.speed() * 3600.0, 0), U.fixed(slip * 100.0, 0)])
	var t: Rover = mk.call()
	t.steer = 1.0
	t.throttle = 1.0
	var pts: Array = []
	for i in 60 * 400:
		t.advance(1.0 / 60.0)
		if i > 60 * 60 and i % 120 == 0: pts.append(Vector2(t.pos.x, t.pos.z))
	var radius := _circle_radius(pts)
	check("full lock turns on a %s m radius (its corner wheels set for 2 m)" % U.fixed(radius, 2), radius > 1.6 and radius < 2.5)
	# The rated tilt: across 40° it stands. Statically it tips where the centre of mass passes the downhill wheels.
	var x: Rover = mk.call(deg_to_rad(40.0), -PI * 0.5)
	for i in 60 * 20: x.advance(1.0 / 60.0)
	var up := DQuat.rotate(DVec3.new(0.0, 1.0, 0.0), x.q)
	var tip := rad_to_deg(atan(float(x.spec.track) * 0.5 / float(x.spec.com_height)))
	check("parked across 40° it stays on its wheels (up %s° from vertical; it would tip past %s°; rated to 45°)" % [
		U.fixed(rad_to_deg(acos(clampf(up.y, -1.0, 1.0))), 1), U.fixed(tip, 0)], up.y > cos(deg_to_rad(50.0)) and tip >= 45.0)

# The arm's inverse kinematics against its forward: the turret's face where it was sent, and no answer out of reach.
func arm() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	var worst := 0.0
	var solved := 0
	var refused := 0
	for i in 400:
		var p := RoverArm.SHOULDER + Vector3(rng.randf_range(-1.8, 1.8), rng.randf_range(-1.6, 0.6), rng.randf_range(0.0, 2.0))
		var sol = RoverArm.solve(p)
		var span := (p + Vector3(0.0, RoverArm.WRIST, 0.0) - RoverArm.SHOULDER).length()
		if sol == null:
			if span < RoverArm.UPPER + RoverArm.FOREARM - 1e-3 and span > absf(RoverArm.UPPER - RoverArm.FOREARM) + 1e-3:
				worst = INF
			refused += 1
			continue
		solved += 1
		worst = maxf(worst, (RoverArm.tip(sol) - p).length())
	check("the arm puts its turret where it is sent (%d reached, worst %s m; %d out of reach refused)" % [solved, U.expo(worst, 1), refused],
		solved > 100 and refused > 20 and worst < 1e-5)
	var a := RoverArm.new()
	var target := Vector3(0.0, -1.0 + 0.0, 1.9)
	check("and moves there at its joints' rate, landing on it", a.reach(target))
	for i in 60 * 60: a.advance(1.0 / 60.0)
	check("(%s m off after a minute)" % U.expo((RoverArm.tip(a.joints) - target).length(), 1), a.placed and (RoverArm.tip(a.joints) - target).length() < 1e-4)
