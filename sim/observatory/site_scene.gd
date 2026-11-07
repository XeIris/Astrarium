class_name SiteScene
extends RefCounted

# The local world round an observatory, in the flight pass (LocalView): the DEM's terrain
# and the facility's models, in metres, x west, y up, z north, height from sea level.
# The Observatory drives its LocalView and camera. Terrain: tools/build_site_terrain.py.

const LIBRARY := "res://assets/sites/observatories.glb"
const SHADER := preload("res://shaders/observatory/site_terrain.gdshader")
const TREE := preload("res://shaders/observatory/site_tree.gdshader")
## Palettes: [rock A, rock B, soil, green, top of the green (m), fields]. Read from photographs.
const GROUNDS := {
	"cheshire": [0x6d6a55, 0x5e6249, 0xa7925a, 0x5f7f3a, 1200.0, 1.0],
	"cinder": [0x4a3530, 0x6b4638, 0x7d5a44, 0x4c5a35, 2900.0, 0.0],
	"atacama": [0x8a4f33, 0xa86b45, 0xb78258, 0x000000, -1.0, 0.0],
}
## For a check: build every structure from SiteFallback.
static var force_fallback := false

var local: LocalView
var key := ""
var group: Node3D
var patch_y := 0.0
var parts: Array = []            # [{node, pose}]
var _grids: Array = []           # [{n, half, h}]
var _mat: ShaderMaterial
var _time := 0.0
var _library: Node3D = null
var _tree_mats: Array = []

func _init(view: LocalView) -> void:
	local = view
	group = Node3D.new()
	group.name = "ObservatorySite"
	local.root.add_child(group)
	local.place(group, DVec3.new())
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER

func dispose() -> void:
	local.unplace(group)
	if is_instance_valid(group): group.queue_free()

## Stand up site `site_key`, or clear to the bare planet for "" (a custom site).
func build(site_key: String) -> void:
	if site_key == key: return
	key = site_key
	for c in group.get_children():
		group.remove_child(c)
		c.queue_free()
	parts.clear()
	_grids.clear()
	patch_y = 0.0
	var d = Facilities.DATA.get(key)
	if d == null: return
	patch_y = float(d.patch_y)
	var g: Array = GROUNDS[d.ground]
	for i in 4: _mat.set_shader_parameter(["uRockA", "uRockB", "uSoil", "uGreen"][i], _lin(int(g[i])))
	_mat.set_shader_parameter("uGreenTop", g[4])
	_mat.set_shader_parameter("uFields", g[5])
	_load_grids(key, d.flats)
	for grid_i in _grids.size():
		group.add_child(terrain_mesh(_grids, grid_i, patch_y, Rocketry.FIGURES.Earth.a, _mat))
	if not force_fallback and ResourceLoader.exists(LIBRARY):
		var packed := load(LIBRARY) as PackedScene
		if packed != null:
			_library = packed.instantiate() as Node3D
			if _library != null: CraftAssets._prepare(_library)
	for p: Dictionary in d.parts:
		var e: float = p.e
		var n: float = p.n
		var y: float = height_at(e, n) if p.get("y") == null else float(p.y)
		var node := _instance(String(p.stage))
		node.position = _at(e, y, n)
		node.rotation.y = float(p.get("yaw", 0.0))
		group.add_child(node)
		parts.append({"node": node, "stage": String(p.stage), "pose": p.get("pose", {})})
		_pose(node, String(p.stage), p.get("pose", {}))
	if _library != null:
		_library.free()
		_library = null
	if d.ground == "cheshire": group.add_child(_trees(d))

## Site coordinates to local: x is west of the datum, z north, the planet curving away.
func _at(e: float, y: float, n: float) -> Vector3:
	return Vector3(-e, y - (e * e + n * n) / (2.0 * Rocketry.FIGURES.Earth.a), n)

static func _lin(hex: int) -> Vector3:
	var c := U.lin(hex)
	return Vector3(c.r, c.g, c.b)

