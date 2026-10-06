extends SceneTree

# Sampled extent bounds flag hierarchy loss/ejection; passing is not a stability theorem.
# Orbit/step overrides select diagnostics; only authored inputs emit the baseline marker.
const DEFAULT_YEARS := 60000.0
const ENERGY_BOUND := 1e-6
const MOMENTUM_BOUND := 1e-7 # M☉ AU/year
const WORLD_BOUND_AU := 10.0
const GAMMA_BOUND_AU := 100.0
const SAMPLE_FRAMES := 1000

var bodies := []
var merged := 0
var failures := 0
var first_failure := ""
var marker := "STABILITYCHECK"

func reject(reason: String) -> void:
	failures += 1
	if first_failure.is_empty(): first_failure = reason
	printerr(marker, " FAIL ", reason)

func _initialize() -> void:
	call_deferred("_run")

func body_states() -> Array:
	var states := []
	for b: Body in bodies:
		var exact := PackedByteArray()
		exact.resize(56)
		var values := [b.mass, b.pos.x, b.pos.y, b.pos.z, b.vel.x, b.vel.y, b.vel.z]
		for i in values.size(): exact.encode_double(i * 8, values[i])
		states.append({"id": b.id, "mass": b.mass, "pos_au": b.pos.to_array(), "vel_au_per_year": b.vel.to_array(),
			"name": b.name, "type": b.type, "softening_au": b.softening, "contact_au": b.contact_au,
			"physical_f64_le_hex": exact.hex_encode()})
	return states

# Point-mass two-body elements describe snapshots; four-body perturbations and
# Plummer softening mean their binding sign is not an escape/stability criterion.
static func osculating(relative_pos: DVec3, relative_vel: DVec3, total_mass: float) -> Dictionary:
	var radius := relative_pos.length()
	var mu := Physics.G * total_mass
	if not relative_pos.is_finite_v() or not relative_vel.is_finite_v() or not is_finite(radius) or radius <= 0.0 or not is_finite(mu) or mu <= 0.0:
		return {"valid": false}
	var angular := relative_pos.cross(relative_vel)
	var energy := 0.5 * relative_vel.length_sq() - mu / radius
	var eccentricity := relative_vel.cross(angular).scale_in(1.0 / mu).sub_in(relative_pos.scaled(1.0 / radius)).length()
	var pericenter := angular.length_sq() / (mu * (1.0 + eccentricity))
	var radial_velocity := relative_pos.dot(relative_vel) / radius
	var semimajor = -mu / (2.0 * energy) if energy != 0.0 else null
	var apocenter = float(semimajor) * (1.0 + eccentricity) if energy < 0.0 else null
	if not angular.is_finite_v() or not is_finite(energy) or not is_finite(eccentricity) or not is_finite(pericenter) or not is_finite(radial_velocity) or (semimajor != null and not is_finite(semimajor)) or (apocenter != null and not is_finite(apocenter)):
		return {"valid": false}
	return {"valid": true, "separation_au": radius, "radial_velocity_au_per_year": radial_velocity,
		"point_mass_specific_energy_au2_per_year2": energy, "specific_angular_momentum_au2_per_year": angular.to_array(),
		"eccentricity": eccentricity, "semimajor_axis_au": semimajor, "pericenter_au": pericenter, "apocenter_au": apocenter}

static func orbital_diagnostics(state_bodies: Array) -> Dictionary:
	if state_bodies.size() != 4 or not Physics.finite_state(state_bodies): return {"valid": false}
	for body: Body in state_bodies:
		if not body.alive: return {"valid": false}
	var a: Body = state_bodies[0]
	var b: Body = state_bodies[1]
	var gamma: Body = state_bodies[2]
	var world: Body = state_bodies[3]
	var binary_mass := a.mass + b.mass
	var inner_mass := binary_mass + world.mass
	var center := a.pos.scaled(a.mass).add_scaled_in(b.pos, b.mass).scale_in(1.0 / binary_mass)
	var velocity := a.vel.scaled(a.mass).add_scaled_in(b.vel, b.mass).scale_in(1.0 / binary_mass)
	var outer_center := center.scaled(binary_mass).add_scaled_in(world.pos, world.mass).scale_in(1.0 / inner_mass)
	var outer_velocity := velocity.scaled(binary_mass).add_scaled_in(world.vel, world.mass).scale_in(1.0 / inner_mass)
	var binary := osculating(b.pos.sub(a.pos), b.vel.sub(a.vel), binary_mass)
	var planet := osculating(world.pos.sub(center), world.vel.sub(velocity), inner_mass)
	var outer := osculating(gamma.pos.sub(outer_center), gamma.vel.sub(outer_velocity), inner_mass + gamma.mass)
	if not binary.valid or not planet.valid or not outer.valid: return {"valid": false}
	return {"valid": true, "binary": binary, "world": planet, "gamma": outer,
		"world_pericenter_to_binary_apocenter": float(planet.pericenter_au) / float(binary.apocenter_au) if binary.apocenter_au != null and float(binary.apocenter_au) > 0.0 else null,
		"gamma_pericenter_to_world_apocenter": float(outer.pericenter_au) / float(planet.apocenter_au) if planet.apocenter_au != null and float(planet.apocenter_au) > 0.0 else null}

