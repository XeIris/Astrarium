extends Node

# Reject unsupported requests through the real stage before changing a live scene.
const Catch = preload("res://tools/coursecheck.gd").Catch
var catcher := Catch.new()
var stage: Node
var checks := 0
var failures := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func snapshot() -> Dictionary:
	var bodies := []
	for b: Body in stage.state.bodies:
		bodies.append({"body": b, "name": b.name, "mass": b.mass, "mass0": b.mass0, "type": b.type,
			"spec": b.spec.duplicate(true), "structure": b.structure.duplicate(true),
			"viz": b.viz, "marker": b.marker, "trail": b.trail,
			"pos": [b.pos.x, b.pos.y, b.pos.z], "vel": [b.vel.x, b.vel.y, b.vel.z],
			"scene_pos": [b.scene_pos.x, b.scene_pos.y, b.scene_pos.z]})
	return {"bodies": bodies, "next_id": stage.state.next_id,
		"preset": stage.state.preset_key, "scene_scale": stage.state.scene_scale,
		"body_scale": stage.state.body_scale, "true_scale": stage.state.true_scale,
		"focus": stage.state.focus_id, "follow": stage.state.follow_id,
		"home": stage.state.home_id, "climate": stage.state.climate,
		"years": stage.state.sim_years, "year_remainder": stage.state.year_remainder, "consumed": stage.state.consumed,
		"cam_radius": stage.cam.radius, "cam_radius_to": stage.cam.radius_to,
		"cam_theta": stage.cam.theta, "cam_phi": stage.cam.phi,
		"cam_target": [stage.cam.target.x, stage.cam.target.y, stage.cam.target.z]}

func rejected_inputs() -> void:
	stage.load_preset("solar")
	var original := snapshot()
	for spec in [
		{"type": "neutron", "mass": 0.05},
		{"type": "planet", "spinFrac": 1.001},
		{"type": "star", "mass": "one"},
		{"type": "star", "mass": NAN},
		{"type": "star", "mass": -1.0},
		{"type": "neutron", "spinHz": INF},
		{"type": "planet", "spinFrac": "fast"},
		{"type": "neutron", "radiusKm": "small"},
		{"type": "neutron", "radiusKm": NAN},
		{"type": "star", "radiusSun": INF},
		{"type": "star", "radiusSun": -1.0},
		{"type": "neutron", "radiusKm": 1e200, "spinHz": 1.4},
		{"type": "bh", "mass": 1e200},
		{"type": "bh", "mass": 1e-200},
		{"type": "planet", "pos": "here"},
		{"type": "planet", "pos": [1.0, 2.0]},
		{"type": "planet", "pos": [1.0, 2.0, 3.0, 4.0]},
		{"type": "planet", "pos": [1.0, NAN, 3.0]},
		{"type": "planet", "vel": [1.0, "fast", 3.0]},
		{"type": "planet", "vel": [1.0, INF, 3.0]},
		{"type": "planet", "softening": -1.0},
		{"type": "planet", "softening": INF},
		{"type": "planet", "contactAU": -1.0},
		{"type": "planet", "contactAU": "near"},
	]:
		check("raw spawn rejects %s" % spec, stage.spawn_body(spec) == null)
		check("rejected spawn keeps scene/IDs/visuals/camera", snapshot() == original)
	check("overflowing critical rate has an explicit numerical rejection reason", Structure.input_error(
		stage._normalized_body_spec({"type": "neutron", "radiusKm": 1e200, "spinHz": 1.4})).contains("numerical range"))
	var b: Body = stage.state.bodies[0]
	for patch in [{"spinFrac": 1.01}, {"mass": "many"}, {"spinFrac": INF},
		{"pos": [NAN, 0.0, 0.0]}, {"vel": []}, {"softening": -1.0}, {"contactAU": INF}]:
		check("raw edit rejects %s" % patch, stage.edit_body(b, patch) == null)
		check("rejected edit keeps spec/mass/visuals/camera", snapshot() == original)
	stage._on_foundry_spawn({"type": "neutron", "mass": 0.05}, {})
	check("Foundry callback handles rejected spawn without following null", snapshot() == original)

