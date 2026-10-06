extends SceneTree

# Analytic two-body expectations exercise numerical scales independently of parity.
var checks := 0
var failures := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func near(a: float, b: float, relative: float = 1e-11) -> bool:
	return is_finite(a) and is_finite(b) and absf(a - b) <= relative * maxf(absf(a), absf(b))

func hole(mass: float, x: float = 0.0, vy: float = 0.0) -> Body:
	var b := Body.new()
	b.type = "bh"
	b.mass = mass
	b.rs = Physics.schwarzschild(mass)
	b.contact_au = b.rs
	b.spec = {"type": "bh", "mass": mass}
	b.pos.x = x
	b.vel.y = vy
	return b

func circular_pair(mass: float, separation: float) -> Array:
	var speed := sqrt(Physics.G * 2.0 * mass / separation)
	return [hole(mass, -separation / 2.0, -speed / 2.0), hole(mass, separation / 2.0, speed / 2.0)]

func ordinary(mass: float, x: float, radius: float, vx: float = 0.0) -> Body:
	var b := Body.new()
	b.mass = mass
	b.pos.x = x
	b.radius = radius
	b.contact_au = radius
	b.vel.x = vx
	return b

func step(bodies: Array, dt: float, cap: float, kernel: String, boost: float = 0.0, callback: Callable = Callable()) -> Dictionary:
	return Derive.step_physics(bodies, dt, cap, boost, callback) if kernel == "gd" else NBody.step_physics(bodies, dt, cap, boost, callback)

func snapshot(bodies: Array) -> Array:
	var out: Array = []
	for b: Body in bodies:
		out.append([b.pos.x, b.pos.y, b.pos.z, b.vel.x, b.vel.y, b.vel.z, b.mass, b.alive])
	return out

func tiny_forces() -> void:
	var r := 5e-10
	var m := 1e-6
	var bodies := circular_pair(m, r)
	var a: Body = bodies[0]
	var b: Body = bodies[1]
	check("tiny BH outside physical contact", r > a.rs + b.rs)
	check("tiny BH request in structural domain", Structure.input_error(a.spec).is_empty())
	Physics.compute_accel(bodies)
	var acceleration := Physics.G * m / (r * r)
	check("tiny BH Newtonian acceleration", near(a.acc.x, acceleration))
	check("tiny BH opposing force", near(a.acc.x, -b.acc.x))
	check("tiny BH circular energy", near(Derive.total_energy(bodies), -Physics.G * m * m / (2.0 * r)))
	var h := r * 1e-4
	a.pos.x += h
	var plus := Derive.total_energy(bodies)
	a.pos.x -= 2.0 * h
	var minus := Derive.total_energy(bodies)
	a.pos.x += h
	check("tiny BH force matches potential gradient", near(-(plus - minus) / (2.0 * h), m * acceleration, 2e-8))
	a.type = "planet"
	b.type = "planet"
	a.radius = 1e-12
	b.radius = 1e-12
	a.softening = 0.02
	b.softening = 0.03
	a.vel.set_v(0.0, 0.0, 0.0)
	b.vel.set_v(0.0, 0.0, 0.0)
	Physics.compute_accel(bodies)
	var d2 := r * r + 0.5 * (0.02 * 0.02 + 0.03 * 0.03)
	check("tiny ordinary finite softened acceleration", near(a.acc.x, Physics.G * m * r / (d2 * sqrt(d2))))
	for kernel in ["gd", "native"]:
		a.pos.x = -r / 2.0; b.pos.x = r / 2.0
		a.vel.set_v(0.0, 0.0, 0.0); b.vel.set_v(0.0, 0.0, 0.0)
		a.contact_au = 1e-12; b.contact_au = 1e-12
		var result := step(bodies, 2e-12, 1e-13, kernel)
		check(kernel + " tiny ordinary force changes velocity", a.vel.x > 0.0 and b.vel.x < 0.0 and near(result.stepped, 2e-12))

