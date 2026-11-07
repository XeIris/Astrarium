# Climate: `sim/climate.gd`

A zero-dimensional energy balance for each rocky or ocean world
([per world](#a-climate-per-world) below),

    C dT/dt = (1 − α(T)) S/4 − OLR(T)

with OLR from the [gas column and its water](#an-atmosphere-with-composition), α rising
with ice cover between 278 K and 233 K (for sea water; [salinity moves both](#water)), and
C the ocean mixed layer's heat capacity. S is the summed flux of every star at the planet's
current distance (`insolation_at`).

## Runaway greenhouse

A wet world's outgoing longwave is capped at 282 W/m², the limit a saturated steam
atmosphere reaches near 300 K and holds until the surface passes ~1600 K
([Goldblatt et al. 2013](https://doi.org/10.1038/ngeo1892)); Kopparapu et al. get 291 W/m²
with their continuum. With today's air the cap binds above 307 K, so an Earth with
α = 0.306 runs away above ~1.19 S⊕; 1D models give 1.06
([Kopparapu et al. 2013](https://doi.org/10.1088/0004-637X/765/2/131)) and 3D models ~1.1.
The cap does not yet move with gravity.

Above the cap the extra flux goes into the ocean, not the mixed layer. A world's water is
its [inventory](#water): Earth's is 2.7×10⁶ kg/m², and boiling it takes 6.1×10¹² J/m²,
10⁵ times what heats a 12 m mixed layer by a kelvin. So at the boiling point the
temperature follows the saturation curve while the ocean evaporates, and the steam
rains back out when the planet cools:

    T_boil = 1 / (1/373.15 K − (R/L) ln(p_dry + steam·m_water·g)),   L = 40.7 kJ/mol, p in bar

(Clausius–Clapeyron at constant L; Earth's whole ocean as steam is 265 bar and 649 K, close
to water's 647 K critical point). An Earth-like world at 1.5 S⊕ boils its ocean in about
three thousand years; a Trisolaris close pass of a few months boils a fraction of a
percent. The latent heat of the vapour below boiling is not in the budget. Once steam
outweighs the dry air the era is "Runaway greenhouse".

## Moist greenhouse and hydrogen escape

Water that reaches the stratosphere is photolysed and its hydrogen escapes, so the
loss is permanent (`Climate.hydrogen_escape`). The cold trap's water mixing ratio is
a log-linear fit through ~3 ppm at 288 K and 3 × 10⁻³ at 340 K, Kasting's (1988)
moist-greenhouse threshold, and is 1 in a runaway. Escape is diffusion-limited,
2.5 × 10¹⁷·(g/g⊕)·f_H m⁻²s⁻¹ with f_H = 2f_H₂O (Hunten 1973; the limit goes as b/H, and H as
1/g), capped by the energy limit ε·F_XUV/(4GMm_H/R) with ε = 0.15 and today's solar XUV,
4.6 mW/m² at 1 AU, scaled with the bolometric flux: 1.6 × 10¹⁵ m⁻²s⁻¹ for Earth. Both use the
world's own gravity and potential. Earth's ocean holds 1.8 × 10³² hydrogen atoms per m²,
and a world's own inventory sets its own, so for Earth:

- today's Earth keeps its ocean for longer than 10¹² years;
- at 340 K it loses it in ~4 Gyr, Kasting's ocean in the Sun's lifetime;
- a runaway escapes at the energy limit and dries in ~2 Gyr at 1.5 S⊕.

Escape is taken from the steam first, then the sea, and recorded as `lost`. The era
reads "Moist greenhouse" while the stratosphere is wet and the sea is still there.
A world with no water left loses the runaway cap, its water bands and its ice, reads as a
dry world and heats to its dry equilibrium. A young or active star's XUV excess, which would
dry a world far faster, is not modelled, and neither is the oxygen the hydrogen leaves behind.

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
WG1 ch. 7). The base albedo and the water bands' fit already include today's clouds.

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
- **Outgoing longwave.** A is pinned so that `A + B·15 °C` equals this world's column's
  emission at 288 K, so the two models agree on a temperate world's mean. Today's air gives
  the same A as the old ε = 0.61, by construction, so today's ice line is unchanged.
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
model keeps its own albedo ramp, which already includes today's caps. That ramp, 0.01
per kelvin over 340 W/m², outruns the column's ~2 W/m²/K, so between 278 K and 233 K the 0-D
model has no stable state: a world that cools to 278 K goes on to freeze, near 0.93 S⊕ with
today's air (the latitude model: 0.90).
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
| `mixedLayer` | thermal flywheel, metres of water; at most the sea's depth | 0.1–5000 |
| `albedoBase` | ice-free Bond albedo; `albedo` stands in for it when unset | 0–1 |
| `albedoIce` | albedo added at full glaciation; with the base at most 1 | 0–1 |
| `pN2`, `pO2`, `pAr` | partial pressures, bar | 0–200, 0–50, 0–50 |
| `pCO2` | partial pressure, bar | 0–100 |
| `pCH4` | partial pressure, bar | 0–10⁻³ |
| `pSO2` | partial pressure, bar; stands for the sulphuric deck it feeds | 0–0.1 |
| `oceans` | whether the world has water to freeze, boil and lose | bool |
| `land` | fraction of the surface above the sea | 0–1 |
| `oceanDepth` | the sea's mean depth, km | 0–100 |
| `salinity` | g of salt per kg of sea | 0–230 |
| `T0` | starting temperature, K; only read when the world is created | 3–5000 |

The gases together may not pass 200 bar. Stating `oceans: true` with `land: 1` or
`oceanDepth: 0` is a contradiction and is rejected; unstated, either simply makes the world dry.

A stated value wins, and an edit is a stated value; setting one to null returns to the
draw. An edit naming only these fields keeps the body's visual and structure, so a
slider cannot disturb a tracked spin. `land` and `oceanDepth` also draw the surface, and
reach it as uniforms; `albedo` draws its colours and rebuilds them.

`greenhouse`, the single ε this model used to take, is gone: a preset's `climate` block
naming it is rejected as an unknown input, and it does nothing on a body's spec.

A world draws what its climate says ([the look follows](#the-look-follows)).

The home world draws nothing. It keeps `Climate.HOME_INPUTS`, today's Earth: NSSDC's air, the
3.7 km sea and albedo 0.306. A preset's `climate` block is merged into its spec (`realismcheck`
steps a bare model beside it and compares bit for bit, and holds a home Earth to NSSDC's
288 K and the 72° ice line). Its `albedo` describes its look; `albedoBase` is what this model reads.

#### Trisolaris's CO₂

The `trisolaris` preset states `pCO2: 0.12`. **That is an authored choice**, not a derivation: the
owner chose it so the long run matches the preset's blurb, "temperate seasons and cold spells".
On today's air, at this world's mean of 0.86 S⊕, 200 years are 99% Deep Freeze. With this CO₂:

| 200 years | Mean | Range | Temperate | Cold | Hot | Deep Freeze |
| --- | --- | --- | --- | --- | --- | --- |
| The single ε (PR 48) | 231 K | 223–301 K | 1.9 yr | 70 yr | 0 | 128 yr |
| Today's air | 195 K | 188–288 K | 1.0 yr | 1.0 yr | 0 | 198 yr |
| **0.12 bar** | **286 K** | **268–310 K** | **167 yr** | **26 yr** | **7 yr** | **0** |

It plays warmer than the single ε did: that model's deep freezes are gone by choice. Its first
35 years read 284 K, 29 temperate and 6 cold, and `realismcheck` holds them.

The climate flips between a lasting freeze and none, so the value is chosen clear of the edge:

| `pCO2`, bar | 0.08 | 0.10 | 0.105 | 0.11 | 0.115 | **0.12** | 0.125 | 0.13 | 0.14 | 0.15 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Mean over 200 yr, K | 205 | 210 | 233 | 284 | 285 | **286** | 287 | 287 | 288 | 289 |
| Deep Freeze, yr | 186 | 175 | 119 | 0 | 0 | **0** | 0 | 0 | 0 | 0 |
| Cold, yr | 5.6 | 9.2 | 22 | 37 | 30 | **26** | 21 | 17 | 9.0 | 1.5 |

Above the flip the result is steady: half to four times the frame length gives 166–168 temperate
years, and restarting the climate 10 to 100 years into the orbit gives 166–168. What it does not
survive is a world that is already frozen, or one that cools too fast. Starting at 275 K or
300 K changes little, but from 260 K or 240 K it never thaws (199 and 200 of 200 years frozen,
the snowball's hysteresis). The flywheel matters as much: at 12 m the world dips to 268 K and comes
back before the ice-albedo feedback takes it; at 6 m it does not (197 years frozen), and at 24 m or
more it never leaves the temperate band. So the panel's mixed-layer slider can freeze this world
for good, and its reset button is the way back.

Other Trisolaris presets state no CO₂ and take today's air.

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

| World | When | `albedoBase` | `albedoIce` | `mixedLayer`, m | Air, bar |
| --- | --- | --- | --- | --- | --- |
| Ocean | x ≥ 0, S ≤ runaway, with probability 0.9·min(x, 1) | 0.25–0.35 | 0.3–0.5 | 10–60 (log) | N₂ 0.3–3 (log), O₂ 0–0.3, Ar 0.5–2% of N₂, CH₄ 10⁻⁷–10⁻⁵ (log), CO₂ [from the weathering balance](#the-draw-of-co) |
| Airless | x < 0 | 0.07–0.25 | 0 | 0.5–3 (log) | none |
| Thick and dry | S > runaway, x ≥ 0.3 | 0.3–0.77 | 0 | 30–300 (log) | CO₂ 10–100 (log), N₂ 1–5% of it, SO₂ 10⁻⁵–0.03 (log) |
| Thin and dry | the rest | 0.15–0.35 | 0 | 0.5–3 (log) | CO₂ 0.006·10^(1.5x)·(0.3–3, log), at most 1; N₂ 3–50% of it |

Every world also draws `land` (one in ten none, the rest 0.05–0.7), `oceanDepth` (0.5–10 km,
log) and `salinity` (5–60 g/kg): they wait unread on a dry world until `oceans` is edited on.
Each is an independent stream, so the phase-one fields are where they were
(`realismcheck` pins three of them).

Stating `oceans` picks the first row or one of the dry rows without a roll. Runaway is
`Climate.hz_flux("runaway", Teff)` for the brightest star. A world whose T0 is unstated
starts at its warmest balance (`equilibrium_T`), both models together, so a cold world
starts on the frozen branch rather than cooling from 288 K.

Where each number comes from. The ranges around these anchors are choices, made to give
the "a little randomised" the issue asks for, and not fits to a population of planets:

- **Thin air.** Mars's 6 mbar of CO₂ on the shoreline, growing tenfold per 0.67 of x, is a
  choice; x says only what a world can keep, not what it has.
- **Thick air.** Spans up to Venus (89 bar of CO₂, 150 ppm of SO₂); the lower ends are choices.
- **Ocean air.** N₂ brackets Earth's 0.8 bar, O₂ its 0.21, CH₄ its 2 ppm. Choices.
- **Sea.** `land` brackets Earth's 0.29, `oceanDepth` its 3.7 km, `salinity` its 35 g/kg. Choices.
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
- **The 0.9 and the 0.3.** The chance of an ocean and the threshold for a Venus's air are
  choices. The solar system's own bodies do not constrain them. Volatile delivery is not
  modelled.

#### The draw of CO₂

There is no live CO₂ cycle: a world's CO₂ is an input and stays what it is. But an ocean
world's silicate weathering would have settled it long ago at whatever keeps the sea from
freezing ([Kopparapu's working hypothesis](https://doi.org/10.1088/0004-637X/765/2/131) for
the whole outer habitable zone), so the draw takes that settled state: the CO₂ that balances
the drawn albedo and the world's sunlight at a surface temperature drawn from 278–295 K, up to
8 bar. Thus a 0.6 S⊕ ocean world draws about 1.3 bar and stays liquid, and past the limit
one freezes. Stated or edited CO₂ is not corrected, so an edit can freeze a world for good,
and a world whose orbit changes keeps the CO₂ it drew; the live cycle is not modelled.

The solar preset states its six rocky worlds' air, sea and flywheel, so nothing there is drawn
but the Moon's and Mercury's emptiness, and `realismcheck` compares them with NSSDC: Mercury
432 K (440), Venus 738 K (737), Earth 290 K (288), Moon 270 K (270.4 black body), Mars 213 K
(214), each a mean over several orbits at the J2000 start, with Pluto in its own balance.

### Stepping

The home world and the panel's world step every frame. The others take turns, two a frame
(`CLIMATE_TURNS`), owing their accepted years until then, so every world keeps the same
clock. A world's sunlight is read when it steps, so one that steps less often samples an
eccentric orbit more coarsely. A step costs about 21 µs for an ocean world and 3.2 µs for
a dry one (19.4 and 2.9 on the single ε), which has no latitude model and takes one backward-Euler step solved by Newton,
stable at any frame length.

A dry world's backward-Euler step takes 4·OLR/T as its slope: a little above the true one, so
it converges in a few iterations, and it reaches the column's balance at any step length
(`realismcheck` lands Venus's, Mars's and dense CO₂'s, down to the condensation floor).

An ocean world keeps its explicit sub-steps, up to 64 per step. Past that cap, where the
explicit T⁴ term can diverge, a sub-step is implicit in linearised T⁴. No scenario reaches
this on a temperate world (it needs about 30 yr per frame with a 12 m layer). It does at
3.2 yr per frame once a world's ocean has all boiled and it sits against the 1600 K end of
the runaway cap, where the explicit step swung between 25 K and 1530 K and this one swings
between 1230 K and 1600 K. A step across that jump in the outgoing longwave is still not
resolved.

### Not modelled yet

Land thermal inertia differing from ocean on one world, live CO₂ cycling and CO₂ collapse (a
cold world's air stays in the air), tidal locking and internal heat, so an ice shell's ocean
is only an inventory. A dry world has no ice line, even one with CO₂ caps like Mars's.

### What the editor shows

The Foundry and the live editor share one set of controls (`CompositionEditor`): a mix, the
pie, a row per gas, the sea and the surface, and what the model expects. `Composition` holds
the mixes. The expectation is `Climate` itself on a scratch `Body`, built by the same
`ClimateInputs.build` a spawn runs and stepped with the stars where they are, so there is no second
formula and nothing on the stage is written.

- **The horizon.** 28 geometric steps from 0.02 years to 100 years, or six radiative times if the
  column is slower. Fixed steps keep its cost fixed: about 3 ms. `compositioncheck` runs the real
  stage for the same 100 years on a real orbit and lands within 1.5 K for an Earth, a dry rock, a
  global ocean, an ice shell, Mars's and Venus's air, a seeded draw and a 0.012 M⊕ world (largest
  gap 1.0 K).
- **A live world.** It forks the world's climate, temperature, ice and water included, so a
  snowball's hysteresis is the world's own. Applying an edit is immediate; the panel says where it is heading.
- **Where it would go.** A spawn's bearing, spread and seed are decided before the preview, and
  `place_spawn` is given them, so the sunlight it reports is the sunlight it gets. The Orbit row
  sets the distance; spawning at rest uses the point in front of the camera.
- **Limits.** A patch goes through `Structure.input_error` first. One outside the domain shows its
  reason in the panel and changes nothing, slider or typed.

The no-air balance is `278.6·(S(1 − α))^¼` with the present albedo, ice included, and greenhouse is
the surface less that. A world under the [cosmic shoreline](#the-draw) with air gets a note, not a
rejection: the model holds its gases fixed (see [not modelled](#not-modelled-yet)).

#### The pie

A pie is linear and these pressures are not: Earth's CO₂ is 0.042 % of its air, about 0.15° of pie,
and its CH₄ under 2 ppm. So:

- Every gas has a legend row with its pressure and share, and under it a bar on a log scale from
  10⁻⁹ bar to the 200 bar limit.
- A slice thinner than a pixel on the rim (1.15° at 50 px) is a tick rather than a slice.
- The inner ring shows the gases under 1% among themselves, so CO₂ against CH₄ is still a shape.
- Water is hatched, because it is not an input: its share follows the temperature through
  Clausius–Clapeyron, against the world's inventory (`Climate.vapour_bar`), with steam on top.
- A legend's filled square is a stated gas and a hollow one was drawn from the seed.

The strip under it is the globe: land, open sea and ice.

## An atmosphere with composition

`Atmosphere` (`sim/atmosphere.gd`) takes partial pressures and the world's gravity and returns
the outgoing longwave, the column's mean mass and what it scatters. Water is not an input: it
follows temperature through Clausius–Clapeyron, against the world's own inventory.

### Outgoing longwave

A spectrum in three parts, each from its own physics, evaluated at an emission temperature
that a grey continuum sets:

    T_r = T · (1 + Dτ)^(−κ/2),     Dτ = (K_CO₂·pCO₂ + K_SO₂·pSO₂)·p/(g/g⊕)
    OLR = σT_r⁴ (1 − f_CH₄)  −  Δν_CO₂ · π[B₆₆₇(T_r) − B₆₆₇(0.745·T_r)]  −  W·(1 − w)·σ[T_r⁴ − T_v⁴]₊

- **The grey continuum.** A radiative-convective column emits from the level where its optical
  depth reaches unity. With τ ∝ p² (collisional) and a dry adiabat of exponent κ = R/c_p, the
  surface sits (τ)^(κ/2) above that level, and the `1 +` carries it smoothly to a thin column's
  surface emission. κ is the mixture's; CO₂ takes 0.2, its value near 400 K (it runs from
  0.24 at 250 K to 0.16 at 735 K). Thin columns have no continuum at all: Earth's Dτ is 2×10⁻⁴.
- **The CO₂ band.** Absorption falls exponentially from 667 cm⁻¹, so a band saturates and widens
  logarithmically: Δν = 2l·ln(1 + x/x₀), x = pCO₂·p/(g/g⊕). This is why forcing goes as ln C,
  and the same formula spans Mars to Venus. π·B₆₆₇ is the Planck flux at the band's centre,
  and the band's core radiates from a stratosphere at 0.745·T_r (Earth's 214.7 K over 288.15 K).
- **CH₄.** Myhre's √ term, 0.036·√(ppb) W/m², at today's Earth, scaled with σT_r⁴. It has no overlap with
  N₂O, which is not an input.
- **Water.** At fixed relative humidity the vapour's emission level holds its temperature as the
  surface warms (Simpson's law), so a share 1 − w of the Planck flux radiates at a fixed T_v, the
  temperature where the vapour reaches 50 Pa·(g/g⊕)/(p/bar), and only the window w follows
  the surface. Colder than T_v, the bands are open. W says how much water there is to close them:
  the inventory against the ~3 kg/m² that does, reduced further when under 10% of the surface is sea.
- **The floors.** Nothing radiates less than the band's core does. A sky of at least 1 bar of
  CO₂ stops at 65 W/m²: Kopparapu's Fig. 5a levels out there near 10 bar at 273 K, once the air is
  opaque at every infrared wavelength. It is that one curve's value, used at any temperature.
- **Runaway.** A wet world's cap above still applies.

### Where the constants come from

Four constants are fits and each uses up one measured number. **So Earth's, Mars's and Venus's
temperatures do not test this model; they calibrate it.** `realismcheck` keeps them as checks
because they catch a column or constant that moves.

| Constant | Value | Set by |
| --- | --- | --- |
| 2l | 18.87 cm⁻¹ | −5.35 W/m² per e-fold of CO₂ at today's Earth (Myhre et al. 1998, as [quoted by lowEBMs](https://lowebms.readthedocs.io/en/latest/code/functions_code/forcing.html); 3.7 W/m² per doubling) |
| x₀ | 8.47×10⁻⁷ bar² | Mars at [NSSDC's](https://nssdc.gsfc.nasa.gov/planetary/factsheet/marsfact.html) 214 K: (1 − 0.25)·586.2/4 W/m² |
| K_CO₂ | 0.45 bar⁻² | closest fit of one exponent to Kopparapu's Fig. 5a and 2 bar case below |
| K_SO₂ | 2.56×10⁴ bar⁻² | Venus at [NSSDC's](https://nssdc.gsfc.nasa.gov/planetary/factsheet/venusfact.html) 737 K: (1 − 0.77)·2601.3/4 W/m² |
| T_v's 50.1 Pa, w = 0.453 | | OLR(288.15 K) = 0.61σT⁴ (today's ice line) and dOLR/dT = 2.09 W/m²/K (North, Cahalan & Coakley's B) |

What was not fitted, and so does test it:

| Test | This model | Reference |
| --- | --- | --- |
| 2 bar of CO₂ on a Mars, 250 K | 82 W/m² | 86 (Kopparapu) and 88.4 (SMART), [their §2.2.1](https://arxiv.org/abs/1301.6674) |
| 273 K, wet, over 1 bar of N₂, CO₂ at 1 / 3 / 10 / 35 bar | 138 / 102 / 65 / 65 W/m² | 112 / 88 / 67 / 65, read off their Fig. 5a |
| Removing Earth's CO₂ | +33 W/m² | no number could be verified |
| Venus's emission level | 0.46 bar | inside the 0.04–1.4 bar its VIRA column gives the deck at 70–48 km (heights assumed) |
| Without its SO₂, Venus's balance | 585 K | below the 737 K it has: the deck is doing real work |
| Mean molecular mass, Earth / Venus / Mars | 28.97 / 43.45 / 43.50 g/mol | NSSDC 28.97 / 43.45 / 43.49 |
| Scale height and density of today's Earth in flight | 8.4 km, 1.23 kg/m³ | NSSDC 8.5, 1.217 |

`tools/physcheck.sh`'s climate rows now differ from the frozen web build, which still has the
single ε. That report is telemetry and the difference is this section.

So in dense CO₂ this model runs up to 25% from a line-by-line one, worst at 1 bar. Its
place is a game's panel, not a paleoclimate. Sources it could not open: the TAR's own Table 6.2
and the PNAS text of Koll & Cronin (2018, the linear OLR) both refused the fetch; 0.036 for CH₄
is the form the issue names, and NOAA's [AGGI](https://gml.noaa.gov/aggi/aggi.html) lists the
newer Meinshausen fit, about 0.039 at today's CH₄, close enough to leave.

### Domain

`ClimateInputs.DOMAIN` rejects what the fits have no claim to, before any spawn, edit or preset
changes anything: CO₂ past 100 bar (Venus's 89 is inside), the gases past 200 bar, CH₄ past
10⁻³ bar (Myhre's term was built for today's ppm), SO₂ past 0.1 bar. Temperature is not
rejected, since a world's T is state: OLR is meant for 150–800 K and is merely finite outside
it. Not represented at all: H₂-rich air (its CIA is what warms Titan and a young Mars), so Titan
and giants are out of this model; CO₂ clouds; and Rayleigh's effect on albedo (dense CO₂ should
brighten a world, which is what makes Kopparapu's maximum greenhouse a maximum; here it is the
draw's 8 bar limit and `albedoBase`).

### What the column looks like

The Rayleigh optical depth at 550 nm is τ = σ̄·p/(m̄g), with each gas's cross section worked out
from He et al. (2021, [Table 1](https://doi.org/10.5194/acp-21-14927-2021))'s refractive index
and King factor: N₂ 4.63, O₂ 4.05, CO₂ 11.6, CH₄ 9.9 (×10⁻²⁷ cm²); Ar takes N₂'s and SO₂ takes
CO₂'s (neither sourced); water 3.7, scaled from Kopparapu's 2.6 at 600 nm. CO₂ against air comes
to 2.6, Kopparapu's "2.5 times". That gives Earth 0.097, Mars 0.0027, Venus 16.

`Atmosphere.limb` turns that into what `rocky_atmosphere.gdshader` takes. Per primary (680, 550,
440 nm), the limb's brightness goes as 1 − exp(−mτ_λ) with τ_λ ∝ λ⁻⁴, each relative to Earth's
column since the shader's β already carries λ⁻⁴: `uThick` from green, `uTint` from the others.
So today's Earth is 1 and white, exactly as it was drawn; m = 5.27 air masses puts Venus's 16 at
the 2.4 it was authored at. A thin sky goes blue; a thick one saturates towards white. Steam
counts. A `planet` with `atmosphere` unstated grows a shell once `uThick` passes 0.01.

Stated `atmColor`/`atmThick` still win, and two presets keep them because the gas column does
not make their skies: Mars's is dust (its gas alone gives `uThick` 0.035 against its stated
0.22) and Venus's colour is sulphuric (its depth is now derived). There is no dust input.
Without one Mars cannot go further, and adding one is the look phase's call.

In flight, `Rocketry.flight_env` gives an uncatalogued world `Climate.flight_atmosphere()`:
that column at its present temperature, isothermal, with γ and M from the mixture, its tint moved
by the limb's and the sky dome's `uThick` from τ (Earth's column is 1.0; the grey path previously read ρ₀).
This replaces the Jeans-test guess for any world with a climate, so its drag changes too. A
catalogued atmosphere is measured and stays, whatever is edited on the body.

## The look follows

`ClimateLook` turns a `Climate` and its spec into uniforms, and `Binder` eases them on (time
constant 0.6 s, written only when they move). Both visuals take the same values. A value a preset
states wins, since a preset states what cannot be derived. Visual updates read the climate and
never write it, or mass, position or velocity.

| What | From | Source, or what kind of choice |
| --- | --- | --- |
| Ice caps | `cl.ice`, the larger of the 0-D ramp and the latitude model | Draws within 1° of the model's ice line at today's Earth (71.4°, 71.8°) |
| Cloud cover | `cl.clouds`, the humidity rule; a deck over any air with SO₂; steam | The rule stays visual ([Clouds](#clouds)). The deck's optical depth of ~30 at Venus's column is an estimate from its opaque deck |
| Sea level | `ocean`, falling from the datum towards the abyssal plain as water leaves | Mass balance, linear in depth (a choice); none once the climate reads dry |
| Land and depth | `cl.land`, `cl.ocean_depth` | A wet world's own. A dry world keeps the crust it was built with |
| Desert | `uArid`, what the sea cannot supply, or heat | `√(sea share / 0.71)` is an estimate. The heat rule is the old one |
| Vegetation | `uBiota`, Miami NPP at the world's temperature and land rain, against today's | Lieth 1975, coefficients as tabulated by [Adams et al. 2004](https://bio-math10.biology.kyushu-u.ac.jp/~ben/adams_et_al_2004.pdf). The heat limit (323–348 K) is an estimate |
| Frost | sea water's freezing point; CO₂ `3182.48/(23.3494 − ln p_mbar)` (James et al. 1992, as used by [Greve et al. 2010](https://arxiv.org/abs/0903.2688)); else N₂'s 37 K | Nothing to frost on an airless world |
| Sky and limb | `cl.sky`, Rayleigh from the column | [What the column looks like](#what-the-column-looks-like) |
| Haze | `0.45 × uThick` up to 1.3 | Earth's old constant; the slope is a choice |
| Craters | fade between 1 mbar and 0.1 bar of air | Estimates |

Rain, which sets vegetation, is `990 mm × min(e^(0.02ΔT), e^(0.07ΔT)) × supply`, capped at what the
sunlight can evaporate (`L·P ≤ (1 − α)S/4`). Near today's Earth precipitation follows the energy
budget at 2 %/K while vapour goes at 7 %/K ([Held & Soden 2006](https://doi.org/10.1175/JCLI3990.1),
[Allan et al. 2014](https://doi.org/10.1007/s10712-012-9213-z)), so 2 %/K warming, and vapour's
7 %/K below today, where it binds. The 990 mm and land's 715 mm are Wikipedia's global means;
L·P there comes to 71 W/m², inside the 65–80 W/m² energy budgets give, and that is not fitted.

`lookcheck` also tests Miami against [Whittaker & Likens's ranges](https://www.taylorfrancis.com/chapters/mono/10.4324/9780203392843-13/soils-nutrient-limitation-tropical-ecosystems-martin-kellman-rosanne-tackaberry)
(tropical forest 1000–3500, temperate 600–2500 g/m²/yr) and CO₂'s frost point at 1 atm (dry ice, 194.7 K).

**Not done.** Mapped worlds keep their map's coast. A dry world has no ice line of its own and no dust.
Ocean colour does not read chlorophyll. There is no CO₂ cap on a dry world but its seasonal frost.

## Water

A world's water is one inventory, `m = ρ·oceanDepth·(1 − land)` kg/m², with ρ = 1025 kg/m³;
Earth's 3.7 km and 29% come to 2.7×10⁶ kg/m². `ocean + steam + lost = 1` are fractions of it,
and everything that used Earth's constants uses it instead: the steam's pressure is `steam·m·g`, the
latent heat `m·L`, the hydrogen `m·2N_A/M`. A tenth of the water boils ten times the faster, under
a tenth of the pressure, about 150 K cooler at the top of the curve.

Water vapour and the sea set each other through it:

- **The vapour's column** is 0.19 of the saturated column, an assumed share that gives Earth's
  ~25 kg/m² at 288 K. A world holding less than that has no standing water at that temperature:
  it reads as dry, draws no ice and only partly closes the water bands, until it is cold enough for
  frost to stand. The state is still `ocean`: nothing is transferred, as the column is ~10⁻⁵ of a real sea.
- **The boiling point** rises with the steam the sea has made, from the dry air's own pressure.
  Thin air boils low, and the vapour raises the pressure it boils at, as `realismcheck` follows.
- **Open water.** Below 10% sea the sky dries in proportion (humidity and water bands). The 10% is a
  choice: land planets lose their water greenhouse at some coverage, and this is one line for it.

### Salinity

Sea water's freezing point is UNESCO's fit (Millero 1978), T_f = −0.0575 S + 1.710523×10⁻³ S^1.5 −
2.154996×10⁻⁴ S² °C, S in g/kg at 1 atm: −1.92 °C at 35. It is fitted to 40 g/kg and extrapolated
from there; the domain stops at 230, near NaCl's eutectic, where it says −18.7 °C against the
measured −21 °C. The coefficients are transcribed, not re-checked against the UNESCO paper; the 35 g/kg value
is the one the issue states. Everything that says when ice forms moves by T_f − T_f(35): the
albedo's 278 K onset and 233 K end, the eras' 273 K and 233 K, and `LatitudeEBM.t_ice`. So sea water
changes nothing, fresh water freezes 1.9 K earlier, and brine holds off 17 K.

Boiling-point elevation, a brine's lower heat capacity and the sea's density are not modelled.

### States

| State | How a world reaches it | Era |
| --- | --- | --- |
| No ocean | `oceans: false`, `land: 1`, `oceanDepth: 0`, or all of it lost; or too little to stand | Dry world |
| Global ocean | `land` below 0.05, temperate | Global ocean |
| Ice shell | `land` below 0.05, frozen to the equator | Ice shell |
| Continents | otherwise | Stable, Chaotic, Moist, Scorching or Deep Freeze by temperature |
| Steam | steam outweighs the dry air | Runaway greenhouse |

The panel names the era and shows the air's pressure and the sea's depth and salinity. An
ice shell's ocean is an inventory: without internal heat nothing says it is liquid underneath.
