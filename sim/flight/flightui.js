import * as THREE from 'three';
import { fmtDur, MODE } from './guidance.js';
import { fmtYears } from './relativity.js';

// ============================================================================
// FLIGHT INSTRUMENTS
// ----------------------------------------------------------------------------
// A navball, a telemetry block, a stage stack, two clocks and a targeting menu.
//
// THE NAVBALL is the one instrument worth building properly, because it is the
// only one that answers the question a pilot actually has — "which way am I
// pointing, relative to where I am going and to the ground below" — in a single
// glance. It is drawn as a true orthographic projection of a sphere fixed in the
// SURFACE frame, seen from the vehicle's own nose:
//
//   · a great circle (the horizon) projects to an ellipse whose semi-minor axis
//     is R·|n·z|, where n is the local up expressed in view coordinates;
//   · a small circle at latitude φ (a pitch line) projects to an ellipse of
//     semi-axes R·cos φ, offset R·sin φ along the projection of n.
//
// Both fall out of the same three lines, which is why the ladder stays correct
// at any attitude instead of being faked with a tilted straight line.
//
// THE TWO CLOCKS are the other thing this UI exists for. MET is the vehicle's
// own proper time and UT is coordinate time; the readout between them is their
// accumulated difference, which is microseconds in low orbit — where it is
// exactly the GPS correction — and years at relativistic speed. Same number.
// ============================================================================

const MARKERS = [
  { key: 'prograde',   glyph: '⊙', color: '#ffe27a' },
  { key: 'retrograde', glyph: '⊘', color: '#ffe27a' },
  { key: 'normal',     glyph: '▲', color: '#c08cff' },
  { key: 'antinormal', glyph: '▼', color: '#c08cff' },
  { key: 'radial',     glyph: '◆', color: '#6fd3ff' },
  { key: 'target',     glyph: '⬟', color: '#8cffb0' },
  { key: 'node',       glyph: '✦', color: '#5fe0ff' },
];

