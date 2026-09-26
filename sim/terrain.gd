class_name Terrain
extends RefCounted

# ============================================================================
# TERRAIN & SURFACE CLIMATE — the GDScript half of sim/terrain.js.
# ----------------------------------------------------------------------------
# The model itself — isostasy, plate tectonics, craters, the P₂ insolation
# profile, the three overturning cells and the Whittaker biome diagram — is
# pure shader code and lives in shaders/bodies/terrain.gdshaderinc, whose
# header carries the derivation (the web build's TERRAIN_GLSL, ported with its
# comments). What is left here is what the JS module exported besides strings:
#
#   crust_threshold(land)  the fBm level that leaves `land` of the sphere
#                          above sea level (the inverse normal CDF)
#   terrain_uniforms(opts) the defaults for the uniforms the include declares,
#                          overridable per body by a preset
#   INCLUDE / NOISE_INCLUDE  the shader include paths — the Godot counterpart
#                          of importing TERRAIN_GLSL / NOISE_GLSL
# ============================================================================

const INCLUDE := "res://shaders/bodies/terrain.gdshaderinc"
const NOISE_INCLUDE := "res://shaders/bodies/terrain_noise.gdshaderinc"

## The fBm level that leaves `land` of the sphere above it. Seven octaves of
## value noise sum to something very close to a normal distribution — measured
## mean 0.4970, standard deviation 0.1065 — so the level is the inverse normal
## CDF, and asking for 29% land gets 29% land. The approximation below is the
## one the web build calls Moro's (the constants are Abramowitz & Stegun
## 26.2.23, |error| < 4.5e-4 in z); it is far finer than a coastline.
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
## override any of them per body. Keys are the JS option names (camelCase,
## data), values are what the shader receives.
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
