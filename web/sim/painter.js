import * as THREE from 'three';
import { G, AU_PER_KM, AU_PER_RSUN } from './physics.js';

// ============================================================================
// PAINTER — rings, belts and clouds
// ----------------------------------------------------------------------------
// Everything here is made of enormous numbers of small things, which is exactly
// the case the N-body integrator cannot take: a ring is 10^13 particles, and
// even a token 20 000 of them would swamp an O(n²) force loop that is currently
// running twelve bodies.
//
// So these are TEST PARTICLES. Each one carries its own orbital elements and is
// advanced analytically in the central body's potential — mean anomaly grows at
// n = √(GM/a³), Kepler's equation is solved for the true position — rather than
// being integrated. That is not a cheat so much as a different and, here, more
// accurate method: for a particle whose own mass is negligible, the two-body
// solution IS the exact answer, and it neither drifts nor needs a step size.
// What it gives up is the particles' effect on each other and on the planet,
// which for a ring is genuinely negligible, and their response to a third body,
// which is not — so resonances are put in by hand where they matter (below).
//
// WHAT DECIDES WHERE A RING CAN BE. A ring is not a design choice. Inside the
// Roche limit,
//
//     d = 2.44 R_p (ρ_p/ρ_m)^⅓
//
// tidal forces across a body held together only by its own gravity exceed its
// self-gravity, so it cannot accrete into a moon and stays a ring; outside it,
// the same material collects into moons within a few orbits. Every ring in the
// solar system lies inside its planet's Roche limit and every major moon lies
// outside. So `ringSpan()` returns that interval, and the painter defaults to
// it rather than to an arbitrary radius.
//
// KIRKWOOD GAPS. The asteroid belt is not uniform: it has gaps at the orbital
// radii where a particle's period is a simple ratio of Jupiter's, because a
// particle there gets the same kick at the same phase every time and its
// eccentricity is pumped until it crosses a planet and is removed. The 3:1,
// 5:2, 7:3 and 2:1 resonances are all visible in the real distribution, and
// they are what `resonanceGaps` reproduces — by depopulating those radii, which
// is what the dynamics does over the age of the solar system.
// ============================================================================

const TWO_PI = Math.PI * 2;

// Bulk densities, g/cm³ → kg/m³, for the Roche calculation.
const RHO = { rock: 3000, ice: 900, rubble: 1500 };

// ----------------------------------------------------------------------------
// The interval a ring can occupy around a body: from just above its surface out
// to the Roche limit for the given material.
//   radiusAU  the central body's radius
//   massSun   its mass
// Returns { inner, outer, roche } in AU. `outer` is null when the Roche limit
// falls inside the body itself — which happens for a low-density central body,
// and means it simply cannot have a ring.
// ----------------------------------------------------------------------------
export function ringSpan(massSun, radiusAU, material = 'ice') {
  const M_SUN = 1.98892e30;
  const rM = radiusAU / AU_PER_KM * 1000;
  const rhoP = (massSun * M_SUN) / ((4 / 3) * Math.PI * rM * rM * rM);
  const roche = 2.44 * radiusAU * Math.cbrt(rhoP / RHO[material]);
  return {
    inner: radiusAU * 1.2,
    outer: roche > radiusAU * 1.3 ? roche : null,
    roche,
  };
}

// ----------------------------------------------------------------------------
// Solve Kepler's equation M = E − e sin E for the eccentric anomaly.
// Two Newton steps from a good initial guess are accurate to ~1e-10 for the
// eccentricities anything here uses, and this runs per particle per frame.
// ----------------------------------------------------------------------------
function eccentricAnomaly(M, e) {
  let E = M + e * Math.sin(M) * (1 + e * Math.cos(M));
  for (let i = 0; i < 2; i++) {
    E -= (E - e * Math.sin(E) - M) / (1 - e * Math.cos(E));
  }
  return E;
}

// The low-order mean-motion resonances that actually clear gaps, as the ratio
// of the perturber's period to the particle's.
const RESONANCES = [
  { p: 3, q: 1, w: 0.012 },   // 3:1  — the Hecuba gap, and the Cassini division's analogue
  { p: 5, q: 2, w: 0.008 },
  { p: 7, q: 3, w: 0.006 },
  { p: 2, q: 1, w: 0.014 },
];

