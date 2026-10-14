# Booster separation

The Shuttle's two solid boosters leave the tank one by one, each on its own path.
`Separation` (`sim/flight/separation.gd`) flies each booster as a separate piece
(`piece_srb_0` port, `piece_srb_1` starboard; each carries its own nozzle). This is
display only: the vessel has already dropped the boosters' mass when they detach.
The other stages use the same model; see [stage-separation.md](stage-separation.md).
The data is `look.sep` on the `srb` stage in `vehicles.gd`.

Source: D. D. Tomlin, *Space Shuttle Solid Rocket Booster (SRB) Separation*,
NASA TM X-64967 (MSFC, 1975), NTRS 19760006102.

## What happens

- Each booster hangs on the tank at one forward bolt and three aft struts. The
  sequence starts when both boosters' chamber pressure falls to 50 psia. At cue +0.8 s
  the nozzles are nulled and the orbiter holds attitude; at cue +2.5 s the bolts are
  cut and the separation motors fire together.
- Eight motors per booster: four in the forward frustum, four on the aft skirt, all on
  the side facing the tank. Their resultant points 40° off the booster's axis and 20°
  off the inboard line, toward the orbiter. The push therefore takes the booster
  outboard, down away from the orbiter's wing, and aft.
- The stack's own acceleration does most of the separating. It still flies at about
  0.9 g on the SSMEs, so the boosters fall behind it. The motors only have to clear the
  boosters sideways first.
- The boosters are aerodynamically unstable and tumble. Their nominal body rates
  3 s after separation (memo table 2):

  | | P (roll) | Q (pitch) | R (yaw) |
  |---|---|---|---|
  | Right booster | −1.1°/s | −11.96°/s | 6.49°/s |
  | Left booster | 3.22°/s | −8.21°/s | 3.30°/s |

  Negative Q is nose down, away from the orbiter, as the memo's text describes.

## The model

- **Motor thrust**: 332 kN per cluster of four. This is the specification's minimum
  of 74,667 lbf average web-action thrust.
- **Motor timing**: ignition 0.09 s after the command, the middle of the specified
  47–137 ms rise. Then 0.75 s at full thrust and a 0.107 s linear tail-off, which
  carries the specified 4,000 lb·s.
- **Mass**: half the pair's dry mass, 86 t.
- **Translation**: the motors' resultant from both clusters, minus the stack's
  thrust-less-drag acceleration along its axis (`accel` in `Craft.update`). Gravity
  pulls both alike and cancels.
- **Integration frame**: the craft's attitude at separation, so the stack's later
  pitching does not swing the boosters around with it.
- **Rotation**: the memo's rates above, reached linearly by 3 s and then held. They
  come from the memo's simulation, which used wind-tunnel data with the motor plumes
  on (tests JA13, IA13, IA57, IA87). Those proximity and plume coefficients are not
  published, so the rates are quoted rather than computed. What can be computed falls
  well short: the two clusters' angular impulse about the pivot is 4.8 × 10⁵ N·m·s,
  which spins a uniform 86 t, 45.5 m case to 1.9°/s, and the lighter bare motor
  (6.56 × 10⁶ slug·ft² in pitch after separation, TWR-17543-10 table 3.10) to 3.1°/s.
  The memo's 9–14°/s are therefore mostly aerodynamic: the stack is stable, the
  boosters are not, and the memo says the moments turn them into each other.
- **Pivot**: the spent case's mid-length (`cgY`, XB ≈ 1175). No inert centre of
  mass for the whole flown booster is published in the sources above. TWR-17543-10
  gives only the bare motor's, at motor station 1,316 in (66% of its length), without
  the skirts and frustum.
- **Residual thrust**: the boosters are still burning when they let go. Below.
- **Booster drag**: left out. About 0.15 m/s² at the 1.5 kPa of separation, under 2%
  of the stack's acceleration.

### Residual thrust

