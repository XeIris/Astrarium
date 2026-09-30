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
| diffuse | galactic band, nebulae, CMB, X-ray background | plain radiance; surface brightness conserved |
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
