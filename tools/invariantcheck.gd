extends SceneTree

# Independent invariants complement reference parity. Run with:
# Godot --headless --path . --script res://tools/invariantcheck.gd
var failures := 0
var checks := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func particle(mass: float, position: DVec3, velocity: DVec3) -> Body:
	var b := Body.new()
	b.mass = mass
	b.pos = position
	b.vel = velocity
	b.radius = 0.01
	b.contact_au = b.radius
	b.softening = 0.2
	return b

func totals(bodies: Array) -> Dictionary:
	var mass := 0.0
	var momentum := DVec3.new()
	var center := DVec3.new()
	for b: Body in bodies:
		if not b.alive: continue
		mass += b.mass
		momentum.add_scaled_in(b.vel, b.mass)
		center.add_scaled_in(b.pos, b.mass)
	return {"mass": mass, "momentum": momentum, "center": center.scale_in(1.0 / mass)}

func collision_cases() -> void:
	for order in [[1, 2, 4], [1, 4, 2], [2, 1, 4], [2, 4, 1], [4, 1, 2], [4, 2, 1]]:
		for kernel in ["direct", "gd", "native"]:
			if kernel == "native" and not NBody.native_available(): continue
			var bodies: Array = []
			for m in order:
				var b := particle(float(m), DVec3.new(), DVec3.new(float(m), -float(m), 0.5))
				b.id = m
				bodies.append(b)
			var before := totals(bodies)
			if kernel == "direct":
				Physics.resolve_collisions(bodies)
			elif kernel == "gd":
				Derive.step_physics(bodies, 1e-8, 1e-8, 0.0)
			else:
				NBody.step_physics(bodies, 1e-8, 1e-8, 0.0)
			var after := totals(bodies)
			var live := 0
			for b: Body in bodies:
				if b.alive: live += 1
			check("%s collision %s mass/momentum" % [kernel, order], live == 1 and after.mass == 7.0 and after.momentum.distance_to(before.momentum) < 1e-12)
			var expected: DVec3 = before.center if kernel == "direct" else before.center.add(before.momentum.scaled(1e-8 / before.mass))
			check("%s collision %s center" % [kernel, order], after.center.distance_to(expected) < 1e-12)

func force_and_energy() -> void:
	var a := particle(2.0, DVec3.new(-0.3, 0.1, 0.4), DVec3.new())
	var b := particle(5.0, DVec3.new(0.7, -0.2, 0.8), DVec3.new())
	a.softening = 0.03
	b.softening = 0.7
	Physics.compute_accel([a, b])
	var net := a.acc.scaled(a.mass).add_scaled_in(b.acc, b.mass)
	check("unequal-softening force antisymmetry", net.length() < 1e-12)
	var acc := a.acc.clone()
	Physics.compute_accel([b, a])
	check("force independent of body order", a.acc.distance_to(acc) < 1e-12)
	var x := a.pos.x
	var h := 1e-6
	a.pos.x = x + h
	var plus := Derive.total_energy([a, b])
	a.pos.x = x - h
	var minus := Derive.total_energy([a, b])
	a.pos.x = x
	check("force matches energy gradient", absf(-(plus - minus) / (2.0 * h) - a.mass * a.acc.x) < 1e-7)
	var E := Derive.total_energy([a, b])
	for i in 1000: Physics.integrate([a, b], 1e-6)
	check("fixed-softening Verlet energy", absf(Derive.total_energy([a, b]) / E - 1.0) < 1e-8)

