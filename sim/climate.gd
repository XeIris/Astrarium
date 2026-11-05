class_name Climate
extends RefCounted

# CLIMATE: one world's zero-dimensional energy-balance model.
#   C · dT/dt = (1 − α(T)) · S/4  −  OLR(T)
#   S     total stellar flux, Σ L_i / d_i² (solar constants × 1361 W/m²)
#   α(T)  albedo rising as the planet freezes: the ice-albedo runaway
#   OLR   outgoing longwave from the gas column (Atmosphere) and its water
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
const L_VAPOUR := 2.26e6       # J/kg
const RHO_SEA := 1025.0        # kg/m³
# Moist greenhouse: above ~340 K the cold trap lets water into the stratosphere, where
# it is photolysed and its hydrogen escapes (Kasting 1988). The trap's mixing ratio, a
# log-linear fit through ~3 ppm at 288 K and 3e-3 at 340 K, reaches 1 in a runaway.
# Escape is diffusion-limited, 2.5e17·f_H m⁻²s⁻¹ at Earth's gravity (Hunten 1973; b/H goes
# as g), capped by the energy limit ε·F_XUV/(4·GMm_H/R): ε = 0.15 and today's Sun's
# 4.6 mW/m² of XUV at 1 AU, scaled with the bolometric flux (a young or active star's XUV
# excess is not modelled). For Earth the cap is 1.6e15 m⁻²s⁻¹.
const MOIST_F := 3e-3
const H_PER_KG_WATER := 6.02214076e23 / 0.018015 * 2.0
const M_H := 1.6735575e-27
const PHI_EARTH := 3.986004e14 / 6.371e6
const ESCAPE_ENERGY := 0.15 * 4.6e-3 / (4.0 * M_H)
const DIFFUSION_LIMIT := 2.5e17
# Vapour column = this share of the saturated column, set by ~25 kg/m² on Earth at 288 K
# (assumed): how much water a world must hold before any of it stands on the surface.
const VAPOUR_SHARE := 0.19
# Below this ocean share the sky dries (assumed): evaporation runs out of open water.
const OPEN_WATER := 0.1
# A world with no land above this share reads as a water world or an ice shell.
const NO_LAND := 0.05
const SALINITY_REF := 35.0
# Below this the column is no atmosphere for flight or for the look: Pluto's 1 Pa is 1e-5 bar.
const AIRLESS_BAR := 1e-6

const ERAS := {
	"DEEP_FREEZE": { "key": "DEEP_FREEZE", "label": "Deep Freeze",  "cls": "era-freeze", "desc": "Oceans locked in ice. Dehydrate and wait." },
	"COLD":        { "key": "COLD",        "label": "Chaotic — Cold", "cls": "era-cold", "desc": "A long winter. The suns are far." },
	"STABLE":      { "key": "STABLE",      "label": "Stable Era",   "cls": "era-stable", "desc": "Temperate. Civilisation may rebuild." },
	"HOT":         { "key": "HOT",         "label": "Chaotic — Hot", "cls": "era-hot",  "desc": "The suns are closing. Heat is rising." },
	"SCORCH":      { "key": "SCORCH",      "label": "Scorching",    "cls": "era-scorch", "desc": "Oceans boiling off. Nothing survives unburied." },
	"RUNAWAY":     { "key": "RUNAWAY",     "label": "Runaway greenhouse", "cls": "era-scorch", "desc": "The sky is steam and cannot shed more heat. The oceans are boiling into it." },
	"MOIST":       { "key": "MOIST",       "label": "Moist greenhouse", "cls": "era-hot", "desc": "Water reaches the stratosphere, sunlight splits it, and the hydrogen leaks to space. The oceans are going for good." },
	"DRY":         { "key": "DRY",         "label": "Dry world",    "cls": "era-cold", "desc": "No ocean to freeze or boil. The ground answers the sunlight directly." },
	"WATER_WORLD": { "key": "WATER_WORLD", "label": "Global ocean", "cls": "era-stable", "desc": "Temperate, and no land breaks the surface from pole to pole." },
	"ICE_SHELL":   { "key": "ICE_SHELL",   "label": "Ice shell",    "cls": "era-freeze", "desc": "No land and no open water: one shell of ice over the whole ocean." },
}

