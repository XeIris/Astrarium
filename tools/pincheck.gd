extends Node

# The pin and the showcase. Headless: the draw, what it reads, the mode's manners. With gpu=1 it also
# renders the shader's height at random points and holds the CPU's crust to it, and judges the marker.
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

func new_stage(preset: String) -> void:
	stage.load_preset(preset)
	stage.set_process(false)
	stage.state.paused = true

func spawn_world(mix: String, au: float, name_: String, extra := {}) -> Body:
	var inputs: Dictionary = Composition.MIXES[mix].inputs.duplicate()
	inputs.merge(extra, true)
	var spec := {"type": "planet", "mass": 3e-6, "name": name_, "seed": 4242, "obliquity": 0.41}
	spec.merge(inputs, true)
	var b: Body = stage.spawn_body(stage.place_spawn(spec, {"a_au": au, "ang": 1.0, "off": 0.5}))
	for i in 3: stage.animate(1.0 / 60.0)
	# The look's first frame has snapped; the frame after has a live ice line too.
	return b

func draws() -> void:
	new_stage("solar")
	var earth: Body = stage.state.body_named("Earth")
	var a := PlanetPin.drop(earth, 1, 0)
	var b := PlanetPin.drop(earth, 1, 0)
	check("the same seed and number land in the same place", a.lat == b.lat and a.lon == b.lon)
	check("and read the same ground", a.ground.text == b.ground.text)
	check("the next pin lands elsewhere", PlanetPin.drop(earth, 2, 0).lat != a.lat)
	check("another run seed lands elsewhere", PlanetPin.drop(earth, 1, 9).lat != a.lat)
	# Equal area: a band's share of pins goes as its share of the sphere (sin lat is uniform).
	var mars: Body = stage.state.body_named("Mars")
	var n := 4000
	var tropics := 0
	var east := 0
	var key := str(U.nz(mars.spec.get("seed"), mars.name))
	for i in n:
		var at := PlanetPin.draw(key, 0, i)
		if absf(at.x) < deg_to_rad(23.44): tropics += 1
		if at.y > 0.0: east += 1
	check("the tropics take their share of the sphere, 39.8%% (%.1f%%)" % (100.0 * tropics / n), near(float(tropics) / n, 0.3978, 0.025))
	check("the hemispheres split evenly (%.1f%%)" % (100.0 * east / n), near(float(east) / n, 0.5, 0.025))

	# The direction helper against the map's frame: 0° N 0° E is the +X meridian's opposite of u = 0.
	var eq := PlanetPin.direction(0.0, 0.0)
	check("0° N, 0° E is the map's centre line", near(eq.x, 1.0, 1e-6))
	check("the pole is on the mesh's +Y", near(PlanetPin.direction(PI * 0.5, 0.3).y, 1.0, 1e-6))
	var uv_u := fposmod((0.0 + PI) / TAU, 1.0)
	check("and that is u = ½", near(uv_u, 0.5, 1e-9))
	# Earth's mask, with places whose answer is known.
	check("the Sahara is land", PlanetPin.land_at("Earth", deg_to_rad(23.0), deg_to_rad(10.0)))
	check("the Pacific is not", not PlanetPin.land_at("Earth", deg_to_rad(0.0), deg_to_rad(-150.0)))
	check("nor the Atlantic", not PlanetPin.land_at("Earth", deg_to_rad(30.0), deg_to_rad(-40.0)))
	check("Australia is", PlanetPin.land_at("Earth", deg_to_rad(-25.0), deg_to_rad(134.0)))
	# Over many pins, Earth's land share is its own.
	var land := 0
	var count := 0
	for i in range(1, 2001):
		var at := PlanetPin.draw("Earth", 0, i)
		if PlanetPin.land_at("Earth", at.x, at.y): land += 1
		count += 1
	check("pins fall on land about 29%% of the time on Earth (%.1f%%)" % (100.0 * land / count), near(float(land) / count, 0.29, 0.03))
	PlanetPin.release_maps()

