class_name LaunchSite
extends RefCounted

# Authored launch complexes with procedural fallback in metres.
# Measured skin envelopes define vehicle clearances; motion includes umbilicals,
# strongbacks and deluge. See model_sources/blender/AGENTS.md.

static var _mats := {}
## Diagnostic switch for checking that a fresh clone still renders its pads.
static var use_authored_pads := true
static func _std(name: String, hex: int, rough: float, metal: float) -> StandardMaterial3D:
	if _mats.has(name): return _mats[name]
	var m := StandardMaterial3D.new()
	m.resource_name = name
	m.albedo_color = Color.hex((hex << 8) | 0xff)
	m.roughness = rough
	m.metallic = metal
	m.metallic_specular = 0.5
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	MaterialDetail.register(m)
	_mats[name] = m
	return m

static func CONCRETE() -> StandardMaterial3D: return _std("concrete", 0x8d8d88, 0.95, 0.02)
static func DARKCON() -> StandardMaterial3D: return _std("darkcon", 0x5c5c58, 0.96, 0.02)
static func STEEL() -> StandardMaterial3D: return _std("steel", 0x7a8288, 0.62, 0.55)
static func PAINT() -> StandardMaterial3D: return _std("paint", 0x9c3f2e, 0.8, 0.1)
static func GREY() -> StandardMaterial3D: return _std("grey", 0x6e7276, 0.75, 0.35)
static func SCORCH() -> StandardMaterial3D: return _std("scorch", 0x2a2724, 0.98, 0.02)
static func WHITE() -> StandardMaterial3D: return _std("white", 0xc9ccd0, 0.8, 0.08)
static func SAFETY() -> StandardMaterial3D: return _std("safety-yellow", 0xd7ad38, 0.72, 0.04)
static func COPPER() -> StandardMaterial3D: return _std("oxidized-copper", 0x657a79, 0.58, 0.35)
static func ASPHALT() -> StandardMaterial3D: return _std("asphalt", 0x3b3d3f, 0.93, 0.0)
static func GRAVEL() -> StandardMaterial3D: return _std("gravel", 0x9a958a, 0.97, 0.0)
static func GLASS() -> StandardMaterial3D: return _std("glass", 0x1d2a33, 0.18, 0.25)
static func WATER() -> StandardMaterial3D: return _std("pond", 0x1f3a40, 0.10, 0.0)
static func SCRUB() -> StandardMaterial3D:
	var m := _std("scrub", 0x4a6740, 0.96, 0.0)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

# Decals are separate materials (see decal.gdshader), since the same concrete is
# structural elsewhere.
static var _decals := {}
static func decal(material: StandardMaterial3D, order: int = 1) -> ShaderMaterial:
	var key := "%s:%d" % [material.resource_name, order]
	if not _decals.has(key):
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/flight/decal.gdshader")
		m.set_shader_parameter("uColor", material.albedo_color)
		m.set_shader_parameter("uRoughness", material.roughness)
		m.set_shader_parameter("uMetallic", material.metallic)
		m.set_shader_parameter("uOrder", float(order))
		_decals[key] = m
	return _decals[key]

static func _node() -> Node3D:
	var n := Node3D.new()
	n.rotation_order = EULER_ORDER_XYZ
	return n

static func _mesh(g: CraftModel.Geo, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.rotation_order = EULER_ORDER_XYZ
	mi.mesh = CraftModel._to_mesh(g, m)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if m is StandardMaterial3D else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# A merged box soup: a lattice tower's thousands of struts as one mesh.
class Struts extends RefCounted:
	var g := CraftModel.Geo.new()
	var n := 0
	## A box from a→b with cross-section w×w, oriented to the segment.
	func strut(ax: float, ay: float, az: float, bx: float, by: float, bz: float, w: float) -> void:
		var d := Vector3(bx - ax, by - ay, bz - az)
		var L := d.length()
		if L < 1e-6: return
		d /= L
		var ref := Vector3(1, 0, 0) if absf(d.y) > 0.95 else Vector3(0, 1, 0)
		var u := d.cross(ref).normalized() * (w * 0.5)
		var v := d.cross(u).normalized() * (w * 0.5)
		var A := Vector3(ax, ay, az); var B := Vector3(bx, by, bz)
		var corners: Array[Vector3] = []
		for end in [A, B]:
			for sv in [[1, 1], [1, -1], [-1, -1], [-1, 1]]:
				corners.append(end + u * sv[0] + v * sv[1])
		var base := n
		for i in 8:
			g.pos.append(corners[i])
			# Flat-ish normals: a strut is thin enough that a radial normal
			# reads fine and costs no extra vertices.
			var c: Vector3 = corners[i] - (A if i < 4 else B)
			g.nrm.append(c.normalized() if c.length() > 0.0 else c)
		for f in [[0, 1, 2, 3], [7, 6, 5, 4], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]:
			g.idx.append_array([base + f[0], base + f[1], base + f[2], base + f[0], base + f[2], base + f[3]])
		n += 8

## A square lattice tower: four legs, ties every `bay`, and diagonals in every bay
## of every face (they carry the wind load, and make it read as a lattice).
static func lattice_tower(H: float, side: float, opts: Dictionary = {}) -> MeshInstance3D:
	var bay: float = opts.get("bay", 6.0)
	var leg: float = opts.get("leg", 0.55)
	var brace: float = opts.get("brace", 0.28)
	var s := Struts.new()
	var h := side / 2.0
	var legs := [[-h, -h], [h, -h], [h, h], [-h, h]]
	for l in legs: s.strut(l[0], 0.0, l[1], l[0], H, l[1], leg)
	var bays := maxi(2, int(U.jround(H / bay)))
	var dy := H / bays
	for i in bays + 1:
		var y := i * dy
		for k in 4:
			var p1: Array = legs[k]; var p2: Array = legs[(k + 1) % 4]
			s.strut(p1[0], y, p1[1], p2[0], y, p2[1], brace)
	for i in bays:
		var y0 := i * dy; var y1 := y0 + dy
		for k in 4:
			var p1: Array = legs[k]; var p2: Array = legs[(k + 1) % 4]
			# alternate the diagonal's sense per bay, as a real braced frame does
			if i % 2 == 0: s.strut(p1[0], y0, p1[1], p2[0], y1, p2[1], brace)
			else: s.strut(p2[0], y0, p2[1], p1[0], y1, p1[1], brace)
	return _mesh(s.g, STEEL())

## A horizontal truss boom — the swing arms, the catch arms, the crane jib.
static func truss(L: float, w: float, d: float, chord: float = 0.22) -> MeshInstance3D:
	var s := Struts.new()
	var hw := w / 2.0
	for z in [-hw, hw]:
		for y in [0.0, d]: s.strut(0.0, y, z, L, y, z, chord)
	var bays := maxi(2, int(U.jround(L / (d * 1.2))))
	for i in bays + 1:
		var x := (float(i) / bays) * L
		for z in [-hw, hw]: s.strut(x, 0.0, z, x, d, z, chord * 0.8)
		s.strut(x, 0.0, -hw, x, 0.0, hw, chord * 0.8)
		s.strut(x, d, -hw, x, d, hw, chord * 0.8)
	for i in bays:
		var x0 := (float(i) / bays) * L; var x1 := (float(i + 1) / bays) * L
		for z in [-hw, hw]: s.strut(x0, 0.0, z, x1, d, z, chord * 0.8)
	return _mesh(s.g, STEEL())

static func box(w: float, h: float, d: float, m: Material, x := 0.0, y := 0.0, z := 0.0) -> MeshInstance3D:
	var b := _mesh(CraftModel._box(w, h, d), m)
	b.position = Vector3(x, y + h / 2.0, z)
	return b

## Rigid service plumbing between two support points. Unlike decorative lines,
## these pipes catch light and cast a useful scale shadow beside the tower.
static func pipe_between(a: Vector3, b: Vector3, radius: float, m: Material) -> MeshInstance3D:
	var d := b - a
	var p := _mesh(CraftModel._cylinder(radius, radius, d.length(), 12, 1, true), m)
	p.position = (a + b) * 0.5
	p.basis = Basis(Quaternion(Vector3.UP, d.normalized()))
	return p

## Annulus with one radial segment, in XY facing +Z.
static func _ring(inner: float, outer: float, seg: int) -> CraftModel.Geo:
	var g := CraftModel.Geo.new()
	for j in 2:
		var r := inner + float(j) * (outer - inner)
		for i in seg + 1:
			var a := float(i) / seg * TAU
			g.pos.append(Vector3(r * cos(a), r * sin(a), 0.0)); g.nrm.append(Vector3(0, 0, 1))
	for i in seg:
		var a := i; var b := i + seg + 1; var c := i + seg + 2; var d := i + 1
		g.idx.append_array([a, b, d, b, c, d])
	return g

# THE VEHICLE'S SKIN, MEASURED. Anything that reaches toward the vehicle (swing
# arm, white room, vent hood, umbilical plate) stops at the skin. This is the
# craft's own triangles (authored or procedural), bucketed by height; a query is a
# lane, a rectangle in (height, across) from some azimuth. Triangles in the lane
# are clipped to it, so a fin between samples can't be missed. Coordinates are the
# craft's: y = 0 on the deck, stack axis at x = z = 0; the site is yawed to the
# craft's roll, so the axes coincide.
class Envelope extends RefCounted:
	const BIN := 1.0
	var tri := PackedVector3Array()      # three vertices per triangle
	var bins: Array = []                 # height bin → PackedInt32Array of triangles
	## Per height bin, the farthest the skin comes from the axis in any
	## direction — a cheap bound that rules most queries out before any clip.
	var r_max := PackedFloat32Array()
	var y_min := INF
	var y_max := -INF
	var _stamp := PackedInt32Array()
	var _query := 0

	func _init(root: Node3D) -> void:
		if root != null: _collect(root, Transform3D.IDENTITY)
		var n := tri.size() / 3
		if n == 0: return
		var nb := int(ceil((y_max - y_min) / BIN)) + 1
		bins.resize(nb)
		r_max.resize(nb)
		r_max.fill(0.0)
		for b in nb: bins[b] = PackedInt32Array()
		for t in n:
			var a := tri[t * 3]; var b2 := tri[t * 3 + 1]; var c := tri[t * 3 + 2]
			var lo := int(floor((minf(a.y, minf(b2.y, c.y)) - y_min) / BIN))
			var hi := int(floor((maxf(a.y, maxf(b2.y, c.y)) - y_min) / BIN))
			var r := sqrt(maxf(a.x * a.x + a.z * a.z, maxf(b2.x * b2.x + b2.z * b2.z, c.x * c.x + c.z * c.z)))
			for b in range(lo, hi + 1):
				bins[b].append(t)
				r_max[b] = maxf(r_max[b], r)
		_stamp.resize(n)
		_stamp.fill(-1)

	func _collect(n: Node, xf: Transform3D) -> void:
		if n is Node3D and not (n as Node3D).visible: return
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mesh := (n as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES: continue
				var arr := mesh.surface_get_arrays(s)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var ix = arr[Mesh.ARRAY_INDEX]
				var count: int = ix.size() if ix != null and ix.size() > 0 else v.size()
				for i in count:
					var p: Vector3 = xf * v[ix[i] if ix != null and ix.size() > 0 else i]
					tri.append(p)
					y_min = minf(y_min, p.y); y_max = maxf(y_max, p.y)
		for c in n.get_children():
			if c is Node3D: _collect(c, xf * (c as Node3D).transform)

	## How far from the axis the skin comes toward azimuth `az`, inside y ∈ [ya, yb],
	## across ∈ [za, zb]. `az` is where the structure approaches FROM (π: from −x);
	## `across` is to the left of that approach. −INF if the lane is empty.
	func standoff(ya: float, yb: float, za: float, zb: float, az: float = PI) -> float:
		if bins.is_empty(): return -INF
		_query += 1
		var u := Vector3(cos(az), 0.0, sin(az))     # outward, toward the structure
		var w := Vector3(-u.z, 0.0, u.x)            # across the lane
		var best := -INF
		var lo := clampi(int(floor((ya - y_min) / BIN)), 0, bins.size() - 1)
		var hi := clampi(int(floor((yb - y_min) / BIN)), 0, bins.size() - 1)
		if yb < y_min or ya > y_max: return -INF
		for b in range(lo, hi + 1):
			for t: int in bins[b]:
				if _stamp[t] == _query: continue
				_stamp[t] = _query
				# (out, y, across): out is distance from the axis toward the structure
				var p0 := tri[t * 3]; var p1 := tri[t * 3 + 1]; var p2 := tri[t * 3 + 2]
				var q0 := Vector3(p0.dot(u), p0.y, p0.dot(w))
				var q1 := Vector3(p1.dot(u), p1.y, p1.dot(w))
				var q2 := Vector3(p2.dot(u), p2.y, p2.dot(w))
				# wholly outside the lane, or no farther out than what is found
				if maxf(q0.y, maxf(q1.y, q2.y)) < ya or minf(q0.y, minf(q1.y, q2.y)) > yb: continue
				if maxf(q0.z, maxf(q1.z, q2.z)) < za or minf(q0.z, minf(q1.z, q2.z)) > zb: continue
				if maxf(q0.x, maxf(q1.x, q2.x)) <= best: continue
				var poly: Array[Vector3] = [q0, q1, q2]
				poly = _clip(poly, 1, ya, 1.0)
				poly = _clip(poly, 1, yb, -1.0)
				poly = _clip(poly, 2, za, 1.0)
				poly = _clip(poly, 2, zb, -1.0)
				for q in poly: best = maxf(best, q.x)
		return best

	## Sutherland–Hodgman against one axis-aligned plane: keep s·(p[axis] − at) ≥ 0.
	static func _clip(poly: Array[Vector3], axis: int, at: float, s: float) -> Array[Vector3]:
		var out: Array[Vector3] = []
		var n := poly.size()
		for i in n:
			var a := poly[i]; var b := poly[(i + 1) % n]
			var da := s * (a[axis] - at); var db := s * (b[axis] - at)
			if da >= 0.0: out.append(a)
			if (da >= 0.0) != (db >= 0.0):
				out.append(a.lerp(b, da / (da - db)))
		return out

	## The farthest the skin comes from the axis anywhere in y ∈ [ya, yb].
	func radius_in(ya: float, yb: float) -> float:
		if bins.is_empty() or yb < y_min or ya > y_max: return 0.0
		var r := 0.0
		for b in range(clampi(int(floor((ya - y_min) / BIN)), 0, bins.size() - 1),
				clampi(int(floor((yb - y_min) / BIN)), 0, bins.size() - 1) + 1):
			r = maxf(r, r_max[b])
		return r

	## The highest point of the stack within `r` of its axis — where a vent
	## hood has to sit.
	func tip(r: float) -> float:
		var top := -INF
		for i in tri.size():
			var p := tri[i]
			if p.x * p.x + p.z * p.z <= r * r: top = maxf(top, p.y)
		return top

# Deck height above terrain: LC-39A's hardstand is a 12.8 m mound. This also keeps
# the mound's top off the ground patch; coplanar, they z-fight.
const PAD_RISE := 12.8

## The raised hardstand: an octagonal mound with sloped flanks. Its top face is
## at local y = 0 — the pad deck — and grade is PAD_RISE below that.
static func hardstand(across: float) -> MeshInstance3D:
	var m := _mesh(CraftModel._cylinder(across * 0.5, across * 0.5 + PAD_RISE * 2.6, PAD_RISE, 8, 1), CONCRETE())
	m.position.y = -PAD_RISE * 0.5   # top face at local y = 0, i.e. at the pad deck
	m.rotation.y = PI / 8.0
	return m

## THE CRAWLERWAY is a ramp up the mound's flank (a 5% grade, the most a loaded
## crawler may climb). Stations in (z, y) along the run, widened into a ribbon.
static func crawlerway(top_r: float, width: float = 40.0, len: float = 1400.0) -> MeshInstance3D:
	var toe := top_r + PAD_RISE * 2.6                 # where the flank meets grade
	var stations := [[0.0, 0.0], [-top_r, 0.0], [-toe, -PAD_RISE], [-len, -PAD_RISE]]
	var g := CraftModel.Geo.new()
	for i in stations.size():
		var z: float = stations[i][0]; var y: float = stations[i][1]
		g.pos.append(Vector3(-width / 2.0, y, z)); g.pos.append(Vector3(width / 2.0, y, z))
		g.nrm.append(Vector3.UP); g.nrm.append(Vector3.UP)
		if i > 0:
			# Counter-clockwise seen from above; the stations run toward −z.
			var b := (i - 1) * 2
			g.idx.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])
	return _mesh(g, decal(DARKCON()))

