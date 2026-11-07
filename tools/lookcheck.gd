extends Node

# The look follows the climate. Headless: the derived values against outside numbers, the ease, no
# rebuild, and physics untouched. With pixels=1 it also renders contrasting worlds and judges the
# frames (quality=low|high picks the setting; out=/abs/dir keeps them).
const Catch = preload("res://tools/coursecheck.gd").Catch
var catcher := Catch.new()
var stage: Node
var checks := 0
var failures := 0
var args := {}

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol

func climate_at(inputs: Dictionary, t: float) -> Climate:
	var c := Climate.new(inputs)
	c.T = t
	c.S = 1.0
	c.ebm.reset(t - 273.15)
	c.humidity = minf(1.0, pow(2.0, (t - 288.0) / 10.0) * 0.5)
	c.ice = maxf(float(c.albedo(t).ice), 0.0)
	c.era = c.classify(t)
	return c

func references() -> void:
	# Precipitation: Earth is the anchor. Its energy and its slopes are what is tested.
	var earth := climate_at({}, 288.0)
	var p0 := ClimateLook.precipitation_mm(earth)
	check("today's rain is the anchor's 990 mm (%.0f)" % p0, near(p0, 990.0, 1.0))
	var lp := p0 / Rocketry.YR_S * Climate.L_VAPOUR
	check("which is a latent flux inside the 65–80 W/m² budgets give (%.0f)" % lp, lp > 65.0 and lp < 80.0)
	var warm := ClimateLook.precipitation_mm(climate_at({}, 291.0))
	check("warming raises rain near 2%%/K, not vapour's 7%%/K (%.1f%%/K)" % ((warm / p0 - 1.0) / 3.0 * 100.0), near((warm / p0 - 1.0) / 3.0, 0.02, 0.003))
	var cold := ClimateLook.precipitation_mm(climate_at({}, 278.0))
	check("a colder world is limited by its vapour", near(log(cold / p0) / -10.0, 0.07, 0.002))
	# Miami against Whittaker & Likens's ranges (1975), as Kellman & Tackaberry quote them.
	var tropic := ClimateLook.npp(299.0, 2500.0)
	check("a tropical forest's NPP is in 1000–3500 g/m²/yr (%.0f)" % tropic, tropic > 1000.0 and tropic < 3500.0)
	var temperate := ClimateLook.npp(283.0, 1000.0)
	check("a temperate forest's is in 600–2500 (%.0f)" % temperate, temperate > 600.0 and temperate < 2500.0)
	var tundra := ClimateLook.npp(263.0, 250.0)
	check("tundra's is near 140 (%.0f)" % tundra, tundra > 70.0 and tundra < 280.0)
	check("no rain, no growth", ClimateLook.npp(300.0, 0.0) == 0.0)
	# Frost: James, Kieffer & Paige's fit against measured sublimation points.
	check("CO₂ freezes near 148 K at Mars's 6 mbar (%.1f)" % ClimateLook.co2_frost_k(0.006), near(ClimateLook.co2_frost_k(0.006), 148.0, 1.0))
	check("and at dry ice's 194.7 K at 1 atm (%.1f)" % ClimateLook.co2_frost_k(1.01325), near(ClimateLook.co2_frost_k(1.01325), 194.7, 1.5))
	# Today's Earth draws as it always did.
	var t := ClimateLook.targets(earth, {})
	check("today's sea is at the datum", t.uSeaKm == 0.0)
	check("today's land grows fully", near(float(t.uBiota), 1.0, 0.01))
	check("nothing dries it", near(float(t.uArid), 0.0, 1e-9))
	check("water freezes where sea water does", near(float(t.uFrostK), 273.0, 1e-6))
	check("the surface's haze is its old constant", near(float(t.uHaze), ClimateLook.HAZE_EARTH, 0.01))
	var frozen := climate_at({}, 240.0)
	frozen.ice = 0.8
	check("the drawn ice is the climate's", ClimateLook.targets(frozen, {}).uIce == 0.8)
	check("today's cloud rule is unchanged over today's sea", near(ClimateLook.cover_of(climate_at({"land": 0.29}, 288.0)), climate_at({"land": 0.29}, 288.0).clouds, 1e-6))
	var dry_sky := climate_at({"land": 0.9}, 295.0)
	check("a dry continent's sky is clearer than its humidity alone", ClimateLook.cover_of(dry_sky) < dry_sky.clouds)

