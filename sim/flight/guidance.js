import * as THREE from 'three';
import { G0, AU_M, GM_SUN, pressure, density, engineOutput, burnTimeFor } from './rocketry.js';
import { elements, propagate, hohmann, timeToApoapsis, timeToPeriapsis, sphereOfInfluence, phaseAngle } from './orbit.js';
import { PHASE } from './vessel.js';

// ============================================================================
// GUIDANCE — the autopilot, and the attitude references it steers to.
//
// Every program here is a CLOSED LOOP on the vehicle's own state. None of them
// replay a stored trajectory, and that is the difference that matters: a
// scripted ascent looks identical whatever you do to the vehicle, while a
// closed loop flies a heavier rocket differently and gives up when it genuinely
// cannot make orbit.
//
// The four laws, and where each comes from:
//
//   ASCENT — vertical rise, pitch kick, gravity turn at zero angle of attack
//   while the air is thick, then a closed-loop phase that holds TIME TO
//   APOAPSIS at a set value until the apoapsis reaches its target. The
//   time-to-apoapsis hold is the practical cousin of Powered Explicit Guidance:
//   both answer "am I climbing too fast or too slow for the energy I have
//   left", and this one does it without re-solving a transcendental every cycle.
//
//   NODE — a Δv vector at a time. Ignition at T − t_burn/2 so a finite burn
//   straddles the impulsive solution it was planned as; cutoff on the REMAINING
//   Δv projected onto the node direction going negative, never on elapsed time,
//   so a wrong burn-time estimate cannot overburn.
//
//   POWERED DESCENT — the Apollo quadratic law. For a linear acceleration
//   profile that arrives at (r_T, v_T) in t_go:
//        a_cmd = 6·Δr/t_go² − 2·Δv/t_go   with  Δr = r_T − r − v·t_go
//   which is the minimum-∫a² solution of the two-point boundary problem, and is
//   what P63 and P64 actually compute. Gravity is added on top, because the
//   engine has to hold the vehicle up as well as steer it.
//
//   HOVERSLAM — one line, and the whole manoeuvre:
//        h_burn = v² / (2·(F/m − g))
//   evaluated every step. Ignition is when the altitude reaches it. The vehicle
//   cannot hover — minimum throttle already gives TWR > 1 — so arriving at zero
//   velocity and zero altitude simultaneously is the only solution there is.
// ============================================================================

const _a = new THREE.Vector3(), _b = new THREE.Vector3(), _c = new THREE.Vector3();
const _d = new THREE.Vector3(), _e = new THREE.Vector3(), _up = new THREE.Vector3();
const _f = new THREE.Vector3(), _g = new THREE.Vector3();

export const MODE = {
  OFF: 'off', PROGRADE: 'prograde', RETROGRADE: 'retrograde',
  NORMAL: 'normal', ANTINORMAL: 'antinormal',
  RADIAL: 'radial', ANTIRADIAL: 'antiradial',
  SURFACE: 'surface', TARGET: 'target', ANTITARGET: 'antitarget',
  NODE: 'node', HOLD: 'hold',
};

/**
 * The attitude reference for a mode, as a world-space direction for the +Y
 * (thrust) axis. Prograde is relative to the SURFACE while inside the
 * atmosphere and to the orbit outside it, because those are the two things a
 * pilot actually wants to line up with and they differ by 465 m/s at the pad.
 */
export function attitudeFor(mode, v, target) {
  const r = v.r;
  _up.copy(r).normalize();
  const inAir = v.env.atm && v.altitude() < v.env.atm.top * 0.6;
  const vel = inAir ? v.airspeed(r, v.v, _b) : _b.copy(v.v);
  const speed = vel.length();
  switch (mode) {
    case MODE.PROGRADE:   return speed > 0.5 ? _a.copy(vel).normalize() : _a.copy(_up);
    case MODE.RETROGRADE: return speed > 0.5 ? _a.copy(vel).normalize().negate() : _a.copy(_up);
    case MODE.NORMAL:     return _a.crossVectors(r, v.v).normalize();
    case MODE.ANTINORMAL: return _a.crossVectors(r, v.v).normalize().negate();
    case MODE.RADIAL:     return _a.copy(_up);
    case MODE.ANTIRADIAL: return _a.copy(_up).negate();
    case MODE.SURFACE:    return _a.copy(_up);
    case MODE.TARGET:
      if (!target) return null;
      return _a.copy(targetOffset(v, target)).normalize();
    case MODE.ANTITARGET:
      if (!target) return null;
      return _a.copy(targetOffset(v, target)).normalize().negate();
    default: return null;
  }
}

/** Vector from the vessel to another body, in the vessel's parent frame (m). */
export function targetOffset(v, body, out = _c) {
  out.subVectors(body.pos, v.parent.pos).multiplyScalar(AU_M).sub(v.r);
  return out;
}

// ============================================================================
// THE AUTOPILOT
// ============================================================================
export class Autopilot {
  constructor(vessel) {
    this.v = vessel;
    this.mode = MODE.OFF;
    this.program = null;          // the active flight program, if any
    this.target = null;           // a body, for transfers and rendezvous
    this.node = null;             // { dv: Vector3, t: seconds from now }
    this.status = 'Manual control';
    this.log = [];
    // Ascent parameters. These are the pilot's, not the vehicle's — a launch
    // profile is a choice, and the same rocket flies differently with a
    // different one.
    this.ascent = {
      targetApo: vessel.vehicle.target?.apoapsis ?? 200e3,
      inclination: vessel.vehicle.target?.inclination ?? 28.5,
      pitchStart: 55,             // m/s at which the pitch program starts
      turnEndV: 2350,             // m/s at which the program reaches horizontal
      turnExp: 0.62,              // shape of θ = 90°(1 − v/v_turn)^k
      climbTime: 170,             // s over which the closed loop closes the altitude deficit
      tauVert: 22,                // s — vertical-rate time constant
    };
    this.lastThrottle = 1;
  }

  // The HUD status line changes every frame; the event log must not. `say` is
  // the transient one, `note` is the one that goes in the log — and separating
  // them is the difference between a flight log and a countdown transcript.
  say(s) { this.status = s; }
  note(s) { if (this._lastNote !== s) { this._lastNote = s; this.status = s; this.v.log(s); } }

  engage(program, opts = {}) {
    this.program = program;
    this.stateName = null;
    this._integ = 0;
    Object.assign(this, opts);
    this.v.autoStage = true;
    this.note(`Autopilot — ${program}`);
  }
  disengage() { this.program = null; this.mode = MODE.OFF; this.note('Manual control'); }

  // -------------------------------------------------------------------------
  update(dt) {
    const v = this.v;
    if (v.phase === PHASE.DESTROYED) { this.program = null; return; }
    // Guidance runs before the integrator, so on the very first cycle there is
    // no telemetry yet. Take a reading rather than guarding every use of it.
    if (!v.telemetry.el) v.sample(0);
    const pa = v.env.atm ? pressure(v.env.atm, Math.max(v.altitude(), 0)) : 0;
    let aim = null;

    switch (this.program) {
      case 'ascent':      aim = this.ascentGuidance(dt, pa); break;
      case 'circularize': aim = this.circularizeGuidance(dt, pa); break;
      case 'node':        aim = this.nodeGuidance(dt, pa, this.node); break;
      case 'transfer':    aim = this.transferGuidance(dt, pa); break;
      case 'land':        aim = this.landingGuidance(dt, pa); break;
      case 'hoverslam':   aim = this.hoverslamGuidance(dt, pa); break;
      case 'edl':         aim = this.edlGuidance(dt, pa); break;
      case 'deorbit':     aim = this.deorbitGuidance(dt, pa); break;
      default:            aim = attitudeFor(this.mode, v, this.target);
    }
    if (aim) v.pointAt(aim, dt, pa);
    this.aim = aim ? aim.clone() : null;
  }

