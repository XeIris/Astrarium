# The sky: procedural, resolution-free, band-aware

Code: `sim/sky.gd` (band tables, environments, uniform writers) and
`shaders/sky/sky.gdshaderinc` (the shader).

## Why no texture

- Lensing magnification near the photon ring is unbounded: the deflection
  map's Jacobian is near-singular and one texel covers tens of pixels. No
  fixed-resolution map survives that at any resolution.
- Lensing conserves surface brightness and amplifies flux by μ = 1/|det J|. An
  extended source (nebula, galactic band) keeps its brightness and distorts; a
  point source stays a point and gets brighter. A star sampled from a texture is
  forced into extended-source behaviour, and the Einstein ring reads as stretched
  paint.

So the sky is split by how lensing treats it:

| layer | contents | treatment |
|---|---|---|
| point | stars, pulsars, X-ray binaries, quasars | analytic, no texture |
| diffuse | galactic band, nebulae, CMB, X-ray background | plain radiance; surface brightness conserved; cacheable per direction |
| absorbing | dust | multiplies everything behind it, per band |

## The screen-space Jacobian

Let J = [dD/dx, dD/dy], the derivative of the outgoing ray direction per screen
pixel, taken with `dFdx`/`dFdy`. It already combines the fov, the resolution and
the lensing.

- w² = |dD/dx × dD/dy| is the solid angle a pixel covers. It shrinks as 1/μ
  where the hole magnifies.
- Diffuse layers ignore J.
- A star's offset is solved in pixels: J p = (s − D) in least squares. The PSF
  is a fixed Gaussian in p, normalised through J, so L = F·G(p)/w². Since
  w² ∝ 1/μ, the peak radiance rises exactly as μ, and the star stays a point.
- Extended sources (galaxies, supernova shells) are kept in source angle so that
  they do arc.

This is the ray-bundle filtering of James, von Tunzelmann, Franklin & Thorne
(2015, the DNGR renderer for *Interstellar*), measured rather than traced. The
PSF width is a constant number of pixels, as an instrument's is fixed on its
detector. A source smaller than that is clamped in size and dimmed to conserve
flux, the same rule as the sub-pixel body marker.

## Magnitudes from the cell subdivision

Stars are hashed into cells of a tangent-warped cube map. Tier k has 2ᵏ times as
many cells per face edge as tier 0, so 4× the stars of tier k−1. One magnitude
less flux per tier reproduces N(<m) ∝ 10^(0.6m), the Euclidean star-count law.
Calibration: 9096 stars brighter than magnitude 6.5 over the sky (Hipparcos).
Below the faintest tier the population is folded into the diffuse layer as
integrated unresolved starlight, which is what the Milky Way band is.

Each star hashes a temperature and takes its colour from the Planck locus, so
colour and band response can't disagree. The temperature draw is weighted for a
magnitude-limited (Malmquist-biased) sample: the naked-eye sky is dominated by
hot B/A stars and distant giants, not by M dwarfs.

## Evaluation cost

Each pixel walks up to a 3×3 neighbourhood of cells in each of six star tiers.
A neighbour is skipped only when every source in it must fail the existing
rejects (more than 20 PSF footprints away, or more than 8 pixels of offset). On
a face, one grid unit spans at least π/6 radians: π/4 times 2/3, the smallest
singular value of the equiangular map, reached at a corner. With a 0.9 margin
for chord and tangent-plane slack, a neighbour at fractional distance f is
skipped when f·π/(3·cells)·0.9 exceeds the reach. The 8-pixel bound uses
|p| ≥ |P δ|/σ_max(J), so it applies only when J is invertible and its plane is
within 8° of tangent; otherwise the footprint bound alone is used. Galaxies use
their own r² > 30σ² reject. Skipped cells contributed nothing, so the image is
unchanged: `tools/skycachecheck.tscn` compares against an exhaustive walk
(`uSkyExhaustive`) and requires identical pixels.

### The diffuse cache

