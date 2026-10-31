class_name CraftModel
extends RefCounted

# Procedural fallback spacecraft in metres. Stage placement and driven pivots use
# the same contract as assets/craft; see model_sources/blender/AGENTS.md.
# Primitive winding is reversed once in _to_mesh. Nodes use XYZ Euler.

# VEHICLE DATA: the one accessor for Vehicles (camelCase keys). `script` is the
# Vehicles script, for the derived stats the studio reports.
static var _vdata = null

static func vehicle_data() -> Dictionary:
	if _vdata == null:
		_vdata = {"VEHICLES": Vehicles.VEHICLES, "VEHICLE_ORDER": Vehicles.VEHICLE_ORDER,
			"ENGINES": Vehicles.ENGINES, "script": Vehicles}
	return _vdata

static func vehicles() -> Dictionary:
	return vehicle_data().VEHICLES

static func vehicle_order() -> Array:
	return vehicle_data().VEHICLE_ORDER

## One vehicle spec by id, or null.
static func vehicle(id: String):
	return vehicles().get(id, null)

# Spec truthiness: null/false/0/"" are false, but an empty object or array is true.
static func _t(v) -> bool:
	if v == null: return false
	match typeof(v):
		TYPE_BOOL: return v
		TYPE_INT, TYPE_FLOAT: return v != 0
		TYPE_STRING, TYPE_STRING_NAME: return v != ""
	return true

static func _n(v, d := 0.0) -> float:
	return float(v) if v != null else d

# MATERIALS
static var MAT := {}

## Lambert diffuse and Schlick-GGX specular. Shared fallback materials include
## open bells, skirts and interstages whose interiors must remain visible.
static func _mat(name: String, color: int, rough: float, metal: float,
		emissive := -1, emissive_intensity := 1.0) -> StandardMaterial3D:
	if MAT.has(name):
		return MAT[name]
	var m := StandardMaterial3D.new()
	m.resource_name = name
	m.albedo_color = Color.hex((color << 8) | 0xff)
	m.roughness = rough
	m.metallic = metal
	m.metallic_specular = 0.5            # F0 = 0.04, three's dielectric
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	if emissive >= 0:
		m.emission_enabled = true
		m.emission = Color.hex((emissive << 8) | 0xff)
		m.emission_energy_multiplier = emissive_intensity
	MaterialDetail.register(m)
	MAT[name] = m
	return m

## The shared palette.
static func craft_materials() -> Dictionary:
	return {
		"white": _mat("white", 0xe8e8ea, 0.72, 0.04),
		"dirty": _mat("dirty", 0xb9b9bd, 0.85, 0.05),
		"black": _mat("black", 0x1b1b1f, 0.62, 0.10),
		"soot": _mat("soot", 0x33333a, 0.95, 0.02),
		# Metalness is low on purpose: nothing gives the craft an environment to reflect,
		# and a PBR metal with nothing to reflect renders black.
		"steel": _mat("steel", 0xc4ccd4, 0.30, 0.34),
		"alu": _mat("alu", 0xa9b0b7, 0.46, 0.26),
		"gold": _mat("gold", 0xd8a13a, 0.52, 0.38),
		"foam": _mat("foam", 0xc2663a, 0.95, 0.02),
		"tiles": _mat("tiles", 0x24242a, 0.88, 0.03),
		"ablator": _mat("ablator", 0x6b5344, 0.94, 0.02),
		"solar": _mat("solar", 0x21306a, 0.38, 0.22),
		"nozzle": _mat("nozzle", 0x6e6b66, 0.42, 0.32),
		"hot": _mat("hot", 0x3a322c, 0.56, 0.26),
		"glass": _mat("glass", 0x16242e, 0.14, 0.24),
		"red": _mat("red", 0xa02a22, 0.7, 0.05),
		"blue": _mat("blue", 0x1f3a7a, 0.7, 0.05),
		# Spin-drive faces are emitters and light themselves (they face away from every
		# light). HDR values: a hex-scaled emissive is nearly black after ACES.
		# Astrophage emits at 4.26 and 18.31 μm, so the visible tail is deep red.
		"emitPlate": _mat("emitPlate", 0x4a4744, 0.52, 0.18, 0x8c3418, 1.3),
		"emitCell": _mat("emitCell", 0x2a1410, 0.45, 0.10, 0xff6a30, 2.8),
	}

static var M := {}
static var SKIN := {}

static func _init_mats() -> void:
	if not M.is_empty():
		return
	M = craft_materials()
	SKIN = {
		"white": M.white, "steel": M.steel, "foam": M.foam, "tiles": M.tiles,
		"metal": M.alu, "ablator": M.ablator, "mli-gold": M.gold, "panel-white": M.dirty,
	}

# A painted band is a separate cached material so it stays its own object
# (reversed-Z float depth needs no polygon offset).
static var _decal_cache := {}
static func decal_mat(material: StandardMaterial3D) -> StandardMaterial3D:
	var k := material.get_instance_id()
	if not _decal_cache.has(k):
		var m: StandardMaterial3D = material.duplicate()
		m.resource_name = material.resource_name + "_decal"
		_decal_cache[k] = m
	return _decal_cache[k]

# Mesh primitives use counter-clockwise source indices, swapped once for Godot.
## Positions, normals and a counter-clockwise index list.
class Geo:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var idx := PackedInt32Array()

static func _to_mesh(g: Geo, material: Material) -> ArrayMesh:
	var n := PackedVector3Array()
	n.resize(g.nrm.size())
	for i in g.nrm.size():
		var v := g.nrm[i]
		n[i] = v.normalized() if v.length_squared() > 1e-20 else Vector3.UP
	# Procedural front faces are counter-clockwise, Godot's clockwise: swap each
	# triple once, here, so every builder can use counter-clockwise order.
	var ix := PackedInt32Array()
	ix.resize(g.idx.size())
	for t in range(0, g.idx.size(), 3):
		ix[t] = g.idx[t]
		ix[t + 1] = g.idx[t + 2]
		ix[t + 2] = g.idx[t + 1]
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = g.pos
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_INDEX] = ix
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	am.surface_set_material(0, material)
	return am

