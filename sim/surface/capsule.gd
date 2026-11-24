class_name Capsule
extends RefCounted

# The Apollo command module after splashdown: one closed outline for what floats and what is drawn, its mass
# properties, and the three uprighting bags. Body frame: y along the axis towards the apex, origin at the heat
# shield's lowest point for the outline, at the centre of mass for the hull handed to Floater.
# docs/physics/ocean.md#the-command-module.

## 154 in across and 127 in tall without the probe (Smithsonian, Apollo 7's CM); the heat shield's sphere of
## 184.8 in, the 33° cone, its shoulder and the tunnel's width are the commonly quoted figures, not checked
## against a drawing.
const MAX_R := 1.9558
const HEIGHT := 3.2258
const SHIELD_R := 4.694
const CONE_HALF := 33.0
const SHOULDER := 0.196
const TUNNEL_R := 0.42
## Apollo 11's splashdown weight, 10,873 lb (NASA SP-4029).
const MASS := 4931.9
## The centre of mass above the shield and off the axis: estimates, the offset the one that trims an Apollo
## shape to L/D 0.3.
const CG_Y := 1.04
const CG_X := 0.14
## Three bags of 22 ft³ each (NASA TN D-7081), as spheres on the forward deck, and how long the compressors
## take to fill them (an estimate).
const BAG_V := 0.623
const BAG_RING := 0.62
const INFLATE_S := 240.0
## Two 16.5 ft drogues, then three 83.5 ft ringsail mains (NASA; NASM): nominal areas, and a drag coefficient
## for each (estimates for a conical ribbon and a ringsail).
const DROGUE := {"area": 2.0 * PI * 2.515 * 2.515 / 4.0, "Cd": 0.55}
const MAINS := {"area": 3.0 * PI * 25.45 * 25.45 / 4.0, "Cd": 0.82}

static func stage_key() -> String:
	return "cm"

## The craft's centre of mass in its stage frame, m.
static func centre() -> Vector3:
	return Vector3(CG_X, CG_Y, 0.0)

static func span() -> float:
	return HEIGHT

## The outline from the shield's centre to the tunnel's top: (r, y), m. `detail` 1 is what floats; the drawn
## model samples the same curve finer.
static func outline(detail := 1) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var t := deg_to_rad(CONE_HALF)
	# The shoulder's torus centre: the cone's flank and the shield's sphere both tangent to it.
	var tor_c := Vector2(MAX_R - SHOULDER, 0.0)
	var a_end := asin((MAX_R - SHOULDER) / (SHIELD_R - SHOULDER))
	tor_c.y = SHIELD_R - (SHIELD_R - SHOULDER) * cos(a_end)
	var cap_n := 4 * detail
	for i in cap_n + 1:
		var a := a_end * i / float(cap_n)
		pts.append(Vector2(SHIELD_R * sin(a), SHIELD_R - SHIELD_R * cos(a)))
	# Round the shoulder from the shield's normal to the cone's.
	var cone_n := PI * 0.5 + t
	var sh_n := 3 * detail
	for i in range(1, sh_n + 1):
		var a := lerpf(a_end, cone_n, i / float(sh_n))
		pts.append(tor_c + Vector2(sin(a), -cos(a)) * SHOULDER)
	var start := pts[pts.size() - 1]
	var climb := (start.x - TUNNEL_R) / tan(t)
	var cone_s := 2 * detail
	for i in range(1, cone_s + 1):
		pts.append(start.lerp(Vector2(TUNNEL_R, start.y + climb), i / float(cone_s)))
	pts.append(Vector2(TUNNEL_R, HEIGHT))
	pts.append(Vector2(0.0, HEIGHT))
	return pts

## The outline turned about its axis into a closed triangle mesh, outward-wound: {verts, tris}, the vertices
## relative to `origin` (body frame), m.
static func lathe(pts: PackedVector2Array, segments: int, origin := Vector3.ZERO) -> Dictionary:
	var verts := PackedFloat64Array()
	var tris := PackedInt32Array()
	var ring_n := pts.size() - 2
	# The two poles, then a ring per interior outline point.
	verts.append_array([-origin.x, pts[0].y - origin.y, -origin.z])
	for k in range(1, pts.size() - 1):
		for s in segments:
			var a := TAU * s / segments
			verts.append_array([pts[k].x * cos(a) - origin.x, pts[k].y - origin.y, pts[k].x * sin(a) - origin.z])
	var top := 1 + ring_n * segments
	verts.append_array([-origin.x, pts[pts.size() - 1].y - origin.y, -origin.z])
	for s in segments:
		var s2 := (s + 1) % segments
		tris.append_array([0, 1 + s, 1 + s2])
		for k in ring_n - 1:
			var a := 1 + k * segments + s; var b := 1 + k * segments + s2
			var c := a + segments; var d := b + segments
			tris.append_array([a, c, b, b, c, d])
		var last := 1 + (ring_n - 1) * segments
		tris.append_array([last + s2, last + s, top])
	return {"verts": verts, "tris": tris}

