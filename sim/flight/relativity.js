import * as THREE from 'three';
import { C_MS, AU_M, G0 } from './rocketry.js';

// ============================================================================
// RELATIVISTIC CRUISE
// ----------------------------------------------------------------------------
// Interstellar flight is a different physical regime from everything else in
// sim/flight/, and it gets its own integrator rather than a relativistic patch
// on the Newtonian one. Between stars there is no gravity worth the name, the
// motion is one-dimensional along the target line, and the exact solution is
// available in closed form — so using it is both more accurate and simpler than
// stepping a modified momentum equation.
//
// With constant PROPER acceleration a (what the crew feels) and proper time τ:
//
//     v(τ) = c·tanh(aτ/c)          γ(τ) = cosh(aτ/c)
//     t(τ) = (c/a)·sinh(aτ/c)      d(τ) = (c²/a)·(cosh(aτ/c) − 1)
//
// The natural variable is the RAPIDITY φ = aτ/c, which adds linearly the way
// velocity does not: a flip-and-burn crossing needs total rapidity 2φ, and the
// rocket equation in these units is simply Δφ = (v_e/c)·ln(m₀/m₁). That is why
// this module thinks in rapidity throughout and only converts to a velocity at
// the very end.
//
// THE MISSION PROFILE. A flip-and-burn (accelerate to the midpoint, decelerate
// after it) is the fastest crossing but needs the most Δv. When the ship does
// not have it, the answer is not "impossible" — it is to burn to whatever
// rapidity the tanks allow, COAST, and turn over. `solveProfile` finds the coast
// fraction, and that is what makes the Hail Mary's real mission close: 2 000 t
// of astrophage on a 100 t ship gives ln(21) = 3.05 of rapidity through a photon
// drive, which is not enough for flip-and-burn over 11.9 ly but is comfortably
// enough for accelerate–coast–decelerate — arriving in 13.9 years of Earth time,
// which is what the book says the trip takes.
// ============================================================================

export const LY_M = 9.4607304725808e15;     // light year, metres (exact by definition of c)
export const LY_AU = LY_M / AU_M;           // 63241.077 AU — the same number as physics.js's C
export const YEAR_S = 365.25 * 86400;

/** Rapidity → velocity fraction, and back. */
export const betaOf = (phi) => Math.tanh(phi);
export const gammaOf = (phi) => Math.cosh(phi);
export const rapidityOf = (beta) => Math.atanh(Math.min(Math.max(beta, -0.999999999), 0.999999999));

/**
 * Total rapidity a vehicle can deliver, from the relativistic rocket equation
 *   Δφ = (v_e/c)·ln(m₀/m₁)
 * A photon drive has v_e = c exactly, so its rapidity is just ln of the mass
 * ratio — which is the cleanest statement of why interstellar flight is hard:
 * every unit of rapidity costs a factor of e in mass.
 */
export function rapidityBudget(dryMass, propMass, exhaustMS) {
  if (!(propMass > 0) || !(dryMass > 0)) return 0;
  return (exhaustMS / C_MS) * Math.log((dryMass + propMass) / dryMass);
}

/**
 * Solve an accelerate–coast–decelerate crossing of `distLy` at proper
 * acceleration `a` with a rapidity budget `budget`.
 *
 * Returns the leg rapidity actually used, the coast, and both clocks. If the
 * budget is more than a flip-and-burn needs, the answer IS flip-and-burn and
 * the surplus is reported rather than spent.
 */
export function solveProfile(distLy, aMS2, budget) {
  const d = distLy * LY_M;
  const ca = C_MS / aMS2;                          // seconds per unit rapidity
  const c2a = C_MS * C_MS / aMS2;                  // metres per unit (cosh−1)

  // Flip-and-burn: each leg covers half the distance.
  const halfPhi = Math.acosh(1 + (d / 2) / c2a);
  if (budget >= 2 * halfPhi) {
    const tau = 2 * ca * halfPhi;
    const t = 2 * ca * Math.sinh(halfPhi);
    return {
      mode: 'flip', phi: halfPhi, coastLy: 0,
      tauS: tau, coordS: t, gammaMax: Math.cosh(halfPhi), betaMax: Math.tanh(halfPhi),
      budget, used: 2 * halfPhi, spare: budget - 2 * halfPhi, feasible: true,
    };
  }
  // Otherwise burn half the budget each way and coast the difference.
  const phi = budget / 2;
  const legLy = c2a * (Math.cosh(phi) - 1);
  const coast = d - 2 * legLy;
  if (coast < 0) {
    // Not even enough to stop: report it honestly rather than inventing fuel.
    return { mode: 'short', phi, coastLy: 0, feasible: false, budget, used: budget,
             tauS: Infinity, coordS: Infinity, gammaMax: Math.cosh(phi), betaMax: Math.tanh(phi) };
  }
  const beta = Math.tanh(phi), gamma = Math.cosh(phi);
  const coastCoord = coast / (beta * C_MS);
  return {
    mode: 'coast', phi, coastLy: coast / LY_M,
    tauS: 2 * ca * phi + coastCoord / gamma,
    coordS: 2 * ca * Math.sinh(phi) + coastCoord,
    gammaMax: gamma, betaMax: beta,
    budget, used: budget, spare: 0, feasible: true,
    burnLy: legLy / LY_M,
  };
}

