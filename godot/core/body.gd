class_name Body
extends RefCounted

# ============================================================================
# A BODY — the physics object the orrery integrates.
# ----------------------------------------------------------------------------
# In the web build a body was a plain JS object that every module hung its own
# fields on (the star visual adds `activity`, the world adds `spinPhase`, the
# integrator adds `_aPrev`). GDScript members are far faster than Dictionary
# lookups — this is the N-body inner loop — so the fields that exist anywhere
# are DECLARED here, and `extra` is the escape hatch for anything a module
# needs that is not worth a declaration. Field names are the JS names in
# snake_case, so `b.radiusScene` is `b.radius_scene`.
#
# Units are the web build's: AU, M☉, years. `pos`/`vel`/`acc` are DVec3 —
# doubles — for the reason in core/dvec3.gd. Nothing here is float32.
# ============================================================================

var id: int = 0
var type: String = "planet"
var name: String = ""
var mass: float = 0.0
var mass0: float = 0.0
var pos := DVec3.new()        # AU
var vel := DVec3.new()        # AU/yr
var acc := DVec3.new()        # AU/yr²
var a_prev := DVec3.new()     # integrator scratch (JS: _aPrev)
var alive: bool = true
var emits_gw: bool = false
var spin = null               # preset-specified spin (neutron stars: Hz-ish), may be null

var spec: Dictionary = {}     # the spec this body was derived from (kept for rebuilds)
var def: Dictionary = {}      # TYPE_DEFAULTS entry

# ---- derived physical properties (deriveBody) -------------------------------
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
var structure: Dictionary = {}  # sim/structure.gd structureOf() result
var softening: float = 0.0      # optional Plummer softening override, AU

# ---- rendering ---------------------------------------------------------------
var viz = null                # the body visual (see PORT_GUIDE.md: visual contract)
var marker = null             # sim/scale.gd point-source marker
var radius_scene: float = 0.0
var rs_scene: float = 0.0
var contact_au: float = 0.0
var size_k: float = 1.0
var size_ease = null          # {from, t} or null
var m_check = null            # structural-limit mass memo (JS: _mCheck)

# ---- trail ----------------------------------------------------------------
var trail = null              # MeshInstance3D
var trail_buf := PackedFloat64Array()  # scene-unit positions, doubles
var trail_max: int = 0
var trail_head: int = 0
var trail_count: int = 0
var trail_color := Color(1, 1, 1)
var trail_opacity: float = 0.5

# ---- per-module state that the web hung on the body ---------------------------
var activity = null           # sim/stellar.gd ActivityModel (stars)
var spin_phase: float = 0.0   # rotation phase, radians (worlds, stars)
var cloud_phase: float = 0.0
var extra: Dictionary = {}

## THE SCENE-SPACE POSITION, in double precision: pos × sceneScale. What the
## web called `b.viz.group.position` (a Vector3 in JS doubles). The node's own
## float32 position is only ever this minus the camera origin.
var scene_pos := DVec3.new()

func _to_string() -> String:
	return "Body#%d %s (%s, %.3g M☉)" % [id, name, type, mass]
