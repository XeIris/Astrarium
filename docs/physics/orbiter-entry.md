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
  `k` from 2.3 (subsonic) to 1.6 (Mach 3), and a drag polar
  `C_D = C_D0(M) + 0.2 C_L²` with `C_D0` 0.06 subsonic, rising through the transonic
  drag rise. Maximum L/D is about 4.6 near 14°. The speed brake adds up to 0.09.
- Blended between Mach 2.5 and 6.

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

The speed brake holds 290 KEAS. The flight-path reference is:

- **TAEM**: −8°, steepening to −20° by 4 km.
- **Outer glide slope**: −20°.
- **Preflare** from 600 m (2000 ft): a pull-up of at most 1.6 g onto the −1.5°
  inner slope by 40 m. Most of the turn is near the bottom, as a constant-g arc's is.
- **Gear down** at 90 m (300 ft).
- **Flare**: a sink rate of `0.9 + 0.11 h` m/s below 30 m.

Touchdown is on the main wheels. `gear.point`, in the stage frame, is the contact
patch, which sits off the vessel's reference point once the stack has staged
(`Vessel.contact_altitude`). The rating is 9.6 ft/s (2.9 m/s) of sink.

## Results, from 300 km

| | Simulated | Real STS |
|---|---|---|
| Deorbit burn | 62–68 m/s | ~90 m/s (lower perigee target) |
| Roll reversals | 4–7, Mach 21 → 3 | typically 4 |
| Max dynamic pressure | ~17 kPa, outer glide slope | ~14 kPa |
| TAEM interface | Mach 2.6, 25 km | Mach 2.5, ~25 km |
| Outer glide slope | −20°, ~300 KEAS | −18 to −20°, ~290–300 KEAS |
| Touchdown | ~1.3 m/s sink, ~235 kt | 1–3 ft/s, 195–215 kt |
| Deorbit burn to touchdown | ~61 min | ~1 h |
| Miss at the launch site | 0.6–2.2 km | (runway) |

The miss is from 250–400 km circular and eccentric orbits, 28.5–51.6°, with up to
1130 km of crossrange.
