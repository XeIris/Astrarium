class_name Cutaway
extends El

# THE 3D CUTAWAY: the interior model as an object, so the core reads as a sphere
# inside shells. Each layer is a double-sided sphere at its own radius, and two
# clipping planes (intersection) remove one octant pair, so the notch shows the far
# inner wall of every shell for free. StandardMaterial3D has no clip planes, so
# shells use shaders/ui/cutaway_layer.gdshader (Lambert + GGX plus the discard).
#
# Its own SubViewport with its own World3D, camera and lights, drawn into this El's
# content box. Linear tonemapper at unity (clamp, sRGB). Light intensities are /π,
# as in modelviewer.gd. Radii are real: a red giant's core is a dot, and that is the
# lesson. The El is `width: 100%; height: auto` over a 320 × 210 bitmap, rendered at
# laid-out size × display scale (capped at 2).

const LAYER_SHADER := preload("res://shaders/ui/cutaway_layer.gdshader")
const LAYER_ALPHA_SHADER := preload("res://shaders/ui/cutaway_layer_alpha.gdshader")

var vp: SubViewport
var camera: Camera3D
var root3d: Node3D
var current: Dictionary = {}
## What is on the turntable now (lessonui compares it with the focused body's
## to decide whether to rebuild).
var structure: Dictionary:
	get: return current
var spin := 0.0
var auto_spin := true
var _tex: TextureRect
var _re_shell := RegEx.create_from_string("(?i)sphere|ISCO|Ergosphere")
var _re_wire := RegEx.create_from_string("(?i)sphere|ISCO")

## Returns the canvas node. opts.style: extra El style (the card's `.lc-canvas`);
## opts.w / opts.h: the bitmap size whose aspect it keeps.
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
	# Ambient 0x93a6c4 × 0.55, sRGB-converted, with the 1/π in the energy.
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
	# A light inside the notch. Omni with range 8 and attenuation 2 matches the physical
	# falloff 1/d² × (1 − (d/8)⁴)².
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

	# A black hole's layers are spacetime locations: wireframe shells over a black ball.
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

## THREE.SphereGeometry(r, 64, 40), vertex for vertex: SphereMesh's grid differs,
## which a wireframe shell would show. (w+1) × (h+1) vertices, seam and poles
## duplicated, degenerate pole triangles skipped, normal = position / r, each
## triangle reversed for Godot's CW front faces (cull_disabled still flips normals by
## facing).
static func _three_sphere(r: float, ws := 64, hs := 40) -> Dictionary:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var grid: Array = []
	var idx := 0
	for iy in hs + 1:
		var row: Array = []
		var vv := float(iy) / hs
		for ix in ws + 1:
			var uu := float(ix) / ws
			var p := Vector3(-r * cos(uu * TAU) * sin(vv * PI), r * cos(vv * PI), r * sin(uu * TAU) * sin(vv * PI))
			v.append(p)
			n.append(p.normalized() if p.length() > 0.0 else Vector3.UP)
			row.append(idx)
			idx += 1
		grid.append(row)
	var tris := PackedInt32Array()      # three's order: (a, b, d), (b, c, d)
	for iy in hs:
		for ix in ws:
			var a: int = grid[iy][ix + 1]
			var b: int = grid[iy][ix]
			var c: int = grid[iy + 1][ix]
			var d: int = grid[iy + 1][ix + 1]
			if iy != 0: tris.append_array([a, b, d])
			if iy != hs - 1: tris.append_array([b, c, d])
	return {"v": v, "n": n, "tris": tris}

static func _sphere(r: float, mat: Material) -> Mesh:
	var g := _three_sphere(r)
	var t: PackedInt32Array = g.tris
	var rev := PackedInt32Array()
	rev.resize(t.size())
	for i in range(0, t.size(), 3):
		rev[i] = t[i]; rev[i + 1] = t[i + 2]; rev[i + 2] = t[i + 1]
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = g.v
	out[Mesh.ARRAY_NORMAL] = g.n
	out[Mesh.ARRAY_INDEX] = rev
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	m.surface_set_material(0, mat)
	return m

## The same sphere drawn `wireframe: true`: three turns each triangle (a, b, c)
## into the three lines ab, bc, ca (shared edges are drawn twice, as there).
static func _wire_sphere(r: float, mat: Material) -> Mesh:
	var g := _three_sphere(r)
	var idx: PackedInt32Array = g.tris
	var lines := PackedInt32Array()
	for t in range(0, idx.size(), 3):
		lines.append_array([idx[t], idx[t + 1], idx[t + 1], idx[t + 2], idx[t + 2], idx[t]])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = g.v
	out[Mesh.ARRAY_NORMAL] = g.n
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

# The legend is page elements (readable): legend() gives rows outermost first;
# build_legend() lays them out as `.cut-legend`.
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
		var r := _el(parent, {"display": "flex", "ai": "center", "gapc": 6.0, "fs": 9.5, "c": HudTheme.TEXT_DIM})
		_el(r, {"w": 8.0, "h": 8.0, "bg": row.color, "shrink": 0.0})
		_el(r, {"grow": 1.0, "basis": -1.0, "minw": 0.0, "c": HudTheme.TEXT}, row.name)
		_el(r, {"fs": 9.0}, row.num)
	parent.touch()

static func _el(parent: Node, style: Dictionary, text = null) -> El:
	var e := El.new(style)
	if text is String: e.runs = [{"t": text}]
	parent.add_child(e)
	return e

func dispose() -> void:
	clear()
	queue_free()
