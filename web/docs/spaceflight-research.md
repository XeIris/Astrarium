# Spaceflight — research notes

Everything the flight model, the vehicle catalogue, the guidance laws and the
effects in `sim/flight/` are built from. Numbers here are the ones actually used
in code; where a number is a *choice* rather than a measurement it says so.

The rule the rest of the repo follows applies here too: **measured beats
modelled**. A vehicle that flew has its published stage masses, thrusts and
specific impulses in `sim/flight/vehicles.js`; only the parts nobody publishes
(structural margins, RCS authority) are modelled.

---

## 1. Prior art — what the good simulators actually do

| sim | what it gets right | what I took |
| --- | --- | --- |
| **Kerbal Space Program** (+ MechJeb, kOS/PEGAS) | the *navball* as the single attitude instrument; maneuver nodes as first-class objects; a stage list that is also the resource display; time warp in named steps | navball, node-execute autopilot, staged Δv readout, warp ladder |
| **Orbiter 2016** | MFD panels — one instrument, many pages; attitude *hold* as a distinct mode from attitude *change*; PID autopilot that doesn't overcorrect at high step | separate "hold" vs "slew" attitude modes, PD controller with rate limiting |
| **Children of a Dead Earth** | everything derived from real engine/propellant numbers rather than tuned | thrust from `ṁ·v_e + A_e(p_e − p_a)`, never a tuned constant |
| **Reentry / Apollo AGC sims** | descent broken into *named programs* with published gate conditions | the lander uses Apollo's own P63/P64/P66 structure and gate numbers |
| **Space Engine / Celestia** | point-source fallback below the resolution limit | already in `sim/scale.js`; the vessel reuses it |

### Time warp — the single most important UX decision

KSP's split is the right one and it is what this implements:

- **Physics warp** (≤ 4× here, ≤ 100× where nothing is loaded): the integrator
  really runs faster. Required whenever thrust or atmosphere is acting, because
  both are functions of the *current* state.
- **On-rails warp** (up to 10⁶×): the vessel is taken off the integrator and
  advanced analytically on its conic. Only legal when unpowered, out of the
  atmosphere and not on the ground. This is exactly why KSP forbids high warp
  under 70 km or with the throttle open, and the same interlocks are here.

The failure mode to avoid is KSP's: *"when the craft transitions a time-warp
boundary the downshift does not happen instantly"*. Here the warp is clamped by
a predicate evaluated **before** the step, and dropping out of rails re-seeds
the integrator from the analytic state, so there is no boundary to cross badly.

