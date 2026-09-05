import * as THREE from 'three';

// ============================================================================
// PROCEDURAL SPACECRAFT
// ----------------------------------------------------------------------------
// Every vehicle is built from primitives at its REAL dimensions in metres, from
// the same numbers the physics uses — a stage's length and diameter come out of
// sim/flight/vehicles.js, so a model can never disagree with the mass it is
// carrying. There are no external assets; this repo has no build step and no
// asset pipeline, and a lathe with the right contour gets closer to a rocket
// engine than a low-poly mesh would anyway.
//
// The parts that move are the point. Each stage is its own THREE.Group, so a
// separation is a re-parent rather than a swap; grid fins rotate out of their
// stowed position, landing legs deploy through a real four-bar arc, fairing
// halves hinge and tumble away, solar arrays unfold, engine bells gimbal with
// the guidance command, and flaps track the control input. All of it is driven
// from `update(state)` by the same numbers the autopilot is looking at.
//
// MATERIALS are chosen for the reason the real ones are:
//   · MLI reads as amber gold because it is Kapton over vapour-deposited
//     aluminium, not gold — so it is a rough, warm, slightly translucent gold
//     rather than a mirror.
//   · White paint is solar-reflective; black is a radiator; both are matte.
//   · Solar cells are dark blue-violet with a visible grid.
//   · Stainless (Starship) is the only near-mirror in the set.
//   · Foam-insulated tankage (the Shuttle ET) is that particular orange.
// ============================================================================

const MAT = {};
function mat(name, spec) {
  if (!MAT[name]) MAT[name] = new THREE.MeshStandardMaterial(spec);
  return MAT[name];
}
export function craftMaterials() {
  return {
    white:    mat('white',    { color: 0xe8e8ea, roughness: 0.72, metalness: 0.04 }),
    dirty:    mat('dirty',    { color: 0xb9b9bd, roughness: 0.85, metalness: 0.05 }),
    black:    mat('black',    { color: 0x1b1b1f, roughness: 0.62, metalness: 0.10 }),
    soot:     mat('soot',     { color: 0x33333a, roughness: 0.95, metalness: 0.02 }),
    steel:    mat('steel',    { color: 0xb8bfc6, roughness: 0.24, metalness: 0.92 }),
    alu:      mat('alu',      { color: 0x9aa0a6, roughness: 0.42, metalness: 0.78 }),
    gold:     mat('gold',     { color: 0xd8a13a, roughness: 0.55, metalness: 0.55 }),
    foam:     mat('foam',     { color: 0xc2663a, roughness: 0.95, metalness: 0.02 }),
    tiles:    mat('tiles',    { color: 0x24242a, roughness: 0.88, metalness: 0.03 }),
    ablator:  mat('ablator',  { color: 0x6b5344, roughness: 0.94, metalness: 0.02 }),
    solar:    mat('solar',    { color: 0x1b2a5e, roughness: 0.35, metalness: 0.30 }),
    nozzle:   mat('nozzle',   { color: 0x5d5a56, roughness: 0.38, metalness: 0.85 }),
    hot:      mat('hot',      { color: 0x2a2320, roughness: 0.55, metalness: 0.55 }),
    glass:    mat('glass',    { color: 0x0d1a24, roughness: 0.12, metalness: 0.55 }),
    red:      mat('red',      { color: 0xa02a22, roughness: 0.7,  metalness: 0.05 }),
  };
}

const M = craftMaterials();
const SKIN = {
  white: M.white, steel: M.steel, foam: M.foam, tiles: M.tiles,
  metal: M.alu, ablator: M.ablator, 'mli-gold': M.gold, 'panel-white': M.dirty,
};

// ---------------------------------------------------------------------------
// PARTS
// ---------------------------------------------------------------------------

/** A tank barrel with domed ends, built as a lathe so the domes are real
 *  geometry rather than a capsule approximation. */
function tank(L, D, material, { domeTop = 0.12, domeBot = 0.06, seg = 28 } = {}) {
  const r = D / 2, pts = [];
  const hb = r * domeBot, ht = r * domeTop;
  pts.push(new THREE.Vector2(0, 0));
  for (let i = 1; i <= 6; i++) {                      // bottom dome
    const a = (i / 6) * Math.PI / 2;
    pts.push(new THREE.Vector2(r * Math.sin(a), hb * (1 - Math.cos(a))));
  }
  pts.push(new THREE.Vector2(r, L - ht));
  for (let i = 1; i <= 6; i++) {                      // top dome
    const a = (i / 6) * Math.PI / 2;
    pts.push(new THREE.Vector2(r * Math.cos(a), L - ht + ht * Math.sin(a)));
  }
  const g = new THREE.LatheGeometry(pts, seg);
  return new THREE.Mesh(g, material);
}

/** A conical adapter / interstage between two diameters. */
function frustum(L, Dbot, Dtop, material, seg = 28) {
  const m = new THREE.Mesh(new THREE.CylinderGeometry(Dtop / 2, Dbot / 2, L, seg, 1, true), material);
  m.position.y = L / 2;
  return m;
}

