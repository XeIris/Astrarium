extends Node

const Catch = preload("res://tools/coursecheck.gd").Catch
var stage: Node
var failures := 0
var checks := 0
var output := ""
signal captured(img: Image)

func expect(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("DOCKINGFLIGHTSHOTS FAIL ", label)

func shot(name_: String) -> void:
	for i in 8:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
	stage.pipe.capture_next(func(img: Image): captured.emit.call_deferred(img))
	stage.animate(0.0)
	var img: Image = await captured
	expect(not img.is_empty(), name_ + " produced a flight image")
	if output != "": expect(img.save_png(output.path_join(name_ + ".png")) == OK, "saved " + name_)

func fly_case(key: String, id: String, offset: Vector3, aim: Vector3, fov: float) -> void:
	var sc: Dictionary = FlightScenarios.find(key, id)
	stage.scenario_world()
	await CraftAssets.craft_models_ready([key, sc.base.carrier])
	var error := FlightScenarios.build(stage, sc)
	expect(error == "", id + " production base")
	if error != "": return
	stage.set_cam_mode("flight")
	var f: Spaceflight = stage.flight
	var dock := f.docking
	var parked := dock.craft.group.find_child(str(dock.berth.node), true, false) as Node3D
	expect(parked != null and not parked.visible, id + " has one craft at the target berth")
	expect(f.craft.authored and dock.craft.authored, id + " renders both authored craft")
	stage.state.paused = true
	f.set_camera_mode("orbit")
	f.fly_cam.state.fov = fov
	f.camera_override = func(camera, pos, _site, _dt):
		var basis_: Basis = dock.craft.group.basis
		camera.pos.copy_from(pos).add_in(DVec3.from_v3(basis_ * offset))
		camera.look_at(pos.clone().add_in(DVec3.from_v3(basis_ * aim)), basis_ * Vector3.BACK)
		camera.near = .04
	await shot(id + "-approach")
	stage.state.paused = false
	stage.set_drawn(false, false)
	for i in 4800:
		stage.step_flight(.05)
		if dock.latched or dock.failure != "": break
		if i % 60 == 0: await get_tree().process_frame
	stage.set_drawn(true)
	expect(dock.latched and dock.failure == "", id + " reaches the capture gate")
	stage.state.paused = true
	await shot(id + "-capture")
	if dock.latched:
		var frozen := dock.carrier.met
		stage.animate(.05)
		expect(dock.carrier.met == frozen, id + " capture stays frozen while paused")
		stage.state.paused = false
		for i in 60: stage.animate(1.0 / 60.0)
		var live := dock.measure(f.vessel, dock.port_pose())
		expect(dock.carrier.met > frozen and absf(live.gap) < 1e-5 and live.cross < 1e-5 \
			and live.speed < 1e-5 and live.angle < 1e-5, id + " follows the live berth after one second")
		expect(parked != null and not parked.visible \
			and f.craft.group.global_position.distance_to(parked.global_position) < .002,
			id + " rendered craft aligns with the hidden stowed datum")
	stage.end_flight()
	for i in 3: await get_tree().process_frame
	expect(not is_instance_valid(parked) and f.docking == null, id + " releases its carrier on exit")

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("DOCKINGFLIGHTSHOTS requires the production GPU renderer")
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("dump="): output = arg.substr(5)
	if output != "": DirAccess.make_dir_recursive_absolute(output)
	var logger := Catch.new()
	OS.add_logger(logger)
	get_tree().create_timer(150.0).timeout.connect(func(): get_tree().quit(1))
	PlanetMaps.synchronous = true
	get_viewport().set_disable_input(true)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	stage.set_process(false)
	for i in 4: await get_tree().process_frame
	stage._start("flight", true)
	stage.configure_window_scale(1.0)
	get_window().size = Vector2i(1440, 960)
	stage.set_render_quality("medium")
	stage.pipe.postfx.grain = 0.0
	stage.set_hud_hidden(true)
	await fly_case("evapod", "pod_berth", Vector3(-13, 8, -9), Vector3(0, -6, 0), 52.0)
	await fly_case("ranger", "spin_match", Vector3(-68, 55, -45), Vector3(0, -26, 0), 48.0)
	for error in logger.take():
		failures += 1
		printerr("DOCKINGFLIGHTSHOTS ENGINE ", error)
	OS.remove_logger(logger)
	print("DOCKINGFLIGHTSHOTS DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
