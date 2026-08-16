import * as THREE from 'three';
import * as PHYS from './sim/physics.js';
import { createBodyVisual } from './sim/bodies.js';
import { GAS_PALETTES } from './sim/textures.js';
import { PRESETS, PRESET_ORDER } from './sim/presets.js';
import { Climate } from './sim/climate.js';
import { createSkyPass, SurfaceObserver } from './sim/skyview.js';
import { MAX_SUNS } from './sim/world.js';
import { luminosity, effectiveTemp, radiusSun, blackbodyColor, spectralClass } from './sim/stellar.js';
import { createBlackHolePass, MAX_HOLES } from './sim/blackhole.js';
import { createPostFX } from './sim/postfx.js';
import { BANDS, VISIBLE_BAND } from './sim/spectrum.js';
import { physicalRadiusAU, createMarker } from './sim/scale.js';

// ============================================================================
// STATE
// ============================================================================
const state = {
  preset: null,            // active preset object
  sceneScale: 2.0,         // scene units per AU
  bodyScale: 1.0,
  trueScale: false,        // draw bodies at their real radius (see sim/scale.js)
  timeScale: 2.0,          // sim years per real second (× speed)
  maxStep: 5e-3,           // max integrator step (yr)
  gwBoost: 0,
  lensing: true,

  mass: 10,                // sandbox BH mass (M☉)
  discIntensity: 0.9,
  discTemp: 0.6,
  showMesh: true,
  showLens: true,
  speed: 1.0,
  paused: false,

  camMode: 'orbit',        // 'orbit' | 'free' | 'surface'
  followId: null,          // body id the orbit camera tracks
  focusId: null,           // selected body id

  bodies: [],
  consumed: 0,
  nextId: 1,
  time: 0,
  simYears: 0,             // elapsed SIMULATED time (yr) — what the climate runs on
  homeId: null,            // the inhabited world, if the preset has one
  climate: null,
  exposure: 1,             // surface-view eye adaptation
  suns: [],                // live star light sources, brightest first
  band: 3,                 // imaging band index (see sim/spectrum.js)
  hudHidden: false,
};

const DOM = {};
['fps', 'rs', 'isco', 'bc', 'cc', 'count', 'bodyList', 'loading', 'massRow',
 'blurb', 'presetName', 'focusName', 'focusPanel', 'camOrbit', 'camFree',
 'discRow', 'tempRow', 'speedVal', 'camSurface', 'climatePanel', 'eraBadge',
 'eraDesc', 'cTemp', 'cFlux', 'cIce', 'cCloud', 'cTau', 'cExtremes', 'climateChart',
 'sunList', 'simClock', 'starPanel', 'surfRow', 'skyRow', 'bhPanel',
 'bandGrid', 'bandNote', 'bandLabel', 'toast', 'panelTabs'].forEach(id => DOM[id] = document.getElementById(id));

// ============================================================================
// SCENE / RENDERER / CAMERA
// ============================================================================
const scene  = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(50, innerWidth / innerHeight, 0.01, 100000);
camera.position.set(0, 8, 24);

const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(devicePixelRatio, 1.5));
renderer.setSize(innerWidth, innerHeight);
renderer.setClearColor(0x000000, 1);
// The frame is composed in linear HDR and tone mapped by sim/postfx.js, so the
// renderer must NOT apply a curve or an sRGB transfer of its own on the way
// into the float target — that would double-encode everything.
renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
renderer.toneMapping = THREE.NoToneMapping;
document.getElementById('canvas-wrap').appendChild(renderer.domElement);

const postfx = createPostFX(renderer);

const ambient = new THREE.AmbientLight(0x223044, 0.6); scene.add(ambient);
const sunLight = new THREE.PointLight(0xffffff, 2.2, 0, 0); scene.add(sunLight);

// A pool of real lights, one per star, so multi-star systems cast the several
// overlapping terminators that make a Trisolaran sky what it is.
const starLights = Array.from({ length: MAX_SUNS }, () => {
  const l = new THREE.PointLight(0xffffff, 0, 0, 0);
  l.visible = false; scene.add(l); return l;
});

// ============================================================================
// STARFIELD
// ============================================================================
function makeStarTexture(size = 2048) {
  const c = document.createElement('canvas'); c.width = size; c.height = size / 2;
  const ctx = c.getContext('2d');
  const g = ctx.createLinearGradient(0, 0, 0, c.height);
  g.addColorStop(0, '#02030a'); g.addColorStop(0.5, '#050416'); g.addColorStop(1, '#02030a');
  ctx.fillStyle = g; ctx.fillRect(0, 0, c.width, c.height);
  for (let i = 0; i < 16; i++) {
    const x = Math.random() * c.width, y = Math.random() * c.height, r = 120 + Math.random() * 300;
    const rg = ctx.createRadialGradient(x, y, 0, x, y, r);
    rg.addColorStop(0, `hsla(${200 + Math.random() * 70},70%,45%,0.10)`); rg.addColorStop(1, 'hsla(0,0%,0%,0)');
    ctx.fillStyle = rg; ctx.fillRect(0, 0, c.width, c.height);
  }
  for (let i = 0; i < 9000; i++) {
    const x = Math.random() * c.width, y = Math.random() * c.height;
    const sz = Math.pow(Math.random(), 10) * 2.6 + 0.25, b = 0.5 + Math.random() * 0.5, t = Math.random();
    ctx.fillStyle = t < 0.7 ? `rgba(255,255,255,${b})` : t < 0.85 ? `rgba(200,220,255,${b})`
                  : t < 0.95 ? `rgba(255,230,200,${b})` : `rgba(255,180,180,${b})`;
    ctx.beginPath(); ctx.arc(x, y, sz, 0, Math.PI * 2); ctx.fill();
  }
  const tex = new THREE.CanvasTexture(c);
  tex.mapping = THREE.EquirectangularReflectionMapping; tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}
const starTex = makeStarTexture();
scene.background = starTex;

// ============================================================================
// LENSING / ACCRETION-DISC PASS
// The whole general-relativistic ray marcher now lives in sim/blackhole.js.
// ============================================================================
const lensPass = createBlackHolePass(starTex);
const lensMaterial = lensPass.material;
const lensScene = lensPass.scene;
const lensCam = lensPass.camera;

// ============================================================================
// SPACETIME MESH (wells from holes + bodies)
// ============================================================================
const MESH_SIZE = 120, MESH_SEG = 110;
const meshGeo = new THREE.PlaneGeometry(MESH_SIZE, MESH_SIZE, MESH_SEG, MESH_SEG);
meshGeo.rotateX(-Math.PI / 2);
const meshMat = new THREE.ShaderMaterial({
  uniforms: { time: { value: 0 }, wells: { value: Array.from({ length: 16 }, () => new THREE.Vector4()) }, wellCount: { value: 0 } },
  transparent: true, wireframe: true,
  vertexShader: `
    uniform vec4 wells[16]; uniform int wellCount; varying float vDepth; varying vec2 vPos;
    void main(){ vec3 p=position; vPos=p.xz; float dip=0.0;
      for(int i=0;i<16;i++){ if(i>=wellCount) break;
        float d=distance(p.xz, wells[i].xy); float s=wells[i].z; float isHole=wells[i].w;
        if(isHole>0.5) dip += s*2.4/(0.5+d*0.14);
        else dip += s*0.8/(d+0.5); }
      p.y -= dip; vDepth=dip;
      gl_Position=projectionMatrix*modelViewMatrix*vec4(p,1.0); }`,
  fragmentShader: `
    varying float vDepth; varying vec2 vPos;
    void main(){ float r=length(vPos); float alpha=(1.0-smoothstep(18.0,60.0,r))*0.30+0.04;
      float it=clamp(vDepth*0.08+0.1,0.0,1.0);
      gl_FragColor=vec4(mix(vec3(0.2,0.35,0.6),vec3(0.8,0.4,0.15),it),alpha); }`,
});
const spacetimeMesh = new THREE.Mesh(meshGeo, meshMat);
spacetimeMesh.position.y = -6;
scene.add(spacetimeMesh);

// merger flash sprites
const flashes = [];
function spawnFlash(worldPos, color, size, decay = 0.8) {
  const cv = document.createElement('canvas'); cv.width = cv.height = 128;
  const g = cv.getContext('2d');
  const rg = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  const h = '#' + color.toString(16).padStart(6, '0');
  rg.addColorStop(0, '#ffffff'); rg.addColorStop(0.3, h + 'cc'); rg.addColorStop(1, h + '00');
  g.fillStyle = rg; g.fillRect(0, 0, 128, 128);
  const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(cv), blending: THREE.AdditiveBlending, transparent: true, depthWrite: false }));
  sp.position.copy(worldPos); sp.scale.setScalar(size); scene.add(sp);
  flashes.push({ sp, life: 1, size, decay });
}

