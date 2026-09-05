import * as THREE from 'three';
import { Vessel, PHASE } from './vessel.js';
import { Autopilot, MODE, attitudeFor, targetOffset, fmtDur } from './guidance.js';
import { VEHICLES, VEHICLE_ORDER, grossMass, totalDeltaV, padTWR, liftoffThrust } from './vehicles.js';
import { AU_M, YR_S, G0, pressure, density, flightEnv } from './rocketry.js';
import { buildCraft } from './craftmodel.js';
import { createPlume, createRCSPuffs, createEntryGlow, createSmokeColumn, PROPELLANT } from './plume.js';
import { createLocalView, createFlightCamera } from './localview.js';
import { createLaunchSite } from './launchsite.js';
import { createFlightHUD, planHTML, cruiseHTML, fmtDist, fmtSpeed } from './flightui.js';
import { Cruise, rapidityBudget, solveProfile, skyBoost, LY_AU, LY_M } from './relativity.js';
import { elements } from './orbit.js';

// ============================================================================
// SPACEFLIGHT — the integration layer
// ----------------------------------------------------------------------------
// This is the only file in sim/flight/ that knows about the orrery. Everything
// under it is pure: given a vehicle, a body and a state it produces numbers, and
// none of it imports blackhole_sim.js or reaches for a global.
//
// THE TWO CLOCKS PROBLEM, and how it is resolved. The orrery runs on
// simulated YEARS per real second (0.35 by default — a day and a half a second)
// and a rocket runs on seconds. Rather than let two clocks drift, entering
// flight takes over `state.timeScale` and drives it from the flight warp:
//
//     state.timeScale = warp / YR_S       (years per second)
//
// so at 1× the planets advance one second per second, at 10⁵× they advance a
// day per second, and there is only ever ONE clock moving the world.
//
// THE TWO SPACES PROBLEM. See sim/flight/localview.js — the vehicle is drawn in
// its own metre-scale pass and composited over the orrery's frame.
// ============================================================================

const WARPS = [1, 2, 5, 10, 50, 100, 1000, 10000, 100000, 1000000];

