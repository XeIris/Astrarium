import * as THREE from 'three';
import {
  G0, C_MS, AU_M, GM_SUN, density, pressure, speedOfSound, scaleHeight,
  dragCoefficient, bluntDragCoefficient, heatFlux, engineOutput, flightEnv,
} from './rocketry.js';
import { elements, propagate, sphereOfInfluence } from './orbit.js';

// ============================================================================
// THE VESSEL
// ----------------------------------------------------------------------------
// State, forces, staging, structure and clocks. Everything in SI, in a frame
// centred on the vessel's parent body whose axes are parallel to the orrery's.
//
// THE FRAME IS NOT INERTIAL — it accelerates with the parent — and that is
// deliberate, because it is the only frame in which a rocket's numbers stay in
// a float's comfortable range. The price is one extra term in the gravity, and
// it is the term that carries all the interesting physics anyway:
//
//     a = Σᵢ GMᵢ (Rᵢ − R_v)/|Rᵢ − R_v|³  −  Σᵢ≠p GMᵢ (Rᵢ − R_p)/|Rᵢ − R_p|³
//
// The first sum is the pull of every body on the vessel; the second is the pull
// of every body EXCEPT the parent on the frame origin. Subtracting them leaves
// the parent's own gravity intact and reduces every other body's contribution to
// a tidal difference — which is why a vessel in LEO does not get dragged out of
// orbit by the Sun's 6e-3 m/s², and why it nevertheless feels the Moon.
//
// ATTITUDE. Body +Y is the thrust axis, so the nose direction is q·(0,1,0) and
// craftmodel.js stacks its meshes along +Y to match. The controller is the
// time-optimal rest-to-rest slew — ω_des = sign(e)·min(k|e|, √(2α|e|)) — rather
// than a plain proportional law, because a proportional law commands a rate the
// vehicle cannot stop from and overshoots every large slew. The available α is
// computed from the real gimbal deflection and the real RCS authority, so a
// stage with its engines off genuinely cannot pitch on gimbal alone.
// ============================================================================

export const PHASE = {
  PRELAUNCH: 'prelaunch', ASCENT: 'ascent', COAST: 'coast', ORBIT: 'orbit',
  BURN: 'burn', ENTRY: 'entry', DESCENT: 'descent', LANDED: 'landed',
  CRUISE: 'cruise', DESTROYED: 'destroyed',
};

const _a = new THREE.Vector3(), _b = new THREE.Vector3(), _c = new THREE.Vector3();
const _d = new THREE.Vector3(), _e = new THREE.Vector3(), _f = new THREE.Vector3();
const _up = new THREE.Vector3(), _vrel = new THREE.Vector3();
const _g1 = new THREE.Vector3(), _g2 = new THREE.Vector3();
const BODY_FWD = new THREE.Vector3(0, 1, 0);

let nextVesselId = 1;

export class Vessel {
  constructor({ vehicle, name, parent, bodies, payload = 0 }) {
    this.id = nextVesselId++;
    this.vehicle = vehicle;
    this.name = name || vehicle.name;
    this.payloadMass = payload;

    // ---- stage state. A stage is `pending` until its ignition event, `live`
    // while it is attached, and gone once jettisoned. Propellant is tracked per
    // stage because that is what staging actually throws away.
    this.stages = vehicle.stages.map((s, i) => ({
      spec: s, index: i,
      prop: s.prop, prop0: s.prop,
      ignited: i === 0 || !!s.liftoff,
      attached: true, spent: s.prop <= 0 && !s.engine,
      restarts: s.restarts ?? 0,
      rcsProp: s.rcs ? s.rcs.prop : 0,
      // How many of this stage's engines are running. Shutting engines down is
      // the only throttle a non-throttleable engine has, and it is what the
      // Saturn V actually did: the centre F-1 was cut at T+135 s to hold the
      // crew under 4 g, and the centre J-2 at T+460 s for the same reason.
      live: s.count,
    }));
    this.stageIndex = 0;                   // the lowest still-attached stage

    // ---- kinematics (SI, parent-centred)
    this.r = new THREE.Vector3();
    this.v = new THREE.Vector3();
    this.q = new THREE.Quaternion();
    this.omega = new THREE.Vector3();      // body rates, world axes, rad/s
    this.throttle = 0;
    this.rcsOn = true;

    // ---- clocks. `met` is the vessel's own PROPER time and `coord` is the
    // coordinate time the rest of the sim runs on; `clockDelta` is the
    // accumulated difference against a clock sitting on the parent's surface at
    // the launch site. In LEO that is tens of microseconds a day (GPS's famous
    // +38.7 µs); at 0.99c it is years. Same expression.
    this.met = 0; this.coord = 0; this.clockDelta = 0;

    // ---- telemetry / records
    this.maxQ = 0; this.maxG = 0; this.heatLoad = 0; this.peakHeat = 0;
    this.downrange = 0; this.phase = PHASE.PRELAUNCH;
    this.failure = null; this.events = [];
    this.stageEvents = 0;
    this.landedAt = null;

    this.setParent(parent, bodies);
    this.telemetry = {};
  }

  // -------------------------------------------------------------------------
  // Parent / frame
  // -------------------------------------------------------------------------
  setParent(body, bodies) {
    this.parent = body;
    this.env = body ? flightEnv(body) : null;
    this.bodies = bodies || [];
  }

