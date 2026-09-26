extends Node

# ===========================================================================
# CRAFT STUDIO — sim/flight/craftmodel.gd on its own, with nothing in the way.
# The Godot counterpart of .claude/crafttest.html, and deliberately NOT built on
# tools/harness.gd: the web page renders straight to the canvas with three's
# own ACESFilmic tone mapping and no bloom, and a harness that went through
# render/postfx.gd would be comparing two different pictures. So this renders
# one HDR SubViewport, tone maps it with three's exact curve (exposure / 0.6,
# then the Hill ACES fit, then sRGB), and composites the flat background colour
# AFTER the curve, as three's clear colour is. Same camera, same rig, same
# figure, same ground, same framing arithmetic as the page.
#
#   Godot --path . res://tools/crafttest.tscn -- v=saturnv view=side out=/abs.png
#     v=<id>        vehicle (default saturnv)
#     view=side|iso|front|top|detail|under|nose   (default side)
#     z=<zoom>      zoom (default 1)
#     stage=<n>     frame one stage only
#     deploy=0      stowed pose (deployables are shown DEPLOYED by default,
#                   because a folded leg tells you nothing about whether the
#                   leg is right — see AGENTS.md)
#     w=, h=        frame size (default 1280×720, the web reference's)
#     assets=0      do not load the authored meshes: the procedural fallback
#     out=<png>     write the frame and quit
#
#   Godot --headless --path . res://tools/crafttest.tscn -- audit [assets=0]
#   Godot --headless --path . res://tools/crafttest.tscn -- clearance [assets=0]
#     print STUDIO.audit() / STUDIO.clearance() as tables (and JSON) and quit.
# ===========================================================================

const CM := preload("res://sim/flight/craftmodel.gd")

var args := {}
var frame := 0
var vp3: SubViewport
var vp2: SubViewport
var cam: Camera3D
var craft

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	# The authored models are a cache build_craft reads, not something it
	# waits for — so the studio has to fill the cache BEFORE it builds anything,
	# or it renders the procedural fallback and reports its triangle count as
	# the regression number.
	if args.get("assets", "1") != "0":
		CraftAssets.craft_models_ready()
	if args.has("audit") or args.has("clearance"):
		if args.has("audit"):
			print_audit(audit())
		if args.has("clearance"):
			print_clearance(clearance())
		CraftAssets.clear()
		get_tree().quit()
		return
	_build_studio()

# ---------------------------------------------------------------------------
# THE NUMBERS
# ---------------------------------------------------------------------------
## Build every vehicle and report its measured extents. There is no test suite
## here, so this is the regression check: a builder that throws, or a stack
## whose height stops matching the published figure, shows up as a number
## rather than as a picture that looks slightly wrong.
static func audit() -> Array:
	var out := []
	var V: Dictionary = CM.vehicles()
	for k in V.keys():
		var c = CM.build_craft(V[k])
		# As-launched, not as-built: arrays and legs are STOWED until the flight
		# state says otherwise, and measuring before the first update reports a
		# payload with its solar wings already open inside a fairing.
		c.update({"dt": 0.0, "attached": {}, "deploy": {}, "gimbal": {"x": 0.0, "z": 0.0}, "flap": 0.0})
		var b: AABB = CM.measure(c.group)
		out.append({"k": k, "h": _r1(b.size.y), "w": _r1(b.size.x), "d": _r1(b.size.z),
			"base": _r1(b.position.y), "tris": CM.triangles(c.group), "authored": c.authored})
		c.group.free()
	return out

