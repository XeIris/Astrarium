# AGENTS.md

Guidance for Codex working in this repo. The [README.md](README.md) is the
authoritative description of *what the sim models and why* (physics derivations,
scenario design, disclaimers) — don't duplicate or rewrite it here. This file is
the engineering map: stack, layout, conventions.

## Stack

- **Three.js 0.160.0**, loaded from a CDN through an `importmap` in
  [blackhole_sim.html](blackhole_sim.html). Vanilla ES modules, no bundler.
- **No build step, no package.json, no dependencies, no tests** — for the code.
  Editing a file and reloading the page is the whole dev loop. The ONE exception
  is `assets/*.glb`, the nine authored spacecraft meshes, built offline in
  Blender from the `.py` files in `assets/blender/`. They are build artifacts,
  not checked-in assets: nothing builds them at serve time, `.gitignore` says
  so, and the sim runs without them (see below).
- Most of the visual work is **custom GLSL** in `THREE.ShaderMaterial`s written
  inline as template strings — full-screen passes (lensing, sky, post) plus
  per-body surface shaders.
- Rendering is **HDR**: everything composes into a half-float target and is tone
  mapped once at the end. Emitters are expected to write values well above 1.0.

## Running

Static files; anything that serves the folder works. The bundled server exists
so ES modules load over http and are never cached stale:

```bash
node .claude/serve.mjs
```

Then open http://localhost:8777/blackhole_sim.html. `.claude/launch.json`
registers the same server as the `sim` preview config (port 8777), so
`preview_start {name: "sim"}` is the preferred way to run and verify changes.

The vehicle models are built offline and their meshes are NOT in the repo — the
SCRIPT is the model, `assets/*.glb` is what falls out of it, and `.gitignore`
says so. A fresh clone runs without them (the procedural fallback takes over),
but the ships are not the ships until this has been run once:

```bash
assets/blender/build.sh
```

That builds all nine (~12 MB, half a minute). Name some to build fewer —
`assets/blender/build.sh shuttle lm` — which is the loop worth using while
editing one. `lib.py` holds the primitives and `common.py` the palette, the
optimiser and the exporter; neither is a vehicle, so neither is buildable.

The script hunts for Blender rather than assuming it: it is commonly installed
somewhere off `PATH` — through Steam, on the machine this was written on — so
`which blender` finding nothing means nothing, and `mdfind -name Blender.app` is
the check worth doing before concluding it is missing. Any Blender 4.1+ works;
the build uses sharp-edge shading rather than the `use_auto_smooth` removed in
4.1. Set `BLENDER_OVERRIDE=/path/to/Blender` to force one.

Scenarios deep-link by hash, e.g. `blackhole_sim.html#bhmerger` — handy for
jumping straight to the case you're debugging. Note that a hash-only change does
NOT reload the page, so an edit to a module is not picked up by re-navigating to
a different hash; add a query (`?v=2#edu_kepler`) or reload. Keys `1`–`7` switch imaging band,
`H` hides the UI (useful before screenshots).

The page has a third mode, **Learn** — a thirty-five lesson beginner's astronomy
course over the same simulator. `SIM.lessons.openLesson('lives/giants')` jumps
straight to one, and `.claude/coursecheck.js` walks the whole curriculum; see the
course entries under Conventions.

`window.SIM` is a deliberate console handle, not a leftover: `SIM.state.bodies[0].structure`
is the fastest way to see what the physics thinks a body is, and `SIM.load('vega')` beats
editing the hash. `SIM.flare('Sun')` forces an eruption: flares arrive years apart and
last days, so at any time scale that makes the orbits legible the whole event is over
inside one frame — drop `SIM.state.timeScale` to ~0.002 first, or there is nothing to see. Note that browser-automation tools usually evaluate in an isolated
world where page globals are not visible — inject a `<script>` element to reach it.

## Layout

Shell:

- [blackhole_sim.html](blackhole_sim.html) — page shell, importmap, all HUD panel
  markup. Controls are plain elements looked up by `id`.
- [blackhole_sim.css](blackhole_sim.css) — HUD/panel styling.
- [blackhole_sim.js](blackhole_sim.js) — the only orchestrator (~3.6k lines).
  Holds `state`, the scene/camera/renderer, body spawning and trails, physics
  stepping, camera modes (orbit / free-fly / surface), picking, preset loading,
  every UI binding, the HUD and climate chart, and the render loop.
- [.claude/serve.mjs](.claude/serve.mjs) — dependency-free static server with
  `Cache-Control: no-store`.

`sim/` — each module owns one domain and exports a small surface:

