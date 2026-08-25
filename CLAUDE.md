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

## Conventions

- **Astronomical units everywhere in physics**: AU, M☉, years — so `G = 4π²`
  exactly. Never introduce a scaling fudge into `sim/physics.js`; rendering
  exaggeration belongs in `sceneScale` / `bodyScale` on the preset.
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

For sky work, open [.claude/skytest.html](.claude/skytest.html) instead. It
renders `sim/sky.js` on its own through the same postfx chain, with a camera you
can aim exactly (`1`–`7` band, `e` environment, arrows aim, `z`/`x` zoom) and no
scene, mesh or black hole in the way. Hunting for the galactic band inside a
live preset wastes a lot of time; there it is always in the same place. Beware
that GLSL reserves `patch`, and that backticks in a comment inside a shader
template literal terminate the string — both cost a debugging round trip here.
