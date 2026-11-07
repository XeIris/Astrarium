class_name ClimateInputs
extends RefCounted

# A rocky or ocean world's climate inputs: their domain, what a spec states, and the
# seeded draw for the rest. Ranges and sources: docs/physics/climate.md#a-climate-per-world.

const KEYS := ["mixedLayer", "albedoBase", "albedoIce", "T0", "oceans", "salinity",
	"pN2", "pO2", "pAr", "pCO2", "pCH4", "pSO2"]
# Inputs that also draw the surface, whose visual takes them as uniforms.
const SURFACE_KEYS := ["land", "oceanDepth"]

# Metres of water, albedo fractions, kelvin, bar, km and g/kg. The gases' upper ends are the
# OLR model's domain (docs/physics/climate.md#an-atmosphere-with-composition): Venus is inside
# it, CH₄ stops short of where Myhre's √ term has no support, and salinity at the NaCl eutectic.
const DOMAIN := {
	"mixedLayer": [0.1, 5000.0], "albedoBase": [0.0, 1.0],
	"albedoIce": [0.0, 1.0], "albedo": [0.0, 1.0], "T0": [3.0, 5000.0],
	"pN2": [0.0, 200.0], "pO2": [0.0, 50.0], "pAr": [0.0, 50.0], "pCO2": [0.0, 100.0],
	"pCH4": [0.0, 1e-3], "pSO2": [0.0, 0.1],
	"land": [0.0, 1.0], "oceanDepth": [0.0, 100.0], "salinity": [0.0, 230.0],
}
const MAX_AIR_BAR := 200.0

# The cosmic shoreline, I ∝ v_esc⁴ (Zahnle & Catling 2017, who draw it by eye and give no
# coefficient). Pinned so Mars, 5.03 km/s at 0.43 S⊕, lies on it.
const SHORELINE_KMS := 6.2
# A world past the last sunlight still has a shoreline: Pluto's flux, rounded down.
const S_FLOOR := 1e-4
# Above this retention a world that lost its water to a runaway keeps a Venus's air.
const THICK_RETENTION := 0.3
# The surface temperature an ocean world's weathering settles at, K, and the CO₂ it may
# use, bar: Kopparapu's 8 bar is where more CO₂ stops warming (assumed ranges otherwise).
const WEATHERING_K := [278.0, 295.0]
const CO2_DRAWN := [1e-5, 8.0]

static func applies(type) -> bool:
	return type == "planet" or type == "world"

## Empty when every climate field the spec states is inside the model's domain.
static func input_error(spec: Dictionary) -> String:
	for field in DOMAIN:
		var value = spec.get(field)
		if value == null: continue
		var range_: Array = DOMAIN[field]
		if not Structure._finite_number(value) or float(value) < float(range_[0]) or float(value) > float(range_[1]):
			return "%s must be a finite number from %s to %s." % [field, Structure._num(range_[0]), Structure._num(range_[1])]
	var base = spec.get("albedoBase")
	var ice = spec.get("albedoIce")
	if base != null and ice != null and float(base) + float(ice) > 1.0:
		return "albedoBase + albedoIce cannot reflect more than all the light."
	var oceans = spec.get("oceans")
	if oceans != null and not oceans is bool:
		return "oceans must be a boolean."
	if oceans == true and (spec.get("land") == 1.0 or spec.get("oceanDepth") == 0.0):
		return "A world with oceans needs a sea: land below 1 and oceanDepth above 0."
	var total := 0.0
	for gas in Atmosphere.GASES:
		total += float(U.nz(spec.get(gas), 0.0))
	if total > MAX_AIR_BAR:
		return "The gases' partial pressures cannot sum past %s bar." % Structure._num(MAX_AIR_BAR)
	var seed_ = spec.get("seed")
	if seed_ != null and not Structure._finite_number(seed_):
		return "seed must be a finite number."
	return ""

## A preset's `climate` block names only inputs, so a misspelt one cannot pass unread.
static func unknown_key(climate: Dictionary) -> String:
	for key in climate:
		if key not in KEYS and key not in SURFACE_KEYS: return str(key)
	return ""

## What the spec states. A home world's `albedo` describes its look, not this model's
## ice-free base: its climate keeps Climate.HOME_INPUTS unless albedoBase is stated.
static func stated(spec: Dictionary) -> Dictionary:
	var out := {}
	for key in KEYS + SURFACE_KEYS:
		if spec.get(key) != null: out[key] = spec[key]
	var home: bool = spec.get("type") == "world" and spec.get("home") == true
	if not home and spec.get("albedo") != null and not out.has("albedoBase"):
		out.albedoBase = spec.albedo
	return out

## True when a patch touches nothing but this model's inputs, so an edit needs neither a
## new visual nor a new structure. `albedo` also draws the surface, and its colours are built.
static func climate_only(patch: Dictionary) -> bool:
	if patch.is_empty(): return false
	for key in patch:
		if key not in KEYS and key not in SURFACE_KEYS: return false
	return true

static func touches_surface(patch: Dictionary) -> bool:
	for key in SURFACE_KEYS:
		if patch.has(key): return true
	return false

## log₁₀ of (v_esc/SHORELINE_KMS)⁴/S: positive keeps an atmosphere. Mars 0, Venus 0.6, Earth 1.
static func retention(mass: float, radius_au: float, S: float) -> float:
	var v_kms := sqrt(2.0 * Physics.G * mass / radius_au) * Rocketry.AU_M / Rocketry.YR_S / 1000.0
	return 4.0 * U.log10(v_kms / SHORELINE_KMS) - U.log10(maxf(S, S_FLOOR))