func ground_reads() -> void:
	new_stage("solar")
	var star: Body = stage.state.body_named("Sun")
	# A world's kinds, at places chosen by asking its own crust.
	var w := spawn_world("earth", 1.0, "Wet", {"land": 0.4, "biota": 1.0})
	var r := PlanetRelief.of_visual(PlanetPin._viz(w))
	var saw := {}
	for i in range(1, 80):
		var pin := PlanetPin.drop(w, i, 0)
		saw[pin.ground.kind] = true
		var h := r.height(pin.p).x
		if pin.ground.kind == "sea": check("pin %d: sea is under the sea (%.1f km)" % [i, h], h < r.sea_km)
		if pin.ground.kind == "land": check("pin %d: land is above it (%.1f km)" % [i, h], h >= r.sea_km)
		check("pin %d says what it found" % i, not String(pin.ground.text).is_empty())
	check("an ocean world has sea and land both", saw.has("sea") and saw.has("land"))
	var dry := spawn_world("bare", 1.0, "Rock")
	var pin := PlanetPin.drop(dry, 1, 0)
	check("a rock's pin is land", pin.ground.kind == "land")
	check("and calls it bare (%s)" % pin.ground.text, String(pin.ground.biome).begins_with("bare"))
	var ball := spawn_world("ocean", 1.0, "Ball")
	var all_sea := true
	for i in range(1, 30):
		var kind: String = PlanetPin.drop(ball, i, 0).ground.kind
		if kind != "sea" and kind != "sea ice" and kind != "ice sheet": all_sea = false
	# 0% land still has plate ridges standing out of the deep, so not every pin need be sea.
	check("a global ocean's pins are all water or ice, or a ridge says why", all_sea or ball.climate.land == 0.0)
	var ice := spawn_world("ocean", 2.5, "Ice")
	var iced := 0
	for i in range(1, 30):
		if PlanetPin.drop(ice, i, 0).ground.kind in ["sea ice", "ice sheet"]: iced += 1
	check("an ice shell's pins are on ice (%d of 29)" % iced, iced >= 25)
	# Mapped worlds: Earth by its mask, Mars and the Moon as dry mosaics.
	var earth: Body = stage.state.body_named("Earth")
	var e_pin := PlanetPin.drop(earth, 3, 0)
	check("a pin on Earth agrees with its mask", (e_pin.ground.kind == "land" or e_pin.ground.kind == "ice sheet") == PlanetPin.land_at("Earth", e_pin.lat, e_pin.lon) or e_pin.ground.kind == "sea ice")
	check("a pin on Mars is dry", PlanetPin.drop(stage.state.body_named("Mars"), 1, 0).ground.kind in ["land", "ice sheet"])
	check("a pin on the Moon is dry", PlanetPin.drop(stage.state.body_named("Moon"), 1, 0).ground.kind == "land")
	for name_ in ["Wet", "Rock", "Ball", "Ice"]:
		stage.remove_body(stage.state.body_named(name_).id)
	PlanetPin.release_maps()
	star = star

# The CPU crust's land share is what the crust threshold asks for: the shader's statistics did not
# move when its hash did. The doc's near-normal sd is the anchor.
func statistics() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var worlds := 40
	var n := 60
	var land := 0
	var sum := 0.0
	var sq := 0.0
	var threshold := Terrain.crust_threshold(0.29)
	# One world's sample covers a few lattice cells, so the statistics are over many seeds.
	for w in worlds:
		var seed_ := rng.randf() * 137.0
		for i in n:
			var z := rng.randf_range(-1.0, 1.0)
			var a := rng.randf() * TAU
			var q := sqrt(1.0 - z * z)
			var p := Vector3(q * cos(a), z, q * sin(a))
			var f := PlanetRelief.fbm(PlanetRelief.warp(p * 1.9 + Vector3(seed_, seed_, seed_), 0.55), 7)
			sum += f
			sq += f * f
			if f > threshold: land += 1
	var count := worlds * n
	var mean := sum / count
	var sd := sqrt(sq / count - mean * mean)
	print("PINCHECK fbm mean=%.4f sd=%.4f land=%.3f" % [mean, sd, float(land) / count])
	check("the fBm's mean stays near the threshold's 0.497 (%.4f)" % mean, near(mean, 0.497, 0.012))
	check("and its sd near 0.1065 (%.4f)" % sd, near(sd, 0.1065, 0.012))
	check("29%% land asks for 29%% land (%.1f%%)" % (100.0 * land / count), near(float(land) / count, 0.29, 0.035))