# Today's Earth, bar: NSSDC's volume fractions of its 1.014 bar.
const EARTH_AIR := { "pN2": 0.79173, "pO2": 0.21243, "pAr": 0.009471, "pCO2": 4.2588e-4, "pCH4": 1.9672e-6, "pSO2": 0.0 }
# What a home world's climate assumes where its preset says nothing.
const HOME_INPUTS := { "mixedLayer": 12.0, "albedoBase": 0.306, "albedoIce": 0.45, "oceans": true,
	"pN2": 0.79173, "pO2": 0.21243, "pAr": 0.009471, "pCO2": 4.2588e-4, "pCH4": 1.9672e-6, "pSO2": 0.0,
	"land": 0.29, "oceanDepth": 3.7, "salinity": 35.0 }

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
var albedo_base: float          # ice-free albedo
var albedo_ice: float           # extra albedo at full glaciation
var pressures := {}             # bar, by Atmosphere.GASES key
var air: Atmosphere
var land := 0.29                # fraction of the surface above the sea
var ocean_depth := 3.7          # km, the sea's mean depth
var salinity := 35.0            # g/kg
# The world's water and what it weighs, from the inputs and the world's own gravity.
var water_column := 0.0         # kg/m²
var steam_bar := 0.0            # bar, the whole inventory as vapour
var gravity := Atmosphere.G_EARTH
var T: float                    # K
var S: float = 1.0              # current insolation, S⊕
var per_star: Array = []        # [{ name, S, dist, mass, frac }]
var era: Dictionary = ERAS.STABLE
var ice: float = 0.0            # 0..1 glaciated fraction
var clouds: float = 0.4         # 0..1 cloud cover
var humidity: float = 0.5
# null until the first step() writes it.
var storm: float = 0.0
# Fractions of the starting inventory (water_column): as sea, ice and its vapour, and in
# the air as steam.
var ocean: float = 1.0
var steam: float = 0.0
# The fraction of the starting ocean whose hydrogen has escaped to space: never back.
var lost: float = 0.0
var escape_flux: float = 0.0    # hydrogen atoms m⁻² s⁻¹, the last step's
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
# The inputs under what the spec states (ClimateInputs): unsetting a stated value returns here.
var drawn: Dictionary = HOME_INPUTS
# Accepted years this world has not stepped yet (catch_up).
var pending: float = 0.0
# What the air looks like (Atmosphere.limb); `sky_serial` moves when it changes.
var sky := {}
var sky_serial := 0
var _sky_steam := 0.0
var _world_mass := 0.0
var _world_radius := 0.0
var _phi := PHI_EARTH           # GM/R, m²/s²
var _ebm_a := 0.0               # LatitudeEBM's OLR intercept, W/m²
var _ice_shift := 0.0           # K the freezing point lies from sea water's
var _open_water := 1.0

## `opts` holds the inputs ClimateInputs.KEYS names; HOME_INPUTS fills the rest.
func _init(opts: Dictionary = {}) -> void:
	apply_inputs(opts)
	T = float(U.nz(opts.get("T0"), 288.0))
	# Seed S extremes from the empty interval, or a fictitious 1.00 S⊕ is reported as
	# observed.
	extremes = { "Tmin": T, "Tmax": T, "Smin": INF, "Smax": -INF }

## Take `stated` over the drawn inputs, for a new world or an accepted edit. T0 is a
## starting condition, so a live edit leaves the temperature to the new balance.
func apply_inputs(stated: Dictionary) -> void:
	mixed_layer = float(U.nz(stated.get("mixedLayer"), drawn.mixedLayer))
	albedo_base = float(U.nz(stated.get("albedoBase"), drawn.albedoBase))
	albedo_ice = float(U.nz(stated.get("albedoIce"), drawn.albedoIce))
	for key in Atmosphere.GASES:
		pressures[key] = float(U.nz(stated.get(key), drawn[key]))
	land = float(U.nz(stated.get("land"), drawn.land))
	ocean_depth = float(U.nz(stated.get("oceanDepth"), drawn.oceanDepth))
	salinity = float(U.nz(stated.get("salinity"), drawn.salinity))
	var now_wet := bool(U.nz(stated.get("oceans"), drawn.oceans)) and land < 1.0 and ocean_depth > 0.0
	if now_wet != wet:
		wet = now_wet
		ocean = 1.0 if wet else 0.0
		steam = 0.0
		lost = 0.0
		escape_flux = 0.0
		if not wet:
			ice = 0.0; ice_edge = 1.0; snowball = false
	_compose()

## The world this climate stands on, when it changes: its gravity holds the air and the water
## up, and its potential well sets the escape. A bare model keeps Earth's.
func set_world(mass_sun: float, radius_au: float) -> void:
	_world_mass = mass_sun
	_world_radius = radius_au
	if not (mass_sun > 0.0 and radius_au > 0.0): return
	var r := radius_au * Rocketry.AU_M
	_phi = Rocketry.GM_SUN * mass_sun / r
	gravity = _phi / r
	_compose()

