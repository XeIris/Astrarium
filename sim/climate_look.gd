class_name ClimateLook
extends RefCounted

# What a world's climate says it looks like. Pure functions of its Climate and spec, so a check
# can read them without a window; Binder eases them onto a visual's materials. A stated look
# (cloudCover, arid, biota, ...) wins: a preset states what cannot be derived.
# docs/physics/climate.md#the-look-follows.

# Global mean precipitation today (505,000 km³/yr over the globe, Wikipedia after Chow et al.),
# and over land. Near today's Earth it follows the energy budget at 2%/K, not vapour's 7%/K
# (Held & Soden 2006; Allan et al. 2014). The vapour cap is what binds a cold world.
const P_GLOBE_MM := 990.0
const P_LAND_MM := 715.0
const P_ENERGY_PER_K := 0.02
const P_VAPOUR_PER_K := 0.07
# Earth's sea share, which sets `supply` to 1 today; the square root is an estimate.
const SEA_TODAY := 0.71
# Climate's cloud rule at no humidity.
const CLEAR_SKY := 0.12
# Lieth's Miami model (1975), as tabulated by Adams et al. (2004), g m⁻² yr⁻¹.
const NPP_MAX := 3000.0
# Heat ends photosynthesis. Thermal limits of land plants near 50 °C, an estimate for a world's mean.
const LIFE_HOT_K := [323.0, 348.0]
# James, Kieffer & Paige (1992): CO₂ frost at T = b/(a − ln p), p in mbar. Past CO₂'s triple point
# (5.185 bar) the solid forms on the melting curve, which stays within a few K of it to 100 bar.
const CO2_FROST_A := 23.3494
const CO2_FROST_B := 3182.48
const CO2_TRIPLE_BAR := 5.185
# N₂ condenses by Clausius–Clapeyron from its triple point (63.15 K, 0.1252 bar; NIST WebBook):
# vaporisation's 5.57 kJ/mol above it, which gives 78.6 K at 1 atm against a measured 77.4, and below
# it an effective 6.8 kJ/mol for sublimation (6.3 at the triple point, more when colder), chosen so
# that Pluto's 11.5 µbar stands over 37 K ice (Gladstone et al. 2016).
const N2_TRIPLE_K := 63.15
const N2_TRIPLE_BAR := 0.1252
const N2_SUBLIME_J := 6800.0
const N2_BOIL_J := 5570.0
# Snow and land ice are fresh water, whatever the sea holds.
const WATER_FROST_K := 273.0
# The troposphere's lapse against the dry adiabat g/c_p: Earth's 6.5 K/km of 9.8 is 0.66, and dry
# worlds, without latent heat, sit nearer 0.4 (Mars's N in Rees & Garrett 2019).
const STABLE_WET := 0.66
const STABLE_DRY := 0.4
# Venus's deck has an optical depth of order 30 (an estimate from its opaque deck; no figure
# could be verified) for its pSO₂·p/(g/g⊕) of 1.41 bar². Cover follows 1 − exp(−τ/2).
const DECK_TAU_PER_BAR2 := 30.0 / 1.41
# Air erases small craters: nothing left by 0.1 bar, all of an airless world's at a mbar (estimates).
const CRATER_AIRLESS := 0.85
const HAZE_EARTH := 0.45
const HAZE_MAX := 1.3
# The sea's abyssal plain lies below its mean by Earth's ratio (Terrain.terrain_uniforms).
const ABYSS_RATIO := 4.6 / 3.7
const SEA_GONE_KM := -60.0
const AIR_TINT_MAX := 1.6

## Mean precipitation over the globe, mm/yr. Zero without water to rain.
static func precipitation_mm(cl: Climate) -> float:
	if not cl.wet or cl.ocean + cl.steam <= 0.0 or cl.humidity <= 0.0: return 0.0
	var dt := cl.T - 288.0
	var absorbed: float = (1.0 - float(cl.albedo(cl.T).alb)) * cl.S * Climate.S0 / 4.0
	# Latent heat cannot carry away more than the sunlight that arrives: L·P ≤ absorbed. kg/m² is mm.
	var energy_cap: float = absorbed / Climate.L_VAPOUR * Rocketry.YR_S
	var p := P_GLOBE_MM * minf(exp(P_ENERGY_PER_K * dt), exp(P_VAPOUR_PER_K * dt))
	return minf(p * supply(cl), energy_cap)

