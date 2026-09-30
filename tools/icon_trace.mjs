// ============================================================================
// THE APP ICONS, RAY-TRACED — a Schwarzschild hole and a thin disk, as vectors.
// ----------------------------------------------------------------------------
//   node tools/icon_trace.mjs            writes assets/icons/*.svg and icon.svg
//
// Units G = c = M = 1. A photon's orbit obeys u'' = 3u² − u (u = 1/r, φ the
// angle swept in its own plane, measured from the observer's direction), and
// that orbit depends on the impact parameter b ALONE. The screen angle α only
// decides at which φ the ray pierces the disk plane: with the observer at
// inclination i, the n-th crossing is at
//     φₙ = atan2(−cos i, sin α sin i) + π + (n − 1)π.
// So one table of u(φ) per b serves every pixel angle, and the image of a disk
// ring of radius R, for each image order n, is the b at which u(b, φₙ) = 1/R.
// n = 1 is the disk seen directly (its far half arched over the top), n = 2 the
// underside wrapped round below the shadow, and the shadow's own edge is the
// critical b = 3√3.
//
// Shading is physical too. A Keplerian emitter's redshift is
//     g = √(1 − 3/r) / (1 − Ω L_z),   Ω = r^(−3/2),   L_z = −b cos α sin i,
// and the observed intensity goes as g⁴. L_z is −x sin i in screen units, so on
// any ONE ring the colour depends on screen x only: each ring is drawn as a
// single annulus under a single horizontal gradient, outer rings first, so each
// overlaps the last and there is no seam anywhere. No filters, no masks —
// nothing an SVG importer might not support.
// ============================================================================
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const BC = 3 * Math.sqrt(3);            // critical impact parameter: the shadow's edge
const H = 0.004, PHI_MAX = 3 * Math.PI + 0.1, NPHI = Math.ceil(PHI_MAX / H) + 1;

// b grid: coarse everywhere, very fine across the photon ring
const bs = [];
for (let b = 0.05; b < 40; b += 0.02) bs.push(b);
for (let b = BC - 0.4; b < BC + 0.6; b += 0.0004) bs.push(b);
bs.sort((a, c) => a - c);

const CAPTURED = NaN, ESCAPED = -1;
// u(φ) per b, RK4. Past r < 2 the ray is captured; past u < 0 it has escaped.
const table = bs.map((b) => {
  const u = new Float32Array(NPHI);
  let x = 0, v = 1 / b, end = null;
  const f = (x) => 3 * x * x - x;
  for (let i = 0; i < NPHI; i++) {
    if (end !== null) { u[i] = end; continue; }
    u[i] = x;
    const k1x = v, k1v = f(x);
    const k2x = v + 0.5 * H * k1v, k2v = f(x + 0.5 * H * k1x);
    const k3x = v + 0.5 * H * k2v, k3v = f(x + 0.5 * H * k2x);
    const k4x = v + H * k3v, k4v = f(x + H * k3x);
    x += (H / 6) * (k1x + 2 * k2x + 2 * k3x + k4x);
    v += (H / 6) * (k1v + 2 * k2v + 2 * k3v + k4v);
    if (x > 0.5) end = CAPTURED; else if (x < 0 && i > 2) end = ESCAPED;
  }
  return u;
});

// radius at angle φ along ray bi, as a key monotone in b: captured → 0, escaped → ∞
function rKey(bi, phi) {
  const t = phi / H, i = Math.floor(t);
  if (i + 1 >= NPHI) return Infinity;
  const a = table[bi][i], c = table[bi][i + 1];
  if (Number.isNaN(a) || Number.isNaN(c)) return 0;
  if (a < 0 || c < 0) return Infinity;
  const u = a + (c - a) * (t - i);
  return u > 0 ? 1 / u : Infinity;
}

// impact parameter whose n-th crossing lands on radius R
function bFor(alpha, n, R, incl) {
  const phi = Math.atan2(-Math.cos(incl), Math.sin(alpha) * Math.sin(incl)) + n * Math.PI;
  let prev = rKey(0, phi);
  for (let i = 1; i < bs.length; i++) {
    const cur = rKey(i, phi);
    if (prev < R && cur >= R) {
      if (!isFinite(cur) || prev === 0) return (bs[i - 1] + bs[i]) / 2;
      return bs[i - 1] + (bs[i] - bs[i - 1]) * (R - prev) / (cur - prev);
    }
    prev = cur;
  }
  return null;
}

// ---------------------------------------------------------------- colour
const RAMPS = {
  ember: [[0, [0, 0, 0]], [0.18, [70, 8, 2]], [0.38, [190, 50, 8]], [0.58, [255, 135, 30]],
          [0.78, [255, 205, 110]], [0.92, [255, 240, 205]], [1, [255, 252, 245]]],
  ice:   [[0, [0, 0, 0]], [0.2, [10, 20, 60]], [0.42, [40, 80, 190]], [0.65, [110, 170, 255]],
          [0.85, [200, 225, 255]], [1, [250, 252, 255]]],
};
function ramp(name, t) {
  const R = RAMPS[name]; t = Math.max(0, Math.min(1, t));
  for (let i = 1; i < R.length; i++) if (t <= R[i][0]) {
    const [t0, c0] = R[i - 1], [t1, c1] = R[i], k = (t - t0) / (t1 - t0);
    return c0.map((v, j) => v + (c1[j] - v) * k);
  }
  return R.at(-1)[1];
}
const hex = (c) => '#' + c.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');
const f1 = (v) => (Math.round(v * 10) / 10).toString();

