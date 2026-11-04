extends Node

# How large a point source is drawn, measured in the final frame: bodies under the
# pixel limit, catalogue stars and sky stars, across zooms and magnitudes. Rule and
# reasons: docs/physics/sky.md#drawn-flux.
#   Godot --path . --resolution 1280x720 res://tools/glowcheck.tscn -- [dump=/abs/dir]

const Catch = preload("res://tools/coursecheck.gd").Catch

## The glow's radius is where an annulus's mean display luminance falls to GLOW_LEVEL.
const GLOW_LEVEL := 0.5
## Limits as a fraction of frame height. The bloom pyramid's kernels are a fixed number
## of pixels, so the same glow is a larger fraction of a smaller frame.
const VIEWS := {Vector2i(1800, 1200): 0.055, Vector2i(1280, 720): 0.09}
## A catalogue star's core is much narrower than a marker's, and bloom's Karis weighting
## mostly rejects it, so the same flux spreads less. The sky's PSF lies between them.
const STAR_GLOW_H := 0.025
const SKY_STAR_GLOW_H := 0.05
const ZOOMS := [70.0, 50.0, 30.0, 12.0, 6.0, 3.0, 1.0]
const SUN_AU := [20.0, 100.0, 500.0, 2000.0, 10000.0]
# Below the Moon's clamp, so these differ in flux at a fixed zoom.
const SUN_UNCLAMPED_AU := [1000.0, 2000.0, 4000.0, 10000.0]
# RA, Dec in degrees and V, brightest first.
const STARS := {
	"Sirius": [101.287, -16.716, -1.46],
	"Vega": [279.235, 38.784, 0.03],
	"Polaris": [37.955, 89.264, 1.98],
}
## Trading flux for exposure must leave a source under the knee alone to this many
## 8-bit levels of display luminance, and must show the compression above it.
const TRADE_SAME_LEVELS := 3.0
const TRADE_ABOVE_RATIO := 1.15
## Levels of display luminance between neighbours in the brightness order.
const ORDER_LEVELS := 2.0
const PROCEDURAL_PRESET := "alphacen"

var logger := Catch.new()
var stage: Node
var failures := 0
var checks := 0
var dump := ""
var view := Vector2i.ZERO
signal captured(img: Image)

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func settle(frames := 6) -> void:
	for i in frames:
		stage.animate(1.0 / 60.0)
		await RenderingServer.frame_post_draw

func capture() -> Image:
	await settle()
	stage.pipe.capture_next(func(img: Image): captured.emit.call_deferred(img))
	stage.animate(0.0)
	return await captured

func luma(img: Image, x: int, y: int) -> float:
	var c := img.get_pixel(x, y)
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

## The brightest pixel within `reach` of the frame centre: the source being measured.
func peak_at(img: Image, reach: int) -> Dictionary:
	var c := Vector2i(img.get_width() / 2, img.get_height() / 2)
	var best := -1.0
	var at := c
	for y in range(c.y - reach, c.y + reach + 1):
		for x in range(c.x - reach, c.x + reach + 1):
			var l := luma(img, x, y)
			if l > best:
				best = l
				at = Vector2i(x, y)
	return {"at": at, "value": best}

## Radius of the glow as a fraction of frame height, around the brightest pixel near
## the centre.
func glow(img: Image, reach := 24) -> Dictionary:
	var h := img.get_height()
	var p := peak_at(img, reach)
	var radius := 0
	for r in range(1, int(h * 0.48)):
		var s := 0.0
		var n := 0
		var steps := clampi(r * 4, 16, 96)
		for k in steps:
			var q := Vector2i(Vector2(p.at) + Vector2.from_angle(TAU * k / steps) * r)
			if q.x < 0 or q.y < 0 or q.x >= img.get_width() or q.y >= h: continue
			s += luma(img, q.x, q.y)
			n += 1
		if s / maxi(n, 1) >= GLOW_LEVEL: radius = r
	return {"radius": float(radius) / h, "peak": p.value, "at": p.at}

func save(img: Image, tag: String) -> void:
	if dump.is_empty(): return
	img.save_png(dump.path_join(tag.replace(" ", "-") + ".png"))

## One source at one setting: the check itself, and its numbers for the log.
func judge(tag: String, limit: float) -> void:
	var img := await capture()
	var g := glow(img)
	check("%s %dp glow %.3f H (limit %.3f), peak %.2f" % [tag, view.y, g.radius, limit, g.peak],
		g.radius <= limit and g.peak > 0.02)
	save(img, "%s-%dp" % [tag, view.y])

