import { circularSpeed, G } from './physics.js';

// ============================================================================
// PRESET SCENARIOS
// Every spec is in REAL units: mass = M☉, pos = AU, vel = AU/yr.
// `sceneScale` = scene units per AU (rendering only). `bodyScale` exaggerates
// rendered body sizes (true-to-scale planets would be sub-pixel). `gwBoost`
// accelerates gravitational-wave inspiral so mergers are watchable.
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
    name: 'Black Hole Sandbox',
    blurb: 'A 10 M☉ black hole with a live accretion disc & lensing. Spawn bodies and watch them orbit, get shredded, and fall in.',
    sceneScale: 2.0, bodyScale: 1.0, camRadius: 24, lensing: true,
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
    name: 'Solar System (to scale)',
    blurb: 'Real orbital distances and masses, G = 4π². Inner planets cluster on the Sun — zoom way out to reach Pluto.',
    sceneScale: 1.0, bodyScale: 0.5, camRadius: 80, lensing: false, timeScale: 6,
    build() {
      const Ms = 1.0;
      const sun = { type: 'star', name: 'Sun', mass: Ms, color: 0xfff2cc, glow: 0xffaa33, pos: [0, 0, 0], vel: [0, 0, 0] };
      const P = (a, m, type, name, extra) => orbiter(Ms, a, { type, name, mass: m, ...extra });
      return [
        sun,
        P(0.387, 1.66e-7, 'planet', 'Mercury', { hot: true }),
        P(0.723, 2.45e-6, 'planet', 'Venus', { hot: true, atmosphere: true, atmColor: 0xffd9a0 }),
        P(1.000, 3.00e-6, 'planet', 'Earth', { atmosphere: true, seaLevel: 0.55 }),
        P(1.524, 3.21e-7, 'planet', 'Mars', { hot: true }),
        P(5.203, 9.54e-4, 'gas-giant', 'Jupiter', { palette: 'jupiter' }),
        P(9.537, 2.86e-4, 'gas-giant', 'Saturn', { palette: 'saturn', rings: true }),
        P(19.19, 4.37e-5, 'gas-giant', 'Uranus', { palette: 'ice' }),
        P(30.07, 5.15e-5, 'gas-giant', 'Neptune', { palette: 'ice' }),
        P(39.48, 6.55e-9, 'planet', 'Pluto', { hot: false }),
      ];
    },
  },

  // --------------------------------------------------------------------------
  threebody: {
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
  bhmerger: {
    name: 'Binary Black Hole Merger',
    blurb: 'Two stellar-mass black holes spiral together, shedding orbital energy to gravitational waves until they coalesce (à la GW150914). Inspiral rate exaggerated.',
    sceneScale: 60, bodyScale: 1.0, camRadius: 30, lensing: true, gwBoost: 3e10, timeScale: 0.15, maxStep: 5e-5,
    build() {
      return binary(36, 29, 0.45,
        { type: 'bh', name: 'BH-A', rs: 0.02 },
        { type: 'bh', name: 'BH-B', rs: 0.016 });
    },
  },

  // --------------------------------------------------------------------------
  nsmerger: {
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
    name: 'Black Hole Devouring a Star',
    blurb: 'A star on a plunging orbit is tidally stripped, trailing a stream of gas onto the black hole.',
    sceneScale: 2.0, bodyScale: 1.0, camRadius: 22, lensing: true,
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

export const PRESET_ORDER = ['sandbox', 'solar', 'threebody', 'binarystar', 'bhmerger', 'nsmerger', 'feeding'];
