class_name SkyConditions
extends RefCounted

# What the air does at a site: airmass, extinction and how bright the sky is in V, from
# the Sun's and Moon's places. Sources per term: docs/physics/instruments.md.

## Median V-band figures per site; sources and which are estimates are in the doc.
const SITES := {
	"paranal": {"sky_v": 21.61, "k_v": 0.12, "seeing": 0.72},
	"maunakea": {"sky_v": 21.9, "k_v": 0.11, "seeing": 0.6},
	"jodrell": {"sky_v": 20.5, "k_v": 0.25, "seeing": 1.5},
	"custom": {"sky_v": 21.0, "k_v": 0.2, "seeing": 1.0},
}

## A clear day's zenith, V mag/arcsec²: the estimate twilight_v runs up to.
const DAY_V := 4.0
const EXPOSURE_POWER := 0.62
const EXPOSURE_MAX := 300.0
## The flight view's exposure ratio between night and a sunlit day.
const DAY_STAR_GAIN := 1.0 / 400.0

## Kasten & Young (1989), altitude in degrees; finite to the horizon.
static func airmass(alt_deg: float) -> float:
	var z := 90.0 - clampf(alt_deg, 0.0, 90.0)
	return 1.0 / (cos(deg_to_rad(z)) + 0.50572 * pow(96.07995 - z, -1.6364))

## The fraction of V light through `x` airmasses.
static func transmission(k_v: float, x: float) -> float:
	return pow(10.0, -0.4 * k_v * x)

## V surface brightness to nanolamberts and back (Krisciunas & Schaefer 1991, eq. 1).
static func nl_of_v(v: float) -> float:
	return 34.08 * exp(20.7233 - 0.92104 * v)

static func v_of_nl(nl: float) -> float:
	return (20.7233 - log(maxf(nl, 1e-30) / 34.08)) / 0.92104

## The Moon's V from its phase angle (degrees) and distance (AU): Krisciunas & Schaefer's
## phase curve at the mean 384,400 km, scaled by distance.
static func moon_v(alpha: float, d_au: float) -> float:
	var a := absf(alpha)
	return -12.73 + 0.026 * a + 4e-9 * a * a * a * a + 5.0 * U.log10(d_au / 0.00256955)

## Moonlight scattered to the target, nL (Krisciunas & Schaefer 1991, eqs. 15–21).
## `alpha` is the Moon's phase angle (0 = full), `rho` the Moon–target separation, all
## degrees, `alt_*` altitudes in degrees. Zero with the Moon down.
static func moon_nl(k_v: float, alpha: float, rho: float, alt_moon: float, alt_target: float) -> float:
	if alt_moon <= 0.0: return 0.0
	var a := absf(alpha)
	var istar := pow(10.0, -0.4 * (3.84 + 0.026 * a + 4e-9 * a * a * a * a))
	var cr := cos(deg_to_rad(rho))
	var f := pow(10.0, 5.36) * (1.06 + cr * cr) + pow(10.0, 6.15 - rho / 40.0)
	var xm := _x(90.0 - alt_moon)
	var xt := _x(90.0 - clampf(alt_target, 0.0, 90.0))
	return f * istar * pow(10.0, -0.4 * k_v * xm) * (1.0 - pow(10.0, -0.4 * k_v * xt))

static func _x(z_deg: float) -> float:
	var s := sin(deg_to_rad(z_deg))
	return pow(1.0 - 0.96 * s * s, -0.5)

## The Sun's sky at the zenith, V mag/arcsec²: Patat et al. (2006) for a solar zenith
## distance of 95–105°; above that a straight run to a clear day's ≈ 4; INF once dark.
static func twilight_v(sun_alt: float) -> float:
	var z := 90.0 - sun_alt
	if z >= 108.0: return INF
	if z >= 105.0: return 11.84 + 1.518 * 10.0 - 0.057 * 100.0 + (z - 105.0) * 2.0
	if z >= 95.0:
		var d := z - 95.0
		return 11.84 + 1.518 * d - 0.057 * d * d
	# From the fit's end at the Sun 5° down to +10° (day), about 0.5 mag per degree.
	return clampf(11.84 + (z - 95.0) * 0.53, DAY_V, 11.84)

## The camera's exposure for the sunlit sky relative to a clear day's, from how much the
## zenith dims. A power below 1, as an adapting eye or an exposure meter only partly follows
## the light: the sky at sunset is about 70 times dimmer than by day but still looks bright.
## The exponent is by eye. Capped near the end of civil twilight: past it, more exposure
## would only show how little sunlit air is left.
static func twilight_exposure(sun_alt: float) -> float:
	var tw := twilight_v(sun_alt)
	if not is_finite(tw): return EXPOSURE_MAX
	return minf(pow(nl_of_v(DAY_V) / nl_of_v(tw), EXPOSURE_POWER), EXPOSURE_MAX)

## The Sun's linear light on the site relative to noon's: its extinction under the sky's
## `exposure`. No channel passes noon's: the exposure is by eye and answers to the sky, and
## uncapped it would light a wall at sunset twice as brightly as at midday.
static func sunlight(extinction: Vector3, exposure: float) -> Color:
	var c := extinction * exposure
	return Color(c.x, c.y, c.z) / maxf(maxf(c.x, maxf(c.y, c.z)), 1.0)

## How far a star's drawn flux falls with the sky's brightness: a threshold under the
## square root of the background (de Vries–Rose) puts the limit near V 1–2 at the Sun's −6°,
## down to the flight view's daylight exposure. `c` is a SITES row.
static func star_gain(c: Dictionary, sun_alt: float) -> float:
	var dark := nl_of_v(float(c.sky_v))
	var tw := twilight_v(sun_alt)
	return maxf(sqrt(dark / (dark + (nl_of_v(tw) if is_finite(tw) else 0.0))), DAY_STAR_GAIN)

## V mag/arcsec² at a target: the dark sky brightened along the slant (airglow's van
## Rhijn law, mostly), then twilight and moonlight added. `c` is a SITES row.
static func sky_v(c: Dictionary, alt_target: float, sun_alt: float, moon_alpha: float, moon_rho: float, alt_moon: float) -> float:
	var x := airmass(alt_target)
	# Half the dark sky brightens with the slant (Patat 2008's f ≈ 0.5, in V).
	var dark: float = float(c.sky_v) - 2.5 * U.log10(0.5 + 0.5 * x)
	var nl := nl_of_v(dark)
	var tw := twilight_v(sun_alt)
	if is_finite(tw): nl += nl_of_v(tw)
	nl += moon_nl(float(c.k_v), moon_alpha, moon_rho, alt_moon, alt_target)
	return v_of_nl(nl)
