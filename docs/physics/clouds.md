# Clouds in local space

Code: `shaders/flight/clouds.gdshader` (the march), `clouds.gdshaderinc` (the
field), `sim/flight/cloudfield.gd` (the CPU copy of the field, which must match
sample for sample), `sim/flight/localview.gd` (per-frame uniforms and LOD).

A raymarched cumulus layer (1.5–4.6 km on Earth), marched per pixel from wherever
the camera is: below, inside or above. The march stops at the depth buffer, so
cloud sorts correctly against ground, tower and vehicle without being sorted.

## Light

- **Extinction** along the view ray, integrated per step with Hillaire's
  energy-conserving form ∫S·e^{−σx}dx = S(1 − e^{−σΔ})/σ, so the result doesn't
  depend on step size.
- **Sun**, attenuated by the optical depth toward it (a short geometric march)
  and phase-weighted by a two-lobe Henyey–Greenstein: a strong forward peak
  (g = 0.8, the silver lining) and a weak back lobe.
- **Multiple scattering**, which keeps thick cloud white. One extra octave after
  Wrenninge et al. (half the extinction, half the energy, a flatter lobe) covers
  shallow orders. Deep orders are diffusion: two-stream theory gives
  transmission 1/(1 + ¾τ(1 − g)), not e^{−τ}. At τ = 40 the exponential leaves
  4e-18 of the sun, and the random walk leaves a fifth. With weight ~1/π², a
  thick slab's diffuse radiance comes out at E·T/π, a Lambert sheet's.
- **Skylight** from above and ground bounce from below (tops brighter than bases).
- **Powder**: an edge facing you is darker than the interior; applied softly,
  away from the forward lobe.
- **Aerial perspective**: the ground's haze at the transmittance-weighted
  distance.

Output is premultiplied: rgb the radiance, alpha the coverage (1 − T). Cloud
hides the stars behind it.

## Sampling

- Steps grow with range, uniform in s where t(s) = t0 + base·(rˢ − 1), floored
  near the camera and sized to reach t1 within budget.
- The per-pixel jitter (interleaved gradient noise) goes on s, not t. On t it
  is a fraction of the first 10 m step, so every pixel samples the same shells,
  and looking along the deck from inside it the cloud reads as stacked sheets.
- Grazing rays span ranges of 4000:1, so the step count is raised until no
  step exceeds ~15% of its range (up to 2× budget). The early exit at 99%
  opacity keeps most of that unpaid.
- Segments are probed at their midpoint. One whose probe, or either
  neighbour's, finds cloud is refined into sub-steps of ~REFINE_LEN (up to
  REFINE_MAX). An unrefined segment's probe is its sample.
- The light march runs once per segment, at its first cloudy sample, and is
  shared by its sub-steps (finer self-shadowing is below a pixel there).

## Upper-atmosphere LOD

From above, a pixel covers tens of metres across a 3 km slab. So localview.gd
lowers uSteps and uLightSteps, stretches uLightFirst so the light march still
reaches as far, and re-reads coverage only every uCovReuse metres (not at all
in the light march). 0 means every sample, as under the deck. Nothing changes
below CLOUD_LOD_LO.
