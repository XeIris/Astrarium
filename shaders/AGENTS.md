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
- Only J-independent layers (diffuse emission, dust depth) may come from the
  per-direction cache (`render/sky_cache.gd`). A new diffuse uniform joins
  `SkyCache.INPUTS`; anything that gates a point source stays live. Run
  `tools/skycachecheck.tscn` after changing the sky.
- Sky environments are populations and add (`blend_environments`). Shape terms
  (scale height, plane concentration, bulge size) take the weighted mean. Each
  parameter declares which on `SKY_PARAMS`, which also builds the settings panel.

The lens uses scene-relative float coordinates and horizon-relative lengths.
Single-hole ray geometry has independent shadow/weak-field checks in
`tools/lenscheck.tscn`; two-hole superposition and disc transfer remain illustrative.
See [the ray contract](../docs/physics/lensing.md#ray-coordinates-and-numerical-scope).

- A point source held a fixed number of pixels wide draws `point_flux`
  (`shaders/common/point_source.gdshaderinc`) of its flux per pixel solid angle,
  never that flux directly: zoom and lensing make it unbounded, and bloom spreads
  it across the frame. Check: `tools/glowcheck.tscn`.

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
- A world's look follows its climate: `ClimateLook` derives the surface's uniforms and the
  deck's cover, and its `Binder` eases them on without a rebuild. A stated spec value wins.
  Nothing writes these uniforms directly, or a stated value and the ease both break.

## Gas giants and cloud decks

- Advected noise must be flow-mapped: two copies on clocks half a period apart,
  cross-faded with `w = 1 − |2t/T − 1|`. Otherwise the shear turns the field into
  moiré stripes within a minute. The period is 16 s on a giant and 20 s on a
  cloud deck.
- The mesh rotates at the interior (System III) rate, and everything visible
  moves over it. Nothing cloud-related goes in the mesh transform.

## Stellar surfaces (`star_photo`, `star_corona`, `star_noise`)

Models and sources: [docs/physics/stellar-surfaces.md](../docs/physics/stellar-surfaces.md).

- A photospheric feature is a local temperature drawn through `sn_planck_ratio` and
  published in the temperature pass; never paint a feature's colour.
- The chromosphere's weight (`StarVisual.CHROMO_GAIN`, `CHROMO_VEIL`) is the one
  display exaggeration. It exists only with a convective envelope, and on giants
  their convection cells carry the disc instead.
- The corona billboard's limb is the spheroid's projected outline (`uFlat`), not the
  equatorial radius. Check: `tools/sunlab.tscn` with `star=vega`.

## Stellar eruptions (`prominence.gd`, `prom_volume`, `star_cme`)

- Plasma lives on field lines, and a picture of it is a line-of-sight integral. Each
  structure is a volume marched through a box (`Prominence.frame_bounds`), its density in
  field-aligned coordinates; never draw a thread as a line or ribbon. `prominence.gd`
  derives the geometry (`uGeo`) and the box from the same numbers.
- Density is structure; excitation (`lit`: footpoint heating, the order loops light in)
  multiplies the emission only. Thin emission goes as n², so a weight folded into n
  is squared. A draining rope loses material, so its fade is in n.
- Filament and prominence are one volume: blend_premul_alpha, emission over the
  transmitted background. Cool material hides only `LINE_SHARE` of the disc (thick in the
  lines, thin in the continuum), and its emission against the disc is the disc's light
  scattered, below it. Hot loops have no opacity; a cooling arcade's only opacity is its
  rain, the strands that condense to 10⁴ K once the loops fall below ~2 MK.
- Steps are even, a fraction of a strand apart and no finer than a pixel; the cheap
  envelope test (`full = false`) skips the density outside the structure. A two-level
  march that backs up after a long step ping-pongs on a widened envelope and drops
  structure; jitter with white noise, since an ordered dither cross-hatches thin strands.
- An unwritten `out` parameter is undefined, not its caller's value: every structure
  function writes `lit`.
- The rope is strongly sheared and relaxes toward square as the event proceeds; the
  shear is the free energy.
- A CME shell is weighted by path length through it (bright at the rim). The
  front, cavity and core are two additive shells with a gap.
- Joy's law: a bipole lies near east-west, tilted by about half its latitude, so
  every arcade in a hemisphere leans the same way.
- Every spot group carries hot coronal loops between flares: nearly invisible in
  white light (`uGlow`), bright in X-ray. A post-flare arcade's colour, visibility and
  opacity follow its cooling (`cooled`).
- Hot plasma publishes its temperature on the disc as well as off it; cool (< 10⁵ K)
  material on the disc leaves the photosphere's value. Check: `tools/sunlab.tscn` with
  `band=5`, `at=top`.
- The corona billboard leaves the temperature underneath, except its 10⁴ K spicule
  fringe. Its glow is too faint to be the band remap's coverage, and replacing the
  sky's code blacks the sky out. Past the Linsky–Haisch line (`Stellar.hot_corona`) a
  giant has no hot corona, loops or quiescent prominences.

## Envelopes (`star_envelope`)

- A star whose atmosphere is not a thin skin (a levitated molecular layer, a dusty wind,
  a hot star's thick wind) gets a sphere marched evenly in the angle about the star's
  centre, which gathers samples at the closest approach and integrates a 1/r² wind
  exactly. Its parameters come only from `Stellar.envelope_of`.
- Extinction is per colour, blending has one alpha: the background goes out by its least
  transmitted colour and the rest comes back from the photosphere it covers.
- Ejected puffs ride the sim clock and conserve mass; their dust's opacity is the jump
  that dims the star. Check: `tools/sunlab.tscn` with `star=mira cam=9 puff=3,-0.08,1.5`.

## gdshader traps

- Writing `ALPHA` makes a material transparent, even at 1.0.
- Float literals below ~1e-14 compile to 0.0; spell them as bit patterns
  (`uintBitsToFloat(0x179abe15u)` for 1e-24). `isnan`/`isinf` are unreliable on
  Metal.
- There are no mutable globals; a value one function sets for another becomes
  a parameter.
