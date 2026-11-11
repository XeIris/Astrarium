extends Node

const Catch=preload("res://tools/coursecheck.gd").Catch
var logger:=Catch.new()
var stage: Node
var output:=""
var failures:=0
signal captured(img: Image)

func check(ok: bool,label: String) -> void:
	if not ok:failures+=1;printerr("DISCOVERYFLIGHTSHOTS FAIL ",label)

func settle(count:=12) -> void:
	for i in count:
		stage.animate(1.0/60)
		await RenderingServer.frame_post_draw

func shot(name_: String) -> void:
	stage.pipe.capture_next(func(img: Image):captured.emit.call_deferred(img))
	stage.animate(0.0)
	var img: Image=await captured
	if output!="":img.save_png(output.path_join(name_+".png"))

func _ready() -> void:
	if DisplayServer.get_name()=="headless":
		printerr("DISCOVERYFLIGHTSHOTS requires the production GPU renderer")
		get_tree().quit(1);return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dump="):output=a.substr(5)
	if output!="":DirAccess.make_dir_recursive_absolute(output)
	OS.add_logger(logger);get_tree().create_timer(120).timeout.connect(func():get_tree().quit(1))
	PlanetMaps.synchronous=true
	stage=load("res://main.tscn").instantiate();add_child(stage)
	await get_tree().process_frame
	stage.set_process(false);stage._start("flight",true)
	await get_tree().process_frame
	stage.configure_window_scale(1.0);get_window().size=Vector2i(1440,960)
	stage.set_render_quality("high");stage.pipe.postfx.grain=0.0;stage.scenario_world("jovian_voyage")
	await stage.launch_craft("discovery")
	var f: Spaceflight=stage.flight
	check(f.active and f.craft.authored,"authored Explorer enters production flight")
	f.vessel.place_in_orbit(1000e3,0.0,0.0)
	f.vessel.q.set_from_unit_vectors(Vessel.BODY_FWD,f.sun_direction(DVec3.new()))
	f.vessel.omega.set_v(0,0,0);stage.state.paused=false
	await settle(120)
	check(f.craft.stages[0].deploy>.99,"production orbital state opens the pod covers")
	check(absf(float(f.vessel.telemetry.centrifuge.gees)-.329213)<.00001,"gravity telemetry follows the authored rotor")
	var rotor: Node3D=f.craft.stages[0].parts.rotors[0]
	var moving:=rotor.quaternion
	await settle(10)
	check(rotor.quaternion.angle_to(moving)>.10,"accepted flight time turns the rotor")
	stage.state.paused=true
	var paused:=rotor.quaternion
	await settle(10)
	check(rotor.quaternion.angle_to(paused)<1e-6,"paused flight freezes rotor phase")
	stage.set_hud_hidden(true);f.set_camera_mode("orbit");f.fly_cam.state.fov=30
	f.camera_override=func(camera,pos,_site,_dt):
		var basis_: Basis=f.craft.group.basis
		camera.pos.copy_from(pos).add_in(DVec3.from_v3(basis_*Vector3(145,160,135)))
		camera.look_at(pos.clone().add_in(DVec3.from_v3(basis_*Vector3(0,48,0))),basis_*Vector3.BACK)
		camera.near=.05
	await settle(12);await shot("exterior")
	f.camera_override=func(camera,pos,_site,_dt):
		var basis_: Basis=f.craft.group.basis
		camera.pos.copy_from(pos).add_in(DVec3.from_v3(basis_*Vector3(12,114,7)))
		camera.look_at(pos.clone().add_in(DVec3.from_v3(basis_*Vector3(0,97,0))),basis_*Vector3.BACK)
		camera.near=.02
	f.fly_cam.state.fov=45
	await settle(12);await shot("pod-bays")
	stage.set_hud_hidden(false);stage.set_panel_open("flightPanel",true)
	stage.hud.toast("",1)
	await settle(15)
	check(f.hud.habitat_box.is_visible_in_tree(),"artificial-gravity measurements are visible in Systems")
	check(f.hud.habitat_values[3].v.said()=="momentum not modelled","gyroscopic omission is visible to the pilot")
	check(not stage.hud.flight_panel.get_global_rect().intersects(f.console.get_global_rect()),"Systems stays above the flight console")
	if output!="":get_viewport().get_texture().get_image().save_png(output.path_join("gravity-hud.png"))
	stage.end_flight();for i in 3:await get_tree().process_frame
	for error in logger.take():failures+=1;printerr("DISCOVERYFLIGHTSHOTS ENGINE ",error)
	OS.remove_logger(logger)
	print("DISCOVERYFLIGHTSHOTS DONE failures=%d"%failures)
	get_tree().quit(1 if failures else 0)
