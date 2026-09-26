class_name Prominence
extends RefCounted

# ============================================================================
# PROMINENCES, FILAMENTS AND THE POST-FLARE ARCADE
# ----------------------------------------------------------------------------
# What used to stand over an erupting active region here was a single tube
# swept along one cubic Bezier: a smooth semicircular arch of uniform
# thickness and uniform colour. Nothing about a real eruption is like that,
# and the differences are not stylistic:
#
#   · PLASMA IS TIED TO FIELD LINES. Coronal gas has a plasma beta far below
#     one, so it cannot cross the magnetic field — it can only slide along it.
#     What you see is therefore a bundle of THREADS, each one a separate flux
#     tube lit up along its own length, not a single solid body. The threading
#     is the texture, and one tube cannot have it.
#
#   · A FLARE MAKES AN ARCADE, NOT AN ARCH. Reconnection proceeds along a
#     magnetic neutral line and works its way upward, so the loops come in a
#     row — dozens of them, anchored in two parallel ribbons, each rooted a
#     little further along and each taller than the last. That row is the
#     single most recognisable thing in any EUV image of a flare.
#
#   · THE ARCADE IS SHEARED, AND THAT SHEAR IS THE ENERGY. A potential field
#     has its loops square across the neutral line and stores nothing. The
#     free energy that a flare releases is exactly the energy of the shear, so
#     a pre-flare arcade is strongly skewed and a post-flare one has relaxed
#     back toward square. Drawing loops perpendicular to the neutral line is
#     drawing a field with nothing to release.
#
#   · A BIPOLE IS NOT ORIENTED AT RANDOM. Hale's polarity law and JOY'S LAW:
#     active regions are bipolar, aligned very nearly east-west, with a tilt
#     that grows with latitude — roughly half the latitude, leading polarity
#     equatorward. So the neutral line runs nearly north-south, tipped a
#     little, and every arcade on a given star leans the same way in a given
#     hemisphere. See create_arcade's caller in sim/star_visual.gd.
#
#   · ON THE DISC IT IS DARK. The same cool, dense material that glows as a
#     bright PROMINENCE off the limb is seen in absorption against the
#     photosphere behind it, where it is called a FILAMENT — it is the same
#     object, and which one you are looking at depends only on where it is.
#     That is why this file draws the arcade twice, once in emission and once
#     in absorption, each discarding where the other applies.
#
#   · THE FOOTPOINTS ARE THE BRIGHT PART. Particles accelerated at the
#     reconnection site stream down the legs and dump their energy where the
#     density rises, so a flaring loop is brightest at its feet and thin and
#     tenuous at its apex, and material condenses and drains back down the
#     legs afterwards as coronal rain.
#
# Geometry is generated in the VERTEX SHADER from a parametric field line, so
# the whole arcade can rise, stretch, shear and untwist over the course of an
# eruption without a single buffer being rewritten. The shader code is in
# shaders/bodies/prom_arcade.gdshaderinc (shared), prom_emit.gdshader and
# prom_absorb.gdshader (the two passes).
# ============================================================================

const THREADS := 22     # flux tubes across the arcade
const SEGS := 44        # samples along each

const EMIT_SHADER := preload("res://shaders/bodies/prom_emit.gdshader")
const ABSORB_SHADER := preload("res://shaders/bodies/prom_absorb.gdshader")

# aThread: -1..1 across the arcade   aS: 0..1 along the loop
# aSide:   -1/+1 ribbon edge         aSeed: per-thread randomiser
# (packed as CUSTOM0 = (aThread, aS, aSide, aSeed), RGBA float).
#
# ONE buffer, shared by every arcade on every star in the scene. It carries no
# shape at all — the shape is entirely in the vertex shader, and two arcades
# differ only by their uniforms — so allocating a copy per flare slot per star
# would be megabytes of identical parameter values. It is never disposed for
# the same reason: it outlives any one star. (A static var holds the one
# reference for the life of the process.)
static var _geo: ArrayMesh = null

## The mesh's own AABB is degenerate — every VERTEX is zero, because the
## shader, not the buffer, has the shape. The web build set frustumCulled =
## false; the Godot equivalent is an AABB nothing can fall outside of.
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

## One arcade: a group carrying the same geometry twice, once in emission and
## once in absorption. Place and orient the group so +Y is the local vertical
## and +Z the bipole axis, then drive it with set_params() (the web's set()).
## `cool` / `hot` are LINEAR colours.
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
