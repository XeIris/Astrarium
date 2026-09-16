import { structureOf, PHASES, whiteDwarfRadiusSun, spectralType } from './structure.js';
import { blackbodyColor } from './stellar.js';

// ============================================================================
// THE HERTZSPRUNG–RUSSELL DIAGRAM
// ----------------------------------------------------------------------------
// Plot every star you can measure with temperature on one axis and luminosity
// on the other, and they do not scatter. They fall on a line — with a couple of
// well-populated clumps off it — and that line is the single most important
// picture in stellar astronomy, because it says that a star is not free to be
// anything. Give it a mass and the physics fixes the rest.
//
// NOTHING IN THIS PLOT IS DRAWN FROM A TABLE. The main sequence is sampled out
// of structureOf() over mass, exactly as the mass–radius curve in
// sim/masscurve.js is — so a change to the stellar model in sim/structure.js
// moves this line too, and the two can never disagree. The evolutionary tracks
// are the same function walked over PHASES at fixed mass; the white dwarf
// sequence is whiteDwarfRadiusSun() at a few cooling temperatures, which is why
// it is a LINE of nearly constant radius rather than a region.
//
// THE AXES ARE BOTH BACKWARDS, and it is worth knowing why rather than being
// annoyed by it: Hertzsprung and Russell plotted against spectral type — O B A
// F G K M — which was an alphabetical ordering of hydrogen line strength before
// anyone knew it was a temperature sequence. Temperature increases to the LEFT
// because that is the order the letters were already in. Luminosity is
// logarithmic because the range is 10¹² to 1.
// ============================================================================

const T_HI = 46000, T_LO = 2100;      // x range, kelvin (hot on the left)
const L_LO = -5.2, L_HI = 7.0;        // y range, log10 L/L☉

// Spectral class boundaries, from spectralType() so the two cannot drift apart.
const CLASSES = [
  ['O', 33000], ['B', 10000], ['A', 7300], ['F', 6000],
  ['G', 5300], ['K', 3900], ['M', 2400],
];