  /** Place the vessel on the launch pad: on the surface, turning with it. */
  placeOnPad(latDeg = 28.5, lonDeg = 0) {
    const env = this.env;
    const lat = latDeg * Math.PI / 180, lon = lonDeg * Math.PI / 180;
    // The pole is −Y (see orbit.js), so "north" is −Y and the equator is the XZ
    // plane — the same plane the orrery lays its orbits in.
    const cl = Math.cos(lat);
    this.r.set(env.radius * cl * Math.cos(lon), -env.radius * Math.sin(lat), env.radius * cl * Math.sin(lon));
    // Surface velocity from the parent's rotation: ω × r, with ω along −Y so an
    // eastward launch gains it. 465 m/s at Earth's equator, and the reason a pad
    // near the equator is worth building.
    _a.set(0, -env.rotRate, 0).cross(this.r);
    this.v.copy(_a);
    // Nose up.
    _up.copy(this.r).normalize();
    this.q.setFromUnitVectors(BODY_FWD, _up);
    this.omega.set(0, 0, 0);
    this.phase = PHASE.PRELAUNCH;
    this.heldDown = false;
    this.launchSite = { lat, lon, r: this.r.clone(), v: this.v.clone() };
    return this;
  }

  /** Place the vessel on a circular orbit of altitude `altM`. */
  placeInOrbit(altM, incDeg = 0, phaseRad = 0) {
    const R = this.env.radius + altM;
    const inc = incDeg * Math.PI / 180;
    const vc = Math.sqrt(this.env.mu / R);
    this.r.set(R * Math.cos(phaseRad), 0, R * Math.sin(phaseRad));
    this.v.set(-vc * Math.sin(phaseRad) * Math.cos(inc), vc * Math.sin(inc), vc * Math.cos(phaseRad) * Math.cos(inc));
    this.q.setFromUnitVectors(BODY_FWD, _a.copy(this.v).normalize());
    this.omega.set(0, 0, 0);
    this.phase = PHASE.ORBIT;
    return this;
  }

  // -------------------------------------------------------------------------
  // Mass properties
  // -------------------------------------------------------------------------
  get mass() {
    let m = this.payloadMass;
    for (const st of this.stages) if (st.attached) m += st.spec.dry + st.prop + st.rcsProp;
    return m;
  }
  /** Length of what is still attached — used for the moment of inertia and for
   *  where the plume comes out. */
  get length() {
    let L = 0;
    for (const st of this.stages) if (st.attached) L += st.spec.L;
    return L;
  }
  get diameter() {
    let D = 0;
    for (const st of this.stages) if (st.attached) D = Math.max(D, st.spec.D);
    return D;
  }
  /** Frontal reference area: the widest live stage. A fairing is wider than the
   *  rocket under it, which is why jettisoning it is worth Δv. */
  get area() {
    let A = 0;
    for (const st of this.stages) if (st.attached) A = Math.max(A, st.spec.area);
    return A;
  }
  /** Transverse and roll moments of inertia, treating the live stack as a
   *  uniform slender cylinder. Crude for a Shuttle, right for everything else,
   *  and what matters is the ORDER: a 110 m Saturn V has 300× the pitch inertia
   *  of a lunar module and turns like it. */
  inertia() {
    const m = this.mass, L = Math.max(this.length, 0.5), R = Math.max(this.diameter / 2, 0.25);
    return { pitch: m * (L * L / 12 + R * R / 4), roll: m * R * R / 2 };
  }

  // -------------------------------------------------------------------------
  // Propulsion
  // -------------------------------------------------------------------------
  liveStages() { return this.stages.filter(s => s.attached && s.ignited && !s.spent); }

  /** Total thrust (N) and flow (kg/s) right now, at ambient pressure `pa`. */
  propulsion(pa) {
    let F = 0, mdot = 0, ispSum = 0, w = 0, plume = null, count = 0;
    for (const st of this.liveStages()) {
      const s = st.spec;
      if (!s.engine || st.prop <= 0) continue;
      const burned = 1 - st.prop / Math.max(st.prop0, 1);
      const o = engineOutput(s.engine, st.live, pa, this.throttle, burned);
      if (s.vacEngine) {
        const ov = engineOutput(s.vacEngine, s.vacCount, pa, this.throttle, burned);
        o.F += ov.F; o.mdot += ov.mdot;
      }
      F += o.F; mdot += o.mdot; ispSum += o.isp * o.F; w += o.F;
      count += st.live + (s.vacCount || 0);
      if (!plume) plume = s.engine.plume;
    }
    return { F, mdot, isp: w > 0 ? ispSum / w : 0, plume, count };
  }

  /** The thrust axis in world coordinates. */
  forward(out = _a) { return out.copy(BODY_FWD).applyQuaternion(this.q); }

  // -------------------------------------------------------------------------
  // Forces
  // -------------------------------------------------------------------------

  /** Gravity in the parent-centred non-inertial frame. See the module header. */
  gravity(r, out) {
    out.set(0, 0, 0);
    const p = this.parent;
    if (!p) return out;
    for (const b of this.bodies) {
      if (!b.alive) continue;
      const gm = GM_SUN * b.mass;
      // offset of body b from the parent, in metres. PRIVATE scratch: callers
      // routinely pass one of the shared temporaries as `out`, and reusing one
      // here would have this function overwrite its own accumulator.
      _g1.subVectors(b.pos, p.pos).multiplyScalar(AU_M);
      // pull on the vessel
      _g2.copy(_g1).sub(r);
      const d2 = _g2.lengthSq();
      if (d2 > 1e-6) out.addScaledVector(_g2, gm / (d2 * Math.sqrt(d2)));
      // pull on the frame origin — every body except the parent itself
      if (b === p) continue;
      const D2 = _g1.lengthSq();
      if (D2 > 1e-6) out.addScaledVector(_g1, -gm / (D2 * Math.sqrt(D2)));
    }
    return out;
  }

  /** Altitude above the parent's mean surface, in metres. */
  altitude(r = this.r) { return r.length() - this.env.radius; }

  /** Velocity relative to the rotating atmosphere. This is what drag, Mach and
   *  heating all use — an equatorial launch site is already doing 465 m/s
   *  through space and 0 m/s through the air. */
  airspeed(r, v, out) {
    _d.set(0, -this.env.rotRate, 0).cross(r);
    return out.subVectors(v, _d);
  }

