# Missions: route estimates and the guidance that flies them

`sim/flight/mission.gd` prices a trip from where the vehicle is to a destination
(`Mission.plan_route`) and flies it with no input from the pilot. The space map
and the hangar show the same plan. Everything here is patched conics: two-body
arcs joined at spheres of influence. The vehicle itself is integrated against
every body (`Vessel.step`). A plan made from conics therefore needs course
corrections when it is flown, and the mission makes them.

## The route

Let P be the body the vehicle orbits, D the destination, and C the lowest body
that both orbit (the Sun for Earth → Mars, the Earth for Earth → Moon). Parking
orbits are 200 km above the Earth, 110 km above the Moon (Apollo's), and
otherwise clear of any air.

| case | legs | estimate |
|---|---|---|
| launch | ascent and insertion | `v_circ(r_park) − 0.9·v_rot + loss`; loss ≈ 1.5 km/s × √(g/g⊕) with air, 6 % of `v_circ` without |
| a moon of P | Hohmann about P, corrections, arrival, capture | departure `Δv₁` of the Hohmann; capture `√(v∞² + 2μ_D/r) − √(μ_D/r)` with `v∞ = \|v_D − v_apo\|` |
| back to P's primary | escape on an ellipse whose periapsis is the parking orbit, then capture | `v∞ = \|v_P − v_apo\|` about D |
| another planet | Hohmann about C, escape and capture hyperbolas | departure `√(v∞² + 2μ_P/r₀) − √(μ_P/r₀)`; the burn is far smaller than the heliocentric Δv it buys (the Oberth effect) |

The first course correction is mostly a plane change. The parking orbit is
inclined to the equator by the launch site's latitude (28.5° from the Cape), and
the Moon's orbit is 18°–29° from the equator, so the angle between them depends
on the nodes. From the ground the planner takes the plane a due-east launch
would reach now (its pole is the site's north). Turning the transfer into the
destination's plane two thirds of the way out costs about `2·v·sin(i/2)` at the
speed there.

Propellant comes from the rocket equation, stage by stage from the lowest one
lit (`Mission.propellant_for`). The route is feasible when the Δv it needs is no
more than the vehicle's `delta_v_remaining`.

### The window

The departure waits until the phase angle φ (the target ahead of the departure
body, about C) reaches the Hohmann value `π − 2π·t_tof/T_target`. φ changes at
`n_target − n_dep` (difference of mean motions), so the wait is
`(φ_want − φ_now)/(n_tgt − n_dep)`, wrapped into one synodic period. That is the
circular, coplanar estimate. For a moon, φ is measured in the parking
orbit's plane (`Orbit.phase_angle` with its normal), since that orbit and the moon's
can be tens of degrees apart. Between planets the planner then searches a porkchop
(`Mission.porkchop_window`, `Orbit.porkchop`): departures over 1.1 synodic periods
and flight times from 0.6 to 1.4 of Hohmann's, each cell a Lambert arc between
the two bodies' conics, priced as the escape and capture burns at the parking
orbits. The cheapest cell sets the wait, the flight time and both v∞, and the
departure leg aims along its v∞ direction. Arcs within 2° of 180° have no defined
plane and are skipped. In `tools/flightphysicscheck.gd`, Mars's real eccentricity
moves the window 29 days from the circular estimate. Results are cached until the clock moves a fiftieth of
a synodic period.

## Flying it

Each burn is scheduled in coordinate time and handed to Guidance as a node
about four minutes before ignition. The vehicle turns at a warp it can steer at:
on rails, attitude is held, not flown. Until then the mission coasts on rails.
It picks the largest warp that reaches the next event in no less than four
seconds of real time, which is why a Mars transfer can be watched end to end.

1. **Departure.** For a moon, the burn raises the apoapsis to the moon's
   distance at the window. For a planet, the vehicle leaves along the planet's
   own motion with the Hohmann v∞. It does not aim at the destination by
   Lambert, because a Hohmann is a 180° transfer, whose plane a Lambert solution
   cannot fix. The burn point is the one, within one parking orbit after the
   window, whose escape hyperbola leaves closest to that direction. Each
   candidate's outgoing asymptote is `cos ν∞·P̂ + sin ν∞·Q̂` with
   `ν∞ = acos(−1/e)`. The planet's velocity is taken at the departure, which can
   be a year away. The burn point is found again from the orbit as it is when
   the window is near: thousands of revolutions on, the Moon and the Sun have
   moved the parking orbit's phase by an unpredictable amount.
2. **Course corrections.** Two of them, at 40 % and 60 % of the remaining
   coast. Each is a Lambert arc (`Orbit.lambert`: universal variables,
   bisection on z) from the vehicle to the destination's position, which is
   carried forward on its own conic about C. The arrival time is free within
   0.7–1.35 of what remains. The cheapest arc is chosen, priced as the burn
   now plus a twelfth of the arrival v∞, because a capture deep in a gravity
   well costs far less than its v∞ (the Oberth effect).
3. **Arrival.** Inside D's sphere, one burn sets the periapsis to the parking
   radius. It keeps the speed, and so the energy. The periapsis speed is then
   `v_p = √(v² − 2μ/r + 2μ/r_p)`, and the angular momentum needed is `r_p·v_p`,
   so the velocity is turned in its own plane until its tangential part is
   `r_p·v_p/r`. The conic leaves out the parent's tide, about 8×10⁻⁴ m/s² at the
   edge of the Moon's sphere, which moves the periapsis by hundreds of kilometres
   over a 15-hour coast in. The same burn is made again three hours before
   periapsis if the periapsis is then more than a quarter of the parking
   altitude off (Apollo's last midcourse correction played the same part).
4. **Capture.** The burn is retimed from the current conic just before it
   starts, because the other bodies' pull moves periapsis over a coast of hours.
   It is closed-loop: it chases the circular velocity at wherever the vehicle
   is, and stops when the remainder points back the way it came.
5. **Landing** (airless bodies, vehicles with gear). Lower the periapsis to
   15 km, then Apollo's P63/P64/P66 sequence (`Guidance.landing_guidance`).

## Skipping

Skip to arrival charges the planned Δv impulsively (`Vessel.spend_dv`, staging
what it empties) and advances the world through the window and the coast at up
to 10⁷×. It then places the vehicle in the parking orbit. The trajectory is not
flown, so it says so; a landing, if planned, is still flown.

## Launch azimuth

The ascent flies its target's plane. `Rocketry.launch_azimuth` gives the inertial
azimuth from sin β = cos i / cos φ. It takes whichever branch, north- or south-going,
the site's range allows (`Rocketry.LAUNCH_RANGES`, found by the pad's latitude), and
otherwise clamps to the window's nearer edge and logs a range-safety event:

| range | window | reaches |
|---|---|---|
| Eastern Range (KSC, the Cape) | 35°–120° | 28.5° to about 57°; no polar orbits |
| Western Range (Vandenberg) | 147°–201° | polar and sun-synchronous, south over the Pacific |
| Baikonur | 29.4°–63.3° | 51.6° to 70°, the drop zones' limits |

Starbase has no window here.

At the first ascent cycle the plane through the pad on that azimuth is fixed
inertially: an instantaneous launch window. Guidance then flies it in two parts.

- **In the air**, it holds the relative azimuth a flown ascent rolls to: circular
  speed along the plane less the ground's own velocity. The gravity turn stays in the
  plane of the air-relative velocity and doesn't chase the plane through thick air.
- **Out of the air**, the plane is re-aimed through the vessel's position at the same
  inclination. The air phase leaves it about 30 km off the liftoff plane, and moving
  the node is cheaper than flying back. A cross-plane acceleration
  `−6y/T² − 4ẏ/T`, the vertical channel's law on its side, then nulls the distance
  off the plane and its rate together at burnout.

The four shared launches reach 51.61° (Shuttle), 32.50° (Saturn V), 28.61° (Falcon 9)
and 28.50° (Starship from Starbase at 26.0°). `tools/sharedflightcheck.gd` holds each
to its target within 0.2°, and `flightphysicscheck` checks the windows.

`missioncheck`'s `orbiter_home` still launches to 28.5°, as every Shuttle flight
did before this. From the vehicle's 51.6° the first deorbit opportunity is 370 km
off the pad's track, and entry guidance holds its first bank to Mach 15 (903 km to
go), then over-brakes past 3 g. Entry from `orbiter_return`'s 51.6° base lands, so
the fault is in how entry guidance handles that crossrange, not in the orbit.

## Lagrange points and halo orbits

`Lagrange` (`sim/flight/lagrange.gd`) finds L1–L5 for a pair at its instantaneous
separation and orbit plane. The collinear points come from Newton's method on the
CR3BP quintics; L4 and L5 sit at ±60°. Sun–Earth L2 lies 1 507 700 km beyond Earth,
and Earth–Moon L1 is 326 381 km from Earth.

Halo orbits about L1 and L2 start from Richardson's (1980) third-order solution. A
symmetric differential correction in the CR3BP (holding x₀, varying z₀ and ẏ₀ until
ẋ = ż = 0 at the y = 0 crossing) then makes them periodic. A JWST-sized Sun–Earth L2
halo (500 000 km out of plane) has a 179.5 d period. A small Earth–Moon L2 halo
(15 000 km) has 14.8 d. Below about 15 000 km the Earth–Moon start does not converge,
since the third-order expansion is poor there.

The space map draws the five points of the Sun–Earth and Earth–Moon pairs once the
pair is resolved on screen, and dashes each L2 halo, solved once on a worker thread.
Right-clicking a point targets it. The flight panel's downrange row then shows the
vessel's distance and speed relative to the point, which moves with the pair's
rotating frame. No mission leg yet plans a transfer or a halo insertion, so a
Lagrange point is a navigation target, not a destination.

## Aerocapture and aerobraking

An interplanetary arrival at a body with air uses that air instead of a capture burn.

### Aerocapture

A vehicle with a heat shield (`limits.heatLoad > 0`, not winged) plans an aerocapture.
The arrival trim aims a periapsis inside the air, the vessel flies the pass heat
shield first (retrograde), and a burn at the following apoapsis makes the orbit
circular there.

- **Predictor.** `Orbit.aero_pass` flies one pass: two-body gravity plus the parent's
  zonal field, drag on the ballistic coefficient m/(C_D·A) with the blunt-body C_D
  `Vessel` uses heat shield first, and air turning with the planet. Mars's J2 moves
  the periapsis by kilometres over the inbound arc, and the corridor is that narrow.
- **Search.** `Mission.aero_periapsis` bisects on the conic periapsis. Each trial
  turns the velocity at the vessel's present position in its own plane, as the trim
  does (`Mission.aimed_velocity`), and flies the predictor from there to the pass's
  apoapsis. It is re-solved at each trim, and the trim's tolerance tightens to 1 km.
- **Checked.** A Starship ship arriving at Mars at v∞ 3 km/s aims a 25 km conic
  periapsis. The predictor then gives a 494 km apoapsis and the vessel's own
  integration (every force `accel()` has) 500 km, for 500 asked.

### Aerobraking

A vehicle with no heat shield captures onto a long ellipse (12 parking radii) and
aerobrakes, as Magellan, Mars Global Surveyor and MRO did. A walk-in burn at apoapsis
lowers the periapsis to where the pass peaks at 0.4 Pa of dynamic pressure
(`Mission.aerobrake_periapsis`); MRO's passes ran at 0.3–0.5. After each pass, if the
periapsis has drifted more than 1.5 km from that, a walk burn at apoapsis corrects it.
Once the apoapsis is within 15% of the parking radius, a burn there raises the
periapsis out of the air.

The route's duration comes from the exponential-atmosphere pass,
Δv = ρ_p v_p √(2π r_p H)/β, in closed form. It is within 17% of a flown pass, which
also sees the air turning. At Mars the ion cruiser walks in at 119 km and takes
about 4.8 km off a 10 000 km apoapsis per pass.

Mars's drag now continues above its 125 km `top` to an `exo` of 250 km, so the upper
passes see air. Its descent scenarios start at 125 km and are unchanged. Neither leg
is flown by a mission check: no check sends a vehicle between planets by default
(missioncheck's Mars case is `long=1` only). The predictor, the search and the
passes are checked in `flightphysicscheck`.