## Narrow edge paint follows the same grade as the crawlerway, including its
## ramp down the mound. A flat stripe would float above the road beyond it.
static func crawlerway_marks(top_r: float, width: float = 40.0, len: float = 1400.0) -> MeshInstance3D:
	var toe := top_r + PAD_RISE * 2.6
	var stations := [[0.0, 0.025], [-top_r, 0.025], [-toe, -PAD_RISE + 0.025], [-len, -PAD_RISE + 0.025]]
	var g := CraftModel.Geo.new()
	for side in [-1.0, 1.0]:
		var x: float = float(side) * (width * 0.5 - 0.7)
		var base := g.pos.size()
		for point in stations:
			g.pos.append(Vector3(x - 0.09, point[1], point[0]))
			g.pos.append(Vector3(x + 0.09, point[1], point[0]))
			g.nrm.append(Vector3.UP); g.nrm.append(Vector3.UP)
		for i in stations.size() - 1:
			var a := base + i * 2
			g.idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	return _mesh(g, decal(SAFETY(), 3))

## The flame trench and the wedge deflector that turns the exhaust 90° out both ends.
static func flame_trench(len: float, wide: float, deep: float) -> Node3D:
	var g := _node()
	var wall := 2.5
	for z in [-(wide / 2.0 + wall / 2.0), wide / 2.0 + wall / 2.0]:
		g.add_child(box(len, deep, wall, DARKCON(), 0.0, -deep, z))
	g.add_child(box(len, 1.2, wide, SCORCH(), 0.0, -deep, 0.0))
	# the wedge
	var wedge := _mesh(CraftModel._cylinder(0.01, wide * 0.48, deep * 0.85, 3, 1), SCORCH())
	wedge.rotation = Vector3(0.0, PI / 2.0, 0.0)
	wedge.position.y = -deep + deep * 0.85 / 2.0
	var holder := _node()
	holder.add_child(wedge)
	holder.rotation.y = PI / 2.0
	g.add_child(holder)
	return g

## Three masts on a catenary, which is what a real lightning protection system
## is: the wire is the conductor and the masts only hold it up.
static func lightning_masts(R: float, H: float) -> Node3D:
	var g := _node()
	var tops: Array[Vector3] = []
	for i in 3:
		var a := (float(i) / 3.0) * PI * 2.0 + PI / 6.0
		var x := cos(a) * R; var z := sin(a) * R
		var m := lattice_tower(H * 0.72, 4.5, {"bay": 7.0, "leg": 0.3, "brace": 0.16})
		m.position = Vector3(x, 0.0, z)
		g.add_child(m)
		var spire := _mesh(CraftModel._cylinder(0.12, 0.5, H * 0.28, 6), STEEL())
		spire.position = Vector3(x, H * 0.72 + H * 0.14, z)
		g.add_child(spire)
		tops.append(Vector3(x, H, z))
	# catenary: y = a·cosh(x/a) — the shape a hanging cable actually takes, and
	# over this span it sags about a tenth of the run.
	var pts := PackedVector3Array()
	for i in 3:
		var A := tops[i]; var B := tops[(i + 1) % 3]
		var span := A.distance_to(B); var sag := span * 0.10
		var a := span * span / (8.0 * sag)
		for t in 17:
			var u := float(t) / 16.0; var x := (u - 0.5) * span
			var drop := a * (cosh(x / a) - cosh(span / (2.0 * a)))
			var p := A.lerp(B, u)
			p.y = A.y + drop
			pts.append(p)
	# Draw the catenary as one continuous strip.
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	var lm := ArrayMesh.new()
	lm.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arr)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.hex(0x3a3f44ff)
	var line := MeshInstance3D.new()
	line.mesh = lm
	line.material_override = mat
	# No shadow: a 2 cm conductor 100 m up casts only penumbra, but the shadow map drew
	# a crawling texel-wide stripe.
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.add_child(line)
	return g

## The sound-suppression water tower. 88 m, and the tank on top holds 1.135 Ml
## — released in 41 seconds, starting before ignition.
static func water_tower(H: float = 88.0) -> Node3D:
	var g := _node()
	g.add_child(lattice_tower(H * 0.78, 9.0, {"bay": 8.0, "leg": 0.4, "brace": 0.2}))
	var tank := _mesh(CraftModel._cylinder(7.5, 7.5, H * 0.2, 20), WHITE())
	tank.position.y = H * 0.78 + H * 0.1
	g.add_child(tank)
	var cap := _mesh(CraftModel._sphere(7.5, 20, 8, 0.0, TAU, 0.0, PI / 2.0), WHITE())
	cap.position.y = H * 0.78 + H * 0.2
	g.add_child(cap)
	return g

