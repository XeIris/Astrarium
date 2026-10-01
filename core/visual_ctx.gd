class_name VisualCtx
extends RefCounted

# The per-frame context every body visual's update(dt, ctx) receives (docs/godot.md).
# Built fresh by the orchestrator each frame; positions are camera-relative.

## A light source. `body` is null for the stand-in light of a starless scene
## (Suns.lit_by), which has only a position, colour and intensity.
class Sun extends RefCounted:
	var body: Body = null
	var pos_rel := Vector3.ZERO     # camera-relative
	var pos_abs: DVec3 = null       # absolute scene position
	var color := Color(1, 1, 1)     # linear
	var intensity: float = 0.0      # flux at the home world, solar constants
	var dist_au: float = 0.0
	var ang_radius: float = 0.0     # angular radius as rendered, for the sky pass
	var ang_true: float = 0.0       # the physically true one

	static func stand_in(p_pos_rel: Vector3, p_color: Color, p_intensity: float) -> Sun:
		var s := Sun.new()
		s.pos_rel = p_pos_rel; s.color = p_color; s.intensity = p_intensity
		return s

class Hole extends RefCounted:
	var body: Body = null
	var pos_rel := Vector3.ZERO     # camera-relative
	var pos_abs: DVec3 = null
	var rs_scene: float = 0.0
	var mass: float = 0.0

	static func of(b: Body, p_pos_rel: Vector3) -> Hole:
		var h := Hole.new()
		h.body = b; h.pos_rel = p_pos_rel; h.pos_abs = b.scene_pos
		h.rs_scene = b.rs_scene; h.mass = b.mass
		return h

var holes: Array = []               # of Hole, heaviest first
var suns: Array = []                # of Sun, brightest first
var camera: Camera3D = null         # at the origin; its basis is the view
var cam_pos: DVec3 = null           # the camera's absolute scene position
var time: float = 0.0               # wall-clock seconds accumulated
var scene_scale: float = 1.0        # scene units per AU
var sim_dt: float = 0.0             # years integrated this frame
var climate = null                  # the home world's Climate, or null
var bodies: Array = []              # every Body
var viewport_h: float = 0.0         # logical viewport height, px
