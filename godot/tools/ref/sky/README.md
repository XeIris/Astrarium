# Sky / surface-view parity evidence

Web build (`web_*`) against the Godot port (`godot_*`), same camera, fov, band
and resolution (1280×720, render scale 1). Everything is rendered at full size.
The files here are **1:1 centre crops** (480×270, to show the PSF itself). The
surface views are the exception: they are smooth, so they are stored as the
**whole frame at half scale**. `sbs_*` are half-scale full frames, web on the
left.

| set | web source | Godot source |
|---|---|---|
| `disc_b0…b6`, `core/globular/halo/starburst_b3`, `core_b2`, `globular_b5`, `disc_b3_yaw0`, `disc_b3_up` | `.claude/skytest.html` (`aim`, `setEnv`, `setBand`) | `tools/skytest.tscn` `band= env= yaw= pitch=` |
| `beta09_*` (observer boost v = 0.9c along −Z) | skytest.html, `U.uBeta.value.set(0,0,-0.9)` | skytest `beta=0,0,-0.9` |
| `lens_{bhmerger,sandbox}_b{3,5,0}` (disc intensity 0, scene emptied: the lensed sky alone) | `blackhole_sim.html#preset` | skytest `lens=state/<name>.json` (real marcher) |
| `surface_{noon,dusk,ground,night}_b3`, `surface_noon_b2` (Trisolaris, scene emptied) | `SIM.setCamMode('surface')`, `SIM.stage.setLocalTime(…)` | skytest `surface=state/<name>.json` |

`state/*shots.json` are the `godot/tools/webref.mjs` shot lists (they use its
`page` and `dump` fields). `state/<name>.json` are the web state dumps the lens
and surface modes replay. The surface dumps also carry the web sky pass's own
uniforms, and skytest prints its own values against them (`surface:` lines).

Luminance-grid difference (16×9 block means, 0–255), mean / max:

| shots | mean \|Δ\| | max |
|---|---|---|
| plain sky, 7 bands × disc, 4 other environments, 3 boosted | 0.01 – 0.13 | 1 |
| lensed sky, 2 presets × 3 bands | 0.03 – 0.36 | 4 |
| surface view, 5 shots | 1.2 – 1.8 | 4 |

The surface residual is the eye-adaptation exposure. The web page keeps easing
it in its own rAF frames between the capture and the dump, so the value the
Godot side replays is a frame or two later than the one the web shot used.
