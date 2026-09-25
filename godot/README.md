# Astrarium, in Godot

This folder is a port of the whole web build — the relativistic orrery, the
astronomy course and the spaceflight simulator — to **Godot 4.7** and
**GDScript**. The web build at the repository root is the reference; this port
is checked against it frame for frame (see *Verifying* below). What the sim
models and why is in the root [README.md](../README.md); the engineering rules
both builds follow are in [CLAUDE.md](../CLAUDE.md); what is *different* about
Godot is in [PORT_GUIDE.md](PORT_GUIDE.md).

## Running it

You need Godot **4.7.x** (standard build — not the .NET one, and not a
double-precision build).

1. *(optional, once)* Put the authored vehicle meshes in the project. They are
   build artifacts of `assets/blender/*.py`, gitignored in both builds; without
   them every vehicle falls back to its procedural build, silently.
   ```sh
   assets/blender/build.sh           # at the repo root, needs Blender 4.1+
   godot/tools/sync_assets.sh        # copies assets/*.glb into godot/assets/craft/
   ```
2. Open `godot/project.godot` in the Godot editor and press **Play** (F5).
   The first open imports everything, which takes a minute.

Or from a terminal, without the editor UI:
```sh
/Applications/Godot.app/Contents/MacOS/Godot --path godot
```
Command-line options go after `--` and stand in for the web build's URL hash
and its `SIM` console handle:

| option | effect |
|---|---|
| `preset=vega` | start in a scenario (the web build's `#vega`) |
| `mode=sandbox\|learn\|flight` | skip the start screen |
| `seed=7` | make the scenario's random choices reproducible |
| `band=5` | imaging band 0–6 |
| `focus=Earth`, `truescale=1`, `cammode=surface`, `localtime=noon` | camera and view |
| `frames=60 dt=0.0166 out=/abs/shot.png [hud=0] [shot3d=1]` | run N fixed steps, save a screenshot, quit |
| `eval=_preset_check` | run a method of `main.gd` (checks, below) |

## Building the macOS app

The export preset is in `export_presets.cfg` (universal arm64 + x86_64,
ad-hoc signed). Install the export templates once — *Editor → Manage Export
Templates → Download and Install* — then:

```sh
cd godot
/Applications/Godot.app/Contents/MacOS/Godot --headless --export-release "macOS" build/Astrarium.app
open build/Astrarium.app
```

The app is signed ad hoc, which runs on the Mac that built it. On another Mac,
Gatekeeper will refuse it the first time: right-click → *Open*, or sign it with
a Developer ID (set `codesign/identity` and `notarization/*` in the preset, or
use *Project → Export…* in the editor). Sync the vehicle meshes **before**
exporting, or the app ships the procedural builds.

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
godot/native/build.sh              # needs only Xcode's command line tools
```

## Verifying

There is no test suite, as in the web build; there are checks.

| check | what it does |
|---|---|
| `tools/presetcheck.sh` | loads all 35 scenarios, runs a second of each, reports script/shader errors and lost bodies |
| `tools/coursecheck.tscn` | walks all 35 lessons / 108 steps in order (port of `.claude/coursecheck.js`) |
| `tools/physcheck.sh` | the interior model, presets, climate and integrator vs the JavaScript, number by number |
| `tools/flightcheck.gd` + `flightref.mjs` | the eleven flight scenarios vs the JavaScript |
| `tools/nbodycheck.gd` | native kernel vs the GDScript loop |
| `tools/crafttest.tscn` | vehicles: `audit()` heights/triangles, `clearance()` |
| `tools/webref.mjs` | screenshots of the web build (headless Chrome) for side-by-side checks |
| `tools/shots.sh` | screenshots of this build via the command-line options above |

`tools/ref/` holds the side-by-side evidence each part of the port was
accepted on.