## The spacetime lattice writes depth, and one of its lines across a star's core reads
## as a dim star.
func load_scene(key: String) -> void:
	stage.load_preset(key)
	stage.state.paused = true
	stage.toggle_mesh(false)

func frame_body(body_name: String, au: float, fov: float) -> void:
	stage.set_cam_mode("orbit")
	stage._stage_set_focus(body_name)
	stage.cam_fov = fov
	# From the sunward side, or a planet is a dim crescent rather than its full magnitude.
	var body: Body = stage.state.body_named(body_name)
	var to_sun: DVec3 = stage.state.body_named("Sun").pos.sub(body.pos).normalized() if body_name != "Sun" else DVec3.new(0.6, 0.53, 0.6)
	stage.cam.theta = acos(clampf(to_sun.y, -1.0, 1.0))
	stage.cam.phi = atan2(to_sun.z, to_sun.x)
	stage.jump_cam_radius(au * stage.state.scene_scale)
	await settle(20)

func aim_at(dir: Vector3, fov: float) -> void:
	stage.set_cam_mode("free")
	stage.cam.yaw = atan2(dir.x, dir.z)
	stage.cam.pitch = asin(clampf(dir.y, -1.0, 1.0))
	stage.cam_fov = fov

func star_dir(s: Array) -> Vector3:
	return SkyModel.radec_to_scene(s[0], s[1]).to_v3().normalized()

## Bodies under the pixel limit, including the Sun from 10000 AU. Boosted sizes hand
## over to the marker at a different distance, and draw the same thing once it has.
func markers() -> void:
	var limit: float = VIEWS[view]
	for true_scale in [true, false]:
		stage.set_true_scale(true_scale)
		for au in SUN_AU:
			await frame_body("Sun", au, 50.0)
			await judge("%s Sun %d AU" % ["true" if true_scale else "boost", int(au)], limit)
	stage.set_true_scale(true)
	for fov in ZOOMS:
		await frame_body("Sun", 10000.0, fov)
		await judge("Sun 10000 AU fov %s" % fov, limit)
		await frame_body("Jupiter", 4.2, fov)
		await judge("Jupiter 4.2 AU fov %s" % fov, limit)
	for fov in [50.0, 6.0, 1.0]:
		await frame_body("Neptune", 30.0, fov)
		await judge("Neptune 30 AU fov %s" % fov, limit)

func catalogue_stars() -> void:
	stage.set_cam_mode("orbit")
	stage._stage_set_focus("Sun")
	await settle(10)
	for star in STARS:
		for fov in ZOOMS:
			aim_at(star_dir(STARS[star]), fov)
			await judge("%s fov %s" % [star, fov], STAR_GLOW_H)
	stage.set_cam_mode("orbit")

## The drawn peak of each source, with no bloom and one exposure: a hard ceiling would
## pass the size limits, but a brighter source must still be drawn brighter. Zoomed far
## enough that all of them are over the knee.
func ordered(setups: Array, tag: String) -> void:
	var pfx: PostFX = stage.pipe.postfx
	var keep := [pfx.bloom, pfx.exposure, pfx.grain]
	pfx.bloom = 0.0
	pfx.grain = 0.0
	pfx.exposure = 1.0
	await setups[0].call()
	await mid_range(pfx)
	var last := INF
	for i in setups.size():
		await setups[i].call()
		var peak: float = peak_at(await capture(), 6).value
		check("%s %d of %d is drawn dimmer than the one before (%.3f, %.3f)" % [tag, i + 1, setups.size(), peak, last],
			peak < last - ORDER_LEVELS / 255.0)
		last = peak
	pfx.bloom = keep[0]
	pfx.exposure = keep[1]
	pfx.grain = keep[2]

## Into the tone curve's mid-range, or every frame saturates and agrees.
func mid_range(pfx: PostFX) -> void:
	for i in 40:
		if peak_at(await capture(), 6).value < 0.5: return
		pfx.exposure *= 0.5

func brighter_stays_brighter() -> void:
	stage.set_true_scale(true)
	var suns := SUN_UNCLAMPED_AU.map(func(au: float): return func(): await frame_body("Sun", au, 6.0))
	await ordered(suns, "Sun at increasing distance")
	var stars := STARS.values().map(func(s: Array): return func(): aim_at(star_dir(s), 6.0))
	await ordered(stars, "Sirius, Vega, Polaris")
	stage.set_cam_mode("orbit")