## Expansion joints, drawn by ground_mark.gdshader on one disc over the hardstand.
static func hardstand_joints(radius: float) -> MeshInstance3D:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/flight/ground_mark.gdshader")
	m.set_shader_parameter("uMode", 0)
	m.set_shader_parameter("uOrder", 1.0)
	m.set_shader_parameter("uExtent", radius * 0.9)
	var disc := _mesh(CraftModel._circle(radius * 0.92, 48), m)
	disc.rotation.x = -PI / 2.0
	return disc

## The burnt apron under the vehicle, as a multiply over the concrete (see
## ground_mark.gdshader): soot darkens what is lit rather than replacing it.
static func scorch_apron(radius: float) -> MeshInstance3D:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/flight/ground_mark.gdshader")
	m.set_shader_parameter("uMode", 1)
	m.set_shader_parameter("uOrder", 2.0)
	m.set_shader_parameter("uScorchRadius", radius)
	var disc := _mesh(CraftModel._circle(radius * 1.25, 64), m)
	disc.rotation.x = -PI / 2.0
	return disc

## Equipment outside the launch mount's blast area.
static func deck_services(radius: float) -> Node3D:
	var g := _node()
	for side in [-1.0, 1.0]:
		var x: float = float(side) * radius * 0.66
		var z := radius * 0.27
		g.add_child(box(14.0, 0.18, 7.0, DARKCON(), x, 0.0, z))
		for j in 3:
			var bx := x + (float(j) - 1.0) * 4.5
			g.add_child(box(3.7, 2.2, 2.7, GREY(), bx, 0.18, z))
			g.add_child(box(3.7, 0.14, 0.45, DARKCON(), bx, 1.65, z + 1.39))
			g.add_child(box(0.16, 0.8, 2.7, SAFETY(), bx - 1.9, 0.18, z))
		var pipe_start := Vector3(x, 0.72, z - 4.3)
		var pipe_end := Vector3(x * 0.5, 0.72, z - 18.0)
		g.add_child(pipe_between(pipe_start, pipe_end, 0.16, COPPER()))
		# A pipe run stands on sleepers and ends at something. Drawn as a bare
		# line hovering over the slab it read as a crack in the concrete.
		var run := pipe_end - pipe_start
		var n_sup := int(run.length() / 3.5)
		for k in range(1, n_sup + 1):
			var at := pipe_start + run * (float(k) / float(n_sup + 1))
			var sleeper := box(0.3, 0.56, 0.9, STEEL(), at.x, 0.0, at.z)
			sleeper.rotation.y = atan2(run.x, run.z)
			g.add_child(sleeper)
		g.add_child(box(1.6, 1.1, 1.6, GREY(), pipe_end.x, 0.0, pipe_end.z))
	return g

## Ground support: cryogenic storage, pump houses, piping and lights, simplified.
static func support_facilities(radius: float, pad_style: String, lamps_only := false) -> Node3D:
	var g := _node()
	if lamps_only:
		_mound_lamps(g, radius)
		return g
	var farm := _node()
	# At grade, so clear of the mound's flank (radius + 2.6 × PAD_RISE).
	farm.position = Vector3(-radius - 95.0, 0.0, -radius * 0.35)
	g.add_child(farm)
	farm.add_child(box(90.0, 0.24, 56.0, DARKCON()))
	if pad_style == "lut" or pad_style == "fss":
		for x in [-22.0, 22.0]:
			var tank := _mesh(CraftModel._sphere(10.5, 24, 16), WHITE())
			tank.position = Vector3(x, 12.0, 2.0)
			farm.add_child(tank)
			for z in [-7.0, 7.0]:
				farm.add_child(box(2.8, 2.0, 2.0, CONCRETE(), x, 0.25, z))
	else:
		for i in 4:
			var x := -31.0 + float(i) * 20.5
			var tank := _mesh(CraftModel._cylinder(5.8, 5.8, 22.0, 20), WHITE())
			tank.position = Vector3(x, 11.25, -2.0)
			farm.add_child(tank)
			var dome := _mesh(CraftModel._sphere(5.8, 20, 10, 0.0, TAU, 0.0, PI / 2.0), WHITE())
			dome.position = Vector3(x, 22.25, -2.0)
			farm.add_child(dome)
	# The low pump building and its roof plant read against the storage vessels.
	farm.add_child(box(27.0, 5.6, 11.0, GREY(), 0.0, 0.25, 20.0))
	farm.add_child(box(29.0, 0.35, 12.5, DARKCON(), 0.0, 5.85, 20.0))
	for x in [-8.0, 0.0, 8.0]:
		farm.add_child(box(3.6, 2.7, 0.08, STEEL(), x, 0.4, 25.56))
	for z in [14.0, 17.0]:
		farm.add_child(pipe_between(Vector3(-39.0, 1.0, z), Vector3(38.0, 1.0, z), 0.18, COPPER()))

	var service := _node()
	service.position = Vector3(radius + 62.0, 0.0, -radius * 0.55)
	g.add_child(service)
	service.add_child(box(32.0, 0.20, 26.0, DARKCON()))
	service.add_child(box(22.0, 7.0, 16.0, GREY(), 0.0, 0.20, 0.0))
	service.add_child(box(23.0, 0.35, 17.0, WHITE(), 0.0, 7.20, 0.0))
	for x in [-6.0, 0.0, 6.0]:
		service.add_child(box(3.8, 3.3, 0.09, STEEL(), x, 0.25, 8.06))
	for x in [-7.0, 7.0]:
		service.add_child(box(3.0, 1.5, 2.7, WHITE(), x, 7.55, 0.0))
	_mound_lamps(g, radius)
	return g

## Short lamp poles make the apron and mound size legible from the pad camera.
static func _mound_lamps(g: Node3D, radius: float) -> void:
	for x_sign in [-1.0, 1.0]:
		for z_sign in [-1.0, 1.0]:
			var x: float = float(x_sign) * radius * 0.66
			var z: float = float(z_sign) * radius * 0.66
			g.add_child(pipe_between(Vector3(x, PAD_RISE, z), Vector3(x, PAD_RISE + 15.0, z), 0.16, STEEL()))
			for side in [-1.0, 1.0]:
				g.add_child(box(1.8, 0.75, 0.6, WHITE(), x + side * 1.0, PAD_RISE + 14.7, z))

# THE REST OF THE COMPLEX — what a launch site is when it is not the pad.
## One draw call per material: parts go into a shared buffer per material and are
## emitted as one mesh.
class Batch extends RefCounted:
	var geos := {}          # Material → CraftModel.Geo
	var shadowless := {}    # Material → true: too thin to cast a shadow worth having
	var keep_out: Array = [] # Rect2 footprints, for the scrub
	func add(g: CraftModel.Geo, m: Material, xf: Transform3D) -> void:
		if not geos.has(m): geos[m] = CraftModel.Geo.new()
		var dst: CraftModel.Geo = geos[m]
		var base := dst.pos.size()
		for i in g.pos.size():
			dst.pos.append(xf * g.pos[i])
			dst.nrm.append(xf.basis * g.nrm[i])
		for i in g.idx: dst.idx.append(base + i)
	## An upright box standing on `at` (its base centre), turned by `yaw`.
	func box(w: float, h: float, d: float, m: Material, at: Vector3, yaw := 0.0) -> void:
		add(CraftModel._box(w, h, d), m, Transform3D(Basis(Vector3.UP, yaw), at + Vector3(0.0, h * 0.5, 0.0)))
	## A vertical drum standing on `at`.
	func drum(r: float, h: float, m: Material, at: Vector3, seg := 18) -> void:
		add(CraftModel._cylinder(r, r, h, seg), m, Transform3D(Basis(), at + Vector3(0.0, h * 0.5, 0.0)))
	## A horizontal drum centred on `at`, its axis along x turned by `yaw`.
	func hdrum(r: float, len: float, m: Material, at: Vector3, yaw := 0.0) -> void:
		var b := Basis(Vector3.UP, yaw) * Basis(Vector3(0, 0, 1), PI / 2.0)
		add(CraftModel._cylinder(r, r, len, 14), m, Transform3D(b, at))
	func ball(r: float, m: Material, at: Vector3) -> void:
		add(CraftModel._sphere(r, 20, 12), m, Transform3D(Basis(), at))
	## A flat ribbon on the ground from a to b (a road, a gravel path).
	func strip(a: Vector2, b: Vector2, width: float, m: Material, lift := 0.03) -> void:
		var d := (b - a)
		var L := d.length()
		if L < 1e-3: return
		var g := CraftModel.Geo.new()
		var n := Vector2(-d.y, d.x) / L * (width * 0.5)
		for p in [a + n, a - n, b + n, b - n]:
			g.pos.append(Vector3(p.x, lift, p.y)); g.nrm.append(Vector3.UP)
		g.idx.append_array([0, 2, 1, 1, 2, 3] if d.cross(n) > 0.0 else [0, 1, 2, 1, 3, 2])
		add(g, m, Transform3D())
	func footprint(c: Vector2, w: float, d: float, pad := 6.0) -> void:
		keep_out.append(Rect2(c.x - w * 0.5 - pad, c.y - d * 0.5 - pad, w + 2.0 * pad, d + 2.0 * pad))
	func build(parent: Node3D) -> void:
		for m in geos:
			var mi := LaunchSite._mesh(geos[m], m)
			if shadowless.has(m): mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(mi)

## An office block: glazing bands a few cm proud of the wall, roof plant, parapet.
static func _office(B: Batch, c: Vector2, w: float, d: float, floors: int, yaw := 0.0) -> void:
	var h := 3.9 * float(floors) + 1.2
	var rot := Basis(Vector3.UP, yaw)
	var at := Vector3(c.x, 0.0, c.y)
	B.box(w, h, d, WHITE(), at, yaw)
	B.box(w + 0.6, 0.5, d + 0.6, GREY(), at + Vector3(0.0, h, 0.0), yaw)
	for f in floors:
		var y := 1.3 + 3.9 * float(f)
		for side in [-1.0, 1.0]:
			B.box(w - 3.0, 1.6, 0.12, GLASS(), at + rot * Vector3(0.0, y, float(side) * (d * 0.5 + 0.06)), yaw)
	for k in 3:
		B.box(4.2, 2.2, 3.0, GREY(), at + rot * Vector3((float(k) - 1.0) * w * 0.25, h + 0.5, 0.0), yaw)
	B.footprint(c, w * 1.1 + d * 0.3, d * 1.1 + w * 0.3)

