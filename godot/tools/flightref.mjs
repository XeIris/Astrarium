// ============================================================================
// FLIGHT REFERENCE RUNNER — the web build's spaceflight model, flown headlessly
// in Node, as the numeric reference for the GDScript port (tools/flightcheck.gd).
//
//   node godot/tools/flightref.mjs [out.json]            run, write results
//   node godot/tools/flightref.mjs --fixture             (re)write the fixture only
//   THREE_MODULE=/path/three.module.js node godot/tools/flightref.mjs out.json
//                                    same, against the real three r160 — the
//                                    output must be identical to the stub's
//   node godot/tools/flightref.mjs --compare js.json gd.json
//                                    diff two result files, per scenario
//
// It imports the REAL modules — sim/flight/{rocketry,vehicles,orbit,vessel,
// guidance,relativity}.js — through a resolve hook that maps `three` onto
// tools/flight_three_stub.mjs (r160's own Vector3/Quaternion arithmetic, copied
// operation for operation). Nothing of the flight model is re-implemented here.
//
// What IS written here is the part of sim/flight/spaceflight.js that drives a
// vessel — begin(), the terminal count, setWarp()'s interlock, and update()'s
// sub-stepping — because spaceflight.js itself imports the renderer. Those few
// lines are transcribed verbatim, and tools/flightcheck.gd transcribes the same
// lines, so the two runners are one driver in two languages.
//
// THE SCENARIOS (the standing regression cases in CLAUDE.md, plus coverage):
//   saturnv / falcon9 / shuttle / starship  pad → count → ascent → insertion
//   lm          Apollo LM from a 15 km lunar orbit, program 'land' (P63/P64/P66)
//   f9booster   a Falcon 9 first stage alone, 70 km up, falling at 1 km/s with
//               200 m/s of drift and 15% of its propellant — program
//               'hoverslam' (entry burn on 3 engines, then the landing burn).
//               BP/BV/BH env vars override the three numbers for exploring.
//   skycrane    MSL at the entry interface its own `edl.entry` describes —
//               program 'edl' (chute, backshell, powered descent, sky crane)
//   skycrane_staged  the same, with a pilot pressing STAGE just before the
//               backshell separation. The program's own separation is a
//               jettison(), which drops the shell but lights nothing, so
//               without the pilot the descent stage never ignites.
//   lmdeorbit   the LM in a 110 km orbit, program 'deorbit' (node execution)
//   leo_rails   a vessel in LEO at 1000× warp — the universal-variable propagator
//   hailmary    the relativistic Cruise to Tau Ceti at 1 000 000×
// The orrery's bodies are FROZEN at the fixture's positions in both runners:
// the flight model reads them, it does not move them, and freezing them keeps
// the comparison about the port rather than about the n-body integrator.
// ============================================================================
import { registerHooks } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const THREE_URL = process.env.THREE_MODULE
  ? pathToFileURL(process.env.THREE_MODULE).href
  : new URL('./flight_three_stub.mjs', import.meta.url).href;
registerHooks({
  resolve(spec, ctx, next) {
    if (spec === 'three') return { url: THREE_URL, shortCircuit: true };
    return next(spec, ctx);
  },
});

const args = process.argv.slice(2);
if (args[0] === '--compare') { compare(args[1], args[2]); process.exit(0); }

const THREE = await import('three');
const R = await import('../../sim/flight/rocketry.js');
const VH = await import('../../sim/flight/vehicles.js');
const O = await import('../../sim/flight/orbit.js');
const VS = await import('../../sim/flight/vessel.js');
const GD = await import('../../sim/flight/guidance.js');
const RL = await import('../../sim/flight/relativity.js');
const { Vessel, PHASE } = VS;
const { Autopilot, MODE, attitudeFor } = GD;
const { VEHICLES } = VH;

// ---- exact double transport ---------------------------------------------------
const hex = (x) => { const b = Buffer.alloc(8); b.writeDoubleLE(x); return b.toString('hex'); };
const unhex = (h) => Buffer.from(h, 'hex').readDoubleLE(0);
const vhex = (v) => [hex(v.x), hex(v.y), hex(v.z)];
const num = (x) => (typeof x === 'number' && Number.isFinite(x) ? x : null);