## A sphere of radius 1 about the origin, outward-wound, for a bag scaled to its radius.
static func sphere(rings := 6, segments := 12) -> Dictionary:
	var pts := PackedVector2Array()
	for i in rings + 1:
		var a := PI * i / rings
		pts.append(Vector2(sin(a), -cos(a)))
	return lathe(pts, segments)

## Mass properties of a closed mesh of uniform density holding `m`: {volume, centroid, inertia (about the
## centroid, row-major)}, by tetrahedra from the origin.
static func mass_properties(mesh: Dictionary, m: float) -> Dictionary:
	var v: PackedFloat64Array = mesh.verts
	var tris: PackedInt32Array = mesh.tris
	var vol := 0.0
	var cx := 0.0; var cy := 0.0; var cz := 0.0
	var c := PackedFloat64Array(); c.resize(9)
	for tr in tris.size() / 3:
		var a := tris[tr * 3] * 3; var b := tris[tr * 3 + 1] * 3; var d := tris[tr * 3 + 2] * 3
		var p := [Vector3(v[a], v[a + 1], v[a + 2]), Vector3(v[b], v[b + 1], v[b + 2]), Vector3(v[d], v[d + 1], v[d + 2])]
		var det := float(v[a] * (v[b + 1] * v[d + 2] - v[b + 2] * v[d + 1]) - v[a + 1] * (v[b] * v[d + 2] - v[b + 2] * v[d])
			+ v[a + 2] * (v[b] * v[d + 1] - v[b + 1] * v[d]))
		vol += det / 6.0
		var s: Vector3 = p[0] + p[1] + p[2]
		cx += det / 24.0 * s.x; cy += det / 24.0 * s.y; cz += det / 24.0 * s.z
		# The covariance of a tetrahedron with a vertex at the origin: det/120 (Σ pᵢpⱼᵀ + s sᵀ).
		for i in 3:
			for j in 3:
				var acc := 0.0
				for q in 3: acc += (p[q] as Vector3)[i] * (p[q] as Vector3)[j]
				c[i * 3 + j] += det / 120.0 * (acc + s[i] * s[j])
	var cen := Vector3(cx / vol, cy / vol, cz / vol)
	var rho_m := m / vol
	var inertia := PackedFloat64Array(); inertia.resize(9)
	var cc := PackedFloat64Array(); cc.resize(9)
	for i in 3:
		for j in 3:
			cc[i * 3 + j] = (c[i * 3 + j] - vol * cen[i] * cen[j]) * rho_m
	var tr_c := cc[0] + cc[4] + cc[8]
	for i in 3:
		for j in 3:
			inertia[i * 3 + j] = (tr_c if i == j else 0.0) - cc[i * 3 + j]
	return {"volume": vol, "centroid": cen, "inertia": inertia}

## The CM as a Floater on a world's liquid, at rest at the origin, heat shield down.
static func floater(gravity: float, liquid: Dictionary, air_density: float, segments := 12) -> Floater:
	var f := Floater.new(gravity, liquid, air_density)
	var cg := Vector3(CG_X, CG_Y, 0.0)
	var hull := lathe(outline(), segments, cg)
	var mp := mass_properties(lathe(outline(), segments), MASS)
	f.set_inertia(MASS, mp.inertia)
	# Bobbing on its own waterplane, about the shield's width: ω = √(ρgA/m).
	f.radiation_omega = sqrt(float(liquid.rho) * gravity * PI * MAX_R * MAX_R / MASS)
	f.hulls.append({"verts": hull.verts, "tris": hull.tris, "scale": 1.0, "name": "hull"})
	var ball := sphere()
	var r := pow(3.0 * BAG_V / (4.0 * PI), 1.0 / 3.0)
	for i in 3:
		var a := TAU * i / 3.0
		var at := Vector3(BAG_RING * cos(a), HEIGHT - 0.1 + r * 0.6, BAG_RING * sin(a)) - cg
		f.hulls.append({"verts": ball.verts, "tris": ball.tris, "scale": 0.0, "full": r, "name": "bag",
			"ox": at.x, "oy": at.y, "oz": at.z})
	return f