export function createNavball(canvas) {
  const ctx = canvas.getContext('2d');
  const _m = new THREE.Matrix4();
  const _v = new THREE.Vector3();

  /**
   * @param q      vessel attitude (body +Y is the nose)
   * @param up     local up, world
   * @param north  local north, world
   * @param vecs   { prograde, retrograde, ... } world directions to mark
   */
  function draw(q, up, north, vecs, extra = {}) {
    const W = canvas.width, H = canvas.height, R = Math.min(W, H) * 0.44;
    const cx = W / 2, cy = H / 2;
    ctx.clearRect(0, 0, W, H);

    // View basis: the camera looks along the vehicle's nose (+Y in body space).
    const fwd = new THREE.Vector3(0, 1, 0).applyQuaternion(q);         // into the screen
    const rgt = new THREE.Vector3(1, 0, 0).applyQuaternion(q);         // screen right
    const upv = new THREE.Vector3(0, 0, -1).applyQuaternion(q);        // screen up
    // world → view (x right, y up, z toward the viewer, i.e. −forward)
    const toView = (w, out) => out.set(w.dot(rgt), w.dot(upv), -w.dot(fwd));

    const n = toView(up, new THREE.Vector3());
    const nxy = Math.hypot(n.x, n.y);
    const ang = nxy > 1e-6 ? Math.atan2(n.y, n.x) : 0;

    ctx.save();
    ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.clip();

    // sky and ground hemispheres
    ctx.fillStyle = '#2a4d78'; ctx.fillRect(0, 0, W, H);
    ctx.save();
    ctx.translate(cx, cy); ctx.rotate(ang);
    // The horizon ellipse: full radius across, squashed by how much the up
    // vector points at the viewer.
    ctx.beginPath();
    ctx.ellipse(0, 0, R * Math.abs(n.z), R, 0, 0, Math.PI * 2);
    ctx.fillStyle = '#6b5334';
    // Which side is ground depends on which way up leans out of the screen.
    ctx.rect(n.x >= 0 ? -R * 1.2 : 0, -R * 1.2, R * 1.2, R * 2.4);
    ctx.fill('evenodd');
    ctx.restore();

    // pitch ladder: small circles every 15°, projected the same way
    ctx.lineWidth = 1;
    for (let p = -75; p <= 75; p += 15) {
      if (p === 0) continue;
      const s = Math.sin(p * Math.PI / 180), c = Math.cos(p * Math.PI / 180);
      ctx.save();
      ctx.translate(cx + n.x * R * s, cy - n.y * R * s);
      ctx.rotate(ang);
      ctx.strokeStyle = p > 0 ? 'rgba(200,225,255,0.42)' : 'rgba(255,210,170,0.34)';
      ctx.beginPath();
      ctx.ellipse(0, 0, R * c * Math.abs(n.z), R * c, 0, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }
    // horizon line, drawn last so it sits on top
    ctx.save();
    ctx.translate(cx, cy); ctx.rotate(ang);
    ctx.strokeStyle = 'rgba(255,255,255,0.85)'; ctx.lineWidth = 1.6;
    ctx.beginPath(); ctx.ellipse(0, 0, R * Math.abs(n.z), R, 0, 0, Math.PI * 2); ctx.stroke();
    ctx.restore();

    // meridians every 45°, for heading
    const e = new THREE.Vector3().crossVectors(up, north).normalize();
    for (let h = 0; h < 360; h += 45) {
      const a = h * Math.PI / 180;
      const m = new THREE.Vector3().copy(north).multiplyScalar(Math.cos(a))
        .addScaledVector(e, Math.sin(a));
      // great circle with normal m
      const mv = toView(m, _v.clone());
      const mxy = Math.hypot(mv.x, mv.y);
      const ma = mxy > 1e-6 ? Math.atan2(mv.y, mv.x) : 0;
      ctx.save(); ctx.translate(cx, cy); ctx.rotate(ma);
      ctx.strokeStyle = h === 0 ? 'rgba(255,255,255,0.55)' : 'rgba(255,255,255,0.16)';
      ctx.lineWidth = h === 0 ? 1.4 : 1;
      ctx.beginPath(); ctx.ellipse(0, 0, R * Math.abs(mv.z), R, 0, 0, Math.PI * 2); ctx.stroke();
      ctx.restore();
    }
    ctx.restore();

    // markers
    for (const M of MARKERS) {
      const w = vecs[M.key];
      if (!w) continue;
      toView(w, _v);
      const x = cx + _v.x * R, y = cy - _v.y * R;
      const front = _v.z > 0;
      ctx.globalAlpha = front ? 1 : 0.30;
      ctx.fillStyle = M.color;
      ctx.font = `${Math.round(R * 0.26)}px system-ui, sans-serif`;
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText(M.glyph, x, y);
      ctx.globalAlpha = 1;
    }

    // the fixed reticle: where the nose is pointing, always dead centre
    ctx.strokeStyle = '#ffcf4d'; ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(cx - R * 0.20, cy); ctx.lineTo(cx - R * 0.06, cy);
    ctx.moveTo(cx + R * 0.06, cy); ctx.lineTo(cx + R * 0.20, cy);
    ctx.moveTo(cx, cy - R * 0.14); ctx.lineTo(cx, cy - R * 0.05);
    ctx.stroke();
    ctx.beginPath(); ctx.arc(cx, cy, R * 0.045, 0, Math.PI * 2); ctx.stroke();

    // bezel
    ctx.strokeStyle = 'rgba(120,190,255,0.45)'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(cx, cy, R + 1, 0, Math.PI * 2); ctx.stroke();

    // pitch / heading numbers
    const pitch = Math.asin(THREE.MathUtils.clamp(fwd.dot(up), -1, 1)) * 180 / Math.PI;
    let hdg = Math.atan2(fwd.dot(e), fwd.dot(north)) * 180 / Math.PI;
    if (hdg < 0) hdg += 360;
    ctx.fillStyle = '#cfe6ff';
    ctx.font = `600 ${Math.round(R * 0.17)}px ui-monospace, monospace`;
    ctx.textAlign = 'left';  ctx.fillText(`${pitch >= 0 ? '+' : ''}${pitch.toFixed(0)}°`, 4, H - 6);
    ctx.textAlign = 'right'; ctx.fillText(`${hdg.toFixed(0)}°`, W - 4, H - 6);
    if (extra.roll != null) {
      ctx.textAlign = 'center';
      ctx.fillText(`${extra.roll.toFixed(0)}°r`, W / 2, H - 6);
    }
  }
  return { draw };
}

// ---------------------------------------------------------------------------
// Formatters. Distances span from metres on the pad to light years in cruise,
// so there is one function and it picks the unit rather than the caller.
// ---------------------------------------------------------------------------
export function fmtDist(m) {
  if (!Number.isFinite(m)) return '—';
  const a = Math.abs(m);
  if (a < 1000) return `${m.toFixed(0)} m`;
  if (a < 1e6) return `${(m / 1000).toFixed(2)} km`;
  if (a < 1.4e11) return `${(m / 1000).toFixed(0)} km`;
  if (a < 9.4e15) return `${(m / 1.495978707e11).toFixed(3)} AU`;
  return `${(m / 9.4607304725808e15).toFixed(3)} ly`;
}
export function fmtSpeed(v) {
  if (!Number.isFinite(v)) return '—';
  return Math.abs(v) < 1000 ? `${v.toFixed(1)} m/s` : `${(v / 1000).toFixed(3)} km/s`;
}
export function fmtMassT(kg) {
  if (kg > 1e6) return `${(kg / 1e6).toFixed(2)} kt`;
  if (kg > 1000) return `${(kg / 1000).toFixed(1)} t`;
  return `${kg.toFixed(0)} kg`;
}
/**
 * The clock-difference readout. This is the whole point of carrying two clocks,
 * and it has to stay readable across twelve orders of magnitude: nanoseconds on
 * the pad, tens of microseconds a day in low orbit (the GPS number), years in
 * interstellar cruise.
 */
export function fmtClockDelta(s) {
  const a = Math.abs(s);
  const sign = s < 0 ? '−' : '+';
  if (a < 1e-9)  return `${sign}${(a * 1e12).toFixed(2)} ps`;
  if (a < 1e-6)  return `${sign}${(a * 1e9).toFixed(2)} ns`;
  if (a < 1e-3)  return `${sign}${(a * 1e6).toFixed(3)} µs`;
  if (a < 1)     return `${sign}${(a * 1e3).toFixed(3)} ms`;
  if (a < 60)    return `${sign}${a.toFixed(3)} s`;
  if (a < 86400) return `${sign}${fmtDur(a)}`;
  return `${sign}${fmtYears(a / (365.25 * 86400))}`;
}

// ---------------------------------------------------------------------------
// THE PANEL
// ---------------------------------------------------------------------------
export function createFlightHUD(root, hooks) {
  root.innerHTML = `
    <div class="fl-top">
      <canvas class="fl-navball" width="188" height="188"></canvas>
      <div class="fl-tape">
        <div class="fl-throttle"><div class="fl-throttle-fill"></div><span>THR</span></div>
        <div class="fl-vs"><div class="fl-vs-mark"></div><span>V/S</span></div>
      </div>
    </div>
    <div class="fl-status"></div>
    <div class="fl-grid"></div>
    <div class="fl-clocks">
      <div class="fl-clock"><span class="k">MET · ship</span><span class="v" data-met>—</span></div>
      <div class="fl-clock"><span class="k">UT · coordinate</span><span class="v" data-ut>—</span></div>
      <div class="fl-clock delta"><span class="k">ship − ground</span><span class="v" data-dt>—</span></div>
    </div>
    <div class="fl-section">Stages</div>
    <div class="fl-stages"></div>
    <div class="fl-section">Autopilot</div>
    <div class="fl-modes"></div>
    <div class="fl-programs"></div>
    <div class="fl-section">Target</div>
    <select class="fl-target"><option value="">— none —</option></select>
    <div class="fl-plan"></div>
    <div class="fl-section">Flight log</div>
    <div class="fl-log"></div>`;

  const q = (s) => root.querySelector(s);
  const navCanvas = q('.fl-navball');
  const navball = createNavball(navCanvas);
  const grid = q('.fl-grid'), stagesEl = q('.fl-stages'), logEl = q('.fl-log');
  const statusEl = q('.fl-status'), planEl = q('.fl-plan'), targetSel = q('.fl-target');
  const thrFill = q('.fl-throttle-fill'), vsMark = q('.fl-vs-mark');

  const MODES = [
    ['prograde', 'PRO'], ['retrograde', 'RETRO'], ['normal', 'NML'], ['antinormal', 'ANML'],
    ['radial', 'RAD'], ['antiradial', 'ARAD'], ['target', 'TGT'], ['off', 'OFF'],
  ];
  q('.fl-modes').innerHTML = MODES.map(([k, l]) =>
    `<button class="fl-mode" data-mode="${k}">${l}</button>`).join('');
  const PROGRAMS = [
    ['ascent', 'Launch to orbit', 'Vertical rise, pitch program inside an angle-of-attack limit, then a closed loop on the climb rate until apoapsis reaches its target.'],
    ['circularize', 'Circularize', 'Coast to the apsis and fly an insertion burn — steered live, because a long burn is not an impulse.'],
    ['transfer', 'Transfer to target', 'Hohmann to the selected body, with the launch window computed and waited for.'],
    ['deorbit', 'Deorbit', 'Drop periapsis into the atmosphere (or into the ground, where there is no atmosphere).'],
    ['land', 'Land (airless)', "Apollo's own P63 / P64 / P66 sequence, on its published gate conditions."],
    ['hoverslam', 'Propulsive landing', 'Entry burn, then a hoverslam: ignition altitude solved from v²/2(F/m − g) every step.'],
    ['edl', 'Entry, descent & landing', 'Aeroshell, supersonic parachute, backshell separation, powered descent, sky crane.'],
    ['cruise', 'Interstellar cruise', 'Leave the system on the exact constant-proper-acceleration solution: accelerate, coast, flip and burn. Two clocks, and the sky aberrates.'],
  ];
  q('.fl-programs').innerHTML = PROGRAMS.map(([k, l, t]) =>
    `<button class="fl-prog" data-prog="${k}" title="${t}">${l}</button>`).join('');

  root.querySelectorAll('[data-mode]').forEach(b =>
    b.addEventListener('click', () => hooks.setMode(b.dataset.mode)));
  root.querySelectorAll('[data-prog]').forEach(b =>
    b.addEventListener('click', () => hooks.runProgram(b.dataset.prog)));
  targetSel.addEventListener('change', () => hooks.setTarget(targetSel.value));

  let lastLog = 0;

  return {
    navCanvas,
    setTargets(names, current) {
      targetSel.innerHTML = '<option value="">— none —</option>' +
        names.map(n => `<option value="${n}"${n === current ? ' selected' : ''}>${n}</option>`).join('');
    },
    update(s) {
      const t = s.telemetry, v = s.vessel;
      navball.draw(v.q, s.up, s.north, s.markers, { roll: s.roll });
      statusEl.textContent = s.status;
      statusEl.className = 'fl-status' + (v.failure ? ' fail' : v.phase === 'landed' ? ' good' : '');

      thrFill.style.height = `${(v.throttle * 100).toFixed(0)}%`;
      const vs = THREE.MathUtils.clamp((t.vertical || 0) / 400, -1, 1);
      vsMark.style.bottom = `${(50 + vs * 46).toFixed(1)}%`;

      const rows = [
        ['altitude', fmtDist(t.alt)],
        ['speed', fmtSpeed(t.speed)],
        ['vertical', fmtSpeed(t.vertical)],
        ['apoapsis', Number.isFinite(t.apo) ? fmtDist(t.apo) : 'escape'],
        ['periapsis', fmtDist(t.peri)],
        ['period', t.period && Number.isFinite(t.period) ? fmtDur(t.period) : '—'],
        ['eccentricity', (t.ecc ?? 0).toFixed(4)],
        ['inclination', `${(t.inc ?? 0).toFixed(2)}°`],
        ['dyn. pressure', `${((t.q || 0) / 1000).toFixed(2)} kPa`],
        ['mach', (t.mach || 0) < 0.01 ? '—' : (t.mach).toFixed(2)],
        ['g-load', `${(t.gees || 0).toFixed(2)} g`],
        ['heat flux', `${((t.heat || 0) / 1e4).toFixed(1)} W/cm²`],
        ['mass', fmtMassT(t.mass || 0)],
        ['thrust', `${((t.thrust || 0) / 1e3).toFixed(0)} kN`],
        ['TWR', (t.twr || 0).toFixed(2)],
        ['Isp', `${(t.isp || 0).toFixed(0)} s`],
        ['Δv remaining', fmtSpeed(t.dv || 0)],
        ['downrange', fmtDist(t.downrange || 0)],
        ['warp', `${s.warp}×`],
        ['body', s.parentName],
      ];
      grid.innerHTML = rows.map(([k, val]) =>
        `<div><span class="k">${k}</span><span class="v">${val}</span></div>`).join('');

      q('[data-met]').textContent = fmtDur(v.met);
      q('[data-ut]').textContent = fmtDur(v.coord);
      q('[data-dt]').textContent = fmtClockDelta(v.clockDelta);

      stagesEl.innerHTML = v.stages.map(st => {
        const frac = st.prop0 > 0 ? st.prop / st.prop0 : 0;
        const cls = !st.attached ? 'gone' : st.ignited ? (st.spent ? 'spent' : 'live') : 'pending';
        return `<div class="fl-stage ${cls}">
          <div class="fl-stage-bar"><i style="width:${(frac * 100).toFixed(1)}%"></i></div>
          <span class="n">${st.spec.name}</span>
          <span class="m">${st.prop0 > 0 ? fmtMassT(st.prop) : fmtMassT(st.spec.dry)}</span>
          ${st.spec.count ? `<span class="e">${st.live}/${st.spec.count}</span>` : ''}
        </div>`;
      }).join('');

      root.querySelectorAll('[data-mode]').forEach(b =>
        b.classList.toggle('on', b.dataset.mode === s.mode));
      root.querySelectorAll('[data-prog]').forEach(b =>
        b.classList.toggle('on', b.dataset.prog === s.program));

      planEl.innerHTML = s.planHTML || '';

      if (v.events.length !== lastLog) {
        lastLog = v.events.length;
        logEl.innerHTML = v.events.slice(-9).reverse().map(e =>
          `<div><span class="t">${fmtDur(e.t)}</span> ${e.msg}</div>`).join('');
      }
    },
  };
}

/** The transfer-plan block, written out in full because the two Δv numbers in an
 *  interplanetary plan are not the same number and confusing them is the classic
 *  way to be 2 km/s wrong. */
export function planHTML(plan, targetName) {
  if (!plan) return `<div class="fl-plan-none">No solution to ${targetName || 'target'} from here.</div>`;
  if (plan.kind === 'hohmann') {
    return `<div class="fl-plan-body">
      <div><span class="k">departure Δv</span><span class="v">${fmtSpeed(plan.dv1)}</span></div>
      <div><span class="k">arrival Δv</span><span class="v">${fmtSpeed(plan.dv2)}</span></div>
      <div><span class="k">total</span><span class="v">${fmtSpeed(plan.dv)}</span></div>
      <div><span class="k">flight time</span><span class="v">${fmtDur(plan.tof)}</span></div>
      <div><span class="k">phase angle</span><span class="v">${(plan.phase * 180 / Math.PI).toFixed(1)}°</span></div>
      <div><span class="k">window in</span><span class="v">${fmtDur(plan.waitS)}</span></div>
      <div><span class="k">window repeats</span><span class="v">${fmtDur(plan.synodic)}</span></div>
    </div>`;
  }
  return `<div class="fl-plan-body">
    <div><span class="k">escape burn</span><span class="v">${fmtSpeed(plan.dvBurn)}</span></div>
    <div><span class="k">v∞ needed</span><span class="v">${fmtSpeed(plan.vInf)}</span></div>
    <div><span class="k">heliocentric Δv</span><span class="v">${fmtSpeed(plan.dvHelio)}</span></div>
    <div><span class="k">flight time</span><span class="v">${fmtDur(plan.tof)}</span></div>
    <div class="fl-plan-note">The burn is smaller than the heliocentric Δv it buys —
      that difference is the Oberth effect, and it is why the departure is made at
      periapsis.</div>
  </div>`;
}

/** The interstellar readout — a different instrument, because in cruise nothing
 *  on the orbital panel means anything. */
export function cruiseHTML(r) {
  if (!r) return '';
  const pct = (r.travelledLy / Math.max(r.totalLy, 1e-9)) * 100;
  return `<div class="fl-cruise">
    <div class="fl-cruise-bar"><i style="width:${pct.toFixed(2)}%"></i>
      <b style="left:${((r.plan.burnLy ?? 0) / r.totalLy * 100).toFixed(2)}%"></b>
      <b style="left:${(100 - (r.plan.burnLy ?? 0) / r.totalLy * 100).toFixed(2)}%"></b></div>
    <div class="fl-grid">
      <div><span class="k">phase</span><span class="v">${r.leg}</span></div>
      <div><span class="k">β = v/c</span><span class="v">${r.beta.toFixed(6)}</span></div>
      <div><span class="k">γ</span><span class="v">${r.gamma.toFixed(4)}</span></div>
      <div><span class="k">acceleration</span><span class="v">${r.accelG.toFixed(2)} g</span></div>
      <div><span class="k">travelled</span><span class="v">${r.travelledLy.toFixed(4)} ly</span></div>
      <div><span class="k">remaining</span><span class="v">${r.remainingLy.toFixed(4)} ly</span></div>
      <div><span class="k">ship clock</span><span class="v">${fmtYears(r.shipYears)}</span></div>
      <div><span class="k">Earth clock</span><span class="v">${fmtYears(r.coordYears)}</span></div>
      <div><span class="k">time dilation</span><span class="v">${r.dilation.toFixed(4)}×</span></div>
      <div><span class="k">astrophage</span><span class="v">${(r.propFrac * 100).toFixed(2)}%</span></div>
    </div>
    <div class="fl-plan-note">${r.plan.mode === 'flip'
      ? 'Flip-and-burn: accelerating to the midpoint and decelerating after it — the fastest crossing this Δv allows.'
      : `Accelerate–coast–decelerate. The tanks hold rapidity ${r.plan.budget.toFixed(2)}; a flip-and-burn crossing would need ${(2 * Math.acosh(1 + 1)).toFixed(0)}× more mass, so the ship burns to β = ${r.plan.betaMax.toFixed(3)}, coasts ${r.plan.coastLy.toFixed(2)} ly and turns over.`}</div>
  </div>`;
}
