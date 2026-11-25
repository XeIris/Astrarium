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
  losses. A coaxial pair's induced power is 1.28 times that of its two rotors alone (Leishman & Syal 2008); sharing one
  disc already costs √2, so κ_c = 1.28/√2 = 0.905. The profile term grows with advance ratio as Leishman gives.
- **Axial flow:** λ_c is positive climbing (air down through the disc), so a climb costs the power that raises the
  weight and a descent gives some back. Vortex-ring states are not modelled.
- **Time:** the flight's, at any frame rate: what a frame leaves of a fixed step is carried to the next.

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
factsheet), not an ephemeris, on 1 July 2023, the Titan Mare Explorer's planned arrival in Titan's late northern
summer. Its orbital phase is chosen so that Ligeia Mare sees the Sun at noon when TiME comes down.
- **Surface:** 93.65 K and 1.467 bar, stated from Huygens (Fulchignoni et al. 2005).
- **Methane:** its climate column is all nitrogen, because the gas fits know methane only at Earth's trace. The
  flight's air table and the entry's glow carry its methane.
- **Poles:** its thick, slow air carries heat poleward, stated as the crust's transport (0.87). That gives 94.5 K
  at the equator and 91.2 K at Ligeia, against Cassini CIRS's 93.7 K and about 91 K (Jennings et al. 2016).
- **Ground:** with no measured map it stands on the crust its visual draws, at Titan's stated relief of 0.5 km
  (Lorenz et al. 2013's map: its highest gridded point 520 m over the 2575 km sphere, its lowest 1.7 km under;
  Corlies et al. 2017's new mountains none over 700 m). The whole of the crust's land relief follows a stated one,
  its detail and mountain belts with its continents (`terrain.gdshaderinc` and `PlanetRelief`, together). Titan
  has no plates, but it has ridges and mountain chains thought compressional (Mitri et al. 2010): the crust's belts
  stand for them at the stated relief's scale. A survey's roughness scales with it, its equatorial dunes are carved
  about a landing, and the flight's far ground and the site past its near grid shade them ([terrain](surface.md#terrain)).
  The globe seen from orbit draws none: Titan's haze hides its surface there in visible light, and Cassini saw the
  dune belt only through near-infrared windows and by radar.
- **Seas:** its three maria are stated where Cassini mapped them ([Titan's seas](ocean.md#titans-seas)), and the
  Titan Mare Explorer comes down on Ligeia.
- **Sky:** the haze hides the Sun and the stars, and the ground is lit by its diffuse light
  ([Mars and Titan](sky.md#mars-and-titan)).

The Survey Shuttle comes in from 800 km over Titan. Without a landing site, its deorbit burn aims its perigee at half
the air's top (Earth's 70 km). Where that is near vacuum, as at half Titan's 600 km, it aims where the air reaches
1e-4 kg/m³ instead. Over a mare Dragonfly's own landing stays up: its feet do not float.

## What tests it

`rotorcheck` (headless, fast suite):

| Test | This model | Reference |
| --- | --- | --- |
| Ingenuity's induced power | 92.2 W | 1.15 × 1.28 × its two rotors' alone, exact |
| Ingenuity climbing at 2 m/s | 7 W over its hover's 194 | the weight raised is 13 W; the inflow falls as it climbs |
| Ingenuity hovering at 0.0165 kg/m³ | 289 W at the battery (194 W at the shafts), collective 10.3° | NASA: about 350 W in flight |
| Its tip Mach | 0.70 at 2537 rpm | about 0.7 |
| Dragonfly hovering on Titan | 6.27 kW at the shafts, 647 rpm, figure of merit 0.83 | a rotor's 0.5–0.75 (Leishman), up to √2/1.28 more against a pair's one disc |
| Dragonfly climbing at 3 m/s | 9.03 kW | the weight raised is 3.54 kW |
| A 420 kg Dragonfly at 10 m/s | 3.46 kW at the shafts and against drag | Lorenz et al. 2018: a little over 2 kW for their 420 kg concept |
| Each, at 20, 60, 144 and 500 Hz | the same 5 s flown, to a fixed step | |
| Each, on a plane | rests, climbs, holds its height, reaches 10 m/s, turns right (Dragonfly by its rotors' torque alone, 17°/s), lands; stops where the ground ends | |

`groundcheck` sets Ingenuity down beside Perseverance after the Sky Crane landing. It flies up 8 m on the site's
own air and ahead at 10 m/s, then lands with its feet on the drawn triangles to 6 mm.

`titancheck` (flight, headless):
- Dragonfly comes down from the top of Titan's air, its chute opening at Mach 1.49.
- It leaves the backshell and lands itself, upright, a foot on the drawn triangles, 1.70 km over the datum. That
  is a summit of the crust's belts, over three times the 520 m of the highest gridded point of Lorenz et al.'s map, and
  inside the 2 km or so Corlies et al. keep it to, which is what the check holds: the belts are too high for Titan.
- It stands among dunes: across them the drawn ground carries 0.85 of the stated 120 m ridges (correlation 0.84, the
  rest its own relief), and the field's crests are 3,000 m apart, as stated.
- It flies 76 m up and across them at 9.8 m/s, never under 72 m, then stands again.
- Drawn and undrawn descents land identically.
- The Survey Shuttle comes in from orbit and stops.
- The Titan Mare Explorer comes down on Ligeia Mare and floats ([the sea](ocean.md#what-tests-it)).
- Dragonfly's and TiME's descents under their chutes and the Shuttle's glide take hours, as Huygens' 2.5 under
  its chutes did, so they are flown at 20× here, and only their first minutes are scenarios to jump to. At 20× the
  Shuttle touches down at 15.4 m/s and 0.7 m/s of sink, its flare scaled to its airspeed
  ([the approach](orbiter-entry.md)).
- Every ground and sea is let go.

Mutations: Glauert's factor of two, the yaw split's sign, a stated relief that leaves the crust's mountains at
Earth's, and dunes laid across their bearing.

Not modelled: blade twist and taper, the rotors' own dynamics (flapping, the time to change speed or pitch),
ground effect, the wind, Ingenuity's solar charging, and the sols between flights.