// ============================================================================
// THE FIXTURE — the `solar` preset's bodies at FIXED phases (the preset draws
// them at random). Same construction as sim/presets.js: orbiter() for the
// planets, moonOf() for the Moon, radiusKm × AU_PER_KM for the radius.
// ============================================================================
const G = 4 * Math.PI * Math.PI;
const AU_PER_KM = 6.68459e-9;
const circularSpeed = (M, r) => Math.sqrt(G * M / r);
function orbiter(Mc, a, spec, angle) {
  const v = circularSpeed(Mc, a);
  const x = Math.cos(angle) * a, z = Math.sin(angle) * a;
  return { ...spec, pos: [x, 0, z], vel: [-Math.sin(angle) * v, 0, Math.cos(angle) * v] };
}
function moonOf(parentSpec, distM, massSun, radiusKm, name) {
  const AU_M = 1.495978707e11;
  const a = distM / AU_M;
  const [px, py, pz] = parentSpec.pos, [vx, vy, vz] = parentSpec.vel;
  const r = Math.hypot(px, pz) || 1;
  const ux = px / r, uz = pz / r;
  const vMoon = circularSpeed(parentSpec.mass + massSun, a);
  return { type: 'planet', name, mass: massSun, radiusKm,
    pos: [px + ux * a, py, pz + uz * a], vel: [vx + (-uz) * vMoon, vy, vz + ux * vMoon] };
}
function buildBodies() {
  const P = (a, m, radiusKm, type, name, ang) => orbiter(1.0, a, { type, name, mass: m, radiusKm }, ang);
  const earth = P(1.000, 3.00e-6, 6371.0, 'planet', 'Earth', 1.0);
  const specs = [
    { type: 'star', name: 'Sun', mass: 1.0, pos: [0, 0, 0], vel: [0, 0, 0], radiusAU: 0.00465047 },
    P(0.387, 1.66e-7, 2439.7, 'planet', 'Mercury', 4.1),
    P(0.723, 2.45e-6, 6051.8, 'planet', 'Venus', 2.6),
    earth,
    moonOf(earth, 3.844e8, 3.6923e-8, 1737.4, 'Moon'),
    P(1.524, 3.21e-7, 3389.5, 'planet', 'Mars', 2.2),
    P(5.203, 9.54e-4, 69911.0, 'gas-giant', 'Jupiter', 0.3),
    P(9.537, 2.86e-4, 58232.0, 'gas-giant', 'Saturn', 5.0),
    P(19.19, 4.37e-5, 25362.0, 'gas-giant', 'Uranus', 3.3),
    P(30.07, 5.15e-5, 24622.0, 'gas-giant', 'Neptune', 1.7),
    P(39.48, 6.55e-9, 1188.3, 'planet', 'Pluto', 5.9),
  ];
  return specs.map((s) => ({
    name: s.name, type: s.type, mass: s.mass,
    radius: s.radiusAU ?? s.radiusKm * AU_PER_KM, dayLength: 0,
    pos: s.pos, vel: s.vel,
  }));
}
function bodyObjects(fix) {
  return fix.map((b) => ({
    name: b.name, type: b.type, mass: b.mass, radius: b.radius, dayLength: b.dayLength, alive: true,
    pos: new THREE.Vector3(...b.pos), vel: new THREE.Vector3(...b.vel),
  }));
}

// ============================================================================
// THE DRIVER — transcribed from sim/flight/spaceflight.js
// ============================================================================
const WARPS = [1, 2, 5, 10, 50, 100, 1000, 10000, 100000, 1000000];
const EARTH_PADS = {
  starship: { lat: 25.99684, lon: -97.15523 },
  default: { lat: 28.608402, lon: -80.604201 },
};
const IGNITION_LEAD = { saturnv: 8.9, shuttle: 6.6, falcon9: 3.0, starship: 3.0 };

function morningLongitude(bodies, body) {
  const stars = bodies.filter((b) => b.type === 'star' || b.type === 'white-dwarf');
  const src = stars.reduce((a, b) => (b.mass > (a?.mass ?? -1) ? b : a), null);
  if (!src || src === body) return 0;
  const a = new THREE.Vector3().subVectors(src.pos, body.pos).normalize();
  const sub = Math.atan2(a.z, a.x) * 180 / Math.PI;
  return sub - 22;
}

// The derived vehicles some scenarios fly. A lone booster is the Falcon 9's own
// first stage with only its landing reserve in the tanks — the same spec object
// the ascent flies, so nothing about it is re-stated.
function vehicleFor(sc) {
  const veh = VEHICLES[sc.vehicle];
  if (!sc.stages) return veh;
  return {
    ...veh, id: sc.id,
    stages: sc.stages.map((i) => (sc.prop != null && i === sc.stages[0]
      ? { ...veh.stages[i], prop: sc.prop } : veh.stages[i])),
  };
}

