// ============================================================================
// FOUNDRY / CROSS-SECTION reference set — the web half of foundrytest.gd.
//
//   node godot/tools/foundrytest.shots.mjs /tmp/fd/shots.json
//   PORT=8803 WEB_ROOT=<checkout> node godot/tools/webref.mjs /tmp/fd/shots.json /tmp/fd/web
//   Godot --path godot res://tools/foundrytest.tscn -- fix=/tmp/fd/web state=<name> out=/tmp/fd/godot/<name>.png
//
// Every shot isolates ONE panel on the page background, at a fixed place, so
// the Godot harness can rebuild the same box around the same component:
//   xsec_*  the real #xsecPanel (cross-section + live editor), pointed at a
//           focused body, moved to (20, 20) with its max-height lifted;
//   fd_*    the Object Foundry mount (#foundry) moved into a bare 300 px
//           `.hud.panel` at (20, 20), after driving its controls.
// The dump (<name>.json) carries what the Godot side needs to reproduce it:
// the structureOf query refreshStructure builds for the body, the body's own
// fields for the live editor, the Foundry's draft, and the measured rects.
// ============================================================================
import { writeFile } from 'node:fs/promises';

const isolate = sel => `
  const P = document.querySelector(${JSON.stringify(sel)});
  for (const e of document.body.children) if (e !== P && e.tagName !== 'SCRIPT') e.style.display = 'none';
  P.style.visibility = 'visible';
  P.style.top = '20px'; P.style.left = '20px'; P.style.right = 'auto'; P.style.maxHeight = 'none';`;

const pick = n => `SIM.state.bodies.find(b => b.name.includes(${JSON.stringify(n)}))`;

// open the cross-section on a body (optionally after editing it)
const xsec = (preset, name, edit, focus, pre = '') => `
  SIM.load(${JSON.stringify(preset)}); ${pre}
  let b = ${name ? pick(name) : 'SIM.state.bodies[0]'};
  ${edit ? `SIM.editBody(b, ${JSON.stringify(edit)}); b = SIM.state.bodies.find(x => x.id === b.id);` : ''}
  SIM.setFollow(b);
  document.getElementById('xsecOpen').click();
  ${focus ? `document.getElementById('leFocus').click();` : ''}
  ${isolate('#xsecPanel')}`;

// build a foundry state
const fd = (type, massLog, extra = {}) => `
  SIM.load('blank');
  const FP = document.createElement('div');
  FP.className = 'hud panel'; FP.id = 'fdTest';
  FP.style.cssText = 'top:20px;left:20px;right:auto;width:300px;max-height:none;';
  document.body.appendChild(FP);
  FP.appendChild(document.getElementById('foundry'));
  SIM.foundry.setType(${JSON.stringify(type)});
  const set = (id, v) => { const e = document.getElementById(id); e.value = String(v); e.dispatchEvent(new Event(e.tagName === 'SELECT' ? 'change' : 'input')); };
  ${massLog != null ? `set('fdMass', ${massLog});` : ''}
  ${Object.entries(extra).map(([k, v]) => `set(${JSON.stringify(k)}, ${JSON.stringify(v)});`).join('\n')}
  ${isolate('#fdTest')}`;

const rects = `
  const rect = el => { if (!el) return null; const r = el.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; };
  const R = {};
  for (const id of ['xsecPanel', 'fdTest', 'xsecCanvas', 'xsecLegend', 'xsecVerdict', 'xsecFacts', 'xsecNotes', 'leCurve',
    'fdXsec', 'fdLegend', 'fdVerdict', 'fdFacts', 'fdLayerNote', 'fdSpawn', 'fdTypes', 'liveEdit', 'fdComp', 'leComp', 'leFocus', 'leNear', 'xsecName'])
    R[id] = rect(document.getElementById(id));`;

const dumpXsec = `${rects}
  const b = SIM.state.bodies.find(x => x.id === SIM.state.focusId);
  return {
    rects: R,
    body: { id: b.id, name: b.name, type: b.type, mass: b.mass, spinFrac: b.spinFrac ?? 0, phase: b.phase ?? null,
      composition: b.composition ?? null, Z: b.Z ?? null },
    q: { type: b.type, mass: b.mass, spinFrac: b.spinFrac ?? 0, phase: b.phase ?? null, composition: b.composition ?? null,
      Z: b.Z ?? null, radiusSun: b.radiusSun ?? null, teff: b.spec?.teff ?? null, luminosity: b.spec?.luminosity ?? null,
      radiusKm: b.spec?.radiusKm ?? null, rs: b.rs ?? null },
    label: b.structure?.label ?? null,
    focus: document.getElementById('leFocus').classList.contains('on'),
    near: document.getElementById('leNear').textContent,
    facts: [...document.querySelectorAll('#xsecFacts > div')].map(d => d.textContent),
    verdict: document.getElementById('xsecVerdict').textContent,
  };`;

