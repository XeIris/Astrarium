class_name EnduranceCraft
extends RefCounted

static func berths(spec: Dictionary) -> Array:
	var look: Dictionary = spec.look
	var cargo := LanderCraft.dock(Vehicles.get_vehicle("lander").stages[0])
	var collar := Vector3(cargo.at[0], cargo.at[1], cargo.at[2])
	var normal := Vector3(cargo.normal[0], cargo.normal[1], cargo.normal[2]).normalized()
	var ranger_length := float(Vehicles.get_vehicle("ranger").stages[0].L)
	var y := float(look.ring.at)
	var out := []
	for i in 2:
		var side := 1.0 if i == 0 else -1.0
		# Both bows point out of the wheel. The tiled bellies face across the gap.
		var roof := Vector3.RIGHT * side
		var ranger := Basis(Vector3.DOWN.cross(roof), Vector3.DOWN, roof)
		var shoulder := Vector3(side * float(look.rangerSpacing) * .5, y, 0)
		var socket := Vector3(shoulder.x, ranger_length + .002, 0)
		out.append(_mount("ranger", i, ranger, socket + Vector3.DOWN*.002 - ranger * Vector3(0,0,.15), shoulder, socket))

		# Roll the cargo ships onto their sides, then seat the inclined dorsal seals.
		var inward := Vector3.FORWARD * side
		var axes := Basis(Vector3.RIGHT.cross(inward), Vector3.RIGHT, inward)
		var lander := axes * Basis(Quaternion(normal, Vector3.BACK))
		var crosshead := Vector3(float(look.cargoCrosshead), y, 0)
		var seat := crosshead - inward * float(look.cargoReach)
		out.append(_mount("lander", i, lander, seat - inward*(LANDER_TUBE+.002) - lander * collar, crosshead, seat))
	return out

static func _mount(kind: String, i: int, axes: Basis, origin: Vector3, base: Vector3, tip: Vector3) -> Dictionary:
	var q := axes.get_rotation_quaternion()
	return {"vehicle":kind, "node":"dock_%s_%d" % [kind,i], "q":[q.x,q.y,q.z,q.w],
		"at":[origin.x,origin.y,origin.z], "base":[base.x,base.y,base.z], "tip":[tip.x,tip.y,tip.z]}

static func axial_ranger(spec: Dictionary) -> Dictionary:
	return {"vehicle":"ranger","node":"dock_ranger_0","q":[0,0,0,1],
		"at":[0,float(spec.look.hubTop)+float(spec.look.axialAdapter)+.002,-.15]}

const RECOVERY_GASKET := .08
const LANDER_TUBE := .12

## Both visitors use the free spin-axis port after leaving their transport berths.
static func axial_lander(spec: Dictionary, lander: Dictionary) -> Dictionary:
	var collar := LanderCraft.dock(lander)
	var normal := Vector3(collar.normal[0], collar.normal[1], collar.normal[2]).normalized()
	var rotation := Quaternion(normal, Vector3.DOWN)
	var tip := Vector3(0, float(spec.look.hubTop) + float(spec.look.axialAdapter), 0)
	var at := tip + Vector3.UP * (RECOVERY_GASKET + LANDER_TUBE) - rotation * Vector3(collar.at[0], collar.at[1], collar.at[2])
	return {"vehicle":"lander", "node":"dock_lander_0", "at":[at.x, at.y, at.z],
		"collar":DVec3.new(collar.at[0], collar.at[1], collar.at[2]),
		"q":[rotation.x, rotation.y, rotation.z, rotation.w]}

static func fit_recovery_adapter(rotor: Node3D, spec: Dictionary, lander: Dictionary) -> void:
	var mount := Node3D.new()
	mount.name = "recovery_adapter"
	mount.position.y = float(spec.look.hubTop) + float(spec.look.axialAdapter)
	rotor.add_child(mount)
	var radius := float(LanderCraft.dock(lander).radius)
	var materials := CraftModel.craft_materials()
	var reducer := CraftModel._mesh(CraftModel._cylinder(radius, .58, .24, 64), materials.steel)
	reducer.position.y = -.12
	mount.add_child(reducer)
	var seal := CraftModel._mesh(CraftModel._torus(radius, RECOVERY_GASKET, 12, 64), materials.black)
	seal.rotation.x = PI / 2.0
	mount.add_child(seal)

static func spokes(spec: Dictionary) -> Array:
	var y:=float(spec.look.ring.at)
	var ring: Dictionary=spec.look.ring
	var inner_edge:=float(ring.centerRadius)-float(ring.moduleSize[0])*.5
	return [{"start":Vector3(1.27,y,0),"end":Vector3(inner_edge+.20,y,0),"radius":1.18,"flangeRadius":1.31}]

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
	var support:=Node3D.new();support.name="inspection_spokes";rotor.add_child(support)
	for spoke: Dictionary in spokes(spec):
		rod(support,spoke.start,spoke.end,spoke.radius,m.white)
	var top := float(spec.look.hubTop)
	var base := float(spec.look.hubBase)
	var y := float(spec.look.ring.at)
	rod(rotor, Vector3(0,base,0), Vector3(0,top,0), float(spec.look.hubRadius), m.white)
	rod(rotor, Vector3(0,top-.25,0), Vector3(0,top+float(spec.look.axialAdapter),0), .58, m.steel)
	rod(rotor, Vector3(0,y,0), Vector3(float(spec.look.cargoCrosshead),y,0), 1.16, m.white)
	for berth: Dictionary in berths(spec):
		var start := Vector3(berth.base[0],berth.base[1],berth.base[2])
		var tip := Vector3(berth.tip[0],berth.tip[1],berth.tip[2])
		rod(rotor,start,tip,.58 if berth.vehicle=="ranger" else 1.04,m.steel)
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
