extends SceneTree

var checks := 0
var failures := 0
func expect(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("EVAPODCHECK FAIL ", label)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var authored := not OS.get_cmdline_user_args().has("assets=0")
	if authored: CraftAssets.craft_models_ready(["evapod"])
	var vehicle: Dictionary = Vehicles.get_vehicle("evapod")
	var craft = CraftModel.build_craft(vehicle)
	root.add_child(craft.group)
	expect(craft.authored == authored, "requested build path available")
	var st = craft.stage("pod")
	var eye_values: Array = vehicle.interior.eye
	var eye := Vector3(eye_values[0],eye_values[1],eye_values[2])
	expect(st.parts.arms.size() == 8, "two shoulders, elbows and paired claws")
	if st.parts.arms.size() != 8:
		craft.group.free(); CraftAssets.clear(); quit(1); return
	var original: Dictionary = vehicle.duplicate(true)
	if OS.get_cmdline_user_args().has("inject_intrusion=1"):
		(st.parts.arms[0] as Node3D).position.z -= 0.4
	for joint: Node3D in st.parts.arms:
		expect(joint.quaternion.angle_to(Quaternion.IDENTITY) < 1e-5,"identity rest rotation")
	for i in range(41):
		var t := i/40.0
		EvaPod.pose(st.parts.arms,t)
		for offset in [0,4]:
			var shoulder: Node3D = st.parts.arms[offset]
			var elbow: Node3D = st.parts.arms[offset+1]
			var jaw: Node3D = st.parts.arms[offset+2]
			expect(shoulder.is_ancestor_of(elbow) and elbow.is_ancestor_of(jaw),"nested moving joints")
			var elbow_at: Vector3 = craft.group.to_local(elbow.global_position)
			var shoulder_at: Vector3 = craft.group.to_local(shoulder.global_position)
			expect(absf(elbow_at.distance_to(shoulder_at)-.36)<.001,"upper link stays connected")
			var wrist: Vector3 = craft.group.to_local(elbow.to_global(Vector3(0,.40,0)))
			var expected: Vector3 = shoulder_at+Vector3(0,.36*cos(deg_to_rad(68)*t),.36*sin(deg_to_rad(68)*t))+Vector3(0,.40*cos(deg_to_rad(86)*t),.40*sin(deg_to_rad(86)*t))
			expect(wrist.distance_to(expected)<.001,"wrist follows the commanded joint chain")
			var left_edge := -INF
			var right_edge := INF
			for p: Vector3 in mesh_points(st.parts.arms[offset+2]): left_edge=maxf(left_edge,p.x)
			for p: Vector3 in mesh_points(st.parts.arms[offset+3]): right_edge=minf(right_edge,p.x)
			expect(right_edge-left_edge>.015,"paired claws remain separated throughout opening")
			# All moving skin must clear the pressure sphere, including intermediate poses.
			var points := mesh_points(shoulder)
			var gap := INF
			for p: Vector3 in points:
				var local: Vector3 = craft.group.to_local(p)
				gap=minf(gap,local.distance_to(Vector3(0,1.03,0))-1.03)
			expect(gap > .015,"moving links clear hull at %.3f (gap %.4f m)" % [t,gap])
	EvaPod.pose(st.parts.arms,0)
	for joint: Node3D in st.parts.arms:
		expect(joint.quaternion.angle_to(Quaternion.IDENTITY)<1e-5,"repeatable parked pose")
	expect(vehicle==original,"visual articulation preserves vehicle specification")
	var cabin := CraftInterior.new()
	if authored: material_probes(craft.group, ["podWhite", "podAluminium", "podSteel", "podSeal"])
	expect(cabin.group==null,"interior absent before entry")
	expect(blocks_window(craft.group,eye),"exterior window has an opaque cabin shade")
	for round_ in range(6):
		cabin.set_enabled(true,craft,vehicle)
		expect(cabin.group!=null and cabin.authored==authored,"interior build path")
		var one := cabin.group
		if round_ == 0 and authored:
			material_probes(cabin.group, ["podRed", "podPanel", "podPad", "podWebbing", "podFloor"])
			var anchors := cabin.group.find_children("interior_light_*", "Node3D", true, false)
			expect(anchors.size() == 5, "five authored recessed light positions")
			var intrusion := exterior_intrusion(st.group, cabin.group)
			expect(intrusion >= .98, "opaque exterior skin stays outside cabin: %.5f m" % intrusion)
		cabin.set_enabled(true,craft,vehicle)
		expect(cabin.group==one,"entry is idempotent")
		var shade := st.group.find_child("window_shade",true,false) as Node3D
		expect(shade!=null and not shade.visible,"exterior shade removed on entry")
		expect(not blocks_window(craft.group,eye),"forward sightline leaves cabin through opening")
		var b := CraftModel.measure(cabin.group)
		expect(b.position.y>=0 and b.end.y<2.06 and b.size.x<2.06,"interior fits exterior datums")
		cabin.dispose()
		await process_frame
		expect(cabin.group==null and shade.visible,"exit releases cabin and restores shade")
	var camera := LocalView.create_flight_camera()
	camera.set_mode("interior")
	var cb := Basis.from_euler(Vector3(.7,-.3,1.2))
	var pos := DVec3.new(4e9,7e9,-2e9)
	camera.update({"craftPos":pos,"craftBasis":cb,"length":2.06,"up":Vector3.UP,"dt":0.0,"interior":vehicle.interior})
	expect(camera.pos.sub(pos).to_v3().distance_to(cb*eye)<1e-5,"interior eye tracks in double through vehicle attitude")
	expect((-camera.basis.z).distance_to(cb*Vector3.BACK)<1e-5 and camera.near==.01,"window direction and near plane")
	craft.group.free(); CraftAssets.clear()
	await process_frame
	print("EVAPODCHECK DONE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures else 0)

func material_probes(node: Node, required: Array) -> void:
	var materials := {}
	collect_materials(node, materials)
	for name_: String in required:
		var mat: StandardMaterial3D = materials.get(name_)
		expect(mat != null, "authored finish " + name_)
		if mat == null: continue
		expect(mat.normal_enabled and mat.normal_texture != null and mat.roughness_texture != null,
			name_ + " retains embedded normal and roughness maps")
		expect(mat.metallic <= 0.4, name_ + " remains readable without reflected environment")

func collect_materials(node: Node, materials: Dictionary) -> void:
	if node is MeshInstance3D and node.mesh != null:
		for s in node.mesh.get_surface_count():
			var mat: StandardMaterial3D = node.mesh.surface_get_material(s)
			if mat == null: continue
			materials[mat.resource_name.get_slice(".",0)] = mat
			if mat.normal_enabled:
				var arrays: Array = node.mesh.surface_get_arrays(s)
				expect(arrays[Mesh.ARRAY_TEX_UV] != null and not arrays[Mesh.ARRAY_TEX_UV].is_empty(),
					"normal-mapped surface has authored UVs")
				var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var orthogonal := 0
				if tangents.size() == normals.size()*4:
					for i in normals.size():
						var t := Vector3(tangents[i*4],tangents[i*4+1],tangents[i*4+2])
						if absf(normals[i].dot(t)) < .03 and t.length() > .9: orthogonal += 1
				expect(orthogonal >= normals.size()*.98, "normal-map tangent frames survive export")
	for child in node.get_children(): collect_materials(child, materials)

func mesh_points(node: Node) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if node is MeshInstance3D and node.mesh!=null:
		for s in node.mesh.get_surface_count():
			var a: Array = node.mesh.surface_get_arrays(s)
			for v: Vector3 in a[Mesh.ARRAY_VERTEX]: out.append(node.global_transform*v)
	for child in node.get_children(): out.append_array(mesh_points(child))
	return out

func blocks_window(node: Node, eye: Vector3) -> bool:
	if node is MeshInstance3D and node.is_visible_in_tree() and node.mesh!=null:
		var inv: Transform3D = node.global_transform.affine_inverse()
		var a: Vector3 = inv*eye
		var b: Vector3 = inv*(eye+Vector3(0,0,3))
		for s in node.mesh.get_surface_count():
			var arr: Array = node.mesh.surface_get_arrays(s)
			var vertices: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			for i in range(0,indices.size(),3):
				if Geometry3D.segment_intersects_triangle(a,b,vertices[indices[i]],vertices[indices[i+1]],vertices[indices[i+2]])!=null: return true
	for child in node.get_children():
		if blocks_window(child,eye): return true
	return false

func exterior_intrusion(node: Node, cabin: Node) -> float:
	if node == cabin or (node is Node3D and not node.is_visible_in_tree()): return INF
	var closest := INF
	if node is MeshInstance3D:
		for s in node.mesh.get_surface_count():
			var mat: Material = node.mesh.surface_get_material(s)
			if mat == null or mat.resource_name.get_slice(".",0) != "podWhite": continue
			var arrays: Array = node.mesh.surface_get_arrays(s)
			for v: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
				var p: Vector3 = node.global_transform*v
				# The boarding step occupies the rear sill below the footrest plane.
				var rear_sill := p.y < .38 and p.z < -.55
				if p.y > .25 and p.z > -.70 and not rear_sill:
					closest=minf(closest,p.distance_to(Vector3(0,1.03,0)))
	for child in node.get_children(): closest=minf(closest,exterior_intrusion(child,cabin))
	return closest
