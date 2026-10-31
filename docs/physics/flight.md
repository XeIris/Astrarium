# Flight frames and cruise

Local flight uses metres and seconds in an accelerating frame centred on the
parent body. The parent's gravity is unchanged; other bodies contribute the
difference between their pull at the vessel and at the parent:

`a = Σ GMᵢ (Rᵢ−Rᵥ)/|Rᵢ−Rᵥ|³ − Σᵢ≠parent GMᵢ (Rᵢ−Rₚ)/|Rᵢ−Rₚ|³`.

This avoids treating the Sun's acceleration of the entire Earth system as an
extra local fall acceleration. The world advances before each vessel substep, so
an RK4 stage reads each body's offset from the parent by cubic Hermite
interpolation between the two snapshots, at the stage's own time, and the
vessel's mass at the first stage's flow. Reading the end-of-step positions put a
first-order error into the tidal term (1.8 km over two days past the Moon at
60 s steps, against 2e-5 m interpolated; `tools/flightphysicscheck.gd`). The
rails kicks read the same snapshots at their two ends.

## The parent's figure

Earth, Mars, the Moon and Jupiter add zonal harmonics J2–J4 about their spin poles
(`Rocketry.ZONAL`: EGM2008, MRO120D, LP150Q, and Juno's field of Iess et al. 2018 at
71 492 km), as −∇ of
Φ = (μ/r) Σ Jₙ (R/r)ⁿ Pₙ(sin φ). This gives nodal regression (the ISS's −5.0°/day,
reproduced to 0.1%), sun-synchronous orbits and apsidal drift.

The rest of the field is in `Rocketry.TESSERAL`, fully normalized and evaluated in
the body-fixed frame (`Rocketry.tesseral_accel`, the Holmes & Featherstone
recursion with the spherical gradient of Vallado §8.7). It covers every m ≥ 1 term
and the zonals past J4:

- Earth: EGM2008's C̄21, S̄21, C̄22 and S̄22 (Pavlis et al. 2012), about 1.2 × 10⁻⁴ m/s²
  at 400 km.
- the Moon: the GRAIL field GL0420A (Konopliv et al. 2013) to degree 16, from the
  PDS Geosciences Node. `tools/build_lunar_gravity.py` writes
  `sim/flight/lunar_gravity.gd` from the first 64 KB of `jggrx_0420a_sha.tab`. Its
  C̄22 is as large as J2's share, and the mascons give up to 195 mGal at 100 km.
  The zonal table's J2–J4 are derived from the same field. Degree 16 resolves
  features of about 340 km: the large basins, not the full mascon spectrum.
  Degree 16 costs 153 terms per evaluation; a degree-660 field would be roughly
  2000 times slower per RK4 stage in GDScript.

`Vessel.body_angle` turns the field with the body. A world under a launch site
keeps that site's longitudes, as the drawn ground does. A tidally locked moon
(`tidalLock` in its spec) keeps its long axis, the principal axis of the GRAIL
frame, on its primary; physical librations of ±7° are left out. Any other body
turns at its sidereal rate from coordinate time zero, so its field's longitudes are
not tied to a map. Mars keeps only its zonals. `flightphysicscheck` checks the
normalized Legendre values against closed forms, the acceleration against −∇ of the
potential, and that turning the body turns the field.

Two-body elements under J2 are biased: at 28.5° a circular 200 km orbit reads
13 km eccentric. Telemetry, and through it guidance, computes its conic with the
orbit-averaged μ_eff = μ[1 + 3/2·J2·(R/r)²(1 − 3/2·sin²i)]
(`Rocketry.effective_mu`). The short-period terms remain: over the half-orbit
coast from a 112 km cutoff to apoapsis they carry the osculating apoapsis by up to
6 km. The ascent therefore cuts off on the coast's flown peak: near the target,
guidance propagates the coast under J2–J4 (`Orbit.zonal_extremes`, RK4 at 5 s) once
a simulated second and adds the peak's offset from the conic apoapsis.

Near orbital speed an apsis moves kilometres per frame, so a cutoff at a frame edge
overshoots. Guidance commands a cutoff time instead (`Vessel.cutoff_in`), from the
apoapsis's measured rate for the ascent and from the Δv still needed over thrust
per mass for the insertion. The integrator ends the thrust inside the substep at
that time; a cutoff commanded during a substep splits it. The four shared launches
now reach their targets within 0.3 km, and `tools/sharedflightcheck.gd` holds the
highest altitude flown over the next revolution to the target ±3 km.

