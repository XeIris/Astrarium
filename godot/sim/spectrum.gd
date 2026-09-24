class_name Spectrum
extends RefCounted

# ============================================================================
# SIMULATED MULTI-WAVELENGTH IMAGING
# ----------------------------------------------------------------------------
# Real astronomy almost never looks at things in visible light. The same black
# hole is a faint smudge to the eye, a blazing point in X-rays, and a pair of
# jets in the radio — because what you see is not "the object" but the object's
# Planck spectrum sampled through one narrow window.
#
# This module re-images the rendered frame through a chosen window. It needs
# one thing per pixel that a colour buffer does not normally carry: the
# emitting material's TEMPERATURE. So the emitters publish it directly —
# the accretion disc, stellar photospheres and neutron-star surfaces each
# write their true temperature, log-encoded, into the alpha channel of the HDR
# buffer. Pixels with no such data (lit geometry) fall back to inferring T from
# colour, which works because those were coloured from the Planck locus in the
# first place.
#
# (In the Godot build that "alpha channel" is produced by a second camera over
# the same world — the temperature pass — and zipped back into the HDR buffer's
# alpha by shaders/post/compose.glsl. Everything downstream of that is the web
# build's chain unchanged. See PORT_GUIDE.md.)
#
# The celestial background does neither. sim/sky.gd composites it at the band's
# own frequency and marks it with SKY_ALPHA so the remap hands it straight to
# the palette. It has to work that way, because the non-visible sky is mostly
# non-thermal and has no temperature for a Planck ratio to consume.
#
# THE CHAIN, PER PIXEL (shaders/post/remap.glsl)
#
#   1. Recover T — from alpha where an emitter published it, otherwise from the
#      blue/red ratio in linear light, which is monotonic along the Planck locus.
#
#   2. Evaluate the band's surface brightness relative to the band's reference
#      temperature. With B_ν = 2hν³/c² / (exp(hν/kT) − 1), the ν³ prefactor is
#      common to both and cancels, leaving only the Planck exponent — which is
#      the whole story anyway, because the Wien cutoff is what makes the bands
#      differ. A source appears in a band if and only if kT is comparable to
#      hν. Everything is computed in logs: hν/kT reaches ~1750 for soft X-rays
#      off a 6000 K star, which overflows a float on the first line otherwise.
#
#   3. The rendered luminance is used only as a coverage mask — "is there
#      emitting material on this pixel" — never as the band radiance.
#
#   4. Per-band gain, log stretch, false-colour ramp. All three are what a real
#      observatory image does.
#
# WHAT THIS IS NOT: it re-images blackbody continuum only. Real non-thermal
# emission — synchrotron from a jet, cyclotron lines, molecular lines, 21 cm —
# is not modelled, and neither is reflected starlight or a planet's own thermal
# glow, which is why worlds go dark outside the visible here when a real
# infrared image would show them plainly.
# ============================================================================

## h/k, in kelvin·seconds — converts a frequency straight to the temperature
## scale where that frequency's Planck exponent is unity.
const H_OVER_K := 4.799243e-11

## The log encoding every emitter publishes its temperature with:
## a = ln(T) / TEMP_LOG_SCALE, clamped below 1 (1.0 is reserved: "no data").
const TEMP_LOG_SCALE := 25.33

# Each band's gain is set the way an observer sets one: expose for the
# brightest target actually in the field. `trefFactor` scales the hottest
# source present (a factor of 1 puts it near full scale, larger under-exposes),
# and `trefFloor` is a hard physical limit that scene-adaptive exposure must
# never cross — it is what keeps the statement "you need a million kelvin to
# emit soft X-rays" true. Without the floor, auto-exposure would happily make
# a 5000 K star blaze in the gamma band.
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
