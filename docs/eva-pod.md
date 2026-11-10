# EVA Pod (2001-inspired)

Phase 1 of [issue 26](https://github.com/XeIris/Astrarium/issues/26): a flyable
one-person work pod, twin articulated manipulators, and a compact cockpit.
Choose it in Spaceflight's hangar. **C** cycles through Interior; drag to look
around inside. **G** extends or parks the arms, opening the claws as they extend.
The hangar's Deployed toggle also poses them. Bindings can be remapped in Settings.

## References and interpretation

The source is our own scripted Blender geometry, not an imported replica mesh or
texture. Reference pictures are used for observation only and stay in ignored
evidence. No studio markings, character likenesses or HAL eye are included.

- [Production stills, Starship Modeler](https://www.starshipmodeler.com/2001/2001ref.htm#pods):
  frontal pod-bay view, front three-quarter space views, and the working arms.
- [Pod variants and dimensions](https://sites.google.com/site/theageofplastic3d/eva-pod-research/eva-pod-research-variants-and-interiors):
  the 81-inch miniature-derived interpretation gives a 2.06 m sphere. The actual
  prop size is disputed; this is a reconstruction choice, not measured CAD.
- [Exterior details and continuity](https://sites.google.com/site/theageofplastic3d/2001-eva-pod-continuity):
  five ports on each side dome, conical notched ears, four headlights, rear hatch,
  and the simpler underside variant.
- [Interior photographs and construction](https://sites.google.com/site/theageofplastic3d/2001-eva-pod-interior):
  brick-red lining, padded black panels, blue and cream keys, twin displays and
  manipulator controllers. The film's separate interior set was larger than the
  exterior. Our one-seat interior is compressed to fit the same pressure sphere.

The deep oval window reveal, angular lower cradle and two parallel-link arms
follow those references. The cockpit uses faceted consoles, individually labelled
Perspex-style pushbuttons, round paddle-switch plates, inward-canted flat displays,
waldo grips, stitched padded walls, harness webbing and five recessed practical
lights. The one-seat layout is adapted to the available hull volume. The fixed
rear hatch does not open. Manipulators are visual mechanisms and do not grab objects or
transfer forces. Their shoulder, elbow and two claw pivots are nested so that
child geometry follows its joint through every intermediate pose.

## Estimated propulsion

All dimensions, mass and propulsion inputs live in `sim/flight/vehicles.gd`.
Dry mass is **1,200 kg**, main propellant **120 kg**, thrust **400 N**, and specific
impulse **220 s**. Attitude jets are **25 N**, with **20 kg** of RCS propellant.
These are explicit fictional estimates, not film specifications. The normal
SI vessel integrator, fuel accounting and attitude controller fly the pod.
The underside outlet is the +Y thrust-axis engine; the window faces +Z.

## Assets and interior lifetime

`model_sources/blender/build.sh evapod` exports `assets/craft/evapod.glb` and
`evapod_interior.glb`. As with other craft, these are ignored generated assets;
`model_sources/blender/evapod.py` is the editable source. The exterior and interior
share the stage datum: bottom at Y=0, sphere centre Y=1.03 m. The seated camera is
(0, 1.34, -0.30) m in that frame.

`evapod_cabin.py` authors the fitted cockpit. Its panel orientations read the
camera eye exported by `craftspec.gd`, so the runtime catalogue owns that datum.

`CraftInterior` loads the separate cockpit PackedScene only on entry, attaches
it to the live stage, hides the exterior's window shade, and creates lights at
five authored fixture anchors. A low neutral fill keeps legends readable. The
lights are scoped to the interior layer; exterior suns and bounce lights exclude
that layer because the local renderer does not cast hull shadows. Leaving the
mode or ending the flight removes it and restores the shade. Missing authored assets use a simple shell, seat and
console. The interior camera rides the vessel's double-precision position and
attitude, uses a 1 cm near plane and a 100 km local far plane, and leaves the
orrery's distant-world pass in place.

## Surface finishes

`evapod_materials.py` generates deterministic, tileable normal and roughness maps
for warm enamel, maroon painted fibreglass, satin panel laminate, fine-grain
leatherette, woven harnesses, rubber and brushed aluminium/steel. They are embedded
in the GLBs and retained on lower quality presets. Godot extracts generated PNG
sidecars during import; those are ignored alongside the GLBs. Metalness is deliberately
moderate so the fittings remain readable without environment reflections.

The meshes carry metre-scaled UV coordinates; the optimiser preserves a common
active UV layer and exports tangents for normal-mapped materials. Grain changes
highlight width and small surface relief instead of adding large dirt blotches.
The display faces use original static schematics, not live telemetry or imported
film graphics. Labelled switches are currently visual, while G still drives the
exterior manipulators. Interior drag allows a full turn to inspect the side and
rear equipment.

The cabin window has a smooth maroon fibreglass reveal, replacing the ribbed
exterior surround only while the authored cockpit is loaded. Exit restores the
surround's previous visibility. The acrylic keys have separate pigmented sides,
illuminated faces and satin metal mounting flanges; larger cream and amber keys
separate power and safety functions from the blue manipulator groups. The display
frames have glare lips, and the cylindrical controllers sit on a low supported
apron instead of intersecting their plinths.

The aft lining leaves an opening for the hatch, its recessed handles, latch and
warning plate. Angled storage lids close onto fitted boxes, with hinge barrels
and recessed pulls. These lids and the hatch remain fixed. Painted service
castings and connected hoses sit against the ceiling shell. The `hatch` studio
view hides the seat for inspection; normal cockpit views retain it.

## Verification

- `tools/evapodcheck.gd` headless, with `assets=1` and `assets=0`: 41 intermediate
  arm poses, connected links, independent wrist-position calculation, moving
  skin clearance from the pressure sphere, paired-claw clearance, reproducible
  rest pose, vehicle data immutability, lazy cockpit entry/exit, open window
  sightline and camera datums. Authored checks also verify cabin-facing exterior
  clearance, embedded finish maps, UVs and tangent frames. Short rays in 26
  directions check the turning camera's clearance; hatch sightlines reject
  upholstery covering its controls, and compartment vertices must fit the shell.
- `tools/crafttest.tscn -- audit clearance parity`: all available authored vehicles,
  with unchanged 2 cm height/datum tolerance. Audit and clearance also run with
  `assets=0`.
- `tools/assetcheck.gd`: required pivots and rest transforms in both build paths.
- `eval=_soak_check soak=eva_pod`: repeated launch, camera entry/exit, arm commands
  and teardown through production Spaceflight, with flat post-warmup counts.
- `tools/evapodflightshots.tscn`: a GPU check through the production renderer,
  including fuel use, arm commands, cockpit depth and camera exit; optional
  `dump=/absolute/directory` saves flight views.
- `tools/evapodshots.tscn -- dump=/absolute/directory`: rendered front, quarter,
  side, rear, underside, extended arms, pilot view and isolated cockpit. This
  tool requires a GPU; numeric checks use headless.

`tools/evapodmaterials.tscn -- out=/abs/materials.png` renders six finish samples under one lighting rig.
