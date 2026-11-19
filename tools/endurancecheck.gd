extends SceneTree

var checks:=0
var failures:=0

func expect(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;printerr("ENDURANCECHECK FAIL ",label)

func _initialize() -> void:run.call_deferred()

func run() -> void:
	var authored:=not OS.get_cmdline_user_args().has("assets=0")
	if authored:CraftAssets.craft_models_ready(["endurance"])
	var vehicle: Dictionary=Vehicles.get_vehicle("endurance")
	var craft=CraftModel.build_craft(vehicle)
	get_root().add_child(craft.group)
	var st=craft.stages[0]
	expect(craft.authored==authored,"requested asset path is available")
	expect(st.parts.rotors.size()==1 and st.parts.gimbals.size()==12,"whole ring rotor and twelve independently driven outlets bind")
	for i in 12:expect(craft.group.find_child("inspection_module_%d"%i,true,false)!=null,"attached module %d"%i)
	var berths := EnduranceCraft.berths(st.spec)
	expect(berths.size()==4,"full complement has four mounts")
	for kind in ["ranger","lander"]:
		var mounts: Array = craft.group.find_children("dock_%s_*"%kind,"Node3D",true,false)
		expect(mounts.size()==2,"two %s transports aboard"%kind)
	for berth: Dictionary in berths:
		var mounted:=craft.group.find_child(berth.node,true,false) as Node3D
		var expected:=Vector3(berth.at[0],berth.at[1],berth.at[2])
		var q := Quaternion(berth.q[0],berth.q[1],berth.q[2],berth.q[3])
		expect(mounted!=null and mounted.position.distance_to(expected)<.001 and mounted.quaternion.angle_to(q)<.001,"%s matches its transport pose"%berth.node)
		if mounted == null: continue
		var side := 1.0 if str(berth.node).ends_with("_0") else -1.0
		if berth.vehicle == "ranger":
			expect(mounted.basis.y.dot(Vector3.DOWN)>.999 and mounted.basis.z.x*side>.999,
				"Ranger bows project forward together, with opposed bellies")
		else:
			expect(absf(mounted.basis.y.y)<.001 and mounted.basis.z.z*side<-.99,
				"Lander long axes lie in the wheel with dorsal ports facing inward")
		var sweep := preload("res://tools/dockingclearance.gd").new(mounted,craft.group)
		sweep.carrier.assign(sweep.carrier.filter(func(n): return not mounted.is_ancestor_of(n)))
		expect(not sweep.visitor.is_empty(),"visible ship at "+str(berth.node))
		var crossing := sweep.interference()
		expect(crossing == "", "%s stowed interference: %s" % [berth.node,crossing])
	var rotation: Node3D=st.parts.rotors[0]
	craft.update({"dt":1.0,"properTime":0.0})
	var first:=rotation.quaternion
	var nozzle: Node3D=st.parts.gimbals[0]
	var origin: Vector3=craft.group.global_transform.affine_inverse()*nozzle.global_position
	craft.update({"dt":1.0,"properTime":3.0})
	expect(absf(rotation.quaternion.angle_to(first)-PI*.5)<1e-5,"three proper seconds turns the 5 rpm ring through 90 degrees")
	var end: Vector3=craft.group.global_transform.affine_inverse()*nozzle.global_position
	expect(absf(Vector2(end.x,end.z).length()-Vector2(origin.x,origin.z).length())<1e-4 and absf(end.y-origin.y)<1e-4,"engines remain attached while the ring spins")
	craft.update({"dt":30.0,"properTime":3.0})
	expect((craft.group.global_transform.affine_inverse()*nozzle.global_position).distance_to(end)<1e-5,"render time cannot advance the ring")
	var habitat:=Centrifuge.state(vehicle.stages[0].centrifuge,3.0)
	expect(absf(habitat.gravity-pow(TAU*5.0/60.0,2)*30.5)<1e-9,"floor gravity uses measured radius and authored spin")
	expect(habitat.gees>.85 and habitat.gees<.86,"5 rpm is reported as about 0.85 g")
	expect(not habitat.momentumCoupled,"prescribed-spin angular momentum omission is explicit")
	var low:=INF;var high:=-INF;var extent:=0.0
	var spoke_gap:=INF
	var members:=EnduranceCraft.spokes(st.spec)
	var support:=rotation.find_child("inspection_spokes",true,false)
	expect(members.size()==1 and support!=null,"one radial pressure tunnel rotates with the ring")
	for node in craft.group.find_children("*","MeshInstance3D",true,false):
		var on_transport := false
		var parent: Node = node.get_parent()
		while parent != rotation and parent != null:
			if str(parent.name).begins_with("dock_"): on_transport = true; break
			parent = parent.get_parent()
		for surface in node.mesh.get_surface_count():
			var arrays: Array=node.mesh.surface_get_arrays(surface)
			var xf: Transform3D=craft.group.global_transform.affine_inverse()*node.global_transform
			if on_transport:
				var to_rotor: Transform3D=rotation.global_transform.affine_inverse()*node.global_transform
				spoke_gap=minf(spoke_gap,member_clearance(arrays,to_rotor,members))
			for point: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
				point=xf*point
				var radial:=Vector2(point.x,point.z).length()
				low=minf(low,point.y);high=maxf(high,point.y);extent=maxf(extent,radial)
	expect(is_finite(spoke_gap) and spoke_gap>.04,"transports clear the radial pressure tunnel (%.3f m)"%spoke_gap)
	expect(low>=-.02 and high<=float(vehicle.stages[0].L)+.02,"all attached geometry respects the axial envelope (%.3f to %.3f)"%[low,high])
	expect(extent<=float(vehicle.stages[0].D)*.5+.02,"modules and details stay inside the 65 m envelope")
	craft.group.free();CraftAssets.clear();await process_frame
	print("ENDURANCECHECK DONE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)

func member_clearance(arrays: Array,xf: Transform3D,members: Array) -> float:
	var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX].duplicate()
	var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
	for i in vertices.size():vertices[i]=xf*vertices[i]
	var closest:=INF
	for member: Dictionary in members:
		var a: Vector3=member.start;var b: Vector3=member.end
		var radius:=float(member.flangeRadius)
		for i in range(0,indices.size(),3):
			var p:=vertices[indices[i]];var q:=vertices[indices[i+1]];var r:=vertices[indices[i+2]]
			if Geometry3D.segment_intersects_triangle(a,b,p,q,r)!=null:return -radius
			for edge: Array in [[p,q],[q,r],[r,p]]:
				var pair:=Geometry3D.get_closest_points_between_segments(a,b,edge[0],edge[1])
				closest=minf(closest,pair[0].distance_to(pair[1])-radius)
	return closest
