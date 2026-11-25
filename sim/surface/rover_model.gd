class_name RoverModel
extends RefCounted

# The Apollo LRV drawn from primitives, to the dimensions Rover's physics uses (NSSDC's: a 3.1 m frame on a
# 2.3 m wheelbase, 81.8 cm × 23 cm wire-mesh tyres with titanium chevrons over half the tread, dust guards
# over the wheels, two seats side by side, the high-gain dish and the TV camera forward). Body frame as the
# physics has it: x left, y up, z forward, origin at the centre of mass. Its wheels turn, steer and ride the
# suspension; update() moves nothing else.

var group: Node3D
var wheels: Array = []        # [{pivot: Node3D (steer and travel), spin: Node3D}] in Rover.wheels' order
## Perseverance's arm: its joints' nodes, {az, lift, elbow, wrist}; empty for the LRV.
var joints := {}
## Perseverance's suspension and wheels; null for the LRV.
var mobility: Node3D = null
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

## The model for a Rover's spec: the LRV's or Perseverance's.
## `stowed`: Perseverance as it came down, its mast folded along the deck.
static func build(spec: Dictionary = Rover.LRV, stowed := false) -> RoverModel:
	var m := RoverModel.new()
	if str(spec.name) == "Perseverance": m._build_perseverance(stowed)
	else: m._build()
	return m

func _build() -> void:
	group = Node3D.new()
	group.name = "LRV"
	var alu := _mat(Color(0.72, 0.73, 0.74), 0.85, 0.4)
	var white := _mat(Color(0.86, 0.86, 0.84), 0.0, 0.7)
	var grey := _mat(Color(0.32, 0.33, 0.34), 0.0, 0.85)
	var mesh_tyre := _mat(Color(0.6, 0.61, 0.62), 0.45, 0.6)
	var titanium := _mat(Color(0.62, 0.6, 0.56), 0.9, 0.35)
	var seat := _mat(Color(0.36, 0.42, 0.5), 0.0, 0.9)
	var gold := _mat(Color(0.83, 0.64, 0.25), 0.9, 0.35)
	var black := _mat(Color(0.05, 0.05, 0.06), 0.0, 0.6)
	var lrv := Rover.LRV
	var deck_y := float(lrv.clearance) - float(lrv.com_height) + 0.05
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
	var r := float(lrv.wheel_r)
	var wb := float(lrv.wheel_b)
	var probe := Rover.new(Rover.PlaneGround.new(), 1.62)
	for i in probe.wheels.size():
		var wh: Rover.Wheel = probe.wheels[i]
		var pivot := Node3D.new()
		pivot.position = wh.mount
		group.add_child(pivot)
		var spin := Node3D.new()
		pivot.add_child(spin)
		var axle := Basis(Vector3.FORWARD, PI * 0.5)
		_part(_cyl(r, wb, 28), mesh_tyre, Vector3.ZERO, spin, axle)
		_part(_cyl(0.324, wb + 0.02, 20), alu, Vector3.ZERO, spin, axle)
		# Titanium chevrons over half the tread.
		for k in 24:
			var a := TAU * k / 24.0
			var at := Vector3(0.0, cos(a) * (r + 0.004), sin(a) * (r + 0.004))
			_part(_box(wb * 0.9, 0.006, 0.035), titanium, at, spin, Basis(Vector3.RIGHT, -a) * Basis(Vector3.UP, 0.5 if k % 2 == 0 else -0.5))
		var out: float = signf(wh.mount.x)
		# The guard: an arc over the wheel, standing with the pivot (it steers and rides with the wheel).
		for k in 7:
			var a := lerpf(-0.9, 0.9, k / 6.0)
			_part(_box(wb + 0.08, 0.012, 0.16), grey, Vector3(0.0, cos(a) * (r + 0.06), sin(a) * (r + 0.06)), pivot, Basis(Vector3.RIGHT, -a))
		# The wishbones, from the chassis's side rail to the hub.
		var rail := Vector3(out * 0.6, deck_y, wh.mount.z)
		_tube(rail + Vector3(0, 0.0, 0.18), wh.mount + Vector3(-out * 0.1, 0.05, 0.0), 0.02, alu, group)
		_tube(rail + Vector3(0, 0.0, -0.18), wh.mount + Vector3(-out * 0.1, 0.05, 0.0), 0.02, alu, group)
		wheels.append({"pivot": pivot, "spin": spin, "mount": wh.mount})