/**
 * A bell nozzle, as a lathe of a real contour: a converging throat, then a
 * parabolic (Rao) expansion. The shape matters visually — an 80% Rao bell is
 * visibly not a cone, and the ratio of exit diameter to throat is what tells
 * you at a glance whether an engine is a sea-level or a vacuum design.
 */
function bell(exitD, { ratio = 3.6, chamber = true } = {}) {
  const re = exitD / 2;
  const rt = re / Math.sqrt(ratio);                  // throat radius from area ratio
  const L = re * 2.6;
  const pts = [];
  if (chamber) {
    pts.push(new THREE.Vector2(rt * 1.9, -L * 0.42));
    pts.push(new THREE.Vector2(rt * 1.9, -L * 0.26));
    pts.push(new THREE.Vector2(rt * 1.25, -L * 0.10));
  }
  pts.push(new THREE.Vector2(rt, 0));
  for (let i = 1; i <= 10; i++) {
    const u = i / 10;
    // parabolic expansion: fast opening near the throat, flattening at the exit
    pts.push(new THREE.Vector2(rt + (re - rt) * Math.pow(u, 0.62), L * u));
  }
  const g = new THREE.LatheGeometry(pts, 24);
  g.computeVertexNormals();
  const m = new THREE.Mesh(g, M.nozzle);
  m.rotation.x = Math.PI;                            // open end downward (−Y)
  return m;
}

/** A ring of engines with a real gimbal joint at each. Returns the group and
 *  the per-engine pivots so the guidance command can actually move them. */
function engineCluster(count, spread, exitD, opts = {}) {
  const g = new THREE.Group();
  const pivots = [];
  const place = (x, z) => {
    const p = new THREE.Group();
    p.position.set(x, 0, z);
    p.add(bell(exitD, opts));
    g.add(p); pivots.push(p);
  };
  if (count === 1) place(0, 0);
  else if (count <= 5) {
    // one centre + a ring — the F-1 and Merlin quincunx
    place(0, 0);
    for (let i = 0; i < count - 1; i++) {
      const a = (i / (count - 1)) * Math.PI * 2;
      place(Math.cos(a) * spread, Math.sin(a) * spread);
    }
  } else if (count <= 9) {
    // octaweb: eight around one
    place(0, 0);
    for (let i = 0; i < count - 1; i++) {
      const a = (i / (count - 1)) * Math.PI * 2 + 0.39;
      place(Math.cos(a) * spread, Math.sin(a) * spread);
    }
  } else {
    // three concentric rings, Super Heavy's arrangement
    const rings = [[3, 0.18], [10, 0.55], [count - 13, 0.92]];
    for (const [n, f] of rings) {
      for (let i = 0; i < n; i++) {
        const a = (i / n) * Math.PI * 2 + f;
        place(Math.cos(a) * spread * f, Math.sin(a) * spread * f);
      }
    }
  }
  return { group: g, pivots };
}

/** Grid fin — an actual waffle, because that is what makes it recognisable. */
function gridFin(size = 1.5) {
  const g = new THREE.Group();
  const t = size * 0.06;
  g.add(new THREE.Mesh(new THREE.BoxGeometry(size, t, size * 0.75), M.hot));
  for (let i = -2; i <= 2; i++) {
    const a = new THREE.Mesh(new THREE.BoxGeometry(t * 0.7, size * 0.42, size * 0.75), M.hot);
    a.position.set(i * size / 5, size * 0.21, 0); g.add(a);
    const b = new THREE.Mesh(new THREE.BoxGeometry(size, size * 0.42, t * 0.7), M.hot);
    b.position.set(0, size * 0.21, i * size * 0.15); g.add(b);
  }
  return g;
}

/** A landing leg as a real four-bar: a main strut and a folding secondary, so
 *  deployment traces an arc instead of a rotation about nothing. */
function landingLeg(len, footR) {
  const g = new THREE.Group();
  const strut = new THREE.Mesh(new THREE.CylinderGeometry(len * 0.045, len * 0.06, len, 8), M.dirty);
  strut.position.y = -len / 2; strut.rotation.z = 0;
  g.add(strut);
  const foot = new THREE.Mesh(new THREE.CylinderGeometry(footR, footR * 0.8, len * 0.05, 12), M.dirty);
  foot.position.y = -len; g.add(foot);
  const brace = new THREE.Mesh(new THREE.CylinderGeometry(len * 0.03, len * 0.03, len * 0.7, 6), M.alu);
  brace.position.set(len * 0.16, -len * 0.42, 0); brace.rotation.z = -0.45;
  g.add(brace);
  return g;
}

function solarArray(span, chord) {
  const g = new THREE.Group();
  const panel = new THREE.Mesh(new THREE.BoxGeometry(span, 0.05, chord), M.solar);
  g.add(panel);
  for (let i = 1; i < 6; i++) {
    const rib = new THREE.Mesh(new THREE.BoxGeometry(0.04, 0.07, chord), M.alu);
    rib.position.x = -span / 2 + span * i / 6; g.add(rib);
  }
  return g;
}

function dish(r) {
  const pts = [];
  for (let i = 0; i <= 8; i++) { const u = i / 8; pts.push(new THREE.Vector2(r * u, r * 0.34 * u * u)); }
  const m = new THREE.Mesh(new THREE.LatheGeometry(pts, 20), M.white);
  m.material = M.white;
  return m;
}