## A car park with cars in it — the one thing on a launch site that says
## people work here. Instanced, with a colour each.
static func _car_park(g: Node3D, B: Batch, c: Vector2, rows: int, per_row: int, yaw: float, seed: int) -> void:
	var rot := Basis(Vector3.UP, yaw)
	var W := float(per_row) * 2.9 + 6.0
	var D := float(rows) * 6.2 + 8.0
	# the lot, as a decal on the ground
	var lot := CraftModel.Geo.new()
	for p in [Vector2(-W, -D), Vector2(W, -D), Vector2(-W, D), Vector2(W, D)]:
		var q := rot * Vector3(p.x * 0.5, 0.0, p.y * 0.5)
		lot.pos.append(Vector3(c.x + q.x, 0.04, c.y + q.z)); lot.nrm.append(Vector3.UP)
	lot.idx.append_array([0, 2, 1, 1, 2, 3])
	var lm := _mesh(lot, decal(ASPHALT(), 2))
	g.add_child(lm)
	B.footprint(c, maxf(W, D), maxf(W, D), 2.0)
	var body := CraftModel.Geo.new()
	for part in [[Vector3(4.5, 0.8, 1.8), 0.35], [Vector3(2.5, 0.65, 1.6), 1.15]]:
		var bx := CraftModel._box(part[0].x, part[0].y, part[0].z)
		for i in bx.pos.size():
			body.pos.append(bx.pos[i] + Vector3(-0.2 if part[1] > 1.0 else 0.0, part[1] + part[0].y * 0.5 - 0.35, 0.0))
			body.nrm.append(bx.nrm[i])
		var base := body.pos.size() - bx.pos.size()
		for i in bx.idx: body.idx.append(base + i)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.35
	mat.metallic = 0.2
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = CraftModel._to_mesh(body, mat)
	mm.instance_count = rows * per_row
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var PAINT_COLS := [Color(0.85, 0.86, 0.87), Color(0.06, 0.06, 0.07), Color(0.45, 0.47, 0.5),
		Color(0.62, 0.64, 0.66), Color(0.12, 0.2, 0.38), Color(0.5, 0.07, 0.06), Color(0.9, 0.9, 0.88)]
	var n := 0
	for rrow in rows:
		for k in per_row:
			if rng.randf() < 0.28: continue    # the empty bays
			var local := Vector3((float(k) - float(per_row - 1) * 0.5) * 2.9, 0.0,
				(float(rrow) - float(rows - 1) * 0.5) * 6.2)
			var q := rot * local
			var face := yaw + PI / 2.0 + (PI if rrow % 2 == 1 else 0.0) + rng.randf_range(-0.05, 0.05)
			mm.set_instance_transform(n, Transform3D(Basis(Vector3.UP, face), Vector3(c.x + q.x, 0.0, c.y + q.z)))
			mm.set_instance_color(n, PAINT_COLS[rng.randi() % PAINT_COLS.size()])
			n += 1
	mm.visible_instance_count = n
	var cars := MultiMeshInstance3D.new()
	cars.name = "cars"
	cars.multimesh = mm
	g.add_child(cars)

## THE GROUNDS around a pad, from the LC-39A/B, SLC-40 and Starbase site plans:
## perimeter road and fence, LOX and LH2 farms on opposite sides (with the hydrogen
## burn pond and flare), gas bottle racks, substation, operations building and car
## park, floodlights, retention pond, and Falcon's integration hangar. Real sizes and
## real relationships, not survey positions.
static func complex_grounds(radius: float, style: String, authored := false) -> Array:
	var g := _node()
	g.name = "grounds"
	var B := Batch.new()
	var toe := radius + PAD_RISE * 2.6 + 8.0            # the mound's footprint
	var Rp := radius + 300.0                            # perimeter road
	# perimeter road (an octagon, broken where the crawlerway crosses it)
	var roads := Batch.new()
	var ring: Array[Vector2] = []
	for i in 8:
		var a := (float(i) + 0.5) * TAU / 8.0
		ring.append(Vector2(cos(a), sin(a)) * Rp)
	for i in 8:
		var a: Vector2 = ring[i]; var b: Vector2 = ring[(i + 1) % 8]
		# the edge the crawlerway (x ≈ 0, z < 0) runs through
		if a.y < 0.0 and b.y < 0.0 and signf(a.x) != signf(b.x):
			var cut_a := a.lerp(b, (a.x - 24.0 * signf(a.x)) / (a.x - b.x))
			var cut_b := a.lerp(b, (a.x + 24.0 * signf(a.x)) / (a.x - b.x))
			roads.strip(a, cut_a, 8.0, ASPHALT()); roads.strip(cut_b, b, 8.0, ASPHALT())
		else:
			roads.strip(a, b, 8.0, ASPHALT())
	# fence: posts every 12 m and three strands, just outside the road
	var Rf := Rp + 22.0
	var fence := Struts.new()
	for i in 8:
		var a0 := (float(i) + 0.5) * TAU / 8.0
		var a1 := (float(i) + 1.5) * TAU / 8.0
		var A := Vector2(cos(a0), sin(a0)) * Rf
		var Bv := Vector2(cos(a1), sin(a1)) * Rf
		var n := int((Bv - A).length() / 12.0)
		for k in n + 1:
			var p := A.lerp(Bv, float(k) / float(n))
			if absf(p.x) < 26.0 and p.y < 0.0: continue
			fence.strut(p.x, 0.0, p.y, p.x, 2.4, p.y, 0.09)
		for hgt in [0.5, 1.4, 2.3]:
			fence.strut(A.x, hgt, A.y, Bv.x, hgt, Bv.y, 0.025)
	var fm := _mesh(fence.g, STEEL())
	fm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.add_child(fm)

	# the second cryogen farm: LH2 on the KSC pads (a 3200 m³ sphere), vaporizers
	# and the burn pond.
	var h2 := Vector2(toe + 95.0, radius * 0.15)
	if authored:
		_grounds_common(g, B, roads, radius, Rp, Rf, toe, true)
		return _grounds_finish(g, B, roads)
	B.box(62.0, 0.25, 48.0, DARKCON(), Vector3(h2.x, 0.0, h2.y))
	if style == "lut" or style == "fss":
		B.ball(10.5, WHITE(), Vector3(h2.x, 12.5, h2.y))
		for k in 8:
			var a := float(k) * TAU / 8.0
			B.box(1.1, 8.0, 1.1, CONCRETE(), Vector3(h2.x + cos(a) * 8.2, 0.25, h2.y + sin(a) * 8.2))
	else:
		# a horizontal cryogen tank row (SLC-40 / Starbase style)
		for k in 3:
			B.hdrum(3.2, 32.0, WHITE(), Vector3(h2.x, 4.2, h2.y - 12.0 + float(k) * 12.0))
			for s in [-11.0, 11.0]:
				B.box(1.4, 1.2, 6.0, CONCRETE(), Vector3(h2.x + s, 0.25, h2.y - 12.0 + float(k) * 12.0))
	for k in 4:
		B.box(2.4, 7.0, 2.4, STEEL(), Vector3(h2.x - 22.0 + float(k) * 3.4, 0.25, h2.y + 19.0))
	B.footprint(h2, 62.0, 48.0)
	var pond := Vector2(h2.x + 70.0, h2.y + 40.0)
	B.box(34.0, 0.6, 34.0, DARKCON(), Vector3(pond.x, 0.0, pond.y))
	var water := CraftModel.Geo.new()
	for p in [Vector2(-15, -15), Vector2(15, -15), Vector2(-15, 15), Vector2(15, 15)]:
		water.pos.append(Vector3(pond.x + p.x, 0.62, pond.y + p.y)); water.nrm.append(Vector3.UP)
	water.idx.append_array([0, 2, 1, 1, 2, 3])
	g.add_child(_mesh(water, decal(WATER(), 1)))
	g.add_child(pipe_between(Vector3(pond.x + 12.0, 0.6, pond.y), Vector3(pond.x + 12.0, 24.0, pond.y), 0.35, STEEL()))
	B.footprint(pond, 34.0, 34.0)
	roads.strip(Vector2(Rp * 0.924, h2.y), Vector2(h2.x + 31.0, h2.y), 6.0, ASPHALT())

	# high-pressure gas: nitrogen and helium in racks of long bottles
	var gas := Vector2(radius * 0.35, toe + 70.0)
	B.box(44.0, 0.25, 26.0, DARKCON(), Vector3(gas.x, 0.0, gas.y))
	for row in 2:
		for k in 4:
			var at := Vector3(gas.x, 1.4 + float(row) * 2.3, gas.y - 7.5 + float(k) * 5.0)
			B.hdrum(1.0, 34.0, GREY(), at)
		for s in [-14.0, 0.0, 14.0]:
			B.box(0.5, 2.6 + float(row) * 2.3, 20.0, STEEL(), Vector3(gas.x + s, 0.25, gas.y))
	B.footprint(gas, 44.0, 26.0)
	roads.strip(Vector2(gas.x, gas.y + 13.0), Vector2(gas.x, Rp * 0.924), 6.0, ASPHALT())

	# electrical substation: gravel, transformers, bus structure, fence
	var sub := Vector2(-radius * 0.45, toe + 95.0)
	B.box(42.0, 0.12, 30.0, GRAVEL(), Vector3(sub.x, 0.0, sub.y))
	for k in 3:
		var x := sub.x - 12.0 + float(k) * 12.0
		B.box(4.2, 3.6, 3.0, GREY(), Vector3(x, 0.12, sub.y + 4.0))
		for f in 4:
			B.box(0.14, 2.8, 1.4, GREY(), Vector3(x - 2.2 + float(f) * 0.12, 0.3, sub.y + 4.0))
	var bus := Struts.new()
	for k in 4:
		var x := sub.x - 18.0 + float(k) * 12.0
		bus.strut(x, 0.12, sub.y - 8.0, x, 9.0, sub.y - 8.0, 0.35)
	bus.strut(sub.x - 18.0, 9.0, sub.y - 8.0, sub.x + 18.0, 9.0, sub.y - 8.0, 0.3)
	bus.strut(sub.x - 18.0, 7.0, sub.y - 8.0, sub.x + 18.0, 7.0, sub.y - 8.0, 0.2)
	g.add_child(_mesh(bus.g, STEEL()))
	B.footprint(sub, 42.0, 30.0)

	_grounds_common(g, B, roads, radius, Rp, Rf, toe, false)

	# floodlight towers, the tall landmarks every pad has at night
	for k in 4:
		var a := (float(k) + 0.5) * TAU / 4.0 + 0.2
		var p := Vector2(cos(a), sin(a)) * (Rp - 40.0)
		if absf(p.x) < 40.0 and p.y < 0.0: p.x += 60.0
		g.add_child(pipe_between(Vector3(p.x, 0.0, p.y), Vector3(p.x, 34.0, p.y), 0.42, STEEL()))
		B.box(5.0, 2.0, 0.8, WHITE(), Vector3(p.x, 33.0, p.y), a)
		B.box(5.6, 0.3, 1.6, STEEL(), Vector3(p.x, 32.6, p.y), a)
		B.footprint(p, 6.0, 6.0)

	# where the vehicle is built horizontally, the hangar it rolls out
	# of: SpaceX's integration facility sits by the ramp at 39A and at SLC-40
	if style == "strongback":
		var hf := Vector2(95.0, -(Rp + 95.0))
		var HW := 92.0; var HD := 58.0; var HH := 24.0
		B.box(HW + 20.0, 0.25, HD + 40.0, DARKCON(), Vector3(hf.x, 0.0, hf.y))
		B.box(HW, HH, HD, WHITE(), Vector3(hf.x, 0.25, hf.y))
		# a barrel roof, as the real one has
		var roof := CraftModel._cylinder(HD * 0.56, HD * 0.56, HW, 24, 1, false, 0.0, PI)
		B.add(roof, GREY(), Transform3D(Basis(Vector3(0, 0, 1), PI / 2.0) * Basis(Vector3.UP, -PI / 2.0),
			Vector3(hf.x, 0.25 + HH - HD * 0.18, hf.y)))
		# the big door on the pad side
		B.box(HW * 0.8, HH * 0.85, 0.3, GREY(), Vector3(hf.x, 0.25, hf.y + HD * 0.5 + 0.15))
		B.footprint(hf, HW + 20.0, HD + 40.0)
		roads.strip(Vector2(hf.x - 30.0, hf.y + HD * 0.5 + 20.0), Vector2(20.0, -(Rp - 10.0)), 14.0, DARKCON())
	# Starbase: the GSE farm is a street of tanks
	if style == "chopsticks":
		var tf := Vector2(-(toe + 60.0), radius * 0.9)
		B.box(120.0, 0.25, 34.0, DARKCON(), Vector3(tf.x, 0.0, tf.y))
		for k in 8:
			var r := 4.5 if k % 3 != 0 else 6.0
			var hgt := 26.0 if k % 2 == 0 else 20.0
			var at := Vector3(tf.x - 52.0 + float(k) * 14.8, 0.25, tf.y)
			B.drum(r, hgt, WHITE(), at)
			B.add(CraftModel._sphere(r, 16, 6, 0.0, TAU, 0.0, PI / 2.0), WHITE(), Transform3D(Basis(), at + Vector3(0, hgt, 0)))
		B.box(40.0, 11.0, 18.0, GREY(), Vector3(tf.x, 0.25, tf.y + 30.0))
		B.footprint(tf, 120.0, 34.0)
		B.footprint(Vector2(tf.x, tf.y + 30.0), 40.0, 18.0)

	return _grounds_finish(g, B, roads)