  /**
   * Total acceleration at a trial state. Called four times per RK4 step, so it
   * writes into scratch and allocates nothing.
   */
  accel(r, v, out, sample) {
    this.gravity(r, out);
    const env = this.env, atm = env.atm;
    const h = this.altitude(r);
    const pa = atm ? pressure(atm, h) : 0;

    // ---- thrust
    const prop = this.propulsion(pa);
    const m = Math.max(this.mass, 1);
    if (prop.F > 0) out.addScaledVector(this.forward(_e), prop.F / m);

    // ---- aerodynamics
    let q = 0, mach = 0, drag = 0, heat = 0;
    if (atm && h < atm.top) {
      const rho = density(atm, h);
      this.airspeed(r, v, _vrel);
      const va = _vrel.length();
      if (rho > 0 && va > 0.5) {
        q = 0.5 * rho * va * va;
        mach = va / speedOfSound(atm, h);
        const st = this.stages.find(s => s.attached);
        const cd = (st && st.spec.blunt) ? bluntDragCoefficient(mach) : dragCoefficient(mach);
        // Angle of attack costs drag. cos²α is the standard slender-body form,
        // and it is why flying off-prograde in thick air is expensive.
        const fwd = this.forward(_f);
        const cosA = Math.abs(fwd.dot(_vrel) / va);
        const cdEff = cd * (1 + 2.2 * (1 - cosA * cosA));
        drag = q * cdEff * this.area;
        out.addScaledVector(_vrel, -drag / (m * va));
        // Parachutes, if any are out.
        if (this.chuteOpen) {
          const ch = this.chuteOpen;
          out.addScaledVector(_vrel, -(q * ch.Cd * ch.area * this.chuteDeploy) / (m * va));
          drag += q * ch.Cd * ch.area * this.chuteDeploy;
        }
        // BLUNT-BODY LIFT. A Mars aeroshell is not a ballistic capsule: an
        // offset centre of mass makes it fly at a trim angle of attack with a
        // lift-to-drag ratio of about 0.24, and it banks that lift vector to
        // steer. Flown lift-up it stretches the trajectory by tens of
        // kilometres, which is the difference between deploying the parachute
        // at Mach 1.7 with 11 km to spare and arriving supersonic at the ground.
        const bl = this.stages.find(s => s.attached && s.spec.lift);
        if (bl && drag > 0) {
          _c.copy(r).normalize();                     // local up
          _c.addScaledVector(_vrel, -_c.dot(_vrel) / (va * va));
          if (_c.lengthSq() > 1e-12) {
            // Banked lift. An entry vehicle rolls its lift vector to control
            // range: straight up stretches the trajectory the most and skips if
            // overdone, so a guided entry flies a partial bank. 60° puts half
            // the lift into the vertical, which is where MSL's range control
            // lived.
            const bank = this.bank ?? (Math.PI / 3);
            out.addScaledVector(_c.normalize(),
              (drag * bl.spec.lift.LD * Math.cos(bank)) / m);
          }
        }
        // Lift, for anything with a wing or a body flap. Perpendicular to the
        // airstream, in the plane containing the body axis — this is what lets
        // the Shuttle fly a hypersonic bank and Starship belly-flop.
        const wing = this.liveStages().find(s => s.spec.wings || s.spec.flaps);
        if (wing && cosA < 0.999) {
          const alpha = Math.acos(THREE.MathUtils.clamp(cosA, -1, 1));
          const clMax = wing.spec.wings ? wing.spec.wings.clMax : 1.1;
          const areaW = wing.spec.wings ? wing.spec.wings.area : this.area * 2.2;
          // Thin-aerofoil-ish: linear to the stall angle, then flat.
          const cl = clMax * Math.sin(2 * Math.min(alpha, 0.6));
          const L = q * cl * areaW;
          // lift direction = component of the body axis perpendicular to v
          _c.copy(fwd).addScaledVector(_vrel, -fwd.dot(_vrel) / (va * va));
          if (_c.lengthSq() > 1e-12) out.addScaledVector(_c.normalize(), L / m);
        }
        const noseR = this.stages.find(s => s.attached)?.spec.heatShield?.noseR ?? this.diameter * 0.25;
        heat = heatFlux(rho, va, noseR);
      }
    }
    if (sample) { sample.q = q; sample.mach = mach; sample.drag = drag; sample.heat = heat; sample.pa = pa; sample.thrust = prop.F; sample.mdot = prop.mdot; sample.isp = prop.isp; sample.plume = prop.plume; sample.engines = prop.count; }
    return out;
  }

  // -------------------------------------------------------------------------
  // Attitude
  // -------------------------------------------------------------------------

  /** Angular acceleration the vehicle can actually produce, rad/s², about a
   *  transverse axis. Gimbal only works while the engines are lit. */
  authority(pa) {
    const I = this.inertia();
    const L = Math.max(this.length, 1);
    let tau = 0;
    for (const st of this.liveStages()) {
      const s = st.spec;
      if (s.engine && st.prop > 0 && this.throttle > 0 && s.gimbalDeg > 0) {
        const o = engineOutput(s.engine, st.live, pa, this.throttle);
        // The gimbal acts at the engine plane, roughly a half-length from the
        // centre of mass.
        tau += o.F * Math.sin(s.gimbalDeg * Math.PI / 180) * (L * 0.45);
      }
      if (this.rcsOn && s.rcs && st.rcsProp > 0) {
        // A quarter of the thrusters bear on any one axis, at a lever arm of
        // roughly the radius plus a fraction of the length.
        tau += s.rcs.thrust * Math.max(s.rcs.count / 4, 1) * (this.diameter * 0.5 + L * 0.25);
      }
    }
    return { alpha: tau / Math.max(I.pitch, 1), tau, I };
  }

