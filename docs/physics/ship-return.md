# Starship's return: belly first, flip, landing burn

The `bellyflop` program (`Guidance.bellyflop_guidance`) brings a lone Starship
down the way the real one comes down. Flights 12–14 (2026) flew this profile to
splashdown; the tower catch of a ship is not yet flown.

## Broadside aerodynamics

A slender body at a high angle of attack is not a slender body any more. The
usual drag rule (`C_D (1 + 2.2 sin²α)` on the end-on area) gives a broadside
Starship a seventh of its real drag. The ship uses H. J. Allen's crossflow
model instead (`Vessel.accel`, for a stage with flaps flying alone). The
airflow is split along the axis and across it, and each part is treated as a
separate flow:

    axial  = q · C_D(M) · A_end · cos²α          along the flow
    normal = q · C_n(M) · L · D · 0.85 · sin²α   across the body, away from the windward side

`C_n` is a circular cylinder's crossflow drag coefficient: 1.2 subsonic,
rising to about 1.45 (Newtonian 4/3, plus the base) above Mach 1.4. The 0.85
takes the nose's taper off the planform `L·D`. The normal force is both drag
and lift: at α = 60° it holds the ship up through the hypersonic part of entry,
and at α = 90° it is all drag.

At sea level the fall settles at the terminal speed `v_t = √(2 m g / (ρ C_n S))`,
about 70 m/s for a ship near 130 t. Starship's measured belly-flop speed is
75–90 m/s.

## Steering with the flaps

The flaps steer in the airflow, so they give control authority wherever there is
dynamic pressure (`Vessel._aero_control`): about 25 m² each at a lever of
0.4 `L`, with a 0.6 coefficient. At a belly-flop's 4 kPa that is a few MN·m,
enough to flip the ship's ~3·10⁷ kg·m² in a few seconds. A falling booster's
grid fins work the same way, once it is descending.

## The sequence

1. **Deorbit**, if the ship is in orbit: periapsis to 35 % of the atmosphere's
   top.
2. **Entry, belly first.** The nose rides `α` above the velocity: 60° above
   Mach 3, opening to broadside (90°) by Mach 0.8. The belly is rolled into the
   flow (a signed roll, so the tiles and not the steel face it). The forward
   flaps fold out of the flow to bring the nose down, the aft ones to bring it up.
3. **Flip.** The flip starts once the altitude is within the fall during the flip
   (`v · 6 s`), plus the stopping distance on the three sea-level engines'
   descent profile, plus 40 m. The forward flaps fold away and the aft pair stays
   out, so drag at the tail and the gimbals swing the nose up to vertical.
   The vacuum engines stay dark.
4. **Landing burn.** It runs on three engines until one alone can stop the ship.
   Three cannot hover at their 40 % throttle floor. The touchdown is at
   0.8 m/s: there are no legs, and anything over 1 m/s is an impact.
