import { circularSpeed, rocheLimit, G } from './physics.js';
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
};

export const PRESET_ORDER = ['trisolaris', 'trisolaris_wander', 'trisolaris_compact', 'trisolaris_wide', 'trisolaris_alpha', 'trisolaris_chaos', 'sandbox', 'solar', 'threebody', 'binarystar', 'bhmerger', 'nsmerger', 'feeding'];
