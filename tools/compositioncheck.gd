extends Node

# The composition editor through the controls the app uses: pick a mix, read the preview, spawn,
# confirm the world is the one previewed; edit it, leave, return, remove it. Reference numbers are
# outside ones (NSSDC); the model's calibration is realismcheck's business.
const Catch = preload("res://tools/coursecheck.gd").Catch
var catcher := Catch.new()
var stage: Node
var foundry
var checks := 0
var failures := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol

# Everything a preview must not touch, as a comparable value.
func digest() -> String:
	var rows := [stage.state.next_id, stage.state.bodies.size(), stage.state.sim_years, stage.state.focus_id, stage.rest_spawn_angle]
	for b: Body in stage.state.bodies:
		rows.append([b.id, b.name, b.mass, b.pos.to_array(), b.vel.to_array(), var_to_str(b.spec)])
		if b.climate != null:
			rows.append([b.climate.T, b.climate.time, b.climate.ice, b.climate.ocean, b.climate.history.size(), var_to_str(b.climate.pressures), b.climate.sky_serial])
	return var_to_str(rows)

func pick(mix: String) -> void:
	var options: Array = foundry.comp.mix.options
	for i in options.size():
		if options[i][0] == mix:
			foundry.comp.mix.select(i)
			foundry.comp.mix._on_item(i)
			return
	check("the picker offers %s" % mix, false)

func set_orbit(au: float) -> void:
	foundry.orbit.set_v(U.log10(au))
	foundry.orbit.moved.emit(foundry.orbit.value)

func set_mass_earths(me: float) -> void:
	foundry.rows.mass.set_v(U.log10(me * Structure.M_EARTH_SUN))
	foundry.rows.mass.moved.emit(foundry.rows.mass.value)

# `years` through step_physics, whose turns step every climate, in steps the orbit resolves.
func run_stage(b: Body, years: float) -> void:
	var steps := 400
	var started: float = b.climate.time
	for i in steps: stage.step_physics(years / steps)
	# A world that was not the panel's or home's may owe its last turn.
	b.climate.catch_up(0.0, b, stage.get_stars())
	check("the climate ran on the stage's clock (%.1f yr)" % (b.climate.time - started), near(b.climate.time - started, years, 1e-6 * years + 1e-9))

func spawned_matches(label: String, p: Dictionary, b: Body) -> void:
	var cl: Climate = b.climate
	check("%s: spawned" % label, cl != null)
	if cl == null: return
	check("%s: spawned air is the previewed air" % label, cl.pressures == p.inputs.pressures)
	check("%s: spawned sea is the previewed sea" % label, cl.land == p.inputs.land and cl.ocean_depth == p.inputs.oceanDepth
		and cl.salinity == p.inputs.salinity and cl.wet == p.inputs.oceans)
	check("%s: spawned surface is the previewed surface" % label, cl.albedo_base == p.inputs.albedoBase and cl.mixed_layer == p.inputs.mixedLayer)
	check("%s: same start temperature (%s, %s)" % [label, p.startT, cl.T], near(cl.T, float(p.startT), 1e-3 * maxf(cl.T, 3.0)))
	check("%s: same sunlight (%s, %s)" % [label, p.S, cl.S], near(cl.S, float(p.S), 2e-3 * maxf(cl.S, 1e-6)))
	check("%s: same gravity" % label, near(cl.gravity, float(p.gravity), 1e-9 * cl.gravity))
	check("%s: finite temperature" % label, is_finite(cl.T) and is_finite(float(p.T)) and float(p.T) > 0.0)