export function createSpaceflight(ctx) {
  const { renderer, scene, camera, state, mount, panel, onExit, toast } = ctx;

  const local = createLocalView();
  const flyCam = createFlightCamera();
  const smoke = createSmokeColumn();
  local.scene.add(smoke.group);
  const rcsPuffs = createRCSPuffs();
  local.craftRoot.add(rcsPuffs.group);

  let vessel = null, ap = null, craft = null, plumes = [], entry = null, cruise = null;
  let site = null, sitePos = null;   // the launch complex, and where it is (parent frame, m)
  // The terminal count. A launch has a beginning, and without one the vehicle
  // simply is not on the pad and then is, which is most of why an ascent that
  // runs in real time can still read as instantaneous.
  let count = null;
  let warpIdx = 0, active = false, hud = null;
  let target = null, plan = null;
  const boost = new THREE.Vector3();

  const _up = new THREE.Vector3(), _north = new THREE.Vector3(), _sun = new THREE.Vector3();
  const _a = new THREE.Vector3(), _b = new THREE.Vector3(), _q = new THREE.Quaternion();
  const _east = new THREE.Vector3(), _padAnchor = new THREE.Vector3();
  const padOffset = new THREE.Vector3();
  let padAimed = false;

  // -------------------------------------------------------------------------
  function bodies() { return state.bodies.filter(b => b.alive); }
  function bodyNamed(n) { return bodies().find(b => b.name === n); }
  function dominant() { return bodies().reduce((a, b) => (b.mass > (a?.mass ?? -1) ? b : a), null); }

  /**
   * The longitude on `body` where it is mid-morning — 35° of rotation before
   * the sub-solar point. The body turns toward increasing longitude (its spin
   * is along −Y, matching the orrery's orbital sense), so earlier in the day is
   * a smaller longitude.
   */
  function morningLongitude(body) {
    const stars = bodies().filter(b => b.type === 'star' || b.type === 'white-dwarf');
    const src = stars.reduce((a, b) => (b.mass > (a?.mass ?? -1) ? b : a), null);
    if (!src || src === body) return 0;
    _a.subVectors(src.pos, body.pos).normalize();
    const sub = Math.atan2(_a.z, _a.x) * 180 / Math.PI;
    // 22° west of the subsolar point. At a 28.5° pad that puts the sun 55° up —
    // mid-morning, the light every launch is photographed in, and high enough
    // that the vehicle is lit rather than silhouetted. (35° put it at 46° and
    // the whole complex read as dusk.)
    return sub - 22;
  }

  /** The brightest star's direction from the vessel, for lighting the model. */
  function sunDirection(out) {
    const stars = bodies().filter(b => b.type === 'star' || b.type === 'white-dwarf');
    const src = stars[0] || dominant();
    if (!src || !vessel) return out.set(0, 1, 0);
    out.subVectors(src.pos, vessel.parent.pos).multiplyScalar(AU_M).sub(vessel.r);
    return out.normalize();
  }

  // -------------------------------------------------------------------------
  // LAUNCH / SPAWN
  // -------------------------------------------------------------------------
  function begin(vehicleKey, opts = {}) {
    const veh = VEHICLES[vehicleKey];
    if (!veh) return null;
    teardown();

    const home = bodyNamed(opts.body || veh.launchFrom || 'Earth')
      || bodyNamed('Earth') || dominant();
    if (!home) { toast?.('No body to fly from in this scenario'); return null; }

    vessel = new Vessel({
      vehicle: veh, parent: home, bodies: bodies(),
      payload: veh.carries ? veh.carries.mass : 0,
    });
    if (veh.role === 'launch' && opts.mode !== 'orbit') {
      // Put the pad in the local morning unless asked otherwise. This is not
      // decoration: the launch site's longitude decides whether the ascent is
      // watched in daylight or in the dark, and "wherever longitude zero
      // happens to be" is night about half the time.
      vessel.placeOnPad(opts.lat ?? veh.target?.inclination ?? 28.5,
                        opts.lon ?? morningLongitude(home));
      flyCam.setMode('pad');
      flyCam.state.hasPad = true;
      // Where the pad IS, in the parent-centred frame the vessel uses. The
      // local frame's origin follows the vehicle's ground track, so the pad
      // does not stay at the origin for long — it has to be carried, and
      // carried round with the planet's rotation like any other point on the
      // surface.
      sitePos = vessel.r.clone();
    } else {
      vessel.placeInOrbit(opts.alt ?? (veh.role === 'lander' ? 15000 : 250000),
                          opts.inc ?? 0, Math.random() * 6.28);
      flyCam.setMode('chase');
      flyCam.state.hasPad = false;
    }
    vessel.vehicleKey = vehicleKey;
    ap = new Autopilot(vessel);
    ap.mode = MODE.PROGRADE;

    craft = buildCraft(veh);
    local.craftRoot.add(craft.group);
    // Frame the whole stack from the pad camera rather than a fixed distance —
    // a Saturn V is 111 m and a lunar module is 7, and one number cannot frame
    // both. The distance is set so the stack subtends about two thirds of the
    // vertical field: d = (H/2)/tan(fov·0.34), with the camera a third of the
    // way up so the vehicle is centred rather than sitting on the bottom edge.
    const H = craft.height || veh.stages.reduce((a, s2) => a + s2.L, 0);
    if (sitePos) {
      site = createLaunchSite(veh, H, vessel.env);
      local.scene.add(site.group);
    }
    // The tower, not the vehicle, is what has to fit in frame — it is taller
    // than the stack and it is the thing the climb is read against.
    const F = Math.max(H, site ? site.towerHeight : 0);
    const d = (F * 0.5) / Math.tan(55 * 0.34 * Math.PI / 180);
    // Set back and round from the tower so the vehicle is seen against open
    // sky rather than through the lattice, and low, because a launch watched
    // from below is the shot that reads as a launch.
    padOffset.set(d * 0.62, F * 0.16, d * 0.78);
    flyCam.state.padPos.copy(padOffset);
    padAimed = false;
    buildPlumes(veh);
    entry = createEntryGlow(Math.max(vessel.diameter * 0.75, 2));
    craft.group.add(entry.mesh);

    flyCam.state.dist = 3.2;
    active = true;
    cruise = null;
    count = null;
    setWarp(0);
    vessel.log(`${veh.name} — ${vessel.phase === PHASE.PRELAUNCH ? 'on the pad' : 'in flight'}, ${(grossMass(veh) / 1000).toFixed(0)} t, ${(totalDeltaV(veh) / 1000).toFixed(2)} km/s ideal Δv`);
    if (vessel.phase === PHASE.PRELAUNCH) {
      const twr = liftoffThrust(veh, 101325) / (vessel.mass * vessel.env.gSurf);
      vessel.log(twr < 1
        ? `HOLD — liftoff thrust-to-weight is ${twr.toFixed(2)}. It will not leave the pad.`
        : `Liftoff TWR ${twr.toFixed(2)} · ${(liftoffThrust(veh, 101325) / 1e6).toFixed(1)} MN`);
    }
    refreshTargets();
    return vessel;
  }

  function buildPlumes(veh) {
    for (const p of plumes) p.mesh.parent?.remove(p.mesh);
    plumes = [];
    for (const st of craft.stages) {
      const spec = st.spec;
      if (!spec.engine) continue;
      const kinds = [[spec.engine, spec.count, st.parts.gimbals]];
      for (const [eng, n, pivots] of kinds) {
        for (const pv of pivots) {
          const pl = createPlume(eng.plume, eng.exitD || spec.D * 0.2);
          pv.add(pl.mesh);
          plumes.push({ ...pl, stageKey: spec.key, engine: eng });
        }
      }
    }
  }

  function teardown() {
    if (craft) { local.craftRoot.remove(craft.group); craft = null; }
    if (site) { local.scene.remove(site.group); site.dispose(); site = null; sitePos = null; }
    local.ground.position.y = 0;
    plumes = []; entry = null;
    smoke.clear();
    vessel = null; ap = null; cruise = null; plan = null; count = null;
    active = false;
  }

  // -------------------------------------------------------------------------
  // INTERSTELLAR
  // -------------------------------------------------------------------------
  /**
   * Leave the solar system for a star. This is a different regime, not a longer
   * burn: the vessel comes off the n-body integrator and onto the exact
   * hyperbolic solution in sim/flight/relativity.js, because at γ = 2 the
   * Newtonian one is simply wrong and no step size fixes that.
   */
  function beginCruise(targetBody, accelG) {
    if (!vessel) return;
    const st = vessel.stages.find(s => s.attached && s.spec.engine?.photon);
    if (!st) { toast?.('This vehicle has no interstellar drive — try the Hail Mary'); return; }
    const origin = vessel.parent.pos.clone().addScaledVector(vessel.r, 1 / AU_M);
    const tpos = targetBody
      ? targetBody.pos.clone()
      : origin.clone().add(new THREE.Vector3(11.9 * LY_AU, 0, 0));
    const a = (accelG ?? (st.spec.engine.holdAccel / G0)) * G0;
    cruise = new Cruise({
      origin, target: tpos, accel: a,
      dryMass: vessel.mass - st.prop, propMass: st.prop,
      exhaustMS: 299792458, name: vessel.name,
    });
    vessel.phase = PHASE.CRUISE;
    const p = cruise.plan;
    vessel.log(`Interstellar cruise — ${cruise.distLy.toFixed(2)} ly at ${(a / G0).toFixed(2)} g`);
    vessel.log(p.mode === 'flip'
      ? `Flip-and-burn: ${(p.tauS / YR_S).toFixed(2)} yr ship, ${(p.coordS / YR_S).toFixed(2)} yr coordinate`
      : `Accelerate–coast–decelerate: burn ${p.burnLy.toFixed(2)} ly, coast ${p.coastLy.toFixed(2)} ly, β ${p.betaMax.toFixed(4)} — ${(p.tauS / YR_S).toFixed(2)} yr ship, ${(p.coordS / YR_S).toFixed(2)} yr coordinate`);
    // A crossing is measured in years, so it starts at the top of the warp
    // ladder. The rails interlock does not apply here: an interstellar cruise
    // is not on rails, it is on the exact hyperbolic solution, and that is
    // valid at any step size.
    setWarp(WARPS.length - 1);
  }

  // -------------------------------------------------------------------------
  // THE TERMINAL COUNT
  // ----------------------------------------------------------------------------
  // The last ten seconds of a real count, with the events at the times they
  // really happen. The lead is the vehicle's own: a Saturn V starts its F-1s at
  // T−8.9 s and does not release until they have been running long enough to
  // prove themselves, a Shuttle starts the SSMEs at T−6.6 s and lights the
  // solids at T−0 (they cannot be shut down, so they go last), and Falcon 9 and
  // Starship start at T−3.
  //
  // This is not ceremony. Watching a vehicle sit still with its engines running
  // and then move is what tells you the clock is real; the ignition transient
  // is the only part of a launch where something changes fast enough to see.
  const IGNITION_LEAD = { saturnv: 8.9, shuttle: 6.6, falcon9: 3.0, starship: 3.0 };

  function startCount(T = 10) {
    const lead = IGNITION_LEAD[vessel.vehicleKey] ?? 4.0;
    count = { t: T, lead, lit: false, called: new Set() };
    vessel.heldDown = true;
    // Warp has to be 1× for the count to mean anything, and the interlock would
    // force it there a moment later anyway.
    setWarp(0);
    vessel.log(`T−${T.toFixed(0)} — terminal count`);
  }

  function stepCount(dtSim) {
    if (!count) return;
    count.t -= dtSim;
    for (const mark of [8, 5, 3, 2, 1]) {
      if (count.t <= mark && !count.called.has(mark)) {
        count.called.add(mark);
        vessel.log(`T−${mark}`);
      }
    }
    if (!count.lit && count.t <= count.lead) {
      count.lit = true;
      // Ignition, but still held down. The engines come up against the
      // hold-downs, which is exactly what the lead time is for: if one does not
      // reach thrust, the count is stopped with the vehicle still on the pad.
      vessel.throttle = 1;
      vessel.log('Ignition sequence start');
    }
    if (count.t <= 0) {
      count = null;
      vessel.heldDown = false;
      vessel.log('Hold-down release');
      ap.engage('ascent');
    }
  }

  // -------------------------------------------------------------------------
  // TIME
  // -------------------------------------------------------------------------
  function setWarp(i) {
    warpIdx = THREE.MathUtils.clamp(i, 0, WARPS.length - 1);
    // The interlocks are real: on rails the thrust and drag terms are not
    // evaluated at all, so allowing high warp while either is acting silently
    // deletes them. Same rule KSP enforces, same reason.
    if (vessel && !cruise) {
      const railable = vessel.canRail();
      if (!railable && WARPS[warpIdx] > 4) {
        warpIdx = 2;
        toast?.('Time warp limited — under thrust or inside the atmosphere');
      }
    }
    state.timeScale = WARPS[warpIdx] / YR_S;
  }
  function warp() { return WARPS[warpIdx]; }

  // -------------------------------------------------------------------------
  // TARGETING
  // -------------------------------------------------------------------------
  function refreshTargets() {
    if (!hud) return;
    hud.setTargets(bodies().map(b => b.name), target?.name);
  }
  function setTarget(name) {
    target = name ? bodyNamed(name) : null;
    plan = null;
    if (ap) { ap.target = target; ap.plan = null; }
  }

  // -------------------------------------------------------------------------
  // UPDATE
  // -------------------------------------------------------------------------
  function update(dt, frame) {
    if (!active || !vessel) return;
    vessel.bodies = bodies();
    if (!vessel.bodies.includes(vessel.parent)) {
      const d = dominant(); if (d) vessel.setParent(d, vessel.bodies); else return;
    }

    // Keep the orrery's clock slaved to the flight warp every frame, not just
    // when the warp changes — otherwise the time-scale slider silently
    // desynchronises the planets from the vehicle flying between them.
    state.timeScale = WARPS[warpIdx] / YR_S;
    const w = warp() * (state.paused ? 0 : state.speed);
    const simSeconds = dt * w;

    if (cruise) {
      // Ship proper time is the natural variable in cruise — the drive, the
      // fuel and the crew all live on it.
      cruise.step(simSeconds);
      cruise.position(_a);
      vessel.met = cruise.tau; vessel.coord = cruise.t;
      vessel.clockDelta = cruise.tau - cruise.t;
      // Point the ship along or against the line of flight, which is what a
      // flip-and-burn looks like from outside.
      const facing = cruise.leg === 'decel' ? -1 : 1;
      _q.setFromUnitVectors(new THREE.Vector3(0, 1, 0), _b.copy(cruise.dir).multiplyScalar(facing));
      vessel.q.slerp(_q, 1 - Math.exp(-dt * 1.4));
      skyBoost(cruise.dir, cruise.beta, boost);
    } else {
      boost.set(0, 0, 0);
      if (count) stepCount(simSeconds);
      if (ap) ap.update(Math.min(dt, 0.1));
      // Physics warp up to 4×; above that the vessel goes on rails, which is
      // only legal unpowered and out of the air (checked inside step()).
      const rails = w > 4 && vessel.canRail();
      if (rails) vessel.step(simSeconds, { rails: true });
      else {
        // Sub-step so a big real-time dt never becomes one huge integration.
        let rem = simSeconds, guard = 0;
        while (rem > 1e-6 && guard++ < 24) {
          const h = Math.min(rem, 0.5 * Math.max(w, 1));
          vessel.step(h);
          rem -= h;
        }
      }
      if (w > 4 && !vessel.canRail()) setWarp(2);
    }

    updateVisual(dt, simSeconds);
    if (hud) updateHUD();
  }

  // -------------------------------------------------------------------------
  function updateVisual(dt, simSeconds) {
    const env = vessel.env;
    const alt = vessel.altitude();
    _up.copy(vessel.r).normalize();
    _north.set(0, -1, 0);
    if (Math.abs(_north.dot(_up)) > 0.98) _north.set(1, 0, 0);
    _north.addScaledVector(_up, -_north.dot(_up)).normalize();
    sunDirection(_sun);

    // Irradiance relative to Earth's, so a launch from Mars is visibly dimmer
    // and one from Mercury is blinding — 1/r² from the brightest star.
    const star = bodies().filter(b => b.type === 'star')[0];
    const dAU = star ? Math.max(star.pos.distanceTo(vessel.parent.pos), 1e-4) : 1;
    const starFlux = star ? (star.luminosity ?? 1) / (dAU * dAU) : 1;
    local.update({ env, altitude: alt, sunDirWorld: _sun, upWorld: _up, northWorld: _north, starFlux });

    // The craft sits at the origin of the local frame with the local up as +Y,
    // so its attitude has to be expressed in that frame rather than in world
    // axes — the two differ by wherever on the planet it happens to be.
    const east = _east.crossVectors(_up, _north).normalize();
    const basis = new THREE.Matrix4().makeBasis(east, _up, _north.clone());
    const frameQ = new THREE.Quaternion().setFromRotationMatrix(basis).invert();
    craft.group.position.set(0, alt, 0);
    craft.group.quaternion.copy(frameQ).multiply(vessel.q);

    // ---- the launch complex. The local frame's origin is the point on the
    // surface directly under the VEHICLE, so as the vehicle flies downrange the
    // pad has to move backwards through the frame — which is the parallax that
    // makes a launch look like one. Its position is exact rather than
    // approximated: for a point at angular distance θ from the origin,
    // (r·east, r·up − R, r·north) is (R sinθ, R(cosθ−1), …), and R(cosθ−1) is
    // to second order the same −x²/2R drop the ground patch is drawn with, so
    // the pad sits ON the ground rather than above or below it.
    if (site && sitePos) {
      if (vessel.phase === PHASE.PRELAUNCH) {
        // Still standing on it: the pad is wherever the vehicle is, exactly.
        // Integrating it separately would let the two disagree by however much
        // the hold differs from a free surface point — 465 m/s at the equator,
        // which is half a kilometre of drift in the first second.
        sitePos.copy(vessel.r);
      } else {
        const w = -env.rotRate * simSeconds;   // carried round with the body
        const c = Math.cos(w), sn = Math.sin(w);
        sitePos.set(sitePos.x * c - sitePos.z * sn, sitePos.y, sitePos.x * sn + sitePos.z * c);
      }
      const sx = sitePos.dot(east), sy = sitePos.dot(_up) - env.radius, sz = sitePos.dot(_north);
      site.group.position.set(sx, sy, sz);
      // The pad deck is the datum: the vessel reads zero altitude standing on
      // its launch mount, which on a real complex is 7.6 m (Saturn/Shuttle
      // Mobile Launcher) to 23.5 m (Starship's OLM) above grade. So the ground
      // patch is dropped by that much rather than the vehicle being raised —
      // raising the vehicle would either put a constant error into the climb or
      // a fake one into its first few seconds.
      local.ground.position.y = -site.deckHeight;
      const range = Math.hypot(sx, sz);
      // Past a few tens of kilometres the whole complex is under a pixel, and
      // the ground patch's own detail is the better picture.
      site.group.visible = alt < 8e4 && range < 1.2e5;
      if (site.group.visible) {
        site.update({
          released: vessel.phase !== PHASE.PRELAUNCH && alt > 1,
          throttle: vessel.telemetry.thrust > 0 ? vessel.throttle : 0,
          dt: Math.min(simSeconds, 0.25),
        });
      }
      // Put the camera on the SUNLIT side once, on the first frame, when the
      // sun's azimuth in the local frame is finally known. A white rocket
      // photographed from its shadow side is a black rocket, which is most of
      // why the vehicle was hard to make out at all.
      if (!padAimed) {
        padAimed = true;
        const sunAz = Math.atan2(_sun.dot(_north), _sun.dot(east));
        const r = Math.hypot(padOffset.x, padOffset.z);
        padOffset.set(Math.cos(sunAz) * r, padOffset.y, Math.sin(sunAz) * r);
      }
      // The pad camera stands ON the pad, so it moves with it.
      _padAnchor.set(sx, sy, sz);
      flyCam.state.padPos.copy(_padAnchor).add(padOffset);
    }

    // moving parts
    const deploy = {};
    for (const st of vessel.stages) {
      const s = st.spec;
      let d = 0;
      if (s.legs) d = (vessel.phase === PHASE.LANDED || (alt < 3000 && vessel.v.dot(_up) < 0)) ? 1 : 0;
      if (s.gridFins) d = alt < (env.atm ? env.atm.top : 0) && vessel.v.dot(_up) < 0 ? 1 : 0;
      if (s.solar || s.look?.arrays) d = 1;
      deploy[s.key] = d;
    }
    // Gimbal deflection, from the attitude error the controller is working on.
    const gerr = ap?.aim ? vessel.forward(_b).angleTo(ap.aim) : 0;
    const gx = THREE.MathUtils.clamp(gerr * 2.4, 0, 0.12) * Math.sign(Math.sin(vessel.met * 3) || 1);
    craft.update({
      dt, attached: Object.fromEntries(vessel.stages.map(s => [s.spec.key, s.attached])),
      deploy, gimbal: { x: gx, z: 0 }, flap: 0,
    });
    for (const st of vessel.stages) {
      if (!st.attached && !craft.stages.find(c => c.key === st.spec.key)?.sep
          && craft.stages.find(c => c.key === st.spec.key)?.group.visible) {
        craft.separate(st.spec.key, 4 + Math.random() * 4, 0.2 + Math.random() * 0.5);
      }
    }

    // plumes — each engine's own, at the ambient pressure it is actually in
    const pa = env.atm ? pressure(env.atm, Math.max(alt, 0)) : 0;
    const p0 = env.atm ? env.atm.p0 : 101325;
    for (const pl of plumes) {
      const st = vessel.stages.find(s => s.spec.key === pl.stageKey);
      const on = st && st.attached && st.ignited && !st.spent && st.prop > 0 && vessel.throttle > 0;
      pl.update(on ? vessel.throttle : 0, pa, vessel.met, p0);
    }
    if (cruise) {
      for (const pl of plumes) pl.update(cruise.leg === 'coast' || cruise.leg === 'arrived' ? 0 : 1, 0, cruise.tau / 100, 101325);
    }

    // re-entry sheath, from the same heat flux that is burning the shield down
    if (entry) {
      entry.mesh.quaternion.copy(craft.group.quaternion).invert();
      vessel.airspeed(vessel.r, vessel.v, _b);
      const dir = _b.lengthSq() > 1 ? _b.normalize() : _up;
      entry.mesh.position.set(0, 0, 0);
      entry.update(vessel.telemetry.heat || 0, vessel.met);
    }

    // launch smoke: only where there is an atmosphere and a surface to hit
    if (env.atm && alt < 900 && vessel.throttle > 0 && vessel.telemetry.thrust > 0) {
      smoke.emit(_a.set(0, Math.max(alt - vessel.length * 0.5, 0), 0),
                 vessel.throttle, Math.max(vessel.diameter * 2.2, 12), dt);
    }
    smoke.update(dt);
    rcsPuffs.update(dt);

    // The pad camera is fixed on the ground, so it is the right view for the
    // first few seconds and useless after that. Hand over to the chase camera
    // once the vehicle has climbed out of its frame — which is what a launch
    // broadcast does, and for the same reason.
    if (flyCam.state.mode === 'pad' && alt > Math.max(craft.height * 22, 1500)) {
      flyCam.setMode('chase');
      vessel.log('Camera — pad view lost, tracking from the vehicle');
    }

    // ---- cameras. The local camera is the real one; the orrery's camera is
    // slaved to it so the planet, the stars and the lensing all agree with the
    // view the vehicle is being watched from.
    flyCam.update(local.camera, {
      craftPos: craft.group.position, craftQuat: craft.group.quaternion,
      length: craft.height || vessel.length, up: _a.set(0, 1, 0),
      velocity: vessel.v, dt,
      sunLocal: _b.set(_sun.dot(east), _sun.dot(_up), _sun.dot(_north)).normalize(),
    });
    local.camera.updateMatrixWorld(true);

    // Map the local camera into the orrery: same orientation, position offset
    // from the vessel by the local offset converted to scene units.
    const sceneScale = state.sceneScale;
    const parentScene = vessel.parent.viz ? vessel.parent.viz.group.position : new THREE.Vector3();
    _b.copy(vessel.r).multiplyScalar(sceneScale / AU_M);
    const camLocal = local.camera.position.clone().sub(craft.group.position);
    // rotate the local offset out of the local frame back into world axes
    const inv = frameQ.clone().invert();
    camLocal.applyQuaternion(inv);
    camera.position.copy(parentScene).add(_b).addScaledVector(camLocal, sceneScale / AU_M);
    const worldQuat = inv.clone().multiply(local.camera.quaternion);
    camera.quaternion.copy(worldQuat);
    camera.fov = local.camera.fov;
    camera.updateProjectionMatrix();
    camera.updateMatrixWorld(true);
  }

  // -------------------------------------------------------------------------
  function updateHUD() {
    const t = vessel.telemetry;
    _up.copy(vessel.r).normalize();
    _north.set(0, -1, 0);
    if (Math.abs(_north.dot(_up)) > 0.98) _north.set(1, 0, 0);
    _north.addScaledVector(_up, -_north.dot(_up)).normalize();
    const markers = {};
    for (const k of ['prograde', 'retrograde', 'normal', 'antinormal', 'radial']) {
      const d = attitudeFor(k, vessel, target);
      if (d) markers[k] = d.clone();
    }
    if (target) markers.target = targetOffset(vessel, target, _a).clone().normalize();
    if (ap?.aim) markers.node = ap.aim.clone();

    if (target && ap && !plan) plan = ap.planTransfer(target);
    hud.update({
      vessel, telemetry: t, up: _up, north: _north, markers,
      status: cruise ? `Interstellar cruise — ${cruise.leg}` : (ap?.status || 'Manual control'),
      mode: ap?.mode, program: ap?.program, warp: warp(),
      parentName: vessel.parent.name,
      planHTML: cruise ? cruiseHTML(cruise.readout())
        : (target ? planHTML(plan, target.name) : ''),
    });
  }

  // -------------------------------------------------------------------------
  // RENDER — the local pass, composited over the orrery's frame
  // -------------------------------------------------------------------------
  function renderLocal() {
    if (!active) return;
    renderer.autoClear = false;
    renderer.clearDepth();
    renderer.render(local.scene, local.camera);
    renderer.autoClear = true;
  }

  function setSize(w, h) { local.setSize(w, h); }

  // -------------------------------------------------------------------------
  // INPUT
  // -------------------------------------------------------------------------
  function key(e) {
    if (!active || !vessel) return false;
    switch (e.code) {
      case 'Comma':  setWarp(warpIdx - 1); return true;
      case 'Period': setWarp(warpIdx + 1); return true;
      case 'KeyX':   vessel.throttle = 0; return true;
      case 'KeyZ':   vessel.throttle = 1; return true;
      case 'ShiftLeft':  vessel.throttle = Math.min(1, vessel.throttle + 0.06); return true;
      case 'ControlLeft': vessel.throttle = Math.max(0, vessel.throttle - 0.06); return true;
      case 'Space':  if (e.shiftKey) { vessel.stage(); return true; } return false;
      case 'KeyG': {
        const st = vessel.stages.find(s => s.attached && s.spec.legs);
        if (st) { st.gearOut = !st.gearOut; }
        return true;
      }
      case 'KeyC': {
        const modes = ['chase', 'orbit', 'cockpit', 'pad'];
        const i = modes.indexOf(flyCam.state.mode);
        flyCam.setMode(modes[(i + 1) % modes.length]);
        return true;
      }
      default: return false;
    }
  }

  function wheel(e) {
    if (!active) return false;
    flyCam.state.dist = THREE.MathUtils.clamp(flyCam.state.dist * (1 + e.deltaY * 0.001), 0.6, 400);
    return true;
  }
  function drag(dx, dy) {
    if (!active) return false;
    flyCam.state.userAimed = true;
    flyCam.state.yaw -= dx * 0.006;
    flyCam.state.pitch = THREE.MathUtils.clamp(flyCam.state.pitch - dy * 0.006, -1.45, 1.45);
    return true;
  }

  // -------------------------------------------------------------------------
  if (panel) {
    hud = createFlightHUD(panel, {
      setMode(m) { if (ap) { ap.program = null; ap.mode = m; ap.say('Manual control'); } },
      runProgram(p) {
        if (!ap) return;
        if (p === 'cruise') { beginCruise(target, null); return; }
        if (p === 'transfer' && !target) { toast?.('Pick a target body first'); return; }
        ap.plan = null; ap.node = null; ap.site = null; ap.burning = false;
        ap.slamming = false; ap.entryDone = false; ap.shieldGone = false; ap.craneOut = false;
        if (p === 'ascent' && vessel.phase === PHASE.PRELAUNCH) { startCount(); return; }
        ap.engage(p);
      },
      setTarget,
    });
  }

  return {
    get active() { return active; },
    get vessel() { return vessel; },
    get autopilot() { return ap; },
    get cruise() { return cruise; },
    get boost() { return boost; },
    localCamera: local.camera,
    // A console handle on local space, in the same spirit as window.SIM: this is
    // the only way to see what the second render pass thinks it is drawing.
    localView: local,
    begin, beginCruise, teardown, update, renderLocal, setSize,
    key, wheel, drag, setWarp, warp, setTarget, refreshTargets,
    warpIndex: () => warpIdx, warpList: WARPS,
    cameraMode: () => flyCam.state.mode,
    setCameraMode: (m) => flyCam.setMode(m),
    vehicles: VEHICLE_ORDER.map(k => ({ key: k, ...VEHICLES[k] })),
  };
}