## A site's packed tile: [{n, half, h}], near grid first; [] when absent.
static func read_grids(site_key: String) -> Array:
	var out := []
	var f := FileAccess.open("res://assets/sites/%s.terrain" % site_key, FileAccess.READ)
	if f == null or f.get_buffer(4).get_string_from_ascii() != "ASTE":
		push_error("site_scene: no terrain for %s" % site_key)
		return out
	for g in 2:
		var n := f.get_32()
		var half := f.get_float()
		var raw := f.get_buffer(n * n * 2)
		var h := PackedFloat32Array()
		h.resize(n * n)
		for i in n * n:
			h[i] = (raw[i * 2] | (raw[i * 2 + 1] << 8)) * 0.1 - 100.0
		out.append({"n": n, "half": half, "h": h})
	return out

func _load_grids(site_key: String, flats: Array) -> void:
	_grids = read_grids(site_key)
	if _grids.is_empty(): return
	# Level each footprint. A DEM height (null) is read before any levelling.
	var levels := []
	for fl: Array in flats:
		levels.append(float(fl[5]) if fl[5] != null else height_at(fl[0], fl[1]))
	for gi in 2:
		var g: Dictionary = _grids[gi]
		var n: int = g.n
		var half: float = g.half
		var step := 2.0 * half / float(n - 1)
		var h: PackedFloat32Array = g.h
		for k in flats.size():
			var fl: Array = flats[k]
			var cy := cos(fl[4]); var sy := sin(fl[4])
			var reach: float = maxf(fl[2], fl[3]) + fl[6]
			var i0 := clampi(int((fl[0] - reach + half) / step), 0, n - 1)
			var i1 := clampi(int((fl[0] + reach + half) / step) + 1, 0, n - 1)
			var j0 := clampi(int((fl[1] - reach + half) / step), 0, n - 1)
			var j1 := clampi(int((fl[1] + reach + half) / step) + 1, 0, n - 1)
			for j in range(j0, j1 + 1):
				for i in range(i0, i1 + 1):
					var de: float = -half + i * step - fl[0]
					var dn: float = -half + j * step - fl[1]
					var u: float = (de * cy - dn * sy) / fl[2]
					var v: float = (de * sy + dn * cy) / fl[3]
					var over: float = (sqrt(u * u + v * v) - 1.0) * minf(fl[2], fl[3])
					if over >= fl[6]: continue
					h[j * n + i] = lerpf(float(levels[k]), h[j * n + i], smoothstep(0.0, fl[6], over))

## Ground height (m above the sea) at metres east and north of the datum; 0 off the tile.
func height_at(e: float, n: float) -> float:
	return sample(_grids, e, n)

static func sample(grids: Array, e: float, n: float) -> float:
	for g: Dictionary in grids:
		var half: float = g.half
		if absf(e) >= half or absf(n) >= half: continue
		var cells: int = int(g.n) - 1
		var fx := (e + half) / (2.0 * half) * cells
		var fy := (n + half) / (2.0 * half) * cells
		var i := int(fx); var j := int(fy)
		var tx := fx - i; var ty := fy - j
		var h: PackedFloat32Array = g.h
		var w: int = g.n
		return lerpf(lerpf(h[j * w + i], h[j * w + i + 1], tx), lerpf(h[(j + 1) * w + i], h[(j + 1) * w + i + 1], tx), ty)
	return 0.0