# The Foundry path end to end, then run the stage to the horizon and compare the settled numbers.
func flow(label: String, mix: String, orbit_au: float, want_era: String, settle_k := 1.5) -> Body:
	pick(mix)
	if orbit_au > 0.0: set_orbit(orbit_au)
	var before: String = digest()
	foundry.update()
	var p: Dictionary = foundry.preview
	check("%s: preview changes nothing on the stage" % label, digest() == before)
	check("%s: preview has no error" % label, not p.is_empty() and not p.has("error"))
	if want_era != "": check("%s: era reads %s (%s)" % [label, want_era, p.era.key], p.era.key == want_era)
	var count: int = stage.state.bodies.size()
	foundry.spawn()
	check("%s: one body more" % label, stage.state.bodies.size() == count + 1)
	var b: Body = stage.state.bodies[-1]
	spawned_matches(label, p, b)
	# The stage's own clock and climate turns, so the orbit is flown as the app flies it.
	var far := float(p.T)
	run_stage(b, 100.0)
	check("%s: stage after 100 yr lands where the preview said (%.1f K, %.1f K)" % [label, b.climate.T, far],
		near(b.climate.T, far, settle_k))
	stage.remove_body(b.id)
	return b

func pie_is_honest() -> void:
	var pie: CompositionPie = foundry.comp.pie
	pick("earth")
	set_orbit(1.0)
	foundry.update()
	var sum := 0.0
	for s in pie.shares: sum += s.deg
	check("the pie's slices sum to the whole circle", near(sum, 360.0, 1e-6))
	var by_key := {}
	for i in pie.rows.size(): by_key[pie.rows[i].key] = i
	check("every gas of today's air has a row", by_key.has("pN2") and by_key.has("pO2") and by_key.has("pAr") and by_key.has("pCO2") and by_key.has("pCH4"))
	check("water has a row of its own", by_key.has("H2O") and pie.rows[by_key.H2O].source == "follows")
	check("stated gases say so", pie.rows[by_key.pN2].source == "stated")
	check("CO₂ is drawn thinner than a pixel, and flagged", pie.shares[by_key.pCO2].thin)
	check("CH₄ too", pie.shares[by_key.pCH4].thin)
	check("N₂ is not", not pie.shares[by_key.pN2].thin)
	check("a thin gas still reads in ppm", CompositionPie.format_share(float(pie.shares[by_key.pCO2].share)).ends_with("ppm"))
	check("CO₂ reads 420 ppm of today's air (NOAA's 2023 mean: 419)", near(float(pie.shares[by_key.pCO2].share), 419e-6, 10e-6))
	check("the tooltip names it", pie._get_tooltip(Vector2(CompositionPie.LEGEND_X + 4.0, by_key.pCO2 * CompositionPie.ROW_H + 2.0)).contains("CO₂"))
	check("a row's height is measured", pie.get_combined_minimum_size().y >= pie.rows.size() * CompositionPie.ROW_H)
	pick(Composition.DRAWN)
	foundry.update()
	var drawn_gases := 0
	for r in pie.rows:
		if r.source == "drawn": drawn_gases += 1
	check("a seeded draw shows drawn gases", drawn_gases > 0 and foundry.inputs.is_empty())
	pick("bare")
	foundry.update()
	check("an airless world has no rows, and says so", pie.rows.is_empty())
	check("and draws a world of bare ground", near(float(pie.surface.land), 1.0, 1e-9))
	pick("ocean")
	foundry.update()
	check("a global ocean has no land on its strip", near(float(pie.surface.land), 0.0, 1e-9) or pie.surface.ice > 0.5)

func gases_reach_the_ui() -> void:
	for key in Atmosphere.GASES:
		check("%s has an editor row and a domain" % key, foundry.comp.gases.has(key) and ClimateInputs.DOMAIN.has(key))
		var row: Dictionary = foundry.comp.gases[key]
		var hi: float = ClimateInputs.DOMAIN[key][1]
		check("%s's slider stops at its domain" % key, near(pow(10.0, row.slider.max_value), hi, hi * 1e-6))