| file | role |
|---|---|
| [sim/physics.js](sim/physics.js) | units & constants (`G`, `C`), N-body velocity-Verlet `integrate`, Paczyński–Wiita term, GW radiation reaction, collisions, `schwarzschild`/radius helpers |
| [sim/presets.js](sim/presets.js) | `PRESETS` / `PRESET_ORDER` — scenario initial conditions in real units, built with `binary()` / `kepler()` helpers |
| [sim/stellar.js](sim/stellar.js) | mass → luminosity / radius / Teff / spectral class / blackbody colour, plus `ActivityModel` (spots, flares, CMEs) |
| [sim/bodies.js](sim/bodies.js) | `createBodyVisual` — dispatches per body type, builds the `THREE.Group` and the `update(dt, ctx)` closure stored on `b.viz` |
| [sim/suns.js](sim/suns.js) | the multi-sun uniform block (`MAX_SUNS`, `SUN_UNIFORMS`, `SUN_GLSL`, `applySuns`) every lit surface declares, and `insolationAt(body, suns)` |
| [sim/terrain.js](sim/terrain.js) | **what a solid surface looks like, and why**: isostasy (the bimodal hypsometric curve), plate tectonics (belts / trenches / ridges from the closing rate), craters, and the surface climate — the P₂ insolation profile, the three overturning cells, and a Whittaker biome diagram. Pure GLSL strings plus `crustThreshold` |
| [sim/rocky_visual.js](sim/rocky_visual.js) | every solid-surface world — Earth, Mars, the Moon, Pluto, anything the Foundry makes. Terrain, volatiles at their own condensation temperature, clouds on the circulation, a Rayleigh atmosphere. Exports the three materials `sim/world.js` also uses |
| [sim/giant_visual.js](sim/giant_visual.js) | gas giants: the zonal jet profile, differential advection of the cloud over a rigidly rotating interior, vortices that ride their own jet, and the ring system's radial optical-depth profile |
| [sim/star_visual.js](sim/star_visual.js) | photosphere / chromosphere / corona / two-ribbon flare / CME rendering |
| [sim/prominence.js](sim/prominence.js) | the eruption itself: a post-flare ARCADE and an erupting flux rope, built as threads on field lines in the vertex shader. Drawn twice — bright in emission off the limb, dark in absorption against the disc, because a prominence and a filament are the same object |
| [sim/neutron_visual.js](sim/neutron_visual.js) | neutron-star surface, self-lensing, polar caps, pulsar beams |
| [sim/world.js](sim/world.js) | the wiring between the climate model and `sim/rocky_visual.js`'s uniforms — nothing else. Re-exports `MAX_SUNS` / `applySuns` from `sim/suns.js` |
| [sim/climate.js](sim/climate.js) | zero-D energy-balance model, `Climate` class and `ERAS` classification |
| [sim/skyview.js](sim/skyview.js) | `SurfaceObserver` (where you stand, planet rotation) + `createSkyPass` multi-sun scattering composite |
| [sim/blackhole.js](sim/blackhole.js) | `createBlackHolePass` — GR null-geodesic ray marcher, shadow/photon ring, volumetric Shakura–Sunyaev disc; `MAX_HOLES = 2` |
| [sim/postfx.js](sim/postfx.js) | `createPostFX` — HDR target, spectral remap, progressive bloom, ACES composite |
| [sim/spectrum.js](sim/spectrum.js) | `BANDS` and the temperature→band-brightness remap shader used by postfx |
| [sim/sky.js](sim/sky.js) | the celestial background: `SKY_GLSL` (procedural stars, galactic band, dust, nebulae, non-thermal populations, all band-aware), `createSkyBackdrop` for scenes with no hole, `SKY_ENVIRONMENTS` / `SKY_PARAMS`, and `blendEnvironments` — several environments at once |
| [sim/scale.js](sim/scale.js) | true-scale rendering: `physicalRadiusAU` mass–radius fallbacks, and `createMarker` — the point-source glow that carries a body once its disc goes sub-pixel |
| [sim/structure.js](sim/structure.js) | **what a body IS**: mass–radius laws per support mechanism, ignition/support limits, rotational shape & gravity darkening, central conditions, and the layer model. `structureOf(spec)` is the single entry point |
| [sim/starcat.js](sim/starcat.js) | `STAR_CATALOG` — measured parameters for ~27 real stars — plus `starSpec` / `starRing` / `realBinary` / `companion` scenario builders |
| [sim/foundry.js](sim/foundry.js) | the Object Foundry editor panel (`createFoundry`), the live-body inspector (`createInspector`) and the in-flight parameter editor (`createLiveEditor`), which share one set of control rows |
| [sim/masscurve.js](sim/masscurve.js) | `createMassCurve` — the log–log mass–radius graph in the live editor. Its threshold marks are *sampled* out of `structureOf`, never listed, so a new limit in `sim/structure.js` appears here on its own |
| [sim/crosssection.js](sim/crosssection.js) | `drawCrossSection` — the labelled interior diagram — plus the temperature ramp and every unit formatter the panels use |
| [sim/painter.js](sim/painter.js) | rings, belts and ejecta: `createOrbitalSwarm` (analytic Keplerian test particles), `createGasCloud`, `ringSpan`, `createPainter` |
| [sim/lessons.js](sim/lessons.js) | **the course** — eight modules, thirty-five lessons, pure DATA with no DOM and no THREE in it. A step's `do` block is a declarative request the UI executes; the header lists the vocabulary |
| [sim/lessonui.js](sim/lessonui.js) | `createLessons` — the course panel, the lesson card, and the executor. The other half of the split: this file is the only one that knows both the curriculum and the page |
| [sim/edupresets.js](sim/edupresets.js) | `EDU_PRESETS` / `EDU_ORDER` — the thirteen teaching scenarios, merged into `PRESETS` by sim/presets.js. Same contract as any other preset |
| [sim/lightcurve.js](sim/lightcurve.js) | the photometer: transit depth integrated against a limb-darkened disc, and the star's radial velocity. The observer is the CAMERA |
| [sim/gwdetector.js](sim/gwdetector.js) | the strain a 4 km interferometer would record from the binary on screen, from the quadrupole formula |
| [sim/hrdiagram.js](sim/hrdiagram.js) | the HR diagram. Main sequence, giant tracks and the white-dwarf line are SAMPLED from `structureOf`, never listed |
| [sim/cutaway.js](sim/cutaway.js) | the interior model as a clipped 3D object, on its own small renderer |

`sim/flight/` — spaceflight. The **only** part of the sim not in AU/M☉/yr; see the
units note under Conventions. `sim/flight/spaceflight.js` is the sole integration
point and the only file here that knows the orrery exists.

| file | role |
|---|---|
| [sim/flight/rocketry.js](sim/flight/rocketry.js) | SI constants, layered atmospheres (`density`/`pressure`/`scaleHeight`), transonic `dragCoefficient`, Sutton–Graves `heatFlux`, `engineOutput` incl. solid-motor thrust profiles, `flightEnv(body)` |
| [sim/flight/vehicles.js](sim/flight/vehicles.js) | `ENGINES` and `VEHICLES` — published masses, thrusts and Isp; `stageDeltaV`/`totalDeltaV`/`padTWR` derive, never store |
| [sim/flight/orbit.js](sim/flight/orbit.js) | universal-variable (Stumpff) `propagate`, classical `elements`, `hohmann`, `sphereOfInfluence`. Reference pole is **−Y**, matching the orrery's own orbital sense |
| [sim/flight/vessel.js](sim/flight/vessel.js) | the `Vessel`: RK4 in a parent-centred non-inertial frame, staging, engine shutdown/relight, attitude with real gimbal + RCS authority, structural limits, SOI handover, proper-time clocks |
| [sim/flight/guidance.js](sim/flight/guidance.js) | the `Autopilot`: ascent, orbital insertion, node execution, transfers, Apollo P63/P64/P66, hoverslam, Mars EDL. One shared `descentLaw` and one shared `limitThrottle` |
| [sim/flight/relativity.js](sim/flight/relativity.js) | exact constant-proper-acceleration `Cruise`, `solveProfile` (flip-and-burn vs accelerate–coast–decelerate), `skyBoost` |
| [sim/flight/craftmodel.js](sim/flight/craftmodel.js) | procedural spacecraft at real dimensions; per-stage groups so separations are re-parents, with legs, grid fins, fairing halves, arrays and gimbals that move |
| [sim/flight/craftassets.js](sim/flight/craftassets.js) | the authored-model cache: loads one vehicle's `assets/<id>.glb` through `GLTFLoader`, splits it into per-stage subtrees, binds their moving parts by name, and lets `buildCraft` stay synchronous. Falls back silently |
| [assets/blender/](assets/blender/) | the Blender builds — one `.py` per vehicle, and the script IS the model, nothing is clicked. `lib.py` holds the primitives (lathe, loft, wing, sphere-cone, bevel), `common.py` the palette, the join-by-material optimiser and the glTF export, `build.sh` finds Blender and runs them |
| [sim/flight/plume.js](sim/flight/plume.js) | exhaust (shape from ambient pressure, shock diamonds when over-expanded), RCS puffs, re-entry plasma, launch smoke |
| [sim/flight/localview.js](sim/flight/localview.js) | **local space**: the metre-scale scene, curved ground patch, altitude-driven atmosphere, and the flight cameras |
| [sim/flight/launchsite.js](sim/flight/launchsite.js) | the launch complex at real dimensions — hardstand, flame trench, mobile launcher, umbilical tower with swing arms, strongback, chopsticks, lightning masts, deluge |
| [sim/flight/modelviewer.js](sim/flight/modelviewer.js) | the studio: a turntable, a three-point rig carried on the camera, a 1.75 m figure for scale, and an exploded view |
| [sim/flight/flightui.js](sim/flight/flightui.js) | the navball (a true orthographic projection of a sphere in the surface frame), telemetry, stage stack, two clocks, transfer plan |
| [sim/flight/spaceflight.js](sim/flight/spaceflight.js) | integration: owns the vessel, drives the local pass, slaves the orrery camera, and takes over `state.timeScale` |

