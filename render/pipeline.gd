class_name RenderPipeline
extends Node

# HDR viewports render before the containing compositor hook, so post-processing
# sees this frame's inputs. Lens compute runs before scene rendering.
# Tone mapping occurs once; layout and floating origin: docs/godot.md.

const TEMP_LAYER_BIT := 1 << 19
const GALAXY_GLOW_LAYER := 1 << 16
const ALL_LAYERS := 0xFFFFF
const GALAXY_GLOW_SCALE := 2.0 / 3.0
const GALAXY_GLOW_MIN_HEIGHT := 720
const METALFX_SCALES := {"off": 1.0, "quality": 1.0 / 1.5, "balanced": 1.0 / 1.7, "performance": 0.5}

static func set_scene_clip(camera: Camera3D, near_plane: float) -> void:
	# Float32 culling planes degenerate at larger ratios, even with reverse-Z depth.
	camera.near = near_plane
	camera.far = minf(100000.0, near_plane * 1.0e7)

enum Mode { ORRERY, FLIGHT, MODEL }
var map_open := false

var hook_vp: SubViewport
var scene_vp: SubViewport
var scene_cam: Camera3D
var world_root: Node3D
var _glow_vp: SubViewport
var _glow_cam: Camera3D
var _galaxy_glow := false
var _reduce_galaxy_glow := true
var _galaxy_view := false
var temp_vp: SubViewport
var temp_cam: Camera3D
var local_vp: SubViewport
var local_cam: Camera3D
var local_root: Node3D
var _local_coverage: LocalCoverage
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
var sky_cache: SkyCache

var mode: int = Mode.ORRERY
var use_lens := false
## dispatch(src: RID, dst: RID, w: int, h: int), run on the render thread between
## compose and the band remap (sim/skyview.gd). null when not on a surface.
var surface_pass = null
var render_scale := 1.0
var metalfx := "off"
var fast_clouds := false
var _cloud_pass: FlightCloudPass
const FULL_CLOUD_SHADER := preload("res://shaders/flight/clouds.gdshader")
const FAST_CLOUD_SHADER := preload("res://shaders/flight/clouds_fast.gdshader")
var view_size := Vector2i(1, 1)     # logical (CSS-equivalent) pixels
var render_size := Vector2i(1, 1)   # device pixels actually rendered
var time := 0.0

## Materials carrying the sky uniform block; anything else that includes
## sky.gdshaderinc (sim/skyview.gd) appends itself.
var sky_materials: Array[ShaderMaterial] = []

var _pending_capture: Array[Array] = []

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

## An Environment that does nothing to the image: the post chain is the one
## tone curve.
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
	# the hook
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

	# the orrery
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

	# the temperature pass: same world, a second camera
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
	# The temperature pass stays live: it picks disc or sky by an exact luminance comparison.
	sky_cache = SkyCache.new(scene_vp, [sky_mat])
	sky_materials = [sky_mat, sky_temp_mat]
	sky_materials.append(sky_cache.material)

	# spaceflight's local world (metres)
	local_vp = _viewport(World3D.new(), true)
	hook_vp.add_child(local_vp)
	local_cam = _camera(0.05, 4.0e6, 55.0)
	_local_coverage = LocalCoverage.new()
	var local_compositor := Compositor.new()
	local_compositor.compositor_effects = [_local_coverage]
	local_cam.compositor = local_compositor
	env_local = neutral_env()
	env_local.background_mode = Environment.BG_CLEAR_COLOR
	local_cam.environment = env_local
	local_vp.add_child(local_cam)
	local_root = Node3D.new()
	local_root.name = "Local"
	local_vp.add_child(local_root)
	local_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

	# the model viewer's studio
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

	# the screen
	display = TextureRect.new()
	display.name = "Display"
	display.texture = postfx.final_tex
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.stretch_mode = TextureRect.STRETCH_SCALE
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	display.set_anchors_preset(Control.PRESET_FULL_RECT)

## Set the logical view size and derive every target from it and the render scale.
func set_view_size(logical: Vector2i) -> void:
	view_size = Vector2i(maxi(logical.x, 1), maxi(logical.y, 1))
	_apply_size()

## Render scale (a pixel ratio), capped by the display's own.
func set_render_scale(s: float) -> float:
	var cap := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	render_scale = minf(s, maxf(cap, 1.0))
	_apply_size()
	return render_scale

