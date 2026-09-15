import { schwarzschild } from './physics.js';

// ============================================================================
// GRAVITATIONAL-WAVE DETECTOR — the strain, and what a detector does with it
// ----------------------------------------------------------------------------
// Two masses in orbit radiate gravitational waves, which is not a metaphor for
// anything: the orbit really does shrink, and the energy really does leave. The
// sim already integrates that — applyGWReaction() in sim/physics.js applies the
// leading-order (2.5-PN) energy loss as a drag, which is why the inspiral in
// #bhmerger accelerates instead of repeating. What this module does is read the
// SAME binary and work out what a detector on Earth would record.
//
// WHAT A DETECTOR RECORDS is not energy, or a photograph — it is a STRAIN: a
// fractional change in length, h = ΔL/L. For a circular binary seen at
// inclination ι and distance D,
//
//     h₊ = (4 G² μ M / c⁴ D r) · (1+cos²ι)/2 · cos 2Φ
//     h× = (4 G² μ M / c⁴ D r) · cos ι       · sin 2Φ
//
// with M the total mass, μ = m₁m₂/M the reduced mass, r the separation and Φ
// the orbital phase. Two things in that expression do all the teaching:
//
//   · The wave is at TWICE the orbital frequency. A binary is symmetric under a
//     half turn — swap the two stars and the mass distribution is the same — so
//     the quadrupole comes back to itself twice per orbit.
//   · h falls as 1/D, not as 1/D². Gravitational-wave astronomy measures an
//     amplitude, not a power, so doubling a detector's sensitivity doubles its
//     reach and so multiplies the volume it can see by eight.
//
// THE SCALE PROBLEM, AND HOW IT IS HANDLED HONESTLY. The scenario draws a
// 36 M☉ black hole's horizon at 0.02 AU so that you can see it; the real one is
// 106 km, twenty-eight thousand times smaller. A strain computed from the drawn
// separation would be true of nothing. So the mapping used here is the one
// invariant both versions share:
//
//     THE DRAWN BINARY AND THE REAL ONE ARE AT THE SAME FRACTION OF THEIR OWN
//     MERGER SEPARATION.
//
// The sim merges its pair when they touch; a real compact binary merges at
// about one Schwarzschild radius of the total mass. Dividing one by the other
// gives a single scale factor, applied to the separation — and then the
// frequency, the amplitude and the chirp rate are all the real ones, sweeping
// up through the detector band exactly as the picture spirals in. The detector
// clock is derived the same way: the orbital PHASE is the thing the two
// versions share, so equivalent time advances by ΔΦ/ω_real. The accelerated
// reaction in the demo is NOT a physical chirp rate; merger/ringdown and
// detector antenna response are outside this illustrative model.
// ============================================================================

const G_SI = 6.67430e-11;
const C = 2.99792458e8;
const M_SUN = 1.98892e30;
const AU_M = 1.495978707e11;
const MPC_M = 3.0857e22;

// LIGO's useful band. Below 20 Hz it is buried in seismic noise (which is why a
// detector on the ground can never see the year-long early inspiral, and why
// LISA has to be in space); above a few kHz the laser's own shot noise wins.
export const BAND_LO = 20, BAND_HI = 2000;

// ----------------------------------------------------------------------------
// Pick the binary: the two heaviest bodies that are close enough together to be
// a pair rather than two unrelated objects in the same scene.
// ----------------------------------------------------------------------------
export function findBinary(bodies) {
  const live = bodies.filter(b => b.alive !== false && (b.type === 'bh' || b.type === 'neutron')).sort((a, b) => b.mass - a.mass);
  if (live.length < 2) return null;
  const a = live[0], b = live[1];
  return { a, b };
}

// The separation at which THIS simulation will call it a merger: the sum of the
// radii the collision test actually uses.
function contactAU(b) {
  return b.contactAU || b.radius || b.rs || 1e-9;
}

