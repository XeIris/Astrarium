class_name Bodies
extends RefCounted

# ============================================================================
# BODY VISUALS — each factory builds a Node3D group and an object with an
# `update(dt, ctx)` method, stored on b.viz. ctx is PORT_GUIDE.md §7's
# (holes, camera, cam_pos, time, scene_scale, sim_dt, suns, …).
# Rendered radii are in SCENE units (visually exaggerated); physical radii in
# AU live on the body for collisions/physics.
#
# PORT NOTES.
#   · The web chained each viz's update() through a closure to add the
#     accretion stream. Here my own visual classes (StarViz, NeutronViz,
#     LegacyStarViz) carry a `stream` member and call accrete() at the end of
#     their update(); the planet visuals — sim/rocky_visual.gd,
#     sim/giant_visual.gd, sim/world.gd, ported in parallel — are wrapped in an
#     AccretionWrap that forwards every property read and write to them.
#   · Those three files are loaded by path, not by class_name, so this file
#     parses whether or not they exist yet; a missing one falls back to a plain
#     sphere (PlainViz) rather than failing.
#   · The orchestrator owns group.position (the floating origin) and
#     group.scale. accrete() is the one exception, as it was in the web: a body
#     being stripped by a hole shrinks its whole group, relative to the
#     group's meta "base_scale" (the web's userData.baseScale), which the
#     orchestrator must set when it attaches the visual.
# ============================================================================

const ACCRETION_SHADER := preload("res://shaders/bodies/accretion_points.gdshader")
const BASIC_SHADER := preload("res://shaders/bodies/star_basic.gdshader")
const BASIC_LAYER_SHADER := preload("res://shaders/bodies/star_basic_layer.gdshader")

# Radial-gradient sprite (corona / glow / flare): `stops` as the web wrote them,
# [[position, 'aa'], …] with alpha as a two-digit hex string (or a float), all
# in the one colour. Canvas pixels are never colour-managed, so the colour is
# RAW. Returns the sprite node; its scale is its size and its material's
# uOpacity is SpriteMaterial.opacity.
static func glow_sprite(color_hex: int, stops = null) -> MeshInstance3D:
	var st: Array = stops if stops != null else [[0.0, "ff"], [0.4, "66"], [1.0, "00"]]
	var out := []
	for s in st:
		var a: float = (("0x" + str(s[1])).hex_to_int() / 255.0) if s[1] is String else float(s[1])
		out.append([float(s[0]), U.raw(color_hex, a)])
	return Flash.make_sprite(out)

static func _sprite_opacity(sp: MeshInstance3D, o: float) -> void:
	(sp.material_override as ShaderMaterial).set_shader_parameter("uOpacity", o)

static func _col(c, fallback: int) -> Color:
	if c is Color: return c
	if c == null: return U.lin(fallback)
	return U.lin(int(c))

