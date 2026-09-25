class_name Cutaway
extends El

# ============================================================================
# THE 3D CUTAWAY — the interior model, as an object rather than as a chart
# ----------------------------------------------------------------------------
# sim/crosssection.gd already draws a body's interior, and draws it well: exact
# radii, a temperature ramp, a label per layer. What a flat disc cannot do is
# make a beginner believe that the core is a SPHERE — that the iron core is not
# a circle painted on a cut face but a ball with a shell of liquid iron round
# it and a mantle round that. That belief is most of what an interior model is
# for, and it costs one quarter of the geometry to earn.
#
# HOW THE WEDGE IS CUT. Not by building wedge geometry — by clipping. Every
# layer is an ordinary sphere at its own radius, drawn DOUBLE-SIDED, and two
# clipping planes with `clipIntersection = true` remove the one octant-pair
# where both of them would cut. Building the wedge as geometry would need cut
# faces, caps and a seam per layer; clipping needs two planes for the whole
# model and gets the inside surfaces for free, which is the entire point: what
# you see through the notch is the far inner wall of every shell above the one
# you are looking at, which is exactly what a cutaway is. (Godot's
# StandardMaterial3D has no clip planes, so the shell material is
# shaders/ui/cutaway_layer.gdshader: the same Lambert + GGX lighting with the
# two-plane discard added.)
#
# It gets its own tiny renderer rather than sharing the orrery's. On the web
# that was a second WebGLRenderer bound to its own canvas; here it is a
# SubViewport with its OWN World3D, camera and lights, so nothing in it can
# see the orrery or be seen by it, and its texture is drawn into this
# element's content box. The web renderer was three's default — sRGB output,
# NoToneMapping — so the viewport's environment is the linear tonemapper at
# unity: values are clamped at 1 and encoded to sRGB, and nothing else. The
# lights are three's physically based intensities, which Godot scales by π
# internally, hence the /π (sim/flight/modelviewer.gd does the same).
#
# THE RADII ARE REAL, AND THAT IS SOMETIMES THE LESSON. A red giant's
# degenerate helium core is 0.008 of its radius, which is a dot — and it should
# be a dot, because the fact that a third of the star's mass is inside a
# thousandth of its volume is the reason it is a red giant at all.
#
# This node IS the canvas: an El with the canvas's `width: 100%; height:
# auto` over a 320 × 210 bitmap, so the lesson card lays it out as it did the
# <canvas>. The viewport renders at the laid-out size × the display scale
# (capped at 2, as `setPixelRatio(min(devicePixelRatio, 2))` was).
# ============================================================================

const LAYER_SHADER := preload("res://shaders/ui/cutaway_layer.gdshader")
const LAYER_ALPHA_SHADER := preload("res://shaders/ui/cutaway_layer_alpha.gdshader")

var vp: SubViewport
var camera: Camera3D
var root3d: Node3D
var current: Dictionary = {}
var spin := 0.0
var auto_spin := true
var _tex: TextureRect
var _re_shell := RegEx.create_from_string("(?i)sphere|ISCO|Ergosphere")
var _re_wire := RegEx.create_from_string("(?i)sphere|ISCO")

## createCutaway({ canvas }) → here the canvas is the returned node.
## opts.style: extra El style (the lesson card's `.lc-canvas` border and
## background); opts.w / opts.h: the bitmap size whose aspect it keeps.
static func create_cutaway(opts: Dictionary = {}) -> Cutaway:
	return Cutaway.new(opts.get("style", {}), float(opts.get("w", 320.0)), float(opts.get("h", 210.0)))