func request_cases(kernel: String) -> void:
	for dt in [1e-9, 5e-13, 1e-200]:
		var b := hole(1.0)
		b.vel.x = 1.0
		var cap: float = dt / 16.0
		var result := step([b], dt, cap, kernel)
		check(kernel + " tiny request accepted %s" % dt, near(result.stepped, dt) and near(b.pos.x, dt))
		check(kernel + " explicit tiny cap respected %s" % dt, result.steps >= 16 and not result.get("resolution_limited", false))
	var b := hole(1.0)
	b.vel.x = 1.0
	var initial := snapshot([b])
	for dt in [0.0, -1.0]:
		var result := step([b], dt, 1e-4, kernel)
		check(kernel + " finite nonpositive time is no-op", result.stepped == 0.0 and result.steps == 0 and not result.get("resolution_limited", false) and snapshot([b]) == initial)
	for cap in [0.0, -1.0, NAN, INF]:
		var result := step([b], 1.0, cap, kernel)
		check(kernel + " invalid cap rejected %s" % cap, result.stepped == 0.0 and result.steps == 0 and result.get("resolution_limited", false) and snapshot([b]) == initial)
	for dt in [NAN, INF]:
		var result := step([b], dt, 1e-4, kernel)
		check(kernel + " nonfinite time rejected", result.stepped == 0.0 and result.get("resolution_limited", false) and snapshot([b]) == initial)
	for boost in [NAN, INF]:
		var result := step([b], 1.0, 1e-4, kernel, boost)
		check(kernel + " nonfinite reaction request rejected", result.stepped == 0.0 and result.get("resolution_limited", false) and snapshot([b]) == initial)
	var guarded := step([b], 1e-4, 1e-10, kernel)
	check(kernel + " guard counts actual bounded substeps", guarded.steps == Derive.STEP_GUARD and near(guarded.stepped, float(Derive.STEP_GUARD) * 1e-10))
	check(kernel + " guard advances accepted clock only", near(b.pos.x, guarded.stepped) and guarded.stepped < 1e-4 and not guarded.get("resolution_limited", false))

func lost_drift_cases(kernel: String) -> void:
	for fixture in [[1e16, 1.0, 0.01], [0.0, 1e-200, 1e-200]]:
		var b := hole(1.0, fixture[0])
		b.vel.x = fixture[1]
		var initial := snapshot([b])
		var result := step([b], fixture[2], fixture[2], kernel)
		check(kernel + " entirely lost force-free drift stops accepted time %s" % str(fixture), result.stepped == 0.0 and result.steps == 0 and result.get("resolution_limited", false) and snapshot([b]) == initial)
	var b := hole(1.0, 1e16)
	b.vel.x = 2.1
	var result := step([b], 1.1, 1.0, kernel)
	check(kernel + " lost later drift preserves accepted prefix", result.stepped == 1.0 and result.steps == 1 and result.get("resolution_limited", false) and b.pos.x == 1e16 + 2.0 and b.vel.x == 2.1)
	b = hole(1.0, 1e16)
	b.vel.set_v(1.0, 1.0, 0.0)
	result = step([b], 0.01, 0.01, kernel)
	check(kernel + " representable component prevents false whole-drift stop", result.stepped == 0.01 and not result.get("resolution_limited", false) and b.pos.y == 0.01)
	b = hole(1.0, 1e16)
	result = step([b], 0.01, 0.01, kernel)
	check(kernel + " stationary force-free body may advance time", result.stepped == 0.01 and not result.get("resolution_limited", false))
	var moving := hole(1.0, 1e16)
	moving.vel.x = 1.0
	var resolved := hole(1e-100, 0.0)
	resolved.vel.y = 1.0
	var bodies: Array = [moving, resolved]
	# This pair has a representable nonzero kick, even though the mover's position rounds away.
	result = step(bodies, 0.01, 0.01, kernel)
	check(kernel + " tiny accelerated kick is retained despite unresolved position", result.stepped == 0.01 and not result.get("resolution_limited", false) and resolved.vel.x > 0.0)

