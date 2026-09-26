# The Godot port — report

**What was done:** the whole of Astrarium (the relativistic orrery, the 35-lesson
astronomy course, the spaceflight simulator, the Object Foundry, the model
viewer and every HUD panel) was ported to **Godot 4.7.2 / GDScript** in
the `godot/` folder on the `godot-port` branch. That project now lives at
the repository root; the runnable web reference is archived in `web/`.

- **Size:** 35.5k lines of GDScript and 5.3k lines of shaders (gdshader and GLSL
  compute), plus one 354-line C file.
- **Accuracy:** every part was checked against the web build, in numbers and in
  side-by-side frames.
- **Build:** a universal macOS `.app` builds from the committed export preset and
  runs.

How to run and build it is in [README.md](README.md). This file covers what
changed architecturally, and why; what was verified; and what still differs.

---

## 1. Major architectural changes

Most of the port is a line-by-line translation, with the derivation comments
carried over. The changes below were forced by Godot. Each was measured before
it was adopted.

### 1.1 Rendering: a SubViewport tree with a compositor hook
The web build drove the GPU by hand (`setRenderTarget`, `autoClear`,
`clearDepth`) and tone mapped once at the end. In Godot that became
`render/pipeline.gd`:

- **Viewport tree.** The orrery, flight and studio worlds are SubViewports nested
  inside a small "hook" viewport.
- **Post chain.** The hook's compositor callback runs the web build's post chain
  as **GLSL 450 compute shaders**, in the same order: compose → [surface
  atmosphere] → [spectral remap] → dual-filter bloom → ACES / vignette / grain /
  dither. Godot's own tonemapper, glow and exposure are off everywhere, so this is
  still the one tone curve.
- **Lens.** The black-hole marcher became a compute pass. The web build wrote it
  as a two-target (MRT) fragment pass, which a canvas shader cannot express. It is
  resolved by a Godot sky shader that also draws the plain star field, so the two
  sky paths share one code path, as they did before.
- **Measured before building.** Nested viewports render before their parent,
  frame-exactly. Compute dispatched in `_process` lands before that frame's draw.
  HDR values above 1 survive.

### 1.2 The temperature pass replaces the HDR alpha channel
The multi-wavelength imaging depends on each emitter writing its true
temperature into the alpha channel of the HDR buffer. Godot cannot write
arbitrary alpha from an opaque shader, so the same world is drawn a second time
by a camera with an extra cull-mask bit. Every shader checks
`CAMERA_VISIBLE_LAYERS` and, in that pass, writes into R exactly what the web
build's blend equations would have left in alpha. The blend-mode table in
`PORT_GUIDE.md §6` was measured, not assumed. This pass only runs outside the
visible band, so it costs nothing in normal viewing.

### 1.3 Double precision and a floating origin
JavaScript numbers are doubles; Godot's `Vector3`, transforms and vertices are
float32.

- **Doubles for physics.** All physics state is held in `DVec3` (three GDScript
  doubles). That covers the N-body state in AU and the flight model in metres
  about a 6.4e6 m planet, where float32 would quantise position to 0.4 m.
- **Floating origin.** Every render camera sits at the origin. Each frame, the
  orchestrator places every object at (its position − the camera position),
  subtracted in double precision. The web build got this for free from three.js
  building its matrices in float64; here it is built into the scene layout.

### 1.4 A native kernel for the one hot loop
GDScript ran the N-body sub-step loop 24–125× slower than V8, and the `solar`
scenario needed **38 ms of physics per frame**. You allowed a native fallback for
hot loops, so that one loop (dynamic step, velocity-Verlet, gravitational-wave
reaction, collisions) moved to `native/astrarium_native.c`.

- **How it's built.** It is a GDExtension written in plain C against Godot's own
  `gdextension_interface.h`: no godot-cpp, no SCons, no CMake, no downloads, and
  one `cc` line to build.
- **Speed.** 19–386× faster: `solar` drops to **0.1 ms/frame**.
- **Accuracy.** Bit-identical to the GDScript reference. It uses `-ffp-contract=off`
  and the JavaScript's own evaluation order, so the sub-step counts match through
  both merger scenarios.
- **Packaging.** The universal `.dylib` is committed prebuilt. If it is missing,
  the GDScript loop runs with identical results, only slower.
- **Everything else stays GDScript.** The flight model measured at 0.3 ms per
  frame (1.6% of a frame) and needed no native code.

### 1.5 The HUD is a CSS layout engine, not Godot containers
The 544 lines of HTML and 1025 lines of CSS became `ui/hud.gd`, built on
`ui/widgets/el.gd`. `El` is a small port of the parts of CSS the page actually
uses: block flow with collapsing margins, flex with baseline alignment, grid,
inline text with Chrome's font metrics, plus the backdrop blur. Godot's own
containers mis-place things by a few pixels everywhere. With `El`, every panel
lands within 0.2 px of the web page.

### 1.6 Other structural changes
- **Body derivation** (`deriveBody`, `renderRadius`, the type tables) moved from
  the orchestrator into `sim/derive.gd`, as AGENTS.md prefers.
