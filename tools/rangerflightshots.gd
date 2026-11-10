extends Node

const Catch = preload("res://tools/coursecheck.gd").Catch
var logger:=Catch.new()
var stage: Node
var f: Spaceflight
var output:=""
var failures:=0
signal captured(img: Image)

func check(ok: bool,label: String) -> void:
	if not ok:
		failures+=1; printerr("RANGERFLIGHTSHOTS FAIL ",label)

func settle(count:=12) -> void:
	for i in count:
		stage.animate(1.0/60)
		await RenderingServer.frame_post_draw

func shot(name_: String) -> void:
	stage.pipe.capture_next(func(img: Image): captured.emit.call_deferred(img))
	stage.animate(0.0)
	var img: Image=await captured
	if not output.is_empty(): img.save_png(output.path_join(name_+".png"))

func _ready() -> void:
	if DisplayServer.get_name()=="headless":
		printerr("RANGERFLIGHTSHOTS requires the production GPU renderer")
		get_tree().quit(1); return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dump="): output=a.substr(5)
	if not output.is_empty(): DirAccess.make_dir_recursive_absolute(output)
	OS.add_logger(logger); get_tree().create_timer(120).timeout.connect(func(): get_tree().quit(1))
	PlanetMaps.synchronous=true
	stage=load("res://main.tscn").instantiate(); add_child(stage)
	await get_tree().process_frame
	stage.set_process(false); stage._start("flight",true)
	await get_tree().process_frame
	stage.configure_window_scale(1.0); get_window().size=Vector2i(1440,960)
	stage.set_render_quality("high"); stage.pipe.postfx.grain=0.0; stage.scenario_world()
	await stage.launch_craft("ranger"); f=stage.flight
	check(f.active and f.interior.group==null,"exterior flight starts without loaded cabin")
	var best_phase:=0.0; var best_score:=-INF
	for i in 72:
		f.vessel.place_in_orbit(210e3,28.5,i*TAU/72)
		var score: float=f.sun_direction(DVec3.new()).dot(DQuat.nrm(f.vessel.r.clone()))
		if score>best_score: best_score=score; best_phase=i*TAU/72
	f.vessel.place_in_orbit(210e3,28.5,best_phase)
	var roof:=f.sun_direction(DVec3.new())
	var nose:=f.vessel.v.clone().add_scaled_in(roof,-f.vessel.v.dot(roof)); DQuat.nrm(nose)
	f.vessel.q.set_from_basis_columns(nose.cross(roof),nose,roof)
	f.vessel.omega.set_v(0,0,0)
	stage.state.paused=true; stage.set_hud_hidden(true)
	f.set_camera_mode("orbit"); f.fly_cam.state.fov=38
	f.camera_override=func(camera,pos,_site,_dt):
		var cb: Basis=f.craft.group.basis
		camera.pos.copy_from(pos).add_in(DVec3.from_v3(cb*Vector3(22,29,20)))
		camera.look_at(pos.clone().add_in(DVec3.from_v3(cb*Vector3(0,8,0))),cb*Vector3.BACK)
		camera.near=.02
	await settle(20); await shot("exterior")
	f.key_action("gear"); await settle(160)
	check(f.craft.stages[0].gear>.99,"gear command drives the production rig")
	await shot("gear")
	f.camera_override=Callable(); f.set_camera_mode("interior")
	await settle(20)
	check(f.interior.group!=null and f.local.camera.near<.011,"lazy cockpit and centimetre depth range")
	var basis_: Basis=f.craft.group.basis
	check((f.fly_cam.basis.y).dot(basis_*Vector3.BACK)>.999,"interior camera uses cabin up rather than thrust axis")
	await shot("cockpit")
	f.drag(-240,90); await settle(10); await shot("cabin-port")
	f.set_camera_mode("orbit"); await settle(3)
	check(f.interior.group==null,"exterior mode disposes cockpit")
	stage.end_flight(); for i in 3: await get_tree().process_frame
	for error in logger.take(): failures+=1; printerr("RANGERFLIGHTSHOTS ENGINE ",error)
	OS.remove_logger(logger)
	print("RANGERFLIGHTSHOTS DONE failures=%d"%failures)
	get_tree().quit(1 if failures else 0)