  // -------------------------------------------------------------------------
  // ASCENT
  // -------------------------------------------------------------------------
  ascentGuidance(dt, pa) {
    const v = this.v, A = this.ascent, t = v.telemetry;
    const env = v.env;
    _up.copy(v.r).normalize();
    // The launch azimuth that reaches the requested inclination, from the
    // spherical-triangle relation cos(i) = cos(lat)·sin(az). A site cannot
    // reach an inclination below its own latitude, which is why Baikonur
    // cannot launch to 28.5° and why this clamps rather than pretending.
    const lat = Math.asin(THREE.MathUtils.clamp(-_up.y, -1, 1));
    const inc = A.inclination * Math.PI / 180;
    const sinAz = THREE.MathUtils.clamp(Math.cos(inc) / Math.max(Math.cos(lat), 1e-3), -1, 1);
    const az = Math.asin(sinAz);
    _b.set(0, -1, 0);
    _c.crossVectors(_b, _up).normalize();                 // local east
    _d.crossVectors(_up, _c).normalize();                 // local north
    const heading = _e.copy(_c).multiplyScalar(Math.sin(az))
      .addScaledVector(_d, Math.cos(az)).normalize().clone();

    v.airspeed(v.r, v.v, _a);
    const vSurf = _a.length();
    const alt = v.altitude();
    const aThrust = this.fullThrust(pa) / Math.max(v.mass, 1);
    const gLoc = env.mu / v.r.lengthSq();

    // ---- throttle: the shared limiter, which is also what protects the
    // circularization and every other powered phase.
    v.throttle = this.limitThrottle(1, pa, dt);

    // ---- phase 1: vertical rise, to clear the tower and build enough speed
    // for the fins/gimbal to have authority.
    if (vSurf < A.pitchStart && alt < 2500) {
      v.throttle = 1; this.lastThrottle = 1;
      this.stateName = 'vertical';
      this.note('Ascent — vertical rise');
      this.pitchDeg = 90;
      return _a.copy(_up);
    }

    // ---- phase 2: the pitch program, flown inside an angle-of-attack limit.
    //
    // The programmed pitch is θ = 90°·(1 − v/v_turn)^k, which is the shape every
    // launcher flies: most of the turn happens early and cheaply, and by the
    // time the vehicle is fast it is nearly horizontal. What keeps it honest is
    // the SECOND term: the command is clamped to within α_max of the velocity
    // vector, and α_max is itself set by the q·α the airframe can take. In
    // thick air that is a fraction of a degree, so the vehicle really is flying
    // a gravity turn there; high up the clamp opens and the program leads.
    if (t.q > 1200 || alt < 42000) {
      this.stateName = 'turn';
      const x = THREE.MathUtils.clamp(vSurf / A.turnEndV, 0, 1);
      const prog = (Math.PI / 2) * Math.pow(1 - x, A.turnExp);
      const dir = vSurf > 1 ? _b.copy(v.airspeed(v.r, v.v, _b)).normalize() : _b.copy(_up);
      const proPitch = Math.asin(THREE.MathUtils.clamp(dir.dot(_up), -1, 1));
      const aMax = THREE.MathUtils.clamp(v.vehicle.limits.qAlpha / Math.max(t.q, 1), 0.008, 0.30);
      const pitch = THREE.MathUtils.clamp(prog, proPitch - aMax, proPitch + aMax);
      this.pitchDeg = pitch * 180 / Math.PI;
      this.say(`Ascent — pitch program ${(pitch * 180 / Math.PI).toFixed(0)}°, q ${(t.q / 1000).toFixed(1)} kPa`);
      // Horizontal component follows the launch azimuth until there is a real
      // orbital plane to follow, then the plane itself.
      _c.copy(v.v).addScaledVector(_up, -v.v.dot(_up));
      const horiz = _c.lengthSq() > 4e4 ? _c.normalize() : _c.copy(heading);
      return _a.copy(horiz).multiplyScalar(Math.cos(pitch))
        .addScaledVector(_up, Math.sin(pitch)).normalize();
    }

    // ---- phase 3: closed loop, out of the air.
    //
    // Hold a VERTICAL SPEED that runs the remaining altitude deficit down over
    // T_climb, and pitch to whatever that needs. As the deficit closes the
    // commanded rate falls to zero and the required pitch falls with it, so the
    // vehicle flattens on its own — no separate "now go horizontal" rule and no
    // discontinuity. Everything left over goes into horizontal speed, which is
    // what actually buys the orbit.
    this.stateName = 'closed';
    const el = t.el;
    const apoAlt = el.ra - env.radius;
    // Hand over when the apoapsis is where it was asked to be — OR when the
    // periapsis has already climbed clear of the atmosphere, which means the
    // vehicle is in orbit whatever the apoapsis says. Without the second test a
    // launcher that ends up in a 178 × 80 km orbit while aiming for 185 keeps
    // flying an ascent forever, seven kilometres short of a number that no
    // longer means anything.
    const safeAlt = env.atm ? env.atm.top * 0.6 : env.radius * 0.002;
    if (Number.isFinite(el.ra) && (apoAlt >= A.targetApo * 0.998 || (el.rp - env.radius) > safeAlt)) {
      v.throttle = 0;
      this.note(`MECO — ${(apoAlt / 1000).toFixed(0)} × ${((el.rp - env.radius) / 1000).toFixed(0)} km, coasting`);
      this.engage('circularize');
      return attitudeFor(MODE.PROGRADE, v);
    }
    const vVert = v.v.dot(_up);
    _c.copy(v.v).addScaledVector(_up, -vVert);
    const vHoriz = _c.length();
    const R = v.r.length();
    const wantVert = THREE.MathUtils.clamp((A.targetApo - alt) / A.climbTime, 0, 1500);
    // The vertical acceleration the engine must supply: hold the vehicle up
    // (gravity), minus what the horizontal speed is ALREADY supplying
    // (centripetal), plus the correction that walks the climb rate toward its
    // target over τ. The centripetal term is what retires the loop on its own —
    // as the vehicle approaches orbital speed it cancels gravity, the required
    // pitch goes to zero, and the vehicle is level and in orbit.
    const aVert = gLoc - (vHoriz * vHoriz) / R + (wantVert - vVert) / A.tauVert;
    // The nose never goes below the horizon on the way up. Without this floor a
    // stage that separates with more climb rate than the loop wants points
    // itself downward to shed it, which converts most of an upper stage into
    // nothing at all.
    const pitch = THREE.MathUtils.clamp(
      Math.asin(THREE.MathUtils.clamp(aVert / Math.max(aThrust, 1e-3), -0.95, 0.95)),
      -0.10, 0.95);
    this.pitchDeg = pitch * 180 / Math.PI;
    this.say(`Ascent — closed loop · apo ${(apoAlt / 1000).toFixed(0)}/${(A.targetApo / 1000).toFixed(0)} km, pitch ${(pitch * 180 / Math.PI).toFixed(0)}°`);
    _c.copy(v.v).addScaledVector(_up, -v.v.dot(_up));
    const horiz = _c.lengthSq() > 4e4 ? _c.normalize() : _c.copy(heading);
    return _a.copy(horiz).multiplyScalar(Math.cos(pitch))
      .addScaledVector(_up, Math.sin(pitch)).normalize();
  }

  // -------------------------------------------------------------------------
  // NODES
  // -------------------------------------------------------------------------
  /** A node that circularizes at whichever apsis is ahead — apoapsis if we are
   *  climbing to it, periapsis if the orbit is already closed and low. */
  planCircularize(atApo = true) {
    const v = this.v, el = v.telemetry.el, mu = v.env.mu;
    if (!Number.isFinite(el.ra) && atApo) return null;
    const R = atApo ? el.ra : el.rp;
    const tGo = atApo ? timeToApoapsis(el, mu) : timeToPeriapsis(el, mu);
    if (!Number.isFinite(R) || !Number.isFinite(tGo)) return null;
    // At an apsis the velocity is purely horizontal, so circularizing is a pure
    // prograde (or retrograde) burn of |v_circ − v_apsis|.
    const vCirc = Math.sqrt(mu / R);
    const vAt = Math.sqrt(Math.max(mu * (2 / R - 1 / el.a), 0));
    // Direction: the horizontal at that apsis. Propagate to find it rather than
    // guessing — the orbit may be inclined and the apsis is not "over there".
    const rA = new THREE.Vector3(), vA = new THREE.Vector3();
    if (!propagate(v.r, v.v, mu, tGo, rA, vA)) return null;
    const dir = vA.normalize();
    return { dv: dir.multiplyScalar(vCirc - vAt), t: tGo, label: atApo ? 'Circularize at apoapsis' : 'Circularize at periapsis' };
  }

