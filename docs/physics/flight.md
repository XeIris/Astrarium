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
