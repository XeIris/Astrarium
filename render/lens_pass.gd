class_name LensPass
extends RefCounted

# ============================================================================
# BLACK HOLE — general-relativistic ray marcher + volumetric accretion disc.
# ============================================================================
# Everything you see of a black hole is light that *missed*. There is no
# surface to shade, so this is a full-screen pass that integrates null
# geodesics backwards from the eye and reports what each one ran into.
#
# WHAT IS PHYSICALLY MODELLED
#
#  · Null geodesics. In Schwarzschild geometry the orbit equation for a photon
#    reduces (via Binet) to a Cartesian acceleration
#        d²x/dλ² = −(3/2) r_s h² x̂ / r⁵ ,    h = |x × v|, |v| = 1
#    which is EXACT for light, not a Newtonian approximation. Integrated with
#    an RK2 midpoint step that shrinks as (r − r_s), so rays that graze the
#    photon sphere at 1.5 r_s are resolved instead of tunnelling through it.
#
#  · The shadow. Nothing is drawn for the hole itself. A ray that crosses the
#    horizon simply stops and returns whatever disc light it had already
#    collected. The dark region that results has an apparent radius of
#    (√27/2)·r_s ≈ 2.6 r_s — noticeably LARGER than the horizon, because the
#    photon sphere is what casts it.
#
#  · The photon ring. Rays with impact parameter near the critical value wind
#    around the hole one or more times, crossing the disc on each pass, and
#    stack that emission into the thin brilliant ring that hugs the shadow.
#    It is not drawn — it falls out of the integration, which is the point.
#
#  · Shakura–Sunyaev disc. T(r) ∝ (r_in/r)^¾ · (1 − √(r_in/r))^¼ — the
#    standard thin-disc profile. It vanishes AT the ISCO and peaks a little
#    outside it, so the disc has a genuinely dark inner gap and a hot ridge.
#
#  · Relativistic transfer. The disc orbits at v = √(r_s/2r)/√(1 − r_s/r); the
#    combined Doppler + gravitational factor g = δ·√(1 − r_s/r) is applied to
#    BOTH the observed colour temperature (T_obs = g·T_emit) and the intensity
#    (I_obs ∝ g⁴, from the invariance of I_ν/ν³). That single term is what
#    produces the famous asymmetry: the approaching limb goes blue-white and
#    ~80× brighter, the receding limb sinks into dull red.
#
#  · Volumetric emission/absorption through a flared, geometrically thin slab
#    of height H(r) ∝ r^9/8, so the disc occludes itself and the far side is
#    genuinely seen *through* the near side.
#
# THE FILAMENTARY STRUCTURE
#
#    Magnetorotational turbulence injects eddies, and Keplerian shear —
#    Ω(r) ∝ r^(−3/2) — stretches every one of them into a long thin arc. The
#    noise is sampled in the CO-ROTATING frame, ψ = φ + Ω(r)·t, with the
#    azimuthal axis compressed and the radial axis expanded (~8:1): strands,
#    not clouds.
#
# THE SPLIT. The marcher runs at the LENS SCALE and does not know the sky
# exists: the geodesic integration and the disc integral are per-RAY costs and
# tolerate being traced at half rate, because their result is a smooth field.
# The star field is a per-PIXEL cost and does not, so the sky is evaluated at
# full resolution over the direction field this pass hands over — in the
# background sky shader (shaders/sky/background.gdshader), which is the Godot
# home of the web build's resolve pass. The web build wrote the two outputs as
# a WebGL2 MRT; here the marcher is a compute shader writing two images.
# ============================================================================

const MAX_HOLES := 2

## Default lens scale — the marcher's resolution as a fraction of the display's.
## The pass scales very nearly linearly with pixel count (measured: 3.89x faster
## for 4x fewer pixels), so this is the strongest single control there is.
const DEFAULT_LENS_SCALE := 0.5

var scale := DEFAULT_LENS_SCALE
var _vw := 1
var _vh := 1
var _mw := 1
var _mh := 1
var _march0 := RID()
var _march1 := RID()
var _ubo := RID()
var _kernel: RDU.Kernel
## Texture2DRDs the background sky shaders sample. Their RIDs are swapped in
## place on resize, so a material holding them never needs re-pointing.
var tex0 := Texture2DRD.new()
var tex1 := Texture2DRD.new()

const UBO_FLOATS := 4 * (MAX_HOLES + 6)

func _init() -> void:
	RenderingServer.call_on_render_thread(_init_rt)

func _init_rt() -> void:
	_kernel = RDU.Kernel.new("res://shaders/lens/lens_march.glsl")
	var zero := PackedFloat32Array(); zero.resize(UBO_FLOATS)
	_ubo = RDU.rd().uniform_buffer_create(UBO_FLOATS * 4, zero.to_byte_array())
	_resize_rt()

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
	_mw = w; _mh = h
	var old0 := _march0; var old1 := _march1
	_march0 = RDU.make_tex(w, h)
	_march1 = RDU.make_tex(w, h)
	tex0.texture_rd_rid = _march0
	tex1.texture_rd_rid = _march1
	RDU.free_rid(old0); RDU.free_rid(old1)

## March this frame. `p` carries: holes (Array of {pos: Vector3 camera-relative,
## rs: float scene units}), basis (the camera's world Basis), fov (rad), aspect,
## time, disc_intensity, disc_temp, disc_tpeak_phys, disc_outer.
func dispatch(p: Dictionary) -> void:
	var holes: Array = p.holes
	var b: Basis = p.basis
	var f := PackedFloat32Array(); f.resize(UBO_FLOATS)
	for k in MAX_HOLES:
		if k < holes.size():
			var hp: Vector3 = holes[k].pos
			f[k * 4 + 0] = hp.x; f[k * 4 + 1] = hp.y; f[k * 4 + 2] = hp.z
			f[k * 4 + 3] = holes[k].rs
	var o := MAX_HOLES * 4
	f[o + 0] = b.x.x; f[o + 1] = b.x.y; f[o + 2] = b.x.z
	f[o + 4] = b.y.x; f[o + 5] = b.y.y; f[o + 6] = b.y.z
	f[o + 8] = b.z.x; f[o + 9] = b.z.y; f[o + 10] = b.z.z
	# camPos is zero: the floating origin puts the camera at the origin.
	f[o + 15] = p.fov
	f[o + 16] = p.aspect; f[o + 17] = p.time; f[o + 18] = p.disc_intensity; f[o + 19] = p.disc_temp
	f[o + 20] = p.disc_tpeak_phys; f[o + 21] = p.disc_outer; f[o + 22] = float(mini(holes.size(), MAX_HOLES))
	var bytes := f.to_byte_array()
	RenderingServer.call_on_render_thread(_dispatch_rt.bind(bytes))

func _dispatch_rt(bytes: PackedByteArray) -> void:
	if _kernel == null or not _kernel.valid():
		return
	var dev := RDU.rd()
	dev.buffer_update(_ubo, 0, bytes.size(), bytes)
	RDU.dispatch(_kernel, [RDU.u_image(0, _march0), RDU.u_image(1, _march1), RDU.u_ubo(2, _ubo)], _mw, _mh)

func release() -> void:
	RenderingServer.call_on_render_thread(func():
		# empty the wrappers first: see PostFX._resize_rt
		tex0.texture_rd_rid = RID(); tex1.texture_rd_rid = RID()
		RDU.free_rid(_march0); RDU.free_rid(_march1); RDU.free_rid(_ubo)
		if _kernel: _kernel.release())