func supported_inputs() -> void:
	stage.clear_bodies()
	var defaults: Body = stage.spawn_body({"type": "neutron"})
	check("spawn validates neutron's actual default mass", defaults != null and defaults.mass == 1.4)
	stage.clear_bodies()
	var rocky: Body = stage.spawn_body({"type": "planet"})
	for spin in [0.999, 1.0]:
		check("near-limit fraction %s is accepted" % spin, stage.edit_body(rocky, {"spinFrac": spin}) == rocky)
		check("near-limit fraction warns without destroying equilibrium", rocky.alive and rocky.spin_frac == spin
			and rocky.structure.verdict.state == Structure.VERDICT.breakup)
	var initial := snapshot()
	check("actual overcritical rotation rejected", stage.edit_body(rocky, {"spinFrac": 1.0001}) == null)
	check("overcritical rejection preserves accepted limit", snapshot() == initial)
	var low: Body = stage.spawn_body({"type": "neutron", "mass": 0.1, "pos": [1.0, 0.0, 0.0]})
	check("model's exact neutron lower endpoint is accepted", low != null and low.mass == 0.1)
	stage.clear_bodies()
	var tiny: Body = stage.spawn_body({"type": "bh", "mass": 1e-15,
		"pos": PackedFloat64Array([1.0, 0.0, 0.0]), "vel": [0.0, 1.0, 0.0], "softening": 0.2})
	check("small wide-orbit hole is accepted without a mass floor", tiny != null)
	if tiny != null:
		check("small hole structure keeps actual mass and horizon", tiny.structure.mass == tiny.mass
			and tiny.structure.rs == tiny.rs and tiny.rs == Physics.schwarzschild(1e-15))
		check("small hot hole does not promise background-driven growth", tiny.structure.verdict.detail.contains("lose energy")
			and tiny.structure.verdict.detail.contains("not simulated"))
		check("authored softening is derived", tiny.softening == 0.2)
		check("edited softening is derived", stage.edit_body(tiny, {"softening": 0.3}) == tiny and tiny.softening == 0.3)

func schema_inputs() -> void:
	stage.load_preset("solar")
	var original := snapshot()
	for spec in [{"type": "starr"}, {"type": ""}, {"type": 7}, {"type": false},
		{"type": "star", "phase": "ms-mid"}, {"type": "star", "phase": NAN},
		{"type": "star", "Z": "solar"}, {"type": "star", "Z": INF},
		{"type": "star", "Z": -0.001}, {"type": "star", "Z": 1.001},
		{"type": "planet", "composition": "eath"}, {"type": "planet", "composition": {}},
		{"type": "star", "teff": "warm"}, {"type": "star", "teff": NAN},
		{"type": "star", "teff": 0.0}, {"type": "star", "teff": -1.0},
		{"type": "white-dwarf", "luminosity": "dim"}, {"type": "star", "luminosity": INF},
		{"type": "star", "luminosity": -1.0}, {"type": "star", "visualSpinRadS": "fast"},
		{"type": "planet", "visualSpinRadS": NAN}, {"type": "world", "dayLength": "long"},
		{"type": "world", "dayLength": INF}, {"type": "world", "obliquity": []},
		{"type": "world", "obliquity": NAN}, {"type": "world", "home": "false"},
		{"type": "star", "emitsGW": 1}, {"type": "bh", "spinHz": INF}]:
		check("schema spawn rejects %s" % spec, stage.spawn_body(spec) == null)
		check("schema spawn rejection is atomic", snapshot() == original)
	var star: Body = stage.state.bodies[0]
	for patch in [{"type": "starr"}, {"type": 7}, {"phase": false}, {"Z": true},
		{"composition": "unknown"}, {"teff": INF}, {"luminosity": -1.0},
		{"visualSpinRadS": []}, {"dayLength": NAN}, {"obliquity": INF}, {"emitsGW": "false"}]:
		check("schema edit rejects %s" % patch, stage.edit_body(star, patch) == null)
		check("schema edit rejection is atomic", snapshot() == original)
	for patch in [{"type": "starr"}, {"teff": "warm"}, {"home": "false"}]:
		var invalid: Dictionary = Presets.PRESETS.solar.duplicate()
		invalid.build = func() -> Array: return [{"type": "star", "mass": 1.0}, U.merged({"type": "planet"}, patch)]
		Presets.PRESETS["__invalid_schema"] = invalid
		check("schema preset rejects %s" % patch, not stage.load_preset("__invalid_schema"))
		check("schema preset rejection is atomic", snapshot() == original)
	Presets.PRESETS.erase("__invalid_schema")
	for type in Derive.TYPE_DEFAULTS:
		check("every derived type is supported: " + type, Structure.input_error(stage._normalized_body_spec({"type": type})).is_empty())
	for key in Starcat.STAR_CATALOG:
		check("every measured catalog entry is supported: " + key,
			Structure.input_error(stage._normalized_body_spec(Starcat.star_spec(key))).is_empty())
	for patch in [{"phase": -100.0}, {"phase": 100.0}, {"Z": 0.0}, {"Z": 1.0},
		{"visualSpinRadS": -4.0}, {"visualSpinRadS": 0.0}, {"dayLength": -0.01},
		{"dayLength": 0.0}, {"obliquity": -TAU}, {"luminosity": 0.0},
		{"phase": null, "Z": null, "composition": null, "teff": null, "luminosity": null,
			"spinHz": null, "visualSpinRadS": null, "dayLength": null, "obliquity": null,
			"home": null, "emitsGW": null}]:
		check("supported schema endpoint/unset value: %s" % patch,
			Structure.input_error(stage._normalized_body_spec(U.merged({"type": "star"}, patch))).is_empty())
	for composition in Structure.ROCK_COMPOSITIONS:
		check("every solid mixture is supported: " + composition,
			Structure.input_error(stage._normalized_body_spec({"type": "planet", "composition": composition})).is_empty())
	stage.clear_bodies()
	for spec in [{}, {"type": null}]:
		var default: Body = stage.spawn_body(spec)
		check("missing or null type defaults to planet", default != null and default.type == "planet")
	var retrograde: Body = stage.spawn_body({"type": "world", "dayLength": -0.01,
		"visualSpinRadS": -4.0, "obliquity": -0.4, "home": false})
	check("signed rotation fields survive real derivation", retrograde != null and retrograde.day_length == -0.01
		and retrograde.visual_spin_rad_s == -4.0 and retrograde.obliquity == -0.4 and not retrograde.home)
	var dark: Body = stage.spawn_body({"type": "white-dwarf", "luminosity": 0.0})
	check("zero measured dwarf luminosity stays zero", dark != null and dark.luminosity == 0.0)

