class_name GalModels
extends RefCounted

# The modelled galaxies, as data: a potential, the tracer populations that sample
# it, and how its light follows its mass. Sources per value in
# docs/physics/galaxies.md; nothing here is tuned to look right.

## The scenarios of the galactic scene, in the order the list shows them.
const ORDER := ["gal_milkyway"]

const PRESETS := {
	"gal_milkyway": {
		"name": "Milky Way",
		"blurb": "Our galaxy as Bovy's MWPotential2014: a bulge, a Miyamoto–Nagai disc and an NFW dark halo, fitted to measured Milky Way kinematics. Thousands of test stars and cold-gas clouds orbit in it. Its rotation curve is measured live from them, beside the one Gaia and APOGEE measured.",
		"model": "milky_way",
		"camRadius": 60.0,
		"camTheta": 0.95,
		"rateMyrS": 5.0,
	},
}

# Bovy (2015) Table 1: normalised at R0 = 8 kpc, vc(R0) = 220 km/s, with the bulge,
# disc and halo supplying 5, 60 and 35 % of the radial force there.
const MW_R0 := 8.0
const MW_V0_KMS := 220.0

## McKee, Parravano & Hollenbach (2015): of the 47.1 M☉ pc⁻² of baryons over the
## solar circle, 27.0 are visible stars and 33.4 stars plus remnants; the rest is gas.
## The bulge has almost no gas, so its visible share is 27.0 / 33.4.
const VISIBLE_DISC := 27.0 / 47.1
const VISIBLE_BULGE := 27.0 / 33.4

static func milky_way_potential() -> GalPotential:
	return GalPotential.new() \
		.add(GalPotential.power_cutoff("bulge", 1.8, 1.9)) \
		.add(GalPotential.miyamoto_nagai("disc", 3.0, 0.28)) \
		.add(GalPotential.nfw("halo", 16.0)) \
		.normalize(MW_R0, MW_V0_KMS * GalUnits.KMS, [0.05, 0.6, 0.35])

# The bar (Dehnen 2000, as galpy has it). Pattern speed 39.0 ± 3.5 km/s/kpc from
# Portail et al. (2017); the long bar's half-length 5.0 ± 0.2 kpc and the bulge's angle
# of 27° ± 2° to the Sun–centre line, near end at positive longitude, from
# Bland-Hawthorn & Gerhard (2016, §4). Strength α = 0.01, galpy's default after Dehnen
# (2000): α = 3 A_f/v0² (Rb/R0)³.
const MW_BAR_OMEGA_KMS_KPC := 39.0
const MW_BAR_RB := 5.0
const MW_BAR_ANGLE_DEG := 27.0
const MW_BAR_ALPHA := 0.01
# The spiral (Cox & Gómez 2002): two arms with their N = 2, Rs = 7 kpc, H = 0.18 kpc and
# a density amplitude of one atomic mass per cm³ at 8 kpc. Pattern speed 28.2 ± 2.1
# km/s/kpc from Gaia DR2 open clusters (Dias et al. 2019). Pitch 12°, the mean of the
# two major arms' pitches measured from maser parallaxes, Perseus (10.3°, 8.7°) and
# Scutum–Centaurus (14.1°, 12.1°) (Reid et al. 2019, Table 2), whose Perseus crest it
# puts at R = 8.87 kpc, Galactocentric azimuth 40° from the Sun, today.
const MW_SPIRAL_OMEGA_KMS_KPC := 28.2
const MW_SPIRAL_PITCH_DEG := 12.0
const MW_SPIRAL_ANCHOR := [8.87, 40.0]
# 1.66054e-24 g cm⁻³ in M☉ pc⁻³, with M☉ = GM☉/G = 1.98841e33 g and the IAU parsec.
const AMU_CM3_MSUN_PC3 := 0.0245355
# Both grow over one bar period from tStart and run another before today (t = 0), so
# the tracers have responded when the scene opens.
const MW_T_START := -320.0
const MW_T_GROW := 160.0

# Spiral arms as measured from maser parallaxes of high-mass star-forming regions
# (Reid et al. 2019, Table 2): name, R_kink (kpc), β_kink, ψ< and ψ> (deg; pitch for
# azimuths below and above the kink), Gaussian width at the kink (kpc, growing 42 pc
# per kpc), and the azimuths measured, β_min..β_max (deg). β runs from the Sun's
# direction toward the rotation. Beyond the measured azimuths an arm is extended at
# the model's 12° pitch: an extrapolation, not a measurement. Norma and Outer are the
# inner and outer ends of one arm, so only Norma is extended; the Local arm is a spur.
# Both keep to what was measured. The 3-kpc arm, inside the bar, is left out.
const REID_2019_ARMS := [
	["Norma", 4.46, 18.0, -1.0, 19.5, 0.14, 5.0, 54.0, true],
	["Scutum–Centaurus", 4.91, 23.0, 14.1, 12.1, 0.23, 0.0, 104.0, true],
	["Sagittarius–Carina", 6.04, 24.0, 17.1, 1.0, 0.27, 2.0, 97.0, true],
	["Local", 8.26, 9.0, 11.4, 11.4, 0.31, -8.0, 34.0, false],
	["Perseus", 8.87, 40.0, 10.3, 8.7, 0.35, -23.0, 115.0, true],
	["Outer", 12.24, 18.0, 3.0, 9.4, 0.65, -16.0, 71.0, false],
]
# Stars younger than 100 Myr light the arms: 1.65 ± 0.19 M☉/yr for a Kroupa IMF
# (Licquia & Newman 2015, as Bland-Hawthorn & Gerhard 2016 quote it), in a layer 49 pc
# thick (the A0 dwarfs' sech² height, Bovy 2017), over the star-forming envelope the
# dust disc traces. The disc's own population then covers ages 0.1–10 Gyr.
const MW_SFR := 1.65
const MW_YOUNG_GYR := 0.1
const MW_YOUNG_H := 0.049
# Dust (Drimmel & Spergel 2001, Table 1, R⊙ = 8 kpc): the disc's ρ0 1098 and the arms'
# 162 MJy/sr/kpc times the V opacity 0.0180 (MJy/sr)⁻¹; scale length 2.26 kpc, height
# 134.4 pc flaring 14.8 pc/kpc past 4.40 kpc, a central hole inside R⊙/2; arms cut
# off outside 6.71 kpc on 2.07 kpc, 64.1 pc/kpc wide, 80 pc high flaring 14.6 pc/kpc²
# past 5.48 kpc (their eqs. 13–17; Gaussian across and above the arm). Extinction per channel relative to V from Rieke & Lebofsky (1985),
# which they adopt: A_R/A_V = 0.748, A_B/A_V = 1.324.
const MW_DUST := {"kappa": 0.0180, "rhoDisc": 1098.0, "rhoArm": 162.0, "hr": 2.26, "h0": 0.1344, "h1": 0.0148,
	"rf": 4.40, "hole": 4.0, "rm": 6.71, "ra": 2.07, "ca": 0.0641, "h0a": 0.080, "rfa": 5.48, "h1a": 0.0146}
