class_name SimState
extends RefCounted

# ============================================================================
# THE ORCHESTRATOR'S STATE — blackhole_sim.js's `state` object, typed.
# ----------------------------------------------------------------------------
# It is its own file (rather than a Dictionary inside main.gd) because other
# modules are handed it and write to it exactly as they did in the web build:
# spaceflight takes over `time_scale` and parks `speed`, the course reads the
# bodies, the cross-section reads the focus. Field names are the JS names in
# snake_case; the comments are the JS comments.
# ============================================================================

var preset = null              # active preset Dictionary
var preset_key: String = ""
var scene_scale: float = 2.0   # scene units per AU
var body_scale: float = 1.0
var true_scale: bool = false   # draw bodies at their real radius (see sim/scale.gd)
var time_scale: float = 2.0    # sim years per real second (× speed)
var max_step: float = 5e-3     # max integrator step (yr)
var gw_boost: float = 0.0
var lensing: bool = true

var mass: float = 10.0         # sandbox BH mass (M☉)
var disc_intensity: float = 0.9
var disc_temp: float = 0.6
var show_mesh: bool = true
var show_lens: bool = true
# Where a spawned body starts. Every scenario with something already in it
# puts new bodies on a circular orbit about the dominant mass, because that
# is the only starting condition that does not immediately fall in. The
# Blank Canvas has no dominant mass, so it starts them at rest instead.
var spawn_at_rest: bool = false
var speed: float = 1.0
var paused: bool = false

var cam_mode: String = "orbit" # 'orbit' | 'free' | 'surface' | 'flight'
var follow_id = null           # body id the orbit camera tracks
var focus_id = null            # selected body id

var bodies: Array = []         # Array of Body
var consumed: int = 0
var next_id: int = 1
var time: float = 0.0          # wall-clock seconds accumulated
var sim_years: float = 0.0     # elapsed SIMULATED time (yr) — what the climate runs on
var home_id = null             # the inhabited world, if the preset has one
var climate = null             # Climate or null
var exposure: float = 1.0      # surface-view eye adaptation
var suns: Array = []           # live star light sources, brightest first
var band: int = 3              # imaging band index (see sim/spectrum.gd)
var hud_hidden: bool = false
var app_mode: String = "sandbox"

# The LIVE sky spec, in the shape SkyModel.apply_sky_environment takes. A
# preset seeds it and the settings panel edits it afterwards, so this — not
# p.sky — is what is on screen. `env` is held as a weight MAP because the panel
# has one slider per environment and a map is what a set of sliders is.
var sky: Dictionary = {"env": {"disc": 1.0}, "tilt": 0.34, "roll": 0.9}
var last_steps: int = 0        # integrator sub-steps in the last frame
var energy0 = null             # total energy when the scenario loaded (drift reference)
var energy_n: int = -1

func body_by_id(id) -> Body:
	if id == null:
		return null
	for b in bodies:
		if b.id == id:
			return b
	return null

func body_named(n: String) -> Body:
	for b in bodies:
		if b.name == n:
			return b
	return null
