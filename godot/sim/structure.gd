class_name Structure
extends RefCounted

# ============================================================================
# INTERIOR STRUCTURE & STABILITY
# ----------------------------------------------------------------------------
# Every other module in this sim answers "where is it and what does it look
# like". This one answers "what IS it" — given a mass, a spin and a point in
# its life, what holds the thing up, how big does that make it, what does it
# look like on the inside, and at what point does the support fail.
#
# That last question is the reason the module exists. The sim's editor lets you
# drag a mass slider, and the interesting behaviour is entirely in the places
# where the answer stops being "a bigger one of the same thing":
#
#   · a rocky planet stops growing at ~300 M⊕ and then SHRINKS, because
#     electron degeneracy stiffens faster than gravity loads it
#   · at 13 M_J it lights deuterium and is a brown dwarf
#   · at 0.075 M☉ it lights hydrogen and is a star
#   · a star spun past its Keplerian limit sheds its equator
#   · a neutron star past the TOV mass has nothing left to hold it up
#   · a star past ~150 M☉ is pushed apart by its own radiation
#
# None of those are thresholds invented for the sim. They are all consequences
# of one competition — pressure against gravity — and the point of collecting
# them here is that the editor can be a slider over real physics rather than a
# menu of hand-authored outcomes.
#
# UNITS. Public functions take and return the sim's astronomical units (M☉, AU,
# years). Internally, anything involving a real equation of state works in SI,
# because that is the only way the published fits mean anything.
#
# PORT NOTE. A structure is a Dictionary with the web build's keys verbatim
# (`radiusAU`, `flattening`, `verdict.detail`, `layers` …), because the
# cross-section, the Foundry, the mass curve and the HR diagram all read it as
# data. `Infinity` is INF; a key the JS left `undefined` is simply absent.
# ============================================================================

# --- SI constants, for the interior physics only.
const G_SI    := 6.67430e-11
const M_SUN   := 1.98892e30      # kg
const R_SUN   := 6.957e8         # m
const L_SUN   := 3.828e26        # W
const M_EARTH := 5.97217e24
const R_EARTH := 6.371e6
const M_JUP   := 1.89813e27
const R_JUP   := 6.9911e7
const SIGMA   := 5.670374e-8     # Stefan–Boltzmann
const K_B     := 1.380649e-23
const M_H     := 1.6735575e-27
const SEC_PER_YR := 3.155815e7

const M_EARTH_SUN := M_EARTH / M_SUN    # 3.0035e-6
const M_JUP_SUN   := M_JUP / M_SUN      # 9.5459e-4

# Mass thresholds that decide what an object IS. All are physical ignition or
# support limits, not categories.
const LIMITS := {
	# Deuterium ignites at T_c ≈ 5e5 K, reached at ~13 M_J. This is the IAU's
	# working planet/brown-dwarf line for the same reason.
	"deuteriumBurn": 13.0 * M_JUP_SUN,     # 0.0124 M☉
	# Hydrogen ignites at ~0.075 M☉ for solar composition (lower, ~0.09, for
	# metal-poor gas — hence the Z dependence in hydrogen_burn_limit()).
	"hydrogenBurn": 0.075,
	# Chandrasekhar mass for a μ_e = 2 (C/O) white dwarf.
	"chandrasekhar": 1.44,
	# Tolman–Oppenheimer–Volkoff maximum for a NON-rotating neutron star. The
	# EOS is not known, so this is a range in the literature (2.0–2.3); GW170817's
	# remnant and the heaviest measured pulsars bracket it near 2.2.
	"tov": 2.20,
	# Uniform (rigid) rotation supports a "supramassive" star up to ~20% above
	# the TOV mass. Differential rotation buys more, but only transiently.
	"tovSpinBoost": 0.20,
	# The Humphreys–Davidson limit: the empirical upper envelope in the HR
	# diagram, above which no stable supergiant is observed. Stars exist above
	# it, but only as luminous blue variables shedding mass in eruptions.
	"humphreysDavidson": 120.0,
	# And the observed upper limit on stellar mass itself. Both the Arches
	# cluster and R136 cut off near here.
	"eddingtonMass": 150.0,
	# Pair-instability window: a He core of 65–135 M☉ makes electron–positron
	# pairs, the adiabatic index falls below 4/3, and the star is disrupted with
	# NO remnant. In terms of initial mass that is roughly 140–260 M☉.
	"pairLo": 140.0, "pairHi": 260.0,
	# Above the pair window, photodisintegration wins and the whole star goes
	# directly to a black hole.
	# Core-collapse thresholds (initial mass, solar metallicity).
	"neutronStarMin": 8.0, "blackHoleMin": 20.0,
}

# Metal-poor gas is more transparent and needs a slightly higher mass to reach
# the ignition temperature. (Z = mass fraction in elements heavier than He.)
static func hydrogen_burn_limit(Z: float = 0.014) -> float:
	return 0.075 + 0.015 * maxf(0.0, 1.0 - Z / 0.014)

# ============================================================================
# SOLID / GASEOUS PLANETS — the mass–radius curve, and where it turns over
# ----------------------------------------------------------------------------
# Seager et al. (2007), "Mass–Radius Relationships for Solid Exoplanets"
# (ApJ 669, 1279; arXiv:0707.2895), show that every solid composition collapses
# onto ONE curve in scaled variables, because all of their equations of state
# are well fitted by a modified polytrope ρ = ρ₀ + cPⁿ with n ≈ 0.51–0.55:
#
#     log₁₀ Rs = k₁ + ⅓ log₁₀ Ms − k₂ Ms^k₃
#
# with Ms = M/m₁, Rs = R/r₁ and the material entering only through the scaling
# pair (m₁, r₁) from their Table 4.
#
# The ⅓ term is the incompressible limit — a Coulomb lattice, where adding mass
# just adds volume. The −k₂Ms^k₃ term is self-compression, and it is what makes
# the curve bend over: differentiate, and dlog R/dlog M reaches zero at
#
#     k₂k₃ Ms^k₃ = 1/(3 ln10)   ⇒   Ms ≈ 47   ⇒   M ≈ 300 M⊕ ≈ 0.95 M_J
#
# That is the sim's headline result for the editor: a rocky planet has a
# LARGEST POSSIBLE SIZE of about 3 R⊕, reached near one Jupiter mass, and past
# it more mass makes it smaller. Seager's fit is quoted as good to Ms ≲ 40, so
# the turnover sits just outside its stated range and its position is good to
# perhaps 20% — but the turnover itself is not a fitting artefact, it is
# electron degeneracy, and every full EOS calculation (Zapolsky & Salpeter
# 1969 onward) finds it.
#
# Validation: the Earth-like differentiated row (32.5% Fe core by mass) gives
# m₁ = 6.41 M⊕, r₁ = 3.19 R⊕. At M = 1 M⊕ that returns 0.970 R⊕ — 3% low,
# which is about the accuracy the paper claims.
# ============================================================================
const SEAGER_K := { "k1": -0.209490, "k2": 0.0804, "k3": 0.394 }

# Scaling pairs from Seager Table 4, in (M⊕, R⊕).
const ROCK_COMPOSITIONS := {
	"iron":     { "label": "Iron",            "m1": 4.34, "r1": 2.23, "rho0": 8300.0, "note": "Pure Fe(ε). The smallest a planet of a given mass can be." },
	"mercury":  { "label": "Iron-rich",       "m1": 6.41, "r1": 2.84, "rho0": 6600.0, "note": "~70% iron core, like Mercury." },
	"earth":    { "label": "Earth-like",      "m1": 6.41, "r1": 3.19, "rho0": 5510.0, "note": "32.5% iron core, 67.5% silicate mantle." },
	"silicate": { "label": "Silicate",        "m1": 7.38, "r1": 3.58, "rho0": 4100.0, "note": "Pure MgSiO₃ perovskite — a coreless rock." },
	"ocean":    { "label": "Ocean world",     "m1": 6.88, "r1": 4.02, "rho0": 2700.0, "note": "45% water ice over rock and a small iron core." },
	"ice":      { "label": "Ice",             "m1": 8.16, "r1": 4.73, "rho0": 1460.0, "note": "Pure H₂O ice — the largest a solid planet can be." },
}

static func _comp(comp) -> Dictionary:
	if comp != null and ROCK_COMPOSITIONS.has(comp):
		return ROCK_COMPOSITIONS[comp]
	return ROCK_COMPOSITIONS.earth

# Scaled radius from Seager's equation (23). Ms, Rs are dimensionless.
static func _seager_rs(Ms: float) -> float:
	var k1: float = SEAGER_K.k1; var k2: float = SEAGER_K.k2; var k3: float = SEAGER_K.k3
	return pow(10.0, k1 + U.log10(Ms) / 3.0 - k2 * pow(Ms, k3))

# Radius (R⊕) of a solid planet of mass M (M⊕) and the given composition.
static func rocky_radius_earth(m_earth: float, comp = "earth") -> float:
	var c := _comp(comp)
	var Ms := maxf(m_earth, 1e-6) / float(c.m1)
	return float(c.r1) * _seager_rs(Ms)

# The turnover, solved rather than tabulated: k₂k₃·Ms^k₃ = 1/(3 ln10).
## Returns { massEarth, radiusEarth }.
static func rocky_max_radius(comp = "earth") -> Dictionary:
	var c := _comp(comp)
	var k2: float = SEAGER_K.k2; var k3: float = SEAGER_K.k3
	var Ms := pow(1.0 / (3.0 * U.LN10 * k2 * k3), 1.0 / k3)
	return { "massEarth": Ms * float(c.m1), "radiusEarth": float(c.r1) * _seager_rs(Ms) }

# ----------------------------------------------------------------------------
# H/He-dominated objects: giant planets and brown dwarfs.
#
# Once hydrogen and helium dominate, the same competition plays out with a much
# softer floor, and the result is the flattest curve in astrophysics: every
# object from Saturn to the hydrogen-burning limit — a factor of 80 in mass —
# sits within about 30% of one Jupiter radius. The interpolation used here has
# the two limiting slopes built in,
#
#     R ∝ M^⅓ / (1 + (M/M₀)^⅔)
#
# which is R ∝ M^⅓ while the gas is classical and R ∝ M^−⅓ once it is fully
# degenerate (the cold-sphere / Chandrasekhar result), with its maximum exactly
# at M₀. Zapolsky & Salpeter (1969) put that maximum near 3–4 M_J at ~1.1 R_J
# for solar composition, which is what M₀ and the prefactor are set to.
#
# Deuterium burning (13–65 M_J) briefly halts the contraction and is worth a
# few percent in radius; it is not modelled, because it does not survive the
# scatter of the real population.
# ----------------------------------------------------------------------------
const GIANT_M0 := 3.5            # M_J — where degeneracy takes over
const GIANT_RMAX := 1.10         # R_J at that mass
static func giant_radius_jup(m_jup: float) -> float:
	var m := maxf(m_jup, 1e-3)
	var u := pow(m / GIANT_M0, 2.0 / 3.0)
	# normalised so R(M₀) = GIANT_RMAX exactly
	return GIANT_RMAX * 2.0 * pow(m / GIANT_M0, 1.0 / 3.0) / (1.0 + u)