  /**
   * Steer toward a world-space direction for the +Y axis.
   *
   * The commanded rate is the TIME-OPTIMAL rest-to-rest profile: accelerate at
   * α, then decelerate at α, which means never asking for a rate you cannot
   * stop from inside the remaining error. A plain proportional law overshoots
   * every large slew and then hunts, which is the exact complaint Orbiter's PID
   * autopilot exists to fix.
   */
  pointAt(dir, dt, pa, rollRef) {
    if (!dir || dir.lengthSq() < 1e-12) return 0;
    _a.copy(dir).normalize();
    const fwd = this.forward(_b);
    const err = fwd.angleTo(_a);
    const { alpha } = this.authority(pa);
    if (alpha <= 0) return err;
    // rotation axis
    _c.crossVectors(fwd, _a);
    if (_c.lengthSq() < 1e-14) {
      // exactly 180° out — any perpendicular axis will do
      _c.set(fwd.y, -fwd.x, 0);
      if (_c.lengthSq() < 1e-14) _c.set(0, fwd.z, -fwd.y);
    }
    _c.normalize();
    // Deadband. Below it the vehicle is pointed and the only job left is to
    // stop turning — without this the controller chatters across the target and
    // anything gated on the pointing error flickers with it.
    if (err < 0.004) {
      const w = this.omega.length();
      if (w > 1e-6) this.omega.multiplyScalar(Math.max(0, 1 - Math.min(alpha * dt / w, 1)));
      return err;
    }
    const wMax = Math.min(Math.sqrt(2 * alpha * err), 0.35);   // rad/s cap: real vehicles are slow
    // current rate about the error axis
    const wNow = this.omega.dot(_c);
    // Command the profile rate; the residual is corrected by the same law next
    // step, which is what makes it settle instead of ringing.
    const dw = THREE.MathUtils.clamp(wMax - wNow, -alpha * dt, alpha * dt);
    this.omega.addScaledVector(_c, dw);
    // Damp any rate that is not about the error axis — this is the RCS holding
    // attitude, and it is why a spacecraft does not tumble after a slew.
    _d.copy(this.omega).addScaledVector(_c, -this.omega.dot(_c));
    const damp = Math.min(alpha * dt, _d.length());
    if (_d.lengthSq() > 1e-16) this.omega.addScaledVector(_d.normalize(), -damp);
    // RCS costs propellant. Gimbal does not (it is already burning).
    this.spendRCS(Math.abs(dw) * this.inertia().pitch, dt);
    return err;
  }

  /** Integrate the attitude by the current body rates. */
  spin(dt) {
    const w = this.omega.length();
    if (w < 1e-9) return;
    _a.copy(this.omega).multiplyScalar(1 / w);
    _dq.setFromAxisAngle(_a, w * dt);
    this.q.premultiply(_dq).normalize();
  }

  /** Book an RCS impulse against the tanks. Torque impulse → propellant. */
  spendRCS(angularImpulse, dt) {
    for (const st of this.liveStages()) {
      const rcs = st.spec.rcs;
      if (!rcs || st.rcsProp <= 0) continue;
      const arm = this.diameter * 0.5 + this.length * 0.25;
      const mdot = angularImpulse / Math.max(arm * G0 * rcs.isp, 1e-6);
      st.rcsProp = Math.max(0, st.rcsProp - mdot);
      return;
    }
  }

  // -------------------------------------------------------------------------
  // Staging
  // -------------------------------------------------------------------------

  /**
   * Fire the next staging event.
   *
   * A staging event is two things at once and they have to happen in this
   * order: drop the lowest attached stage that has nothing left to give, then
   * light the lowest stage that has not been lit. Doing it the other way round
   * ignites an upper stage inside the interstage it is still attached to.
   *
   * `sep: 'none'` marks a stage that is never thrown away — a capsule, an
   * orbiter, the Hail Mary itself — so it is skipped by the jettison pass but
   * still eligible for ignition.
   */
  stage() {
    let dropped = null;
    for (const st of this.stages) {
      if (!st.attached) continue;
      const done = !st.spec.engine || st.prop <= 1e-6;
      // The lowest attached stage still has propellant and is lit: nothing at
      // the bottom is finished, so this event only ignites.
      if (!done && st.ignited) break;
      if (st.spec.sep === 'none') break;
      st.attached = false; st.spent = true;
      dropped = st; this.stageEvents++;
      this.log(st.spec.sep === 'fairing'
        ? `Fairing separation — ${st.spec.name} away`
        : `Staging — ${st.spec.name} away`);
      break;
    }
    for (const st of this.stages) {
      if (!st.attached || st.ignited || !st.spec.engine) continue;
      st.ignited = true;
      this.log(`Ignition — ${st.spec.name}`);
      break;
    }
    this.stageIndex = this.stages.findIndex(s => s.attached);
    return dropped;
  }

  /**
   * Shut down `n` engines on the burning stage. Symmetric shutdown only: with a
   * centre engine it goes first (a Saturn V or a Falcon 9 shuts the centre), and
   * after that they come off in pairs, because an asymmetric thrust pattern the
   * gimbal cannot trim is how you lose the vehicle.
   */
  shutdownEngines(n = 1) {
    const st = this.currentStage;
    if (!st || st.live <= 1) return 0;
    const off = Math.min(n, st.live - 1);
    st.live -= off;
    this.log(`Engine shutdown — ${off} of ${st.spec.count} on ${st.spec.name} (${st.live} running)`);
    return off;
  }

  /**
   * Ask for a specific number of engines on the burning stage. Real vehicles
   * choose their engine count per phase rather than throttling nine engines to
   * their floor and hoping — a Falcon 9 lights three for the entry burn and one
   * for the landing — and shutdown has to be reversible for that to be possible.
   */
  setEngineCount(n) {
    const st = this.currentStage;
    if (!st || !st.spec.count) return 0;
    const want = Math.max(1, Math.min(n | 0, st.spec.count));
    if (want === st.live) return st.live;
    this.log(want > st.live
      ? `Engine relight — ${want} of ${st.spec.count} on ${st.spec.name}`
      : `Engine shutdown — ${st.live - want} of ${st.spec.count} on ${st.spec.name} (${want} running)`);
    st.live = want;
    return st.live;
  }