## Common to every complex: car park, roads, retention pond. Office and gatehouse
## are procedural only when the library is missing.
static func _grounds_common(g: Node3D, B: Batch, roads: Batch, radius: float, Rp: float, Rf: float, toe: float, authored: bool) -> void:
	# operations building and its car park, outside the fence by the
	# gate where the crawlerway comes in
	var ops := Vector2(-(Rf + 70.0), -(Rp * 0.55))
	if not authored: _office(B, ops, 64.0, 20.0, 3, 0.0)
	_car_park(g, B, Vector2(ops.x, ops.y + 44.0), 4, 18, 0.0, 7101)
	roads.strip(Vector2(ops.x + 32.0, ops.y), Vector2(-Rp * 0.924, ops.y), 7.0, ASPHALT())
	roads.strip(Vector2(ops.x, ops.y + 25.0), Vector2(ops.x, ops.y + 30.0), 7.0, ASPHALT())
	# a guard house at the gate
	if not authored:
		B.box(6.0, 3.2, 4.0, WHITE(), Vector3(34.0, 0.0, -(Rf + 16.0)))
		B.box(7.0, 0.3, 5.0, GREY(), Vector3(34.0, 3.2, -(Rf + 16.0)))
		B.footprint(Vector2(34.0, -(Rf + 16.0)), 7.0, 5.0)

	# the deluge water's retention pond (a million litres a launch go
	# somewhere), low and dark
	var ret := Vector2(toe + 60.0, -(toe + 70.0))
	B.box(84.0, 0.5, 46.0, GRAVEL(), Vector3(ret.x, 0.0, ret.y))
	var rw := CraftModel.Geo.new()
	for p in [Vector2(-39, -20), Vector2(39, -20), Vector2(-39, 20), Vector2(39, 20)]:
		rw.pos.append(Vector3(ret.x + p.x, 0.52, ret.y + p.y)); rw.nrm.append(Vector3.UP)
	rw.idx.append_array([0, 2, 1, 1, 2, 3])
	g.add_child(_mesh(rw, decal(WATER(), 1)))
	B.footprint(ret, 84.0, 46.0)

