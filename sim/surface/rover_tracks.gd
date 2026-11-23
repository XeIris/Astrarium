class_name RoverTracks
extends RefCounted

# Where the wheels have run: a strip the tread's width along each wheel's contact points, its chevron
# imprints drawn into the ground's shading (shaders/surface/track.gdshader multiplies the ground under
# it). How deep each one is, Bekker's sinkage, is the physics'; the strip carries it to the shader, which
# darkens deeper ruts more. Drawing only.

const SHADER := preload("res://shaders/surface/track.gdshader")
## A point every this far along a wheel's path, m, and at most this many per wheel.
const STEP := 0.2
const MAX_POINTS := 3000

var paths: Array = [[], [], [], []]       # per wheel: [Vector3 contact point (site frame), sinkage m, distance m]
var view: MeshInstance3D = null
var _dirty := false
var _last: Array = [null, null, null, null]
var _mat: ShaderMaterial = null

## Record the wheels' contact points as they move on.
func step(rover: Rover) -> void:
	for i in rover.wheels.size():
		var wh: Rover.Wheel = rover.wheels[i]
		if not wh.contact: continue
		# On the surface, not at the rut's floor: the rut is the shader's, and the strip must lie on the ground.
		var p := wh.contact_point.to_v3() + Vector3.UP * wh.sinkage
		var path: Array = paths[i]
		var last = _last[i]
		if last != null and p.distance_to(last[0]) < STEP: continue
		var along: float = 0.0 if last == null else float(last[2]) + p.distance_to(last[0])
		# A jump (the wheel was in the air) starts a new strip.
		if last != null and p.distance_to(last[0]) > 1.5: path.append(null)
		var point := [p, wh.sinkage, along]
		path.append(point)
		_last[i] = point
		if path.size() > MAX_POINTS: path.pop_front()
		_dirty = true

## Build the strips' mesh under `parent` (the site's group) when anything changed.
func draw(parent: Node3D, up_offset := 0.006) -> void:
	if not _dirty: return
	_dirty = false
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for path: Array in paths:
		var prev = null
		for k in path.size():
			var cur = path[k]
			if cur == null or prev == null:
				prev = cur
				continue
			var a: Vector3 = prev[0]
			var b: Vector3 = cur[0]
			var d := b - a
			if d.length() < 1e-4:
				continue
			var side := d.cross(Vector3.UP).normalized() * (Rover.WHEEL_B * 0.5)
			var base := verts.size()
			for p in [a - side, a + side, b - side, b + side]:
				verts.append((p as Vector3) + Vector3.UP * up_offset)
			uvs.append_array([Vector2(0, prev[2]), Vector2(1, prev[2]), Vector2(0, cur[2]), Vector2(1, cur[2])])
			for z in [prev[1], prev[1], cur[1], cur[1]]: cols.append(Color(float(z) * 20.0, 0.0, 0.0))
			idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
			prev = cur
	if view == null:
		view = MeshInstance3D.new()
		view.name = "lrv_tracks"
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		view.material_override = _mat
		view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		view.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
		parent.add_child(view)
	if verts.is_empty():
		view.mesh = null
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	view.mesh = mesh

func dispose() -> void:
	if view != null and is_instance_valid(view): view.queue_free()
	view = null