## Conventions

- **Astronomical units everywhere in physics**: AU, M☉, years — so `G = 4π²`
  exactly. Never introduce a scaling fudge into `sim/physics.js`; rendering
  exaggeration belongs in `sceneScale` / `bodyScale` on the preset.
- **`sim/flight/` is the one exception, and it is a hard boundary.** A rocket is
  a metres-and-seconds object: an ascent lasts 500 s (1.6e-5 yr) and reaches
  200 km (1.3e-6 AU), so expressing it in AU/M☉/yr throws away most of a float's
  mantissa before the first step. The bridge is exact rather than fitted —
  `GM☉ = 1.32712440018e20 m³/s²` **is** `G = 4π² AU³/M☉/yr²`, re-expressed — and
  it is crossed in exactly one place, `sim/flight/vessel.js`. Do not let SI leak
  outward or AU leak inward.
- **Spaceflight draws in a SECOND pass with its own camera**, in metres. At AU
  scale a 100 m rocket is 7e-10 scene units and the near plane, the depth buffer
  and float32 vertex precision all fail at once; it is eleven orders of
  magnitude and no single projection covers it. `sim/flight/localview.js` owns
  that pass and the orrery's camera is slaved to it — the two never need to see
  each other, because from a hundred metres the universe is background and from
  a hundred kilometres the vehicle is a point.
- **A guidance law is a closed loop on the vehicle's own state**, never a stored
  trajectory. The test of a new one is that a heavier vehicle flies differently
  and an incapable one fails honestly. In particular: never gate a manoeuvre on
  catching a narrow window (it will be missed), never size an ignition on the
  full available deceleration (there is no margin left for the lag), and never
  let a discrete choice — how many engines are lit — appear inside a continuous
  predicate, or the burn will stutter on and off every frame.
- **Scene units ≠ AU.** `state.sceneScale` converts. Physical radii used for
  collisions live on the body in AU; rendered radii are in scene units.
- **Exaggerated size is a constant MAGNIFICATION, not a constant size.** `baseRadius`
  scales each type's boosted radius by how far the body's real radius departs from
  that type's radius at its default mass (`referenceRadiusAU`). Normalising at the
  default is what keeps every existing preset pixel-identical while letting the mass
  slider do something — before this, every rocky planet was drawn at exactly 0.15
  scene units whatever its mass, so the whole degeneracy turnover was invisible.
- **A body's physical radius comes from `structureOf`** unless the spec carries a
  measured `radiusKm`. The old `physicalRadiusAU` fallback was a plain M^0.27 and
  never turned over, so a 300 M⊕ planet was drawn 4.7 R⊕ across even at true scale.
- **Rendered size goes through `renderRadius`**, never `baseRadius` directly.
  Black holes are always their true horizon; everything else is the real radius
  when `state.trueScale` is on and the exaggerated stand-in otherwise. A body's
  visual bakes its radius into geometry and local offsets, so changing the size
  convention at runtime means `rebuildVisuals()` — the physics body survives, the
  meshes do not. `b.spec` is kept for exactly that.
- **A true-scale body is usually sub-pixel**, and is carried by the point-source
  marker in `sim/scale.js` rather than by any mesh. Anything that reasons about a
  body's on-screen presence — picking, the near plane, the follow camera — has to
  hold up when its rendered radius is 1e-5 scene units. `state.trueScale` is a
  standing regression case for this: fly to Earth in the `solar` preset and it
  should resolve into a sphere, not clip, jitter, or slide out of frame.
- **A body's vertex shader never forms an absolute world position.** Write
  `projectionMatrix * modelViewMatrix * vec4(p, 1.0)`, not
  `projectionMatrix * viewMatrix * modelMatrix * vec4(p, 1.0)`: the second one
  materialises a world coordinate in float32, and 35 scene units out (the
  `stellar_zoo` ring) that quantises to 4e-6 — coarser than Sirius B's true-scale
  radius of 2e-5, so the sphere renders as a lump of cubes. `modelViewMatrix` is
  assembled on the CPU in float64 and carries the CAMERA-relative offset, which is
  tiny whenever you are close enough to see the body. For the same reason the view
  vector is not `cameraPosition - vWP` (a 1e-4 difference between two numbers of
  magnitude 35, i.e. all cancellation error): shaders that need it in world space
  rotate the view-space offset back with the transpose of `mat3(viewMatrix)`.
  Directions — normals, sun vectors — are unaffected and may still use `modelMatrix`.
- **Body visuals follow one contract**: a factory returns `{ group, update(dt, ctx) }`
  attached as `b.viz`, with `ctx = { holes, camera, time, sceneScale }`.
- **A stage's `L` is its WHOLE length, nose included.** A nose cone eats into the
  barrel rather than being stacked on top of it; adding it above `L` made every
  stage that has one longer than the number the physics integrates — 8 m of it on
  the Shuttle tank alone, which is how the stack came out 68 m instead of 56.
- **Not every stage stacks.** `look.mount = { x, y, z }` mounts a stage on the
  core instead of on the nose of the one below, and a mounted stage does not
  advance the stack height. The Shuttle is the case that forced it: the orbiter
  is bolted to the SIDE of the tank, and stacking it put 37 m of spacecraft in
  the wrong place — no amount of surface detail survives that. Because mounts
  exist, the stack's height is a MEASURED extent (a `Box3` over the built root),
  not a running sum of stage lengths.
- **y = 0 on a craft is the PAD SURFACE — or, for a lander, the FOOTPAD
  PLANE.** `spaceflight.js` adds `craft.group`
  straight to `local.craftRoot` with no vertical offset, so the datum has to be
  whatever the vehicle stands on — for the Shuttle that is the solids' nozzle
  exit, not the tank's aft dome, which is 9.2 m higher. Get it wrong and the
  boosters are under the concrete. The LM is the case that was wrong: its gear
  hung off a box whose underside was the origin, so the footpads finished 1.5 m
  below the surface it had just landed on and the descent engine was buried in
  it. `LM_GEAR` is the stand-off, and the ascent stage carries the same offset
  internally so buildCraft's stacking still lands it on the descent stage's roof.
- **An interstage ADAPTS.** It is drawn from the stage's own diameter to the next
  one's (`ctx.nextD`), because the Saturn V's go 10.06 m → 6.6 m → 3.9 m. Drawn
  as a cylinder the whole vehicle is one width from the engines to the escape
  tower, which is the single thing a Saturn V most obviously is not.
- **Anything in `parts.gimbals` must have IDENTITY as its neutral pose.**
  `update()` drives those groups by *assigning* Euler angles, and assigning a
  rotation wipes whatever orientation was set when the part was built. So a
  thruster that is mounted at an angle needs TWO groups: an outer mount carrying
  the fixed orientation, and an inner pivot — the one registered — that the
  guidance moves. Both the sky crane's engine cant and the Hail Mary's spin
  drives were being snapped back to vertical on the first frame for want of it,
  and it is invisible until something is mounted off-axis.