## ENGINE CLEARANCE, as a number rather than as a picture. For every stage with
## more than one engine, the smallest gap between any two bells: the NEAREST
## NEIGHBOUR over the whole cluster, which is the test a per-ring chord check
## misses. Negative means they interpenetrate.
##
## This exists because three separate clusters shipped with their bells inside
## each other — the S-IC's outboard F-1s half a metre into the centre engine,
## Super Heavy's inner three buried in the ten around them, Starship's vacuum
## Raptors sitting on its sea-level ones — and every one of them looked, in a
## render, like a tightly packed cluster.
static func clearance() -> Array:
	var out := []
	var V: Dictionary = CM.vehicles()
	for k in V.keys():
		var c = CM.build_craft(V[k])
		c.update({"dt": 4.0, "attached": {}, "deploy": {}, "gimbal": {"x": 0.0, "z": 0.0}, "flap": 0.0})
		var rows := []
		for st in c.stages:
			var ps := []
			for p: Node3D in st.parts.gimbals:
				var b: AABB = CM.measure(p)
				var v := CM.world_xform(p).origin
				ps.append({"x": v.x, "z": v.z, "r": b.size.x / 2.0})
			if ps.size() < 2: continue
			var gap := INF
			for i in ps.size():
				for j in range(i + 1, ps.size()):
					gap = minf(gap, Vector2(ps[i].x - ps[j].x, ps[i].z - ps[j].z).length() - (ps[i].r + ps[j].r))
			rows.append({"stage": st.key, "n": ps.size(), "gap": snappedf(gap, 0.001)})
		if not rows.is_empty():
			out.append({"k": k, "clusters": rows})
		c.group.free()
	return out

static func _r1(x: float) -> float:
	return snappedf(x, 0.1)

static func print_audit(rows: Array) -> void:
	print("AUDIT  %-11s %7s %7s %7s %6s %8s  %s" % ["vehicle", "h", "w", "d", "base", "tris", "build"])
	for r in rows:
		print("AUDIT  %-11s %7.1f %7.1f %7.1f %6.1f %8d  %s" % [r.k, r.h, r.w, r.d, r.base, r.tris,
			"authored" if r.authored else "procedural"])
	print("AUDIT_JSON ", JSON.stringify(rows))

static func print_clearance(rows: Array) -> void:
	for r in rows:
		for c in r.clusters:
			print("CLEAR  %-11s %-8s n=%2d  gap=%7.3f" % [r.k, c.stage, c.n, c.gap])
	print("CLEAR_JSON ", JSON.stringify(rows))

# ---------------------------------------------------------------------------
# THE STUDIO
# ---------------------------------------------------------------------------
## three's ACESFilmicToneMapping (r160), exactly: exposure / 0.6, the Hill
## RRT+ODT fit, clamp — then linear → sRGB, as the page's SRGBColorSpace output
## does. The background is composited AFTER the curve, because three's clear
## colour never goes through tone mapping.
const TONEMAP_SHADER := """
shader_type canvas_item;
uniform sampler2D hdr : filter_linear;
uniform vec3 bg;          // sRGB, as the page's scene.background hex
uniform float exposure = 1.0;
vec3 rrt(vec3 v) {
	vec3 a = v * (v + 0.0245786) - 0.000090537;
	vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
	return a / b;
}
vec3 aces(vec3 c) {
	const mat3 IN = mat3(vec3(0.59719, 0.07600, 0.02840), vec3(0.35458, 0.90834, 0.13383), vec3(0.04823, 0.01566, 0.83777));
	const mat3 OUT = mat3(vec3(1.60475, -0.10208, -0.00327), vec3(-0.53108, 1.10813, -0.07276), vec3(-0.07367, -0.00605, 1.07602));
	c *= exposure / 0.6;
	c = IN * c;
	c = rrt(c);
	c = OUT * c;
	return clamp(c, 0.0, 1.0);
}
vec3 to_srgb(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}
void fragment() {
	vec4 s = texture(hdr, UV);
	vec3 lin = s.a > 1e-4 ? s.rgb / s.a : vec3(0.0);
	COLOR = vec4(mix(bg, to_srgb(aces(lin)), clamp(s.a, 0.0, 1.0)), 1.0);
}
"""

## The HDR 3D viewport + the 2D viewport that tone maps it, sized w×h. Returns
## [vp3, vp2, tonemap_rect]. Shared with craftsheet.gd.
static func make_frame(parent: Node, w: int, h: int, bg_hex: int) -> Array:
	var v3 := SubViewport.new()
	v3.size = Vector2i(w, h)
	v3.use_hdr_2d = true
	v3.transparent_bg = true
	v3.msaa_3d = Viewport.MSAA_4X                  # antialias: true
	v3.own_world_3d = true
	v3.mesh_lod_threshold = 0.0                    # no automatic LOD: three has none
	v3.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var v2 := SubViewport.new()
	v2.size = Vector2i(w, h)
	v2.transparent_bg = false
	v2.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var tr := TextureRect.new()
	tr.texture = v3.get_texture()
	tr.size = Vector2(w, h)
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = TONEMAP_SHADER
	sm.shader = sh
	sm.set_shader_parameter("hdr", v3.get_texture())
	sm.set_shader_parameter("bg", _srgb3(bg_hex))
	tr.material = sm
	v2.add_child(tr)
	parent.add_child(v3)
	parent.add_child(v2)
	return [v3, v2, tr]

