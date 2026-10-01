# AGENTS.md

Astrarium: a relativistic orrery, a 35-lesson astronomy course and a spaceflight
simulator, in Godot 4.7 / GDScript at the repo root. [README.md](README.md) covers
running, exporting and the command-line options. [docs/godot.md](docs/godot.md)
covers the render pipeline, colour management, the temperature pass and GDScript
traps. `sim/flight/`, `model_sources/blender/` and `shaders/` have their own
AGENTS.md. Read `shaders/AGENTS.md` before editing how a body looks
(`sim/*_visual.gd`, `sim/terrain.gd`, `sim/prominence.gd`, `sim/sky.gd`).

## `web/` is frozen

`web/` is the archived Three.js build. Do not edit it and do not port changes
back to it. Some checks in `tools/` still run it as a numeric reference
(`physcheck.sh`, `flightcheck.gd` + `flightref.mjs`); that is its only remaining
use. [web/README.md](web/README.md) still describes the physics and scenario
design.

## Comments

- Comment *why*, not *what*: a non-obvious reason, a source for a number, a trap.
  One or two lines is the default.
- A derivation longer than ~10 lines goes in `docs/physics/<topic>.md`, with a
  one-line pointer in the code.
- No history (what the code used to do, which bug a line fixed). That belongs in
  the commit message.
- No references to the web build beyond one line in a file header, and no banner
  separator lines.
- Many existing files are denser than this. Don't match their density.

## Units and precision

- Physics is in AU, M☉ and years, so `G = 4π²` exactly. Never put a scaling fudge
  in the physics; rendering exaggeration belongs in the preset's `sceneScale` /
  `bodyScale`. Scene units ≠ AU: `state.scene_scale` converts. Collision radii on
  a body are in AU; rendered radii are in scene units.
- `sim/flight/` is SI (metres, seconds), because an ascent in AU loses most of a
  float's mantissa. The bridge (`GM☉ = 1.32712440018e20 m³/s²`) is crossed only
  in `sim/flight/vessel.gd`.
- Physics state is double: `DVec3`, never `Vector3`. Every camera sits at the
  origin and nodes are placed at `abs.rel_v3(cam_pos)` (a floating origin), so
  world space is camera-relative. See [docs/godot.md](docs/godot.md).

## What a body is

- `structure_of(spec)` in `sim/structure.gd` is the single source of truth for
  radius, shape, interior and stability. Every consumer reads `b.structure`.
  Call `refresh_structure(b)` whenever mass or spin changes (accretion changes
  mass continuously). New thresholds go in `structure.gd`, never in a second
  place.
- Measured beats modelled: a spec with `radiusSun` / `teff` / `luminosity` /
  `radiusKm` (e.g. from `sim/starcat.gd`) overrides the evolutionary track. A
  measured `radiusKm` is also the contact distance.
- Spawning and editing are the same operation: both end in `derive_body()`
  re-reading `b.spec`. Anything a spec implies belongs in `derive_body`, or it
  exists on spawn and vanishes on the first edit.
- A structural limit is an event: `check_structural_limits()` in `main.gd` must
  act on it (a neutron star past the TOV mass collapses; a white dwarf at the
  Chandrasekhar mass detonates). A verdict the sim only prints is a bug.
- Appearance is a consequence. A planet derives its insolation from where it is
  and which stars light it (`insolation_at`), then its temperature, ice line and
  biomes. A preset states a value only when it can't be derived (Venus's 737 K is
  stated; Mercury's temperature is not).

## Size and the camera

- Rendered size goes through `render_radius`. Black holes are always the true
  horizon. Everything else is the true radius under `state.true_scale`, and
  otherwise a magnified stand-in (`base_radius` scaled by real/reference radius,
  so the mass slider still changes size). Switching conventions at runtime means
  `rebuild_visuals()`.
- A true-scale body is usually sub-pixel and is drawn by the point-source marker
  (`sim/marker.gd`). Picking, the near plane and the follow camera must work at a
  rendered radius of 1e-5. Check: `solar`, true scale, fly to Earth.
- An edited body eases into its new size (`size_ease`), and the follow camera
  glides (`radius_to`). Deliberate camera moves go through `jump_cam_radius`, or
  a glide already in progress drags the view back.
- Following a body is exact tracking plus a decaying offset (`track_follow`,
  `glide_target_to`), never a lerp toward it: a first-order lag rubber-bands.

## Body visuals

A factory returns an object with `group: Node3D` and `update(dt, ctx)`, stored
on `b.viz`. The orchestrator owns `group.position` and `group.scale`, so a visual
puts its own offsets on inner nodes. `ctx` is a `VisualCtx`
([docs/godot.md](docs/godot.md#the-body-visual-contract)).

## The course

- `sim/lessons.gd` is data with no scene access. A step's `do` block is a
  declarative request that `sim/lessonui.gd` executes against the stage. An
  unimplemented directive is ignored, not thrown.
- A `do` block is a patch, not a state: `apply_do` reloads only when the preset
  changes, then applies focus, then distances, then local time. The order is
  load-bearing.
- Don't state a camera distance in a step. `focus` already frames a body at seven
  radii, which works at both size conventions.
- Instruments in a lesson card (light curve, strain, HR diagram) measure the live
  bodies every frame, never a table.

## UI

- The HUD is native Controls styled by the Theme in `ui/theme.gd`; add a look
  as a kind in `KINDS`, not as per-node overrides. `ui/hud.gd` keeps the
  orchestrator's API (`set_text`, `set_active`, `set_shown`, `set_slider`,
  `mount`) and its static builders (`label`, `range_row`, `frame`, `stack`,
  `grid`, `hbox`) are what the Foundry, flight panel and course build with.
- The left column is a measured chain: each panel is placed from the previous
  one's measured bottom (`HudPanel.natural_height`). A collapsed panel leaves a
  tab, and nothing overlaps. Settings is an Esc overlay outside the chain, for
  settings that outlive a scenario.
- Wrapping text goes through `Hud.label(..., wrap)` (a `Prose`) and is set with
  `say()`, or it breaks a word early. Check HUD changes with
  `tools/hudcheck.tscn` (screenshots of named states, `htest=1` for the
  interaction walk).
- Key bindings: `ui/control_bindings.gd` owns the defaults, conflicts and
  `user://controls.json`. `main.gd` resolves keys before passing flight actions on.
- The step cap is the one setting that changes the answer. The HUD reports
  sub-steps per frame and energy drift, and says when `STEP_GUARD` is hit
  (otherwise the sim silently runs slow). Drift rebases when the body count
  changes.

## Checks

There is no test suite; there are checks, listed in
[README.md](README.md#verifying). Run the one that covers your change:

- presets, structure or contact radii: `tools/presetcheck.sh`
- lessons, presets or the stage: `tools/coursecheck.tscn`
- the HUD: `tools/hudcheck.tscn` (`htest=1`, and screenshots of the states it
  touches)
- vehicles: `tools/crafttest.tscn -- audit` and `-- clearance`, with and without
  `assets=0`
- launch complexes: `tools/padcheck.gd` (and `-- padmodels=0`); must report zero
- anything that creates or frees nodes, visuals or caches: `eval=_soak_check`;
  the counts must stay flat after the first round
- parse errors: `Godot --headless --path . --import`, then `--quit`. Shader
  errors print as `SHADER ERROR` on first render.

Long-run stability: Trisolaris stays stable for 60k+ years at ~1e-7 relative
energy drift. For screenshots, use `frames=60 out=/abs/shot.png` (see README).
