import * as THREE from 'three';
import { craftStage, bindParts } from './craftassets.js';

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
/**
 * Every craft material is DOUBLE-SIDED. Most of this vehicle set is open
 * shells — lathed nozzles, aft skirts, interstages, an aeroshell backshell —
 * and a single-sided shell has no inner wall: you look into an engine bell and
 * see the sky through it, and the sky crane's backshell shows the heat shield
 * that is supposed to be behind it. Back-face culling saves nothing measurable
 * at ~16 k triangles per vehicle, and a closed solid never shows its inside
 * anyway, so this is the cheap fix rather than capping every open profile.
 */
function mat(name, spec) {
  if (!MAT[name]) MAT[name] = new THREE.MeshStandardMaterial({ side: THREE.DoubleSide, ...spec });
  return MAT[name];
}
export function craftMaterials() {
  return {
    white:    mat('white',    { color: 0xe8e8ea, roughness: 0.72, metalness: 0.04 }),
    dirty:    mat('dirty',    { color: 0xb9b9bd, roughness: 0.85, metalness: 0.05 }),
    black:    mat('black',    { color: 0x1b1b1f, roughness: 0.62, metalness: 0.10 }),
    soot:     mat('soot',     { color: 0x33333a, roughness: 0.95, metalness: 0.02 }),
    // METALNESS IS DELIBERATELY LOW. Nothing in this renderer sets
    // `scene.environment` — local space is lit by punctual lights only — and a
    // PBR metal has no diffuse term at all: it is entirely reflection, so with
    // nothing to reflect it renders BLACK. That is why the sky crane's deck and
    // Curiosity's chassis came out as dark blobs at metalness 0.78. Until there
    // is an environment to sample, the base colour has to carry the material
    // and metalness stays low enough that the diffuse term survives.
    steel:    mat('steel',    { color: 0xc4ccd4, roughness: 0.30, metalness: 0.34 }),
    alu:      mat('alu',      { color: 0xa9b0b7, roughness: 0.46, metalness: 0.26 }),
    gold:     mat('gold',     { color: 0xd8a13a, roughness: 0.52, metalness: 0.38 }),
    foam:     mat('foam',     { color: 0xc2663a, roughness: 0.95, metalness: 0.02 }),
    tiles:    mat('tiles',    { color: 0x24242a, roughness: 0.88, metalness: 0.03 }),
    ablator:  mat('ablator',  { color: 0x6b5344, roughness: 0.94, metalness: 0.02 }),
    solar:    mat('solar',    { color: 0x21306a, roughness: 0.38, metalness: 0.22 }),
    nozzle:   mat('nozzle',   { color: 0x6e6b66, roughness: 0.42, metalness: 0.32 }),
    hot:      mat('hot',      { color: 0x3a322c, roughness: 0.56, metalness: 0.26 }),
    glass:    mat('glass',    { color: 0x16242e, roughness: 0.14, metalness: 0.24 }),
    red:      mat('red',      { color: 0xa02a22, roughness: 0.7,  metalness: 0.05 }),
    // A spin drive's face is an EMITTER, and it has to be lit by itself. It
    // points aft, away from every light in the scene, so a plain surface there
    // renders black however it is coloured — which is what made three drives
    // read as three empty cups. Astrophage fires at 4.26 and 18.31 μm, so the
    // visible tail of it is deep red rather than white.
    // These have to be BRIGHT. An emissive of 0x2a0d06 is 0.023 in linear light;
    // through the ACES curve that lands back at almost nothing, so a first pass
    // at these values still rendered as black discs. The sim's pipeline is HDR
    // and expects emitters to write well above 1.0 — see the note on publishing
    // temperature — so an emitter that reads on screen has to be scaled for it.
    emitPlate: mat('emitPlate', { color: 0x4a4744, emissive: 0x8c3418,
                                  emissiveIntensity: 1.3, roughness: 0.52, metalness: 0.18 }),
    emitCell:  mat('emitCell',  { color: 0x2a1410, emissive: 0xff6a30,
                                  emissiveIntensity: 2.8, roughness: 0.45, metalness: 0.10 }),
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

/**
 * A ring of engines with a real gimbal joint at each. Returns the group and
 * the per-engine pivots so the guidance command can actually move them.
 *
 * THE RING RADIUS IS DERIVED FROM THE ENGINE, not picked as a fraction of the
 * vehicle, because on a real cluster the bells are the constraint. An engine on
 * a ring of n gets 2 r sin(pi/n) of chord and its exit needs all of it; one with
 * a centre engine also has to clear that. Written as fractions of a fraction the
 * layouts came out wrong in both directions — the Saturn V's four outboard F-1s
 * were drawn inside their own centre engine, and Super Heavy's outer twenty were
 * so deeply interpenetrated that the cluster had no silhouette at all.
 *
 * Solving it instead of dialling it also gets the real numbers for free: four
 * 3.53 m F-1s land on a 3.67 m ring, which is where they are, and which is why
 * an S-IC's bells hang outside the line of the tank above them.
 */
function engineCluster(count, spread, exitD, opts = {}) {
  const g = new THREE.Group();
  const pivots = [];
  let d = exitD;                       // the DRAWN exit — see the 3-ring case
  const place = (x, z) => {
    const p = new THREE.Group();
    p.position.set(x, 0, z);
    // How far THIS bell may actually swing. A cluster is not all one engine —
    // Starship's three vacuum Raptors are rigid and sit in the same list as its
    // three gimballing ones — so the authority belongs on the pivot rather than
    // on the stage. Absent, update() leaves the pivot unclamped.
    if (opts.gimbalDeg != null) p.userData.gimbalDeg = opts.gimbalDeg;
    p.add(bell(d, opts));
    g.add(p); pivots.push(p);
  };
  // The smallest ring n bells of diameter d can stand on: neighbours clear, and
  // the centre engine clears too where there is one. `minR` is for a cluster
  // that has to miss ANOTHER cluster — Starship's vacuum Raptors have to sit
  // outside its sea-level ones, and neither call can see the other.
  const ringR = (n, centre) => Math.max(
    d * 1.04 / (2 * Math.sin(Math.PI / n)), centre ? d * 1.04 : 0, opts.minR ?? 0);
  const ring = (n, r, phase = Math.PI / n) => {
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2 + phase;
      place(Math.cos(a) * r, Math.sin(a) * r);
    }
  };

  if (count === 1) place(0, 0);
  else if (count === 5 || count === 9) {
    // A centre engine and a ring: the F-1 quincunx and the Merlin octaweb.
    place(0, 0);
    ring(count - 1, ringR(count - 1, true), count === 9 ? 0.39 : 0);
  } else if (count <= 9) {
    ring(count, ringR(count, false), count === 3 ? Math.PI / 2 : Math.PI / count);
  } else {
    // THREE CONCENTRIC RINGS, Super Heavy's arrangement — and the one layout in
    // the set where the packing does not close. Twenty 1.3 m bells want a 4.16 m
    // ring and the booster is 4.5 m in RADIUS, so something has to give: the
    // DRAWN bell shrinks until the outer ring fits inside the skirt. An engine
    // a tenth of a metre narrow is a smaller error than thirty-three that
    // interpenetrate, and it is the only one of the two you cannot see.
    const nOut = count - 13;
    const sOut = Math.sin(Math.PI / nOut);
    const rMax = opts.maxR ?? spread * 1.46;
    d = Math.min(exitD, 2 * rMax * sOut / (1 + sOut));
    const rOut = rMax - d * 0.50;
    ring(3, Math.max(d * 0.95, rOut - d * 2.80), 0);
    ring(10, rOut - d * 1.45);
    ring(nOut, rOut);
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
/** A strut between two points. Structure is most of what makes a vehicle of
 *  parts read as one object rather than as parts. */
function beam(p1, p2, r, material = M.alu, seg = 6) {
  const b = new THREE.Mesh(new THREE.CylinderGeometry(r, r, p1.distanceTo(p2), seg), material);
  b.position.copy(p1).lerp(p2, 0.5);
  b.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0),
    p2.clone().sub(p1).normalize());
  return b;
}

/**
 * A landing leg: a primary strut with its shock cartridge, a pair of secondary
 * struts, a footpad on a ball joint, and optionally the contact probe under it.
 *
 * Built straight DOWN from the hinge, with the footpad's bearing face at
 * exactly -len. THE CALLER SETS THE DEPLOYMENT ANGLE — see the pre-cant note at
 * the call sites, which is where the sign is derived — so this carries none of
 * its own. The secondaries splay in ±Z, sideways in the leg's own frame, which
 * is where they are on both the Apollo gear and the Falcon's and the only
 * arrangement that does not depend on which way the leg happens to be swung.
 */
function landingLeg(len, footR, probe = 0) {
  const g = new THREE.Group();
  const strut = new THREE.Mesh(
    new THREE.CylinderGeometry(len * 0.050, len * 0.044, len * 0.60, 10), M.dirty);
  strut.position.y = -len * 0.30; g.add(strut);
  // The crushable-honeycomb cartridge: a visibly fatter section at the bottom
  // of the primary, and the part that actually absorbs the landing.
  const cart = new THREE.Mesh(
    new THREE.CylinderGeometry(len * 0.066, len * 0.066, len * 0.36, 10), M.dirty);
  cart.position.y = -len * 0.79; g.add(cart);
  const joint = new THREE.Mesh(new THREE.SphereGeometry(len * 0.052, 10, 7), M.alu);
  joint.position.y = -len * 0.97; g.add(joint);
  // The footpad: a shallow dish, so it can lie flat on a slope instead of on
  // one edge.
  const foot = new THREE.Mesh(
    new THREE.CylinderGeometry(footR * 0.58, footR * 0.96, footR * 0.28, 18), M.dirty);
  foot.position.y = -len - footR * 0.06; g.add(foot);
  for (const s of [-1, 1]) {
    g.add(beam(new THREE.Vector3(0, len * 0.02, s * len * 0.135),
               new THREE.Vector3(0, -len * 0.60, s * len * 0.028),
               len * 0.024, M.alu));
  }
  if (probe > 0) {
    const pr = new THREE.Mesh(new THREE.CylinderGeometry(len * 0.010, len * 0.010, probe, 6), M.alu);
    pr.position.y = -len - probe / 2; g.add(pr);
    const tip = new THREE.Mesh(new THREE.ConeGeometry(len * 0.026, len * 0.04, 8), M.alu);
    tip.position.y = -len - probe; tip.rotation.x = Math.PI; g.add(tip);
  }
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

/**
 * A LOFTED HULL — the one shape a lathe cannot give you.
 *
 * `sections` are cross-sections along the stack axis (+Y), each
 * `{ y, w, h, cz, n }`: half-width in X, half-height in Z, the section's
 * centreline offset in Z, and a superellipse exponent — n = 2 is an ellipse,
 * n = 4 the rounded square an aircraft fuselage actually is.
 *
 * An orbiter is not a body of revolution. Its width and height change
 * independently along its length and its section is square-ish, so a cylinder
 * is not a poor approximation of it — it is a different object, which is what
 * made the old model read as a rocket with a plank through it.
 *
 * `t0`/`t1` bound the angular sweep, so the upper and lower shells can be built
 * as separate meshes carrying different materials. That is the whole point for
 * a vehicle whose belly is black tiles and whose back is white blanket.
 */
function loft(sections, material, { seg = 28, t0 = 0, t1 = Math.PI * 2 } = {}) {
  const S = sections.length;
  const closed = Math.abs((t1 - t0) - Math.PI * 2) < 1e-6;
  const ring = closed ? seg : seg + 1;
  const pos = [], idx = [];
  for (const c of sections) {
    const n = c.n || 2, e = 2 / n;
    for (let i = 0; i < ring; i++) {
      const t = t0 + (t1 - t0) * (i / seg);
      const ct = Math.cos(t), st = Math.sin(t);
      // Superellipse in the exponent form, so one parameter carries the section
      // from a circle to a square without changing the vertex count.
      pos.push((c.w || 0) * Math.sign(ct) * Math.abs(ct) ** e,
               c.y,
               (c.h || 0) * Math.sign(st) * Math.abs(st) ** e + (c.cz || 0));
    }
  }
  for (let s = 0; s < S - 1; s++) {
    for (let i = 0; i < seg; i++) {
      const a = s * ring + i, b = s * ring + (i + 1) % ring;
      // Wound outward: +t is counter-clockwise in XZ, so (a, b2, b) is the
      // pair that faces away from the axis. The other order renders inside-out
      // and is invisible against a black sky until you fly through it.
      idx.push(a, b + ring, b, a, a + ring, b + ring);
    }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setIndex(idx);
  g.computeVertexNormals();
  return new THREE.Mesh(g, material);
}

/** NACA symmetric thickness distribution, as a fraction of chord. */
function naca(u, t) {
  return 5 * t * (0.2969 * Math.sqrt(u) - 0.1260 * u - 0.3516 * u * u
                + 0.2843 * u ** 3 - 0.1015 * u ** 4);
}

/**
 * A WING from real spanwise stations, each `{ x, yLE, chord, thick, cz }`:
 * where the leading edge is at that station, how long the chord is there and
 * how thick the section is. A kinked planform — the orbiter's double delta — is
 * just a station at the kink, so nothing special is needed to express one.
 *
 * The section is an airfoil rather than a rectangle because a flat plate has no
 * leading edge, and on a re-entry wing the leading edge is the part you look
 * at: it is the hottest structure on the vehicle and it is a different colour
 * from everything around it.
 *
 * Upper and lower surfaces come back as separate meshes — a Shuttle wing is
 * white on top and black underneath, and that split IS the shape's read.
 */
function wingPanel(stations, matUp, matLo, { nChord = 14, sign = 1 } = {}) {
  const build = (side) => {
    const pos = [], idx = [];
    for (const st of stations) {
      for (let i = 0; i <= nChord; i++) {
        const u = i / nChord;
        pos.push(sign * st.x, st.yLE - u * st.chord,
                 side * naca(u, st.thick) * st.chord + (st.cz || 0));
      }
    }
    const R = nChord + 1;
    for (let s = 0; s < stations.length - 1; s++) {
      for (let i = 0; i < nChord; i++) {
        const a = s * R + i, b = a + 1;
        // Winding follows the surface's outward side, and mirroring the panel
        // to the other wing reverses it — so `sign` has to flip it back or the
        // left wing is inside-out.
        const f = (side * sign > 0);
        idx.push(...(f ? [a, b, b + R, a, b + R, a + R]
                       : [a, b + R, b, a, a + R, b + R]));
      }
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setIndex(idx); g.computeVertexNormals();
    return g;
  };
  const grp = new THREE.Group();
  grp.add(new THREE.Mesh(build(+1), matUp));
  grp.add(new THREE.Mesh(build(-1), matLo));
  return grp;
}

/**
 * A TUBE SWEPT ALONG A CURVED CENTRELINE. `pts` is the centreline; the tube is
 * built by carrying a frame along it rather than by orienting each ring
 * independently, because the naive frame (a fresh "up" per ring) flips wherever
 * the tangent passes near vertical and the tube turns inside out at that ring.
 *
 * PARALLEL TRANSPORT is the fix: start with any normal perpendicular to the
 * first tangent, then rotate it by the same rotation that carried the previous
 * tangent to this one. It accumulates no twist of its own, which is what a
 * pressure vessel bent around something needs — the seams have to stay straight.
 */
function bentTube(pts, r, material, { radial = 20 } = {}) {
  const N = pts.length;
  const tan = pts.map((_, i) => pts[Math.min(i + 1, N - 1)].clone()
    .sub(pts[Math.max(i - 1, 0)]).normalize());
  // A seed normal: any axis not parallel to the first tangent, made perpendicular.
  const nrm = [new THREE.Vector3(0, 0, 1)];
  if (Math.abs(nrm[0].dot(tan[0])) > 0.9) nrm[0].set(1, 0, 0);
  nrm[0].sub(tan[0].clone().multiplyScalar(nrm[0].dot(tan[0]))).normalize();
  const q = new THREE.Quaternion();
  for (let i = 1; i < N; i++) {
    q.setFromUnitVectors(tan[i - 1], tan[i]);
    nrm.push(nrm[i - 1].clone().applyQuaternion(q).normalize());
  }
  const pos = [], idx = [], bi = new THREE.Vector3();
  for (let i = 0; i < N; i++) {
    bi.crossVectors(tan[i], nrm[i]).normalize();
    for (let j = 0; j < radial; j++) {
      const a = (j / radial) * Math.PI * 2, c = Math.cos(a) * r, sn = Math.sin(a) * r;
      pos.push(pts[i].x + nrm[i].x * c + bi.x * sn,
               pts[i].y + nrm[i].y * c + bi.y * sn,
               pts[i].z + nrm[i].z * c + bi.z * sn);
    }
  }
  for (let i = 0; i < N - 1; i++) {
    for (let j = 0; j < radial; j++) {
      const a = i * radial + j, b = i * radial + (j + 1) % radial;
      idx.push(a, b, b + radial, a, b + radial, a + radial);
    }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setIndex(idx); g.computeVertexNormals();
  return { mesh: new THREE.Mesh(g, material), tan, nrm };
}

/**
 * A centreline that runs STRAIGHT and then bends through a circular arc in the
 * XY plane, ending with a short straight run on the new heading. Returned in the
 * radial/axial frame — x is distance from the ship's axis — so one path serves
 * all three of a cluster by rotating the group it is put in.
 */
function bentPath(x0, y0, yBend, turnR, turnDeg, runOut, nStraight = 6, nArc = 10) {
  const pts = [], th = turnDeg * Math.PI / 180, cx = x0 - turnR;
  for (let i = 0; i <= nStraight; i++) {
    pts.push(new THREE.Vector3(x0, y0 + (yBend - y0) * (i / nStraight), 0));
  }
  for (let i = 1; i <= nArc; i++) {
    const t = th * (i / nArc);
    pts.push(new THREE.Vector3(cx + turnR * Math.cos(t), yBend - turnR * Math.sin(t), 0));
  }
  const end = pts[pts.length - 1];
  pts.push(new THREE.Vector3(end.x - Math.sin(th) * runOut, end.y - Math.cos(th) * runOut, 0));
  return pts;
}

/** A tangent ogive nose — the curve an actual fairing is struck on, which is
 *  visibly fuller than the half-ellipse a naive lathe produces. */
function ogive(L, D, material, seg = 28) {
  const r = D / 2, rho = (r * r + L * L) / (2 * r), pts = [];
  for (let i = 0; i <= 14; i++) {
    const y = (i / 14) * L;
    // Full radius at the BASE, tapering to the tip: the y term is measured from
    // the base, not the apex. With it the other way round the curve is turned
    // inside out and every nose on the vehicle renders as a funnel.
    pts.push(new THREE.Vector2(Math.max(Math.sqrt(Math.max(rho * rho - y * y, 0)) - rho + r, 1e-3), y));
  }
  return new THREE.Mesh(new THREE.LatheGeometry(pts, seg), material);
}

/**
 * A SPHERE-CONE heat shield: a spherical nose cap of radius `noseR` blended
 * into a straight flank at `half` degrees, closed by a shoulder radius. Every
 * Mars lander since Viking has flown this shape at 70°, and it is the shape —
 * blunt, so the shock stands off and the gas heats instead of the vehicle —
 * rather than a cone, which is what the old model drew.
 */
function sphereCone(D, noseR, halfDeg, material, seg = 32) {
  const R = D / 2, half = halfDeg * Math.PI / 180, shoulder = R * 0.06;
  const pts = [];
  // The cap runs to the tangent point, where the sphere's slope matches the flank.
  const tA = Math.PI / 2 - half;
  for (let i = 0; i <= 10; i++) {
    const a = (i / 10) * tA;
    pts.push(new THREE.Vector2(noseR * Math.sin(a), noseR * (1 - Math.cos(a))));
  }
  const xT = noseR * Math.sin(tA), yT = noseR * (1 - Math.cos(tA));
  const xF = R - shoulder * Math.cos(half);
  pts.push(new THREE.Vector2(xF, yT + (xF - xT) / Math.tan(half)));
  const yF = yT + (xF - xT) / Math.tan(half);
  for (let i = 1; i <= 5; i++) {                       // the shoulder round-over
    const a = half + (i / 5) * (Math.PI / 2 - half);
    pts.push(new THREE.Vector2(xF + shoulder * (Math.cos(a) - Math.cos(half)),
                               yF + shoulder * (Math.sin(a) - Math.sin(half))));
  }
  // WHICH WAY IT POINTS IS THE WHOLE CONTRACT, so it is fixed here rather than
  // left to a caller's rotation: the apex is the LOWEST point and the SHOULDER
  // sits at y = 0, which is the plane the backshell bolts to. Built apex-at-
  // the-origin and flipped by the caller, the vehicle ends up with its heat
  // shield on top — a shape that would kill the vehicle it is meant to protect.
  const top = pts[pts.length - 1].y;
  for (const p of pts) p.y -= top;
  const g = new THREE.LatheGeometry(pts, seg);
  g.computeVertexNormals();
  return new THREE.Mesh(g, material);
}

/** An open lattice tower — the Apollo escape tower is mostly air, and drawing
 *  it as a solid cone is what made the old Saturn V's nose read as a crayon. */
function lattice(h, wBot, wTop, material) {
  const g = new THREE.Group(), t = wBot * 0.055;
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const pts = [new THREE.Vector3(Math.cos(a) * wBot / 2, 0, Math.sin(a) * wBot / 2),
                 new THREE.Vector3(Math.cos(a) * wTop / 2, h, Math.sin(a) * wTop / 2)];
    const len = pts[0].distanceTo(pts[1]);
    const leg = new THREE.Mesh(new THREE.CylinderGeometry(t, t, len, 6), material);
    leg.position.copy(pts[0]).lerp(pts[1], 0.5);
    leg.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0),
      pts[1].clone().sub(pts[0]).normalize());
    g.add(leg);
  }
  for (let k = 1; k <= 3; k++) {                        // cross bracing
    const y = h * k / 4, w = wBot + (wTop - wBot) * (k / 4);
    const ring = new THREE.Mesh(new THREE.TorusGeometry(w / 2 * 0.99, t * 0.7, 4, 4), material);
    ring.rotation.x = Math.PI / 2; ring.rotation.z = Math.PI / 4; ring.position.y = y;
    g.add(ring);
  }
  return g;
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

  // THE AUTHORED MODEL, if one loaded. Everything past this point is the
  // procedural build: real dimensions out of Three.js primitives, and still
  // the only thing that draws when the .glb is missing — which it is on a
  // fresh clone, because the mesh is a build artifact and the .py file beside
  // it is the model. See sim/flight/craftassets.js.
  //
  // The authored subtree replaces the stage's CONTENTS, not its placement:
  // buildCraft assigns this group's position a moment later, so the model goes
  // inside it rather than being it.
  const authored = craftStage(ctx?.id, spec.key);
  if (authored) {
    g.add(authored);
    bindParts(authored, parts, spec);
    return { group: g, parts };
  }

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

  // ---- the default: a cylindrical stage with engines under it.
  // A stage's L is its WHOLE length, so a nose eats into the barrel rather than
  // being stacked on top of it.
  const noseL = look.tank ? D * 1.45 : look.nosecone ? D * 1.55 : 0;
  // A stage that carries a nose OR an interstage needs a FLAT top for it to sit
  // on: the lathe's top dome curves away underneath and leaves a pinched gap at
  // every joint, which is what read as odd spacing up the Saturn V. The aft end
  // is near-flat for the same reason — it butts onto a thrust structure or the
  // interstage below, and no real stage tapers there either.
  const body = tank(L - noseL, D, skin,
    { domeBot: 0.02, ...((noseL > 0 || look.interstage) ? { domeTop: 0 } : {}) });
  g.add(body);
  if (look.soot) { const s = stripe(D, 0, L * 0.12, M.soot); g.add(s); }
  if (look.band) g.add(stripe(D, L * 0.62, L * 0.10, M.black));
  if (look.pattern === 'saturn') {
    // THE ROLL PATTERN. It is not decoration: the black quadrants were painted
    // on so the tracking cameras could measure the vehicle's roll attitude
    // optically during first-stage flight. That is why they are asymmetric
    // quarter-panels rather than full bands — a full band tells you nothing
    // about roll — and getting that right is most of what makes a white
    // cylinder read as a Saturn V.
    g.add(stripe(D, 0, L * 0.075, M.black));            // aft skirt
    g.add(stripe(D, L * 0.955, L * 0.045, M.black));    // forward skirt
    for (const [y, h] of [[L * 0.075, L * 0.115], [L * 0.545, L * 0.105]]) {
      for (let k = 0; k < 4; k += 2) {
        const q = new THREE.Mesh(new THREE.CylinderGeometry(
          D / 2 * 1.004, D / 2 * 1.004, h, 10, 1, true, k * Math.PI / 2, Math.PI / 2), M.black);
        q.position.y = y + h / 2; g.add(q);
      }
    }
    // UNITED STATES down the side, and the flag opposite it.
    const usa = new THREE.Mesh(new THREE.CylinderGeometry(
      D / 2 * 1.006, D / 2 * 1.006, L * 0.20, 8, 1, true, -0.34, 0.68), M.black);
    usa.position.y = L * 0.78; g.add(usa);
    const flag = new THREE.Mesh(new THREE.CylinderGeometry(
      D / 2 * 1.006, D / 2 * 1.006, L * 0.075, 6, 1, true, Math.PI - 0.24, 0.48), M.red);
    flag.position.y = L * 0.80; g.add(flag);
  }
  if (look.hotStage) {
    const hs = new THREE.Mesh(new THREE.CylinderGeometry(D / 2 * 0.99, D / 2 * 0.99, L * 0.03, 28, 1, true), M.hot);
    hs.position.y = L * 0.995; g.add(hs);
  }
  if (look.interstage) {
    // An interstage ADAPTS: the Saturn V's S-II/S-IVB piece goes 10.06 m to
    // 6.6 m and the spacecraft adapter above it goes 6.6 m to 3.9 m. Drawing it
    // as a cylinder at the lower stage's diameter is what made the whole
    // vehicle one width from the engines to the escape tower.
    const topD = ctx?.nextD ?? D;
    const ov = Math.min(0.35, look.interstage * 0.18);   // sink into both ends
    const is = new THREE.Mesh(
      new THREE.CylinderGeometry(topD / 2, D / 2, look.interstage + ov * 2, 28, 1, true),
      look.interstageSkin === 'skin' ? skin
        : look.interstageSkin === 'black' ? M.black : M.dirty);
    is.position.y = L + look.interstage / 2 - ov * 0.0; g.add(is);
    if (Math.abs(topD - D) < 0.05) {
      // A cylindrical interstage gets the separation-plane band that a real one
      // has; a conical one does not need it, its own silhouette says where it is.
      const bd = new THREE.Mesh(new THREE.TorusGeometry(D / 2 * 1.005, D * 0.006, 6, 32), M.black);
      bd.rotation.x = Math.PI / 2; bd.position.y = L + look.interstage; g.add(bd);
    }
  }
  if (look.aftSkirt) {
    const sk = new THREE.Mesh(new THREE.CylinderGeometry(D / 2, D / 2 * 1.02, L * 0.14, 24, 1, true), M.dirty);
    sk.position.y = L * 0.07; g.add(sk);
  }
  if (look.nosecone) {
    const n = ogive(noseL, D, skin); n.position.y = L - noseL; g.add(n);
  }
  if (look.tiles) {
    // heat tiles on the windward half only, which is what they are for
    const sh = new THREE.Mesh(new THREE.CylinderGeometry(D / 2 * 1.005, D / 2 * 1.005, L * 0.9, 28, 1, true, -Math.PI / 2, Math.PI), M.tiles);
    sh.position.y = L * 0.45; g.add(sh);
  }
  if (look.tank) {
    // Shuttle ET. Its 46.9 m is the WHOLE tank, ogive included, so the barrel
    // has to be shortened to make room for the nose rather than the nose added
    // on top — otherwise the stack stands 8 m taller than the real one.
    // `g.add()` returns the GROUP, not the mesh — chaining `.position` onto it
    // moves the whole stage and leaves the nose buried at the tank's base.
    const nose = ogive(noseL, D, skin, 24);
    nose.position.y = L - noseL; g.add(nose);
    // The intertank is the one stringered band on an otherwise smooth tank, and
    // it is the feature that stops 47 m of orange foam reading as a crayon.
    const itY = L * 0.545, itH = L * 0.115;
    for (let i = 0; i < 40; i++) {
      const a = i / 40 * Math.PI * 2;
      const rib = new THREE.Mesh(new THREE.BoxGeometry(0.16, itH, 0.16), M.foam);
      rib.position.set(Math.cos(a) * D / 2 * 1.005, itY + itH / 2, Math.sin(a) * D / 2 * 1.005);
      rib.rotation.y = -a; g.add(rib);
    }
    for (const yy of [itY, itY + itH]) {
      const b = new THREE.Mesh(new THREE.TorusGeometry(D / 2 * 1.012, 0.10, 6, 40), M.foam);
      b.rotation.x = Math.PI / 2; b.position.y = yy; g.add(b);
    }
    // The LO2 feedline and the pressurisation lines run the length of the tank
    // on the orbiter's side — the only straight lines on the whole object.
    for (const [ax, r] of [[0.34, 0.24], [-0.34, 0.13]]) {
      const pipe = new THREE.Mesh(new THREE.CylinderGeometry(r, r, L * 0.80, 10), M.dirty);
      pipe.position.set(Math.sin(ax) * D / 2 * 1.06, L * 0.40, Math.cos(ax) * D / 2 * 1.06);
      g.add(pipe);
    }
  }

  // engines. `engineOn` names ANOTHER stage that physically carries them — the
  // Shuttle's SSMEs are on the orbiter and fed from the tank — so the stage
  // that owns the propellant must not also draw the bells.
  if (spec.engine && spec.count > 0 && !spec.engineOn) {
    const spread = D * 0.30;
    const ec = engineCluster(spec.count, spread, spec.engine.exitD || D * 0.2,
                             { gimbalDeg: spec.engine.gimbal, maxR: D * 0.44 });
    ec.group.position.y = -0.02;
    g.add(ec.group);
    parts.gimbals = ec.pivots;
    // a thrust structure so the bells are not floating
    const ts = new THREE.Mesh(new THREE.CylinderGeometry(D / 2 * 0.92, D / 2 * 0.80, D * 0.16, 20, 1, true), M.soot);
    ts.position.y = D * 0.05; g.add(ts);
  }
  if (spec.vacEngine && spec.vacCount) {
    // `minR`: these have to sit outside the sea-level cluster drawn above, and
    // neither call can see the other. Starship's 2.4 m vacuum bells alongside
    // its 1.3 m sea-level ones need 2.1 m of ring before the two stop touching.
    const ec = engineCluster(spec.vacCount, D * 0.44, spec.vacEngine.exitD,
                             { gimbalDeg: spec.vacEngine.gimbal, minR: D * 0.28 });
    ec.group.position.y = -0.02; g.add(ec.group);
    parts.gimbals.push(...ec.pivots);
  }
  if (spec.gridFins) {
    const finY = L + (look.interstage || 0) * 0.72;
    for (let i = 0; i < spec.gridFins; i++) {
      const a = (i / spec.gridFins) * Math.PI * 2 + 0.4;
      const hinge = new THREE.Group();
      hinge.position.set(Math.cos(a) * D / 2, finY, Math.sin(a) * D / 2);
      hinge.rotation.y = -a;
      // Same pre-cant argument as the legs, with the fins' own 1.35 rad of
      // travel: DEPLOYED is square to the body, so the fin carries +1.35 and
      // the hinge gives it back. Without it the fins started square and the
      // deploy laid them flat along the interstage — exactly backwards.
      const arm = new THREE.Group();
      arm.rotation.z = 1.35;
      const fin = gridFin(D * 0.42);
      fin.position.set(D * 0.22, 0, 0);
      arm.add(fin);
      hinge.add(arm);
      g.add(hinge);
      parts.fins.push(hinge);
    }
  }
  if (spec.legs) {
    // THE PRE-CANT IS WHAT MAKES THE DEPLOYED POSE RIGHT, and its sign is worth
    // deriving rather than guessing. update() deploys by assigning the hinge
    // rotation.z = -1.15 d, and NEGATIVE z about a hinge whose local +X is
    // outboard swings a leg built along -Y INWARD, under the vehicle. With no
    // pre-cant at all a leg does not splay: it folds in and tucks under the
    // engines, which is what all four of these were doing.
    //
    // Deployed we want 60 degrees out from the vertical, i.e. rotation.z =
    // +1.047; the hinge contributes -1.15, so the leg carries the difference.
    // Stowed (d = 0) that leaves it lying up along the body, which is where the
    // leg bays are.
    for (let i = 0; i < spec.legs; i++) {
      const a = (i / spec.legs) * Math.PI * 2 + 0.78;
      const hinge = new THREE.Group();
      hinge.position.set(Math.cos(a) * D / 2 * 0.92, L * 0.055, Math.sin(a) * D / 2 * 0.92);
      hinge.rotation.y = -a;
      const leg = landingLeg(D * 0.82, D * 0.10);
      leg.rotation.z = 1.047 + 1.15;
      hinge.add(leg);
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
  if (look.fins) {
    // The S-IC's four fins and the four conical fairings ahead of them. They
    // are the widest part of the vehicle — 18.8 m across the fin tips against a
    // 10.06 m tank — so leaving them off did not just lose detail, it lost the
    // stage's proportions at the one place anybody looks at it.
    for (let i = 0; i < look.fins; i++) {
      const a = (i / look.fins) * Math.PI * 2 + Math.PI / 4;
      // Everything for one fin station hangs off a single swung group, so the
      // fairing and the fin cannot drift apart from each other.
      const bay = new THREE.Group(); bay.rotation.y = -a;
      // Fairing: a faired cone over the outboard engine's actuators and the
      // retro-rockets, tapering into the tank wall.
      const fair = new THREE.Mesh(
        new THREE.CylinderGeometry(D * 0.055, D * 0.165, L * 0.215, 14, 1, true), M.white);
      fair.position.set(D / 2 * 0.90, L * 0.150, 0);
      bay.add(fair);
      // It is faired INTO the tank, not stood off it: a half-round fillet down
      // the joint is what stops it reading as a spike taped to the side.
      const fillet = new THREE.Mesh(
        new THREE.CylinderGeometry(D * 0.075, D * 0.075, L * 0.215, 10, 1, true,
          Math.PI / 2, Math.PI), M.white);
      fillet.position.set(D / 2 * 0.99, L * 0.150, 0); bay.add(fillet);
      // Fin: a clipped swept delta, built from a wing panel so it has a real
      // leading edge instead of being a slab.
      const fin = wingPanel([
        { x: D * 0.48, yLE: L * 0.150, chord: L * 0.128, thick: 0.09 },
        { x: D * 0.68, yLE: L * 0.098, chord: L * 0.105, thick: 0.10 },
        { x: D * 0.93, yLE: L * 0.030, chord: L * 0.072, thick: 0.12 },
      ], M.black, M.black);
      bay.add(fin);                                   // span is already +X = outward
      g.add(bay);
    }
  }
  if (look.octaweb) {
    // The octaweb is a visible black machined structure, not a smooth base.
    const ow = new THREE.Mesh(new THREE.CylinderGeometry(D / 2 * 1.01, D / 2 * 0.97, D * 0.26, 8), M.black);
    ow.position.y = D * 0.13; ow.rotation.y = Math.PI / 8; g.add(ow);
    // Four stowed landing legs, lying along the body as dark strakes. They are
    // there for the whole ascent and are half the booster's aft silhouette.
    for (let i = 0; i < 4; i++) {
      const a = (i / 4) * Math.PI * 2 + 0.78;
      const holder = new THREE.Group(); holder.rotation.y = -a;
      const bayL = D * 1.15;
      const fair = new THREE.Mesh(new THREE.CylinderGeometry(
        D * 0.075, D * 0.075, bayL, 8, 1, true, -Math.PI / 2, Math.PI), M.black);
      fair.position.set(D / 2 * 0.985, D * 0.14 + bayL / 2, 0);
      holder.add(fair);
      // The nose fairing over the top of the stowed leg, which is the only bit
      // of it that stands out from the body.
      const tip = new THREE.Mesh(new THREE.ConeGeometry(D * 0.075, D * 0.20, 8, 1, true), M.black);
      tip.position.set(D / 2 * 0.985, D * 0.14 + bayL + D * 0.10, 0);
      holder.add(tip);
      g.add(holder);
    }
  }
  if (spec.rcs) g.add(rcsRing(D, L * 0.88, 4));
  return { group: g, parts };
}

/**
 * THE SOLIDS. A pair, and the vehicle stands on them: y = 0 here is the NOZZLE
 * EXIT PLANE, level with the pad, so the whole 45.5 m is measured the way the
 * published number is rather than from an arbitrary datum.
 *
 * A solid's read is its joints. The RSRM ships as four casting segments bolted
 * together with tang-and-clevis field joints, and those four raised bands — plus
 * the systems tunnel running the full length between them — are what separate a
 * booster from a white pipe at any distance you are ever likely to see it from.
 */
function buildSRB(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D, L = spec.L, r = D / 2;
  for (const side of [-1, 1]) {
    const b = new THREE.Group();
    b.position.x = side * 6.35;

    // Aft skirt: the flared structure that actually carries the stack, with the
    // nozzle recessed inside it. It is wider than the motor case.
    const skirt = new THREE.Mesh(
      new THREE.CylinderGeometry(r * 1.02, r * 1.30, L * 0.098, 24, 1, true), M.dirty);
    skirt.position.y = L * 0.049; b.add(skirt);
    // The nozzle hangs on a PIVOT, and it has to: parts.gimbals is where the
    // PLUMES hang as well as where the deflection is applied, so a booster with
    // no pivot burns invisibly — and these two make 71% of the thrust at
    // liftoff. The RSRM's nozzle really does vector 8 degrees, which is the
    // stack's only control authority until the SSMEs have any.
    const nzp = new THREE.Group();
    nzp.position.y = L * 0.085;
    nzp.userData.gimbalDeg = spec.engine.gimbal;
    nzp.add(bell(spec.engine.exitD || D * 0.95, { ratio: 7.7, chamber: false }));
    b.add(nzp); parts.gimbals.push(nzp);

    // Motor case: four segments, so four field joints.
    const caseY = L * 0.098, caseL = L * 0.735;
    const body = new THREE.Mesh(new THREE.CylinderGeometry(r, r, caseL, 28, 1, true), M.white);
    body.position.y = caseY + caseL / 2; b.add(body);
    for (let i = 1; i <= 4; i++) {
      const j = new THREE.Mesh(new THREE.TorusGeometry(r * 1.018, D * 0.022, 6, 28), M.dirty);
      j.rotation.x = Math.PI / 2; j.position.y = caseY + caseL * i / 5; b.add(j);
    }
    // Systems tunnel — the cable raceway down the outboard face.
    const tun = new THREE.Mesh(new THREE.BoxGeometry(D * 0.10, caseL * 0.98, D * 0.07), M.dirty);
    tun.position.set(side * r * 0.99, caseY + caseL / 2, 0); b.add(tun);

    // Forward skirt, frustum and nose cap. The frustum is where the drogue and
    // main parachutes live, which is why it is a separate piece that comes off.
    const fsY = caseY + caseL, fsL = L * 0.070;
    const fs = new THREE.Mesh(new THREE.CylinderGeometry(r, r, fsL, 24, 1, true), M.white);
    fs.position.y = fsY + fsL / 2; b.add(fs);
    const frL = L * 0.048;
    const fr = new THREE.Mesh(new THREE.CylinderGeometry(r * 0.72, r, frL, 24, 1, true), M.white);
    fr.position.y = fsY + fsL + frL / 2; b.add(fr);
    const capY = fsY + fsL + frL, capL = L - capY;
    const cap = ogive(capL, r * 1.44, M.white, 24); cap.position.y = capY; b.add(cap);

    // The forward attach fitting and the aft struts: the booster does not touch
    // the tank, it is held off it, and the gap is a structural fact.
    for (const [y, len] of [[fsY + fsL * 0.4, 0.9], [caseY + caseL * 0.06, 1.1],
                            [caseY + caseL * 0.13, 1.1]]) {
      const st = new THREE.Mesh(new THREE.CylinderGeometry(0.16, 0.16, len, 8), M.dirty);
      st.position.set(-side * (r + len / 2), y, 0); st.rotation.z = Math.PI / 2;
      b.add(st);
    }
    g.add(b);
  }
  return { group: g, parts };
}

/**
 * THE ORBITER. Built nose-up along +Y like every other stage, with the wings on
 * ±X and the BELLY on −Z — which is the side that faces the tank, because the
 * orbiter rides the External Tank belly-down.
 *
 * The old model was a lathe with a plank through it, and it was wrong in the
 * way that matters: an orbiter is not a body of revolution. Its width and
 * height vary independently, its section is a rounded square, and its planform
 * has a kink. All three are what `loft` and `wingPanel` exist for.
 *
 * The white/black split is not decoration either — it is the thermal design
 * made visible. Reinforced carbon-carbon and black HRSI tiles go where the
 * plasma does: the underside, the leading edges, the nose cap. Everything that
 * only ever sees space is white LRSI and felt blanket. Getting that boundary in
 * the right place does more for the read than any amount of panel detail.
 */
function buildOrbiter(spec, parts) {
  const g = new THREE.Group();
  const L = spec.L;                                     // 37.2 m
  const f = (u) => u * L;

  // ---- fuselage: stations from the base up, half-width / half-height in m.
  // `n` carries the section from near-circular at the nose to the rounded
  // square of the payload bay, which is a box with a lid.
  const sec = [
    { y: f(0.000), w: 2.35, h: 2.60, cz: 0.10, n: 3.0 },
    { y: f(0.030), w: 2.62, h: 2.86, cz: 0.06, n: 3.4 },
    { y: f(0.090), w: 2.78, h: 2.92, cz: 0.02, n: 3.6 },
    { y: f(0.200), w: 2.80, h: 2.86, cz: 0.00, n: 3.6 },
    { y: f(0.400), w: 2.80, h: 2.80, cz: 0.00, n: 3.6 },
    { y: f(0.640), w: 2.80, h: 2.74, cz: 0.00, n: 3.5 },
    { y: f(0.720), w: 2.72, h: 2.58, cz: 0.02, n: 3.2 },
    { y: f(0.800), w: 2.44, h: 2.26, cz: 0.06, n: 2.9 },
    { y: f(0.865), w: 2.02, h: 1.84, cz: 0.10, n: 2.7 },
    { y: f(0.925), w: 1.42, h: 1.30, cz: 0.12, n: 2.5 },
    { y: f(0.968), w: 0.78, h: 0.72, cz: 0.12, n: 2.3 },
    { y: f(1.000), w: 0.10, h: 0.10, cz: 0.10, n: 2.2 },
  ];
  // Two shells, split at the waterline: white blanket over, black tile under.
  g.add(loft(sec, M.white, { seg: 30, t0: 0, t1: Math.PI }));
  g.add(loft(sec, M.tiles, { seg: 30, t0: Math.PI, t1: Math.PI * 2 }));

  // ---- wing: a double delta. The kink at x = 5.4 m is the whole planform —
  // an 79° glove that keeps the shock attached at hypersonic speed, then a 45°
  // outer panel that still has a usable lift curve at 200 knots on final.
  const ws = [
    { x: 2.52, yLE: f(0.700), chord: f(0.673), thick: 0.055, cz: -1.30 },
    { x: 3.80, yLE: f(0.560), chord: f(0.533), thick: 0.060, cz: -1.20 },
    { x: 5.40, yLE: f(0.360), chord: f(0.333), thick: 0.070, cz: -1.10 },
    { x: 8.60, yLE: f(0.245), chord: f(0.218), thick: 0.085, cz: -0.85 },
    { x: 11.30, yLE: f(0.147), chord: f(0.112), thick: 0.100, cz: -0.62 },
    { x: 11.90, yLE: f(0.138), chord: f(0.062), thick: 0.110, cz: -0.58 },
  ];
  for (const sgn of [1, -1]) g.add(wingPanel(ws, M.white, M.tiles, { sign: sgn }));

  // ---- vertical tail. Built in the wing's own frame (span on X) and rotated
  // upright, so one function serves both surfaces.
  const ts = [
    { x: 0.0, yLE: f(0.185), chord: 6.10, thick: 0.13 },
    { x: 3.4, yLE: f(0.140), chord: 4.85, thick: 0.13 },
    { x: 6.6, yLE: f(0.100), chord: 3.55, thick: 0.14 },
    { x: 7.9, yLE: f(0.083), chord: 2.75, thick: 0.15 },
  ];
  const tail = wingPanel(ts, M.white, M.white);
  tail.rotation.y = -Math.PI / 2;                       // span X → +Z, i.e. up
  tail.position.z = 2.55;
  g.add(tail);

  // ---- OMS pods: the two bulges either side of the fin root. They are the
  // orbiter's own engines, and the only ones it keeps after the tank is gone.
  for (const sgn of [-1, 1]) {
    const pod = loft([
      { y: f(0.020), w: 0.55, h: 0.55, n: 2.4 },
      { y: f(0.060), w: 1.05, h: 1.00, n: 2.6 },
      { y: f(0.120), w: 1.25, h: 1.15, n: 2.6 },
      { y: f(0.175), w: 1.05, h: 0.95, n: 2.5 },
      { y: f(0.215), w: 0.45, h: 0.42, n: 2.4 },
    ], M.white, { seg: 18 });
    pod.position.set(sgn * 2.05, 0, 1.95);
    g.add(pod);
    // The OMS bell itself, canted out and down the way the real one is.
    const b = bell(1.35, { ratio: 55 });
    b.position.set(sgn * 2.15, f(0.035), 1.55);
    b.rotation.x = -0.30; b.rotation.z = sgn * 0.18;
    g.add(b);
    // Forward RCS is in the nose, aft RCS in the pod — both visible as clusters
    // of black nozzle mouths, which is how you actually spot them in a photo.
    for (let k = 0; k < 3; k++) {
      const n2 = new THREE.Mesh(new THREE.CylinderGeometry(0.11, 0.13, 0.22, 8), M.black);
      n2.position.set(sgn * (2.7 + k * 0.1), f(0.19 + k * 0.006), 2.3 - k * 0.5);
      n2.rotation.z = sgn * Math.PI / 2; g.add(n2);
    }
  }

  // ---- three SSMEs, in the triangle they actually sit in: one high on the
  // centreline, two low and outboard. They gimbal, so each gets a pivot.
  const ec = new THREE.Group(), piv = [];
  for (const [x, z] of [[0, 1.30], [-1.55, -0.55], [1.55, -0.55]]) {
    const p = new THREE.Group();
    p.position.set(x, f(0.045), z);
    p.add(bell(2.30, { ratio: 69 }));
    ec.add(p); piv.push(p);
  }
  g.add(ec); parts.gimbals = piv;
  // The boat-tail shroud the engines hang out of.
  const aft = loft([{ y: f(0.000), w: 2.30, h: 2.45, cz: 0.10, n: 3.0 },
                    { y: f(0.055), w: 2.70, h: 2.90, cz: 0.05, n: 3.4 }], M.black, { seg: 24 });
  g.add(aft);

  // ---- body flap: the slab under the engines that trims the vehicle in
  // hypersonic flight and shields the bells. Small, and very recognisable.
  const flap = new THREE.Mesh(new THREE.BoxGeometry(4.3, 2.3, 0.36), M.tiles);
  flap.position.set(0, f(0.028), -2.35); flap.rotation.x = 0.12;
  g.add(flap); parts.flaps.push(flap);

  // ---- payload bay doors, closed: two long panels along the top with the
  // radiator lines that live on their inner face showing as seams.
  for (const sgn of [-1, 1]) {
    const door = loft([
      { y: f(0.215), w: 2.62, h: 2.62, n: 3.4 },
      { y: f(0.640), w: 2.62, h: 2.60, n: 3.4 },
    ], M.dirty, { seg: 14, t0: sgn > 0 ? 0.10 : Math.PI - 0.10,
                  t1: sgn > 0 ? Math.PI / 2 - 0.03 : Math.PI / 2 + 0.03 });
    g.add(door);
  }

  // ---- forward flight deck windows. Nothing else on the vehicle says "there
  // are people in this", and they were previously placed at a fixed z that sat
  // INSIDE the hull at that station, so they never showed at all. The surface
  // has to be evaluated: the section here is a superellipse, so solve it for z
  // at the window's own x and stand the glass a few centimetres proud of it.
  const winSec = { w: 1.72, h: 1.56, cz: 0.11, n: 2.7 };
  const surfZ = (x) => winSec.cz + winSec.h *
    Math.pow(Math.max(1 - Math.pow(Math.abs(x) / winSec.w, winSec.n), 0), 1 / winSec.n);
  for (let i = 0; i < 6; i++) {
    const a = (i - 2.5) / 2.5;                          // −1 … +1 across the front
    const x = a * 1.30;
    const win = new THREE.Mesh(new THREE.BoxGeometry(0.52, 0.46, 0.10), M.glass);
    win.position.set(x, f(0.897), surfZ(x) + 0.02);
    win.rotation.set(-0.62, -a * 0.42, 0);
    g.add(win);
  }
  // The two overhead windows, flat on the crown behind the forward six.
  for (const dx of [-0.42, 0.42]) {
    const ov = new THREE.Mesh(new THREE.BoxGeometry(0.44, 0.44, 0.10), M.glass);
    ov.position.set(dx, f(0.856), surfZ(dx) + 0.10);
    ov.rotation.x = -0.05; g.add(ov);
  }
  // Side hatch, on the port side of the crew cabin.
  const hatch = new THREE.Mesh(new THREE.CylinderGeometry(0.50, 0.50, 0.08, 18), M.dirty);
  hatch.position.set(-1.86, f(0.845), 0.55);
  hatch.rotation.set(0, 0, Math.PI / 2); g.add(hatch);
  // Black nose cap: the hottest single point on the vehicle, ~1 600 °C.
  const cap = loft([
    { y: f(0.962), w: 0.90, h: 0.84, cz: 0.10, n: 2.3 },
    { y: f(0.985), w: 0.56, h: 0.52, cz: 0.10, n: 2.2 },
    { y: f(1.000), w: 0.10, h: 0.10, cz: 0.10, n: 2.2 },
  ], M.tiles, { seg: 20 });
  g.add(cap);

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

/**
 * THE APOLLO SPACECRAFT: service module, command module, and the escape tower
 * that sits on top of it for the first three minutes of the flight.
 *
 * The command module is a 33° blunt cone, not a capsule primitive — that angle
 * and the spherical heat shield under it are the entire re-entry design. And
 * the escape tower is mostly air: an open lattice with a solid motor on top,
 * which is why drawing it as a filled cone turned the most distinctive nose in
 * spaceflight into a crayon.
 */
function buildCSM(spec, parts) {
  const g = new THREE.Group();
  const smD = 3.90, smL = 4.70, r = smD / 2;

  // ---- service module: a plain cylinder, and almost all of it is propellant.
  const sm = new THREE.Mesh(new THREE.CylinderGeometry(r, r, smL, 28, 1, true), M.alu);
  sm.position.y = smL / 2; g.add(sm);
  // Its six radiator/RCS bays read as vertical seams around the drum.
  for (let i = 0; i < 6; i++) {
    const a = i / 6 * Math.PI * 2;
    const seam = new THREE.Mesh(new THREE.BoxGeometry(0.05, smL * 0.96, 0.14), M.dirty);
    seam.position.set(Math.cos(a) * r, smL / 2, Math.sin(a) * r);
    seam.rotation.y = -a; g.add(seam);
  }
  g.add(rcsRing(smD, smL * 0.86, 4));
  const b = bell(2.24, { ratio: 62 }); b.scale.setScalar(1.15); g.add(b);
  const hd = dish(1.0); hd.position.set(2.3, 1.1, 0); hd.rotation.z = -1.15; g.add(hd);

  // ---- command module: the 33° cone, apex up, on its heat shield.
  const cmY = smL, cmH = 3.20, cmR = 1.955;
  const cm = new THREE.Mesh(new THREE.CylinderGeometry(cmR * 0.28, cmR, cmH, 24, 1, true), M.alu);
  cm.position.y = cmY + cmH / 2; g.add(cm);
  const shield = new THREE.Mesh(
    new THREE.SphereGeometry(cmR * 1.9, 24, 8, 0, Math.PI * 2, Math.PI * 0.72, Math.PI * 0.28),
    M.ablator);
  shield.position.y = cmY + cmR * 1.62; g.add(shield);
  const tunnel = new THREE.Mesh(new THREE.CylinderGeometry(cmR * 0.26, cmR * 0.28, 0.42, 16), M.alu);
  tunnel.position.y = cmY + cmH + 0.18; g.add(tunnel);

  // ---- launch escape system: tower, motor, and the canted nozzles that pull
  // the command module off a failing stack fast enough to matter.
  const towY = cmY + cmH + 0.40, towH = 3.05;
  const tower = lattice(towH, cmR * 1.05, cmR * 0.62, M.dirty);
  tower.position.y = towY; g.add(tower);
  const motorY = towY + towH, motorL = 4.75;
  const motor = new THREE.Mesh(new THREE.CylinderGeometry(0.33, 0.33, motorL, 18), M.white);
  motor.position.y = motorY + motorL / 2; g.add(motor);
  for (let i = 0; i < 4; i++) {                        // escape motor nozzles
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const n2 = new THREE.Mesh(new THREE.ConeGeometry(0.17, 0.42, 10), M.nozzle);
    n2.position.set(Math.cos(a) * 0.33, motorY + motorL * 0.30, Math.sin(a) * 0.33);
    n2.rotation.set(Math.sin(a) * 0.45, 0, -Math.cos(a) * 0.45);
    g.add(n2);
  }
  // Ballast nose and the Q-ball that measures angle of attack at the very tip.
  const nose = ogive(1.55, 0.66, M.white, 16);
  nose.position.y = motorY + motorL; g.add(nose);

  return { group: g, parts };
}

// ---------------------------------------------------------------------------
// THE LUNAR MODULE'S STANCE. A landed LM stands about 1.5 m clear of the
// surface on a gear 9.4 m across the footpads, and those two numbers set
// everything else about the legs.
//
// Both builds used to hang the gear off a box whose underside was the origin,
// so the footpads ended a metre and a half BELOW the ground the vehicle was
// standing on and the engine bell was buried in it. y = 0 is the footpad
// bearing plane; LM_GEAR is how far the descent stage sits above it, and the
// ascent stage carries the same offset internally so that buildCraft's
// stacking still lands it on the descent stage's roof.
// ---------------------------------------------------------------------------
const LM_GEAR = 1.52;
const LM_PAD_R = 4.30;

function buildLMDescent(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D, L = spec.L, r = D / 2;
  const y0 = LM_GEAR, y1 = LM_GEAR + L;
  const hingeR = r * 0.96, hingeY = LM_GEAR + L * 0.90;
  const legLen = Math.hypot(LM_PAD_R - hingeR, hingeY);
  const legCant = Math.atan2(LM_PAD_R - hingeR, hingeY);   // deployed, and stays

  // The octagonal box. Its whole character is that it is a box wrapped in foil.
  // Turned an eighth of a face so a FLAT is centred on +X, which is where the
  // ladder, the porch and the forward leg all are.
  const box = new THREE.Mesh(new THREE.CylinderGeometry(r, r, L, 8), M.gold);
  box.position.y = y0 + L / 2; box.rotation.y = Math.PI / 8; g.add(box);
  // Quadrant panels in black MLI on the four DIAGONAL faces — the cut corners
  // between the tank bays. They are what breaks the shape up.
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const p = new THREE.Mesh(new THREE.BoxGeometry(D * 0.34, L * 0.82, 0.07), M.black);
    p.position.set(Math.cos(a) * r * 0.95, y0 + L / 2, Math.sin(a) * r * 0.95);
    p.rotation.y = -a; g.add(p);
  }
  // The DPS, foreshortened so its lip sits a hand's breadth above the surface,
  // which is where it really is. With no pivot registered parts.gimbals came
  // back empty for this vehicle and the LM burned with no visible exhaust.
  const dp = new THREE.Group();
  dp.position.y = y0;
  dp.userData.gimbalDeg = spec.engine.gimbal;
  const b = bell(spec.engine.exitD, { ratio: 47.5 }); b.scale.set(1, 0.70, 1);
  dp.add(b); g.add(dp); parts.gimbals.push(dp);
  const skirt = new THREE.Mesh(
    new THREE.CylinderGeometry(0.60, 1.05, L * 0.20, 24, 1, true), M.dirty);
  skirt.position.y = y0 + L * 0.10; g.add(skirt);

  // Four legs, from the TOP outrigger where the primary strut really roots —
  // which is also what lets the ladder run from the porch to the pad in one
  // straight line. The contact probe hangs under three of the four pads, and
  // it is what actually ended the landings: "contact light" is a probe
  // touching, not a footpad.
  //
  // AND THE LM's GEAR IS NOT A DEPLOYABLE. Every other lander in the set
  // extends its legs on the way down, and spaceflight.js accordingly holds
  // anything in parts.legs folded until 3 km — but the LM's legs came out in
  // lunar orbit, days before the descent, and the sim's story starts after
  // that. Registering them would fly the whole powered descent with the gear
  // in a pose it was never in, and with the primary struts rooted at the TOP
  // of the box (where they really are, and what lets the ladder run straight
  // from the porch to the pad) the 1.15 rad of travel update() gives a leg puts
  // that stowed pose out sideways. So they are built deployed and left alone.
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2;
    const h = new THREE.Group();
    h.position.set(Math.cos(a) * hingeR, hingeY, Math.sin(a) * hingeR);
    h.rotation.y = -a;
    const leg = landingLeg(legLen, 0.47, i === 0 ? 0 : 1.7);
    leg.rotation.z = legCant;
    h.add(leg);
    // The outrigger the strut roots into. It is structure, not gear, so it
    // hangs on the stage rather than on the hinge that swings.
    const out = new THREE.Mesh(new THREE.CylinderGeometry(0.09, 0.09, r * 0.49, 6), M.alu);
    out.rotation.z = Math.PI / 2;
    out.position.set(Math.cos(a) * r * 0.74, hingeY, Math.sin(a) * r * 0.74);
    out.rotation.y = 0; g.add(out);
    // THE LADDER, on the forward leg and slanting with it. Nine rungs from the
    // porch to a bottom rung that stops well short of the pad.
    if (i === 0) {
      for (const sgn of [-1, 1]) {
        leg.add(beam(new THREE.Vector3(0.34, legLen * 0.03, sgn * 0.26),
                     new THREE.Vector3(0.34, -legLen * 0.80, sgn * 0.26), 0.035, M.alu));
      }
      for (let k = 0; k < 9; k++) {
        const rung = new THREE.Mesh(new THREE.BoxGeometry(0.09, 0.035, 0.56), M.alu);
        rung.position.set(0.34, legLen * 0.03 - legLen * 0.83 * (k / 8), 0);
        leg.add(rung);
      }
    }
    g.add(h);
  }

  // The egress porch above the forward leg, and the MESA beside it — the bay
  // that swung down carrying the TV camera that broadcast the first step.
  const porch = new THREE.Mesh(new THREE.BoxGeometry(0.86, 0.07, 1.02), M.alu);
  porch.position.set(r * 0.86, y1 - 0.03, 0); g.add(porch);
  const mesa = new THREE.Mesh(new THREE.BoxGeometry(1.20, 1.05, 0.90), M.dirty);
  mesa.position.set(0, y0 + L * 0.62, r * 0.82); g.add(mesa);
  // The landing radar, under the aft face: what the guidance actually flew on
  // below high gate.
  const lr = new THREE.Mesh(new THREE.BoxGeometry(0.66, 0.14, 0.66), M.black);
  lr.position.set(-r * 0.58, y0 - 0.06, 0); g.add(lr);
  return { group: g, parts };
}

/**
 * The ascent stage, built with the SAME ground clearance baked in: buildCraft
 * stacks it at the descent stage's 3.05 m and the descent stage's roof is
 * LM_GEAR higher than that, so the offset lives inside the builder.
 */
function buildLMAscent(spec, parts) {
  const g = new THREE.Group();
  const B = LM_GEAR;
  // The crew cabin: a fat cylinder with the two triangular windows canted down,
  // and the equipment bay behind it. Lumpy on purpose — it never flew in air.
  const cab = new THREE.Mesh(new THREE.CylinderGeometry(1.17, 1.17, 2.10, 20), M.gold);
  cab.rotation.x = Math.PI / 2; cab.position.set(0, B + 2.02, 0.30); g.add(cab);
  const mid = new THREE.Mesh(new THREE.BoxGeometry(2.46, 1.86, 2.30), M.gold);
  mid.position.set(0, B + 0.98, -0.22); g.add(mid);
  const aft = new THREE.Mesh(new THREE.BoxGeometry(1.90, 1.30, 0.80), M.black);
  aft.position.set(0, B + 1.30, -1.30); g.add(aft);
  for (const sgn of [-1, 1]) {
    const t = new THREE.Mesh(new THREE.SphereGeometry(0.72, 18, 12), M.gold);
    t.position.set(sgn * 1.34, B + 1.02, -0.30); g.add(t);
    const w = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.44, 0.12), M.glass);
    w.position.set(sgn * 0.46, B + 2.36, 1.30); w.rotation.x = -0.42; g.add(w);
  }
  const hatch = new THREE.Mesh(new THREE.BoxGeometry(0.85, 0.85, 0.12), M.black);
  hatch.position.set(0, B + 1.02, 1.22); g.add(hatch);
  const tun = new THREE.Mesh(new THREE.CylinderGeometry(0.48, 0.48, 0.32, 18), M.alu);
  tun.position.y = B + 3.06; g.add(tun);
  const drogue = new THREE.Mesh(new THREE.CylinderGeometry(0.58, 0.44, 0.48, 18), M.dirty);
  drogue.position.y = B + 3.46; g.add(drogue);
  // The steerable S-band dish and the rendezvous radar. Getting home depended
  // on both of them working — and on both of them POINTING somewhere: the
  // rendezvous antenna used to be aimed back into its own cabin roof.
  const d = dish(0.62); d.position.set(1.16, B + 3.00, -0.52); d.rotation.z = -0.85;
  g.add(d);
  const rr = dish(0.40); rr.position.set(0, B + 3.05, 0.86); rr.rotation.x = 1.15;
  g.add(rr);
  // The APS is FIXED — no gimbal at all — so the ascent stage steers on RCS
  // alone. It still needs the pivot, because that is where the plume hangs.
  const ap = new THREE.Group();
  ap.position.y = B + 0.06;
  ap.userData.gimbalDeg = spec.engine.gimbal;      // 0: declared, and clamped to it
  ap.add(bell(spec.engine.exitD, { ratio: 45 }));
  g.add(ap); parts.gimbals.push(ap);
  const rcs = rcsRing(3.56, B + 2.48, 4); g.add(rcs);
  return { group: g, parts };
}

/**
 * THE MSL AEROSHELL — a 70° sphere-cone, the shape every Mars lander has flown
 * since Viking, plus the backshell and the parachute cone above it.
 *
 * Blunt is the whole point. A sharp body puts the shock on the skin and the
 * vehicle absorbs the heat; a blunt one stands the shock off ahead of itself so
 * the gas heats instead. The old model drew this as a plain cone with the nose
 * pointing the WRONG WAY — the heat shield inverted, opening downwards, which
 * is a shape that would kill the vehicle it is supposed to protect.
 */
function buildAeroshell(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D;                                     // 4.5 m
  const noseR = spec.heatShield?.noseR || D * 0.25;

  // Heat shield: apex DOWN, into the flow — which sphereCone now guarantees
  // itself, with its shoulder on y = 0. It used to be flipped here, on a
  // profile that already ran apex-first, and two rights made a wrong.
  const hs = sphereCone(D, noseR, 70, M.ablator, 36);
  hs.position.y = D * 0.30;
  g.add(hs);

  // Backshell: a shallower cone closing the top, in white thermal blanket.
  const bs = new THREE.Mesh(
    new THREE.CylinderGeometry(D * 0.19, D / 2, D * 0.36, 36, 1, true), M.white);
  bs.position.y = D * 0.30 + D * 0.18; g.add(bs);
  // The joint ring between the two halves — they separate here.
  const ring = new THREE.Mesh(new THREE.TorusGeometry(D / 2 * 1.005, D * 0.012, 6, 36), M.dirty);
  ring.rotation.x = Math.PI / 2; ring.position.y = D * 0.30; g.add(ring);

  // Parachute cone and its cover, on the axis.
  const pc = new THREE.Mesh(new THREE.CylinderGeometry(D * 0.155, D * 0.19, D * 0.10, 24), M.white);
  pc.position.y = D * 0.30 + D * 0.36 + D * 0.05; g.add(pc);
  const lid = new THREE.Mesh(new THREE.SphereGeometry(D * 0.155, 20, 8, 0, Math.PI * 2, 0, Math.PI / 2), M.dirty);
  lid.position.y = D * 0.30 + D * 0.36 + D * 0.10; g.add(lid);

  // Cruise-stage RCS quads and the two tungsten balance masses that are ejected
  // to shift the centre of mass and set the trim angle of attack. The offset CoM
  // is what gives this capsule its L/D of 0.24 — it is a flying machine.
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const q = new THREE.Mesh(new THREE.BoxGeometry(D * 0.07, D * 0.05, D * 0.07), M.dirty);
    q.position.set(Math.cos(a) * D * 0.34, D * 0.52, Math.sin(a) * D * 0.34);
    q.rotation.y = -a; g.add(q);
  }
  return { group: g, parts };
}