func rejected() -> void:
	var comp: CompositionEditor = foundry.comp
	pick("earth")
	set_orbit(1.0)
	foundry.update()
	var inputs: Dictionary = foundry.inputs.duplicate()
	var row: Dictionary = comp.gases.pCO2
	row.field.text_submitted.emit("500")
	check("typing past CO₂'s domain says the limit", comp.limit_el.visible and (comp.limit_el as Prose).text.contains("100"))
	check("and changes nothing", foundry.inputs == inputs)
	row.field.text_submitted.emit("-3")
	check("a negative pressure is refused", comp.limit_el.visible and foundry.inputs == inputs)
	row.field.text_submitted.emit("banana")
	check("a word is refused", comp.limit_el.visible and (comp.limit_el as Prose).text.contains("not a pressure") and foundry.inputs == inputs)
	row.field.text_submitted.emit("4 mbar")
	check("a good value clears the limit and lands", not comp.limit_el.visible and near(float(foundry.inputs.pCO2), 4e-3, 1e-9))
	check("that makes it custom", comp.mix.value == Composition.CUSTOM)
	comp.gases.pN2.field.text_submitted.emit("150")
	check("150 bar of N₂ is fine alone", near(float(foundry.inputs.pN2), 150.0, 1e-6))
	comp.gases.pCO2.field.text_submitted.emit("90")
	check("but the gases cannot sum past 200 bar", comp.limit_el.visible and (comp.limit_el as Prose).text.contains("200") and near(float(foundry.inputs.pCO2), 4e-3, 1e-9))
	check("what it refused is not in the spawn", near(float(foundry.spawn_spec().pCO2), 4e-3, 1e-9))
	pick("earth")
	check("picking a mix clears the limit", not comp.limit_el.visible)
	comp.gases.pCO2.slider.moved.emit(comp.gases.pCO2.slider.min_value)
	check("a slider's foot is none at all", float(foundry.inputs.pCO2) == 0.0)
	pick("earth")
	comp._on_remove("pCH4")
	foundry.update()
	check("removing a gas takes it out of the air", float(foundry.preview.inputs.pressures.pCH4) == 0.0)
	var offered := comp.add_gas.options.map(func(o): return o[0])
	check("and offers it again", offered.has("pCH4"))
	comp.add_gas.select(offered.find("pCH4"))
	comp.add_gas._on_item(offered.find("pCH4"))
	check("adding a gas puts it back inside its domain", float(foundry.inputs.pCH4) > 0.0 and float(foundry.inputs.pCH4) <= ClimateInputs.DOMAIN.pCH4[1])
	pick("earth")

