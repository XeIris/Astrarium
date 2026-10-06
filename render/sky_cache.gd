class_name SkyCache
extends RefCounted

# Per-direction cache of the sky's diffuse emission and dust depth (sky_diffuseAdd
# and sky_tau in sky.gdshaderinc). Point sources and the star-density field stay
# analytic: docs/physics/sky.md#the-diffuse-cache.

## Texels per face edge: about 4 mrad at a face centre, several texels across the
## finest diffuse noise. One RGBA16F atlas of 3x2 faces uses 12.6 MB.
const FACE := 512
## Uniforms the cached layers read; any change re-renders the cache.
const INPUTS := ["uGalNormal", "uGalCenter", "uGalEast", "uVisibleBand", "uExtCoef",
	"uGlow", "uBulge", "uDust", "uHii", "uRefl", "uBandScaleH", "uBulgeSize",
	"uwSynch", "uwH21", "uwCmb", "uwDustEm", "uwGlow", "uwBulge", "uwHii", "uwRefl",
	"uwXrayBg", "uwPion"]

enum { STALE, RENDERING, READY }

## False evaluates every layer live (checks compare the two paths).
var enabled := true
var state := STALE
var viewport: SubViewport
## The generator material; it belongs in pipe.sky_materials to receive sky uniforms.
var material: ShaderMaterial
var _parent: SubViewport
var _users: Array
var _signature := []

## `parent` must render after the cache: a child viewport is drawn before its parent.
## `users` are the sky materials that sample it.
func _init(parent: SubViewport, users: Array) -> void:
	_parent = parent
	_users = users
	viewport = SubViewport.new()
	viewport.name = "SkyCache"
	viewport.size = Vector2i(3 * FACE, 2 * FACE)
	viewport.use_hdr_2d = true
	viewport.disable_3d = true
	# An opaque viewport forces alpha to 1, and alpha holds the dust depth.
	viewport.transparent_bg = true
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/sky/sky_cache.gdshader")
	material.set_shader_parameter("uCacheFace", float(FACE))
	var rect := ColorRect.new()
	rect.size = Vector2(viewport.size)
	rect.material = material
	viewport.add_child(rect)
	parent.add_child(viewport)
	for m in users:
		m.set_shader_parameter("uSkyCache", viewport.get_texture())
	_publish(0.0)

## Once per frame before the sky renders. An input change waits for one unchanged
## frame (a dragged slider must not re-render every frame), then renders once; rays
## evaluate live until that render has completed. Nothing advances while the parent
## (and so the sky) is not drawn.
func sync() -> void:
	if _parent.render_target_update_mode == SubViewport.UPDATE_DISABLED: return
	var signature := INPUTS.map(func(n: String): return material.get_shader_parameter(n))
	if signature != _signature or not enabled:
		_signature = signature
		if state != STALE:
			state = STALE
			_publish(0.0)
		return
	if state == STALE:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		state = RENDERING
	elif state == RENDERING:
		state = READY
		_publish(float(FACE))

func _publish(face: float) -> void:
	for m in _users:
		m.set_shader_parameter("uSkyCacheFace", face)
