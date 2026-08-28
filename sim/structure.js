import { G, C, AU_PER_RSUN, AU_PER_KM, schwarzschild } from './physics.js';

// ============================================================================
// INTERIOR STRUCTURE & STABILITY
// ----------------------------------------------------------------------------
// Every other module in this sim answers "where is it and what does it look
// like". This one answers "what IS it" — given a mass, a spin and a point in
// its life, what holds the thing up, how big does that make it, what does it
// look like on the inside, and at what point does the support fail.
//
// That last question is the reason the module exists. The sim's editor lets you
// drag a mass slider, and the interesting behaviour is entirely in the places
// where the answer stops being "a bigger one of the same thing":
//
//   · a rocky planet stops growing at ~300 M⊕ and then SHRINKS, because
//     electron degeneracy stiffens faster than gravity loads it
//   · at 13 M_J it lights deuterium and is a brown dwarf
//   · at 0.075 M☉ it lights hydrogen and is a star
//   · a star spun past its Keplerian limit sheds its equator
//   · a neutron star past the TOV mass has nothing left to hold it up
//   · a star past ~150 M☉ is pushed apart by its own radiation
//
// None of those are thresholds invented for the sim. They are all consequences
// of one competition — pressure against gravity — and the point of collecting
// them here is that the editor can be a slider over real physics rather than a
// menu of hand-authored outcomes.
//
// UNITS. Public functions take and return the sim's astronomical units (M☉, AU,
// years). Internally, anything involving a real equation of state works in SI,
// because that is the only way the published fits mean anything.
// ============================================================================

// --- SI constants, for the interior physics only.
const G_SI    = 6.67430e-11;
const M_SUN   = 1.98892e30;      // kg
const R_SUN   = 6.957e8;         // m
const L_SUN   = 3.828e26;        // W
const M_EARTH = 5.97217e24;
const R_EARTH = 6.371e6;
const M_JUP   = 1.89813e27;
const R_JUP   = 6.9911e7;
const SIGMA   = 5.670374e-8;     // Stefan–Boltzmann
const K_B     = 1.380649e-23;
const M_H     = 1.6735575e-27;
const SEC_PER_YR = 3.155815e7;

export const M_EARTH_SUN = M_EARTH / M_SUN;    // 3.0035e-6
export const M_JUP_SUN   = M_JUP / M_SUN;      // 9.5459e-4

// Mass thresholds that decide what an object IS. All are physical ignition or
// support limits, not categories.
export const LIMITS = {
  // Deuterium ignites at T_c ≈ 5e5 K, reached at ~13 M_J. This is the IAU's
  // working planet/brown-dwarf line for the same reason.
  deuteriumBurn: 13 * M_JUP_SUN,        // 0.0124 M☉
  // Hydrogen ignites at ~0.075 M☉ for solar composition (lower, ~0.09, for
  // metal-poor gas — hence the Z dependence in hydrogenBurnLimit()).
  hydrogenBurn: 0.075,
  // Chandrasekhar mass for a μ_e = 2 (C/O) white dwarf.
  chandrasekhar: 1.44,
  // Tolman–Oppenheimer–Volkoff maximum for a NON-rotating neutron star. The
  // EOS is not known, so this is a range in the literature (2.0–2.3); GW170817's
  // remnant and the heaviest measured pulsars bracket it near 2.2.
  tov: 2.20,
  // Uniform (rigid) rotation supports a "supramassive" star up to ~20% above
  // the TOV mass. Differential rotation buys more, but only transiently.
  tovSpinBoost: 0.20,
  // The Humphreys–Davidson limit: the empirical upper envelope in the HR
  // diagram, above which no stable supergiant is observed. Stars exist above
  // it, but only as luminous blue variables shedding mass in eruptions.
  humphreysDavidson: 120,
  // And the observed upper limit on stellar mass itself. Both the Arches
  // cluster and R136 cut off near here.
  eddingtonMass: 150,
  // Pair-instability window: a He core of 65–135 M☉ makes electron–positron
  // pairs, the adiabatic index falls below 4/3, and the star is disrupted with
  // NO remnant. In terms of initial mass that is roughly 140–260 M☉.
  pairLo: 140, pairHi: 260,
  // Above the pair window, photodisintegration wins and the whole star goes
  // directly to a black hole.
  // Core-collapse thresholds (initial mass, solar metallicity).
  neutronStarMin: 8, blackHoleMin: 20,
};

// Metal-poor gas is more transparent and needs a slightly higher mass to reach
// the ignition temperature. (Z = mass fraction in elements heavier than He.)
export function hydrogenBurnLimit(Z = 0.014) {
  return 0.075 + 0.015 * Math.max(0, 1 - Z / 0.014);
}

// ============================================================================
// SOLID / GASEOUS PLANETS — the mass–radius curve, and where it turns over
// ----------------------------------------------------------------------------
// Seager et al. (2007), "Mass–Radius Relationships for Solid Exoplanets"
// (ApJ 669, 1279; arXiv:0707.2895), show that every solid composition collapses
// onto ONE curve in scaled variables, because all of their equations of state
// are well fitted by a modified polytrope ρ = ρ₀ + cPⁿ with n ≈ 0.51–0.55:
//
//     log₁₀ Rs = k₁ + ⅓ log₁₀ Ms − k₂ Ms^k₃
//
// with Ms = M/m₁, Rs = R/r₁ and the material entering only through the scaling
// pair (m₁, r₁) from their Table 4.
//
// The ⅓ term is the incompressible limit — a Coulomb lattice, where adding mass
// just adds volume. The −k₂Ms^k₃ term is self-compression, and it is what makes
// the curve bend over: differentiate, and dlog R/dlog M reaches zero at
//
//     k₂k₃ Ms^k₃ = 1/(3 ln10)   ⇒   Ms ≈ 47   ⇒   M ≈ 300 M⊕ ≈ 0.95 M_J
//
// That is the sim's headline result for the editor: a rocky planet has a
// LARGEST POSSIBLE SIZE of about 3 R⊕, reached near one Jupiter mass, and past
// it more mass makes it smaller. Seager's fit is quoted as good to Ms ≲ 40, so
// the turnover sits just outside its stated range and its position is good to
// perhaps 20% — but the turnover itself is not a fitting artefact, it is
// electron degeneracy, and every full EOS calculation (Zapolsky & Salpeter
// 1969 onward) finds it.
//
// Validation: the Earth-like differentiated row (32.5% Fe core by mass) gives
// m₁ = 6.41 M⊕, r₁ = 3.19 R⊕. At M = 1 M⊕ that returns 0.970 R⊕ — 3% low,
// which is about the accuracy the paper claims.
// ============================================================================
const SEAGER_K = { k1: -0.209490, k2: 0.0804, k3: 0.394 };

// Scaling pairs from Seager Table 4, in (M⊕, R⊕).
export const ROCK_COMPOSITIONS = {
  iron:     { label: 'Iron',            m1: 4.34, r1: 2.23, rho0: 8300, note: 'Pure Fe(ε). The smallest a planet of a given mass can be.' },
  mercury:  { label: 'Iron-rich',       m1: 6.41, r1: 2.84, rho0: 6600, note: '~70% iron core, like Mercury.' },
  earth:    { label: 'Earth-like',      m1: 6.41, r1: 3.19, rho0: 5510, note: '32.5% iron core, 67.5% silicate mantle.' },
  silicate: { label: 'Silicate',        m1: 7.38, r1: 3.58, rho0: 4100, note: 'Pure MgSiO₃ perovskite — a coreless rock.' },
  ocean:    { label: 'Ocean world',     m1: 6.88, r1: 4.02, rho0: 2700, note: '45% water ice over rock and a small iron core.' },
  ice:      { label: 'Ice',             m1: 8.16, r1: 4.73, rho0: 1460, note: 'Pure H₂O ice — the largest a solid planet can be.' },
};

// Scaled radius from Seager's equation (23). Ms, Rs are dimensionless.
function seagerRs(Ms) {
  const { k1, k2, k3 } = SEAGER_K;
  return Math.pow(10, k1 + Math.log10(Ms) / 3 - k2 * Math.pow(Ms, k3));
}

// Radius (R⊕) of a solid planet of mass M (M⊕) and the given composition.
export function rockyRadiusEarth(mEarth, comp = 'earth') {
  const c = ROCK_COMPOSITIONS[comp] || ROCK_COMPOSITIONS.earth;
  const Ms = Math.max(mEarth, 1e-6) / c.m1;
  return c.r1 * seagerRs(Ms);
}

// The turnover, solved rather than tabulated: k₂k₃·Ms^k₃ = 1/(3 ln10).
export function rockyMaxRadius(comp = 'earth') {
  const c = ROCK_COMPOSITIONS[comp] || ROCK_COMPOSITIONS.earth;
  const { k2, k3 } = SEAGER_K;
  const Ms = Math.pow(1 / (3 * Math.LN10 * k2 * k3), 1 / k3);
  return { massEarth: Ms * c.m1, radiusEarth: c.r1 * seagerRs(Ms) };
}

// ----------------------------------------------------------------------------
// H/He-dominated objects: giant planets and brown dwarfs.
//
// Once hydrogen and helium dominate, the same competition plays out with a much
// softer floor, and the result is the flattest curve in astrophysics: every
// object from Saturn to the hydrogen-burning limit — a factor of 80 in mass —
// sits within about 30% of one Jupiter radius. The interpolation used here has
// the two limiting slopes built in,
//
//     R ∝ M^⅓ / (1 + (M/M₀)^⅔)
//
// which is R ∝ M^⅓ while the gas is classical and R ∝ M^−⅓ once it is fully
// degenerate (the cold-sphere / Chandrasekhar result), with its maximum exactly
// at M₀. Zapolsky & Salpeter (1969) put that maximum near 3–4 M_J at ~1.1 R_J
// for solar composition, which is what M₀ and the prefactor are set to.
//
// Deuterium burning (13–65 M_J) briefly halts the contraction and is worth a
// few percent in radius; it is not modelled, because it does not survive the
// scatter of the real population.
// ----------------------------------------------------------------------------
const GIANT_M0 = 3.5;            // M_J — where degeneracy takes over
const GIANT_RMAX = 1.10;         // R_J at that mass
export function giantRadiusJup(mJup) {
  const m = Math.max(mJup, 1e-3);
  const u = Math.pow(m / GIANT_M0, 2 / 3);
  // normalised so R(M₀) = GIANT_RMAX exactly
  return GIANT_RMAX * 2 * Math.pow(m / GIANT_M0, 1 / 3) / (1 + u);
}

