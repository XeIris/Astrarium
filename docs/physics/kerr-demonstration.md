# Prescribed circular Kerr orbit

The movie-spacecraft demonstration uses a labelled **kinematic test-particle
orbit**. It does not send a close orbit through the orrery's Newtonian + 1PN pair
force law, and is not a general strong-field mission integrator.

For prograde equatorial circular motion, let `rho = r / (GM/c²)` and let `a` be
dimensionless spin. The Boyer–Lindquist coordinate angular velocity and clock rate
are

```
Omega = (c³/GM) / (rho^(3/2) + a)
dt/dtau = (1 + a/rho^(3/2)) / sqrt(1 - 3/rho + 2*a/rho^(3/2))
```

These are the circular geodesic relations from [Bardeen, Press & Teukolsky
(1972)](https://doi.org/10.1086/151796), with the clock relation also given in
[Mummery & Balbus (2024), appendix A](https://academic.oup.com/mnras/article/531/1/366/7671518).
Coordinate time is the stationary observer's time at infinity. The embedded flat
scene position displays the Boyer–Lindquist radius and azimuth. The camera sends
the equivalent equatorial Cartesian radius `sqrt(r_BL² + a² (GM/c²)²)` to the
Kerr–Schild lens. The lens uses its static observer frame at the demo radius.
It omits aberration due to the spacecraft's orbital motion. A display light
from the disc direction illuminates the craft.

`KerrCircular` accepts positive masses, `0 <= a <= 0.998`, and radii at or outside
the prograde ISCO from `Structure.kerr_isco`. That spin cap is the current lens
verification domain. Accretion hazards, tides, radiation, finite-size spacecraft
stresses and orbital perturbations are omitted.

`endurance:kerr_orbit` uses `rho = 3.5` and `a = 0.998` around the isolated
100 million solar mass body in `gargantua_demo`. The default oblique view frames
the illustrated disc and escaping starlight. One orbit is about 6 h 29 min at
infinity, with `dt/dtau = 1.72235`. The flight HUD displays both clocks.

`tools/kerrcircularcheck.gd` checks the Schwarzschild clock rate at 6M, normalises
the four-velocity directly against Kerr metric components, checks the radial
geodesic condition independently, and verifies mass scaling, period closure and
invalid-request rejection. `tools/kerrflightcheck.tscn` exercises accepted-time
accounting, pause, period closure and the flight HUD. Its `render=1` gate
inspects the lensed backdrop, including escaping rays and the shadow.