// ============================================================================
// BODY CREATION
// ============================================================================
const TRAIL_MAX = 600;
function baseRadius(type, mass) {
  switch (type) {
    // Rendered star size now follows the real main-sequence mass–radius
    // relation, so a 2 M☉ star is visibly bigger than a 0.85 M☉ one.
    case 'star': return 0.34 * radiusSun(mass);
    // A neutron star is ~12 km across sitting in an orbit millions of times
    // wider, so its rendered size is pure exaggeration either way. It used to
    // be 0.09 and was carried entirely by a glow sprite pasted over it; now
    // that it has an actual lensed surface, polar caps and a magnetosphere,
    // it needs enough pixels for any of that to be visible.
    case 'neutron': return 0.30;
    case 'gas-giant': return 0.30;
    case 'world': return 0.13;
    case 'planet': return 0.15;
    default: return 0.2;
  }
}
// Rendered radius in SCENE units. Black holes are always honest — their
// horizon is the thing you came to look at. Everything else is either the real
// geometric radius (true scale) or the readable, exaggerated stand-in.
function renderRadius(b, spec, mass) {
  if (spec.type === 'bh') return b.rs * state.sceneScale;
  if (state.trueScale && b.radius > 0) return b.radius * state.sceneScale;
  return baseRadius(spec.type, mass) * state.bodyScale;
}

const TYPE_DEFAULTS = {
  star:    { mass: 1.0, color: 0xffe0a0, glow: 0xff8040 },
  neutron: { mass: 1.4, color: 0xcfe8ff, glow: 0x88c4ff },
  'gas-giant': { mass: 9.5e-4, color: 0xd4a574, glow: 0x6a4828 },
  planet:  { mass: 3e-6, color: 0x6a90c0, glow: 0x3a6a9a },
  world:   { mass: 3e-6, color: 0x6a90c0, glow: 0x3a6a9a },
  bh:      { mass: 10, color: 0x000000, glow: 0x000000 },
};

// ---------------------------------------------------------------------------
// Build (or rebuild) a body's renderable half from its stored spec. Split out
// of spawnBody so the size convention can change at runtime — the physics body
// keeps its position, velocity and mass; only the meshes are thrown away.
// ---------------------------------------------------------------------------
function attachVisual(b) {
  const spec = b.spec, def = b.def;
  const radiusScene = renderRadius(b, spec, b.mass0);
  b.radiusScene = radiusScene;
  b.contactAU = radiusScene / state.sceneScale;
  if (spec.type === 'bh') b.rsScene = radiusScene;

  const palette = spec.palette ? GAS_PALETTES[spec.palette] : null;
  // Stars are coloured from their blackbody temperature unless a preset
  // deliberately overrides it (the figure-eight uses colour to tell bodies apart).
  const starColor = spec.color != null ? new THREE.Color(spec.color)
                  : (b.teff ? blackbodyColor(b.teff) : null);
  const viz = createBodyVisual(b, {
    radiusScene,
    color: spec.type === 'star' ? starColor : (spec.color ?? def.color),
    teff: b.teff,
    glow: spec.glow ?? def.glow,
    seed: spec.seed,
    obliquity: spec.obliquity,
    palette, hot: spec.hot, atmosphere: spec.atmosphere, atmColor: spec.atmColor,
    seaLevel: spec.seaLevel, rings: spec.rings, ringColor: spec.ringColor,
  });
  viz.group.userData.bodyId = b.id;
  viz.group.userData.baseScale = 1;
  viz.group.position.copy(b.pos).multiplyScalar(state.sceneScale);
  scene.add(viz.group);

  // Point-source marker: what keeps a true-scale body visible once its disc
  // falls below a pixel. It lives in the scene rather than under viz.group so
  // its size is never coupled to whatever the body's own visual does to its
  // transform (tidal stretching, flare pulses).
  const markerColor = spec.type === 'star'
    ? (starColor ?? new THREE.Color(0xfff2cc))
    : new THREE.Color(spec.color ?? def.color);
  b.marker = createMarker({
    color: markerColor,
    teff: b.teff ?? 0,
    // Emitters must stay bright enough to survive tone mapping and trip the
    // bloom; reflectors only need to be seen.
    gain: spec.type === 'star' ? 26 : (spec.type === 'neutron' ? 18 : 2.2),
  });
  scene.add(b.marker.mesh);
}

function detachVisual(b) {
  if (b.viz) {
    scene.remove(b.viz.group);
    b.viz.group.traverse(o => { o.geometry?.dispose?.(); o.material?.dispose?.(); });
  }
  if (b.marker) { scene.remove(b.marker.mesh); b.marker.dispose(); b.marker = null; }
}

// Swap every body between true and exaggerated size in place. Rebuilding is the
// honest way to do this: each visual bakes its radius into geometry and into
// local-space offsets (corona span, ring radii, prominence loops), so scaling
// the group would leave those subtly wrong.
function rebuildVisuals() {
  for (const b of state.bodies) { detachVisual(b); attachVisual(b); }
  // the follow distance was framed for the old size and is now meaningless
  const fb = state.bodies.find(x => x.id === state.followId);
  if (fb) cam.radius = Math.max(fb.radiusScene, fb.rsScene || 0) * 7;
  if (state.camMode === 'orbit') updateOrbitCam();
}

function spawnBody(spec) {
  const def = TYPE_DEFAULTS[spec.type] || TYPE_DEFAULTS.planet;
  const mass = spec.mass ?? def.mass;
  const b = {
    id: state.nextId++,
    type: spec.type,
    name: spec.name || spec.type.toUpperCase(),
    mass, mass0: mass,
    pos: new THREE.Vector3(...(spec.pos || [0, 0, 0])),     // AU
    vel: new THREE.Vector3(...(spec.vel || [0, 0, 0])),     // AU/yr
    acc: new THREE.Vector3(),
    alive: true,
    emitsGW: spec.emitsGW ?? (spec.type === 'bh' || spec.type === 'neutron'),
    spin: spec.spin,
  };

  if (spec.type === 'bh') {
    b.rs = spec.rs ?? PHYS.schwarzschild(mass);            // effective horizon (AU)
  } else if (spec.type === 'neutron') {
    b.radius = PHYS.neutronRadius(mass);
    b.rs = PHYS.schwarzschild(mass);
  } else if (spec.type === 'star') {
    b.radius = PHYS.stellarRadius(mass);
    // stellar properties derived from mass alone (see sim/stellar.js)
    b.luminosity = spec.luminosity ?? luminosity(mass);
    b.teff = spec.teff ?? effectiveTemp(mass);
    b.spectral = spectralClass(b.teff);
  } else {
    // Planets and worlds now carry a REAL radius (AU) rather than the old
    // 0.0001 placeholder — true-scale rendering needs it, and it also makes the
    // collision test physical instead of arbitrary. sim/scale.js falls back to a
    // mass–radius relation when a preset gives no measured radiusKm.
    b.radius = physicalRadiusAU(spec.type, mass, spec.radiusKm);
  }
  if (spec.type === 'world') {
    b.dayLength = spec.dayLength ?? 1 / 90;
    b.obliquity = spec.obliquity ?? 0.35;
    b.home = !!spec.home;
  }

  // the spec is kept so the visual can be rebuilt at a different size without
  // disturbing the physics state (see rebuildVisuals)
  b.spec = spec; b.def = def;
  attachVisual(b);
  if (spec.type === 'world' && spec.home) state.homeId = b.id;

  // trail — compact bodies (tight, fast inspirals) get a short, faint trail so
  // the dense loops don't obscure what's happening; everything else gets a long one.
  const compact = spec.type === 'bh' || spec.type === 'neutron';
  const tMax = compact ? 130 : TRAIL_MAX;
  const tOpacity = compact ? 0.28 : 0.5;
  const trailGeo = new THREE.BufferGeometry();
  trailGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(tMax * 3), 3));
  const colArr = new Float32Array(tMax * 3);
  const tc = new THREE.Color(spec.color ?? def.glow ?? 0x88aaff);
  for (let i = 0; i < tMax; i++) {
    const k = i / (tMax - 1);
    colArr[i * 3] = tc.r * k; colArr[i * 3 + 1] = tc.g * k; colArr[i * 3 + 2] = tc.b * k;
  }
  trailGeo.setAttribute('color', new THREE.BufferAttribute(colArr, 3));
  const trail = new THREE.Line(trailGeo, new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: tOpacity, blending: THREE.AdditiveBlending }));
  trail.frustumCulled = false;
  scene.add(trail);
  b.trail = trail;
  b.trailMax = tMax;
  b.trailBuf = new Float32Array(tMax * 3);
  b.trailHead = 0; b.trailCount = 0;

  state.bodies.push(b);
  return b;
}

