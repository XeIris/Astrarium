# Secular evolution

Settings › Sim › Secular evolution (on by default, `secular=0` on the command line
turns it off). Four slow processes act on the orrery's bodies: tides, stellar winds,
Roche-lobe overflow and stellar ageing. The first three change positions, velocities
and masses, so they run inside the N-body kernel, after each accepted sub-step, in
`Physics.apply_secular` and its copy in `native/astrarium_native.c`. The two copies
perform the same operations in the same order, and `tools/nbodycheck.gd`'s
`secular` case compares them. Ageing changes only a star's structure, so it runs once
per frame in `main._step_secular`. `tools/secularcheck.gd` checks the physics and
`tools/realismcheck.tscn` checks the events.

The kernel's inputs come from `Structure.secular_terms`, through
`Derive._secular_inputs`. The spin `Ω` is integrated state: it starts at the body's
own rate and then belongs to the kernel.

## Tides

The model is Hut's (1981) constant-time-lag equilibrium tide, using only its
dissipative part. It assumes each body's spin is parallel to the normal of the orbit
in question. Body *i*, with radius R, Love number k₂, time lag Δt and spin Ω, raises
a tide that exerts this force on its companion *j*:

    F = −(3/2) k₂ G m_j² R⁵ Δt / r⁷ · [ 3 (ṙ/r) r̂ − (Ω − θ̇) θ̂ ],      θ̇ = |r × v|/r²

Hut's eq. 9 writes this with the apsidal constant k = k₂/2. The static bulge's
conservative term (the apsidal precession it drives) is left out. The opposite force
acts on *i*. The tangential part's torque comes out of *i*'s spin:
`I dΩ/dt = −r F·θ̂`, with `I = gyr · m R²`. The orbit plus the spin therefore keep
their angular momentum to rounding error: `secularcheck` measures 3 × 10⁻¹⁵ over 40
orbits with 1PN off, since 1PN conserves its own angular momentum rather than the
Newtonian one. The pair interacts only while `r < 200 R`. At 200 R the force is
already 10⁻¹⁶ of the force at contact.

The kick is explicit, so it saturates: the radial part can remove at most half of ṙ
in one step, and the spin–orbit slip `Ω − θ̇` can shrink by at most half. A
saturated tide depends on the timestep, as the GW drag does. With real lags it never
saturates outside contact.

