# Rotorcraft: `sim/surface/rotorcraft.gd`, `rotorcraft_model.gd`

Two flying machines on one physics (`Rotorcraft.INGENUITY`, `Rotorcraft.DRAGONFLY`), in the air of the world they fly in:
- **Ingenuity**: set down beside Perseverance on Mars (key I).
- **Dragonfly**: let go from its backshell over Titan, in the Titan expedition.

Both fly in the site's frame (x west, y up, z north), SI, doubles, a fixed 1/400 s step on the flight clock,
drawn or not. They stand on the drawn ground ([the ground under a landing](surface.md#the-ground-under-a-landing))
and write nothing back.

## The rotors

Blade-element momentum theory with uniform inflow on an untwisted blade:

- **Thrust:** C_T = (σa/2)(θ/3 − λ/2), for solidity σ, lift slope a, collective θ and inflow ratio λ.
- **Inflow:** λ = λ_c + C_T / (2√(μ² + λ²)) (Glauert), solved by Newton's method from the axial solution. λ_c is
  the climb speed over the tip speed and μ the speed across the disc over the tip speed.
- **Coaxial pairs:** each pair shares one disc, its inflow set by the pair's total thrust.
- **Power:** C_P = κκ_c C_T λ_i + C_T λ_c + (σC_d0/8)(1 + 4.65μ²), with κ = 1.15 for a real rotor's induced
  losses and κ_c = 1.28 for a coaxial pair's lower rotor in the upper's wake (Leishman & Syal 2008). The profile
  term grows with advance ratio as Leishman gives.

The two craft control their rotors differently:
- **Ingenuity** holds its rotors at 2537 rpm and makes its thrust with collective, which stops at 24°. It steers
  with cyclic, tilting each rotor's thrust.
- **Dragonfly's** rotors are fixed-pitch and change speed. Its four pairs share the thrust unevenly to roll and
  pitch it.
- **Yaw**, on both, comes from the difference between each pair's upper and lower torque.

The battery pays the shaft power over the motors' efficiency, plus the avionics.

## The flight software

It holds a commanded velocity over the ground in the heading's frame, a climb rate and a yaw rate, flown as a
thrust vector within the craft's tilt limit and the attitude that points it.
- **Height:** with the climb stick centred it holds its height over the ground below, as both real craft do with
  their laser altimeters, and slows where the ground rises faster than it can climb.
- **On the ground:** once down without a climb command it idles there until told to climb.
- **The yaw integrator** is held at zero while the rotors are not carrying the craft, so a creep on the ground
  cannot wind it up.

## Ingenuity

From NASA:
- 1.8 kg, two coaxial counter-rotating rotors of 0.605 m radius with two blades each.
- A blade area of 0.170 m² a rotor (solidity 0.148; Koning et al., NASA TM 2024), at a constant 2537 rpm.
- About 350 W in flight, 10 m/s at most, 24 m at the highest.

These are estimates:
- the airfoil's lift slope (5/rad) and drag (0.035), a thin cambered section near Reynolds number 20,000;
- the hubs' heights, the legs and the body's drag;
- the motors' 75% efficiency, 30 W of avionics and a 40 Wh battery.

It flies in the air the Mars table has at the site: 0.0151 kg/m³ at Jezero, whose 2.6 km below the datum the
table does not go under. NASA measured about 0.0165 kg/m³ during its flights.

## Dragonfly

From NASA: 875 kg, 3.85 m across, eight 1.35 m rotors as four coaxial pairs. These are estimates:
- the arms;
- the blades' fixed pitch (0.24 rad) and solidity (0.10), and the speed limit;
- the airfoil (5.7/rad, C_d0 0.012);
- the legs and the body's drag area (0.8 m²);
- the motors' efficiency;
- a 14 kWh battery, the upper bound of [Lorenz et al. 2018](https://www.researchgate.net/publication/329129271_Dragonfly_A_rotorcraft_lander_concept_for_scientific_exploration_at_titan): what the MMRTG gives over a Titan night.

Its descent:
- **Entry:** at Huygens' 6.0 km/s, 30° down. The flight's Titan air is one 21 km scale height, steeper than the
  real extended upper air that held Huygens near 12 g on its 65°, so a Huygens-steep entry here passes 20 g.
- **Chute:** opens at Huygens' Mach 1.5.
- **Release:** it leaves the backshell 1.2 km up (an estimate) and flies itself down at 3 m/s.
- **Landing:** below 40 m it looks at the ground under it, and over ground steeper than 12° it holds its height
  and moves on, as its hazard lidar picks its spot. It is then flown with the keys.

## Titan

`sim/titan_moon.gd`, the Titan expedition preset: Titan on a circular orbit in Saturn's equatorial plane (NASA's
factsheet), not an ephemeris.
- **Surface:** 93.65 K and 1.467 bar, stated from Huygens (Fulchignoni et al. 2005).
- **Methane:** its climate column is all nitrogen, because the gas fits know methane only at Earth's trace. The
  flight's air table and the entry's glow carry its methane.
- **Ground:** with no measured map it stands on the crust its visual draws. The crust's relief is 3.2 km on every
  world, and a survey's roughness scales as 1/g, so Titan's ground here is far rougher than its real dunes and
  plains.
- **Seas:** not drawn yet.

The Survey Shuttle comes in from 800 km over Titan. Without a landing site, its deorbit burn aims its perigee
where the air reaches 1e-4 kg/m³, never above half the air's top: about 75 km on Earth, and inside Titan's
extended air rather than at half its 600 km.

## What tests it

`rotorcheck` (headless, fast suite):

| Test | This model | Reference |
| --- | --- | --- |
| Ingenuity's induced power | 130.4 W | κκ_c T^1.5/√(2ρA), exact |
| Ingenuity hovering at 0.0165 kg/m³ | 340 W at the battery (232 W at the shafts), collective 10.3° | NASA: about 350 W in flight |
| Its tip Mach | 0.70 at 2537 rpm | about 0.7 |
| Dragonfly hovering on Titan | 10.9 kW at the shafts, figure of merit 0.47, 723 rpm | a small rotor's 0.5–0.75 (Leishman) |
| A 420 kg Dragonfly at 10 m/s | 3.1 kW at the shafts and against drag | Lorenz et al. 2018: a little over 2 kW for their 420 kg concept |
| Each, on a plane | rests, climbs, holds its height, reaches 10 m/s, turns right a quarter turn, lands | |

`groundcheck` sets Ingenuity down beside Perseverance after the Sky Crane landing. It flies up 8 m on the site's
own air and ahead at 10 m/s, then lands with its feet on the drawn triangles to 6 mm.

`titancheck` (flight, headless):
- Dragonfly comes down from the top of Titan's air, its chute opening at Mach 1.49.
- It leaves the backshell and lands itself on less steep ground, tilted 4°, a foot on the drawn triangles.
- It flies 73 m up and 9 m/s across the hills, never under 68 m, then stands again.
- Drawn and undrawn descents land identically.
- The Survey Shuttle comes in from orbit and stops.
- Dragonfly's descent under its chute and the Shuttle's glide take hours, as Huygens' 2.5 under its chutes
  did, so they are flown at 20× here and are not scenarios to jump to. At 20× the Shuttle's flare settles
  differently: it touches down at 7.6 m/s against 20.4 m/s at 1×.
- Every ground is let go.

Mutations: Glauert's factor of two, and the yaw split's sign.

Not modelled: blade twist and taper, the rotors' own dynamics (flapping, the time to change speed or pitch),
ground effect, the wind, Ingenuity's solar charging, and the sols between flights.
