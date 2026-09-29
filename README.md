# Astrarium

The main version of Astrarium is a **Godot 4.7 / GDScript** relativistic orrery,
astronomy course, and spaceflight simulator. Open [project.godot](project.godot)
to run it. The original HTML/Three.js version is archived as a runnable project
in [web/](web/). Its [README](web/README.md) describes the physics and scenarios;
the shared engineering guidance is in [AGENTS.md](AGENTS.md), Godot-specific
decisions are in [PORT_GUIDE.md](PORT_GUIDE.md), and the port's verification
record is in [PORT_REPORT.md](PORT_REPORT.md).

## Running it

You need Godot **4.7.x** (standard build — not the .NET one, and not a
double-precision build).

1. *(optional, once)* Build the authored vehicle and launchpad meshes. They are
   build artifacts of `model_sources/blender/*.py` and are gitignored; without
   them the vehicles and launchpads use their procedural fallbacks.
   ```sh
   model_sources/blender/build.sh       # needs Blender 4.1+; 9 craft + 4 pads
   tools/sync_assets.sh                 # copies web/assets/*.glb into assets/craft/
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
an eight-step 3D cloud layer, subtle near-field atmospheric scattering and a
solar disc with an apparent diameter of about 0.53 degrees. Medium uses a
lighter cloud shader; Low skips clouds. Daylight exposure is calibrated in the
flight view, and the Advanced exposure slider gives manual control.
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
| `eval=_preset_check` | run a method of `main.gd` (checks, below) |

## Building the macOS app

The export preset is in `export_presets.cfg` (universal arm64 + x86_64,
ad-hoc signed). Install the export templates once — *Editor → Manage Export
Templates → Download and Install* — then:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --export-release "macOS" build/Astrarium.app
open build/Astrarium.app
```

The app is signed ad hoc, which runs on the Mac that built it. On another Mac,
Gatekeeper will refuse it the first time: right-click → *Open*, or sign it with
a Developer ID (set `codesign/identity` and `notarization/*` in the preset, or
use *Project → Export…* in the editor). Build the launchpad meshes and sync
the vehicle meshes **before** exporting, or the app uses procedural fallbacks.

## The native physics kernel

`native/` holds one small GDExtension, written in plain C against Godot's own
`gdextension_interface.h`: the N-body sub-step loop. GDScript runs that loop
~50–125× slower than the browser's JIT does, and the `solar` scenario needed
38 ms of physics per frame; the kernel does it in 0.1 ms, bit-identically
(`tools/nbodycheck.gd` proves both). The universal `.dylib` is **committed
prebuilt**, so nothing needs compiling to run or export. If it is missing, the
same GDScript loop runs instead — identical results, just slower. Rebuild after
editing `astrarium_native.c`:
```sh
native/build.sh                    # needs only Xcode's command line tools
```

## Verifying

There is no test suite, as in the web build; there are checks.

| check | what it does |
|---|---|
| `tools/presetcheck.sh` | loads all 35 scenarios, runs a second of each, reports script/shader errors and lost bodies |
| `tools/coursecheck.tscn` | walks all 35 lessons / 108 steps in order (port of `web/.claude/coursecheck.js`) |
| `tools/physcheck.sh` | the interior model, presets, climate and integrator vs the JavaScript, number by number |
| `tools/flightcheck.gd` + `flightref.mjs` | the eleven flight scenarios vs the JavaScript |
| `tools/nbodycheck.gd` | native kernel vs the GDScript loop |
| `tools/crafttest.tscn` | vehicles: `audit()` heights/triangles, `clearance()` |
| `tools/webref.mjs` | screenshots of the web build (headless Chrome) for side-by-side checks |
| `tools/shots.sh` | screenshots of this build via the command-line options above |
| `eval=_leak_check` | loads all 35 scenarios and two launches, five times over; object, resource, node and VRAM counts should stay flat |
| `--verbose ... eval=_shutdown_check` | drags render scale, opens a cutaway lesson, the model viewer and a launch, then quits; a clean run reports nothing leaked at exit |

`tools/ref/` holds the side-by-side evidence each part of the port was
accepted on.
