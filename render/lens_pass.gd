class_name LensPass
extends RefCounted

# Kerr ray marching and an illustrated volumetric Page–Thorne accretion disc.
# The half-resolution direction field is resolved against a full-resolution sky.
# Derivation and limitations: docs/physics/lensing.md.

const MAX_HOLES := 2

## Half resolution dispatches one quarter of the display pixels.
const DEFAULT_LENS_SCALE := 0.5
enum DiscUpdate { FULL, BUILD_MASK, REUSE_MASK }
enum RayPipeline { SINGLE_HOLE = 1, NON_ROTATING = 2 }

var scale := DEFAULT_LENS_SCALE
var _vw := 1
var _vh := 1
var _mw := 1
var _mh := 1
var _march0 := RID()
var _march1 := RID()
var _disc_mask := RID()
var _ubo := RID()
var _kernel: RDU.Kernel
var _pipelines: Dictionary[int, RID] = {}
var _marched_params := PackedByteArray()
var _ray_params := PackedByteArray()
var _disc_mask_ready := false
## Texture2DRDs the background sky shaders sample. Their RIDs are swapped in
## place on resize, so a material holding them never needs re-pointing.
var tex0 := Texture2DRD.new()
var tex1 := Texture2DRD.new()

const UBO_FLOATS := 4 * (MAX_HOLES * 4 + 6)
const DISC_TIME_INDEX := MAX_HOLES * 16 + 17
static var _pt_cache := {}

func _init() -> void:
	RenderingServer.call_on_render_thread(_init_rt)

func _init_rt() -> void:
	_kernel = RDU.Kernel.new("res://shaders/lens/lens_march.glsl")
	var zero := PackedFloat32Array(); zero.resize(UBO_FLOATS)
	if RDU.available():
		_ubo = RDU.rd().uniform_buffer_create(UBO_FLOATS * 4, zero.to_byte_array())
	_resize_rt()

func _pipeline_rt(flags: int) -> RID:
	if flags == 0: return RID()
	if not _pipelines.has(flags):
		# Compile only the variants actually used on this stage.
		var constants: Array[RDPipelineSpecializationConstant] = []
		for id in 2:
			if (flags & (1 << id)) == 0: continue
			var enabled := RDPipelineSpecializationConstant.new()
			enabled.constant_id = id
			enabled.value = true
			constants.append(enabled)
		_pipelines[flags] = RDU.rd().compute_pipeline_create(_kernel.shader, constants)
	return _pipelines[flags]

## Display-resolution size, in device pixels.
func set_size(w: int, h: int) -> void:
	_vw = maxi(w, 1); _vh = maxi(h, 1)
	RenderingServer.call_on_render_thread(_resize_rt)

func set_scale(s: float) -> void:
	scale = clampf(s, 0.1, 1.0)
	RenderingServer.call_on_render_thread(_resize_rt)

func get_scale() -> float:
	return scale

func march_size() -> Vector2i:
	return Vector2i(_mw, _mh)

func _resize_rt() -> void:
	var w := maxi(1, int(round(_vw * scale)))
	var h := maxi(1, int(round(_vh * scale)))
	if w == _mw and h == _mh and _march0.is_valid():
		return
	_marched_params = PackedByteArray()
	_ray_params = PackedByteArray()
	_disc_mask_ready = false
	_mw = w; _mh = h
	var old0 := _march0; var old1 := _march1
	RDU.free_rid(_disc_mask)
	_disc_mask = RID()
	_march0 = RDU.make_tex(w, h)
	_march1 = RDU.make_tex(w, h)
	tex0.texture_rd_rid = _march0
	tex1.texture_rd_rid = _march1
	RDU.free_rid(old0); RDU.free_rid(old1)

## Page–Thorne terms for spin a*, cached; the marcher evaluates the flux per sample.
static func disc_terms(a: float) -> Dictionary:
	var key := snappedf(clampf(a, 0.0, 0.998), 1e-4)
	if not _pt_cache.has(key):
		if _pt_cache.size() > 64: _pt_cache.clear()
		_pt_cache[key] = Physics.page_thorne_terms(key)
	return _pt_cache[key]

## ν_observed/ν_∞ for the background at the camera, a static observer: 1/√(1 − f) with
## Kerr–Schild f = 2Mr³/(r⁴ + a²z²) summed over the holes (weak-field superposition for
## two). Inside an ergosphere no observer is static; the Kerr–Schild normal observer's
## √(1 + f) stands in, without its direction dependence.
static func grav_shift(holes: Array) -> float:
	var f := 0.0
	for h in holes:
		var M := 0.5 * float(h.rs)
		if not (M > 0.0): continue
		var x: Vector3 = -(h.pos as Vector3) / M
		var a := clampf(float(h.get("spin", 0.0)), 0.0, 0.998)
		var z := -x.y                     # the spin axis is world −Y (toKS)
		var rho2 := x.length_squared()
		var r2 := 0.5 * (rho2 - a * a + sqrt(pow(rho2 - a * a, 2.0) + 4.0 * a * a * z * z))
		var r := sqrt(maxf(r2, 1e-12))
		f += 2.0 * r * r2 / (r2 * r2 + a * a * z * z)
	return 1.0 / sqrt(1.0 - f) if f < 0.999 else sqrt(1.0 + f)

