class_name TimeCapsule
extends RefCounted

# The Titan Mare Explorer, the 2011 Discovery finalist that would have floated on Ligeia Mare: one axisymmetric
# capsule that enters, comes down on its chutes and floats as a drifting buoy, its heat shield the hull's
# bottom. One closed outline for what floats and what is drawn. Body frame: y along the axis towards the top,
# origin at the shield's lowest point for the outline, at the centre of mass for the hull handed to Floater.
# The same calls as Capsule (SurfaceSea.hull_for). docs/physics/ocean.md#the-titan-mare-explorer.

## Lorenz & Mann 2015 (JHU APL Technical Digest 33(2)): 700 kg, an axisymmetric hull modelled as stacked
## cylinders 0.8–2.9 m across, the centre of mass close to the waterline. The rest are estimates: a forebody
## with Huygens' 60° half-angle and a 0.75 m nose, a backshell rising to the 0.8 m top 1.6 m up.
const MASS := 700.0
const MAX_R := 1.45
const TOP_R := 0.40
const NOSE_R := 0.75
const CONE_HALF := 60.0
const SHOULDER := 0.06
const HEIGHT := 1.6
const CG_Y := 0.62
## The camera's sphere and the medium-gain antenna's box, each on a mast (Lorenz & Mann's figure 4): drawn only.
const MAST_H := 0.9

## Huygens' chutes scaled to TiME's mass (an estimate): the main, 8.3 m on Huygens' 319 kg, opened at Mach 1.5;
## the stabiliser that replaced it, sized here so it and the capsule's own drag bring 700 kg down at Huygens'
## 4.5 m/s on Titan (Lebreton et al. 2005: 4.54 m/s at impact).
const MAIN := {"area": 119.0, "Cd": 0.6}
const STABILISER := {"area": 19.5, "Cd": 0.55}

static func stage_key() -> String:
	return "time"

## The craft's centre of mass in its stage frame, m.
static func centre() -> Vector3:
	return Vector3(0.0, CG_Y, 0.0)

static func span() -> float:
	return HEIGHT

## The outline from the shield's centre to the top: (r, y), m. `detail` 1 is what floats.
static func outline(detail := 1) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var t := deg_to_rad(CONE_HALF)
	# The nose sphere meets the cone where its normal is the cone's: 90° − θ from the axis.
	var a_end := PI * 0.5 - t
	var cap_n := 3 * detail
	for i in cap_n + 1:
		var a := a_end * i / float(cap_n)
		pts.append(Vector2(NOSE_R * sin(a), NOSE_R - NOSE_R * cos(a)))
	var start := pts[pts.size() - 1]
	var run := (MAX_R - SHOULDER - start.x) / sin(t)
	var cone_n := 3 * detail
	for i in range(1, cone_n + 1):
		pts.append(start + Vector2(sin(t), cos(t)) * run * i / float(cone_n))
	# The shoulder: round from the cone's normal to the backshell's.
	var edge := pts[pts.size() - 1]
	var tor_c := edge - Vector2(cos(t), -sin(t)) * SHOULDER
	var back := atan2(HEIGHT - (tor_c.y + SHOULDER), MAX_R - TOP_R)
	var sh_n := 3 * detail
	for i in range(1, sh_n + 1):
		var a := lerpf(-t, PI * 0.5 - back, i / float(sh_n))
		pts.append(tor_c + Vector2(cos(a), sin(a)) * SHOULDER)
	var rim := pts[pts.size() - 1]
	var back_n := 3 * detail
	for i in range(1, back_n + 1):
		pts.append(rim.lerp(Vector2(TOP_R, HEIGHT), i / float(back_n)))
	pts.append(Vector2(0.0, HEIGHT))
	return pts

