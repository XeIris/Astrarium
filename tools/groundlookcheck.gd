extends Node

# GROUND LOOK CHECK: the drawn ground at a landing against its CPU half (docs/physics/surface.md#the-ground-close-up).
# Windowed, because it judges the frame: the LM lands on the Moon under a low Sun, and every sampled pixel's
# ground point is found by marching its view ray over the site's triangles. Where SurfaceShadow says the
# Sun is hidden, the frame must be dark, and where it says the Sun is clear, lit; the LM's own shadow
# falls where the Sun's ray from it meets the ground. Fails on any SHADER ERROR the run raises.
#   Godot --path . --resolution 1280x720 res://tools/groundlookcheck.tscn -- [out=/abs/frame.png] [hour=-80]

const SAMPLES_X := 96
const SAMPLES_Y := 60

var main: Node
var args := {}
var failures := 0
var checks := 0

func check(what: String, ok: bool) -> void:
	checks += 1
	if ok: print("GROUNDLOOKCHECK ok   ", what)
	else:
		failures += 1
		printerr("GROUNDLOOKCHECK FAIL ", what)

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	PlanetMaps.synchronous = true
	main = Node.new()
	main.name = "Main"
	main.set_script(load("res://main.gd"))
	add_child(main)
	main.set_process(false)
	for i in 4: await get_tree().process_frame
	main.set_hud_hidden(true)
	await _run()
	print("GROUNDLOOKCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

func _run() -> void:
	# Where the descent lands unturned, then turned to land at `hour` from noon.
	var trial := await _land(0.0)
	if trial.is_empty(): return
	var turn := wrapf(float(trial.sun_lon) + deg_to_rad(float(args.get("hour", "-80"))) - float(trial.land_lon), -PI, PI)
	var run := await _land(turn)
	if run.is_empty(): return
	var f: Spaceflight = main.flight
	var site: SurfaceSite = f.ground_site
	check("the surveyed site is drawn", site != null and site.built)
	if site == null: return
	f.fly_cam.state.userAimed = true
	f.fly_cam.state.yaw = 2.4
	f.fly_cam.state.pitch = 0.35
	f.fly_cam.state.dist = 9.0
	for k in 30: await _frame()
	# Drawn now, not whenever the window manager next lets an unfocused window draw.
	RenderingServer.force_draw(true, 1.0 / 60.0)
	var img := get_viewport().get_texture().get_image()
	if args.has("out"): img.save_png(str(args.out))
	var cam: Camera3D = f.local.camera
	var inv := site.group.global_transform.affine_inverse()
	var sun: Vector3 = site._mat.get_shader_parameter("uSunDir")
	var ang := float(site._mat.get_shader_parameter("uSunAng"))
	var grids: Array = site.relief.grids
	var R: float = site.relief.radius_m
	var top := float(site._mat.get_shader_parameter("uTop"))
	var craft: Vector3 = inv * f.craft.group.global_position
	var vp_size := Vector2(cam.get_viewport().get_visible_rect().size)
	var im_size := Vector2(img.get_width(), img.get_height())
	# Each sample's class at the CPU's march: 1 lit, 0 dark, −1 unjudged (sky, the LM and its shadow's
	# path, a penumbra). Only a sample whose four neighbours share its class is judged, so a shadow's edge
	# a pixel away from where the march puts it is not counted against either.
	var cls := PackedInt32Array()
	cls.resize(SAMPLES_X * SAMPLES_Y)
	cls.fill(-1)
	var lum := PackedFloat32Array()
	lum.resize(SAMPLES_X * SAMPLES_Y)
	var o: Vector3 = inv * cam.global_position
	for sy in SAMPLES_Y:
		for sx in SAMPLES_X:
			var px := Vector2((sx + 0.5) / SAMPLES_X, 0.12 + 0.88 * (sy + 0.5) / SAMPLES_Y) * vp_size
			var d: Vector3 = (inv.basis * cam.project_ray_normal(px)).normalized()
			var hit = _hit(grids, o, d, R)
			if hit == null: continue
			var p: Vector3 = hit
			if p.distance_to(craft) < 12.0 or _toward(p, craft, sun) < 8.0: continue
			var vis := SurfaceShadow.visibility(grids, -p.x, p.z, p.y, sun, ang, R, top)
			if vis > 0.05 and vis < 0.95: continue
			var k := sy * SAMPLES_X + sx
			cls[k] = 1 if vis >= 0.95 else 0
			lum[k] = _lum(img, Vector2i((px / vp_size * im_size).round()))
	# Only a sample whose four neighbours share its class is judged, and a shadowed one against the lit
	# ground around it (within 6 samples): how bright lit ground is varies across the frame with its
	# incidence and distance, and a shadow is darker than its own surroundings, not than a number.
	var lit := []
	var dark := []
	var dark_ok := 0
	var contrast := []
	for sy in range(1, SAMPLES_Y - 1):
		for sx in range(1, SAMPLES_X - 1):
			var k := sy * SAMPLES_X + sx
			var c := cls[k]
			if c < 0 or cls[k - 1] != c or cls[k + 1] != c or cls[k - SAMPLES_X] != c or cls[k + SAMPLES_X] != c: continue
			if c == 1:
				lit.append(lum[k])
				continue
			dark.append(lum[k])
			var around := []
			for dy in range(-6, 7):
				for dx in range(-6, 7):
					var x := sx + dx
					var y := sy + dy
					if x < 0 or y < 0 or x >= SAMPLES_X or y >= SAMPLES_Y: continue
					if cls[y * SAMPLES_X + x] == 1: around.append(lum[y * SAMPLES_X + x])
			if around.size() < 8: continue
			around.sort()
			var local_lit: float = around[around.size() / 2]
			contrast.append(lum[k] / maxf(local_lit, 1e-6))
			if lum[k] < 0.5 * local_lit: dark_ok += 1
	check("the march finds lit and shadowed ground in the frame (%d lit, %d dark, %d with lit ground beside them)" % [lit.size(), dark.size(), contrast.size()],
		lit.size() >= 40 and contrast.size() >= 12)
	if lit.size() < 40 or contrast.size() < 12: return
	lit.sort()
	contrast.sort()
	var lit_med: float = lit[lit.size() / 2]
	check("where the CPU's march hides the Sun the frame is darker than the lit ground beside it: median %s of it, and under half at %d of %d" % [
		U.fixed(contrast[contrast.size() / 2], 2), dark_ok, contrast.size()],
		contrast[contrast.size() / 2] < 0.35 and dark_ok >= 0.75 * contrast.size())
	# The LM's shadow: from its middle along the Sun's ray back to the ground.
	var mid := craft + Vector3(0.0, 2.5, 0.0)
	var foot = _hit(grids, mid, -sun.normalized(), R)
	check("the LM's shadow meets the ground", foot != null)
	if foot == null: return
	var world: Vector3 = site.group.global_transform * (foot as Vector3)
	if cam.is_position_behind(world):
		check("the LM's shadow is in the frame", false)
		return
	var spx := cam.unproject_position(world)
	var spot := _lum(img, Vector2i((spx / vp_size * im_size).round()))
	var ground_vis := SurfaceShadow.visibility(grids, -(foot as Vector3).x, (foot as Vector3).z, (foot as Vector3).y, sun, ang, R, top)
	check("where it falls the ground is in the Sun (%s), and the frame is dark there: %s against %s lit" % [U.fixed(ground_vis, 2),
		U.fixed(spot, 3), U.fixed(lit_med, 3)], ground_vis > 0.9 and spot < 0.5 * lit_med)

# The first point where `d` from `o` meets the ground's triangles, in the site's frame, or null.
func _hit(grids: Array, o: Vector3, d: Vector3, R: float):
	var t := 0.5
	var prev := 0.0
	for k in 400:
		var p := o + d * t
		var g := SurfaceShadow.ground_y(grids, -p.x, p.z, R)
		if is_nan(g): return null
		if p.y < g:
			var lo := prev
			var hi := t
			for b in 30:
				var m := 0.5 * (lo + hi)
				var q := o + d * m
				if q.y < SurfaceShadow.ground_y(grids, -q.x, q.z, R): hi = m
				else: lo = m
			return o + d * hi
		prev = t
		t = t * 1.02 + 0.2
		if t > 30000.0: return null
	return null

# How far the Sun's ray from `p` passes from `c`, m.
static func _toward(p: Vector3, c: Vector3, sun: Vector3) -> float:
	var s := sun.normalized()
	var v := c - p
	var along := maxf(v.dot(s), 0.0)
	return (v - s * along).length()

# Mean luminance of a 3 × 3 block, linear.
static func _lum(img: Image, at: Vector2i) -> float:
	var sum := 0.0
	var n := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var q := Vector2i(clampi(at.x + dx, 0, img.get_width() - 1), clampi(at.y + dy, 0, img.get_height() - 1))
			sum += img.get_pixelv(q).srgb_to_linear().get_luminance()
			n += 1
	return sum / n

func _land(turn: float) -> Dictionary:
	var err: String = await main.jump_scenario("lm:powered_descent")
	if err != "":
		check("lm:powered_descent jump (%s)" % err, false)
		return {}
	main.hud.toast("", 1)
	var f: Spaceflight = main.flight
	var v: Vessel = f.vessel
	if turn != 0.0:
		var dq := DQuat.new()
		dq.set_from_axis_angle(DVec3.new(0.0, -1.0, 0.0), turn)
		for d: DVec3 in [v.r, v.v, v.omega]: DQuat.rotate(d, dq)
		v.q.premultiply(dq).normalize_in()
		if v.on_rebase.is_valid(): v.on_rebase.call(dq)
	main.set_drawn(false)
	var n := 0
	while v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED and n < 60000:
		if turn != 0.0 and v.height_above_ground() < 300.0: break
		main.step_flight(0.05)
		n += 1
	main.set_drawn(true)
	while v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED and n < 120000:
		await _frame()
		n += 1
	if v.phase != Vessel.PHASE.LANDED:
		check("the LM lands (%s)" % v.failure, false)
		return {}
	var sun := f.sun_direction(DVec3.new())
	return {"sun_lon": atan2(sun.z, sun.x), "land_lon": atan2(v.r.z, v.r.x)}

func _frame() -> void:
	main.animate(1.0 / 60.0)
	await get_tree().process_frame
