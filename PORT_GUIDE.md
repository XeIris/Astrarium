# Astrarium → Godot: the porting contract

This is the engineering contract for the Godot 4.7 project at the repository root.
The archived web build in `web/` remains a runnable reference. Read the repo's
`AGENTS.md` first. Its conventions are the
physics and the rendering rules, and they bind this port exactly as they bind
the web build. This file covers only what is **different** in Godot, and why.

The bar is a **side-by-side match**: the same scenario, camera and band gives
the same picture — same features, positions, colours and brightness, judged by
eye and by coarse luminance-grid diffs. Small shading or antialiasing
differences are acceptable. Missing features, wrong colours and wrong behaviour
are not.

---

## 1. Layout and naming

```
./
  project.godot  main.tscn  main.gd      orchestrator (port of blackhole_sim.js)
  core/          dvec3.gd (DVec3)  body.gd (Body)  u.gd (U: JS-compat helpers)
  render/        pipeline.gd  postfx.gd  lens_pass.gd  rd_util.gd  hook_effect.gd
  sim/           one .gd per sim/*.js, same base name, snake_case
  sim/flight/    one .gd per sim/flight/*.js
  shaders/       common/ sky/ lens/ post/ bodies/ flight/  (+ ui/ if needed)
  ui/            theme.gd, hud.gd, widgets/, panels/
  assets/        planet-maps/ (committed), craft/*.glb (build artifacts, synced)
  tools/         harness.gd + per-module harness scenes, webref.mjs, checks
```

* **One JS module → one GDScript file**, with the same base name
  (`sim/star_visual.js` → `sim/star_visual.gd`). Module-level exports become
  `static func`s and `const`s on a `class_name` script. Functions become
  snake_case (`structureOf` → `structure_of`, `createStarVisual` →
  `create_star_visual`).
* **`class_name`** is the module name in PascalCase. It must not collide with a
  Godot built-in class: `sim/sky.js` is `SkyModel`, not `Sky`, and
  `sim/painter.js` is `Painter`. Check with `ClassDB.class_exists()` if unsure.
* **JS factories that return closures become classes.** A GDScript lambda
  captures locals *by value at creation*, so the JS pattern `let n = 0;
  return { update() { n++ } }` silently breaks. Port the factory as
  `class Foo extends RefCounted` with member variables, and keep a static
  `create_foo(...)` that returns `Foo.new(...)`.
* **Object fields keep their JS names in snake_case** (`b.radiusScene` →
  `b.radius_scene`). Plain data (presets, specs, lesson steps, flare events)
  stays as `Dictionary` with the JS keys verbatim (camelCase keys are fine in
  data), because the course, the Foundry and the presets pass those around as
  data. `spec.get("mass")` for optional keys.
* **Comments are the documentation.** Port every derivation comment with the
  code, rewording only where the JS plumbing it described no longer exists.
  Match the density of the original. Do not summarise a header block into one
  line.

## 2. GDScript traps (every one of these has already produced a wrong number)

| JS | GDScript | why it matters |
|---|---|---|
| `1/2` | `1.0/2.0` | **Integer division.** `1/2 == 0` in GDScript. Write float literals in all physics. |
| `a ?? b` | `U.nz(a, b)` / `d.get(k, b)` | `get` only defaults a *missing* key |
| `if (arr.length)` | `if not arr.is_empty()` | an empty Array/Dictionary is **falsy** in GDScript, truthy in JS |
| `x.toFixed(2)` | `U.fixed(x, 2)` or `"%.2f" % x` | |
| `x.toExponential(1)` | `U.expo(x, 1)` | JS spelling: `5.0e-3` |
| `Math.round` | `U.jround` | JS rounds .5 up; `round()` rounds away from 0 |
| `Math.log10`, `Math.cbrt`, `Math.hypot` | `U.log10`, `U.cbrt`, `Vector2(a,b).length()` | |
| `%` on floats | `fmod` (sign of dividend, like JS) / `fposmod` | `%` is int-only |
| `Math.random()` | `randf()` | |
| `new THREE.Color(0xRRGGBB)` | `U.lin(0xRRGGBB)` | **colour management**, §5 |
| `THREE.MathUtils.smoothstep(x,a,b)` | `U.smooth(x,a,b)` | argument order differs from `smoothstep(a,b,x)` |
| `arr.splice(i,1)` | `arr.remove_at(i)` | |
| typed arrays | `PackedFloat32Array`, `PackedFloat64Array` … | |
| `obj.a?.b` | explicit null checks | |
| closures capturing mutable locals | class members | §1 |

