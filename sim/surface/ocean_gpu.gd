class_name OceanGPU
extends RefCounted

# OceanField's four cascades run each drawn frame on the RenderingDevice (shaders/surface/ocean_fft.glsl), into
# textures the water shader samples. Without a RenderingDevice (headless) it allocates nothing and `ready` stays
# false. Render-thread work goes through call_on_render_thread, as the other compute passes do. docs/godot.md.

const SHADER := "res://shaders/surface/ocean_fft.glsl"

var field: OceanField
## Per cascade: what the water shader samples.
var disp: Array[Texture2DRD] = []
var deriv: Array[Texture2DRD] = []
var ready := false
var _kernel: RDU.Kernel = null
var _h0: Array[RID] = []
var _wk: Array[RID] = []
var _fa: Array[RID] = []
var _fb: Array[RID] = []
var _disp: Array[RID] = []
var _deriv: Array[RID] = []
var _read := {}

func _init(f: OceanField) -> void:
	field = f
	for c in OceanField.CASCADES:
		disp.append(Texture2DRD.new())
		deriv.append(Texture2DRD.new())
	if not RDU.available(): return
	RenderingServer.call_on_render_thread(_init_rt.bind(_spectra()))

## Re-upload the amplitudes after OceanField.set_wind.
func refill() -> void:
	if not RDU.available(): return
	RenderingServer.call_on_render_thread(_upload_rt.bind(_spectra()))

## Run the cascades at site time `t`, `dt` since the last frame (for the foam's fading).
func run(t: float, dt: float) -> void:
	if not RDU.available(): return
	RenderingServer.call_on_render_thread(_run_rt.bind(t, dt))

## Read one cascade's (Dx, h, Dz, ∂Dx/∂z) back, for the checks: a PackedFloat32Array of N² × 4, or empty.
func read_back(c: int) -> PackedFloat32Array:
	if not RDU.available(): return PackedFloat32Array()
	RenderingServer.call_on_render_thread(_read_rt.bind(c))
	RenderingServer.force_sync()
	return _read.get(c, PackedFloat32Array())

func dispose() -> void:
	ready = false
	if not RDU.available(): return
	RenderingServer.call_on_render_thread(_free_rt)

# h̃₀(k) beside h̃₀(−k), and ω beside k, as float images, from the CPU's doubles.
func _spectra() -> Array:
	var out := []
	for c in OceanField.CASCADES:
		var nn := field.n[c]
		var dk := TAU / field.L[c]
		var h := PackedFloat32Array(); h.resize(nn * nn * 4)
		var w := PackedFloat32Array(); w.resize(nn * nn * 4)
		for iz in nn:
			for ix in nn:
				var i := iz * nn + ix
				var j := ((nn - iz) % nn) * nn + (nn - ix) % nn
				h[i * 4] = field.h0r[c][i]; h[i * 4 + 1] = field.h0i[c][i]
				h[i * 4 + 2] = field.h0r[c][j]; h[i * 4 + 3] = field.h0i[c][j]
				w[i * 4] = field.omega[c][i]
				w[i * 4 + 1] = dk * float(OceanField._signed(ix, nn))
				w[i * 4 + 2] = dk * float(OceanField._signed(iz, nn))
		out.append([h.to_byte_array(), w.to_byte_array()])
	return out

static func _image(nn: int, fmt: int) -> RID:
	var f := RDTextureFormat.new()
	f.width = nn
	f.height = nn
	f.format = fmt
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return RDU.rd().texture_create(f, RDTextureView.new())

func _init_rt(spectra: Array) -> void:
	_kernel = RDU.Kernel.new(SHADER)
	if not _kernel.valid(): return
	var f32 := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	for c in OceanField.CASCADES:
		var nn := field.n[c]
		_h0.append(_image(nn, f32)); _wk.append(_image(nn, f32))
		_fa.append(_image(nn, f32)); _fb.append(_image(nn, f32))
		_disp.append(_image(nn, f32)); _deriv.append(_image(nn, RDU.RGBA16F))
		RDU.rd().texture_clear(_disp[c], Color(0, 0, 0, 0), 0, 1, 0, 1)
		disp[c].texture_rd_rid = _disp[c]
		deriv[c].texture_rd_rid = _deriv[c]
	_upload_rt(spectra)
	ready = true

func _upload_rt(spectra: Array) -> void:
	if _h0.is_empty(): return
	for c in OceanField.CASCADES:
		RDU.rd().texture_update(_h0[c], 0, spectra[c][0])
		RDU.rd().texture_update(_wk[c], 0, spectra[c][1])

func _run_rt(t: float, dt: float) -> void:
	if not ready: return
	var dev := RDU.rd()
	for c in OceanField.CASCADES:
		var nn := field.n[c]
		var uniforms: Array[RDUniform] = [RDU.u_image(0, _h0[c]), RDU.u_image(1, _wk[c]), RDU.u_image(2, _fa[c]),
			RDU.u_image(3, _fb[c]), RDU.u_image(4, _disp[c]), RDU.u_image(5, _deriv[c])]
		var us := UniformSetCacheRD.get_cache(_kernel.shader, 0, uniforms)
		for mode in 4:
			var push := RDU.pack([mode, nn, t, dt, 0.0, 0.0, 0.0, 0.0])
			var cl := dev.compute_list_begin()
			dev.compute_list_bind_compute_pipeline(cl, _kernel.pipeline)
			dev.compute_list_bind_uniform_set(cl, us, 0)
			dev.compute_list_set_push_constant(cl, push, push.size())
			dev.compute_list_dispatch(cl, nn, 1, 1)
			dev.compute_list_end()

func _read_rt(c: int) -> void:
	if not ready: return
	_read[c] = RDU.rd().texture_get_data(_disp[c], 0).to_float32_array()

func _free_rt() -> void:
	for c in disp.size():
		disp[c].texture_rd_rid = RID()
		deriv[c].texture_rd_rid = RID()
	for list in [_h0, _wk, _fa, _fb, _disp, _deriv]:
		for r in list: RDU.free_rid(r)
		list.clear()
	if _kernel != null: _kernel.release()
	_kernel = null