  /**
   * ORBITAL INSERTION — the same law as the ascent's closed loop, aimed at zero
   * vertical speed instead of a climb rate.
   *
   * A node is the wrong tool for this. A circularization from a steep insertion
   * can be a thousand metres per second, which on an upper stage is a burn two
   * or three minutes long — and over two minutes the orbit rotates out from
   * under a direction that was frozen at ignition, the cosine loss climbs, and
   * eventually the vehicle is thrusting sideways to the burn it thinks it is
   * making. Real vehicles do not fly a long insertion burn as an impulse; they
   * fly it as guidance. So does this:
   *
   *   pitch so that   a_vertical = g − v_horiz²/r + (0 − ṙ)/τ
   *
   * i.e. hold the vehicle in the vertical balance a circular orbit requires,
   * and put everything else into horizontal speed. When the centripetal term
   * cancels gravity the required pitch is zero and the orbit is circular, so
   * the loop retires itself.
   */
  circularizeGuidance(dt, pa) {
    const v = this.v, env = v.env, t = v.telemetry;
    _up.copy(v.r).normalize();
    const R = v.r.length();
    const vVert = v.v.dot(_up);
    _c.copy(v.v).addScaledVector(_up, -vVert);
    const vHoriz = _c.length();
    const target = this.ascent.targetApo + env.radius;

    // Done when the PERIAPSIS is where it was asked to be, or when the orbit is
    // round and high enough to stay up. Testing the periapsis is what stops a
    // high-Δv upper stage running away: eccentricity alone is satisfied by a
    // 1 300 × 3 km orbit as easily as by a circular one, and only one of those
    // survives the next hour.
    const safe = env.atm ? env.atm.top * 0.62 : env.radius * 0.001;
    // "In orbit" is a physical statement, not a cosmetic one: the periapsis is
    // clear of the atmosphere and the orbit is round enough to stay that way.
    // Chasing a perfectly circular orbit past that point spends propellant on a
    // number rather than on the mission, and a real upper stage does not.
    if (t.peri >= (target - env.radius) * 0.92 || (t.ecc < 0.014 && t.peri > safe)) {
      v.throttle = 0; this.program = null; this.mode = MODE.PROGRADE;
      v.phase = PHASE.ORBIT;
      this.note(`Orbit — ${(t.apo / 1000).toFixed(0)} × ${(t.peri / 1000).toFixed(0)} km, e = ${t.ecc.toFixed(4)}`);
      return attitudeFor(MODE.PROGRADE, v);
    }
    // Where to burn. Two cases, and separating them is what makes this
    // reliable:
    //
    //   The periapsis is already clear of the atmosphere — the orbit is safe,
    //   so there is time to be efficient, and the burn waits for apoapsis where
    //   raising the periapsis is cheapest.
    //
    //   The periapsis is NOT clear — the vehicle is on a trajectory that ends in
    //   the atmosphere, and waiting is how you arrive there. Burn now.
    //
    // The earlier version waited for a window of tBurn·0.65 + 20 seconds around
    // apoapsis, which for a 30 m/s trim burn is a 22-second slot that the
    // vehicle can pass through between samples — and having missed it, it
    // cheerfully coasted another 85 minutes for the next one. A rule that
    // depends on catching a narrow window is a rule that will miss it.
    const tApo = timeToApoapsis(t.el, env.mu);
    const aThrust = this.fullThrust(pa) / Math.max(v.mass, 1);
    const dvNeed = Math.max(Math.sqrt(env.mu / Math.max(t.el.ra, R)) - vHoriz, 0);
    const tBurn = burnTimeFor(dvNeed, v.mass, this.fullThrust(pa), this.currentIsp(pa));
    if (t.peri > safe && Number.isFinite(tApo) && tApo > tBurn * 0.5 + 25) {
      v.throttle = 0;
      this.say(`Coasting to apoapsis — T-${tApo.toFixed(0)} s, insertion Δv ${dvNeed.toFixed(0)} m/s`);
      return attitudeFor(MODE.PROGRADE, v);
    }

    const gLoc = env.mu / (R * R);
    // The vertical acceleration a circular orbit needs here: gravity minus what
    // the horizontal speed already supplies, plus the correction that drives
    // the climb rate to zero.
    // Same balance as the ascent loop, aimed at zero climb rate. The floor on
    // the pitch matters as much here: a stage that reaches its target apoapsis
    // still climbing at several hundred metres per second will otherwise point
    // itself steeply down to null that out, and spend the insertion budget
    // digging its own periapsis into the ground.
    const aVert = gLoc - (vHoriz * vHoriz) / R + (0 - vVert) / 22;
    const pitch = THREE.MathUtils.clamp(
      Math.asin(THREE.MathUtils.clamp(aVert / Math.max(aThrust, 1e-3), -0.9, 0.9)), -0.30, 0.9);
    v.throttle = this.limitThrottle(1, pa, dt);
    this.say(`Insertion burn — ${(t.apo / 1000).toFixed(0)} × ${(t.peri / 1000).toFixed(0)} km, e ${t.ecc.toFixed(3)}, Δv ${dvNeed.toFixed(0)} m/s`);
    if (this.fullThrust(pa) <= 0 && v.nextStage) v.stage();
    const horiz = vHoriz > 50 ? _c.normalize() : _c.copy(v.forward(_d));
    return _a.copy(horiz).multiplyScalar(Math.cos(pitch))
      .addScaledVector(_up, Math.sin(pitch)).normalize();
  }

  /**
   * Execute a node. The three parts that make this reliable:
   *   · point at the node vector and WAIT — a burn started before the vehicle
   *     has turned is a burn in the wrong direction;
   *   · ignite at T − t_burn/2, from the rocket equation at the current mass;
   *   · cut when the remaining Δv projected onto the node goes negative.
   */
  nodeGuidance(dt, pa, node) {
    const v = this.v;
    if (!node) { this.say('No node'); v.throttle = 0; return attitudeFor(MODE.PROGRADE, v); }
    if (!this.burning) {
      // The node was planned for a moment in the future; track it down as the
      // clock runs so the estimate keeps improving.
      this.nodeVec = node.dv.clone();
      this.nodeT = node.t;
      this.nodeDvTotal = node.dv.length();
      this.burnRemaining = this.nodeDvTotal;
    }
    const dir = _a.copy(this.nodeVec).normalize();
    // Nothing lit and nothing left to burn in what IS lit: the next stage has
    // to be ignited before there is a burn to execute at all. This is the case
    // where an ascent reaches its target apoapsis mid-stage — Apollo's S-II cut
    // off at insertion and the S-IVB lit for the circularization, and without
    // this the vehicle counts down to a burn it has no engine for.
    if (this.fullThrust(pa) <= 0 && v.nextStage) v.stage();
    const prop = v.propulsion(pa);
    const fullThrust = this.fullThrust(pa);
    const tBurn = burnTimeFor(this.burnRemaining, v.mass, fullThrust, this.currentIsp(pa));
    this.nodeT -= dt;

    if (!this.burning && this.nodeT > tBurn / 2) {
      v.throttle = 0;
      this.say(`${node.label || 'Node'} — T-${Math.max(this.nodeT - tBurn / 2, 0).toFixed(0)} s, Δv ${this.burnRemaining.toFixed(1)} m/s`);
      // Only slew to the node when the burn is close. The node vector is fixed
      // in space but the vessel is not, so "point at the node" a whole orbit
      // early means chasing a target that sweeps 180° — which a real crew would
      // never do and which, on cold gas at 70 s of specific impulse, empties the
      // attitude tanks long before the burn. Until then, hold prograde: free,
      // stable, and already within a few degrees of most node directions.
      const lead = Math.max(3 * tBurn, 90);
      return this.nodeT < lead ? dir : attitudeFor(MODE.PROGRADE, v);
    }
    // ignition
    if (!this.burning) { this.burning = true; this.note(`${node.label || 'Node'} — ignition, Δv ${this.burnRemaining.toFixed(1)} m/s`); }
    // Burn while pointing near enough, and account for the cosine loss rather
    // than pretending there is none. Gating the throttle on a TIGHT error is
    // what deadlocks a vehicle whose only attitude authority is its own gimbal:
    // it cannot turn without thrusting and will not thrust until it has turned.
    // 20° is loose enough to break that and tight enough that the loss (6%) is
    // charged honestly to the burn.
    const err = v.forward(_b).angleTo(dir);
    v.throttle = err < 0.35 ? this.limitThrottle(1, pa, dt) : 0;
    if (prop.F > 0) this.burnRemaining -= (prop.F / v.mass) * Math.cos(err) * dt;
    if (this.burnRemaining <= 0.05 || v.deltaVRemaining(pa) < 0.01) {
      v.throttle = 0; this.burning = false;
      this.note(`${node.label || 'Node'} — cutoff`);
      this.node = null;
      if (this.program === 'circularize' || this.program === 'node') {
        this.program = null; this.mode = MODE.PROGRADE;
        this.v.phase = PHASE.ORBIT;
        this.note('In orbit');
      } else { this.stateName = 'done'; }
    }
    return dir;
  }