- **A pivot declares how far it may swing, and `update()` clamps to it.**
  `parts.gimbals` is where the PLUMES hang as well as where the deflection is
  applied, so a rigid engine still has to be registered there — which meant an
  engine that cannot gimbal was drawn gimballing. The authority belongs on the
  pivot (`userData.gimbalDeg`) rather than on the stage, because a cluster is
  not all one engine: Starship's three vacuum Raptors are fixed and sit in the
  same list as its three that steer. A pivot that declares nothing is left
  unclamped, so a hand-built drive keeps whatever freedom it had. The Hail
  Mary's four spin drives are the case that forced it — rigid, and visibly
  canted a few degrees and waggling once a second until the clamp existed.
- **Every vehicle is AUTHORED, and every vehicle still has a procedural
  build.** Both halves matter. The reason to author is that a lathe cannot
  BEVEL AN EDGE: a perfectly sharp edge catches no specular highlight at all,
  which is why hard surface assembled from `CylinderGeometry` reads as cardboard
  however right its silhouette is, and there is no bevel modifier at runtime.
  Nor can it cut a recessed panel line — `CylinderGeometry` takes ONE radius, so
  a joint between barrel sections can only be a ring strapped round the outside,
  where the Blender build dips the radius and cuts a groove. And some shapes are
  not bodies of revolution at all: an orbiter's width and height vary
  independently over a rounded-square section, which is `loft`, and its planform
  has a kink, which is `wing`.
  The reason to keep the procedural build is that the meshes are BUILD ARTIFACTS
  and are not in the repo. A fresh clone has none of them.
- **A missing asset is not an error.** `buildStage` falls back to the procedural
  build if the .glb has not loaded, 404s, or the CDN serving `GLTFLoader` is
  unreachable — one `console.warn` per vehicle and the sim runs. The fallback is
  kept WORKING rather than left to rot: a vehicle that cannot be drawn without a
  network round trip is a vehicle that cannot be drawn. The standing check is to
  move `assets/*.glb` aside and re-run `STUDIO.audit()`; the heights must still
  match (they agree within a few tenths of a metre) and only the triangle counts
  should move. `buildCraft` also stays SYNCHRONOUS — four call sites depend on it
  returning a finished vehicle, one of them `audit()` — so assets are preloaded
  into a cache and the builder reads the cache. Anything that builds a craft has
  to fill it first (`craftModelsReady(id)`) or it silently measures the fallback
  and reports that as the regression number.
- **Load ONE vehicle, not nine.** The set is ~12 MB and the Hail Mary alone is
  two thirds of it, so nothing is fetched at boot: `preloadCraft(id)` gets
  exactly one, `launchCraft` awaits the one it is about to fly, and the craft
  buttons warm on `pointerenter` — pointing at a button is a reliable signal
  that it is about to be pressed, which turns the fetch into one that has
  already happened. Only the studios (`crafttest`/`craftsheet`) load all nine,
  because `audit()` builds all nine.
- **The moving parts are bound BY NAME, and the names are an INTERFACE.**
  `assets/blender/common.py` writes them, `craftassets.js` matches them, and
  nothing checks that the two agree — rename a node in a `.py` and the legs stop
  deploying, silently, with no error anywhere. One `stage_<key>` empty per
  stage, then `gimbal_`/`leg_`/`fin_`/`array_`/`flap_`/`half_` for what update()
  drives, each scoped by stage key (`gimbal_sic_3`) because Blender object names
  are unique SCENE-WIDE and two stages both wanting `gimbal_0` would silently
  get `gimbal_0` and `gimbal_0.001`. The match is anchored and digit-terminated
  for the same reason: a helper empty called `gimbal_beetle_0_mount` must not be
  collected as a second pivot. Pivots carry identity rotation and sit ON THE
  EXIT PLANE, because spaceflight.js parents the plume straight to them.
- **A DRIVEN NODE CARRIES IDENTITY ROTATION; its azimuth goes on a mount.**
  `update()` deploys a leg, a fin or a flap by assigning Three's `rotation.z` —
  into an Euler triple Three decomposed from the quaternion glTF actually
  stores, because glTF has no Eulers. For a node whose only rotation is about
  Blender Z that decomposition comes back as `(0, azimuth, 0)` and the
  assignment means what it looks like. Past ninety degrees it does not: the XYZ
  solver returns the equally valid `(π, π − azimuth, π)`, the assignment
  overwrites a z term that was carrying half the rotation, and the part swings
  somewhere arbitrary. On the Apollo gear that was exactly one leg of four —
  the one at 180° — deploying UPWARD through the ascent stage while its three
  neighbours came down correctly, which looks like a modelling slip and is a
  frame bug. `common.py`'s `hinge()` is the fix: the mount takes the azimuth,
  the driven node stays at identity. Same rule as the gimbal pivots, one level
  up, and for the same reason — the parent owns the pose the child cannot keep.
- **A deployable is built STOWED, and the pre-cant is derived, not guessed.**
  `update()` gives a leg +1.15 rad and a fin +1.35 about the node's own Blender
  Y, and about that axis a POSITIVE angle swings a part built along −Z *inward*,
  under the vehicle. So a leg with no pre-cant does not splay when it deploys —
  it folds in and tucks under the engines, which is what every leg in the set
  was doing, in both builds. Write down where the part has to END (60° out for a
  Falcon leg; square to the body for a grid fin), subtract the travel, and that
  is the built pose. Where the travel cannot reach both poses honestly, the part
  is not a deployable: the LM's gear came out in lunar orbit days before the
  descent, so it is named `gear_` rather than `leg_`, does not match, and is
  never collected. Opting out of an interface is done by not matching it.
- **An engine ring's radius comes from the ENGINE, not from a fraction of the
  vehicle — and the test is the NEAREST NEIGHBOUR over the whole cluster.** A
  bell on a ring of n gets `2 r sin(π/n)` of chord and needs all of it; one with
  a centre engine has to clear that too; and in a multi-ring pattern the closest
  pair is usually a pair on DIFFERENT rings, which no per-ring check ever looks
  at. Solving the rings one at a time passed every chord on Super Heavy and
  still left the inner three 0.87 m from engines that needed 1.07. So the
  three-ring radii are fixed multiples of the exit diameter (0.90 / 2.05 / 3.45,
  every pair ≥ 1.079 diameters apart, outer edge at 3.95) and two clusters that
  cannot see each other — Starship's vacuum Raptors over its sea-level ones —
  are staggered as well as spaced. `STUDIO.clearance()` is the standing check
  and reports the minimum gap per stage; negative is an interpenetration.
  Solving it rather than dialling it also gets the real numbers for free: four
  3.53 m F-1s land on a 3.8 m ring, which is where they are and why an S-IC's
  bells hang outside the line of the tank above them. Where the packing
  genuinely does not close — twenty 1.3 m bells want a 4.16 m ring inside a
  4.5 m booster — the DRAWN bell shrinks. A bell a fifth of a metre narrow is
  the smaller error, and the only one of the two you cannot see.
