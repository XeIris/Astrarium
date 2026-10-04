extends Node

# Exercise cached views through production edits and physical events.
const Catch = preload("res://tools/coursecheck.gd").Catch
var catcher := Catch.new()
var stage: Node
var checks := 0
var failures := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func show(b: Body) -> void:
	stage.state.focus_id = b.id
	stage.open_cross_section()
	check("inspector reads canonical structure", is_same(stage.inspector.canvas.st, b.structure))
	check("mass handle reads canonical structure", is_same(stage.live_editor.curve._live_structure, b.structure))

func sampled_edits(b: Body) -> void:
	var curve: MassCurve = stage.live_editor.curve
	curve.nearest(b.mass)
	for index in [0, MassCurve.N / 2, MassCurve.N - 1]:
		var lm: float = curve.view[0] + (curve.view[1] - curve.view[0]) * index / (MassCurve.N - 1)
		var patch: Dictionary = curve.spec.duplicate()
		for key in Derive.MASS_EDIT_MEASUREMENTS: patch.erase(key)
		patch.mass = pow(10.0, lm)
		var expected := Structure.structure_of(patch)
		var sample = curve.samples[index]
		var radius: float = float(expected.get("radiusAU", 0.0))
		check("sample predicts mass edit at index %d" % index,
			(sample == null) if radius <= 0.0 else (sample != null and sample.type == expected.type
			and absf(float(sample.ly) - U.log10(radius)) < 1e-12))

func unchanged_views(b: Body) -> void:
	show(b)
	var editor = stage.live_editor
	editor.curve.set_focus(true)
	editor.sync(b)
	var structure: Dictionary = b.structure
	var samples: Array = editor.curve.samples
	var view: Array = editor.curve.view.duplicate()
	var first_fact: Node = stage.inspector.facts_el.get_child(0)
	var started := Time.get_ticks_usec()
	for i in 100:
		stage.show_cross_section(b)
		editor.sync(b)
	print("EDITORCHECK PROFILE unchanged_100_us=", Time.get_ticks_usec() - started)
	check("unchanged inspection keeps canonical structure", is_same(b.structure, structure))
	check("unchanged focused graph keeps sampled results", is_same(editor.curve.samples, samples) and editor.curve.view == view)
	check("unchanged inspection keeps fact controls", stage.inspector.facts_el.get_child(0) == first_fact)

func edits() -> void:
	stage.clear_bodies()
	var star: Body = stage.spawn_body({"type": "star", "mass": 1.0, "radiusSun": 2.0, "teff": 6200.0, "luminosity": 5.0})
	unchanged_views(star)
	var curve: MassCurve = stage.live_editor.curve
	var samples: Array = curve.samples
	var previous: Dictionary = star.structure
	stage.edit_body(star, {"radiusSun": 3.0})
	show(star)
	check("measured radius updates inspector and live handle", not is_same(star.structure, previous)
		and star.structure.radiusSun == 3.0 and curve._live_structure.radiusSun == 3.0)
	check("measurement change preserves predicted mass-edit samples", is_same(curve.samples, samples))
	previous = star.structure
	stage.edit_body(star, {"radiusSun": 3.0})
	show(star)
	check("equal-valued edits still publish the latest canonical snapshot", not is_same(star.structure, previous)
		and star.structure == previous and is_same(stage.inspector.canvas.st, star.structure))
	sampled_edits(star)
	stage.edit_body(star, {"mass": 1.1})
	show(star)
	check("mass edit discards the same measurements as the graph", not star.spec.has("radiusSun")
		and not star.spec.has("teff") and not star.spec.has("luminosity"))
	sampled_edits(star)
	stage.edit_body(star, {"spinFrac": 0.2, "phase": 0.8, "Z": 0.02})
	show(star)
	sampled_edits(star)
	stage.clear_bodies()
	var neutron: Body = stage.spawn_body({"type": "neutron", "mass": 1.4, "radiusKm": 18.0, "spinHz": 100.0})
	show(neutron)
	sampled_edits(neutron)
	samples = curve.samples
	stage.edit_body(neutron, {"spinHz": 150.0})
	show(neutron)
	check("measured frequency invalidates predicted samples", not is_same(curve.samples, samples))
	sampled_edits(neutron)
	stage.edit_body(neutron, {"spinFrac": 0.1})
	show(neutron)
	check("modeled spin edit removes measured frequency from graph", not curve.spec.has("spinHz"))
	sampled_edits(neutron)

