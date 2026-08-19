# Astrarium — performance findings and the native-port question

A handoff document. It exists so a cold session can pick this up without
re-deriving anything: what was researched, what was measured, what was built,
**which earlier claims turned out to be wrong**, and what a Godot port would
actually involve.

Everything numeric here was measured on an Apple M5, Chrome/ANGLE Metal
backend, unless labelled an estimate. Two different resolutions appear —
1920×1080 for the research-phase numbers and 1280×720 for the implementation
numbers — so always read the resolution before comparing two figures.

Work lives on branch `perf/tier1-shader-culling`:

| commit | what |
|---|---|
| `570f36a` | Tier 1 — per-band sky culling, render-scale default, antialias off |
| `48039d1` | Tier 2 — split the lens pass, march at half scale, resolve sky at full |
| `c568d3c` | `desktop/` Electron shell + what the GPU profiling found |

---

## 1. Origin

The question was: **migrate off Three.js to something native, or optimise the
existing stack?** Two research agents were run *blind to each other* to avoid
anchoring — one arguing the migration case, one arguing the stay-on-web case.
Neither was told the other existed.

The most trustworthy signal in the whole exercise is where they **independently
converged**:

- Both identified `sim/sky.js` as the real hot spot, **not** `sim/blackhole.js`.
  One got there by counting (~90–117 cell evaluations per pixel), the other by
  measuring (19 ms of a 43 ms frame).
- Both flagged the same redundancy: `sky_cube` / `sky_toGrid` recomputed 5+
  times per pixel across `sky_clusterField`, `sky_galaxies`, `sky_snr`,
  `sky_compact` and the star loop.
- Both concluded the N-body physics is a non-issue (measured <2 ms p90).
- Both concluded **f64 is a red herring** — see below, it's the single most
  important negative finding in the migration report.

---

## 2. Migration research — key findings

### 2.1 Codebase composition (measured, not estimated)

| category | lines | where |
|---|---|---|
| GLSL inside template literals | **~2,074 (27%)** | sky 736, blackhole 345, skyview 212, star_visual 176, world 157, spectrum 142, neutron 130, postfx 119 |
| Pure logic, zero graphics API | ~1,000 | physics, stellar, presets, climate, spectrum's JS half |
| Three.js-coupled orchestration | ~2,600 | `blackhole_sim.js` 1,483, bodies, the visual modules' JS halves |
| HTML/CSS UI | ~500 | 62 `id=` hooks + 290 lines CSS |

The porting payload is much smaller than the 7,668-line total suggests. The
physics is ~200 lines with only **5** `THREE.` references.

### 2.2 The shaders are GLSL ES **1.00**, not 3.00

This was unanticipated and it matters. Everything uses `gl_FragColor` /
`texture2D`, and `sim/blackhole.js` opts into `derivatives` — the WebGL1-era
extension. Visible scars:

- `MAX_HOLES = 2` and `MAX_SUNS = 4` are **compile-time template-string
  constants**, because ES 1.00 needs constant loop bounds and constant-size
  uniform arrays. Raising either means recompiling every program.
- Every variable-count loop is the `for(k=0;k<MAX;k++){ if(k>=n) break; }` idiom.
- No bitwise ops, so hashes are the `fract(sin(·))` family — an integer PCG hash
  would be cheaper *and* better distributed.
- No `texelFetch`, `textureGather`, integer textures, dynamic uniform indexing.

**None of this is a WebGL2 limit.** WebGL2 supports `#version 300 es` and Three
exposes `glslVersion: THREE.GLSL3`. This is self-inflicted and free to fix.
*(Tier 2 converted the marcher to GLSL3 for MRT — the rest is still ES 1.00.)*

### 2.3 What WebGL2 genuinely blocks