func water_and_air() -> void:
	var dry := Composition.MIXES.bare.inputs
	var t := ClimateLook.targets(climate_at(dry, 400.0), {})
	check("an airless rock has no sea", t.uSeaKm == ClimateLook.SEA_GONE_KM)
	check("nothing grows on it", t.uBiota == 0.0)
	check("it has nothing to frost", t.uFrostK == 0.0)
	check("no deck", t.cover == 0.0)
	check("craters stand", near(float(t.uCrater), ClimateLook.CRATER_AIRLESS, 1e-6))
	check("and it does not glow", t.uScorch == 0.0)
	var mars := climate_at(Composition.MIXES.mars.inputs, 214.0)
	t = ClimateLook.targets(mars, {})
	check("Mars's air freezes at Mars's frost point (%.1f)" % t.uFrostK, near(float(t.uFrostK), 148.0, 1.5))
	check("and has no deck of its own", t.cover == 0.0)
	var venus := climate_at(Composition.MIXES.venus.inputs, 737.0)
	venus.set_world(2.448e-6, 6051.8 * Physics.AU_PER_KM)
	t = ClimateLook.targets(venus, {})
	check("Venus's sulphur makes an opaque deck (%.3f)" % t.cover, float(t.cover) > 0.99)
	check("and it glows at 737 K", float(t.uScorch) > 0.9)
	# More land, less rain.
	var last := -1.0
	var rising := true
	for land in [0.0, 0.29, 0.6, 0.9, 0.99]:
		var a := ClimateLook.arid_of(climate_at({"land": land}, 288.0))
		if land > 0.29 and a <= last: rising = false
		last = a
	check("drier as the land grows", rising and last > 0.8)
	check("a sea past Earth's waters no better", ClimateLook.arid_of(climate_at({"land": 0.0}, 288.0)) == 0.0)
	var boiled := climate_at({}, 400.0)
	check("heat dries land even beside a sea", ClimateLook.arid_of(boiled) > 0.5)
	# Vegetation falls off at each end.
	var green := ClimateLook.biota_of(climate_at({}, 288.0))
	check("colder grows less", ClimateLook.biota_of(climate_at({}, 275.0)) < green)
	check("a snowball grows nothing", ClimateLook.biota_of(climate_at({}, 225.0)) < 0.01)
	check("past the heat limit nothing grows", ClimateLook.biota_of(climate_at({}, 355.0)) == 0.0)
	check("little on a world with too little water for a full sky", ClimateLook.biota_of(climate_at({"oceanDepth": 1e-5, "land": 0.0}, 288.0)) < 0.6)
	# The sea falls as it goes.
	var half := climate_at({}, 288.0)
	half.ocean = 0.5
	check("half the water, the datum falls (%.2f km)" % ClimateLook.sea_km_of(half, false), ClimateLook.sea_km_of(half, false) < -2.0 and ClimateLook.sea_km_of(half, false) > -5.0)
	half.ocean = 0.0
	check("none left, no liquid", ClimateLook.sea_km_of(half, false) == ClimateLook.SEA_GONE_KM)
	# Stated beats derived.
	var stated := {"cloudCover": 0.11, "arid": 0.22, "biota": 0.33, "haze": 0.44, "frostK": 55.0, "crater": 0.66, "surfaceK": 777.0}
	t = ClimateLook.targets(climate_at({}, 288.0), stated)
	check("a stated look wins", t.cover == 0.11 and t.uArid == 0.22 and t.uBiota == 0.33 and t.uHaze == 0.44 and t.uFrostK == 55.0 and t.uCrater == 0.66 and t.uMeanK == 777.0)
	t = ClimateLook.targets(climate_at({}, 288.0), {"hot": true})
	check("a stated dry surface wins over a draw", t.uSeaKm == ClimateLook.SEA_GONE_KM and t.uIce == 0.0 and t.uBiota == 0.0)
	t = ClimateLook.targets(climate_at({}, 288.0), {"hot": true, "oceans": true})
	check("until oceans is edited on", t.uSeaKm == 0.0)
	# The rendered cap against the latitude model.
	var edge_world := Climate.new()
	var lit := Body.new()
	lit.mass = 1.0; lit.radius = 0.1; lit.pos = DVec3.new(); lit.vel = DVec3.new(); lit.activity = null; lit.luminosity = 1.0
	var at := Body.new()
	at.mass = 3e-6; at.radius = 6371.0 * Physics.AU_PER_KM; at.pos = DVec3.new(1.0, 0.0, 0.0); at.vel = DVec3.new()
	at.obliquity = 0.4091; at.spec = {"obliquity": 0.4091}
	for i in 400: edge_world.step(0.5, at, [lit])
	var drawn_edge := rad_to_deg(asin(clampf(1.0 - 1.05 * edge_world.ice, -1.0, 1.0)))
	var model_edge := rad_to_deg(asin(edge_world.ice_edge))
	check("the drawn cap sits on the model's ice line (%.1f°, %.1f°)" % [drawn_edge, model_edge], near(drawn_edge, model_edge, 4.0))
	# The cover table.
	var worst := 0.0
	for i in range(1, 200):
		var c := float(i) / 200.0
		worst = maxf(worst, absf(Terrain.cloud_z_table(c) - Terrain.cloud_global_z(c)))
	print("LOOKCHECK cover table worst z error %.5f" % worst)
	check("the cover table is within 0.02 probit of the exact bisection", worst < 0.02)
	check("its ends are exact", Terrain.cloud_z_table(0.0) == -8.0 and Terrain.cloud_z_table(1.0) == 8.0)

