class_name Liquid
extends RefCounted

# What a sea is made of: the numbers its waves, its light and what floats on it read. SI.
# docs/physics/ocean.md#the-liquids.

## Methane's polarisability volume, m³ (CRC Handbook, "Atomic and molecular polarizabilities"), and its
## molar mass: the index of refraction of the liquid follows from them and its density (Lorentz–Lorenz).
const CH4_ALPHA := 2.593e-30
const CH4_MOLAR := 0.016043
const AVOGADRO := 6.02214076e23

## Sea water, 35 PSU near 20 °C.
## - Absorption, 1/m at 650, 550 and 450 nm: pure water's, Pope & Fry 1997. Chlorophyll and silt are not in it.
## - Backscatter, 1/m at the same wavelengths: pure sea water's, half of Morel 1974's b, which goes as λ^-4.32.
const SEAWATER := {
	"name": "sea water", "rho": 1025.0, "sigma": 0.074, "nu": 1.05e-6, "n": 1.339,
	"absorb": Vector3(0.340, 0.0565, 0.0092), "backscatter": Vector3(0.00044, 0.00093, 0.00245),
}

## Ligeia Mare's liquid, which Cassini's radiometry finds methane-dominated (Le Gall et al. 2016): here pure
## methane at 92 K, NIST WebBook's saturated liquid (449.7 kg/m³, 0.0168 N/m, 186.7 µPa·s). Its dissolved
## nitrogen and ethane are not in it. Absorption and backscatter are estimates: methane's red bands weaker than
## water's, and Rayleigh backscatter scaled from water's by (n² − 1)².
const TITAN_SEA := {
	"name": "liquid methane", "rho": 449.7, "sigma": 0.0168, "nu": 4.15e-7, "molar": CH4_MOLAR,
	"absorb": Vector3(0.06, 0.004, 0.002), "backscatter": Vector3(0.00032, 0.00067, 0.00176),
}

const BY_WORLD := {"Earth": SEAWATER, "Titan": TITAN_SEA}

## The liquid of a world's sea: sea water unless the world is listed.
static func of(world_name: String) -> Dictionary:
	var l: Dictionary = BY_WORLD.get(world_name, SEAWATER).duplicate()
	if not l.has("n"): l.n = lorentz_lorenz(float(l.rho), float(l.molar), CH4_ALPHA)
	return l

## Index of refraction of a nonpolar liquid from its molecules' polarisability volume α (m³):
## (n² − 1)/(n² + 2) = (4π/3) N α, with N molecules per m³.
static func lorentz_lorenz(rho: float, molar: float, alpha: float) -> float:
	var x := 4.0 * PI / 3.0 * rho / molar * AVOGADRO * alpha
	return sqrt((1.0 + 2.0 * x) / (1.0 - x))

## Normal-incidence reflectance, ((n − 1)/(n + 1))².
static func f0(n: float) -> float:
	return pow((n - 1.0) / (n + 1.0), 2.0)

## The colour deep liquid sends back up, per channel: R∞ ≈ 0.33 b_b/a (Gordon et al. 1975), under a
## surface it has to leave through.
static func deep_reflectance(l: Dictionary) -> Vector3:
	var a: Vector3 = l.absorb
	var bb: Vector3 = l.backscatter
	return Vector3(0.33 * bb.x / (a.x + bb.x), 0.33 * bb.y / (a.y + bb.y), 0.33 * bb.z / (a.z + bb.z))
