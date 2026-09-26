class_name SpacetimeMesh
extends RefCounted

# ============================================================================
# SPACETIME MESH (wells from holes + bodies) — from blackhole_sim.js, where it
# lived in the orchestrator: a 120-unit sheet, 110 × 110 cells, hung 6 units
# below the focus, that sags under every body. Holes dig a broad funnel
# (2.4 r_s / (0.5 + 0.14 d)); everything else a shallow dimple scaled by mass
# and drawn size, capped at 6 so a star does not punch through the floor.
#
# THE WIREFRAME. THREE drew this with `wireframe: true`, which renders a
# triangle mesh as gl.LINES over an index it builds itself: for EVERY
# triangle (a, b, c) of the PlaneGeometry it emits a–b, b–c, c–a. So every
# cell shows its diagonal, and every interior edge is drawn TWICE — once for
# each triangle that owns it — which, at a blended alpha of ~0.3, is part of
# the look (1 − 0.7² = 0.51 where two coincide). Godot has no wireframe flag
# for a ShaderMaterial, so the same index is built here as PRIMITIVE_LINES,
# duplicates included, over THREE's own PlaneGeometry vertex and triangle
# order (rotated −90° about X into the XZ plane).
#
# THE RECENTRING. The slab follows the camera's focus (the orbit target, or
# the camera itself in free flight) so fast or distant bodies never wander off
# it; the wells are stored relative to that centre — in double precision here,
# then truncated, which is the floating-origin rule (PORT_GUIDE.md §3).
# ============================================================================

const MESH_SIZE := 120.0
const MESH_SEG := 110
const SHADER := preload("res://shaders/bodies/mesh_spacetime.gdshader")

var node: MeshInstance3D
var mat: ShaderMaterial
var time := 0.0
## The slab's absolute scene position (the web's spacetimeMesh.position).
var origin := DVec3.new(0.0, -6.0, 0.0)

static func build_wireframe(size: float = MESH_SIZE, seg: int = MESH_SEG) -> ArrayMesh:
	var g1 := seg + 1
	var seg_w := size / seg
	var half := size / 2.0
	var verts := PackedVector3Array()
	verts.resize(g1 * g1)
	# PlaneGeometry: iy rows top to bottom (y = half − iy·s), ix left to right;
	# then rotateX(−π/2) takes (x, y, 0) to (x, 0, −y).
	for iy in g1:
		var y := iy * seg_w - half
		for ix in g1:
			var x := ix * seg_w - half
			verts[iy * g1 + ix] = Vector3(x, 0.0, y)   # −(half − iy·s) = iy·s − half
	var idx := PackedInt32Array()
	idx.resize(seg * seg * 12)
	var k := 0
	for iy in seg:
		for ix in seg:
			var a := ix + g1 * iy
			var b := ix + g1 * (iy + 1)
			var c := (ix + 1) + g1 * (iy + 1)
			var d := (ix + 1) + g1 * iy
			# triangles (a, b, d) and (b, c, d); each as three edges
			for tri in [[a, b, d], [b, c, d]]:
				idx[k] = tri[0]; idx[k + 1] = tri[1]
				idx[k + 2] = tri[1]; idx[k + 3] = tri[2]
				idx[k + 4] = tri[2]; idx[k + 5] = tri[0]
				k += 6
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	# the wells pull vertices down by up to ~50 units; give the culler room
	m.custom_aabb = AABB(Vector3(-half, -200.0, -half), Vector3(size, 210.0, size))
	return m

func _init() -> void:
	mat = ShaderMaterial.new()
	mat.shader = SHADER
	var w := PackedVector4Array(); w.resize(16)
	mat.set_shader_parameter("wells", w)
	mat.set_shader_parameter("wellCount", 0)
	node = MeshInstance3D.new()
	node.name = "SpacetimeMesh"
	node.mesh = build_wireframe()
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Once per frame, after the camera is final. `mcx`, `mcz`: the slab centre —
## the orbit target's x/z, or the camera's own in free flight (the web's
## `state.camMode === 'free' ? camera.position : cam.target`). `sim_stepped`
## is the years integrated this frame. Places the node itself.
func update(bodies: Array, mcx: float, mcz: float, sim_stepped: float, cam_pos: DVec3) -> void:
	origin.set_v(mcx, -6.0, mcz)
	node.position = origin.rel_v3(cam_pos)
	var wells := PackedVector4Array(); wells.resize(16)
	var wc := 0
	for b in bodies:
		if wc >= 16: break
		var p: DVec3 = b.scene_pos
		if b.type == "bh":
			wells[wc] = Vector4(p.x - mcx, p.z - mcz, b.rs_scene, 1.0)
		else:
			wells[wc] = Vector4(p.x - mcx, p.z - mcz, minf(b.mass + b.radius_scene, 6.0), 0.0)
		wc += 1
	mat.set_shader_parameter("wells", wells)
	mat.set_shader_parameter("wellCount", wc)
	time += sim_stepped
	mat.set_shader_parameter("time", time)