function makeState(sc, fixBodies) {
  const bodies = bodyObjects(fixBodies);
  const home = bodies.find((b) => b.name === sc.body);
  const veh = vehicleFor(sc);
  const vessel = new Vessel({ vehicle: veh, parent: home, bodies, payload: veh.carries ? veh.carries.mass : 0 });
  const S = { sc, veh, vessel, bodies, ap: null, count: null, warpIdx: 0, cruise: null,
              boost: new THREE.Vector3(), best: { q: 0, met: 0, alt: 0 } };
  if (sc.place === 'pad') {
    const earthPad = home.name === 'Earth' ? (EARTH_PADS[sc.vehicle] || EARTH_PADS.default) : null;
    vessel.placeOnPad(earthPad?.lat ?? veh.target?.inclination ?? 28.5, morningLongitude(bodies, home));
  } else {
    vessel.placeInOrbit(sc.alt, sc.inc ?? 0, sc.phase ?? 0);
  }
  if (sc.init) {
    // An explicit initial state, carried in the fixture as exact doubles.
    vessel.r.set(...sc.init.r.map(unhex));
    vessel.v.set(...sc.init.v.map(unhex));
    vessel.q.set(...sc.init.q.map(unhex));
  }
  vessel.vehicleKey = sc.vehicle;
  S.ap = new Autopilot(vessel);
  S.ap.mode = MODE.PROGRADE;
  setWarp(S, 0);
  vessel.log(`${veh.name} — ${vessel.phase === PHASE.PRELAUNCH ? 'on the pad' : 'in flight'}, ${(VH.grossMass(veh) / 1000).toFixed(0)} t, ${(VH.totalDeltaV(veh) / 1000).toFixed(2)} km/s ideal Δv`);
  if (vessel.phase === PHASE.PRELAUNCH) {
    const twr = VH.liftoffThrust(veh, 101325) / (vessel.mass * vessel.env.gSurf);
    vessel.log(twr < 1
      ? `HOLD — liftoff thrust-to-weight is ${twr.toFixed(2)}. It will not leave the pad.`
      : `Liftoff TWR ${twr.toFixed(2)} · ${(VH.liftoffThrust(veh, 101325) / 1e6).toFixed(1)} MN`);
  }
  // runProgram()
  if (sc.program === 'cruise') { beginCruise(S); return S; }
  if (sc.program) {
    const ap = S.ap;
    ap.plan = null; ap.node = null; ap.site = null; ap.burning = false;
    ap.slamming = false; ap.entryDone = false; ap.shieldGone = false; ap.craneOut = false;
    if (sc.program === 'ascent' && vessel.phase === PHASE.PRELAUNCH) startCount(S, sc.count ?? 10);
    else ap.engage(sc.program);
  }
  return S;
}

function setWarp(S, i) {
  S.warpIdx = THREE.MathUtils.clamp(i, 0, WARPS.length - 1);
  const vessel = S.vessel;
  if (vessel && !S.cruise) {
    const railable = vessel.canRail();
    if (!railable && WARPS[S.warpIdx] > 4) {
      const capped = WARPS.reduce((best, v, i) => (v <= 4 ? i : best), 0);
      S.warpIdx = capped;
    }
  }
}

function startCount(S, T = 10) {
  const lead = IGNITION_LEAD[S.vessel.vehicleKey] ?? 4.0;
  S.count = { t: T, lead, lit: false, called: new Set() };
  S.vessel.heldDown = true;
  setWarp(S, 0);
  S.vessel.log(`T−${T.toFixed(0)} — terminal count`);
}
function stepCount(S, dtSim) {
  const count = S.count, vessel = S.vessel;
  if (!count) return;
  count.t -= dtSim;
  for (const mark of [8, 5, 3, 2, 1]) {
    if (count.t <= mark && !count.called.has(mark)) { count.called.add(mark); vessel.log(`T−${mark}`); }
  }
  if (!count.lit && count.t <= count.lead) {
    count.lit = true; vessel.throttle = 1; vessel.log('Ignition sequence start');
  }
  if (count.t <= 0) {
    S.count = null; vessel.heldDown = false; vessel.log('Hold-down release'); S.ap.engage('ascent');
  }
}