function removeBody(id) {
  const idx = state.bodies.findIndex(b => b.id === id);
  if (idx < 0) return;
  const b = state.bodies[idx];
  detachVisual(b);
  scene.remove(b.trail);
  b.trail.geometry.dispose();
  state.bodies.splice(idx, 1);
  if (state.focusId === id) { state.focusId = null; state.followId = null; }
  refreshUI();
}

function clearBodies() {
  while (state.bodies.length) removeBody(state.bodies[0].id);
  state.consumed = 0; refreshUI();
}

// add a body orbiting the dominant mass (used by Spawn buttons)
function spawnOrbiting(type) {
  const center = state.bodies.reduce((a, b) => (b.mass > (a?.mass ?? -1) ? b : a), null);
  const Mc = center ? center.mass : 1;
  const cpos = center ? center.pos : new THREE.Vector3();
  const aAU = (5 + Math.random() * 9) / state.sceneScale + (center ? center.radiusScene / state.sceneScale : 0);
  const ang = Math.random() * Math.PI * 2;
  const dir = new THREE.Vector3(Math.cos(ang), 0, Math.sin(ang));
  const pos = cpos.clone().addScaledVector(dir, aAU);
  const v = PHYS.circularSpeed(Mc, aAU);
  const tang = new THREE.Vector3(-Math.sin(ang), 0, Math.cos(ang)).multiplyScalar(v);
  if (center) tang.add(center.vel);
  const palette = type === 'gas-giant' ? ['jupiter', 'saturn', 'ice'][Math.floor(Math.random() * 3)] : undefined;
  spawnBody({ type, pos: [pos.x, pos.y, pos.z], vel: [tang.x, tang.y, tang.z], palette, atmosphere: type === 'planet', seed: Math.floor(Math.random() * 1e9) });
  refreshUI();
}

// ============================================================================
// PHYSICS STEP
// ============================================================================
function getHoles() {
  return state.bodies.filter(b => b.type === 'bh').sort((a, b) => b.mass - a.mass);
}

function getStars() {
  return state.bodies.filter(b => b.type === 'star' && b.alive);
}
function getHome() {
  return state.homeId != null ? state.bodies.find(b => b.id === state.homeId) : null;
}

// Hottest emitter in the scene, in kelvin. The multi-wavelength imaging anchors
// its gain to this — see postfx.setSceneTemp.
function sceneMaxTemp() {
  let t = 0;
  for (const b of state.bodies) {
    if (b.type === 'star') t = Math.max(t, b.teff ?? effectiveTemp(b.mass));
    else if (b.type === 'neutron') t = Math.max(t, 1.0e6);
    // thin-disc peak, T ∝ M^(−1/4)
    else if (b.type === 'bh') t = Math.max(t, 2.0e7 * Math.pow(Math.max(b.mass, 0.1), -0.25));
  }
  return t || 5800;
}

// Build the per-frame sun description used by every lighting path: the world
// shader, the sky shader and the real THREE lights. Intensity is the star's
// flux AT THE HOME WORLD in solar constants, so the visual brightness of each
// sun tracks the same number the climate model is integrating.
const _sv = new THREE.Vector3();
function updateSuns() {
  const stars = getStars();
  const home = getHome();
  state.suns.length = 0;
  for (const s of stars) {
    const L = (s.luminosity ?? luminosity(s.mass)) * (s.activity ? s.activity.flux : 1);
    const d = home ? Math.max(home.pos.distanceTo(s.pos), 1e-3) : 1;
    state.suns.push({
      body: s,
      posScene: s.viz.group.position,
      color: blackbodyColor(s.teff ?? effectiveTemp(s.mass)),
      intensity: home ? L / (d * d) : L,
      distAU: d,
      // true angular RADIUS as rendered, for the sky pass
      angRadius: Math.atan((s.radiusScene) / Math.max(d * state.sceneScale, 1e-4)),
      // and the physically true one, for the readout
      angTrue: Math.atan(PHYS.stellarRadius(s.mass) / d),
    });
  }
  state.suns.sort((a, b) => b.intensity - a.intensity);

  // drive the real lights
  for (let i = 0; i < starLights.length; i++) {
    const l = starLights[i], s = state.suns[i];
    if (!s) { l.visible = false; continue; }
    l.visible = true;
    l.position.copy(s.posScene);
    l.color.copy(s.color);
    // a light's falloff is handled by THREE; scale by luminosity so the big
    // star really does out-light the small one
    l.intensity = 2.0 * Math.pow(s.body.luminosity ?? 1, 0.45);
  }
  // the legacy single light is only for presets with no stars (black holes)
  sunLight.visible = state.suns.length === 0;
}

// Smallest resolved-needs timescale among bodies — the dynamical time of the
// tightest/ fastest pair. Used to shrink the step during close encounters so a
// fast in-spiral can't slingshot out from integration error.
function dynamicStep() {
  let tMin = state.maxStep;
  const bs = state.bodies;
  for (let i = 0; i < bs.length; i++) {
    if (!bs[i].alive) continue;
    for (let j = i + 1; j < bs.length; j++) {
      if (!bs[j].alive) continue;
      const sep = bs[i].pos.distanceTo(bs[j].pos);
      const mu = PHYS.G * (bs[i].mass + bs[j].mass);
      const tFall = Math.sqrt((sep * sep * sep) / Math.max(mu, 1e-9));   // free-fall time
      const vrel = bs[i].vel.distanceTo(bs[j].vel);
      const tFly = sep / Math.max(vrel, 1e-6);                            // crossing time
      tMin = Math.min(tMin, 0.05 * tFall, 0.08 * tFly);
    }
  }
  return Math.max(tMin, 1e-8);
}

function stepPhysics(simDt) {
  if (simDt <= 0) return;
  let remaining = simDt, guard = 0;
  while (remaining > 1e-12 && guard < 8000) {
    guard++;
    const h = Math.min(remaining, dynamicStep());
    PHYS.integrate(state.bodies, h);
    if (state.gwBoost) PHYS.applyGWReaction(state.bodies, h, state.gwBoost);
    const events = PHYS.resolveCollisions(state.bodies);
    for (const ev of events) handleMerger(ev);
    remaining -= h;
  }
  state.simYears += simDt;
  // commit visual positions + trails after the sub-steps
  for (const b of state.bodies) {
    b.viz.group.position.copy(b.pos).multiplyScalar(state.sceneScale);
    pushTrail(b);
  }
  // advance the climate on the same simulated clock
  const home = getHome();
  if (state.climate && home) state.climate.step(simDt, home, getStars());
}

function handleMerger(ev) {
  const surv = ev.survivor, gone = ev.absorbed;
  const wpos = surv.pos.clone().multiplyScalar(state.sceneScale);
  if (surv.type === 'bh' || gone.type === 'bh') {
    const wasBH = surv.type === 'bh';
    surv.type = 'bh';
    surv.rs = (wasBH ? (surv.rs || 0) : 0) + (gone.type === 'bh' ? gone.rs : PHYS.schwarzschild(gone.mass));
    if (!surv.rs) surv.rs = PHYS.schwarzschild(surv.mass);
    const rsS = surv.rs * state.sceneScale;
    spawnFlash(wpos, 0xffffff, rsS * 9, 1.6);             // bright ringdown burst
    spawnFlash(wpos, 0xffd2a0, rsS * 5, 0.32);            // slow lingering afterglow
  } else if (surv.type === 'neutron' && gone.type === 'neutron') {
    spawnFlash(wpos, 0xffffff, surv.radiusScene * 60, 1.4);
    spawnFlash(wpos, 0xbfe0ff, surv.radiusScene * 34, 0.28);   // kilonova glow
  } else {
    spawnFlash(wpos, 0xffaa66, surv.radiusScene * 14, 0.8);
  }
  state.consumed++;
  removeBody(gone.id);
  refreshUI();
}

function pushTrail(b) {
  const M = b.trailMax;
  const p = b.viz.group.position;
  const head = b.trailHead;
  b.trailBuf[head * 3] = p.x; b.trailBuf[head * 3 + 1] = p.y; b.trailBuf[head * 3 + 2] = p.z;
  b.trailHead = (head + 1) % M;
  b.trailCount = Math.min(b.trailCount + 1, M);
  const tp = b.trail.geometry.attributes.position.array;
  const oldest = (b.trailHead - b.trailCount + M) % M;
  const firstSeg = M - oldest;
  if (b.trailCount <= firstSeg) {
    tp.set(b.trailBuf.subarray(oldest * 3, (oldest + b.trailCount) * 3), 0);
  } else {
    tp.set(b.trailBuf.subarray(oldest * 3), 0);
    tp.set(b.trailBuf.subarray(0, (b.trailCount - firstSeg) * 3), firstSeg * 3);
  }
  b.trail.geometry.setDrawRange(0, b.trailCount);
  b.trail.geometry.attributes.position.needsUpdate = true;
}

