# Realistic sky background — research + design notes

Research behind [sim/sky.js](../sim/sky.js), which replaced the 2048×1024 canvas star map that
used to live in `blackhole_sim.js`.

> **Status: built.** All of §5 is implemented. Two things changed during
> implementation and the sections below have been corrected to match:
>
> - **The PSF moved from source angle to pixels.** Blurring a star by a fixed
>   angle on the source sphere gets that kernel stretched tangentially by the
>   lens, so stars near the ring rendered as arcs. Arcs are the correct image of
>   an *extended* source; the fix is to solve for the star's offset in pixels
>   through the screen-space Jacobian and keep the PSF circular there. Extended
>   things (galaxies, SNR shells) are deliberately left in source angle so they
>   still arc, which is the honest difference between the two cases.
> - **Gas needed its own spatial profile.** Built on the stellar band profile,
>   the radio and gamma skies were still at a third of full scale 25° off the
>   plane, and the log stretch turned that into saturated false colour over the
>   whole frame. Interstellar gas has a much smaller scale height than stars, and
>   saying so is what makes those bands read as a ridge rather than a wash.

---

## 1. Why the current sky breaks

`makeStarTexture(2048)` paints 9000 canvas discs into a 2048×1024 equirectangular
texture, which `sampleStars()` in [sim/blackhole.js:138](../sim/blackhole.js) point-samples with
`texture2D`. Four distinct failures, only one of which is "resolution":

**1.1 It is under-resolved before lensing even starts.**
2048 texels across 360° = 0.176°/texel. The lens pass runs at `fov = 0.87 rad` (49.8°)
over ~1000 vertical pixels = 0.05°/pixel. The star map is already ~3.5× coarser than the
screen with the camera sitting still. Bilinear magnification turns each star into a
smeared 4-texel lozenge — that is the "blur" component of what you're seeing.

**1.2 Lensing magnification multiplies that by 10–100×.**
Near the photon ring the Jacobian of the deflection map is near-singular; a single texel
maps to tens of pixels. Any fixed-resolution map fails there, at any resolution — you
cannot outrun a divergence with more texels. This is the "pixels" component.

**1.3 The lensing response is physically wrong, not just ugly.**
Gravitational lensing conserves surface brightness (Liouville / conservation of étendue)
and amplifies *flux* by the magnification μ = 1/|det J|. So:

- **Extended sources** (a nebula, the Milky Way band) keep the same surface brightness and
  just get *distorted*. A texture lookup does exactly the right thing here.
- **Point sources** (stars) are unresolved. They stay point-like and get **brighter** by μ.
  They must not smear.

Sampling stars from a texture forces them into the extended-source behaviour, which is why
the Einstein ring looks like stretched paint instead of a ring of brilliant points. This is
the core structural insight: **the sky has to be split by how lensing treats it, not by what
it is.**

**1.4 Equirectangular pole pinch.** Texel solid angle → 0 at `v = 0,1`, so star density per
steradian is wildly over-dense at the poles and there is a seam at the ±y axis. In a free-fly
camera you can point at it.

The Interstellar/DNGR paper (James, von Tunzelmann, Franklin & Thorne 2015) hit exactly this
and solved it by propagating **ray bundles** rather than rays, and filtering the star field
over the bundle's footprint — their stated reason was that point-sampled stars flickered
unacceptably. That's the reference architecture: know your pixel's angular footprint, and
integrate the sky over it rather than sampling at a point.

---

## 2. Proposed architecture: three layers, split by lensing behaviour

| layer | content | lensing | representation |
|---|---|---|---|
| **point** | stars, pulsars, X-ray binaries, quasars | stays point-like, flux ×μ | analytic procedural, no texture |
| **diffuse** | Milky Way band, nebulae, CMB, diffuse X-ray | surface brightness conserved, distorted | 3D noise / low-res map — texture is *correct* here |
| **absorbing** | interstellar dust | multiplies everything behind it | procedural extinction map, band-dependent |

Layers composite as `Σ (emission_i · Π extinction_j-in-front)`, all evaluated on the outgoing
ray direction from the marcher — one call, where `sampleStars()` is now.

### 2.1 Point layer — analytic stars

**Cell hashing on direction.** Project the direction onto a **cube face** (or an icosahedral
scheme) rather than lat/long — equal-ish solid angle per cell, no pole pinch, no seam.
Hash `(face, i, j)` → per-cell star count and per-star `(offset within cell, apparent
magnitude, temperature)`. Angular resolution becomes infinite: at 1000× magnification you
still get a crisp point, because there is no grid to magnify.