**Check.** A hot Jupiter at a = 0.05 AU and e = 0.2 is given a spin that is
pseudo-synchronous (Hut's eq. 42, Ω/n = 1.242) and heavy enough to stay that way.
Its lag is raised so it circularises in ~2000 orbits. Over 40 orbits the measured
de/dt and da/dt match Hut's orbit-averaged eqs. 9–10 to 0.1% and 0.2%. A spin that
starts at 3n decays as `exp(−t/t_lock)`, with `t_lock` taken from
`Structure.tidal_timescales`, to 0.01%.

**Constants** (`Structure.TIDES`; a spec's `k2` and `tideLagS` win):

| body | k₂ | Δt | I/MR² |
|---|---|---|---|
| rocky | uniform elastic sphere, 1.5/(1 + 19μ/2ρgR), μ = 65 GPa: Moon 0.023 (GRAIL 0.024), Mars 0.15 (0.17) | 36 s: Mars, Q = 88 at Phobos's tidal frequency (Jacobson & Lainey 2014), from Q⁻¹ = 2\|Ω − n\|Δt | 0.35 |
| Earth (stated) | 0.299 (Lambeck 1980) | 638 s, the ocean tide that recedes the Moon by 3.8 cm/yr (Neron de Surgy & Laskar 1997) | 0.35 |
| giant | 0.52, n = 1 polytrope (Jupiter 0.565, Juno) | 0.10 s: Jupiter's Q = 3.6 × 10⁴ at Io (Lainey et al. 2009) | 0.254 |
| star | 0.029, n = 3 polytrope; 0.287, n = 1.5, below 0.35 M☉ | k₂Δt = 7.6 × 10⁻⁴ s, Zahn's (1977) convective-envelope tide for the Sun; ×10⁻³ for a radiative envelope | 0.076; 0.205 |

White dwarfs, neutron stars and holes raise no tide in this model. Their Love numbers
matter only in the last orbits before contact, where 1PN and the contact rules
already govern. A body whose rotation is unknown (a generic planet with no
`dayLength`) raises no tide, because its spin would be a guess.

**Readouts.** In the cross-section inspector, `main.secular_facts` gives Ω/n, the
despin e-folding time `I a⁶ / ((3/2) k₂ G m_j² R⁵ Δt)` and the circularisation time
`1/t = (21/4) k₂ G Δt m_j (m + m_j) R⁵ / (m a⁸)`. The second is Hut's eq. 10 at
e → 0 with the spin synchronous, where the bracket is 7/18 of its e = 0 value. Both
are measured against the tidal partner with the largest M/d³.

## Winds

Each sub-step takes `Ṁ dt` (at most 10⁻³ of the mass) from the star. The velocity is
unchanged, which is an isotropic wind. Orbits then widen adiabatically by themselves:
`secularcheck` blows 20% off a star over 1000 orbits of a planet, and `a·M` holds to
2 × 10⁻⁸ while the orbit stays circular to 10⁻⁴.

`Structure.wind_mass_loss`:

- above 27.5 kK: Vink et al. (2001) eq. 24 (v∞/v_esc = 2.6); 12.5–22.5 kK, and down
  to 12.5 kK here: eq. 25 (v∞/v_esc = 1.3). The bistability jump sits between them.
- Wolf–Rayet: Nugis & Lamers (2000) with Y = 1.
- evolved cool stars (past TAMS): Reimers (1975), `4 × 10⁻¹³ η LR/M` with η = 0.477
  (McDonald & Zijlstra 2015).
- cool dwarfs: the Sun's 2 × 10⁻¹⁴ M☉/yr scaled by surface area. Wood et al. (2005)
  measure a spread of about ten around this, tied to activity, which the model does
  not follow.

Momentum leaves with the wind, so a star's wind changes the system's momentum, as it
should.

## Roche-lobe overflow

Every star is a potential donor. The donor's partner is the body with the largest
M/d³. The lobe radius is Eggleton's (1983) `R_L/r = 0.49 q^⅔ / (0.6 q^⅔ + ln(1 + q^⅓))`
with q = M_donor/M_accretor, measured at the instantaneous separation r, so an
eccentric orbit overflows near periastron. When R > R_L, mass moves at Hurley, Tout
& Pols's (2002) eq. 58 rate, `Ṁ = 3 × 10⁻⁶ min(M, 5)² [ln(R/R_L)]³ M☉/yr`, capped at
10⁻³ of the donor per step. The transferred mass carries the donor's velocity into
the accretor, an inelastic merge of momenta. Mass, momentum and orbital angular
momentum are therefore kept, and the orbit's response to the changing mass ratio
emerges. The stream's own angular momentum through L₁ and any mass lost from the
system are not modelled.

A star passing close to a hole overflows on the way in. In `realismcheck`'s tidal
disruption that moves ~10⁻¹⁰ M☉ before the star is torn apart.

## Novae and accretion-driven Type Ia

The kernel reports what each body gained. `main._step_secular` then decides its fate
with `Structure.accretion_regime`. The critical rate is
`Ṁ_cr = 9 × 10⁻⁷ (M − 0.5) M☉/yr` (Nomoto et al. 2007; Hachisu et al. 1999):

- **nova**, below 0.4 Ṁ_cr: the hydrogen accumulates. At the ignition mass
  `Δm = 4πR⁴ P_ign / GM`, with `P_ign = 2 × 10¹⁹ dyn/cm²` inside the 10¹⁸–10²⁰ of
  Yaron et al. (2005), `check_structural_limits` sets off a nova. The envelope is
  thrown off (retention zero, as for most classical novae), with a flash and a toast.
  At 1 M☉ the ignition mass is 8.5 × 10⁻⁵ M☉.
- **steady**, from 0.4 to 1 × Ṁ_cr: the hydrogen burns as it lands and the dwarf
  grows.
- **wind**, above Ṁ_cr: the dwarf grows at Ṁ_cr and an optically thick wind blows
  the rest away.

A dwarf that grows to the Chandrasekhar mass detonates through the existing
structural limit. The hard limits (Chandrasekhar, TOV) are tested on every mass
change. The full structure is re-derived once the mass has moved by 10⁻⁹ or the age
by 10⁻⁴ in phase.

## Ageing

Each frame a star advances along its track by the simulated time, through
`Structure.phase_after`. `LIFE_CLOCK` maps the phase f to the time since ZAMS in
main-sequence lifetimes: f is linear on the main sequence, then follows MIST's
1 M☉ track (Choi et al. 2016): TAMS at 1.0, the RGB tip at 1.22, the end of core
helium burning at 1.232 and the end of the AGB at 1.234. Before ZAMS there is a
Kelvin–Helmholtz contraction of 0.3% of the main sequence. The clock does not depend
on mass, so a massive star's post-main-sequence phases are only roughly timed. A
star whose phase reaches 2.0 ends through `core_collapse`, leaving what
`end_state_of` gives.

## Not modelled

The conservative tidal bulge; spin axes that are not aligned with the orbit
(obliquity tides); the dynamical tide's frequency dependence; magnetic braking;
mass and angular momentum lost from a binary in overflow; common envelopes; and the
change in Ṁ as a donor's radius responds to losing mass within one frame (the
radius is re-derived each frame).
