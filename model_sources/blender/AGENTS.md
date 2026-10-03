# model_sources/blender — authored vehicles and launch sites

The script is the model; nothing is clicked. `build.sh` builds the `.glb`
artifacts (gitignored); pass names to build fewer (`build.sh shuttle pad_fss`).
Vehicle builds write directly to `assets/craft/`; pads write to `assets/pads/`.
`tools/sync_assets.sh /external/artifact/directory` can copy separately built
vehicles into `assets/craft/`. Its default confirms the local build without
copying files onto themselves. `lib.py` holds the
primitives (lathe, loft, wing, sphere-cone, bevel) and `common.py` the palette,
optimiser and exporter; neither is buildable.

Blender often lives off `PATH` (on the author's machine it's under Steam), so
check `mdfind -name Blender.app` before concluding it's missing, or set
`BLENDER_OVERRIDE`. Any Blender 4.1+ works.

The procedural builds in `sim/flight/craftmodel.gd` are the fallback when a
`.glb` is missing. Keep them working, and keep `build_craft` synchronous: assets
are preloaded into a cache with `preload_craft(id)`, or settled with
`craft_models_ready([id])` before an audit. Authored and fallback height/datums
must match in stowed and deployed poses; run `crafttest -- parity` with all nine
models. This gate does not establish full silhouette or material parity.

## Axes and datum

- The stack axis is Blender +Z (nose toward +Z), which the exporter turns into
  Y-up. Blender +Y becomes −Z, so the "up" of a cross-section (an orbiter's top
  surface) is Blender −Y. `loft` and `wing` take vertical terms up-positive and
  negate internally; most sign errors here come from this.
- y = 0 is the pad surface, or the footpad plane for a lander (`LM_GEAR` is the
  stand-off). For the Shuttle that is the solids' nozzle exit.
- A stage's `L` is its whole length, nose included. A mounted stage
  (`look.mount`, e.g. the orbiter on the tank) doesn't advance the stack, so stack
  height is a measured `AABB`, not a sum. Mount heights come from the real
  attach points.

## Names are an interface

`common.py` writes node names and `craftassets.gd` validates them before caching
and binding parts. Required counts and swing limits come from vehicle metadata,
including engine ownership and fixed pivots. Missing optional assets may use the
procedural build; present malformed assets must fail the checks.

- One `stage_<key>` empty per stage, then `gimbal_` / `leg_` / `fin_` / `array_` /
  `flap_` / `half_`, each scoped by stage key (`gimbal_sic_3`), because Blender
  names are unique scene-wide. Matching is anchored and digit-terminated.
- A pivot that can't swing is suffixed `_fixed` (e.g. 20 of Super Heavy's 33
  Raptors, the S-IC's centre F-1).
- Opting out is done by not matching: the LM's gear is `gear_`, not `leg_`.
  Declare fixed gear with `look.fixedLegs`; deployable arrays with `look.arrays`.
  `look.enginesPerPivot` must divide the engine count exactly for grouped rigs.

Run `tools/assetcheck.gd` and `tools/crafttest.tscn -- audit clearance`, each
with authored models and with `assets=0`, after changing rigs or metadata.
The asset check exercises stowed/deployed poses and rejects malformed rigs.

## Moving parts

- A driven node (gimbal, leg, fin, flap) carries identity rotation; any fixed
  orientation or azimuth goes on a parent mount (`hinge()` in `common.py`).
  Assigning an Euler angle wipes the node's own rotation, and past 90° the
  decomposed glTF quaternion flips.
- Gimbal pivots sit on the nozzle exit plane, since plumes parent straight to
  them. A pivot declares its swing (`userData.gimbalDeg` / `gimbal_deg`), and
  `update()` clamps to it.
- Deployables are built stowed. A positive swing about the node's Y folds a part
  built along −Z inward, so derive the pre-cant: final pose minus travel.
- A stowed array folds a full 90°. `parts.arrays` means deployable only, so
  fixed radiators don't go in it.

## Shape

- Engine ring radii come from the engine, checked by nearest neighbour over the
  whole cluster (pairs on different rings included). Three-ring radii are 0.90 /
  2.05 / 3.45 exit diameters. Where packing can't close, shrink the drawn bell.
  `crafttest -- clearance` reports the minimum gap per stage; negative is an
  interpenetration.
- A vehicle is one object: position each part against what it bolts to
  (`nodeY + nodeR`) and overlap the joint.
- An interstage adapts from its own diameter to the next stage's (`ctx.nextD`).
  A stage carrying a nose or interstage has a flat tank top.
- A lathed part off the axis must be moved onto its own axis, and a dome's rim
  sits on the barrel.
- A dish radiates along its +Z, away from the hull, with its structure behind the
  reflector.
- `engineOn` means the bells belong to another stage (the SSMEs are on the
  orbiter, not the tank).
- The Hail Mary's four drives hang square, parallel to the axis. `count` in
  `vehicles.gd` equals the model's engine count.
- A stage builder never writes its own group's transform (`build_craft` sets
  it); put offsets on an inner group.

## Materials and export

- Craft materials are double-sided (bells, skirts and interstages are open
  shells) and low-metalness: reflections are unavailable in some quality modes
  and environments.
- Emitters are lit by themselves at HDR values; a hex emissive that looks right
  is nearly black after ACES.
- Meshes are joined by material within each node before export (the Hail Mary
  goes from 612 draw calls to 34), never across nodes, or moving parts weld to
  the body. Bevels are baked in the same pass.