func sample_orbits(summary: Dictionary, snapshot: Dictionary, years: float) -> void:
	if not snapshot.valid:
		reject("nonfinite or degenerate orbital diagnostic at year %s" % years)
		return
	for key in ["binary", "world", "gamma"]:
		var orbit: Dictionary = snapshot[key]
		var row: Dictionary = summary.get(key, {"sampled_min_pericenter_au": orbit.pericenter_au,
			"sampled_max_eccentricity": orbit.eccentricity, "sampled_max_point_mass_specific_energy_au2_per_year2": orbit.point_mass_specific_energy_au2_per_year2,
			"first_sampled_nonnegative_point_mass_energy_years": null})
		row.sampled_min_pericenter_au = minf(row.sampled_min_pericenter_au, orbit.pericenter_au)
		row.sampled_max_eccentricity = maxf(row.sampled_max_eccentricity, orbit.eccentricity)
		row.sampled_max_point_mass_specific_energy_au2_per_year2 = maxf(row.sampled_max_point_mass_specific_energy_au2_per_year2, orbit.point_mass_specific_energy_au2_per_year2)
		if row.first_sampled_nonnegative_point_mass_energy_years == null and orbit.point_mass_specific_energy_au2_per_year2 >= 0.0:
			row.first_sampled_nonnegative_point_mass_energy_years = years
		summary[key] = row
	for key in ["world_pericenter_to_binary_apocenter", "gamma_pericenter_to_world_apocenter"]:
		if snapshot[key] != null:
			summary["sampled_min_" + key] = minf(summary.get("sampled_min_" + key, snapshot[key]), snapshot[key])

func rotate_world_orientation(angle: float) -> void:
	var binary_mass: float = bodies[0].mass + bodies[1].mass
	var center: DVec3 = bodies[0].pos.scaled(bodies[0].mass).add_scaled_in(bodies[1].pos, bodies[1].mass).scale_in(1.0 / binary_mass)
	var velocity: DVec3 = bodies[0].vel.scaled(bodies[0].mass).add_scaled_in(bodies[1].vel, bodies[1].mass).scale_in(1.0 / binary_mass)
	var c := cos(angle)
	var s := sin(angle)
	for pair in [[bodies[3].pos, center], [bodies[3].vel, velocity]]:
		var value: DVec3 = pair[0]
		var origin: DVec3 = pair[1]
		var x := value.x - origin.x
		var z := value.z - origin.z
		value.x = origin.x + c * x - s * z
		value.z = origin.z + s * x + c * z