// ----------------------------------------------------------------------------
// White dwarfs. Degenerate electrons, so the radius FALLS with mass and reaches
// zero at the Chandrasekhar mass. The non-relativistic result R ∝ M^−⅓ is only
// right well below it; the standard correction that carries the curve to
// M_Ch is Nauenberg (1972):
//
//     R = 0.0126 R☉ · (μ_e/2)^−⁵⸍³ · (M/M_Ch)^−⅓ · [1 − (M/M_Ch)^{4/3}]^½
//
// which gives 0.0084 R☉ at 1.0 M☉ — Sirius B, measured at 0.0084 R☉.
// ----------------------------------------------------------------------------
export function whiteDwarfRadiusSun(massSun) {
  const x = Math.min(massSun / LIMITS.chandrasekhar, 0.999);
  return 0.0126 * Math.pow(x, -1 / 3) * Math.sqrt(Math.max(1 - Math.pow(x, 4 / 3), 1e-6));
}

// ----------------------------------------------------------------------------
// Neutron stars. The EOS above nuclear density is genuinely unknown, so this is
// a smooth stand-in for the family of modern "stiff enough to reach 2.1 M☉"
// candidates: nearly flat at 11.5–12.5 km through the observed mass range, then
// steepening sharply as the TOV mass is approached and the star runs out of
// pressure. NICER's measurements of PSR J0030 and J0740 both land near 12.4 km.
// ----------------------------------------------------------------------------
export function neutronRadiusKm(massSun) {
  const m = Math.max(massSun, 0.1);
  const x = Math.min(m / LIMITS.tov, 0.999);
  // 12.6 km plateau, collapsing as x → 1
  return 12.6 * Math.pow(1 - 0.62 * Math.pow(x, 6), 0.22);
}

// The maximum mass a neutron star can carry, given how fast it spins. Rigid
// rotation adds centrifugal support worth ~20% at the mass-shedding limit.
export function tovLimit(spinFrac = 0) {
  return LIMITS.tov * (1 + LIMITS.tovSpinBoost * Math.min(Math.max(spinFrac, 0), 1) ** 2);
}

// ============================================================================
// STELLAR EVOLUTION — "how much of its life it has burned"
// ----------------------------------------------------------------------------
// A star is not one object. It is a sequence, and which part of the sequence
// you are looking at changes its radius by three orders of magnitude and its
// colour from blue to red and back. The editor exposes that as one knob, and
// this is what the knob drives.
//
// The physics behind the main-sequence part is homology. Fusion converts H to
// He, which RAISES the mean molecular weight of the core,
//
//     μ = 4 / (3 + 5X − Z)      (fully ionised)
//
// from 0.62 at X = 0.71 to 1.34 at X = 0. The core must then be hotter and
// denser to hold the same weight up, so the star brightens and swells while it
// sits on the main sequence — the Sun is ~30% brighter now than at its ZAMS and
// will be ~2.2× as bright when its core hydrogen runs out. The fits below
// reproduce that (L grows ×2.2, R grows ×1.6 across the main sequence), which
// is the right behaviour for solar-type stars and roughly right for the rest.
//
// Everything after the main sequence — shell burning, the giant branches, the
// remnant — is not homologous and cannot be got from a scaling law. Those
// phases are entered here as calibrated stops along the track, with radii and
// temperatures taken from where real stars of that mass actually sit.
// ============================================================================

// Mean molecular weight for a fully ionised mix.
export function meanMolecularWeight(X, Z) { return 4 / (3 + 5 * X - Z); }

// Main-sequence lifetime (yr): t ≈ 10 Gyr · (M/M☉) / (L/L☉), because the fuel
// available is ∝ M and the rate it burns at is ∝ L.
export function mainSequenceLifetime(massSun, L) {
  return 1.0e10 * massSun / Math.max(L, 1e-6);
}

// The named stops. `f` is the position on the track used by the UI (0 = ZAMS,
// 1 = core hydrogen exhausted, >1 = post-main-sequence). `X` is the CORE
// hydrogen fraction.
//
// `rMul`/`lMul` multiply the BASELINE radius and luminosity — and the baseline
// is the middle of the main sequence, not the zero-age start of it, because
// that is what baseRadiusSun / baseLuminosity are normalised to (1 M☉ → 1 R☉,
// 1 L☉, which is today's 4.6 Gyr-old Sun). The main-sequence entries are
// therefore calibrated directly against the solar track: the ZAMS Sun really
// was 0.70 L☉ and 0.90 R☉, and it really will reach about 1.85 L☉ and 1.35 R☉
// before its core hydrogen runs out. Setting f = 0.5 returns the Sun exactly.
export const PHASES = [
  { id: 'protostar', label: 'Protostar',      f: -0.15, X: 0.71, rMul: 3.5,  lMul: 1.2,  burn: 'gravitational contraction',
    note: 'Not yet fusing. Held up by the heat of its own collapse, sliding down the Hayashi track.' },
  { id: 'zams',      label: 'ZAMS',           f: 0.00,  X: 0.71, rMul: 0.90, lMul: 0.70,  burn: 'H → He (core)',
    note: 'Zero-age main sequence. Core hydrogen just lit; the star is as small and faint as it will ever be while burning.' },
  { id: 'ms-early',  label: 'Early MS',       f: 0.25,  X: 0.55, rMul: 0.95, lMul: 0.83, burn: 'H → He (core)',
    note: 'A quarter through. Helium ash is accumulating in the core and the star is slowly brightening.' },
  { id: 'ms-mid',    label: 'Mid MS',         f: 0.50,  X: 0.38, rMul: 1.00, lMul: 1.00, burn: 'H → He (core)',
    note: 'Half its hydrogen gone. Where the Sun is now.' },
  { id: 'ms-late',   label: 'Late MS',        f: 0.85,  X: 0.12, rMul: 1.15, lMul: 1.40, burn: 'H → He (core)',
    note: 'Running out. The core is nearly pure helium and the envelope is visibly swelling.' },
  { id: 'tams',      label: 'TAMS',           f: 1.00,  X: 0.00, rMul: 1.35, lMul: 1.85, burn: 'H → He (shell)',
    note: 'Core hydrogen exhausted. Burning moves to a shell around an inert helium core; the main sequence is over.' },
  { id: 'subgiant',  label: 'Subgiant',       f: 1.10,  X: 0.00, rMul: 2.8,  lMul: 2.5,  burn: 'H → He (shell)',
    note: 'The inert core contracts, the shell burns hotter, and the envelope expands to absorb it. Cooling at nearly constant luminosity.' },
  { id: 'rgb',       label: 'Red giant',      f: 1.35,  X: 0.00, rMul: 25,   lMul: 320,  burn: 'H → He (shell), degenerate He core',
    note: 'A degenerate helium core the size of Earth inside a convective envelope the size of Mercury\'s orbit.' },
  { id: 'heburn',    label: 'Core He burning',f: 1.55,  X: 0.00, rMul: 10,   lMul: 65,   burn: '3 ⁴He → ¹²C (core)',
    note: 'Helium ignites — in low-mass stars all at once, in a flash — and the star settles back down to burn it.' },
  { id: 'agb',       label: 'AGB / supergiant',f: 1.80, X: 0.00, rMul: 130,  lMul: 3500, burn: 'H and He shells; C/O core',
    note: 'Two burning shells around an inert carbon–oxygen core, an enormous pulsating envelope, and a heavy wind stripping it away.' },
  { id: 'preSN',     label: 'Pre-collapse',   f: 1.95,  X: 0.00, rMul: 220,  lMul: 6000, burn: 'Si → Fe (core), onion shells',
    note: 'Massive stars only. Silicon burning takes days and builds an iron core that cannot burn. Collapse is imminent.' },
  { id: 'remnant',   label: 'Remnant',        f: 2.00,  X: 0.00, rMul: 0,    lMul: 0,    burn: 'none',
    note: 'What is left when the pressure fails.' },
];

export function phaseById(id) { return PHASES.find(p => p.id === id) || PHASES[1]; }

// Interpolate the track between named stops so the UI slider is continuous.
export function phaseAt(f) {
  const lo = PHASES[0], hi = PHASES[PHASES.length - 1];
  if (f <= lo.f) return { ...lo };
  if (f >= hi.f) return { ...hi };
  for (let i = 0; i < PHASES.length - 1; i++) {
    const a = PHASES[i], b = PHASES[i + 1];
    if (f >= a.f && f <= b.f) {
      const t = (f - a.f) / (b.f - a.f);
      // Radius and luminosity span orders of magnitude across the giant
      // branches, so interpolate them in the log — a linear blend from 1.6 to
      // 25 R☉ would spend most of the slider in a size no star occupies.
      const lerpLog = (u, v) => Math.exp(Math.log(Math.max(u, 1e-6)) * (1 - t) + Math.log(Math.max(v, 1e-6)) * t);
      return {
        id: t < 0.5 ? a.id : b.id,
        label: t < 0.5 ? a.label : b.label,
        note: t < 0.5 ? a.note : b.note,
        burn: t < 0.5 ? a.burn : b.burn,
        f,
        X: a.X + (b.X - a.X) * t,
        rMul: b.rMul === 0 ? a.rMul : lerpLog(a.rMul, b.rMul),
        lMul: b.lMul === 0 ? a.lMul : lerpLog(a.lMul, b.lMul),
      };
    }
  }
  return { ...PHASES[1] };
}