## TiME as a Floater on a world's liquid, at rest at the origin, shield down.
static func floater(gravity: float, liquid: Dictionary, air_density: float, segments := 12) -> Floater:
	var f := Floater.new(gravity, liquid, air_density)
	var cg := centre()
	var hull := Capsule.lathe(outline(), segments, cg)
	var mp := Capsule.mass_properties(Capsule.lathe(outline(), segments), MASS)
	f.set_inertia(MASS, mp.inertia)
	# Bobbing on its own waterplane, about the shoulder's width: ω = √(ρgA/m).
	f.radiation_omega = sqrt(float(liquid.rho) * gravity * PI * MAX_R * MAX_R / MASS)
	f.hulls.append({"verts": hull.verts, "tris": hull.tris, "scale": 1.0, "name": "hull"})
	return f

## It has no bags.
static func inflate(_f: Floater, _fill: float) -> void:
	pass

# THE MODEL
## For drawing, stage frame (origin at the shield's lowest point): the hull from the outline that floats, the
## two masts, and the two canopies hidden until used. Spaceflight finds them through the group's "capsule" meta.
static func build_model(_spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := Node3D.new()
	var pts := outline(3)
	var cap_end := 3 * 3 + 3 * 3
	var char_m := StandardMaterial3D.new()
	char_m.albedo_color = Color(0.14, 0.1, 0.08)
	char_m.roughness = 0.95
	var skin := StandardMaterial3D.new()
	# The backshell's white thermal paint.
	skin.albedo_color = Color(0.82, 0.8, 0.76)
	skin.roughness = 0.6
	g.add_child(Capsule._lathe_node(pts.slice(0, cap_end + 1), 48, char_m, true))
	g.add_child(Capsule._lathe_node(pts.slice(cap_end), 48, skin, false))
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.06, 0.06, 0.07)
	dark.metallic = 0.4
	dark.roughness = 0.35
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.6, 0.6, 0.62)
	metal.metallic = 0.8
	metal.roughness = 0.35
	for side in [-1.0, 1.0]:
		var mast := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.025; cm.bottom_radius = 0.035; cm.height = MAST_H
		mast.mesh = cm
		mast.material_override = metal
		mast.position = Vector3(side * 0.22, HEIGHT + MAST_H * 0.5, 0.0)
		g.add_child(mast)
	var pod := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.11; sm.height = 0.22
	pod.mesh = sm
	pod.material_override = dark
	pod.position = Vector3(-0.22, HEIGHT + MAST_H + 0.1, 0.0)
	g.add_child(pod)
	var mga := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.36, 0.26, 0.08)
	mga.mesh = bm
	mga.material_override = skin
	mga.position = Vector3(0.22, HEIGHT + MAST_H + 0.12, 0.0)
	mga.rotation.x = -0.5
	g.add_child(mga)
	# The two radioisotope generators on the backshell's flank.
	for side in [-1.0, 1.0]:
		var rtg := MeshInstance3D.new()
		var rc := CylinderMesh.new()
		rc.top_radius = 0.14; rc.bottom_radius = 0.14; rc.height = 0.55
		rtg.mesh = rc
		rtg.material_override = dark
		rtg.position = Vector3(0.0, 1.15, side * 0.9)
		rtg.rotation.x = side * 0.9
		g.add_child(rtg)
	var main := Capsule._canopy(sqrt(MAIN.area / PI) * 0.7, 18.0, Vector3.ZERO)
	var stab := Capsule._canopy(sqrt(STABILISER.area / PI) * 0.7, 10.0, Vector3.ZERO)
	for c: Node3D in [main, stab]:
		c.position = Vector3(0.0, HEIGHT, 0.0)
		g.add_child(c)
	g.set_meta("capsule", {"bags": [], "drogues": [main], "mains": [stab], "bag_r": 0.0})
	return {"group": g, "parts": parts}

## Pose the canopies: `chute` "", "drogue" (the main) or "mains" (the stabiliser), `open` 0–1.
static func pose_model(g: Node3D, fill: float, chute: String, open: float) -> void:
	Capsule.pose_model(g, fill, chute, open)
