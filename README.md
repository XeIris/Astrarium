# Astrarium

The main version of Astrarium is a **Godot 4.7 / GDScript** relativistic orrery,
astronomy course, and spaceflight simulator. Open [project.godot](project.godot)
to run it. The original HTML/Three.js version is archived as a runnable project
in [web/](web/). Its [README](web/README.md) describes the physics and scenarios;
the shared engineering guidance is in [AGENTS.md](AGENTS.md), Godot-specific
decisions are in [docs/godot.md](docs/godot.md), and the initial migration's historical
verification record is in [PORT_REPORT.md](PORT_REPORT.md).

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

The app opens on a title screen over a reel of live scenes rendered by the game
itself: the Hail Mary passing a lensed black hole, a Saturn V clearing its tower,
and Jupiter seen past Io at true scale, both drawn from Cassini and Galileo
maps ([sim/titlereel.gd](sim/titlereel.gd), [map sources](assets/planet-maps/README.md)).
Choose **Sandbox**, **Spaceflight** or **Learn** to load that mode, or **Settings**.

**Spaceflight** opens on the hangar. The craft stands on the studio turntable,
the line-up runs down the left, and a card gives the craft's numbers and the
missions it can fly: free flight, Earth orbit, lunar orbit, a lunar landing,
Mars or Venus orbit. Each is priced in Δv against what the craft carries, and a
mission it cannot fly says why. **Start mission** puts the craft on the pad. The
autopilot then flies every leg (launch, transfer, course corrections, capture,
landing) and chooses the time warp, so the whole mission can be watched. Change
the warp yourself and auto warp stops until you turn it back on.

Flying shows a console along the bottom: the attitude ball between its
throttle and climb tapes, altitude, speed, the orbit, Δv, the live stage's
propellant, time warp, and the mission's legs as a route. **Systems** opens the
full telemetry, stages, autopilot programs and flight log. **M** opens the
space map, a flat view of the system from above the ecliptic. The 3D frame
stops rendering behind it. Scroll to zoom and drag to pan. Click a world to
follow it; right-click it to orbit or land there. The route card gives the
transfer's type, Δv, propellant, the wait for the window and the time en route.
**Fly mission** hands it to the autopilot. **Skip to arrival** charges the
propellant and the time and puts the craft in the parking orbit, without flying
the trajectory. See [missions](docs/physics/missions.md).

Press **Esc** during play for Settings;
its **Controls** tab lists the bindings and has **Quit to start** and **Quit app**.
Select a key in that tab to remap it. Keyboard bindings are saved between runs;
**Reset all bindings** restores the defaults.
The **Render** tab switches the spacetime mesh between a connected grid and
deforming dots. The **Mesh** button in Controls still shows or hides it.
It also offers Low, Medium, High and Ultra rendering presets. Tick **Advanced rendering
controls** to adjust resolution, black-hole lens detail, exposure and post-processing
individually. **Lighting detail** affects the local flight scene and craft studio:
Medium adds shadows and ambient occlusion; High also adds screen-space
indirect light and reflections in the craft studio. The flight view uses a
transparent render pass, where Godot does not support screen-space reflections.
These effects are not hardware ray tracing.

