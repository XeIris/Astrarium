extends Node

# GROUND SHOTS: evidence frames of a landing on the surveyed ground (docs/physics/surface.md#the-ground-under-a-landing).
# The LM on the Moon and the Sky Crane on Mars, each descent turned about the pole so it lands in a low
# morning sun, which shows relief; the last of the descent as a frame sequence for a video, and stills
# after touchdown. The command module comes down in the sea, at the first hour of its list that puts it there.
# Windowed: it judges nothing, it draws.
#   Godot --path . --resolution 1280x720 res://tools/groundshots.tscn -- out=/abs/dir [only=lm|skycrane|apollocm|dragonfly|time] [video=0] [hour=-60]

const CASES := {
	"lm": {"base": "lm:powered_descent", "world": "Moon", "film_below": 260.0},
	"skycrane": {"base": "skycrane:entry", "world": "Mars", "film_below": 400.0},
	"apollocm": {"base": "apollocm:entry", "world": "Earth", "film_below": 90.0, "sea": true},
	"dragonfly": {"base": "dragonfly:entry", "world": "Titan", "film_below": 0.0, "warp": 20.0},
	# Aimed at Ligeia Mare, so not turned to an hour: it comes down in the light Ligeia has.
	"time": {"base": "time:entry", "world": "Titan", "film_below": 60.0, "warp": 20.0, "fixed": true, "sea": true},
}
# Stills after touchdown: [yaw, pitch, distance in vehicle lengths].
const VIEWS := [[2.4, 0.10, 3.0], [0.6, 0.22, 5.0], [4.0, 0.05, 2.2], [1.5, 0.55, 14.0]]

