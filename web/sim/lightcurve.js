import * as THREE from 'three';

// ============================================================================
// PHOTOMETER — the light curve and the radial velocity, measured
// ----------------------------------------------------------------------------
// Almost everything known about planets around other stars was learned from two
// numbers that a telescope can actually get: how bright the star is, and how
// fast it is moving toward or away. Neither one is a picture of a planet. So
// this instrument does not draw a planet either — it points at the running
// simulation from wherever the camera is and measures those two numbers, frame
// by frame, exactly as an observatory would.
//
// WHAT IT MEASURES
//
//   FLUX. Sum the luminosity of every star, subtract whatever is blocked. A
//   body of radius r crossing a star of radius R blocks the overlap of two
//   circles in the plane of the sky — but not uniformly, because a star is
//   LIMB DARKENED: you see deeper, hotter gas at the centre of the disc and
//   shallower, cooler gas at the edge, so the middle of the disc is brighter.
//   The linear law
//
//       I(μ)/I(0) = 1 − u(1 − μ),      μ = cos(angle from disc centre)
//
//   with u ≈ 0.6 for a solar-type star in visible light, is what gives a real
//   transit its rounded bottom instead of a flat one. It is integrated here by
//   sampling the planet's disc rather than by a closed form, because the closed
//   form only exists for the linear law and the sampling is honest for any of
//   them.
//
//   RADIAL VELOCITY. The component of a star's own velocity along the line of
//   sight. A star with a planet does not sit still — both orbit their common
//   centre of mass — and that motion is a Doppler shift in every line in its
//   spectrum. The amplitude is small: 127 m/s for a hot Jupiter, 9 cm/s for an
//   Earth. This reads it straight off the integrator's velocity vector, which
//   is why it agrees with the transit: the same orbit produces both.
//
// THE OBSERVER IS THE CAMERA. Not a fixed axis — the camera. That is not a
// shortcut, it is the lesson: a transit requires the orbit to be edge-on to
// whoever is looking, and for an Earth at 1 AU round a Sun-like star the
// chance of that is R☉/a = 0.47%. Climbing out of the orbital plane and
// watching the dips disappear is the fastest way to understand why the
// thousands of planets we know about are a biased sample of the ones there are.
//
// The observer is taken to be at INFINITY — the direction to the camera is
// used, but not its distance. A real one is parsecs away, which is far enough
// that every body in the system is at the same distance to one part in 10⁵.
// ============================================================================

const AU_PER_YR_TO_MS = 1.495978707e11 / 3.15576e7;   // 4740.57 m/s

// Sample points over a unit disc, spiralled so they are equal-area rather than
// bunched at the middle. 96 of them resolve a 1% transit to better than a part
// in 10³, which is finer than the chart can draw.
const DISC_SAMPLES = (() => {
  const pts = [];
  const n = 96, golden = Math.PI * (3 - Math.sqrt(5));
  for (let i = 0; i < n; i++) {
    const r = Math.sqrt((i + 0.5) / n), th = i * golden;
    pts.push([r * Math.cos(th), r * Math.sin(th)]);
  }
  return pts;
})();

const LIMB_U = 0.6;

const _d = new THREE.Vector3(), _e1 = new THREE.Vector3(), _e2 = new THREE.Vector3();

// ----------------------------------------------------------------------------
// One measurement of the system as seen from direction `u` (a unit vector from
// the system TOWARD the observer).
//
// Returns the total flux in solar luminosities as seen from unit distance, the
// same normalised by the unobscured total, the radial velocity of the brightest
// star in m/s (positive = receding), and a list of what is currently in front
// of what.
// ----------------------------------------------------------------------------
export function measure(bodies, u) {
  // A basis for the plane of the sky. Any two vectors perpendicular to u will
  // do — the measurement cannot depend on which, and does not.
  _e1.set(0, 1, 0);
  if (Math.abs(_e1.dot(u)) > 0.9) _e1.set(1, 0, 0);
  _e1.crossVectors(_e1, u).normalize();
  _e2.crossVectors(u, _e1).normalize();

  const stars = bodies.filter(b => b.alive !== false && b.luminosity > 0 && b.radius > 0);
  const occulters = bodies.filter(b => b.alive !== false && b.radius > 0);

  let flux = 0, total = 0;
  const events = [];
  for (const s of stars) {
    total += s.luminosity;
    let blocked = 0;
    const R = s.radius;
    const projected = [];
    for (const p of occulters) {
      if (p === s) continue;
      _d.subVectors(p.pos, s.pos);
      if (_d.dot(u) <= 0) continue;
      const x = _d.dot(_e1), y = _d.dot(_e2), r = p.radius;
      if (Math.hypot(x, y) >= R + r) continue;
      projected.push({ p, x, y, r });
    }
    const intensity = (x, y) => {
      const q2 = (x * x + y * y) / (R * R);
      return q2 < 1 ? 1 - LIMB_U * (1 - Math.sqrt(1 - q2)) : 0;
    };
    const contains = (p, x, y) => (x - p.x) ** 2 + (y - p.y) ** 2 <= p.r ** 2;
    if (projected.some(p => p.r >= R)) {
      // Sample the smaller disc. Sampling a huge occulter can miss the star
      // entirely, turning a total eclipse into no eclipse. Count the union of
      // silhouettes, including luminous companions, without double subtraction.
      let all = 0, hidden = 0;
      for (const [sx, sy] of DISC_SAMPLES) {
        const x = sx * R, y = sy * R, I = intensity(x, y);
        all += I;
        if (projected.some(p => contains(p, x, y))) hidden += I;
      }
      blocked = hidden / all;
      for (const p of projected) events.push({ star: s, body: p.p });
    } else for (let i = 0; i < projected.length; i++) {
      const p = projected[i];
      let acc = 0;
      for (const [sx, sy] of DISC_SAMPLES) {
        const x = p.x + sx * p.r, y = p.y + sy * p.r;
        if (projected.slice(0, i).some(prev => contains(prev, x, y))) continue;
        acc += intensity(x, y);
      }
      const cover = p.r * p.r * acc / (DISC_SAMPLES.length * R * R * (1 - LIMB_U / 3));
      blocked += cover;
      if (cover > 1e-7) events.push({ star: s, body: p.p, depth: cover });
    }
    flux += s.luminosity * Math.max(0, 1 - blocked);
  }

  // The radial velocity of the brightest star: what a spectrograph would put a
  // number on, since it is the one whose lines dominate the spectrum.
  let bright = null;
  for (const s of stars) if (!bright || s.luminosity > bright.luminosity) bright = s;
  const rv = bright ? -bright.vel.dot(u) * AU_PER_YR_TO_MS : 0;

  return { flux, rel: total > 0 ? flux / total : 1, rv, events, star: bright, total };
}

