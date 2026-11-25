# The sea: `sim/surface/ocean_field.gd`, `ocean_gpu.gd`, `floater.gd`, `capsule.gd`, `time_capsule.gd`, `surface_sea.gd`, `sim/stated_seas.gd`

A sea as Tessendorf's FFT ocean, the same field on the GPU (drawn) and the CPU (floated on); a rigid body that
floats on it; Apollo's command module, which comes down on it from a lunar return; and the Titan Mare Explorer,
which comes down on Titan's Ligeia Mare. SI, the site's frame
(x west, y up, z north). The spectrum is [the surface's](surface.md#oceans): JONSWAP on the world's own g, with
dispersion over the local depth and the liquid's surface tension.

## The liquids

`liquid.gd`. What the waves, the light and the hulls read.

| | Sea water | Ligeia Mare (Titan) |
| --- | --- | --- |
| Density | 1025 kg/m³ | 449.7 kg/m³: liquid methane at 92 K ([NIST WebBook](https://webbook.nist.gov/chemistry/fluid/)) |
| Surface tension | 0.074 N/m | 0.0168 N/m (NIST) |
| Kinematic viscosity | 1.05e-6 m²/s | 4.15e-7 m²/s (NIST's 186.7 µPa·s over its density) |
| Index of refraction | 1.339 | 1.294, from Lorentz–Lorenz with methane's polarisability volume 2.593 Å³ (CRC) |
| Absorption at 650, 550, 450 nm | 0.340, 0.0565, 0.0092 /m: pure water's ([Pope & Fry 1997](https://doi.org/10.1364/AO.36.008710)) | estimates, red weaker than water's |
| Backscatter | half of pure sea water's b, [Morel 1974](https://www.oceanopticsbook.info/view/optical-constituents-of-the-ocean/water), λ^-4.32 | water's scaled by (n² − 1)² |
| Freezes at | the climate's freezing point for its salinity | 90.694 K, methane's triple point (NIST), under Ligeia's 91 K |
| Waves start at | any wind | 0.4 m/s at 10 m, where the wind's work beats the viscosity ([Lorenz & Mann 2015](https://www.jhuapl.edu/sites/default/files/2024-09/33-02-Lorenz.pdf), for methane) |

Ligeia is methane-dominated ([Le Gall et al. 2016](https://ui.adsabs.harvard.edu/abs/2016JGRE..121..233L)); its
dissolved nitrogen and ethane are not in it. A deep column sends back R∞ ≈ 0.33 b_b/a of the light that reaches it
([Gordon et al. 1975](https://doi.org/10.1364/AO.14.000417)): 8.8% in the blue, 0.5% in the green and 0.04% in the
red for clear sea water, which is why the open sea is blue. Chlorophyll and silt are not modelled.

Under its wind's onset a liquid lies flat (`OceanField.calm`): no mode is drawn and the glint has no unresolved
roughness, as Cassini's radar found Ligeia, flat to millimetres. Earth's sea has no onset here.

## Titan's seas

`sim/stated_seas.gd`. Titan's crust is procedural and draws no seas, so its three maria are stated where Cassini's
radar mapped them, each as spherical caps sized to its mapped area (Cassini's west longitudes negated to east, in the
mesh's own longitudes):

| Mare | Centre | Area | Depth |
| --- | --- | --- | --- |
| Ligeia | 79° N 248° W, one 200 km cap | 126,000 km² (Stofan et al. 2012) | 170 m at the deepest (Mastrogiuseppe et al. 2014) |
| Kraken | two basins, 73° N 315° W and 62° N 305° W, 280 and 300 km | about 500,000 km² (Hayes 2016) | 300 m, a floor: its main body was deeper than the radar reached (Poggiali et al. 2020) |
| Punga | 85.1° N 339.7° W, 139 km | 61,000 km² (Hayes 2016) | 120 m (Mastrogiuseppe et al. 2018) |

The depth goes as (d/R)^1.2 of the deepest, d in from the shore of a cap of radius R. With Ligeia's 170 m that gives
Le Gall et al.'s (2016) mean of about 50 m. Every reader takes them from there:
- **The pin** reads "sea" inside one, with its name and depth.
- **The survey of a site** within reach of one lays the floor at the mare's depth under it, and off it the crust's
  land rising over 20 km from a datum-level shore.
- **A vessel's ground** over one is the liquid, at the datum, as an altimeter ranges to it, and `SurfaceGround`
  stands down there for the sea.
- **The flight's far ground** draws them dark from altitude, the coast pushed a few kilometres either way by noise.

Not stated: Titan's hundreds of smaller lakes, Kraken's composition (70% methane, 16% nitrogen, 14% ethane, Poggiali
et al. 2020; it floats on Ligeia's liquid here), the maria on the globe seen from orbit, where the haze hides them
anyway, and the seas' common level against the mean radius.

## The spectrum on four lattices

`ocean_field.gd`. The longest tile is six peak wavelengths, at least 12 m and at most 3 km; each next tile is 5, 5
and 8 times smaller. Cascades 0 and 1 are 64 × 64, 2 and 3 are 128 × 128. Each owns a band of wavenumbers, from where
the one before ended to half its own Nyquist's (four texels a wavelength), so no wave is counted twice. Every mode
on a lattice is drawn once at the start, two unit normals seeded from the site, and a change of wind rescales it
without redrawing its phase.

- **Directions.** [Donelan et al. 1985](https://doi.org/10.1098/rsta.1985.0054)'s sech²(βθ) about the wind, with
  Banner 1990's β past 1.6 ω_p, β = 10^(−0.4 + 0.8393 e^(−0.567 ln (ω/ω_p)²)), normalised over a full turn:
  D = β/(2 tanh βπ) sech²(βθ).
- **On the lattice.** S(k) = S(ω) D(θ) (dω/dk)/k per unit k-area, times the lattice's Δk² per mode.
  ⟨|h̃₀|²⟩ is half of that, since a mode and its −k partner each carry |h̃₀|² of variance.
- **In time.** h̃(k, t) = h̃₀(k) e^{−iωt} + h̃₀*(−k) e^{iωt}, a wave going along k, and the field is the inverse DFT
  of it, x_n = Σ F_m e^{+2πi mn/N}, real because each mode has its conjugate at −k.
- **Repeating.** Each ω is rounded to a whole number of turns in 8192 s, at most 4e-4 rad/s from its dispersion, and the
  GPU takes its float32 phase from the time within that. A day at sea is as exact as its first minute.
- **A new wind** keeps the lattices unless its longest tile would be over 1.5 times the old one's, when they are laid
  out again.
- **Sideways.** The water moves as Lagrange's first order moves it, D̂ = i(k/|k|)h̃: a Gerstner wave, crests closed
  up and troughs opened, at Tessendorf's λ = 1.
- **What none of them draws** goes to the glint's roughness: the mean-square slope of the same spectrum from the last
  band's top to the capillary wavenumber √(ρg/σ), and of any cascade too fine for a pixel there
  ([Bruneton, Neyret & Holzschuch 2010](https://inria.hal.science/inria-00443630)).

## The CPU's half

The two long cascades hold 99.4% of the variance and every wave down to a few metres, which is what moves a hull.
The CPU runs them (`OceanField.snapshot`) in double from the same h̃₀ and the same clock as the GPU: two inverse FFTs
a cascade, the sideways pair packed as one complex field, and rows with no mode skipped. 12 ms a snapshot. Between
lattice points it blends the four texels about a point as the water shader fetches them. The height over a site
point is that of the lattice point whose displacement lands there, by fixed-point iteration, which converges while
no wave folds over.

## On the GPU

`ocean_gpu.gd`, `shaders/surface/ocean_fft.glsl`: per cascade per frame, the spectrum at t, the inverse FFT of
its rows and then its columns in shared memory (Cooley–Tukey on a bit-reversed load), and two textures: (Dx, h, Dz,
∂Dx/∂z) and (∂h/∂x, ∂h/∂z, ∂Dx/∂x, ∂Dz/∂z). The h̃₀ and ω it reads are the CPU's, uploaded. Without a
RenderingDevice nothing is allocated, and the site falls back to the trains.

## Drawing it

`shaders/surface/water.gdshader`, hand-lit as the site's ground is.

- **The surface.** The long cascades fetched texel by texel and blended as the CPU blends them; the short ones fade
  where the mesh's rings are too coarse for them. Normals from the derivatives, `(−∂h/∂x/(1 + ∂Dx/∂x), 1, …)`.
- **The sky** reflected by Schlick's Fresnel with the liquid's F₀ = ((n − 1)/(n + 1))²: 0.021 for sea water,
  0.016 for methane.
- **The sun's glint**: Beckmann's distribution of the unresolved slopes about the drawn normal.
- **The liquid.** The refracted ray's path to the bed (the far grid's depth, or the depth buffer when a hull or the
  site's own ground is nearer) attenuates what is behind by e^{−(a + b_b)ℓ}, and the light that lit it came down
  through the liquid too. What the column sends back, R∞ under the light that reaches the surface, fills the rest.
  The screen texture is bent a little along the normal: a screen-space refraction, not a traced one.
- **The light** the sky, the column and the fog are lit by is the ground's, the star's flux through the exposure
  in the sky's colour (`uLight`), and the sun's glint takes what the air leaves of the direct beam: at Saturn, under
  Titan's haze, both are a fraction of Earth's.
- **Foam** on the crests, where the three longer cascades together squeeze the surface towards folding,
  J = (1 + ∂Dx/∂x)(1 + ∂Dz/∂z) − (∂Dx/∂z)², below 0.55, which is an estimate. A linear sea seldom folds, so this
  marks steep crests, not a calibrated whitecap cover. It is not kept from frame to frame.

## What floats

`floater.gd`: a rigid body with closed triangle-mesh hulls, stepped at 1/120 s in double.

- **Pressure.** On each triangle below the surface, clipped where the depth along an edge is zero, the hydrostatic
  pressure ρg·depth is linear. Its force is A times its mean, and its moment uses ∫p r dA = A/12 (Σpᵢrᵢ + Σpᵢ Σrᵢ),
  both exact. A closed hull in still water therefore gets Archimedes' force and the righting moment of its real
  shape, at any attitude.
- **Drag.** Each wetted panel's velocity relative to the water: C_D 1 pushing into it and 0.3 pulling away (estimates
  for blunt panels), and ITTC 1957 friction along it.
- **Radiation.** A body bobbing at ω makes waves that leave at g/ω, so a panel pushing at u_n meets about ρ(g/ω)u_n,
  fading as e^{−kd} with depth. ω is the hull's heave frequency on its waterplane, √(ρgA/m). This is an estimate of
  the damping potential theory would give, and it is what stops a hull bobbing for minutes.
- **Air.** Wind pushes on each panel above the surface that faces it (C_D 1.1), and a parachute pulls at its riser
  point.
- **The water it reads** is the CPU's half, sampled on a 5 × 5 lattice of probes 1.5 m apart about the hull every
  0.1 s, and blended in time. The water's velocity comes from the probes' change. Waves shorter than about 3 m are
  smoothed out of it.

Not modelled: added mass, the waves a hull makes reaching the drawn sea, green water on deck, the hull's flex.

## The command module

`capsule.gd`. One outline, sampled coarser for the hull that floats and finer for the model that is drawn:
- **Size:** 154 in across and 127 in tall (the Smithsonian's Apollo 7 CM).
- **Shape:** the heat shield's 184.8 in sphere, the 33° cone, its shoulder and the tunnel are commonly quoted
  figures, not taken from a drawing.
- **Mass:** 4,932 kg, Apollo 11's splashdown weight (NASA SP-4029).
- **Centre of mass and inertia:** the centre of mass 1.04 m up and 0.14 m off the axis is an estimate, the offset
  that trims an Apollo shape to L/D 0.3. The inertia is the outline's as a uniform solid, also an estimate.
- **Bags:** three uprighting bags of 22 ft³ each (NASA TN D-7081), spheres on the forward deck, which the
  compressors fill in 4 minutes (an estimate).

The return: Apollo 11's entry interface, 400,000 ft at 36,194 ft/s inertial and 6.48° down (NASA SP-4029). It
flies at L/D 0.30, banked 60°, and its Avcoat ablates. Baroswitches fire two 16.5 ft drogues (39.7 m²) at 24,000 ft and
three 83.5 ft ringsail mains at 10,700 ft. The mains' drag area is what Apollo's 22 mph on three implies (C_D 0.54
on the nominal area), so the splash speed is an input, not a result.

## The Titan Mare Explorer

`time_capsule.gd`. TiME was a 2011 Discovery finalist that would have splashed down on Ligeia Mare in 2023 and
floated for six Titan days. One capsule enters behind its own heat shield, comes down on chutes and floats as a
drifting buoy. From [Lorenz & Mann 2015](https://www.jhuapl.edu/sites/default/files/2024-09/33-02-Lorenz.pdf):
- **Mass:** 700 kg.
- **Hull:** axisymmetric, modelled there as stacked cylinders 0.8–2.9 m across, with the centre of mass close to the
  waterline. Not self-righting, like a discus buoy.

These are estimates:
- **Shape:** a forebody with Huygens' 60° half-angle and a 0.75 m nose, the shoulder 2.9 m across, a backshell
  rising to the 0.8 m top 1.6 m up.
- **Centre of mass:** 0.62 m up.
- **Inertia:** the outline's as a uniform solid.
- **Drawn only:** the camera's sphere and the antenna's box on their masts (Lorenz & Mann's figure 4), and two
  radioisotope generators.

On methane it draws 0.69 m with 0.91 m of freeboard. It bobs at 2.85 s, against 2π√(m/ρgA) = 2.73 s on its 2.78 m
waterline. Lorenz & Mann give about 2.6 s on an ethane-rich sea, where it would sit higher.

Its descent:
- **Entry:** at Huygens' 6.0 km/s, 30° down as Dragonfly's is here, over a point up-track of Ligeia's middle.
- **Main chute:** Huygens' 8.3 m scaled to 700 kg, opened at Huygens' Mach 1.5.
- **Stabiliser:** takes over at 110 km, as Huygens' did after 15 minutes. It is sized so that it and the capsule's
  own drag bring 700 kg down at Huygens' 4.5 m/s (Lebreton et al. 2005).
- **Under the chutes:** the risers hold it below the canopy, a pendulum whose torque is the chute's drag at about a
  body length (`Vessel.authority`), so a capsule without thrusters hangs in the airflow.

The Titan expedition is dated 1 July 2023, TiME's planned arrival, in Titan's late northern summer: the subsolar
latitude is 9.5° and the Sun is 19.5° up over Ligeia at splashdown. Lorenz & Mann say it never climbs past about
30° there.

## Coming down at sea

`surface_sea.gd`. A vehicle with `floats` over a world with oceans, or with stated seas, asks for the sea where its
chute will bring it down: the pin, the site's weather (`SurfaceWeather`), and an FFT field for its wind. The fetch is
an open ocean's with 4 km of depth, or across a stated mare at its depth under the point. Twenty flight-seconds later it stands on it, drawn or not. Fifteen metres above the mean sea the
Floater takes the vessel at its place, velocity and attitude, under its mains; the crew cut them 2 s after
splashdown (an estimate). Its height is over the mean sea under it, which by then can be kilometres from the survey's pin
and metres under the pin's tangent plane; the drift the HUD gives is from the splash. The vessel stays landed where it came down, and the craft is drawn where the Floater has
it. On land there is no sea, and the capsule meets the ground as any vehicle does. G starts the CM's bags'
compressors; TiME has none.

On Ligeia the site's weather gives about 1 m/s, the energy-budget wind of
[the surface's weather](surface.md#weather). Titan's Hadley cell runs past the pole, so no storms grow there. Lorenz &
Mann's own winds for the season are lighter (a Weibull scale of 0.4 m/s; Huygens measured about 0.3), and 1 m/s is
the strongest they expected.

## What tests it

`oceancheck` (headless):

| Test | This model | Reference |
| --- | --- | --- |
| The lattices' variance against the spectrum integrated | H_s 2.220 against 2.245 m (10 m/s), 0.410/0.414 (5 m/s, 20 km), 0.161/0.163 (Titan) | within 3% |
| A cascade's FFT against the direct sum over its modes | 4e-15 m | exact on the lattice |
| One wave over fixed points, above its mean | 0.4525 of its length | Lagrange's first order: (π − 2ak)/2π = 0.4523 |
| A box's volume, its force at 0.7 m draft | exact; 84,464.100 N | ρgV, to 1e-12 |
| Its righting moment at 0.02 rad | −2,120.2 N·m | ρgV·GM·sin φ = −2,119.5 |
| Floating free | 0.489 m draft | m/ρA = 0.488 m |
| The CM, bags empty | stable at 6° and at 112° of heel | Stable I and Stable II (TN D-7081) |
| Bags full | stable at 6° only | |
| Onto still water at 22 mph | rests displacing 4.81 m³ (its weight) | |
| In a 7 m/s sea, inverted, the bags started | upright 42 s later | Apollo 11: upright 7.6 min after splashdown (SP-4029; the crew's wait is in it) |
| Heave in a 10 m/s sea against the water under it | correlation 0.999, ratio 1.05 | a 4 m body on 80 m waves rides them |
| On Ligeia Mare | floats with 10.97 of its 16.06 m³ under | |
| Ligeia's place, depth, area and mean depth | 79° N 248° W, 170 m; 125,640 km², mean 50 m | Stofan et al. 2012's 126,000 km², Le Gall et al.'s about 50 m |
| A mare's place against the pin's | the same vector to 1e-7 | |
| Methane at 0.3 m/s | H_s 0, no unresolved slope | flat, under its 0.4 m/s onset |
| Methane at 1.0 and 1.5 m/s | H_s 0.161 and 0.362 m | Lorenz & Mann's 0.2U²/g: 0.148 and 0.333 m |
| TiME on still methane | displaces 1.557 m³, its weight; rests upright or capsized | not self-righting (Lorenz & Mann) |
| Its heave | 2.85 s | 2π√(m/ρgA) = 2.73 s |

Printed, not judged: on still water with full bags it rights from Stable II. Mean-square slope at 10 m/s is 0.026
drawn and 0.006 unresolved, against [Cox & Munk 1954](https://doi.org/10.1364/JOSA.44.000838)'s measured 0.054 for a
clean sea. The spectrum's tail is lighter than a real sea's.

`oceanlookcheck` (windowed): the GPU's two long cascades against the CPU's after a minute of frames, worst 4.2 µm in a
2.2 m sea (1.9e-6 of H_s) and 3.3e-7 m on Titan. It also draws the water shader once.

`seacheck` (flight, headless): the command module from its mains to the Pacific. The sea is stood on before it
arrives, it splashes at 9.7 m/s with a 5.5 g peak, and the probes read the drawn sea to 3 mm. It floats inverted
here, as Apollo 11 did, pulled over by its mains in the wind, and G rights it. Drawn and undrawn flights float
identically, other Earth flights make no sea, and every sea is let go.

`titancheck` (flight, headless) flies TiME from the top of Titan's air at 20×:
- its main opens at Mach 1.50 and its stabiliser at 110 km;
- it comes down on Ligeia Mare at 4.5 m/s with a 1.6 g peak, and floats upright, heel under 2°, displacing
  1.66 m³ of methane on the waves against its 1.56 m³ at rest;
- the sea's 0.14 m in 0.9 m/s of wind is Lorenz & Mann's 0.13 m;
- drawn and undrawn come down on the sea identically.

The entry, in the scenarios: peak heating 305 W/cm² against Apollo 11's 286 BTU/ft²/s (325 W/cm²), and a peak of
8.6 g against its 6.56 g. Its constant 60° bank is not Apollo's guided bank. It comes down at 0° N, 168.3° W; Apollo
11 came down at 13.3° N, 169.15° W.