// ============================================================================
// CAMERA — orbit + free-fly + click-to-focus
// ============================================================================
const cam = {
  target: new THREE.Vector3(), radius: 24, theta: Math.PI / 2 - 0.35, phi: Math.PI / 2,
  // free fly
  yaw: 0, pitch: 0, freeSpeed: 12,
};
const keys = {};
const observer = new SurfaceObserver();
const skyPass = createSkyPass();
function updateOrbitCam() {
  const { radius, theta, phi } = cam;
  camera.position.set(radius * Math.sin(theta) * Math.cos(phi), radius * Math.cos(theta), radius * Math.sin(theta) * Math.sin(phi)).add(cam.target);
  camera.lookAt(cam.target);
}
// Pick radius in scene units. Clicking works off the body's rendered disc,
// which at true scale can be a millionth of the screen — so once a body has
// handed over to its point-source marker, the marker's own on-screen footprint
// becomes the target instead. Below that it is not clickable at all, which is
// fine: the Bodies list is the reliable way to reach a distant world, and
// aiming at a sub-pixel dot never was.
function pickRadiusScene(b) {
  const geometric = Math.max(b.radiusScene, b.rsScene || 0) * 1.6;
  if (!b.marker || !b.marker.mesh.visible) return geometric;
  return Math.max(geometric, b.marker.mesh.scale.x * 0.42);
}

function setFollow(body) {
  state.followId = body ? body.id : null;
  state.focusId = body ? body.id : null;
  if (body) {
    cam.target.copy(body.viz.group.position);
    // frame the body itself — a 4-unit floor put small worlds a hundred radii away
    cam.radius = Math.max(body.radiusScene, body.rsScene || 0) * 7;
    if (state.camMode === 'orbit') updateOrbitCam();
  }
  refreshUI();
}

// pointer / drag
let dragging = false, dragMoved = false, lastX = 0, lastY = 0, downX = 0, downY = 0;
const el = renderer.domElement;
el.addEventListener('mousedown', e => { dragging = true; dragMoved = false; lastX = downX = e.clientX; lastY = downY = e.clientY; });
addEventListener('mouseup', e => {
  dragging = false;
  if (!dragMoved) handlePick(e);
});
addEventListener('mousemove', e => {
  if (!dragging) return;
  const dx = e.clientX - lastX, dy = e.clientY - lastY;
  if (Math.abs(e.clientX - downX) + Math.abs(e.clientY - downY) > 4) dragMoved = true;
  lastX = e.clientX; lastY = e.clientY;
  if (state.camMode === 'orbit') {
    cam.phi -= dx * 0.005;
    cam.theta = Math.max(0.05, Math.min(Math.PI - 0.05, cam.theta - dy * 0.005));
    updateOrbitCam();
  } else if (state.camMode === 'surface') {
    // scale the look speed with the zoom, so a narrow FOV pans slowly
    const k = observer.fov / 62 * 0.0032;
    observer.look(-dx * k, -dy * k);
  } else {
    cam.yaw -= dx * 0.0025; cam.pitch = Math.max(-1.5, Math.min(1.5, cam.pitch - dy * 0.0025));
  }
});
el.addEventListener('wheel', e => {
  e.preventDefault();
  // The zoom floor used to be 0.05 scene units — twenty times wider than a
  // true-scale Earth, so you could never actually reach one. It now only has to
  // stay clear of float32 denormals.
  if (state.camMode === 'orbit') { cam.radius = Math.max(1e-6, Math.min(20000, cam.radius * (1 + e.deltaY * 0.001))); updateOrbitCam(); }
  else if (state.camMode === 'surface') observer.zoom(1 + e.deltaY * 0.0012);
  else cam.freeSpeed = Math.max(0.5, cam.freeSpeed * (1 - e.deltaY * 0.001));
}, { passive: false });

const raycaster = new THREE.Raycaster();
function handlePick(e) {
  const ndc = new THREE.Vector2((e.clientX / innerWidth) * 2 - 1, -(e.clientY / innerHeight) * 2 + 1);
  raycaster.setFromCamera(ndc, camera);
  let best = null, bestD = Infinity;
  for (const b of state.bodies) {
    const wp = b.viz.group.position;
    const ray = raycaster.ray;
    const d = ray.distanceToPoint(wp);
    const along = wp.clone().sub(ray.origin).dot(ray.direction);
    if (along < 0) continue;
    const hitR = pickRadiusScene(b);
    if (d < hitR && along < bestD) { best = b; bestD = along; }
  }
  if (best) setFollow(best); else setFollow(null);
}

addEventListener('keydown', e => {
  // never steal keys from a focused control (the sliders take arrows/space)
  const tag = e.target?.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
  keys[e.code] = true;
  if (e.key === 'r' || e.key === 'R') { cam.target.set(0, 0, 0); cam.radius = state.preset.camRadius; cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2; if (state.camMode === 'orbit') updateOrbitCam(); }
  if (e.code === 'Space') { e.preventDefault(); state.paused = !state.paused; }
  if (e.key === 'f' || e.key === 'F') setCamMode(state.camMode === 'orbit' ? 'free' : 'orbit');
  if (e.key === 'v' || e.key === 'V') setCamMode(state.camMode === 'surface' ? 'orbit' : 'surface');
  if (e.key === 'h' || e.key === 'H') setHudHidden(!state.hudHidden);
  // 1–7 select the imaging band, in spectrum order
  if (e.code.startsWith('Digit')) {
    const n = +e.code.slice(5);
    if (n >= 1 && n <= BANDS.length) setBand(n - 1);
  }
  if ((e.key === 'Delete' || e.key === 'Backspace') && state.focusId != null) removeBody(state.focusId);
});
addEventListener('keyup', e => { keys[e.code] = false; });

function setCamMode(mode) {
  if (mode === 'surface' && !getHome()) mode = 'orbit';    // nowhere to stand
  if (mode === 'free' && state.camMode !== 'free') {
    // seed yaw/pitch from current look direction
    const dir = cam.target.clone().sub(camera.position).normalize();
    cam.yaw = Math.atan2(dir.x, dir.z); cam.pitch = Math.asin(THREE.MathUtils.clamp(dir.y, -1, 1));
  }
  const wasSurface = state.camMode === 'surface';
  state.camMode = mode;
  if (mode === 'surface') {
    camera.near = 0.002;
    // At system speeds the planet spins tens of times a second and the sky is a
    // blur, so entering the surface view drops to a pace where a day is watchable.
    if (!wasSurface) applyRegime('day');
    // point the observer at the brightest sun so you don't start facing a wall
    aimAtBrightestSun();
  } else if (wasSurface) {
    camera.near = 0.01;
    camera.up.set(0, 1, 0);
    camera.fov = 50;
  }
  camera.updateProjectionMatrix();
  DOM.camOrbit.classList.toggle('active', mode === 'orbit');
  DOM.camFree.classList.toggle('active', mode === 'free');
  DOM.camSurface?.classList.toggle('active', mode === 'surface');
  if (DOM.skyRow) DOM.skyRow.style.display = mode === 'surface' ? '' : 'none';
}

// Turn the observer to face whichever sun is currently brightest overhead.
function aimAtBrightestSun() {
  const home = getHome();
  if (!home || !state.suns.length) return;
  observer.update(home, camera);
  const up = observer.up, north = observer.north;
  const east = new THREE.Vector3().crossVectors(up, north);
  // prefer a sun that is actually above the horizon
  let best = null, bestScore = -Infinity;
  for (const s of state.suns) {
    const d = s.posScene.clone().sub(observer.eye).normalize();
    const elev = d.dot(up);
    const score = elev > -0.05 ? s.intensity * (elev + 0.2) : -1 + s.intensity * 1e-3;
    if (score > bestScore) { bestScore = score; best = d; }
  }
  if (!best) return;
  observer.azimuth = Math.atan2(best.dot(east), best.dot(north));
  // If every sun is down, look at the horizon rather than at our own feet.
  const sunElev = Math.asin(THREE.MathUtils.clamp(best.dot(up), -1, 1));
  observer.elevation = sunElev < 0.05
    ? 0.12
    : THREE.MathUtils.clamp(sunElev, 0.05, 1.1);
}

