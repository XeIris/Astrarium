class_name GalUnits
extends RefCounted

# The galactic scene's units: kpc, Myr and 10¹⁰ M☉. Physics.G is 4π² AU³ M☉⁻¹ yr⁻²
# with the orrery year (Rocketry.YR_S); a galactic Myr is 10⁶ of those years, so both
# scenes share one G. Convert only at the boundary. docs/physics/galaxies.md.

## AU per parsec: 648000/π exactly (IAU 2015 Resolution B2).
const AU_PER_PC := 648000.0 / PI
const AU_PER_KPC := AU_PER_PC * 1000.0
const KPC_M := AU_PER_KPC * Rocketry.AU_M
const MASS_UNIT_SUN := 1e10
const MYR_YR := 1e6
## kpc³ (10¹⁰ M☉)⁻¹ Myr⁻²; 0.0449850 to six figures.
const G := Physics.G * MASS_UNIT_SUN * MYR_YR * MYR_YR / (AU_PER_KPC * AU_PER_KPC * AU_PER_KPC)
## 1 km/s in kpc/Myr (≈ 1.02271e-3).
const KMS := 1000.0 * Rocketry.YR_S * MYR_YR / KPC_M

static func kms(v_kpc_myr: float) -> float:
	return v_kpc_myr / KMS

## Mass density in M☉ pc⁻³ from 10¹⁰ M☉ kpc⁻³.
static func msun_pc3(rho: float) -> float:
	return rho * MASS_UNIT_SUN * 1e-9

## Surface density in M☉ pc⁻² from 10¹⁰ M☉ kpc⁻².
static func msun_pc2(sigma: float) -> float:
	return sigma * MASS_UNIT_SUN * 1e-6
