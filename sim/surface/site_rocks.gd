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
static func table(k: float, d_min: float, d_max := D_MAX) -> Array:
	var q := 1.79 + 0.152 / k
	var steps := 240
	var r := pow(d_max / d_min, 1.0 / steps)
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

## Cells of CELL_M a side draw each size class's rocks from a seed of its own, so a rock is where and what it was
## whenever the field is laid out again and however near the eye has come; the field follows the eye once it has
## moved REFRESH_M, and waits while it is too high to see any.
const CELL_M := 25.0
const REFRESH_M := 40.0
## How many classes' worth of cells are kept once laid.
const KEPT := 4000

var node: MultiMeshInstance3D
var _relief: SurfaceRelief
var _patch_y := 0.0
var _classes := []
var _centre := Vector2(INF, INF)
## (cell, class) -> [the instances' buffer, each one's roll against thinning out].
var _laid := {}

## The rocks for a site, a MultiMeshInstance3D in its frame (x west, y up, z north), or null where none lie. `colour`
## is linear.
static func build(b: Body, relief: SurfaceRelief, patch_y: float, colour: Vector3, biota: float) -> SiteRocks:
	if biota > 0.1 or relief.grids.is_empty(): return null
	var r := SiteRocks.new()
	r._relief = relief
	r._patch_y = patch_y
	r._classes = classes(float(K.get(b.name, K_DEFAULT)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _rock_mesh()
	r.node = MultiMeshInstance3D.new()
	r.node.name = "rocks"
	r.node.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(colour.x, colour.y, colour.z).linear_to_srgb()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mat.normal_enabled = true
	mat.normal_texture = _pit_normals()
	mat.normal_scale = 0.6
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(1.6, 1.6, 1.6)
	r.node.material_override = mat
	r.node.visibility_range_end = SHOWN_M
	r.follow(0.0, 0.0, 0.0)
	return r

## The smallest diameter drawn in band `i`, m, and so the least of its size class.
static func band_d(i: int) -> float:
	return lerpf(INNER_D, OUTER_D, float(i) / float(BANDS - 1))

## The size classes, smallest first: each a [diameters, counts] table of the rocks from its band's least diameter to
## the next band's.
static func classes(k: float) -> Array:
	var out := []
	for i in BANDS: out.append(table(k, band_d(i), band_d(i + 1) if i + 1 < BANDS else D_MAX))
	return out

## A cell's rocks of one class: [east, north, its three sizes, yaw, tilt, shade, its roll against thinning out, its
## diameter].
static func cell_rocks(seed_: int, ci: int, cj: int, which: int, tab: Array) -> Array:
	var ds: PackedFloat64Array = tab[0]
	var cum: PackedFloat64Array = tab[1]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed_, ci, cj, which, 977])
	# The cell's count: its expectation, its fraction drawn.
	var want := cum[-1] * CELL_M * CELL_M
	var count := int(want) + (1 if rng.randf() < want - floorf(want) else 0)
	var out := []
	for i in count:
		var pe := (ci + rng.randf()) * CELL_M
		var pn := (cj + rng.randf()) * CELL_M
		var d := ds[mini(cum.bsearch(rng.randf() * cum[-1]), ds.size() - 1)]
		var sx := d * rng.randf_range(0.8, 1.2)
		var sz := d * rng.randf_range(0.7, 1.1)
		var sy := d * rng.randf_range(0.45, 0.75)
		out.append([pe, pn, sx, sy, sz, rng.randf() * TAU, rng.randf_range(-0.3, 0.3), rng.randf_range(0.75, 1.1), rng.randf(), d])
	return out

## The diameters, m, of the rocks of `d_min` or more within `radius` of (east, north), as they are drawn. Cells are
## kept in `cache`.
static func near(relief: SurfaceRelief, body_name: String, e: float, n: float, radius: float, d_min: float, cache: Dictionary) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if not cache.has("classes"): cache.classes = classes(float(K.get(body_name, K_DEFAULT)))
	for cj in range(int(floor((n - radius) / CELL_M)), int(floor((n + radius) / CELL_M)) + 1):
		for ci in range(int(floor((e - radius) / CELL_M)), int(floor((e + radius) / CELL_M)) + 1):
			for which in BANDS:
				if which + 1 < BANDS and band_d(which + 1) <= d_min: continue
				var key := Vector3i(ci, cj, which)
				if not cache.has(key): cache[key] = cell_rocks(relief.seed, ci, cj, which, cache.classes[which])
				for rock: Array in cache[key]:
					if float(rock[9]) >= d_min and Vector2(float(rock[0]) - e, float(rock[1]) - n).length() <= radius: out.append(rock[9])
	return out

## Lay the field out about (east, north), m, the eye `over` m above the ground there, if it has moved far enough.
func follow(e: float, n: float, over: float) -> void:
	var at := Vector2(e, n)
	if over > SHOWN_M or at.distance_to(_centre) < REFRESH_M: return
	_centre = at
	if _laid.size() > KEPT: _laid.clear()
	var buf := PackedFloat32Array()
	var reach := int(ceil(OUTER_M / CELL_M))
	var ci := int(floor(e / CELL_M)); var cj := int(floor(n / CELL_M))
	for dj in range(-reach, reach + 1):
		for di in range(-reach, reach + 1):
			var mid := (Vector2(ci + di, cj + dj) + Vector2(0.5, 0.5)) * CELL_M
			var dist := mid.distance_to(at)
			if dist > OUTER_M: continue
			var keep := 1.0 - smoothstep(OUTER_M * 0.65, OUTER_M, dist)
			# The nearer the eye, the smaller the classes drawn with the larger.
			for which in range(mini(int(dist / OUTER_M * BANDS), BANDS - 1), BANDS):
				var key := Vector3i(ci + di, cj + dj, which)
				if not _laid.has(key): _laid[key] = _lay(key)
				var made: Array = _laid[key]
				var rows: PackedFloat32Array = made[0]
				var rolls: PackedFloat32Array = made[1]
				if buf.size() + rows.size() > MAX * ROW: continue
				if keep >= 1.0:
					buf.append_array(rows)
					continue
				for i in rolls.size():
					if rolls[i] <= keep: buf.append_array(rows.slice(i * ROW, (i + 1) * ROW))
	var mm := node.multimesh
	mm.instance_count = buf.size() / ROW
	if not buf.is_empty(): mm.buffer = buf

## An instance's row in a MultiMesh's buffer: its 3 × 4 transform and its colour.
const ROW := 16

func _lay(key: Vector3i) -> Array:
	var rows := PackedFloat32Array()
	var rolls := PackedFloat32Array()
	for rock: Array in cell_rocks(_relief.seed, key.x, key.y, key.z, _classes[key.z]):
		var pe: float = rock[0]; var pn: float = rock[1]
		var g := SiteScene.drawn_height(_relief.grids, pe, pn, _patch_y, _relief.radius_m, false)
		# Heights are over the sea where there is one.
		if is_nan(g) or (_relief.has_sea and g <= 0.0): continue
		# Rocks are wider than tall, and sit part in the ground.
		var size := Vector3(rock[2], rock[3], rock[4])
		var b := Basis(Vector3.UP, rock[5]) * Basis(Vector3.RIGHT, rock[6]) * Basis.from_scale(size * 0.5)
		var y := g + size.y * 0.15
		var shade: float = rock[7]
		rows.append_array(PackedFloat32Array([b.x.x, b.y.x, b.z.x, -pe, b.x.y, b.y.y, b.z.y, y, b.x.z, b.y.z, b.z.z, pn, shade, shade, shade, 1.0]))
		rolls.append(rock[8])
	return [rows, rolls]

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
