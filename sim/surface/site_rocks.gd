class_name SiteRocks
extends RefCounted

# The rocks about a site on a lifeless dry world, drawn only: Golombek & Rapp's (1997) model of the rocks at the
# Viking sites and their terrestrial analogues, the cumulative fractional area covered by rocks of diameter D or
# more F(D) = k e^(−q D) with q = 1.79 + 0.152/k, k the area all of them cover. Scattered on the drawn ground's
# triangles about the site's middle, part-buried, one lumpy mesh in many rotations and proportions.
# Contact is the grid's: a gear or a wheel does not meet them. docs/physics/surface.md#the-ground-close-up.

## k by world. Mars: the modal 8% of Golombek & Rapp (Viking 1 without its outcrops). The Moon and Titan are
## estimates: a mare's coarse fragments cover a few per cent (Shoemaker & Morris 1970 found the Surveyor sites
## alike), and Huygens landed among rounded cobbles of up to about 15 cm. Other dry worlds: 5%.
const K := {"Mars": 0.08, "Moon": 0.03, "Titan": 0.05}
const K_DEFAULT := 0.05
## The smallest rock drawn grows from INNER_D at the eye to OUTER_D at OUTER_M, in BANDS steps, as smaller ones
## fall under a pixel; the field thins to nothing over its outer third, so it has no edge. At most MAX rocks.
const INNER_D := 0.15
const BANDS := 6
const OUTER_M := 220.0
const OUTER_D := 0.6
const D_MAX := 4.0
const MAX := 14000
const SHOWN_M := 700.0

## The model's cumulative count per square metre from `d_min` up, on a log grid of diameters to D_MAX:
## [diameters, counts], each count the rocks between d_min and that diameter, −dF/dD over a rock's area πD²/4.
static func table(k: float, d_min: float) -> Array:
	var q := 1.79 + 0.152 / k
	var steps := 240
	var r := pow(D_MAX / d_min, 1.0 / steps)
	var ds := PackedFloat64Array(); var cum := PackedFloat64Array()
	var acc := 0.0
	var d := d_min
	for i in steps:
		var d1 := d * r
		var dm := sqrt(d * d1)
		acc += k * q * exp(-q * dm) / (PI * dm * dm / 4.0) * (d1 - d)
		ds.append(d1); cum.append(acc)
		d = d1
	return [ds, cum]

## Rocks per square metre larger than `d_min`.
static func density(k: float, d_min: float) -> float:
	var t := table(k, d_min)
	return (t[1] as PackedFloat64Array)[-1]

## Cells of CELL_M a side each draw their own rocks from their own seed, so a rock is where it was whenever the
## field is laid out again about a new centre; the field follows the eye once it has moved REFRESH_M.
const CELL_M := 25.0
const REFRESH_M := 40.0

var node: MultiMeshInstance3D
var _relief: SurfaceRelief
var _patch_y := 0.0
var _k := K_DEFAULT
var _tables := []
var _centre := Vector2(INF, INF)

## The rocks for a site, a MultiMeshInstance3D in its frame (x west, y up, z north), or null where none lie.
static func build(b: Body, relief: SurfaceRelief, patch_y: float, colour: Vector3, biota: float) -> SiteRocks:
	if biota > 0.1 or relief.grids.is_empty(): return null
	var r := SiteRocks.new()
	r._relief = relief
	r._patch_y = patch_y
	r._k = float(K.get(b.name, K_DEFAULT))
	r._tables = []
	for i in BANDS: r._tables.append(table(r._k, lerpf(INNER_D, OUTER_D, float(i) / float(BANDS - 1))))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _rock_mesh()
	r.node = MultiMeshInstance3D.new()
	r.node.name = "rocks"
	r.node.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(colour.x, colour.y, colour.z)
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mat.normal_enabled = true
	mat.normal_texture = _pit_normals()
	mat.normal_scale = 0.6
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(1.6, 1.6, 1.6)
	r.node.material_override = mat
	r.node.visibility_range_end = SHOWN_M
	r.follow(0.0, 0.0)
	return r

