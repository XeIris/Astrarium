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
`sky_diffuseAdd`/`sky_tau` into a 3×2 cube-face atlas (512² per face, RGBA16F,
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
geometry. The Chappuis absorption keeps the twilight zenith blue. Multiple
scattering is not computed. A gain of 15 matches the pad's noon zenith to the
earlier calibration. Without the multiply scattered light, civil twilight is
darker than a real sky. Coverage follows radiance, and the light divides back out
of the blend so that faint twilight adds over the stars. Other bodies keep the
grey-column sky with a tint.

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
at 266.405°, −28.936°, carried onto the scene's ecliptic axes. If
`assets/sky/bsc5.bin` exists (built by `tools/build_starcat.py` from the Yale
Bright Star Catalogue, BSC5), each of its ~9100 stars is drawn at its J2000
direction (`BrightStars`). Brightness comes from V on the flux scale above, and
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