### The surface

Earth's surface is the WGS-84 ellipsoid (`Rocketry.FIGURES`: a = 6 378 137 m,
f = 1/298.257 223 563, NIMA TR8350.2), scaled with the body's mean radius so an
edited Earth keeps its shape. Every other body is a sphere of its mean radius.

- `Rocketry.surface_radius(env, r)` is the centre-to-surface distance along r,
  a·b/√(b²cos²ψ + a²sin²ψ) at geocentric latitude ψ. Altitude is |r| minus it, which
  differs from height along the ellipsoid's normal by under a metre below 1000 km.
  Air density, Mach, heating, winds, ground contact, gear, wheels, falls at rest,
  splashdown, the clock's ground reference and the aerocapture predictor
  (`Orbit.aero_pass`'s `fig`) all read it.
- A pad's latitude is geodetic: `Rocketry.geodetic_point` puts KSC 39A
  (28.6084° N) at geocentric 28.4469°, 6373.3 km from the centre, 2.3 km above the
  old mean sphere. The vehicle stands along the radius, 0.16° from the ellipsoid's
  normal there; the deflection of the vertical is not modelled.
- Landing sites, the catch tower, the runway and the LM's gates sit on the surface
  under them. Orbit targets stay radii over the mean sphere (`Mission.park_radius`,
  apsis altitudes in telemetry), so a circular 300 km orbit at 51.6° reads 293–307 km
  of altitude as it crosses the bulge, as a real one does. A built circular orbit
  (`Vessel.place_in_orbit`) starts at its stated altitude over the ground under it.
- The local scene draws the ground, haze, sky dome and clouds on the sphere of the
  surface radius under the eye (`surfaceR`), and sets the launch complex on that
  sphere. Off the parallel the ellipsoid departs from it by up to 2.8 m per km, which
  only a complex tens of kilometres away would show. The ground map's geography is
  laid out by geodetic latitude, as the map is.

`flightphysicscheck` holds a and b, the pad's geocentric latitude and height, and a
fall at the pole meeting the polar radius. The built Earth scenario bases were
re-recorded from their replays ([flight scenarios](../flight-scenarios.md)).

## Radiation pressure and the solar sail

A stage carrying a `sail` (area, specular reflectivity ρ) feels each star's light,
P = L/(4πd²c): on a flat sail at incidence α, F = P·A·cos α·[(1 − ρ)û + 2ρ cos α n̂],
the absorbed part along the light û and the reflected part along the sail's normal,
away from the lit side (`Vessel._radiation`; diffuse reflection and the sail's
billow are not modelled). Nothing pushes inside the parent's cylindrical shadow. The
Solar Sail is NASA's Solar Cruiser design: 1653 m² of aluminised polyimide, ρ = 0.91,
about 100 kg, a characteristic acceleration of 0.14 mm/s² at 1 AU. Ordinary craft
feel no radiation pressure; for them it would be ~10⁻⁸ m/s². `flightphysicscheck`
holds the push face on, at 35°, edge on and in Earth's shadow, and a sail held to the
Sun on a circular orbit at the reduced gravity μ(1 − β), which stays at 1 AU.

## Δv accounting

While thrusting, `Vessel.sample` integrates the ideal Δv ∫T/m dt and what gravity
(∫g·v̂ dt), steering (∫T/m·(1 − cos β) dt, β between thrust and velocity) and drag
(∫D/m dt) took from it, in the parent's inertial frame. The flight panel shows the
three losses; for a burn in vacuum Δ|v| = ideal − gravity − steering, which
`flightphysicscheck` holds to 0.2%.

## Propellant boil-off and slosh

A cryogenic stage that is not firing boils its propellant off the pad at
ṁ = q″·A/h_fg (`Vessel.boil_off`), vented without thrust. Each tank's wetted area is
its share of 85% of the stage's barrel by the volumes the mixture ratio and the
densities give; latent heats are NIST's at the normal boiling point (LH₂ 445.6,
CH₄ 510.8, LOX 213.1 kJ/kg). The heat leak q″ = 2 W/m² is an order-of-magnitude
estimate for spray-on foam in orbit, not a measured value for any stage: no
published vent rate for the S-IVB or Starship was found. At that rate the S-IVB
boils 6.5 kg an hour.

