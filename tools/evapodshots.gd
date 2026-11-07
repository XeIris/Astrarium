extends Node

const CT := preload("res://tools/crafttest.gd")
var output := ""
var vp: SubViewport
var frame: SubViewport
var craft
var cam: Camera3D
var cabin := CraftInterior.new()

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dump="): output=a.substr(5)
	if output.is_empty() or DisplayServer.get_name()=="headless":
		printerr("EVAPODSHOTS needs a GPU and dump=/absolute/directory")
		get_tree().quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	get_window().size=Vector2i(1280,960)
	CraftAssets.craft_models_ready(["evapod"])
	var fr: Array=CT.make_frame(self,1280,960,0x161e29)
	vp=fr[0]; frame=fr[1]
	CT.add_rig(vp,1.5,0x475569,.5)
	var show:=TextureRect.new(); show.texture=frame.get_texture(); show.size=Vector2(1280,960); add_child(show)
	craft=CraftModel.build_craft(Vehicles.get_vehicle("evapod")); vp.add_child(craft.group)
	cam=Camera3D.new(); cam.near=.01; cam.far=100; cam.fov=38; vp.add_child(cam); cam.current=true
	for shot in ["front","quarter","side","rear","under","extended","cockpit","cabin"]:
		cabin.dispose()
		craft.group.visible=true
		EvaPod.pose(craft.stages[0].parts.arms,1.0 if shot=="extended" else 0.0)
		cam.projection=Camera3D.PROJECTION_PERSPECTIVE; cam.fov=38
		var center:=Vector3(0,1.03,0)
		var offsets: Dictionary={"front":Vector3(0,.05,5),"quarter":Vector3(3.4,1.4,4.4),"side":Vector3(5,.3,0),"rear":Vector3(3.4,1.3,-4.4),"under":Vector3(2,-3.2,3.1),"extended":Vector3(3.1,1.5,4.9)}
		if shot=="cockpit":
			cabin.set_enabled(true,craft,Vehicles.get_vehicle("evapod"))
			cam.position=Vector3(0,1.34,-.13); cam.look_at(Vector3(0,1.10,1.0)); cam.fov=82
		elif shot=="cabin":
			cabin.set_enabled(true,craft,Vehicles.get_vehicle("evapod"))
			for n in craft.stages[0].group.get_children():
				if n!=cabin.group: n.visible=false
			var liner := cabin.group.find_child("window_liner",true,false) as Node3D
			if liner!=null: liner.visible=false
			cam.position=Vector3(1.65,2.15,2.1); cam.look_at(Vector3(0,1.05,0)); cam.fov=49
		else:
			cam.position=center+offsets[shot]; cam.look_at(center)
		for i in 5: await RenderingServer.frame_post_draw
		frame.get_texture().get_image().save_png(output.path_join(shot+".png"))
		print("EVAPODSHOTS ",shot)
		for n in craft.stages[0].group.get_children(): n.visible=true
	cabin.dispose(); craft.group.queue_free(); CraftAssets.clear()
	await get_tree().process_frame
	print("EVAPODSHOTS DONE")
	get_tree().quit()