  /**
   * The throttle every program should actually command, given what it wants.
   *
   * Two limits, both solved rather than nudged, plus the engine-shutdown escape
   * hatch for when the throttle has run out of authority. This lives here and
   * not in the ascent because a light upper stage circularizing is exactly as
   * capable of tearing itself apart as one climbing — the Starship's third burn
   * pulls more g than its first.
   */
  limitThrottle(want, pa, dt) {
    const v = this.v, t = v.telemetry, lim = v.vehicle.limits;
    let th = want;
    const qTarget = lim.maxQ * 0.70;
    if (t.q > qTarget) th = Math.min(th, 1 - 2.2 * (t.q / qTarget - 1));
    const gTarget = lim.maxG * 0.88;
    const Ffull = this.fullThrust(pa);
    if (Ffull > 0) th = Math.min(th, (gTarget * G0 * v.mass + (t.drag || 0)) / Ffull);
    // ENGINE SHUTDOWN, decided BEFORE the thrust is commanded rather than after
    // it has been felt. A nine-engine booster at its 57% floor pulls 8 g on an
    // empty tank, and one frame of that is enough to lose the vehicle — so
    // waiting to measure the overload and then reacting is a guidance law that
    // reliably arrives one step too late. The test is on what the floor WOULD
    // produce, which is knowable in advance.
    this.shutCool = Math.max(0, (this.shutCool || 0) - (dt || 0));
    const stC = v.currentStage;
    if (want > 0 && !this.shutCool && !this.manualEngines
        && stC?.spec.engine && Ffull > 0 && stC.live > 1) {
      const floor = stC.spec.engine.solid ? 1 : (stC.spec.engine.throttleMin ?? 1);
      const gAtFloor = (Ffull * floor - (t.drag || 0)) / (v.mass * G0);
      if (th <= floor + 1e-6 && gAtFloor > gTarget) {
        // How many engines can stay lit and still keep the floor under the
        // target. Solved rather than stepped one at a time, because on a nearly
        // empty stage the acceleration climbs by a g a second.
        const ratio = (gTarget * G0 * v.mass + (t.drag || 0)) / (Ffull * floor);
        const keep = Math.max(1, Math.floor(stC.live * Math.min(ratio, 1)));
        if (keep < stC.live) {
          v.shutdownEngines(stC.live - keep);
          this.shutCool = 1.0;
          // Re-solve against the thrust that is actually left.
          const F2 = this.fullThrust(pa);
          if (F2 > 0) th = Math.min(1, (gTarget * G0 * v.mass + (t.drag || 0)) / F2);
        }
      }
    }
    th = this.throttleFor(THREE.MathUtils.clamp(th, 0, 1));
    this.lastThrottle = th || 1;
    return th;
  }

  /** Thrust at full throttle from the engines that are actually RUNNING —
   *  `st.live`, not the stage's built count. Using the built count makes every
   *  throttle solve, burn-time estimate and g prediction wrong by the ratio of
   *  the two the moment anything shuts an engine down, and the shutdown logic
   *  then reads its own output as an overload and shuts down again. */
  fullThrust(pa) {
    let F = 0;
    for (const st of this.v.liveStages()) {
      if (!st.spec.engine || st.prop <= 0) continue;
      F += engineOutput(st.spec.engine, st.live, pa, 1).F;
      if (st.spec.vacEngine) F += engineOutput(st.spec.vacEngine, st.spec.vacCount, pa, 1).F;
    }
    return F;
  }
  currentIsp(pa) {
    const st = this.v.liveStages().find(s => s.spec.engine && s.prop > 0);
    return st ? engineOutput(st.spec.engine, st.live, pa, 1).isp : 300;
  }

  // -------------------------------------------------------------------------
  // INTERPLANETARY TRANSFER
  // -------------------------------------------------------------------------
  /**
   * Plan a transfer to `target`. Two cases, and the difference is which body's
   * gravity dominates the answer:
   *
   *   SAME PARENT — a straight Hohmann between the two orbits, with a wait for
   *   the phase angle. This is the LEO→GEO and Earth→Mars-around-the-Sun case.
   *
   *   DIFFERENT PARENT — the vessel must first leave its parent's sphere of
   *   influence with the right hyperbolic excess velocity, and the departure
   *   burn is far smaller than the heliocentric Δv it buys because it is made
   *   deep in the parent's well (the Oberth effect). The planner reports both
   *   numbers, because confusing them is the single most common way to get an
   *   interplanetary Δv budget wrong by 2 km/s.
   */
  planTransfer(target) {
    const v = this.v;
    const dominant = v.bodies.reduce((a, b) => (b.mass > (a?.mass ?? -1) ? b : a), null);
    if (!target || !dominant || target === v.parent) return null;

    // THE TARGET IS IN THE SAME WELL. A Moon shot from Earth orbit is a Hohmann
    // about the EARTH — that is what a translunar injection is — and planning
    // it about the Sun instead compares two almost identical heliocentric
    // orbits and reports a transfer costing twenty metres per second. The test
    // is whose gravity actually dominates at the target, not which body is
    // heaviest in the scene.
    if (v.primaryOf(target) === v.parent) {
      const r1 = v.r.length();
      const r2 = _a.subVectors(target.pos, v.parent.pos).multiplyScalar(AU_M).length();
      const h = hohmann(v.env.mu, r1, r2);
      const want = h.phase;
      const now = phaseAngle(v.r, _a);
      let wait = want - now;
      while (wait < 0) wait += 2 * Math.PI;
      const T1 = v.telemetry.el.period, T2 = 2 * Math.PI * Math.sqrt(r2 ** 3 / v.env.mu);
      const rate = 2 * Math.PI * (1 / T2 - 1 / T1);
      const waitS = Math.abs(rate) > 1e-12 ? wait / -rate : 0;
      return { kind: 'hohmann', ...h,
               waitS: waitS > 0 ? waitS : waitS + Math.abs(h.synodic),
               label: `Transfer to ${target.name}` };
    }

    if (v.parent === dominant) {
      // heliocentric-to-heliocentric
      const r1 = v.r.length();
      const r2 = _a.subVectors(target.pos, v.parent.pos).multiplyScalar(AU_M).length();
      const h = hohmann(v.env.mu, r1, r2);
      const want = h.phase;
      const now = phaseAngle(v.r, _a);
      let wait = (want - now);
      while (wait < 0) wait += 2 * Math.PI;
      const T1 = v.telemetry.el.period, T2 = 2 * Math.PI * Math.sqrt(r2 ** 3 / v.env.mu);
      const rate = 2 * Math.PI * (1 / T2 - 1 / T1);
      const waitS = Math.abs(rate) > 1e-12 ? wait / -rate : 0;
      return { kind: 'hohmann', ...h, waitS: waitS > 0 ? waitS : waitS + Math.abs(h.synodic),
               label: `Transfer to ${target.name}` };
    }

    // escape the current parent first
    const aAU = v.parent.pos.distanceTo(dominant.pos);
    const soi = sphereOfInfluence(aAU * AU_M, v.parent.mass, dominant.mass);
    const muP = GM_SUN * dominant.mass;
    const r1 = aAU * AU_M;
    const r2 = _a.subVectors(target.pos, dominant.pos).multiplyScalar(AU_M).length();
    const h = hohmann(muP, r1, r2);
    // v∞ needed, then the burn from the current orbit — the Oberth saving is
    // the difference between these two, and it is large.
    const vInf = Math.abs(h.dv1);
    const R = v.r.length();
    const vEsc2 = 2 * v.env.mu / R;
    const vNeeded = Math.sqrt(vEsc2 + vInf * vInf);
    const vNow = v.v.length();
    return {
      kind: 'escape', vInf, soi,
      dvBurn: vNeeded - vNow, dvHelio: h.dv, tof: h.tof,
      phase: h.phase, synodic: h.synodic,
      label: `Depart ${v.parent.name} for ${target.name}`,
    };
  }

