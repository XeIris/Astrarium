class_name RoverTracks
extends RefCounted

# Where the wheels have run: a strip along each wheel's contact points, a little wider than the tread so the
# soil heaped beside the rut shows, relit as relief in the ground's shading (shaders/surface/track.gdshader
# multiplies the ground under it). How deep each rut is, Bekker's sinkage, is the physics'; the grousers'
# imprint follows the wheel's own count round its rim. Drawing only.

const SHADER := preload("res://shaders/surface/track.gdshader")
## A point every this far along a wheel's path, m, and at most this many per wheel; filled chunks of CHUNK points are
## meshed once and kept.
const STEP := 0.2
const MAX_POINTS := 3000
const CHUNK := 150

var paths: Array = []       # per wheel: [Vector3 contact point (site frame), sinkage m, distance m, heading], null at a break
var view: Node3D = null
var _dirty := false
## The tread's width, m.
var width := 0.23
## The share of the strip's width the tread takes (track.gdshader's TREAD1 − TREAD0).
const TREAD_SHARE := 0.74
var _pitch := 0.107
var _curve := false
var _last: Array = []
var _mat: ShaderMaterial = null
## Per wheel, [first point's number, MeshInstance3D] of the chunks meshed, and how many points have left the front.
var _chunks: Array = []
var _gone: Array = []

## Record the wheels' contact points as they move on.
func step(rover: Rover) -> void:
	width = float(rover.spec.wheel_b)
	_pitch = TAU * float(rover.spec.wheel_r) / float(rover.spec.get("grousers", 24))
	_curve = bool(rover.spec.get("grouser_curve", false))
	while paths.size() < rover.wheels.size():
		paths.append([])
		_last.append(null)
		_chunks.append([])
		_gone.append(0)
	for i in rover.wheels.size():
		var wh: Rover.Wheel = rover.wheels[i]
		var path: Array = paths[i]
		if not wh.contact:
			# In the air: the strip ends here.
			if _last[i] != null and not path.is_empty() and path[-1] != null: path.append(null)
			_last[i] = null
			continue
		# On the surface, not at the rut's floor: the rut is the shader's, and the strip must lie on the ground.
		var p := wh.contact_point.to_v3() + Vector3.UP * wh.sinkage
		var last = _last[i]
		if last != null and p.distance_to(last[0]) < STEP: continue
		var along: float = 0.0 if last == null else float(last[2]) + p.distance_to(last[0])
		var point := [p, wh.sinkage, along]
		path.append(point)
		_last[i] = point
		while path.size() > MAX_POINTS:
			path.pop_front()
			_gone[i] += 1
		_dirty = true

## Build the strips' mesh under `parent` (the site's group) when anything changed. `sun`: toward the Sun, the
## site's frame.
func draw(parent: Node3D, sun := Vector3.UP, fog := 0.0, up_offset := 0.006) -> void:
	if view == null:
		view = Node3D.new()
		view.name = "tracks"
		parent.add_child(view)
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		_dirty = true
	_mat.set_shader_parameter("uSun", sun.normalized())
	_mat.set_shader_parameter("uFog", fog)
	if not _dirty: return
	_dirty = false
	_mat.set_shader_parameter("uWidth", width / TREAD_SHARE)
	_mat.set_shader_parameter("uPitch", _pitch)
	_mat.set_shader_parameter("uSweep", 0.7 if _curve else 1.6)
	_mat.set_shader_parameter("uCurved", 1.0 if _curve else 0.0)
	for i in paths.size():
		var path: Array = paths[i]
		var made: Array = _chunks[i]
		# Chunks wholly off the front go.
		while not made.is_empty() and int(made[0][0]) + CHUNK <= int(_gone[i]):
			(made.pop_front()[1] as Node).queue_free()
		var from: int = int(made[-1][0]) if not made.is_empty() else int(_gone[i]) / CHUNK * CHUNK
		# The last one is still filling: it is made again.
		if not made.is_empty(): (made.pop_back()[1] as Node).queue_free()
		while from < int(_gone[i]) + path.size():
			var mi := MeshInstance3D.new()
			# One point over into the next, so the strips join.
			mi.mesh = _strip(path, maxi(from - int(_gone[i]), 0), mini(from + CHUNK + 1 - int(_gone[i]), path.size()), up_offset)
			mi.material_override = _mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			view.add_child(mi)
			made.append([from, mi])
			from += CHUNK

func _strip(path: Array, from: int, to: int, up_offset: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var heads := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var prev = null
	for k in range(from, to):
		var cur = path[k]
		if cur == null or prev == null:
			prev = cur
			continue
		var a: Vector3 = prev[0]
		var b: Vector3 = cur[0]
		var d := b - a
		if d.length() < 1e-4: continue
		var side := d.cross(Vector3.UP).normalized() * (width * 0.5 / TREAD_SHARE)
		var hd := Vector2(d.x, d.z).normalized()
		var base := verts.size()
		for p in [a - side, a + side, b - side, b + side]: verts.append((p as Vector3) + Vector3.UP * up_offset)
		uvs.append_array([Vector2(0, prev[2]), Vector2(1, prev[2]), Vector2(0, cur[2]), Vector2(1, cur[2])])
		heads.append_array([hd, hd, hd, hd])
		for z in [prev[1], prev[1], cur[1], cur[1]]: cols.append(Color(float(z) * 20.0, 0.0, 0.0))
		idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
		prev = cur
	if verts.is_empty(): return null
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_TEX_UV2] = heads
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func dispose() -> void:
	if view != null and is_instance_valid(view): view.queue_free()
	view = null
	for i in _chunks.size(): _chunks[i] = []
	_dirty = true
