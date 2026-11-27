extends Node

# MAP CHECK: the two flat maps (ui/explore_map.gd, ui/space_map.gd) through real clicks.
# Planetary exploration's picker runs a slow clock of its own, and a world chosen from its
# list is held in the middle; the flight map holds a clicked body in the middle at 1000×.
#   Godot --headless --path . res://tools/mapcheck.tscn

const Catch = preload("res://tools/coursecheck.gd").Catch
const DT := 1.0 / 60.0
var catcher := Catch.new()
var main: Node
var checks := 0
var failures := 0

func check(label: String, ok: bool, detail := "") -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s%s" % ["ok" if ok else "FAIL", label, "" if ok or detail == "" else " — " + detail])

func _ready() -> void:
	OS.add_logger(catcher)
	PlanetMaps.synchronous = true
	main = load("res://main.tscn").instantiate()
	add_child(main)
	main.set_process(false)
	for i in 3: await get_tree().process_frame
	await picker()
	await flight_map()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("MAPCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)

## A press and release at `at`, as the pointer would; returns the control it landed on.
func click(at: Vector2) -> Control:
	get_viewport().notify_mouse_entered()
	var e := InputEventMouseMotion.new()
	e.position = at; e.global_position = at
	get_viewport().push_input(e, true)
	var under := get_viewport().gui_get_hovered_control()
	for pressed in [true, false]:
		var c := InputEventMouseButton.new()
		c.button_index = MOUSE_BUTTON_LEFT; c.pressed = pressed; c.position = at; c.global_position = at
		get_viewport().push_input(c, true)
	return under

## The stage and the map stepped together; the worst distance of `b` from the middle in
## the second half, once a glide onto it has had time to ease out.
func held(map: Control, b: Body, frames := 120) -> float:
	var worst := 0.0
	for i in frames:
		main.animate(DT)
		map._process(DT)
		if i >= frames / 2: worst = maxf(worst, map.to_screen(b.pos).distance_to(map.size * 0.5))
	return worst

func picker() -> void:
	main._start("explore")
	var m: ExploreMap = main.explore_map
	# The list is laid out on the frame after it opens.
	for i in 2: await get_tree().process_frame
	var moon: Body = main.state.body_named("Moon")
	var c := m.primary_of(moon)
	var period := sqrt(pow(moon.pos.distance_to(c.pos), 3.0) / (moon.mass + c.mass))
	check("the picker turns the quickest orbit in a minute, not the scenario's time-lapse",
		absf(period / main.state.time_scale - ExploreMap.ORBIT_ON_SCREEN_S) < 1.0, "%s yr/s" % main.state.time_scale)
	for name in ["Earth", "Moon", "Mars", "Pluto"]:
		var btn: BaseButton = null
		for item in m.list.body.get_children():
			if item is BaseButton and item.text == name: btn = item
		var under := click(btn.get_global_rect().get_center())
		await get_tree().process_frame
		var b: Body = main.state.body_named(name)
		var worst := held(m, b)
		check("%s's button holds it in the middle of the picker" % name, under == btn and m.follow == b and worst < 1.0,
			"%s px off, following %s, %s under the pointer" % [worst, m.follow.name if m.follow != null else "nothing", under])
	# Back to the whole system, then a click on a world in view glides it in.
	main.set_app_mode("explore")
	await get_tree().process_frame
	var mars: Body = main.state.body_named("Mars")
	click(m.to_screen(mars.pos))
	await get_tree().process_frame
	var worst := held(m, mars)
	check("a click on Mars in the picker holds it in the middle", m.follow == mars and worst < 1.0, "%s px off" % worst)
	main.quit_to_start()

func flight_map() -> void:
	main.scenario_world("solar")
	CraftAssets.craft_models_ready(["falcon9"])
	var err := FlightScenarios.build(main, FlightScenarios.find("falcon9", "orbit"))
	check("a Falcon 9 in orbit is built", err == "", err)
	main.state.app_mode = "flight"
	main.set_cam_mode("flight")
	main.open_map()
	await get_tree().process_frame
	var map: SpaceMap = main.space_map
	main.flight.set_warp(Spaceflight.WARPS.find(1000))
	check("the flight is at 1000× warp", main.flight.warp() == 1000, "%s×" % main.flight.warp())
	# Earth first: once the view is down on the Moon, Earth is off the screen.
	for name in ["Earth", "Moon"]:
		var b: Body = main.state.body_named(name)
		click(map.to_screen(b.pos))
		await get_tree().process_frame
		var worst := held(map, b)
		check("a click on the %s holds it in the middle of the flight map at 1000×" % name, map.follow == b and worst < 1.0,
			"%s px off, following %s" % [worst, map.follow.name if map.follow != null else "nothing"])
	main.close_map()
	main.end_flight()