// ----------------------------------------------------------------------------
// ZAMS scaling relations. These are the same piecewise mass–luminosity and
// mass–radius laws sim/stellar.js uses for the main sequence, restated here so
// the structure model is self-contained and can be given a metallicity.
// ----------------------------------------------------------------------------
// Above 20 M☉ no single power law works: the slope of the mass–luminosity
// relation falls from 3.5 toward ~1.4 as massive stars approach the Eddington
// ceiling. Rather than extrapolate a power law past where it is calibrated,
// interpolate in log–log through anchors read off the Geneva rotating grids
// (Ekström et al. 2012; Yusof et al. 2013 for the very massive end).
const MASSIVE_L = [
  [20, 5.01e4], [30, 1.41e5], [40, 2.82e5], [60, 5.62e5],
  [85, 1.00e6], [120, 1.58e6], [150, 2.00e6], [200, 3.02e6], [300, 5.01e6],
];

export function baseLuminosity(massSun, Z = 0.014) {
  const m = Math.max(massSun, 0.02);
  let L;
  if (m < 0.43)      L = 0.23 * Math.pow(m, 2.3);
  else if (m < 2.0)  L = Math.pow(m, 4.0);
  else if (m < 20)   L = 1.4 * Math.pow(m, 3.5);
  else {
    const A = MASSIVE_L;
    if (m >= A[A.length - 1][0]) {
      const [m0, L0] = A[A.length - 1];
      L = L0 * Math.pow(m / m0, 1.4);
    } else {
      let i = 0; while (A[i + 1][0] < m) i++;
      const [m0, L0] = A[i], [m1, L1] = A[i + 1];
      const t = (Math.log(m) - Math.log(m0)) / (Math.log(m1) - Math.log(m0));
      L = Math.exp(Math.log(L0) * (1 - t) + Math.log(L1) * t);
    }
  }
  // Metal-poor stars are more transparent, so they are hotter and brighter at
  // fixed mass — a weak but real dependence.
  return L * Math.pow(0.014 / Math.max(Z, 1e-4), 0.12);
}

export function baseRadiusSun(massSun) {
  const m = Math.max(massSun, 0.05);
  return m < 1.0 ? Math.pow(m, 0.8) : Math.pow(m, 0.57);
}

// Kept under the old names so nothing outside this module has to know that the
// baseline is mid-main-sequence rather than zero-age (see PHASES).
export const zamsLuminosity = baseLuminosity;
export const zamsRadiusSun = baseRadiusSun;

// Eddington luminosity in L☉ for electron-scattering opacity (κ = 0.34 m²/kg,
// solar composition). L/L_Edd is the single number that decides whether a
// massive star's atmosphere is bound to it.
export function eddingtonLuminosity(massSun) { return 3.2e4 * massSun; }

// ============================================================================
// ROTATION — shape, break-up, and gravity darkening
// ----------------------------------------------------------------------------
// Two different problems, because two different mass distributions.
//
// PLANETS are not very centrally condensed, and their flattening is small, so
// the first-order hydrostatic theory is both valid and accurate. The
// Darwin–Radau relation ties the flattening f to the rotation parameter
// q = Ω²R³/GM through the moment-of-inertia factor λ = C/MR²:
//
//     f = 5q / (2[1 + ((5/2)(1 − (3/2)λ))²])
//
// Fed Earth's numbers it returns 1/300 against a measured 1/298.25, and
// Jupiter's it returns 0.0656 against a measured 0.0649. That is not a fit —
// λ is an independently measured quantity for both.
//
// STARS are extremely centrally condensed: the Sun carries half its mass inside
// 0.26 R☉. The right limit is therefore the opposite one — the ROCHE model,
// where the whole mass is treated as a point and the surface is an equipotential
// of Φ = −GM/r − ½Ω²r²sin²θ. Writing ω = Ω/Ω_crit, that equipotential is the
// cubic
//
//     1/x + (4/27)ω²x²sin²θ = 1,        x = R(θ)/R_pole
//
// whose relevant root has the closed form used below. It carries one famous and
// completely non-obvious consequence: at break-up, exactly,
//
//     R_equator / R_pole = 3/2
//
// no matter what the star is. Nothing can be flatter than that and stay in one
// piece — which is why Achernar, measured at 1.35, is described as being close
// to break-up, and why the sim can put a hard, principled stop on the spin
// slider instead of an arbitrary one.
// ============================================================================

// Moment-of-inertia factor C/MR² by kind of body. Measured where measured.
export const INERTIA_FACTOR = {
  rocky: 0.3307,      // Earth
  iron: 0.26,         // Mercury-like, big core
  giant: 0.254,       // Jupiter
  star: 0.073,        // solar model — a star is nearly all centre
  neutron: 0.36,      // NS are stiff and nearly uniform; ~0.35–0.4 for stiff EOS
  wd: 0.16,
};

// The largest flattening each kind can actually reach before it sheds mass.
// Darwin–Radau is a FIRST-ORDER theory: it is excellent while f is small (it
// returns Earth's and Jupiter's measured values to 1%) and meaningless as f
// approaches the mass-shedding limit, where it runs off to any value at all.
// So it is saturated onto the shape the body genuinely terminates at:
//
//   neutron stars — numerical models with realistic equations of state stop at
//                   R_eq/R_pol ≈ 1.5 at the Kepler frequency, the same ratio
//                   the Roche model gives, because a neutron star is also
//                   strongly centrally condensed
//   planets       — nothing in this sim gets close, but the uniform-density
//                   (Maclaurin) sequence turns over near f ≈ 0.42
//
// The saturation used is f_max·tanh(f/f_max), which equals f to first order —
// so nothing that was accurate is disturbed — and can never exceed f_max.
const MAX_FLATTENING = { neutron: 0.333, rocky: 0.42, iron: 0.42, giant: 0.42, wd: 0.333 };

// The angular velocity at which the equator is in orbit and material leaves —
// the mass-shedding, or Keplerian, limit.
//
// Where that is depends on how the mass is arranged, and the two cases differ
// by a factor of nearly two, so it is not a detail. For a body that barely
// deforms, break-up is simply Ω = √(GM/R³) at its own radius. For a centrally
// condensed one the Roche geometry gets there first: the equator has already
// swelled to 1.5 R_pole by then, so the orbit it has to match is a wider one,
//
//     Ω_crit = √(GM / (1.5 R_pole)³) = √(8GM / 27 R_pole³)
//
// which is 0.544 of the naive value. Passing a polar radius and getting the
// naive answer back would put every star's break-up in the wrong place.
export function breakupOmega(massSun, radiusAU, kind = 'star') {
  const M = massSun * M_SUN, R = radiusAU / AU_PER_KM * 1000;
  const K = (kind === 'star' || kind === 'wd') ? 8 / 27 : 1;
  return Math.sqrt(K * G_SI * M / (R * R * R));
}

// The Roche-model surface: R(θ)/R_pole for ω = Ω/Ω_crit and colatitude θ.
// `u` = ω·sinθ. Below 1e-3 the closed form is 0/0, so use its series there.
export function rocheShape(u) {
  const uu = Math.min(Math.max(u, 0), 1);
  if (uu < 1e-3) return 1 + (4 / 27) * uu * uu;
  return (3 / uu) * Math.cos((Math.PI + Math.acos(uu)) / 3);
}

// The inverse: given a MEASURED R_eq/R_pole, what fraction of break-up is the
// star spinning at? Interferometry measures the shape far more precisely than
// it measures the equatorial velocity (which needs the inclination), so for a
// real star the shape is the better input. rocheShape is monotonic on [0,1],
// so a bisection is exact and cheap.
export function inverseRocheShape(ratio) {
  const r = Math.min(Math.max(ratio, 1), 1.5);
  let lo = 0, hi = 1;
  for (let i = 0; i < 40; i++) {
    const mid = (lo + hi) / 2;
    if (rocheShape(mid) < r) lo = mid; else hi = mid;
  }
  return (lo + hi) / 2;
}

// Flattening of a rotating body. `kind` selects which theory applies.
//   omega    rad/s
//   radiusAU non-rotating (or polar) radius
// Returns { f, Re, Rp, omegaCrit, spinFrac, periodSec }.
export function rotationalShape(massSun, radiusAU, omega, kind = 'star') {
  const omegaCrit = breakupOmega(massSun, radiusAU, kind);
  const spinFrac = omegaCrit > 0 ? Math.min(omega / omegaCrit, 1) : 0;
  let Re, Rp, f;
  if (kind === 'star' || kind === 'wd') {
    // Roche: the polar radius barely moves (it is nearly all interior), so hold
    // it and let the equator go.
    Rp = radiusAU;
    Re = Rp * rocheShape(spinFrac);
    f = 1 - Rp / Re;
  } else {
    const lam = INERTIA_FACTOR[kind] ?? INERTIA_FACTOR.rocky;
    const M = massSun * M_SUN;
    const k = 2.5 * (1 - 1.5 * lam);
    const fMax = MAX_FLATTENING[kind] ?? 0.42;
    // q is defined on the EQUATORIAL radius, which is itself what we are
    // solving for, so this is a fixed point. It converges in two passes
    // because f is small wherever the first-order theory is valid at all.
    Re = radiusAU; f = 0;
    for (let i = 0; i < 3; i++) {
      const Rm = Re / AU_PER_KM * 1000;
      const q = omega * omega * Rm * Rm * Rm / (G_SI * M);
      f = fMax * Math.tanh(5 * q / (2 * (1 + k * k)) / fMax);
      // Conserve volume: a rotating body bulges, it does not simply gain size.
      // R³ = Re²·Rp with Re = Rp/(1−f) returns the mean radius exactly.
      Rp = radiusAU * Math.cbrt((1 - f) * (1 - f));
      Re = Rp / (1 - f);
    }
  }
  return {
    f, Re, Rp, omega, omegaCrit, spinFrac,
    periodSec: omega > 0 ? 2 * Math.PI / omega : Infinity,
  };
}