Diffuse emission and dust depth ignore J, so they are functions of rest-frame
direction alone. `render/sky_cache.gd` renders them through the same
`sky_diffuseAdd`/`sky_tau` into a 3×2 cube-face atlas (768² per face, RGBA16F,
equiangular, texel centres on face edges), re-rendering only when an input
uniform changes. Rays sample it when magnification is below 4×; nearer the
photon ring, every layer stays live. The star-density field (band profile and
clusters) stays live too: interpolating it moves the acceptance threshold and
adds or removes individual stars. The temperature pass also stays live, because
it chooses disc or sky by an exact luminance comparison.

The cached image differs from live evaluation by at most one 8-bit level on all
but isolated pixels (the check's bound: 8 levels, and at most 0.01% of pixels
beyond 2 levels), across visible, X-ray, radio, aberrated and lensed views.

## Bands

`sim/spectrum.gd` re-images blackbody continuum, which is wrong for most of the
non-visible sky: 21 cm and CO lines, synchrotron, π⁰-decay gamma rays, the CMB.
So the sky is composited per band at the band's own frequency:

    L(d, ν) = Σᵢ spatialᵢ(d) · spectralᵢ(ν) · Πⱼ extⱼ(d, ν)

`spectralᵢ` is the authored weight table `W` for non-thermal components and a
Planck flux ratio for stars. The result is marked `SKY_ALPHA` so the remap passes
it through.

Stars need a flux ratio, not the surface-brightness ratio: in the Rayleigh–Jeans
limit the brightness ratio is ~1, and it is the ν³ prefactor that removes them.
A 6000 K star is 6e-11 as bright at 1 GHz as in the visible.

Lensing is achromatic, so the distortion geometry is pixel-identical in all
seven bands; only the source content changes.

## Environments

An environment is a set of populations. Amounts (star density, glow, bulge,
dust, H II, reflection, galaxies) add, because populations along one line of
sight superpose. Shapes (plane concentration, scale height, bulge size) take the
weighted mean, because there is one galactic plane you are inside. Summed, disc
plus core gives a band 0.23 rad thick. The rule is the `add` flag on each
`SKY_PARAMS` row.

## Flight sky

Earth's flight sky (`shaders/flight/sky_dome.gdshader`, `uPhysical`) is single
scattering through a spherical atmosphere. Sixteen view samples each carry their
own six-sample sun path:

    L = ∫ T_view · T_sun · [β_R ρ_R(z) P_R(θ) + β_M ρ_M(z) P_M(θ)] ds

The coefficients are Bruneton's (2017). Rayleigh β_R = (5.802, 13.558, 33.1)×10⁻⁶ m⁻¹
at 680, 550 and 440 nm with H_R = 8 km. Mie β_M = 3.996×10⁻⁶ (extinction 4.44×10⁻⁶),
H_M = 1.2 km, Henyey–Greenstein g = 0.8. Ozone absorbs (0.650, 1.881, 0.085)×10⁻⁶
in a tent from 10 to 40 km. A sample in the planet's shadow gets no sun, so the
reddened sunset, the Earth's shadow and the Belt of Venus come out of the
geometry. The Chappuis absorption keeps the twilight zenith blue.

Multiple scattering follows Hillaire (2020, §5.5). At each height and sun cosine,
`tools/build_sky_ms.py` gathers the second-order light L₂ over the sphere with an
isotropic phase (ground albedo 0.3) and the fraction f_ms that one more scattering
returns. Every higher order is then the geometric series Ψ = L₂/(1 − f_ms), and each
view sample adds σ_s·Ψ:

    L += T_view · (σ_R(z) + σ_M(z)) · Ψ(h, μ_s) ds

The 32 × 32 table (`sim/flight/sky_ms.gd`, h = v²·96 km) uses the dome's own
coefficients. It adds ×1.50 to the noon zenith from sea level, ×1.29 at sunset and
×1.71 with the sun 6° down. The gain falls from 15 to 10.02 so that the noon zenith
(sun 60° up) keeps the earlier calibration, and civil twilight brightens 14% relative
to noon. At the daylight exposure the twilight sky still reads dark, as the real
one does: its zenith is about 1% of noon's. Coverage follows radiance, and the light
divides back out of the blend so that faint twilight adds over the stars. Bodies
without a coefficient set keep the grey-column sky with a tint.

### Mars and Titan