**Magnitude distribution.** For a homogeneous Euclidean population, cumulative counts go as
N(<m) ∝ 10^(0.6m) — one magnitude fainter is ~4× as many stars. The real Galaxy flattens
this past m ≈ 12 (finite disc scale height + extinction), slope dropping toward ~0.45.
Draw m by inverse-CDF of a **broken power law**. Calibration anchor: 9096 stars brighter
than mag 6.5 over the whole sky (Hipparcos).

**Critical: know when to stop drawing individuals.** Below the flux where a star contributes
less than a fraction of a pixel, stop emitting points and fold the remaining population into
the diffuse layer as *integrated unresolved starlight*. This is not a cheat — the Milky Way
band **is** unresolved stars. It's also what kills the "uniform confetti of equal dots" look
and is why the current field reads as lazy: it draws ~9000 stars of nearly one brightness
class, where the real sky is a handful of blazing points over a smooth glow.

**Tier by magnitude for performance.** Bright tier = a few hundred stars over the whole sky,
evaluate always. Faint tiers = only the 3×3 cells around the ray. Cost stays bounded.

**Colour from temperature, never from a palette.** `blackhole.js` already has `blackbody(T)`
and the repo convention is explicit that colour comes from a temperature. So hash a
*temperature*, not a colour. Two payoffs:

- One number drives visible colour **and** band response, consistently.
- Stars can finally **publish** their T into the HDR alpha channel. Right now `sampleStars()`
  returns colour with `a = 1.0` ("no temperature data"), so the whole background falls through
  `spectrum.js`'s colour-inference path. Use the flux-weighted-mean-T accumulator the disc
  loop already uses (`tSum/tWeight` at [sim/blackhole.js:358](../sim/blackhole.js)).

**Do not sample the IMF for temperature.** A magnitude-limited sky is Malmquist-biased: you
preferentially see intrinsically luminous stars, so the naked-eye sky is dominated by hot
B/A stars and distant giants, *not* by the M dwarfs that dominate by number. Weight the
temperature draw toward a magnitude-limited sample: B/A/F majority plus a red-giant tail.
(Convenient: it means the sky should look mostly blue-white with scattered orange, which
is both correct and prettier than a physically-naive M-dwarf-heavy field.)

**PSF and anti-aliasing.** Draw each star as a compact core plus a faint wide halo, with
**angular** width clamped to ≥ ~1.2 pixels. The clamp rule that matters:

> when a star's PSF hits the minimum size, **don't shrink it further — dim it**, conserving
> integrated flux.

That is precisely the rule `createMarker` in [sim/scale.js](../sim/scale.js) already uses for
sub-pixel bodies; reuse the reasoning. Compute the pixel's angular footprint from `fov`/
resolution, and **widen it by √μ** — that is the DNGR ray-bundle filter, and it's what
prevents the Einstein ring from becoming a shimmering mess in motion.

**Magnification μ in-shader.** Take `dFdx`/`dFdy` of the outgoing ray direction at the end of
the march; μ = 1/|det J| of that 2×2 Jacobian relative to the unlensed footprint. Clamp hard
(the shadow edge will produce garbage derivatives) and cap μ so a star near the ring gets
brilliant rather than infinite. Optional but high payoff: diffraction spikes on the brightest
few points only — defensible here because the sim is already framed as an *imaging
instrument* with selectable bands, and spikes are an instrument signature.

### 2.2 Diffuse layer

Ranked by visual payoff per unit of work:

1. **Galactic band + bulge.** The single biggest win. Surface brightness ≈ exp(−|b|/h) in
   galactic latitude, plus a bulge lobe toward the centre, plus a **dark lane** bisecting it.
   This is what makes a sky read as "inside a galaxy" instead of "dots on black."
2. **Dust extinction.** Patchy dark nebulae and the central lane. Multiplicative, and
   **strongly band-dependent** — this is the backbone of the band bonus (§3).
3. **Emission nebulae (H II).** Hα red, clumpy, plane-concentrated.
4. **Reflection nebulae.** Blue, hugging hot stars. Cheap contrast against #3.
5. **Clusters.** A few dozen hashed seeds that locally boost point density: open clusters
   (young, blue, loose, in the plane) vs globulars (old, red, spherical, off the plane).