func _init(style: Dictionary = {}, w := 320.0, h := 210.0) -> void:
	var s := {"aspect": h / w}
	s.merge(style, true)
	super(s)
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.world_3d = World3D.new()
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X            # antialias: true
	vp.size = Vector2i(int(w), int(h))
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp, false, Node.INTERNAL_MODE_BACK)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0
	env.glow_enabled = false
	env.ssao_enabled = false
	env.ssr_enabled = false
	env.sdfgi_enabled = false
	env.fog_enabled = false
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	# AmbientLight(0x93a6c4, 0.55): an ambient colour is sRGB and converted,
	# like three's hex; its diffuse term is albedo × E here and albedo × E / π
	# there, so the energy carries the 1/π.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.hex(0x93a6c4ff)
	env.ambient_light_energy = 0.55 / PI
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	camera = Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_HEIGHT     # fov is vertical, as THREE's is
	camera.fov = 34.0
	camera.near = 0.01
	camera.far = 100.0
	camera.current = true
	var cam_pos := Vector3(2.1, 1.35, 2.3)
	camera.transform = Transform3D(Basis.looking_at(-cam_pos, Vector3.UP), cam_pos)
	vp.add_child(camera)

	_dir_light(0xffffff, 1.5, Vector3(3, 4, 5))
	_dir_light(0x88a8ff, 0.45, Vector3(-4, -1, -2))
	# A light INSIDE the notch, or the whole reason for cutting it is in shadow.
	# PointLight(0xffe3c0, 2.0, distance 8, decay 2): Godot's omni attenuation
	# with range 8 and attenuation 2 is three's physical falloff
	# (1/d² × (1 − (d/8)⁴)²) term for term.
	var inner := OmniLight3D.new()
	inner.light_color = Color.hex(0xffe3c0ff)
	inner.light_energy = 2.0 / PI
	inner.omni_range = 8.0
	inner.omni_attenuation = 2.0
	inner.position = Vector3(0.9, 0.5, 0.9)
	vp.add_child(inner)

	root3d = Node3D.new()
	vp.add_child(root3d)

	_tex = TextureRect.new()
	_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tex.stretch_mode = TextureRect.STRETCH_SCALE
	_tex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_tex.texture = vp.get_texture()
	# the viewport's cleared background is transparent and its antialiased
	# edges are resolved against it, i.e. premultiplied
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	_tex.material = m
	add_child(_tex, false, Node.INTERNAL_MODE_BACK)

func _dir_light(hex: int, intensity: float, pos: Vector3) -> void:
	# DirectionalLight: shines from its position toward the target (origin)
	var l := DirectionalLight3D.new()
	l.light_color = Color.hex((hex << 8) | 0xff)
	l.light_energy = intensity / PI
	l.transform = Transform3D(Basis.looking_at(-pos, Vector3.UP), pos)
	vp.add_child(l)

func clear() -> void:
	for c in root3d.get_children():
		root3d.remove_child(c)
		c.queue_free()

# ---- build from a structure
func show_structure(st: Dictionary) -> void:
	clear()
	current = st
	var layers: Array = st.get("layers", []) if not st.is_empty() else []
	if layers.is_empty():
		return

	# A black hole has no interior. Its "layers" are locations in the
	# spacetime, so they are drawn as wireframe shells over a black ball
	# rather than as material — see draw_cross_section for the same distinction.
	var is_hole: bool = st.get("type") == "bh"

	for i in range(layers.size() - 1, -1, -1):
		var L: Dictionary = layers[i]
		var r := maxf(CrossSection.num(L.get("r1")), 0.004)
		var T := CrossSection.num(L.get("T"))
		var nm := str(L.get("name", ""))
		var col_srgb: Color = HudTheme.hexc(0x06070c) if (is_hole and T == 0.0) else CrossSection.temp_color(T)
		var shell := is_hole and _re_shell.search(nm) != null
		var wire := is_hole and _re_wire.search(nm) != null
		var mat := ShaderMaterial.new()
		mat.shader = LAYER_ALPHA_SHADER if shell else LAYER_SHADER
		mat.set_shader_parameter("albedo", col_srgb)
		# Hot layers carry their own light. A 15-million-kelvin core lit only
		# by a lamp outside the star is the one thing a cutaway must not show.
		var k := 0.55 if T > 1e5 else (0.22 if T > 3000.0 else 0.04)
		var lin := col_srgb.srgb_to_linear()
		mat.set_shader_parameter("emissive", Vector3(lin.r, lin.g, lin.b) * k)
		mat.set_shader_parameter("roughness_v", 0.82)
		if shell:
			mat.set_shader_parameter("opacity", 0.16)
		var mi := MeshInstance3D.new()
		mi.mesh = _wire_sphere(r, mat) if wire else _sphere(r, mat)
		mi.set_meta("layer", L)
		root3d.add_child(mi)

	# Rotational flattening, applied to the whole model rather than layer by
	# layer: the published layer radii are means, and the shape is the body's.
	var f := CrossSection.num(st.get("flattening"))
	if not (f > 0.0): f = 0.0
	root3d.scale = Vector3(1.0, 1.0 - f, 1.0)

