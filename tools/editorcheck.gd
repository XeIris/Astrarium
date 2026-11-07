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
	stage._on_live_edit(star, {"spinFrac": 0.2})
	var visual = star.viz
	var marker = star.marker
	var row: Node = stage.hud.ids.bodyList.get_child(0)
	var fact: Node = stage.inspector.facts_el.get_child(0)
	stage._on_live_edit(star, {"spinFrac": 0.3})
	check("spin edit retains visual, marker and activity ownership", is_same(star.viz, visual) and is_same(star.marker, marker))
	check("spin edit retains fact controls when the schema is unchanged", stage.inspector.facts_el.get_child(0) == fact)
	check("spin edit updates photosphere deformation", absf(float(visual.mat.get_shader_parameter("uSpin")) - 0.3) < 1e-6)
	var temps := Structure.gravity_darkened_temps(float(star.teff), star.spin_frac)
	check("spin edit updates pole temperature", absf(float(visual.mat.get_shader_parameter("uTpole")) - float(temps.tPole)) < 0.01)
	check("unchanged body list retains native controls during edits", stage.hud.ids.bodyList.get_child(0) == row)
	stage.edit_body(star, {"name": "Renamed"})
	check("body list refreshes when its displayed name changes", stage.hud.ids.bodyList.get_child(0) != row)
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

func live_state_edits() -> void:
	stage.clear_bodies()
	var b: Body = stage.spawn_body({"type": "planet", "name": "Original", "pos": [2.0, 0.0, 0.0], "vel": [1.0, 0.0, 0.0]})
	stage.state.max_step = 0.25
	stage.state.gw_boost = 0.0
	stage.step_physics(0.25)
	var pos := b.pos.to_array()
	var vel := b.vel.to_array()
	check("ordinary edit preserves integrated vectors", stage.edit_body(b, {"spinFrac": 0.1}) == b
		and b.pos.to_array() == pos and b.vel.to_array() == vel)
	check("accepted spec snapshots current vectors", b.spec.pos == pos and b.spec.vel == vel)
	show(b)
	var samples: Array = stage.live_editor.curve.samples
	check("name edit reaches the live body", stage.edit_body(b, {"name": "Renamed"}) == b and b.name == "Renamed")
	check("name lookup follows the accepted edit", stage.state.body_named("Renamed") == b and stage.state.body_named("Original") == null)
	show(b)
	check("name edit preserves equilibrium samples", is_same(stage.live_editor.curve.samples, samples))
	stage.push_trail(b)
	stage.push_trail(b)
	b.trail.update(b, stage.cam_pos)
	stage.update_sim_stats()
	check("teleport edit applies exact doubles", stage.edit_body(b, {"pos": PackedFloat64Array([7.123456789012345, -3.0, 4.0])}) == b
		and b.pos.x == 7.123456789012345 and b.pos.y == -3.0 and b.pos.z == 4.0 and b.vel.to_array() == vel)
	check("teleport immediately updates scene and visual placement", b.scene_pos.to_array() == b.pos.scaled(stage.state.scene_scale).to_array()
		and b.viz.group.position == b.scene_pos.rel_v3(stage.cam_pos))
	check("teleport breaks trail continuity even while paused", b.trail_count == 1
		and b.trail.mat.get_shader_parameter("u_ring").y == 1)
	check("teleport rebases manual energy change", stage.state.energy0 == null)
	show(b)
	check("vector edit preserves equilibrium samples", is_same(stage.live_editor.curve.samples, samples))
	stage.update_sim_stats()
	pos = b.pos.to_array()
	check("velocity-only edit preserves position", stage.edit_body(b, {"vel": [0.0, -2.0, 0.0]}) == b
		and b.pos.to_array() == pos and b.vel.to_array() == [0.0, -2.0, 0.0])
	check("velocity edit rebases manual energy change", stage.state.energy0 == null)
	check("unset vectors preserve live state", stage.edit_body(b, {"pos": null, "vel": null}) == b
		and b.pos.to_array() == pos and b.vel.to_array() == [0.0, -2.0, 0.0])
	stage.step_physics(0.25)
	check("next integration uses edited velocity", b.pos.y == -3.5)
	var spec: Dictionary = b.spec.duplicate(true)
	var viz = b.viz
	pos = b.pos.to_array()
	check("mixed invalid edit is rejected atomically", stage.edit_body(b, {"pos": [99.0, 0.0, 0.0], "vel": [NAN, 0.0, 0.0], "name": "Bad"}) == null
		and b.spec == spec and b.pos.to_array() == pos and b.name == "Renamed" and b.viz == viz)
	check("explicit type change is rejected atomically", stage.edit_body(b, {"type": "bh", "mass": 2.0, "pos": [99.0, 0.0, 0.0]}) == null
		and b.spec == spec and b.pos.to_array() == pos and b.viz == viz and b.type == "planet")
	check("same-type edit remains supported", stage.edit_body(b, {"type": "planet"}) == b)
	check("combined vectors apply without float32 rounding", stage.edit_body(b, {"pos": [9.123456789012345, 1.0, 2.0], "vel": [3.0, 4.0, 5.0]}) == b
		and b.pos.x == 9.123456789012345 and b.vel.to_array() == [3.0, 4.0, 5.0])
	check("empty name restores creation fallback", stage.edit_body(b, {"name": ""}) == b and b.name == "PLANET")
	check("unset name restores creation fallback", stage.edit_body(b, {"name": null}) == b and b.name == "PLANET")
	pos = b.pos.to_array()
	vel = b.vel.to_array()
	stage.transmute(b, "world", null)
	check("structural derivation preserves live vectors", b.pos.to_array() == pos and b.vel.to_array() == vel)
	var orphan := Derive.new_body(b.id, {"type": "planet", "mass": 3e-6})
	var orphan_spec: Dictionary = orphan.spec.duplicate(true)
	check("public edit rejects an alive same-ID orphan", stage.edit_body(orphan, {"mass": 6e-6}) == null
		and orphan.spec == orphan_spec and orphan.viz == null and orphan.mass == 3e-6)
	if orphan.viz != null: stage.detach_visual(orphan)
	stage.remove_body(b.id)
	b.alive = true
	check("public edit rejects a removed body even if marked alive", stage.edit_body(b, {"mass": 6e-6}) == null and b.viz == null)
	if b.viz != null: stage.detach_visual(b)
	stage.state.max_step = 1e-6