## Lay the field out about (east, north), m, if the eye has moved far enough from where it last was.
func follow(e: float, n: float) -> void:
	var at := Vector2(e, n)
	if at.distance_to(_centre) < REFRESH_M: return
	_centre = at
	var xforms: Array[Transform3D] = []
	var tints := PackedColorArray()
	var reach := int(ceil(OUTER_M / CELL_M))
	var ci := int(floor(e / CELL_M)); var cj := int(floor(n / CELL_M))
	var rng := RandomNumberGenerator.new()
	for dj in range(-reach, reach + 1):
		for di in range(-reach, reach + 1):
			var c0 := Vector2((ci + di) * CELL_M, (cj + dj) * CELL_M)
			var mid := c0 + Vector2(CELL_M, CELL_M) * 0.5
			var dist := mid.distance_to(at)
			if dist > OUTER_M: continue
			var tab: Array = _tables[mini(int(dist / OUTER_M * BANDS), BANDS - 1)]
			var keep := 1.0 - smoothstep(OUTER_M * 0.65, OUTER_M, dist)
			var ds: PackedFloat64Array = tab[0]
			var cum: PackedFloat64Array = tab[1]
			rng.seed = hash([_relief.seed, ci + di, cj + dj, 977])
			# The cell's count: its expectation, its fraction drawn.
			var want := cum[-1] * CELL_M * CELL_M
			var count := int(want) + (1 if rng.randf() < want - floorf(want) else 0)
			for i in count:
				if xforms.size() >= MAX: break
				var pe := c0.x + rng.randf() * CELL_M
				var pn := c0.y + rng.randf() * CELL_M
				var d := ds[mini(cum.bsearch(rng.randf() * cum[-1]), ds.size() - 1)]
				var sx := d * rng.randf_range(0.8, 1.2)
				var sz := d * rng.randf_range(0.7, 1.1)
				var sy := d * rng.randf_range(0.45, 0.75)
				var yaw := rng.randf() * TAU
				var tilt := rng.randf_range(-0.3, 0.3)
				var shade := rng.randf_range(0.75, 1.1)
				if rng.randf() > keep: continue
				var g := SiteScene.drawn_height(_relief.grids, pe, pn, _patch_y, _relief.radius_m, false)
				if is_nan(g) or (_relief.has_sea and g <= _relief.sea_m): continue
				# Rocks are wider than tall, and sit part in the ground.
				var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, tilt) * Basis.from_scale(Vector3(sx, sy, sz) * 0.5)
				xforms.append(Transform3D(basis, Vector3(-pe, g + sy * 0.15, pn)))
				tints.append(Color(shade, shade, shade))
	var mm := node.multimesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, tints[i])

# A unit rock: an icosahedron split once, its 42 corners pushed in and out at random and shaded smooth, the
# underside flattened where it sits in the ground: the rounded, irregular stones of PIA24424 and PIA24429.
static func _rock_mesh() -> ArrayMesh:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v: Array[Vector3] = [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t),
		Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var f := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for i in v.size(): v[i] = v[i].normalized()
	# Split each face in four, sharing the new mid-edge corners.
	var mids := {}
	var faces := []
	for tri: Array in f:
		var m := []
		for k in 3:
			var a: int = tri[k]; var b: int = tri[(k + 1) % 3]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if not mids.has(key):
				mids[key] = v.size()
				v.append(((v[a] + v[b]) * 0.5).normalized())
			m.append(mids[key])
		faces.append_array([[tri[0], m[0], m[2]], [tri[1], m[1], m[0]], [tri[2], m[2], m[1]], [m[0], m[1], m[2]]])
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	# Two scales of lumpiness: the corners' own, and a broad squash that keeps it from being a ball.
	var squash := Vector3(rng.randf_range(0.85, 1.15), 1.0, rng.randf_range(0.8, 1.1))
	for i in v.size():
		var u := v[i]
		var r := rng.randf_range(0.82, 1.12) * (1.0 + 0.12 * sin(u.x * 3.1 + 1.3) * cos(u.z * 2.7))
		var p := u * r * squash
		if p.y < -0.35: p.y = -0.35 - (p.y + 0.35) * 0.3
		v[i] = p
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in v:
		st.set_uv(Vector2(atan2(p.z, p.x) / TAU + 0.5, p.y * 0.5 + 0.5))
		st.add_vertex(p)
	for tri: Array in faces:
		# Wound to face out (Godot's front faces wind clockwise seen from the front).
		var a: Vector3 = v[tri[0]]; var b: Vector3 = v[tri[1]]; var c: Vector3 = v[tri[2]]
		if (b - a).cross(c - a).dot(a + b + c) < 0.0:
			st.add_index(tri[0]); st.add_index(tri[1]); st.add_index(tri[2])
		else:
			st.add_index(tri[0]); st.add_index(tri[2]); st.add_index(tri[1])
	st.generate_normals()
	return st.commit()

# Pits and grain on the faces: cellular noise as a normal map, mapped triplanar so a stretched rock is not smeared.
static var _pits: NoiseTexture2D = null
static func _pit_normals() -> NoiseTexture2D:
	if _pits != null: return _pits
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_CELLULAR
	fn.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	fn.frequency = 0.06
	_pits = NoiseTexture2D.new()
	_pits.noise = fn
	_pits.width = 256; _pits.height = 256
	_pits.seamless = true
	_pits.as_normal_map = true
	_pits.bump_strength = 4.0
	return _pits
