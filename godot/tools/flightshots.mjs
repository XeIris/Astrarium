// ============================================================================
// FLIGHT SHOTS — turns tools/flight_scenarios.json (the table the Godot
// harness tools/flighttest.gd flies) into a webref.mjs shot list, so the web
// build flies the SAME steps: one entry per ["shot"], each replaying its
// scenario from a fresh page up to that point.
//
//   node godot/tools/flightshots.mjs [scen,scen] > /abs/shots.json
//   PORT=8801 WEB_ROOT=<checkout with assets/*.glb> node godot/tools/webref.mjs /abs/shots.json /abs/out/
//
// The solar system is built with Math.random replaced by mulberry32(seed) —
// the same stream main.gd's `seed=` feeds Presets — so both skies, and the
// Moon's phase, are the same. Math.random is pinned to 0 while a vehicle is
// placed in orbit (its phase), matching the harness's `phase: 0`.
// ============================================================================
import { readFile } from 'node:fs/promises';

// TABLE=/abs/other.json flies another table of the same shape (a debugging set).
const table = JSON.parse(await readFile(process.env.TABLE || new URL('./flight_scenarios.json', import.meta.url), 'utf8'));
const only = process.argv[2] ? process.argv[2].split(',') : Object.keys(table.scenarios);

const PRELUDE = (seed) => `
  const mb = (a) => () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  const r0 = Math.random; Math.random = mb(${seed}); SIM.load('solar'); Math.random = r0;
  // The Earth map arrives asynchronously, and a setup that runs thousands of
  // SIM.frame()s back to back never yields to let it land — so whether the pad
  // stood on the mapped coast or on the procedural ground was a race with the
  // vehicle's .glb. The Godot harness loads maps synchronously; wait for it here.
  await new Promise(r => import('./sim/planetmaps.js').then(m => m.loadPlanetMap('Earth', r) || r()));
  SIM.setAppMode('flight');
  const F = () => SIM.flight;
  const frames = (n) => { for (let i = 0; i < n; i++) SIM.frame(1 / 60); };
`;

function stepJS(s) {
  switch (s[0]) {
    case 'launch': return `await SIM.launchCraft(${JSON.stringify(s[1])});`;
    case 'begin': return `{ const r = Math.random; Math.random = () => ${s[2].phase != null ? s[2].phase / 6.28 : 'r()'};
      F().begin(${JSON.stringify(s[1])}, ${JSON.stringify(s[2])}); Math.random = r; SIM.setCamMode('flight'); }`;
    case 'booster': return `{ const V = await import('./sim/flight/vehicles.js'); const f9 = V.VEHICLES.falcon9;
      V.VEHICLES.f9booster = { ...f9, id: 'f9booster', stages: [{ ...f9.stages[0], prop: 411000 * 0.15 }] }; }`;
    case 'init': return `{ const T = SIM.THREE, v = F().vessel, env = v.env, i = ${JSON.stringify(s[1])};
      const r = new T.Vector3(env.radius + i.alt, 0, 0), up = r.clone().normalize();
      const east = new T.Vector3().crossVectors(new T.Vector3(0, -1, 0), up).normalize();
      const surf = new T.Vector3(0, -env.rotRate, 0).cross(r);
      const vel = up.clone().multiplyScalar(i.vVert).addScaledVector(east, i.vHoriz).add(surf);
      const air = vel.clone().sub(surf).normalize().negate();
      v.r.copy(r); v.v.copy(vel); v.q.setFromUnitVectors(new T.Vector3(0, 1, 0), air); }`;
    case 'program': return `document.querySelector('#flightHud [data-prog="${s[1]}"]').click();`;
    case 'cam': return `F().setCameraMode(${JSON.stringify(s[1])});`;
    case 'warp': return `F().setWarp(${s[1]});`;
    case 'frames': return `frames(${s[1]});`;
    // Debug: fly on the procedural ground alone, without the Earth map.
    case 'nomap': return `F().localView.ground.material.uniforms.uEarthColor.value = null;`;
    case 'close': return `document.querySelector('[data-close="${s[1]}"]').click();`;
    default: return '';
  }
}

const TELEMETRY = `const f = SIM.flight, v = f.vessel, t = v ? v.telemetry : {};
  return { met: v?.met, alt: t.alt, speed: t.speed, q: t.q, mach: t.mach, thr: v?.throttle, mass: t.mass,
    apo: t.apo, peri: t.peri, phase: v?.phase, cam: f.cameraMode(), status: f.autopilot?.status,
    near: SIM.camera.near, fov: SIM.camera.fov };`;

const shots = [];
for (const key of only) {
  const steps = table.scenarios[key];
  steps.forEach((s, i) => {
    if (s[0] !== 'shot') return;
    let body = steps.slice(0, i).map(stepJS).join('\n');
    // The toast's lifetime is wall-clock, which the two runners do not share.
    if (s[2]) body += `\ndocument.getElementById('toast').style.display = 'none';`;
    shots.push({ name: s[1], mode: 'sandbox', freeze: true, frames: 0, wait: 300,
      hud: !!s[2], bare: !!s[2], setup: PRELUDE(table.seed) + body, dump: TELEMETRY });
  });
}
process.stdout.write(JSON.stringify(shots, null, 1));
