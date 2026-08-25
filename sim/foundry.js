import {
  structureOf, ROCK_COMPOSITIONS, PHASES, phaseAt, LIMITS,
  M_EARTH_SUN, M_JUP_SUN, rockyMaxRadius, tovLimit, VERDICT,
} from './structure.js';
import {
  drawCrossSection, drawTempLegend, structureFacts, VERDICT_CLASS,
  fmtMass, fmtLength,
} from './crosssection.js';

// ============================================================================
// THE OBJECT FOUNDRY — building a body out of physics rather than out of a menu
// ----------------------------------------------------------------------------
// The point of this panel is that it has no catalogue of outcomes in it. There
// is no rule anywhere saying "if mass > X show the explosion". There are four
// inputs — mass, spin, composition, and how much of its life it has burned —
// and everything you see is what sim/structure.js derives from them. Which is
// why dragging one slider produces behaviour that was never scripted:
//
//   MASS on a rocky planet. The radius grows as M^⅓, flattens, and then at
//   about 300 M⊕ it STOPS and starts falling: electron degeneracy stiffens
//   faster than gravity loads it, so past one Jupiter mass a ball of rock gets
//   smaller the more rock you add. Keep going and at 13 M_J it lights
//   deuterium and the panel stops calling it a planet; at 0.075 M☉ it lights
//   hydrogen and it is a star.
//
//   MASS on a star. Colour tracks temperature all the way from a 2800 K red
//   dwarf to a 45 000 K O star, because both come from the same L and R. Past
//   ~150 M☉ its own radiation is pushing its outer layers off; between 140 and
//   260 M☉ the pair instability disassembles it completely, leaving nothing;
//   above that it collapses straight to a black hole without exploding at all.
//
//   MASS on a neutron star. Nothing happens, and then at the TOV mass
//   everything does — there is no pressure left anywhere in physics to hold it
//   up, and it becomes a black hole. Spin it first and the limit moves, because
//   centrifugal support is real support.
//
//   SPIN, on anything. The body flattens along the Roche sequence and its
//   equator cools relative to its poles, and at Ω = Ω_crit the equator is in
//   orbit and material leaves. That limit is R_eq/R_pol = 3/2 exactly, for
//   every object, which is why the slider can stop somewhere principled.
//
//   LIFE BURNED, on a star. The core hydrogen fraction falls, the mean
//   molecular weight rises, and the star brightens and swells along its track —
//   then leaves the main sequence entirely and becomes a subgiant, a red giant
//   with a degenerate helium core, and finally an onion of burning shells
//   around iron.
// ============================================================================

// Slider range in log10(M☉) per type, chosen to run comfortably PAST the
// boundary in both directions — the thresholds are the interesting part, so
// every range has to be able to reach one.
const MASS_RANGE = {
  planet:        [-8.5, -1.6, -5.52],    // 0.01 M⊕ … 25 M_J   (default 1 M⊕)
  'gas-giant':   [-5.5, -0.7, -3.02],    // 0.3 M⊕  … 200 M_J  (default 1 M_J)
  star:          [-1.4,  2.6,  0.0],     // 0.04    … 400 M☉   (default 1 M☉)
  neutron:       [-0.5,  0.62, 0.146],   // 0.32    … 4.2 M☉   (default 1.4)
  'white-dwarf': [-1.1,  0.25, -0.22],   // 0.08    … 1.8 M☉   (default 0.6)
  bh:            [ 0.0,  9.0,  1.0],     // 1       … 1e9 M☉   (default 10)
};

const TYPES = [
  { id: 'planet', label: 'Rocky planet', sym: '·' },
  { id: 'gas-giant', label: 'Gas giant', sym: '○' },
  { id: 'star', label: 'Star', sym: '☉' },
  { id: 'neutron', label: 'Neutron star', sym: '◉' },
  { id: 'white-dwarf', label: 'White dwarf', sym: '◇' },
  { id: 'bh', label: 'Black hole', sym: '●' },
];