The sequence starts when chamber pressure falls to 50 psia, and the bolts are cut
2.5 s later. By then the memo puts each booster's thrust at about 30,000 lbf
(133 kN), and it starts its runs from that value. It gives no decay law, so the model
derives one. Vacuum thrust is proportional to chamber pressure:
`F/p = 2.59 Mlbf / 660.8 psia` over web time (TWR-17543-10 table 3.4), so 50 psia is
196,000 lbf. A chamber blowing down decays exponentially, and 196,000 to 30,000 lbf
in 2.5 s gives `τ = 2.5 / ln 6.53 = 1.33 s`. Each booster is pushed along its own
axis by `133 kN · e^(−t/τ)` from separation, 176 kN·s or 2.0 m/s in all, until it is
down to 1% at 6.1 s. A pure gas blowdown of the empty case would be faster (about
0.35 s from its volume, throat and c*); the slower decay the memo implies is
consistent with propellant slivers still burning.

## Check against the memo

Each booster's movement, relative to a stack accelerating at 9.6 m/s² (the ascent
gives 9.9 m/s² once the boosters are gone):

| | Simulated | Memo |
|---|---|---|
| Aft, 0.25 s | 0.33 m | 0.28 m, forward attach (fig. 16) |
| Sideways velocity after the burn | 3.8 m/s | the specified 60,000 lb·s per cluster, at 40°/20° |
| Aft, 3 s | 51 m | "primary relative motion of the SRB is rearward" |

Without the residual thrust the boosters fall back 0.38 m by 0.25 s. `residual_push`
in `tools/assetcheck.gd` holds the 0.33 m row to ±0.015 m, and the residual's own
travel to its closed form. The memo flew a Vandenberg mission's separation state with
proximity aerodynamics, so the rest of the difference is not attributed to any one
term.

## Display

- `Spaceflight.attach_sep_motors` hangs one plume per cluster on each booster. Each plume
  uses the clusters' merged exhaust, 0.65 m across, sized from the motor's 12.9 in
  case. It is dark until the stage separates, then follows `motor_fraction`.
- While the motors burn they leave alumina smoke in the air, through the same smoke
  pool as the exhaust trail.
- Once the motors are out, the tumble has built up (3 s) and the residual thrust is
  down to 1% (6.1 s), each booster is handed on to `Fall` (below) and stays drawn to
  splashdown. Without that hand-off (a bare `Craft`, as the asset checks build) a
  piece stays drawn for 30 s (`Separation.SHOWN`), by which time it is about 4 km
  behind.

## Ascent

Where the boosters are let go is set by the ascent, which every launcher shares
(`Guidance.ascent_guidance`). The Shuttle's part of it is checked against the
nominal first stage in *Flight Procedures Handbook: Ascent/Aborts*, JSC-10559 Rev. A
(1988), table 2.2-I, and the STS-30 press-kit timeline.

- **Ignition**: the SSMEs start at T−6.6 s and the solids at T−0 (JSC-10559 §2.2).
  A solid lights at hold-down release (`Vessel.lit`), since nothing could shut it
  down for a scrub.
- **Thrust**: each solid follows the RSRM population-nominal vacuum thrust at 60 °F
  and the standard 0.368 in/s burn rate, the average of the static-test and flight
  motors through RSRM-4: A. S. Drendel, M. C. Richards, *RSRM-4 (360T004) Final
  Report, Ballistics/Mass Properties*, Thiokol TWR-17543-10, NTRS 19900003336 (1989),
  fig. 3.8. Below.
- **Steering**: first-stage guidance is an open-loop attitude table against relative
  speed, I-loaded per flight; it holds pad attitude until 127 ft/s. The shared law
  θ = 90°·v₀/(v₀ + v − v_start) stands in for the table, with the Shuttle's own
  v_start (38.7 m/s) and v₀ (720 m/s, from `ascent` in `vehicles.gd`). v₀ is
  fitted to the staging altitude; the table's other altitudes are a check on it.
  The table lofts more than the shared default (600 m/s): after staging the stack's
  thrust barely exceeds its weight, so the solids make the climb.
