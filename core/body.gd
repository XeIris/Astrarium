class_name Body
extends RefCounted

# Orrery state in AU, M☉ and years. Declared fields keep dictionary lookups out of
# the integration loop; DVec3 preserves precision across astronomical distances.

var id: int = 0
var type: String = "planet"
var name: String = ""
var mass: float = 0.0
var mass0: float = 0.0
var pos := DVec3.new()        # AU
var vel := DVec3.new()        # AU/yr
var acc := DVec3.new()        # AU/yr²
var a_prev := DVec3.new()     # integrator scratch
var alive: bool = true
var emits_gw: bool = false

var spec: Dictionary = {}     # the spec this body was derived from (kept for rebuilds)
var def: Dictionary = {}      # TYPE_DEFAULTS entry

# Derived physical properties.
var rs: float = 0.0           # Schwarzschild radius, AU
var radius: float = 0.0       # physical radius, AU
var radius_sun = null         # R☉ or null
var luminosity = null         # L☉ or null
var teff = null               # K or null
var spectral = null           # spectral class string or null
var phase = null              # evolutionary phase (stars)
var day_length: float = 0.0   # years (worlds)
var obliquity: float = 0.0
var home: bool = false
var spin_frac: float = 0.0
var composition = null
var Z: float = 0.014
var structure: Dictionary = {}  # sim/structure.gd structure_of() result
var softening: float = 0.0      # optional Plummer softening override, AU

# Rendering state.
var viz = null                # the body visual (see docs/godot.md: visual contract)
var visual_spin_rad_s = null  # radians per unpaused render second
var default_visual_spin_rad_s = null  # sampled once, survives visual rebuilds
var marker = null             # sim/marker.gd point-source marker
var radius_scene: float = 0.0
var rs_scene: float = 0.0
var contact_au: float = 0.0
var size_k: float = 1.0
var size_ease = null          # {from, t} or null
var m_check = null            # structural-limit mass memo

# Trail buffer ownership and indices.
var trail = null              # MeshInstance3D
var trail_buf := PackedFloat64Array()  # scene-unit positions, doubles
var trail_max: int = 0
var trail_head: int = 0
var trail_count: int = 0
var trail_color := Color(1, 1, 1)
var trail_opacity: float = 0.5

# Per-module state.
var activity = null           # sim/stellar.gd ActivityModel (stars)
var spin_phase: float = 0.0   # rotation phase, radians (worlds, stars)
var cloud_phase: float = 0.0
var extra: Dictionary = {}

## Scene-space position in double precision: pos × scene_scale. The node's own
## float32 position is only ever this minus the camera origin.
var scene_pos := DVec3.new()

func _to_string() -> String:
	return "Body#%d %s (%s, %s M☉)" % [id, name, type, U.prec(mass, 3)]
