# Black holes: the lens marcher

Code: `render/lens_pass.gd` (dispatch and uniforms), `shaders/lens/lens_march.glsl`
(the compute kernel), `shaders/sky/background.gdshader` (the full-resolution sky
over the marcher's direction field).

Everything you see of a black hole is light that missed. There is no surface to
shade, so a full-screen pass integrates null geodesics backwards from the eye.

## Modelled

- **Null geodesics.** In Schwarzschild geometry the photon orbit equation
  reduces (via Binet) to the Cartesian acceleration
      d²x/dλ² = −(3/2) r_s h² x / r⁵,   h = |x × dx/dλ|
  for one Schwarzschild hole. The renderer uses unit arclength tangents and
  projects the acceleration perpendicular to the tangent, then integrates both
  tangent and position with an RK2 midpoint step that
  shrinks as (r − r_s), so rays grazing the photon sphere at 1.5 r_s are
  resolved.
- **The shadow.** A ray crossing the horizon stops and returns the disc light
  it has collected. The dark region's apparent radius is (√27/2)·r_s ≈ 2.6 r_s,
  cast by the photon sphere. A finite static observer sees
  `sin α = (√27/2)·(r_s/R)·√(1 − r_s/R)`; the single-hole camera maps its local
  ray to the coordinate tangent before marching.
- **The photon ring.** Rays near the critical impact parameter wind round the
  hole and cross the disc on each pass, stacking into the thin bright ring. It
  comes out of the integration; nothing draws it.
- **Shakura–Sunyaev disc.** T(r) ∝ (r_in/r)^¾ · (1 − √(r_in/r))^¼, zero at the
  ISCO and peaking just outside it: a dark inner gap and a hot ridge.
- **Illustrated transfer.** The disc orbits at v = √(r_s/2r)/√(1 − r_s/r). The
  fitted-colour Doppler and gravitational factor g = δ·√(1 − r_s/r) sets both the
  colour temperature, T_obs = g·T_emit, and the intensity, I_obs ∝ g⁴ (from the
  invariance of I_ν/ν³ at infinity). Finite-observer/local-direction corrections
  are not a complete transport model. The approaching limb comes out blue-white and ~80×
  brighter; the receding limb is dull red.
- **Volume.** Emission and absorption through a flared slab H(r) ∝ r^(9/8), so
  the far side is seen through the near side.
- **Filaments.** MRI turbulence sheared by Keplerian Ω(r) ∝ r^(−3/2): noise is
  sampled in the co-rotating frame ψ = φ + Ω(r)·t, compressed azimuthally and
  stretched radially (~8:1), giving strands rather than clouds.

## The split

The marcher runs at the lens scale (default half resolution; cost is nearly
linear in pixels, 3.89× faster for 4× fewer). Geodesics and the disc integral
are smooth per-ray fields and tolerate that. The star field is a per-pixel cost,
so the sky is evaluated at full resolution in the background sky shader over the
direction field the marcher writes. The marcher is a compute shader writing two
images.


## Ray coordinates and numerical scope

The single-hole Cartesian acceleration follows
[Walters and Forbes, equation 12](https://arxiv.org/pdf/1409.3645).
For unit tangent `v`, write this acceleration as `A(x,v)`. Our arclength form is
`dv/ds = A − v(v·A)`: reparameterizing the affine tangent `dx/dλ=qv` cancels
its squared speed in this transverse curvature. Both RK2 stages project their
own acceleration; position advances with the midpoint tangent, not the endpoint.
This arclength conversion is a derivation from that homogeneous quadratic equation.

For a static camera at `R>r_s`, split the local ray into radial and tangential
parts. The coordinate tangent is proportional to
`rd_radial + rd_tangential/√(1 − r_s/R)`, then normalized for arclength.
[Perlick and Tsupko](https://arxiv.org/pdf/2105.07101) give the independent
finite-observer shadow formula used by `tools/lenscheck.tscn`.
Two-hole acceleration superposition and its camera remain an illustrative
geometry; they are not a solution for a binary Schwarzschild/Kerr spacetime.

The implementation factors acceleration into unit directions and `r_s/r²`,
avoiding fifth powers and scene-unit distance floors. Disc height and optical
path ratios also use their actual horizon scale. Far steps may grow with distance;
near steps retain the horizon bounds. A segment that cannot reach the emitting
annulus needs no disc-specific step cap. Disc density is evaluated only inside
its conservative height envelope. These changes retain the 240-step limit and
noise detail; finite iteration count still limits rays very near the critical orbit.

Float32 inputs, half-float direction storage, and strongly unequal two-hole scales
remain numerical limits. The displayed turbulent disc is illustrative: its fitted
colour, density, local Doppler direction and transfer to a finite observer are
not a complete radiative-transfer calculation. The temperature resolve assigns
the dominant source rather than mixing spectra; categorical X-ray boundaries
and finite-field edges remain visible. Single-hole ray geometry and the
analytic-star resolve have independent checks; matching a disc image does not
validate all astrophysical claims.
