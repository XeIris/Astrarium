class_name FlightCloudPass
extends CompositorEffect

const SHADER := "res://shaders/flight/clouds_march.glsl"
# The std140 block in clouds_march.glsl uses one vec4 slot per scalar or
# vector, three for the planet basis, then four more for the camera.
const PARAMS: Array[StringName] = [
	&"uCloudCoverage", &"uCloudZ", &"uCloudItcz", &"uCloudBase", &"uCloudTop",
	&"uCloudSigma", &"uLocalToPlanet", &"uPlanetR", &"uCloudWind", &"uClearAt",
	&"uClearR", &"uCamLocal", &"uSunDir", &"uSunColor", &"uSkyTop", &"uSkyNight",
	&"uSkyBottom", &"uBounce", &"uHaze", &"uHazeDensity", &"uHazeRho", &"uMaxDist",
	&"uSteps", &"uLightSteps", &"uDetail", &"uPixAngle", &"uLightFirst", &"uCovReuse",
]
const NOISE: Array[StringName] = [&"uCloudShape", &"uCloudWorley", &"uCloudDetail"]
const UNIFORM_BYTES := (28 + 2 + 4) * 16

var color := Texture2DRD.new()
var clip := Texture2DRD.new()

var _input := Vector2i.ZERO
var _target := Vector2i.ZERO
var _color := RID()
var _clip := RID()
var _ubo := RID()
var _depth_sampler := RID()
var _noise_sampler := RID()
var _march: RDU.Kernel
var _values := PackedFloat32Array()
var _noise: Array[Texture3D] = []
var _planes := Vector2.ZERO

static func available() -> bool:
	return RDU.available() and RenderingServer.get_current_rendering_method() == "forward_plus"

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	enabled = false

func prepare(mat: ShaderMaterial, viewport: SubViewport, camera: Camera3D) -> void:
	# Match RendererViewport's float multiplication and truncation for MetalFX.
	var input := Vector2i(Vector2(viewport.size) * viewport.scaling_3d_scale).clamp(
		Vector2i.ONE, Vector2i(16384, 16384))
	mat.set_shader_parameter("uCloudInputSize", input)
	var values := PackedFloat32Array()
	for param in PARAMS:
		var value: Variant = mat.get_shader_parameter(param)
		if value is Basis:
			for i in 3:
				var column: Vector3 = value[i]
				values.append_array([column.x, column.y, column.z, 0.0])
		elif value is Vector3:
			values.append_array([value.x, value.y, value.z, 0.0])
		else:
			values.append_array([float(value), 0.0, 0.0, 0.0])
	var noise: Array[Texture3D] = []
	for param in NOISE:
		noise.append(mat.get_shader_parameter(param))
	RenderingServer.call_on_render_thread(
		_prepare_rt.bind(input, values, noise, Vector2(camera.near, camera.far)))

func _prepare_rt(input: Vector2i, values: PackedFloat32Array, noise: Array[Texture3D], planes: Vector2) -> void:
	_input = input
	_values = values
	_noise = noise
	_planes = planes
	if _march == null:
		_march = RDU.Kernel.new(SHADER)
		if not _march.valid(): return
		var sampler := RDSamplerState.new()
		_depth_sampler = RDU.rd().sampler_create(sampler)
		sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
		sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
		sampler.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
		_noise_sampler = RDU.rd().sampler_create(sampler)
		_ubo = RDU.rd().uniform_buffer_create(UNIFORM_BYTES)
	if not _march.valid(): return
	var target := (input + Vector2i.ONE) / 2
	if target == _target: return

	# Replace the wrappers before the renderer builds this frame's material sets.
	var format := RDTextureFormat.new()
	format.width = target.x
	format.height = target.y
	format.format = RDU.RGBA16F
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var next_color := RDU.rd().texture_create(format, RDTextureView.new())
	var next_clip := RDU.make_tex(target.x, target.y, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	if not next_color.is_valid() or not next_clip.is_valid():
		RDU.free_rid(next_color)
		RDU.free_rid(next_clip)
		return
	color.texture_rd_rid = next_color
	clip.texture_rd_rid = next_clip
	RDU.free_rid(_color)
	RDU.free_rid(_clip)
	_color = next_color
	_clip = next_clip
	_target = target

func _render_callback(_type: int, data: RenderData) -> void:
	if not _color.is_valid() or not _clip.is_valid(): return
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_internal_size() != _input or _target != (_input + Vector2i.ONE) / 2:
		_invalidate_rt()
		return
	var depth := buffers.get_depth_layer(0)
	if not depth.is_valid():
		_invalidate_rt()
		return
	var uniforms: Array[RDUniform] = [RDU.u_sampled(0, _depth_sampler, depth)]
	for i in _noise.size():
		var source := RenderingServer.texture_get_rd_texture(_noise[i].get_rid()) if _noise[i] != null else RID()
		if not source.is_valid():
			_invalidate_rt()
			return
		uniforms.append(RDU.u_sampled(i + 1, _noise_sampler, source))
	uniforms.append(RDU.u_image(4, _color))
	uniforms.append(RDU.u_image(5, _clip))
	uniforms.append(RDU.u_ubo(6, _ubo))

	var scene := data.get_render_scene_data()
	var view := scene.get_cam_projection()
	var basis := scene.get_cam_transform().basis
	var values := _values.duplicate()
	values.append_array([absf(view.x.x), absf(view.y.y), _planes.x, _planes.y])
	for i in 3:
		var column: Vector3 = basis[i]
		values.append_array([column.x, column.y, column.z, 0.0])
	var bytes := values.to_byte_array()
	RDU.rd().buffer_update(_ubo, 0, bytes.size(), bytes)
	RDU.dispatch(_march, uniforms, _target.x, _target.y)

func _invalidate_rt() -> void:
	# A skipped dispatch must never composite a previous camera's cloud layer.
	RDU.rd().texture_clear(_color, Color(-1.0, -1.0, -1.0, -1.0), 0, 1, 0, 1)

func release_rt() -> void:
	color.texture_rd_rid = RID()
	clip.texture_rd_rid = RID()
	for rid in [_color, _clip, _ubo, _depth_sampler, _noise_sampler]:
		RDU.free_rid(rid)
	if _march != null: _march.release()
	_color = RID()
	_clip = RID()