const _fwd = new THREE.Vector3(), _right = new THREE.Vector3(), _up = new THREE.Vector3(0, 1, 0);
function updateFreeCam(dt) {
  _fwd.set(Math.sin(cam.yaw) * Math.cos(cam.pitch), Math.sin(cam.pitch), Math.cos(cam.yaw) * Math.cos(cam.pitch)).normalize();
  _right.crossVectors(_fwd, _up).normalize();
  const sp = cam.freeSpeed * (keys['ShiftLeft'] || keys['ShiftRight'] ? 4 : 1) * dt;
  if (keys['KeyW']) camera.position.addScaledVector(_fwd, sp);
  if (keys['KeyS']) camera.position.addScaledVector(_fwd, -sp);
  if (keys['KeyD']) camera.position.addScaledVector(_right, sp);
  if (keys['KeyA']) camera.position.addScaledVector(_right, -sp);
  if (keys['KeyE'] || keys['Space']) camera.position.addScaledVector(_up, sp);
  if (keys['KeyQ'] || keys['ControlLeft']) camera.position.addScaledVector(_up, -sp);
  camera.lookAt(camera.position.clone().add(_fwd));
}

// ============================================================================
// PRESET LOADING
// ============================================================================
function loadPreset(key) {
  const p = PRESETS[key];
  if (!p) return;
  clearBodies();
  // also remove flashes
  for (const fl of flashes) scene.remove(fl.sp); flashes.length = 0;

  state.preset = p;
  state.sceneScale = p.sceneScale;
  state.bodyScale = p.bodyScale ?? 1;
  state.trueScale = !!p.trueScale;
  {
    const sb = document.querySelector('[data-view="scale"]');
    if (sb) { sb.classList.toggle('active', state.trueScale); sb.textContent = state.trueScale ? 'Sizes: Real' : 'Sizes: Boosted'; }
  }
  state.timeScale = p.timeScale ?? 2;
  state.maxStep = p.maxStep ?? 5e-3;
  state.gwBoost = p.gwBoost ?? 0;
  state.lensing = p.lensing;
  state.showLens = p.lensing;
  // Sim Speed and the paused flag are USER settings, not scenario settings —
  // they carry over. (`timeScale` does not: it is measured in simulated years
  // per second, and a neutron-star inspiral and the solar system genuinely
  // need values four orders of magnitude apart to be watchable at all. Speed
  // is the dimensionless multiplier on top of it, which is what you actually
  // set when you slow something down to look at it.)
  state.consumed = 0;
  state.focusId = state.followId = null;
  state.simYears = 0;
  state.homeId = null;
  state.suns.length = 0;

  for (const spec of p.build()) spawnBody(spec);

  // climate only exists for presets that give us a world to stand on
  state.climate = p.climate ? new Climate(p.climate) : null;
  if (state.climate) {
    const home = getHome();
    if (home) state.climate.step(1e-6, home, getStars());
  }
  updateSuns();

  // Camera reset. In a hierarchical system the total barycentre is nowhere near
  // the stars (the outer companion drags it ~11 AU away), so presets with a home
  // world start the camera following that world instead of the origin.
  cam.target.set(0, 0, 0); cam.radius = p.camRadius; cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2;
  setCamMode('orbit');
  if (p.focus) {
    const f = state.bodies.find(b => b.name === p.focus);
    if (f) { setFollow(f); cam.radius = p.camRadius; }
  }
  updateOrbitCam();
  // the spacetime slab is noise in a multi-star system; restore it elsewhere
  toggleMesh(p.mesh !== false);

  // sync the time-scale slider to the preset's own pace
  const ts = document.getElementById('timescale');
  if (ts) {
    ts.value = String(Math.log10(state.timeScale));
    document.getElementById('timescale-val').textContent =
      state.timeScale < 1 ? `${(state.timeScale * 365.25).toFixed(1)} d/s` : `${state.timeScale.toFixed(1)} yr/s`;
  }
  const home = getHome();
  const dl = document.getElementById('daylen');
  if (dl && home) {
    dl.value = String(home.dayLength * 365.25);
    document.getElementById('daylen-val').textContent = `${(home.dayLength * 365.25).toFixed(1)} d`;
  }
  const ml = document.getElementById('mixed');
  if (ml && state.climate) {
    ml.value = String(state.climate.mixedLayer);
    document.getElementById('mixed-val').textContent = `${state.climate.mixedLayer.toFixed(0)} m`;
  }

  // UI
  DOM.presetName.textContent = p.name;
  DOM.blurb.textContent = p.blurb;
  DOM.massRow.style.display = key === 'sandbox' ? '' : 'none';
  DOM.discRow.style.display = p.lensing ? '' : 'none';
  DOM.tempRow.style.display = p.lensing ? '' : 'none';
  if (DOM.bhPanel) DOM.bhPanel.style.display = getHoles().length ? '' : 'none';
  if (DOM.climatePanel) DOM.climatePanel.style.display = state.climate ? '' : 'none';
  if (DOM.starPanel) DOM.starPanel.style.display = getStars().length ? '' : 'none';
  if (DOM.surfRow) DOM.surfRow.style.display = p.surface ? '' : 'none';
  if (DOM.camSurface) DOM.camSurface.style.display = p.surface ? '' : 'none';
  spacetimeMesh.visible = state.showMesh;
  document.querySelectorAll('[data-preset]').forEach(b => b.classList.toggle('active', b.dataset.preset === key));
  refreshUI();
}

// ============================================================================
// UI
// ============================================================================
function refreshUI() {
  // body list
  if (state.bodies.length === 0) {
    DOM.bodyList.innerHTML = '<div class="empty">— empty —</div>';
  } else {
    DOM.bodyList.innerHTML = state.bodies.map(b =>
      `<div class="body-item ${b.id === state.focusId ? 'sel' : ''}" data-focus="${b.id}">
        <span class="type">#${b.id} ${b.name}</span>
        <button class="rm" data-rm="${b.id}">✕</button></div>`).join('');
    DOM.bodyList.querySelectorAll('[data-rm]').forEach(btn => btn.addEventListener('click', e => { e.stopPropagation(); removeBody(parseInt(btn.dataset.rm)); }));
    DOM.bodyList.querySelectorAll('[data-focus]').forEach(d => d.addEventListener('click', () => { const b = state.bodies.find(x => x.id == d.dataset.focus); if (b) setFollow(b); }));
  }
  DOM.count.textContent = `(${state.bodies.length})`;
  DOM.bc.textContent = state.bodies.length;
  DOM.cc.textContent = state.consumed;
  const holes = getHoles();
  DOM.rs.textContent = holes[0] ? holes[0].rs.toFixed(3) : '0.000';
  DOM.isco.textContent = holes[0] ? (3 * holes[0].rs).toFixed(3) : '0.000';
  // focus panel
  const fb = state.bodies.find(b => b.id === state.focusId);
  if (fb) {
    DOM.focusPanel.style.display = '';
    DOM.focusName.textContent = `${fb.name} · ${fb.mass < 0.01 ? (fb.mass).toExponential(2) : fb.mass.toFixed(2)} M☉`;
  } else DOM.focusPanel.style.display = 'none';
}

// ----------------------------------------------------------------------------
// CLIMATE / STAR HUD
// ----------------------------------------------------------------------------
function fmtYears(y) {
  if (y < 1) return `${(y * 365.25).toFixed(1)} d`;
  if (y < 1000) return `${y.toFixed(2)} yr`;
  return `${(y / 1000).toFixed(2)} kyr`;
}

let hudAcc = 0;
function updateHUD(dt) {
  hudAcc += dt;
  if (hudAcc < 0.1) return;
  hudAcc = 0;

  if (DOM.simClock) DOM.simClock.textContent = fmtYears(state.simYears);

  // --- star readout: what each sun actually is, and how bright it is here
  if (DOM.sunList && state.suns.length) {
    DOM.sunList.innerHTML = state.suns.map(s => {
      const b = s.body;
      const cls = b.spectral ?? '';
      const col = '#' + s.color.getHexString();
      const flaring = b.activity && b.activity.flux > 1.05;
      return `<div class="sun-row">
        <span class="dot" style="background:${col};box-shadow:0 0 8px ${col}"></span>
        <span class="sn">${b.name}</span>
        <span class="sc">${cls} · ${b.mass.toFixed(2)} M☉ · ${Math.round(b.teff ?? 0)} K</span>
        <span class="sf">${s.distAU.toFixed(2)} AU · ${s.intensity.toFixed(2)} S⊕${flaring ? ' <b class="flare">FLARE</b>' : ''}</span>
      </div>`;
    }).join('');
  }

  const cl = state.climate;
  if (!cl || !DOM.climatePanel || DOM.climatePanel.style.display === 'none') return;

  if (DOM.eraBadge) {
    DOM.eraBadge.textContent = cl.era.label;
    DOM.eraBadge.className = 'era-badge ' + cl.era.cls;
  }
  if (DOM.eraDesc) DOM.eraDesc.textContent = cl.era.desc;
  if (DOM.cTemp) DOM.cTemp.textContent = `${cl.celsius.toFixed(1)} °C`;
  if (DOM.cFlux) DOM.cFlux.textContent = `${cl.S.toFixed(2)} S⊕`;
  if (DOM.cIce) DOM.cIce.textContent = `${(cl.ice * 100).toFixed(0)} %`;
  if (DOM.cCloud) DOM.cCloud.textContent = `${(cl.clouds * 100).toFixed(0)} %`;
  if (DOM.cTau) DOM.cTau.textContent = `${cl.tauYears.toFixed(2)} yr`;
  if (DOM.cExtremes) {
    DOM.cExtremes.textContent =
      `${(cl.extremes.Tmin - 273.15).toFixed(0)} … ${(cl.extremes.Tmax - 273.15).toFixed(0)} °C`;
  }
  drawClimateChart();
}

