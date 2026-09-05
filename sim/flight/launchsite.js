import * as THREE from 'three';

// ============================================================================
// THE LAUNCH COMPLEX
// ----------------------------------------------------------------------------
// A rocket rising over an empty plain does not look like it is rising. There is
// nothing in the frame whose size is known, so there is no parallax to read and
// no scale to read it against — the vehicle appears to sit still and then to be
// somewhere else. Every launch broadcast ever made solves this the same way: it
// puts a tower of known height next to the vehicle and lets you watch the
// vehicle go past it.
//
// So this is not decoration. The tower is the instrument you read the first
// fifteen seconds of a launch on, which is exactly the part of the flight where
// the vehicle is moving slowly enough that nothing else in view is changing.
//
// Everything here is at real dimensions, from the pads these vehicles actually
// flew from:
//
//   LC-39A hardstand      390 × 325 m octagon, raised 12.8 m above grade
//   flame trench          137 m long, 18 m wide, 12.2 m deep, split by a
//                         wedge deflector under the vehicle
//   Mobile Launcher       49.4 × 41.1 m platform, 7.6 m deep, one 13.7 m
//                         square exhaust opening
//   LUT (Saturn V)        115.8 m to the top of the hammerhead crane, 12 m
//                         square in plan, nine swing arms
//   FSS (Shuttle)         75.3 m, plus the vent arm and its "beanie cap" over
//                         the ET, and a rotating service structure
//   Falcon 9 TE           ~63 m strongback, retracted a few degrees at T−4 min
//                         and dropped away at liftoff
//   Starship tower        146 m, two catch arms
//   lightning masts       three, on a catenary; the 39B masts are 181 m
//   water tower           88 m, 1.135 Ml, for the sound suppression deluge
//
// The moving parts move for the reasons they really do: swing arms carry
// propellant and power and cannot be released until the engines are up, so they
// retract on ignition; the strongback is holding the vehicle vertical and falls
// back as it leaves; the deluge starts before ignition, because it is there to
// stop the ACOUSTIC energy reflecting off the deck and shaking the payload
// apart, not to cool anything.
// ============================================================================

const CONCRETE = new THREE.MeshStandardMaterial({ color: 0x8d8d88, roughness: 0.95, metalness: 0.02 });
const DARKCON  = new THREE.MeshStandardMaterial({ color: 0x5c5c58, roughness: 0.96, metalness: 0.02 });
const STEEL    = new THREE.MeshStandardMaterial({ color: 0x7a8288, roughness: 0.62, metalness: 0.55 });
const PAINT    = new THREE.MeshStandardMaterial({ color: 0x9c3f2e, roughness: 0.8,  metalness: 0.1 });
const GREY     = new THREE.MeshStandardMaterial({ color: 0x6e7276, roughness: 0.75, metalness: 0.35 });
const SCORCH   = new THREE.MeshStandardMaterial({ color: 0x2a2724, roughness: 0.98, metalness: 0.02 });
const WHITE    = new THREE.MeshStandardMaterial({ color: 0xc9ccd0, roughness: 0.8,  metalness: 0.08 });