  transferGuidance(dt, pa) {
    const v = this.v;
    if (!this.plan) this.plan = this.planTransfer(this.target);
    const p = this.plan;
    if (!p) { this.say('No transfer solution'); this.program = null; return null; }

    if (p.kind === 'escape') {
      if (!this.node) {
        // Burn prograde at the next periapsis — deepest in the well, where the
        // Oberth benefit is largest.
        const el = v.telemetry.el;
        const tGo = timeToPeriapsis(el, v.env.mu);
        const rP = new THREE.Vector3(), vP = new THREE.Vector3();
        if (!propagate(v.r, v.v, v.env.mu, Number.isFinite(tGo) ? tGo : 0, rP, vP)) return null;
        this.node = { dv: vP.normalize().multiplyScalar(p.dvBurn), t: Number.isFinite(tGo) ? tGo : 0,
                      label: p.label };
      }
      return this.nodeGuidance(dt, pa, this.node);
    }
    // heliocentric Hohmann: wait for the window, then burn
    if (p.waitS > 0) {
      p.waitS -= dt;
      v.throttle = 0;
      this.say(`Transfer window in ${fmtDur(p.waitS)} — phase ${(phaseAngle(v.r, _a.subVectors(this.target.pos, v.parent.pos)) * 180 / Math.PI).toFixed(1)}°, want ${(p.phase * 180 / Math.PI).toFixed(1)}°`);
      return attitudeFor(MODE.PROGRADE, v);
    }
    if (!this.node) {
      this.node = { dv: _a.copy(v.v).normalize().multiplyScalar(p.dv1).clone(), t: 0, label: p.label };
    }
    return this.nodeGuidance(dt, pa, this.node);
  }

  // -------------------------------------------------------------------------
  // POWERED DESCENT — Apollo's programs, on Apollo's gates
  // -------------------------------------------------------------------------
  /**
   * The quadratic guidance law. Returns the commanded THRUST acceleration
   * (gravity already added back), in the parent frame.
   */
  quadratic(rT, vT, tGo, out) {
    const v = this.v;
    // Δr = r_T − r − v·t_go , Δv = v_T − v
    _b.copy(rT).sub(v.r).addScaledVector(v.v, -tGo);
    _c.copy(vT).sub(v.v);
    out.copy(_b).multiplyScalar(6 / (tGo * tGo)).addScaledVector(_c, -2 / tGo);
    // the engine also has to hold the vehicle up
    v.gravity(v.r, _d);
    out.sub(_d);
    return out;
  }

  /**
   * THE TERMINAL DESCENT LAW — one controller, used by every landing.
   *
   * The vertical and lateral axes are treated SEPARATELY, and that separation
   * is the whole design. A single three-dimensional "fly to the target" law
   * saturates: a vehicle a kilometre up with a hundred metres per second of
   * sideways drift asks for more lateral acceleration than the engine has, the
   * command ends up pointing nearly horizontal, and the vehicle falls out of
   * the sky perfectly on course.
   *
   * VERTICAL — a reference descent rate that is exactly what the vehicle can
   * still stop from, plus the rate it wants to touch down at:
   *
   *     v_ref(h) = −( v_touch + √(2·a_dec·h) ),   a_dec = k·(F/m − g)
   *
   * The commanded vertical acceleration closes the gap over τ, and is CLAMPED
   * AT ZERO: an engine cannot push downward, and a vehicle descending slower
   * than the reference should simply fall until it catches it. That free fall
   * is not a gap in the law, it is the fuel-optimal thing to do — every second
   * spent holding a vehicle up is a second of gravity loss.
   *
   * LATERAL — null the ground-relative drift and close on the site, with the
   * result capped at a maximum TILT. A lander leans a few degrees to stop
   * drifting; it never points sideways, and capping the tilt is what guarantees
   * the vertical channel keeps the authority it was promised.
   *
   * Everything is ground-relative, because a landing site is a place on a
   * rotating body and the gear cares about motion relative to it.
   */
  descentLaw(aMax, vTouch, maxTiltRad, tau, decFrac = 0.6, vCap = Infinity, holdBelow = 0) {
    const v = this.v, env = v.env;
    const alt = Math.max(v.altitude(), 0);
    _up.copy(v.r).normalize();
    const g = env.mu / Math.max(v.r.lengthSq(), 1);
    v.airspeed(v.r, v.v, _g);
    const vVert = _g.dot(_up);
    _b.copy(_g).addScaledVector(_up, -vVert);          // lateral drift

    const aDec = Math.max(decFrac * (aMax - g), 0.05);
    // The reference is also CAPPED. Without a cap it is whatever the vehicle
    // could survive — 113 m/s at the Apollo approach gate — and the free-fall
    // clamp then means the lander does not touch its engine until it is going
    // that fast, arriving at the surface having spent the whole approach
    // accelerating. A real approach phase descends at a chosen rate (Apollo's
    // is about 45 m/s at hi-gate) so that there is time to do the other things
    // an approach is for: fly out the sideways drift, and look at the site.
    // Below `holdBelow` the reference is simply the touchdown rate — a
    // constant-rate final descent. The square-root profile is still several
    // metres per second a metre off the ground, which is more than any landing
    // gear is rated for, so the last stretch has to be flown at a held rate
    // instead. This is not a smoothing hack: it is what a sky crane does for
    // its last twenty metres and what a lunar module does for its last ten.
    const vRef = alt < holdBelow
      ? -vTouch
      : -Math.min(vTouch + Math.sqrt(2 * aDec * alt), vCap);
    // FEED-FORWARD. Following the reference means decelerating at a_dec — the
    // profile is √(2·a_dec·h), and differentiating it along the trajectory
    // gives exactly that. Without the term, a vehicle sitting perfectly on the
    // reference is commanded g and nothing more, i.e. told to hold its speed,
    // and it rides its own profile straight into the ground: the error term
    // only ever reacts to falling BEHIND, and by then there is no altitude left
    // to catch up in. The zero clamp still gives free fall when the vehicle is
    // above the profile, which is the fuel-optimal thing to do.
    // No feed-forward in the held-rate region: the reference is constant there,
    // so following it needs gravity and nothing else.
    const aFF = (vVert < 0 && alt >= holdBelow) ? aDec : 0;
    // Free fall is fuel-optimal a long way up and reckless close in: a vehicle
    // that is slower than its reference at 150 m and takes the free ride
    // arrives at the held-rate region 40% faster than it left, with no altitude
    // left to fix it. Below a few times the hold altitude the command floors at
    // g — hold what you have — rather than at zero.
    const floorA = alt < holdBelow * 5 ? g : 0;
    const aVert = Math.max(g + aFF + (vRef - vVert) / tau, floorA);

    // lateral: kill the drift, and lean gently toward the site
    _c.set(0, 0, 0);
    if (this.site) {
      _c.subVectors(this.site, v.r);
      _c.addScaledVector(_up, -_c.dot(_up));
      const off = _c.length();
      // Deliberately weak, and capped hard. Landing on the exact spot is worth
      // something; not landing sideways is worth more. A strong site-seeking
      // term fights the drift-killing term whenever the vehicle is already
      // moving toward the site, and the two settle at a lateral speed neither
      // of them wanted.
      if (off > 1e-3) _c.multiplyScalar(Math.min(off, 25) / off * 0.02);
    }
    _d.copy(_b).multiplyScalar(-1 / (tau * 0.7)).add(_c);
    // The lateral authority is a fraction of the ENGINE, not a fraction of
    // whatever the vertical channel happens to be asking for right now. Tying
    // it to the vertical command starves the lateral axis exactly when the
    // vehicle is coasting down a capped reference and the vertical command is
    // only enough to hold it up — on the Moon that is 1.6 m/s², which allows
    // a tenth of a g of lateral correction and leaves the lander to arrive with
    // most of its approach speed intact.
    const maxLat = aMax * Math.sin(maxTiltRad);
    if (_d.length() > maxLat) _d.setLength(maxLat);

    this.vRef = vRef; this.vVertNow = vVert; this.latNow = _b.length();
    return _e.copy(_up).multiplyScalar(aVert).add(_d);
  }

  /**
   * Keep a commanded thrust direction inside what the airframe can take.
   *
   * q·α is one of the four ways this vehicle breaks, so a controller that asks
   * for a large lateral correction in thick air is asking to be destroyed. The
   * allowable misalignment is α_max = qα_limit / q, and the command is rotated
   * back toward the airstream until it fits — which is why a booster's lateral
   * authority vanishes as it descends, and why it has to be pointed at the pad
   * long before it gets there.
   */
  aeroLimit(cmd, out) {
    const v = this.v, t = v.telemetry;
    if (!v.env.atm || !(t.q > 200)) return out.copy(cmd).normalize();
    v.airspeed(v.r, v.v, _b);
    const va = _b.length();
    if (va < 1) return out.copy(cmd).normalize();
    _b.multiplyScalar(-1 / va);                       // retrograde, the aligned attitude
    out.copy(cmd).normalize();
    // 0.85 of the limit, because the limit is where the vehicle breaks and
    // steering to exactly there leaves nothing for a gust or a lag.
    const aMaxRad = THREE.MathUtils.clamp(0.85 * v.vehicle.limits.qAlpha / t.q, 0.01, Math.PI);
    const ang = out.angleTo(_b);
    if (ang <= aMaxRad) return out;
    // rotate `out` toward the airstream until it is within the limit
    _c.crossVectors(_b, out);
    if (_c.lengthSq() < 1e-12) return out.copy(_b);
    _c.normalize();
    return out.copy(_b).applyAxisAngle(_c, aMaxRad);
  }

