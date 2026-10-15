# Flight scenarios

Developer mode (Settings › Controls) and `scenario=<vehicle>:<id>` put the flight in a
named moment without replaying the mission to it. The registry is
[sim/flight/scenarios.gd](../sim/flight/scenarios.gd); this page says how a scenario
is reached, how close that is to a played flight, and what the checks hold it to.

## How a scenario is reached

A scenario is a **base**, built directly, and optionally a **condition** that the
real flight is flown to from there.

| base | built as | used by |
|---|---|---|
| `pad` | `Spaceflight.begin(mode=pad)` and the terminal count at T−10 s, in the local morning | every ascent |
| `orbit` | a circular orbit, with stages dropped or jettisoned and propellant set | parking orbits, deorbit burns, the LM's descent |
| `return` | Super Heavy after its boostback (`CatchTower.begin_return`); with `at`, part-way down relative to the tower | booster return and catch |
| `descent` | `tools/flight_scenarios.json`'s descent starts (`flightcheck`'s f9booster and skycrane) | Falcon 9 booster, Mars EDL |
| `air` | an altitude, airspeed and flight-path angle on an orbit's track, the program's first guidance cycle, the attitude it asks for, and its filters as they were in flight | the Shuttle's and Starship's returns |

The condition (`until`) is flown by `FlightScenarios.Jump`: the frame loop
`main.step_flight` that `animate()` runs, at a frame of 50 ms (the longest frame the
game takes, so the jump is a flight played at 20 fps), undrawn. The warp is what a
player could choose, picked by `FlightScenarios.played_warp`: 1× in the count and in
the air, 2× under power above it, 10× on unpowered coasts above it. Guidance runs
once per frame interval of flight time (`Spaceflight.update`), so 2× in the air
lands the orbiter as 1× does, but a Shuttle ascent flown at 2× in the air still cuts
off 10 km higher; the jump stays at 1× there. One exception
leaves the played path: an unpowered coast down to the air with no burn pending is
flown in one step on its exact conic (`Vessel.step`'s rails), to 25 km above the
atmosphere's top, where guidance takes the attitude over again. That coast is
unperturbed two-body motion rather than the integrated tidal model; it changes the
entry interface by metres.

Undrawn means `Spaceflight.fast_forward`: the sky, lighting, cameras, entry glow and
vapour are skipped. In the air (level 1) the plumes, the pad cloud and the smoke trail
are still laid frame by frame, so the trail behind a vehicle at max-Q is the one it
flew; above the air (level 2) only what physics and the pad read is kept: dropped
stages and their falls, the launch site's rotation and arms, the planet's turn.

The world is the solar preset with its random phases fixed (`main.scenario_world`),
so a scenario's sky, Moon and pad lighting repeat.

## Agreement with a played flight

`tools/scenariocheck.tscn -- replay=1` flies every scenario that has a condition again
as played: from the base it stands in for, at 1/60 s frames, through the same warp
rule, with no coast on rails. At the same condition it compares altitude, airspeed,
flight-path angle, mass and time since liftoff with what the jump handed over, and
fails outside `TOLERANCE` in that file:

| quantity | tolerance | why it differs at all |
|---|---|---|
| altitude | 500 m + 3 % | guidance runs once a frame, so a 20 fps flight steers at a third of the rate |
| airspeed | 20 m/s + 3 % | the same |
| flight-path angle | 1° | the same |
| mass | 100 kg + 0.3 % | ignition and cutoff fall on a frame boundary: 33 ms of an F-1 cluster's flow is 430 kg |
| time since liftoff | 1 s + 1 % | the condition is tested once a frame |

Two kinds of scenario differ from that rule, both because a descent's guidance acts
on a test made once a frame. A booster's landing burn (`catch`, `hoverslam`) lit
hundreds of metres apart at 20 and 60 fps, so those jumps are flown at 60 fps
(`dt`) and agree with the played flight to the metre from the same base. The LM's
P63 and P64 are flown at 20 fps and reach P64 about 2 s early with 90 kg more
burned (1 %); their `tol` allows 6 % in speed, 2.5 % in mass and 2° of flight-path
angle, rather than tripling a 5 s jump.

A built `air` or `return … at` base is the replay's own state where it passed that
altitude (in [scenarios.gd](../sim/flight/scenarios.gd), `ORBITER_AIR`, `SHIP_AIR`,
`_booster_air`), so the comparison also catches a base gone stale after a change to
guidance or aerodynamics: rebuild it from the replay's numbers.

Results on this revision are below (M5, headless; a windowed jump that draws while
it waits is about a fifth slower). Jump time is wall clock for the whole jump,
building included; a built base's own row has no condition to replay. The Super
Heavy boostback base solves its boostback aim from scratch in a fresh process (12 s
here), which the later booster scenarios avoid.

| scenario | hand-over | jump | jump − played |
|---|---|---|---|
| `saturnv:pad` | 0.00 km, 0 m/s air, — | 0.5 s | built directly |
| `saturnv:liftoff` | 0.11 km, 25 m/s air, ascent/vertical | 0.4 s | alt +0.8 m, speed +0.1 m/s, fpa +0.0°, mass -434.4 kg, t +0.0 s |
| `saturnv:max_q` | 13.03 km, 520 m/s air, ascent/turn | 1.4 s | alt +12.5 m, speed +0.2 m/s, fpa +0.0°, mass -434.3 kg, t +0.0 s |
| `saturnv:sic_staging` | 57.65 km, 2302 m/s air, ascent/closed | 2.6 s | alt +35.4 m, speed -0.4 m/s, fpa +0.0°, mass -173.7 kg, t +0.0 s |
| `saturnv:interstage` | 81.42 km, 2582 m/s air, ascent/closed | 3.0 s | alt +31.2 m, speed -0.9 m/s, fpa +0.0°, mass +0.0 kg, t +0.0 s |
| `saturnv:sii_staging` | 112.71 km, 6724 m/s air, ascent/closed | 8.7 s | alt -24.5 m, speed -0.6 m/s, fpa +0.0°, mass -41.7 kg, t +0.0 s |
| `saturnv:orbit` | 185.00 km, 7394 m/s air, — | 0.0 s | built directly |
| `falcon9:pad` | 0.00 km, 0 m/s air, — | 0.1 s | built directly |
| `falcon9:liftoff` | 0.03 km, 16 m/s air, ascent/vertical | 0.3 s | alt +0.6 m, speed +0.1 m/s, fpa +0.0°, mass -91.7 kg, t +0.0 s |
| `falcon9:max_q` | 11.84 km, 455 m/s air, ascent/turn | 1.2 s | alt +1.8 m, speed +0.0 m/s, fpa +0.1°, mass -23.3 kg, t +0.0 s |
| `falcon9:meco` | 59.25 km, 2553 m/s air, ascent/closed | 2.5 s | alt +13.9 m, speed -1.2 m/s, fpa +0.0°, mass +17.4 kg, t -0.1 s |
| `falcon9:fairing` | 125.48 km, 3403 m/s air, ascent/closed | 4.3 s | alt +34.1 m, speed -0.5 m/s, fpa +0.0°, mass +0.0 kg, t +0.0 s |
| `falcon9:orbit` | 210.00 km, 7360 m/s air, — | 0.0 s | built directly |
| `falcon9:booster_return` | 70.00 km, 1020 m/s air, hoverslam | 0.0 s | built directly |
| `falcon9:entry_burn` | 38.17 km, 1281 m/s air, hoverslam | 0.9 s | alt +0.0 m, speed +0.0 m/s, fpa +0.0°, mass +0.0 kg, t +0.0 s |
| `falcon9:landing_burn` | 0.74 km, 213 m/s air, hoverslam | 4.7 s | alt +0.0 m, speed +0.0 m/s, fpa +0.0°, mass +0.0 kg, t +0.0 s |
| `shuttle:pad` | 0.00 km, 0 m/s air, — | 0.1 s | built directly |
| `shuttle:liftoff` | 0.04 km, 23 m/s air, ascent/vertical | 0.3 s | alt +0.8 m, speed +0.1 m/s, fpa +0.0°, mass -406.9 kg, t +0.0 s |
| `shuttle:roll_program` | 0.12 km, 38 m/s air, ascent/vertical | 0.3 s | alt +1.3 m, speed +0.2 m/s, fpa +0.0°, mass -410.8 kg, t +0.0 s |
| `shuttle:max_q` | 11.44 km, 451 m/s air, ascent/turn | 1.1 s | alt +23.1 m, speed +0.6 m/s, fpa -0.1°, mass -676.2 kg, t +0.1 s |
| `shuttle:srb_sep` | 43.49 km, 1402 m/s air, ascent/turn | 2.0 s | alt -19.2 m, speed -0.2 m/s, fpa -0.1°, mass +0.5 kg, t -0.1 s |
| `shuttle:meco` | 111.93 km, 7472 m/s air, circularize | 10.1 s | alt +3.1 m, speed -0.1 m/s, fpa +0.0°, mass -7.4 kg, t +0.0 s |
| `shuttle:et_sep` | 113.04 km, 7470 m/s air, circularize | 10.4 s | alt +4.1 m, speed -0.1 m/s, fpa +0.0°, mass -2.8 kg, t +0.0 s |
| `shuttle:orbit` | 300.00 km, 7433 m/s air, — | 0.0 s | built directly |
| `shuttle:deorbit` | 300.00 km, 7433 m/s air, glide/deorbit | 0.1 s | alt +0.0 m, speed +0.0 m/s, fpa +0.0°, mass -1.5 kg, t +0.3 s |
| `shuttle:entry_interface` | 122.00 km, 7577 m/s air, glide/entry | 3.4 s | alt +0.1 m, speed +0.0 m/s, fpa +0.0°, mass -14.3 kg, t +0.1 s |
| `shuttle:entry_80km` | 80.00 km, 7568 m/s air, glide/entry | 0.0 s | alt +0.3 m, speed +0.1 m/s, fpa +0.0°, mass -243.9 kg |
| `shuttle:peak_heating` | 63.95 km, 7074 m/s air, glide/entry | 3.0 s | alt -1907.7 m, speed +137.4 m/s, fpa +0.2°, mass -106.0 kg |
| `shuttle:roll_reversal` | 63.14 km, 6095 m/s air, glide/entry | 6.3 s | alt -982.9 m, speed -187.2 m/s, fpa -0.1°, mass -105.4 kg |
| `shuttle:taem` | 24.40 km, 760 m/s air, glide/taem | 0.0 s | alt -20.1 m, speed -0.3 m/s, fpa +0.0°, mass -11.9 kg |
| `shuttle:final_approach` | 3.99 km, 193 m/s air, glide/approach | 0.0 s | alt -11.0 m, speed -0.9 m/s, fpa +0.3°, mass -11.9 kg |
| `shuttle:flare` | 0.60 km, 162 m/s air, glide/flare | 0.7 s | alt -1.4 m, speed -0.1 m/s, fpa +0.1°, mass -11.9 kg |
| `shuttle:rollout` | -0.00 km, 101 m/s air, glide/rollout | 1.1 s | alt +0.1 m, speed +1.2 m/s, fpa +0.0°, mass -11.9 kg |
| `starship:pad` | 0.00 km, 0 m/s air, — | 0.1 s | built directly |
| `starship:liftoff` | 0.06 km, 25 m/s air, ascent/vertical | 0.4 s | alt +0.8 m, speed +0.1 m/s, fpa +0.0°, mass -833.3 kg, t +0.0 s |
| `starship:max_q` | 11.58 km, 450 m/s air, ascent/turn | 1.4 s | alt +7.3 m, speed +0.2 m/s, fpa +0.0°, mass -534.5 kg, t +0.0 s |
| `starship:hot_staging` | 59.38 km, 2352 m/s air, ascent/closed | 3.0 s | alt +1.9 m, speed -0.8 m/s, fpa +0.0°, mass +108.8 kg, t -0.1 s |
| `starship:orbit` | 200.00 km, 7366 m/s air, — | 0.1 s | built directly |
| `starship:deorbit` | 200.00 km, 7366 m/s air, bellyflop/deorbit | 0.1 s | alt +0.0 m, speed +0.0 m/s, fpa +0.0°, mass -0.6 kg, t +0.3 s |
| `starship:bellyflop` | 80.00 km, 7314 m/s air, bellyflop/entry | 0.1 s | alt +0.5 m, speed +14.5 m/s, fpa -0.1°, mass -347.1 kg |
| `starship:subsonic` | 15.00 km, 192 m/s air, bellyflop/entry | 0.0 s | alt +1.1 m, speed +0.0 m/s, fpa -0.1°, mass -39.4 kg |
| `starship:flip` | 0.59 km, 71 m/s air, bellyflop/flip | 1.6 s | alt -4.0 m, speed +0.0 m/s, fpa +0.5°, mass -114.2 kg |
| `starship:landing_burn` | 0.37 km, 61 m/s air, bellyflop/landing | 1.7 s | alt -2.9 m, speed -0.3 m/s, fpa +0.4°, mass -114.2 kg |
| `starship:boostback` | 95.00 km, 60 m/s air, catch | 9.2 s | built directly |
| `starship:booster_15km` | 14.98 km, 1089 m/s air, catch/coast | 0.1 s | alt +0.0 m, speed +0.0 m/s, fpa +0.0°, mass -759.2 kg |
| `starship:booster_landing_burn` | 9.21 km, 931 m/s air, catch/landing | 0.4 s | alt -76.8 m, speed -3.3 m/s, fpa +0.0°, mass -759.1 kg |
| `starship:tower_catch` | 0.40 km, 52 m/s air, catch/terminal | 2.3 s | alt +0.0 m, speed -0.1 m/s, fpa +0.0°, mass +134.2 kg |
| `lm:powered_descent` | 15.00 km, 1668 m/s air, land | 0.0 s | built directly |
| `lm:approach` | 2.66 km, 154 m/s air, land/P64 | 3.8 s | alt -1.8 m, speed +0.3 m/s, fpa +0.2°, mass -87.9 kg, t -2.2 s |
| `lm:terminal_descent` | 0.09 km, 21 m/s air, land/P66 | 4.5 s | alt -2.5 m, speed -0.2 m/s, fpa +0.1°, mass -83.3 kg, t -1.8 s |
| `skycrane:entry` | 125.00 km, 5560 m/s air, edl | 0.0 s | built directly |
| `skycrane:parachute` | 6.19 km, 387 m/s air, edl/chute | 2.6 s | alt -11.8 m, speed -0.3 m/s, fpa +0.0°, mass +0.0 kg, t +0.1 s |
| `skycrane:powered_descent` | 1.79 km, 107 m/s air, edl/powered | 3.0 s | alt -6.0 m, speed +0.0 m/s, fpa +0.0°, mass +0.0 kg, t +0.1 s |
| `skycrane:sky_crane` | 0.02 km, 1 m/s air, edl/powered | 3.6 s | alt +0.0 m, speed -0.1 m/s, fpa -0.5°, mass -0.3 kg, t +0.1 s |

## Known limits

- Super Heavy's return from its boostback apogee solves the boostback's aim by flying
  the coast up to eight times (`CatchTower.return_state`, several seconds). The solve
  starts from the last solution for that booster, so a second jump costs one try; the
  booster scenarios start 15 km over the tower instead.
- A jump keeps the trail and pad cloud only while it is in the air; a scenario that
  starts above the air has none behind it.
