# shaders — and how bodies look

These rules also cover the CPU halves: `sim/*_visual.gd`, `sim/terrain.gd`,
`sim/prominence.gd` and `sim/sky.gd`. Translation from Three.js, blending modes
and the temperature pass are in [docs/godot.md](../docs/godot.md).

## Pipeline

- Rendering is HDR, tone mapped once in `render/postfx.gd`. Emitters write values
  well above 1, and an emitter that faces away from every light must light
  itself.
- Every emitter publishes its true temperature through the temperature pass
  (`shaders/common/temp_pass.gdshaderinc`, `is_temp_pass`). Without it, X-ray and
  radio bands guess T from colour. Check in band 5 (X-ray).
- The sky is the exception: `SKY_ALPHA` (0.995) means "already imaged in this
  band". It is composited per band in `sky.gdshaderinc`, because most of the
  non-visible sky is non-thermal. A new sky component is a row in the band-weight
  table, not a temperature.
- Flare plasma adds colour but replaces the temperature value; absorption passes
  `discard` in the temperature pass. Check: `preset=alphacen`, Proxima, a forced
  flare, band 5.
- Body shaders are `render_mode unshaded` and light themselves from the sun
  uniforms (`suns.gdshaderinc`).
- A transparent object is drawn after every opaque one, whatever its
  `render_priority`. A background either depth-tests or goes in its own earlier
  pass.
- Volumes in local space (clouds, plumes, glare) are depth-test-disabled and stop
  their rays at `hint_depth_texture`. Godot's projection has a flipped y: use
  `abs(PROJECTION_MATRIX[1][1])`.
- A geometric march jitters its parameter s in t(s) = t0 + base·(rˢ − 1), not t,
  or the long steps land on shared shells.
- Lines at grade (joints, scorch) are `ground_mark.gdshader` multiplies filtered
  by `fwidth`, not geometry. Anything at grade stands clear of the hardstand flank
  (radius + 2.6·PAD_RISE).

## Resolution

- Procedural noise has no mip chain: filter subpixel detail and choose octave
  counts against the screen. Inspect motion as well as still frames.
- Nothing in the sky may depend on a fixed angular resolution: lensing
  magnification is unbounded near the photon ring. Stars are analytic and
  filtered through the screen-space Jacobian. Check: `preset=bhmerger`, where the
  lensed arcs must be strings of crisp points.
- Sky environments are populations and add (`blend_environments`). Shape terms
  (scale height, plane concentration, bulge size) take the weighted mean. Each
  parameter declares which on `SKY_PARAMS`, which also builds the settings panel.

## Solid surfaces (`rocky_surface.gdshader`, `terrain.gdshaderinc`)

- Land fraction goes through the inverse normal CDF (`crust_threshold(0.29)`),
  not `1 − land`: the noise is near-Gaussian (mean 0.497, sd 0.1065).
- Albedos are physical albedos (forest 0.12, sand 0.38). `uGain` is the one
  shared exposure constant.
- `uFrostK` is the dominant volatile's condensation temperature (273 K water,
  148 K CO₂, 37 K N₂); a new frost is a new temperature. `uCrater` decides whether
  impacts are erased.
- `uSeaKm` is the height of the datum, not an offset (a dry world's sea is 60 km
  down, which is not 60 km of altitude for the lapse rate).
- Seasonal caps come from `uDecl` (sine of the sub-solar latitude) and `uSeason`;
  the annual mean can't grow Mars's CO₂ cap.
- The hot end is derived too: `rocky_visual.gd` derives `uSeaKm`, `uScorch` and
  `uArid` from temperature, but only for bodies with an atmosphere.

## Gas giants and cloud decks

- Advected noise must be flow-mapped: two copies on clocks half a period apart,
  cross-faded with `w = 1 − |2t/T − 1|`. Otherwise the shear turns the field into
  moiré stripes within a minute. The period is 16 s on a giant and 20 s on a
  cloud deck.
- The mesh rotates at the interior (System III) rate, and everything visible
  moves over it. Nothing cloud-related goes in the mesh transform.

## Stellar eruptions (`prominence.gd`, `prom_*`, `star_cme`)

- Plasma lives on field lines: an eruption is an arcade of separate threads
  anchored in two ribbons, and the arcade's length along the neutral line is
  several loop spans.
- The rope is strongly sheared and relaxes toward square as the event proceeds;
  the shear is the free energy.
- A prominence and a filament are one object, drawn twice from one buffer:
  emitting off the limb and absorbing against the disc (tested in view space
  against the star's centre).
- The arcade buffer carries only thread index, arc parameter and side; the shape
  is all in the vertex shader. One buffer serves every star and is never freed.
- A CME shell is weighted by path length through it (bright at the rim). The
  front, cavity and core are two additive shells with a gap.
- Joy's law: a bipole lies near east-west, tilted by about half its latitude, so
  every arcade in a hemisphere leans the same way.

## gdshader traps

- Writing `ALPHA` makes a material transparent, even at 1.0.
- Float literals below ~1e-14 compile to 0.0; spell them as bit patterns
  (`uintBitsToFloat(0x179abe15u)` for 1e-24). `isnan`/`isinf` are unreliable on
  Metal.
- There are no mutable globals; a value one function sets for another becomes
  a parameter.
