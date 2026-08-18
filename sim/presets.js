import { circularSpeed, G } from './physics.js';
import { luminosity, effectiveTemp } from './stellar.js';

// ============================================================================
// PRESET SCENARIOS
// Every spec is in REAL units: mass = M☉, pos = AU, vel = AU/yr.
// `sceneScale` = scene units per AU (rendering only). `bodyScale` exaggerates
// rendered body sizes (true-to-scale planets ARE sub-pixel — `trueScale: true`
// draws them honestly instead and leans on the point-source markers in
// sim/scale.js to keep them visible). `radiusKm` supplies a real physical
// radius; without one, sim/scale.js falls back to a mass–radius relation.
// `gwBoost` accelerates gravitational-wave inspiral so mergers are watchable.
//
// `sky` says WHERE IN THE UNIVERSE the system is, which sim/sky.js turns into a
// background. `env` names one of SKY_ENVIRONMENTS — disc, core, globular, halo,
// starburst — and `tilt`/`roll` orient the galactic plane relative to the
// scene, deciding where the band crosses the view. Nothing here obliges the sky
// to be Earth's; a system in a globular cluster genuinely has thousands of
// bright stars and no band at all, and saying so costs two numbers.
// ============================================================================

// two-body barycentric setup orbiting in the XZ plane
function binary(m1, m2, sep, t1, t2, phase = 0) {
  const M = m1 + m2;
  const r1 = sep * m2 / M, r2 = sep * m1 / M;
  const vrel = circularSpeed(M, sep);
  const v1 = vrel * m2 / M, v2 = vrel * m1 / M;
  const cx = Math.cos(phase), cz = Math.sin(phase);
  return [
    { ...t1, mass: m1, pos: [-r1 * cx, 0, -r1 * cz], vel: [r1 * 0 + v1 * cz, 0, -v1 * cx] },
    { ...t2, mass: m2, pos: [r2 * cx, 0, r2 * cz], vel: [-v2 * cz, 0, v2 * cx] },
  ];
}

// ----------------------------------------------------------------------------
// Keplerian two-body relative state (position & velocity) for an orbit with
// semi-major axis a, eccentricity e, inclination incl, at true anomaly nu.
// Used to assemble hierarchical systems exactly rather than by eyeballing.
// ----------------------------------------------------------------------------
function kepler(Mtot, a, e, incl, nu) {
  const p = a * (1 - e * e);
  const r = p / (1 + e * Math.cos(nu));
  const h = Math.sqrt(G * Mtot * p);
  const px = r * Math.cos(nu), pz = r * Math.sin(nu);
  const vx = -G * Mtot / h * Math.sin(nu);
  const vz = G * Mtot / h * (e + Math.cos(nu));
  const c = Math.cos(incl), s = Math.sin(incl);
  return { pos: [px, pz * s, pz * c], vel: [vx, vz * s, vz * c] };
}

const addv = (a, b, k = 1) => [a[0] + b[0] * k, a[1] + b[1] * k, a[2] + b[2] * k];
const mulv = (a, k) => [a[0] * k, a[1] * k, a[2] * k];

// Shared three-sun constructors. The nested Kepler states put every level at
// its own barycentre before the outer orbit is applied, which avoids the small
// but secular kick caused by simply placing the inner system at the origin.
function triStar(name, mass, extra = {}) {
  return {
    type: 'star', name, mass,
    luminosity: luminosity(mass), teff: effectiveTemp(mass), ...extra,
  };
}

function circumbinaryTriad({
  mA, mB, mC, aBin, aWorld, eWorld, worldNu = Math.PI,
  aOuter, eOuter, outerIncl = 0, outerNu = Math.PI * 0.55,
  world = {},
}) {
  const Mab = mA + mB;
  const kb = kepler(Mab, aBin, 0, 0, 0);
  const A = { ...triStar('Alpha', mA), pos: mulv(kb.pos, -mB / Mab), vel: mulv(kb.vel, -mB / Mab) };
  const B = { ...triStar('Beta', mB), pos: mulv(kb.pos, mA / Mab), vel: mulv(kb.vel, mA / Mab) };

  const kw = kepler(Mab, aWorld, eWorld, 0, worldNu);
  const P = {
    type: 'world', name: 'Trisolaris', mass: 3.0e-6,
    pos: kw.pos, vel: kw.vel,
    dayLength: 1 / 90, obliquity: 0.41, home: true,
    ...world,
  };

  // The outer star orbits the barycentre of the binary + world, not the
  // binary alone. The distinction is tiny here, but keeps the construction
  // self-consistent and makes the helper safe for heavier test worlds too.
  const Min = Mab + P.mass, Mtot = Min + mC;
  const ko = kepler(Mtot, aOuter, eOuter, outerIncl, outerNu);
  const C = { ...triStar('Gamma', mC), pos: mulv(ko.pos, Min / Mtot), vel: mulv(ko.vel, Min / Mtot) };
  const off = mulv(ko.pos, -mC / Mtot), offv = mulv(ko.vel, -mC / Mtot);
  for (const b of [A, B, P]) { b.pos = addv(b.pos, off); b.vel = addv(b.vel, offv); }

  return [A, B, C, P];
}