- **A vehicle is ONE OBJECT, and the joins are load-bearing on that.** Parts
  written at independently chosen heights do not meet: the Hail Mary's docking
  node sat three quarters of a metre above the instrument module's roof and the
  mast another metre above that, so the top of the ship was a sphere and a rod
  flying in company. Position a part against what it bolts to — `nodeY + nodeR`,
  not another round fraction of the length — and overlap the joint rather than
  butting it.
- **Which way a dish points is the whole of what a dish is for**, and its
  structure lives BEHIND the reflector. A paraboloid radiates along its own +Z;
  rotate that axis into the hull it is bolted to and the spacecraft is aiming
  its only transmitter at its own tank. Ribs and backing shell at the same z as
  the surface are not backing anything either — they are spars across the
  aperture. Both were true of three of the four dishes in the set.
- **A lathed part that is not on the axis has to be MOVED there**, and a dome's
  rim goes on the barrel. The Hail Mary's tank heads were written full-radius at
  full height, which is a concave funnel whose rim floats a tank radius clear of
  the skin, and were left revolved about the ship's centreline instead of the
  tank's. Two errors that hid each other, and three open pressure vessels.
- **A pivot that cannot swing is suffixed `_fixed`.** That is how per-engine
  authority survives the trip through glTF, which carries no custom properties
  here: `bindParts` gives every other pivot the engine's published gimbal and
  gives those zero. It is not a detail — twenty of Super Heavy's thirty-three
  Raptors are bolted down, three of Starship's six are, and so is the centre
  F-1 on an S-IC. Without it they are all drawn steering.
- **Meshes are joined by material WITHIN each node before export.** Six hundred
  objects is six hundred DRAW CALLS a frame for a body that never moves relative
  to itself, and this is drawn in a second pass over a whole orrery — the Hail
  Mary went 612 → 34. The node boundary is what keeps it honest: joining across
  one would weld the Falcon's legs to its tank and the deploy would move
  nothing. Bevels are baked in the same pass, because once meshes are joined
  there is no per-object modifier stack left for the exporter to apply.
- **Blender is Z-up and the vehicle's UP is Blender −Y.** The exporter converts
  to the Y-up Three wants, so Blender +Z is the stack axis and Blender +Y is
  Three's −Z. Every sign error in `assets/blender/` is that one. `loft` and
  `wing` therefore take their vertical terms as UP-POSITIVE and negate
  internally, so a section table moves from `craftmodel.js` to a `.py` file
  without touching a sign — get it wrong and the Shuttle flies inverted with its
  tiles facing the sky.
- **The Hail Mary's four drives fire through ONE PLANE, parallel to the axis.**
  A drive canted by θ throws away 1 − cos θ of its thrust and puts the rest
  into a torque that has to be held out with propellant for thirteen years, so
  the tanks bend in around the spine — that is the shape of the ship — but each
  drive hangs SQUARE underneath the bend on its own thrust block, and the fourth
  is on the centreline. `count` in `sim/flight/vehicles.js` is the model's count
  on purpose: a vehicle whose engines you can see and whose thrust you integrate
  must not disagree about how many there are.
- **A stage builder must not write to its own group's transform.** `buildCraft`
  assigns `group.position` when it places the stage, so an offset set inside the
  builder is silently overwritten a moment later. Put it on an inner group. This
  is the same trap as the gimbal one above, one level up: in both cases the
  parent owns that property and the child's value does not survive.
- **An emitter has to be lit by itself, and BRIGHTLY.** A drive face points aft,
  away from every light in the scene, so it renders black however it is coloured.
  An emissive of 0x2a0d06 is 0.023 in linear light and ACES puts it back at
  almost nothing — emitters need values scaled for an HDR pipeline, not values
  that look right as hex.
- **`parts.arrays` means DEPLOYABLE.** `update()` holds everything in that list
  folded until the flight state asks for it, so fixed structure — the Hail Mary's
  radiators — must not go in it, or the ship flies with its heat rejection stowed.
- **Craft materials are DOUBLE-SIDED and LOW-METALNESS, both on purpose.** Most
  of the vehicle set is open shells — lathed nozzles, aft skirts, interstages,
  an aeroshell backshell — and a single-sided shell has no inner wall, so you
  look into an engine bell and see sky. Separately, nothing in this renderer sets
  `scene.environment`: local space is lit by punctual lights only, and a PBR
  metal is *entirely* reflection with no diffuse term, so at metalness 0.8 it
  renders BLACK. That is what made the sky crane's deck and Curiosity's chassis
  dark blobs. Until there is an environment to sample, the base colour carries
  the material.
- **`engineOn` means the bells belong to ANOTHER stage.** The Shuttle's SSMEs are
  on the orbiter and fed from the tank; the stage that owns the propellant must
  not draw them too, or the stack flies with six main engines, three of them
  bolted to a tank it throws away.
- **A stage that carries a nose or an interstage needs a FLAT tank top.** The
  lathe's dome curves away underneath whatever sits on it and leaves a pinched
  gap at every joint — which is what read as odd spacing up the Saturn V.
- **A stowed array folds to 90°, not "mostly".** At 1.35 rad the Falcon 9's
  payload still spanned 5.8 m inside a 5.2 m fairing and speared through it.