func energy_scale_cases() -> void:
	for fixture in [[900, -600, -300], [-900, 600, 300]]:
		var b := hole(pow(2.0, fixture[0]))
		b.vel.x = pow(2.0, fixture[1])
		check("kinetic energy recovers extreme intermediate square %s" % str(fixture), near(Derive.total_energy([b]), 0.5 * pow(2.0, fixture[2])))
	var b := hole(pow(2.0, 700.0))
	b.vel.x = 3.0 * pow(2.0, -538.0)
	check("subnormal velocity square does not distort representable energy", near(Derive.total_energy([b]), 4.5 * pow(2.0, -376.0)))
	b = hole(3.0 * pow(2.0, -1074.0))
	b.vel.x = pow(2.0, 500.0)
	check("subnormal half-mass does not distort representable energy", near(Derive.total_energy([b]), 1.5 * pow(2.0, -74.0)))
	for mass in [2.0, 3.0]:
		b = hole(mass)
		b.vel.x = pow(2.0, -537.0)
		check("representable final subnormal energy rounds once m=%s" % mass, Derive.total_energy([b]) == (1.0 if mass == 2.0 else 2.0) * pow(2.0, -1074.0))
	var uneven: Array = [hole(pow(2.0, -1074.0)), hole(pow(2.0, 1000.0), 1.0)]
	check("subnormal weighted mass does not distort potential energy", near(Derive.total_energy(uneven), -Physics.G * pow(2.0, -74.0)))
	for fixture in [[-600, -500, -700], [600, 700, 500]]:
		var mass := pow(2.0, fixture[0])
		var pair: Array = [hole(mass), hole(mass, pow(2.0, fixture[1]))]
		check("potential energy recovers extreme intermediate product %s" % str(fixture), near(Derive.total_energy(pair), -Physics.G * pow(2.0, fixture[2])))
	for exponent in [-600, 600]:
		var scale := pow(2.0, exponent)
		var pair: Array = [ordinary(1.0, 0.0, 0.0), ordinary(1.0, scale, 0.0)]
		for particle: Body in pair: particle.softening = scale
		check("softened distance rescales extreme square %s" % exponent, near(Derive.total_energy(pair), -Physics.G * pow(2.0, -exponent) / sqrt(2.0)))
	b = hole(1.0)
	b.vel.x = pow(2.0, -600.0)
	check("unrepresentable nonzero kinetic energy is unavailable", is_nan(Derive.total_energy([b])))
	check("unrepresentable nonzero potential energy is unavailable", is_nan(Derive.total_energy([hole(pow(2.0, -600.0)), hole(pow(2.0, -600.0), 1.0)])))
	check("truly overflowing energy is unavailable", is_nan(Derive.total_energy([hole(1.0, 0.0, 1e200)])))
	check("stationary isolated body has valid zero energy", Derive.total_energy([hole(1.0)]) == 0.0)
	var a := ordinary(0.7, -0.4, 0.02, 0.13)
	b = ordinary(1.3, 0.9, 0.03, -0.27)
	a.vel.y = -0.9; b.vel.z = 0.4
	var expected := 0.5 * a.mass * a.vel.length_sq() - Physics.G * a.mass * b.mass / sqrt(pow(a.pos.x - b.pos.x, 2.0) + Physics.pair_softening_sq(a, b)) + 0.5 * b.mass * b.vel.length_sq()
	check("ordinary diagnostic preserves original arithmetic exactly", Derive.total_energy([a, b]) == expected)