// True where a semi-major axis sits inside a resonance gap with a perturber of
// semi-major axis aPert.
function inResonanceGap(a, aPert) {
  for (const r of RESONANCES) {
    // a_res / a_pert = (q/p)^(2/3)  from Kepler's third law
    const aRes = aPert * Math.pow(r.q / r.p, 2 / 3);
    if (Math.abs(a - aRes) < r.w * aPert) return true;
  }
  return false;
}

// ============================================================================
// The particle system itself. One THREE.Points, one draw call, positions
// rewritten on the CPU each frame from the analytic solution.
// ============================================================================
function particleMaterial(color, sizePx, softness = 1.0) {
  return new THREE.ShaderMaterial({
    uniforms: {
      uColor: { value: new THREE.Color(color) },
      uSize: { value: sizePx },
      uSoft: { value: softness },
    },
    transparent: true, depthWrite: false,
    blending: THREE.NormalBlending,
    vertexShader: `
      attribute float aSize; attribute float aShade;
      varying float vShade;
      uniform float uSize;
      void main(){
        vShade = aShade;
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        // Constant size in PIXELS, deliberately. A ring particle is somewhere
        // between a grain and a house, sitting in a ring a hundred thousand
        // kilometres wide: its true angular size is unresolvable at every
        // distance from which the ring is visible at all, so it is a point
        // source and stays one. Sizing these with distance would draw the
        // particles as boulders the size of moons the moment you flew close.
        gl_PointSize = uSize * aSize;
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: `
      precision highp float;
      uniform vec3 uColor; uniform float uSoft;
      varying float vShade;
      void main(){
        float d = length(gl_PointCoord - 0.5) * 2.0;
        if (d > 1.0) discard;
        float a = pow(1.0 - d, uSoft);
        gl_FragColor = vec4(uColor * vShade, a * 0.9);
      }`,
  });
}

// ----------------------------------------------------------------------------
// createOrbitalSwarm — the shared engine behind rings and belts.
//
//   centralMass   M☉, the body the particles orbit
//   inner/outer   AU
//   count         number of particles
//   ecc/incl      maximum eccentricity and inclination spread
//   perturberA    if given, clear resonance gaps against a body at this a (AU)
//   sceneScale    scene units per AU
// ----------------------------------------------------------------------------
export function createOrbitalSwarm({
  centralMass, inner, outer, count = 4000, ecc = 0.002, incl = 0.0008,
  color = 0xcdbb99, sizePx = 2.2, sceneScale = 1, tilt = 0, softness = 1.0,
  perturberA = null, surfaceDensity = -1.5, shade = [0.55, 1.0],
}) {
  const N = Math.max(16, count | 0);
  const pos = new Float32Array(N * 3);
  const size = new Float32Array(N);
  const shadeA = new Float32Array(N);

  // Orbital elements, one set per particle.
  const el = {
    a: new Float64Array(N), e: new Float64Array(N),
    n: new Float64Array(N), M0: new Float64Array(N),
    cosI: new Float64Array(N), sinI: new Float64Array(N),
    cosO: new Float64Array(N), sinO: new Float64Array(N),
    cosW: new Float64Array(N), sinW: new Float64Array(N),
  };

  const GM = G * Math.max(centralMass, 1e-9);
  let written = 0;
  let guard = 0;
  while (written < N && guard < N * 40) {
    guard++;
    // Sample the semi-major axis from a power-law surface density Σ ∝ a^p,
    // so the number of particles between a and a+da goes as 2πa·Σ·da ∝ a^(p+1).
    // Saturn's rings and the asteroid belt are both centrally concentrated;
    // a flat sample would put most of the particles in the outer edge, which
    // is where a uniform random radius always puts them.
    const u = Math.random();
    const k = surfaceDensity + 2;
    const a = k === 0
      ? inner * Math.pow(outer / inner, u)
      : Math.pow(Math.pow(inner, k) + u * (Math.pow(outer, k) - Math.pow(inner, k)), 1 / k);
    if (perturberA && inResonanceGap(a, perturberA)) continue;

    const i = written++;
    const e = Math.random() * ecc;
    const inc = (Math.random() - 0.5) * 2 * incl;
    const Om = Math.random() * TWO_PI, w = Math.random() * TWO_PI;
    el.a[i] = a; el.e[i] = e;
    el.n[i] = Math.sqrt(GM / (a * a * a));      // mean motion, rad/yr
    el.M0[i] = Math.random() * TWO_PI;
    el.cosI[i] = Math.cos(inc); el.sinI[i] = Math.sin(inc);
    el.cosO[i] = Math.cos(Om);  el.sinO[i] = Math.sin(Om);
    el.cosW[i] = Math.cos(w);   el.sinW[i] = Math.sin(w);
    size[i] = 0.55 + Math.random() * 0.9;
    shadeA[i] = shade[0] + Math.random() * (shade[1] - shade[0]);
  }

  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  geo.setAttribute('aSize', new THREE.BufferAttribute(size, 1));
  geo.setAttribute('aShade', new THREE.BufferAttribute(shadeA, 1));
  const mat = particleMaterial(color, sizePx, softness);
  const points = new THREE.Points(geo, mat);
  points.frustumCulled = false;

  const group = new THREE.Group();
  group.add(points);
  group.rotation.x = tilt;

  let t = 0;
  function update(simDt, scale = sceneScale) {
    t += simDt;
    for (let i = 0; i < written; i++) {
      const a = el.a[i], e = el.e[i];
      const M = el.M0[i] + el.n[i] * t;
      const E = e > 1e-6 ? eccentricAnomaly(M, e) : M;
      // Position in the orbital plane, from the eccentric anomaly.
      const xo = a * (Math.cos(E) - e);
      const yo = a * Math.sqrt(1 - e * e) * Math.sin(E);
      // Rotate by argument of periapsis, inclination, longitude of node.
      const cw = el.cosW[i], sw = el.sinW[i];
      const x1 = xo * cw - yo * sw, y1 = xo * sw + yo * cw;
      const ci = el.cosI[i], si = el.sinI[i];
      const x2 = x1, y2 = y1 * ci, z2 = y1 * si;
      const co = el.cosO[i], so = el.sinO[i];
      const X = x2 * co - y2 * so, Y = x2 * so + y2 * co;
      // Scene axes: the orbital plane is XZ, so the out-of-plane term is Y.
      pos[i * 3] = X * scale;
      pos[i * 3 + 1] = z2 * scale;
      pos[i * 3 + 2] = Y * scale;
    }
    geo.attributes.position.needsUpdate = true;
    geo.setDrawRange(0, written);
  }
  update(0, sceneScale);

  return {
    group, points, count: written,
    update,
    dispose() { geo.dispose(); mat.dispose(); },
  };
}

// ============================================================================
// GAS CLOUD — an expanding shell, optionally bipolar.
// ----------------------------------------------------------------------------
// Nebulae are optically thin, so what you see is the integral of emission along
// the line of sight — which is why a hollow expanding shell looks like a bright
// RIM: the sightline through the edge passes through far more gas than the one
// through the middle. That limb brightening is the single feature that makes a
// shell read as a shell, and it is one line of shader (the exponent on the
// fresnel term) rather than a texture.
//
// Ejected shells also expand homologously — a parcel thrown out faster is
// further out, so v ∝ r and the whole thing scales without changing shape. The
// radius here therefore grows linearly with time at the speed given, which for
// Eta Carinae's Homunculus is a measured 650 km/s.
// ============================================================================
export function createGasCloud({
  radius = 10, color = 0xffcf9a, lobes = 1, density = 0.7,
  expandAUperYr = 0, sceneScale = 1, seed = 1,
}) {
  const mat = new THREE.ShaderMaterial({
    uniforms: {
      uColor: { value: new THREE.Color(color) },
      uDensity: { value: density },
      uTime: { value: 0 },
      uSeed: { value: seed },
    },
    transparent: true, depthWrite: false, side: THREE.DoubleSide,
    blending: THREE.AdditiveBlending,
    vertexShader: `
      varying vec3 vObj; varying vec3 vView; varying vec3 vN;
      void main(){
        vObj = normalize(position);
        vN = normalize(mat3(modelMatrix) * normal);
        // Camera-relative, never through an absolute world coordinate — see
        // sim/star_visual.js for why float32 world positions destroy a small
        // body's silhouette. vView is that offset rotated back into world
        // space by the transpose of the (orthonormal) view rotation.
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        mat3 vr = mat3(viewMatrix);
        vView = -vec3(dot(vr[0], mv.xyz), dot(vr[1], mv.xyz), dot(vr[2], mv.xyz));
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: `
      precision highp float;
      uniform vec3 uColor; uniform float uDensity, uTime, uSeed;
      varying vec3 vObj; varying vec3 vView; varying vec3 vN;
      float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1,113.5,7.9))) * 43758.5453); }
      float noise(vec3 p){
        vec3 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
        return mix(mix(mix(hash(i),             hash(i+vec3(1,0,0)), f.x),
                       mix(hash(i+vec3(0,1,0)), hash(i+vec3(1,1,0)), f.x), f.y),
                   mix(mix(hash(i+vec3(0,0,1)), hash(i+vec3(1,0,1)), f.x),
                       mix(hash(i+vec3(0,1,1)), hash(i+vec3(1,1,1)), f.x), f.y), f.z);
      }
      float fbm(vec3 p){ float v=0.0,a=0.5; for(int i=0;i<5;i++){ v+=a*noise(p); p*=2.13; a*=0.5; } return v; }
      void main(){
        vec3 V = normalize(vView);
        float mu = abs(dot(normalize(vN), V));
        // Limb brightening: an optically thin shell is brightest where the
        // sightline is most nearly tangent to it, i.e. where mu -> 0. The
        // column depth through a thin shell goes as 1/mu.
        float limb = pow(1.0 - mu, 2.4) + 0.06;
        // Filamentary structure. Real ejecta are shredded by Rayleigh-Taylor
        // instabilities at the contact between fast and slow material, which
        // is what makes every nebula stringy rather than smooth.
        float fil = fbm(vObj * 5.0 + uSeed) * 0.7 + fbm(vObj * 17.0 - uSeed) * 0.45;
        float a = limb * uDensity * (0.35 + fil);
        gl_FragColor = vec4(uColor * a * 2.2, clamp(a, 0.0, 1.0) * 0.85);
      }`,
  });

  const group = new THREE.Group();
  const shells = [];
  // A bipolar cloud is two lobes thrown along the rotation axis — which is what
  // happens whenever the ejection is collimated by rotation or by a companion,
  // and is why the Homunculus is an hourglass and not a sphere.
  const n = Math.max(1, lobes | 0);
  for (let i = 0; i < n; i++) {
    const m = new THREE.Mesh(new THREE.SphereGeometry(1, 48, 36), mat);
    if (n > 1) {
      m.position.y = (i === 0 ? 1 : -1) * 0.85;
      m.scale.set(0.78, 1.0, 0.78);
    }
    group.add(m);
    shells.push(m);
  }
  group.renderOrder = -2;

  let r = radius, t = 0;
  function update(simDt, scale = sceneScale) {
    t += simDt;
    mat.uniforms.uTime.value = t;
    r = radius + expandAUperYr * t;
    group.scale.setScalar(r * scale);
  }
  update(0, sceneScale);

  return {
    group, update,
    get radiusAU() { return r; },
    dispose() {
      for (const m of shells) m.geometry.dispose();
      mat.dispose();
    },
  };
}

// ============================================================================
// The painter's own bookkeeping: a list of decorations, each pinned to a body
// (or to the scene origin), updated together and disposed together.
// ============================================================================
export function createPainter({ scene, getBody, getSceneScale }) {
  const items = [];

  function add(kind, opts) {
    const scale = getSceneScale();
    let it;
    if (kind === 'cloud') {
      it = createGasCloud({ ...opts, sceneScale: scale });
    } else {
      it = createOrbitalSwarm({ ...opts, sceneScale: scale });
    }
    it.kind = kind;
    it.bodyId = opts.bodyId ?? null;
    it.label = opts.label ?? kind;
    scene.add(it.group);
    items.push(it);
    return it;
  }

  function update(simDt) {
    const scale = getSceneScale();
    for (const it of items) {
      it.update(simDt, scale);
      // Pinned decorations follow their body. A ring is bound to its planet,
      // so it has to travel with it — including through the planet's own orbit.
      if (it.bodyId != null) {
        const b = getBody(it.bodyId);
        // Gone OR dead: a body marked !alive has already lost its meshes, so
        // reading b.viz would be reading a corpse, and leaving the decoration
        // pinned to its last position leaves a ring around nothing.
        if (b && b.alive) it.group.position.copy(b.viz.group.position);
        else it.orphan = true;
      }
    }
    // A decoration whose body is gone goes with it.
    for (let i = items.length - 1; i >= 0; i--) {
      if (items[i].orphan) { remove(items[i]); }
    }
  }

  function remove(it) {
    const i = items.indexOf(it);
    if (i < 0) return;
    items.splice(i, 1);
    scene.remove(it.group);
    it.dispose();
  }

  function clear() { while (items.length) remove(items[0]); }

  return { add, update, remove, clear, get items() { return items; } };
}
