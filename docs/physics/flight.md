# Flight frames and cruise

Local flight uses metres and seconds in an accelerating frame centred on the
parent body. The parent's gravity is unchanged; other bodies contribute the
difference between their pull at the vessel and at the parent:

`a = Σ GMᵢ (Rᵢ−Rᵥ)/|Rᵢ−Rᵥ|³ − Σᵢ≠parent GMᵢ (Rᵢ−Rₚ)/|Rᵢ−Rₚ|³`.

This avoids treating the Sun's acceleration of the entire Earth system as an
extra local fall acceleration. The world advances before each vessel substep, so
an RK4 stage reads each body's offset from the parent by cubic Hermite
interpolation between the two snapshots, at the stage's own time, and the
vessel's mass at the first stage's flow. Reading the end-of-step positions put a
first-order error into the tidal term (1.8 km over two days past the Moon at
60 s steps, against 2e-5 m interpolated; `tools/flightphysicscheck.gd`). The
rails kicks read the same snapshots at their two ends.

## The parent's figure

Earth, Mars and the Moon add zonal harmonics J2–J4 about their spin poles
(`Rocketry.ZONAL`: EGM2008, MRO120D, LP150Q), as −∇ of
Φ = (μ/r) Σ Jₙ (R/r)ⁿ Pₙ(sin φ). This gives nodal regression (the ISS's −5.0°/day,
reproduced to 0.1%), sun-synchronous orbits and apsidal drift. Sectoral and
tesseral terms are absent, so the Moon's C22 (as large as its J2) and the mascons
that make low lunar orbits unstable are not modelled.

Two-body elements under J2 are biased: at 28.5° a circular 200 km orbit reads
13 km eccentric. Telemetry, and through it guidance, computes its conic with the
orbit-averaged μ_eff = μ[1 + 3/2·J2·(R/r)²(1 − 3/2·sin²i)]
(`Rocketry.effective_mu`). The short-period terms remain, about ±6 km in a
near-circular orbit's apsides, and the ascent still cuts off on two-body elements,
so the final orbit can differ from the target by that much.
`tools/sharedflightcheck.gd` gates on the altitudes flown over the next
revolution, widened by J2·R²/a.

The surface stays a sphere of the body's mean radius. The WGS-84 ellipsoid would
put the pad and geodetic latitude right to 21 km, but the ground, clouds, sky,
landing and planet maps all assume a sphere and would have to change together.

## Air

Shock-layer radiation adds to the Sutton–Graves convective flux
(`Rocketry.radiative_heat_flux`, Tauber & Sutton 1991): zero below about 9 km/s
in air and 6 km/s in CO₂, and dominant on lunar return. Its f(V) tables are the
commonly reproduced ones, not checked against the original paper here.

A launcher stage may carry a `cdTable` (`{source, rows: [[Mach, Cd], ...]}`) that
replaces the generic Cd(Mach) curve while it is the lowest stage attached. No
vehicle has one yet: sourced tables (MSFC wind-tunnel reports for the Saturn V)
were not available when the mechanism was added.

Climatological winds (`Rocketry.WINDS`, Settings › Sim, off by default) give
Earth a zonal-mean circulation: ±6 m/s trades and westerlies, a 1/7-power
boundary layer, and a 35 m/s jet near 12 km at 35° latitude. The airspeed
includes it, so drag, Mach and heating see it. It is off by default because the
orbiter's glide and rollout laws read airspeed as ground speed, and with a jet
the orbiter overflies the runway. Physics vectors use doubles; flight rendering
uses a second floating origin in the metre-scale viewport. The frame coordinator
converts accepted coordinate seconds to orrery years. Proper-time clocks and
guidance run only over accepted intervals; integrator guards stop both spaces
together. [The flight contract](../../sim/flight/AGENTS.md) describes integration
order, staging, guidance and the required launch checks.

Interstellar cruise is a separate one-dimensional, gravity-free model with
constant proper acceleration `a`. Rapidity `φ = aτ/c` gives
`v = c tanh φ`, `γ = cosh φ`, `t = (c/a) sinh φ`, and
`d = (c²/a)(cosh φ−1)`. Burns change rapidity by
`Δφ = (vₑ/c) ln(m₀/m₁)`. The profile solver chooses burn/coast/turnaround
intervals subject to available propellant; these equations do not model
gravitating interstellar trajectories.

Vehicle dimensions, engine counts and thrust are canonical in
`sim/flight/vehicles.gd`. The historical source compilation remains in
[the archived research record](../../web/docs/spaceflight-research.md).
