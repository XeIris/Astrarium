class_name Climate
extends RefCounted

# CLIMATE: a zero-dimensional energy-balance model.
#   C · dT/dt = (1 − α(T)) · S/4  −  ε σ T⁴
#   S     total stellar flux, Σ L_i / d_i² (solar constants × 1361 W/m²)
#   α(T)  albedo rising as the planet freezes: the ice-albedo runaway
#   ε     effective emissivity (the greenhouse); 0.61 puts Earth at 288 K
#   C     ocean mixed-layer heat capacity, the thermal flywheel
# A wet world's outgoing longwave cannot exceed the runaway-greenhouse limit; above it
# the ocean boils into a steam atmosphere along its saturation curve
# (docs/physics/climate.md). Stable and Chaotic Eras come out of the orbit; a bad
# enough era sterilises the world. `per_star` rows, `era` and `extremes` are
# Dictionaries; `history` rows are [simYear, S, T].

const S0 := 1361.0             # solar constant, W/m²
const SIGMA := 5.670374e-8     # Stefan–Boltzmann, W m⁻² K⁻⁴
const YEAR_S := Rocketry.YR_S  # seconds per orrery year
const RHO_CW := 1000.0 * 4181.0 # sea water ρ·c_p, J m⁻³ K⁻¹
# Runaway greenhouse: a saturated steam atmosphere emits at most ~282 W/m² from
# ~300 K to ~1600 K surface temperature (Goldblatt et al. 2013).
const OLR_LIMIT := 282.0
const RUNAWAY_END_K := 1600.0
# Earth's ocean: 1.4e21 kg over 5.1e14 m² is 2.7e6 kg/m², 270 bar as steam; with
# L = 2.26 MJ/kg it takes 6.2e12 J/m² to boil.
const OCEAN_COLUMN_LATENT := 2.7e6 * 2.26e6
const OCEAN_STEAM_BAR := 270.0

const ERAS := {
	"DEEP_FREEZE": { "key": "DEEP_FREEZE", "label": "Deep Freeze",  "cls": "era-freeze", "desc": "Oceans locked in ice. Dehydrate and wait." },
	"COLD":        { "key": "COLD",        "label": "Chaotic — Cold", "cls": "era-cold", "desc": "A long winter. The suns are far." },
	"STABLE":      { "key": "STABLE",      "label": "Stable Era",   "cls": "era-stable", "desc": "Temperate. Civilisation may rebuild." },
	"HOT":         { "key": "HOT",         "label": "Chaotic — Hot", "cls": "era-hot",  "desc": "The suns are closing. Heat is rising." },
	"SCORCH":      { "key": "SCORCH",      "label": "Scorching",    "cls": "era-scorch", "desc": "Oceans boiling off. Nothing survives unburied." },
	"RUNAWAY":     { "key": "RUNAWAY",     "label": "Runaway greenhouse", "cls": "era-scorch", "desc": "The sky is steam and cannot shed more heat. The oceans are boiling into it." },
}