## Bags `fill` of the way full, 0–1, by volume.
static func inflate(f: Floater, fill: float) -> void:
	for h in f.hulls:
		if str(h.name) == "bag": h.scale = float(h.full) * pow(clampf(fill, 0.0, 1.0), 1.0 / 3.0)

# THE MODEL
## Drawn heights of the canopies above the apex, m, at full inflation: the risers and suspension lines run
## about a canopy's diameter (an estimate from recovery photographs).
const DROGUE_UP := 14.0
const MAINS_UP := 30.0

## The CM for drawing, stage frame (origin at the shield's lowest point): the hull from the outline that
## floats, sampled finer, with its windows, hatch and thrusters; the bags and canopies hidden until used.
## Spaceflight finds them through the group's "capsule" meta.
static func build_model(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := Node3D.new()
	var pts := outline(3)
	var cap_end := 4 * 3 + 3 * 3
	var shield_pts := pts.slice(0, cap_end + 1)
	var upper_pts := pts.slice(cap_end)
	var char_m := StandardMaterial3D.new()
	char_m.albedo_color = Color(0.16, 0.11, 0.08)
	char_m.roughness = 0.95
	var skin := StandardMaterial3D.new()
	# The Mylar skin came home scorched: bare aluminium streaked brown.
	skin.albedo_color = Color(0.5, 0.45, 0.39)
	skin.metallic = 0.15
	skin.roughness = 0.55
	g.add_child(_lathe_node(shield_pts, 48, char_m, true))
	g.add_child(_lathe_node(upper_pts, 48, skin, false))
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.03, 0.035, 0.04)
	dark.metallic = 0.2
	dark.roughness = 0.15
	var t := deg_to_rad(CONE_HALF)
	# Two rendezvous windows forward, two side windows, the hatch window between them.
	for w in [[-0.5, 1.9, 0.2, 0.22], [0.5, 1.9, 0.2, 0.22], [-1.25, 1.55, 0.26, 0.26], [1.25, 1.55, 0.26, 0.26], [0.0, 1.55, 0.24, 0.24]]:
		g.add_child(_on_cone(float(w[0]), float(w[1]), Vector2(w[2], w[3]), dark, t))
	var hatch_m := StandardMaterial3D.new()
	hatch_m.albedo_color = Color(0.3, 0.27, 0.23)
	hatch_m.metallic = 0.5
	hatch_m.roughness = 0.6
	g.add_child(_on_cone(0.0, 1.45, Vector2(0.75, 0.85), hatch_m, t, 0.004))
	for i in 6:
		g.add_child(_on_cone(PI * 0.25 + i * PI / 3.0, 2.25, Vector2(0.12, 0.12), dark, t))
	var bag_m := StandardMaterial3D.new()
	bag_m.albedo_color = Color(0.92, 0.92, 0.9)
	bag_m.roughness = 0.7
	var bags := []
	var r := pow(3.0 * BAG_V / (4.0 * PI), 1.0 / 3.0)
	for i in 3:
		var a := TAU * i / 3.0
		var ball := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 1.0
		sm.height = 2.0
		ball.mesh = sm
		ball.material_override = bag_m
		ball.position = Vector3(BAG_RING * cos(a), HEIGHT - 0.1 + r * 0.6, BAG_RING * sin(a))
		ball.scale = Vector3.ONE * 1e-3
		ball.visible = false
		g.add_child(ball)
		bags.append(ball)
	var drogues := []
	for i in 2:
		var c := _canopy(2.515 * 0.7, DROGUE_UP, Vector3(cos(PI * i) * 2.0, 0.0, 0.0))
		g.add_child(c); drogues.append(c)
	var mains := []
	for i in 3:
		var a := TAU * i / 3.0 + 0.4
		var c := _canopy(25.45 * 0.7 / 2.0, MAINS_UP, Vector3(cos(a), 0.0, sin(a)) * 9.0)
		g.add_child(c); mains.append(c)
	g.set_meta("capsule", {"bags": bags, "drogues": drogues, "mains": mains, "bag_r": r})
	return {"group": g, "parts": parts}