The same path draws Mars's and Titan's skies (`scatter: "mars"`/`"titan"` in
`Rocketry.ATMOSPHERES`). Their coefficients are in `SkyMS.ATMOS`, each with its own
multiple-scattering table. The aerosol's extinction, single-scattering albedo and
Henyey–Greenstein g are given per primary (680, 550, 440 nm), and the shell's height
is per body. `tools/build_sky_ms.py` builds all three tables; Earth's is unchanged
to the last digit.

- **Mars.** CO₂ Rayleigh is 2.5× air's per molecule at 0.83% of Earth's number
  density. Dust is τ = 0.5, well mixed with an 11.1 km scale height. Its
  single-scattering albedo is 0.976/0.935/0.64, after Wolff et al. (2009): iron
  oxides absorb the blue. Its g is 0.62/0.68/0.80. Henyey–Greenstein has no
  diffraction peak, so the rising blue g stands in for ~1.5 µm grains scattering
  short wavelengths into a narrower forward lobe.
  - The noon zenith is butterscotch, B/R 0.51.
  - With the sun 2° up, the sky 5° from it is blue (B/R 1.59) and the sky opposite
    tan (0.35): the blue Martian sunset.
- **Titan.** N₂ at 1.467 bar and 93.7 K has 4.45× Earth's number density, with a
  20.6 km scale height. The haze is τ = 2.0/3.0/4.5 with a 65 km scale height,
  albedo 0.92/0.85/0.65 and g ≈ 0.6, after Huygens DISR (Tomasko et al. 2005). The
  shell reaches 520 km. The zenith is deep orange: G/R 0.33 and B/R 0.02 with
  multiple scattering.

Hillaire's geometric series is a looser fit under Titan's optical depth of 3–5 than
under Earth's 0.3. No preset carries Titan yet, so its sky is checked numerically,
not seen.

Off Earth the sky follows the star's flux through the camera's exposure, as the
ground does (`uSkyFlux`). Earth keeps its noon calibration. `flightphysicscheck`
single-scatters each sky on the CPU from `SkyMS.ATMOS` and checks those colours.
`tools/skyshots.tscn` renders the sky from a pad on any body with the sun at a
chosen elevation.

### Night emission: airglow and aurora

Earth's dome also integrates volume emission through a 400 km shell:

- **Airglow.** O(¹S) 557.7 nm gives 250 R at the zenith from a layer at 97 ± 6 km,
  and O(¹D) 630 nm gives 50 R near 250 km.
- **Aurora.** An oval round the geomagnetic north pole (80.7° N, 72.7° W, IGRF-13
  epoch 2020; the southern oval mirrors it). Its midnight edge sits at 70° − 2°·Kp
  magnetic latitude, 3° further poleward at noon, and the band is 2.5° + 0.6°·Kp
  wide. Thin arcs fold along it. It is green near 110 km and red above 200 km, at
  1 kR at Kp 2, doubling per unit.

1 R of 557.7 nm is 1.5 × 10⁻¹² of the G band's solar irradiance per steradian, so
even a strong aurora is 10⁻⁵ of the day sky. The renderer has no night adaptation,
so emission is drawn at a stated display gain of 3 × 10⁵ while the sun is more than
6° below the eye's horizon. That is about the exposure a night photograph from
orbit takes against a daylit one. The geomagnetic pole is placed through the
launch site's geography, as the ground map is, so the ovals need a flight from a
pad. In orbit afterwards they stay registered.

`Stellar.storm_kp` drives Kp from the star's activity model. It is 2 when quiet. A
CME arrives 1.8 days after launch (900 km/s), lifts Kp toward 9 by how far its
flare's energy exceeded the CME threshold, and fades over a day. Every CME is
treated as aimed at Earth.

Rendered at 52° N with Kp 6, faint green arcs fill the northern sky; at the Cape
there are none.

### Zodiacal light and noctilucent clouds

The night emission also carries the zodiacal light, sunlight scattered by
interplanetary dust, drawn at the same display gain. It is a fit to Leinert et al.
(1998, table 17) within ~30%: in the ecliptic 3500 S10 at 30° elongation, 260 at 90°,
150 at 135° and 180 in the gegenschein, falling to 60 at the ecliptic poles with an
e-folding of 25° in ecliptic latitude. 1 S10 is 6.5 × 10⁻¹² of the Sun's irradiance
per steradian. The ecliptic comes from the orrery's own plane.