function beginCruise(S) {
  const vessel = S.vessel;
  const st = vessel.stages.find((s) => s.attached && s.spec.engine?.photon);
  const origin = vessel.parent.pos.clone().addScaledVector(vessel.r, 1 / R.AU_M);
  const tpos = origin.clone().add(new THREE.Vector3(11.9 * RL.LY_AU, 0, 0));
  const a = (st.spec.engine.holdAccel / R.G0) * R.G0;
  S.cruise = new RL.Cruise({
    origin, target: tpos, accel: a,
    dryMass: vessel.mass - st.prop, propMass: st.prop, exhaustMS: 299792458, name: vessel.name,
  });
  vessel.phase = PHASE.CRUISE;
  const p = S.cruise.plan;
  vessel.log(`Interstellar cruise — ${S.cruise.distLy.toFixed(2)} ly at ${(a / R.G0).toFixed(2)} g`);
  vessel.log(p.mode === 'flip'
    ? `Flip-and-burn: ${(p.tauS / R.YR_S).toFixed(2)} yr ship, ${(p.coordS / R.YR_S).toFixed(2)} yr coordinate`
    : `Accelerate–coast–decelerate: burn ${p.burnLy.toFixed(2)} ly, coast ${p.coastLy.toFixed(2)} ly, β ${p.betaMax.toFixed(4)} — ${(p.tauS / R.YR_S).toFixed(2)} yr ship, ${(p.coordS / R.YR_S).toFixed(2)} yr coordinate`);
  setWarp(S, WARPS.length - 1);
}

// The frame: spaceflight.js update(), minus everything that draws.
const _q = new THREE.Quaternion(), _b = new THREE.Vector3(), _a = new THREE.Vector3();
function frame(S, dt) {
  const vessel = S.vessel;
  const w = WARPS[S.warpIdx];
  const simSeconds = dt * w;
  if (S.cruise) {
    const cruise = S.cruise;
    cruise.step(simSeconds);
    cruise.position(_a);
    vessel.met = cruise.tau; vessel.coord = cruise.t;
    vessel.clockDelta = cruise.tau - cruise.t;
    const facing = cruise.leg === 'decel' ? -1 : 1;
    _q.setFromUnitVectors(new THREE.Vector3(0, 1, 0), _b.copy(cruise.dir).multiplyScalar(facing));
    vessel.q.slerp(_q, 1 - Math.exp(-dt * 1.4));
    RL.skyBoost(cruise.dir, cruise.beta, S.boost);
  } else {
    S.boost.set(0, 0, 0);
    if (S.count) stepCount(S, simSeconds);
    pilot(S);
    if (S.ap) S.ap.update(Math.min(dt, 0.1));
    const rails = w > 4 && vessel.canRail();
    if (rails) vessel.step(simSeconds, { rails: true });
    else {
      let rem = simSeconds, guard = 0;
      while (rem > 1e-6 && guard++ < 24) {
        const h = Math.min(rem, 0.5 * Math.max(w, 1));
        vessel.step(h);
        rem -= h;
      }
    }
    if (w > 4 && !vessel.canRail()) setWarp(S, 2);
  }
}

// A PILOT's hand on the staging button — the one scripted input any scenario
// makes. `pilotStage` stages once, just before the EDL program's own backshell
// separation would fire (it fires at 1.8 km or 100 m/s; this at 1.9 km or
// 105 m/s). See the skycrane_staged scenario for why a pilot is needed at all.
const _air = new THREE.Vector3();
function pilot(S) {
  const sc = S.sc, v = S.vessel;
  if (!sc.pilotStage || S.piloted || S.ap.stateName !== 'chute') return;
  const speed = v.airspeed(v.r, v.v, _air).length();
  if (v.altitude() < 1900 || speed < 105) { v.stage(); S.piloted = true; }
}

// The one policy the driver adds: which rung it ASKS for. Launches coast to
// apoapsis at `coastWarp` once the insertion loop is waiting; everything else
// asks for `warp`. setWarp's interlock decides what it actually gets.
function wantWarp(S) {
  const sc = S.sc, ap = S.ap, v = S.vessel;
  if (S.cruise) return WARPS.length - 1;
  if (sc.coastWarp && ap.program === 'circularize' && v.throttle === 0) return WARPS.indexOf(sc.coastWarp);
  return WARPS.indexOf(sc.warp ?? 1);
}

function done(S) {
  const v = S.vessel, sc = S.sc;
  if (S.cruise) return S.cruise.leg === 'arrived';
  if (v.phase === PHASE.DESTROYED || v.phase === PHASE.LANDED) return true;
  if (sc.until === 'orbit') return S.ap.program === null && v.phase === PHASE.ORBIT && !S.count;
  return false;
}