// A scrolling record of insolation and temperature. The point of the chart is
// to make the lag visible: the temperature curve is a smoothed, delayed echo of
// the flux curve, and the delay is the ocean's thermal inertia.
function drawClimateChart() {
  const cv = DOM.climateChart;
  const cl = state.climate;
  if (!cv || !cl || cl.history.length < 2) return;
  const ctx = cv.getContext('2d');
  const w = cv.width, h = cv.height;
  ctx.clearRect(0, 0, w, h);

  const hist = cl.history;
  const t0 = hist[0][0], t1 = hist[hist.length - 1][0];
  const span = Math.max(t1 - t0, 1e-6);
  let sMax = 0.5, tMin = 200, tMax = 340;
  for (const [, S, T] of hist) { sMax = Math.max(sMax, S); tMin = Math.min(tMin, T); tMax = Math.max(tMax, T); }
  tMin -= 6; tMax += 6;

  const X = t => (t - t0) / span * w;
  const Ys = S => h - (S / (sMax * 1.1)) * h;
  const Yt = T => h - (T - tMin) / (tMax - tMin) * h;

  // habitable band (liquid water at the surface)
  ctx.fillStyle = 'rgba(80,200,140,0.10)';
  const yTop = Yt(305), yBot = Yt(273);
  ctx.fillRect(0, yTop, w, Math.max(yBot - yTop, 1));
  ctx.strokeStyle = 'rgba(80,200,140,0.35)'; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(0, yBot); ctx.lineTo(w, yBot); ctx.stroke();

  // insolation (filled)
  ctx.beginPath();
  ctx.moveTo(X(hist[0][0]), h);
  for (const [t, S] of hist) ctx.lineTo(X(t), Ys(S));
  ctx.lineTo(X(t1), h); ctx.closePath();
  ctx.fillStyle = 'rgba(255,190,90,0.16)'; ctx.fill();
  ctx.beginPath();
  hist.forEach(([t, S], i) => i ? ctx.lineTo(X(t), Ys(S)) : ctx.moveTo(X(t), Ys(S)));
  ctx.strokeStyle = 'rgba(255,190,90,0.75)'; ctx.lineWidth = 1.2; ctx.stroke();

  // temperature
  ctx.beginPath();
  hist.forEach(([t, , T], i) => i ? ctx.lineTo(X(t), Yt(T)) : ctx.moveTo(X(t), Yt(T)));
  ctx.strokeStyle = '#ff6a5a'; ctx.lineWidth = 1.6; ctx.stroke();

  ctx.fillStyle = 'rgba(160,180,210,0.55)';
  ctx.font = '9px ui-monospace,monospace';
  ctx.fillText(`${fmtYears(span)} window`, 4, 10);
  ctx.fillText(`peak ${sMax.toFixed(1)} S⊕`, 4, h - 4);
}

function bindSlider(id, key, fmt = v => v.toFixed(2), onChange) {
  const elx = document.getElementById(id), val = document.getElementById(id + '-val');
  elx.addEventListener('input', () => { state[key] = parseFloat(elx.value); val.textContent = fmt(state[key]); onChange?.(); });
}
bindSlider('mass', 'mass', v => v.toFixed(1), () => {
  const bh = getHoles()[0];
  if (bh && state.preset && PRESETS.sandbox === state.preset) {
    bh.mass = state.mass; bh.rs = state.mass * 0.05; bh.rsScene = bh.rs * state.sceneScale; bh.radiusScene = bh.rsScene;
    refreshUI();
  }
});
bindSlider('disc', 'discIntensity');
bindSlider('temp', 'discTemp');
bindSlider('speed', 'speed', v => v.toFixed(2));

// ============================================================================
// PANEL VISIBILITY
// Two independent levels: individual panels collapse to a tab (✕ / the tab),
// and H drops the entire HUD for an unobstructed view. Hiding everything is
// only safe if the way back is discoverable, hence the toast.
// ============================================================================
let toastTimer = null;
function toast(msg, ms = 2200) {
  if (!DOM.toast) return;
  DOM.toast.textContent = msg;
  DOM.toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => DOM.toast.classList.remove('show'), ms);
}

const collapsed = new Set();
function setPanelOpen(id, open) {
  const panel = document.getElementById(id);
  const tab = document.querySelector(`[data-open="${id}"]`);
  if (!panel) return;
  if (open) collapsed.delete(id); else collapsed.add(id);
  // While the whole HUD is hidden, neither the panel nor its tab may show.
  panel.style.display = (open && !state.hudHidden) ? '' : 'none';
  if (tab) tab.hidden = open || state.hudHidden;
  // the key hint sits in the bottom-right corner; give it the corner back when
  // the control panel is not occupying it
  if (id === 'controlPanel') {
    document.body.classList.toggle('panel-open-right', open && !state.hudHidden);
  }
}

document.querySelectorAll('[data-close]').forEach(btn =>
  btn.addEventListener('click', () => setPanelOpen(btn.dataset.close, false)));
document.querySelectorAll('[data-open]').forEach(btn =>
  btn.addEventListener('click', () => setPanelOpen(btn.dataset.open, true)));
// both start open — this also seeds the body class the hint's position keys off
for (const id of ['scenarioPanel', 'controlPanel']) setPanelOpen(id, true);

function setHudHidden(hidden) {
  state.hudHidden = hidden;
  for (const el of document.querySelectorAll('.hud')) {
    // panels obey their own collapsed state once the HUD comes back
    el.style.display = hidden ? 'none' : '';
  }
  for (const id of ['scenarioPanel', 'controlPanel']) setPanelOpen(id, !collapsed.has(id));
  if (hidden) toast('HUD hidden — press H to restore');
}

// ============================================================================
// IMAGING BAND
// ============================================================================
function setBand(i) {
  const band = postfx.setBand(i);
  state.band = postfx.band;
  DOM.bandGrid?.querySelectorAll('[data-band]').forEach(b =>
    b.classList.toggle('active', +b.dataset.band === state.band));
  if (DOM.bandNote) DOM.bandNote.textContent = band.note;
  if (DOM.bandLabel) DOM.bandLabel.textContent = band.short;
}

if (DOM.bandGrid) {
  DOM.bandGrid.innerHTML = BANDS.map((b, i) =>
    `<button class="band-btn" data-band="${i}" title="${b.note}">${b.short}</button>`).join('');
  DOM.bandGrid.querySelectorAll('[data-band]').forEach(btn =>
    btn.addEventListener('click', () => setBand(+btn.dataset.band)));
}
setBand(VISIBLE_BAND);

document.querySelectorAll('[data-spawn]').forEach(btn => btn.addEventListener('click', () => spawnOrbiting(btn.dataset.spawn)));
document.querySelectorAll('[data-preset]').forEach(btn => btn.addEventListener('click', () => loadPreset(btn.dataset.preset)));
document.getElementById('clear').addEventListener('click', clearBodies);
document.getElementById('delFocus').addEventListener('click', () => { if (state.focusId != null) removeBody(state.focusId); });
DOM.camOrbit.addEventListener('click', () => setCamMode('orbit'));
DOM.camFree.addEventListener('click', () => setCamMode('free'));
DOM.camSurface?.addEventListener('click', () => setCamMode('surface'));

// --- surface-view controls
const latEl = document.getElementById('lat');
latEl?.addEventListener('input', () => {
  observer.latitude = parseFloat(latEl.value) * Math.PI / 180;
  document.getElementById('lat-val').textContent = `${Math.round(parseFloat(latEl.value))}°`;
});
const dayEl = document.getElementById('daylen');
dayEl?.addEventListener('input', () => {
  const days = parseFloat(dayEl.value);
  const home = getHome();
  if (home) home.dayLength = days / 365.25;
  document.getElementById('daylen-val').textContent = `${days.toFixed(1)} d`;
});