  /** Drop a specific stage by key — used by the scripted sequences (heat-shield
   *  jettison, backshell separation, sky-crane release). */
  jettison(key) {
    const st = this.stages.find(s => s.spec.key === key && s.attached);
    if (!st) return null;
    st.attached = false; st.spent = true; this.stageEvents++;
    this.log(`Separation — ${st.spec.name}`);
    return st;
  }

  get currentStage() { return this.stages.find(s => s.attached && s.ignited && !s.spent) || null; }
  get nextStage() { return this.stages.find(s => s.attached && !s.ignited && s.spec.engine) || null; }

  /** Δv remaining in everything still attached, from the rocket equation. */
  deltaVRemaining(pa = 0) {
    let dv = 0;
    // Walk from the top down so each stage's payload is what is above it.
    let above = this.payloadMass;
    const live = this.stages.filter(s => s.attached);
    for (let i = live.length - 1; i >= 0; i--) {
      const st = live[i];
      above += st.spec.dry + st.rcsProp;
      if (st.spec.engine && st.prop > 0) {
        const ve = G0 * (pa > 0 ? st.spec.engine.ispSL : st.spec.engine.ispVac);
        dv += ve * Math.log((above + st.prop) / above);
      }
      above += st.prop;
    }
    return dv;
  }

  // -------------------------------------------------------------------------
  // Structure
  // -------------------------------------------------------------------------
  /**
   * Four independent ways to lose a vehicle, each against a real limit. A
   * verdict here is an EVENT — the vessel is destroyed and the sim says which
   * of the four did it — not a warning light.
   */
  checkStructure(s, dt) {
    const lim = this.vehicle.limits;
    if (this.phase === PHASE.DESTROYED) return;
    if (s.q > lim.maxQ) return this.destroy(`aerodynamic breakup — ${(s.q / 1000).toFixed(1)} kPa exceeded the ${(lim.maxQ / 1000).toFixed(0)} kPa airframe limit`);
    if (s.gees > lim.maxG) return this.destroy(`structural failure — ${s.gees.toFixed(1)} g exceeded the ${lim.maxG} g limit`);
    if (s.q * s.alpha > lim.qAlpha) return this.destroy(`loss of control — q·α of ${(s.q * s.alpha / 1000).toFixed(1)} kPa·rad exceeded ${(lim.qAlpha / 1000).toFixed(0)}`);
    if (lim.heatLoad > 0 && this.heatLoad > lim.heatLoad) return this.destroy(`thermal failure — ${(this.heatLoad / 1e6).toFixed(0)} MJ/m² burned through the shield`);
    // No shield at all: bare aluminium structure fails somewhere around
    // 80 W/cm² of stagnation heating, which is why a stage that comes back
    // without one comes back as a debris field.
    if (lim.heatLoad === 0 && s.heat > 8e5) return this.destroy(`burned up on entry — ${(s.heat / 1e4).toFixed(0)} W/cm² on a vehicle with no heat shield`);
  }

  destroy(why) {
    if (this.phase === PHASE.DESTROYED) return;
    this.phase = PHASE.DESTROYED;
    this.failure = why;
    this.throttle = 0;
    this.log(`LOSS OF VEHICLE — ${why}`);
  }

  log(msg) {
    this.events.push({ t: this.met, msg });
    if (this.events.length > 120) this.events.shift();
  }

  // -------------------------------------------------------------------------
  // Clocks
  // -------------------------------------------------------------------------
  /**
   * Advance the proper-time clocks.
   *
   *   dτ/dt = √(1 − v²/c² − 2Φ/c²)
   *
   * with Φ the (negative) Newtonian potential summed over every body. The two
   * ends of this are twelve orders of magnitude apart, so the DIFFERENCE
   * against a ground clock is accumulated through
   *
   *   √A − √B = (A − B)/(√A + √B)
   *
   * which never subtracts two nearly-equal numbers. At LEO that recovers GPS's
   * +38.7 µs/day; at 0.99c it accumulates years — from one expression.
   */
  stepClocks(dt) {
    const c2 = C_MS * C_MS;
    // vessel: speed in the coordinate frame = parent's own speed + local v
    _a.copy(this.parent.vel).multiplyScalar(AU_M / 3.15576e7).add(this.v);
    const vShip2 = _a.lengthSq();
    const phiShip = this.potential(this.r);
    // ground reference: a clock on the parent's surface at the launch latitude
    const site = this.launchSite ? this.launchSite.r : _b.copy(this.r).setLength(this.env.radius);
    _c.copy(this.parent.vel).multiplyScalar(AU_M / 3.15576e7);
    _d.set(0, -this.env.rotRate, 0).cross(site);
    const vGnd2 = _c.add(_d).lengthSq();
    const phiGnd = this.potential(site);

    const A = Math.max(1 - vShip2 / c2 - 2 * phiShip / c2, 1e-12);
    const B = Math.max(1 - vGnd2 / c2 - 2 * phiGnd / c2, 1e-12);
    const rate = Math.sqrt(A);
    this.met += dt * rate;
    this.coord += dt;
    // (A − B) is formed from differences of the *terms*, never of the rates.
    const dA = (vGnd2 - vShip2) / c2 - 2 * (phiShip - phiGnd) / c2;
    this.clockDelta += dt * dA / (rate + Math.sqrt(B));
    this.timeRate = rate;
  }

  /** Newtonian potential (negative, J/kg) at a parent-frame position. */
  potential(r) {
    let phi = 0;
    _f.copy(r);
    for (const b of this.bodies) {
      if (!b.alive) continue;
      _e.subVectors(b.pos, this.parent.pos).multiplyScalar(AU_M).sub(_f);
      const d = Math.max(_e.length(), (b.radius || 1e-9) * AU_M * 0.5);
      phi -= GM_SUN * b.mass / d;
    }
    return phi;
  }

  // -------------------------------------------------------------------------
  // Stepping
  // -------------------------------------------------------------------------

