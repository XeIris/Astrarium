# Astrarium

The main version of Astrarium is a **Godot 4.7 / GDScript** relativistic orrery,
astronomy course, and spaceflight simulator. Open [project.godot](project.godot)
to run it. The original HTML/Three.js version is archived as a runnable project
in [web/](web/). Its [README](web/README.md) describes the physics and scenarios;
the shared engineering guidance is in [AGENTS.md](AGENTS.md), Godot-specific
decisions are in [docs/godot.md](docs/godot.md), and the port's verification
record is in [PORT_REPORT.md](PORT_REPORT.md).

## Running it

You need Godot **4.7.x** (standard build — not the .NET one, and not a
double-precision build).

1. *(optional, once)* Build the authored vehicle, launchpad and launch-site
   facility meshes. They are build artifacts of `model_sources/blender/*.py`
   and are gitignored; without them the vehicles, launchpads and site
   buildings use their procedural fallbacks.
   ```sh
   model_sources/blender/build.sh       # needs Blender 4.1+; 9 craft, 4 pads, facilities
   tools/sync_assets.sh /abs/source     # optional: import existing GLBs from elsewhere
   ```
2. Open `project.godot` in the Godot editor and press **Play** (F5).
   The first open imports everything, which takes a minute.

The app opens on a star-field start screen. Choose **Sandbox**, **Learn astronomy**,
or **Spaceflight** to load that mode. Press **Esc** during play for Settings;
its **Controls** tab lists the bindings and has **Quit to start** and **Quit app**.
Select a key in that tab to remap it. Keyboard bindings are saved between runs;
**Reset all bindings** restores the defaults.
The **Render** tab switches the spacetime mesh between a connected grid and
deforming dots. The **Mesh** button in Controls still shows or hides it.
It also offers Low, Medium and High rendering presets. Tick **Advanced rendering
controls** to adjust resolution, black-hole lens detail, exposure and post-processing
individually. **Lighting detail** affects the local flight scene and craft studio:
Medium adds shadows and ambient occlusion; High also adds screen-space
indirect light and reflections in the craft studio. The flight view uses a
transparent render pass, where Godot does not support screen-space reflections.
These effects are not hardware ray tracing.
High rendering quality adds seven photo-style material textures to spacecraft
and launchpads, with subtle roughness and normal detail. The same set works on
authored Blender models and procedural vehicle fallbacks; see
[the material guide](assets/materials/README.md). Lower presets keep the lighter
flat-colour materials.
In Earth's flight view, High also uses sky radiance for material reflections,
a raymarched volumetric cumulus layer (1.5–4.6 km, visible from below,
inside and above, casting shadows on the ground and dimming the vehicle's
sunlight when it is under or in a cloud) and subtle near-field atmospheric
scattering. Medium marches the same clouds more coarsely; Low skips them.
The sun is drawn at its true angular size at every altitude, reddened by the
air mass along its line and occluded by the vehicle, the ground, the planet
and clouds, with the camera's glare: a 14-ray starburst from a 7-blade iris,
fine scatter rays, and coloured aperture ghosts strung across the frame
(`shaders/flight/lens_flare.gdshader`). The sky is integrated through a
spherical atmosphere, so climbing out of it the horizon becomes a thin blue
limb, and the ground is hazed along the true slant path; from altitude the
10 km/px Earth map gets noise-warped coastlines, kilometre-scale land
texture and a sun glint on the sea. The star field is dimmed by the camera's
daylight exposure (stars vanish beside a sunlit vehicle and return in the
planet's shadow or far from the Sun). Daylight exposure is calibrated in the
flight view, and the Advanced exposure slider gives manual control.
Engine exhaust is a raymarched volume per engine: shock diamonds and Mach
disks from the real exit-to-ambient pressure ratio, afterburning, soot, and a
look per propellant and engine (see `sim/flight/plume.gd`); large clusters
draw one merged far field.
The four Blender pad builds add railings, catwalks, structural framing and
service hardware to Saturn V, Shuttle, Falcon 9 and Starship launch sites. The
surrounding hardstand now has joints, marked access roads, utility cabinets,
storage tanks, pump buildings, lighting and instanced coastal vegetation.

Or from a terminal, without the editor UI:
```sh
/Applications/Godot.app/Contents/MacOS/Godot --path .
```
Command-line options go after `--` and stand in for the web build's URL hash
and its `SIM` console handle:

| option | effect |
|---|---|
| `preset=vega` | start in a scenario (the web build's `#vega`) |
| `mode=sandbox\|learn\|flight` | skip the start screen and load that mode |
| `craft=saturnv\|falcon9\|shuttle\|starship` | select a launcher when starting flight mode |
| `padaz=180 padel=-0.2` | rotate and lower the flight pad camera for a screenshot |
| `padmodels=0` | check the procedural launchpad fallback |
| `sunview=1` | aim the final flight screenshot directly at the sun |
| `seed=7` | make the scenario's random choices reproducible |
| `quality=low\|medium\|high`, `lighting=low\|medium\|high` | rendering and local lighting presets |
| `band=5` | imaging band 0–6 |
| `focus=Earth`, `truescale=1`, `cammode=surface`, `localtime=noon` | camera and view |
| `frames=60 dt=0.0166 out=/abs/shot.png [hud=0] [shot3d=1]` | run N fixed steps, save a screenshot, quit |
| `eval=_preset_check` | run a development check (below); tools are excluded from exports |

## Building the macOS app

The macOS export preset in `export_presets.cfg` is universal arm64 + x86_64,
ad-hoc signed, with a minimum macOS version of 11. Linux and Windows presets
target x86_64; build their native kernel on the target OS with `sh native/build.sh`. Install the export templates once — *Editor → Manage Export
Templates → Download and Install* — then:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --export-release "macOS" build/Astrarium.app
open build/Astrarium.app
```

The app is signed ad hoc, which runs on the Mac that built it. On another Mac,
Gatekeeper will refuse it the first time: right-click → *Open*, or sign it with
a Developer ID (set `codesign/identity` and `notarization/*` in the preset, or
use *Project → Export…* in the editor). Build the authored meshes **before**
exporting, or the app uses procedural fallbacks.

## The native physics kernel

`native/` holds one small GDExtension, written in plain C against Godot's own
`gdextension_interface.h`: the N-body sub-step loop. GDScript runs that loop
~50–125× slower than the browser's JIT does, and the `solar` scenario needed
38 ms of physics per frame; the kernel did it in 0.1 ms in that local benchmark.
`tools/nbodycheck.gd` checks both implementations with strict numerical
tolerances; timings depend on the scenario and hardware. The universal `.dylib` is **committed
prebuilt**, so nothing needs compiling to run or export. If it is missing, the
same GDScript loop runs instead — identical results, just slower. Rebuild after
editing `astrarium_native.c`:
```sh
native/build.sh                    # needs only Xcode's command line tools
```

## Verifying

Run the checks relevant to the change; defects and incomplete runs must return a
nonzero exit. Independent physics invariants supplement comparisons with the
frozen numeric reference. The [codebase review and remediation log](docs/codebase-review-2026-10-02.md)
records known issues, ownership and acceptance evidence.

`python3 tools/check.py` runs the fast headless suite. Select additional suites,
for example `python3 tools/check.py fast native assets rendered lifecycle export`.
The runner retains child logs and a JSON report, rejects errors, timeouts and
missing completion markers, and stops on the first failure. Use `--godot` to
select an engine and `--log-dir` to retain results at a chosen location.
`assets` requires all nine generated craft models; `rendered`, `lifecycle` and
`perf` need a working graphical renderer. `flight` runs the four full launches. `native` includes the numerical boundary checks.
`stability` runs the strict 60,000-year Trisolaris check. `stability-study` adds
three timestep refinements and five orientation probes. Both remain explicit
suites because of their runtime; the redesigned scenario passes the tested bounds
(see [scenario limits and results](docs/scenarios.md#trisolaris-hierarchical-initial-conditions)).
`compatibility` keeps the known strict frozen-reference differences failing.
Body motion uses conservative Newtonian pair gravity; relativistic visuals and
the illustrative tight-pair drag have separate limits described in
[the compact-dynamics model](docs/physics/compact-dynamics.md).

`python3 tools/check.py perf --repeat 3` records rendered scenario/editor/LOD
measurements, fixed-step CPU flight timings and HUD shown/hidden timings.
See [the measurement contract and local results](docs/performance.md). Missing
GPU timestamps are reported as unavailable; these measurements are not portable
performance budgets.

`python3 tools/check.py clean` requires a committed clean working tree, clones it
without local import caches/generated models, builds the native kernel, checks
procedural assets and validates an export pack plus isolated resource/native
startup. To also render the exported application, run
`python3 tools/cleancheck.py --godot /absolute/Godot --log-dir /absolute/evidence --rendered-boot`.
The pack distribution contains **both `game.zip` and its `native/bin/` sidecar**;
`--export-pack` alone does not ship the OS library. Normal full application
exports include it through the extension descriptor.

[Portable CI](.github/workflows/verify.yml) pins Godot 4.7.2 and runs the clean
procedural gate on macOS, Linux and Windows. It does not establish authored
Blender fidelity, graphical performance or device budgets. Windows/Linux
execution evidence remains pending until the workflow runs on those hosts.
[Evidence retention](docs/evidence.md) keeps new generated captures out of the
frozen migration reference archive.

The `eval=` development methods live in `tools/runtime_checks.gd` and load only
when requested. Unknown methods and development checks requested from an export
fail explicitly. Multiple requested methods run in order.

| check | what it does |
|---|---|
| `tools/presetcheck.sh` | loads all 35 scenarios, runs a second of each, reports script/shader errors and lost bodies |
| `tools/coursecheck.tscn` | renders all 35 lessons / 108 steps; rejects engine errors, missing subjects and unknown directives; `selftest=1` must exit 1 with three errors and one warning |
| `tools/physcheck.sh` | compatibility report against frozen JavaScript; numeric differences are printed, not rejected; child/engine failures and missing output fail |
| `tools/flightcheck.gd` + `flightref.mjs` | the eleven flight scenarios vs the JavaScript |
| `tools/flighttimecheck.gd` | forced vessel/frame guard exhaustion, elapsed clocks, site rotation, visual time, warnings and normal/rails branches |
| `tools/sharedtimecheck.tscn` | rendered production frame driver: shared world/flight coordinate clocks, guards, moving parents, rails fallback and cruise arrival; `assets=0` skips optional models; `bench=1` measures frame CPU time |
| `tools/sharedflightcheck.gd` | four powered launches through `Spaceflight.update()` with moving world bodies; rejects clock divergence and missed orbit targets |
| `tools/sciencecheck.gd` | independent physical GW separation/SI values and live transit/RV/convergence checks, plus frozen photometry/pair selection; `-- compatibility=web` enforces obsolete contact-scaled GW readings and live trajectories, currently failing four intentional differences |
| `tools/numericalcheck.gd` | requires native kernel; checks tiny forces, potentials, step caps, positive durations, orbital convergence and unsafe-update rollback in both implementations |
| `tools/nbodycheck.gd` | requires native kernel; checks bodies, mass, positions, velocities, merger order, steps and integrated time against GDScript |
| `tools/invariantcheck.gd` | collision mass/momentum, symmetric ordinary and black-hole pair forces, matching energy, and presentation-independent contact distances |
| `tools/stabilitycheck.gd` | requires native kernel; strict 60,000-year Trisolaris bounds and compensated accepted time; `years=<n>` selects a shorter probe; `max_step=<years>`, `step_divisor=2`, `world_rotation=<radians>` and `world_eccentricity=<e>` select separately marked diagnostics; `report=/abs/result.json` retains runtime/force metadata, exact double states and approximate orbital elements |
| `tools/transitioncheck.tscn` | rendered spin/remnant transitions and canonical black-hole horizons through mass sliders, edits and contact mergers; rejects stale progenitor measurements |
| `tools/structureinputcheck.tscn` | production spawn/edit/preset rejection before mutation, supported threshold events, and rejected-control resynchronization |
| `tools/accretioncheck.tscn` | rendered physical/visual boundary: separated bodies retain mass and momentum under visual updates, paused streams freeze, and physical contact mergers still conserve mass and momentum; `native=0` forces GDScript and `inject_mutation=1` must fail |
| `tools/crafttest.tscn` | vehicles: `audit()` heights/triangles, `clearance()`; `-- parity` requires all nine authored craft and asserts whole-vehicle height/base agreement within 2 cm in both poses; `inject_parity=1` must fail |
| `tools/assetcheck.gd` | authored rig contracts and articulation, or procedural parts with `assets=0`; `inject_invalid=1` must fail on a missing driven part |
| `tools/savecheck.gd` | isolated JSON write/recovery failures, malformed controls/course/icon settings, binding conflicts and Reset rollback |
| `tools/hudcheck.tscn` | the HUD: `hstate=<state> hout=/abs/x.png` screenshots a named state through fixed steps; `htest=1` clicks, drags, types and scrolls through the controls with real input events and checks the orchestrator's state follows; `hperf=1` times frames with the HUD shown and hidden |
| `tools/editorcheck.tscn` | canonical inspector and graph invalidation, measured/tiny bodies, structural threshold crossings, and delayed edits across selection/removal/reused IDs |
| `tools/padcheck.gd` | rejects pad structure inside its vehicle; `padmodels=0` / `assets=0` select fallback pads / craft; `inject_intrusion=1` must fail |
| `python3 tools/exportcheck.py /abs/game.zip` | checks a `Godot --headless --path . --export-pack macOS /abs/game.zip` resource archive for development files, missing boot files and broken import/remap targets; native libraries and rendering still need an exported-app smoke run |
| `tools/webref.mjs` | screenshots of the web build (headless Chrome) for side-by-side checks |
| `tools/shots.sh` | screenshots of this build via the command-line options above |
| `eval=_leak_check` | loads all 35 scenarios and two launches five times; object/resource/node/orphan growth after warmup fails; VRAM is reported as telemetry |
| `eval=_soak_check` | repeats features with seeded initial conditions and asserts flat object/resource/node/orphan counts after warmup; the staged launch asserts ascent and three separations; `rounds=5` changes the default four rounds, `soak=model_viewer soakassets=0` checks all nine procedural craft; `soak=editor` exercises focused graphs and pending-edit removal |
| `--verbose ... eval=_shutdown_check` | drags render scale, opens a cutaway lesson, the model viewer and a launch, then quits; a clean run reports nothing leaked at exit |

`tools/ref/` holds the side-by-side evidence each part of the port was
accepted on.
