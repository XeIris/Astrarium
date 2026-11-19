# Authored 3D models

`blender/` contains editable Python sources for ten spacecraft, four launch
complexes, site facilities and observatories. `lib.py` supplies geometry
primitives; `common.py` supplies materials, optimisation and glTF export.
The generated GLBs are ignored build artifacts.

From the repository root:

```sh
model_sources/blender/build.sh              # all authored models → assets/
model_sources/blender/build.sh shuttle lm   # selected spacecraft
model_sources/blender/build.sh evapod       # exterior and separate cockpit
```

Use Blender 4.1+ and Godot. The build exports the vehicle catalogue from Godot,
so the scripts read their dimensions and rig counts from the runtime data.
`BLENDER_OVERRIDE` and `GODOT` can name executables outside PATH.

Godot uses procedural spacecraft and launch-complex fallbacks when generated
models are absent. `tools/sync_assets.sh /absolute/source` optionally copies
models built elsewhere. See [the authoring contract](blender/AGENTS.md) and
[the EVA pod's references and interior pipeline](../docs/eva-pod.md).
