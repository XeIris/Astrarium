# Codebase review and remediation

Reviewed 2 October 2026 against `0588e1e`, on Godot 4.7.2, Metal,
Apple M5. This is a targeted architecture and code audit with executable
checks, rather than an exhaustive verification of every behavior.

The priority is correctness and trustworthy verification, then maintainability
and measured performance. Comment cleanup is worthwhile but should not displace
those changes. The archived `web/` implementation remains untouched; agreement
with it is useful evidence of compatibility, not proof of physical correctness.

## Work ownership

The first remediation batch was implemented in parallel. Agents shared a
checkout with distinct file ownership; the coordinator reviewed the combined
diff and ran integration checks. The user requested committing this verified batch
before continuing remediation. Publication remains outside this work.

| Owner | Scope |
|---|---|
| Physics agent | `sim/physics.gd`, `sim/derive.gd`, native kernel, conservation checks |
| Verification agent | Preset/physics wrappers, native comparison, lifecycle check functions |
| Rendering/flight agent | Camera/frustum fixes; vessel and flight-driver elapsed time |
| Coordinator | This log, guidance/docs, FPS measurement, integration review |

Large architectural changes and unmeasured optimization candidates remain
backlog work. Their acceptance criteria below make them suitable for subsequent
bounded assignments.

## Findings

Statuses: **active** is assigned implementation; **partial** has a verified bounded
fix with remaining work; **backlog** needs a later implementation or profiling pass.
**Verified** requires a reviewed change and
recorded acceptance evidence, not an agent's assertion alone.

| ID | Priority | Status | Finding | Acceptance criteria |
|---|---|---|---|---|
| R01 | P1 | Verified | Collision resolution reuses an absorbed body, creating mass in a three-way overlap. | Mass and momentum conserved for multi-body collisions and permutations; native and GDScript agree. |
| R02 | P1 | Verified | Contact distance defaults to rendered size, so true scale changes simulation outcomes. | Physical contact distance and merger outcomes independent of scene/body scale and true-scale toggles; explicit distances and measured radii respected for non-BH bodies; BHs use horizons. |
| R03 | P1 | Verified | Source-specific softening gives unequal opposing forces; energy diagnostic uses a different potential. | Ordinary pairs use symmetric forces and a matching potential; compact/GW approximation limits explicitly identified. |
| R04 | P2 | Verified | Course harness never starts the simulation, exposing an incomplete surface-camera clipping update. | Full course walk has zero errors; surface, free, flight and true-scale Earth cameras remain useful; rendered evidence inspected. |
| R05 | P2 | Verified: targeted gates | Wrappers can mask child failure, missing completion or reported defects; some checks only print comparisons. | Nonzero exits for defects, child failure and incomplete runs; comparison validates bodies, positions, velocities and finite values; deliberate failure probes reject correctly. |
| R06 | P2 | Verified: batch 2 | Vessel integration guard advances clocks by requested time even when integration is truncated. | World and flight share accepted coordinate time and a frame budget; moving-parent guards, rails fallback and cruise arrival pass production-driver checks. |
| R07 | P2 | Verified | FPS uses clamped simulation time and averages reciprocal frame durations. | FPS measures frame count divided by actual elapsed time, independently of simulation/screenshot stepping. |
| R08 | P2 | Verified | Guidance conflicts with behavior and relies on prose where invariants should be checked. | Instructions accurately describe physics/display separation, checks, API contracts and camera scope; no blanket silent acceptance of malformed authored data. |
| R09 | P2 | Partial: development checks extracted | `main.gd` concentrates body events, camera control, mode coordination and UI wiring. | Extract one coherent responsibility at a time, retain visible frame order and lifecycle ownership, run affected checks after each extraction. |
| R10 | P2 | Partial: validated assets/saves, contact API | Important interfaces use unchecked dictionary keys and optional dynamic method calls. | Prioritize typed subsystem dependencies and validated input schemas; malformed authored data produces actionable diagnostics. |
| R11 | P2 | Verified: batch 2 | Lesson directives may silently disappear; missing asset parts may silently stop moving. | Authored lesson keys and asset stage/part contracts validated; deliberate typo/part-removal probes fail. |
| R12 | P2 | Partial: height/datum parity | Blender and procedural vehicle implementations duplicate shape and moving-part knowledge. | Decide whether runtime procedural builds remain a product requirement; validate dimensions, engine/part counts and articulation if retained. |
| R13 | P3 | Partial: touched owners | Long introductions, port history, banner comments and repeated documentation reduce signal. | Remove redundant narration; retain units, precision, ownership and algorithm rationale; keep substantial explanations in canonical docs. |
| R14 | P2 | Profiling backlog | Authored models strongly favor top LOD; materials frequently disable back-face culling. | Measure launch/studio GPU cost; preserve close detail while distant geometry and genuinely closed surfaces avoid unnecessary work. |
| R15 | P2 | Profiling backlog | Body slider edits rebuild visuals; inspector repeatedly recomputes structure. | Measure interaction spikes and apply bounded invalidation/caching only where justified; lifecycle counts stay flat. |
| R16 | P3 | Profiling backlog | Per-frame shader arrays and transient compute uniform sets may add submission/allocation cost. | CPU/render-thread profile establishes material cost before changing lifetime or cache ownership. |
| R17 | P2 | Verified: local macOS export | All-resource export can include development/archived resources. | Development files excluded, runtime remaps retained, exported native/flight rendering exercised outside the source checkout. |
| R18 | P3 | Backlog | Tracked screenshot/reference evidence dominates repository storage. | Define evidence retention and regenerate/retain useful baselines; do not delete verification evidence indiscriminately. |
| R19 | P2 | Verified: POSIX and simulated recovery | Progress/settings writes are direct and lack atomic replacement. | Validated temporary publication, retained recovery data and visible failures; actual Windows integration remains pending. |
| R20 | P2 | Partial: runner and local baseline | Performance and release confidence lack a reproducible integrated baseline. | One check entry point and CI, clean-clone/export smoke checks, scenario CPU/GPU and frame-time budgets, keyboard/text-scaling/small-window checks. |
| R21 | P2 | Verified: controlled flight/model rounds | The uncontrolled staged-flight soak compared changing inputs and gained a cached TextLine. | Repeat seeded initial conditions, exercise real separations and verify exact flat counts without clearing caches or widening tolerances. |
| R22 | P2 | Verified: batch 5 | Catalogue pulsar spin periods become Hz in `spec.spin`, while the neutron visual consumes the same value as an angular rate per rendered second. | Separate measured frequency from illustrative angular speed; document the time mapping and verify catalogue-derived rotation periods. |
| R23 | P2 | Verified: batch 6 | Full-width lesson cards overlap both side panels, blocking course items, Next and Close. | At 900/1024×600, all course entries remain scrollable and card navigation receives real pointer events. |
| R24 | P2 | Verified: current Mac, batch 6 | The physical window minimum ignores content scale; logical columns overlap at scale 2. | Maintain sufficient logical layout space at supported scales and verify flight actions remain reachable. |
| R25 | P2 | Open: structural event gap | Rotational breakup and below-minimum neutron verdicts are returned by Structure but not acted on by the stage. | Define and execute their physical consequences; a warning alone cannot satisfy the structural-event contract. |
| R26 | P1 | Verified: batch 7 | Visual accretion removed physical mass/momentum without a receiving body and could delete the rest of a donor. | Cosmetic streams cannot mutate physical state; production frames match the kernel and contact mergers conserve mass/momentum, with pause/zero-time gates. |
| R27 | P1 | Open: demonstration physics conflict | Several presets inflate black-hole horizons or multiply reaction forces, contradicting the physical-unit guidance. | Mass-consistent horizons and justified force/time mapping; explicitly separate and label any retained demonstration approximation, with independent checks. |