6. **External galaxies.** A few resolved smudges plus a faint isotropic field of fuzzies.
   Physically pointed: galaxies are **isotropic** while everything galactic is
   plane-concentrated, and they vanish behind the plane (zone of avoidance) in visible while
   reappearing in IR/X-ray.
7. **SNR shells, pulsars, X-ray binaries.** Nearly invisible in visible, dominant in
   radio/X-ray/gamma. Needed for §3 to have anything to show.
8. **CMB.** Only exists in microwave — where it is the *entire sky*. See §3.

### 2.3 Per-preset sky parameters — the cheapest realism you can buy

You said this doesn't have to be Earth's sky, which is a licence, not a constraint. Put a
small sky block on each preset in [sim/presets.js](../sim/presets.js): galactic latitude/longitude of
the system, galactocentric distance, and an environment enum. Then:

- **thin disc, mid-radius** → familiar band across the sky
- **galactic centre** → sky choked with stars, enormous bulge, heavy extinction
- **inside a globular cluster** → thousands of bright points, no band, no dust
- **halo / intergalactic** → almost empty, one faint galaxy smear, galaxies everywhere
- **starburst / spiral arm** → Hα everywhere, blazing OB associations

Same code, wildly different scene identity, and it gives each preset a signature sky.

---

## 3. The band bonus — and the structural problem it exposes

**`spectrum.js` cannot produce a real multiwavelength sky, and its own header says so.**
It re-images *blackbody continuum* by recovering a temperature and evaluating a Planck ratio.
But almost everything that dominates the non-visible sky is **not thermal continuum**:

- 21 cm HI — a line
- CO — a line
- galactic synchrotron — power law, I ∝ ν^−α, α ≈ 0.7
- free-free — flat then falling
- π⁰-decay gamma rays — cosmic-ray collision product
- CMB — thermal but at 2.725 K, off the bottom of any stellar scale

**So the background must not go through the temperature-inference path.** Give each sky
component its own emission law and evaluate it *directly at the current band's frequency*:

```
skyRadiance(dir, nu) = Σ_i  spatialMap_i(dir) · spectralLaw_i(nu) · Π_j extinction_j(dir, nu)
```

where `spectralLaw` is one of: `blackbody(T)`, power law `ν^−α`, line at `ν₀`, or a hand-authored
7-element per-band weight vector. That decouples the sky from the alpha-channel trick entirely
and makes each band's content *authored physics* rather than a remap of the visible image.

**Integration question to settle:** the sky comes out already-in-band, so `spectrum.js` must
pass it through untouched. Reserved-alpha sentinel is the natural hook, but the existing
`a = 1.0` sentinel currently means "infer from colour" — it'd need a second sentinel meaning
"already in band, don't touch."

### 3.1 What each band should actually show

Anchored on the NASA GSFC Multiwavelength Milky Way survey descriptions.

| band | sky is dominated by | stars? | dust behaves as |
|---|---|---|---|
| **Radio 1 GHz** | Synchrotron: bright galactic plane + a huge loop/spur arching out of it; SNR shells; pulsars; radio galaxies. HI structure. | **Gone.** A star's Rayleigh–Jeans flux at 1 GHz is negligible. | transparent |
| **Microwave 100 GHz** | **CMB everywhere** — near-uniform 2.725 K floor with a dipole from your motion. Plus thermal dust in the plane, plus free-free. | gone | transparent |
| **Infrared 10 µm** | **Warm dust glows — the visible sky's dark lanes become the brightest thing in the frame.** Star-forming regions light up. Continuous glowing band. | cool giants prominent; hot stars relatively fade | **emits** |
| **Visible** | stars, emission/reflection nebulae, dark lanes | yes | absorbs |
| **UV** | **Only O/B stars survive** — sparse sky tracing spiral arms and OB associations. | hot stars only | absorbs *worse* than visible (2175 Å bump) — lanes go blacker |
| **X-ray** | Diffuse soft background (hot bubble + AGN); X-ray binaries and neutron stars as brilliant points; SNR shells. **Cold clouds appear as shadows absorbing the background.** | normal stars gone (coronae too faint) | absorbs — but as *silhouette against a diffuse glow* |
| **Gamma** | Near-black sky: a thin bright plane ridge (cosmic rays × interstellar gas → π⁰ decay) plus **a handful of point sources** — pulsars, blazars. | gone | transparent |

Two payoffs worth designing for explicitly:

