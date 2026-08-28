import { structureOf, M_EARTH_SUN, M_JUP_SUN, VERDICT } from './structure.js';
import { AU_PER_KM, AU_PER_RSUN } from './physics.js';

// ============================================================================
// THE MASS–RADIUS CURVE — the slider's own graph, and a handle you can drag
// ----------------------------------------------------------------------------
// A slider tells you where you are. It cannot tell you where the interesting
// places ARE, and in this model they are the whole point: a rocky planet's
// radius does not grow monotonically, it turns over at ~300 M⊕ where electron
// degeneracy starts stiffening faster than gravity loads it; a neutron star's
// radius is flat for a solar mass and then falls off a cliff at the TOV limit.
// Neither is visible on a linear bar with a number next to it.
//
// So this draws R(M) for the body's own composition and spin, log–log, with the
// current object sitting on the curve as a handle you can drag. Both axes have
// to be logarithmic: the mass axis spans ten decades from a dwarf planet to a
// supermassive hole, and the radius axis spans eight from a neutron star's
// 12 km to a supergiant's 700 R☉. On log axes the power laws that make up the
// curve — R ∝ M^⅓ for a cold solid, R ∝ M^(−⅓) for a degenerate one, R ∝ M for
// a horizon — are straight lines with slopes of ⅓, −⅓ and 1, and the places
// where the physics changes are visible as kinks rather than hidden in a number.
//
// THE MARKS ARE NOT A LIST. Nothing here knows that 13 M_J is the deuterium
// limit. The curve is sampled by calling structureOf() across the range, and a
// boundary is drawn wherever the RESULT changes regime — a different type, or a
// different verdict. That is the same rule the rest of the editor follows: if
// sim/structure.js learns a new threshold, this graph grows a new line without
// being told. It also means the marks move when they should — spin a neutron
// star up and the TOV line slides right, because rotation really does support
// more mass.
//
// The one thing sampling cannot show is a region with no equilibrium at all
// (past the Chandrasekhar mass a white dwarf has no radius, it detonates), so
// those come back with radiusAU = 0 and are drawn as a hatched dead zone rather
// than as a curve falling to nothing.
// ============================================================================

const N = 240;                 // samples across the range
const PAD_L = 34, PAD_R = 10, PAD_T = 14, PAD_B = 22;

// Colour per resulting type, so a curve that crosses an ignition threshold
// changes colour at the crossing. These match the type buttons' sense of what
// each object is rather than any particular body's own colour.
const TYPE_COLOR = {
  planet: '#7fb2e0', world: '#7fb2e0', 'gas-giant': '#d9a15e', star: '#ffd27f',
  'white-dwarf': '#cfe4ff', neutron: '#a8d8ff', bh: '#b98cff',
};
const DEAD = 'rgba(255,110,110,0.85)';

// A regime is what the model says the object IS at that mass — its type plus
// the verdict on whether it can hold itself up. A change in either is a line.
function regimeKey(st) {
  return `${st.type}|${st.verdict?.state ?? VERDICT.ok}`;
}

// What to call the boundary. The model's own words, shortened to fit: the
// verdict label when there is one (it names the event — "TOV limit exceeded"),
// otherwise the new object's label ("Brown dwarf").
function regimeLabel(st) {
  const v = st.verdict;
  // A reclassification's verdict label is the generic word "Reclassified"; the
  // interesting half is what it became, which is the structure's own label.
  if (st.reclassifiedFrom) return st.label || st.type;
  if (v && v.state !== VERDICT.ok && v.label) return v.label;
  return st.label || st.type;
}

function fmtMassShort(m) {
  // Plain scientific notation at the top of the range. Dividing by 1e6 and
  // appending "e6" reads fine at 3.2e6 and turns into "1.0e+2e6" at 1e8 — and
  // the Foundry's black-hole slider goes to 1e9.
  if (m >= 1e6) {
    const e = Math.floor(Math.log10(m));
    return `${+(m / Math.pow(10, e)).toPrecision(2)}e${e} M☉`;
  }
  if (m >= 0.02) return `${m < 10 ? m.toFixed(2) : m.toPrecision(3)} M☉`;
  if (m / M_JUP_SUN >= 0.3) return `${(m / M_JUP_SUN).toFixed(1)} M_J`;
  return `${(m / M_EARTH_SUN).toPrecision(2)} M⊕`;
}