// ----------------------------------------------------------------------------
// One reading. `distMpc` is where the source is put — 410 Mpc is GW150914's
// measured luminosity distance, 40 Mpc is GW170817's.
// ----------------------------------------------------------------------------
export function strainOf(pair, { distMpc = 410, incl = 0 } = {}) {
  if (!pair) return null;
  const { a, b } = pair;
  const m1 = a.mass, m2 = b.mass, Msun = m1 + m2;
  const rSim = a.pos.distanceTo(b.pos);
  if (!(rSim > 0)) return null;

  // The merger-referenced mapping described in the header.
  const mergeSim = contactAU(a) + contactAU(b);
  const mergeReal = schwarzschild(Msun);            // AU
  const scale = mergeReal / Math.max(mergeSim, 1e-12);
  const rAU = rSim * scale;
  const r = rAU * AU_M;                              // metres

  const M = Msun * M_SUN, mu = (m1 * m2 / Msun) * M_SUN;
  const D = distMpc * MPC_M;

  const omega = Math.sqrt(G_SI * M / (r * r * r));   // rad/s, orbital
  const fGW = omega / Math.PI;                       // twice the orbital frequency
  const h0 = 4 * G_SI * G_SI * mu * M / (C * C * C * C * D * r);

  // The chirp mass is the ONE combination of the two masses the waveform
  // actually determines, which is why every detection is quoted with one:
  // the early inspiral depends on m1 and m2 only through M_c.
  const Mc = Math.pow(m1 * m2, 3 / 5) / Math.pow(Msun, 1 / 5);

  return {
    m1, m2, Msun, Mc, rAU, rSchwarz: rAU / mergeReal,
    omega, fGW, h0, distMpc,
    hPlus: h0 * (1 + Math.cos(incl) ** 2) / 2,
    hCross: h0 * Math.cos(incl),
    inBand: fGW >= BAND_LO && fGW <= BAND_HI,
  };
}