func uniform(viz, key: String) -> float:
	return float(viz.surf_mat.get_shader_parameter(key))

func viz_of(b: Body):
	return b.viz.inner if b.viz is Bodies.AccretionWrap else b.viz

# Physical state, in the order of what visual updates must never touch.
func physics_digest() -> String:
	var rows := []
	for b: Body in stage.state.bodies: rows.append([b.id, b.mass, b.mass0, b.pos.to_array(), b.vel.to_array(), b.radius, b.spin_frac])
	return var_to_str(rows)

func stage_flow() -> void:
	stage.load_preset("solar")
	stage.set_process(false)
	stage.state.paused = true
	var b: Body = stage.spawn_body(stage.place_spawn(U.merged({"type": "planet", "mass": 3e-6, "name": "Edited", "seed": 11}, Composition.MIXES.earth.inputs), {"a_au": 1.0, "ang": 0.5, "off": 0.5}))
	var viz = viz_of(b)
	stage.animate(1.0 / 60.0)
	var before := physics_digest()
	var meshes := [viz.surface, viz.clouds, viz.atmo]
	check("a new world snaps to its look on its first frame", near(uniform(viz, "uMeanK"), b.climate.T, 0.2))
	var old_t: float = b.climate.T
	# A far warmer world: its temperature must arrive, not jump.
	b.climate.T = 340.0
	b.climate.humidity = 1.0
	stage.animate(1.0 / 60.0)
	var first := uniform(viz, "uMeanK")
	check("a change does not snap (%.1f K of %.1f)" % [first, 340.0], first < 340.0 - 5.0)
	var writes_during := 0
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 6000:
		stage.animate(1.0 / 60.0)
		b.climate.T = 340.0
		await get_tree().process_frame
		if near(uniform(viz, "uMeanK"), 340.0, 0.1): break
	check("it arrives in a few seconds (%.1f K)" % uniform(viz, "uMeanK"), near(uniform(viz, "uMeanK"), 340.0, 0.2))
	b.climate.T = old_t
	check("no frame of that rebuilt the visual", is_same(viz_of(b), viz) and is_same(viz.surface, meshes[0]) and is_same(viz.clouds, meshes[1]) and is_same(viz.atmo, meshes[2]))
	check("no frame of that moved a body", physics_digest() == before)
	# Once there, nothing more to write.
	var binder: ClimateLook.Binder = viz._look
	binder.ease_to(ClimateLook.targets(b.climate, b.spec))
	for i in 8000:
		binder.value = binder.value
		var moved := binder.ease_to(ClimateLook.targets(b.climate, b.spec))
		if moved.is_empty(): break
		OS.delay_usec(800)
	check("a settled world writes no uniforms", binder.ease_to(ClimateLook.targets(b.climate, b.spec)).is_empty())
	# Real edits through the boundary, with the frames to carry them.
	await edit_to(b, {"land": 0.05}, "uCrustT", Terrain.crust_threshold(0.05))
	check("a land edit keeps the visual", is_same(viz_of(b), viz))
	await edit_to(b, {"land": 0.29, "oceanDepth": 8.0}, "uOceanDepth", 8.0 * ClimateLook.ABYSS_RATIO)
	await edit_to(b, {"oceans": false}, "uSeaKm", ClimateLook.SEA_GONE_KM)
	check("no oceans, no biota", near(uniform(viz, "uBiota"), 0.0, 0.01))
	await edit_to(b, {"oceans": true, "oceanDepth": 3.7, "salinity": 200.0}, "uFrostK", 273.0 + Climate.freezing_point(200.0) - Climate.freezing_point(35.0))
	# An airless world grows a shell and a deck when it is given air.
	var rock: Body = stage.spawn_body(stage.place_spawn(U.merged({"type": "planet", "mass": 3e-6, "name": "Rock", "seed": 12}, Composition.MIXES.bare.inputs), {"a_au": 1.0, "ang": 2.5, "off": 0.5}))
	stage.animate(1.0 / 60.0)
	var rv = viz_of(rock)
	check("an airless world has no shell", rv.atmo == null and rv.clouds == null)
	var haze0: float = uniform(rv, "uHaze")
	stage.edit_body(rock, Composition.mix_patch("earth"))
	stage.animate(1.0 / 60.0)
	check("given air, it grows a shell", rv.atmo != null and rv.atmo.is_inside_tree())
	check("and a deck", rv.clouds != null)
	check("without a new visual", is_same(viz_of(rock), rv))
	await settle_frames(rock, 4000)
	check("its haze comes up", uniform(rv, "uHaze") > haze0 + 0.3)
	check("its craters fill", uniform(rv, "uCrater") < 0.05)
	stage.edit_body(rock, Composition.mix_patch("venus"))
	stage.animate(1.0 / 60.0)
	await settle_frames(rock, 4000)
	check("a Venus's air closes its deck (%.2f)" % float(rv.cloud_mat.get_shader_parameter("uCover")), float(rv.cloud_mat.get_shader_parameter("uCover")) > 0.9)
	var tint: Vector3 = rv.atmo_mat.get_shader_parameter("uTint")
	check("and tints its limb (%s)" % tint, tint.x > tint.z)
	check("the surface's aerial colour follows", rv.surf_mat.get_shader_parameter("uAirTint") == tint)
	stage.remove_body(rock.id)
	stage.remove_body(b.id)
	# What presets state stays stated.
	var mars: Body = stage.state.body_named("Mars")
	var venus: Body = stage.state.body_named("Venus")
	var earth: Body = stage.state.body_named("Earth")
	for i in 3: stage.animate(1.0 / 60.0)
	check("Mars keeps its stated sky", near(float(viz_of(mars).atmo_mat.get_shader_parameter("uThick")), 0.22, 1e-6))
	check("Venus keeps its stated deck", float(viz_of(venus).cloud_mat.get_shader_parameter("uCover")) == 1.0)
	check("Venus keeps its 737 K", near(uniform(viz_of(venus), "uMeanK"), 737.0, 0.1))
	check("Earth keeps its stated cover", near(float(viz_of(earth).cloud_mat.get_shader_parameter("uCover")), 0.44, 1e-3))
	# A home world's visual takes the same look.
	stage.load_preset("trisolaris")
	stage.set_process(false)
	stage.state.paused = true
	var home: Body = stage.get_home()
	stage.animate(1.0 / 60.0)
	check("a home world follows the same rules", home.viz is WorldVisual.WorldViz and near(uniform(home.viz, "uBiota"), ClimateLook.biota_of(home.climate), 0.02))
	var home_viz = home.viz
	stage.edit_body(home, {"land": 0.6})
	stage.animate(1.0 / 60.0)
	check("and an edit keeps its visual", is_same(home.viz, home_viz))
	stage.load_preset("solar")
	stage.set_process(false)
	stage.state.paused = true

