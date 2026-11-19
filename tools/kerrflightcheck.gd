extends Node

const Catch=preload("res://tools/coursecheck.gd").Catch
var checks:=0
var failures:=0
var stage: Node
signal captured(img: Image)

func expect(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;printerr("KERRFLIGHTCHECK FAIL ",label)

func shot(output: String,name_: String) -> Image:
	for i in 8:
		stage.animate(1.0/60.0)
		await RenderingServer.frame_post_draw
	stage.pipe.capture_next(func(img: Image):captured.emit.call_deferred(img))
	stage.animate(0.0)
	var img: Image=await captured
	if output!="":expect(img.save_png(output.path_join(name_+".png"))==OK,"saved "+name_)
	return img

func has_backdrop(img: Image) -> bool:
	var bright:=0
	for y in range(1,13):
		for x in range(1,25):
			var pixel:=img.get_pixel(img.get_width()*x/25,img.get_height()*y/65)
			if pixel.get_luminance()>.04:bright+=1
	return bright>=20

func _ready() -> void:
	var output:=""
	var render:=OS.get_cmdline_user_args().has("render=1")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("dump="):output=arg.substr(5)
	render=render or output!=""
	if render and DisplayServer.get_name()=="headless":
		printerr("KERRFLIGHTCHECK render requires a GPU");get_tree().quit(1);return
	var logger:=Catch.new();OS.add_logger(logger)
	get_tree().create_timer(120).timeout.connect(func():get_tree().quit(1))
	PlanetMaps.synchronous=true;get_viewport().set_disable_input(true)
	stage=load("res://main.tscn").instantiate();add_child(stage);stage.set_process(false)
	for i in 4:await get_tree().process_frame
	stage._start("flight",true)
	var result: String=await stage.jump_scenario("endurance:kerr_orbit")
	expect(result=="","registered production scenario builds")
	if result!="":get_tree().quit(1);return
	var f: Spaceflight=stage.flight;var v:=f.vessel
	var orbit: Dictionary=v.telemetry.kerr
	var original_prop: float=v.stages[0].prop
	var initial:=v.r.clone();var years: float=stage.state.sim_years
	var accepted: float=stage.step_flight(.05)
	expect(absf((float(stage.state.sim_years)-years)*Rocketry.YR_S-accepted)<1e-7,"world and demonstration share accepted coordinate seconds")
	expect(absf(v.met-accepted/float(orbit.dilation))<1e-10 and v.r.distance_to(initial)>1.0,"Kerr proper time and azimuth advance together")
	var old_time:=v.coord
	accepted=f.update(.2,null,func(seconds: float) -> float:return seconds*.25)
	expect(absf(accepted-.05)<1e-10 and absf(v.coord-old_time-accepted)<1e-10 and v.step_guard_hit,"partial world acceptance limits both clocks")
	stage.state.paused=true
	var paused:=v.r.clone();var paused_met:=v.met
	expect(f.update(.05)==0.0 and v.r.distance_to(paused)<1e-6 and v.met==paused_met,"pause freezes orbit and proper time")
	stage.state.paused=false;f.set_warp(9)
	stage.step_flight((float(orbit.period)-v.coord)/f.warp())
	expect(v.r.distance_to(initial)<.001,"one accepted coordinate period closes the orbit")
	expect(absf(v.met-float(orbit.period)/float(orbit.dilation))<1e-8,"proper time matches the independent orbit ratio")
	expect(f.autopilot==null and v.stages[0].prop==original_prop and not f.key_action("throttle_full"),"prescribed orbit cannot enter ordinary thrust control")
	if render:
		if output!="":DirAccess.make_dir_recursive_absolute(output)
		stage.configure_window_scale(1.0);get_window().size=Vector2i(1440,960)
		stage.set_render_quality("medium");stage.pipe.postfx.grain=0.0
		stage.state.paused=true;f.set_warp(0)
		stage.set_hud_hidden(true);stage.hud.toast("",1)
		var default:=await shot(output,"kerr-default")
		expect(stage.pipe.use_lens and has_backdrop(default),"default orbit view contains the lensed sky")
		var view: Dictionary={"offset":DVec3.new(110,80,57)}
		f.camera_override=func(camera,pos,_site,_dt):
			camera.pos.copy_from(pos).add_in(view.offset)
			var basis_: Basis=f.craft.group.basis
			camera.look_at(pos.clone().add_in(DVec3.from_v3(basis_*Vector3(0,18,0))),Vector3.BACK)
			camera.near=.05
		var shadow:=await shot(output,"kerr-shadow")
		view.offset=DVec3.new(85,-110,45)
		var escape:=await shot(output,"kerr-escape")
		expect(has_backdrop(escape) and shadow.get_pixel(0,0).get_luminance()<.04,"outward rays escape and the inward view shows the shadow")
		print("KERRFLIGHTCHECK VIEW lens=%s cameraAU=%.5f spin=%.3f"%[stage.state.show_lens,stage.cam_pos.length(),orbit.spin])
		stage.set_hud_hidden(false);stage.set_panel_open("flightPanel",true);stage.hud.toast("",1)
		await get_tree().create_timer(.45).timeout
		for i in 10:stage.animate(1.0/60.0);await RenderingServer.frame_post_draw
		expect(f.hud.ut_v.k.said()=="t · infinity","reference clock is identified at infinity")
		if output!="":expect(get_viewport().get_texture().get_image().save_png(output.path_join("kerr-hud.png"))==OK,"clock and orbit readout rendered")
	stage.end_flight()
	for i in 3:await get_tree().process_frame
	for error in logger.take():failures+=1;printerr("KERRFLIGHTCHECK ENGINE ",error)
	OS.remove_logger(logger)
	print("KERRFLIGHTCHECK DONE checks=%d failures=%d"%[checks,failures])
	get_tree().quit(1 if failures else 0)