## THREE.SphereGeometry(r, 64, 40)
static func _sphere(r: float, mat: Material) -> Mesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = 2.0 * r
	s.radial_segments = 64
	s.rings = 40
	s.material = mat
	return s

## The same sphere drawn `wireframe: true`: every triangle edge as a line.
static func _wire_sphere(r: float, mat: Material) -> Mesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = 2.0 * r
	s.radial_segments = 64
	s.rings = 40
	var a := s.get_mesh_arrays()
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var lines := PackedInt32Array()
	for t in range(0, idx.size(), 3):
		lines.append_array([idx[t], idx[t + 1], idx[t + 1], idx[t + 2], idx[t + 2], idx[t]])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = v
	out[Mesh.ARRAY_NORMAL] = n
	out[Mesh.ARRAY_INDEX] = lines
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, out)
	m.surface_set_material(0, mat)
	return m

func show_spec(spec: Dictionary) -> void:
	show_structure(Structure.structure_of(spec))

func set_spin(on: bool) -> void:
	auto_spin = on

func nudge(d: float) -> void:
	spin += d
	root3d.rotation.y = spin

## render(dt): advance the turntable. The viewport itself redraws every frame.
func render(dt := 1.0 / 60.0) -> void:
	if auto_spin: spin += dt * 0.35
	root3d.rotation.y = spin

func _draw_extra() -> void:
	var r := _snap(Rect2(Vector2(gf("bl"), gf("bt")), size - Vector2(gf("bl") + gf("br"), gf("bt") + gf("bb"))))
	_tex.position = r.position
	_tex.size = r.size
	var dpr := minf(get_window().content_scale_factor if is_inside_tree() else 1.0, 2.0)
	var want := Vector2i(maxi(int(roundf(r.size.x * dpr)), 1), maxi(int(roundf(r.size.y * dpr)), 1))
	if vp.size != want:
		vp.size = want

# The legend is page elements rather than drawn into the render: it has to be
# readable, and a 3D view is not. legend() gives the rows (outermost first,
# as the web's markup did); build_legend() lays them out as `.cut-legend`.
func legend() -> Array:
	var rows: Array = []
	var layers: Array = current.get("layers", []) if not current.is_empty() else []
	var R := CrossSection.num(current.get("radiusAU"))
	if not (R > 0.0): R = 0.0
	for i in range(layers.size() - 1, -1, -1):
		var L: Dictionary = layers[i]
		rows.append({"color": CrossSection.temp_color(L.get("T")), "name": str(L.get("name", "")),
			"num": "%s · %s" % [CrossSection.fmt_length(CrossSection.num(L.get("r1")) * R), CrossSection.fmt_temp(L.get("T"))]})
	return rows

## Fill `parent` (an El) with the .cut-legend grid.
func build_legend(parent: El) -> void:
	for c in parent.get_children():
		if c is El:
			parent.remove_child(c)
			c.queue_free()
	parent.set_style({"display": "grid", "cols": [1.0], "gapr": 2.0, "gapc": 2.0, "mt": 4.0, "maxh": 108.0, "scroll": true, "sbw": 3.0})
	for row in legend():
		var r := Foundry.E(parent, {"display": "flex", "ai": "center", "gapc": 6.0, "fs": 9.5, "c": HudTheme.TEXT_DIM})
		Foundry.E(r, {"w": 8.0, "h": 8.0, "bg": row.color, "shrink": 0.0})
		Foundry.E(r, {"grow": 1.0, "basis": -1.0, "minw": 0.0, "c": HudTheme.TEXT}, row.name)
		Foundry.E(r, {"fs": 9.0}, row.num)
	parent.touch()

func dispose() -> void:
	clear()
	queue_free()
