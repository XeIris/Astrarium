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
		bodies.append({"body": b, "mass": b.mass, "mass0": b.mass0, "type": b.type,
			"spec": b.spec.duplicate(true), "structure": b.structure.duplicate(true),
			"viz": b.viz, "marker": b.marker, "trail": b.trail,
			"pos": [b.pos.x, b.pos.y, b.pos.z], "vel": [b.vel.x, b.vel.y, b.vel.z]})
	return {"bodies": bodies, "next_id": stage.state.next_id,
		"preset": stage.state.preset_key, "scene_scale": stage.state.scene_scale,
		"body_scale": stage.state.body_scale, "true_scale": stage.state.true_scale,
		"focus": stage.state.focus_id, "follow": stage.state.follow_id,
		"home": stage.state.home_id, "climate": stage.state.climate,
		"years": stage.state.sim_years, "consumed": stage.state.consumed,
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
	]:
		check("raw spawn rejects %s" % spec, stage.spawn_body(spec) == null)
		check("rejected spawn keeps scene/IDs/visuals/camera", snapshot() == original)
	check("overflowing critical rate has an explicit numerical rejection reason", Structure.input_error(
		stage._normalized_body_spec({"type": "neutron", "radiusKm": 1e200, "spinHz": 1.4})).contains("numerical range"))
	var b: Body = stage.state.bodies[0]
	for patch in [{"spinFrac": 1.01}, {"mass": "many"}, {"spinFrac": INF}]:
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
	measured_inputs()
	await pending_editor_input()
	editor_and_preset_inputs()
	events_and_live_mass()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("STRUCTUREINPUTCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