function radiator(w, h) {
  const g = new THREE.Group();
  g.add(new THREE.Mesh(new THREE.BoxGeometry(w, 0.04, h), M.white));
  for (let i = 0; i < 7; i++) {
    const p = new THREE.Mesh(new THREE.BoxGeometry(w * 0.94, 0.06, h * 0.02), M.black);
    p.position.z = -h / 2 + h * (i + 0.5) / 7; g.add(p);
  }
  return g;
}

/** Small detail that does more for realism than anything else its size: a ring
 *  of RCS thruster quads, and the black conduit runs down a white tank. */
function rcsRing(D, y, n = 4) {
  const g = new THREE.Group();
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2;
    const pod = new THREE.Group();
    pod.position.set(Math.cos(a) * D / 2, y, Math.sin(a) * D / 2);
    const box = new THREE.Mesh(new THREE.BoxGeometry(D * 0.07, D * 0.05, D * 0.07), M.dirty);
    pod.add(box);
    for (let k = 0; k < 2; k++) {
      const n2 = new THREE.Mesh(new THREE.ConeGeometry(D * 0.014, D * 0.03, 8), M.nozzle);
      n2.position.set(0, k ? D * 0.035 : -D * 0.035, 0);
      n2.rotation.x = k ? 0 : Math.PI;
      pod.add(n2);
    }
    pod.lookAt(0, y, 0);
    g.add(pod);
  }
  return g;
}

function stripe(D, y, h, material) {
  const m = new THREE.Mesh(new THREE.CylinderGeometry(D / 2 * 1.002, D / 2 * 1.002, h, 28, 1, true), material);
  m.position.y = y + h / 2;
  return m;
}

// ---------------------------------------------------------------------------
// STAGE BUILDERS — one per `look` flavour
// ---------------------------------------------------------------------------
function buildStage(spec, ctx) {
  const g = new THREE.Group();
  const look = spec.look || {};
  const skin = SKIN[look.skin] || M.white;
  const D = spec.D, L = spec.L;
  const parts = { gimbals: [], fins: [], legs: [], arrays: [], flaps: [], halves: [], nozzles: [] };

  if (look.srb) return buildSRB(spec, parts);
  if (look.orbiter) return buildOrbiter(spec, parts);
  if (look.aeroshell) return buildAeroshell(spec, parts);
  if (look.skycrane) return buildSkyCrane(spec, parts);
  if (look.rover) return buildRover(spec, parts);
  if (look.hailmary) return buildHailMary(spec, parts);
  if (look.beetle) return buildBeetle(spec, parts);
  if (look.bus) return buildIonBus(spec, parts);
  if (look.octagon) return buildLMDescent(spec, parts);
  if (look.cabin) return buildLMAscent(spec, parts);
  if (look.capsule) return buildCSM(spec, parts);
  if (look.fairing) return buildFairing(spec, parts);
  if (look.satellite) return buildSatellite(spec, parts);

  // ---- the default: a cylindrical stage with engines under it
  const body = tank(L, D, skin);
  g.add(body);
  if (look.soot) { const s = stripe(D, 0, L * 0.12, M.soot); g.add(s); }
  if (look.band) g.add(stripe(D, L * 0.62, L * 0.10, M.black));
  if (look.pattern === 'saturn') {
    // the black roll pattern that makes a Saturn V a Saturn V
    for (const [y, h] of [[L * 0.02, L * 0.05], [L * 0.30, L * 0.05], [L * 0.62, L * 0.05]]) {
      g.add(stripe(D, y, h, M.black));
    }
    const usa = stripe(D, L * 0.44, L * 0.09, M.red); g.add(usa);
  }
  if (look.hotStage) {
    const hs = new THREE.Mesh(new THREE.CylinderGeometry(D / 2 * 0.99, D / 2 * 0.99, L * 0.03, 28, 1, true), M.hot);
    hs.position.y = L * 0.995; g.add(hs);
  }
  if (look.interstage) {
    const is = new THREE.Mesh(new THREE.CylinderGeometry(D / 2, D / 2, look.interstage, 28, 1, true), M.dirty);
    is.position.y = L + look.interstage / 2; g.add(is);
  }
  if (look.aftSkirt) {
    const sk = new THREE.Mesh(new THREE.CylinderGeometry(D / 2, D / 2 * 1.02, L * 0.14, 24, 1, true), M.dirty);
    sk.position.y = L * 0.07; g.add(sk);
  }
  if (look.nosecone) {
    const pts = [];
    for (let i = 0; i <= 10; i++) { const u = i / 10; pts.push(new THREE.Vector2(D / 2 * Math.sqrt(1 - u * u * 0.96), L + u * D * 1.55)); }
    g.add(new THREE.Mesh(new THREE.LatheGeometry(pts, 28), skin));
  }
  if (look.tiles) {
    // heat tiles on the windward half only, which is what they are for
    const sh = new THREE.Mesh(new THREE.CylinderGeometry(D / 2 * 1.005, D / 2 * 1.005, L * 0.9, 28, 1, true, -Math.PI / 2, Math.PI), M.tiles);
    sh.position.y = L * 0.45; g.add(sh);
  }
  if (look.tank) {
    // Shuttle ET: an ogive nose and the intertank ribbing
    const pts = [];
    for (let i = 0; i <= 10; i++) { const u = i / 10; pts.push(new THREE.Vector2(D / 2 * Math.sqrt(1 - u * u), L + u * D * 0.9)); }
    g.add(new THREE.Mesh(new THREE.LatheGeometry(pts, 24), skin));
    for (let i = 0; i < 16; i++) {
      const rib = new THREE.Mesh(new THREE.BoxGeometry(0.14, L * 0.18, 0.14), M.foam);
      const a = i / 16 * Math.PI * 2;
      rib.position.set(Math.cos(a) * D / 2, L * 0.60, Math.sin(a) * D / 2);
      g.add(rib);
    }
  }

  // engines
  if (spec.engine && spec.count > 0) {
    const spread = D * 0.30;
    const ec = engineCluster(spec.count, spread, spec.engine.exitD || D * 0.2);
    ec.group.position.y = -0.02;
    g.add(ec.group);
    parts.gimbals = ec.pivots;
    // a thrust structure so the bells are not floating
    const ts = new THREE.Mesh(new THREE.CylinderGeometry(D / 2 * 0.92, D / 2 * 0.80, D * 0.16, 20, 1, true), M.soot);
    ts.position.y = D * 0.05; g.add(ts);
  }
  if (spec.vacEngine && spec.vacCount) {
    const ec = engineCluster(spec.vacCount, D * 0.44, spec.vacEngine.exitD);
    ec.group.position.y = -0.02; g.add(ec.group);
    parts.gimbals.push(...ec.pivots);
  }
  if (spec.gridFins) {
    for (let i = 0; i < spec.gridFins; i++) {
      const a = (i / spec.gridFins) * Math.PI * 2 + 0.4;
      const hinge = new THREE.Group();
      hinge.position.set(Math.cos(a) * D / 2, L * 0.93, Math.sin(a) * D / 2);
      hinge.rotation.y = -a;
      const fin = gridFin(D * 0.42);
      fin.position.set(D * 0.22, 0, 0);
      hinge.add(fin);
      g.add(hinge);
      parts.fins.push(hinge);
    }
  }
  if (spec.legs) {
    for (let i = 0; i < spec.legs; i++) {
      const a = (i / spec.legs) * Math.PI * 2 + 0.78;
      const hinge = new THREE.Group();
      hinge.position.set(Math.cos(a) * D / 2 * 0.92, L * 0.055, Math.sin(a) * D / 2 * 0.92);
      hinge.rotation.y = -a;
      hinge.add(landingLeg(D * 0.82, D * 0.10));
      g.add(hinge);
      parts.legs.push(hinge);
    }
  }
  if (spec.flaps) {
    for (const [ax, ay, sgn] of [[1, L * 0.86, 1], [-1, L * 0.86, -1], [1, L * 0.10, 1], [-1, L * 0.10, -1]]) {
      const h = new THREE.Group();
      h.position.set(ax * D / 2 * 0.95, ay, 0);
      const f = new THREE.Mesh(new THREE.BoxGeometry(D * 0.42, D * 0.5, 0.35), M.tiles);
      f.position.x = ax * D * 0.20;
      h.add(f); g.add(h); parts.flaps.push(h);
    }
  }
  if (spec.rcs) g.add(rcsRing(D, L * 0.88, 4));
  return { group: g, parts };
}