function sampleOf(S, f) {
  const v = S.vessel, t = v.telemetry, ap = S.ap;
  if (S.cruise) {
    const c = S.cruise;
    return { f, tau: c.tau, t: c.t, phi: c.phi, s: c.s, prop: c.prop, leg: c.leg,
             q: [v.q.x, v.q.y, v.q.z, v.q.w], boost: [S.boost.x, S.boost.y, S.boost.z] };
  }
  return {
    f, met: v.met, coord: v.coord, clockDelta: v.clockDelta,
    r: [v.r.x, v.r.y, v.r.z], v: [v.v.x, v.v.y, v.v.z], quat: [v.q.x, v.q.y, v.q.z, v.q.w],
    alt: num(t.alt), speed: num(t.speed), q: num(t.q), mach: num(t.mach), gees: num(t.gees),
    thr: v.throttle, mass: num(t.mass), apo: num(t.apo), peri: num(t.peri), ecc: num(t.ecc),
    inc: num(t.inc), dv: num(t.dv), downrange: num(t.downrange), heat: num(t.heat),
    phase: v.phase, prog: ap.program, st: ap.stateName ?? null, status: ap.status,
    parent: v.parent.name, warp: WARPS[S.warpIdx],
  };
}

function run(sc, fixBodies, dt) {
  const S = makeState(sc, fixBodies);
  const samples = [];
  const maxFrames = sc.maxFrames ?? 60000;
  const every = sc.every ?? 300;
  let f = 0;
  const t0 = performance.now();
  for (; f < maxFrames; f++) {
    setWarp(S, wantWarp(S));
    frame(S, dt);
    const v = S.vessel;
    if (!S.cruise && v.maxQ > S.best.q) S.best = { q: v.maxQ, met: v.met, alt: v.telemetry.alt };
    if (f % every === 0) samples.push(sampleOf(S, f));
    if (done(S)) break;
  }
  const wall = performance.now() - t0;
  samples.push(sampleOf(S, f));
  const v = S.vessel, t = v.telemetry;
  const summary = {
    frames: f, phase: v.phase, failure: v.failure, met: v.met, coord: v.coord,
    clockDelta: v.clockDelta, mass: v.mass, maxQ: v.maxQ, maxQMet: S.best.met, maxQAlt: S.best.alt,
    maxG: v.maxG, heatLoad: v.heatLoad, peakHeat: v.peakHeat,
    apo: num(t.apo), peri: num(t.peri), inc: num(t.inc), ecc: num(t.ecc),
    landedAt: v.landedAt, parent: v.parent.name, wallMs: wall,
  };
  const geared = v.stages.find((s) => s.attached && s.spec.legs);
  summary.gear = geared ? geared.spec.gear ?? null : null;
  if (S.cruise) {
    const ro = S.cruise.readout();
    summary.cruise = { ...ro, plan: undefined, log: S.cruise.log.map((e) => [e.tau, e.m]) };
    summary.plan = S.cruise.plan;
  }
  if (sc.plan) {
    // The transfer planner, asked from wherever the run ended.
    const tgt = S.bodies.find((b) => b.name === sc.plan);
    const p = S.ap.planTransfer(tgt);
    summary.transfer = p;
  }
  return { summary, samples, events: v.events.map((e) => [e.t, e.msg]) };
}