// ---------------------------------------------------------------------------
// A merged box soup. A lattice tower is a few thousand struts and every one of
// them as its own mesh would cost more draw calls than the rest of the sim put
// together, so they are baked into one BufferGeometry up front. Nothing in a
// tower moves relative to the rest of the tower, so there is nothing lost.
// ---------------------------------------------------------------------------
class Struts {
  constructor() { this.pos = []; this.nor = []; this.idx = []; this.n = 0; }
  /** A box from a→b with cross-section w×w, oriented to the segment. */
  strut(ax, ay, az, bx, by, bz, w) {
    const d = new THREE.Vector3(bx - ax, by - ay, bz - az);
    const L = d.length();
    if (L < 1e-6) return;
    d.divideScalar(L);
    const ref = Math.abs(d.y) > 0.95 ? new THREE.Vector3(1, 0, 0) : new THREE.Vector3(0, 1, 0);
    const u = new THREE.Vector3().crossVectors(d, ref).normalize().multiplyScalar(w * 0.5);
    const v = new THREE.Vector3().crossVectors(d, u).normalize().multiplyScalar(w * 0.5);
    const A = new THREE.Vector3(ax, ay, az), B = new THREE.Vector3(bx, by, bz);
    const corners = [];
    for (const end of [A, B]) for (const [su, sv] of [[1, 1], [1, -1], [-1, -1], [-1, 1]]) {
      corners.push(end.x + u.x * su + v.x * sv, end.y + u.y * su + v.y * sv, end.z + u.z * su + v.z * sv);
    }
    const base = this.n;
    for (let i = 0; i < 8; i++) this.pos.push(corners[i * 3], corners[i * 3 + 1], corners[i * 3 + 2]);
    // Flat-ish normals: a strut is thin enough that a radial normal reads fine
    // and costs no extra vertices.
    for (let i = 0; i < 8; i++) {
      const cx = corners[i * 3] - (i < 4 ? A.x : B.x);
      const cy = corners[i * 3 + 1] - (i < 4 ? A.y : B.y);
      const cz = corners[i * 3 + 2] - (i < 4 ? A.z : B.z);
      const l = Math.hypot(cx, cy, cz) || 1;
      this.nor.push(cx / l, cy / l, cz / l);
    }
    const F = [[0, 1, 2, 3], [7, 6, 5, 4], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]];
    for (const [a, b, c, e] of F) this.idx.push(base + a, base + b, base + c, base + a, base + c, base + e);
    this.n += 8;
  }
  build() {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(this.pos, 3));
    g.setAttribute('normal', new THREE.Float32BufferAttribute(this.nor, 3));
    g.setIndex(this.idx);
    g.computeBoundingSphere();
    return g;
  }
}

/**
 * A square lattice tower: four legs, horizontal ties at `bay` intervals, and a
 * pair of diagonals in every bay of every face. That is what a real umbilical
 * tower is — the diagonals are what carries the wind load, and they are also
 * the only reason a lattice reads as a lattice at a distance rather than as
 * four lines.
 */
function latticeTower(H, side, { bay = 6, leg = 0.55, brace = 0.28 } = {}) {
  const s = new Struts();
  const h = side / 2;
  const legs = [[-h, -h], [h, -h], [h, h], [-h, h]];
  for (const [x, z] of legs) s.strut(x, 0, z, x, H, z, leg);
  const bays = Math.max(2, Math.round(H / bay));
  const dy = H / bays;
  for (let i = 0; i <= bays; i++) {
    const y = i * dy;
    for (let k = 0; k < 4; k++) {
      const [x1, z1] = legs[k], [x2, z2] = legs[(k + 1) % 4];
      s.strut(x1, y, z1, x2, y, z2, brace);
    }
  }
  for (let i = 0; i < bays; i++) {
    const y0 = i * dy, y1 = y0 + dy;
    for (let k = 0; k < 4; k++) {
      const [x1, z1] = legs[k], [x2, z2] = legs[(k + 1) % 4];
      // alternate the diagonal's sense per bay, as a real braced frame does
      if (i % 2 === 0) s.strut(x1, y0, z1, x2, y1, z2, brace);
      else s.strut(x2, y0, z2, x1, y1, z1, brace);
    }
  }
  return new THREE.Mesh(s.build(), STEEL);
}

/** A horizontal truss boom — the swing arms, the catch arms, the crane jib. */
function truss(L, w, d, { chord = 0.22 } = {}) {
  const s = new Struts();
  const hw = w / 2;
  for (const z of [-hw, hw]) for (const y of [0, d]) s.strut(0, y, z, L, y, z, chord);
  const bays = Math.max(2, Math.round(L / (d * 1.2)));
  for (let i = 0; i <= bays; i++) {
    const x = (i / bays) * L;
    for (const z of [-hw, hw]) s.strut(x, 0, z, x, d, z, chord * 0.8);
    s.strut(x, 0, -hw, x, 0, hw, chord * 0.8);
    s.strut(x, d, -hw, x, d, hw, chord * 0.8);
  }
  for (let i = 0; i < bays; i++) {
    const x0 = (i / bays) * L, x1 = ((i + 1) / bays) * L;
    for (const z of [-hw, hw]) s.strut(x0, 0, z, x1, d, z, chord * 0.8);
  }
  return new THREE.Mesh(s.build(), STEEL);
}