/**
 * THE DESCENT STAGE — "sky crane". An eight-engine octagonal deck that flies
 * the rover down and then lowers it on three bridle cables, because a rover
 * with wheels does not want legs and a lander with legs does not want a rover
 * on top of it.
 *
 * The engines are CANTED OUT, and that is not styling: eight plumes pointed
 * straight down at a rover hanging seven metres below would blast it, and would
 * dig the crater that Viking and Phoenix both had to be flown around. The cant
 * is the reason the architecture works at all.
 */
function buildSkyCrane(spec, parts) {
  const g = new THREE.Group();
  const D = spec.D;                                     // 3.2 m
  const deckY = 1.05;

  // Octagonal deck, ribbed underneath the way a real truss deck is.
  const deck = new THREE.Mesh(new THREE.CylinderGeometry(D / 2, D / 2 * 0.94, 0.42, 8), M.alu);
  deck.position.y = deckY; deck.rotation.y = Math.PI / 8; g.add(deck);
  for (let i = 0; i < 8; i++) {
    const a = i / 8 * Math.PI * 2;
    const rib = new THREE.Mesh(new THREE.BoxGeometry(D * 0.44, 0.10, 0.09), M.dirty);
    rib.position.set(Math.cos(a) * D * 0.24, deckY - 0.24, Math.sin(a) * D * 0.24);
    rib.rotation.y = -a; g.add(rib);
  }

  // Four spherical hydrazine tanks on top — most of the stage's dry volume.
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const t = new THREE.Mesh(new THREE.SphereGeometry(0.42, 16, 12), M.gold);
    t.position.set(Math.cos(a) * D * 0.26, deckY + 0.52, Math.sin(a) * D * 0.26);
    g.add(t);
  }
  // Avionics box and the descent-stage antenna.
  const av = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.34, 0.52), M.dirty);
  av.position.set(0, deckY + 0.42, 0); g.add(av);

  // Eight MLEs in four canted pairs. Each pair is a pivot so differential
  // throttle — which is how this stage actually steers — has something to show.
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2 + Math.PI / 4;
    const cant = new THREE.Group();
    cant.position.set(Math.cos(a) * D * 0.44, deckY - 0.20, Math.sin(a) * D * 0.44);
    cant.rotation.set(Math.sin(a) * 0.26, -a, -Math.cos(a) * 0.26);
    const p = new THREE.Group();                       // the driven pivot
    cant.add(p);
    for (const dx of [-0.22, 0.22]) {
      const b = bell(0.28, { ratio: 40 });
      b.position.x = dx; b.scale.setScalar(1.15); p.add(b);
    }
    g.add(cant); parts.gimbals.push(p);
  }

  // The bridle: three cables and the descent-rate limiter they spool from. This
  // is the part that makes it a crane rather than a lander.
  for (let i = 0; i < 3; i++) {
    const a = i / 3 * Math.PI * 2;
    const c = new THREE.Mesh(new THREE.CylinderGeometry(0.018, 0.018, 1.5, 5), M.dirty);
    c.position.set(Math.cos(a) * D * 0.20, deckY - 0.85, Math.sin(a) * D * 0.20);
    c.rotation.set(Math.sin(a) * 0.16, 0, -Math.cos(a) * 0.16);
    g.add(c);
  }
  return { group: g, parts };
}

