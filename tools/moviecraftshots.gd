extends Node

const CT := preload("res://tools/crafttest.gd")
var output := ""
var id := "ranger"
var cabin := CraftInterior.new()

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("dump="): output=a.substr(5)
		if a.begins_with("v="): id=a.substr(2)
	if output.is_empty() or DisplayServer.get_name()=="headless":
		printerr("MOVIECRAFTSHOTS requires a GPU and dump=/absolute/directory")
		get_tree().quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	get_window().size=Vector2i(1280,960)
	CraftAssets.craft_models_ready([id])
	var fr: Array=CT.make_frame(self,1280,960,0x161e29)
	var vp: SubViewport=fr[0]; var frame: SubViewport=fr[1]
	CT.add_rig(vp,1.5,0x475569,.5)
	for light in vp.find_children("*","DirectionalLight3D",true,false): light.light_cull_mask &= ~CraftInterior.LAYER
	var show:=TextureRect.new(); show.texture=frame.get_texture(); show.size=Vector2(1280,960); add_child(show)
	var vehicle: Dictionary=Vehicles.get_vehicle(id)
	var craft=CraftModel.build_craft(vehicle); vp.add_child(craft.group)
	var cam:=Camera3D.new(); cam.near=.01; cam.far=1000; cam.fov=38; vp.add_child(cam); cam.current=true
	for shot in ["quarter","front","side","rear","top","under","gear","cockpit","port","aft","cutaway"]:
		cabin.dispose()
		craft.update({"dt":4.0,"gear":{id:1.0 if shot=="gear" else 0.0}})
		var center:=Vector3(0,8,0)
		var offsets: Dictionary={"quarter":Vector3(22,23,20),"front":Vector3(0,34,8),"side":Vector3(35,0,7),"rear":Vector3(20,-31,17),"top":Vector3(0,.01,35),"under":Vector3(17,15,-28),"gear":Vector3(24,21,-15)}
		cam.fov=38
		if shot in ["cockpit","port","aft","cutaway"]:
			cabin.set_enabled(true,craft,vehicle)
			var eye: Array=vehicle.interior.eye
			cam.position=Vector3(eye[0],eye[1],eye[2]); cam.fov=85
			var targets: Dictionary={"cockpit":Vector3(-.40,9.8,1.15),"port":Vector3(-2.0,8.1,.8),"aft":Vector3(0,3.1,.65)}
			if shot=="cutaway":
				for n in craft.stages[0].group.get_children():
					if n!=cabin.group: n.visible=false
				var liner:=cabin.group.find_child("window_liner",true,false) as Node3D
				if liner!=null: liner.visible=false
				cam.position=Vector3(5,12,6); cam.look_at(Vector3(0,6.4,.4),Vector3.BACK); cam.fov=55
			else: cam.look_at(targets[shot],Vector3.BACK)
		else:
			cam.position=center+offsets[shot]; cam.look_at(center,Vector3.BACK)
		for i in 6: await RenderingServer.frame_post_draw
		frame.get_texture().get_image().save_png(output.path_join(shot+".png"))
		print("MOVIECRAFTSHOTS ",id," ",shot)
		for n in craft.stages[0].group.get_children(): n.visible=true
	cabin.dispose(); craft.group.queue_free(); CraftAssets.clear()
	await get_tree().process_frame
	print("MOVIECRAFTSHOTS DONE")
	get_tree().quit()
