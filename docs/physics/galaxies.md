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
| LMC | 2.7 × 10⁹ M☉ (van der Marel et al. 2009) | exponential, 1.3–1.5 kpc (van der Marel 2001; 1.4 here) | i 34.7°, PA 122.5° (van der Marel & Cioni 2001); 49.59 kpc |
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
  - They have no arms, bars or dust: the LMC's bar is missing.
  - The eye adapts to the Milky Way, so seen close up they are overexposed.

## Galaxy types (phase 3c)

Galaxies too far for the Milky Way's scene are scenes of their own (`GalModels.TYPES`,
presets `gal_m87`, `gal_m104`), drawn from their measured total light. Each part takes
its share of that light from a published decomposition, and its stellar mass follows
through the population model. They have no tracers.

The share is of the light drawn, so what the glow's bounds leave out is made up, as for
the neighbours ([the light a neighbour draws](#the-light-a-neighbour-draws)); with arms, the
disc's population starts at 100 Myr, as drawn, since the arms hold the younger stars.
`galaxycheck` marches each glow without its dust, since RC3's V_T⁰ and Kormendy et al.'s
M_VT are corrected for the galaxy's own, and holds it within 0.005 mag of the measured.
Seen face-on, M104's dust then takes 0.03 mag.

- **M87.** A Hernquist sphere of the 16.2 kpc half-light radius Kormendy et al. (2009,
  Table 1, from the 2-D profile) measure, drawn at their M_VT = −22.95 (D = 17.22 Mpc).
  Its landmark is M87*: 6.5 × 10⁹ M☉ (EHT Collaboration 2019). Kormendy et al. fit
  n ≈ 12 to its cD halo; a Hernquist sphere is n ≈ 4, so the far halo is too faint.
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
- **M51, the Whirlpool,** with its companion NGC 5195 (preset `gal_m51`).
  - **Light.** Drawn at M_V = −21.53: RC3's V_T⁰ = 8.14 at McQuinn et al.'s (2016)
    8.58 Mpc. Marchuk et al. (2024) decompose it in the g band with each spiral arm as
    its own component (rescaled from 8.9 Mpc):
    - bulge 8 % (r_eff 16.1″), a Hernquist sphere;
    - disc 56 % (h 70.0″);
    - two arms of 19 % and 17 %. Their pitches are 11.0° and 14.1°. Their radial FWHMs
      are 47.0″ and 45.8″, so σ across the arm = FWHM/2.355 × cos pitch. Their light
      falls outward with h_s 51.0″ and 62.4″, and their width does not grow with radius.
  - **Orientation:** i = 46.2°, PA = 24.4°. The literature spans 20° to over 50°;
    Marchuk et al.'s arms were measured at theirs.
  - **The arms** go through the Milky Way's arm machinery, generalised: per-arm decay,
    no width growth, their own radius span and windings, and a mirror flag (unused here:
    the winding already matches).
  - **Rendering choices, set to Hubble's image by eye:** the arms' phase; their span
    (1.5–10.5 kpc); their light rising over the first 2 kpc and fading over 0.6 rad past
    their ends; the arms' and disc's thicknesses. Marchuk et al.'s own arm start and
    maximum were not read.
  - **No dust.**
  - **The arms' light** is the measured 36 % of the total, as the young population's
    colour. Calzetti et al.'s (2005) 3.4 M☉/yr over 100 Myr would give only 0.36 of it:
    the g-band arm light also holds older stars gathered in the arms.
- **NGC 5195:**
  - drawn at RC3's V_T⁰ = 9.58, a Hernquist sphere of RC3's effective aperture
    (r_e = 57.15″);
  - placed from NED's positions (4.41′ apart) and 35 kpc behind M51, inside the 20–50 kpc
    Dobbs et al. (2010) and Salo & Laurikainen (2000) give (via Marchuk et al.);
  - drawn round, though Wei et al. (2020) give i 43°.
- **Checked:**
  - all four drawn at their measured magnitudes;
  - the arms' drawn light equal to the measured;
  - each arm's light along its ridge falling with its measured h_s (within 2.5 %);
  - NGC 5195's offset (4.413′, 35.0 kpc);
  - M51's glow against the CPU integral across its middle.
- **Against Hubble** (heic0506a, rotated to its north 91.9° right of vertical):
  - the arms wind the same way and NGC 5195 sits where it does;
  - the model looks more inclined than the image, and has none of the dust lanes, H II
    regions or blue colour of the real arms.
- **The glow box** now holds the spheroid's whole march radius. A ray that misses the
  box has no fragment, so a taller spheroid was cut off flat.

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
