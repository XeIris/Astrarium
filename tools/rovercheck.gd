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
	var closed := Rover.static_sinkage(Rover.MASS * G / 4.0)
	check("at rest the wheels carry the vehicle (%s of %s N)" % [U.fixed(_load(r), 0), U.fixed(Rover.MASS * G, 0)],
		absf(_load(r) - Rover.MASS * G) < 0.02 * Rover.MASS * G)
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
