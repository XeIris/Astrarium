// ============================================================================
// PHYSICS-CORE REFERENCE — the web build's numbers, for the Godot port to match.
// ----------------------------------------------------------------------------
//   node godot/tools/physref.mjs ref  <out.json>
//       Runs the web build's pure modules (sim/structure.js, starcat, presets,
//       edupresets, climate, scale, and the body-derivation + stepPhysics code
//       lifted VERBATIM out of blackhole_sim.js) over a wide spread of cases and
//       writes cases + results. godot/tools/physcheck.gd reads the same file,
//       recomputes every case in GDScript and writes its own; physdiff.mjs
//       compares the two.
//   node godot/tools/physref.mjs long <preset> <simYears> [fps]
//       Integrates a preset with the exact stepPhysics loop at its own time
//       scale, frame by frame, and prints relative energy drift, sub-steps and
//       wall time — the same run physcheck.gd does with mode=long.
//
// 'three' is mapped to godot/tools/three_stub.mjs by a resolve hook, so the web
// build is imported untouched. Math.random is replaced by a seeded Park–Miller
// generator (the same one physcheck.gd installs as Presets.rand_override), so
// the solar system's random orbital phases can be compared too.
// ============================================================================
import { register } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const stubURL = pathToFileURL(path.join(here, 'three_stub.mjs')).href;
register('data:text/javascript,' + encodeURIComponent(`
  export async function resolve(spec, ctx, next) {
    if (spec === 'three') return { url: ${JSON.stringify(stubURL)}, shortCircuit: true };
    return next(spec, ctx);
  }`));

// ---- deterministic Math.random -------------------------------------------
let seed = 1;
const pm = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };
Math.random = pm;
const reseed = (s) => { seed = s; };

const simURL = (f) => pathToFileURL(path.join(root, 'sim', f)).href;
const S = await import(simURL('structure.js'));
const PHYS = await import(simURL('physics.js'));
const ST = await import(simURL('stellar.js'));
const CAT = await import(simURL('starcat.js'));
const { PRESETS, PRESET_ORDER } = await import(simURL('presets.js'));
const { Climate } = await import(simURL('climate.js'));
const SCALE = await import(simURL('scale.js'));

