extends Node

# How the galactic scene draws, judged in the rendered frame (docs/physics/galaxies.md):
# the glow shader's face-on surface brightness against the same integral done on the
# CPU in double, and the hand-over between drawn stars and the glow, whose flux must
# match. Windowed, because it reads the GPU's frame and must see SHADER ERRORs.
#   Godot --path . --resolution 1280x720 res://tools/galaxylookcheck.tscn -- [dump=/abs/dir]

const Catch = preload("res://tools/coursecheck.gd").Catch

## Views of the solar neighbourhood averaged for the hand-over, each a fresh draw of
## the lattice; and the shell measured, so that the nearest star cannot dominate.
const HANDOVER_VIEWS := 48
const INNER := 0.005
const HANDOVER_TOL := 0.06
const PROFILE_TOL := 0.04
## Rows across the dust lane, as offsets from the frame's centre row: edge-on from
## outside, and from the Sun, where the lane sits ~210 px above the centre and in-plane
## steps are optically thick. Columns spread over ±EDGE_HALF_PX; the CPU marches
## EDGE_SAMPLES (an in-plane ray's asinh spacing is otherwise ~0.4 kpc).
const DUST_ROWS := {"edge": [-24, -8, -3, 0, 3, 8, 24], "sun": [-280, -240, -215, -205, -190, -160, -100, 0]}
const EDGE_COLUMNS := 48
const EDGE_HALF_PX := 320
const EDGE_SAMPLES := 3000
const EDGE_EXPOSURE := 0.05
## From the Sun the glow's 28 steps cross ~30 kpc of arm dust in the plane: that
## quadrature reads 5.3 % bright in the lane against a converged CPU march (12000
## samples agree with 3000). A step attenuated at its midpoint reads 14 %.
const DUST_TOL := {"edge": 0.04, "sun": 0.08}

var logger := Catch.new()
var stage: Node
var failures := 0
var checks := 0
var dump := ""

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok  " if ok else "FAIL", label])

func settle(frames := 4) -> void:
	for i in frames:
		stage.animate(1.0 / 60.0)
		await RenderingServer.frame_post_draw

## The scene's linear HDR frame, before the post chain.
func hdr() -> Image:
	await settle()
	return stage.pipe.scene_vp.get_texture().get_image()

func luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

func mean_luma(img: Image) -> float:
	var s := 0.0
	var w := img.get_width()
	var h := img.get_height()
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			s += luma(img.get_pixel(x, y))
	return s / float((w / 2) * (h / 2))

## Flux in the frame, in units of a centre pixel's solid angle: a star's drawn pixels
## sum to its flux wherever it falls (the point-source rule), but a pixel of glow is
## radiance, and a pixel at tan-plane (x, y) subtends (1 + x² + y²)^−3/2 of the centre's.
func frame_flux(img: Image, extended: bool) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var t := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var s := 0.0
	for y in range(0, h, 2):
		var ty := (1.0 - (float(y) + 0.5) / float(h) * 2.0) * t
		for x in range(0, w, 2):
			var tx := ((float(x) + 0.5) / float(w) * 2.0 - 1.0) * t * float(w) / float(h)
			var k := pow(1.0 + tx * tx + ty * ty, -1.5) if extended else 1.0
			s += luma(img.get_pixel(x, y)) * k
	return s * 4.0

func save(img: Image, tag: String) -> void:
	if dump.is_empty(): return
	var copy := img.duplicate()
	copy.convert(Image.FORMAT_RGBA8)
	copy.save_png(dump.path_join(tag + ".png"))

