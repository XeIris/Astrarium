# Movie-inspired spacecraft, phases 2–4

Scope: [issue 26](https://github.com/XeIris/Astrarium/issues/26). All models are
original scripted Blender reconstructions. Photographs inform shape and finish;
no downloaded meshes, film graphics, logos or character likenesses become assets.

## Delivery requirements

1. Ranger-inspired winged shuttle: authored exterior, procedural fallback and
   lazy cockpit; orbital entry, glide, gear and ground landing through production
   guidance. Iterate against exterior and cockpit references at several angles.
2. Discovery One-inspired explorer: long spine, spherical command section, drive
   section and docked EVA pod. Record published versus judged proportions and
   estimated nuclear propulsion. Animate its centrifuge; report radius, spin,
   artificial gravity and Coriolis ratio. Model rotor angular momentum or state its
   omission explicitly. Provide an Earth–Jupiter mission with the Galilean moons.
3. Endurance-inspired expedition craft: twelve-module ring and hub, carrying
   Ranger and separate Lander vehicles. Animate spin and expose gravity telemetry.
   Add a production spin-matching scenario with expectation windows. Add a rapidly
   spinning supermassive-hole preset within the verified a*=0.998 limit. Use an
   explicitly labelled kinematic equatorial Kerr orbit and time-dilation formula
   for the demonstration; do not present the orrery's weak-field dynamics as Kerr
   orbital physics.
4. For each: reference comparisons, repeated design passes, moving-part and
   attachment checks, authored/fallback audit/clearance/parity, production renders,
   lifecycle evidence, descriptive commits and branch publication.

Full interiors for the larger ships are issue phase 5 and are outside these three
phases. Their exterior windows and entry points must not obstruct that later work.

## Ranger reconstruction

Four Blender design passes were inspected from front, rear, side, plan and below,
then through the production flight renderer. Overall length 17.9 m and
span 9.7 m are reconstruction choices, not studio CAD measurements. `vehicles.gd`
owns these dimensions, mass, propulsion and camera datums. `RangerCraft.geometry`
exports the same apertured skin to Blender and the procedural fallback. Blender
adds gaskets, blanket seams, radiator ribs, nozzle walls and cabin fittings.

The chemical OMS estimate is two 45 kN engines at 360 s vacuum Isp, 6 t main
propellant and 14.5 t dry mass. Aerodynamics reuse the Shuttle coefficient family
on an estimated 85 m² lifting area. This is an orbit-to-ground shuttle model;
the film's extraordinary single-stage ascent is not represented.

The cockpit loads only on entry. Its up direction is +Z in the stage frame,
separate from the +Y thrust axis; camera yaw uses that cabin vertical. G lowers
three independently hinged wheel assemblies into real belly openings. The seven
trailing control surfaces reuse the guidance's existing command ordering; this
is an estimated control layout. Screens and switches are visual fittings.

The headless return check flew a 250 km orbit through a paid deorbit burn,
atmospheric entry, banking reversals, glide, preflare and rollout. Touchdown was
0.73 m/s sink at 79.1 m/s ground speed, and wheel stop followed after 1.86 km.
Orbit, entry-interface and preflare scenarios also pass played-flight replay.
Development and asset gates cover all eleven authored models (22 parity poses).
The Ranger-specific sweep checks ground contact, attachment, cockpit sightlines,
camera frames, finish maps and repeated entry in both build paths.

Observation sources:

- [Ian Hunter, miniature VFX supervisor interview](https://www.artofvfx.com/interstellar-ian-hunter-miniature-vfx-supervisor-co-founder-new-deal-studios/):
  practical miniature construction, Shuttle heat tiles, quilted insulation and
  familiar aerospace hardware as the material direction.
- [Chris Kieffer, film graphics designer](https://www.chriskieffer.com/work/interstellar):
  practical cockpit photographs, two-seat layout, centre stack, overhead windows,
  graphite instrument cabinets and pale structural framing. Our display graphics
  are newly drawn static schematics, not copied film graphics or live instruments.
- [Exhibited film props, photographed by Hollywood Movie Costumes and Props](https://hollywoodmoviecostumesandprops.blogspot.com/2017/08/tars-robot-and-space-shuttle-models.html):
  long deck, crown glazing, chine fences and thermal blanket boundaries.
- [Moebius kit from several angles](https://thegreatcanadianmodelbuilderswebpage.blogspot.com/2015/08/ranger-from-intersteller.html):
  supplementary rear and planform observation; a model is secondary evidence.

Build with `model_sources/blender/build.sh ranger`. Capture inspection views using
`tools/moviecraftshots.tscn -- v=ranger dump=/absolute/directory`. Numeric geometry
and lifecycle assertions run headless in `tools/rangercheck.gd` with either asset
path. `tools/rangerflightcheck.tscn` flies the production deorbit-to-rollout loop.

Generated reference photos, successive renders and check logs are kept in ignored
`tools/evidence/movie-craft/`. Completion of the full phase 2–4 objective requires
the remaining ships and demonstrations as well as the Ranger.
