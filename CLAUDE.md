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
| [sim/textures.js](sim/textures.js) | seeded procedural rocky / gas-giant canvas textures |

## Conventions

- **Astronomical units everywhere in physics**: AU, M☉, years — so `G = 4π²`
  exactly. Never introduce a scaling fudge into `sim/physics.js`; rendering
  exaggeration belongs in `sceneScale` / `bodyScale` on the preset.
- **Scene units ≠ AU.** `state.sceneScale` converts. Physical radii used for
  collisions live on the body in AU; rendered radii are in scene units.
- **Body visuals follow one contract**: a factory returns `{ group, update(dt, ctx) }`
  attached as `b.viz`, with `ctx = { holes, camera, time, sceneScale }`.
- **Emitters publish their true temperature** (log-encoded) into the alpha of
  the HDR buffer so `sim/spectrum.js` can re-image them in non-visible bands. A
  new emitter that doesn't publish it will fall back to inferring T from colour
  and will behave wrong in X-ray/radio bands.
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
