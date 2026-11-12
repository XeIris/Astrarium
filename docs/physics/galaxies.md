# The galactic scene

`sim/galaxy/` is a separate world, entered from the scenario list's **Galaxies**
group. Its scene units are kpc with the galaxy's centre at the origin, its clock is
Myr, and it has no orrery bodies. Issue 25 plans six phases; this document grows with
them. Phase 1 is the Milky Way alone: a potential, tracers that orbit in it, a rotation
curve measured from them, and how it is drawn at every distance.

## Units

Physics in the orrery is AU, M☉ and the orrery year with `G = 4π²`. The galactic scene
uses kpc, 10¹⁰ M☉ and 10⁶ orrery years, and derives its G from the same constants
(`GalUnits`):

    G = 4π² · 10¹⁰ · (10⁶)² / (AU per kpc)³ = 0.0449850 kpc³ (10¹⁰ M☉)⁻¹ Myr⁻²

with 1 pc = 648000/π AU exactly (IAU 2015 B2). The orrery year is 365.2569 d (the
period in which `Physics.G` is exactly 4π², `Rocketry.YR_S`), so a galactic Myr is
1.7 × 10⁻⁵ longer than a Julian one. `galaxycheck` holds G to the conventional
4.300917 × 10⁻⁶ kpc (km/s)² M☉⁻¹ from GM☉ = 1.32712440018 × 10²⁰ m³ s⁻².

## The Milky Way's potential

Bovy (2015, ApJS 216, 29), `MWPotential2014`, as galpy implements it
(`galpy/potential/mwpotentials.py` and the component classes, read for this work):

| Part | Form | Parameters | Share of the radial force at R0 |
|---|---|---|---|
| bulge | ρ ∝ r^−α exp(−(r/rc)²) | α = 1.8, rc = 1.9 kpc | 5 % |
| disc | Miyamoto–Nagai | a = 3 kpc, b = 0.28 kpc | 60 % |
| halo | NFW | rs = 16 kpc | 35 % |

normalised at R0 = 8 kpc to vc(R0) = 220 km/s (galpy's `normalize`). Each part's
potential is zero at infinity. The bulge's enclosed mass is

    G M(r) = 2π A rc^(3−α) γ(3/2 − α/2, r²/rc²)

and its potential `−G M(r)/r − 2π A rc^(2−α) Γ(1 − α/2, r²/rc²)`, with the incomplete
gamma functions from Numerical Recipes (3rd ed., §6.1–6.2). galpy's potential differs
by a constant. For the integrator, G M(r) is tabulated on 768 points in ln r and
interpolated with Hermite cubics using its exact derivative 4πG r³ρ; a spherical force
is conservative whatever the interpolation, and the table is within 3 × 10⁻⁹ of the
exact mass.

Bovy's Table 1 lists values derived from the fitted potential. They test this
implementation, not the Galaxy:

| Quantity | Table 1 | Here |
|---|---:|---:|
| vesc(R0), km/s | 513 | 512.96 |
| M(< 60 kpc), 10¹¹ M☉ (as R vc²/G) | 4.1 | 4.08 |
| Fz(R0, 1.1 kpc), 2πG M☉ pc⁻² | 72 | 71.7 |
| ρ(R0, 0), M☉ pc⁻³ | 0.10 | 0.101 |
| ρDM(R0), M☉ pc⁻³ | 0.008 | 0.0075 |
| d ln vc / d ln R at R0 | −0.10 | −0.101 |
| bulge, disc mass, 10¹⁰ M☉ | 0.5, 6.8 | 0.45, 6.82 |
| Mvir (NFW inside 245 kpc), 10¹² M☉ | 0.8 | 0.81 |

The bulge and halo-density rows agree only to Bovy's rounding (one figure).

### Against the measured Galaxy

Eilers et al. (2019, ApJ 871, 120) measured the circular speed from 5 to 25 kpc with
23 000 APOGEE/Gaia red giants and the Jeans equation; their Table 1 is in `GalCurve`
and the chart draws it. MWPotential2014 was not fitted to it. The model lies below it
everywhere: by 9.8 km/s on average over 5–21 kpc and by up to 15.4 km/s (7 %) near
17 kpc. At the Sun Eilers et al. find 229.0 ± 0.2 km/s with R0 = 8.122 kpc (systematic
2–3 %); the model has 220 at 8 kpc by construction. This is a known property of
MWPotential2014 (Bovy calls it a convenience model, not the best current one), and
`galaxycheck` pins the offset so that a change to the potential shows.

## Tracers

`GalTracers` are massless test particles in the static potential, integrated with a
drift–kick–drift leapfrog at a fixed 0.1 Myr step. Each tracer's energy error stays
bounded; the axisymmetric force has no azimuthal part, so its Lz is kept to rounding.
Test particles don't interact, so each tracer takes all of a frame's steps in turn with
the potential inlined (`GalPotential.Kernel`); 6000 tracers cost ~5 ms per step in
GDScript.

Two populations:

- **Cold gas**, 2000 clouds from 2 to 30 kpc: surface density flat to 12.5 kpc then
  exponential with a 3.75 kpc scale length (Kalberla & Dedes 2008, A&A 487, 951), and
  the cold neutral medium's 6.1 km/s dispersion (their Table 1).
- **Old thin disc**, 4000 stars with guiding radii 4 to 20 kpc, sampling the model
  disc's own surface density: σR = 35 and σz = 25 km/s at 8.2 kpc, falling outward as
  exp(−R/2Rd) with Rd = 2.6 kpc (Bland-Hawthorn & Gerhard 2016, ARA&A 54, 529, §5 and
  Table 5). Inside 4 kpc the bar dominates and the extrapolated σR passes 70 km/s.

### Initial conditions in equilibrium

Gaussian velocities about the Jeans-equation mean are not an equilibrium: a warm disc
drawn that way relaxes, and a check on its curve measures a transient. Both
populations are therefore drawn from Shu's (1969) distribution function in the plane,

    f(E, Lz) ∝ F(Rg)/σR²(Rg) · exp(−(E − Ec(Rg))/σR²(Rg)),

with Rg the guiding radius of Lz and Ec its circular orbit's energy. f depends on the
integrals only, so the population is stationary (Jeans' theorem). Per tracer: Rg from
F; E − Ec from the exponential, accepted in proportion to its radial period (the
phase-space volume of the orbit); then a time-uniform phase along the radial orbit,
R = R̄ − ΔR cos θ with weight dt/dθ. Heights follow an isothermal layer in the
potential at that radius, ρ ∝ exp(−(Φ(R, z) − Φ(R, 0))/σz²), with Gaussian vz; the
vertical part is separable only approximately. Drawing takes about a second, so the
scene does it on a worker thread.

Over 1 Gyr the thin disc's mean vφ in 2-kpc rings moves by 0.1–4.7 km/s, within three
standard errors; the remaining drift is the vertical–radial coupling the separable
approximation ignores.

## The rotation curve, measured

`GalCurve.measure` bins the live tracers in 1-kpc rings: mean vφ and its standard
error. Three curves come out of one measurement:

- **Cold gas** is the circular speed: its asymmetric drift is a fraction of a km/s.
  `galaxycheck` requires it to match the model in every bin, at the start and after
  1 Gyr (worst 2.3 σ).
- **Stars** lag it (asymmetric drift): 25 km/s at R0 here, against the 10–20 measured
  for the old thin disc. The Shu disc is hotter than its parameters suggest where
  stars from the hot inner disc visit.
- **Stars, Jeans-corrected**, as Eilers et al. did it:
  vc² = ⟨vφ²⟩ − ⟨vR²⟩ (1 + ∂ln ν/∂ln R + ∂ln⟨vR²⟩/∂ln R), with ν and ⟨vR²⟩ fitted
  as exponentials in R. It recovers vc within 4.2 km/s over 6–18 kpc; the model disc
  is not exponential, which is the method's own systematic.

Bins within 1 kpc (gas) or 2 kpc (stars) of a population's guiding-radius limits are
not drawn: near an edge a ring holds only stars at the ends of their orbits.

## How it is drawn

Everything drawn comes from the potential: light follows the model's own disc and
bulge densities.

### Populations and light

`GalPopulation` builds a stellar population today from Kroupa's (2001) IMF thinned by
`Structure.main_sequence_lifetime`: a constant star formation rate for 10 Gyr for the
disc, a single burst 10 Gyr ago for the bulge. Stars past the main sequence add light
by the fuel consumption theorem (Renzini & Buzzoni 1986): stars leaving the main
sequence at b per year, each burning F M☉ of fuel in a phase, give that phase
L = 9.75 × 10¹⁰ b F L☉, with F per phase (SGB, RGB, HB, E-AGB, TP-AGB) from Maraston
(1998, MNRAS 300, 872) Table 1. Each phase's temperature is read from the ranges in
her Table 3 and is an estimate. Giants carry 45 % of the disc's light and 75 % of the
bulge's.

A star's colour is its visible light per bolometric L☉: Planck through the CIE 1931
functions (`PlasmaSpectrum.cmf`) into linear sRGB, divided by σT⁴, scaled so the Sun's
luminance is 1. A hot star emits mostly ultraviolet, so it contributes less visible
light per L☉ than the Sun; without this, O and B stars would turn a whole disc blue.

**Against the measured Galaxy.** Weighting the disc and bulge populations by their
visible light gives an integrated colour; through the blackbody whose blue-to-red
ratio matches it and Ballesteros' (2012) blackbody relation, B−V = 0.719 (disc 0.711,
bulge 0.99). Licquia, Newman & Brinchmann (2015) measure the Milky Way's rest-frame
B−V as 0.744 +0.068 −0.054. Nothing was tuned to it; `galaxycheck` holds it within
2σ, and holds a 5772 K blackbody to the Sun's 0.65. The bulge gives only 2 % of the
light, less than the 10–30 % usually quoted, because MWPotential2014's bulge is light
(0.45 × 10¹⁰ M☉) and old.

**Against Gaia's star counts.** Bovy (2017, MNRAS 470, 1360) measured the solar
neighbourhood's main-sequence stars per magnitude with Gaia TGAS and 2MASS (his
Table 1). Per magnitude of M_V the model has, against his counts: 0.48 for A0–A5, 0.98
for A6–F1, 1.5 for later F, 1.6–2.2 for G and 2.8 for early K. The bright end that
dominates the drawn sky is right; the model has too many G and K dwarfs. Its local
number density of main-sequence stars, 0.17 pc⁻³, comes from the Miyamoto–Nagai
disc's mid-plane density times McKee's visible fraction, which is a ratio of
surface densities: gas sits in a thinner layer than stars, so at the mid-plane the
stellar share is smaller than that ratio. `galaxycheck` pins these ratios.