func panel_text(id: String) -> String:
	var el = stage.hud.ids.get(id)
	return String(el.text) if el != null else ""

# The mode's manners: enter, pin, leave, and nothing stays changed.
func mode_flow() -> void:
	new_stage("solar")
	var earth: Body = stage.state.body_named("Earth")
	stage.state.pin_on_focus = true
	var state = stage.state
	stage.set_follow(state.body_named("Jupiter"))
	stage.jump_cam_radius(11.0)
	stage.cam.theta = 1.1
	stage.cam.phi = 0.7
	stage.set_time_scale(0.123)
	state.speed = 1.5
	state.paused = true
	state.focus_id = earth.id
	var before := {"theta": stage.cam.theta, "phi": stage.cam.phi, "radius": stage.cam.radius, "follow": state.follow_id, "focus": state.focus_id,
		"time_scale": state.time_scale, "speed": state.speed, "paused": state.paused, "true": state.true_scale, "mode": state.cam_mode, "home": state.home_id}
	var bodies := {}
	for b: Body in state.bodies: bodies[b.id] = [b.mass, b.spec.duplicate(true), b.radius]
	stage.refresh_ui()
	check("the focus panel offers a world's showcase", stage.hud.ids.showcaseOpen.visible)
	stage._on_showcase_action("open")
	check("it opens on the focused world", stage.showcase.active and stage.showcase.body == earth)
	check("the app is in the mode", state.app_mode == "showcase")
	check("and it runs its clock", not state.paused)
	check("the panel names the world", panel_text("scWorld") == "Earth")
	check("no pin until it is in focus", stage.showcase.pin == null)
	for i in 400:
		stage.animate(1.0 / 60.0)
		if stage.showcase.pin != null: break
	check("a pin drops by itself once the world fills the view", stage.showcase.pin != null)
	check("the world fills it", stage.cam.radius <= earth.radius_scene * Showcase.FRAME_RADII * Showcase.SETTLED)
	var marker: Node3D = stage.showcase.marker
	check("the marker is on the surface mesh", marker != null and marker.get_parent() == earth.viz.surface)
	check("the panel says what it landed on", panel_text("scPinAt") != "—")
	var first := PlanetPin.drop(earth, 1, 0)
	check("it is the seed's first pin", stage.showcase.pin.lat == first.lat and stage.showcase.pin.lon == first.lon)
	var spin0: float = earth.spin_phase
	for i in 240: stage.animate(1.0 / 60.0)
	check("the ground keeps turning under the view", earth.spin_phase != spin0)
	# Rides with it: the pin stays on the camera's side.
	var viz = earth.viz
	var world: Vector3 = (viz.group.global_transform.basis * viz.surface.basis).orthonormalized() * stage.showcase.pin.p
	var to_cam := DVec3.new(sin(stage.cam.theta) * cos(stage.cam.phi), cos(stage.cam.theta), sin(stage.cam.theta) * sin(stage.cam.phi)).to_v3()
	check("the view rides with the pin (cos %.2f)" % world.dot(to_cam), world.dot(to_cam) > 0.35)
	check("the slab is out of the picture", not stage.spacetime_mesh.node.visible)
	stage._on_showcase_action("pin")
	check("another pin moves on", stage.showcase.pin.n == 2)
	var standing: int = PlanetPin._viz(earth).surface.get_children().filter(func(c): return String(c.name).begins_with("Pin") and not c.is_queued_for_deletion()).size()
	check("and only one marker stands (%d)" % standing, standing == 1)
	# A rebuild takes the marker with it; it comes back.
	stage.set_true_scale(not state.true_scale)
	stage.animate(1.0 / 60.0)
	check("a rebuilt visual gets its marker back", stage.showcase.marker != null and stage.showcase.marker.get_parent() == PlanetPin._viz(earth).surface)
	check("true scale: the marker is scaled to the world", stage.showcase.marker.get_child(0).mesh.height < earth.radius_scene * 0.2)
	stage.set_true_scale(not state.true_scale)
	stage.animate(1.0 / 60.0)
	stage._on_showcase_action("auto")
	check("the setting turns off", not state.pin_on_focus)
	stage._on_showcase_action("leave")
	check("leaving ends the mode", not stage.showcase.active and state.app_mode == "sandbox")
	var after := {"theta": stage.cam.theta, "phi": stage.cam.phi, "radius": stage.cam.radius, "follow": state.follow_id, "focus": state.focus_id,
		"time_scale": state.time_scale, "speed": state.speed, "paused": state.paused, "true": state.true_scale, "mode": state.cam_mode, "home": state.home_id}
	for k in before:
		check("leaving restores %s (%s)" % [k, after[k]], before[k] == after[k] or (before[k] is float and near(float(before[k]), float(after[k]), 1e-9)))
	check("no pin stands after", stage.showcase.marker == null and earth.viz.surface.get_children().filter(func(c): return c.name.begins_with("Pin") and not c.is_queued_for_deletion()).is_empty())
	var same := true
	for b: Body in state.bodies:
		if not bodies.has(b.id) or bodies[b.id][0] != b.mass or bodies[b.id][2] != b.radius or var_to_str(bodies[b.id][1]) != var_to_str(b.spec): same = false
	check("no body's mass, radius or spec moved", same)
	check("the map's mask is let go", PlanetPin._mask.is_empty())
	# With the setting off, a manual pin only.
	stage.set_app_mode("showcase", {"body": "Mars"})
	check("named by body", stage.showcase.body.name == "Mars")
	for i in 200: stage.animate(1.0 / 60.0)
	check("with the setting off nothing drops", stage.showcase.pin == null)
	stage._on_showcase_action("pin")
	check("a manual pin drops", stage.showcase.pin != null)
	# Removing the world ends the mode.
	var doomed: Body = stage.showcase.body
	stage.remove_body(doomed.id)
	stage.animate(1.0 / 60.0)
	check("removing the world ends the mode", not stage.showcase.active)
	stage.state.pin_on_focus = true
	# Loading a scenario ends it.
	new_stage("solar")
	stage.set_app_mode("showcase", {"body": "Venus"})
	stage.load_preset("sandbox")
	check("another scenario ends it", not stage.showcase.active)
	# A star's collapse or a merge: the world's climate goes.
	new_stage("solar")
	stage.set_app_mode("showcase", {"body": "Earth"})
	var e2: Body = stage.state.body_named("Earth")
	stage.transmute(e2, "gas-giant", "")
	stage.animate(1.0 / 60.0)
	check("a world that stops being one ends it", not stage.showcase.active)
	# A scenario with no world refuses.
	new_stage("bhmerger")
	stage.set_app_mode("showcase", {"body": ""})
	check("no rocky world: the mode refuses", not stage.showcase.active and stage.state.app_mode == "sandbox")
	new_stage("solar")
	stage.state.paused = true

