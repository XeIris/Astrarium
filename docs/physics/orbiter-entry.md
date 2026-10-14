# The orbiter's way home: entry, glide and landing

The `glide` program (`Guidance.glide_guidance`) flies a lone Shuttle orbiter from
orbit to a touchdown on its main gear: at its launch site if it has one, otherwise
where its glide ends. `tools/missioncheck.tscn -- only=orbiter_return` flies it from
a 300 km orbit, and `only=orbiter_home` from Pad 39A to orbit and back.

## Aerodynamics

A lone stage with `wings` takes its lift and drag on the wing area (250 m²) from
`Vessel.winged_coeffs(α, M, speed brake)`, in place of the slender-body drag the
stacked vehicles use.

- **Hypersonic** (Mach 6 and up): a normal force linear plus Newtonian in α,
  `C_N = 0.6 sin α + 1.6 sin²α`, with a small axial term. At 40° that is
  `C_L` 0.77, `C_D` 0.71, L/D 1.08 (the orbiter's measured hypersonic L/D is about
  1.0–1.1). At 20° it is L/D 1.9.
- **Subsonic to supersonic**: a low-aspect-ratio delta. `C_L = k sin α cos α`, with
  `k` from 3.0 (subsonic) to 1.6 (Mach 3), and a drag polar
  `C_D = C_D0(M) + 0.2 C_L²` with `C_D0` 0.06 subsonic, rising through the transonic
  drag rise. Maximum L/D is about 4.6 near 11°.
- Blended between Mach 2.5 and 6.

The subsonic numbers are checked against the Approach and Landing Tests (ALT)
flown without the tailcone [1]:

- **Lift slope**: about 0.052 per degree, linear to 13°. That is where `k = 3.0`
  comes from (k is the slope per radian).
- **Drag polar**: the parabola agrees with the flight L/D within about 5% from
  `C_L` 0.2 to 0.6. Maximum L/D was about 4.7, at `C_L` 0.45–0.5.
- **Landing gear**: adds `ΔC_D` 0.020, the flight-derived value. The wind-tunnel
  prediction was 0.027. The gear counts from the moment it is commanded down.
- **Speed brake** (98.6° fully open): adds `ΔC_D = 0.00075 (δ − 20°)` past 20°,
  and nothing below. This fits the Rockwell Aerodynamic Design Data Book curves
  reproduced in NASA TM-81365 [2] (fig. 3, `C_L` 0.25–0.5): 0.003–0.006 at 25°,
  0.021–0.026 at 55°, 0.050 at 87°. With 0.020 for the gear, deploying the gear
  costs about as much as opening the brake a further 27°. JSC-23266 [3] gives
  40° for the operational data.

- **Ground effect**: `ΔC_L` against main-wheel height, the prediction the ALT
  flights matched (fig. 14 of [1], tailcone off, gear down): 0.108 on the runway,
  0.041 at 10 ft, 0.015 at 20 ft, nothing above 37 ft. Its effect on drag was
  negligible, so only lift changes. Flight control closes on normal acceleration, so
  the commanded α near the ground is the one the extra lift allows
  (`Vessel.winged_alpha` takes the wheel height). On the runway it is left out: the
  ALT data end at touchdown, and there it would only relieve the rolling friction.

The elevons give pitch authority in proportion to dynamic pressure.

## Entry

1. **Deorbit**: a retrograde burn that drops perigee to half the atmosphere's
   height, about 68 m/s from 300 km. With a launch site, the burn waits for an
   opportunity (below).
2. **Entry**: 40° nose up until 3.5 km/s, easing to 14° by Mach 2.5. From the
   first 50 Pa of dynamic pressure the bank angle tracks a drag reference. Banking
   only from 300 Pa skips the vehicle back out near 85 km. The nominal profile is
   about 5 m/s² while the air is thin and heating is the limit, the constant-drag
   phase's 33 ft/s² (10 m/s²) from 5 km/s, and 8 m/s² by TAEM. It is capped at
   14 kPa of dynamic pressure. The bank is
   `cos σ = (k (ḣ_ref − ḣ) + g − v_h²/r + D ḣ/v) / L`, with `v_h` the inertial
   horizontal speed. Air speed is about 400 m/s short of it eastward, which is
   worth about 1 m/s² of lift.
3. **Sink-rate reference**: holding a drag profile means sinking into denser air
   as the speed and α fall. With `D ∝ ρ v² C_D`, `ρ ∝ e^(−h/H)` and `v̇ = −D`,

       Ḋ/D = −ḣ/H − 2D/v − D dlnC_D/dv,   Ḋ = −D dD_ref/dv
       ⇒ ḣ_ref = −H (2D/v − dD_ref/dv + D dlnC_D/dv)

   plus 150 m/s per unit of relative drag error. Without the feed-forward term the
   drag lags its reference by about 20%.
