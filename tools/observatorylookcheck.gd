extends Node

# How the Observatory's sky looks, measured in the final frame, because the sky's coverage,
# bloom and the tone curve decide it (docs/physics/observatory.md#the-moon-by-day-and-by-night):
#   Godot --path . --resolution 1280x720 res://tools/observatorylookcheck.tscn -- [dump=/abs/dir]
# The Moon by day and at 70°, a bright sky at sunrise, Saturn's disc at 1°, the overlay
# behind the buildings and the buildings darkening with the sky. Limits are display luminance, so they hold the look, not the physics;
# the numbers behind them are in tools/imagingcheck.gd and tools/observatorystagecheck.gd.

const Catch = preload("res://tools/coursecheck.gd").Catch

const VIEWS := [Vector2i(1800, 1200), Vector2i(900, 600)]
## A real 15% crescent is faint against the blue: its limb adds about a tenth to the sky.
const DAY_LIMB_MIN := 1.03
const DAY_LIMB_MAX := 1.6
## How bright the sky reads with the Sun at +1°, and how far a star may stand out of it.
const SUNRISE_SKY_MIN := 0.15
const SUNRISE_STAR_MAX := 0.05
const DARK_SKY_MAX := 0.04
const DARK_STAR_MIN := 0.3
## What a wall facing the Sun reads: lit by day, and a silhouette after dark, whichever way
## the camera looks.
const WALL_DAY_MIN := 0.5
const WALL_DARK_MAX := 0.05
const WALL_VIEW_DIFF := 0.03

var logger := Catch.new()
var stage: Node
var o: Observatory
var failures := 0
var checks := 0
var dump := ""
signal captured(img: Image)

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func settle(frames := 6) -> void:
	for i in frames:
		stage.animate(1.0 / 60.0)
		await RenderingServer.frame_post_draw

## The 3D frame alone. A sky change eases over about a second, hence the default.
func capture(frames := 120) -> Image:
	await settle(frames)
	stage.pipe.capture_next(func(img: Image): captured.emit.call_deferred(img))
	stage.animate(0.0)
	return await captured

func save(img: Image, tag: String) -> void:
	if not dump.is_empty(): img.save_png(dump.path_join(tag + ".png"))

func luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

## Scene direction `d` in pixels of `img`, as the camera draws it.
func to_px(d: Vector3, img: Image) -> Vector2:
	var b: Basis = stage.cam_basis
	var t := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var w := float(img.get_width()); var h := float(img.get_height())
	var z := -d.dot(b.z)
	return Vector2((d.dot(b.x) / z / (t * w / h) + 1.0) * 0.5 * w, (1.0 - d.dot(b.y) / z / t) * 0.5 * h)

func seen(body_name: String) -> Vector3:
	return stage.state.body_named(body_name).scene_pos.sub(stage.cam_pos).normalized().to_v3()

## Where a body is on `img`: its centre, radius (px) and the unit vector toward the Sun.
func disc(body_name: String, img: Image) -> Dictionary:
	var b: Body = stage.state.body_named(body_name)
	var d := seen(body_name)
	var c := to_px(d, img)
	var ang := atan(b.radius_scene / b.scene_pos.distance_to(stage.cam_pos))
	var px := ang / tan(deg_to_rad(stage.cam_fov) * 0.5) * img.get_height() * 0.5
	return {"c": c, "r": px, "sun": (to_px((d + seen("Sun") * 0.002).normalized(), img) - c).normalized()}

## Mean luminance of a piece of annulus: `r0`..`r1` px round `c`, within `half` rad of `u`.
func patch(img: Image, c: Vector2, r0: float, r1: float, u: Vector2, half := PI) -> float:
	var s := 0.0
	var n := 0
	for y in range(int(c.y - r1), int(c.y + r1) + 2):
		for x in range(int(c.x - r1), int(c.x + r1) + 2):
			var v := Vector2(x + 0.5, y + 0.5) - c
			var r := v.length()
			if r < r0 or r > r1 or absf(v.angle_to(u)) > half: continue
			s += luma(img.get_pixel(x, y))
			n += 1
	return s / maxi(n, 1)

func at(date: String) -> void:
	o.tracking = ""
	o.tracking_dir = null
	o.set_date_text(date)
	await settle(3)