## Evidence at the reviewed revision

### Physics

`Physics.resolve_collisions()` in `sim/physics.gd` continues the inner loop after
`a` has been absorbed. The native kernel deliberately preserves the same
behavior. Three coincident ordinary bodies with masses 1, 2 and 4 and positive
contact radii produced live mass **8** from initial mass **7** in both paths.
Reference equivalence consequently misses this defect.

`Derive.contact_au()` defaults to `radius_scene / scene_scale`. For a one-solar-mass
star with scene scale 2 and body scale 1, readable radius gives contact distance
**0.17 AU**, while true scale gives **0.00465047 AU**, a factor **36.5554**.
Explicit `contactAU` and measured `radiusKm` override that behavior.

`Physics.compute_accel()` uses each source's softening independently. A pair of
masses 1 and 2, separation 2 AU, and softenings 0.1 and 1 AU gave total momentum
derivative **-3.8986168** along the separation axis with no external force.
`Derive.total_energy()` uses Newtonian pair energy despite the softened force.
Tests should distinguish ordinary conservative dynamics from the project's
compact-body and gravitational-wave approximations.

### Check behavior

The rendered course walk returned **35 lessons, 108 steps, 222 errors**, all
repeated `create_frustum_points` failures from the rendering light culler. Errors
began in `sky/daynight`. The count is repeated failures, not 222 distinct defects.
A solar-only camera probe did not produce the same error.

Remediation diagnosis corrected the initial attribution: the harness stayed on
the start screen, making `animate()` return immediately. The surface observer
then changed the near plane without the normal frame's corresponding far-plane
update. This is a harness defect exposing an incomplete camera update, not
evidence of 222 production gameplay failures. Starting the simulation and pairing
near/far updates removed the errors without reducing the existing clipping ratio.

An executable substituted through `GODOT` emitted `PRESETCHECK LOST` with a
nonempty list and exited 37. `tools/presetcheck.sh` returned 0. Its parser also
does not require a completion marker or reject ordinary engine errors.

`tools/nbodycheck.gd` prints discrepancies but exits successfully without
assertions; it compares positions over the shorter array without rejecting a
body count difference. Preset checking manually animates without yielding a
rendered frame per scenario. Lifecycle checks print counts without asserting
post-warmup growth.

### Passing baseline checks

- `tools/sciencecheck.gd`: **17 checks, 0 failed**.
- `tools/nbodycheck.gd`, 30 frames for its nine default scenarios: identical
  positions and sub-step counts; no mergers occurred in that short run.
- Solar physics timing in that run: about **64.38 ms/frame** in GDScript and
  **0.195 ms/frame** natively. This is a short local measurement, not a supported
  hardware performance promise.
- Headless import found no script parse failures. Sandbox errors saving editor
  settings and macOS certificate messages were environmental diagnostics.

### Maintainability and comments

The nonarchived source sample contained approximately 44,100 lines across
GDScript, shaders, native C and model/tool Python, excluding the vendor API header.
The largest active scripts were `main.gd` (2,419 lines), `craftmodel.gd` (2,139),
`hud.gd` (1,934), and `launchsite.gd` (1,498). Lesson/catalogue data is not treated
as control-flow complexity merely because it is large.

Comment-only lines were about 17% of nonblank simulation source and 26% of shader
source. These ratios are descriptive, not quality scores. Examples worth trimming
include a 44-line lesson introduction and a 27-line planet-map introduction.
Numerical reasoning, unit annotations and unusual engine constraints are worth
retaining. Source provenance cannot be inferred from a verbose writing style.

The root AGENTS.md was about 1,112 words. Its strengths are nonstandard numerical
constraints and explicit ownership; its weaknesses are contradictions, blanket
rules with legitimate exceptions, and requirements without automated enforcement.
Tracked `tools/` content totaled about 83 MB, mainly evidence/fixtures.

The scoped guidance also deserves maintenance:

- `sim/flight/AGENTS.md` usefully records SI units, rotating-frame signs, staging
  and guidance constraints. Its claim that only `spaceflight.gd` knows the orrery
  exists is too literal: `Vessel` accepts `Body` parents and body arrays. Describe
  responsibility boundaries precisely. Frozen launch matching is compatibility
  evidence and should sit alongside independent fuel/time/conservation checks.
- `model_sources/blender/AGENTS.md` has valuable axes, datum and articulation
  contracts. It explicitly admits that node names are unchecked interfaces;
  documenting that failure mode does not repair it. Blanket double-sided craft
  materials should become a distinction between open shells and closed surfaces
  after profiling and visual validation.
