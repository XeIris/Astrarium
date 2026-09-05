import * as THREE from 'three';

// ============================================================================
// TWO-BODY ORBITAL MECHANICS
// ----------------------------------------------------------------------------
// Everything here is about ONE body's gravity, in SI, in a frame centred on it.
// The sim's real force model is the full n-body sum (see vessel.js); this module
// exists for the two jobs that genuinely want the two-body answer:
//
//   1. THE INSTRUMENTS. "Apoapsis 412 km" is a statement about the conic the
//      vessel is on right now, and the conic is what the crew steers by. It is
//      recomputed every frame from the live state, so perturbations show up as
//      the numbers drifting, which is exactly what they do in reality.
//
//   2. ON-RAILS TIME WARP. Above ~1000x the integrator cannot keep up with an
//      orbit — a 90-minute LEO orbit passes in 5 ms of wall clock — so an
//      unpowered vessel outside the atmosphere is taken off the integrator and
//      advanced along its conic analytically. That is exactly what KSP does and
//      for the same reason. The propagation is EXACT for the two-body problem,
//      so it neither drifts nor cares about the step size; what it drops is the
//      perturbations, which is an honest and clearly-bounded trade.
//
// The propagator is the universal-variable (Stumpff) formulation rather than a
// per-conic one. That is not an aesthetic choice: a vessel on an escape
// trajectory passes through e = 1, and a formulation with separate elliptic and
// hyperbolic branches divides by zero exactly there. The universal form has no
// branch — it is one series that covers ellipse, parabola and hyperbola.
// ============================================================================

// ---- Stumpff functions ------------------------------------------------------
// C(z) and S(z) are the even and odd parts of the universal anomaly series. The
// series expansions near z = 0 are not an optimisation: the closed forms are
// 0/0 there, which is precisely the parabolic case.
export function stumpffC(z) {
  if (z > 1e-6)  { const s = Math.sqrt(z);  return (1 - Math.cos(s)) / z; }
  if (z < -1e-6) { const s = Math.sqrt(-z); return (Math.cosh(s) - 1) / -z; }
  return 0.5 - z / 24 + z * z / 720;
}
export function stumpffS(z) {
  if (z > 1e-6)  { const s = Math.sqrt(z);  return (s - Math.sin(s)) / (z * s); }
  if (z < -1e-6) { const s = Math.sqrt(-z); return (Math.sinh(s) - s) / (-z * s); }
  return 1 / 6 - z / 120 + z * z / 5040;
}

const _r0 = new THREE.Vector3(), _v0 = new THREE.Vector3();

/**
 * Advance (r, v) by dt seconds on the two-body conic about `mu`.
 * Writes into rOut/vOut (which may alias r/v). Returns false if it failed to
 * converge, in which case the caller must fall back to integrating.
 */
