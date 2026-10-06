class_name Bodies
extends RefCounted

# Factories return b.viz with update(dt, ctx); see docs/godot.md for ownership.
# Rendered radii use scene units; body physics uses AU.

const ACCRETION_SHADER := preload("res://shaders/bodies/accretion_points.gdshader")

static func _col(c, fallback: int) -> Color:
	if c is Color: return c
	if c == null: return U.lin(fallback)
	return U.lin(int(c))

static func create_neutron(b: Body, opts: VisualOpts):
	var viz = NeutronVisual.create_neutron_visual(b, opts)
	viz.stream = AccretionStream.new(0x8fc4ff)
	viz.group.add_child(viz.stream.points)
	return viz

static func with_accretion(viz, b: Body, color_hex) -> AccretionWrap:
	var w := AccretionWrap.new(viz, b, AccretionStream.new(color_hex if color_hex != null else 0x886644))
	b.viz = w
	return w

static func _load_visual(path: String):
	if not ResourceLoader.exists(path):
		return null
	return load(path)

static func create_rocky(b: Body, opts: VisualOpts):
	var S = _load_visual("res://sim/rocky_visual.gd")
	var viz = S.create_rocky_visual(b, opts) if S != null else PlainViz.new(b, opts)
	return with_accretion(viz, b, opts.glow)

static func create_giant(b: Body, opts: VisualOpts):
	var S = _load_visual("res://sim/giant_visual.gd")
	if S == null:
		return with_accretion(PlainViz.new(b, opts), b, opts.glow)
	var pals: Dictionary = S.GIANT_PALETTES
	var pal = pals.get(opts.palette_name, pals.get("jupiter"))
	var o := opts.copy()
	o.giant_palette = pal
	return with_accretion(S.create_giant_visual(b, o), b, opts.glow)

static func create_world(b: Body, opts: VisualOpts):
	var S = _load_visual("res://sim/world.gd")
	if S == null:
		var v := PlainViz.new(b, opts)
		b.viz = v
		return v
	return S.create_world_visual(b, opts)

## A plain sphere when an optional planet visual is unavailable.
class PlainViz:
	extends RefCounted
	var group: Node3D
	var core: MeshInstance3D
	var base_r: float
	var r: float
	var is_star := false
	var is_hole := false
	var is_neutron := false
	func _init(_b: Body, opts: VisualOpts) -> void:
		group = Node3D.new()
		var R: float = opts.radius_scene
		var m := StandardMaterial3D.new()
		m.albedo_color = Bodies._col(opts.color, 0x6a90c0)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		core = MeshInstance3D.new()
		var s := SphereMesh.new(); s.radius = R; s.height = 2.0 * R
		core.mesh = s
		core.material_override = m
		group.add_child(core)
		base_r = R
		r = R
	func update(_dt: float, _ctx: VisualCtx) -> void:
		pass

## A planet viz with an accretion stream after its update(). Every property the
## orchestrator touches on b.viz is forwarded; `inner` is the wrapped object.
class AccretionWrap:
	extends RefCounted
	var inner
	var body: Body
	var stream: AccretionStream
	func _init(p_inner, b: Body, s: AccretionStream) -> void:
		inner = p_inner
		body = b
		stream = s
		var g: Node3D = inner.get("group")
		if g != null:
			g.add_child(stream.points)
	func update(dt: float, ctx: VisualCtx) -> void:
		inner.update(dt, ctx)
		Bodies.update_accretion_stream(body, ctx, stream, dt)
	func _get(property: StringName):
		return inner.get(property) if inner != null else null
	func _set(property: StringName, value) -> bool:
		if inner == null: return false
		inner.set(property, value)
		return true

# BLACK HOLE: an empty transform. There is no surface to draw, and the visible
# shadow is the photon sphere's at (√27/2)·r_s ≈ 2.6 r_s; lens_pass.gd renders it by
# returning nothing for rays that cross the horizon. This carries only the position
# physics, camera and picker read.
class HoleViz:
	extends RefCounted
	var group := Node3D.new()
	var core = null
	var base_r := 1.0
	var r := 1.0
	var is_hole := true
	var is_star := false
	var is_neutron := false
	var stream = null
	func update(_dt: float, _ctx: VisualCtx) -> void:
		pass

static func create_black_hole(b: Body, _opts: VisualOpts) -> HoleViz:
	var viz := HoleViz.new()
	b.viz = viz
	return viz