// Radius axis labels. One unit for the whole axis, chosen from what the curve
// actually covers — km for compact objects, R⊕ for planets, R☉ for stars.
function radiusUnit(maxAU) {
  if (maxAU < 3e-5) return { k: 1 / AU_PER_KM, name: 'km' };
  if (maxAU < 4e-3) return { k: 1 / (6.371e6 / 1000 * AU_PER_KM), name: 'R⊕' };
  return { k: 1 / AU_PER_RSUN, name: 'R☉' };
}

export function createMassCurve({ canvas, onPick }) {
  const ctx = canvas.getContext('2d');
  let spec = null, range = [-6, 1], samples = [], marks = [], view = [-6, 1];
  let dead = [];                        // [lo,hi] spans with no equilibrium
  let focus = false;                    // zoomed to the nearest boundary
  let cacheKey = '';

  const X = lm => PAD_L + (lm - view[0]) / (view[1] - view[0]) * (canvas.width - PAD_L - PAD_R);
  const unX = px => view[0] + (px - PAD_L) / (canvas.width - PAD_L - PAD_R) * (view[1] - view[0]);

  // --- sampling -------------------------------------------------------------
  function resample() {
    const key = JSON.stringify([spec?.type, spec?.spinFrac, spec?.composition,
      spec?.phase, spec?.Z, view]);
    if (key === cacheKey) return;
    cacheKey = key;
    samples = []; marks = []; dead = [];
    let prevKey = null, deadFrom = null;
    for (let i = 0; i < N; i++) {
      const lm = view[0] + (view[1] - view[0]) * i / (N - 1);
      const m = Math.pow(10, lm);
      let st;
      try { st = structureOf({ ...spec, mass: m }); } catch { continue; }
      const r = st.radiusAU;
      const k = regimeKey(st);
      if (prevKey !== null && k !== prevKey) {
        marks.push({ lm, label: regimeLabel(st), type: st.type, bad: st.verdict && st.verdict.state !== VERDICT.ok });
      }
      prevKey = k;
      // A mass with no equilibrium radius is a gap in the curve, not a zero.
      if (!(r > 0)) {
        if (deadFrom === null) deadFrom = lm;
        samples.push(null);
      } else {
        if (deadFrom !== null) { dead.push([deadFrom, lm]); deadFrom = null; }
        samples.push({ lm, ly: Math.log10(r), type: st.type });
      }
    }
    if (deadFrom !== null) dead.push([deadFrom, view[1]]);
  }

  // The nearest regime boundary to a given mass — what "focus" zooms to, and
  // what the readout names so you know which cliff you are walking toward.
  function nearestMark(lm) {
    let best = null, d = Infinity;
    for (const mk of marks) {
      const dd = Math.abs(mk.lm - lm);
      if (dd < d) { d = dd; best = mk; }
    }
    return best;
  }

  // --- drawing --------------------------------------------------------------
  function draw() {
    const W = canvas.width, H = canvas.height;
    const plotH = H - PAD_T - PAD_B;
    ctx.clearRect(0, 0, W, H);
    if (!spec) return;
    resample();

    const live = samples.filter(Boolean);
    if (!live.length) return;
    let y0 = Infinity, y1 = -Infinity;
    for (const s of live) { if (s.ly < y0) y0 = s.ly; if (s.ly > y1) y1 = s.ly; }
    // A flat curve (a neutron star barely changes radius over its whole range)
    // would otherwise be drawn with the noise amplified to fill the panel.
    if (y1 - y0 < 0.5) { const c = (y0 + y1) / 2; y0 = c - 0.25; y1 = c + 0.25; }
    const padY = (y1 - y0) * 0.12;
    y0 -= padY; y1 += padY;
    const Y = ly => PAD_T + (1 - (ly - y0) / (y1 - y0)) * plotH;

    // --- decade grid. Log axes are only honest if the reader can see the
    // decades, so both sets of gridlines are drawn at powers of ten.
    ctx.strokeStyle = 'rgba(140,170,210,0.10)';
    ctx.lineWidth = 1;
    ctx.font = '9px ui-monospace, monospace';
    ctx.fillStyle = 'rgba(150,175,210,0.55)';
    ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
    const unit = radiusUnit(Math.pow(10, y1));
    for (let d = Math.ceil(y0); d <= Math.floor(y1); d++) {
      const y = Y(d);
      ctx.beginPath(); ctx.moveTo(PAD_L, y); ctx.lineTo(W - PAD_R, y); ctx.stroke();
      const v = Math.pow(10, d) * unit.k;
      ctx.fillText(v >= 1e4 || v < 0.01 ? v.toExponential(0).replace('e+', 'e') : String(+v.toPrecision(2)), PAD_L - 4, y);
    }
    ctx.textAlign = 'left';
    ctx.fillText(unit.name, 2, PAD_T - 6);
    ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    // Every decade gets a gridline; only some get a label. Ten decades across
    // 300 px is 30 px each and "0.033 M⊕" is 50 wide, so labelling them all
    // produces a smear rather than an axis.
    const perDecade = (X(1) - X(0));
    const labelEvery = Math.max(1, Math.ceil(56 / Math.max(perDecade, 1)));
    for (let d = Math.ceil(view[0]); d <= Math.floor(view[1]); d++) {
      const x = X(d);
      ctx.beginPath(); ctx.moveTo(x, PAD_T); ctx.lineTo(x, H - PAD_B); ctx.stroke();
      if (((d % labelEvery) + labelEvery) % labelEvery !== 0) continue;
      ctx.fillStyle = 'rgba(150,175,210,0.45)';
      ctx.fillText(fmtMassShort(Math.pow(10, d)), x, H - PAD_B + 4);
    }

    // --- dead zones: masses with no equilibrium at all
    for (const [a, b] of dead) {
      ctx.fillStyle = 'rgba(255,90,90,0.10)';
      ctx.fillRect(X(a), PAD_T, Math.max(X(b) - X(a), 1.5), plotH);
    }

    // --- regime boundaries, drawn before the curve so the curve sits on top
    ctx.setLineDash([3, 3]);
    for (const mk of marks) {
      const x = X(mk.lm);
      if (x < PAD_L || x > W - PAD_R) continue;
      ctx.strokeStyle = mk.bad ? 'rgba(255,120,120,0.75)' : 'rgba(150,200,255,0.55)';
      ctx.beginPath(); ctx.moveTo(x, PAD_T); ctx.lineTo(x, H - PAD_B); ctx.stroke();
    }
    ctx.setLineDash([]);

    // --- the curve, coloured by what the object IS at that mass
    ctx.lineWidth = 2;
    let run = [];
    const flush = () => {
      if (run.length < 2) { run = []; return; }
      ctx.strokeStyle = TYPE_COLOR[run[0].type] || '#9fc4ff';
      ctx.beginPath();
      run.forEach((s, i) => (i ? ctx.lineTo(X(s.lm), Y(s.ly)) : ctx.moveTo(X(s.lm), Y(s.ly))));
      ctx.stroke();
      run = [];
    };
    for (const s of samples) {
      if (!s) { flush(); continue; }
      if (run.length && run[run.length - 1].type !== s.type) { const last = run[run.length - 1]; flush(); run.push(last); }
      run.push(s);
    }
    flush();

    // --- boundary labels last, so they are legible over the curve
    ctx.font = '9px ui-monospace, monospace';
    ctx.textAlign = 'left'; ctx.textBaseline = 'top';
    // Boundaries cluster (deuterium ignition and hydrogen ignition are 0.8 dex
    // apart), so labels alternate between two rows and a label that would still
    // land on top of the previous one is dropped rather than smeared over it.
    const rowEnd = [-1e9, -1e9];
    for (const mk of marks) {
      const x = X(mk.lm);
      if (x < PAD_L || x > W - PAD_R) continue;
      const txt = mk.label.length > 20 ? mk.label.slice(0, 19) + '…' : mk.label;
      const w = ctx.measureText(txt).width;
      const row = rowEnd[0] <= rowEnd[1] ? 0 : 1;
      if (x < rowEnd[row] + 6) continue;
      const tx = Math.min(x + 3, W - PAD_R - w - 1);
      rowEnd[row] = tx + w;
      const ty = PAD_T + 1 + row * 12;
      ctx.fillStyle = 'rgba(8,10,16,0.72)';
      ctx.fillRect(tx - 2, ty, w + 4, 11);
      ctx.fillStyle = mk.bad ? '#ff9a9a' : '#a9cdf5';
      ctx.fillText(txt, tx, ty + 1);
    }

    // --- the handle: where this body sits on its own curve
    const lm = Math.log10(Math.max(spec.mass, 1e-12));
    if (lm >= view[0] && lm <= view[1]) {
      let st = null;
      try { st = structureOf({ ...spec, mass: Math.pow(10, lm) }); } catch { /* ignore */ }
      const r = st?.radiusAU;
      const x = X(lm);
      ctx.strokeStyle = 'rgba(255,255,255,0.35)';
      ctx.setLineDash([2, 3]);
      ctx.beginPath(); ctx.moveTo(x, PAD_T); ctx.lineTo(x, H - PAD_B); ctx.stroke();
      ctx.setLineDash([]);
      if (r > 0) {
        const y = Y(Math.log10(r));
        ctx.beginPath(); ctx.arc(x, y, 4.5, 0, Math.PI * 2);
        ctx.fillStyle = '#fff'; ctx.fill();
        ctx.lineWidth = 2; ctx.strokeStyle = st?.verdict && st.verdict.state !== VERDICT.ok ? DEAD : (TYPE_COLOR[st.type] || '#9fc4ff');
        ctx.stroke();
      }
    }
  }

  // --- interaction ----------------------------------------------------------
  // Dragging the handle is the same edit the mass slider makes; the graph is a
  // second view of one number, not a second number.
  let down = false;
  function pick(ev) {
    const rect = canvas.getBoundingClientRect();
    const px = (ev.clientX - rect.left) * (canvas.width / rect.width);
    const lm = Math.min(Math.max(unX(px), view[0]), view[1]);
    onPick?.(Math.pow(10, lm));
  }
  canvas.addEventListener('pointerdown', e => {
    down = true; canvas.setPointerCapture(e.pointerId); pick(e); e.preventDefault();
  });
  canvas.addEventListener('pointermove', e => { if (down) pick(e); });
  canvas.addEventListener('pointerup', e => { down = false; canvas.releasePointerCapture?.(e.pointerId); });
  canvas.addEventListener('pointercancel', () => { down = false; });

  return {
    // spec: the body's current parameters (type, mass, spin, composition…).
    // range: [log10 lo, log10 hi] of the type's full mass range.
    draw(newSpec, newRange) {
      spec = newSpec;
      if (newRange) range = newRange;
      const lm = Math.log10(Math.max(spec.mass, 1e-12));
      if (focus) {
        // Zoomed: put the nearest boundary and the body in the same ±0.35 dex
        // window, so the transition is something you can crawl across rather
        // than something the handle jumps over in one pixel.
        cacheKey = '';                     // the window moves, so re-sample
        view = [Math.min(lm, range[0]), Math.max(lm, range[1])];
        resample();
        const mk = nearestMark(lm);
        const c = mk ? (mk.lm + lm) / 2 : lm;
        const half = Math.max(0.35, mk ? Math.abs(mk.lm - lm) * 0.75 + 0.2 : 0.35);
        view = [c - half, c + half];
      } else {
        view = [Math.min(range[0], lm - 0.02), Math.max(range[1], lm + 0.02)];
      }
      draw();
    },
    setFocus(v) { focus = !!v; cacheKey = ''; },
    get focus() { return focus; },
    // What the body is closest to becoming — used for the caption under the
    // graph, which is the part people actually read.
    nearest(mass) {
      const lm = Math.log10(Math.max(mass, 1e-12));
      const mk = nearestMark(lm);
      if (!mk) return null;
      return { label: mk.label, mass: Math.pow(10, mk.lm), above: mk.lm < lm, bad: mk.bad };
    },
  };
}

// The panel that owns the graph labels its caption with the same units.
export { fmtMassShort };
