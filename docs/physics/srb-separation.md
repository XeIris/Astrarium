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
- A piece stays drawn for 30 s (`Separation.SHOWN`), by which time it is about 4 km
  behind.
