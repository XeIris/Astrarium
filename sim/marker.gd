class_name Marker
extends RefCounted

# Point-source fallback below the pixel limit; brightness falls with distance.
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
	material.set_shader_parameter("uGain", float(U.nz(opts.get("gain"), 1.0)))
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
	# hold a constant on-screen size, which is the whole point of the marker
	var s := MARKER_QUAD_PX / _pixels_per_world_unit(dist, fov_rad, viewport_h)
	mesh.scale = Vector3.ONE * maxf(s, 1e-30)
	return opacity

## The quad's current world size, for the pick radius.
func quad_scale() -> float:
	return mesh.scale.x

func dispose() -> void:
	if is_instance_valid(mesh):
		mesh.queue_free()