# ----------------------------------------------------------------------------
# White dwarfs. Degenerate electrons, so the radius FALLS with mass and reaches
# zero at the Chandrasekhar mass. The non-relativistic result R ∝ M^−⅓ is only
# right well below it; the standard correction that carries the curve to
# M_Ch is Nauenberg (1972):
#
#     R = 0.0126 R☉ · (μ_e/2)^−⁵⸍³ · (M/M_Ch)^−⅓ · [1 − (M/M_Ch)^{4/3}]^½
#
# which gives 0.0084 R☉ at 1.0 M☉ — Sirius B, measured at 0.0084 R☉.
# ----------------------------------------------------------------------------
static func white_dwarf_radius_sun(mass_sun: float) -> float:
	var x := minf(mass_sun / float(LIMITS.chandrasekhar), 0.999)
	return 0.0126 * pow(x, -1.0 / 3.0) * sqrt(maxf(1.0 - pow(x, 4.0 / 3.0), 1e-6))

# ----------------------------------------------------------------------------
# Neutron stars. The EOS above nuclear density is genuinely unknown, so this is
# a smooth stand-in for the family of modern "stiff enough to reach 2.1 M☉"
# candidates: nearly flat at 11.5–12.5 km through the observed mass range, then
# steepening sharply as the TOV mass is approached and the star runs out of
# pressure. NICER's measurements of PSR J0030 and J0740 both land near 12.4 km.
# ----------------------------------------------------------------------------
static func neutron_radius_km(mass_sun: float) -> float:
	var m := maxf(mass_sun, 0.1)
	var x := minf(m / float(LIMITS.tov), 0.999)
	# 12.6 km plateau, collapsing as x → 1
	return 12.6 * pow(1.0 - 0.62 * pow(x, 6.0), 0.22)

# The maximum mass a neutron star can carry, given how fast it spins. Rigid
# rotation adds centrifugal support worth ~20% at the mass-shedding limit.
static func tov_limit(spin_frac: float = 0.0) -> float:
	return float(LIMITS.tov) * (1.0 + float(LIMITS.tovSpinBoost) * pow(minf(maxf(spin_frac, 0.0), 1.0), 2.0))

# ============================================================================
# STELLAR EVOLUTION — "how much of its life it has burned"
# ----------------------------------------------------------------------------
# A star is not one object. It is a sequence, and which part of the sequence
# you are looking at changes its radius by three orders of magnitude and its
# colour from blue to red and back. The editor exposes that as one knob, and
# this is what the knob drives.
#
# The physics behind the main-sequence part is homology. Fusion converts H to
# He, which RAISES the mean molecular weight of the core,
#
#     μ = 4 / (3 + 5X − Z)      (fully ionised)
#
# from 0.62 at X = 0.71 to 1.34 at X = 0. The core must then be hotter and
# denser to hold the same weight up, so the star brightens and swells while it
# sits on the main sequence — the Sun is ~30% brighter now than at its ZAMS and
# will be ~2.2× as bright when its core hydrogen runs out. The fits below
# reproduce that (L grows ×2.2, R grows ×1.6 across the main sequence), which
# is the right behaviour for solar-type stars and roughly right for the rest.
#
# Everything after the main sequence — shell burning, the giant branches, the
# remnant — is not homologous and cannot be got from a scaling law. Those
# phases are entered here as calibrated stops along the track, with radii and
# temperatures taken from where real stars of that mass actually sit.
# ============================================================================

# Mean molecular weight for a fully ionised mix.
static func mean_molecular_weight(X: float, Z: float) -> float:
	return 4.0 / (3.0 + 5.0 * X - Z)

# Main-sequence lifetime (yr): t ≈ 10 Gyr · (M/M☉) / (L/L☉), because the fuel
# available is ∝ M and the rate it burns at is ∝ L.
static func main_sequence_lifetime(mass_sun: float, L: float) -> float:
	return 1.0e10 * mass_sun / maxf(L, 1e-6)

# The named stops. `f` is the position on the track used by the UI (0 = ZAMS,
# 1 = core hydrogen exhausted, >1 = post-main-sequence). `X` is the CORE
# hydrogen fraction.
#
# `rMul`/`lMul` multiply the BASELINE radius and luminosity — and the baseline
# is the middle of the main sequence, not the zero-age start of it, because
# that is what base_radius_sun / base_luminosity are normalised to (1 M☉ → 1 R☉,
# 1 L☉, which is today's 4.6 Gyr-old Sun). The main-sequence entries are
# therefore calibrated directly against the solar track: the ZAMS Sun really
# was 0.70 L☉ and 0.90 R☉, and it really will reach about 1.85 L☉ and 1.35 R☉
# before its core hydrogen runs out. Setting f = 0.5 returns the Sun exactly.
const PHASES := [
	{ "id": "protostar", "label": "Protostar",      "f": -0.15, "X": 0.71, "rMul": 3.5,  "lMul": 1.2,  "burn": "gravitational contraction",
		"note": "Not yet fusing. Held up by the heat of its own collapse, sliding down the Hayashi track." },
	{ "id": "zams",      "label": "ZAMS",           "f": 0.00,  "X": 0.71, "rMul": 0.90, "lMul": 0.70,  "burn": "H → He (core)",
		"note": "Zero-age main sequence. Core hydrogen just lit; the star is as small and faint as it will ever be while burning." },
	{ "id": "ms-early",  "label": "Early MS",       "f": 0.25,  "X": 0.55, "rMul": 0.95, "lMul": 0.83, "burn": "H → He (core)",
		"note": "A quarter through. Helium ash is accumulating in the core and the star is slowly brightening." },
	{ "id": "ms-mid",    "label": "Mid MS",         "f": 0.50,  "X": 0.38, "rMul": 1.00, "lMul": 1.00, "burn": "H → He (core)",
		"note": "Half its hydrogen gone. Where the Sun is now." },
	{ "id": "ms-late",   "label": "Late MS",        "f": 0.85,  "X": 0.12, "rMul": 1.15, "lMul": 1.40, "burn": "H → He (core)",
		"note": "Running out. The core is nearly pure helium and the envelope is visibly swelling." },
	{ "id": "tams",      "label": "TAMS",           "f": 1.00,  "X": 0.00, "rMul": 1.35, "lMul": 1.85, "burn": "H → He (shell)",
		"note": "Core hydrogen exhausted. Burning moves to a shell around an inert helium core; the main sequence is over." },
	{ "id": "subgiant",  "label": "Subgiant",       "f": 1.10,  "X": 0.00, "rMul": 2.8,  "lMul": 2.5,  "burn": "H → He (shell)",
		"note": "The inert core contracts, the shell burns hotter, and the envelope expands to absorb it. Cooling at nearly constant luminosity." },
	{ "id": "rgb",       "label": "Red giant",      "f": 1.35,  "X": 0.00, "rMul": 25.0, "lMul": 320.0, "burn": "H → He (shell), degenerate He core",
		"note": "A degenerate helium core the size of Earth inside a convective envelope the size of Mercury's orbit." },
	{ "id": "heburn",    "label": "Core He burning","f": 1.55,  "X": 0.00, "rMul": 10.0, "lMul": 65.0, "burn": "3 ⁴He → ¹²C (core)",
		"note": "Helium ignites — in low-mass stars all at once, in a flash — and the star settles back down to burn it." },
	{ "id": "agb",       "label": "AGB / supergiant","f": 1.80, "X": 0.00, "rMul": 130.0, "lMul": 3500.0, "burn": "H and He shells; C/O core",
		"note": "Two burning shells around an inert carbon–oxygen core, an enormous pulsating envelope, and a heavy wind stripping it away." },
	{ "id": "preSN",     "label": "Pre-collapse",   "f": 1.95,  "X": 0.00, "rMul": 220.0, "lMul": 6000.0, "burn": "Si → Fe (core), onion shells",
		"note": "Massive stars only. Silicon burning takes days and builds an iron core that cannot burn. Collapse is imminent." },
	{ "id": "remnant",   "label": "Remnant",        "f": 2.00,  "X": 0.00, "rMul": 0.0,  "lMul": 0.0,  "burn": "none",
		"note": "What is left when the pressure fails." },
]

## PHASES.find(p => p.id === id) || PHASES[1]. Returns the (read-only) table
## entry itself, as the JS did.
static func phase_by_id(id) -> Dictionary:
	for p in PHASES:
		if p.id == id:
			return p
	return PHASES[1]

# Interpolate the track between named stops so the UI slider is continuous.
static func phase_at(f: float) -> Dictionary:
	var lo: Dictionary = PHASES[0]
	var hi: Dictionary = PHASES[PHASES.size() - 1]
	if f <= float(lo.f): return lo.duplicate()
	if f >= float(hi.f): return hi.duplicate()
	for i in PHASES.size() - 1:
		var a: Dictionary = PHASES[i]
		var b: Dictionary = PHASES[i + 1]
		if f >= float(a.f) and f <= float(b.f):
			var t := (f - float(a.f)) / (float(b.f) - float(a.f))
			# Radius and luminosity span orders of magnitude across the giant
			# branches, so interpolate them in the log — a linear blend from 1.6 to
			# 25 R☉ would spend most of the slider in a size no star occupies.
			return {
				"id": a.id if t < 0.5 else b.id,
				"label": a.label if t < 0.5 else b.label,
				"note": a.note if t < 0.5 else b.note,
				"burn": a.burn if t < 0.5 else b.burn,
				"f": f,
				"X": float(a.X) + (float(b.X) - float(a.X)) * t,
				"rMul": float(a.rMul) if float(b.rMul) == 0.0 else _lerp_log(a.rMul, b.rMul, t),
				"lMul": float(a.lMul) if float(b.lMul) == 0.0 else _lerp_log(a.lMul, b.lMul, t),
			}
	return (PHASES[1] as Dictionary).duplicate()

static func _lerp_log(u: float, v: float, t: float) -> float:
	return exp(log(maxf(u, 1e-6)) * (1.0 - t) + log(maxf(v, 1e-6)) * t)