func compact_force_cases() -> void:
	for companion_type in ["bh", "star"]:
		var label := "unequal BH/%s" % companion_type
		var separation := 0.03
		var m1 := 2.0
		var m2 := 5.0
		var speed := Physics.circular_speed(m1 + m2, separation)
		var specs := [
			{"type": "bh", "mass": m1, "pos": [-separation * m2 / (m1 + m2), 0.0, 0.0], "vel": [0.0, -speed * m2 / (m1 + m2), 0.0]},
			{"type": companion_type, "mass": m2, "pos": [separation * m1 / (m1 + m2), 0.0, 0.0], "vel": [0.0, speed * m1 / (m1 + m2), 0.0]},
		]
		var a := Derive.new_body(1, specs[0])
		var b := Derive.new_body(2, specs[1])
		check(label + " outside physical contact", separation > a.contact_au + b.contact_au)
		Physics.compute_accel([a, b])
		var force := a.acc.scaled(a.mass)
		check(label + " force antisymmetry", force.add_scaled_in(b.acc, b.mass).length() < a.acc.length() * a.mass * 1e-12)
		var acceleration := a.acc.clone()
		Physics.compute_accel([b, a])
		check(label + " force order independence", a.acc.distance_to(acceleration) < acceleration.length() * 1e-12)
		var x := a.pos.x
		var h := separation * 1e-5
		a.pos.x = x + h
		var plus := Derive.total_energy([a, b])
		a.pos.x = x - h
		var minus := Derive.total_energy([a, b])
		a.pos.x = x
		check(label + " force matches energy gradient", absf(-(plus - minus) / (2.0 * h) - a.mass * a.acc.x) < absf(a.mass * a.acc.x) * 1e-8)
		var period := TAU * separation / speed
		var dt := period / 2000.0
		for kernel in ["gd", "native"]:
			if kernel == "native" and not NBody.native_available(): continue
			var bodies: Array = [Derive.new_body(1, specs[0]), Derive.new_body(2, specs[1])]
			var before := totals(bodies)
			var energy := Derive.total_energy(bodies)
			var max_energy_error := 0.0
			var accepted := 0.0
			for i in 2000:
				var result: Dictionary = Derive.step_physics(bodies, dt, dt, 0.0) if kernel == "gd" else NBody.step_physics(bodies, dt, dt, 0.0)
				accepted += result.stepped
				if i % 100 == 0:
					max_energy_error = maxf(max_energy_error, absf(Derive.total_energy(bodies) / energy - 1.0))
			var after := totals(bodies)
			check(label + " %s accepted orbit" % kernel, bodies.size() == 2 and absf(accepted / period - 1.0) < 1e-12)
			check(label + " %s momentum" % kernel, after.momentum.distance_to(before.momentum) < 1e-9)
			var expected: DVec3 = before.center.add(before.momentum.scaled(period / before.mass))
			check(label + " %s center trajectory" % kernel, after.center.distance_to(expected) < 1e-12)
			check(label + " %s orbit energy" % kernel, max_energy_error < 1e-8)

func contact_cases() -> void:
	for spec in [
		{"type": "star", "mass": 1.0},
		{"type": "planet", "mass": 3e-6, "radiusKm": 6371.0},
		{"type": "white-dwarf", "mass": 0.6, "radiusSun": 0.02},
		{"type": "star", "mass": 2.0, "radiusSun": 3.0},
		{"type": "star", "mass": 1.0, "contactAU": 0.03},
		{"type": "bh", "mass": 10.0},
	]:
		var b := Derive.new_body(1, spec)
		var expected := float(spec.get("contactAU", b.rs if b.type == "bh" else b.radius))
		check("%s derives contact without visuals" % spec, b.contact_au == expected)
		for scene_scale in [0.5, 2.0, 1000.0]:
			for true_scale in [false, true]:
				b.radius_scene = Derive.render_radius(b, spec, b.mass, scene_scale, 4.0, true_scale)
				check("%s contact at scale %s true %s" % [spec, scene_scale, true_scale], Derive.contact_au(b, spec) == expected)
	var model := Derive.new_body(1, {"type": "star", "mass": 1.0})
	var old_radius := model.radius
	model.mass = 2.0
	Derive.refresh_structure(model)
	check("mass refresh updates modeled contact", model.radius != old_radius and model.contact_au == model.radius and model.radius == model.structure.radiusAU)
	for spec in [{"type": "planet", "mass": 3e-6, "radiusKm": 6371.0}, {"type": "star", "mass": 1.0, "radiusSun": 2.0}, {"type": "star", "mass": 1.0, "contactAU": 0.03}]:
		var b := Derive.new_body(1, spec)
		var contact := b.contact_au
		b.mass *= 2.0
		Derive.refresh_structure(b)
		check("mass refresh preserves measurement/override %s" % spec, b.contact_au == contact)
	var a := Derive.new_body(1, {"type": "star", "mass": 1.0})
	var b := Derive.new_body(2, {"type": "star", "mass": 1.0, "pos": [0.05, 0.0, 0.0]})
	for true_scale in [false, true]:
		for body: Body in [a, b]:
			body.radius_scene = Derive.render_radius(body, body.spec, body.mass, 2.0, 1.0, true_scale)
			body.contact_au = Derive.contact_au(body, body.spec)
		check("separate photospheres survive true scale %s" % true_scale, Physics.resolve_collisions([a, b]).is_empty())