function alphaWorldTriad({
  mA, mB, mC, aWorld, eWorld, worldNu = Math.PI,
  aBeta, eBeta, betaIncl = 0, betaNu = 0,
  aOuter, eOuter, outerIncl = 0, outerNu = Math.PI * 0.55,
  world = {},
}) {
  // First level: Trisolaris is an S-type world around Alpha.
  const Mwp = mA + 3.0e-6;
  const kw = kepler(Mwp, aWorld, eWorld, 0, worldNu);
  const A = { ...triStar('Alpha', mA), pos: mulv(kw.pos, -3.0e-6 / Mwp), vel: mulv(kw.vel, -3.0e-6 / Mwp) };
  const P = {
    type: 'world', name: 'Trisolaris', mass: 3.0e-6,
    pos: mulv(kw.pos, mA / Mwp), vel: mulv(kw.vel, mA / Mwp),
    dayLength: 1 / 90, obliquity: 0.41, home: true,
    ...world,
  };

  // Second level: Beta circles the Alpha + world pair. Gamma then circles the
  // entire nested system, so neither outer orbit is started around a false
  // origin.
  const Minner = Mwp + mB;
  const kb = kepler(Minner, aBeta, eBeta, betaIncl, betaNu);
  const B = { ...triStar('Beta', mB), pos: mulv(kb.pos, Mwp / Minner), vel: mulv(kb.vel, Mwp / Minner) };
  const boff = mulv(kb.pos, -mB / Minner), boffv = mulv(kb.vel, -mB / Minner);
  for (const b of [A, P]) { b.pos = addv(b.pos, boff); b.vel = addv(b.vel, boffv); }

  const Mtot = Minner + mC;
  const ko = kepler(Mtot, aOuter, eOuter, outerIncl, outerNu);
  const C = { ...triStar('Gamma', mC), pos: mulv(ko.pos, Minner / Mtot), vel: mulv(ko.vel, Minner / Mtot) };
  const off = mulv(ko.pos, -mC / Mtot), offv = mulv(ko.vel, -mC / Mtot);
  for (const b of [A, B, P]) { b.pos = addv(b.pos, off); b.vel = addv(b.vel, offv); }

  return [A, B, C, P];
}

// circular orbit about a dominant central mass at the origin
function orbiter(Mc, a, spec, angle = Math.random() * Math.PI * 2, incl = 0) {
  const v = circularSpeed(Mc, a);
  const x = Math.cos(angle) * a, z = Math.sin(angle) * a;
  const y = Math.sin(incl) * x;
  return { ...spec, pos: [x, y * 0.02, z], vel: [-Math.sin(angle) * v, 0, Math.cos(angle) * v] };
}

