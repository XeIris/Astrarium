import { circularSpeed, rocheLimit, G } from './physics.js';
import { luminosity, effectiveTemp } from './stellar.js';
import { starSpec, starRing, realBinary, companion } from './starcat.js';
import { baseRadiusSun, phaseById } from './structure.js';

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

// ----------------------------------------------------------------------------
// A 2+2 hierarchy deliberately parked NEAR its stability boundary, which is the
// only architecture that gives the book's sky without the book's death sentence.
//
//   Alpha       the home sun. Trisolaris orbits it at aP, close in and tightly
//               bound, which is what lets the world survive at all.
//   Beta+Gamma  a tight pair (aBC) that together orbit Alpha on a wide, eccentric,
//               inclined orbit whose periapsis dives to q2 = a2(1 - e2).
//
// What makes the resulting sky non-repeating rather than merely periodic is that
// the encounters are strong and NOT in the secular regime. Each periapsis passage
// brings the pair to within q2 - aP of the world and delivers an impulsive kick to
// its orbit; near the Mardling-Aarseth stability boundary those kicks are large
// enough that the world's semi-major axis, eccentricity and orientation take a
// chaotic walk instead of averaging out. So no two passages find the world in the
// same place on the same orbit, and Beta and Gamma swing between flying-star
// points and discs that rival the home sun's, whirling around each other as they
// come. (Note that a modest `i2` is deliberate: below the ~39.2 deg Kozai-Lidov
// critical angle there is no eccentricity-inclination libration to speak of. The
// inclination here is not driving the chaos, it just denies the encounters a
// shared plane and keeps the suns from tracing one repeated line across the sky.)
//
// `qRatio` = q2 / aP is the single knob that matters. Below ~4 the world is
// stripped within decades; above ~6 the kicks weaken, the system relaxes toward a
// plain hierarchy, and the sky goes back to being predictable — measurably so, in
// a grid scan the one-sun fraction climbs from 21% to over 70%. See the preset.
// ----------------------------------------------------------------------------
function wanderingTriad({
  mA, mB, mC, aBC, eBC = 0.10, e2, i2, qRatio, fLight = 1.0,
  eP = 0.04, nuP = 0, nu2 = Math.PI, nuBC = 0, world = {},
}) {
  const mp = 3.0e-6;
  // put the world where Alpha alone delivers `fLight` Earth-suns
  const aP = Math.sqrt(luminosity(mA) / fLight);
  const a2 = (qRatio * aP) / (1 - e2);

  // A close pass is survivable here only because the destruction distance is the
  // real one. Left to the default, a body is destroyed on contact with its
  // *drawn* radius: for these stars that is 3.5-3.7x the true photosphere and
  // ~2x the Roche limit, and on the flagship preset's fatter drawing convention
  // it is ~9x and ~7x. That difference decides which close passes the world
  // walks away from, so it should not be a drawing choice. See attachVisual().
  const star = (name, mass) => ({
    type: 'star', name, mass,
    luminosity: luminosity(mass), teff: effectiveTemp(mass),
    contactAU: rocheLimit(mass),
  });

  // level 1: Trisolaris about Alpha
  const MAp = mA + mp;
  const kp = kepler(MAp, aP, eP, 0, nuP);
  const A = { ...star('Alpha', mA), pos: mulv(kp.pos, -mp / MAp), vel: mulv(kp.vel, -mp / MAp) };
  const P = {
    type: 'world', name: 'Trisolaris', mass: mp,
    pos: mulv(kp.pos, mA / MAp), vel: mulv(kp.vel, mA / MAp),
    dayLength: 1 / 90, obliquity: 0.41, home: true,
    ...world,
  };

  // level 1b: the Beta-Gamma pair about its own barycentre
  const MBC = mB + mC;
  const kbc = kepler(MBC, aBC, eBC, 0, nuBC);
  const B = { ...star('Beta', mB), pos: mulv(kbc.pos, -mC / MBC), vel: mulv(kbc.vel, -mC / MBC) };
  const C = { ...star('Gamma', mC), pos: mulv(kbc.pos, mB / MBC), vel: mulv(kbc.vel, mB / MBC) };

  // level 2: the pair's barycentre about Alpha's, inclined and eccentric
  const Mt = MAp + MBC;
  const k2 = kepler(Mt, a2, e2, i2, nu2);
  for (const b of [B, C]) { b.pos = addv(b.pos, k2.pos, MAp / Mt); b.vel = addv(b.vel, k2.vel, MAp / Mt); }
  for (const b of [A, P]) { b.pos = addv(b.pos, k2.pos, -MBC / Mt); b.vel = addv(b.vel, k2.vel, -MBC / Mt); }

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
  // TRISOLARIS — WANDERING SUNS
  // --------------------------------------------------------------------------
  // The other four Trisolaris presets put the chaos in the climate and keep the
  // orbits tame, which is what makes them last 60 000 years — but it also makes
  // their sky honest to the physics and *not* to the book. Alpha and Beta stay a
  // fixed pair overhead and Gamma sits 20 AU out contributing 0.04 S⊕: a third
  // sun you have to be told about. Nobody would write a religion around it.
  //
  // This one is built the other way round, for the SKY. It is a 2+2 hierarchy
  // parked just inside the region where secular evolution goes chaotic:
  //
  //   Alpha  0.58 M☉  K5, 4163 K   the home sun, 0.34 AU away — an orange disc
  //                                twice the width of Earth's Sun
  //   Beta   1.25 M☉  F5, 6770 K   — a tight 0.45 AU pair with a 78-day period,
  //   Gamma  0.78 M☉  K2, 4973 K     the two of them on one wide e = 0.50 orbit
  //                                  inclined 22° to the world's own
  //
  // The pair's periapsis dives to 1.68 AU — five times the world's own orbit,
  // which is close enough for Beta and Gamma to swell into discs and pull the
  // world's orbit around, and far enough that it is not simply torn away on the
  // first pass. Every 3.8 years they come back, and each passage kicks the world's
  // orbit hard enough that this close to the stability boundary the kicks compound
  // chaotically rather than averaging away — so no two returns find the world where
  // the last one left it, and none of them look alike. Nothing here is scripted or
  // animated: the suns wander because the three-body problem says they do.
  //
  // Measured over a 24-run ensemble at this preset's own step cap (75 203 samples;
  // see the note on determinism below), counting how many of the three are close
  // enough to show a real disc — at least a quarter of the width Earth's Sun
  // shows us, which is a statement about distance and not about how big this sim
  // chooses to draw them:
  //
  //     none               3%        true dark. Rare, and it does happen
  //     one               21%        a Stable Era. The sky you could plan a harvest by
  //     two               44%        the ordinary state of affairs
  //     three             32%        a tri-solar day, and the world bakes
  //
  // The same measurement on the flagship preset gives a flat 0 / 0 / 100 / 0 —
  // two suns, always, never changing size. Insolation here runs 0.64 (5th pct) to
  // 3.68 (95th), tailing to 7.8 at the 99th, and stays in the liquid-water band
  // 91% of the time. How many are above the HORIZON at any moment is then set by
  // the world's own 4-day rotation on top of that: near a close approach a single
  // day carries you through all four of those skies and back.
  //
  // ON DETERMINISM. A chaotic system's Lyapunov time is of order its orbital
  // period, so after a few decades this scenario's trajectory is set by
  // floating-point rounding, not by these initial conditions — your run will NOT
  // match the numbers above shot for shot, and cannot. Everything quoted here is
  // therefore pooled over 24 runs differing only in starting phase, which is the
  // only kind of claim that means anything about a system like this. On that
  // ensemble the world lives a median of 382 years (shortest 92, longest 3437) and
  // always ends: 14 of the 24 runs ejected it into the dark, the other 10 fed it
  // to a star's Roche limit. It is supposed to end. That is the premise of the
  // book. Worst-case energy drift across those runs is 5.3e-4.
  trisolaris_wander: {
    sky: { env: 'disc', tilt: 0.52, roll: 0.85 },
    name: 'Trisolaris — Wandering Suns',
    blurb: 'Three suns that genuinely wander. A tight Beta+Gamma pair dives past the home sun every 3.8 years on a chaotically evolving inclined orbit, so the sky is never the same twice: one sun 21% of the time, two 44%, three 32%, dark 3% — against two-suns-always for the other architectures. Stand on the planet (V); this is the one built for the view. Unlike them it is not stable, and it is not meant to be: the world lives a few centuries, then is ejected or torn apart.',
    sceneScale: 4.0, bodyScale: 0.20, camRadius: 18, lensing: false,
    // Close passes are the whole point here, so the step cap is tighter than the
    // stable presets'. At 3e-4 the worst-case relative energy drift is 6e-5 over
    // 1500 years and 5.3e-4 across the full 24-run ensemble; halving the cap again
    // changes neither the lifetimes nor the sky statistics.
    timeScale: 0.35, maxStep: 3e-4,
    surface: true, focus: 'Alpha', mesh: false,
    // a deeper mixed layer than the flagship: the swings here are sharper, and
    // 20 m of ocean is what keeps them eras rather than weather.
    climate: { mixedLayer: 20, T0: 288 },
    build() {
      return wanderingTriad({
        mA: 0.58, mB: 1.25, mC: 0.78,
        aBC: 0.45, eBC: 0.10,
        e2: 0.50, i2: 22 * Math.PI / 180,
        qRatio: 5.0, fLight: 1.0,
        eP: 0.04, nuP: 0.9, nu2: Math.PI, nuBC: 2.1,
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

  // ==========================================================================
  // REAL STARS
  // --------------------------------------------------------------------------
  // Everything below is built from measured objects — see sim/starcat.js for
  // the numbers and where they come from. These presets all run at TRUE SCALE,
  // because their whole point is a comparison, and a comparison between
  // exaggerated radii is a comparison between drawing conventions. A star that
  // goes sub-pixel is carried by the point-source marker in sim/scale.js, which
  // is what a telescope does with it too.
  // ==========================================================================

  stellar_zoo: {
    sky: { env: 'disc', tilt: 0.34, roll: 1.15 },
    name: 'The Stellar Zoo',
    blurb: 'Ten famous stars at their true relative sizes, from Betelgeuse — whose photosphere would reach the asteroid belt — down to Sirius B, an Earth-sized white dwarf. That is a range of 90 000 to 1, so most of them are points until you fly to them. They are on genuinely circular orbits about their common centre of mass, computed from the real N-body force at t = 0; a ring of unequal masses has no stable mode, so left running it will buckle and come apart. That is the correct answer, not a bug.',
    sceneScale: 0.5, bodyScale: 1.0, camRadius: 60, lensing: false, mesh: false,
    trueScale: true, timeScale: 1.5, maxStep: 2e-3,
    build() {
      return starRing(['betelgeuse', 'rigel', 'aldebaran', 'polaris', 'achernar',
                       'bellatrix', 'vega', 'siriusA', 'sun', 'siriusB'], 70);
    },
  },

  sirius: {
    sky: { env: 'disc', tilt: 0.40, roll: 2.4 },
    name: 'Sirius A & B',
    blurb: 'The real orbit: a = 7.50 AU, e = 0.59, period 50.13 years. Sirius A is an ordinary A1 star; Sirius B beside it has 1.02 solar masses packed into the volume of Earth, held up by electron degeneracy alone. Its existence was deduced from Sirius A wobbling, forty years before anyone saw it. At true scale B is a point of light — which is exactly the observational problem that made it so hard to find.',
    sceneScale: 3.0, bodyScale: 1.0, camRadius: 40, lensing: false, mesh: false,
    trueScale: true, timeScale: 3, maxStep: 1e-3,
    build() { return realBinary('siriusA', 'siriusB', { a: 7.4957, e: 0.5923, incl: 0.24, nu: 2.2 }); },
  },

  vega: {
    sky: { env: 'disc', tilt: 0.28, roll: 0.5 },
    name: 'Vega — a star seen pole-on',
    blurb: 'Vega spins at 236 km/s, 88% of the speed at which it would fly apart, and we happen to look almost straight down its rotation axis. That is why it was the photometric zero point for a century and why the calibration was quietly wrong: we were measuring its hot pole. The bulge and the pole-to-equator temperature gradient here are not artistic — the measured rotation predicts an equatorial radius 1.192 times the polar against 1.193 observed, and von Zeipel gravity darkening then gives a 10 260 K pole over an 8 610 K equator against 10 070 / 8 910 measured. (Vega also has a debris disc, but it runs from 86 to 200 AU — twenty thousand times the width of the star — so there is no single zoom that shows you both.)',
    sceneScale: 182, bodyScale: 1.0, camRadius: 9, lensing: false, mesh: false,
    trueScale: true, timeScale: 0.2, maxStep: 1e-3,
    build() {
      const v = starSpec('vega', { pos: [0, 0, 0], vel: [0, 0, 0] });
      return [v];
    },
  },

  achernar: {
    sky: { env: 'disc', tilt: 0.62, roll: 1.8 },
    name: 'Achernar — the flattest star',
    blurb: 'Its equator sits 35% further from the centre than its poles, which is the most extreme rotational distortion measured on any bright star. The hard limit is 1.5: at that ratio the equator is in orbit and material simply leaves, and nothing that stays in one piece can be flatter. Achernar is close enough to it that it really is throwing off a disc of its own gas — the "e" in its spectral type B6Vep.',
    sceneScale: 64, bodyScale: 1.0, camRadius: 11, lensing: false, mesh: false,
    trueScale: true, timeScale: 0.2, maxStep: 1e-3,
    paint: [{ kind: 'ring', body: 'Achernar', inner: 0.052, outer: 0.13, tilt: 0.0, color: 0xffd0b0, density: 0.7, decretion: true }],
    build() { return [starSpec('achernar', { pos: [0, 0, 0], vel: [0, 0, 0] })]; },
  },

  betelgeuse: {
    sky: { env: 'disc', tilt: 0.30, roll: 2.9 },
    name: 'Betelgeuse',
    blurb: 'A red supergiant of 16.5 solar masses and 764 solar radii — put it where the Sun is and its surface would reach past the asteroid belt, swallowing Mercury, Venus, Earth and Mars. Jupiter and Saturn are drawn here at their real orbital distances, to scale, so you can see that Jupiter’s orbit is the first one that clears it. Its interior is the onion: an iron-free carbon–oxygen core under helium and hydrogen shells, and almost all of that enormous volume is emptier than a laboratory vacuum.',
    sceneScale: 2.2, bodyScale: 1.0, camRadius: 34, lensing: false, mesh: false,
    trueScale: true, timeScale: 0.4, maxStep: 2e-3,
    build() {
      const B = starSpec('betelgeuse', { pos: [0, 0, 0], vel: [0, 0, 0] });
      return [
        B,
        companion(B.mass, 5.203, { type: 'gas-giant', name: "Jupiter's orbit", mass: 9.5459e-4, radiusKm: 69911, palette: 'jupiter' }, 0.4),
        companion(B.mass, 9.537, { type: 'gas-giant', name: "Saturn's orbit", mass: 2.858e-4, radiusKm: 58232, palette: 'saturn', rings: true }, 3.1),
      ];
    },
  },

  alphacen: {
    sky: { env: 'disc', tilt: 0.44, roll: 0.2 },
    name: 'Alpha Centauri',
    blurb: 'The real nearest system, with the real orbit: A and B swing between 11.2 and 35.6 AU on an 80-year, e = 0.52 ellipse. Proxima is bound to the pair but 13 000 AU out — so far that it takes 550 000 years to go round once, and it is off screen at any zoom that shows the binary. Proxima b orbits it in 11 days, inside a habitable zone that is inside Mercury’s distance, around a star that flares hard enough to strip an atmosphere.',
    sceneScale: 1.6, bodyScale: 1.0, camRadius: 60, lensing: false, mesh: false,
    trueScale: true, timeScale: 4, maxStep: 2e-3,
    build() {
      const pair = realBinary('alphacenA', 'alphacenB', { a: 23.52, e: 0.5179, incl: 0.14, nu: 1.1 });
      const P = starSpec('proxima');
      // Proxima's real separation is 13 000 AU; placed there it is simply not
      // in the scene. It goes at 900 AU on the same bound, near-circular path
      // so it is reachable, and the blurb says what has been changed.
      const M = pair[0].mass + pair[1].mass + P.mass;
      const a = 900, v = circularSpeed(M, a);
      Object.assign(P, { pos: [a, 0, 0], vel: [0, 0, v * 0.55] });
      const pb = companion(P.mass, 0.0485, {
        type: 'planet', name: 'Proxima b', mass: 3.3e-6, radiusKm: 7160, hot: true,
      }, 1.0);
      pb.pos = [pb.pos[0] + a, pb.pos[1], pb.pos[2]];
      pb.vel = [pb.vel[0], pb.vel[1], pb.vel[2] + v * 0.55];
      return [...pair, P, pb];
    },
  },

  etacar: {
    sky: { env: 'starburst', tilt: 0.52, roll: 1.35 },
    name: 'Eta Carinae — against the Eddington limit',
    blurb: 'A hundred solar masses radiating five million times the Sun. At that luminosity the radiation pressure pushing outward on free electrons is comparable to the star’s own gravity holding it in — L/L_Edd is near one, and its outer layers are barely bound at all. In the 1840s it threw off somewhere between ten and forty solar masses in a single eruption, briefly became the second brightest star in the sky, and survived. The debris is the Homunculus Nebula, expanding at its measured 650 km/s — drawn at 26 AU rather than its true 38 000, because the binary that threw it off is 15 AU across and there is no single frame that holds both.',
    sceneScale: 0.9, bodyScale: 1.0, camRadius: 78, lensing: false, mesh: false,
    trueScale: true, timeScale: 0.3, maxStep: 2e-3,
    paint: [{ kind: 'cloud', body: 'Eta Carinae A', radius: 26, lobes: 2, color: 0xffcf9a, density: 0.85, expand: 0.137 }],
    build() {
      const E = starSpec('etacar', { pos: [0, 0, 0], vel: [0, 0, 0] });
      // The real companion: ~30 M☉, 5.54-year orbit, e ≈ 0.9. Its periastron
      // passage is what makes the whole system flare in X-rays.
      const M = E.mass + 30;
      const a = 15.4, e = 0.9, nu = Math.PI * 0.8;
      const k = kepler(M, a, e, 0.2, nu);
      return [
        { ...E, pos: mulv(k.pos, -30 / M), vel: mulv(k.vel, -30 / M) },
        { type: 'star', name: 'Eta Carinae B', mass: 30, radiusSun: 20, teff: 37000,
          luminosity: 8.0e5, phase: phaseById('ms-mid').f,
          pos: mulv(k.pos, E.mass / M), vel: mulv(k.vel, E.mass / M) },
      ];
    },
  },

  hr_ladder: {
    sky: { env: 'globular', tilt: 0.36, roll: 0.9 },
    name: 'The Main Sequence, end to end',
    blurb: 'Eleven stars from 0.1 to 60 solar masses, every one of them burning hydrogen in its core — the same process, over a factor of 600 in mass. Everything else changes: the red dwarf at one end is 3000 K and will last ten trillion years; the O star at the other is 45 000 K, four hundred thousand times brighter, and will be gone in three million. Sizes are exaggerated here rather than true, because this is the one comparison where readability beats honesty; hit "Sizes: Real" to see what it actually looks like.',
    sceneScale: 1.0, bodyScale: 0.9, camRadius: 46, lensing: false, mesh: false,
    timeScale: 0.5, maxStep: 2e-3,
    build() {
      const masses = [0.1, 0.2, 0.4, 0.7, 1.0, 1.5, 2.5, 4, 9, 20, 60];
      const n = masses.length, R = 26;
      const specs = masses.map((m, i) => {
        const th = (i / n) * Math.PI * 2;
        return {
          type: 'star', name: `${m} M☉`, mass: m,
          luminosity: luminosity(m), teff: effectiveTemp(m),
          radiusSun: baseRadiusSun(m), phase: 0.5,
          pos: [Math.cos(th) * R, 0, Math.sin(th) * R], _th: th,
        };
      });
      // same exact circular-balance construction as starRing()
      for (const s of specs) {
        let ax = 0, az = 0;
        for (const o of specs) {
          if (o === s) continue;
          const dx = o.pos[0] - s.pos[0], dz = o.pos[2] - s.pos[2];
          const d2 = dx * dx + dz * dz, d = Math.sqrt(d2);
          ax += G * o.mass / d2 * dx / d; az += G * o.mass / d2 * dz / d;
        }
        const aRad = Math.max(-(ax * Math.cos(s._th) + az * Math.sin(s._th)), 1e-9);
        const v = Math.sqrt(aRad * R);
        s.vel = [-Math.sin(s._th) * v, 0, Math.cos(s._th) * v];
        delete s._th;
      }
      return specs;
    },
  },
};

export const PRESET_ORDER = ['stellar_zoo', 'sirius', 'vega', 'achernar', 'betelgeuse', 'alphacen', 'etacar', 'hr_ladder', 'trisolaris', 'trisolaris_wander', 'trisolaris_compact', 'trisolaris_wide', 'trisolaris_alpha', 'trisolaris_chaos', 'sandbox', 'solar', 'threebody', 'binarystar', 'bhmerger', 'nsmerger', 'feeding'];