# Golden value uses the project's exact G=4π² and c=63241.077 AU/yr convention.
const RS_PER_MSUN := 1.9742003183427407e-8

func horizon_close(actual: float, expected: float) -> bool:
	return is_finite(actual) and absf(actual - expected) <= absf(expected) * 1e-13

func horizon_cases() -> void:
	for mass in [1.0, 12.0, 4e6]:
		var expected: float = mass * RS_PER_MSUN
		for override in [-1.0, 0.0, 0.5, 1e9]:
			var spec := {"type": "bh", "mass": mass, "rs": override, "contactAU": 0.7,
				"radiusSun": 120.0, "radiusKm": 900000.0}
			var b := Derive.new_body(1, spec.duplicate(true))
			check("BH override %s mass %s cannot change physical horizon" % [override, mass],
				horizon_close(b.rs, expected) and horizon_close(b.contact_au, expected))
			check("BH authored horizon is absent or canonical", not b.spec.has("rs") or horizon_close(float(b.spec.rs), expected))
			for spin in [0.0, 0.6]:
				var spinning := spec.duplicate(true)
				spinning.spinFrac = spin
				var st := Structure.structure_of(spinning)
				var horizon: float = expected * 0.5 * (1.0 + sqrt(1.0 - spin * spin))
				check("BH override cannot change structure mass %s spin %s" % [mass, spin],
					horizon_close(float(st.rs), expected) and horizon_close(float(st.horizonAU), horizon)
					and horizon_close(float(st.shadowAU), sqrt(27.0) * expected / 2.0))
			b.rs = 0.25
			b.contact_au = 0.75
			b.spec.rs = 0.5
			b.mass *= 2.0
			Derive.refresh_structure(b)
			check("mass refresh repairs cached BH horizon/contact/structure", horizon_close(b.rs, expected * 2.0)
				and horizon_close(b.contact_au, expected * 2.0) and horizon_close(float(b.structure.rs), expected * 2.0))
			check("mass refresh sanitizes authored horizon", not b.spec.has("rs") or horizon_close(float(b.spec.rs), expected * 2.0))
			for scene_scale in [0.5, 1000.0]:
				var true_size := Derive.render_radius(b, b.spec, b.mass, scene_scale, 100.0, true)
				var boosted := Derive.render_radius(b, b.spec, b.mass, scene_scale, 100.0, false)
				check("BH true-scale render is the physical horizon", horizon_close(true_size, expected * 2.0 * scene_scale))
				check("BH boosted render is never below the physical horizon", is_finite(boosted) and boosted >= true_size)
				check("BH contact ignores rendered magnification", horizon_close(Derive.contact_au(b, b.spec), expected * 2.0))
	var a := Derive.new_body(1, {"type": "bh", "mass": 12.0, "rs": 0.5})
	var b := Derive.new_body(2, {"type": "bh", "mass": 8.0, "rs": 0.5, "pos": [0.05, 0.0, 0.0]})
	check("authored horizons cannot create distant physical contact", Physics.resolve_collisions([a, b]).is_empty() and a.alive and b.alive)
	# The sandbox hole is ~30 km; boosted mode must still draw it beside its boosted neighbours.
	var drawn := []
	for mass in [1.0, 10.0, 50.0]:
		drawn.append(Derive.hole_render_radius(mass * RS_PER_MSUN, 2.0, 1.0, false))
	check("boosted stellar-mass hole is drawn at planet scale or larger", drawn[1] >= Derive.BOOST_RADIUS.planet)
	check("boosted hole size follows mass", drawn[0] < drawn[1] and drawn[1] < drawn[2])

