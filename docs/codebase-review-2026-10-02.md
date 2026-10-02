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
| R06 | P2 | Partial: flight-local | Vessel integration guard advances clocks by requested time even when integration is truncated. | Guard exhaustion reproduced; clocks/downstream operations use integrated time; exhaustion visible and normal flight remains equivalent. Shared orrery frame ordering remains unresolved. |
| R07 | P2 | Verified | FPS uses clamped simulation time and averages reciprocal frame durations. | FPS measures frame count divided by actual elapsed time, independently of simulation/screenshot stepping. |
| R08 | P2 | Verified | Guidance conflicts with behavior and relies on prose where invariants should be checked. | Instructions accurately describe physics/display separation, checks, API contracts and camera scope; no blanket silent acceptance of malformed authored data. |
| R09 | P2 | Backlog | `main.gd` concentrates body events, camera control, mode coordination, UI wiring and checks. | Extract one coherent responsibility at a time, retain visible frame order and lifecycle ownership, run affected checks after each extraction. |
| R10 | P2 | Backlog | Important interfaces use unchecked dictionary keys and optional dynamic method calls. | Prioritize typed subsystem dependencies and validated input schemas; malformed authored data produces actionable diagnostics. |
| R11 | P2 | Partial: lesson keys | Lesson directives may silently disappear; missing asset parts may silently stop moving. | All authored lesson keys and expected asset stage/part contracts validated; deliberate typo/renaming probes fail. |
| R12 | P2 | Backlog | Blender and procedural vehicle implementations duplicate shape and moving-part knowledge. | Decide whether runtime procedural builds remain a product requirement; validate dimensions, engine/part counts and articulation if retained. |
| R13 | P3 | Partial: lesson header | Long introductions, port history, banner comments and repeated documentation reduce signal. | Remove redundant narration; retain units, precision, ownership and algorithm rationale; keep substantial explanations in canonical docs. |
| R14 | P2 | Profiling backlog | Authored models strongly favor top LOD; materials frequently disable back-face culling. | Measure launch/studio GPU cost; preserve close detail while distant geometry and genuinely closed surfaces avoid unnecessary work. |
| R15 | P2 | Profiling backlog | Body slider edits rebuild visuals; inspector repeatedly recomputes structure. | Measure interaction spikes and apply bounded invalidation/caching only where justified; lifecycle counts stay flat. |
| R16 | P3 | Profiling backlog | Per-frame shader arrays and transient compute uniform sets may add submission/allocation cost. | CPU/render-thread profile establishes material cost before changing lifetime or cache ownership. |
| R17 | P2 | Backlog | All-resource export can include development/archived resources. | Inspect an exported package and exclude development/reference content without losing dynamically loaded runtime assets. |
| R18 | P3 | Backlog | Tracked screenshot/reference evidence dominates repository storage. | Define evidence retention and regenerate/retain useful baselines; do not delete verification evidence indiscriminately. |
| R19 | P2 | Backlog | Progress/settings writes are direct and lack atomic replacement. | Interrupted writes preserve a last valid file; malformed/unwritable files handled visibly and safely. |
| R20 | P2 | Backlog | Performance and release confidence lack a reproducible integrated baseline. | One check entry point and CI, clean-clone/export smoke checks, scenario CPU/GPU and frame-time budgets, keyboard/text-scaling/small-window checks. |

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
R06 remains partial: `main.animate()` advances the orrery before flight, so the
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

## Suggested next assignments

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