# ----------------------------------------------------------------------------
# ZAMS scaling relations. These are the same piecewise mass–luminosity and
# mass–radius laws sim/stellar.gd uses for the main sequence, restated here so
# the structure model is self-contained and can be given a metallicity.
# ----------------------------------------------------------------------------
# Above 20 M☉ no single power law works: the slope of the mass–luminosity
# relation falls from 3.5 toward ~1.4 as massive stars approach the Eddington
# ceiling. Rather than extrapolate a power law past where it is calibrated,
# interpolate in log–log through anchors read off the Geneva rotating grids
# (Ekström et al. 2012; Yusof et al. 2013 for the very massive end).
const MASSIVE_L := [
	[20.0, 5.01e4], [30.0, 1.41e5], [40.0, 2.82e5], [60.0, 5.62e5],
	[85.0, 1.00e6], [120.0, 1.58e6], [150.0, 2.00e6], [200.0, 3.02e6], [300.0, 5.01e6],
]

static func base_luminosity(mass_sun: float, Z: float = 0.014) -> float:
	var m := maxf(mass_sun, 0.02)
	var L: float
	if m < 0.43: L = 0.23 * pow(m, 2.3)
	elif m < 2.0: L = pow(m, 4.0)
	elif m < 20.0: L = 1.4 * pow(m, 3.5)
	else:
		var A := MASSIVE_L
		if m >= A[A.size() - 1][0]:
			var m0: float = A[A.size() - 1][0]; var L0: float = A[A.size() - 1][1]
			L = L0 * pow(m / m0, 1.4)
		else:
			var i := 0
			while A[i + 1][0] < m: i += 1
			var m0: float = A[i][0]; var L0: float = A[i][1]
			var m1: float = A[i + 1][0]; var L1: float = A[i + 1][1]
			var t := (log(m) - log(m0)) / (log(m1) - log(m0))
			L = exp(log(L0) * (1.0 - t) + log(L1) * t)
	# Metal-poor stars are more transparent, so they are hotter and brighter at
	# fixed mass — a weak but real dependence.
	return L * pow(0.014 / maxf(Z, 1e-4), 0.12)

static func base_radius_sun(mass_sun: float) -> float:
	var m := maxf(mass_sun, 0.05)
	return pow(m, 0.8) if m < 1.0 else pow(m, 0.57)

# Kept under the old names so nothing outside this module has to know that the
# baseline is mid-main-sequence rather than zero-age (see PHASES).
static func zams_luminosity(mass_sun: float, Z: float = 0.014) -> float:
	return base_luminosity(mass_sun, Z)
static func zams_radius_sun(mass_sun: float) -> float:
	return base_radius_sun(mass_sun)

# Eddington luminosity in L☉ for electron-scattering opacity (κ = 0.34 m²/kg,
# solar composition). L/L_Edd is the single number that decides whether a
# massive star's atmosphere is bound to it.
static func eddington_luminosity(mass_sun: float) -> float:
	return 3.2e4 * mass_sun

# ============================================================================
# ROTATION — shape, break-up, and gravity darkening
# ----------------------------------------------------------------------------
# Two different problems, because two different mass distributions.
#
# PLANETS are not very centrally condensed, and their flattening is small, so
# the first-order hydrostatic theory is both valid and accurate. The
# Darwin–Radau relation ties the flattening f to the rotation parameter
# q = Ω²R³/GM through the moment-of-inertia factor λ = C/MR²:
#
#     f = 5q / (2[1 + ((5/2)(1 − (3/2)λ))²])
#
# Fed Earth's numbers it returns 1/300 against a measured 1/298.25, and
# Jupiter's it returns 0.0656 against a measured 0.0649. That is not a fit —
# λ is an independently measured quantity for both.
#
# STARS are extremely centrally condensed: the Sun carries half its mass inside
# 0.26 R☉. The right limit is therefore the opposite one — the ROCHE model,
# where the whole mass is treated as a point and the surface is an equipotential
# of Φ = −GM/r − ½Ω²r²sin²θ. Writing ω = Ω/Ω_crit, that equipotential is the
# cubic
#
#     1/x + (4/27)ω²x²sin²θ = 1,        x = R(θ)/R_pole
#
# whose relevant root has the closed form used below. It carries one famous and
# completely non-obvious consequence: at break-up, exactly,
#
#     R_equator / R_pole = 3/2
#
# no matter what the star is. Nothing can be flatter than that and stay in one
# piece — which is why Achernar, measured at 1.35, is described as being close
# to break-up, and why the sim can put a hard, principled stop on the spin
# slider instead of an arbitrary one.
# ============================================================================

# Moment-of-inertia factor C/MR² by kind of body. Measured where measured.
const INERTIA_FACTOR := {
	"rocky": 0.3307,      # Earth
	"iron": 0.26,         # Mercury-like, big core
	"giant": 0.254,       # Jupiter
	"star": 0.073,        # solar model — a star is nearly all centre
	"neutron": 0.36,      # NS are stiff and nearly uniform; ~0.35–0.4 for stiff EOS
	"wd": 0.16,
}

# The largest flattening each kind can actually reach before it sheds mass.
# Darwin–Radau is a FIRST-ORDER theory: it is excellent while f is small (it
# returns Earth's and Jupiter's measured values to 1%) and meaningless as f
# approaches the mass-shedding limit, where it runs off to any value at all.
# So it is saturated onto the shape the body genuinely terminates at:
#
#   neutron stars — numerical models with realistic equations of state stop at
#                   R_eq/R_pol ≈ 1.5 at the Kepler frequency, the same ratio
#                   the Roche model gives, because a neutron star is also
#                   strongly centrally condensed
#   planets       — nothing in this sim gets close, but the uniform-density
#                   (Maclaurin) sequence turns over near f ≈ 0.42
#
# The saturation used is f_max·tanh(f/f_max), which equals f to first order —
# so nothing that was accurate is disturbed — and can never exceed f_max.
const MAX_FLATTENING := { "neutron": 0.333, "rocky": 0.42, "iron": 0.42, "giant": 0.42, "wd": 0.333 }

# The angular velocity at which the equator is in orbit and material leaves —
# the mass-shedding, or Keplerian, limit.
#
# Where that is depends on how the mass is arranged, and the two cases differ
# by a factor of nearly two, so it is not a detail. For a body that barely
# deforms, break-up is simply Ω = √(GM/R³) at its own radius. For a centrally
# condensed one the Roche geometry gets there first: the equator has already
# swelled to 1.5 R_pole by then, so the orbit it has to match is a wider one,
#
#     Ω_crit = √(GM / (1.5 R_pole)³) = √(8GM / 27 R_pole³)
#
# which is 0.544 of the naive value. Passing a polar radius and getting the
# naive answer back would put every star's break-up in the wrong place.
static func breakup_omega(mass_sun: float, radius_au: float, kind: String = "star") -> float:
	var M := mass_sun * M_SUN
	var R := radius_au / Physics.AU_PER_KM * 1000.0
	var K := (8.0 / 27.0) if (kind == "star" or kind == "wd") else 1.0
	return sqrt(K * G_SI * M / (R * R * R))

# The Roche-model surface: R(θ)/R_pole for ω = Ω/Ω_crit and colatitude θ.
# `u` = ω·sinθ. Below 1e-3 the closed form is 0/0, so use its series there.
static func roche_shape(u: float) -> float:
	var uu := minf(maxf(u, 0.0), 1.0)
	if uu < 1e-3: return 1.0 + (4.0 / 27.0) * uu * uu
	return (3.0 / uu) * cos((PI + acos(uu)) / 3.0)

# The inverse: given a MEASURED R_eq/R_pole, what fraction of break-up is the
# star spinning at? Interferometry measures the shape far more precisely than
# it measures the equatorial velocity (which needs the inclination), so for a
# real star the shape is the better input. roche_shape is monotonic on [0,1],
# so a bisection is exact and cheap.
static func inverse_roche_shape(ratio: float) -> float:
	var r := minf(maxf(ratio, 1.0), 1.5)
	var lo := 0.0
	var hi := 1.0
	for i in 40:
		var mid := (lo + hi) / 2.0
		if roche_shape(mid) < r: lo = mid
		else: hi = mid
	return (lo + hi) / 2.0

# Flattening of a rotating body. `kind` selects which theory applies.
#   omega    rad/s
#   radius_au non-rotating (or polar) radius
# Returns { f, Re, Rp, omega, omegaCrit, spinFrac, periodSec }.
static func rotational_shape(mass_sun: float, radius_au: float, omega: float, kind: String = "star") -> Dictionary:
	var omega_crit := breakup_omega(mass_sun, radius_au, kind)
	var spin_frac := minf(omega / omega_crit, 1.0) if omega_crit > 0.0 else 0.0
	var Re: float
	var Rp: float
	var f: float
	if kind == "star" or kind == "wd":
		# Roche: the polar radius barely moves (it is nearly all interior), so hold
		# it and let the equator go.
		Rp = radius_au
		Re = Rp * roche_shape(spin_frac)
		f = 1.0 - Rp / Re
	else:
		var lam: float = INERTIA_FACTOR.get(kind, INERTIA_FACTOR.rocky)
		var M := mass_sun * M_SUN
		var k := 2.5 * (1.0 - 1.5 * lam)
		var f_max: float = MAX_FLATTENING.get(kind, 0.42)
		# q is defined on the EQUATORIAL radius, which is itself what we are
		# solving for, so this is a fixed point. It converges in two passes
		# because f is small wherever the first-order theory is valid at all.
		Re = radius_au; f = 0.0
		for i in 3:
			var Rm := Re / Physics.AU_PER_KM * 1000.0
			var q := omega * omega * Rm * Rm * Rm / (G_SI * M)
			f = f_max * tanh(5.0 * q / (2.0 * (1.0 + k * k)) / f_max)
			# Conserve volume: a rotating body bulges, it does not simply gain size.
			# R³ = Re²·Rp with Re = Rp/(1−f) returns the mean radius exactly.
			Rp = radius_au * U.cbrt((1.0 - f) * (1.0 - f))
			Re = Rp / (1.0 - f)
	return {
		"f": f, "Re": Re, "Rp": Rp, "omega": omega, "omegaCrit": omega_crit, "spinFrac": spin_frac,
		"periodSec": 2.0 * PI / omega if omega > 0.0 else INF,
	}

# ----------------------------------------------------------------------------
# GRAVITY DARKENING (von Zeipel 1924).
#
# In a rotating star the surface is an equipotential but NOT an equal-flux
# surface: the radiative flux is proportional to the local effective gravity,
# so F ∝ g_eff and hence
#
#     T_eff ∝ g_eff^β,     β = ¼ (radiative envelope, von Zeipel)
#                          β ≈ 0.08 (convective envelope, Lucy 1967)
#
# The equator of a fast rotator is further from the centre AND has centrifugal
# support, so its effective gravity — and its temperature — are lower. This is
# not subtle: Vega's pole is measured at ~10 070 K and its equator at ~8 910 K,
# and Altair, Regulus and Achernar are all visibly two-toned. It is also why a
# pole-on rapid rotator (Vega) looks hotter and more luminous than it is, and
# why the sim needs it before it can honestly draw any of those stars.
#
# β switches with the envelope because the transport does: radiative flux
# follows the temperature gradient, convective flux follows buoyancy and is far
# less sensitive to g. Stars cooler than ~7000 K have convective envelopes.
#
# (For very rapid rotation von Zeipel's β = ¼ overestimates the contrast;
# Espinosa Lara & Rieutord 2011 give the correct model, which behaves like a
# β that falls toward ~0.19. The reduction below is that effect, applied as a
# correction rather than a full second model.)
# ----------------------------------------------------------------------------
static func gravity_darkening_beta(teff: float, spin_frac: float = 0.0) -> float:
	var convective := teff < 7000.0
	var base := 0.08 if convective else 0.25
	return base * (1.0 - 0.22 * spin_frac * spin_frac)

