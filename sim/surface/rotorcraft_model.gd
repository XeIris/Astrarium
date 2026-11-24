class_name RotorcraftModel
extends RefCounted

# A Rotorcraft drawn: Ingenuity or Dragonfly, procedural, in the body frame Rotorcraft flies (origin at the
# centre of mass, y up, z ahead). Its rotors sit where the physics puts them; blades turn at a rate the eye can
# follow, with a faint disc once they are fast, since 2537 rpm strobes against any frame rate.

const SHOWN_RATE := 30.0

var group: Node3D
var _blades: Array = []
var _discs: Array = []

static func build(spec: Dictionary) -> RotorcraftModel:
	var m := RotorcraftModel.new()
	m.group = Node3D.new()
	m.group.name = str(spec.name)
	if str(spec.name) == "Ingenuity": m._ingenuity(spec)
	else: m._dragonfly(spec)
	m._rotors(spec)
	return m

static func _mat(c: Color, metal := 0.0, rough := 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	return m

func _box(size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = at
	group.add_child(mi)
	return mi

func _rod(a: Vector3, b: Vector3, r: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = a.distance_to(b)
	mi.mesh = c
	mi.material_override = mat
	mi.position = (a + b) * 0.5
	var d := (b - a).normalized()
	if absf(d.dot(Vector3.UP)) < 0.999:
		mi.basis = Basis(Quaternion(Vector3.UP, d))
	group.add_child(mi)
	return mi

# Ingenuity, to NASA's 0.49 m tall: the warm fuselage 136 × 195 × 163 mm, four carbon legs, the mast, and the
# solar panel above the rotors.
func _ingenuity(spec: Dictionary) -> void:
	var foil := _mat(Color(0.82, 0.62, 0.28), 0.6, 0.35)
	var carbon := _mat(Color(0.08, 0.08, 0.09), 0.2, 0.5)
	var panel := _mat(Color(0.05, 0.07, 0.14), 0.3, 0.25)
	var sz: Vector3 = spec.size
	_box(sz, Vector3(0.0, -0.02, 0.0), foil)
	for leg: Vector3 in spec.legs:
		_rod(Vector3(leg.x * 0.25, -0.02 - sz.y * 0.3, leg.z * 0.25), leg, 0.006, carbon)
	_rod(Vector3(0.0, -0.02 + sz.y * 0.5, 0.0), Vector3(0.0, 0.32, 0.0), 0.012, carbon)
	_box(Vector3(0.425, 0.008, 0.165), Vector3(0.0, 0.32, 0.0), panel)

# Dragonfly, to NASA's 3.85 × 3.85 × 1.75 m: the lander body, four arms to the coaxial pairs, two skids, the
# MMRTG at the back and the high-gain antenna on top.
func _dragonfly(spec: Dictionary) -> void:
	var white := _mat(Color(0.86, 0.86, 0.84), 0.0, 0.55)
	var gold := _mat(Color(0.8, 0.62, 0.3), 0.6, 0.35)
	var dark := _mat(Color(0.15, 0.15, 0.16), 0.4, 0.45)
	_box(Vector3(1.9, 0.75, 1.5), Vector3(0.0, 0.05, 0.0), gold)
	_box(Vector3(1.6, 0.12, 1.3), Vector3(0.0, 0.48, 0.0), white)
	for leg: Vector3 in spec.legs:
		_rod(Vector3(leg.x * 0.8, -0.3, leg.z * 0.6), leg, 0.04, dark)
	for side in [-1.0, 1.0]:
		_rod(Vector3(side * 0.9, -0.75, 1.4), Vector3(side * 0.9, -0.75, -1.4), 0.05, dark)
	var hubs := {}
	for r: Dictionary in spec.rotors: hubs[int(r.pair)] = Vector3(r.at.x, 0.0, r.at.z)
	for p in hubs:
		var h: Vector3 = hubs[p]
		_rod(Vector3(h.x * 0.35, 0.3, h.z * 0.35), Vector3(h.x, 0.62, h.z), 0.06, white)
		_rod(Vector3(h.x, 0.5, h.z), Vector3(h.x, 0.8, h.z), 0.05, dark)
	var rtg := _rod(Vector3(0.0, 0.25, -0.8), Vector3(0.0, 0.25, -1.4), 0.32, dark)
	rtg.name = "MMRTG"
	var dish := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5; sm.height = 0.25; sm.is_hemisphere = true
	dish.mesh = sm
	dish.material_override = white
	dish.position = Vector3(0.0, 0.62, 0.3)
	dish.rotation = Vector3(PI, 0.0, 0.0)
	group.add_child(dish)

func _rotors(spec: Dictionary) -> void:
	var blade_m := _mat(Color(0.12, 0.12, 0.13), 0.1, 0.5)
	var disc_m := StandardMaterial3D.new()
	disc_m.albedo_color = Color(0.3, 0.3, 0.32, 0.18)
	disc_m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	disc_m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var R := float(spec.radius)
	var chord := float(spec.solidity) * PI * R / float(spec.blades)
	for r: Dictionary in spec.rotors:
		var hub := Node3D.new()
		hub.position = r.at
		group.add_child(hub)
		for b in int(spec.blades):
			var bl := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(R * 2.0, 0.006 * maxf(R / 0.6, 1.0), chord)
			bl.mesh = bm
			bl.material_override = blade_m
			bl.rotation.y = PI * b / float(spec.blades)
			hub.add_child(bl)
		var disc := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = R; cm.bottom_radius = R; cm.height = 0.002
		disc.mesh = cm
		disc.material_override = disc_m
		disc.visible = false
		hub.add_child(disc)
		_blades.append([hub, float(r.spin)])
		_discs.append(disc)

var _last_us := 0

## Pose it where the craft is (site frame) and turn its blades, on the wall clock: drawing only.
func update(craft: Rotorcraft) -> void:
	var now := Time.get_ticks_usec()
	var dt := clampf((now - _last_us) / 1e6, 0.0, 0.1) if _last_us > 0 else 0.0
	_last_us = now
	group.transform = Transform3D(Basis(craft.q.to_quaternion()), craft.pos.to_v3())
	for i in _blades.size():
		var hub: Node3D = _blades[i][0]
		var om := craft.rotors[i].omega if craft.armed else 0.0
		hub.rotation.y += float(_blades[i][1]) * minf(om, SHOWN_RATE) * dt
		(_discs[i] as Node3D).visible = om > SHOWN_RATE