// The parameter rows, shared verbatim between the Foundry (building a body) and
// the live editor (changing one that already exists). They are the same four
// inputs in both places on purpose: editing an object in flight is not a
// different, weaker operation than making one — it runs the same interior model
// and reaches the same thresholds.
function controlRows(p) {
  return `
  <div class="row">
    <label for="${p}Mass" title="Dragged far enough, this stops being a size control and starts being an identity control: mass is what decides whether an object is a planet, a brown dwarf, a star or a hole.">Mass</label>
    <input type="range" id="${p}Mass" min="-8.5" max="-1.6" step="0.01" value="-5.52">
    <span class="val" id="${p}MassVal">1.00 M⊕</span>
  </div>

  <div class="row" id="${p}SpinRow">
    <label for="${p}Spin" title="As a fraction of the speed at which the body's own equator would be in orbit. 1.0 is mass shedding, and no rotating body can be flatter than R_eq/R_pol = 3/2.">Spin</label>
    <input type="range" id="${p}Spin" min="0" max="1" step="0.005" value="0">
    <span class="val" id="${p}SpinVal">0%</span>
  </div>

  <div class="row" id="${p}CompRow">
    <label for="${p}Comp" title="What the planet is made of. Every solid composition follows the same scaled mass-radius curve (Seager et al. 2007) and differs only in where it sits on it.">Composition</label>
    <select id="${p}Comp" class="fd-select"></select>
  </div>

  <div class="row" id="${p}PhaseRow">
    <label for="${p}Phase" title="How far through its life. Core hydrogen falls from 0.71 to zero across the main sequence, then burning moves to a shell and the star leaves it altogether.">Life burned</label>
    <input type="range" id="${p}Phase" min="-0.15" max="1.95" step="0.01" value="0.5">
    <span class="val" id="${p}PhaseVal">Mid MS</span>
  </div>

  <div class="row" id="${p}ZRow">
    <label for="${p}Z" title="Mass fraction in elements heavier than helium. Metal-poor gas is more transparent, so a metal-poor star is hotter and brighter — and needs slightly more mass to ignite at all.">Metallicity Z</label>
    <input type="range" id="${p}Z" min="0.0001" max="0.04" step="0.0005" value="0.014">
    <span class="val" id="${p}ZVal">0.014</span>
  </div>`;
}

// Mass readout picks its unit from the value, not from the type — a "rocky
// planet" dragged past 13 M_J is being reported in the units of what it has
// become.
function massLabel(m) {
  if (m >= 0.02) return `${m < 10 ? m.toFixed(3) : m.toPrecision(3)} M☉`;
  if (m / M_JUP_SUN >= 0.3) return `${(m / M_JUP_SUN).toFixed(2)} M_J`;
  const me = m / M_EARTH_SUN;
  return `${me < 10 ? me.toFixed(2) : me.toPrecision(3)} M⊕`;
}

// Every type the sim can hold maps onto one of the Foundry's mass ranges. A
// `world` is a rocky planet that happens to be the one you can stand on.
const RANGE_FOR = t => MASS_RANGE[t === 'world' ? 'planet' : t] || MASS_RANGE.planet;

const MARKUP = `
  <div class="fd-types" id="fdTypes"></div>
${controlRows('fd')}

  <div class="fd-verdict" id="fdVerdict"></div>
  <div class="fd-facts" id="fdFacts"></div>

  <canvas class="fd-xsec" id="fdXsec" width="300" height="230"></canvas>
  <canvas class="fd-legend" id="fdLegend" width="300" height="26"></canvas>
  <div class="fd-note" id="fdLayerNote"></div>

  <button class="action-btn" id="fdSpawn">Spawn into orbit</button>
`;

