# Astrarium

*A relativistic orrery.*

An interactive space simulator built with Three.js. It started as a single-prompt
black-hole renderer (gravitational lensing, accretion disc, spacetime mesh) and has
grown into a small N-body sandbox with real orbital mechanics and a set of
ready-made astrophysical scenarios.

![A 10 M☉ black hole: the accretion disc lensed over the top of the shadow and
back under it, the photon ring at the rim, a companion star visible through the
lensing, and the spacetime well dimpling the mesh below.](docs/preview.png)

## Physics

Everything runs in **astronomical units**: length in AU, mass in solar masses (M☉),
time in years. In these units the gravitational constant is exactly **G = 4π²** and
the speed of light is ≈ 63 241 AU/yr — so a body at 1 AU around a 1 M☉ star orbits in
exactly one year, with no fudge factors.

- **Full pairwise N-body gravity**, integrated with **velocity-Verlet** (symplectic —
  conserves energy far better than the old semi-implicit Euler).
- **Black holes** attract via the **Paczyński–Wiita pseudo-potential**, which
  reproduces the correct ISCO at 3·r_s and the relativistic plunge.
- **Compact binaries** (BH–BH, NS–NS) lose orbital energy to **gravitational waves**
  via the leading-order (2.5-PN) radiation-reaction term, so they genuinely inspiral
  and merge with the right chirp shape. (The inspiral *rate* is exaggerated in the
  merger presets so it's watchable; the morphology is real.)
- Neutron stars follow a mass–radius relation (heavier ⇒ smaller, floored near the
  ~10 km limit); main-sequence stars use R ∝ M^0.8.

### What holds a body up

`sim/structure.js` answers a different question from the rest of the physics: not where
a body is, but what it *is* — what is supporting it against its own gravity, how big
that makes it, what is inside it, and at what point the support fails. Everything the
Object Foundry does is derived from it, and none of the outcomes below are scripted;
they are all consequences of the same competition between pressure and gravity.

- **Solid planets** follow the scaled mass–radius law of
  [Seager et al. (2007)](https://arxiv.org/abs/0707.2895) — every composition collapses
  onto one curve, because the equations of state are all well fitted by a modified
  polytrope. Fed the Earth-like coefficients it returns 0.97 R⊕ at 1 M⊕. Differentiate
  it and the curve **turns over at about 300 M⊕**: past roughly one Jupiter mass,
  electron degeneracy stiffens faster than gravity loads the planet, and adding rock
  makes it *smaller*. There is a largest possible rocky planet, and it is ~3 R⊕.
- **Ignition thresholds** are where the identity changes: deuterium at 13 M_J,
  hydrogen at 0.075 M☉. Drag a planet's mass past either and it stops being one.
- **Degenerate stars** shrink as they gain mass. White dwarfs use the Nauenberg (1972)
  form of R ∝ M^−⅓ carried to the Chandrasekhar mass, which returns 0.0084 R☉ at
  1.02 M☉ — Sirius B, measured at 0.0084 R☉. Past 1.44 M☉ there is no equilibrium and
  it detonates as a Type Ia.
- **Neutron stars** collapse past the **TOV limit** (~2.2 M☉ at rest), and rigid
  rotation raises that by up to 20% because centrifugal support is real support. Feed
  one in the sim and you can watch the moment it gives up.
- **Massive stars** run into their own light. `L/L_Edd` rises with mass; above the
  Humphreys–Davidson limit no stable supergiant is observed; between **140 and 260 M☉**
  the **pair instability** disassembles the star completely, leaving no remnant at all;
  above that it collapses directly to a black hole without exploding.
- **Evolution** moves along a track rather than sitting on the main sequence. The core
  hydrogen fraction falls, the mean molecular weight rises, and the star brightens and
  swells — calibrated on the solar track, so the ZAMS Sun really is 0.70 L☉ and 0.90 R☉
  and today's is exactly 1.00. Past the main sequence it becomes a subgiant, then a red
  giant with a degenerate helium core, and — if it is heavy enough — an onion of burning
  shells around an inert iron core. Above ~40 M☉ it goes the other way: its own wind
  strips the envelope and it ends as a hot, small **Wolf–Rayet** star.

### Rotation, shape and gravity darkening

Spin is stored as one dimensionless number: Ω/Ω_crit, the fraction of the rate at which
the body's own equator would be in orbit. That single number sets the shape and the
surface temperature map, and both are checked against measurements.

- **Planets** use the **Darwin–Radau** relation, which ties flattening to the measured
  moment-of-inertia factor. It returns Earth's flattening as 1/300 against a measured
  1/298.25, and Jupiter's as 0.0652 against 0.0649.
- **Stars** use the **Roche model**, exact in the centrally-condensed limit, which
  carries one famous consequence: at break-up, **R_equator/R_pole = 3/2 exactly**, for
  any star. Nothing that stays in one piece can be flatter, which is why the spin
  control has a principled hard stop rather than an arbitrary one.
- **Gravity darkening** (von Zeipel 1924) follows: flux tracks effective gravity, so
  T_eff ∝ g^β, with β = ¼ for a radiative envelope and ≈ 0.08 for a convective one
  (Lucy 1967). The equator of a fast rotator is further out *and* centrifugally
  supported, so it is cooler and dimmer than the poles.

Vega is the test case, and it is a strong one. Its measured 236 km/s equatorial velocity
predicts an equator-to-pole radius ratio of **1.192** against **1.193** observed, and a
**10 260 K** pole over an **8 610 K** equator against **10 070 / 8 910** measured — with
no free parameters anywhere in between.

> Visual sizes of compact objects and horizons are exaggerated so they're not
> sub-pixel — a true-to-scale stellar black hole or planet would be invisible next to
> its orbit. Orbital *distances* and dynamics are always real.

### True scale

The **Sizes** toggle switches every body between that exaggerated stand-in and its real
geometric radius. The Solar System preset starts in true scale, and there the bodies are
built from measured radii: Earth is 4.26 × 10⁻⁵ AU across in a 1 AU orbit, a ratio of
1 : 23 000, so from a camera that fits Neptune on screen it covers about a thousandth of
a pixel.

What makes that usable rather than an empty screen is the same thing that makes a real
telescope usable. Below its resolution limit a body stops being a disc and becomes a
**point source**: its apparent size stops shrinking — pinned at the instrument's
point-spread function — while its brightness keeps falling as 1/r². So each body is drawn
at its true size and, once that drops under a few pixels, cross-fades into a fixed-pixel
glow with the correct colour and temperature. Fly toward one and the marker fades back out
as the real sphere resolves. The geometry is never falsified; only the visibility floor is.

This means a planet at true scale really is indistinguishable from a background star, which
is honest and also inconvenient — so the **Bodies** list is the reliable way to travel. Pick
one and the camera flies to it; its marker also gains a selection reticle so you can see
where it is. Clicking in the viewport still works down to the marker's own footprint, and
stops working below that, which is roughly where aiming at it stopped being possible anyway.

Two numerical hazards come with a 10⁷ dynamic range, and both are handled rather than
tolerated: the camera's near plane tracks its viewing distance (a fixed 0.01 AU near plane
sits *outside* a true-scale Earth, clipping it away entirely), and the follow camera tracks
its target exactly instead of smoothly once the residual is large compared to the viewing
distance — at 6 yr/s Earth crosses most of an AU per frame while the camera sits 3 × 10⁻⁴ AU
from it, and a fractional catch-up never arrives. Depth precision needs no special handling:
a body hands over to its marker about an order of magnitude before the depth buffer could
degrade below the body's own size. The derivation is in [sim/scale.js](sim/scale.js).

## Trisolaris

A full model of the *Three-Body Problem* system: three suns, one world, and a climate
that tries to kill it.

**The system is a hierarchy**, because that is the only arrangement in which a
multiple-star system with a planet actually survives:

| body                 | mass     | class     | role                                                    |
| -------------------- | -------- | --------- | ------------------------------------------------------- |
| **Alpha**      | 1.20 M☉ | F, 6576 K | inner binary, with Beta — 0.35 AU apart, 53-day period |
| **Beta**       | 0.85 M☉ | K, 5236 K | inner binary, with Alpha                                |
| **Gamma**      | 2.00 M☉ | A, 9451 K | wide 25°-inclined orbit, 22 AU, ~51-year period        |
| **Trisolaris** | 1 M⊕    | —        | circumbinary orbit at 1.80 AU, e = 0.42                 |

The planet's orbit sits well outside the Holman–Wiegert circumbinary stability limit
(a_crit ≈ 2.3 a_bin ≈ 0.8 AU). **Verified by direct integration: stable for 60 000+
simulated years** with a relative energy drift of ~1e-7 — several hours of continuous
watching before anything drifts. Closer-in variants of Gamma's orbit were tested and
did disintegrate (at 22 AU it survives; at 14 AU the planet is ejected after ~1900 yr).

Three additional stable architectures are available in the Trisolaris scenario group:

| scenario | architecture | defining scales |
| -------- | ------------ | --------------- |
| **Compact Haven** | tighter circumbinary hierarchy | binary 0.24 AU, world 1.35 AU, Gamma 15 AU |
| **Wide Seasons** | wide circumbinary hierarchy | binary 0.55 AU, world 2.60 AU, Gamma 36 AU |
| **Alpha's Refuge** | S-type nested hierarchy | world around Alpha at 0.80 AU, Beta 6.5 AU, Gamma 52 AU |

All four deterministic architectures complete the 60 000-year headless stability check;
the first three are P-type circumbinary worlds and Alpha's Refuge is the S-type
counterexample. The numerical check uses the same browser-loaded physics module as the
visual simulation:

```bash
cd desktop
ASTRARIUM_STABILITY=1 ./node_modules/.bin/electron .
```

In these four the chaos therefore lives in the **climate**, not in the orbits — and
that is real chaos, not a script. (For the version where the *orbits* misbehave too,
see **Wandering Suns** below.) Insolation swings by a factor of ~8 (0.40 → 3.08 S⊕) every
1.7-year orbit, and a zero-dimensional energy-balance model turns that into eras:

```text
C · dT/dt = (1 − α(T)) · S/4 − ε σ T⁴
```

with `α(T)` rising as the world freezes — the **ice-albedo feedback**, the runaway that
can snowball a planet permanently. At the default 12 m ocean mixed layer the world
spends roughly **42% Chaotic-Cold, 38% Stable, 20% Chaotic-Hot**, ranging −18 °C to
+55 °C. Deepen the ocean to 25 m and it is temperate 94% of the time; shallow it to 8 m
and the swings become lethal. That slider is the whole story of the book in one knob.

**Stand on the planet** (`V`, or the *On Trisolaris* button) to see the sky directly:
Rayleigh + Mie single scattering evaluated **separately for each sun**, with Kasten–Young
air mass, so each sun reddens on its own schedule as it sets, casts its own terminator,
and the sky colour is the sum of all three. The suns rise and set because the ground is
turning — the observer rides the planet's real rotation at a latitude you choose.

The scattering integral **saturates** (`1 − exp(−β_e·m)`) rather than growing linearly
with air mass, so the horizon stays pale and bright instead of blowing out, and the sun's
own disc is extinguished through the same air mass — which is what turns it blood red on
the horizon. Output goes through a filmic curve with **eye adaptation**: exposure tracks
the actual horizontal illuminance with a ~1.6 s lag, so a sunrise dazzles briefly and
then settles instead of flash-banging the whole frame.

Because a sunset takes minutes while an era takes centuries, time is logarithmic with
four named regimes — **Sunset · Days · Seasons · Eras**.

### Wandering Suns — the sky the book actually describes

Stability has a cost, and it is paid in the sky. In all four architectures above the
two near suns keep a fixed apparent size and the third sits 20 AU out contributing
0.04 S⊕ — a sun you have to be *told* about. Nobody would build a religion around it.

**Trisolaris — Wandering Suns** is built the other way round, for the view from the
ground. It is a 2+2 hierarchy parked just inside the region where secular evolution
turns chaotic: the world orbits Alpha (0.58 M☉, K5) at 0.34 AU, while Beta (1.25 M☉,
F5) and Gamma (0.78 M☉, K2) form a tight 0.45 AU pair on a wide *e* = 0.50 orbit
inclined 22°, whose periapsis dives to 1.68 AU — five times the world's own orbit.

Every 3.8 years the pair comes back, and each passage delivers an impulsive kick to the
world's orbit. This close to the Mardling–Aarseth stability boundary those kicks are
strong enough to compound chaotically instead of averaging away, so no two returns find
the world where the last one left it. (The 22° inclination is not doing the work — it is
below the ~39.2° Kozai–Lidov critical angle, so there is no eccentricity–inclination
libration here. It simply denies the encounters a shared plane, which keeps the suns
from tracing one repeated line across the sky.) The ratio of the pair's periapsis to the
world's orbit is the whole knob: below ~4 the world is stripped within decades, above ~6
the kicks weaken and the one-sun fraction climbs from 21% back over 70%.

Counting how many suns are near enough to show a real disc (at least a quarter the
width Earth's Sun shows us — a statement about distance, not about how big the sim
draws them):

| suns showing a disc | Wandering Suns | flagship Trisolaris |
| --- | --- | --- |
| none | 3% | 0% |
| one | 21% | 0% |
| two | 44% | **100%** |
| three | 32% | 0% |

Insolation runs **0.64 → 3.68 S⊕** (5th–95th percentile, tailing to 7.8 at the 99th) and
stays in the liquid-water band 91% of the time. How many are above the *horizon* at any
moment is then the world's own 4-day rotation on top of that: near a close approach a
single day carries you through all four skies — a two-sun night, a tri-solar day, a lone
sun, and true darkness — and back.

**On determinism.** A chaotic system's Lyapunov time is of order its orbital period, so
after a few decades this scenario's trajectory is set by floating-point rounding rather
than by its initial conditions. Your run will not match those numbers shot for shot and
cannot; every figure above is pooled over a **24-run ensemble** (75 203 samples) at the
preset's own step cap, differing only in starting phase — which is the only kind of claim
that means anything about a system like this. On that ensemble the world lives a median
of **382 years** (shortest 92, longest 3437) and always ends: 14 runs ejected it into the
dark, the other 10 fed it to a star's Roche limit. It is *supposed* to end. Worst-case
relative energy drift across those runs is 5.3e-4.

This one also fixes a quiet distortion. A body used to be destroyed on contact with its
**drawn** radius, and these stars are drawn several times oversize — at the flagship
preset's scale a star reached ~9× further out than its real photosphere, silently
deciding which close passes a world walks away from. A preset can now give a real
destruction distance in AU; this one uses the **Roche limit**, `d = 2.44 R★ (ρ★/ρ)^⅓`,
the distance at which a rocky world is pulled apart before it ever reaches the surface.

Finally there is **Trisolaris — Chaotic Era**: the same three suns with *no* hierarchy at
all, a genuine chaotic three-body system. The planet is thrown around and usually ejected
or consumed within a few centuries. That is the honest limit of the idea, and it is why
the Trisolarans want to leave.

## Spaceflight

A rocket is a different kind of object from everything else in this sim, and it
gets a different treatment: its own integrator, its own units, its own render
pass and its own instrument panel. Pick a vehicle from the **Spaceflight**
section and it is built on the pad, in the local morning, at its real size.

Everything below is in `sim/flight/`; the numbers and their sources are in
[docs/spaceflight-research.md](docs/spaceflight-research.md).

### The vehicles are the real ones

Published stage masses, engines and specific impulses — nothing tuned for
playability. A stage's Δv is **computed** from its own dry and propellant mass
through the rocket equation, so if a vehicle cannot reach orbit here, it could
not reach orbit.

| vehicle | gross | liftoff thrust | pad TWR | ideal Δv |
| --- | --- | --- | --- | --- |
| **Saturn V / Apollo** | 2 862 t | 33.6 MN | 1.20 | 16.7 km/s |
| **Falcon 9 Block 5** | 564 t | 7.6 MN | 1.37 | 9.7 km/s |
| **Space Shuttle** | 2 031 t | 30.8 MN | 1.55 | 11.0 km/s |
| **Starship / Super Heavy** | 4 995 t | 74.4 MN | 1.52 | 11.6 km/s |
| **Apollo LM** | 15.2 t | 45 kN | 1.86 (lunar) | 4.7 km/s |
| **Mars sky crane** | 2.8 t | 24.5 kN | — | 0.36 km/s |
| **Ion cruiser** (Dawn-class) | 1.2 t | **0.24 N** | — | 18.5 km/s |
| **Hail Mary** | 2 100 t | photon drive | — | rapidity 3.05 |

The details that matter are in there too, because they change how the thing
flies: a solid rocket booster's thrust **drops by a third** through the middle
of its burn (that is what the star-shaped grain is for, and it is what holds the
Shuttle stack under its limits when nothing aboard can throttle); the Apollo
descent engine has a **forbidden throttle band** between 60% and 92.5% that
eroded the valve, so the guidance really does have to sit on one side of it or
the other; a Merlin cannot go below 57%, which is why a Falcon 9 booster cannot
hover and has to land by hoverslam.

### What is actually simulated

- **Thrust** as `ṁ·g₀·Isp(p_a)`, with Isp interpolated between the engine's
  published sea-level and vacuum values. Mass flow is constant at a given
  throttle — the turbopump does not know what the outside pressure is.
- **Atmosphere** to the US Standard tables: a lapse-rate troposphere and
  exponential layers above, accurate to better than 1% below 20 km. Mars, Venus
  and Titan get their own, from their measured surface conditions.
- **Drag** with a transonic Cd curve, not a constant — which is what puts max-Q
  where it belongs. The launchers above fly it at **25–33 kPa around 7–13 km**.
- **Aerodynamic heating** from Sutton–Graves, `q̇ ∝ √ρ · v³`. The cube is the
  whole story of re-entry, and it drives the ablation budget and the plasma
  sheath from the same number.
- **Full n-body gravity** in a frame centred on whichever body the vessel is
  near, so the third-body terms are real rather than added on. Sphere-of-
  influence handovers are computed against each body's **own primary**, which is
  what keeps a vessel in low lunar orbit from being handed back and forth
  between the Earth and the Moon every frame.
- **Four ways to lose the vehicle**, each against a real limit: dynamic
  pressure, axial g, `q·α`, and heat load. None of them are warnings.

### Flying it

The autopilot is a set of **closed loops on the vehicle's own state**, not a
stored trajectory. A heavier rocket flies differently, and one that genuinely
cannot make orbit gives up rather than pretending.

- **Ascent** — vertical rise, a pitch program flown inside an angle-of-attack
  limit set by the airframe's own `q·α`, then a closed loop that holds a climb
  rate until apoapsis reaches its target. The Saturn V's timeline comes out as
  centre-engine shutdown at **143 s**, S-IC staging at **164 s**, orbit at
  **709 s** — against 135 s, 168 s and 703 s as flown.
- **Orbital insertion** steered live rather than as an impulse, because a
  thousand-metre-per-second circularisation is a burn two minutes long and the
  orbit rotates out from under a direction frozen at ignition.
- **Powered descent** on Apollo's own program structure and published gates:
  **P63** braking, **hi-gate** at 2 377 m and 129 m/s, **P64** approach,
  **lo-gate**, **P66** terminal. The lunar module touches down at **2.2 m/s
  vertical and 0.5 m/s lateral after 687 s** — Apollo 11 took 756 s.
- **Propulsive recovery** — an entry burn scheduled by the dynamic pressure it
  exists to prevent, then a hoverslam whose ignition altitude is `v²/2(F/m − g)`
  solved every step, together with how many engines to light. The booster lights
  two Merlins at **1 598 m** and touches down at 3.2 m/s.
- **Entry, descent and landing** — the Mars sequence, on its real gates: guided
  lifting entry at L/D 0.24, supersonic parachute at **Mach 1.70**, backshell
  separation at **1.80 km and 107 m/s**, powered descent, sky crane at 20 m.
- **Transfers** — Hohmann with the launch window computed and waited for. The
  planner reports the departure burn and the heliocentric Δv **separately**,
  because they are not the same number and confusing them is the classic way to
  be 2 km/s wrong.

Flight time is **1:1 with the wall clock** at 1×: one minute of your time is one
minute of the vehicle's, and the warp ladder is the only thing that changes it.

**Time warp** works the way it has to: physics warp while anything is acting,
and an exact two-body propagation on rails above that — with the same interlocks
KSP uses, because on rails the thrust and drag terms are not evaluated at all.
A launch itself runs at 1×, through a real terminal count: T−10, ignition at the
vehicle's own lead — **T−8.9 s** for a Saturn V, T−6.6 for a Shuttle, T−3 for
Falcon 9 and Starship — the engines coming up against the hold-downs, and
release at T−0. Nine seconds of a vehicle straining on the pad is not ceremony;
it is the only part of a launch that changes fast enough to see, and without it
an ascent that really is running in real time still reads as instantaneous.

### The pad

A rocket rising over an empty plain does not look like it is rising: there is
nothing in the frame whose size is known, so there is no parallax to read. So
the complexes are modelled too, at the dimensions of the pads these vehicles
actually flew from — the LC-39A hardstand raised **12.8 m**, the **137 m** flame
trench and its deflector, the **49.4 × 41.1 m** Mobile Launcher, the **115.8 m**
umbilical tower with nine swing arms that retract on ignition because they are
carrying live propellant until then, Falcon 9's strongback, Starship's OLM and
its 146 m catch tower, lightning masts on a catenary, and the sound-suppression
deluge, which exists to stop the acoustic energy reflecting off the deck rather
than to cool anything.

### The model viewer

The vehicles are built at real dimensions from the same numbers the physics
integrates, and in flight you never get to look at them. The viewer is a studio:
neutral ground, a turntable, a three-point light rig carried on the camera so
there is no shadow side, the stack pulled apart along its own axis, and a
**1.75 m figure standing next to it** — because scale is a comparison, and
110 m means nothing until there is a person beside it. Every number in the panel
is derived on the spot: a stage's Δv from its own dry and propellant mass, the
pad TWR from the engines actually fitted.

### Interstellar

The **Hail Mary** is built from the book and the 2026 film: three parallel
astrophage tanks, the pressure vessel forward of them, four beetles in the nose.

Its performance is not asserted, it is derived. The book puts a gram of
astrophage at ~9 × 10¹³ J — which is *mc²* to two figures — so the spin drive
converts fuel completely into light and its exhaust velocity is exactly **c**.
Two thousand tonnes of it on a hundred-tonne ship is a mass ratio of 21, so the
whole mission has **ln 21 = 3.05 of rapidity** to spend. That is *not* enough for
a flip-and-burn crossing of the 11.9 light years to Tau Ceti, which needs 6.03.
It is comfortably enough for accelerate–coast–decelerate, and the planner solves
for the coast rather than assuming it:

> burn to β = 0.909 (γ = 2.39), coast 10.1 ly, turn over —
> **13.9 years of Earth time and 6.6 aboard.**

Thirteen years is what the book says the outbound trip takes.

The cruise runs on the exact constant-proper-acceleration solution rather than
on a relativistic patch over the Newtonian integrator — `v = c·tanh(aτ/c)`,
`t = (c/a)·sinh(aτ/c)`, `d = (c²/a)(cosh(aτ/c) − 1)` — and reproduces the
standard 1 g reference journeys exactly.

And the sky changes, from one boost vector:

- **Aberration** compresses the whole sky into a forward cone,
  `cos θ = (cos θ′ − β)/(1 − β cos θ′)`. It is applied to the ray direction
  *before* the screen-space derivatives are taken, so the crowding is measured
  by the same Jacobian that already measures lensing magnification — no new
  resolution assumption anywhere.
- **Doppler** shifts each star's temperature by `D`, applied at source, because
  `sim/sky.js` colours its stars from a Planck locus and a blackbody at `T` seen
  through `D` *is* a blackbody at `T·D`.
- The **headlight effect** brightens it as `D⁴`. At β = 0.91 the sky ahead is a
  single blazing cone and everything behind is black.

### Two clocks

The vessel carries its own proper time and the coordinate time, and the readout
between them is their accumulated difference:

```
dτ/dt = √(1 − v²/c² − 2Φ/c²)
```

Because the difference is accumulated through `√A − √B = (A − B)/(√A + √B)`, it
never subtracts two nearly-equal numbers, and one expression covers twelve orders
of magnitude. In low orbit it is tens of microseconds a day — the same
calculation, and the same +38.7 µs/day, that GPS has to correct for. At β = 0.91
it is years.

## Real stars

`sim/starcat.js` is a catalogue of measured objects, and the numbers in it are the
measurements rather than what the scaling relations would have predicted. That
distinction matters more than it sounds: feed Betelgeuse's 16.5 M☉ into a
main-sequence radius relation and you get 4.9 R☉, and Betelgeuse is 764. So each entry
also carries the evolutionary phase it is actually in, which is what lets the
cross-section show a red supergiant's shells instead of a scaled-up Sun.

Scenarios built from it:

- **The Stellar Zoo** — ten famous stars at their true relative sizes, from Betelgeuse
  down to Sirius B. That is a range of 90 000 to 1, so most of them are points until you
  fly to one. They start on genuinely circular orbits, computed from the real N-body
  force at t = 0; a ring of unequal masses has no stable mode and will come apart, which
  is the correct answer rather than a bug.
- **Sirius A & B** — the real orbit (a = 7.50 AU, e = 0.59, P = 50.13 yr), an ordinary
  A1 star beside an Earth-sized white dwarf.
- **Vega** — the rapid rotator seen pole-on that was the photometric zero point for a
  century, which is why the calibration was quietly wrong.
- **Achernar** — the flattest known star, at 1.35, against the hard limit of 1.5, and
  close enough to break-up that it is throwing off a disc of its own gas.
- **Betelgeuse** — with Jupiter's and Saturn's orbits drawn to scale beside it, so you
  can see that Jupiter's is the first one that clears the star.
- **Alpha Centauri** — the real nearest system, with the real 80-year orbit.
- **Eta Carinae** — a hundred solar masses hard against its own Eddington limit, with
  the Homunculus it threw off in the 1840s.
- **The Main Sequence, end to end** — eleven stars from 0.1 to 60 M☉, all doing the same
  thing, over a factor of 600 in mass and 400 000 in luminosity.

## Blank Canvas

An empty scene, and the one place where **Spawn puts things down at rest** instead of
into an orbit. Nothing moves until gravity moves it, so whatever happens next is entirely
yours — release two bodies and watch them fall together, or place three and find out what
the three-body problem does to your arrangement. The `Spawn: In orbit / At rest` toggle
works everywhere; the Blank Canvas just defaults to the other setting.

(Nothing in it emits light, so until you spawn a star the scene is lit by a lamp riding
the camera. It is a viewing aid, it is labelled as one, and it switches off the moment
there is a real star to light things.)

## The Object Foundry

An editor with no catalogue of outcomes in it. There are four inputs — mass, spin,
composition, and how much of its life it has burned — and everything shown is derived
from them by the interior model. So one slider produces behaviour nobody wrote:

- Drag a **rocky planet's** mass up and the radius grows, flattens, **stops at ~300 M⊕
  and then falls** — 0.67 R⊕ at 0.3 M⊕, 2.34 at 30, 3.06 at the peak, and back down to
  2.79 at 900. The drawn size follows it, in true scale and in the exaggerated view
  alike. Keep going: at 13 M_J it lights deuterium and the panel stops
  calling it a planet, at 0.075 M☉ it lights hydrogen and it is a star.
- Drag a **star's** mass up and the colour tracks temperature from a 2800 K red dwarf to
  a 45 000 K O star; past 120 M☉ it is a luminous blue variable, from 140 to 260 it is
  destroyed completely by the pair instability, and above that it collapses without
  exploding at all.
- Drag a **neutron star's** mass up and nothing happens — until the TOV mass, where
  everything does. Spin it first and the limit moves.
- Drag **spin** on anything and it visibly deforms along the Roche sequence while its
  equator cools relative to its poles, stopping at the 3/2 mass-shedding limit.
- Drag **life burned** on a star and it walks its evolutionary track, ending — if you
  take it all the way — in a core collapse you watch happen in the scene.

## Editing a body in flight

The Foundry's sliders appear again at the top of the cross-section panel, aimed at the
focused body instead of at a draft — because building an object and changing one are the
same operation here. The mass, spin, composition, age and metallicity of anything already
in the scene can be moved while it orbits: the object is re-derived from the new numbers,
its meshes are rebuilt, and its structural limits are rechecked immediately. What it is
orbiting, where it is and how fast it is moving are untouched.

The editor sits in the left column under the scenario list, and its top edge is
measured rather than fixed: collapse the scenarios and it slides up into the space.

Above the sliders is the body's own **mass–radius curve**, log–log, with the object
drawn on it as a handle you can drag. A slider tells you where you are; it cannot tell
you where the interesting places are, and here that is the whole point — a rocky
planet's radius turns over at ~300 M⊕ and *falls* thereafter, a neutron star's is flat
for a solar mass and then drops off a cliff. On log axes the power laws are straight
lines (R ∝ M^⅓ cold, R ∝ M^−⅓ degenerate, R ∝ M for a horizon) and the kinks between
them are where the physics changes. Dashed lines mark those crossings, red where the
object is destroyed rather than reclassified, and `focus limit` narrows the graph to
the nearest one so a transition takes a whole drag instead of one pixel.

Nothing in the graph knows that 13 M_J is the deuterium limit. It is sampled by calling
the same interior model across the range and marking wherever the *answer* changes
regime, so the lines move when they should: spin a neutron star up and the TOV mark
slides right, because rotation really is support.

Which means the thresholds are live rather than something you can only build up to.
Drag a 2.0 M☉ neutron star's mass and it collapses to a black hole under you at exactly
the TOV mass — spin it up first and it survives further, because centrifugal support is
real support. Push a white dwarf to 1.44 M☉ and it detonates and is gone. Take Earth to
300 M⊕ and watch the radius stop growing at 3.06 R⊕, then to 26 M_J and watch it stop
being a planet. Age the Sun through to core helium burning and it swells into a K giant
with the planets still in orbit around it.

One deliberate loss: changing the mass of a catalogue star discards its *measured*
radius, temperature and luminosity and hands it back to the evolutionary track. Those
numbers described Betelgeuse; a 1 M☉ object is not Betelgeuse, and keeping its 764 R☉
would be the one place in the sim where a measurement outlived the thing it measured.

## Cross-section

Every body can be cut open (`Cross-section & edit` on a focused object): concentric layers
colour-coded by temperature over a log scale spanning 100 K to 10¹⁰ K, labelled with
radii and temperatures, plus the derived quantities and a note per layer on what it is.

The notes are deliberately uneven about confidence, because the *inference* is uneven. A
planet's core radius comes from its moment of inertia and is known to a few percent; a
neutron star's inner core is genuinely unknown and is what the whole TOV question turns
on; and a black hole's interior is not unmeasured but unmeasurABLE — what the diagram
draws there is the coordinate structure of a solution to Einstein's equations, and it
says so. (It is still worth drawing: the horizon, ergosphere, photon sphere and ISCO are
all real, locatable surfaces, and the Kerr ISCO comes out at 2.321 M for a* = 0.9, which
is the textbook value.)

## Painter

The things made of too many pieces to integrate — rings, belts, ejecta — added as **test
particles on real Keplerian orbits**, advanced analytically rather than integrated. For a
particle of negligible mass the two-body solution *is* the exact answer, so this neither
drifts nor needs a step size.

- **Rings** can only exist **inside the Roche limit**, where tides beat self-gravity and
  the material cannot collect into a moon. That is why every ring in the solar system is
  inside its planet's Roche limit and every major moon is outside it — so the painter
  computes the span from the body's own density and refuses when there isn't one.
- **Belts** get **Kirkwood gaps** cleared at the 3:1, 5:2, 7:3 and 2:1 resonances with
  whatever lies outside them, which is what actually carved the ones in our own belt.
- **Ejecta** are optically thin hollow shells, so they **limb-brighten** into a rim, and
  they expand homologously — the one shape that grows without changing shape.

## Features

- **Scenarios:** **Trisolaris** · **Wandering Suns** · **Compact Haven** · **Wide Seasons** ·
  **Alpha's Refuge** · **Trisolaris — Chaotic Era** · **The Stellar Zoo** ·
  **Sirius A & B** · **Vega** · **Achernar** · **Betelgeuse** · **Alpha Centauri** ·
  **Eta Carinae** · **The Main Sequence, end to end** · **Blank Canvas** ·
  Black Hole Sandbox ·
  Solar System (real distances & masses — zoom way out for Pluto) · Three-Body
  figure-eight (an exact choreography solution) · Binary Star · Binary Black Hole
  Merger · Neutron Star Merger (kilonova) · BH Devouring a Star.
- **Stars derived from one number.** Give a star a mass and everything else follows from
  main-sequence scaling relations: luminosity (piecewise M–L), radius, effective
  temperature via Stefan–Boltzmann, and colour from a Planck-locus fit. A 2 M☉ star
  really is bigger, hotter, bluer and ~30× more luminous than a 0.85 M☉ one
  (Gamma puts out ~16 L☉; Beta, ~0.5 L☉).
- **Live stellar activity.** Starspots emerge in mid-latitude activity belts, grow, decay
  and are replaced; **differential rotation** laps the equator past the poles (Ω ∝
  1 − 0.19 sin²lat, as on the Sun); **flares** follow a power-law energy distribution with
  a fast rise and exponential decay, firing more often on cool convective stars than hot
  ones; the biggest events launch expanding **coronal mass ejections**. Flares brighten
  the star, and that extra flux feeds straight into the planet's climate.
- Physically correct **limb darkening** (I(μ)/I(0) = 1 − u(1 − μ)), a chromospheric H-α
  limb, prominence loops standing over erupting regions, and a smooth streamered corona.
- **Granule size from the pressure scale height**, not from taste. A convection cell is
  about as wide as H_p = kT/(μm_H g) at the surface, so the number of cells across a star
  is R/H_p — 2400 for the Sun, under a hundred for Betelgeuse. That is why a red
  supergiant here is a handful of *enormous* cells rather than a scaled-up Sun, which is
  what Schwarzschild (1975) predicted and what the VLTI and ALMA images show.
- **Disc brightness from temperature.** Surface brightness goes as σT⁴, so a 3600 K
  supergiant's disc is 0.15 of the Sun's per unit area and an O star's is 230 times it;
  every star used to be drawn at the same brightness and so came out the same white.
  (What is drawn is the eye's response to that ratio — Stevens' power law, L^⅓ — rather
  than the raw ratio, because the orbit view has no adapted exposure. It is a display
  transform and `sim/structure.js` says so.)
- **Neutron stars** that spin and sweep two lighthouse **pulsar beams**.
- **Procedurally generated planets** — rocky worlds (continents, oceans, ice caps) and
  banded gas giants (zonal bands, storms, optional rings).
- **Accretion:** bodies near a black hole are tidally stripped, shedding a visible
  particle stream and **losing mass** (they shrink) as they feed it.
- **Living worlds** whose surface is generated in-shader from 3D noise (no seam, no polar
  pinch) and driven by the climate model: ice caps advance and retreat with the glaciated
  fraction, seas shrink as they boil off, cloud decks thicken with humidity, and the
  ground glows when it is hot enough to. Lit by every star at once — several terminators
  in several colours crossing one disc.
- **Spaceflight:** real launch vehicles with published stage masses and engines,
  flown by closed-loop guidance — ascent, orbital insertion, transfers, Apollo's
  own descent programs, propulsive booster recovery, Mars EDL, and relativistic
  interstellar cruise with two clocks and an aberrated sky.
- **Camera:** orbit camera, **free-fly mode** (WASD + mouse look), **surface view** from
  the planet's ground (`V`), **flight cameras** while a vessel exists (`C` cycles
  chase / orbit / cockpit / pad), and **click any object to focus and zoom** onto it.