## Half the flux at twice the exposure, with no bloom, is the same HDR pixel while
## the mapping is linear, whatever the tone curve does. Zoom is the flux control:
## pixel solid angle doubles at √2 times tan(fov/2).
func trade(setup: Callable, fov: float) -> Array:
	var pfx: PostFX = stage.pipe.postfx
	var keep := [pfx.bloom, pfx.exposure, pfx.grain]
	pfx.bloom = 0.0
	pfx.grain = 0.0
	pfx.exposure = 1.0
	var wider := 2.0 * rad_to_deg(atan(tan(deg_to_rad(fov) * 0.5) * sqrt(2.0)))
	await setup.call(fov)
	await mid_range(pfx)
	var a: float = peak_at(await capture(), 6).value
	await setup.call(wider)
	pfx.exposure *= 2.0
	var b: float = peak_at(await capture(), 6).value
	pfx.bloom = keep[0]
	pfx.exposure = keep[1]
	pfx.grain = keep[2]
	return [a, b]

func linear_below_the_knee() -> void:
	stage.set_true_scale(true)
	var body := func(fov: float): await frame_body("Neptune", 5.0, fov)
	var star := func(fov: float): aim_at(star_dir(STARS["Polaris"]), fov)
	var r := await trade(body, 50.0)
	check("marker under the knee is linear in flux (%.3f, %.3f)" % r, absf(r[0] - r[1]) <= TRADE_SAME_LEVELS / 255.0)
	r = await trade(star, 50.0)
	check("catalogue star under the knee is linear in flux (%.3f, %.3f)" % r, absf(r[0] - r[1]) <= TRADE_SAME_LEVELS / 255.0)
	var sun := func(fov: float): await frame_body("Sun", 10000.0, fov)
	r = await trade(sun, 6.0)
	check("marker over the knee is compressed (%.3f, %.3f)" % r, r[1] > r[0] * TRADE_ABOVE_RATIO)
	var bright := func(fov: float): aim_at(star_dir(STARS["Sirius"]), fov)
	r = await trade(bright, 3.0)
	check("catalogue star over the knee is compressed (%.3f, %.3f)" % r, r[1] > r[0] * TRADE_ABOVE_RATIO)
	stage.set_cam_mode("orbit")

## A scene with no catalogue, so its brightest stars come from the sky shader's tiers.
## The field is hashed, so find one wide and follow it in, reaiming as the zoom resolves it.
func procedural_stars() -> void:
	load_scene(PROCEDURAL_PRESET)
	check("%s has no star catalogue" % PROCEDURAL_PRESET, stage.bright_stars == null)
	await settle(10)
	# Directly away from the system, so that nothing in view is one of its bodies.
	var dir: Vector3 = stage.cam_basis.z
	aim_at(dir, 30.0)
	var reach := int(view.y * 0.45)
	for fov in [30.0, 12.0, 6.0, 3.0, 1.0]:
		stage.cam_fov = fov
		var at: Vector2i = peak_at(await capture(), reach).at
		reach = 48
		var tan_half := tan(deg_to_rad(fov) * 0.5)
		var half := view.y * 0.5
		var local := Vector3((at.x - view.x * 0.5) / half * tan_half, -(at.y - half) / half * tan_half, -1.0)
		dir = (stage.cam_basis * local).normalized()
		aim_at(dir, fov)
		var img := await capture()
		var g := glow(img, 6)
		check("sky star fov %s %dp glow %.3f H (limit %.3f), peak %.2f" % [fov, view.y, g.radius, SKY_STAR_GLOW_H, g.peak],
			g.radius <= SKY_STAR_GLOW_H and g.peak > 0.02)
		save(img, "sky-star-fov-%s-%dp" % [fov, view.y])
	stage.set_cam_mode("orbit")

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("GLOWCHECK requires graphical rendering")
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("dump=") and arg.trim_prefix("dump=").is_absolute_path():
			dump = arg.trim_prefix("dump=")
		else:
			printerr("GLOWCHECK unknown option ", arg)
			get_tree().quit(1)
			return
	if not dump.is_empty() and DirAccess.make_dir_recursive_absolute(dump) != OK:
		printerr("GLOWCHECK cannot create ", dump)
		get_tree().quit(1)
		return
	OS.add_logger(logger)
	get_tree().create_timer(600.0).timeout.connect(func():
		printerr("GLOWCHECK timed out")
		get_tree().quit(1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("sandbox")
	stage.lessons.store = ""
	for size in VIEWS:
		view = size
		stage.pipe.set_view_size(view)
		load_scene("solar")
		await markers()
		await catalogue_stars()
		if size == VIEWS.keys()[0]:
			await brighter_stays_brighter()
			await linear_below_the_knee()
		await procedural_stars()
	for error in logger.take():
		failures += 1
		printerr("GLOWCHECK ENGINE ", error)
	OS.remove_logger(logger)
	print("GLOWCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
