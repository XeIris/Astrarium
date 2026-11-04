extends Node

# A scripted tour of the simulated instruments for a reproducible video:
#   Godot --path . --resolution 1600x1000 --write-movie /abs/demo.avi --fixed-fps 30 \
#         res://tools/instruments_demo.tscn
# Saturn through two telescopes side by side, saturation and bleed, the sky filling a long
# frame, Jupiter and the Moon at the plate scale, and the Lovell slewing to radio sources.

var main: Node
var t := 0.0
var _i := 0
# [start (s), what]; each step runs once when the clock passes its start.
var steps := [
	[0.0, "enter"],
	[4.0, "saturn"],
	[9.0, "bleed"],
	[13.0, "hold_saturn"],
	[14.0, "vst"],
	[20.0, "clear"],
	[21.0, "deep"],
	[25.0, "deep_long"],
	[29.0, "good_seeing"],
	[33.0, "jupiter_date"],
	[33.5, "jupiter"],
	[39.0, "moon_date"],
	[39.5, "moon"],
	[46.0, "moon_close"],
	[53.0, "lovell"],
	[56.0, "cyg"],
	[64.0, "cas"],
	[72.0, "end"],
]

func _ready() -> void:
	main = load("res://main.tscn").instantiate()
	add_child(main)
	# At the display's own scale unless told otherwise; 1 shows the panel whole.
	var args := OS.get_cmdline_user_args()
	if args.has("uiscale=1"): main.configure_window_scale(1.0)

func _process(dt: float) -> void:
	t += dt
	while _i < steps.size() and t >= float(steps[_i][0]):
		_run(String(steps[_i][1]))
		_i += 1

func _shoot(o: Observatory, exposure: float, nd := 0.0, seeing := NAN) -> void:
	o.desk.exposure = exposure
	o.desk.nd = nd
	o.desk.seeing = seeing
	o.desk.expose()

func _run(what: String) -> void:
	var o: Observatory = main.observatory
	match what:
		"enter":
			main._start("observatory")
			o.observe()
			o.set_rate("pause")
			o.set_site("paranal")
			o.set_date_text("2026-11-05 02:00")
			o.look(20.0, 45.0)
			o.desk.set_instrument("fors2")
		"saturn":
			o.desk.set_target_text("Saturn")
			_shoot(o, 0.05, 5.0)
		"bleed": _shoot(o, 2.0, 5.0)
		"hold_saturn":
			_shoot(o, 0.05, 5.0)
			o.desk.finish_into_frame()
			o.desk.hold()
		"vst":
			o.desk.set_instrument("omegacam")
			_shoot(o, 0.05)
		"clear":
			o.desk.release_hold()
			o.desk.set_instrument("fors2")
		"deep":
			o.desk.set_target_text("03 32 28 -27 48 30")
			_shoot(o, 60.0)
		"deep_long": _shoot(o, 1800.0)
		"good_seeing":
			_shoot(o, 600.0, 0.0, 1.5)
			o.desk.finish_into_frame()
			o.desk.hold()
			_shoot(o, 600.0, 0.0, 0.4)
		"jupiter_date":
			o.desk.release_hold()
			o.set_date_text("2026-11-05 08:30")
		"jupiter":
			o.desk.set_target_text("Jupiter")
			_shoot(o, 0.01, 5.0)
		"moon_date": o.set_date_text("2026-11-05 09:30")
		"moon":
			o.desk.set_instrument("omegacam")
			o.desk.field = "full"
			o.desk.set_target_text("Moon")
			_shoot(o, 0.005)
		"moon_close":
			# The lit limb, closer: the disc's centre is on the crescent's night side.
			var d: DVec3 = o.desk.target_dir()
			var moon: Body = main.state.body_named("Moon")
			var sun_d := o.desk.body_dir(main.state.body_named("Sun"))
			var limb := sun_d.sub(d.scaled(sun_d.dot(d))).normalized()
			var dist := EarthFrame.from_scene(moon.pos.sub(main.state.body_named("Earth").pos)).length()
			var at := d.add(limb.scaled(0.8 * moon.radius / dist)).normalized()
			o.desk.field = "wide"
			o.desk._set_target({"name": "the Moon's lit limb", "kind": "sky", "dir": at, "v": NAN}, false)
			_shoot(o, 0.005)
		"lovell":
			o.desk.field = "pixels"
			o.desk.seeing = NAN
			o.set_site("jodrell")
			o.set_date_text("2026-11-04 19:30")
			var view: Dictionary = Facilities.DATA.jodrell.view
			o.wide()
			o.look(float(view.az), float(view.alt))
			o.desk.set_instrument("lovell_l")
		"cyg":
			o.desk._set_target({"name": "Cyg A", "kind": "radio", "dir": EarthFrame.radec_vec(deg_to_rad(float(Telescopes.RADIO["Cyg A"].ra)), deg_to_rad(float(Telescopes.RADIO["Cyg A"].dec))), "v": NAN}, false)
			_shoot(o, 1.0)
		"cas":
			o.desk._set_target({"name": "Cas A", "kind": "radio", "dir": EarthFrame.radec_vec(deg_to_rad(float(Telescopes.RADIO["Cas A"].ra)), deg_to_rad(float(Telescopes.RADIO["Cas A"].dec))), "v": NAN}, false)
			_shoot(o, 1.0)
		"end": get_tree().quit()