Only compute shaders, and concretely for this project: GPU N-body / Barnes-Hut
(no atomics, no shared memory, can't build a tree), SPH or MHD accretion,
histogram-based auto-exposure, and ray compaction for the marcher. Everything
else — the disc marcher, the sky, all surface shaders, postfx — is
embarrassingly-parallel fragment work where a fragment shader is already the
right tool. Moving those to compute buys maybe 10–25%, not 5×.

### 2.4 f64 is unobtainable on this machine, at every layer

WGSL has no `f64` and it is not coming. Vulkan/OpenGL expose `shaderFloat64`,
DX12 has limited doubles, and **Metal has no `double` type at all**. On darwin,
shader f64 is unavailable in WebGL2, WebGPU, wgpu, Vulkan-via-MoltenVK and
native Metal alike. *Migrating for f64 means migrating toward something the
target cannot deliver.* The 10⁷ dynamic-range problem is a **coordinate-system**
problem — camera-relative origins plus logarithmic depth, ~200 lines, works
today in the browser.

### 2.5 Target ranking (as researched)

1. **Rust + wgpu** — near-native ceiling, full compute, best agentic story
   (`cargo check`, naga validates WGSL *with source spans before a frame
   renders*, headless render-to-PNG in ~40 lines). Main risk: wgpu's API churns
   hard, so model knowledge is version-skewed.
2. **Raw WebGPU in the browser, as a deliberate stage 1** — compute, storage
   buffers (kills the `MAX_HOLES`/`MAX_SUNS` constants), fp32 targets,
   timestamp queries, while keeping instant reload and the URL. Because
   **wgpu *is* the WebGPU API**, the WGSL ports essentially verbatim if you
   later go native. The expensive, correctness-sensitive third of the work gets
   paid once and reused in both outcomes.
3. **C++ + Vulkan, or Dawn** — highest ceiling; Vulkan's API has been stable
   since 2016 so model knowledge is deeper and less skewed than wgpu's. Ranked
   below on ergonomics, not capability.
4. **Godot 4.6** — see §6.
5. Bevy — churns harder than wgpu, and its render graph + built-in atmosphere
   are redundant with what this project already hand-writes.
6. Python + Warp — excellent for the *physics*, NVIDIA-only, not a renderer.
7. Unity — editor-centric, binary scene assets an agent can't read.
8. Unreal — worst fit on every one of the stated criteria.

### 2.6 Cost of a full native port

**6–10 engineer-weeks to parity, producing zero new features.** That figure is
the strongest honest argument against migrating and should be stated first in
any pitch. What is lost: instant reload, zero build step, share-a-URL,
works-on-a-phone, and `.claude/skytest.html` (which exists *because* the web
makes throwaway harnesses free).

---

## 3. Optimisation research — key findings

Profiled with `EXT_disjoint_timer_query_webgl2` plus an isolated A/B harness.
At **1920×1080**:

| pass | ms/frame | share |
|---|---|---|
| **LENS** (marcher, sky inlined) | **38.8** | **90%** |
| composite (ACES) | 0.55 | 1.3% |
| bloom down+up ×8 | ~0.26 | 0.6% |
| scene geometry | ~0.4 | 1% |

**The frame is one shader.** CPU side of `animate()` measured median <0.1 ms,
p90 1.8 ms.

### 3.1 Two hypotheses it killed

- **`STEPS 240` is not a performance dial.** 240 → 120 changed nothing; 240 → 60
  saved 6%. Rays already exit on `captured` / `minr > far` / `trans < 0.004` at
  20–60 iterations. The *step size* clamps are the knob, not the count. The
  comment at `sim/blackhole.js:297` still implies otherwise and is misleading.
- **The fBm in `discDensity` is not the bottleneck.** 80 `hash31` calls per
  density sample looks alarming; dropping 4 octaves to 1 saved 2.5%.
- **Bloom is 1% of frame.** The 5-level progressive chain is earning its keep.
  Leave it alone.

### 3.2 The finding that drove Tier 1

Ten of fifteen sky components have per-band weight at or near **zero** in the
visible, and were all being computed at full price and then multiplied by
nothing — three 3×3 compact-source neighbourhoods, an SNR neighbourhood, and six
diffuse fields carrying an fBm each. The `W` table in `sim/sky.js` already
declares exactly which components exist per band; it was only being used for
multiplication, never as a predicate.

### 3.3 On the web upgrade path

WebGPU browser support is solved (~80–85% real-world; Linux the one hole).
**Three.js is the blocker, not the browser** — the manual states plainly that
`ShaderMaterial` / `RawShaderMaterial` / `onBeforeCompile` are **not supported**
by `WebGPURenderer`. This project is ~4,000 lines of hand-written GLSL living in
`ShaderMaterial`s. Migrating to `WebGPURenderer` means porting all of it to
node materials / TSL. Recommended path if ever taken: **raw WebGPU + a tiny
hand-rolled scene layer** for the ~10 meshes that exist, not Three's WebGPU path.

For *this* workload WebGPU buys **~0–15%** — the frame is one ALU-bound
fullscreen fragment shader, and WGSL vs GLSL runs on the same silicon. It pays
off only when you want compute.

### 3.4 Electron vs Tauri

Tauri 2 is ~3 MB vs Electron's ~96 MB, but uses the **system webview** —
WKWebView on macOS, where WebGPU is gated separately from Safari's own flags, so
`navigator.gpu` can be `undefined` on a Mac where Safari has it. **If WebGPU is
anywhere in your future, use Electron.**

### 3.5 What genuinely cannot be fixed on the web

1. No fp64 in shaders (but see §2.4 — native doesn't fix it on a Mac either).
2. **No control over, or visibility into, the driver's shader compiler.** No
   register-pressure data, no occupancy, no ISA. *This is the most painful one*
   and it bit us directly — see §5.1.
3. Timer-query precision deliberately blunted.
4. No unified/managed memory, no explicit residency control.
5. `subgroups` at ~70% adoption, so not a baseline assumption.
6. Vsync-capped and throttled when backgrounded *(Electron removes this one)*.
7. Multi-GPU unreachable.

---

## 4. What was built, and what it measured

### 4.1 Tier 1 — `570f36a`

Band-weight culling, with **two** thresholds rather than one. A single
threshold of 0.05 looks perfect in the visible and **silently damages 1.9% of
the X-ray frame**, because several weights sit at exactly 0.05 and the log
stretch in `sim/spectrum.js` *lifts* faint components where ACES *buries* them.

```
SKY_W_EPS_VIS 0.03    // → ACES tone mapper, buried under the stars
SKY_W_EPS_LOG 0.005   // → log stretch, which lifts faint components
```

Verified by full-frame diff, **all seven bands: 0 pixels changed**, max channel
delta ≤1. Sky pass alone at 1280×720:

| band | before | after | |
|---|---|---|---|
| visible | 8.28 ms | **4.70** | **1.76×** |
| radio | 8.41 | 6.14 | 1.37× |
| UV | 8.28 | 6.82 | 1.21× |
| X-ray | 8.52 | 7.14 | 1.19× |
| IR / gamma | ~8.2 | ~7.0 | 1.16× |

Plus: `antialias: false` (nothing reaches the default framebuffer but one
fullscreen quad), pixel-ratio default 1.5 → 1.0 with a **Render scale** slider
(2.25× fewer pixels on a 2× display), dead `resolution` uniform removed.

### 4.2 Tier 2 — `48039d1`

Pre-build ablation established the decisive fact: **the pass scales near-linearly
with pixel count** — 3.89× faster for 4× fewer pixels. And the sky costs 11.1 ms
*inside* the lensed shader vs ~4.4 ms alone.

So the pass was split. Pass 1 marches at `lensScale` into two RGBA16F
attachments; pass 2 evaluates `sim/sky.js` over the resulting direction field at
**full display resolution**. Stars are full-res at every setting; only the disc
and shadow edge soften.

| | ms | vs before |
|---|---|---|
| before, single pass | 35.61 | — |
| split, lens 1.00 | 27.83 | 1.28× |
| **split, lens 0.50** (default) | **11.39** | **3.13×** |
| split, lens 0.25 | 6.89 | 5.17× |

At 60 r_s: 14.25 / 12.40 / 7.24 / 6.15.

Two encoding decisions, both load-bearing:

- **Direction stored as a delta from the undeflected ray.** Deflection → 0 away
  from the hole, so the delta is smallest exactly where the sky needs the most
  angular precision, and fp16 spends its mantissa on the bend rather than the
  unit vector it corrects. The resolve pass rebuilds `d` as *(exact full-res ray
  + interpolated delta)*, so interpolation error tracks the deflection gradient.
- **`trans` was a `vec3` holding three copies of one number** — every
  attenuation is `exp(-tau)` with scalar tau. Collapsing it to a float, and
  zeroing it on capture to retire the separate `captured` flag, is what fit the
  handoff into two attachments instead of three.

**Regression case held.** Arcs above the holes are still strings of crisp
points, verified at 3× and 6× zoom — same stars, same positions, diffraction
spikes intact. Measurable cost: total light in the photon-ring annulus falls
**412 → 359 → 327** across scales 1.00 / 0.50 / 0.25, i.e. the ring loses 13% of
its light at the default. Direction-field discontinuity affects 8.84% of pixels
at 26 r_s, 3.15% at 60, 1.54% at 120.

### 4.3 Electron shell — `c568d3c`

`desktop/` hosts the **unmodified** web build over loopback. No desktop branch
of the sim, no bundler; deleting the directory changes nothing. Buys **no frame
time** — it buys no background throttling, no vsync ceiling, a pinned renderer,
a WebGPU flag, and a native process Instruments can attach to.

---

## 5. Corrections — claims that turned out wrong

Recorded deliberately, so nobody rebuilds on them.

### 5.1 "The lensed pass is register-pressure-bound" — **partly falsified**

Metal System Trace over 12 s, run twice (pre-split code and current code), shows
**zero register-spill events from Electron in either**. The shaders do not spill.

Occupancy limiting *without* spilling is a different mechanism and remains
consistent with all behavioural evidence — splitting identical work made it
1.28× faster, and the band culling went from 1.00× to 1.20× once split — but it
is **not confirmed**. ANGLE's translated source is suggestive, not decisive:
**940 declared locals** for the fused shader vs **687** for the resolve pass.

**Still open**, and it needs a GUI step no agent can drive: take a Metal frame
capture and open the `.gputrace` in Xcode's GPU debugger, whose pipeline-state
inspector reports register usage and theoretical occupancy per shader. ~5
minutes of manual work. It is the last unanswered question about this renderer.

### 5.2 "Electron will unlock GPU profiling" — **wrong**

`EXT_disjoint_timer_query_webgl2` is *exposed* and returns **0 from every
query** — in a browser tab, in Electron, and with `--enable-gpu-benchmarking`
explicitly set. **ANGLE's Metal backend does not implement GPU timestamps.**
Per-draw GPU timing is unavailable on this stack by any route. Every number in
this document came from a `readPixels` stall — wall time around a forced sync,
not GPU time. Directionally sound; not what a profiler gives you.

What *does* work: **Metal System Trace via `xctrace`, driven headlessly**. Full
Xcode is required (Command Line Tools is not enough) but `xcode-select` does
**not** need switching — invoke by path. Recipe in `desktop/README.md`.

### 5.3 "Hoisting the cube-cell setup saves 1–2 ms" — **no measurable gain**

8.28 vs 8.64 ms, opposite sign, within noise. ANGLE was already CSE-ing the
pure calls. Kept for clarity, not for speed.

### 5.4 "Band culling gives 1.44× on the lensed frame" — **0% until Tier 2**

It measured exactly 1.00× inside the lensed pass across four camera distances.
Only after the split did it start paying (1.20×). **The two changes only work
together**, which is also the best evidence for the occupancy story.

---

## 6. The Godot question

### 6.1 It will not make the frame faster

Same GPU, same shader math. Dropping the ANGLE translation layer is worth
something small; the ALU work is identical. **A port is a capability move, not a
performance move.** Nothing gets a dramatically faster version of this exact
image — the 3.13× came from doing less work, and the trace found no pathology
hiding under what remains.

What it buys: compute shaders, storage buffers, real particle counts, fp32
targets, no sandbox, a native app.

### 6.2 Why Godot is nonetheless the easiest *native* target here

`gdshader` is GLSL-derived. The ~2,100 lines of GLSL port with far less
syntactic violence than WGSL or HLSL, which would mean rewriting every line.
GDScript is agent-friendly, hot reload is instant, and docs density in training
data is high.

### 6.3 What to install

| | |
|---|---|
| **Godot 4.6** stable | Single binary, no SDK. 90% of it. |
| **Godot .NET build + .NET 8 SDK** | Only for C# — but see 6.4, probably yes. |
| *(optional)* godot-cpp + SCons | Only if GDExtension is needed. Xcode toolchain already covers the compiler. |

### 6.4 Three risks to settle early

1. **GDScript is slow for tight numeric loops.** V8 JITs the N-body; GDScript is
   a bytecode VM, typically 10–50× slower on that code. `physics.js` runs O(N²)
   per substep with up to 8,000 substeps/frame. Currently <2 ms; could become
   the new bottleneck. Fix is C#, GDExtension, or GPU compute — decide early
   because it shapes the data layout.
2. **Godot's renderer is in the way.** This project is ~90% custom fullscreen
   passes and ~10% scene graph. Godot brings its own tonemapper, HDR pipeline
   and sky, all of which get bypassed. Expect real effort making Godot *not* do
   things. `CompositorEffect` (4.3+) is the sanctioned injection point.
3. **Compute shaders reportedly do not work in headless exports.** If true in
   4.6, that breaks unattended agent verification precisely for the feature
   motivating the move. **Verify against current docs before committing** — this
   comes from the research phase, not from having built it.

### 6.5 Session estimate

| phase | sessions |
|---|---|
| Scaffold + **prove the headless screenshot loop works** | 1 |
| `sim/sky.js` — hardest file, subtly visual, needs its own harness | 3 |
| Marcher + disc + the MRT split | 2 |
| Postfx chain (bypassing Godot's tonemapper) | 1 |
| Physics, presets, stellar, climate (pure logic) | 2 |
| Body visuals — star, neutron, world, textures, markers | 3 |
| Orchestrator, cameras, picking, trails | 2 |
| UI: 62 DOM ids + 290 lines CSS → Control nodes | 3 |
| Visual parity, 9 presets × 7 bands, Trisolaris stability | 2 |
| **total to parity, zero new features** | **~19** |

**Treat this as a rough shape, not a budget.** It could be meaningfully fewer if
the gdshader translation is as mechanical as expected and the UI maps cleanly —
the shader port is the bulk of the risk and it might simply work. It could be
meaningfully more if Godot's renderer fights the custom pass chain, if the
GDScript numerics force a mid-port move to C#/GDExtension, or if the sky's
correctness proves as subtle in a new engine as it is in this one. Sessions also
vary enormously in size; a "session" here means roughly one coherent chunk of
the kind done on this branch, not a fixed unit.

The number that matters is not 19 — it's that **the first thing you couldn't
already see arrives after all of it.**

### 6.6 Recommended sequencing

Put the port in `godot/`, exactly as `desktop/` sits today, so the web build
stays live and shippable throughout.

**Spike `sim/sky.js` first, in isolation** — the equivalent of
`.claude/skytest.html`. It is the hardest file, its correctness is the most
subtly visual, and it is ~3 of the ~19 sessions. If it looks right and the
agentic loop feels good, the rest is mostly grinding. If it fights, that cost 3
sessions to learn instead of 19.

### 6.7 The standing alternative

If the actual goal is **compute shaders**, raw WebGPU in the browser gets them
for roughly the cost of translating the shaders — no orchestrator port, no UI
port. Godot is the right answer for *a native app that isn't a browser*; it is
an expensive answer for *compute shaders*. Today's results did not weaken this.

---

## 7. Picking this up cold

1. Read `CLAUDE.md` first — it is the engineering map and its conventions
   (comment density, `renderRadius`, the sky's resolution-independence rule) are
   binding on any port.
2. Current work is on `perf/tier1-shader-culling`, three commits, not merged.
3. Run the web build with `preview_start {name: "sim"}`; run the desktop shell
   with `cd desktop && npm install && npm start`.
4. **Beware two traps that each cost a debugging round trip:** GLSL reserves
   `patch`, and a backtick inside a comment in a shader template literal
   terminates the string. Both are documented in `CLAUDE.md`; both were hit
   again during this work.
5. Do not trust `EXT_disjoint_timer_query_webgl2` — see §5.2. Time passes with a
   `readPixels` stall, and state that that is what you did.
6. If a measurement contradicts something in this document, **the measurement
   wins**. Four claims in here were already overturned that way.