function box(w, h, d, m, x = 0, y = 0, z = 0) {
  const b = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), m);
  b.position.set(x, y + h / 2, z);
  return b;
}

/** The raised hardstand: an octagonal mound with sloped flanks. */
function hardstand(across, rise) {
  const g = new THREE.CylinderGeometry(across * 0.5, across * 0.5 + rise * 2.6, rise, 8, 1);
  const m = new THREE.Mesh(g, CONCRETE);
  m.position.y = -rise * 0.5;   // top face at local y = 0, i.e. at the pad deck
  m.rotation.y = Math.PI / 8;
  return m;
}

/**
 * The flame trench and its deflector. The trench runs under the vehicle and out
 * both ways; the deflector is a wedge directly beneath the engines that turns
 * the exhaust through 90° and sends it out either end. Without it the plume
 * reflects straight back up into the vehicle it just came out of.
 */
function flameTrench(len, wide, deep) {
  const g = new THREE.Group();
  const wall = 2.5;
  for (const z of [-(wide / 2 + wall / 2), wide / 2 + wall / 2]) {
    g.add(box(len, deep, wall, DARKCON, 0, -deep, z));
  }
  g.add(box(len, 1.2, wide, SCORCH, 0, -deep, 0));
  // the wedge
  const wedge = new THREE.Mesh(new THREE.CylinderGeometry(0.01, wide * 0.48, deep * 0.85, 3, 1), SCORCH);
  wedge.rotation.set(0, Math.PI / 2, 0);
  wedge.scale.set(1, 1, 1);
  wedge.position.y = -deep + deep * 0.85 / 2;
  const holder = new THREE.Group();
  holder.add(wedge);
  holder.rotation.y = Math.PI / 2;
  g.add(holder);
  return g;
}

/** Three masts on a catenary, which is what a real lightning protection system
 *  is: the wire is the conductor and the masts only hold it up. */
function lightningMasts(R, H) {
  const g = new THREE.Group();
  const tops = [];
  for (let i = 0; i < 3; i++) {
    const a = (i / 3) * Math.PI * 2 + Math.PI / 6;
    const x = Math.cos(a) * R, z = Math.sin(a) * R;
    const m = latticeTower(H * 0.72, 4.5, { bay: 7, leg: 0.3, brace: 0.16 });
    m.position.set(x, 0, z);
    g.add(m);
    const spire = new THREE.Mesh(new THREE.CylinderGeometry(0.12, 0.5, H * 0.28, 6), STEEL);
    spire.position.set(x, H * 0.72 + H * 0.14, z);
    g.add(spire);
    tops.push(new THREE.Vector3(x, H, z));
  }
  // catenary: y = a·cosh(x/a) — the shape a hanging cable actually takes, and
  // over this span it sags about a tenth of the run.
  const pts = [];
  for (let i = 0; i < 3; i++) {
    const A = tops[i], B = tops[(i + 1) % 3];
    const span = A.distanceTo(B), sag = span * 0.10;
    const a = span * span / (8 * sag);
    for (let t = 0; t <= 16; t++) {
      const u = t / 16, x = (u - 0.5) * span;
      const drop = a * (Math.cosh(x / a) - Math.cosh(span / (2 * a)));
      pts.push(new THREE.Vector3().lerpVectors(A, B, u).setY(A.y + drop));
    }
  }
  const cg = new THREE.BufferGeometry().setFromPoints(pts);
  const cable = new THREE.LineSegments(cg, new THREE.LineBasicMaterial({ color: 0x3a3f44 }));
  // setFromPoints gives a strip per run; draw it as a strip instead
  g.add(new THREE.Line(cg, new THREE.LineBasicMaterial({ color: 0x3a3f44 })));
  cable.visible = false;
  return g;
}

