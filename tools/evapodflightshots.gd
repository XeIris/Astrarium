extends Node

const Catch = preload("res://tools/coursecheck.gd").Catch
var logger := Catch.new()
var stage: Node
var f: Spaceflight
var output := ""
var failures := 0
var authored := false
signal captured(img: Image)

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("EVAPODFLIGHT FAIL ",label)

func settle(frames := 12) -> void:
	for i in frames:
		stage.animate(1.0/60.0)
		await RenderingServer.frame_post_draw

func shot(name_: String) -> void:
	stage.pipe.capture_next(func(img: Image): captured.emit.call_deferred(img))
	stage.animate(0.0)
	var img: Image = await captured
	if not output.is_empty(): img.save_png(output.path_join(name_+".png"))

func _ready() -> void:
	if DisplayServer.get_name()=="headless":
		printerr("EVAPODFLIGHT requires rendered flight and a GPU")
		get_tree().quit(1)
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dump="): output=a.substr(5)
	if not output.is_empty(): DirAccess.make_dir_recursive_absolute(output)
	OS.add_logger(logger)
	get_tree().create_timer(120).timeout.connect(func(): get_tree().quit(1))
	PlanetMaps.synchronous=true
	stage=load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("flight",true)
	await get_tree().process_frame
	stage.configure_window_scale(1.0)
	get_window().size=Vector2i(1440,960)
	stage.set_render_quality("high")
	stage.pipe.postfx.grain=0.0
	stage.scenario_world()
	await stage.launch_craft("evapod")
	f=stage.flight
	authored=f.craft.authored
	check(f.active,"pod enters spaceflight")
	# A reproducible sunlit orbit lets screenshots expose skin and joint defects.
	var best_phase:=0.0
	var best_score:=-INF
	for i in 72:
		f.vessel.place_in_orbit(210e3,28.5,i*TAU/72)
		var sun: DVec3=f.sun_direction(DVec3.new())
		var up: DVec3=DQuat.nrm(f.vessel.r.clone())
		var score: float=sun.dot(up)
		if score>best_score:
			best_score=score
			best_phase=i*TAU/72
	f.vessel.place_in_orbit(210e3,28.5,best_phase)
	check(f.interior.group==null,"cockpit is absent in exterior view")
	stage.state.paused=false
	var prop: float=f.vessel.current_stage.prop
	var coord: float=f.vessel.coord
	f.vessel.throttle=.25
	await settle(120)
	f.vessel.throttle=0.0
	check(f.vessel.coord>coord+1.9 and f.vessel.current_stage.prop<prop,"normal integrator advances flight and pays for thrust")
	stage.state.paused=true
	stage.set_hud_hidden(true)
	f.set_camera_mode("orbit")
	f.fly_cam.state.fov=38.0
	f.camera_override=func(camera, pos, _site, _dt):
		var cb: Basis=f.craft.group.basis
		camera.pos.copy_from(pos).add_in(DVec3.from_v3(cb*Vector3(3.4,2.3,4.5)))
		camera.look_at(pos.clone().add_in(DVec3.from_v3(cb*Vector3(0,1.03,0))),cb*Vector3.UP)
		camera.near=.02
	await settle(30)
	await shot("flight-exterior")
	f.key_action("gear")
	for i in 180:
		stage.animate(1.0/60.0)
		await RenderingServer.frame_post_draw
	check(f.craft.stages[0].deploy>.99,"flight command extends arms")
	await shot("flight-arms")
	f.camera_override=Callable()
	f.set_camera_mode("interior")
	f.fly_cam.state.interiorPitch=.18
	await settle(20)
	check(f.interior.group!=null and f.interior.authored==authored and f.local.camera.near<=.011,"authored cockpit uses close depth range")
	await shot("flight-interior")
	f.drag(160,-20)
	await settle()
	await shot("flight-look")
	stage.set_hud_hidden(false)
	stage.sync_warp_label()
	await settle()
	# The pipeline capture contains 3D only; the viewport capture also includes Controls.
	await RenderingServer.frame_post_draw
	if not output.is_empty(): get_viewport().get_texture().get_image().save_png(output.path_join("flight-hud.png"))
	f.set_camera_mode("orbit")
	await settle(3)
	check(f.interior.group==null,"camera exit releases cockpit")
	stage.end_flight()
	for i in 3: await get_tree().process_frame
	for error in logger.take():
		failures += 1
		printerr("EVAPODFLIGHT ENGINE ",error)
	OS.remove_logger(logger)
	print("EVAPODFLIGHT DONE failures=%d"%failures)
	get_tree().quit(1 if failures else 0)