func measured_structure_cases() -> void:
	for spec in [
		{"type": "planet", "mass": 3e-6, "radiusKm": 6371.0},
		{"type": "gas-giant", "mass": 9.5e-4, "radiusKm": 90000.0},
		{"type": "star", "mass": 1.0, "radiusSun": 2.0},
		{"type": "star", "mass": 1.0, "radiusKm": 800000.0},
		{"type": "white-dwarf", "mass": 0.6, "radiusSun": 0.02},
		{"type": "white-dwarf", "mass": 0.6, "radiusKm": 10000.0},
		{"type": "neutron", "mass": 1.4, "radiusKm": 14.0},
	]:
		var b := Derive.new_body(1, spec)
		var expected := float(spec.radiusKm) * Physics.AU_PER_KM if spec.has("radiusKm") else float(spec.radiusSun) * Physics.AU_PER_RSUN
		check("canonical measured radius %s" % spec, b.radius == expected and b.structure.radiusAU == expected and b.contact_au == expected)
		if b.structure.has("radiusSun"):
			check("canonical radiusSun cache %s" % spec, b.radius_sun == b.structure.radiusSun)
		if spec.type in ["star", "white-dwarf"]:
			check("canonical body luminosity %s" % spec, b.luminosity == b.structure.luminosity and b.teff == b.structure.teff)
		var larger: Dictionary = spec.duplicate()
		larger.spinFrac = 0.2
		var measured_key := "radiusKm" if spec.has("radiusKm") else "radiusSun"
		larger[measured_key] *= 2.0
		var smaller: Dictionary = spec.duplicate()
		smaller.spinFrac = 0.2
		var small := Structure.structure_of(smaller)
		var big := Structure.structure_of(larger)
		check("density follows measured radius %s" % spec, absf(big.density / small.density - 0.125) < 1e-12)
		check("rotation follows measured radius %s" % spec, absf(big.rotation.periodSec / small.rotation.periodSec - sqrt(8.0)) < 1e-12 and absf(big.radiusEqAU / small.radiusEqAU - 2.0) < 1e-12)
		if spec.type == "neutron":
			check("neutron gravity/compactness follow measurement", absf(big.surfaceGravity / small.surfaceGravity - 0.25) < 1e-12 and absf(big.compactness / small.compactness - 0.5) < 1e-12)
		if spec.type == "white-dwarf":
			check("white-dwarf luminosity follows measured area", absf(big.luminosity / small.luminosity - 4.0) < 1e-12)
	var both := Structure.structure_of({"type": "star", "mass": 1.0, "radiusSun": 3.0, "radiusKm": 800000.0})
	check("radiusKm wins conflicting radius measurements", both.radiusAU == 800000.0 * Physics.AU_PER_KM)
	var dwarf := Structure.structure_of({"type": "white-dwarf", "mass": 0.6, "radiusSun": 0.02, "luminosity": 0.5})
	check("measured luminosity remains authoritative", dwarf.luminosity == 0.5)
	var promoted := Structure.structure_of({"type": "planet", "mass": 1.0, "radiusKm": 6371.0, "luminosity": 0.001, "teff": 300.0})
	var star := Structure.structure_of({"type": "star", "mass": 1.0})
	check("ignition discards previous type measurements", promoted.type == "star" and promoted.radiusAU == star.radiusAU and promoted.teff == star.teff and promoted.luminosity == star.luminosity)


func equivalent_kernels() -> void:
	if not NBody.native_available():
		print("SKIP native equivalence: NBodyKernel unavailable")
		return
	for compact in [false, true]:
		var gd: Array = []
		var native: Array = []
		for mass in [2.0, 5.0]:
			for bodies in [gd, native]:
				var b := particle(mass, DVec3.new(mass - 3.0, 0.1, 0.0), DVec3.new(0.0, mass * 0.2, 0.03))
				b.softening = mass * 0.1
				if compact:
					b.type = "bh"
					b.rs = Physics.schwarzschild(mass)
				bodies.append(b)
		var a := Derive.step_physics(gd, 0.01, 1e-4, 0.0)
		var b := NBody.step_physics(native, 0.01, 1e-4, 0.0)
		check("kernel timing compact=%s" % compact, a.steps == b.steps and absf(a.stepped - b.stepped) < 1e-15)
		for i in gd.size():
			check("kernel state compact=%s body=%s" % [compact, i], gd[i].pos.distance_to(native[i].pos) < 1e-13 and gd[i].vel.distance_to(native[i].vel) < 1e-13 and gd[i].mass == native[i].mass)

func _init() -> void:
	collision_cases()
	force_and_energy()
	compact_force_cases()
	contact_cases()
	horizon_cases()
	measured_structure_cases()
	equivalent_kernels()
	print("INVARIANTCHECK DONE checks=%s failures=%s native=%s" % [checks, failures, NBody.native_available()])
	quit(1 if failures else 0)
