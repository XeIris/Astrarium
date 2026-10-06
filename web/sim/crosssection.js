import {
  structureOf, VERDICT, M_EARTH_SUN, M_JUP_SUN, LIMITS,
} from './structure.js';
import { AU_PER_KM, AU_PER_RSUN } from './physics.js';

// ============================================================================
// CROSS-SECTION — cutting a body open and labelling what is inside
// ----------------------------------------------------------------------------
// Everything else in this sim draws what an observer could see. This draws what
// they could not: the interior, which for every object here is inferred rather
// than imaged. That is worth being explicit about, because the inference is not
// equally strong everywhere along the radius —
//
//   · a planet's core radius comes from its moment of inertia and seismology,
//     and is known to a few percent
//   · a star's interior comes from stellar models constrained by helioseismology
//     and neutrinos, and is known well for the Sun and less well elsewhere
//   · a neutron star's inner core is genuinely unknown — that is what the whole
//     TOV-limit question turns on
//   · a black hole's interior is not merely unmeasured but unmeasurABLE, and
//     what is drawn there is the coordinate structure of a solution to
//     Einstein's equations, not a place anyone has information about
//
// So each layer carries its own note, and the black hole says outright that the
// diagram is cheating. The alternative — drawing them all with the same
// confidence — would be the actual dishonesty.
//
// TEMPERATURE COLOUR. Layers are filled by a ramp over log T spanning 100 K to
// 10¹⁰ K, which is the range the sim contains (a planet's crust to a collapsing
// iron core). It runs dark violet → red → orange → yellow → white, the ordering
// of a heated blackbody, so "brighter is hotter" is the whole legend.
// ============================================================================

// A perceptual ramp over log10(T). Anchors are chosen so the familiar
// temperatures land where you would expect: a planetary surface is dark, a
// photosphere is orange-yellow, a stellar core is white.
const TEMP_STOPS = [
  [2.0, [18, 16, 46]],        // 100 K   — outer solar system ice
  [2.5, [30, 34, 92]],        // 316 K   — a habitable surface
  [3.0, [72, 40, 120]],       // 1 kK    — molten rock
  [3.5, [150, 46, 96]],       // 3.2 kK  — an M dwarf photosphere
  [3.76, [206, 74, 58]],      // 5.8 kK  — the Sun's photosphere
  [4.3, [242, 140, 44]],      // 20 kK   — a B star
  [5.0, [252, 196, 82]],      // 100 kK
  [6.0, [255, 232, 150]],     // 1 MK    — the solar corona
  [7.3, [255, 250, 225]],     // 20 MK   — the Sun's core
  [9.0, [232, 244, 255]],     // 1 GK    — carbon burning
  [10.0, [190, 222, 255]],    // 10 GK   — silicon burning / collapse
];

export function tempColor(T) {
  if (!(T > 0)) return 'rgb(24,26,34)';
  if (!Number.isFinite(T)) return 'rgb(255,255,255)';
  const x = Math.log10(T);
  if (x <= TEMP_STOPS[0][0]) return `rgb(${TEMP_STOPS[0][1].join(',')})`;
  for (let i = 0; i < TEMP_STOPS.length - 1; i++) {
    const [x0, c0] = TEMP_STOPS[i], [x1, c1] = TEMP_STOPS[i + 1];
    if (x <= x1) {
      const t = (x - x0) / (x1 - x0);
      return `rgb(${c0.map((c, k) => Math.round(c + (c1[k] - c) * t)).join(',')})`;
    }
  }
  return `rgb(${TEMP_STOPS[TEMP_STOPS.length - 1][1].join(',')})`;
}

// ----------------------------------------------------------------------------
// Formatting. A body in this sim can be 10 km or 10 AU across and 1e-9 or 1e9
// solar masses, so every readout has to pick its own unit or it is unreadable.
// ----------------------------------------------------------------------------
export function fmtLength(au) {
  if (!(au > 0)) return '—';
  const km = au / AU_PER_KM;
  if (km < 1) return `${(km * 1000).toFixed(0)} m`;
  if (km < 1e5) return `${km.toFixed(km < 100 ? 1 : 0)} km`;
  if (au < 0.02) return `${(au / AU_PER_RSUN).toFixed(3)} R☉`;
  if (au < 3) return `${(au / AU_PER_RSUN).toFixed(1)} R☉ · ${au.toFixed(3)} AU`;
  return `${(au / AU_PER_RSUN).toFixed(0)} R☉ · ${au.toFixed(2)} AU`;
}

export function fmtMass(msun) {
  if (msun >= 0.02) return `${msun.toFixed(msun < 10 ? 3 : 1)} M☉`;
  const mj = msun / M_JUP_SUN;
  if (mj >= 0.3) return `${mj.toFixed(2)} M_J`;
  return `${(msun / M_EARTH_SUN).toFixed(msun / M_EARTH_SUN < 10 ? 2 : 0)} M⊕`;
}

