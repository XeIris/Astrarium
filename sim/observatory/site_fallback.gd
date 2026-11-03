class_name SiteFallback
extends RefCounted

# Plain blocks standing in for assets/sites/observatories.glb on a fresh clone, to the
# authored models' datums and pivots (model_sources/blender/observatories.py).

## Height of each structure's top above its datum, m, with any dish at the horizon; the
## check holds both builds to it. Lovell: JBO's 89.0 m.
const HEIGHTS := {"lovell": 89.0, "mark2": 37.0, "keck": 30.5, "keck_hall": 6.0, "subaru": 34.0,
	"irtf": 16.1, "ut": 28.5, "at": 7.3, "vlt_platform": 4.5, "vst": 13.0, "vista": 19.0}

static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m

const WHITE := Color(0.86, 0.85, 0.82)
const GREY := Color(0.55, 0.57, 0.58)
const BLUE := Color(0.1, 0.17, 0.32)

static func _add(par: Node3D, mesh: PrimitiveMesh, y: float, c: Color, x := 0.0, z := 0.0) -> MeshInstance3D:
	mesh.material = _mat(c)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(x, y, z)
	par.add_child(mi)
	return mi

static func _cyl(par: Node3D, r: float, h: float, y: float, c: Color, x := 0.0, z := 0.0) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = r; m.bottom_radius = r; m.height = h
	return _add(par, m, y + h * 0.5, c, x, z)

static func _box(par: Node3D, s: Vector3, y: float, c: Color, x := 0.0, z := 0.0) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = s
	return _add(par, m, y + s.y * 0.5, c, x, z)

static func _sphere(par: Node3D, r: float, y: float, c: Color, x := 0.0, z := 0.0) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = r; m.height = 2.0 * r
	return _add(par, m, y, c, x, z)

static func _pivot(par: Node3D, name: String, y := 0.0) -> Node3D:
	var n := Node3D.new()
	n.name = name
	n.position.y = y
	par.add_child(n)
	return n

## A shallow bowl: boresight +y, its rim `rim` above the pivot.
static func _bowl(par: Node3D, r: float, f: float, rim: float, c: Color) -> void:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var n_r := 10
	var n_t := 48
	for i in n_r + 1:
		var rr := r * i / float(n_r)
		for k in n_t:
			var a := TAU * k / float(n_t)
			verts.append(Vector3(rr * cos(a), rim + (rr * rr - r * r) / (4.0 * f), rr * sin(a)))
	for i in n_r:
		for k in n_t:
			var k2 := (k + 1) % n_t
			idx.append_array([i * n_t + k, i * n_t + k2, (i + 1) * n_t + k, i * n_t + k2, (i + 1) * n_t + k2, (i + 1) * n_t + k])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var st := SurfaceTool.new()
	st.create_from_arrays(arrays)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := _mat(c)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	par.add_child(mi)

static func build(stage: String) -> Node3D:
	var root := Node3D.new()
	root.name = stage
	match stage:
		"lovell":
			_cyl(root, 53.75, 0.4, 0.0, GREY)
			var az := _pivot(root, "door_lovell_az")
			for s in [-1.0, 1.0]:
				_box(az, Vector3(8.0, 58.0, 12.0), 0.0, WHITE, s * 46.0)
			var el := _pivot(az, "door_lovell_el", 50.5)
			_bowl(el, 38.1, 22.9, 9.0, WHITE)
			_cyl(el, 37.6, 20.0, -11.5, GREY)
			_cyl(el, 0.6, 21.0, -6.85, WHITE)
			_box(el, Vector3(1.0, 27.0, 1.0), -38.5, GREY)
		"mark2":
			_cyl(root, 13.2, 5.0, 0.0, WHITE)
			var az := _pivot(root, "door_mark2_az", 5.0)
			var el := _pivot(az, "door_mark2_el", 18.0)
			_bowl(el, 19.05, 12.2, 1.0, WHITE)
			el.scale = Vector3(1.0, 1.0, 25.4 / 38.1)
			for s in [-1.0, 1.0]: _box(az, Vector3(3.0, 18.0, 6.0), 0.0, GREY, s * 14.0)
		"keck":
			_cyl(root, 16.7, 6.6, 0.0, WHITE)
			var dome := _pivot(root, "door_keck_dome")
			_sphere(dome, 15.5, 15.0, WHITE)
		"keck_hall":
			_box(root, Vector3(58.0, 6.0, 16.0), 0.0, WHITE)
		"subaru":
			_cyl(root, 20.0, 6.0, 0.0, WHITE)
			_box(root, Vector3(31.0, 28.0, 19.0), 6.0, GREY)
		"irtf":
			_box(root, Vector3(34.0, 5.0, 20.0), 0.0, WHITE)
			_sphere(root, 8.6, 7.5, GREY)
		"ut", "vst", "vista":
			var r: float = {"ut": 14.5, "vst": 7.0, "vista": 10.0}[stage]
			var h: float = {"ut": 28.5, "vst": 13.0, "vista": 19.0}[stage]
			_cyl(root, r, h * 0.33, 0.0, GREY)
			var dome := _pivot(root, "door_%s_dome" % stage, h * 0.33)
			_cyl(dome, r, h * 0.67, 0.0, Color(0.7, 0.72, 0.74))
		"at":
			_box(root, Vector3(3.6, 3.0, 3.6), 0.0, WHITE)
			_sphere(root, 2.35, 4.9, WHITE)
		"vlt_platform":
			_box(root, Vector3(46.0, 3.6, 13.0), 0.0, WHITE, -72.0, 30.0)
			_box(root, Vector3(74.0, 8.5, 16.0), -4.0, WHITE, -44.0, -112.0)
	return root
