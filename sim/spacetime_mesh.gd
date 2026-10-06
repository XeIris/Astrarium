class_name SpacetimeMesh
extends RefCounted

# A deformed sheet under the orbit focus. Its geometry uses concentric square
# bands so the number of vertices stays bounded over a wide view. The visible
# grid or dots are drawn procedurally from local XZ coordinates in the shader;
# one zoom-dependent spacing applies to every band, without a dense centre or
# sparse stripes at the joins. Both styles use the same well displacement.

const INNER_SIZE := 120.0
const INNER_SEG := 112
const RING_SEG := 56
const RING_LEVELS := 9
const MAX_EXTENT := 30720.0
const GRID_PIXELS := 18.0
const LINE_SHADER := preload("res://shaders/bodies/mesh_spacetime.gdshader")
const DOT_SHADER := preload("res://shaders/bodies/mesh_spacetime_dots.gdshader")

var node: MeshInstance3D
var outer_node: MeshInstance3D
var line_mat: ShaderMaterial
var dot_mat: ShaderMaterial
var inner_cache := {}
var outer_cache := {}
var lod := 0
var style := "lines"
var time := 0.0
var origin := DVec3.new(0.0, -6.0, 0.0)

static func _mesh(verts: PackedVector3Array, idx: PackedInt32Array, extent: float) -> ArrayMesh:
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	# The shader lowers the vertices after culling.
	mesh.custom_aabb = AABB(Vector3(-extent, -1500.0, -extent), Vector3(extent * 2.0, 1600.0, extent * 2.0))
	return mesh

static func build_center(level: int) -> ArrayMesh:
	var size := INNER_SIZE * pow(2.0, level)
	var seg := INNER_SEG if level == 0 else RING_SEG
	var half := size * 0.5
	var step := size / seg
	var stride := seg + 1
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	verts.resize(stride * stride)
	idx.resize(seg * seg * 6)
	for iy in stride:
		for ix in stride:
			verts[iy * stride + ix] = Vector3(-half + ix * step, 0.0, -half + iy * step)
	var k := 0
	for iy in seg:
		for ix in seg:
			var a := ix + stride * iy
			var b := a + stride
			var d := a + 1
			var c := b + 1
			idx[k] = a; idx[k + 1] = b; idx[k + 2] = d
			idx[k + 3] = b; idx[k + 4] = c; idx[k + 5] = d
			k += 6
	return _mesh(verts, idx, half)

static func build_outer(start_level: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	const HOLE_BEGIN := RING_SEG / 4
	const HOLE_END := RING_SEG - HOLE_BEGIN
	var stride := RING_SEG + 1
	for level in range(start_level, RING_LEVELS):
		var half := (INNER_SIZE * 0.5) * pow(2.0, level + 1)
		var step := 2.0 * half / RING_SEG
		var offset := verts.size()
		for iy in stride:
			for ix in stride:
				verts.append(Vector3(-half + ix * step, 0.0, -half + iy * step))
		for iy in RING_SEG:
			for ix in RING_SEG:
				if ix >= HOLE_BEGIN and ix < HOLE_END and iy >= HOLE_BEGIN and iy < HOLE_END:
					continue
				var a := offset + ix + stride * iy
				var b := a + stride
				var d := a + 1
				var c := b + 1
				idx.append_array(PackedInt32Array([a, b, d, b, c, d]))
	return _mesh(verts, idx, MAX_EXTENT)

func _init() -> void:
	line_mat = ShaderMaterial.new()
	line_mat.shader = LINE_SHADER
	dot_mat = ShaderMaterial.new()
	dot_mat.shader = DOT_SHADER
	var wells := PackedVector4Array(); wells.resize(16)
	for material in [line_mat, dot_mat]:
		material.set_shader_parameter("wells", wells)
		material.set_shader_parameter("wellCount", 0)
		material.set_shader_parameter("grid_step", 1.0)
	inner_cache[0] = build_center(0)
	outer_cache[0] = build_outer(0)
	node = MeshInstance3D.new()
	node.name = "SpacetimeMesh"
	node.mesh = inner_cache[0]
	node.material_override = line_mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	outer_node = MeshInstance3D.new()
	outer_node.name = "SpacetimeMeshOuter"
	outer_node.mesh = outer_cache[0]
	outer_node.material_override = line_mat
	outer_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(outer_node)

func set_style(which: String) -> void:
	style = "dots" if which == "dots" else "lines"
	var material := dot_mat if style == "dots" else line_mat
	node.material_override = material
	outer_node.material_override = material

func _set_lod(next_lod: int) -> void:
	if next_lod == lod:
		return
	lod = next_lod
	if not inner_cache.has(lod):
		inner_cache[lod] = build_center(lod)
	if not outer_cache.has(lod):
		outer_cache[lod] = build_outer(lod)
	node.mesh = inner_cache[lod]
	outer_node.mesh = outer_cache[lod]

## Recenter the sheet after the camera is final. The geometry LOD only changes
## when its projected spacing would fall below three pixels. The visible grid
## spacing changes smoothly with zoom and stays identical across both meshes.
func update(bodies: Array, mcx: float, mcz: float, sim_stepped: float, cam_pos: DVec3,
		viewport_size: Vector2 = Vector2(1600.0, 1000.0), fov_degrees: float = 50.0) -> void:
	origin.set_v(mcx, -6.0, mcz)
	node.position = origin.rel_v3(cam_pos)
	var dx := cam_pos.x - mcx
	var dy := cam_pos.y + 6.0
	var dz := cam_pos.z - mcz
	var distance := sqrt(dx * dx + dy * dy + dz * dz)
	var world_per_pixel := 2.0 * distance * tan(deg_to_rad(fov_degrees) * 0.5) / maxf(viewport_size.y, 1.0)
	var next_lod := 0
	while next_lod < RING_LEVELS - 1:
		var spacing := (INNER_SIZE * pow(2.0, next_lod)) / (INNER_SEG if next_lod == 0 else RING_SEG)
		if spacing >= world_per_pixel * 3.0:
			break
		next_lod += 1
	_set_lod(next_lod)
	var visible_step := maxf(world_per_pixel * GRID_PIXELS, 0.3)
	for material in [line_mat, dot_mat]:
		material.set_shader_parameter("grid_step", visible_step)
	dot_mat.set_shader_parameter("viewport_size", viewport_size)
	var wells := PackedVector4Array(); wells.resize(16)
	var count := 0
	for body in bodies:
		if count >= 16: break
		var p: DVec3 = body.scene_pos
		if body.type == "bh":
			wells[count] = Vector4(p.x - mcx, p.z - mcz, body.rs_scene, 1.0)
		else:
			wells[count] = Vector4(p.x - mcx, p.z - mcz, minf(body.mass + body.radius_scene, 6.0), 0.0)
		count += 1
	for material in [line_mat, dot_mat]:
		material.set_shader_parameter("wells", wells)
		material.set_shader_parameter("wellCount", count)
	time += sim_stepped
	line_mat.set_shader_parameter("time", time)
	dot_mat.set_shader_parameter("time", time)
