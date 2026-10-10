# Exhaust plumes at altitude, and launch smoke

How `shaders/flight/plume.gdshader` sizes and lights a plume in air and as the
vehicle climbs, and how `Plume.SmokeColumn` and `shaders/flight/smoke_volume.gdshader`
make the pad cloud, the exhaust trail and the tanks' boil-off. The near field (shock cells, Mach disk, mixing layer) is described in the
shader's header. Everything here is an appearance model driven by flight
state; nothing feeds back into thrust or trajectory.

## Why a plume balloons

An under-expanded jet leaves the nozzle at a higher pressure than its
surroundings and turns outward at the lip until its boundary pressure matches
what pushes on it. Near the pad that is the ambient pressure, and the jet
barely widens. In flight the freestream adds roughly its dynamic pressure `q`
where it meets the plume's boundary, so the boundary settles where

    π R² · k (p_a + q) ≈ F

with `F` the thrust carried by the plume. `Plume.PlumeFx.update` solves this for
the equilibrium radius

    R_eq = √(F / (π k (p_a + q))),   k = 2.5

and passes `uBalloon = R_eq / r_exit`. `k` is a shape factor that absorbs the
boundary's inclination and the momentum still in the jet. `F` is the vacuum
thrust times throttle. With that, an F-1 at sea level (7.8 MN, p_a = 101 kPa)
gives 3.1 m against a 1.77 m exit radius: the near-pencil seen at liftoff.

| Saturn V first stage (five F-1, 38.9 MN vacuum) | p_a | q | R_eq |
|---|---|---|---|
| liftoff | 101 kPa | 0 | 7.0 m |
| max-q, ~13 km | 16.5 kPa | ~33 kPa | 10 m |
| T+146 s, 46.6 km (this simulator) | 0.14 kPa | 2.9 kPa | 40 m |
| near staging, ~60 km | ~0.02 kPa | ~0.6 kPa | ~90 m |

Staging photographs show the first-stage plume many vehicle diameters across
(the stage is 10 m wide), which this scale reproduces. The far field of a
cluster carries the whole cluster's thrust; its single-engine near fields do
not balloon, since they hand over to it within a few diameters.

## Shape

`balloon_radius` in the shader turns the corner within about one `R_eq`
(`1 − e^(−2.6 x/R_eq)`), holds, and then narrows by about a third over six
`R_eq` as the freestream folds it back. Noise lobes stretched about 4.5:1
along the flow, advected downstream, displace the boundary by ±30%. At
altitude the F-1's fuel-rich film coolant is recirculated toward the base and
burns along the plume boundary ([NASA MSFC base-heating
analyses](https://ntrs.nasa.gov/citations/19950017010)). In staging footage
that reads as long sheets of fire streaming back from the base, which the
stretched lobes imitate. Without them the boundary reads as a smooth cone.

## Brightness

Three things decide how much the ballooned plume glows.

- **Incandescent soot.** It glows whether or not there is oxygen left to burn,
  so the shell's emission scales with the propellant's soot (`inc`). A kerosene
  F-1 plume stays bright orange at altitude; a hydrogen J-2 plume is close to
  invisible against daylight.
- **Shock heating.** Where the freestream meets the boundary it is compressed
  and heated. `uShellK = √(clamp((p_a + q) / 4 kPa))` brightens the shell with
  the air it is meeting and fades it in vacuum.
- **Spreading.** The emission per metre is scaled by `1/R_eq`, so a path
  across the swollen plume carries the light. The narrow neck at the exit
  stays dim, because the shock heating develops where the freestream meets the
  boundary, downstream. (Scaling by the local radius instead put a white hot
  spot at the nozzles.)

Brown absorbing soot sits between the hot tongues (`sig_hi`), which gives the
plume its dark streaks. A cluster's single-engine near fields dim and redden
with the pressure ratio as well: their expanded cores have cooled, so their
light is the mixing layer's colour, not the white core's.

## Flame, then smoke

In air a kerosene plume's luminous part is short. Fuel-rich exhaust
afterburns in the mixing layer and burns out within about a vehicle length
(`flame_len = d_exit (8 + 30·u)`, with `u` the under-expansion measure, so it
lengthens as the air thins). Past it the exhaust is soot and condensing
water: a grey column that scatters daylight. The plume shader draws that column
in the rest of its box (`uTrailK`, `uTrail`), widening and broken by the large
eddies. `Plume.SmokeColumn` then continues it as a world-fixed trail.

Its density is the propellant's soot plus 0.3 for condensation, times
`(p_a / p_0)^¼`, which thins it with altitude. Its reflectance is
`Plume.smoke_grey`: 0.42 for kerosene soot, 0.72 for a solid's white alumina,
and near-white condensation for hydrogen.

## The pad cloud and the trail

Both live in the air, not on the vehicle. The local flight frame follows the
vehicle and the planet turns under it, so every frame
`Spaceflight._reframe_smoke` maps each puff through
`x′ = B′ᵀ(B x + O + ω×O·t − O′)`. `B` is the local frame, `O` its origin under
the vehicle, and `ω` the planet's spin.

- **Pad cloud.** A trench deflector turns the jet 90° and throws it out of both
  ends. About 80% of puffs leave along the trench axis, starting 1.6–3 plume
  widths out at speed; the rest roll out round the base. An open deflector
  throws them every way. Forty small puffs a second, growing as
  `√(1 + 2.4·age)`, fading in over half a second and living about 15 s,
  overlap into one billowing cloud. A few large ones read as separate balls.
- **Trail.** Puffs are laid where the shader's column fades, spaced by 0.42
  of its width and jittered in size and position so the column is not a tube.
  They slow to the wind, widen as `√(1 + 0.35·age)` and last 70–110 s.
- **Boil-off.** `Cryo` (`sim/flight/cryo.gd`) vents cold vapour from the top of
  each cryogenic stage's upper tank while the vehicle sits fuelled. It is
  denser than air, so it slumps as it spreads and evaporates in 2.5–4 s. The
  same module draws rime on those tanks: on the oxygen tank of a kerosene
  stage, lightly on an insulated hydrogen stage, on both tanks of a methane
  stage. The rime sheds over the first ~20 s of flight.

## Launch smoke as volumes

On High and Ultra each puff is a sphere of eroded 3D noise (the cloud field's
Perlin volume), raymarched from its camera-facing quad and stopped at the
depth buffer. The large noise octave also moves the surface in and out, so no
puff keeps a round silhouette. This is the split that compensated ray marching
uses ([Zhou et al. 2008](https://www.microsoft.com/en-us/research/publication/real-time-smoke-rendering-using-compensated-ray-marching/)):
the low-frequency shape (the spheres) is lit cheaply, and the fine detail is
added only along the view ray.

- **The sun through the cloud.** For each pad puff, the CPU sums the chords of
  40 randomly chosen other puffs that cross its sunward ray, weighted by their
  opacity and scaled to the whole cloud. It passes the smoothed `exp(−sum)` as
  the instance's custom.y. A tenth of the puffs refresh per frame. Inside the
  puff, a short march toward the sun adds its own shading.
- **Scattering.** Henyey–Greenstein with g = 0.55, mixed 70:30 with isotropic.
  Skylight comes from above and ground bounce from below.
- **Fire light.** The deflected exhaust lights the low puffs from underneath,
  falling off with distance from the flame in puff diameters. It goes out
  as the jet stops reaching the deck.
- **Soot albedo.** Smoke is optically thick, so multiple scattering raises its
  effective albedo to about 0.35. A volume puff of soot uses that rather than
  the near-black single-scattering colour the flat sprites use.
