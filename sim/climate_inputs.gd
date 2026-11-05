class_name ClimateInputs
extends RefCounted

# A rocky or ocean world's climate inputs: their domain, what a spec states, and the
# seeded draw for the rest. Ranges and sources: docs/physics/climate.md#a-climate-per-world.

const KEYS := ["mixedLayer", "greenhouse", "albedoBase", "albedoIce", "T0", "oceans"]

# Metres of water, ε, albedo fractions and kelvin. ε reaches below Venus's 0.0089.
const DOMAIN := {
	"mixedLayer": [0.1, 5000.0], "greenhouse": [0.005, 1.0], "albedoBase": [0.0, 1.0],
	"albedoIce": [0.0, 1.0], "albedo": [0.0, 1.0], "T0": [3.0, 5000.0],
}

# The cosmic shoreline, I ∝ v_esc⁴ (Zahnle & Catling 2017, who draw it by eye and give no
# coefficient). Pinned so Mars, 5.03 km/s at 0.43 S⊕, lies on it.
const SHORELINE_KMS := 6.2
# A world past the last sunlight still has a shoreline: Pluto's flux, rounded down.
const S_FLOOR := 1e-4
# Above this retention a world that lost its water to a runaway keeps a Venus's air.
const THICK_RETENTION := 0.3

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
	var seed_ = spec.get("seed")
	if seed_ != null and not Structure._finite_number(seed_):
		return "seed must be a finite number."
	return ""

## A preset's `climate` block names only inputs, so a misspelt one cannot pass unread.
static func unknown_key(climate: Dictionary) -> String:
	for key in climate:
		if key not in KEYS: return str(key)
	return ""

## What the spec states. A home world's `albedo` describes its look, not this model's
## ice-free base: its climate keeps Climate.HOME_INPUTS unless albedoBase is stated.
static func stated(spec: Dictionary) -> Dictionary:
	var out := {}
	for key in KEYS:
		if spec.get(key) != null: out[key] = spec[key]
	var home: bool = spec.get("type") == "world" and spec.get("home") == true
	if not home and spec.get("albedo") != null and not out.has("albedoBase"):
		out.albedoBase = spec.albedo
	return out

## True when a patch touches nothing but this model's inputs, so an edit needs neither a
## new visual nor a new structure. `albedo` also draws the surface, so it is not one.
static func climate_only(patch: Dictionary) -> bool:
	if patch.is_empty(): return false
	for key in patch:
		if key not in KEYS: return false
	return true

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
	var eps: float
	var base: float
	var layer: float
	if wet:
		eps = _air_emissivity(x) + lerpf(-0.06, 0.06, u.call("greenhouse"))
		base = lerpf(0.25, 0.35, u.call("albedoBase"))
		ice = lerpf(0.3, 0.5, u.call("albedoIce"))
		layer = _log_between(10.0, 60.0, u.call("mixedLayer"))
	elif x < 0.0:
		eps = lerpf(0.9, 1.0, u.call("greenhouse"))
		base = lerpf(0.07, 0.25, u.call("albedoBase"))
		layer = _log_between(0.5, 3.0, u.call("mixedLayer"))
	elif S > s_runaway and x >= THICK_RETENTION:
		eps = _log_between(0.0089, 0.3, u.call("greenhouse"))
		base = lerpf(0.3, 0.77, u.call("albedoBase"))
		layer = _log_between(30.0, 300.0, u.call("mixedLayer"))
	else:
		eps = _air_emissivity(x) + lerpf(-0.06, 0.06, u.call("greenhouse"))
		base = lerpf(0.15, 0.35, u.call("albedoBase"))
		layer = _log_between(0.5, 3.0, u.call("mixedLayer"))
	return {"mixedLayer": layer, "greenhouse": minf(eps, 1.0), "albedoBase": base, "albedoIce": ice, "oceans": wet}

## ε falls as the air thickens: Mars's 0.95 on the shoreline, Earth's 0.61 at x = 1,
## 0.45 for a super-Earth's deeper atmosphere at x = 2.
static func _air_emissivity(x: float) -> float:
	if x <= 1.0: return lerpf(0.95, 0.61, clampf(x, 0.0, 1.0))
	return lerpf(0.61, 0.45, minf(x - 1.0, 1.0))

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
		var S := cl.insolation(b, stars)
		cl.drawn = draw(str(U.nz(b.spec.get("seed"), b.name)), run_seed, b.mass, b.radius, S,
			float(cl.habitable_zone().inner), inputs.get("oceans"))
		cl.apply_inputs(inputs)
		cl.start_at(float(U.nz(inputs.get("T0"), cl.equilibrium_T(S))))
	cl.step(1e-6, b, stars)
	return cl
