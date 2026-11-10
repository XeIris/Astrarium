# The surface: `sim/surface/`, `sim/planet_relief.gd`, `sim/planet_pin.gd`

What a world is like at one point on it. All of it runs only while someone stands there. It reads
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
keeps its map's coast, and until real elevation grids are approved its height is the procedural crust's, not a
measurement, and the panel says so.

## Terrain

`SurfaceRelief` builds a far grid (60 km half-width, or 8% of a small world's radius) and a near one
(3.2 km), in the form `SiteScene` reads.

1. **The true crust,** 21×21 samples of `PlanetRelief` across the far grid. A sample costs 0.5 ms in
   GDScript and the shader's highest octave is about 40 km on an Earth, so this is what is resolved.
2. **Roughness that goes as 1/g.** Rock strength over ρg caps relief: Olympus Mons's 21.9 km against
   Everest's 8.8 km is 2.5, and the gravity ratio is 2.6
   ([table](https://en.wikipedia.org/wiki/List_of_tallest_mountains_in_the_Solar_System)). `surfacecheck` holds the
   local relief to that ratio. The 420 m amplitude itself is an estimate.
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

Not modelled: lakes as water (a filled pit drains through its spill), glaciers, sediment deposition, lithology,
tectonic uplift during the run (the crust's relief stands in for what it built).

## Oceans

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
- **Drawn.** 24 Gerstner trains (Tessendorf's (29)–(30)) spread about the wind, with a frequency set fixed at the
  start of a visit, so wind changes the amplitudes without a jump in phase. A slope past 1/6 breaks (Tessendorf §4.6), which is the foam.

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
| Stability | N² = (g²/c_pT)(1 − Γ/Γ_d), Γ/Γ_d = 0.66 wet, 0.4 dry | Earth's 6.5 of 9.8 K/km; the 0.4 from Mars's N in Rees & Garrett's table |
| Tropopause | where the column reaches 0.745 T (`Atmosphere.STRAT`) | Earth's 214.7 K over 288 K |
| Hadley width | φ ≈ √(NH/Ωa), H the scale height | [Rees & Garrett 2019](https://arxiv.org/abs/1903.00393), after Held 2000 |
| Rossby radius | L = NH_t/f | [Wikipedia](https://en.wikipedia.org/wiki/Rossby_radius_of_deformation) (up to its π) |
| Fastest wave | 3.9 L, from κL = 1.61 | [Eady model](https://en.wikipedia.org/wiki/Eady_model) |
| Growth | σ = 0.31 (f/N) dU/dz | Lindzen & Farrell 1980, as [NCL's function](https://www.ncl.ucar.edu/Document/Functions/Contributed/eady_growth_rate.shtml) cites it (its printed form has a stray g; this is the dimensional one) |
| Shear | thermal wind, dU/dz = (g/fT) ∂T/∂y | [Wikipedia](https://en.wikipedia.org/wiki/Thermal_wind) |
| Life | 1.4/σ | **Calibrated** to Earth's ~4 days ([Sharkey et al. 2019](https://arxiv.org/abs/1905.08840)) |
| Surface wind | U ∝ (absorbed/ρ)^⅓, 7 m/s today | An energy-budget estimate, pinned to Earth |

The contrast ∂T/∂y is the world's own latitude model's (a dry world, an estimate of 0.3 T). Systems are seeded along the storm
track, grow and decay on their Eady clock, and drift on half the column's thermal wind. Cover rises and wind veers under
one. Rain's yearly mean is the climate's; a system concentrates it. **None of this reaches `Climate`.**

What tests it, from Earth's calibration only:

| Test | This model | Reference |
| --- | --- | --- |
| Hadley edge: Earth, Mars, Venus, Titan | 25°, 33°, 52°, past the pole | 30°, 40°, 60°, pole to pole (Rees & Garrett Table 1) |
| Zonal wavenumber of storms, Earth / Mars | 6.1 / 2.0 | 5–7, and [1–4](https://www.gfdl.noaa.gov/bibliography/related_files/dbanfield0401.pdf) |
| Surface wind, Venus / Titan / Mars | 0.77 / 1.0 / 23 m/s | [0.3–1 m/s](https://nssdc.gsfc.nasa.gov/planetary/factsheet/venusfact.html) / about 1 m/s / [2–10 m/s, 17–30 in a dust storm](https://nssdc.gsfc.nasa.gov/planetary/factsheet/marsfact.html) |

Mars's wind comes out two to three times too high: a thin atmosphere's boundary layer is not the same machine, and
the one constant was pinned to Earth. It is left visible rather than fitted. In thinner air still the scaling has no
limit of its own, so it stops at 8% of the speed of sound (an estimate).

Not modelled: fronts as moving lines (a system is a Gaussian), convection's own weather, monsoons, orography's
rain shadow at a site, Venus's slow rotation regime beyond its Hadley width.

## What it costs

Nothing outside a visit: `surfacecheck` holds `SurfaceStats` at zero through the orrery, a free camera, a showcase with its
pin, flight and the Observatory, and after three visits the node and resource counts are where they started. Arrival spends
0.25–1.3 s on a worker thread surveying and carving (65 to 161 cells a side, `Low` to `Ultra`, on an M-series Mac) while the view
waits in orbit. On foot it costs about 0.1 ms a frame on a dry world and 2.3 ms on a wet one, most of which is the cloud field's
CPU march, the one flight runs too.