func numerical_time() -> void:
	stage.clear_bodies()
	var b: Body = stage.spawn_body({"type": "star", "vel": [1.0, 0.0, 0.0]})
	stage.state.sim_years = 0.0
	stage.state.max_step = 1e-13
	stage.state.gw_boost = 0.0
	var accepted: float = stage.step_physics(5e-13)
	check("production clock accepts a short positive duration", accepted == 5e-13
		and stage.state.sim_years == accepted and b.pos.x == accepted and not stage.state.last_resolution_limited)
	stage.state.max_step = 0.0
	var original := snapshot()
	check("invalid step cap accepts no time", stage.step_physics(1e-6) == 0.0)
	check("invalid cap leaves physical scene and clock unchanged", snapshot() == original and stage.state.last_resolution_limited)
	stage.update_sim_stats()
	var label: Label = stage.hud.get_el("setSteps")
	check("production HUD exposes a numerical stop", label.text.contains("precision limit")
		and label.tooltip_text.contains("Unsafe steps were not accepted"))
	stage.state.max_step = 1e-13
	accepted = stage.step_physics(1e-6)
	check("work guard keeps partial accepted time", accepted > 0.0 and accepted < 1e-6
		and stage.state.last_steps == Derive.STEP_GUARD and not stage.state.last_resolution_limited)
	stage.update_sim_stats()
	check("work guard has a distinct warning", label.text.contains("capped")
		and label.tooltip_text.contains("8000 sub-step guard"))
	stage.state.sim_years = 1e10
	stage.state.max_step = 1e-12
	accepted = stage.step_physics(1e-3)
	check("partial accepted time survives a large elapsed clock", accepted > 0.0
		and stage.state.sim_years == 1e10 and stage.state.year_remainder == accepted)
	for i in 250: stage.step_physics(1e-3)
	check("small accepted intervals eventually advance the large clock", stage.state.sim_years > 1e10)
	stage.state.sim_years = 0.0
	check("assigning a new epoch clears fractional time", stage.state.year_remainder == 0.0)
	var clock := SimState.new()
	clock.sim_years = -1e10
	clock.advance_years(1e10)
	clock.advance_years(1e-200)
	check("compensated clock handles cancellation and a new tiny epoch", clock.sim_years == 1e-200 and clock.year_remainder == 0.0)
	clock.sim_years = 1.7976931348623157e308
	check("clock permits a finite increment at its upper edge", clock.can_advance_years(5e291))
	clock.advance_years(5e291)
	check("clock preflight includes accumulated remainder at overflow", not clock.can_advance_years(5e291))
	stage.state.sim_years = 1e308
	original = snapshot()
	check("overflowing global clock request stops before integration", stage.step_physics(1e308) == 0.0
		and snapshot() == original and stage.state.last_resolution_limited)
	stage.state.sim_years = 0.0
	stage.state.max_step = 1e-6
	check("later resolved request clears the numerical warning", stage.step_physics(1e-6) == 1e-6
		and not stage.state.last_resolution_limited)
	stage.state.max_step = 0.0
	stage.step_physics(1e-6, true)
	stage.state.max_step = 1e-6
	stage.step_physics(1e-6, true)
	check("coupled callbacks retain an earlier numerical warning", stage.state.last_resolution_limited)