func force_scale_cases(kernel: String) -> void:
	for fixture in [[600.0, 200.0, false], [400.0, 0.0, true], [635.0, 200.0, false]]:
		var distance_exp: float = fixture[0]
		var mass_exp: float = fixture[1]
		var softened: bool = fixture[2]
		var r := pow(2.0, distance_exp)
		var mass := pow(2.0, mass_exp)
		var a := ordinary(mass, 0.0, 1e-10) if softened else hole(mass)
		var b := ordinary(mass, r, 1e-10) if softened else hole(mass, r)
		if softened: a.softening = r; b.softening = r
		var bodies: Array = [a, b]
		var expected := Physics.G * pow(2.0, mass_exp - 2.0 * distance_exp)
		if softened: expected /= 2.0 * sqrt(2.0)
		var label := kernel + " scaled force " + str(fixture)
		check(label + " structural mass domain", Structure.input_error({"type": a.type, "mass": mass}).is_empty())
		check(label + " independent finite acceleration", Physics.compute_accel(bodies) and expected > 0.0 and near(a.acc.x, expected) and a.acc.x == -b.acc.x)
		var result := step(bodies, 1.0, 1.0, kernel)
		check(label + " accepts tiny resolved kick", result.stepped == 1.0 and result.steps == 1 and not result.get("resolution_limited", false) and near(a.vel.x, expected) and a.vel.x == -b.vel.x)
	for fixture in [[-174.0, 300.0], [-30.0, 340.0]]:
		var r := pow(2.0, fixture[0])
		var mass := pow(2.0, 200.0)
		var softening := pow(2.0, fixture[1])
		var a := ordinary(mass, 0.0, 1e-80)
		var b := ordinary(mass, r, 1e-80)
		a.softening = softening; b.softening = softening
		var expected := Physics.G * pow(2.0, 200.0 + fixture[0] - 3.0 * fixture[1])
		var label := kernel + " subnormal kernel restored by mass " + str(fixture)
		check(label + " structural request", Structure.input_error({"type": a.type, "mass": mass, "softening": softening, "radiusKm": 1e-80}).is_empty())
		check(label + " independent acceleration", Physics.compute_accel([a, b]) and near(a.acc.x, expected) and a.acc.x == -b.acc.x)
		if fixture[0] == -30.0:
			var dt := pow(2.0, -160.0)
			var result := step([a, b], dt, dt, kernel)
			check(label + " resolved integrated kick", result.steps == 1 and result.stepped == dt and not result.get("resolution_limited", false) and near(a.vel.x, expected * dt) and a.vel.x == -b.vel.x)
	var tiny := 3.0 * pow(2.0, -538.0)
	check(kernel + " subnormal squared norm retains exact axis distance", Physics.distance_xyz(tiny, 0.0, 0.0) == tiny)
	var far: Array = [hole(1.0), hole(1.0, pow(2.0, 600.0))]
	var result := step(far, 1.0, 1.0, kernel)
	check(kernel + " genuinely sub-ULP force may round to zero", result.stepped == 1.0 and result.steps == 1 and not result.get("resolution_limited", false) and far[0].vel.x == 0.0 and far[1].vel.x == 0.0)
	var a := ordinary(0.7, -0.4, 0.02)
	var b := ordinary(1.3, 0.9, 0.03)
	var distance := b.pos.x - a.pos.x
	var d2 := distance * distance + Physics.pair_softening_sq(a, b)
	var expected := (distance * (1.0 / distance)) * ((Physics.G * distance / (d2 * sqrt(d2))) * b.mass)
	check(kernel + " ordinary force arithmetic remains bit exact", Physics.compute_accel([a, b]) and a.acc.x == expected)

