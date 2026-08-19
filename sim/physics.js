import * as THREE from 'three';

// ============================================================================
// REAL PHYSICS ENGINE
// ----------------------------------------------------------------------------
// Units: astronomical. Length = AU, mass = solar mass (M☉), time = year (yr).
// In this system the gravitational constant is exactly G = 4π², the speed of
// light is c ≈ 63241 AU/yr. With these units a body at 1 AU around a 1 M☉ star
// orbits in exactly 1 yr — i.e. the integrator reproduces real Kepler/Newton
// dynamics with no fudge factors.
//
// Integrator: full pairwise N-body with velocity-Verlet (symplectic, conserves
// energy far better than the semi-implicit Euler the old sim used).
//   - Compact objects (black holes, neutron stars) attract via the
//     Paczyński–Wiita pseudo-potential, which reproduces the correct ISCO at
//     3·r_s and the relativistic plunge — "real enough" GR without integrating
//     null/timelike geodesics every frame.
//   - Tight compact-compact binaries lose energy to gravitational waves via the
//     leading-order (quadrupole / 2.5-PN) radiation-reaction term, so binaries
//     genuinely inspiral and merge with the right chirp shape.
// ============================================================================

export const G = 4 * Math.PI * Math.PI;        // 39.478 AU³ M☉⁻¹ yr⁻²
export const C = 63241.077;                    // speed of light, AU/yr
export const AU_PER_RSUN = 0.00465047;         // solar radius in AU
export const AU_PER_KM = 6.68459e-9;

// Schwarzschild radius (AU) for a given mass in M☉.
export function schwarzschild(massSun) {
  return 2 * G * massSun / (C * C);
}

// Neutron-star radius (AU) from a simple mass–radius relation: NS shrink as
// they get heavier (degenerate matter), ~12 km near 1.4 M☉, hard floor at the
// theoretical ~10 km, capped near the Tolman–Oppenheimer–Volkoff limit ~2.2 M☉.
export function neutronRadius(massSun) {
  const m = Math.min(Math.max(massSun, 1.1), 2.2);
  const km = 13.0 - 2.6 * (m - 1.1);   // 13 km at 1.1 M☉ → ~10.1 km at 2.2 M☉
  return Math.max(km, 9.5) * AU_PER_KM;
}

// Physical stellar radius (AU) from mass via main-sequence R ∝ M^0.8.
export function stellarRadius(massSun) {
  return Math.pow(Math.max(massSun, 0.05), 0.8) * AU_PER_RSUN;
}

// ----------------------------------------------------------------------------
// Roche limit (AU): the separation inside which a body held together only by
// its own gravity is pulled apart by the tidal field of `massSun`.
//   d = 2.44 R* (rho* / rho_body)^(1/3)
// For a rocky world around a main-sequence star this lands a few stellar radii
// out — the world is shredded well before it ever reaches the photosphere, so
// this, not the star's surface, is the honest destruction distance for any
// scenario built on close passes.
// ----------------------------------------------------------------------------
const RHO_SUN = 1.41;                          // g/cm^3
export function rocheLimit(massSun, bodyDensity = 5.5) {
  const rAU = stellarRadius(massSun);
  const rSun = rAU / AU_PER_RSUN;
  const rhoStar = RHO_SUN * massSun / (rSun * rSun * rSun);
  return 2.44 * rAU * Math.cbrt(rhoStar / bodyDensity);
}

const _r = new THREE.Vector3();
const _tmp = new THREE.Vector3();

// ----------------------------------------------------------------------------
// Acceleration field. Fills every live body's `acc`.
// ----------------------------------------------------------------------------
export function computeAccel(bodies) {
  for (const b of bodies) b.acc.set(0, 0, 0);

  for (let i = 0; i < bodies.length; i++) {
    const a = bodies[i];
    if (!a.alive) continue;
    for (let j = i + 1; j < bodies.length; j++) {
      const b = bodies[j];
      if (!b.alive) continue;

      _r.subVectors(b.pos, a.pos);
      let dist = _r.length();
      if (dist < 1e-9) continue;
      const inv = 1 / dist;
      _r.multiplyScalar(inv);                // unit vector a→b

      // Pull strength of each body on the other. Compact bodies use the
      // Paczyński–Wiita denominator (r − r_s)² so the ISCO/plunge are correct.
      const fA = pullMag(b, dist);           // accel of A toward B
      const fB = pullMag(a, dist);           // accel of B toward A

      a.acc.addScaledVector(_r, fA);
      b.acc.addScaledVector(_r, -fB);
    }
  }
}

// |acceleration| imparted by `source` at separation `dist`.
// Only true black holes use the Paczyński–Wiita pseudo-potential (which makes
// the ISCO/plunge appear); stars & neutron stars are extended bodies → Newton.
function pullMag(source, dist) {
  const GM = G * source.mass;
  if (source.type === 'bh') {
    const denom = Math.max(dist - source.rs, source.rs * 0.05);
    return GM / (denom * denom);
  }
  // Plummer softening for extended bodies so close passes don't blow up.
  const soft = source.softening || (source.radius * 0.5 + 1e-4);
  const d2 = dist * dist + soft * soft;
  return GM / d2;
}