func live_edit() -> void:
	stage.state.paused = true
	pick("earth")
	set_orbit(1.0)
	foundry.spawn()
	var b: Body = stage.state.bodies[-1]
	var editor = stage.live_editor
	var comp: CompositionEditor = editor.comp
	stage.state.focus_id = b.id
	stage.open_cross_section()
	check("the world's editor shows its controls", comp.visible)
	check("the editor names the mix it was given", comp.mix.value == "earth")
	var viz = b.viz
	var before: String = digest()
	var p := Composition.preview_edit(b, {"pCO2": 0.2}, stage.get_stars())
	check("an edit's preview changes nothing", digest() == before and b.climate.pressures.pCO2 != 0.2)
	comp.gases.pCO2.field.text_submitted.emit("0.2 bar")
	editor._flush()
	check("the typed value reaches the world", near(float(b.climate.pressures.pCO2), 0.2, 1e-9) and near(float(b.spec.pCO2), 0.2, 1e-9))
	check("and keeps its visual", is_same(b.viz, viz))
	check("it becomes custom", comp.mix.value == Composition.CUSTOM)
	var settled := float(p.T)
	run_stage(b, 100.0)
	check("the world warms to what the edit's preview said (%.1f K, %.1f K)" % [b.climate.T, settled], near(b.climate.T, settled, 1.5))
	stage.live_editor.sync(b)
	check("the slider follows the world", near(comp.gases.pCO2.slider.value, U.log10(0.2), 0.01))
	var co2 := float(b.climate.pressures.pCO2)
	comp.gases.pCO2.field.text_submitted.emit("900")
	check("an edit past the domain says the limit", comp.limit_el.visible)
	editor._flush()
	check("and changes nothing", b.climate.pressures.pCO2 == co2 and b.spec.pCO2 == co2)
	# Land and depth are uniforms, not a rebuild.
	comp.land.moved.emit(0.02)
	editor._flush()
	check("a land edit reaches the climate", near(b.climate.land, 0.02, 1e-9))
	check("and the same visual's crust", is_same(b.viz, viz) and near(float(b.viz.surf_mat.get_shader_parameter("uCrustT")), Terrain.crust_threshold(0.02), 1e-5))
	# Leave and return: the panel is that world's each time.
	comp.gases.pCO2.field.text_submitted.emit("900")
	check("a refusal is on screen as we leave", comp.limit_el.visible)
	var mars: Body = stage.state.body_named("Mars")
	stage.state.focus_id = mars.id
	stage.open_cross_section()
	check("another world shows its own air", near(comp.gases.pCO2.slider.value, U.log10(float(mars.climate.pressures.pCO2)), 0.01))
	check("and its own mix, which is no mix", comp.mix.value == Composition.CUSTOM)
	check("the limit message did not follow", not comp.limit_el.visible)
	stage.state.focus_id = b.id
	stage.open_cross_section()
	check("returning restores the first world's air", near(comp.gases.pCO2.slider.value, U.log10(0.2), 0.01))
	check("a preview on a world with no change holds", is_same(b.viz, viz))
	stage.state.focus_id = stage.state.body_named("Sun").id
	stage.open_cross_section()
	check("a star has no composition controls", not comp.visible)
	stage.state.focus_id = b.id
	stage.open_cross_section()
	var cl: Climate = b.climate
	comp.gases.pCO2.field.text_submitted.emit("0.01")
	stage.remove_body(b.id)
	check("removing it clears the editor", editor.body == null and not comp.visible)
	check("and drops the queued patch", editor.pending == null)
	check("which never landed", cl.pressures.pCO2 == 0.2 or cl.pressures.pCO2 == 0.01)

func extremes() -> void:
	stage.load_preset("solar")
	stage.set_process(false)
	stage.state.paused = true
	foundry.refresh()
	set_mass_earths(1.0)
	flow("Earth at 1 AU, the Sun as parent", "earth", 1.0, "STABLE")
	flow("dry world", "bare", 1.0, "DRY")
	flow("global ocean", "ocean", 1.0, "WATER_WORLD")
	flow("ice shell", "ocean", 2.5, "ICE_SHELL")
	flow("thin Mars-like air", "mars", 1.52, "DRY")
	flow("dense Venus-like air", "venus", 0.72, "DRY")
	flow("seeded draw", Composition.DRAWN, 1.3, "")
	set_mass_earths(0.012)
	flow("low gravity, Earth's mix", "earth", 1.0, "")
	flow("low gravity, airless", "bare", 1.0, "DRY")
	set_mass_earths(1.0)
	# True scale changes the picture, never the model.
	stage.set_true_scale(true)
	foundry.update()
	flow("true scale", "earth", 1.0, "STABLE")
	stage.set_true_scale(false)
	# A world with no stars and a blank stage.
	stage.clear_bodies()
	foundry.update()
	pick("earth")
	check("an empty stage still previews", not foundry.preview.is_empty() and not foundry.preview.has("error"))
	check("the orbit row gives way to spawning at rest", not foundry.orbit_row.visible)
	check("no stars: no sunlight", foundry.preview.S == 0.0)
	check("no stars: a finite, frozen world", is_finite(float(foundry.preview.T)) and float(foundry.preview.T) < 100.0)
	var p: Dictionary = foundry.preview
	foundry.spawn()
	spawned_matches("no stars", p, stage.state.bodies[-1])
	stage.clear_bodies()
	stage.load_preset("solar")
	stage.set_process(false)
	stage.state.paused = true
	foundry.refresh()

