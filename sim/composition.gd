class_name Composition
extends RefCounted

# What a world's air and water are made of, as the Foundry and the live editor ask about it:
# named mixes, what the climate model expects of a candidate, and the rows the pie draws. The
# expectation is the real model run on a scratch body, so nothing here is a second formula and
# nothing touches the stage. docs/physics/climate.md#what-the-editor-shows.

# What the editor can set: every climate input except a world's starting temperature.
const EDIT_KEYS := ["mixedLayer", "albedoBase", "albedoIce", "oceans", "land", "oceanDepth", "salinity",
	"pN2", "pO2", "pAr", "pCO2", "pCH4", "pSO2"]

# Mixes state every key they care about. What a mix leaves out is drawn, as for any world.
# Earth's is Climate.HOME_INPUTS; Mars's and Venus's are the solar preset's (NSSDC's air).
const MIXES := {
	"earth": { "label": "Earth-like", "inputs": { "oceans": true, "land": 0.29, "oceanDepth": 3.7, "salinity": 35.0,
		"mixedLayer": 12.0, "albedoBase": 0.306, "albedoIce": 0.45,
		"pN2": 0.79173, "pO2": 0.21243, "pAr": 0.009471, "pCO2": 4.2588e-4, "pCH4": 1.9672e-6, "pSO2": 0.0 } },
	"ocean": { "label": "Global ocean", "inputs": { "oceans": true, "land": 0.0, "oceanDepth": 10.0, "salinity": 35.0,
		"mixedLayer": 50.0, "albedoBase": 0.25, "albedoIce": 0.45,
		"pN2": 0.79173, "pO2": 0.21243, "pAr": 0.009471, "pCO2": 4.2588e-4, "pCH4": 1.9672e-6, "pSO2": 0.0 } },
	"mars": { "label": "Mars-like", "inputs": { "oceans": false, "mixedLayer": 1.5, "albedoBase": 0.25, "albedoIce": 0.0,
		"pCO2": 6.048e-3, "pN2": 1.647e-4, "pAr": 1.234e-4, "pO2": 1.018e-5, "pCH4": 0.0, "pSO2": 0.0 } },
	"venus": { "label": "Venus-like", "inputs": { "oceans": false, "mixedLayer": 270.0, "albedoBase": 0.77, "albedoIce": 0.0,
		"pCO2": 88.78, "pN2": 3.22, "pAr": 0.00644, "pO2": 0.0, "pCH4": 0.0, "pSO2": 0.0138 } },
	"bare": { "label": "Airless rock", "inputs": { "oceans": false, "mixedLayer": 1.5, "albedoBase": 0.12, "albedoIce": 0.0,
		"pN2": 0.0, "pO2": 0.0, "pAr": 0.0, "pCO2": 0.0, "pCH4": 0.0, "pSO2": 0.0 } },
}

# The two picks that are not mixes. The seeded draw states nothing; custom is whatever was edited.
const DRAWN := "drawn"
const CUSTOM := "custom"

# A preview's horizon: long enough for a slow column to answer, and a fixed step count so its
# cost does not depend on how slow the column is (geometric, since the ice is the slow part).
const HORIZON_YEARS := 100.0
const SETTLE_STEPS := 28
const SETTLE_FIRST := 0.02

## [[value, label], ...] for the mix picker.
static func options() -> Array:
	var out := [[DRAWN, "Seeded draw"]]
	for key in MIXES: out.append([key, MIXES[key].label])
	out.append([CUSTOM, "Custom"])
	return out

## The patch that makes a world this mix. A key the mix leaves out returns to the draw.
static func mix_patch(mix: String) -> Dictionary:
	var inputs: Dictionary = MIXES[mix].inputs if MIXES.has(mix) else {}
	var patch := {}
	for key in EDIT_KEYS: patch[key] = inputs.get(key)
	return patch

## Which pick these stated inputs are.
static func matching(stated: Dictionary) -> String:
	var mine := {}
	for key in EDIT_KEYS:
		if stated.get(key) != null: mine[key] = stated[key]
	if mine.is_empty(): return DRAWN
	for key in MIXES:
		if mine == MIXES[key].inputs: return key
	return CUSTOM

## What the model expects of a world built from `spec` where `spec.pos` puts it, lit by `stars`.
## {"error": reason} for a request the model's domain rejects, {} for a body with no climate.
static func preview(spec: Dictionary, stars: Array, run_seed: int) -> Dictionary:
	var reason := Structure.input_error(spec)
	if reason != "": return { "error": reason }
	var b := Derive.new_body(-1, spec)
	if not ClimateInputs.applies(b.type): return {}
	var cl := ClimateInputs.build(b, stars, run_seed)
	var start := cl.T
	settle(cl, b, stars)
	var out := read(cl, b, ClimateInputs.stated(b.spec))
	out.startT = start
	return out

## What `patch` would do to the live world `b`, from where it is now. `b` is only read.
static func preview_edit(b: Body, patch: Dictionary, stars: Array) -> Dictionary:
	var spec := U.merged(b.spec, patch)
	spec.type = b.type
	spec.mass = b.mass
	var reason := Structure.input_error(spec)
	if reason != "": return { "error": reason }
	if b.climate == null: return {}
	var cl: Climate = b.climate.fork()
	var stated := ClimateInputs.stated(spec)
	cl.apply_inputs(stated)
	settle(cl, b, stars)
	var out := read(cl, b, stated)
	out.startT = b.climate.T
	return out