  /**
   * Advance `dt` seconds. `mode` is 'integrate' or 'rails'.
   *
   * RAILS is only legal unpowered, out of the atmosphere and off the ground —
   * the same interlocks KSP uses, and for the same reason: on rails the thrust
   * and drag terms are not evaluated at all, so allowing it while either is
   * acting silently deletes them. Entering and leaving rails re-seeds from the
   * analytic state, so there is no boundary to cross badly.
   */
  step(dt, opts = {}) {
    if (this.phase === PHASE.DESTROYED) { this.coord += dt; return; }
    if (this.phase === PHASE.LANDED && this.throttle <= 0) {
      // Sit on the surface, turning with it, rather than integrating a
      // contact force that is exactly cancelling gravity.
      const w = -this.env.rotRate * dt;
      const cw = Math.cos(w), sw = Math.sin(w);
      const x = this.r.x, z = this.r.z;
      this.r.set(x * cw - z * sw, this.r.y, x * sw + z * cw);
      _a.set(0, -this.env.rotRate, 0).cross(this.r);
      this.v.copy(_a);
      this.stepClocks(dt);
      this.sample(0);
      return;
    }

    if (opts.rails && this.canRail()) {
      if (propagate(this.r, this.v, this.env.mu, dt, this.r, this.v)) {
        this.stepClocks(dt);
        this.sample(dt);
        this.checkSOI();
        return;
      }
    }

    // ---- RK4. The substep is bounded by how fast the state is changing: in
    // thick air with the engines lit that is a few hundredths of a second, in
    // orbit it can be tens. Choosing it from the acceleration rather than
    // fixing it is what lets one integrator cover both.
    let remaining = dt, guard = 0;
    const s = {};
    while (remaining > 1e-9 && guard++ < 400) {
      const h = Math.min(remaining, this.stepBound());
      this.rk4(h, s);
      remaining -= h;
    }
    this.stepClocks(dt);
    this.sample(dt, s);
    this.autoJettison();
    this.checkSOI();
    this.contact(dt);
  }

  /**
   * Conditional separations that are not staging events — the fairing, most
   * obviously. Its real criterion is not an altitude but a HEAT FLUX: the
   * fairing comes off once free-molecular heating on the bare payload drops
   * below about 1135 W/m², which is the number the industry quotes and which
   * happens somewhere around 110 km depending entirely on how the vehicle flew.
   * Keying it to the flux rather than to an altitude means a lofted trajectory
   * really does shed its fairing earlier.
   */
  autoJettison() {
    for (const st of this.stages) {
      const j = st.spec.jettisonAt;
      if (!j || !st.attached) continue;
      const t = this.telemetry;
      if (j.heat != null && t.heat != null && t.heat < j.heat && this.altitude() > 60000) {
        this.jettison(st.spec.key);
      } else if (j.alt != null && this.altitude() > j.alt) {
        this.jettison(st.spec.key);
      }
    }
  }

  /** Largest safe substep, seconds. */
  stepBound() {
    const alt = this.altitude();
    const atm = this.env.atm;
    // In the atmosphere the density scale height is what limits it: never move
    // more than a fraction of a scale height in one step, or the drag is
    // evaluated at an altitude the vehicle has already left.
    if (atm && alt < atm.top) {
      const H = scaleHeight(atm, Math.max(alt, 0));
      const v = Math.max(this.v.length(), 1);
      return THREE.MathUtils.clamp(0.02 * H / v, 0.004, 0.5);
    }
    if (this.throttle > 0) return 0.25;
    // Ballistic: a fraction of the local orbital period.
    const R = Math.max(this.r.length(), this.env.radius);
    const T = 2 * Math.PI * Math.sqrt(R * R * R / this.env.mu);
    return THREE.MathUtils.clamp(T / 900, 0.05, 60);
  }

  rk4(h, s) {
    const r0 = _k.r0.copy(this.r), v0 = _k.v0.copy(this.v);
    this.accel(r0, v0, _k.a1, s);
    _k.r1.copy(r0).addScaledVector(v0, h / 2);
    _k.v1.copy(v0).addScaledVector(_k.a1, h / 2);
    this.accel(_k.r1, _k.v1, _k.a2);
    _k.r2.copy(r0).addScaledVector(_k.v1, h / 2);
    _k.v2.copy(v0).addScaledVector(_k.a2, h / 2);
    this.accel(_k.r2, _k.v2, _k.a3);
    _k.r3.copy(r0).addScaledVector(_k.v2, h);
    _k.v3.copy(v0).addScaledVector(_k.a3, h);
    this.accel(_k.r3, _k.v3, _k.a4);

    this.r.addScaledVector(v0, h / 6).addScaledVector(_k.v1, h / 3)
          .addScaledVector(_k.v2, h / 3).addScaledVector(_k.v3, h / 6);
    this.v.addScaledVector(_k.a1, h / 6).addScaledVector(_k.a2, h / 3)
          .addScaledVector(_k.a3, h / 3).addScaledVector(_k.a4, h / 6);

    // Propellant is spent on the same step, from the flow the first evaluation
    // reported — the flow is constant at a given throttle, so this is exact
    // rather than a first-order approximation.
    if (s.mdot > 0) this.burn(s.mdot * h);
    this.spin(h);
    this.heatLoad += (s.heat || 0) * h;
    if (s.heat > this.peakHeat) this.peakHeat = s.heat;
  }

  /** Draw `kg` from the live stages, bottom first, and auto-stage when a stage
   *  runs dry if the flight plan says to. */
  burn(kg) {
    for (const st of this.liveStages()) {
      if (!st.spec.engine || st.prop <= 0) continue;
      const take = Math.min(st.prop, kg);
      st.prop -= take; kg -= take;
      if (st.prop <= 1e-6) {
        st.spent = true;
        this.log(`${st.spec.name} — cutoff (propellant depleted)`);
        if (this.autoStage) this.pendingStage = true;
      }
      if (kg <= 0) break;
    }
  }