export function createFoundry({ mount, onSpawn }) {
  mount.innerHTML = MARKUP;
  const $ = id => mount.querySelector('#' + id);

  const draft = {
    type: 'planet',
    mass: Math.pow(10, MASS_RANGE.planet[2]),
    spinFrac: 0,
    composition: 'earth',
    phase: 0.5,
    Z: 0.014,
  };
  // Remember where the mass slider was left for each type, so flipping between
  // Star and Rocky planet does not silently reset a mass you chose.
  const lastMass = {};
  for (const [k, v] of Object.entries(MASS_RANGE)) lastMass[k] = v[2];

  // --- type buttons
  $('fdTypes').innerHTML = TYPES.map(t =>
    `<button class="fd-type" data-fdtype="${t.id}"><span class="sym">${t.sym}</span>${t.label}</button>`).join('');

  // --- composition options
  $('fdComp').innerHTML = Object.entries(ROCK_COMPOSITIONS)
    .map(([k, c]) => `<option value="${k}">${c.label}</option>`).join('');
  $('fdComp').value = 'earth';

  drawTempLegend($('fdLegend'));

  let structure = null;

  function setType(id) {
    lastMass[draft.type] = Math.log10(draft.mass);
    draft.type = id;
    const [lo, hi] = MASS_RANGE[id];
    const el = $('fdMass');
    el.min = String(lo); el.max = String(hi);
    // Carry the mass across if the new type's range can hold it; this is what
    // makes "build a 0.01 M☉ planet, switch to Star, watch it be rejected"
    // work, which is a lesson rather than an error.
    const keep = Math.min(Math.max(lastMass[id], lo), hi);
    el.value = String(keep);
    draft.mass = Math.pow(10, keep);
    mount.querySelectorAll('[data-fdtype]').forEach(b =>
      b.classList.toggle('active', b.dataset.fdtype === id));
    // Rows that only mean something for some types.
    $('fdCompRow').style.display = id === 'planet' ? '' : 'none';
    $('fdPhaseRow').style.display = id === 'star' ? '' : 'none';
    $('fdZRow').style.display = id === 'star' ? '' : 'none';
    $('fdSpinRow').querySelector('label').textContent = id === 'bh' ? 'Spin a*' : 'Spin';
    update();
  }

  function update() {
    draft.mass = Math.pow(10, parseFloat($('fdMass').value));
    draft.spinFrac = parseFloat($('fdSpin').value);
    draft.composition = $('fdComp').value;
    draft.phase = parseFloat($('fdPhase').value);
    draft.Z = parseFloat($('fdZ').value);

    $('fdMassVal').textContent = massLabel(draft.mass);
    $('fdSpinVal').textContent = draft.type === 'bh'
      ? draft.spinFrac.toFixed(3)
      : `${(draft.spinFrac * 100).toFixed(0)}%`;
    $('fdPhaseVal').textContent = phaseAt(draft.phase).label;
    $('fdZVal').textContent = draft.Z.toFixed(4);

    structure = structureOf(draft);

    // --- verdict banner
    const v = structure.verdict || { state: VERDICT.ok, label: '', detail: '' };
    const cls = VERDICT_CLASS[v.state] || 'v-ok';
    const became = structure.type !== draft.type
      ? `<div class="fd-became">now a ${TYPES.find(t => t.id === structure.type)?.label ?? structure.type}</div>` : '';
    $('fdVerdict').className = `fd-verdict ${cls}`;
    $('fdVerdict').innerHTML =
      `<div class="fd-vhead">${v.label}</div>${became}<div class="fd-vbody">${v.detail}</div>`;

    // --- derived quantities
    $('fdFacts').innerHTML = structureFacts(structure)
      .map(([k, val]) => `<div><span class="k">${k}</span><span class="v">${val}</span></div>`).join('');

    drawCrossSection($('fdXsec'), structure, { title: structure.label });
    $('fdLayerNote').innerHTML = (structure.layers || [])
      .map(L => `<div><b>${L.name}</b> — ${L.note}</div>`).join('');
  }

  mount.addEventListener('click', e => {
    const t = e.target.closest('[data-fdtype]');
    if (t) setType(t.dataset.fdtype);
  });
  for (const id of ['fdMass', 'fdSpin', 'fdPhase', 'fdZ']) {
    $(id).addEventListener('input', update);
  }
  $('fdComp').addEventListener('change', update);
  $('fdSpawn').addEventListener('click', () => {
    // Spawn what it ACTUALLY IS, not what the type buttons say. A 20 M_J
    // "rocky planet" goes into the scene as a brown dwarf, because that is
    // what the physics returned.
    onSpawn?.({
      type: structure.type,
      mass: structure.mass,
      spinFrac: draft.spinFrac,
      composition: draft.composition,
      phase: draft.type === 'star' ? draft.phase : undefined,
      Z: draft.Z,
      radiusKm: structure.radiusKm,
      name: `${structure.label}`,
    }, structure);
  });

  setType('planet');

  return {
    get draft() { return draft; },
    get structure() { return structure; },
    refresh: update,
    setType,
  };
}