func edit_to(b: Body, patch: Dictionary, key: String, want: float) -> void:
	check("edit %s accepted" % str(patch.keys()), stage.edit_body(b, patch) == b)
	await settle_frames(b, 4000)
	var got := uniform(viz_of(b), key)
	check("%s reaches %s (%s)" % [key, want, got], near(got, want, 0.01 * maxf(absf(want), 1.0)))

func settle_frames(_b: Body, ms: int) -> void:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < ms:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame

func cost() -> void:
	stage.load_preset("trisolaris")
	stage.set_process(false)
	stage.state.paused = true
	var b: Body = stage.get_home()
	var ctx := VisualCtx.new()
	ctx.bodies = stage.state.bodies; ctx.suns = stage.state.suns; ctx.camera = stage.pipe.scene_cam
	ctx.cam_pos = stage.cam_pos; ctx.scene_scale = stage.state.scene_scale; ctx.sim_dt = 1e-5; ctx.viewport_h = 720.0
	var started := Time.get_ticks_usec()
	for i in 1000:
		ClimateLook.targets(b.climate, b.spec)
	print("LOOKCHECK PROFILE targets_us=%.1f" % ((Time.get_ticks_usec() - started) / 1000.0))
	started = Time.get_ticks_usec()
	for i in 200: b.viz.update(1.0 / 60.0, ctx)
	print("LOOKCHECK PROFILE world_update_us=%.1f" % ((Time.get_ticks_usec() - started) / 200.0))
	stage.load_preset("solar")
	stage.set_process(false)
	stage.state.paused = true
	var mars: Body = stage.state.body_named("Mars")
	started = Time.get_ticks_usec()
	for i in 200: mars.viz.update(1.0 / 60.0, ctx)
	print("LOOKCHECK PROFILE rocky_update_us=%.1f" % ((Time.get_ticks_usec() - started) / 200.0))