**Developer mode** (Settings › Controls, off by default and remembered between
runs) adds a **Dev** page for testing the flight without replaying a mission. Pick a
vehicle and a sequence (the pad in the count, max-Q, staging, MECO, orbit, the
Shuttle's deorbit, entry, peak heating, roll reversal, TAEM, approach, flare and
rollout, Starship's hot staging, belly-flop, flip and landing burn, Super Heavy's
return and tower catch, a Falcon 9 booster landing, the LM's descent, the sky
crane) and it jumps there: the state is built directly where it can be and flown on
by the real physics, undrawn, to that moment, usually within a few seconds. The page
also has pause, single-frame step, time warp past the normal interlocks, teleport to
an altitude and speed, the autopilot programs, forced staging, restart, the quality
tiers, and the labs (effects lab, model viewer, title shots). See
[flight scenarios](docs/flight-scenarios.md).
High rendering quality adds seven photo-style material textures to spacecraft
and launchpads, with subtle roughness and normal detail, a semi-gloss clearcoat
on painted skins and faint run-off weathering, and draws launch smoke as
raymarched volumes lit by the sun, sky and fire ([plumes](docs/physics/plumes.md)).
Ultra adds the display's full pixel density, finer cloud, plume and smoke
marches, soft (PCSS) sun shadows and full-quality ambient occlusion. It is a
heavy tier: about 20 fps for the launch scene on an M5 at 2× pixel density. The same set works on
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
In air a kerosene flame burns out within about a vehicle length and leaves a
grey smoke trail standing in the sky; the pad cloud is thrown out of both ends
of the flame trench. Above the dense air a plume swells to the radius where its
pressure meets the ambient plus the freestream's dynamic pressure, so a Saturn
V's first stage trails a billowing fire tens of metres across by staging. On the
pad, cryogenic tanks carry rime and vent cold vapour until liftoff, and the
ground round a coastal pad is lawn, scrub, sand and marsh
([plumes and smoke](docs/physics/plumes.md)).
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
| `title=hole\|launch\|jupiter` | hold the title on one reel shot (for screenshots); `title=0` shows it over the bare sky |
| `craft=saturnv\|falcon9\|shuttle\|starship` | select a launcher when starting flight mode |
| `scenario=shuttle:peak_heating` | jump straight into a flight scenario (`vehicle:id`, listed in [sim/flight/scenarios.gd](sim/flight/scenarios.gd)); with `frames=… out=…` the frames count from the hand-over, and an unknown or failed scenario exits 1 |
| `padaz=180 padel=-0.2` | rotate and lower the flight pad camera for a screenshot |
| `padmodels=0` | check the procedural launchpad fallback |
| `winds=1` | turn on Earth's climatological winds (Settings › Sim) for a run or a check |
| `sunview=1` | aim the final flight screenshot directly at the sun |
| `seed=7` | make the scenario's random choices reproducible |
| `quality=low\|medium\|high`, `lighting=low\|medium\|high` | rendering and local lighting presets |
| `band=5` | imaging band 0–6 |
| `focus=Earth`, `truescale=1`, `cammode=surface`, `localtime=noon` | camera and view |
| `frames=60 dt=0.0166 out=/abs/shot.png [hud=0] [shot3d=1]` | run N fixed steps, save a screenshot, quit |
| `program=ascent` | with `mode=flight`, start an autopilot program on the vehicle before the shot |
| `ff=alt:12000\|t:124\|event:staging` | before the `frames` steps, step undrawn until the vehicle crosses an altitude (m), until seconds after liftoff (stage seconds outside flight) or until a vehicle event containing the text (`staging` matches separations); `frames` then counts only the drawn frames that settle the picture |
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

`python3 tools/check.py` runs the fast headless suite. Checks that judge state
or numbers run `--headless`; only those that judge a rendered frame, read a GPU
result or must see a `SHADER ERROR` (printed on first render) open a window,
because headless Godot has no RenderingDevice. Under `--headless` the compute
passes (`render/rd_util.gd`) allocate and dispatch nothing; a check that needs
their output tests `RDU.available()` and fails. Godot activates itself
as each window opens. On macOS, `--background` returns focus to the app you
last used within about 50 ms of each activation. Checks keep rendering behind
other windows, but not minimized or on a hidden Space, so the fullscreen M5
gates reject it. Select additional suites,
for example `python3 tools/check.py fast native assets rendered lifecycle export`.
The runner retains child logs and a JSON report, rejects errors, timeouts and
missing completion markers, and starts nothing new after the first failure.
Use `--godot` to select an engine and `--log-dir` to retain results at a chosen location.
Every check reports its wall and CPU seconds; the run ends with a table, slowest
first, and `--compare /abs/old/report.json` flags any check over 1.25× and 5 s
slower than in that report. `--list` prints the plan without running it.
`--jobs N` runs up to N independent checks at once (default: the performance-core
count; `--jobs 1` runs them one after another). Each keeps its own log and timeout,
the longest start first, and results print and enter the report in suite order.
Nothing runs beside the `fast` import or any check in `perf`, `m5-*`,
`stability*`, `export` and `clean`; the `lifecycle` checks (one process per soak
feature, plus the leak and shutdown checks) run beside each other only. Other
checks' logged timings are taken under concurrent load.

While checks run, a terminal shows a live block: checks done of total, what is
running against its usual time and timeout, and an estimate of the time left
(learned from earlier passing runs). Piped output, such as an agent's, gets a
`PROGRESS` block every 30 s instead. A `WARN` line names a check nearing its
timeout, running well past its usual time, or silent for two minutes past it.
`python3 tools/check.py --watch` shows every run in progress in any worktree of
this clone, including one an agent started; `--status` prints it once.
### The fast path