// ============================================================================
// THE CRUISE STATE — one live interstellar flight
// ============================================================================
export class Cruise {
  /**
   * @param origin  THREE.Vector3, AU, in the orrery's frame
   * @param target  THREE.Vector3, AU
   */
  constructor({ origin, target, accel, budget, dryMass, propMass, exhaustMS, name }) {
    this.name = name || 'Cruise';
    this.origin = origin.clone();
    this.dir = target.clone().sub(origin);
    this.distAU = this.dir.length();
    this.dir.normalize();
    this.distLy = this.distAU / LY_AU;
    this.a = accel;
    this.dryMass = dryMass; this.propMass = propMass; this.prop = propMass;
    this.exhaust = exhaustMS;
    this.budget = budget ?? rapidityBudget(dryMass, propMass, exhaustMS);
    this.plan = solveProfile(this.distLy, this.a, this.budget);
    // live state
    this.phi = 0;               // current rapidity (signed along dir)
    this.s = 0;                 // distance travelled along dir, metres
    this.tau = 0;               // ship proper time, s
    this.t = 0;                 // coordinate time, s
    this.leg = 'accel';         // accel | coast | decel | arrived
    this.legTau = 0;
    this.throttle = 1;
    this.log = [];
  }

  get beta() { return Math.tanh(this.phi); }
  get gamma() { return Math.cosh(this.phi); }
  /** Metres remaining to the target. */
  get remaining() { return Math.max(this.distLy * LY_M - this.s, 0); }
  /** Position in AU, in the orrery's frame. */
  position(out = new THREE.Vector3()) {
    return out.copy(this.dir).multiplyScalar(this.s / AU_M).add(this.origin);
  }
  /** Velocity in AU/yr, for anything that wants it in the orrery's units. */
  velocity(out = new THREE.Vector3()) {
    return out.copy(this.dir).multiplyScalar(this.beta * LY_AU);
  }

  note(m) { this.log.push({ tau: this.tau, m }); if (this.log.length > 60) this.log.shift(); }

  /**
   * Advance by `dtau` seconds of SHIP time — the natural variable, because the
   * drive's throttle, the fuel burn and the crew all live on the ship's clock.
   * Coordinate time is derived from it, never integrated separately.
   */
  step(dtau) {
    if (this.leg === 'arrived' || dtau <= 0) return;
    const plan = this.plan;
    const legPhi = plan.phi;
    // decide the leg
    if (this.leg === 'accel' && this.phi >= legPhi - 1e-9) {
      this.leg = plan.mode === 'flip' ? 'decel' : 'coast';
      this.note(plan.mode === 'flip' ? 'Turnover — beginning deceleration' : `Cutoff at β = ${this.beta.toFixed(5)}, γ = ${this.gamma.toFixed(3)} — coasting`);
      if (this.leg === 'decel') this.note('Flip and burn');
    }
    if (this.leg === 'coast') {
      // Turn over when the remaining distance equals what the deceleration leg
      // will cover — computed, not scheduled, so a mid-course change of mind
      // still stops at the right place.
      const need = (C_MS * C_MS / this.a) * (Math.cosh(this.phi) - 1);
      if (this.remaining <= need) { this.leg = 'decel'; this.note('Turnover — flip and burn'); }
    }

    const burning = this.leg === 'accel' || this.leg === 'decel';
    const sign = this.leg === 'decel' ? -1 : 1;
    const a = burning ? this.a * this.throttle : 0;

    // Exact hyperbolic advance over dtau at constant proper acceleration.
    const dphi = sign * a * dtau / C_MS;
    const phi0 = this.phi, phi1 = burning ? this.phi + dphi : this.phi;
    // Coordinate time and distance are integrals of cosh and sinh; with constant
    // a they are exact, and with a = 0 they reduce to the coasting case.
    if (burning && Math.abs(dphi) > 1e-15) {
      const k = C_MS / (sign * a);
      this.t += k * (Math.sinh(phi1) - Math.sinh(phi0));
      this.s += (C_MS * k) * (Math.cosh(phi1) - Math.cosh(phi0));
      // Fuel: dm/m = −dφ·c/v_e , the relativistic rocket equation differentiated.
      const frac = Math.exp(-Math.abs(dphi) * C_MS / this.exhaust);
      const m = this.dryMass + this.prop;
      this.prop = Math.max(0, m * frac - this.dryMass);
      if (this.prop <= 0 && this.leg === 'accel') { this.note('Astrophage exhausted — coasting'); this.leg = 'coast'; }
      this.phi = phi1;
    } else {
      this.t += dtau * Math.cosh(this.phi);
      this.s += dtau * C_MS * Math.sinh(this.phi);
    }
    this.tau += dtau;

    if (this.leg === 'decel' && (this.phi <= 0 || this.remaining <= 0)) {
      this.phi = Math.max(this.phi, 0);
      this.leg = 'arrived';
      this.note(`Arrival — ${fmtYears(this.tau / YEAR_S)} ship, ${fmtYears(this.t / YEAR_S)} coordinate`);
    }
  }