## A grid as a mesh: x west, y up, z north, the planet curving away by `R`. With `sea`, cells at sea
## level tuck under the sea; `channel` (log₁₀ drainage area per cell) rides in UV2.y for rivers.
static func terrain_mesh(grids: Array, gi: int, patch_y: float, R: float, mat: Material, sea := true, channel := PackedFloat32Array()) -> MeshInstance3D:
	var g: Dictionary = grids[gi]
	var n: int = g.n
	var half: float = g.half
	var h: PackedFloat32Array = g.h
	var step := 2.0 * half / float(n - 1)
	var far := gi > 0
	var near_half: float = grids[0].half
	var verts := PackedVector3Array(); verts.resize(n * n)
	var norms := PackedVector3Array(); norms.resize(n * n)
	var uv := PackedVector2Array(); uv.resize(n * n)
	var uv2 := PackedVector2Array(); uv2.resize(n * n)
	for j in n:
		var dn := -half + j * step
		for i in n:
			var de := -half + i * step
			var y: float = h[j * n + i]
			var idx := j * n + i
			var drawn := y
			# The sea belongs to the planet's patch, and the far grid tucks under the near.
			if sea and y <= 0.5: drawn = -40.0
			elif far and absf(de) < near_half and absf(dn) < near_half: drawn = y - 6.0
			# The far grid's rim drops to the patch rather than ending in a step.
			if far and (i == 0 or j == 0 or i == n - 1 or j == n - 1): drawn = minf(drawn, patch_y - 30.0)
			verts[idx] = Vector3(-de, drawn - (de * de + dn * dn) / (2.0 * R), dn)
			uv[idx] = Vector2(de, dn)
			uv2[idx] = Vector2(y, channel[idx] if not channel.is_empty() else 0.0)
			var ix0 := maxi(i - 1, 0); var ix1 := mini(i + 1, n - 1)
			var jy0 := maxi(j - 1, 0); var jy1 := mini(j + 1, n - 1)
			var dhde := (h[j * n + ix1] - h[j * n + ix0]) / ((ix1 - ix0) * step)
			var dhdn := (h[jy1 * n + i] - h[jy0 * n + i]) / ((jy1 - jy0) * step)
			# x is west, so the slope along x is minus the slope east.
			norms[idx] = Vector3(dhde, 1.0, -dhdn).normalized()
	var idx := PackedInt32Array()
	idx.resize((n - 1) * (n - 1) * 6)
	var w := 0
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			if far:
				# Skip what the near grid covers, less a cell of overlap.
				var de := -half + (i + 0.5) * step
				var dn := -half + (j + 0.5) * step
				if absf(de) < near_half - step and absf(dn) < near_half - step: continue
			# Clockwise from above, in a frame whose x runs west.
			idx[w] = a; idx[w + 1] = a + n; idx[w + 2] = a + 1
			idx[w + 3] = a + 1; idx[w + 4] = a + n; idx[w + 5] = a + n + 1
			w += 6
	idx.resize(w)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "terrain_%d" % gi
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
	return mi

## A structure from the library, or its fallback blocks.
func _instance(stage: String) -> Node3D:
	if _library != null:
		var src := _library.find_child("stage_" + stage, true, false) as Node3D
		if src != null:
			var copy := src.duplicate() as Node3D
			copy.transform = Transform3D.IDENTITY
			copy.name = stage
			return copy
	return SiteFallback.build(stage)

static func _pivot(node: Node3D, stage: String, part: String) -> Node3D:
	return node.find_child("door_%s_%s" % [stage, part], true, false) as Node3D

## Set a structure's moving parts: az and dome (compass °), el (°), open and slide.
static func _pose(node: Node3D, stage: String, pose: Dictionary) -> void:
	var az := _pivot(node, stage, "az")
	if az != null and pose.has("az"): az.rotation.y = -deg_to_rad(float(pose.az))
	var el := _pivot(node, stage, "el")
	if el != null and pose.has("el"): el.rotation.x = deg_to_rad(90.0 - float(pose.el))
	var dome := _pivot(node, stage, "dome")
	if dome != null and pose.has("dome"): dome.rotation.y = -deg_to_rad(float(pose.dome))
	# Keck's shutters part over the sphere, each about its horizontal axis.
	var shut_l := _pivot(node, stage, "shutter_l")
	var shut_r := _pivot(node, stage, "shutter_r")
	if shut_l != null and shut_r != null:
		var open := deg_to_rad(27.0) * float(pose.get("open", 0.0))
		shut_l.rotation.z = open
		shut_r.rotation.z = -open
	# The VLT's roof modules slide out over the shoulders.
	var door_l := _pivot(node, stage, "door_l")
	var door_r := _pivot(node, stage, "door_r")
	if door_l != null and door_r != null:
		door_l.position.x = -float(pose.get("slide", 0.0))
		door_r.position.x = float(pose.get("slide", 0.0))

## Point part `i` at compass azimuth `az` and elevation `el` (degrees), with its enclosure,
## in place of its idle sway.
func aim(i: int, az: float, el: float) -> void:
	if i < 0 or i >= parts.size(): return
	var p: Dictionary = parts[i]
	p.aimed = true
	aim_pose(p.node, p.stage, p.pose, az, el)

## `node`'s moving parts for that pointing. The structure's own yaw turns its az pivot with it.
static func aim_pose(node: Node3D, stage: String, base: Dictionary, az: float, el: float) -> void:
	var live := base.duplicate()
	live.az = az + rad_to_deg(node.rotation.y)
	live.el = el
	if live.has("dome"): live.dome = live.az
	if stage.begins_with("keck"): live.open = 1.0
	_pose(node, stage, live)