Noctilucent clouds are ice at 83 km over the summer pole: a 1.5 km layer of vertical
optical depth 3 × 10⁻⁴ at 550 nm going as λ^−2.5, forward scattering (g = 0.6), in
billows and bands. They form poleward of ~50° within about two months of the summer
solstice (sub-solar latitude past ~15° on the site's side; Gadsden & Schröder 1989),
and are lit only where sunlight still reaches 83 km, so they show in deep twilight
over a dark sky without a display gain of their own.

## Planetshine

A rocky planet's or world's night side is lit by its brightest sunlit neighbour
(`Suns.apply_shine`). A Lambert sphere of albedo A and radius R at distance d sends
the fraction A·(2/3)·(R/d)²·[sin α + (π − α) cos α]/π of the sunlight, where α is
the neighbour's phase angle as seen from the lit body. For a full Earth on the Moon
that is 7 × 10⁻⁵. Like the eclipse umbra's red, it is drawn ×100 for display:
earthshine on a crescent Moon reads as a faint glow on the dark side rather than as
black. The light takes the neighbour's colour and the star's.

## Eclipses

Body surfaces dim by the fraction of each star's disc that another body covers
(`eclipse()` in `shaders/common/suns.gdshaderinc`, fed by `Suns.apply_occluders`).
The geometry is flat-sky circle overlap of the star's angular radius and the
occluder's, at the occluder's true radius and position in units of the lit body's
true radius, so a magnified render never casts a magnified shadow. Umbra,
antumbra and penumbra all follow. The star's own limb darkening is ignored, which
leaves a penumbra's profile slightly too linear. A thick atmosphere (Earth,
Venus, Titan) refracts sunset light into its umbra: an eclipsed Moon turns red.
The real umbral light is about 10⁻⁴ of sunlight, raised ×100 here so that totality
reads at the full Moon's exposure.

## Point-source brightness

A sub-pixel body's marker takes its apparent V magnitude (`Marker.apparent_magnitude`).
Planets and the Moon use the V(1,0) and phase-angle polynomials of Mallama &
Hilton (2018), scaled by the star's luminosity. Other reflectors are Lambert
spheres with their geometric albedo, and stars are M_V = 4.83 − 2.5 log L at
their distance. Brightness goes on the sky's own flux scale: a tier-0 sky star
(`SkyModel.STAR_FLUX`) is V ≈ 2.5, and the marker's profile integrates to the same
radiance·pixel². It is clamped between the full Moon (−12.7) and the sky's
8th-magnitude limit, so a body is never lost entirely. Holes and compact stars
keep their fixed emitter gain.

## Catalogue stars

A scene whose sky says `galactic: "j2000"` (`solar`) puts the Milky Way on the real
galactic frame: the north galactic pole at RA 192.859°, Dec +27.128° and the centre
at 266.405°, −28.936°, carried onto the scene's ecliptic axes. Each of the 9096
stars in `assets/sky/bsc5.bin` is drawn at its J2000 direction (`BrightStars`).
The file is the Yale Bright Star Catalogue, 5th revised edition (Hoffleit &
Warren 1991), reduced by `tools/build_starcat.py` from HEASARC's BSC5P table.
Without the file, the procedural sky stays whole. Brightness comes from V on the flux scale above, and
colour is the Planck colour of Ballesteros's (2012) B−V temperature. The
procedural sky then skips its four brightest tiers (to V ≈ 6) and fills in
below. The catalogue is visible-band only. It is neither lensed nor aberrated, so
a relativistic flight's sky warps only the procedural stars. Moving the plane-tilt
or roll slider returns the scene to the hand-placed procedural frame.

## Light time

With Settings › Sim › Light-time delay, every body is drawn at its retarded
position, x − v·d/c, where d is its distance from the camera. That is the first
order of solving t_ret = t − |x(t_ret) − x_cam|/c, exact to (v/c)². Jupiter is
seen 35–52 minutes late; Rømer used the resulting shift in Io's eclipses to
measure c. Physics, contact and the instruments use the instantaneous positions.