- **Not everything is a body of revolution.** `loft()` takes cross-sections with
  independent half-width, half-height and a superellipse exponent, and its
  `t0`/`t1` sweep lets the upper and lower shells carry different materials —
  which is the whole point for a vehicle that is white on top and black
  underneath. `wingPanel()` takes spanwise stations, so a kinked planform (the
  orbiter's double delta) is just a station at the kink. Approximating either
  with a cylinder and a slab is not a coarse model of the shape, it is a
  different object.
- **A planet's appearance is a CONSEQUENCE, not a setting.** A body works out its
  own insolation from wherever it currently is and whatever stars are lighting it
  (`insolationAt`), turns that into a surface temperature, and the ice line, the
  desert belts and the biomes follow. Edit a planet's orbit in flight and its caps
  move. So a new planet parameter belongs in the derivation if it can be derived,
  and only in the preset if it genuinely cannot — Venus's 737 K is stated because
  no emissivity reaches it; Mercury's 433 K is not stated anywhere.
- **What a cap is made of is ONE uniform.** `uFrostK` is the condensation
  temperature of the body's dominant volatile: 273 K is water, 148 K is Mars's CO₂,
  37 K is Pluto's nitrogen. Adding a kind of frost means adding a temperature, not
  a code path. Likewise `uCrater` — whether anything erases impacts — is what
  separates the Moon from the Earth, not a separate shader.
- **Land fraction goes through the inverse normal CDF, not through a bias.**
  Seven octaves of value noise are very nearly Gaussian (measured: mean 0.4970,
  sd 0.1065), so the sea-level threshold for 29% land is `crustThreshold(0.29)`.
  Subtracting `1 - land` instead — the obvious thing — gives a third of the land
  asked for, and it is not obvious from the picture that anything is wrong.
- **Albedos are ALBEDOS.** Closed-canopy forest is 0.12 and sand is 0.38, and it is
  that ratio that makes a continent read as a continent. Colours chosen by eye come
  out all the same brightness, which is the most reliable way to make a rendered
  planet look painted. The one display convention is `uGain` (a single exposure
  constant, because a camera exposes for the planet), and it is shared by every
  body so two worlds side by side stay comparable.
- **ADVECTED NOISE MUST BE FLOW-MAPPED.** A gas giant's cloud is carried by a wind
  that depends on latitude, so the longitude offset between two adjacent latitudes
  grows WITHOUT BOUND: sample a frozen noise field at that offset and after a
  minute the field's latitudinal frequency is finer than a pixel and the planet
  dissolves into a moire of horizontal stripes that swims with the camera. A real
  atmosphere escapes this because its eddies are regenerated, not stretched for
  ever. So the field is regenerated too — two copies advected on clocks half a
  period out of step, cross-faded so each one's weight is ZERO at the moment its
  own clock wraps (`w = 1 - |2t/T - 1|`, not `|2t/T - 1|`, or the reset pops). The
  period bounds the shear and therefore the frequency; it is 16 s on a giant and
  20 s on a cloud deck because the jets are a fifth of a radian apart. Same device
  in `sim/giant_visual.js` and in `cloudMaterial`, same reason.
- **Procedural detail finer than a pixel is not detail, it is aliasing** — and on a
  banded planet it aliases into the very thing the bands are made of. There is no
  mip chain on any of this, so octave counts and frequencies are chosen against the
  screen, not against the noise. Anything that "adds more detail" to a giant has to
  be looked at while the sim is running, not paused: the shear is what exposes it.
- **A gas giant's core and its atmosphere are different objects.** The mesh's own
  rotation is System III, the rigid interior rate; everything visible moves over it.
  Nothing about the cloud may be baked into the mesh transform, or the two become
  one object again and the planet reads as solid.
- **Sea level is a LEVEL.** `uSeaKm` is the height of the datum, not an offset
  applied to the ground: a dry world says sea level is 60 km down, and subtracting
  that from the terrain is the same arithmetic but a different physical claim — the
  lapse rate then reads it as 60 km of altitude and takes 390 K off the surface,
  which froze Mars solid under CO₂ at an equilibrium temperature of 213 K.
- **The annual mean cannot grow a winter cap.** Mars's cap is CO₂ at 148 K and its
  annual-mean polar temperature is nowhere near that. `uDecl` is the sine of the
  sub-solar latitude — geometry the orrery is already integrating — and `uSeason`
  is how far the surface follows it: small under an ocean, large on bare rock.
- **AN ERUPTION IS AN ARCADE, NOT AN ARCH — AND PLASMA LIVES ON FIELD LINES.**
  Coronal beta is far below one, so gas cannot cross the field, only slide along
  it: what is visible is a bundle of separate THREADS, and one tube can never
  have that texture. Reconnection also runs along a neutral line and climbs, so
  the loops come in a row anchored in two ribbons that draw apart. Both of those
  are in [sim/prominence.js](sim/prominence.js), and the arcade's LENGTH along
  the neutral line has to be several times a single loop's span or the loops
  pile up into a ball of wool — which was the first thing that went wrong when
  the single tube was replaced.
- **The shear IS the energy.** A potential arcade is square across its neutral
  line and stores nothing; the free energy a flare releases is the energy of the
  skew. So the erupting rope is strongly sheared and winds down toward square as
  the event proceeds, and the post-flare arcade under it is already relaxed.
  Drawing loops perpendicular to the neutral line draws a field with nothing to
  release.
- **A prominence and a filament are ONE OBJECT.** The same cool material is
  bright against the sky off the limb and dark in absorption against the
  photosphere. So the arcade geometry is drawn twice from one buffer, with
  different blend modes, each pass discarding where the other applies; the test
  is whether the point projects inside the disc, done in view space against the
  star's centre. Adding a "prominence" that only emits gets the limb right and
  the disc wrong.
- **Geometry that is entirely in the vertex shader is geometry you can share.**
  The arcade buffer carries no shape at all — only thread index, arc parameter
  and a side flag — so ONE buffer serves every arcade on every star, and an
  eruption rises, stretches, shears and splays without a byte being rewritten.
  It is deliberately never disposed; it outlives any one star.
- **A thin shell is brightest where you look ALONG it.** Shade a CME shell like
  an ordinary surface and it renders as a hard-edged crescent; weight it by the
  path length through the shell — long at the rim, short face-on — and the same
  geometry becomes the arc-with-legs a CME actually is. Its three parts (swept-up
  front, evacuated cavity, prominence core) are two additive shells with a gap,
  and the gap is the cavity, so nothing has to darken anything.
- **Flare plasma publishes 10⁷ K, and that needs the alpha channel REPLACED.**
  Alpha here is not opacity, it is the temperature channel
  [sim/spectrum.js](sim/spectrum.js) images the frame from, so an additively
  blended emitter must use `CustomBlending` with `blendDstAlpha = ZeroFactor`:
  summed onto the photosphere's own published value it saturates to 1.0, which
  means "no data" and silently drops both back to guessing a temperature from
  colour. Absorption passes do the opposite and leave alpha alone. This is what
  makes an eruption the brightest thing on a star in the X-ray band while the
  3000 K photosphere under it is a black silhouette — the standing check is
  `#alphacen`, Proxima, a forced flare, band 6.
- **Active regions are not oriented at random** (Joy's law): a bipole lies
  nearly east-west with a tilt of roughly half the latitude, leading polarity
  equatorward. The whole eruption is built on that axis, so every arcade in a
  hemisphere leans the same way — which is a thing you can see, and a thing that
  looks wrong the moment it is random.
- **`sim/structure.js` is the single source of truth for what a body is.** Radius,
  shape, temperature map, interior layers and the stability verdict all come from
  `structureOf()`, and every consumer — the star shader's oblateness, the cross-section,
  the Foundry, the runtime collapse checks — reads `b.structure`. It has to be refreshed
  (`refreshStructure(b)`) whenever mass or spin changes, which accretion does
  continuously. Do NOT add a second place that decides whether something is a brown
  dwarf; add the threshold there.
- **Building a body and editing one are the same operation.** Both end in
  `deriveBody()` re-reading a spec; they differ only in what is preserved. The live
  editor in the cross-section panel patches `b.spec`, re-derives, rebuilds the meshes
  and then calls `checkStructuralLimits`, so every threshold is reachable in flight.
  Anything new that a spec implies belongs in `deriveBody`, not in `spawnBody`, or it
  will exist on spawn and quietly vanish on the first edit.
- **A rebuilt body eases into its new size.** `editBody` starts the mesh at the size
  it had (`b.sizeEase`, applied per frame by `applySizeEase`) and asks the follow
  camera to glide (`cam.radiusTo`, eased by `easeCamRadius`) instead of snapping.
  Both are geometric, because radius and viewing distance are scales. Anything that
  repositions the camera deliberately must go through `jumpCamRadius`, or an
  in-flight glide will drag the view back a frame later.
- **A structural limit is an event, not a label.** If the model says a body cannot hold
  itself up, `checkStructuralLimits()` in the orchestrator has to act on it — a neutron
  star past the TOV mass becomes a black hole, a white dwarf at the Chandrasekhar mass
  detonates. A verdict the sim only prints is a bug.
- **Measured beats modelled.** A spec carrying `radiusSun` / `teff` / `luminosity` (i.e.
  anything from `sim/starcat.js`) overrides the evolutionary track, because the track
  returns 244 R☉ for a 16.5 M☉ supergiant and Betelgeuse is 764. The track is for
  filling in what was not measured.
- **Emitters publish their true temperature** (log-encoded) into the alpha of
  the HDR buffer so `sim/spectrum.js` can re-image them in non-visible bands. A
  new emitter that doesn't publish it will fall back to inferring T from colour
  and will behave wrong in X-ray/radio bands.
- **The sky is the exception to that**, and deliberately so. Alpha `SKY_ALPHA`
  (0.995) means "already imaged in this band, pass through untouched". The
  celestial background cannot go through a Planck ratio at all, because most of
  what dominates the sky outside the visible is non-thermal — synchrotron, 21 cm
  and CO lines, π⁰-decay gammas, the CMB — so `sim/sky.js` composites it at the
  band's own frequency instead. Adding a sky component means adding a row to the
  `W` band-weight table there, not giving it a temperature.
- **Sky environments are POPULATIONS, not paint, so they ADD.** `env` takes
  several at once (`['globular', 'disc']`, or a weight map) and
  `blendEnvironments` sums the amplitudes — star density, glow, bulge, dust,
  H II, reflection, external galaxies — because independent populations along
  one line of sight superpose: standing in a globular you see the cluster's own
  stars AND the galaxy through them. The SHAPE terms are the exception and take
  the weighted mean, because there is exactly one galactic plane you are inside
  and therefore exactly one scale height, one plane concentration, one bulge
  size. Summing those is the error worth naming: disc + core at full weight
  gives a band 0.23 rad thick, which is not a galaxy seen from anywhere. The
  split is declared per-parameter on `SKY_PARAMS` (`add: true|false`), which is
  also the list the settings panel builds itself from — add a component there
  and a control appears on its own.
- **Nothing about the sky may depend on a fixed angular resolution.** Lensing
  magnification near the photon ring is unbounded, so any map, mipmap or baked
  texture fails there at any resolution. Stars are analytic and filtered through
  the screen-space Jacobian; that is what makes them stay point-like and
  brighten by μ instead of smearing. `#bhmerger` is the standing regression case
  — the lensed arcs above the holes must be strings of crisp points.
- **A transparent object is drawn after every opaque one**, whatever its
  `renderOrder` — three sorts within the opaque and transparent lists, not
  across them. A sky dome given `renderOrder = -10` and `depthTest: false` on
  the reasoning that it should be "behind everything" is therefore drawn LAST,
  over the top of the vehicle, at whatever alpha it computes. That is what made
  a launch look washed out and see-through. A background either depth-tests
  against the scene or is drawn in its own pass before it.
- **Local space is lit for a Lambert BRDF.** The vehicle is a
  `MeshStandardMaterial`, whose diffuse term is albedo/π times the irradiance,
  so anything hand-shaded next to it — the ground patch — has to carry the same
  1/π or it comes out π times brighter than the rocket standing on it and the
  tone curve's shoulder flattens it to a glare.
- **A point fixed to a rotating body is carried by ω × r, not by a rotation
  matrix written out again.** The pole is −Y, so the small-angle form of
  `x' = x cos w − z sin w` agrees with `ω × r` only for `w = +Ω dt`; written
  with the intuitive minus sign the point goes round BACKWARDS and separates
  from the vehicle standing on it at twice the surface speed — 816 m/s at a
  28.5° pad, which pulled the pad view out to a kilometre in the first second
  of a launch. `placeOnPad` already contains the one true expression; both the
  launch pad and the landing site derive from it.
- **A launch needs something of known size next to it.** The tower in
  `sim/flight/launchsite.js` is not decoration: it is the only object in frame
  whose height the eye knows, and without it a vehicle climbing over a smooth
  plain reads as stationary and then as teleported. The same goes for the
  terminal count — a launch has to have a beginning you can watch.
- **Following a moving body is exact tracking plus a decaying offset**, never a
  fractional catch-up. `target.lerp(bodyPos, k)` is a first-order lag, and a
  first-order lag driven by a ramp keeps a steady-state error proportional to
  the body's speed — that is the rubber-banding, and no k below 1 removes it.
  See `trackFollow` / `glideTargetTo` in [blackhole_sim.js](blackhole_sim.js).
- **The left column is a measured CHAIN, and Settings is its head.** Top left is
  the settings panel (`#settingsPanel`), then the scenario list, then flight and
  the cross-section; each one's top is `layoutLeftColumn()` measuring the
  previous panel's BOTTOM, never a constant. `--col-top` is the ceiling under
  the mode switch, `--tab-top` the top of the tab stack, `--scenario-top` the
  scenario list's own top, and every var falls back to the one above it so a
  collapsed panel closes the gap rather than leaving a hole. **The tab stack is
  part of the chain, not a fixed point in it**: a tab is a panel's placeholder
  and belongs where that panel would have been. Pinned to `--col-top` it shares
  a y with the settings panel, and collapsing the scenario list drew its tab on
  top of an open Settings. The four states — each panel open or collapsed — are
  the standing check, and none of them may overlap. The panel holds what OUTLIVES a scenario — how the sky is
  composed, what the renderer spends its frame on, and the integrator's step cap
  — as against the control column on the right, which is about the thing you are
  currently looking at. Render scale and lens detail live here for that reason.
- **The step cap is the one setting that changes the ANSWER.** Everything else
  in the settings panel changes the picture. So the sim page reports what the
  integrator is actually doing — sub-steps per frame and relative energy drift
  since the scenario loaded — and says so when `stepPhysics` hits its 8000-step
  guard, because the guard does not corrupt the answer, it silently runs
  simulated time slow, and silently is the whole problem. The drift reference
  rebases on a body count change: a merger carries off binding energy, so
  comparing across one reports physics as if it were error.
- **The control column is folded and mode-filtered at runtime**, from the `<h3>`s
  themselves (`groupControlSections`), so a new section folds and can be
  assigned to a mode without touching any of the controls inside it. Mode
  visibility uses a CLASS, because the climate and focused-object blocks drive
  their own inline `display` and whichever wrote last would win.
- **The frame loop's dt is wall-clock, and nothing may shadow it.**
  `requestAnimationFrame(cb)` calls back with a DOMHighResTimeStamp, so
  `function animate(fixedDt) { requestAnimationFrame(animate); ... }` receives
  the milliseconds since navigation as `fixedDt` on every real frame — dt then
  is not the length of the frame but the AGE OF THE PAGE, growing without
  bound. The sim ran 176× fast, the frame-rate readout sat at 0 because 1/dt had
  underflowed, and every exponential ease downstream saturated. A hand-driven
  step is passed through the module-level `manualDt`, never a parameter.
- **Order in the render loop matters** and is documented inline: surface view and
  lensed view are separate branches, the spectral remap runs *before* bloom, and
  the sky pass applies its own eye-adaptation exposure so the tone mapper is
  called at unity there.
- **The comments are the documentation.** Each module opens with a block header
  deriving the physics it implements. Keep that density when editing — explain
  the equation and the reason for a choice, not the syntax.
- **The course is DATA and the page is CODE, and they do not meet.**
  `sim/lessons.js` imports nothing at all; a step asks for "the solar system,
  following Earth, at true scale, in the X-ray band" and has no idea how any of
  those four are done. `sim/lessonui.js` executes that against a `stage` object
  built in the orchestrator, which is the whole of the coupling. A directive the
  stage does not implement is ignored rather than thrown, so a lesson may ask
  for something a later version will do.
- **A lesson step's `do` block is a PATCH, not a state.** Steps within a lesson
  normally share a scenario and differ by a camera or a band, so `applyDo` only
  reloads when the key actually changes — and the order in it is load-bearing:
  loading resets the camera and the focus, and `focus` reframes the view, so
  anything that sets a distance has to come after both. Local time comes after
  the controls, because where noon is depends on the latitude the step just set.
- **A step that states a camera distance is usually wrong to.** `focus` already
  frames a body at seven of its own radii, which is right under BOTH size
  conventions; a distance written while looking at the exaggerated view puts the
  camera inside the planet at true scale. `.claude/coursecheck.js` checks this
  and found seven.
- **There is no test runner, and for the course there is
  [.claude/coursecheck.js](.claude/coursecheck.js).** Injected into the page, it
  walks every lesson and every step IN ORDER — with `next()`, not by jumping,
  because a step is a patch on the last one — runs a frame at each, and reports
  anything that threw, any scenario that did not load, any body a lesson focuses
  that is not in it, any control or panel it names that does not exist, and any
  camera that ended up inside its subject. `SIM.lessons` and `SIM.stage` are
  exposed for it. Run it after touching lessons, presets or the stage.
  [.claude/presetcheck.js](.claude/presetcheck.js) is its blunter sibling: it
  loads EVERY scenario in `PRESET_ORDER`, runs a second of frames in each, and
  reports anything that threw or that quietly lost bodies — which is the check
  that catches a change to a contact radius or a mass–radius law reaching a
  scenario nobody was looking at.
- **An instrument in a lesson card MEASURES the scene.** The light curve, the
  strain and the HR diagram are all computed from the live bodies each frame
  (`lessons.update(dt)` in the render loop), never from a table — which is what
  makes "climb out of the orbital plane and the transits stop" a demonstration
  rather than an assertion. A light curve that only advances when Next is
  pressed is a picture of a light curve.
- **A measured radius is the contact distance too.** By default a body is
  destroyed when it touches what you can SEE, which keeps the exaggerated view
  self-consistent — but the Moon orbits 0.00257 AU from an Earth whose
  exaggerated disc is 0.15 AU across, so switching `#solar` to readable sizes
  destroyed it silently. Anything carrying a real `radiusKm` uses that instead.
- **The hot end of a surface is derived, like the cold end.** Everything freezes
  out below its own condensation point and always did; nothing dried out above
  the boiling point unless the energy-balance model in `sim/world.js` was driving
  it, which happens only for a scenario's one home world. So an ordinary planet
  at 388 K was drawn with oceans. `sim/rocky_visual.js` now derives `uSeaKm`,
  `uScorch` and `uArid` from the temperature it already computes — but only for
  a body with an atmosphere, because an airless rock at 440 K is not scorched,
  it is just warm, and tinting it would be inventing a phenomenon.
- Prefer extending a `sim/` module over growing `blackhole_sim.js`; it is already
  the largest file and is the integration layer, not a home for new physics.

## Verifying changes

There is no test suite. Verify visually via the preview server: load the
relevant scenario by hash, check the browser console for shader compile errors
(they surface as Three.js program errors), and screenshot. For dynamics changes,
the HUD reports simulated time and body count, and long-run stability is checked
by letting a preset integrate — the Trisolaris hierarchy is the standing
regression case (stable for 60k+ years, ~1e-7 relative energy drift).

The physics in `sim/structure.js` is pure and has no Three.js in it beyond what
`sim/physics.js` drags in, so it can be checked numerically instead of by eye. Copy
`sim/` somewhere with a stub `three` module on the resolution path and run a script
against it; the relations are all calibrated against published measurements (Earth's and
Jupiter's flattening, Sirius B's radius, the Kerr ISCO, Vega's oblateness and pole/equator
temperatures, the Sun's central temperature), so a regression shows up as a number moving
rather than as a picture looking wrong.

The spaceflight physics is pure in the same sense and is checked the same way —
`sim/flight/` imports nothing from the orrery except through
`sim/flight/spaceflight.js`, so a stub `three` on the resolution path is enough to
fly a whole mission headlessly. The standing regression cases are the four
launchers reaching orbit with the right max-q and staging times, and the three
landings touching down inside their gear ratings.

When the preview pane is hidden the page gets a 0×0 viewport and
`requestAnimationFrame` never fires, so nothing renders and screenshots show a
stale surface. `SIM.frame(dt)` runs one frame by hand at a fixed step;
[.claude/art.js](.claude/art.js) reads the composited framebuffer back as a
coarse luminance grid, and [.claude/mission.js](.claude/mission.js) scripts a
whole flight and samples telemetry along it. Override `innerWidth`/`innerHeight`
and dispatch a `resize` first, or the drawing buffer is one pixel.

For vehicle models, open [.claude/crafttest.html](.claude/crafttest.html) — the
same idea as skytest, for `sim/flight/craftmodel.js`. It renders one vehicle on
a neutral ground under a fixed three-point rig with a 1.75 m figure beside it:
`?v=shuttle&view=side` (orthographic elevation — a silhouette is the honest test
of a shape and the only projection you can hold against a reference photo),
`view=iso|front|top|detail|under|nose` (`detail`/`under` frame the aft end,
`nose` the forward one), `&stage=N` to frame one stage, `&z=` to zoom.
Deployables are shown DEPLOYED; `&deploy=0` gets the stowed pose. That is not a
default worth flipping back: `update()` holds everything folded until the flight
state asks, so the harness spent its life drawing landers with their legs up and
grid fins laid flat — the one pose in which a deployable tells you nothing about
whether it is right, and the reason four broken landing gears went unnoticed.
`STUDIO.audit()` builds EVERY vehicle and returns measured height, span and
triangle count — that is the regression check, because a stack whose height
stops matching the published figure shows up as a number rather than as a
picture that looks slightly wrong. [.claude/craftsheet.html](.claude/craftsheet.html)
puts them all in one frame, which is how you judge whether the set belongs
together. Note both set `preserveDrawingBuffer` — without it a hidden preview
pane screenshots black, since nothing repaints and the buffer is cleared once
composited. Params live in the SEARCH string, not the fragment: a hash-only
change does not re-execute the module and you get the previous vehicle.

For sky work, open [.claude/skytest.html](.claude/skytest.html) instead. It
renders `sim/sky.js` on its own through the same postfx chain, with a camera you
can aim exactly (`1`–`7` band, `e` environment, arrows aim, `z`/`x` zoom) and no
scene, mesh or black hole in the way. Hunting for the galactic band inside a
live preset wastes a lot of time; there it is always in the same place. Beware
that GLSL reserves `patch`, and that backticks in a comment inside a shader
template literal terminate the string — both cost a debugging round trip here.