func contact_and_limits(kernel: String) -> void:
	var bodies: Array = [hole(1.0), hole(1.0)]
	var blocked_initial := snapshot(bodies)
	var blocked: Dictionary = Derive.step_physics(bodies, 1e-6, 1e-6, 0.0, Callable(), Derive.STEP_GUARD) if kernel == "gd" else NBody.step_physics(bodies, 1e-6, 1e-6, 0.0, Callable(), Derive.STEP_GUARD)
	check(kernel + " exhausted guard leaves initial contact untouched", blocked.stepped == 0.0 and blocked.steps == Derive.STEP_GUARD and snapshot(bodies) == blocked_initial)
	for b: Body in bodies: b.vel.x = 1.0
	var events := [0]
	var merged := func(ev):
		events[0] += 1
		Derive.refresh_structure(ev.survivor)
		bodies.erase(ev.absorbed)
	var result := step(bodies, 5e-13, 1e-13, kernel, 0.0, merged)
	check(kernel + " coincident physical contact merges once", events[0] == 1 and bodies.size() == 1 and bodies[0].mass == 2.0)
	check(kernel + " contact preserves tiny clock progress", near(result.stepped, 5e-13) and near(bodies[0].pos.x, 5e-13) and not result.get("resolution_limited", false))
	var b := hole(1.0, 1e308)
	b.vel.x = 1e308
	var initial := snapshot([b])
	result = step([b], 10.0, 10.0, kernel)
	check(kernel + " overflowing candidate visibly limited", result.stepped == 0.0 and result.get("resolution_limited", false))
	check(kernel + " overflowing candidate rolls physical state back", snapshot([b]) == initial)
	b = hole(1.0, 1e308)
	b.vel.x = 2e307
	result = step([b], 5.0, 1.0, kernel)
	check(kernel + " later overflow retains accepted time", result.stepped == 3.0 and result.steps == 3 and result.get("resolution_limited", false))
	check(kernel + " later overflow restores last accepted state", near(b.pos.x, 1.6e308) and b.vel.x == 2e307)
	bodies = [ordinary(1e-12, 0.0, 1e-220), ordinary(1e-12, 1e-200, 1e-220)]
	for particle: Body in bodies: particle.softening = 1e-220
	initial = snapshot(bodies)
	result = step(bodies, 1e-8, 1e-8, kernel)
	check(kernel + " nonzero underflow-scale separation does not merge", bodies.size() == 2 and bodies[0].alive and bodies[1].alive)
	check(kernel + " unrepresentable tiny dynamics visibly limited", result.stepped == 0.0 and result.get("resolution_limited", false) and snapshot(bodies) == initial)
	bodies = circular_pair(1e-6, 1e-11)
	for compact: Body in bodies: compact.emits_gw = true
	initial = snapshot(bodies)
	result = step(bodies, 1e-17, 1e-17, kernel, -1e308)
	check(kernel + " unsafe reaction candidate visibly limited", result.stepped == 0.0 and result.get("resolution_limited", false))
	check(kernel + " unsafe reaction candidate restores physical state", snapshot(bodies) == initial)

func merger_prefix_cases(kernel: String) -> void:
	# Binary powers provide exact distinct positions despite the large offset.
	var base := pow(2.0, 700.0)
	var ulp := pow(2.0, 648.0)
	var dt := 1e-4
	for at_start in [true, false]:
		var label := kernel + (" initial" if at_start else " final-step") + " unsafe merger"
		var bodies: Array = [
			ordinary(1e-20, 0.0, 9.55e-5),
			ordinary(1e-20, 0.0 if at_start else 0.0002, 9.55e-5, 0.0 if at_start else -0.1),
			ordinary(1e100, base, 7.75 * ulp),
			ordinary(1e100, base if at_start else base + 16.0 * ulp, 7.75 * ulp, 0.0 if at_start else -ulp / dt),
		]
		var events := [0]
		var merged := func(ev):
			events[0] += 1
			bodies.erase(ev.absorbed)
		var result := step(bodies, dt, dt, kernel, 0.0, merged)
		check(label + " preserves valid prefix event", events[0] == 1 and bodies.size() == 3 and bodies[0].mass == 2e-20)
		check(label + " reports resolution limit", result.get("resolution_limited", false))
		check(label + " counts accepted time exactly", result.stepped == (0.0 if at_start else dt) and result.steps == (0 if at_start else 1))
		check(label + " keeps unsafe bodies finite and unmerged", bodies.size() == 3 and bodies[1].alive and bodies[2].alive and bodies[1].mass == 1e100 and bodies[2].mass == 1e100 and is_finite(bodies[1].pos.x) and is_finite(bodies[2].pos.x))