# Everything derived from the inputs and the world, so a step reads it instead of working it out.
func _compose() -> void:
	air = Atmosphere.new(pressures, gravity)
	water_column = ocean_depth * 1000.0 * RHO_SEA * (1.0 - land) if wet else 0.0
	steam_bar = water_column * gravity * 1e-5
	_open_water = minf((1.0 - land) / OPEN_WATER, 1.0)
	_ice_shift = freezing_point(salinity) - freezing_point(SALINITY_REF)
	ebm.t_ice = LatitudeEBM.T_ICE + _ice_shift
	_ebm_a = air.olr(288.15, _water_weight()) - LatitudeEBM.B * 15.0
	_refresh_sky()

func _refresh_sky() -> void:
	_sky_steam = steam
	sky = air.limb(steam * steam_bar)
	sky_serial += 1

## What a vessel flies through on a world with no measured atmosphere: this column, hydrostatic
## and isothermal at the present temperature. Null below AIRLESS_BAR.
func flight_atmosphere() -> Variant:
	var bar := air.p_dry + steam * steam_bar
	if bar < AIRLESS_BAR: return null
	var molar := air.mean_molar
	var temp := maxf(T, 30.0)
	var height := Rocketry.R_GAS * temp / (molar * gravity)
	var tint := _sky_colour(0x6a8fc0)
	return {
		"p0": bar * 1e5, "rho0": bar * 1e5 * molar / (Rocketry.R_GAS * temp), "T0": temp, "molar": molar,
		"gamma": air.gamma, "layers": [{ "base": 0.0, "H": height }], "top": height * 14.0,
		"tint": tint, "haze": _sky_colour(0xa8c4e0), "skyThick": air.sky_thickness(float(sky.get("tau", 0.0))),
	}

# An authored N₂ sky's colour, moved by this column's limb tint: β's blue saturates in a thick sky.
func _sky_colour(base: int) -> int:
	var tint: Vector3 = sky.get("tint", Vector3.ONE)
	var r := float((base >> 16) & 0xff) * tint.x
	var g := float((base >> 8) & 0xff) * tint.y
	var b := float(base & 0xff) * tint.z
	var top := maxf(maxf(r, g), maxf(b, 1.0))
	var k := minf(255.0 / top, 1.0)
	return (int(r * k) << 16) | (int(g * k) << 8) | int(b * k)

## Start the 0-D model and the latitude model together at `T0` K.
func start_at(T0: float) -> void:
	T = T0
	ebm.reset(T0 - 273.15)
	extremes = { "Tmin": T0, "Tmax": T0, "Smin": INF, "Smax": -INF }

## The warmest balance at insolation `s_earth`, K; a wet world's ceiling is its boiling point.
func equilibrium_T(s_earth: float) -> float:
	var q := s_earth * S0 / 4.0
	var hi := boiling_point(0.0) if wet else _hottest_balance(q)
	if wet and _net_flux(hi, q) >= 0.0: return hi
	var t := hi
	while t > 3.0:
		var next := t * 0.98
		if _net_flux(next, q) >= 0.0:
			var warm := t
			var cool := next
			for i in 40:
				var mid := 0.5 * (warm + cool)
				if _net_flux(mid, q) >= 0.0: cool = mid
				else: warm = mid
			return cool
		t = next
	return 3.0

# OLR is at least the band core's share of the emission, so the balance lies below this.
func _hottest_balance(q: float) -> float:
	return pow(q / (pow(Atmosphere.STRAT, 4.0) * SIGMA), 0.25) / air.emit_k + 1.0

func _net_flux(t: float, q: float) -> float:
	return (1.0 - _albedo_at(t)) * q - olr(t)

## Accepted years since this world last stepped, plus `dt_years`, all at once. The home
## world and the panel's pass through here with nothing owed.
func catch_up(dt_years: float, planet: Body, stars: Array) -> void:
	var owed := pending + dt_years
	pending = 0.0
	step(owed, planet, stars)

# A wet world's mixed layer cannot be deeper than its sea.
var heat_capacity: float:       # J m⁻² K⁻¹
	get: return (minf(mixed_layer, ocean_depth * 1000.0) if wet else mixed_layer) * RHO_CW

# Radiative relaxation time (yr): compare with the orbital period to see whether
# seasons register.
var tau_years: float:
	get: return heat_capacity / (4.0 * olr(T) / T) / YEAR_S

var celsius: float:
	get: return T - 273.15

## Returns { alb, ice }.
func albedo(t: float) -> Dictionary:
	return { "alb": _albedo_at(t), "ice": _ice_cover(t) }

