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

The implementation history below records bounded changes and their checks.
The closure disposition distinguishes completed fixes, unsupported model behavior
and verification that requires another platform or usable GPU timers.

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
| R09 | P2 | Verified bounded extraction: checks and camera | `main.gd` concentrates body events, camera control, mode coordination and UI wiring. | Extract one coherent responsibility at a time, retain visible frame order and lifecycle ownership, run affected checks after each extraction. |
| R10 | P2 | Verified targeted boundaries: bodies/assets/saves/camera/sky | Important interfaces use unchecked dictionary keys and optional dynamic method calls. | Prioritize typed subsystem dependencies and validated input schemas; malformed authored data produces actionable diagnostics. |
| R11 | P2 | Verified: batch 2 | Lesson directives may silently disappear; missing asset parts may silently stop moving. | Authored lesson keys and asset stage/part contracts validated; deliberate typo/part-removal probes fail. |
| R12 | P2 | Verified shared physical metadata and bounded parity | Blender and procedural vehicle implementations duplicate shape and moving-part knowledge. | Decide whether runtime procedural builds remain a product requirement; validate dimensions, engine/part counts and articulation if retained. |
| R13 | P3 | Verified broad cleanup, batch 15 | Long introductions, port history, banner comments and repeated documentation reduce signal. | Remove redundant narration; retain units, precision, ownership and algorithm rationale; keep substantial explanations in canonical docs. |
| R14 | P2 | Resolved/bounded: normal LOD, winding and authored culling verified | Authored models strongly favor top LOD; materials frequently disable back-face culling. | Controlled GPU comparisons support normal LOD; shared open shells retain interiors. Further surface splits need measured benefit. Device budgets remain R20. |
| R15 | P2 | Verified bounded invalidation; spikes remain measurable | Body slider edits rebuild visuals; inspector repeatedly recomputes structure. | Measure interaction spikes and apply bounded invalidation/caching only where justified; lifecycle counts stay flat. |
| R16 | P3 | Partial: uniform cache verified; unsafe/ineffective array caches rejected | Per-frame shader arrays and transient compute uniform sets may add submission/allocation cost. | Rendered allocation/lifetime evidence must justify any different packing ownership. |
| R17 | P2 | Verified: local macOS export | All-resource export can include development/archived resources. | Development files excluded, runtime remaps retained, exported native/flight rendering exercised outside the source checkout. |
| R18 | P3 | Verified retention policy; archive retained | Tracked screenshot/reference evidence dominates repository storage. | Define evidence retention and regenerate/retain useful baselines; do not delete verification evidence indiscriminately. |
| R19 | P2 | Verified: POSIX and simulated recovery | Progress/settings writes are direct and lack atomic replacement. | Validated temporary publication, retained recovery data and visible failures; actual Windows integration remains pending. |
| R20 | P2 | Partial: macOS/Linux clean gates passed; Windows/remote CI pending | Performance and release confidence lack a reproducible integrated baseline. | Actual Windows verification, remote CI execution and supported-device GPU/frame budgets remain. |
| R21 | P2 | Verified: controlled flight/model rounds | The uncontrolled staged-flight soak compared changing inputs and gained a cached TextLine. | Repeat seeded initial conditions, exercise real separations and verify exact flat counts without clearing caches or widening tolerances. |
| R22 | P2 | Verified: batch 5 | Catalogue pulsar spin periods become Hz in `spec.spin`, while the neutron visual consumes the same value as an angular rate per rendered second. | Separate measured frequency from illustrative angular speed; document the time mapping and verify catalogue-derived rotation periods. |
| R23 | P2 | Verified: batch 6 | Full-width lesson cards overlap both side panels, blocking course items, Next and Close. | At 900/1024×600, all course entries remain scrollable and card navigation receives real pointer events. |
| R24 | P2 | Verified: current Mac, batch 6 | The physical window minimum ignores content scale; logical columns overlap at scale 2. | Maintain sufficient logical layout space at supported scales and verify flight actions remain reachable. |
| R25 | P2 | Verified supported domain; evolution outside scope | Rotational breakup and below-minimum neutron verdicts are returned by Structure but not acted on by the stage. | Define supported input domain and reject unsupported equilibrium requests before mutation; preserve modeled threshold events. Mass-shedding/subminimum evolution remains unmodeled. |
| R26 | P1 | Verified: batch 7 | Visual accretion removed physical mass/momentum without a receiving body and could delete the rest of a donor. | Cosmetic streams cannot mutate physical state; production frames match the kernel and contact mergers conserve mass/momentum, with pause/zero-time gates. |
| R27 | P1 | Verified bounded Newtonian/illustrative model | Several presets inflate black-hole horizons or multiply reaction forces, contradicting the physical-unit guidance. | Mass-consistent horizons and justified force/time mapping; explicitly separate and label any retained demonstration approximation, with independent checks. |
| R28 | P1 | Verified: bounded survival, batch 14 | The original flagship Trisolaris world breaches its declared extent before 60,000 years despite small energy drift; the observed failure time changes with numerical stepping. | Reproducible long-run gate, timestep/convergence and initial-condition sensitivity study; supported scenario behavior and lesson claims agree. Keep original failed controls visible. |
| R29 | P2 | Verified: bounded display model, batch 9 | Neutron self-lensing used an analytic approximation outside its stated domain, while lessons called it exact ray tracing and comments understated visible area. | Bound the display parameter without changing physics; document approximation/stylization, correct claims and inspect affected views. |
| R30 | P2 | Partial: targeted precision/domain guards verified | Fixed force/time cutoffs are removed; both kernels honor tiny caps and report detected numerical stops. Extreme finite inputs can still lose individual spatial/force components. | Bound the remaining scientific/numerical domain; test convergence and unsupported extremes independently of reference agreement. |
| R31 | P1 | Verified: batch 12 | A structural mass memo ignores changes below 0.1%, suppressing a Chandrasekhar event after a small merger. | A real small contact merger crossing the threshold detonates during the production frame; exact event checks cannot use a mass tolerance. |
| R32 | P1 | Verified: batch 12 | Trailing live edits can move to a different selected body, including reused IDs, or rebuild visuals on a removed body. | Cancel pending work on instance changes/removal/rejection; stale callbacks require exact scene membership; asynchronous regression and lifecycle checks pass. |
| R33 | P2 | Verified: batch 13 | Accepted position, velocity and name edits change the spec but leave live state unchanged; manual force/potential edits contaminate the drift reference. | Explicit vector/name edits reach live state atomically, ordinary edits preserve integrated coordinates, teleports restart trails, and energy-changing edits rebase diagnostics. |

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


## Batch 8 — physical black-hole scale and long-run recheck, 2026-10-03