- **Drag**: the parallel stack's frontal area is the sum of the tank's, both
  boosters' and the orbiter's, 102 m² (80 m² once the boosters are gone).

### The solids' thrust

`Rocketry.RSRM_PROFILE` is fig. 3.8's population average, read at 0.1 s from a
300 dpi scan, smoothed over 1 s before the tail-off knee at 108 s, and cut at the
123.4 s action time. Each sample's x is the vacuum impulse delivered so far over the
impulse to action time, and its y is the thrust over the 3.32 Mlbf peak (`thrustVac`
14.77 MN). The knots keep every sample within 0.008 of the peak. Total impulse is
the 502 t of propellant × 268 s, 296.6 Mlbf·s, so the profile gives only the shape.
The engine burns the profile in time (dx/dt = F/I):

| | Model | Thiokol nominal (TWR-17543-10) |
|---|---|---|
| Vacuum thrust at ignition, peak | 3.15, 3.32 Mlbf at 21 s | fig. 3.8 |
| Vacuum thrust in the max-q bucket | 2.38 Mlbf at 52 s | fig. 3.8 |
| Impulse to 20 s | 65.2 Mlbf·s | 64.5 (table 3.6; at least 63.1) |
| Impulse to 60 s | 173.5 Mlbf·s | 172.7 (171.2–178.1) |
| Impulse to web time, 111.7 s | 289.5 Mlbf·s | 288.9 (table 3.4) |
| Burnout | 123.3 s | 123.4 s action time |
| Sea-level thrust at liftoff | 2.85 Mlbf | 2.8 Mlbf (Kanner et al. 2012, NTRS 20120001534) |
| Peak sea-level thrust | 3.00 Mlbf | 3.06 Mlbf (table 3.4) |

The sea-level figures come from the engine's fixed 242 s sea-level Isp, which
scales thrust rather than subtracting p·A_e: 2% low at the peak. The 0.25 s
ignition rise is not modelled. Separation follows burnout in the model; RSRM-4
(STS-30, 71 °F) commanded it 2.8 s after its action time.

### Against the flown first stage

Relative speeds are the table's events; the altitudes and times are where the model
reaches them.

| | Simulated | Flown (table 2.2-I) |
|---|---|---|
| 127 ft/s (38.7 m/s), tower clear | 0.13 km, T+7 s | 387 ft (0.12 km), T+7 s |
| 450 ft/s (137 m/s) | 1.26 km, T+20 s | 3,963 ft (1.21 km), T+20 s |
| 658 ft/s (201 m/s) | 2.48 km, T+27 s | 8,157 ft (2.49 km), T+27 s |
| 900 ft/s (274 m/s) | 4.45 km, T+36 s | 15,275 ft (4.66 km), T+38 s |
| 1,335 ft/s (407 m/s) | 9.71 km, T+54 s | 34,150 ft (10.41 km), T+58 s |
| 1,504 ft/s (458 m/s) | 11.72 km, T+59 s | 41,058 ft (12.51 km), T+64 s |
| 2,628 ft/s (801 m/s) | 22.14 km, T+83 s | 79,029 ft (24.09 km) |
| Max-q | 35.6 kPa (743 psf), T+50 s, 8.6 km | about 33 kPa at 1,335 ft/s, 34,150 ft; "just prior to throttle up" |
| SRB separation | T+123.3 s, 47.4 km | T+124 s, 155,315 ft (47.3 km); KSC: 156,000 ft |
| Relative speed | 1.44 km/s (4,711 ft/s) | 4,139 ft/s (1.26 km/s); STS-30: 4,212 ft/s; Bacchus: about 4,600 ft/s |
| Inertial speed | 1.81 km/s (5,945 ft/s) | 5,336 ft/s (1.63 km/s) |
| Climb rate, flight path | 651 m/s, 27° | about 700 m/s, for KSC's apogee |

The table gives 2,628 ft/s at "01:18", which its own altitudes rule out (41,058 to
79,029 ft in 14 s at under 2,628 ft/s), so only the altitude is compared.