static func metalfx_available() -> bool:
	var rd := RDU.rd()
	return rd != null and rd.has_feature(RenderingDevice.SUPPORTS_METALFX_SPATIAL)

func set_metalfx(preset: String) -> void:
	if not METALFX_SCALES.has(preset): return
	metalfx = preset if metalfx_available() else "off"
	_sync_3d_scale()

func prepare_clouds(mat: ShaderMaterial, visible_now: bool) -> void:
	if not fast_clouds or not visible_now:
		if _cloud_pass != null: _cloud_pass.enabled = false
		if mat.shader != FULL_CLOUD_SHADER: mat.shader = FULL_CLOUD_SHADER
		return
	if _cloud_pass == null:
		_cloud_pass = FlightCloudPass.new()
		var effects := local_cam.compositor.compositor_effects
		effects.append(_cloud_pass)
		local_cam.compositor.compositor_effects = effects
	if mat.shader != FAST_CLOUD_SHADER:
		mat.shader = FAST_CLOUD_SHADER
		mat.set_shader_parameter("uReduced", _cloud_pass.color)
		mat.set_shader_parameter("uReducedClip", _cloud_pass.clip)
	_cloud_pass.prepare(mat, local_vp, local_cam)
	_cloud_pass.enabled = true

func set_galaxy_view(active: bool) -> void:
	_galaxy_view = active
	_sync_3d_scale()

func _sync_3d_scale() -> void:
	var scale: float = METALFX_SCALES[metalfx]
	# Spectral bands pair colour and temperature per pixel. Galaxy photometry
	# sizes point sources against the output raster.
	var visible_scale := scale if postfx.band == Spectrum.VISIBLE_BAND else 1.0
	_set_3d_scale(scene_vp, 1.0 if _galaxy_view else visible_scale)
	_set_3d_scale(local_vp, visible_scale)
	_set_3d_scale(model_vp, scale)
	if _local_coverage.enabled and visible_scale == 1.0:
		RenderingServer.call_on_render_thread(_local_coverage.clear_rt)
	_local_coverage.enabled = visible_scale < 1.0

static func _set_3d_scale(vp: SubViewport, scale: float) -> void:
	if is_equal_approx(vp.scaling_3d_scale, scale): return
	vp.scaling_3d_scale = scale
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL if scale < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR

func _apply_size() -> void:
	render_size = Vector2i(maxi(1, int(view_size.x * render_scale)), maxi(1, int(view_size.y * render_scale)))
	for vp in [scene_vp, temp_vp, local_vp, model_vp]:
		vp.size = render_size
	_sync_galaxy_glow()
	postfx.set_size(render_size.x, render_size.y)
	lens.set_size(render_size.x, render_size.y)

func set_band(i: int) -> Dictionary:
	var b := postfx.set_band(i)
	_sync_3d_scale()
	_sync_update_modes()
	return b

func set_mode(m: int) -> void:
	mode = m
	_sync_update_modes()

## The space map covers the frame: nothing 3D needs drawing behind it.
func set_map_open(on: bool) -> void:
	map_open = on
	_sync_update_modes()

func set_galaxy_glow(on: bool) -> void:
	if _galaxy_glow == on: return
	_galaxy_glow = on
	_sync_galaxy_glow()

func set_galaxy_glow_quality(reduced: bool) -> void:
	if _reduce_galaxy_glow == reduced: return
	_reduce_galaxy_glow = reduced
	_sync_galaxy_glow()

## The diffuse march and point sources can sample different pixel footprints.
func galaxy_glow_size() -> Vector2i:
	return _glow_vp.size if _glow_vp != null else render_size

func _sync_galaxy_glow() -> void:
	# Keep the full march at small resolutions and on the higher quality tiers.
	var h := maxi(GALAXY_GLOW_MIN_HEIGHT, roundi(render_size.y * GALAXY_GLOW_SCALE))
	var split := _galaxy_glow and _reduce_galaxy_glow and h < render_size.y \
		and mode == Mode.ORRERY and not map_open and postfx.band == Spectrum.VISIBLE_BAND and RDU.available()
	if not split:
		if _glow_vp != null:
			scene_cam.cull_mask |= GALAXY_GLOW_LAYER
			_glow_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			_glow_vp.queue_free()
			_glow_vp = null
			_glow_cam = null
		return
	if _glow_vp == null:
		scene_cam.cull_mask &= ~GALAXY_GLOW_LAYER
		_glow_vp = _viewport(scene_vp.world_3d)
		_glow_vp.name = "GalaxyGlow"
		hook_vp.add_child(_glow_vp)
		_glow_cam = _camera()
		_glow_cam.cull_mask = GALAXY_GLOW_LAYER
		_glow_cam.environment = neutral_env()
		_glow_cam.environment.background_mode = Environment.BG_COLOR
		_glow_cam.environment.background_color = Color.BLACK
		_glow_vp.add_child(_glow_cam)
	var size := Vector2i(roundi(float(render_size.x) * h / render_size.y), h)
	if _glow_vp.size != size: _glow_vp.size = size