// --- climate controls: the two knobs that decide whether the world lives
const mlEl = document.getElementById('mixed');
mlEl?.addEventListener('input', () => {
  const v = parseFloat(mlEl.value);
  if (state.climate) state.climate.mixedLayer = v;
  document.getElementById('mixed-val').textContent = `${v.toFixed(0)} m`;
});
const ghEl = document.getElementById('greenhouse');
ghEl?.addEventListener('input', () => {
  const v = parseFloat(ghEl.value);
  if (state.climate) state.climate.greenhouse = v;
  document.getElementById('greenhouse-val').textContent = v.toFixed(2);
});
document.getElementById('climateReset')?.addEventListener('click', () => {
  state.climate?.reset(288);
});

// ----------------------------------------------------------------------------
// TIME CONTROL
// A three-sun system has to be watched at wildly different speeds: a sunset
// lasts minutes, an orbit lasts years, a climate era lasts centuries. One
// linear speed control cannot serve all three, so the scale is logarithmic and
// backed by named regimes that are computed FROM the current world's day length
// and orbital period rather than hard-coded.
// ----------------------------------------------------------------------------
const tsEl = document.getElementById('timescale');
function timeLabel(yrPerSec) {
  if (yrPerSec < 3e-3) return `${(yrPerSec * 365.25 * 24).toFixed(2)} hr/s`;
  if (yrPerSec < 1) return `${(yrPerSec * 365.25).toFixed(2)} d/s`;
  return `${yrPerSec.toFixed(1)} yr/s`;
}
function setTimeScale(yrPerSec) {
  state.timeScale = THREE.MathUtils.clamp(yrPerSec, 1e-5, 20);
  if (tsEl) tsEl.value = String(Math.log10(state.timeScale));
  const el = document.getElementById('timescale-val');
  if (el) el.textContent = timeLabel(state.timeScale);
}
function applyTimeScale() {
  if (!tsEl) return;
  setTimeScale(Math.pow(10, parseFloat(tsEl.value)));
}
tsEl?.addEventListener('input', applyTimeScale);

// Seconds of real time each regime should take for its characteristic event.
const TIME_REGIMES = { sunset: 45, day: 8, season: 90, era: 120 };
function applyRegime(name) {
  const home = getHome();
  const day = home?.dayLength ?? 0.011;
  if (name === 'sunset') setTimeScale(day / TIME_REGIMES.sunset);
  else if (name === 'day') setTimeScale(day / TIME_REGIMES.day);
  else if (name === 'season') setTimeScale(1.69 / TIME_REGIMES.season);   // ~one orbit
  else if (name === 'era') setTimeScale(51 / TIME_REGIMES.era);           // ~one Gamma orbit
  document.querySelectorAll('[data-time]').forEach(b => b.classList.toggle('active', b.dataset.time === name));
}
document.querySelectorAll('[data-time]').forEach(b =>
  b.addEventListener('click', () => applyRegime(b.dataset.time)));
document.getElementById('resetView').addEventListener('click', () => { setFollow(null); cam.target.set(0, 0, 0); cam.radius = state.preset.camRadius; cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2; setCamMode('orbit'); updateOrbitCam(); });

function toggleMesh(on) {
  state.showMesh = on;
  spacetimeMesh.visible = on;
  const btn = document.querySelector('[data-view="mesh"]');
  if (btn) { btn.classList.toggle('active', on); btn.textContent = on ? 'Mesh ON' : 'Mesh OFF'; }
}

function setTrueScale(on) {
  state.trueScale = on;
  const btn = document.querySelector('[data-view="scale"]');
  if (btn) { btn.classList.toggle('active', on); btn.textContent = on ? 'Sizes: Real' : 'Sizes: Boosted'; }
  rebuildVisuals();
  refreshUI();
}

document.querySelectorAll('[data-view]').forEach(btn => btn.addEventListener('click', () => {
  const v = btn.dataset.view;
  if (v === 'mesh') toggleMesh(!state.showMesh);
  else if (v === 'scale') setTrueScale(!state.trueScale);
  else { state.showLens = !state.showLens; btn.classList.toggle('active', state.showLens); btn.textContent = state.showLens ? 'Lens ON' : 'Lens OFF'; }
}));

// ============================================================================
// RENDER TARGET + RESIZE
// ============================================================================
const sceneTarget = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, minFilter: THREE.LinearFilter, magFilter: THREE.LinearFilter });
function resize() {
  const w = innerWidth, h = innerHeight;
  renderer.setSize(w, h); camera.aspect = w / h; camera.updateProjectionMatrix();
  const pr = renderer.getPixelRatio();
  sceneTarget.setSize(w * pr, h * pr);
  postfx.setSize(w * pr, h * pr);
  lensMaterial.uniforms.aspect.value = w / h;
  lensMaterial.uniforms.fov.value = camera.fov * Math.PI / 180;
}
addEventListener('resize', resize);