For the inner loop, run what the change touches, headless, and replay whole
missions only when the change can alter flight:

- `python3 tools/check.py dev` (under a minute): the import, the fast numeric
  checks, the `skip_moon` mission and a short undrawn/drawn parity flight.
- `python3 tools/check.py --changed` runs only the checks covering files changed
  since `HEAD` (`--changed main` since the branch left `main`), from the mapping
  `CHANGED_RULES` in `tools/check.py`. Documentation selects nothing; a path no
  rule covers selects `dev`. Add suites to narrow it (`--changed flight`). A run
  that selects nothing exits 1, since nothing was verified.
- Missions are judged on their flown state, so they run headless and undrawn:
  `main.set_drawn(false, false)` steps physics, structural events and what physics
  reads, and skips body visuals, markers, trails, the HUD, plumes, smoke and the
  cameras. `missioncheck-parity-shuttle_fates` flies the same frames both ways and
  fails unless the final states are bit-identical (`inject_coupling=1` must fail).
- For a visual before/after, fast-forward instead of flying in real time:
  `Godot --path . -- mode=flight craft=falcon9 program=ascent ff=alt:12000 frames=20 hud=0 out=/abs/f9_12km.png`,
  or one process for a whole matrix with
  `res://tools/fxlab.tscn -- crafts=falcon9,shuttle alts=12000,30000 qualities=low,high views=20:0,90:10 out=/abs/dir`.
  The fast-forward keeps the smoke trail, plumes and pad simulating undrawn, so
  the settle frames only present them.