## Pose the bags and canopies: `fill` 0–1 of the bags; `chute` "", "drogue" or "mains", `open` 0–1.
static func pose_model(g: Node3D, fill: float, chute: String, open: float) -> void:
	if g == null or not g.has_meta("capsule"): return
	var m: Dictionary = g.get_meta("capsule")
	var s := maxf(float(m.bag_r) * pow(clampf(fill, 0.0, 1.0), 1.0 / 3.0), 1e-3)
	for bag: Node3D in m.bags:
		bag.visible = fill > 0.0
		bag.scale = Vector3.ONE * s
	for set_ in [["drogue", m.drogues], ["mains", m.mains]]:
		for c: Node3D in set_[1]:
			c.visible = chute == set_[0]
			# Reefed, a canopy is long and narrow; open, wide.
			var o := clampf(open, 0.05, 1.0)
			c.scale = Vector3(o, lerpf(0.75, 1.0, o), o)

static func _lathe_node(pts: PackedVector2Array, segments: int, mat: Material, closed_bottom: bool) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in pts.size() - 1:
		var p0 := pts[k]; var p1 := pts[k + 1]
		for s in segments:
			var a0 := TAU * s / segments; var a1 := TAU * (s + 1) / segments
			var v00 := Vector3(p0.x * cos(a0), p0.y, p0.x * sin(a0)); var v01 := Vector3(p0.x * cos(a1), p0.y, p0.x * sin(a1))
			var v10 := Vector3(p1.x * cos(a0), p1.y, p1.x * sin(a0)); var v11 := Vector3(p1.x * cos(a1), p1.y, p1.x * sin(a1))
			for tri in [[v00, v10, v01], [v01, v10, v11]]:
				for q: Vector3 in tri: st.add_vertex(q)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi

# A flat patch on the cone's flank, `az` round from +x, centred `y` up, `size` across and along the slant.
static func _on_cone(az: float, y: float, size: Vector2, mat: Material, t: float, lift := 0.006) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	mi.mesh = q
	mi.material_override = mat
	var start_y := 0.719
	var r := MAX_R - SHOULDER * 0.4 - (y - start_y) * tan(t)
	var out := Vector3(cos(az), 0.0, sin(az))
	var n := (out * cos(t) + Vector3.UP * sin(t)).normalized()
	mi.position = out * (r + lift) + Vector3.UP * y
	mi.basis = Basis.looking_at(-n, Vector3.UP)
	return mi

# A canopy of orange and white gores on its lines, `up` m over the apex and `off` to the side.
static func _canopy(radius: float, up: float, off: Vector3) -> Node3D:
	var node := Node3D.new()
	node.position = Vector3(0.0, HEIGHT, 0.0)
	node.visible = false
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var gores := 16
	var rings := 5
	var top := off + Vector3(0.0, up, 0.0)
	for gi in gores:
		var col := Color(0.95, 0.42, 0.12) if gi % 2 == 0 else Color(0.95, 0.93, 0.9)
		for k in rings:
			var b0 := PI * 0.5 * k / rings; var b1 := PI * 0.5 * (k + 1) / rings
			var a0 := TAU * gi / gores; var a1 := TAU * (gi + 1) / gores
			var pt := func(a: float, b: float) -> Vector3: return top + Vector3(cos(a) * sin(b) * radius, cos(b) * radius * 0.55 - radius * 0.3, sin(a) * sin(b) * radius)
			for tri in [[pt.call(a0, b0), pt.call(a1, b0), pt.call(a0, b1)], [pt.call(a1, b0), pt.call(a1, b1), pt.call(a0, b1)]]:
				for q: Vector3 in tri:
					st.set_color(col)
					st.add_vertex(q)
	st.generate_normals()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.85
	var dome := MeshInstance3D.new()
	dome.mesh = st.commit()
	dome.material_override = m
	node.add_child(dome)
	# The lines, as thin quads from the skirt to the apex.
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in 8:
		var a := TAU * i / 8.0
		lines.surface_add_vertex(Vector3.ZERO)
		lines.surface_add_vertex(top + Vector3(cos(a) * radius, -radius * 0.3, sin(a) * radius))
	lines.surface_end()
	var lm := StandardMaterial3D.new()
	lm.albedo_color = Color(0.85, 0.82, 0.75)
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var li := MeshInstance3D.new()
	li.mesh = lines
	li.material_override = lm
	node.add_child(li)
	return node