# A scene's physics do not notice a showcase: two runs side by side, with and without.
func physics_parity() -> void:
	var run := func(visit: bool) -> String:
		new_stage("solar")
		stage.state.paused = false
		stage.set_time_scale(0.002)
		# A focused world's climate steps every frame, so both runs focus the same one.
		stage.state.focus_id = stage.state.body_named("Earth").id
		if visit: stage.set_app_mode("showcase", {"body": "Earth"})
		for i in 200: stage.step_physics(0.0005)
		var out := []
		for b: Body in stage.state.bodies:
			out.append([b.name, b.pos.to_array(), b.vel.to_array(), b.mass])
			if b.climate != null: out.append([b.climate.T, b.climate.ice])
		if visit: stage.set_app_mode("sandbox")
		return var_to_str(out)
	var plain: String = run.call(false)
	var shown: String = run.call(true)
	check("a showcase changes no orbit or climate", plain == shown)

func gpu_probe() -> void:
	new_stage("blank")
	var star: Body = stage.spawn_body({"type": "star", "mass": 1.0, "name": "Lamp", "radiusKm": 696000.0})
	star = star
	var worlds := [
		spawn_world("earth", 1.0, "Wet", {"land": 0.35}),
		spawn_world("bare", 1.0, "Cratered"),
	]
	for w: Body in worlds:
		var r := PlanetRelief.of_visual(PlanetPin._viz(w))
		var rng := RandomNumberGenerator.new()
		rng.seed = 5
		var n := 64
		var pts := Image.create(n, n, false, Image.FORMAT_RGBF)
		var dirs := []
		for j in n:
			for i in n:
				var z := rng.randf_range(-1.0, 1.0)
				var a := rng.randf() * TAU
				var q := sqrt(1.0 - z * z)
				var p := Vector3(q * cos(a), z, q * sin(a))
				dirs.append(p)
				pts.set_pixel(i, j, Color(p.x, p.y, p.z))
		var vp := SubViewport.new()
		vp.size = Vector2i(n, n)
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.transparent_bg = false
		add_child(vp)
		var mat := ShaderMaterial.new()
		mat.shader = load("res://tools/terrain_probe.gdshader")
		mat.set_shader_parameter("uPoints", ImageTexture.create_from_image(pts))
		mat.set_shader_parameter("uSeed", r.seed)
		mat.set_shader_parameter("uCrater", r.crater)
		mat.set_shader_parameter("uCrustT", r.crust_t)
		mat.set_shader_parameter("uLandRelief", r.land_relief)
		mat.set_shader_parameter("uOceanDepth", r.ocean_depth)
		mat.set_shader_parameter("uPlateScale", r.plate_scale)
		var rect := ColorRect.new()
		rect.size = Vector2(n, n)
		rect.material = mat
		vp.add_child(rect)
		for i in 4: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var worst := 0.0
		var total := 0.0
		var count := 0
		var sign_miss := 0
		for j in n:
			for i in n:
				var c := img.get_pixel(i, j)
				var k: float = c.r + c.g / 255.0 + c.b / 65025.0
				var gpu := k * 80.0 - 40.0
				var cpu := r.height(dirs[j * n + i]).x
				var diff := absf(gpu - cpu)
				worst = maxf(worst, diff)
				total += diff
				count += 1
				if (gpu < r.sea_km) != (cpu < r.sea_km): sign_miss += 1
		print("PINCHECK GPU %s: mean diff %.1f m, worst %.1f m, sea/land disagreements %d of %d" % [w.name, 1000.0 * total / count, 1000.0 * worst, sign_miss, count])
		check("%s: the CPU's crust is the shader's, mean diff %.1f m" % [w.name, 1000.0 * total / count], total / count < 0.05)
		check("%s: worst point within 300 m (%.0f m)" % [w.name, 1000.0 * worst], worst < 0.3)
		check("%s: a pin never disagrees about sea and land" % w.name, sign_miss <= 1)
		vp.queue_free()