func measured_inputs() -> void:
	stage.clear_bodies()
	var radius := 18.0 * Physics.AU_PER_KM
	var critical_hz := Structure.breakup_omega(1.4, radius, "neutron") / TAU
	var measured: Body = stage.spawn_body({"type": "neutron", "mass": 1.4, "radiusKm": 18.0,
		"spinHz": 0.2 * critical_hz, "spinFrac": 2.0})
	check("measured frequency overrides overcritical modeled fraction", measured != null and absf(measured.spin_frac - 0.2) < 1e-12)
	if measured == null: return
	var original := snapshot()
	check("measured overcritical frequency rejected", stage.edit_body(measured, {"spinHz": critical_hz * 1.001}) == null)
	check("frequency rejection preserves measured spec and visual", snapshot() == original)
	check("modeled edit erases measured frequency before validation", stage.edit_body(measured, {"spinFrac": 0.4}) == measured
		and not measured.spec.has("spinHz") and measured.spin_frac == 0.4)
	stage.clear_bodies()
	var compact_hz := 0.9 * Structure.breakup_omega(1.4, 8.0 * Physics.AU_PER_KM, "neutron") / TAU
	var compact: Body = stage.spawn_body({"type": "neutron", "mass": 1.4, "radiusKm": 8.0, "spinHz": compact_hz})
	check("measured compact neutron supported before mass edit", compact != null)
	if compact == null: return
	original = snapshot()
	check("mass edit validates after discarding measured radius", stage.edit_body(compact, {"mass": 1.4}) == null)
	check("rejected mass edit retains original measured radius/frequency", snapshot() == original)
	stage.clear_bodies()
	var gentle_hz := 0.5 * Structure.breakup_omega(1.4, 30.0 * Physics.AU_PER_KM, "neutron") / TAU
	var gentle: Body = stage.spawn_body({"type": "neutron", "mass": 1.4, "radiusKm": 30.0, "spinHz": gentle_hz})
	check("supported mass edit preserves frequency and removes measurement", stage.edit_body(gentle, {"mass": 1.5}) == gentle
		and gentle.spec.spinHz == gentle_hz and not gentle.spec.has("radiusKm"))

func pending_editor_input() -> void:
	stage.clear_bodies()
	var b: Body = stage.spawn_body({"type": "neutron", "mass": 1.4})
	var editor = stage.live_editor
	editor.sync(b)
	editor._last_apply = -1000000
	editor.queue({"spinFrac": 0.1})
	check("live editor first applies supported request", b.spin_frac == 0.1)
	# Anchor the throttle window after visual construction, independent of machine speed.
	editor._last_apply = Time.get_ticks_msec()
	editor.queue({"mass": 0.05})
	var timer: SceneTreeTimer = editor._timer
	check("live editor holds unsupported request behind an actual timer", timer != null and editor.pending != null)
	var original := snapshot()
	check("pending edit can be rejected before timeout", stage.edit_body(b, {"mass": 0.05}) == null)
	check("pending rejection clears draft without changing live scene", editor.pending == null and snapshot() == original)
	if timer == null: return
	await timer.timeout
	for i in 2: await get_tree().process_frame
	check("settled editor timer cannot replay rejected request", editor._timer == null and editor.pending == null and snapshot() == original)

