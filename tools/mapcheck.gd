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
var glides := 0
var cuts := 0

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
	get_viewport().notify_mouse_entered()
	await picker()
	await flight_map()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("MAPCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)

## A press and release at `at`, as the pointer would; returns the control it landed on.
func click(at: Vector2) -> Control:
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

## Click `at` to follow `b`, then hold it. The first step shows the glide's direction: from
## within a screen `b` starts toward the middle from where it was, from beyond it is there at once.
func follows(map: Control, b: Body, at: Vector2, target: Control, label: String) -> void:
	var was: Body = map.follow
	var c := map.size * 0.5
	var before: Vector2 = map.to_screen(b.pos)
	var under := click(at)
	map._process(DT)
	var after: Vector2 = map.to_screen(b.pos)
	var cut := before.distance_to(c) > map.size.length()
	var first := after.distance_to(c) < 1.0 if cut \
		else (after - c).dot(before - c) > 0.0 and after.distance_to(c) < before.distance_to(c)
	if cut: cuts += 1
	else: glides += 1
	var worst := held(map, b)
	check(label, was != b and under == target and map.follow == b and first and worst < 1.0,
		"%s px off, first step %s → %s (%s), following %s, %s under the pointer" % [worst, before, after,
			"cut" if cut else "glide", map.follow.name if map.follow != null else "nothing", under])

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
	# Earth and then the Moon are in view when chosen and glide in; Mars and Pluto are cut to.
	for name in ["Earth", "Moon", "Mars", "Pluto"]:
		var btn: BaseButton = null
		for item in m.list.body.get_children():
			if item is BaseButton and item.text == name: btn = item
		follows(m, main.state.body_named(name), btn.get_global_rect().get_center(), btn,
			"%s's button brings it to the middle of the picker and holds it there" % name)
	main.set_app_mode("explore")
	await get_tree().process_frame
	var mars: Body = main.state.body_named("Mars")
	follows(m, mars, m.to_screen(mars.pos), m, "a click on Mars in the picker brings it to the middle and holds it there")
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
	# The map opens following the ship's primary, Earth: follow the ship first, so that the
	# click on Earth is what follows it. Earth first: once down on the Moon, Earth is off screen.
	map._on_menu(SpaceMap.MENU_SHIP)
	map._process(DT)
	for name in ["Earth", "Moon"]:
		var b: Body = main.state.body_named(name)
		follows(map, b, map.to_screen(b.pos), map, "a click on the %s brings it to the middle of the flight map at 1000× and holds it there" % name)
	check("both a glide and a cut were checked", glides > 0 and cuts > 0, "%d glides, %d cuts" % [glides, cuts])
	main.close_map()
	main.end_flight()