## Pose the wheels from the physics, and the arm from its joints; the group's own transform is the caller's.
func update(rover: Rover, arm: RoverArm = null) -> void:
	if arm != null and not joints.is_empty():
		(joints.az as Node3D).basis = Basis(Vector3.UP, float(arm.joints.az))
		(joints.lift as Node3D).basis = Basis(Vector3.RIGHT, -float(arm.joints.lift))
		(joints.elbow as Node3D).basis = Basis(Vector3.RIGHT, float(arm.joints.elbow))
		(joints.wrist as Node3D).basis = Basis(Vector3.RIGHT, float(arm.joints.wrist))
	for i in wheels.size():
		var w: Dictionary = wheels[i]
		var wh: Rover.Wheel = rover.wheels[i]
		var pivot: Node3D = w.pivot
		pivot.position = (w.mount as Vector3) + Vector3(0.0, wh.compression, 0.0)
		pivot.basis = Basis(Vector3.UP, wh.steer)
		(w.spin as Node3D).basis = Basis(Vector3.RIGHT, wh.angle)

## Fold Perseverance's mobility up beside her body and in, by `k` (1 as packed over the heat shield, 0 deployed):
## it comes down into place while the bridles pay out.
const STOW_UP := 0.24
const STOW_IN := 0.88
func stow(k: float) -> void:
	if mobility == null: return
	mobility.position.y = STOW_UP * k
	mobility.scale.x = lerpf(1.0, STOW_IN, k)

## The group's transform in the site's frame (x west, y up, z north).
static func site_transform(rover: Rover) -> Transform3D:
	return Transform3D(Basis(rover.q.to_quaternion()), rover.pos.to_v3())

