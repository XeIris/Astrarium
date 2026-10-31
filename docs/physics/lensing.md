# Black holes: the lens marcher

Code: `render/lens_pass.gd` (dispatch, uniforms and the Page–Thorne terms), `shaders/lens/lens_march.glsl`
(the compute kernel), `shaders/sky/background.gdshader` (the full-resolution sky
over the marcher's direction field).

Everything you see of a black hole is light that missed. There is no surface to
shade, so a full-screen pass integrates null geodesics backwards from the eye.

## Modelled

- **Kerr null geodesics.** Each hole is a Kerr spacetime in Kerr–Schild Cartesian
  coordinates (see [Ray coordinates](#ray-coordinates-and-numerical-scope)). Its spin
  axis is the disc's angular momentum (scene −y), so the disc is always prograde.
  Energy E = −pₜ, the axial angular momentum L = p_φ and Carter's constant Q are
  conserved by the Hamiltonian flow; they are not imposed, so `tools/lenscheck.tscn`
  measures the shadow they produce against Bardeen's boundary.
- **The shadow.** A ray crossing the horizon r₊ = M(1 + √(1 − a²)) stops and returns
  the disc light it has collected. At a* = 0 the shadow's radius is (√27/2)·r_s, and
  a finite static observer sees `sin α = (√27/2)·(r_s/R)·√(1 − r_s/R)`. With spin,
  frame dragging lets prograde photons orbit closer (down to r → M as a* → 1), so
  the edge on the approaching side flattens and the shadow shifts away from it.
  The edges seen from the equator are the equatorial photon orbits; from the pole
  the shadow is a circle of radius √(η + a²) (Bardeen 1973, below).
- **The photon ring.** Rays near the critical orbits wind round the hole and cross
  the disc on each pass, stacking into the thin bright ring. It comes out of the
  integration; nothing draws it.
- **Page–Thorne disc.** The inner edge is the prograde Kerr ISCO
  (`Structure.kerr_isco`), 6M at a* = 0 and 1.24M at 0.998. The emitted
  temperature is (F/F_peak)^¼ with F the Novikov–Thorne flux of
  [Page & Thorne (1974)](https://doi.org/10.1086/152990):

      F ∝ [x − x₀ − (3a/2) ln(x/x₀) − Σᵢ 3(xᵢ − a)²/(xᵢ(xᵢ − xⱼ)(xᵢ − xₖ)) ln((x − xᵢ)/(x₀ − xᵢ))]
          / (x⁴ (x³ − 3x + 2a)),   x = √(r/M), x₀ = √(r_isco/M)

  with xᵢ the roots of x³ − 3x + 2a. It is zero at the ISCO, peaks at 9.55M for
  a* = 0 and 1.58M for 0.998, and tends to the Newtonian 3GMṀ/(8πr³) far out
  (`Physics.page_thorne_flux`). The physical peak temperature
  (`Derive.disc_peak_temp`) holds the Eddington ratio fixed, so Ṁ ∝ 1/η with
  efficiency η = 1 − E_isco (5.7% to 32%) and T_peak⁴ ∝ F_peak/η: ×2.8 at 0.998.
- **Transfer.** Gas moves on prograde circular equatorial orbits,
  Ω = M^½/(r^{3/2} + aM^½), and the frequency ratio is g = 1/(uᵗ(E − ΩL)) from the
  ray's conserved E and L, with E = 1 for the camera (Bardeen, Press & Teukolsky
  1972 give uᵗ). g sets the colour temperature, T_obs = g·T_emit, and the
  intensity, I_obs ∝ g⁴ (from the invariance of I_ν/ν³). The approaching limb comes
  out blue-white and an order of magnitude brighter; the receding limb is dull red.
  Off the midplane the slab uses the midplane orbit at the same r.
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

The Kerr–Schild form ([Visser 2007](https://arxiv.org/abs/0706.0622)) is

    g = η + f k⊗k,   f = 2Mr³/(r⁴ + a²z²),
    k = (1, (rx + ay)/(r² + a²), (ry − ax)/(r² + a²), z/r),
    (x² + y²)/(r² + a²) + z²/r² = 1,

with k null, so gᵘᵛ = ηᵘᵛ − f KᵘKᵛ (K = η⁻¹k). The marcher integrates Hamilton's
equations for H = ½gᵘᵛpᵤpᵥ: dx/dλ = p − f k(K·p) and dp/dλ = ½∇f (K·p)² + f(K·p)∇(K·p),
with ∇r, ∇f and ∇k analytic. At a* = 0 this is Schwarzschild in Eddington–Finkelstein
form, so the a* = 0 shadow and weak bend checks still apply. Positions are divided by
each hole's M, which keeps the fixtures at r_s = 1 and 10⁻⁷ identical.

The camera traces rays backwards. Backward tracing in Kerr(a) is forward tracing in
its time reverse, Kerr(−a), with the disc running the other way; ingoing
Kerr–Schild coordinates are regular on that spacetime's future horizon, so rays
cross it. The camera is a static observer, u = ∂ₜ/√(1 − f) (inside an ergosphere,
where no static observer exists, the Kerr–Schild normal observer). Its local ray n
maps to a coordinate direction through the symmetric inverse square root of the
static frame's spatial metric δ + f/(1 − f) k⊗k, then p = u + n, so the camera
measures energy 1. At a* = 0 this reduces to the radial/tangential split
`rd_radial + rd_tangential/√(1 − r_s/R)`.

Each step is an RK2 midpoint in λ sized to a spatial step of 0.16(r − r₊), at least
0.1 r_s and at most 0.3 r, capped near the disc plane. The bend accumulates
separately from the initial momentum so fp32 keeps a 10⁻⁵ rad deflection. Prograde
orbits of a near-extremal hole skim the horizon for several windings; 320 steps
hold the a* = 0.998 edges to within a pixel at 512², and a ray still within 4 r_s
when the steps run out is counted as captured. A Python prototype of the same
scheme (step floor 0.1 r_s, 300 steps) put the a* = 0.998 prograde edge 1% from
Bardeen's.

[Bardeen (1973)](https://ui.adsabs.harvard.edu/abs/1973blho.conf..215B) gives the
critical orbits a distant observer sees: for the spherical photon orbit at r,
ξ = L/E = −(r³ − 3Mr² + a²r + a²M)/(a(r − M)) and
η = Q/E² = r³(4a²M − r(r − 3M)²)/(a²(r − M)²); an observer at inclination i sees
α = −ξ/sin i, β = ±√(η + a²cos²i − ξ²cot²i). `tools/lenscheck.tscn` compares the
rendered edges at a* = 0.9 and 0.998, from the equator (η = 0 and ξ = 0) and the
pole, with these at R = 4000M (within 1.5 px), and keeps
[Perlick and Tsupko](https://arxiv.org/pdf/2105.07101)'s finite-observer
Schwarzschild shadow at 7 and 20 r_s.

Two holes superpose their f k⊗k terms in gᵘᵛ. That sum is not a solution of the
field equations, and its camera uses the plain view direction with the energy that
makes it null; it remains an illustrative geometry.

Float32 inputs, half-float direction storage, and strongly unequal two-hole scales
remain numerical limits. The displayed turbulent disc is illustrative: its fitted
colour, density and transfer through the slab are not a complete radiative-transfer
calculation, and the colour temperature is the "Disc Temp" control scaled by the
Page–Thorne profile. The temperature resolve assigns the dominant source rather
than mixing spectra; categorical X-ray boundaries and finite-field edges remain
visible. Single-hole ray geometry and the analytic-star resolve have independent
checks; matching a disc image does not validate all astrophysical claims.