# ---------------------------------------------------------------------------
# LEGACY STAR ('star-basic'): granulation fBm + limb darkening + flicker, a
# gassy outer layer, a glow-sprite corona and four flame sprites that wax and
# wane. Kept for the type; the high-fidelity star is sim/star_visual.gd.
# ---------------------------------------------------------------------------
class LegacyStarViz:
	extends RefCounted
	var body: Body
	var group: Node3D
	var core: MeshInstance3D
	var mat: ShaderMaterial
	var layer: MeshInstance3D
	var layer_mat: ShaderMaterial
	var corona: MeshInstance3D
	var flares: Array = []          # [{node, phase, a}]
	var stream = null
	var base_r: float
	var r: float
	var color_hex: int
	var is_star := false
	var is_hole := false
	var is_neutron := false
	var time := 0.0
	var layer_time := 0.0

	func _init(b: Body, opts: Dictionary) -> void:
		body = b
		group = Node3D.new()
		var R: float = opts.radiusScene
		var col := Bodies._col(opts.get("color"), 0xffe0a0)
		mat = ShaderMaterial.new()
		mat.shader = Bodies.BASIC_SHADER
		mat.set_shader_parameter("uColor", Vector3(col.r, col.g, col.b))
		core = MeshInstance3D.new()
		var s := SphereMesh.new(); s.radius = R; s.height = 2.0 * R; s.radial_segments = 48; s.rings = 48
		core.mesh = s
		core.material_override = mat
		group.add_child(core)

		# gassy outer layer — slightly larger, additive
		layer_mat = ShaderMaterial.new()
		layer_mat.shader = Bodies.BASIC_LAYER_SHADER
		layer_mat.set_shader_parameter("uColor", Vector3(col.r, col.g, col.b))
		layer = MeshInstance3D.new()
		var s2 := SphereMesh.new(); s2.radius = R * 1.08; s2.height = 2.16 * R; s2.radial_segments = 32; s2.rings = 32
		layer.mesh = s2
		layer.material_override = layer_mat
		group.add_child(layer)

		var glow: int = int(U.nz(opts.get("glow"), 0xff8040))
		corona = Bodies.glow_sprite(glow, [[0.0, "88"], [0.3, "40"], [1.0, "00"]])
		corona.scale = Vector3.ONE * (R * 6.0)
		group.add_child(corona)

		# prominences / flares: a few flame sprites that wax & wane
		for i in 4:
			var f := Bodies.glow_sprite(glow, [[0.0, "cc"], [0.5, "30"], [1.0, "00"]])
			var a := randf() * TAU
			f.position = Vector3(cos(a) * R, sin(a) * R * 0.6, (randf() - 0.5) * R)
			f.scale = Vector3.ONE * (R * 1.5)
			group.add_child(f)
			flares.append({"node": f, "phase": randf() * 6.28, "a": a})

		base_r = R
		r = R
		color_hex = U.hex_of(col)

	func update(dt: float, ctx: Dictionary) -> void:
		var t: float = float(ctx.get("time", 0.0))
		time += dt
		layer_time += dt * 0.6
		mat.set_shader_parameter("uTime", time)
		layer_mat.set_shader_parameter("uTime", layer_time)
		# slow swelling pulsation (stellar variability)
		var pulse := 1.0 + sin(t * 0.6 + body.id) * 0.04
		core.scale = Vector3.ONE * pulse
		layer.scale = Vector3.ONE * pulse
		# (the web's uPulse lives on the core's material only; the layer's own
		# copy of the uniform block was cloned once and never driven)
		mat.set_shader_parameter("uPulse", 0.9 + sin(t * 4.0 + body.id) * 0.04)
		Bodies._sprite_opacity(corona, 0.8 + sin(t * 1.3 + body.id) * 0.15)
		for f in flares:
			var e := 0.4 + 0.6 * pow(maxf(0.0, sin(t * 1.1 + f.phase)), 3.0)
			Bodies._sprite_opacity(f.node, e)
			(f.node as Node3D).scale = Vector3.ONE * (r * (1.0 + e * 1.2))
		if stream != null:
			Bodies.accrete(body, ctx, stream, dt)

static func create_star(b: Body, opts: Dictionary) -> LegacyStarViz:
	var viz := LegacyStarViz.new(b, opts)
	viz.stream = AccretionStream.new(int(U.nz(opts.get("glow"), 0xff8040)))
	viz.group.add_child(viz.stream.points)
	b.viz = viz
	return viz

# ---------------------------------------------------------------------------
# NEUTRON STAR — see sim/neutron_visual.gd. Like the star, it still has to be
# edible by a black hole, so it gets the same accretion stream chained on.
# ---------------------------------------------------------------------------
static func create_neutron(b: Body, opts: Dictionary):
	var viz = NeutronVisual.create_neutron_visual(b, opts)
	viz.stream = AccretionStream.new(0x8fc4ff)
	viz.group.add_child(viz.stream.points)
	return viz

# ---------------------------------------------------------------------------
# PLANETS. Both kinds are full shader models now — sim/rocky_visual.gd and
# sim/giant_visual.gd — and the only thing this file adds is the accretion
# stream, because a planet still has to be edible by a black hole.
#
# What used to be here was a CanvasTexture: fBm run through a colour ramp and
# wrapped round a sphere. It had to go for two reasons beyond looking painted.
# A texture has a seam and a polar pinch; and, more to the point, nothing in it
# was a consequence of anything — the same wallpaper was drawn at 0.4 AU and at
# 40 AU, so a planet's appearance said nothing whatever about the planet.
# ---------------------------------------------------------------------------
static func with_accretion(viz, b: Body, color_hex) -> AccretionWrap:
	var w := AccretionWrap.new(viz, b, AccretionStream.new(color_hex if color_hex != null else 0x886644))
	b.viz = w
	return w