/**
 * CURIOSITY. A rocker-bogie rover: six driven wheels on a passive linkage that
 * keeps all six loaded over a rock half the wheel's diameter, with no springs
 * anywhere in it. The linkage IS the vehicle's signature, and the old model —
 * a box with six discs stuck to it — had none of it.
 *
 * It has no landing legs because the wheels are the landing gear; it is set
 * down on them directly, which is why they are as big as they are.
 */
function buildRover(spec, parts) {
  const g = new THREE.Group();
  const wr = 0.2625, y0 = wr;                          // 0.525 m wheels
  const bodyY = y0 + 0.62;

  // Warm electronics box: 3.0 × 2.7 × 0.8 m, so a SLAB. `loft` stacks its
  // sections along +Y, and w/h are the half-extents in X and Z — writing the
  // long axis into the section list and then rotating it upright made a 2.7 m
  // tall blob instead of a chassis the wheels could hang off.
  const body = loft([
    { y: -0.34, w: 0.95, h: 1.16, n: 3.2 },
    { y: -0.26, w: 1.12, h: 1.34, n: 3.8 },
    { y: 0.26, w: 1.12, h: 1.34, n: 3.8 },
    { y: 0.34, w: 0.98, h: 1.18, n: 3.2 },
  ], M.alu, { seg: 20 });
  body.position.y = bodyY; g.add(body);

  // RTG at the back, canted up, with its cooling fins — the one part of this
  // rover that is visibly hot.
  const rtg = new THREE.Mesh(new THREE.CylinderGeometry(0.27, 0.27, 0.62, 14), M.black);
  rtg.position.set(-1.42, bodyY + 0.34, 0);
  rtg.rotation.set(0, 0, Math.PI / 2 - 0.30); g.add(rtg);
  const fins = new THREE.Group();
  for (let i = 0; i < 8; i++) {
    const a = i / 8 * Math.PI * 2;
    const f = new THREE.Mesh(new THREE.BoxGeometry(0.56, 0.22, 0.022), M.dirty);
    f.position.set(0, Math.sin(a) * 0.26, Math.cos(a) * 0.26);
    f.rotation.x = -a; fins.add(f);
  }
  fins.position.set(-1.42, bodyY + 0.34, 0); fins.rotation.z = -0.30; g.add(fins);

  // Remote sensing mast: camera head, and it is 2 m up because that is roughly
  // eye height — the images are meant to look like standing there.
  const mast = new THREE.Mesh(new THREE.CylinderGeometry(0.055, 0.07, 1.15, 8), M.dirty);
  mast.position.set(0.72, bodyY + 0.92, 0.30); g.add(mast);
  const head = new THREE.Mesh(new THREE.BoxGeometry(0.56, 0.20, 0.20), M.dirty);
  head.position.set(0.72, bodyY + 1.55, 0.30); g.add(head);
  for (const dx of [-0.20, 0.20]) {
    const eye = new THREE.Mesh(new THREE.CylinderGeometry(0.055, 0.055, 0.08, 12), M.glass);
    eye.position.set(0.72 + dx, bodyY + 1.55, 0.41); eye.rotation.x = Math.PI / 2; g.add(eye);
  }
  // High-gain antenna and the robotic arm, stowed against the front.
  const hga = new THREE.Mesh(new THREE.BoxGeometry(0.30, 0.30, 0.05), M.dirty);
  hga.position.set(-0.55, bodyY + 0.55, -0.55); hga.rotation.set(0.5, 0.6, 0); g.add(hga);
  const arm = new THREE.Mesh(new THREE.CylinderGeometry(0.07, 0.07, 1.05, 8), M.alu);
  arm.position.set(1.18, bodyY - 0.18, 0); arm.rotation.z = 1.15; g.add(arm);

  // ---- rocker-bogie. The rocker runs the length of each side; the bogie is
  // the short rear link that carries two of the three wheels.
  for (const sz of [1, -1]) {
    const side = new THREE.Group();
    side.position.z = sz * 0.72;
    const rocker = new THREE.Mesh(new THREE.CylinderGeometry(0.045, 0.045, 1.55, 6), M.dirty);
    rocker.position.set(0.20, bodyY - 0.16, 0); rocker.rotation.z = Math.PI / 2 - 0.30;
    side.add(rocker);
    const bogie = new THREE.Mesh(new THREE.CylinderGeometry(0.04, 0.04, 0.95, 6), M.dirty);
    bogie.position.set(-0.75, y0 + 0.30, 0); bogie.rotation.z = Math.PI / 2 + 0.22;
    side.add(bogie);
    for (const [x, drop] of [[1.05, 0.0], [-0.30, 0.0], [-1.18, 0.0]]) {
      const leg = new THREE.Mesh(new THREE.CylinderGeometry(0.035, 0.035, 0.52, 6), M.dirty);
      leg.position.set(x, y0 + 0.26 + drop, 0); side.add(leg);
      // Wheel: a drum with cleats, because the grousers are what you see.
      const w = new THREE.Mesh(new THREE.CylinderGeometry(wr, wr, 0.40, 16, 1, true), M.dirty);
      w.rotation.x = Math.PI / 2; w.position.set(x, y0, 0); side.add(w);
      for (let k = 0; k < 10; k++) {
        const a = k / 10 * Math.PI * 2;
        const cl = new THREE.Mesh(new THREE.BoxGeometry(0.022, 0.05, 0.38), M.alu);
        cl.position.set(x + Math.cos(a) * wr * 0.99, y0 + Math.sin(a) * wr * 0.99, 0);
        cl.rotation.z = -a; side.add(cl);
      }
      // Hub face, so a wheel is a wheel and not an open tube.
      for (const zf of [-1, 1]) {
        const hub = new THREE.Mesh(new THREE.CircleGeometry(wr * 0.98, 16), M.dirty);
        hub.position.set(x, y0, zf * 0.20); hub.rotation.y = zf > 0 ? 0 : Math.PI;
        side.add(hub);
      }
    }
    g.add(side);
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
 * THE HAIL MARY, to the film's design.
 *
 * The aft is the part everyone gets wrong, including two earlier passes at this
 * model. The three astrophage tanks do NOT stop on a deck and they do not end
 * in a cone. They run straight down the ship and then BEND INWARD, wrapping
 * around a slim central cone that is taller than the bend and stands between
 * them — and each tank ends in its OWN SPIN DRIVE on its aft face. That is why
 * `vehicles.js` gives this vehicle `count: 3`: three drives, one per tank, not
 * one engine under a hub.
 *
 * So the silhouette is a trident whose prongs curl in at the base. Building the
 * tanks as straight cylinders on a triangular deck loses it completely, which is
 * what the previous version did.
 *
 * The spine is where the ship is a ship: the cone carries the module stack, and
 * above the tanks it keeps going — pressure vessel with its three decks
 * (control, lab, dormitory), then instruments and a docking node. The gold bands
 * at the joints are the only warm colour on it.
 *
 * A SPIN DRIVE is an array of ~1 000 small emitters, not a nozzle: each is a
 * transparent triangular slide that astrophage coats, rotates into vacuum, and
 * fires from at 4.26 and 18.31 μm. So each tank's aft face is a grid of
 * apertures, which looks like nothing else in the set.
 */
// ---------------------------------------------------------------------------
// THE HAIL MARY
// ---------------------------------------------------------------------------

/**
 * A SPIN DRIVE, and deliberately NOT a bell.
 *
 * Astrophage stores ~9e13 J/g and radiates it as light at 4.26 and 18.31 µm, so
 * there is no gas to expand and nothing for a nozzle contour to do: the drive is
 * a plate of emitters behind a shallow reflector that collimates the beam. Two
 * consequences the shape has to show.
 *
 *   · It is SHORT. A chemical bell is long because the gas needs length to
 *     expand against the ambient; light does not expand.
 *   · It is SMALL. Thrust from a photon drive is P/c, so the size of the
 *     aperture is set by how much power the plate can radiate without melting,
 *     not by an area ratio. A drive drawn as wide as the tank it hangs under is
 *     drawn as a chemical engine that happens to glow.
 *
 * Built from the EXIT PLANE UPWARD, and the returned pivot's origin is ON that
 * plane, because spaceflight.js parents the plume straight to the pivot — with
 * the origin at the top of the hardware the beam starts inside it and the first
 * two metres of exhaust are drawn through the machinery.
 *
 * `mount` carries the position and `pivot` is what gets registered as a gimbal.
 * Both exist even though a spin drive is rigid: the plume hangs on the pivot,
 * and anything in parts.gimbals must have identity as its neutral pose.
 */
function spinDrive(R) {
  const mount = new THREE.Group();
  const pivot = new THREE.Group();
  // A spin drive is RIGID — it steers by differential power across four of
  // them, not by swinging. Declaring that here is what stops update() from
  // canting it: see the clamp in buildCraft.
  pivot.userData.gimbalDeg = 0;
  mount.add(pivot);

  // The reflector, lathed on a curve rather than struck as a cone — the curve
  // is the whole difference between a bell mouth and a funnel.
  const prof = [];
  for (let i = 0; i <= 8; i++) {
    const u = i / 8;
    prof.push(new THREE.Vector2(R * (1 - 0.42 * u * u), R * 1.05 * u));
  }
  const neckR = R * 0.58, neckY = R * 1.42;
  prof.push(new THREE.Vector2(neckR, neckY));
  pivot.add(new THREE.Mesh(new THREE.LatheGeometry(prof, 24), M.nozzle));

  const lip = new THREE.Mesh(new THREE.TorusGeometry(R, R * 0.055, 4, 24), M.alu);
  lip.rotation.x = Math.PI / 2; pivot.add(lip);

  // The emitter plate is RECESSED inside the reflector — you should have to
  // look up the drive to see it, which is also what stops four glowing discs
  // reading as four tail-lights.
  const plateR = R * 0.80, plateY = R * 0.55;
  // Mid-grey plate, dark cells, and both emissive: built the other way up the
  // whole assembly reads as an empty cup, which is the opposite of a thousand
  // emitters packed onto a face. The values are scaled for an HDR pipeline —
  // see the note on M.emitPlate.
  const face = new THREE.Mesh(new THREE.CircleGeometry(plateR, 24), M.emitPlate);
  face.position.y = plateY; face.rotation.x = Math.PI / 2; pivot.add(face);
  for (let ring = 1; ring <= 3; ring++) {
    const rr = plateR * 0.27 * ring, cnt = 6 * ring;
    for (let k = 0; k < cnt; k++) {
      const b = k / cnt * Math.PI * 2 + ring * 0.4;
      const cell = new THREE.Mesh(new THREE.CircleGeometry(plateR * 0.11, 6), M.emitCell);
      cell.position.set(Math.cos(b) * rr, plateY - R * 0.004, Math.sin(b) * rr);
      cell.rotation.x = Math.PI / 2; cell.rotation.z = -b;
      pivot.add(cell);
    }
  }
  // Cooling ribs down the outside of the reflector. A drive that turns two
  // thousand tonnes of fuel into light has to get the waste heat out somewhere,
  // and they are also what gives the cone a scale to read against.
  for (let i = 0; i < 8; i++) {
    const a = i / 8 * Math.PI * 2;
    const rib = new THREE.Mesh(new THREE.BoxGeometry(R * 0.055, R * 0.95, R * 0.10), M.alu);
    rib.position.set(Math.cos(a) * R * 0.86, R * 0.52, Math.sin(a) * R * 0.86);
    rib.rotation.y = -a; rib.rotation.z = 0.11;
    pivot.add(rib);
  }
  // A closing disc at the neck, so you cannot see up inside the ship.
  const shut = new THREE.Mesh(new THREE.CircleGeometry(neckR, 20), M.dirty);
  shut.position.y = neckY; shut.rotation.x = -Math.PI / 2; pivot.add(shut);
  // The emitter can: the machinery the plate is the front face of.
  const can = new THREE.Mesh(new THREE.CylinderGeometry(
    neckR * 1.10, neckR, R * 0.62, 20, 1, true), M.dirty);
  can.position.y = neckY + R * 0.31; pivot.add(can);
  const collar = new THREE.Mesh(new THREE.TorusGeometry(neckR * 1.13, R * 0.05, 4, 20), M.alu);
  collar.rotation.x = Math.PI / 2; collar.position.y = neckY + R * 0.10; pivot.add(collar);

  return { mount, pivot, neckR, topY: neckY + R * 0.62 };
}

/**
 * The Hail Mary. Three astrophage tanks in a triangle around a central spine,
 * a pressure vessel forward of them, and FOUR spin drives — one under each tank
 * and one on the axis — all firing through a single plane parallel to the ship's
 * axis.
 *
 * That last point is the layout, not a detail. A drive canted by θ throws away
 * 1 − cos θ of its thrust and puts the rest into a torque that has to be held
 * out with propellant; on a ship that spends thirteen years under power, the
 * only arrangement that costs nothing is thrust vectors parallel to the axis
 * and through one plane. The tanks still bend in around the spine — that is the
 * shape of the ship — but the drives hang square underneath the bend on their
 * own thrust blocks rather than being bolted to whatever angle the tank ended
 * on.
 */
function buildHailMary(spec, parts) {
  // The authored .glb is picked up by buildStage before this is ever called —
  // this whole function is now the FALLBACK, and it is kept working rather
  // than left to rot because a ship that cannot be drawn without a network
  // round trip is a ship that cannot be drawn.
  const g = new THREE.Group();
  const L = spec.L, D = spec.D;                          // 47 m × 12 m
  const f = (u) => u * L;
  const look = spec.look || {};
  const nT = look.tanks || 3;
  const tr = D * 0.265, tankR = D * 0.110;
  const Y = new THREE.Vector3(0, 1, 0), Z = new THREE.Vector3(0, 0, 1);

  /** A strut between two points. Structure is most of what makes a ship of
   *  parts read as one object rather than as parts. */
  const beam = (p1, p2, r, m = M.alu) => {
    const b = new THREE.Mesh(new THREE.CylinderGeometry(r, r, p1.distanceTo(p2), 6), m);
    b.position.copy(p1).lerp(p2, 0.5);
    b.quaternion.setFromUnitVectors(Y, p2.clone().sub(p1).normalize());
    return b;
  };

  // The aft plane. Every drive's exit sits on it.
  const aftY = f(0.132);
  const dR = tankR * 0.62;                 // 0.82 m — the drive is SMALLER than its tank

  // ---- the central drive, on the axis. The middle of the ship is where the
  // spine's own load path ends, so it is where a fourth drive belongs: the
  // three tank drives push on the tanks and this one pushes on the structure
  // that carries them.
  const axial = spinDrive(dR);
  axial.mount.position.set(0, aftY, 0);
  g.add(axial.mount); parts.gimbals.push(axial.pivot);
  const plateY = aftY + axial.topY + f(0.006);

  // ---- the central body. It is a FAT cone the tanks lie AGAINST, not a spike
  // they bend past. Its radius at any height is set by the geometry around it:
  // it has to equal the tank centreline's radius there minus the tank's own
  // radius, or the bend curves around nothing. And it now TERMINATES ON A
  // THRUST PLATE at plateY rather than closing to a point — the plate is what
  // the axial drive hangs from and what the aft truss ties to.
  const coneY1 = f(0.468);
  const coneProf = [
    [0, plateY], [dR * 1.55, plateY],
    [dR * 1.75, plateY + f(0.014)], [D * 0.132, f(0.212)],
    [D * 0.146, f(0.238)], [D * 0.155, f(0.266)], [D * 0.155, f(0.468)],
    [D * 0.075, f(0.468)],
  ].map(([r, y]) => new THREE.Vector2(r, y));
  g.add(new THREE.Mesh(new THREE.LatheGeometry(coneProf, 30), M.dirty));
  // The plate's rim and the neck down to the drive.
  const rim = new THREE.Mesh(new THREE.CylinderGeometry(
    dR * 1.55, dR * 1.42, f(0.016), 24, 1, true), M.alu);
  rim.position.y = plateY - f(0.008); g.add(rim);
  const neck = new THREE.Mesh(new THREE.CylinderGeometry(
    axial.neckR * 1.14, axial.neckR * 1.14, plateY - (aftY + axial.topY) + 0.1, 18, 1, true), M.dirty);
  neck.position.y = (plateY + aftY + axial.topY) / 2; g.add(neck);
  for (const [rr, u] of [[D * 0.142, 0.222], [D * 0.152, 0.252], [D * 0.158, 0.330],
                         [D * 0.158, 0.420]]) {
    const b = new THREE.Mesh(new THREE.TorusGeometry(rr, D * 0.006, 4, 28), M.alu);
    b.rotation.x = Math.PI / 2; b.position.y = f(u); g.add(b);
  }
  // MLI on the spine where it runs between the tanks, and the plumbing that
  // feeds four drives from three tanks — the cross-feed is the reason the
  // middle of this ship is machinery rather than skin.
  const mliBand = new THREE.Mesh(new THREE.CylinderGeometry(
    D * 0.157, D * 0.157, f(0.030), 28, 1, true), M.gold);
  mliBand.position.y = f(0.300); g.add(mliBand);
  for (let i = 0; i < 8; i++) {
    const a = i / 8 * Math.PI * 2 + 0.5;
    // Staggered in length and height. Eight identical cylinders at one station
    // read as a single painted band; a real trunk run is a bundle of lines that
    // start and stop at different fittings.
    const h = f(0.150 + 0.055 * ((i * 5) % 7) / 7);
    const run = new THREE.Mesh(new THREE.CylinderGeometry(
      D * 0.008, D * 0.008, h, 6, 1, true), i % 3 ? M.alu : M.soot);
    run.position.set(Math.cos(a) * D * 0.163, f(0.352) + h * 0.5 - f(0.075),
                     Math.sin(a) * D * 0.163);
    g.add(run);
  }
  for (let i = 0; i < 3; i++) {                          // valve packages
    const a = i / 3 * Math.PI * 2 + 0.9;
    const box = new THREE.Mesh(new THREE.BoxGeometry(D * 0.055, D * 0.075, D * 0.045), M.alu);
    box.position.set(Math.cos(a) * D * 0.172, f(0.288), Math.sin(a) * D * 0.172);
    box.rotation.y = -a; g.add(box);
  }

  // ---- three tanks: straight, then bent in around the cone.
  // The turn is limited by what happens at the DRIVE FACE, not at the tank's
  // last ring: the drive sits below the bent end, so every degree of turn walks
  // it inward. Three faces of radius r clear each other on a ring of R only
  // while R·√3 > 2r.
  const path = bentPath(tr, f(0.679), f(0.245), D * 0.55, 16, D * 0.14);
  const endP = path[path.length - 1];
  for (let i = 0; i < nT; i++) {
    const a = i / nT * Math.PI * 2 + Math.PI / 2;
    const t = new THREE.Group();
    t.rotation.y = -a;                                   // the path is radial/axial
    const { mesh, tan, nrm } = bentTube(path, tankR, M.white, { radial: 24 });
    t.add(mesh);
    // The transported frame the tube was built on, reused by every piece of
    // hardware that has to follow the bend. `nrm` is the out-of-plane axis and
    // `bi` the in-plane one, so φ = 0 is the ±z flank and φ = π/2 is inboard.
    const bi = (k) => new THREE.Vector3().crossVectors(tan[k], nrm[k]).normalize();
    const surf = (k, phi, rr) => path[k].clone()
      .addScaledVector(nrm[k], Math.cos(phi) * rr)
      .addScaledVector(bi(k), Math.sin(phi) * rr);

    // Ring frames, and a weld seam halfway between every pair of them. A
    // pressure vessel twenty-four metres long is not one piece of metal, and
    // the spacing of the barrel sections is the first thing that gives a tank
    // its size.
    //
    // Spaced by ARC LENGTH, not by path index. The centreline's own points are
    // 3.4 m apart down the straight run and 0.18 m apart round the bend, so a
    // ring every k-th point puts EIGHTEEN times as many on the turn as on the
    // barrel: the aft end came out corrugated and the rest came out bare. A
    // barrel section has one length wherever it is on the tank.
    const arc = [0];
    for (let k = 1; k < path.length; k++) arc[k] = arc[k - 1] + path[k].distanceTo(path[k - 1]);
    const at = (sT) => {                                 // position + tangent at an arc length
      let k = 1; while (k < arc.length - 1 && arc[k] < sT) k++;
      const u = (sT - arc[k - 1]) / Math.max(arc[k] - arc[k - 1], 1e-6);
      return { p: path[k - 1].clone().lerp(path[k], u),
               q: tan[k - 1].clone().lerp(tan[k], u).normalize() };
    };
    const BAY = 2.6;                                     // barrel section length, m
    for (let n = 1; n * BAY * 0.5 < arc[arc.length - 1] - 0.35; n++) {
      const { p, q } = at(n * BAY * 0.5);
      if (n % 2) {                                       // frame
        const ring = new THREE.Mesh(
          new THREE.TorusGeometry(tankR * 1.016, tankR * 0.038, 4, 24), M.alu);
        ring.position.copy(p);
        ring.quaternion.setFromUnitVectors(Z, q);
        t.add(ring);
      } else {                                           // weld seam
        // A seam has to stand PROUD of the skin and be cut on the SAME segment
        // count as it. At tankR·1.004 on 22 sides against a 24-sided tube the
        // two polygons cross each other twice per facet, and the ring renders
        // as a row of dashes that come and go with the camera — which looked
        // like deliberate hatching and was z-fighting.
        const seam = new THREE.Mesh(new THREE.CylinderGeometry(
          tankR * 1.012, tankR * 1.012, tankR * 0.05, 24, 1, true), M.soot);
        seam.position.copy(p);
        seam.quaternion.setFromUnitVectors(Y, q);
        t.add(seam);
      }
    }
    // Cable trays, a propellant trunk on the inboard face and a conduit run on
    // the outboard one, all carried round the bend on the tank's own frame.
    // These are most of what tells you a tank is a machine and not a cylinder.
    for (const [phi, rr, rad, m] of [
      [0.62, tankR * 1.05, 0.085, M.alu],
      [-0.62, tankR * 1.05, 0.085, M.alu],
      [Math.PI * 0.5, tankR * 1.09, 0.135, M.dirty],     // inboard: the feed trunk
      [Math.PI * 1.5, tankR * 1.06, 0.090, M.soot],      // outboard: conduit
      [Math.PI * 1.5 - 0.30, tankR * 1.04, 0.055, M.alu],
    ]) {
      const rail = new THREE.CatmullRomCurve3(path.map((_, k) => surf(k, phi, rr)));
      t.add(new THREE.Mesh(new THREE.TubeGeometry(rail, 24, rad, 4, false), m));
    }
    // Standoff brackets, so the runs are held off the skin rather than sunk in it.
    for (let k = 2; k < path.length - 1; k += 3) {
      for (const phi of [Math.PI * 0.5, Math.PI * 1.5]) {
        const p1 = surf(k, phi, tankR * 0.99), p2 = surf(k, phi, tankR * 1.10);
        t.add(beam(p1, p2, 0.05));
      }
    }
    // Forward dome, collar and cap.
    const dome = new THREE.Mesh(
      new THREE.SphereGeometry(tankR, 24, 10, 0, Math.PI * 2, 0, Math.PI / 2), M.white);
    dome.position.copy(path[0]); t.add(dome);
    const collar = new THREE.Mesh(new THREE.TorusGeometry(tankR * 1.02, tankR * 0.05, 4, 24), M.alu);
    collar.rotation.x = Math.PI / 2; collar.position.copy(path[0]); t.add(collar);
    const vent = new THREE.Mesh(new THREE.CylinderGeometry(
      tankR * 0.18, tankR * 0.22, tankR * 0.30, 12), M.dirty);
    vent.position.set(tr + tankR * 0.40, path[0].y + tankR * 0.95, 0); t.add(vent);
    // MLI: one band on the straight run above the bend, one under the dome.
    for (const [y, h] of [[f(0.285), f(0.030)], [f(0.640), f(0.022)]]) {
      const gb = new THREE.Mesh(new THREE.CylinderGeometry(
        tankR * 1.02, tankR * 1.02, h, 24, 1, true), M.gold);
      gb.position.set(tr, y, 0); t.add(gb);
    }
    // Equipment on the outboard flanks, clear of the conduit run. The boxes are
    // small, and being able to SEE that they are small next to a 2.6 m tank is
    // most of what they are there for.
    for (const [y, w, h2, phi] of [[f(0.330), 1.5, 1.1, Math.PI * 1.5 + 0.62],
                                   [f(0.455), 0.9, 0.8, Math.PI * 1.5 - 0.62],
                                   [f(0.545), 1.2, 0.6, Math.PI * 1.5 + 0.62],
                                   [f(0.612), 0.7, 0.9, Math.PI * 1.5 - 0.62]]) {
      const box = new THREE.Mesh(new THREE.BoxGeometry(0.34, h2, w), M.dirty);
      box.position.set(tr - Math.sin(phi) * tankR * 1.08, y, Math.cos(phi) * tankR * 1.08);
      box.rotation.y = Math.atan2(Math.cos(phi), -Math.sin(phi));
      t.add(box);
    }

    // ---- the aft end: a bulkhead, a thrust block, and the drive square under it.
    const endT = tan[tan.length - 1];
    const capPlate = new THREE.Mesh(new THREE.CircleGeometry(tankR, 24), M.dirty);
    capPlate.position.copy(endP);
    capPlate.quaternion.setFromUnitVectors(Z, endT); t.add(capPlate);
    const capRing = new THREE.Mesh(
      new THREE.TorusGeometry(tankR * 1.01, tankR * 0.055, 4, 24), M.alu);
    capRing.position.copy(endP);
    capRing.quaternion.setFromUnitVectors(Z, endT); t.add(capRing);

    // The thrust block. This is the part that makes an axial drive under a bent
    // tank an honest structure rather than a floating one: the tank's aft face
    // is oblique, the drive is square to the ship, and something has to take up
    // the difference and carry 31 MN through it.
    const drv = spinDrive(dR);
    drv.mount.position.set(endP.x, aftY, 0);
    t.add(drv.mount); parts.gimbals.push(drv.pivot);
    // Buried at the top inside the tank's aft end and square to the ship at the
    // bottom, so the whole 16 degrees is taken up in one short piece of
    // structure rather than being carried out into the thrust vector.
    const blockTop = endP.y + tankR * 0.62, blockBot = aftY + drv.topY;
    const block = new THREE.Mesh(new THREE.CylinderGeometry(
      dR * 0.92, dR * 0.80, blockTop - blockBot, 18, 1, true), M.dirty);
    block.position.set(endP.x, (blockTop + blockBot) / 2, 0); t.add(block);
    // Gussets out to the bulkhead ring. The cap is oblique and the block is
    // square, so no two of them are the same length — which is what taking an
    // angle out of a structure actually looks like.
    const nEnd = nrm[nrm.length - 1];
    const bEnd = new THREE.Vector3().crossVectors(endT, nEnd).normalize();
    for (let k = 0; k < 6; k++) {
      const phi = k / 6 * Math.PI * 2;
      const p2 = endP.clone()
        .addScaledVector(nEnd, Math.cos(phi) * tankR * 0.90)
        .addScaledVector(bEnd, Math.sin(phi) * tankR * 0.90);
      const p1 = new THREE.Vector3(endP.x - Math.sin(phi) * dR * 0.88,
                                   blockBot + 0.22, Math.cos(phi) * dR * 0.88);
      t.add(beam(p1, p2, 0.06));
    }
    // The feed line, off the inboard trunk and down the side of the block into
    // the emitter can. Routed outboard of the spine's thrust plate, because the
    // shortest path from there to here goes straight through it.
    const feed = new THREE.CatmullRomCurve3([
      surf(path.length - 6, Math.PI * 0.5, tankR * 1.09),
      surf(path.length - 2, Math.PI * 0.5, tankR * 1.15),
      new THREE.Vector3(endP.x - dR * 1.05, blockBot + 0.75, 0),
      new THREE.Vector3(endP.x - dR * 0.90, blockBot + 0.30, 0),
    ]);
    t.add(new THREE.Mesh(new THREE.TubeGeometry(feed, 16, 0.12, 5, false), M.alu));
    g.add(t);
  }

  // ---- structure. Radial struts to the spine at two stations up the straight
  // run, girth ties between adjacent tanks, and an aft truss tying all four
  // drive blocks into one thrust structure.
  for (const yy of [f(0.290), f(0.584)]) {
    for (let i = 0; i < nT; i++) {
      const a = i / nT * Math.PI * 2 + Math.PI / 2;
      const inner = D * 0.075;
      g.add(beam(new THREE.Vector3(Math.cos(a) * inner, yy, Math.sin(a) * inner),
                 new THREE.Vector3(Math.cos(a) * (tr - tankR * 0.9), yy,
                                   Math.sin(a) * (tr - tankR * 0.9)), 0.09));
    }
  }
  const ringPt = (i, r, y) => {
    const a = i / nT * Math.PI * 2 + Math.PI / 2;
    return new THREE.Vector3(Math.cos(a) * r, y, Math.sin(a) * r);
  };
  for (const [yy, rr] of [[f(0.330), tr], [f(0.620), tr]]) {
    for (let i = 0; i < nT; i++) {
      g.add(beam(ringPt(i, rr - tankR * 0.2, yy), ringPt(i + 1, rr - tankR * 0.2, yy), 0.075));
    }
  }
  // The aft truss. Two struts from the spine's thrust plate to each drive block
  // and a girth ring between the blocks: four drives on one plane are only one
  // thrust structure if something actually ties them together.
  for (let i = 0; i < nT; i++) {
    const p = ringPt(i, endP.x, aftY + dR * 2.0);
    for (const s of [-1, 1]) {
      const q = ringPt(i + s * 0.22, dR * 1.5, plateY - f(0.010));
      g.add(beam(p, q, 0.075));
    }
    g.add(beam(p, ringPt(i + 1, endP.x, aftY + dR * 2.0), 0.065));
  }

  // ---- the module stack, standing on the cone and running past the tanks.
  const mod = (y0, y1, dia, m) => {
    const c = new THREE.Mesh(new THREE.CylinderGeometry(dia / 2, dia / 2, y1 - y0, 22, 1, true), m);
    c.position.y = (y0 + y1) / 2; g.add(c); return c;
  };
  const band = (y, dia, h, m) => {
    const c = new THREE.Mesh(new THREE.CylinderGeometry(dia / 2 * 1.02, dia / 2 * 1.02, h, 22, 1, true), m);
    c.position.y = y; g.add(c);
  };
  band(coneY1, D * 0.150, f(0.022), M.gold);
  mod(f(0.468), f(0.560), D * 0.150, M.dirty);           // machinery / stores
  band(f(0.560), D * 0.180, f(0.022), M.gold);

  const hullY0 = f(0.566), hullY1 = f(0.855), hullD = D * 0.205;
  mod(hullY0, hullY1, hullD, M.white);
  for (let k = 0; k < 3; k++) {                          // control / lab / dorm
    band(hullY0 + (hullY1 - hullY0) * (0.17 + k * 0.30), hullD, f(0.006), M.black);
  }
  for (const side of [1, -1]) {
    const w = new THREE.Mesh(new THREE.CylinderGeometry(0.30, 0.30, 0.10, 14), M.glass);
    w.position.set(side * hullD * 0.5, hullY0 + (hullY1 - hullY0) * 0.78, 0);
    w.rotation.z = Math.PI / 2; g.add(w);
  }
  const lock = new THREE.Mesh(new THREE.CylinderGeometry(0.55, 0.55, 0.22, 16), M.alu);
  lock.position.set(0, hullY0 + (hullY1 - hullY0) * 0.40, hullD * 0.5);
  lock.rotation.x = Math.PI / 2; g.add(lock);
  band(hullY1, D * 0.170, f(0.022), M.gold);

  mod(f(0.861), f(1.013), D * 0.140, M.dirty);           // instruments
  const node = new THREE.Mesh(new THREE.SphereGeometry(D * 0.088, 20, 14), M.alu);
  node.position.y = f(1.051); g.add(node);
  for (let i = 0; i < 4; i++) {
    const a = i / 4 * Math.PI * 2;
    const port = new THREE.Mesh(new THREE.CylinderGeometry(D * 0.030, D * 0.034, D * 0.055, 14), M.dirty);
    port.position.set(Math.cos(a) * D * 0.095, f(1.051), Math.sin(a) * D * 0.095);
    port.rotation.z = Math.PI / 2; port.rotation.y = -a; g.add(port);
  }
  const mast = new THREE.Mesh(new THREE.CylinderGeometry(0.07, 0.07, f(0.055), 8), M.alu);
  mast.position.y = f(1.120); g.add(mast);
  const hgDish = dish(D * 0.105);
  hgDish.position.set(D * 0.14, f(1.007), 0); hgDish.rotation.z = -1.2; g.add(hgDish);

  // ---- radiators. FIXED structure, not deployables: a ship under power for
  // thirteen years rejects heat continuously, and anything put in parts.arrays
  // flies stowed until the flight state asks for it. They sit on the hull ABOVE
  // the tank tops, which is the only band of the spine with a clear horizon.
  const nRad = look.radiators || 0;
  for (let i = 0; i < nRad; i++) {
    const arm = new THREE.Group();
    arm.rotation.y = -(i / nRad * Math.PI * 2 + Math.PI / 4);
    arm.position.y = f(0.775);
    // The panel is turned up on an INNER object. Two Euler angles on one node
    // compose in a fixed order and the second one swings the first out of the
    // plane you set it in; a parent for the azimuth and a child for the tilt
    // is the version that means what it says.
    const rad = radiator(D * 0.22, f(0.085));
    rad.rotation.x = Math.PI / 2;
    rad.position.x = hullD * 0.5 + D * 0.175;
    arm.add(rad);
    arm.add(beam(new THREE.Vector3(hullD * 0.46, 0, 0),
                 new THREE.Vector3(hullD * 0.5 + D * 0.09, 0, 0), 0.07));
    g.add(arm);
  }

  // ---- solar wings: two long flat panels, the widest thing on the ship.
  for (const side of [1, -1]) {
    const wing = new THREE.Group();
    const nP = 7, pw = D * 0.235, ph = D * 0.40;
    for (let k = 0; k < nP; k++) {
      // Turned through 90°: the panel's plane contains the ship's axis, so it
      // stands off the hull like a wing instead of lying flat like a table.
      const pnl = new THREE.Mesh(new THREE.BoxGeometry(pw, ph, 0.05), M.solar);
      pnl.position.set(D * 0.46 + pw * (k + 0.5) * 1.02, 0, 0); wing.add(pnl);
      const rib = new THREE.Mesh(new THREE.BoxGeometry(0.06, ph, 0.10), M.alu);
      rib.position.set(D * 0.46 + pw * k * 1.02, 0, 0); wing.add(rib);
    }
    const spar = new THREE.Mesh(new THREE.CylinderGeometry(0.10, 0.10, D * 1.20, 6), M.alu);
    spar.position.set(D * 0.46 + D * 0.60, 0, 0); spar.rotation.z = Math.PI / 2;
    wing.add(spar);
    wing.position.set(0, f(0.360), 0);
    wing.rotation.y = side > 0 ? 0 : Math.PI;
    // Fixed structure, NOT a deployable — see the note on `parts.arrays`.
    g.add(wing);
  }

  // ---- beetles on the spine below the pressure vessel. Next to the ship they
  // are deliberately tiny, and they are the only way an answer gets home.
  const nB = look.beetles || 0;
  for (let i = 0; i < nB; i++) {
    const a = i / nB * Math.PI * 2 + Math.PI / 4;
    const b = new THREE.Group();
    b.position.set(Math.cos(a) * D * 0.105, f(0.520), Math.sin(a) * D * 0.105);
    b.rotation.y = -a;
    b.add(new THREE.Mesh(new THREE.CapsuleGeometry(D * 0.028, D * 0.070, 5, 12), M.dirty));
    const nz = new THREE.Mesh(new THREE.CylinderGeometry(D * 0.018, D * 0.026, D * 0.028, 12), M.emitPlate);
    nz.position.y = -D * 0.068; b.add(nz);
    g.add(b);
  }
  g.add(rcsRing(hullD, hullY0 + (hullY1 - hullY0) * 0.55, 4));
  // The layout above is written around the aft plane, which sits at f(0.132);
  // shift the ship so the drives' exit plane is the origin. The offset goes on
  // an INNER group, not on `g` — buildCraft assigns the stage group's position
  // when it places the stage, so anything written to `g.position` here is
  // silently overwritten a moment later.
  const body = new THREE.Group();
  while (g.children.length) body.add(g.children[0]);
  body.position.y = -aftY;
  g.add(body);
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
  const specs = vehicle.stages;
  for (let i = 0; i < specs.length; i++) {
    const spec = specs[i];
    // A stage needs to know what it is adapting TO: the Saturn V's S-II/S-IVB
    // interstage is a cone from 10.06 m to 6.6 m, and a stage that only knows
    // its own diameter has to draw it as a cylinder and get it wrong.
    const nextD = specs[i + 1]?.D ?? spec.D;
    const { group, parts } = buildStage(spec, { ...vehicle, nextD });
    // A PARALLEL stage is mounted on the core rather than stacked on it. The
    // Shuttle is the case that matters: the orbiter is bolted to the SIDE of
    // the tank, not balanced on its nose, and stacking it was the single
    // biggest error in the old model. `mount` says where, in metres, and a
    // mounted stage does not advance the stack height.
    const mount = spec.look?.mount;
    group.position.set(mount?.x || 0, (mount?.y || 0) + (mount ? 0 : y), mount?.z || 0);
    root.add(group);
    stages.push({ key: spec.key, spec, group, parts,
      baseY: group.position.y, deploy: 0, sep: null });
    if (!mount) y += spec.L + (spec.look?.interstage || 0);
  }
  // The stack's height is now a measured extent, not a running sum: once a
  // stage can be MOUNTED alongside the core, the sum of the stage lengths stops
  // being the height of anything. The Shuttle is the case — 46.9 m of tank with
  // solids hanging below its base — and the camera framing, the pad view
  // handover and the vessel's own length all read this number.
  const _bb = new THREE.Box3().setFromObject(root);
  const height = Number.isFinite(_bb.max.y - _bb.min.y) ? _bb.max.y - _bb.min.y : y;
  root.userData.height = height;

  const _v = new THREE.Vector3();
  return {
    group: root, stages, height,
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
        for (const arr of st.parts.arrays) arr.rotation.z = (1 - d) * (Math.PI / 2);
        for (const h of st.parts.halves) {
          h.rotation.z = 0; h.position.x = 0;
        }
        // gimbal: the commanded deflection, shared by every bell on the stage —
        // but CLAMPED to what each one can physically do. The command is a
        // controller output, not a pose, and an engine that cannot gimbal must
        // not be drawn gimballing: the Hail Mary's spin drives are rigid, and
        // until this clamp existed all four sat visibly canted a few degrees
        // and waggled once a second. A pivot that declares no authority is
        // left alone, so every hand-built drive keeps the freedom it had.
        const gx = (s.gimbal?.x || 0), gz = (s.gimbal?.z || 0);
        for (const p of st.parts.gimbals) {
          const lim = (p.userData.gimbalDeg ?? 90) * Math.PI / 180;
          p.rotation.x = THREE.MathUtils.clamp(gz, -lim, lim);
          p.rotation.z = THREE.MathUtils.clamp(-gx, -lim, lim);
        }
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
