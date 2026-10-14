# Exhaust plumes at altitude, and launch smoke

How `shaders/flight/plume.gdshader` sizes and lights a plume in air and as the
vehicle climbs, and how `Plume.SmokeColumn`, `shaders/flight/smoke_trail.gdshader`
and `shaders/flight/smoke_volume.gdshader` make the pad cloud, the exhaust trail
and the tanks' boil-off. The near field (shock cells, Mach disk, mixing layer) is described in the
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
`R_eq` as the freestream folds it back. Noise lobes stretched about 5.7:1
along the flow, advected downstream, displace the boundary by ±27%. At
altitude the F-1's fuel-rich film coolant is recirculated toward the base and
burns along the plume boundary ([NASA MSFC base-heating
analyses](https://ntrs.nasa.gov/citations/19950017010)). In staging footage
that reads as long sheets of fire streaming back from the base. The shader
places these tongues by `r / R_b(x)`, the fraction of the boundary's radius,
which stays constant along a streamline, so they fan out from the base as the
plume swells. They are cut with a hard threshold so they read as separate
sheets. Without them the boundary reads as a smooth cone.

### One surface from the nozzle to the far field

Near the nozzle the shader's `jet_radius` widens the jet in two ways. Turbulent
mixing spreads it by ~0.14 exit radii per exit diameter in air, and less in
vacuum. An under-expanded jet also turns outward at the lip by a vacuum law,
`1 + 2.6·u·x^0.62`, which depends only on the pressure ratio. In air that
expansion stops where the boundary's pressure meets `p_a + q`, which is the
balloon. So the radius is

    R_j(x) = max(spreading, min(vacuum expansion, R_b(x)))

and the box `PlumeFx.update` sizes for the jet uses the same expression at its
far end. Without the cap, between ~15 and ~40 km the pressure-ratio cone was
about ten times wider than the balloon. It was drawn around the balloon's dome
as a second, wider cone.

The balloon's fire ends where the jet's flame does (`uFlame`), so the two burn
out together. In vacuum `R_b` grows without bound and the cap no longer applies.

The supersonic core of an under-expanded jet cools as it expands. Its light per
metre is spread over `R_j²`, as the mixing layer's is. Otherwise a merged far
field's core filled the swollen plume with a white glow at the nozzles.

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

Brown absorbing soot sits in the gaps between the hot tongues (`sig_hi`,
weighted by `(1 − tongue)²`), which gives the plume its dark streaks. A cluster's single-engine near fields dim and redden
with the pressure ratio as well: their expanded cores have cooled, so their
light is the mixing layer's colour, not the white core's.

## Flame, then smoke

In air a kerosene plume's luminous part is short. Fuel-rich exhaust
afterburns in the mixing layer and burns out within about a vehicle length
(`flame_len = d_exit (8 + 30·u)`, with `u` the under-expansion measure, so it
lengthens as the air thins). Past it the exhaust is soot and condensing
water: a grey column that scatters daylight. That column is drawn by the trail
([below](#the-trail)), from where it grows out of the flame onward; the plume
shader's own soot fades out over the same stretch.

### How dense the smoke is

The smoke is the exhaust laid along the path. Each metre of trail holds
`ṁ / v` kilograms: the mass flow over the airspeed. A slow vehicle near the pad
leaves a thick column and a fast one high up leaves a thin one. How much of that
mass shows depends on the propellant:

    smoky = soot + water · (0.3 · (p_a / p_0)^¼ + 0.7 · cold)

`water` is the exhaust's water relative to kerosene's (kerosene ≈ 30 % by mass,
hydrogen nearly all, methane about half). Low down the water condenses in the
humid air, which thins with altitude. Above the tropopause (−55 °C, `cold`
rising from 12 to 26 kPa) it freezes to ice, which is why a trail stays bright to
staging. Spread over a column of radius `R` the optical depth across it is

    τ = SMOKE_K · smoky · ṁ / (v · R),        SMOKE_K = 2

This line density `K` is the column's whole budget: whatever its width, every
metre of it holds `σ ≈ K / (2 R²)` with `R` its half-density radius, so the
near-field column, the ballooned one and the trail far behind are shapes of the
same smoke. Widening changes its shape and thins it; it never steps.

**Where the flame stops.** In the ballooned far field the luminous tongues fade
out by `uFlame·L` while the column grows in, filling the radius the balloon has
narrowed to (`0.62·R_eq` at the box's end). Light from the balloon comes
from incandescent soot and from afterburning in the shock. A clean methane plume
still glows (`inc = soot·1.15 + afterburn·0.35`).

**The box's length.** The plume's box still runs past the flame,
`L ≥ flame_len·(1 + 1.2·c)` with `c = clamp(τ/0.08)`, so it shrinks smoothly as
the column thins instead of jumping. Its end is where the trail's nodes are laid.

The smoke's reflectance is `Plume.smoke_grey`: 0.42 for kerosene soot, 0.72 for
a solid's white alumina, and near-white condensation for hydrogen.

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
- **Trail.** One continuous column along nodes laid in the air
  ([next section](#the-trail)).
- **Boil-off.** `Cryo` (`sim/flight/cryo.gd`) vents cold vapour from the top of
  each cryogenic stage's upper tank while the vehicle sits fuelled: sixteen
  small, faint puffs a second per vent, which overlap into a stream. It is
  denser than air, so it slumps as it spreads and evaporates in 2–4 s. The
  vehicle, a vertical cylinder, shades the vapour on its far side from the sun.
  The same module draws rime on those tanks: on the oxygen tank of a kerosene
  stage, lightly on an insulated hydrogen stage, on both tanks of a methane
  stage. The rime forms in broad patches, streaked vertically where condensate
  froze running down the stringers. It sheds over the first ~20 s of flight.

## The trail

The exhaust trail is one tube of smoke, not a string of puffs. A column of
puffs reads as beads however they are jittered: each puff is densest at its
centre, so the column's density rises and falls at their spacing, and puffs laid
per frame gap apart at speed. Puffs also show less than their nominal size (a
sprite's visible radius is well inside its quad, a volume puff's eroded radius
inside its sphere), so a trail of them is narrower than the column it continues.

**Strands.** Each smoky plume lays its own strand: the longest lit one, and each
lit separation motor (solid, so its column is alumina). A strand whose plume goes
out (cutoff, staging, a burnt-out motor) leaves its column in the air as its end,
and the next stage starts a new one.

**Nodes.** `SmokeColumn.trail_to` lays a node where the plume's box ends each
time the vehicle has gone a fixed distance past the last one, interpolated
along the frame's path: three column radius scales, or an eighth of a second's
flight when that is longer, so 110 s of the main strand fits in half of the
2048 nodes. Nodes link to their neighbours by slot and sequence number, so
strands can interleave in the ring and a reused slot ends a strand cleanly. A node records
the column's radius scale `a` and line density `K` there. It drifts with the
air, slows to the wind, widens by turbulent diffusion as `a √(1 + 0.35·age)`,
and its `K` disperses over the last 40 % of a 70–110 s life, each node on its
own clock so an old trail breaks up raggedly.

**The live end.** Ahead of the newest node the column hangs from the plume:
eight samples along the plume's axis (`PlumeFx.column_*`) from where it grows
out of the flame (35 % of the flame's length, `K = 0`) to the box's end. Their
widths and weights are the plume's own: the near field's column widens with the
jet as `R_j · (1 + 0.9·ramp)` exit radii; the balloon's fills it as it narrows
(`balloon_radius`); `uHi` weights them. The plume shader's soot fades on the
same ramp, so the column replaces it rather than covering it. Because the column
and the trail are the same geometry in the same shader, there is no hand-over.
A column drawn in the plume's own box cannot hand over to a trail starting at
its end: no fade between two separately composited volumes matches one medium,
whichever is drawn first, and the plume is always drawn after the smoke.

**One column, many segments.** Each instance is the box round one segment
between two points, but its march counts only the slab between the segment's end
planes. Each end plane bisects the bend into the neighbouring segment, so
neighbours share it and the segments partition the column. Overlapping them and
cross-fading the density does not work: two half-density volumes composited one
over the other average their light from deeper inside than one full-density
volume would, and show bands at every joint. Along a segment, `a` and `K` are
interpolated by the distances to the two end planes, so they agree with the
neighbour's on the plane they share. Segments are sorted by the distance from
the eye to their nearest point, which along a chain draws each one behind its
neighbour nearer the eye; sorting by centre puts thin seams at the joints seen
side-on.

**Density** (`smoke_column.gdshaderinc`). In a column of radius scale `a`:

    σ = K · body · (0.3 + 2.1 n²) / (2 (0.82 a)²)
    body = smoothstep(1.2, 0.45, r/a + 1.3 (lobe − ½))

`lobe` is noise with features about `2.2 a` across, pushing the edge in and
out to 1.85 `a`; `n` is noise about `0.8 a` across, looked up through the lobes
(domain warping), so the detail curls round them. The noise is fixed in the air,
not the vehicle (`uAir`, carried through every reframe and the wind), so the
column streams back past a climbing vehicle. Its scale follows `a` without the
pattern sliding: two power-of-two octaves either side of the wanted size are
cross-faded by `log₂ a` and restored to full contrast, and each octave keeps its
own texture offset, or the pattern jumps where the width crosses a power of two.
High and Ultra add a finer octave at full contrast, so it adds detail but not
density.

**Light.** The sun reaches a point through the column's mean extinction
`K/(2a²)` along its chord to the sun (`tube_chord`), capped at four radius scales
when the sun is down the axis. Smoke is optically thick: light scattered many
times reaches deeper than the direct beam, so a second, weaker and more forgiving
term carries it, `e^{−τ}·phase + 0.4 e^{−0.4τ}` (the octave approximation of
Wrenninge, *Art-Directable Multiple Volumetric Scattering*, SIGGRAPH 2015 talk).
The phase function is Henyey–Greenstein, g = 0.55, mixed 70:30 with isotropic,
as for the pad cloud's volumes; the sky lights the column from above and the
ground from below. On Ultra two steps toward the sun through the noise add the
billows' own shadows, as a departure from the mean so the column is no darker on
average.

**March.** Low, Medium, High and Ultra take 8, 10, 12 and 12 steps through each
segment's chord, about 0.3 `a` on High. Coarser steps in a dense column light it
from deeper inside and darken it.

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
- **Vapour.** Boil-off is drawn as thin sheets: the sharpened ridges of the
  noise inside a ragged envelope. Most of each puff is empty, so the
  overlapping puffs read as wisps, not balls.
- **Soot albedo.** Smoke is optically thick, so multiple scattering raises its
  effective albedo to about 0.35. A volume puff of soot uses that rather than
  the near-black single-scattering colour the flat sprites use.