func edited_energy_reference() -> void:
	stage.clear_bodies()
	var star: Body = stage.spawn_body({"type": "star", "radiusSun": 1.0})
	stage.spawn_body({"type": "planet", "pos": [1.0, 0.0, 0.0]})
	stage.update_sim_stats()
	var energy: float = stage.state.energy0
	stage.edit_body(star, {"name": "Named"})
	check("name-only edits retain energy reference", stage.state.energy0 == energy)
	stage.edit_body(star, {"radiusSun": 2.0})
	check("radius-only edits retain energy reference", stage.state.energy0 == energy)
	stage.edit_body(star, {"softening": 0.01})
	check("softening change rebases energy", stage.state.energy0 == null)
	stage.clear_bodies()
	var neutron: Body = stage.spawn_body({"type": "neutron", "mass": 2.4, "spinFrac": 0.8})
	stage.spawn_body({"type": "planet", "pos": [1.0, 0.0, 0.0]})
	stage.update_sim_stats()
	stage.edit_body(neutron, {"spinFrac": 0.0})
	check("fixed-mass collapse changes type and rebases energy", neutron.type == "bh" and stage.state.energy0 == null)

func unavailable_energy() -> void:
	stage.clear_bodies()
	var body: Body = stage.spawn_body({"type": "bh", "mass": 1.0, "vel": [1e-300, 0.0, 0.0]})
	stage.update_sim_stats()
	check("unrepresentable nonzero energy is visibly unavailable", stage.hud.ids.setDrift.text == "unavailable"
		and not stage.hud.ids.setDrift.tooltip_text.is_empty())
	check("invalid energy cannot become a drift reference", stage.state.energy0 == null)
	stage.edit_body(body, {"vel": [1.0, 0.0, 0.0]})
	stage.update_sim_stats()
	# ½mv² plus the 1PN kinetic term ⅜mv⁴/c² (Physics.eih_energy).
	var expected := 0.5 + 0.375 / (Physics.C * Physics.C)
	check("representable energy recovers a finite reference", stage.state.energy0 == expected and stage.hud.ids.setDrift.text == "0"
		and stage.hud.ids.setDrift.tooltip_text.is_empty())
	stage.state.energy0 = NAN
	stage.update_sim_stats()
	check("invalid stored reference is discarded", stage.state.energy0 == expected and stage.hud.ids.setDrift.text == "0")
	stage.state.energy0 = 0.0
	stage.update_sim_stats()
	check("zero reference cannot hide a nonzero energy change", stage.hud.ids.setDrift.text == "unavailable"
		and stage.hud.ids.setDrift.tooltip_text.contains("zero-energy"))
	stage.edit_body(body, {"vel": [0.0, 0.0, 0.0]})
	stage.update_sim_stats()
	check("physical zero energy remains a valid diagnostic", stage.state.energy0 == 0.0 and stage.hud.ids.setDrift.text == "0")