  /** Carry the landing site round with the body it is on. */
  spinSite(dt) {
    if (!this.site) return;
    const w = -this.v.env.rotRate * dt;
    const c = Math.cos(w), sn = Math.sin(w);
    const x = this.site.x, z = this.site.z;
    this.site.set(x * c - z * sn, this.site.y, x * sn + z * c);
  }

  landingGuidance(dt, pa) {
    const v = this.v, env = v.env, t = v.telemetry;
    this.spinSite(dt);
    const prof = v.vehicle.descent;
    const alt = v.altitude();
    _up.copy(v.r).normalize();
    const vVert = v.v.dot(_up);
    const aMax = this.fullThrust(pa) / v.mass;

    if (!this.site) {
      // Put the landing site where this vehicle can actually stop, straight
      // down-track. Braking from v_h to the hi-gate speed at the available
      // acceleration covers  (v₁ + v₂)/2 · (v₁ − v₂)/a  — so the range is
      // derived from the vehicle rather than read out of a stored number that
      // belonged to a different one. A site placed short forces the guidance to
      // brake harder than the engine can, and the quadratic law answers that by
      // lofting: the lander climbs twenty kilometres on its way down.
      const vh = Math.sqrt(Math.max(t.speed * t.speed - vVert * vVert, 0));
      const vGate = prof ? prof.hiGate.vHoriz : 130;
      const brake = Math.max(aMax * 0.72, 0.05);
      const range = Math.max((vh + vGate) * 0.5 * Math.max(vh - vGate, 0) / brake,
                             (prof ? prof.hiGate.range : 7000) * 2);
      const ang = range / env.radius;
      _b.copy(v.v).addScaledVector(_up, -vVert).normalize();
      this.site = _up.clone().multiplyScalar(Math.cos(ang)).addScaledVector(_b, Math.sin(ang))
        .multiplyScalar(env.radius);
      this.stateName = 'P63';
      this.note('P63 — braking phase');
    }
    const site = this.site;

    if (this.stateName === 'P63') {
      const gate = prof ? prof.hiGate : { alt: 2400, range: 7000, vVert: -45, vHoriz: 129 };
      // hi-gate target: `gate.alt` above the site, `gate.range` short of it
      _a.copy(site).normalize();
      _b.copy(v.v).addScaledVector(_up, -v.v.dot(_up));
      if (_b.lengthSq() < 1) _b.copy(_up).cross(_a);
      _b.normalize();
      const rT = _a.clone().multiplyScalar(env.radius + gate.alt).addScaledVector(_b, -gate.range);
      const vT = _b.clone().multiplyScalar(gate.vHoriz).addScaledVector(_a, gate.vVert);
      // Aim the braking phase just ABOVE the DPS's forbidden throttle band, so
      // it flies at full thrust the way the real P63 does, rather than
      // repeatedly commanding a setting the engine is not allowed to hold and
      // being rounded down to 60% of it.
      const tGo = this.trackTGo(rT, vT, aMax, dt, 0.96);
      const cmd = this.quadratic(rT, vT, tGo, _e);
      const need = cmd.length();
      v.throttle = this.limitThrottle(need / Math.max(aMax, 1e-6), pa, dt);
      this.say(`P63 — braking · ${(alt / 1000).toFixed(1)} km, ${t.speed.toFixed(0)} m/s, ${tGo.toFixed(0)} s to hi-gate`);
      if (alt < gate.alt * 1.12 || tGo < 2) { this.stateName = 'P64'; this.note('P64 — approach phase'); }
      return cmd.normalize();
    }

    if (this.stateName === 'P64') {
      const gate = prof ? prof.loGate : { alt: 30, range: 11 };
      _a.copy(site).normalize();
      const rT = _a.clone().multiplyScalar(env.radius + gate.alt);
      const vT = _a.clone().multiplyScalar(-1.2);
      const cmd = this.descentLaw(aMax, 2.0, 0.60, 3.5, 0.6, 50);
      v.throttle = this.limitThrottle(cmd.length() / Math.max(aMax, 1e-6), pa, dt);
      this.say(`P64 — approach · ${alt.toFixed(0)} m, ${this.vVertNow.toFixed(1)} of ${this.vRef.toFixed(1)} m/s, ${this.latNow.toFixed(1)} m/s lateral`);
      // Hand to terminal descent when the vehicle is genuinely over the site,
      // not merely low. Apollo's lo-gate is a STATE — 30 m up, 11 m short, and
      // essentially stopped — and transitioning on the altitude alone hands
      // P66 a vehicle still moving 40 m/s sideways with five seconds to fix it.
      _b.copy(v.v).addScaledVector(_up, -v.v.dot(_up));
      const lateral = _b.length();
      if ((alt < gate.alt * 3.0 && lateral < 8) || alt < gate.alt * 0.7) {
        this.stateName = 'P66'; this.tGo = null; this.note('P66 — terminal descent');
      }
      return cmd.normalize();
    }

    // P66 — terminal descent. Same law, aimed at the gear's rated touchdown
    // rate with a tighter time constant and a bigger allowed lean, because this
    // is the phase where the last metre per second of sideways drift has to go.
    const aCmd = this.descentLaw(aMax, 0.8, 0.35, 1.4, 0.55, 20, 12);
    v.throttle = this.limitThrottle(aCmd.length() / Math.max(aMax, 1e-6), pa, dt);
    this.say(`P66 — terminal · ${alt.toFixed(1)} m, ${this.vVertNow.toFixed(2)} m/s, ${this.latNow.toFixed(2)} m/s lateral`);
    if (v.phase === PHASE.LANDED) { this.note('Landed'); this.program = null; v.throttle = 0; }
    return aCmd.normalize();
  }

  /**
   * Choose t_go so the commanded acceleration sits at a comfortable fraction of
   * what the engine can give.
   *
   * Apollo solved a quartic for this. Bisection gets to the same place and
   * cannot diverge, which matters because |a_cmd| falls monotonically with t_go
   * and a multiplicative search seeded badly walks the wrong way: seeded at the
   * 3000 s ceiling, the quadratic law's commanded acceleration collapses to
   * "cancel gravity", the throttle holds a TWR above 1, and a lander told to
   * descend climbs instead — which is exactly what it did.
   *
   * The bracket's upper end is a real physical estimate rather than a constant:
   * braking Δv at the available acceleration. For an Apollo PDI that is
   * 1570 m/s at 2.96 m/s², i.e. 530 s — against the 514 s the real thing took.
   */
  /**
   * Time-to-go as a COUNTDOWN that is nudged, not re-solved from nothing every
   * cycle. Time really is passing, so the honest update is to subtract dt and
   * correct slowly toward the freshly solved value; re-solving outright each
   * frame lets the answer jump by hundreds of seconds between steps, and the
   * throttle chatters between its deep-throttle floor and full power because
   * the commanded acceleration is following it.
   */
  trackTGo(rT, vT, aMax, dt, frac) {
    const solved = this.solveTGo(rT, vT, aMax, frac);
    this.tGo = this.tGo == null
      ? solved
      : Math.max(this.tGo - dt, 1) * 0.97 + solved * 0.03;
    return this.tGo;
  }

  solveTGo(rT, vT, aMax, frac = 0.72) {
    const v = this.v;
    const dv = _e.copy(vT).sub(v.v).length();
    const est = THREE.MathUtils.clamp(dv / Math.max(aMax * 0.85, 0.05), 4, 4000);
    let lo = 2, hi = est * 2.2;
    const want = aMax * frac;
    // |a_cmd| decreasing in t_go, so bisect on the sign of (a − want).
    for (let i = 0; i < 34; i++) {
      const mid = 0.5 * (lo + hi);
      const a = this.quadratic(rT, vT, mid, _e).length();
      if (a > want) lo = mid; else hi = mid;
      if (hi - lo < 0.5) break;
    }
    return 0.5 * (lo + hi);
  }

