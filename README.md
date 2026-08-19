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

## Features

- **Scenarios:** **Trisolaris** · **Wandering Suns** · **Compact Haven** · **Wide Seasons** ·
  **Alpha's Refuge** · **Trisolaris — Chaotic Era** · Black Hole Sandbox ·
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
- **Camera:** orbit camera, **free-fly mode** (WASD + mouse look), **surface view** from
  the planet's ground (`V`), and **click any object to focus and zoom** onto it.
- Gravitational lensing (now up to two black holes), accretion-disc shader with
  Doppler beaming & gravitational redshift, and a deformable spacetime mesh.

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
`space` pause · `del` remove focused.

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

## Disclaimer

For education and play. The orbital dynamics, stellar scaling relations and the climate
model are real. Compact-object sizes, horizon radii and merger timescales are deliberately
exaggerated for visibility — and so are **stellar radii in the surface view**: the suns of
Trisolaris are drawn about 10× their true angular size (a real one would subtend ~0.3°),
because a physically-sized sun is a bright dot and the point of that view is the sky.