# PIXELS: contrasting worlds under one sun, the same camera, judged on their discs.
const WORLDS := {
	"earth": {"mix": "earth", "au": 1.0},
	"ocean": {"mix": "ocean", "au": 1.0},
	"snowball": {"mix": "earth", "au": 1.6},
	"venus": {"mix": "venus", "au": 0.72},
	"mars": {"mix": "mars", "au": 1.52},
	"desert": {"mix": "earth", "au": 1.0, "patch": {"land": 0.9, "pCO2": 0.01}},
	"bare": {"mix": "bare", "au": 1.0},
}

func shoot(name: String, spec: Dictionary) -> Dictionary:
	stage.load_preset("blank")
	stage.set_process(false)
	stage.state.paused = true
	stage.state.show_mesh = false
	stage.state.show_lens = false
	stage.spacetime_mesh.node.visible = false
	var star: Body = stage.spawn_body({"type": "star", "mass": 1.0, "name": "Lamp", "radiusKm": 696000.0})
	var inputs: Dictionary = Composition.MIXES[spec.mix].inputs.duplicate()
	inputs.merge(spec.get("patch", {}), true)
	var world := {"type": "planet", "mass": 3e-6, "name": name, "seed": 2024, "obliquity": 0.41,
		"pos": DVec3.new(float(spec.au), 0.0, 0.0).add(star.pos).to_array(), "vel": [0.0, 0.0, 0.0]}
	world.merge(inputs)
	var b: Body = stage.spawn_body(world)
	for i in 200: b.climate.step(1.0, b, [star])
	stage.set_follow(b)
	# Sunward of the world, looking back, so the disc is full and the star behind the camera.
	stage.cam.phi = PI
	stage.cam.theta = PI * 0.5 - 0.3
	stage.jump_cam_radius(stage.frame_radius(b))
	var frames := 0
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 2500 or frames < 40:
		stage.animate(1.0 / 60.0)
		frames += 1
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if args.has("out"): img.save_png("%s/%s_%s.png" % [args.out, name, args.get("quality", "medium")])
	var w := img.get_width(); var h := img.get_height()
	var c := Vector2(w * 0.5, h * 0.5)
	# The disc's size from the camera's own numbers: a star can sit anywhere behind it.
	var r: float = (h * 0.5) * tan(asin(minf(b.radius_scene / stage.cam.radius, 0.9))) / tan(deg_to_rad(stage.cam_fov) * 0.5)
	var sum := Vector3.ZERO
	var n := 0
	var sat := 0.0
	for i in 800:
		var a := i * 2.399963
		var rr := sqrt((i + 0.5) / 800.0) * r * 0.85
		var q := img.get_pixelv((c + Vector2(cos(a), sin(a)) * rr).floor()).srgb_to_linear()
		sum += Vector3(q.r, q.g, q.b)
		sat += maxf(maxf(q.r, q.g), q.b) - minf(minf(q.r, q.g), q.b)
		n += 1
	sum /= n
	return {"name": name, "r": sum.x, "g": sum.y, "b": sum.z, "lum": 0.2126 * sum.x + 0.7152 * sum.y + 0.0722 * sum.z, "sat": sat / n, "T": b.climate.T, "radius": r}

