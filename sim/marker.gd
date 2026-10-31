class_name Marker
extends RefCounted

# Point-source fallback below the pixel limit. A body with an apparent magnitude
# (set_magnitude) is drawn at that brightness on the sky's own flux scale.
# Depth-tested, additive, no depth write; temperature-pass coverage is discarded.
# Placed under world_root independently of the body visual. See docs/godot.md.

const SHADER := preload("res://shaders/bodies/marker_point.gdshader")

# Crossover band: above FADE_OUT_PX the mesh alone, below FADE_IN_PX the marker
# alone, both between (the marker's core matches the disc it replaces).
const FADE_IN_PX := 2.5
const FADE_OUT_PX := 7.0
# Drawn size of the marker quad. The visible core is a small fraction of this;
# the rest is the halo falloff, which needs room or it clips into a square.
const MARKER_QUAD_PX := 14.0

const NO_CULL_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

var mesh: MeshInstance3D
var material: ShaderMaterial
var magnitude := NAN
var _base_gain := 1.0

# The Sun's apparent V at 1 AU, and its absolute V.
const M_SUN_V := -26.74
const M_SUN_ABS_V := 4.83
const AU_PER_PC := 206264.806247
# Mallama & Hilton (2018), Astron. Comput. 25, 10: V(1,0) and the phase law in α
# (degrees) as polynomial coefficients from α¹ up. Saturn is its globe alone, Mercury
# to 170°, Venus below 163.7°. The Moon is Allen's Astrophysical Quantities (2000).
const PLANET_V := {
	"Mercury": [-0.613, [6.3280e-2, -1.6336e-3, 3.3644e-5, -3.4265e-7, 1.6893e-9, -3.0334e-12]],
	"Venus":   [-4.384, [-1.044e-3, 3.687e-4, -2.814e-6, 8.938e-9]],
	"Earth":   [-3.99, [-1.060e-3, 2.054e-4]],
	"Mars":    [-1.601, [2.267e-2, -1.302e-4]],
	"Jupiter": [-9.395, [-3.7e-4, 6.16e-4]],
	"Saturn":  [-8.914, [1.825e-3, 1.0e-4]],
	"Uranus":  [-7.110, [6.587e-3, 1.045e-4]],
	"Neptune": [-7.00, [7.944e-3, 9.617e-5]],
	"Moon":    [0.21, [2.6e-2, 0.0, 0.0, 4.0e-9]],
}
# The marker's core and halo integrate to this many pixels² of radiance at gain 1.
const MARKER_FLUX_PX2 := 18.6

# Apparent diameter in pixels: one pixel spans (2·z·tan(f/2))/H at distance z. (Also
# exported by sim/scale.gd.)
static func _pixels_per_world_unit(dist: float, fov_rad: float, viewport_h: float) -> float:
	return viewport_h / maxf(2.0 * dist * tan(fov_rad / 2.0), 1e-30)

static func _apparent_pixels(radius_scene: float, dist: float, fov_rad: float, viewport_h: float) -> float:
	return 2.0 * radius_scene * _pixels_per_world_unit(dist, fov_rad, viewport_h)

## opts: { color: Color (linear) or int (sRGB hex → linear),
##         teff: float (K, 0 = publishes nothing), gain: float = 1 }
static func create_marker(opts: Dictionary) -> Marker:
	return Marker.new(opts)

func _init(opts: Dictionary) -> void:
	var c = opts.get("color", Color(1, 1, 1))
	var col: Color = c if c is Color else U.lin(int(c))
	var teff: float = float(U.nz(opts.get("teff"), 0.0))
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("uColor", Vector3(col.r, col.g, col.b))
	material.set_shader_parameter("uOpacity", 0.0)
	_base_gain = float(U.nz(opts.get("gain"), 1.0))
	material.set_shader_parameter("uGain", _base_gain)
	material.set_shader_parameter("uSel", 0.0)
	material.set_shader_parameter("uTempA", minf(log(maxf(teff, 1.0)) / 25.33, 0.98) if teff > 0.0 else 0.0)
	material.render_priority = 3
	mesh = MeshInstance3D.new()
	mesh.name = "Marker"
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	mesh.mesh = q
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.custom_aabb = NO_CULL_AABB       # it is one quad, and its own scale is dynamic
	mesh.visible = false