  canRail() {
    if (this.throttle > 0) return false;
    if (this.phase === PHASE.LANDED || this.phase === PHASE.PRELAUNCH) return false;
    const atm = this.env.atm;
    if (atm && this.altitude() < atm.top) return false;
    if (this.chuteOpen) return false;
    return true;
  }

  /**
   * A body's own primary — the body it is gravitationally BOUND to.
   *
   * The obvious test, "whose pull is strongest here", is wrong, and famously so:
   * the Sun pulls the Moon about twice as hard as the Earth does. The Moon
   * orbits the Earth anyway, because what decides that is not the pull but the
   * TIDAL difference — whether the Moon sits inside the Earth's Hill sphere,
   *
   *     r_Hill = d·(m/3M)^⅓ ,
   *
   * which for the Earth is 1.5 million km against the Moon's 384 000. So the
   * primary is the smallest Hill sphere the body is inside; failing all of
   * them, the system's dominant mass.
   *
   * Getting this wrong is not cosmetic. It puts the Moon's sphere of influence
   * at 129 000 km instead of 66 000 with the Earth's *inside* it, so a vessel in
   * low lunar orbit is simultaneously inside both and the handover oscillates
   * every frame; and it plans a translunar injection as a heliocentric transfer
   * between two nearly identical orbits, costing twenty metres per second.
   */
  primaryOf(body) {
    const root = this.bodies.reduce((a, b) => (b.alive && b.mass > (a?.mass ?? -1) ? b : a), null);
    if (!root || root === body) return null;
    let best = null, bestHill = Infinity;
    for (const c of this.bodies) {
      if (c === body || c === root || !c.alive || c.mass <= body.mass) continue;
      const dRoot = c.pos.distanceTo(root.pos) * AU_M;
      if (!(dRoot > 0)) continue;
      const hill = dRoot * Math.cbrt(c.mass / (3 * root.mass));
      if (body.pos.distanceTo(c.pos) * AU_M < hill && hill < bestHill) {
        best = c; bestHill = hill;
      }
    }
    return best || root;
  }

  /** SOI radius of `body` about its own primary, in metres. */
  soiOf(body) {
    const p = this.primaryOf(body);
    if (!p) return Infinity;
    return sphereOfInfluence(body.pos.distanceTo(p.pos) * AU_M, body.mass, p.mass);
  }

  /**
   * Has the vessel left the parent's sphere of influence, or entered a smaller
   * one nested inside it? This is the patched-conic handover, and it is where
   * the HUD's numbers jump — because the conic they describe genuinely changed.
   *
   * Entering picks the SMALLEST enclosing SOI, so a vessel in low lunar orbit
   * is handed to the Moon and not to the Earth it is also technically inside.
   */
  checkSOI() {
    if (!this.bodies.length) return;
    const R = this.r.length();

    // entering: the deepest SOI that contains us and is not the parent's own
    let best = null, bestSoi = Infinity;
    for (const b of this.bodies) {
      if (b === this.parent || !b.alive) continue;
      const soi = this.soiOf(b);
      if (!Number.isFinite(soi)) continue;
      _a.subVectors(b.pos, this.parent.pos).multiplyScalar(AU_M);
      if (this.r.distanceTo(_a) < soi && soi < bestSoi) { best = b; bestSoi = soi; }
    }
    // leaving: outside the parent's own SOI
    const own = this.soiOf(this.parent);
    if (R > own) {
      const up = this.primaryOf(this.parent);
      // Only climb out if the parent we would climb to is not itself a smaller,
      // closer option — otherwise the two rules can hand the vessel back and
      // forth across the same boundary.
      if (up && !(best && bestSoi < own)) return this.rebase(up);
    }
    if (best && bestSoi < own) return this.rebase(best);
  }

  /** Move the vessel's frame to a new parent, preserving the absolute state.
   *  Position and velocity are both offset — forgetting the velocity offset is
   *  the classic patched-conic bug and it puts the vessel on a wildly wrong
   *  conic the instant it crosses a boundary. */
  rebase(body) {
    if (body === this.parent) return;
    _a.subVectors(this.parent.pos, body.pos).multiplyScalar(AU_M);
    _b.subVectors(this.parent.vel, body.vel).multiplyScalar(AU_M / 3.15576e7);
    this.r.add(_a); this.v.add(_b);
    const old = this.parent.name;
    this.setParent(body, this.bodies);
    this.log(`Sphere of influence — ${old} → ${body.name}`);
  }

