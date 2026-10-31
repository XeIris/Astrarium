extends Node

# SKY SHOTS: the flight sky from a pad on any body, with the sun at a chosen elevation,
# through the real flight renderer. For judging the physical skies (Earth, Mars,
# Titan) and Earth's night emission (docs/physics/sky.md#flight-sky).
#
#   Godot --path . res://tools/skyshots.tscn -- body=Mars sunel=2 look=sun out=/abs/a.png
#   Godot --path . res://tools/skyshots.tscn -- shots=Mars:0:60:zenith,Mars:0:2:sun,Titan:10:40:sun out=/abs/dir
#
# A shot is body:lat:sunel:look (look = sun, zenith, opposite, or a number: degrees of
# elevation toward the sun's azimuth). kp= raises a geomagnetic storm (Earth's aurora)
# by planting a CME that has just arrived. fov= (default 80).

var args := {}
var main: Node
var flight: Spaceflight
var look := "sun"
var failures := 0

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
	main._start("sandbox")
	main.set_render_quality(str(args.get("quality", "high")))
	main.hud.visible = false
	flight = main.flight
	var shots: Array = []
	if args.has("shots"):
		for s in str(args.shots).split(",", false): shots.append(s.split(":"))
		DirAccess.make_dir_recursive_absolute(str(args.out))
	else:
		shots.append([str(args.get("body", "Mars")), str(args.get("lat", "0")), str(args.get("sunel", "30")), str(args.get("look", "sun"))])
	for s in shots:
		var name := "%s_%s_%s_%s.png" % Array(s)
		await _shot(str(s[0]), float(s[1]), float(s[2]), str(s[3]), str(args.out).path_join(name) if shots.size() > 1 or args.has("shots") else str(args.out))
	print("SKYSHOTS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _shot(body_name: String, lat: float, sunel: float, p_look: String, path: String) -> void:
	main.load_preset("solar")
	if flight.active: main.end_flight()
	var body: Body = flight.body_named(body_name)
	if body == null:
		failures += 1
		printerr("SKYSHOTS FAIL no body %s" % body_name)
		return
	# The longitude that puts the sun `sunel` above the morning horizon at `lat`.
	var sun: Body = flight.body_named("Sun")
	var a := DQuat.rotate(DVec3.new().sub_vectors(sun.pos, body.pos), Rocketry.spin_frame(body).invert())
	var dec := asin(clampf(-a.y / a.length(), -1.0, 1.0))
	var sub := rad_to_deg(atan2(a.z, a.x))
	var phi := deg_to_rad(lat)
	var cos_h := clampf((sin(deg_to_rad(sunel)) - sin(phi) * sin(dec)) / maxf(cos(phi) * cos(dec), 1e-6), -1.0, 1.0)
	var lon := sub - rad_to_deg(acos(cos_h))
	var kp := float(args.get("kp", "0"))
	if kp > 2.0 and sun.activity != null:
		var act = sun.activity
		act.cmes.append({"t": 0.0052, "life": 0.05, "radius": 1.0, "speed": 0.0, "alpha": 1.0,
			"dir": Vector3.UP, "width": 0.4, "energy": 1.1 * act.activity + (kp - 2.0) / 7.0 * 1.9 * act.activity})
	flight.begin("falcon9", {"mode": "pad", "body": body_name, "lat": lat, "lon": lon})
	main.set_cam_mode("flight")
	look = p_look
	flight.camera_override = _camera
	main.set_drawn(false)
	for i in 30: main.animate(1.0 / 60.0)
	main.set_drawn(true)
	main.animate(0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	if err != OK:
		failures += 1
		printerr("SKYSHOTS FAIL could not write %s" % path)
	else: print("SKYSHOTS saved %s (sun %.1f° at lat %.1f on %s)" % [path, sunel, lat, body_name])

## Thirty metres up beside the pad, looking toward the sun's azimuth.
func _camera(fly_cam: LocalView.FlightCamera, craft_pos: DVec3, _site: DVec3, _dt: float) -> void:
	var sun_l := flight.frame_basis.transposed() * flight.sun_direction(DVec3.new()).to_v3()
	var up := Vector3.UP
	var horiz := Vector3(sun_l.x, 0.0, sun_l.z)
	horiz = horiz.normalized() if horiz.length() > 1e-4 else Vector3.FORWARD
	var dir: Vector3
	match look:
		"zenith": dir = (up + horiz * 0.02).normalized()
		"opposite": dir = (-horiz * cos(deg_to_rad(20.0)) + up * sin(deg_to_rad(20.0))).normalized()
		"sun": dir = (horiz * cos(asin(clampf(sun_l.y, -1.0, 1.0)) ) + up * (sun_l.y + 0.08)).normalized()
		_:
			var e := deg_to_rad(float(look))
			dir = (horiz * cos(e) + up * sin(e)).normalized()
	fly_cam.pos.copy_from(craft_pos).add_in(DVec3.new(80.0, 30.0, 0.0))
	fly_cam.look_at(fly_cam.pos.clone().add_in(DVec3.from_v3(dir * 100.0)), Vector3.UP)
	fly_cam.state.fov = float(args.get("fov", "80"))
	fly_cam.near = 0.5