- **Closures became classes.** The web build's closure factories are ported as
  classes, because GDScript lambdas capture locals by value.
- **Command-line options replace the URL hash and the `SIM` console handle:**
  - `preset=`, `mode=`, `band=`, `focus=`, `truescale=`, `cammode=`, `localtime=`
    set up the view;
  - `seed=` reproduces the web build's random scenario layout;
  - `frames=`/`out=` run fixed steps, write a screenshot and quit;
  - `eval=` runs checks.
- **Near-plane policy.** This is the one intentional behavioural deviation.
  - *The problem:* Godot builds its culling frustum in float32, and any far/near
    ratio past about 1e7 degenerates it (measured). The web build's true-scale
    close-ups reach 1e11, and the whole frame was culled.
  - *The fix:* the near plane sits at 5% of the viewing distance instead of 0.1%.
    That is safe because Godot's depth buffer is reverse-Z float, which, unlike
    WebGL's integer depth, doesn't need a tiny near plane for precision.
  - *Result:* pictures are unchanged.
- **Vehicle meshes** load through Godot's glTF importer, so they survive export.
  The procedural fallback still works when they're missing.

## 2. Verification
The standing checks from AGENTS.md, plus a side-by-side comparison of every
part against the web build. The web frames were captured headless in Chrome, with
the page's own clock frozen and seeded the same way as the Godot run. All of this
was re-run on the final tree.

| area | result |
|---|---|
| All 35 scenarios (`tools/presetcheck.sh`) | 35/35 load and run with **0 script/shader errors**; body counts identical to the web build's own `presetcheck.js` |
| Course (`tools/coursecheck.tscn`) | **35 lessons, 108 steps, 0 errors**, the same count the web's `coursecheck.js` gives |
| Interior model, presets, climate | 1,048 `structure_of` cases and 48,918 numbers: max relative error 2.8e-14; every AGENTS.md calibration reproduced |
| Integrator | identical sub-step counts on every preset; Trisolaris 2,000 yr: same 5,142,870 sub-steps, energy agrees to 9e-10 |
| Flight | 11 scenarios: same events at the same times; launchers to orbit (Saturn V max-q 29.58 kPa at 81 s, orbit at 719 s); LM lands at −2.26 m/s. 22 telemetry dumps: worst gap 3.8e-9 relative |
| Vehicles | height, span, triangle count and engine clearance identical to `STUDIO.audit()` / `clearance()`, with and without the authored meshes |
| Pictures | all 35 scenarios; all 7 imaging bands; sky environments, lensed sky, surface view; stars, planets, rings; Foundry / cross-section / cutaway (28 states); course cards and instruments (14 shots); flight (22 shots); HUD (19 states within 0.2 px) |
| Instruments | transit depth and RV K = 152.4 m/s; GW f = 9.5676 Hz, h₀ = 3.39e-22, both matching the web to ~1e-11 |
| macOS build | exported universal `.app` (188 MB, ad-hoc signed, native kernel bundled); runs sandbox, Learn, Spaceflight and the X-ray band with 0 errors |

The evidence behind each row is in `tools/ref/` (web and Godot image pairs,
plus state dumps).

## 3. What still differs, and why

- **Random streams.** JavaScript's `Math.random` and Godot's `randf` produce
  different sequences. Starspot positions, flare and CME timing, cloud seeds,
  starting planet spin and launch-smoke puffs therefore differ between runs of
  either build, and between the builds. `seed=N` lines up the scenario layouts
  that side-by-side checks depend on.
- **Cosmetic, sub-pixel or near-invisible:**
  - The black-hole cutaway's three faint wireframe shells are slightly bluer
    (blending in linear vs display space).
  - Some small text sits about 0.5 px higher.
  - The Flight panel header sits 1 px lower.
  - The upper-stage exhaust is a little narrower at staging.
- **Not ported (deliberately small):**
  - the "INITIALIZING SPACETIME METRIC…" loading overlay;
  - the start card's 2 px hover lift;
  - the 0.15 s hover colour transitions (Godot's are instant).
- **Web-build bugs reproduced faithfully rather than fixed**, since fixing them
  would have made the two builds diverge. These are four flight bugs, found by
  running the web build's own flight model headlessly:
  1. The Shuttle never reaches orbit. The orbiter's engines light at SRB
     separation, and the vehicle breaks up at 1891 s.
  2. The Falcon 9 hoverslam lands at 7.9 m/s against a 6.0 m/s gear rating.
  3. The Mars EDL program never lights the sky-crane descent stage (141.8 m/s
     impact unless the pilot stages it).
  4. `deorbit` re-plans a zero-Δv node every frame after cutoff.

  All four are worth fixing in the web build first; the port will follow.

## 4. Housekeeping notes

- `tools/ref/` is **80 MB** of comparison images. They are the evidence
  for this report but don't need to live in the repo. Deleting that folder
  changes nothing about running or building.
- The parallel porting work used git worktrees under `.claude/worktrees/` (historical), one
  per agent branch. Every branch is merged into `godot-port`, so they can be
  removed with `git worktree remove`.
- Nothing has been pushed.
