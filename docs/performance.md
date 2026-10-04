# Measuring rendering and editing

`tools/perfcheck.tscn` runs the production stage at 1280×720 device pixels,
render scale 1, VSync off and fixed 1/60-second simulation calls. Each case
settles for 90 rendered frames before collecting 180 samples. It records median,
p95 and maximum for the stage call, any edit action, viewport rendering CPU/GPU
times and visible primitives. Render-thread timestamps measure each compute
shader dispatch separately, including repeated bloom mip passes.
Cases cover the solar system, idle/continuous editing, lensing, two studio
distances with two LOD biases, and an authored Falcon 9 on the pad and in ascent.
Flight rows record phase, elapsed mission seconds and altitude; prelaunch,
landed and destroyed phases cannot pass the ascent case. Reports identify the actual
rendering driver and method, including command-line overrides.

`studio_abba=1` instead compares only Saturn V LOD bias 128 / 1, with two ABBA
cycles at each of the two distances (16 blocks). After articulation settles,
simulation time, camera and every craft-node pose are held fixed and checked
against one baseline per distance. Each block warms for 90 frames and collects
180 distinct completed timestamp batches, with at most twice that many attempts.
Its primary metric is the model viewport's matched start/end timestamps from
the same acknowledged render-thread batch, excluding the HUD and compositor.
This uses the pinned engine's [viewport markers](https://github.com/godotengine/godot/blob/4.7.2-stable/servers/rendering/renderer_viewport.cpp#L310-L313)
and [completed timestamp frame identity](https://docs.godotengine.org/en/stable/classes/class_renderingdevice.html#class-renderingdevice-method-get-captured-timestamps-frame).
It is not a same-frame CPU/GPU latency measurement. Missing spans, insufficient
distinct frames, mixed zero/nonzero GPU times, changed state and timeout fail.
All-zero GPU timing is reported as unavailable and fails with `require_gpu=1`.
Four composited screenshots are saved outside sampling, beside the report with
its filename prefix. The suite runner includes this comparison separately.

Run with `report=/absolute/profile.json`. `samples=90` is a shorter probe;
`uniform_cache=0` compares transient uniform sets. `require_gpu=1` makes missing
GPU measurements a failure. Without that flag, unsupported GPU timing is
explicitly reported as `gpu_available: false`; zero is not interpreted as free
rendering. Headless execution, engine errors and incomplete runs fail.

The viewport sum includes enabled viewports and root HUD, plus CPU frame setup.
The lens dispatch precedes viewport rendering; its compute timing is reported
separately. Compute measurements overlap the compositor's viewport measurements,
so adding both would double-count. The action cost includes editor/inspector
work and visual changes; it does not include deferred GPU execution.

Viewport GPU measurements are milliseconds under Godot's
[timing contract](https://docs.godotengine.org/en/stable/classes/class_renderingserver.html#class-renderingserver-method-viewport-get-measured-render-time-gpu).
Compute CPU timestamps are microseconds, but GPU timestamps are nanoseconds in
the pinned 4.7.2 [Vulkan driver](https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/vulkan/rendering_device_driver_vulkan.cpp#L6107-L6137).
The public RenderingDevice documentation currently calls both microseconds;
using that GPU unit inflated the original compute reports by 1000×. Corrected
reports divide GPU differences by 1,000,000 to obtain milliseconds. Earlier
zero-valued Metal GPU observations and CPU measurements are unaffected.
The [engine uniform-set cache](https://docs.godotengine.org/en/stable/classes/class_uniformsetcacherd.html)
invalidates sets when dependent resources are freed, including resized targets.

## Local closure measurements

Godot 4.7.2, Metal 4, Apple M5, 1280×720, 90 samples per case. Before/after
measurements are local evidence, not a supported-device performance guarantee.
Metal returned zero GPU timestamps both for viewports and compute captures;
GPU costs remain unmeasured on this backend.

| Measurement | Before | After |
|---|---:|---:|
| Continuous solar-star spin edit, median action CPU | 15.983 ms | 8.596 ms |
| Same action, p95 | 16.499 ms | 9.760 ms |
| Solar compute dispatches, current code with transient / cached sets | 0.184 ms | 0.010 ms |
| Saturn V studio, near view, primitives at LOD bias 128 / 1 | 24,323 / 12,205 | Same screen-space comparison |
| Saturn V studio, distant view, primitives at LOD bias 128 / 1 | 21,053 / 8,835 | Same screen-space comparison |

The final probe with other science checks idle measured a 4.275 ms edit median,
5.264 ms p95 and 17.705 ms maximum. Background work and scheduling materially
change wall timings; the earlier before/after samples are observations, not an
isolated speedup attribution. The uniform-set comparison toggles only that cache
in the final code. All eight original cases complete, and authored models settle before
LOD overrides so asynchronous fallback replacement cannot change the comparison.

The edit still occasionally exceeds a 16.67 ms frame interval; graph sampling
and changing prose remain real costs. Stable lists/fact schemas retain Controls,
and stellar spin changes retain the photosphere/activity pools while updating
physical deformation and gravity-darkening parameters. Other intrinsic edits
retain the complete visual rebuild until separately justified.

Imported craft now use ordinary screen-space LOD selection. Open engine bells,
skirts and interstages remain double-sided; a global culling change would remove
visible surfaces. Per-sun uniform packing remains uncached: packed arrays use
copy-on-write across material submissions, so storing arrays alone does not prove
that allocations disappear. Optimize it only after isolated allocation evidence.

## Additional backend and allocation probes

An October 4 probe on the same M5 used Vulkan/Forward+ through MoltenVK, 90
samples per case and the ten-case harness. It returned nonzero viewport and
compute GPU timings. The lens march median was **4.783 ms** (p95 5.143 ms).
Viewport GPU medians were **8.664 ms on the pad** and **8.445 ms during ascent**;
these overlap post-processing and must not be added to compute totals.
The probe completed with zero harness/Godot failures, but MoltenVK printed
`VK_INCOMPLETE` while serializing its pipeline cache. Retain that diagnostic;
this is provisional backend evidence, not a clean default-renderer release gate.
Reports: `/tmp/astrarium-b17-gpu-final.json` and its adjacent raw log. The stricter
phase-guard rerun (`/tmp/astrarium-b17-gpu-guarded.json`) also passed ten cases;
the flight row confirms ascent at 18 mission seconds and 131.086 m altitude.
It measured pad/ascent viewport medians of 8.361 / 7.933 ms and a lens march
median of 5.549 ms, reinforcing the variability of short local samples.

Near studio GPU medians were 3.497 / 2.675 ms at LOD biases 128 / 1. Distant
medians were 3.333 / 3.287 ms, and a preceding probe reversed that ordering.
Primitive reduction is repeatable; these ordered, short timing samples do not
establish a distant GPU speedup or justify blanket back-face culling. The default
Metal backend still reports zero through the timing APIs. A separate Metal
System Trace independently captured 33,408 active GPU intervals attributed to
the test's Godot process, including compute, fragment and vertex work. Interval
durations are nested/overlapping and have no case markers; they are not frame
times and cannot be summed into a frame budget. Filtered evidence is retained in
`/tmp/astrarium-b17-metal-trace-summary.json`.

An isolated macOS native allocation-history experiment counted freed as well as
live allocations around production `Suns.apply_suns`, with three ShaderMaterials
and three lights. Current packing made **six loop-specific allocation events and
376 requested bytes per call**. Naive retained-array mutation removed those
events but changed a material's cached uniforms before submission. A candidate
that duplicated the packed wrappers before mutation preserved isolation and made
the same six events / 376 bytes as current code. The proposed cache therefore
adds ownership without demonstrating a safe allocation reduction; current
packing remains. This is headless material-cache/submission evidence, not a
rendered lifetime or whole-frame allocation budget. Reproduction and normalized
stacks are listed in `/tmp/astrarium-sun-allocation-findings.md`; compact results
are in `/tmp/astrarium-sun-allocation-comparison.json`.

## Controlled LOD comparison after winding repair

Freshly imported authored meshes, Godot 4.7.2 Vulkan/Forward+, M5, 1280×720,
180 distinct timestamp batches per block. Each value below averages the two
block medians for that bias in one ABBA cycle; frames within a block are not
independent experiment repetitions.

| Distance / cycle | Bias 128 GPU | Bias 1 GPU | Bias 1 minus 128 | Primitives 128 / 1 |
|---|---:|---:|---:|---:|
| Near / 0 | 0.267 ms | 0.302 ms | +0.035 ms | 22,851 / 9,575 |
| Near / 1 | 0.289 ms | 0.302 ms | +0.013 ms | 22,851 / 9,575 |
| Distant / 0 | 0.220 ms | 0.212 ms | −0.008 ms | 15,893 / 7,051 |
| Distant / 1 | 0.188 ms | 0.181 ms | −0.007 ms | 15,893 / 7,051 |

All 16 blocks pass with nonzero GPU timing and no backend diagnostics in this
run. Evidence: `/tmp/astrarium-b18-abba-verified.json` and its adjacent raw log.
The final guard also includes the craft root's transform and passes another
16×180-sample run in `/tmp/astrarium-b18-abba-root-guard.json`.
That rerun's near deltas are −0.042 / +0.044 ms across its two cycles, while
distant deltas are −0.043 / −0.026 ms. Even the near comparison changes sign;
these few cycles do not establish a statistically reliable speedup.
The older pre-import exploratory report is discarded. Normal LOD reduces
geometry; near timing is slightly worse and distant savings are tiny on this
device. These results support retaining ordinary LOD and do not justify another
material split or blanket culling change. Near captures and the rebuilt Hail Mary
before/after renders were inspected. Winding repair also changes bevel-generated
geometry, so earlier primitive counts are historical, not the current baseline.

Closed topology alone does not establish culling safety. The Blender primitive
gate rejects inconsistent cap winding and inward fins/tori, including closed
surfaces with no boundary edges. Exported surfaces often combine closed solids
with open shells under one material. Runtime import now preserves authored
culling; the shared open-shell palettes retain visible interiors. A later split
needs component-wise outward orientation, visual checks and measured benefit.

Portable budgets require named hardware, renderer, quality, asset mode and frame
conditions. The CI headless checks establish correctness/export contracts, not
rendering performance. Retain raw reports as CI artifacts or temporary evidence,
following [the retention policy](evidence.md).
