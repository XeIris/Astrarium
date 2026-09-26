class_name RenderPipeline
extends Node

# ============================================================================
# THE RENDER PIPELINE — the Godot home of everything the web build did by hand
# with renderer.setRenderTarget / autoClear / clearDepth in animate().
# ----------------------------------------------------------------------------
# The web build rendered into its own half-float target and tone mapped once.
# That is kept exactly; what changes is who does the drawing.
#
#   hook_vp  (4×4, empty world, a Compositor whose callback runs the post chain)
#    ├─ scene_vp   the orrery. HDR-2D, linear, Godot's tonemap/glow/exposure OFF.
#    │    │        Background = shaders/sky/background.gdshader (sky, or the
#    │    │        lens resolve). Objects go under `world_root`.
#    │    └─ temp_vp  the SAME world, a second camera whose cull mask carries
#    │               TEMP_LAYER_BIT: every shader writes the web build's
#    │               alpha-channel temperature into R instead of colour.
#    ├─ local_vp   spaceflight's metre-scale world, transparent background,
#    │             composited over the orrery exactly as the web build drew it
#    │             over the orrery with its own depth.
#    └─ model_vp   the model-viewer studio, which takes the whole frame.
#   display  (TextureRect)  the 8-bit composite, stretched to the window.
#
# WHY THIS SHAPE. A SubViewport renders BEFORE the viewport that contains it
# (measured: nested viewports are frame-exact), so the hook's callback is the
# first moment every input to the post chain is finished for this frame, and
# the root viewport — which draws `display` — renders after the hook. The lens
# marcher is dispatched from _process via call_on_render_thread, which with
# the single-threaded render model runs before any viewport draws, so the sky
# shader samples this frame's march. All three facts were measured in a probe
# before this was written (PORT_GUIDE.md, "render order").
#
# THE FLOATING ORIGIN. Every camera here sits at the origin with rotation only;
# the orchestrator places objects at (position − camera position), computed in
# double precision. See PORT_GUIDE.md.
# ============================================================================

const TEMP_LAYER_BIT := 1 << 19
const ALL_LAYERS := 0xFFFFF

enum Mode { ORRERY, FLIGHT, MODEL }

var hook_vp: SubViewport
var scene_vp: SubViewport
var scene_cam: Camera3D
var world_root: Node3D
var temp_vp: SubViewport
var temp_cam: Camera3D
var local_vp: SubViewport
var local_cam: Camera3D
var local_root: Node3D
var model_vp: SubViewport
var model_cam: Camera3D
var model_root: Node3D
var display: TextureRect

var env_color: Environment
var env_temp: Environment
var sky_mat: ShaderMaterial
var sky_temp_mat: ShaderMaterial
var env_local: Environment
var env_model: Environment

var postfx: PostFX
var lens: LensPass

var mode: int = Mode.ORRERY
var use_lens := false
## An object with dispatch(src: RID, dst: RID, w: int, h: int), run on the
## render thread between compose and the band remap (sim/skyview.gd's
## atmosphere). null when not standing on a world.
var surface_pass = null
var render_scale := 1.0
var view_size := Vector2i(1, 1)     # logical (CSS-equivalent) pixels
var render_size := Vector2i(1, 1)   # device pixels actually rendered
var time := 0.0

## Materials that carry the sky uniform block — the web build's syncSky(fn)
## iterated two uniform objects; this list is the same idea. Anything else that
## includes sky.gdshaderinc (sim/skyview.gd) appends itself.
var sky_materials: Array[ShaderMaterial] = []

var _pending_capture: Array[Callable] = []

func _ready() -> void:
	process_priority = 1000   # after the orchestrator has placed this frame's camera
	postfx = PostFX.new()
	lens = LensPass.new()
	_build()

func _viewport(w: World3D, transparent := false) -> SubViewport:
	var vp := SubViewport.new()
	vp.use_hdr_2d = true
	vp.transparent_bg = transparent
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = false
	vp.use_debanding = false
	vp.positional_shadow_atlas_size = 0
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.handle_input_locally = false
	vp.gui_disable_input = true
	vp.audio_listener_enable_3d = false
	if w != null:
		vp.world_3d = w
	return vp