// ----------------------------------------------------------------------------
// Gravitational-wave radiation reaction for a bound compact binary.
// Applies the 2.5-PN leading-order energy loss as a drag, scaled by `boost`
// so the inspiral is watchable (real systems take Myr; presets exaggerate the
// rate but preserve the correct r(t) ∝ (t_c − t)^¼ chirp morphology).
// ----------------------------------------------------------------------------
const _rel = new THREE.Vector3();
const _vrel = new THREE.Vector3();
// G and C are module constants, so their powers are too — hoisted out of the
// O(n²) pair loop rather than recomputed per pair per sub-step.
const G4 = Math.pow(G, 4);
const C5 = Math.pow(C, 5);
export function applyGWReaction(bodies, dt, boost) {
  const compact = bodies.filter(b => b.alive && b.emitsGW);
  for (let i = 0; i < compact.length; i++) {
    for (let j = i + 1; j < compact.length; j++) {
      const a = compact[i], b = compact[j];
      _rel.subVectors(b.pos, a.pos);
      const r = _rel.length();
      // Scale the "tight pair" window to the bodies' physical/rendered size, not
      // their Schwarzschild radius — a neutron star's true horizon is microscopic
      // and would exclude its whole inspiral.
      const cSum = (a.contactAU || a.radius || a.rs) + (b.contactAU || b.radius || b.rs);
      if (r > 400 * cSum || r < cSum * 0.5) continue;

      _vrel.subVectors(b.vel, a.vel);
      const m1 = a.mass, m2 = b.mass, M = m1 + m2, mu = m1 * m2 / M;

      // dE/dt for a circular binary: −32/5 · G⁴ m1²m2²(m1+m2) / (c⁵ r⁵)
      const dEdt = (32 / 5) * G4 * m1 * m1 * m2 * m2 * M
                 / (C5 * Math.pow(r, 5)) * boost;

      // Convert power loss into a velocity-space drag opposing relative motion.
      const vrelMag = Math.max(_vrel.length(), 1e-6);
      let dragAcc = dEdt / (mu * vrelMag);
      // Cap the fractional relative-speed bled off per sub-step (step-size
      // independent) so the runaway final plunge (the chirp diverges as r→0) is
      // spread over many frames and stays clearly visible.
      const maxKick = 0.0025 * vrelMag;
      if (dragAcc * dt > maxKick) dragAcc = maxKick / dt;
      _vrel.multiplyScalar(1 / vrelMag);             // unit
      // share the kick by reduced mass
      a.vel.addScaledVector(_vrel,  dragAcc * (mu / m1) * dt);
      b.vel.addScaledVector(_vrel, -dragAcc * (mu / m2) * dt);
    }
  }
}

// ----------------------------------------------------------------------------
// One velocity-Verlet step (symplectic).
// ----------------------------------------------------------------------------
export function integrate(bodies, dt) {
  const live = bodies.filter(b => b.alive);
  if (!live.length) return;

  computeAccel(live);
  for (const b of live) {
    // x += v·dt + ½a·dt²
    b.pos.addScaledVector(b.vel, dt);
    b.pos.addScaledVector(b.acc, 0.5 * dt * dt);
    _tmp.copy(b.acc);
    b._aPrev = b._aPrev || new THREE.Vector3();
    b._aPrev.copy(_tmp);
  }
  computeAccel(live);
  for (const b of live) {
    // v += ½(a_old + a_new)·dt
    b.vel.addScaledVector(_tmp.copy(b._aPrev).add(b.acc), 0.5 * dt);
  }
}

// ----------------------------------------------------------------------------
// Collision / accretion resolution. Returns an array of merger events.
// ----------------------------------------------------------------------------
export function resolveCollisions(bodies) {
  const events = [];
  for (let i = 0; i < bodies.length; i++) {
    const a = bodies[i];
    if (!a.alive) continue;
    for (let j = i + 1; j < bodies.length; j++) {
      const b = bodies[j];
      if (!b.alive) continue;

      _rel.subVectors(b.pos, a.pos);
      const d = _rel.length();

      // contact distance: event horizon for BHs, rendered surface otherwise.
      const ca = a.type === 'bh' ? a.rs : (a.contactAU || a.radius);
      const cb = b.type === 'bh' ? b.rs : (b.contactAU || b.radius);
      if (d > ca + cb) continue;

      // merge lighter into heavier; conserve momentum
      const big = a.mass >= b.mass ? a : b;
      const small = big === a ? b : a;
      const M = big.mass + small.mass;
      big.vel.multiplyScalar(big.mass).addScaledVector(small.vel, small.mass).multiplyScalar(1 / M);
      big.pos.multiplyScalar(big.mass).addScaledVector(small.pos, small.mass).multiplyScalar(1 / M);
      big.mass = M;
      small.alive = false;
      events.push({ survivor: big, absorbed: small, separation: d });
    }
  }
  return events;
}

// Orbital speed for a circular orbit of radius r (AU) about mass M (M☉).
export function circularSpeed(M, r) { return Math.sqrt(G * M / r); }

// Vis-viva speed for an orbit with given semi-major axis a at radius r.
export function visViva(M, r, a) { return Math.sqrt(G * M * (2 / r - 1 / a)); }