// ============================================================================
// A standalone inspector for a body that already exists in the scene — the same
// diagram and the same facts, but reading a live body instead of a draft.
// ============================================================================
export function createInspector({ canvas, legend, factsEl, verdictEl, notesEl }) {
  if (legend) drawTempLegend(legend);
  return {
    show(st, title) {
      if (!st) return;
      drawCrossSection(canvas, st, { title: title ?? st.label });
      if (factsEl) {
        factsEl.innerHTML = structureFacts(st)
          .map(([k, v]) => `<div><span class="k">${k}</span><span class="v">${v}</span></div>`).join('');
      }
      if (verdictEl && st.verdict) {
        verdictEl.className = `fd-verdict ${VERDICT_CLASS[st.verdict.state] || 'v-ok'}`;
        verdictEl.innerHTML =
          `<div class="fd-vhead">${st.verdict.label}</div><div class="fd-vbody">${st.verdict.detail}</div>`;
      }
      if (notesEl) {
        notesEl.innerHTML = (st.layers || [])
          .map(L => `<div><b>${L.name}</b> — ${L.note}</div>`).join('');
      }
    },
  };
}

// ============================================================================
// THE LIVE EDITOR — the same four inputs, pointed at a body already in flight
// ----------------------------------------------------------------------------
// Spawning and editing differ only in what is preserved. This panel holds no
// draft: it reads the focused body, and every slider move hands a patch back to
// the orchestrator, which re-derives the object and rebuilds its meshes in
// place. So the thresholds are all still live — drag a neutron star past the
// TOV mass and it collapses under you, spin a star to break-up and it flattens
// and its equator cools while it is still orbiting.
//
// Two details that are not obvious:
//
//   · The mass slider's range comes from the type, but a body can already sit
//     outside it (a catalogue supergiant, a body that has been eating). The
//     range is widened to contain what is actually there rather than snapping
//     the value — an editor that silently changed the thing you opened it on
//     would be worse than no editor.
//   · Mass changes continuously in this sim, because accretion is continuous.
//     The sliders re-read the body every refresh, EXCEPT the one being dragged:
//     nothing is more annoying than a control that fights your thumb.
// ============================================================================
export function createLiveEditor({ mount, onEdit }) {
  mount.innerHTML = `<div class="le-rows">${controlRows('le')}</div>`;
  const $ = id => mount.querySelector('#' + id);

  $('leComp').innerHTML = Object.entries(ROCK_COMPOSITIONS)
    .map(([k, c]) => `<option value="${k}">${c.label}</option>`).join('');

  let body = null;          // the body being edited
  let dragging = null;      // id of the control currently under the pointer
  let lastId = null;        // which body the controls are currently showing
  let pending = null;       // patch coalesced between applies
  let timer = 0, lastApply = 0;

  // At most one apply per frame-length. A slider emits events far faster than a
  // visual can be torn down and rebuilt, and every patch is absolute rather
  // than incremental, so dropping the intermediate ones costs nothing — but the
  // LAST one must always land, hence the trailing timer. (A timer rather than
  // requestAnimationFrame: rAF never fires while the tab is hidden, and an edit
  // that silently did nothing until you looked back at the page would be a
  // mystery rather than a feature.)
  const MIN_MS = 16;
  function flush() {
    timer = 0; lastApply = performance.now();
    const p = pending; pending = null;
    if (body && p) onEdit?.(body, p);
  }
  function queue(patch) {
    pending = { ...(pending || {}), ...patch };
    if (timer) return;
    const wait = MIN_MS - (performance.now() - lastApply);
    if (wait <= 0) flush();
    else timer = setTimeout(flush, wait);
  }

  function readouts() {
    const m = Math.pow(10, parseFloat($('leMass').value));
    $('leMassVal').textContent = massLabel(m);
    const sp = parseFloat($('leSpin').value);
    $('leSpinVal').textContent = body?.type === 'bh' ? sp.toFixed(3) : `${(sp * 100).toFixed(0)}%`;
    $('lePhaseVal').textContent = phaseAt(parseFloat($('lePhase').value)).label;
    $('leZVal').textContent = parseFloat($('leZ').value).toFixed(4);
  }

  // Push the body's current state into the controls. Called on attach and on
  // every panel refresh; skips whatever the user has hold of.
  function sync(b) {
    // Switching to a different body always loads that body's values, whatever
    // the pointer is doing — the alternative is a slider still holding the last
    // object's number while the panel names a new one.
    if (b && b.id !== lastId) { lastId = b.id; dragging = null; }
    body = b;
    if (!b) return;
    const type = b.type;
    const [lo, hi] = RANGE_FOR(type);
    const lm = Math.log10(Math.max(b.mass, 1e-12));
    const el = $('leMass');
    el.min = String(Math.min(lo, lm - 0.01));
    el.max = String(Math.max(hi, lm + 0.01));
    if (dragging !== 'leMass') el.value = String(lm);
    if (dragging !== 'leSpin') $('leSpin').value = String(b.spinFrac ?? 0);
    if (dragging !== 'lePhase') $('lePhase').value = String(b.phase ?? 0.5);
    if (dragging !== 'leZ') $('leZ').value = String(b.Z ?? 0.014);
    if (dragging !== 'leComp') $('leComp').value = b.composition || 'earth';

    const rocky = type === 'planet' || type === 'world';
    $('leCompRow').style.display = rocky ? '' : 'none';
    $('lePhaseRow').style.display = type === 'star' ? '' : 'none';
    $('leZRow').style.display = type === 'star' ? '' : 'none';
    // A black hole has no surface to shed from, so its spin is the Kerr a*
    // rather than a fraction of break-up, and it runs to the extremal limit.
    const bh = type === 'bh';
    $('leSpinRow').querySelector('label').textContent = bh ? 'Spin a*' : 'Spin';
    $('leSpin').max = bh ? '0.998' : '1';
    readouts();
  }

  for (const id of ['leMass', 'leSpin', 'lePhase', 'leZ']) {
    const el = $(id);
    el.addEventListener('pointerdown', () => { dragging = id; });
    el.addEventListener('keydown', () => { dragging = id; });
    el.addEventListener('input', () => {
      dragging = id;
      readouts();
      if (id === 'leMass') queue({ mass: Math.pow(10, parseFloat(el.value)) });
      else if (id === 'leSpin') queue({ spinFrac: parseFloat(el.value) });
      else if (id === 'lePhase') queue({ phase: parseFloat(el.value) });
      else queue({ Z: parseFloat(el.value) });
    });
    el.addEventListener('change', () => { dragging = null; });
    el.addEventListener('blur', () => { dragging = null; });
  }
  // Releasing anywhere ends the drag, including outside the slider — otherwise
  // a control that lost the pointer would stop tracking the body forever.
  addEventListener('pointerup', () => { dragging = null; });

  $('leComp').addEventListener('change', () => {
    queue({ composition: $('leComp').value });
  });

  return {
    sync,
    get body() { return body; },
  };
}