## Per frame while the facility is on show: the telescopes keep working.
func animate(dt: float) -> void:
	_time += dt
	for p: Dictionary in parts:
		var pose: Dictionary = p.pose
		if not pose.has("el") or p.get("aimed", false): continue
		var live := pose.duplicate()
		live.el = float(pose.el) + 6.0 * sin(_time * 0.11)
		if pose.has("az"): live.az = float(pose.az) + 12.0 * sin(_time * 0.07)
		if pose.has("dome"): live.dome = live.az
		_pose(p.node, p.stage, live)

## The sky pass's light for the terrain, after LocalView.update.
func light(sun_l: Vector3, eye: float) -> void:
	_mat.set_shader_parameter("uSunDir", sun_l)
	_mat.set_shader_parameter("uEye", eye)
	var gm := local.ground_mat
	for p in ["uHaze", "uDensity", "uScaleH", "uHasAir", "uSkyI"]:
		_mat.set_shader_parameter(p, gm.get_shader_parameter(p))
	for t: ShaderMaterial in _tree_mats:
		t.set_shader_parameter("uSkyI", gm.get_shader_parameter("uSkyI"))
		t.set_shader_parameter("uSunY", sun_l.y)

## Hedgerow oaks and the conifers round the Lovell, as one instanced mesh each.
func _trees(d: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "trees"
	var rng := RandomNumberGenerator.new()
	rng.seed = 5361
	var flats: Array = d.flats
	var kinds := [_tree_mesh(false), _tree_mesh(true)]
	_tree_mats.clear()
	for k in 2:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = kinds[k]
		var placed := []
		var tries := 0
		while placed.size() < 700 and tries < 6000:
			tries += 1
			# Clumped: a wood's centre, then a tree near it.
			var a := rng.randf() * TAU
			# Beyond the film camera's circle.
			var r := 250.0 + pow(rng.randf(), 1.4) * 1500.0
			var e := r * cos(a) + 45.0 * rng.randfn()
			var n := r * sin(a) + 45.0 * rng.randfn()
			if fmod(absf(e * 0.013) + 0.6 * sin(n * 0.009), 2.0) > 1.15: continue
			var clear := true
			for fl: Array in flats:
				if Vector2(e - float(fl[0]), n - float(fl[1])).length() < float(fl[2]) + 18.0: clear = false
			if not clear: continue
			var s := rng.randf_range(0.65, 1.1)
			var t := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.25), s)), _at(e, height_at(e, n), n))
			placed.append(t)
		mm.instance_count = placed.size()
		for i in placed.size(): mm.set_instance_transform(i, placed[i])
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		var tm := ShaderMaterial.new()
		tm.shader = TREE
		tm.set_shader_parameter("uAlbedo", Vector3(0.12, 0.18, 0.1) if k == 1 else Vector3(0.17, 0.23, 0.1))
		mi.material_override = tm
		_tree_mats.append(tm)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.custom_aabb = AABB(Vector3(-4000, -500, -4000), Vector3(8000, 3000, 8000))
		root.add_child(mi)
	return root

static func _tree_mesh(conifer: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if conifer:
		# Tiers of cone, a pine's stepped outline.
		for t in 4:
			var c := CylinderMesh.new()
			var k := 1.0 - t * 0.22
			c.top_radius = 0.15; c.bottom_radius = 4.0 * k; c.height = 7.5 * k; c.radial_segments = 8; c.rings = 1
			st.append_from(c, 0, Transform3D(Basis(), Vector3(0.0, 3.0 + t * 4.4 + c.height * 0.5, 0.0)))
	else:
		# Three overlapping crowns, an oak's lumpy one.
		for b: Array in [[Vector3(0.0, 9.0, 0.0), 6.0], [Vector3(3.2, 7.0, 1.4), 4.2], [Vector3(-2.8, 7.4, -1.8), 4.4]]:
			var s := SphereMesh.new()
			s.radius = b[1]; s.height = float(b[1]) * 1.7; s.radial_segments = 8; s.rings = 4
			st.append_from(s, 0, Transform3D(Basis(), b[0]))
	return st.commit()