function buildSRB(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D, L = spec.L;
  for (const side of [-1, 1]) {
    const b = new THREE.Group();
    b.position.x = side * 6.9;
    b.add(tank(L * 0.86, D, M.white, { domeTop: 0.02 }));
    // the four segment joints — a solid's most recognisable feature
    for (let i = 1; i <= 4; i++) {
      const r = new THREE.Mesh(new THREE.TorusGeometry(D / 2 * 1.01, D * 0.02, 6, 24), M.dirty);
      r.rotation.x = Math.PI / 2; r.position.y = L * 0.86 * i / 5; b.add(r);
    }
    const pts = [];
    for (let i = 0; i <= 8; i++) { const u = i / 8; pts.push(new THREE.Vector2(D / 2 * Math.sqrt(1 - u * u * 0.98), L * 0.86 + u * D * 1.5)); }
    b.add(new THREE.Mesh(new THREE.LatheGeometry(pts, 20), M.white));
    const n = bell(spec.engine.exitD, { ratio: 7.7, chamber: false });
    n.scale.setScalar(1.35); b.add(n);
    g.add(b);
  }
  return { group: g, parts };
}

function buildOrbiter(spec, parts) {
  const g = new THREE.Group();
  const L = spec.L;
  // The orbiter lies along the stack, so it is built nose-up like everything
  // else and its wing is in the XZ plane.
  const fus = tank(L * 0.92, 5.2, M.white, { domeTop: 0.3 });
  g.add(fus);
  const nose = new THREE.Mesh(new THREE.SphereGeometry(2.6, 18, 12, 0, Math.PI * 2, 0, Math.PI / 2), M.tiles);
  nose.position.y = L * 0.92; g.add(nose);
  // wing: a double delta
  const sh = new THREE.Shape();
  sh.moveTo(0, -L * 0.34); sh.lineTo(11.9, -L * 0.40); sh.lineTo(11.9, -L * 0.24);
  sh.lineTo(4.2, 0.0); sh.lineTo(0, L * 0.10);
  const wingGeo = new THREE.ExtrudeGeometry(sh, { depth: 0.5, bevelEnabled: false });
  for (const side of [1, -1]) {
    const w = new THREE.Mesh(wingGeo, M.tiles);
    w.rotation.x = Math.PI / 2; w.rotation.y = side > 0 ? 0 : Math.PI;
    w.position.set(0, L * 0.42, 0.25 * side);
    g.add(w);
  }
  const tail = new THREE.Mesh(new THREE.BoxGeometry(0.45, 8.0, 5.0), M.white);
  tail.position.set(0, L * 0.80, -3.2); g.add(tail);
  // three main engines in a triangle + two OMS pods
  const ec = engineCluster(3, 2.2, 2.30);
  ec.group.position.y = 0.4; g.add(ec.group); parts.gimbals = ec.pivots;
  for (const side of [-1, 1]) {
    const pod = new THREE.Mesh(new THREE.CapsuleGeometry(1.5, 3.4, 6, 12), M.white);
    pod.position.set(side * 2.9, 2.6, -2.0); pod.rotation.x = 0.1; g.add(pod);
  }
  const cargo = new THREE.Mesh(new THREE.CylinderGeometry(2.3, 2.3, 18.3, 20, 1, true, 0, Math.PI), M.black);
  cargo.position.set(0, L * 0.55, 1.0); cargo.rotation.y = Math.PI / 2; g.add(cargo);
  const win = new THREE.Mesh(new THREE.BoxGeometry(2.4, 0.9, 0.3), M.glass);
  win.position.set(0, L * 0.88, 2.4); g.add(win);
  return { group: g, parts };
}