static func _srgb3(hex: int) -> Vector3:
	return Vector3(((hex >> 16) & 255) / 255.0, ((hex >> 8) & 255) / 255.0, (hex & 255) / 255.0)

## The page's rig, into a 3D viewport: key high-left, quarter-strength fill
## opposite, rim behind to peel a white vehicle off a grey ground, and an
## ambient. Intensities are three's (r160, physically-correct lights, Lambert
## = albedo/π) divided by π, because Godot's non-physical light energy already
## carries the π: measured, a white Lambert quad under a unit DirectionalLight3D
## returns exactly 1.0 and under a unit ambient returns 1.0 — three returns 1/π
## for both.
static func add_rig(vp: SubViewport, rim_i := 2.0, amb_hex := 0x404a58, amb_i := 0.6) -> Environment:
	for L in [[Vector3(-4, 5, 6), 0xfff4e6, 3.0], [Vector3(5, 1, 3), 0xbfd4ff, 0.8], [Vector3(2, 2, -7), 0xffffff, rim_i]]:
		vp.add_child(dir_light(L[0], L[1], L[2]))
	var env := RenderPipeline.neutral_env()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.hex((amb_hex << 8) | 0xff)   # sRGB, converted like three's
	env.ambient_light_energy = amb_i / PI
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	return env

## A DirectionalLight at `pos` shining at the origin, three-style (a three
## directional light points from its position to its target).
static func dir_light(pos: Vector3, hex: int, intensity: float) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.light_color = Color.hex((hex << 8) | 0xff)
	l.light_energy = intensity / PI
	l.shadow_enabled = false
	l.basis = look_basis(-pos)
	return l

## A basis whose −Z points along `dir` (a camera's or a light's forward).
static func look_basis(dir: Vector3, up := Vector3.UP) -> Basis:
	var d := dir.normalized()
	if absf(d.dot(up)) > 0.99999:
		up = Vector3(0, 0, -1) if d.y > 0 else Vector3(0, 0, 1)
	return Basis.looking_at(d, up)