// ============================================================================
// PURE-FUNCTION SPOT CHECKS — every exported helper at a spread of inputs
// ============================================================================
function spot(fixBodies) {
  const out = {};
  const bodies = bodyObjects(fixBodies);
  for (const b of bodies) {
    const e = R.flightEnv(b);
    out['env_' + b.name] = { mu: e.mu, radius: e.radius, gSurf: e.gSurf, rotRate: e.rotRate, vRotEq: e.vRotEq,
      daySec: e.daySec, vEsc: e.vEsc, vCirc: e.vCirc, karman: e.karman, hasAtm: !!e.atm,
      atm: e.atm ? { p0: e.atm.p0, rho0: e.atm.rho0, T0: e.atm.T0, top: e.atm.top } : null };
  }
  const atmE = R.flightEnv(bodies.find((b) => b.name === 'Earth')).atm;
  const atmM = R.flightEnv(bodies.find((b) => b.name === 'Mars')).atm;
  const rows = [];
  for (const h of [-100, 0, 500, 5000, 11000, 12500, 20000, 32000, 45000, 50000, 80000, 139999, 140000, 2e5]) {
    rows.push([h, R.density(atmE, h), R.pressure(atmE, h), R.temperature(atmE, h), R.scaleHeight(atmE, h),
      R.speedOfSound(atmE, h), R.density(atmM, h), R.pressure(atmM, h), R.scaleHeight(atmM, h)]);
  }
  out.atmosphere = rows;
  out.cd = [0, 0.5, 0.8, 0.95, 1.1, 1.25, 1.4, 2.5, 4, 8, 40].map((M) => [M, R.dragCoefficient(M), R.bluntDragCoefficient(M)]);
  out.heat = [[1e-4, 7800, 1], [0.01, 5500, 0.02], [0, 1000, 1]].map(([rho, v, rn]) => R.heatFlux(rho, v, rn));
  out.solid = [0, 0.02, 0.1, 0.3, 0.5, 0.9, 1, 1.2].map((x) => R.solidThrustFraction(x));
  out.engine = [];
  for (const [k, eng] of Object.entries(VH.ENGINES)) {
    for (const [n, pa, th, burned] of [[1, 101325, 1, 0], [3, 50000, 0.7, 0.3], [2, 0, 0.05, 0.9], [1, 0, 0, 0]]) {
      const o = R.engineOutput(eng, n, pa, th, burned);
      out.engine.push([k, n, pa, th, o.F, o.mdot, o.isp, o.throttle]);
    }
  }
  out.burnTime = [R.burnTimeFor(1000, 5e5, 1e6, 350), R.burnTimeFor(0, 1, 1, 1), R.burnTimeFor(3137, 140000, 1033e3, 421)];
  out.vehicles = {};
  for (const k of VH.VEHICLE_ORDER) {
    const v = VEHICLES[k];
    out.vehicles[k] = { gross: VH.grossMass(v), dv: VH.totalDeltaV(v), twr: VH.padTWR(v), F: VH.liftoffThrust(v),
      stageDv: v.stages.map((_, i) => VH.stageDeltaV(v, i)), areas: v.stages.map((s) => s.area) };
  }
  // orbit.js
  const mu = 3.986e14;
  const cases = [
    [[6.771e6, 0, 0], [0, 0, 7672]], [[7e6, 1e5, -2e5], [100, -300, 8200]],
    [[6.6e6, 0, 0], [0, 2000, 11200]], [[4e7, 3e6, 1e6], [-200, 50, 3000]],
    [[6.5e6, 0, 1e5], [0, 0, 11050]],
  ];
  out.orbit = cases.map(([r, v]) => {
    const rv = new THREE.Vector3(...r), vv = new THREE.Vector3(...v);
    const el = O.elements(rv, vv, mu);
    const res = { el: Object.fromEntries(Object.entries(el).map(([k, x]) => [k, num(x)])) };
    res.tApo = num(O.timeToApoapsis(el, mu)); res.tPeri = num(O.timeToPeriapsis(el, mu));
    res.circ = num(O.circularizeDv(el, mu));
    for (const dt of [60, 1800, 86400, -900]) {
      const ro = new THREE.Vector3(), vo = new THREE.Vector3();
      const ok = O.propagate(rv, vv, mu, dt, ro, vo);
      res['p' + dt] = [ok, ro.x, ro.y, ro.z, vo.x, vo.y, vo.z];
    }
    return res;
  });
  out.stumpff = [-50, -1, -1e-7, 0, 1e-7, 1, 30].map((z) => [O.stumpffC(z), O.stumpffS(z)]);
  out.hohmann = [O.hohmann(3.986e14, 6.671e6, 4.2164e7), O.hohmann(1.32712440018e20, 1.496e11, 2.279e11)];
  out.soi = [O.sphereOfInfluence(3.844e8, 3.69e-8, 3e-6), O.sphereOfInfluence(0, 1, 1)];
  out.phase = O.phaseAngle(new THREE.Vector3(1, 0, 0), new THREE.Vector3(-1, 0, -0.1));
  // relativity.js
  out.rel = {
    budget: RL.rapidityBudget(1e5, 2e6, 299792458),
    tau: RL.solveProfile(11.9, 1.5 * 9.80665, RL.rapidityBudget(1e5, 2e6, 299792458)),
    flip: RL.solveProfile(4.246, 9.80665, 10),
    short: RL.solveProfile(11.9, 9.80665, 0.1),
    doppler: [RL.dopplerFactor(0.5, 1), RL.dopplerFactor(0.9, -0.3)],
    cone: RL.aberrationCone(0.9), beta: RL.betaOf(1.2), gamma: RL.gammaOf(1.2), rap: RL.rapidityOf(0.99),
    years: [1e-4, 0.5, 13.9, 5000, 3e7, Infinity].map(RL.fmtYears),
  };
  out.fmtDur = [0, 59.9, 3725, 90061, -45, Infinity].map(GD.fmtDur);
  return out;
}