# Perseverance, to NASA's 3 × 2.7 × 2.2 m and its photographs (PIA24428 from the descent stage, PIA24424 under the
# body): a white deck dense with boxes and harness, the coring-bit carousel on the front, the MMRTG at the back
# inside its white heat-rejection frame, the remote sensing mast whose head (SuperCam's telescope over Mastcam-Z's
# pair) stands 2.2 m up, the hexagonal high-gain antenna, beige titanium rocker-bogie tubes with the steering
# actuators at the corners, and six 52.5 cm aluminium wheels with 48 gently curved treads on curved flexure
# spokes. `stowed`: the mast folded back along the deck, as it came down.
func _build_perseverance(stowed := false) -> void:
	group = Node3D.new()
	group.name = "Perseverance"
	var spec := Rover.PERSEVERANCE
	# Dust settles on everything within a sol: the whites are a warm off-white, the metals a little tan and nearly
	# matte (PIA24424 and PIA24429 show the wheels and the rocker-bogie light, not mirror-dark).
	var white := _mat(Color(0.80, 0.78, 0.74), 0.0, 0.62)
	var grey := _mat(Color(0.52, 0.52, 0.52), 0.1, 0.6)
	var alu := _mat(Color(0.66, 0.65, 0.62), 0.2, 0.5)
	var ti := _mat(Color(0.62, 0.58, 0.52), 0.15, 0.6)
	var dark := _mat(Color(0.09, 0.09, 0.1), 0.1, 0.55)
	var gold := _mat(Color(0.84, 0.62, 0.26), 0.7, 0.35)
	var copper := _mat(Color(0.70, 0.40, 0.22), 0.5, 0.45)
	var glass := _mat(Color(0.03, 0.035, 0.05), 0.3, 0.08)
	var base_y := float(spec.clearance) - float(spec.com_height)
	var top_y := base_y + 0.5
	# The warm electronics box and the deck over it.
	_part(_box(1.36, 0.5, 1.95), white, Vector3(0.0, base_y + 0.25, 0.02), group)
	_part(_box(1.44, 0.035, 2.02), _mat(Color(0.74, 0.72, 0.68), 0.05, 0.6), Vector3(0.0, top_y, 0.02), group)
	for side in [-1.0, 1.0]:
		# A belly rim and the side panels' bolted seams.
		_part(_box(0.02, 0.44, 1.9), grey, Vector3(side * 0.69, base_y + 0.27, 0.02), group)
	# The deck's instruments and avionics: boxes, a cable run, the sample tubes' stowage.
	var deck_items := [[Vector3(-0.32, 0.09, 0.55), Vector3(0.42, 0.14, 0.34), white],
		[Vector3(0.36, 0.07, 0.42), Vector3(0.3, 0.1, 0.48), gold], [Vector3(0.05, 0.1, -0.05), Vector3(0.55, 0.16, 0.42), grey],
		[Vector3(-0.38, 0.06, -0.38), Vector3(0.36, 0.09, 0.3), white], [Vector3(0.38, 0.12, -0.42), Vector3(0.26, 0.2, 0.26), white],
		[Vector3(0.0, 0.05, 0.85), Vector3(0.9, 0.06, 0.18), copper]]
	for it: Array in deck_items:
		_part(_box(it[1].x, it[1].y, it[1].z), it[2], Vector3(it[0].x, top_y + it[1].y * 0.5, it[0].z), group)
	_tube(Vector3(-0.6, top_y + 0.03, 0.8), Vector3(-0.6, top_y + 0.03, -0.8), 0.018, copper, group)
	_tube(Vector3(0.6, top_y + 0.03, 0.75), Vector3(0.0, top_y + 0.03, 0.75), 0.015, gold, group)
	# The front: the coring-bit carousel's wheel and the sample handling below it, and the Hazcams.
	_part(_cyl(0.3, 0.1, 24), white, Vector3(0.18, base_y + 0.24, 1.05), group, Basis(Vector3.RIGHT, PI * 0.5))
	_part(_cyl(0.1, 0.12, 12), grey, Vector3(0.18, base_y + 0.24, 1.08), group, Basis(Vector3.RIGHT, PI * 0.5))
	for x in [-0.45, -0.3, 0.45, 0.3]:
		_part(_box(0.07, 0.06, 0.06), dark, Vector3(x, base_y + 0.05, 1.03), group)
	# The MMRTG at the back, canted, its fins dark, inside the white frame of heat-rejection panels (PIA24428).
	var rtg := Node3D.new()
	rtg.position = Vector3(0.0, base_y + 0.32, -1.22)
	rtg.basis = Basis(Vector3.RIGHT, -0.5)
	group.add_child(rtg)
	_part(_cyl(0.22, 0.66, 16), dark, Vector3.ZERO, rtg)
	for k in 8:
		var a := TAU * k / 8.0
		_part(_box(0.03, 0.6, 0.12), dark, Vector3(cos(a) * 0.27, 0.0, sin(a) * 0.27), rtg, Basis(Vector3.UP, -a))
	# The panels stand either side, open above, so the generator shows between them from overhead.
	for side in [-1.0, 1.0]:
		_part(_box(0.03, 0.46, 0.7), white, Vector3(side * 0.5, base_y + 0.3, -1.22), group, Basis(Vector3.RIGHT, -0.2))
		_part(_box(0.02, 0.36, 0.58), grey, Vector3(side * 0.48, base_y + 0.3, -1.22), group, Basis(Vector3.RIGHT, -0.2))
	_tube(Vector3(0.5, base_y + 0.06, -1.55), Vector3(-0.5, base_y + 0.06, -1.55), 0.02, white, group)
	# The high-gain antenna, a hexagon on its gimbal, and the UHF antenna beside it.
	_tube(Vector3(0.48, top_y, -0.32), Vector3(0.48, top_y + 0.3, -0.32), 0.03, alu, group)
	_part(_cyl(0.3, 0.035, 6), white, Vector3(0.48, top_y + 0.34, -0.32), group, Basis(Vector3.RIGHT, 0.5))
	_part(_cyl(0.06, 0.25, 10), white, Vector3(0.2, top_y + 0.12, -0.6), group)
	# The remote sensing mast, front right: SuperCam's telescope over Mastcam-Z's two zoom cameras and the
	# Navcams, the head 2.2 m over the ground. Stowed, it lies back along the deck.
	var mast := Node3D.new()
	mast.position = Vector3(-0.45, top_y, 0.72)
	group.add_child(mast)
	var mast_h := 2.2 - float(spec.com_height) - top_y - 0.1
	if stowed: mast.basis = Basis(Vector3.RIGHT, -PI * 0.5)
	_part(_cyl(0.07, 0.12, 12), grey, Vector3(0.0, 0.06, 0.0), mast)
	_tube(Vector3(0.0, 0.1, 0.0), Vector3(0.0, mast_h, 0.0), 0.055, white, mast)
	var head := Node3D.new()
	head.position = Vector3(0.0, mast_h, 0.0)
	mast.add_child(head)
	_part(_box(0.44, 0.2, 0.26), white, Vector3(0.0, 0.08, 0.02), head)
	_part(_cyl(0.08, 0.2, 16), white, Vector3(0.0, 0.26, 0.06), head, Basis(Vector3.RIGHT, PI * 0.5))
	_part(_cyl(0.06, 0.02, 16), glass, Vector3(0.0, 0.26, 0.17), head, Basis(Vector3.RIGHT, PI * 0.5))
	for x in [-0.13, 0.13]:
		_part(_cyl(0.04, 0.12, 12), dark, Vector3(x, 0.05, 0.16), head, Basis(Vector3.RIGHT, PI * 0.5))
		_part(_cyl(0.028, 0.02, 12), glass, Vector3(x, 0.05, 0.225), head, Basis(Vector3.RIGHT, PI * 0.5))
		_part(_box(0.06, 0.05, 0.06), dark, Vector3(x * 1.45, -0.05, 0.14), head)
	# Wheels, each on its link: the rocker from the body's side to the front wheel and the bogie pivot, the bogie
	# to the middle and rear; the corner wheels steer under their actuators.
	mobility = Node3D.new()
	mobility.name = "mobility"
	group.add_child(mobility)
	var r := float(spec.wheel_r)
	var probe := Rover.new(Rover.PlaneGround.new(), 3.71, spec, Rover.MARS_SAND)
	var bogie_z := (float(spec.axles[1]) + float(spec.axles[2])) * 0.5
	for i in probe.wheels.size():
		var wh: Rover.Wheel = probe.wheels[i]
		var pivot := Node3D.new()
		pivot.position = wh.mount
		mobility.add_child(pivot)
		var spin := Node3D.new()
		pivot.add_child(spin)
		var w := MeshInstance3D.new()
		var out: float = signf(wh.mount.x)
		# Spokes outboard: x is her left.
		w.mesh = _perseverance_wheel(r, float(spec.wheel_b), out)
		w.material_override = alu
		spin.add_child(w)
		# The hub motor on the inboard face, and the corner wheels' steering actuator above.
		var drum := _part(_cyl(0.075, 0.13, 12), dark, Vector3(-out * 0.2, 0.0, 0.0), pivot, Basis(Vector3.FORWARD, PI * 0.5))
		drum.name = "motor"
		if wh.steers:
			_part(_cyl(0.06, 0.16, 12), dark, Vector3(-out * 0.22, 0.32, 0.0), pivot)
			_tube(Vector3(-out * 0.22, 0.24, 0.0), Vector3(-out * 0.22, 0.0, 0.0), 0.035, ti, pivot)
		wheels.append({"pivot": pivot, "spin": spin, "mount": wh.mount})
	# The suspension, from the mounts' rest positions.
	for side in [-1.0, 1.0]:
		var ws: Array = probe.wheels.filter(func(x): return signf(x.mount.x) == side)
		ws.sort_custom(func(a, b): return a.mount.z > b.mount.z)
		var hub := Vector3(side * 0.74, base_y + 0.18, 0.2)
		var bogie := Vector3(side * 0.86, base_y - 0.05, bogie_z)
		_part(_cyl(0.07, 0.1, 12), ti, hub, mobility, Basis(Vector3.FORWARD, PI * 0.5))
		if ws.size() >= 3:
			var top := func(m: Vector3) -> Vector3: return Vector3(side * 0.88, m.y + 0.3, m.z)
			_tube(hub, top.call(ws[0].mount), 0.042, ti, mobility)
			_tube(top.call(ws[0].mount), Vector3(side * 0.88, ws[0].mount.y + 0.06, ws[0].mount.z), 0.035, ti, mobility)
			_tube(hub, bogie, 0.042, ti, mobility)
			_tube(bogie, top.call(ws[1].mount), 0.038, ti, mobility)
			_tube(bogie, top.call(ws[2].mount), 0.038, ti, mobility)
			for m: Vector3 in [ws[1].mount, ws[2].mount]:
				_tube(top.call(m), Vector3(side * 0.88, m.y + 0.06, m.z), 0.033, ti, mobility)
	# The differential bar across the deck that ties the two rockers.
	_tube(Vector3(-0.74, top_y + 0.06, 0.2), Vector3(0.74, top_y + 0.06, 0.2), 0.03, ti, group)
	# The arm: shoulder (azimuth, then lift), elbow, wrist, and the turret's tools on its face.
	var shoulder := Node3D.new()
	shoulder.position = RoverArm.SHOULDER
	group.add_child(shoulder)
	var lift := Node3D.new()
	shoulder.add_child(lift)
	_part(_cyl(0.08, 0.18, 14), dark, Vector3.ZERO, lift, Basis(Vector3.FORWARD, PI * 0.5))
	_tube(Vector3.ZERO, Vector3(0.0, 0.0, RoverArm.UPPER), 0.05, white, lift)
	var elbow := Node3D.new()
	elbow.position = Vector3(0.0, 0.0, RoverArm.UPPER)
	lift.add_child(elbow)
	_part(_cyl(0.07, 0.16, 14), dark, Vector3.ZERO, elbow, Basis(Vector3.FORWARD, PI * 0.5))
	_tube(Vector3.ZERO, Vector3(0.0, 0.0, RoverArm.FOREARM), 0.045, white, elbow)
	var wrist := Node3D.new()
	wrist.position = Vector3(0.0, 0.0, RoverArm.FOREARM)
	elbow.add_child(wrist)
	# The turret below the wrist: the coring drill (its bit), PIXL, SHERLOC with WATSON, the gas dust remover.
	_part(_cyl(0.06, 0.1, 12), dark, Vector3(0.0, -0.05, 0.0), wrist)
	_part(_box(0.3, 0.22, 0.3), white, Vector3(0.0, -RoverArm.WRIST * 0.55, 0.0), wrist)
	_part(_cyl(0.05, 0.2, 12), grey, Vector3(0.0, -RoverArm.WRIST * 0.85, 0.06), wrist)
	_tube(Vector3(0.0, -RoverArm.WRIST * 0.7, 0.06), Vector3(0.0, -RoverArm.WRIST, 0.06), 0.02, alu, wrist)
	_part(_box(0.13, 0.11, 0.12), gold, Vector3(0.15, -RoverArm.WRIST * 0.72, -0.09), wrist)
	_part(_box(0.11, 0.09, 0.13), dark, Vector3(-0.15, -RoverArm.WRIST * 0.7, -0.08), wrist)
	joints = {"az": shoulder, "lift": lift, "elbow": elbow, "wrist": wrist}
	# Folded until RoverArm moves it; for the descent, across her front (PIA24428), clear of the bridles.
	shoulder.basis = Basis(Vector3.UP, -PI * 0.5 if stowed else float(RoverArm.STOWED.az))
	lift.basis = Basis(Vector3.RIGHT, -float(RoverArm.STOWED.lift))
	elbow.basis = Basis(Vector3.RIGHT, float(RoverArm.STOWED.elbow))
	wrist.basis = Basis(Vector3.RIGHT, float(RoverArm.STOWED.wrist))