## The inputs of a world with nothing stated. `key` is the body's seed or name; each field
## has its own stream, so a field added later leaves the existing ones as they were.
## `oceans`, when the spec states it, decides which kind of world the rest is drawn for.
static func draw(key: String, run_seed: int, mass: float, radius_au: float, S: float, s_runaway: float, oceans = null) -> Dictionary:
	var x := retention(mass, radius_au, S)
	var u := func(field: String) -> float: return _uniform(key, run_seed, field)
	# Wet worlds need air to hold a liquid and a star that has not boiled it off.
	var wet: bool = oceans if oceans != null else (x >= 0.0 and S <= s_runaway and u.call("oceans") < 0.9 * minf(x, 1.0))
	var ice := 0.0
	var base: float
	var layer: float
	var air: Dictionary
	if wet:
		base = lerpf(0.25, 0.35, u.call("albedoBase"))
		ice = lerpf(0.3, 0.5, u.call("albedoIce"))
		layer = _log_between(10.0, 60.0, u.call("mixedLayer"))
		air = _wet_air(u, mass, radius_au, S, base)
	elif x < 0.0:
		base = lerpf(0.07, 0.25, u.call("albedoBase"))
		layer = _log_between(0.5, 3.0, u.call("mixedLayer"))
		air = {}
	elif S > s_runaway and x >= THICK_RETENTION:
		base = lerpf(0.3, 0.77, u.call("albedoBase"))
		layer = _log_between(30.0, 300.0, u.call("mixedLayer"))
		var co2 := _log_between(10.0, 100.0, u.call("pCO2"))
		air = {"pCO2": co2, "pN2": co2 * lerpf(0.01, 0.05, u.call("pN2")),
			"pSO2": _log_between(1e-5, 0.03, u.call("pSO2"))}
	else:
		base = lerpf(0.15, 0.35, u.call("albedoBase"))
		layer = _log_between(0.5, 3.0, u.call("mixedLayer"))
		# Mars's 6 mbar on the shoreline, thickening with what the world can hold.
		var co2 := minf(0.006 * pow(10.0, 1.5 * x) * _log_between(0.3, 3.0, u.call("pCO2")), 1.0)
		air = {"pCO2": co2, "pN2": co2 * lerpf(0.03, 0.5, u.call("pN2"))}
	var out := {"mixedLayer": layer, "albedoBase": base, "albedoIce": ice, "oceans": wet,
		"land": _drawn_land(u.call("land")), "oceanDepth": _log_between(0.5, 10.0, u.call("oceanDepth")),
		"salinity": lerpf(5.0, 60.0, u.call("salinity"))}
	for gas in Atmosphere.GASES: out[gas] = float(air.get(gas, 0.0))
	return out

# One world in ten has no land; the rest span a shelf sea to Earth's more than twice over.
static func _drawn_land(v: float) -> float:
	return 0.0 if v < 0.1 else lerpf(0.05, 0.7, (v - 0.1) / 0.9)

## An ocean world's air: N₂ and O₂ drawn, and CO₂ where the carbonate-silicate cycle would have
## left it. There is no live CO₂ cycle, so the draw is the settled state of one.
static func _wet_air(u: Callable, mass: float, radius_au: float, S: float, base: float) -> Dictionary:
	var n2 := _log_between(0.3, 3.0, u.call("pN2"))
	var air := {"pN2": n2, "pO2": lerpf(0.0, 0.3, u.call("pO2")), "pAr": n2 * lerpf(0.005, 0.02, u.call("pAr")),
		"pCH4": _log_between(1e-7, 1e-5, u.call("pCH4")), "pSO2": 0.0}
	var target := lerpf(WEATHERING_K[0], WEATHERING_K[1], u.call("pCO2"))
	var gravity := Physics.G * mass / (radius_au * radius_au) * Rocketry.AU_M / (Rocketry.YR_S * Rocketry.YR_S)
	var absorbed := (1.0 - base) * S * Climate.S0 / 4.0
	var lo := log(CO2_DRAWN[0])
	var hi := log(CO2_DRAWN[1])
	for i in 14:
		var mid := 0.5 * (lo + hi)
		air.pCO2 = exp(mid)
		if Atmosphere.new(air, gravity).olr(target, 1.0) > absorbed: lo = mid
		else: hi = mid
	air.pCO2 = exp(0.5 * (lo + hi))
	return air

static func _log_between(lo: float, hi: float, u: float) -> float:
	return lo * pow(hi / lo, u)

# FNV-1a over the UTF-8 name, so a draw does not depend on Godot's own hash or RNG.
static func _uniform(key: String, run_seed: int, field: String) -> float:
	var h := 2166136261
	for byte in ("%s|%d|%s" % [key, run_seed, field]).to_utf8_buffer():
		h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
	return GiantVisual.Mulberry.new(h).next()

## The body's Climate. `stars` are the bodies that light it now. A home world keeps the
## home model's inputs and start; another starts in balance with its light unless T0 is stated.
static func build(b: Body, stars: Array, run_seed: int) -> Climate:
	var inputs := stated(b.spec)
	var cl: Climate
	if b.home:
		cl = Climate.new(inputs)
		cl.drawn = Climate.HOME_INPUTS
	else:
		cl = Climate.new()
		cl.set_world(b.mass, b.radius)
		var S := cl.insolation(b, stars)
		cl.drawn = draw(str(U.nz(b.spec.get("seed"), b.name)), run_seed, b.mass, b.radius, S,
			float(cl.habitable_zone().inner), inputs.get("oceans"))
		cl.apply_inputs(inputs)
		cl.start_at(float(U.nz(inputs.get("T0"), cl.equilibrium_T(S))))
	cl.step(1e-6, b, stars)
	return cl
