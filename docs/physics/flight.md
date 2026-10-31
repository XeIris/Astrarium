# Flight frames and cruise

Local flight uses metres and seconds in an accelerating frame centred on the
parent body. The parent's gravity is unchanged; other bodies contribute the
difference between their pull at the vessel and at the parent:

`a = Σ GMᵢ (Rᵢ−Rᵥ)/|Rᵢ−Rᵥ|³ − Σᵢ≠parent GMᵢ (Rᵢ−Rₚ)/|Rᵢ−Rₚ|³`.

This avoids treating the Sun's acceleration of the entire Earth system as an
extra local fall acceleration. Physics vectors use doubles; flight rendering
uses a second floating origin in the metre-scale viewport. The frame coordinator
converts accepted coordinate seconds to orrery years. Proper-time clocks and
guidance run only over accepted intervals; integrator guards stop both spaces
together. [The flight contract](../../sim/flight/AGENTS.md) describes integration
order, staging, guidance and the required launch checks.

## Orientation

The frame is turned so the parent's north pole is −Y: its equator is the XZ
plane, latitude is `asin(−r̂.y)` and the surface turns with ω = (0, −Ω, 0).
`Rocketry.spin_frame` gives the rotation, world = frame · local, as the shortest
arc from −Y to the pole. Poles are the IAU WGCCRE values at J2000 (Archinal et al.
2018), with the Moon's, Mars's and Neptune's periodic terms summed at J2000 and no
precession. For Earth the shortest arc fixes the equinox on +X, so the local frame
is J2000 equatorial in the orrery's axis convention: a star's RA and Dec are its
longitude and latitude, as a launch site's are. A world without a measured pole
leans by its `obliquity` about +Z, as `RockyVisual` draws it; a star keeps the
ecliptic, against which heliocentric inclinations are read.

Everything the vessel keeps is local. Orrery positions cross through the frame:
gravity and the potential are summed in orrery axes with the vessel's position
turned out and the sum turned back, `Vessel.body_offset` serves sphere tests and
guidance, and `to_world` / `to_local` serve lighting, the cruise line, the space
map, the mission planner's body states and the orrery camera. A rebase between bodies with different poles
turns position, velocity, attitude and the autopilot's held directions into the
new frame (`on_rebase`). With Earth's 23.44° tilt the pad has seasons, a 28.5° N
launch reaches 28.5° to the equator, and the Moon's orbit lies 18.3°–28.6° from
it over the 18.6-year nodal cycle (`tools/spinframecheck.gd`).

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
