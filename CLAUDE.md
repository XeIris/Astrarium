# CLAUDE.md

Guidance for Claude Code working in this repo. The [README.md](README.md) is the
authoritative description of *what the sim models and why* (physics derivations,
scenario design, disclaimers) — don't duplicate or rewrite it here. This file is
the engineering map: stack, layout, conventions.

## Stack

- **Three.js 0.160.0**, loaded from a CDN through an `importmap` in
  [blackhole_sim.html](blackhole_sim.html). Vanilla ES modules, no bundler.
- **No build step, no package.json, no dependencies, no tests.** Editing a file
  and reloading the page is the whole dev loop.
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

Scenarios deep-link by hash, e.g. `blackhole_sim.html#bhmerger` — handy for
jumping straight to the case you're debugging. Keys `1`–`7` switch imaging band,
`H` hides the UI (useful before screenshots).

`window.SIM` is a deliberate console handle, not a leftover: `SIM.state.bodies[0].structure`
is the fastest way to see what the physics thinks a body is, and `SIM.load('vega')` beats
editing the hash. Note that browser-automation tools usually evaluate in an isolated
world where page globals are not visible — inject a `<script>` element to reach it.

## Layout

Shell:

- [blackhole_sim.html](blackhole_sim.html) — page shell, importmap, all HUD panel
  markup. Controls are plain elements looked up by `id`.
- [blackhole_sim.css](blackhole_sim.css) — HUD/panel styling.
- [blackhole_sim.js](blackhole_sim.js) — the only orchestrator (~1.2k lines).
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
| [sim/star_visual.js](sim/star_visual.js) | photosphere / chromosphere / corona / prominence / CME rendering |
| [sim/neutron_visual.js](sim/neutron_visual.js) | neutron-star surface, self-lensing, polar caps, pulsar beams |
| [sim/world.js](sim/world.js) | the climate-driven rocky planet; also owns `MAX_SUNS` and `applySuns` (multi-sun lighting uniforms) |
| [sim/climate.js](sim/climate.js) | zero-D energy-balance model, `Climate` class and `ERAS` classification |
| [sim/skyview.js](sim/skyview.js) | `SurfaceObserver` (where you stand, planet rotation) + `createSkyPass` multi-sun scattering composite |
| [sim/blackhole.js](sim/blackhole.js) | `createBlackHolePass` — GR null-geodesic ray marcher, shadow/photon ring, volumetric Shakura–Sunyaev disc; `MAX_HOLES = 2` |
| [sim/postfx.js](sim/postfx.js) | `createPostFX` — HDR target, spectral remap, progressive bloom, ACES composite |
| [sim/spectrum.js](sim/spectrum.js) | `BANDS` and the temperature→band-brightness remap shader used by postfx |
| [sim/sky.js](sim/sky.js) | the celestial background: `SKY_GLSL` (procedural stars, galactic band, dust, nebulae, non-thermal populations, all band-aware), `createSkyBackdrop` for scenes with no hole, and `SKY_ENVIRONMENTS` |
| [sim/textures.js](sim/textures.js) | seeded procedural rocky / gas-giant canvas textures |
| [sim/scale.js](sim/scale.js) | true-scale rendering: `physicalRadiusAU` mass–radius fallbacks, and `createMarker` — the point-source glow that carries a body once its disc goes sub-pixel |
| [sim/structure.js](sim/structure.js) | **what a body IS**: mass–radius laws per support mechanism, ignition/support limits, rotational shape & gravity darkening, central conditions, and the layer model. `structureOf(spec)` is the single entry point |
| [sim/starcat.js](sim/starcat.js) | `STAR_CATALOG` — measured parameters for ~27 real stars — plus `starSpec` / `starRing` / `realBinary` / `companion` scenario builders |
| [sim/foundry.js](sim/foundry.js) | the Object Foundry editor panel (`createFoundry`), the live-body inspector (`createInspector`) and the in-flight parameter editor (`createLiveEditor`), which share one set of control rows |
| [sim/masscurve.js](sim/masscurve.js) | `createMassCurve` — the log–log mass–radius graph in the live editor. Its threshold marks are *sampled* out of `structureOf`, never listed, so a new limit in `sim/structure.js` appears here on its own |
| [sim/crosssection.js](sim/crosssection.js) | `drawCrossSection` — the labelled interior diagram — plus the temperature ramp and every unit formatter the panels use |
| [sim/painter.js](sim/painter.js) | rings, belts and ejecta: `createOrbitalSwarm` (analytic Keplerian test particles), `createGasCloud`, `ringSpan`, `createPainter` |

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
- **The control column is folded and mode-filtered at runtime**, from the `<h3>`s
  themselves (`groupControlSections`), so a new section folds and can be
  assigned to a mode without touching any of the controls inside it. Mode
  visibility uses a CLASS, because the climate and focused-object blocks drive
  their own inline `display` and whichever wrote last would win.
- **Order in the render loop matters** and is documented inline: surface view and
  lensed view are separate branches, the spectral remap runs *before* bloom, and
  the sky pass applies its own eye-adaptation exposure so the tone mapper is
  called at unity there.
- **The comments are the documentation.** Each module opens with a block header
  deriving the physics it implements. Keep that density when editing — explain
  the equation and the reason for a choice, not the syntax.
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

For sky work, open [.claude/skytest.html](.claude/skytest.html) instead. It
renders `sim/sky.js` on its own through the same postfx chain, with a camera you
can aim exactly (`1`–`7` band, `e` environment, arrows aim, `z`/`x` zoom) and no
scene, mesh or black hole in the way. Hunting for the galactic band inside a
live preset wastes a lot of time; there it is always in the same place. Beware
that GLSL reserves `patch`, and that backticks in a comment inside a shader
template literal terminate the string — both cost a debugging round trip here.