// ============================================================================
// THE SCENARIO LIST, with any explicit initial states resolved to exact bits
// ============================================================================
function scenarioList(fixBodies) {
  const list = [
    { id: 'saturnv', vehicle: 'saturnv', body: 'Earth', place: 'pad', program: 'ascent', until: 'orbit', coastWarp: 10, maxFrames: 150000 },
    { id: 'falcon9', vehicle: 'falcon9', body: 'Earth', place: 'pad', program: 'ascent', until: 'orbit', coastWarp: 10, maxFrames: 150000 },
    { id: 'shuttle', vehicle: 'shuttle', body: 'Earth', place: 'pad', program: 'ascent', until: 'orbit', coastWarp: 10, maxFrames: 150000 },
    { id: 'starship', vehicle: 'starship', body: 'Earth', place: 'pad', program: 'ascent', until: 'orbit', coastWarp: 10, maxFrames: 150000 },
    { id: 'lm', vehicle: 'lm', body: 'Moon', place: 'orbit', alt: 15000, inc: 0, phase: 0, program: 'land', maxFrames: 60000 },
    { id: 'f9booster', vehicle: 'falcon9', stages: [0], prop: 411000 * Number(process.env.BP ?? 0.15), body: 'Earth', place: 'orbit', alt: 70000,
      init: { alt: 70000, vVert: Number(process.env.BV ?? -1000), vHoriz: Number(process.env.BH ?? 200), attitude: 'retro-air' }, program: 'hoverslam', maxFrames: 60000 },
    { id: 'skycrane', vehicle: 'skycrane', body: 'Mars', place: 'orbit', alt: 125000,
      init: { alt: 125000, vInertial: 5800, fpaDeg: -15.5, attitude: 'retro-air' }, program: 'edl', maxFrames: 60000 },
    { id: 'skycrane_staged', vehicle: 'skycrane', body: 'Mars', place: 'orbit', alt: 125000, pilotStage: true,
      init: { alt: 125000, vInertial: 5800, fpaDeg: -15.5, attitude: 'retro-air' }, program: 'edl', maxFrames: 60000 },
    { id: 'lmdeorbit', vehicle: 'lm', body: 'Moon', place: 'orbit', alt: 110000, inc: 0, phase: 1.0, program: 'deorbit', maxFrames: 900 * 30 },
    { id: 'leo_rails', vehicle: 'falcon9', body: 'Earth', place: 'orbit', alt: 250000, inc: 28.5, phase: 0.4, warp: 1000, maxFrames: 3000, every: 100, plan: 'Moon' },
    { id: 'hailmary', vehicle: 'hailmary', body: 'Earth', place: 'orbit', alt: 250000, inc: 0, phase: 0, program: 'cruise', maxFrames: 40000, every: 500 },
  ];
  const bodies = bodyObjects(fixBodies);
  for (const sc of list) {
    if (!sc.init) continue;
    const home = bodies.find((b) => b.name === sc.body);
    const env = R.flightEnv(home);
    const i = sc.init;
    const Rr = env.radius + i.alt;
    const r = new THREE.Vector3(Rr, 0, 0);
    const up = r.clone().normalize();
    const east = new THREE.Vector3().crossVectors(new THREE.Vector3(0, -1, 0), up).normalize();
    const surf = new THREE.Vector3(0, -env.rotRate, 0).cross(r);
    let v;
    if (i.vInertial != null) {
      const f = i.fpaDeg * Math.PI / 180;
      v = up.clone().multiplyScalar(i.vInertial * Math.sin(f)).addScaledVector(east, i.vInertial * Math.cos(f));
    } else {
      v = up.clone().multiplyScalar(i.vVert).addScaledVector(east, i.vHoriz).add(surf);
    }
    const air = v.clone().sub(surf).normalize().negate();
    const q = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), air);
    sc.init = { ...i, r: vhex(r), v: vhex(v), q: [hex(q.x), hex(q.y), hex(q.z), hex(q.w)] };
  }
  return list;
}