4. **Roll reversals**: a bank turns the velocity off its line. Past a deadband
   (10° above 4 km/s, widening to 17° below 2.5 km/s, where TAEM's turn takes
   over), the bank goes to the other side.

## Landing at the launch site

A vessel launched from a pad (`Vessel.launch_site`) is flown back to it. The site
at coordinate time `t` is the pad turned by `Ω (t − t_placed)` (`Vessel.site_at`).
It is computed from time rather than integrated per frame, because guidance runs
on the unwarped frame `dt`.

**Deorbit opportunity.** For a burn `t_b` from now, the predictor:

- propagates the orbit to `t_b` (`Orbit.propagate`) and applies the burn;
- propagates the post-burn conic to entry interface (400,000 ft,
  `Orbit.time_to_radius_descending`);
- adds a modelled ground range along the ground-relative velocity at entry
  interface: `R = R_thin + R_nom(v) + R_glide(26 km)`.

`R_thin` = 3650 km is the thin-air descent to where the drag reference takes hold.
`R_nom(v) = ∫ u du / D_nom(u)` from v down to 760 m/s, and `R_glide` is the TAEM
and approach glide below.

Delaying the burn carries the predicted touchdown ahead at the orbital rate and
the site at the planet's. The downrange miss therefore falls through zero once a
revolution. The program scans a day ahead in 2-minute steps and bisects each zero.
It takes the first one whose crossrange is within 1100 km. Crossrange is measured
from the orbit's plane to the site at touchdown, entry interface plus 1850 s. The
closed loop made good 1130 km, but not 1210 km. Ten minutes before the burn, the
program re-solves it from the current state and fixes its Δv vector. From a 28.5°
orbit over Kennedy, the wait is up to most of a day: the plane passes near the pad
only for part of each day.

