# Gravitational Sandbox — a real-physics space sim

An interactive space simulator built with Three.js. It started as a single-prompt
black-hole renderer (gravitational lensing, accretion disc, spacetime mesh) and has
grown into a small N-body sandbox with real orbital mechanics and a set of
ready-made astrophysical scenarios.

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
> its orbit. Orbital *distances* and dynamics are real.

## Features

- **Scenarios:** Black Hole Sandbox · Solar System (real distances & masses — zoom way
  out for Pluto) · Three-Body figure-eight (an exact choreography solution) · Binary
  Star · Binary Black Hole Merger · Neutron Star Merger (kilonova) · BH Devouring a Star.
- **Stars** with an animated granulation/sunspot surface shader, gassy outer layer,
  corona and flaring prominences.
- **Neutron stars** that spin and sweep two lighthouse **pulsar beams**.
- **Procedurally generated planets** — rocky worlds (continents, oceans, ice caps) and
  banded gas giants (zonal bands, storms, optional rings).
- **Accretion:** bodies near a black hole are tidally stripped, shedding a visible
  particle stream and **losing mass** (they shrink) as they feed it.
- **Camera:** orbit camera, **free-fly mode** (WASD + mouse look), and **click any
  object to focus and zoom** onto it. Per-object delete.
- Gravitational lensing (now up to two black holes), accretion-disc shader with
  Doppler beaming & gravitational redshift, and a deformable spacetime mesh.

## Running

It's static — serve the folder and open `blackhole_sim.html`:

```bash
python3 -m http.server
# then open http://localhost:8000/blackhole_sim.html
```

Deep-link a scenario with a URL hash, e.g. `blackhole_sim.html#bhmerger`.

### Controls

`drag` look · `scroll` zoom / fly-speed · `click` focus object · `F` free cam ·
`WASD` fly (`Shift` boost, `Q/E` down/up) · `R` reset view · `space` pause · `del` remove focused.

## Layout

- `blackhole_sim.html` / `.css` — shell & UI
- `blackhole_sim.js` — scene, lensing/disc shader, camera, picking, render loop, UI
- `sim/physics.js` — N-body integrator, GR pseudo-potential, GW inspiral, collisions
- `sim/bodies.js` — body visuals (star/neutron/planet shaders, accretion streams)
- `sim/textures.js` — procedural rocky & gas-giant texture generation
- `sim/presets.js` — scenario definitions with real initial conditions

## Disclaimer

For education and play. The orbital dynamics are real; compact-object sizes, horizon
radii and merger timescales are deliberately exaggerated for visibility.