## How well the sea can water the land, 1 today: less sea, drier interiors.
static func supply(cl: Climate) -> float:
	if not cl.wet: return 0.0
	var share := clampf((1.0 - cl.land) / SEA_TODAY, 0.0, 1.0)
	return sqrt(share) * minf(cl.ocean * cl.water_column / maxf(cl.vapour_column(cl.T), 1e-6), 1.0)

## The shader's global dryness: what the sea cannot supply, or heat takes back.
static func arid_of(cl: Climate) -> float:
	var hot := clampf((cl.T - 310.0) / 80.0, 0.0, 0.8)
	return maxf(1.0 - supply(cl), hot)

## Net primary productivity at a world's mean land temperature and rain, g m⁻² yr⁻¹.
static func npp(t_k: float, p_mm: float) -> float:
	var c := t_k - 273.15
	var by_t := NPP_MAX / (1.0 + exp(1.315 - 0.119 * c))
	var by_p := NPP_MAX * (1.0 - exp(-0.000664 * p_mm))
	return minf(by_t, by_p)

## How much of the land is growing, against today's Earth: 1 at its 288 K and 715 mm.
static func biota_of(cl: Climate) -> float:
	var rain := precipitation_mm(cl) * P_LAND_MM / P_GLOBE_MM
	if rain <= 0.0: return 0.0
	var growth := npp(cl.T, rain) / npp(288.0, P_LAND_MM)
	var heat := 1.0 - clampf((cl.T - LIFE_HOT_K[0]) / (LIFE_HOT_K[1] - LIFE_HOT_K[0]), 0.0, 1.0)
	return clampf(growth, 0.0, 1.0) * heat * (1.0 - clampf(cl.ice, 0.0, 1.0))

## CO₂'s frost point at `bar`, K.
static func co2_frost_k(bar: float) -> float:
	return CO2_FROST_B / (CO2_FROST_A - log(clampf(bar, 1e-9, CO2_TRIPLE_BAR) * 1000.0))

## N₂'s condensation point at `bar`, K.
static func n2_frost_k(bar: float) -> float:
	var heat := N2_SUBLIME_J if bar < N2_TRIPLE_BAR else N2_BOIL_J
	return 1.0 / (1.0 / N2_TRIPLE_K - Atmosphere.R_GAS / heat * log(maxf(bar, 1e-12) / N2_TRIPLE_BAR))

## The frost point of what can freeze here: water, else the air's main volatile. A world with no air
## and no water has nothing to frost.
static func frost_of(cl: Climate) -> float:
	if cl.wet and cl.ocean + cl.steam > 0.0: return WATER_FROST_K
	var co2 := float(cl.pressures.get("pCO2", 0.0))
	if co2 > 0.5 * cl.air.p_dry and co2 > 0.0: return co2_frost_k(co2)
	if cl.air.p_dry <= Climate.AIRLESS_BAR: return 0.0
	var n2 := float(cl.pressures.get("pN2", 0.0))
	return n2_frost_k(n2 if n2 > 0.0 else cl.air.p_dry)

## How fast the air cools with height near the ground, K/m: none without air.
static func lapse_k_m(cl: Climate) -> float:
	var air: float = cl.air.p_dry + cl.steam * cl.steam_bar
	if air < Climate.AIRLESS_BAR or cl.air.kappa <= 0.0 or cl.air.mean_molar <= 0.0: return 0.0
	var cp: float = Atmosphere.R_GAS / cl.air.kappa / cl.air.mean_molar
	var stable := STABLE_WET if cl.wet and cl.ocean + cl.steam > 0.0 else STABLE_DRY
	return stable * cl.gravity / cp

## Where the sea stands against the crust's datum, km. As it evaporates or escapes it falls towards
## the abyssal plain; past that, no liquid at all.
static func sea_km_of(cl: Climate, hot_stated: bool) -> float:
	if not cl.wet or cl.ocean <= 0.0 or cl.era.key == "DRY" or hot_stated: return SEA_GONE_KM
	return -(1.0 - cl.ocean) * cl.ocean_depth * ABYSS_RATIO