## An Environment that does NOTHING to the image: the post chain is the one
## tone curve, as sim/postfx.js was.
static func neutral_env() -> Environment:
	var e := Environment.new()
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.tonemap_exposure = 1.0
	e.tonemap_white = 1.0
	e.glow_enabled = false
	e.ssr_enabled = false
	e.ssao_enabled = false
	e.ssil_enabled = false
	e.sdfgi_enabled = false
	e.fog_enabled = false
	e.volumetric_fog_enabled = false
	e.adjustment_enabled = false
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0, 0, 0)
	e.ambient_light_energy = 0.0
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	return e

func _camera(near := 0.01, far := 100000.0, fov := 50.0) -> Camera3D:
	var c := Camera3D.new()
	c.keep_aspect = Camera3D.KEEP_HEIGHT     # fov is vertical, as THREE's is
	c.fov = fov
	c.near = near
	c.far = far
	c.current = true
	return c

func _build() -> void:
	# ---- the hook
	hook_vp = _viewport(World3D.new())
	hook_vp.size = Vector2i(4, 4)
	add_child(hook_vp)
	var hcam := _camera()
	var henv := neutral_env()
	henv.background_mode = Environment.BG_CLEAR_COLOR
	hcam.environment = henv
	var comp := Compositor.new()
	var eff := HookEffect.new()
	eff.callback = _post_rt
	comp.compositor_effects = [eff]
	hcam.compositor = comp
	hook_vp.add_child(hcam)

	# ---- the orrery
	scene_vp = _viewport(World3D.new())
	hook_vp.add_child(scene_vp)
	scene_cam = _camera()
	scene_cam.cull_mask = ALL_LAYERS & ~TEMP_LAYER_BIT
	env_color = neutral_env()
	env_color.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky/background.gdshader")
	sky_mat.set_shader_parameter("t_march0", lens.tex0)
	sky_mat.set_shader_parameter("t_march1", lens.tex1)
	sky.sky_material = sky_mat
	env_color.sky = sky
	scene_cam.environment = env_color
	scene_vp.add_child(scene_cam)
	world_root = Node3D.new()
	world_root.name = "World"
	scene_vp.add_child(world_root)

	# ---- the temperature pass: same world, a second camera
	temp_vp = _viewport(scene_vp.world_3d)
	scene_vp.add_child(temp_vp)
	temp_cam = _camera()
	temp_cam.cull_mask = ALL_LAYERS | TEMP_LAYER_BIT
	env_temp = neutral_env()
	env_temp.background_mode = Environment.BG_SKY
	var sky_t := Sky.new()
	sky_t.radiance_size = Sky.RADIANCE_SIZE_32
	sky_t.process_mode = Sky.PROCESS_MODE_QUALITY
	sky_temp_mat = ShaderMaterial.new()
	sky_temp_mat.shader = load("res://shaders/sky/background_temp.gdshader")
	sky_temp_mat.set_shader_parameter("t_march0", lens.tex0)
	sky_temp_mat.set_shader_parameter("t_march1", lens.tex1)
	sky_t.sky_material = sky_temp_mat
	env_temp.sky = sky_t
	temp_cam.environment = env_temp
	temp_vp.add_child(temp_cam)
	temp_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	sky_materials = [sky_mat, sky_temp_mat]

	# ---- spaceflight's local world (metres)
	local_vp = _viewport(World3D.new(), true)
	hook_vp.add_child(local_vp)
	local_cam = _camera(0.05, 4.0e6, 55.0)
	env_local = neutral_env()
	env_local.background_mode = Environment.BG_CLEAR_COLOR
	local_cam.environment = env_local
	local_vp.add_child(local_cam)
	local_root = Node3D.new()
	local_root.name = "Local"
	local_vp.add_child(local_root)
	local_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

	# ---- the model viewer's studio
	model_vp = _viewport(World3D.new())
	hook_vp.add_child(model_vp)
	model_cam = _camera(0.05, 5000.0, 32.0)
	env_model = neutral_env()
	env_model.background_mode = Environment.BG_COLOR
	env_model.background_color = Color.hex(0x0b0d11ff)   # sRGB, converted like setClearColor
	model_cam.environment = env_model
	model_vp.add_child(model_cam)
	model_root = Node3D.new()
	model_root.name = "Studio"
	model_vp.add_child(model_root)
	model_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

	# ---- the screen
	display = TextureRect.new()
	display.name = "Display"
	display.texture = postfx.final_tex
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.stretch_mode = TextureRect.STRETCH_SCALE
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	display.set_anchors_preset(Control.PRESET_FULL_RECT)