Slosh is a readout: the first lateral mode of the lowest tank, a cylinder of radius
R filled to h, ω² = (ξa/R)·tanh(ξh/R) with ξ = 1.841 (Abramson, NASA SP-106), and
the free surface's tilt under the lateral acceleration. With no settling
acceleration the propellant is unsettled and no mode is reported. Slosh does not act
on the attitude.

## Heat-shield ablation

A charring ablator (`heatShield.ablator` with `thickness`, `rho` and `qstar`)
rejects its hot char's radiation, εσT⁴ with ε = 0.85 at 1500 K (0.24 MW/m²), and the
rest of the stagnation flux recedes it at ṡ = q_net/(ρ·Q*) (`Vessel._ablate`). The
recession is the stagnation point's, the deepest; the mass shed is the shield's area
times it, an upper bound. A shield receded through its thickness is a burn-through.
The Mars aeroshell carries MSL's 31.75 mm of PICA (ρ 265 kg/m³; Edquist et al. 2014)
with Q* = 50 MJ/kg, an estimate for a charring ablator at ~1 MW/m². Reusable tiles
(the orbiter, Starship) do not recede; the heat-load limits still apply to them.

## Air

### The thermosphere

Settings › Sim › Solar activity (`f107=` on the command line) sets the 10.7 cm solar
flux. At its default, the left end, Earth's air above 86 km is US76's table: a
thermosphere of moderate activity with an exospheric temperature of 1000 K, which
every built flight assumes. With a flux set, the air above 120 km is the Bates
profile `T = T∞ − (T∞ − T₁₂₀)·e^(−sζ)` in geopotential ζ, which is US76's own form
above 120 km, with s = 0.01875 km⁻¹. Each species (N₂, O, O₂, Ar, and He with
thermal diffusion α = −0.38) is in diffusive equilibrium from US76's 120 km number
densities, in Walker's (1965) closed form:

    n(ζ) = n₁₂₀ [T₁₂₀/T]^(1 + α + γ) e^(−sγζ),   γ = m g₁₂₀ / (s k T∞)

T∞ follows Jacchia's (1971) night-time `T_c = 379 + 3.24 F10.7`, scaled so that
F10.7 = 150 gives US76's 1000 K. At 150, density follows the US76 table to within
18% from 200 to 600 km; the table's extra O and H fluxes make up the difference.
At 400 km, density spans 18× from F10.7 = 70 to 250. NRLMSISE-00 gives roughly
10–20× over a solar cycle there; its geomagnetic, diurnal, seasonal and latitude
terms are not modelled. Drag continues up to `exo` and kicks the rails, so low
orbits decay at the rate the setting implies. `flightphysicscheck` flies a 400 km
orbit on rails for two days at three activities. The extra decay scales with the
density differences to within 3%, and an active Sun takes ~230 m more than a quiet
one for the ion cruiser.

Shock-layer radiation adds to the Sutton–Graves convective flux
(`Rocketry.radiative_heat_flux`, Tauber & Sutton 1991): zero below about 9 km/s
in air and 6 km/s in CO₂, and dominant on lunar return. Its f(V) tables are the
commonly reproduced ones, not checked against the original paper here.

A launcher stage may carry a `cdTable` (`{source, rows: [[Mach, Cd], ...]}`) that
replaces the generic Cd(Mach) curve while it is the lowest stage attached, and a
`cdBase` that replaces the blunt-body curve while it falls base first. Tables are
held beyond their ends.

- The Saturn V's S-IC carries the total aerodynamic axial-force coefficient of the
  S-IC flight configuration, F-1s firing, from Boeing D5-15481-1 (the AS-504 launch
  vehicle reference trajectory, fig. 3-2), on the 10.06 m diameter. It was
  digitized from the scanned plot against its local gridlines (the scan is rotated
  about 1.4°), to ±0.01 above Mach 0.4 and ±0.03 below. It peaks at 0.81 near Mach
  1.2 and turns negative above Mach 7, where the plume fills the base. The S-II and
  its aft interstage carry the same figure's S-II curve, 0.28 at Mach 5 to 0.23 at
  Mach 8. The figure's liftoff term (56.5 kN for 4 s) is left out.