- Gravitational lensing (now up to two black holes), accretion-disc shader with
  Doppler beaming & gravitational redshift, and a deformable spacetime mesh.

## Two doors

Astrarium is two simulators sharing one renderer, and one stacked control column
could not serve both — by the time spaceflight was at the bottom of it, changing
the imaging band meant scrolling past a climate model. So the page opens with a
choice, **Sandbox** or **Spaceflight**, and the switch in the top left changes
mode at any time.

They share the physics and nothing else. **Spaceflight is for flying**: it opens
already on the pad at Earth, at **1:1** — one second per second, with the warp
ladder the only handle on it — and the orrery's own instruments are simply not
there. No scenario list, no interior editor, no painter, no spawner, no body
list, no imaging bands, and above all no time-scale slider. Those are things you
do to a universe you are looking at, and none of them mean anything while you
are holding a vehicle down on a launch mount. Editing happens in the sandbox.

## Running

It's static — serve the folder and open `blackhole_sim.html`:

```bash
node .claude/serve.mjs
# then open http://localhost:8777/blackhole_sim.html
```

Deep-link a scenario with a URL hash, e.g. `blackhole_sim.html#bhmerger`.

### Controls

`drag` look · `scroll` zoom / fly-speed / FOV · `click` focus object · **`V` stand on the
planet** · `F` free cam · `WASD` fly (`Shift` boost, `Q/E` down/up) · `R` reset view ·
`space` pause · `del` remove focused · `1`–`7` imaging band · `H` hide the HUD.

