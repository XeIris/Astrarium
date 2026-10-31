# Physics and fidelity review, 2026-10-30

This review checks the physics, numbers and features against measured values and
reputable references. It is separate from
[the 2026-10-02 codebase review](codebase-review-2026-10-02.md), which covered
numerical safety and engineering rather than physical fidelity. Each finding gives
the location, the evidence (a calculation reproduced here, or a source), the
consequence and a fix. Severity:

- **P1**: produces visibly or quantitatively wrong behaviour in a scenario the
  game presents as real.
- **P2**: wrong or outdated value or model with a smaller or localised effect.
- **P3**: an illustrative simplification that should be labelled, or a
  consistency issue.

The calculations were reproduced in Python from the constants in the code.

## Status (2026-10-31)

Fixed by the stacked branches: `fix/physics-fidelity-batch1` (P1-1 to P1-3),
`fix/physics-fidelity-batch2-4` (P1-5 to P1-8, S1, S2, S4 to S8, S10, S12, S13,
V2), `fix/physics-fidelity-obliquity` (P1-4), `fix/physics-integrator-1pn`
(section 5: Yoshida-4 and EIH 1PN; S3, S9, S11, S14) and
`fix/physics-fidelity-remaining` (the rest, below), with `fix/physics-fidelity-followups`
completing F1's cutoff, F5 and V1. F7 needs only a source note.