/** The sound-suppression water tower. 88 m, and the tank on top holds 1.135 Ml
 *  — released in 41 seconds, starting before ignition. */
function waterTower(H = 88) {
  const g = new THREE.Group();
  g.add(latticeTower(H * 0.78, 9, { bay: 8, leg: 0.4, brace: 0.2 }));
  const tank = new THREE.Mesh(new THREE.CylinderGeometry(7.5, 7.5, H * 0.2, 20), WHITE);
  tank.position.y = H * 0.78 + H * 0.1;
  g.add(tank);
  const cap = new THREE.Mesh(new THREE.SphereGeometry(7.5, 20, 8, 0, Math.PI * 2, 0, Math.PI / 2), WHITE);
  cap.position.y = H * 0.78 + H * 0.2;
  g.add(cap);
  return g;
}

// ---------------------------------------------------------------------------
// THE COMPLEX
// ---------------------------------------------------------------------------

const STYLES = {
  saturnv:  'lut',
  shuttle:  'fss',
  falcon9:  'strongback',
  starship: 'chopsticks',
};

/**
 * Build a launch complex sized to a vehicle.
 *
 * @param vehicle  the entry from sim/flight/vehicles.js
 * @param height   the vehicle's real stacked height, m
 * @param env      flightEnv() for the body — only its gravity matters here,
 *                 and only for how far the deluge plume drifts
 */