**Range control** (the Shuttle's): the nominal drag profile is scaled so that what
it flies to TAEM is the ground range left,
`D_ref = D_nom(v) · R_nom(v) / (R_togo − R_glide(26 km))`. For constant drag this
is `D = (v² − v_TAEM²) / 2R`. `D_ref` is floored at the drag at which the lift,
banked 30°, still holds the vehicle level, so some lift is always free to turn. It
is capped at 1.5× nominal and at 14 kPa.

**Lateral**: the first bank is toward the site. Reversals are referenced to the
plane through the vehicle and the site, using the ground-relative velocity. The
bank is at least 15° so that the turn never stops when the drag channel wants the
lift straight up.

**TAEM** aims the glide at the site:

- With too little energy for the range, the scheduled flight-path angle is
  shallowed by the ratio of the range the glide would fly to the range left.
  α is held at no more than best L/D, since a higher α only adds drag.
- With energy to spare, the track turns off the line to the site so that it
  closes at the rate the glide uses range, `cos ψ = R_togo / R_glide(h)`. This is
  an S-turn, and when far too high it becomes a circle round the site, as the
  heading-alignment cone is.
- The bank (at most 45°) nulls the heading error and levels out below 150 m.
- Down the outer glide slope, γ may also steepen 25% onto its line.

## TAEM, approach and landing

Below 760 m/s (about Mach 2.5) the wings level, or bank toward a launch site (above).
The flight-path angle is steered with α, solved from the lift the path needs:

    a_n = g cos γ + v k (γ_ref − γ),   C_L = m a_n / (q S cos σ)

The speed brake follows the Shuttle's autoland schedule [3, §2.5, §4.4]:

- **Down to 3000 ft**: it holds 300 KEAS. The command is proportional to the EAS
  error, about a trim that follows the error below 14,000 ft. The trim starts
  from the design's 65°.
- **At 3000 ft**: it is retracted to a value computed for the touchdown energy,
  and held there. Touchdown energy is targeted at 195 KEAS, or 205 KEAS above
  222,000 lb (100.7 t). The real logic sums I-loaded downrange sensitivities to
  wind, weight, velocity error and density altitude. Here the rest of the
  approach is flown in fast time, by the same laws, in still air
  (`_touchdown_eas`), and the brake setting that lands at the target is found by
  bisection. Limits are 15° (the linkage minimum) to 80°.
- **At 500 ft**: one adjustment, recomputed the same way and limited to 50°.
- **At touchdown**: full open at weight on wheels, for the rollout (below).

The flight-path reference is:

- **TAEM**: −8°, steepening to −20° by 4 km.
- **Outer glide slope**: −20°.
- **Preflare** from 600 m (2000 ft): a pull-up of at most 1.6 g onto the −1.5°
  inner slope by 40 m. Most of the turn is near the bottom, as a constant-g arc's is.
- **Gear down** at 90 m (300 ft).
- **Flare**: a sink rate of `0.9 + 0.11 h` m/s below 30 m.

Touchdown is on the main wheels. `gear.point`, in the stage frame, is the contact
patch, which sits off the vessel's reference point once the stack has staged
(`Vessel.contact_altitude`). The rating is 9.6 ft/s (2.9 m/s) of sink.

## Rollout

From main-gear touchdown the vessel is in `ROLLOUT` (`Vessel.Rollout`) until wheel
stop. It is physics on the ground, not a scripted slide:

- **Wheels**: the runway pushes on the wheels with whatever force keeps them on its
  curved surface, and never pulls. Enough lift would lift the vehicle off. Rolling
  friction is μN with μ = 0.025 on concrete [3, App. C.2]. The brakes act on the main
  wheels at up to 4 × 25,000 ft-lb on 44.5 in tyres [3, App. C.3]. The tyres' side
  force holds the track. The air still acts: lift and drag come from `winged_coeffs`
  at α = pitch, with the speed brake full open (100%, [3, §5.3.6.7]) and the gear down.
  Below θ = 0 the lift presses down on the wheels, as [3, §4.12] describes.
- **Derotation**: flight control slews the pitch rate about the main wheels to its
  command at the beep trim's 0.6°/s² ramp, and the nose wheels are the stop. The
  command is the design rate of 2°/s; beep trim commands 1.5°/s, and flights
  averaged 2.1°/s [3, §4.12]. The nose comes down at 185 KEAS whatever the weight,
  or at once if touchdown is slower [3, §5.3.6.7].
- **Drag chute** (flown from STS-49, May 1992): 40 ft conical ribbon, free-stream
  C_D 0.575, times a wake factor of 0.65–0.9 behind the orbiter (0.8 is used),
  reefed to 40% of its drag area [4]. It deploys at 195 KEAS. Seconds after the
  button: mortar at 1, out and reefed at 2.5, disreef at 6 [3, §5.3.6.7]. The 0.5 s
  fill after disreef is an estimate. It is jettisoned at 60 KGS [3].
- **Braking**: not before midfield, which is 5,000 ft past the nominal touchdown
  point (2,500 ft past the threshold of a 15,000 ft runway), and below 140 KGS. The
  target is 9 ft/s² overall, eased to 5.5 ft/s² below 40 KGS [3, §5.3.6.7, App. C.3].
  The pedal makes up whatever the air, the chute and the rolling friction do not
  supply.
- **Visuals**: the nose gear comes down with the pitch. The chute streams downstream
  on its riser (87.5 ft from the base to the skirt [4]), with its pilot chute behind
  it. The speed brake halves and four elevons are moving parts: during derotation
  the elevons go trailing-edge up to 10°, and with weight on the nose gear load
  relief takes them to 10° down at 20°/s [3, §4.12]. These are drawn only; their
  aerodynamics are not modelled.

| | Simulated (99–111 t) | Real |
|---|---|---|
| Main gear → nose gear touchdown | 10–11 s | 6 s (STS-115), 13 s (STS-118) |
| Nose gear touchdown | 144 KEAS, 0.63 m/s nose sink | typically 150 KEAS [4]; 147, 158 KEAS (STS-50, -49) |
| Peak non-braking deceleration | 11.3 ft/s² near disreef | 11–13 ft/s² at disreef [3, §4.11] |
| Braking starts | midfield, 91–100 KGS | 110 KGS on average with the chute [3, §4.13] |
| Rollout | 6,800–6,900 ft, 44 s | nominally stops 9,000–11,000 ft down the runway, i.e. 6,500–8,500 ft from a 2,500 ft touchdown [3, §4]; flown at KSC 7,771–10,708 ft in 50–65 s [5] |

`tools/missioncheck.tscn` requires, for `orbiter_return` and `orbiter_home`:

- a wheel stop;
- nose-gear touchdown at 130–170 KEAS;
- main-gear touchdown at no more than 11° pitch. Without ground effect the polar
  needs 12°; flown touchdowns were near 8°, and 14.6° scrapes the tail [3, §4.7];
- the chute deployed and jettisoned;
- wheel stop at 6,000–11,000 ft. The lower bound is the nominal 6,500 ft less the
  500 ft dispersion in [3, App. C.1]. The upper bound is just past the longest
  flown at Kennedy.

Known residuals:

- The sim touches down at 9.4° pitch, against about 8° in reality (12° before ground
  effect was modelled). The nose gear comes down at 144 KEAS, against a typical 150.
- The sim brakes firmly to the cue card, while crews were often gentler. Its
  rollouts are at the short end of the flown ones.
- The elevons' and the chute's pitching moments are not modelled, so derotation
  is rate-commanded.
- There is no crosswind, nose-wheel steering or antiskid limit.

## Results, from 300 km

| | Simulated | Real STS |
|---|---|---|
| Deorbit burn | 62–68 m/s | ~90 m/s (lower perigee target) |
| Roll reversals | 4–7, Mach 21 → 3 | typically 4 |
| Max dynamic pressure | ~18 kPa near 33 km (Mach 5.5) | ~14 kPa |
| TAEM interface | Mach 2.6, 25 km | Mach 2.5, ~25 km |
| Outer glide slope | −20°, 298–308 KEAS, brake 72–78° | −20° light, −18° heavy; 300 KEAS, brake ~65° mid-weight [3] |
| Speed brake set at 3000 ft | 37–41° | 15–80° (computed) [3] |
| Peak after the retract | 308 KEAS | ≈310 KEAS [3] |
| 3000 ft → 500 ft | 16 s | ~16 s [3] |
| 500 ft → touchdown | 19 s | ~23 s [3] |
| Deceleration, gear down | ~5 KEAS/s | just over 4 KEAS/s [3] |
| Touchdown | 1.1 m/s sink; 202–206 kt (107 t), 194 kt (99 t) | ~3 ft/s; 205 KEAS heavy, 195 light [3] |
| Touchdown pitch | 9.4° | about 8°; < 14.6° (tail scrape) [3] |
| Deorbit burn to touchdown | ~61 min | ~1 h |
| Miss at the launch site | 0.6–2.2 km | (runway) |

The miss is from 250–400 km circular and eccentric orbits, 28.5–51.6°, with up to
1130 km of crossrange.

The orbiter lands at 107 t, a heavyweight. The real one would have flown the −18°
outer glide slope, which accounts for the brake trimming above 65° on −20°. The
sim leaves the inner glide slope ~4 s sooner than the real one and decelerates
faster on it. The extra drag comes from the flight-derived gear increment, and STS
flights did better than the ALT-era data on L/D. Over the shorter time the two give the same touchdown energy. The brake
setting carries the difference.

## Sources

1. I. Hooks, D. Homan, P. Romere, "Aerodynamic Challenges of ALT", NASA JSC
   (1985), NTRS 19850008602. Figs. 12–15: tailcone-off L/D, lift and
   drag against α, ground effect, and the landing-gear increment.
2. H. J. Walker, *Analytic Study of Orbiter Landing Profiles*, NASA TM-81365
   (1981), NTRS 19820002128. Fig. 3: trimmed L/D against `C_L` for speed brake 0°,
   25°, 55° and 87°, gear up and down, Mach 0.25 and 0.6, from the Rockwell ADDB.
3. *Approach, Landing and Rollout Flight Procedures Handbook*, JSC-23266 Rev. B
   (NASA JSC, May 2005). §2.5 and §4.4: the speed brake; §4.5: preflare, gear, inner
   glide slope; §4.7: touchdown targets and constraints; App. B.2–B.4: outer
   glide slope design, the ~310 KEAS peak after the retract, the IGS
   deceleration, and ground effect; §4.8–4.14, §5.3.6.7–5.3.6.8 and App. C:
   rollout, drag chute, derotation, braking, rolling friction and brake torque.
4. R. E. Meyerson, *Space Shuttle Orbiter Drag Parachute Design*, AIAA 2001-2051
   (NTRS 20110001620): C_D 0.575, wake factor 0.65–0.9, 40% reefing, 87.5 ft
   trailing distance, NGTD ~150 KEAS, STS-47 to -62 deploy data. Also C. H. Lowry,
   *Space Shuttle Orbiter Drag Chute Summary* (NTRS 20130010383): 40 ft ribbon
   canopy, 9 ft pilot chute, introduced on STS-49.
5. NASA mission pages (nasa.gov/mission/sts-NN), landing data: STS-47 8,567 ft
   51 s; -52 10,708 ft 63 s; -56 9,530 ft 63 s; -57 9,954 ft 65 s; -61 7,922 ft
   53 s; -60 7,771 ft 50 s; -62 10,151 ft 55 s; -49 (Edwards) 9,490 ft 58 s.