## Mesh node with a material override.
static func _mesh(g: Geo, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.rotation_order = EULER_ORDER_XYZ
	mi.mesh = _to_mesh(g, material)
	return mi

## Untransformed parent for independently placed parts.
static func _grp() -> Node3D:
	var n := Node3D.new()
	n.rotation_order = EULER_ORDER_XYZ
	return n

## BufferGeometry.computeVertexNormals(): area-weighted face normals summed
## per index (so a lathe's duplicated seam stays a crease, at split seams).
static func _compute_normals(g: Geo) -> void:
	var n := PackedVector3Array()
	n.resize(g.pos.size())
	for t in range(0, g.idx.size(), 3):
		var a := g.idx[t]; var b := g.idx[t + 1]; var c := g.idx[t + 2]
		var cb := (g.pos[c] - g.pos[b]).cross(g.pos[a] - g.pos[b])
		n[a] += cb; n[b] += cb; n[c] += cb
	g.nrm = n

## Cylinder mesh (zero top radius gives a cone).
static func _cylinder(rt: float, rb: float, h: float, radial := 32, hseg := 1,
		open_ended := false, ts := 0.0, tl := TAU) -> Geo:
	var g := Geo.new()
	var half := h / 2.0
	var index := 0
	var rows := []
	var slope := (rb - rt) / h
	for y in hseg + 1:
		var row := []
		var v := float(y) / hseg
		var r := v * (rb - rt) + rt
		for x in radial + 1:
			var u := float(x) / radial
			var th := u * tl + ts
			g.pos.append(Vector3(r * sin(th), -v * h + half, r * cos(th)))
			g.nrm.append(Vector3(sin(th), slope, cos(th)).normalized())
			row.append(index); index += 1
		rows.append(row)
	for x in radial:
		for y in hseg:
			var a: int = rows[y][x]; var b: int = rows[y + 1][x]
			var c: int = rows[y + 1][x + 1]; var d: int = rows[y][x + 1]
			g.idx.append_array([a, b, d, b, c, d])
	if not open_ended:
		for top in [true, false]:
			var r := rt if top else rb
			if not (r > 0.0): continue
			var sgn := 1.0 if top else -1.0
			var c0 := index
			for x in radial:
				g.pos.append(Vector3(0, half * sgn, 0)); g.nrm.append(Vector3(0, sgn, 0)); index += 1
			var c1 := index
			for x in radial + 1:
				var th := float(x) / radial * tl + ts
				g.pos.append(Vector3(r * sin(th), half * sgn, r * cos(th))); g.nrm.append(Vector3(0, sgn, 0)); index += 1
			for x in radial:
				var c := c0 + x; var i := c1 + x
				if top: g.idx.append_array([i, i + 1, c])
				else: g.idx.append_array([i + 1, i, c])
	return g

static func _cone(r: float, h: float, radial := 32, hseg := 1, open_ended := false,
		ts := 0.0, tl := TAU) -> Geo:
	return _cylinder(0.0, r, h, radial, hseg, open_ended, ts, tl)

## UV sphere mesh.
static func _sphere(radius: float, ws := 32, hs := 16, ps := 0.0, pl := TAU,
		ts := 0.0, tl := PI) -> Geo:
	ws = maxi(3, ws); hs = maxi(2, hs)
	var the := minf(ts + tl, PI)
	var g := Geo.new()
	var grid := []
	var index := 0
	for iy in hs + 1:
		var row := []
		var v := float(iy) / hs
		for ix in ws + 1:
			var u := float(ix) / ws
			var p := Vector3(-radius * cos(ps + u * pl) * sin(ts + v * tl),
				radius * cos(ts + v * tl),
				radius * sin(ps + u * pl) * sin(ts + v * tl))
			g.pos.append(p); g.nrm.append(p.normalized())
			row.append(index); index += 1
		grid.append(row)
	for iy in hs:
		for ix in ws:
			var a: int = grid[iy][ix + 1]; var b: int = grid[iy][ix]
			var c: int = grid[iy + 1][ix]; var d: int = grid[iy + 1][ix + 1]
			if iy != 0 or ts > 0.0: g.idx.append_array([a, b, d])
			if iy != hs - 1 or the < PI: g.idx.append_array([b, c, d])
	return g

## Torus mesh — the ring lies in XY, so callers turn it with rotation.x.
static func _torus(radius: float, tube: float, rseg := 12, tseg := 48, arc := TAU) -> Geo:
	var g := Geo.new()
	for j in rseg + 1:
		for i in tseg + 1:
			var u := float(i) / tseg * arc
			var v := float(j) / rseg * TAU
			var p := Vector3((radius + tube * cos(v)) * cos(u), (radius + tube * cos(v)) * sin(u), tube * sin(v))
			g.pos.append(p)
			g.nrm.append((p - Vector3(radius * cos(u), radius * sin(u), 0)).normalized())
	for j in range(1, rseg + 1):
		for i in range(1, tseg + 1):
			var a := (tseg + 1) * j + i - 1
			var b := (tseg + 1) * (j - 1) + i - 1
			var c := (tseg + 1) * (j - 1) + i
			var d := (tseg + 1) * j + i
			g.idx.append_array([a, b, d, b, c, d])
	return g

## Box mesh with one segment per side: 24 vertices, flat normals.
static func _box(w: float, h: float, d: float) -> Geo:
	var g := Geo.new()
	# buildPlane(u, v, w, udir, vdir, width, height, depth) in counter-clockwise order:
	# px, nx, py, ny, pz, nz.
	var planes := [
		["z", "y", "x", -1, -1, d, h, w], ["z", "y", "x", 1, -1, d, h, -w],
		["x", "z", "y", 1, 1, w, d, h], ["x", "z", "y", 1, -1, w, d, -h],
		["x", "y", "z", 1, -1, w, h, d], ["x", "y", "z", -1, -1, w, h, -d]]
	var ax := {"x": 0, "y": 1, "z": 2}
	for pl in planes:
		var off := g.pos.size()
		var wd: float = pl[5]; var ht: float = pl[6]; var dp: float = pl[7]
		for iy in 2:
			var yy := iy * ht - ht / 2.0
			for ix in 2:
				var xx := ix * wd - wd / 2.0
				var p := [0.0, 0.0, 0.0]
				p[ax[pl[0]]] = xx * pl[3]
				p[ax[pl[1]]] = yy * pl[4]
				p[ax[pl[2]]] = dp / 2.0
				g.pos.append(Vector3(p[0], p[1], p[2]))
				var nn := [0.0, 0.0, 0.0]
				nn[ax[pl[2]]] = 1.0 if dp > 0.0 else -1.0
				g.nrm.append(Vector3(nn[0], nn[1], nn[2]))
		var a := off; var b := off + 2; var c := off + 3; var e := off + 1
		g.idx.append_array([a, b, e, b, c, e])
	return g

## Disc mesh, in XY facing +Z.
static func _circle(radius: float, seg := 32, ts := 0.0, tl := TAU) -> Geo:
	seg = maxi(3, seg)
	var g := Geo.new()
	g.pos.append(Vector3.ZERO); g.nrm.append(Vector3(0, 0, 1))
	for s in seg + 1:
		var a := ts + float(s) / seg * tl
		g.pos.append(Vector3(radius * cos(a), radius * sin(a), 0)); g.nrm.append(Vector3(0, 0, 1))
	for i in range(1, seg + 1):
		g.idx.append_array([i, i + 1, 0])
	return g

## Plane mesh, one segment, in XY facing +Z.
static func _plane(w: float, h: float) -> Geo:
	var g := Geo.new()
	for iy in 2:
		for ix in 2:
			g.pos.append(Vector3(ix * w - w / 2.0, -(iy * h - h / 2.0), 0)); g.nrm.append(Vector3(0, 0, 1))
	g.idx.append_array([0, 2, 1, 2, 3, 1])
	return g

## Lathed mesh, including its averaged meridian normals.
static func _lathe(points: PackedVector2Array, segments := 12, ps := 0.0, pl := TAU) -> Geo:
	pl = clampf(pl, 0.0, TAU)
	var g := Geo.new()
	var init := PackedVector3Array()
	var prev := Vector3.ZERO
	var np := points.size()
	for j in np:
		if j == 0:
			var dx := points[1].x - points[0].x; var dy := points[1].y - points[0].y
			var nn := Vector3(dy, -dx, 0)
			prev = nn
			init.append(nn.normalized())
		elif j == np - 1:
			init.append(prev)
		else:
			var dx := points[j + 1].x - points[j].x; var dy := points[j + 1].y - points[j].y
			var nn := Vector3(dy, -dx, 0)
			var cur := nn
			init.append((nn + prev).normalized())
			prev = cur
	for i in segments + 1:
		var phi := ps + float(i) / segments * pl
		var s := sin(phi); var c := cos(phi)
		for j in np:
			g.pos.append(Vector3(points[j].x * s, points[j].y, points[j].x * c))
			g.nrm.append(Vector3(init[j].x * s, init[j].y, init[j].x * c))
	for i in segments:
		for j in np - 1:
			var base := j + i * np
			var a := base; var b := base + np; var c := base + np + 1; var d := base + 1
			g.idx.append_array([a, b, d, c, d, b])
	return g

## Capsule mesh: a lathe of absarc + line + absarc.
static func _capsule(radius: float, length: float, cap_seg := 4, radial := 8) -> Geo:
	var pts := PackedVector2Array()
	var n := cap_seg * 2
	for i in n + 1:
		var a := 1.5 * PI + float(i) / n * (0.5 * PI)
		pts.append(Vector2(radius * cos(a), -length / 2.0 + radius * sin(a)))
	pts.append(Vector2(radius, length / 2.0))
	for i in range(1, n + 1):
		var a := float(i) / n * (0.5 * PI)
		pts.append(Vector2(radius * cos(a), length / 2.0 + radius * sin(a)))
	return _lathe(pts, radial)

# Centripetal Catmull–Rom curve and tube
class CatmullRom:
	var pts: Array   # of Vector3
	var _lengths := PackedFloat64Array()
	func _init(p: Array) -> void:
		pts = p
	static func _poly(x0: float, x1: float, x2: float, x3: float, dt0: float, dt1: float, dt2: float, w: float) -> float:
		var t1 := (x1 - x0) / dt0 - (x2 - x0) / (dt0 + dt1) + (x2 - x1) / dt1
		var t2 := (x2 - x1) / dt1 - (x3 - x1) / (dt1 + dt2) + (x3 - x2) / dt2
		t1 *= dt1; t2 *= dt1
		var c0 := x1; var c1 := t1
		var c2 := -3.0 * x1 + 3.0 * x2 - 2.0 * t1 - t2
		var c3 := 2.0 * x1 - 2.0 * x2 + t1 + t2
		return c0 + c1 * w + c2 * w * w + c3 * w * w * w
	func get_point(t: float) -> Vector3:
		var l := pts.size()
		var p := (l - 1) * t
		var ip := int(floor(p))
		var w := p - ip
		if w == 0.0 and ip == l - 1:
			ip = l - 2; w = 1.0
		var p0: Vector3
		if ip > 0: p0 = pts[ip - 1]
		else: p0 = (pts[0] - pts[1]) + pts[0]
		var p1: Vector3 = pts[ip % l]
		var p2: Vector3 = pts[(ip + 1) % l]
		var p3: Vector3
		if ip + 2 < l: p3 = pts[(ip + 2) % l]
		else: p3 = (pts[l - 1] - pts[l - 2]) + pts[l - 1]
		var dt0 := pow(p0.distance_squared_to(p1), 0.25)
		var dt1 := pow(p1.distance_squared_to(p2), 0.25)
		var dt2 := pow(p2.distance_squared_to(p3), 0.25)
		if dt1 < 1e-4: dt1 = 1.0
		if dt0 < 1e-4: dt0 = dt1
		if dt2 < 1e-4: dt2 = dt1
		return Vector3(_poly(p0.x, p1.x, p2.x, p3.x, dt0, dt1, dt2, w),
			_poly(p0.y, p1.y, p2.y, p3.y, dt0, dt1, dt2, w),
			_poly(p0.z, p1.z, p2.z, p3.z, dt0, dt1, dt2, w))
	func lengths() -> PackedFloat64Array:
		if _lengths.is_empty():
			var last := get_point(0.0); var sum := 0.0
			_lengths.append(0.0)
			for i in range(1, 201):
				var cur := get_point(i / 200.0)
				sum += cur.distance_to(last)
				_lengths.append(sum); last = cur
		return _lengths
	func u_to_t(u: float) -> float:
		var al := lengths()
		var il := al.size()
		var target := u * al[il - 1]
		var low := 0; var high := il - 1; var i := 0
		while low <= high:
			i = low + (high - low) / 2
			var cmp := al[i] - target
			if cmp < 0.0: low = i + 1
			elif cmp > 0.0: high = i - 1
			else:
				high = i; break
		i = high
		if al[i] == target: return float(i) / (il - 1)
		return (i + (target - al[i]) / (al[i + 1] - al[i])) / (il - 1)
	func get_point_at(u: float) -> Vector3:
		return get_point(u_to_t(u))
	func get_tangent_at(u: float) -> Vector3:
		var t := u_to_t(u)
		var t1 := maxf(t - 0.0001, 0.0); var t2 := minf(t + 0.0001, 1.0)
		return (get_point(t2) - get_point(t1)).normalized()

static func _tube(curve: CatmullRom, tseg: int, radius: float, rseg: int) -> Geo:
	# computeFrenetFrames(tseg, closed = false)
	var tans := []
	for i in tseg + 1:
		tans.append(curve.get_tangent_at(float(i) / tseg))
	var mn := INF
	var t0: Vector3 = tans[0]
	var nn := Vector3.ZERO
	if absf(t0.x) <= mn: mn = absf(t0.x); nn = Vector3(1, 0, 0)
	if absf(t0.y) <= mn: mn = absf(t0.y); nn = Vector3(0, 1, 0)
	if absf(t0.z) <= mn: nn = Vector3(0, 0, 1)
	var vec := t0.cross(nn).normalized()
	var nrms := [t0.cross(vec)]
	var bins := [t0.cross(nrms[0])]
	for i in range(1, tseg + 1):
		var n2: Vector3 = nrms[i - 1]
		var ta: Vector3 = tans[i - 1]; var tb: Vector3 = tans[i]
		var v := ta.cross(tb)
		if v.length() > 2.220446049250313e-16:
			v = v.normalized()
			var th := acos(clampf(ta.dot(tb), -1.0, 1.0))
			n2 = Basis(v, th) * n2
		nrms.append(n2)
		bins.append(tb.cross(n2))
	var g := Geo.new()
	for i in tseg + 1:
		var P := curve.get_point_at(float(i) / tseg)
		var N: Vector3 = nrms[i]; var B: Vector3 = bins[i]
		for j in rseg + 1:
			var v := float(j) / rseg * TAU
			var nrm := (N * -cos(v) + B * sin(v)).normalized()
			g.nrm.append(nrm)
			g.pos.append(P + nrm * radius)
	for j in range(1, tseg + 1):
		for i in range(1, rseg + 1):
			var a := (rseg + 1) * (j - 1) + (i - 1)
			var b := (rseg + 1) * j + (i - 1)
			var c := (rseg + 1) * j + i
			var d := (rseg + 1) * (j - 1) + i
			g.idx.append_array([a, b, d, b, c, d])
	return g

# Transform helpers
## Quaternion.setFromUnitVectors, the shortest-arc algorithm (its antiparallel fallback
## differs from Godot's Quaternion(from, to)).
static func quat_from_unit_vectors(vf: Vector3, vt: Vector3) -> Quaternion:
	var r := vf.dot(vt) + 1.0
	var q: Quaternion
	if r < 2.220446049250313e-16:
		if absf(vf.x) > absf(vf.z): q = Quaternion(-vf.y, vf.x, 0, 0)
		else: q = Quaternion(0, -vf.z, vf.y, 0)
	else:
		q = Quaternion(vf.y * vt.z - vf.z * vt.y, vf.z * vt.x - vf.x * vt.z, vf.x * vt.y - vf.y * vt.x, r)
	return q.normalized()

## Object3D.lookAt for a NON-camera object at `from` (world space, no parent):
## its +Z turns toward `to`, x = up × z, y = z × x.
static func _look_plus_z(from: Vector3, to: Vector3) -> Basis:
	var z := (to - from)
	if z.length_squared() == 0.0: z = Vector3(0, 0, 1)
	z = z.normalized()
	var x := Vector3.UP.cross(z)
	if x.length_squared() == 0.0:
		z.z += 0.0001; z = z.normalized(); x = Vector3.UP.cross(z)
	x = x.normalized()
	var y := z.cross(x)
	return Basis(x, y, z)

static func _add(parent: Node3D, child: Node3D) -> Node3D:
	parent.add_child(child)
	return child

# PARTS

## A tank barrel with domed ends, built as a lathe so the domes are real
## geometry rather than a capsule approximation.
static func tank(L: float, D: float, material: Material, dome_top := 0.12, dome_bot := 0.06, seg := 28) -> MeshInstance3D:
	var r := D / 2.0
	var pts := PackedVector2Array()
	var hb := r * dome_bot; var ht := r * dome_top
	pts.append(Vector2(0, 0))
	for i in range(1, 7):                                  # bottom dome
		var a := (i / 6.0) * PI / 2.0
		pts.append(Vector2(r * sin(a), hb * (1.0 - cos(a))))
	pts.append(Vector2(r, L - ht))
	for i in range(1, 7):                                  # top dome
		var a := (i / 6.0) * PI / 2.0
		pts.append(Vector2(r * cos(a), L - ht + ht * sin(a)))
	return _mesh(_lathe(pts, seg), material)

## A conical adapter / interstage between two diameters.
static func frustum(L: float, dbot: float, dtop: float, material: Material, seg := 28) -> MeshInstance3D:
	var m := _mesh(_cylinder(dtop / 2.0, dbot / 2.0, L, seg, 1, true), material)
	m.position.y = L / 2.0
	return m

## A bell nozzle: converging throat, then a parabolic (Rao) expansion. The exit to
## throat ratio is what reads as sea-level versus vacuum.
static func bell(exit_d: float, ratio := 3.6, chamber := true) -> MeshInstance3D:
	var re := exit_d / 2.0
	var rt := re / sqrt(ratio)                         # throat radius from area ratio
	var L := re * 2.6
	var pts := PackedVector2Array()
	if chamber:
		pts.append(Vector2(rt * 1.9, -L * 0.42))
		pts.append(Vector2(rt * 1.9, -L * 0.26))
		pts.append(Vector2(rt * 1.25, -L * 0.10))
	pts.append(Vector2(rt, 0))
	for i in range(1, 11):
		var u := i / 10.0
		# parabolic expansion: fast opening near the throat, flattening at the exit
		pts.append(Vector2(rt + (re - rt) * pow(u, 0.62), L * u))
	var g := _lathe(pts, 24)
	_compute_normals(g)
	var m := _mesh(g, M.nozzle)
	m.rotation.x = PI                                  # open end downward (−Y)
	return m

## A ring of engines with a gimbal pivot each. The ring radius comes from the
## engine's exit diameter, not a fraction of the vehicle (see
## model_sources/blender/AGENTS.md); four 3.53 m F-1s land on a 3.67 m ring.
static func engine_cluster(count: int, spread: float, exit_d: float, opts := {}) -> Dictionary:
	var g := _grp()
	var pivots: Array[Node3D] = []
	# The drawn exit, in an array because lambdas capture locals by value and the
	# three-ring case reassigns it.
	var dd := [exit_d]
	var place := func(x: float, z: float) -> void:
		var d: float = dd[0]
		var p := _grp()
		p.position = Vector3(x, 0, z)
		# Per-pivot swing authority (a cluster can mix rigid and gimballed engines).
		if opts.get("gimbalDeg") != null: p.set_meta("gimbal_deg", float(opts.gimbalDeg))
		p.add_child(bell(d, opts.get("ratio", 3.6), opts.get("chamber", true)))
		g.add_child(p); pivots.append(p)
	# Smallest ring n bells of diameter d fit on, clearing a centre engine if any.
	# `minR` keeps one cluster outside another. 8% gap so bells don't read as touching.
	var ring_r := func(n: int, centre: bool) -> float:
		var d: float = dd[0]
		return maxf(maxf(d * 1.08 / (2.0 * sin(PI / n)), d * 1.08 if centre else 0.0), _n(opts.get("minR"), 0.0))
	var ring := func(n: int, r: float, phase: float) -> void:
		for i in n:
			var a := (float(i) / n) * TAU + phase + _n(opts.get("phase"), 0.0)
			place.call(cos(a) * r, sin(a) * r)

	if count == 1:
		place.call(0.0, 0.0)
	elif count == 5 or count == 9:
		# A centre engine and a ring: the F-1 quincunx and the Merlin octaweb.
		place.call(0.0, 0.0)
		ring.call(count - 1, ring_r.call(count - 1, true), 0.39 if count == 9 else 0.0)
	elif count <= 9:
		ring.call(count, ring_r.call(count, false), PI / 2.0 if count == 3 else PI / count)
	else:
		# Three concentric rings (Super Heavy). The test is the nearest neighbour over the
		# whole cluster, not per ring. Radii 0.90 / 2.05 / 3.45 exit diameters keep every
		# pair ≥ 1.079 apart; where that doesn't fit the skirt, the drawn bell shrinks.
		var r_max := _n(opts.get("maxR"), spread * 1.46)
		var d := minf(exit_d, r_max / 3.95)
		dd[0] = d
		ring.call(3, 0.90 * d, 0.0)
		ring.call(10, 2.05 * d, PI / 10.0)
		ring.call(count - 13, 3.45 * d, PI / (count - 13))
	return {"group": g, "pivots": pivots}

## Grid fin — an actual waffle, because that is what makes it recognisable.
static func grid_fin(size := 1.5) -> Node3D:
	var g := _grp()
	var t := size * 0.06
	g.add_child(_mesh(_box(size, t, size * 0.75), M.hot))
	for i in range(-2, 3):
		var a := _mesh(_box(t * 0.7, size * 0.42, size * 0.75), M.hot)
		a.position = Vector3(i * size / 5.0, size * 0.21, 0); g.add_child(a)
		var b := _mesh(_box(size, size * 0.42, t * 0.7), M.hot)
		b.position = Vector3(0, size * 0.21, i * size * 0.15); g.add_child(b)
	return g

## A strut between two points. Structure is most of what makes a vehicle of
## parts read as one object rather than as parts.
static func beam(p1: Vector3, p2: Vector3, r: float, material: Material = null, seg := 6) -> MeshInstance3D:
	if material == null: material = M.alu
	var b := _mesh(_cylinder(r, r, p1.distance_to(p2), seg), material)
	b.position = p1.lerp(p2, 0.5)
	b.quaternion = quat_from_unit_vectors(Vector3(0, 1, 0), (p2 - p1).normalized())
	return b

## A ribbon parachute rigged along +Y from its attach point (the origin): riser,
## suspension lines and an inflated canopy whose apex is `reach` m out. `D0` is the
## nominal diameter, m. Fall scales x and z with how far it is open. The inflated
## diameter (0.67 D0), canopy depth, line length (D0), 24 gores and the ribbons' gaps
## are drawn proportions, not data.
static func parachute(D0: float, reach: float) -> Node3D:
	var cloth := _mat("nylon", 0xeeeae0, 0.9, 0.0)
	var cord := _mat("cord", 0xcfc8b8, 0.95, 0.0)
	var g := _grp()
	var rp := 0.335 * D0
	var hc := 0.9 * rp
	var y_skirt := reach - hc
	var y_conf := maxf(y_skirt - sqrt(maxf(D0 * D0 - rp * rp, 0.0)), reach * 0.15)
	const GORES := 24
	const SUB := 3
	const BANDS := 10
	var canopy := Geo.new()
	var cols := GORES * SUB
	for band in BANDS:
		# Each ribbon covers 80% of its band; the gaps are the canopy's porosity.
		var s0 := float(band) / BANDS * 0.94
		var s1 := s0 + 0.8 / BANDS * 0.94
		var base := canopy.pos.size()
		for s: float in [s0, s1]:
			var phi := s * PI / 2.0
			for c in cols + 1:
				var a := TAU * float(c) / cols
				# The cloth bulges between the radials.
				var r := rp * cos(phi) * (1.0 + 0.05 * sin(PI * float(c % SUB) / SUB))
				canopy.pos.append(Vector3(r * cos(a), y_skirt + hc * sin(phi), r * sin(a)))
				canopy.nrm.append(Vector3.ZERO)
		for c in cols:
			var a0 := base + c
			var b0 := base + cols + 1 + c
			canopy.idx.append_array([a0, b0, a0 + 1, a0 + 1, b0, b0 + 1])
	_compute_normals(canopy)
	g.add_child(_mesh(canopy, cloth))
	var lines := Geo.new()
	var w := maxf(0.05, D0 * 0.0025)
	var conf := Vector3(0.0, y_conf, 0.0)
	var cords := [[Vector3.ZERO, conf, w * 3.0]]
	for k in GORES:
		var a := TAU * float(k) / GORES
		cords.append([conf, Vector3(rp * cos(a), y_skirt, rp * sin(a)), w])
	for cd: Array in cords:
		var p0: Vector3 = cd[0]
		var p1: Vector3 = cd[1]
		var ax := (p1 - p0).normalized()
		var side := ax.cross(Vector3(1, 0, 0) if absf(ax.x) < 0.9 else Vector3(0, 0, 1)).normalized()
		# Two crossed ribbons, so a line reads from any side.
		for d: Vector3 in [side, ax.cross(side)]:
			var o: Vector3 = d * (float(cd[2]) * 0.5)
			var i0 := lines.pos.size()
			lines.pos.append_array([p0 - o, p0 + o, p1 - o, p1 + o])
			for n in 4: lines.nrm.append(d.cross(ax))
			lines.idx.append_array([i0, i0 + 1, i0 + 2, i0 + 1, i0 + 3, i0 + 2])
	g.add_child(_mesh(lines, cord))
	return g

## A landing leg: primary strut, two secondaries splayed in ±Z, footpad at -len,
## optional contact probe. The caller sets the deployment angle.
static func landing_leg(len: float, foot_r: float, probe := 0.0) -> Node3D:
	var g := _grp()
	var strut := _mesh(_cylinder(len * 0.050, len * 0.044, len * 0.60, 10), M.dirty)
	strut.position.y = -len * 0.30; g.add_child(strut)
	# The crushable-honeycomb cartridge: a visibly fatter section at the bottom
	# of the primary, and the part that actually absorbs the landing.
	var cart := _mesh(_cylinder(len * 0.066, len * 0.066, len * 0.36, 10), M.dirty)
	cart.position.y = -len * 0.79; g.add_child(cart)
	var joint := _mesh(_sphere(len * 0.052, 10, 7), M.alu)
	joint.position.y = -len * 0.97; g.add_child(joint)
	# The footpad: a shallow dish, so it can lie flat on a slope instead of on
	# one edge.
	var foot := _mesh(_cylinder(foot_r * 0.58, foot_r * 0.96, foot_r * 0.28, 18), M.dirty)
	foot.position.y = -len - foot_r * 0.06; g.add_child(foot)
	for s in [-1.0, 1.0]:
		g.add_child(beam(Vector3(0, len * 0.02, s * len * 0.135),
			Vector3(0, -len * 0.60, s * len * 0.028), len * 0.024, M.alu))
	if probe > 0.0:
		var pr := _mesh(_cylinder(len * 0.010, len * 0.010, probe, 6), M.alu)
		pr.position.y = -len - probe / 2.0; g.add_child(pr)
		var tip := _mesh(_cone(len * 0.026, len * 0.04, 8), M.alu)
		tip.position.y = -len - probe; tip.rotation.x = PI; g.add_child(tip)
	return g

static func solar_array(span: float, chord: float) -> Node3D:
	var g := _grp()
	g.add_child(_mesh(_box(span, 0.05, chord), M.solar))
	for i in range(1, 6):
		var rib := _mesh(_box(0.04, 0.07, chord), M.alu)
		rib.position.x = -span / 2.0 + span * i / 6.0; g.add_child(rib)
	return g

static func dish(r: float) -> MeshInstance3D:
	var pts := PackedVector2Array()
	for i in 9:
		var u := i / 8.0
		pts.append(Vector2(r * u, r * 0.34 * u * u))
	return _mesh(_lathe(pts, 20), M.white)

static func radiator(w: float, h: float) -> Node3D:
	var g := _grp()
	g.add_child(_mesh(_box(w, 0.04, h), M.white))
	for i in 7:
		var p := _mesh(_box(w * 0.94, 0.06, h * 0.02), M.black)
		p.position.z = -h / 2.0 + h * (i + 0.5) / 7.0; g.add_child(p)
	return g

## Small detail that does more for realism than anything else its size: a ring
## of RCS thruster quads, and the black conduit runs down a white tank.
static func rcs_ring(D: float, y: float, n := 4) -> Node3D:
	var g := _grp()
	for i in n:
		var a := (float(i) / n) * TAU
		var pod := _grp()
		pod.position = Vector3(cos(a) * D / 2.0, y, sin(a) * D / 2.0)
		pod.add_child(_mesh(_box(D * 0.07, D * 0.05, D * 0.07), M.dirty))
		for k in 2:
			var n2 := _mesh(_cone(D * 0.014, D * 0.03, 8), M.nozzle)
			n2.position = Vector3(0, D * 0.035 if k else -D * 0.035, 0)
			n2.rotation.x = 0.0 if k else PI
			pod.add_child(n2)
		pod.basis = _look_plus_z(pod.position, Vector3(0, y, 0))
		g.add_child(pod)
	return g

static func stripe(D: float, y: float, h: float, material: StandardMaterial3D) -> MeshInstance3D:
	var m := _mesh(_cylinder(D / 2.0 * 1.004, D / 2.0 * 1.004, h, 28, 1, true), decal_mat(material))
	m.position.y = y + h / 2.0
	return m

## A lofted hull, for shapes a lathe can't make. `sections` along +Y are
## `{ y, w, h, cz, n }`: half-width in X, half-height in Z, centreline offset in Z,
## superellipse exponent (2 = ellipse, 4 = rounded square). `t0`/`t1` bound the
## sweep so upper and lower shells can take different materials.
static func loft(sections: Array, material: Material, seg := 28, t0 := 0.0, t1 := TAU) -> MeshInstance3D:
	var S := sections.size()
	var closed := absf((t1 - t0) - TAU) < 1e-6
	var ring := seg if closed else seg + 1
	var g := Geo.new()
	for c in sections:
		var nexp: float = c.get("n", 2.0)
		var e := 2.0 / nexp
		for i in ring:
			var t := t0 + (t1 - t0) * (float(i) / seg)
			var ct := cos(t); var st := sin(t)
			# Superellipse in the exponent form, so one parameter carries the
			# section from a circle to a square without changing the vertex count.
			g.pos.append(Vector3(c.get("w", 0.0) * signf(ct) * pow(absf(ct), e), c.y,
				c.get("h", 0.0) * signf(st) * pow(absf(st), e) + c.get("cz", 0.0)))
	for s in S - 1:
		for i in seg:
			var a := s * ring + i; var b := s * ring + (i + 1) % ring
			# Wound outward; the other order renders inside-out.
			g.idx.append_array([a, b + ring, b, a, a + ring, b + ring])
	_compute_normals(g)
	return _mesh(g, material)

## NACA symmetric thickness distribution, as a fraction of chord.
static func naca(u: float, t: float) -> float:
	return 5.0 * t * (0.2969 * sqrt(u) - 0.1260 * u - 0.3516 * u * u
		+ 0.2843 * u * u * u - 0.1015 * u * u * u * u)

## A wing from spanwise stations `{ x, yLE, chord, thick, cz }`; a kinked planform
## is just a station at the kink. Airfoil section, upper and lower surfaces as
## separate meshes.
static func wing_panel(stations: Array, mat_up: Material, mat_lo: Material, n_chord := 14, sign := 1.0) -> Node3D:
	var build := func(side: float) -> Geo:
		var g := Geo.new()
		for st in stations:
			for i in n_chord + 1:
				var u := float(i) / n_chord
				g.pos.append(Vector3(sign * st.x, st.yLE - u * st.chord,
					side * naca(u, st.thick) * st.chord + st.get("cz", 0.0)))
		var R := n_chord + 1
		for s in stations.size() - 1:
			for i in n_chord:
				var a := s * R + i; var b := a + 1
				# Mirroring reverses the winding, so `sign` flips it back.
				if side * sign > 0.0: g.idx.append_array([a, b, b + R, a, b + R, a + R])
				else: g.idx.append_array([a, b + R, b, a, a + R, b + R])
		_compute_normals(g)
		return g
	var grp := _grp()
	grp.add_child(_mesh(build.call(1.0), mat_up))
	grp.add_child(_mesh(build.call(-1.0), mat_lo))
	return grp

## A tube along a curved centreline, framed by parallel transport so it never
## flips where the tangent passes vertical and the seams stay straight.
## `radii`, if given, is the radius at each point (a taper).
static func bent_tube(pts: Array, r: float, material: Material, radial := 20, radii: Array = []) -> Dictionary:
	var N := pts.size()
	var tan := []
	for i in N:
		tan.append((pts[mini(i + 1, N - 1)] - pts[maxi(i - 1, 0)]).normalized())
	# A seed normal: any axis not parallel to the first tangent, made perpendicular.
	var n0 := Vector3(0, 0, 1)
	if absf(n0.dot(tan[0])) > 0.9: n0 = Vector3(1, 0, 0)
	n0 = (n0 - tan[0] * n0.dot(tan[0])).normalized()
	var nrm := [n0]
	for i in range(1, N):
		var q := quat_from_unit_vectors(tan[i - 1], tan[i])
		nrm.append((q * nrm[i - 1]).normalized())
	var g := Geo.new()
	for i in N:
		var bi: Vector3 = tan[i].cross(nrm[i]).normalized()
		var ri: float = radii[i] if i < radii.size() else r
		for j in radial:
			var a := (float(j) / radial) * TAU
			var c := cos(a) * ri; var sn := sin(a) * ri
			g.pos.append(pts[i] + nrm[i] * c + bi * sn)
	for i in N - 1:
		for j in radial:
			var a := i * radial + j; var b := i * radial + (j + 1) % radial
			g.idx.append_array([a, b, b + radial, a, b + radial, a + radial])
	_compute_normals(g)
	return {"mesh": _mesh(g, material), "tan": tan, "nrm": nrm}

## A centreline that runs straight, bends through a circular arc in XY, then runs
## straight again. Radial/axial frame (x = distance from the axis).
static func bent_path(x0: float, y0: float, y_bend: float, turn_r: float, turn_deg: float,
		run_out: float, n_straight := 6, n_arc := 10) -> Array:
	var pts := []
	var th := turn_deg * PI / 180.0; var cx := x0 - turn_r
	for i in n_straight + 1:
		pts.append(Vector3(x0, y0 + (y_bend - y0) * (float(i) / n_straight), 0))
	for i in range(1, n_arc + 1):
		var t := th * (float(i) / n_arc)
		pts.append(Vector3(cx + turn_r * cos(t), y_bend - turn_r * sin(t), 0))
	var end: Vector3 = pts[pts.size() - 1]
	pts.append(Vector3(end.x - sin(th) * run_out, end.y - cos(th) * run_out, 0))
	return pts

## A tangent ogive nose — the curve an actual fairing is struck on, which is
## visibly fuller than the half-ellipse a naive lathe produces.
static func ogive(L: float, D: float, material: Material, seg := 28) -> MeshInstance3D:
	var r := D / 2.0; var rho := (r * r + L * L) / (2.0 * r)
	var pts := PackedVector2Array()
	for i in 15:
		var y := (i / 14.0) * L
		# Full radius at the base: y is measured from the base, not the apex.
		pts.append(Vector2(maxf(sqrt(maxf(rho * rho - y * y, 0.0)) - rho + r, 1e-3), y))
	return _mesh(_lathe(pts, seg), material)

## A sphere-cone heat shield: nose cap of radius `noseR`, straight flank at `half`
## degrees, shoulder radius. Every Mars lander since Viking flies it at 70°.
static func sphere_cone(D: float, nose_r: float, half_deg: float, material: Material, seg := 32) -> MeshInstance3D:
	var R := D / 2.0; var half := half_deg * PI / 180.0; var shoulder := R * 0.06
	var pts := PackedVector2Array()
	# The cap runs to the tangent point, where the sphere's slope matches the flank.
	var tA := PI / 2.0 - half
	for i in 11:
		var a := (i / 10.0) * tA
		pts.append(Vector2(nose_r * sin(a), nose_r * (1.0 - cos(a))))
	var xT := nose_r * sin(tA); var yT := nose_r * (1.0 - cos(tA))
	var xF := R - shoulder * cos(half)
	pts.append(Vector2(xF, yT + (xF - xT) / tan(half)))
	var yF := yT + (xF - xT) / tan(half)
	for i in range(1, 6):                              # the shoulder round-over
		var a := half + (i / 5.0) * (PI / 2.0 - half)
		pts.append(Vector2(xF + shoulder * (cos(a) - cos(half)), yF + shoulder * (sin(a) - sin(half))))
	# Apex is the lowest point and the shoulder sits at y = 0, where the backshell
	# bolts on. Fixed here so no caller can flip it.
	var top := pts[pts.size() - 1].y
	for i in pts.size():
		pts[i] = Vector2(pts[i].x, pts[i].y - top)
	var g := _lathe(pts, seg)
	_compute_normals(g)
	return _mesh(g, material)

## An open lattice tower (the Apollo escape tower is mostly air).
static func lattice(h: float, w_bot: float, w_top: float, material: Material) -> Node3D:
	var g := _grp(); var t := w_bot * 0.055
	for i in 4:
		var a := i / 4.0 * TAU + PI / 4.0
		var p0 := Vector3(cos(a) * w_bot / 2.0, 0, sin(a) * w_bot / 2.0)
		var p1 := Vector3(cos(a) * w_top / 2.0, h, sin(a) * w_top / 2.0)
		var leg := _mesh(_cylinder(t, t, p0.distance_to(p1), 6), material)
		leg.position = p0.lerp(p1, 0.5)
		leg.quaternion = quat_from_unit_vectors(Vector3(0, 1, 0), (p1 - p0).normalized())
		g.add_child(leg)
	for k in range(1, 4):                              # cross bracing
		var y := h * k / 4.0; var w := w_bot + (w_top - w_bot) * (k / 4.0)
		var ring := _mesh(_torus(w / 2.0 * 0.99, t * 0.7, 4, 4), material)
		ring.rotation = Vector3(PI / 2.0, 0, PI / 4.0); ring.position.y = y
		g.add_child(ring)
	return g

# STAGE BUILDERS — one per `look` flavour
static func _new_parts() -> Dictionary:
	return {"gimbals": [], "fins": [], "legs": [], "arrays": [], "flaps": [], "halves": [], "doors": [], "pieces": [], "nosecaps": [], "frustums": [], "nozzles": [], "chutes": []}

static func build_stage(spec: Dictionary, ctx: Dictionary) -> Dictionary:
	var built := _build_stage(spec, ctx)
	var limits := CraftAssets.gimbal_limits(spec, ctx.get("vehicle", {}))
	for i in mini(built.parts.gimbals.size(), limits.size()):
		built.parts.gimbals[i].set_meta("gimbal_deg", limits[i])
	return built

static func _build_stage(spec: Dictionary, ctx: Dictionary) -> Dictionary:
	_init_mats()
	var look: Dictionary = spec.get("look", {}) if spec.get("look") != null else {}
	var skin: StandardMaterial3D = SKIN.get(look.get("skin", ""), M.white)
	var D: float = spec.D; var L: float = spec.L
	var parts := _new_parts()

	# The authored model, if loaded. It replaces the stage's contents, not its
	# placement: build_craft sets this group's position afterwards.
	var authored := CraftAssets.craft_stage(str(ctx.get("id", "")), str(spec.key))
	if authored != null:
		var ga := _grp()
		ga.add_child(authored)
		CraftAssets.bind_parts(authored, parts, spec, ctx.get("vehicle", {}))
		return {"group": ga, "parts": parts}

	if _t(look.get("srb")): return ShuttleLines.build_srb(spec, parts)
	if _t(look.get("orbiter")): return ShuttleLines.build_orbiter(spec, parts)
	if _t(look.get("tank")): return ShuttleLines.build_et(spec, parts)
	if _t(look.get("aeroshell")): return build_aeroshell(spec, parts)
	if _t(look.get("skycrane")): return build_sky_crane(spec, parts)
	if _t(look.get("rover")): return build_rover(spec, parts)
	if _t(look.get("hailmary")): return build_hail_mary(spec, parts)
	if _t(look.get("superHeavy")): return build_super_heavy(spec, parts)
	if _t(look.get("starship")): return build_starship_ship(spec, parts)
	if _t(look.get("beetle")): return build_beetle(spec, parts)
	if _t(look.get("bus")): return build_ion_bus(spec, parts)
	if _t(look.get("sail")): return build_sail(spec, parts)
	if _t(look.get("octagon")): return build_lm_descent(spec, parts)
	if _t(look.get("cabin")): return build_lm_ascent(spec, parts)
	if _t(look.get("capsule")): return build_csm(spec, parts)
	if _t(look.get("fairing")): return build_fairing(spec, parts)
	if _t(look.get("ring")): return build_ring(spec, parts)
	if _t(look.get("satellite")): return build_satellite(spec, parts)
	# Created only now: a Node3D is not refcounted, so one made before those returns leaks.
	var g := _grp()

	# the default: a cylindrical stage with engines under it. `L` is the whole
	# length, so a nose eats into the barrel.
	var nose_l := D * 1.55 if _t(look.get("nosecone")) else 0.0
	var interstage := _n(look.get("interstage"), 0.0)
	# A stage carrying a nose or interstage gets a flat top, or the dome leaves a gap
	# at the joint. The aft end is near-flat too.
	var flat := nose_l > 0.0 or interstage != 0.0 or _t(look.get("flatTop"))
	g.add_child(tank(L - nose_l, D, skin, 0.0 if flat else 0.12, 0.02))
	if _t(look.get("soot")): g.add_child(stripe(D, 0, L * 0.12, M.soot))
	if _t(look.get("band")): g.add_child(stripe(D, L * 0.62, L * 0.10, M.black))
	if look.get("pattern") == "saturn":
		# The Saturn V roll pattern: asymmetric quarter panels so tracking cameras could
		# read roll.
		g.add_child(stripe(D, 0, L * 0.075, M.black))            # aft skirt
		g.add_child(stripe(D, L * 0.955, L * 0.045, M.black))    # forward skirt
		for yh in [[L * 0.075, L * 0.115], [L * 0.545, L * 0.105]]:
			for k in [0, 2]:
				var q := _mesh(_cylinder(D / 2.0 * 1.004, D / 2.0 * 1.004, yh[1], 10, 1, true,
					k * PI / 2.0, PI / 2.0), decal_mat(M.black))
				q.position.y = yh[0] + yh[1] / 2.0; g.add_child(q)
		# UNITED STATES down the side, and the flag opposite it.
		var usa := _mesh(_cylinder(D / 2.0 * 1.006, D / 2.0 * 1.006, L * 0.20, 8, 1, true, -0.34, 0.68), decal_mat(M.black))
		usa.position.y = L * 0.78; g.add_child(usa)
		var flag := _mesh(_cylinder(D / 2.0 * 1.006, D / 2.0 * 1.006, L * 0.075, 6, 1, true, PI - 0.24, 0.48), decal_mat(M.red))
		flag.position.y = L * 0.80; g.add_child(flag)
	if _t(look.get("hotStage")):
		var hs := _mesh(_cylinder(D / 2.0 * 0.99, D / 2.0 * 0.99, L * 0.03, 28, 1, true), M.hot)
		hs.position.y = L * 0.995; g.add_child(hs)
	if interstage != 0.0:
		# An interstage adapts to the next stage's diameter (10.06 → 6.6 → 3.9 m on the
		# Saturn V).
		var top_d := _n(ctx.get("nextD"), D)
		var ov := minf(0.35, interstage * 0.18)            # sink into both ends
		var ism: StandardMaterial3D = skin if look.get("interstageSkin") == "skin" \
			else (M.black if look.get("interstageSkin") == "black" else M.dirty)
		var is_m := _mesh(_cylinder(top_d / 2.0, D / 2.0, interstage + ov * 2.0, 28, 1, true), ism)
		is_m.position.y = L + interstage / 2.0 - ov * 0.0; g.add_child(is_m)
		if absf(top_d - D) < 0.05:
			# Separation-plane band on a cylindrical interstage only.
			var bd := _mesh(_torus(D / 2.0 * 1.005, D * 0.006, 6, 32), M.black)
			bd.rotation.x = PI / 2.0; bd.position.y = L + interstage; g.add_child(bd)
	if _t(look.get("aftSkirt")):
		var sk := _mesh(_cylinder(D / 2.0, D / 2.0 * 1.02, L * 0.14, 24, 1, true), M.dirty)
		sk.position.y = L * 0.07; g.add_child(sk)
	if _t(look.get("nosecone")):
		var n := ogive(nose_l, D, skin); n.position.y = L - nose_l; g.add_child(n)
	if _t(look.get("tiles")):
		# heat tiles on the windward half only, which is what they are for
		var sh := _mesh(_cylinder(D / 2.0 * 1.005, D / 2.0 * 1.005, L * 0.9, 28, 1, true, -PI / 2.0, PI), decal_mat(M.tiles))
		sh.position.y = L * 0.45; g.add_child(sh)
	# engines. `engineOn` means another stage carries them (the SSMEs are on the
	# orbiter), so the tank doesn't draw bells.
	var eng = spec.get("engine")
	if eng != null and _n(spec.get("count")) > 0 and not _t(spec.get("engineOn")):
		var spread := D * 0.30
		var exd := _n(eng.get("exitD"), 0.0)
		var ec := engine_cluster(int(spec.count), spread, exd if exd != 0.0 else D * 0.2,
			{"gimbalDeg": eng.get("gimbal"), "maxR": D * 0.475})
		ec.group.position.y = -0.02
		g.add_child(ec.group)
		parts.gimbals = ec.pivots.duplicate()
		# a thrust structure so the bells are not floating
		var ts := _mesh(_cylinder(D / 2.0 * 0.92, D / 2.0 * 0.80, D * 0.16, 20, 1, true), M.soot)
		ts.position.y = D * 0.05; g.add_child(ts)
	var veng = spec.get("vacEngine")
	if veng != null and _t(spec.get("vacCount")):
		# `minR` and `phase` keep Starship's vacuum bells clear of the sea-level ones:
		# 2.1 m of ring, and staggered, or each sits on top of its neighbour.
		var vc := int(spec.vacCount)
		var ec := engine_cluster(vc, D * 0.44, float(veng.exitD),
			{"gimbalDeg": veng.get("gimbal"), "minR": D * 0.28, "phase": PI / vc})
		ec.group.position.y = -0.02; g.add_child(ec.group)
		parts.gimbals.append_array(ec.pivots)
	if _t(spec.get("gridFins")):
		var nf := int(spec.gridFins)
		var fin_y := L + interstage * 0.72
		for i in nf:
			var a := (float(i) / nf) * TAU + 0.4
			var hinge := _grp()
			hinge.position = Vector3(cos(a) * D / 2.0, fin_y, sin(a) * D / 2.0)
			hinge.rotation.y = -a
			# Fins are built with +1.35 rad pre-cant so the deploy's travel ends square to the
			# body.
			var arm := _grp()
			arm.rotation.z = 1.35
			var fin := grid_fin(D * 0.42)
			fin.position = Vector3(D * 0.22, 0, 0)
			arm.add_child(fin)
			hinge.add_child(arm)
			g.add_child(hinge)
			parts.fins.append(hinge)
	if _t(spec.get("legs")):
		# Legs are built with pre-cant: update() swings the hinge by -1.15·d, which folds a
		# leg inward, so the leg carries +1.047 + 1.15 to end 60° out when deployed and lie
		# along the body when stowed.
		var nl := int(spec.legs)
		for i in nl:
			var a := (float(i) / nl) * TAU + 0.78
			var hinge := _grp()
			hinge.position = Vector3(cos(a) * D / 2.0 * 0.92, L * 0.055, sin(a) * D / 2.0 * 0.92)
			hinge.rotation.y = -a
			var leg := landing_leg(D * 0.82, D * 0.10)
			leg.rotation.z = 1.047 + 1.15
			hinge.add_child(leg)
			g.add_child(hinge)
			parts.legs.append(hinge)
	if _t(spec.get("flaps")):
		for fl in [[1.0, L * 0.86, 1], [-1.0, L * 0.86, -1], [1.0, L * 0.10, 1], [-1.0, L * 0.10, -1]]:
			var h := _grp()
			h.position = Vector3(fl[0] * D / 2.0 * 0.95, fl[1], 0)
			var f := _mesh(_box(D * 0.42, D * 0.5, 0.35), M.tiles)
			f.position.x = fl[0] * D * 0.20
			h.add_child(f); g.add_child(h); parts.flaps.append(h)
	if _t(look.get("fins")):
		# The S-IC's four fins and fairings: 18.8 m across the tips against a 10.06 m tank.
		var nfin := int(look.fins)
		for i in nfin:
			var a := (float(i) / nfin) * TAU + PI / 4.0
			# Everything for one fin station hangs off a single swung group, so
			# the fairing and the fin cannot drift apart from each other.
			var bay := _grp(); bay.rotation.y = -a
			# Fairing: a faired cone over the outboard engine's actuators and the
			# retro-rockets, tapering into the tank wall.
			var fair := _mesh(_cylinder(D * 0.055, D * 0.165, L * 0.215, 14, 1, true), M.white)
			fair.position = Vector3(D / 2.0 * 0.90, L * 0.150, 0)
			bay.add_child(fair)
			# It is faired INTO the tank, not stood off it: a half-round fillet
			# down the joint is what stops it reading as a spike taped to the side.
			var fillet := _mesh(_cylinder(D * 0.075, D * 0.075, L * 0.215, 10, 1, true, PI / 2.0, PI), M.white)
			fillet.position = Vector3(D / 2.0 * 0.99, L * 0.150, 0); bay.add_child(fillet)
			# Fin: a clipped swept delta, built from a wing panel so it has a real
			# leading edge instead of being a slab.
			var fin := wing_panel([
				{"x": D * 0.48, "yLE": L * 0.150, "chord": L * 0.128, "thick": 0.09},
				{"x": D * 0.68, "yLE": L * 0.098, "chord": L * 0.105, "thick": 0.10},
				{"x": D * 0.93, "yLE": L * 0.030, "chord": L * 0.072, "thick": 0.12},
			], M.black, M.black)
			bay.add_child(fin)                             # span is already +X = outward
			g.add_child(bay)
	if _t(look.get("octaweb")):
		# The octaweb is a visible black machined structure, not a smooth base.
		var ow := _mesh(_cylinder(D / 2.0 * 1.01, D / 2.0 * 0.97, D * 0.26, 8), M.black)
		ow.position.y = D * 0.13; ow.rotation.y = PI / 8.0; g.add_child(ow)
		# Four stowed landing legs, lying along the body as dark strakes. They
		# are there for the whole ascent and are half the booster's aft silhouette.
		for i in 4:
			var a := (i / 4.0) * TAU + 0.78
			var holder := _grp(); holder.rotation.y = -a
			var bay_l := D * 1.15
			var fair := _mesh(_cylinder(D * 0.075, D * 0.075, bay_l, 8, 1, true, -PI / 2.0, PI), M.black)
			fair.position = Vector3(D / 2.0 * 0.985, D * 0.14 + bay_l / 2.0, 0)
			holder.add_child(fair)
			# The nose fairing over the top of the stowed leg, which is the only
			# bit of it that stands out from the body.
			var tip := _mesh(_cone(D * 0.075, D * 0.20, 8, 1, true), M.black)
			tip.position = Vector3(D / 2.0 * 0.985, D * 0.14 + bay_l + D * 0.10, 0)
			holder.add_child(tip)
			g.add_child(holder)
	if _t(spec.get("rcs")): g.add_child(rcs_ring(D, L * 0.88, 4))
	return {"group": g, "parts": parts}

## SUPER HEAVY V3 and its ship. Fallbacks for the authored .glb, from the same layout
## as model_sources/blender/starship.py: the vented interstage built in (a crown of truss
## arches), three grid fins in a T at the catch points and away from the tower, two
## chines, the Raptor 3s bare under a plumbing ring.
static func build_super_heavy(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var L: float = spec.L; var D: float = spec.D; var R := D / 2.0
	var bay_top := 2.0; var crown := 1.3
	var body := _mesh(_cylinder(R, R, L - bay_top - crown, 36, 1, true), M.steel)
	body.position.y = bay_top + (L - bay_top - crown) / 2.0; g.add_child(body)
	var y := bay_top + 1.83
	while y < L - crown - 0.4:
		var wr := _mesh(_torus(R * 1.003, 0.03, 4, 36), M.steel)
		wr.rotation.x = PI / 2.0; wr.position.y = y; g.add_child(wr)
		y += 1.83
	var shield := _mesh(_circle(R * 0.99, 36), M.hot)
	shield.rotation.x = -PI / 2.0; shield.position.y = L - crown - 0.02; g.add_child(shield)
	for yy in [L - crown, L - 0.12]:
		var rr := _mesh(_torus(R, 0.13, 4, 36), M.steel)
		rr.rotation.x = PI / 2.0; rr.position.y = yy; g.add_child(rr)
	for i in 30:
		var a0 := i / 30.0 * TAU; var a1 := (i + 1) / 30.0 * TAU; var am := (a0 + a1) / 2.0
		var hi := Vector3(cos(am) * R * 0.99, L - 0.12, -sin(am) * R * 0.99)
		g.add_child(beam(Vector3(cos(a0) * R, L - crown, -sin(a0) * R), hi, 0.07, M.steel, 4))
		g.add_child(beam(Vector3(cos(a1) * R, L - crown, -sin(a1) * R), hi, 0.07, M.steel, 4))
	for i in 36:
		var a := i / 36.0 * TAU
		var v := _mesh(_box(0.06, 1.7, 0.32), M.black)
		v.position = Vector3(cos(a) * R * 1.004, L - 9.0, -sin(a) * R * 1.004); v.rotation.y = a; g.add_child(v)
	# the open engine bay
	var dome := _mesh(_circle(R * 0.97, 36), M.black)
	dome.rotation.x = PI / 2.0; dome.position.y = bay_top - 0.05; g.add_child(dome)
	for yy in [0.35, 0.95, 1.55]:
		var mf := _mesh(_torus(R * 0.955, 0.13, 4, 36), M.soot)
		mf.rotation.x = PI / 2.0; mf.position.y = yy; g.add_child(mf)
	for i in 24:
		var a := i / 24.0 * TAU
		g.add_child(beam(Vector3(cos(a) * R * 0.95, 0.15, -sin(a) * R * 0.95), Vector3(cos(a) * R * 0.95, bay_top, -sin(a) * R * 0.95), 0.06, M.soot, 4))
	var eng = spec.get("engine")
	var ec := engine_cluster(int(spec.count), D * 0.30, float(eng.exitD), {"gimbalDeg": eng.get("gimbal"), "maxR": D * 0.475})
	ec.group.position.y = -0.02; g.add_child(ec.group)
	parts.gimbals = ec.pivots.duplicate()
	# chines, the raceway and the quick-disconnect plate
	for az in [PI / 2.0 + 0.35, -PI / 2.0 + 0.35]:
		var ch := _mesh(_box(1.2, L * 0.60 - bay_top - 3.0, 1.2), M.steel)
		ch.position = Vector3(cos(az) * (R + 0.12), (bay_top + L * 0.60 - 3.0) / 2.0, -sin(az) * (R + 0.12))
		ch.rotation.y = az + PI / 4.0; g.add_child(ch)
	var ra := -PI / 2.0 - 0.5
	var rw := _mesh(_box(0.30, L - 6.0, 0.42), M.steel)
	rw.position = Vector3(cos(ra) * (R + 0.15), L / 2.0 - 1.0, -sin(ra) * (R + 0.15)); rw.rotation.y = ra; g.add_child(rw)
	var qd := _mesh(_box(0.4, 1.8, 2.2), M.dirty)
	qd.position = Vector3(0, 4.0, -(R + 0.15)); qd.rotation.y = PI / 2.0; g.add_child(qd)
	# Three grid fins: the catch points at ±X and one away from the tower.
	var nf := int(spec.get("gridFins", 3))
	for i in nf:
		var az: float = [0.0, PI, -PI / 2.0, PI / 2.0][i % 4]
		var hinge := _grp()
		hinge.position = Vector3(cos(az) * R, L - 3.4, -sin(az) * R)
		hinge.rotation.y = az
		var arm := _grp()
		arm.rotation.z = 1.35
		var fin := hex_grid_fin(5.2, 4.2, 0.75, 0.62)
		fin.position.x = 0.9
		arm.add_child(fin)
		arm.add_child(beam(Vector3.ZERO, Vector3(0.95, 0, 0), 0.32, M.hot, 8))
		hinge.add_child(arm); g.add_child(hinge)
		parts.fins.append(hinge)
	g.add_child(rcs_ring(D * 1.04, L - 6.0, 4))
	return {"group": g, "parts": parts}

## A V3 grid fin: an elongated hexagon of deep diamond cells, spanning +X from its
## hinge, the flow through it along Y.
static func hex_grid_fin(W: float, H: float, depth: float, pitch: float) -> Node3D:
	var g := _grp()
	var hull := [Vector2(0, -H * 0.25), Vector2(W * 0.22, -H / 2.0), Vector2(W * 0.78, -H / 2.0), Vector2(W, -H * 0.25),
		Vector2(W, H * 0.25), Vector2(W * 0.78, H / 2.0), Vector2(W * 0.22, H / 2.0), Vector2(0, H * 0.25)]
	for i in hull.size():
		var a: Vector2 = hull[i]; var b: Vector2 = hull[(i + 1) % hull.size()]
		var rim := _mesh(_box((b - a).length() + 0.12, depth, 0.14), M.hot)
		rim.position = Vector3((a.x + b.x) / 2.0, 0, (a.y + b.y) / 2.0)
		rim.rotation.y = -atan2(b.y - a.y, b.x - a.x); g.add_child(rim)
	for sgn in [1.0, -1.0]:
		var d := Vector2(sqrt(0.5), sgn * sqrt(0.5))
		var nrm := Vector2(-d.y, d.x)
		var n := int((W + H) / pitch) + 2
		for j in range(-n, n + 1):
			var p := Vector2(W / 2.0, 0) + nrm * (j * pitch)
			var t0 := -1e9; var t1 := 1e9
			var ok := true
			for i in hull.size():
				var a: Vector2 = hull[i]; var b: Vector2 = hull[(i + 1) % hull.size()]
				var en := Vector2(b.y - a.y, -(b.x - a.x))
				var den := en.dot(d); var num := en.dot(a - p)
				if absf(den) < 1e-9:
					if num < 0.0: ok = false
					continue
				if den > 0.0: t1 = minf(t1, num / den)
				else: t0 = maxf(t0, num / den)
			if not ok or t1 - t0 < 0.2: continue
			var c := p + d * ((t0 + t1) / 2.0)
			var bar := _mesh(_box(t1 - t0, depth * 0.92, 0.05), M.hot)
			bar.position = Vector3(c.x, 0, c.y); bar.rotation.y = -atan2(d.y, d.x); g.add_child(bar)
	return g

static func build_starship_ship(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var L: float = spec.L; var D: float = spec.D; var R := D / 2.0
	var nose_l := D * 1.55
	var rho := (R * R + nose_l * nose_l) / (2.0 * R)
	var nose_r := func(y: float) -> float:
		if y <= L - nose_l: return R
		var t := minf(y - (L - nose_l), nose_l)
		return maxf(sqrt(maxf(rho * rho - t * t, 0.0)) - rho + R, 0.02)
	g.add_child(tank(L - nose_l, D, M.steel, 0.0, 0.02))
	var nose := ogive(nose_l, D, M.steel); nose.position.y = L - nose_l; g.add_child(nose)
	# Tiles on the windward half (−Z, Blender's +Y), up the nose to the tip.
	var tp := PackedVector2Array([Vector2(R * 1.006, 0.6), Vector2(R * 1.006, L - nose_l)])
	for i in range(1, 25):
		var yy := L - nose_l + nose_l * 0.985 * i / 24.0
		tp.append(Vector2(nose_r.call(yy) * 1.006 + 0.004, yy))
	tp.append(Vector2(0.0, L + 0.004))
	g.add_child(_mesh(_lathe(tp, 24, PI / 2.0 - 0.10, PI + 0.20), M.tiles))
	# Four flaps on hinge lines along the body: aft at the tile edge, forward moved leeward.
	for fl in [[-0.35, L - nose_l + 1.0, L - 4.6, 3.4, 1.6], [PI + 0.35, L - nose_l + 1.0, L - 4.6, 3.4, 1.6],
			[0.0, 1.2, 12.6, 4.6, 3.2], [PI, 1.2, 12.6, 4.6, 3.2]]:
		var az: float = fl[0]
		var r0: float = nose_r.call(fl[1]); var r1: float = nose_r.call(fl[2])
		var mount := _grp()
		mount.position = Vector3(cos(az) * r0 * 0.99, fl[1], -sin(az) * r0 * 0.99)
		mount.rotation.y = az
		var tilt := _grp()
		tilt.rotation.z = atan2(r0 - r1, fl[2] - fl[1])
		var h := _grp()
		# Local Z up the hinge, so update()'s turn about Z swings it about the hinge line.
		h.rotation.x = -PI / 2.0
		var Lh := Vector2(fl[2] - fl[1], r0 - r1).length()
		var plate := _mesh(_flap_plate(fl[3], fl[4], Lh, 0.32), M.tiles)
		h.add_child(plate)
		tilt.add_child(h); mount.add_child(tilt); g.add_child(mount)
		parts.flaps.append(h)
	# engines: three sea-level inside three vacuum, staggered
	var eng = spec.get("engine")
	var ec := engine_cluster(int(spec.count), D * 0.30, float(eng.exitD), {"gimbalDeg": eng.get("gimbal"), "maxR": D * 0.475})
	ec.group.position.y = -0.02; g.add_child(ec.group)
	parts.gimbals = ec.pivots.duplicate()
	var veng = spec.get("vacEngine")
	if veng != null:
		var vc := int(spec.vacCount)
		var vec := engine_cluster(vc, D * 0.44, float(veng.exitD), {"gimbalDeg": veng.get("gimbal"), "minR": D * 0.28, "phase": PI / vc})
		vec.group.position.y = -0.02; g.add_child(vec.group)
		parts.gimbals.append_array(vec.pivots)
	var sk := _mesh(_cylinder(R, R * 0.99, 1.6, 36, 1, true), M.soot)
	sk.position.y = 0.8; g.add_child(sk)
	# leeward ports and the catch pins
	for pz in [[L * 0.74, 1.3], [L * 0.31, 1.9]]:
		var port := _mesh(_box(pz[1], pz[1], 0.10), M.black)
		port.position = Vector3(0, pz[0], R * 1.006); g.add_child(port)
	for sgn in [-1.0, 1.0]:
		var pin := _mesh(_box(0.7, 0.5, 0.5), M.hot)
		pin.position = Vector3(sgn * R * 1.04, L * 0.70, 0.6); g.add_child(pin)
	g.add_child(rcs_ring(D * 1.04, L * 0.66, 4))
	return {"group": g, "parts": parts}

## A flap's plate in its hinge frame: span along +X from the hull, chord along the
## hinge (local +Z here, Blender's −Y), root span `s0` at the foot and `s1` at the head.
static func _flap_plate(s0: float, s1: float, chord: float, th: float) -> Geo:
	var g := Geo.new()
	var pts := [Vector2(0.05, 0.0), Vector2(s0, 0.0), Vector2(s1, chord * 0.92), Vector2(0.05, chord)]
	for p in pts:
		for zz in [-th / 2.0, th / 2.0]:
			g.pos.append(Vector3(p.x, zz, p.y))
	# Two caps and four sides, wound outward.
	g.idx.append_array([0, 2, 4, 0, 4, 6, 1, 5, 3, 1, 7, 5])
	for i in 4:
		var a := i * 2; var b := ((i + 1) % 4) * 2
		g.idx.append_array([a, b + 1, b, a, a + 1, b + 1])
	_compute_normals(g)
	return g

static func build_fairing(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var D: float = spec.D; var L: float = spec.L
	# Two halves that hinge apart and tumble — the classic separation.
	for side in [1.0, -1.0]:
		var h := _grp()
		var pts := PackedVector2Array()
		for i in 13:
			var u := i / 12.0
			var r := D / 2.0 if u < 0.55 else D / 2.0 * sqrt(maxf(1.0 - pow((u - 0.55) / 0.45, 2.0), 0.0))
			pts.append(Vector2(maxf(r, 0.02), u * L))
		h.add_child(_mesh(_lathe(pts, 20, -PI / 2.0 if side > 0 else PI / 2.0, PI), M.white))
		g.add_child(h)
		parts.halves.append(h)
	return {"group": g, "parts": parts}

## An interstage that is a stage of its own (the S-II's aft interstage, dropped at the
## second plane): an open cylinder sunk into its neighbours, the plane banded on top.
static func build_ring(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var D: float = spec.D; var L: float = spec.L
	var ov := minf(0.35, L * 0.18)
	var m := _mesh(_cylinder(D / 2.0, D / 2.0, L + ov * 2.0, 28, 1, true), M.dirty)
	m.position.y = L / 2.0; g.add_child(m)
	var bd := _mesh(_torus(D / 2.0 * 1.005, D * 0.006, 6, 32), M.black)
	bd.rotation.x = PI / 2.0; bd.position.y = L; g.add_child(bd)
	return {"group": g, "parts": parts}

## A square sail of `sail.area` across the stage's axis (its normal is the body axis),
## on four booms along its diagonals from a small bus.
static func build_sail(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var bus := _mesh(_box(0.6, 0.5, 0.6), M.gold)
	bus.position.y = 0.25; g.add_child(bus)
	var side := sqrt(float(spec.sail.area))
	var sheet := _mesh(_box(side, 0.004, side), M.alu)
	sheet.position.y = 0.55
	sheet.rotation.y = PI / 4.0
	g.add_child(sheet)
	for k in 4:
		var boom := _mesh(_cylinder(0.05, 0.05, float(spec.sail.boom), 8), M.dirty)
		boom.rotation = Vector3(0.0, k * PI / 2.0, PI / 2.0)
		boom.position = Vector3(cos(k * PI / 2.0), 0.0, -sin(k * PI / 2.0)) * float(spec.sail.boom) * 0.5 + Vector3(0, 0.56, 0)
		g.add_child(boom)
	return {"group": g, "parts": parts}

static func build_satellite(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var b := _mesh(_box(2.4, 3.0, 2.4), M.gold)
	b.position.y = 1.5; g.add_child(b)
	for side in [1.0, -1.0]:
		var arm := _grp()
		arm.position = Vector3(side * 1.2, 1.6, 0)
		var a := solar_array(7.5, 2.0); a.position.x = side * 4.0; arm.add_child(a)
		g.add_child(arm); parts.arrays.append(arm)
	var d := dish(1.1); d.position.y = 3.1; g.add_child(d)
	return {"group": g, "parts": parts}

## THE APOLLO SPACECRAFT: service module, command module (a 33° blunt cone over a
## spherical heat shield), and the escape tower (an open lattice under a solid motor).
static func build_csm(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var sm_d := 3.90; var sm_l := 4.70; var r := sm_d / 2.0
	# service module: a plain cylinder, and almost all of it is propellant.
	var sm := _mesh(_cylinder(r, r, sm_l, 28, 1, true), M.alu)
	sm.position.y = sm_l / 2.0; g.add_child(sm)
	# Its six radiator/RCS bays read as vertical seams around the drum.
	for i in 6:
		var a := i / 6.0 * TAU
		var seam := _mesh(_box(0.05, sm_l * 0.96, 0.14), M.dirty)
		seam.position = Vector3(cos(a) * r, sm_l / 2.0, sin(a) * r)
		seam.rotation.y = -a; g.add_child(seam)
	g.add_child(rcs_ring(sm_d, sm_l * 0.86, 4))
	var pivot := _grp()
	var b := bell(2.24, 62); b.scale = Vector3(1.15, 1.15, 1.15)
	pivot.add_child(b); g.add_child(pivot); parts.gimbals.append(pivot)
	var hd := dish(1.0); hd.position = Vector3(2.3, 1.1, 0); hd.rotation.z = -1.15; g.add_child(hd)
	# command module: the 33° cone, apex up, on its heat shield.
	var cm_y := sm_l; var cm_h := 3.20; var cm_r := 1.955
	var cm := _mesh(_cylinder(cm_r * 0.28, cm_r, cm_h, 24, 1, true), M.alu)
	cm.position.y = cm_y + cm_h / 2.0; g.add_child(cm)
	var shield := _mesh(_sphere(cm_r * 1.9, 24, 8, 0.0, TAU, PI * 0.72, PI * 0.28), M.ablator)
	shield.position.y = cm_y + cm_r * 1.62; g.add_child(shield)
	var tunnel := _mesh(_cylinder(cm_r * 0.26, cm_r * 0.28, 0.42, 16), M.alu)
	tunnel.position.y = cm_y + cm_h + 0.18; g.add_child(tunnel)
	# launch escape system: tower, motor, and the canted nozzles that pull
	# the command module off a failing stack fast enough to matter.
	var tow_y := cm_y + cm_h + 0.40; var tow_h := 3.05
	var tower := lattice(tow_h, cm_r * 1.05, cm_r * 0.62, M.dirty)
	tower.position.y = tow_y; g.add_child(tower)
	var motor_y := tow_y + tow_h; var motor_l := 4.75
	var motor := _mesh(_cylinder(0.33, 0.33, motor_l, 18), M.white)
	motor.position.y = motor_y + motor_l / 2.0; g.add_child(motor)
	for i in 4:                                        # escape motor nozzles
		var a := i / 4.0 * TAU + PI / 4.0
		var n2 := _mesh(_cone(0.17, 0.42, 10), M.nozzle)
		n2.position = Vector3(cos(a) * 0.33, motor_y + motor_l * 0.30, sin(a) * 0.33)
		n2.rotation = Vector3(sin(a) * 0.45, 0, -cos(a) * 0.45)
		g.add_child(n2)
	# Ballast nose and the Q-ball that measures angle of attack at the very tip.
	var nose := ogive(1.55, 0.66, M.white, 16)
	nose.position.y = motor_y + motor_l; g.add_child(nose)
	return {"group": g, "parts": parts}

# LM stance: 1.5 m clear of the surface on a gear 9.4 m across the pads. y = 0 is
# the footpad plane; LM_GEAR is the descent stage's height above it, and the
# ascent stage carries the same offset internally.
const LM_GEAR := 1.52
const LM_PAD_R := 4.30

static func build_lm_descent(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var D: float = spec.D; var L: float = spec.L; var r := D / 2.0
	var y0 := LM_GEAR; var y1 := LM_GEAR + L
	var hinge_r := r * 0.96; var hinge_y := LM_GEAR + L * 0.90
	var leg_len := Vector2(LM_PAD_R - hinge_r, hinge_y).length()
	var leg_cant := atan2(LM_PAD_R - hinge_r, hinge_y)     # deployed, and stays
	# The octagonal box, turned so a flat faces +X (ladder, porch, forward leg).
	var box := _mesh(_cylinder(r, r, L, 8), M.gold)
	box.position.y = y0 + L / 2.0; box.rotation.y = PI / 8.0; g.add_child(box)
	# Quadrant panels in black MLI on the four DIAGONAL faces — the cut corners
	# between the tank bays. They are what breaks the shape up.
	for i in 4:
		var a := i / 4.0 * TAU + PI / 4.0
		var p := _mesh(_box(D * 0.34, L * 0.82, 0.07), M.black)
		p.position = Vector3(cos(a) * r * 0.95, y0 + L / 2.0, sin(a) * r * 0.95)
		p.rotation.y = -a; g.add_child(p)
	# The DPS, its lip a hand's breadth above the surface, on a pivot so it has a plume.
	var dp := _grp()
	dp.position.y = y0
	dp.set_meta("gimbal_deg", float(spec.engine.gimbal))
	var b := bell(float(spec.engine.exitD), 47.5); b.scale = Vector3(1, 0.70, 1)
	dp.add_child(b); g.add_child(dp); parts.gimbals.append(dp)
	var skirt := _mesh(_cylinder(0.60, 1.05, L * 0.20, 24, 1, true), M.dirty)
	skirt.position.y = y0 + L * 0.10; g.add_child(skirt)

	# Four legs rooted at the top outrigger, with contact probes under three pads.
	# Built deployed and not registered: the LM's gear came out in lunar orbit, and
	# the leg deploy travel can't reach both poses.
	for i in 4:
		var a := i / 4.0 * TAU
		var h := _grp()
		h.position = Vector3(cos(a) * hinge_r, hinge_y, sin(a) * hinge_r)
		h.rotation.y = -a
		var leg := landing_leg(leg_len, 0.47, 0.0 if i == 0 else 1.7)
		leg.rotation.z = leg_cant
		h.add_child(leg)
		# The outrigger the strut roots into. It is structure, not gear, so it
		# hangs on the stage rather than on the hinge that swings.
		var out := _mesh(_cylinder(0.09, 0.09, r * 0.49, 6), M.alu)
		out.rotation.z = PI / 2.0
		out.position = Vector3(cos(a) * r * 0.74, hinge_y, sin(a) * r * 0.74)
		out.rotation.y = 0.0; g.add_child(out)
		# THE LADDER, on the forward leg and slanting with it. Nine rungs from
		# the porch to a bottom rung that stops well short of the pad.
		if i == 0:
			for sgn in [-1.0, 1.0]:
				leg.add_child(beam(Vector3(0.34, leg_len * 0.03, sgn * 0.26),
					Vector3(0.34, -leg_len * 0.80, sgn * 0.26), 0.035, M.alu))
			for k in 9:
				var rung := _mesh(_box(0.09, 0.035, 0.56), M.alu)
				rung.position = Vector3(0.34, leg_len * 0.03 - leg_len * 0.83 * (k / 8.0), 0)
				leg.add_child(rung)
		g.add_child(h)
	# The egress porch above the forward leg, and the MESA beside it — the bay
	# that swung down carrying the TV camera that broadcast the first step.
	var porch := _mesh(_box(0.86, 0.07, 1.02), M.alu)
	porch.position = Vector3(r * 0.86, y1 - 0.03, 0); g.add_child(porch)
	var mesa := _mesh(_box(1.20, 1.05, 0.90), M.dirty)
	mesa.position = Vector3(0, y0 + L * 0.62, r * 0.82); g.add_child(mesa)
	# The landing radar, under the aft face: what the guidance actually flew on
	# below high gate.
	var lr := _mesh(_box(0.66, 0.14, 0.66), M.black)
	lr.position = Vector3(-r * 0.58, y0 - 0.06, 0); g.add_child(lr)
	return {"group": g, "parts": parts}

## The ascent stage, with the LM_GEAR offset built in so build_craft's stacking
## lands it on the descent stage's roof.
static func build_lm_ascent(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var B := LM_GEAR
	# The crew cabin, windows and equipment bay.
	var cab := _mesh(_cylinder(1.17, 1.17, 2.10, 20), M.gold)
	cab.rotation.x = PI / 2.0; cab.position = Vector3(0, B + 2.02, 0.30); g.add_child(cab)
	var mid := _mesh(_box(2.46, 1.86, 2.30), M.gold)
	mid.position = Vector3(0, B + 0.98, -0.22); g.add_child(mid)
	var aft := _mesh(_box(1.90, 1.30, 0.80), M.black)
	aft.position = Vector3(0, B + 1.30, -1.30); g.add_child(aft)
	for sgn in [-1.0, 1.0]:
		var t := _mesh(_sphere(0.72, 18, 12), M.gold)
		t.position = Vector3(sgn * 1.34, B + 1.02, -0.30); g.add_child(t)
		var w := _mesh(_box(0.62, 0.44, 0.12), M.glass)
		w.position = Vector3(sgn * 0.46, B + 2.36, 1.30); w.rotation.x = -0.42; g.add_child(w)
	var hatch := _mesh(_box(0.85, 0.85, 0.12), M.black)
	hatch.position = Vector3(0, B + 1.02, 1.22); g.add_child(hatch)
	var tun := _mesh(_cylinder(0.48, 0.48, 0.32, 18), M.alu)
	tun.position.y = B + 3.06; g.add_child(tun)
	var drogue := _mesh(_cylinder(0.58, 0.44, 0.48, 18), M.dirty)
	drogue.position.y = B + 3.46; g.add_child(drogue)
	# The steerable S-band dish and the rendezvous radar, both pointing outward.
	var d := dish(0.62); d.position = Vector3(1.16, B + 3.00, -0.52); d.rotation.z = -0.85
	g.add_child(d)
	var rr := dish(0.40); rr.position = Vector3(0, B + 3.05, 0.86); rr.rotation.x = 1.15
	g.add_child(rr)
	# The APS is FIXED — no gimbal at all — so the ascent stage steers on RCS
	# alone. It still needs the pivot, because that is where the plume hangs.
	var ap := _grp()
	ap.position.y = B + 0.06
	ap.set_meta("gimbal_deg", float(spec.engine.gimbal))    # 0: declared, and clamped to it
	ap.add_child(bell(float(spec.engine.exitD), 45))
	g.add_child(ap); parts.gimbals.append(ap)
	g.add_child(rcs_ring(3.56, B + 2.48, 4))
	return {"group": g, "parts": parts}

## THE MSL AEROSHELL: a 70° sphere-cone, backshell and parachute cone. Blunt, so the
## shock stands off ahead of the vehicle.
static func build_aeroshell(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var D: float = spec.D                              # 4.5 m
	var hsd = spec.get("heatShield")
	var nose_r := D * 0.25
	if hsd != null and _t(hsd.get("noseR")): nose_r = float(hsd.noseR)
	# Heat shield apex down (sphere_cone guarantees it), shoulder on y = 0.
	var hs := sphere_cone(D, nose_r, 70, M.ablator, 36)
	hs.position.y = D * 0.30
	g.add_child(hs)
	# Backshell: a shallower cone closing the top, in white thermal blanket.
	var bs := _mesh(_cylinder(D * 0.19, D / 2.0, D * 0.36, 36, 1, true), M.white)
	bs.position.y = D * 0.30 + D * 0.18; g.add_child(bs)
	# The joint ring between the two halves — they separate here.
	var ring := _mesh(_torus(D / 2.0 * 1.005, D * 0.012, 6, 36), M.dirty)
	ring.rotation.x = PI / 2.0; ring.position.y = D * 0.30; g.add_child(ring)
	# Parachute cone and its cover, on the axis.
	var pc := _mesh(_cylinder(D * 0.155, D * 0.19, D * 0.10, 24), M.white)
	pc.position.y = D * 0.30 + D * 0.36 + D * 0.05; g.add_child(pc)
	var lid_profile := PackedVector2Array([Vector2(D * 0.155, D * 0.76),
		Vector2(D * 0.150, D * 0.80), Vector2(D * 0.115, D * 0.84), Vector2(0, D * 0.86)])
	g.add_child(_mesh(_lathe(lid_profile, 24), M.dirty))
	# Cruise-stage RCS quads and the tungsten balance masses whose offset CoM gives the
	# capsule its L/D of 0.24.
	for i in 4:
		var a := i / 4.0 * TAU + PI / 4.0
		var q := _mesh(_box(D * 0.07, D * 0.05, D * 0.07), M.dirty)
		q.position = Vector3(cos(a) * D * 0.34, D * 0.52, sin(a) * D * 0.34)
		q.rotation.y = -a; g.add_child(q)
	return {"group": g, "parts": parts}

## THE SKY CRANE: an eight-engine deck that lowers the rover on three bridles. The
## engines are canted out so the plumes miss the rover and don't dig a crater.
static func build_sky_crane(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var D: float = spec.D                              # 3.2 m
	var deck_y := 1.05
	# Octagonal deck, ribbed underneath the way a real truss deck is.
	var deck := _mesh(_cylinder(D / 2.0, D / 2.0 * 0.94, 0.42, 8), M.alu)
	deck.position.y = deck_y; deck.rotation.y = PI / 8.0; g.add_child(deck)
	for i in 8:
		var a := i / 8.0 * TAU
		var rib := _mesh(_box(D * 0.44, 0.10, 0.09), M.dirty)
		rib.position = Vector3(cos(a) * D * 0.24, deck_y - 0.24, sin(a) * D * 0.24)
		rib.rotation.y = -a; g.add_child(rib)
	# Four spherical hydrazine tanks on top — most of the stage's dry volume.
	for i in 4:
		var a := i / 4.0 * TAU + PI / 4.0
		var t := _mesh(_sphere(0.42, 16, 12), M.gold)
		t.position = Vector3(cos(a) * D * 0.26, deck_y + 0.52, sin(a) * D * 0.26)
		g.add_child(t)
	# Avionics box and the descent-stage antenna.
	var av := _mesh(_box(0.62, 0.34, 0.52), M.dirty)
	av.position = Vector3(0, deck_y + 0.42, 0); g.add_child(av)
	# Eight MLEs in four canted pairs. Each pair is a pivot so differential
	# throttle — which is how this stage actually steers — has something to show.
	for i in 4:
		var a := i / 4.0 * TAU + PI / 4.0
		var cant := _grp()
		cant.position = Vector3(cos(a) * D * 0.44, deck_y - 0.20, sin(a) * D * 0.44)
		cant.rotation = Vector3(sin(a) * 0.26, -a, -cos(a) * 0.26)
		var p := _grp()                                # the driven pivot
		cant.add_child(p)
		for dx in [-0.22, 0.22]:
			var b := bell(0.28, 40)
			b.position.x = dx; b.scale = Vector3(1.15, 1.15, 1.15); p.add_child(b)
		g.add_child(cant); parts.gimbals.append(p)
	# The bridle: three cables and the descent-rate limiter they spool from. This
	# is the part that makes it a crane rather than a lander.
	for i in 3:
		var a := i / 3.0 * TAU
		var c := _mesh(_cylinder(0.018, 0.018, 1.5, 5), M.dirty)
		c.basis = Basis(Vector3.UP, -a) * Basis(Vector3.RIGHT, 0.16)
		# Cable origin is the spool end; the cylinder primitive is centered.
		c.position = Vector3(cos(a) * D * 0.20, deck_y - 0.85, -sin(a) * D * 0.20) + c.basis * Vector3(0, -0.75, 0)
		g.add_child(c)
	return {"group": g, "parts": parts}

## CURIOSITY: rocker-bogie, six driven wheels on a passive linkage. No legs; the
## wheels are the landing gear.
static func build_rover(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var wr := 0.2625; var y0 := wr                     # 0.525 m wheels
	var body_y := y0 + 0.62
	# Warm electronics box, 3.0 × 2.7 × 0.8 m: w/h are the X and Z half-extents.
	var body := loft([
		{"y": -0.34, "w": 0.95, "h": 1.16, "n": 3.2},
		{"y": -0.26, "w": 1.12, "h": 1.34, "n": 3.8},
		{"y": 0.26, "w": 1.12, "h": 1.34, "n": 3.8},
		{"y": 0.34, "w": 0.98, "h": 1.18, "n": 3.2},
	], M.alu, 20)
	body.position.y = body_y; g.add_child(body)
	# RTG at the back, canted up, with its cooling fins — the one part of this
	# rover that is visibly hot.
	var rtg := _mesh(_cylinder(0.27, 0.27, 0.62, 14), M.black)
	rtg.position = Vector3(-1.42, body_y + 0.34, 0)
	rtg.rotation = Vector3(0, 0, PI / 2.0 - 0.30); g.add_child(rtg)
	var fins := _grp()
	for i in 8:
		var a := i / 8.0 * TAU
		var fm := _mesh(_box(0.56, 0.22, 0.022), M.dirty)
		fm.position = Vector3(0, sin(a) * 0.26, cos(a) * 0.26)
		fm.rotation.x = -a; fins.add_child(fm)
	fins.position = Vector3(-1.42, body_y + 0.34, 0); fins.rotation.z = -0.30; g.add_child(fins)
	# Remote sensing mast: camera head, and it is 2 m up because that is roughly
	# eye height — the images are meant to look like standing there.
	var mast := _mesh(_cylinder(0.055, 0.07, 1.15, 8), M.dirty)
	mast.position = Vector3(0.72, body_y + 0.92, 0.30); g.add_child(mast)
	var head := _mesh(_box(0.56, 0.20, 0.20), M.dirty)
	head.position = Vector3(0.72, body_y + 1.55, 0.30); g.add_child(head)
	for dx in [-0.20, 0.20]:
		var eye := _mesh(_cylinder(0.055, 0.055, 0.08, 12), M.glass)
		eye.position = Vector3(0.72 + dx, body_y + 1.55, 0.41); eye.rotation.x = PI / 2.0; g.add_child(eye)
	var chemcam := _mesh(_cylinder(0.12, 0.12, 0.16, 12), M.dirty)
	chemcam.position = Vector3(0.72, body_y + 1.76, 0.30); g.add_child(chemcam)
	# High-gain antenna and the robotic arm, stowed against the front.
	var hga := _mesh(_box(0.30, 0.30, 0.05), M.dirty)
	hga.position = Vector3(-0.55, body_y + 0.55, -0.55); hga.rotation = Vector3(0.5, 0.6, 0); g.add_child(hga)
	var arm := _mesh(_cylinder(0.07, 0.07, 1.05, 8), M.alu)
	arm.position = Vector3(1.18, body_y - 0.18, 0); arm.rotation.z = 1.15; g.add_child(arm)
	# rocker-bogie. The rocker runs the length of each side; the bogie is
	# the short rear link that carries two of the three wheels.
	for sz in [1.0, -1.0]:
		var side := _grp()
		side.position.z = sz * 0.72
		var rocker := _mesh(_cylinder(0.045, 0.045, 1.55, 6), M.dirty)
		rocker.position = Vector3(0.20, body_y - 0.16, 0); rocker.rotation.z = PI / 2.0 - 0.30
		side.add_child(rocker)
		var bogie := _mesh(_cylinder(0.04, 0.04, 0.95, 6), M.dirty)
		bogie.position = Vector3(-0.75, y0 + 0.30, 0); bogie.rotation.z = PI / 2.0 + 0.22
		side.add_child(bogie)
		for xd in [[1.05, 0.0], [-0.30, 0.0], [-1.18, 0.0]]:
			var x: float = xd[0]
			var leg := _mesh(_cylinder(0.035, 0.035, 0.52, 6), M.dirty)
			leg.position = Vector3(x, y0 + 0.26 + xd[1], 0); side.add_child(leg)
			# Wheel: a drum with cleats, because the grousers are what you see.
			var w := _mesh(_cylinder(wr, wr, 0.40, 16, 1, true), M.dirty)
			w.rotation.x = PI / 2.0; w.position = Vector3(x, y0, 0); side.add_child(w)
			for k in 10:
				var a := k / 10.0 * TAU
				var cl := _mesh(_box(0.022, 0.05, 0.38), M.alu)
				cl.position = Vector3(x + cos(a) * wr * 0.99, y0 + sin(a) * wr * 0.99, 0)
				cl.rotation.z = -a; side.add_child(cl)
			# Hub face, so a wheel is a wheel and not an open tube.
			for zf in [-1.0, 1.0]:
				var hub := _mesh(_circle(wr * 0.98, 16), M.dirty)
				hub.position = Vector3(x, y0, zf * 0.20); hub.rotation.y = 0.0 if zf > 0 else PI
				side.add_child(hub)
		g.add_child(side)
	return {"group": g, "parts": parts}

static func build_ion_bus(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var bus := _mesh(_box(1.64, 1.36, 1.64), M.gold)
	bus.position.y = 0.9; g.add_child(bus)
	for side in [1.0, -1.0]:
		var arm := _grp()
		arm.position = Vector3(side * 0.92, 0.9, 0)
		arm.add_child(beam(Vector3.ZERO, Vector3(side * 0.55, 0, 0), 0.05))
		var a := solar_array(8.3, 2.2); a.position.x = side * 4.7; arm.add_child(a)
		g.add_child(arm); parts.arrays.append(arm)
	var adapter := _mesh(_cylinder(1.64 * 0.46, 1.64 * 0.30, 0.22, 20), M.alu)
	adapter.position.y = 0.11; g.add_child(adapter)
	var d := dish(0.82); d.position.y = 1.58; g.add_child(d)
	var feed := _mesh(_cylinder(0.03, 0.03, 0.46, 8), M.dirty)
	feed.position.y = 1.91; g.add_child(feed)
	var horn := _mesh(_sphere(0.09, 12, 8), M.dirty)
	horn.position.y = 2.16; g.add_child(horn)
	# Three gridded ion thrusters. They are small, and they should look it.
	for i in 3:
		var a := i / 3.0 * TAU
		var th := _grp()
		th.position = Vector3(cos(a) * 0.42, 0.1, sin(a) * 0.42)
		var cyl := _mesh(_cylinder(0.18, 0.16, 0.32, 14), M.nozzle)
		cyl.position.y = -0.16; th.add_child(cyl)
		var grid := _mesh(_circle(0.17, 16), M.black)
		grid.position.y = -0.33; grid.rotation.x = PI / 2.0; th.add_child(grid)
		g.add_child(th); parts.gimbals.append(th)
	return {"group": g, "parts": parts}

# THE HAIL MARY

## A SPIN DRIVE, not a bell. Astrophage radiates light, so there is nothing to
## expand: a recessed emitter plate behind a shallow reflector. Short (light needs
## no expansion length) and small (thrust is P/c). Built from the exit plane up,
## with the pivot on that plane, since the plume parents to it. `mount` carries
## the position; `pivot` stays identity and is what gets registered.
static func spin_drive(R: float) -> Dictionary:
	var mount := _grp()
	var pivot := _grp()
	# Rigid: it steers by differential power, so declare zero swing.
	pivot.set_meta("gimbal_deg", 0.0)
	mount.add_child(pivot)
	# The reflector, lathed on a curve rather than struck as a cone — the curve
	# is the whole difference between a bell mouth and a funnel.
	var prof := PackedVector2Array()
	for i in 9:
		var u := i / 8.0
		prof.append(Vector2(R * (1.0 - 0.42 * u * u), R * 1.05 * u))
	var neck_r := R * 0.58; var neck_y := R * 1.42
	prof.append(Vector2(neck_r, neck_y))
	pivot.add_child(_mesh(_lathe(prof, 24), M.nozzle))
	var lip := _mesh(_torus(R, R * 0.055, 4, 24), M.alu)
	lip.rotation.x = PI / 2.0; pivot.add_child(lip)
	# The plate is recessed inside the reflector.
	var plate_r := R * 0.80; var plate_y := R * 0.55
	# Both plate and cells emit (HDR values, see M.emitPlate).
	var face := _mesh(_circle(plate_r, 24), M.emitPlate)
	face.position.y = plate_y; face.rotation.x = PI / 2.0; pivot.add_child(face)
	for ring in range(1, 4):
		var rr := plate_r * 0.27 * ring; var cnt := 6 * ring
		for k in cnt:
			var b := float(k) / cnt * TAU + ring * 0.4
			var cell := _mesh(_circle(plate_r * 0.11, 6), M.emitCell)
			cell.position = Vector3(cos(b) * rr, plate_y - R * 0.004, sin(b) * rr)
			cell.rotation = Vector3(PI / 2.0, 0, -b)
			pivot.add_child(cell)
	# Cooling ribs down the reflector.
	for i in 8:
		var a := i / 8.0 * TAU
		var rib := _mesh(_box(R * 0.055, R * 0.95, R * 0.10), M.alu)
		rib.position = Vector3(cos(a) * R * 0.86, R * 0.52, sin(a) * R * 0.86)
		rib.rotation = Vector3(0, -a, 0.11)
		pivot.add_child(rib)
	# A closing disc at the neck, so you cannot see up inside the ship.
	var shut := _mesh(_circle(neck_r, 20), M.dirty)
	shut.position.y = neck_y; shut.rotation.x = -PI / 2.0; pivot.add_child(shut)
	# The emitter can: the machinery the plate is the front face of.
	var can := _mesh(_cylinder(neck_r * 1.10, neck_r, R * 0.62, 20, 1, true), M.dirty)
	can.position.y = neck_y + R * 0.31; pivot.add_child(can)
	var collar := _mesh(_torus(neck_r * 1.13, R * 0.05, 4, 20), M.alu)
	collar.rotation.x = PI / 2.0; collar.position.y = neck_y + R * 0.10; pivot.add_child(collar)
	return {"mount": mount, "pivot": pivot, "neckR": neck_r, "topY": neck_y + R * 0.62}

## The Hail Mary, after the 2026 film: three tanks in a triangle round a central
## drive drum, a train of crew modules forward of it between them, two solar wings
## astern. Each tank tapers aft through an S-bend to its own drive beside the drum;
## all four drives fire parallel to the axis through one plane. The layout is in
## metres at the film's 104 m, shared with model_sources/blender/hailmary.py.
## Fallback for the authored .glb.
const HM_MODULES := [[35.0, 42.0, 4.0, "white", "hub"], [42.0, 44.6, 2.6, "gold", "plain"],
	[44.6, 47.5, 2.1, "alu", "node"], [47.5, 54.0, 3.1, "white", "ringed"],
	[54.0, 55.6, 2.2, "dirty", "plain"], [55.6, 62.3, 3.0, "white", "quilt"],
	[62.3, 67.5, 3.0, "white", "berth"], [67.5, 77.8, 3.0, "white", "banded"],
	[77.8, 83.4, 2.1, "white", "plain"], [83.4, 86.0, 2.35, "soot", "plain"],
	[86.0, 93.4, 2.3, "white", "greeble"], [93.4, 100.6, 2.3, "white", "hatch"],
	[100.6, 104.0, 2.3, "alu", "dock"]]

static func build_hail_mary(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var k: float = float(spec.L) / 104.0
	var look: Dictionary = spec.get("look", {})
	var tr := 11.4 * k; var tank_r := 4.0 * k; var taper_y := 29.4 * k; var top_y := 100.0 * k
	var tip_x := 6.6 * k; var tip_y := 1.6 * k; var tip_r := 1.45 * k
	var bay0 := 42.7 * k; var bay1 := 51.5 * k; var core_r := 2.6 * k
	var drum_r := 5.0 * k; var drum_y0 := 9.5 * k; var drum_y1 := 34.0 * k
	var dR := 0.82 * k; var dR0 := 1.1 * k
	var radius_at := func(y: float) -> float:
		if y >= taper_y:
			if y > bay0 and y < bay1:
				return tank_r + (core_r - tank_r) * minf(minf(y - bay0, bay1 - y) / (0.8 * k), 1.0)
			return tank_r
		return tip_r + (tank_r - tip_r) * pow(maxf((y - tip_y) / (taper_y - tip_y), 0.0), 0.85)

	# the drum, its bands and brackets
	var prof := PackedVector2Array([Vector2(0, drum_y0), Vector2(3.6 * k, drum_y0),
		Vector2(4.5 * k, drum_y0 + 0.6 * k), Vector2(drum_r, drum_y0 + 1.6 * k), Vector2(drum_r, drum_y1 - 1.0 * k),
		Vector2(5.6 * k, drum_y1), Vector2(5.7 * k, drum_y1 + 0.6 * k), Vector2(5.4 * k, drum_y1 + 0.9 * k),
		Vector2(4.4 * k, drum_y1 + 0.7 * k), Vector2(0, drum_y1 + 0.7 * k)])
	g.add_child(_mesh(_lathe(prof, 36), M.dirty))
	for yb in [15.0 * k, 28.0 * k]:
		var b := _mesh(_torus(drum_r * 1.01, 0.14 * k, 4, 36), M.alu)
		b.rotation.x = PI / 2.0; b.position.y = yb; g.add_child(b)
	for row in 3:
		var yb: float = [12.5, 21.0, 31.0][row] * k
		for i in 16:
			var a := i / 16.0 * TAU + row * 0.2
			var br := _mesh(_box(0.35 * k, 0.8 * k, 0.6 * k), M.alu)
			br.position = Vector3(cos(a) * drum_r * 1.03, yb, -sin(a) * drum_r * 1.03)
			br.rotation.y = a; g.add_child(br)
	# the central drive, its neck, and the thrust units round it
	var axial := spin_drive(dR0)
	g.add_child(axial.mount); parts.gimbals.append(axial.pivot)
	g.add_child(_mesh(_lathe(PackedVector2Array([Vector2(0, axial.topY - 0.05 * k), Vector2(0.9 * k, axial.topY - 0.05 * k),
		Vector2(1.2 * k, drum_y0 + 0.05 * k), Vector2(0, drum_y0 + 0.05 * k)]), 18), M.dirty))
	for i in 6:
		var a := i / 6.0 * TAU + PI / 6.0
		var y0 := (0.7 + 0.45 * ((i * 3) % 5)) * k
		var c := Vector3(cos(a) * 2.9 * k, 0, -sin(a) * 2.9 * k)
		var u := _mesh(_cylinder(0.75 * k, 0.75 * k, drum_y0 + 0.1 * k - y0, 14), M.nozzle)
		u.position = c + Vector3(0, (y0 + drum_y0 + 0.1 * k) / 2.0, 0); g.add_child(u)
		var face := _mesh(_circle(0.54 * k, 14), M.emitPlate)
		face.position = c + Vector3(0, y0 - 0.01 * k, 0); face.rotation.x = PI / 2.0; g.add_child(face)

	# the three tanks: barrel, open bay, S-bend taper to a drive
	var path := []
	for i in 24:
		path.append(Vector3(tr, top_y + (taper_y - top_y) * i / 24.0, 0))
	for i in 21:
		var t := 1.0 - i / 20.0
		var sm := t * t * (3.0 - 2.0 * t)
		path.append(Vector3(tip_x + (tr - tip_x) * sm, tip_y + (taper_y - tip_y) * t, 0))
	var radii := []
	for p in path: radii.append(radius_at.call((p as Vector3).y))
	for i in 3:
		var a := i / 3.0 * TAU + PI / 2.0
		var t := _grp()
		# Blender's +Y is Godot's −Z, so its turn about +Z is this one about +Y.
		t.rotation.y = a
		t.add_child(bent_tube(path, tank_r, M.white, 28, radii).mesh)
		var cap_r := tank_r * 0.93
		var cap_prof := PackedVector2Array([Vector2(tank_r * 0.999, top_y), Vector2(cap_r, top_y + 0.25 * k), Vector2(cap_r, top_y + 1.0 * k)])
		for j in range(1, 9):
			var w := j / 8.0 * PI / 2.0
			cap_prof.append(Vector2(cap_r * cos(w), top_y + 1.0 * k + 0.7 * k * sin(w)))
		var cap := _mesh(_lathe(cap_prof, 28), M.dirty)
		cap.position.x = tr; t.add_child(cap)
		for bd in [[57.7, 61.8, M.soot, 1.012], [87.0, 89.6, M.gold, 1.016], [94.0, 94.6, M.soot, 1.012], [36.6, 42.7, M.dirty, 1.006]]:
			var h: float = (bd[1] - bd[0]) * k
			var band := _mesh(_cylinder(tank_r * bd[3], tank_r * bd[3], h, 28, 1, true), bd[2])
			band.position = Vector3(tr, (bd[0] + bd[1]) * 0.5 * k, 0); t.add_child(band)
		for yc in [taper_y + 0.2 * k, 33.0 * k, bay0, bay1, (bay0 + bay1) / 2.0]:
			var ring := _mesh(_torus(tank_r * 1.02, 0.17 * k, 4, 28), M.alu)
			ring.rotation.x = PI / 2.0; ring.position = Vector3(tr, yc, 0); t.add_child(ring)
		for j in 10:
			var b := j / 10.0 * TAU
			var p0 := Vector3(tr + cos(b) * tank_r, bay0, sin(b) * tank_r)
			t.add_child(beam(p0, Vector3(p0.x, bay1, p0.z), 0.12 * k))
		var door := _mesh(_box(0.08 * k, 2.4 * k, 2.4 * k), M.soot)
		door.position = Vector3(tr + tank_r * 1.01, 63.5 * k, 0); t.add_child(door)
		var tip_ring := _mesh(_torus(tip_r * 1.01, 0.12 * k, 4, 24), M.alu)
		tip_ring.rotation.x = PI / 2.0; tip_ring.position = Vector3(tip_x, tip_y, 0); t.add_child(tip_ring)
		var tip_cap := _mesh(_circle(tip_r, 24), M.dirty)
		tip_cap.rotation.x = PI / 2.0; tip_cap.position = Vector3(tip_x, tip_y, 0); t.add_child(tip_cap)
		var drv := spin_drive(dR)
		drv.mount.position = Vector3(tip_x, 0, 0)
		t.add_child(drv.mount); parts.gimbals.append(drv.pivot)
		g.add_child(t)

	# struts to the drum and the stack, girth ties, the aft truss
	var rp := func(i: float, r: float, y: float) -> Vector3:
		var a := i / 3.0 * TAU + PI / 2.0
		return Vector3(cos(a) * r, y, -sin(a) * r)
	for tie in [[22.0, drum_r], [38.0, 4.0 * k], [60.0, 3.0 * k], [91.0, 2.3 * k]]:
		for i in 3:
			for sd in [-0.035, 0.035]:
				g.add_child(beam(rp.call(float(i), tie[1] * 0.98, tie[0] * k),
					rp.call(i + sd * 3.0, tr - tank_r * 0.97, tie[0] * k), 0.16 * k))
	for yg in [70.0 * k, 97.0 * k]:
		for i in 3:
			g.add_child(beam(rp.call(i + 0.13, tr - tank_r * 0.2, yg), rp.call(i + 0.87, tr - tank_r * 0.2, yg), 0.14 * k))
	for i in 3:
		for sd in [-1.0, 1.0]:
			g.add_child(beam(rp.call(float(i), tip_x, tip_y + 0.6 * k), rp.call(i + sd * 0.25, 3.8 * k, drum_y0 + 0.3 * k), 0.13 * k))

	# the crew stack
	for md in HM_MODULES:
		var y0: float = md[0] * k; var y1: float = md[1] * k; var r: float = md[2] * k
		var kind: String = md[4]
		var mp := PackedVector2Array()
		if kind == "dock":
			mp = PackedVector2Array([Vector2(0, y0), Vector2(r, y0), Vector2(r, y0 + 1.0 * k), Vector2(1.6 * k, y1 - 0.4 * k), Vector2(1.6 * k, y1), Vector2(0, y1)])
		elif kind == "node":
			mp.append(Vector2(0, y0))
			for j in 9: mp.append(Vector2(r * (0.75 + 0.25 * sin(j / 8.0 * PI)), y0 + (y1 - y0) * j / 8.0))
			mp.append(Vector2(0, y1))
		else:
			mp = PackedVector2Array([Vector2(0, y0), Vector2(r * 0.92, y0), Vector2(r, y0 + 0.25 * k), Vector2(r, y1 - 0.25 * k), Vector2(r * 0.92, y1), Vector2(0, y1)])
		g.add_child(_mesh(_lathe(mp, 28), M[md[3]]))
		if kind == "ringed" or kind == "hub":
			var n := 4 if kind == "ringed" else 2
			for j in n:
				var fr := _mesh(_torus(r * 1.02, 0.10 * k, 4, 28), M.alu)
				fr.rotation.x = PI / 2.0; fr.position.y = y0 + (y1 - y0) * (j + 0.5) / n; g.add_child(fr)
		elif kind == "banded":
			var bd := _mesh(_cylinder(r * 1.012, r * 1.012, 1.0 * k, 28, 1, true), M.soot)
			bd.position.y = (y0 + y1) / 2.0; g.add_child(bd)
		elif kind == "berth":
			var br := _mesh(_torus(1.25 * k, 0.16 * k, 4, 20), M.alu)
			br.rotation.y = PI / 2.0; br.position = Vector3(r, (y0 + y1) / 2.0, 0); g.add_child(br)
		elif kind == "dock":
			var dr := _mesh(_torus(1.45 * k, 0.12 * k, 4, 20), M.alu)
			dr.rotation.x = PI / 2.0; dr.position.y = y1; g.add_child(dr)
	g.add_child(beam(Vector3(0, 97.0 * k, -2.2 * k), Vector3(0, 97.0 * k, -5.5 * k), 0.09 * k))
	g.add_child(beam(Vector3(-2.3 * k, 90.0 * k, 0), Vector3(-4.1 * k, 90.0 * k, 0), 0.10 * k))
	var hg := dish(1.2 * k)
	hg.position = Vector3(-4.1 * k, 90.0 * k, 0); hg.rotation.z = 0.9; g.add_child(hg)
	var nB := int(_n(look.get("beetles"), 0.0))
	for i in nB:
		var a := float(i) / nB * TAU
		var bt := _mesh(_capsule(0.42 * k, 1.8 * k, 5, 12), M.dirty)
		bt.position = Vector3(cos(a) * 2.75 * k, 80.6 * k, -sin(a) * 2.75 * k); g.add_child(bt)

	# two solar wings astern, between the tanks: fixed structure, not parts.arrays
	var wy := (13.9 + 15.6) * 0.5 * k
	for side in [1.0, -1.0]:
		var wing := _grp()
		wing.rotation.y = 0.0 if side > 0 else PI
		wing.add_child(beam(Vector3(drum_r * 0.98, wy, 0), Vector3(52.6 * k, wy, 0), 0.30 * k))
		var nP := 9; var seg := (52.0 - 15.0) * k / nP
		for col in [[5.5, 13.9], [15.6, 24.0]]:
			for j in nP:
				var pnl := _mesh(_box(seg * 0.96, (col[1] - col[0]) * k, 0.08 * k), M.solar)
				pnl.position = Vector3(15.0 * k + seg * (j + 0.5), (col[0] + col[1]) * 0.5 * k, 0); wing.add_child(pnl)
		g.add_child(wing)
	g.add_child(rcs_ring(6.0 * k, 65.0 * k, 4))
	return {"group": g, "parts": parts}

static func build_beetle(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var D: float = spec.D
	var R := D / 2.0
	var cap := R * 0.42
	# Barrel stations and dome depth match model_sources/blender/beetle.py.
	var h0 := 1.55; var h1 := 3.70
	var profile := PackedVector2Array([Vector2(0, h0 - cap)])
	for i in range(1, 9):
		var a := i / 8.0 * PI / 2.0
		profile.append(Vector2(R * sin(a), h0 - cap * cos(a)))
	profile.append(Vector2(R, h1))
	for i in range(1, 9):
		var a := i / 8.0 * PI / 2.0
		profile.append(Vector2(R * cos(a), h1 + cap * sin(a)))
	g.add_child(_mesh(_lathe(profile, 24), M.dirty))
	for k in 4:
		var hoop := _mesh(_torus(R * 1.015, D * 0.018, 8, 24), M.alu)
		hoop.rotation.x = PI / 2.0; hoop.position.y = h0 + (h1 - h0) * (k + 0.5) / 4.0
		g.add_child(hoop)
	# The drive exits at y=0; its shallow reflector and can sit forward of it.
	var dr := R * 0.46; var neck := dr * 1.42
	var drive := _grp()
	var reflector := PackedVector2Array()
	for i in 9:
		var u := i / 8.0
		reflector.append(Vector2(dr * u, neck * (1.0 - u * u) * 0.62))
	reflector.append(Vector2(dr * 1.06, -0.02))
	drive.add_child(_mesh(_lathe(reflector, 24), M.alu))
	var lip := _mesh(_torus(dr * 1.05, dr * 0.055, 8, 24), M.alu)
	lip.rotation.x = PI / 2.0; lip.position.y = -0.01; drive.add_child(lip)
	var plate := _mesh(_cylinder(dr * 0.90, dr * 0.90, neck * 0.06, 20), M.emitPlate)
	plate.position.y = neck * 0.37; drive.add_child(plate)
	var can := _mesh(_cylinder(dr * 0.72, dr * 0.82, neck * 0.75, 20), M.dirty)
	can.position.y = neck * 0.775; drive.add_child(can)
	g.add_child(drive); parts.gimbals.append(drive)
	var skirt := _mesh(_cylinder(R * 0.92, dr * 1.15, 1.30 - neck * 1.15 * 0.94, 24), M.dirty)
	skirt.position.y = (1.30 + neck * 1.15 * 0.94) / 2.0; g.add_child(skirt)
	var antenna := _grp()
	antenna.position = Vector3(R * 0.98 + D * 0.19, h1 - 0.30, 0)
	antenna.rotation.z = -0.62
	var dish_profile := PackedVector2Array()
	var rd := D * 0.33
	for i in 13:
		var u := i / 12.0
		dish_profile.append(Vector2(rd * u, rd * 0.30 * u * u))
	antenna.add_child(_mesh(_lathe(dish_profile, 24), M.white))
	var feed := _mesh(_cylinder(rd * 0.14, rd * 0.11, rd * 0.14, 12), M.dirty)
	feed.position.y = rd * 0.83; antenna.add_child(feed); g.add_child(antenna)
	var horn_profile := PackedVector2Array([Vector2(0.05, h1 + cap * 0.96),
		Vector2(0.05, h1 + cap + 0.16), Vector2(0.17, h1 + cap + 0.30)])
	g.add_child(_mesh(_lathe(horn_profile, 16), M.alu))
	return {"group": g, "parts": parts}

# Bounds include each mesh transformed through its full parent chain.
## `n`'s transform relative to the top of its hierarchy (global in a tree; the
## product of locals up to the parentless root otherwise, since crafts are built
## before being added).
static func world_xform(n: Node3D) -> Transform3D:
	var t := n.transform
	var p := n.get_parent()
	while p != null:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t

## Box3.setFromObject: every mesh's local box transformed and unioned, invisible
## meshes included. Size < 0 when there is nothing to measure.
static func measure(obj: Node3D, skip: Node = null) -> AABB:
	var acc := [false, AABB()]
	_measure_into(obj, world_xform(obj), acc, skip)
	return acc[1] if acc[0] else AABB(Vector3.ZERO, Vector3(-1, -1, -1))

static func _measure_into(n: Node, xf: Transform3D, acc: Array, skip: Node) -> void:
	if n == skip: return
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var b := xf * (n as MeshInstance3D).mesh.get_aabb()
		if acc[0]: acc[1] = (acc[1] as AABB).merge(b)
		else:
			acc[0] = true; acc[1] = b
	for c in n.get_children():
		if c is Node3D:
			_measure_into(c, xf * (c as Node3D).transform, acc, skip)

## Triangle count of everything under `obj` (the audit's third column).
static func triangles(obj: Node) -> int:
	var tris := 0
	if obj is MeshInstance3D and (obj as MeshInstance3D).mesh is ArrayMesh:
		var m: ArrayMesh = (obj as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var ni := m.surface_get_array_index_len(s)
			tris += (ni if ni > 0 else m.surface_get_array_len(s)) / 3
	for c in obj.get_children():
		tris += triangles(c)
	return tris

## Pose a drag chute (`chutes` part, built deployed along its −Y and packed by
## ShuttleLines.CHUTE_PACK) from `ch` = {t: s since the deploy command, gone: s since
## the jettison or < 0, dir: downstream in the stage frame, gs: ground speed, m/s}, or
## null while stowed. Out on the riser after the mortar, its canopy as wide as the
## square root of the drag area it is giving; jettisoned, it stays on the runway and
## collapses as the vehicle rolls away from it.
static func drive_chute(node: Node3D, ch, dc: Dictionary) -> void:
	if not node.has_meta("base"): node.set_meta("base", node.position)
	var base: Vector3 = node.get_meta("base")
	if ch == null or dc.is_empty() or float(ch.t) < float(dc.mortar):
		node.visible = false
		node.position = base
		node.basis = Basis.from_scale(Vector3.ONE * ShuttleLines.CHUTE_PACK)
		return
	var t := float(ch.t)
	var ext := smoothstep(float(dc.mortar), float(dc.mortar) + 0.7, t)
	var wide := maxf(sqrt(Vessel.drag_chute_area(t, dc)), 0.08)
	# Reefed, the canopy is long and narrow.
	var length := ext * lerpf(1.15, 1.0, clampf((wide - 0.6) / 0.4, 0.0, 1.0))
	var gone := float(ch.get("gone", -1.0))
	var drift := 0.0
	if gone >= 0.0:
		if gone > 3.0:
			node.visible = false
			return
		wide *= lerpf(1.0, 0.15, clampf(gone / 1.5, 0.0, 1.0))
		drift = float(ch.get("gs", 0.0)) * gone
	var dir: Vector3 = ch.get("dir", Vector3.DOWN)
	node.visible = true
	node.position = base + dir * drift
	node.basis = Basis(Quaternion(Vector3.DOWN, dir.normalized())) * Basis.from_scale(Vector3(wide, maxf(length, 1e-3), wide))

# THE VEHICLE
## How far the orbiter's payload bay doors swing open, rad.
const DOOR_OPEN := 175.5 * PI / 180.0

## One stage of a built craft: {key, spec, group, parts, base_y, deploy, sep}.
class CraftStage extends RefCounted:
	var key: String
	var spec: Dictionary
	var group: Node3D
	## {gimbals, fins, legs, arrays, flaps, halves, doors, pieces, nozzles, chutes}: Arrays of Node3D.
	var parts: Dictionary
	var base_y := 0.0
	var deploy := 0.0
	var gear := 0.0
	## null, or Separation.start's state while a separated stage leaves.
	var sep = null
	## Its pieces were handed on to Fall (`update`'s `release`): no longer the craft's.
	var handed := false

## A built vehicle: `group` (root), `stages` (CraftStage, bottom to top),
## `height` (measured, m), `authored` (any stage used the .glb), update(), separate().
class Craft extends RefCounted:
	var group: Node3D
	var stages: Array = []
	var height := 0.0
	var authored := false

	## Drive every moving part from the flight state; nothing is on a timer. `s` is
	## {dt, attached: {key: bool}, deploy: {key: 0..1}, gear: {key: 0..1}, gimbal: {x, z},
	## flap (float or Array, rad), finTwist (Array, rad), gearStage, accel (the stack's
	## non-gravitational acceleration, m/s², a Vector3 in the craft frame or a float
	## along +Y, which separated stages fall behind at), simDt (simulated seconds this
	## frame, which separated stages fly on; dt when absent), release (Callable(stage,
	## sep): takes the pieces of a stage with a fate, `look.fall`, once Separation is
	## done with them; without it they stay drawn for Separation.SHOWN), chute: {key: {t,
	## gone, dir, gs}} for a drag chute out (drive_chute)}.
	func update(s: Dictionary) -> void:
		var dt := float(s.get("dt", 0.0))
		var attached: Dictionary = s.get("attached", {}) if s.get("attached") != null else {}
		var deploy: Dictionary = s.get("deploy", {}) if s.get("deploy") != null else {}
		var gim: Dictionary = s.get("gimbal", {}) if s.get("gimbal") != null else {}
		var acc = s.get("accel", 0.0)
		var a_stack: Vector3 = acc if acc is Vector3 else Vector3(0.0, float(acc), 0.0)
		var release = s.get("release")
		for st: CraftStage in stages:
			if st.handed: continue
			var a = attached.get(st.key)
			var live: bool = not (a is bool and a == false)
			st.group.visible = live or st.sep != null
			if st.sep != null:
				var go := true
				var left := float(s.get("simDt", dt))
				while left > 0.0 and go:
					var h := minf(left, Separation.STEP)
					go = Separation.step(st.sep, h, group.basis, a_stack)
					left -= h
				if go and release is Callable and (release as Callable).is_valid() \
						and st.spec.get("look", {}).has("fall") and float(st.sep.t) >= Separation.handoff_time(st.sep):
					(release as Callable).call(st, st.sep)
					st.handed = true; st.sep = null
				elif not go:
					st.group.visible = false; st.sep = null
				continue
			# deployables, eased so they take a real second or two
			var want := 0.0
			var gs = s.get("gearStage")
			if (gs != null and str(gs) == st.key) or live:
				want = float(U.nz(deploy.get(st.key), 0.0))
			var cover_key := str(st.spec.get("look", {}).get("arrayCover", ""))
			if cover_key != "":
				var cover := stage(cover_key)
				var cover_live = attached.get(cover_key)
				# Keep arrays folded until the jettisoned shell finishes its visible drift.
				if cover == null or not (cover_live is bool and cover_live == false) or cover.sep != null:
					want = 0.0
					st.deploy = 0.0
			st.deploy += clampf(want - st.deploy, -dt * 0.55, dt * 0.55)
			var d := st.deploy
			# Landing gear that swings its own angle (`look.gearSwing`, the orbiter's
			# wheels) runs on the `gear` channel, apart from the stage's other deployables.
			var swing := float(st.spec.get("look", {}).get("gearSwing", 0.0))
			if swing > 0.0:
				var gin = s.get("gear", {})
				var gw := float(gin.get(st.key, 0.0)) if gin is Dictionary else 0.0
				st.gear += clampf(gw - st.gear, -dt * 0.45, dt * 0.45)
				for leg: Node3D in st.parts.legs: leg.rotation.z = -st.gear * swing
			else:
				for leg: Node3D in st.parts.legs: leg.rotation.z = -d * 1.15
			# A grid fin steers by twisting about its own span: its local X, outboard.
			var twist = s.get("finTwist")
			for i in st.parts.fins.size():
				var fin: Node3D = st.parts.fins[i]
				fin.rotation.z = -d * 1.35
				fin.rotation.x = float(twist[i]) if twist is Array and i < twist.size() else 0.0
			for arr: Node3D in st.parts.arrays: arr.rotation.z = (1.0 - d) * (PI / 2.0)
			for door: Node3D in st.parts.doors: door.rotation.z = d * DOOR_OPEN
			for h: Node3D in st.parts.halves:
				h.rotation.z = 0.0; h.position.x = 0.0
			# gimbal: the commanded deflection, clamped per pivot to its `gimbal_deg`; a pivot
			# without one is left unclamped.
			var gx := float(U.nz(gim.get("x"), 0.0)); var gz := float(U.nz(gim.get("z"), 0.0))
			for p: Node3D in st.parts.gimbals:
				var lim := float(p.get_meta("gimbal_deg", 90.0)) * PI / 180.0
				p.rotation.x = clampf(gz, -lim, lim)
				p.rotation.z = clampf(-gx, -lim, lim)
			# One value turns every flap by 0.6 of it (the orbiter's body flap); an array sets
			# each, rad, in parts order.
			var flap = s.get("flap")
			for i in st.parts.flaps.size():
				var f: Node3D = st.parts.flaps[i]
				f.rotation.z = (float(flap[i]) if i < flap.size() else 0.0) if flap is Array else float(U.nz(flap, 0.0)) * 0.6
			var chutes = s.get("chute")
			for c: Node3D in st.parts.chutes:
				CraftModel.drive_chute(c, chutes.get(st.key) if chutes is Dictionary else null, st.spec.get("dragChute", {}))

	## Detach a stage: it stops following the stack and leaves under Separation. A
	## stage made of pieces (`look.pieces`, a fairing's halves) sends each off on its
	## own. `ctx`: Separation.start's {mass, support}; without a mass, the specs of the
	## stages still flying stand in.
	func separate(key: String, ctx := {}) -> void:
		var st := stage(key)
		if st == null or st.sep != null or st.handed: return
		var nodes: Array = st.parts.pieces if not st.parts.pieces.is_empty() else st.parts.halves
		if nodes.is_empty(): nodes = [st.group]
		if not ctx.has("mass"):
			var m := 0.0
			for o: CraftStage in stages:
				if o != st and o.sep == null and o.group.visible: m += float(o.spec.dry) + float(o.spec.prop)
			ctx = ctx.duplicate(); ctx.mass = m
		st.sep = Separation.start(st.spec, st.group, nodes, group.basis, ctx)

	## Find a stage record by key, or null.
	func stage(key: String) -> CraftStage:
		for st: CraftStage in stages:
			if st.key == key: return st
		return null

## Build a whole vehicle, stages stacked bottom to top along +Y (the thrust axis).
## Synchronous: it reads CraftAssets' cache and never waits, so fill it first
## (craft_models_ready(id)) or this builds the fallback.
static func build_craft(vehicle: Dictionary) -> Craft:
	_init_mats()
	var root := _grp()
	root.name = "craft_" + str(vehicle.get("id", ""))
	var craft := Craft.new()
	var y := 0.0
	var specs: Array = vehicle.stages
	for i in specs.size():
		var spec: Dictionary = specs[i]
		# The next stage's diameter, for an adapting interstage.
		var next_d: float = specs[i + 1].D if i + 1 < specs.size() else spec.D
		var built := build_stage(spec, {"id": vehicle.get("id", ""), "nextD": next_d, "vehicle": vehicle})
		var group: Node3D = built.group
		# NOT "stage_<key>": that prefix is the authored file's own stage node,
		# which sits INSIDE this group, and is_authored() looks for it there.
		group.name = "st_" + str(spec.key)
		# A mounted stage sits on the core (the orbiter on the tank's side) and doesn't
		# advance the stack height.
		var look = spec.get("look")
		var mount = look.get("mount") if look != null else null
		if mount != null:
			group.position = Vector3(_n(mount.get("x")), _n(mount.get("y")), _n(mount.get("z")))
		else:
			group.position = Vector3(0, y, 0)
		root.add_child(group)
		var st := CraftStage.new()
		st.key = str(spec.key); st.spec = spec; st.group = group; st.parts = built.parts
		st.base_y = group.position.y
		craft.stages.append(st)
		if mount == null:
			y += float(spec.L) + (_n(look.get("interstage")) if look != null else 0.0)
	# Stack height is a measured extent, since mounted stages break a sum of lengths.
	# Camera framing, pad handover and vessel length read it.
	var bb := measure(root)
	var height := bb.size.y if bb.size.y >= 0.0 else y
	root.set_meta("height", height)
	craft.group = root
	craft.height = height
	craft.authored = CraftAssets.is_authored(root)
	return craft