// ----------------------------------------------------------------------------
// GRAVITY DARKENING (von Zeipel 1924).
//
// In a rotating star the surface is an equipotential but NOT an equal-flux
// surface: the radiative flux is proportional to the local effective gravity,
// so F ∝ g_eff and hence
//
//     T_eff ∝ g_eff^β,     β = ¼ (radiative envelope, von Zeipel)
//                          β ≈ 0.08 (convective envelope, Lucy 1967)
//
// The equator of a fast rotator is further from the centre AND has centrifugal
// support, so its effective gravity — and its temperature — are lower. This is
// not subtle: Vega's pole is measured at ~10 070 K and its equator at ~8 910 K,
// and Altair, Regulus and Achernar are all visibly two-toned. It is also why a
// pole-on rapid rotator (Vega) looks hotter and more luminous than it is, and
// why the sim needs it before it can honestly draw any of those stars.
//
// β switches with the envelope because the transport does: radiative flux
// follows the temperature gradient, convective flux follows buoyancy and is far
// less sensitive to g. Stars cooler than ~7000 K have convective envelopes.
//
// (For very rapid rotation von Zeipel's β = ¼ overestimates the contrast;
// Espinosa Lara & Rieutord 2011 give the correct model, which behaves like a
// β that falls toward ~0.19. The reduction below is that effect, applied as a
// correction rather than a full second model.)
// ----------------------------------------------------------------------------
export function gravityDarkeningBeta(teff, spinFrac = 0) {
  const convective = teff < 7000;
  const base = convective ? 0.08 : 0.25;
  return base * (1 - 0.22 * spinFrac * spinFrac);
}

// Effective gravity at colatitude θ on a Roche surface, in units of the polar
// value. Used by the shader and by the temperature map below.
export function rocheGravity(spinFrac, cosTheta) {
  const sinT = Math.sqrt(Math.max(0, 1 - cosTheta * cosTheta));
  const x = rocheShape(spinFrac * sinT);           // r / R_pole
  // With GM = 1 and R_pole = 1, Ω² = (8/27)ω².
  const om2 = (8 / 27) * spinFrac * spinFrac;
  const gr = -1 / (x * x) + om2 * x * sinT * sinT;  // radial
  const gt = om2 * x * sinT * cosTheta;             // meridional
  return Math.sqrt(gr * gr + gt * gt);              // polar value is exactly 1
}

// Pole and equator temperatures for a star of mean Teff spinning at spinFrac.
// The mean is held fixed in the Stefan–Boltzmann sense — total luminosity is
// what is observed, and the rotation redistributes it, it does not create it.
export function gravityDarkenedTemps(teff, spinFrac) {
  const beta = gravityDarkeningBeta(teff, spinFrac);
  const gEq = rocheGravity(spinFrac, 0);
  const rEq = Math.pow(gEq, beta);                  // T_eq / T_pole
  // Luminosity-weighted mean of T⁴ over the (approximated) surface, so that
  // 4πR²σT_mean⁴ is preserved; a two-point quadrature is plenty at this level.
  const mean4 = 0.5 * (1 + rEq * rEq * rEq * rEq);
  const tPole = teff / Math.pow(mean4, 0.25);
  return { tPole, tEq: tPole * rEq, beta, gEq };
}

// ============================================================================
// CENTRAL CONDITIONS
// ----------------------------------------------------------------------------
// Hydrostatic equilibrium integrated over the star gives the virial estimates
//
//     P_c ~ (3/8π) GM²/R⁴          T_c ~ (1/2) μ m_H G M / (k R)
//
// which are correct in form and low by a fixed factor for a real centrally
// condensed star, because they assume the mean density throughout. Calibrating
// that factor once on the Sun (T_c = 1.571e7 K, P_c = 2.34e16 Pa) makes them
// usable across the main sequence, where the structure is genuinely homologous.
// They are labelled as estimates wherever the sim shows them.
// ============================================================================
// Each calibrated once against the modern standard solar model, at the Sun's
// PRESENT core composition (X_c ≈ 0.38, which is what phaseAt(0.5) returns):
// T_c = 1.571e7 K, P_c = 2.34e16 Pa, ρ_c = 1.622e5 kg/m³ (ρ_c/ρ̄ = 115).
const TC_CAL = 1.660;
const PC_CAL = 174.0;
const RHOC_CAL = 115;

export function centralConditions(massSun, radiusSun_, X = 0.71, Z = 0.014) {
  const M = massSun * M_SUN, R = Math.max(radiusSun_, 1e-6) * R_SUN;
  const mu = meanMolecularWeight(X, Z);
  const Tc = TC_CAL * 0.5 * mu * M_H * G_SI * M / (K_B * R);
  const Pc = PC_CAL * (3 / (8 * Math.PI)) * G_SI * M * M / Math.pow(R, 4);
  const rhoMean = M / ((4 / 3) * Math.PI * R * R * R);
  return { Tc, Pc, rhoMean, rhoC: rhoMean * RHOC_CAL, mu };
}

// ============================================================================
// CONVECTION CELL SIZE
// ----------------------------------------------------------------------------
// Granules are not decoration and they are not all one size. A convection cell
// is about as wide as the pressure scale height at the surface,
//
//     H_p = kT / (mu m_H g),      g = GM/R²   ⇒   H_p/R = kTR / (mu m_H GM)
//
// so the number of cells across a star is R/H_p — and that number moves by more
// than two orders of magnitude across the stars this sim draws. The Sun gets
// H_p/R = 4.2e-4, which is ~2400 cells across a diameter, and photographs of it
// show exactly that: a fine mosaic. Betelgeuse gets 0.012, which is under a
// hundred, and the RHD simulations (Chiavassa et al.) and the direct images
// (VLTI, ALMA) both show what that means — a red supergiant's surface is a
// handful of ENORMOUS cells, one of which can cover a third of the visible
// disc, appearing and dissolving over years.
//
// Schwarzschild (1975) predicted this from exactly this argument, before any of
// it could be seen. Drawing a supergiant with solar granulation throws away the
// single most distinctive thing about how it looks.
//
// Returned as a noise frequency for the photosphere shader, normalised so the
// Sun keeps the value that was tuned by eye for it.
// ============================================================================
const HP_OVER_R_SUN = 4.16e-4;
export function pressureScaleHeightFrac(teff, radiusSun_, massSun, mu = 0.62) {
  const R = Math.max(radiusSun_, 1e-6) * R_SUN, M = Math.max(massSun, 1e-6) * M_SUN;
  return (K_B * teff * R) / (mu * M_H * G_SI * M);
}
export function granuleFrequency(teff, radiusSun_, massSun) {
  const hp = pressureScaleHeightFrac(teff, radiusSun_, massSun);
  const cells = HP_OVER_R_SUN / Math.max(hp, 1e-9);
  // The floor is not physical, it is the shader's: below ~1.5 the fBm has less
  // than one full period across the sphere and stops reading as cells at all.
  return Math.min(Math.max(40 * cells, 1.5), 80);
}

// ----------------------------------------------------------------------------
// How bright to DRAW a photosphere, relative to the Sun's.
//
// The physics is one line — Stefan–Boltzmann, F = σT⁴ — and it says a 3600 K
// supergiant's surface is 0.15 of the Sun's per unit area while a 40 000 K O
// star's is 230 times it: a range of 1500 to 1 between the stars in this sim.
// Every star used to be drawn at the same surface brightness, which is why a
// red supergiant came out the same white as an A star.
//
// Drawing the raw ratio does not work, and the reason is not the renderer. It
// is that this sim has no auto-exposure in the orbit view: the tone curve is
// anchored once, near the Sun, so a disc at 0.15 lands low on it, and the sRGB
// encode then compresses what little colour ratio is left into brown-grey. A
// photograph of Betelgeuse is orange because the photographer exposed for
// Betelgeuse.
//
// So what is drawn is the eye's response to that ratio rather than the ratio
// itself. Stevens' power law puts perceived brightness at roughly L^⅓ for a
// large field viewed in the dark, which turns σT⁴ into
//
//     (T/T☉)^(4/3)
//
// — 0.53 for Betelgeuse, 1.97 for Vega, 13 for an O star. The ordering and the
// colour are preserved, the range is compressed the way an adapted observer
// compresses it, and it is honest about being a display transform rather than
// a flux. (Replacing this with a real adapted exposure over the HDR buffer
// would let the raw T⁴ through, and is the right thing to do eventually.)
//
// The cap is the renderer's, not the star's: past ~12 the bloom kernel runs out
// of extent and more energy only widens a white disc.
// ----------------------------------------------------------------------------
export function surfaceBrightness(teff) {
  return Math.min(Math.pow(Math.max(teff, 500) / 5772, 4 / 3), 12);
}

// ============================================================================
// THE VERDICT — what the object actually does
// ----------------------------------------------------------------------------
// One place that decides, from mass / spin / phase alone, whether the thing you
// just built holds together. The editor reads this to warn you; the sim reads
// it to act on it.
// ============================================================================
export const VERDICT = {
  ok:        'stable',
  breakup:   'breakup',      // spun past the mass-shedding limit
  collapse:  'collapse',     // no pressure left → black hole
  explode:   'explode',      // unbound by its own radiation, or pair instability
  ignite:    'ignite',       // crossed a fusion threshold → becomes something else
  degenerate:'degenerate',   // past the radius maximum: more mass, smaller body
};

// ============================================================================
// THE MAIN ENTRY POINT
// ----------------------------------------------------------------------------
// structureOf(spec) → everything above, resolved for one object, plus the layer
// list the cross-section view draws. `spec`:
//   { type, mass (M☉), spinFrac (0–1), phase (f), composition, Z, radiusKm }
// ============================================================================
export function structureOf(spec) {
  const type = spec.type || 'planet';
  const mass = Math.max(spec.mass ?? 1, 1e-12);
  const spinFrac = Math.min(Math.max(spec.spinFrac ?? 0, 0), 1.15);
  switch (type) {
    case 'bh':       return holeStructure(spec, mass, spinFrac);
    case 'neutron':  return neutronStructure(spec, mass, spinFrac);
    case 'white-dwarf': return whiteDwarfStructure(spec, mass, spinFrac);
    case 'star':     return starStructure(spec, mass, spinFrac);
    case 'gas-giant':return giantStructure(spec, mass, spinFrac);
    default:         return rockyStructure(spec, mass, spinFrac);
  }
}