func moon_by_day() -> void:
	await at("2026-11-05 13:00")
	o.point_at("Moon")
	stage.observer.fov = 3.0
	var img := await capture()
	save(img, "moon-day")
	var m := disc("Moon", img)
	var lit := patch(img, m.c, m.r * 0.75, m.r * 0.95, m.sun, 0.7)
	var dark := patch(img, m.c, m.r * 0.75, m.r * 0.95, -m.sun, 0.7)
	var sky := patch(img, m.c, m.r * 1.2, m.r * 1.5, -m.sun, 0.7)
	check("the day's crescent shows: limb %.3f against sky %.3f" % [lit, sky], lit / sky >= DAY_LIMB_MIN)
	check("and is no brighter than a real one (at most %.1f × the sky)" % DAY_LIMB_MAX, lit / sky <= DAY_LIMB_MAX)
	check("the Moon's dark side is the sky's colour: %.3f against %.3f" % [dark, sky], absf(dark / sky - 1.0) < 0.03)
	var far := patch(img, m.c, m.r * 2.0, m.r * 3.0, m.sun)
	check("nothing shows through away from the disc: %.3f against %.3f" % [far, sky], absf(far / sky - 1.0) < 0.05)

func crescent_at_70() -> void:
	await at("2026-11-05 09:00")
	var az: Dictionary = o.target_azalt("Moon", stage.cam_pos)
	stage.observer.fov = 70.0
	o.look(az.az, az.alt)
	var img := await capture()
	save(img, "moon-70-%d" % img.get_height())
	var m := disc("Moon", img)
	var bg := patch(img, m.c, m.r + 2.0, m.r + 5.0, m.sun)
	var peak := 0.0
	var sum := 0.0
	var along := 0.0
	for y in range(int(m.c.y - m.r - 2.0), int(m.c.y + m.r + 3.0)):
		for x in range(int(m.c.x - m.r - 2.0), int(m.c.x + m.r + 3.0)):
			var v := Vector2(x + 0.5, y + 0.5) - (m.c as Vector2)
			if v.length() > m.r + 1.5: continue
			var l := maxf(luma(img.get_pixel(x, y)) - bg, 0.0)
			peak = maxf(peak, l)
			sum += l
			along += l * v.dot(m.sun)
	var lean: float = along / maxf(sum, 1e-6) / m.r
	check("%dp: the Moon at 70° reads: peak %.2f over the sky" % [img.get_height(), peak], peak > 0.25)
	# A ring's light sits round the centre; a crescent's toward the Sun.
	check("%dp: and leans toward the Sun as a crescent: %.2f of its radius" % [img.get_height(), lean], lean > 0.3)

func sky_at(sun_alt: float, tag: String) -> Dictionary:
	await at(_date_when(sun_alt))
	var sun: Dictionary = o.target_azalt("Sun", stage.cam_pos)
	stage.observer.fov = 70.0
	o.look(fposmod(sun.az + 180.0, 360.0), 62.0)
	var img := await capture()
	save(img, "sky-" + tag)
	var ls := PackedFloat32Array()
	var edges := PackedFloat32Array()
	for y in range(img.get_height() / 4, img.get_height() * 3 / 4, 2):
		for x in range(img.get_width() / 4, img.get_width() * 3 / 4, 2):
			var l := luma(img.get_pixel(x, y))
			ls.append(l)
			# Against a pixel a little way off, so the sky's own gradient doesn't count.
			edges.append(l - luma(img.get_pixel(x + 8, y)))
	ls.sort()
	edges.sort()
	return {"median": ls[ls.size() / 2], "stars": edges[int(edges.size() * 0.999)]}

## The morning of 2026-11-05 at the site when the Sun rises through `alt`.
func _date_when(alt: float) -> String:
	var la := deg_to_rad(o.lat); var lo := deg_to_rad(o.lon)
	var day := Observatory.julian_day(2026, 11, 5)
	for i in 1440:
		var t := day + float(i) / 1440.0
		var tti := EarthFrame.tt_of_civil(t)
		var s := Observatory.solar_state(tti)
		var a := rad_to_deg(EarthFrame.altitude(EarthFrame.site(tti, la, lo, o.h), EarthFrame.from_scene(s.Sun[0].sub(s.Earth[0])).normalized()))
		# From 04:00 UT, on the way up: Paranal's Sun is well down then.
		if a >= alt and i > 240:
			return "2026-11-05 %02d:%02d" % [i / 60, i % 60]
	return "2026-11-05 12:00"

