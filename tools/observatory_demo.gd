extends Node

# A scripted tour of the Observatory for a reproducible video:
#   Godot --path . --resolution 1600x1000 --write-movie /abs/demo.avi --fixed-fps 30 \
#         res://tools/observatory_demo.tscn
# The start screen, the picker's film of each facility with the arrows, Observe, a night
# from the ground with the overlay, a zoom, a night at one hour a second, and dates past
# the range. Quits after the last shot; without --write-movie it plays in real time.

var main: Node
var t := 0.0
var _i := 0
var _zoom := 0.0
# [start (s), what]; each step runs once when the clock passes its start.
var steps := [
	[0.0, "title"],
	[3.0, "enter"],
	[15.0, "next"],
	[27.0, "next"],
	[39.0, "observe"],
	[47.0, "zoom_in"],
	[52.0, "zoom_out"],
	[54.0, "timelapse"],
	[61.0, "extrapolated"],
	[64.0, "far"],
	[68.0, "end"],
]

func _ready() -> void:
	main = load("res://main.tscn").instantiate()
	add_child(main)

func _process(dt: float) -> void:
	t += dt
	while _i < steps.size() and t >= float(steps[_i][0]):
		_run(String(steps[_i][1]))
		_i += 1
	if _zoom != 0.0: main.observer.zoom(exp(_zoom * dt))

func _run(what: String) -> void:
	var o: Observatory = main.observatory
	match what:
		"title": pass
		"enter": main._start("observatory")
		"next": o.picker_step(1)
		"observe":
			o.observe()
			o.set_rate("pause")
			o.set_date_text("2026-11-05 02:30")
			o.look(150.0, 32.0)
		"zoom_in":
			o.look(165.0, 58.0)
			_zoom = -0.75
		"zoom_out":
			_zoom = 0.0
			main.observer.fov = 70.0
		"timelapse":
			o.set_date_text("2026-11-05 00:30")
			o.look(100.0, 25.0)
			o.set_rate("3600x")
		"extrapolated":
			o.set_rate("pause")
			o.set_date_text("2126-11-05 02:30")
			o.look(150.0, 32.0)
		"far": o.set_date_text("2400-11-05 02:30")
		"end": get_tree().quit()