## The sulphur deck's opaque share.
static func deck_of(cl: Climate) -> float:
	return 1.0 - exp(-0.5 * DECK_TAU_PER_BAR2 * float(cl.pressures.get("pSO2", 0.0)) * cl.air.p_dry / (cl.gravity / Atmosphere.G_EARTH))

## Cover: the humidity rule on a wet world and the steam or sulphur deck on any.
static func cover_of(cl: Climate) -> float:
	# The humidity rule answers to the air over the sea; a dry continent's sky is clearer.
	var moist := CLEAR_SKY + (cl.clouds - CLEAR_SKY) * supply(cl) if cl.wet else 0.0
	var cover := maxf(moist, deck_of(cl))
	# A runaway ends under more cloud, not less: only fair-weather structure goes.
	var boil := clampf((cl.T - 340.0) / 110.0, 0.0, 1.0) if cl.wet and cl.ocean + cl.steam > 0.0 else 0.0
	return cover + (1.0 - cover) * boil

## Everything the surface, deck and shell take, keyed by uniform. A stated value wins.
static func targets(cl: Climate, spec: Dictionary) -> Dictionary:
	var air: float = cl.air.p_dry + cl.steam * cl.steam_bar
	var has_air := air >= Climate.AIRLESS_BAR
	var thick := float(cl.sky.get("thick", 0.0))
	var hot_stated: bool = spec.get("hot") == true and spec.get("oceans") != true
	var t_mean := float(U.nz(spec.get("surfaceK"), cl.T))
	# A preset's `hot` says this ground is dry, whatever its draw has it hold.
	var out := {
		"uMeanK": t_mean,
		"uIce": 0.0 if hot_stated else cl.ice,
		"uSeaKm": sea_km_of(cl, hot_stated),
		"uScorch": clampf((t_mean - 330.0) / 140.0, 0.0, 1.0) if has_air else 0.0,
		"uArid": float(U.nz(spec.get("arid"), 1.0 if hot_stated else arid_of(cl))),
		"uBiota": float(U.nz(spec.get("biota"), 0.0 if hot_stated else biota_of(cl))),
		"uFrostK": float(U.nz(spec.get("frostK"), frost_of(cl))),
		"uLapse": lapse_k_m(cl) * 1000.0,
		"uHaze": float(U.nz(spec.get("haze"), minf(HAZE_EARTH * thick, HAZE_MAX))),
		"uCrater": float(U.nz(spec.get("crater"), CRATER_AIRLESS * (1.0 - smoothstep(0.001, 0.1, air)))),
		"cover": float(U.nz(spec.get("cloudCover"), deck_of(cl) if hot_stated else cover_of(cl))),
		"storm": cl.storm,
	}
	# A world with a sea has a coast. A dry one's relief keeps the crust it was built with: its
	# drawn land waits unread, as its sea does, until oceans is edited on.
	if (cl.wet and not hot_stated) or spec.get("land") != null: out.uCrustT = Terrain.crust_threshold(cl.land)
	if cl.wet and not hot_stated: out.uOceanDepth = cl.ocean_depth * ABYSS_RATIO
	return out

## Eases `targets` onto materials, writing a uniform only when it has moved.
class Binder extends RefCounted:
	const EASE_S := 0.6
	# How far a value must move to be worth a write, by uniform.
	const STEP := {"uMeanK": 0.05, "uCrustT": 2e-4, "uOceanDepth": 0.002, "cover": 1e-3}
	var value := {}
	var written := {}
	var _last_usec := 0

	func ease_to(want: Dictionary) -> Dictionary:
		var now := Time.get_ticks_usec()
		var k := 1.0 if value.is_empty() else 1.0 - exp(-float(now - _last_usec) * 1e-6 / EASE_S)
		_last_usec = now
		var moved := {}
		for key in want:
			var target := float(want[key])
			var cur := float(value.get(key, target))
			var next := cur + (target - cur) * k
			# Close enough is there, so a finished ease writes nothing more.
			var step := float(STEP.get(key, 1e-3))
			if absf(target - next) < step * 0.5: next = target
			value[key] = next
			if not written.has(key) or absf(next - float(written[key])) >= step or (next == target and written[key] != target):
				written[key] = next
				moved[key] = next
		return moved
