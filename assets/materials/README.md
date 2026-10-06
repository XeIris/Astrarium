# Flight material set

These seven generated material photographs are the albedo layer used by the
Godot **High** rendering preset. `sim/flight/material_detail.gd` assigns them by
material name to every authored GLB, procedural craft fallback, and launchpad.
Triplanar projection is needed because the Blender build and procedural meshes
do not share UVs. The preset also adds a small procedural normal and roughness
variation; it restores the original materials when High is turned off.

| Image | Surfaces |
|---|---|
| `painted-skin.png` | painted hull, markings, tower paint |
| `brushed-metal.png` | steel, aluminum, nozzles, exposed pad metal |
| `ceramic-tiles.png` | thermal protection tiles |
| `thermal-foam.png` | insulation and ablators |
| `gold-insulation.png` | gold thermal blankets |
| `solar-cells.png` | photovoltaic panels |
| `launch-concrete.png` | hardstand, flame trench, scorched concrete |

The colour textures are shared material references, not scans of specific
vehicles. Emissive and glass surfaces retain their authored treatment. The
images are committed source assets; the `.png.import` files enable mipmaps for
distance views. Rebuilding the GLBs does not bake these textures into them.