Known differences:
- The SSMEs fly no throttle bucket of their own. The flown one (65% from 658 to
  1,358 ft/s) is an I-load; here the shared q limit throttles them, to 71% at
  T+50 s. From T+40 s the model is ahead of the table, and max-q comes 8 s early
  and 8% high. With the flown throttle schedule the SSMEs would deliver about
  27 m/s less by staging.
- At staging the stack carries 186 m/s more inertial speed than table 2.2-I, at
  the flown altitude. The steering cannot remove that energy. The solids now
  deliver their measured impulse on their measured schedule, and the missing
  throttle bucket explains only 27 m/s. The rest is in the drag or the masses,
  which nothing here measures.

## Recovery

`Fall` (`sim/flight/fall.gd`) flies each booster from the hand-off to the sea as a
body of its own, in the vessel's parent-centred frame: gravity from the vessel's own
model, drag against the turning air, RK4 at 0.05 s in the air. The data is
`look.fall` on the `srb` stage. It is display only; the vessel never sees it.

Sources:
- NASA KSC, *Solid Rocket Boosters and Post-Launch Processing*, FS-2004-07-012-KSC
  (rev. 2006). Its timeline table is the flown sequence: separation at T+124 s and
  156,000 ft; apogee at T+196 s and 238,000 ft; nose cap and pilot chute at T+349 s,
  16,000 ft, 360 mph; drogue at T+350 s, 15,530 ft; frustum and mains at T+371 s,
  6,450 ft, 250 mph; booster impact at T+414 s, 50 mph; frustum and drogue impact at
  T+459 s, 40 mph. Afloat, the forward end is about 30 ft out of the water. The nose
  cap is not recovered.
- D. L. Bacchus, D. A. Kross, R. D. Moog, *The Aerodynamic Challenges of SRB
  Recovery*, NTRS 19850008599 (1985). The booster reenters "in a random tumbling
  mode", Mach 5 down to 0.5. Fig. 1 (steel-case booster, 115 ft mains): apogee near
  220,000 ft 73 s after separation, max q 2,000 psf at 48,000 ft, 173 psf at drogue
  deployment (15,600 ft), mains at 6,600 ft, impact 295 s after separation at
  87 ft/s, 140 nmi downrange. Fig. 3: the 54 ft drogue opens in three stages, 60%,
  80% and full drag area. Fig. 16 (drop test): drogue disreefs 6.86 s and 11.86 s
  after deployment, mains 9.65 s and 16.65 s after theirs, which come 2.33 s after
  frustum separation. The 136 ft mains lower the nominal impact from 87 to 75 ft/s.
- R. Runkle, K. Henson, *STS-3 Main Parachute Failure*, NASA TM-82490 (1982). Table 5
  gives the flown state at main deployment on STS-1 to STS-3: 6,160–6,530 ft,
  354–359 ft/s, 120–123 psf. The main canopies' floats clear the frustum when it is
  about 250 ft from the booster, and the mains pull 13.3° off the riser line.
- J. R. Schmidt, P. G. McFadden, *Reefing of Quarter Spherical Ribbon Parachutes used
  in the Ares I First Stage Deceleration System*, NTRS 20090033119 (2009): Ares I's
  mains are "configured in a similar manner to the SSP SRB parachutes", reefed to
  about 20% and 40% of full drag area.

The model:
- **Tumbling body**: before the drogue, drag is the average over an end-over-end
  tumble of Allen's crossflow on the planform and the blunt drag of the end:
  C_D A = (4/3π)(C_n L D + C_D,end πD²/4), with `Vessel.crossflow_cn` and
  `Rocketry.blunt_drag_coefficient`. 4/3π is the mean of |sin α|³ over a turn. The
  memo's rates are mostly pitch, so the tumble is planar. Nothing is fitted: at the
  nose-cap altitude this gives 171 m/s, against KSC's 161 m/s.