func twilight() -> void:
	var dark := await sky_at(-30.0, "dark")
	var civil := await sky_at(-6.0, "civil")
	var rise := await sky_at(1.0, "sunrise")
	check("a dark night is dark: %.3f" % dark.median, dark.median < DARK_SKY_MAX)
	check("and has stars: %.3f over the sky" % dark.stars, dark.stars > DARK_STAR_MIN)
	check("the Sun at +1°: the sky is bright: %.3f" % rise.median, rise.median > SUNRISE_SKY_MIN)
	check("and starless: %.3f over the sky" % rise.stars, rise.stars < SUNRISE_STAR_MAX)
	check("civil twilight lies between: %.3f" % civil.median, civil.median > dark.median and civil.median < rise.median)
	check("with fewer stars than the dark: %.3f" % civil.stars, civil.stars < dark.stars)

func saturn() -> void:
	await at("2026-11-05 02:20")
	o.point_at("Saturn")
	stage.observer.fov = 1.0
	var img := await capture()
	save(img, "saturn-%d" % img.get_height())
	var s := disc("Saturn", img)
	var globe := patch(img, s.c, 0.0, s.r * 0.7, s.sun)
	# Round the globe, where a marker's halo would stand behind its depth. The rings cross this
	# annulus, and are dimmer than the globe.
	var rim := patch(img, s.c, s.r + 0.5, s.r + 2.0, s.sun)
	check("%dp: Saturn's disc reads: globe %.2f" % [img.get_height(), globe], globe > 0.1)
	check("%dp: no bright rim round it: %.2f" % [img.get_height(), rim], rim < globe)

## The overlay is on the window's own frame, so this reads that, without the HUD.
func window_frame() -> Image:
	await settle(6)
	return get_viewport().get_texture().get_image()

func overlay_behind_buildings() -> void:
	await at("2026-11-05 09:00")
	stage.observer.fov = 70.0
	o.look(293.0, 28.0)
	stage.hud.visible = false
	o.show_names = false
	await settle(120)
	o.show_lines = true
	var with_lines := await window_frame()
	o.show_lines = false
	var without := await window_frame()
	o.show_lines = true
	o.show_names = true
	stage.hud.visible = true
	var mask: Image = stage.pipe.local_vp.get_texture().get_image()
	save(with_lines, "overlay")
	var on_solid := 0
	var solid := 0
	var on_sky := 0
	var w := with_lines.get_width(); var h := with_lines.get_height()
	var mw := float(mask.get_width()) / w; var mh := float(mask.get_height()) / h
	var opaque := func(x: int, y: int) -> bool:
		return mask.get_pixel(clampi(int(x * mw), 0, mask.get_width() - 1), clampi(int(y * mh), 0, mask.get_height() - 1)).a >= 0.999
	for y in range(4, h - 4):
		for x in range(4, w - 4):
			var a: Color = with_lines.get_pixel(x, y)
			var b: Color = without.get_pixel(x, y)
			# The figures' blue: frame to frame a panel's edge shimmers, but in grey.
			var moved := (a.b - b.b) - (a.r - b.r) > 0.12
			# Well inside a structure or well outside one: an edge pixel is partly both.
			var all_in: bool = opaque.call(x - 3, y - 3) and opaque.call(x + 3, y - 3) and opaque.call(x - 3, y + 3) and opaque.call(x + 3, y + 3)
			var all_out: bool = not opaque.call(x - 3, y - 3) and not opaque.call(x + 3, y - 3) and not opaque.call(x - 3, y + 3) and not opaque.call(x + 3, y + 3)
			if all_in:
				solid += 1
				if moved: on_solid += 1
			elif all_out and moved:
				on_sky += 1
	check("the view has buildings in it: %d px" % solid, solid > 5000)
	check("the figures are drawn on the sky: %d px" % on_sky, on_sky > 300)
	check("and not over the buildings: %d px" % on_solid, on_solid < 20)