const dumpFd = `${rects}
  const f = SIM.foundry;
  return {
    rects: R,
    draft: { ...f.draft }, type: [...document.querySelectorAll('[data-fdtype].active')].map(e => e.dataset.fdtype)[0],
    slider: { mass: +document.getElementById('fdMass').value, spin: +document.getElementById('fdSpin').value,
      phase: +document.getElementById('fdPhase').value, Z: +document.getElementById('fdZ').value,
      comp: document.getElementById('fdComp').value },
    facts: [...document.querySelectorAll('#fdFacts > div')].map(d => d.textContent),
    verdict: document.getElementById('fdVerdict').textContent,
    // what the Spawn button actually hands the scene: click it and read the
    // spawned body's spec back (after the capture, so the shot is unaffected)
    spawn: (() => {
      const n = SIM.state.bodies.length;
      document.getElementById('fdSpawn').click();
      const b = SIM.state.bodies[SIM.state.bodies.length - 1];
      if (SIM.state.bodies.length === n || !b) return null;
      const s = { ...b.spec };
      for (const k of ['pos', 'vel', 'seed', 'atmosphere']) delete s[k];
      return s;
    })(),
  };`;

// the 3D cutaway on its own canvas (320 × 210, as the lesson card sizes it),
// at a fixed turntable angle, with its legend under it
const cut = spec => `
  SIM.load('blank');
  const { createCutaway } = await import('./sim/cutaway.js');
  const { structureOf } = await import('./sim/structure.js');
  const cv = document.createElement('canvas'); cv.width = 320; cv.height = 210;
  cv.style.cssText = 'position:fixed;left:20px;top:20px;width:320px;height:210px;background:rgba(4,6,10,0.55);z-index:50';
  const lg = document.createElement('div'); lg.className = 'cut-legend';
  lg.style.cssText = 'position:fixed;left:20px;top:230px;width:320px;max-height:none;z-index:50';
  for (const e of document.body.children) if (e.tagName !== 'SCRIPT') e.style.display = 'none';
  document.body.appendChild(cv); document.body.appendChild(lg);
  const c = createCutaway({ canvas: cv }); c.setSpin(false); c.nudge(0.6);
  window.__q = ${JSON.stringify(spec)};
  c.show(structureOf(window.__q)); c.render(0);
  lg.innerHTML = c.legend();
  window.__cut = c;`;
const dumpCut = `return { q: window.__q, legend: [...document.querySelectorAll('.cut-row')].map(r => r.textContent.replace(/\\s+/g, ' ').trim()) };`;

const H = 1400;
const shots = [
  { name: 'xsec_sun', setup: xsec('solar', 'Sun') },
  { name: 'xsec_redgiant', setup: xsec('solar', 'Sun', { phase: 1.35 }) },
  { name: 'xsec_presn', setup: xsec('blank', 'Doomed', null, false, `SIM.spawnBody(SIM.placeSpawn({ type: 'star', mass: 18, phase: 1.9, name: 'Doomed' }));`) },
  { name: 'xsec_vega', setup: xsec('vega', 'Vega') },
  { name: 'xsec_betelgeuse', setup: xsec('betelgeuse', 'Betelgeuse') },
  { name: 'xsec_wd', setup: xsec('sirius', 'Sirius B') },
  { name: 'xsec_neutron', setup: xsec('nsmerger', 'NS-A') },
  { name: 'xsec_neutron_focus', setup: xsec('nsmerger', 'NS-A', null, true) },
  { name: 'xsec_earth', setup: xsec('solar', 'Earth') },
  { name: 'xsec_jupiter', setup: xsec('solar', 'Jupiter') },
  { name: 'xsec_browndwarf', setup: xsec('solar', 'Jupiter', { mass: 0.04 }) },
  { name: 'xsec_bh', setup: xsec('bhmerger', null) },
  { name: 'fd_planet', setup: fd('planet', null) },
  { name: 'fd_superearth', setup: fd('planet', -3.3, { fdSpin: 0.6, fdComp: 'ice' }) },
  { name: 'fd_giant_bd', setup: fd('gas-giant', -1.4) },
  { name: 'fd_star', setup: fd('star', 0.5, { fdPhase: 1.35 }) },
  { name: 'fd_star_ms', setup: fd('star', 0.0) },
  { name: 'fd_neutron_tov', setup: fd('neutron', 0.45) },
  { name: 'fd_wd', setup: fd('white-dwarf', 0.2) },
  { name: 'fd_bh', setup: fd('bh', 1.0, { fdSpin: 0.9 }) },
].map(s => ({ ...s, hud: true, freeze: true, width: 1280, height: H, frames: 12, dump: s.name.startsWith('xsec') ? dumpXsec : dumpFd }));
for (const [n, spec] of Object.entries({
  sun: { type: 'star', mass: 1, phase: 0.5 },
  redgiant: { type: 'star', mass: 1.2, phase: 1.35 },
  presn: { type: 'star', mass: 18, phase: 1.9 },
  vega: { type: 'star', mass: 2.1, phase: 0.3, spinFrac: 0.88 },
  earth: { type: 'planet', mass: 3.0035e-6, composition: 'earth' },
  jupiter: { type: 'gas-giant', mass: 9.5459e-4, spinFrac: 0.3 },
  neutron: { type: 'neutron', mass: 1.4 },
  bh: { type: 'bh', mass: 10, spinFrac: 0.9 },
})) shots.push({ name: 'cut_' + n, setup: cut(spec), hud: true, freeze: true, width: 1280, height: 720, frames: 0, dump: dumpCut });

await writeFile(process.argv[2] || 'shots.json', JSON.stringify(shots, null, 1));
console.log('wrote', shots.length, 'shots');
