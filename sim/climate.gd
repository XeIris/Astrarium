class_name Climate
extends RefCounted

# ============================================================================
# CLIMATE — a zero-dimensional energy-balance model (EBM)
# ----------------------------------------------------------------------------
# The oldest real climate model there is, and the right one here: it captures
# exactly the physics that makes Trisolaris terrifying.
#
#   C · dT/dt = (1 − α(T)) · S/4  −  ε σ T⁴
#
#   S      total stellar flux at the planet, summed over every star:
#          S = Σ L_i / d_i²   (in solar constants, then × 1361 W/m²)
#   α(T)   planetary albedo, which RISES as the planet freezes — the
#          ice-albedo feedback. This is the runaway: a cold snap grows ice,
#          ice reflects sunlight, which deepens the cold snap. Cross the
#          threshold and the planet snowballs and never comes back.
#   ε      effective emissivity, i.e. the greenhouse. ε = 0.61 is calibrated
#          so Earth (S = 1, α = 0.3) sits at 288 K.
#   C      heat capacity of the ocean mixed layer — the planet's thermal
#          flywheel. A deep ocean damps the swings; a shallow one lets the
#          temperature whip around with the orbit.
#
# The result is emergent, not scripted: Stable Eras and Chaotic Eras fall out
# of the orbit, and a bad enough Chaotic Era genuinely sterilises the world.
#
# PORT NOTE. Fields are the JS names in snake_case (`mixedLayer` →
# `mixed_layer`, `perStar` → `per_star`); the physics symbols `T` and `S` keep
# their case. `per_star` rows, `era` and `extremes` are Dictionaries with the JS
# keys, and `history` rows are [simYear, S, T] Arrays, as before.
# ============================================================================

const S0 := 1361.0             # solar constant, W/m²
const SIGMA := 5.670374e-8     # Stefan–Boltzmann, W m⁻² K⁻⁴
const YEAR_S := 3.15576e7      # seconds per year
const RHO_CW := 1000.0 * 4181.0 # sea water ρ·c_p, J m⁻³ K⁻¹

const ERAS := {
	"DEEP_FREEZE": { "key": "DEEP_FREEZE", "label": "Deep Freeze",  "cls": "era-freeze", "desc": "Oceans locked in ice. Dehydrate and wait." },
	"COLD":        { "key": "COLD",        "label": "Chaotic — Cold", "cls": "era-cold", "desc": "A long winter. The suns are far." },
	"STABLE":      { "key": "STABLE",      "label": "Stable Era",   "cls": "era-stable", "desc": "Temperate. Civilisation may rebuild." },
	"HOT":         { "key": "HOT",         "label": "Chaotic — Hot", "cls": "era-hot",  "desc": "The suns are closing. Heat is rising." },
	"SCORCH":      { "key": "SCORCH",      "label": "Scorching",    "cls": "era-scorch", "desc": "Oceans boiling off. Nothing survives unburied." },
}

var mixed_layer: float          # metres of ocean
var greenhouse: float           # effective emissivity ε
var albedo_base: float          # ice-free albedo
var albedo_ice: float           # extra albedo at full glaciation
var T: float                    # K
var S: float = 1.0              # current insolation, S⊕
var per_star: Array = []        # [{ name, S, dist, mass, frac }]
var era: Dictionary = ERAS.STABLE
var ice: float = 0.0            # 0..1 glaciated fraction
var clouds: float = 0.4         # 0..1 cloud cover
var humidity: float = 0.5
# JS: `this.storm` is undefined until the first step() writes it.
var storm: float = 0.0
var time: float = 0.0
# rolling history for the graph: [simYear, S, T]
var history: Array = []
var history_max: int = 900
var _acc: float = 0.0
var extremes: Dictionary = {}

## `opts` is the preset's `climate` Dictionary (JS keys: mixedLayer,
## greenhouse, albedoBase, albedoIce, T0).
func _init(opts: Dictionary = {}) -> void:
	mixed_layer = float(U.nz(opts.get("mixedLayer"), 12.0))
	greenhouse = float(U.nz(opts.get("greenhouse"), 0.61))
	albedo_base = float(U.nz(opts.get("albedoBase"), 0.22))
	albedo_ice = float(U.nz(opts.get("albedoIce"), 0.45))
	T = float(U.nz(opts.get("T0"), 288.0))
	# Seeded from the empty interval, not from 1 S⊕: step() only ever narrows
	# these with min/max, so a seed of 1 is reported as an observed extreme on
	# a world that never receives exactly one solar constant. Trisolaris ranges
	# 0.40–3.08 S⊕, so Smin would read a fictitious 1.00 until the first dip.
	extremes = { "Tmin": T, "Tmax": T, "Smin": INF, "Smax": -INF }

