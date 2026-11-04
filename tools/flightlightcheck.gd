extends Node

# A vehicle lit only by what can reach it, measured in the final frame: nothing casts a shadow
# from the planet, so LocalView's Sun must stop at the limb itself, and the fill is what's left.
#   Godot --path . --resolution 1280x720 res://tools/flightlightcheck.tscn -- [dump=/abs/dir]
# On the pad by day, at sunset, through twilight and at night, and in orbit by day, past the
# local horizontal with the Sun still over the limb, and in eclipse. Windowed: High takes its
# ambient from a sky the GPU integrates, and the limits are display luminance. They hold the
# look, not the physics.

const Catch = preload("res://tools/coursecheck.gd").Catch

const CRAFT := "falcon9"
const VIEW := Vector2i(1280, 720)
const ORBIT_ALT := 210e3
const ORBIT_INC := 28.5
## Wall luminance: readable in sunlight, a dim shape without it, and not a hole in the stars.
const WALL_LIT_MIN := 0.15
const WALL_DARK_MAX := 0.06
const WALL_DARK_MIN := 0.005
## Plume.daylight past the limb, where the twilight term still has a few degrees to fall.
const SMOKE_DARK_MAX := 0.15
## Linear red over blue of the Sun at +2°: the air takes the blue first.
const LOW_SUN_RED_MIN := 3.0

var logger := Catch.new()
var stage: Node
var f: Spaceflight
var failures := 0
var checks := 0
var dump := ""
signal captured(img: Image)

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func settle(frames: int) -> void:
	for i in frames:
		stage.animate(1.0 / 60.0)
		await RenderingServer.frame_post_draw

func capture() -> Image:
	stage.pipe.capture_next(func(img: Image): captured.emit.call_deferred(img))
	stage.animate(0.0)
	return await captured

func luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

## Sine of the Sun's height over the vessel's local horizontal.
func sun_y() -> float:
	return DQuat.nrm(f.vessel.r.clone()).dot(DQuat.nrm(f.sun_direction(DVec3.new())))

## The angle in 0..360 whose placement puts the Sun nearest `alt` degrees. `place` moves the
## vessel; the pad and the orbit each sweep their own angle.
func solve(alt: float, place: Callable, rising := true) -> float:
	var best := 0.0
	var err := INF
	var want := sin(deg_to_rad(alt))
	for i in 1440:
		var a := i * 0.25
		place.call(a)
		var y := sun_y()
		place.call(a + 0.25)
		if (sun_y() > y) != rising: continue
		if absf(y - want) < err:
			err = absf(y - want)
			best = a
	return best

func begin(opts: Dictionary) -> void:
	if f.active: stage.end_flight()
	stage.scenario_world()
	# A clear sky: the sweep lands anywhere in the cloud field, and this judges the limb.
	stage.state.body_named("Earth").spec["cloudCover"] = 0.0
	f.begin(CRAFT, opts)
	stage.set_cam_mode("flight")
	stage.set_hud_hidden(true)

## The vehicle standing on a pad where the Sun is at `alt` degrees.
func on_pad(alt: float) -> void:
	begin({"mode": "pad"})
	var lat := float(f.vessel.launch_site.lat) * 180.0 / PI
	var lon := solve(alt, func(a: float): f.vessel.place_on_pad(lat, a))
	begin({"mode": "pad", "lon": lon})
	f.fly_cam.set_mode("chase")

## The vehicle coasting where the Sun is at `alt` degrees. Orbit's phase turns against the
## pad's longitude, so the same sweep finds the same side of the night.
func in_orbit(alt: float) -> void:
	begin({"mode": "orbit", "alt": ORBIT_ALT, "inc": ORBIT_INC, "phase": 0.0})
	var ph := deg_to_rad(solve(alt, func(a: float): f.vessel.place_in_orbit(ORBIT_ALT, ORBIT_INC, deg_to_rad(a))))
	begin({"mode": "orbit", "alt": ORBIT_ALT, "inc": ORBIT_INC, "phase": ph})

## Median luminance along the stack, in the final frame, after the exposure and the chase
## camera have eased round to the sunward side.
func wall(tag: String) -> float:
	await settle(240)
	var img := await capture()
	if not dump.is_empty(): img.save_png(dump.path_join(tag + ".png"))
	var cam: Camera3D = f.local.camera
	var size := Vector2(stage.pipe.local_vp.size)
	var scale := Vector2(img.get_width(), img.get_height()) / size
	var g: Node3D = f.craft.group
	var axis := g.global_basis * Vector3.UP
	var seen: Array[float] = []
	for i in range(3, 9):
		var p := cam.unproject_position(g.global_position + axis * f.vessel.length * (i / 10.0)) * scale
		for dx in range(-3, 4):
			var x := int(p.x) + dx
			var y := int(p.y)
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				seen.append(luma(img.get_pixel(x, y)))
	if seen.is_empty():
		check("%s: the vehicle is in frame" % tag, false)
		return -1.0
	seen.sort()
	return seen[seen.size() / 2]