# Effective gravity at colatitude θ on a Roche surface, in units of the polar
# value. Used by the shader and by the temperature map below.
static func roche_gravity(spin_frac: float, cos_theta: float) -> float:
	var sinT := sqrt(maxf(0.0, 1.0 - cos_theta * cos_theta))
	var x := roche_shape(spin_frac * sinT)            # r / R_pole
	# With GM = 1 and R_pole = 1, Ω² = (8/27)ω².
	var om2 := (8.0 / 27.0) * spin_frac * spin_frac
	var gr := -1.0 / (x * x) + om2 * x * sinT * sinT  # radial
	var gt := om2 * x * sinT * cos_theta              # meridional
	return sqrt(gr * gr + gt * gt)                    # polar value is exactly 1

# Pole and equator temperatures for a star of mean Teff spinning at spinFrac.
# The mean is held fixed in the Stefan–Boltzmann sense — total luminosity is
# what is observed, and the rotation redistributes it, it does not create it.
## Returns { tPole, tEq, beta, gEq }.
static func gravity_darkened_temps(teff: float, spin_frac: float) -> Dictionary:
	var beta := gravity_darkening_beta(teff, spin_frac)
	var g_eq := roche_gravity(spin_frac, 0.0)
	var r_eq := pow(g_eq, beta)                       # T_eq / T_pole
	# Luminosity-weighted mean of T⁴ over the (approximated) surface, so that
	# 4πR²σT_mean⁴ is preserved; a two-point quadrature is plenty at this level.
	var mean4 := 0.5 * (1.0 + r_eq * r_eq * r_eq * r_eq)
	var t_pole := teff / pow(mean4, 0.25)
	return { "tPole": t_pole, "tEq": t_pole * r_eq, "beta": beta, "gEq": g_eq }

# ============================================================================
# CENTRAL CONDITIONS
# ----------------------------------------------------------------------------
# Hydrostatic equilibrium integrated over the star gives the virial estimates
#
#     P_c ~ (3/8π) GM²/R⁴          T_c ~ (1/2) μ m_H G M / (k R)
#
# which are correct in form and low by a fixed factor for a real centrally
# condensed star, because they assume the mean density throughout. Calibrating
# that factor once on the Sun (T_c = 1.571e7 K, P_c = 2.34e16 Pa) makes them
# usable across the main sequence, where the structure is genuinely homologous.
# They are labelled as estimates wherever the sim shows them.
# ============================================================================
# Each calibrated once against the modern standard solar model, at the Sun's
# PRESENT core composition (X_c ≈ 0.38, which is what phase_at(0.5) returns):
# T_c = 1.571e7 K, P_c = 2.34e16 Pa, ρ_c = 1.622e5 kg/m³ (ρ_c/ρ̄ = 115).
const TC_CAL := 1.660
const PC_CAL := 174.0
const RHOC_CAL := 115.0

## Returns { Tc, Pc, rhoMean, rhoC, mu }.
static func central_conditions(mass_sun: float, radius_sun_: float, X: float = 0.71, Z: float = 0.014) -> Dictionary:
	var M := mass_sun * M_SUN
	var R := maxf(radius_sun_, 1e-6) * R_SUN
	var mu := mean_molecular_weight(X, Z)
	var Tc := TC_CAL * 0.5 * mu * M_H * G_SI * M / (K_B * R)
	var Pc := PC_CAL * (3.0 / (8.0 * PI)) * G_SI * M * M / pow(R, 4.0)
	var rho_mean := M / ((4.0 / 3.0) * PI * R * R * R)
	return { "Tc": Tc, "Pc": Pc, "rhoMean": rho_mean, "rhoC": rho_mean * RHOC_CAL, "mu": mu }

# ============================================================================
# CONVECTION CELL SIZE
# ----------------------------------------------------------------------------
# Granules are not decoration and they are not all one size. A convection cell
# is about as wide as the pressure scale height at the surface,
#
#     H_p = kT / (mu m_H g),      g = GM/R²   ⇒   H_p/R = kTR / (mu m_H GM)
#
# so the number of cells across a star is R/H_p — and that number moves by more
# than two orders of magnitude across the stars this sim draws. The Sun gets
# H_p/R = 4.2e-4, which is ~2400 cells across a diameter, and photographs of it
# show exactly that: a fine mosaic. Betelgeuse gets 0.012, which is under a
# hundred, and the RHD simulations (Chiavassa et al.) and the direct images
# (VLTI, ALMA) both show what that means — a red supergiant's surface is a
# handful of ENORMOUS cells, one of which can cover a third of the visible
# disc, appearing and dissolving over years.
#
# Schwarzschild (1975) predicted this from exactly this argument, before any of
# it could be seen. Drawing a supergiant with solar granulation throws away the
# single most distinctive thing about how it looks.
#
# Returned as a noise frequency for the photosphere shader, normalised so the
# Sun keeps the value that was tuned by eye for it.
# ============================================================================
const HP_OVER_R_SUN := 4.16e-4
static func pressure_scale_height_frac(teff: float, radius_sun_: float, mass_sun: float, mu: float = 0.62) -> float:
	var R := maxf(radius_sun_, 1e-6) * R_SUN
	var M := maxf(mass_sun, 1e-6) * M_SUN
	return (K_B * teff * R) / (mu * M_H * G_SI * M)

static func granule_frequency(teff: float, radius_sun_: float, mass_sun: float) -> float:
	var hp := pressure_scale_height_frac(teff, radius_sun_, mass_sun)
	var cells := HP_OVER_R_SUN / maxf(hp, 1e-9)
	# The floor is not physical, it is the shader's: below ~1.5 the fBm has less
	# than one full period across the sphere and stops reading as cells at all.
	return minf(maxf(40.0 * cells, 1.5), 80.0)

# ----------------------------------------------------------------------------
# How bright to DRAW a photosphere, relative to the Sun's.
#
# The physics is one line — Stefan–Boltzmann, F = σT⁴ — and it says a 3600 K
# supergiant's surface is 0.15 of the Sun's per unit area while a 40 000 K O
# star's is 230 times it: a range of 1500 to 1 between the stars in this sim.
# Every star used to be drawn at the same surface brightness, which is why a
# red supergiant came out the same white as an A star.
#
# Drawing the raw ratio does not work, and the reason is not the renderer. It
# is that this sim has no auto-exposure in the orbit view: the tone curve is
# anchored once, near the Sun, so a disc at 0.15 lands low on it, and the sRGB
# encode then compresses what little colour ratio is left into brown-grey. A
# photograph of Betelgeuse is orange because the photographer exposed for
# Betelgeuse.
#
# So what is drawn is the eye's response to that ratio rather than the ratio
# itself. Stevens' power law puts perceived brightness at roughly L^⅓ for a
# large field viewed in the dark, which turns σT⁴ into
#
#     (T/T☉)^(4/3)
#
# — 0.53 for Betelgeuse, 1.97 for Vega, 13 for an O star. The ordering and the
# colour are preserved, the range is compressed the way an adapted observer
# compresses it, and it is honest about being a display transform rather than
# a flux. (Replacing this with a real adapted exposure over the HDR buffer
# would let the raw T⁴ through, and is the right thing to do eventually.)
#
# The cap is the renderer's, not the star's: past ~12 the bloom kernel runs out
# of extent and more energy only widens a white disc.
# ----------------------------------------------------------------------------
static func surface_brightness(teff: float) -> float:
	return minf(pow(maxf(teff, 500.0) / 5772.0, 4.0 / 3.0), 12.0)

# ============================================================================
# THE VERDICT — what the object actually does
# ----------------------------------------------------------------------------
# One place that decides, from mass / spin / phase alone, whether the thing you
# just built holds together. The editor reads this to warn you; the sim reads
# it to act on it.
# ============================================================================
const VERDICT := {
	"ok":        "stable",
	"breakup":   "breakup",      # spun past the mass-shedding limit
	"collapse":  "collapse",     # no pressure left → black hole
	"explode":   "explode",      # unbound by its own radiation, or pair instability
	"ignite":    "ignite",       # crossed a fusion threshold → becomes something else
	"degenerate":"degenerate",   # past the radius maximum: more mass, smaller body
}

# JS `Number.prototype.toString()` for the few LIMITS values interpolated into
# prose: an integer-valued number prints without a decimal point ("140", not
# Godot's "140.0").
static func _num(x: float) -> String:
	if x == floor(x) and absf(x) < 1e15:
		return str(int(x))
	return str(x)

# JS `(v > 0)` for a spec field that may be missing or null.
static func _pos(v) -> bool:
	return v != null and float(v) > 0.0

# ============================================================================
# THE MAIN ENTRY POINT
# ----------------------------------------------------------------------------
# structure_of(spec) → everything above, resolved for one object, plus the layer
# list the cross-section view draws. `spec`:
#   { type, mass (M☉), spinFrac (0–1), phase (f), composition, Z, radiusKm }
# ============================================================================
static func structure_of(spec: Dictionary) -> Dictionary:
	var t = spec.get("type")
	var type: String = t if (t != null and t != "") else "planet"
	var mass := maxf(float(U.nz(spec.get("mass"), 1.0)), 1e-12)
	var spin_frac := minf(maxf(float(U.nz(spec.get("spinFrac"), 0.0)), 0.0), 1.15)
	match type:
		"bh": return _hole_structure(spec, mass, spin_frac)
		"neutron": return _neutron_structure(spec, mass, spin_frac)
		"white-dwarf": return _white_dwarf_structure(spec, mass, spin_frac)
		"star": return _star_structure(spec, mass, spin_frac)
		"gas-giant": return _giant_structure(spec, mass, spin_frac)
		_: return _rocky_structure(spec, mass, spin_frac)

# Shared tail: apply rotation to a finished non-rotating structure.
static func _with_rotation(s: Dictionary, mass: float, kind: String, spin_frac: float) -> Dictionary:
	var omega_crit := breakup_omega(mass, s.radiusAU, kind)
	var rot := rotational_shape(mass, s.radiusAU, spin_frac * omega_crit, kind)
	s.rotation = rot
	s.radiusEqAU = rot.Re
	s.radiusPolarAU = rot.Rp
	s.flattening = rot.f
	s.spinFrac = spin_frac
	s.spinPeriodSec = rot.periodSec
	if spin_frac >= 0.999:
		s.verdict = {
			"state": VERDICT.breakup,
			"label": "Rotational break-up",
			"detail": "At the mass-shedding limit the equator is in orbit: R_eq/R_pol = 3/2 and material leaves the surface. Nothing rotating faster stays in one piece.",
		}
	return s