# The climate panel's sliders are live edits of the focused world, through the same boundary.
func climate_edits() -> void:
	stage.load_preset("solar")
	var earth: Body = stage.state.body_named("Earth")
	var mars: Body = stage.state.body_named("Mars")
	var sun: Body = stage.state.body_named("Sun")
	stage.set_follow(sun)
	check("a star with no home world shows no climate", stage.climate_world() == null and not stage.hud.ids.climatePanel.visible)
	stage.set_follow(mars)
	check("the panel takes the focused world", stage.climate_world() == mars and stage.hud.ids.climatePanel.visible)
	check("its sliders read that world", absf(stage.hud.sliders.co2.value - U.log10(6.048e-3)) < 0.01
		and stage.hud.get_el("co2-val").text == "6.0 mbar")
	stage.hud_acc = 1.0
	stage.update_hud(0.0)
	check("the panel names the world and its era", stage.hud.get_el("cWorld").text == "Mars" and stage.hud.get_el("eraLabel").text == "Dry world")
	var earth_before: float = earth.climate.pressures.pCO2
	var visual = mars.viz
	var structure: Dictionary = mars.structure
	mars.spin_tracked = true
	mars.spin_omega = 123.0
	var cold_olr: float = mars.climate.olr(214.0)
	stage._on_slider("co2", 0.0)
	check("the slider edits the focused world", is_equal_approx(mars.climate.pressures.pCO2, 1.0) and is_equal_approx(mars.spec.pCO2, 1.0))
	check("and that traps more", mars.climate.olr(214.0) < cold_olr)
	check("and no other", earth.climate.pressures.pCO2 == earth_before and not earth.spec.has("T0"))
	stage._on_slider("co2", -6.0)
	check("the slider's foot is no CO₂", mars.climate.pressures.pCO2 == 0.0 and stage.hud.get_el("co2-val").text == "none")
	stage._on_slider("co2", -0.3)
	check("a climate edit keeps the visual and structure", is_same(mars.viz, visual) and is_same(mars.structure, structure))
	check("a climate edit keeps a tracked spin", mars.spin_tracked and mars.spin_omega == 123.0)
	stage._on_slider("mixed", 30.0)
	check("the depth slider edits the focused world", mars.climate.mixed_layer == 30.0 and mars.spec.mixedLayer == 30.0)
	var climate: Climate = mars.climate
	var inputs := [climate.mixed_layer, climate.pressures.duplicate()]
	var light: float = climate.gravity
	check("a mass edit is accepted", stage.edit_body(mars, {"mass": mars.mass * 1.1}) == mars)
	check("a mass edit keeps the climate and what the user set", is_same(mars.climate, climate)
		and [climate.mixed_layer, climate.pressures] == inputs)
	climate.step(1e-6, mars, stage.get_stars())
	check("a mass edit reaches the climate's gravity", climate.gravity > light)
	check("an albedo edit goes through the rebuild", stage.edit_body(mars, {"albedo": 0.4}) == mars and climate.albedo_base == 0.4 and not is_same(mars.viz, visual))
	var rejected_viz = mars.viz
	var co2_before: float = climate.pressures.pCO2
	check("a rejected climate edit reports null", stage.edit_body(mars, {"pCO2": 200.0}) == null)
	check("a rejected climate edit changes nothing", climate.pressures.pCO2 == co2_before and mars.spec.pCO2 == co2_before and is_same(mars.viz, rejected_viz))
	# Water: salinity needs no new surface; land and depth draw one, and reach the inventory.
	var sea_viz = earth.viz
	var earth_column: float = earth.climate.water_column
	check("a salinity edit is a climate edit", stage.edit_body(earth, {"salinity": 200.0}) == earth and earth.climate.salinity == 200.0 and is_same(earth.viz, sea_viz))
	check("and moves the ice edge", earth.climate.ebm.t_ice < LatitudeEBM.T_ICE)
	check("a land edit keeps the visual", stage.edit_body(earth, {"land": 0.0}) == earth and is_same(earth.viz, sea_viz))
	check("and moves its crust", absf(float(earth.viz.surf_mat.get_shader_parameter("uCrustT")) - Terrain.crust_threshold(0.0)) < 1e-6)
	check("and reaches the inventory", earth.climate.water_column > earth_column)
	check("and the era", earth.climate.classify(288.0).key == "WATER_WORLD")
	check("a depth edit reaches the inventory", stage.edit_body(earth, {"oceanDepth": 1.0}) == earth and near_ratio(earth.climate.water_column, 1.0 * 1000.0 * Climate.RHO_SEA))
	check("no depth under a stated ocean is rejected", stage.edit_body(earth, {"oceanDepth": 0.0}) == null)
	check("no sea left is a dry world", stage.edit_body(earth, {"oceanDepth": 0.0, "oceans": false}) == earth and not earth.climate.wet and earth.climate.classify(288.0).key == "DRY")
	check("and back again", stage.edit_body(earth, {"oceanDepth": 3.7, "oceans": true}) == earth and earth.climate.wet and earth.climate.ocean == 1.0)
	stage.edit_body(earth, {"land": 0.32, "salinity": 35.0})
	# The shell follows the air, without a rebuild, unless the look is stated.
	var earth_viz = earth.viz
	var thick_before := float(earth_viz.atmo_mat.get_shader_parameter("uThick"))
	stage.edit_body(earth, {"pN2": 8.0})
	stage.animate(1.0 / 60.0)
	var thick_after := float(earth_viz.atmo_mat.get_shader_parameter("uThick"))
	print("EDITORCHECK sky thick %s to %s" % [thick_before, thick_after])
	check("an air edit keeps the visual", is_same(earth.viz, earth_viz))
	check("and thickens the shell", thick_after > thick_before * 1.2)
	var mars_thick := float(mars.viz.atmo_mat.get_shader_parameter("uThick"))
	stage.edit_body(mars, {"pN2": 8.0})
	stage.animate(1.0 / 60.0)
	check("a stated depth stays stated", float(mars.viz.atmo_mat.get_shader_parameter("uThick")) == mars_thick)
	stage.edit_body(earth, {"pN2": Climate.EARTH_AIR.pN2})
	climate.T = 123.0
	stage._on_climate_reset()
	check("reset acts on the focused world", climate.T == 288.0 and climate.era.key == "DRY")
	stage.set_follow(mars)
	stage.hud_acc = 1.0
	stage.update_hud(0.0)
	check("the panel reads the air and names no sea", stage.hud.get_el("cAir").text.ends_with("bar") and stage.hud.get_el("cSea").text == "none")
	stage.set_follow(earth)
	var was: float = stage.hud.sliders.mixed.value
	check("focusing another world moves the sliders", was == 60.0 and stage.hud.get_el("mixed-val").text == "60 m")
	stage.remove_body(earth.id)
	check("removing the panel's world empties it", stage.climate_world() == null and not stage.hud.ids.climatePanel.visible)
	stage.load_preset("trisolaris")
	var home: Body = stage.get_home()
	check("a star's focus falls back to the home world", stage.state.focus_id != home.id and stage.climate_world() == home)
	stage._on_slider("co2", -2.0)
	check("the fallback's slider edits the home world", is_equal_approx(home.climate.pressures.pCO2, 0.01) and is_equal_approx(home.spec.pCO2, 0.01))

func near_ratio(a: float, b: float) -> bool:
	return absf(a - b) < 1e-3 * absf(b)

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
	live_state_edits()
	edited_energy_reference()
	unavailable_energy()
	climate_edits()
	await pending_body_switch()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("EDITORCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