export function propagate(r, v, mu, dt, rOut, vOut) {
  if (dt === 0) { rOut.copy(r); vOut.copy(v); return true; }
  _r0.copy(r); _v0.copy(v);
  const r0 = _r0.length(), v0 = _v0.length();
  if (r0 < 1e-6 || !Number.isFinite(r0)) return false;
  const sqmu = Math.sqrt(mu);
  const rdotv = _r0.dot(_v0);
  const alpha = 2 / r0 - v0 * v0 / mu;               // = 1/a; negative ⇒ hyperbolic

  // Initial guess for the universal anomaly. The elliptic guess is exact for a
  // circle; the hyperbolic one is Vallado's, and matters because a bad guess on
  // a near-parabolic orbit sends Newton off to infinity.
  let x;
  if (alpha > 1e-12) {
    x = sqmu * dt * alpha;
    // Guard the near-2π case, where the elliptic guess overshoots a whole rev.
    if (Math.abs(alpha * sqmu * dt) > 2 * Math.PI) x = Math.sign(dt) * Math.sqrt(1 / alpha) * 2 * Math.PI;
  } else if (alpha < -1e-12) {
    const a = 1 / alpha;
    const s = Math.sign(dt) * Math.sqrt(-a);
    const num = -2 * mu * alpha * dt;
    const den = rdotv + s * Math.sqrt(-mu * a) * (1 - r0 * alpha);
    x = s * Math.log(Math.max(num / den, 1e-12));
  } else {
    x = sqmu * dt / r0;                              // parabolic
  }

  let z = 0, C = 0.5, S = 1 / 6, rMag = r0, ok = false;
  for (let i = 0; i < 60; i++) {
    z = alpha * x * x;
    C = stumpffC(z); S = stumpffS(z);
    rMag = x * x * C + (rdotv / sqmu) * x * (1 - z * S) + r0 * (1 - z * C);
    const F = (rdotv / sqmu) * x * x * C + (1 - alpha * r0) * x * x * x * S + r0 * x - sqmu * dt;
    if (Math.abs(F) < 1e-7 * Math.max(1, Math.abs(sqmu * dt))) { ok = true; break; }
    if (rMag < 1e-9) return false;
    x -= F / rMag;                                   // dF/dx = rMag exactly
    if (!Number.isFinite(x)) return false;
  }
  if (!ok) return false;

  // Lagrange f and g. These reconstruct the new state as a linear combination of
  // the OLD position and velocity, which is why the propagation is exact rather
  // than integrated: the orbit plane is preserved to machine precision.
  const f = 1 - (x * x / r0) * C;
  const g = dt - (x * x * x / sqmu) * S;
  const gd = 1 - (x * x / rMag) * C;
  const fd = (sqmu / (r0 * rMag)) * x * (z * S - 1);

  rOut.set(f * _r0.x + g * _v0.x, f * _r0.y + g * _v0.y, f * _r0.z + g * _v0.z);
  vOut.set(fd * _r0.x + gd * _v0.x, fd * _r0.y + gd * _v0.y, fd * _r0.z + gd * _v0.z);
  return Number.isFinite(rOut.x) && Number.isFinite(vOut.x);
}

// ---- classical elements -----------------------------------------------------
const _h = new THREE.Vector3(), _n = new THREE.Vector3(), _e = new THREE.Vector3(),
      _t = new THREE.Vector3();
// The reference pole. It is −Y, not +Y, and that is measured rather than
// chosen: sim/presets.js places every standard orbit at (a·cos, 0, a·sin) with
// velocity (−v·sin, 0, v·cos), whose angular momentum r × v points along −Y. So
// the orrery's own "orbital north" is −Y, and defining it that way here is what
// makes a normal prograde orbit read as inclination 0° in the HUD instead of
// 180°. Everything else — the normal/anti-normal attitude targets, the plane
// change planner — inherits the same sign for free.
const K = new THREE.Vector3(0, -1, 0);

/**
 * Classical elements from state. Angles in radians, lengths in metres.
 * The reference plane is the sim's XZ plane and the pole is +Y, matching the
 * orrery — so an inclination reported here is measured against the same plane
 * the presets lay their orbits in.
 */
export function elements(r, v, mu) {
  const R = r.length(), V = v.length();
  _h.crossVectors(r, v);
  const h = _h.length();
  const energy = V * V / 2 - mu / R;
  // a from the vis-viva energy. Infinite exactly at escape, which is correct and
  // is why the periapsis/apoapsis readouts have to handle a non-finite `a`.
  const a = Math.abs(energy) < 1e-12 ? Infinity : -mu / (2 * energy);
  _e.copy(v).cross(_h).multiplyScalar(1 / mu).sub(_t.copy(r).multiplyScalar(1 / R));
  const e = _e.length();
  const inc = Math.acos(THREE.MathUtils.clamp(_h.dot(K) / Math.max(h, 1e-12), -1, 1));
  _n.crossVectors(K, _h);
  const nMag = _n.length();
  let raan = nMag > 1e-9 ? Math.atan2(_n.z, _n.x) : 0;
  let argp = 0;
  if (nMag > 1e-9 && e > 1e-9) {
    argp = Math.acos(THREE.MathUtils.clamp(_n.dot(_e) / (nMag * e), -1, 1));
    if (_e.dot(K) < 0) argp = 2 * Math.PI - argp;
  }
  let nu = 0;
  if (e > 1e-9) {
    nu = Math.acos(THREE.MathUtils.clamp(_e.dot(r) / (e * R), -1, 1));
    if (r.dot(v) < 0) nu = 2 * Math.PI - nu;
  } else {
    nu = Math.atan2(r.dot(_t.crossVectors(_h, _e.set(1, 0, 0))), r.x);
  }
  const rp = e < 1 ? a * (1 - e) : (h * h / mu) / (1 + e);
  const ra = e < 1 ? a * (1 + e) : Infinity;
  const period = e < 1 && Number.isFinite(a) ? 2 * Math.PI * Math.sqrt(a * a * a / mu) : Infinity;
  return { a, e, inc, raan, argp, nu, rp, ra, h, energy, period, r: R, v: V };
}

