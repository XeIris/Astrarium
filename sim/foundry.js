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

const MARKUP = `
  <div class="fd-types" id="fdTypes"></div>

  <div class="row">
    <label for="fdMass" title="Dragged far enough, this stops being a size control and starts being an identity control: mass is what decides whether an object is a planet, a brown dwarf, a star or a hole.">Mass</label>
    <input type="range" id="fdMass" min="-8.5" max="-1.6" step="0.01" value="-5.52">
    <span class="val" id="fdMassVal">1.00 M⊕</span>
  </div>

  <div class="row" id="fdSpinRow">
    <label for="fdSpin" title="As a fraction of the speed at which the body's own equator would be in orbit. 1.0 is mass shedding, and no rotating body can be flatter than R_eq/R_pol = 3/2.">Spin</label>
    <input type="range" id="fdSpin" min="0" max="1" step="0.005" value="0">
    <span class="val" id="fdSpinVal">0%</span>
  </div>

  <div class="row" id="fdCompRow">
    <label for="fdComp" title="What the planet is made of. Every solid composition follows the same scaled mass-radius curve (Seager et al. 2007) and differs only in where it sits on it.">Composition</label>
    <select id="fdComp" class="fd-select"></select>
  </div>

  <div class="row" id="fdPhaseRow">
    <label for="fdPhase" title="How far through its life. Core hydrogen falls from 0.71 to zero across the main sequence, then burning moves to a shell and the star leaves it altogether.">Life burned</label>
    <input type="range" id="fdPhase" min="-0.15" max="1.95" step="0.01" value="0.5">
    <span class="val" id="fdPhaseVal">Mid MS</span>
  </div>

  <div class="row" id="fdZRow">
    <label for="fdZ" title="Mass fraction in elements heavier than helium. Metal-poor gas is more transparent, so a metal-poor star is hotter and brighter — and needs slightly more mass to ignite at all.">Metallicity Z</label>
    <input type="range" id="fdZ" min="0.0001" max="0.04" step="0.0005" value="0.014">
    <span class="val" id="fdZVal">0.014</span>
  </div>

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

  // Mass readout picks its unit from the value, not from the type — a "rocky
  // planet" dragged past 13 M_J is being reported in the units of what it has
  // become.
  function massLabel(m) {
    if (m >= 0.02) return `${m < 10 ? m.toFixed(3) : m.toPrecision(3)} M☉`;
    if (m / M_JUP_SUN >= 0.3) return `${(m / M_JUP_SUN).toFixed(2)} M_J`;
    const me = m / M_EARTH_SUN;
    return `${me < 10 ? me.toFixed(2) : me.toPrecision(3)} M⊕`;
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