// ============================================================================
// ANIMATION LOOP
// ============================================================================
let lastT = performance.now(), fpsAcc = 0, fpsCount = 0, fpsTime = 0;
function animate() {
  requestAnimationFrame(animate);
  const now = performance.now();
  let dt = Math.min((now - lastT) / 1000, 0.05); lastT = now;
  const simDt = state.paused ? 0 : dt * state.speed * state.timeScale;
  state.time += dt;

  fpsAcc += 1 / Math.max(dt, 1e-4); fpsCount++; fpsTime += dt;
  if (fpsTime > 0.5) { DOM.fps.textContent = Math.round(fpsAcc / fpsCount); fpsAcc = fpsCount = fpsTime = 0; }

  stepPhysics(simDt);
  updateSuns();
  postfx.setSceneTemp(sceneMaxTemp());

  // body visual updates
  const holes = getHoles().map(h => ({ posScene: h.viz.group.position, rsScene: h.rsScene, mass: h.mass }));
  const ctx = {
    holes, camera, time: state.time, sceneScale: state.sceneScale,
    simDt, suns: state.suns, climate: state.climate,
  };
  for (const b of state.bodies) {
    if (b.type === 'bh') { b.rsScene = b.rs * state.sceneScale; b.radiusScene = b.rsScene; }
    b.viz.update(dt * (state.paused ? 0 : 1) + 0.0001, ctx); // keep shaders animating even paused-ish
  }
  // Bodies stripped down to nothing by accretion are fully consumed. This has
  // to be measured against the body's ORIGINAL mass: a planet is born lighter
  // than this threshold, and must not be deleted just for being a planet.
  for (const b of state.bodies.slice()) {
    if (b.type !== 'bh' && b.mass0 > 0.05 && b.mass <= Math.max(0.012, b.mass0 * 0.02)) {
      spawnFlash(b.viz.group.position.clone(), 0xffcaa0, b.radiusScene * 10, 0.7);
      state.consumed++; removeBody(b.id);
    }
  }

  // camera follow / movement
  const home = getHome();
  if (state.camMode === 'surface' && home) observer.update(home, camera);
  else if (state.camMode === 'free') updateFreeCam(dt);
  else {
    if (state.followId != null) {
      const fb = state.bodies.find(b => b.id === state.followId);
      // The 0.2 lerp exists to damp the camera when you click between bodies.
      // At true scale it breaks down: framing Earth puts the camera 3e-4 AU
      // out while Earth itself covers most of an AU per frame at 6 yr/s, so a
      // fractional catch-up never arrives and the target trails hopelessly
      // behind. Smooth only while the residual is small compared to the
      // viewing distance; past that, track exactly.
      if (fb) {
        const p = fb.viz.group.position;
        if (cam.target.distanceToSquared(p) > (cam.radius * 0.25) ** 2) cam.target.copy(p);
        else cam.target.lerp(p, 0.2);
      }
    }
    updateOrbitCam();
  }

  // ---- near plane. A fixed 0.01 AU near plane sits outside a true-scale Earth
  // entirely: fly up to one and it clips away before you ever see it. Tying the
  // near plane to how far the camera actually is keeps the whole zoom range —
  // from 40 AU down to a low pass over a planet — inside the depth buffer.
  if (state.camMode !== 'surface') {
    // In orbit mode the viewing distance IS cam.radius. Free-fly has no such
    // handle, so use the gap to the nearest body's surface — that is the only
    // thing the near plane can actually clip through.
    let camDist = cam.radius;
    if (state.camMode === 'free') {
      camDist = Infinity;
      for (const b of state.bodies) {
        const surf = camera.position.distanceTo(b.viz.group.position) - Math.max(b.radiusScene, b.rsScene || 0);
        if (surf < camDist) camDist = surf;
      }
      camDist = Number.isFinite(camDist) ? Math.max(camDist, 1e-6) : 1;
    }
    const near = THREE.MathUtils.clamp(camDist * 1e-3, 1e-7, 0.01);
    // only touch the projection matrix on a real change — this runs every frame
    if (Math.abs(Math.log(near / camera.near)) > 0.05) {
      camera.near = near;
      camera.updateProjectionMatrix();
    }
  }

  // ---- point-source markers. Every body gets one; it only shows itself when
  // the body's own disc has shrunk past a few pixels, so in the exaggerated
  // presets it is silently inert and costs one quad's worth of nothing.
  // Not in surface view: the sky pass draws the suns itself, with real angular
  // radii and atmospheric scattering, and a marker on top would double them.
  for (const b of state.bodies) {
    if (!b.marker) continue;
    if (state.camMode === 'surface') { b.marker.mesh.visible = false; continue; }
    b.marker.update(camera, b.viz.group.position, Math.max(b.radiusScene, b.rsScene || 0),
                    innerHeight, b.id === state.focusId);
  }

  // light at dominant star/bh (legacy single-light path for star-less presets)
  if (sunLight.visible) {
    const lum = state.bodies.find(b => b.type === 'star') || holes[0] && state.bodies.find(b => b.type === 'bh');
    if (lum) sunLight.position.copy(lum.viz.group.position);
  }

  // flashes
  for (let i = flashes.length - 1; i >= 0; i--) {
    const f = flashes[i]; f.life -= dt * (f.decay ?? 0.8);
    if (f.life <= 0) { scene.remove(f.sp); flashes.splice(i, 1); continue; }
    f.sp.scale.setScalar(f.size * (1 + (1 - f.life) * 2)); f.sp.material.opacity = f.life;
  }

  // mesh wells — recenter the slab under the camera's focus so fast/distant
  // bodies never wander off it; well coords are stored relative to that center.
  const mcx = state.camMode === 'free' ? camera.position.x : cam.target.x;
  const mcz = state.camMode === 'free' ? camera.position.z : cam.target.z;
  spacetimeMesh.position.set(mcx, -6, mcz);
  const wells = meshMat.uniforms.wells.value;
  let wc = 0;
  for (const b of state.bodies) {
    if (wc >= 16) break;
    const p = b.viz.group.position;
    if (b.type === 'bh') wells[wc++].set(p.x - mcx, p.z - mcz, b.rsScene, 1);
    else wells[wc++].set(p.x - mcx, p.z - mcz, Math.min(b.mass + b.radiusScene, 6), 0);
  }
  meshMat.uniforms.wellCount.value = wc;
  meshMat.uniforms.time.value += simDt;

  // lensing uniforms
  lensMaterial.uniforms.time.value += simDt;
  const useLens = state.showLens && holes.length > 0;
  if (useLens) {
    camera.updateMatrixWorld(true);   // camMat below must match this frame
    const n = Math.min(holes.length, MAX_HOLES);
    for (let i = 0; i < n; i++) {
      lensMaterial.uniforms.holePos.value[i].copy(holes[i].posScene);
      lensMaterial.uniforms.holeRs.value[i] = holes[i].rsScene;
    }
    lensMaterial.uniforms.holeCount.value = n;
    lensMaterial.uniforms.discIntensity.value = state.discIntensity;
    lensMaterial.uniforms.discOuter.value = state.preset?.discOuter ?? 15;
    // True peak disc temperature, for the multi-wavelength imaging. Thin-disc
    // theory gives T_peak ∝ M^(−1/4), so a 10 M☉ hole runs at ~10⁷ K (an X-ray
    // binary) while a supermassive one peaks in the UV. Independent of the
    // "Disc Temp" slider, which only sets the visible-light palette.
    lensMaterial.uniforms.discTpeakPhys.value = 2.0e7 * Math.pow(Math.max(holes[0].mass, 0.1), -0.25);
    lensMaterial.uniforms.discTemp.value = state.discTemp;
    lensMaterial.uniforms.camPos.value.copy(camera.position);
    lensMaterial.uniforms.camMat.value.copy(camera.matrixWorld);
    lensMaterial.uniforms.fov.value = camera.fov * Math.PI / 180;
  }

  // ---- surface view: render the sky as a full-screen composite over the scene
  if (state.camMode === 'surface' && home) {
    const u = skyPass.material.uniforms;
    const n = Math.min(state.suns.length, MAX_SUNS);
    let illum = 0;
    for (let i = 0; i < n; i++) {
      const s = state.suns[i];
      u.uSunDir.value[i].copy(s.posScene).sub(observer.eye).normalize();
      u.uSunColor.value[i].copy(s.color);
      u.uSunInt.value[i] = s.intensity;
      u.uSunAng.value[i] = s.angRadius;
      // horizontal illuminance from this sun: flux × cos(zenith angle)
      illum += s.intensity * Math.max(u.uSunDir.value[i].dot(observer.up), 0);
    }
    u.uSunCount.value = n;

    // Eye adaptation. Without it the view is either a black night or a white
    // day: three suns of different luminosity crossing the sky span a huge
    // dynamic range. Target exposure falls as the ground gets brighter, and the
    // eye takes a moment to follow — so a sunrise dazzles briefly, then settles.
    const target = THREE.MathUtils.clamp(0.32 / (0.12 + illum), 0.35, 1.9);
    const adapt = 1 - Math.exp(-dt / 1.6);              // ~1.6 s time constant
    state.exposure += (target - state.exposure) * adapt;
    u.uExposure.value = state.exposure;
    u.uUp.value.copy(observer.up);
    u.uNorth.value.copy(observer.north);
    u.uCamPos.value.copy(camera.position);
    u.uCamMat.value.copy(camera.matrixWorld);
    u.uFov.value = camera.fov * Math.PI / 180;
    u.uAspect.value = camera.aspect;
    u.uTime.value += dt;
    const cl = state.climate;
    if (cl) {
      u.uIce.value = cl.ice;
      u.uScorch.value = THREE.MathUtils.clamp((cl.T - 320) / 120, 0, 1);
      u.uClouds.value = cl.clouds;
      u.uHumidity.value = cl.humidity;
      u.uStorm.value = cl.storm ?? 0.2;
    }

    // we are standing on the world, so don't draw it; and the spacetime slab
    // would cut across the sky
    const meshWas = spacetimeMesh.visible;
    home.viz.group.visible = false;
    spacetimeMesh.visible = false;

    renderer.setRenderTarget(sceneTarget); renderer.clear();
    renderer.render(scene, camera);
    // the sky composite lands in the HDR buffer, not on the screen
    renderer.setRenderTarget(postfx.hdr); renderer.clear();
    skyPass.material.uniforms.tScene.value = sceneTarget.texture;
    renderer.render(skyPass.scene, skyPass.camera);

    home.viz.group.visible = true;
    spacetimeMesh.visible = meshWas;
    // The sky pass already applies its own eye-adaptation exposure, so the
    // tone mapper takes the frame at unity and just does the highlight roll-off
    // and the bloom on top of it.
    postfx.render(1.0, state.time);
    updateHUD(dt);
    return;
  }

  // ---- render: everything composes into the HDR buffer, then one tone map
  if (useLens) {
    // pass 1 — the geodesic marcher: lensed starfield + accretion disc +
    // shadow. It traces the sky map directly, so there is no pre-rendered
    // backdrop to feed it. (The old code rendered the whole scene into an
    // offscreen target here for a `tScene` sampler that the shader never
    // actually read — a full scene draw per frame, thrown away.)
    renderer.setRenderTarget(postfx.hdr); renderer.clear();
    renderer.render(lensScene, lensCam);

    // pass 2 — real geometry back on top, with depth, over the lensed image
    renderer.autoClear = false; renderer.clearDepth();
    scene.background = null;
    renderer.render(scene, camera);
    scene.background = starTex; renderer.autoClear = true;
  } else {
    renderer.setRenderTarget(postfx.hdr); renderer.clear();
    renderer.render(scene, camera);
  }
  postfx.render(1.0, state.time);
  updateHUD(dt);
}

// ============================================================================
// BOOT
// ============================================================================
resize();
loadPreset(PRESETS[location.hash.slice(1)] ? location.hash.slice(1) : 'sandbox');
addEventListener('hashchange', () => { if (PRESETS[location.hash.slice(1)]) loadPreset(location.hash.slice(1)); });
setTimeout(() => { DOM.loading.classList.add('gone'); animate(); }, 400);
