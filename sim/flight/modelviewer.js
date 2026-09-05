import * as THREE from 'three';
import { buildCraft } from './craftmodel.js';
import { VEHICLES, VEHICLE_ORDER, grossMass, totalDeltaV, stageDeltaV, padTWR } from './vehicles.js';

// ============================================================================
// THE MODEL VIEWER
// ----------------------------------------------------------------------------
// The vehicles are built at their real dimensions from the same numbers the
// physics uses, and in flight you almost never get to see that. A rocket in a
// launch is a hundred metres away and lit from one side; a lander is a dot on a
// grey plain; an ion cruiser is in the dark. So this is a studio: neutral
// ground, three-point light, a turntable, and nothing else in the scene.
//
// It exists to answer three questions that flight cannot:
//
//   HOW BIG IS IT?      A 1.75 m figure stands at the base and a rule is drawn
//                       up the side in ten-metre divisions. Scale is a
//                       comparison, not a number — 110 m means nothing until
//                       there is a person next to it.
//   WHAT IS IT MADE OF? The stack can be pulled apart along its own axis, each
//                       stage separated in proportion to its length, so the
//                       interstages, the engine clusters and the payload are
//                       all visible at once.
//   WHAT MOVES?         Legs, fins, arrays and gimbals all run from the same
//                       `update` the flight model drives, so what you see here
//                       is what will move on the vehicle.
//
// LIGHTING is a photographic three-point setup rather than a physical one,
// because the question here is "what shape is this" and not "what would this
// look like at Merritt Island at 09:00". A key at 35° above and to the left, a
// fill at a quarter of its strength opposite to open the shadows, and a rim
// behind to separate a white vehicle from a grey ground — which is exactly the
// problem every NASA publicity photograph of a rocket had to solve.
// ============================================================================

const GRID_VERT = `
  varying vec3 vP;
  void main(){ vP = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`;

const GRID_FRAG = `
  precision highp float;
  varying vec3 vP;
  uniform float uStep, uRadius;
  uniform vec3 uCol, uBg;
  void main(){
    // Anti-aliased grid: the line width is set from the screen-space derivative
    // so a line is one pixel wide however far away it is. A fixed width would
    // either alias into moiré at range or vanish underfoot.
    vec2 g = abs(fract(vP.xz / uStep - 0.5) - 0.5) / fwidth(vP.xz / uStep);
    float line = 1.0 - min(min(g.x, g.y), 1.0);
    vec2 g10 = abs(fract(vP.xz / (uStep * 10.0) - 0.5) - 0.5) / fwidth(vP.xz / (uStep * 10.0));
    line = max(line, (1.0 - min(min(g10.x, g10.y), 1.0)) * 1.6);
    float fade = 1.0 - smoothstep(uRadius * 0.35, uRadius, length(vP.xz));
    gl_FragColor = vec4(mix(uBg, uCol, clamp(line, 0.0, 1.0)), fade);
  }`;