var main: Node
var args := {}

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if not args.has("out"):
		printerr("GROUNDSHOTS FAIL out=/abs/dir is required")
		get_tree().quit(1)
		return
	PlanetMaps.synchronous = true
	main = Node.new()
	main.name = "Main"
	main.set_script(load("res://main.gd"))
	add_child(main)
	main.set_process(false)
	for i in 4: await get_tree().process_frame
	main.set_hud_hidden(true)
	var failures := 0
	for key in CASES:
		if args.has("only") and str(args.only) != key: continue
		if not await _case(key, CASES[key]): failures += 1
	print("GROUNDSHOTS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _case(key: String, c: Dictionary) -> bool:
	var dir: String = str(args.out).path_join(key)
	DirAccess.make_dir_recursive_absolute(dir)
	# Once undrawn to see how far round the descent carries it, then turned so it lands at `hour`.
	var trial := await _fly(c, 0.0, false, "")
	if trial.is_empty(): return false
	var hours: Array = [float(args.get("hour", "-60"))]
	if c.get("sea", false) and not args.has("hour"): hours = [-40.0, -50.0, -30.0, 40.0, 50.0, -60.0, 30.0, 60.0]
	if c.get("fixed", false): hours = []
	var turn := 0.0
	for h in hours:
		turn = wrapf(float(trial.sun_lon) + deg_to_rad(float(h)) - float(trial.land_lon), -PI, PI)
		if not c.get("sea", false): break
		var probe := await _fly(c, turn, false, "")
		if not probe.is_empty() and main.flight.vessel.afloat(): break
	var run := await _fly(c, turn, args.get("video", "1") != "0", dir)
	if run.is_empty(): return false
	print("GROUNDSHOTS %s landed at hour %s°, %s" % [key, U.fixed(rad_to_deg(wrapf(float(run.land_lon) - float(run.sun_lon), -PI, PI)), 1), run.where])
	var f: Spaceflight = main.flight
	if key == "lm" and args.get("rover", "1") != "0": await _drive(f, dir)
	if key == "skycrane" and args.get("rover", "1") != "0": await _drive_mars(f, dir)
	if key == "apollocm": await _float(f, dir)
	if key == "dragonfly": await _fly_dragonfly(f, dir)
	if key == "time": await _float_time(f, dir)
	f.fly_cam.state.userAimed = true
	for i in VIEWS.size():
		var vw: Array = VIEWS[i]
		f.fly_cam.state.yaw = float(vw[0])
		f.fly_cam.state.pitch = float(vw[1])
		f.fly_cam.state.dist = float(vw[2])
		for k in 20: await _frame(1.0 / 60.0)
		await _save(dir.path_join("still_%d.png" % i), false)
	return true

# The LRV off the LM, driven a loop past it, filmed; stills of it parked after, and of its tracks.
func _drive(f: Spaceflight, dir: String) -> void:
	if not f.deploy_rover():
		printerr("GROUNDSHOTS FAIL the LRV could not be deployed")
		return
	var r: Rover = f.rover
	f.rover_keys = false
	f.fly_cam.state.userAimed = true
	f.fly_cam.state.yaw = 2.6
	f.fly_cam.state.pitch = 0.18
	f.fly_cam.state.dist = 2.4
	# Away from the LM (it is west of the rover), round a turn, and back past it at speed.
	var plan := [[7.0, 1.0, 0.0], [6.0, 1.0, -0.6], [9.0, 1.0, 0.0], [7.0, 1.0, -0.7], [5.0, 1.0, 0.0], [4.0, 0.0, 0.0]]
	var shot := 0
	var film: bool = args.get("video", "1") != "0"
	for leg: Array in plan:
		r.throttle = float(leg[1])
		r.steer = float(leg[2])
		for k in int(float(leg[0]) * 60.0):
			await _frame(1.0 / 60.0)
			if film and k % 2 == 0:
				await _save(dir.path_join("drive/%05d.jpg" % shot), true)
				shot += 1
	var views := [[1.0, 0.12, 2.0], [3.6, 0.3, 3.2], [0.2, 0.9, 6.0]]
	for i in views.size():
		f.fly_cam.state.yaw = float(views[i][0])
		f.fly_cam.state.pitch = float(views[i][1])
		f.fly_cam.state.dist = float(views[i][2])
		for k in 20: await _frame(1.0 / 60.0)
		await _save(dir.path_join("lrv_%d.png" % i), false)
	print("GROUNDSHOTS lrv: %d frames filmed: %s" % [shot, f.rover_readout()])
	f.driving = false

# Perseverance off the Sky Crane: a drive filmed at 20× (it makes 152 m/h), the arm to the ground ahead, and
# the mast camera's view. Stills after.
func _drive_mars(f: Spaceflight, dir: String) -> void:
	if not f.deploy_rover():
		printerr("GROUNDSHOTS FAIL Perseverance could not be deployed")
		return
	var r: Rover = f.rover
	f.rover_keys = false
	f.fly_cam.state.userAimed = true
	f.fly_cam.state.yaw = 2.2
	f.fly_cam.state.pitch = 0.2
	f.fly_cam.state.dist = 2.2
	f.dev_warp = 20.0
	var film: bool = args.get("video", "1") != "0"
	var shot := 0
	var plan := [[8.0, 1.0, 0.0], [6.0, 1.0, 0.8], [6.0, 1.0, 0.0], [5.0, 0.0, 0.0]]
	for leg: Array in plan:
		r.throttle = float(leg[1])
		r.steer = float(leg[2])
		for k in int(float(leg[0]) * 60.0):
			await _frame(1.0 / 60.0)
			if film and k % 2 == 0:
				await _save(dir.path_join("drive/%05d.jpg" % shot), true)
				shot += 1
	f._toggle_arm()
	f.fly_cam.state.yaw = 0.9
	f.fly_cam.state.pitch = 0.25
	f.fly_cam.state.dist = 1.6
	for k in 60 * 7:
		await _frame(1.0 / 60.0)
		if film and k % 2 == 0:
			await _save(dir.path_join("drive/%05d.jpg" % shot), true)
			shot += 1
	f.dev_warp = 0.0
	var views := [[0.9, 0.25, 1.6], [2.8, 0.15, 2.0], [4.4, 0.5, 3.5]]
	for i in views.size():
		f.fly_cam.state.yaw = float(views[i][0])
		f.fly_cam.state.pitch = float(views[i][1])
		f.fly_cam.state.dist = float(views[i][2])
		for k in 20: await _frame(1.0 / 60.0)
		await _save(dir.path_join("rover_%d.png" % i), false)
	f.set_camera_mode("mast")
	for k in 20: await _frame(1.0 / 60.0)
	await _save(dir.path_join("mast.png"), false)
	f.set_camera_mode("chase")
	print("GROUNDSHOTS perseverance: %d frames filmed: %s" % [shot, f.rover_readout()])
	f.driving = false
	if args.get("heli", "1") != "0": await _fly_ingenuity(f, dir)

# Ingenuity off Perseverance: up, ahead, round and down, filmed at 1×; stills in the air and parked.
func _fly_ingenuity(f: Spaceflight, dir: String) -> void:
	if not f.deploy_heli():
		printerr("GROUNDSHOTS FAIL Ingenuity could not be deployed")
		return
	var h: Rotorcraft = f.heli
	f.rover_keys = false
	f.fly_cam.state.userAimed = true
	f.fly_cam.state.yaw = 2.0
	f.fly_cam.state.pitch = 0.15
	f.fly_cam.state.dist = 4.0
	var film: bool = args.get("video", "1") != "0"
	var shot := 0
	var plan := [[2.0, 0.0, 0.0, 0.0], [4.0, 0.0, 0.0, 1.0], [2.0, 0.0, 0.0, 0.0], [5.0, 0.6, 0.0, 0.0], [3.0, 0.3, 0.6, 0.0],
		[4.0, 0.0, 0.0, 0.0], [5.0, 0.0, 0.0, -1.0], [3.0, 0.0, 0.0, 0.0]]
	var stills := 0
	for leg: Array in plan:
		h.cmd_fwd = float(leg[1]); h.cmd_yaw = float(leg[2]); h.cmd_climb = float(leg[3])
		for k in int(float(leg[0]) * 60.0):
			await _frame(1.0 / 60.0)
			if film and k % 2 == 0:
				await _save(dir.path_join("heli/%05d.jpg" % shot), true)
				shot += 1
		if h.height_above_ground() > 3.0 and stills < 2:
			await _save(dir.path_join("ingenuity_air_%d.png" % stills), false)
			stills += 1
	print("GROUNDSHOTS ingenuity: %d frames filmed: %s" % [shot, f.heli_readout()])
	f.fly_cam.state.yaw = 3.4
	f.fly_cam.state.pitch = 0.2
	f.fly_cam.state.dist = 3.0
	for k in 20: await _frame(1.0 / 60.0)
	await _save(dir.path_join("ingenuity_parked.png"), false)

# Dragonfly: its own landing filmed at 10×, then flown up, across the hills and down at 1×.
func _fly_dragonfly(f: Spaceflight, dir: String) -> void:
	var film: bool = args.get("video", "1") != "0"
	var shot := 0
	f.rover_keys = false
	f.fly_cam.state.userAimed = true
	f.fly_cam.state.yaw = 2.2
	f.fly_cam.state.pitch = 0.12
	f.fly_cam.state.dist = 3.0
	f.dev_warp = 10.0
	var n := 0
	while f.heli != null and f.autoland and n < 20000:
		await _frame(1.0 / 60.0)
		n += 1
		if film and n % 3 == 0:
			await _save(dir.path_join("fly/%05d.jpg" % shot), true)
			shot += 1
	f.dev_warp = 0.0
	if f.heli == null or not f.flying:
		printerr("GROUNDSHOTS FAIL Dragonfly did not land itself")
		return
	await _save(dir.path_join("dragonfly_landed.png"), false)
	var h: Rotorcraft = f.heli
	var plan := [[2.0, 0.0, 0.0, 0.0], [8.0, 0.0, 0.0, 1.0], [12.0, 0.8, 0.0, 0.0], [6.0, 0.5, 0.5, 0.0], [6.0, 0.0, 0.0, 0.0]]
	var stills := 0
	for leg: Array in plan:
		h.cmd_fwd = float(leg[1]); h.cmd_yaw = float(leg[2]); h.cmd_climb = float(leg[3])
		for k in int(float(leg[0]) * 60.0):
			await _frame(1.0 / 60.0)
			if film and k % 2 == 0:
				await _save(dir.path_join("fly/%05d.jpg" % shot), true)
				shot += 1
		if h.height_above_ground() > 5.0 and stills < 3:
			await _save(dir.path_join("dragonfly_air_%d.png" % stills), false)
			stills += 1
	print("GROUNDSHOTS dragonfly: %d frames filmed: %s" % [shot, f.heli_readout()])

# Afloat: the splash's aftermath filmed, then the bags righting it at 10×, and stills on the sea.
func _float(f: Spaceflight, dir: String) -> void:
	var v: Vessel = f.vessel
	if not v.afloat():
		printerr("GROUNDSHOTS FAIL the command module is not afloat")
		return
	var film: bool = args.get("video", "1") != "0"
	var shot := 10000
	f.fly_cam.state.userAimed = true
	f.fly_cam.state.yaw = 2.3
	f.fly_cam.state.pitch = 0.12
	f.fly_cam.state.dist = 2.4
	for k in (60 * 12 if args.get("quick", "0") != "1" else 30):
		await _frame(1.0 / 60.0)
		f.fly_cam.state.yaw += 0.0012
		if film and k % 2 == 0:
			await _save(dir.path_join("seq/%05d.jpg" % shot), true)
			shot += 1
	print("GROUNDSHOTS afloat: %s" % f.sea_readout())
	for i in 3:
		f.fly_cam.state.yaw = [0.4, 3.6, 5.2][i]
		f.fly_cam.state.pitch = [0.08, 0.3, 0.6][i]
		f.fly_cam.state.dist = [2.6, 4.5, 9.0][i]
		for k in 30: await _frame(1.0 / 60.0)
		await _save(dir.path_join("afloat_%d.png" % i), false)
	if args.get("quick", "0") == "1": return
	f.key_action("gear")
	f.dev_warp = 10.0
	f.fly_cam.state.yaw = 1.2
	f.fly_cam.state.pitch = 0.15
	f.fly_cam.state.dist = 3.4
	for k in 60 * 40:
		await _frame(1.0 / 60.0)
		if film and k % 2 == 0:
			await _save(dir.path_join("seq/%05d.jpg" % shot), true)
			shot += 1
	f.dev_warp = 0.0
	print("GROUNDSHOTS righted: %s" % f.sea_readout())
	for i in 3:
		f.fly_cam.state.yaw = [0.9, 2.9, 4.6][i]
		f.fly_cam.state.pitch = [0.1, 0.25, 0.04][i]
		f.fly_cam.state.dist = [2.8, 5.0, 2.2][i]
		for k in 30: await _frame(1.0 / 60.0)
		await _save(dir.path_join("upright_%d.png" % i), false)

# TiME afloat on Ligeia: the splash's aftermath and its rocking filmed, then stills low over the methane.
func _float_time(f: Spaceflight, dir: String) -> void:
	if not f.vessel.afloat():
		printerr("GROUNDSHOTS FAIL TiME is not afloat")
		return
	var film: bool = args.get("video", "1") != "0"
	var shot := 10000
	f.fly_cam.state.userAimed = true
	f.fly_cam.state.yaw = 2.3
	f.fly_cam.state.pitch = 0.1
	f.fly_cam.state.dist = 3.0
	for k in (60 * 20 if args.get("quick", "0") != "1" else 30):
		await _frame(1.0 / 60.0)
		f.fly_cam.state.yaw += 0.0015
		if film and k % 2 == 0:
			await _save(dir.path_join("seq/%05d.jpg" % shot), true)
			shot += 1
	print("GROUNDSHOTS afloat: %s" % f.sea_readout())
	for i in 4:
		f.fly_cam.state.yaw = [0.4, 3.6, 5.2, 1.8][i]
		f.fly_cam.state.pitch = [0.06, 0.25, 0.5, 0.02][i]
		f.fly_cam.state.dist = [3.2, 6.0, 14.0, 2.6][i]
		for k in 30: await _frame(1.0 / 60.0)
		await _save(dir.path_join("afloat_%d.png" % i), false)

# Fly the case's descent from its base, turned `turn` rad about the pole, to touchdown and 3 s past.
func _fly(c: Dictionary, turn: float, film: bool, dir: String) -> Dictionary:
	var err: String = await main.jump_scenario(str(c.base))
	if err != "":
		printerr("GROUNDSHOTS FAIL %s: %s" % [c.base, err])
		return {}
	main.hud.toast("", 1)
	var f: Spaceflight = main.flight
	var v: Vessel = f.vessel
	if turn != 0.0: _turn(v, turn)
	main.set_drawn(false)
	f.dev_warp = float(c.get("warp", 0.0))
	var n := 0
	while v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED and n < 60000:
		if film and v.height_above_ground() < float(c.film_below): break
		main.step_flight(0.05)
		n += 1
	f.dev_warp = 0.0
	main.set_drawn(true)
	var shot := 0
	var after := 0
	while v.phase != Vessel.PHASE.DESTROYED and after < 180 and n < 120000:
		await _frame(1.0 / 60.0)
		n += 1
		if v.phase == Vessel.PHASE.LANDED: after += 1
		if not film:
			if v.phase == Vessel.PHASE.LANDED: break
			continue
		if n % 2 == 0:
			await _save(dir.path_join("seq/%05d.jpg" % shot), true)
			shot += 1
	if v.phase != Vessel.PHASE.LANDED:
		printerr("GROUNDSHOTS FAIL %s did not land: %s" % [c.base, v.failure])
		return {}
	if args.get("events", "0") == "1":
		for e in v.events: print("GROUNDSHOTS EVENT %s %s" % [U.fixed(float(e.t), 1), e.msg])
		for cs in f.craft.stages: print("GROUNDSHOTS STAGE %s visible=%s pos=%s" % [cs.key if "key" in cs else "?", cs.group.visible, cs.group.global_position - f.craft.group.global_position])
		print("GROUNDSHOTS FALLS %d" % f.falls.size())
		for fl in f.falls: print("GROUNDSHOTS FALL %s phase=%s" % [fl.get("key") if fl is Dictionary else str(fl), fl.get("phase") if fl is Dictionary else ""])
	var sun := f.sun_direction(DVec3.new())
	var ll := SurfaceGround.lat_lon(SurfaceGround.to_mesh(v.r, v.body_angle(v.coord), DVec3.new()))
	return {"sun_lon": atan2(sun.z, sun.x), "land_lon": atan2(v.r.z, v.r.x),
		"where": "%s° %s°, %s m over the figure, %s frames filmed" % [U.fixed(rad_to_deg(ll[0]), 3), U.fixed(rad_to_deg(ll[1]), 3),
			U.fixed(v.altitude(), 0), shot]}

# Turn the whole state about the pole: longitudes grow by `phi`. A flight frame is the parent's equatorial
# one, so the descent is the same descent over different ground, in a different hour.
func _turn(v: Vessel, phi: float) -> void:
	var dq := DQuat.new()
	dq.set_from_axis_angle(DVec3.new(0.0, -1.0, 0.0), phi)
	for d: DVec3 in [v.r, v.v, v.omega]: DQuat.rotate(d, dq)
	v.q.premultiply(dq).normalize_in()
	if v.on_rebase.is_valid(): v.on_rebase.call(dq)

func _frame(dt: float) -> void:
	main.animate(dt)
	await get_tree().process_frame

func _save(path: String, jpg: bool) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	# Drawn now, not whenever the window manager next lets an unfocused window draw.
	RenderingServer.force_draw(true, 1.0 / 60.0)
	var img := get_viewport().get_texture().get_image()
	if jpg: img.save_jpg(path, 0.88)
	else: img.save_png(path)
