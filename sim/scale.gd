class_name Scale
extends RefCounted

# ============================================================================
# TRUE-SCALE RENDERING
#
# Every other preset renders bodies at an invented size, because the Solar
# System spans seven orders of magnitude between "how far apart things are"
# and "how big things are". Earth's radius is 4.26e-5 AU sitting in a 1 AU
# orbit: a ratio of 1 : 23 000. Drawn honestly at a camera distance that fits
# Neptune's orbit on screen, Earth covers 0.001 of a pixel.
#
# The exaggeration is therefore not laziness, it is the only way a mesh
# renderer shows anything at all. But it is not the ONLY way to be visible,
# and that is the loophole this module uses.
#
# A real telescope has the same problem and solves it the same way: below the
# resolution limit a body stops being a disc and becomes a POINT SOURCE. Its
# apparent size stops shrinking (it is pinned at the instrument's point-spread
# function) while its brightness keeps falling as 1/r². So we render bodies at
# their true geometric size and, when that drops below a few pixels, cross-fade
# the mesh into a fixed-pixel-size glow. Geometry stays honest; visibility is
# preserved. This is what Celestia and Space Engine do.
#
# The two numerical hazards of true scale, and why they do not bite here:
#
#   Depth precision. A 24-bit depth buffer with near=n resolves roughly
#   z²/(n·2²⁴) at distance z. A body of radius R goes sub-pixel (and hence
#   becomes a marker, with no depth-sensitive geometry left) once
#   z > 2R/θ_px ≈ 2317·R. Its geometry stays well resolved while
#   z < sqrt(1.7e4·R). For Earth those are 0.099 AU and 0.84 AU — the mesh has
#   already handed over to the marker an order of magnitude before depth
#   precision could degrade below the body's own size. The crossover saves us.
#
#   float32 vertex precision. Relative epsilon ~1e-7 of the position
#   magnitude, so a body 40 AU from the origin jitters by ~4e-6 AU. That is
#   invisible until you zoom in far enough for 4e-6 AU to exceed a pixel, which
#   only happens in extreme close-ups of the outer system. Callers that care
#   can subtract a render origin; nothing here assumes one.
#   (In the Godot port the floating origin makes that subtraction structural —
#   see godot/PORT_GUIDE.md §3.)
# ============================================================================

# ----------------------------------------------------------------------------
# Physical radius (AU) for a non-degenerate body.
#
# A measured radius always wins. Failing that we need a mass–radius relation,
# and there are two distinct regimes because the supporting pressure changes:
#
#   Rocky worlds are held up by electrostatic (Coulomb) forces in a nearly
#   incompressible lattice, so adding mass mostly adds volume, damped by
#   self-compression: R/R⊕ ≈ (M/M⊕)^0.27 across 0.1–10 M⊕.
#
#   Gas giants are held up by partially degenerate electrons, and degeneracy
#   pressure stiffens faster than gravity loads it. The radius is therefore
#   almost flat — every object from 0.3 to 10 M_J sits within ~20% of one
#   Jupiter radius, and Jupiter itself is near the maximum. A constant beats
#   any power law here.
# ----------------------------------------------------------------------------
const R_EARTH_KM := 6371.0
const R_JUP_KM   := 69911.0
const M_EARTH_SUN := 3.00348e-6      # Earth mass in M☉

## `radius_km` may be null (JS undefined): `radiusKm > 0` is false for it.
static func physical_radius_au(type: String, mass_sun: float, radius_km = null) -> float:
	if radius_km != null and float(radius_km) > 0.0: return float(radius_km) * Physics.AU_PER_KM
	if type == "gas-giant": return R_JUP_KM * Physics.AU_PER_KM
	# rocky: 'planet' and 'world'
	var m_earth := maxf(mass_sun / M_EARTH_SUN, 1e-4)
	return R_EARTH_KM * pow(m_earth, 0.27) * Physics.AU_PER_KM

# ----------------------------------------------------------------------------
# Apparent angular DIAMETER of a body, in screen pixels.
#
# A perspective camera with vertical field of view f maps a viewport of H
# pixels onto 2·z·tan(f/2) world units at distance z, so one pixel spans
# (2·z·tan(f/2))/H there. Dividing the body's diameter by that gives its size
# in pixels — the quantity that decides whether a mesh is worth drawing.
# ----------------------------------------------------------------------------
static func pixels_per_world_unit(dist: float, fov_rad: float, viewport_h: float) -> float:
	return viewport_h / maxf(2.0 * dist * tan(fov_rad / 2.0), 1.0e-30)   # "1.0e-30": Godot mis-parses "1e-30" by an ULP

static func apparent_pixels(radius_scene: float, dist: float, fov_rad: float, viewport_h: float) -> float:
	return 2.0 * radius_scene * pixels_per_world_unit(dist, fov_rad, viewport_h)

# ---- MARKER (visual) — ported by the visuals agent ----
