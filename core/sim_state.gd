class_name SimState
extends RefCounted

# The orchestrator's state, typed. Its own file because other modules are handed it
# and write to it (spaceflight takes over `time_scale` and parks `speed`, the course
# reads the bodies, the cross-section reads the focus).

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
var mesh_style: String = "lines"
var show_lens: bool = true
# Spawn at rest (the Blank Canvas, with no dominant mass) or on a circular orbit
# about the dominant mass (everywhere else).
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
var _sim_years: float = 0.0
var year_remainder: float = 0.0
var sim_years: float:
	get: return _sim_years
	set(value):
		_sim_years = value
		year_remainder = 0.0
var home_id = null             # the inhabited world, if the preset has one
var climate = null             # Climate or null
var exposure: float = 1.0      # surface-view eye adaptation
var suns: Array = []           # live star light sources, brightest first
var band: int = 3              # imaging band index (see sim/spectrum.gd)
var hud_hidden: bool = false
var app_mode: String = "sandbox"

# The live sky spec (what's on screen), in apply_sky_environment's shape. A preset
# seeds it, the settings panel edits it; `env` is a weight map, one slider per
# environment.
var sky: Dictionary = {"env": {"disc": 1.0}, "tilt": 0.34, "roll": 0.9}
var last_steps: int = 0        # integrator sub-steps in the last frame
var last_resolution_limited: bool = false
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

# Retain accepted intervals smaller than the elapsed clock's current ULP.
# Assigning sim_years explicitly starts a new epoch and clears this remainder.
func advance_years(accepted: float) -> void:
	var total := _sim_years + accepted
	year_remainder += _year_correction(total, accepted)
	_sim_years = total + year_remainder
	var folded := _sim_years - total
	year_remainder = (total - (_sim_years - folded)) + (year_remainder - folded)

func can_advance_years(requested: float) -> bool:
	var total := _sim_years + requested
	return is_finite(total) and is_finite(year_remainder) and is_finite(
		total + (year_remainder + _year_correction(total, requested)))

func _year_correction(total: float, increment: float) -> float:
	return (_sim_years - total) + increment if absf(_sim_years) >= absf(increment) else (increment - total) + _sim_years