  /** Respect the engine's real throttle limits, including a forbidden band. */
  throttleFor(x) {
    const st = this.v.liveStages().find(s => s.spec.engine && s.prop > 0);
    if (!st) return 0;
    const eng = st.spec.engine;
    let th = THREE.MathUtils.clamp(x, 0, eng.maxThrottle ?? 1);
    // Below the deep-throttle floor there are two options and only one of them
    // is safe. Cutting to zero is what the old rule did whenever the request
    // fell under half the floor — and in a landing burn, where the commanded
    // acceleration drops the moment the vehicle starts tracking its reference,
    // that turns the last hundred metres into a series of free falls. A real
    // engine cannot go below its floor, so it sits AT the floor, over-brakes a
    // little, and the loop asks for less next cycle. Zero is reserved for a
    // genuine shutdown command.
    const floor = eng.throttleMin ?? 0;
    if (th < floor) th = x < 0.02 ? 0 : floor;
    // The Apollo DPS could not be run between 60% and 92.5% without eroding the
    // throttle valve, so a command inside the band has to go to one edge or the
    // other. It goes UP. Rounding down looks thriftier and is the wrong answer:
    // the guidance asked for that acceleration because it needs it, and a
    // lander that consistently delivers 60% of a 72% command arrives at the
    // surface still moving 40 m/s sideways. Propellant is recoverable; the
    // approach is not.
    if (eng.forbidden && th > eng.forbidden[0] && th < eng.forbidden[1]) {
      th = (th - eng.forbidden[0]) < (eng.forbidden[1] - th) ? eng.forbidden[0] : eng.forbidden[1];
    }
    return th;
  }

  // -------------------------------------------------------------------------
  // HOVERSLAM — propulsive booster recovery
  // -------------------------------------------------------------------------
  hoverslamGuidance(dt, pa) {
    const v = this.v, env = v.env;
    const alt = v.altitude();
    _up.copy(v.r).normalize();
    v.airspeed(v.r, v.v, _a);
    const speed = _a.length();
    const vVert = v.v.dot(_up);
    const g = env.mu / v.r.lengthSq();
    const mMin = this.throttleFor(0.0001) || 1;
    const aMax = this.fullThrust(pa) / v.mass;

    // The landing burn takes priority over the entry burn: once the vehicle is
    // inside the envelope where it must burn continuously to stop, an entry
    // burn that switches itself off because the speed dropped under a threshold
    // hands it back a vehicle it can no longer save.
    // The shortest landing burn the vehicle could possibly fly — every engine,
    // full throttle. The entry burn hands over when even that would no longer
    // fit with margin. It is used rather than the SELECTED burn's altitude
    // because the selected engine count is a discrete choice that flips between
    // two values as the altitude falls, and gating a burn on a number that
    // jumps makes the burn stutter on and off every frame.
    const stE = v.currentStage;
    const perE = stE?.spec.engine
      ? engineOutput(stE.spec.engine, 1, pa, 1).F / Math.max(v.mass, 1) : 0;
    const aFull = Math.max((stE?.spec.count ?? 1) * perE - g, 0.3);
    const hBurnPre = (vVert * vVert) / (2 * aFull);
    // ENTRY BURN. Scheduled by the dynamic pressure it is there to prevent,
    // not by an altitude: the vehicle burns retrograde whenever q climbs past a
    // third of what the airframe can take, and stops when it falls back under.
    // That is self-scheduling — a steeper return starts the burn higher and a
    // shallow one may not need it at all — and it cannot be caught out by a
    // trajectory the numbers were not written for. A fixed "70 km to 40 km at
    // over 1800 m/s" window simply does not fire on a booster that separates
    // slower, and the vehicle then meets max-q with the engines cold.
    const qLim = v.vehicle.limits.maxQ;
    // THE HANDOVER. Solved first and tested first, so the landing burn always
    // wins: an entry burn that keeps running because its own deceleration keeps
    // shrinking the predicted landing-burn altitude will run the vehicle all
    // the way to the ground, and hand over at forty metres.
    const selPre = this.solveLandingBurn(alt, vVert, pa, g);
    // The terminal landing burn belongs in the last few kilometres. Above that
    // the atmosphere and the entry burn do the braking, and they are far better
    // at it than the engines: a booster at 34 km is doing over a kilometre a
    // second, its predicted burn altitude is larger than its altitude, and
    // reading that as "burn now" starts a landing burn thirty kilometres up
    // that runs the tanks dry long before the ground.
    const terminalCeiling = env.atm ? env.atm.top * 0.08 : Infinity;
    // Ignition is at h_burn and NOT before. This is the part of a hoverslam
    // that is genuinely unforgiving: minimum throttle already gives a
    // thrust-to-weight above one, so the vehicle cannot hover, and lighting
    // early does not buy margin — it buys an ascent. Igniting at two kilometres
    // "to be safe" makes the booster stop at a hundred metres, climb back to
    // four hundred, and oscillate until the tanks are dry.
    const mustLand = this.slamming || (alt <= selPre.hBurn * 1.05 && alt < terminalCeiling);
    // Hysteresis on q: start at a third of the limit, stop at a fifth. An entry
    // burn is not a thing you pulse.
    // Start the entry burn early — a tenth of the airframe limit, which on a
    // returning booster is around 40 km — and hold it. Waiting until a third of
    // the limit means starting at 30 km with a kilometre and a half a second
    // still on the clock, and by then the air is arriving faster than the
    // engines can take it away.
    const qOn = qLim * (this.entryBurning ? 0.06 : 0.10);
    // The entry burn also stops well before the ground. Its job is to protect
    // the vehicle from the air, and its throttle is set by dynamic pressure —
    // which near the surface is still high enough to keep it lit, so it flies
    // the booster gently down to a hundred metres and hands over a vehicle
    // whose landing burn is now twenty metres long. Below half the terminal
    // ceiling the vehicle either falls or lands; nothing else.
    if (env.atm && !mustLand && alt > terminalCeiling * 0.5
        && alt > hBurnPre * 1.6 && v.telemetry.q > qOn) {
      // Throttle on how far over the line q is, so it is a trim rather than a
      // hammer, and hard over if the vehicle is genuinely in trouble.
      // Three engines for the entry burn — the count the real vehicle uses, and
      // the reason it can pull the deceleration it needs without the throttle
      // floor of nine putting it over its g limit.
      v.setEngineCount(3);
      this.manualEngines = true;
      const over = v.telemetry.q / (qLim * 0.10) - 1;
      // Through the shared limiter, so the same g cap and the same engine
      // shutdown apply here as on the way up. A nine-engine booster at its 57%
      // floor pulls 5 g on an empty tank; the limiter is what turns that into
      // the three-engine burn the real one uses.
      v.throttle = this.limitThrottle(THREE.MathUtils.clamp(0.45 + over * 2.5, 0, 1), pa, dt);
      if (!this.entryBurning) { this.entryBurning = true; this.note(`Entry burn — ${(alt / 1000).toFixed(0)} km, ${speed.toFixed(0)} m/s, q ${(v.telemetry.q / 1000).toFixed(1)} kPa`); }
      this.say(`Entry burn — ${(alt / 1000).toFixed(0)} km, ${speed.toFixed(0)} m/s, q ${(v.telemetry.q / 1000).toFixed(1)} kPa`);
      return attitudeFor(MODE.RETROGRADE, v);
    }
    if (this.entryBurning) { this.entryBurning = false; this.entryDone = true; v.throttle = 0; this.note('Entry burn cutoff'); }

    // THE ONE LINE THAT IS THE WHOLE MANOEUVRE — generalised over how many
    // engines are lit, because that is the other half of the decision.
    //
    //     h_burn(n) = v² / (2·(n·F_engine/m − g))
    //
    // Fewer engines means a lower deceleration and a higher ignition altitude.
    // The vehicle picks the FEWEST engines whose burn still fits in the
    // altitude it has left, which is exactly why a Falcon 9 lands on one engine
    // when it can and three when it cannot. Choosing the count first and then
    // computing h_burn for a different count is how you arrive at 900 m needing
    // 3 900 m of braking.
    const sel = selPre;
    const hBurn = sel.hBurn;
    if (!mustLand) {
      v.throttle = 0;
      this.say(`Falling — ${(alt / 1000).toFixed(1)} km, ${(-vVert).toFixed(0)} m/s, ignite at ${(hBurn / 1000).toFixed(2)} km`);
      return attitudeFor(MODE.RETROGRADE, v);
    }
    if (!this.slamming) {
      this.slamming = true;
      v.setEngineCount(sel.n);
      this.manualEngines = true;
      this.note(`Landing burn — ${sel.n} engine${sel.n > 1 ? 's' : ''}, ignition at ${hBurn.toFixed(0)} m`);
    }
    // Same terminal law. For a booster the reference rate IS the hoverslam
    // profile — √(2·a_net·h) is what "arrive at zero velocity at zero altitude"
    // means — and the zero clamp on the vertical command is what lets it keep
    // falling between the entry burn and the landing burn instead of hovering.
    // A booster barely leans. Six degrees of tilt against 25 kPa of dynamic
    // pressure is already 2.6 kPa·rad of the 5 the airframe allows, and the
    // attitude lags the command — so the commanded tilt has to sit well inside
    // the limit, not at it.
    const cmd = this.descentLaw(aMax, 2.0, 0.10, 1.0, 0.55, Infinity, 30);
    v.throttle = this.limitThrottle(cmd.length() / Math.max(aMax, 1e-6), pa, dt);
    this.say(`Landing burn — ${alt.toFixed(0)} m, ${this.vVertNow.toFixed(1)} of ${this.vRef.toFixed(1)} m/s, throttle ${(v.throttle * 100).toFixed(0)}%`);
    if (v.phase === PHASE.LANDED) { this.program = null; v.throttle = 0; this.note('Booster recovered'); }
    return this.aeroLimit(cmd, _a);
  }