- `shaders/AGENTS.md` preserves useful HDR, temperature-pass, transparency and
  Metal constraints. Several appearance rules are art-direction choices rather
  than universal engine requirements. Separate those from mandatory pipeline
  contracts, state their scope, and give visual checks reproducible fixtures.

Do not enlarge these files into architectural manuals. Keep the unusual contracts
near their owners and replace repeated prose with executable validation where
possible. The first batch updates root guidance; scoped follow-ups remain backlog.

## Remediation principles

1. Independent physical invariants take precedence over matching a defective
   numeric reference. Keep the reference frozen and report intentional differences.
2. Validate authored interfaces during checks. Runtime fallback remains useful
   for genuinely optional assets; it must not conceal malformed required data.
3. Separate measured problems from profiling candidates. No wholesale cache,
   language or framework rewrite follows from a static suspicion.
4. Keep refactors bounded by responsibility and testable behavior. Do not split
   files into arbitrary pieces just to reduce their line counts.
5. Document API units, ownership, lifetime and failure behavior. Move substantial
   explanations to one canonical location and link to it.

## Research informing the review

- [SlopCodeBench, version 2](https://arxiv.org/abs/2603.24755v2) studies coding
  agents repeatedly extending their solutions. It reports increased redundant
  code and concentrated complexity; quality prompts help initially without
  preventing later degradation. Its Python results are not a GDScript score.
- [Evaluating AGENTS.md, version 3](https://arxiv.org/abs/2602.11988v3) reports no
  general task-success improvement and higher inference cost from repository
  context files. Keep nonstandard practices explicit and evaluate instructions,
  rather than assuming more context produces better changes.
- [Godot optimization guidance](https://docs.godotengine.org/en/stable/tutorials/performance/general_optimization.html)
  recommends measured bottleneck identification, hardware-aware profiling and
  retesting changes.
- [Godot static typing](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/static_typing.html)
  describes earlier error detection and optimized opcodes for known types.
- [Godot scene organization](https://docs.godotengine.org/en/stable/tutorials/best_practices/scene_organization.html)
  supports focused components and explicit dependencies.
- [Google documentation guidance](https://google.github.io/styleguide/docguide/best_practices.html)
  distinguishes useful API contracts from inline rationale and redundant prose.

The research does not establish a universal acceptable comment ratio. This audit
uses concrete examples and behavioral evidence instead of an LLM-origin detector.

## Verification after remediation

The coordinator reviewed the shared diff. Verification uses Godot 4.7.2 on the
same machine; rendered checks use Metal outside the sandbox because sandboxed
GPU launches abort. Results below describe executed coverage, not promises about
untested scenarios or long-run stability.

| Check | Executed coverage and result |
|---|---|
| `tools/invariantcheck.gd` | Final 129/129, including all six three-body collision permutations, momentum, force symmetry, potential gradient, energy stability, scale independence, canonical measured radii/dependent quantities and native equivalence. |
| `tools/nbodycheck.gd` | Final nine scenarios × 240 frames; positions, velocities, masses, identities, merger order, steps and integrated time pass, with survivor refresh matching production callbacks. Deliberately altered velocity fails with exit 1. |
| `tools/presetcheck.sh` | 35 rendered scenarios, no engine/script/shader errors, zero unexpected body losses, complete markers, exit 0. |
| `tools/presetcheck.selfcheck.sh` | All nine wrapper cases pass; child exit 37 is preserved; missing/incomplete output, lost bodies and engine/script/shader errors rejected. |
| `tools/coursecheck.tscn` | Final active simulation walk after canonical radii/transmutation: 35 lessons, 108 steps, zero errors, including authored directive validation. First-lesson deliberate error/typo probe: three errors, one warning, exit 1. |
| Camera probes | True-scale Earth screenshot inspected; picking and all solar bodies inside clipping range. Tiny Mercury, actual surface/free/orbit transitions, temperature camera, launch/flight return pass. |
| `eval=_soak_check` | Four rounds each of spawn/remove, mass edits and true scale: object/resource/node/orphan counts exactly flat after warmup. Full feature matrix remains unexecuted. |
| `eval=_leak_check` | Five passes across all presets and two launch/abort cycles: objects 7,425, resources 305, nodes 1,810, orphans flat. VRAM 365–368 MB is telemetry, not a cache-independent failure gate. |
| FPS/energy display probe | Five 100 ms frames report 10 FPS; alternating 10/90 ms frames report 20 FPS; zero-duration sample is ignored. BH energy display carries the approximate indicator. |
| `tools/hudcheck.tscn` | 54 interaction assertions pass. First run exposed native mouse-exit interference splitting synthetic input across frames; harness routing repaired and repeated successfully. Controls/progress isolated. Ordinary/BH settings screenshots inspected; approximate label legible. Screenshot-save failure exits 1. |
| `tools/physcheck.sh` failure probe | Injected child exit 37 retained; stale output removed before running the child. |
| `tools/sciencecheck.gd` | Default correctness: 20/20, including independent live transit quadrature, SI RV projection and timestep convergence. Strict frozen compatibility: 22 checks, two expected failures, exit 1. |
| `tools/transitioncheck.tscn` | 14/14 rendered assertions: measured-star remnants become WD/NS/BH, discard old radius/contact, retain the intended WD 30,000 K and recompute luminosity; zero engine errors. |
| `tools/flighttimecheck.gd` | Forced inner/outer exhaustion, clocks/site rotation/downrange/visual elapsed time, warning episodes and healthy/rails/landed/destroyed branches: zero failures. |
| Existing flight regression | Eleven scenarios complete; phase/frame/MET summaries match archived reference. Largest apoapsis/periapsis summary delta about 0.0000743 m. This summary comparison does not assert every spot probe is identical. |
| Import / diff review | No script parse errors; sandbox editor-settings/certificate diagnostics remain environmental. Diff whitespace check passes; rebuilt native library retains arm64 and x86_64 slices. |

Ordinary gravity now uses symmetric Plummer softening:
`epsilon_pair² = (epsilon_a² + epsilon_b²) / 2`,
`a = G m_other r / (r² + epsilon_pair²)^(3/2)`, with pair potential
`-G m_a m_b / sqrt(r² + epsilon_pair²)`. This corrects both asymmetric softening
and the old force's incorrect Plummer label. BH source-wise Paczyński–Wiita
behavior remains an explicitly nonconservative educational approximation; the
HUD marks its energy diagnostic, and GW scenarios, as approximate.

The archived physics comparison completes but ordinary/NS trajectories, energy
and contact distances differ intentionally. BH merger/feeding frame results in
that comparison remain identical. `physdiff.mjs` prints numeric differences;
its successful exit alone does not assert numerical parity.

The initial post-fix science check passed 15/17. Its static instrument fixtures
still pass; two live trajectory expectations tied to the frozen web force law
differ: transit depth **0.02094173372322** versus **0.02094144213736**, and RV
amplitude **152.15322058258** versus **152.418190727708**. Fixtures and tolerances
were not weakened. Independent live-instrument checks now own default correctness;
the strict historical comparison remains available with `compatibility=web` and
still rejects both differences. Independent transit quadrature differs by about
1.064e-4 relatively; depth and RV discrepancies decrease with timestep halving.

The flight defect was reproduced against the baseline: 400 fixed RK4 steps
integrated **6.25 s**, while the old clock advanced **10 s**, creating about
**1,531 m** of launch-site divergence. Vessel clocks, sampling, contact and the
flight driver's local effects now use integrated time. Both inner and outer guards
report through the existing event log and recover without repeated warnings.
At the end of batch 1, R06 remained partial: `main.animate()` advanced the orrery before flight, so the
shared world can still run ahead when flight truncates its requested time. Fixing
that requires a coherent frame-order/time contract; reordering blindly would
risk the existing parent/anchor/cruise dependencies.

Guidance now permits useful API contracts, scopes the camera-at-origin rule,
requires physical collision radii and independent invariants, distinguishes
optional runtime support from malformed authored directives, and avoids an
unverified long-run guarantee. The lesson introduction was shortened and its
unsupported `speed` / misplaced `instrument` vocabulary removed. Broader comment
cleanup, profiling, architectural extraction and release work remain the bounded
backlog above.

## Suggested assignments after batch 1

1. Finish the shared flight/orrery time contract (R06), then validate a forced
   guard with moving parents and cruise transitions.
2. Enforce authored asset stage/part contracts (R11/R12) before deduplicating
   vehicle generation; use a deliberate part-renaming failure probe.
3. Establish repeatable frame-time profiles and export/clean-clone checks
   (R14–R17/R20). Optimize the measured launch/studio or slider bottleneck first.
4. Extract one coherent responsibility from `main.gd` (R09), with explicit frame
   order and teardown ownership. Add atomic progress/settings replacement (R19).
5. Trim redundant comments while touching their owners (R13); retain the physical
   rationale and lifetime contracts. Avoid a repo-wide cosmetic purge.

## Batch 2

Committed as `03ce2f0` (`fix(sim): synchronize flight time and harden assets and
saves`), including the known R21 failure, at the user's request.

Batch 1 was committed as `a017a2c` (`fix(sim): correct physical invariants and make
verification reliable`) at the user's request. Batch 2 begins from that clean
revision and retains distinct agent ownership:

| Owner | Assignment |
|---|---|
| Rendering/flight agent | R06: shared coordinate time, per-frame integration budgets, moving parents and cruise transitions |
| Verification/asset agent | R11: validate authored stage/engine/articulation contracts; fix discovered procedural/authored inconsistencies |
| Persistence agent | R19: safe controls/course saves, malformed-file handling, isolated failure/recovery checks |
| Coordinator | R17: inspect exported resources and remove development content; review and integrate the combined changes |

The export inspection established a narrower issue than the initial suspicion:
the archived web tree was absent, but the resource ZIP included **67 tool entries**
and a prior app bundle's icon. Those 68 development entries occupied **621,691
uncompressed bytes**. Excluding development directories reduced the local ZIP from
**53,071,690** to **52,477,832 bytes**, with zero development entries and retained
craft/map imports. This is release hygiene, not a significant performance claim.
The final resource ZIP passes the remap/boot checks with **305 entries** and
**52,495,410 bytes**. The macOS debug bundle includes the universal native dylib;
running its executable from `/tmp`, without `--path`, renders the authored Shuttle
and launch complex with no script/shader errors. This is a local debug smoke,
not release signing/notarization or clean-clone evidence.

Flight now requests world coordinate time at integration boundaries, accepts the
world's actual duration, and commits trails/climate/rendering once per frame.
Cruise converts each proper-time leg to coordinate time and inverts a truncated
accepted duration. MET and coordinate clocks remain continuous across entry and
arrival. Stateful guidance retains one update per frame; running it per RK4
interval initially caused a Shuttle insertion failure that the new production
driver caught. Countdown advances on accepted time. Active guidance programs stay
on RK4; rails are reserved for unpowered commands. Root/scoped instructions now
describe the actual world/local conversions rather than asserting every
conversion occurs in one file.

Shared-time checks pass **75/75** with both native and GDScript kernels. Sequential
CPU batch samples on the local Apple M5 measured orbit frames **1.241→1.263 ms**
and guided ascent **2.101→2.117 ms** versus `a017a2c`, about **1.8% / 0.8%**
overhead. These are local samples, not GPU timings or general performance bounds.

The four live-parent launches meet the authored apoapsis targets within 3 km;
periapsis meets guidance's 92% cutoff criterion, with a 3 km test allowance. These
are insertion gates, not proof of fully circular orbits. Final apo/peri (km):
Saturn V **184.9/176.6**, Falcon 9 **200.6/184.9**, Shuttle **301.0/276.0**,
Starship **250.1/231.0**. Coordinate clock disagreement remains below 6e-10 s.
The eleven legacy scenarios retain their batch-1 numerical results exactly.

Craft templates validate stage scope, required driven parts, numeric ordering,
geometry, identity pivot rotation and fixed/gimballed authority once at load.
Shuttle engine authority follows the external-tank engine specification; the
procedural CSM now registers its pivot. Blender output goes directly to runtime
assets, resolving a documented workflow that previously wrote into frozen `web/`.
The local Shuttle artifact was rebuilt to move fixed flap orientation onto a
mount. Generated GLBs remain gitignored: rebuild/import them on other machines.

Geometry parity remains R12: authored/procedural audit heights differ for Sky
Crane **6.9/6.6 m**, Ion Cruiser **17.7/17.1 m**, and Beetle **4.5/4.9 m**.
The audit checks valid geometry and clearance; it does not assert parity.

The shared 100-line JSON helper verifies same-directory temporary output before
publication. POSIX rename replaces atomically; Godot's Windows replacement has a
delete-before-rename window, so it retains/restores a validated recovery backup.
Malformed data blocks automatic overwrite; explicit Reset rolls back on failure.
Controls/course/icon failures reach the HUD. **64/64** isolated assertions cover
truncation, backup/restore and destructive publication failures, invalid schemas,
conflicts and Reset. No power-loss/fsync durability or actual Windows result is
claimed.

Integrated validation: **54 HUD interactions**, **35 lessons / 108 steps / zero
errors**, **129 physics invariants**, **20 science checks**, **360 authored rig
assertions**, **348 fallback assertions**, all four authored/fallback pad/craft
combinations with zero intrusion. Deliberate malformed rigs and pad obstructions
exit 1. Model-viewer counts stay exactly flat over five rendered rounds after
the harness actually drives asynchronous loading to completion.

The five-round staged-flight soak still **fails**: objects **7276→7277**, resources
**210**, nodes **1810**, orphans **47**. Notification quiescence removes transient
Tween spikes but does not explain the retained extra object. The same +1 failure
reproduces at `a017a2c`; verbose shutdown reports no leaked instances. This remains
R21, not a proven craft leak and not a green lifecycle result. The strict gate is
unchanged. Local logs: `/tmp/b2-soak-flight-quiesced.log` and
`/tmp/b2-soak-baseline-flight.log`.

The exported Earth smoke exposed another framing defect shared with the source:
the glide/cut decision used the old camera radius before framing the destination.
At true scale, a 60-frame capture could still be far from Earth. The destination
radius now governs that decision, and CLI size convention precedes focus.
Source and packaged 60-frame true-scale Earth captures were inspected after the
fix; the complete course and 54 HUD interactions pass again. Course boot failures
now report and exit immediately instead of entering a walk on a broken stage;
the unsupported headless renderer provides a negative boot probe (exit 1).

Next batch should investigate R21 first, establish repeatable frame/GPU profiles
and an integrated check entry point (R20), then choose one measured performance
fix or one bounded extraction from `main.gd` (R09). Resolve R12's geometry parity
before introducing shared vehicle-generation infrastructure. Avoid a framework
rewrite or comment purge merely to shrink files.

After the remediation batches, re-review the current codebase independently:
rerun correctness/failure probes, inspect the actual architecture and instruction
files, and measure frame-time costs. Do not treat completed checkmarks or agents'
reports as a substitute for that review.

## Batch 3 — 2026-10-03

Begins from `03ce2f0`. Ownership is separated to keep changes reviewable:

| Owner | Assignment |
|---|---|
| Lifecycle agent | R21: identify the extra object and verify exact post-warmup counts |
| Verification agent | R20: one strict check entry point and repeatable measurements; assess CI prerequisites |
| Geometry agent | R12: correct measured craft height/datum differences and enforce parity |
| Coordinator | R09: move development checks out of the runtime orchestrator; integration review and this log |

### Verified geometry and measurement changes

R12 is partially addressed. Sky Crane, Ion Cruiser and Beetle had missing or
misplaced parts and incorrect shape/datum details. Corrections use physical
geometry rather than global scale factors. Sky Crane's Blender PICA strips now
stop at the spherical-cap tangent, and fallback cable rotations follow the
Blender-to-Godot axis conversion. All nine craft pass whole-vehicle height and
minimum-Y comparisons in **18 stowed/deployed poses**, within **2 cm** for bevel
and tessellation bounds. A deliberate 5% Beetle height error fails both poses
and exits 1. This does not establish per-stage, width, material or full silhouette
parity: Beetle spans remain **3.9 m authored / 3.7 m fallback**.

Authored/fallback asset checks pass **360/348** assertions; all four pad/craft
combinations report zero intrusion. Six final rendered craft images were
inspected without runtime or shader errors. All nine authored model viewers
retain exact **7894 objects / 718 resources / 1748 nodes / 401 cached-template
orphans** over five rendered rounds.

`tools/check.py` provides selected suites with retained logs, commands, engine,
platform and Git state in a JSON report. It rejects nonzero exits, errors,
timeouts and missing/duplicate completion markers. Its authored-assets gate
requires all nine models. R20 remains partial: clean-machine CI needs a portable
native build, generated models and a graphical runner; no CI coverage is claimed.

The performance harnesses now assert that `assets=0` selects procedural craft.
HUD timing disables automatic processing and advances exactly once per measured
frame; an independent simulation-clock assertion covers all 640 warmup/measured
frames. Earlier samples did not enforce the requested fallback configuration.

Three serial repetitions on **Godot 4.7.2 / macOS arm64 / Metal 4.0 / Apple M5**,
at **1280×720**, with procedural models and fixed 1/60-second simulation steps:

| Measurement | GDScript | Native |
|---|---:|---:|
| Solar-orbit CPU, median ms/frame | 0.835 | 0.651 |
| Falcon 9 ascent CPU, median ms/frame | 1.358 | 1.165 |

Independent review corrected the p99 nearest-rank calculation; the nine HUD
measurements were rerun. Rendered wall-frame mean medians with HUD shown/hidden:
sandbox **6.94/6.71 ms**, flight **6.94/6.95 ms**, studio **5.82/5.65 ms**.
Median shown/hidden p99: **8.81/9.02**, **9.37/9.46**, **13.07/13.10 ms**,
respectively. Studio shown means span **4.28–5.95 ms**. These are local telemetry,
not GPU timings, general performance bounds or evidence of an optimization win.
All sixteen original performance children and nine corrected HUD children pass.
Local reports: `/tmp/astrarium-b3-perf-final/report.json` and
`/tmp/astrarium-b3-hud-perf-final/report.json`.

R10: `Derive.contact_au` now accepts only body/spec inputs. Removed ignored
render-radius/scene-scale parameters from every caller; presentation-independence
tests still vary the body's rendered radius. **129 invariants** and all **nine
native/GDScript equivalence scenarios** pass.

### Lifecycle diagnosis

The old staged-flight check did not perform its claimed separations: a burning,
fueled stage rejects a manual stage command. It also allowed pause/input changes
and advanced a randomly initialized Solar System between rounds. The check now
asserts that ascent executes and all three separations occur, disables external
main input, fixes the default seed, reloads identical initial conditions and lets
HUD notifications settle without advancing the world.

Godot ObjectDB snapshots identify the extra object as **TextLine**, with no other
class growth after accounting for the profiler's own lazy physics diagnostics.
The native owner is not exposed. [Godot's font measurement cache](https://github.com/godotengine/godot/blob/4.7-stable/scene/resources/font.cpp#L286-L310)
retains TextLine objects with [bounded capacities](https://github.com/godotengine/godot/blob/4.7-stable/scene/resources/font.cpp#L534-L537);
changing readout strings is the supported explanation, not a proven craft leak.
Five and eight seeded, controlled rounds with real staging keep exactly **7310 objects /
210 resources / 1825 nodes / 47 orphans**, with no engine errors or shutdown
leaks. No tolerance was widened and no font cache was cleared. Temporary debugger
code and snapshot hooks remain outside the committed source.

All nine procedural model viewers keep exactly **6853 objects / 135 resources /
1748 nodes / zero orphans** over five rounds, with fallback selection asserted.
The separate all-nine authored run is also flat. R21's original counter alarm is
resolved by repeatable test inputs; production ownership was not changed to hide
the font-cache behavior.

R09's bounded extraction moves the four development check methods to
`tools/runtime_checks.gd`. `main.gd` retains a small `eval=` dispatcher that loads
the tool only when requested, retains its asynchronous owner and rejects unknown
methods or unavailable exported tooling. Multiple methods execute in order.
Game frame order and subsystem ownership are unchanged. `main.gd` is still a
large orchestrator; this is partial debt reduction, not an architecture rewrite.

The exported resource pack remains **305 entries**, with **zero development
entries** including the new check script/UID. Normal gameplay has no static
dependency on the tooling. Headless import and direct loading of both scripts
pass. **14** runner probes confirm acceptance of complete runs and rejection of
faults, including errors present only in the engine log and timed-out POSIX
descendants.

The first integrated run passed all five rendered gates but rejected two more
unequal lifecycle endpoints. Spawn/remove left live flashes while the main
process was disabled; a wall-clock wait did not advance their lifetime. The
check now drives their normal animation with physics paused, asserts completion
within 900 fixed steps, and seeds quick-spawn's separate global RNG. The lesson
walk populated completion progress on its first pass, changing the subsequent
UI state; test-owned progress now resets before each walk. Five targeted rounds
stay exactly flat for spawn/remove (**6391/137/1619/0**) and the complete course
(**7272/137/1876/0**). No production lifecycle was changed to make these checks
pass.

The packaged debug app boots from `/tmp` without a project path, renders
true-scale Earth and exits 0. An exported development-check request exits 1 with
a clear unavailable diagnostic. A source request for an unknown method also
exits 1, including with a one-frame screenshot request; it creates no screenshot.

Final integrated lifecycle validation passes all three children. All **eleven
feature groups** remain exactly flat over **five rounds**, including all nine
model viewers and actual staged flight. Five complete preset/launch passes stay
at **7434 objects / 307 resources / 1810 nodes**, with no orphan growth. VRAM
**382.0–382.7 MB** is telemetry, not an asserted memory bound. Shutdown awaits the
launch and reports no leaked instances. No engine/script/shader errors occur.
Final report: `/tmp/astrarium-b3-lifecycle-final/report.json`; the earlier failing
integrated report is retained separately for traceability.

Batch 3 committed as **`a14eabc`** (`fix(dev): enforce craft parity and reliable
lifecycle checks`).

## Batch 4 — 2026-10-03

The next bounded pass removes repeated usage narration, archived API references
and banner comments from `core/body.gd`, `sim/flash.gd` and `sim/scale.gd`.
It retains units, floating-origin precision, lifetime ownership, raw colour
channels, mass-radius assumptions and the numeric-literal trap. Stale references
to the marker owner and structural accessor are corrected. All three files have
identical executable token streams before/after; no gameplay tests were added
or repeated for this comment-only change.

Rechecking the vague `Body.spin` annotation exposed R22. `starcat.gd` converts a
catalogue period in milliseconds to **1000 / period_ms**, a frequency in Hz.
`neutron_visual.gd` adds that value times rendered-frame seconds directly to
`rotation.y`, whose [Godot unit is radians](https://docs.godotengine.org/en/stable/classes/class_node3d.html#class-node3d-property-rotation).
The field is also used for illustrative planet rotation. A literal catalogue
frequency therefore needs an explicit 2π conversion and a declared time mapping;
the present interface leaves that intention implicit. Structural `spin_frac` is
a separate input. Rotation behavior is preserved in this batch; R22 requires a
clear physical-frequency/visual-speed contract and a period regression check.

The broad re-review remains pending. Priorities now are R22's unit contract,
R14–R16's actual GPU/allocation/interaction profiles, and small-window/text-scale
coverage from R20. Further `main.gd` extraction should establish useful ownership
boundaries rather than merely move lines. Full craft silhouette parity, portable
CI and an actual Windows save/recovery run remain unverified.


## Batch 5 — spin contract and renewed review, 2026-10-03

R22 separates physical neutron frequency (`spinHz`, cycles/second) from the
explicit display angular rate (`visualSpinRadS`, radians/unpaused render second).
Catalogue periods now produce a 2π conversion at the display boundary. Measured
frequency overrides the modelled structural spin fraction before the TOV verdict;
the existing neutron breakup model supplies that conversion. Two formerly
inconsistent period calculations now use the same neutron angular velocity.
The course pulsar has a physical 30 Hz frequency and an explicitly slower display,
labelled in the preset and lesson. This does not claim the display clock follows
orrery time or that a sampled image can resolve frequencies above its frame rate.

Live derivation rereads authored display rates and frequency. Removing an override
restores the measured rate or a stable sampled visual default. Transmutation drops
progenitor measurements and defaults; remnant display rates are explicit. Neutron
phase uses a bounded double accumulator. Removing the per-frame 0.0001-second
increment fixes pause/zero-time rotation and frame-count-dependent period inflation.
The obsolete comment claiming all visuals follow accepted world time is removed.
Frozen visual fixture adapters retain their original angular rates; `web/` is untouched.

Independent review confirmed the unit/clock boundaries. The rendered transition
check passes **39 assertions**, including the Crab's **33.5 ms** period, quarter/full
turns, frame partitioning, large elapsed intervals, production pause, frequency and
mass edits, override removal, TOV support ordering, unsupported collapse and remnant
rates. Overcritical frequency remains visible to the breakup verdict; executing that
verdict is the separate R25 gap. Fast checks and all five rendered gates pass,
including **35 lessons / 108 steps / zero errors**, **54 HUD assertions**, shared
flight/world time, and all **35 presets**. Reports are retained under
`/tmp/astrarium-b5-fast/` and `/tmp/astrarium-b5-rendered-final/`.

The renewed instruction audit corrected four stale scopes: procedural noise has no
mip chain, but imported maps do; only closed-loop ascent/circularization pitch uses
the stated rate limit; `craft_models_ready` takes an array and may request several
models; height/datum parity does not prove complete silhouette/material parity.
The material guidance now acknowledges quality-dependent reflection environments.
These are documentation corrections, not additional rendering or guidance behavior.

The profiling agent measured three repetitions at 1280×720 on Apple M5, medium
rendering/low lighting, with asserted Saturn V authored/procedural selection:

| State | Craft | Update CPU ms | Render CPU ms |
|---|---|---:|---:|
| Studio | Authored / procedural | 0.582 / 0.613 | 0.299 / 0.302 |
| Launchpad | Authored / procedural | 1.183 / 1.181 | 0.397 / 0.428 |

These are medians of run means, not GPU times or a portable frame budget.
All supported GPU timestamp readings are unavailable: the
[installed Metal backend](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/drivers/metal/rendering_device_driver_metal.cpp#L2108-L2120)
clears timestamp results. A distant authored LOD probe reduced submitted primitives
24,133→9,547 (60.4%) without establishing a timing gain. An Earth edit probe measured
2.068 ms per edit plus 0.624 ms for inspector refresh; further attribution is needed
before caching. R14–R16 remain profiling work, with no optimization claimed.
Temporary instrumentation, commands, raw JSON/logs and screenshots remain in
`/tmp/astrarium-b5-profile/`; durable reproducible evidence storage (R18) is still partial.

The UI agent reproduced R23 at both 900×600 and 1024×600 with actual pointer hit tests.
Existing HUD interaction checks at 1024×600 fail Next and Close (**53 passed,
2 failed**, nonzero exit). At content scale 2, a physical 1024×600 becomes logical
512×300 and the right panel covers forward warp. A temporary scale-aware minimum
restores logical 900×600 and reaches all eight tested flight actions on this display.
Settings bindings remain scrollable at scale 1.5. Evidence is in
`/tmp/astrarium-b5-ui/`; production UI fixes are the next batch.

The broader review also exposed R25 and R26. Neither is hidden by widened test
tolerances or an assertion that current behavior is correct. R26 is especially
serious: a visual size/time convention still affects physical evolution even after
the collision contact fixes. The broad re-review remains in progress.

Five-round targeted lifecycle checks remain exactly flat after warmup:
spawn/remove **6389/137/1619/0**, mass edits **6768/137/1720/0**, true-scale
rebuilds **6788/137/1720/0** (objects/resources/nodes/orphans). No shutdown,
script or shader error appears in `/tmp/astrarium-b5-soak.log`.

Screenshot validation found another stale instruction: X-ray is band **5**,
whereas band **6** is Gamma (`Spectrum.BANDS`). The shader AGENTS examples now
use the actual X-ray index. Both bands render without errors; the neutron surface
is bright in X-ray and dark in Gamma as the band model states.

R26's CPU-only probe invokes the actual accretion function on a separated donor
and hole with **zero accepted simulation time**. At exaggerated radius it removes
**0.0020000667 M☉** from a 1 M☉ donor in one 1/60-second render call and damps
its velocity; the 12 M☉ hole gains nothing. The same physical geometry at true
radius leaves donor mass and velocity unchanged. Evidence:
`/tmp/astrarium-b5-profile/accretion_cpu.gd` and `.log`. The probe's headless macOS
certificate diagnostic is retained, not presented as a clean engine run.


R27 follows from checking R26's scenario, not from speculative optimization.
`_build_sandbox` assigns a **0.5 AU** horizon to **10 M☉** (the mass-derived
Schwarzschild radius is about **1.974×10⁻⁷ AU**). `_build_feeding` similarly uses
0.5 AU for 12 M☉, and the sandbox mass control writes `mass × 0.05` directly
to `bh.rs`. These radii enter the Paczyński–Wiita force and contact distance;
they are not merely magnified meshes. Merger presets also use reaction boosts
up to **4×10¹⁷**, multiplying physical drag while keeping the orbital clock.
This conflicts with the root AGENTS prohibition on physics scaling fudges.
R02's corrected contact boundary and R03's ordinary-pair symmetry do not verify
these demonstration models. They need an explicit scientific/product decision
and independently tested replacements or clearly scoped approximation contracts.


## Batch 6 — usable HUD layouts, 2026-10-03

Batch 5 committed as **`48c7c62`** (`fix(sim): separate physical spin from display rotation`).

R23 reserves a full-width lesson card's measured height in both column budgets,
and places it above the measured diagnostics band. Visible downstream panels
receive a scrollable share; their placement still follows the previous panel's
measured bottom. A narrow-to-wide breakpoint alone was insufficient: with a
cross-section open at logical width 1041, the remaining gap could not hold the
minimum-width card. Full-width placement now also follows the measured available
gap. Settings keeps its independent modal layout.

R24 treats **900×600** as the logical minimum. Automatic display scale is fitted
to usable screen space, the physical minimum scales with it, and normal startup
fits the decorated window's size and position. Explicit screenshot sizing remains
available. Scalar double arithmetic avoids Vector2's float32 rounding; subpixel
roundoff is discarded before ceiling the physical minimum. The actual 903-pixel
fit exposed a one-double-ULP error, and bounded checks now cover widths 900–4000.
This is window/display-scale coverage, not a claim of accessibility text-zoom support.

The new strict layout gate exercises real clicks at logical **900/1024×600** with
scales **1/1.5/2**, plus **1041/1078/1280×600** breakpoint/cutaway cases. It checks
course-bottom access, Next/Close, cross-section access, diagnostics separation,
launch program, attitude mode, forward warp and exit. The final matrix passes
**124/124** assertions. A temporary inherited-harness injection restores the
right-panel overlap and fails **25** assertions with exit **1**, without script
errors. No tolerance or expected-failure exception masks occlusion.

All **six** rendered suite children pass: course **35/108/0**, HUD interactions
**54/0**, layout, shared time **76/0**, transitions **39/0** and all **35 presets**.
After the final numeric-only correction, the layout matrix and clean import were
rerun. Nine affected screenshots were inspected by the UI agent; the coordinator
also inspected narrow course, breakpoint cutaway and Retina flight screenshots.
Native decorated bounds fit the current display's usable rectangle. Other platforms
and monitor arrangements remain unverified. Production node/cache ownership did
not change, so an additional lifecycle soak was not required for this layout pass.

Evidence: `/tmp/astrarium-b5-ui/rendered-final/report.json`,
`numeric-final-layout.log`, `final-import.log`, `occlusion-negative.log`,
`nativebounds-fixed.log`, and `final-shots/` in the same directory.

R26's visual/physical coupling and R27's demonstration physics are the next
correctness priorities, ahead of speculative optimization. R25's structural event
gaps, remaining main ownership boundaries, craft silhouette parity, portable CI,
Windows save behavior and supported-backend GPU attribution remain open.

A further content precision issue was verified against the actual shader:
`shaders/bodies/neutron_surface.gdshader` uses a closed-form light-bending relation,
while the neutron lesson says it is ray-traced and not approximated. The
[original Beloborodov paper](https://arxiv.org/abs/astro-ph/0201117) explicitly
identifies that relation as approximate, with a limited compactness domain.
The visual header also claims 60% visibility at compactness 0.4, although its own
mapping gives about 83%. Correcting these claims and documenting the supported
visual-model domain belongs in the next content/model review; the UI change does
not establish physical accuracy.


## Batch 7 — conserve physics across visual updates, 2026-10-03

R26 is resolved by removing unsupported physical behavior, rather than inventing
a gas-transfer law. `update_accretion_stream` changes only its particle pool;
rendered reach affects the illustration but cannot remove mass, damp velocity or
shrink the body's owned transform. Nonpositive visual time performs no pool update
or emission. The stage no longer deletes a separated donor merely because its
mass is small compared with its original mass. Physical contact mergers remain
in the integrator/event path. Continuous hydrodynamic accretion is not modeled.

The feeding scenario and affected lesson cards now describe an orbiting companion
and illustrated gas flow; they no longer promise live stripping or a drag-driven
death spiral. Root instructions, the visual contract and stale comments were
corrected, and unused shrink metadata removed. R27's inflated horizons, compact
force approximation and reaction boosts remain open; cosmetic correctness does
not validate those models. Force laws and integration algorithms did not change.

The new rendered production gate passes **106/106** assertions with the native
kernel and **106/106** with forced GDScript. It covers eight true/exaggerated,
scene-scale and body-scale combinations with positive render time and zero
accepted world time; paused/zero-time pool snapshots; direct positive cosmetic
animation; positive accepted frames compared with cloned kernel-only evolution;
a diminished separated donor; and physical contact mass/momentum conservation.
The contact fixture isolates merger conservation from the known compact-force
asymmetry; the moving pair is compared to its kernel rather than incorrectly
asserting Newtonian pair symmetry.

An injected visual mutation deliberately drains mass, damps velocity and changes
scale. It exits **1** and the strict runner rejects it, establishing that the new
gate detects a physical/visual boundary violation (**35 failed assertions**).
Feeding also loses its preset-check exemption for disappearing bodies. All six
fast/native children pass. Evidence: `/tmp/astrarium-b7-fast/report.json` and
`/tmp/astrarium-b7-accretion-run/report.json`; commands and engine logs are retained
in those directories. The rendered suite runs both kernel variants.

All **eight** rendered-suite children pass, including both new accretion gates,
course **35/108/0**, HUD **54/0**, layout **124/0**, shared time **76/0**, transitions
**39/0** and all **35 presets**. After removing feeding's lost-body exemption,
the complete preset gate was rerun and passed. The targeted five-round soak
stays exactly flat after warmup: spawn/remove **6389/137/1619/0**, true scale
**6788/137/1720/0** (objects/resources/nodes/orphans). Evidence:
`/tmp/astrarium-b7-rendered/report.json` and `/tmp/astrarium-b7-final/report.json`.

The optional stream screenshot exposed shutdown leaks in the older isolated
render harness. The harness now releases its lens/post-processing RD resources;
the accretion fixture breaks its body/visual reference cycles. Its repeated shot
passes the strict error/leak gate, shows live particles and retains donor mass
**1 M☉**. The original failed run remains in the evidence directory; it is not
counted as a pass. Corrected evidence is `stream-fixed-report.json` and
`03-stream-shot-fixed.log`, with inspected `stream.png`. The real lens/post-processing harness and final headless import also pass
(`cleanup-report.json`). Other isolated fixtures' object ownership has not been
comprehensively reviewed.

R25 follow-up remains open. A rotational endpoint alone does not justify deleting
a body: the [mass-shedding collapse study](https://arxiv.org/abs/astro-ph/0205091)
starts with a radially unstable star. The model's 0.1 M☉ neutron minimum is approximate;
[cold-equilibrium calculations](https://arxiv.org/abs/astro-ph/0201434) find
EOS-dependent minima and a rotation dependence. Do not invent mass shedding or
a universal destruction law to satisfy the event contract. A next implementation
should define the supported equilibrium domain, distinguish warning thresholds
from unsupported inputs, and validate complete spawn/edit/preset requests before
mutating state. Edits must use current mass rather than stale merged-body specs;
failed requests need synchronized controls and atomic scenario loading. This is
a proposed approach, not a verified fix.