| item | status |
|---|---|
| S15 | Done. `Structure.neutron_cooling`: modified-Urca and photon cooling with an iron envelope, a crust that relaxes in ~30 yr, and `ageYr` in the spec ([structure.md](physics/structure.md#neutron-star-cooling)). |
| F1 | J2–J4 for Earth, Mars and the Moon in gravity, the potential and the rails kicks. ISS regression −5.02°/day. Telemetry uses a J2-averaged μ. The ascent cuts off on the coast's peak propagated under J2–J4, at a commanded cutoff time inside the step; the four shared launches reach their targets within 0.3 km, and `sharedflightcheck`'s J2·R²/a widening is gone ([flight.md](physics/flight.md#the-parents-figure)). **Not done:** the WGS-84 surface (ground, clouds, sky, landing and maps all assume a sphere), lunar mascons and C22. |
| F2 | Done. CO₂ k = 1.9027e-4 landed earlier; Tauber–Sutton radiative heating added for air and CO₂ (Venus held at the 9 km/s end of the CO₂ table). |
| F3 | Done. RK4 stages and rails kicks interpolate body offsets (cubic Hermite), and mass follows the first stage's flow. |
| F4 | **Mechanism only.** A stage's `cdTable` replaces the generic curve; no sourced per-vehicle table is included yet. |
| F5 | Done, **off by default.** A zonal climatology with trades, westerlies and a jet (Settings › Sim, `winds=1`). Aerodynamics read airspeed; wheels, gear, tower arms, the rollout, the descent drift and the orbiter's runway geometry read ground velocity, and the glide's range model allows for the wind along track. With winds on, `orbiter_return`, `orbiter_home`, `ship_return`, every Shuttle scenario, the Starship catch and the Falcon 9 fairing scenario pass. Off by default because the built scenario bases were recorded in still air (`starship:subsonic`'s replay misses by 1.1° with wind) and the frozen reference has none ([flight.md](physics/flight.md#air)). |
| F6 | Done. A porkchop of Lambert arcs prices and times interplanetary windows, and the departure leg aims along its v∞. |
| V1 | Done for Earth: single scattering with Bruneton's Rayleigh, Mie and ozone coefficients, sun-path transmittance and planet shadow, plus Hillaire's (2020) multiple-scattering table (`sim/flight/sky_ms.gd`, `tools/build_sky_ms.py`). It adds ×1.5 at the noon zenith and ×1.7 in civil twilight; the gain is renormalised to keep noon. Twilight at the daylight exposure stays dark because the real twilight/noon ratio is ~1%. Other bodies keep the tinted column ([sky.md](physics/sky.md#flight-sky)). |
| V3 | Done. Quadratic per band, interpolated in Teff from Claret's (2000) tables (VizieR J/A+A/363/1081; ATLAS from 3500 K, PHOENIX refitted below), log g 4.5 and solar metallicity only ([structure.md](physics/structure.md)). |
| V4 | Done. Analytic umbra and penumbra on rocky, cloud and giant surfaces at true scale; a red umbra for thick atmospheres, brightened ×100 for display. The star's limb darkening inside the penumbra is ignored. |
| V5 | Done. Mallama & Hilton (2018) magnitudes for the planets, Lambert spheres for other reflectors, on the sky's flux scale. |
| V6 | Done. `solar` draws the 9096 stars of the Yale Bright Star Catalogue (BSC5, `assets/sky/bsc5.bin`, built by `tools/build_starcat.py`) on the real J2000 galactic frame, and the procedural sky fills in below V ≈ 6. Gaia stars are not used; the catalogue is visible-band only, and neither lensed nor aberrated. |
| V7 | **Label only.** The inspector says "Schwarzschild geodesics — spin not rendered"; Kerr geodesics and Novikov–Thorne flux are not implemented. |
| V8 | Done. Flamm's paraboloid to 40 r_s for holes and depth ∝ Φ elsewhere, labelled in Settings › Render. |
| V9 | Done. Optional first-order light-time (Rømer) delay for drawn positions (Settings › Sim). |

---

## 1. Verified defects

### P1-1. Default Plummer softening adds a large spurious precession to real orbits

`Physics.softening_of` ([sim/physics.gd:135](../sim/physics.gd)) defaults to
`radius/2 + 1e-4 AU`, and no preset overrides it. The native kernel does the same
([native/astrarium_native.c:104](../native/astrarium_native.c)). For the Sun the
softening is 0.00243 AU, so the Sun–Mercury pair has ε² = 2.95×10⁻⁶ AU², and the
1e-4 AU floor alone is 15 000 km.

A softened potential −GM/√(r²+ε²) ≈ −GM/r + GMε²/(2r³) adds a repulsive 1/r³
term. To first order this gives an apsidal precession of Δϖ ≈ −3πε²/a² per orbit.

| check | value |
|---|---|
| analytic, Mercury | −15 900″ per century |
| direct integration (velocity Verlet, h = 1e-5 yr, e = 0.2056, game ε) | −17 500″ per century (unsoftened control: −11″) |
| unsoftened, at the orrery's own adaptive step (0.05 t_fall, about 240 steps per orbit) | **+162 000″ per century** of integration error |
| real GR precession of Mercury | +42.98″ per century |
| real total observed | ≈ +575″ per century |

So the default softening drives Mercury's perihelion backwards at about 4.4° per
century, roughly 370 times the GR effect and in the opposite direction. Earth gets
about −0.16° per century, comparable to its real precession of +0.32° per century.
For the Moon, ε/r = 0.044, which weakens Earth–Moon gravity by 0.29% and makes the
circular initial velocity (computed unsoftened) slightly too fast.

The last row matters as much as the softening. At the step `dynamic_step` picks
for Mercury, velocity Verlet's own phase error turns the perihelion about 45° per
century, so a correct force law alone doesn't give a correct precession. That
needs the integrator work in section 5 (a fixed-step or time-symmetric scheme, or
WHFast/IAS15) or a smaller step factor for resolved orbits.

**Fix:** use ε = 0 for any pair whose bodies are resolved (contact distance ≪
separation), and keep softening for sandbox encounters only. Alternatively, scale
the floor to the pair's contact radii, not a fixed 1e-4 AU. Then set
`softening: 0` explicitly in `solar`, `sirius`, `alphacen` and the edu presets.
`total_energy` already uses the same pair rule, so it stays consistent.

### P1-2. The code uses three different years and two values of GM☉

| place | constant | implied year or GM |
|---|---|---|
| `Physics.G = 4π²` | AU³ M☉⁻¹ yr⁻² | the **Gaussian** year, 365.25690 d |
| `Physics.C`, `Rocketry.YR_S`, `Relativity.YEAR_S`, `Climate.YEAR_S` | Julian year | 365.25 d |
| `Structure.SEC_PER_YR = 3.155815e7` | sidereal year | 365.2564 d |
| `Rocketry.GM_SUN` | 1.32712440018e20 (IAU 2015) | |
| `Structure.M_SUN·G_SI`, `GWDetector.M_SUN` | 1.98892e30 × 6.67430e-11 | 1.32746e20, **+2.6×10⁻⁴** |

With the IAU GM☉ and the exact AU, G in AU³ M☉⁻¹ (Julian yr)⁻² is **39.4769264**,
not 39.4784176 (a −3.8×10⁻⁵ difference). The comment on `Rocketry.GM_SUN`, "the
same G as sim/physics.gd", is therefore false. The orrery's 1 AU orbit lasts
exactly 365.25 d. The SI flight frame, converting with `YR_S`, expects 365.2569 d.
The difference accumulates to about 10 minutes per orbit, which is 0.68° of
longitude per century, and planet velocities handed to flight are inconsistent by
about 0.6 m/s.

**Fix:** define `G := Rocketry.GM_SUN * YR_S² / AU_M³` once, use the Julian year
everywhere, and set `M_SUN := GM_SUN / G_SI = 1.98841e30 kg`
([IAU 2015 Resolution B3](https://www.iau.org/static/resolutions/IAU2015_English.pdf)).
The figure-eight preset's "×2π" rescale then needs `sqrt(G)`.

### P1-3. The `solar` preset isn't the real Solar System

[sim/presets.gd:509](../sim/presets.gd), `orbiter()` at line 219.

- Every planet starts on a **circular, coplanar orbit at a random phase**. Real
  eccentricities include Mercury 0.2056, Mars 0.0934 and Pluto 0.2488 (inclined
  17.1°). Positions match no date, so the sky, phases and launch windows are
  fictional.
- The `incl` argument of `orbiter()` is not an inclination. It adds `0.02·sin(i)·x`
  to y and no vertical velocity.
- **The Moon is coplanar with the ecliptic** (`moon_of` keeps the parent's y), so
  there is a solar and a lunar eclipse at every syzygy. The course's own
  `edu_moon` preset uses the real 5.14° and teaches the opposite.
- The Sun has zero velocity, so the system's barycentre drifts at about 13 m/s.
  This is Galilean and harmless, but it moves trails.
- **Masses:** Earth is 3.00e-6 M☉. The real value is 3.003489e-6, and
  `Rocketry.M_EARTH_SUN` already has it. The difference makes the flight μ⊕
  3.98137e14 against the WGS-84 3.986004e14 (−0.116%), costing about 4.5 m/s of
  LEO speed and moving GEO by 16 km. Mars is 3.21e-7 against 3.2271e-7 (−0.53%).

**Fix:** initialise the planets from the JPL approximate Keplerian elements
([Standish, "Approximate Positions of the Planets"](https://ssd.jpl.nasa.gov/planets/approx_pos.html))
at J2000 or the user's date, using full (a, e, i, Ω, ϖ, L). The Moon needs
a = 384 400 km, e = 0.0549 and i = 5.145°. Take masses from
[DE440 GM values](https://ssd.jpl.nasa.gov/astro_par.html). Then remove the
barycentric drift.

### P1-4. The flight frame gives Earth zero obliquity

`place_on_pad` ([sim/flight/vessel.gd:237](../sim/flight/vessel.gd)) puts the
spin pole on −Y, the **ecliptic** pole, and every rotating-body expression shares
it. The orrery visual still tilts Earth by 23.44°. As a result:

- A launch from 28.5° N reaches 28.5° to the **ecliptic**. The Moon, in the
  ecliptic under P1-3, needs a 28.5° plane change. In reality the Moon's orbit is
  18.3°–28.6° from the equator over the 18.6-year nodal cycle, and Apollo
  launched near the Moon's plane by choosing the launch azimuth and time.
- The Sun's elevation at the pad has no seasons, and the Sun never leaves the
  equatorial plane in the flight sky.
- `mission_direction` converts RA/Dec through ε = 23.4393°, but the launch site
  doesn't, so star and launch geometry disagree by up to 23°.

**Fix:** give each body a spin-axis quaternion, using the IAU WGCCRE pole RA/Dec
([Archinal et al. 2018](https://doi.org/10.1007/s10569-017-9805-5)). Then rotate
`place_on_pad`, `site_at`, `airspeed` and the landed step by it.

### P1-5. Venus rotates at its solar-day rate

`SURFACES.Venus.day = −10 087 200 s` ([sim/flight/rocketry.gd:232](../sim/flight/rocketry.gd))
is 116.75 d, Venus's **solar** day. The inertial frame needs the sidereal period,
−243.0226 d = −20 997 153 s. Equatorial surface speed comes out at 3.77 m/s
against the real 1.81 m/s, and the atmosphere co-rotates twice too fast.

### P1-6. Atmosphere model errors

[sim/flight/rocketry.gd:23–134](../sim/flight/rocketry.gd), checked against the
[US Standard Atmosphere 1976](https://ntrs.nasa.gov/citations/19770009539).

| h (km) | ρ game / US76 | T game (K) | T US76 (K) | a game / US76 (m/s) |
|---|---|---|---|---|
| 30 | 0.99 | 216.6 | 226.5 | 295 / 302 |
| 50 | 1.00 | 216.6 | 270.6 | 295 / **330** |
| 60 | 0.87 | 216.6 | 247.0 | 295 / 315 |
| 100 | **2.27** | 216.6 | 195.1 | 295 / 280 |
| 120 | **3.92** | 216.6 | 360 | |
| 140 | 1.56, then **0** above | | | |

1. **Temperature is frozen at 216.65 K above 11 km.** Isothermal layers keep the
   lower layer's T. Mach number is overstated by up to 12% near the stratopause.
   That shifts `drag_coefficient(mach)`, the plume shock structure and the
   heating readouts.
2. **The thermosphere is too dense by 2–4× from 90 to 130 km, and drag is
   exactly zero above 140 km.** Entry interface (122 km) arrives in air four
   times too dense. No orbit ever decays: the ISS at 400 km really loses about
   2 km per month at solar mean
   ([NRLMSISE-00](https://doi.org/10.1029/2002JA009430)).
3. **The lapse-rate exponent uses Earth's g₀ for every body**
   (`n = G0·M/(R·L) − 1`, line 100, and `scale_height`, line 129). For Venus
   (g = 8.87), density at 50 km is 0.93 kg/m³ against 1.50 with Venus's own g.
   [VIRA](https://doi.org/10.1016/0273-1177(85)90197-8) gives about 1.6, so the
   game is 40% low.

**Fix:** use the full seven-layer US76 lapse table, with T carried through every
layer and `g_surf` in the exponent. Above 86 km, use tabulated exponential
segments to about 1000 km, or NRLMSISE-00 with an F10.7 setting for drag and
decay.

### P1-7. Above 4× warp the vessel ignores every body but its parent

`spaceflight.gd:1177` puts the vessel on `Orbit.propagate`, a two-body Kepler
conic about the parent, whenever warp is above 4×. Below that, RK4 includes the
Moon and the Sun. **The same coast therefore follows a different trajectory
depending on time warp.** A trans-lunar coast at warp ignores lunar gravity until
the patched SOI handover at 66 000 km. That is enough to move the arrival
periapsis by hundreds of kilometres, and free-return trajectories can't exist.

**Fix:** on rails, use Encke's method or a Wisdom–Holman split (Kepler drift about
the parent plus third-body kicks). Alternatively, use an adaptive high-order
integrator ([DOP853, Hairer et al.](https://doi.org/10.1007/978-3-540-78862-1))
that warps by taking long steps rather than by dropping forces.

### P1-8. Orrery planets spin at a random rate unrelated to simulated time

`rocky_visual.gd:267` gives every non-"world" planet, including Earth in `solar`, a
random display spin of 0.4–1.6 rad per *render* second, with a **10% chance of
spinning retrograde**. `giant_visual.gd:230` does the same for the giants. The
`dayLength` path in `world.gd` is used only by `world` types. Day and night on
Earth in the orrery therefore have nothing to do with the clock. Venus and Uranus
aren't retrograde unless the random draw makes them so. The cloud deck's ×0.985
is described as "super-rotation", but it is sub-rotation. Venus's cloud tops
super-rotate about 60× faster than its surface.

**Fix:** drive rotation from sidereal period × sim time for every body that has a
period. Keep `visualSpinRadS` only as an explicit override.

---

## 2. Stellar and compact-object model

| # | sev | location | finding | evidence or reference | fix |
|---|---|---|---|---|---|
| S1 | P2 | `structure.gd:127` | Main-sequence lifetime `1e10·M/L` fails at both ends. It gives 20 M☉ → 4.0 Myr, 60 → 1.07, 120 → 0.76 and 0.1 M☉ → 0.87 Tyr. The `stellar_zoo` blurb says "three million" and "ten trillion". | Geneva tracks: about 3 Myr at 120 M☉ and about 8 Myr at 20 M☉ ([Ekström+2012](https://arxiv.org/pdf/1110.5049); [Massey 2013 review](https://arxiv.org/pdf/1305.5914)). 0.1 M☉ is fully convective and lives about 6 Tyr ([Laughlin+1997](https://doi.org/10.1086/304125)). | Interpolate tabulated τ_MS(M) from MIST or Geneva, or use a fuel fraction q(M) that rises to 1 below 0.35 M☉ and above about 30 M☉. |
| S2 | P2 | `structure.gd:43`, `_stellar_verdict` | The Humphreys–Davidson limit is a **luminosity** limit for cool supergiants (log L ≈ 5.8), not a mass at which a star explodes. Stars from 120 to 140 M☉ are flagged "explode". `eddingtonMass: 150` is misnamed. | [Humphreys & Davidson 1979](https://doi.org/10.1086/157301). R136a1 is 196 (169–230) M☉ ([Kalari+2022](https://www.sci.news/astronomy/gemini-south-images-most-massive-known-star-11118.html)). | Apply HD as a cap on red-supergiant radius/T at high L, and raise the observed upper mass to about 200–300. |
| S3 | P2 | `LIMITS.pairLo/Hi` | Pair-instability uses the 140–260 M☉ *initial* mass at any Z. At solar Z, winds keep the helium core below 65 M☉. | [Heger & Woosley 2002](https://doi.org/10.1086/338487); [Woosley 2017](https://doi.org/10.3847/1538-4357/836/2/244). | Gate on helium-core mass, estimated from Z-dependent mass loss. |
| S4 | P3 | `structure.gd:234` | The comment gives κ = 0.34 **m²/kg**. The real value is 0.34 cm²/g = 0.034 m²/kg. The constant 3.2e4 L☉/M☉ corresponds to κ = 0.40 (pure H); X = 0.7 gives 3.84e4. | 4πGMc/κ | Use `3.84e4·M·(1.7/(1+X))`. |
| S5 | P2 | `structure.gd:107` | The white-dwarf coefficient of 0.0126 inflates radii by 12%. It gives Sirius B 0.0088 R☉ against the measured 0.0081, and 0.6 M☉ 0.0140 against about 0.0125. | Nauenberg 1972 coefficient 0.0112 (μe = 2); [Bond+2017](https://doi.org/10.3847/1538-4357/aa6af8) | Use 0.0112, plus a finite-temperature envelope term if hot white dwarfs matter. |
| S6 | P2 | `structure.gd:774` | The initial–final mass relation uses only the first Cummings segment: 8 M☉ → 1.13 M☉ against 1.33, and 5 → 0.89 against 1.01. | [Cummings+2018](https://doi.org/10.3847/1538-4357/aadfd6), three-piece MIST fit | Use all three segments. |
| S7 | P3 | `physics.gd:20` | A second neutron-star radius law (linear, 13 → 10 km) still exists beside `Structure.neutron_radius_km`, against the single-source rule. `derive_body` calls it before `refresh_structure` overwrites the result. | AGENTS.md "What a body is" | Delete it. |
| S8 | P3 | `structure.gd:110` | Radius falls to 11.1 km at 2.08 M☉. NICER measures PSR J0740+6620 at 12.4 (+1.3/−1.0) km. | [Riley+2021](https://doi.org/10.3847/2041-8213/ac0a81); [Miller+2021](https://doi.org/10.3847/2041-8213/ac089b) | Flatten the curve until about 0.95 M_TOV. |
| S9 | P2 | `stellar.gd:57` | Rotation `25 d·M^−0.6` gives 2 M☉ a 16.5 d period. Above the Kraft break (≈6200 K), A and B stars rotate at 100–300 km/s, with periods of about 1 d. Rotation doesn't depend on age (Skumanich spin-down). | [Kraft 1967](https://doi.org/10.1086/149359); [Zorec & Royer 2012](https://doi.org/10.1051/0004-6361/201117691) | Make rotation piecewise in Teff, with gyrochronology below the break. |
| S10 | P1 for climate | `stellar.gd:154,164`, `climate.gd:85`, `main.gd:718` | Flares last 1.5–9 *days* and multiply **bolometric** luminosity by up to about ×2, which feeds insolation and climate. CMEs expand at 14–34 R☉/yr, which is 0.3–0.75 km/s. | Largest solar flares raise TSI by about 3×10⁻⁴ for minutes ([Kopp+2005](https://doi.org/10.1007/s11207-005-7433-9); [Woods+2004](https://doi.org/10.1029/2004GL019571)). CMEs move at 300–3000 km/s. | Keep the visual pulse, but couple at most about 1e-3 into `luminosity` (M-dwarf superflares a few %). Label CME speed as time-compressed, or scale it with time warp. |
| S11 | P3 | phase table | The `rgb` stop (25 R☉, 320 L☉) is mid-RGB, but its note says "the size of Mercury's orbit" (83 R☉). There is no RGB tip (Sun: ≈170–250 R☉, ≈2500 L☉) and no helium-flash event. | [MIST tracks](https://waps.cfa.harvard.edu/MIST/) | Add an RGB-tip stop, or interpolate MIST tracks. |
| S12 | P3 | `_hole_layers` | The photon-sphere layer always sits at 3M, even when the hole spins, while `photonSphereAU` gives the Kerr prograde value. `shadowAU` is a convoluted expression that equals √27·M. | Bardeen+1972 | Use the computed Kerr radius. |
| S13 | P2 | `main.gd:781` | Mergers conserve rest mass. A BH–BH merger radiates about 5% of its mass (GW150914: 3.1 M☉ of 65), leaves a spin of about 0.69 for equal masses, and receives a kick of up to thousands of km/s. Star–star mergers lose no mass. | [LIGO 2016](https://doi.org/10.1103/PhysRevLett.116.061102); [Hofmann, Barausse & Rezzolla 2016](https://doi.org/10.3847/2041-8205/825/2/L19); [Campanelli+2007](https://doi.org/10.1103/PhysRevLett.98.231102) | Apply the numerical-relativity fits for final mass, spin and kick. |
| S14 | P3 | `physics.gd:248` | GW drag uses circular power and doesn't evolve eccentricity, so eccentric binaries don't circularise. | [Peters 1964](https://doi.org/10.1103/PhysRev.136.B1224) | Use orbit-averaged Peters da/dt and de/dt, or the 2.5PN Burke–Thorne term. |
| S15 | P3 | `structure.gd` neutron | Neutron stars have a fixed Teff of 6×10⁵ K, and the crust is hotter than the core in every case. | [Yakovlev & Pethick 2004](https://doi.org/10.1146/annurev.astro.42.053102.134013) | Add a cooling curve T(age). |

---

## 3. Flight and aerothermal model

| # | sev | finding | reference | fix |
|---|---|---|---|---|
| F1 | P2 | Bodies are spherical point masses. Without **J2**, there is no nodal regression (the ISS's is about −5°/day), no sun-synchronous orbits and no apsidal drift. Earth uses a 6371 km sphere instead of the WGS-84 ellipsoid, so pad height and geodetic latitude are wrong by up to 21 km. | J2 = 1.08263e-3, [Vallado](https://celestrak.org/software/vallado-sw.php) | Add J2, and J3/J4 for Earth, Mars and the Moon, plus GRAIL mascons for low lunar orbits. |
| F2 | P2 | The Sutton–Graves air constant (1.7415e-4) is used for Mars and Venus too. For CO₂ it is about 1.90e-4. There is **no radiative heating**, which dominates the shock layer above about 10 km/s (lunar return, Mars entry). | [Sutton & Graves 1971](https://ntrs.nasa.gov/citations/19720003329); [Tauber & Sutton 1991](https://doi.org/10.2514/3.26230) | Use a per-atmosphere k and add the Tauber–Sutton q_rad term. |
| F3 | P3 | Inside an RK4 step, other bodies sit at their *end-of-step* positions, which is first-order error in the tidal term. Mass is held constant through the step. | | Interpolate body positions at the RK stages. |
| F4 | P3 | `drag_coefficient(Mach)` is one curve for every launcher, and angle-of-attack drag is an ad hoc `1 + 2.2 sin²α`. Plume-on base drag isn't modelled. | | Use per-vehicle Cd tables (e.g. Saturn V from MSFC TM X-53xxx, Falcon from public DATCOM fits). |
| F5 | P3 | There are no winds. Air rotates rigidly. | [HWM14](https://doi.org/10.1002/2014EA000089) | Add a jet stream and wind shear for max-Q and landing realism. |
| F6 | P3 | The Δv and window planner assumes circular coplanar planets. Once P1-3 is fixed, the Hohmann phase-angle window will be wrong by weeks for Mars (e = 0.093). | | Use a Lambert porkchop over departure and arrival dates. The Lambert solver already exists. |
| F7 | P3 | The engine data checks out: F-1, J-2, RS-25 at 104.5% (2183.7 kN, 452.3 s), RSRM, LM DPS/APS, SPS, NEXT, and the Merlin/MVac Isp. Raptor 3 is modelled at 250 tf sea level. SpaceX's 2024 card says 280 tf, but sources disagree. | [Raptor](https://en.wikipedia.org/wiki/SpaceX_Raptor) | Record which source the Raptor number comes from. |

---

## 4. Rendering fidelity

| # | sev | finding | fix or reference |
|---|---|---|---|
| V1 | P2 | The flight sky dome ([shaders/flight/sky_dome.gdshader](../shaders/flight/sky_dome.gdshader)) uses a single grey optical depth with a tint colour, a hand-tuned sunset factor `(1, 0.45, 0.22)` and a hand-tuned "sun" clamp. It has no λ⁻⁴ extinction, no ozone (the Chappuis band is why the twilight zenith stays blue), no multiple scattering, and no Earth shadow or Belt of Venus. The README says the sky is "integrated through a spherical atmosphere"; only the column density is. | [Hillaire 2020](https://sebh.github.io/publications/egsr2020.pdf) or [Bruneton 2017](https://github.com/ebruneton/precomputed_atmospheric_scattering), with β_R = (5.802, 13.558, 33.1)×10⁻⁶ m⁻¹, β_M = 3.996×10⁻⁶ (g ≈ 0.8) and ozone (0.650, 1.881, 0.085)×10⁻⁶. |
| V2 | P2 | Star colour uses Tanner Helland's photographic fit, renormalised to the peak channel. It is not colorimetric: the Sun at 5772 K comes out orange-ish, when it should be very slightly pink-white in sRGB. | Integrate Planck × CIE 1931 CMFs → XYZ → linear sRGB, or use [Charity's table](http://www.vendian.org/mncharity/dir3/blackbody/). |
| V3 | P3 | Limb darkening is linear with u = 0.6 for every star and band. The legacy shader uses `pow(μ, 0.55)`. | Teff- and band-dependent quadratic coefficients ([Claret 2000](https://doi.org/10.1051/0004-6361:20000193)). |
| V4 | P2 | There are no eclipse or moon shadows between bodies. The lesson admits this. Saturn's ring shadow already exists. | Analytic sphere-occlusion with an umbra and penumbra from the star's angular radius, including limb darkening. Add Earth's reddened umbra for lunar eclipses. |
| V5 | P3 | The point-source marker's brightness isn't the body's apparent magnitude. It ignores albedo, phase angle and distance from the Sun. | Planet magnitudes from [Mallama & Hilton 2018](https://doi.org/10.1016/j.ascom.2018.08.002). |
| V6 | P3 | The sky is procedural. The `solar` scene has no real constellations, planets or Milky Way orientation. | Use the Yale BSC5 or HYG catalogue for V < 6.5 (≈9100 stars) and Gaia DR3 for fainter stars, keeping the procedural fill below that. |
| V7 | P3 | The lens marcher is Schwarzschild, even when the inspector says "Kerr (a* = …)". The disc is Newtonian Shakura–Sunyaev with a zero-torque edge. | Kerr null geodesics with Carter's constant (shadow asymmetry, frame dragging), and the [Novikov–Thorne / Page–Thorne](https://doi.org/10.1086/152990) flux. The label should say "spin not rendered" until then. |
| V8 | P3 | The spacetime sheet's depth is `2.4 r_s/(0.5+0.14d)` for holes and `min(M + R, 6)` for everything else. Neither is a physical embedding. | Flamm's paraboloid z = 2√(r_s(r−r_s)) for holes, and depth ∝ Φ elsewhere, with a label. |
| V9 | P3 | Everything is drawn at instantaneous positions. The course teaches "Light takes time", but the renderer has no retarded time. | An optional light-time correction (Rømer). |

---

## 5. Integrator

- **Adaptive velocity Verlet is not symplectic.** `dynamic_step` picks h from the
  current state. The docs admit this, but the consequence is secular energy drift
  in eccentric presets (Sirius e = 0.59, α Cen e = 0.52, Trisolaris), so
  "passing" stability checks partly measure the integrator. Options:
  time-symmetric step selection
  ([Hut, Makino & McMillan 1995](https://doi.org/10.1086/187889)),
  [IAS15](https://doi.org/10.1093/mnras/stu2164) for general use,
  [WHFast](https://doi.org/10.1093/mnras/stv1257) for hierarchical systems such as
  the Solar System, and Mikkola–Aarseth algorithmic regularization for close
  black-hole and neutron-star pairs.
- **No post-Newtonian terms.** Calling this a "relativistic orrery" is generous:
  orbits are Newtonian. 1PN Einstein–Infeld–Hoffmann terms would produce
  Mercury's 43″ per century, and periastron advance in compact binaries (Hulse–Taylor:
  4.23° per year).

---

## 6. Additions that would improve realism

### Ephemeris and time
- Real-date start from JPL elements or DE440 (see P1-3), a date and time readout
  in UTC and TDB, and true sidereal rotation with IAU pole orientation for every
  body.
- Real eclipse prediction, falling out of the geometry once the Moon is inclined.

### Gravity and dynamics
- 1PN EIH terms behind a toggle, with a lesson showing Mercury's 43″.
- J2 and zonal harmonics (Earth, Mars, Moon, Jupiter), which give sun-synchronous
  orbits and Molniya critical inclination as emergent behaviour.
- Tides: dynamic Roche-limit disruption as a structural event (instead of only a
  preset `contactAU`), tidal locking and circularisation timescales.
- Stellar mass loss in time. Adiabatic mass loss widens orbits (a ∝ 1/M), so the
  Sun's red-giant phase would push the planets out.
- Roche-lobe overflow and mass transfer
  ([Eggleton 1983](https://doi.org/10.1086/160960) lobe radius), novae, and
  Type Ia supernovae from accretion rather than only a mass slider.
- Supernova natal kicks for neutron stars (Maxwellian σ ≈ 265 km/s,
  [Hobbs+2005](https://doi.org/10.1111/j.1365-2966.2005.09087.x)), which unbind
  binaries as an emergent outcome.
- Numerical-relativity remnant fits and a ringdown at merger (S13). Peters
  inspiral would let `bhmerger` chirp honestly.
- Radiation pressure and solar sails. A light-sail craft would sit naturally
  beside the photon drive.

### Flight
- NRLMSISE-00 drag with a solar-activity slider and orbital decay. This makes
  reboosts and re-entry of debris real.
- Lagrange points and halo orbits (JWST at L2), and gravity assists. Both need
  P1-7 fixed.
- Aerobraking and aerocapture at Mars and Venus, with the corrected atmospheres.
- Radiative heating, ablation and recession on the heat shield, and the
  communications blackout (plasma frequency above S-band at about
  10¹⁷ electrons/m³).
- Propellant boil-off and slosh, and gravity- and steering-loss telemetry (the
  game already computes the pieces).
- Real launch sites with their azimuth limits (KSC 35°–120°, Vandenberg polar,
  Baikonur 51.6°).

### Visuals
- A physically based sky and aerial perspective (V1), applied consistently to
  Earth, Mars (dust Mie scattering gives a **blue** sunset) and Titan (haze).
- Eclipse shadows (V4), earthshine on the night side of the Moon, and planet
  phases with correct magnitudes (V5).
- A real star catalogue and Milky Way (V6), with relativistic beaming already
  supported by `sky_aberrate`.
- Aurora ovals driven by the flare and CME model, airglow at 90–100 km (557.7 nm
  green), zodiacal light, and noctilucent clouds at 83 km for high-latitude
  twilight launches.
- Spectral re-entry plasma colour (N₂⁺ and O lines on Earth, CN and C₂ on
  Mars/Titan entry).
- Kerr lensing and a Novikov–Thorne disc (V7). Gravitational redshift of the
  background seen by a hovering observer.
- Colorimetric blackbody colours (V2) and per-band limb darkening (V3).

### Climate
- The runaway-greenhouse limit (outgoing longwave radiation capped at about
  282 W/m², [Goldblatt+2013](https://doi.org/10.1038/ngeo1892)) and a moist
  greenhouse, so a Trisolaris "Scorch" era can actually lose its oceans.
- Cloud albedo feedback. `clouds` is computed but never enters the albedo.
- A latitudinal Budyko–Sellers or North energy-balance model, giving ice lines
  and snowball bifurcation. `insolation_s2` already provides the forcing.
- Habitable-zone overlays from [Kopparapu+2013](https://doi.org/10.1088/0004-637X/765/2/131).

---

## 7. Checked and found correct

These were verified and need no change: c in AU/yr (63241.077); the Hawking
temperature (6.17×10⁻⁸ K·M☉/M) and evaporation time (2.1×10⁶⁷ yr·M³); Kerr
r₊, ISCO and prograde photon orbit; the Roche-model surface and
Ω_crit = √(8GM/27R_p³); the annual-insolation P₂ coefficient (−0.477 at 23.44°);
T_eq = 278.6 K·(S(1−A))^¼; Seager mass–radius fits; giant radius law (Jupiter
1.01 R_J); the relativistic rocket and rapidity budget; linear Isp(p_a), which is
exact for fixed ṁ; sidereal days for Earth, Mars, the Moon, Mercury, Titan and
Pluto; Saturn's ring radii (1.235–2.27 R_S); the giant-planet internal-heat ratios;
the fairing jettison criterion (1135 W/m²); Mars and Titan surface states; and the
Schwarzschild lens geometry and finite-observer shadow. The physics docs are
unusually candid about their own limits, which made this review easier.

## Suggested order of work

1. P1-1 softening, P1-2 constants and P1-3 ephemeris. Do them together: they
   change the same presets and the drift baselines, so `presetcheck`, `nbodycheck`
   and stability need to be re-run.
2. P1-6 atmosphere and P1-5 Venus. These are self-contained, and
   `sharedflightcheck` and `missioncheck` cover them.
3. P1-7 rails and P1-4 obliquity. These change mission planning, so replay the
   missions.
4. P1-8 spin, then S1–S15 data fixes, then visuals.
