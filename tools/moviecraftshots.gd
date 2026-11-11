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
	var shots: Array=["quarter","front","side","rear","top","under","gear","cockpit","port","aft","cutaway"] if vehicle.has("interior") else ["quarter","front","side","rear","top","under","command","hatches","rotor","stern"]
	if id=="endurance":shots=["quarter","front","side","rear","top","under","hub","module"]
	if id=="lander":shots=["quarter","front","side","rear","top","under","nose","drive"]
	var length:=float(vehicle.stages[0].L)
	var framing:=maxf(length,float(vehicle.stages[0].D))
	for shot in shots:
		cabin.dispose()
		craft.update({"dt":4.0,"properTime":1.0,"gear":{id:1.0 if shot=="gear" else 0.0},"deploy":{str(vehicle.stages[0].key):1.0 if shot in ["hatches","rotor"] else 0.0}})
		var center:=Vector3(0,length*.45,0)
		var offsets: Dictionary={"quarter":Vector3(1.22,1.28,1.11)*length,"front":Vector3(0,1.90,.45)*length,"side":Vector3(1.95,0,.39)*length,"rear":Vector3(1.11,-1.72,.94)*length,"top":Vector3(0,.001,1.95)*length,"under":Vector3(.94,.83,-1.55)*length,"gear":Vector3(1.34,1.17,-.84)*length}
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
		elif shot in ["hub","module","nose","drive"]:
			var views: Dictionary={"hub":[Vector3(10,39,8),Vector3(0,20,0)],
				"module":[Vector3(43,28,13),Vector3(27,17,0)],
				"nose":[Vector3(14,27,10),Vector3(0,length*.74,0)],
				"drive":[Vector3(14,-16,9),Vector3(0,2,-.7)]}
			cam.position=views[shot][0];cam.look_at(views[shot][1],Vector3.BACK);cam.fov=45
		elif shot in ["command","hatches","rotor","stern"]:
			var radius:=float(vehicle.stages[0].D)*.5
			center=Vector3(0,length-radius,0)
			cam.position=center+Vector3(-radius*1.48,radius*3.2,radius*.65); cam.look_at(center,Vector3.BACK)
			if shot=="rotor":
				var shell:=craft.group.find_child("inspection_command_hull",true,false) as Node3D
				if shell!=null: shell.visible=false
				cam.position=center+Vector3(radius*2.2,radius*1.5,radius*.8);cam.look_at(center,Vector3.BACK)
			elif shot=="stern":
				center=Vector3(0,9,0);cam.position=Vector3(radius*2,-radius*2.8,radius*1.2);cam.look_at(center,Vector3.BACK)
		else:
			cam.position=center+(offsets[shot] as Vector3)*framing/length; cam.look_at(center,Vector3.BACK)
			if shot in ["quarter","side","rear","under"]:
				if id=="discovery":cam.fov=24
				if id=="endurance":cam.fov=30
		for i in 6: await RenderingServer.frame_post_draw
		frame.get_texture().get_image().save_png(output.path_join(shot+".png"))
		print("MOVIECRAFTSHOTS ",id," ",shot)
		for n in craft.stages[0].group.get_children(): n.visible=true
		var shell:=craft.group.find_child("inspection_command_hull",true,false) as Node3D
		if shell!=null: shell.visible=true
	cabin.dispose(); craft.group.queue_free(); CraftAssets.clear()
	await get_tree().process_frame
	print("MOVIECRAFTSHOTS DONE")
	get_tree().quit()
