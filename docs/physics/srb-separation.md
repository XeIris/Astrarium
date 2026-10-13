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
  on. Proximity and plume aerodynamics are not modelled here, and the motors' own
  torque gives only about 2°/s.
- **Pivot**: the spent case's mid-length (`cgY`, XB ≈ 1175). No inert centre of
  mass for the flown booster is published in the sources above.
- **Residual thrust**: left out. The memo starts its runs with each booster still
  making 30,000 lbf (133 kN, 1.5 m/s² on 86 t), decaying, but gives no decay law.
- **Booster drag**: left out. About 0.3 m/s² at the ~3 kPa of separation, under 4%
  of the stack's acceleration.

## Check against the memo

In the flown ascent the boosters separate at T+130 s and 40 km, with the stack at
9.6 m/s². Each booster's movement, relative to the stack:

| | Simulated | Memo |
|---|---|---|
| Aft, 0.25 s | 0.50 m | 0.28 m, forward attach (fig. 16) |
| Sideways velocity after the burn | 3.8 m/s | the specified 60,000 lb·s per cluster, at 40°/20° |
| Aft, 3 s | 56 m | "primary relative motion of the SRB is rearward" |

The 0.25 s value includes one frame of the pre-separation acceleration. Without the
residual thrust the boosters also fall back somewhat faster than the memo's.

## Display

- `Spaceflight.attach_sep_motors` hangs one plume per cluster on each booster. Each plume
  uses the clusters' merged exhaust, 0.65 m across, sized from the motor's 12.9 in
  case. It is dark until the stage separates, then follows `motor_fraction`.
- While the motors burn they leave alumina smoke in the air, through the same smoke
  pool as the exhaust trail.
- Once the motors are out and the tumble has built up (3 s), each booster is handed
  on to `Fall` (below) and stays drawn to splashdown. Without that hand-off (a bare
  `Craft`, as the asset checks build) a piece stays drawn for 30 s
  (`Separation.SHOWN`), by which time it is about 4 km behind.

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

The apogee is not checked against the sources, and it differs. The shared ascent
drops the boosters at T+120 s, 39.8 km and 1.75 km/s, against KSC's T+124 s and
156,000 ft (47.5 km). They coast to 57.8 km at T+182 s, against 238,000 ft
(72.5 km, KSC) or 220,000 ft (67 km, Bacchus), and come down 22 s earlier
(T+393 s). That is the ascent's lower lofting, not the fall. The check holds the fall
to what it controls: the apogee within 10% of the vacuum apogee from the hand-off
state (the tumbling booster's drag on the way up costs about 1 km).