const EXTINCTION_RGB := [0.748, 1.0, 1.324]
# The box/peanut bulge's axis ratios, 10 : 6.3 : 2.6 (Wegg & Gerhard 2013, via
# Bland-Hawthorn & Gerhard 2016): its light, not its mass, turns with the bar.
const MW_BULGE_AXES := [0.63, 0.26]

## The Sun's azimuth in the scene: it sits at (−R0, 0, 0). A Galactocentric azimuth β
## measured from the Sun toward the rotation (Reid et al.) is φ = π + β.
static func mw_patterns() -> Array:
	var v0 := MW_V0_KMS * GalUnits.KMS
	var af := MW_BAR_ALPHA * v0 * v0 * pow(MW_R0 / MW_BAR_RB, 3.0) / 3.0
	var bar := GalPattern.bar(MW_BAR_OMEGA_KMS_KPC * GalUnits.KMS, PI + deg_to_rad(MW_BAR_ANGLE_DEG),
		MW_BAR_RB, af, MW_T_START, MW_T_GROW)
	var pitch := deg_to_rad(MW_SPIRAL_PITCH_DEG)
	var rho0 := AMU_CM3_MSUN_PC3 * 1e9 / GalUnits.MASS_UNIT_SUN
	var amp := 4.0 * PI * GalUnits.G * 0.18 * rho0
	# γ = 0 at the anchor: φp = φ + ln(R/r0)/tan α.
	var anchor_phi: float = PI + deg_to_rad(float(MW_SPIRAL_ANCHOR[1]))
	var angle0: float = anchor_phi + log(float(MW_SPIRAL_ANCHOR[0]) / MW_R0) / tan(pitch)
	var spiral := GalPattern.spiral(MW_SPIRAL_OMEGA_KMS_KPC * GalUnits.KMS, angle0, 2, pitch, MW_R0, 7.0, 0.18,
		amp, MW_T_START, MW_T_GROW)
	return [bar, spiral]

## A model: its potential, tracer populations and light. `seed` fixes every draw;
## `patterns = false` leaves out the bar and spiral (galaxycheck's static runs).
static func build(key: String, seed := 1, patterns := true) -> Dictionary:
	match key:
		"milky_way":
			return {
				"key": key, "name": "Milky Way", "seed": seed,
				"potential": milky_way_potential(),
				"patterns": mw_patterns() if patterns else [],
				"tStart": MW_T_START if patterns else 0.0,
				"r0": MW_R0,
				# Rotation sense: the Galaxy turns clockwise seen from the north galactic
				# pole (+Y), so a star's azimuth from +X toward +Z grows.
				"sense": 1.0,
				"extent": 30.0,
				"populations": [
					# Kalberla & Dedes (2008): HI surface density roughly flat inside ~12.5 kpc,
					# then exponential with a 3.75 kpc scale length to ~30 kpc; the cold
					# neutral medium's dispersion is 6.1 km/s (their Table 1).
					{"name": "gas", "kind": "gas", "count": 2000, "rmin": 2.0, "rmax": 30.0,
						"flatTo": 12.5, "scale": 3.75, "sigmaKms": 6.1},
					# Bland-Hawthorn & Gerhard (2016): the old thin disc has σR = 35 ± 5 and
					# σz = 25 ± 5 km/s at R0, falling outward on 2 Rd with Rd = 2.6 kpc (their
					# Table 5, Binney & Piffl 2015). Positions sample the model disc's own density.
					# Inside 4 kpc the bar rules and the extrapolated σR passes 70 km/s, so the
					# axisymmetric disc starts there.
					{"name": "thin disc", "kind": "disc", "part": "disc", "count": 4000, "rmin": 4.0, "rmax": 20.0,
						"sigmaRKms": 35.0, "sigmaZKms": 25.0, "rSigma": 5.2, "rRef": 8.2},
				],
				"light": [
					{"part": "disc", "visible": VISIBLE_DISC},
					{"part": "bulge", "visible": VISIBLE_BULGE},
				],
				"arms": REID_2019_ARMS if patterns else [],
				"sfr": MW_SFR if patterns else 0.0,
				"dust": MW_DUST if patterns else {},
				"bulgeAxes": MW_BULGE_AXES if patterns else [1.0, 1.0],
			}
	return {}