export function createLaunchSite(vehicle, height, env) {
  const style = STYLES[vehicle.key] || 'lut';
  const group = new THREE.Group();
  const D = vehicle.stages[0]?.D || 5;

  // How high the vehicle stands above its own launch mount. The vessel's
  // altitude is measured from the planet's reference radius and reads zero on
  // the pad, so the complex is built with the DECK at group-local y = 0 and
  // everything that touches the ground sits at −deck: that puts the deck under
  // the engines rather than through them, and puts the grade where the ground
  // patch is drawn.
  const deckHeight = style === 'chopsticks' ? 23.5 : style === 'strongback' ? 9.6 : 7.6;
  const GRADE = -deckHeight;

  // ---- ground works, common to every complex
  const ground = new THREE.Group();
  ground.position.y = GRADE;
  group.add(ground);
  const rise = 12.8;
  ground.add(hardstand(Math.max(height * 2.6, 200), rise));
  ground.add(flameTrench(137, 18, 12.2));
  // The scorched apron. Every pad has one and it is the single strongest cue
  // that something violent happens here.
  const apron = new THREE.Mesh(new THREE.CircleGeometry(Math.max(D * 5, 30), 40), SCORCH);
  apron.rotation.x = -Math.PI / 2;
  apron.position.y = 0.12;
  ground.add(apron);
  // The crawlerway out to the VAB — a 40 m wide river-rock road, and the only
  // thing in the scene that says which way "away" is.
  const road = new THREE.Mesh(new THREE.PlaneGeometry(40, 1400), DARKCON);
  road.rotation.x = -Math.PI / 2;
  road.position.set(0, 0.08, -760);
  ground.add(road);

  // The masts stand well clear of the vehicle — they are there to intercept a
  // strike, and a conductor close enough to be in the frame is close enough to
  // be a hazard. At 39B they are about 200 m out on a 300 m catenary span.
  ground.add(lightningMasts(Math.max(height * 2.4, 240), Math.max(height * 1.2, 100)));
  const wt = waterTower(88);
  wt.position.set(-150, 0, 90);
  ground.add(wt);

  // ---- the launch mount. Every one of these vehicles stands on a structure
  // that holds it down until the engines are at full thrust and confirmed good.
  // Every part of the structure that stands on the ground is built upward from
  // zero and then dropped onto grade in one move, so a change to the deck
  // height cannot leave one piece of the tower floating.
  const mount = new THREE.Group();
  mount.position.y = GRADE;
  group.add(mount);

  /** @type {{group:THREE.Group, retract:number, axis:'yaw'|'tilt', rest:number, open:number}[]} */
  const arms = [];
  let tower = null;

  if (style === 'lut' || style === 'fss') {
    // Mobile Launcher Platform: 49.4 × 41.1 m, 7.6 m deep, with a square
    // exhaust opening the vehicle stands over. Built as four slabs around the
    // hole rather than one box, so the hole is real and the trench shows.
    const PW = 49.4, PD = 41.1, PH = 7.6, HOLE = 13.7;
    const sideW = (PW - HOLE) / 2, sideD = (PD - HOLE) / 2;
    mount.add(box(sideW, PH, PD, GREY, -(HOLE / 2 + sideW / 2), 0, 0));
    mount.add(box(sideW, PH, PD, GREY, +(HOLE / 2 + sideW / 2), 0, 0));
    mount.add(box(HOLE, PH, sideD, GREY, 0, 0, -(HOLE / 2 + sideD / 2)));
    mount.add(box(HOLE, PH, sideD, GREY, 0, 0, +(HOLE / 2 + sideD / 2)));
    // hold-down arms
    for (let i = 0; i < 4; i++) {
      const a = (i / 4) * Math.PI * 2 + Math.PI / 4;
      mount.add(box(2.2, 3.4, 2.2, PAINT, Math.cos(a) * D * 0.62, PH, Math.sin(a) * D * 0.62));
    }

    const towerH = style === 'lut' ? Math.max(height + 12, 116) : 75.3;
    tower = latticeTower(towerH, 12.2, { bay: 6.1 });
    tower.position.set(-(HOLE / 2 + 16), PH, 0);
    mount.add(tower);
    // hammerhead crane
    const jib = truss(22, 3, 3);
    jib.position.set(-(HOLE / 2 + 16) + 6, PH + towerH + 2, 0);
    mount.add(jib);
    mount.add(box(3, 4, 3, STEEL, -(HOLE / 2 + 16), PH + towerH, 0));

    // SWING ARMS. Nine on the LUT, at the levels where the stages actually
    // needed servicing: propellant, pneumatics, power, and the crew access arm
    // near the top. They carry live umbilicals, so they cannot leave until the
    // engines are running — which is why they retract ON IGNITION and not
    // before it.
    const n = style === 'lut' ? 9 : 5;
    for (let i = 0; i < n; i++) {
      const y = PH + 10 + (i / (n - 1)) * (height * 0.92 - 10);
      const pivot = new THREE.Group();
      pivot.position.set(-(HOLE / 2 + 16), y, 0);
      const arm = truss(16, 2.6, 2.4);
      arm.position.set(6, -1.2, 0);
      pivot.add(arm);
      // the white room / crew access arm is the top one and is bigger
      if (i === n - 1) {
        const room = box(4.5, 4.5, 5, WHITE, 16, -2.2, 0);
        pivot.add(room);
      }
      mount.add(pivot);
      arms.push({ group: pivot, axis: 'yaw', rest: 0, open: -Math.PI * 0.62 });
    }

    if (style === 'fss') {
      // the Rotating Service Structure, swung clear before launch
      const rss = new THREE.Group();
      rss.position.set(-(HOLE / 2 + 16), PH, 0);
      const body = box(18, 40, 14, WHITE, 14, 12, 0);
      rss.add(body);
      mount.add(rss);
      arms.push({ group: rss, axis: 'yaw', rest: -Math.PI * 0.66, open: -Math.PI * 0.66 });
      // vent arm and its "beanie cap" over the ET nose, drawing off the boiled
      // oxygen that would otherwise fall as ice onto the orbiter's tiles
      const vent = new THREE.Group();
      vent.position.set(-(HOLE / 2 + 16), PH + height * 0.93, 0);
      const vArm = truss(14, 2.2, 2);
      vArm.position.set(5, 0, 0);
      vent.add(vArm);
      const cap = new THREE.Mesh(new THREE.ConeGeometry(3.4, 5, 16, 1, true), WHITE);
      cap.position.set(17, -1, 0);
      cap.rotation.x = Math.PI;
      vent.add(cap);
      mount.add(vent);
      arms.push({ group: vent, axis: 'yaw', rest: 0, open: -Math.PI * 0.55 });
    }
  } else if (style === 'strongback') {
    // Falcon 9's launch mount is a small four-legged stool, and the vehicle is
    // brought out lying on the transporter-erector, which then stands it up and
    // stays alongside carrying propellant and power until it lifts.
    const legH = 8;
    for (let i = 0; i < 4; i++) {
      const a = (i / 4) * Math.PI * 2 + Math.PI / 4;
      mount.add(box(1.6, legH, 1.6, GREY, Math.cos(a) * 4.4, 0, Math.sin(a) * 4.4));
    }
    mount.add(box(11, 1.6, 11, GREY, 0, legH, 0));
    const te = new THREE.Group();
    te.position.set(-(D / 2 + 2.6), legH, 0);
    const back = latticeTower(Math.min(height * 0.86, 63), 3.4, { bay: 5, leg: 0.3, brace: 0.16 });
    te.add(back);
    // the two umbilical "quick disconnect" boxes that fall away at liftoff
    te.add(box(2.4, 3, 2.4, WHITE, 1.6, height * 0.30, 0));
    te.add(box(2.4, 3, 2.4, WHITE, 1.6, height * 0.62, 0));
    mount.add(te);
    // The strongback rotates about its base, away from the vehicle.
    arms.push({ group: te, axis: 'tilt', rest: -0.035, open: -0.30 });
    tower = back;
  } else {
    // Starship: an Orbital Launch Mount on six legs with the vehicle over a
    // water-cooled steel deck, and a 146 m tower carrying two catch arms.
    const legH = 20;
    for (let i = 0; i < 6; i++) {
      const a = (i / 6) * Math.PI * 2;
      mount.add(box(3, legH, 3, GREY, Math.cos(a) * 12, 0, Math.sin(a) * 12));
    }
    const ring = new THREE.Mesh(new THREE.CylinderGeometry(14, 14, 3.5, 24, 1, true), GREY);
    ring.position.y = legH + 1.75;
    mount.add(ring);
    const deck = new THREE.Mesh(new THREE.RingGeometry(6.5, 14, 24), SCORCH);
    deck.rotation.x = -Math.PI / 2;
    deck.position.y = legH + 3.5;
    mount.add(deck);

    tower = latticeTower(146, 12, { bay: 8.4, leg: 0.7, brace: 0.32 });
    tower.position.set(-26, 0, 0);
    mount.add(tower);
    for (const z of [-9, 9]) {
      const pivot = new THREE.Group();
      pivot.position.set(-26, 62, z);
      const arm = truss(26, 5, 4.5, { chord: 0.34 });
      arm.position.set(6, 0, 0);
      pivot.add(arm);
      mount.add(pivot);
      arms.push({ group: pivot, axis: 'yaw', rest: z > 0 ? -0.10 : 0.10, open: z > 0 ? -1.15 : 1.15 });
    }
  }

  // ---- the deluge. Sprites rather than geometry: it is a cloud, and a cloud
  // made of triangles is a worse cloud than a cloud made of a few hundred
  // camera-facing quads.
  const STEAM = 340;
  const sPos = new Float32Array(STEAM * 3), sAge = new Float32Array(STEAM), sVel = new Float32Array(STEAM * 3);
  for (let i = 0; i < STEAM; i++) sAge[i] = -1;
  const sGeo = new THREE.BufferGeometry();
  sGeo.setAttribute('position', new THREE.BufferAttribute(sPos, 3));
  const sAgeAttr = new THREE.BufferAttribute(sAge, 1);
  sGeo.setAttribute('aAge', sAgeAttr);
  const steam = new THREE.Points(sGeo, new THREE.ShaderMaterial({
    uniforms: { uSize: { value: Math.max(D * 6, 30) } },
    vertexShader: `
      attribute float aAge; varying float vA; uniform float uSize;
      void main(){
        vA = aAge;
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        gl_PointSize = uSize * (0.35 + aAge * 1.6) * 300.0 / max(-mv.z, 1.0);
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: `
      varying float vA;
      void main(){
        vec2 d = gl_PointCoord - 0.5;
        float r = length(d);
        if(r > 0.5 || vA < 0.0) discard;
        float a = (1.0 - smoothstep(0.15, 0.5, r)) * (1.0 - vA) * 0.55;
        gl_FragColor = vec4(vec3(0.92, 0.93, 0.95), a);
      }`,
    transparent: true, depthWrite: false, blending: THREE.NormalBlending,
  }));
  steam.frustumCulled = false;
  group.add(steam);
  let sNext = 0;

  // Retraction state: 0 = stowed against the vehicle, 1 = fully clear. Arms are
  // heavy and hydraulic; the real ones take a couple of seconds.
  let open = 0;

  return {
    group,
    style,
    deckHeight,
    /** Height of the tallest structure, m — the camera uses it for framing. */
    towerHeight: style === 'chopsticks' ? 146 : style === 'strongback' ? Math.min(height * 0.86, 63) : Math.max(height + 12, 116),

    /**
     * @param s.released  true once the vehicle has committed to leaving
     * @param s.throttle  0..1, drives the deluge
     * @param s.dt        seconds
     */
    update(s) {
      const want = s.released ? 1 : 0;
      open += (want - open) * (1 - Math.exp(-s.dt / 1.6));
      for (const a of arms) {
        const ang = a.rest + (a.open - a.rest) * open;
        if (a.axis === 'yaw') a.group.rotation.y = ang;
        else a.group.rotation.z = ang;
      }

      // deluge: on whenever the engines are, plus the pre-ignition flow
      const rate = s.throttle > 0 ? 1 : 0;
      const emit = Math.min(Math.round(rate * 90 * s.dt), STEAM);
      for (let k = 0; k < emit; k++) {
        const i = sNext = (sNext + 1) % STEAM;
        const a = Math.random() * Math.PI * 2, rr = Math.sqrt(Math.random()) * D * 2.2;
        sPos[i * 3] = Math.cos(a) * rr;
        sPos[i * 3 + 1] = 1 + Math.random() * 4;
        sPos[i * 3 + 2] = Math.sin(a) * rr;
        // Blown out along the trench, because that is where the deflector sends
        // it, and up as it entrains air and loses momentum.
        const along = Math.random() < 0.5 ? -1 : 1;
        sVel[i * 3] = along * (14 + Math.random() * 26);
        sVel[i * 3 + 1] = 5 + Math.random() * 12;
        sVel[i * 3 + 2] = (Math.random() - 0.5) * 8;
        sAge[i] = 0;
      }
      for (let i = 0; i < STEAM; i++) {
        if (sAge[i] < 0) continue;
        sAge[i] += s.dt / 6.5;
        if (sAge[i] >= 1) { sAge[i] = -1; continue; }
        sPos[i * 3] += sVel[i * 3] * s.dt;
        sPos[i * 3 + 1] += sVel[i * 3 + 1] * s.dt;
        sPos[i * 3 + 2] += sVel[i * 3 + 2] * s.dt;
        // buoyant, and slowing as it spreads
        sVel[i * 3] *= Math.exp(-s.dt * 0.55);
        sVel[i * 3 + 2] *= Math.exp(-s.dt * 0.55);
        sVel[i * 3 + 1] = sVel[i * 3 + 1] * Math.exp(-s.dt * 0.3) + 3.5 * s.dt;
      }
      sGeo.attributes.position.needsUpdate = true;
      sAgeAttr.needsUpdate = true;
    },

    dispose() {
      group.traverse(o => { if (o.geometry) o.geometry.dispose(); });
      sGeo.dispose();
    },
  };
}
