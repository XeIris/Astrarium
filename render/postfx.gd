class_name PostFX
extends RefCounted

# POST-PROCESSING: HDR bloom and filmic tone mapping, the one tone curve (Godot's
# tonemapper, glow and auto-exposure are off on every viewport; render/pipeline.gd).
# The chain (shaders/post/*.glsl, compute, in order in one callback):
#   compose    → HDR buffer (half-float, temperature in a)
#   [surface   → the atmosphere, when standing on a world: sim/skyview.gd]
#   [remap     → spectral re-imaging, outside visible light]
#   bright pass, then a 5-level dual-filter down/upsample bloom
#   composite: ACES RRT+ODT fit, vignette, grain, ordered dither → 8-bit sRGB
# The curve compresses rather than clips, so an emitter 40× over white keeps its
# colour at the edges.

const MIPS := 5

## The defaults the web build's settings panel wrote on load (FX_DEFAULTS):
## the uniforms' own initial values are overwritten before the first frame.
var bloom := 0.55
## Camera exposure is applied once, after the HDR passes and before ACES.
var exposure := 1.0
var flight_exposure := 1.0
var threshold := 1.0
var knee := 0.7
var radius := 1.0
var vignette := 0.35
var grain := 0.02

var band := Spectrum.VISIBLE_BAND
var _scene_max_t := 5800.0
var _theta := 0.0
var _tref := 5800.0
const STRETCH := 120.0

var _w := 1
var _h := 1
var _sampler := RID()
var _hdr := RID()         # composed HDR buffer
var _hdr2 := RID()        # surface-composited HDR buffer
var _banded := RID()
var _down: Array[RID] = []
var _up: Array[RID] = []
var _dsz: Array[Vector2i] = []
var _final := RID()
var final_tex := Texture2DRD.new()

var k_compose: RDU.Kernel
var k_remap: RDU.Kernel
var k_bright: RDU.Kernel
var k_down: RDU.Kernel
var k_up: RDU.Kernel
var k_composite: RDU.Kernel

func _init() -> void:
	RenderingServer.call_on_render_thread(_init_rt)

func _init_rt() -> void:
	_sampler = RDU.linear_sampler()
	k_compose = RDU.Kernel.new("res://shaders/post/compose.glsl")
	k_remap = RDU.Kernel.new("res://shaders/post/remap.glsl")
	k_bright = RDU.Kernel.new("res://shaders/post/bright.glsl")
	k_down = RDU.Kernel.new("res://shaders/post/down.glsl")
	k_up = RDU.Kernel.new("res://shaders/post/up.glsl")
	k_composite = RDU.Kernel.new("res://shaders/post/composite.glsl")
	_apply_band_gain()

## Switch the imaging band. VISIBLE_BAND bypasses the remap entirely.
func set_band(i: int) -> Dictionary:
	band = clampi(i, 0, Spectrum.BANDS.size() - 1)
	_apply_band_gain()
	return Spectrum.BANDS[band]

## The hottest emitter's temperature, which anchors the band gain (expose for the
## brightest target, or a 5000 K scene is black above the visible).
func set_scene_temp(t: float) -> void:
	if not (t > 0.0) or absf(t - _scene_max_t) < _scene_max_t * 0.01:
		return
	_scene_max_t = t
	_apply_band_gain()

func _apply_band_gain() -> void:
	var d := Spectrum.band_uniform_data(band, _scene_max_t)
	_theta = d.theta
	_tref = d.tref

func set_size(w: int, h: int) -> void:
	_w = maxi(w, 1); _h = maxi(h, 1)
	RenderingServer.call_on_render_thread(_resize_rt)

func size() -> Vector2i:
	return Vector2i(_w, _h)

## Rebind before freeing: freeing an RD texture a Texture2DRD still wraps frees the
## engine's views too ("Attempted to free invalid ID" on every resize).
func _resize_rt() -> void:
	# The surface and remap targets are allocated only when those modes are used
	# (16 bytes per pixel otherwise).
	var had_hdr2 := _hdr2.is_valid()
	var had_banded := _banded.is_valid()
	var old: Array[RID] = [_hdr, _final]
	if had_hdr2: old.append(_hdr2)
	if had_banded: old.append(_banded)
	old.append_array(_down); old.append_array(_up)
	_hdr = RDU.make_tex(_w, _h)
	_hdr2 = RDU.make_tex(_w, _h) if had_hdr2 else RID()
	_banded = RDU.make_tex(_w, _h) if had_banded else RID()
	_final = RDU.make_tex(_w, _h, RDU.RGBA8)
	final_tex.texture_rd_rid = _final
	for r in old:
		RDU.free_rid(r)
	_down.clear(); _up.clear(); _dsz.clear()
	var mw := _w; var mh := _h
	for i in MIPS:
		mw = maxi(1, mw / 2); mh = maxi(1, mh / 2)
		_dsz.append(Vector2i(mw, mh))
		_down.append(RDU.make_tex(mw, mh))
		_up.append(RDU.make_tex(mw, mh))

