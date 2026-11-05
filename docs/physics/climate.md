# Climate: `sim/climate.gd`

A zero-dimensional energy balance for each rocky or ocean world
([per world](#a-climate-per-world) below),

    C dT/dt = (1 − α(T)) S/4 − OLR(T),   OLR = ε σ T⁴

with ε the effective emissivity (0.61 puts Earth at 288 K), α rising with ice cover
between 278 K and 233 K, and C the ocean mixed layer's heat capacity. S is the
summed flux of every star at the planet's current distance (`insolation_at`).

## Runaway greenhouse

A wet world's outgoing longwave is capped at 282 W/m², the limit a saturated steam
atmosphere reaches near 300 K and holds until the surface passes ~1600 K
([Goldblatt et al. 2013](https://doi.org/10.1038/ngeo1892)). With ε = 0.61 the cap
binds above 302 K, so an Earth with α = 0.306 runs away above ~1.19 S⊕; 1D models
give 1.06 ([Kopparapu et al. 2013](https://doi.org/10.1088/0004-637X/765/2/131)) and
3D models ~1.1.

Above the cap the extra flux goes into the ocean, not the mixed layer. Earth's ocean
is 2.7×10⁶ kg/m² (1.4×10²¹ kg over 5.1×10¹⁴ m²); boiling it takes 6.2×10¹² J/m²,
10⁵ times what heats a 12 m mixed layer by a kelvin. So at the boiling point the
temperature follows the saturation curve while the ocean evaporates, and the steam
rains back out when the planet cools:

    T_boil = 1 / (1/373.15 K − (R/L) ln(1 + 270·steam)),   L = 40.7 kJ/mol

(Clausius–Clapeyron at constant L; a whole ocean as steam is 270 bar and 651 K, close
to water's 647 K critical point). An Earth-like world at 1.5 S⊕ boils its ocean in about
three thousand years; a Trisolaris close pass of a few months boils a fraction of a
percent. While steam is present the era is "Runaway greenhouse".

## Moist greenhouse and hydrogen escape

Water that reaches the stratosphere is photolysed and its hydrogen escapes, so the
loss is permanent (`Climate.hydrogen_escape`). The cold trap's water mixing ratio is
a log-linear fit through ~3 ppm at 288 K and 3 × 10⁻³ at 340 K, Kasting's (1988)
moist-greenhouse threshold, and is 1 in a runaway. Escape is diffusion-limited,
2.5 × 10¹⁷·f_H m⁻²s⁻¹ with f_H = 2f_H₂O (Hunten 1973), capped by the energy limit
ε·F_XUV/(4GMm_H/R) with ε = 0.15 and today's solar XUV, 4.6 mW/m² at 1 AU, scaled with
the bolometric flux: 1.6 × 10¹⁵ m⁻²s⁻¹ for Earth. An ocean column holds 1.8 × 10³²
hydrogen atoms per m², so:

- today's Earth keeps its ocean for longer than 10¹² years;
- at 340 K it loses it in ~4 Gyr, Kasting's ocean in the Sun's lifetime;
- a runaway escapes at the energy limit and dries in ~2 Gyr at 1.5 S⊕.

Escape is taken from the steam first, then the sea, and recorded as `lost`. The era
reads "Moist greenhouse" while the stratosphere is wet and the sea is still there.
A world with no water left loses the runaway cap and heats to its dry equilibrium.
A young or active star's XUV excess, which would dry a world far faster, is not
modelled, and the escape uses Earth's gravity and column for every world.

A world without oceans (`oceans: false`) has no cap.

## The habitable zone

`Climate.hz_flux` evaluates Kopparapu et al. (2013, Table 3, as corrected in their
erratum) for a star's Teff, S_eff = S☉ + aT + bT² + cT³ + dT⁴ with T = Teff − 5780 K
(clamped to 2600–7200 K). The climate panel shows the conservative zone, runaway to
maximum greenhouse (1.05 to 0.34 S⊕ for the Sun), for the star delivering most of the
flux; the limits are single-star results, so a circumbinary world reads them
approximately. The coefficients were transcribed from the paper rather than
re-downloaded; at 5780 K they reproduce its 0.99 AU moist-greenhouse and 1.70 AU
maximum-greenhouse distances.

## Clouds

Cloud cover is a visual humidity rule: it rises 3.75%/K near 288 K. It stays out of
the energy balance. Coupled at CERES's cloud radiative effect (−47 W/m² shortwave,
+26 W/m² longwave, at 0.67 cover; Loeb et al. 2018), that rule would add a cloud
feedback of −1.2 W/m²/K, where the observed value is +0.42 ± 0.35 W/m²/K (IPCC AR6
WG1 ch. 7). The base albedo and ε already include today's clouds.

## Ice lines and the snowball

`LatitudeEBM` (`sim/ebm.gd`) runs North's (1975) diffusive Budyko–Sellers model
beside the global balance, on the same clock and heat capacity:

    C ∂T/∂t = Q s(x) a(x, T) − (A + B T) + D ∂/∂x[(1 − x²) ∂T/∂x],   x = sin φ

The pieces:

- **Insolation.** `s(x) = 1 + s₂P₂(x)`, with s₂ from the world's obliquity
  (`RockyVisual.insolation_s2`).
- **Albedo.** The coalbedo is `0.697 − 0.0779 P₂(x)` where ice-free and 0.38 under
  ice, with the ice edge at −10 °C. B = 2.09 W m⁻² K⁻¹ (North, Cahalan & Coakley
  1981).
- **Outgoing longwave.** A is pinned so that `A + B·15 °C` equals this model's own
  emission at 288 K, so the two models agree on a temperate world's mean.
- **Diffusion.** D = 0.55 W m⁻² K⁻¹ puts today's edge at 71.8° with a 14.5 °C mean.
  A slightly larger D melts the cap altogether: this is North's small-ice-cap
  instability.
- **Numerics.** One hemisphere in 60 cells, stepped implicitly (tridiagonal), so a
  frame of any length is stable.

Ice is state, not a function of the present sunlight. Lowering S, the cap grows
until, below 0.90 S₀, it runs to the equator: a snowball. It then stays frozen at
today's sunlight and thaws only above 1.32 S₀. This is the hysteresis of Budyko
(1969) and Sellers (1969). Past 54.7° of obliquity s₂ changes sign, the poles
become the warm end, and ice forms at the equator first.

The climate panel's "ice line" row shows the edge, or "snowball". The glaciated
fraction `ice` is the larger of the global model's temperature ramp and the
latitude model's ice cover, and a world's surface draws its caps from it. A
snowball takes the global model's ice to full cover, so its temperature and era
follow (`realismcheck` drives 0.85 S₀ into deep freeze). Otherwise the global
model keeps its own albedo ramp, which already includes today's caps.
`tools/realismcheck.tscn` checks the 72° edge, the snowball threshold, the
hysteresis and the inverted case.

## A climate per world

Every `planet` or `world` body has its own `Climate` in `b.climate`; a body that stops
being one (a collapse, a merger into a hole) loses it. `ClimateInputs` holds the rest.
The panel reads the focused world, or the home world when the focus has no climate.

### Inputs

Flat spec fields, validated with mass and spin by `Structure.input_error` before a
spawn, edit or preset changes anything:

| Field | Meaning | Domain |
| --- | --- | --- |
| `mixedLayer` | thermal flywheel, metres of water | 0.1–5000 |
| `greenhouse` | effective emissivity ε | 0.005–1 |
| `albedoBase` | ice-free Bond albedo; `albedo` stands in for it when unset | 0–1 |
| `albedoIce` | albedo added at full glaciation; with the base at most 1 | 0–1 |
| `oceans` | whether the world has water to freeze, boil and lose | bool |
| `T0` | starting temperature, K; only read when the world is created | 3–5000 |

A stated value wins, and an edit is a stated value; setting one to null returns to the
draw. An edit naming only these fields keeps the body's visual and structure, so a
slider cannot disturb a tracked spin. `albedo` also draws the surface, so it rebuilds.

A rendered `planet` still works out its own surface temperature from `albedo` and
`greenhouse` when its visual is built, so it does not yet read this model or the draw:
that is the later look phase. A `world`'s surface already follows its own `b.climate`.

The home world draws nothing. It keeps `Climate.HOME_INPUTS`, and a preset's `climate`
block is merged into its spec, so its result is the model it always was (`realismcheck`
steps a bare model beside it and compares bit for bit). Its `albedo` describes its look,
not this model's base of 0.22, which is why a home Earth settles near 296 K, not 288 K.

### The draw

An unstated input is drawn once, when the world is created, from the mass, radius and
insolation it has then. Each field has its own stream, hashed from the body's `seed` (or
its name when it has none), the run's `seed=` and the field's name, so the same scenario
always gives the same worlds. Later edits, orbits and mergers do not redraw.

What a world keeps comes from the cosmic shoreline, the empirical divide between
solar-system bodies with and without air, I ∝ v_esc⁴
([Zahnle & Catling 2017](https://doi.org/10.3847/1538-4357/aa7846)). They draw the line by
eye and give no coefficient, so this one is pinned by putting Mars on it (5.03 km/s at
0.43 S⊕, so v₀ = 6.2 km/s), and retention is

    x = log₁₀[(v_esc / 6.2 km/s)⁴ / S]

which gives Mars 0, Venus 0.6, Earth 1.0, Titan 0.5; the Moon −1.7, Mercury −1.5,
Callisto −0.2. Ganymede lands on the line (0.0) with no real atmosphere, so read this as
a boundary a world may lie near, not a verdict on one. S is floored at 10⁻⁴ S⊕.

| World | When | ε | `albedoBase` | `albedoIce` | `mixedLayer`, m |
| --- | --- | --- | --- | --- | --- |
| Ocean | x ≥ 0, S ≤ runaway, with probability 0.9·min(x, 1) | ε(x) ± 0.06 | 0.25–0.35 | 0.3–0.5 | 10–60 (log) |
| Airless | x < 0 | 0.9–1.0 | 0.07–0.25 | 0 | 0.5–3 (log) |
| Thick and dry | S > runaway, x ≥ 0.3 | 0.0089–0.3 (log) | 0.3–0.77 | 0 | 30–300 (log) |
| Thin and dry | the rest | ε(x) ± 0.06, at most 1 | 0.15–0.35 | 0 | 0.5–3 (log) |

Stating `oceans` picks the first row or one of the dry rows without a roll. Runaway is
`Climate.hz_flux("runaway", Teff)` for the brightest star. A world whose T0 is unstated
starts at its warmest balance (`equilibrium_T`), both models together, so a cold world
starts on the frozen branch rather than cooling from 288 K.

Where each number comes from. The ranges around these anchors are choices, made to give
the "a little randomised" the issue asks for, and not fits to a population of planets:

- **ε(x).** Falls linearly from 0.95 at x = 0 (Mars, stated in the preset) to 0.61 at
  x = 1 (Earth), then to 0.45 at x = 2 for a deeper atmosphere (a choice).
- **Venus's ε.** 0.0089 is what balances the [NSSDC](https://nssdc.gsfc.nasa.gov/planetary/factsheet/venusfact.html)
  737 K at albedo 0.77 and 1.91 S⊕: (1 − 0.77)·1.91·340 W/m² / σ(737 K)⁴.
- **Albedos.** NSSDC Bond albedos anchor the rows: Mercury 0.068, Moon 0.11, Mars 0.25,
  Earth 0.294, Venus 0.77. The extra ice albedo brackets North et al.'s 0.32 (coalbedo
  0.697 to 0.38, `sim/ebm.gd`) and this model's existing 0.45.
- **Dry flywheel.** Rock's annual skin depth is √(κP/π) = 3.2 m with κ ≈ 10⁻⁶ m²/s, and
  with ρc ≈ 2×10⁶ J m⁻³ K⁻¹ that is 6.3×10⁶ J m⁻² K⁻¹, 1.5 m of water (assumed typical rock
  values). The range is a factor of about two around it.
- **Venus's flywheel.** 92 bar of CO₂ over 8.87 m/s², with c_p ≈ 1100 J kg⁻¹ K⁻¹ (assumed),
  is 1.1×10⁹ J m⁻² K⁻¹, about 270 m of water, the thick row's upper end.
- **Ocean flywheel.** 10–60 m spans the mixed layers this project's presets already
  state. It is not fitted to an ocean climatology.
- **Bare ε.** 0.9–1 says bare ground radiates close to a black body; it is not fitted to
  a measured regolith emissivity.
- **The 0.9 and the 0.3.** The chance of an ocean and the threshold for a Venus's air are
  choices. The solar system's own bodies do not constrain them. Volatile delivery is not
  modelled.

The solar preset states its six rocky worlds, so nothing there is drawn, and
`realismcheck` compares them with NSSDC: Mercury 432 K (440), Venus 739 K (737), Earth
289 K (288), Moon 270 K (270.4 black body), Mars 212 K (214), each a mean over several
orbits at the J2000 start, with Pluto in its own balance.

### Stepping

The home world and the panel's world step every frame. The others take turns, two a frame
(`CLIMATE_TURNS`), owing their accepted years until then, so every world keeps the same
clock. A world's sunlight is read when it steps, so one that steps less often samples an
eccentric orbit more coarsely. A step costs about 19 µs for an ocean world and 3 µs for
a dry one, which has no latitude model and takes one backward-Euler step solved by Newton,
stable at any frame length.

An ocean world keeps its explicit sub-steps, up to 64 per step. Past that cap, where the
explicit T⁴ term can diverge, a sub-step is implicit in linearised T⁴. No scenario reaches
this on a temperate world (it needs about 30 yr per frame with a 12 m layer). It does at
3.2 yr per frame once a world's ocean has all boiled and it sits against the 1600 K end of
the runaway cap, where the explicit step swung between 25 K and 1530 K and this one swings
between 1230 K and 1600 K. A step across that jump in the outgoing longwave is still not
resolved.

### Not modelled yet

Land thermal inertia differing from ocean on one world, CO₂ cycling (the silicate-weathering
thermostat that would keep an outer world's oceans liquid), tidal locking, internal heat
and any gas composition. A dry world has no ice line, even one with CO₂ caps like Mars's.