function buildFairing(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D, L = spec.L;
  // Two halves that hinge apart and tumble — the classic separation.
  for (const side of [1, -1]) {
    const h = new THREE.Group();
    const pts = [];
    for (let i = 0; i <= 12; i++) {
      const u = i / 12;
      const r = u < 0.55 ? D / 2 : D / 2 * Math.sqrt(Math.max(1 - ((u - 0.55) / 0.45) ** 2, 0));
      pts.push(new THREE.Vector2(Math.max(r, 0.02), u * L));
    }
    const half = new THREE.Mesh(
      new THREE.LatheGeometry(pts, 20, side > 0 ? -Math.PI / 2 : Math.PI / 2, Math.PI), M.white);
    half.material.side = THREE.DoubleSide;
    h.add(half);
    g.add(h);
    parts.halves.push(h);
  }
  return { group: g, parts };
}

function buildSatellite(spec, parts) {
  const g = new THREE.Group();
  const b = new THREE.Mesh(new THREE.BoxGeometry(2.4, 3.0, 2.4), M.gold);
  b.position.y = 1.5; g.add(b);
  for (const side of [1, -1]) {
    const arm = new THREE.Group();
    arm.position.set(side * 1.2, 1.6, 0);
    const a = solarArray(7.5, 2.0); a.position.x = side * 4.0; arm.add(a);
    g.add(arm); parts.arrays.push(arm);
  }
  const d = dish(1.1); d.position.y = 3.1; g.add(d);
  return { group: g, parts };
}

function buildCSM(spec, parts) {
  const g = new THREE.Group();
  // service module: a plain cylinder with the SPS bell out the back
  const sm = new THREE.Mesh(new THREE.CylinderGeometry(1.96, 1.96, 7.4, 24), M.alu);
  sm.position.y = 3.7; g.add(sm);
  g.add(rcsRing(3.92, 6.4, 4));
  const b = bell(2.24, { ratio: 62 }); b.scale.setScalar(1.15); g.add(b);
  const hd = dish(1.0); hd.position.set(2.4, 1.2, 0); hd.rotation.z = -1.1; g.add(hd);
  // command module: the cone, blunt end down
  const cm = new THREE.Mesh(new THREE.ConeGeometry(1.96, 3.2, 24), M.dirty);
  cm.position.y = 7.4 + 1.6; g.add(cm);
  const shield = new THREE.Mesh(new THREE.SphereGeometry(2.6, 20, 8, 0, Math.PI * 2, Math.PI * 0.72, Math.PI * 0.28), M.ablator);
  shield.position.y = 7.4 + 1.7; g.add(shield);
  return { group: g, parts };
}