`assets` requires all nine generated craft models; `rendered`, `lifecycle` and
`perf` need a working graphical renderer. `flight` runs the four full launches (one process each), the descent gates (LM, sky crane, Falcon 9 boosters at three propellant loads, a Super Heavy tower catch at 1× and 2×, and a deorbit), the missions, one process per descent and per mission, and every developer
scenario (`scenariocheck`); `scenario-replay` compares each scenario with the same
flight played at 60 fps (about half an hour). `native` includes the numerical boundary checks.
`stability` runs the strict 60,000-year Trisolaris check. `stability-study` adds
three timestep refinements and five orientation probes. Both remain explicit
suites because of their runtime; the redesigned scenario passes the tested bounds
(see [scenario limits and results](docs/scenarios.md#trisolaris-hierarchical-initial-conditions)).
`compatibility` keeps the known strict frozen-reference differences failing.
Body motion uses conservative Newtonian pair gravity; relativistic visuals and
the illustrative tight-pair drag have separate limits described in
[the compact-dynamics model](docs/physics/compact-dynamics.md).

`python3 tools/check.py perf --repeat 3` records rendered scenario/editor/LOD
measurements (including authored launchpad/ascent), fixed-step CPU flight timings
and HUD shown/hidden timings. It also runs a frozen studio LOD comparison with
two ABBA cycles at each distance and distinct model-viewport timestamp batches.
See [the measurement contract and local results](docs/performance.md). Missing
GPU timestamps are reported as unavailable; these measurements are not portable
performance budgets.

`python3 tools/check.py m5-medium` applies the same frame budget to the full
native Medium preset (MSAA, lens detail 0.5). Both M5 gates need the fullscreen
Space visible on the built-in display; while it is hidden, macOS withholds
drawables and the watchdog fails the run.
`python3 tools/check.py m5-budget` runs the selected M5 Metal gate: native
3024×1964 scene targets, Low-based settings, MSAA disabled, lens detail 0.35,
native pixel scaling,
elapsed simulation steps, at least 30 mean FPS and p95 frame intervals within
33.33 ms. The HUD client/frame dimensions are recorded separately. See the performance
notes for the custom configuration and measured results.

Authored builds run a Blender primitive-winding check before publishing models,
then refresh Godot imports when the engine is available. This prevents checks
from measuring an older imported mesh after the source GLB changes.

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
Blender fidelity, graphical performance or device budgets. A Linux x86_64
Ubuntu clean-clone/native/export run passed locally under Docker emulation on
macOS; this establishes the functional platform contract, not Linux GPU costs.
An [actual three-platform CI run](https://github.com/XeIris/Astrarium/actions/runs/37246714048)
passed all 16 clean children per platform at `7773b7f`, including 190 numerical
checks, native invariants/parity, 64 save checks and isolated exported startup. Engine downloads now require
the pinned official SHA256 before extraction. Later revisions require their own
remote run; headless CI supplies no rendered frame budget.
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
| `tools/flightcheck.gd` + `flightref.mjs` | the eleven flight scenarios vs the JavaScript; rejects a descent that does not land inside its gear rating, a Super Heavy return that is not caught by the tower, and a deorbit that does not burn once and hand back. These three intentionally diverge from the frozen build, which fails them. So does `starship`: V3 Raptor 3s and propellant, where the frozen build flies V1; and `shuttle`, whose solids light at T−0 and whose first stage lofts to JSC-10559's staging state |
| `tools/flighttimecheck.gd` | forced vessel/frame guard exhaustion, elapsed clocks, site rotation, visual time, warnings and normal/rails branches |
| `tools/flightphysicscheck.gd` | launch-azimuth windows (Cape, Vandenberg, Baikonur), Lagrange points and halo periods, J2–J4 and the tesseral field (Earth's C22, GRAIL to degree 16) against −∇Φ, normalized Legendre values, the field turning with the body, ISS nodal regression under RK4 and rails, the F10.7 thermosphere against US76 and orbital decay against density, radio blackout from the equilibrium shock layer, a coast's flown extremes under J2, RK4 stages against a moving Moon, radiative heating, winds (air against ground velocity), Cd tables, the sky's multiple-scattering table, porkchop against Hohmann |
| `tools/build_sky_ms.py` | regenerates `sim/flight/sky_ms.gd`, Earth's multiple-scattering table and the sky gain (Hillaire 2020), from the sky dome's coefficients |
| `tools/build_lunar_gravity.py` | writes `sim/flight/lunar_gravity.gd`, the Moon's field to degree 16 from GRAIL's GL0420A (`jggrx_0420a_sha.tab`, PDS Geosciences; the first 64 KB suffice) |
| `tools/build_starcat.py` | builds `assets/sky/bsc5.bin` (the Yale Bright Star Catalogue, V < 6.5) for the `solar` sky from HEASARC's BSC5P table, or from a local copy given as its argument; rejects a parse of fewer than 9000 stars |
| `tools/spinframecheck.gd` | the flight frame's orientation: Earth's is J2000 equatorial (RA/Dec equal a site's longitude/latitude), the subsolar latitude follows the declination through the year, the Moon stays 18–29° from Earth's equator over a nodal cycle, and a rebase between poles keeps position and pointing |
| `tools/cloudcheck.gd` | the flight cloud field's opaque sky fraction against the world's `cloudCover`, and the climatology's clear subtropics, cloudy ITCZ and storm tracks (headless, on the CPU twin) |
| `tools/sharedtimecheck.tscn` | rendered production frame driver: shared world/flight coordinate clocks, guards, moving parents, rails fallback and cruise arrival; `assets=0` skips optional models; `bench=1` measures frame CPU time |
| `tools/sharedflightcheck.gd` | four powered launches through `Spaceflight.update()` with moving world bodies (`only=saturnv,shuttle` picks some); rejects clock divergence, missed orbit targets, an orbit more than 0.5° from the pad's latitude to Earth's IAU equator, a Saturn V whose S-II aft interstage does not drop within two frames of 29.8 s after the S-IC, and a Shuttle that does not stage within 1 km of 47.3 km and 2 s of T+124 s with max-q 30–35 kPa |
| `tools/missioncheck.tscn` | whole missions flown by the autopilot with no input: launch to Earth orbit, Earth orbit → lunar orbit, an LM landing, a skip to the Moon, a lone Starship from orbit through its own return (deorbit, belly-first entry, flip, landing burn inside 1 m/s), and a lone Shuttle orbiter from orbit to its main gear (deorbit, 40° entry with roll reversals, glide slopes, flare inside the gear's 2.9 m/s at 195–215 kt), and the Shuttle from Pad 39A to orbit and home (it waits for the deorbit opportunity that brings Kennedy within crossrange and lands within 10 km of the pad), and the Shuttle's dropped stages (`shuttle_fates`: each booster's recovery at the flown altitudes and speeds to splashdown, the tank to its breakup) (`long=1` adds Earth orbit → Mars orbit); rejects a mission that fails, stalls or ends in the wrong orbit. Runs `--headless` and undrawn; `drawn=1` presents every step; `parity=1 [frames=N]` flies each case undrawn and drawn and rejects any difference in the final state |
| `tools/sciencecheck.gd` | independent physical GW separation/SI values and live transit/RV/convergence checks, plus frozen photometry/pair selection; `-- compatibility=web` enforces obsolete contact-scaled GW readings and live trajectories, currently failing four intentional differences |
| `tools/skycachecheck.tscn` | rendered sky: the point-source cull must match an exhaustive walk pixel for pixel; the diffuse cache must stay within its stated error of live evaluation across bands, aberration and lensing. `timing=1` prints native-size frame medians, `reference=/abs/sky.gdshaderinc` requires the live sky to match another revision (e.g. from `git show`), `dump=/abs/dir` saves live/cached images and the cache atlas |
| `tools/skycost.tscn` | frame cost of each sky component (point tiers, dust, clusters, galaxies, nebulae, cache, constant sky) by editing the shader source; a renamed component fails. Options `preset=`, `band=`, `view=WxH`, `scale=`, `samples=` |
| `tools/lenscheck.tscn` | graphical GPU check of independent single-hole shadow size, horizon-scale invariance, finite fields and weak-field deflection |
| `tools/numericalcheck.gd` | requires native kernel; checks tiny forces, potentials, step caps, positive durations, orbital convergence and unsafe-update rollback in both implementations |
| `tools/nbodycheck.gd` | requires native kernel; checks bodies, mass, positions, velocities, spins, overflow, merger order, steps and integrated time against GDScript, with a `secular` case that exercises tides, winds and Roche-lobe overflow |
| `tools/secularcheck.gd` | the secular terms against their sources: Hut's tidal de/dt and da/dt, angular momentum with the spin, despin time, adiabatic widening under a wind, Eggleton's lobe and Hurley's overflow rate with mass and momentum kept, wind rates, nova ignition and accretion regimes, the ageing clock ([secular.md](docs/physics/secular.md)) |
| `tools/invariantcheck.gd` | collision mass/momentum, symmetric ordinary and black-hole pair forces, matching energy, and presentation-independent contact distances |
| `tools/stabilitycheck.gd` | requires native kernel; strict 60,000-year Trisolaris bounds and compensated accepted time; `years=<n>` selects a shorter probe; `max_step=<years>`, `step_divisor=2`, `world_rotation=<radians>` and `world_eccentricity=<e>` select separately marked diagnostics; `report=/abs/result.json` retains runtime/force metadata, exact double states and approximate orbital elements |
| `tools/transitioncheck.tscn` | rendered spin/remnant transitions and canonical black-hole horizons through mass sliders, edits and contact mergers; rejects stale progenitor measurements |
| `tools/structureinputcheck.tscn` | production spawn/edit/preset rejection before mutation, supported threshold events, and rejected-control resynchronization |
| `tools/accretioncheck.tscn` | rendered physical/visual boundary: separated bodies retain mass and momentum under visual updates, paused streams freeze, and physical contact mergers still conserve mass and momentum; `native=0` forces GDScript and `inject_mutation=1` must fail |
| `tools/crafttest.tscn` | vehicles: `audit()` heights/triangles, `clearance()`; `-- parity` requires all nine authored craft and asserts whole-vehicle height/base agreement within 2 cm in both poses; `inject_parity=1` must fail |
| `tools/assetcheck.gd` | authored rig contracts and articulation, or procedural parts with `assets=0`; every dropped stage must leave by its separation physics (`stage_separations`, `booster_pieces`), and a residual thrust must carry its stage its closed-form travel (`residual_push`); `inject_invalid=1` must fail on a missing driven part |
| `tools/savecheck.gd` | isolated JSON write/recovery failures, malformed controls/course/icon settings, binding conflicts and Reset rollback |
| `tools/sunlab.tscn` | the solar lab: the Sun alone with hand-placed active regions and one flare at a chosen phase, for the photosphere, loops and eruptions (`x=0.45` the flare's progress, `at=limb\|top\|disc` where it sits, `top` showing its loops side-on, `close=1` the camera on the region, `band=5` X-ray, `teff=` another star); `out=/abs/x.png frames=12` writes a picture |
| `tools/fxlab.tscn` | the effects lab: one vehicle held at an altitude and airspeed with the air streaming past, through the real flight renderer, for the plume, trail, condensation collars and re-entry plasma (`alpha=` holds the nose above the airflow, belly into it: `craft=shuttle stage=2 alt=70000 speed=7000 pitch=91 alpha=40 throttle=0`). Interactive with no arguments (sliders, `[ ]` vehicle, `1`–`4` stage); `crafts=a,b alts=10000,30000 out=/abs/dir` writes one picture per vehicle and altitude; `mode=fly` photographs a real ascent as it passes each altitude; `qualities=low,high` and `views=az:el[:dist],…` add a quality × camera matrix, each cell drawn at the same instant after an undrawn approach; `humidity=`, `speed=`, `pitch=`, `az=`/`el=`/`dist=`/`aim=` set the air and camera. Prints the shoulders it found for vapour |
| `tools/scenariocheck.tscn` | headless: jumps to every flight scenario and requires its declared altitude, speed, program, state and stages at the hand-over and a second of flight after it (`only=shuttle:taem,lm`); `replay=1` also flies each one as played at 60 fps from its base and requires agreement within the documented tolerance ([flight scenarios](docs/flight-scenarios.md)); `inject_bad=1` must fail |
| `tools/hudcheck.tscn` | the HUD: `hstate=<state> hout=/abs/x.png` screenshots a named state through fixed steps (`hcraft=<id>` picks the hangar's vehicle; `settings_dev`, `settings_dev_shuttle` and `scenario hscenario=<vehicle>:<id>` show the Developer page and a jump); `htest=1` clicks, drags, types and scrolls through the controls with real input events and checks the orchestrator's state follows; `hperf=1` times frames with the HUD shown and hidden |
| `tools/realismcheck.tscn` | the review's additions against independent numbers: the Page–Thorne disc (peak radius, efficiencies, far-field flux), tidal disruption radii and events (a star round a 10⁴ M☉ hole in fine and single steps, a moon becoming a ring, a neutron star fed past TOV), natal-kick statistics and Blaauw unbinding, the Budyko–Sellers ice line, snowball and hysteresis, overflow feeding a white dwarf, a nova, an accretion-driven Type Ia and a star's end by age, the runaway greenhouse's latent-heat ocean and Kopparapu's habitable zone, and that no preset loads with a body inside a disruption radius (headless) |
| `tools/editorcheck.tscn` | canonical inspector and graph invalidation, measured/tiny bodies, structural threshold crossings, and delayed edits across selection/removal/reused IDs |
| `tools/padcheck.gd` | rejects pad structure inside its vehicle at rest, an arm that touches it through the terminal count and liftoff (an arm carried by another, as the GOX vent hood is, moves with both), and anything (wires included) left in its ascent column; `padmodels=0` / `assets=0` select fallback pads / craft; `inject_intrusion=1`, `inject_fixed_arm=1` and `inject_late_arm=1` must fail |
| `python3 tools/exportcheck.py /abs/game.zip` | checks a `Godot --headless --path . --export-pack macOS /abs/game.zip` resource archive for development files, missing boot files and broken import/remap targets; native libraries and rendering still need an exported-app smoke run |
| `tools/reference_shots.py` | shared runner for `startest_all.sh`, `coursetest.sh` and `flightshots.sh`; rejects child/engine failures, timeouts, missing completion markers and missing/invalid captures; retains `reference-report.json`. `TIMEOUT=<seconds>` overrides each child deadline |
| `python3 tools/reference_shots_test.py` | failure-contract self-checks for the reference runners, without a renderer |
| `tools/webref.mjs` | screenshots of the web build (headless Chrome) for side-by-side checks; use `flightshots.sh` for validated flight captures |
| `tools/shots.sh` | screenshots of this build via the command-line options above |
| `eval=_leak_check` | loads all 35 scenarios and two launches five times; object/resource/node/orphan growth after warmup fails; VRAM is reported as telemetry |
| `eval=_soak_check` | repeats features with seeded initial conditions and asserts flat object/resource/node/orphan counts after warmup; the staged launch asserts ascent and three separations; `rounds=5` changes the default four rounds, `soak=model_viewer soakassets=0` checks all nine procedural craft; `soak=editor` exercises focused graphs and pending-edit removal |
| `--verbose ... eval=_shutdown_check` | drags render scale, opens a cutaway lesson, the model viewer and a launch, then quits; a clean run reports nothing leaked at exit |

The historical side-by-side migration evidence was archived out of the working
tree; `tools/ref/` now keeps the manifest and retention note.