// Shared tail: apply rotation to a finished non-rotating structure.
function withRotation(s, mass, kind, spinFrac) {
  const omegaCrit = breakupOmega(mass, s.radiusAU, kind);
  const rot = rotationalShape(mass, s.radiusAU, spinFrac * omegaCrit, kind);
  s.rotation = rot;
  s.radiusEqAU = rot.Re;
  s.radiusPolarAU = rot.Rp;
  s.flattening = rot.f;
  s.spinFrac = spinFrac;
  s.spinPeriodSec = rot.periodSec;
  if (spinFrac >= 0.999) {
    s.verdict = {
      state: VERDICT.breakup,
      label: 'Rotational break-up',
      detail: `At the mass-shedding limit the equator is in orbit: R_eq/R_pol = 3/2 and material leaves the surface. Nothing rotating faster stays in one piece.`,
    };
  }
  return s;
}

// ---------------------------------------------------------------------------
function rockyStructure(spec, mass, spinFrac) {
  const comp = spec.composition && ROCK_COMPOSITIONS[spec.composition] ? spec.composition : 'earth';
  const c = ROCK_COMPOSITIONS[comp];
  const mEarth = mass / M_EARTH_SUN;
  const peak = rockyMaxRadius(comp);

  // Threshold crossings first — a "rocky planet" heavier than the deuterium
  // limit is not one, and saying so is the whole point of the editor.
  // Z-dependent, and identical to the limit starStructure demotes on — see
  // giantStructure for why they must not differ.
  const hLimit = hydrogenBurnLimit(spec.Z ?? 0.014);
  if (mass >= hLimit) {
    return reclassified('star', spec, mass, spinFrac,
      `At ${hLimit.toFixed(3)} M☉ the core reaches 3 million K and hydrogen ignites. This is a star.`);
  }
  if (mass >= LIMITS.deuteriumBurn) {
    return reclassified('gas-giant', spec, mass, spinFrac,
      `Above 13 M_J the core burns deuterium. This is a brown dwarf, not a planet.`);
  }

  const rEarth = rockyRadiusEarth(mEarth, comp);
  const radiusAU = rEarth * R_EARTH / 1000 * AU_PER_KM;
  const rhoMean = (mass * M_SUN) / ((4 / 3) * Math.PI * Math.pow(rEarth * R_EARTH, 3));
  const cc = centralConditions(mass, radiusAU / AU_PER_RSUN, 0, 1);
  // The virial temperature is meaningless for a cold solid body held up by
  // Coulomb forces; use the observed terrestrial scaling instead (Earth's core
  // is 5700 K, and central temperature rises roughly as M^0.6 across the
  // super-Earth range in interior models).
  const Tc = 5700 * Math.pow(Math.max(mEarth, 0.01), 0.6);
  const past = mEarth > peak.massEarth;

  const s = {
    type: 'planet', kind: 'rocky', mass, composition: comp,
    label: mEarth < 0.5 ? 'Rocky body' : (mEarth < 2 ? 'Terrestrial planet' : (mEarth < 10 ? 'Super-Earth' : 'Mega-Earth')),
    radiusAU, radiusKm: rEarth * R_EARTH / 1000, radiusEarth: rEarth,
    density: rhoMean, Tc, Pc: cc.Pc,
    maxRadiusEarth: peak.radiusEarth, maxRadiusMassEarth: peak.massEarth,
    verdict: past ? {
      state: VERDICT.degenerate,
      label: 'Degeneracy-limited',
      detail: `Past ${Math.round(peak.massEarth)} M⊕ (${(peak.massEarth * M_EARTH_SUN / M_JUP_SUN).toFixed(2)} M_J) electron degeneracy stiffens faster than gravity loads the planet, so adding mass now makes it SMALLER. The largest a solid planet of this composition can be is ${peak.radiusEarth.toFixed(2)} R⊕.`,
    } : {
      state: VERDICT.ok, label: c.label,
      detail: `${c.note} Radius follows Seager et al. (2007); it flattens out near ${Math.round(peak.massEarth)} M⊕ at ${peak.radiusEarth.toFixed(2)} R⊕ and turns over past it.`,
    },
    layers: rockyLayers(comp, rEarth, Tc),
  };
  return withRotation(s, mass, comp === 'iron' || comp === 'mercury' ? 'iron' : 'rocky', spinFrac);
}

function rockyLayers(comp, rEarth, Tc) {
  // Core mass fractions from the Seager composition; converted to radius
  // fractions with the usual ~2:1 core/mantle density ratio.
  const coreFrac = { iron: 1.0, mercury: 0.85, earth: 0.545, silicate: 0.0, ocean: 0.40, ice: 0.0 }[comp] ?? 0.545;
  const iceFrac  = { ocean: 0.72, ice: 1.0 }[comp] ?? 0;
  const L = [];
  if (coreFrac > 0) {
    L.push({ name: 'Inner core', r0: 0, r1: coreFrac * 0.35, T: Tc, rho: 13000,
             note: 'Solid iron–nickel. Freezes out of the liquid core as the planet cools.' });
    L.push({ name: 'Outer core', r0: coreFrac * 0.35, r1: coreFrac, T: Tc * 0.75, rho: 11000,
             note: 'Liquid iron. Convection here is what generates a magnetic field.' });
  }
  const mantleTop = iceFrac > 0 ? 1 - iceFrac * 0.45 : 0.985;
  L.push({ name: 'Lower mantle', r0: coreFrac, r1: coreFrac + (mantleTop - coreFrac) * 0.72, T: Tc * 0.55, rho: 5200,
           note: 'Bridgmanite — MgSiO₃ perovskite. The most abundant mineral in a rocky planet.' });
  L.push({ name: 'Upper mantle', r0: coreFrac + (mantleTop - coreFrac) * 0.72, r1: mantleTop, T: Tc * 0.28, rho: 3400,
           note: 'Olivine and pyroxene. Solid, but creeping — this is what drives plate tectonics.' });
  if (iceFrac > 0) {
    L.push({ name: 'High-pressure ice', r0: mantleTop, r1: 1 - iceFrac * 0.12, T: 900, rho: 1600,
             note: 'Ice VII and X — water frozen by pressure, not cold, at over 1000 K.' });
    L.push({ name: 'Ocean', r0: 1 - iceFrac * 0.12, r1: 0.997, T: 300, rho: 1000,
             note: 'Liquid water. On a world this size it can be hundreds of km deep.' });
  } else {
    L.push({ name: 'Crust', r0: mantleTop, r1: 0.997, T: 900, rho: 2900,
             note: 'The chilled, brittle outer skin. A few tenths of a percent of the radius.' });
  }
  L.push({ name: 'Atmosphere', r0: 0.997, r1: 1.0, T: 260, rho: 1.2,
           note: 'Thin enough to be a rounding error on the radius, and the only part anything lives in.' });
  return L;
}

// ---------------------------------------------------------------------------
function giantStructure(spec, mass, spinFrac) {
  // The SAME limit starStructure demotes on. It has to be, or the two disagree:
  // starStructure sends anything below hydrogenBurnLimit(Z) back down, and if
  // this promoted at a fixed 0.075 M☉ then at low Z every mass in between would
  // be reclassified up and down forever — structureOf recursing into itself
  // until the stack gives out, which is a hang, not a verdict.
  const hLimit = hydrogenBurnLimit(spec.Z ?? 0.014);
  if (mass >= hLimit) {
    return reclassified('star', spec, mass, spinFrac,
      `Above ${hLimit.toFixed(3)} M☉ the core sustains hydrogen fusion. This is a star.`);
  }
  const mJup = mass / M_JUP_SUN;
  const rJup = giantRadiusJup(mJup);
  const radiusAU = rJup * R_JUP / 1000 * AU_PER_KM;
  const rho = (mass * M_SUN) / ((4 / 3) * Math.PI * Math.pow(rJup * R_JUP, 3));
  const brown = mass >= LIMITS.deuteriumBurn;
  // Interior temperature: Jupiter's centre is ~20 000 K; brown dwarfs reach
  // ~3e6 K, enough for deuterium but not hydrogen.
  const Tc = brown ? 5e5 * Math.pow(mJup / 13, 0.9) : 20000 * Math.pow(Math.max(mJup, 0.05), 0.7);
  const past = mJup > GIANT_M0;

  const s = {
    type: 'gas-giant', kind: brown ? 'brown-dwarf' : 'giant', mass,
    label: brown ? 'Brown dwarf' : (mJup < 0.3 ? 'Ice giant' : 'Gas giant'),
    radiusAU, radiusKm: rJup * R_JUP / 1000, radiusJup: rJup,
    density: rho, Tc,
    teff: brown ? 1300 * Math.pow(mJup / 13, 0.5) : 0,
    verdict: brown ? {
      state: VERDICT.ignite, label: 'Deuterium burning',
      detail: `Above 13 M_J (${(LIMITS.deuteriumBurn).toFixed(4)} M☉) the centre passes 5×10⁵ K and burns its deuterium — briefly, since there is very little of it. Not a planet, and not a star: a brown dwarf, which will simply cool forever.`,
    } : past ? {
      state: VERDICT.degenerate, label: 'Degeneracy-limited',
      detail: `Past ~${GIANT_M0} M_J the hydrogen is degenerate and more mass compresses the planet rather than inflating it. This is why every gas giant and brown dwarf, over a factor of 80 in mass, is within about 30% of one Jupiter radius.`,
    } : { state: VERDICT.ok, label: 'Hydrogen–helium envelope',
      detail: 'Held up by ordinary gas pressure over a degenerate interior. Radius is nearly independent of mass here.' },
    layers: giantLayers(mJup, Tc, brown),
  };
  return withRotation(s, mass, 'giant', spinFrac);
}