- The Falcon 9 first stage's `cdBase` is the total drag of DLR's RFZ model, a
  Falcon 9 first stage returning base first with engines off (Bykerk & Horchler
  2024, AFMC2024-35, table 2, RANS): 1.01 at Mach 0.75 rising to 1.73 at Mach 1.45,
  on 10.52 m². No published ascent Cd(Mach) for Falcon 9 was found, so its ascent
  keeps the generic curve.

Climatological winds (`Rocketry.WINDS`, Settings › Sim or `winds=1`, off by
default) give Earth a zonal-mean circulation: ±6 m/s trades and westerlies, a
1/7-power boundary layer, and a 35 m/s jet near 12 km at 35° latitude.
`Vessel.airspeed` includes the wind, so drag, Mach, heating and the aerodynamic
attitude see it. `Vessel.ground_velocity` does not: the wheels, gear and tower
arms, the rollout, the descent law's drift, and the orbiter's heading and range to
the runway use it. The glide's range model stretches each layer of the scheduled
glide by (TAS + w)/TAS for the wind along the ground track, and the touchdown gate
reads air speed (195–215 KEAS) while the rollout reads ground speed. With winds on,
`orbiter_return`, `orbiter_home` and `ship_return` land, and the `shuttle:rollout`
and Starship catch scenarios pass. Winds stay off by default: the scenarios'
built bases (the orbiter at 80 km, 24.4 km and 3990 m; Starship at 80 and 15 km)
were recorded in still air and would have to be re-recorded, and the frozen
numeric reference has no wind. Physics vectors use doubles; flight rendering
uses a second floating origin in the metre-scale viewport. The frame coordinator
converts accepted coordinate seconds to orrery years. Proper-time clocks and
guidance run only over accepted intervals; integrator guards stop both spaces
together. [The flight contract](../../sim/flight/AGENTS.md) describes integration
order, staging, guidance and the required launch checks.

## Orientation

The frame is turned so the parent's north pole is −Y: its equator is the XZ
plane, latitude is `asin(−r̂.y)` and the surface turns with ω = (0, −Ω, 0).
`Rocketry.spin_frame` gives the rotation, world = frame · local, as the shortest
arc from −Y to the pole. Poles are the IAU WGCCRE values at J2000 (Archinal et al.
2018), with the Moon's, Mars's and Neptune's periodic terms summed at J2000 and no
precession. For Earth the shortest arc fixes the equinox on +X, so the local frame
is J2000 equatorial in the orrery's axis convention: a star's RA and Dec are its
longitude and latitude, as a launch site's are. A world without a measured pole
leans by its `obliquity` about +Z, as `RockyVisual` draws it; a star keeps the
ecliptic, against which heliocentric inclinations are read.

Everything the vessel keeps is local. Orrery positions cross through the frame:
gravity and the potential are summed in orrery axes with the vessel's position
turned out and the sum turned back, `Vessel.body_offset` serves sphere tests and
guidance, and `to_world` / `to_local` serve lighting, the cruise line, the space
map, the mission planner's body states and the orrery camera. A rebase between bodies with different poles
turns position, velocity, attitude and the autopilot's held directions into the
new frame (`on_rebase`). With Earth's 23.44° tilt the pad has seasons, a 28.5° N
launch reaches 28.5° to the equator, and the Moon's orbit lies 18.3°–28.6° from
it over the 18.6-year nodal cycle (`tools/spinframecheck.gd`).

Interstellar cruise is a separate one-dimensional, gravity-free model with
constant proper acceleration `a`. Rapidity `φ = aτ/c` gives
`v = c tanh φ`, `γ = cosh φ`, `t = (c/a) sinh φ`, and
`d = (c²/a)(cosh φ−1)`. Burns change rapidity by
`Δφ = (vₑ/c) ln(m₀/m₁)`. The profile solver chooses burn/coast/turnaround
intervals subject to available propellant; these equations do not model
gravitating interstellar trajectories.

Vehicle dimensions, engine counts and thrust are canonical in
`sim/flight/vehicles.gd`. The historical source compilation remains in
[the archived research record](../../web/docs/spaceflight-research.md).