# Kopparapu et al. (2013, with its erratum), Table 3: S_eff = S☉ + aT + bT² + cT³ + dT⁴,
# T = Teff − 5780 K, valid for 2600–7200 K.
const HZ := {
	"recentVenus": [1.7753, 1.4316e-4, 2.9875e-9, -7.5702e-12, -1.1635e-15],
	"runaway":     [1.0512, 1.3242e-4, 1.5418e-8, -7.9895e-12, -1.8328e-15],
	"moist":       [1.0140, 8.1774e-5, 1.7063e-9, -4.3241e-12, -6.6462e-16],
	"maximum":     [0.3438, 5.8942e-5, 1.6558e-9, -3.0045e-12, -5.2983e-16],
	"earlyMars":   [0.3179, 5.4513e-5, 1.5313e-9, -2.7786e-12, -4.8997e-16],
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
# null until the first step() writes it.
var storm: float = 0.0
# Fractions of the starting ocean: on the surface, and in the air as steam.
var ocean: float = 1.0
var steam: float = 0.0
var wet: bool = true
var time: float = 0.0
# rolling history for the graph: [simYear, S, T]
var history: Array = []
# Budyko–Sellers in latitude (LatitudeEBM): sin of the ice edge's latitude, and whether
# the world is frozen to the equator. A snowball drives this model's ice to full cover.
var ebm := LatitudeEBM.new()
var ice_edge: float = 1.0
var snowball: bool = false
var history_max: int = 900
var _acc: float = 0.0
var extremes: Dictionary = {}

## `opts` is the preset's `climate` Dictionary (mixedLayer, greenhouse,
## albedoBase, albedoIce, T0).
func _init(opts: Dictionary = {}) -> void:
	mixed_layer = float(U.nz(opts.get("mixedLayer"), 12.0))
	greenhouse = float(U.nz(opts.get("greenhouse"), 0.61))
	albedo_base = float(U.nz(opts.get("albedoBase"), 0.22))
	albedo_ice = float(U.nz(opts.get("albedoIce"), 0.45))
	T = float(U.nz(opts.get("T0"), 288.0))
	wet = bool(opts.get("oceans", true))
	if not wet: ocean = 0.0
	# Seed S extremes from the empty interval, or a fictitious 1.00 S⊕ is reported as
	# observed.
	extremes = { "Tmin": T, "Tmax": T, "Smin": INF, "Smax": -INF }

var heat_capacity: float:       # J m⁻² K⁻¹
	get: return mixed_layer * RHO_CW

# Radiative relaxation time (yr): compare with the orbital period to see whether
# seasons register.
var tau_years: float:
	get: return heat_capacity / (4.0 * greenhouse * SIGMA * pow(T, 3.0)) / YEAR_S

var celsius: float:
	get: return T - 273.15

## Returns { alb, ice }.
func albedo(t: float) -> Dictionary:
	# ice fraction ramps in between 278 K and 233 K
	var ic := minf(maxf((278.0 - t) / 45.0, 0.0), 1.0)
	if snowball: ic = 1.0
	return { "alb": albedo_base + albedo_ice * ic, "ice": ic }

# Insolation from every luminous body, in units of Earth's solar constant.
# `planet` and `stars` are Bodies, positions in AU.
func insolation(planet: Body, stars: Array) -> float:
	var s_tot := 0.0
	per_star.clear()
	for s in stars:
		var L: float = U.nz(s.luminosity, Stellar.luminosity(s.mass))
		var d := maxf(planet.pos.distance_to(s.pos), 1e-4)
		# a flare's tiny share of the star's total output; 1 when quiet
		var flux: float = s.activity.bolometric if s.activity != null else 1.0
		var contrib := L * flux / (d * d)
		s_tot += contrib
		per_star.append({ "name": s.name, "S": contrib, "dist": d, "mass": s.mass,
			"teff": float(U.nz(s.teff, Stellar.effective_temp(s.mass))) })
	for p in per_star:
		p.frac = p.S / s_tot if s_tot > 0.0 else 0.0
	# sort_custom is not stable, so ties keep insertion order through the index.
	for i in per_star.size(): per_star[i]._i = i
	per_star.sort_custom(func(a, b): return a.S > b.S or (a.S == b.S and a._i < b._i))
	for p in per_star: p.erase("_i")
	return s_tot

## Effective flux S/S⊕ at a habitable-zone limit (`HZ` key) for a star of `teff`.
static func hz_flux(limit: String, teff: float) -> float:
	var c: Array = HZ[limit]
	var t := clampf(teff, 2600.0, 7200.0) - 5780.0
	return float(c[0]) + t * (float(c[1]) + t * (float(c[2]) + t * (float(c[3]) + t * float(c[4]))))

## The conservative habitable zone, runaway to maximum greenhouse, in S⊕ for the
## star delivering most of the flux (Kopparapu's limits are for one star).
func habitable_zone() -> Dictionary:
	var teff := float(per_star[0].teff) if not per_star.is_empty() else 5780.0
	return { "inner": hz_flux("runaway", teff), "outer": hz_flux("maximum", teff), "teff": teff }

## Boiling point (K) under the steam a fraction `st` of the ocean makes, by
## Clausius–Clapeyron with L = 40.7 kJ/mol: 373 K at 1 bar, 651 K at 270 bar.
static func boiling_point(st: float) -> float:
	return 1.0 / (1.0 / 373.15 - 8.314 / 40700.0 * log(1.0 + OCEAN_STEAM_BAR * maxf(st, 0.0)))

## Outgoing longwave, W/m².
func olr(t: float) -> float:
	var e := greenhouse * SIGMA * pow(t, 4.0)
	if ocean + steam > 0.0 and t < RUNAWAY_END_K: e = minf(e, OLR_LIMIT)
	return e

func classify(t: float) -> Dictionary:
	if steam > 0.01: return ERAS.RUNAWAY
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
		var net := absorbed - olr(T)
		var boil := boiling_point(steam)
		# At the boiling point the flux goes into latent heat, which outweighs the mixed
		# layer's sensible heat by 10⁵ K: the ocean boils, or the steam rains out.
		if net > 0.0 and ocean > 0.0 and T >= boil:
			var dm := minf(net * h * YEAR_S / OCEAN_COLUMN_LATENT, ocean)
			ocean -= dm; steam += dm
			T = boiling_point(steam)
		elif net < 0.0 and steam > 0.0 and T <= boil:
			var dm := minf(-net * h * YEAR_S / OCEAN_COLUMN_LATENT, steam)
			steam -= dm; ocean += dm
			T = boiling_point(steam)
		else:
			T += net / heat_capacity * (h * YEAR_S)
		T = maxf(T, 3.0)
		ice = ab.ice

	# The latitude model on the same clock, its OLR line pinned to this model's emission at
	# 288 K, so the two agree on a temperate world's mean.
	var obl := float(U.nz(planet.spec.get("obliquity"), planet.obliquity))
	var A := greenhouse * SIGMA * pow(288.15, 4.0) - LatitudeEBM.B * 15.0
	ebm.step(dt_years * YEAR_S, S * S0 / 4.0, RockyVisual.insolation_s2(obl), A, heat_capacity)
	ice_edge = ebm.ice_edge()
	snowball = ebm.snowball()
	ice = maxf(ice, ebm.ice_fraction())

	# Humidity → cloud → weather: saturation vapour pressure roughly doubles every 10 K.
	var cc := pow(2.0, (T - 288.0) / 10.0)
	humidity = minf(1.0, cc * (1.0 - ice) * 0.5) if ocean + steam > 0.0 else 0.0
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
	# Reset every derived quantity too (world.gd reads ice, the HUD era and clouds).
	S = 1.0; ice = 0.0; clouds = 0.4; humidity = 0.5
	ebm.reset(T0 - 273.15); ice_edge = 1.0; snowball = false
	ocean = 1.0 if wet else 0.0; steam = 0.0
	era = ERAS.STABLE
	per_star.clear(); _acc = 0.0
	extremes = { "Tmin": T0, "Tmax": T0, "Smin": INF, "Smax": -INF }
