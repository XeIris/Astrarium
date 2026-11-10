extends SceneTree

var checks := 0
var failures := 0

func expect(ok: bool, label: String) -> void:
	checks+=1
	if not ok:
		failures+=1
		printerr("RANGERCHECK FAIL ",label)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var authored := not OS.get_cmdline_user_args().has("assets=0")
	if authored: CraftAssets.craft_models_ready(["ranger"])
	var vehicle: Dictionary=Vehicles.get_vehicle("ranger")
	var original: Dictionary=vehicle.duplicate(true)
	var craft=CraftModel.build_craft(vehicle); root.add_child(craft.group)
	expect(craft.authored==authored,"requested authored/fallback build path")
	var st=craft.stage("ranger")
	expect(st.parts.legs.size()==3 and st.parts.flaps.size()==7 and st.parts.gimbals.size()==2,"complete separate driven parts")
	if st.parts.legs.size()!=3:
		craft.group.free(); CraftAssets.clear(); quit(1); return
	var bounds:=CraftModel.measure(craft.group)
	expect(absf(bounds.size.y-17.9)<.02 and absf(bounds.position.y)<.02,"shared nose and engine-exit datums")
	for i in range(41):
		var t:=i/40.0
		st.gear=t
		craft.update({"dt":0.0,"gear":{"ranger":t},"flap":[.1,-.1,.2,-.2,.1,-.15,.15]})
		for j in 3:
			var leg: Node3D=st.parts.legs[j]
			var tip: Vector3=craft.group.to_local(leg.to_global(Vector3(.98,0,0)))
			var pivot: Vector3=craft.group.to_local(leg.global_position)
			expect(absf(tip.distance_to(pivot)-.98)<1e-4,"gear strut stays attached through full sweep")
			var expected:=pivot+Vector3(0,.98*cos(t*PI/2),-.98*sin(t*PI/2))
			expect(tip.distance_to(expected)<.001,"gear follows the intended local hinge axis")
			for point: Vector3 in points(leg,craft.group):
				if point.z<-.2 and point.z>-.8:
					expect(absf(point.x-pivot.x)<.48 and point.y>pivot.y-.35 and point.y<pivot.y+1.35,"gear crosses skin only inside its own bay")
			if i==40:
				var min_z:=INF
				for point: Vector3 in points(leg,craft.group): min_z=minf(min_z,point.z)
				expect(absf(min_z-float(st.spec.gear.point[2]))<.015,"tyre contact matches the physics ground point")
	var cabin:=CraftInterior.new()
	var e: Array=vehicle.interior.eye
	var eye:=Vector3(e[0],e[1],e[2])
	expect(blocked(craft.group,eye,Vector3.UP),"opaque window shade in exterior mode")
	for round_ in range(5):
		cabin.set_enabled(true,craft,vehicle)
		expect(cabin.group!=null and cabin.authored==authored,"lazy cabin build path")
		var one:=cabin.group
		cabin.set_enabled(true,craft,vehicle)
		expect(cabin.group==one,"repeated entry reuses one cabin")
		expect(not blocked(craft.group,eye,Vector3.UP),"pilot has an open forward sightline")
		if round_==0 and authored:
			expect(cabin.group.find_children("interior_light_*","Node3D",true,false).size()==6,"six anchored cabin fixtures")
			var finishes: Dictionary={}
			collect_finishes(craft.group,finishes)
			for key in ["surveyThermal","surveyCarbon","surveyLiner","surveyWebbing","surveySeat"]:
				expect(finishes.has(key),"distinct authored finish "+key)
		cabin.dispose(); await process_frame
		expect(cabin.group==null,"camera exit releases cabin")
	expect(vehicle==original,"poses and camera entry preserve vehicle metadata")
	var camera:=LocalView.create_flight_camera(); camera.set_mode("interior")
	var cb:=Basis.from_euler(Vector3(.7,-.3,1.2))
	var position:=DVec3.new(4e9,7e9,-2e9)
	camera.update({"craftPos":position,"craftBasis":cb,"length":17.9,"up":Vector3.UP,"dt":0.0,"interior":vehicle.interior})
	expect(camera.pos.sub(position).to_v3().distance_to(cb*eye)<1e-5,"pilot eye follows double-precision vessel position")
	expect((-camera.basis.z).dot(cb*Vector3.UP)>.9999 and camera.basis.y.dot(cb*Vector3.BACK)>.9999,"camera uses the cabin forward/up frame")
	camera.state.interiorYaw=PI/2
	camera.update({"craftPos":position,"craftBasis":cb,"length":17.9,"up":Vector3.UP,"dt":0.0,"interior":vehicle.interior})
	expect((-camera.basis.z).dot(cb*Vector3.LEFT)>.9999,"look yaw turns about cabin vertical")
	craft.group.free(); CraftAssets.clear(); await process_frame
	print("RANGERCHECK DONE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)

func points(node: Node, relative: Node3D) -> Array[Vector3]:
	var out: Array[Vector3]=[]
	if node is MeshInstance3D and node.mesh!=null:
		var xf: Transform3D=relative.global_transform.affine_inverse()*node.global_transform
		for s in node.mesh.get_surface_count():
			for p: Vector3 in node.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]: out.append(xf*p)
	for child in node.get_children(): out.append_array(points(child,relative))
	return out

func blocked(node: Node, eye: Vector3, direction: Vector3) -> bool:
	if node is Node3D and not node.visible: return false
	if node is MeshInstance3D and node.mesh!=null:
		var inverse: Transform3D=node.global_transform.affine_inverse()
		var origin:=inverse*eye; var dir:=inverse.basis*direction
		for s in node.mesh.get_surface_count():
			var arr: Array=node.mesh.surface_get_arrays(s)
			var vs: PackedVector3Array=arr[Mesh.ARRAY_VERTEX]
			var ix: PackedInt32Array=arr[Mesh.ARRAY_INDEX]
			for i in range(0,ix.size(),3):
				var hit=Geometry3D.ray_intersects_triangle(origin,dir,vs[ix[i]],vs[ix[i+1]],vs[ix[i+2]])
				if hit!=null and (hit as Vector3).distance_to(origin)<5: return true
	for child in node.get_children():
		if blocked(child,eye,direction): return true
	return false

func collect_finishes(node: Node, found: Dictionary) -> void:
	if node is MeshInstance3D and node.mesh!=null:
		for s in node.mesh.get_surface_count():
			var mat: StandardMaterial3D=node.mesh.surface_get_material(s)
			if mat==null or not mat.resource_name.begins_with("survey"): continue
			found[mat.resource_name.get_slice(".",0)]=mat
			if mat.normal_enabled:
				var a: Array=node.mesh.surface_get_arrays(s)
				expect(mat.normal_texture!=null and mat.roughness_texture!=null,"embedded finish maps survive import")
				expect(a[Mesh.ARRAY_TEX_UV]!=null and a[Mesh.ARRAY_TANGENT]!=null,"mapped finish has UVs and tangent frames")
	for child in node.get_children(): collect_finishes(child,found)