// Time from now to the next periapsis/apoapsis passage, seconds. Only defined
// on a closed orbit; on a hyperbola apoapsis never arrives.
export function timeToAnomaly(el, mu, targetNu) {
  if (!(el.e < 1) || !Number.isFinite(el.period)) return Infinity;
  const E = (nu) => 2 * Math.atan2(Math.sqrt(1 - el.e) * Math.sin(nu / 2),
                                   Math.sqrt(1 + el.e) * Math.cos(nu / 2));
  const M = (nu) => { const ecc = E(nu); return ecc - el.e * Math.sin(ecc); };
  let dM = M(targetNu) - M(el.nu);
  while (dM < 0) dM += 2 * Math.PI;
  return dM / (2 * Math.PI) * el.period;
}
export const timeToApoapsis  = (el, mu) => timeToAnomaly(el, mu, Math.PI);
export const timeToPeriapsis = (el, mu) => timeToAnomaly(el, mu, 0);

// ---- transfers --------------------------------------------------------------

/**
 * Hohmann transfer between two circular orbits of radii r1, r2 about `mu`.
 * The minimum-energy two-impulse transfer, and the number every mission plan
 * starts from.
 */
export function hohmann(mu, r1, r2) {
  const aT = (r1 + r2) / 2;
  const v1 = Math.sqrt(mu / r1), v2 = Math.sqrt(mu / r2);
  const dv1 = v1 * (Math.sqrt(2 * r2 / (r1 + r2)) - 1);
  const dv2 = v2 * (1 - Math.sqrt(2 * r1 / (r1 + r2)));
  const tof = Math.PI * Math.sqrt(aT * aT * aT / mu);
  // Phase angle the TARGET must lead the vessel by at departure: the target
  // travels ω₂·tof while the vessel sweeps exactly π.
  const T2 = 2 * Math.PI * Math.sqrt(r2 * r2 * r2 / mu);
  const phase = Math.PI - 2 * Math.PI * tof / T2;
  const T1 = 2 * Math.PI * Math.sqrt(r1 * r1 * r1 / mu);
  // How long until the same geometry comes round again — i.e. the launch window
  // period. 780 days for Earth/Mars, which is why Mars missions come in pairs
  // of years and not whenever anyone feels like it.
  const synodic = Math.abs(1 / (1 / T1 - 1 / T2));
  return { dv1, dv2, dv: Math.abs(dv1) + Math.abs(dv2), tof, aT, phase, synodic };
}

/** Δv to circularize at the current radius — the standard "raise the periapsis
 *  to match" burn, evaluated where the vessel is right now. */
export function circularizeDv(el, mu, atRadius) {
  const R = atRadius ?? el.ra;
  if (!Number.isFinite(R)) return 0;
  const vCirc = Math.sqrt(mu / R);
  const vHere = Math.sqrt(Math.max(mu * (2 / R - 1 / el.a), 0));
  return vCirc - vHere;
}

/** Current phase angle from `r` to `rTarget`, signed about +Y, in radians. */
export function phaseAngle(r, rTarget) {
  const a = Math.atan2(r.z, r.x), b = Math.atan2(rTarget.z, rTarget.x);
  let d = b - a;
  while (d > Math.PI) d -= 2 * Math.PI;
  while (d < -Math.PI) d += 2 * Math.PI;
  return d;
}

/**
 * Sphere of influence (m): the radius at which `body`'s pull dominates its
 * primary's. r_SOI = a·(m/M)^(2/5) — the Laplace radius, which is what the
 * patched-conic approximation patches at.
 */
export function sphereOfInfluence(aM, massBody, massPrimary) {
  if (!(massPrimary > 0) || !(aM > 0)) return Infinity;
  return aM * Math.pow(massBody / massPrimary, 0.4);
}