function giantLayers(mJup, Tc, brown) {
  // The metallic-hydrogen transition sits near 0.8 R_J in Jupiter and moves
  // outward with mass; above ~2 M_J almost the whole interior is metallic.
  const met = Math.min(0.35 + 0.42 / Math.max(Math.pow(mJup, 0.35), 0.4), 0.90);
  return [
    { name: 'Rock/ice core', r0: 0, r1: 0.12, T: Tc, rho: 20000,
      note: brown ? 'If it formed like a star it may have none at all.' : 'A few to twenty Earth masses of heavy elements — the seed the envelope collapsed onto.' },
    { name: 'Metallic hydrogen', r0: 0.12, r1: met, T: Tc * 0.6, rho: 1000,
      note: 'Hydrogen compressed until it ionises and conducts like a metal. Jupiter\'s enormous magnetic field is generated here.' },
    { name: 'Molecular hydrogen', r0: met, r1: 0.985, T: 5000, rho: 300,
      note: 'Fluid H₂ and helium, convecting all the way up. There is no surface anywhere in this.' },
    { name: 'Cloud decks', r0: 0.985, r1: 1.0, T: brown ? 1300 : 165, rho: 0.2,
      note: brown ? 'Iron and silicate clouds, then methane as it cools.' : 'Ammonia over ammonium hydrosulphide over water. The banding is the top of the convection.' },
  ];
}

// ---------------------------------------------------------------------------
function starStructure(spec, mass, spinFrac) {
  const Z = spec.Z ?? 0.014;
  const hLimit = hydrogenBurnLimit(Z);
  if (mass < hLimit) {
    return reclassified(mass >= LIMITS.deuteriumBurn ? 'gas-giant' : 'planet', spec, mass, spinFrac,
      `Below ${hLimit.toFixed(3)} M☉ the core never reaches the 3 million K hydrogen needs. This cannot be a star.`);
  }

  const ph = phaseAt(spec.phase ?? 0.5);
  const L0 = baseLuminosity(mass, Z), R0 = baseRadiusSun(mass);
  const tMS = mainSequenceLifetime(mass, L0);

  // Post-main-sequence radii scale with mass, but far more weakly than the
  // main-sequence relation — a red giant is a red giant whether it started at
  // 1 or 5 M☉, because its size is set by the burning shell and the degenerate
  // core it sits on, not by how much envelope is draped over them.
  const post = ph.f > 1.0;
  const giantDamp = post ? Math.pow(mass, 0.25) : 1;
  // Above roughly 40 M☉ a star leaving the main sequence does NOT become a red
  // supergiant. Its own radiation-driven wind strips the hydrogen envelope off
  // faster than the envelope can expand, and what is left is a Wolf–Rayet star:
  // the bare helium (then carbon) core, a few solar radii across and 50 000 to
  // 200 000 K. That is the same Humphreys–Davidson limit again, seen from the
  // other side — the reason no cool supergiants are observed at high luminosity
  // is that the stars that would have been them have been skinned.
  const wolfRayet = post && mass > 40;
  let R = wolfRayet ? Math.max(R0 * 0.45, 1) : R0 * ph.rMul * giantDamp;

  // Post-main-sequence LUMINOSITY does not scale like the phase table says for
  // anything but a solar-mass star, and the reason is worth stating: after the
  // main sequence a star's luminosity is set by its helium CORE, not by its
  // envelope. For a low-mass star that core is degenerate and grows enormously
  // relative to a small starting luminosity — the Sun will brighten by a factor
  // of a few hundred on the red giant branch. For anything above ~3 M☉ the core
  // is already most of the star's luminosity on the main sequence and there is
  // far less room to grow: a 16.5 M☉ star goes from 2.5e4 L☉ on the ZAMS to
  // 1.3e5 as a supergiant, a factor of five, not three hundred.
  //
  // So the phase multiplier is faded out with mass toward a flat factor of ~5.
  // The crossover at 2.2 M☉ is where the helium core stops being degenerate,
  // which is the same place the helium flash stops happening.
  const POST_MASSIVE = 5;
  let L = L0 * ph.lMul;
  if (post && ph.lMul > 1) {
    const w = 1 / (1 + Math.pow(mass / 2.2, 3));
    L = L0 * (1 + (ph.lMul - 1) * w * w + (POST_MASSIVE - 1) * (1 - w));
  }

  // A star cannot be more luminous than Eddington and stay bound, and the
  // massive ones genuinely run into that ceiling once they leave the main
  // sequence: L_Edd = 4πGMc/κ, which for electron scattering is 3.2e4 L☉ per
  // solar mass. Rather than let the phase multipliers — which are calibrated on
  // the solar track — carry a 20 M☉ star to ten times its own Eddington
  // luminosity, cap it there and let the verdict say why. That cap IS the
  // physics of a luminous blue variable.
  const LEdd = eddingtonLuminosity(mass);
  if (L > 0.9 * LEdd) { L = 0.9 * LEdd; if (!wolfRayet) R = Math.max(R, R0 * ph.rMul); }

  // The Hayashi limit. A fully convective star cannot be cooler than about
  // 3000–3500 K and stay in hydrostatic equilibrium — to the right of that line
  // in the HR diagram there is no solution at all, which is why the coolest
  // supergiants all pile up against the same temperature regardless of mass.
  // Since L is fixed by the core, capping T from below caps R from above:
  //     R_max = √L · (T☉/T_Hayashi)²
  if (!wolfRayet) R = Math.min(R, Math.sqrt(L) * Math.pow(5772 / 3200, 2));

  // A MEASURED star overrides the model. sim/starcat.js carries real radii,
  // temperatures and luminosities, and for anything off the main sequence they
  // are not close: the track above returns 244 R☉ for a 16.5 M☉ supergiant and
  // Betelgeuse is 764. Where an observation exists it is the answer, and the
  // evolutionary track is only there to fill in what was not measured.
  if (spec.radiusSun > 0) R = spec.radiusSun;
  if (spec.luminosity > 0) L = spec.luminosity;
  const gamma = L / LEdd;

  const teff = spec.teff > 0 ? spec.teff : 5772 * Math.pow(L / (R * R), 0.25);
  const gd = gravityDarkenedTemps(teff, spinFrac);
  const radiusAU = R * AU_PER_RSUN;
  const cc = centralConditions(mass, R, ph.X, Z);
  const convectiveEnvelope = teff < 7000;
  const convectiveCore = mass > 1.2;

  const s = {
    type: 'star', kind: 'star', mass, Z,
    measured: !!(spec.radiusSun > 0 || spec.teff > 0),
    label: `${spectralFull(teff, luminosityClass(R, mass))} · ${ph.label}`,
    phase: ph, phaseF: ph.f,
    radiusAU, radiusSun: R, radiusKm: R * R_SUN / 1000,
    luminosity: L, teff, tPole: gd.tPole, tEq: gd.tEq, gdBeta: gd.beta,
    Tc: cc.Tc, Pc: cc.Pc, rhoC: cc.rhoC, density: cc.rhoMean, mu: cc.mu,
    X: ph.X, eddington: gamma, msLifetime: tMS,
    convectiveEnvelope, convectiveCore, wolfRayet,
    endState: endStateOf(mass),
    verdict: stellarVerdict(mass, gamma, ph),
    layers: starLayers(mass, ph, cc, convectiveCore, convectiveEnvelope),
  };
  return withRotation(s, mass, 'star', spinFrac);
}

function stellarVerdict(mass, gamma, ph) {
  // Order matters: the destruction mechanisms are checked before the merely
  // violent ones, because a 200 M☉ star's pair instability is not something its
  // Eddington factor gets a say in.

  if (mass > LIMITS.humphreysDavidson && mass < LIMITS.pairLo) {
    return {
      state: VERDICT.explode, label: 'Above the Humphreys–Davidson limit',
      detail: `No stable supergiant is observed above this line in the HR diagram, and no stable star of any kind above about ${LIMITS.eddingtonMass} M☉ — the Arches cluster and R136 both cut off there. It is not a selection effect: a star this massive drives a radiation wind that strips it faster than it evolves, so it sheds itself back down. This one is a luminous blue variable, and it will erupt.`,
    };
  }
  if (mass >= LIMITS.pairLo && mass <= LIMITS.pairHi) {
    return {
      state: VERDICT.explode, label: 'Pair instability',
      detail: `Between ${LIMITS.pairLo} and ${LIMITS.pairHi} M☉ the core gets hot enough that photons convert into electron–positron pairs. Making pairs costs pressure, the adiabatic index drops below 4/3, and the core collapses — into a runaway oxygen burn that unbinds the entire star. There is no remnant at all.`,
    };
  }
  if (mass > LIMITS.pairHi) {
    return {
      state: VERDICT.collapse, label: 'Direct collapse',
      detail: `Above ${LIMITS.pairHi} M☉ photodisintegration outruns the pair instability and the core implodes without any explosion. The star disappears into a black hole essentially whole.`,
    };
  }
  if (gamma > 0.85) {
    return {
      state: VERDICT.explode, label: 'Eddington-limited',
      detail: `L/L_Edd = ${gamma.toFixed(2)}. Radiation pressure on free electrons is now comparable to this star's own gravity, so its outer layers are barely bound at all. Real stars here — η Carinae and the luminous blue variables — do not sit quietly: they erupt, throwing off whole solar masses at a time. η Carinae shed 10–40 M☉ in a single event in the 1840s and survived it.`,
    };
  }
  if (ph.id === 'preSN') {
    return {
      state: VERDICT.collapse, label: 'Pre-collapse',
      detail: 'Silicon burning has built an iron core. Iron cannot release energy by fusing, so the core has no way to replace what it radiates: it will collapse in under a second.',
    };
  }
  if (gamma > 0.35) {
    return {
      state: VERDICT.ok, label: 'Near-Eddington',
      detail: `L/L_Edd = ${gamma.toFixed(2)}. Bound, but driving a heavy radiation-pressure wind — this star is losing mass fast enough to matter to its own evolution.`,
    };
  }
  return { state: VERDICT.ok, label: 'Hydrostatic equilibrium', detail: `${ph.note}` };
}

export function endStateOf(mass) {
  if (mass >= LIMITS.pairLo && mass <= LIMITS.pairHi) return { type: 'none', label: 'No remnant (pair-instability SN)' };
  if (mass > LIMITS.pairHi) return { type: 'bh', label: 'Black hole (direct collapse)', mass: mass * 0.9 };
  if (mass >= LIMITS.blackHoleMin) return { type: 'bh', label: 'Black hole', mass: 0.3 * Math.pow(mass, 0.85) };
  if (mass >= LIMITS.neutronStarMin) return { type: 'neutron', label: 'Neutron star', mass: 1.2 + 0.06 * (mass - 8) };
  // Initial–final mass relation for white dwarfs (Cummings et al. 2018):
  // roughly M_f = 0.08 M_i + 0.49 over 2–8 M☉.
  return { type: 'white-dwarf', label: 'White dwarf', mass: Math.min(0.08 * mass + 0.49, 1.35) };
}