## Run a scratch climate forward with its stars held where they are.
static func settle(cl: Climate, b: Body, stars: Array) -> void:
	var total := maxf(HORIZON_YEARS, 6.0 * cl.tau_years)
	var ratio := pow(total / SETTLE_FIRST, 1.0 / float(SETTLE_STEPS))
	var at := 0.0
	for i in SETTLE_STEPS:
		var next := SETTLE_FIRST * pow(ratio, float(i + 1))
		cl.step(next - at, b, stars)
		at = next
	cl.history.clear()

## The panel's numbers, all read off the climate.
static func read(cl: Climate, b: Body, stated: Dictionary) -> Dictionary:
	# The same sunlight on the same ground, ice included, with nothing overhead.
	var airless_t := RockyVisual.surface_temp_k(cl.S, cl.albedo(cl.T).alb, 1.0)
	var bar := cl.air.p_dry + cl.steam * cl.steam_bar
	var scale := Rocketry.R_GAS * maxf(cl.T, 30.0) / (cl.air.mean_molar * cl.gravity) if bar >= Climate.AIRLESS_BAR else 0.0
	return {
		"T": cl.T, "S": cl.S, "airlessT": airless_t, "air": bar, "gravity": cl.gravity,
		"molar": cl.air.mean_molar, "scaleM": scale, "era": cl.era,
		"ice": cl.ice, "iceEdge": cl.ice_edge, "snowball": cl.snowball, "clouds": cl.clouds, "humidity": cl.humidity,
		"wet": cl.wet, "ocean": cl.ocean, "steam": cl.steam, "land": cl.land, "depth": cl.ocean_depth,
		"salinity": cl.salinity, "water": cl.water_column,
		"freeze": Climate.freezing_point(cl.salinity), "boil": cl.boiling_point(cl.steam),
		"sea": sea_state(cl), "sky": cl.sky_rgb(), "tau": float(cl.sky.get("tau", 0.0)), "thick": float(cl.sky.get("thick", 0.0)),
		"hz": cl.habitable_zone(), "retention": ClimateInputs.retention(b.mass, b.radius, cl.S),
		"stated": stated, "rows": rows(cl, stated), "surface": surface_shares(cl),
		"inputs": {
			"mixedLayer": cl.mixed_layer, "albedoBase": cl.albedo_base, "albedoIce": cl.albedo_ice,
			"oceans": cl.wet, "land": cl.land, "oceanDepth": cl.ocean_depth, "salinity": cl.salinity,
			"pressures": cl.pressures.duplicate(),
		},
	}

## What the sea is doing, in a few words.
static func sea_state(cl: Climate) -> String:
	if not cl.wet: return "none"
	if cl.ocean + cl.steam <= 0.0: return "lost to space"
	var key: String = cl.era.key
	if key == "RUNAWAY": return "boiling"
	if key == "DRY": return "too little to stand"
	if key == "ICE_SHELL": return "ice shell"
	if cl.snowball or key == "DEEP_FREEZE": return "frozen"
	if cl.land < Climate.NO_LAND: return "global ocean"
	return "open"

## The gases, largest first, with water last among equals: it follows temperature. `stated`
## says which gases a world states rather than drew.
static func rows(cl: Climate, stated: Dictionary) -> Array:
	var out := []
	for key in Atmosphere.GASES:
		var bar := float(cl.pressures.get(key, 0.0))
		if bar <= 0.0: continue
		var gas: Dictionary = Atmosphere.GASES[key]
		out.append({ "key": key, "label": gas.label, "color": gas.color, "bar": bar,
			"source": "stated" if stated.get(key) != null else "drawn" })
	var water := cl.vapour_bar(cl.T) + cl.steam * cl.steam_bar
	if water > 0.0:
		out.append({ "key": "H2O", "label": "H₂O", "color": 0xa8dcff, "bar": water, "source": "follows" })
	out.sort_custom(func(a, b): return a.bar > b.bar or (a.bar == b.bar and a.key < b.key))
	return out

## The surface as shares of the globe: land, open sea and ice over either.
static func surface_shares(cl: Climate) -> Dictionary:
	var standing: bool = cl.wet and cl.ocean > 0.0 and cl.era.key != "DRY"
	var ice := clampf(cl.ice, 0.0, 1.0) if standing else 0.0
	var sea := (1.0 - cl.land) if standing else 0.0
	return { "ice": ice, "sea": sea * (1.0 - ice), "land": (1.0 - sea) * (1.0 - ice) }

## A typed pressure: "0.2", "426 ubar", "6 mbar", "1e-4 bar". NAN when it does not read as one.
static func parse_bar(text: String) -> float:
	var t := text.strip_edges().to_lower().replace("µ", "u").replace("μ", "u")
	var scale := 1.0
	for unit in [["ubar", 1e-6], ["mbar", 1e-3], ["bar", 1.0], ["none", 0.0]]:
		if t.ends_with(unit[0]):
			t = t.substr(0, t.length() - String(unit[0]).length()).strip_edges()
			scale = unit[1]
			if t == "" and unit[0] == "none": return 0.0
			break
	return t.to_float() * scale if t.is_valid_float() else NAN