static func _load_visual(path: String):
	if not ResourceLoader.exists(path):
		return null
	return load(path)

static func create_rocky(b: Body, opts: Dictionary):
	var S = _load_visual("res://sim/rocky_visual.gd")
	var viz = S.create_rocky_visual(b, opts) if S != null else PlainViz.new(b, opts)
	return with_accretion(viz, b, opts.get("glow"))

static func create_giant(b: Body, opts: Dictionary):
	var S = _load_visual("res://sim/giant_visual.gd")
	if S == null:
		return with_accretion(PlainViz.new(b, opts), b, opts.get("glow"))
	var pals: Dictionary = S.GIANT_PALETTES
	var pal = pals.get(opts.get("paletteName"), pals.get("jupiter"))
	return with_accretion(S.create_giant_visual(b, U.merged(opts, {"giantPalette": pal})), b, opts.get("glow"))

static func create_world(b: Body, opts: Dictionary):
	var S = _load_visual("res://sim/world.gd")
	if S == null:
		var v := PlainViz.new(b, opts)
		b.viz = v
		return v
	return S.create_world_visual(b, opts)

## A plain sphere in the body's colour: the stand-in for a planet visual whose
## port is not in this checkout.
class PlainViz:
	extends RefCounted
	var group: Node3D
	var core: MeshInstance3D
	var base_r: float
	var r: float
	var is_star := false
	var is_hole := false
	var is_neutron := false
	func _init(_b: Body, opts: Dictionary) -> void:
		group = Node3D.new()
		var R: float = opts.radiusScene
		var m := StandardMaterial3D.new()
		m.albedo_color = Bodies._col(opts.get("color"), 0x6a90c0)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		core = MeshInstance3D.new()
		var s := SphereMesh.new(); s.radius = R; s.height = 2.0 * R
		core.mesh = s
		core.material_override = m
		group.add_child(core)
		base_r = R
		r = R
	func update(_dt: float, _ctx: Dictionary) -> void:
		pass

## The web's `withAccretion`: the planet's own viz, with an accretion stream
## chained after its update(). Every property the orchestrator reads or writes
## on b.viz (group, core, mat, r, …) is forwarded to the wrapped object;
## `inner` is the object itself, for method calls beyond update().
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
	func update(dt: float, ctx: Dictionary) -> void:
		inner.update(dt, ctx)
		Bodies.accrete(body, ctx, stream, dt)
	func _get(property: StringName):
		return inner.get(property) if inner != null else null
	func _set(property: StringName, value) -> bool:
		if inner == null: return false
		inner.set(property, value)
		return true

# ---------------------------------------------------------------------------
# BLACK HOLE — an empty transform, deliberately.
# ----------------------------------------------------------------------------
# There used to be a black sphere here, sized to r_s and drawn over the lensed
# image. It was wrong twice over. A black hole has no surface to draw: inside
# the horizon there is a singularity, and the horizon itself is a one-way
# boundary, not an object. And the dark region you actually see is not the
# horizon at all — it is the shadow cast by the photon sphere, with an
# apparent radius of (√27/2)·r_s ≈ 2.6 r_s, so a sphere at r_s was 2.6× too
# small and covered up the very light (the photon ring, the lensed underside
# of the disc) that makes a black hole recognisable.
#
# The ray marcher in render/lens_pass.gd already renders the shadow correctly,
# by the only honest method: rays that cross the horizon return nothing. So
# this group carries no geometry at all — just the position that physics, the
# camera and the picker read.
# ---------------------------------------------------------------------------
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
	func update(_dt: float, _ctx: Dictionary) -> void:
		pass

static func create_black_hole(b: Body, _opts: Dictionary) -> HoleViz:
	var viz := HoleViz.new()
	b.viz = viz
	return viz