R27's horizon component is corrected. Body derivation, structure and mass refresh
use the mass-derived Schwarzschild length; authored `rs` overrides are discarded.
The sandbox slider goes through the ordinary edit path. Contact mergers derive
from merged mass, including the case where a heavier measured star absorbs a
lighter black hole; stellar measurements and photospheric fields are removed.
The independent golden checks use the repository's stated G/c convention rather
than calling the same helper as the implementation. The linear mass relation
follows [NASA's Schwarzschild-radius explanation](https://imagine.gsfc.nasa.gov/educators/blackholes/imagine/page22.html).

The isolated lesson preserves its useful close view through `sceneScale`.
Feeding now uses a close, barycentric companion orbit with separated physical
surfaces and physical-size rendering. Its gas stream remains illustrative and
conserves the bodies' state. Sandbox framing uses the existing focus control.
Small AU radii remain readable in scientific notation instead of rounding to
zero. These presentation changes do not multiply physical radii.

Correcting the horizons exposes the wide black-hole pair's actual behavior: it
does not demonstrate an inspiral on the lesson's timescale. Scenario/course copy
now describes the wide orbit and leading-order strain estimate; the preset check
no longer permits disappearing bodies in that pair. Disc lessons use the isolated
close view. The neutron merger is identified as an accelerated illustration.
R27 remains **partial**: reaction multipliers and the source-dependent compact
force approximation still need independent model review. The structural model
reports Kerr surfaces, while contact, dynamics and lensing still use a
Schwarzschild scale; a full Kerr implementation is not claimed. The review also
found that a heavier star absorbing a lighter hole retains `emits_gw=false`;
compact-remnant radiation eligibility belongs in the remaining dynamics fix.

The new independent horizon checks fail **121/250** assertions against the old
implementation, then pass **250/250** after correction. All six fast/native
children pass, as do all eight rendered-suite children: course **35/108/0**, HUD
**54/0**, layout **124/0**, shared time **76/0**, transitions **59/0**, accretion
**106/0** under each kernel and all **35 presets**. The final HUD-format assertion
increases the transition gate to **60**; its final rerun is recorded below.
Evidence: `/tmp/astrarium-r27-before.log`, `/tmp/astrarium-b8-fast/report.json`,
`/tmp/astrarium-b8-rendered/report.json`, `/tmp/astrarium-b8-final/report.json`.
The old-code negative probe contains a macOS CA diagnostic; its numerical
assertion failure is independent of that diagnostic.

A combined lifecycle run initially gained one object in later true-scale rounds.
The isolated repeat passed. Investigation confirmed that `hud_acc` survived
between rounds, so identical accepted simulation times produced different clock
and drift text. The harness now resets that timer before each reload/action;
count limits and cache ownership are unchanged. The extra object's class was
not established, so this is a verified endpoint-control defect rather than a
proven identification of that object. Original failed evidence remains in
`/tmp/astrarium-b8-final`; temporary diagnostics are in
`/tmp/astrarium-b8-huddiag`. Inspected images in `/tmp/astrarium-b8-shots` show the
isolated shadow, sandbox focus and readable physical-size companion with live
particles. Final lifecycle/HUD evidence is recorded below.

### R28: the stability claim fails its own long-run recheck

No ordinary force, native integrator or Trisolaris initial condition changed in
this batch. A strict current-native-kernel run uses the authored timestep and
actual 60 FPS mapping (`0.35/60` years/frame, `maxStep=4e-4` years). Before the run,
we declared four finite bodies, no mergers, unchanged mass, complete accepted
time without guards, momentum error <=1e-7 M☉ AU/year, sampled relative energy
drift <=1e-6, world-to-inner-barycenter distance <=10 AU and Gamma-to-inner distance
<=100 AU. These broad extent bounds detect hierarchy loss; they are not an
analytical stability theorem. Sampling occurs every 1,000 frames.

The first observed extent failure is at **18,094.9999990768 years**, with world
separation **20.659937165 AU**. A repeat reproduces it. A separate continuous
60,000-year diagnostic retains that failure and exits **1**, reaching a world
separation of **53,538.925912 AU** from the stellar barycenter, outward speed
**1.277974887 AU/year** and positive instantaneous far-field binding proxy.
This is evidence of ejection in that numerical trajectory. Sampled maximum
relative energy drift is only **5.2622578e-8**; small whole-system energy error
cannot establish orbital stability. Four bodies, zero mergers, accepted time,
mass, momentum and guard checks remain valid. The full diagnostic performs
**154,285,715 substeps**, with at most **15/frame**.

`tools/stabilitycheck.gd` makes the strict test reproducible. The opt-in
`python3 tools/check.py stability` suite requires both target and accepted time
to be 60,000 years and zero failures; a shorter `years=10` smoke cannot satisfy
that marker. The repository gate reproduces the first failure and exits **1**;
it is deliberately not relabeled an expected pass. The fast default omits this
long-running suite, and README explicitly identifies its current failure. The
unsupported stability statements in `docs/scenarios.md` and the flagship
in-app description are corrected. Unrevalidated 60,000-year promises are also
removed from the three neighboring hierarchy variants; this does not establish
that those variants fail.

Evidence: `/tmp/astrarium-b8-stability/report.json` and `stability.json`; the
continuous trajectory, serialized endpoint and commands are in
`/tmp/astrarium-b8-trisolaris/REPORT.md`. These headless diagnostics retain the
known macOS system-CA message, specifically allowed by the runner; the numerical
failure is not an engine-message inference. This is one trajectory at one
step configuration. A convergence and initial-condition perturbation study is
needed before choosing new scenario parameters or making a stronger physical
claim. Do not widen the bounds to preserve the former narrative.


Final import, transitions **60/60**, HUD **54/0**, layout **124/0**, and the combined
five-round soak pass after the final numeric-format/harness changes. Exact
post-warmup counts (objects/resources/nodes/orphans): spawn/remove
**6389/137/1619/0**, mass edits **6768/137/1720/0**, true scale
**6788/137/1720/0** in every round. The refreshed sandbox screenshot was inspected:
physical radius/ISCO values are readable and focusing still reveals the shadow.
Evidence: `/tmp/astrarium-b8-verified/report.json` and `sandbox-focus.png`.

After removing the remaining in-app stability promises, the full course gate
passes again (**35 lessons / 108 steps / 0 errors**):
`/tmp/astrarium-b8-copy-final/report.json`. Independent final diff review found
no further blocker for the bounded horizon fix; the radiation-eligibility
follow-up above remains open.


## Batch 9 — supported structural requests and derived remnant state, 2026-10-04

R25 now has an explicit supported input domain. `Structure.input_error` rejects
nonfinite/nonpositive mass, invalid measured radii, invalid physical spin,
non-black-hole rotation above the modeled mass-shedding rate, and neutron mass
below the stand-in's shared minimum. Measured `spinHz` retains precedence over
`spinFrac`; 0.999–1 remains an allowed near-limit warning. The 0.1 M☉ lower
boundary is a model limit, not a universal physical disintegration threshold.
[The structure note](physics/structure.md#supported-requests-and-physical-events)
links the primary EOS/rotation studies and distinguishes requests from events.
Mass shedding and subminimum evolution remain unmodeled; R25 is **partial**.

The stage validates copied candidates before changing IDs, bodies, visuals or
camera state. Editing starts from live mass, including after a merger, and
removes superseded measurements before validating the new mass/frequency pair.
A preset's entire body list is built and checked before clearing the live scene.
Failed live edits restore controls, clear pending requests and safely settle an
already-running throttle timer; unrelated open editors are preserved. Unsupported
Foundry drafts cannot spawn, and the callback handles rejection. Existing TOV
collapse and Chandrasekhar detonation still execute. This gate covers the stated
structural fields, not a comprehensive schema for every body/preset field.

The R27 remnant-eligibility defect is corrected: `derive_body` owns `emits_gw`
for spawn, edit and transformation. Black holes and neutron stars default true,
ordinary bodies false; explicit non-null `emitsGW` values override the default.
A heavier star absorbing a hole now becomes radiation-eligible, neutron remnants
inherit the same policy, and compact-to-ordinary reclassification resets it.
Reaction multipliers, source-dependent compact forces and full Kerr behavior
remain outside this fix.

R29's neutron display parameter is capped at **u=0.5**, the supported boundary
of [Beloborodov's approximate relation](https://arxiv.org/html/astro-ph/0201117v1).
Physical radius, mass and compactness are unchanged. The retained lower display
floor is explicitly illustrative. At u=0.4 the approximation predicts 83.33%
visibility; it is neither the former 60% comment nor an exact ray-traced result.
The lesson and preset comment are corrected; the shader's stylized rim and
mesh-disc proxy are identified. Equations, angular/domain accuracy and omissions
live in [the model note](physics/neutron-light-bending.md), and the long visual
header/port narration is reduced to useful pointers.

Independent reviews found no remaining blocker in these bounded changes. The
new production input gate passes **179/179** assertions: rejected-state snapshots,
defaults, measured spin, accepted warnings, actual merged mass, preset atomicity,
control/timer recovery, existing events and all authored preset body specs. A
finite extreme radius that overflows the critical-rate calculation rejects with
a numerical-range reason before frequency division. The expanded transition
check passes **115/115**, covering eligibility defaults/overrides, remnant paths
and actual neutron shader uniforms on either side of the supported domain.

All six fast/native children pass. Across the original integration and repaired
targeted reruns, all **nine** rendered-suite children pass: course **35/108/0**,
HUD **54/0**, layout **124/0**, shared time **76/0**, transitions, input gate,
accretion **106/0** with each kernel and all **35 presets**. The first input
harness lacked a dictionary type annotation and failed to parse; its stalled
child was terminated and the failed report retained. It is not counted as a pass.
After correcting that and adding timer/radius edge cases, the gate passed; the
final critical-rate guard was followed by transitions/input/preset reruns.
Evidence: `/tmp/astrarium-b9-integrated/report.json`,
`/tmp/astrarium-b9-final/report.json`, `/tmp/astrarium-b9-verified/report.json`.

A temporary injected stage deliberately advances an ID after rejected spawning
and changes camera radius after rejected edits. The input harness detects **22**
assertion failures, completes and exits **1**, without engine errors; the strict
runner rejects it. It does not mask failures as expected passes. The negative
fixture predates the final numerical edge case and runs **176** assertions.

The combined five-round soak is exactly flat after warmup
(objects/resources/nodes/orphans): spawn/remove **6391/137/1619/0**, mass edits
**6770/137/1720/0**, true scale **6790/137/1720/0**. Evidence:
`/tmp/astrarium-b9-final/05-targeted-soak.log`. Inspected visible-band images show
1.4 M☉ physical/display compactness **0.33120065**, and 2.0 M☉ physical compactness
**0.51538421** with display **0.5**. The X-ray image renders without shader errors;
the image does not establish quantitative flux accuracy. Final lesson-card and
import evidence is retained in `/tmp/astrarium-b9-cleanup`; the accepted lesson
image/report is `/tmp/astrarium-b9-lesson-final`. Earlier screenshot helpers
targeted an incomplete lesson key and then retained a body across reload; those
attempts are not accepted lesson evidence. The corrected helper checks the full
lesson key and reacquires the live body. The card text, Next and Close are visible.

R28 remains an explicit failure. The stability suite repeats the same observed
extent violation at **18,094.9999990768 years**, world distance **20.659937165 AU**,
and exits **1** with unchanged bounds. Eligibility changes do not affect its
ordinary-body trajectory. Evidence: `/tmp/astrarium-b9-stability/report.json` and
`stability.json`. Its known macOS system-CA diagnostic is specifically allowed
and retained; the orbital failure is independently numerical. Convergence and
initial-condition sensitivity work still precede any replacement stability claim.


## Batch 10 — conservative compact orbits and stability diagnostics, 2026-10-04

R27's source-dependent black-hole forces are replaced in both kernels with
symmetric Newtonian pair gravity. Unequal holes and mixed hole/star pairs now
have equal opposing forces and the existing Newtonian energy potential matches
the force. Ordinary Plummer gravity is unchanged. This deliberately limits body
motion to weak-field orbits: it does not promise a dynamical ISCO, relativistic
precession or plunge. A fixed-source
[Paczyński–Wiita model](https://arxiv.org/html/0904.0913v1) does not justify
the former self-consistent binary force. The universal native library is rebuilt.

Independent invariants pass **274/274**, including 24 compact-force/orbit checks
across native and GDScript. They test action/reaction, body order, finite-difference
energy gradients, integrated time, momentum, center trajectory and orbital energy.
All nine native-parity scenarios pass at unchanged tolerances. In an isolated
copy, restoring the old source-wise force produces **9 failures / exit 1**.
Evidence: `/tmp/astrarium-b10-compact-invariants.log`,
`/tmp/astrarium-b10-compact-native.log`, `/tmp/astrarium-b10-legacy-force.log`.

The strain instrument now reads actual AU separation, without contact-radius
rescaling. Independent SI goldens and separation/contact invariance checks pass;
the science gate completes **30/30**. Restoring the old instrument produces
**7 failures / exit 1**. Strict frozen compatibility still fails explicitly,
now with four intentional differences: two obsolete contact-scaled strain
readings and two existing live-transit comparisons. Frozen fixtures are retained
and no tolerances are widened. Evidence: `/tmp/astrarium-b10-negative`.

The GW instrument's long fake-size/chirp introduction is removed; its adaptive
plot scale and scientific labels show the corrected tiny amplitudes. The caption,
phase-derived time axis and boost tooltip identify circular estimates and
illustrative drag. Ineffective boosts are removed from the wide black-hole and
neutron-star views; their saved IDs remain, while the neutron preset no longer
advertises a merger or kilonova. The ordinary-star inspiral description also
states its exaggerated drag and missing hydrodynamics. R27 remains **partial**:
contact-window drag has no bound-orbit test, arbitrary boosts and a per-step cap;
strong-field dynamics and full detector waveforms are not implemented. The
[compact model note](physics/compact-dynamics.md) records those limits and primary
sources. The native header loses unsupported historical timing/port narration
while retaining the buffer ownership/layout contract. Guard guidance recommends
reducing requested simulation rate and makes the accuracy cost of larger steps
explicit.

R28's authored baseline still fails at **18,094.9999990768 years**. A six-run study
keeps bounds and observation cadence fixed: half-step fails around 8,482 years,
quarter-step passes sampled bounds through 60,000, eighth-step fails around
12,460. World apsidal-orientation offsets of ±1e-6 radians fail around 27,224
and 14,578 years. The next refinement defeats the isolated quarter-step pass;
there is no justified timestep-only fix or converged stability claim. No authored
Trisolaris orbit/timestep is changed.
[Scenario notes](scenarios.md#trisolaris-hierarchical-initial-conditions) retain
the table, limitations and reproduction instructions; experiment logs/reports
are under `/tmp/astrarium-b10-convergence`. The early option `phase_offset` was
renamed `world_rotation` because rotating the ellipse changes orientation, not
anomaly along that ellipse. Earlier commands/JSON names remain as actually run.

The stability tool rejects unknown/repeated/malformed arguments, larger caps,
caps below the integrator floor and invalid report paths. Any explicit cap or
orientation selects a diagnostic marker, even if numerically unchanged. The
runner accepts only one authored 60,000-year baseline completion and rejects
conflicting success/failure or baseline/diagnostic terminals. **8/8** marker
cases match expectations after fixing a conflict loophole found during review:
`/tmp/astrarium-b10-negative/marker-fixed/report.json`. The earlier failing
marker probe is preserved separately.

Reports use full-precision decimals plus versioned little-endian binary64 hex
for mass, position and velocity, with field order recorded. A probe of Godot
4.7.2's decimal decoding found three one-ULP differences in 28 final physical
values even with full-precision output; it does not independently isolate the
parser's internal cause. The binary round-trip preserves **28/28** exactly.
Earlier matrix reports predate this encoding and are trajectory summaries, not
accepted exact state archives. Failed precision probes remain in
`/tmp/astrarium-b10-precision` and `...-precision-final`; accepted evidence is
`/tmp/astrarium-b10-precision-binary/report.json`. This is an evidence-retention
limitation under R18. Independent review also exposed R30: the structural gate
does not reject arbitrary tiny systems below numerical force/time cutoffs.

All six fast/native and all nine rendered children pass in the integrated run:
`/tmp/astrarium-b10-integrated/report.json`. After final caption/plot fixes, the
course (**35 lessons / 108 steps / 0 errors**) and HUD (**54/0**) pass again;
black-hole/neutron lesson plots and the fresh simulation-settings overlay are
inspected. The first settings screenshot followed the interaction walk and was
not an overlay image; the fresh one is accepted. Final visible evidence is under
`/tmp/astrarium-b10-visual-final`. Five-round post-warmup counts
(objects/resources/nodes/orphans) are exactly flat: spawn/remove
**6388/137/1619/0**, mass edits **6767/137/1720/0**, true scale
**6787/137/1720/0**.

After the final native-header rebuild and state-encoding changes, all six
fast/native children pass again. The authored long-run gate still exits **1**
at the same extent violation, and its final report retains schema-1 exact
states: `/tmp/astrarium-b10-verified/report.json` and `stability.json`.
Python's decimal decoder matches all **56** initial/final physical doubles
against the binary payloads. The observed one-ULP discrepancy is specific to
the tested Godot decoding path; no broader parser claim is inferred.


### Batch 11: numerical cutoffs, rollback and accepted clocks

Removed the fixed `1e-9 AU` force cutoff, `1e-8 year` step floor and
`1e-12 year` request remainder cutoff. Tiny resolved systems now retain their
Newtonian force/potential and requested cap. Scaled distance and free-fall
calculations avoid false zero separations from squared-norm underflow. Positive
calls resolve existing contacts before choosing a step; nonpositive calls remain
no-ops. The work guard counts successful steps and accepts only their time.

Both kernels restore a failed position/velocity or GW update and reject unsafe
merger candidates while retaining earlier valid events. An explicit native status
survives callbacks, final steps and an exhausted work guard. Review caught a
second defect: resetting the native accumulator after a merger allowed later
tiny steps to move bodies without increasing accepted time. The ten-slot header
now carries the whole call's accepted time and original budget. The production
clock also retains a compensated remainder; assigning a new epoch clears it.
The HUD distinguishes detected numerical stops from the work limit. The unused
HUD statistics method and its misleading larger-step advice were removed.

Spawn/edit/preset preflight validates three finite position/velocity components
and finite nonnegative contact/softening distances. Derivation now applies
explicit softening on both spawn and edit. Tiny black-hole structure uses its
actual mass, rejects underflow/overflow of derived scales, and describes hot
Hawking emission without promising background-driven growth or simulating
evaporation. The remaining ordinary structural mass clamp and extreme
floating-point limits are documented; **R30 remains partial**, not a guarantee
of arbitrary finite-double dynamics. Spatial increments below an absolute
coordinate's ULP and underflow in extreme force/energy/strain products remain.

The new strict numerical harness passes **128/128** assertions, including
analytic tiny forces/potentials, short durations down to `1e-200` years,
512-to-1024-step orbital refinement, rollback, valid merger prefixes and the
native restart regression. Isolated HEAD rejects **42 of the original 83**
assertions; an isolated old-wrapper mutation rejects **3/128**. Evidence:
`/tmp/astrarium-b11-domain`. These negatives retain their actual test versions.

The updated authored Trisolaris gate still exits **1**, now at the first sampled
extent violation near **56,332.5000096394 years**: world **13.5535453609774 AU**,
maximum energy drift **5.248293e-8**. The changed remainder and budget arithmetic
changes floating-point stepping and the chaotic trajectory; this later violation does
not establish improved stability. No authored orbit, cap or bounds changed.
**R28 stays open**; `/tmp/astrarium-b11-stability` retains the failed report and
exact binary states. The batch-10 refinement matrix remains historical evidence
for its implementation, not a convergence result for this one.

All seven final fast/native checks and four full launches pass:
`/tmp/astrarium-b11-final-cpu/report.json`. Final native/rendered results and
production input/clock assertions are retained under
`/tmp/astrarium-b11-final-rendered`. The final compensated-clock overflow check
also passes **231/231** production input/clock assertions in
`/tmp/astrarium-b11-visual/structure-final.log`. The precision-warning screenshot and
five-round lifecycle evidence are in `/tmp/astrarium-b11-visual`; post-warmup
objects/resources/nodes/orphans remain flat at **6390/137/1619/0** (spawn/remove),
**6789/137/1720/0** (mass edits), **6809/137/1720/0** (true scale).


### Batch 12: measured editor work and safe edit ownership

R15 profiling against `828c5e9` identified a specific avoidable cost: unchanged focused graph
refreshes sampled 240 structures over the broad range, then another 240 over
the focused range, at every 10 Hz refresh. Local warmed headless CPU fixtures
(five batches, Godot 4.7.2, Apple M5) measured **5.85–7.70 ms** per unchanged
focused refresh. Input/view invalidation reduces that fixture to **16–19 µs**;
unchanged inspector formatting falls from **41–61 µs** to about **0.25 µs**.
Full-range unchanged sync adds roughly **4–6 µs** of snapshot/serialization
work, and genuinely changed spin still costs **3.1–4.1 ms** to resample. These
measurements exclude GPU work, drawing/layout and input-to-display latency;
they are not frame-rate promises. Visual factory construction/disposal was
measured separately, but visual rebuild/interaction spikes remain **R15 partial**.
Final baselines, fixture commands, all five batches and limitations are retained
in `/tmp/astrarium-b12-profile/REPORT.md` and `profile-final-{head,fixed}.log`.

The inspector now consumes the canonical body structure. Equal-valued replacement
dictionaries update canvas ownership while retaining the no-redraw optimization.
The curve retains one sampled result and skips unchanged view work; it snapshots
its inputs and includes physical `spinHz`. Hypothetical mass edits share the
production measurement-removal list. The live handle uses the canonical measured
radius, and the axes include it even when it lies outside the hypothetical curve.
Valid tiny black-hole masses remain their actual value in controls and the graph.
The explanation distinguishes current measurements from mass-edit estimates.
Touched introductions/banner comments and an unused port-era graph factory
wrapper were removed; no second threshold or structure schema was introduced.

Two correctness defects found while profiling are fixed. **R31:** a white dwarf
at **1.439999 M☉** absorbing **3e-6 M☉** crosses Chandrasekhar, yet the old 0.1%
memo skipped the event. The clean pre-fix probe exits **1**; exact mass comparison
now allows the production frame to detonate it. **R32:** switching targets during
a trailing edit moved a queued mass change to the next body. The isolated HEAD
fixture fails **2/4** assertions with the second body's mass changed from 2 to
1.2; the corrected fixture passes **4/4**. Pending edits now belong to body
instances, are cancelled on switches/rejection/removal, and stale stage callbacks
must still match exact scene membership. Removed bodies are marked inactive,
preventing orphan visual reconstruction. Negative logs are retained under
`/tmp/astrarium-b12-profile`.

The strict production editor harness passes **83/83** assertions across measured
radius/frequency edits, equal-valued snapshots, sample predictions, mergers,
collapse/reclassification, tiny bodies, timer cancellation, removal and reused
IDs. All seven fast/native and ten rendered children pass in the integrated and
reviewed runs: `/tmp/astrarium-b12-integrated/report.json` and
`/tmp/astrarium-b12-reviewed/report.json`. The final tiny-body assertions and
HUD explanation are additionally checked under `/tmp/astrarium-b12`; the course
remains **35 lessons / 108 steps / 0 errors**, with **54/0** HUD interactions.
Focused, measured-radius and tiny-body screenshots are inspected there.

Five-round post-warmup objects/resources/nodes/orphans are exactly flat:
**6390/137/1619/0** (spawn/remove), **6789/137/1720/0** (mass edits),
**6809/137/1720/0** (true scale), and **6340/136/1593/0** for the new editor soak,
which opens focused graphs, edits multiple body types and cancels a pending edit
on removal. No physics kernel or authored Trisolaris configuration changed;
**R28 remains open** at the batch-11 failed baseline.

### Batch 13: atomic body edits and bounded input schemas

**R33:** valid position, velocity and name patches were accepted into the spec
without updating the live body. Edits now validate effective live-state snapshots
before mutation, preserve integrated coordinates for omitted/null vectors, apply
explicit vectors in double precision, and derive names through the shared spawn/
edit path. Teleports immediately update scene placement and restart the trail,
including while paused. Energy-changing edits reset the drift reference after
structural consequences; radius-dependent softening and fixed-mass neutron
collapse are covered. Ordinary name changes retain the energy reference.

The public edit boundary also requires exact scene membership, extending R32's
callback protection to direct callers and revived removed objects. Unsupported
type changes are rejected instead of silently discarded. R10's input gate now
rejects unknown/non-string types and malformed temperature, luminosity, phase,
metallicity, composition, rotation and boolean fields before spawn/edit/preset
mutation. Existing catalog entries, null defaults, signed rotation, phase
endpoint clamping and zero day-length fallback remain supported. This is a
bounded schema: visual options remain open and finite values do not establish
safe arithmetic for every combination, so **R10/R30 remain partial**.

Refreshing accepted specs exposed an overly broad mass-curve cache key. Name and
trajectory fields are now excluded from hypothetical equilibrium sampling;
rename/teleport checks require the sampled array to remain the same instance.
AGENTS.md now distinguishes intrinsic derivation from state-vector ownership,
avoiding guidance that would rewind a body during a merger/reclassification.

The rendered pre-fix regression fails **12/98** assertions with exit 1 in
`/tmp/astrarium-b13/editor-baseline.log`. An intermediate non-string type edit
also exposed GDScript's invalid mixed-type comparison; the guard now checks the
type before comparing, with the failed engine log retained as
`structureinput-type-probe-engine.log`. The final editor check passes **115/115**,
the input check **370/370**, and all ten rendered children pass in
`/tmp/astrarium-b13-reviewed/report.json`. The seven fast/native children passed
in `/tmp/astrarium-b13-integrated/report.json`; that earlier rendered run correctly
stopped on the graph-cache regression instead of hiding it. The course remains
**35 lessons / 108 steps / 0 errors**, and HUD interactions remain **54/0**.

Five-round post-warmup object/resource/node/orphan counts are exactly flat:
**6390/137/1619/0** (spawn/remove), **6789/137/1720/0** (mass edits), and
**6396/137/1613/0** (editor, now including position/velocity/name changes), with
zero failures or shutdown leaks in `/tmp/astrarium-b13/soak.log`. Independent
subagent review found no remaining blockers. Physics forces/integration and
authored Trisolaris settings are unchanged; **R28 remains open**.

### Batch 14: a bounded Trisolaris design and honest orbital diagnostics

R28's unchanged baseline reproduces the 56 332.5000096394-year sampled extent
failure with exit 1 in `/tmp/astrarium-b14-baseline/report.json`. The design
argument applied an isolated circular-planet cutoff to an eccentric four-body
configuration. Primary-source screening supports increasing planetary periapsis;
the single candidate **e = 0.20** was declared before its lifetime was measured.
Only the former world eccentricity **0.42** changes. Masses, semimajor axes,
Gamma's orbit, authored step cap and every gate bound remain unchanged. Sources,
screening calculations and limitations are in
[scenario notes](scenarios.md#trisolaris-hierarchical-initial-conditions).

The flagship now reuses the existing circumbinary constructor instead of a
duplicate body builder. At e = 0.42 the shared builder matches **all 28 physical
binary64 values** of the original initial state. Its small planetary-mass/recoil
approximation remains explicit, avoiding another simultaneous dynamical change.
The check adopts the production compensated accepted-time clock and reports its
remainder, explicit numerical stops, runtime/force metadata and exact states.
Jacobi two-body osculating snapshots supply eccentricity, energy, inferred apses
and hierarchy ratios. These are descriptive approximations, not new pass bounds
or definitive escape criteria; raw zero softening selects the radius-based default.

All **nine predeclared runs** reach **60 000 accepted years / zero remainder /
zero failures**: h, h/2, h/4, h/8, plus authored-cap world-orientation offsets
±1e-6, π/2, π and 3π/2. Worst sampled world/binary extent is **2.286519 AU**,
Gamma **29.699423 AU**, momentum error **1.516e-11 M☉ AU/year**. Energy-drift
maxima at the four caps are **5.19544e-8 / 1.04481e-8 / 2.49480e-9 / 6.33114e-10**.
No merger, mass change or frame/numerical guard occurs. Maximum inferred world
eccentricity is **0.2984**, minimum inferred periapsis **1.2793 AU**. The complete
matrix and exact reports are in `/tmp/astrarium-b14-study/matrix-report.json`;
two independent headless processes ran concurrently, so wall times are not
performance comparisons. `python3 tools/check.py stability-study` regenerates
the same nine cases sequentially with strict baseline/diagnostic marker separation.

The e = 0.42 control still fails at **56 332.5 years** under the corrected clock,
with the same physical final state and first failing frame. Its inferred world
eccentricity reaches **0.9355**, periapsis **0.5048 AU** and extent **13.553545 AU**.
Point-mass orbital energy remains negative at that sample, so the extent failure
is not mislabeled as definitive ejection. The failed control is retained in
`original-control.{json,log}`. The earlier step-sensitive results remain historical
evidence rather than being reclassified as successful validation.

A five-run 20-year refinement against h/32 shares exact initial states and shows
second-order convergence: all-body position error ratios **3.926 / 4.046 / 4.192**
against finite-reference expectations **4.012 / 4.048 / 4.200**. World barycentric
position error falls from **1.56733e-4** to **2.35107e-6 AU**. The full position/
velocity tables and calculations are in `/tmp/astrarium-b14-convergence/REPORT.md`.
Authored-cap all-body position RMS error is **0.0106542 AU** after 20 years:
accumulated binary phase error remains material, even with small energy drift.
R28 closes as bounded survival across tested settings, not exact long-run phase,
indefinite stability or a statistical lifetime theorem.

The production climate model, sampled every accepted frame for 200 years with
quiet stars, retains changing seasons: **0.5343–1.6418 S⊕**, **267.14–305.42 K**,
about **154.97 temperate / 44.94 cold / 0.09 hot years**. This is a short-term
product-behavior check, not a full-lifetime climate envelope. The description is
updated accordingly and the rendered Trisolaris screenshot is inspected.

All **17 fast/native/rendered children** pass in
`/tmp/astrarium-b14-integrated/report.json`; this includes the complete course,
presets, numerical domain, inputs and editor regressions. Diagnostic formula
checks pass **15/15**, option checks **16/16**, and **10/10** runner-negative cases
reject forged success, short/incomplete targets, errors and conflicting terminal
markers. Five complete preset/launch cycles remain flat at **7456 objects /
307 resources / 1810 nodes**, with no shutdown leaks in `leak.log`. Independent
scientific review found no blockers.

The required five-round soak also stays exactly flat after warmup:
**6393/137/1619/0** (spawn/remove), **6792/137/1720/0** (mass edits), and
**6812/137/1720/0** (true scale), in object/resource/node/orphan order.
`/tmp/astrarium-b14-study/soak.log` reports zero failures and shutdown leaks.

### Closing the review cycle

At the end of batch 14, R28 was the remaining fully open P1 finding. The correctness remediation was
close to closure; the entire cycle still has twelve partial/profiling/backlog
findings and an actual-Windows verification gap. The next work should be bounded
around evidence and final disposition, rather than expanding the product's
scientific model whenever another approximation is noticed:

1. Measure launch/studio GPU cost, visual-edit spikes and per-frame submissions
   (R14–R16), then fix the costs the measurements establish.
2. Finish a bounded architecture/interface pass (R09/R10), settle geometry
   ownership (R12), and address remaining comment/evidence/release hygiene
   (R13/R18/R20). Portable CI and clean-clone verification remain unfinished.
3. Re-review the final code and AGENTS.md, rerun the relevant integrated/export/
   lifecycle/long-run checks, and give every remaining finding a clear verified,
   deferred or bounded-model disposition. Windows evidence remains unverified
   until an actual Windows run exists; the rotational/compact/extreme-numeric
   limitations (R25/R27/R30) retain their documented scope.

### Batch 15: ownership, measured churn and reproducible release gates

The typed `OrreryCamera` owns orbit/free motion, framing, picking and near-plane
calculation. The stage retains frame order and flight/surface ownership. Fifty
regressions cover floating-origin precision, tracking/easing, controls and atomic
schema rejection. Independent review caught huge finite camera distances that
overflow float scene calculations; authored radius requests now use the existing
wheel interval, 1e-6–20000 scene units. Derived body framing keeps its own rules.
Sky patches and preset sky data share an explicit validator; 58 checks reject
unknown fields/environments, malformed weights and unsafe parameter values.
R09/R10 close for these targeted boundaries, not every dynamic dictionary.

Continuous stellar spin edits retain their visual/activity pools and update
deformation and temperature uniforms. Stable body lists and inspector fact
schemas retain their Controls. The editor gate passes 121 checks, including
control identity, changed shader values and changed-name invalidation. Other
intrinsic edits still rebuild visuals. The settled eight-case profiler records
CPU action/submission, geometry and explicitly unavailable GPU timings. Local
spin-edit medians fall from 15.983 ms to 8.596 ms in the first before/after runs;
the final idle-machine probe records 4.275 ms, p95 5.264 ms, maximum 17.705 ms.
Scheduling affects these observations; this is not a portable frame budget.
Toggling only the compute uniform cache in final code changes the sum of solar
dispatch CPU medians from 0.184 to 0.010 ms. Godot owns dependency invalidation.
The same backend returns zero GPU timestamps, so GPU time remains unverified.
Methodology and limits are in [performance notes](performance.md).

Crafts use ordinary screen-space LOD. Settled Saturn V near-view primitives are
24,323 / 12,205 at biases 128 / 1; the distant comparison is 21,053 / 8,835.
Both near renders were inspected. Open shells remain double-sided; per-mesh
culling needs measured GPU evidence. The screenshot harness now releases its
craft cache at shutdown, removing the mesh/material leaks found during this
comparison. Per-sun packed-array caching is deferred because copy-on-write
submission can preserve allocations despite a reused array variable.

Blender builds consume exported runtime vehicle dimensions/engine metadata and
validate stage/part counts before export. All 14 vehicle/pad/facility builds pass;
all nine authored craft pass asset articulation, audit and clearance checks.
Authored/procedural height and datum parity passes all 18 poses at the unchanged
2 cm tolerance. Procedural fallback remains a product requirement; decorative
width/silhouette and material differences are not falsely called full parity.

Redundant introductions, banner separators, port-history narration and unused
stellar fallback implementations are removed across runtime owners and tools.
Units, ownership and numerical reasons remain; flight derivations move to
[their canonical document](physics/flight.md). Root and scoped guidance now
describe camera/schema ownership, physical metadata, measured performance and
verification limits. The [evidence policy](evidence.md) retains the 553-image,
78.90 MiB historical archive and directs new output to ignored/CI evidence.
Deleting useful archived verification is not an optimization of the game.

Native builds/descriptors and export presets cover macOS universal, Linux and
Windows x64. The clean-check gate clones committed source without generated
models or import caches, rebuilds native code and verifies procedural contracts,
export resources and isolated native startup; optional rendered boot exercises
the production application. Pack exports now include an explicit native sidecar
because the OS loader cannot load its library from the resource ZIP. CI is wired
for the three operating systems. Actual Windows/Linux execution remains pending;
native save publication assertions now identify the platform being tested.

Integrated evidence: 25 headless/native/asset/procedural/export children pass in
`/tmp/astrarium-closure-headless/report.json`; 22 fast/native/rendered/lifecycle
children pass in `/tmp/astrarium-closure-integrated/report.json`, including all
35 presets, 108 course steps, HUD interactions/layout and 370 input checks.
Five-round soak counts stay exactly flat after warm-up: **6393/138/1619/0** for
spawn/remove, **6792/138/1720/0** for mass edits and **6812/138/1720/0** for true
scale (object/resource/node/orphan order). Leak and shutdown gates pass.
Strict 60,000-year Trisolaris and all four full flight gates pass in
`/tmp/astrarium-closure-final-science/report.json`. Independent review found the
camera range defect above and no further blockers in these bounded changes.
The committed candidate `80e46b8` also passes the clean-clone gate with all 16
children and a rendered exported boot outside the source checkout. Evidence:
`/tmp/astrarium-closure-clean/report.json`, `complete: true`, `rendered_boot: true`.

### Batch 16: targeted representability and final disposition

R30's next bounded fix stops entirely lost **force-free** drift in both kernels.
Old/new acceleration must both be zero, velocity nonzero and the entire position
unchanged; rejected candidates roll back without accepting elapsed time. A later
failed candidate preserves its accepted prefix. Tiny accelerated velocity kicks
remain supported. The original native binary fails the new drift/prefix probes,
so these tests distinguish the defect from parity alone.

Energy diagnostics preserve ordinary arithmetic exactly, rescaling exceptional
energy products with binary powers and softened distances by magnitude. Analytic
fixtures recover representable terms after intermediate underflow/overflow and
verify subnormal rounding. Truly unrepresentable positive terms report `NAN`,
with visible unavailable/recovery behavior in the HUD. A zero-energy reference
cannot silently report zero drift after energy becomes nonzero. Ordinary body
requests below the existing 1e-12 M☉ structure floor now reject atomically instead
of publishing a structure with a different mass. Black holes keep their separate
domain. The [numerical contract](physics/numerics.md) states the remaining limits.

Verification: **156 numerical / 274 invariant checks**, all nine native comparison
presets at unchanged tolerances, **377 structure input / 127 editor checks**,
and all ten rendered-suite children pass. The subnormal camera rejection fixture
uses a runtime binary power so decimal parsing cannot turn its input into zero;
all 50 camera checks pass. The required strict **60,000-year Trisolaris** gate
passes again after the integration change. Logs are in
`/tmp/astrarium-r30-*.log`, `/tmp/astrarium-closure-r30-rendered/`,
`/tmp/astrarium-closure-r30-editor-final.log` and
`/tmp/astrarium-closure-r30-stability/`. The native library was rebuilt.

Every finding now has an explicit disposition. Four remain partial:

| Finding | Completed evidence | Remaining work and trigger |
|---|---|---|
| R14 | Normal craft LOD, settled primitive comparisons, inspected near renders | Obtain usable launch/studio GPU timings, then classify closed meshes before changing culling. Current Metal timestamp APIs return zero. |
| R16 | Engine-owned uniform cache with controlled submission comparison and flat lifecycle counts | Measure per-sun packed-array allocations before choosing a cache that actually removes copy-on-write cost. |
| R20 | Integrated runner, portable build/descriptors, CI definition, clean macOS clone/export/rendered boot, prior interaction/layout gates | Execute actual Linux/Windows CI and define supported-device GPU/frame budgets. CI configuration is not a passing remote run. R19's actual-Windows publication gap shares this gate. |
| R30 | Independent convergence/extreme arithmetic tests, whole force-free drift stops, diagnostic availability and ordinary input floor | Individual components, accelerated kicks and extreme force intermediates can still lose precision; any broader domain must have predeclared representability and convergence gates. |

R25/R27 close as supported model boundaries: unsupported equilibrium inputs reject
before mutation, and compact motion is labeled Newtonian with illustrative drag.
Mass-shedding evolution, arbitrary compact strong-field binaries and indefinite
Trisolaris stability are additional scientific models, not implemented fixes.
The procedural/authored silhouette differences are explicit product choices.

Final architecture review still finds `main.gd` substantial (2338 lines before
the final diagnostic addition), and visual-specific options remain an open
dictionary. Further extraction should target scenario lifecycle or UI wiring
when changing that responsibility, with typed ownership and affected gates;
splitting functions just to lower a file's line count adds maintenance work.
The revised guidance records executable contracts and admits verification gaps.
This review has fixed the demonstrated correctness defects; it has not certified
every behavior, every device or every finite scientific input.

The final committed code candidate `afbaacd` passes the clean clone/native rebuild,
all 16 procedural/export children, isolated native startup and rendered exported
boot: `/tmp/astrarium-review-final-clean/report.json` records `complete: true`
and `rendered_boot: true`. The subsequent documentation-only closure records
this evidence and updates the engineering notes; it changes no executable code.
Independent final re-review of `afbaacd` found no blockers in diagnostic recovery,
atomic input rejection or their regressions; it corrected the scaling description
above and confirmed that external/numerical gaps remain explicit.

### Batch 17: usable profiling and actual Linux verification

The profiler now identifies the actual driver/method and exercises authored
Falcon 9 launchpad and ascent scenes in addition to the original eight cases.
Flight rows retain phase, mission seconds and altitude. Both the pre-sample and
post-sample guards require ascent, so prelaunch, landed or destroyed craft cannot
be reported as an ascent measurement. The runner requires a ten-case completion
marker with zero failures.

A Vulkan/Forward+ probe on Apple M5 returned GPU timings and exposed a profiler
units defect: pinned Godot 4.7.2 returns compute GPU timestamps in nanoseconds,
despite the public documentation saying microseconds. Conversion is corrected;
prior compute GPU numbers from the exploratory Vulkan probe were 1000× too
large and are discarded. Metal's earlier zero values and CPU measurements are
unaffected. Two corrected ten-case probes complete with zero harness failures.
The guarded rerun measures pad/ascent viewport GPU medians of **8.361 / 7.933 ms**
and lens-march compute median **5.549 ms**. These overlap and cannot be added.
MoltenVK prints a pipeline-cache `VK_INCOMPLETE` diagnostic; these measurements
remain provisional alternate-backend evidence. The default Metal timing APIs
remain unavailable. A separate Metal System Trace confirms actual GPU execution,
with 33,408 active intervals attributed only to the test process; its overlapping,
unlabeled intervals do not establish per-case budgets. See
[measurement scope and evidence](performance.md#additional-backend-and-allocation-probes).

Normal LOD still reduces primitives, but distant GPU timing order changes across
short probes. R14 remains partial for controlled comparisons and surface-specific
culling. A blanket material change is not supported by this evidence.

R16's isolated native allocation-history experiment counts both freed and live
allocations. Production sun packing makes **six loop-specific events / 376
requested bytes per call**, confirmed by a second run with half the calls.
Direct retained-array mutation appears cheaper but changes material uniforms
before resubmission. Copy-on-write-safe wrapper retention preserves the old
material value and makes the same six events / 376 bytes. Both candidates are
rejected as production optimizations; no extra cache ownership is introduced.
Rendered lifetime and whole-frame material cost remain the trigger for a
different design, rather than array reuse alone.

The committed candidate `d3e7655` passes an actual **Linux x86_64 Ubuntu 22.04**
clean-clone run under Docker's amd64 emulation on the ARM64 Mac. GCC 11.4 builds
the Linux native library; pinned official Godot 4.7.2 passes all **16 children**,
including **274 invariants, 64 Linux save checks**, numerical boundaries and all
nine native/GDScript comparisons at unchanged tolerances. Exported resources
and the native sidecar validate, then isolated exported startup confirms
`NBodyKernel`. Engine SHA256/SHA512 checks pass. Reproduction, environment and
logs are retained in `/tmp/astrarium-linux-evidence/`. This closes R20's missing
Linux functional run; it establishes neither Linux GPU costs nor remote CI
success. Actual Windows execution, including R19's publication contract, and
supported-device performance budgets remain pending. No production physics or
visual code changes in this batch; earlier science/lifecycle proofs still apply.

Final harness verification: the guarded Vulkan probe passes all ten 90-sample
cases; default Metal passes all ten 30-sample cases while reporting unavailable
GPU timings. Metal with `require_gpu=1` exits nonzero with exactly ten unavailable
timing failures, and headless execution rejects before sampling. Script import,
Python parsing and whitespace checks pass. Independent re-review confirms the
unit conversion, phase guards, completion marker and evidence limits; no blockers
remain in this batch. Logs/reports are `/tmp/astrarium-b17-{gpu-guarded,
metal-guarded,metal-strict,headless-negative,import}.*`.

### Batch 18: outward winding, import authority and controlled LOD evidence

The R14 surface audit found actual geometry defects hidden by double-sided
materials: lathed apex fans disagreed with their surrounding edges, and fin and
torus faces pointed inward. These three primitive builders now wind outward.
The native Blender gate tests both shared-edge consistency and independent
analytic exterior normals; closed but globally inverted geometry must fail.
It rejects the original source with **358 failures** and passes five corrected
fixtures, including unchanged box/capped-tube controls. `build.sh` runs it before
publishing any model. All **14 authored craft/site/facility builds** complete.

Runtime asset preparation now preserves authored glTF culling instead of forcing
every material double-sided. Regression probes cover both single- and
double-sided materials and prove Lambert preparation still runs. Existing shared
palettes retain double-sided rendering because material-joined surfaces combine
open shells and closed pieces. No automatic closed-mesh culling or extra material
buckets are introduced. Scoped guidance now requires consistent outward winding,
visible interiors and measured benefit; the unsupported comment claiming culling
could save nothing is removed.

Verification also exposed stale import evidence: a changed source GLB could still
load its previous Godot import. The build refreshes imports after all publications
when Godot is present, and explicitly requests manual import otherwise. Exploratory
checks before that refresh are discarded. The refreshed asset/procedural report
passes all **15 children**, including **18 parity poses** at the unchanged 2 cm
tolerance, **364 authored / 352 procedural asset checks**, audits, clearance and
launchpads. Evidence: `/tmp/astrarium-b18-assets-final/report.json`.

The opt-in studio profiler now uses two ABBA cycles per distance. It freezes and
checks time, camera and craft pose across all eight blocks at each distance;
only LOD bias changes. Model viewport start/end timestamps and distinct frame
IDs come from one acknowledged render-thread batch. Every block needs exactly
180 distinct samples within bounded attempts. Screenshots occur after collection,
outside timings, with main-thread acknowledgement. Invalid spans, state changes,
mixed GPU availability or a 240-second timeout fail explicitly. The runner keeps
authored rendered models separate from procedural CPU-flight metadata.

Fresh-import Vulkan evidence passes **16 blocks × 180 distinct samples**, zero
failures, and no backend diagnostics: `/tmp/astrarium-b18-abba-verified.json`.
Normal LOD reduces near primitives from **22,851 to 9,575**, and distant primitives
from **15,893 to 7,051**. Across the two ABBA cycles, normal LOD's near model GPU
times are **0.013–0.035 ms higher**, while distant times are **0.007–0.008 ms
lower**. This does not establish a broad GPU speedup. Default Metal passes the
16-block path with 30 distinct samples per block and explicit unavailable GPU
timing. Near LOD renders and the rebuilt Hail Mary before/after views were
inspected. [The measurement notes](performance.md#controlled-lod-comparison-after-winding-repair)
retain the paired values and interpretation.

R14 closes within this measured scope: ordinary LOD, outward primitive winding,
authored culling authority and mixed-shell defaults are verified. A further
surface split needs evidence that its cost and visual risk are worthwhile.
Three findings remain partial: R16's rendered material/allocation cost, R20's
Windows/remote CI/device budgets, and R30's broader component/intermediate
representability limits. This batch changes authored geometry and preparation,
not flight dynamics or orrery integration.

Lifecycle verification passes all three children in
`/tmp/astrarium-b18-lifecycle/report.json`: five-round feature soak, leak checks
and resource shutdown. Counts remain flat after warm-up, including
**6393/138/1619/0** for spawn/remove, **6792/138/1720/0** for mass edits and
**6812/138/1720/0** for true scale (object/resource/node/orphan order).

The ordinary ten-case profiler still passes. Headless ABBA rejects before sampling;
Metal ABBA with `require_gpu=1` exits nonzero with exactly 16 unavailable-timing
failures. The runner's updated completion patterns match the successful ten- and
sixteen-case logs exactly once. Godot import, Python parsing, shell syntax and
whitespace checks pass. Independent re-review confirms the winding corrections,
material regression probes, post-export import order and measurement limits.
The final pose baseline includes the craft root as well as every descendant;
`/tmp/astrarium-b18-abba-root-guard.json` repeats all 16 blocks with 180 distinct
samples, zero failures and the same primitive counts.
Its near timing deltas change sign across cycles (−0.042 / +0.044 ms), further
limiting any general GPU-speedup interpretation; both measured runs are retained.
