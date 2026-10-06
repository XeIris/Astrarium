# Scenario design notes

Code: `sim/presets.gd`, `sim/edupresets.gd`. [web/README.md](../web/README.md)
describes the scenarios for readers; this file keeps the design constraints and
measurements behind them.

## Trisolaris (hierarchical initial conditions)

The flagship starts with a Keplerian hierarchy:

- Alpha (1.20 M☉) and Beta (0.85 M☉): a 0.35 AU pair, 53-day period.
- Trisolaris: a coplanar 1.80 AU circumbinary orbit, eccentricity **0.20**,
  initially at apoapsis. Initial periapsis/apoapsis are 1.44/2.16 AU.
- Gamma (2.00 M☉): a 22 AU orbit with e = 0.35, inclination 25° and a
  51.3-year Kepler period.

Batch 14 replaces only the world's former eccentricity of 0.42. The old orbit
passed an inappropriate circular-planet screening argument but breached the
declared extent bound at 56 332.5 years. The
[Holman–Wiegert study](https://arxiv.org/pdf/astro-ph/9809315) initializes
circular, coplanar test particles around an isolated binary; its roughly
0.852 AU cutoff does not validate an eccentric world perturbed by Gamma.

The candidate e = 0.20 was chosen before measuring its lifetime. The coplanar,
test-particle Mardling–Aarseth screening expression,
`a_crit = 2.8 a_bin (1 + e_world)^0.4 / (1 - e_world)^1.2`, gives 2.168 AU
for the former e = 0.42 and 1.378 AU for e = 0.20. The 1.80 AU candidate has
about 31% initial semimajor-axis margin under that screen. These are design
estimates, not proof: published eccentricity-aware criteria disagree and do not
include this complete four-body softened model. See the
[comparison and Eq. 11](https://academic.oup.com/mnras/article/532/2/1580/7700715)
and [Adelbert's single-planet controls](https://arxiv.org/abs/2310.07575).

### Bounded survival and numerical accuracy

All **nine predeclared 60 000-year runs** pass the original limits: four live
bodies, no mergers, sampled world/binary distance below 10 AU, Gamma below
100 AU, relative total-energy drift below 1e-6 and momentum error below
1e-7 M☉ AU/year. Stars, orbit sizes, Gamma's orbit, authored cap and bounds
are unchanged. The check now accumulates accepted time with the production
compensated clock; every passing run reaches 60 000 years with zero remainder.

| maximum step (years) | maximum sampled world distance (AU) | maximum relative energy drift |
|---:|---:|---:|
| 0.0004, authored | 2.279197 | 5.19544e-8 |
| 0.0002 | 2.268883 | 1.04481e-8 |
| 0.0001 | 2.275204 | 2.49480e-9 |
| 0.00005 | 2.286518 | 6.33114e-10 |

The remaining five runs rotate the world position and velocity around the inner
binary barycenter by +1e-6, −1e-6, π/2, π and 3π/2 radians at the authored cap.
These change apsidal orientation rather than anomaly on a fixed ellipse.
Across all nine runs, sampled world distance stays below **2.287 AU** and Gamma
below **29.700 AU**. Maximum inferred world eccentricity is **0.2984** and
minimum inferred periapsis **1.2793 AU**. This sparse study supports survival
under the tested settings, not indefinite stability or statistical lifetime
estimates. Sampled extrema need not capture every closest approach.

A separate 20-year refinement uses h, h/2, h/4 and h/8 against h/32. All-body
position RMS errors are 0.0106542, 0.00271354, 0.000670718 and 0.000159987 AU;
velocity RMS errors are 0.463146, 0.117968, 0.0291591 and 0.00695536 AU/year.
Adjacent position-error ratios 3.926/4.046/4.192 agree with finite-reference
second-order expectations. World position errors relative to the binary
barycenter fall from 1.56733e-4 to 2.35107e-6 AU. Accumulated binary phase error
at the authored cap is appreciable: small energy drift and bounded survival do
not establish exact positions or phase over 60 000 years. The finest trajectory
is a numerical reference, not an exact solution.

The original e = 0.42 control still fails at 56 332.5 years under the compensated
clock. Its inferred eccentricity reaches 0.9355 and periapsis 0.5048 AU; negative
point-mass orbital energy at that sample is not an escape verdict. The former
step-sensitive failures and single lucky passing refinement remain in the
[review log](codebase-review-2026-10-02.md).

### Sunlight, reporting and reproduction

A 200-year probe samples every accepted frame through the production `Climate`
model with quiet stars. Insolation ranges **0.5343–1.6418 S⊕** and temperature
**267.14–305.42 K**; approximately 154.97 years are temperate, 44.94 cold and
0.09 hot under the model's labels. This validates short-term changing seasons,
not a 60 000-year climate envelope. Flares and stellar variability are excluded.

Run `python3 tools/check.py stability` for the strict authored baseline, or
`python3 tools/check.py stability-study` for all nine cases. Direct headless
options include `step_divisor=2` (also 1/4/8), `max_step=0.0002`,
`world_rotation=0.000001` and `world_eccentricity=0.42`. Any supplied override
selects diagnostic mode, even if its value equals the authored configuration;
`step_divisor` cannot accompany `max_step`. For the short refinement use
`years=20 max_step=0.0000125` as the reference. Use `report=/abs/result.json`.

Reports retain runtime/force/clock metadata, decimal states and versioned binary64
hex. `softening_au=0` records the raw request: the ordinary force uses
`radius / 2 + 1e-4 AU` as its default, not zero softening. Osculating elements
are unsoftened Jacobi two-body snapshots, not the actual four-body potential;
their energy signs and separation ratios are descriptive, not gate criteria.
An inferred periapsis minimum is not a measured star/world minimum separation.
The constructor preserves its tiny-world approximation (Kepler mass excludes
the 3e-6 M☉ world and the stellar binary has no world recoil); the diagnostic
includes that world mass. This accounts for a small difference between authored
and initial inferred eccentricity. Extent is sampled every 1 000 frames
(about 5.83 years); failure times are first observed violations.

Batch-14 exact states, logs and computations are retained in
`/tmp/astrarium-b14-study` and `/tmp/astrarium-b14-convergence`. Future checks
regenerate reports; these measurements apply to Godot 4.7.2/native on this Mac.

## Wandering suns (`trisolaris_wander`)

Built for the sky rather than stability: a 2+2 hierarchy parked just inside
the region where encounters go chaotic.

    Alpha  0.58 M☉  K5, 4163 K   home sun, 0.34 AU: an orange disc twice the Sun's width
    Beta   1.25 M☉  F5, 6770 K   a 0.45 AU pair (78 days) on one wide e = 0.50 orbit,
    Gamma  0.78 M☉  K2, 4973 K   inclined 22° to the world's

The pair's periapsis is 1.68 AU, five times the world's orbit. Every 3.8 years
a passage kicks the world's orbit, and near the Mardling–Aarseth boundary the
kicks compound rather than average out. The inclination is below the ~39.2°
Kozai–Lidov angle: it doesn't drive the chaos, it keeps the suns from tracing
one repeated line.

`qRatio` = q₂/a_P is the one knob. Below ~4 the world is stripped within decades.
Above ~6 the system relaxes and the sky becomes predictable (in a grid scan the
one-sun fraction climbs from 21% to over 70%).

Measured over a 24-run ensemble at the preset's step cap (75 203 samples),
counting suns showing a disc at least a quarter of the Sun's apparent width:

| suns showing a disc | fraction |
|---|---|
| none | 3% |
| one | 21% (a Stable Era) |
| two | 44% |
| three | 32% (a tri-solar day) |

The flagship preset gives 0 / 0 / 100 / 0. Insolation runs 0.64 (5th percentile)
to 3.68 (95th), 7.8 at the 99th, and is in the liquid-water band 91% of the time.

The Lyapunov time is of order an orbital period, so a run is set by rounding
after a few decades and can't reproduce these numbers shot for shot; only
ensemble statistics mean anything. The world lives a median of 382 years
(92 to 3437) and always ends: 14 of 24 runs ejected it, 10 fed it to a star's
Roche limit. The step cap is 3e-4: worst-case drift 6e-5 over 1500 years and
5.3e-4 across the ensemble. Halving the cap changes neither lifetimes nor sky
statistics.

These presets use the real destruction distance, not the drawn radius (drawn,
it is 3.5–3.7× the photosphere and ~2× the Roche limit, 9× and 7× at the
flagship's scale). It decides which close passes the world survives.
