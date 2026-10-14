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
the air, 2× under power above it, 10× on unpowered coasts above it. One exception
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

A built `air` or `return … at` base is the replay's own state where it passed that
altitude (in [scenarios.gd](../sim/flight/scenarios.gd), `ORBITER_AIR`, `SHIP_AIR`,
`_booster_air`), so the comparison also catches a base gone stale after a change to
guidance or aerodynamics: rebuild it from the replay's numbers.

Results on this revision are below (M5, headless). Jump times are wall-clock for
the whole jump, building included.

RESULTS

## Known limits

- Guidance is stepped once a frame with the frame's wall time, so a flight at 2× in
  the air steers at half the rate of the flight time it integrates. The orbiter does
  not survive its entry at 2× (it is lost at 37 km); scenarios never fly 2× in the air.
- Super Heavy's return from its boostback apogee solves the boostback's aim by flying
  the coast up to eight times (`CatchTower.return_state`, several seconds). The solve
  starts from the last solution for that booster, so a second jump costs one try; the
  booster scenarios start 15 km over the tower instead.
- A jump keeps the trail and pad cloud only while it is in the air; a scenario that
  starts above the air has none behind it.
