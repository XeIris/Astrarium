extends SceneTree

var checks:=0
var failures:=0

func expect(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;printerr("DISCOVERYCHECK FAIL ",label)

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var authored:=not OS.get_cmdline_user_args().has("assets=0")
	if authored:CraftAssets.craft_models_ready(["discovery"])
	var vehicle: Dictionary=Vehicles.get_vehicle("discovery")
	var original: Dictionary=vehicle.duplicate(true)
	var craft=CraftModel.build_craft(vehicle);root.add_child(craft.group)
	expect(craft.authored==authored,"requested build path")
	var st=craft.stages[0]
	expect(st.parts.rotors.size()==1 and st.parts.doors.size()==3 and st.parts.gimbals.size()==3,"complete rotor, bay and drive rig")
	var b:=CraftModel.measure(craft.group)
	expect(absf(b.position.y)<.02 and absf(b.end.y-float(st.spec.L))<.02,"common engine exit and bow datums: %s"%b)
	check_stern(craft.group,st)
	expect(craft.group.find_children("dock_pod_*","Node3D",true,false).size()==3,"three berthed EVA pods")
	var center:=Vector3(0,float(st.spec.L)-float(st.spec.D)*.5-float(st.spec.look.noseSealAllowance),0)
	var radius:=float(st.spec.D)*.5
	var opening:=float(st.spec.look.bayRadius)-.013
	for i in 3:
		var pod:=craft.group.find_child("dock_pod_%d"%i,true,false) as Node3D
		var clearance:=INF
		for point: Vector3 in points(pod,craft.group):
			var h2:=radius*radius-point.x*point.x-point.z*point.z
			if h2<=0.0:continue
			var shell_y:=center.y+sqrt(h2)
			if point.y<=shell_y and point.y+6.0>=shell_y:
				var centerline:=Vector2((i-1)*float(st.spec.look.baySpacing),float(st.spec.look.bayZ))
				clearance=minf(clearance,opening-Vector2(point.x,point.z).distance_to(centerline))
		expect(is_finite(clearance) and clearance>.02,"pod %d translation fits its circular aperture: %.3f m"%[i,clearance])
	if authored:
		var furniture: Array=craft.group.find_children("inspection_berth_*","Node3D",true,false)
		expect(furniture.size()==3,"three separately inspectable berth structures")
		for assembly in furniture:
			var farthest:=0.0
			for point in points(assembly,craft.group):farthest=maxf(farthest,point.distance_to(center))
			expect(farthest<float(st.spec.D)*.5-.10,"berth furniture stays inside pressure skin: %.4f m"%farthest)
	for i in range(41):
		st.deploy=i/40.0
		craft.update({"dt":0.0,"properTime":i*.25})
		var worst:=INF
		for door: Node3D in st.parts.doors:
			for point: Vector3 in points(door,craft.group,"surveyEnamel" if authored else ""): worst=minf(worst,point.distance_to(center))
		expect(worst>float(st.spec.D)*.5+.025,"moving hatches clear pressure skin at %.3f (r %.3f)"%[st.deploy,worst])
	var cover_gap:=INF
	for door: Node3D in st.parts.doors:
		for point: Vector3 in points(door,craft.group):
			if point.y<=center.y:continue
			for i in 3:
				var axis:=Vector2((i-1)*float(st.spec.look.baySpacing),float(st.spec.look.bayZ))
				cover_gap=minf(cover_gap,Vector2(point.x,point.z).distance_to(axis)-opening)
	# A cover can pass over an adjacent opening on its track; the open pose
	# must leave the entire approach cylinder clear for every pod.
	expect(cover_gap>.02,"fully open covers clear all bay approaches (%.3f m)"%cover_gap)
	var rotor: Node3D=st.parts.rotors[0]
	craft.update({"dt":0.0,"properTime":1.0})
	var pose:=rotor.transform
	craft.update({"dt":10.0,"properTime":1.0})
	expect(rotor.transform.is_equal_approx(pose),"paused proper time freezes rotor despite display frames")
	craft.update({"dt":0.0,"properTime":8.5})
	expect(rotor.transform.is_equal_approx(pose),"8 rpm rotor repeats after a 7.5 second period")
	var occupied:=0.0
	for point: Vector3 in points(rotor,craft.group):occupied=maxf(occupied,point.distance_to(center))
	expect(occupied<float(st.spec.D)*.5-.08,"rotor skin stays inside pressure sphere through spin")
	var known:=Centrifuge.state({"radius":10.0,"rpm":6.0,"walkSpeed":1.0},1.0)
	expect(absf(known.gravity-3.9478417604)<1e-8,"artificial gravity against independent 10 m / 6 rpm value")
	expect(absf(known.coriolisRatio-.3183098862)<1e-8,"Coriolis-to-gravity ratio for a 1 m/s walker")
	expect(not known.momentumCoupled,"gyroscopic omission is explicit telemetry")
	var empty:=Centrifuge.state({"radius":10.0,"rpm":0.0},1.0)
	expect(empty.gravity==0.0 and is_nan(empty.coriolisRatio),"stopped rotor reports unavailable ratio")
	expect(vehicle==original,"articulation preserves shared metadata")
	var worlds: Array=Presets.PRESETS.jovian_voyage.build.call()
	var solar: Array=Presets.PRESETS.solar.build.call()
	for reference: Dictionary in solar:
		if reference.name!="Jupiter":continue
		var resolved:=JovianMoons.system(reference)
		var total:=0.0
		for body: Dictionary in resolved:total+=float(body.mass)
		expect(absf(total-float(reference.mass))<1e-15,"resolved Jovian mass equals the original system mass")
		for field in ["pos","vel"]:
			var worst:=0.0
			for axis in 3:
				var barycenter:=0.0
				for body: Dictionary in resolved:barycenter+=float(body.mass)/total*float(body[field][axis])
				worst=maxf(worst,absf(barycenter-float(reference[field][axis])))
			expect(worst<1e-12,"Jovian barycentre preserves "+field)
	var jupiter: Dictionary={}
	for world: Dictionary in worlds:
		if world.name=="Jupiter":jupiter=world
	var pole: Array=Rocketry.POLES.Jupiter
	var normal:=Rocketry.equatorial_dir(deg_to_rad(pole[0]),deg_to_rad(pole[1]))
	for row: Array in JovianMoons.DATA:
		var found:=false
		for world: Dictionary in worlds:
			if world.name!=row[0]:continue
			found=true
			var r:=DVec3.new(world.pos[0]-jupiter.pos[0],world.pos[1]-jupiter.pos[1],world.pos[2]-jupiter.pos[2])
			var v:=DVec3.new(world.vel[0]-jupiter.vel[0],world.vel[1]-jupiter.vel[1],world.vel[2]-jupiter.vel[2])
			expect(absf(r.length()/Physics.AU_PER_KM-float(row[1]))<.001,"moon orbital radius: "+str(row[0]))
			expect(absf(r.dot(normal))/r.length()<1e-10,"moon plane agrees with Jupiter's figure")
			expect(absf(r.dot(v))/(r.length()*v.length())<1e-10,"circular moon velocity is tangential")
			expect(world.pN2==0.0 and world.pCO2==0.0,"moon has no invented continuum air column")
		expect(found,"voyage includes "+str(row[0]))
	craft.group.free();CraftAssets.clear();await process_frame
	print("DISCOVERYCHECK DONE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)

func check_stern(group: Node3D,st) -> void:
	for i in 3:
		var dish:=group.find_child("inspection_antenna_%d"%i,true,false) as Node3D
		var feed:=group.find_child("inspection_feed_%d"%i,true,false) as Node3D
		expect(dish!=null and feed!=null,"dish %d has a reflector and feed"%i)
		if dish!=null and feed!=null:
			var axis:=group.to_local(feed.global_position)-group.to_local(dish.global_position)
			expect(axis.normalized().dot(Vector3.DOWN)>.999,"dish %d faces aft"%i)
		var neck:=group.find_child("inspection_drive_neck_%d"%i,true,false)
		expect(neck!=null,"drive %d has a fixed reactor duct"%i)
		if neck==null or i>=st.parts.gimbals.size(): continue
		var near_end:=INF
		var far_end:=-INF
		for point: Vector3 in points(neck,group):
			near_end=minf(near_end,point.y)
			far_end=maxf(far_end,point.y)
		expect(absf(near_end-4.20)<.03 and far_end>float(st.spec.look.reactorAft),
			"drive %d duct joins the bell and reactor (%.2f–%.2f m)"%[i,near_end,far_end])
		var bell: Node3D=st.parts.gimbals[i]
		var rest:=bell.quaternion
		var limit:=deg_to_rad(float(bell.get_meta("gimbal_deg",0.0)))
		for axis: Vector3 in [Vector3.RIGHT,Vector3.BACK]:
			for sign_: float in [-1.0,1.0]:
				bell.quaternion=rest*Quaternion(axis,sign_*limit)
				var reach:=-INF
				for point: Vector3 in points(bell,group):reach=maxf(reach,point.y)
				expect(reach>near_end+.10,"drive %d still overlaps its duct at full gimbal"%i)
		bell.quaternion=rest

func points(node: Node,relative: Node3D,finish_name:="") -> Array[Vector3]:
	var out: Array[Vector3]=[]
	if node is MeshInstance3D and node.mesh!=null:
		var xf: Transform3D=relative.global_transform.affine_inverse()*node.global_transform
		for s in node.mesh.get_surface_count():
			if finish_name!="" and not str(node.mesh.surface_get_material(s).resource_name).begins_with(finish_name):continue
			var a: Array=node.mesh.surface_get_arrays(s)
			var vertices: PackedVector3Array=a[Mesh.ARRAY_VERTEX]
			for p: Vector3 in vertices:out.append(xf*p)
			var indices: PackedInt32Array=a[Mesh.ARRAY_INDEX]
			for i in range(0,indices.size(),3):
				out.append(xf*((vertices[indices[i]]+vertices[indices[i+1]]+vertices[indices[i+2]])/3.0))
	for child in node.get_children():out.append_array(points(child,relative,finish_name))
	return out