# One wheel, shared by all six, in the wheel's frame (axle along x): the rim, 48 treads curving gently across it
# (twice Curiosity's count, curved rather than chevroned), and six curved titanium flexure spokes to the hub.
static var _wheel_cache := {}

## `side` 1: the face on +x; −1: mirrored, for the wheels on her right.
static func _perseverance_wheel(r: float, width: float, side := 1.0) -> ArrayMesh:
	var key := "%s_%s_%s" % [r, width, side]
	if _wheel_cache.has(key): return _wheel_cache[key]
	_mirror = side
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 48
	var rim_r := r - 0.012
	# The rim drum, outside and in.
	for k in seg:
		var a0 := TAU * k / seg; var a1 := TAU * (k + 1) / seg
		var rad := Vector3(0.0, cos((a0 + a1) * 0.5), sin((a0 + a1) * 0.5))
		for rr in [rim_r, rim_r - 0.006]:
			var p00 := Vector3(-width * 0.5, cos(a0) * rr, sin(a0) * rr); var p01 := Vector3(width * 0.5, cos(a0) * rr, sin(a0) * rr)
			var p10 := Vector3(-width * 0.5, cos(a1) * rr, sin(a1) * rr); var p11 := Vector3(width * 0.5, cos(a1) * rr, sin(a1) * rr)
			var out := rad if rr == rim_r else -rad
			_tri(st, p00, p10, p01, out)
			_tri(st, p01, p10, p11, out)
	# Treads: each a curved ridge, four straight pieces bowing a few centimetres round the rim.
	for k in 48:
		var a := TAU * k / 48.0
		for j in 4:
			var t0 := -0.5 + j / 4.0; var t1 := t0 + 0.25
			var bow := func(t: float) -> float: return a + 0.09 * (1.0 - 4.0 * t * t)
			var x0 := t0 * width; var x1 := t1 * width
			var b0: float = bow.call(t0); var b1: float = bow.call(t1)
			var h := 0.012
			_ridge(st, Vector3(x0, cos(b0) * rim_r, sin(b0) * rim_r), Vector3(x1, cos(b1) * rim_r, sin(b1) * rim_r), h, 0.006)
	# Hub and spokes on the outboard face (+x; the right side's wheels are mirrored), the spokes curving from
	# the hub to the rim's lip as Perseverance's flexures do.
	var hub_r := r * 0.24
	var face := width * 0.42
	for k in 12:
		var a0 := TAU * k / 12.0; var a1 := TAU * (k + 1) / 12.0
		var c := Vector3(face, 0.0, 0.0)
		var q0 := c + Vector3(0.0, cos(a0) * hub_r, sin(a0) * hub_r); var q1 := c + Vector3(0.0, cos(a1) * hub_r, sin(a1) * hub_r)
		_tri(st, c + Vector3(0.02, 0.0, 0.0), q0, q1, Vector3.RIGHT)
		_tri(st, c - Vector3(0.06, 0.0, 0.0), q0, q1, Vector3.LEFT)
	for k in 6:
		var a := TAU * k / 6.0
		var pts: Array[Vector3] = []
		for j in 4:
			var t := j / 3.0
			var ang := a + 0.55 * t * t
			var rad := lerpf(hub_r, rim_r - 0.004, t)
			pts.append(Vector3(face - 0.03 * sin(PI * t), cos(ang) * rad, sin(ang) * rad))
		for j in 3: _ridge(st, pts[j], pts[j + 1], 0.01, 0.028, Vector3(1.0, 0.0, 0.0))
	_mirror = 1.0
	st.generate_normals()
	var mesh := st.commit()
	_wheel_cache[key] = mesh
	return mesh

