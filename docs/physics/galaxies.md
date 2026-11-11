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
  wave: ρ = ρ0 e^{−(R−r0)/Rs} sech²(z/H) cos γ, with ρ0 = 1 amu cm⁻³, r0 = 8, Rs = 7
  and H = 0.18 kpc, and γ = N(φ − φp + ln(R/r0)/tan α), so its arms trail. It turns at
  28.2 ± 2.1 km/s/kpc (Dias et al. 2019). Its 12° pitch is the mean of the two major
  arms' measured pitches, and its crest lies on Perseus today (Reid et al. 2019).

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
  short of stars, and the glow does not make it up. Phase 2 nests the lattice.
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