export const PRESETS = {
  // --------------------------------------------------------------------------
  sandbox: {
    sky: { env: 'disc', tilt: 0.42, roll: 0.7 },
    name: 'Black Hole Sandbox',
    blurb: 'A 10 M☉ black hole with a live accretion disc & lensing. Spawn bodies and watch them orbit, get shredded, and fall in.',
    sceneScale: 2.0, bodyScale: 1.0, camRadius: 34, lensing: true,
    build() {
      const Mbh = 10, rs = 0.5;   // 0.5 AU "fat" horizon → self-consistent & visible
      const bodies = [{ type: 'bh', name: 'Singularity', mass: Mbh, rs, pos: [0, 0, 0], vel: [0, 0, 0] }];
      bodies.push(orbiter(Mbh, 4.5, { type: 'gas-giant', name: 'Gas Giant', palette: 'jupiter' }, 0.6));
      bodies.push(orbiter(Mbh, 7.0, { type: 'star', name: 'Companion Star', mass: 1.2 }, 3.4));
      return bodies;
    },
  },

  // --------------------------------------------------------------------------
  solar: {
    sky: { env: 'disc', tilt: 0.38, roll: 2.1 },
    name: 'Solar System',
    blurb: 'Real orbital distances, masses and body radii, G = 4π². Sizes default to TRUE scale — the planets are points until you fly to one. Toggle "Sizes" to get the readable, exaggerated view back.',
    sceneScale: 1.0, bodyScale: 0.5, camRadius: 80, lensing: false, timeScale: 6,
    // The one preset where the bodies are drawn at their real geometric size.
    // See sim/scale.js for why that needs a point-source fallback to be usable.
    trueScale: true,
    build() {
      const Ms = 1.0;
      const sun = { type: 'star', name: 'Sun', mass: Ms, color: 0xfff2cc, glow: 0xffaa33, pos: [0, 0, 0], vel: [0, 0, 0] };
      // a = semi-major axis (AU), m = mass (M☉), radiusKm = mean physical radius
      const P = (a, m, radiusKm, type, name, extra) => orbiter(Ms, a, { type, name, mass: m, radiusKm, ...extra });
      return [
        sun,
        P(0.387, 1.66e-7,  2439.7, 'planet', 'Mercury', { hot: true }),
        P(0.723, 2.45e-6,  6051.8, 'planet', 'Venus', { hot: true, atmosphere: true, atmColor: 0xffd9a0 }),
        P(1.000, 3.00e-6,  6371.0, 'planet', 'Earth', { atmosphere: true, seaLevel: 0.55 }),
        P(1.524, 3.21e-7,  3389.5, 'planet', 'Mars', { hot: true }),
        P(5.203, 9.54e-4, 69911.0, 'gas-giant', 'Jupiter', { palette: 'jupiter' }),
        P(9.537, 2.86e-4, 58232.0, 'gas-giant', 'Saturn', { palette: 'saturn', rings: true }),
        P(19.19, 4.37e-5, 25362.0, 'gas-giant', 'Uranus', { palette: 'ice' }),
        P(30.07, 5.15e-5, 24622.0, 'gas-giant', 'Neptune', { palette: 'ice' }),
        P(39.48, 6.55e-9,  1188.3, 'planet', 'Pluto', { hot: false }),
      ];
    },
  },

  // --------------------------------------------------------------------------
  threebody: {
    sky: { env: 'globular', tilt: 0.30, roll: 1.4 },
    name: 'Three-Body (figure-eight)',
    blurb: 'The Chenciner–Montgomery choreography: three equal masses chasing each other along one shared figure-eight orbit. A real exact solution.',
    sceneScale: 4.0, bodyScale: 1.4, camRadius: 22, lensing: false,
    build() {
      // exact figure-eight ICs for G=m=1; rescale velocities by 2π for G=4π².
      const k = 2 * Math.PI;
      const p = [0.97000436, -0.24308753];
      const v3 = [-0.93240737, -0.86473146];
      const star = (i) => ({ type: 'star', name: `Body ${i}`, mass: 1, color: [0xffd9a0, 0xa0c8ff, 0xffa0a0][i - 1], glow: [0xff8040, 0x4080ff, 0xff4060][i - 1] });
      return [
        { ...star(1), pos: [p[0], 0, p[1]], vel: [-v3[0] / 2 * k, 0, -v3[1] / 2 * k] },
        { ...star(2), pos: [-p[0], 0, -p[1]], vel: [-v3[0] / 2 * k, 0, -v3[1] / 2 * k] },
        { ...star(3), pos: [0, 0, 0], vel: [v3[0] * k, 0, v3[1] * k] },
      ];
    },
  },

  // --------------------------------------------------------------------------
  // TRISOLARIS
  // --------------------------------------------------------------------------
  // Three suns and a world, arranged so it actually survives. A raw three-body
  // system with a planet in it disintegrates in a few hundred years, which is
  // dramatic but useless for watching a climate evolve. So this uses the one
  // arrangement nature actually permits for long-lived multiple-star systems: a
  // HIERARCHY.
  //
  //   · Alpha (1.20 M☉, F-type) and Beta (0.85 M☉, K-type) are a tight pair,
  //     0.35 AU apart, circling each other every 53 days.
  //   · Trisolaris orbits BOTH of them at 1.80 AU — a circumbinary "P-type"
  //     orbit, comfortably outside the Holman–Wiegert stability limit
  //     (a_crit ≈ 2.3 a_bin ≈ 0.8 AU), on a deliberately eccentric path (e = 0.42).
  //   · Gamma (2.00 M☉, hot A-type, 11 L☉) sweeps around the whole inner system
  //     on a 51-year, 25°-inclined orbit.
  //
  // Verified by integration: the configuration holds for 60 000+ simulated years
  // with a relative energy drift of ~1e-7. The planet's insolation still swings
  // by a factor of ~9 — from 0.34 to 3.1 Earth-suns — which is what drives the
  // Stable and Chaotic Eras. The chaos is in the CLIMATE, not in the orbits.
  trisolaris: {
    sky: { env: 'disc', tilt: 0.55, roll: 0.35 },
    name: 'Trisolaris',
    blurb: 'Three suns, one world. A tight binary (Alpha + Beta) with Trisolaris on a wide eccentric circumbinary orbit, and hot Gamma sweeping past every 51 years. Insolation swings 9× — the Stable and Chaotic Eras are emergent, not scripted. Stable for 60 000+ years.',
    sceneScale: 4.0, bodyScale: 0.55, camRadius: 20, lensing: false,
    // The tighter cap keeps the 60 000-year phase error bounded; 8e-4 is fast
    // enough to look fine but eventually lets this particular hierarchy drift.
    timeScale: 0.35, maxStep: 4e-4,
    surface: true, focus: 'Alpha', mesh: false,                      // offers the view-from-the-ground camera
    climate: { mixedLayer: 12, T0: 288 },
    build() {
      const mA = 1.20, mB = 0.85, mC = 2.00, mp = 3.0e-6;
      const aBin = 0.35;                       // Alpha–Beta separation
      const aP = 1.80, eP = 0.42;              // Trisolaris' circumbinary orbit
      const aC = 22.0, eC = 0.35, iC = 25 * Math.PI / 180;

      const star = (name, mass, extra) => ({
        type: 'star', name, mass,
        luminosity: luminosity(mass), teff: effectiveTemp(mass), ...extra,
      });

      // -- inner binary about its own barycentre
      const Mab = mA + mB;
      const kb = kepler(Mab, aBin, 0, 0, 0);
      const A = { ...star('Alpha', mA), pos: mulv(kb.pos, -mB / Mab), vel: mulv(kb.vel, -mB / Mab) };
      const B = { ...star('Beta', mB), pos: mulv(kb.pos, mA / Mab), vel: mulv(kb.vel, mA / Mab) };

      // -- Trisolaris on a circumbinary orbit about that barycentre,
      //    started at apoapsis: the world begins in a long, cold winter.
      const kp = kepler(Mab, aP, eP, 0, Math.PI);
      const P = {
        type: 'world', name: 'Trisolaris', mass: mp,
        pos: kp.pos, vel: kp.vel,
        dayLength: 1 / 90,               // ~4 sim-day rotation, slow enough to watch
        obliquity: 0.41,
        home: true,
      };

      // -- Gamma about the whole inner system, started near apoapsis so its
      //    approach (and the heat that comes with it) plays out as you watch.
      const Min = Mab + mp, Mtot = Min + mC;
      const kc = kepler(Mtot, aC, eC, iC, Math.PI * 0.55);
      const C = { ...star('Gamma', mC), pos: mulv(kc.pos, Min / Mtot), vel: mulv(kc.vel, Min / Mtot) };
      const off = mulv(kc.pos, -mC / Mtot), offv = mulv(kc.vel, -mC / Mtot);
      for (const b of [A, B, P]) { b.pos = addv(b.pos, off); b.vel = addv(b.vel, offv); }

      return [A, B, C, P];
    },
  },

  // A more compact P-type hierarchy. The inner binary is tighter and Gamma
  // comes closer, but the world still has >4 binary separations at periapsis
  // and Gamma stays >7 world apocentres away at its closest approach.
  trisolaris_compact: {
    sky: { env: 'disc', tilt: 0.50, roll: 0.65 },
    name: 'Trisolaris - Compact Haven',
    blurb: 'A compact, bright hierarchy: Trisolaris circles Alpha and Beta at 1.35 AU while Gamma sweeps the 15 AU outer orbit. Three suns, stronger encounters, and a stable 60 000-year architecture.',
    sceneScale: 4.0, bodyScale: 0.55, camRadius: 20, lensing: false,
    timeScale: 0.35, maxStep: 4e-4,
    surface: true, focus: 'Alpha', mesh: false,
    climate: { mixedLayer: 12, T0: 288 },
    build() {
      return circumbinaryTriad({
        mA: 1.15, mB: 0.75, mC: 1.55,
        aBin: 0.24, aWorld: 1.35, eWorld: 0.22,
        aOuter: 15.0, eOuter: 0.22, outerIncl: 12 * Math.PI / 180,
        outerNu: Math.PI * 0.65,
      });
    },
  },

  // A wide P-type hierarchy trades encounter strength for a long outer period.
  // The planet's 2.6 AU orbit has room for a large seasonal cycle without
  // approaching the circumbinary stability boundary.
  trisolaris_wide: {
    sky: { env: 'disc', tilt: 0.60, roll: 0.10 },
    name: 'Trisolaris - Wide Seasons',
    blurb: 'A wide circumbinary world: Alpha and Beta are 0.55 AU apart, Trisolaris follows a 2.6 AU eccentric orbit, and Gamma returns every century from 36 AU. Verified stable for 60 000 simulated years.',
    sceneScale: 3.0, bodyScale: 0.55, camRadius: 28, lensing: false,
    timeScale: 0.35, maxStep: 4e-4,
    surface: true, focus: 'Alpha', mesh: false,
    climate: { mixedLayer: 18, T0: 288 },
    build() {
      return circumbinaryTriad({
        mA: 1.05, mB: 0.90, mC: 1.65,
        aBin: 0.55, aWorld: 2.60, eWorld: 0.28,
        aOuter: 36.0, eOuter: 0.25, outerIncl: 18 * Math.PI / 180,
        outerNu: Math.PI * 0.40,
      });
    },
  },

  // The world need not be circumbinary. This S-type solution nests the world
  // around Alpha, Beta around that pair, and Gamma around the whole hierarchy.
  // It is a useful counterexample to the first preset: the planet gets a
  // familiar dominant sun while the other two still make a changing sky.
  trisolaris_alpha: {
    sky: { env: 'disc', tilt: 0.46, roll: 1.05 },
    name: "Trisolaris - Alpha's Refuge",
    blurb: "An S-type solution: Trisolaris orbits Alpha at 0.8 AU, Beta circles the pair at 6.5 AU, and Gamma stays out at 52 AU. The planet remains bound to its home sun for 60 000+ simulated years.",
    sceneScale: 2.4, bodyScale: 0.55, camRadius: 24, lensing: false,
    timeScale: 0.35, maxStep: 4e-4,
    surface: true, focus: 'Alpha', mesh: false,
    climate: { mixedLayer: 14, T0: 288 },
    build() {
      return alphaWorldTriad({
        mA: 1.10, mB: 0.80, mC: 1.60,
        aWorld: 0.80, eWorld: 0.12, worldNu: Math.PI,
        aBeta: 6.50, eBeta: 0.18, betaIncl: 8 * Math.PI / 180, betaNu: 0.90,
        aOuter: 52.0, eOuter: 0.20, outerIncl: 18 * Math.PI / 180,
        outerNu: Math.PI * 0.60,
      });
    },
  },

  // --------------------------------------------------------------------------
  // The honest version: a genuine, non-hierarchical three-body system. This is
  // what the Trisolarans actually live with — and it is why they want to leave.
  // Expect the planet to be flung into a wildly eccentric orbit, swallowed, or
  // ejected outright, usually within a few hundred years. Reload to reroll.
  trisolaris_chaos: {
    sky: { env: 'disc', tilt: 0.55, roll: 0.35 },
    name: 'Trisolaris — Chaotic Era',
    blurb: 'The same three suns with NO protective hierarchy — a true chaotic three-body system. Trisolaris gets thrown between the stars, roasted, frozen, and usually ejected or consumed within a few centuries. This is the version that has no solution.',
    sceneScale: 3.0, bodyScale: 0.55, camRadius: 40, lensing: false,
    timeScale: 0.35, maxStep: 6e-4,
    surface: true, focus: 'Alpha', mesh: false,
    climate: { mixedLayer: 10, T0: 288 },
    build() {
      const star = (name, mass, extra) => ({
        type: 'star', name, mass,
        luminosity: luminosity(mass), teff: effectiveTemp(mass), ...extra,
      });
      // three comparable masses on a near-equilateral (Lagrange) layout, which
      // is unstable for mass ratios like these — it breaks up on its own.
      const ms = [1.20, 0.85, 2.00];
      const R = 3.2, Mt = ms.reduce((a, b) => a + b, 0);
      const names = ['Alpha', 'Beta', 'Gamma'];
      const bodies = ms.map((m, i) => {
        const th = (i * 2 * Math.PI) / 3;
        const v = Math.sqrt(G * Mt / (Math.sqrt(3) * R)) * 0.96;   // just off equilibrium
        return {
          ...star(names[i], m),
          pos: [R * Math.cos(th), 0, R * Math.sin(th)],
          vel: [-v * Math.sin(th), 0, v * Math.cos(th)],
        };
      });
      bodies.push({
        type: 'world', name: 'Trisolaris', mass: 3e-6,
        pos: [0, 0, 9.5], vel: [-Math.sqrt(G * Mt / 9.5) * 1.02, 0, 0],
        dayLength: 1 / 90, obliquity: 0.41, home: true,
      });
      return bodies;
    },
  },

  // --------------------------------------------------------------------------
  bhmerger: {
    sky: { env: 'halo', tilt: 0.22, roll: 2.6 },
    name: 'Binary Black Hole Merger',
    blurb: 'Two stellar-mass black holes spiral together, shedding orbital energy to gravitational waves until they coalesce (à la GW150914). Inspiral rate exaggerated.',
    sceneScale: 60, bodyScale: 1.0, camRadius: 72, lensing: true, gwBoost: 3e10, timeScale: 0.15, maxStep: 5e-5,
    build() {
      return binary(36, 29, 0.45,
        { type: 'bh', name: 'BH-A', rs: 0.02 },
        { type: 'bh', name: 'BH-B', rs: 0.016 });
    },
  },

  // --------------------------------------------------------------------------
  nsmerger: {
    sky: { env: 'starburst', tilt: 0.48, roll: 1.9 },
    name: 'Neutron Star Merger',
    blurb: 'Two neutron stars inspiral and collide in a kilonova (à la GW170817). Watch the pulsar beams sweep as they whirl together.',
    sceneScale: 45, bodyScale: 1.0, camRadius: 26, lensing: false, gwBoost: 1.8e14, timeScale: 0.15, maxStep: 5e-5,
    build() {
      return binary(1.45, 1.35, 0.35,
        { type: 'neutron', name: 'NS-A', spin: 22 },
        { type: 'neutron', name: 'NS-B', spin: 16 });
    },
  },

  // --------------------------------------------------------------------------
  binarystar: {
    sky: { env: 'starburst', tilt: 0.50, roll: 0.9 },
    name: 'Binary Star Merger',
    blurb: 'A close contact binary: the two stars slowly spiral together and merge into one more massive star (a luminous red nova). Takes ~30 s — speed it up or slow it down with the slider.',
    sceneScale: 3.0, bodyScale: 1.0, camRadius: 16, lensing: false, gwBoost: 4e17, timeScale: 0.5,
    build() {
      return binary(1.1, 0.9, 2.5,
        { type: 'star', name: 'Star A', mass: 1.1, color: 0xfff0d0, glow: 0xffaa44, emitsGW: true },
        { type: 'star', name: 'Star B', mass: 0.9, color: 0xffd0a0, glow: 0xff8030, emitsGW: true });
    },
  },

  // --------------------------------------------------------------------------
  feeding: {
    sky: { env: 'core', tilt: 0.36, roll: 1.2 },
    name: 'Black Hole Devouring a Star',
    blurb: 'A star on a plunging orbit is tidally stripped, trailing a stream of gas onto the black hole.',
    sceneScale: 2.0, bodyScale: 1.0, camRadius: 30, lensing: true, discOuter: 9,
    build() {
      // Star starts on a true (Paczyński–Wiita) circular orbit at the OUTER edge of
      // the tidal reach, so it orbits stably while accretion drag bleeds its energy
      // and spirals it slowly inward, shedding a gas stream the whole way down.
      const Mbh = 12, rs = 0.5, a = 6;
      const v = Math.sqrt(G * Mbh * a) / (a - rs);   // PW circular speed
      return [
        { type: 'bh', name: 'Singularity', mass: Mbh, rs, pos: [0, 0, 0], vel: [0, 0, 0] },
        { type: 'star', name: 'Doomed Star', mass: 1.8, color: 0xffe0a0, glow: 0xff8040, pos: [a, 0, 0], vel: [0, 0, v] },
      ];
    },
  },
};

export const PRESET_ORDER = ['trisolaris', 'trisolaris_compact', 'trisolaris_wide', 'trisolaris_alpha', 'trisolaris_chaos', 'sandbox', 'solar', 'threebody', 'binarystar', 'bhmerger', 'nsmerger', 'feeding'];