# Cosmetic gas stream in local scene units; it does not transfer physical mass.
class AccretionStream:
	extends RefCounted
	var max_n := 240
	var head := 0
	var pos_arr := PackedVector3Array()
	var vel_arr := PackedVector3Array()
	var life_arr := PackedFloat32Array()
	var alpha_arr := PackedFloat32Array()
	var points: MeshInstance3D
	var mesh: ArrayMesh
	var mat: ShaderMaterial
	var _live := false

	## `color`: an sRGB hex (converted) or a linear Color.
	func _init(color) -> void:
		pos_arr.resize(max_n); vel_arr.resize(max_n); life_arr.resize(max_n); alpha_arr.resize(max_n)
		var c: Color = color if color is Color else U.lin(int(color))
		mat = ShaderMaterial.new()
		mat.shader = Bodies.ACCRETION_SHADER
		mat.set_shader_parameter("uColor", Vector3(c.r, c.g, c.b))
		mat.set_shader_parameter("uSize", 60.0)
		mesh = ArrayMesh.new()
		points = MeshInstance3D.new()
		points.name = "AccretionStream"
		points.mesh = mesh
		points.material_override = mat
		points.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		points.custom_aabb = AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))
		points.visible = false

	## Positions and velocities are local scene units and scene units per render second.
	func emit(origin_local: Vector3, toward_local: Vector3) -> void:
		var i := head
		head = (head + 1) % max_n
		pos_arr[i] = origin_local
		var spread := 0.3
		vel_arr[i] = toward_local + Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * spread
		life_arr[i] = 1.0

	func step(dt: float) -> void:
		if dt <= 0.0: return
		var any := false
		for i in max_n:
			if life_arr[i] <= 0.0:
				alpha_arr[i] = 0.0
				continue
			life_arr[i] -= dt * 0.6
			pos_arr[i] += vel_arr[i] * dt
			alpha_arr[i] = maxf(0.0, life_arr[i])
			any = true
		if any or _live:
			_rebuild()
		_live = any
		points.visible = any

	func _rebuild() -> void:
		var custom := PackedFloat32Array()
		custom.resize(max_n * 4)
		for i in max_n:
			custom[i * 4] = alpha_arr[i]
		var arr := []; arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = pos_arr
		arr[Mesh.ARRAY_CUSTOM0] = custom
		mesh.clear_surfaces()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr, [], {},
			Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)

static func update_accretion_stream(b: Body, ctx: VisualCtx, stream: AccretionStream, dt: float) -> void:
	if dt <= 0.0: return
	stream.step(dt)
	var holes: Array = ctx.holes
	var viz = b.viz
	if holes.is_empty() or viz == null or viz.get("is_hole"): return
	var group: Node3D = viz.get("group")
	var xf := group.global_transform if group.is_inside_tree() else group.transform
	var wpos := xf.origin
	var nearest: VisualCtx.Hole = null
	var nd := INF
	for h: VisualCtx.Hole in holes:
		var d := h.pos_rel.distance_to(wpos)
		if d < nd: nd = d; nearest = h
	if nearest == null: return
	var R: float = float(U.nz(viz.get("r"), b.radius_scene))
	var rs_scene: float = nearest.rs_scene
	# Illustrative reach follows visible geometry, not a physical Roche limit.
	var reach := rs_scene * 14.0 + R * 3.0
	if nd > reach: return
	var strength := clampf(1.0 - (nd - rs_scene * 2.0) / reach, 0.0, 1.0)
	var hole_local: Vector3 = xf.affine_inverse() * nearest.pos_rel
	var dir := hole_local.normalized() * (R * (4.0 + 6.0 * strength))
	var emit_n := (1 + int(floor(strength * 2.0))) if randf() < strength * 0.9 else 0
	var core = viz.get("core")
	var core_s: float = (core as Node3D).scale.x if core is Node3D else 1.0
	for k in emit_n:
		stream.emit(U.random_dir() * (R * core_s), dir)

static func create_star_hifi(b: Body, opts: VisualOpts):
	var viz = StarVisual.create_star_visual(b, opts)
	viz.stream = AccretionStream.new(viz.hot)
	viz.group.add_child(viz.stream.points)
	return viz

## Dispatch per body type; sets and returns b.viz.
static func create_body_visual(b: Body, opts: VisualOpts):
	match b.type:
		"bh": return create_black_hole(b, opts)
		"star": return create_star_hifi(b, opts)
		# A white dwarf is a small hot photosphere with no convective envelope: `quiet`
		# turns off spots and flares.
		"white-dwarf":
			var o := opts.copy()
			o.quiet = true
			return create_star_hifi(b, o)
		"world": return create_world(b, opts)
		"neutron": return create_neutron(b, opts)
		"gas-giant": return create_giant(b, opts)
		_: return create_rocky(b, opts)   # rocky