## Per frame, with the camera-relative position and rendered radius. Returns the
## marker's opacity (whether the marker is carrying the body).
func update(camera: Camera3D, pos_rel: Vector3, radius_scene: float, viewport_h: float, selected := false) -> float:
	material.set_shader_parameter("uSel", 1.0 if selected else 0.0)
	var cam_p := camera.global_position if (camera != null and camera.is_inside_tree()) else Vector3.ZERO
	var dist := cam_p.distance_to(pos_rel)
	var fov_rad := deg_to_rad(camera.fov if camera != null else 50.0)
	var px := _apparent_pixels(radius_scene, dist, fov_rad, viewport_h)

	# 1 when the body is sub-pixel, 0 once the mesh is comfortably resolved
	var t := clampf((FADE_OUT_PX - px) / (FADE_OUT_PX - FADE_IN_PX), 0.0, 1.0)
	var opacity := t * t * (3.0 - 2.0 * t)          # smoothstep — no popping
	material.set_shader_parameter("uOpacity", opacity)
	mesh.visible = opacity > 0.002
	if not mesh.visible:
		return 0.0

	mesh.position = pos_rel
	if not is_nan(magnitude):
		# Radiance × pixel² of a sky star of this magnitude, spread over the marker's profile.
		var pix_sr := pow(1.0 / _pixels_per_world_unit(1.0, fov_rad, viewport_h), 2.0)
		# Brighter than the full Moon only blooms harder; fainter than the floor is lost.
		var m := clampf(magnitude, -12.7, SkyModel.STAR_FLUX_FLOOR_MAG)
		var flux := SkyModel.STAR_FLUX * pow(10.0, -0.4 * (m - SkyModel.STAR_FLUX_MAG))
		material.set_shader_parameter("uGain", flux / (pix_sr * MARKER_FLUX_PX2))
	# hold a constant on-screen size, which is the whole point of the marker
	var s := MARKER_QUAD_PX / _pixels_per_world_unit(dist, fov_rad, viewport_h)
	mesh.scale = Vector3.ONE * maxf(s, 1e-30)
	return opacity

## Apparent V of `b` seen from `obs` (AU), lit by `star`. Planets named in PLANET_V use
## Mallama & Hilton's fits (for a Sun-like star, scaled by its luminosity); any other
## reflector a Lambert sphere with its geometric albedo; a star its luminosity as V.
## NAN for anything else (holes and compact stars keep their fixed emitter gain).
static func apparent_magnitude(b: Body, obs: DVec3, star: Body) -> float:
	var delta := maxf(b.pos.distance_to(obs), 1e-12)
	if b.type == "star":
		return M_SUN_ABS_V - 2.5 * U.log10(maxf(float(U.nz(b.luminosity, 1.0)), 1e-12)) \
			+ 5.0 * U.log10(delta / AU_PER_PC / 10.0)
	if not b.type in ["planet", "world", "gas-giant"] or star == null: return NAN
	var r := maxf(b.pos.distance_to(star.pos), 1e-12)
	var to_star := star.pos.sub(b.pos).normalized()
	var to_obs := obs.sub(b.pos).normalized()
	var alpha := acos(clampf(to_star.dot(to_obs), -1.0, 1.0))
	var lum := maxf(float(U.nz(star.luminosity, 1.0)), 1e-12)
	if PLANET_V.has(b.name):
		var row: Array = PLANET_V[b.name]
		var a_deg := rad_to_deg(alpha)
		var phase := 0.0
		var p := a_deg
		for c in row[1]:
			phase += float(c) * p
			p *= a_deg
		return float(row[0]) + 5.0 * U.log10(r * delta) + phase - 2.5 * U.log10(lum)
	var albedo := float(U.nz(b.spec.get("albedo"), 0.3))
	var lambert := (sin(alpha) + (PI - alpha) * cos(alpha)) / PI
	var f := albedo * pow(b.radius / delta, 2.0) * maxf(lambert, 1e-9) * lum / (r * r)
	return M_SUN_V - 2.5 * U.log10(f)

func dispose() -> void:
	if is_instance_valid(mesh):
		mesh.queue_free()
