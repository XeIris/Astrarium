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
follow those references. Smaller details are simplified; the fixed rear hatch
does not open. Manipulators are visual mechanisms and do not grab objects or
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
(0, 1.34, -0.13) m in that frame.

`CraftInterior` loads the separate cockpit PackedScene only on entry, attaches
it to the live stage, hides the exterior's window shade, and adds lights scoped
to the interior's render layer. Leaving the mode or ending the flight removes
it and restores the shade. Missing authored assets use a simple shell, seat and
console. The interior camera rides the vessel's double-precision position and
attitude, uses a 1 cm near plane and a 100 km local far plane, and leaves the
orrery's distant-world pass in place.

## Verification

- `tools/evapodcheck.gd` headless, with `assets=1` and `assets=0`: 41 intermediate
  arm poses, connected links, independent wrist-position calculation, moving
  skin clearance from the pressure sphere, paired-claw clearance, reproducible rest pose, vehicle data
  immutability, lazy cockpit entry/exit, open window sightline and camera datums.
- `tools/crafttest.tscn -- audit clearance parity`: all ten authored vehicles,
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