# A thin box from a to b, `h` proud along `up` (default: radially out from the axle) and `w` wide: a tread or a
# spoke.
static func _ridge(st: SurfaceTool, a: Vector3, b: Vector3, h: float, w: float, up := Vector3.ZERO) -> void:
	var along := (b - a).normalized()
	var mid := (a + b) * 0.5
	var out := up if up != Vector3.ZERO else Vector3(0.0, mid.y, mid.z).normalized()
	if out.length_squared() < 1e-6: out = Vector3.UP
	var side := along.cross(out).normalized() * (w * 0.5)
	var lift := out * h
	var c := [a - side, a + side, b + side, b - side]
	var corners := []
	for p in c: corners.append(p)
	for p in c: corners.append((p as Vector3) + lift)
	var centre := (a + b) * 0.5 + lift * 0.5
	for f in [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]:
		var fc: Vector3 = (corners[f[0]] + corners[f[1]] + corners[f[2]] + corners[f[3]]) * 0.25
		_tri(st, corners[f[0]], corners[f[1]], corners[f[2]], fc - centre)
		_tri(st, corners[f[0]], corners[f[2]], corners[f[3]], fc - centre)

static var _mirror := 1.0

# A triangle facing `out`: Godot's front face winds clockwise seen from the front. Mirrored in x while `_mirror`
# is −1.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, out: Vector3) -> void:
	if _mirror < 0.0:
		var m := Vector3(-1.0, 1.0, 1.0)
		a *= m; b *= m; c *= m; out *= m
	if (b - a).cross(c - a).dot(out) < 0.0:
		st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	else:
		st.add_vertex(a); st.add_vertex(c); st.add_vertex(b)