// ============================================================================
function main() {
  const fixDir = `${HERE}/fixtures`;
  mkdirSync(fixDir, { recursive: true });
  const fixBodies = buildBodies();
  const scenarios = scenarioList(fixBodies);
  const dt = process.env.DT ? 1 / Number(process.env.DT) : 1 / 30;
  const fixture = {
    note: 'Generated by tools/flightref.mjs. Doubles are carried as little-endian IEEE-754 hex (h) beside their decimal value.',
    dt: hex(dt),
    bodies: fixBodies.map((b) => ({ ...b, h: { mass: hex(b.mass), radius: hex(b.radius), pos: b.pos.map(hex), vel: b.vel.map(hex) } })),
    scenarios,
  };
  writeFileSync(`${fixDir}/flight_fixture.json`, JSON.stringify(fixture, null, 1));
  if (args[0] === '--fixture') { console.log('fixture written'); return; }
  const only = process.env.ONLY ? process.env.ONLY.split(',') : null;
  const results = { runner: 'js', three: process.env.THREE_MODULE ? 'real' : 'stub', spot: spot(fixBodies), scenarios: {} };
  for (const sc of scenarios) {
    if (only && !only.includes(sc.id)) continue;
    const res = run(sc, fixBodies, dt);
    results.scenarios[sc.id] = res;
    const s = res.summary;
    console.log(`${sc.id.padEnd(10)} ${s.phase.padEnd(9)} met ${s.met.toFixed(1)} s  frames ${s.frames}  ` +
      `maxQ ${(s.maxQ / 1000).toFixed(2)} kPa @ ${s.maxQMet.toFixed(1)} s  apo/peri ${s.apo != null ? (s.apo / 1000).toFixed(1) : '—'}/${s.peri != null ? (s.peri / 1000).toFixed(1) : '—'} km  ` +
      `inc ${s.inc?.toFixed(2)}  ${s.landedAt ? `touchdown ${s.landedAt.vVert.toFixed(2)} / ${s.landedAt.vHoriz.toFixed(2)} m/s` : ''} ${s.failure ?? ''} (${s.wallMs.toFixed(0)} ms)`);
  }
  const outPath = args[0] || `${HERE}/fixtures/flight_js.json`;
  writeFileSync(outPath, JSON.stringify(results));
  console.log('wrote', outPath);
}
main();

// ============================================================================
// COMPARISON — max deviation per scenario between two result files
// ============================================================================
function compare(pa, pb) {
  const A = JSON.parse(readFileSync(pa, 'utf8')), B = JSON.parse(readFileSync(pb, 'utf8'));
  const rel = (a, b) => (a === b ? 0 : Math.abs(a - b) / Math.max(Math.abs(a), Math.abs(b), 1e-300));
  function walk(a, b, path, acc) {
    if (typeof a === 'number' && typeof b === 'number') {
      const d = rel(a, b);
      if (d > acc.max) { acc.max = d; acc.at = path; acc.a = a; acc.b = b; }
      if (d > 0) acc.nonzero++;
      acc.n++;
    } else if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) acc.shape.push(`${path}: length ${a.length} vs ${b.length}`);
      for (let i = 0; i < Math.min(a.length, b.length); i++) walk(a[i], b[i], `${path}[${i}]`, acc);
    } else if (a && b && typeof a === 'object' && typeof b === 'object') {
      for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
        if (!(k in a) || !(k in b)) { if (k !== 'wallMs') acc.shape.push(`${path}.${k}: missing on one side`); continue; }
        if (k === 'wallMs') continue;
        walk(a[k], b[k], `${path}.${k}`, acc);
      }
    } else if (a !== b) {
      acc.diff.push(`${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
    }
  }
  const report = (name, a, b) => {
    const acc = { max: 0, at: '', n: 0, nonzero: 0, shape: [], diff: [] };
    walk(a, b, name, acc);
    console.log(`${name.padEnd(12)} numbers ${acc.n}, differing ${acc.nonzero}, max rel dev ${acc.max.toExponential(2)}${acc.at ? ` at ${acc.at} (${acc.a} vs ${acc.b})` : ''}`);
    for (const s of acc.shape.slice(0, 6)) console.log('   shape:', s);
    for (const s of acc.diff.slice(0, 6)) console.log('   diff: ', s);
  };
  report('spot', A.spot, B.spot);
  for (const k of Object.keys(A.scenarios)) {
    if (!B.scenarios[k]) { console.log(`${k}: missing in ${pb}`); continue; }
    report(k, A.scenarios[k], B.scenarios[k]);
  }
}