func editor_and_preset_inputs() -> void:
	stage.clear_bodies()
	var b: Body = stage.spawn_body({"type": "neutron", "mass": 1.4})
	stage.live_editor.sync(b)
	stage.live_editor._last_apply = -1000000
	var original := snapshot()
	stage.live_editor._on_pick(0.05)
	check("live mass-curve rejection leaves scene intact", snapshot() == original)
	check("rejected live drag resets pending controls", stage.live_editor.dragging == "" and stage.live_editor.pending == null
		and absf(stage.live_editor.rows.mass.value - U.log10(b.mass)) <= stage.live_editor.rows.mass.snap)
	var other: Body = stage.spawn_body({"type": "planet", "pos": [2.0, 0.0, 0.0]})
	stage.edit_body(other, {"spinFrac": 2.0})
	check("rejected unrelated edit does not replace live editor body", stage.live_editor.body == b)
	stage.load_preset("solar")
	original = snapshot()
	var invalid: Dictionary = Presets.PRESETS.solar.duplicate()
	invalid.build = func() -> Array: return [{"type": "star", "mass": 1.0}, {"type": "neutron", "mass": 0.05}]
	Presets.PRESETS["__unsupported_input"] = invalid
	check("preset rejects invalid second body", not stage.load_preset("__unsupported_input"))
	check("preset preflight preserves complete live scene", snapshot() == original)
	Presets.PRESETS.erase("__unsupported_input")
	check("supported preset still loads", stage.load_preset("sandbox") and stage.state.preset_key == "sandbox")
	original = snapshot()
	var hole: Body = stage.get_holes()[0]
	stage._on_slider("mass", -1.0)
	check("rejected sandbox slider keeps body and camera", snapshot() == original)
	check("rejected sandbox slider restores its readout", stage.state.mass == hole.mass
		and stage.hud.get_el("mass-val").text == U.fixed(hole.mass, 1))
	var panel = stage.foundry
	panel.set_type("neutron")
	panel.rows.mass.min_value = -2.0
	panel.rows.mass.set_v(U.log10(0.05))
	panel.update()
	check("unsupported Foundry draft disables Spawn", panel.spawn_btn.disabled)
	original = snapshot()
	panel.spawn()
	check("unsupported Foundry draft cannot call spawn", snapshot() == original)
	panel.set_type("planet")
	panel.rows.spin.set_v(1.0)
	panel.update()
	check("Foundry limit warning leaves supported Spawn enabled", not panel.spawn_btn.disabled)

func events_and_live_mass() -> void:
	stage.clear_bodies()
	var a: Body = stage.spawn_body({"type": "neutron", "mass": 1.1})
	stage.spawn_body({"type": "neutron", "mass": 0.2})
	stage.state.paused = false
	stage.state.time_scale = 1.0
	stage.state.speed = 1.0
	stage.state.max_step = 1e-6
	stage.state.gw_boost = 0.0
	stage.animate(1e-6)
	stage.state.paused = true
	check("production contact produces merged live mass", stage.state.bodies.size() == 1 and a.mass > 1.29)
	check("unpatched edit uses live merged mass", stage.edit_body(a, {"spinFrac": 0.2}) == a
		and a.spec.mass == a.mass and a.mass > 1.29)
	stage.clear_bodies()
	var collapse: Body = stage.spawn_body({"type": "neutron", "mass": 3.0})
	check("TOV event input is accepted", collapse != null)
	if collapse != null:
		stage.check_structural_limits(collapse)
		check("TOV event still becomes a black hole", collapse.type == "bh")
	stage.clear_bodies()
	var dwarf: Body = stage.spawn_body({"type": "white-dwarf", "mass": 1.5})
	check("Chandrasekhar event input is accepted", dwarf != null)
	if dwarf != null:
		stage.check_structural_limits(dwarf)
		check("Chandrasekhar event still detonates", stage.state.body_by_id(dwarf.id) == null)
	for key in Presets.PRESET_ORDER:
		for spec in Presets.PRESETS[key].build.call():
			check("authored preset supported: %s/%s" % [key, spec.get("name", spec.type)],
				Structure.input_error(stage._normalized_body_spec(spec)).is_empty())

func _ready() -> void:
	OS.add_logger(catcher)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	await get_tree().process_frame
	stage._start("sandbox")
	stage.set_process(false)
	stage.state.paused = true
	rejected_inputs()
	supported_inputs()
	schema_inputs()
	numerical_time()
	measured_inputs()
	await pending_editor_input()
	editor_and_preset_inputs()
	events_and_live_mass()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("STRUCTUREINPUTCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
