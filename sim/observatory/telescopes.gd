class_name Telescopes
extends RefCounted

# The instruments, with the published figures they use. `part` is the telescope's index in
# its site's parts (Facilities.DATA), which points when you slew. docs/physics/instruments.md
# gives each number's source and marks which are estimates.

## Johnson V photon zero point, photons/s/cm²/Å at V = 0 (Bessell 1998's 3.63e-9 erg/s/cm²/Å
## at 5500 Å), and the band's effective width and wavelength.
const V_PHOTONS := 1004.0
const V_WIDTH := 890.0
const V_LAMBDA := 550e-9

const INSTRUMENTS := {
	"fors2": {
		"kind": "optical", "site": "paranal", "part": 1, "name": "VLT FORS2", "telescope": "UT1 Antu",
		"d": 8.2, "eps": 0.14, "pixel": 0.25, "fov": 408.0, "read": 2.7, "dark": 3.0 / 3600.0,
		"full": 45900.0, "tau": 0.34, "band": 1232.0, "lambda": 555e-9,
		"note": "8.2 m, 0.25″ per pixel over 6.8′ (2 × 2 binned).",
		"min_alt": 20.0, "az_rate": 2.0, "el_rate": 2.0,
	},
	"deimos": {
		"kind": "optical", "site": "maunakea", "part": 1, "name": "Keck II DEIMOS", "telescope": "Keck II",
		"d": 10.0, "eps": 0.18, "pixel": 0.1185, "fov": 300.0, "read": 5.0, "dark": 0.001,
		"full": 65000.0, "tau": 0.30, "band": 890.0, "lambda": 550e-9,
		"note": "10 m, 0.119″ per pixel; a 5′ square of its 16.7 × 5′ field.",
		"min_alt": 18.0, "az_rate": 1.0, "el_rate": 1.0,
	},
	"omegacam": {
		"kind": "optical", "site": "paranal", "part": 5, "name": "VST OmegaCAM", "telescope": "VST",
		"d": 2.6, "eps": 0.36, "pixel": 0.214, "fov": 3600.0, "read": 5.0, "dark": 0.001,
		"full": 163000.0, "tau": 0.40, "band": 890.0, "lambda": 550e-9,
		"note": "2.6 m survey telescope, 0.214″ per pixel over 1°.",
		"min_alt": 20.0, "az_rate": 1.0, "el_rate": 1.0,
	},
	"lovell_l": {
		"kind": "radio", "site": "jodrell", "part": 0, "name": "Lovell L-band", "telescope": "Lovell",
		"d": 76.2, "freq": 1.5e9, "bandwidth": 512e6, "sefd": 36.0, "pixel": 132.0,
		"note": "76.2 m at 1.25–1.75 GHz: an 11′ beam mapping radio sources, not starlight.",
		"min_alt": 8.0, "az_rate": 15.0 / 60.0, "el_rate": 10.0 / 60.0,
	},
}
const ORDER := ["lovell_l", "deimos", "fors2", "omegacam"]
## Optional neutral density, magnitudes. None of these instruments carries one; the Moon and
## bright planets otherwise saturate them in under the shortest exposure offered.
const ND := [0.0, 5.0, 10.0]

## The instruments at a site, in display order.
static func at_site(site: String) -> Array:
	var out := []
	for k in ORDER:
		if INSTRUMENTS[k].site == site: out.append(k)
	return out

## Electrons per second (before the air) from a star of magnitude `v`.
static func electrons_per_s(row: Dictionary, v: float) -> float:
	var r: float = float(row.d) * 50.0   # cm
	var area := PI * r * r * (1.0 - float(row.eps) * float(row.eps))
	return V_PHOTONS * pow(10.0, -0.4 * v) * float(row.band) * area * float(row.tau)

## The magnitude that gives one electron per second before the air.
static func zero_point(row: Dictionary) -> float:
	return 2.5 * U.log10(electrons_per_s(row, 0.0))

