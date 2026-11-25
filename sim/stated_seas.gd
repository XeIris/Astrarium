class_name StatedSeas
extends RefCounted

# Seas a world's crust does not draw, stated from what was mapped: Titan's three northern maria from Cassini's
# radar. Each is a union of spherical caps (lat, lon, radius) sized to its mapped area, in the planet mesh's
# latitude and east longitude; the crust is procedural, so its longitudes are not tied to the IAU's meridian.
# What reads them: the pin (PlanetPin), the ground surveyed or stood on there (SurfaceRelief, SurfaceGround),
# the sea in flight (SurfaceSea) and the flight's far ground. Pure data and arithmetic: safe on any thread.
# docs/physics/ocean.md#titans-seas.

## Depth from the shore inward goes as (d / R)^DEPTH_POWER of the deepest, R the cap's radius: with Ligeia's
## 170 m deepest that gives Le Gall et al.'s (2016) mean of about 50 m (the mean of (d/R)^p over a disc is
## 2 / ((p + 1)(p + 2))).
const DEPTH_POWER := 1.2

## Cassini's west longitudes are negated to east. Areas: Hayes 2016 (Annual Review), Stofan et al. 2012.
## - Ligeia Mare, 79° N 248° W, 126,000 km² (a 200 km cap); 170 m measured (Mastrogiuseppe et al. 2014).
## - Kraken Mare, centred 68° N 310° W, 500,000 km² and 1,170 km long: two basins as two caps; its main body
##   deeper than 300 m (Poggiali et al. 2020), so 300 m is a floor on its depth.
## - Punga Mare, 85.1° N 339.7° W, 61,000 km² (a 139 km cap); 120 m along the altimetry track
##   (Mastrogiuseppe et al. 2018).
const MARIA := {
	"Titan": [
		{"name": "Ligeia Mare", "depth": 170.0, "caps": [[79.0, -248.0, 200.0e3]]},
		{"name": "Kraken Mare", "depth": 300.0, "caps": [[73.0, -315.0, 280.0e3], [62.0, -305.0, 300.0e3]]},
		{"name": "Punga Mare", "depth": 120.0, "caps": [[85.1, -339.7, 139.0e3]]},
	],
}

static func has(world: String) -> bool:
	return MARIA.has(world)

## The mesh-frame unit vector at a latitude and east longitude, rad (PlanetPin.direction's convention).
static func unit(lat: float, lon: float) -> Vector3:
	return Vector3(cos(lon) * cos(lat), sin(lat), -sin(lon) * cos(lat))

## The mare under (lat, lon), rad, on a world of radius `radius_m`: {name, inside (m in from the nearest
## shore, negative outside), depth (m of liquid there, 0 outside), deepest, reach (the cap's radius, m)}, or
## an empty Dictionary where no mare comes within `near_m` of it.
static func at(world: String, lat: float, lon: float, radius_m: float, near_m := 0.0) -> Dictionary:
	if not MARIA.has(world): return {}
	var p := unit(lat, lon)
	var best := {}
	var best_in := -INF
	for mare: Dictionary in MARIA[world]:
		for cap: Array in mare.caps:
			var c := unit(deg_to_rad(float(cap[0])), deg_to_rad(float(cap[1])))
			var inside := float(cap[2]) - acos(clampf(p.dot(c), -1.0, 1.0)) * radius_m
			if inside > best_in:
				best_in = inside
				best = {"name": mare.name, "inside": inside, "deepest": float(mare.depth), "reach": float(cap[2])}
	if best.is_empty() or best_in < -near_m: return {}
	best.depth = depth_at(float(best.deepest), float(best.inside), float(best.reach))
	return best

## Liquid depth `inside` m in from the shore of a cap `reach` m across its radius, m.
static func depth_at(deepest: float, inside: float, reach: float) -> float:
	if inside <= 0.0: return 0.0
	return deepest * pow(minf(inside / reach, 1.0), DEPTH_POWER)

## Every cap on a world: [mesh-frame unit centre, angular radius rad] for a world of radius `radius_m`.
static func caps(world: String, radius_m: float) -> Array:
	var out := []
	for mare: Dictionary in MARIA.get(world, []):
		for cap: Array in mare.caps:
			out.append([unit(deg_to_rad(float(cap[0])), deg_to_rad(float(cap[1]))), float(cap[2]) / radius_m])
	return out