// ----------------------------------------------------------------------------
// The instrument: a strain trace on a real-seconds axis, plus the L-shaped
// interferometer whose arms it is stretching.
// ----------------------------------------------------------------------------
export function createGWDetector({ canvas, armM = 4000, distMpc = 410 }) {
  const ctx = canvas.getContext('2d');
  const hs = [], ts = [];
  // 200 samples across the chart. A sample is one FRAME, and
  // at the pace these lessons run there are about thirty frames per orbit —
  // fifteen per wave cycle, since the wave is at twice the orbital frequency.
  // At 600 the cycles are four pixels apart and the chirp renders as a solid
  // block; at 200 you can see the individual oscillations tighten, which is
  // the entire thing the plot is for.
  const SPAN = 200;
  let phase = 0;          // accumulated orbital phase, radians
  let lastTheta = null;    // last measured orbital angle, for unwrapping
  let tReal = 0;           // detector clock, seconds
  let last = null;

  function reset() { hs.length = ts.length = 0; phase = 0; lastTheta = null; tReal = 0; last = null; }

  function sample(bodies) {
    const pair = findBinary(bodies);
    const s = strainOf(pair, { distMpc });
    last = s;
    if (!s) return null;

    // The orbital angle in the orbital plane. Unwrapped so the phase is
    // monotonic even though atan2 is not.
    const { a, b } = pair;
    const dx = b.pos.x - a.pos.x, dz = b.pos.z - a.pos.z;
    const theta = Math.atan2(dz, dx);
    if (lastTheta !== null) {
      let d = theta - lastTheta;
      while (d > Math.PI) d -= 2 * Math.PI;
      while (d < -Math.PI) d += 2 * Math.PI;
      if (Math.abs(d) < 1e-12) return s;
      phase += d;
      // The detector's own clock. ΔΦ is shared between the drawn binary and
      // the real one; dividing by the REAL angular rate turns it into real
      // seconds, which is what makes the trace a waveform and not a picture.
      tReal += Math.abs(d) / s.omega;
    }
    lastTheta = theta;

    hs.push(s.hPlus * Math.cos(2 * phase));
    ts.push(tReal);
    if (hs.length > SPAN) { hs.shift(); ts.shift(); }
    return s;
  }

  function draw() {
    const W = canvas.width, H = canvas.height;
    ctx.clearRect(0, 0, W, H);
    ctx.font = '10px ui-monospace, monospace';

    const armH = 78, gap = 10;
    const traceH = H - armH - gap;

    // ---- strain trace
    let amp = 1e-24;
    for (const h of hs) amp = Math.max(amp, Math.abs(h));
    ctx.strokeStyle = 'rgba(150,170,200,0.16)';
    ctx.strokeRect(0.5, 0.5, W - 1, traceH - 1);
    ctx.beginPath();
    ctx.moveTo(0, traceH / 2); ctx.lineTo(W, traceH / 2);
    ctx.strokeStyle = 'rgba(150,170,200,0.12)'; ctx.stroke();

    if (hs.length > 1) {
      ctx.beginPath();
      for (let i = 0; i < hs.length; i++) {
        const x = (ts[i] - ts[0]) / Math.max(ts[ts.length - 1] - ts[0], 1e-12) * W;
        const y = traceH / 2 - (hs[i] / amp) * (traceH / 2 - 8);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      }
      ctx.strokeStyle = '#8fe0c0'; ctx.lineWidth = 1.3; ctx.stroke();
    } else {
      ctx.fillStyle = 'rgba(150,170,200,0.55)';
      ctx.fillText('waiting for a binary…', 10, 20);
    }

    ctx.fillStyle = 'rgba(190,205,230,0.85)';
    ctx.fillText('strain  h(t)', 6, 12);
    ctx.textAlign = 'right';
    ctx.fillStyle = 'rgba(150,170,200,0.6)';
    ctx.fillText(`±${(amp * 1e21).toFixed(2)}×10⁻²¹`, W - 6, 12);
    if (ts.length > 1) ctx.fillText(`${(ts[ts.length - 1] - ts[0]).toFixed(3)} s of detector time`, W - 6, traceH - 6);
    ctx.textAlign = 'left';

    // ---- the interferometer, with its arms stretched by the current strain.
    // The schematic exaggerates the strain with bounded, adaptive gain; the
    // readout gives physical displacement per arm, h L / 2.
    const h = last ? last.hPlus * Math.cos(2 * phase) : 0;
    const y0 = traceH + gap;
    const cx = 54, cy = y0 + armH - 16, L = 46;
    // Keep the schematic inside its box at high strain; report the actual
    // displacement numerically. A fixed 10^23 gain inverted the arms.
    const stretch = 0.3 * Math.tanh(h / amp);
    const ex = 1 + stretch, ey = 1 - stretch;
    ctx.strokeStyle = 'rgba(140,200,255,0.85)'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + L * ex, cy); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx, cy - L * ey); ctx.stroke();
    ctx.fillStyle = '#ffd28a';
    ctx.fillRect(cx - 3, cy - 3, 6, 6);
    ctx.fillStyle = 'rgba(190,205,230,0.9)';
    ctx.fillRect(cx + L * ex - 2, cy - 5, 3, 10);
    ctx.fillRect(cx - 5, cy - L * ey - 1, 10, 3);

    const tx = cx + L + 26;
    ctx.fillStyle = 'rgba(190,205,230,0.85)';
    if (last) {
      const dL = Math.abs(h) * armM / 2;
      ctx.fillText(`f_GW  ${last.fGW < 1 ? last.fGW.toExponential(2) : last.fGW.toFixed(1)} Hz`, tx, y0 + 14);
      ctx.fillText(`h     ${last.h0.toExponential(2)}`, tx, y0 + 28);
      ctx.fillText(`ΔL    ${dL.toExponential(2)} m  (${armM / 1000} km arm)`, tx, y0 + 42);
      ctx.fillText(`M_c   ${last.Mc.toFixed(1)} M☉ at ${last.distMpc} Mpc`, tx, y0 + 56);
      ctx.fillStyle = last.inBand ? '#8fe0c0' : 'rgba(150,170,200,0.55)';
      ctx.fillText(last.inBand ? '● in the LIGO band' : last.fGW < BAND_LO ? `○ below ${BAND_LO} Hz — seismic noise` : `○ above ${BAND_HI} Hz — shot noise`, tx, y0 + 70);
    } else {
      ctx.fillText('no binary in this scenario', tx, y0 + 14);
    }
  }

  return { sample, draw, reset, get last() { return last; } };
}
