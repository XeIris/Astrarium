class_name EnduranceCraft
extends RefCounted

static func berths(spec: Dictionary) -> Array:
	var hub:=float(spec.look.hubLength)
	var cargo:=LanderCraft.dock(Vehicles.get_vehicle("lander").stages[0])
	var slope: float=-float(cargo.normal[1])
	var rotation:=DQuat.new().set_from_axis_angle(DVec3.new(0,0,1),atan(slope))
	rotation.multiply(DQuat.new().set_from_axis_angle(DVec3.new(0,1,0),PI*.5))
	var point:=DVec3.new(cargo.at[0],cargo.at[1],cargo.at[2])
	var berth: Array=spec.look.landerBerth
	var offset:=DVec3.new(berth[0],berth[1],berth[2]).sub_in(DQuat.rotate(point,rotation))
	return [{"vehicle":"ranger","node":"dock_ranger_0","at":[0.0,hub+float(spec.look.axialAdapter)-.10,-.13],"q":[0.0,0.0,0.0,1.0]},
		{"vehicle":"lander","node":"dock_lander_0","at":offset.to_array(),"q":[rotation.x,rotation.y,rotation.z,rotation.w]}]

static func spokes(spec: Dictionary) -> Array:
	var y:=float(spec.look.ring.at)
	var members:=[]
	for i in 3:
		var angle:=TAU*i/3.0
		var radial:=Vector3(cos(angle),0,sin(angle))
		var outer:=radial*21.9+Vector3.UP*y
		members.append({"start":radial*1.25+Vector3.UP*y,"end":outer,"radius":.90})
		for side in [-1,1]:
			members.append({"start":radial*1.30+Vector3.UP*(y+side*3.0),"end":outer,"radius":.075})
	return members

static func build(spec: Dictionary,parts: Dictionary) -> Dictionary:
	var root:=Node3D.new()
	var rotor:=Node3D.new();rotor.name="rotor_expedition_0";root.add_child(rotor);parts.rotors.append(rotor)
	var m:=CraftModel.craft_materials()
	var ring: Dictionary=spec.look.ring
	var radius:=float(ring.centerRadius);var height:=float(ring.at)
	var size_: Array=ring.moduleSize
	for i in 12:
		var angle:=TAU*i/12.0
		var mount:=Node3D.new();mount.name="inspection_module_%d"%i;rotor.add_child(mount)
		mount.position.y=height;mount.rotation.y=-angle
		EvaPod._box(mount,Vector3(radius,0,0),Vector3(size_[0],size_[1],size_[2]),m.white)
		var a:=Vector3(radius,0,0);var b:=Vector3(radius*cos(PI/6),0,radius*sin(PI/6))
		rod(mount,a,b,1.04,m.white)
		var junction:=CraftModel._mesh(CraftModel._sphere(1.55,20,12),m.white)
		junction.position=(a+b)*.5;mount.add_child(junction)
		for side in [-1,1]:
			if i%2==0:
				EvaPod._box(mount,Vector3(radius,side*(float(size_[1])*.5+.08),0),Vector3(float(size_[0])-.8,.10,float(size_[2])-.8),m.black)
		if i%3==0:
			for point: Vector2 in [Vector2(-1.55,-1.65),Vector2(1.55,-1.65),Vector2(0,1.65)]:
				var pivot:=Node3D.new();mount.add_child(pivot);parts.gimbals.append(pivot)
				pivot.position=Vector3(radius+point.x,-float(size_[1])*.5-.275,point.y)
				var bell:=CraftModel._mesh(CraftModel._cylinder(.40,.95,1.08,32),m.nozzle)
				bell.position.y=.56;pivot.add_child(bell)
	for spoke: Dictionary in spokes(spec):
		rod(rotor,spoke.start,spoke.end,spoke.radius,m.white if spoke.radius>.5 else m.steel)
	var hub_length:=float(spec.look.hubLength)
	var hub_radius:=float(spec.look.hubRadius)
	var hub:=CraftModel._mesh(CraftModel._cylinder(hub_radius,hub_radius,hub_length,48),m.white)
	hub.position.y=hub_length*.5;rotor.add_child(hub)
	rod(rotor,Vector3(0,hub_length-.25,0),Vector3(0,hub_length+float(spec.look.axialAdapter),0),.58,m.steel)
	var lander: Array=spec.look.landerBerth
	rod(rotor,Vector3(-hub_radius+.22,lander[1],0),Vector3(lander[0]-.02,lander[1],0),1.04,m.steel)
	for berth: Dictionary in berths(spec):
		var mount:=Node3D.new();mount.name=berth.node;rotor.add_child(mount)
		mount.position=Vector3(berth.at[0],berth.at[1],berth.at[2])
		mount.quaternion=Quaternion(berth.q[0],berth.q[1],berth.q[2],berth.q[3])
		var child_spec: Dictionary=Vehicles.get_vehicle(berth.vehicle).stages[0]
		var child=RangerCraft.build(child_spec,CraftModel._new_parts()) if berth.vehicle=="ranger" else LanderCraft.build(child_spec,CraftModel._new_parts())
		mount.add_child(child.group)
	return {"group":root,"parts":parts}

static func rod(parent: Node3D,a: Vector3,b: Vector3,radius: float,mat: Material) -> void:
	var span:=b-a
	var node:=CraftModel._mesh(CraftModel._cylinder(radius,radius,span.length(),16),mat)
	node.position=(a+b)*.5
	node.quaternion=Quaternion(Vector3.UP,span.normalized())
	parent.add_child(node)