static func std_mat(hex: int, rough: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.hex((hex << 8) | 0xff)
	m.roughness = rough
	m.metallic = metal
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	return m

func _build_studio() -> void:
	var key: String = args.get("v", "saturnv")
	var view: String = args.get("view", "side")
	var zoom := float(args.get("z", "1"))
	var only = args.get("stage")
	var dep := float(args.get("deploy", "1"))
	var W := int(args.get("w", "1280")); var H := int(args.get("h", "720"))
	get_window().size = Vector2i(W, H)
	var fr := make_frame(self, W, H, 0x30343b)
	vp3 = fr[0]; vp2 = fr[1]
	add_rig(vp3)

	# A spec is user input and build_craft reads vehicle.stages straight off
	# what it is handed, so an unknown key fails deep inside the builder rather
	# than here, where the message can say what the options were.
	var veh = CM.vehicle(key)
	if veh == null:
		push_error("[crafttest] no such vehicle '%s' — try one of: %s" % [key, ", ".join(CM.vehicles().keys())])
		get_tree().quit(1)
		return
	craft = CM.build_craft(veh)
	vp3.add_child(craft.group)
	var deploy := {}
	for st in craft.stages: deploy[st.key] = dep
	# dt = 0 freezes the easing at wherever `deploy` started, so the state has
	# to be stepped in rather than waited for: one step at dt = 0, then one big
	# one.
	craft.update({"dt": 0.0, "attached": {}, "deploy": deploy, "gimbal": {"x": 0.0, "z": 0.0}, "flap": 0.0})
	craft.update({"dt": 4.0, "attached": {}, "deploy": deploy, "gimbal": {"x": 0.0, "z": 0.0}, "flap": 0.0})

	# Frame it. A rocket is a tall thin thing, so the fit is driven by height.
	var box: AABB
	if only != null:
		var si := int(only)
		if si < 0 or si >= craft.stages.size():
			push_error("[crafttest] no stage %s on '%s' — it has %d" % [only, key, craft.stages.size()])
			get_tree().quit(1)
			return
		box = CM.measure(craft.stages[si].group)
	else:
		box = CM.measure(craft.group)
	var size := box.size
	var mid := box.get_center()
	var hh := maxf(size.y, 1e-3); var ww := maxf(maxf(size.x, size.z), 1e-3)

	# A 1.75 m figure at the base: the only object whose size the eye already knows.
	var man := MeshInstance3D.new()
	man.mesh = CM._to_mesh(CM._capsule(0.22, 1.3, 4, 8), std_mat(0xd08a50, 0.9))
	man.position = Vector3(ww * 0.62 + 1.5, box.position.y + 0.87, 0)
	vp3.add_child(man)
	var ground := MeshInstance3D.new()
	ground.mesh = CM._to_mesh(CM._circle(maxf(hh, ww) * 3.0, 48), std_mat(0x2a2d33, 1.0))
	ground.rotation_order = EULER_ORDER_XYZ
	ground.rotation.x = -PI / 2.0
	ground.position.y = box.position.y - 0.01
	vp3.add_child(ground)

	cam = Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	var ortho := view == "side" or view == "front" or view == "top"
	# `detail` frames the AFT END, and its distance has to come from the height,
	# not the width: a ship with a 51 m wingspan and a 47 m hull would otherwise
	# pull the camera out to 160 m to "zoom in" on its engines. `nose` is
	# `detail`'s opposite number: the forward end is where the antennas, the
	# docking node and the escape tower are.
	var close := view == "detail" or view == "under" or view == "nose"
	var d := (hh * 0.42 if close else hh * 1.9) / zoom
	var at := mid
	if view == "nose": at = Vector3(0, box.end.y - hh * 0.14, 0)
	elif view == "detail" or view == "under": at = Vector3(0, box.position.y + hh * 0.16, 0)
	var dirs := {"under": Vector3(0.45, -0.78, 0.44), "side": Vector3(0, 0, 1), "front": Vector3(1, 0, 0),
		"top": Vector3(0, 1, 0.0001), "iso": Vector3(0.72, 0.30, 0.62), "nose": Vector3(0.74, 0.34, 0.58),
		"detail": Vector3(0.80, 0.22, 0.55)}
	var dir: Vector3 = dirs.get(view, Vector3(0, 0, 1)).normalized()
	if ortho:
		# Orthographic: a silhouette is the honest test of a shape, and it is
		# the only projection you can compare against a reference photo taken at
		# range. three's frustum runs −1e5…1e5 through the camera; Godot wants a
		# positive near, so the eye is backed off along its own axis instead —
		# an orthographic picture does not change with distance.
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = (ww * 2.4 if view == "top" else hh * 1.12) / zoom
		d += 4.0 * maxf(hh, ww) + 50.0
		cam.near = 0.05; cam.far = 1.0e5
	else:
		cam.fov = 34.0
		cam.near = 0.02; cam.far = 1.0e5
	cam.transform = Transform3D(look_basis(-dir), at + dir * d)
	vp3.add_child(cam)
	cam.current = true

	var hud := Label.new()
	hud.text = "%s\n%s  ·  %s m tall  ·  %s m span" % [veh.name, view, U.fixed(size.y, 1), U.fixed(size.x, 1)]
	hud.position = Vector2(10, 8)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Menlo", "SF Mono", "monospace"])
	hud.add_theme_font_override("font", font)
	hud.add_theme_font_size_override("font_size", 12)
	hud.add_theme_color_override("font_color", Color.hex(0x9fb4c7ff))
	hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	vp2.add_child(hud)

	var show := TextureRect.new()
	show.texture = vp2.get_texture()
	show.set_anchors_preset(Control.PRESET_FULL_RECT)
	show.stretch_mode = TextureRect.STRETCH_SCALE
	show.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(show)
	print("crafttest: %s %s — %.1f m tall, %.1f m span, %s" % [key, view, size.y, size.x,
		"authored" if craft.authored else "procedural"])

func _process(_dt: float) -> void:
	if vp2 == null: return
	frame += 1
	if args.has("out") and frame == 4:
		var img := vp2.get_texture().get_image()
		img.save_png(str(args.out))
		print("crafttest: saved ", args.out)
		craft.group.queue_free()
		CraftAssets.clear()
		get_tree().quit()