func events() -> void:
	stage.clear_bodies()
	var a: Body = stage.spawn_body({"type": "neutron", "mass": 1.1})
	stage.spawn_body({"type": "neutron", "mass": 0.2})
	show(a)
	var previous: Dictionary = a.structure
	stage.state.gw_boost = 0.0
	stage.step_physics(1e-6)
	show(a)
	check("contact updates canonical inspector and handle", stage.state.bodies.size() == 1
		and not is_same(a.structure, previous) and a.structure.mass == a.mass)
	stage.edit_body(a, {"mass": 3.0})
	show(a)
	check("collapse replaces structure and graph type", a.type == "bh"
		and stage.inspector.canvas.st.type == "bh" and stage.live_editor.curve.spec.type == "bh")
	stage.clear_bodies()
	var planet: Body = stage.spawn_body({"type": "planet", "mass": 3e-6})
	show(planet)
	stage.edit_body(planet, {"mass": 0.08})
	show(planet)
	check("ignition reclassification updates graph and inspector", planet.type == "star"
		and stage.live_editor.curve.spec.type == "star" and stage.inspector.canvas.st.type == "star")

func small_body() -> void:
	stage.clear_bodies()
	var tiny: Body = stage.spawn_body({"type": "bh", "mass": 1e-15})
	show(tiny)
	var editor = stage.live_editor
	check("valid small hole keeps its real mass in controls", absf(editor.rows.mass.value + 15.0) < 1e-10
		and editor.curve.spec.mass == 1e-15)
	var curve: MassCurve = editor.curve
	check("small hole's handle remains within the focused view", curve.view[0] <= -15.0 and curve.view[1] >= -15.0)
	sampled_edits(tiny)

func pending_body_switch() -> void:
	stage.clear_bodies()
	var first: Body = stage.spawn_body({"type": "star", "mass": 1.0})
	var second: Body = stage.spawn_body({"type": "star", "mass": 2.0, "pos": [1.0, 0.0, 0.0]})
	var editor = stage.live_editor
	show(first)
	editor._last_apply = Time.get_ticks_msec()
	editor.queue({"mass": 1.2})
	check("body switch fixture has a trailing edit", editor._timer != null and editor.pending != null)
	show(second)
	check("switch cancels the previous body's queued edit", editor._timer == null and editor.pending == null)
	editor.queue({"spinFrac": 0.2})
	await get_tree().create_timer(0.04, true, false, true).timeout
	check("old trailing edit cannot change the new body", first.mass == 1.0 and second.mass == 2.0)
	check("new body's queued edit still lands", second.spin_frac == 0.2 and editor.pending == null)
	editor._last_apply = Time.get_ticks_msec()
	editor.queue({"mass": 2.2})
	var replacement := Derive.new_body(second.id, {"type": "star", "mass": 3.0})
	editor.sync(replacement)
	check("same-ID replacement cancels the old instance's draft", editor.pending == null and editor._timer == null)
	await get_tree().create_timer(0.04, true, false, true).timeout
	check("same-ID replacement remains untouched", replacement.mass == 3.0 and second.mass == 2.0)
	editor.sync(first)
	editor._last_apply = Time.get_ticks_msec()
	editor.queue({"mass": 1.1})
	editor.reject_edit(first)
	check("rejection cancels pending timer", editor.pending == null and editor._timer == null)
	editor.queue({"spinFrac": 0.15})
	await get_tree().create_timer(0.04, true, false, true).timeout
	check("new valid edit after rejection lands once", first.mass == 1.0 and first.spin_frac == 0.15)
	editor._last_apply = Time.get_ticks_msec()
	editor.queue({"mass": 1.1})
	stage.remove_body(first.id)
	check("removal releases target and pending work immediately", editor.body == null
		and editor.pending == null and editor._timer == null and not first.alive)
	await get_tree().create_timer(0.04, true, false, true).timeout
	check("removed body cannot rebuild orphan visuals", first.mass == 1.0 and first.viz == null and first.marker == null)
	var reused: Body = stage.spawn_body({"type": "star", "mass": 3.0})
	reused.id = first.id
	stage._on_live_edit(first, {"mass": 1.5})
	check("stale callback cannot target a replacement before editor sync", reused.mass == 3.0
		and first.viz == null and not stage.xsec_open)
	show(reused)
	stage.clear_bodies()
	check("clearing the scene releases the live editor", editor.body == null and editor.pending == null and editor._timer == null)

func small_threshold_crossing() -> void:
	stage.clear_bodies()
	var dwarf: Body = stage.spawn_body({"type": "white-dwarf", "mass": 1.439999})
	stage.check_structural_limits(dwarf)
	stage.spawn_body({"type": "planet", "mass": 3e-6})
	stage.step_physics(1e-6)
	check("small merger crosses Chandrasekhar physically", dwarf.mass > float(Structure.LIMITS.chandrasekhar)
		and dwarf.mass - float(dwarf.m_check) < float(dwarf.m_check) * 1e-3)
	stage.animate(1e-6)
	check("small threshold crossing detonates in the production frame", stage.state.body_by_id(dwarf.id) == null)

func _ready() -> void:
	OS.add_logger(catcher)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	for i in 2: await get_tree().process_frame
	stage._start("sandbox")
	stage.set_process(false)
	stage.state.paused = true
	edits()
	events()
	small_threshold_crossing()
	small_body()
	await pending_body_switch()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("EDITORCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