func merger_clock_case(kernel: String) -> void:
	var tiny_a := hole(1e-6, 1000.0)
	var tiny_b := hole(1e-6, 1001.0)
	var bodies: Array = [ordinary(1e-20, -10.0, 0.0955), ordinary(1e-20, -9.8, 0.0955, -0.1), tiny_a, tiny_b]
	var events := [0]
	var post_callback: Array = []
	var merged := func(ev):
		events[0] += 1
		bodies.erase(ev.absorbed)
		var mass := 1e-30
		var separation := 1e-30
		var speed := sqrt(Physics.G * 2.0 * mass / separation)
		for compact: Body in [tiny_a, tiny_b]:
			compact.mass = mass
			compact.rs = Physics.schwarzschild(mass)
			compact.contact_au = compact.rs
		tiny_a.pos.set_v(-separation / 2.0, 0.0, 0.0)
		tiny_b.pos.set_v(separation / 2.0, 0.0, 0.0)
		tiny_a.vel.set_v(0.0, -speed / 2.0, 0.0)
		tiny_b.vel.set_v(0.0, speed / 2.0, 0.0)
		post_callback.assign(snapshot(bodies))
	var result := step(bodies, 0.5, 0.125, kernel, 0.0, merged)
	check(kernel + " merger restart preserves accepted prefix", events[0] == 1 and result.stepped == 0.125 and result.steps == 1)
	check(kernel + " merger restart reports unrepresentable clock increment", result.get("resolution_limited", false))
	check(kernel + " merger restart leaves postcallback physical state untouched", not post_callback.is_empty() and snapshot(bodies) == post_callback)
	check(kernel + " merger restart tiny pair remains physically separate", tiny_a.pos.distance_to(tiny_b.pos) > tiny_a.rs + tiny_b.rs)

func orbit_error(mass: float, r: float, divisions: int, kernel: String) -> Dictionary:
	var bodies := circular_pair(mass, r)
	var a: Body = bodies[0]
	var b: Body = bodies[1]
	var period := TAU * sqrt(r * r * r / (Physics.G * 2.0 * mass))
	var initial_energy := -Physics.G * mass * mass / (2.0 * r)
	var frame := period / 128.0
	var energy_error := 0.0
	var radius_error := 0.0
	var accepted := 0.0
	var complete := true
	for i in 128:
		var result := step(bodies, frame, period / float(divisions), kernel)
		accepted += result.stepped
		if not near(result.stepped, frame) or result.get("resolution_limited", false) or bodies.size() != 2:
			complete = false
			break
		energy_error = maxf(energy_error, absf(Derive.total_energy(bodies) / initial_energy - 1.0))
		radius_error = maxf(radius_error, absf(a.pos.distance_to(b.pos) / r - 1.0))
	var phase_error := sqrt(pow(a.pos.x + r / 2.0, 2.0) + a.pos.y * a.pos.y) / (r / 2.0)
	return {"complete": complete and near(accepted, period), "energy": energy_error, "radius": radius_error, "phase": phase_error}

func orbit_cases(kernel: String) -> void:
	for fixture in [[1.0, 1e-5], [1e-6, 5e-10], [1e-12, 0.1]]:
		var mass: float = fixture[0]
		var r: float = fixture[1]
		var label := kernel + " circular m=%s r=%s" % [mass, r]
		check(label + " outside contact in structural domain", r > 2.0 * Physics.schwarzschild(mass) and Structure.input_error({"type": "bh", "mass": mass}).is_empty())
		var coarse := orbit_error(mass, r, 512, kernel)
		var fine := orbit_error(mass, r, 1024, kernel)
		check(label + " accepted complete physical period", coarse.complete and fine.complete)
		check(label + " energy bound", fine.complete and fine.energy < 1e-8)
		check(label + " radius bound", fine.complete and fine.radius < 3e-5)
		check(label + " closes orbit", fine.complete and fine.phase < 1e-4)
		check(label + " phase converges with halved step", coarse.complete and fine.complete and fine.phase > 0.0 and coarse.phase > fine.phase * 3.5 and coarse.phase < fine.phase * 4.5)
		print("NUMERICALCHECK ORBIT %s coarse=%s fine=%s" % [label, JSON.stringify(coarse), JSON.stringify(fine)])

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check("native extension loaded", NBody.native_available())
	if not NBody.native_available():
		print("NUMERICALCHECK DONE checks=%d failures=%d" % [checks, failures])
		quit(1)
		return
	tiny_forces()
	energy_scale_cases()
	for kernel in ["gd", "native"]:
		request_cases(kernel)
		lost_drift_cases(kernel)
		force_scale_cases(kernel)
		contact_and_limits(kernel)
		merger_prefix_cases(kernel)
		merger_clock_case(kernel)
		orbit_cases(kernel)
	print("NUMERICALCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
