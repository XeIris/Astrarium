class_name Terrain
extends RefCounted

# TERRAIN & SURFACE CLIMATE, the CPU half. The model is shader code in
# shaders/bodies/terrain.gdshaderinc (with its derivation). Here:
#   crust_threshold(land)    the fBm level leaving `land` of the sphere above sea
#                            level (the inverse normal CDF)
#   terrain_uniforms(opts)   defaults for the include's uniforms, per-body overridable
#   INCLUDE / NOISE_INCLUDE  the include paths

const INCLUDE := "res://shaders/bodies/terrain.gdshaderinc"
const NOISE_INCLUDE := "res://shaders/bodies/terrain_noise.gdshaderinc"

## Seven octaves of value noise are near-normal (mean 0.4970, sd 0.1065), so the level
## is the inverse normal CDF and 29% land gives 29% land. Abramowitz & Stegun 26.2.23,
## |error| < 4.5e-4 in z.
static func crust_threshold(land: float) -> float:
	var q := 1.0 - minf(maxf(land, 0.002), 0.998)
	# rational approximation to the standard normal quantile
	var tail := minf(q, 1.0 - q)
	var t := sqrt(-2.0 * log(tail))
	var z := t - (2.515517 + 0.802853 * t + 0.010328 * t * t) / \
			(1.0 + 1.432788 * t + 0.189269 * t * t + 0.001308 * t * t * t)
	if q < 0.5:
		z = -z
	return 0.4970 + 0.1065 * z

## Defaults for the uniforms terrain.gdshaderinc declares. A preset can
## override any of them per body. Keys are camelCase option names; values are
## what the shader receives.
static func terrain_uniforms(opts: Dictionary = {}) -> Dictionary:
	return {
		"uPlateScale": float(U.nz(opts.get("plateScale"), 2.6)),
		"uLandRelief": float(U.nz(opts.get("landRelief"), 3.2)),
		"uOceanDepth": float(U.nz(opts.get("oceanDepth"), 4.6)),
		"uCrustT": crust_threshold(float(U.nz(opts.get("continent"), 0.35))),
		"uMeanK": float(U.nz(opts.get("meanK"), 288.0)),
		"uTransport": float(U.nz(opts.get("transport"), 0.42)),
		"uArid": float(U.nz(opts.get("arid"), 0.0)),
	}
