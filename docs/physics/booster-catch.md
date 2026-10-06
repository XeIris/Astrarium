# Booster return and tower catch

Super Heavy's return to the launch tower: `Vehicles.booster_return`,
`CatchTower` (`sim/flight/catchtower.gd`) and the `catch` program in
`sim/flight/guidance.gd`. The arms are drawn by `LaunchSite` and authored in
`model_sources/blender/launchpads.py`.

## What the real flights show

Flight 5 (13 October 2024) was the first catch. Flights 7 and 8 followed, then a reflown booster on Flight 9.

| Event (Flight 5) | T+ |
|---|---|
| MECO | 2:35 |
| Boostback start / shutdown | 2:45 / 3:41 |
| Landing burn start | 6:30 |
| Landing burn shutdown and catch | 6:54 |

- Hot staging happens at about 66 km and 5,710 km/h (Flight 3 webcast telemetry).
- During boostback the inner engines relight. For the landing burn the booster lights its inner 13
  engines, then shuts down all but the centre 3 (SpaceX's flight descriptions).
- The booster flies no entry burn. Viewers reading the webcast quoted a fall of about 4,500 km/h
  (1.25 km/s) half a minute before the catch, drag near 40 m/s² at 3,000 km/h, and about 1,250 km/h
  at landing-burn start. A peak deceleration near 5.5 g has also been reported. All of these are
  second-hand webcast readings.
- The booster slows to a near hover, slides sideways to the arms, and the arms close
  around it before the engines shut down. It hangs from two pins between its grid fins.
- The tower is about 146 m tall. The catch arms are reported as roughly 36 m long and ride a
  carriage on the tower. The booster is 71 m long and 9 m across, with a dry mass of 275 t.

Sources: Wikipedia ([SpaceX Super Heavy](https://en.wikipedia.org/wiki/SpaceX_Super_Heavy),
[Starship flight test 5](https://en.wikipedia.org/wiki/Starship_flight_test_5),
[flight test 3](https://en.wikipedia.org/wiki/Starship_flight_test_3),
[flight test 7](https://en.wikipedia.org/wiki/Starship_flight_test_7));
[Everyday Astronaut, Flight 5](https://everydayastronaut.com/starship-super-heavy-flight-5/);
[Hacker News webcast discussion](https://news.ycombinator.com/item?id=41828439);
[SpaceNexus, Mechazilla](https://spacenexus.us/blog/how-spacex-catches-rockets-mechazilla)
(the arm length and the 1–2 m approach window; a secondary source).

## The model

The start state is the apogee after boostback: 95 km up, coming home at 60 m/s.
Falling from 95 km takes about 150 s to the landing burn. That matches the interval
between apogee and T+6:30, and the fall peaks near 1.2 km/s. The boostback itself is
not flown. `CatchTower.return_state` solves the downrange and crossrange offsets the
way a boostback targets: it flies the coast and the catch guidance to landing-burn
ignition, predicts where a constant-deceleration burn would stop (r + v·t_go/2), and
moves the start by that point's miss from the approach point.

The flight program, `catch`, runs in these phases:

1. **Coast.** Engines down while q is below 1 kPa, then retrograde. No entry burn.
   On RCS alone a 71 m booster turns at about 0.002 rad/s², so following the
   near-horizontal airflow at apogee would take about 50 s to slew. The shared q guard
   remains as a safety net.
2. **Landing burn on 13 engines.** Ignition comes from integrating the burn forward
   with this model's density and engines-first drag. Drag is several g here and falls
   as the booster slows, so no constant stands in for it. Above q·0.05 > qα the booster
   thrusts along the airflow, because the q·α limit allows less angle of attack than
   the flight path's own tilt. Lower down it diverts with the quadratic law,
   a = 6Δr/t² − 4v/t.
3. **Centre 3.** The 13 hand over to 3 where the centre engines alone can still stop at
   the gate. The booster descends to a hover gate 6 m above the rails, 15 m out from the
   axis, then slides in.
4. **Catch.** The tower starts closing its arms (3 s) once the pins are within 25 m
   above the rails and inside the catch radius. The booster then descends at 2 m/s.
   When the pins cross the rails, the booster is caught if the arms are closed, it is
   within the catch radius, and its rates are inside the rating. Otherwise it is lost:
   to the closing arms, to a missed rail, or to the tower itself.
5. **Settle.** The shock absorbers are a damped spring (about a 3 s period, ζ 0.7) that
   takes up the contact speed.

Three Raptors at the 40% floor deliver about 2.71 MN at sea level. A near-empty
booster weighs about 2.70 MN, so the final hover is marginal. That matches the real
catch masses.

### Estimates (none published)

| Quantity | Value | Why |
|---|---|---|
| Catch radius | 1.5 m | The reported 1–2 m approach window |
| Rated vertical / lateral contact | 3.0 / 1.0 m/s | "Several m/s" descending onto the arms; the same rating as the legged landers |
| Base clearance above the deck | 8 m | Booster engines just clear the launch mount's clamps |
| Arm closing time | 3 s | From catch footage |
| Landing propellant | 130 t | Sized by this model's flight, with about 20 t left at the catch, inside the authored 6% reserve |
| Descent limits | maxQ 350 kPa, maxG 6.5 | The unpowered descent the real booster flies peaks near 210 kPa and 5 g in this drag model. The stack's 45 kPa is an ascent bending limit |
| Apogee / homeward speed | 95 km / 60 m/s | The timeline above. Slow, because nothing steers the coast without grid-fin lift |

### Known differences

- **Grid fins** are drawn but neither steer nor add drag. The real booster steers its
  coast on them. Here, the start state's homeward speed stands in for that steering.
- **The landing burn** lights at about 6.6 km and lasts about 45 s, against roughly
  24 s on the real flights. This booster reaches the lower atmosphere faster than the
  real one, so the 13 engines start higher and run longer.
- **Our ascent stages Super Heavy dry** at about 2.7 km/s over the ground, where the
  real booster stages at about 1.6 km/s with its return propellant held back.
  `reserve` is used only by the Δv readout. The return scenario therefore starts from
  real figures, not from our own ascent.
