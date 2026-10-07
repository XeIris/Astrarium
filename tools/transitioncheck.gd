extends Node

# Verify spin, physical horizons and remnants through the real stage.
# Godot --path . res://tools/transitioncheck.tscn -- mode=sandbox
const CourseCheck = preload("res://tools/coursecheck.gd")
var catcher := CourseCheck.Catch.new()
var failures := 0
var checks := 0
var stage: Node

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func render_frames() -> void:
	for i in 3:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame

func spin_checks() -> void:
	stage.clear_bodies()
	var b: Body = stage.spawn_body(Starcat.star_spec("crab"))
	var period := 0.0335
	check("catalogue spin period is 33.5 ms", absf(float(b.structure.spinPeriodMs) - 33.5) < 1e-10)
	check("neutron period units agree", absf(float(b.structure.spinPeriodSec) * 1000.0 - float(b.structure.spinPeriodMs)) < 1e-10)
	check("measured frequency becomes angular rate", absf(float(b.visual_spin_rad_s) - TAU / period) < 1e-10)
	stage.state.paused = false
	stage.animate(0.0)
	check("zero-time production frame preserves spin", b.spin_phase == 0.0)
	stage.animate(period / 4.0)
	check("quarter physical period rotates by pi/2", absf(b.spin_phase - PI / 2.0) < 1e-10 and absf(b.viz.spin_axis.rotation.y - PI / 2.0) < 1e-6)
	stage.animate(period * 3.0 / 4.0)
	check("full physical period returns phase", absf(sin(b.spin_phase)) < 1e-10 and cos(b.spin_phase) > 0.999999)
	stage.state.paused = true
	var phase := b.spin_phase
	stage.animate(1.0)
	check("paused production frame preserves spin", b.spin_phase == phase)
	var ctx := VisualCtx.new()
	b.spin_phase = 0.0
	for i in 10: b.viz.update(period / 10.0, ctx)
	check("rotation is independent of frame partition", absf(sin(b.spin_phase)) < 1e-10 and cos(b.spin_phase) > 0.999999)
	b.viz.update(100000.0, ctx)
	check("long visual interval keeps phase bounded", absf(b.spin_phase) < TAU and is_finite(b.viz.spin_axis.rotation.y))
	stage.edit_body(b, {"spinHz": 20.0})
	check("frequency edit refreshes body and period", absf(float(b.visual_spin_rad_s) - TAU * 20.0) < 1e-10 and absf(float(b.structure.spinPeriodMs) - 50.0) < 1e-10)
	var fraction := b.spin_frac
	stage.edit_body(b, {"mass": 1.5})
	check("mass edit preserves measured frequency and rederives fraction", b.spec.spinHz == 20.0 and b.spin_frac != fraction and absf(float(b.structure.spinPeriodMs) - 50.0) < 1e-10)
	stage.edit_body(b, {"visualSpinRadS": 6.0})
	check("display override does not change physical period", b.visual_spin_rad_s == 6.0 and absf(float(b.structure.spinPeriodMs) - 50.0) < 1e-10)
	stage.edit_body(b, {"visualSpinRadS": null})
	check("removing display override restores measured rate", absf(float(b.visual_spin_rad_s) - TAU * 20.0) < 1e-10)
	stage.edit_body(b, {"spinFrac": 0.02})
	check("fraction edit replaces measured frequency", not b.spec.has("spinHz") and absf(b.spin_frac - 0.02) < 1e-10)
	check("modelled neutron period units agree", absf(float(b.structure.spinPeriodMs) - float(b.structure.spinPeriodSec) * 1000.0) < 1e-10)
	var default_rate: float = b.visual_spin_rad_s
	stage.edit_body(b, {"visualSpinRadS": 2.0})
	stage.edit_body(b, {"visualSpinRadS": null})
	check("removing override restores sampled default", b.visual_spin_rad_s == default_rate)
	stage.edit_body(b, {"mass": 1.4})
	check("sampled default survives visual rebuild", b.visual_spin_rad_s == default_rate)
	stage.edit_body(b, {"spinHz": 20.0})
	stage.transmute(b, "planet", null)
	check("transmutation discards progenitor spin measurement and default", not b.spec.has("spinHz") and b.default_visual_spin_rad_s != default_rate)
	check("ordinary reclassification clears default compact GW eligibility", not b.emits_gw)
	var model := Structure.structure_of({"type": "neutron", "mass": 1.4, "spinFrac": 0.02})
	check("fraction-only period units agree", absf(float(model.spinPeriodMs) - float(model.spinPeriodSec) * 1000.0) < 1e-10)
	var radius := Structure.neutron_radius_km(2.4) * Physics.AU_PER_KM
	var critical := Structure.breakup_omega(2.4, radius, "neutron")
	var supported := Structure.structure_of({"type": "neutron", "mass": 2.4, "spinHz": critical * 0.9 / TAU})
	check("measured spin affects TOV before verdict", supported.type == "neutron" and supported.verdict.state == Structure.VERDICT.ok and supported.tovMax > 2.4)
	var supported_body: Body = stage.spawn_body({"type": "neutron", "mass": 2.4, "spinHz": critical * 0.9 / TAU, "visualSpinRadS": 10.0})
	stage.check_structural_limits(supported_body)
	check("production accepts measured rotational support", supported_body.type == "neutron" and absf(supported_body.spin_frac - 0.9) < 1e-10)
	var collapsed: Body = stage.spawn_body({"type": "neutron", "mass": 3.0, "spinHz": critical * 0.9 / TAU})
	stage.check_structural_limits(collapsed)
	check("production acts on unsupported measured neutron", collapsed.type == "bh" and not collapsed.spec.has("spinHz"))
	var overcritical := Structure.structure_of({"type": "neutron", "mass": 2.4, "spinHz": critical * 1.1 / TAU})
	check("overcritical measurement reaches breakup", overcritical.verdict.state == Structure.VERDICT.breakup and overcritical.spinFrac > 1.0)
	var edu: Body = Derive.new_body(1, Presets.PRESETS.edu_pulsar.build.call()[0])
	check("lesson has physical 30 Hz and explicit slower display", absf(float(edu.structure.spinPeriodMs) - 1000.0 / 30.0) < 1e-10 and edu.visual_spin_rad_s == 30.0)