static func _grounds_finish(g: Node3D, B: Batch, roads: Batch) -> Array:
	roads.build(g)
	# the roads lie ON the ground, so they are decals, not slabs
	for c in g.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh.surface_get_material(0) == ASPHALT():
			(c as MeshInstance3D).mesh.surface_set_material(0, decal(ASPHALT(), 1))
			(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif c is MeshInstance3D and (c as MeshInstance3D).mesh.surface_get_material(0) == DARKCON():
			(c as MeshInstance3D).mesh.surface_set_material(0, decal(DARKCON(), 1))
			(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	B.build(g)
	return [g, B.keep_out]

# THE AUTHORED GROUNDS: model_sources/blender/facilities.py builds
# assets/pads/facilities.glb, one `stage_fac_<name>` per building. site_plan says
# where each stands; without the library, complex_grounds' blocks stand in.
static func _facility_library() -> Node3D:
	if not use_authored_pads: return null
	var path := "res://assets/pads/facilities.glb"
	if not ResourceLoader.exists(path): return null
	var packed := load(path) as PackedScene
	if packed == null: return null
	var lib := packed.instantiate() as Node3D
	if lib != null: CraftAssets._prepare(lib)
	return lib

## The yaw that turns a facility's local +x (or, with `z`, its +z) toward the
## pad from where it stands. Its mains, doors and lamps face that way.
static func _face_pad(p: Vector2, z := false) -> float:
	var d := -p.normalized()
	return atan2(d.x, d.y) if z else atan2(-d.y, d.x)

## Where a point given in a facility's own frame lands, the facility standing
## at `p` turned by `yaw` (Basis(UP, yaw), as Node3D.rotation.y applies it).
static func _at(p: Vector2, yaw: float, local: Vector2) -> Vector2:
	return p + Vector2(local.x * cos(yaw) + local.y * sin(yaw), -local.x * sin(yaw) + local.y * cos(yaw))

## [name, position, yaw, half-extent, service road?] for one complex. Pad at the
## origin, crawlerway toward −z, north +z. From the site plans: at LC-39 LOX at the
## NW corner, LH2 at the NE, water tower ~300 m NE, hypergols SW and SE; SpaceX's
## hangar at the foot of the ramp; Starbase's tank farm beside the mount. Clear of
## the masts (30°, 150°, 270° at `mast_r`), the trench axis (±x) and crawlerway (−z).
static func site_plan(r: float, style: String, mast_r: float) -> Array:
	var toe := r + PAD_RISE * 2.6 + 8.0
	var Rp := r + 300.0
	var Rf := Rp + 22.0
	var plan: Array = []
	var add := func(name: String, p: Vector2, yaw: float, half: float, road := false) -> void:
		plan.append([name, p, yaw, half, road])
	# every complex
	add.call("substation", Vector2(-r * 0.45, toe + 95.0), 0.0, 24.0, true)
	add.call("gas_farm", Vector2(r * 0.35, toe + 70.0), 0.0, 27.0, true)
	add.call("ops_building", Vector2(-(Rf + 70.0), -(Rp * 0.55)), 0.0, 36.0)
	add.call("guard_house", Vector2(34.0, -(Rf + 16.0)), 0.0, 10.0)
	var shop := Vector2(-(toe + 75.0), -(toe + 60.0))
	add.call("warehouse", shop, _face_pad(shop, true), 26.0)
	for k in 4:
		var a := (float(k) + 0.5) * TAU / 4.0 + 0.2
		var p := Vector2(cos(a), sin(a)) * (Rp - 40.0)
		if absf(p.x) < 40.0 and p.y < 0.0: p.x += 60.0
		add.call("floodlight", p, _face_pad(p, true), 3.0)
	# the camera sites ring the foot of the mound, clear of the trench's two
	# ends (0° and 180°) and of the crawlerway (270°)
	for deg in [35.0, 72.0, 108.0, 145.0, 215.0, 325.0]:
		var a := deg_to_rad(deg)
		var p := Vector2(cos(a), sin(a)) * (toe + 6.0)
		add.call("camera_site", p, _face_pad(p), 2.5)
	# the LC-39 pads: Apollo and Shuttle
	if style == "lut" or style == "fss" or style == "strongback":
		var lox := Vector2(-(toe + 45.0), toe * 0.4)
		var lox_yaw := _face_pad(lox)
		add.call("lox_sphere", lox, lox_yaw, 26.0, true)
		# a tanker at the sphere's fill bay (facilities.py: -(R + 2), R + 3)
		add.call("tanker", _at(lox, lox_yaw, Vector2(-12.5, 13.5)), lox_yaw, 0.0)
		var wt := Vector2(Rp * 0.52, Rp * 0.52)
		add.call("water_tower", wt, _face_pad(wt), 20.0)
		# the converter-compressor building and the shops, east of the pad
		var ccf := Vector2(toe + 150.0, -toe * 0.3)
		add.call("warehouse", ccf, _face_pad(ccf, true), 26.0)
	if style == "lut" or style == "fss":
		var lh2 := Vector2(toe + 45.0, toe * 0.4)
		var lh2_yaw := _face_pad(lh2)
		add.call("lh2_sphere", lh2, lh2_yaw, 26.0, true)
		add.call("tanker", _at(lh2, lh2_yaw, Vector2(-12.9, 13.9)), lh2_yaw, 0.0)
		add.call("burn_pond", Vector2(toe + 125.0, toe * 0.4 + 75.0), 0.0, 32.0)
	if style == "lut" or style == "strongback":
		var rp1 := Vector2(-(toe + 45.0), -toe * 0.2)
		add.call("rp1_farm", rp1, _face_pad(rp1), 28.0, true)
	if style == "fss":
		for sx in [-1.0, 1.0]:
			var hy := Vector2(sx * (toe + 35.0), -toe * 0.2)
			add.call("hypergol", hy, _face_pad(hy), 18.0, true)
	# SpaceX: the hangar at the foot of the ramp, and horizontal tanks in
	# place of the hydrogen sphere a Falcon has no use for
	if style == "strongback":
		var ht := Vector2(toe + 45.0, toe * 0.4)
		add.call("horizontal_tanks", ht, _face_pad(ht), 24.0, true)
		add.call("hif", Vector2(0.0, -(Rp + 150.0)), 0.0, 70.0)
		add.call("containers", Vector2(72.0, -(Rp + 130.0)), 0.0, 16.0)
		add.call("trailers", Vector2(-72.0, -(Rp + 125.0)), PI / 2.0, 21.0)
	# Starbase
	if style == "chopsticks":
		# north of the 150° mast, clear of its catenary's foot
		var farm := Vector2(-(toe + 70.0), mast_r * 0.5 + 45.0)
		add.call("tank_farm", farm, 0.0, 66.0, true)
		# the tankers that fill it, waiting their turn along its south side
		for k in 3:
			add.call("tanker", farm + Vector2(-44.0 + float(k) * 22.0, -18.0), 0.0, 0.0)
		add.call("subcooler", farm + Vector2(-10.0, 30.0), 0.0, 17.0)
		var bunker := Vector2(-(toe + 12.0), farm.y * 0.5)
		add.call("gse_bunker", bunker, _face_pad(bunker, true) + PI, 24.0)
		var hz := Vector2(-(toe + 60.0), -r * 0.15)
		add.call("horizontal_tanks", hz, _face_pad(hz), 24.0, true)
		var dl := Vector2(toe + 35.0, r * 0.35)
		add.call("deluge_tanks", dl, _face_pad(dl), 18.0)
		# a site that is still being built: the crane that stacks it, the
		# container yard and the office trailers
		var crane := Vector2(-(toe + 15.0), -60.0)
		add.call("crawler_crane", crane, _face_pad(crane), 16.0)
		add.call("containers", Vector2(toe + 45.0, -toe * 0.3), _face_pad(Vector2(toe + 45.0, -toe * 0.3)), 16.0)
		add.call("trailers", Vector2(r * 0.35 + 72.0, toe + 60.0), 0.0, 21.0)
	return plan

static func _set_range(n: Node, end: float) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		# railings, ladders and cable are thinner than a shadow-map texel:
		# their shadows are aliasing, and cost a pass for nothing
		var m := (n as MeshInstance3D).mesh.surface_get_material(0)
		if m != null and m.resource_name in ["safety-yellow", "rubber"]:
			(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if n is GeometryInstance3D:
		(n as GeometryInstance3D).visibility_range_end = end
		(n as GeometryInstance3D).visibility_range_end_margin = end * 0.1
		(n as GeometryInstance3D).visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for c in n.get_children(): _set_range(c, end)

## Stand the plan's facilities on the plain, with service roads where asked.
## Returns their footprints for the scrub.
static func place_facilities(plain: Node3D, lib: Node3D, plan: Array, Rp: float) -> Array:
	var g := _node()
	g.name = "facilities"
	plain.add_child(g)
	var roads := Batch.new()
	var keep_out: Array = []
	for item in plan:
		var src := lib.get_node_or_null("stage_fac_" + str(item[0])) as Node3D
		if src == null: continue
		var n := src.duplicate() as Node3D
		var p: Vector2 = item[1]
		n.position = Vector3(p.x, 0.0, p.y)
		n.rotation = Vector3(0.0, float(item[2]), 0.0)
		g.add_child(n)
		var half: float = item[3]
		# Visibility range grows with size.
		_set_range(n, 2500.0 + maxf(half, 4.0) * 80.0)
		if half > 0.0: keep_out.append(Rect2(p.x - half - 4.0, p.y - half - 4.0, 2.0 * half + 8.0, 2.0 * half + 8.0))
		if item[4]:
			# out to the perimeter road: an octagon of circumradius Rp, whose
			# edges' normals are at multiples of 45°
			var out := p.normalized()
			var off := fposmod(atan2(out.y, out.x) + PI / 8.0, PI / 4.0) - PI / 8.0
			var ring := Rp * cos(PI / 8.0) / cos(off)
			if p.length() + half < ring:
				roads.strip(p + out * half, out * ring, 6.0, ASPHALT())
	roads.build(g)
	for c in g.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).mesh.surface_set_material(0, decal(ASPHALT(), 1))
			(c as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return keep_out

## Sparse coastal scrub outside the maintained hardstand. Instancing keeps the
## visible foliage to one draw call rather than hundreds of tiny scene nodes.
static func coastal_scrub(radius: float, keep_out: Array = []) -> MultiMeshInstance3D:
	var blades := CraftModel.Geo.new()
	for i in 11:
		var a := float(i) * 2.39996
		var rr := 0.14 + 0.07 * float(i % 4)
		var h := 0.8 + 0.12 * float(i % 5)
		var radial := Vector3(cos(a), 0.0, sin(a))
		var tangent := Vector3(-sin(a), 0.0, cos(a))
		var center := radial * rr
		var base := blades.pos.size()
		blades.pos.append(center - tangent * 0.15)
		blades.pos.append(center + radial * 0.20 + Vector3.UP * h)
		blades.pos.append(center + tangent * 0.15)
		for j in 3: blades.nrm.append(radial)
		blades.idx.append_array([base, base + 1, base + 2])
	var mesh := CraftModel._to_mesh(blades, SCRUB())
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.mesh = mesh
	instances.instance_count = 900
	var rng := RandomNumberGenerator.new()
	rng.seed = 58193
	var made := 0
	for i in 900:
		var a := rng.randf_range(0.0, TAU)
		var r := sqrt(lerpf(pow(radius + 34.0, 2.0), pow(radius + 850.0, 2.0), rng.randf()))
		var x := cos(a) * r
		var z := sin(a) * r
		if absf(x) < 30.0 and z < -radius: continue # crawlerway
		var clear := true
		for rc in keep_out:
			if (rc as Rect2).has_point(Vector2(x, z)): clear = false; break
		if not clear: continue
		var scale := rng.randf_range(0.7, 1.9)
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
			Vector3(scale, scale * rng.randf_range(0.7, 1.4), scale))
		instances.set_instance_transform(made, Transform3D(basis, Vector3(x, 0.0, z)))
		made += 1
	instances.visible_instance_count = made
	var foliage := MultiMeshInstance3D.new()
	foliage.name = "coastal_scrub"
	foliage.multimesh = instances
	foliage.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return foliage

# THE COMPLEX
const STYLES := {"saturnv": "lut", "shuttle": "fss", "falcon9": "strongback", "starship": "chopsticks"}

## Mobile launcher exhaust openings [centre x, centre z, width x, depth z] in m,
## matching model_sources/blender/launchpads.py. The Shuttle's has three.
const DECK_HOLES := {
	"lut": [[0.0, 0.0, 13.7, 13.7]],
	"fss": [[-6.35, 0.0, 6.1, 12.8], [6.35, 0.0, 6.1, 12.8], [0.0, 7.4, 10.4, 9.4]],
}

## The platform minus its holes: cut the plan at every hole edge and keep the
## cells no hole covers, merged along x. [[x0, x1, z0, z1], …]
static func deck_cells(pw: float, pd: float, holes: Array, cx0 := 0.0, cz0 := 0.0) -> Array:
	var xs := [cx0 - pw * 0.5, cx0 + pw * 0.5]
	var zs := [cz0 - pd * 0.5, cz0 + pd * 0.5]
	for h in holes:
		for sg in [-1.0, 1.0]:
			xs.append(clampf(h[0] + sg * h[2] * 0.5, xs[0], xs[1]))
			zs.append(clampf(h[1] + sg * h[3] * 0.5, zs[0], zs[1]))
	xs.sort(); zs.sort()
	var cells := []
	for j in zs.size() - 1:
		var z0: float = zs[j]; var z1: float = zs[j + 1]
		if z1 - z0 < 1e-6: continue
		var run = null
		for i in xs.size() - 1:
			var x0: float = xs[i]; var x1: float = xs[i + 1]
			if x1 - x0 < 1e-6: continue
			var cx := (x0 + x1) * 0.5; var cz := (z0 + z1) * 0.5
			var solid := true
			for h in holes:
				if absf(cx - h[0]) < h[2] * 0.5 and absf(cz - h[1]) < h[3] * 0.5: solid = false
			if solid and run != null and absf(run[1] - x0) < 1e-6:
				run[1] = x1
			elif solid:
				run = [x0, x1, z0, z1]
				cells.append(run)
			else:
				run = null
	return cells
const STEAM_N := 340

var group: Node3D
var style: String
var deck_height: float
## How far grade — the level the ground patch is drawn at — sits below the pad
## deck: the launch mount's own height plus the hardstand's rise.
var grade_drop: float
## Height of the tallest structure, m — the camera uses it for framing. The
## same expression the tower was BUILT from, not a second guess at it.
var tower_height: float
var arms: Array = []           # [{group, axis: "yaw"|"tilt", rest, open}]
var open := 0.0
var D := 5.0
var steam: MeshInstance3D
var steam_mesh: ArrayMesh
var s_pos := PackedVector3Array()
var s_vel := PackedVector3Array()
var s_age := PackedFloat32Array()
var s_next := 0

## Build a launch complex for a vehicle.
##   vehicle  the sim/flight/vehicles.gd entry
##   height   real stacked height, m
##   env      Rocketry.flight_env(); only its gravity matters (deluge drift)
##   craft    the built root, measured for clearances; null falls back to the
##            diameter-based reach
static func create_launch_site(vehicle: Dictionary, height: float, env = null, craft: Node3D = null) -> LaunchSite:
	return LaunchSite.new(vehicle, height, env, craft)

static func _authored_pad(pad_style: String) -> Node3D:
	if not use_authored_pads: return null
	var path := "res://assets/pads/pad_%s.glb" % pad_style
	if not ResourceLoader.exists(path): return null
	var packed := load(path) as PackedScene
	if packed == null: return null
	var art := packed.instantiate() as Node3D
	if art != null: CraftAssets._prepare(art)
	return art

## The measured skin (see Envelope). Clearances between it and anything that
## reaches toward the vehicle.
var skin: Envelope
const GAP := 0.35

## Where a structure from azimuth `az` must stop inside a lane: the skin's standoff
## plus GAP, or `fallback` if the lane is empty or unmeasured.
func _stop(ya: float, yb: float, za: float, zb: float, fallback: float, az: float = PI) -> float:
	var d := skin.standoff(ya, yb, za, zb, az) if skin != null else -INF
	return d + GAP if d > -INF else fallback

func _init(vehicle: Dictionary, height: float, _env = null, craft: Node3D = null) -> void:
	skin = Envelope.new(craft) if craft != null else null
	# By `id`, not `key`. A vehicle carries `id` and has never carried `key` —
	# that belongs to its STAGES.
	style = STYLES.get(str(vehicle.get("id", "")), "lut")
	group = _node()
	group.name = "launch_site"
	D = float(vehicle.stages[0].D) if not vehicle.stages.is_empty() else 5.0

	# The vehicle's height above its mount. The deck is at local y = 0 (the vessel reads
	# zero altitude on the pad), and everything on the ground sits at −deck.
	deck_height = 23.5 if style == "chopsticks" else (9.6 if style == "strongback" else 7.6)
	var GRADE := -deck_height
	grade_drop = deck_height + PAD_RISE
	tower_height = 146.0 if style == "chopsticks" \
		else (minf(height * 0.86, 63.0) if style == "strongback"
		else (75.3 if style == "fss" else maxf(height + 12.0, 116.0)))

	# ground works, common to every complex
	var ground := _node()
	ground.position.y = GRADE
	group.add_child(ground)
	var across := maxf(height * 2.6, 200.0)
	var top_r := across * 0.5
	ground.add_child(hardstand(across))
	ground.add_child(hardstand_joints(top_r))
	ground.add_child(deck_services(top_r))
	ground.add_child(flame_trench(137.0, 18.0, 12.2))
	# The scorched apron, a decal on the deck.
	var apron := scorch_apron(maxf(D * 2.5, 18.0))
	apron.position.y = 0.01
	ground.add_child(apron)
	# The crawlerway out to the VAB — a 40 m wide river-rock road, and the only
	# thing in the scene that says which way "away" is.
	ground.add_child(crawlerway(top_r))
	ground.add_child(crawlerway_marks(top_r))

	# Everything that stands OFF the mound stands at grade, PAD_RISE lower.
	var plain := _node()
	plain.position.y = GRADE - PAD_RISE
	group.add_child(plain)
	# Masts stand well clear (~200 m out on a 300 m span at 39B).
	var mast_r := maxf(height * 2.4, top_r + 140.0)
	plain.add_child(lightning_masts(mast_r, maxf(height * 1.2, 100.0)))
	# The buildings: authored (model_sources/blender/facilities.py) when the
	# library has been built, the procedural blocks when it has not.
	var lib := _facility_library()
	var keep_out: Array = []
	if lib != null:
		plain.add_child(support_facilities(top_r, style, true))
		var grounds := complex_grounds(top_r, style, true)
		plain.add_child(grounds[0])
		keep_out = grounds[1]
		keep_out.append_array(place_facilities(plain, lib, site_plan(top_r, style, mast_r), top_r + 300.0))
		lib.free()
	else:
		var wt := water_tower(88.0)
		wt.position = Vector3(-(top_r + 60.0), 0.0, top_r * 0.8)
		plain.add_child(wt)
		plain.add_child(support_facilities(top_r, style))
		var grounds := complex_grounds(top_r, style)
		plain.add_child(grounds[0])
		keep_out = grounds[1]
		# support_facilities' two plots and the water tower
		keep_out.append(Rect2(-top_r - 145.0, -top_r * 0.35 - 38.0, 100.0, 76.0))
		keep_out.append(Rect2(top_r + 40.0, -top_r * 0.55 - 19.0, 44.0, 38.0))
		keep_out.append(Rect2(-(top_r + 60.0) - 10.0, top_r * 0.8 - 10.0, 20.0, 20.0))
	plain.add_child(coastal_scrub(top_r, keep_out))

	# the launch mount: built upward from zero, then dropped onto grade in one move.
	var mount := _node()
	mount.position.y = GRADE
	group.add_child(mount)
	var art := _authored_pad(style)
	if art != null: mount.add_child(art)
	var authored_deck: Node3D = art.get_node_or_null("stage_deck") if art != null else null
	var authored_tower: Node3D = art.get_node_or_null("stage_tower") if art != null else null
	var authored_strongback: Node3D = art.get_node_or_null("stage_strongback") if art != null else null
	var authored_rss: Node3D = art.get_node_or_null("stage_rss") if art != null else null

	if style == "lut" or style == "fss":
		# Mobile Launcher Platform: 49.4 × 41.1 m, 7.6 m deep, with a square
		# exhaust opening — four slabs around the hole, so the hole is real.
		var PW := 49.4; var PD := 41.1; var PH := 7.6; var HOLE := 13.7
		var holes: Array = DECK_HOLES[style]
		if authored_deck == null:
			for c in deck_cells(PW, PD, holes):
				mount.add_child(box(c[1] - c[0], PH, c[3] - c[2], GREY(), (c[0] + c[1]) * 0.5, 0.0, (c[2] + c[3]) * 0.5))
			var hx := 0.0
			for h in holes: hx = maxf(hx, absf(h[0]) + h[2] * 0.5)
			# hazard lines a metre outside each opening, cut where they would
			# cross a neighbouring one
			for h in holes:
				for signum in [-1.0, 1.0]:
					for ln in [[0.34, h[3] + 2.35, h[0] + signum * (h[2] * 0.5 + 1.0), h[1]],
							[h[2] + 2.35, 0.34, h[0], h[1] + signum * (h[3] * 0.5 + 1.0)]]:
						for c in deck_cells(ln[0], ln[1], holes, ln[2], ln[3]):
							mount.add_child(box(c[1] - c[0], 0.035, c[3] - c[2], SAFETY(),
								(c[0] + c[1]) * 0.5, PH, (c[2] + c[3]) * 0.5))
			for signum in [-1.0, 1.0]:
				for i in 7:
					mount.add_child(box(0.18, 0.04, 2.1, DARKCON(), signum * (hx + 3.2), PH,
						(float(i) - 3.0) * 2.7))
		# HOLD-DOWN ARMS between the fins: of two candidate sets of four, keep the one that
		# stands closer in, and stand each arm off the skin it faces.
		var best_set := 0.0
		var best_r := INF
		for set_off in [PI / 4.0, 0.0]:
			var worst := 0.0
			for i in 4:
				var a: float = (float(i) / 4.0) * TAU + set_off
				worst = maxf(worst, _stop(0.0, 3.4, -1.1, 1.1, D * 0.5, a))
			if worst < best_r:
				best_r = worst; best_set = set_off
		for i in 4:
			var a: float = (float(i) / 4.0) * TAU + best_set
			var r := maxf(D * 0.62, _stop(0.0, 3.4, -1.1, 1.1, D * 0.5, a) + 1.1)
			mount.add_child(box(2.2, 3.4, 2.2, PAINT(), cos(a) * r, PH, sin(a) * r))
		var tower_h := maxf(height + 12.0, 116.0) if style == "lut" else 75.3
		var tower_x := -(HOLE / 2.0 + 16.0)
		if authored_tower == null:
			var tower := lattice_tower(tower_h, 12.2, {"bay": 6.1})
			tower.position = Vector3(tower_x, PH, 0.0)
			mount.add_child(tower)
		elif style == "lut":
			authored_tower.scale.y = tower_h / 116.0
		# Feed and return lines are separate runs on the tower's outside face.
		for z in [-3.2, 3.2]:
			mount.add_child(pipe_between(Vector3(tower_x - 6.4, PH, z),
				Vector3(tower_x - 6.4, PH + tower_h * 0.88, z), 0.18, COPPER()))
		# hammerhead crane
		var jib := truss(22.0, 3.0, 3.0)
		jib.position = Vector3(-(HOLE / 2.0 + 16.0) + 6.0, PH + tower_h + 2.0, 0.0)
		mount.add_child(jib)
		mount.add_child(box(3.0, 4.0, 3.0, STEEL(), -(HOLE / 2.0 + 16.0), PH + tower_h, 0.0))
		# SWING ARMS (nine on the LUT) at the service levels, retracting on ignition. Each is
		# cut to the skin at its own height.
		var n := 9 if style == "lut" else 5
		var pivot_x := -(HOLE / 2.0 + 16.0)
		# On the FSS the crew access arm goes to the orbiter's hatch (0.834 of the way up,
		# in the orbiter's off-axis lane).
		var hatch_y := -1.0
		var hatch_z := 0.0
		if style == "fss":
			for st in vehicle.stages:
				var lk: Dictionary = st.get("look", {})
				var mt = lk.get("mount")
				if CraftModel._t(lk.get("orbiter")) and mt != null:
					hatch_y = float(mt.get("y", 0.0)) + float(st.L) * 0.834
					hatch_z = float(mt.get("z", 0.0))
		for i in n:
			var y := PH + 10.0 + (float(i) / (n - 1)) * (height * 0.92 - 10.0)
			var top_arm := i == n - 1
			var lane_z := 0.0
			if top_arm and hatch_y > 0.0:
				y = PH + hatch_y
				lane_z = hatch_z
			var vy := y - PH                       # the same height in the craft's frame
			var pivot := _node()
			pivot.position = Vector3(pivot_x, y, lane_z)
			# The white room is the top arm and larger. (`across` is to the left of an approach
			# from −x, i.e. −z.)
			var stop := _stop(vy - 2.3, vy + 2.4, -lane_z - 2.6, -lane_z + 2.6, 0.0) if top_arm \
				else _stop(vy - 1.3, vy + 1.3, -1.5, 1.5, 0.0)
			var tip := -pivot_x - stop             # arm-local x of the skin, less the gap
			var arm_end := tip - 4.5 * 0.5 if top_arm else tip
			var arm := truss(maxf(arm_end - 6.0, 2.0), 2.6, 2.4)
			arm.position = Vector3(6.0, -1.2, 0.0)
			pivot.add_child(arm)
			if top_arm:
				pivot.add_child(box(4.5, 4.5, 5.0, WHITE(), tip - 2.25, -2.2, 0.0))
			mount.add_child(pivot)
			arms.append({"group": pivot, "axis": "yaw", "rest": 0.0, "open": -PI * 0.62})
		if style == "fss":
			# the Rotating Service Structure, swung clear before launch
			var rss := _node()
			rss.position = Vector3(-(HOLE / 2.0 + 16.0), PH, 0.0)
			if authored_rss != null:
				authored_rss.owner = null
				art.remove_child(authored_rss)
				rss.add_child(authored_rss)
			else:
				rss.add_child(box(18.0, 40.0, 14.0, WHITE(), 14.0, 12.0, 0.0))
			mount.add_child(rss)
			arms.append({"group": rss, "axis": "yaw", "rest": -PI * 0.66, "open": -PI * 0.66})
			# The vent arm's "beanie cap" sits over the ET's ogive tip, on the axis, at the
			# measured top of the stack.
			var nose := skin.tip(1.5) if skin != null else -INF
			if nose == -INF: nose = height * 0.93
			var vent := _node()
			vent.position = Vector3(pivot_x, PH + nose + 2.0, 0.0)
			var v_arm := truss(-pivot_x - 6.0, 2.2, 2.0)
			v_arm.position = Vector3(5.0, 0.0, 0.0)
			vent.add_child(v_arm)
			# A 5 m cone, apex up: rim 1 m below the tip, crown 4 m above.
			var cap := _mesh(CraftModel._cone(3.4, 5.0, 16, 1, true), WHITE())
			cap.position = Vector3(-pivot_x, -0.5, 0.0)
			vent.add_child(cap)
			mount.add_child(vent)
			arms.append({"group": vent, "axis": "yaw", "rest": 0.0, "open": -PI * 0.55})
	elif style == "strongback":
		# Falcon 9: a four-legged mount, and a transporter-erector alongside until liftoff.
		var leg_h := 8.0
		if authored_deck == null:
			for i in 4:
				var a := (float(i) / 4.0) * PI * 2.0 + PI / 4.0
				mount.add_child(box(1.6, leg_h, 1.6, GREY(), cos(a) * 4.4, 0.0, sin(a) * 4.4))
			# A ring: the nine Merlins fire through the middle.
			for signum in [-1.0, 1.0]:
				mount.add_child(box(11.0, 1.6, 2.1, GREY(), 0.0, leg_h, signum * 4.45))
				mount.add_child(box(2.1, 1.6, 6.8, GREY(), signum * 4.45, leg_h, 0.0))
			for i in 4:
				var a := float(i) * TAU / 4.0
				var stripe := box(0.42, 0.045, 8.7, SAFETY(), cos(a) * 5.2, leg_h + 1.6,
					sin(a) * 5.2)
				stripe.rotation.y = a
				mount.add_child(stripe)
		# The strongback stands 0.9 m off the measured skin over its whole height.
		var te := _node()
		var sb_h := minf(height * 0.86, 63.0)
		var sb_face := _stop(leg_h - deck_height, leg_h - deck_height + sb_h, -1.9, 1.9, D * 0.5) + 0.55
		te.position = Vector3(-(sb_face + 1.7), leg_h, 0.0)
		if authored_strongback != null:
			authored_strongback.owner = null
			art.remove_child(authored_strongback)
			te.add_child(authored_strongback)
			authored_strongback.scale.y = minf(height * 0.86, 63.0) / 63.0
		else:
			te.add_child(lattice_tower(minf(height * 0.86, 63.0), 3.4,
				{"bay": 5.0, "leg": 0.3, "brace": 0.16}))
		# Quick-disconnect plates bridge to the skin and stop at it.
		for f in [0.30, 0.62]:
			var qy: float = height * f
			var vy: float = leg_h - deck_height + qy
			var reach := sb_face + 1.7 - _stop(vy, vy + 3.0, -1.2, 1.2, D * 0.5) + 0.2
			te.add_child(box(maxf(reach - 1.7, 0.2), 3.0, 2.4, WHITE(), 1.7 + (reach - 1.7) * 0.5, qy, 0.0))
		# Two hydraulic rams are visually separate from the umbilical truss.
		for z in [-1.1, 1.1]:
			te.add_child(pipe_between(Vector3(-2.5, 1.0, z), Vector3(-0.9, height * 0.35, z), 0.22, STEEL()))
		mount.add_child(te)
		# The strongback falls back about its base, away from the vehicle: positive z
		# (rotation.z = θ moves height y to x = −y·sin θ; the vehicle is on +x). Plumb
		# until release.
		arms.append({"group": te, "axis": "tilt", "rest": 0.0, "open": 0.30})
	else:
		# Starship: an Orbital Launch Mount on six legs with the vehicle over a
		# water-cooled steel deck, and a 146 m tower carrying two catch arms.
		var leg_h := 20.0
		if authored_deck == null:
			for i in 6:
				var a := (float(i) / 6.0) * PI * 2.0
				mount.add_child(box(3.0, leg_h, 3.0, GREY(), cos(a) * 12.0, 0.0, sin(a) * 12.0))
			var ring := _mesh(_ring(6.5, 14.0, 32), GREY())
			ring.rotation.x = -PI / 2.0
			ring.position.y = leg_h + 3.5
			mount.add_child(ring)
			var deck := _mesh(_ring(6.5, 14.0, 32), decal(SCORCH(), 2))
			deck.rotation.x = -PI / 2.0
			deck.position.y = leg_h + 3.515
			mount.add_child(deck)
		# Individual water-cooled deck plates, plumbing underneath, and launch
		# clamps distinguish this mount from a single featureless grey cylinder.
		if authored_deck == null:
			for i in 12:
				var a := (float(i) + 0.5) * TAU / 12.0
				var x := cos(a) * 10.0; var z := sin(a) * 10.0
				var plate := box(3.7, 0.10, 4.4, STEEL(), x, leg_h + 3.5, z)
				plate.rotation.y = -a
				mount.add_child(plate)
				if i % 2 == 0:
					mount.add_child(box(1.4, 2.6, 1.5, PAINT(), cos(a) * 7.5, leg_h + 3.5,
						sin(a) * 7.5))
		for z in [-13.0, 13.0]:
			mount.add_child(pipe_between(Vector3(-28.0, 1.0, z), Vector3(-13.0, leg_h + 2.0, z),
				0.34, COPPER()))
		if authored_tower == null:
			var tower := lattice_tower(146.0, 12.0, {"bay": 8.4, "leg": 0.7, "brace": 0.32})
			tower.position = Vector3(-26.0, 0.0, 0.0)
			mount.add_child(tower)
		for z in [-9.0, 9.0]:
			var pivot := _node()
			pivot.position = Vector3(-26.0, 62.0, z)
			var arm := truss(26.0, 5.0, 4.5, 0.34)
			arm.position = Vector3(6.0, 0.0, 0.0)
			pivot.add_child(arm)
			mount.add_child(pivot)
			arms.append({"group": pivot, "axis": "yaw", "rest": -0.10 if z > 0.0 else 0.10, "open": -1.15 if z > 0.0 else 1.15})

	# the deluge. Points rather than geometry: it is a cloud, and a cloud
	# made of triangles is a worse cloud than a few hundred camera-facing quads.
	s_pos.resize(STEAM_N); s_vel.resize(STEAM_N); s_age.resize(STEAM_N)
	s_age.fill(-1.0)
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/flight/steam.gdshader")
	sm.set_shader_parameter("uSize", maxf(D * 6.0, 30.0))
	sm.set_shader_parameter("uMap", Plume.smoke_texture())
	sm.render_priority = LocalView.ORDER.smoke
	steam_mesh = ArrayMesh.new()
	steam = MeshInstance3D.new()
	steam.name = "deluge"
	steam.mesh = steam_mesh
	steam.material_override = sm
	steam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	steam.custom_aabb = AABB(Vector3(-2000, -100, -2000), Vector3(4000, 2000, 4000))
	group.add_child(steam)

##   s.released  true once the vehicle has committed to leaving
##   s.throttle  0..1, drives the deluge
##   s.dt        seconds
func update(s: Dictionary) -> void:
	var dt := float(s.dt)
	# Retraction state: 0 = stowed against the vehicle, 1 = fully clear. Arms
	# are heavy and hydraulic; the real ones take a couple of seconds.
	var want := 1.0 if s.released else 0.0
	open += (want - open) * (1.0 - exp(-dt / 1.6))
	for a in arms:
		var ang: float = a.rest + (a.open - a.rest) * open
		var g: Node3D = a.group
		if a.axis == "yaw": g.rotation.y = ang
		else: g.rotation.z = ang

	# deluge: on whenever the engines are, plus the pre-ignition flow
	var rate := 1.0 if float(s.throttle) > 0.0 else 0.0
	var emit := mini(int(U.jround(rate * 90.0 * dt)), STEAM_N)
	for k in emit:
		s_next = (s_next + 1) % STEAM_N
		var i := s_next
		var a := randf() * PI * 2.0
		var rr := sqrt(randf()) * D * 2.2
		s_pos[i] = Vector3(cos(a) * rr, 1.0 + randf() * 4.0, sin(a) * rr)
		# Blown out along the trench, because that is where the deflector sends
		# it, and up as it entrains air and loses momentum.
		var along := -1.0 if randf() < 0.5 else 1.0
		s_vel[i] = Vector3(along * (14.0 + randf() * 26.0), 5.0 + randf() * 12.0, (randf() - 0.5) * 8.0)
		s_age[i] = 0.0
	var pts := PackedVector3Array()
	var ages := PackedVector2Array()
	for i in STEAM_N:
		if s_age[i] < 0.0: continue
		s_age[i] += dt / 6.5
		if s_age[i] >= 1.0:
			s_age[i] = -1.0
			continue
		s_pos[i] += s_vel[i] * dt
		# buoyant, and slowing as it spreads
		var v := s_vel[i]
		v.x *= exp(-dt * 0.55)
		v.z *= exp(-dt * 0.55)
		v.y = v.y * exp(-dt * 0.3) + 3.5 * dt
		s_vel[i] = v
		pts.append(s_pos[i])
		# a stable per-slot angle for the puff (steam.gdshader)
		ages.append(Vector2(s_age[i], fmod(float(i) * 0.6180339, 1.0)))
	(steam.material_override as ShaderMaterial).set_shader_parameter("uLight", clampf(Plume.daylight, 0.08, 1.4))
	steam_mesh.clear_surfaces()
	if not pts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = pts
		arr[Mesh.ARRAY_TEX_UV] = ages
		steam_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr)

func dispose() -> void:
	if is_instance_valid(group): group.queue_free()