# NSSDC's numbers, none of which fitted anything these read.
func references() -> void:
	var star: Body = stage.state.body_named("Sun")
	var at := func(au: float) -> Array: return (DVec3.new(au, 0.0, 0.0).add(star.pos)).to_array()
	var earth := {"type": "planet", "mass": 3.003e-6, "radiusKm": 6371.0, "pos": at.call(1.0)}
	earth.merge(Composition.MIXES.earth.inputs)
	var mars := {"type": "planet", "mass": 3.227e-7, "radiusKm": 3389.5, "pos": at.call(1.524)}
	mars.merge(Composition.MIXES.mars.inputs)
	var venus := {"type": "planet", "mass": 2.448e-6, "radiusKm": 6051.8, "pos": at.call(0.723)}
	venus.merge(Composition.MIXES.venus.inputs)
	var rows := {"Earth": [earth, 8.5, 28.97], "Mars": [mars, 11.1, 43.34], "Venus": [venus, 15.9, 43.45]}
	for name in rows:
		var p := Composition.preview(rows[name][0], [star], 0)
		check("%s's scale height is NSSDC's (%.1f km, %.1f)" % [name, p.scaleM / 1000.0, rows[name][1]], near(p.scaleM / 1000.0, rows[name][1], 0.08 * rows[name][1]))
		check("%s's mean molecular mass is NSSDC's (%.2f, %.2f)" % [name, p.molar * 1000.0, rows[name][2]], near(p.molar * 1000.0, rows[name][2], 0.4))
	var moon := {"type": "planet", "mass": 3.69e-8, "radiusKm": 1737.4, "pos": at.call(1.0), "albedoBase": 0.11, "oceans": false, "mixedLayer": 1.5, "pCO2": 0.0, "pN2": 0.0, "pO2": 0.0, "pAr": 0.0, "pCH4": 0.0, "pSO2": 0.0}
	var pm := Composition.preview(moon, [star], 0)
	check("the Moon's no-air balance is NSSDC's 270.4 K (%.1f K)" % pm.airlessT, near(pm.airlessT, 270.4, 1.5))
	check("and has no greenhouse", near(pm.T, pm.airlessT, 2.0))
	check("and no sky", pm.sky == 0x05060a)
	check("Earth's air reads NSSDC's 1.014 bar", near(Composition.preview(earth, [star], 0).air, 1.014, 0.001))

func seeds() -> void:
	var star: Body = stage.state.body_named("Sun")
	var spec := {"type": "planet", "mass": 3e-6, "radiusKm": 6371.0, "pos": DVec3.new(1.2, 0.0, 0.0).add(star.pos).to_array(), "seed": 12345}
	var a := Composition.preview(spec, [star], 0)
	var b := Composition.preview(spec, [star], 0)
	check("the same seed draws the same world", a.inputs == b.inputs and a.T == b.T)
	spec.seed = 54321
	var c := Composition.preview(spec, [star], 0)
	check("another seed draws another", a.inputs != c.inputs)
	check("the run's seed moves it too", Composition.preview({"type": "planet", "mass": 3e-6, "radiusKm": 6371.0, "pos": spec.pos, "seed": 12345}, [star], 7).inputs != a.inputs)

func cost() -> void:
	pick("earth")
	var started := Time.get_ticks_usec()
	for i in 20: foundry.update()
	var us := (Time.get_ticks_usec() - started) / 20
	print("COMPOSITIONCHECK PROFILE foundry_update_us=%d" % us)
	var s: Dictionary = foundry.placed_spec()
	started = Time.get_ticks_usec()
	for i in 20: Composition.preview(s, stage.get_stars(), 0)
	us = (Time.get_ticks_usec() - started) / 20
	print("COMPOSITIONCHECK PROFILE preview_us=%d" % us)
	check("a preview fits a frame (%d µs)" % us, us < 16000)

func _ready() -> void:
	OS.add_logger(catcher)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	for i in 2: await get_tree().process_frame
	stage._start("sandbox")
	stage.load_preset("solar")
	stage.set_process(false)
	stage.state.paused = true
	foundry = stage.foundry
	foundry.set_type("planet")
	foundry.update()
	gases_reach_the_ui()
	pie_is_honest()
	rejected()
	seeds()
	references()
	live_edit()
	extremes()
	cost()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("COMPOSITIONCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