- **Attitude**: the memo's rates, held until the drogue opens; then the booster
  swings along the flow (over about 2 s, display) and hangs tail first, which
  Bacchus describes. Hanging, its drag is the blunt end's alone.
- **Events** at baroswitch altitudes from the KSC table: the nose cap comes off at
  16,000 ft and leaves as its own piece (mass 230 kg, an estimate; it sinks). The
  drogue opens 1 s later. At 6,450 ft the frustum leaves with the drogue still on
  it, and the mains open 2.33 s later.
- **Drogue**: 118 m² full open. On STS-1 to STS-3 the booster (170,000 lb then) hung
  at 122 psf on the drogue just before the mains: W/q = 129.5 m², less the
  tail-first body's 11 m². That is C_D0 0.55 on the 54 ft canopy, within the
  conical-ribbon range.
- **Mains**: 2,360 m² for the cluster, 2mg/(ρ₀v²) for the 75 ft/s nominal impact of
  a 170,000 lb booster (Bacchus). Reefed to 20% and 40% (Ares I) at the drop-test
  times.
- **Fill**: each opening and disreef ramps over 1 s, not resolved further.
- **Frustum**: 2,400 kg, from its 40 mph impact on the drogue at sea level
  (m = ρ₀v²C_DA/2g).
- **Mass**: the booster is half the pair's dry mass, 86 t, less the cap and frustum.
  The reentry masses in the sources are lighter (170,000 lb, 77 t), which is why
  this booster comes down a little faster.
- **Afloat**: nozzle down, the forward skirt 30 ft out of the water, turning with
  the Earth. A piece stays drawn 120 s after it comes to rest unless the camera
  follows it. B cycles the camera through the boosters and the tank
  (`Spaceflight.follow`); the local frame then sits under the followed piece.

## Check

`shuttle_fates` in `tools/missioncheck.tscn` flies the Shuttle from the pad. Each
booster must stay drawn until it is down, run apogee, nose cap, drogue, frustum,
mains and splashdown in that order, and be afloat for its 120 s with three mains
fully open before it lands. Tolerances against the KSC table:

| | Simulated | Flown | Tolerance |
|---|---|---|---|
| Nose cap altitude | 4,877 m | 16,000 ft (4,877 m) | 2% |
| Nose cap speed | 171 m/s | 360 mph (161 m/s) | 15% |
| Drogue altitude | 4,708 m | 15,530 ft (4,734 m) | 3% |
| Frustum altitude | 1,966 m | 6,450 ft (1,966 m) | 2% |
| Frustum speed | 126 m/s | 250 mph (112 m/s); 354–359 ft/s on STS-1 to 3 | 15% |
| Nose cap to frustum | 18.9 s | 22 s | 25% |
| Frustum to splashdown | 40.5 s | 43 s | 20% |
| Splashdown | 23.8 m/s | 50 mph (22.4 m/s); 75 ft/s nominal | 12% |
| Frustum splashdown | 17.2 m/s | 40 mph (17.9 m/s) | 15% |

The speeds run 6–13% fast and the drogue phase short: this booster is 12% heavier
than the sources'. The altitudes are baroswitch settings, so they check that the
events fire where set, at the 0.05 s step.

The apogee and the timeline are checked against KSC's table too, since the ascent
now drops the boosters where the flown one did ([Ascent](#ascent)):

| | Simulated | Flown | Tolerance |
|---|---|---|---|
| Apogee | 69.7 km | 238,000 ft (72.5 km) | 8% |
| Apogee time | T+193 s | T+196 s | 8% |
| Splashdown time | T+415 s | T+414 s | 8% |

They separate 0.7 s early and climbing a little slowly (651 m/s), so the apogee is
4% low. Bacchus's lower apogee, 220,000 ft (67 km), is
read off fig. 1 of Bacchus et al. and is not checked. The fall is held to what it
controls separately: the apogee within 10% of the vacuum apogee from the hand-off
state (the tumbling booster's drag on the way up costs about 0.5 km).
