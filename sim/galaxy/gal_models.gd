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

## A model: its potential, tracer populations and light. `seed` fixes every draw.
static func build(key: String, seed := 1) -> Dictionary:
	match key:
		"milky_way":
			return {
				"key": key, "name": "Milky Way", "seed": seed,
				"potential": milky_way_potential(),
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
			}
	return {}
