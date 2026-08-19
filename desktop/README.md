# Astrarium — desktop shell

An Electron window around the **unmodified** web build. There is no
desktop-specific branch of the simulation: `main.js` serves `../` over loopback
and points a window at `../blackhole_sim.html`. Delete this directory and the
web build is untouched. The root stays dependency-free, as
[CLAUDE.md](../CLAUDE.md) requires — the one `package.json` lives here.

```bash
cd desktop
npm install                 # electron only, ~100 MB binary
npm start
```

`ASTRARIUM_SCENARIO=bhmerger npm start` opens straight into a scenario.
`ASTRARIUM_DEVTOOLS=1` opens devtools detached.

## What the shell is actually for

**Not frame time.** Same Chromium, same ANGLE→Metal translation, same shaders.
A frame that costs 11 ms in a tab costs 11 ms here. What it buys:

- **No background throttling.** `requestAnimationFrame` is frozen in a hidden
  browser tab, which makes unattended measurement impossible.
- **No vsync ceiling** (`--disable-gpu-vsync`, `--disable-frame-rate-limit`), so
  a 6 ms frame reports as 6 ms rather than queueing to the next 16.7 ms.
- **A native process**, which Instruments and Metal System Trace can attach to.
- **A pinned Chromium**, so the renderer cannot change under you.
- **WebGPU available** (`--enable-unsafe-webgpu`) for when the marcher wants
  compute shaders.

## Benchmark mode

```bash
ASTRARIUM_BENCH=1 ./node_modules/.bin/electron .
```

Runs [bench.js](bench.js) in the renderer, prints JSON between `===BENCH===`
markers, exits. Times the march and resolve passes separately across lens
scales and camera distances.

For the long-run orbital regression, run the hidden renderer stability check:

```bash
ASTRARIUM_STABILITY=1 ./node_modules/.bin/electron .
```

This imports the production preset builders, Three.js module, and N-body integrator,
then advances the four deterministic Trisolaris architectures for 60 000 simulated
years. It reports the world and outer-orbit envelopes, minimum separation, and relative
energy drift between `===STABILITY===` markers.

> **Caveat, and it is a big one.** `EXT_disjoint_timer_query_webgl2` is
> *exposed* on this stack and every query returns **0** — in a browser tab, and
> in Electron, and with `--enable-gpu-benchmarking` set. ANGLE's Metal backend
> does not implement GPU timestamps. So `bench.js` currently reports zeros on
> macOS and the honest way to time a pass here is still a `readPixels` stall,
> which measures wall time around a forced sync rather than GPU time. The file
> is kept because it is correct and will start returning real numbers the day
> ANGLE implements the extension, or immediately on a non-Metal backend.

## Getting a real GPU profile

Metal System Trace works and can be driven headlessly. Full Xcode is required
(Command Line Tools is not enough), but `xcode-select` does **not** need to be
switched — invoke the binary by path:

```bash
XC=/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer "$XC" record \
  --template "Metal System Trace" --output /tmp/astrarium.trace --time-limit 12s \
  --launch -- ./node_modules/electron/dist/Electron.app/Contents/MacOS/Electron .
```

Then list the tables with `xctrace export --input /tmp/astrarium.trace --toc`
and pull one with
`--xpath '/trace-toc/run[@number="1"]/data/table[@schema="NAME"]'`.

Useful schemas: `graphics-compiler-spill-events` (register spills, by process),
`gpu-counter-value`, `metal-application-intervals`,
`gpu-shader-profiler-interval`.

**What this answered.** Traces of the pre-split single pass and the current
split pass both show **zero register-spill events from Electron** over 12 s. So
the shaders do not spill. Occupancy limiting *without* spilling is still fully
consistent with the behavioural evidence (splitting identical work made it
1.28× faster; a sky optimisation went from 1.00× to 1.20× once split), but
confirming it needs occupancy counters, and the only counter this machine
exposes through Metal System Trace is raytracing-unit activity.

**To finish it** you need a GUI step this tooling cannot drive: open the app,
take a Metal frame capture (Xcode → Debug → Capture GPU Frame, or set
`MTL_CAPTURE_ENABLED=1` and capture programmatically), then open the resulting
`.gputrace` in Xcode's GPU debugger. Its pipeline-state inspector reports
register usage and theoretical occupancy per shader directly. That is a
five-minute manual task and it is the last unanswered question about this
renderer's performance.