func _ensure_optional_targets(surface: bool, spectral: bool) -> void:
	if surface and not _hdr2.is_valid():
		_hdr2 = RDU.make_tex(_w, _h)
	if spectral and not _banded.is_valid():
		_banded = RDU.make_tex(_w, _h)

## Release every RD resource. The wrapper is emptied first, for the reason
## _resize_rt gives.
func release() -> void:
	RenderingServer.call_on_render_thread(_free_rt)

func _free_rt() -> void:
	final_tex.texture_rd_rid = RID()
	for r in [_hdr, _hdr2, _banded, _final, _sampler]:
		RDU.free_rid(r)
	for r in _down + _up:
		RDU.free_rid(r)
	_hdr = RID(); _hdr2 = RID(); _banded = RID(); _final = RID(); _sampler = RID()
	_down.clear(); _up.clear()
	for k in [k_compose, k_remap, k_bright, k_down, k_up, k_composite]:
		if k: k.release()
	k_composite = null

## Run the chain. Render thread only. `inputs`: scene, temp, local (RD RIDs; may be
## invalid), mode (0/1/2), use_temp, surface (dispatch(src, dst, w, h) or null),
## time (for grain).
func render_rt(inputs: Dictionary) -> void:
	if k_composite == null or not _final.is_valid():
		return
	var scene: RID = inputs.scene
	if not scene.is_valid():
		return
	var temp: RID = inputs.get("temp", RID())
	var local: RID = inputs.get("local", RID())
	if not temp.is_valid(): temp = scene
	if not local.is_valid(): local = scene
	var surface = inputs.get("surface", null)
	var use_spectral := band != Spectrum.VISIBLE_BAND
	_ensure_optional_targets(surface != null, use_spectral)

	# 0. compose the HDR buffer (+ temperature in alpha)
	RDU.dispatch(k_compose, [
		RDU.u_sampled(0, _sampler, scene), RDU.u_sampled(1, _sampler, temp),
		RDU.u_sampled(2, _sampler, local), RDU.u_image(3, _hdr)],
		_w, _h, RDU.pack([inputs.mode, 1.0 if inputs.use_temp else 0.0]))
	var src := _hdr

	# 0b. the surface view's atmosphere composites over the scene it was given
	if surface != null:
		surface.dispatch(src, _hdr2, _w, _h)
		src = _hdr2

	# 1. spectral re-imaging, before bloom (bloom is the instrument's PSF on the band
	# image).
	if band != Spectrum.VISIBLE_BAND:
		RDU.dispatch(k_remap, [RDU.u_sampled(0, _sampler, src), RDU.u_image(1, _banded)],
			_w, _h, RDU.pack([_theta, _tref, band, STRETCH]))
		src = _banded

	# 2. bright pass into mip 0 (half resolution)
	RDU.dispatch(k_bright, [RDU.u_sampled(0, _sampler, src), RDU.u_image(1, _down[0])],
		_dsz[0].x, _dsz[0].y, RDU.pack([1.0 / _w, 1.0 / _h, threshold, knee]))

	# 3. progressive downsample
	for i in range(1, MIPS):
		RDU.dispatch(k_down, [RDU.u_sampled(0, _sampler, _down[i - 1]), RDU.u_image(1, _down[i])],
			_dsz[i].x, _dsz[i].y, RDU.pack([1.0 / _dsz[i - 1].x, 1.0 / _dsz[i - 1].y]))

	# 4. upsample + accumulate back up the chain
	var acc: RID = _down[MIPS - 1]
	for i in range(MIPS - 1, 0, -1):
		RDU.dispatch(k_up, [RDU.u_sampled(0, _sampler, acc), RDU.u_sampled(1, _sampler, _down[i - 1]),
			RDU.u_image(2, _up[i - 1])],
			_dsz[i - 1].x, _dsz[i - 1].y, RDU.pack([1.0 / _dsz[i].x, 1.0 / _dsz[i].y, radius]))
		acc = _up[i - 1]

	# 5. composite to 8-bit sRGB
	RDU.dispatch(k_composite, [RDU.u_sampled(0, _sampler, src), RDU.u_sampled(1, _sampler, acc),
		RDU.u_image(2, _final)],
		_w, _h, RDU.pack([bloom, exposure * (flight_exposure if int(inputs.mode) == 1 else 1.0),
			vignette, grain, inputs.get("time", 0.0)]))

## Read the last composited frame back (RENDER THREAD, after the hook ran).
func read_final_rt() -> Image:
	var data := RDU.rd().texture_get_data(_final, 0)
	return Image.create_from_data(_w, _h, false, Image.FORMAT_RGBA8, data)

## Read the HDR buffer (debug/art checks).
func read_hdr_rt() -> Image:
	var data := RDU.rd().texture_get_data(_hdr, 0)
	return Image.create_from_data(_w, _h, false, Image.FORMAT_RGBAH, data)
