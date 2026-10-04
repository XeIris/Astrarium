# Measuring rendering and editing

`tools/perfcheck.tscn` runs the production stage at 1280×720 device pixels,
render scale 1, VSync off and fixed 1/60-second simulation calls. Each case
settles for 90 rendered frames before collecting 180 samples. It records median,
p95 and maximum for the stage call, any edit action, viewport rendering CPU/GPU
times and visible primitives. Render-thread timestamps measure each compute
shader dispatch separately, including repeated bloom mip passes.

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

These APIs follow Godot's [viewport timing contract](https://docs.godotengine.org/en/latest/classes/class_renderingserver.html#class-renderingserver-method-viewport-get-measured-render-time-gpu)
and [RenderingDevice timestamp contract](https://docs.godotengine.org/en/4.4/classes/class_renderingdevice.html#class-renderingdevice-method-capture-timestamp).
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
in the final code. All eight cases complete, and authored models settle before
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

Portable budgets require named hardware, renderer, quality, asset mode and frame
conditions. The CI headless checks establish correctness/export contracts, not
rendering performance. Retain raw reports as CI artifacts or temporary evidence,
following [the retention policy](evidence.md).