# ---------------------------------------------------------------------------
static func _rocky_structure(spec: Dictionary, mass: float, spin_frac: float) -> Dictionary:
	var sc = spec.get("composition")
	var comp: String = sc if (sc != null and sc is String and sc != "" and ROCK_COMPOSITIONS.has(sc)) else "earth"
	var c: Dictionary = ROCK_COMPOSITIONS[comp]
	var m_earth := mass / M_EARTH_SUN
	var peak := rocky_max_radius(comp)
	var peak_m: float = peak.massEarth
	var peak_r: float = peak.radiusEarth

	# Threshold crossings first — a "rocky planet" heavier than the deuterium
	# limit is not one, and saying so is the whole point of the editor.
	# Z-dependent, and identical to the limit _star_structure demotes on — see
	# _giant_structure for why they must not differ.
	var h_limit := hydrogen_burn_limit(float(U.nz(spec.get("Z"), 0.014)))
	if mass >= h_limit:
		return _reclassified("star", spec, mass, spin_frac,
			"At %s M☉ the core reaches 3 million K and hydrogen ignites. This is a star." % U.fixed(h_limit, 3))
	if mass >= float(LIMITS.deuteriumBurn):
		return _reclassified("gas-giant", spec, mass, spin_frac,
			"Above 13 M_J the core burns deuterium. This is a brown dwarf, not a planet.")

	var r_earth := rocky_radius_earth(m_earth, comp)
	var radius_au := r_earth * R_EARTH / 1000.0 * Physics.AU_PER_KM
	var rho_mean := (mass * M_SUN) / ((4.0 / 3.0) * PI * pow(r_earth * R_EARTH, 3.0))
	var cc := central_conditions(mass, radius_au / Physics.AU_PER_RSUN, 0.0, 1.0)
	# The virial temperature is meaningless for a cold solid body held up by
	# Coulomb forces; use the observed terrestrial scaling instead (Earth's core
	# is 5700 K, and central temperature rises roughly as M^0.6 across the
	# super-Earth range in interior models).
	var Tc := 5700.0 * pow(maxf(m_earth, 0.01), 0.6)
	var past := m_earth > peak_m

	var label: String
	if m_earth < 0.5: label = "Rocky body"
	elif m_earth < 2.0: label = "Terrestrial planet"
	elif m_earth < 10.0: label = "Super-Earth"
	else: label = "Mega-Earth"
	var verdict: Dictionary
	if past:
		verdict = {
			"state": VERDICT.degenerate,
			"label": "Degeneracy-limited",
			"detail": "Past %d M⊕ (%s M_J) electron degeneracy stiffens faster than gravity loads the planet, so adding mass now makes it SMALLER. The largest a solid planet of this composition can be is %s R⊕." % [
				int(U.jround(peak_m)), U.fixed(peak_m * M_EARTH_SUN / M_JUP_SUN, 2), U.fixed(peak_r, 2)],
		}
	else:
		verdict = {
			"state": VERDICT.ok, "label": c.label,
			"detail": "%s Radius follows Seager et al. (2007); it flattens out near %d M⊕ at %s R⊕ and turns over past it." % [
				c.note, int(U.jround(peak_m)), U.fixed(peak_r, 2)],
		}
	var s := {
		"type": "planet", "kind": "rocky", "mass": mass, "composition": comp,
		"label": label,
		"radiusAU": radius_au, "radiusKm": r_earth * R_EARTH / 1000.0, "radiusEarth": r_earth,
		"density": rho_mean, "Tc": Tc, "Pc": cc.Pc,
		"maxRadiusEarth": peak_r, "maxRadiusMassEarth": peak_m,
		"verdict": verdict,
		"layers": _rocky_layers(comp, r_earth, Tc),
	}
	return _with_rotation(s, mass, "iron" if (comp == "iron" or comp == "mercury") else "rocky", spin_frac)

static func _rocky_layers(comp: String, _r_earth: float, Tc: float) -> Array:
	# Core mass fractions from the Seager composition; converted to radius
	# fractions with the usual ~2:1 core/mantle density ratio.
	var core_frac: float = { "iron": 1.0, "mercury": 0.85, "earth": 0.545, "silicate": 0.0, "ocean": 0.40, "ice": 0.0 }.get(comp, 0.545)
	var ice_frac: float = { "ocean": 0.72, "ice": 1.0 }.get(comp, 0.0)
	var L := []
	if core_frac > 0.0:
		L.append({ "name": "Inner core", "r0": 0.0, "r1": core_frac * 0.35, "T": Tc, "rho": 13000.0,
			"note": "Solid iron–nickel. Freezes out of the liquid core as the planet cools." })
		L.append({ "name": "Outer core", "r0": core_frac * 0.35, "r1": core_frac, "T": Tc * 0.75, "rho": 11000.0,
			"note": "Liquid iron. Convection here is what generates a magnetic field." })
	var mantle_top := (1.0 - ice_frac * 0.45) if ice_frac > 0.0 else 0.985
	L.append({ "name": "Lower mantle", "r0": core_frac, "r1": core_frac + (mantle_top - core_frac) * 0.72, "T": Tc * 0.55, "rho": 5200.0,
		"note": "Bridgmanite — MgSiO₃ perovskite. The most abundant mineral in a rocky planet." })
	L.append({ "name": "Upper mantle", "r0": core_frac + (mantle_top - core_frac) * 0.72, "r1": mantle_top, "T": Tc * 0.28, "rho": 3400.0,
		"note": "Olivine and pyroxene. Solid, but creeping — this is what drives plate tectonics." })
	if ice_frac > 0.0:
		L.append({ "name": "High-pressure ice", "r0": mantle_top, "r1": 1.0 - ice_frac * 0.12, "T": 900.0, "rho": 1600.0,
			"note": "Ice VII and X — water frozen by pressure, not cold, at over 1000 K." })
		L.append({ "name": "Ocean", "r0": 1.0 - ice_frac * 0.12, "r1": 0.997, "T": 300.0, "rho": 1000.0,
			"note": "Liquid water. On a world this size it can be hundreds of km deep." })
	else:
		L.append({ "name": "Crust", "r0": mantle_top, "r1": 0.997, "T": 900.0, "rho": 2900.0,
			"note": "The chilled, brittle outer skin. A few tenths of a percent of the radius." })
	L.append({ "name": "Atmosphere", "r0": 0.997, "r1": 1.0, "T": 260.0, "rho": 1.2,
		"note": "Thin enough to be a rounding error on the radius, and the only part anything lives in." })
	return L

# ---------------------------------------------------------------------------
static func _giant_structure(spec: Dictionary, mass: float, spin_frac: float) -> Dictionary:
	# The SAME limit _star_structure demotes on. It has to be, or the two disagree:
	# _star_structure sends anything below hydrogen_burn_limit(Z) back down, and if
	# this promoted at a fixed 0.075 M☉ then at low Z every mass in between would
	# be reclassified up and down forever — structure_of recursing into itself
	# until the stack gives out, which is a hang, not a verdict.
	var h_limit := hydrogen_burn_limit(float(U.nz(spec.get("Z"), 0.014)))
	if mass >= h_limit:
		return _reclassified("star", spec, mass, spin_frac,
			"Above %s M☉ the core sustains hydrogen fusion. This is a star." % U.fixed(h_limit, 3))
	var m_jup := mass / M_JUP_SUN
	var r_jup := giant_radius_jup(m_jup)
	var radius_au := r_jup * R_JUP / 1000.0 * Physics.AU_PER_KM
	var rho := (mass * M_SUN) / ((4.0 / 3.0) * PI * pow(r_jup * R_JUP, 3.0))
	var brown := mass >= float(LIMITS.deuteriumBurn)
	# Interior temperature: Jupiter's centre is ~20 000 K; brown dwarfs reach
	# ~3e6 K, enough for deuterium but not hydrogen.
	var Tc := (5e5 * pow(m_jup / 13.0, 0.9)) if brown else (20000.0 * pow(maxf(m_jup, 0.05), 0.7))
	var past := m_jup > GIANT_M0

	var verdict: Dictionary
	if brown:
		verdict = {
			"state": VERDICT.ignite, "label": "Deuterium burning",
			"detail": "Above 13 M_J (%s M☉) the centre passes 5×10⁵ K and burns its deuterium — briefly, since there is very little of it. Not a planet, and not a star: a brown dwarf, which will simply cool forever." % U.fixed(LIMITS.deuteriumBurn, 4),
		}
	elif past:
		verdict = {
			"state": VERDICT.degenerate, "label": "Degeneracy-limited",
			"detail": "Past ~%s M_J the hydrogen is degenerate and more mass compresses the planet rather than inflating it. This is why every gas giant and brown dwarf, over a factor of 80 in mass, is within about 30%% of one Jupiter radius." % _num(GIANT_M0),
		}
	else:
		verdict = { "state": VERDICT.ok, "label": "Hydrogen–helium envelope",
			"detail": "Held up by ordinary gas pressure over a degenerate interior. Radius is nearly independent of mass here." }
	var label: String
	if brown: label = "Brown dwarf"
	elif m_jup < 0.3: label = "Ice giant"
	else: label = "Gas giant"
	var s := {
		"type": "gas-giant", "kind": "brown-dwarf" if brown else "giant", "mass": mass,
		"label": label,
		"radiusAU": radius_au, "radiusKm": r_jup * R_JUP / 1000.0, "radiusJup": r_jup,
		"density": rho, "Tc": Tc,
		"teff": (1300.0 * pow(m_jup / 13.0, 0.5)) if brown else 0.0,
		"verdict": verdict,
		"layers": _giant_layers(m_jup, Tc, brown),
	}
	return _with_rotation(s, mass, "giant", spin_frac)

static func _giant_layers(m_jup: float, Tc: float, brown: bool) -> Array:
	# The metallic-hydrogen transition sits near 0.8 R_J in Jupiter and moves
	# outward with mass; above ~2 M_J almost the whole interior is metallic.
	var met := minf(0.35 + 0.42 / maxf(pow(m_jup, 0.35), 0.4), 0.90)
	return [
		{ "name": "Rock/ice core", "r0": 0.0, "r1": 0.12, "T": Tc, "rho": 20000.0,
			"note": "If it formed like a star it may have none at all." if brown else "A few to twenty Earth masses of heavy elements — the seed the envelope collapsed onto." },
		{ "name": "Metallic hydrogen", "r0": 0.12, "r1": met, "T": Tc * 0.6, "rho": 1000.0,
			"note": "Hydrogen compressed until it ionises and conducts like a metal. Jupiter's enormous magnetic field is generated here." },
		{ "name": "Molecular hydrogen", "r0": met, "r1": 0.985, "T": 5000.0, "rho": 300.0,
			"note": "Fluid H₂ and helium, convecting all the way up. There is no surface anywhere in this." },
		{ "name": "Cloud decks", "r0": 0.985, "r1": 1.0, "T": 1300.0 if brown else 165.0, "rho": 0.2,
			"note": "Iron and silicate clouds, then methane as it cools." if brown else "Ammonia over ammonium hydrosulphide over water. The banding is the top of the convection." },
	]