## The brightest tenth of what stands above the horizon, which holds the walls facing the Sun,
## and the median of the sky around it. A 70° field at altitude 28° has its horizon 88% down.
func site_and_sky(img: Image) -> Dictionary:
	var mask: Image = stage.pipe.local_vp.get_texture().get_image()
	var mw := float(mask.get_width()) / img.get_width()
	var mh := float(mask.get_height()) / img.get_height()
	var solid := PackedFloat32Array()
	var sky := PackedFloat32Array()
	for y in range(0, int(img.get_height() * 0.85), 2):
		for x in range(0, img.get_width(), 2):
			var a := mask.get_pixel(int(x * mw), int(y * mh)).a
			(solid if a >= 0.999 else sky).append(luma(img.get_pixel(x, y)))
	solid.sort()
	sky.sort()
	return {"site": solid[int(solid.size() * 0.9)] if solid.size() > 100 else NAN, "sky": sky[sky.size() / 2]}

func site_seen(az: float) -> Dictionary:
	stage.observer.fov = 70.0
	o.look(az, 28.0)
	return site_and_sky(await capture())

## A quality's preset brings back film grain, which swamps a 2 px Moon, and its own view size.
func use_quality(quality: String) -> void:
	stage.set_render_quality(quality)
	stage.pipe.postfx.grain = 0.0
	stage.pipe.set_view_size(VIEWS[0])

## With the Sun down nothing lights the walls but the sky, so they are dark from either side.
func site_after_sunset(quality: String) -> void:
	use_quality(quality)
	await at("2026-11-05 09:00")
	var sun: Dictionary = o.target_azalt("Sun", stage.cam_pos)
	check("%s: the Sun is well down: %.1f°" % [quality, sun.alt], sun.alt < -10.0)
	var anti := await site_seen(fposmod(float(sun.az) + 180.0, 360.0))
	var toward := await site_seen(float(sun.az))
	check("%s: walls facing a set Sun are dark: %.3f" % [quality, anti.site], anti.site < WALL_DARK_MAX)
	check("%s: and read alike from the other side: %.3f and %.3f" % [quality, anti.site, toward.site],
		absf(anti.site - toward.site) < WALL_VIEW_DIFF)
	var seen := {}
	for alt in [20.0, -1.0, -3.0, -6.0]:
		await at(_date_when(alt))
		seen[alt] = await site_seen(fposmod(float(sun.az) + 180.0, 360.0))
		if not dump.is_empty():
			save(await capture(1), "site-%s-%+d" % [quality, int(alt)])
	check("%s: and lit by day: %.3f" % [quality, seen[20.0].site], seen[20.0].site > WALL_DAY_MIN)
	check("%s: the site goes out as the Sun sets: %.3f, then %.3f" % [quality, seen[-1.0].site, seen[-3.0].site],
		seen[-1.0].site > seen[-3.0].site + 0.05)
	check("%s: and stands dark on the twilight sky: %.3f on %.3f" % [quality, seen[-3.0].site, seen[-3.0].sky],
		seen[-3.0].site < seen[-3.0].sky)
	check("%s: and keeps falling with it: %.3f, %.3f, %.3f" % [quality, seen[-3.0].site, seen[-6.0].site, anti.site],
		seen[-3.0].site >= seen[-6.0].site and seen[-6.0].site >= anti.site - 0.005)

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dump="): dump = a.substr(5)
	if not dump.is_empty() and DirAccess.make_dir_recursive_absolute(dump) != OK:
		printerr("OBSERVATORYLOOKCHECK cannot create ", dump)
		get_tree().quit(1)
		return
	OS.add_logger(logger)
	get_tree().create_timer(600.0).timeout.connect(func():
		printerr("OBSERVATORYLOOKCHECK timed out")
		get_tree().quit(1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("observatory", true)
	await settle(3)
	o = stage.observatory
	o.set_rate("pause")
	o.set_site("paranal")
	await settle(3)
	stage.pipe.postfx.grain = 0.0
	stage.pipe.set_view_size(VIEWS[0])
	await moon_by_day()
	await twilight()
	await overlay_behind_buildings()
	var quality: String = stage.render_quality
	# High takes its ambient from another sky, one that is black below the horizon.
	for q in ["medium", "high"]:
		await site_after_sunset(q)
	use_quality(quality)
	for size: Vector2i in VIEWS:
		stage.pipe.set_view_size(size)
		await crescent_at_70()
		await saturn()
	for error in logger.take():
		failures += 1
		printerr("OBSERVATORYLOOKCHECK ENGINE ", error)
	OS.remove_logger(logger)
	print("OBSERVATORYLOOKCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