export function fmtTemp(T) {
  if (!Number.isFinite(T)) return '∞';
  if (!(T > 0)) return '—';
  if (T < 1e4) return `${Math.round(T)} K`;
  if (T < 1e6) return `${(T / 1e3).toFixed(1)} kK`;
  if (T < 1e9) return `${(T / 1e6).toFixed(T < 1e7 ? 1 : 0)} MK`;
  return `${(T / 1e9).toFixed(1)} GK`;
}

export function fmtDensity(rho) {
  if (!Number.isFinite(rho)) return '∞';
  if (!(rho > 0)) return '—';
  if (rho < 1e4) return `${rho.toFixed(rho < 100 ? 2 : 0)} kg/m³`;
  const e = Math.floor(Math.log10(rho));
  return `${(rho / Math.pow(10, e)).toFixed(2)}×10${sup(e)} kg/m³`;
}
const SUPS = '⁰¹²³⁴⁵⁶⁷⁸⁹';
function sup(n) { return String(n).split('').map(c => (c === '-' ? '⁻' : SUPS[+c])).join(''); }

// ============================================================================
// THE DIAGRAM
// ----------------------------------------------------------------------------
// draw(canvas, structure) — one call, repeated whenever the body changes.
// ============================================================================
export function drawCrossSection(canvas, st, opts = {}) {
  if (!canvas || !st) return;
  const ctx = canvas.getContext('2d');
  const W = canvas.width, H = canvas.height;
  ctx.clearRect(0, 0, W, H);
  if (!st.layers || !st.layers.length) {
    ctx.fillStyle = 'rgba(150,170,200,0.6)';
    ctx.font = '12px ui-monospace, monospace';
    ctx.fillText('no interior to show', 14, 24);
    return;
  }

  // Layout: the body occupies a disc on the left, labels stack down the right.
  const padL = 10, padT = 26, padB = 34;
  const labelW = Math.min(178, W * 0.42);
  const discW = W - labelW - padL - 12;
  const R = Math.min(discW / 2, (H - padT - padB) / 2);
  const cx = padL + R, cy = padT + R;

  // --- title
  ctx.font = '600 12px ui-monospace, monospace';
  ctx.fillStyle = '#cfe0ff';
  ctx.fillText(opts.title || st.label || '', padL, 14);

  // Radial scale: layer r0/r1 are fractions of the body's own radius, so the
  // disc is drawn to fill R and the scale bar underneath carries the units.
  const rr = f => Math.max(f, 0) * R;

  // --- filled layers, outermost first so the inner ones land on top
  const layers = st.layers;
  for (let i = layers.length - 1; i >= 0; i--) {
    const L = layers[i];
    ctx.beginPath();
    ctx.arc(cx, cy, rr(L.r1), 0, Math.PI * 2);
    ctx.fillStyle = L.T === 0 && st.type === 'bh' ? 'rgba(6,7,12,1)' : tempColor(L.T);
    ctx.fill();
  }
  // boundaries
  ctx.lineWidth = 1;
  for (const L of layers) {
    ctx.beginPath();
    ctx.arc(cx, cy, rr(L.r1), 0, Math.PI * 2);
    ctx.strokeStyle = 'rgba(0,0,0,0.45)';
    ctx.stroke();
  }

  // --- a black hole's "layers" are not material shells and must not be drawn
  // as if they were: the horizon, photon sphere and ISCO are locations in the
  // spacetime, so they get dashed rings over an unlit interior.
  if (st.type === 'bh') {
    ctx.setLineDash([4, 4]);
    for (const L of layers) {
      if (!/sphere|ISCO|horizon|Ergosphere/i.test(L.name)) continue;
      ctx.beginPath();
      ctx.arc(cx, cy, rr(L.r1), 0, Math.PI * 2);
      ctx.strokeStyle = /horizon/i.test(L.name) ? 'rgba(255,220,150,0.95)' : 'rgba(120,190,255,0.75)';
      ctx.lineWidth = 1.4;
      ctx.stroke();
    }
    ctx.setLineDash([]);
  }

  // --- rotational flattening, shown honestly: if the body is oblate, outline
  // the true shape over the (circular) layer diagram. The layers themselves are
  // drawn round because their published radii are means; the outline is the
  // measured shape, and the gap between them is the point.
  if (st.flattening > 0.01) {
    ctx.beginPath();
    ctx.ellipse(cx, cy, R, R * (1 - st.flattening), 0, 0, Math.PI * 2);
    ctx.strokeStyle = 'rgba(120,220,255,0.85)';
    ctx.setLineDash([3, 3]); ctx.lineWidth = 1.2; ctx.stroke();
    ctx.setLineDash([]);
    ctx.font = '9px ui-monospace, monospace';
    ctx.fillStyle = 'rgba(120,220,255,0.9)';
    ctx.fillText(`true shape · f = ${st.flattening.toFixed(3)}`, padL, cy + R + 13);
  }

  // --- labels down the right, with leader lines to the mid-radius of the layer
  const lx = W - labelW + 4;
  const rows = layers.length;
  const rowH = Math.min(26, (H - padT - 8) / rows);
  ctx.textBaseline = 'middle';
  layers.forEach((L, i) => {
    const y = padT + rowH * (i + 0.5);
    const mid = (L.r0 + L.r1) / 2;
    // leader: from the layer's mid-radius on the diagram's upper-right diagonal
    const th = -Math.PI * 0.5 + (i + 0.5) / rows * Math.PI * 0.98;
    const px = cx + Math.cos(th) * rr(mid), py = cy + Math.sin(th) * rr(mid);
    ctx.beginPath();
    ctx.moveTo(px, py);
    ctx.lineTo(lx - 8, y);
    ctx.strokeStyle = 'rgba(150,175,210,0.30)';
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.beginPath(); ctx.arc(px, py, 1.8, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(190,215,255,0.8)'; ctx.fill();

    // swatch
    ctx.fillStyle = tempColor(L.T);
    ctx.fillRect(lx, y - 5, 8, 10);
    ctx.strokeStyle = 'rgba(0,0,0,0.5)'; ctx.strokeRect(lx + 0.5, y - 4.5, 7, 9);

    ctx.font = '10px ui-monospace, monospace';
    ctx.fillStyle = '#dbe6f5';
    ctx.fillText(L.name, lx + 13, y - 4);
    ctx.font = '9px ui-monospace, monospace';
    ctx.fillStyle = 'rgba(150,175,210,0.75)';
    const rTxt = st.radiusAU > 0 ? fmtLength(L.r1 * st.radiusAU) : `${(L.r1 * 100).toFixed(0)}%`;
    ctx.fillText(`${rTxt}${L.T > 0 && Number.isFinite(L.T) ? ' · ' + fmtTemp(L.T) : ''}`, lx + 13, y + 6);
  });
  ctx.textBaseline = 'alphabetic';

  // --- scale bar under the disc: how big the whole thing actually is
  ctx.font = '9px ui-monospace, monospace';
  ctx.fillStyle = 'rgba(190,210,240,0.8)';
  const barY = H - 14;
  ctx.beginPath();
  ctx.moveTo(cx - R, barY); ctx.lineTo(cx + R, barY);
  ctx.moveTo(cx - R, barY - 3); ctx.lineTo(cx - R, barY + 3);
  ctx.moveTo(cx + R, barY - 3); ctx.lineTo(cx + R, barY + 3);
  ctx.strokeStyle = 'rgba(190,210,240,0.5)'; ctx.lineWidth = 1; ctx.stroke();
  const label = st.type === 'bh'
    ? `ISCO ${fmtLength(st.iscoAU * 2)} across`
    : `${fmtLength(st.radiusAU * 2)} across`;
  ctx.textAlign = 'center';
  ctx.fillText(label, cx, barY - 6);
  ctx.textAlign = 'left';
}

// ----------------------------------------------------------------------------
// The temperature legend, drawn once into its own small canvas.
// ----------------------------------------------------------------------------
export function drawTempLegend(canvas) {
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const W = canvas.width, H = canvas.height;
  ctx.clearRect(0, 0, W, H);
  const barH = 9;
  for (let x = 0; x < W; x++) {
    const logT = 2 + (x / W) * 8;             // 100 K … 1e10 K
    ctx.fillStyle = tempColor(Math.pow(10, logT));
    ctx.fillRect(x, 0, 1, barH);
  }
  ctx.font = '8px ui-monospace, monospace';
  ctx.fillStyle = 'rgba(150,175,210,0.8)';
  const ticks = [[2, '100 K'], [3.76, '5.8 kK'], [7.2, '16 MK'], [10, '10 GK']];
  for (const [lt, txt] of ticks) {
    const x = ((lt - 2) / 8) * W;
    ctx.fillRect(Math.min(x, W - 1), barH, 1, 3);
    ctx.textAlign = x < W * 0.2 ? 'left' : (x > W * 0.8 ? 'right' : 'center');
    ctx.fillText(txt, Math.min(Math.max(x, 1), W - 1), barH + 12);
  }
  ctx.textAlign = 'left';
}

// ----------------------------------------------------------------------------
// The prose that goes beside the diagram: the derived quantities the layers do
// not carry, chosen per kind of body because what is interesting about a
// neutron star (its compactness) is not what is interesting about a planet.
// ----------------------------------------------------------------------------
export function structureFacts(st) {
  const F = [];
  const add = (k, v) => { if (v != null && v !== '') F.push([k, v]); };
  add('mass', fmtMass(st.mass));
  if (st.type !== 'bh') add('radius', fmtLength(st.radiusAU));
  if (st.flattening > 1e-3) {
    add('shape', `R_eq/R_pol = ${(1 / (1 - st.flattening)).toFixed(3)}`);
    add('flattening', `f = ${st.flattening.toFixed(4)}`);
  }
  if (st.spinFrac > 1e-3) {
    add('spin', `${(st.spinFrac * 100).toFixed(1)}% of break-up`);
    add('period', fmtPeriod(st.spinPeriodSec));
  }
  switch (st.type) {
    case 'planet':
      add('composition', st.composition);
      add('density', fmtDensity(st.density));
      add('core temp', fmtTemp(st.Tc));
      add('max radius', `${st.maxRadiusEarth.toFixed(2)} R⊕ at ${Math.round(st.maxRadiusMassEarth)} M⊕`);
      break;
    case 'gas-giant':
      add('density', fmtDensity(st.density));
      add('core temp', fmtTemp(st.Tc));
      if (st.teff > 0) add('T_eff', fmtTemp(st.teff));
      break;
    case 'star':
      add('T_eff', fmtTemp(st.teff));
      if (st.spinFrac > 1e-3) add('pole / equator', `${fmtTemp(st.tPole)} / ${fmtTemp(st.tEq)}`);
      add('luminosity', `${st.luminosity < 1000 ? st.luminosity.toFixed(2) : st.luminosity.toExponential(2)} L☉`);
      add('L / L_Edd', st.eddington.toFixed(3));
      add('core temp', fmtTemp(st.Tc));
      add('core pressure', `${(st.Pc / 1e9).toExponential(2)} GPa`);
      add('core X(H)', st.X.toFixed(2));
      add('phase', st.phase?.label);
      add('MS lifetime', fmtYears(st.msLifetime));
      add('ends as', st.endState?.label);
      break;
    case 'neutron':
      add('density', fmtDensity(st.density));
      add('surface gravity', `${(st.surfaceGravity / 9.81).toExponential(2)} g`);
      add('compactness', `r_s/R = ${st.compactness.toFixed(3)}`);
      add('surface redshift', `${(st.redshift * 100).toFixed(1)}%`);
      add('TOV limit here', `${st.tovMax.toFixed(2)} M☉`);
      if (Number.isFinite(st.spinPeriodMs)) add('spin period', `${st.spinPeriodMs.toFixed(2)} ms`);
      break;
    case 'white-dwarf':
      add('density', fmtDensity(st.density));
      add('T_eff', fmtTemp(st.teff));
      add('Chandrasekhar', `${LIMITS.chandrasekhar} M☉`);
      break;
    case 'bh':
      add('event horizon', fmtLength(st.horizonAU));
      add('photon sphere', fmtLength(st.photonSphereAU));
      add('ISCO', fmtLength(st.iscoAU));
      if (st.spin > 0.01) add('spin a*', st.spin.toFixed(3));
      add('Hawking T', `${st.hawkingK.toExponential(2)} K`);
      add('evaporates in', `10${sup(Math.round(Math.log10(st.evaporationYr)))} yr`);
      break;
  }
  return F;
}

export function fmtPeriod(sec) {
  if (!Number.isFinite(sec)) return '—';
  if (sec < 1) return `${(sec * 1000).toFixed(2)} ms`;
  if (sec < 120) return `${sec.toFixed(2)} s`;
  if (sec < 7200) return `${(sec / 60).toFixed(1)} min`;
  if (sec < 3 * 86400) return `${(sec / 3600).toFixed(1)} h`;
  if (sec < 800 * 86400) return `${(sec / 86400).toFixed(1)} d`;
  return `${(sec / 3.156e7).toFixed(2)} yr`;
}

export function fmtYears(y) {
  if (!(y > 0) || !Number.isFinite(y)) return '—';
  if (y < 1e3) return `${y.toFixed(0)} yr`;
  if (y < 1e6) return `${(y / 1e3).toFixed(1)} kyr`;
  if (y < 1e9) return `${(y / 1e6).toFixed(1)} Myr`;
  if (y < 1e13) return `${(y / 1e9).toFixed(1)} Gyr`;
  return `${(y / 1e9).toExponential(1)} Gyr`;
}

export const VERDICT_CLASS = {
  [VERDICT.ok]: 'v-ok',
  [VERDICT.degenerate]: 'v-warn',
  [VERDICT.breakup]: 'v-bad',
  [VERDICT.collapse]: 'v-bad',
  [VERDICT.explode]: 'v-bad',
  [VERDICT.ignite]: 'v-info',
};

export { structureOf };
