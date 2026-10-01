# Godot engineering notes

Reference for the render pipeline, precision, colour and shader contracts. The
rules every change must follow are in the root [AGENTS.md](../AGENTS.md).

## Layout and naming

```
main.gd        orchestrator: state, spawning, physics stepping, camera, UI bindings
core/          DVec3, Body, SimState, VisualCtx, VisualOpts, U (helpers)
render/        pipeline.gd, postfx.gd, lens_pass.gd, rd_util.gd, hook_effect.gd
sim/           one domain per file; sim/flight/ is spaceflight
shaders/       common/ sky/ lens/ post/ bodies/ flight/ ui/
ui/            theme.gd, hud.gd, control_bindings.gd, widgets/
tools/         harness.gd, per-module harness scenes, checks
```

- Modules are `class_name` scripts with `static func`s and `const`s. The name
  must not collide with a Godot class (`SkyModel`, not `Sky`); check with
  `ClassDB.class_exists()`.
- A factory that would return a closure is a `RefCounted` inner class with a
  static `create_foo()`: GDScript lambdas capture locals by value.
- Plain data (presets, specs, lesson steps, flare events) is `Dictionary` with
  camelCase keys, since the course, Foundry and presets pass it around as data.
  Use `spec.get("mass")` for optional keys.

## GDScript traps

| trap | use |
|---|---|
| `1/2 == 0` | float literals in all physics |
| `d.get(k, b)` only defaults a missing key | `U.nz(a, b)` for null |
| empty Array/Dictionary is falsy | `is_empty()` |
| `round()` rounds .5 away from 0 | `U.jround` |
| `%` is int-only | `fmod` / `fposmod` |
| `smoothstep(a, b, x)` argument order | `U.smooth(x, a, b)` |
| number formatting | `U.fixed(x, n)`, `U.expo(x, n)` |
| `log10`, `cbrt` | `U.log10`, `U.cbrt` |

## Double precision and the floating origin

`Vector3`, `Transform3D` and vertex positions are float32.

- Physics state is `DVec3` (three doubles). `sim/flight/` integrates in metres
  about a 6.4e6 m planet, where float32 quantises to 0.4 m, so it uses `DVec3`
  too.
- Every camera sits at the origin (rotation only). Each frame the orchestrator
  picks the camera's absolute position `cam_pos` and places every node at
  `abs.rel_v3(cam_pos)`, subtracting in double. World space is camera-relative:
  `CAMERA_POSITION_WORLD` ≈ 0, `MODEL_MATRIX[3].xyz` is the camera-relative
  position, and a view vector is `normalize(-world_pos)`. Uniforms that are
  positions (suns, holes) are passed camera-relative; directions are unaffected.
- Keep far/near ≤ ~1e7 by moving the near plane: `near = clamp(camDist·0.05,
  1e-7, 0.01)`, `far = min(1e5, near·1e7)`. Godot builds its culling frustum in
  float32, and at 1e8 the frustum degenerates and the framed body is culled.
  Reverse-Z float depth makes a far-out near plane safe.
- Frame order: physics → camera → place nodes → visual `update()`s → markers →
  `pipeline.prepare_frame()`. A visual sees this frame's camera.

## Render pipeline (`render/pipeline.gd`)

```
hook_vp (compositor callback = the post chain)
 ├─ scene_vp   the orrery world; background = sky shader (sky or lens resolve)
 │   └─ temp_vp   same world, second camera: the temperature pass
 ├─ local_vp   spaceflight's metre-scale world, transparent background
 └─ model_vp   the model viewer's studio
display (TextureRect) ← 8-bit composite (PostFX.final_tex)
```

- Orrery objects go under `pipe.world_root`, flight under `pipe.local_root`,
  studio under `pipe.model_root`.
- Godot's tonemapper, glow, exposure, SSAO and fog are off everywhere
  (`RenderPipeline.neutral_env()`). `render/postfx.gd` (bloom, ACES, vignette,
  grain, dither) is the only tone curve.
- The sky is `shaders/sky/background.gdshader` including `sky.gdshaderinc`. With a
  hole present it resolves the lens marcher (`render/lens_pass.gd` +
  `shaders/lens/lens_march.glsl`).
- Fullscreen passes are GLSL 450 compute shaders (`#[compute]`, imported as
  `RDShaderFile`), dispatched on the render thread through `RDU`
  (`render/rd_util.gd`). Use `RDU` rather than hand-rolled RD code.
- Measured behaviour this relies on: a SubViewport renders before the viewport
  containing it, frame-exact. Compute dispatched from `_process` via
  `RenderingServer.call_on_render_thread` runs before this frame's viewports
  draw. A `use_hdr_2d` viewport with the linear tonemapper returns unclamped
  linear values. `dFdx` works in sky shaders, and `CAMERA_VISIBLE_LAYERS` works
  in spatial shaders.

