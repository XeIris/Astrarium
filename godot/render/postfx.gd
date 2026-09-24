class_name PostFX
extends RefCounted

# ============================================================================
# POST-PROCESSING — HDR bloom + filmic tone mapping.
# ----------------------------------------------------------------------------
# This is the single biggest reason the sim used to read as "cartoony": every
# emitter was clamped to 1.0 at the framebuffer, so a star, a flare and the
# inner edge of an accretion disc all resolved to exactly the same flat white.
# Real cameras and real eyes do neither of those things — they bloom, and they
# roll highlights off along a filmic curve instead of clipping.
#
# The chain (shaders/post/*.glsl, all compute, run in order in one callback):
#   compose  →  HDR buffer (half-float, values well above 1, temperature in a)
#   [surface →  the atmosphere, when standing on a world: sim/skyview.gd]
#   [remap   →  spectral re-imaging, when not in visible light]
#   bright pass, then a 5-level progressive down/upsample bloom
#             (the "dual filter" used by Unreal/CoD — cheap, and it produces a
#             wide, smooth halo instead of a visible gaussian donut)
#   composite: ACES RRT+ODT fit, vignette, grain, ordered dither → 8-bit sRGB
#
# Because the tone curve compresses rather than clips, an object can now be
# 40× over white and still show its own colour at the edges — which is exactly
# how the Doppler-boosted side of a disc, or the core of an O star, behaves.
#
# Godot's own tonemapper, glow and auto-exposure are all OFF on every viewport
# feeding this (see render/pipeline.gd): this is the ONE tone curve, as it was
# in the web build.
# ============================================================================

const MIPS := 5

## The defaults the web build's settings panel wrote on load (FX_DEFAULTS):
## the uniforms' own initial values are overwritten before the first frame.
var bloom := 0.55
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

## The temperature of the hottest emitter in the scene. The band gain is
## anchored to it — an observer exposes for the brightest target in the field,
## and without that a preset with only 5000 K stars would render as a black
## frame in every band above the visible.
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

func _resize_rt() -> void:
	for r in [_hdr, _hdr2, _banded, _final]:
		RDU.free_rid(r)
	for r in _down + _up:
		RDU.free_rid(r)
	_hdr = RDU.make_tex(_w, _h)
	_hdr2 = RDU.make_tex(_w, _h)
	_banded = RDU.make_tex(_w, _h)
	_final = RDU.make_tex(_w, _h, RDU.RGBA8)
	final_tex.texture_rd_rid = _final
	_down.clear(); _up.clear(); _dsz.clear()
	var mw := _w; var mh := _h
	for i in MIPS:
		mw = maxi(1, mw / 2); mh = maxi(1, mh / 2)
		_dsz.append(Vector2i(mw, mh))
		_down.append(RDU.make_tex(mw, mh))
		_up.append(RDU.make_tex(mw, mh))

## Run the whole chain. RENDER THREAD ONLY (the pipeline's hook callback).
## `inputs`: scene, temp, local (RD RIDs; may be invalid), mode (0/1/2),
## use_temp (bool), surface (an object with dispatch(src, dst, w, h), or null),
## time (seconds, for the grain).
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

	# 0. compose the HDR buffer (+ temperature in alpha)
	RDU.dispatch(k_compose, [
		RDU.u_sampled(0, _sampler, scene), RDU.u_sampled(1, _sampler, temp),
		RDU.u_sampled(2, _sampler, local), RDU.u_image(3, _hdr)],
		_w, _h, RDU.pack([inputs.mode, 1.0 if inputs.use_temp else 0.0]))
	var src := _hdr

	# 0b. the surface view's atmosphere composites over the scene it was given
	var surface = inputs.get("surface", null)
	if surface != null:
		surface.dispatch(src, _hdr2, _w, _h)
		src = _hdr2

	# 1. spectral re-imaging, when we are not looking in visible light. It runs
	# BEFORE the bloom: bloom is the instrument's point-spread function, so it
	# has to spread the band image.
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
		_w, _h, RDU.pack([bloom, 1.0, vignette, grain, inputs.get("time", 0.0)]))

## Read the last composited frame back (RENDER THREAD, after the hook ran).
func read_final_rt() -> Image:
	var data := RDU.rd().texture_get_data(_final, 0)
	return Image.create_from_data(_w, _h, false, Image.FORMAT_RGBA8, data)

## Read the HDR buffer (debug/art checks).
func read_hdr_rt() -> Image:
	var data := RDU.rd().texture_get_data(_hdr, 0)
	return Image.create_from_data(_w, _h, false, Image.FORMAT_RGBAH, data)
