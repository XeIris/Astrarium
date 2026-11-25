# The surface: `sim/surface/`, `sim/planet_relief.gd`, `sim/planet_pin.gd`

What a world is like at one point on it. All of it runs only while someone stands there, or while a vessel comes
down on a dry mapped world ([the ground under a landing](#the-ground-under-a-landing)). It reads
the world's gravity, air, water and temperature, and it writes nothing back: the global energy
balance and the N-body physics do not know it exists (`surfacecheck` proves both). SI throughout.

## The pin

`PlanetPin` draws a latitude and longitude uniform on the sphere, from a hash of the world's seed,
the run's `seed=` and the pin's number, so the same scenario always gets the same sequence.

It reads what is there from what the planet draws. `PlanetRelief` is the CPU half of
`terrain.gdshaderinc`, and `pincheck gpu=1` renders the shader's height at 8192 random points and holds the
two to each other: a mean difference of 0.0 m, a worst of 2.8 m, and no disagreement about sea and land. It also
reads 600 pixels of the real planet in the frame, and 598 agree.

To make that possible the rocky surface's noise uses an integer lattice hash, PCG3D ([Jarzynski &
Olano 2020](https://jcgt.org/published/0009/03/02/)), rather than `fract(sin(x)·43758)`: a GPU's `sin` cannot be
reproduced on a CPU, and at that multiplier an error of one part in 10⁶ moves the result by 0.04. `Vector3` is
float32, as the shader is, so high octaves round alike. Cloud decks, giants and rings keep their hash. A world filling
the frame costs the same either way, about 6.5–7 ms a frame on an M-series Mac.

This re-rolled the geography of every unmapped rocky world once. Its statistics stayed: over 40 seeds the fBm has a
mean of 0.492 and an sd of 0.110 against the 0.497 and 0.1065 `Terrain.crust_threshold` assumes, and asking for 29%
land gives 28.9%.

The crust's seed is a hash of the world's name, nudged by its spec's `seed`, so a world has the same ground every
time it is loaded. A body id would not do that, because it counts every spawn since the start.

The climate's part comes from `ClimateLook.targets` (`PlanetRelief.of_body`), not from the material. A material eases
over 0.6 s, and an undrawn stage (`ff=`, the checks) never updates it. Only the static uniforms are read off the
material: seed, relief, plate scale, insolation and transport. Temperature falls with height at the world's own rate
(`uLapse`): 0.66 g/c_p on a wet world, 0.4 g/c_p on a dry one, nothing without air. The shader takes the same uniform.
Height for the lapse counts from the sea where there is one, otherwise from the datum, and it may be negative: a basin
below a dry world's datum is warmer than the datum.

A pin does not hunt for land. It says what it found: open sea and how deep, sea ice, an ice sheet, or the biome and
its height. On Earth it falls on land about 29% of the time, as it should. **A mapped world** (Earth, Mars, the Moon)
keeps its map's coast, and its height is measured.

### Measured height

`PlanetElevation` reads a quarter-degree grid per world, built by `tools/build_planet_relief.py`: ETOPO 2022's
60″ ice surface averaged in 15×15 blocks (Earth, metres above sea level), and the MOLA MEGDR and LOLA LDEM at their
own 4 per degree (medians, above the areoid and the 1737.4 km sphere). A cell is 28 km on Earth, 15 km on Mars and
7.6 km on the Moon, which is what a pin reads and what the far grid stands on. The roughness, rivers and craters
below are drawn on top of it. Io keeps the crust, and its panel still says so.

The map's coast is finer than a cell. Where the map has both land and sea within a cell of the pin and the cell averages
to the other side, the pin keeps the map's side by 5 m, and the far grid bends to it under a Gaussian one cell wide.
Away from a coast the cell stands as measured, so inland ground below the sea reads below it: the Qattara Depression
72 m, the Caspian lowland 14 m. On a map the sea in view is where the map has sea across the far grid, not wherever
the ground is low. Inside a grid that does see the sea, dry land below sea level (a polder, a depression near a
coast) is still drawn under the water plane.

What tests it, each against a height surveyed elsewhere and each catching a different misreading:

| Test | Grid | Reference |
| --- | --- | --- |
| South Pole (rows flipped) | see `pincheck` | 2835 m, Amundsen–Scott |
| Greenland's summit, 72.58° N 38.46° W (east for west) | see `pincheck` | 3216 m, Summit Station |
| Lake Titicaca | see `pincheck` | 3812 m |
| Mean ocean depth, area-weighted (units) | see `pincheck` | 3682 m (Charette & Smith 2010) |
| Land above sea level | see `pincheck` | 29.2% |
| Earth's highest cell | see `pincheck` | beside Everest, below its 8848.86 m |
| Mars's highest cell (the 0° E start) | 21134 m, 1.3° from the centre | Olympus Mons, 21.287 km at 18.65° N 226.20° E |
| Mars's lowest cell | −8068 m at 32.9° S 62.1° E | in Hellas, below its floor's 7152 m |
| The Moon's highest cell | 10504 m, at the summit's cell | 10.786 km at 5.441° N 158.656° W |
| The Moon's lowest cell | −8879 m, at the pit's cell | Antoniadi's pit, 9.178 km down at 70.43° S 187.42° E |

A summit reads below its peak because a cell is a mean or a median over its quarter degree.

## Terrain

`SurfaceRelief` builds a far grid (60 km half-width, or 8% of a small world's radius) and a near one
(3.2 km), in the form `SiteScene` reads.

1. **The true crust,** 21×21 samples of `PlanetRelief` across the far grid, or of the measured grid on a mapped
   world. A crust sample costs 0.5 ms in GDScript and the shader's highest octave is about 40 km on an Earth, so this
   is what is resolved.
2. **Roughness that goes as 1/g.** Rock strength over ρg caps relief: Olympus Mons's 21.9 km against
   Everest's 8.8 km is 2.5, and the gravity ratio is 2.6
   ([table](https://en.wikipedia.org/wiki/List_of_tallest_mountains_in_the_Solar_System)). `surfacecheck` holds the
   local relief to that ratio. Its ±450 m on Earth (`ROUGH_M` 900 m, half of it either way) is itself an estimate.
   A world that states its relief (`landRelief`, km from the datum to its highest rises; the crust's default is
   3.2) scales its roughness with that instead: the statement already holds what strength and erosion made of it.
   Titan's 1 km (Corlies et al. 2017 keep it within about ±2 km of its geoid, its mountains under 700 m) gives
   it under a third of Earth's roughness, where 1/g alone would give it four times.
2a. **Dunes,** on a world that states a dune field (`dunes`: Titan's equatorial sand seas). Linear ridges of a
   stated height and width, a stated spacing apart along a stated bearing, meandering a little (a twelfth of a
   wavelength's noise), with flat interdunes between. They thin out over the outer third of their latitude band
   and stay out of a sea. Only a grid with six cells or more to a spacing carries them: the near grid's 6 km about
   a landing, not the far grid's 1 km cells. Titan's: 120 m high, 1 km wide, 3 km apart, along 80° within 30° of
   the equator, a choice inside Lorenz et al. (2006) and Radebaugh et al. (2008): 100–150 m, about 1 km, 1–4 km,
   roughly east–west.
3. **Rivers,** where anything flows: the stream-power law,

       dz/dt = U − K A^m S^n + D∇²z,     m = 0.5, n = 1

   solved by backward Euler along the flow order, `z = (z + F z_r)/(1 + F)` with `F = K A^m Δt/Δx`, which is
   stable at any step ([Braun & Willett 2013](https://doi.org/10.1016/j.geomorph.2012.10.008); the paper
   refused the fetch, so this is derived directly, not transcribed). m/n ≈ 0.5 is the concavity rivers show
   ([stream power law](https://en.wikipedia.org/wiki/Stream_power_law), observed 0.35–0.7). Pits are
   filled first (Barnes et al. 2014, the priority-flood, from memory of the method).
4. **How a world enters K.** Specific stream power is `ω = ρ g Q S / W`
   ([Oskin et al. 2014](https://escholarship.org/content/qt9c08699j/qt9c08699j.pdf), after Howard 1994), so K goes with g, and with discharge's
   rain, `K = K⊕ (g/g⊕)(P/P⊕)^m`. P comes from the climate ([the look follows](climate.md#the-look-follows)).
   K⊕ = 2×10⁻⁶ m⁰ yr⁻¹ is an estimate: about 1 mm/yr at 100 km² on a 5% slope. The sources that give fitted
   values refused the fetch.
5. **Creep.** D = 5×10⁻³ m²/yr, inside the field range of 10⁻³–10⁻² (MIT 12.163's notes, after Dietrich and others).
   A dry world's 10⁻⁴ is an estimate.
6. **Craters,** on a world where nothing erases them: bowls and rims with N(>D) ∝ D⁻². The exponent is
   the usual one for production populations, and no page read stated it, so treat it as an estimate, as are the
   density and the depth-to-diameter of 0.2.

What tests it. These do not come out of any constant here:

| Test | This model | Reference |
| --- | --- | --- |
| Hack's exponent, L ∝ A^h | 0.64 over 2538 cells | [slightly under 0.6](https://en.wikipedia.org/wiki/Hack%27s_law) |
| Steady slope–area exponent | −0.501, within 1.1% of S = (U/K) A^(−m/n) | the law's own analytic steady state |
| Bifurcation ratio | 4.0 (163 : 41 : 10 streams) | [3–5 in British rivers](https://en.wikipedia.org/wiki/Strahler_number) |
| Relief on Mars's gravity / Earth's | 2.65 | 2.5 (Olympus Mons / Everest) |

**On a measured dry world** (the Moon, Mars; `SurfaceRelief.HURST`), steps 2 and 6 change: the relief a measured
cell already holds is not drawn again. The cell's own roughness at its scale is read off the grid: the RMS height
difference between neighbouring cells over a 7 × 7 patch about the pin. It is carried below the cell by fBm whose
octaves fall by 2^−H, and calibrated on each grid at two cells' lag to ν(ℓ) = ν_cell (ℓ/L_cell)^H, counting what the
grid already holds. Craters are capped at half a cell. H is 0.85 for the Moon, between Rosenburg et al. 2011's LOLA
medians of 0.76 (maria) and 0.95 (highlands). For Mars it is 0.80, an estimate inside Orosei et al. 2003's H > 0.5.
Earth keeps the gravity-scaled roughness, which its rivers carve.

| Test (`groundcheck`) | This model | Reference |
| --- | --- | --- |
| Median slope at 50 m, Mare Tranquillitatis | 0.96° | 2.0° at 17 m (LOLA), about 1.5° at 50 m by H = 0.76 |
| Median slope at 50 m, farside highlands | 5.9° | 7.5° at 17 m, about 7.1° at 50 m by H = 0.95 |
| Highlands over maria | 6.1 | 3.8 at 17 m |
| A site's height at its pin against its measured cell | −1 to 112 m, inside 3 ν_cell | before: 0.8–1.2 km |

Not modelled: lakes as water (a filled pit drains through its spill), glaciers, sediment deposition, lithology,
tectonic uplift during the run (the crust's relief stands in for what it built).

## Oceans

A site has a sea only where one can be seen: under a pin at sea, or where the far grid's ground falls below sea level.
Inland, the waves and tide rows go from the panel. The disc drops with the ball's curve as the terrain does, about
640 m at 90 km on Earth. It runs past the far grid only when the pin is at sea, since beyond the grid nothing says
where the coast is. Whether it freezes is the sea's own temperature at its level, not the ground's.

A spectrum, then wave trains, as `ocean.gdshader` sums them.

- **Spectrum.** JONSWAP (Hasselmann et al. 1973), as [Stewart §16.4](https://geo.libretexts.org/Bookshelves/Oceanography/Introduction_to_Physical_Oceanography_(Stewart)/16%3A_Ocean_Waves/16.4%3A_Ocean-Wave_Spectra) gives it:
  `S(ω) = αg²/ω⁵ exp[−(5/4)(ω_p/ω)⁴] γ^r`, with `α = 0.076(U²/Fg)^0.22`, `ω_p = 22(g²/UF)^⅓`, γ = 3.3. A sea
  cannot grow past fully developed, Pierson-Moskowitz's `H_s = 0.22 U²/g`, so α and ω_p are floored there.
- **The world's own g** is in every term. Air and liquid density change how fast waves grow and not how
  high they end, as [Lorenz & Hayes 2012](https://doi.org/10.1016/j.icarus.2012.03.002)'s abstract says. This
  is why only g appears.
- **Dispersion.** `ω² = (gk + σk³/ρ) tanh(kh)` ([Wikipedia](https://en.wikipedia.org/wiki/Dispersion_(water_waves)),
  and [Tessendorf 2004](https://jtessen.people.clemson.edu/reports/papers_files/coursenotes2004.pdf)'s (32)–(33)), solved by Newton for each train's
  wavenumber at the local depth.
- **Drawn.** Where a RenderingDevice runs, the same spectrum drawn as Tessendorf's FFT ocean, in four cascades
  ([the sea](ocean.md)). Without one, 24 Gerstner trains (Tessendorf's (29)–(30)) spread about the wind, with a
  frequency set fixed at the start of a visit, so wind changes the amplitudes without a jump in phase; there a slope
  past 1/6 breaks (Tessendorf §4.6), which is the foam.

| Test | This model | Reference |
| --- | --- | --- |
| H_s from the drawn trains' variance, 4√m₀, against the closed form | within 10% | 0.22 U²/g |
| 10 m/s on Earth | 2.2 m | [Beaufort 5](https://en.wikipedia.org/wiki/Beaufort_scale): 2–3 m |
| 1 m/s on Titan's 1.35 m/s² | 0.16 m | Lorenz & Hayes: about 0.2 m fully developed |
| Minimum phase speed | 0.23 m/s | (4gσ/ρ)^¼, the known capillary minimum |

### Tides

The equilibrium tide from every body, read live each frame:

    η = γ Σ (m/M)(R/d)³ R (3cos²ψ − 1)/2

for each body at distance d and zenith angle ψ, with γ = 1 + k₂ − h₂ the yield of the solid world (h₂ taken as
2.04 k₂, Earth's ratio: 0.609/0.299; γ = 0.69, as in [the standard tables](https://yewalenikhil65.github.io/basilisk-docs/html/equilibrium__tide_8h_source.html)).
A world with no stated k₂ is rigid. Earth's rows against
[Apel's equilibrium constituents](https://geo.libretexts.org/Bookshelves/Oceanography/Coastal_Dynamics_(Bosboom_and_Stive)/03%3A_Ocean_waves/3.07%3A_Generation_of_the_tide/3.7.6%3A_Tidal_constituents)
(M₂ 0.24 m, S₂ 0.11 m, S₂/M₂ 0.46) are in `surfacecheck`, along with the semi-diurnal period from the live orbit.

This is the equilibrium tide, with no basins, resonance or coasts, which is why real shores see metres.

## Weather

`SurfaceWeather` takes its scales from the world.

| Scale | Form | Source |
| --- | --- | --- |
| Stability | N² = (g²/c_pT)(1 − Γ/Γ_d), Γ/Γ_d = 0.66 wet, 0.4 dry (`ClimateLook.STABLE_*`, the lapse the planet draws) | Earth's 6.5 of 9.8 K/km; the 0.4 from Mars's N in Rees & Garrett's table |
| Tropopause | where the column reaches 0.745 T (`Atmosphere.STRAT`) | Earth's 214.7 K over 288 K |
| Hadley width | φ ≈ (gΔ_vH_t/Ω²a²θ₀)^¼ = √(NH_t/Ωa), H_t the tropopause height, constant 1 | Held 2000: where angular-momentum-conserving flow turns baroclinically unstable; the form [Frierson, Lu & Chen 2007](https://doi.org/10.1175/2007JAS2272.1) test against GCMs (the lecture notes could not be fetched, so this is the form as those papers quote it) |
| Rossby radius | L = NH_t/f | [Wikipedia](https://en.wikipedia.org/wiki/Rossby_radius_of_deformation) (up to its π) |
| Fastest wave | 3.9 L, from κL = 1.61 | [Eady model](https://en.wikipedia.org/wiki/Eady_model) |
| Growth | σ = 0.31 (f/N) dU/dz | Lindzen & Farrell 1980, as [NCL's function](https://www.ncl.ucar.edu/Document/Functions/Contributed/eady_growth_rate.shtml) cites it (its printed form has a stray g; this is the dimensional one) |
| Shear | thermal wind, dU/dz = (g/fT) ∂T/∂y | [Wikipedia](https://en.wikipedia.org/wiki/Thermal_wind) |
| Life | 1.4/σ | **Calibrated** to Earth's ~4 days ([Sharkey et al. 2019](https://arxiv.org/abs/1905.08840)) |
| Surface wind | U ∝ (absorbed/ρ)^⅓, 7 m/s today | An energy-budget estimate, pinned to Earth |

The contrast ∂T/∂y is the world's own latitude model's (a dry world, an estimate of 0.3 T). Where the Hadley cell runs past
the pole (Titan, Venus) there is no baroclinic zone poleward of it and no storms grow. Elsewhere systems are seeded along the storm
track, grow and decay on their Eady clock, and drift on half the column's thermal wind. Cover rises and wind veers under
one. **None of this reaches `Climate`.**

**Rain and snow at the site.** A year's rain here is the climate's global mean times the pin's share:
its `precipitation()` over that index's mean on the sphere (400 Fibonacci points, worked out on the survey's thread).
It falls when something makes it: a storm overhead (`smoothstep(0.25, 0.65, influence)`) or a shower, in a tenth of
three-hour spells (an estimate). The rate is scaled by that activity's long-run mean, measured by running the storm
population ahead 3000 eighth-lives and putting it back, so a year adds up to the share. Precipitation is snow
where the site's own annual-mean air is at or below 1.2 °C over land and 1.9 °C over the sea, the temperatures at
which [Dai 2008](https://doi.org/10.1029/2008GL033295) finds snow the more frequent. The weather has no seasons, so
a site whose mean is above that never snows, whatever its winter would do.

What tests it, from Earth's calibration only:

| Test | This model | Reference |
| --- | --- | --- |
| Hadley edge: Earth, Mars, Venus, Titan | 29°, 51°, past the pole, past the pole | 30°, 40°, 60°, pole to pole (Rees & Garrett Table 1) |
| Storm drift, Earth | 7.6 m/s | Extratropical cyclones move at about 25–50 km/h (7–14 m/s) |
| Zonal wavenumber of storms, Earth / Mars | 6.1 / 2.0 | 5–7, and [1–4](https://www.gfdl.noaa.gov/bibliography/related_files/dbanfield0401.pdf) |
| Surface wind, Venus / Titan / Mars | 0.77 / 1.0 / 23 m/s | [0.3–1 m/s](https://nssdc.gsfc.nasa.gov/planetary/factsheet/venusfact.html) / about 1 m/s / [2–10 m/s, 17–30 in a dust storm](https://nssdc.gsfc.nasa.gov/planetary/factsheet/marsfact.html) |

Held's small-angle form outgrows a slow rotator's cell: Venus's 60 km troposphere puts its edge past the pole, where
the observed one is near 60°. Mars's comes out 11° wide of its reference. Mars's wind comes out two to three times too high: a thin atmosphere's boundary layer is not the same machine, and
the one constant was pinned to Earth. It is left visible rather than fitted. In thinner air still the scaling has no
limit of its own, so it stops at 8% of the speed of sound (an estimate).

### Dust

A dry world's storms lift dust instead of making rain. `now().dust_tau` is the air's optical depth at visible
wavelengths: Mars' 0.6 between storms, an estimate inside what the rovers record outside storms. It rises by up to 3
as `(lift)²` once a system overhead is past 0.35 of its strength, and then `kind` is "dust". The 3 is an estimate:
Jezero's regional storm of January 2022 peaked near 2
([Lemmon et al. 2022](https://doi.org/10.1029/2022GL100126)), and 2018's global storm passed 8 at Gale.
Other dry worlds' dust is not modelled.

In flight over a drawn site, the depth over the clear sky's (LocalView's `dust_extra`) does two things:

- **The Sun:** it takes the Sun along its slant path, blue a fifth more than red.
- **The view:** it closes in as exponential fog through a 3 km layer, lit by the day that reaches it.

A showcase may state a storm or the devils' rate over the world's own (`SurfaceWeather.stated`, the scenarios'
`weather`). The flight does not step the synoptic weather; its storms are where the visit's setup left them.

### Dust devils

`dust_devils.gd`. Convective vortices about the eye, within 2.5 km, drawn only:

- **When:** born at 10 dusty devils per km² per sol, packed into the quarter-sol of strong heating. None while the
  Sun is under 15°, then rising linearly to full at 90° (`heating`). The rate is from Jezero: about four vortices
  passed Perseverance a sol, over a quarter of them dusty. One dusty pass a sol, over the ~0.09 km² a devil sweeps
  within 30 m of a point in 1.5 km of drift, is about 11 per km².
- **Size and life:** 2–15 min; 8–60 m across, log-uniform; 150–900 m tall. A swirl of 14 m/s at the core's edge.
- **Motion:** they drift with the wind, wander a little and spin up and die away.
- **Look:** a column of soft puffs, densest at the foot and flaring upward, a little darker than the bright sky
  behind it. That is how a devil stands out kilometres off in Spirit's and Perseverance's sequences.

The encounters are [Newman et al. 2022](https://doi.org/10.1126/sciadv.abn3783)'s, from MEDA's first 216 sols. The sizes
and lives are estimates within what Mars rovers and orbiters have measured. Arriving in an afternoon already under way, the population is run
forward first, so its devils are already up. `surfacecheck` holds them to none at night, about the stated rate by
day, and drift with the wind.

Not modelled: fronts as moving lines (a system is a Gaussian), convection's own weather beyond its share of spells,
seasons, monsoons, orography's rain shadow at a site, Venus's slow rotation regime beyond its Hadley width. The
rivers still carve with the climate's global mean rain, not the site's.

## The ground under a landing

`sim/surface/surface_ground.gd`. A vessel coming down on a dry world with no launch site there owns a
`SurfaceGround`, and what its gear touches is what is drawn. Contact, the LM's P63–P66, the EDL program
and the descent law read `Vessel.height_above_ground`; the air, the heating and orbit targets still read `altitude`,
over the flight figure. A world with seas or launch sites (Earth) keeps the figure as its ground, and its flights are unchanged.
A dry world without a measured grid (Titan, Io) stands on the crust its visual draws, as a pin reads it, until
surveyed. Over a stated sea (Titan's maria, [the sea](ocean.md#titans-seas)) the ground is the liquid at the datum,
and no survey is carved: a craft built to float comes down on `SurfaceSea`.

1. **Measured, until surveyed.** Height over the figure less `PlanetElevation`'s cell at the vessel's latitude and
   longitude. The flight frame turns into the planet mesh's by `Vessel.body_angle`, the same longitude the pad uses.
2. **Asked for.** P63 asks at its landing site, and EDL asks at chute deploy, at where a steady deceleration would
   bring it to rest (`v_h h / |v_z|`, at most 15 km on). Otherwise the vessel asks for itself below 6 km over the
   measured ground and under 300 m/s. The survey is `SurfaceSite.plan_relief`, the one a visit carves, at 129 cells
   whatever the render quality, because a display setting must not move the ground.
3. **Adopted 20 flight seconds later.** At a fixed moment of flight time, not when the worker finishes, so a
   fast-forwarded flight and a drawn one change ground at the same step. A survey still running then is waited for,
   which only happens undrawn: it takes 0.25–1.3 s.
4. **Read off the drawn triangles.** `SiteScene.drawn_height` is `terrain_mesh`'s vertex rule and its cell split,
   curvature drop included. The site's datum is the flight figure under the pin, so its frame is planet-fixed and
   Spaceflight places the same site in the local pass. Past the far grid the measured cell takes over again.

In the held-rate part of a descent, the rate is held against the ground (`Vessel.closing_rate`, the change in
height along the ground velocity), as a radar altimeter measures it. Held inertially, a Sky Crane drifting at
0.6 m/s down a 23° slope of the carved site closes at 0.48 of its 0.74 m/s, and burns out 5 m up.

What tests it (`groundcheck`):

| Test | Result |
| --- | --- |
| The flight frame to the mesh and back | 1e-9 m |
| `drawn_height` against the built mesh's own triangles, found in its index buffer | 2.4e-4 m worst over 3000 points |
| The LM (`lm:terminal_descent`) and the Sky Crane (`skycrane:sky_crane`) on the placed site, from the nodes | physics and the drawn mesh agree to 1 mm |
| Adoption after the request | 20.00 s of flight time |
| The Sky Crane flown drawn and undrawn | same step, same place to 0.1 mm |
| Earth | no ground model, nothing of the surface runs |

Not modelled, or estimated:
- **The datum.** On Mars, MOLA measures height above the areoid, and the flight figure is an ellipsoid. Their
  difference is not modelled.
- **Legs on a slope.** A vehicle stands along the radius, and contact is at its footprint's centre.

### A landing's dust

`sim/flight/plume_dust.gd`, drawn only. Where the lit stage's jet meets the drawn ground, its pressure is the thrust
over the disc it has spread to. The spread is a half-angle of 0.9 rad in vacuum, where the jet expands freely, and
0.35 in air. Past 5 Pa it lifts soil, at full rate from 100 Pa. The grains leave radially from the impingement:

- **In vacuum:** flat and fast, 300–900 m/s at 1–3° up, on ballistic paths. That is the sheet under Apollo's LM: a
  cone 1–3° over the horizontal (Lane & Metzger 2012), at 300–2000 m/s by Apollo-era pitting estimates, fine dust
  faster still. The drawn speeds are the larger grains' end.
- **In air:** 5–18 m/s, slowed to the wind in about half a second, drifting up in the jet's turbulence and spreading
  into a cloud, as the descent stage's camera saw under Perseverance (PIA24428).

The onset and spreads are estimates, set so the LM's 24 kN hover starts it near 30 m, where Apollo 11's crew first
called dust, and not from 60 m. The Sky Crane's 8.5 kN starts it at 25 m. `groundcheck` holds those three. A frame
flown undrawn for more than 2 s clears it.

## The ground close up

`shaders/surface/ground.gdshader`, a visit's and a landing's site (the Observatory keeps its own). Three things
the grid alone cannot show.

- **The relief below the grid, in the shading.** Octaves from half a cell down, each κ ν(λ) high, where
  ν(ℓ) = ν_cell (ℓ/L_cell)^H. κ = √(1 − 2^−2(1−H)) / 1.22 makes the summed field's RMS slope at its finest drawn octave
  ν(λ)/λ: the octaves' slopes add to 1/√(1 − 2^−2(1−H)) of the finest's, and the noise's RMS gradient is 1.22 per unit
  height (Monte Carlo). That is the same law the survey carves with, so a 50 m slope and a
  50 cm one come from one measurement. An octave narrower than about two pixels is faded out rather than aliased.
  The noise is an integer hash (PCG2D). This relief tilts the normal only: contact is the grid's triangles, and the
  gear does not meet anything under the grid's 50 m.
- **A regolith's BRDF.** On an airless world, Lommel–Seeliger (2/(μ₀ + μ) over Lambert) with Hapke's shadow-hiding
  surge, B₀ 1.8 and h 0.071, a lunar fit quoted by the CU/NASA Ames lunar photometry work. Under air, Oren–Nayar at
  σ = 0.35 rad. Each is normalised to Lambert at normal incidence (the surge at 30° phase), so the palette's physical
  albedos keep their meaning.
- **Shadows.** The Sun is occluded by the grids' own heights: a ray marched from each fragment over the near grid's
  triangles, then the far grid's, in 28 steps from 0.5 m growing by 1.5, softened over the Sun's disc. `SurfaceShadow`
  is the same march on the CPU. A vehicle's shadow is the Sun's shadow map, on only while a site is drawn
  (`LocalView.set_ground_shadows`: four splits to 600 m).
- **Colour that does not tile.** Rock and soil are mixed by noise from 12 km patches down to metres, and the grain
  (±15%) runs from 300 m down, the same on both grids so their seam does not show. It is gradient noise on the same
  integer hash, each octave turned 37° and 2.07 times finer than the last so no two share a lattice's axes, on a
  domain warped by a further 900 m of noise so its boundaries meander ([Quílez, "fbm"](https://iquilezles.org/articles/fbm)
  and ["warp"](https://iquilezles.org/articles/warp)). Every octave fades out where it falls under two pixels, and the
  thresholds widen as it does, so from far off the ground keeps the octaves it can resolve and the mean of the rest
  rather than their aliases. Lower contrast hides repetition from altitude too
  ([FlightGear's procedural texturing](https://wiki.flightgear.org/Procedural_texturing)). An airless regolith,
  gardened even by impacts, varies at under half the contrast of dust and sand under air. Single-octave value noise
  on axis-aligned 70 m cells, pushed through a sharp threshold, drew a grid of squares from a few kilometres up.
- **Its colours on a mapped world** are the map's at the site, 5 × 5 texels about it at the albedo the globe draws
  (`PlanetPin.map_colour`): the site, its rim and the flight's patch past it are one ground.
- **Dunes** (Titan's) are carved on the near grid and shaded past it, on the same profile and meander
  (`SurfaceRelief.dune_ridge` is the shader's gradient noise and hash in GDScript), darker sand on the crests as
  Cassini saw it; from far off a pixel holds many dunes and sees their mean.
- **Colour that follows the ground.** The ground against its surroundings 1.2 km about it, on both grids' own
  triangles: under air the lows collect the darker fines and sand (to 22% darker 70 m down) and the highs are
  weathered rock (7% lighter); on an airless world steep slopes are fresher, brighter material (to 25%), as mass
  wasting keeps exposing it.
- **Fresh craters,** on an airless world: of the twelve largest the survey stamped, about one in three, drawn from
  the site's seed, has a bright blanket of immature regolith to 2.5 radii (55% brighter) and broken rays to about
  12 radii, fading as they go (estimates: Tycho's run to some 35 of its radii). Under air rays are erased fast and
  are not drawn.
- **Rocks** (`SiteRocks`), on a lifeless dry world, after Golombek & Rapp's (1997) model of the Viking sites and
  their terrestrial analogues: the area covered by rocks of diameter D or more is F(D) = k e^(−qD), q = 1.79 + 0.152/k,
  so the number per square metre is the integral of −dF/dD over a rock's πD²/4. k is Mars's modal 8%, and estimates
  of 3% for the Moon (Shoemaker & Morris 1970 found the Surveyor sites' fragments alike) and 5% for Titan, where
  Huygens landed among rounded cobbles. They are laid out about the eye on a 25 m lattice, each cell's rocks from
  its own seed, so a rock is where it was when the field is laid out again; the smallest drawn grows from 15 cm at
  the eye to 60 cm at 220 m, and the field thins to nothing over its outer third. One mesh in many rotations and
  proportions, part-buried: a subdivided icosahedron, lumpy and shaded smooth, with a pitted normal map (the rounded,
  vesicular stones of PIA24424 and PIA24429). Its colour is the soil's, a third of the way to the rock's and greyed,
  as loose stones wear the dust they sit in. They are drawn only: contact is the grid's. A landing map reads the metre-sized ones
  ([sky-crane.md](sky-crane.md#why-the-divert-is-out-of-plane)).
- **Where the site meets the planet's patch.** The survey eases the far grid's outer 15% down to its lowest point,
  where the patch lies, so it meets the patch as a slope (`SurfaceRelief._ramp_rim`; contact reads the eased grid).
  There the site dissolves into the patch by an ordered dither, which then shows in its own light; and the whole
  site dissolves in between 15 and 8 km over the ground on the way down, since above that the patch draws the same
  world to the horizon in one light and one haze. In flight the patch wears the site's colours while it is drawn.
  Under a haze like Titan's the engine's ambient carries part of the skylight, and the site's own term gives way
  to it, or the site stands brighter than the patch beside it.

What tests it (`groundlookcheck`, windowed): the LM lands under a 10° Sun, and 5760 pixels have their ground point
found by marching their view rays over the site's triangles. Away from a shadow's edge, where the CPU's march hides
the Sun, the frame is darker than the lit ground beside it: a median of 0.05 of its brightness, and under half at
31 of 33 points. A global threshold would not do, since a 10° Sun lights distant plains at grazing incidence almost
as dimly as shadow. The LM's shadow falls, dark, on sunlit ground where the Sun's ray from the LM meets the ground.
Without the amplitude's normalisation the shading octaves together were twice as steep as the measured roughness,
and under that Sun black facets covered much of the lit ground.

Not modelled: rocks in contact, the relief below the grid in contact or silhouette, light scattered from sunlit ground into
shadow (on the Moon, the hemisphere fill stands in for it).

## What it costs

Nothing outside a visit: `surfacecheck` holds `SurfaceStats` at zero through the orrery, a free camera, a showcase with its
pin, flight and the Observatory, and after three visits the node and resource counts are where they started. Arrival spends
0.25–1.3 s on a worker thread surveying and carving (65 to 161 cells a side, `Low` to `Ultra`, on an M-series Mac) while the view
waits in orbit. On foot it costs about 0.1 ms a frame on a dry world and 2.3 ms on a wet one, most of which is the cloud field's
CPU march, the one flight runs too.