// ---------------------------------------------------------------- build
function build(o) {
  const incl = (90 - o.elev) * Math.PI / 180;        // elev: camera height above the disk plane
  const NA = 84;
  // α warped so samples crowd the ellipse ends (α = 0, π), where the contour turns hardest
  const alphas = Array.from({ length: NA }, (_, i) => { const t = (i / NA) * 2 * Math.PI; return t - 0.4 * Math.sin(2 * t); });
  const K = { 1: 30, 2: 12 };
  const radii = (n) => Array.from({ length: K[n] + 1 }, (_, j) => o.rIn * Math.pow(o.rOut / o.rIn, j / K[n]));
  const grid = {};
  for (const n of [1, 2]) grid[n] = radii(n).map((R) => alphas.map((a) => {
    const b = bFor(a, n, R, incl);
    return b == null ? null : [b * Math.cos(a), b * Math.sin(a)];
  }).filter(Boolean));

  // The HOLE sits at the centre of the canvas; the scale fits the furthest
  // point of either image inside `fit`, which is the same whatever the tilt.
  const far = Math.max(...[grid[1].at(-1), grid[2].at(-1)].flat().map(([x, y]) => Math.hypot(x, y)));
  const s = o.fit / far;
  const X = (x) => 32 + s * x, Y = (y) => 32 - s * y;
  const pt = ([x, y]) => f1(X(x)) + ' ' + f1(Y(y));
  const bg = [5, 6, 10];

  const Iem = (r) => Math.pow(o.rIn / r, 2) * (1 - Math.pow(Math.max(0, (r - o.rOut * 0.55) / (o.rOut * 0.45)), 2));
  // ramp colour, faded into the background below t = 0.3 rather than made transparent
  const shade = (r, x) => {
    const g = Math.sqrt(1 - 3 / r) / (1 + Math.pow(r, -1.5) * x * Math.sin(incl) * o.doppler);
    const t = 1 - Math.exp(-Math.pow(g, 4) * Iem(r) * o.gain);
    const k = Math.min(1, t / 0.3);
    return hex(ramp(o.ramp, t).map((v, j) => bg[j] + (v - bg[j]) * k));
  };

  let defs = '', body = '', gid = 0;
  const rings = (n) => {
    const rs = radii(n), inner = grid[n][0].map(pt).join('L');
    for (let j = rs.length - 1; j >= 1; j--) {
      const ring = grid[n][j], xm = Math.max(...ring.map((p) => Math.abs(p[0])));
      const rm = Math.sqrt(rs[j] * rs[j - 1]);
      let stops = '';
      for (let k = 0; k <= 10; k++) stops += `<stop offset="${k / 10}" stop-color="${shade(rm, -xm + (2 * xm * k) / 10)}"/>`;
      const id = `${o.id}${gid++}`;
      defs += `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="${f1(X(-xm))}" y1="0" x2="${f1(X(xm))}" y2="0">${stops}</linearGradient>`;
      body += `<path fill-rule="evenodd" fill="url(#${id})" d="M${ring.map(pt).join('L')}ZM${inner}Z"/>`;
    }
  };

  // photon ring, brighter on the approaching (left) side
  const rr = f1(s * BC * 1.012);
  defs += `<linearGradient id="${o.id}ring" gradientUnits="userSpaceOnUse" x1="${f1(32 - s * BC)}" y1="0" x2="${f1(32 + s * BC)}" y2="0"><stop offset="0" stop-color="${o.ringL}"/><stop offset="1" stop-color="${o.ringR}"/></linearGradient>`;
  body += `<circle cx="32" cy="32" r="${f1(s * BC)}" fill="#000"/>`;
  body += `<circle cx="32" cy="32" r="${rr}" fill="none" stroke="url(#${o.id}ring)" stroke-width="0.45"/>`;
  rings(2);        // underside first: the direct image passes in front of it
  rings(1);

  const stars = STARS.map(([x, y, r, a]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="#fff" fill-opacity="${a}"/>`).join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs>${defs}</defs>` +
    `<rect width="64" height="64" rx="13" fill="${hex(bg)}"/>${stars}<g transform="rotate(${o.tilt} 32 32)">${body}</g></svg>\n`;
}

const STARS = [[9, 11, 0.45, 0.8], [55, 10, 0.35, 0.6], [52, 55, 0.4, 0.7], [11, 52, 0.3, 0.5], [46, 14, 0.25, 0.5], [21, 57, 0.25, 0.4]];

// The two icons. Keep in step with ui/app_icon.gd's ICONS.
const ICONS = {
  // full beaming: the approaching side at ~0.4c blazes, the receding side all but vanishes
  ember: { id: 'e', elev: 10, tilt: -14, rIn: 6, rOut: 18, fit: 29, doppler: 1, ramp: 'ember', gain: 3,
    ringL: '#fff4e0', ringR: '#7a2a0a' },
  // a hotter disk (T above ~20 000 K reads blue-white), beaming at 70%
  bluehot: { id: 'b', elev: 10, tilt: -16, rIn: 6, rOut: 18, fit: 29, doppler: 0.7, ramp: 'ice', gain: 3,
    ringL: '#f2f6ff', ringR: '#3050a0' },
};

fs.mkdirSync(path.join(ROOT, 'assets/icons'), { recursive: true });
for (const [name, spec] of Object.entries(ICONS)) {
  const svg = build(spec);
  fs.writeFileSync(path.join(ROOT, `assets/icons/${name}.svg`), svg);
  console.log(`assets/icons/${name}.svg  ${(svg.length / 1024).toFixed(1)} KB`);
}
// the project icon (and every export's) is the default choice
fs.copyFileSync(path.join(ROOT, 'assets/icons/ember.svg'), path.join(ROOT, 'icon.svg'));
console.log('icon.svg = ember');
