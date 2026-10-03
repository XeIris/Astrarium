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

## MeshStandardMaterial → StandardMaterial3D with Lambert diffuse and Schlick-GGX
## specular. Every craft material is double-sided: bells, skirts and interstages are
## open shells, and culling saves nothing measurable at ~16 k triangles.
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

# GEOMETRY — three.js's primitives, reproduced exactly.
## Positions, normals and a three-convention (CCW) index list.
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
	# three's front faces are counter-clockwise, Godot's clockwise: swap each
	# triple once, here, so every builder can use three's order.
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

## A mesh node, three's `new THREE.Mesh(geometry, material)`.
static func _mesh(g: Geo, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.rotation_order = EULER_ORDER_XYZ
	mi.mesh = _to_mesh(g, material)
	return mi

## `new THREE.Group()`.
static func _grp() -> Node3D:
	var n := Node3D.new()
	n.rotation_order = EULER_ORDER_XYZ
	return n

## BufferGeometry.computeVertexNormals(): area-weighted face normals summed
## per index (so a lathe's duplicated seam stays a crease, as in three).
static func _compute_normals(g: Geo) -> void:
	var n := PackedVector3Array()
	n.resize(g.pos.size())
	for t in range(0, g.idx.size(), 3):
		var a := g.idx[t]; var b := g.idx[t + 1]; var c := g.idx[t + 2]
		var cb := (g.pos[c] - g.pos[b]).cross(g.pos[a] - g.pos[b])
		n[a] += cb; n[b] += cb; n[c] += cb
	g.nrm = n

## THREE.CylinderGeometry (ConeGeometry is this with radiusTop = 0).
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

## THREE.SphereGeometry.
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

## THREE.TorusGeometry — the ring lies in XY, so callers turn it with rotation.x.
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

## THREE.BoxGeometry(w, h, d) with one segment per side: 24 vertices, flat normals.
static func _box(w: float, h: float, d: float) -> Geo:
	var g := Geo.new()
	# buildPlane(u, v, w, udir, vdir, width, height, depth) in three's order:
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

## THREE.CircleGeometry, in XY facing +Z.
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

## THREE.PlaneGeometry(w, h), one segment, in XY facing +Z.
static func _plane(w: float, h: float) -> Geo:
	var g := Geo.new()
	for iy in 2:
		for ix in 2:
			g.pos.append(Vector3(ix * w - w / 2.0, -(iy * h - h / 2.0), 0)); g.nrm.append(Vector3(0, 0, 1))
	g.idx.append_array([0, 2, 1, 2, 3, 1])
	return g

## THREE.LatheGeometry, including its averaged meridian normals.
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

## THREE.CapsuleGeometry (r160): a lathe of absarc + line + absarc.
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

# ---- THREE.CatmullRomCurve3 (centripetal) and TubeGeometry ---------------
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

# ---- three's Object3D helpers --------------------------------------------
## Quaternion.setFromUnitVectors, three's algorithm (its antiparallel fallback
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
static func bent_tube(pts: Array, r: float, material: Material, radial := 20) -> Dictionary:
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
		for j in radial:
			var a := (float(j) / radial) * TAU
			var c := cos(a) * r; var sn := sin(a) * r
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
	return {"gimbals": [], "fins": [], "legs": [], "arrays": [], "flaps": [], "halves": [], "nozzles": []}

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

	if _t(look.get("srb")): return build_srb(spec, parts)
	if _t(look.get("orbiter")): return build_orbiter(spec, parts)
	if _t(look.get("aeroshell")): return build_aeroshell(spec, parts)
	if _t(look.get("skycrane")): return build_sky_crane(spec, parts)
	if _t(look.get("rover")): return build_rover(spec, parts)
	if _t(look.get("hailmary")): return build_hail_mary(spec, parts)
	if _t(look.get("beetle")): return build_beetle(spec, parts)
	if _t(look.get("bus")): return build_ion_bus(spec, parts)
	if _t(look.get("octagon")): return build_lm_descent(spec, parts)
	if _t(look.get("cabin")): return build_lm_ascent(spec, parts)
	if _t(look.get("capsule")): return build_csm(spec, parts)
	if _t(look.get("fairing")): return build_fairing(spec, parts)
	if _t(look.get("satellite")): return build_satellite(spec, parts)
	# Created only now: a Node3D is not refcounted, so one made before those returns leaks.
	var g := _grp()

	# ---- the default: a cylindrical stage with engines under it. `L` is the whole
	# length, so a nose eats into the barrel.
	var nose_l := D * 1.45 if _t(look.get("tank")) else (D * 1.55 if _t(look.get("nosecone")) else 0.0)
	var interstage := _n(look.get("interstage"), 0.0)
	# A stage carrying a nose or interstage gets a flat top, or the dome leaves a gap
	# at the joint. The aft end is near-flat too.
	var flat := nose_l > 0.0 or interstage != 0.0
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
	if _t(look.get("tank")):
		# Shuttle ET: its 46.9 m includes the ogive, so the barrel is shortened for it.
		var nose := ogive(nose_l, D, skin, 24)
		nose.position.y = L - nose_l; g.add_child(nose)
		# The intertank is the one stringered band on an otherwise smooth tank,
		# and it is the feature that stops 47 m of orange foam reading as a crayon.
		var it_y := L * 0.545; var it_h := L * 0.115
		for i in 40:
			var a := i / 40.0 * TAU
			var rib := _mesh(_box(0.16, it_h, 0.16), M.foam)
			rib.position = Vector3(cos(a) * D / 2.0 * 1.005, it_y + it_h / 2.0, sin(a) * D / 2.0 * 1.005)
			rib.rotation.y = -a; g.add_child(rib)
		for yy in [it_y, it_y + it_h]:
			var b := _mesh(_torus(D / 2.0 * 1.012, 0.10, 6, 40), M.foam)
			b.rotation.x = PI / 2.0; b.position.y = yy; g.add_child(b)
		# The LO2 feedline and the pressurisation lines run the length of the
		# tank on the orbiter's side — the only straight lines on the whole object.
		for ar in [[0.34, 0.24], [-0.34, 0.13]]:
			var pipe := _mesh(_cylinder(ar[1], ar[1], L * 0.80, 10), M.dirty)
			pipe.position = Vector3(sin(ar[0]) * D / 2.0 * 1.06, L * 0.40, cos(ar[0]) * D / 2.0 * 1.06)
			g.add_child(pipe)

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

## THE SOLIDS. y = 0 is the nozzle exit plane, level with the pad, so the 45.5 m is
## measured as published. Four casting segments with raised field joints and a
## full-length systems tunnel.
static func build_srb(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var D: float = spec.D; var L: float = spec.L; var r := D / 2.0
	for side in [-1.0, 1.0]:
		var b := _grp()
		b.position.x = side * 6.35
		# Aft skirt: the flared structure that actually carries the stack, with
		# the nozzle recessed inside it. It is wider than the motor case.
		var skirt := _mesh(_cylinder(r * 1.02, r * 1.30, L * 0.098, 24, 1, true), M.dirty)
		skirt.position.y = L * 0.049; b.add_child(skirt)
		# The nozzle hangs on a pivot because plumes parent to parts.gimbals. The RSRM
		# nozzle vectors 8°.
		var nzp := _grp()
		nzp.position.y = L * 0.085
		nzp.set_meta("gimbal_deg", float(spec.engine.gimbal))
		var exd := _n(spec.engine.get("exitD"), 0.0)
		nzp.add_child(bell(exd if exd != 0.0 else D * 0.95, 7.7, false))
		b.add_child(nzp); parts.gimbals.append(nzp)
		# Motor case: four segments, so four field joints.
		var case_y := L * 0.098; var case_l := L * 0.735
		var body := _mesh(_cylinder(r, r, case_l, 28, 1, true), M.white)
		body.position.y = case_y + case_l / 2.0; b.add_child(body)
		for i in range(1, 5):
			var j := _mesh(_torus(r * 1.018, D * 0.022, 6, 28), M.dirty)
			j.rotation.x = PI / 2.0; j.position.y = case_y + case_l * i / 5.0; b.add_child(j)
		# Systems tunnel — the cable raceway down the outboard face.
		var tun := _mesh(_box(D * 0.10, case_l * 0.98, D * 0.07), M.dirty)
		tun.position = Vector3(side * r * 0.99, case_y + case_l / 2.0, 0); b.add_child(tun)
		# Forward skirt, frustum (the parachutes) and nose cap.
		var fs_y := case_y + case_l; var fs_l := L * 0.070
		var fs := _mesh(_cylinder(r, r, fs_l, 24, 1, true), M.white)
		fs.position.y = fs_y + fs_l / 2.0; b.add_child(fs)
		var fr_l := L * 0.048
		var fr := _mesh(_cylinder(r * 0.72, r, fr_l, 24, 1, true), M.white)
		fr.position.y = fs_y + fs_l + fr_l / 2.0; b.add_child(fr)
		var cap_y := fs_y + fs_l + fr_l; var cap_l := L - cap_y
		var cap := ogive(cap_l, r * 1.44, M.white, 24); cap.position.y = cap_y; b.add_child(cap)
		# The forward attach fitting and the aft struts: the booster does not
		# touch the tank, it is held off it, and the gap is a structural fact.
		for yl in [[fs_y + fs_l * 0.4, 0.9], [case_y + case_l * 0.06, 1.1], [case_y + case_l * 0.13, 1.1]]:
			var st := _mesh(_cylinder(0.16, 0.16, yl[1], 8), M.dirty)
			st.position = Vector3(-side * (r + yl[1] / 2.0), yl[0], 0); st.rotation.z = PI / 2.0
			b.add_child(st)
		g.add_child(b)
	return {"group": g, "parts": parts}

## THE ORBITER, nose-up along +Y, wings on ±X, belly on −Z (toward the tank). Lofted
## fuselage and a kinked wing. Black tiles and RCC where the plasma goes, white
## blanket where only space does.
static func build_orbiter(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var L: float = spec.L                                  # 37.2 m
	var f := func(u: float) -> float: return u * L
	# ---- fuselage: stations from the base up, half-width / half-height in m. `n`
	# goes from near-circular at the nose to the payload bay's rounded square.
	var sec := [
		{"y": f.call(0.000), "w": 2.35, "h": 2.60, "cz": 0.10, "n": 3.0},
		{"y": f.call(0.030), "w": 2.62, "h": 2.86, "cz": 0.06, "n": 3.4},
		{"y": f.call(0.090), "w": 2.78, "h": 2.92, "cz": 0.02, "n": 3.6},
		{"y": f.call(0.200), "w": 2.80, "h": 2.86, "cz": 0.00, "n": 3.6},
		{"y": f.call(0.400), "w": 2.80, "h": 2.80, "cz": 0.00, "n": 3.6},
		{"y": f.call(0.640), "w": 2.80, "h": 2.74, "cz": 0.00, "n": 3.5},
		{"y": f.call(0.720), "w": 2.72, "h": 2.58, "cz": 0.02, "n": 3.2},
		{"y": f.call(0.800), "w": 2.44, "h": 2.26, "cz": 0.06, "n": 2.9},
		{"y": f.call(0.865), "w": 2.02, "h": 1.84, "cz": 0.10, "n": 2.7},
		{"y": f.call(0.925), "w": 1.42, "h": 1.30, "cz": 0.12, "n": 2.5},
		{"y": f.call(0.968), "w": 0.78, "h": 0.72, "cz": 0.12, "n": 2.3},
		{"y": f.call(1.000), "w": 0.10, "h": 0.10, "cz": 0.10, "n": 2.2},
	]
	# Two shells, split at the waterline: white blanket over, black tile under.
	g.add_child(loft(sec, M.white, 30, 0.0, PI))
	g.add_child(loft(sec, M.tiles, 30, PI, TAU))

	# ---- wing: a double delta, kinked at x = 5.4 m (79° glove, 45° outer panel).
	var ws := [
		{"x": 2.52, "yLE": f.call(0.700), "chord": f.call(0.673), "thick": 0.055, "cz": -1.30},
		{"x": 3.80, "yLE": f.call(0.560), "chord": f.call(0.533), "thick": 0.060, "cz": -1.20},
		{"x": 5.40, "yLE": f.call(0.360), "chord": f.call(0.333), "thick": 0.070, "cz": -1.10},
		{"x": 8.60, "yLE": f.call(0.245), "chord": f.call(0.218), "thick": 0.085, "cz": -0.85},
		{"x": 11.30, "yLE": f.call(0.147), "chord": f.call(0.112), "thick": 0.100, "cz": -0.62},
		{"x": 11.90, "yLE": f.call(0.138), "chord": f.call(0.062), "thick": 0.110, "cz": -0.58},
	]
	for sgn in [1.0, -1.0]:
		g.add_child(wing_panel(ws, M.white, M.tiles, 14, sgn))

	# ---- vertical tail. Built in the wing's own frame (span on X) and rotated
	# upright, so one function serves both surfaces.
	var ts := [
		{"x": 0.0, "yLE": f.call(0.185), "chord": 6.10, "thick": 0.13},
		{"x": 3.4, "yLE": f.call(0.140), "chord": 4.85, "thick": 0.13},
		{"x": 6.6, "yLE": f.call(0.100), "chord": 3.55, "thick": 0.14},
		{"x": 7.9, "yLE": f.call(0.083), "chord": 2.75, "thick": 0.15},
	]
	var tail := wing_panel(ts, M.white, M.white)
	tail.rotation.y = -PI / 2.0                        # span X → +Z, i.e. up
	tail.position.z = 2.55
	g.add_child(tail)

	# ---- OMS pods: the two bulges either side of the fin root. They are the
	# orbiter's own engines, and the only ones it keeps after the tank is gone.
	for sgn in [-1.0, 1.0]:
		var pod := loft([
			{"y": f.call(0.020), "w": 0.55, "h": 0.55, "n": 2.4},
			{"y": f.call(0.060), "w": 1.05, "h": 1.00, "n": 2.6},
			{"y": f.call(0.120), "w": 1.25, "h": 1.15, "n": 2.6},
			{"y": f.call(0.175), "w": 1.05, "h": 0.95, "n": 2.5},
			{"y": f.call(0.215), "w": 0.45, "h": 0.42, "n": 2.4},
		], M.white, 18)
		pod.position = Vector3(sgn * 2.05, 0, 1.95)
		g.add_child(pod)
		# The OMS bell itself, canted out and down the way the real one is.
		var b := bell(1.35, 55)
		b.position = Vector3(sgn * 2.15, f.call(0.035), 1.55)
		b.rotation = Vector3(-0.30, b.rotation.y, sgn * 0.18)
		g.add_child(b)
		# Forward RCS in the nose, aft RCS in the pods.
		for k in 3:
			var n2 := _mesh(_cylinder(0.11, 0.13, 0.22, 8), M.black)
			n2.position = Vector3(sgn * (2.7 + k * 0.1), f.call(0.19 + k * 0.006), 2.3 - k * 0.5)
			n2.rotation.z = sgn * PI / 2.0; g.add_child(n2)

	# ---- three SSMEs, in the triangle they actually sit in: one high on the
	# centreline, two low and outboard. They gimbal, so each gets a pivot.
	var ec := _grp()
	var piv := []
	for xz in [[0.0, 1.30], [-1.55, -0.55], [1.55, -0.55]]:
		var p := _grp()
		p.position = Vector3(xz[0], f.call(0.045), xz[1])
		p.add_child(bell(2.30, 69))
		ec.add_child(p); piv.append(p)
	g.add_child(ec); parts.gimbals = piv
	# The boat-tail shroud the engines hang out of.
	var aft := loft([{"y": f.call(0.000), "w": 2.30, "h": 2.45, "cz": 0.10, "n": 3.0},
		{"y": f.call(0.055), "w": 2.70, "h": 2.90, "cz": 0.05, "n": 3.4}], M.black, 24)
	g.add_child(aft)

	# ---- body flap: the slab under the engines that trims the vehicle in
	# hypersonic flight and shields the bells. Small, and very recognisable.
	var flap := _mesh(_box(4.3, 2.3, 0.36), M.tiles)
	flap.position = Vector3(0, f.call(0.028), -2.35); flap.rotation.x = 0.12
	g.add_child(flap); parts.flaps.append(flap)

	# ---- payload bay doors, closed: two long panels along the top with the
	# radiator lines that live on their inner face showing as seams.
	for sgn in [-1.0, 1.0]:
		var door := loft([
			{"y": f.call(0.215), "w": 2.62, "h": 2.62, "n": 3.4},
			{"y": f.call(0.640), "w": 2.62, "h": 2.60, "n": 3.4},
		], M.dirty, 14, 0.10 if sgn > 0 else PI - 0.10, PI / 2.0 - 0.03 if sgn > 0 else PI / 2.0 + 0.03)
		g.add_child(door)

	# ---- flight deck windows, placed by solving the superellipse section for z at
	# the window's x and standing the glass a few cm proud.
	var win_sec := {"w": 1.72, "h": 1.56, "cz": 0.11, "n": 2.7}
	var surf_z := func(x: float) -> float:
		return win_sec.cz + win_sec.h * pow(maxf(1.0 - pow(absf(x) / win_sec.w, win_sec.n), 0.0), 1.0 / win_sec.n)
	for i in 6:
		var a := (i - 2.5) / 2.5                       # −1 … +1 across the front
		var x := a * 1.30
		var win := _mesh(_box(0.52, 0.46, 0.10), M.glass)
		win.position = Vector3(x, f.call(0.897), surf_z.call(x) + 0.02)
		win.rotation = Vector3(-0.62, -a * 0.42, 0)
		g.add_child(win)
	# The two overhead windows, flat on the crown behind the forward six.
	for dx in [-0.42, 0.42]:
		var ov := _mesh(_box(0.44, 0.44, 0.10), M.glass)
		ov.position = Vector3(dx, f.call(0.856), surf_z.call(dx) + 0.10)
		ov.rotation.x = -0.05; g.add_child(ov)
	# Side hatch, on the port side of the crew cabin.
	var hatch := _mesh(_cylinder(0.50, 0.50, 0.08, 18), M.dirty)
	hatch.position = Vector3(-1.86, f.call(0.845), 0.55)
	hatch.rotation = Vector3(0, 0, PI / 2.0); g.add_child(hatch)
	# Black nose cap: the hottest single point on the vehicle, ~1 600 °C.
	var cap := loft([
		{"y": f.call(0.962), "w": 0.90, "h": 0.84, "cz": 0.10, "n": 2.3},
		{"y": f.call(0.985), "w": 0.56, "h": 0.52, "cz": 0.10, "n": 2.2},
		{"y": f.call(1.000), "w": 0.10, "h": 0.10, "cz": 0.10, "n": 2.2},
	], M.tiles, 20)
	g.add_child(cap)
	return {"group": g, "parts": parts}

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
	# ---- service module: a plain cylinder, and almost all of it is propellant.
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
	# ---- command module: the 33° cone, apex up, on its heat shield.
	var cm_y := sm_l; var cm_h := 3.20; var cm_r := 1.955
	var cm := _mesh(_cylinder(cm_r * 0.28, cm_r, cm_h, 24, 1, true), M.alu)
	cm.position.y = cm_y + cm_h / 2.0; g.add_child(cm)
	var shield := _mesh(_sphere(cm_r * 1.9, 24, 8, 0.0, TAU, PI * 0.72, PI * 0.28), M.ablator)
	shield.position.y = cm_y + cm_r * 1.62; g.add_child(shield)
	var tunnel := _mesh(_cylinder(cm_r * 0.26, cm_r * 0.28, 0.42, 16), M.alu)
	tunnel.position.y = cm_y + cm_h + 0.18; g.add_child(tunnel)
	# ---- launch escape system: tower, motor, and the canted nozzles that pull
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
	# ---- rocker-bogie. The rocker runs the length of each side; the bogie is
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

## The Hail Mary: three astrophage tanks around a central spine, a pressure vessel
## forward, and four spin drives (one under each tank, one on the axis). All four
## fire parallel to the axis through one plane, since a canted drive wastes
## 1 − cos θ and adds a torque held for thirteen years. The tanks bend in around the
## spine; the drives hang square beneath the bend. Fallback for the authored .glb.
static func build_hail_mary(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := _grp()
	var L: float = spec.L; var D: float = spec.D       # 47 m × 12 m
	var f := func(u: float) -> float: return u * L
	var look: Dictionary = spec.get("look", {})
	var nT := int(_n(look.get("tanks"), 3.0)) if _t(look.get("tanks")) else 3
	var tr := D * 0.265; var tank_r := D * 0.110
	var Y := Vector3(0, 1, 0); var Z := Vector3(0, 0, 1)
	# The aft plane. Every drive's exit sits on it.
	var aft_y: float = f.call(0.132)
	var dR := tank_r * 0.62                # 0.82 m — the drive is SMALLER than its tank

	# ---- the central drive, on the axis, where the spine's load path ends.
	var axial := spin_drive(dR)
	axial.mount.position = Vector3(0, aft_y, 0)
	g.add_child(axial.mount); parts.gimbals.append(axial.pivot)
	var plate_y: float = aft_y + axial.topY + f.call(0.006)

	# ---- the central body: a fat cone the tanks lie against. Its radius equals the
	# tank centreline's radius minus the tank radius, and it ends on a thrust plate at
	# plate_y for the axial drive and aft truss.
	var cone_y1: float = f.call(0.468)
	var cone_prof := PackedVector2Array([
		Vector2(0, plate_y), Vector2(dR * 1.55, plate_y),
		Vector2(dR * 1.75, plate_y + f.call(0.014)), Vector2(D * 0.132, f.call(0.212)),
		Vector2(D * 0.146, f.call(0.238)), Vector2(D * 0.155, f.call(0.266)), Vector2(D * 0.155, f.call(0.468)),
		Vector2(D * 0.075, f.call(0.468))])
	g.add_child(_mesh(_lathe(cone_prof, 30), M.dirty))
	# The plate's rim and the neck down to the drive.
	var rim := _mesh(_cylinder(dR * 1.55, dR * 1.42, f.call(0.016), 24, 1, true), M.alu)
	rim.position.y = plate_y - f.call(0.008); g.add_child(rim)
	var neck := _mesh(_cylinder(axial.neckR * 1.14, axial.neckR * 1.14,
		plate_y - (aft_y + axial.topY) + 0.1, 18, 1, true), M.dirty)
	neck.position.y = (plate_y + aft_y + axial.topY) / 2.0; g.add_child(neck)
	for ru in [[D * 0.142, 0.222], [D * 0.152, 0.252], [D * 0.158, 0.330], [D * 0.158, 0.420]]:
		var b := _mesh(_torus(ru[0], D * 0.006, 4, 28), M.alu)
		b.rotation.x = PI / 2.0; b.position.y = f.call(ru[1]); g.add_child(b)
	# MLI on the spine between the tanks, and the cross-feed plumbing.
	var mli_band := _mesh(_cylinder(D * 0.157, D * 0.157, f.call(0.030), 28, 1, true), M.gold)
	mli_band.position.y = f.call(0.300); g.add_child(mli_band)
	for i in 8:
		var a := i / 8.0 * TAU + 0.5
		# Staggered in length and height, as a real trunk run is.
		var h: float = f.call(0.150 + 0.055 * ((i * 5) % 7) / 7.0)
		var run := _mesh(_cylinder(D * 0.008, D * 0.008, h, 6, 1, true), M.alu if i % 3 else M.soot)
		run.position = Vector3(cos(a) * D * 0.163, f.call(0.352) + h * 0.5 - f.call(0.075), sin(a) * D * 0.163)
		g.add_child(run)
	for i in 3:                                        # valve packages
		var a := i / 3.0 * TAU + 0.9
		var box := _mesh(_box(D * 0.055, D * 0.075, D * 0.045), M.alu)
		box.position = Vector3(cos(a) * D * 0.172, f.call(0.288), sin(a) * D * 0.172)
		box.rotation.y = -a; g.add_child(box)

	# ---- three tanks: straight, then bent in around the cone. The turn is limited at
	# the drive faces: three faces of radius r clear on a ring of R only while R·√3 > 2r.
	var path := bent_path(tr, f.call(0.679), f.call(0.245), D * 0.55, 16, D * 0.14)
	var end_p: Vector3 = path[path.size() - 1]
	for i in nT:
		var a := float(i) / nT * TAU + PI / 2.0
		var t := _grp()
		t.rotation.y = -a                              # the path is radial/axial
		var bt := bent_tube(path, tank_r, M.white, 24)
		var tan: Array = bt.tan; var nrm: Array = bt.nrm
		t.add_child(bt.mesh)
		# The tube's transported frame, reused for hardware that follows the bend: `nrm`
		# is out of plane, `bi` in plane; φ = 0 is the ±z flank, φ = π/2 inboard.
		var bi := func(k: int) -> Vector3: return (tan[k] as Vector3).cross(nrm[k]).normalized()
		var surf := func(k: int, phi: float, rr: float) -> Vector3:
			return path[k] + (nrm[k] as Vector3) * (cos(phi) * rr) + (bi.call(k) as Vector3) * (sin(phi) * rr)

		# Ring frames and weld seams, spaced by arc length (the path's points are 3.4 m
		# apart on the barrel and 0.18 m round the bend).
		var arc := [0.0]
		for k in range(1, path.size()):
			arc.append(arc[k - 1] + (path[k] as Vector3).distance_to(path[k - 1]))
		var at := func(sT: float) -> Array:            # position + tangent at an arc length
			var k := 1
			while k < arc.size() - 1 and arc[k] < sT: k += 1
			var u: float = (sT - arc[k - 1]) / maxf(arc[k] - arc[k - 1], 1e-6)
			return [(path[k - 1] as Vector3).lerp(path[k], u), (tan[k - 1] as Vector3).lerp(tan[k], u).normalized()]
		var BAY := 2.6                                 # barrel section length, m
		var n := 1
		while n * BAY * 0.5 < arc[arc.size() - 1] - 0.35:
			var pq: Array = at.call(n * BAY * 0.5)
			if n % 2:                                  # frame
				var ring := _mesh(_torus(tank_r * 1.016, tank_r * 0.038, 4, 24), M.alu)
				ring.position = pq[0]
				ring.quaternion = quat_from_unit_vectors(Z, pq[1])
				t.add_child(ring)
			else:                                      # weld seam
				# A seam stands proud and uses the tube's segment count, or the polygons cross and
				# z-fight into dashes.
				var seam := _mesh(_cylinder(tank_r * 1.012, tank_r * 1.012, tank_r * 0.05, 24, 1, true), M.soot)
				seam.position = pq[0]
				seam.quaternion = quat_from_unit_vectors(Y, pq[1])
				t.add_child(seam)
			n += 1
		# Cable trays, an inboard propellant trunk and an outboard conduit, carried round
		# the bend on the tank frame.
		for rail_def in [
				[0.62, tank_r * 1.05, 0.085, M.alu],
				[-0.62, tank_r * 1.05, 0.085, M.alu],
				[PI * 0.5, tank_r * 1.09, 0.135, M.dirty],      # inboard: the feed trunk
				[PI * 1.5, tank_r * 1.06, 0.090, M.soot],       # outboard: conduit
				[PI * 1.5 - 0.30, tank_r * 1.04, 0.055, M.alu]]:
			var rpts := []
			for k in path.size():
				rpts.append(surf.call(k, rail_def[0], rail_def[1]))
			t.add_child(_mesh(_tube(CatmullRom.new(rpts), 24, rail_def[2], 4), rail_def[3]))
		# Standoff brackets, so the runs are held off the skin rather than sunk in it.
		var kk := 2
		while kk < path.size() - 1:
			for phi in [PI * 0.5, PI * 1.5]:
				t.add_child(beam(surf.call(kk, phi, tank_r * 0.99), surf.call(kk, phi, tank_r * 1.10), 0.05))
			kk += 3
		# Forward dome, collar and cap.
		var dome := _mesh(_sphere(tank_r, 24, 10, 0.0, TAU, 0.0, PI / 2.0), M.white)
		dome.position = path[0]; t.add_child(dome)
		var collar := _mesh(_torus(tank_r * 1.02, tank_r * 0.05, 4, 24), M.alu)
		collar.rotation.x = PI / 2.0; collar.position = path[0]; t.add_child(collar)
		var vent := _mesh(_cylinder(tank_r * 0.18, tank_r * 0.22, tank_r * 0.30, 12), M.dirty)
		vent.position = Vector3(tr + tank_r * 0.40, (path[0] as Vector3).y + tank_r * 0.95, 0); t.add_child(vent)
		# MLI: one band on the straight run above the bend, one under the dome.
		for yh in [[f.call(0.285), f.call(0.030)], [f.call(0.640), f.call(0.022)]]:
			var gb := _mesh(_cylinder(tank_r * 1.02, tank_r * 1.02, yh[1], 24, 1, true), M.gold)
			gb.position = Vector3(tr, yh[0], 0); t.add_child(gb)
		# Equipment boxes on the outboard flanks, clear of the conduit.
		for eq in [[f.call(0.330), 1.5, 1.1, PI * 1.5 + 0.62],
				[f.call(0.455), 0.9, 0.8, PI * 1.5 - 0.62],
				[f.call(0.545), 1.2, 0.6, PI * 1.5 + 0.62],
				[f.call(0.612), 0.7, 0.9, PI * 1.5 - 0.62]]:
			var phi: float = eq[3]
			var box := _mesh(_box(0.34, eq[2], eq[1]), M.dirty)
			box.position = Vector3(tr - sin(phi) * tank_r * 1.08, eq[0], cos(phi) * tank_r * 1.08)
			box.rotation.y = atan2(cos(phi), -sin(phi))
			t.add_child(box)

		# ---- the aft end: a bulkhead, a thrust block, and the drive square under it.
		var end_t: Vector3 = tan[tan.size() - 1]
		var cap_plate := _mesh(_circle(tank_r, 24), M.dirty)
		cap_plate.position = end_p
		cap_plate.quaternion = quat_from_unit_vectors(Z, end_t); t.add_child(cap_plate)
		var cap_ring := _mesh(_torus(tank_r * 1.01, tank_r * 0.055, 4, 24), M.alu)
		cap_ring.position = end_p
		cap_ring.quaternion = quat_from_unit_vectors(Z, end_t); t.add_child(cap_ring)
		# The thrust block: takes the oblique tank end to a square drive and carries 31 MN.
		var drv := spin_drive(dR)
		drv.mount.position = Vector3(end_p.x, aft_y, 0)
		t.add_child(drv.mount); parts.gimbals.append(drv.pivot)
		# Buried in the tank's aft end at the top and square to the ship at the bottom, so
		# the 16° is taken up in one short piece.
		var block_top := end_p.y + tank_r * 0.62; var block_bot: float = aft_y + drv.topY
		var block := _mesh(_cylinder(dR * 0.92, dR * 0.80, block_top - block_bot, 18, 1, true), M.dirty)
		block.position = Vector3(end_p.x, (block_top + block_bot) / 2.0, 0); t.add_child(block)
		# Gussets to the bulkhead ring (all different lengths: oblique cap, square block).
		var n_end: Vector3 = nrm[nrm.size() - 1]
		var b_end := end_t.cross(n_end).normalized()
		for k in 6:
			var phi := k / 6.0 * TAU
			var p2 := end_p + n_end * (cos(phi) * tank_r * 0.90) + b_end * (sin(phi) * tank_r * 0.90)
			var p1 := Vector3(end_p.x - sin(phi) * dR * 0.88, block_bot + 0.22, cos(phi) * dR * 0.88)
			t.add_child(beam(p1, p2, 0.06))
		# The feed line from the inboard trunk into the emitter can, routed outboard of the
		# spine's thrust plate.
		var feed := CatmullRom.new([
			surf.call(path.size() - 6, PI * 0.5, tank_r * 1.09),
			surf.call(path.size() - 2, PI * 0.5, tank_r * 1.15),
			Vector3(end_p.x - dR * 1.05, block_bot + 0.75, 0),
			Vector3(end_p.x - dR * 0.90, block_bot + 0.30, 0)])
		t.add_child(_mesh(_tube(feed, 16, 0.12, 5), M.alu))
		g.add_child(t)

	# ---- structure: radial struts to the spine at two stations, girth ties between
	# tanks, and an aft truss tying the four drive blocks together.
	for yy in [f.call(0.290), f.call(0.584)]:
		for i in nT:
			var a := float(i) / nT * TAU + PI / 2.0
			var inner := D * 0.075
			g.add_child(beam(Vector3(cos(a) * inner, yy, sin(a) * inner),
				Vector3(cos(a) * (tr - tank_r * 0.9), yy, sin(a) * (tr - tank_r * 0.9)), 0.09))
	var ring_pt := func(i: float, r: float, y: float) -> Vector3:
		var a := i / nT * TAU + PI / 2.0
		return Vector3(cos(a) * r, y, sin(a) * r)
	for yr in [[f.call(0.330), tr], [f.call(0.620), tr]]:
		for i in nT:
			g.add_child(beam(ring_pt.call(float(i), yr[1] - tank_r * 0.2, yr[0]),
				ring_pt.call(float(i + 1), yr[1] - tank_r * 0.2, yr[0]), 0.075))
	# The aft truss: two struts from the thrust plate to each drive block, and a
	# girth ring between blocks.
	for i in nT:
		var p: Vector3 = ring_pt.call(float(i), end_p.x, aft_y + dR * 2.0)
		for s in [-1.0, 1.0]:
			var q: Vector3 = ring_pt.call(i + s * 0.22, dR * 1.5, plate_y - f.call(0.010))
			g.add_child(beam(p, q, 0.075))
		g.add_child(beam(p, ring_pt.call(float(i + 1), end_p.x, aft_y + dR * 2.0), 0.065))

	# ---- the module stack, standing on the cone and running past the tanks.
	var mod := func(y0: float, y1: float, dia: float, m: Material) -> void:
		var c := _mesh(_cylinder(dia / 2.0, dia / 2.0, y1 - y0, 22, 1, true), m)
		c.position.y = (y0 + y1) / 2.0; g.add_child(c)
	var band := func(y: float, dia: float, h: float, m: StandardMaterial3D) -> void:
		var c := _mesh(_cylinder(dia / 2.0 * 1.02, dia / 2.0 * 1.02, h, 22, 1, true), decal_mat(m))
		c.position.y = y; g.add_child(c)
	band.call(cone_y1, D * 0.150, f.call(0.022), M.gold)
	mod.call(f.call(0.468), f.call(0.560), D * 0.150, M.dirty)     # machinery / stores
	band.call(f.call(0.560), D * 0.180, f.call(0.022), M.gold)

	var hull_y0: float = f.call(0.566); var hull_y1: float = f.call(0.855); var hull_d := D * 0.205
	mod.call(hull_y0, hull_y1, hull_d, M.white)
	for k in 3:                                        # control / lab / dorm
		band.call(hull_y0 + (hull_y1 - hull_y0) * (0.17 + k * 0.30), hull_d, f.call(0.006), M.black)
	for side in [1.0, -1.0]:
		var w := _mesh(_cylinder(0.30, 0.30, 0.10, 14), M.glass)
		w.position = Vector3(side * hull_d * 0.5, hull_y0 + (hull_y1 - hull_y0) * 0.78, 0)
		w.rotation.z = PI / 2.0; g.add_child(w)
	var lock := _mesh(_cylinder(0.55, 0.55, 0.22, 16), M.alu)
	lock.position = Vector3(0, hull_y0 + (hull_y1 - hull_y0) * 0.40, hull_d * 0.5)
	lock.rotation.x = PI / 2.0; g.add_child(lock)
	band.call(hull_y1, D * 0.170, f.call(0.022), M.gold)

	mod.call(f.call(0.861), f.call(1.013), D * 0.140, M.dirty)     # instruments
	# The nose is one object: the node overlaps the module it sits on, and the mast
	# starts inside the node.
	var node_r := D * 0.088; var node_y: float = f.call(1.028)
	var node := _mesh(_sphere(node_r, 20, 14), M.alu)
	node.position.y = node_y; g.add_child(node)
	var collar2 := _mesh(_cylinder(D * 0.082, D * 0.072, f.call(0.020), 24), M.dirty)
	collar2.position.y = f.call(1.008); g.add_child(collar2)
	for i in 4:
		var a := i / 4.0 * TAU
		var port := _mesh(_cylinder(D * 0.030, D * 0.034, D * 0.055, 14), M.dirty)
		port.position = Vector3(cos(a) * D * 0.095, node_y, sin(a) * D * 0.095)
		port.rotation = Vector3(0, -a, PI / 2.0); g.add_child(port)
	var mast_y0 := node_y + node_r * 0.55; var mast_l: float = f.call(1.148) - mast_y0
	var mast := _mesh(_cylinder(0.07, 0.07, mast_l, 8), M.alu)
	mast.position.y = mast_y0 + mast_l / 2.0; g.add_child(mast)
	# The high-gain antenna on a boom, opening forward.
	var hg_y: float = f.call(1.000); var hg_x := D * 0.172
	g.add_child(beam(Vector3(D * 0.070, hg_y, 0), Vector3(hg_x, hg_y, 0), 0.075, M.alu, 6))
	var hg_dish := dish(D * 0.105)
	hg_dish.position = Vector3(hg_x, hg_y + D * 0.030, 0); hg_dish.rotation.z = -0.56; g.add_child(hg_dish)

	# ---- radiators: fixed structure, not parts.arrays (which flies stowed). On the
	# hull above the tank tops, the one band of spine with a clear horizon.
	var n_rad := int(_n(look.get("radiators"), 0.0))
	for i in n_rad:
		var arm := _grp()
		arm.rotation.y = -(float(i) / n_rad * TAU + PI / 4.0)
		arm.position.y = f.call(0.775)
		# Azimuth on the parent and tilt on a child, so the two angles don't compose.
		var rad := radiator(D * 0.22, f.call(0.085))
		rad.rotation.x = PI / 2.0
		rad.position.x = hull_d * 0.5 + D * 0.175
		arm.add_child(rad)
		arm.add_child(beam(Vector3(hull_d * 0.46, 0, 0), Vector3(hull_d * 0.5 + D * 0.09, 0, 0), 0.07))
		g.add_child(arm)

	# ---- solar wings: two long flat panels, the widest thing on the ship.
	for side in [1.0, -1.0]:
		var wing := _grp()
		var nP := 7; var pw := D * 0.235; var ph := D * 0.40
		for k in nP:
			# Turned through 90°: the panel's plane contains the ship's axis, so
			# it stands off the hull like a wing instead of lying flat like a table.
			var pnl := _mesh(_box(pw, ph, 0.05), M.solar)
			pnl.position = Vector3(D * 0.46 + pw * (k + 0.5) * 1.02, 0, 0); wing.add_child(pnl)
			var rib := _mesh(_box(0.06, ph, 0.10), M.alu)
			rib.position = Vector3(D * 0.46 + pw * k * 1.02, 0, 0); wing.add_child(rib)
		var spar := _mesh(_cylinder(0.10, 0.10, D * 1.20, 6), M.alu)
		spar.position = Vector3(D * 0.46 + D * 0.60, 0, 0); spar.rotation.z = PI / 2.0
		wing.add_child(spar)
		wing.position = Vector3(0, f.call(0.360), 0)
		wing.rotation.y = 0.0 if side > 0 else PI
		# Fixed structure, NOT a deployable — see the note on `parts.arrays`.
		g.add_child(wing)

	# ---- beetles on the spine below the pressure vessel. Next to the ship they
	# are deliberately tiny, and they are the only way an answer gets home.
	var nB := int(_n(look.get("beetles"), 0.0))
	for i in nB:
		var a := float(i) / nB * TAU + PI / 4.0
		var b := _grp()
		b.position = Vector3(cos(a) * D * 0.105, f.call(0.520), sin(a) * D * 0.105)
		b.rotation.y = -a
		b.add_child(_mesh(_capsule(D * 0.028, D * 0.070, 5, 12), M.dirty))
		var nz := _mesh(_cylinder(D * 0.018, D * 0.026, D * 0.028, 12), M.emitPlate)
		nz.position.y = -D * 0.068; b.add_child(nz)
		g.add_child(b)
	g.add_child(rcs_ring(hull_d, hull_y0 + (hull_y1 - hull_y0) * 0.55, 4))
	# Shift the ship so the drives' exit plane is the origin. On an inner group:
	# build_craft overwrites `g.position`.
	var body := _grp()
	for c in g.get_children():
		g.remove_child(c); body.add_child(c)
	body.position.y = -aft_y
	g.add_child(body)
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

# MEASUREMENT — three's Box3.setFromObject, which several callers depend on.
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

# THE VEHICLE
## One stage of a built craft: {key, spec, group, parts, base_y, deploy, sep}.
class CraftStage extends RefCounted:
	var key: String
	var spec: Dictionary
	var group: Node3D
	## {gimbals, fins, legs, arrays, flaps, halves, nozzles}: Arrays of Node3D.
	var parts: Dictionary
	var base_y := 0.0
	var deploy := 0.0
	## null, or {t, v, spin} while a separated stage drifts off.
	var sep = null

## A built vehicle: `group` (root), `stages` (CraftStage, bottom to top),
## `height` (measured, m), `authored` (any stage used the .glb), update(), separate().
class Craft extends RefCounted:
	var group: Node3D
	var stages: Array = []
	var height := 0.0
	var authored := false

	## Drive every moving part from the flight state; nothing is on a timer. `s` is
	## {dt, attached: {key: bool}, deploy: {key: 0..1}, gimbal: {x, z}, flap, gearStage}.
	func update(s: Dictionary) -> void:
		var dt := float(s.get("dt", 0.0))
		var attached: Dictionary = s.get("attached", {}) if s.get("attached") != null else {}
		var deploy: Dictionary = s.get("deploy", {}) if s.get("deploy") != null else {}
		var gim: Dictionary = s.get("gimbal", {}) if s.get("gimbal") != null else {}
		for st: CraftStage in stages:
			var a = attached.get(st.key)
			var live: bool = not (a is bool and a == false)
			st.group.visible = live or st.sep != null
			if st.sep != null:
				# A separated stage drifts and tumbles away for a moment.
				st.sep.t += dt
				st.group.position.y = st.base_y - st.sep.t * st.sep.v
				st.group.rotation.x = st.sep.t * st.sep.spin
				st.group.rotation.z = st.sep.t * st.sep.spin * 0.6
				if st.sep.t > 6.0:
					st.group.visible = false; st.sep = null
				continue
			# deployables, eased so they take a real second or two
			var want := 0.0
			var gs = s.get("gearStage")
			if (gs != null and str(gs) == st.key) or live:
				want = float(U.nz(deploy.get(st.key), 0.0))
			st.deploy += clampf(want - st.deploy, -dt * 0.55, dt * 0.55)
			var d := st.deploy
			for leg: Node3D in st.parts.legs: leg.rotation.z = -d * 1.15
			for fin: Node3D in st.parts.fins: fin.rotation.z = -d * 1.35
			for arr: Node3D in st.parts.arrays: arr.rotation.z = (1.0 - d) * (PI / 2.0)
			for h: Node3D in st.parts.halves:
				h.rotation.z = 0.0; h.position.x = 0.0
			# gimbal: the commanded deflection, clamped per pivot to its `gimbal_deg`; a pivot
			# without one is left unclamped.
			var gx := float(U.nz(gim.get("x"), 0.0)); var gz := float(U.nz(gim.get("z"), 0.0))
			for p: Node3D in st.parts.gimbals:
				var lim := float(p.get_meta("gimbal_deg", 90.0)) * PI / 180.0
				p.rotation.x = clampf(gz, -lim, lim)
				p.rotation.z = clampf(-gx, -lim, lim)
			var flap := float(U.nz(s.get("flap"), 0.0))
			for f: Node3D in st.parts.flaps: f.rotation.z = flap * 0.6

	## Detach a stage: it stops following the stack and drifts off.
	func separate(key: String, dv := 3.0, spin := 0.25) -> void:
		for st: CraftStage in stages:
			if st.key == key:
				if st.sep == null: st.sep = {"t": 0.0, "v": dv, "spin": spin}
				return

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
