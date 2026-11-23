extends Node

# GROUND SHOTS: evidence frames of a landing on the surveyed ground (docs/physics/surface.md#the-ground-under-a-landing).
# The LM on the Moon and the Sky Crane on Mars, each descent turned about the pole so it lands in a low
# morning sun, which shows relief; the last of the descent as a frame sequence for a video, and stills
# after touchdown. Windowed: it judges nothing, it draws.
#   Godot --path . --resolution 1280x720 res://tools/groundshots.tscn -- out=/abs/dir [only=lm|skycrane] [video=0] [hour=-60]

const CASES := {
	"lm": {"base": "lm:powered_descent", "world": "Moon", "film_below": 260.0},
	"skycrane": {"base": "skycrane:entry", "world": "Mars", "film_below": 400.0},
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
	var hour := deg_to_rad(float(args.get("hour", "-60")))
	var turn := wrapf(float(trial.sun_lon) + hour - float(trial.land_lon), -PI, PI)
	var run := await _fly(c, turn, args.get("video", "1") != "0", dir)
	if run.is_empty(): return false
	print("GROUNDSHOTS %s landed at hour %s°, %s" % [key, U.fixed(rad_to_deg(wrapf(float(run.land_lon) - float(run.sun_lon), -PI, PI)), 1), run.where])
	var f: Spaceflight = main.flight
	f.fly_cam.state.userAimed = true
	for i in VIEWS.size():
		var vw: Array = VIEWS[i]
		f.fly_cam.state.yaw = float(vw[0])
		f.fly_cam.state.pitch = float(vw[1])
		f.fly_cam.state.dist = float(vw[2])
		for k in 20: await _frame(1.0 / 60.0)
		await _save(dir.path_join("still_%d.png" % i), false)
	return true

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
	var n := 0
	while v.phase != Vessel.PHASE.LANDED and v.phase != Vessel.PHASE.DESTROYED and n < 60000:
		if film and v.height_above_ground() < float(c.film_below): break
		main.step_flight(0.05)
		n += 1
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
