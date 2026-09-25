// ============================================================================
// HUD FIXTURE DUMP — evaluated inside the WEB page by webref.mjs (the `dump`
// field of godot/tools/uitest.shots.json). It returns everything the Godot HUD
// needs to reproduce the page's current state — the data the orchestrator
// would hand the Hud, the text of every leaf element, which elements are
// shown, which buttons are active, where every slider sits — plus the page's
// MEASURED geometry, so the Godot layout can be checked as numbers and not
// only as a picture. godot/tools/uitest.gd reads the JSON this produces.
// ============================================================================
(async () => {
  const shown = el => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const rect = el => { const r = el.getBoundingClientRect(); return [Math.round(r.x * 10) / 10, Math.round(r.y * 10) / 10, Math.round(r.width * 10) / 10, Math.round(r.height * 10) / 10]; };
  const out = { w: innerWidth, h: innerHeight };

  // ---- data the orchestrator passes in
  const { BANDS } = await import('./sim/spectrum.js');
  out.bands = BANDS.map(b => ({ short: b.short, note: b.note, label: b.label }));
  const sky = await import('./sim/sky.js');
  out.envs = Object.keys(sky.SKY_ENVIRONMENTS);
  out.params = sky.SKY_PARAMS.map(p => ({ key: p.key, label: p.label, add: p.add, max: p.max }));
  const S = SIM.state;
  out.sky = JSON.parse(JSON.stringify(S.sky));
  out.skyEff = { ...sky.blendEnvironments(S.sky.env), ...S.sky };
  out.groups = [...document.querySelectorAll('#presetList .preset-group')].map(g => ({
    id: g.dataset.group, label: g.querySelector('.preset-group-name').textContent,
    keys: [...g.querySelectorAll('[data-preset]')].map(b => b.dataset.preset), open: g.open }));
  out.presets = {};
  for (const b of document.querySelectorAll('[data-preset]')) out.presets[b.dataset.preset] = { name: b.textContent };
  out.presetKey = S.presetKey;
  out.search = document.getElementById('presetSearch').value;
  out.bodies = S.bodies.map(b => ({ id: b.id, name: b.name }));
  out.focusId = S.focusId;
  out.band = S.band;
  out.suns = S.suns.map(s => ({ name: s.body.name, cls: s.body.spectral ?? '', mass: s.body.mass, teff: s.body.teff ?? 0,
    dist_au: s.distAU, intensity: s.intensity, color: [s.color.r, s.color.g, s.color.b],
    flaring: !!(s.body.activity && s.body.activity.flux > 1.05) }));
  const cl = S.climate;
  out.climate = cl ? { label: cl.era.label, cls: cl.era.cls, desc: cl.era.desc, celsius: cl.celsius, S: cl.S, ice: cl.ice,
    clouds: cl.clouds, tauYears: cl.tauYears, Tmin: cl.extremes.Tmin, Tmax: cl.extremes.Tmax, history: cl.history.map(r => [...r]) } : null;
  out.crafts = [...document.querySelectorAll('#craftGrid [data-craft]')].map(b => ({
    key: b.dataset.craft, name: b.querySelector('.cn').textContent, desc: b.querySelector('.cd').textContent, blurb: b.title }));
  out.models = [...document.querySelectorAll('#mvGrid [data-mv]')].map(b => ({ key: b.dataset.mv, name: b.textContent }));
  const mvOn = document.querySelector('#mvGrid .on');
  if (mvOn) {
    const V = await import('./sim/flight/vehicles.js');
    const veh = V.VEHICLES[mvOn.dataset.mv];
    const hTxt = document.querySelector('#mvList .v').textContent;
    out.modelStats = { key: mvOn.dataset.mv, name: veh.name, height: parseFloat(hTxt), gross: V.grossMass(veh), dv: V.totalDeltaV(veh),
      twr: V.padTWR(veh, 9.80665), rows: veh.stages.map((s, i) => ({ name: s.name || s.key, L: s.L, D: s.D, dry: s.dry, prop: s.prop,
        engine: s.engine ? `${s.count}× ${s.engine.name}` : '—', thrust: s.engine ? s.engine.thrustVac * s.count : 0,
        isp: s.engine ? s.engine.ispVac : 0, dv: V.stageDeltaV(veh, i) })) };
  }

  // ---- page state
  out.mode = document.body.dataset.appMode;
  out.bodyClass = document.body.className;
  out.text = {}; out.shown = {};
  for (const el of document.querySelectorAll('[id]')) {
    if (el.closest('#canvas-wrap')) continue;
    out.shown[el.id] = shown(el);
    if (el.children.length === 0 && el.tagName !== 'INPUT' && el.tagName !== 'CANVAS') out.text[el.id] = el.textContent;
    if (el.tagName === 'INPUT' && el.type === 'range') out.text[el.id] = el.value;
  }
  out.active = [];
  for (const el of document.querySelectorAll('button')) {
    const a = [...el.attributes].find(x => /^data-(view|time|preset|craft|mv|band|mode|set)$/.test(x.name));
    const sel = el.id ? el.id : a ? `[${a.name}=${a.value}]` : null;
    if (!sel) continue;
    out.active.push({ sel, on: el.classList.contains('active') || el.classList.contains('on'), text: el.textContent.trim() });
  }
  out.sections = [...document.querySelectorAll('#controlPanel .sec-head')].map(h => ({
    title: h.textContent.replace('▸', '').replace(/\s*\(.*?\)\s*$/, '').trim(), open: !h.classList.contains('closed'),
    shown: shown(h) }));
  out.setPage = document.querySelector('.set-tab.on')?.dataset.set;
  out.skyAdvOpen = !document.getElementById('skyAdv').hidden;
  out.toast = document.getElementById('toast').classList.contains('show') ? document.getElementById('toast').textContent : null;
  out.collapsed = ['settingsPanel', 'scenarioPanel', 'coursePanel', 'controlPanel', 'flightPanel', 'xsecPanel', 'modelPanel']
    .filter(id => document.getElementById(id).style.display === 'none');
  out.startShown = shown(document.getElementById('startScreen')) && !document.getElementById('startScreen').classList.contains('gone');

  // ---- measured geometry: every panel, tab and marked element
  out.rects = {};
  const sels = ['#settingsPanel', '#scenarioPanel', '#coursePanel', '#controlPanel', '#modelPanel', '#xsecPanel', '#flightPanel',
    '.title-block', '.mode-switch', '#readout', '#hint', '#toast', '#lessonCard', '.tab-col', '#panelTabs .tab-right',
    '[data-open=settingsPanel]', '[data-open=scenarioPanel]', '[data-open=coursePanel]', '[data-open=flightPanel]',
    '#presetName', '#presetList', '#blurb', '#setTabs', '#bandGrid', '#bandNote', '#sunList', '#eraBadge', '#climateChart',
    '#bodyList', '#craftGrid', '#mvGrid', '#mvList', '#mvStages', '.start-inner', '.start-cards', '.start-title'];
  for (const s of sels) { const el = document.querySelector(s); if (shown(el)) out.rects[s] = rect(el); }
  for (const h of document.querySelectorAll('#controlPanel .sec-head')) if (shown(h)) out.rects['sec:' + h.textContent.replace('▸', '').replace(/\s*\(.*?\)\s*$/, '').trim()] = rect(h);
  return out;
})()
