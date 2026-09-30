class_name RDU
extends RefCounted

# RENDERINGDEVICE HELPERS for the compute passes in render/: GLSL 450 compute on the
# main RenderingDevice, writing RD textures handed on as Texture2DRD. Compute rather
# than canvas_item SubViewports because order is explicit (one callback, in order,
# this frame), passes can have several outputs (the lens marcher writes two), and
# the shaders stay GLSL. Render thread only (a CompositorEffect callback or
# RenderingServer.call_on_render_thread).

const RGBA16F := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
const RGBA8 := RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM

static func rd() -> RenderingDevice:
	return RenderingServer.get_rendering_device()

static func make_tex(w: int, h: int, fmt := RGBA16F) -> RID:
	var f := RDTextureFormat.new()
	f.width = maxi(w, 1)
	f.height = maxi(h, 1)
	f.format = fmt
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return rd().texture_create(f, RDTextureView.new())

static func free_rid(r: RID) -> void:
	if r.is_valid():
		rd().free_rid(r)

## Linear-filtered, clamp-to-edge: THREE.LinearFilter + ClampToEdgeWrapping.
static func linear_sampler() -> RID:
	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	s.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	s.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return rd().sampler_create(s)

## A compiled compute shader and its pipeline. Loaded from a `#[compute]` .glsl
## file, which Godot imports as an RDShaderFile — so a compile error surfaces
## at import time, with the file and line, before a frame is drawn.
class Kernel:
	var shader: RID
	var pipeline: RID
	var path: String
	func _init(p: String) -> void:
		path = p
		var sf: RDShaderFile = load(p)
		if sf == null:
			push_error("RDU: cannot load compute shader " + p)
			return
		var spirv := sf.get_spirv()
		var err := spirv.compile_error_compute
		if err != "":
			push_error("RDU: " + p + " failed to compile:\n" + err)
			return
		shader = RDU.rd().shader_create_from_spirv(spirv)
		pipeline = RDU.rd().compute_pipeline_create(shader)
	func valid() -> bool:
		return pipeline.is_valid()
	func release() -> void:
		RDU.free_rid(pipeline)
		RDU.free_rid(shader)

static func u_image(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u

static func u_sampled(binding: int, sampler: RID, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(tex)
	return u

static func u_ubo(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u

## Pad a float array to a multiple of 4 floats (16 bytes) — push constants and
## std140 blocks are both sized in vec4s.
static func pack(vals: Array) -> PackedByteArray:
	var f := PackedFloat32Array()
	for v in vals:
		f.append(float(v))
	while f.size() % 4 != 0:
		f.append(0.0)
	return f.to_byte_array()

## Dispatch `k` over a w×h grid in 8×8 groups (every kernel here declares
## local_size 8×8). The uniform set is transient: built, bound, freed.
static func dispatch(k: Kernel, uniforms: Array, w: int, h: int, push := PackedByteArray()) -> void:
	if not k.valid():
		return
	var dev := rd()
	var us := dev.uniform_set_create(uniforms, k.shader, 0)
	var cl := dev.compute_list_begin()
	dev.compute_list_bind_compute_pipeline(cl, k.pipeline)
	dev.compute_list_bind_uniform_set(cl, us, 0)
	if push.size() > 0:
		dev.compute_list_set_push_constant(cl, push, push.size())
	dev.compute_list_dispatch(cl, (w + 7) / 8, (h + 7) / 8, 1)
	dev.compute_list_end()
	dev.free_rid(us)

## The RD texture behind any engine Texture (a ViewportTexture, an image
## texture) — how a compute pass reads what a SubViewport rendered.
static func rd_of(tex: Texture2D) -> RID:
	if tex == null:
		return RID()
	return RenderingServer.texture_get_rd_texture(tex.get_rid())