# ---------------------------------------------------------------------------
static func _star_structure(spec: Dictionary, mass: float, spin_frac: float) -> Dictionary:
	var Z := float(U.nz(spec.get("Z"), 0.014))
	var h_limit := hydrogen_burn_limit(Z)
	if mass < h_limit:
		return _reclassified("gas-giant" if mass >= float(LIMITS.deuteriumBurn) else "planet", spec, mass, spin_frac,
			"Below %s M☉ the core never reaches the 3 million K hydrogen needs. This cannot be a star." % U.fixed(h_limit, 3))

	var ph := phase_at(float(U.nz(spec.get("phase"), 0.5)))
	var L0 := base_luminosity(mass, Z)
	var R0 := base_radius_sun(mass)
	var t_ms := main_sequence_lifetime(mass, L0)
	var ph_f: float = ph.f
	var ph_r: float = ph.rMul
	var ph_l: float = ph.lMul

	# Post-main-sequence radii scale with mass, but far more weakly than the
	# main-sequence relation — a red giant is a red giant whether it started at
	# 1 or 5 M☉, because its size is set by the burning shell and the degenerate
	# core it sits on, not by how much envelope is draped over them.
	var post := ph_f > 1.0
	var giant_damp := pow(mass, 0.25) if post else 1.0
	# Above roughly 40 M☉ a star leaving the main sequence does NOT become a red
	# supergiant. Its own radiation-driven wind strips the hydrogen envelope off
	# faster than the envelope can expand, and what is left is a Wolf–Rayet star:
	# the bare helium (then carbon) core, a few solar radii across and 50 000 to
	# 200 000 K. That is the same Humphreys–Davidson limit again, seen from the
	# other side — the reason no cool supergiants are observed at high luminosity
	# is that the stars that would have been them have been skinned.
	var wolf_rayet := post and mass > 40.0
	var R := maxf(R0 * 0.45, 1.0) if wolf_rayet else R0 * ph_r * giant_damp

	# Post-main-sequence LUMINOSITY does not scale like the phase table says for
	# anything but a solar-mass star, and the reason is worth stating: after the
	# main sequence a star's luminosity is set by its helium CORE, not by its
	# envelope. For a low-mass star that core is degenerate and grows enormously
	# relative to a small starting luminosity — the Sun will brighten by a factor
	# of a few hundred on the red giant branch. For anything above ~3 M☉ the core
	# is already most of the star's luminosity on the main sequence and there is
	# far less room to grow: a 16.5 M☉ star goes from 2.5e4 L☉ on the ZAMS to
	# 1.3e5 as a supergiant, a factor of five, not three hundred.
	#
	# So the phase multiplier is faded out with mass toward a flat factor of ~5.
	# The crossover at 2.2 M☉ is where the helium core stops being degenerate,
	# which is the same place the helium flash stops happening.
	const POST_MASSIVE := 5.0
	var L := L0 * ph_l
	if post and ph_l > 1.0:
		var w := 1.0 / (1.0 + pow(mass / 2.2, 3.0))
		L = L0 * (1.0 + (ph_l - 1.0) * w * w + (POST_MASSIVE - 1.0) * (1.0 - w))

	# A star cannot be more luminous than Eddington and stay bound, and the
	# massive ones genuinely run into that ceiling once they leave the main
	# sequence: L_Edd = 4πGMc/κ, which for electron scattering is 3.2e4 L☉ per
	# solar mass. Rather than let the phase multipliers — which are calibrated on
	# the solar track — carry a 20 M☉ star to ten times its own Eddington
	# luminosity, cap it there and let the verdict say why. That cap IS the
	# physics of a luminous blue variable.
	var L_edd := eddington_luminosity(mass)
	if L > 0.9 * L_edd:
		L = 0.9 * L_edd
		if not wolf_rayet: R = maxf(R, R0 * ph_r)

	# The Hayashi limit. A fully convective star cannot be cooler than about
	# 3000–3500 K and stay in hydrostatic equilibrium — to the right of that line
	# in the HR diagram there is no solution at all, which is why the coolest
	# supergiants all pile up against the same temperature regardless of mass.
	# Since L is fixed by the core, capping T from below caps R from above:
	#     R_max = √L · (T☉/T_Hayashi)²
	if not wolf_rayet: R = minf(R, sqrt(L) * pow(5772.0 / 3200.0, 2.0))

	# A MEASURED star overrides the model. sim/starcat.gd carries real radii,
	# temperatures and luminosities, and for anything off the main sequence they
	# are not close: the track above returns 244 R☉ for a 16.5 M☉ supergiant and
	# Betelgeuse is 764. Where an observation exists it is the answer, and the
	# evolutionary track is only there to fill in what was not measured.
	if _pos(spec.get("radiusSun")): R = float(spec.radiusSun)
	if _pos(spec.get("luminosity")): L = float(spec.luminosity)
	var gamma := L / L_edd

	var teff: float = float(spec.teff) if _pos(spec.get("teff")) else 5772.0 * pow(L / (R * R), 0.25)
	var gd := gravity_darkened_temps(teff, spin_frac)
	var radius_au := R * Physics.AU_PER_RSUN
	var cc := central_conditions(mass, R, ph.X, Z)
	var convective_envelope := teff < 7000.0
	var convective_core := mass > 1.2

	var s := {
		"type": "star", "kind": "star", "mass": mass, "Z": Z,
		"measured": _pos(spec.get("radiusSun")) or _pos(spec.get("teff")),
		"label": "%s · %s" % [spectral_full(teff, luminosity_class(R, mass)), ph.label],
		"phase": ph, "phaseF": ph_f,
		"radiusAU": radius_au, "radiusSun": R, "radiusKm": R * R_SUN / 1000.0,
		"luminosity": L, "teff": teff, "tPole": gd.tPole, "tEq": gd.tEq, "gdBeta": gd.beta,
		"Tc": cc.Tc, "Pc": cc.Pc, "rhoC": cc.rhoC, "density": cc.rhoMean, "mu": cc.mu,
		"X": ph.X, "eddington": gamma, "msLifetime": t_ms,
		"convectiveEnvelope": convective_envelope, "convectiveCore": convective_core, "wolfRayet": wolf_rayet,
		"endState": end_state_of(mass),
		"verdict": _stellar_verdict(mass, gamma, ph),
		"layers": _star_layers(mass, ph, cc, convective_core, convective_envelope),
	}
	return _with_rotation(s, mass, "star", spin_frac)

static func _stellar_verdict(mass: float, gamma: float, ph: Dictionary) -> Dictionary:
	# Order matters: the destruction mechanisms are checked before the merely
	# violent ones, because a 200 M☉ star's pair instability is not something its
	# Eddington factor gets a say in.

	if mass > float(LIMITS.humphreysDavidson) and mass < float(LIMITS.pairLo):
		return {
			"state": VERDICT.explode, "label": "Above the Humphreys–Davidson limit",
			"detail": "No stable supergiant is observed above this line in the HR diagram, and no stable star of any kind above about %s M☉ — the Arches cluster and R136 both cut off there. It is not a selection effect: a star this massive drives a radiation wind that strips it faster than it evolves, so it sheds itself back down. This one is a luminous blue variable, and it will erupt." % _num(LIMITS.eddingtonMass),
		}
	if mass >= float(LIMITS.pairLo) and mass <= float(LIMITS.pairHi):
		return {
			"state": VERDICT.explode, "label": "Pair instability",
			"detail": "Between %s and %s M☉ the core gets hot enough that photons convert into electron–positron pairs. Making pairs costs pressure, the adiabatic index drops below 4/3, and the core collapses — into a runaway oxygen burn that unbinds the entire star. There is no remnant at all." % [_num(LIMITS.pairLo), _num(LIMITS.pairHi)],
		}
	if mass > float(LIMITS.pairHi):
		return {
			"state": VERDICT.collapse, "label": "Direct collapse",
			"detail": "Above %s M☉ photodisintegration outruns the pair instability and the core implodes without any explosion. The star disappears into a black hole essentially whole." % _num(LIMITS.pairHi),
		}
	if gamma > 0.85:
		return {
			"state": VERDICT.explode, "label": "Eddington-limited",
			"detail": "L/L_Edd = %s. Radiation pressure on free electrons is now comparable to this star's own gravity, so its outer layers are barely bound at all. Real stars here — η Carinae and the luminous blue variables — do not sit quietly: they erupt, throwing off whole solar masses at a time. η Carinae shed 10–40 M☉ in a single event in the 1840s and survived it." % U.fixed(gamma, 2),
		}
	if ph.id == "preSN":
		return {
			"state": VERDICT.collapse, "label": "Pre-collapse",
			"detail": "Silicon burning has built an iron core. Iron cannot release energy by fusing, so the core has no way to replace what it radiates: it will collapse in under a second.",
		}
	if gamma > 0.35:
		return {
			"state": VERDICT.ok, "label": "Near-Eddington",
			"detail": "L/L_Edd = %s. Bound, but driving a heavy radiation-pressure wind — this star is losing mass fast enough to matter to its own evolution." % U.fixed(gamma, 2),
		}
	return { "state": VERDICT.ok, "label": "Hydrostatic equilibrium", "detail": "%s" % ph.note }

## Returns { type, label, mass? } — what the star leaves behind.
static func end_state_of(mass: float) -> Dictionary:
	if mass >= float(LIMITS.pairLo) and mass <= float(LIMITS.pairHi): return { "type": "none", "label": "No remnant (pair-instability SN)" }
	if mass > float(LIMITS.pairHi): return { "type": "bh", "label": "Black hole (direct collapse)", "mass": mass * 0.9 }
	if mass >= float(LIMITS.blackHoleMin): return { "type": "bh", "label": "Black hole", "mass": 0.3 * pow(mass, 0.85) }
	if mass >= float(LIMITS.neutronStarMin): return { "type": "neutron", "label": "Neutron star", "mass": 1.2 + 0.06 * (mass - 8.0) }
	# Initial–final mass relation for white dwarfs (Cummings et al. 2018):
	# roughly M_f = 0.08 M_i + 0.49 over 2–8 M☉.
	return { "type": "white-dwarf", "label": "White dwarf", "mass": minf(0.08 * mass + 0.49, 1.35) }

