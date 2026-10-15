extends Node

# EFFECTS LAB: one vehicle's plume, exhaust trail and vapour at a chosen altitude,
# through the real flight renderer, without flying there. The vehicle is held still
# with the air streaming past (Spaceflight.lab), which is the same flow as flying
# through still air.
#
#   Godot --path . res://tools/fxlab.tscn                         interactive
#   Godot --path . res://tools/fxlab.tscn -- craft=falcon9 alt=32000 out=/abs/a.png
#   Godot --path . res://tools/fxlab.tscn -- crafts=saturnv,shuttle alts=10000,25000,40000 out=/abs/dir
#   Godot --path . res://tools/fxlab.tscn -- mode=fly craft=saturnv alts=20000,35000 out=/abs/dir
#   Godot --path . res://tools/fxlab.tscn -- crafts=falcon9,shuttle alts=12000,30000 \
#         qualities=low,high views=20:0,90:10:1.5 out=/abs/dir         one process, 16 pictures
#
# hold (default): speed= and pitch= default to a Saturn V-like ascent at that altitude
#   (PROFILE); alpha= (degrees of nose above the airflow, belly into it: 40 for an
#   orbiter's entry); throttle=, stage= (index of the lit stage), settle= seconds of trail
#   before the picture, humidity= (0..1, for condensation), alone=1 (drop the stages
#   above the lit one too: the External Tank on its own, stage=1).
# fly: a real launch on the ascent program, photographed as it passes each altitude.
# Camera: az= (degrees round the axis from level on the sunward side, toward the
#   sky), el= (degrees toward the nose), dist= (× the
#   vehicle plus its plume), aim= (0 frames the vehicle, 1 the plume's end), fov=.
# quality=low|medium|high|ultra, or qualities= for several; views=az:el[:dist],... for
#   several cameras. Each (craft, altitude) is reached undrawn (main.set_drawn) with the
#   trail's history kept, then every quality and view is drawn at that same instant.
#   With several pictures, out= is a directory and each is <craft>_<km>km[_<quality>]
#   [_v<n>].png. Exits nonzero if a picture could not be written.
# Interactive keys: [ ] vehicle, 1–4 lit stage, H hide the panel, P picture to out=.

## [altitude m, airspeed m/s, pitch from vertical °], roughly AS-506's ascent: max-Q
## near 13 km at Mach 1.6, staging at 67 km and 2.3 km/s.
const PROFILE := [[0.0, 0.0, 0.0], [1000.0, 90.0, 2.0], [3000.0, 190.0, 8.0], [8000.0, 330.0, 22.0],
	[13000.0, 480.0, 32.0], [20000.0, 800.0, 45.0], [30000.0, 1300.0, 55.0], [40000.0, 1800.0, 62.0],
	[50000.0, 2150.0, 67.0], [60000.0, 2350.0, 71.0], [80000.0, 2700.0, 77.0], [120000.0, 3500.0, 84.0]]

var args := {}
var main: Node
var flight: Spaceflight
var crafts: Array = []
var craft := ""
var stage := 0
var cam := {"az": 20.0, "el": 0.0, "dist": 0.9, "aim": 0.3, "fov": 40.0}
var hold := {"alt": 35000.0, "speed": -1.0, "pitch": -1.0, "alpha": 0.0, "throttle": 1.0, "humidity": 0.6}
var panel: HudPanel
var caption: Label
var sliders := {}
var failures := 0
var dt := 1.0 / 60.0
var qualities: Array = []
var views: Array = []         # [az, el, dist]