# Independent golden radius in AU/M☉ for the orrery's G and c convention.
const RS_PER_MSUN := 1.9742003183427407e-8

func horizon_close(actual: float, expected: float) -> bool:
	return is_finite(actual) and absf(actual - expected) <= absf(expected) * 1e-13

func canonical_horizon(label: String, b: Body) -> void:
	var expected := b.mass * RS_PER_MSUN
	var rendered := Derive.hole_render_radius(expected, stage.state.scene_scale, stage.state.body_scale, stage.state.true_scale)
	check(label + " physical horizon/contact", b.type == "bh" and horizon_close(b.rs, expected) and horizon_close(b.contact_au, expected) and b.radius == 0.0)
	check(label + " structure and rendered horizon", horizon_close(float(b.structure.rs), expected)
		and horizon_close(b.rs_scene, rendered) and horizon_close(b.radius_scene, rendered))
	check(label + " canonical authored state", b.spec.mass == b.mass and (not b.spec.has("rs") or horizon_close(float(b.spec.rs), expected)))

func radiation_checks() -> void:
	stage.state.paused = true
	for case in [["star", 1.0, false], ["white-dwarf", 0.6, false], ["neutron", 1.4, true], ["bh", 8.0, true]]:
		stage.clear_bodies()
		var b: Body = stage.spawn_body({"type": case[0], "mass": case[1]})
		check("%s spawn defaults GW eligibility" % case[0], b.emits_gw == case[2])
		for override in [true, false, null]:
			stage.edit_body(b, {"emitsGW": override})
			var expected: bool = case[2] if override == null else bool(override)
			check("%s edit emitsGW=%s" % [case[0], override], b.emits_gw == expected)
			var spawned := Derive.new_body(-1, b.spec)
			check("%s spawn/edit agree emitsGW=%s" % [case[0], override], spawned.emits_gw == expected and spawned.emits_gw == b.emits_gw)
		# A poisoned derived cache must be repaired by a normal edit, not only spawn.
		b.emits_gw = not bool(case[2])
		stage.edit_body(b, {"mass": case[1]})
		check("%s ordinary edit restores spec-implied GW eligibility" % case[0], b.emits_gw == case[2])
	for case in [[10.0, "neutron"], [30.0, "bh"]]:
		for override in [true, false]:
			stage.clear_bodies()
			var b: Body = stage.spawn_body({"type": "star", "mass": case[0], "emitsGW": override})
			stage.core_collapse(b)
			check("%s collapse preserves emitsGW=%s" % [case[1], override], b.type == case[1] and b.spec.emitsGW == override and b.emits_gw == override)
			var spawned := Derive.new_body(-1, b.spec)
			check("%s collapse/spawn agree emitsGW=%s" % [case[1], override], spawned.emits_gw == override and spawned.emits_gw == b.emits_gw)