  /**
   * The fewest engines whose landing burn still fits inside the altitude left,
   * and the altitude that burn has to start at. Scanned rather than assumed:
   * the answer depends on the vehicle's current mass, which is why it is one
   * engine on a nearly empty booster and three on a heavy one.
   */
  solveLandingBurn(alt, vVert, pa, g) {
    const v = this.v;
    const st = v.currentStage;
    if (!st || !st.spec.engine) return { n: 1, hBurn: 0 };
    const per = engineOutput(st.spec.engine, 1, pa, 1).F / Math.max(v.mass, 1);
    // The MOST engines the g limit allows, which is what makes this a hoverslam
    // rather than a descent: more deceleration means a later ignition, and the
    // whole point of the manoeuvre is to arrive at zero velocity and zero
    // altitude at the same instant, having spent as little time as possible
    // holding the vehicle up against gravity. Picking the FEWEST engines
    // instead gives an ignition altitude of thirty kilometres and a burn that
    // is mostly hover.
    const gLimit = (v.vehicle.limits.maxG * 0.85 * G0 + g);
    const n = THREE.MathUtils.clamp(Math.floor(gLimit / Math.max(per, 1e-6)), 1, st.spec.count);
    // The SAME margin the descent law flies with (decFrac), so the ignition
    // altitude and the profile the vehicle then tracks are the same curve. Sized
    // on the full deceleration instead, the burn starts exactly where a perfect
    // controller would need it and a real one with any lag at all arrives short.
    // 70% of the available deceleration, so ignition is about 20% higher than a
    // perfect controller would need. A hoverslam has no margin by construction;
    // this is the only place to put any, and without it the vehicle arrives
    // saturated at full throttle and still moving.
    const a = Math.max(0.58 * (n * per - g), 0.3);
    return { n, hBurn: (vVert * vVert) / (2 * a) };
  }

  // -------------------------------------------------------------------------
  // ENTRY, DESCENT AND LANDING — the atmospheric one
  // -------------------------------------------------------------------------
  edlGuidance(dt, pa) {
    const v = this.v, env = v.env, t = v.telemetry;
    this.spinSite(dt);
    const plan = v.vehicle.edl;
    const alt = v.altitude();
    _up.copy(v.r).normalize();
    v.airspeed(v.r, v.v, _a);
    const speed = _a.length();
    const vVert = v.v.dot(_up);
    v.throttle = 0;

    if (!this.stateName) { this.stateName = 'entry'; this.note('Entry interface'); }

    if (this.stateName === 'entry') {
      this.say(`Entry — ${(alt / 1000).toFixed(1)} km, ${speed.toFixed(0)} m/s, ${(t.heat / 1e4).toFixed(1)} W/cm²`);
      // Heat-shield forward, which is the entire job of the aeroshell.
      // A parachute is qualified for a Mach number and a dynamic pressure, not
      // an altitude — MSL's supersonic disk-gap-band deploys at Mach 1.7 and
      // about 750 Pa, wherever on the profile that happens to be. Gating on a
      // stored altitude means an entry that decelerates higher than expected
      // falls past its own deployment box with the chute still packed.
      const ch = plan?.chute ?? { mach: 1.7, deployQ: 750 };
      // The lower bound matters as much as the upper one: at the entry
      // interface there is no atmosphere at all, so Mach and q are both zero
      // and a test written only as "Mach below 1.7" fires on the first frame,
      // 125 km up, into vacuum. A parachute needs dynamic pressure to inflate.
      if (t.mach < ch.mach && t.mach > 0.05
          && t.q > (ch.deployQ ?? 750) * 0.25 && t.q < (ch.deployQ ?? 750) * 1.6) {
        this.stateName = 'chute';
        const sh = v.stages.find(s => s.attached && s.spec.chute);
        v.chuteOpen = sh ? sh.spec.chute : { area: 200, Cd: 0.62 };
        v.chuteDeploy = 0;
        this.note(`Parachute deploy — Mach ${t.mach.toFixed(2)}, ${(alt / 1000).toFixed(1)} km`);
      }
      return attitudeFor(MODE.RETROGRADE, v);
    }

    if (this.stateName === 'chute') {
      // Inflation takes a couple of seconds, and the load during it is the
      // largest of the whole descent.
      v.chuteDeploy = Math.min(1, (v.chuteDeploy || 0) + dt / 2.2);
      this.say(`On the chute — ${(alt / 1000).toFixed(2)} km, ${speed.toFixed(0)} m/s`);
      // The backshell — and the chute with it — is released LOW and SLOW, at
      // about 1.8 km and 100 m/s, and only then does the descent stage light.
      // Dropping it at parachute deploy instead leaves the descent stage to fly
      // the whole remaining descent on 390 kg of hydrazine, which is a fifth of
      // what that would take. The chute does the work; the rockets do the last
      // kilometre.
      const bs = plan?.backshell ?? { alt: 1800, v: 100 };
      if ((alt < bs.alt || speed < bs.v) && !this.shieldGone) {
        this.shieldGone = true; v.jettison('shell'); v.chuteOpen = null;
        this.stateName = 'powered';
        this.note(`Backshell separation — ${(alt / 1000).toFixed(2)} km, ${speed.toFixed(0)} m/s`);
      }
      return attitudeFor(MODE.RETROGRADE, v);
    }

    // powered descent + sky crane, on the same glide slope as every other
    // terminal phase
    const aMax = this.fullThrust(pa) / v.mass;
    const sk = plan?.skycrane ?? { alt: 20, vTouch: -0.75 };
    if (!this.site) this.site = _up.clone().multiplyScalar(env.radius);
    _a.copy(this.site).normalize();
    const rT = _a.clone().multiplyScalar(env.radius + 0.5);
    const cmd = this.descentLaw(aMax, Math.abs(sk.vTouch), 0.35, 1.8, 0.55, 120, sk.alt * 1.5);
    v.throttle = this.limitThrottle(cmd.length() / Math.max(aMax, 1e-6), pa, dt);
    if (alt < sk.alt && !this.craneOut) {
      this.craneOut = true;
      this.note('Sky crane — rover on the cables');
    }
    this.say(`Powered descent — ${alt.toFixed(0)} m, ${vVert.toFixed(2)} m/s`);
    if (v.phase === PHASE.LANDED) { this.program = null; v.throttle = 0; this.note('Touchdown'); }
    return this.aeroLimit(cmd, _b);
  }

  // -------------------------------------------------------------------------
  deorbitGuidance(dt, pa) {
    const v = this.v, el = v.telemetry.el, mu = v.env.mu;
    if (!this.node) {
      // Drop the periapsis to a target inside the atmosphere (or just under the
      // surface for an airless body), from the current apoapsis.
      const targetPeri = v.env.radius + (v.env.atm ? v.env.atm.top * 0.35 : -v.env.radius * 0.02);
      const R = el.r;
      const aNew = (R + targetPeri) / 2;
      const vNew = Math.sqrt(Math.max(mu * (2 / R - 1 / aNew), 0));
      const dv = vNew - el.v;
      this.node = { dv: _a.copy(v.v).normalize().multiplyScalar(dv).clone(), t: 0, label: 'Deorbit burn' };
    }
    return this.nodeGuidance(dt, pa, this.node);
  }
}

export function fmtDur(s) {
  if (!Number.isFinite(s)) return '—';
  const neg = s < 0; s = Math.abs(s);
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
        m = Math.floor(s % 3600 / 60), sec = Math.floor(s % 60);
  const out = d > 0 ? `${d}d ${h}h ${m}m` : h > 0 ? `${h}h ${m}m ${sec}s` : `${m}m ${sec}s`;
  return (neg ? '-' : '') + out;
}