## Pin the exposure so frames compare: no adaptation, the user's exposure as given.
func pin(v: GalaxyVisual, exposure: float) -> void:
	v.exposure = exposure
	v.adaptation = 1.0
	stage.galaxy._adapted = true
	v.adapt_enabled = false

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("GALAXYLOOKCHECK requires graphical rendering")
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("dump=") and arg.trim_prefix("dump=").is_absolute_path():
			dump = arg.trim_prefix("dump=")
		else:
			printerr("GALAXYLOOKCHECK unknown option ", arg)
			get_tree().quit(1)
			return
	if not dump.is_empty() and DirAccess.make_dir_recursive_absolute(dump) != OK:
		printerr("GALAXYLOOKCHECK cannot create ", dump)
		get_tree().quit(1)
		return
	OS.add_logger(logger)
	get_tree().create_timer(600.0).timeout.connect(func():
		printerr("GALAXYLOOKCHECK timed out")
		get_tree().quit(1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("sandbox")
	stage.lessons.store = ""
	stage.pipe.set_view_size(Vector2i(1280, 720))
	stage.load_preset("gal_milkyway")
	stage.galaxy.wait_tracers()
	stage.state.paused = true
	var v: GalaxyVisual = stage.galaxy.visual
	check("the scene is up with its tracers", stage.galaxy.active and v != null and stage.galaxy.tracers != null)
	if v != null:
		await views(v)
		await profile(v)
		await through_dust(v, "edge")
		await through_dust(v, "sun")
		await handover(v)
	for error in logger.take():
		failures += 1
		printerr("GALAXYLOOKCHECK ENGINE ", error)
	OS.remove_logger(logger)
	print("GALAXYLOOKCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

# Every framing draws something, brighter at the galaxy than off it.
func views(v: GalaxyVisual) -> void:
	for f in ["whole", "face", "edge", "sun", "centre"]:
		stage.galaxy.frame(f)
		await settle(20)
		var img := await hdr()
		save(img, "view-" + f)
		var w := img.get_width()
		var h := img.get_height()
		var mid := luma(img.get_pixel(w / 2, h / 2))
		var all := mean_luma(img)
		var finite := is_finite(mid) and is_finite(all)
		check("%s: drawn, finite, centre %s over a mean %s" % [f, U.fixed(mid, 3), U.fixed(all, 4)], finite and all > 1e-4 and (f == "sun" or mid > all))

# Face-on, the glow's pixels against the CPU's integral along the same rays.
func profile(v: GalaxyVisual) -> void:
	stage.galaxy.frame("face")
	v.show_tracers = false
	v.show_stars = false
	pin(v, 0.05)
	var img := await hdr()
	save(img, "profile-face")
	# The background sky's own points are not the glow's.
	v.show_glow = false
	var sky := await hdr()
	v.show_glow = true
	var basis: Basis = stage.cam_basis
	var cam: Vector3 = stage.cam_pos.to_v3()
	var fov := deg_to_rad(stage.cam_fov)
	var size := Vector2(img.get_width(), img.get_height())
	var tan_h := tan(fov * 0.5)
	var gain := GalaxyVisual.K * SkyModel.star_gain() * v.exposure * v.adaptation
	var worst := 0.0
	var rings := 0
	# Rings of pixels about the centre: the jitter averages out over a ring.
	for rpx in [40, 80, 120, 160, 200, 240, 280]:
		var drawn := 0.0
		var want := 0.0
		var n := 64
		for k in n:
			var px := size * 0.5 + Vector2.from_angle(TAU * float(k) / float(n)) * float(rpx)
			var ndc := Vector2(px.x / size.x * 2.0 - 1.0, 1.0 - px.y / size.y * 2.0)
			var d := (basis * Vector3(ndc.x * tan_h * size.x / size.y, ndc.y * tan_h, -1.0)).normalized()
			drawn += luma(img.get_pixel(int(px.x), int(px.y))) - luma(sky.get_pixel(int(px.x), int(px.y)))
			want += v.ray_luminance(cam, d) * gain
		var err := absf(drawn / want - 1.0)
		print("     ring %d px: drawn %s, integral %s" % [rpx, U.expo(drawn / n, 3), U.expo(want / n, 3)])
		worst = maxf(worst, err)
		rings += 1
	check("face-on glow = CPU integral of the model's light in %d rings (worst %s %%, < %s)" % [rings, U.fixed(worst * 100.0, 1), U.fixed(PROFILE_TOL * 100.0, 0)], worst < PROFILE_TOL)
	v.show_tracers = true
	v.show_stars = true

# Through the dust lane: rows of pixels across it against the CPU's integral, so the
# glow's absorption (its in-step mean, and the spheroid reading the disc march's
# optical depth) is held where it is thick. Pixel centres exactly: the lane is a few
# pixels high edge-on.
func through_dust(v: GalaxyVisual, framing: String) -> void:
	stage.galaxy.frame(framing)
	v.show_tracers = false
	v.show_stars = false
	pin(v, EDGE_EXPOSURE)
	var img := await hdr()
	save(img, "dust-" + framing)
	v.show_glow = false
	var sky := await hdr()
	v.show_glow = true
	var basis: Basis = stage.cam_basis
	var cam: Vector3 = stage.cam_pos.to_v3()
	var size := Vector2(img.get_width(), img.get_height())
	var tan_h := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var gain := GalaxyVisual.K * SkyModel.star_gain() * v.exposure * v.adaptation
	var worst := 0.0
	var rows := 0
	for dy in DUST_ROWS[framing]:
		var drawn := 0.0
		var want := 0.0
		for k in EDGE_COLUMNS:
			var ix := int(size.x * 0.5) + int((float(k) / float(EDGE_COLUMNS - 1) * 2.0 - 1.0) * EDGE_HALF_PX)
			var iy := int(size.y * 0.5) + int(dy)
			var ndc := Vector2((float(ix) + 0.5) / size.x * 2.0 - 1.0, 1.0 - (float(iy) + 0.5) / size.y * 2.0)
			var d := (basis * Vector3(ndc.x * tan_h * size.x / size.y, ndc.y * tan_h, -1.0)).normalized()
			drawn += luma(img.get_pixel(ix, iy)) - luma(sky.get_pixel(ix, iy))
			want += v.ray_luminance(cam, d, 1e-3, EDGE_SAMPLES) * gain
		var err := absf(drawn / want - 1.0)
		print("     row %+d px: drawn %s, integral %s" % [int(dy), U.expo(drawn / EDGE_COLUMNS, 3), U.expo(want / EDGE_COLUMNS, 3)])
		worst = maxf(worst, err)
		rows += 1
	check("%s: glow through the dust = CPU integral in %d rows (worst %s %%, < %s)" % [framing, rows, U.fixed(worst * 100.0, 1), U.fixed(DUST_TOL[framing] * 100.0, 0)], worst < DUST_TOL[framing])
	v.show_tracers = true
	v.show_stars = true

# The stars drawn one by one carry the light the glow gives up to them. Every star is
# white with the mean luminosity of its population, so the light in the shell from
# INNER to the resolved radius is n·L either way; only the stars' Poisson draw differs.
func handover(v: GalaxyVisual) -> void:
	stage.galaxy.frame("sun")
	v.show_tracers = false
	pin(v, 0.02)
	var white := Vector3(1, 1, 1)
	var keep_d: Vector3 = v.glow_mat.get_shader_parameter("uDiscCol")
	var keep_s: Vector3 = v.glow_mat.get_shader_parameter("uSphereCol")
	var keep_f: Vector2 = v.glow_mat.get_shader_parameter("uFaint")
	v.glow_mat.set_shader_parameter("uDiscCol", white)
	v.glow_mat.set_shader_parameter("uSphereCol", white)
	v.glow_mat.set_shader_parameter("uInner", INNER)
	v.star_mat.set_shader_parameter("uInner", INNER)
	v.star_mat.set_shader_parameter("uFixL", 1.0 / v.disc_pop.resolved_per_l)
	# The spheroid's stars would need their own L; at the Sun they are a few in a million.
	var sun := Vector3(-8.0, 0.02, 0.0)
	var share := GalaxyVisual.sphere_share(v, sun)
	check("spheroid's share of the stars at the Sun %s < 1e-3" % U.expo(share, 2), share < 1e-3)
	var stars := 0.0
	var glow := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in HANDOVER_VIEWS:
		stage.cam.phi = rng.randf() * TAU
		stage.cam.theta = rng.randf_range(0.6, PI - 0.6)
		stage.cam.target.set_v(-8.0 + rng.randf_range(-0.2, 0.2), 0.02, rng.randf_range(-0.2, 0.2))
		stage.update_orbit_cam()
		# a: stars + the glow beyond them; c: the glow beyond them alone; b: the glow throughout.
		v.glow_mat.set_shader_parameter("uFaint", Vector2(0.0, 0.0))
		v.show_stars = true
		var a := await hdr()
		v.show_stars = false
		v.res_override = GalaxyVisual.RES_MAX
		var c := await hdr()
		v.res_override = 0.0
		var b := await hdr()
		v.res_override = -1.0
		# a − c is the stars alone; b − c is the glow's shell alone.
		stars += frame_flux(a, false) - frame_flux(c, false)
		glow += frame_flux(b, true) - frame_flux(c, true)
	var ratio := stars / glow
	check("hand-over over %d views: stars carry %s of the glow's shell light (1 ± %s)" % [HANDOVER_VIEWS, U.fixed(ratio, 3), U.fixed(HANDOVER_TOL, 2)],
		glow > 0.0 and absf(ratio - 1.0) < HANDOVER_TOL)
	v.glow_mat.set_shader_parameter("uDiscCol", keep_d)
	v.glow_mat.set_shader_parameter("uSphereCol", keep_s)
	v.glow_mat.set_shader_parameter("uFaint", keep_f)
	v.glow_mat.set_shader_parameter("uInner", 0.0)
	v.star_mat.set_shader_parameter("uInner", 0.0)
	v.star_mat.set_shader_parameter("uFixL", 0.0)
	v.show_stars = true
	v.show_tracers = true