## 3. Double precision and the floating origin

Godot's `Vector3`, `Transform3D` and every vertex position are **float32**.
The web build's `THREE.Vector3` physics was **float64**, because JS numbers
are doubles. This split drives most of the architecture.

* **Physics state is double.** `Body.pos/vel/acc` are `DVec3`
  (`core/dvec3.gd`): three GDScript floats, which are doubles. The flight
  model (`sim/flight/`) integrates in metres about a 6.4e6 m planet, and there
  float32 quantises position to 0.4 m, so its vectors are `DVec3` too. Never
  store a physics position in a `Vector3`.
* **Every renderer camera sits at the origin (rotation only).** Each frame the
  orchestrator decides the camera's absolute scene position `cam_pos` (a
  `DVec3`). It then places every object at `node.position = abs.rel_v3(cam_pos)`,
  doing the subtraction in double and truncating afterwards. The web build got
  this for free because THREE builds `modelViewMatrix` on the CPU in float64
  (AGENTS.md, "a body's vertex shader never forms an absolute world
  position"). Here it is structural: world space *is* camera-relative space,
  so every world-space shader quantity is small near the camera and the
  Sirius B lump-of-cubes failure cannot occur.
* **Consequences for shaders.** `CAMERA_POSITION_WORLD` is ~0.
  `MODEL_MATRIX[3].xyz` is the object's camera-relative position. A view vector
  is `normalize(-world_pos)`. Uniforms that were world positions in the web
  build (sun positions, hole positions) are passed camera-relative:
  `pos_rel = abs.rel_v3(cam_pos)`. Directions (normals, sun directions) are
  unaffected.
* **Keep far/near ≤ ~1e7 (measured), and move the NEAR plane to get there.**
  The web build's near-plane policy (`near = clamp(camDist·1e-3, 1e-7, 0.01)`,
  `far = 1e5`) reaches a ratio of 1e11 when framing Proxima or Sirius B at
  true scale. THREE draws that fine; Godot derives its culling frustum from the
  projection in float32, the planes degenerate (`create_frustum_points` errors;
  measured: 1e8 already fails every frame) and whatever is framed is culled.
  Clamping `far` alone culls the rest of the system instead (the spacetime
  mesh vanished from true-scale views). So main.gd moves the near plane out:
  `near = clamp(camDist·0.05, 1e-7, 0.01)`, `far = min(1e5, near·1e7)`. That
  is safe because Godot's depth buffer is reverse-Z float, whose precision
  does not depend on the near plane the way the web build's 24-bit integer
  depth did — the 1e-3 there bought depth resolution, not visibility — and the
  framed body's surface sits at 6/7 of the viewing distance, far outside 5%.
* **Frame order.** physics → camera (final `cam_pos` for the frame) → place
  every node → visual `update()`s → markers → `pipeline.prepare_frame()`. A
  visual therefore sees this frame's camera. (The web build ran visual
  updates before the camera follow; the one-frame difference is invisible, and
  placing nodes before the camera moves would jitter every followed body.)

## 4. The render pipeline (render/pipeline.gd). Read it; don't reimplement it

```
hook_vp (compositor callback = the post chain)
 ├─ scene_vp   the orrery world. Background = sky shader (sky or lens resolve)
 │   └─ temp_vp   SAME world, second camera: the temperature pass (§6)
 ├─ local_vp   spaceflight's metre-scale world, transparent background
 └─ model_vp   the model viewer's studio
display (TextureRect) ← 8-bit composite (PostFX.final_tex)
```

* Put orrery objects under `pipe.world_root`, flight objects under
  `pipe.local_root`, and studio objects under `pipe.model_root`.