// ---- lift the pure orchestrator code out of blackhole_sim.js --------------
const src = readFileSync(path.join(root, 'blackhole_sim.js'), 'utf8');
function block(startRe) {
  const m = src.match(startRe);
  if (!m) throw new Error('not found: ' + startRe);
  let i = src.indexOf('{', m.index), depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) break;
  }
  let end = i + 1;
  if (src[end] === ';') end++;
  return src.slice(m.index, end);
}
const lifted = [
  block(/^const BOOST_RADIUS = \{/m),
  'const _refRadius = new Map();',
  block(/^function referenceRadiusAU\(/m),
  block(/^function baseRadius\(/m),
  block(/^function renderRadius\(/m),
  block(/^const TYPE_DEFAULTS = \{/m),
  block(/^function discPeakTemp\(/m),
  block(/^function refreshStructure\(/m),
  block(/^function deriveBody\(/m),
  block(/^function getStars\(/m),
  block(/^function getHome\(/m),
  block(/^function dynamicStep\(/m),
  block(/^function stepPhysics\(/m),
  block(/^function totalEnergy\(/m),
].join('\n\n');
// attachVisual's destruction-distance statement, verbatim.
const contactLine = src.match(/^\s*b\.contactAU = [^;]+;/m)[0].trim();
// spawnBody's object literal, verbatim (the non-visual half).
const spawnLit = src.match(/function spawnBody\(spec\) \{[\s\S]*?const b = (\{[\s\S]*?\n  \});/)[1];

const modSrc = `
import * as THREE from 'three';
import * as PHYS from ${JSON.stringify(simURL('physics.js'))};
import { luminosity, effectiveTemp, radiusSun, blackbodyColor, spectralClass } from ${JSON.stringify(simURL('stellar.js'))};
import { structureOf, whiteDwarfRadiusSun, gravityDarkenedTemps, tovLimit, endStateOf, VERDICT, LIMITS } from ${JSON.stringify(simURL('structure.js'))};
import { physicalRadiusAU } from ${JSON.stringify(simURL('scale.js'))};
export const state = { sceneScale: 1, bodyScale: 1, trueScale: false, maxStep: 5e-3, gwBoost: 0,
  bodies: [], simYears: 0, lastSteps: 0, climate: null, homeId: null, nextId: 1, consumed: 0 };
// handleMerger's physics half only: the absorbed body leaves the list (removeBody).
function handleMerger(ev) { const i = state.bodies.indexOf(ev.absorbed); if (i >= 0) state.bodies.splice(i, 1); state.consumed++; }
function pushTrail() {}
${lifted}
export function newBody(spec) {
  const def = TYPE_DEFAULTS[spec.type] || TYPE_DEFAULTS.planet;
  const mass = spec.mass ?? def.mass;
  const b = ${spawnLit};
  deriveBody(b, spec);
  b.viz = { group: { position: new THREE.Vector3() } };
  return b;
}
export function attachContact(b) {
  const spec = b.spec;
  const radiusScene = renderRadius(b, spec, b.mass0);
  b.radiusScene = radiusScene;
  ${contactLine}
  return b;
}
export { referenceRadiusAU, baseRadius, renderRadius, discPeakTemp, deriveBody, refreshStructure,
         dynamicStep, stepPhysics, totalEnergy, getStars, getHome, TYPE_DEFAULTS, BOOST_RADIUS };
`;
const tmp = path.join(os.tmpdir(), `physref_orch_${process.pid}.mjs`);
writeFileSync(tmp, modSrc);
const O = await import(pathToFileURL(tmp).href);

// ---- JSON: Infinity/NaN as strings, undefined dropped, functions dropped ---
const clean = (v) => JSON.parse(JSON.stringify(v, (k, x) => {
  if (typeof x === 'number' && !Number.isFinite(x)) return Number.isNaN(x) ? 'NaN' : (x > 0 ? 'Infinity' : '-Infinity');
  if (typeof x === 'function') return undefined;
  if (x && x.isVector3) return [x.x, x.y, x.z];
  return x;
}));

// Godot's JSON parser loses precision on a long plain decimal such as
// 0.0000015013600345916377 (which is how JS writes anything >= 1e-7), but reads
// exponent notation exactly. So every non-integer is written as toExponential(),
// which is still the shortest round-trip representation.
function exactJSON(v) {
  if (typeof v === 'number') return (Number.isInteger(v) && Math.abs(v) < 1e15) ? String(v) : v.toExponential();
  if (Array.isArray(v)) return '[' + v.map(exactJSON).join(',') + ']';
  if (v && typeof v === 'object') return '{' + Object.entries(v).map(([k, x]) => JSON.stringify(k) + ':' + exactJSON(x)).join(',') + '}';
  return JSON.stringify(v);
}

// ---- loading a preset the way loadPreset does (physics half) --------------
function loadPreset(key, seedValue = 12345) {
  const p = PRESETS[key];
  reseed(seedValue);
  const st = O.state;
  st.sceneScale = p.sceneScale; st.bodyScale = p.bodyScale ?? 1; st.trueScale = !!p.trueScale;
  st.maxStep = p.maxStep ?? 5e-3; st.gwBoost = p.gwBoost ?? 0; st.timeScale = p.timeScale ?? 2;
  st.bodies = []; st.simYears = 0; st.homeId = null; st.nextId = 1; st.consumed = 0;
  const specs = p.build();
  for (const spec of specs) {
    const b = O.newBody(spec);
    b.id = st.nextId++;
    O.attachContact(b);
    if (spec.type === 'world' && spec.home) st.homeId = b.id;
    st.bodies.push(b);
  }
  st.climate = p.climate ? new Climate(p.climate) : null;
  if (st.climate) { const home = O.getHome(); if (home) st.climate.step(1e-6, home, O.getStars()); }
  return { p, specs };
}

const bodyOut = (b) => ({
  name: b.name, type: b.type, mass: b.mass, alive: b.alive, emitsGW: b.emitsGW,
  radius: b.radius, rs: b.rs, radiusSun: b.radiusSun, luminosity: b.luminosity, teff: b.teff,
  spectral: b.spectral, phase: b.phase, spinFrac: b.spinFrac, Z: b.Z, composition: b.composition,
  dayLength: b.dayLength, obliquity: b.obliquity, home: b.home,
  radiusScene: b.radiusScene, contactAU: b.contactAU, structure: b.structure,
});

// ============================================================================
function makeCases() {
  const ME = S.M_EARTH_SUN, MJ = S.M_JUP_SUN;
  const specs = [];
  const comps = ['earth', 'iron', 'mercury', 'silicate', 'ocean', 'ice', 'bogus', undefined];
  for (const mE of [0.001, 0.01, 0.1, 0.5, 1, 2, 5, 10, 50, 100, 300, 1000, 3000, 4200, 5000, 30000]) {
    for (const c of comps) specs.push({ type: 'planet', mass: mE * ME, composition: c });
  }
  for (const sf of [0, 0.3, 0.9, 0.999, 1.0, 1.1, 1.3])
    for (const t of ['planet', 'world', 'gas-giant']) specs.push({ type: t, mass: 300 * ME, spinFrac: sf });
  specs.push({ mass: 3e-6 }, { type: 'rocky', mass: 1e-5 }, { type: 'world', mass: 3e-6, Z: 0.0001 });
  for (const mJ of [0.001, 0.01, 0.1, 0.3, 1, 3.5, 5, 10, 13, 13.5, 20, 50, 70, 78, 80, 90, 100])
    for (const Z of [0.014, 0.001]) specs.push({ type: 'gas-giant', mass: mJ * MJ, Z });
  const phases = [-0.3, -0.15, 0, 0.1, 0.25, 0.5, 0.7, 0.85, 1, 1.05, 1.1, 1.2, 1.35, 1.45, 1.55, 1.7, 1.8, 1.9, 1.95, 2.0, 2.5, undefined];
  for (const m of [0.05, 0.078, 0.08, 0.1, 0.2, 0.43, 0.5, 1, 1.2, 1.5, 2, 2.2, 5, 8, 15, 20, 25, 40, 41, 60, 100, 121, 130, 145, 150, 200, 261, 400])
    for (const ph of phases) specs.push({ type: 'star', mass: m, phase: ph });
  for (const sf of [0, 0.02, 0.5, 0.88, 0.999, 1.1])
    for (const m of [0.3, 1, 2.1, 6.7, 30]) specs.push({ type: 'star', mass: m, spinFrac: sf, Z: 0.004 });
  for (const Z of [0.0001, 0.001, 0.004, 0.02, 0.05]) specs.push({ type: 'star', mass: 0.08, Z }, { type: 'star', mass: 3, Z, phase: 1.4 });
  for (const k of Object.keys(CAT.STAR_CATALOG)) specs.push(CAT.starSpec(k));
  for (const m of [0.2, 0.6, 1.0, 1.018, 1.3, 1.35, 1.4, 1.44, 1.5])
    for (const sf of [0, 0.5, 1.0]) specs.push({ type: 'white-dwarf', mass: m, spinFrac: sf }, { type: 'white-dwarf', mass: m, teff: 25200 });
  for (const m of [0.05, 0.1, 0.5, 1.0, 1.4, 2.0, 2.1, 2.2, 2.3, 2.5, 2.7])
    for (const sf of [0, 0.02, 0.03, 0.5, 1.0]) specs.push({ type: 'neutron', mass: m, spinFrac: sf });
  for (const m of [1, 10, 36, 65, 4e6])
    for (const sf of [0, 0.005, 0.05, 0.5, 0.9, 0.998, 1.1]) specs.push({ type: 'bh', mass: m, spinFrac: sf }, { type: 'bh', mass: m, spinFrac: sf, rs: 0.5 });

  const calls = [];
  const C = (fn, ...args) => calls.push({ fn, args });
  for (const c of ['earth', 'iron', 'mercury', 'silicate', 'ocean', 'ice']) {
    C('rockyMaxRadius', c);
    for (const m of [1e-9, 0.01, 1, 10, 300, 1e4]) C('rockyRadiusEarth', m, c);
  }
  for (const m of [1e-5, 0.01, 0.3, 1, 3.5, 10, 80]) C('giantRadiusJup', m);
  for (const m of [0.1, 0.6, 1.0, 1.018, 1.4, 1.44, 2]) C('whiteDwarfRadiusSun', m);
  for (const m of [0.01, 0.5, 1.4, 2.0, 2.2, 3]) C('neutronRadiusKm', m);
  for (const s of [-1, 0, 0.3, 1, 2]) C('tovLimit', s);
  for (const z of [0, 0.001, 0.014, 0.05]) C('hydrogenBurnLimit', z);
  for (const f of [-1, -0.15, -0.1, 0, 0.3, 0.5, 0.9, 1.0, 1.2, 1.5, 1.7, 1.9, 1.97, 2, 3]) C('phaseAt', f);
  for (const id of ['zams', 'agb', 'nope']) C('phaseById', id);
  for (const m of [0.01, 0.3, 0.43, 1, 1.99, 2, 10, 19.9, 20, 25, 33, 60, 100, 150, 250, 300, 500])
    for (const z of [0.014, 0.0001, 0.03]) C('baseLuminosity', m, z);
  for (const m of [0.01, 0.5, 1, 2, 50]) C('baseRadiusSun', m);
  for (const u of [0, 5e-4, 1e-3, 0.3, 0.88, 1, 1.5]) C('rocheShape', u);
  for (const r of [0.9, 1, 1.05, 1.193, 1.352, 1.5, 2]) C('inverseRocheShape', r);
  for (const [m, r, w, k] of [[1, 0.00465, 1e-6, 'star'], [3e-6, 4.26e-5, 7.29e-5, 'rocky'], [9.5e-4, 4.67e-4, 1.76e-4, 'giant'],
    [1.4, 8e-8, 2000, 'neutron'], [0.6, 5e-5, 0.01, 'wd'], [1, 1e-4, 1, 'iron'], [1, 1e-4, 1, 'weird']]) C('rotationalShape', m, r, w, k);
  for (const [m, r, k] of [[1, 0.00465, 'star'], [1, 0.00465, 'rocky'], [0.6, 5e-5, 'wd']]) C('breakupOmega', m, r, k);
  for (const t of [3000, 6999, 7000, 10000]) for (const s of [0, 0.5, 1]) C('gravityDarkeningBeta', t, s);
  for (const s of [0, 0.5, 0.88, 1]) for (const c of [0, 0.5, 1]) C('rocheGravity', s, c);
  for (const t of [4000, 9602, 15000]) for (const s of [0, 0.3, 0.88, 0.96, 1]) C('gravityDarkenedTemps', t, s);
  for (const [m, r, X, Z] of [[1, 1, 0.38, 0.014], [1, 1, 0.71, 0.014], [16.5, 764, 0, 0.014], [3e-6, 0.009, 0, 1]]) C('centralConditions', m, r, X, Z);
  for (const [t, r, m] of [[5772, 1, 1], [3600, 764, 16.5], [9602, 2.362, 2.135], [25200, 0.0084, 1.018]]) {
    C('pressureScaleHeightFrac', t, r, m); C('granuleFrequency', t, r, m);
  }
  for (const t of [100, 500, 3600, 5772, 9602, 40000, 1e6]) C('surfaceBrightness', t);
  for (const t of [1000, 2400, 3899, 3900, 5300, 5772, 7300, 9602, 10000, 33000, 54999, 55000, 80000]) {
    C('spectralType', t); C('spectralFull', t, 'V'); C('spectralFull', t, 'Ia');
  }
  for (const [r, m] of [[1, 1], [2, 1], [5, 1], [13, 1], [45, 1], [764, 16.5], [0.0084, 1.018]]) C('luminosityClass', r, m);
  for (const m of [0.5, 2, 7.9, 8, 19.9, 20, 100, 140, 260, 261]) C('endStateOf', m);
  for (const [X, Z] of [[0.71, 0.014], [0, 0.014], [0, 1]]) C('meanMolecularWeight', X, Z);
  for (const [m, L] of [[1, 1], [10, 0], [0.1, 1e-3]]) C('mainSequenceLifetime', m, L);
  C('eddingtonLuminosity', 3);
  for (const [t, m, r] of [['planet', 3e-6, undefined], ['world', 1e-4, 0], ['gas-giant', 1e-3, undefined], ['planet', 1e-12, undefined], ['planet', 1, 6371]])
    C('physicalRadiusAU', t, m, r ?? null);
  for (const [d, f, h] of [[1, 0.8, 1000], [1e-9, 1.2, 720], [0, 0.8, 900]]) { C('pixelsPerWorldUnit', d, f, h); C('apparentPixels', 1e-4, d, f, h); }
  for (const m of [0.01, 1, 10, 1e6]) C('discPeakTemp', m);
  for (const t of ['star', 'white-dwarf', 'neutron', 'gas-giant', 'world', 'planet', 'bh', 'unknown']) C('referenceRadiusAU', t);
  for (const [t, m, rs] of [['star', 1, null], ['star', 16.5, 764], ['planet', 3e-6, null], ['gas-giant', 0.01, null], ['neutron', 1.4, null], ['white-dwarf', 1, null], ['weird', 1, null]])
    C('baseRadius', t, m, rs);
  return { specs, calls };
}

const CALL = {
  rockyMaxRadius: S.rockyMaxRadius, rockyRadiusEarth: S.rockyRadiusEarth, giantRadiusJup: S.giantRadiusJup,
  whiteDwarfRadiusSun: S.whiteDwarfRadiusSun, neutronRadiusKm: S.neutronRadiusKm, tovLimit: S.tovLimit,
  hydrogenBurnLimit: S.hydrogenBurnLimit, phaseAt: S.phaseAt, phaseById: S.phaseById,
  baseLuminosity: S.baseLuminosity, baseRadiusSun: S.baseRadiusSun, rocheShape: S.rocheShape,
  inverseRocheShape: S.inverseRocheShape, rotationalShape: S.rotationalShape, breakupOmega: S.breakupOmega,
  gravityDarkeningBeta: S.gravityDarkeningBeta, rocheGravity: S.rocheGravity,
  gravityDarkenedTemps: S.gravityDarkenedTemps, centralConditions: S.centralConditions,
  pressureScaleHeightFrac: S.pressureScaleHeightFrac, granuleFrequency: S.granuleFrequency,
  surfaceBrightness: S.surfaceBrightness, spectralType: S.spectralType, spectralFull: S.spectralFull,
  luminosityClass: S.luminosityClass, endStateOf: S.endStateOf, meanMolecularWeight: S.meanMolecularWeight,
  mainSequenceLifetime: S.mainSequenceLifetime, eddingtonLuminosity: S.eddingtonLuminosity,
  physicalRadiusAU: (t, m, r) => SCALE.physicalRadiusAU(t, m, r ?? undefined),
  pixelsPerWorldUnit: SCALE.pixelsPerWorldUnit, apparentPixels: SCALE.apparentPixels,
  discPeakTemp: O.discPeakTemp, referenceRadiusAU: O.referenceRadiusAU,
  baseRadius: (t, m, rs) => O.baseRadius(null, rs == null ? { type: t } : { type: t, radiusSun: rs }, m),
};

// ---- the integration check: frames of a preset at its own pace ------------
function runFrames(key, frames, fps = 60, sample = 0) {
  const { p } = loadPreset(key);
  const st = O.state;
  const E0 = O.totalEnergy();
  let steps = 0, maxSteps = 0, capped = 0;
  const samples = [];
  const frameDt = (p.timeScale ?? 2) / fps;
  const t0 = performance.now();
  for (let f = 0; f < frames; f++) {
    const stepped = O.stepPhysics(frameDt);
    steps += st.lastSteps; maxSteps = Math.max(maxSteps, st.lastSteps);
    if (st.lastSteps >= 8000) capped++;
    if (sample && (f + 1) % sample === 0) {
      const cl = st.climate;
      samples.push({ f: f + 1, simYears: st.simYears, E: O.totalEnergy(), n: st.bodies.length,
        bodies: st.bodies.map(b => ({ name: b.name, pos: [b.pos.x, b.pos.y, b.pos.z], vel: [b.vel.x, b.vel.y, b.vel.z], mass: b.mass })),
        climate: cl ? { T: cl.T, S: cl.S, era: cl.era.key, ice: cl.ice, clouds: cl.clouds, humidity: cl.humidity, storm: cl.storm,
          time: cl.time, historyLen: cl.history.length, extremes: { ...cl.extremes }, perStar: cl.perStar.map(o => ({ ...o })), last: cl.history[cl.history.length - 1] } : null });
    }
  }
  const ms = performance.now() - t0;
  const E1 = O.totalEnergy();
  return { key, frames, fps, timeScale: p.timeScale ?? 2, simYears: st.simYears, bodies: st.bodies.length, consumed: st.consumed,
    E0, E1, drift: Math.abs((E1 - E0) / E0), steps, maxSteps, capped, ms, stepsPerSec: steps / (ms / 1000), samples };
}

// ---- standalone climate --------------------------------------------------
function climateCases() {
  const out = [];
  const mk = (x, L, name) => ({ name, mass: 1, luminosity: L, pos: new (class { constructor() { this.x = x; this.y = 0; this.z = 0; }
    distanceTo(o) { return Math.hypot(this.x - o.x, this.y - o.y, this.z - o.z); } })() });
  for (const opts of [{}, { mixedLayer: 5, T0: 200 }, { mixedLayer: 60, T0: 320, greenhouse: 0.7, albedoBase: 0.3, albedoIce: 0.3 }]) {
    const cl = new Climate(opts);
    const planet = mk(0, 0, 'P');
    const rows = [{ T: cl.T, tau: cl.tauYears, hc: cl.heatCapacity, c: cl.celsius }];
    for (const [d1, d2, dt] of [[1, 3, 0.01], [0.5, 2, 0.1], [0.3, 5, 1], [2, 1, 10], [1, 1, 0], [1, 1, -1], [1, 1, 0.003], [4, 0.2, 0.05]]) {
      const stars = [mk(d1, 1, 'A'), mk(-d2, 2.5, 'B')];
      cl.step(dt, planet, stars);
      rows.push({ T: cl.T, S: cl.S, era: cl.era.key, ice: cl.ice, clouds: cl.clouds, humidity: cl.humidity, storm: cl.storm,
        time: cl.time, hist: cl.history.length, ext: { ...cl.extremes }, perStar: cl.perStar.map(o => ({ ...o })), alb: cl.albedo(250), cls: cl.classify(cl.T).key, c: cl.celsius });
    }
    cl.reset(250);
    rows.push({ T: cl.T, S: cl.S, era: cl.era.key, ext: { ...cl.extremes }, hist: cl.history.length });
    out.push(rows);
  }
  return out;
}

// ---- edu_transit radial velocity (the one sciencecheck.js check that is
// purely presets + integrator): 5000 × 1e-5 yr of Verlet, star's reflex RV.
function transitRV() {
  loadPreset('edu_transit');
  const bs = O.state.bodies;
  const star = bs[0];
  let lo = Infinity, hi = -Infinity;
  const k = 1.495978707e11 / 3.15576e7;
  for (let i = 0; i < 5000; i++) {
    PHYS.integrate(bs, 1e-5);
    const rv = -star.vel.z * k;
    lo = Math.min(lo, rv); hi = Math.max(hi, rv);
  }
  return { K: (hi - lo) / 2, lo, hi };
}

// ============================================================================
const [mode, a1, a2, a3] = process.argv.slice(2);
if (mode === 'ref') {
  const { specs, calls } = makeCases();
  const out = { cases: { specs, calls } };
  out.structure = specs.map(s => S.structureOf(s));
  out.calls = calls.map(c => CALL[c.fn](...c.args));
  out.catalog = {};
  for (const k of Object.keys(CAT.STAR_CATALOG)) out.catalog[k] = CAT.starSpec(k, { extra: 1 });
  out.builders = {
    ring: CAT.starRing(['sun', 'vega', 'siriusB', 'betelgeuse'], 10, { phase: 0.3 }),
    ring0: CAT.starRing(['sun', 'proxima'], 1),
    binary: CAT.realBinary('siriusA', 'siriusB', { a: 7.4957, e: 0.5923 }),
    binary2: CAT.realBinary('alphacenA', 'alphacenB', { a: 23.52, e: 0.5179, incl: 0.14, nu: 1.1 }),
    companion: CAT.companion(2, 3, { name: 'x', mass: 1e-6 }, 0.7, 0.2),
  };
  out.presetOrder = PRESET_ORDER;
  out.presets = {};
  for (const key of PRESET_ORDER) {
    const { p, specs: bs } = loadPreset(key);
    const meta = {};
    for (const [k, v] of Object.entries(p)) if (typeof v !== 'function') meta[k] = v;
    const st = O.state;
    const bodies = st.bodies.map(b => {
      const o = bodyOut(b);
      // both size conventions
      o.rBoost = O.renderRadius.call(null, b, b.spec, b.mass0);
      st.trueScale = !st.trueScale; o.rOther = O.renderRadius(b, b.spec, b.mass0); st.trueScale = !st.trueScale;
      o.baseRadius = O.baseRadius(b, b.spec, b.mass0);
      return o;
    });
    out.presets[key] = { meta, specs: bs, bodies, E0: O.totalEnergy(), dyn: O.dynamicStep(),
      climate: st.climate ? { T: st.climate.T, S: st.climate.S, perStar: st.climate.perStar } : null };
  }
  out.climate = climateCases();
  out.frames = {};
  for (const key of ['trisolaris', 'trisolaris_wander', 'bhmerger', 'nsmerger', 'binarystar', 'threebody', 'solar', 'feeding', 'sandbox', 'edu_seasons', 'sirius'])
    out.frames[key] = runFrames(key, 240, 60, 60);
  out.transitRV = transitRV();
  // The published calibrations CLAUDE.md names, as numbers.
  const AUkm = PHYS.AU_PER_KM;
  const earth = S.rotationalShape(3.0035e-6, 6371.0 * AUkm, 7.2921159e-5, 'rocky');
  const jup = S.rotationalShape(9.5459e-4, 69911 * AUkm, 1.75853e-4, 'giant');
  const vega = S.structureOf(CAT.starSpec('vega'));
  const sun = S.structureOf({ type: 'star', mass: 1, phase: 0.5 });
  out.calibrations = {
    earthFlattening: earth.f, earthInvF: 1 / earth.f,
    jupiterFlattening: jup.f,
    siriusB_Rsun: S.whiteDwarfRadiusSun(1.018),
    iscoOverM_a0: S.structureOf({ type: 'bh', mass: 10 }).iscoAU / (S.structureOf({ type: 'bh', mass: 10 }).rs / 2),
    iscoOverM_a998: S.structureOf({ type: 'bh', mass: 10, spinFrac: 0.998 }).iscoAU / (S.structureOf({ type: 'bh', mass: 10 }).rs / 2),
    vegaSpinFrac: vega.spinFrac, vegaReOverRp: vega.radiusEqAU / vega.radiusPolarAU, vegaTPole: vega.tPole, vegaTEq: vega.tEq,
    sunTc: sun.Tc, sunPc: sun.Pc, sunRhoC: sun.rhoC, sunR: sun.radiusSun, sunL: sun.luminosity, sunTeff: sun.teff,
    rockyMaxRadiusEarth: S.rockyMaxRadius('earth').radiusEarth, rockyMaxMassEarth: S.rockyMaxRadius('earth').massEarth,
    earth1ME_Rearth: S.rockyRadiusEarth(1, 'earth'),
  };
  writeFileSync(a1, exactJSON(clean(out)));
  console.log(`wrote ${a1}: ${specs.length} structure cases, ${calls.length} calls, ${PRESET_ORDER.length} presets`);
} else if (mode === 'long') {
  const key = a1, years = parseFloat(a2), fps = parseFloat(a3 || '60');
  const p = PRESETS[key];
  const frames = Math.ceil(years / ((p.timeScale ?? 2) / fps));
  const r = runFrames(key, frames, fps, Math.max(1, Math.floor(frames / 10)));
  const series = r.samples.map(s => ({ yr: s.simYears, drift: Math.abs((s.E - r.E0) / r.E0), n: s.n }));
  delete r.samples;
  console.log(JSON.stringify({ ...r, series }, null, 1));
} else {
  console.log('usage: physref.mjs ref <out.json> | long <preset> <simYears> [fps]');
}