## Set the logical view size (what the web build called innerWidth/innerHeight)
## and derive every target from it and the render scale.
func set_view_size(logical: Vector2i) -> void:
	view_size = Vector2i(maxi(logical.x, 1), maxi(logical.y, 1))
	_apply_size()

## Render scale — the web build's pixel ratio, capped by the display's own.
func set_render_scale(s: float) -> float:
	var cap := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	render_scale = minf(s, maxf(cap, 1.0))
	_apply_size()
	return render_scale

func _apply_size() -> void:
	render_size = Vector2i(maxi(1, int(view_size.x * render_scale)), maxi(1, int(view_size.y * render_scale)))
	for vp in [scene_vp, temp_vp, local_vp, model_vp]:
		vp.size = render_size
	postfx.set_size(render_size.x, render_size.y)
	lens.set_size(render_size.x, render_size.y)

func set_band(i: int) -> Dictionary:
	var b := postfx.set_band(i)
	_sync_update_modes()
	return b

func set_mode(m: int) -> void:
	mode = m
	_sync_update_modes()

func _sync_update_modes() -> void:
	var need_temp := postfx.band != Spectrum.VISIBLE_BAND and mode != Mode.MODEL
	temp_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if need_temp else SubViewport.UPDATE_DISABLED
	scene_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED if mode == Mode.MODEL else SubViewport.UPDATE_ALWAYS
	local_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if mode == Mode.FLIGHT else SubViewport.UPDATE_DISABLED
	model_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if mode == Mode.MODEL else SubViewport.UPDATE_DISABLED

## Set a uniform on every material that includes the sky block.
func sky_set(name: StringName, value) -> void:
	for m in sky_materials:
		m.set_shader_parameter(name, value)

## Called by the orchestrator once the frame's camera and holes are final.
## `lens_params` is null when no lens is drawn, else see LensPass.dispatch.
func prepare_frame(lens_params, t: float) -> void:
	time = t
	temp_cam.global_transform = scene_cam.global_transform
	temp_cam.fov = scene_cam.fov
	temp_cam.near = scene_cam.near
	temp_cam.far = scene_cam.far
	use_lens = lens_params != null
	for m in sky_materials:
		m.set_shader_parameter("u_lens", use_lens)
	if use_lens:
		lens.dispatch(lens_params)

func _post_rt() -> void:
	var src_scene := RID()
	if mode == Mode.MODEL:
		src_scene = RDU.rd_of(model_vp.get_texture())
	else:
		src_scene = RDU.rd_of(scene_vp.get_texture())
	var use_temp := postfx.band != Spectrum.VISIBLE_BAND and mode != Mode.MODEL
	postfx.render_rt({
		"scene": src_scene,
		"temp": RDU.rd_of(temp_vp.get_texture()) if use_temp else RID(),
		"local": RDU.rd_of(local_vp.get_texture()) if mode == Mode.FLIGHT else RID(),
		"mode": float(mode),
		"use_temp": use_temp,
		"surface": surface_pass if mode == Mode.ORRERY else null,
		"time": time,
	})
	if not _pending_capture.is_empty():
		var img := postfx.read_final_rt()
		var cbs := _pending_capture.duplicate()
		_pending_capture.clear()
		for cb in cbs:
			cb.call(img)

## Ask for the next composited frame (3D only, no HUD) as an Image.
func capture_next(cb: Callable) -> void:
	_pending_capture.append(cb)