func _ready() -> void:
	set_process(false)
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
	qualities = str(args.get("qualities", args.get("quality", "high"))).split(",", false)
	main.set_render_quality(str(qualities[0]))
	main.hud.visible = false
	flight = main.flight
	for k in ["az", "el", "dist", "aim", "fov"]:
		if args.has(k): cam[k] = float(args[k])
	for k in ["alt", "speed", "pitch", "alpha", "throttle", "humidity"]:
		if args.has(k): hold[k] = float(args[k])
	stage = int(args.get("stage", "0"))
	crafts = str(args.get("crafts", args.get("craft", "saturnv"))).split(",", false)
	var layer := CanvasLayer.new()
	add_child(layer)
	caption = Hud.label(layer, "", {"fs": 13.0, "ls": 2.0, "up": true, "c": HudTheme.TEXT})
	caption.position = Vector2(24, 18)
	if not args.has("out"):
		_build_panel(layer)
		await _use(crafts[0])
		set_process(true)
		return
	var alts: Array = []
	for a in str(args.get("alts", str(hold.alt))).split(",", false): alts.append(float(a))
	for w in str(args.get("views", "")).split(",", false):
		var p := w.split(":")
		views.append([float(p[0]), float(p[1]) if p.size() > 1 else cam.el, float(p[2]) if p.size() > 2 else cam.dist])
	if views.is_empty(): views = [[cam.az, cam.el, cam.dist]]
	var many := crafts.size() * alts.size() * qualities.size() * views.size() > 1
	if many: DirAccess.make_dir_recursive_absolute(str(args.out))
	for c in crafts:
		if args.get("mode", "hold") == "fly": await _fly(c, alts, many)
		else:
			for alt in alts:
				await _use(c)
				hold.alt = alt
				_apply()
				main.set_drawn(false)
				for i in int(float(args.get("settle", "6")) / dt): main.animate(dt)
				main.set_drawn(true)
				await _matrix(c, alt, many)
	print("FXLAB DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _path(c: String, alt: float, many: bool, q := "", view := -1) -> String:
	if not many: return str(args.out)
	var name := "%s_%02dkm" % [c, int(roundf(alt / 1000.0))]
	if qualities.size() > 1: name += "_" + q
	if views.size() > 1: name += "_v%d" % view
	return str(args.out).path_join(name + ".png")

## Every quality and view of the present instant: animate(0) re-presents the stage at
## the new setting without stepping it.
func _matrix(c: String, alt: float, many: bool) -> void:
	for q in qualities:
		if qualities.size() > 1: main.set_render_quality(str(q))
		for i in views.size():
			cam.az = views[i][0]; cam.el = views[i][1]; cam.dist = views[i][2]
			main.animate(0.0)
			await _shot(_path(c, alt, many, str(q), i))

## Start `key` on the pad, then hold it (the pad is only the way in).
func _use(key: String) -> void:
	craft = key
	main.load_preset("solar")
	await CraftAssets.craft_models_ready([key])
	if flight.active: main.end_flight()
	flight.begin(key, {"mode": "pad"})
	main.set_cam_mode("flight")
	flight.camera_override = _camera
	_apply()
	if flight.vapour != null:
		for sh in flight.vapour.shoulders:
			print("FXLAB %s shoulder y=%s m r=%s m turn=%s° stage=%s" % [key, U.fixed(sh.y, 1), U.fixed(sh.r, 2), U.fixed(rad_to_deg(sh.theta), 1), sh.stage])

## The lab's state onto the held vehicle.
func _apply() -> void:
	var p := profile(float(hold.alt))
	flight.lab = {"alt": hold.alt, "speed": p.x if hold.speed < 0.0 else hold.speed,
		"pitch": deg_to_rad(p.y if hold.pitch < 0.0 else hold.pitch), "alpha": deg_to_rad(hold.alpha),
		"throttle": hold.throttle}
	Plume.humidity = float(hold.humidity)
	var v: Vessel = flight.vessel
	var lit := clampi(stage, 0, v.stages.size() - 1)
	# Everything below the lit stage has gone; the lit one burns.
	for i in v.stages.size():
		var st: Vessel.StageState = v.stages[i]
		st.attached = i >= lit
		if i == lit:
			st.ignited = true
			st.spent = false
		# Gone already, not separating in frame.
		# alone=1: the stages above it have gone too (the External Tank on its own entry).
		if args.get("alone", "0") == "1" and i > lit: st.attached = false
		var cs = flight.craft.stage(str(st.spec.key))
		if cs != null and not st.attached and cs.sep == null: cs.group.visible = false
	v.stage_index = lit
	_caption()

func _caption() -> void:
	var l: Dictionary = flight.lab if flight.lab != null else {}
	var v: Vessel = flight.vessel
	caption.text = "%s · stage %d · %s km · %s m/s · pitch %s° · q %s kPa · humidity %d%%" % [
		v.vehicle.name, v.stage_index + 1, U.fixed(v.altitude() / 1000.0, 1),
		U.fixed(float(l.get("speed", v.telemetry.get("airspeed", 0.0))), 0),
		U.fixed(rad_to_deg(float(l.get("pitch", 0.0))), 0),
		U.fixed(float(v.telemetry.get("q", 0.0)) / 1000.0, 1), int(roundf(Plume.humidity * 100.0))]

## Airspeed (x) and pitch from vertical, degrees (y), on PROFILE at `alt`.
static func profile(alt: float) -> Vector2:
	for i in range(1, PROFILE.size()):
		var a: Array = PROFILE[i - 1]; var b: Array = PROFILE[i]
		if alt <= b[0]:
			var u: float = (alt - a[0]) / (b[0] - a[0])
			return Vector2(lerpf(a[1], b[1], u), lerpf(a[2], b[2], u))
	var e: Array = PROFILE[-1]
	return Vector2(e[1], e[2])

## A real ascent, photographed as it climbs through each altitude.
func _fly(key: String, alts: Array, many: bool) -> void:
	await _use(key)
	flight.lab = null
	flight.run_program("ascent")
	alts.sort()
	var next := 0
	var frames := 0
	main.set_drawn(false)
	while next < alts.size() and frames < 60 * 900:
		main.animate(dt)
		frames += 1
		var v: Vessel = flight.vessel
		if v.phase == Vessel.PHASE.DESTROYED: break
		if v.altitude() >= float(alts[next]):
			main.set_drawn(true)
			_caption()
			await _matrix(key, float(alts[next]), many)
			main.set_drawn(false)
			next += 1
		if frames % 600 == 0: await get_tree().process_frame
	main.set_drawn(true)
	if next < alts.size():
		failures += 1
		printerr("FXLAB FAIL %s reached %s km of %s" % [key, U.fixed(flight.vessel.altitude() / 1000.0, 1), alts])

func _shot(path: String) -> void:
	_caption()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	if err != OK:
		failures += 1
		printerr("FXLAB FAIL could not write %s (%s)" % [path, error_string(err)])
	else: print("FXLAB saved %s" % path)

## The lab camera: round the vehicle's axis from the sunward side, framing the vehicle
## and its plume together.
func _camera(fly_cam: LocalView.FlightCamera, craft_pos: DVec3, _site: DVec3, _dt: float) -> void:
	var H: float = flight.craft.height
	var axis: Vector3 = (flight.craft.group.basis * Vector3.UP).normalized()
	var plume := 0.0
	for pl in flight.plumes:
		if pl.mesh.visible: plume = maxf(plume, pl.last_len)
	var span := H + plume
	# az 0 is level with the axis on its sunward side, 90 above it: the plume is seen
	# side-on against the sky rather than the ground.
	var right := axis.cross(Vector3.UP if absf(axis.y) < 0.999 else Vector3.RIGHT).normalized()
	var sun_l := flight.frame_basis.transposed() * flight.sun_direction(DVec3.new()).to_v3()
	if sun_l.dot(right) < 0.0: right = -right
	var fwd := axis.cross(right).normalized()
	if fwd.y < 0.0: fwd = -fwd
	var az := deg_to_rad(float(cam.az))
	var el := deg_to_rad(float(cam.el))
	var d := float(cam.dist) * span
	var aim := axis * (H * 0.5 - span * float(cam.aim))
	var off := (right * cos(az) + fwd * sin(az)) * (d * cos(el)) + axis * (d * sin(el))
	var target := craft_pos.clone().add_in(DVec3.from_v3(aim))
	fly_cam.pos.copy_from(target).add_in(DVec3.from_v3(off))
	fly_cam.look_at(target, Vector3.UP)
	fly_cam.state.fov = float(cam.fov)
	fly_cam.near = clampf(d * 0.01, 0.05, 40.0)

func _process(real_dt: float) -> void:
	main.animate(minf(real_dt, 0.05))
	_caption()

func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo: return
	match k.keycode:
		KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
			var all: Array = Vehicles.VEHICLE_ORDER
			var i := all.find(craft) + (1 if k.keycode == KEY_BRACKETRIGHT else -1)
			stage = 0
			_use(all[posmod(i, all.size())])
		KEY_1, KEY_2, KEY_3, KEY_4:
			stage = k.keycode - KEY_1
			_use(craft)
		KEY_H:
			panel.visible = not panel.visible
		KEY_P:
			if args.has("pic"): _shot(str(args.pic))

func _build_panel(layer: CanvasLayer) -> void:
	panel = HudPanel.new([16, 16, 16, 16], false)
	layer.add_child(panel)
	panel.position = Vector2(24, 56)
	panel.custom_minimum_size = Vector2(330, 0)
	var rows := [
		["alt", "Altitude km", 0.0, 120.0, 0.5, hold.alt / 1000.0, hold],
		["speed", "Airspeed m/s (−1 profile)", -1.0, 8000.0, 10.0, hold.speed, hold],
		["pitch", "Pitch ° (−1 profile)", -1.0, 90.0, 1.0, hold.pitch, hold],
		["alpha", "Angle of attack °", -90.0, 90.0, 1.0, hold.alpha, hold],
		["throttle", "Throttle", 0.0, 1.0, 0.01, hold.throttle, hold],
		["humidity", "Humidity", 0.0, 1.0, 0.01, hold.humidity, hold],
		["az", "Camera azimuth °", -180.0, 180.0, 1.0, cam.az, cam],
		["el", "Camera elevation °", -80.0, 80.0, 1.0, cam.el, cam],
		["dist", "Distance ×", 0.1, 4.0, 0.01, cam.dist, cam],
		["aim", "Aim down plume", -0.5, 1.0, 0.01, cam.aim, cam],
	]
	for r in rows:
		var s := HudSlider.new(r[2], r[3], r[4], r[5])
		var row := Hud.range_row(panel.body, r[1], "", s, U.fixed(float(r[5]), 2), 6.0)
		var key: String = r[0]
		var into: Dictionary = r[6]
		sliders[key] = s
		s.moved.connect(func(v: float):
			into[key] = v * 1000.0 if key == "alt" else v
			(row.val as Label).text = U.fixed(v, 2)
			if into == hold: _apply())
	Hud.label(panel.body, "[ ] vehicle · 1–4 stage · H panel", {"fs": 9.0, "c": HudTheme.TEXT_DIM})
