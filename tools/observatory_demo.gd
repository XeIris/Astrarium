extends Node

# A scripted tour of the Observatory for a reproducible video:
#   Godot --path . --resolution 1600x1000 --write-movie /abs/demo.avi --fixed-fps 30 \
#         res://tools/observatory_demo.tscn
# The start screen, the three sites at night, winter and summer midnight at one site,
# the overlay off and on, a night at one hour a second, and dates past the range.
# Quits after the last shot; without --write-movie it plays in real time.

var main: Node
var t := 0.0
var _i := 0
var _pan := 0.0
# [start (s), what]; each step runs once when the clock passes its start.
var steps := [
	[0.0, "title"],
	[3.0, "enter"],
	[7.0, "maunakea"],
	[10.5, "jodrell"],
	[14.0, "winter"],
	[17.5, "summer"],
	[21.0, "figures_off"],
	[23.0, "figures_on"],
	[25.0, "timelapse"],
	[31.0, "extrapolated"],
	[34.0, "far"],
	[38.0, "end"],
]

func _ready() -> void:
	main = load("res://main.tscn").instantiate()
	add_child(main)

func _process(dt: float) -> void:
	t += dt
	while _i < steps.size() and t >= float(steps[_i][0]):
		_run(String(steps[_i][1]))
		_i += 1
	# A slow pan keeps the sky turning on screen between steps.
	if main.observatory.active and _pan != 0.0:
		main.observer.look(_pan * dt, 0.0)

func _run(what: String) -> void:
	var o: Observatory = main.observatory if main.observatory else null
	match what:
		"title": pass
		"enter":
			main._start("observatory")
			o.set_site("paranal")
			o.set_rate("60x")
			o.set_date_text("2026-11-04 02:30")
			o.look(150.0, 30.0)
			_pan = -0.03
		"maunakea":
			o.set_site("maunakea")
			o.set_date_text("2026-11-04 09:30")
			o.look(0.0, 22.0)
		"jodrell":
			o.set_site("jodrell")
			o.set_date_text("2026-11-04 00:30")
			o.look(10.0, 35.0)
		"winter":
			o.set_rate("pause")
			o.set_date_text("2026-12-21 00:00")
			o.look(180.0, 28.0)
			_pan = 0.0
		"summer":
			o.set_date_text("2026-06-21 00:00")
		"figures_off":
			main._on_obs_action("view", "lines")
			main._on_obs_action("view", "names")
		"figures_on":
			main._on_obs_action("view", "lines")
			main._on_obs_action("view", "names")
		"timelapse":
			o.set_site("paranal")
			o.set_date_text("2026-11-04 00:00")
			o.look(165.0, 32.0)
			main._on_obs_action("view", "bounds")
			o.set_rate("3600x")
		"extrapolated":
			o.set_rate("pause")
			main._on_obs_action("view", "bounds")
			o.set_site("jodrell")
			o.set_date_text("2126-12-21 00:00")
			o.look(180.0, 28.0)
		"far":
			o.set_date_text("2400-12-21 00:00")
		"end":
			get_tree().quit()
