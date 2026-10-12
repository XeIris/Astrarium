# The orbiter's way home: entry, glide and landing

The `glide` program (`Guidance.glide_guidance`) flies a lone Shuttle orbiter from
orbit to a touchdown on its main gear. `tools/missioncheck.tscn -- only=orbiter_return`
flies it from a 300 km orbit.

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
   height. From 300 km that is about 68 m/s, and touchdown follows about 81 minutes
   and 275° of orbit later. The real Shuttle's took about an hour.
2. **Entry**: 40° nose up until 3.5 km/s, easing to 14° by Mach 2.5. The bank
   angle tracks a drag reference: about 5 m/s² while the air is thin and heating is
   the limit, the constant-drag phase's 33 ft/s² (10 m/s²) from 5 km/s, and 8 m/s² by
   TAEM. The bank is
   `cos σ = (k (ḣ_ref − ḣ) + g − v_h²/r + D ḣ/v) / L`, with the sink-rate reference
   from the (low-passed) drag error.
3. **Roll reversals**: a bank turns the velocity out of the plane it entered in.
   Once that angle passes 10°, the bank goes to the other side. A flight from
   300 km makes four or five, between Mach 20 and 3.

There is no runway to aim at. The real reversals manage crossrange toward the
runway, and the real drag reference is set from the range still to fly. Here the
orbiter lands where the glide ends, along its orbit's ground track.

## TAEM, approach and landing

Below 760 m/s (about Mach 2.5) the wings level. The flight-path angle is steered
with α, solved from the lift the path needs:

    a_n = g cos γ + v k (γ_ref − γ),   C_L = m a_n / (q S)

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
| Deorbit burn | 68 m/s | ~90 m/s (lower perigee target) |
| Roll reversals | 4–5, Mach 20 → 3 | typically 4 |
| Max dynamic pressure | ~15 kPa, outer glide slope | ~14 kPa |
| TAEM interface | Mach 2.6, 26 km | Mach 2.5, ~25 km |
| Outer glide slope | −20°, 300 KEAS | −18 to −20°, ~290–300 KEAS |
| Touchdown | ~1.2 m/s sink, ~235 kt | 1–3 ft/s, 195–215 kt |
| Deorbit burn to touchdown | ~81 min | ~1 h |