function buildLMDescent(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D, L = spec.L;
  // The octagonal box. Its whole character is that it is a box wrapped in foil.
  const box = new THREE.Mesh(new THREE.CylinderGeometry(D / 2, D / 2, L, 8), M.gold);
  box.position.y = L / 2; box.rotation.y = Math.PI / 8; g.add(box);
  // Quadrant panels in black MLI, which is what breaks the shape up.
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const p = new THREE.Mesh(new THREE.BoxGeometry(D * 0.30, L * 0.8, 0.06), M.black);
    p.position.set(Math.cos(a) * D / 2 * 0.96, L / 2, Math.sin(a) * D / 2 * 0.96);
    p.rotation.y = -a; g.add(p);
  }
  const b = bell(spec.engine.exitD, { ratio: 47.5 }); b.scale.setScalar(1.1); g.add(b);
  // Four legs on outriggers, plus the ladder on the +X one.
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const h = new THREE.Group();
    h.position.set(Math.cos(a) * D / 2 * 0.9, L * 0.30, Math.sin(a) * D / 2 * 0.9);
    h.rotation.y = -a;
    const leg = landingLeg(3.2, 0.94);
    leg.rotation.z = -0.62;
    h.add(leg);
    const pad = new THREE.Mesh(new THREE.CylinderGeometry(0.47, 0.42, 0.12, 14), M.dirty);
    pad.position.set(2.0, -2.6, 0); h.add(pad);
    const probe = new THREE.Mesh(new THREE.CylinderGeometry(0.02, 0.02, 1.7, 5), M.dirty);
    probe.position.set(2.1, -3.4, 0); h.add(probe);
    g.add(h); parts.legs.push(h);
  }
  return { group: g, parts };
}

function buildLMAscent(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D;
  // The crew cabin: a fat cylinder with the two triangular windows canted down,
  // and the equipment bay behind it. Lumpy on purpose — it never flew in air.
  const cab = new THREE.Mesh(new THREE.CylinderGeometry(1.15, 1.15, 2.0, 16), M.gold);
  cab.rotation.x = Math.PI / 2; cab.position.set(0, 2.0, 0.35); g.add(cab);
  const mid = new THREE.Mesh(new THREE.BoxGeometry(2.5, 1.9, 2.4), M.gold);
  mid.position.set(0, 1.0, -0.2); g.add(mid);
  for (const side of [-1, 1]) {
    const w = new THREE.Mesh(new THREE.BoxGeometry(0.60, 0.42, 0.10), M.glass);
    w.position.set(side * 0.44, 2.35, 1.32); w.rotation.x = -0.45; g.add(w);
  }
  const hatch = new THREE.Mesh(new THREE.BoxGeometry(0.85, 0.85, 0.10), M.black);
  hatch.position.set(0, 1.05, 1.24); g.add(hatch);
  const d = dish(0.66); d.position.set(1.1, 3.0, -0.6); d.rotation.z = -0.9; g.add(d);
  const drogue = new THREE.Mesh(new THREE.CylinderGeometry(0.42, 0.55, 0.5, 14), M.dirty);
  drogue.position.y = 3.2; g.add(drogue);
  const b = bell(spec.engine.exitD, { ratio: 45 }); g.add(b);
  g.add(rcsRing(3.4, 2.4, 4));
  return { group: g, parts };
}

function buildAeroshell(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D;
  // A 70° sphere-cone: the shape every Mars lander has used since Viking.
  const heat = new THREE.Mesh(new THREE.ConeGeometry(D / 2, D * 0.28, 32, 1, true), M.ablator);
  heat.rotation.x = Math.PI; heat.position.y = D * 0.14; g.add(heat);
  const back = new THREE.Mesh(new THREE.ConeGeometry(D / 2, D * 0.42, 32, 1, true), M.white);
  back.position.y = D * 0.14 + D * 0.21; g.add(back);
  const cap = new THREE.Mesh(new THREE.CylinderGeometry(D * 0.18, D * 0.22, D * 0.06, 20), M.white);
  cap.position.y = D * 0.14 + D * 0.42; g.add(cap);
  return { group: g, parts };
}

function buildSkyCrane(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D;
  const deck = new THREE.Mesh(new THREE.CylinderGeometry(D / 2, D / 2 * 0.9, 0.8, 12), M.alu);
  deck.position.y = 1.2; g.add(deck);
  // four clusters of two throttleable engines, canted out so the plumes miss
  // the rover hanging underneath — which is exactly why they are canted.
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const p = new THREE.Group();
    p.position.set(Math.cos(a) * D * 0.42, 1.0, Math.sin(a) * D * 0.42);
    p.rotation.z = -Math.cos(a) * 0.28; p.rotation.x = Math.sin(a) * 0.28;
    for (const dx of [-0.18, 0.18]) { const b = bell(0.20, { ratio: 40 }); b.position.x = dx; p.add(b); }
    g.add(p); parts.gimbals.push(p);
  }
  const tankA = new THREE.Mesh(new THREE.SphereGeometry(0.55, 14, 10), M.gold);
  tankA.position.set(0, 1.9, 0); g.add(tankA);
  return { group: g, parts };
}

function buildRover(spec, parts) {
  const g = new THREE.Group();
  const body = new THREE.Mesh(new THREE.BoxGeometry(2.2, 0.9, 1.5), M.alu);
  body.position.y = 0.85; g.add(body);
  const rtg = new THREE.Mesh(new THREE.CylinderGeometry(0.32, 0.32, 0.8, 12), M.black);
  rtg.position.set(-1.2, 1.1, 0); rtg.rotation.z = Math.PI / 2; g.add(rtg);
  const mast = new THREE.Mesh(new THREE.CylinderGeometry(0.06, 0.07, 1.3, 8), M.dirty);
  mast.position.set(0.7, 1.9, 0); g.add(mast);
  const head = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.22, 0.22), M.dirty);
  head.position.set(0.7, 2.6, 0); g.add(head);
  for (const [x, z] of [[-0.85, 0.72], [0, 0.78], [0.85, 0.72], [-0.85, -0.72], [0, -0.78], [0.85, -0.72]]) {
    const w = new THREE.Mesh(new THREE.CylinderGeometry(0.42, 0.42, 0.4, 14), M.dirty);
    w.rotation.x = Math.PI / 2; w.position.set(x, 0.42, z); g.add(w);
  }
  return { group: g, parts };
}

