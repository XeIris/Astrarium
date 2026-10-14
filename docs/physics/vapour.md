# Condensation collars

Near Mach 1 in humid air a rocket wears white collars: fog that hugs the
vehicle behind each shoulder and ends in a sharp edge. `sim/flight/vapour.gd`
works out where they form and how dense they are. `shaders/flight/vapour.gdshader`
draws them. They are not always there. Whether they form depends on the
humidity, the temperature and the Mach number. `tools/fxlab.tscn` shows them
with `humidity=` and an altitude near Mach 1.

## Why the air fogs

Air turning a convex corner (the foot of a nose cone, an interstage flare, the
top of a boat-tail) accelerates and expands. Expanding, it cools at constant
total temperature:

    T_l = T · (1 + 0.2 M²) / (1 + 0.2 M_l²)

The water vapour expands with the air, so its partial pressure falls with the
pressure, `e_l = RH · e_sat(T) · (T_l / T)^3.5`. Saturation pressure falls far
faster. Magnus's `e_sat(T) = 611.2 · exp(17.62 t / (243.12 + t))`, with `t` in
°C, roughly doubles every 10 K. A few kelvin of cooling can therefore take
humid air past saturation. The water condensed is what is left over:

    w = max(e_l − e_sat(T_l), 0) / (R_v · T_l)      kg/m³,  R_v = 461.5 J/(kg·K)

At the shock that recompresses the flow the air warms again and the fog
evaporates. That shock is the collar's sharp aft edge.

## The local Mach number

The peak Mach number over a corner that turns the flow by `θ`:

- **Below Mach 1:** an incompressible pressure dip `Cp ≈ −θ`, scaled by
  Prandtl–Glauert `1/√(1 − M²)`. The scaling is capped at Mach 0.98, where the
  linear theory fails. The isentropic relation turns the pressure into a Mach
  number.
- **Above Mach 1:** a Prandtl–Meyer expansion, `ν(M_l) = ν(M) + θ`.
- **Between 0.98 and 1.05:** a blend of the two.

The pocket of expanded air grows toward Mach 1, so the collar is longest and
widest there. Its length is `R (1.4 + 3.2 b)` and its flare `0.25 + 0.75 b`,
with `b = exp(−((M − 1)/0.14)²)`. Away from Mach 1 it is a thin sheath.

## Where the corners are

The shoulders are measured off the built vehicle, so they work for every model,
authored or procedural. The meshes give the stack's radius in 96 height bins.
Each mesh's vertices are interpolated between its rings, because a cylinder's
vertices are only at its ends. The radius is taken in eight sectors round the
axis, and each bin keeps the second-narrowest. Fins, flaps and side-mounted
boosters fill only some sectors, so they do not count as the body. A corner is
either the foot of a rise of a fifth or more (a nose or a flare), or the top of a
boat-tail. The lowest sixth (bells, skirts, fins) is skipped.

## How it looks

Droplets formed in an expansion lasting milliseconds have no time to grow. At
about 0.3 µm their extinction is `3 Q / (4 ρ_w r) ≈ 5000 m²/kg`. A gram per
cubic metre of fog (a humid day near the ground) then has `σ = 5 m⁻¹`, opaque
across a metre. The shader marches the annulus between the skin and the edge.
The fog is thickest against the skin and streaked along the flow. It is white,
and bright toward the sun, because small droplets scatter forward.

## Humidity

`Plume.humidity` is the troposphere's relative humidity (the lab's slider).
The stratosphere is dry, so above 9–13 km it falls to 3 %. Combined with the
cold up there, almost nothing is left to condense. That matches what is seen:
collars appear in the first minute or so of a launch, around Mach 1, on humid
days.