function starLayers(mass, ph, cc, convCore, convEnv) {
  const L = [];
  const giant = ph.f > 1.15;
  const massive = mass > 8;

  if (giant && massive && ph.id === 'preSN') {
    // The onion. Each shell is burning the ash of the one outside it, each
    // stage runs hotter, faster and shorter than the last: for a 20 M☉ star,
    // hydrogen lasts 10 Myr, helium 1 Myr, carbon 300 yr, neon 8 months,
    // oxygen 4 months and silicon about a DAY.
    L.push({ name: 'Iron core', r0: 0, r1: 0.010, T: 8e9, rho: 1e10,
             note: 'Inert. Iron is the bottom of the binding-energy curve — fusing it costs energy instead of releasing it. This core is already collapsing.' });
    L.push({ name: 'Silicon shell', r0: 0.010, r1: 0.020, T: 3.5e9, rho: 1e8, note: 'Si → Fe. Lasts about a day.' });
    L.push({ name: 'Oxygen shell', r0: 0.020, r1: 0.038, T: 2.1e9, rho: 1e7, note: 'O → Si, S. A few months.' });
    L.push({ name: 'Neon shell', r0: 0.038, r1: 0.060, T: 1.4e9, rho: 4e6, note: 'Ne → O, Mg. Under a year.' });
    L.push({ name: 'Carbon shell', r0: 0.060, r1: 0.10, T: 8e8, rho: 2e5, note: 'C → Ne, Na, Mg. Centuries.' });
    L.push({ name: 'Helium shell', r0: 0.10, r1: 0.22, T: 2e8, rho: 1e3, note: '3 ⁴He → ¹²C. Hundreds of thousands of years.' });
    L.push({ name: 'Hydrogen envelope', r0: 0.22, r1: 0.995, T: 5e6, rho: 0.1,
             note: 'Almost all the volume and almost none of the action — convective, tenuous, and about to be thrown off.' });
    L.push({ name: 'Photosphere', r0: 0.995, r1: 1.0, T: 3500, rho: 1e-7, note: 'Where the star finally becomes transparent.' });
    return L;
  }

  if (giant) {
    const coreR = 0.008;
    L.push({ name: 'Degenerate helium core', r0: 0, r1: coreR, T: cc.Tc, rho: 1e6,
             note: 'Held up by electron degeneracy, not heat. About the size of Earth, and containing a third of the star.' });
    L.push({ name: 'Hydrogen-burning shell', r0: coreR, r1: coreR * 1.5, T: 4e7, rho: 1e4,
             note: 'A thin, ferociously hot shell. This — not the core — is what makes a red giant bright.' });
    L.push({ name: 'Convective envelope', r0: coreR * 1.5, r1: 0.99, T: 3e5, rho: 1e-4,
             note: 'Enormous, cool, and turning over in a handful of vast convection cells rather than millions of granules.' });
    L.push({ name: 'Photosphere', r0: 0.99, r1: 1.0, T: 3600, rho: 1e-8,
             note: 'So tenuous that it is closer to a laboratory vacuum than to air.' });
    return L;
  }

  // Main sequence. Which way round the convection goes is set by mass, and it
  // is a real and visible divide: stars above ~1.2 M☉ burn by the CNO cycle,
  // whose ferocious temperature sensitivity (ε ∝ T¹⁷) concentrates the energy
  // release so sharply that radiation cannot carry it and the CORE convects.
  // Below that, the pp chain (ε ∝ T⁴) is gentle enough for a radiative core,
  // and it is the cool opaque OUTER layers that convect instead.
  if (convCore) {
    L.push({ name: 'Convective core', r0: 0, r1: 0.20, T: cc.Tc, rho: cc.rhoC,
             note: 'CNO-cycle burning, ε ∝ T¹⁷. Too concentrated for radiation to carry, so it boils — and keeps mixing fresh hydrogen in, which extends the star\'s life.' });
    L.push({ name: 'Radiative envelope', r0: 0.20, r1: 0.99, T: cc.Tc * 0.1, rho: cc.rhoMean,
             note: 'Stably stratified. Photons random-walk outward; nothing overturns.' });
  } else {
    L.push({ name: 'Core', r0: 0, r1: 0.25, T: cc.Tc, rho: cc.rhoC,
             note: 'pp-chain burning, ε ∝ T⁴. Gentle enough that radiation alone can carry the energy away.' });
    L.push({ name: 'Radiative zone', r0: 0.25, r1: convEnv ? 0.71 : 0.99, T: cc.Tc * 0.15, rho: cc.rhoMean * 5,
             note: 'A photon takes of order 100 000 years to random-walk across this.' });
    if (convEnv) {
      L.push({ name: 'Convective zone', r0: 0.71, r1: 0.995, T: 2e6, rho: 1e-3,
               note: 'Opaque enough that convection beats radiation. The overturning here, sheared by rotation, is the star\'s magnetic dynamo.' });
    }
  }
  L.push({ name: 'Photosphere', r0: 0.995, r1: 1.0, T: 0, rho: 1e-4,
           note: 'A few hundred km thick and the only part you can see. Its granulation is the tops of the convection cells.' });
  L.push({ name: 'Chromosphere', r0: 1.0, r1: 1.004, T: 20000, rho: 1e-8, note: 'Thin, hot, and visible only as the pink rim in an eclipse.' });
  L.push({ name: 'Corona', r0: 1.004, r1: 1.06, T: 2e6, rho: 1e-12,
           note: 'A million kelvin above a 5800 K surface — magnetically heated, and still not fully explained.' });
  return L;
}

// ---------------------------------------------------------------------------
function neutronStructure(spec, mass, spinFrac) {
  const maxM = tovLimit(spinFrac);
  if (mass > maxM) {
    const s = holeStructure({ ...spec, type: 'bh' }, mass, spinFrac);
    s.verdict = {
      state: VERDICT.collapse, label: 'TOV limit exceeded',
      detail: `${mass.toFixed(2)} M☉ is past the ${maxM.toFixed(2)} M☉ this star can support${spinFrac > 0.02 ? ` (${LIMITS.tov} M☉ at rest, raised ${Math.round((maxM / LIMITS.tov - 1) * 100)}% by rotation)` : ''}. Neutron degeneracy and the strong force are the last sources of pressure there are — past them nothing stops the collapse, and it becomes a black hole.`,
    };
    s.wasNeutron = true;
    return s;
  }
  if (mass < 0.1) {
    return {
      type: 'neutron', kind: 'neutron', mass, radiusAU: neutronRadiusKm(0.1) * AU_PER_KM,
      label: 'Sub-minimum-mass', layers: [],
      verdict: { state: VERDICT.explode, label: 'Below the minimum mass',
        detail: 'Under about 0.1 M☉ a neutron star is not gravitationally bound against its own degeneracy pressure. It expands and disintegrates.' },
    };
  }

  const rKm = neutronRadiusKm(mass);
  const radiusAU = rKm * AU_PER_KM;
  const rs = schwarzschild(mass);
  const compactness = rs / radiusAU;              // 2GM/Rc² — how relativistic
  const rho = (mass * M_SUN) / ((4 / 3) * Math.PI * Math.pow(rKm * 1000, 3));
  const surfaceG = G_SI * mass * M_SUN / Math.pow(rKm * 1000, 2);
  const omegaC = breakupOmega(mass, radiusAU);
  const periodMs = spinFrac > 0 ? 2 * Math.PI / (spinFrac * omegaC) * 1000 : Infinity;

  const s = {
    type: 'neutron', kind: 'neutron', mass,
    label: periodMs < 30 ? 'Millisecond pulsar' : 'Neutron star',
    radiusAU, radiusKm: rKm, density: rho, surfaceGravity: surfaceG,
    compactness, tovMax: maxM, spinPeriodMs: periodMs,
    // Redshift of light leaving the surface: 1/√(1−r_s/R) − 1. At 0.3
    // compactness this is ~19%, big enough to see in the spectrum.
    redshift: 1 / Math.sqrt(Math.max(1 - compactness, 1e-3)) - 1,
    teff: 6e5,
    verdict: mass > maxM * 0.95 ? {
      state: VERDICT.ok, label: 'Near the TOV limit',
      detail: `Within 5% of the ${maxM.toFixed(2)} M☉ maximum. A little more mass — or losing this spin — and it collapses.`,
    } : {
      state: VERDICT.ok, label: 'Neutron degeneracy + strong force',
      detail: `Mean density ${(rho / 1e17).toFixed(2)}×10¹⁷ kg/m³ — a sugar cube of this weighs as much as a mountain. Surface gravity is ${(surfaceG / 9.81).toExponential(1)} g, and light leaving the surface is redshifted by ${((1 / Math.sqrt(Math.max(1 - compactness, 1e-3)) - 1) * 100).toFixed(0)}%.`,
    },
    layers: neutronLayers(rKm),
  };
  return withRotation(s, mass, 'neutron', spinFrac);
}

function neutronLayers(rKm) {
  return [
    { name: 'Inner core', r0: 0, r1: 0.45, T: 1e8, rho: 1.2e18,
      note: 'Above a few times nuclear density, and genuinely unknown. Hyperons? A deconfined quark–gluon core? Which it is decides the TOV limit.' },
    { name: 'Outer core', r0: 0.45, r1: 0.90, T: 2e8, rho: 5e17,
      note: 'Superfluid neutrons with a few percent superconducting protons and electrons. Frictionless — and the sudden unpinning of its vortices is what makes a pulsar glitch.' },
    { name: 'Inner crust', r0: 0.90, r1: 0.975, T: 5e8, rho: 1e17,
      note: 'Past neutron drip. Nuclei dissolve into "nuclear pasta" — sheets and rods of nuclear matter, the stiffest material that exists.' },
    { name: 'Outer crust', r0: 0.975, r1: 0.998, T: 1e8, rho: 1e11,
      note: 'A crystalline lattice of iron-group nuclei in a degenerate electron sea. About a kilometre thick, and 10¹⁸ times stronger than steel.' },
    { name: 'Atmosphere', r0: 0.998, r1: 1.0, T: 1e6, rho: 1e2,
      note: 'A few centimetres of carbon or hydrogen plasma. It sets the X-ray spectrum, which is how the radius gets measured at all.' },
  ];
}

