# sim/flight — spaceflight

Vessel dynamics use SI units (see the root AGENTS.md). `vessel.gd` converts body
positions and gravity to its local environment; `spaceflight.gd` coordinates
orrery bodies, cruise endpoints and cameras. Local
space is a second pass with its own camera, in metres (`localview.gd`), and the
orrery camera is slaved to it. No single projection spans a 100 m rocket and an
AU-scale scene.

Editing `craftmodel.gd` or `craftassets.gd`? The shape and naming rules in
[model_sources/blender/AGENTS.md](../../model_sources/blender/AGENTS.md) apply
to the procedural builds too.

## Guidance (`guidance.gd`)

- A guidance law is a closed loop on the vehicle's own state, never a stored
  trajectory. A heavier vehicle should fly differently and an incapable one
  should fail honestly.
- Never gate a manoeuvre on catching a narrow window, never size an ignition on
  the full available deceleration (no margin is left for the lag), and never put
  a discrete choice (engine count) inside a continuous predicate, or the burn
  stutters.
- Closed-loop ascent and circularization pitch commands are limited to 1° per
  vessel proper-time second, including handovers and staging.
- Ascent pitch program: θ = 90°·v₀/(v₀ + v − v_start), clamped to within α_max
  of the velocity vector. Check the staging state, not the final orbit: a Saturn
  V should stage near AS-506's (67 km, 2.4 km/s, 21°).
- Above the air, explicit guidance (a_v = 6Δh/T² − 4ḣ/T, T_go from the rocket
  equation) aims at a low perigee cutoff, then circularizes. A tank that must come
  down (`disposalPerigee`) is left on a lower ellipse: the law aims at that ellipse's
  climb rate too ([stage-separation.md](../../docs/physics/stage-separation.md#where-the-tank-goes)). Regression: all four
  launchers in orbit within the target gates in `tools/sharedflightcheck.gd`.
  The legacy `flightref.mjs` comparison supplements this production-driver check.
- Descents share one `descent_law`, and every powered phase shares one
  `limit_throttle`.
- A tower catch is physics in `CatchTower` (arms, rails, absorbers, outcomes);
  `LaunchSite` only draws its state. Estimates and sources are in
  [booster-catch.md](../../docs/physics/booster-catch.md). Regression: `shcatch`
  and `shcatch_2x` in `tools/flightcheck.gd`.
- A lone ship with flaps flies Allen's crossflow aerodynamics, and its own
  `soloLimits`. `bellyflop` brings it home belly first: bank for a drag-tracking
  glide, a flip and a landing burn
  ([ship-return.md](../../docs/physics/ship-return.md)). Regression: `ship_return`
  in `tools/missioncheck.tscn`.
- A lone stage with `wings` (the orbiter) flies `Vessel.winged_coeffs`; `glide`
  brings it from orbit to its main gear: 40° entry banking on a drag reference with
  roll reversals, the glide slopes, a flare
  ([orbiter-entry.md](../../docs/physics/orbiter-entry.md)). With a launch site it
  waits for the deorbit opportunity a conic predictor finds, flies range-to-go drag
  and reversals toward the site, and aims TAEM at it. The site comes from
  `Vessel.site_at(coord)`, never from integrating frame `dt`. A stage's `gear.point`
  is where it touches down once it is alone. Regression: `orbiter_return` and
  `orbiter_home` in `tools/missioncheck.tscn`.
- The Shuttle's lines (orbiter, tank, boosters) are one set of station tables in
  `shuttlelines.gd` and `model_sources/blender/shuttle.py`; change both
  ([shuttle-geometry.md](../../docs/physics/shuttle-geometry.md)).
- Every dropped stage leaves under `Separation`: whole, or as its pieces
  (`piece_<stage>_<i>` nodes, `look.pieces`; a fairing's halves). It is flown in
  the frame held at separation: the stack's non-gravitational acceleration leaves
  it behind (gravity cancels), and its sourced `look.sep` data adds separation or
  retro motors, a sideways push, the stack's own unmodelled push (ullage, the
  orbiter's −Z translation) and body rates. Never a canned drift, and never a
  number without a source in
  [stage-separation.md](../../docs/physics/stage-separation.md). Display only: the
  vessel has already shed the stage's mass. Regression: `stage_separations` and
  `booster_pieces` in `tools/assetcheck.gd`.
- A stage with a fate (`look.fall`) is handed on by `Craft.update`'s `release` once
  Separation's pushes are over: each piece becomes a `Fall` (`fall.gd`), a ballistic
  body in the vessel's frame with drag against the turning air and its recovery
  events (chutes, a part shed, splashdown) or breakup. It never acts on the vessel.
  Spaceflight draws it in the local frame and can follow it (`follow`, key B); the
  local frame then sits under the piece. Regression: `shuttle_fates` in
  `tools/missioncheck.tscn`
  ([srb-separation.md](../../docs/physics/srb-separation.md#recovery)).

## Vessel (`vessel.gd`)

- During flight, the vessel requests coordinate seconds from the world's
  integrator before advancing. Both clocks use the accepted duration; all calls
  share the frame's world step budget. Cruise integrates proper time and requests
  its corresponding coordinate duration. Commit trails and visuals once per frame.
- Each stage pays for its own engines: `burn()` splits the flow by each lit
  stage's mass flow. A separation lights the next stage only if nothing is still
  burning. A solid is never shut down to meet a g limit; its thrust is read at
  its current point in the grain.
- RCS belongs to every attached stage, and attitude control feeds the target's
  rate forward. Holding prograde means holding a turning attitude.
- On rails, attitude is held at the last `point_at`, not frozen. Insertion burns
  and node burns light only within 20° of their direction.
- A point fixed to a rotating body moves by ω × r. With the pole on −Y, the
  small-angle form is `w = +Ω dt`. `place_on_pad` holds the one true expression;
  the pad and the landing site both derive from it.

## Local space (`localview.gd`, `launchsite.gd`, `cloudfield.gd`)

- The ground patch is hand-shaded for a Lambert BRDF (albedo/π) so it matches the
  `StandardMaterial3D` vehicle standing on it.
- The launch tower is the one object of known size in frame; without it a
  climbing vehicle reads as stationary. The terminal count gives a launch a
  visible start.
- A launch complex is fitted to its vehicle's measured skin
  (`LaunchSite.Envelope`) and yawed to the vehicle's roll, never sized from a
  diameter. `tools/padcheck.gd` must report zero.
- The grounds are a plan (`LaunchSite.site_plan`) plus a library
  (`model_sources/blender/facilities.py`, one `stage_fac_<name>` node each).
  They keep clear of the lightning masts, the trench axis (±x) and the
  crawlerway (−z). A missing library falls back to `complex_grounds`. Aerial
  check: the `*_grounds` scenarios in `tools/flight_scenarios.json`.
- Anything drawn of the planet is sampled planet-fixed (`uLocalToPlanet`), since
  the local origin rides under the vehicle. `cloudfield.gd` must stay
  sample-for-sample identical to `shaders/flight/clouds.gdshaderinc`, or the
  vehicle's lighting and its shadow disagree.
- The sky and haze run from the camera's height (set in `apply_origin`), not the
  vehicle's altitude.