- **The radio and gamma skies should be nearly empty of stars.** Switching from visible to
  radio and watching 9000 points vanish while the galactic plane ignites is the single most
  convincing thing this feature can do.
- **The dust inversion.** Visible: lanes are black. IR: the *same* lanes are the brightest
  structure on screen. X-ray: black again, but as shadows against a diffuse glow rather than
  as absence. Three different reasons for three different appearances of one structure.

### 3.2 Two truths worth encoding

- **Lensing is achromatic.** Unlike a glass lens, a black hole deflects every wavelength
  identically — no dispersion in vacuum. The distortion geometry is *pixel-identical* across
  all seven bands; only the source content changes. Switching bands with the ring on screen
  should demonstrate this, and it's a genuinely instructive contrast against everyday optics.
- **Observer shift and aberration.** An observer deep in the potential or moving fast sees the
  whole sky shifted and **aberrated** — concentrated into a bright ring ahead of the motion.
  Band-shifting is the dramatic part: a source can be shifted clean *out of one band and into
  another*. (Note the background light itself has no *net* gravitational shift when it comes
  from and returns to the asymptotic region — the shift is the observer's, not the path's.)

---

## 4. Integration cost — the part that will bite

One texture currently serves three consumers: `scene.background`, the lens pass, and the
surface sky view in [sim/skyview.js](../sim/skyview.js). Going analytic means:

- A shared GLSL chunk (`sim/sky.js`) included by both the lens pass and the sky pass.
- **The no-black-hole path needs a real fullscreen sky pass**, since `scene.background = tex`
  stops being an option. Not optional — most presets have no hole.
- `skyview.js` already computes sky opacity to occlude stars; it needs to occlude the *new*
  sky the same way, and per band (a daylit sky is opaque in visible but transparent in X-ray).
- Keeping a low-res baked fallback is possible but I'd avoid it — two sources of truth for
  the sky is how the "looks different in different views" bugs start.

---

## 5. Order of work

1. `sim/sky.js` — cube-cell hashed analytic point stars with T-derived colour, PSF with the
   flux-conserving minimum-size clamp. Wire into the lens pass replacing `sampleStars()`.
   *This alone fixes the pixelation.*
2. Fullscreen sky pass for the no-hole path; retire `makeStarTexture`.
3. Magnification-scaled flux + bundle-widened PSF. *This fixes the Einstein ring.*
4. Diffuse layer: galactic band, bulge, dust lane, unresolved starlight floor.
5. Per-component spectral laws + the pass-through sentinel in `spectrum.js`. *This is the
   band bonus.*
6. Nebulae, clusters, galaxies, compact-object point sources.
7. Per-preset sky environment block.

Steps 1–3 are the "it looks broken" fix. Step 5 is the feature you actually want.

---

## Sources

- [Gravitational Lensing by Spinning Black Holes in Astrophysics, and in the Movie Interstellar — James, von Tunzelmann, Franklin & Thorne (arXiv:1502.03808)](https://arxiv.org/abs/1502.03808)
- [Multiwavelength Milky Way — NASA GSFC all-sky survey descriptions](https://asd.gsfc.nasa.gov/archive/mwmw/mmw_images.html)
- [Multiwavelength Milky Way: The Nature of Light — NASA GSFC](https://asd.gsfc.nasa.gov/archive/mwmw/mmw_EM.html)
- [Multiwavelength Astronomy — NASA Imagine the Universe](https://imagine.gsfc.nasa.gov/science/toolbox/multiwavelength1.html)
- [Lectures on Gravitational Lensing — Narayan & Bartelmann (arXiv:astro-ph/9606001)](https://arxiv.org/pdf/astro-ph/9606001)
- [Gravitational lensing formalism — surface brightness conservation / Liouville](https://handwiki.org/wiki/Astronomy:Gravitational_lensing_formalism)
- [Malmquist bias](https://en.wikipedia.org/wiki/Malmquist_bias)
- [Naked-eye star counts — Hipparcos, mag 6.5](https://www.physics.unlv.edu/~jeffery/astro/glossary/naked_eye_star.html)
- [Extinction — Swinburne COSMOS](https://astronomy.swin.edu.au/cosmos/*/Extinction)
- [Dark nebula — Wikipedia](https://en.wikipedia.org/wiki/Dark_nebula)
- [Casual Effects: Starfield Shader](http://casual-effects.blogspot.com/2013/08/starfield-shader.html)
- [marian42/starfield — procedural WebGL starfield](https://github.com/marian42/starfield)