# End to end: the actual planet in the frame, its sea and land read off the pixels, against the CPU's.
func coast_in_the_frame() -> void:
	new_stage("blank")
	stage.state.show_mesh = false
	stage.state.show_lens = false
	stage.spacetime_mesh.node.visible = false
	stage.hud.set_hud_hidden(true)
	var star: Body = stage.spawn_body({"type": "star", "mass": 1.0, "name": "Lamp", "radiusKm": 696000.0})
	var b := spawn_world("earth", 1.0, "Coast", {"land": 0.45, "cloudCover": 0.0, "biota": 0.0, "regolith": 0xc08040})
	var viz = PlanetPin._viz(b)
	# The whole disc, lit from behind the camera.
	stage.set_follow(b)
	var d: DVec3 = star.pos.sub(b.pos).normalized()
	stage.cam.phi = atan2(d.z, d.x)
	stage.cam.theta = acos(clampf(d.y, -1.0, 1.0))
	stage.jump_cam_radius(b.radius_scene * 2.6)
	for i in 30:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if args.has("out"): img.save_png("%s/coast.png" % args.out)
	var r := PlanetRelief.of_visual(viz)
	var cam: Camera3D = stage.pipe.scene_cam
	var view := Vector2(stage.pipe.view_size)
	var scale_x := view.x / img.get_width()
	var center := b.scene_pos.rel_v3(stage.cam_pos)
	var R: float = viz.R
	var turn: Basis = (viz.group.global_transform.basis * viz.surface.basis).orthonormalized().inverse()
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var agree := 0
	var total := 0
	var tries := 0
	while total < 600 and tries < 20000:
		tries += 1
		var px := Vector2i(rng.randi_range(0, img.get_width() - 1), rng.randi_range(0, img.get_height() - 1))
		var ray := cam.project_ray_normal(Vector2(px) * scale_x)
		var b_ := ray.dot(center)
		var disc := b_ * b_ - center.length_squared() + R * R
		if disc <= 0.0: continue
		var hit := ray * (b_ - sqrt(disc)) - center
		if hit.normalized().dot(-ray) < 0.6: continue
		var p := (turn * hit).normalized()
		var h := r.height(p).x
		# Leave the shore itself, where a pixel straddles the line.
		if absf(h - r.sea_km) < 0.25: continue
		var c := img.get_pixelv(px)
		var drawn_sea := c.b > c.r
		if drawn_sea == (h < r.sea_km): agree += 1
		total += 1
	print("PINCHECK coast %d of %d pixels agree" % [agree, total])
	check("the frame's sea and land are the CPU's (%d of %d)" % [agree, total], total >= 200 and float(agree) / total > 0.97)