// ---------------------------------------------------------------------------
function whiteDwarfStructure(spec, mass, spinFrac) {
  if (mass >= LIMITS.chandrasekhar) {
    return {
      type: 'white-dwarf', kind: 'wd', mass, radiusAU: 0,
      label: 'Chandrasekhar mass exceeded', layers: [],
      verdict: {
        state: VERDICT.explode, label: 'Type Ia supernova',
        detail: `Past ${LIMITS.chandrasekhar} M☉ the electrons are relativistic and degeneracy pressure stops growing with density — there is no equilibrium left. In practice the star ignites its carbon first and detonates completely as a Type Ia supernova, leaving nothing. Because that always happens at the same mass, they all have nearly the same brightness, which is how the expansion of the universe was measured.`,
      },
    };
  }
  const R = whiteDwarfRadiusSun(mass);
  const radiusAU = R * AU_PER_RSUN;
  const teff = spec.teff ?? 12000;
  const rho = (mass * M_SUN) / ((4 / 3) * Math.PI * Math.pow(R * R_SUN, 3));
  const s = {
    type: 'white-dwarf', kind: 'wd', mass,
    label: 'White dwarf', radiusAU, radiusSun: R, radiusKm: R * R_SUN / 1000,
    density: rho, teff, Tc: 1e7,
    luminosity: 4 * Math.PI * Math.pow(R * R_SUN, 2) * SIGMA * Math.pow(teff, 4) / L_SUN,
    verdict: {
      state: mass > LIMITS.chandrasekhar * 0.93 ? VERDICT.ok : VERDICT.degenerate,
      label: 'Electron degeneracy',
      detail: `Earth-sized and star-massed: mean density ${(rho / 1e9).toFixed(2)}×10⁹ kg/m³. Because degeneracy pressure does not care about temperature, a white dwarf gets SMALLER as it gets heavier — R ∝ M^−⅓ — and shrinks to nothing at the Chandrasekhar mass of ${LIMITS.chandrasekhar} M☉.`,
    },
    layers: [
      { name: 'C/O core', r0: 0, r1: 0.98, T: 1e7, rho: rho * 1.4,
        note: 'Carbon and oxygen ash, degenerate throughout. It cools by conduction and eventually crystallises — a diamond the size of a planet.' },
      { name: 'Helium layer', r0: 0.98, r1: 0.995, T: 1e6, rho: 1e5, note: 'About 1% of the mass, and opaque enough to slow the cooling by billions of years.' },
      { name: 'Hydrogen skin', r0: 0.995, r1: 1.0, T: teff, rho: 1e2, note: 'A hundred metres of hydrogen, 10⁻⁴ of the mass. It is all you can see.' },
    ],
  };
  return withRotation(s, mass, 'wd', spinFrac);
}

// ---------------------------------------------------------------------------
// A black hole has no interior to draw, which is exactly why the cross-section
// is interesting: everything labelled here is a property of the SPACETIME
// outside it, and every one of them is a real, locatable surface.
function holeStructure(spec, mass, spinFrac) {
  const a = Math.min(spinFrac, 0.998);            // dimensionless Kerr spin a/M
  const rsAU = spec.rs ?? schwarzschild(mass);
  const M = rsAU / 2;                             // geometric mass, AU
  // Kerr horizon: r₊ = M + √(M² − a²M²)
  const rPlus = M * (1 + Math.sqrt(Math.max(1 - a * a, 0)));
  // Prograde ISCO (Bardeen, Press & Teukolsky 1972).
  const z1 = 1 + Math.cbrt(1 - a * a) * (Math.cbrt(1 + a) + Math.cbrt(1 - a));
  const z2 = Math.sqrt(3 * a * a + z1 * z1);
  const rIsco = M * (3 + z2 - Math.sqrt(Math.max((3 - z1) * (3 + z1 + 2 * z2), 0)));
  // Hawking temperature and evaporation time, for the readout.
  const tHawk = 6.169e-8 / mass;                  // K
  const tEvap = 2.1e67 * Math.pow(mass, 3);       // yr

  return {
    type: 'bh', kind: 'bh', mass,
    label: a > 0.1 ? `Kerr black hole (a* = ${a.toFixed(2)})` : 'Schwarzschild black hole',
    radiusAU: rPlus, rs: rsAU, spin: a,
    horizonAU: rPlus, photonSphereAU: a > 0.01 ? 2 * M * (1 + Math.cos((2 / 3) * Math.acos(-a))) : 1.5 * rsAU,
    shadowAU: Math.sqrt(27) / 2 * M * 2 * 0.5 + Math.sqrt(27) * M / 2,   // ≈ √27 M
    iscoAU: rIsco, ergoAU: a > 0.01 ? 2 * M : rsAU,
    hawkingK: tHawk, evaporationYr: tEvap,
    teff: 2.0e7 * Math.pow(Math.max(mass, 0.1), -0.25),
    verdict: {
      state: VERDICT.ok, label: 'No equilibrium',
      detail: `There is no pressure here at all — nothing is holding anything up. The Hawking temperature is ${tHawk.toExponential(2)} K, far below the 2.7 K microwave background, so this hole absorbs more than it radiates and will keep growing for another 10^${Math.round(Math.log10(tEvap))} years before it can even begin to evaporate.`,
    },
    layers: holeLayers(M, rPlus, rIsco, a),
  };
}

function holeLayers(M, rPlus, rIsco, a) {
  // Normalised against the ISCO, which is the outermost thing drawn.
  const N = rIsco;
  const f = r => Math.min(r / N, 1);
  const L = [
    { name: 'Singularity', r0: 0, r1: f(M * 0.06), T: Infinity, rho: Infinity,
      note: a > 0.01
        ? 'A ring, not a point — a rotating hole\'s singularity is a circle of radius aM in the equatorial plane. General relativity stops predicting anything here, which is a statement about the theory, not about the place.'
        : 'A point of infinite density where the equations stop making sense. Everything that falls in reaches it in finite proper time.' },
    { name: 'Interior', r0: f(M * 0.06), r1: f(rPlus), T: 0, rho: 0,
      note: 'Inside the horizon the radial direction becomes timelike: falling inward stops being a direction you can choose and becomes a direction in time, like tomorrow. Nothing here is drawn from observation, because nothing here can be observed.' },
    { name: 'Event horizon', r0: f(rPlus), r1: f(rPlus * 1.02), T: 0, rho: 0,
      note: `r₊ = ${(rPlus * 2).toFixed(4)} AU in Schwarzschild terms. Not a surface — a one-way boundary. Falling through it, you notice nothing at all.` },
  ];
  if (a > 0.01) {
    L.push({ name: 'Ergosphere', r0: f(rPlus * 1.02), r1: f(2 * M), T: 0, rho: 0,
      note: 'Frame dragging is so strong here that standing still is impossible — you must rotate with the hole. Energy can be extracted from this region (the Penrose process), which is where a quasar\'s jets get their power.' });
  }
  L.push({ name: 'Photon sphere', r0: f(1.5 * 2 * M) - 0.004, r1: f(1.5 * 2 * M) + 0.004, T: 0, rho: 0,
    note: 'r = 1.5 r_s, where light orbits. Unstable — a photon here needs only a nudge to fall in or escape. Its lensed image is the bright ring you actually see, at √27·M ≈ 2.6 r_s.' });
  L.push({ name: 'ISCO', r0: f(rIsco) - 0.004, r1: f(rIsco), T: 0, rho: 0,
    note: `The innermost stable circular orbit, at ${(rIsco / M).toFixed(2)} M. Inside it there are no stable orbits at all, so an accretion disc simply ends here and its inner edge plunges. This is what sets a disc's peak temperature.` });
  return L;
}

// ---------------------------------------------------------------------------
// A mass that crossed a threshold: rebuild it as what it actually is, and carry
// the explanation with it.
function reclassified(newType, spec, mass, spinFrac, why) {
  const s = structureOf({ ...spec, type: newType, mass, spinFrac });
  s.reclassifiedFrom = spec.type;
  s.verdict = { state: VERDICT.ignite, label: 'Reclassified', detail: why };
  return s;
}

// ---------------------------------------------------------------------------
export function spectralType(teff) {
  if (teff >= 33000) return 'O';
  if (teff >= 10000) return 'B';
  if (teff >= 7300)  return 'A';
  if (teff >= 6000)  return 'F';
  if (teff >= 5300)  return 'G';
  if (teff >= 3900)  return 'K';
  if (teff >= 2400)  return 'M';
  return 'L';
}

// Full MK type with a digit, e.g. "G2". The subdivisions are linear in
// log Teff within each class, which is close enough to the real scale.
export function spectralFull(teff, luminosityClass = 'V') {
  const EDGES = [['O', 33000, 55000], ['B', 10000, 33000], ['A', 7300, 10000],
                 ['F', 6000, 7300], ['G', 5300, 6000], ['K', 3900, 5300], ['M', 2400, 3900]];
  for (const [letter, lo, hi] of EDGES) {
    if (teff >= lo && teff < hi) {
      const d = Math.min(9, Math.max(0, Math.floor(10 * (Math.log10(hi) - Math.log10(teff)) / (Math.log10(hi) - Math.log10(lo)))));
      return `${letter}${d}${luminosityClass}`;
    }
  }
  return teff >= 55000 ? 'O2' + luminosityClass : 'L' + luminosityClass;
}

// Luminosity class from radius, which is what the class actually encodes.
export function luminosityClass(radiusSun_, massSun) {
  const ms = zamsRadiusSun(massSun);
  const r = radiusSun_ / Math.max(ms, 1e-6);
  if (r > 100) return 'Ia';
  if (r > 40)  return 'Ib';
  if (r > 12)  return 'II';
  if (r > 4)   return 'III';
  if (r > 1.9) return 'IV';
  return 'V';
}