export function createModelViewer() {
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(38, 1, 0.05, 40000);

  // The rig is carried ON the camera, not fixed to the world. A studio
  // photographer moves the lights with the subject; a fixed rig means half of
  // every turntable revolution is spent looking at the shadow side, which is
  // exactly the problem this viewer exists to solve.
  const key = new THREE.DirectionalLight(0xfff3e4, 2.9);
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xbfd4f0, 0.8);
  scene.add(fill);
  const rim = new THREE.DirectionalLight(0xe8f0ff, 1.9);
  scene.add(rim);
  scene.add(new THREE.HemisphereLight(0x2a3340, 0x14161a, 0.55));

  const gridU = {
    uStep: { value: 1 }, uRadius: { value: 100 },
    uCol: { value: new THREE.Color(0x55677a) }, uBg: { value: new THREE.Color(0x101318) },
  };
  const grid = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), new THREE.ShaderMaterial({
    uniforms: gridU, vertexShader: GRID_VERT, fragmentShader: GRID_FRAG,
    transparent: true, depthWrite: false, side: THREE.DoubleSide,
  }));
  grid.rotation.x = -Math.PI / 2;
  scene.add(grid);

  const root = new THREE.Group();
  scene.add(root);

  // ---- the human figure. 1.75 m, and deliberately a silhouette rather than a
  // model: the eye reads a person from the proportions alone, and anything more
  // detailed would invite you to look at it instead of at the vehicle.
  function human() {
    const g = new THREE.Group();
    const m = new THREE.MeshStandardMaterial({ color: 0xd8641f, roughness: 0.85, metalness: 0.0 });
    const body = new THREE.Mesh(new THREE.CapsuleGeometry(0.19, 0.72, 4, 10), m);
    body.position.y = 1.10;
    g.add(body);
    const head = new THREE.Mesh(new THREE.SphereGeometry(0.115, 12, 10), m);
    head.position.y = 1.66;
    g.add(head);
    for (const s of [-1, 1]) {
      const leg = new THREE.Mesh(new THREE.CapsuleGeometry(0.085, 0.62, 4, 8), m);
      leg.position.set(s * 0.10, 0.40, 0);
      g.add(leg);
      const arm = new THREE.Mesh(new THREE.CapsuleGeometry(0.062, 0.56, 4, 8), m);
      arm.position.set(s * 0.30, 1.12, 0);
      g.add(arm);
    }
    return g;
  }
  const figure = human();
  root.add(figure);

  // ---- the rule: a graduated bar beside the vehicle, in tens of metres.
  const ruleGroup = new THREE.Group();
  root.add(ruleGroup);
  function buildRule(H) {
    ruleGroup.clear();
    const mat = new THREE.LineBasicMaterial({ color: 0x6f8496 });
    const step = H > 200 ? 50 : H > 60 ? 10 : H > 12 ? 5 : 1;
    const pts = [];
    pts.push(new THREE.Vector3(0, 0, 0), new THREE.Vector3(0, H, 0));
    for (let y = 0; y <= H + 1e-6; y += step) {
      const long = (Math.round(y / step) % 5 === 0);
      pts.push(new THREE.Vector3(0, y, 0), new THREE.Vector3(long ? H * 0.035 : H * 0.018, y, 0));
    }
    const g = new THREE.BufferGeometry().setFromPoints(pts);
    ruleGroup.add(new THREE.LineSegments(g, mat));
    ruleGroup.userData.step = step;
  }

  let craft = null, vehicle = null, height = 1, span = 1, midY = 0.5, radius = 1;
  // Turntable state. `spin` is the idle rotation; it stops the moment the
  // viewer takes hold of the model, because an object that keeps moving under
  // your hand cannot be inspected.
  const cam = { yaw: 0.9, pitch: 0.20, dist: 3.0, spin: 0.10, held: false, explode: 0, wantExplode: 0 };
  let deployAll = 1;

  function load(vehicleKey) {
    const veh = VEHICLES[vehicleKey];
    if (!veh) return null;
    if (craft) { root.remove(craft.group); craft = null; }
    vehicle = { key: vehicleKey, ...veh };
    craft = buildCraft(veh);
    root.add(craft.group);
    // Frame from the MODEL's own bounds, not from the stacked stage lengths.
    // Those two disagree wherever a vehicle is not a simple stack — the lunar
    // module's legs reach far outside its 6 m of stage height, an aeroshell is
    // wider than it is tall, and a Shuttle's boosters sit alongside rather than
    // under. A box measured off the geometry cannot be wrong about any of them.
    craft.group.updateMatrixWorld(true);
    const bb = new THREE.Box3().setFromObject(craft.group);
    const size = bb.getSize(new THREE.Vector3());
    height = craft.height || veh.stages.reduce((a, s) => a + s.L, 0);
    // What has to fit vertically is the larger of the height and the width, so
    // a squat, wide vehicle is not cropped by a frame sized for a tall one.
    span = Math.max(size.y, size.x * 0.8, size.z * 0.8, 1);
    midY = (bb.min.y + bb.max.y) * 0.5;
    radius = Math.max(size.x, size.z) * 0.5;

    figure.position.set(radius + 1.4, 0, radius * 0.5);
    figure.visible = span > 3.5;
    buildRule(height);
    ruleGroup.position.set(-(radius + 1.2), 0, 0);

    // A grid whose squares are a size you can name: metres for a lander, tens
    // of metres for a launcher.
    gridU.uStep.value = span > 60 ? 10 : span > 12 ? 5 : 1;
    gridU.uRadius.value = span * 3.2;
    grid.scale.set(span * 7, span * 7, 1);

    cam.dist = 1.95;
    cam.yaw = 0.9;
    cam.pitch = 0.10;
    cam.explode = cam.wantExplode = 0;
    return vehicle;
  }

  return {
    scene, camera, cam,
    get vehicle() { return vehicle; },
    get height() { return height; },
    load,

    /** Stage-by-stage statistics for the panel, all derived rather than stored. */
    stats() {
      if (!vehicle) return null;
      const rows = vehicle.stages.map((s, i) => ({
        key: s.key, name: s.name || s.key,
        L: s.L, D: s.D, dry: s.dry, prop: s.prop,
        engine: s.engine ? `${s.count}× ${s.engine.name}` : '—',
        thrust: s.engine ? s.engine.thrustVac * s.count : 0,
        isp: s.engine ? s.engine.ispVac : 0,
        dv: stageDeltaV(vehicle, i),
      }));
      return {
        name: vehicle.name, height, rows,
        gross: grossMass(vehicle), dv: totalDeltaV(vehicle),
        twr: padTWR(vehicle, 9.80665),
      };
    },

    setExplode(v) { cam.wantExplode = THREE.MathUtils.clamp(v, 0, 1); },
    setDeploy(v) { deployAll = v ? 1 : 0; },
    drag(dx, dy) {
      cam.held = true;
      cam.yaw -= dx * 0.008;
      cam.pitch = THREE.MathUtils.clamp(cam.pitch - dy * 0.006, -1.35, 1.45);
    },
    wheel(e) {
      cam.dist = THREE.MathUtils.clamp(cam.dist * (1 + e.deltaY * 0.0012), 0.45, 40);
    },

    update(dt) {
      if (!craft) return;
      if (!cam.held) cam.yaw += cam.spin * dt;
      cam.explode += (cam.wantExplode - cam.explode) * (1 - Math.exp(-dt * 4));

      // The stack is pulled apart along its own axis, each stage moved in
      // proportion to how far up the stack it sits — so the gaps are even and
      // the vehicle stays recognisable instead of scattering.
      for (const st of craft.stages) {
        st.group.position.y = st.baseY + cam.explode * st.baseY * 0.55;
        st.group.visible = true;
        st.sep = null;
      }
      craft.update({
        dt,
        attached: Object.fromEntries(craft.stages.map(s => [s.key, true])),
        deploy: Object.fromEntries(craft.stages.map(s => [s.key, deployAll])),
        gimbal: { x: 0, z: 0 }, flap: 0,
      });

      // Frame the whole stack: the camera orbits the vehicle's mid-height at a
      // distance set by the height itself, so a 7 m lander and a 120 m launcher
      // are both filled to the same fraction of the frame.
      const H = span * (1 + cam.explode * 0.5);
      const mid = midY + span * cam.explode * 0.28;
      const d = cam.dist * H;
      const cp = Math.cos(cam.pitch), sp = Math.sin(cam.pitch);
      camera.position.set(
        Math.cos(cam.yaw) * cp * d, mid + sp * d, Math.sin(cam.yaw) * cp * d);
      camera.up.set(0, 1, 0);
      camera.lookAt(0, mid, 0);
      // Key 40° off the camera axis and above, fill 70° the other way and low,
      // rim behind and high: the standard three-point setup, in the camera's
      // own frame so it holds at every angle.
      const place = (light, dAz, elev) => {
        const a = cam.yaw + dAz;
        light.position.set(Math.cos(a) * Math.cos(elev), Math.sin(elev), Math.sin(a) * Math.cos(elev))
          .multiplyScalar(H * 10);
        light.target.position.set(0, mid, 0);
        light.target.updateMatrixWorld();
      };
      place(key, -0.70, 0.62);
      place(fill, 1.15, 0.12);
      place(rim, Math.PI + 0.35, 0.75);

      camera.near = Math.max(H * 0.002, 0.02);
      camera.far = H * 200;
      camera.updateProjectionMatrix();
    },

    setSize(w, h) { camera.aspect = w / h; camera.updateProjectionMatrix(); },

    list() { return VEHICLE_ORDER.map(k => ({ key: k, ...VEHICLES[k] })); },

    dispose() {
      if (craft) root.remove(craft.group);
      craft = null; vehicle = null;
    },
  };
}