**In flight:** `Z` / `X` full and cut throttle · `shift`+`space` stage ·
`,` / `.` time warp · `C` flight camera · drag orbits the vehicle.

## Layout

- `blackhole_sim.html` / `.css` — shell & UI
- `blackhole_sim.js` — scene, lensing/disc shader, camera, picking, render loop, UI
- `sim/physics.js` — N-body integrator, GR pseudo-potential, GW inspiral, collisions
- `sim/bodies.js` — body visuals (star/neutron/planet shaders, accretion streams)
- `sim/textures.js` — procedural rocky & gas-giant texture generation
- `sim/presets.js` — scenario definitions with real initial conditions
- `sim/stellar.js` — mass → luminosity / radius / temperature / colour, and the
  starspot-flare-CME activity model
- `sim/star_visual.js` — photosphere, corona, prominence and CME rendering
- `sim/world.js` — the climate-driven planet (surface, clouds, atmosphere), multi-sun lit
- `sim/climate.js` — the energy-balance climate model and era classification
- `sim/skyview.js` — surface observer + multi-sun atmospheric scattering pass
- `sim/scale.js` — true-scale rendering: real mass–radius relations and the
  point-source markers that keep a sub-pixel body visible
- `sim/structure.js` — what holds a body up: mass–radius laws, ignition and support
  limits, rotational shape, gravity darkening, and the layer model everything else reads