# ---------------------------------------------------------------------------
# ACCRETION STREAM — a GPU point pool. When a body is inside a hole's tidal
# radius it sheds particles that spiral toward the hole, and visibly loses
# mass (mass + rendered radius shrink).
#
# The pool is rebuilt into its ArrayMesh each frame it has anything alive, and
# hidden (and not rebuilt) while it is empty — which is every body, every
# frame, in a scene with no hole in it.
# ---------------------------------------------------------------------------
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

	## `color`: an sRGB hex (converted, as THREE.Color(hex) was) or a linear Color.
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

	# emit a particle in the group's LOCAL space heading toward toward_local
	func emit(origin_local: Vector3, toward_local: Vector3) -> void:
		var i := head
		head = (head + 1) % max_n
		pos_arr[i] = origin_local
		var spread := 0.3
		vel_arr[i] = toward_local + Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * spread
		life_arr[i] = 1.0

	func step(dt: float) -> void:
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

static func accrete(b: Body, ctx: Dictionary, stream: AccretionStream, dt: float) -> void:
	stream.step(dt)
	var holes: Array = ctx.get("holes", [])
	var viz = b.viz
	if holes.is_empty() or viz == null or viz.get("is_hole"): return
	var group: Node3D = viz.get("group")
	var xf := group.global_transform if group.is_inside_tree() else group.transform
	var wpos := xf.origin
	var nearest = null
	var nd := INF
	for h in holes:
		var d := (h.pos_rel as Vector3).distance_to(wpos)
		if d < nd: nd = d; nearest = h
	if nearest == null: return
	var R: float = float(U.nz(viz.get("r"), b.radius_scene))
	var rs_scene: float = nearest.rs_scene
	# tidal (Roche-ish) reach ~ a few times the rendered horizon
	var reach := rs_scene * 14.0 + R * 3.0
	if nd > reach: return
	var strength := clampf(1.0 - (nd - rs_scene * 2.0) / reach, 0.0, 1.0)
	# local-space direction toward hole
	var hole_local: Vector3 = xf.affine_inverse() * (nearest.pos_rel as Vector3)
	var dir := hole_local.normalized() * (R * (4.0 + 6.0 * strength))
	var emit_n := (1 + int(floor(strength * 2.0))) if randf() < strength * 0.9 else 0
	var core = viz.get("core")
	var core_s: float = (core as Node3D).scale.x if core is Node3D else 1.0
	for k in emit_n:
		stream.emit(U.random_dir() * (R * core_s), dir)
	# visible mass loss + accretion drag → a slow inward death-spiral
	if strength > 0.03:
		if b.mass > 0.02:
			var loss := b.mass * strength * dt * 0.18
			b.mass = maxf(0.01, b.mass - loss)
			var m0 := b.mass0 if b.mass0 != 0.0 else b.mass
			var shrink := maxf(0.18, pow(b.mass / m0, 0.33))
			group.scale = Vector3.ONE * (shrink * float(group.get_meta("base_scale", 1.0)))
		# bleed a little orbital energy so it gradually descends rather than orbiting forever
		if b.vel != null: b.vel.scale_in(1.0 - strength * dt * 0.06)

# ---------------------------------------------------------------------------
# The high-fidelity star still has to be able to be eaten by a black hole, so
# give it the same accretion stream the legacy star had and chain the updates.
static func create_star_hifi(b: Body, opts: Dictionary):
	var viz = StarVisual.create_star_visual(b, opts)
	viz.stream = AccretionStream.new(viz.hot)
	viz.group.add_child(viz.stream.points)
	return viz

## Dispatch per body type. Sets b.viz and returns it. `opts` is the dictionary
## attachVisual builds (keys verbatim from the web: radiusScene, oblate,
## spinFrac, tPole, tEq, gdBeta, radiusSun, color, teff, glow, seed, …).
static func create_body_visual(b: Body, opts: Dictionary):
	match b.type:
		"bh": return create_black_hole(b, opts)
		"star": return create_star_hifi(b, opts)
		# A white dwarf is a photosphere like any other — a very small, very hot
		# one. What it does NOT have is a convective envelope, so it has no dynamo,
		# no starspots and no flares: `quiet` turns the activity model off rather
		# than letting a degenerate star erupt.
		"white-dwarf": return create_star_hifi(b, U.merged(opts, {"quiet": true}))
		"star-basic": return create_star(b, opts)
		"world": return create_world(b, opts)
		"neutron": return create_neutron(b, opts)
		"gas-giant": return create_giant(b, opts)
		_: return create_rocky(b, opts)   # rocky
