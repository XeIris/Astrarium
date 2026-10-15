# Re-entry plasma

What is drawn is the shock layer, the gas between the bow shock and the skin,
and the wake it sheds. Its brightness and colour come from one number: the
vessel's Sutton–Graves stagnation flux q₀ (`Rocketry.heat_flux`, at the nose
radius `Vessel` uses), the same flux that loads the heat shield. Code:
`Plume.EntryGlow` and `EntryUnit` in `sim/flight/plume.gd`;
`shaders/flight/entry_glow.gdshader`, `entry_wake.gdshader` and
`entry_plasma.gdshaderinc`.

## Units

Each body the air heats on its own is a unit: every stage of the craft, driven
by the stack's flux while it is attached, and each piece handed to `Fall` (the
boosters, the External Tank), driven by its own flux from its own airspeed,
density and diameter. A unit's flow direction is its own velocity through the
turning air, in world axes. A detached stage that is not a `Fall` is dark.

## The layer on the skin

The layer is the vehicle's own skin meshes drawn again as a `material_overlay`:
three shells chained by `next_pass`, pushed out along the normals by 0.6 %,
4.5 % and 12 % of the diameter, and thickened by up to 2.5× toward the
shoulders, where the real standoff grows. Riding the skin, the layer fits every
part, flap and separated piece, and the vehicle's depth hides its own far side.
Decals and nodes with their own shader (frost, plumes) are skipped.

With c = n̂·v̂ the cosine of incidence (v̂ the body's direction through the air):

- the local wall flux is q₀·c², times √(R_ref/R) for the local radius of
  curvature R, estimated from the normal's change across the pixel and clamped
  to 0.6–1.8. At 40° α the belly gets c² ≈ 0.41 of the nose: about the
  radiative-equilibrium ratio of the belly tiles' 1260 °C to the nose cap's
  1650 °C, (1533/1923)⁴ ≈ 0.40. The radius term lifts the nose cap and the wing
  leading edges above the flat belly;
- the gas's radiance climbs faster than the wall flux with the shock's
  strength, so the layer shines as (local flux)^1.5;
- c ≤ 0 is dark: the leeward side and anything facing away from the air;
- so is skin in the body's own lee (Newtonian shadowing): the air meets the
  first surface in its path and nothing behind it. The wake's grid (below)
  keeps, for each column along the flow, the most upstream skin depth; it is
  uploaded as a texture every 0.1 s, and each shell fragment compares its own
  skin point's depth with the four nearest columns. A point more than the
  tolerance behind is sheltered, blended over a second tolerance so the edge is
  soft. The tolerance is the wake's (the larger of 4% of the diameter and
  0.6 cell) plus the depth the point's own surface spans across 1.5 cells,
  1.5 cell·tan θ, so slanted windward skin does not shade itself. The samples
  are sparse, so an empty column with skin on both sides within two cells
  takes the lower of the two and the silhouette does not grow. The orbiter's
  fin and OMS pods, forward-facing but behind the fuselage at 40° α, go dark;
- the local temperature is T₀·(local flux)^¼, where T₀ is the stagnation
  temperature derived from q₀, and it sets the colour: deep red near 2000 K,
  red-orange by 3500 K, yellow-orange by 5000 K, blue-white above 8000 K;
- a thin glowing layer brightens toward its limb (longer path), and the
  outermost shell fades toward its own silhouette so that no edge line is
  drawn round the vehicle;
- turbulence is value noise stretched along the flow and advected aft.

A blunt body's bow-shock cap is the same layer on its heat shield, which faces
the flow squarely (c ≈ 1). It stands about 0.12 D off the shield and wraps the
shoulder.

## The wake

Gas leaves the skin where the windward surface ends. Every 0.1 s, 1200
area-weighted skin samples are projected along the flow onto a 28×28 grid. A
sample is a departure point when three things hold:

1. it is windward (c ≥ 0.1);
2. it is the first thing the air meets in its grid column, so it is not in the
   lee of the body. This excludes a bump on the leeward fuselage that has the
   belly ahead of it;
3. one and a half cells along the direction the gas runs over the skin (the
   normal's part across the flow), the projection is empty, so the surface ends
   there. This keeps trailing edges, chines and a heat shield's shoulder, and
   rejects leading edges and the middle of the belly.

Departure points are weighted by c². Streaks are drawn from them along the
flow: camera-facing ribbons that widen downstream, flicker, and run aft as
they fade. The wake is cooler and paler than the layer it left, and saturates
with flux: a harder entry gives a longer wake (2.5–8.5 diameters), not a
blinding one.

## Limits

- No radiative transfer, no chemistry and no ablation products. The colour
  ramp is the progression seen in entry imagery, not a spectrum.
- Shadowing is Newtonian: a sheltered surface is dark however close it is to
  the shock. Real lee flow is not quite empty (the fin sees a weak expansion
  flow), and the 28-column grid resolves shelter to about 1/28 of the body,
  so a small part near the edge of a shadow is softened rather than cut.
- The curvature estimate is per pixel, so its effect varies with distance from
  the camera. Its clamp keeps the change bounded.
