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
	if OS.get_cmdline_user_args().has("tour"):
		await record_tour()
		return
	get_window().size=Vector2i(1280,960)
	CraftAssets.craft_models_ready([id])
	var fr: Array=CT.make_frame(self,1280,960,0x161e29)
	var vp: SubViewport=fr[0]; var frame: SubViewport=fr[1]
	CT.add_rig(vp,1.5,0x475569,.5)
	for light in vp.find_children("*","DirectionalLight3D",true,false): light.light_cull_mask &= ~CraftInterior.LAYER
	if id == "endurance":
		var lights := vp.find_children("*","DirectionalLight3D",true,false)
		light_forward_face(lights)
		lights[0].shadow_enabled = true
		lights[0].directional_shadow_max_distance = 145
	var show:=TextureRect.new(); show.texture=frame.get_texture(); show.size=Vector2(1280,960); add_child(show)
	var vehicle: Dictionary=Vehicles.get_vehicle(id)
	var craft=CraftModel.build_craft(vehicle); vp.add_child(craft.group)
	var cam:=Camera3D.new(); cam.near=.01; cam.far=1000; cam.fov=38; vp.add_child(cam); cam.current=true
	var shots: Array=["quarter","front","side","rear","top","under","gear","cockpit","port","aft","cutaway"] if vehicle.has("interior") else ["quarter","front","side","rear","top","under","command","hatches","rotor","stern"]
	if id=="endurance":shots=["quarter","front","side","rear","top","under","hub","module","formation","bow"]
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
		elif shot in ["formation","bow"]:
			craft.update({"dt":0.0,"properTime":0.0})
			var axis := Vector3(0,float(vehicle.stages[0].look.ring.at),0)
			if shot == "bow":
				cam.position = axis + Vector3(0,-94,0)
				cam.look_at(axis,Vector3.BACK)
				cam.fov = 43
			else:
				cam.position = axis + Vector3(14,-55,-52)
				cam.look_at(axis+Vector3(0,-4,0),Vector3.RIGHT)
				cam.fov = 37
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

func light_forward_face(lights: Array) -> void:
	lights[0].basis = CT.look_basis(Vector3(-.44,.68,.62))
	lights[1].basis = CT.look_basis(Vector3(.68,.35,-.62))
	lights[1].light_energy = .48

## 24 fps frames in catalogue metres. Each shot moves the camera in model space.
func record_tour() -> void:
	get_window().size = Vector2i(1280,720)
	var frames := CT.make_frame(self,1280,720,0x121820)
	var world: SubViewport = frames[0]
	var composite: SubViewport = frames[1]
	CT.add_rig(world,1.7,0x475569,.5)
	var lights := world.find_children("*","DirectionalLight3D",true,false)
	for light in lights: light.light_cull_mask &= ~CraftInterior.LAYER
	lights[0].shadow_enabled = true
	var display := TextureRect.new()
	display.texture = composite.get_texture()
	display.size = Vector2(1280,720)
	add_child(display)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.current = true
	cam.near = .01
	cam.far = 1600
	var key_basis: Basis = lights[0].basis
	var fill_basis: Basis = lights[1].basis
	var fill_energy: float = lights[1].light_energy
	var number := 0
	var lineup := ["discovery","evapod","endurance","ranger","lander"]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("v=") and id in lineup: lineup = [id]
	for key in lineup:
		await CraftAssets.craft_models_ready([key])
		var vehicle: Dictionary = Vehicles.get_vehicle(key)
		var craft := CraftModel.build_craft(vehicle)
		world.add_child(craft.group)
		var length := float(vehicle.stages[0].L)
		var radius := float(vehicle.stages[0].D) * .5
		lights[0].directional_shadow_max_distance = maxf(14.0,length*2.5)
		var shots: Array
		match key:
			"discovery":
				shots = [[Vector3(0,length*.5,0),Vector3(.96,.32,.55)*length,.64,38.0],
					[Vector3(0,length-radius,0),Vector3(-1.3,2.35,.72)*radius,.34,48.0]]
			"evapod":
				shots = [[Vector3(0,1.04,0),Vector3(2.7,1.0,4.25),.80,38.0],["cabin"],["detail"]]
			"endurance":
				light_forward_face(lights)
				var hub := Vector3(0,float(vehicle.stages[0].look.ring.at),0)
				shots = [[hub,Vector3(30,-76,-45),.40,45.0],
					[hub+Vector3(0,-4,0),Vector3(17,-29,-33),.45,42.0]]
			"ranger":
				shots = [[Vector3(0,length*.47,0),Vector3(.80,.83,.45)*length,.80,39.0],["cabin"],["detail"]]
			"lander":
				shots = [[Vector3(0,length*.46,0),Vector3(24,24,13),.65,46.0],
					[Vector3(0,2,-.5),Vector3(13,-18,9),.50,44.0],
					[Vector3(0,4.3,1.4),Vector3(4,-3,6),.48,46.0]]
		for shot: Array in shots:
			var inside := shot.size() == 1
			var count := 144 if inside else 96
			if inside:
				cabin.set_enabled(true,craft,vehicle)
				cabin.light_windows(lights[0],lights[1])
			for i in count:
				var u := smoothstep(0,1,float(i)/(count-1))
				var time := float(number)/24
				var pod: bool = key == "evapod"
				var up := Vector3.UP if pod else Vector3.BACK
				var deploy_key := str(vehicle.stages[0].key)
				craft.update({"dt":1.0/24,"properTime":time, "deploy":{deploy_key:u if pod else 1.0}})
				if inside:
					if shot[0] == "detail":
						if pod:
							cam.position = Vector3(.04,1.36,-.25)
							cam.look_at(Vector3(-.70+.38*u,.90,.53),up)
						else:
							cam.position = Vector3(-.28+.23*u,6.64,.73)
							cam.look_at(Vector3(.20,8.54,.42),up)
						cam.fov = 62
					elif pod:
						cam.position = Vector3(0,1.34,-.30)
						cam.look_at(cam.position+Vector3(-.72+.98*u,-.18,.85),up)
						cam.fov = 82
					else:
						cam.position = Vector3(-.20-.47*u,5.8+1.22*u,.97)
						cam.look_at(Vector3(.28,9.8,.62),up)
						cam.fov = 78
				else:
					var target: Vector3 = shot[0]
					var offset: Vector3 = shot[1]
					var orbit_axis := Vector3.UP if key in ["evapod","endurance"] else Vector3.BACK
					cam.position = target+offset.rotated(orbit_axis,float(shot[2])*(u-.5))
					cam.look_at(target,up)
					cam.fov = shot[3]
				if i == 0:
					for settle in 4: await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				var path := output.path_join("%05d.jpg" % number)
				if composite.get_texture().get_image().save_jpg(path,.94) != OK:
					printerr("MOVIECRAFTSHOTS could not save ",path)
					get_tree().quit(1)
					return
				number += 1
			cabin.dispose()
		craft.group.queue_free()
		if key == "endurance":
			lights[0].basis = key_basis
			lights[1].basis = fill_basis
			lights[1].light_energy = fill_energy
		await get_tree().process_frame
	CraftAssets.clear()
	print("MOVIECRAFTSHOTS TOUR DONE frames=",number)
	get_tree().quit()