* **Godot's tonemapper, glow, exposure, SSAO and fog are off everywhere**
  (`RenderPipeline.neutral_env()`). `render/postfx.gd` (bloom + ACES +
  vignette + grain + dither) is the one tone curve, as `sim/postfx.js` was.
  Emitters write HDR values well above 1, as before.
* The **sky** is `shaders/sky/background.gdshader`, a Godot sky shader drawn
  behind all opaque geometry. It includes `shaders/sky/sky.gdshaderinc`, the
  port of `SKY_GLSL`. With a hole present it resolves the lens marcher's output
  (`render/lens_pass.gd` + `shaders/lens/lens_march.glsl`, a compute shader).
* Fullscreen passes are **GLSL 450 compute shaders** (`#[compute]` files,
  imported as `RDShaderFile`), dispatched on the render thread through
  `RDU` (`render/rd_util.gd`). The web build's fragment passes port almost
  verbatim: `gl_FragColor` → `imageStore`, `vUv` → `(p+0.5)/size`. Use `RDU`
  rather than hand-rolled RD code.
* **Measured facts this relies on** (probe run before any of it was written):
  a SubViewport renders before the viewport that contains it, and this is
  frame-exact. Compute dispatched from `_process` through
  `RenderingServer.call_on_render_thread` runs before this frame's viewports
  draw. A `use_hdr_2d` viewport with the linear tonemapper returns linear
  values above 1, unclamped. `dFdx` works in sky shaders. `CAMERA_VISIBLE_LAYERS`
  works in spatial shaders.

## 5. Colour management

three r160 has `ColorManagement.enabled = true`, so:

* `new THREE.Color(0xRRGGBB)`, `color.setHex()`, `setClearColor(hex)`, and
  material `color: 0x…` are **sRGB → converted to linear**. In Godot use
  `U.lin(hex)` for values set from script, or declare the uniform
  `uniform vec3 u_color : source_color;` and pass `Color.hex(...)`, which Godot
  converts on the GPU. Pick one: don't do both.
* `new THREE.Color(r, g, b)` from **floats** is **not** converted. The Planck
  fit `Stellar.blackbody_color` is one of these. Pass such colours raw, with no
  `source_color` hint.
* `CanvasTexture` pixels (the web build's radial-gradient glow sprites, the
  flash sprites) are `NoColorSpace`: the hex values are sampled **as linear**
  and never decoded. Port those gradients as shader math on the raw values
  (`U.raw(hex)`), not as sRGB.
* Textures from files (planet maps, glTF base colour) are sRGB and decoded;
  Godot's importer and `source_color` samplers do the same.
* `color.getHexString()` for CSS (sun-list dots) is linear → sRGB: `U.css_of(c)`.

## 6. Shaders: GLSL ES → gdshader, and the temperature pass

### Translation