# Ice fraction: ramps in between 278 K and 233 K for sea water, moving with its freezing
# point. Without water standing on the surface there is none to reflect.
func _ice_cover(t: float) -> float:
	if not _standing_water(t): return 0.0
	if snowball: return 1.0
	return minf(maxf((278.0 + _ice_shift - t) / 45.0, 0.0), 1.0)

## Sea water's freezing point (K) at `s` g/kg: UNESCO's fit (Millero 1978) at 1 atm.
## −1.92 °C at 35 g/kg; fitted to 40 g/kg and extrapolated towards the brine eutectic.
static func freezing_point(s: float) -> float:
	return 273.15 + (-0.0575 + 1.710523e-3 * sqrt(s) - 2.154996e-4 * s) * s

## The vapour column (kg/m²) saturated air holds at `t` K over this world.
func vapour_column(t: float) -> float:
	return VAPOUR_SHARE * Atmosphere.saturation_bar(t) * 1e5 / gravity * Atmosphere.M_H2O / air.mean_molar

## Whether the inventory exceeds what the air holds at `t` K, so some of it stands as sea or ice.
## Only worth asking of a small inventory: a boiling sky holds ~1000 kg/m².
func _standing_water(t: float) -> bool:
	if ocean <= 0.0: return false
	var mass := ocean * water_column
	return mass > 5000.0 or mass > vapour_column(t)

# How opaque the water bands are: the water there is against what closes them, under open sky.
func _water_weight() -> float:
	if ocean + steam <= 0.0: return 0.0
	return minf((ocean + steam) * water_column / air.water_opaque_column, 1.0) * _open_water

func _albedo_at(t: float) -> float:
	return minf(albedo_base + albedo_ice * _ice_cover(t), 1.0)

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

## Boiling point (K) under the air and the steam a fraction `st` of the water makes.
func boiling_point(st: float) -> float:
	return Atmosphere.saturation_T(air.p_dry + steam_bar * maxf(st, 0.0))

## Outgoing longwave, W/m².
func olr(t: float) -> float:
	var e := air.olr(t, _water_weight())
	if ocean + steam > 0.0 and t < RUNAWAY_END_K: e = minf(e, OLR_LIMIT)
	return e

## OLR as an effective emissivity at the present temperature, for what still reads one.
func emissivity() -> float:
	return olr(T) / (SIGMA * T * T * T * T)

# Steam rules the sky once it outweighs the dry air.
func _steam_rules() -> bool:
	return steam > 0.0 and steam * steam_bar > air.p_dry

## Water's mixing ratio at the cold trap over a surface at `t` K (see MOIST_F).
func stratospheric_water(t: float) -> float:
	if ocean + steam <= 0.0: return 0.0
	if _steam_rules(): return 1.0
	return minf(pow(10.0, -5.52 + 0.0577 * (t - 288.0)), 1.0)

## Hydrogen escaping to space, atoms m⁻² s⁻¹, at insolation S (S⊕).
func hydrogen_escape(t: float, s_earth: float) -> float:
	var diffusion := DIFFUSION_LIMIT * gravity / Atmosphere.G_EARTH * 2.0 * stratospheric_water(t)
	return minf(diffusion, ESCAPE_ENERGY / _phi * s_earth)

func classify(t: float) -> Dictionary:
	if not wet: return ERAS.DRY
	if _steam_rules(): return ERAS.RUNAWAY
	if not _standing_water(t): return ERAS.DRY
	var no_land := land < NO_LAND
	if snowball or t < 233.0 + _ice_shift: return ERAS.ICE_SHELL if no_land else ERAS.DEEP_FREEZE
	if t < 273.0 + _ice_shift: return ERAS.COLD
	if stratospheric_water(t) > MOIST_F: return ERAS.MOIST
	if t > 345.0: return ERAS.SCORCH
	if t > 305.0: return ERAS.HOT
	return ERAS.WATER_WORLD if no_land else ERAS.STABLE

# Advance the climate by `dt_years` of simulated time.
func step(dt_years: float, planet: Body, stars: Array) -> void:
	if not (dt_years > 0.0): return
	time += dt_years
	S = insolation(planet, stars)
	if planet.mass != _world_mass or planet.radius != _world_radius: set_world(planet.mass, planet.radius)

	if wet: _step_wet(dt_years, planet)
	else: _step_dry(dt_years)

	# A sky of steam looks like one; only a real change moves the shell's uniforms.
	if absf(steam - _sky_steam) * steam_bar > 0.02 * (air.p_dry + steam * steam_bar + 1e-3): _refresh_sky()

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

