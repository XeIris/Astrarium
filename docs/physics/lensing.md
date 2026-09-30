# Black holes: the lens marcher

Code: `render/lens_pass.gd` (dispatch and uniforms), `shaders/lens/lens_march.glsl`
(the compute kernel), `shaders/sky/background.gdshader` (the full-resolution sky
over the marcher's direction field).

Everything you see of a black hole is light that missed. There is no surface to
shade, so a full-screen pass integrates null geodesics backwards from the eye.

## Modelled

- **Null geodesics.** In Schwarzschild geometry the photon orbit equation
  reduces (via Binet) to the Cartesian acceleration
      d²x/dλ² = −(3/2) r_s h² x̂ / r⁵,   h = |x × v|, |v| = 1
  which is exact for light. It is integrated with an RK2 midpoint step that
  shrinks as (r − r_s), so rays grazing the photon sphere at 1.5 r_s are
  resolved.
- **The shadow.** A ray crossing the horizon stops and returns the disc light
  it has collected. The dark region's apparent radius is (√27/2)·r_s ≈ 2.6 r_s,
  cast by the photon sphere.
- **The photon ring.** Rays near the critical impact parameter wind round the
  hole and cross the disc on each pass, stacking into the thin bright ring. It
  comes out of the integration; nothing draws it.
- **Shakura–Sunyaev disc.** T(r) ∝ (r_in/r)^¾ · (1 − √(r_in/r))^¼, zero at the
  ISCO and peaking just outside it: a dark inner gap and a hot ridge.
- **Relativistic transfer.** The disc orbits at v = √(r_s/2r)/√(1 − r_s/r). The
  combined Doppler and gravitational factor g = δ·√(1 − r_s/r) sets both the
  colour temperature, T_obs = g·T_emit, and the intensity, I_obs ∝ g⁴ (from the
  invariance of I_ν/ν³). The approaching limb comes out blue-white and ~80×
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