The star lattice draws masses from a table of the resolved stars' log m at
cumulative fractions u = 1 − 10^(−7k/64): a few per cent of resolved stars span 2 to
100 M☉, and a table evenly spaced in u would spread its last step across that range
and draw O stars by the hundred. `galaxycheck` integrates the table as the shader
reads it and holds the drawn stars' mean luminosity (0.996) and their share above
8 M☉ (1.00) to the population.

The visible fraction of the disc's mass is McKee, Parravano & Hollenbach's (2015)
27.0 of 47.1 M☉ pc⁻² over the solar circle; the bulge's is 27.0/33.4 (no gas).

### Three levels

- **The glow** (`galaxy_glow.gdshader`) integrates the luminosity density along each
  view ray, I = ∫ j ds / 4π, on a box drawn from inside, so it is the galaxy from
  outside and the Milky Way's band from within. Samples are uniform in
  u = asinh((s − s_c)/scale) about the ray's crossing of the plane (disc) or its
  closest approach to the centre (bulge).
- **Stars** (`galaxy_stars.gdshader`) are made in the vertex shader from the vertex
  index alone. The galaxy is cut into 10-pc cells in (R, height, azimuth); a cell's
  stars are a Poisson draw from the model's number density, hashed from its integer
  coordinates, so a region always holds the same stars. Each ring of cells turns at
  its own circular frequency, so stars move with the galaxy and the lattice never
  shears apart (the CPU reduces each ring's angle in double). Stars above 0.5 M☉
  within 40 pc of the camera are drawn one by one.
- **The hand-over.** Inside the resolved radius the glow keeps only the light of
  stars it does not draw: those below 0.5 M☉ (1 % of the light) and, in phase 1, the
  giants. Stars and glow draw on one density and one population table, so their flux
  is equal by construction; `galaxylookcheck` measures it.

### Brightness

The flux scale is the sky's: `SkyModel.STAR_FLUX` is a V = 2.5 star, and a star of L
at d has the Sun's absolute V of 4.83 shifted by its distance, so sky flux
= K L / 4πd² with K = STAR_FLUX · 10^(−0.4 · 2.33) · 4π · 10⁻⁴ (L in L☉, d in kpc).
The glow's pixel value is its radiance times K. A galaxy's centre is far brighter than
the night sky's Milky Way band, so the scene adapts like an eye: the brightest of the
view's centre and the galaxy's centre (its cusp cut at 2 % of the distance, so a patch
sets the level, not one pixel) is held at 1.5, never above the night-sky calibration.
The exposure slider multiplies that.

### What `galaxylookcheck` measures

- Face-on, the glow's pixels against the same integral done on the CPU in double
  (`GalaxyVisual.ray_luminance`) along the same rays: within 0.5 % in seven rings.
- Through the dust lane, rows of pixels across it against the same integral, with the
  CPU marching 3000 samples (12000 give the same): edge-on from outside within 0.6 %
  (tolerance 4 %), and from the Sun within 5.3 % (tolerance 8 %). From the Sun the
  glow's 28 far steps cross ~30 kpc of arm dust in the plane, and that quadrature reads
  bright in the lane. Face-on the dust is too thin to test the absorption; these rows
  are where a step attenuated at its midpoint (14 % off from the Sun) or a spheroid
  that ignores the disc's dust (33 % off edge-on) shows.
- The hand-over: with every drawn star given its population's mean luminosity and the
  nearest 5 pc left out (so no single star dominates), the stars in the shell carry
  1.015 of the light the glow gives up, over 24 views (tolerance 6 %). A star's drawn
  pixels sum to its flux wherever it lands (`point_flux`, the codebase's point-source
  rule), while a glow pixel is radiance and covers (1 + x² + y²)^−3/2 of the centre
  pixel's solid angle; the check compares flux, not pixel sums. Comparing pixel sums
  reads 0.72 for a 50° frame, and this is why.

## The bar, the arms and the dust (phase 2a)

### Two rotating patterns

`GalPattern` adds non-axisymmetric gravity, each pattern turning rigidly.

- **The bar** is Dehnen's (2000) quadrupole in Monari et al.'s (2016) 3D form, as galpy
  has it: Φ = A cos 2(φ − φb) (R/r)² g(r), with g = −(Rb/r)³ beyond Rb and
  (r/Rb)³ − 2 inside. It turns at 39.0 ± 3.5 km/s/kpc (Portail et al. 2017), with
  Rb = 5.0 kpc (the long bar's half-length) and its near end 27° ahead of the
  Sun–centre line today (Bland-Hawthorn & Gerhard 2016). Its strength is galpy's
  default α = 0.01, after Dehnen (2000).
- **The spiral** is Cox & Gómez's (2002) potential of a two-armed stellar density
  wave: ρ = ρ0 e^{−(R−r0)/Rs} sech²(z/H) cos γ, with ρ0 = (14/11) m_H n0 = 1.283 amu cm⁻³
  (their n0 = 1 cm⁻³, with helium), r0 = 8, Rs = 7
  and H = 0.18 kpc, and γ = N(φ − φp + ln(R/r0)/tan α), so its arms trail. It turns at
  28.2 ± 2.1 km/s/kpc (Dias et al. 2019). Its 12° pitch is the mean of the two major
  arms' measured pitches, and its crest lies on Perseus today (Reid et al. 2019). Reid
  et al.'s arm radii are for R0 = 8.15 kpc; they are scaled by 8.0/8.15 to the model's R0, so
  each arm keeps its place relative to the Sun.

Both grow by Dehnen's quintic over one bar period from t = −320 Myr and run a further
period before today, so the tracers have responded when the scene opens. The
scene runs that history on a worker thread, which takes about a second.

Turning patterns do work on a tracer: dE/dt = ∂Φ/∂t. The kernels tally
W = ∫∂Φ/∂t dt at each kick (midpoint in time and position), so E − W is each tracer's
invariant; it holds to 9 × 10⁻⁶ through the growth. With the bar alone and fully grown,
the Jacobi integral E − Ωb Lz holds to 2 × 10⁻⁶, which does not use the tally.

### A native kernel

`NBodyKernel.tracers` (`native/astrarium_native.c`) runs the same arithmetic as
`GalTracers._step_fused`, expression for expression, and `galaxycheck` requires the two
to be bit-identical at every step (an ulp in the work tally can round away again, so
the end state alone can agree by luck). That needs `-fno-builtin` in
`native/build.sh`: otherwise clang fuses the spiral's adjacent `cos` and `sin` into
`sincos`, an ulp off GDScript's separate calls. Bit identity also needs the library
and the engine to share a libm: the kernel calls `exp`, `log`, `sin`, `cos`, `atan2`,
`tanh` and `pow`, and MinGW's differ from the engine's on Windows. `galaxycheck` asks
the library (`NBodyKernel.libm`) for those functions at fixed arguments; where any
differs it requires agreement to 10⁻⁹ instead and names the functions. The native kernel takes 0.36 ms per step for 6000 tracers, against
9.9 ms in GDScript; the GDScript one remains the fallback where the library is absent.

Measuring the pattern speeds back from the tracers (the drift of their m = 2 density
phase) was tried and does not work at this tracer count. The cold gas's response
decays and turns at a mix of speeds, so it is not a check.

### Light

Appearance follows the model:

- **The stellar arms** are the spiral's own density, Cox & Gómez's ρ, lit at the old
  disc's light-to-mass ratio and added to the disc's light (held non-negative). The
  drawn stars crowd into them too.
- **The young stars**, under 100 Myr, are a separate population. The disc's own
  population now covers 0.1–10 Gyr, so they are not counted twice. They form at
  1.65 ± 0.19 M☉/yr (Licquia & Newman 2015, via Bland-Hawthorn & Gerhard 2016), in a
  layer 49 pc high (Bovy 2017's A0 dwarfs), across the star-forming disc's radial
  envelope (the dust disc's, below). They lie along Reid et al.'s (2019, Table 2)
  measured arms, with their kinks, pitches and widths, and turn at the spiral's speed.
  - Outside each arm's measured azimuths, Norma, Scutum–Centaurus,
    Sagittarius–Carina and Perseus are extended at 12°: an extrapolation.
  - Outer (Norma's far end) and the Local spur keep to what was measured. Past
    their ends they fade out over about 9° of azimuth at their own pitch, a rendering
    choice that avoids a hard edge.
  - `galaxycheck` holds their total to SFR × 100 Myr × the young population's L/M.
- **The bulge's light** takes the box/peanut bulge's axis ratios, 10 : 6.3 : 2.6
  (Wegg & Gerhard 2013, via Bland-Hawthorn & Gerhard 2016), turning with the bar. Its
  mass stays MWPotential2014's spherical one, with the bar's quadrupole added.
- **Dust** is Drimmel & Spergel's (2001) model, their eqs. 13–17 and Table 1:
  - a sech² disc (κV ρ0 = 0.0180 × 1098 kpc⁻¹, scale length 2.26 kpc, height 134 pc
    flaring past 4.4 kpc, a hole inside R⊙/2);
  - Gaussian arms (κV ρa = 0.0180 × 162, cut off outside 6.71 kpc, 64 pc/kpc wide,
    80 pc high);
  - all on Reid's arm loci rather than their Taylor & Cordes geometry. Their local
    arm component is left out.
  
  The glow marches it front to back, per channel with Rieke & Lebofsky's (1985)
  A_R/A_V = 0.748 and A_B/A_V = 1.324, so the light behind it reddens.
- **Drawn stars** are dimmed by the same dust, at its density halfway along each sight
  line.
- **A baked map.** The young arms, the stellar spiral and the arm dust all turn
  rigidly at Ωp, so in their own frame they are fixed. They are baked once on a worker
  thread into a 384² map over ±20 kpc (52 pc texels, under half the narrowest arm's
  width). The shaders read it turned by Ωp t, one lookup per sample instead of a loop
  over arms and windings. The CPU copy reads the same map the same way, so the look
  check still compares two integrations of one model. The stellar spiral's factor is
  still 0.2 at 20 kpc, so its light fades out between 16 and 20 kpc; otherwise the
  map's square border would show face-on. Its gravity is not windowed.
- **A split march.** The glow's disc march spends 4 samples evenly on the resolved
  sphere and 28, warped about the plane crossing, beyond it. With 40 warped samples the
  hand-over read 1.02–1.04, because too few fell inside the 40 pc shell. Split, it
  reads 0.977. Each step's light is attenuated by its exact in-step mean,
  (1 − e^{−k})/k for optical depth k, so long steps through the dust lane neither
  overshoot nor flicker with the per-pixel jitter (an integer hash: interleaved
  gradient noise hatched the lane).
- **Performance.** At native resolution on the M5, the galaxy runs at 49–52 fps from
  outside and 33–34 fps from the Sun (p95 29.6–30.4 ms over two runs, against the
  33.3 ms gate). The
  spheroid's march reads the disc's optical depth by inverting the disc march's sample
  spacing rather than searching stored boundaries; the stored array cost registers.
- **The eye.** Within the disc it adapts as before. From outside it exposes for the
  disc's mean brightness at 6 kpc, as a photograph of a galaxy does, and may open up
  to 100×. The bulge then burns out.

### Against the measured Galaxy

- **Extinction to the centre.** From the Sun to the Galactic centre the dust gives
  A_V = 21.1. Fritz et al. (2011) measure A_Ks = 2.42 ± 0.10 toward Sgr A*, or
  A_V ≈ 21.6 with Rieke & Lebofsky's A_K/A_V = 0.112. Not fitted.
- **Colour.** With the young arms, the integrated colour is B−V = 0.789, against
  Licquia et al.'s 0.744 +0.068 −0.054. The young population's own B−V (0.30) is too
  red: the post-main-sequence temperatures are Maraston's ranges for ages above a Gyr,
  not young supergiants'.
- **Local dust.** Locally the mid-plane extinction is 1.4 mag/kpc toward the centre,
  because the Sun sits on the Local arm's dust. Straight up it is A_V = 0.24, probably
  high: the low-dust bubble around the Sun is not modelled.
- **The sky from the Sun** now shows the band split by its dust lane and reddened
  toward the centre, as ESO's optical panorama does.

### Limits (phase 2a)

- **Weak arms face-on.** The stellar arms modulate the disc by about 25 % at the Sun,
  and the young arms add about 6 % of the blue light. With MWPotential2014's bright
  bulge, the arms are visible face-on only at the disc's exposure, and the bar is lost
  inside the burnt-out bulge.
- **Smooth young light.** Real arms are lit by clumped OB associations and H II regions.
- **The tracers' response** to the bar and arms is weak and transient.
- **Grain in the dust lane.** From inside the disc the jittered march leaves a fine,
  unstructured grain along the lane's edges.
- **The young stars** are in the glow only; the drawn lattice holds the old disc's
  and bulge's stars.

## The real stars around the Sun (phase 2b)

Near the Sun the model gives way to the measured sky, so the galactic scene joins the
Solar System's (`sim/galaxy/gal_neighbourhood.gd`, `assets/sky/neighbourhood.bin`, built
by `tools/build_neighbourhood.py`).

- **Two sets.**
  - Near: every star within 40 pc brighter than M_V = 8.54, which is the model's own
    resolved limit (its 0.5 M☉ star). There are 4081, from Gaia DR3 with BSC5 for the
    stars too bright for Gaia.
  - Far: the rest of the Solar System sky, BSC5 and Gaia from G = 6.5 to 8: 57 076
    stars with the same V and B−V the `solar` sky draws.
- **Distances,** in order of preference:
  - Gaia DR3 at parallax/error ≥ 10 where its astrometry is sound: RUWE ≤ 1.4
    (Lindegren et al. 2021) and G ≥ 5, below which Gaia saturates (45 702 stars);
  - Hipparcos (van Leeuwen 2007) at ≥ 5 (9049);
  - Gaia at ≥ 5, whatever its RUWE or G (3955);
  - BSC5's own parallax (53).

  Gaia's parallax zero-point (about −0.02 mas; Lindegren et al. 2021) is not applied: it
  moves a near star by under 0.1 %, and a far star's distance shows only within 30 pc of
  the Sun, where its own parallax is a few mas at least. The asset is
  sha256 `30472e8fe5cd978ffb3837d8d5f55292876036f2fbc4b33da4bab9a957f6fffa`, from queries
  run on 2026-11-12.

  293 have none and stand at 1 kpc in their direction. Against Hipparcos, Gaia's
  parallaxes for the BSC5 stars agree to −1.3 % (median), 16–84 % within −10 to +5 %.
  BSC5's own parallaxes are poor for distant stars: Rigel at 77 pc against
  Hipparcos's 265 pc. That is why Hipparcos is preferred to them.
- **The near set replaces the lattice.** Where the camera's resolved sphere overlaps
  the Sun's 40 pc, no procedural star is made inside it (`uHole`), and the real ones are
  drawn by the same point rule. The glow already gives up the resolved stars' light
  there.
- **The far set is joined through the glow.** Its stars would otherwise add their light
  twice: from the Sun they carry 22 % of the model's whole sky. The glow gives up their
  light as a map of galactic (l, b) smoothed over 12°. Smoothed over 4°, the map ran
  out of glow to take around the brightest groups (Orion, 0.8 % of the catalogue's
  light), and the sky went dark around them. Real bright stars clump more than the
  model's smooth light does. At 12° none of the catalogue's light is left over.
- **Fading out.** A sample complete to V = 8 from the Sun is not complete from anywhere
  else. The far set and its map fade out as the camera goes from 10 to 30 pc from the
  Sun.
- **The Sun's motion.** The set rides with the Sun, which turns at Ω(R0) as its lattice
  ring does, and the "sun" framing follows it exactly.
- **Brightness.** Observed V already includes the real extinction, so the model's dust
  does not dim these stars again. A star's flux at the Sun is the `solar` sky's for its
  V (`galaxycheck`, to 6 × 10⁻⁷).

### Gaia against the model

Within 40 pc, the real stars to the model's resolved limit against the model's own
resolved stars, per magnitude:

| M_V | real | model |
|---|---|---|
| −2 to 0 | 19 | 0 |
| 0 to 2 | 152 | 41 |
| 2 to 4 | 579 | 422 |
| 4 to 6 | 1355 | 1979 |
| 6 to 8.54 | 1976 | 4144 |
| total | 4081 | 6586 |

The model has 1.5–2.1 times too many K and early-M dwarfs and too few A stars and
giants. That is the same pattern the comparison with Bovy (2017) shows, now in an
independent sample. In visible light the real stars give 2.33 times the model's
(12 026 against 5163 L☉), because a few A stars and giants dominate: Sirius, Vega,
Arcturus and Capella. The model holds giants in its glow and draws none. `galaxycheck`
pins both ratios, so a change to the population shows.

### Limits (phase 2b)

- **Joined from the Sun only.** Elsewhere the drawn stars are the model's main sequence
  within 40 pc. There is no layer of luminous stars or giants, and the bulge's cells
  still overflow: about 270 resolved stars per 10 pc cell at 3 kpc, 10⁴ in the bulge,
  against 128 slots. Raising the resolved mass there would leave the old bulge with
  none, because its resolved stars are giants. The fix is a layer of giants with their
  own luminosity function, planned as phase 2c.
- **Real giants within 40 pc** (Arcturus, Capella, Aldebaran, Pollux) are drawn, and
  the model's giant light stays in the glow there too. The double count is a small
  part of the near sphere's light.
- **The far set is fixed to the Sun's view.** Its smoothed map is correct only at the
  Sun, and the 293 stars with no distance are placed at 1 kpc.

## Landmarks (phase 3a)

`sim/galaxy/gal_landmarks.gd` lists the places worth flying to, each with a card and its
sources. The panel lists them; their names stand beside them on screen (behind the
HUD); pressing either flies there.

| landmark | placed by | sources |
|---|---|---|
| The Sun | the Sun's frame, turning at Ω(R0) | GRAVITY 2019 (R0 measured 8.18 kpc; the model's is 8), Bennett & Bovy 2019 |
| Sagittarius A* | the centre | GRAVITY 2022 (4.30 × 10⁶ M☉) |
| The bar | the centre, labelled along the bar | Bland-Hawthorn & Gerhard 2016; Portail et al. 2017 |
| Perseus Arm | the spiral's crest at 8.87 kpc, β = 40°, turning with the pattern | Reid et al. 2019; Dias et al. 2019 |
| ω Centauri | RA, Dec, 5.43 kpc; drawn as a point of V = 3.50 | Baumgardt's catalogue (Baumgardt & Vasiliev 2021) |
| Large Magellanic Cloud | NED's position, 49.59 kpc | Pietrzyński et al. 2019; Erkal et al. 2019; Kallivayalil et al. 2013 |
| Small Magellanic Cloud | NED's position, 62.44 kpc | Graczyk et al. 2020; Zivick et al. 2018 |
| Triangulum (M33) | NED's position, 809 kpc | McConnachie 2012; Corbelli et al. 2014 |
| Andromeda (M31) | NED's position, 783 kpc | McConnachie 2012; Kafle et al. 2018; Tamm et al. 2012 |

- **Placing things on the sky.** A sky landmark is placed from the Sun at t = 0 through
  the app's galactic frame (`SkyModel.galactic_frame_j2000`). `galaxycheck` holds that
  frame to ESA's own (l, b) for eight Gaia DR3 stars, to 0.03″.
- **Flying.** A flight is a glide that then tracks the landmark exactly
  (`OrreryCamera.track_point`, the follow camera's rule for a point), so the Perseus
  Arm's landmark stays on the crest as the pattern turns. A flight to something on the
  sky arrives from the Sun's side, so it is seen as we see it.
- **Limits.**
  - The satellites, ω Cen and the Clouds hold their places from t = 0: their own
    orbits are not followed.
  - ω Cen's point takes the old spheroid's colour, and its light is also in the model's
    spheroid (a small double count).

## The Local Group (phase 3b)

The Milky Way's four largest neighbours are drawn from their stars (`GalModels.LOCAL_GROUP`),
each by its own `GalaxyVisual`, placed where it is and tilted as measured, at the Milky
Way's exposure.

| | stars | shape | tilt and distance |
|---|---|---|---|
| M31 | Hernquist bulge 3.4 × 10¹⁰ M☉, a = 0.7 kpc; Miyamoto–Nagai disc 6.9 × 10¹⁰ M☉, a = 6.5, b = 0.26 kpc (Kafle et al. 2018, from five earlier studies) | as given | i 77.5° (Tamm et al. 2012), PA 38° (Corbelli et al. 2010), 783 kpc (McConnachie 2012) |
| M33 | 4.8 × 10⁹ M☉, no bulge (Corbelli et al. 2014) | exponential, 1.8 kpc; 100 pc half-thick | PA 23°, ellipticity 0.41, so i = 53.8°; 809 kpc (McConnachie 2012) |
| LMC | 2.7 × 10⁹ M☉ (van der Marel et al. 2009) | exponential, 1.3–1.5 kpc (van der Marel 2001; 1.4 here), with a bar (below) | i 25.86°, line of nodes 149.23° (Choi et al. 2018a, the frame its bar was measured in); 49.59 kpc |
| SMC | 3.1 × 10⁸ M☉ (ibid., from Stanimirović et al. 2004) | an old spheroid (ibid.), exponential with scale length 1.25 kpc (Gonidakis et al. 2009) | 62.44 kpc |

- **Stand-ins.** An exponential disc is drawn as a Miyamoto–Nagai disc of the same mass
  and half-mass radius (a = 1.678 R_d/√3). The SMC is a Hernquist sphere of the same
  projected half-light radius (a = R_e/1.8153). Crowl et al. (2001) find it elongated
  along our line of sight, so drawing it round is a simplification. The LMC's thickness
  (b = 0.2 a) is a rendering choice; van der Marel et al. (2002) find its disc thick.
- **Measured beats modelled.**
  - The masses through the population model give the LMC −18.96 and M33 −19.59.
    McConnachie (2012, Table 3) measures −18.1 and −18.8: the literature's masses imply
    M/L_V ≈ 1.8, the population model's is ≈ 0.8.
  - The SMC agrees within 0.2 mag.
  - So where an absolute V is measured, the light is scaled to it. M31 has none in hand,
    and is drawn from its masses.
  - The scale counts only the light the glow draws (below), so what is drawn, not the
    model's total, is the measured magnitude.
  - `galaxycheck` marches the drawn glow through each galaxy and holds it to the measured
    within 0.005 mag, and the mass-based prediction within 1 mag.
- <a id="the-light-a-neighbour-draws"></a>**The light a neighbour draws.** The glow
  is drawn on a box of half-height h, 4 kpc or the spheroid's sphere if taller (a ray
  that misses the box has no fragment). It marches a disc through the box, its light tapering to zero over
  the last fifth of the galaxy's extent e, and a spheroid through a sphere of radius r_s
  (`GalModels.sphere_reach`). Left out, the lost light is 0.15 mag for M33 and the LMC
  and 0.3 mag for the SMC.
  - A Hernquist sphere holds (r_s/(r_s + a))² of its light within r_s. Flattened to axes
    b and c, its light is round in r' = (u, y/c, v/b), the sphere's edge lies at r' = r_s q(n)
    along a direction n, and the share is ∫ q⁻³ (r_s q/(r_s q + a))² dΩ / (4π b c).
  - A Miyamoto–Nagai disc's mass in a cylinder of radius R and half-height h is the
    gravitational flux out of it over 4πG. Through the side, with ζ = √(z² + b²):
    M_side/M = R² ∫₀ʰ dz / (R² + (a + ζ)²)^{3/2}.
  - Through the two caps, each integral over R' closed: M_caps/M = (h/ζ_h)(1 − s/√(R² + s²)),
    with s = a + ζ_h. For b = 0 and h → ∞ the sum is the Kuzmin disc's 1 − a/√(R² + a²).
  - A disc drawn from a baked map (M33, the LMC) holds all its light in the map, and only
    the taper cuts it: an exponential of scale h holds 1 − (1 + x) e^(−x) within x = R/h.
  - The taper w(R) = smoothstep(e, 0.8e, R) weights the cumulative mass by parts:
    drawn/M = ∫ M(R)/M · (−dw/dR) dR over 0.8e to e, where −dw/dR = 6t(1 − t)/(0.2e) and
    t = (e − R)/(0.2e).
- **Checked:**
  - Each neighbour's frame tilts by its stated inclination and lays its line of nodes
    at its stated position angle, to 0.01°.
  - M33's drawn glow matches the CPU integral along the same rays, turned into its
    frame, to 0.1 %.
- **Limits.**
  - Light only: the halos wait for encounters (phase 4).
  - The neighbours hold their places from t = 0.
  - Which side of each disc is near is not modelled.
  - M33 has its two inner arms and the LMC its bar (below); the SMC has neither. None
    has dust.
- **M33's arms** are the two inner arms Smercina et al. (2023, PHATTER) find in resolved stars of
  every age.
  - **Geometry:** log spirals of pitch 23.78° through R0 0.90 kpc, 157.5° apart (their
    155–160°: the arms are not symmetric), traced to 3.2 kpc (Javadi et al. 2017). They wind
    counterclockwise outward on the sky, and their phase was set by laying them over ESO's
    image. Their width (σ 0.3 kpc), start and fade are set by eye.
  - **Light:** M33's disc is split at one star formation rate into its last 100 Myr and the rest,
    the whole at its measured V. The rate this implies, 0.37 M☉/yr, is reported and not imposed;
    Verley et al. (2007) find 0.2 M☉/yr for the inner disc alone.
  - **Strength:** the young light is gathered into the arms (90 % of it) so its normalised m = 2
    amplitude over 1–3.2 kpc is 0.6, the middle of the 0.4–0.8 M33 shows in Hα and dust
    (Combes et al. 2012). The old disc stays smooth.
  - **Checked:** the drawn young light's amplitude is 0.600; the glow matches the CPU integral to
    0.2 %.
  - **Missing:** M33 is flocculent, with many arm fragments and bright H II regions between the
    two main arms; here it is a clean two-armed spiral.
- **The LMC's bar** is Rathore et al.'s (2024) measurement from completeness-corrected Gaia DR3
  red clump stars.
  - **Measured:** axis ratio 0.54, PA 121.26° on the sky, a peak bi-symmetric amplitude A2 of
    0.27, and A2 falling to half its peak at 2.58 kpc (their AM1 radius). Their preferred
    2.13 kpc comes from where the m = 2 phase turns, which a straight model bar cannot show.
  - **Drawn** as a Ferrers (1 − m²)² bar in the disc's map:
    - its share of the disc's light (0.33) is solved so the map's own peak A2, in their 0.1 kpc
      annuli, is 0.27;
    - its length (3.25 kpc) is set so A2 halves at 2.58 kpc;
    - its angle in the disc's plane is the sky PA deprojected through the disc's axes: 30.55°
      from the line of nodes, the ~30° misalignment they note.
  - **Not drawn:** the bar's 0.76 kpc offset from the disc's centre (its direction is only
    shown in a figure), its tilt out of the plane, and the arm on its western end.
  - **Checked:** measured back out of the drawn map, the peak A2 is 0.27, A2 halves at 2.65 kpc
    (0.1 kpc bins), and the bar lies at PA 121.16° on the sky. The LMC's glow matches the CPU
    integral in its frame to 0.1 %.
  - The eye adapts to the Milky Way, so seen close up they are overexposed.

## Galaxy types (phase 3c)

Galaxies too far for the Milky Way's scene are scenes of their own (`GalModels.TYPES`,
presets `gal_m87`, `gal_m104`), drawn from their measured total light. Each part takes
its share of that light from a published decomposition, and its stellar mass follows
through the population model. They have no tracers.

The share is of the light drawn, so what the glow's bounds leave out is made up, as for
the neighbours ([the light a neighbour draws](#the-light-a-neighbour-draws)); with arms, the
disc's population starts at 100 Myr, as drawn, since the arms hold the younger stars.
`galaxycheck` marches each glow drawn from parts without its dust, since RC3's V_T⁰ is
corrected for the galaxy's own, and holds it within 0.005 mag of the measured.
Seen face-on, M104's dust then takes 0.03 mag.

- **M87,** drawn from its measured light, not a fitted shape. Its landmark is M87*:
  6.5 × 10⁹ M☉ (EHT Collaboration 2019).
  - **The profile.** Kormendy et al.'s (2009) Table 3 is M87's V surface brightness along its
    major axis, 98 points from 0.017″ to 2444″ (D = 17.22 Mpc).
    - It is corrected for the Galaxy's A_V = 0.072 (their Table 1): it was not, and then
      integrates to M_VT within 0.01 mag.
    - Radii are circularised by √(1 − ε), and M87 is drawn round.
  - **The density.** Abel inversion turns the profile into the luminosity density whose
    projection it is (`GalModels.abel`), tabulated as ln j on 256 radii even in ln r. The
    glow reads the table (spheroid kind 2).
  - **Past the last point** (155 kpc circularised), the profile carries on as Kormendy et
    al.'s Sérsic fit does (n 11.84, r_e 704″, with Ciotti & Bertin's 1999 b_n), joined
    there. It runs out to 20 times in the inversion and is drawn to 3 times, 465 kpc. The
    last measured segment itself falls only as R^−1.3 near the sky limit, and carrying
    that on would add light nobody measured.
  - **Mass.** Held in the potential as a Hernquist sphere of the same mass and half-mass
    radius.
  - **Checked:**
    - Projected back along parallel rays, the drawn galaxy matches all 92 measured points
      inside 78 kpc to 0.039 mag; the worst is the very centre.
    - Its light within the last point's circle is M_V −22.94 (Kormendy et al.: −22.95).
    - Its glow matches the CPU integral to 0.3 %.
- **M104, the Sombrero.**
  - Drawn at M_V = −22.35: RC3's V_T⁰ = 7.55 at McQuinn et al.'s (2016) 9.55 Mpc.
  - Light split as in Gadotti & Sánchez-Janssen's (2012) bulge + disc + halo
    decomposition, rescaled from 9.1 Mpc:
    - the bulge (13 %, n 1.9, r_e 0.46 kpc) and halo (52 %, exponential, r_e 6.0 kpc,
      ε 0.28) as one flattened Hernquist sphere of their joint half-light radius,
      4.68 kpc;
    - the disc (35 %) as a Miyamoto–Nagai disc of its 1.89 kpc scale length's
      half-mass radius, 0.78 kpc thick.
  - Inclination 84°.
- **M104's dust** is De Looze et al.'s (2012, Table 2) radiative-transfer model:
  - a ring of 7.5 × 10⁶ M☉ in four Gaussians at 6.1–8.75 kpc, 20 pc thick, and an inner
    exponential disc of 4.07 × 10⁵ M☉ (both rescaled from 9.2 Mpc);
  - the dust's V opacity is Draine's (2003, Table 4): C_ext(V) = 4.89 × 10⁻²² cm² per H at
    M_H/M_dust = 90, so 2.63 × 10⁴ cm²/g;
  - a constant-density 20 pc slab is drawn as a sech² layer of the same column;
  - the glow samples on the thinnest dust layer, so a 20 pc ring is not stepped over.
- **Checked:**
  - both drawn at their measured magnitudes;
  - κ re-derived from Draine's two numbers;
  - M104's dust integrated back to De Looze et al.'s ring and inner disc masses (0.0 %
    and 0.9 %);
  - its glow against the CPU integral in rows across the ring (0.8 %).
- **Against photographs** (ESO, ESA/Hubble; shown side by side in the showcase, judged
  by eye):
  - M104's ring spans the same share of the field as Hubble's dust lane, at the same tilt.
  - M87's size and colour match ESO's VLT image.
  - Missing: M87's jet and globular clusters, and the mottled texture of M104's lane.
- **M51, the Whirlpool,** with its companion NGC 5195 (preset `gal_m51`): see
  [M51](#m51) below.
- **NGC 5195:**
  - drawn at RC3's V_T⁰ = 9.58, a Hernquist sphere of RC3's effective aperture
    (r_e = 57.15″);
  - placed from NED's positions (4.41′ apart) and 35 kpc behind M51, inside the 20–50 kpc
    Dobbs et al. (2010) and Salo & Laurikainen (2000) give (via Marchuk et al. 2024);
  - drawn round, though Wei et al. (2020) give i 43°.
- **The glow box** now holds the spheroid's whole march radius. A ray that misses the
  box has no fragment, so a taller spheroid was cut off flat.

## M51

M51 is drawn from one radiative-transfer model of its stars and dust together, so its dust dims
light the model says is there, not light already dimmed. Everything below is at McQuinn et al.'s
(2016) 8.58 Mpc; values from other distances are rescaled.

### Where its arms are

- **Orientation and pitches** from Egusa et al.'s (2017) stellar mass map: i 24°, PA 169°; the
  arms' pitch is 19.3° and 23.4° inside 150″ (6.24 kpc), 37.4° and 32.4° beyond, measured
  over 30″–220″. Arm 2 is the one joined to NGC 5195.
- **Widths:** σ across the arm 0.815 and 0.785 kpc, Marchuk et al.'s (2024) radial FWHM.
- **Phase, by overlay.** The arms wind clockwise outward on the sky. Their phase was set by
  laying the ridges over Hubble's image (heic0506a). The image's scale and north were taken
  from the two nuclei rather than its caption: 588 px for NED's 4.41′, north 92.2° clockwise
  from up. Their start (rising over 1.5–3.5 kpc) and their fade past the measured span are
  set by eye.

### Its stars

Inman et al. (2023) fit M51 from the ultraviolet to the submillimetre (Tables 3, 5, A1, A3).
- **Components:**
  - a Sérsic n = 4 bulge of R_e 0.35 kpc, drawn as a Hernquist sphere;
  - an inner and a main old disc and an inner and a main young (thin) disc. Each is zero
    inside R_tin, linear from χ to 1 up to R_in, then exponential to R_t (their eq. 1), and
    exp(−|z|/z) in height: z 0.19 kpc old, 0.09 young.
- **V band.** Their L_ν at 4719 and 6185 Å give V at 5476 Å, log-linear in L_ν and in scale
  length, and L☉ from the Sun's 4.80 AB (Willmer 2018).
- **Beyond their fit.** Their fit ends at 6.8 kpc, where the disc stops being axisymmetric.
  Past it the main discs carry on at their outer disc's scale lengths (2.0 kpc old, 1.45
  young): an extrapolation.
- **Gathered into the arms**, each ring keeping its mean:
  - the old disc to the K-band arm/interarm contrast Rix & Rieke (1993, §4.2) measure: 1.8
    at 70″, 3 at 125″, 2 at 150″;
  - 91 % of the young light, the arms' share of M51's H II Hα (Lee, Hwang & Lee 2011, §5.2:
    10^41.1 erg/s in the arms against 10^40.1 between).
- **In the map.** Both discs sit in the arm map, b and r, as bolometric surface luminosity.
- **Intrinsic light.** Their stars give M_V −21.94 before the dust.

### Its dust

- **Discs.** Inman et al.'s inner and main dust discs, in the same form: τ_B 5.33 and 2.62
  face-on at R_in 0.8 and 2.7 kpc, scale lengths 5.0 and 6.0 kpc, z 0.16 kpc. τ_V = τ_B/1.324
  (Rieke & Lebofsky 1985), and mass through Draine's κ_V.
- **Lanes.** PAWS puts 66.5 % of the CO outside the centre in the arms (Colombo et al. 2014,
  Table 2), so that share of each ring's dust lies in lanes, the ring's mean kept.
  - A lane follows its gas arm's pitch: 19.9° and 18.8° inside 150″, 27.8° and 27.6° beyond.
  - It has the gas arm's azimuthal FWHM, 30° inside and 5° beyond (Egusa et al. 2017).
  - It is anchored upstream of the young stars by ΔΘ = Ω_p t_SF (R_CR/R − 1) at 4 kpc:
    Egusa et al.'s (2009) arm-1 fit, Ω_p t_SF = 0.225 rad and R_CR 2.9′, with a flat
    rotation curve. That is 10.4°.
- **Mass:**
  - 4.22 × 10⁷ M☉ inside 6.8 kpc, 1.13 times Inman et al.'s 3.74 × 10⁷: Draine's V opacity
    against their Weingartner & Draine B-band model;
  - 8.3 × 10⁷ M☉ with the extrapolated outer disc, 0.93 of Mentuch Cooper et al.'s (2012)
    whole-galaxy Herschel mass.

### H II regions

Drawn by `GalHII` and `shaders/galaxy/galaxy_hii.gdshader`.
- **Hα.** The star formation rate's Hα, log SFR = log L(Hα) − 41.27 (Kennicutt & Evans 2012,
  Kroupa IMF), at Inman et al.'s 4.11 M☉/yr: 7.7 × 10⁴¹ erg/s. Of it, 45 % is in diffuse gas
  (Thilker, Braun & Walterbos 2000) and is added to the arms' smooth light; the rest lies in
  regions.
- **Brightness and size.**
  - Brightness follows Lee et al.'s (2011) luminosity function: L^−2.25 above 10^37.1 erg/s,
    L^−1.42 below, 10^35.5 to 10^39.0 at 9.9 Mpc.
  - Sizes follow L ∝ D^3.04, anchored at 8 pc for 10^35.5. A region is a Gaussian of
    σ = D/4.
- **Lines.** Hα, [N II] at half the Hα (Bresolin et al. 2004, via Lee et al.) and Hβ at Hα/2.86
  (case B). They are coloured through the CIE functions per unit power, as the populations'
  light is (`GalPopulation.visible_line`).
- **Stars.** Each region holds a point cluster with its share of the light of all stars
  under 10 Myr (where 90 % of the Hα comes from). The regions as a whole hold 55 %, taken
  from the young disc's light.
- **Drawn.** 28 272 regions are drawn one by one. Those under 10^36.5 erg/s, 72 % of them with
  14 % of the regions' light, stay in the arms' smooth light, lines and all.
- **Clustering.** Regions stand in complexes along the young light. Each is a hierarchy
  (Soneira & Peebles 1978) with a Poisson number of children per halving of scale, three on
  average: a fractal of dimension log 3/log 2 = 1.585, against Grasha et al.'s (2019) D₂ =
  2 + α = 1.60.
  - Its top scale, 220 pc, is set so the regions' two-point correlation over 100–3000 pc has
    Grasha et al.'s slope, −0.40 ± 0.05 for clusters under 10 Myr. Clustering fades to
    random by 700–900 pc, their "few hundred parsec".
- **Dimming.** Each region is dimmed by the model's dust between it and the camera: 16 steps
  through the dust layer.

### Checked

`galaxycheck`:
- **Map.** Each band of radius keeps Inman et al.'s profiles (old, young, dust: under 1 %).
  The dust map holds its profile's mass (0.1 %).
- **Arms.** The lanes stand 10.44° upstream at 4 kpc. The old disc peaks 3.03× its valley at
  5.2 kpc. At 4 kpc, every texel of young light matches 91 % gathered into the arms.
- **M_V.** The rays add back to the stars' light without dust (0.000 mag). Through its dust,
  M51 shows **M_V −21.27, 0.26 mag fainter than RC3's −21.53**. Our dust extinguishes and
  never scatters, while Inman et al.'s model, with scattering, absorbs 38 % even
  bolometrically; ours takes 45 % of V.
- **H II regions:**
  - their Hα (exact) and the bright slope of the luminosity function recovered from the
    catalogue (0.569 against 0.574);
  - their sizes;
  - the young light kept between the smooth arms and the clusters (1e-7);
  - their clustering slope (−0.36 with 1031 regions; within 2σ of the estimator).
- **Lee et al.'s catalogue.** It holds 0.5 dex less Hα than the star formation rate gives. It
  misses faint and blended regions, and its 3.1 mag extinction correction is a mean.

`galaxylookcheck`:
- **Glow.** M51's glow, with its maps and dust, against the CPU integral across it: 0.4 %.
- **H II regions.** The 28 272 regions' drawn light against the CPU's sum, each dimmed as the
  shader marches the dust: 0.73 %.

### Against Hubble

Set side by side at matched field and north, judged by eye:
- **What agrees:** the arms' layout, their dust lanes on the inner edges, and the knots along
  them.
- **The knots' colour.** Hubble's palette records Hα more strongly than the eye. Hα at 656 nm
  sits on the tail of the eye's red response, so the regions here are bluish-white with a
  pink cast, not Hubble's pink.
- **NGC 5195's place.** The comparison is rendered from 316 kpc, since Godot's field of view
  stops at 1°. From there NGC 5195, 35 kpc behind M51, sits 10 % nearer to it on the sky
  than it does from the Sun.

### Cost

`m5-budget` measures M51 framed whole and from 8 kpc, where the glow fills the frame.
- A Hernquist spheroid's glow is marched out to where what lies beyond is 0.5 % of its
  galaxy's light, or to its extent. M51's bulge, 2 % of its light, ends at 1.18 kpc; the
  others are still bounded by their extents.
- A galaxy with nothing in its disc's layer (NGC 5195, M87) skips that march.
- The resolved-star lattice runs only with the camera inside its galaxy's disc, not merely
  in its plane.
- The H II regions' quads span ±2σ, with each blob scaled to keep all its light.

### Missing

- **Scattering.** Dust only extinguishes.
- **Fine structure:**
  - the fine dust filaments and feathers between the arms;
  - the 10–100 Myr clusters that make Hubble's arms grainy and blue;
  - the outer arm's link to NGC 5195;
  - NGC 5195's own dust and shape.

## Encounters (phase 4)

The preset "Milky Way meets M31" starts the Milky Way, M31 and M33 from van der Marel
et al.'s (2012b) canonical model. Their present positions and velocities are those
paper's Table 2: M31's from Hubble's proper motion, M_vir 1.5 × 10¹² M☉ each for the
two large galaxies and 1.5 × 10¹¹ for M33. The model runs in two regimes. While the
galaxies are far apart, it is cheap and exact enough. Near each other, everything
moves under everything else's gravity.

### The orbits (GalOrbits)

The galaxies' centres follow van der Marel et al.'s semi-analytic method (their §2.2
and Appendix A):

- **Haloes.** Each halo is a Hernquist sphere. Its mass and scale match the NFW
  halo's density as r → 0 and its mass within r₂₀₀; this is their paper II's
  Appendix A, with h 0.7, Ω_m 0.27 and Δ_vir 360.
- **Gravity.** Galaxy j pulls on galaxy i with −G M_j/(r + a_j)², softened to a
  constant density inside 2 kpc.
- **Friction.** Chandrasekhar's formula, with Hernquist's isotropic dispersion and
  their fitted Coulomb logarithm ln Λ = max(L, α ln(r/(C a))). The constants (α, C, L)
  are (0.15, 0.17, 0.02) for galaxies within 1.5× in mass and (1.0, 1.22, 0) for a
  satellite.
- **Frame.** The system's mean acceleration is taken out, as theirs is.
- **Integrator.** Classical Runge–Kutta at 1 Myr.

`encountercheck` holds the method to their numbers:

- M33 passes M31 at 79.6 kpc after 0.916 Gyr. Their semi-analytic orbit gives
  80.3 kpc at 0.93 Gyr, and their N-body run 79.6 kpc at 0.92 Gyr.
- M31 reaches its first pericentre at 4.14 Gyr. Their N-body run has it at 3.97 Gyr.

### Far apart: restricted stars

Each galaxy is first a rigid potential riding its centre:
- its Hernquist halo (M_vir less disc and bulge, as their N-body haloes are);
- a Miyamoto–Nagai disc about its spin, with a = 0.9688 R_d and b = 0.1 R_d;
- a Hernquist bulge, with a = R_e / 1.8153.

The disc and bulge stars are test particles moving in every galaxy's potential. They
take drift–kick–drift steps of 0.5 Myr, with the centres at mid-step. The C kernel
(`run_encounter`) and the GDScript one agree bit for bit.

The galaxies are built from their Table 1:
- the Milky Way: disc 7.5 × 10¹⁰ M☉, R_d 3 kpc; bulge 10¹⁰, R_e 0.6;
- M31: disc 1.2 × 10¹¹, R_d 5; bulge 1.9 × 10¹⁰, R_e 1.0;
- M33: disc 9 × 10⁹, R_d 1.3; no bulge.

The spins of the Milky Way and M31 are the ones their §3.2 states. M33's is derived
from its Table 1 geometry (inclination 52.9°, line of nodes 4°, near side W, approaching
side N) by `GalModels.disc_spin`. The same derivation from M31's geometry lands 0.86°
from their stated vector. Our spin–orbit angles, 32.5° for the Milky Way and 76.1° for
M31, match their 32.6° and 76.2°.

Discs are warm, set up following Hernquist (1993):
- σ_R² ∝ e^(−R/R_d), normalised to Toomre's Q = 1.5 at 2.76 R_d (the Sun's radius in
  the Milky Way's scale lengths);
- σ_φ from the epicycle approximation;
- σ_z from an isothermal sheet (σ_z² = π G Σ z₀, z₀ = 0.1 R_d);
- the mean rotation from the Jeans equation with asymmetric drift:
  v̄_φ² = v_c² + σ_R² (1 − κ²/4Ω² − 2R/R_d).

Q stays above 1.47 from 0.5 to 6 R_d in all three discs. Bulge stars are drawn from the
bulge's distribution function (below).

### Live

With test particles alone the encounter is wrong. Set beside van der Marel et al.'s
Fig. 5, the restricted run showed:
- The discs barely respond. At 4.47 Gyr only 0.13 % of the Milky Way's stars lie beyond
  30 kpc.
- The merger leaves two overlapping discs ±25 kpc across, where van der Marel et al.'s
  remnant is an elliptical.

Rigid potentials have no disc self-gravity to amplify a tidal response, and nothing to
take up the orbit's energy. Changing the pericentre does not help: scaling M31's
transverse velocity to bring it to 25 kpc still leaves the Milky Way's disc intact.

So when the Milky Way and M31 come within 250 kpc (at about 3.5 Gyr), every galaxy becomes
particles:
- The stars keep their places and take their masses: 4 × 10⁶ M☉ each, Plummer softening
  0.1 kpc.
- Each halo arrives about its galaxy's centre, at its galaxy's velocity. It was drawn
  when the encounter was built: particles of 4 × 10⁷ M☉, softened by 1 kpc, cut at the
  virial radius.
- Each disc's mean rotation is re-set from the pull its own galaxy's particles exert
  in rings of R_d/4, because an exponential disc is not a Miyamoto–Nagai one.
- From then on every particle pulls on every other.

The haloes and bulges are in equilibrium (`GalEddington`):
- Their Hernquist density is sampled with the distribution function that Eddington's
  formula gives in the galaxy's whole spherical potential: halo, bulge and the disc's
  enclosed mass taken as a sphere.
- dρ/dΨ is held constant across each step of a 600-point grid, and the square root
  integrated exactly across it.
- Speeds come from per-radius cumulative tables.
- Particles come in mirrored pairs, (x, v) and (−x, −v), so a halo sits exactly on its
  centre at rest.

The sampler is checked on a lone Hernquist sphere (`encountercheck`):
- f(E) has Hernquist's (1990) closed form's shape to 2 × 10⁻³;
- the dispersion matches his at 0.1–10 a within the sampling noise;
- the sample is virialised, 2K/|W| = 1.01, with his W to 1 %.

The kernel is a Barnes–Hut octree (Barnes & Hut 1986):
- leaves of 8 particles, monopole cells;
- a cell is opened when nearer than side/θ plus its centre of mass's offset from the
  cube's centre, with θ = 0.7;
- a group walk (Barnes 1990): one interaction list for every ≤ 32-particle node;
- pairs softened by the larger of the two softenings;
- kick–drift–kick at 1 Myr.

The C kernel (`run_live`) uses every core. Each particle's force is summed by one thread
in a fixed order, so the bits are the same on one thread as on ten, and the same as the
GDScript twin's. Against direct summation, the accelerations err by 0.3 % at the median
and 2.4 % at the 99th percentile.

Left alone for 300 Myr, a live Milky Way:
- keeps its energy to 10⁻³;
- keeps its halo's 10 % and half-mass radii to 1 %;
- thickens its disc at 6–10 kpc from 0.27 to 0.42 kpc rms. The heating is
  mostly the disc's own spirals: halo particles a quarter as heavy heat it barely
  less.

How the numbers were set, on the lone Milky Way over 600 Myr:
- **Halo particles.** At 10⁷ M☉, σ_z at 6–10 kpc rose from 21 to 26 km/s; at
  4 × 10⁷ M☉, to 28 km/s, at 38 % of the cost per step. So the cheaper mass was taken.
- **Halo softening.** 1 kpc heated the disc less than 0.3 kpc did (28 against 30 km/s).
- **Step and opening angle.** A 1 Myr step and θ 0.7 hold the energy to 10⁻³ and the
  forces to the accuracy above.
- **The switch.** At 250 kpc the discs go live about 0.6 Gyr before first passage:
  enough for the haloes to settle, and short enough to limit the heating.

### Against van der Marel et al.'s N-body run

`encounterlivecheck` runs the scene's encounter to 10 Gyr. Their N-body run used
1.4 million luminous and 1.05 million dark particles.

| | here | their N-body |
|---|---|---|
| M31's first pericentre | 36.1 kpc at 4.12 Gyr | 35.0 kpc at 3.97 Gyr |
| merged (within 5 kpc for 1 Gyr) | 6.15 Gyr | 6.29 Gyr |
| remnant, log Σ at R^1/4 = 1, 1.5, 2, 2.38 | 3.54, 2.63, 1.62, 0.72 | 3.6, 2.5, 1.6, 0.8 |
| M31's first apocentre (not judged) | 145.9 kpc at 4.75 Gyr | 171.9 kpc at 4.79 Gyr |
| M33's closest to the Milky Way (not judged) | 30.4 kpc at 3.93 Gyr | 97.3 kpc at 3.83 Gyr |

Their profile values are read off their Fig. 7 to about ±0.05 dex. Both remnants follow
de Vaucouleurs' law with R_e ≈ 7 kpc: an elliptical.

M31's first apocentre falls short of theirs, and the cause is upstream. Before the
switch, M33's orbit is semi-analytic, a method they found inadequate for M33 (their
Appendix A). Here M33 dives through the Milky Way's halo before M31 arrives, where in
their N-body run it passed at 97 kpc. Without M33, the live run's apocentre is 145 kpc
against the semi-analytic 124. The live haloes take less of the orbit's energy at first
passage than the fitted friction does.

### Cost

- The scene steps the encounter on a worker, a batch at a time, while the frame draws
  the last batch's stars.
- A live step of 127 000 particles takes about 44 ms on an M5, so the clock reaches
  about 20 Myr/s and the HUD reports "limited" beyond that.
- The restricted phase runs at hundreds of Myr/s.
- `perfcheck` measures the frame rate with the live kernel running (`galaxy-encounter-live`).

### The Antennae

The preset "The Antennae" is NGC 4038/4039 as Privon et al. (2013, Table 2) reconstructed it
with Identikit.

**Their encounter.**
- Two equal galaxies on a parabolic orbit (e = 1), pericentre p = 0.25.
- Disc spins (i, ω) of (65°, 345°) for NGC 4038 and (70°, 95°) for NGC 4039.
- Seen at t = 5.62, the idealised pericentre being at t = 2, from Euler angles
  (−20°, 283°, −5°).
- Scaled by L = 19.7 kpc and V = 265 km/s, with G = 1. A time unit is therefore 72.7 Myr,
  and "today" is 408.5 Myr after the start.

**Their galaxy** is Barnes & Hibbard's (2009, App. B), which Privon et al. used for their
self-consistent runs:
- a Hernquist bulge of 0.0625, a = 0.02, cut at 4.0;
- an exponential disc of 0.1875, R_d = 1/12, sech² height 0.0075;
- an NFW halo with 0.16 inside a_h = 0.25, tapered beyond b_h = 0.98015 so that the whole
  halo holds 1.0.

The taper (their eq. B2) keeps the density and its slope continuous at b_h. `GalEddington`
samples that halo, and its total comes out at 1.00000. Discs follow their eq. B10–B13:
- σ_z from the isothermal sheet;
- σ_R = (1 + R/(R + q_σ)) σ_z, which is ≈ 2 σ_z in the body and → σ_z at the centre;
- the Jeans equation for the mean rotation.

Particle counts are those of Privon et al.'s self-consistent runs: 8k bulge, 24k disc and 32k
halo particles a galaxy. Every particle is softened by 0.0075 (0.15 kpc), with steps of
0.25 Myr; their step was 1/256 of a unit, 0.28 Myr. The encounter is live from the start.
Each disc's velocities are drawn once the live potential exists, from the particles' own
pull. Measured that way, v_c at 3 R_d is 1.267 units, against their 1.26.

**The angle conventions.** Their papers define i and ω relative to the orbit's angular
momentum and the separation at periapsis, and θ as Euler angles. They do not give signs or
the Euler order. The reading used here:
- the ascending node lies ω behind the direction to the companion;
- the view is R_x(θX) R_y(θY) R_z(θZ);
- sky X is east.

It was chosen against their own model, not the telescope data. Their Fig. 6a's particles
were extracted by colour, and each reading's tails at t = 5.62 were scored by mean
nearest-particle distance. This order scored 7.4 kpc; the next best (Z-Y-Z) scored 7.6, the
reverse order 14.7, and the transposes 24–34. With ω measured ahead instead of behind, the
northern tail's velocity collapses. With the reading used here, `encountercheck` finds:

| | here | Privon et al. |
|---|---|---|
| first pericentre | 6.2 kpc, 260 Myr before now | about 5 kpc, 260 Myr before now |
| back together by now | within 1.1 kpc | "around its second passage" |
| tail ends (position angle) | 207°, 32° | 194°, 37° (their Fig. 6a's particles) |
| line of sight | south tail recedes 119 km/s, north approaches 87 km/s | the same signs (their Fig. 6b) |

At full resolution the nuclei come back within 1 kpc 34 Myr after now; their model merges
70 Myr after it.

**Against the sky.** The southern tail runs south-west in a straight sweep. The real one,
in ESO's DSS2 image and in their model, drops south first and then hooks west. Privon et al.
also reproduced the hook only partly, and they quote their spins as good to 15°. No angle was
refitted here.

### Limits (phase 4)

- **Particle counts.** About 50 000 luminous particles where their run had
  1.4 million. Tails are there, but thin.
- **Halo mass resolution.** Halo particles of 4 × 10⁷ M☉ heat the discs over Gyr. The
  discs go live 0.6 Gyr before first passage to limit it.
- **Gas.** None: no starbursts, no gas tails.
- **M33 before the switch.** Its orbit is semi-analytic, with the weakness above.
  Its orbit is uncertain in any case: with M31's measured proper motion, Patel, Besla
  & Sohn (2017) find a recent close passage of M33 by M31 improbable.
- **The Antennae** use Barnes & Hibbard's single galaxy model for both. Privon et al. note
  that its circular speed is high for real late-type discs. There is no gas, so none of the
  starburst that lights the real pair.
- **Today's odds.** Recent measurements put the chance of a Milky Way–M31 merger within
  10 Gyr at about even (Sawala et al. 2025). The preset follows van der Marel et al.'s
  canonical start, one realisation.

## Limits (phase 1)

- Phase 1 was axisymmetric and dust-free; phase 2a above adds the bar, the arms and
  the dust.
- Giants are in the glow but not drawn one by one; neither are white dwarfs. From
  the Sun the drawn sky holds only dwarfs within 40 pc, a few hundred stars, where
  the real naked-eye sky's ~5000 are mostly giants and luminous stars much farther
  away.
- The shader's copy of the mass-table lookup is checked through its output only
  (the hand-over test uses a fixed luminosity); its luminosity function is not
  measured in pixels.
- Colours are blackbody colours; real stellar spectra and line blanketing are not
  modelled.
- The resolved lattice has 128 slots per cell, enough wherever ≤ ~100 stars above
  0.5 M☉ share 10³ pc³: the disc beyond ~3 kpc. Denser regions (the bulge) are drawn
  short of stars, and the glow does not make it up. Still so after phase 2b; see its
  limits.
- The gas is collisionless: cold test particles, not a fluid.

## Do the checks catch defects?

`tools/mutationcheck.py` breaks the code in place, one defect at a time, runs the
check that should catch it, and restores the file. Twenty-one defects are caught. Phase
2a's seven are the spiral's radial force, the bar's force in the GDScript kernel alone
(which the native kernel then disagrees with), the work tally's sign, dust arms cut
off on the wrong side of r_m, doubled young light, a step's light attenuated at its
midpoint, and a spheroid unabsorbed by the disc's dust. Bolometric colours now leave
the integrated B−V inside its 2σ and are caught by the populations' pinned colours. Phase 1's are a
Julian year in the km/s conversion, a mass table evenly spaced in u, a wrong force share at R0, the disc's vertical
force in the potential and in the integrator, the bulge table's derivative, a half
kick, the Jeans equation's sign, no giants, bolometric instead of visible colours, a
10 % glow, a star's flux over 2π, an off-centre star lattice, and a glow that keeps
the drawn stars' light. One is a known miss: dropping the radial-period weight from
the Shu sampling reshapes only the eccentric tail of a disc this cool, below the
stationarity test's noise. The hand-over test resolves about 6 %, so a smaller
defect in the star counts (one extra star in each cell, say) also passes it.

Phase 4's thirteen are all caught by `encountercheck`:
- the orbits: no dynamical friction, and the Coulomb logarithm read as a power;
- the restricted disc pulling as a sphere;
- the sampler: radii drawn from the wrong cumulative mass, and speeds set without the
  disc's pull;
- the GDScript tree: opening cells without the centre-of-mass offset, and kicking a whole
  step each half;
- a warm disc without asymmetric drift;
- haloes going live at rest;
- the Antennae: ω measured ahead of the companion, the other Euler order, σ_R = σ_z, and a
  taper that breaks the halo's slope.