| three.js GLSL | gdshader (spatial) |
|---|---|
| `position`, `normal`, `uv` (vertex) | `VERTEX`, `NORMAL`, `UV` |
| `gl_Position = projectionMatrix*modelViewMatrix*vec4(p,1)` | set `VERTEX = p` (model space); Godot multiplies |
| `normalize(normalMatrix*normal)` | `NORMAL` in `fragment()` (view space), or `MODELVIEW_NORMAL_MATRIX * NORMAL` in `vertex()` |
| `modelMatrix`, `viewMatrix`, `cameraPosition` | `MODEL_MATRIX`, `VIEW_MATRIX`, `CAMERA_POSITION_WORLD` (≈0, §3) |
| `varying` | `varying` (declare at top; write in `vertex()`, read in `fragment()`) |
| `gl_FragColor = vec4(c, a)` | `ALBEDO = c;` with `render_mode unshaded`, plus `ALPHA = a` **only if transparent** |
| `gl_FragCoord`, `gl_PointCoord`, `gl_PointSize` | `FRAGCOORD`, `POINT_COORD`, `POINT_SIZE` (works, no flag needed) |
| `texture2D` | `texture` |
| `side: DoubleSide` / `BackSide` | `render_mode cull_disabled` / `cull_front` |
| `depthWrite: false` / `depthTest: false` | `depth_draw_never` / `depth_test_disabled` |
| `renderOrder` | `material.render_priority` (it sorts within opaque/transparent lists only, as three's did; AGENTS.md) |
| `precision highp float;` | delete |

* **Writing `ALPHA` makes a material transparent**, even if the value is 1.0.
  An opaque web material must not write `ALPHA`.
* Every body shader in this sim does its own lighting from uniforms, so it is
  `render_mode unshaded`. Only the flight/studio vehicles and the cutaway use
  Godot's lighting.
* gdshader is strict about int/float mixing, as GLSL ES was. Reserved words
  also differ from GLSL, so rename on a compile error.
* **Float literals below ~1e-14 compile to 0.0 in a gdshader.** Godot re-prints
  each constant into the generated GLSL in fixed notation, so `1e-16`, `1e-24`
  and `1e-30` reach the GPU as zero. A floor like `max(x, 1e-24)` then stops
  flooring and divides by zero. Measured: this produced NaNs on the photon
  ring, which the bloom spread into black rectangles. Spell such constants as bit
  patterns, `uintBitsToFloat(0x179abe15u)` for 1e-24 (see
  shaders/sky/sky.gdshaderinc). Compute `.glsl` files are compiled directly and
  are not affected. Note too that `isnan()`/`isinf()` checks are unreliable on
  the Metal backend's fast math. Test the bits
  (`floatBitsToUint(x) & 0x7fffffffu) >= 0x7f800000u`) when debugging.
* gdshader has no mutable globals (only `const`/`uniform`/`varying` outside
  functions). A GLSL module-level variable that one function sets and another
  reads (the sky's `sky_D`) has to become an explicit parameter.
* Uniform arrays: `uniform vec3 a[4];` set from script with a
  `PackedVector3Array` of exactly that length.

### Blending: three → Godot (measured)

| three.js | Godot | arithmetic |
|---|---|---|
| opaque | (default) | replace |
| `NormalBlending` (transparent) | `blend_mix` | c = s·a + d·(1−a) |
| `AdditiveBlending` | `blend_add` | c = s·a + d |
| `CustomBlending` ONE,ONE (color) | `blend_premul_alpha` with `ALPHA = 0` | c = s + d |
| "add colour, REPLACE alpha" (flare plasma) | `blend_premul_alpha`: `ALPHA=0` in colour pass, `ALPHA=1` in temp pass | |

### The temperature pass (read this if your shader emits light)

The web build encoded each emitter's true temperature as
`a = ln(T)/25.33` (clamped ≤ 0.98) and wrote it into the **alpha** of the HDR
buffer. `1.0` means "no data, infer T from colour", and `SKY_ALPHA = 0.995`
means "sky, already imaged in this band". Godot cannot write arbitrary alpha
from an opaque shader, so **the same world is drawn a second time** by
`temp_cam`, whose cull mask carries layer 20 (`TEMP_LAYER_BIT`). No object is
on that layer. Every shader in the orrery (and flight) world must:

```glsl
#include "res://shaders/common/temp_pass.gdshaderinc"
...
void fragment() {
    ... compute colour exactly as the web build did ...
    if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
        ALBEDO = vec3(<R>, 0.0, 0.0);   // and ALPHA as below
    } else {
        ALBEDO = colour;
    }
}
```

`<R>` reproduces, in R, what the web build's blend did to **alpha**:

| web material | what it wrote to alpha | temp-pass output |
|---|---|---|
| opaque emitter | `temp_code(T)` | `ALBEDO.r = temp_code(T)` |
| opaque non-emitter | 1.0 | `ALBEDO.r = TEMP_NO_DATA` |
| NormalBlending, alpha `a` (alpha eq. ONE, 1−a) | a + d(1−a) | `ALBEDO.r = 1.0; ALPHA = a` (blend_mix) |
| AdditiveBlending, alpha `a` (alpha eq. SRC_ALPHA, ONE) | a·a + d | `ALBEDO.r = a; ALPHA = a` (blend_add) |
| flare plasma (replace alpha) | `temp_code(T)` | `ALBEDO.r = temp_code(T); ALPHA = 1.0` (blend_premul_alpha) |
| absorption pass (leaves alpha alone) | — | `discard;` |
| marker (alpha MAX) | max(d, code) | `ALBEDO.r = 0; ALPHA = 0` (premul): a no-op, since d is almost always SKY_ALPHA ≥ code |

The temperature pass only renders when the band is not visible light, so it
costs nothing in the visible. Test your emitter in band 6 (X-ray) against the
web build.

## 7. The body visual contract

```gdscript
# create_body_visual(b: Body, opts: Dictionary) -> visual object with:
var group: Node3D            # added under pipe.world_root by the orchestrator
func update(dt: float, ctx: Dictionary) -> void
# plus whatever the web viz object exposed (core, mat, R, baseR, isHole → is_hole …)
```

The orchestrator owns `group.position` (the floating origin) and
`group.scale` (size ease, oblateness). A visual must put its own offsets on
inner nodes. This is the AGENTS.md rule "a stage builder must not write to
its own group's transform", one level up. `ctx`:

| key | meaning |
|---|---|
| `holes` | `[{pos_rel: Vector3, rs_scene: float, mass: float}]` camera-relative |
| `camera` | the Camera3D (at the origin; its basis is the view orientation) |
| `cam_pos` | `DVec3`, the camera's absolute scene position |
| `time` | wall-clock seconds accumulated (`state.time`) |
| `scene_scale` | scene units per AU |
| `sim_dt` | years integrated this frame |
| `suns` | `[{body, pos_rel: Vector3, color: Color (linear), intensity, dist_au, ang_radius, ang_true}]` |
| `climate` | the home world's `Climate` or null |
| `bodies` | all bodies |
| `viewport_h` | logical viewport height in px (the web build's `innerHeight`) |

`b.scene_pos` (`DVec3`) is the body's absolute scene position, which is what
the web build called `b.viz.group.position`.

## 8. UI

HTML/CSS becomes Godot `Control` nodes, styled by `ui/theme.gd` from the
CSS's own variables (`--panel`, `--accent`, …). The font is a `SystemFont`
with the CSS stack (`JetBrains Mono, SF Mono, Menlo, monospace`). Panels have
the CSS's `backdrop-filter: blur`, done as a screen-texture blur shader. Sizes
are in **CSS px = Godot logical px**: the window's `content_scale_factor` is
the display scale, exactly as a browser's devicePixelRatio. Canvas-2D
drawings (climate chart, cross-section, mass curve, instruments, navball)
become `Control._draw()` overrides using the same arithmetic.

## 9. Verification

* **Harnesses.** `tools/harness.gd` is a base class that brings up the real
  pipeline, a fixed-step clock, the orbit camera and a screenshot. Extend it
  per module (see `tools/pipeline_test.gd`) and run:
  `/Applications/Godot.app/Contents/MacOS/Godot --path . res://tools/x.tscn -- out=/abs/x.png frames=30`
  (the process quits by itself after writing the file; run it in the background
  and wait, because a window opens).
* **Reference frames from the web build.** `node tools/webref.mjs shots.json outdir/`
  drives headless Chrome over the web build and writes PNGs. See its header
  for the shot format. Set `PORT=<unique>` if several run at once.
* **Numbers before pictures.** Pure modules (physics, structure, flight) are
  verified numerically: run the JS in Node (stub `three` with a tiny Vector3/
  Color/MathUtils), run the GDScript headless
  (`Godot --headless --path . --script res://tools/x.gd`), and compare.
* **Script errors.** `Godot --headless --path . --import` then
  `Godot --headless --path . --quit` surfaces parse errors. Shader compile
  errors appear on first render as `SHADER ERROR` lines, so grep the output.

## 10. Working rules for parallel porting

* Own your files; do not edit anyone else's. `core/`, `render/`,
  `project.godot` and this guide are shared. If you need a change there, make
  the smallest additive change and **report it**.
* Commit your work to your branch when done (no push). The orchestrator
  (`main.gd`) is written separately against the APIs you report. So report
  **every public function and signal** you expose, with its signature, and
  anything you could not match.