func pixels() -> void:
	var seen := {}
	for name in WORLDS:
		seen[name] = await shoot(name, WORLDS[name])
		var s: Dictionary = seen[name]
		print("LOOKCHECK PIXELS %-9s T=%5.1f K lum=%.3f rgb=%.3f %.3f %.3f sat=%.3f r=%.0f px" % [name, s.T, s.lum, s.r, s.g, s.b, s.sat, s.radius])
	check("the disc is on screen", seen.earth.radius > 40.0)
	check("a snowball outshines an ocean world (%.3f, %.3f)" % [seen.snowball.lum, seen.ocean.lum], seen.snowball.lum > seen.ocean.lum * 1.15)
	check("a snowball is whiter than an ocean", seen.snowball.sat / seen.snowball.lum < seen.ocean.sat / seen.ocean.lum)
	check("Venus's deck outshines bare rock (%.3f, %.3f)" % [seen.venus.lum, seen.bare.lum], seen.venus.lum > seen.bare.lum * 1.7)
	check("Venus's deck is warm-tinted", seen.venus.r > seen.venus.b)
	check("a desert world is redder than an ocean world (r/b %.2f, %.2f)" % [seen.desert.r / seen.desert.b, seen.ocean.r / seen.ocean.b], seen.desert.r / seen.desert.b > seen.ocean.r / seen.ocean.b * 1.1)
	check("Mars's air over rock is redder than blue", seen.mars.r > seen.mars.b * 1.1)
	check("the desert is a desert, not a frozen or boiled world (%.0f K)" % seen.desert.T, seen.desert.T > 280.0 and seen.desert.T < 320.0)
	check("an airless rock is darker than any deck", seen.bare.lum < seen.venus.lum and seen.bare.lum < seen.ocean.lum)

func _ready() -> void:
	OS.add_logger(catcher)
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	for i in 2: await get_tree().process_frame
	stage._start("sandbox")
	stage.set_process(false)
	if args.has("quality"): stage.set_render_quality(args.quality)
	if args.get("pixels", "0") == "1":
		stage.hud.set_hud_hidden(true)
		await pixels()
	else:
		references()
		water_and_air()
		await stage_flow()
		cost()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("LOOKCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
