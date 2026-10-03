# What a body is: `sim/structure.gd`

`structure_of(spec)` answers what holds a body up, how big that makes it, what
its interior looks like, and where the support fails. The interesting
behaviour is at the thresholds, and all of them come from pressure against
gravity:

- a rocky planet stops growing near 300 M⊕ and then shrinks (electron degeneracy)
- 13 M_J lights deuterium (brown dwarf); ~0.075 M☉ lights hydrogen (star)
- a star spun past its Keplerian limit sheds its equator
- a neutron star past the TOV mass collapses
- a star past ~150 M☉ is pushed apart by its own radiation

Public functions use AU / M☉ / yr; interior equations of state work in SI.

## Supported requests and physical events

The stage preflights complete spawn, edit and preset requests before changing
live bodies. Mass must be finite and positive; physical spin must be finite and
nonnegative. Non-black-hole rotation above the model's mass-shedding rate is
unsupported. The near-limit warning at fractions 0.999–1 is still allowed;
this equilibrium model does not evolve shed material. Neutron `spinHz` takes
precedence over `spinFrac` when checking rotational support.

`Structure.LIMITS.neutronMin` is the stand-in model's lower mass domain,
0.1 M☉. It is not a universal physical destruction threshold. Published
[cold equilibrium calculations](https://arxiv.org/abs/astro-ph/0201434) give
EOS-dependent minima and show that rotation changes them. Likewise, the
[mass-shedding collapse study](https://arxiv.org/abs/astro-ph/0205091) starts
with a star already unstable to radial collapse; rotation alone does not justify
deleting it. Unsupported requests are rejected rather than assigned a made-up
explosion or mass-loss law.

TOV collapse, Chandrasekhar detonation and reclassification remain supported
events. A stellar radiation/evolution warning is not automatically an immediate
destruction instruction. Failed edits preserve the body and restore its controls;
an invalid body specification rejects the whole preset before the live scenario
is cleared. This input gate does not establish stability of every accepted body.

Authored positions and velocities must have exactly three finite numeric components;
contact distances and softening must be finite and nonnegative AU. Zero softening
selects the ordinary-pair default. Black-hole structures retain the actual mass,
including below the ordinary structure fit's lower clamp, and reject horizon or
isolated evaporation scales that underflow or overflow. This is a numerical guard,
not a claimed physical lower mass boundary.

The black-hole card compares its modeled Hawking temperature with the current
microwave background rather than assuming every hole is colder. Hot isolated holes
can lose energy through thermal emission; evaporation is not integrated. See
[Hawking's original calculation](https://authors.library.caltech.edu/records/2wsvj-qrt68).

## Solid planets (Seager et al. 2007)

Every solid composition collapses onto one curve in scaled variables, because
each EOS fits a modified polytrope ρ = ρ₀ + cPⁿ (n ≈ 0.51–0.55):

    log₁₀ Rs = k₁ + ⅓ log₁₀ Ms − k₂ Ms^k₃,   Ms = M/m₁, Rs = R/r₁

The ⅓ term is the incompressible limit; −k₂Ms^k₃ is self-compression. dlogR/dlogM
reaches zero at k₂k₃ Ms^k₃ = 1/(3 ln10), so Ms ≈ 47, M ≈ 300 M⊕ ≈ 0.95 M_J: a
rocky planet's largest size is about 3 R⊕. The fit is quoted to Ms ≲ 40, so the
turnover's position is good to perhaps 20%, but the turnover itself is
degeneracy and every full EOS calculation finds it (Zapolsky & Salpeter 1969
onward). Check: the Earth-like row gives 0.970 R⊕ at 1 M⊕.

## Giants and brown dwarfs

    R ∝ M^⅓ / (1 + (M/M₀)^⅔)

This is R ∝ M^⅓ while the gas is classical and M^−⅓ once fully degenerate,
peaking at M₀. Zapolsky & Salpeter put the peak near 3–4 M_J at ~1.1 R_J. Every
object from Saturn to the hydrogen-burning limit (a factor of 80 in mass) sits
within ~30% of one Jupiter radius. Deuterium burning's few-percent radius effect
is not modelled.

## Degenerate stars

White dwarfs follow Nauenberg (1972):
R = 0.0126 R☉ · (μ_e/2)^−5/3 · (M/M_Ch)^−1/3 · [1 − (M/M_Ch)^4/3]^½, giving
0.0084 R☉ at 1.0 M☉ (Sirius B, measured 0.0084).

Neutron stars use a smooth stand-in for modern stiff EOSs: flat at 11.5–12.5 km
over the observed masses, steepening near TOV (NICER: J0030 and J0740 near
12.4 km). Rigid rotation raises TOV by up to ~20%.

## Stellar evolution

On the main sequence, fusion raises the core's mean molecular weight,
μ = 4/(3 + 5X − Z), from 0.62 to 1.34, so the star brightens and swells (the
fits give L × 2.2 and R × 1.6 across the main sequence). Post-main-sequence
phases aren't homologous and are entered as calibrated stops (`PHASES`). The
baseline is mid-main-sequence, so `f = 0.5` returns today's Sun exactly. The ZAMS
Sun was 0.70 L☉ and 0.90 R☉.

After the main sequence:

- Radii scale weakly with mass (∝ M^0.25), since the shell and core set a
  giant's size.
- Above ~40 M☉ the wind strips the envelope and the star is a Wolf–Rayet.
- Luminosity is set by the helium core. The phase multiplier fades toward a
  flat ×5 above ~2.2 M☉, where the core stops being degenerate (a 16.5 M☉ star
  goes from 2.5e4 L☉ to 1.3e5 L☉).
- L is capped at 0.9 L_Edd (3.2e4 L☉ per M☉); that cap is the luminous blue
  variable.
- The Hayashi limit caps R at √L · (T☉/3200 K)².
- Measured values override all of this (the track gives 244 R☉ for a
  16.5 M☉ supergiant; Betelgeuse is 764).

Above 20 M☉ the mass–luminosity slope falls from 3.5 toward 1.4, so L is
interpolated through Geneva-grid anchors (Ekström et al. 2012; Yusof et al.
2013).

## Rotation

Planets are only mildly centrally condensed, so first-order Darwin–Radau
applies:

    f = 5q / (2[1 + ((5/2)(1 − (3/2)λ))²]),   q = Ω²R³/GM,   λ = C/MR²

It gives 1/300 for Earth (measured 1/298.25) and 0.0656 for Jupiter (0.0649),
from independently measured λ. Being first order, it is saturated onto
f_max·tanh(f/f_max) (Maclaurin turnover ~0.42; neutron stars 1/3).

Stars are strongly condensed, so the Roche model applies: the surface is an
equipotential of Φ = −GM/r − ½Ω²r²sin²θ, i.e. 1/x + (4/27)ω²x²sin²θ = 1 with
x = R(θ)/R_pole. At break-up R_eq/R_pole = 3/2 for any star (Achernar, 1.35, is
near it), so Ω_crit = √(8GM/27R_pole³), 0.544 of the naive value.

Gravity darkening (von Zeipel 1924): T_eff ∝ g_eff^β, β = ¼ radiative and ≈ 0.08
convective (Lucy 1967, below ~7000 K). β is reduced at high spin, after Espinosa
Lara & Rieutord (2011). Vega: pole ~10 070 K, equator ~8 910 K. The mean T is
held in the Stefan–Boltzmann sense.

## Central conditions

The virial estimates P_c ~ (3/8π)GM²/R⁴ and T_c ~ ½μm_H GM/(kR) are right in
form and low by a fixed factor. They are calibrated once on the standard solar
model at X_c ≈ 0.38 (T_c = 1.571e7 K, P_c = 2.34e16 Pa, ρ_c/ρ̄ = 115).

## Granulation

A convection cell is about a pressure scale height wide:
H_p/R = kTR/(μ m_H GM). The Sun gets 4.2e-4 (~2400 cells across); Betelgeuse
gets 0.012, a handful of huge cells (Schwarzschild 1975; Chiavassa et al.; VLTI
and ALMA images).

## Drawn surface brightness

σT⁴ spans 1500:1 across the sim's stars, but the orbit view has no auto-exposure,
so the raw ratio renders a red supergiant brown-grey. What is drawn is the eye's
response (Stevens' power law, L^⅓): (T/T☉)^(4/3), capped at 12 where the bloom
kernel runs out.
