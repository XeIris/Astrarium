class_name Marker
extends RefCounted

# ============================================================================
# THE POINT-SOURCE MARKER — the visual half of sim/scale.js (createMarker).
# The physics half (physicalRadiusAU) is sim/scale.gd.
# ----------------------------------------------------------------------------
# A real telescope has the true-scale problem and solves it this way: below
# the resolution limit a body stops being a disc and becomes a POINT SOURCE.
# Its apparent size stops shrinking (it is pinned at the instrument's
# point-spread function) while its brightness keeps falling as 1/r². So bodies
# are rendered at their true geometric size and, when that drops below a few
# pixels, the mesh cross-fades into a fixed-pixel-size glow. Geometry stays
# honest; visibility is preserved. This is what Celestia and Space Engine do.
#
# The marker itself: a camera-facing quad with an Airy-like profile — a tight
# core plus a broad faint halo, which is what an unresolved source actually
# looks like once optics and the atmosphere are done with it.
#
# Blending is deliberately split. RGB adds (the marker is an emitter, and
# premultiplying by coverage in the shader keeps it energy-consistent), but
# ALPHA takes the MAX. Alpha in this pipeline is not opacity — it is the
# log-encoded true temperature that sim/spectrum.gd reads to re-image the
# frame in a non-visible band (see AGENTS.md). Adding temperatures would be
# meaningless; taking the hottest contributor at a pixel is the correct
# composite. In the Godot temperature pass that max is a no-op against the
# sky (see shaders/bodies/marker_point.gdshader), so the pass discards.
#
# DEPTH. The marker is depth-TESTED (never depth-writing) and drawn at
# render_priority 3, after everything at 0 — as the web's was (renderOrder 3,
# depthTest on). So whatever writes depth in front of it cuts it. On the web
# that is the orbit trails: THREE's LineBasicMaterial keeps depthWrite = true
# even when transparent, the near side of every inner orbit crosses in front
# of the Sun, and the Sun's marker is striped by them in its lower half — with
# correspondingly less bloom. A trail material that does NOT write depth draws
# the full marker and a Sun visibly larger and brighter than the web's
# (measured on #solar: ring means within 5 levels with the trails writing
# depth, 30–50 levels too bright without).
#
# PORT NOTES. The mesh is a child the orchestrator adds under world_root, NOT
# under the body's group, exactly as the web kept it in the scene: its size is
# never coupled to whatever the body's own visual does to its transform.
# update() takes the body's CAMERA-RELATIVE position (the floating origin),
# and places the mesh there itself.
# ============================================================================

const SHADER := preload("res://shaders/bodies/marker_point.gdshader")

# Crossover band. Above FADE_OUT_PX the mesh carries the body on its own and
# the marker is off; below FADE_IN_PX the mesh is sub-pixel mush and the marker
# carries it entirely. Between them both draw, additively, and the handover is
# invisible because the marker's core is about as wide as the disc it replaces.
const FADE_IN_PX := 2.5
const FADE_OUT_PX := 7.0
# Drawn size of the marker quad. The visible core is a small fraction of this;
# the rest is the halo falloff, which needs room or it clips into a square.
const MARKER_QUAD_PX := 14.0

const NO_CULL_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

var mesh: MeshInstance3D
var material: ShaderMaterial

# ----------------------------------------------------------------------------
# Apparent angular DIAMETER of a body, in screen pixels. (Private copies of
# sim/scale.js's pure helpers; sim/scale.gd exports the same two.)
#
# A perspective camera with vertical field of view f maps a viewport of H
# pixels onto 2·z·tan(f/2) world units at distance z, so one pixel spans
# (2·z·tan(f/2))/H there. Dividing the body's diameter by that gives its size
# in pixels — the quantity that decides whether a mesh is worth drawing.
# ----------------------------------------------------------------------------
static func _pixels_per_world_unit(dist: float, fov_rad: float, viewport_h: float) -> float:
	return viewport_h / maxf(2.0 * dist * tan(fov_rad / 2.0), 1e-30)

static func _apparent_pixels(radius_scene: float, dist: float, fov_rad: float, viewport_h: float) -> float:
	return 2.0 * radius_scene * _pixels_per_world_unit(dist, fov_rad, viewport_h)

## opts: { color: Color (linear) or int (sRGB hex → linear, as THREE.Color),
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
	material.render_priority = 3          # the web's renderOrder = 3
	mesh = MeshInstance3D.new()
	mesh.name = "Marker"
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	mesh.mesh = q
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.custom_aabb = NO_CULL_AABB       # it is one quad, and its own scale is dynamic
	mesh.visible = false

## Called per frame with the body's CAMERA-RELATIVE position and its rendered
## radius. Returns the marker's opacity, so the caller can tell whether the
## body is currently being carried by the marker rather than by its mesh.
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

## The quad's current world size (THREE's mesh.scale.x) — what the web's
## pick-radius code read.
func quad_scale() -> float:
	return mesh.scale.x

func dispose() -> void:
	if is_instance_valid(mesh):
		mesh.queue_free()
