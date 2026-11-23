class_name RoverModel
extends RefCounted

# The Apollo LRV drawn from primitives, to the dimensions Rover's physics uses (NSSDC's: a 3.1 m frame on a
# 2.3 m wheelbase, 81.8 cm × 23 cm wire-mesh tyres with titanium chevrons over half the tread, dust guards
# over the wheels, two seats side by side, the high-gain dish and the TV camera forward). Body frame as the
# physics has it: x left, y up, z forward, origin at the centre of mass. Its wheels turn, steer and ride the
# suspension; update() moves nothing else.

var group: Node3D
var wheels: Array = []        # [{pivot: Node3D (steer and travel), spin: Node3D}] in Rover.wheels' order
var _mats := {}

static func _mat(rgb: Color, metal := 0.0, rough := 0.8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = rgb
	m.metallic = metal
	m.roughness = rough
	return m

func _part(mesh: Mesh, mat: Material, at: Vector3, parent: Node3D, basis := Basis()) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = Transform3D(basis, at)
	parent.add_child(mi)
	return mi

static func _box(x: float, y: float, z: float) -> BoxMesh:
	var box := BoxMesh.new()
	box.size = Vector3(x, y, z)
	return box

static func _cyl(r: float, h: float, seg := 16) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

# A tube from a to b, in `parent`'s frame.
func _tube(a: Vector3, b: Vector3, r: float, mat: Material, parent: Node3D) -> void:
	var d := b - a
	var len := d.length()
	if len < 1e-4: return
	var y := d / len
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	_part(_cyl(r, len, 8), mat, (a + b) * 0.5, parent, Basis(x, y, z))

static func build() -> RoverModel:
	var m := RoverModel.new()
	m._build()
	return m

func _build() -> void:
	group = Node3D.new()
	group.name = "LRV"
	var alu := _mat(Color(0.72, 0.73, 0.74), 0.85, 0.4)
	var white := _mat(Color(0.86, 0.86, 0.84), 0.0, 0.7)
	var grey := _mat(Color(0.32, 0.33, 0.34), 0.0, 0.85)
	var mesh_tyre := _mat(Color(0.55, 0.56, 0.57), 0.9, 0.55)
	var titanium := _mat(Color(0.62, 0.6, 0.56), 0.9, 0.35)
	var seat := _mat(Color(0.36, 0.42, 0.5), 0.0, 0.9)
	var gold := _mat(Color(0.83, 0.64, 0.25), 0.9, 0.35)
	var black := _mat(Color(0.05, 0.05, 0.06), 0.0, 0.6)
	var deck_y := Rover.CLEARANCE - Rover.COM_HEIGHT + 0.05
	# The chassis: three hinged sections of 2219 tubing, a 3.1 m frame. A deck plate over each.
	for z in [-1.0, 0.0, 1.0]:
		_part(_box(1.12, 0.05, 1.0), grey, Vector3(0.0, deck_y, z * 1.03), group)
	for side in [-1.0, 1.0]:
		_tube(Vector3(side * 0.6, deck_y, -1.55), Vector3(side * 0.6, deck_y, 1.55), 0.025, alu, group)
	for z in [-1.55, -0.52, 0.52, 1.55]:
		_tube(Vector3(-0.6, deck_y, z), Vector3(0.6, deck_y, z), 0.022, alu, group)
	# Forward: the batteries and electronics under their dust covers; the console and hand controller.
	_part(_box(1.0, 0.22, 0.55), white, Vector3(0.0, deck_y + 0.14, 1.2), group)
	_part(_box(0.38, 0.32, 0.12), grey, Vector3(0.0, deck_y + 0.62, 0.62), group, Basis(Vector3.RIGHT, -0.5))
	_tube(Vector3(0.0, deck_y + 0.05, 0.6), Vector3(0.0, deck_y + 0.5, 0.62), 0.02, alu, group)
	_part(_box(0.06, 0.12, 0.06), black, Vector3(0.0, deck_y + 0.42, 0.22), group)
	# Two seats side by side, tubular aluminium and nylon webbing.
	for side in [-1.0, 1.0]:
		var sx: float = side * 0.33
		_part(_box(0.46, 0.04, 0.44), seat, Vector3(sx, deck_y + 0.3, -0.05), group)
		_part(_box(0.46, 0.5, 0.04), seat, Vector3(sx, deck_y + 0.55, -0.3), group, Basis(Vector3.RIGHT, 0.2))
		for x in [sx - 0.22, sx + 0.22]:
			_tube(Vector3(x, deck_y, 0.15), Vector3(x, deck_y + 0.3, 0.15), 0.015, alu, group)
			_tube(Vector3(x, deck_y, -0.27), Vector3(x, deck_y + 0.8, -0.35), 0.015, alu, group)
	# The high-gain dish on its mast, forward right, and the TV camera forward left.
	var mast_top := Vector3(-0.42, deck_y + 1.05, 1.05)
	_tube(Vector3(-0.42, deck_y + 0.25, 1.05), mast_top, 0.018, alu, group)
	var dish := CylinderMesh.new()
	dish.top_radius = 0.46
	dish.bottom_radius = 0.04
	dish.height = 0.18
	dish.radial_segments = 24
	_part(dish, white, mast_top + Vector3(0.0, 0.12, 0.05), group, Basis(Vector3.RIGHT, -0.35))
	_tube(Vector3(0.45, deck_y + 0.25, 1.35), Vector3(0.45, deck_y + 0.62, 1.35), 0.018, alu, group)
	_part(_box(0.14, 0.12, 0.24), gold, Vector3(0.45, deck_y + 0.7, 1.38), group)
	_part(_cyl(0.035, 0.06), black, Vector3(0.45, deck_y + 0.7, 1.52), group, Basis(Vector3.RIGHT, PI * 0.5))
	# The low-gain helical antenna, and the tool stand aft.
	_tube(Vector3(0.52, deck_y + 0.2, 1.0), Vector3(0.52, deck_y + 1.1, 1.0), 0.02, white, group)
	_part(_box(0.8, 0.5, 0.35), grey, Vector3(0.0, deck_y + 0.27, -1.3), group)
	# Wheels on double wishbones under dust guards.
	var r := Rover.WHEEL_R
	var probe := Rover.new(Rover.PlaneGround.new(), 1.62)
	for i in 4:
		var wh: Rover.Wheel = probe.wheels[i]
		var pivot := Node3D.new()
		pivot.position = wh.mount
		group.add_child(pivot)
		var spin := Node3D.new()
		pivot.add_child(spin)
		var axle := Basis(Vector3.FORWARD, PI * 0.5)
		_part(_cyl(r, Rover.WHEEL_B, 28), mesh_tyre, Vector3.ZERO, spin, axle)
		_part(_cyl(0.324, Rover.WHEEL_B + 0.02, 20), alu, Vector3.ZERO, spin, axle)
		# Titanium chevrons over half the tread.
		for k in 24:
			var a := TAU * k / 24.0
			var at := Vector3(0.0, cos(a) * (r + 0.004), sin(a) * (r + 0.004))
			_part(_box(Rover.WHEEL_B * 0.9, 0.006, 0.035), titanium, at, spin, Basis(Vector3.RIGHT, -a) * Basis(Vector3.UP, 0.5 if k % 2 == 0 else -0.5))
		var out: float = signf(wh.mount.x)
		# The guard: an arc over the wheel, standing with the pivot (it steers and rides with the wheel).
		for k in 7:
			var a := lerpf(-0.9, 0.9, k / 6.0)
			_part(_box(Rover.WHEEL_B + 0.08, 0.012, 0.16), grey, Vector3(0.0, cos(a) * (r + 0.06), sin(a) * (r + 0.06)), pivot, Basis(Vector3.RIGHT, -a))
		# The wishbones, from the chassis's side rail to the hub.
		var rail := Vector3(out * 0.6, deck_y, wh.mount.z)
		_tube(rail + Vector3(0, 0.0, 0.18), wh.mount + Vector3(-out * 0.1, 0.05, 0.0), 0.02, alu, group)
		_tube(rail + Vector3(0, 0.0, -0.18), wh.mount + Vector3(-out * 0.1, 0.05, 0.0), 0.02, alu, group)
		wheels.append({"pivot": pivot, "spin": spin, "mount": wh.mount})

## Pose the wheels from the physics; the group's own transform is the caller's.
func update(rover: Rover) -> void:
	for i in wheels.size():
		var w: Dictionary = wheels[i]
		var wh: Rover.Wheel = rover.wheels[i]
		var pivot: Node3D = w.pivot
		pivot.position = (w.mount as Vector3) + Vector3(0.0, wh.compression, 0.0)
		pivot.basis = Basis(Vector3.UP, wh.steer)
		(w.spin as Node3D).basis = Basis(Vector3.RIGHT, wh.angle)

## The group's transform in the site's frame (x west, y up, z north).
static func site_transform(rover: Rover) -> Transform3D:
	return Transform3D(Basis(rover.q.to_quaternion()), rover.pos.to_v3())