// ----------------------------------------------------------------------------
// The rolling chart. Two traces share one time axis, because the whole point is
// that the dip and the wobble come from the same orbit: the transit happens at
// the moment the star's radial velocity passes through zero going the right way.
// ----------------------------------------------------------------------------
export function createPhotometer({ canvas, span = 520 }) {
  const ctx = canvas.getContext('2d');
  const t = [], f = [], v = [];
  let mode = 'both';
  let last = { rel: 1, rv: 0, events: [] };

  function reset() { t.length = f.length = v.length = 0; }

  function sample(bodies, u, clock) {
    const m = measure(bodies, u);
    last = m;
    if (t.length && clock === t[t.length - 1]) {
      f[f.length - 1] = m.rel; v[v.length - 1] = m.rv;
      return m;
    }
    t.push(clock); f.push(m.rel); v.push(m.rv);
    if (t.length > span) { t.shift(); f.shift(); v.shift(); }
    return m;
  }

  function trace(x0, y0, w, h, ys, label, unit, color, opts = {}) {
    let lo = Infinity, hi = -Infinity;
    for (const y of ys) { if (y < lo) lo = y; if (y > hi) hi = y; }
    if (!isFinite(lo)) { lo = 0; hi = 1; }
    // A pad of at least `floor` keeps a flat trace from being amplified into
    // noise: with no planet transiting, the flux is 1.000000 and an autoscale
    // that fits the range would draw the last bit of floating-point as a
    // mountain range. A real photometer has a noise floor for the same reason.
    const floor = opts.floor ?? 0;
    const mid = (lo + hi) / 2, halfRaw = Math.max((hi - lo) / 2, floor / 2);
    const half = halfRaw * 1.25;
    lo = mid - half; hi = mid + half;

    ctx.strokeStyle = 'rgba(150,170,200,0.16)';
    ctx.lineWidth = 1;
    ctx.strokeRect(x0 + 0.5, y0 + 0.5, w - 1, h - 1);

    ctx.beginPath();
    for (let i = 0; i < ys.length; i++) {
      const px = x0 + (t[i] - t[0]) / Math.max(t[t.length - 1] - t[0], 1e-12) * w;
      const py = y0 + h - ((ys[i] - lo) / (hi - lo)) * h;
      if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.strokeStyle = color; ctx.lineWidth = 1.4; ctx.stroke();

    ctx.font = '10px ui-monospace, monospace';
    ctx.fillStyle = 'rgba(190,205,230,0.85)';
    ctx.fillText(label, x0 + 6, y0 + 12);
    ctx.fillStyle = 'rgba(150,170,200,0.6)';
    ctx.textAlign = 'right';
    ctx.fillText(opts.fmt(hi) + unit, x0 + w - 6, y0 + 12);
    ctx.fillText(opts.fmt(lo) + unit, x0 + w - 6, y0 + h - 5);
    ctx.textAlign = 'left';
  }

  function draw() {
    const W = canvas.width, H = canvas.height;
    ctx.clearRect(0, 0, W, H);
    if (t.length < 2) {
      ctx.fillStyle = 'rgba(150,170,200,0.55)';
      ctx.font = '11px ui-monospace, monospace';
      ctx.fillText('collecting…', 12, 22);
      return;
    }
    const pad = 8;
    const two = mode === 'both';
    const h = two ? (H - pad * 3) / 2 : H - pad * 2;
    if (mode !== 'rv') {
      trace(pad, pad, W - pad * 2, h, f, 'relative flux', '', '#ffd28a',
        { floor: 4e-4, fmt: x => x.toFixed(5) });
    }
    if (mode !== 'flux') {
      trace(pad, two ? pad * 2 + h : pad, W - pad * 2, h, v, 'radial velocity', ' m/s', '#7fc4ff',
        { floor: 2, fmt: x => x.toFixed(1) });
    }
  }

  return {
    reset, sample, draw,
    setMode(m) { mode = m; },
    get last() { return last; },
    get depthPPM() {
      let lo = 1; for (const y of f) if (y < lo) lo = y;
      return Math.round((1 - lo) * 1e6);
    },
    get amplitude() {
      let lo = Infinity, hi = -Infinity;
      for (const y of v) { if (y < lo) lo = y; if (y > hi) hi = y; }
      return isFinite(lo) ? (hi - lo) / 2 : 0;
    },
  };
}
