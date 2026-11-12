class_name DiscoveryCraft
extends RefCounted

static func berths(spec: Dictionary) -> Array:
	var radius:=float(spec.D)*.5
	var center:=float(spec.L)-radius-float(spec.look.noseSealAllowance)
	var out:=[]
	for i in 3:
		var x: float=(i-1)*float(spec.look.baySpacing)
		var z:=float(spec.look.bayZ)
		var y:=center+sqrt(radius*radius-x*x-z*z)-2.15
		out.append({"vehicle":"evapod","node":"dock_pod_%d"%i,"at":[x,y,-2.82],
			"q":[0.0,sqrt(.5),sqrt(.5),0.0]})
	return out

static func dishes(spec: Dictionary) -> Array:
	var y:=float(spec.look.antennaAt)
	return [{"at":[0.0,y,5.9],"radius":2.3},{"at":[-3.0,y,5.9],"radius":.85},
		{"at":[3.0,y,5.9],"radius":.85}]

static func build(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var root:=Node3D.new()
	var m:=CraftModel.craft_materials()
	var length:=float(spec.L); var radius:=float(spec.D)*.5
	var center:=length-radius-float(spec.look.noseSealAllowance)
	var bay_radius:=float(spec.look.bayRadius)
	var bay_spacing:=float(spec.look.baySpacing)
	var bay_z:=float(spec.look.bayZ)
	var skin:=CraftModel.Geo.new()
	for j in range(97):
		var lat:=PI*j/96.0
		for i in range(193):
			var a:=TAU*i/192.0
			var normal:=Vector3(sin(lat)*sin(a),cos(lat),sin(lat)*cos(a))
			skin.pos.append(normal*radius+Vector3(0,center,0)); skin.nrm.append(normal)
	for j in 96:
		for i in 192:
			var k:=j*193+i
			var point: Vector3=(skin.pos[k]+skin.pos[k+1]+skin.pos[k+193]+skin.pos[k+194])*.25
			var opening:=false
			if point.y>center+radius*.4:
				opening=absf(point.x)<radius*.615 and absf(point.z-radius*.29)<.25
				for bay in 3:
					# The coarse shell cuts by cell centre. Leave room for the
					# half-cell step along the opening's inner edge.
					if Vector2(point.x-(bay-1)*bay_spacing,point.z-bay_z).length()<bay_radius+.10: opening=true
			if not opening: skin.idx.append_array(PackedInt32Array([k,k+1,k+193,k+1,k+194,k+193]))
	root.add_child(CraftModel._mesh(skin,m.white))
	var aft:=float(spec.look.reactorAft)
	var fore:=float(spec.look.reactorFore)
	EvaPod._box(root,Vector3(0,(aft+fore)*.5,0),Vector3(radius*1.20,fore-aft,radius*.99),m.dirty)
	EvaPod._box(root,Vector3(0,(fore+center-radius)*.5,0),Vector3(.65,center-radius-fore,.65),m.steel)
	var modules:=int(spec.look.spineModules)
	for i in modules:
		var y:=lerpf(fore+3.5,center-radius-3,float(i)/(modules-1))
		for side in [-1,1]:
			EvaPod._box(root,Vector3(side*1.3,y,0),Vector3(2.2,3.5,2.7),m.white)
			EvaPod._box(root,Vector3(0,y,side*1.3),Vector3(2.7,3.5,2.2),m.white)
	for i in 3:
		var p:=Node3D.new(); root.add_child(p); parts.gimbals.append(p)
		p.position=Vector3((i-1)*2.65,0,0)
		var shape:=PackedVector2Array([Vector2(1.07,0),Vector2(1.18,.12),Vector2(1.17,1.25),
			Vector2(.87,3.20),Vector2(.53,4.38)])
		p.add_child(CraftModel._mesh(CraftModel._lathe(shape,6),m.white))
		for z in [-.48,.48]:
			var bell:=CraftModel._mesh(CraftModel._lathe(PackedVector2Array([
				Vector2(.40,.01),Vector2(.37,.36),Vector2(.19,2.2)]),32),m.nozzle)
			bell.position.z=z;p.add_child(bell)
		var neck:=CraftModel._mesh(CraftModel._cylinder(.49,.49,aft-3.95,24),m.steel)
		neck.name="inspection_drive_neck_%d"%i
		neck.position=Vector3(p.position.x,(aft+4.45)*.5,0);root.add_child(neck)
	var mast_y:=float(spec.look.antennaAt)
	var mast:=CraftModel._mesh(CraftModel._cylinder(.22,.28,4.1,24),m.steel)
	mast.position=Vector3(0,mast_y,3.86);mast.rotation.x=PI*.5;root.add_child(mast)
	for i in 3:
		var dish: Dictionary=dishes(spec)[i]
		var at: Array=dish.at
		var dish_root:=Node3D.new();dish_root.name="inspection_antenna_%d"%i
		dish_root.position=Vector3(at[0],at[1],at[2]);root.add_child(dish_root)
		var r:=float(dish.radius)
		var profile:=PackedVector2Array()
		for ring in range(9):
			var t:=float(ring)/8.0
			profile.append(Vector2(r*t,-r*.20*t*t))
		dish_root.add_child(CraftModel._mesh(CraftModel._lathe(profile,48),m.white))
		var feed:=Node3D.new();feed.name="inspection_feed_%d"%i
		feed.position.y=-r*.5;dish_root.add_child(feed)
		var boom:=CraftModel._mesh(CraftModel._cylinder(.035,.035,r*.5,8),m.steel)
		boom.position.y=-r*.25;dish_root.add_child(boom)
		if i>0:
			var bridge:=CraftModel._mesh(CraftModel._cylinder(.10,.10,3.02,12),m.steel)
			bridge.position=Vector3(at[0]*.5,mast_y+.045,5.87);bridge.rotation.z=PI*.5;root.add_child(bridge)
	for i in 3:
		var x: float=(i-1)*bay_spacing; var z:=bay_z
		var hinge:=Vector3(0,center,0)
		var mount:=Node3D.new(); root.add_child(mount); mount.position=hinge
		root.add_child(_seal(x,z,center,radius,bay_radius+.022,m.black))
		var door:=Node3D.new(); mount.add_child(door); parts.doors.append(door)
		var patch:=CraftModel.Geo.new()
		var middle:=Vector3(x,sqrt(radius*radius-x*x-z*z),z)*(1+.055/radius)
		patch.pos.append(middle);patch.nrm.append(middle.normalized())
		for band in range(1,6):
			for j in 64:
				var a:=TAU*j/64.0;var rr:=(bay_radius-.04)*band/5.0
				var xx:=x+rr*cos(a);var zz:=z+rr*sin(a)
				var point:=Vector3(xx,sqrt(radius*radius-xx*xx-zz*zz),zz)*(1+.055/radius)
				patch.pos.append(point);patch.nrm.append(point.normalized())
		for j in 64:patch.idx.append_array(PackedInt32Array([0,1+(j+1)%64,1+j]))
		for band in 4:
			for j in 64:
				var a:=1+band*64+j;var b_:=1+band*64+(j+1)%64
				patch.idx.append_array(PackedInt32Array([a,b_,b_+64,a,b_+64,a+64]))
		door.add_child(CraftModel._mesh(patch,m.white))
	var rotor:=Node3D.new(); root.add_child(rotor); parts.rotors.append(rotor)
	var at: Array=spec.centrifuge.at; rotor.position=Vector3(at[0],at[1],at[2])
	var torus:=CraftModel._mesh(CraftModel._torus(float(spec.centrifuge.radius),.3,8,64),m.dirty)
	rotor.add_child(torus)
	torus.rotation.x=PI/2
	for berth: Dictionary in berths(spec):
		var dock:=Node3D.new(); dock.name=berth.node; root.add_child(dock)
		dock.position=Vector3(berth.at[0],berth.at[1],berth.at[2])
		dock.quaternion=Quaternion(berth.q[0],berth.q[1],berth.q[2],berth.q[3])
		var pod=EvaPod.build(Vehicles.get_vehicle("evapod").stages[0],CraftModel._new_parts())
		dock.add_child(pod.group)
	return {"group":root,"parts":parts}

static func _seal(cx: float,cz: float,center: float,radius: float,seal_radius: float,mat: Material) -> MeshInstance3D:
	var g:=CraftModel.Geo.new()
	for i in range(65):
		var a:=TAU*i/64.0
		var x:=cx+seal_radius*cos(a);var z:=cz+seal_radius*sin(a)
		var point:=Vector3(x,center+sqrt(radius*radius-x*x-z*z)+.015,z)
		var normal: Vector3=(point-Vector3(0,center,0)).normalized()
		var tangent:=Vector3(-sin(a),0,cos(a))
		var across:=tangent.cross(normal).normalized()
		for j in 8:
			var t:=TAU*j/8.0
			var n:=normal*cos(t)+across*sin(t)
			g.pos.append(point+n*.035);g.nrm.append(n)
	for i in 64:
		for j in 8:
			var a:=i*8+j;var b:=i*8+(j+1)%8
			g.idx.append_array(PackedInt32Array([a,b,a+8,b,b+8,a+8]))
	return CraftModel._mesh(g,mat)