func neutron_domain_checks() -> void:
	stage.state.paused = true
	for mass in [1.4, 2.0]:
		stage.clear_bodies()
		var spec := {"type": "neutron", "mass": mass}
		var physical := Derive.new_body(-1, spec)
		var compact := physical.rs / physical.radius
		var b: Body = stage.spawn_body(spec)
		await render_frames()
		# Beloborodov (2002), eq. 1: R >= 2 r_s; docs/physics/neutron-light-bending.md.
		check("%s M☉ neutron exercises physical compactness domain" % mass,
			(compact > 0.15 and compact < 0.5) if mass == 1.4 else compact > 0.5)
		var shader_compact := float(b.viz.surf_mat.get_shader_parameter("uCompact"))
		check("%s M☉ neutron shader uses supported compactness" % mass,
			absf(shader_compact - compact) < 1e-12 if mass == 1.4 else shader_compact == 0.5)
		check("%s M☉ neutron display preserves physical radii and mass" % mass,
			b.type == "neutron" and b.rs == physical.rs and b.radius == physical.radius and b.mass == physical.mass)

func horizon_checks() -> void:
	stage.load_preset("sandbox")
	stage.state.paused = true
	var holes: Array = stage.get_holes()
	check("sandbox provides one editable black hole", holes.size() == 1)
	if holes.is_empty(): return
	var hole: Body = holes[0]
	stage._stage_set_control("mass", 25.0)
	check("production sandbox slider edits body mass", hole.mass == 25.0 and stage.state.mass == 25.0)
	canonical_horizon("sandbox slider", hole)
	check("small physical horizon remains readable in HUD", stage.hud.get_el("rs").text != "0.000" and stage.hud.get_el("isco").text != "0.000")
	stage.edit_body(hole, {"mass": 15.0, "rs": 0.5, "contactAU": 0.7})
	canonical_horizon("mass edit cannot restore authored horizon", hole)
	for mixed in [false, true]:
		stage.clear_bodies()
		stage.state.scene_scale = 2.0
		stage.state.true_scale = false
		stage.state.speed = 1.0
		stage.state.time_scale = 1.0
		stage.state.max_step = 1e-6
		stage.state.gw_boost = 0.0
		stage.state.paused = false
		var common := [0.3, -0.2, 0.1]
		var spec := {"type": "star" if mixed else "bh", "name": "heavier", "mass": 20.0,
			"rs": 0.5, "pos": [0.0, 0.0, 0.0], "vel": common}
		if mixed: spec.merge({"radiusSun": 120.0, "luminosity": 900.0, "teff": 4500.0, "contactAU": 0.3})
		var a: Body = stage.spawn_body(spec)
		var b: Body = stage.spawn_body({"type": "bh", "name": "lighter", "mass": 2.0,
			"rs": 0.25, "pos": [0.0, 0.0, 0.0], "vel": common})
		var momentum := a.vel.scaled(a.mass).add_scaled_in(b.vel, b.mass)
		var years: float = stage.state.sim_years
		# Matching positions and velocities leave no force direction at either kick.
		stage.animate(1e-6)
		check("contact mixed=%s merges through production" % mixed, stage.state.bodies.size() == 1
			and stage.state.bodies[0] == a and stage.state.sim_years > years)
		check("contact mixed=%s mass/momentum conserved" % mixed, a.mass == 22.0
			and a.vel.scaled(a.mass).distance_to(momentum) < 1e-12)
		canonical_horizon("contact mixed=%s" % mixed, a)
		check("contact mixed=%s defaults to BH GW eligibility" % mixed, a.emits_gw and Derive.new_body(-1, a.spec).emits_gw == a.emits_gw)
		if mixed:
			check("absorbed lighter hole discards stellar measurements", not a.spec.has("radiusSun")
				and not a.spec.has("radiusKm") and not a.spec.has("luminosity") and not a.spec.has("teff") and not a.spec.has("contactAU"))
			check("absorbed lighter hole discards photosphere", a.radius == 0.0 and a.radius_sun == null and a.teff == null and a.luminosity == null)
		stage.state.paused = true
		await render_frames()