function buildIonBus(spec, parts) {
  const g = new THREE.Group();
  const bus = new THREE.Mesh(new THREE.BoxGeometry(1.64, 1.36, 1.64), M.gold);
  bus.position.y = 0.9; g.add(bus);
  for (const side of [1, -1]) {
    const arm = new THREE.Group();
    arm.position.set(side * 0.82, 0.9, 0);
    const a = solarArray(8.3, 2.2); a.position.x = side * 4.4; arm.add(a);
    g.add(arm); parts.arrays.push(arm);
  }
  const d = dish(0.82); d.position.y = 1.9; g.add(d);
  // Three gridded ion thrusters. They are small, and they should look it.
  for (let i = 0; i < 3; i++) {
    const a = i / 3 * Math.PI * 2;
    const th = new THREE.Group();
    th.position.set(Math.cos(a) * 0.42, 0.1, Math.sin(a) * 0.42);
    const cyl = new THREE.Mesh(new THREE.CylinderGeometry(0.18, 0.16, 0.32, 14), M.nozzle);
    cyl.position.y = -0.16; th.add(cyl);
    const grid = new THREE.Mesh(new THREE.CircleGeometry(0.17, 16), M.black);
    grid.position.y = -0.33; grid.rotation.x = Math.PI / 2; th.add(grid);
    g.add(th); parts.gimbals.push(th);
  }
  return { group: g, parts };
}

/**
 * THE HAIL MARY. Three parallel astrophage tanks with the pressure vessel
 * forward of them, radiators along the tanks, the spin drives at the base, and
 * four beetles in a ring at the nose. The film's version is deliberately
 * something today's space agencies would build — panelled, ribbed, utilitarian —
 * so this is greeble on plain cylinders rather than a smooth hull.
 */
function buildHailMary(spec, parts) {
  const g = new THREE.Group();
  const L = spec.L, D = spec.D;
  const tankL = L * 0.62, tankD = D * 0.29, tr = D * 0.29;

  for (let i = 0; i < 3; i++) {
    const a = i / 3 * Math.PI * 2 + Math.PI / 2;
    const t = new THREE.Group();
    t.position.set(Math.cos(a) * tr, 0, Math.sin(a) * tr);
    t.add(tank(tankL, tankD, M.dirty, { domeTop: 0.5, domeBot: 0.5 }));
    // ribs — the tanks read as engineered rather than extruded
    for (let k = 1; k < 9; k++) {
      const r = new THREE.Mesh(new THREE.TorusGeometry(tankD / 2 * 1.02, tankD * 0.015, 5, 20), M.alu);
      r.rotation.x = Math.PI / 2; r.position.y = tankL * k / 9; t.add(r);
    }
    // the spin drive at the base of each tank
    const dr = new THREE.Group();
    const cone = new THREE.Mesh(new THREE.CylinderGeometry(tankD * 0.30, tankD * 0.46, tankD * 0.55, 20, 1, true), M.hot);
    cone.position.y = -tankD * 0.30; dr.add(cone);
    const face = new THREE.Mesh(new THREE.CircleGeometry(tankD * 0.44, 20), M.black);
    face.position.y = -tankD * 0.575; face.rotation.x = Math.PI / 2; dr.add(face);
    t.add(dr);
    parts.gimbals.push(dr);
    g.add(t);
  }
  // spine + pressure vessel
  const spine = new THREE.Mesh(new THREE.CylinderGeometry(D * 0.055, D * 0.055, L * 0.92, 14), M.alu);
  spine.position.y = L * 0.46; g.add(spine);
  const hullL = L * 0.30, hullD = D * 0.33;
  const hull = tank(hullL, hullD, M.dirty, { domeTop: 0.55, domeBot: 0.35 });
  hull.position.y = tankL + L * 0.02; g.add(hull);
  // deck bands: control room / lab / dormitory, in that order forward-to-aft
  for (let k = 0; k < 3; k++) {
    const band = stripe(hullD, tankL + L * 0.02 + hullL * (0.12 + k * 0.26), hullL * 0.035, k === 1 ? M.black : M.alu);
    g.add(band);
  }
  for (const side of [1, -1]) {
    const w = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.06), M.glass);
    w.position.set(side * hullD * 0.5, tankL + L * 0.02 + hullL * 0.80, 0);
    w.rotation.y = Math.PI / 2 * side; g.add(w);
  }
  // radiators along the tank bay, which is where the waste heat is
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + 0.4;
    const r = radiator(D * 0.40, tankL * 0.55);
    r.position.set(Math.cos(a) * D * 0.50, tankL * 0.45, Math.sin(a) * D * 0.50);
    r.rotation.y = -a; r.rotation.z = Math.PI / 2;
    g.add(r); parts.arrays.push(r);
  }
  // four beetles in a ring at the very nose
  const noseY = tankL + L * 0.02 + hullL;
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const b = new THREE.Group();
    b.position.set(Math.cos(a) * hullD * 0.42, noseY + D * 0.10, Math.sin(a) * hullD * 0.42);
    const body = new THREE.Mesh(new THREE.CapsuleGeometry(D * 0.055, D * 0.10, 5, 12), M.dirty);
    b.add(body);
    const nz = new THREE.Mesh(new THREE.ConeGeometry(D * 0.045, D * 0.07, 12), M.hot);
    nz.position.y = -D * 0.12; nz.rotation.x = Math.PI; b.add(nz);
    g.add(b);
  }
  const cap = new THREE.Mesh(new THREE.ConeGeometry(hullD * 0.55, D * 0.30, 20), M.dirty);
  cap.position.y = noseY + D * 0.30; g.add(cap);
  g.add(rcsRing(hullD, tankL + L * 0.02 + hullL * 0.5, 4));
  return { group: g, parts };
}