func use_quality(quality: String) -> void:
	stage.set_render_quality(quality)
	stage.pipe.postfx.grain = 0.0
	stage.pipe.set_view_size(VIEW)

func pad(quality: String) -> void:
	use_quality(quality)
	var seen := {}
	for alt in [30.0, 12.0, 2.0, -3.0, -8.0, -20.0, -38.0]:
		await on_pad(alt)
		seen[alt] = await wall("%s-pad%+d" % [quality, int(alt)])
		var sun: DirectionalLight3D = f.local.sun
		print("  %s pad %+.0f°: sun %.2f°, light %.3f, wall %.3f" % [quality, alt, rad_to_deg(asin(sun_y())), sun.light_energy, seen[alt]])
		if alt >= 2.0:
			check("%s: the Sun at %+.0f° reaches the pad" % [quality, alt], sun.light_energy > 0.0)
		else:
			check("%s: the Sun at %+.0f° does not: %.3f" % [quality, alt, sun.light_energy], sun.light_energy == 0.0)
		if alt == 2.0:
			var c := sun.light_color.srgb_to_linear()
			check("%s: and a low Sun is red: red/blue %.1f" % [quality, c.r / maxf(c.b, 1e-4)],
				c.r / maxf(c.b, 1e-4) >= LOW_SUN_RED_MIN)
	check("%s: a white wall reads in daylight: %.3f" % [quality, seen[30.0]], seen[30.0] > WALL_LIT_MIN)
	check("%s: and is a dim shape at night: %.3f" % [quality, seen[-38.0]],
		seen[-38.0] < WALL_DARK_MAX and seen[-38.0] > WALL_DARK_MIN)
	# A handover that leaves a gap or a step would show here, whatever the end points do.
	var alts := [30.0, 12.0, 2.0, -3.0, -8.0, -20.0, -38.0]
	for i in alts.size() - 1:
		check("%s: and goes out steadily: %.3f at %+.0f°, then %.3f at %+.0f°" % [quality, seen[alts[i]], alts[i], seen[alts[i + 1]], alts[i + 1]],
			seen[alts[i + 1]] <= seen[alts[i]] + 0.01)

func orbit(quality: String) -> void:
	use_quality(quality)
	# The horizon at this height is 14.3° below the local horizontal.
	var seen := {}
	for alt in [40.0, -8.0, -20.0, -50.0]:
		await in_orbit(alt)
		seen[alt] = await wall("%s-orbit%+d" % [quality, int(alt)])
		var sun: DirectionalLight3D = f.local.sun
		print("  %s orbit %+.0f°: sun %.2f°, light %.3f, wall %.3f" % [quality, alt, rad_to_deg(asin(sun_y())), sun.light_energy, seen[alt]])
		if alt > -14.3:
			check("%s: in orbit the Sun at %+.0f° is over the limb and lights the vehicle: %.3f" % [quality, alt, seen[alt]],
				sun.light_energy > 0.0 and seen[alt] > WALL_LIT_MIN)
			check("%s: and smoke there is sunlit too: %.3f" % [quality, Plume.daylight], Plume.daylight > 0.3)
		else:
			check("%s: in eclipse, at %+.0f°, nothing shines through the planet: %.3f" % [quality, alt, sun.light_energy],
				sun.light_energy == 0.0)
			check("%s: and the vehicle is a dim shape: %.3f" % [quality, seen[alt]],
				seen[alt] < WALL_DARK_MAX and seen[alt] > WALL_DARK_MIN)
			check("%s: and smoke is not sunlit: %.3f" % [quality, Plume.daylight], Plume.daylight < SMOKE_DARK_MAX)

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dump="): dump = a.substr(5)
	if not dump.is_empty() and DirAccess.make_dir_recursive_absolute(dump) != OK:
		printerr("FLIGHTLIGHTCHECK cannot create ", dump)
		get_tree().quit(1)
		return
	OS.add_logger(logger)
	get_tree().create_timer(600.0).timeout.connect(func():
		printerr("FLIGHTLIGHTCHECK timed out")
		get_tree().quit(1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	PlanetMaps.synchronous = true
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("flight", true)
	await get_tree().process_frame
	f = stage.flight
	await CraftAssets.craft_models_ready([CRAFT])
	# Medium fills from a colour, High from a sky that is black below its horizon.
	for q in ["medium", "high"]:
		await pad(q)
		await orbit(q)
	for error in logger.take():
		failures += 1
		printerr("FLIGHTLIGHTCHECK ENGINE ", error)
	OS.remove_logger(logger)
	print("FLIGHTLIGHTCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