static func _star_layers(mass: float, ph: Dictionary, cc: Dictionary, conv_core: bool, conv_env: bool) -> Array:
	var L := []
	var giant := float(ph.f) > 1.15
	var massive := mass > 8.0

	if giant and massive and ph.id == "preSN":
		# The onion. Each shell is burning the ash of the one outside it, each
		# stage runs hotter, faster and shorter than the last: for a 20 M☉ star,
		# hydrogen lasts 10 Myr, helium 1 Myr, carbon 300 yr, neon 8 months,
		# oxygen 4 months and silicon about a DAY.
		L.append({ "name": "Iron core", "r0": 0.0, "r1": 0.010, "T": 8e9, "rho": 1e10,
			"note": "Inert. Iron is the bottom of the binding-energy curve — fusing it costs energy instead of releasing it. This core is already collapsing." })
		L.append({ "name": "Silicon shell", "r0": 0.010, "r1": 0.020, "T": 3.5e9, "rho": 1e8, "note": "Si → Fe. Lasts about a day." })
		L.append({ "name": "Oxygen shell", "r0": 0.020, "r1": 0.038, "T": 2.1e9, "rho": 1e7, "note": "O → Si, S. A few months." })
		L.append({ "name": "Neon shell", "r0": 0.038, "r1": 0.060, "T": 1.4e9, "rho": 4e6, "note": "Ne → O, Mg. Under a year." })
		L.append({ "name": "Carbon shell", "r0": 0.060, "r1": 0.10, "T": 8e8, "rho": 2e5, "note": "C → Ne, Na, Mg. Centuries." })
		L.append({ "name": "Helium shell", "r0": 0.10, "r1": 0.22, "T": 2e8, "rho": 1e3, "note": "3 ⁴He → ¹²C. Hundreds of thousands of years." })
		L.append({ "name": "Hydrogen envelope", "r0": 0.22, "r1": 0.995, "T": 5e6, "rho": 0.1,
			"note": "Almost all the volume and almost none of the action — convective, tenuous, and about to be thrown off." })
		L.append({ "name": "Photosphere", "r0": 0.995, "r1": 1.0, "T": 3500.0, "rho": 1e-7, "note": "Where the star finally becomes transparent." })
		return L

	if giant:
		var core_r := 0.008
		L.append({ "name": "Degenerate helium core", "r0": 0.0, "r1": core_r, "T": cc.Tc, "rho": 1e6,
			"note": "Held up by electron degeneracy, not heat. About the size of Earth, and containing a third of the star." })
		L.append({ "name": "Hydrogen-burning shell", "r0": core_r, "r1": core_r * 1.5, "T": 4e7, "rho": 1e4,
			"note": "A thin, ferociously hot shell. This — not the core — is what makes a red giant bright." })
		L.append({ "name": "Convective envelope", "r0": core_r * 1.5, "r1": 0.99, "T": 3e5, "rho": 1e-4,
			"note": "Enormous, cool, and turning over in a handful of vast convection cells rather than millions of granules." })
		L.append({ "name": "Photosphere", "r0": 0.99, "r1": 1.0, "T": 3600.0, "rho": 1e-8,
			"note": "So tenuous that it is closer to a laboratory vacuum than to air." })
		return L

	# Main sequence. Which way round the convection goes is set by mass, and it
	# is a real and visible divide: stars above ~1.2 M☉ burn by the CNO cycle,
	# whose ferocious temperature sensitivity (ε ∝ T¹⁷) concentrates the energy
	# release so sharply that radiation cannot carry it and the CORE convects.
	# Below that, the pp chain (ε ∝ T⁴) is gentle enough for a radiative core,
	# and it is the cool opaque OUTER layers that convect instead.
	if conv_core:
		L.append({ "name": "Convective core", "r0": 0.0, "r1": 0.20, "T": cc.Tc, "rho": cc.rhoC,
			"note": "CNO-cycle burning, ε ∝ T¹⁷. Too concentrated for radiation to carry, so it boils — and keeps mixing fresh hydrogen in, which extends the star's life." })
		L.append({ "name": "Radiative envelope", "r0": 0.20, "r1": 0.99, "T": float(cc.Tc) * 0.1, "rho": cc.rhoMean,
			"note": "Stably stratified. Photons random-walk outward; nothing overturns." })
	else:
		L.append({ "name": "Core", "r0": 0.0, "r1": 0.25, "T": cc.Tc, "rho": cc.rhoC,
			"note": "pp-chain burning, ε ∝ T⁴. Gentle enough that radiation alone can carry the energy away." })
		L.append({ "name": "Radiative zone", "r0": 0.25, "r1": 0.71 if conv_env else 0.99, "T": float(cc.Tc) * 0.15, "rho": float(cc.rhoMean) * 5.0,
			"note": "A photon takes of order 100 000 years to random-walk across this." })
		if conv_env:
			L.append({ "name": "Convective zone", "r0": 0.71, "r1": 0.995, "T": 2e6, "rho": 1e-3,
				"note": "Opaque enough that convection beats radiation. The overturning here, sheared by rotation, is the star's magnetic dynamo." })
	L.append({ "name": "Photosphere", "r0": 0.995, "r1": 1.0, "T": 0.0, "rho": 1e-4,
		"note": "A few hundred km thick and the only part you can see. Its granulation is the tops of the convection cells." })
	L.append({ "name": "Chromosphere", "r0": 1.0, "r1": 1.004, "T": 20000.0, "rho": 1e-8, "note": "Thin, hot, and visible only as the pink rim in an eclipse." })
	L.append({ "name": "Corona", "r0": 1.004, "r1": 1.06, "T": 2e6, "rho": 1e-12,
		"note": "A million kelvin above a 5800 K surface — magnetically heated, and still not fully explained." })
	return L

# ---------------------------------------------------------------------------
static func _neutron_structure(spec: Dictionary, mass: float, spin_frac: float) -> Dictionary:
	var max_m := tov_limit(spin_frac)
	if mass > max_m:
		var hs := spec.duplicate()
		hs.type = "bh"
		var s := _hole_structure(hs, mass, spin_frac)
		var rot_note := ""
		if spin_frac > 0.02:
			rot_note = " (%s M☉ at rest, raised %d%% by rotation)" % [_num(LIMITS.tov), int(U.jround((max_m / float(LIMITS.tov) - 1.0) * 100.0))]
		s.verdict = {
			"state": VERDICT.collapse, "label": "TOV limit exceeded",
			"detail": "%s M☉ is past the %s M☉ this star can support%s. Neutron degeneracy and the strong force are the last sources of pressure there are — past them nothing stops the collapse, and it becomes a black hole." % [U.fixed(mass, 2), U.fixed(max_m, 2), rot_note],
		}
		s.wasNeutron = true
		return s
	if mass < 0.1:
		return {
			"type": "neutron", "kind": "neutron", "mass": mass, "radiusAU": neutron_radius_km(0.1) * Physics.AU_PER_KM,
			"label": "Sub-minimum-mass", "layers": [],
			"verdict": { "state": VERDICT.explode, "label": "Below the minimum mass",
				"detail": "Under about 0.1 M☉ a neutron star is not gravitationally bound against its own degeneracy pressure. It expands and disintegrates." },
		}

	var r_km := neutron_radius_km(mass)
	var radius_au := r_km * Physics.AU_PER_KM
	var rs := Physics.schwarzschild(mass)
	var compactness := rs / radius_au              # 2GM/Rc² — how relativistic
	var rho := (mass * M_SUN) / ((4.0 / 3.0) * PI * pow(r_km * 1000.0, 3.0))
	var surface_g := G_SI * mass * M_SUN / pow(r_km * 1000.0, 2.0)
	var omega_c := breakup_omega(mass, radius_au)
	var period_ms := (2.0 * PI / (spin_frac * omega_c) * 1000.0) if spin_frac > 0.0 else INF

	var verdict: Dictionary
	if mass > max_m * 0.95:
		verdict = {
			"state": VERDICT.ok, "label": "Near the TOV limit",
			"detail": "Within 5%% of the %s M☉ maximum. A little more mass — or losing this spin — and it collapses." % U.fixed(max_m, 2),
		}
	else:
		verdict = {
			"state": VERDICT.ok, "label": "Neutron degeneracy + strong force",
			"detail": "Mean density %s×10¹⁷ kg/m³ — a sugar cube of this weighs as much as a mountain. Surface gravity is %s g, and light leaving the surface is redshifted by %s%%." % [
				U.fixed(rho / 1e17, 2), U.expo(surface_g / 9.81, 1),
				U.fixed((1.0 / sqrt(maxf(1.0 - compactness, 1e-3)) - 1.0) * 100.0, 0)],
		}
	var s := {
		"type": "neutron", "kind": "neutron", "mass": mass,
		"label": "Millisecond pulsar" if period_ms < 30.0 else "Neutron star",
		"radiusAU": radius_au, "radiusKm": r_km, "density": rho, "surfaceGravity": surface_g,
		"compactness": compactness, "tovMax": max_m, "spinPeriodMs": period_ms,
		# Redshift of light leaving the surface: 1/√(1−r_s/R) − 1. At 0.3
		# compactness this is ~19%, big enough to see in the spectrum.
		"redshift": 1.0 / sqrt(maxf(1.0 - compactness, 1e-3)) - 1.0,
		"teff": 6e5,
		"verdict": verdict,
		"layers": _neutron_layers(r_km),
	}
	return _with_rotation(s, mass, "neutron", spin_frac)

static func _neutron_layers(_r_km: float) -> Array:
	return [
		{ "name": "Inner core", "r0": 0.0, "r1": 0.45, "T": 1e8, "rho": 1.2e18,
			"note": "Above a few times nuclear density, and genuinely unknown. Hyperons? A deconfined quark–gluon core? Which it is decides the TOV limit." },
		{ "name": "Outer core", "r0": 0.45, "r1": 0.90, "T": 2e8, "rho": 5e17,
			"note": "Superfluid neutrons with a few percent superconducting protons and electrons. Frictionless — and the sudden unpinning of its vortices is what makes a pulsar glitch." },
		{ "name": "Inner crust", "r0": 0.90, "r1": 0.975, "T": 5e8, "rho": 1e17,
			"note": "Past neutron drip. Nuclei dissolve into \"nuclear pasta\" — sheets and rods of nuclear matter, the stiffest material that exists." },
		{ "name": "Outer crust", "r0": 0.975, "r1": 0.998, "T": 1e8, "rho": 1e11,
			"note": "A crystalline lattice of iron-group nuclei in a degenerate electron sea. About a kilometre thick, and 10¹⁸ times stronger than steel." },
		{ "name": "Atmosphere", "r0": 0.998, "r1": 1.0, "T": 1e6, "rho": 1e2,
			"note": "A few centimetres of carbon or hydrogen plasma. It sets the X-ray spectrum, which is how the radius gets measured at all." },
	]