export function createHRDiagram({ canvas }) {
  const ctx = canvas.getContext('2d');

  // ---- the ZAMS-to-midlife main sequence, sampled over mass.
  // f = 0.5 (PHASES 'ms-mid') is where the model is calibrated to today's Sun,
  // and where most observed main-sequence stars actually sit.
  const MS = [];
  for (let lm = Math.log10(0.08); lm <= Math.log10(80); lm += 0.02) {
    const m = Math.pow(10, lm);
    const s = structureOf({ type: 'star', mass: m, phase: 0.5 });
    if (s.type !== 'star' || !(s.luminosity > 0)) continue;
    MS.push({ m, teff: s.teff, L: s.luminosity });
  }

  // ---- two evolutionary tracks, the same function walked over the phases.
  const track = mass => PHASES
    .filter(p => p.f >= 0 && p.id !== 'remnant')
    .map(p => {
      const s = structureOf({ type: 'star', mass, phase: p.f });
      return { teff: s.teff, L: s.luminosity, label: p.label, id: p.id };
    })
    .filter(p => p.L > 0);
  const TRACKS = [
    { mass: 1, color: 'rgba(255,190,120,0.75)', pts: track(1) },
    { mass: 8, color: 'rgba(160,200,255,0.7)', pts: track(8) },
  ];

  // ---- the white dwarf cooling sequence. A white dwarf does not burn
  // anything; it is a fixed lump of degenerate matter losing heat, so it slides
  // DOWN and to the RIGHT at constant radius over billions of years.
  const WD = [];
  for (const M of [0.6]) {
    const R = whiteDwarfRadiusSun(M);
    for (let T = 40000; T >= 4000; T -= 1000) {
      WD.push({ teff: T, L: R * R * Math.pow(T / 5772, 4) });
    }
  }

  const X = t => {
    const k = (Math.log10(T_HI) - Math.log10(Math.max(t, 1))) / (Math.log10(T_HI) - Math.log10(T_LO));
    return pad.l + k * (canvas.width - pad.l - pad.r);
  };
  const Y = L => {
    const k = (Math.log10(Math.max(L, 1e-9)) - L_LO) / (L_HI - L_LO);
    return canvas.height - pad.b - k * (canvas.height - pad.t - pad.b);
  };
  const pad = { l: 34, r: 10, t: 16, b: 24 };

  function poly(pts, color, width = 1.6, dash = null) {
    if (pts.length < 2) return;
    ctx.save();
    if (dash) ctx.setLineDash(dash);
    ctx.beginPath();
    pts.forEach((p, i) => (i ? ctx.lineTo(X(p.teff), Y(p.L)) : ctx.moveTo(X(p.teff), Y(p.L))));
    ctx.strokeStyle = color; ctx.lineWidth = width; ctx.stroke();
    ctx.restore();
  }

  function draw(bodies = []) {
    const W = canvas.width, H = canvas.height;
    ctx.clearRect(0, 0, W, H);
    ctx.font = '9px ui-monospace, monospace';

    // ---- frame and the luminosity decades
    ctx.strokeStyle = 'rgba(150,170,200,0.18)'; ctx.lineWidth = 1;
    ctx.strokeRect(pad.l + 0.5, pad.t + 0.5, W - pad.l - pad.r - 1, H - pad.t - pad.b - 1);
    ctx.fillStyle = 'rgba(150,170,200,0.55)';
    ctx.textAlign = 'right';
    for (let e = -4; e <= 6; e += 2) {
      const y = Y(Math.pow(10, e));
      if (y < pad.t || y > H - pad.b) continue;
      ctx.strokeStyle = 'rgba(150,170,200,0.07)';
      ctx.beginPath(); ctx.moveTo(pad.l, y); ctx.lineTo(W - pad.r, y); ctx.stroke();
      ctx.fillText(`10${sup(e)}`, pad.l - 4, y + 3);
    }
    ctx.textAlign = 'center';
    // ---- spectral classes across the top, at their own boundaries
    for (let i = 0; i < CLASSES.length; i++) {
      const [name, tLo] = CLASSES[i];
      const tHi = i === 0 ? T_HI : CLASSES[i - 1][1];
      const x0 = X(tHi), x1 = X(tLo);
      ctx.strokeStyle = 'rgba(150,170,200,0.10)';
      ctx.beginPath(); ctx.moveTo(x1, pad.t); ctx.lineTo(x1, H - pad.b); ctx.stroke();
      ctx.fillStyle = 'rgba(190,205,230,0.6)';
      ctx.fillText(name, (x0 + x1) / 2, pad.t - 5);
    }
    ctx.textAlign = 'left';

    // ---- the sequences
    poly(MS, 'rgba(255,255,255,0.55)', 2.2);
    poly(WD, 'rgba(190,215,255,0.6)', 1.6, [3, 3]);
    for (const t of TRACKS) poly(t.pts, t.color, 1.2, [2, 3]);

    // ---- named regions, placed where the curves actually put them
    ctx.fillStyle = 'rgba(190,205,230,0.5)';
    label('main sequence', 9000, 10, -18, 8);
    label('giants', 4200, 300, 6, 0);
    label('supergiants', 6000, 1e5, 0, 0);
    label('white dwarfs', 14000, 5e-3, 6, 10);

    // ---- the live stars in the scene
    for (const b of bodies) {
      if (!(b.teff > 0) || !(b.luminosity > 0)) continue;
      if (b.type !== 'star' && b.type !== 'white-dwarf') continue;
      const x = X(b.teff), y = Y(b.luminosity);
      if (x < pad.l - 6 || x > W || y < 0 || y > H) continue;
      const c = blackbodyColor(b.teff);
      ctx.beginPath(); ctx.arc(x, y, 4.2, 0, Math.PI * 2);
      ctx.fillStyle = `rgb(${(c.r * 255) | 0},${(c.g * 255) | 0},${(c.b * 255) | 0})`;
      ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,0.6)'; ctx.lineWidth = 1; ctx.stroke();
      ctx.fillStyle = 'rgba(225,235,250,0.92)';
      // A white dwarf's class is D, not whatever its temperature would make it
      // on the main sequence — Sirius B is 25 000 K and is emphatically not a
      // B star. The body already carries the right answer, so use it.
      const cls = b.spectral || spectralType(b.teff);
      ctx.fillText(b.name.endsWith(` ${cls}`) ? b.name : `${b.name} ${cls}`, x + 7, y + 3);
    }

    ctx.fillStyle = 'rgba(150,170,200,0.5)';
    ctx.fillText('← hotter        surface temperature        cooler →', pad.l + 2, H - 8);
    ctx.save();
    ctx.translate(10, H / 2); ctx.rotate(-Math.PI / 2);
    ctx.textAlign = 'center';
    ctx.fillText('luminosity  L/L☉', 0, 0);
    ctx.restore();
  }

  function label(text, teff, L, dx, dy) {
    ctx.fillText(text, X(teff) + dx, Y(L) + dy);
  }

  return { draw };
}

const SUPS = { '-': '⁻', 0: '⁰', 1: '¹', 2: '²', 3: '³', 4: '⁴', 5: '⁵', 6: '⁶', 7: '⁷', 8: '⁸', 9: '⁹' };
function sup(n) { return String(n).split('').map(c => SUPS[c] ?? c).join(''); }
