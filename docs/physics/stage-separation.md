# Stage separation

Every stage the vessel drops leaves the stack under `Separation`
(`sim/flight/separation.gd`): whole, or as its pieces (the Shuttle's boosters, a
fairing's two halves). It is display only. The vessel has already shed the stage's
mass, and nothing here feeds back into its flight.

## The model

- **Frame**: each body is integrated in the craft's attitude at separation, so the
  stack's later turning does not swing it round.
- **Gravity** pulls the stage and the stack alike and cancels.
- **The stack's acceleration**: the stage falls behind at the stack's
  non-gravitational acceleration (thrust, drag, lift, a parachute), taken from the
  vessel's own force model as a vector in the craft frame. Standing on the ground,
  it is the ground's push.
- **The stage's own push**, from `look.sep` in `vehicles.gd`:
  - `motors`: solid separation or retro motors on the stage, at sites `[y, r, az°]`
    in its frame. Thrust is per site, and the exhaust runs forward and out at the
    site's azimuth by `cant`.
  - `push`: a sideways speed for pieces, straight out from the stack's axis.
  - `stack`: a push on what is left that the vessel does not fly (ullage rockets,
    the orbiter's translation), as a thrust on the remaining mass.
  - `rates`: body rates reached by `spinUp` s and then held.
  - `residual`: the stage's own engines still pushing it along its axis: a solid's
    blowdown (`tau`) or a liquid engine's measured decay (`curve`). A stage with a fate
    is handed on once it is over.
- **Shown** for 30 s (`Separation.SHOWN`), unless the stage has a fate (`look.fall`):
  then once its motors, the stack's push and the spin-up are over
  (`Separation.handoff_time`), each piece flies on as a `Fall`, a body of its own in
  the vessel's frame, to the sea or its breakup. The Shuttle's boosters and tank have
  one ([srb-separation.md](srb-separation.md#recovery), and the tank below).

The stage's own drag is left out. For the boosters it is under 2% of the stack's
acceleration ([srb-separation.md](srb-separation.md)); higher up it is smaller still.

A stage with no published push leaves on the stack's acceleration alone. No rates are
given without a source, so such a stage keeps the attitude it had at separation.

## Saturn V

Source: *Saturn V Flight Manual SA-503*, MSFC-MAN-503 (1968), NTRS 19750063889.

**S-IC/S-II** (figure 2-1, figure 4-25, page 5-24):

- The S-II ullage rockets light at S-IC cutoff + 0.5 s. The separation signal and
  the S-IC retrorockets follow at + 0.7 s, and the S-II ignites at + 2.4 s.
- There are eight retrorockets, in pairs in the four F-1 engine fairings. Each is
  pinned 7.5° from the centreline, and each fires through the fairing's forward end.
  Average effective thrust is 87,913 lbf (391.1 kN) for 0.633 s (figure 4-25).
  The summary table on page 1-5 gives 75,800 lbf for 0.541 s, footnoted "minimum
  vacuum thrust at 120°F"; the figure's nominal values are used.
- There are four ullage rockets, 22,700 lbf (101 kN) for 3.7 s. They sit at the aft
  end of the S-IC/S-II interstage, canted 10° outward.
- The model: 782.1 kN per fairing pair. The sites are the fairings' forward tips
  (y 10.8 m, r 4.53 m, at 45° + k·90°). The stack's push is 4 × 101 kN × cos 10°,
  starting 0.2 s before the stage separates.

**F-1 tail-off** (`look.sep.residual`). The F-1s are still pushing the S-IC when it
separates. Source: *Saturn V Launch Vehicle Flight Evaluation Report AS-510*,
MPR-SAT-FE-71-2, NTRS 19730025086, §5.4 and fig. 5-4.

- Fig. 5-4 is the four outboard engines' thrust decay against time from cutoff, as a
  fraction of their 7,067,700 lbf (31.44 MN) at cutoff. It falls through 10% at
  0.62 s, bottoms near 2.1% at 0.83 s, peaks at 2.3% at 1.2 s and reaches zero at
  4.85 s. The model reads it from 0.67 s on; separation comes at 0.7 s, where it is
  2.7% (0.86 MN, 6.2 m/s² on the S-IC).
- After separation it is worth 1.80 MN·s, 13 m/s on the 137.6 t stage, almost as much
  as the eight retros' 2.0 MN·s. The retros win early, the tail-off over the next
  four seconds.
- The report measured 2,646,945 lbf·s from cutoff to zero (0.374 s at the cutoff
  thrust). The curve from 0.67 s carries 0.058 s of it, so the off-scale first
  0.67 s carry 0.316 s, an average of 47% of cutoff thrust. That part is the stack's,
  which in the model burns its propellant at full thrust to separation instead.

**Dual-plane separation** (MSFC-MAN-503 p. 5-24, fig. 2-1; AS-510 table 16-9). The
S-IC/S-II interstage is cut at two planes. At the first, the S-IC leaves with a small
ring (615 kg, included in its dry mass). The large interstage, the S-II's aft
interstage, stays on the S-II, around its J-2s. It carries the ullage rockets. It drops
30.5 s after S-IC cutoff: 29.8 s after the first plane.

- The model: the stage `sii_aft_is`, 3,504 kg (AS-510 table 16-9), 1.5 m tall,
  dropped by `jettisonAt.afterBelow` 29.8 s after the S-IC. The S-II flies those
  seconds with its mass, then the ring falls behind on the S-II's acceleration alone.
- AS-510 reports the second plane separation as predicted, with no significant
  attitude disturbance (§10.6). No push or rates are published for it.

**S-II/S-IVB** (figure 2-1, page 5-25):

- There are four retrorockets, 34,810 lbf (154.8 kN) for 1.52 s. They are 90° apart
  in the aft end of the S-IVB's aft interstage, which stays with the S-II. The cases
  are canted about 3° and the nozzles 9.5° out from the centreline.
- The S-IVB's two solid ullage rockets give 3,390 lbf (15.1 kN) each for 3.87 s.
  They light 0.1 s before the separation signal.
- The manual does not give the retros' clocking, so the model puts them at 0°, 90°,
  180° and 270°.

Not modelled:
- Post-separation rates. The AS-506 flight evaluation (MPR-SAT-FE-69-9, §12)
  reports the separations as nominal, within staging limits, but publishes no rates
  for the spent stages.

**Check**: the manual says seven retrorockets (one out) separate the S-IC by at
least 6 ft in under one second. With seven, the retros give 19.7 m/s² on the 137.6 t
stage for 0.633 s, and the ullage rockets 0.59 m/s² on the stack. Less the tail-off,
that is 6.3 m at 1 s, before the S-II lights (8.8 m without it).

**Check against AS-510**: AS-510 flew with four retros, no ullage rockets and the
staging delayed by a second (separation 1.64 s after cutoff, S-II start valves open
at 3.4 s). Its separation distance fell short of the prediction, and the JANNAF
lessons-learned review (S. Richards, NTRS 20100023317) and the report put that down to
the F-1 tail-off impulse. The same sequence against the 157 t S-IC, with the stack
unpushed until the J-2s start:

| s after cutoff | 2.35 | 2.65 | 3.0 | 3.5 | 4.0 |
|---|---|---|---|---|---|
| Reconstructed (fig. 10-15), ft | 2.5 | 9.5 | 13.7 | 17.6 | 20.2 |
| Model, with the tail-off, ft | 5.2 | 8.6 | 11.5 | 13.9 | 14.4 |
| Model, without it, ft | 8.1 | 14.2 | 21.4 | 31.7 | 41.9 |

The reconstructed values are read off the figure. With the tail-off the model follows
the flight to 3 s. By 4 s it falls 6 ft short; the J-2s' start transient and the
stages' drag are not in this sequence. It is a one-dimensional integration of the
numbers above, not a run of `Separation`, whose S-II lights at once.

## Falcon 9

Source: *Falcon User's Guide* (SpaceX, May 2025), §2.4.

- **Stage separation**: helium releases three latches, and four pneumatic pushers
  (one a redundant centre pusher) push the stages apart. Their impulse is not
  published, so the first stage leaves on the second stage's acceleration alone.
- **Fairing**: helium releases the latches on the vertical seam, and four pneumatic
  pushers push the halves apart. Their speed is not published either. The only
  figure found is ~10 m/s for a 5.4 m Ariane 5 half (M. Woronowicz, *Development of
  an analytical transient evacuation model for the fairing jettison process*, NASA
  CCMPP 2023, the JWST launch). It is used for the 5.2 m Falcon fairing as an
  estimate. The halves get no rates, since none are published.

## Space Shuttle external tank

Sources:
- *Flight Procedures Handbook, Ascent/Aborts*, JSC-10559 Rev. F (2005), §2.2.3,
  §2.6.1.3 and §4.3.1.12.
- *Space Shuttle External Tank System Definition Handbook, SLWT*, LMC-ET-SE61-1,
  vol. 1, §2.1.3 and §3.3.1.

- The tank separates about 20 s after MECO (18 s in `sepAfterCutoff`). Separation is
  inhibited while any body rate exceeds 0.7°/s.
- Just before the structural release, the transition autopilot starts an automatic
  −Z RCS translation, which moves the orbiter away from the tank. Once that −Z
  translation reaches 4 ft/s, the software moves on to OMS-1 (MM 104).
- For the RTLS separation, the handbook names the jets: four forward and six aft
  down-firing primaries. The model uses the same ten for the nominal case, at
  870 lbf (3.87 kN) each. Their cant is ignored.
- The model: 38.7 kN on what is left (the orbiter), along +Z of the craft frame,
  which is the orbiter's −Z, out of the payload bay. It runs until 1.219 m/s, about
  3.5 s on 110 t. There is no thrust on the stack, so nothing pulls the tank aft
  along the axis. It drops straight away from the orbiter's belly, about 35 m in
  30 s.
- **Rates**: none. The separation inhibit keeps the stack under 0.7°/s, and the
  tank has nothing to turn it in vacuum. The SLWT handbook says the tank "pitches
  away from the Orbiter, tumbles", which covers its whole fall. The only measured
  rate found is 8.6–8.8°/s, from video of the STS-31 tank (tumble valve
  deactivated) breaking up at reentry: M. W. Snyder and D. E. Pitts, IGARSS '92,
  NTRS 19930063598. That rate builds up in the air; `Fall` turns the tank at
  8.7°/s once it is below the top of the atmosphere.
- The tank's relief valves stay closed for at least 100 s after separation, and its
  LO2 vent is non-propulsive (under 50 lbf) (SLWT handbook §3.3.1, §4).

### Where the tank goes

The tank is not in orbit when it drops. MECO leaves the perigee in the atmosphere, and
the orbiter's OMS-2 raises it at apogee.

Sources:
- *STS-31 National Space Transportation System Mission Report* (JSC, 1990): MECO at
  T+8:31, "an orbit of 330 by 48 nmi"; OMS-2 then made it 330 × 311 nmi.
- P. D. Maley, *Observing U.S. Manned Orbiters* (pauldmaley.com/shuttle), who watched
  the STS-31 tank from Mauna Kea: separated 8.5 min after launch at 369,000 ft;
  reentry "began at an altitude of 247,935 feet at 17.48 north latitude and 156.11
  west longitude", tumbling end over end at about 8°/s; at least 50 pieces 7 s after
  the rupture, followed down to 214,000 ft. Snyder and Pitts (above) analysed the
  same video.
- SETI Institute, *STS-125 External Tank Reentry Observing Campaign*
  (shuttle.seti.org): another Hubble flight's tank was due to reenter just south-east
  of Hawaii, about 80 minutes after launch.

The model:
- **Guidance** (`guidance.gd`): a stage with `disposalPerigee` (the tank, 48 nmi =
  88.9 km from STS-31) makes the ascent cut off at the same insertion altitude, but
  on the ellipse from that perigee to the target apoapsis, still climbing at its
  rate. The vertical law aims at that final rate,
  a_v = 6Δh/T² − (4ḣ + 2ḣ_f)/T. T is the missing speed over its measured closing
  rate, since the 3 g limit stretches the burn; the last 10 s steer the climb rate
  alone. The Shuttle now cuts off near 300 × 92 km at 112 km, climbing about 73 m/s.
- **Fall**: the tank coasts on that ellipse, drag (the same tumble average as the
  boosters, `look.fall.tumble` 8.7°/s) takes it down on its first return to perigee,
  and it is retired at the rupture altitude, 247,935 ft (75.57 km). Fragments are not
  drawn.
- **Result** (the `shuttle_fates` check): the tank leaves MECO on a 93 km perigee,
  reaches 283 km (drag on the climb out costs it 16 km) and ruptures 85 min after
  liftoff near 23.5° N, 137.5° W, in the Pacific north-east of Hawaii. STS-31's, on a
  28.5° direct insertion, ruptured at 17.5° N, 156.1° W; this flight goes to 51.6°.
  Where it comes down is a consequence of the launch and the orbit, so the check
  requires only that it is over the sea on the Earth map's land mask.

## Others

- **Starship**: it hot-stages, with the ship's engines lit before the booster lets
  go. The booster leaves on the ship's acceleration. SpaceX's flight
  descriptions (Flights 2, 3 and 8) have the booster keep its three centre engines
  burning through hot staging and into the boostback flip. They are
  left out because their throttle is not published, and the booster's turn is part
  of `booster_return`, not this display.
- **Apollo LM**: the descent stage is left on the surface at liftoff. The ground's
  push holds it there while the ascent stage climbs away.
- **Sky crane**: the aeroshell is one stage here, heat shield and backshell together.
  It falls behind the powered descent stage. In reality the heat shield drops first,
  and the backshell rises away on its parachute.

## Check

`stage_separations` in `tools/assetcheck.gd` measures the built nodes directly.
- Every stage dropped under thrust must fall behind by at least the stack's
  acceleration plus its authored pushes.
- A whole stage must not drift sideways, and a piece must move away from the axis.
- The tank, dropped in a coast, must not slide along the axis, and must move away
  from the orbiter by its translation.

The old constant-speed drift fails every case.

`shuttle_fates` in `tools/missioncheck.tscn` follows the Shuttle's pieces past the
hand-off: the boosters' recovery ([srb-separation.md](srb-separation.md#check)), and
the tank, which must leave MECO on an 89 km perigee (±12%) and break up at
247,935 ft (±1%) over the sea.