## An ocean's state: sub-stepped explicitly, with the latitude model on the same clock.
func _step_wet(dt_years: float, planet: Body) -> void:
	# Sub-step so a big frame-step can't overshoot the T⁴ term into instability.
	var tau := maxf(tau_years, 1e-4)
	var n := mini(64, maxi(1, int(ceil(dt_years / (tau * 0.25)))))
	var h := dt_years / float(n)
	var hs := h * YEAR_S
	var cap := heat_capacity
	for i in n:
		var ic := _ice_cover(T)
		var absorbed := (1.0 - minf(albedo_base + albedo_ice * ic, 1.0)) * S * S0 / 4.0
		var out := olr(T)
		var net := absorbed - out
		var boil := boiling_point(steam)
		# At the boiling point the flux goes into latent heat, which outweighs the mixed
		# layer's sensible heat by 10⁵ K: the ocean boils, or the steam rains out.
		if net > 0.0 and ocean > 0.0 and T >= boil:
			var dm := minf(net * hs / (water_column * L_VAPOUR), ocean)
			ocean -= dm; steam += dm
			T = boiling_point(steam)
		elif net < 0.0 and steam > 0.0 and T <= boil:
			var dm := minf(-net * hs / (water_column * L_VAPOUR), steam)
			steam -= dm; ocean += dm
			T = boiling_point(steam)
		else:
			var dT := net / cap * hs
			# Past the sub-step cap explicit T⁴ can diverge; linearise it implicitly there.
			var stiff := 4.0 * out / T / cap * hs
			T += dT / (1.0 + stiff) if stiff > 1.0 else dT
		T = maxf(T, 3.0)
		ice = ic
		# Lost from the air first, then the sea; a world with none left dries for good.
		escape_flux = hydrogen_escape(T, S) if ocean + steam > 0.0 else 0.0
		var dl := minf(escape_flux * hs / (water_column * H_PER_KG_WATER), ocean + steam)
		if dl > 0.0:
			var from_steam := minf(dl, steam)
			steam -= from_steam; ocean -= dl - from_steam
			ocean = maxf(ocean, 0.0)
			lost += dl

	# The latitude model on the same clock, its OLR line pinned to this model's emission at
	# 288 K, so the two agree on a temperate world's mean.
	var obl := float(U.nz(planet.spec.get("obliquity"), planet.obliquity))
	ebm.step(dt_years * YEAR_S, S * S0 / 4.0, RockyVisual.insolation_s2(obl), _ebm_a, cap)
	ice_edge = ebm.ice_edge()
	snowball = ebm.snowball()
	ice = maxf(ice, ebm.ice_fraction())

	# Humidity → cloud → weather: saturation vapour pressure roughly doubles every 10 K.
	var cc := pow(2.0, (T - 288.0) / 10.0)
	humidity = minf(1.0, cc * (1.0 - ice) * 0.5) * _open_water if ocean + steam > 0.0 else 0.0
	clouds = minf(0.95, 0.12 + humidity * 0.75)
	# storminess scales with how hard the insolation is changing plus raw heat
	storm = minf(1.0, humidity * 0.8 + maxf(0.0, (T - 300.0) / 60.0))

## No water: one backward-Euler step by Newton, its slope 4·OLR/T. That leans a little above
## the true slope, so it closes quickly. A thin dry layer is stiff at any frame length.
func _step_dry(dt_years: float) -> void:
	var a := (1.0 - _albedo_at(T)) * S * S0 / 4.0
	var k := dt_years * YEAR_S / heat_capacity
	var x := T
	for i in 12:
		var e := air.olr(x)
		var dx := (x - T - k * (a - e)) / (1.0 + 4.0 * k * e / x)
		x = maxf(x - dx, 3.0)
		if absf(dx) < 1e-6 * x: break
	T = x
	ice = 0.0; humidity = 0.0; clouds = 0.0; storm = 0.0; escape_flux = 0.0

func reset(T0: float = 288.0) -> void:
	T = T0; time = 0.0; history.clear()
	# Reset every derived quantity too (world.gd reads ice, the HUD era and clouds).
	S = 1.0; ice = 0.0; clouds = 0.4 if wet else 0.0; humidity = 0.5 if wet else 0.0
	ebm.reset(T0 - 273.15); ice_edge = 1.0; snowball = false
	ocean = 1.0 if wet else 0.0; steam = 0.0; lost = 0.0; escape_flux = 0.0
	era = ERAS.STABLE if wet else ERAS.DRY
	per_star.clear(); _acc = 0.0; pending = 0.0
	_refresh_sky()
	extremes = { "Tmin": T0, "Tmax": T0, "Smin": INF, "Smax": -INF }