var heat_capacity: float:       # J m⁻² K⁻¹
	get: return mixed_layer * RHO_CW

# Radiative relaxation time of the planet, in years — how long it takes to
# respond to a change in sunlight. Compare it to the orbital period to know
# whether the world can even "feel" a season.
var tau_years: float:
	get: return heat_capacity / (4.0 * greenhouse * SIGMA * pow(T, 3.0)) / YEAR_S

var celsius: float:
	get: return T - 273.15

## Returns { alb, ice }.
func albedo(t: float) -> Dictionary:
	# ice fraction ramps in between 278 K and 233 K
	var ic := minf(maxf((278.0 - t) / 45.0, 0.0), 1.0)
	return { "alb": albedo_base + albedo_ice * ic, "ice": ic }

# Insolation from every luminous body, in units of Earth's solar constant.
# `planet` and `stars` are Bodies, positions in AU.
func insolation(planet: Body, stars: Array) -> float:
	var s_tot := 0.0
	per_star.clear()
	for s in stars:
		var L: float = U.nz(s.luminosity, Stellar.luminosity(s.mass))
		var d := maxf(planet.pos.distance_to(s.pos), 1e-4)
		# flares briefly brighten the star; activity.flux is 1 when quiet
		var flux: float = s.activity.flux if s.activity != null else 1.0
		var contrib := L * flux / (d * d)
		s_tot += contrib
		per_star.append({ "name": s.name, "S": contrib, "dist": d, "mass": s.mass })
	for p in per_star:
		p.frac = p.S / s_tot if s_tot > 0.0 else 0.0
	# JS Array.prototype.sort is stable; sort_custom is not, so ties keep their
	# insertion order through the index.
	for i in per_star.size(): per_star[i]._i = i
	per_star.sort_custom(func(a, b): return a.S > b.S or (a.S == b.S and a._i < b._i))
	for p in per_star: p.erase("_i")
	return s_tot

func classify(t: float) -> Dictionary:
	if t < 233.0: return ERAS.DEEP_FREEZE
	if t < 273.0: return ERAS.COLD
	if t > 345.0: return ERAS.SCORCH
	if t > 305.0: return ERAS.HOT
	return ERAS.STABLE

# Advance the climate by `dt_years` of simulated time.
func step(dt_years: float, planet: Body, stars: Array) -> void:
	if not (dt_years > 0.0): return
	time += dt_years
	S = insolation(planet, stars)

	# Sub-step so a big frame-step can't overshoot the T⁴ term into instability.
	var tau := maxf(tau_years, 1e-4)
	var n := mini(64, maxi(1, int(ceil(dt_years / (tau * 0.25)))))
	var h := dt_years / float(n)
	for i in n:
		var ab := albedo(T)
		var absorbed := (1.0 - float(ab.alb)) * S * S0 / 4.0
		var emitted := greenhouse * SIGMA * pow(T, 4.0)
		T += (absorbed - emitted) / heat_capacity * (h * YEAR_S)
		T = maxf(T, 3.0)
		ice = ab.ice

	# Diagnostics that ride on temperature: humidity → cloud → weather.
	# Saturation vapour pressure roughly doubles every 10 K (Clausius–Clapeyron),
	# so a warm world is a wet, cloudy, stormy one.
	var cc := pow(2.0, (T - 288.0) / 10.0)
	humidity = minf(1.0, cc * (1.0 - ice) * 0.5)
	clouds = minf(0.95, 0.12 + humidity * 0.75)
	# storminess scales with how hard the insolation is changing plus raw heat
	storm = minf(1.0, humidity * 0.8 + maxf(0.0, (T - 300.0) / 60.0))

	era = classify(T)

	var e := extremes
	e.Tmin = minf(e.Tmin, T); e.Tmax = maxf(e.Tmax, T)
	e.Smin = minf(e.Smin, S); e.Smax = maxf(e.Smax, S)

	# sample the history on a cadence tied to sim time, not frame rate
	_acc += dt_years
	var cadence := maxf(0.004, dt_years)
	if _acc >= cadence:
		_acc = 0.0
		history.append([time, S, T])
		if history.size() > history_max: history.pop_front()

func reset(T0: float = 288.0) -> void:
	T = T0; time = 0.0; history.clear()
	# Every derived quantity has to go back with it. sim/world.gd reads cl.ice
	# straight into the surface shader and the HUD reads era/clouds, so leaving
	# these behind leaves the old run's ice caps and era badge on screen until
	# the next step() completes.
	S = 1.0; ice = 0.0; clouds = 0.4; humidity = 0.5
	era = ERAS.STABLE
	per_star.clear(); _acc = 0.0
	extremes = { "Tmin": T0, "Tmax": T0, "Smin": INF, "Smax": -INF }
