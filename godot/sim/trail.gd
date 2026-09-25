class_name Trail
extends RefCounted

# ============================================================================
# ORBIT TRAILS — the web build's per-body THREE.Line (blackhole_sim.js,
# spawnBody/pushTrail), in its own file because under the floating origin a
# trail is no longer a buffer that only grows at one end.
# ----------------------------------------------------------------------------
# The ring buffer is kept in DOUBLE precision (Body.trail_buf) and the drawn
# vertices are written relative to an ANCHOR — the newest point — so the
# float32 line is precise exactly where the body is, which is where the camera
# is looking whenever precision could matter. The node sits at the anchor
# minus the camera origin, which is all that changes on a frame when nothing
# was pushed.
#
# The look is the web build's: a vertex-colour gradient from black at the
# oldest slot to the body's colour at the newest, ADDITIVE, at the body's
# opacity. The gradient is fixed to buffer SLOTS, not to age, so a trail that
# has not filled yet only uses the dim end of it — as three drew it with a
# draw range over a fixed colour attribute.
# ============================================================================

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;
#include "res://shaders/common/temp_pass.gdshaderinc"
uniform float u_opacity = 0.5;
void fragment() {
	// LineBasicMaterial + AdditiveBlending: c = rgb·opacity + dst, and the web
	// build's alpha channel took opacity² + dst (see PORT_GUIDE.md §6).
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(u_opacity, 0.0, 0.0);
	} else {
		ALBEDO = COLOR.rgb;
	}
	ALPHA = u_opacity;
}
"""
static var _shader: Shader

var node := MeshInstance3D.new()
var mesh := ArrayMesh.new()
var dirty := false
var max_n: int
var colors := PackedColorArray()
var _anchor := DVec3.new()

func _init(p_max: int, color: Color, opacity: float) -> void:
	max_n = p_max
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("u_opacity", opacity)
	node.mesh = mesh
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# its extent changes every frame; culling it would need a fresh AABB each time
	node.extra_cull_margin = 1.0e7
	colors.resize(max_n)
	for i in max_n:
		var k := float(i) / float(max_n - 1)
		colors[i] = Color(color.r * k, color.g * k, color.b * k, 1.0)

func update(b: Body, cam_pos: DVec3) -> void:
	if dirty:
		dirty = false
		mesh.clear_surfaces()
		var n := b.trail_count
		if n >= 2:
			var M := max_n
			var buf := b.trail_buf
			var newest := (b.trail_head - 1 + M) % M
			_anchor.set_v(buf[newest * 3], buf[newest * 3 + 1], buf[newest * 3 + 2])
			var oldest := (b.trail_head - n + M) % M
			var verts := PackedVector3Array(); verts.resize(n)
			var cols := PackedColorArray(); cols.resize(n)
			for i in n:
				var s := (oldest + i) % M
				verts[i] = Vector3(buf[s * 3] - _anchor.x, buf[s * 3 + 1] - _anchor.y, buf[s * 3 + 2] - _anchor.z)
				cols[i] = colors[i]
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = verts
			arr[Mesh.ARRAY_COLOR] = cols
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arr)
	node.position = _anchor.rel_v3(cam_pos)
