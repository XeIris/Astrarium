class_name Trail
extends RefCounted

# Double ring buffer uploaded to a float32 texture, oldest segments first.
# Points are anchor-relative; reanchor near the body to limit float32 error.
# Depth-writing trails may occlude the point-source marker.

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_always, cull_disabled;
#include "res://shaders/common/temp_pass.gdshaderinc"
uniform float u_opacity = 0.5;
uniform vec3 u_color = vec3(1.0);
uniform sampler2D u_pts : filter_nearest;
// (head, count, size) of the ring buffer
uniform ivec3 u_ring = ivec3(0, 0, 2);
varying vec3 v_col;
void vertex() {
	// UV: (this vertex's index along the trail from the oldest, its segment's)
	int i = int(UV.x);
	int n = u_ring.y;
	int M = u_ring.z;
	// In 8-bit steps, truncated, as Godot stores a vertex colour.
	v_col = floor(u_color * (float(i) / float(M - 1)) * 255.0) / 255.0;
	if (int(UV.y) + 1 >= n) {
		POSITION = vec4(2.0, 2.0, 0.5, 1.0);    // outside the clip volume
	} else {
		vec3 p = texelFetch(u_pts, ivec2((u_ring.x - n + i + M) % M, 0), 0).xyz;
		POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(p, 1.0));
	}
}
void fragment() {
	// Additive: c = rgb·opacity + dst; the temperature pass takes opacity² + dst
	// (docs/godot.md).
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(u_opacity, 0.0, 0.0);
	} else {
		ALBEDO = v_col;
	}
	ALPHA = u_opacity;
}
"""
static var _shader: Shader
static var _meshes := {}

## Rewrite about the newest point once it is this many camera distances from the
## anchor (see the header).
const REANCHOR := 2.0
## Also rewrite every this many pushes: between rewrites the bounds only grow, and
## the transparent sort reads their centre.
const REFRESH := 240
static var _phase := 0

var node := MeshInstance3D.new()
var mat := ShaderMaterial.new()
## Pushes since the last update(); main.gd's push_trail counts them.
var pending := 0
var max_n: int
var _pts := PackedFloat32Array()
var _img: Image
var _tex: ImageTexture
var _anchor := DVec3.new()
var _built := false
var _since := 0
var _offset := 0
var _lo := Vector3.ZERO
var _hi := Vector3.ZERO

func _init(p_max: int, color: Color, opacity: float) -> void:
	max_n = p_max
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	_pts.resize(max_n * 4)
	_img = Image.create_from_data(max_n, 1, false, Image.FORMAT_RGBAF, _pts.to_byte_array())
	_tex = ImageTexture.create_from_image(_img)
	mat.shader = _shader
	mat.set_shader_parameter("u_opacity", opacity)
	mat.set_shader_parameter("u_color", Vector3(color.r, color.g, color.b))
	mat.set_shader_parameter("u_ring", Vector3i(0, 0, max_n))
	mat.set_shader_parameter("u_pts", _tex)
	node.mesh = _segments(max_n)
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# its extent changes every frame; culling it would need a fresh AABB each time
	node.extra_cull_margin = 1.0e7
	# spread the periodic rewrites of many trails over different frames
	_offset = _phase
	_phase = (_phase + 37) % REFRESH

# Segment k joins points k and k + 1 along the trail. Positions come from the
# texture, so one mesh serves every trail of a length.
static func _segments(M: int) -> ArrayMesh:
	if _meshes.has(M): return _meshes[M]
	var verts := PackedVector3Array(); verts.resize((M - 1) * 2)
	var uvs := PackedVector2Array(); uvs.resize((M - 1) * 2)
	for k in M - 1:
		uvs[k * 2] = Vector2(k, k)
		uvs[k * 2 + 1] = Vector2(k + 1, k)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	_meshes[M] = m
	return m

func update(b: Body, cam_pos: DVec3) -> void:
	var n := b.trail_count
	if n >= 1:
		var M := max_n
		var buf := b.trail_buf
		var newest := (b.trail_head - 1 + M) % M
		var nx := buf[newest * 3]; var ny := buf[newest * 3 + 1]; var nz := buf[newest * 3 + 2]
		var dx := nx - _anchor.x; var dy := ny - _anchor.y; var dz := nz - _anchor.z
		var cx := nx - cam_pos.x; var cy := ny - cam_pos.y; var cz := nz - cam_pos.z
		if not _built or pending >= M or _since >= REFRESH \
				or dx * dx + dy * dy + dz * dz > REANCHOR * REANCHOR * (cx * cx + cy * cy + cz * cz):
			_rebuild(b)
		elif pending > 0:
			_write_new(b, mini(pending, n))
		if pending > 0:
			_img.set_data(M, 1, false, Image.FORMAT_RGBAF, _pts.to_byte_array())
			_tex.update(_img)
			mat.set_shader_parameter("u_ring", Vector3i(b.trail_head, n, M))
			_since += pending
			pending = 0
	node.position = _anchor.rel_v3(cam_pos)

# Every filled slot, about a new anchor on the newest point.
func _rebuild(b: Body) -> void:
	var M := max_n
	var n := b.trail_count
	var buf := b.trail_buf
	var newest := (b.trail_head - 1 + M) % M
	_anchor.set_v(buf[newest * 3], buf[newest * 3 + 1], buf[newest * 3 + 2])
	var lo := Vector3(INF, INF, INF); var hi := -lo
	for age in n:
		var s := (newest - age + M) % M
		var v := Vector3(buf[s * 3] - _anchor.x, buf[s * 3 + 1] - _anchor.y, buf[s * 3 + 2] - _anchor.z)
		_pts[s * 4] = v.x; _pts[s * 4 + 1] = v.y; _pts[s * 4 + 2] = v.z
		lo = lo.min(v); hi = hi.max(v)
	_lo = lo; _hi = hi
	node.custom_aabb = AABB(lo, hi - lo) if n >= 2 else AABB()
	_since = 0 if _built else _offset
	_built = true
	pending = maxi(pending, 1)    # upload it

# The `count` newest slots, about the current anchor.
func _write_new(b: Body, count: int) -> void:
	var M := max_n
	var buf := b.trail_buf
	var grew := false
	for k in count:
		var s := (b.trail_head - 1 - k + M) % M
		var v := Vector3(buf[s * 3] - _anchor.x, buf[s * 3 + 1] - _anchor.y, buf[s * 3 + 2] - _anchor.z)
		_pts[s * 4] = v.x; _pts[s * 4 + 1] = v.y; _pts[s * 4 + 2] = v.z
		if v.x < _lo.x or v.y < _lo.y or v.z < _lo.z or v.x > _hi.x or v.y > _hi.y or v.z > _hi.z:
			_lo = _lo.min(v); _hi = _hi.max(v)
			grew = true
	if grew and b.trail_count >= 2:
		node.custom_aabb = AABB(_lo, _hi - _lo)