func _run() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv[0] not in ["years", "report", "max_step", "world_rotation", "world_eccentricity", "step_divisor"] or args.has(kv[0]):
			reject("unknown or repeated option: %s" % kv[0])
			quit(1)
			return
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	for key in ["years", "max_step", "world_rotation", "world_eccentricity"]:
		if args.has(key) and not String(args[key]).is_valid_float():
			reject("%s must be a number" % key)
			quit(1)
			return
	var preset: Dictionary = Presets.PRESETS.trisolaris
	var target_years := float(args.get("years", DEFAULT_YEARS))
	var max_step := float(args.get("max_step", preset.maxStep))
	var world_rotation := float(args.get("world_rotation", 0.0))
	var world_eccentricity = float(args.world_eccentricity) if args.has("world_eccentricity") else null
	var step_divisor := 1
	if args.has("step_divisor"):
		if not String(args.step_divisor).is_valid_int() or int(args.step_divisor) not in [1, 2, 4, 8] or args.has("max_step"):
			reject("step_divisor must be 1, 2, 4 or 8 and cannot accompany max_step")
			quit(1)
			return
		step_divisor = int(args.step_divisor)
		max_step = float(preset.maxStep) / step_divisor
	var mode := "diagnostic" if args.has("max_step") or args.has("world_rotation") or args.has("world_eccentricity") or args.has("step_divisor") else "baseline"
	marker = "STABILITYDIAGNOSTIC" if mode == "diagnostic" else "STABILITYCHECK"
	var report_path: String = args.get("report", "")
	if not is_finite(target_years) or target_years <= 0.0 or not is_finite(max_step) or max_step <= 0.0 or max_step > float(preset.maxStep) or not is_finite(world_rotation):
		reject("years must be finite and positive; max_step must be positive and no larger than the authored cap; world_rotation must be finite")
		quit(1)
		return
	if world_eccentricity != null and (not is_finite(world_eccentricity) or world_eccentricity < 0.0 or world_eccentricity >= 1.0):
		reject("world_eccentricity must be finite and in [0, 1)")
		quit(1)
		return
	if args.has("report") and (report_path.is_empty() or not report_path.is_absolute_path()):
		reject("report must be an absolute path")
		quit(1)
		return
	if not NBody.native_available():
		reject("native kernel required for bounded long run")
		quit(1)
		return
	var initial_masses := {}
	var specs: Array = Presets._build_trisolaris(world_eccentricity) if world_eccentricity != null else preset.build.call()
	for spec in specs:
		var body := Derive.new_body(bodies.size() + 1, spec)
		bodies.append(body)
		initial_masses[body.id] = body.mass
	if bodies.size() != 4:
		reject("Trisolaris must start with four bodies")
		quit(1)
		return
	if world_rotation != 0.0: rotate_world_orientation(world_rotation)
	var initial_states := body_states()
	var initial_mass := 0.0
	var initial_momentum := DVec3.new()
	for b: Body in bodies:
		initial_mass += b.mass
		initial_momentum.add_scaled_in(b.vel, b.mass)
	var initial_energy := Derive.total_energy(bodies)
	if not is_finite(initial_energy) or initial_energy == 0.0:
		reject("initial energy must be finite and nonzero")
		quit(1)
		return
	var clock := SimState.new()
	var years := 0.0
	var frames := 0
	var steps := 0
	var max_steps := 0
	var max_drift := 0.0
	var max_momentum_error := 0.0
	var max_world_distance := 0.0
	var max_gamma_distance := 0.0
	var wall_start := Time.get_ticks_usec()
	var frame_years := float(preset.timeScale) / 60.0
	var initial_orbits := orbital_diagnostics(bodies)
	var orbit_summary := {}
	sample_orbits(orbit_summary, initial_orbits, years)
	if failures > 0:
		quit(1)
		return
	var on_merger := func(_ev): merged += 1
	print(marker, " CONFIG mode=", mode, " clock=compensated_accepted_time target_years=", target_years, " frame_years=", frame_years, " max_step=", max_step,
		" authored_max_step=", preset.maxStep, " world_rotation=", world_rotation,
		" energy_bound=", ENERGY_BOUND, " momentum_bound=", MOMENTUM_BOUND, " world_bound_au=", WORLD_BOUND_AU,
		" gamma_bound_au=", GAMMA_BOUND_AU, " sample_frames=", SAMPLE_FRAMES, " native=true")
	while (target_years - clock.sim_years) - clock.year_remainder > 0.0 and failures == 0:
		var requested := minf(frame_years, (target_years - clock.sim_years) - clock.year_remainder)
		var result := NBody.step_physics(bodies, requested, max_step, 0.0, on_merger)
		var accepted: float = result.stepped
		if not is_finite(accepted) or accepted <= 0.0 or accepted > requested or not clock.can_advance_years(accepted):
			reject("invalid accepted interval at year %s" % years)
			break
		clock.advance_years(accepted)
		years = clock.sim_years
		frames += 1
		steps += int(result.steps)
		max_steps = maxi(max_steps, int(result.steps))
		if absf(accepted - requested) > maxf(1e-14, requested * 1e-12) or bool(result.resolution_limited) or int(result.steps) >= Derive.STEP_GUARD:
			reject("incomplete integration or frame guard at year %s" % years)
		if merged > 0 or bodies.size() != 4:
			reject("merger or body-count change at year %s" % years)
		if failures > 0: break
		if frames % SAMPLE_FRAMES == 0 or years >= target_years:
			sample_orbits(orbit_summary, orbital_diagnostics(bodies), years)
			var mass := 0.0
			var momentum := DVec3.new()
			for b: Body in bodies:
				mass += b.mass
				momentum.add_scaled_in(b.vel, b.mass)
				if not b.alive or not b.pos.is_finite_v() or not b.vel.is_finite_v() or not is_finite(b.mass):
					reject("invalid body state at year %s" % years)
				if b.mass != initial_masses.get(b.id): reject("body mass changed at year %s" % years)
			var momentum_error := momentum.distance_to(initial_momentum)
			max_momentum_error = maxf(max_momentum_error, momentum_error)
			if mass != initial_mass or not is_finite(momentum_error) or momentum_error > MOMENTUM_BOUND:
				reject("mass/momentum bound exceeded at year %s" % years)
			var drift := absf((Derive.total_energy(bodies) - initial_energy) / initial_energy)
			if not is_finite(drift) or drift > ENERGY_BOUND:
				reject("energy drift %s exceeds declared bound at year %s" % [drift, years])
			max_drift = maxf(max_drift, drift)
			var inner: DVec3 = bodies[0].pos.scaled(bodies[0].mass).add_scaled_in(bodies[1].pos, bodies[1].mass).scale_in(1.0 / (bodies[0].mass + bodies[1].mass))
			var world_distance: float = bodies[3].pos.distance_to(inner)
			var gamma_distance: float = bodies[2].pos.distance_to(inner)
			max_world_distance = maxf(max_world_distance, world_distance)
			max_gamma_distance = maxf(max_gamma_distance, gamma_distance)
			if not is_finite(world_distance) or not is_finite(gamma_distance) or world_distance > WORLD_BOUND_AU or gamma_distance > GAMMA_BOUND_AU:
				reject("sampled hierarchy extent exceeded at year %s: world=%s AU gamma=%s AU" % [years, world_distance, gamma_distance])
			if frames % 171000 == 0:
				print(marker, " PROGRESS accepted_years=", years, " max_drift=", max_drift)
	if failures == 0 and (years != target_years or clock.year_remainder != 0.0): reject("incomplete target integration")
	var report := {"mode": mode, "authored_max_step": float(preset.maxStep), "max_step": max_step,
		"step_divisor": step_divisor, "world_eccentricity_override": world_eccentricity,
		"world_eccentricity_override_convention": "same Presets._build_trisolaris constructor with only world eccentricity replaced",
		"godot_version": Engine.get_version_info(), "operating_system": OS.get_name(), "architecture": Engine.get_architecture_name(),
		"force_model": "symmetric RMS-Plummer ordinary pairs; conservative Newtonian motion; GW boost zero",
		"clock_method": "SimState.advance_years compensated accepted intervals; final budget includes remainder",
		"accepted_years_remainder": clock.year_remainder,
		"orbital_diagnostic_model": "unsoftened Jacobi two-body point-mass snapshots; binding sign is not a four-body escape criterion",
		"initial_orbits": initial_orbits, "final_orbits": orbital_diagnostics(bodies), "sampled_orbit_summary": orbit_summary,
		"state_encoding_version": 1,
		"exact_state_layout": "little-endian binary64: mass, position xyz (AU), velocity xyz (AU/year)",
		"world_rotation_radians": world_rotation, "frame_years": frame_years, "native": true,
		"initial_energy": initial_energy, "initial_momentum": initial_momentum.to_array(),
		"initial_states": initial_states, "final_states": body_states(),
		"target_years": target_years, "accepted_years": years, "frames": frames, "substeps": steps,
		"max_substeps_per_frame": max_steps, "energy_bound": ENERGY_BOUND, "sampled_max_relative_energy_drift": max_drift,
		"momentum_bound": MOMENTUM_BOUND, "sampled_max_momentum_error": max_momentum_error,
		"world_bound_au": WORLD_BOUND_AU, "gamma_bound_au": GAMMA_BOUND_AU,
		"sampled_max_world_distance_au": max_world_distance, "sampled_max_gamma_distance_au": max_gamma_distance,
		"sample_interval_frames": SAMPLE_FRAMES, "mergers": merged, "bodies": bodies.size(), "mass": initial_mass,
		"wall_seconds": (Time.get_ticks_usec() - wall_start) / 1e6, "failures": failures, "first_failure": first_failure}
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file == null:
			reject("cannot write report: %s" % report_path)
		else:
			file.store_string(JSON.stringify(report, "\t", true, true))
			file.close()
	print(marker, " METRICS max_world_distance_au=", max_world_distance, " max_gamma_distance_au=", max_gamma_distance,
		" max_relative_energy_drift=", max_drift, " max_momentum_error=", max_momentum_error, " frames=", frames, " substeps=", steps)
	print(marker, " DONE mode=", mode, " target_years=", target_years, " accepted_years=", years, " failures=", failures)
	quit(1 if failures else 0)