- `sim/starcat.js` — the catalogue of measured stars and the scenarios built from it
- `sim/foundry.js` — the Object Foundry editor and the live editor
- `sim/masscurve.js` — the draggable mass–radius graph and its model-derived marks
- `sim/crosssection.js` — the labelled interior diagram and its temperature ramp
- `sim/painter.js` — rings, belts and ejecta as analytically-advanced test particles
- `sim/flight/` — spaceflight: SI-unit vehicle physics, the vehicle catalogue,
  two-body mechanics and on-rails propagation, the autopilot, relativistic
  cruise, procedural spacecraft, exhaust and plasma effects, the metre-scale
  local render pass, and the instrument panel

## Disclaimer

For education and play. The orbital dynamics, stellar scaling relations and the climate
model are real. Compact-object sizes, horizon radii and merger timescales are deliberately
exaggerated for visibility — and so are **stellar radii in the surface view**: the suns of
Trisolaris are drawn about 10× their true angular size (a real one would subtend ~0.3°),
because a physically-sized sun is a bright dot and the point of that view is the sky.

The spacecraft are the exception to the exaggeration: they are modelled at their
real dimensions and drawn in their own metre-scale pass, because at AU scale a
rocket is 7 × 10⁻¹⁰ of a scene unit and no single projection covers both. The
one piece of genuine science fiction is the Hail Mary's astrophage, which is the
book's, and even there the drive is treated as the photon rocket the book's own
energy density implies.