func _sync_update_modes() -> void:
	var off := SubViewport.UPDATE_DISABLED
	var need_temp := postfx.band != Spectrum.VISIBLE_BAND and mode != Mode.MODEL and not map_open
	temp_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if need_temp else off
	scene_vp.render_target_update_mode = off if mode == Mode.MODEL or map_open else SubViewport.UPDATE_ALWAYS
	local_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if mode == Mode.FLIGHT and not map_open else off
	model_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if mode == Mode.MODEL and not map_open else off
	_sync_galaxy_glow()

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
	if _glow_cam != null:
		_glow_cam.transform = scene_cam.transform
		_glow_cam.fov = scene_cam.fov
		_glow_cam.near = scene_cam.near
		_glow_cam.far = scene_cam.far
	use_lens = lens_params != null
	sky_mat.set_shader_parameter("u_lens", use_lens)
	sky_temp_mat.set_shader_parameter("u_lens", use_lens)
	sky_cache.sync()
	sky_mat.set_shader_parameter("u_grav", LensPass.grav_shift(lens_params.holes) if use_lens else 1.0)
	if use_lens and not map_open:
		lens.dispatch(lens_params)

func _post_rt() -> void:
	# The opaque map already owns the display; retain explicit capture requests.
	if map_open and _pending_capture.is_empty(): return
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
		"local_coverage": _local_coverage.texture if mode == Mode.FLIGHT and _local_coverage.enabled else RID(),
		"glow": RDU.rd_of(_glow_vp.get_texture()) if _glow_vp != null else RID(),
		"mode": float(mode),
		"use_temp": use_temp,
		"surface": surface_pass if mode == Mode.ORRERY else null,
		"capture_hdr": _pending_capture.any(func(request: Array): return request[1]),
		"time": time,
	})
	if not _pending_capture.is_empty():
		var cbs := _pending_capture.duplicate()
		_pending_capture.clear()
		var images := {}
		for request in cbs:
			var hdr: bool = request[1]
			if not images.has(hdr): images[hdr] = postfx.read_hdr_rt() if hdr else postfx.read_final_rt()
			(request[0] as Callable).call(images[hdr])

## Ask for the next composited frame (3D only, no HUD) as an Image. HDR captures
## include all viewport layers before the atmosphere, spectral remap and bloom.
func capture_next(cb: Callable, hdr := false) -> void:
	_pending_capture.append([cb, hdr])

func _exit_tree() -> void:
	if _cloud_pass != null:
		_cloud_pass.enabled = false
		RenderingServer.call_on_render_thread(_cloud_pass.release_rt)
	if _local_coverage != null:
		RenderingServer.call_on_render_thread(_local_coverage.release_rt)

class LocalCoverage extends CompositorEffect:
	var texture := RID()
	var size := Vector2i.ZERO
	var _sampler := RID()
	var _copy: RDU.Kernel

	func _init() -> void:
		effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
		access_resolved_color = true
		enabled = false

	func _render_callback(_type: int, data: RenderData) -> void:
		# MetalFX returns opaque colour. Keep the resolved coverage at its input size.
		var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
		var source := buffers.get_color_layer(0)
		var extent := buffers.get_internal_size()
		if _copy == null:
			_copy = RDU.Kernel.new("res://shaders/post/local_coverage.glsl")
			_sampler = RDU.linear_sampler()
		if size != extent:
			clear_rt()
			texture = RDU.make_tex(extent.x, extent.y, RenderingDevice.DATA_FORMAT_R16_SFLOAT)
			size = extent
		RDU.dispatch(_copy, [RDU.u_sampled(0, _sampler, source), RDU.u_image(1, texture)], size.x, size.y)

	func clear_rt() -> void:
		RDU.free_rid(texture)
		texture = RID()
		size = Vector2i.ZERO

	func release_rt() -> void:
		clear_rt()
		RDU.free_rid(_sampler)
		if _copy != null: _copy.release()