# ---------------------------------------------------------------------------
static func _white_dwarf_structure(spec: Dictionary, mass: float, spin_frac: float) -> Dictionary:
	if mass >= float(LIMITS.chandrasekhar):
		return {
			"type": "white-dwarf", "kind": "wd", "mass": mass, "radiusAU": 0.0,
			"label": "Chandrasekhar mass exceeded", "layers": [],
			"verdict": {
				"state": VERDICT.explode, "label": "Type Ia supernova",
				"detail": "Past %s M☉ the electrons are relativistic and degeneracy pressure stops growing with density — there is no equilibrium left. In practice the star ignites its carbon first and detonates completely as a Type Ia supernova, leaving nothing. Because that always happens at the same mass, they all have nearly the same brightness, which is how the expansion of the universe was measured." % _num(LIMITS.chandrasekhar),
			},
		}
	var R := white_dwarf_radius_sun(mass)
	var radius_au := R * Physics.AU_PER_RSUN
	var teff := float(U.nz(spec.get("teff"), 12000.0))
	var rho := (mass * M_SUN) / ((4.0 / 3.0) * PI * pow(R * R_SUN, 3.0))
	var s := {
		"type": "white-dwarf", "kind": "wd", "mass": mass,
		"label": "White dwarf", "radiusAU": radius_au, "radiusSun": R, "radiusKm": R * R_SUN / 1000.0,
		"density": rho, "teff": teff, "Tc": 1e7,
		"luminosity": 4.0 * PI * pow(R * R_SUN, 2.0) * SIGMA * pow(teff, 4.0) / L_SUN,
		"verdict": {
			"state": VERDICT.ok if mass > float(LIMITS.chandrasekhar) * 0.93 else VERDICT.degenerate,
			"label": "Electron degeneracy",
			"detail": "Earth-sized and star-massed: mean density %s×10⁹ kg/m³. Because degeneracy pressure does not care about temperature, a white dwarf gets SMALLER as it gets heavier — R ∝ M^−⅓ — and shrinks to nothing at the Chandrasekhar mass of %s M☉." % [U.fixed(rho / 1e9, 2), _num(LIMITS.chandrasekhar)],
		},
		"layers": [
			{ "name": "C/O core", "r0": 0.0, "r1": 0.98, "T": 1e7, "rho": rho * 1.4,
				"note": "Carbon and oxygen ash, degenerate throughout. It cools by conduction and eventually crystallises — a diamond the size of a planet." },
			{ "name": "Helium layer", "r0": 0.98, "r1": 0.995, "T": 1e6, "rho": 1e5, "note": "About 1% of the mass, and opaque enough to slow the cooling by billions of years." },
			{ "name": "Hydrogen skin", "r0": 0.995, "r1": 1.0, "T": teff, "rho": 1e2, "note": "A hundred metres of hydrogen, 10⁻⁴ of the mass. It is all you can see." },
		],
	}
	return _with_rotation(s, mass, "wd", spin_frac)

# ---------------------------------------------------------------------------
# A black hole has no interior to draw, which is exactly why the cross-section
# is interesting: everything labelled here is a property of the SPACETIME
# outside it, and every one of them is a real, locatable surface.
static func _hole_structure(spec: Dictionary, mass: float, spin_frac: float) -> Dictionary:
	var a := minf(spin_frac, 0.998)                  # dimensionless Kerr spin a/M
	var rs_au := float(U.nz(spec.get("rs"), Physics.schwarzschild(mass)))
	var M := rs_au / 2.0                             # geometric mass, AU
	# Kerr horizon: r₊ = M + √(M² − a²M²)
	var r_plus := M * (1.0 + sqrt(maxf(1.0 - a * a, 0.0)))
	# Prograde ISCO (Bardeen, Press & Teukolsky 1972).
	var z1 := 1.0 + U.cbrt(1.0 - a * a) * (U.cbrt(1.0 + a) + U.cbrt(1.0 - a))
	var z2 := sqrt(3.0 * a * a + z1 * z1)
	var r_isco := M * (3.0 + z2 - sqrt(maxf((3.0 - z1) * (3.0 + z1 + 2.0 * z2), 0.0)))
	# Hawking temperature and evaporation time, for the readout.
	var t_hawk := 6.169e-8 / mass                    # K
	var t_evap := 2.1e67 * pow(mass, 3.0)            # yr

	return {
		"type": "bh", "kind": "bh", "mass": mass,
		"label": ("Kerr black hole (a* = %s)" % U.fixed(a, 2)) if a > 0.1 else "Schwarzschild black hole",
		"radiusAU": r_plus, "rs": rs_au, "spin": a,
		"horizonAU": r_plus, "photonSphereAU": (2.0 * M * (1.0 + cos((2.0 / 3.0) * acos(-a)))) if a > 0.01 else 1.5 * rs_au,
		"shadowAU": sqrt(27.0) / 2.0 * M * 2.0 * 0.5 + sqrt(27.0) * M / 2.0,   # ≈ √27 M
		"iscoAU": r_isco, "ergoAU": 2.0 * M if a > 0.01 else rs_au,
		"hawkingK": t_hawk, "evaporationYr": t_evap,
		"teff": 2.0e7 * pow(maxf(mass, 0.1), -0.25),
		"verdict": {
			"state": VERDICT.ok, "label": "No equilibrium",
			"detail": "There is no pressure here at all — nothing is holding anything up. The Hawking temperature is %s K, far below the 2.7 K microwave background, so this hole absorbs more than it radiates and will keep growing for another 10^%d years before it can even begin to evaporate." % [
				U.expo(t_hawk, 2), int(U.jround(U.log10(t_evap)))],
		},
		"layers": _hole_layers(M, r_plus, r_isco, a),
	}

static func _hole_layers(M: float, r_plus: float, r_isco: float, a: float) -> Array:
	# Normalised against the ISCO, which is the outermost thing drawn.
	var N := r_isco
	var f := func(r: float) -> float: return minf(r / N, 1.0)
	var L := [
		{ "name": "Singularity", "r0": 0.0, "r1": f.call(M * 0.06), "T": INF, "rho": INF,
			"note": "A ring, not a point — a rotating hole's singularity is a circle of radius aM in the equatorial plane. General relativity stops predicting anything here, which is a statement about the theory, not about the place." if a > 0.01
				else "A point of infinite density where the equations stop making sense. Everything that falls in reaches it in finite proper time." },
		{ "name": "Interior", "r0": f.call(M * 0.06), "r1": f.call(r_plus), "T": 0.0, "rho": 0.0,
			"note": "Inside the horizon the radial direction becomes timelike: falling inward stops being a direction you can choose and becomes a direction in time, like tomorrow. Nothing here is drawn from observation, because nothing here can be observed." },
		{ "name": "Event horizon", "r0": f.call(r_plus), "r1": f.call(r_plus * 1.02), "T": 0.0, "rho": 0.0,
			"note": "r₊ = %s AU in Schwarzschild terms. Not a surface — a one-way boundary. Falling through it, you notice nothing at all." % U.fixed(r_plus * 2.0, 4) },
	]
	if a > 0.01:
		L.append({ "name": "Ergosphere", "r0": f.call(r_plus * 1.02), "r1": f.call(2.0 * M), "T": 0.0, "rho": 0.0,
			"note": "Frame dragging is so strong here that standing still is impossible — you must rotate with the hole. Energy can be extracted from this region (the Penrose process), which is where a quasar's jets get their power." })
	L.append({ "name": "Photon sphere", "r0": f.call(1.5 * 2.0 * M) - 0.004, "r1": f.call(1.5 * 2.0 * M) + 0.004, "T": 0.0, "rho": 0.0,
		"note": "r = 1.5 r_s, where light orbits. Unstable — a photon here needs only a nudge to fall in or escape. Its lensed image is the bright ring you actually see, at √27·M ≈ 2.6 r_s." })
	L.append({ "name": "ISCO", "r0": f.call(r_isco) - 0.004, "r1": f.call(r_isco), "T": 0.0, "rho": 0.0,
		"note": "The innermost stable circular orbit, at %s M. Inside it there are no stable orbits at all, so an accretion disc simply ends here and its inner edge plunges. This is what sets a disc's peak temperature." % U.fixed(r_isco / M, 2) })
	return L

# ---------------------------------------------------------------------------
# A mass that crossed a threshold: rebuild it as what it actually is, and carry
# the explanation with it.
static func _reclassified(new_type: String, spec: Dictionary, mass: float, spin_frac: float, why: String) -> Dictionary:
	var sp := spec.duplicate()
	sp.type = new_type; sp.mass = mass; sp.spinFrac = spin_frac
	var s := structure_of(sp)
	# JS `s.reclassifiedFrom = spec.type` — undefined when the spec had none,
	# and an undefined key is simply absent.
	if spec.get("type") != null:
		s.reclassifiedFrom = spec.type
	s.verdict = { "state": VERDICT.ignite, "label": "Reclassified", "detail": why }
	return s

# ---------------------------------------------------------------------------
static func spectral_type(teff: float) -> String:
	if teff >= 33000.0: return "O"
	if teff >= 10000.0: return "B"
	if teff >= 7300.0: return "A"
	if teff >= 6000.0: return "F"
	if teff >= 5300.0: return "G"
	if teff >= 3900.0: return "K"
	if teff >= 2400.0: return "M"
	return "L"

# Full MK type with a digit, e.g. "G2". The subdivisions are linear in
# log Teff within each class, which is close enough to the real scale.
const _SP_EDGES := [["O", 33000.0, 55000.0], ["B", 10000.0, 33000.0], ["A", 7300.0, 10000.0],
		["F", 6000.0, 7300.0], ["G", 5300.0, 6000.0], ["K", 3900.0, 5300.0], ["M", 2400.0, 3900.0]]
static func spectral_full(teff: float, lum_class: String = "V") -> String:
	for e in _SP_EDGES:
		var letter: String = e[0]
		var lo: float = e[1]
		var hi: float = e[2]
		if teff >= lo and teff < hi:
			var d := mini(9, maxi(0, int(floor(10.0 * (U.log10(hi) - U.log10(teff)) / (U.log10(hi) - U.log10(lo))))))
			return "%s%d%s" % [letter, d, lum_class]
	return ("O2" + lum_class) if teff >= 55000.0 else ("L" + lum_class)

# Luminosity class from radius, which is what the class actually encodes.
static func luminosity_class(radius_sun_: float, mass_sun: float) -> String:
	var ms := zams_radius_sun(mass_sun)
	var r := radius_sun_ / maxf(ms, 1e-6)
	if r > 100.0: return "Ia"
	if r > 40.0: return "Ib"
	if r > 12.0: return "II"
	if r > 4.0: return "III"
	if r > 1.9: return "IV"
	return "V"
