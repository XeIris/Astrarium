class_name Prominence
extends RefCounted

# Parametric field-line threads deform in the vertex shader.
# Emission off the limb and absorption on the disc require separate draws.
# See shaders/AGENTS.md for the shared geometry and temperature contract.

const THREADS := 22     # flux tubes across the arcade
const SEGS := 44        # samples along each

const EMIT_SHADER := preload("res://shaders/bodies/prom_emit.gdshader")
const ABSORB_SHADER := preload("res://shaders/bodies/prom_absorb.gdshader")

# aThread: -1..1 across the arcade   aS: 0..1 along the loop
# aSide:   -1/+1 ribbon edge         aSeed: per-thread randomiser
# (packed as CUSTOM0 = (aThread, aS, aSide, aSeed), RGBA float).
# One buffer carries no shape, so it serves every arcade on every star, and is
# never freed (a static var holds it).
static var _geo: ArrayMesh = null

## Every vertex is zero (the shader has the shape), so use an AABB nothing falls
## outside of.
const NO_CULL_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

static func arcade_geometry() -> ArrayMesh:
	if _geo != null:
		return _geo
	var verts := THREADS * (SEGS + 1) * 2
	var custom := PackedFloat32Array()
	custom.resize(verts * 4)
	var pos := PackedVector3Array()        # unused; the shader builds it
	pos.resize(verts)
	var index := PackedInt32Array()
	var v := 0
	for t in THREADS:
		var k := 0.0 if THREADS == 1 else (float(t) / float(THREADS - 1)) * 2.0 - 1.0
		var seed := t * 0.6180339887
		var base := v
		for s in SEGS + 1:
			for side in 2:
				custom[v * 4 + 0] = k
				custom[v * 4 + 1] = float(s) / float(SEGS)
				custom[v * 4 + 2] = side * 2.0 - 1.0
				custom[v * 4 + 3] = seed
				v += 1
		for s in SEGS:
			var a := base + s * 2
			index.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = index
	var geo := ArrayMesh.new()
	geo.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	geo.custom_aabb = NO_CULL_AABB
	_geo = geo
	return geo

static func _arcade_material(cool: Color, hot: Color, mode: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	# mode 0: emission (additive colour, temperature replaced);
	# mode 1: absorption (over-composited colour, temperature untouched).
	m.shader = EMIT_SHADER if mode == 0 else ABSORB_SHADER
	m.set_shader_parameter("uMode", float(mode))
	m.set_shader_parameter("uCool", Vector3(cool.r, cool.g, cool.b))
	m.set_shader_parameter("uHot", Vector3(hot.r, hot.g, hot.b))
	return m

## One arcade: the same geometry twice, emission and absorption. Orient the group
## with +Y the local vertical and +Z the bipole axis, then drive it with
## set_params(). `cool` / `hot` are linear colours.
static func create_arcade(cool: Color, hot: Color) -> Arcade:
	return Arcade.new(cool, hot)

class Arcade:
	extends RefCounted
	var group: Node3D
	var geo: ArrayMesh
	var emit_mat: ShaderMaterial
	var abs_mat: ShaderMaterial
	## uTime, accumulated here rather than read back from the material.
	var time := 0.0

	func _init(cool: Color, hot: Color) -> void:
		geo = Prominence.arcade_geometry()
		emit_mat = Prominence._arcade_material(cool, hot, 0)
		abs_mat = Prominence._arcade_material(cool, hot, 1)
		group = Node3D.new()
		for mat in [emit_mat, abs_mat]:
			var mesh := MeshInstance3D.new()
			mesh.mesh = geo
			mesh.material_override = mat
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# the shader, not the buffer, has the shape
			mesh.custom_aabb = Prominence.NO_CULL_AABB
			group.add_child(mesh)
		group.visible = false

	## p = { R, span, len, height, shear, twist, erupt, width, amp, plasmaT, dt }
	func set_params(p: Dictionary) -> void:
		time += float(p.dt)
		for m in [emit_mat, abs_mat]:
			m.set_shader_parameter("uR", p.R)
			m.set_shader_parameter("uSpan", p.span)
			m.set_shader_parameter("uLen", p.len)
			m.set_shader_parameter("uHeight", p.height)
			m.set_shader_parameter("uShear", p.shear)
			m.set_shader_parameter("uTwist", p.twist)
			m.set_shader_parameter("uErupt", p.erupt)
			m.set_shader_parameter("uWidth", p.width)
			m.set_shader_parameter("uAmp", p.amp)
			m.set_shader_parameter("uPlasmaT", p.plasmaT)
			m.set_shader_parameter("uTime", time)

	## the geometry is shared and outlives this arcade; only the nodes go
	func dispose() -> void:
		if is_instance_valid(group):
			group.queue_free()