Sources: [Time warp (KSP wiki)](https://wiki.kerbalspaceprogram.com/wiki/Time_warp),
[Navball (KSP wiki)](https://wiki.kerbalspaceprogram.com/wiki/Navball),
[MechJeb Ascent Guidance](https://github.com/MuMech/MechJeb2/wiki/Ascent-Guidance),
[PEGAS](https://github.com/Noiredd/PEGAS),
[AttitudeMFD](https://www.orbiterwiki.org/wiki/AttitudeMFD).

---

## 2. Propulsion physics

### Thrust

```
F = ṁ · v_e,vac  +  A_e · (p_e − p_a)          ≡  ṁ · g₀ · Isp(p_a)
Isp(p_a) = Isp_vac − (Isp_vac − Isp_SL) · (p_a / p₀)
```

The linear interpolation in ambient pressure between the published sea-level and
vacuum specific impulses is the standard engineering shortcut and is accurate to
better than a percent for a fixed-geometry bell, because the pressure term is
itself linear in `p_a`. It is *not* an approximation of convenience: `Isp_SL` and
`Isp_vac` are both published for every engine below, so the endpoints are
measured and only the interior is interpolated.

Mass flow is then `ṁ = F_vac / (g₀ · Isp_vac)` and is constant at a given
throttle — the engine does not know what the outside pressure is.

`g₀ = 9.80665 m/s²` exactly (it is a *defined* constant in the Isp definition,
not local gravity).

### Tsiolkovsky

`Δv = Isp · g₀ · ln(m₀/m₁)`, applied per stage. The stage Δv figures in the HUD
are computed, never stored.

### Throttle limits

Real engines cannot throttle to zero. Merlin 1D: 57–100%. RS-25: 67–109%. Apollo
DPS: 10–60% and 92.5–100%, with the band between them forbidden (it eroded the
throttle valve) — this is modelled, and the lander's guidance really does avoid
the dead band.

---

## 3. Atmosphere and aerodynamics

### Density

Exponential atmosphere, `ρ(h) = ρ₀ exp(−h/H)`, is the standard first-order model
and is what the search sources recommend for trajectory work. Earth is given a
**two-layer** fit instead of one, because a single scale height is ~15% wrong at
max-Q altitude, which is precisely where it matters:

| body | ρ₀ (kg/m³) | H (m) | top (km) | note |
| --- | --- | --- | --- | --- |
| Earth | 1.225 | 8500 troposphere → 6000 above 12 km | 140 | max-Q ≈ 11–13 km |
| Mars | 0.020 | 11 100 | 125 | ~0.6% of Earth surface pressure |
| Venus | 65 | 15 900 | 250 | 92 bar at the surface |
| Titan | 5.4 | 21 000 | 600 | denser than Earth's, in 0.14 g |
| Moon / Mercury | 0 | — | — | airless: no chute, no aerobraking |

Surface pressure follows from `p = ρ R T / M`; the sim carries `p₀` directly.

### Drag and dynamic pressure

```
q  = ½ ρ v²                      (Pa)
D  = q · Cd(M) · A               (N)
```

`Cd(M)` is a transonic curve, not a constant — subsonic ≈ 0.30, rising to a peak
≈ 0.75 at M ≈ 1.1, falling to ≈ 0.28 by M ≈ 4. This is what puts **max-Q** where
it belongs (≈ 11–13 km, ≈ 30–35 kPa on a Falcon 9 profile) and it is why the
autopilot throttles down through it.

Speed of sound `a = √(γRT/M)`, with a simple linear lapse-rate temperature
profile, so the Mach number is real rather than assumed.

### Heating

Sutton–Graves stagnation-point convective heating:

```
q̇ = k · √(ρ/R_n) · v³ ,   k = 1.7415e-4 (SI, air)
```

`v³` is the whole story of re-entry: doubling entry speed is eight times the
heat rate. This drives both the heat-shield ablation budget and the plasma-sheath
visual, and it is why the Mars aeroshell needs the atmosphere and the Moon lander
does not have one.

Sources: [Braeunig atmospheric models](http://www.braeunig.us/space/atmmodel.htm),
[Max q](https://grokipedia.com/page/Max_q),
[Gravity turn](https://grokipedia.com/page/Gravity_turn).

---

## 4. The vehicle catalogue

Published numbers. `t` = tonne = 1000 kg.

### Saturn V — the expendable superheavy (Earth → Moon)

| stage | dry | prop | engines | thrust | Isp | burn | size |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S-IC | 137 t | 2077 t | 5 × F-1 | 34.5 MN SL | 263 s SL / 304 vac | 150 s | 42 m × 10 m |
| S-II | 36.2 t | 443 t | 5 × J-2 | 4.4 MN | 421 s vac | 367 s | 24.9 m × 10 m |
| S-IVB | 13.5 t | 109.5 t | 1 × J-2 | 1.033 MN | 421 s vac | 500 s (2 burns) | 17.8 m × 6.6 m |

### Apollo LM — the lander

- Overall 6.99 m tall (22 ft 11 in) with legs deployed; **9.4 m** (31 ft) diagonal
  across the landing gear; ascent stage 3.76 m, descent stage 3.05 m.
- 15 200 kg total (H-series), 10 730 kg of that propellant.
- **DPS**: 45.04 kN max, throttleable 10–60% and 92.5–100%, Isp 311 s.
- **APS**: 15.6 kN fixed, Isp 311 s.

### Falcon 9 Block 5 — the reusable orbital launcher

| stage | dry | prop | engines | thrust | Isp | size |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | 22.2 t | 411 t | 9 × Merlin 1D | 7.6 MN SL / 8.2 vac | 282 SL / 311 vac | 41.2 m × 3.7 m |
| S2 | 4.0 t | 111 t | 1 × MVac | 934 kN | 348 s | 13.8 m × 3.7 m |

### Space Shuttle — the winged one

- ET 46.9 m × 8.4 m, 26.5 t empty, 756 t gross.
- 2 × SRB, 12.5 MN each at liftoff (~83% of liftoff thrust), Isp 242 s SL.
- Orbiter 37.2 m long, 23.8 m span, 68 t empty; 3 × RS-25 at 2.28 MN vac total,
  Isp 366 s SL / 452.3 s vac.

### Super Heavy / Starship — the fully-reusable superheavy

- Booster 71 m × 9 m, 275 t empty, 3400 t propellant, 33 × Raptor 2 = 73.5 MN,
  Isp 327 SL / 347 vac.
- Ship 52 m × 9 m, ~120 t empty, 1200 t propellant, 3 × Raptor SL + 3 × RVac.
- LOX/CH₄ — matters visually: a methalox plume is nearly transparent blue, not
  the orange of RP-1.

### Electric propulsion — the interplanetary cruiser

- **NSTAR** (Deep Space 1, Dawn): 92 mN at 2.1 kW, Isp 1000–3300 s.
- **NEXT**: 25–237 mN over 0.6–6.9 kW, Isp 1400–4190 s.
- **Hall thruster**: exhaust 20–30 km/s, Isp 1500–3000 s, higher thrust density.

The point for gameplay: a NEXT-class ion stage produces **1/40 000 of a
Merlin's thrust** and runs for *months*. It is unusable at 1× and is the reason
the warp ladder has to reach 10⁵–10⁶.

### The *Hail Mary* — the interstellar ship

Design taken from the book and the 2026 film. Layout, front to back:

- Nose **control room** (single pilot seat, monitor wall), then **lab**, then
  **dormitory** (three coffin-like beds, nanny-bot arms, ~3 m tall), then a ~1 m
  **storage** deck.
- Aft: **three parallel cylindrical astrophage tanks**, 2 000 000 kg of fuel,
  with the **spin drives** at their base.
- At the tip, an isolated compartment carrying **four "beetle" probes** — small
  return craft whose only job is to get data back to Earth.
- The film scaled the ship up from the book so the interior is habitable on
  camera; it is deliberately "something today's international space community
  would build" — panelled, utilitarian, white/grey with foil and radiators, not
  a smooth spaceship.

**Its performance is checkable.** Continuous 1.5 g (= 14.7 m/s²) over Tau Ceti's
11.9 ly, accelerating to the midpoint and decelerating after it:

```
c/a = 0.647 yr        a·d_half/c² = 5.95/0.647 = 9.20
τ_leg = (c/a)·arccosh(10.20) = 0.647 × 3.013 = 1.95 yr   → τ_total ≈ 3.9 yr
t_leg = (c/a)·sinh(3.013)   = 0.647 × 10.15 = 6.57 yr   → t_total ≈ 13.1 yr
γ_max = cosh(3.013) = 10.2  →  v_max = 0.995 c
```

3.9 years aboard, 13 years on Earth — which is exactly what the book says the
trip takes. So 1.5 g is the acceleration the story implies, and it is what the
sim's Hail Mary uses.

Sources: [S-IC](https://en.wikipedia.org/wiki/S-IC), [S-II](https://en.wikipedia.org/wiki/S-II),
[S-IVB](https://en.wikipedia.org/wiki/S-IVB), [Braeunig LM specs](http://www.braeunig.us/space/specs/lm.htm),
[Descent propulsion system](https://en.wikipedia.org/wiki/Descent_propulsion_system),
[Falcon 9 Block 5](https://en.wikipedia.org/wiki/Falcon_9_Block_5),
[Shuttle ET](https://science.ksc.nasa.gov/shuttle/technology/sts-newsref/et.html),
[SRB](https://science.ksc.nasa.gov/shuttle/technology/sts-newsref/srb.html),
[Super Heavy](https://en.wikipedia.org/wiki/SpaceX_Super_Heavy),
[NEXT](https://en.wikipedia.org/wiki/NEXT_(ion_thruster)),
[Hail Mary layout](https://projecthailmary.fandom.com/wiki/Hail_Mary),
[LEGO vs film ship](https://www.brickfanatics.com/lego-icons-project-hail-mary-to-movie-ship).

---

## 5. Guidance and autopilot

### Ascent — vertical rise, gravity turn, terminal guidance

The gravity turn is the real thing: after a pitch *kick* of a few degrees the
vehicle flies at **zero angle of attack** and lets gravity rotate the velocity
vector, because any lift generated by flying at an angle is paid for in
structural load and drag.

```
dγ/dt = −(g cos γ)/v + (v cos γ)/(R + h)
```

Implemented in three phases, which is what every real launcher does:

1. **Vertical rise** to clear the tower — until `v ≈ 55–65 m/s`.
2. **Pitch kick** of 2–4°, then **hold prograde** (α = 0) while `q` is
   significant. Throttle is bucketed through max-Q.
3. **Terminal guidance** once `q < 1 kPa`: a linear-tangent steering law
   (`tan θ = A + B·t`), which is the closed-form optimum for flight in a
   uniform field and is the core of Powered Explicit Guidance / UPFG as flown on
   the Shuttle. Coefficients are re-solved every second from the remaining Δv
   and the target orbital energy — that re-solve *is* the "explicit" in PEG.

Then coast to apoapsis and **circularize** with a node burn.

### Node execution

For a burn of Δv with current thrust `F` and mass `m`, the burn time from
Tsiolkovsky is

```
t_burn = (m·g₀·Isp/F)·(1 − exp(−Δv/(g₀·Isp)))
```

The burn is centred on the node — ignition at `T − t_burn/2` — which is the
standard way to keep a finite burn close to the impulsive solution it was
planned as. Cutoff is on **remaining Δv projected onto the node direction**
going negative, not on elapsed time, so a wrong `t_burn` cannot overburn.

### Transfers

Hohmann, computed from the two semi-major axes:

```
Δv₁ = √(μ/r₁)·(√(2r₂/(r₁+r₂)) − 1)
Δv₂ = √(μ/r₂)·(1 − √(2r₁/(r₁+r₂)))
t   = π√((r₁+r₂)³/(8μ))
phase angle at departure  φ = π − 2π·t/T₂
```

Sanity numbers the code must reproduce: Earth→Mars **heliocentric** two-impulse
Δv = 2.945 + 2.649 = **5.594 km/s**, transfer time **259 days**, synodic period
**779.9 d**, departure phase angle **44.3°**. (The 3.6 km/s figure usually quoted
for a Mars departure is the burn *from a 200 km LEO*, which is smaller than the
heliocentric Δv because of the Oberth effect — the sim reports both, and they are
not the same number.) LEO→GEO = 2.455 + 1.477 = **3.93 km/s**. Earth SOI radius
924 Mm, lunar SOI 66 Mm.

Interplanetary flight uses **patched conics** for planning and full n-body for
integration — the planner's answer is a first guess that the integrator then
corrects with a mid-course burn, which is what real missions do.

### Landing

**Airless (Moon-type) — Apollo's own program structure and gate conditions:**

| program | phase | entry conditions | exit |
| --- | --- | --- | --- |
| **P63** | braking | 15.2 km altitude, 1700 m/s horizontal, ~457 km downrange | hi-gate |
| — | hi-gate | **2377 m altitude, 7 km range, −45 m/s vertical, 129 m/s forward** | → P64 |
| **P64** | approach | ~146 s, pitches up so the site is visible through the window | lo-gate |
| — | lo-gate | **~30 m altitude, 11 m range** | → P66 |
| **P66** | terminal | rate-of-descent hold, ~1 m/s at contact | contact light |

P63 is a quartic-polynomial guidance law targeting position, velocity **and**
acceleration at hi-gate; that is what makes the profile look the way it does.

**Propulsive booster recovery (Falcon-type):**

| phase | condition |
| --- | --- |
| stage separation | ~65–70 km |
| boostback | 3 engines, ~30 s, reverses the trajectory (RTLS only) |
| grid fins deploy | ~70 km |
| entry burn | 3 engines, ~70 km → ~40 km |
| landing burn | ignition ~8 km, 1 or 3 engines |
| legs | seconds before touchdown |

The landing burn is a **hoverslam**: the vehicle's minimum throttle gives a
TWR > 1, so it cannot hover, and the only solution is to arrive at zero velocity
at zero altitude simultaneously. The ignition altitude is solved for, not
scripted:

```
h_burn = v² / (2·(F/m − g))
```

evaluated continuously; ignition is when the vehicle's actual altitude reaches
it. That single line is the whole manoeuvre and it is why it looks so tense.

**Atmospheric (Mars-type EDL) —** the seven minutes: entry interface at
~5.8 km/s, peak heating ~870 °C on the shield, supersonic chute at ~Mach 1.7,
heat shield jettison, backshell separation at ~1.8 km / 100 m/s, powered descent
on the descent stage, sky crane lowers the rover on cables from ~20 m, cables cut,
descent stage flies away.

Sources: [Cherry, *A User's Guide to LUMINARY 1A*](https://www.ibiblio.org/apollo/Documents/CherryEyles-UsersGuideToLuminary1A_text.pdf),
[Apollo 11 PDI overview](https://www.linkedin.com/pulse/overview-apollo-11-lunar-landing-from-pdi-touchdown-jacques-oubrier),
[Falcon 9 DPL trajectory](https://zlsadesign.com/infographic/trajectory/spacex-falcon9-booster-dpl/),
[Sky crane](https://en.wikipedia.org/wiki/Sky_crane_(landing_system)),
[How we land on Mars](https://science.nasa.gov/planetary-science/programs/mars-exploration/mission-timeline/how-we-land-on-mars/),
[Hohmann transfer](https://www.omnicalculator.com/physics/hohmann-transfer),
[Earth–Mars transfer](https://marspedia.org/Earth-Mars_Transfer_Trajectory).

### Attitude control

Quaternion error → body rates → torque, with the torque coming from two real
and *different* sources:

- **Engine gimbal**: torque `= F·sin(δ)·L_arm`, available only while thrusting,
  and only in pitch/yaw (roll needs differential gimbal or RCS). Merlin gimbals
  ±5°, F-1 ±5.15°, RS-25 ±10.5°.
- **RCS**: small fixed thrusters, available always, consumes monopropellant,
  gives roll authority. Apollo LM RCS: 16 × 445 N.

The controller is a critically-damped PD on the quaternion error with a rate
limit — the same structure as Orbiter's PID autopilot, which exists precisely
because a naive proportional controller overcorrects.

---

## 6. Relativity

### The exact constant-proper-acceleration solution

With proper acceleration `a` and proper time `τ`:

```
v(τ) = c·tanh(aτ/c)
γ(τ) = cosh(aτ/c)
t(τ) = (c/a)·sinh(aτ/c)
d(τ) = (c²/a)·(cosh(aτ/c) − 1)
```

and the rocket's own mass ratio for a total rapidity `aτ/c`:

```
M/m = exp(aτ/c) − 1      (for the accelerate-only case)
```

Reference journeys at 1 g, one way, flip-and-burn: Proxima (4.24 ly) — 3.6 yr
ship, 5.9 yr Earth. Tau Ceti (11.9 ly) — 4.9 yr ship, 13.8 yr Earth. Andromeda
(2.5 Mly) — 28.6 yr ship, 2.5 Myr Earth. These are the numbers the HUD must
reproduce.

### Two clocks — and why they are interesting even in LEO

`dτ/dt = √(1 − v²/c² − 2GM/(rc²))` combines the velocity and gravitational
terms. This is not only a relativistic-cruise feature: **in LEO it is measurable
and is the reason GPS works**. A GPS satellite runs +45.9 μs/day from the weaker
potential and −7.2 μs/day from its speed, net **+38.7 μs/day** — a real, famous
number the sim reproduces on the same code path that later shows years of
divergence at 0.99 c. One expression, twelve orders of magnitude.

### What relativistic flight looks like

Three distinct effects, all of which apply to the *sky*, not to the ship:

1. **Aberration.** The apparent direction of a source, seen from the moving
   ship, satisfies `cos θ = (cos θ' − β)/(1 − β cos θ')`. Stars pile up into a
   forward cone; at γ = 10 the entire sky is squeezed into ~11° ahead.
2. **Doppler.** `D = 1/(γ(1 − β cos θ'))`. Blue ahead, red behind. A blackbody at
   `T` is seen at `T·D` — which is *exactly* representable here, because the sky
   colours its stars from a Planck locus, so the shift is applied to `T` at
   source rather than as a hue filter afterwards.
3. **Headlight effect.** Specific intensity transforms as `I' = D⁴ I`. Forward
   the sky brightens enormously; behind it goes black. This is the same physics
   that makes blazars bright, and it is one line.

Aberration also changes the *solid angle per pixel*, which is why it must be
applied to the ray direction **before** the screen-space derivatives are taken —
then the existing point-source machinery in `sim/sky.js` handles the star
crowding by itself, exactly as it already does for lensing magnification. No new
resolution assumption is introduced, which the repo forbids.

Sources: [Baez, *The Relativistic Rocket*](https://math.ucr.edu/home/baez/physics/Relativity/SR/Rocket/rocket.html),
[Relativistic aberration](https://en.wikipedia.org/wiki/Relativistic_aberration),
[C-ship: aberration](https://www.fourmilab.ch/cship/aberration.html).

---

## 7. Effects

### Rocket plume

The plume's shape is set by the ratio of exit pressure to ambient:

- **Over-expanded** (sea level, `p_e < p_a`): the flow is squeezed by the outside
  air into a narrow column, and compresses back up to ambient through a train of
  oblique shocks — the **shock diamonds**. Three to five are visible on a
  Falcon 9 at liftoff. Bright nodes where the gas is compressed and heated, dark
  gaps where it expands.
- **Under-expanded** (vacuum, `p_e > p_a`): nothing confines it, so it opens into
  a huge, faint bell many times the nozzle diameter. This is why an upper stage
  looks like it has an enormous ghostly flame and a first stage looks like a
  blowtorch.

The transition is continuous in `p_a`, so one shader with `p_a/p_e` as a uniform
gives both, plus everything in between during ascent — which is the effect worth
having.

Colour is the propellant, not taste: RP-1/LOX is soot-luminous orange
(~2500–3000 K visible), LH2/LOX is nearly invisible pale blue-violet, methalox is
blue with a faint orange core, hypergolics are pale yellow-white. Plumes are
emitters, so they publish their temperature into the HDR alpha (`sim/spectrum.js`
convention) and re-image correctly in the infrared band.

### Ion engine

No thermal plume at all — a collimated beam of xenon ions recombining, so it is a
narrow, dim blue-violet cone with a bright grid glow at the base, and it does not
flicker. At 237 mN it also must not look powerful.

### Re-entry

The heating is `∝ √ρ · v³`, so the plasma sheath is driven off the same Sutton–
Graves number that ablates the shield: a bow-shock cap ahead of the vehicle whose
colour runs from dull red through orange to blue-white with `q̇`, plus a wake of
shed plasma. Nothing is scripted; if you enter too fast you get more of it, and
then you get a debris field.

### Materials

Spacecraft look the way they do for thermal reasons and it is worth being
accurate: the gold is **amber Kapton over vapour-deposited aluminium** (MLI), not
gold; white paint is for solar reflection, black for radiating; radiators are
flat white panels with visible tubing; solar cells are dark blue-violet with a
grid. Tanks are bare aluminium-lithium (Falcon), foam-insulated orange (Shuttle
ET), or stainless (Starship).

Sources: [Shock diamond](https://en.wikipedia.org/wiki/Shock_diamond),
[Shock diamonds and Mach disks](https://aerospaceweb.org/question/propulsion/q0224.shtml),
[Multi-layer insulation](https://en.wikipedia.org/wiki/Multi-layer_insulation).

---

## 8. Structural integrity — what actually breaks

Four independent failure modes, each with a published-ish limit:

| mode | limit used | what exceeds it |
| --- | --- | --- |
| dynamic pressure | 35–50 kPa depending on vehicle | flying too fast too low |
| axial load | 4 g crewed, 6–8 g uncrewed | not throttling a light upper stage |
| aerodynamic torque, `q·α` | ~5 kPa·rad | steering hard in the thick air |
| heat load | ablator budget in MJ/m² | too steep or too fast an entry |

Saturn V peaked at ~4 g at S-IC cutoff and the crew felt it; the Shuttle
throttled to hold 3 g. Both are consequences of a light vehicle with a fixed
engine, and both emerge here rather than being scripted.

---

## 9. Unit and frame decisions (the part that makes this fit the repo)

The orrery works in **AU / M☉ / yr** with `G = 4π²`. A rocket works in
**m / kg / s**. Bridging them badly would destroy both, so:

- The vessel's state is `(r, v)` in **metres and m/s**, relative to its **parent
  body's centre**, in a frame whose axes are parallel to the world frame but
  which is **not inertial** (it accelerates with the parent).
- Gravity in that frame is the full n-body sum minus the frame's own
  acceleration — which is the standard third-body-perturbation form and yields
  real tidal terms for free:
  ```
  a = Σᵢ GMᵢ (Rᵢ − R_v)/|Rᵢ − R_v|³  −  Σᵢ≠p GMᵢ (Rᵢ − R_p)/|Rᵢ − R_p|³
  ```
- `GM☉ = 1.32712440018e20 m³/s²`, which is the *same constant* as `G = 4π²`:
  `4π²·AU³/yr² = 1.3273e20 m³/s²`. Nothing is rescaled, only re-expressed.
- Scene position is `parentScene + (r/AU)·sceneScale`, so the vessel inherits
  the existing true-scale machinery, including the point-source marker for when
  it is (always) sub-pixel from orbital distances.
- The flight clock runs in seconds; the orrery clock runs in years. Entering
  flight sets `state.timeScale` from the flight warp (`warp/YR_S` yr/s), so the
  planets keep orbiting correctly, just slowly, and there is only ever **one**
  clock driving the world.