func marker_pixels() -> void:
	new_stage("blank")
	stage.state.show_mesh = false
	stage.state.show_lens = false
	stage.spacetime_mesh.node.visible = false
	var star: Body = stage.spawn_body({"type": "star", "mass": 1.0, "name": "Lamp", "radiusKm": 696000.0})
	star = star
	spawn_world("bare", 1.0, "Stage")
	stage.hud.set_hud_hidden(true)
	stage.state.pin_on_focus = true
	stage.set_app_mode("showcase", {"body": "Stage"})
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 5000:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if args.has("out"): img.save_png("%s/showcase.png" % args.out)
	var red := 0
	for j in range(0, img.get_height(), 2):
		for i in range(0, img.get_width(), 2):
			var c := img.get_pixel(i, j)
			if c.r > c.g * 1.5 and c.r > c.b * 1.5 and c.r > 0.3: red += 1
	print("PINCHECK marker pixels %d" % red)
	check("the pin shows in the frame (%d px)" % red, red >= 10)
	stage.set_app_mode("sandbox")

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
	if args.get("gpu", "0") == "1":
		await gpu_probe()
		await coast_in_the_frame()
		await marker_pixels()
	else:
		statistics()
		draws()
		ground_reads()
		mode_flow()
		physics_parity()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("PINCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