## March this frame. `p`: holes (Array of {pos: camera-relative Vector3, rs: scene
## units, spin: a* ≥ 0, prograde with the disc}), basis (camera world Basis), fov (rad), aspect, time, disc_intensity,
## disc_temp, disc_tpeak_phys, disc_outer.
func dispatch(p: Dictionary) -> void:
	var holes: Array = p.holes
	var b: Basis = p.basis
	var f := PackedFloat32Array(); f.resize(UBO_FLOATS)
	var non_rotating := true
	for k in MAX_HOLES:
		if k < holes.size():
			var hp: Vector3 = holes[k].pos
			f[k * 4 + 0] = hp.x; f[k * 4 + 1] = hp.y; f[k * 4 + 2] = hp.z
			f[k * 4 + 3] = holes[k].rs
			var t := disc_terms(float(holes[k].get("spin", 0.0)))
			var s := (MAX_HOLES + k) * 4
			f[s] = t.a; f[s + 1] = 0.5 * float(t.isco); f[s + 2] = 1.0 / float(t.peak); f[s + 3] = t.x0
			non_rotating = non_rotating and f[s] == 0.0
			for i in 3:
				f[(2 * MAX_HOLES + k) * 4 + i] = t.roots[i]
				f[(3 * MAX_HOLES + k) * 4 + i] = t.c[i]
	var o := MAX_HOLES * 4 * 4
	f[o + 0] = b.x.x; f[o + 1] = b.x.y; f[o + 2] = b.x.z
	f[o + 4] = b.y.x; f[o + 5] = b.y.y; f[o + 6] = b.y.z
	f[o + 8] = b.z.x; f[o + 9] = b.z.y; f[o + 10] = b.z.z
	# camPos is zero: the floating origin puts the camera at the origin.
	f[o + 15] = p.fov
	f[o + 16] = p.aspect; f[DISC_TIME_INDEX] = p.time; f[o + 18] = p.disc_intensity; f[o + 19] = p.disc_temp
	f[o + 20] = p.disc_tpeak_phys; f[o + 21] = p.disc_outer; f[o + 22] = float(mini(holes.size(), MAX_HOLES))
	var bytes := f.to_byte_array()
	var flags := int(RayPipeline.SINGLE_HOLE) if holes.size() == 1 else 0
	if non_rotating: flags |= RayPipeline.NON_ROTATING
	RenderingServer.call_on_render_thread(_dispatch_rt.bind(bytes, flags))

func _dispatch_rt(bytes: PackedByteArray, flags: int) -> void:
	if _kernel == null or not _kernel.valid() or not _march0.is_valid() or not _march1.is_valid():
		return
	# Both textures depend only on this uniform block and their dimensions.
	if bytes == _marched_params:
		return
	if not _disc_mask.is_valid(): _disc_mask = RDU.make_tex(_mw, _mh, RenderingDevice.DATA_FORMAT_R8_UNORM)
	# Build the footprint on the first disc-only update after the view settles.
	# Rays outside it depend on every packed input except time.
	var rays := bytes.duplicate()
	rays.encode_u32(DISC_TIME_INDEX * 4, 0)
	var stationary := rays == _ray_params
	var disc_mode := DiscUpdate.FULL
	if stationary: disc_mode = DiscUpdate.REUSE_MASK if _disc_mask_ready else DiscUpdate.BUILD_MASK
	var dev := RDU.rd()
	dev.buffer_update(_ubo, 0, bytes.size(), bytes)
	RDU.dispatch(_kernel, [RDU.u_image(0, _march0), RDU.u_image(1, _march1), RDU.u_ubo(2, _ubo),
		RDU.u_image(3, _disc_mask)], _mw, _mh, RDU.pack([disc_mode]), _pipeline_rt(flags))
	_marched_params = bytes
	_ray_params = rays
	_disc_mask_ready = stationary

func release() -> void:
	RenderingServer.call_on_render_thread(func():
		# empty the wrappers first: see PostFX._resize_rt
		tex0.texture_rd_rid = RID(); tex1.texture_rd_rid = RID()
		RDU.free_rid(_march0); RDU.free_rid(_march1); RDU.free_rid(_ubo)
		RDU.free_rid(_disc_mask)
		for pipeline in _pipelines.values(): RDU.free_rid(pipeline)
		_pipelines.clear()
		if _kernel: _kernel.release())
