class_name Terrain
extends RefCounted

# TERRAIN & SURFACE CLIMATE, the CPU half. The model is shader code in
# shaders/bodies/terrain.gdshaderinc (with its derivation). Here:
#   crust_threshold(land)    the fBm level leaving `land` of the sphere above sea
#                            level (the inverse normal CDF)
#   terrain_uniforms(opts)   defaults for the include's uniforms, per-body overridable
#   cloud_global_z(cover)    the probit offset that gives `cover` of the globe opaque
#                            cloud under the zonal climatology (cloud_climate.gdshaderinc)
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
static func terrain_uniforms(opts: VisualOpts) -> Dictionary:
	return {
		"uPlateScale": float(U.nz(opts.plate_scale, 2.6)),
		"uLandRelief": float(U.nz(opts.land_relief, 3.2)),
		"uOceanDepth": float(U.nz(opts.ocean_depth, 4.6)),
		"uCrustT": crust_threshold(float(U.nz(opts.continent, 0.35))),
		"uMeanK": 288.0,
		"uTransport": float(U.nz(opts.transport, 0.42)),
		"uArid": float(U.nz(opts.arid, 0.0)),
	}

## shaders/common/cloud_climate.gdshaderinc's cloud_zonal_z: phi is latitude, itcz the
## ITCZ's latitude (rad).
static func cloud_zonal_z(phi: float, itcz := 0.0) -> float:
	var a := absf(phi)
	var i := (phi - itcz) / 0.14
	var s := (a - 0.45) / 0.17
	var k := (a - 1.0) / 0.22
	return 0.30 * exp(-i * i) - 0.50 * exp(-s * s) + 0.72 * exp(-k * k)

## Standard normal CDF (Abramowitz & Stegun 7.1.26 through erf, |error| < 1.5e-7).
static func normal_cdf(z: float) -> float:
	var x := absf(z) / sqrt(2.0)
	var t := 1.0 / (1.0 + 0.3275911 * x)
	var e := 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t \
		+ 0.254829592) * t * exp(-x * x)
	return 0.5 * (1.0 + (e if z >= 0.0 else -e))

## The global probit offset whose area-weighted mean of Φ(z + cloud_zonal_z) is
## `cover` (the world's cloudCover: its fraction under opaque cloud), by bisection.
## Saturates at ±8 for 0 and 1.
static func cloud_global_z(cover: float) -> float:
	if cover <= 0.0: return -8.0
	if cover >= 1.0: return 8.0
	var lo := -8.0
	var hi := 8.0
	for it in 40:
		var mid := 0.5 * (lo + hi)
		var s := 0.0
		var w := 0.0
		for i in 90:
			var phi := -PI * 0.5 + (i + 0.5) * PI / 90.0
			s += cos(phi) * normal_cdf(mid + cloud_zonal_z(phi))
			w += cos(phi)
		if s / w < cover: lo = mid
		else: hi = mid
	return 0.5 * (lo + hi)