func _ready() -> void:
	OS.add_logger(catcher)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	await get_tree().process_frame
	stage._start("sandbox")
	stage.state.paused = true
	stage.set_process(false)
	spin_checks()
	radiation_checks()
	await neutron_domain_checks()
	await horizon_checks()
	for case in [[1.0, "white-dwarf"], [10.0, "neutron"], [30.0, "bh"]]:
		stage.clear_bodies()
		var b: Body = stage.spawn_body({"type": "star", "mass": case[0], "radiusSun": 120.0,
			"luminosity": 900.0, "teff": 4500.0, "contactAU": 0.3, "name": "Measured progenitor"})
		await render_frames()
		stage.core_collapse(b)
		await render_frames()
		check("%s remnant type" % case[1], b.type == case[1])
		check("%s remnant defaults GW eligibility" % case[1], b.emits_gw == (case[1] in ["neutron", "bh"]))
		check("%s remnant/spawn agree GW eligibility" % case[1], Derive.new_body(-1, b.spec).emits_gw == b.emits_gw)
		check("%s discards progenitor radius/contact" % case[1], not b.spec.has("radiusSun") and not b.spec.has("radiusKm") and not b.spec.has("contactAU"))
		if b.type == "bh":
			check("BH contact is new horizon", b.contact_au == Physics.schwarzschild(b.mass) and b.radius == 0.0)
			check("BH discards photosphere", b.teff == null and b.luminosity == null and b.radius_sun == null)
		else:
			check("%s physical radius follows remnant" % case[1], b.radius == b.structure.radiusAU and b.radius < 0.001 and b.contact_au == b.radius)
			if b.type == "white-dwarf":
				check("WD retains intended remnant temperature", b.teff == 30000.0 and b.spec.teff == 30000.0)
				check("WD recomputes luminosity", b.luminosity == b.structure.luminosity and b.luminosity < 1.0 and not b.spec.has("luminosity"))
			else:
				check("neutron discards stellar photosphere", b.teff == null and b.luminosity == null)
				check("neutron remnant retains intended display rate", b.visual_spin_rad_s == 30.0)
	var errors := catcher.take()
	for error in errors: print("TRANSITIONCHECK ENGINE ", error)
	check("rendered remnant transitions have no engine errors", errors.is_empty())
	print("TRANSITIONCHECK DONE checks=%s failures=%s" % [checks, failures])
	OS.remove_logger(catcher)
	get_tree().quit(1 if failures else 0)