## Colour management

- Hex colours are sRGB. From script use `U.lin(hex)`, or declare
  `uniform vec3 c : source_color;` and pass `Color.hex(...)`. Don't do both.
- Colours computed as floats (e.g. `Stellar.blackbody_color`) are already linear:
  pass them raw, with no `source_color`.
- Glow and flash sprite gradients are raw values sampled as linear
  (`U.raw(hex)`), not sRGB.
- Texture files (planet maps, glTF base colour) are sRGB and decoded by the
  importer / `source_color` samplers.
- Linear → CSS-style hex for UI swatches: `U.css_of(c)`.

## Blending

| effect | Godot | arithmetic |
|---|---|---|
| opaque | default | replace |
| normal transparency | `blend_mix` | s·a + d·(1−a) |
| additive | `blend_add` | s·a + d |
| pure add (ONE, ONE) | `blend_premul_alpha`, `ALPHA = 0` | s + d |
| add colour, replace temperature (flare plasma) | `blend_premul_alpha`: `ALPHA = 0` in the colour pass, `ALPHA = 1` in the temp pass | |

## The temperature pass

Each emitter's true temperature is encoded as `a = ln(T)/25.33` (≤ 0.98) and
drives the non-visible bands. `1.0` means "no data, infer T from colour", and
`SKY_ALPHA = 0.995` means "sky, already imaged in this band". An opaque Godot
shader can't write arbitrary alpha, so `temp_cam` draws the same world a second
time with cull-mask layer 20 (`TEMP_LAYER_BIT`) and every shader writes the code
into R:

```glsl
#include "res://shaders/common/temp_pass.gdshaderinc"
void fragment() {
    if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
        ALBEDO = vec3(<R>, 0.0, 0.0);   // and ALPHA as below
    } else {
        ALBEDO = colour;
    }
}
```

| material | temp-pass output |
|---|---|
| opaque emitter | `ALBEDO.r = temp_code(T)` |
| opaque non-emitter | `ALBEDO.r = TEMP_NO_DATA` |
| normal transparency, alpha `a` | `ALBEDO.r = 1.0; ALPHA = a` (blend_mix) |
| additive, alpha `a` | `ALBEDO.r = a; ALPHA = a` (blend_add) |
| flare plasma | `ALBEDO.r = temp_code(T); ALPHA = 1.0` (blend_premul_alpha) |
| absorption pass | `discard;` |
| marker | `ALBEDO.r = 0; ALPHA = 0` (premul no-op) |

The pass only renders outside visible light, so it costs nothing there.

## The body visual contract

```gdscript
var group: Node3D            # added under pipe.world_root by the orchestrator
func update(dt: float, ctx: VisualCtx) -> void
```

The orchestrator owns `group.position` (floating origin) and `group.scale`
(size ease, oblateness). `b.scene_pos` (`DVec3`) is the body's absolute scene
position.

`VisualCtx` (`core/visual_ctx.gd`) is a typed class, so a misspelt field is a parse
error rather than a silent null.

| `ctx` field | meaning |
|---|---|
| `holes` | `[VisualCtx.Hole]` (`body, pos_rel, pos_abs, rs_scene, mass`), heaviest first |
| `camera` | the Camera3D (at the origin; its basis is the view) |
| `cam_pos` | `DVec3`, the camera's absolute scene position |
| `time` | wall-clock seconds accumulated |
| `scene_scale` | scene units per AU |
| `sim_dt` | years integrated this frame |
| `suns` | `[VisualCtx.Sun]` (`body, pos_rel, pos_abs, color` (linear)`, intensity, dist_au, ang_radius, ang_true`), brightest first; `state.suns` is the same list |
| `climate` | the home world's `Climate`, or null |
| `bodies` | all bodies |
| `viewport_h` | logical viewport height in px |

## UI

Controls are styled by `ui/theme.gd`. Sizes are logical px, with the window's
`content_scale_factor` as the display scale. Panels blur what's behind them
with a screen-texture shader. Charts, the cross-section, instruments and the
navball are `Control._draw()` overrides.

## Harnesses

- `tools/harness.gd` brings up the real pipeline, a fixed-step clock, the orbit
  camera and a screenshot. Extend it per module (see `tools/pipeline_test.gd`):
  `Godot --path . res://tools/x.tscn -- out=/abs/x.png frames=30`. A window
  opens and the process quits after writing, so run it in the background.
- Pure modules (physics, structure, flight) are checked numerically, headless:
  `Godot --headless --path . --script res://tools/x.gd`.
