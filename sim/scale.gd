class_name Scale
extends RefCounted

# TRUE-SCALE RENDERING. Earth's radius is 1 : 23 000 of its orbit, so at a distance
# that fits Neptune's orbit Earth is 0.001 of a pixel. Below the resolution limit a
# body becomes a point source (sim/marker.gd): true size, cross-fading into a fixed-
# pixel glow. Why the numerical hazards don't bite:
#   Depth: a body goes sub-pixel beyond z ≈ 2317·R, well before depth precision
#   degrades below its own size (Godot's reverse-Z float depth helps further).
#   float32: the floating origin (docs/godot.md) keeps positions camera-relative.

# Physical radius (AU) for a non-degenerate body. A measured radius wins; otherwise:
#   rocky  R/R⊕ ≈ (M/M⊕)^0.27 over 0.1–10 M⊕ (a near-incompressible lattice)
#   giant  roughly constant: everything from 0.3 to 10 M_J is within ~20% of R_J
const R_EARTH_KM := 6371.0
const R_JUP_KM   := 69911.0
const M_EARTH_SUN := 3.00348e-6      # Earth mass in M☉

## `radius_km` may be null, which counts as not positive.
static func physical_radius_au(type: String, mass_sun: float, radius_km = null) -> float:
	if radius_km != null and float(radius_km) > 0.0: return float(radius_km) * Physics.AU_PER_KM
	if type == "gas-giant": return R_JUP_KM * Physics.AU_PER_KM
	# rocky: 'planet' and 'world'
	var m_earth := maxf(mass_sun / M_EARTH_SUN, 1e-4)
	return R_EARTH_KM * pow(m_earth, 0.27) * Physics.AU_PER_KM

# Apparent diameter in pixels: one pixel spans (2·z·tan(f/2))/H at distance z.
static func pixels_per_world_unit(dist: float, fov_rad: float, viewport_h: float) -> float:
	return viewport_h / maxf(2.0 * dist * tan(fov_rad / 2.0), 1.0e-30)   # "1.0e-30": Godot mis-parses "1e-30" by an ULP

static func apparent_pixels(radius_scene: float, dist: float, fov_rad: float, viewport_h: float) -> float:
	return 2.0 * radius_scene * pixels_per_world_unit(dist, fov_rad, viewport_h)

# ---- MARKER (visual): sim/marker.gd