## Named bright stars for the target box, J2000 RA and Dec in degrees; the check holds
## each to a catalogue star of the right brightness.
const STARS := {
	"Sirius": [101.2872, -16.7161], "Canopus": [95.9880, -52.6957], "Arcturus": [213.9153, 19.1824],
	"Rigil Kentaurus": [219.9021, -60.8340], "Vega": [279.2347, 38.7837], "Capella": [79.1723, 45.9980],
	"Rigel": [78.6345, -8.2016], "Procyon": [114.8255, 5.2250], "Betelgeuse": [88.7929, 7.4071],
	"Achernar": [24.4285, -57.2368], "Hadar": [210.9559, -60.3730], "Altair": [297.6958, 8.8683],
	"Acrux": [186.6496, -63.0991], "Aldebaran": [68.9802, 16.5093], "Antares": [247.3519, -26.4320],
	"Spica": [201.2983, -11.1613], "Pollux": [116.3289, 28.0262], "Fomalhaut": [344.4128, -29.6222],
	"Deneb": [310.3580, 45.2803], "Regulus": [152.0930, 11.9672], "Polaris": [37.9546, 89.2641],
}

## Radio sources, J2000 degrees: their spectra are Baars et al. (1977), log S(Jy) = a + b lg ν +
## c lg²ν, ν in MHz, with Cas A's secular fade (0.97% a year from 1965 at 1 GHz).
const RADIO := {
	"Cas A": {"ra": 350.8664, "dec": 58.8117, "a": 5.625, "b": -0.634, "c": -0.023, "fade": 0.0097, "from": 1965.0},
	"Cyg A": {"ra": 299.8682, "dec": 40.7339, "a": 4.695, "b": 0.085, "c": -0.178},
	"Tau A": {"ra": 83.6331, "dec": 22.0145, "a": 3.915, "b": -0.299, "c": 0.0},
	"Vir A": {"ra": 187.7059, "dec": 12.3911, "a": 5.023, "b": -0.856, "c": 0.0},
}

## A source's flux density (Jy) at `freq` (Hz) in Julian year `year`.
static func radio_jy(src: Dictionary, freq: float, year: float) -> float:
	var l := U.log10(freq / 1e6)
	var s := pow(10.0, float(src.a) + float(src.b) * l + float(src.c) * l * l)
	if src.has("fade"): s *= pow(1.0 - float(src.fade), year - float(src.from))
	return s

## Thermal bodies at L band: brightness temperature (K), S = 2kTΩ/λ². Estimates, listed in the doc.
const THERMAL_K := {"Moon": 225.0, "Mercury": 300.0, "Venus": 600.0, "Mars": 190.0, "Saturn": 150.0, "Uranus": 130.0, "Neptune": 130.0}
## Jupiter's synchrotron belts outshine its disc: about 4.8 Jy at 4.04 AU, scaled as 1/d².
const JUPITER_JY_4AU := 4.8
## The quiet Sun at 1.5 GHz: about 40 solar flux units.
const SUN_JY := 4.0e5
const K_B := 1.380649e-23
const C := 299792458.0

## A solar-system body's flux density (Jy): angular radius `radius` (rad), distance `d_au`.
static func body_jy(body_name: String, radius: float, d_au: float, freq: float) -> float:
	if body_name == "Sun": return SUN_JY
	if body_name == "Jupiter": return JUPITER_JY_4AU * pow(4.04 / d_au, 2.0)
	var lam := C / freq
	return 2.0 * K_B * float(THERMAL_K.get(body_name, 150.0)) * PI * radius * radius / (lam * lam) * 1e26

## The beam's FWHM (rad): 70 λ/D degrees, a tapered dish's usual width.
static func beam_fwhm(row: Dictionary) -> float:
	return deg_to_rad(70.0 * C / float(row.freq) / float(row.d))

## Confusion noise (Jy/beam), Condon et al. 2002: 0.2 mJy ν^−0.7 θ² (ν GHz, θ arcmin).
static func confusion_jy(row: Dictionary) -> float:
	var theta := rad_to_deg(beam_fwhm(row)) * 60.0
	return 0.2e-3 * pow(float(row.freq) / 1e9, -0.7) * theta * theta

## Radiometer noise (Jy/beam) in `tau` seconds, two polarisations, with the source's own
## power `s` (Jy) added to the system's.
static func radiometer_jy(row: Dictionary, tau: float, s := 0.0) -> float:
	return (float(row.sefd) + s) / sqrt(2.0 * float(row.bandwidth) * tau)