  /** Ground contact. A landing is a landing if the legs are down and the
   *  vertical speed is inside what the gear can take; otherwise it is a crash,
   *  and the threshold is the real one (Apollo's gear was rated to 3 m/s). */
  contact(dt) {
    const alt = this.altitude();
    // Bolted to the mount. This has to come before the airborne branch: the
    // integrator moves the vehicle a few centimetres before contact() ever
    // runs, and an altitude test alone would call that liftoff on the first
    // step after ignition — which is precisely the moment the hold-downs exist
    // to bridge.
    if (this.phase === PHASE.PRELAUNCH && this.heldDown) {
      this.r.setLength(this.env.radius);
      _c.set(0, -this.env.rotRate, 0).cross(this.r);
      this.v.copy(_c);
      return;
    }
    if (alt > 0) {
      // Liftoff is detected here rather than in the pad branch below, because a
      // vehicle with a TWR of 1.4 is already off the ground by the end of its
      // first step and the pad branch never runs again.
      if (this.phase === PHASE.PRELAUNCH) {
        this.phase = PHASE.ASCENT; this.t0 = this.met; this.log('Liftoff');
      }
      return;
    }
    const up = _a.copy(this.r).normalize();
    this.airspeed(this.r, this.v, _vrel);
    const vVert = this.v.dot(up);
    if (this.phase === PHASE.PRELAUNCH) {
      // held down on the pad until thrust exceeds weight
      this.r.setLength(this.env.radius);
      const w = this.mass * this.env.gSurf;
      const s = {}; this.accel(this.r, this.v, _b, s);
      // Hold-downs. A launch vehicle is bolted to its mount and stays there
      // while the engines come up, so that a failure to reach thrust is a
      // scrubbed count rather than a vehicle that lifts a metre and falls back.
      // Releasing on thrust alone made ignition and liftoff the same instant,
      // which is the one moment of a launch that is worth watching happen.
      if (s.thrust > w && !this.heldDown) { this.phase = PHASE.ASCENT; this.log('Liftoff'); this.t0 = this.met; }
      else { _c.set(0, -this.env.rotRate, 0).cross(this.r); this.v.copy(_c); }
      return;
    }
    // Gear rating is a property of the GEAR, not a global constant. Apollo's
    // legs were qualified to 3 m/s of vertical touchdown; a Falcon 9's are
    // built for about twice that because a hoverslam has no margin to spare.
    const geared = this.stages.find(s => s.attached && s.spec.legs);
    const legs = !!geared;
    const rate = geared?.spec.gear ?? { vVert: 3.0, vHoriz: 1.2 };
    // Lateral speed is measured against the GROUND, not against the stars. A
    // landing gear is dragged sideways by how fast the pad is moving under it,
    // and at Mars's equator that is 240 m/s of difference between the two.
    const vHoriz = _b.copy(_vrel).addScaledVector(up, -_vrel.dot(up)).length();
    const limitV = legs ? rate.vVert : 1.0;
    const limitH = legs ? rate.vHoriz : 0.5;
    if (vVert < -limitV || vHoriz > limitH * 3) {
      return this.destroy(`impact at ${Math.abs(vVert).toFixed(1)} m/s vertical, ${vHoriz.toFixed(1)} m/s lateral — gear rated to ${limitV} m/s`);
    }
    this.r.setLength(this.env.radius);
    _c.set(0, -this.env.rotRate, 0).cross(this.r);
    this.v.copy(_c);
    this.omega.set(0, 0, 0);
    if (this.phase !== PHASE.LANDED) {
      this.phase = PHASE.LANDED;
      this.landedAt = { met: this.met, vVert, vHoriz };
      this.log(`Touchdown — ${Math.abs(vVert).toFixed(2)} m/s vertical, ${vHoriz.toFixed(2)} m/s lateral`);
    }
  }

  // -------------------------------------------------------------------------
  // Telemetry
  // -------------------------------------------------------------------------
  sample(dt, s) {
    const env = this.env;
    if (!s) { s = {}; this.accel(this.r, this.v, _b, s); }
    const m = Math.max(this.mass, 1);
    const alt = this.altitude();
    this.airspeed(this.r, this.v, _vrel);
    // g-load is what an accelerometer reads: every force EXCEPT gravity, which
    // is why a coasting vessel reads zero however hard it is falling.
    const aNet = Math.abs((s.thrust || 0) - (s.drag || 0)) / m;
    const fwd = this.forward(_e);
    const va = _vrel.length();
    // Angle of attack is how far the airstream is OFF THE AXIS, which is what
    // the q·α structural limit is about — not which end is forward. Every entry
    // vehicle ever flown flies backwards on purpose: an Apollo command module,
    // a Mars aeroshell and a returning booster all put their axis along the
    // airstream and their heat shield into it. Measured signed, all three read
    // α = 180° and tear themselves apart the instant they enter the atmosphere.
    const alpha = va > 1 ? Math.acos(THREE.MathUtils.clamp(Math.abs(fwd.dot(_vrel)) / va, 0, 1)) : 0;
    const el = elements(this.r, this.v, env.mu);
    if (s.q > this.maxQ) this.maxQ = s.q;
    if (aNet / G0 > this.maxG) this.maxG = aNet / G0;
    if (this.launchSite) {
      // great-circle distance from the pad, along the surface
      const ang = this.launchSite.r.angleTo(this.r);
      this.downrange = ang * env.radius;
    }
    const t = this.telemetry;
    t.alt = alt; t.altKm = alt / 1000;
    t.speed = this.v.length(); t.airspeed = va;
    t.vertical = this.v.dot(_a.copy(this.r).normalize());
    t.horizontal = Math.sqrt(Math.max(t.speed * t.speed - t.vertical * t.vertical, 0));
    t.q = s.q || 0; t.mach = s.mach || 0; t.drag = s.drag || 0; t.heat = s.heat || 0;
    t.thrust = s.thrust || 0; t.isp = s.isp || 0; t.mdot = s.mdot || 0;
    t.plume = s.plume; t.engines = s.engines || 0;
    t.mass = m; t.gees = aNet / G0; t.alpha = alpha;
    t.twr = (s.thrust || 0) / (m * env.mu / (this.r.lengthSq() || 1));
    t.el = el;
    t.apo = el.ra - env.radius; t.peri = el.rp - env.radius;
    t.period = el.period; t.ecc = el.e; t.inc = el.inc * 180 / Math.PI;
    t.pressure = s.pa || 0;
    t.dv = this.deltaVRemaining(s.pa || 0);
    t.downrange = this.downrange;
    t.gSurf = env.mu / (this.r.lengthSq() || 1);
    // The gate the structure checks are made against.
    s.gees = t.gees; s.alpha = alpha;
    if (dt > 0) this.checkStructure(s, dt);
    if (this.pendingStage) { this.pendingStage = false; this.stage(); }
    return t;
  }
}

// RK4 scratch. One set for the whole module: only one vessel integrates at a
// time and the alternative is four Vector3 allocations per substep per frame.
const _dq = new THREE.Quaternion();
const _k = {
  r0: new THREE.Vector3(), v0: new THREE.Vector3(),
  r1: new THREE.Vector3(), v1: new THREE.Vector3(),
  r2: new THREE.Vector3(), v2: new THREE.Vector3(),
  r3: new THREE.Vector3(), v3: new THREE.Vector3(),
  a1: new THREE.Vector3(), a2: new THREE.Vector3(),
  a3: new THREE.Vector3(), a4: new THREE.Vector3(),
};
