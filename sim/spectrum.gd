class_name Spectrum
extends RefCounted

# Blackbody imaging from physical temperature encoded in HDR alpha.
# Sky bands are composited separately; reflected and planetary thermal spectra
# are outside this approximation. See docs/godot.md and docs/physics/sky.md.

## h/k, in kelvin·seconds — converts a frequency straight to the temperature
## scale where that frequency's Planck exponent is unity.
const H_OVER_K := 4.799243e-11

## The log encoding every emitter publishes its temperature with:
## a = ln(T) / TEMP_LOG_SCALE, clamped below 1 (1.0 is reserved: "no data").
const TEMP_LOG_SCALE := 25.33

# Per-band exposure: `trefFactor` scales the hottest source in the field, and
# `trefFloor` is a hard limit so a 5000 K star can't blaze in gamma.
const BANDS := [
	{
		"id": "radio", "label": "Radio", "short": "RADIO",
		"nu": 1e9, "trefFactor": 1.8, "trefFloor": 2000.0,
		"note": "1 GHz. Far down the Rayleigh–Jeans tail of everything here, where brightness is simply proportional to temperature — so nothing is cut off, and the image is the scene’s temperature map at low gain.",
	},
	{
		"id": "microwave", "label": "Microwave", "short": "MICRO",
		"nu": 1e11, "trefFactor": 1.3, "trefFloor": 2000.0,
		"note": "100 GHz. Still Rayleigh–Jeans for every source in this scene, so it differs from radio only in sensitivity. That similarity is the real physics, not a shortcut.",
	},
	{
		"id": "infrared", "label": "Infrared", "short": "IR",
		"nu": 3e13, "trefFactor": 1.0, "trefFloor": 2000.0,
		"note": "10 µm. The coolest band with a Wien cutoff that bites in this scene: material below ~1500 K begins to fade while stars and the disc stay bright.",
	},
	{
		"id": "visible", "label": "Visible", "short": "VIS",
		"nu": 5.45e14, "trefFactor": 1.0, "trefFloor": 2000.0,
		"note": "550 nm. True colour — the frame exactly as rendered, with no remapping.",
	},
	{
		"id": "ultraviolet", "label": "Ultraviolet", "short": "UV",
		"nu": 1.5e15, "trefFactor": 1.0, "trefFloor": 8000.0,
		"note": "200 nm. The cutoff bites hard: cool K and M stars all but vanish while hot A/B stars and the inner accretion disc blaze.",
	},
	{
		"id": "xray", "label": "X-ray", "short": "X-RAY",
		"nu": 7.3e16, "trefFactor": 1.0, "trefFloor": 1.0e6,
		"note": "0.3 keV soft X-ray. Only million-kelvin material survives — the inner disc and neutron-star surfaces. Ordinary stars are black silhouettes.",
	},
	{
		"id": "gamma", "label": "Gamma", "short": "GAMMA",
		"nu": 2.4e19, "trefFactor": 1.0, "trefFloor": 3.0e8,
		"note": "~100 keV. Nothing thermal in this scene is hot enough to reach here, so the frame goes black. Real gamma sources are non-thermal (synchrotron, pair processes), which this model does not simulate.",
	},
]

const VISIBLE_BAND := 3

## Uniform values for a band, exposed for a scene whose hottest emitter is
## `scene_max_t` kelvin.
static func band_uniform_data(index: int, scene_max_t: float = 5800.0) -> Dictionary:
	var b: Dictionary = BANDS[clampi(index, 0, BANDS.size() - 1)]
	return {
		"theta": H_OVER_K * float(b.nu),
		"tref": maxf(scene_max_t * float(b.trefFactor), float(b.trefFloor)),
	}

## The alpha an emitter publishes for temperature T (see TEMP_LOG_SCALE).
static func temp_code(t: float) -> float:
	return minf(log(maxf(t, 1.0)) / TEMP_LOG_SCALE, 0.98) if t > 0.0 else 0.0