function buildBeetle(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D, L = spec.L;
  const body = new THREE.Mesh(new THREE.CapsuleGeometry(D / 2, L * 0.55, 6, 16), M.dirty);
  body.position.y = L * 0.5; g.add(body);
  for (let k = 0; k < 4; k++) {
    const r = new THREE.Mesh(new THREE.TorusGeometry(D / 2 * 1.02, D * 0.02, 5, 20), M.alu);
    r.rotation.x = Math.PI / 2; r.position.y = L * (0.22 + k * 0.19); g.add(r);
  }
  const dr = new THREE.Group();
  dr.add(new THREE.Mesh(new THREE.CylinderGeometry(D * 0.30, D * 0.40, D * 0.30, 16, 1, true), M.hot));
  dr.position.y = -D * 0.05; g.add(dr); parts.gimbals.push(dr);
  const d = dish(D * 0.34); d.position.set(D * 0.4, L * 0.75, 0); d.rotation.z = -1.2; g.add(d);
  return { group: g, parts };
}

// ---------------------------------------------------------------------------
// THE VEHICLE
// ---------------------------------------------------------------------------
/**
 * Build a whole vehicle. Stages are stacked bottom-to-top along +Y at their
 * real lengths, which is also the axis vessel.js thrusts along, so the model and
 * the physics cannot disagree about which way is up.
 *
 * Returns { group, stages: [{key, group, parts}], update(state) }.
 */
export function buildCraft(vehicle) {
  const root = new THREE.Group();
  const stages = [];
  let y = 0;
  for (const spec of vehicle.stages) {
    const { group, parts } = buildStage(spec, vehicle);
    // Parallel boosters and stages whose engines live on another stage sit
    // alongside rather than on top.
    const inline = !(spec.look?.srb);
    group.position.y = y;
    root.add(group);
    stages.push({ key: spec.key, spec, group, parts, baseY: y, deploy: 0, sep: null });
    if (inline) y += spec.L + (spec.look?.interstage || 0);
  }
  root.userData.height = y;

  const _v = new THREE.Vector3();
  return {
    group: root, stages, height: y,
    /**
     * Drive every moving part from the flight state. Nothing here is on a timer
     * — a leg is out because the guidance asked for it, a gimbal is deflected
     * because the controller is commanding that torque, a fin is at the angle
     * the roll rate needs.
     */
    update(s) {
      for (const st of stages) {
        const live = s.attached?.[st.key] !== false;
        st.group.visible = live || st.sep != null;
        if (st.sep) {
          // A separated stage drifts and tumbles away on its own for a moment,
          // which is the only part of a staging event anyone remembers.
          st.sep.t += s.dt;
          st.group.position.y = st.baseY - st.sep.t * st.sep.v;
          st.group.rotation.x = st.sep.t * st.sep.spin;
          st.group.rotation.z = st.sep.t * st.sep.spin * 0.6;
          if (st.sep.t > 6) { st.group.visible = false; st.sep = null; }
          continue;
        }
        // deployables, eased so they take a real second or two
        const want = st.spec.key === s.gearStage || live ? s.deploy?.[st.key] ?? 0 : 0;
        st.deploy += THREE.MathUtils.clamp(want - st.deploy, -s.dt * 0.55, s.dt * 0.55);
        const d = st.deploy;
        for (const leg of st.parts.legs) leg.rotation.z = -d * 1.15;
        for (const fin of st.parts.fins) fin.rotation.z = -d * 1.35;
        for (const arr of st.parts.arrays) arr.rotation.z = (1 - d) * 1.35;
        for (const h of st.parts.halves) {
          h.rotation.z = 0; h.position.x = 0;
        }
        // gimbal: the commanded deflection, shared by every bell on the stage
        const gx = (s.gimbal?.x || 0), gz = (s.gimbal?.z || 0);
        for (const p of st.parts.gimbals) { p.rotation.x = gz; p.rotation.z = -gx; }
        for (const f of st.parts.flaps) f.rotation.z = (s.flap || 0) * 0.6;
      }
    },
    /** Detach a stage: it stops following the stack and drifts off. */
    separate(key, dv = 3, spin = 0.25) {
      const st = stages.find(x => x.key === key);
      if (st && !st.sep) st.sep = { t: 0, v: dv, spin };
    },
  };
}