  /** Everything the HUD needs, in one object. */
  readout() {
    return {
      beta: this.beta, gamma: this.gamma, phi: this.phi,
      shipYears: this.tau / YEAR_S, coordYears: this.t / YEAR_S,
      dilation: this.t / Math.max(this.tau, 1e-9),
      travelledLy: this.s / LY_M, remainingLy: this.remaining / LY_M,
      totalLy: this.distLy, leg: this.leg,
      propT: this.prop / 1000, propFrac: this.prop / Math.max(this.propMass, 1),
      accelG: (this.leg === 'coast' || this.leg === 'arrived') ? 0 : this.a / G0,
      plan: this.plan,
    };
  }
}

// ============================================================================
// WHAT RELATIVISTIC FLIGHT LOOKS LIKE
// ----------------------------------------------------------------------------
// Three effects, all of which act on the SKY rather than on the ship, and all of
// which fall out of one boost. `skyBoost` hands sim/sky.js the velocity it needs
// and the shader does the rest; see the aberration block in SKY_GLSL.
//
//   ABERRATION. The apparent direction of a source satisfies
//       cos θ_rest = (cos θ_ship − β)/(1 − β·cos θ_ship)
//   so the whole sky piles into a forward cone. At γ = 10 everything visible is
//   inside about 11° ahead.
//
//   DOPPLER. D = 1/(γ(1 − β·cos θ_ship)). A blackbody at T is seen at T·D, which
//   is exactly representable here because sim/sky.js colours its stars from a
//   Planck locus — so the shift is applied to the TEMPERATURE at source rather
//   than as a hue filter afterwards.
//
//   HEADLIGHT. Specific intensity transforms as I' = D⁴·I. Ahead the sky
//   brightens enormously; behind it goes black. Same physics as a blazar, one
//   multiply.
//
// Crucially the aberration is applied to the ray direction BEFORE the screen
// derivatives are taken, so the change in solid angle per pixel is picked up by
// the existing point-source machinery — the same path that already handles
// lensing magnification. Nothing here introduces a fixed angular resolution,
// which the repo forbids for good reason.
// ============================================================================

/** The β vector (velocity/c) to hand the sky shader, in world coordinates. */
export function skyBoost(dirUnit, beta, out = new THREE.Vector3()) {
  return out.copy(dirUnit).multiplyScalar(THREE.MathUtils.clamp(beta, -0.999999, 0.999999));
}

/** Doppler factor for a source seen at angle θ from the direction of travel. */
export function dopplerFactor(beta, cosTheta) {
  const g = 1 / Math.sqrt(Math.max(1 - beta * beta, 1e-18));
  return 1 / (g * (1 - beta * cosTheta));
}

/** Half-angle (radians) containing the forward half of the aberrated sky —
 *  the "tunnel" a relativistic crew actually sees. */
export function aberrationCone(beta) {
  // The rest-frame hemisphere ahead (cos θ = 0) maps to cos θ' = β.
  return Math.acos(THREE.MathUtils.clamp(beta, -1, 1));
}

export function fmtYears(y) {
  if (!Number.isFinite(y)) return '—';
  if (y < 1 / 365.25) return `${(y * 365.25 * 24).toFixed(1)} h`;
  if (y < 1) return `${(y * 365.25).toFixed(1)} d`;
  if (y < 1000) return `${y.toFixed(2)} yr`;
  if (y < 1e6) return `${(y / 1000).toFixed(2)} kyr`;
  return `${(y / 1e6).toFixed(2)} Myr`;
}
