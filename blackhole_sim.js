import * as THREE from 'three';
import * as PHYS from './sim/physics.js';
import { createBodyVisual } from './sim/bodies.js';
import { GAS_PALETTES } from './sim/textures.js';
import { PRESETS, PRESET_ORDER } from './sim/presets.js';
import { Climate } from './sim/climate.js';
import { createSkyPass, SurfaceObserver } from './sim/skyview.js';
import { MAX_SUNS } from './sim/world.js';
import { luminosity, effectiveTemp, radiusSun, blackbodyColor, spectralClass } from './sim/stellar.js';
import { structureOf, whiteDwarfRadiusSun, gravityDarkenedTemps, tovLimit, endStateOf, VERDICT, LIMITS } from './sim/structure.js';
import { createFoundry, createInspector, createLiveEditor } from './sim/foundry.js';
import { createPainter, ringSpan } from './sim/painter.js';
import { fmtMass } from './sim/crosssection.js';
import { createBlackHolePass, MAX_HOLES } from './sim/blackhole.js';
import { createPostFX } from './sim/postfx.js';
import { BANDS, VISIBLE_BAND } from './sim/spectrum.js';
import { physicalRadiusAU, createMarker } from './sim/scale.js';
import { createSkyBackdrop, applySkyBand, applySkyEnvironment, applySkyOptics } from './sim/sky.js';

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
  // Where a spawned body starts. Every scenario with something already in it
  // puts new bodies on a circular orbit about the dominant mass, because that
  // is the only starting condition that does not immediately fall in. The
  // Blank Canvas has no dominant mass, so it starts them at rest instead.
  spawnAtRest: false,
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
 'discRow', 'tempRow', 'camSurface', 'climatePanel', 'eraBadge',
 'eraDesc', 'cTemp', 'cFlux', 'cIce', 'cCloud', 'cTau', 'cExtremes', 'climateChart',
 'sunList', 'simClock', 'starPanel', 'skyRow', 'bhPanel',
 'bandGrid', 'bandNote', 'bandLabel', 'toast', 'panelTabs', 'presetSearch',
 'presetSearchClear', 'presetList', 'presetEmpty', 'foundry', 'xsecPanel',
 'xsecCanvas', 'xsecLegend', 'xsecFacts', 'xsecNotes', 'xsecVerdict', 'xsecName',
 'xsecOpen', 'liveEdit'].forEach(id => DOM[id] = document.getElementById(id));

// The scenario catalogue is grouped here rather than in the physics presets:
// these labels are navigation, while PRESETS remains the source of truth for
// each scenario's initial conditions and rendering settings.
const presetGroup = (id, label, keys) => ({
  id, label, keys: PRESET_ORDER.filter(key => keys.includes(key)),
});
const PRESET_GROUPS = [
  presetGroup('trisolaris', 'Trisolaris scenarios', ['trisolaris', 'trisolaris_wander', 'trisolaris_compact', 'trisolaris_wide', 'trisolaris_alpha', 'trisolaris_chaos']),
  presetGroup('black-holes', 'BH scenarios', ['bhmerger', 'feeding']),
  presetGroup('neutron-stars', 'Neutron star scenarios', ['nsmerger']),
  presetGroup('sandboxes', 'Sandboxes', ['blank', 'sandbox']),
  presetGroup('real-stars', 'Real stars', ['stellar_zoo', 'sirius', 'vega', 'achernar', 'betelgeuse', 'alphacen', 'etacar', 'hr_ladder']),
  presetGroup('stellar-systems', 'Stellar system scenarios', ['solar', 'threebody', 'binarystar']),
];
const openPresetGroups = new Set();
let presetSearchText = '';

// ============================================================================
// SCENE / RENDERER / CAMERA
// ============================================================================
const scene  = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(50, innerWidth / innerHeight, 0.01, 100000);
camera.position.set(0, 8, 24);

// antialias is deliberately OFF. Nothing is ever drawn to the default
// framebuffer except one fullscreen quad in sim/postfx.js's composite - the
// whole frame is assembled in the non-multisampled HDR target - so MSAA here
// only ever antialiases the edges of that quad, which are the edges of the
// screen. It costs a multisampled backbuffer and a resolve to do nothing.
const renderer = new THREE.WebGLRenderer({ antialias: false, powerPreference: 'high-performance' });

// Render scale. Every expensive pass in this sim is fullscreen, so this is a
// straight multiplier on the entire frame cost - on a 2x display, a ratio of
// 1.5 is 2.25x the pixels of 1.0. It defaults to 1.0 rather than following the
// display, because the lensed pass is by far the most expensive thing here and
// a sharper photon ring is rarely worth halving the frame rate. The slider is
// there for screenshots, where it is worth exactly that.
renderer.setPixelRatio(Math.min(devicePixelRatio, 1.0));
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
// SKY
// ============================================================================
// The sky is procedural and lives in sim/sky.js — there is no texture and no
// scene.background any more. Two consumers share the same GLSL and the same
// uniforms: the lensing pass traces it directly, and this backdrop draws it for
// every scene that has no black hole in it (which is most of them).
//
// Keeping the two in one module is the point. The old canvas map was assigned
// to scene.background AND handed to the lens pass AND showed through the
// surface view, and any change had to be made to look right in all three.
const backdrop = createSkyBackdrop();

// ============================================================================
// LENSING / ACCRETION-DISC PASS
// The whole general-relativistic ray marcher now lives in sim/blackhole.js.
// ============================================================================
const lensPass = createBlackHolePass();
// Both of the pass's materials share one uniforms object, so this is still the
// single place to set hole positions, camera and disc parameters.
const lensMaterial = lensPass.material;

// Both passes carry an identical copy of the sky uniform block, so every change
// has to reach both or the two views disagree about what the sky looks like.
function syncSky(fn) { fn(backdrop.uniforms); fn(lensMaterial.uniforms); }

// Draw the sky into whatever target is currently bound. Depth is off, so this
// has to go down FIRST and the scene composites over it — the reverse of the
// lensed path, where the marcher has already put the sky in the buffer.
function drawBackdrop() {
  camera.updateMatrixWorld(true);   // camMat must match this frame's camera
  backdrop.uniforms.camMat.value.copy(camera.matrixWorld);
  backdrop.uniforms.fov.value = camera.fov * Math.PI / 180;
  renderer.render(backdrop.scene, backdrop.camera);
}

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

// ============================================================================
// PAINTER — see sim/painter.js. Everything it holds is a test particle or a
// shell, none of it enters the N-body loop, and all of it is pinned to a body.
// ============================================================================
const painter = createPainter({
  scene,
  getBody: id => state.bodies.find(b => b.id === id),
  getSceneScale: () => state.sceneScale,
});

// ---------------------------------------------------------------------------
// FLASH SPRITES — the two things a violent event can look like.
//
// `flash` (the default) is a compact glow that grows a little and fades: the
// right stand-in for light, where nothing is actually moving outward — a
// ringdown burst, a horizon forming, a disc brightening as it swallows something.
//
// `shell` is the right stand-in for MATTER, and everything the sim calls a
// supernova throws matter. Two things change. The ejecta expand a long way —
// as t^½ rather than linearly, because they run out fast and then decelerate
// against what is around them — and, because the sprite spreads the same
// emission over that growing disc, brightness falls as size⁻¹ on top of the
// fade. The net effect is a wash that thins out instead of a dot that dims:
// what was left of a Type Ia at 90% of its life used to be a small, still
// clearly visible blue-white ball sitting exactly where the star had been,
// which reads as "the star is still there" — the opposite of what the toast
// says happened to it.
// ---------------------------------------------------------------------------
const flashes = [];
function spawnFlash(worldPos, color, size, decay = 0.8, { grow = 2, kind = 'flash' } = {}) {
  const cv = document.createElement('canvas'); cv.width = cv.height = 128;
  const g = cv.getContext('2d');
  const rg = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  const h = '#' + color.toString(16).padStart(6, '0');
  rg.addColorStop(0, '#ffffff'); rg.addColorStop(0.3, h + 'cc'); rg.addColorStop(1, h + '00');
  g.fillStyle = rg; g.fillRect(0, 0, 128, 128);
  const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(cv), blending: THREE.AdditiveBlending, transparent: true, depthWrite: false }));
  sp.position.copy(worldPos); sp.scale.setScalar(size); scene.add(sp);
  flashes.push({ sp, life: 1, size, decay, grow, shell: kind === 'shell' });
}
// Each flash owns a fresh 128×128 CanvasTexture, and a merger spawns two. They
// have to go back with the sprite or every merge leaks a pair.
function killFlash(f) {
  scene.remove(f.sp);
  f.sp.material.map?.dispose();
  f.sp.material.dispose();
}

// ============================================================================
// BODY CREATION
// ============================================================================
const TRAIL_MAX = 600;
// The exaggerated ("Boosted") size of each type, at that type's DEFAULT mass.
// A neutron star is ~12 km across sitting in an orbit millions of times wider,
// so its rendered size is pure invention either way; what these numbers buy is
// enough pixels for its lensed surface, polar caps and magnetosphere to be
// visible at all.
const BOOST_RADIUS = {
  star: 0.34, 'white-dwarf': 0.12, neutron: 0.30,
  'gas-giant': 0.30, world: 0.13, planet: 0.15, bh: 0.2,
};

// The physical radius each of those numbers corresponds to, computed once from
// the interior model at the type's default mass. Boosted radius is then scaled
// by how far the BODY's real radius departs from that reference — so the
// exaggeration is a constant magnification per type rather than a constant
// size, and a 300 M⊕ super-Earth is visibly three times a 1 M⊕ one.
//
// Normalising at the default mass is what keeps every existing preset
// pixel-identical: a quick-spawned planet is 1 M⊕, a quick-spawned gas giant is
// 1 M_J, Trisolaris is 1 M⊕, and all of them come out at exactly the ratio 1.
const _refRadius = new Map();
function referenceRadiusAU(type) {
  if (!_refRadius.has(type)) {
    const def = TYPE_DEFAULTS[type] || TYPE_DEFAULTS.planet;
    const st = structureOf({ type, mass: def.mass, spinFrac: 0 });
    _refRadius.set(type, st.radiusAU > 0 ? st.radiusAU : 1);
  }
  return _refRadius.get(type);
}

function baseRadius(b, spec, mass) {
  const type = spec.type;
  const base = BOOST_RADIUS[type] ?? 0.2;
  // Stars are the one type whose measured radii span 90 000 to 1 (Betelgeuse to
  // Sirius B). This is the deliberately unphysical readable mode, and drawing
  // that range at all defeats its purpose, so a measured stellar radius is
  // compressed: R^0.45 keeps the ordering and squeezes the range to ~180:1.
  // True scale is the other branch of renderRadius and is left entirely alone.
  if (type === 'star') {
    return base * (spec.radiusSun != null ? Math.pow(spec.radiusSun, 0.45) : radiusSun(mass));
  }
  const ref = referenceRadiusAU(type);
  const r = b?.radius > 0 ? b.radius : ref;
  // The clamp is not physics, it is framing: a 0.01 M⊕ pebble still has to be
  // clickable and a brown dwarf still has to fit beside the star it orbits.
  return base * THREE.MathUtils.clamp(r / ref, 0.18, 9);
}
// Rendered radius in SCENE units. Black holes are always honest — their
// horizon is the thing you came to look at. Everything else is either the real
// geometric radius (true scale) or the readable, exaggerated stand-in.
function renderRadius(b, spec, mass) {
  if (spec.type === 'bh') return b.rs * state.sceneScale;
  if (state.trueScale && b.radius > 0) return b.radius * state.sceneScale;
  return baseRadius(b, spec, mass) * state.bodyScale;
}

const TYPE_DEFAULTS = {
  star:    { mass: 1.0, color: 0xffe0a0, glow: 0xff8040 },
  neutron: { mass: 1.4, color: 0xcfe8ff, glow: 0x88c4ff },
  'white-dwarf': { mass: 0.6, color: 0xdfe9ff, glow: 0xaac8ff },
  'gas-giant': { mass: 9.5e-4, color: 0xd4a574, glow: 0x6a4828 },
  planet:  { mass: 3e-6, color: 0x6a90c0, glow: 0x3a6a9a },
  world:   { mass: 3e-6, color: 0x6a90c0, glow: 0x3a6a9a },
  bh:      { mass: 10, color: 0x000000, glow: 0x000000 },
};

// Peak temperature of the Shakura–Sunyaev disc a hole of this mass would carry.
// The thin-disc result is T_peak ∝ (Ṁ/M²)^¼ and, at a fixed Eddington fraction,
// Ṁ ∝ M, which leaves T ∝ M^(−¼): a stellar-mass hole peaks in the X-ray at
// ~10⁷ K and a supermassive one only in the UV. This is the temperature the
// lens pass images the disc at, and the one a sub-pixel hole's marker has to
// publish so the imaging bands treat it as the X-ray source it is.
function discPeakTemp(mass) {
  return 2.0e7 * Math.pow(Math.max(mass, 0.1), -0.25);
}

// ---------------------------------------------------------------------------
// Build (or rebuild) a body's renderable half from its stored spec. Split out
// of spawnBody so the size convention can change at runtime — the physics body
// keeps its position, velocity and mass; only the meshes are thrown away.
// ---------------------------------------------------------------------------
function attachVisual(b) {
  const spec = b.spec, def = b.def;
  const radiusScene = renderRadius(b, spec, b.mass0);
  b.radiusScene = radiusScene;
  // Destruction distance. By default a body is destroyed when it touches what
  // you can SEE, which keeps the exaggerated view self-consistent. But that ties
  // a physical outcome to a drawing convention: at the Trisolaris presets' scale
  // an exaggerated star reaches ~9x further out than its real photosphere, which
  // quietly decides which close passes a world walks away from. A spec may
  // override it with a real distance in AU (see the Roche limits in
  // sim/presets.js).
  b.contactAU = spec.contactAU ?? radiusScene / state.sceneScale;
  if (spec.type === 'bh') b.rsScene = radiusScene;

  const palette = spec.palette ? GAS_PALETTES[spec.palette] : null;
  // Stars are coloured from their blackbody temperature unless a preset
  // deliberately overrides it (the figure-eight uses colour to tell bodies apart).
  const starColor = spec.color != null ? new THREE.Color(spec.color)
                  : (b.teff ? blackbodyColor(b.teff) : null);
  const isStarLike = spec.type === 'star' || spec.type === 'white-dwarf';
  // Rotational flattening and gravity darkening, from sim/structure.js. A star
  // spun to 88% of break-up is measurably lens-shaped and measurably two-tone,
  // and both are consequences of the same one number.
  const st = b.structure;
  const gd = (spec.type === 'star' && b.teff) ? gravityDarkenedTemps(b.teff, b.spinFrac ?? 0) : null;
  const viz = createBodyVisual(b, {
    radiusScene,
    oblate: st?.flattening ? 1 / (1 - st.flattening) : 1,
    spinFrac: b.spinFrac ?? 0,
    tPole: gd?.tPole, tEq: gd?.tEq, gdBeta: gd?.beta,
    radiusSun: b.radiusSun ?? (b.radius ? b.radius / PHYS.AU_PER_RSUN : undefined),
    color: isStarLike ? starColor : (spec.color ?? def.color),
    teff: b.teff,
    glow: spec.glow ?? def.glow,
    seed: spec.seed,
    obliquity: spec.obliquity,
    palette, hot: spec.hot, atmosphere: spec.atmosphere, atmColor: spec.atmColor,
    seaLevel: spec.seaLevel, rings: spec.rings, ringColor: spec.ringColor,
  });
  // Rotational flattening for everything that is NOT a star: the star shader
  // deforms its own mesh onto the Roche surface (it needs the shape to compute
  // gravity darkening anyway), but a planet or a neutron star has no such
  // shader, so its group is scaled into the spheroid instead. Volume is
  // conserved by sim/structure.js, so this bulges the body rather than
  // inflating it — Jupiter really is 6.5% wider than it is tall.
  if (st?.flattening > 1e-4 && spec.type !== 'star' && spec.type !== 'white-dwarf') {
    const k = st.radiusEqAU / (st.radiusAU || 1);
    viz.group.scale.set(k, k * (1 - st.flattening), k);
  }
  viz.group.userData.bodyId = b.id;
  viz.group.userData.baseScale = viz.group.scale.x || 1;
  // The full (possibly oblate) scale, kept so the size ease can multiply it
  // without flattening a spheroid back into a sphere.
  viz.group.userData.baseVec = viz.group.scale.clone();
  b.sizeK = 1;
  viz.group.position.copy(b.pos).multiplyScalar(state.sceneScale);
  scene.add(viz.group);

  // Point-source marker: what keeps a true-scale body visible once its disc
  // falls below a pixel. It lives in the scene rather than under viz.group so
  // its size is never coupled to whatever the body's own visual does to its
  // transform (tidal stretching, flare pulses).
  const emitter = spec.type === 'star' || spec.type === 'white-dwarf';
  // A black hole is the one type that is ALWAYS drawn at its true horizon, so
  // outside the black-hole presets — where the horizon is deliberately fat — it
  // is always sub-pixel and always carried by the marker. Colouring that marker
  // from the type's own colour meant colouring it 0x000000: it drew nothing, so
  // every remnant the sim makes (core collapse, a neutron star past the TOV
  // mass, a merger) simply vanished the instant it formed, leaving only the
  // Bodies list to prove it was still there.
  //
  // What you see of a distant hole is not the hole, it is the disc, so the
  // marker takes the disc's peak temperature — colour AND the log-encoded
  // temperature the imaging bands re-image from (CLAUDE.md: emitters publish
  // their true temperature). A stellar-mass hole is then correctly dim in the
  // radio and blazing in X-ray, which is exactly how one is actually found.
  const isHole = spec.type === 'bh';
  const discT = isHole ? discPeakTemp(b.mass) : 0;
  const markerColor = emitter
    ? (starColor ?? (b.teff ? blackbodyColor(b.teff) : new THREE.Color(0xfff2cc)))
    // the Planck colour fit saturates long before 10⁷ K; past ~40 000 K the eye
    // has nothing left to say beyond "blue-white", so clamp rather than extrapolate
    : (isHole ? blackbodyColor(Math.min(discT, 4.0e4)) : new THREE.Color(spec.color ?? def.color));
  b.marker = createMarker({
    color: markerColor,
    teff: isHole ? discT : (b.teff ?? 0),
    // Emitters must stay bright enough to survive tone mapping and trip the
    // bloom; reflectors only need to be seen.
    gain: spec.type === 'star' ? 26
        : ((spec.type === 'neutron' || spec.type === 'white-dwarf' || isHole) ? 18 : 2.2),
  });
  scene.add(b.marker.mesh);
}

// THREE.Material.dispose() frees the material, never the textures it points at,
// and removing an Object3D frees nothing at all. Every procedural body owns its
// maps (rockyTexture / gasGiantTexture build a CanvasTexture each), and
// rebuildVisuals + loadPreset run this path repeatedly in a session, so anything
// missed here accumulates on the GPU for as long as the tab is open.
function disposeMaterial(mat) {
  if (!mat) return;
  for (const v of Object.values(mat)) {
    if (v && v.isTexture) v.dispose();
  }
  for (const u of Object.values(mat.uniforms || {})) {
    const v = u?.value;
    if (v && v.isTexture) v.dispose();
  }
  mat.dispose();
}

function detachVisual(b) {
  if (b.viz) {
    scene.remove(b.viz.group);
    b.viz.group.traverse(o => {
      o.geometry?.dispose?.();
      const m = o.material;
      if (Array.isArray(m)) m.forEach(disposeMaterial); else disposeMaterial(m);
    });
  }
  if (b.marker) { scene.remove(b.marker.mesh); b.marker.dispose(); b.marker = null; }
}

// ---------------------------------------------------------------------------
// Size easing. An edit rebuilds the mesh at the new radius immediately — it has
// to, because the whole visual is derived from that radius — so without this an
// object that doubles in mass CUTS to its new size. The mesh is started back at
// the size it had and grows into the new one over ~0.25 s, geometrically,
// because radius is a scale and a linear ramp between 1e-5 and 1e2 spends the
// entire animation in the last decade.
//
// This multiplies the group's own scale rather than replacing it, so the
// rotational flattening baked in by attachVisual survives the transition. The
// eased factor also drives the point-source marker (see the render loop), or a
// true-scale body would glide while its glow jumped.
// ---------------------------------------------------------------------------
function applySizeEase(b, dt) {
  const e = b.sizeEase;
  if (!e) return;
  e.t = Math.min(1, e.t + dt / 0.25);
  const k = Math.pow(e.from, 1 - e.t);          // from → 1
  b.sizeK = k;
  const base = b.viz?.group.userData.baseVec;
  if (base) b.viz.group.scale.set(base.x * k, base.y * k, base.z * k);
  if (e.t >= 1) { b.sizeEase = null; b.sizeK = 1; }
}

// Swap every body between true and exaggerated size in place. Rebuilding is the
// honest way to do this: each visual bakes its radius into geometry and into
// local-space offsets (corona span, ring radii, prominence loops), so scaling
// the group would leave those subtly wrong.
function rebuildVisuals() {
  for (const b of state.bodies) { detachVisual(b); attachVisual(b); }
  // the follow distance was framed for the old size and is now meaningless
  const fb = state.bodies.find(x => x.id === state.followId);
  if (fb) jumpCamRadius(frameRadius(fb));
  if (state.camMode === 'orbit') updateOrbitCam();
}

// ---------------------------------------------------------------------------
// Recompute a body's interior model. Everything that reads structure — the
// cross-section, the object editor, the oblateness the star shader draws, the
// stability checks in the render loop — reads b.structure, so this is the one
// place that decides what a body physically IS. It has to be re-run whenever
// mass or spin changes, which accretion does continuously.
// ---------------------------------------------------------------------------
function refreshStructure(b) {
  b.structure = structureOf({
    type: b.type, mass: b.mass, spinFrac: b.spinFrac ?? 0,
    phase: b.phase, composition: b.composition, Z: b.Z,
    radiusSun: b.radiusSun, teff: b.spec?.teff, luminosity: b.spec?.luminosity,
    radiusKm: b.spec?.radiusKm, rs: b.rs,
  });
  return b.structure;
}

// ---------------------------------------------------------------------------
// Derive everything a body's spec IMPLIES: horizon, radius, temperature,
// luminosity, spin and interior model. Split out of spawnBody because it has to
// be re-runnable on a body that already exists — the live editor changes a mass
// or a spin on something already in orbit and needs exactly this block again,
// without touching the id, the position, the velocity or the trail.
// ---------------------------------------------------------------------------
function deriveBody(b, spec) {
  const def = TYPE_DEFAULTS[spec.type] || TYPE_DEFAULTS.planet;
  const mass = b.mass;
  if (spec.type === 'bh') {
    b.rs = spec.rs ?? PHYS.schwarzschild(mass);            // effective horizon (AU)
  } else if (spec.type === 'neutron') {
    b.radius = PHYS.neutronRadius(mass);
    b.rs = PHYS.schwarzschild(mass);
  } else if (spec.type === 'star') {
    // A measured radius (sim/starcat.js) wins; otherwise the main-sequence
    // relation. This matters far past cosmetics — b.radius is the collision
    // radius, and Betelgeuse's is 150 times what its mass alone would predict.
    b.radiusSun = spec.radiusSun ?? null;
    b.radius = spec.radiusSun != null ? spec.radiusSun * PHYS.AU_PER_RSUN : PHYS.stellarRadius(mass);
    b.luminosity = spec.luminosity ?? luminosity(mass);
    b.teff = spec.teff ?? effectiveTemp(mass);
    b.spectral = spectralClass(b.teff);
    b.phase = spec.phase ?? 0.5;
  } else if (spec.type === 'white-dwarf') {
    b.radiusSun = spec.radiusSun ?? whiteDwarfRadiusSun(mass);
    b.radius = b.radiusSun * PHYS.AU_PER_RSUN;
    b.teff = spec.teff ?? 12000;
    // L = 4πR²σT⁴, in solar units with the Sun's own radius and 5772 K divided out
    b.luminosity = spec.luminosity ?? Math.pow(b.radiusSun, 2) * Math.pow(b.teff / 5772, 4);
    b.spectral = 'D';
    b.rs = PHYS.schwarzschild(mass);
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

  // How fast it turns, as a fraction of its own break-up rate. This is the
  // dimensionless form of spin, and it is the one that means something: 1.0 is
  // the mass-shedding limit for ANY body, so the same number describes a
  // millisecond pulsar and a gas giant. sim/structure.js turns it into a shape.
  b.spinFrac = spec.spinFrac ?? 0;
  b.composition = spec.composition;
  b.Z = spec.Z ?? 0.014;

  // the spec is kept so the visual can be rebuilt at a different size without
  // disturbing the physics state (see rebuildVisuals)
  b.spec = spec; b.def = def;
  refreshStructure(b);

  // A MEASURED radius always wins. Failing that, take the interior model's,
  // which is the same relation the Foundry and the cross-section are showing —
  // and which, unlike the M^0.27 fallback it replaces, actually turns over.
  // Without this a 300 M⊕ planet is drawn 4.7 R⊕ across even at true scale,
  // when the whole point is that no rocky planet can exceed about 3.06.
  if (!spec.radiusKm && spec.type !== 'bh' && b.structure?.radiusAU > 0) {
    b.radius = b.structure.radiusAU;
  }
  return b;
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

  deriveBody(b, spec);

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
  b.trail.material.dispose();
  state.bodies.splice(idx, 1);
  if (state.focusId === id) { state.focusId = null; state.followId = null; }
  refreshUI();
}

// Empty the scene. Not just the body list: a body is the only thing that OWNS
// anything here, so everything it left behind has to go with it or the scene is
// not actually clear. Two kinds of debris outlive their owner —
//
//   · flashes, which are spawned at an event and then live on their own clock.
//     A Type Ia's afterglow runs for eight seconds, so clearing right after one
//     used to leave a white glow burning in an otherwise empty scene, with
//     nothing in the Bodies list to explain it and no way to remove it.
//   · everything the painter holds — rings, belts, ejecta clouds — which track
//     a body by id and simply freeze where they are once that id is gone.
//
// loadPreset goes through here, which is why loading a scenario never showed
// either problem and clearing did.
function clearBodies() {
  while (state.bodies.length) removeBody(state.bodies[0].id);
  for (const fl of flashes) killFlash(fl);
  flashes.length = 0;
  painter.clear();
  state.consumed = 0; refreshUI();
}

// add a body orbiting the dominant mass (used by Spawn buttons)
function spawnOrbiting(type) {
  const palette = type === 'gas-giant' ? ['jupiter', 'saturn', 'ice'][Math.floor(Math.random() * 3)] : undefined;
  spawnBody(placeSpawn({
    type, palette, atmosphere: type === 'planet', seed: Math.floor(Math.random() * 1e9),
  }));
  refreshUI();
}

// ---------------------------------------------------------------------------
// Put a spec on a circular orbit about the dominant mass. Shared by the quick
// spawn buttons and by the Object Foundry, so a hand-built 40 M☉ star arrives
// the same way a quick-spawn planet does.
// ---------------------------------------------------------------------------
function orbitSpecAroundDominant(spec) {
  const center = state.bodies.reduce((a, b) => (b.mass > (a?.mass ?? -1) ? b : a), null);
  const Mc = center ? Math.max(center.mass, 1e-6) : 1;
  const cpos = center ? center.pos : new THREE.Vector3();
  // Stay clear of whatever we are orbiting: outside its rendered disc, and
  // outside its horizon by a wide margin if it is a hole.
  const clearAU = center
    ? Math.max(center.radiusScene / state.sceneScale, (center.rs || 0) * 8, center.radius || 0)
    : 0;
  const aAU = clearAU * 2.5 + (5 + Math.random() * 9) / state.sceneScale;
  const ang = Math.random() * Math.PI * 2;
  const dir = new THREE.Vector3(Math.cos(ang), 0, Math.sin(ang));
  const pos = cpos.clone().addScaledVector(dir, aAU);
  const v = PHYS.circularSpeed(Mc + (spec.mass ?? 0), aAU);
  const tang = new THREE.Vector3(-Math.sin(ang), 0, Math.cos(ang)).multiplyScalar(v);
  if (center) tang.add(center.vel);
  return { ...spec, pos: [pos.x, pos.y, pos.z], vel: [tang.x, tang.y, tang.z] };
}

// ---------------------------------------------------------------------------
// Place a spec AT REST, in front of the camera.
//
// "At rest" means exactly zero velocity in the simulation frame — not zero
// relative to anything nearby — so a body dropped into a moving system really
// does get left behind by it, which is the honest thing for a workbench to do.
//
// It goes where you are looking rather than at the origin, because the whole
// point is to place things deliberately, and it is offset by a fraction of the
// viewing distance so successive spawns do not land inside each other.
// ---------------------------------------------------------------------------
let restSpawnAngle = 0;
function restSpecAtRest(spec) {
  const centre = new THREE.Vector3();
  let reach;
  if (state.camMode === 'free') {
    _fwd.set(Math.sin(cam.yaw) * Math.cos(cam.pitch), Math.sin(cam.pitch), Math.cos(cam.yaw) * Math.cos(cam.pitch));
    reach = Math.max(cam.freeSpeed * 1.5, 2);
    centre.copy(camera.position).addScaledVector(_fwd, reach);
  } else {
    centre.copy(cam.target);
    reach = cam.radius;
  }
  // Fan successive spawns around the look-at point instead of stacking them.
  restSpawnAngle += 2.399963;                       // golden angle, so they spread
  const off = reach * 0.32;
  centre.x += Math.cos(restSpawnAngle) * off;
  centre.z += Math.sin(restSpawnAngle) * off;
  const posAU = centre.multiplyScalar(1 / state.sceneScale);
  return { ...spec, pos: [posAU.x, posAU.y, posAU.z], vel: [0, 0, 0] };
}

// Spawn placement, chosen by the scenario: at rest on the workbench, in orbit
// everywhere else. An empty scene has no dominant mass to orbit, so it always
// falls back to at-rest regardless of the toggle.
// ---------------------------------------------------------------------------
// LIVE EDIT — the Foundry's sliders, pointed at a body that already exists.
// ----------------------------------------------------------------------------
// Building an object and then editing one are the same operation here: both end
// in deriveBody() re-reading a spec. What differs is only what is preserved.
// The physics state — id, position, velocity, trail, whatever it is orbiting —
// survives; everything the spec implies is thrown away and derived again, and
// the meshes with it, because a visual bakes its radius into geometry and into
// local-space offsets (corona span, ring radii, prominence loops).
//
// The edit is then passed straight to checkStructuralLimits, which is what
// makes this more than a size control: drag a 2.0 M☉ neutron star up and it
// does not become a big neutron star, it becomes a black hole, at exactly the
// mass sim/structure.js says it must. Spin it up first and it survives longer,
// because centrifugal support is real support.
// ---------------------------------------------------------------------------
function editBody(b, patch) {
  if (!b || !b.alive) return null;
  const spec = { ...(b.spec || {}), ...patch };
  if (patch.mass != null) {
    b.mass = patch.mass; b.mass0 = patch.mass;
    spec.mass = patch.mass;
    // Measured beats modelled (CLAUDE.md) — but a measurement describes ONE
    // star. Once you have changed its mass those numbers are no longer about
    // this object, so they are dropped and the evolutionary track takes over.
    // Otherwise a 16.5 M☉ Betelgeuse dragged to 1 M☉ would still be 764 R☉.
    delete spec.radiusSun; delete spec.teff; delete spec.luminosity;
    delete spec.radiusKm; delete spec.rs;
    b.radiusSun = null;
  }
  b.spec = spec;
  const before = b.radiusScene || 0;
  detachVisual(b);
  deriveBody(b, spec);
  attachVisual(b);

  // Keep the followed body framed while it is being edited. A mass slider moves
  // a radius by ORDERS OF MAGNITUDE, so without this the object either fills the
  // screen or vanishes; with a hard snap instead it lurches. The camera is asked
  // to glide, and the mesh eases from its old size over the same time constant,
  // so what you see is one object changing character rather than a cut between
  // two objects. Framing is only maintained while the drag actually moves the
  // size — a 1% change is left alone so nudging the slider does not creep the
  // view. It also never fights a zoom: the wheel cancels the glide.
  const r = Math.max(b.radiusScene, b.rsScene || 0);
  if (before > 0 && r > 0) {
    const jump = r / before;
    if (Math.abs(Math.log(jump)) > 0.01) {
      // start the mesh where it was and let it grow into its new size
      b.sizeEase = { from: 1 / jump, t: 0 };
      if (b.id === state.followId && state.camMode === 'orbit') {
        cam.radiusTo = Math.min(frameRadius(b), 20000);
      }
    }
  }
  // A verdict the sim only prints is a bug: let the limit fire immediately
  // rather than waiting for the next mass change.
  b._mCheck = null;
  checkStructuralLimits(b);
  refreshUI();
  return b;
}

function placeSpawn(spec) {
  return (state.spawnAtRest || state.bodies.length === 0)
    ? restSpecAtRest(spec)
    : orbitSpecAroundDominant(spec);
}

// ============================================================================
// STRUCTURAL CONSEQUENCES
// ----------------------------------------------------------------------------
// The interior model is not decoration: when it says a body can no longer hold
// itself up, the body has to stop existing as that kind of body. Three things
// can happen, and all three are reachable in ordinary play rather than only
// from the editor —
//
//   · a neutron star fed past its TOV mass (by accretion, or by merging with
//     another) has nothing left to support it and collapses to a black hole
//   · a star built at the end of its life does what a star at the end of its
//     life does: core collapse, and either a remnant or, in the pair-instability
//     window, nothing at all
//   · a body that crosses an ignition threshold is simply a different kind of
//     object and is rebuilt as one
//
// This runs on any body whose mass has changed since it was last checked, which
// is what makes the black-hole presets interesting: feed a 2.0 M☉ neutron star
// and you can watch the moment it gives up.
// ============================================================================
function transmute(b, newType, why) {
  const wpos = b.pos.clone().multiplyScalar(state.sceneScale);
  b.type = newType;
  b.spec = { ...(b.spec || {}), type: newType, mass: b.mass };
  b.def = TYPE_DEFAULTS[newType] || TYPE_DEFAULTS.planet;
  if (newType === 'bh') {
    b.rs = PHYS.schwarzschild(b.mass);
    b.radius = 0;
    // A horizon has no photosphere; leaving a temperature behind would keep
    // re-imaging it as a star in the non-visible bands (see CLAUDE.md).
    b.teff = undefined; b.spectral = undefined; b.luminosity = undefined;
    b.radiusSun = null;
    b.emitsGW = true;
    spawnFlash(wpos, 0xffffff, Math.max(b.rs * state.sceneScale * 9, 0.6), 1.4);
    spawnFlash(wpos, 0x9fd0ff, Math.max(b.rs * state.sceneScale * 5, 0.4), 0.3);
  }
  detachVisual(b);
  refreshStructure(b);
  attachVisual(b);
  if (why) toast(why, 5200);
  refreshUI();
}

// A star at the end of its life. What it leaves behind is decided by
// endStateOf(), which is the standard initial-to-final mass mapping — and in
// the pair-instability window it leaves nothing whatsoever.
function coreCollapse(b) {
  const end = endStateOf(b.mass);
  const wpos = b.pos.clone().multiplyScalar(state.sceneScale);
  const size = Math.max(b.radiusScene * 22, 1.5);
  // A collapsing star is bigger than a white dwarf, but so is what it throws:
  // stand back far enough that the blast is something you watch rather than
  // something you are inside. The remnant is a point source afterwards anyway.
  recoilCamera(b, size);
  spawnFlash(wpos, 0xffffff, size, 0.55);
  spawnFlash(wpos, 0xffd0a0, size * 0.6, 0.16, { kind: 'shell', grow: 12 });
  state.consumed++;
  if (end.type === 'none') {
    toast(`${b.name}: pair-instability supernova — no remnant at all`, 6000);
    spawnFlash(wpos, 0x9fd8ff, size * 1.6, 0.10, { kind: 'shell', grow: 18 });
    removeBody(b.id);
    return;
  }
  b.mass = end.mass; b.mass0 = end.mass;
  b.spinFrac = Math.min((b.spinFrac ?? 0) + 0.55, 0.95);   // collapse spins it up
  if (end.type === 'neutron') {
    b.radius = PHYS.neutronRadius(b.mass);
    b.spec = { ...(b.spec || {}), type: 'neutron', mass: b.mass, spin: 30 };
    b.teff = undefined;
    transmute(b, 'neutron', `${b.name}: core collapse → ${end.label} (${fmtMass(end.mass)})`);
  } else if (end.type === 'bh') {
    transmute(b, 'bh', `${b.name}: core collapse → ${end.label} (${fmtMass(end.mass)})`);
  } else {
    b.radiusSun = whiteDwarfRadiusSun(b.mass);
    b.radius = b.radiusSun * PHYS.AU_PER_RSUN;
    b.teff = 30000;
    b.spec = { ...(b.spec || {}), type: 'white-dwarf', mass: b.mass, teff: 30000 };
    transmute(b, 'white-dwarf', `${b.name}: envelope shed → ${end.label} (${fmtMass(end.mass)})`);
  }
}

// ---------------------------------------------------------------------------
// Stand back from an explosion you were watching from close up.
//
// The follow camera frames a body at seven of its radii, and a white dwarf is
// SMALL — about 0.2 scene units away in the workbench. The blast it throws is
// two units across before it starts expanding, i.e. ten times further out than
// the camera is: you end up inside the billboard, and an additive white
// gradient covering every pixel does not read as an explosion at all, it reads
// as a white glow filling the screen that will not go away. (It also outlives
// the body by eight seconds, so the Bodies list is empty while it is still
// there — which is exactly what it looked like.)
//
// So a destructive event pushes the view out to where the blast fits on screen,
// but only for whoever was actually following the body: a supernova across the
// system must not yank your camera. It is a glide, not a cut — the ease is the
// same one an edit uses — and it never pulls you IN, so if you were already
// watching from far away nothing moves.
// ---------------------------------------------------------------------------
function recoilCamera(b, blastSize) {
  if (b.id !== state.followId || state.camMode !== 'orbit') return;
  cam.radiusTo = Math.min(Math.max(cam.radius, blastSize * 2.4), 20000);
}

// Called for any body whose mass has moved. Cheap — it only recomputes the
// structure when the mass actually changed by more than a part in a thousand.
function checkStructuralLimits(b) {
  if (!b.alive || b.type === 'bh') return;
  if (b._mCheck != null && Math.abs(b.mass - b._mCheck) < b._mCheck * 1e-3) return;
  b._mCheck = b.mass;
  const st = refreshStructure(b);

  if (b.type === 'neutron' && b.mass > tovLimit(b.spinFrac ?? 0)) {
    transmute(b, 'bh',
      `${b.name} passed the TOV limit at ${fmtMass(b.mass)} — nothing can hold it up. Collapsed to a black hole.`);
    return;
  }
  if (b.type === 'white-dwarf' && b.mass >= LIMITS.chandrasekhar) {
    const wpos = b.pos.clone().multiplyScalar(state.sceneScale);
    const blast = Math.max(b.radiusScene * 40, 2.0);
    recoilCamera(b, blast);
    spawnFlash(wpos, 0xffffff, blast, 0.4);
    // The ejecta. A Type Ia unbinds the entire star at ~10 000 km/s, so this
    // is the one that must not still be sitting there looking like a star.
    spawnFlash(wpos, 0xbfe0ff, blast * 0.6, 0.12, { kind: 'shell', grow: 14 });
    toast(`${b.name} reached the Chandrasekhar mass — Type Ia supernova, nothing left`, 6000);
    state.consumed++;
    removeBody(b.id);
    return;
  }
  // A body that has crossed an ignition threshold is a different object.
  if (st.type !== b.type && st.reclassifiedFrom) {
    transmute(b, st.type, `${b.name}: ${st.verdict.detail}`);
  }
}

// ============================================================================
// PHYSICS STEP
// ============================================================================
function getHoles() {
  return state.bodies.filter(b => b.type === 'bh').sort((a, b) => b.mass - a.mass);
}

function getStars() {
  // White dwarfs light a scene too — Sirius B is 25 000 K, hotter than Sirius A
  // — and leaving them out would make the Sirius preset lit by one star.
  return state.bodies.filter(b => (b.type === 'star' || b.type === 'white-dwarf') && b.alive);
}
function getHome() {
  return state.homeId != null ? state.bodies.find(b => b.id === state.homeId) : null;
}

// Hottest emitter in the scene, in kelvin. The multi-wavelength imaging anchors
// its gain to this — see postfx.setSceneTemp.
function sceneMaxTemp() {
  let t = 0;
  for (const b of state.bodies) {
    if (b.type === 'star' || b.type === 'white-dwarf') t = Math.max(t, b.teff ?? effectiveTemp(b.mass));
    else if (b.type === 'neutron') t = Math.max(t, 1.0e6);
    else if (b.type === 'bh') t = Math.max(t, discPeakTemp(b.mass));
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

// Returns the simulated time actually integrated, which is <= simDt whenever
// the sub-step guard trips. Callers must drive anything on the simulated clock
// from the return value, not from what they passed in.
function stepPhysics(simDt) {
  if (simDt <= 0) return 0;
  let remaining = simDt, guard = 0, stepped = 0;
  while (remaining > 1e-12 && guard < 8000) {
    guard++;
    const h = Math.min(remaining, dynamicStep());
    PHYS.integrate(state.bodies, h);
    if (state.gwBoost) PHYS.applyGWReaction(state.bodies, h, state.gwBoost);
    const events = PHYS.resolveCollisions(state.bodies);
    for (const ev of events) handleMerger(ev);
    remaining -= h;
    stepped += h;
  }
  // Advance the clock by what was actually integrated, not by what was asked
  // for. During a close encounter dynamicStep() falls toward its 1e-8 floor and
  // the guard can stop the loop having covered under a percent of simDt; adding
  // the full simDt there would jump the clock, the climate and the shader time
  // uniforms while the bodies had barely moved, and the deficit is never repaid.
  state.simYears += stepped;
  // commit visual positions + trails after the sub-steps
  for (const b of state.bodies) {
    b.viz.group.position.copy(b.pos).multiplyScalar(state.sceneScale);
    pushTrail(b);
  }
  // advance the climate on the same simulated clock
  const home = getHome();
  if (state.climate && home) state.climate.step(stepped, home, getStars());
  return stepped;
}

function handleMerger(ev) {
  const surv = ev.survivor, gone = ev.absorbed;
  const wpos = surv.pos.clone().multiplyScalar(state.sceneScale);
  if (surv.type === 'bh' || gone.type === 'bh') {
    const wasBH = surv.type === 'bh';
    surv.type = 'bh';
    if (wasBH) {
      // r_s ∝ M, so summing the two horizons is exactly the horizon of the
      // merged mass — and it carries a preset's deliberately "fat" horizon
      // through the merger instead of collapsing it to the true one.
      surv.rs = (surv.rs || 0) + (gone.type === 'bh' ? gone.rs : PHYS.schwarzschild(gone.mass));
    } else {
      // resolveCollisions keeps the heavier body, so a star heavier than the
      // hole survives and becomes one. Scale the absorbed horizon by the mass
      // it now contains; taking gone.rs alone ignored the survivor's own mass.
      surv.rs = gone.rs * (surv.mass / gone.mass);
    }
    if (!surv.rs) surv.rs = PHYS.schwarzschild(surv.mass);
    // The physics type changed, so the spec and the meshes have to follow it.
    // Left alone, the lens pass would place a horizon over a star mesh, and a
    // later true-scale toggle would rebuild it as a star again.
    if (!wasBH) {
      surv.spec = { ...(surv.spec || {}), type: 'bh', mass: surv.mass, rs: surv.rs };
      surv.def = TYPE_DEFAULTS.bh;
      // A horizon has no photosphere: leaving the star's Teff behind would keep
      // publishing a stellar temperature into the HDR alpha and re-image the
      // hole as a star in the non-visible bands.
      surv.teff = undefined; surv.spectral = undefined;
      detachVisual(surv);
      attachVisual(surv);
    }
    const rsS = surv.rs * state.sceneScale;
    spawnFlash(wpos, 0xffffff, rsS * 9, 1.6);             // bright ringdown burst
    spawnFlash(wpos, 0xffd2a0, rsS * 5, 0.32);            // slow lingering afterglow
  } else if (surv.type === 'neutron' && gone.type === 'neutron') {
    spawnFlash(wpos, 0xffffff, surv.radiusScene * 60, 1.4);
    // kilonova: the tidal tails and the disc wind, which really are ejecta
    spawnFlash(wpos, 0xbfe0ff, surv.radiusScene * 34, 0.28, { kind: 'shell', grow: 10 });
  } else {
    spawnFlash(wpos, 0xffaa66, surv.radiusScene * 14, 0.8, { kind: 'shell', grow: 6 });
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
  // Where the viewing distance is HEADING, when something asked for a new one
  // smoothly. Null means the camera is exactly where it was put.
  radiusTo: null,
  // free fly
  yaw: 0, pitch: 0, freeSpeed: 12,
};
// Put the camera at a distance immediately, cancelling any glide in progress.
// Everything that repositions the camera on purpose — the zoom wheel, reset,
// loading a preset — goes through here, or an in-flight ease would drag the
// view back out from under it a frame later.
function jumpCamRadius(r) { cam.radius = r; cam.radiusTo = null; }

// The distance to frame a body from: seven of its radii, but never closer than
// the scene can actually resolve.
//
// Every shader gets positions as float32, so a point sitting D scene units from
// the origin is only known to about D·1e-5 units. A stellar-mass horizon is
// r_s ≈ 1e-7 units — smaller than its own coordinate noise — so framing it at
// 7 r_s does not give a close look at a black hole, it drops the camera inside
// the rounding error, where the ray marcher has nothing to march through and
// the rest of the scene is astronomically far away. That is the blank screen
// you used to get the moment a star or a neutron star collapsed while followed.
// Sub-resolution bodies are carried by the point-source marker (sim/scale.js)
// instead, and the marker holds a constant on-screen size at any distance, so
// stopping at the floor costs nothing and keeps the object findable.
//
// The floor is well below every real body — a true-scale Earth at 1 AU is
// framed at 3e-4 against a 1e-5 floor — so this only ever binds on horizons.
function frameRadius(b) {
  const geometric = Math.max(b.radiusScene, b.rsScene || 0) * 7;
  const resolvable = Math.max(1e-6, b.viz.group.position.length() * 1e-5);
  if (geometric >= resolvable) return geometric;
  // Below the floor there is nothing to fly to. The marker holds a constant
  // on-screen size however close you get, so approaching it changes nothing
  // except throwing away every other object in the scene — the view is left
  // where it was, and the marker simply lights up at whatever distance you are.
  return Math.max(cam.radius, resolvable);
}
// Ask for a distance instead of taking one. Geometric (log-space) easing,
// because viewing distance is a scale: gliding from 1e-4 to 1e2 AU linearly
// spends the whole animation in the last decade and looks like a jump anyway.
function easeCamRadius(dt) {
  if (cam.radiusTo == null) return;
  const ratio = cam.radiusTo / cam.radius;
  if (Math.abs(Math.log(ratio)) < 0.01) { cam.radius = cam.radiusTo; cam.radiusTo = null; return; }
  // frame-rate independent: same time constant at 30 and 144 fps
  cam.radius *= Math.pow(ratio, 1 - Math.exp(-dt * 6));
}
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
    jumpCamRadius(frameRadius(body));
    if (state.camMode === 'orbit') updateOrbitCam();
  }
  refreshUI();
}

// pointer / drag
let dragging = false, dragMoved = false, lastX = 0, lastY = 0, downX = 0, downY = 0;
const el = renderer.domElement;
el.addEventListener('mousedown', e => { dragging = true; dragMoved = false; lastX = downX = e.clientX; lastY = downY = e.clientY; });
addEventListener('mouseup', e => {
  // Only interactions that began on the canvas are picks. dragMoved stays false
  // for anything started on the HUD, so without this a slider drag or a panel
  // click ran a pick behind the panel and cleared the focused body.
  const wasDragging = dragging;
  dragging = false;
  if (wasDragging && !dragMoved) handlePick(e);
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
  if (state.camMode === 'orbit') { jumpCamRadius(Math.max(1e-6, Math.min(20000, cam.radius * (1 + e.deltaY * 0.001)))); updateOrbitCam(); }
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
  if (e.key === 'r' || e.key === 'R') { cam.target.set(0, 0, 0); jumpCamRadius(state.preset.camRadius); cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2; if (state.camMode === 'orbit') updateOrbitCam(); }
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
  clearBodies();          // bodies, painted swarms and any flash still burning

  state.preset = p;
  // Where in the universe this system sits. A preset that says nothing gets the
  // mid-disc default, which is the familiar arrangement.
  syncSky(u => applySkyEnvironment(u, p.sky || {}));
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
  setSpawnAtRest(p.spawnAtRest ?? false);
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

  // Anything the scenario paints on: rings, belts, ejecta. Applied after the
  // bodies exist, since each decoration is pinned to one of them by name.
  for (const spec of p.paint || []) applyPaintSpec(spec);

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
  cam.target.set(0, 0, 0); jumpCamRadius(p.camRadius); cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2;
  setCamMode('orbit');
  if (p.focus) {
    const f = state.bodies.find(b => b.name === p.focus);
    if (f) { setFollow(f); jumpCamRadius(p.camRadius); }
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
  if (DOM.camSurface) DOM.camSurface.style.display = p.surface ? '' : 'none';
  spacetimeMesh.visible = state.showMesh;
  document.querySelectorAll('[data-preset]').forEach(b => b.classList.toggle('active', b.dataset.preset === key));
  refreshUI();
}

// ============================================================================
// PAINTING
// ----------------------------------------------------------------------------
// The parameters are derived from the body rather than asked for, because the
// interesting ones are not free: a ring's span is fixed by the Roche limit, and
// a belt's gaps are fixed by which resonances a perturber has cleared.
// ============================================================================
function applyPaintSpec(spec) {
  const b = spec.body ? state.bodies.find(x => x.name === spec.body) : null;
  if (spec.body && !b) return null;
  const common = { bodyId: b ? b.id : null, sceneScale: state.sceneScale };
  if (spec.kind === 'cloud') {
    return painter.add('cloud', {
      ...common,
      radius: spec.radius ?? 10, lobes: spec.lobes ?? 1,
      color: spec.color ?? 0xffcf9a, density: spec.density ?? 0.7,
      expandAUperYr: spec.expand ?? 0, seed: spec.seed ?? Math.random() * 100,
      label: spec.label ?? 'ejecta',
    });
  }
  return painter.add(spec.kind === 'belt' ? 'belt' : 'ring', {
    ...common,
    centralMass: b ? b.mass : 1,
    inner: spec.inner, outer: spec.outer,
    count: spec.count ?? (spec.kind === 'belt' ? 11000 : 26000),
    ecc: spec.ecc ?? (spec.kind === 'belt' ? 0.14 : 0.0025),
    incl: spec.incl ?? (spec.kind === 'belt' ? 0.16 : 0.001),
    color: spec.color ?? 0xcdbb99,
    sizePx: spec.sizePx ?? (spec.kind === 'belt' ? 2.4 : 2.0),
    tilt: spec.tilt ?? 0,
    perturberA: spec.perturber ?? null,
    surfaceDensity: spec.surfaceDensity ?? -1.5,
    label: spec.label ?? spec.kind,
  });
}

// The "Ring" button. What it mostly does is REFUSE, when the body it was aimed
// at cannot have one — and saying why is the point of the button.
function paintRingOn(b) {
  if (!b) return toast('Focus a body first (click it, or pick it from Bodies)');
  if (b.type === 'bh') {
    return toast('A black hole has no surface for a ring to sit above — what it gets instead is an accretion disc, which the lensing pass already draws.', 6000);
  }
  const span = ringSpan(b.mass, b.radius || 1e-6, 'ice');
  if (!span.outer) {
    return toast(`${b.name} is too diffuse for a ring: its Roche limit falls inside its own surface, so any orbiting debris is outside the tidal zone and would simply accrete into a moon.`, 7000);
  }
  applyPaintSpec({
    kind: 'ring', body: b.name,
    inner: span.inner, outer: span.outer,
    tilt: (Math.random() - 0.5) * 0.5,
    color: b.type === 'star' ? 0xffd8b4 : 0xcdbb99,
  });
  toast(`Ring around ${b.name}: ${(span.inner / PHYS.AU_PER_KM).toFixed(0)}–${(span.outer / PHYS.AU_PER_KM).toFixed(0)} km, i.e. from just above the surface out to the Roche limit at ${(span.roche / (b.radius || 1)).toFixed(2)} body radii. Outside that, this material would clump into a moon instead.`, 8000);
}

function paintBeltOn(b) {
  if (!b) return toast('Focus a body first (click it, or pick it from Bodies)');
  // The belt goes around whatever this body orbits, not around the body — a
  // belt is a heliocentric structure. If the focus IS the dominant mass, use it.
  const central = state.bodies.reduce((a, x) => (x.mass > (a?.mass ?? -1) ? x : a), null);
  const host = (b === central) ? b : central;
  if (!host) return;
  const rHost = Math.max(host.radius || 0, host.rs || 0);
  // Place it where the solar system's is, in units of the host's own scale:
  // 2.1–3.3 AU about 1 M☉ scales as √M for a fixed orbital period.
  const k = Math.sqrt(Math.max(host.mass, 1e-6));
  const inner = Math.max(2.1 * k, rHost * 4), outer = Math.max(3.4 * k, rHost * 7);
  // The nearest more massive body outside the belt is what clears the gaps.
  let perturber = null, best = Infinity;
  for (const o of state.bodies) {
    if (o === host || o.mass < host.mass * 1e-5) continue;
    const a = o.pos.distanceTo(host.pos);
    if (a > outer && a < best) { best = a; perturber = a; }
  }
  applyPaintSpec({
    kind: 'belt', body: host.name, inner, outer,
    perturber, color: 0x9a8d7c, surfaceDensity: -1.0,
  });
  toast(perturber
    ? `Belt from ${inner.toFixed(2)} to ${outer.toFixed(2)} AU, with Kirkwood gaps cleared at the 3:1, 5:2, 7:3 and 2:1 resonances with the body at ${perturber.toFixed(2)} AU.`
    : `Belt from ${inner.toFixed(2)} to ${outer.toFixed(2)} AU. No body outside it to clear resonance gaps, so it is smooth — which is what the asteroid belt would look like without Jupiter.`, 8000);
}

function paintCloudOn(b) {
  if (!b) return toast('Focus a body first (click it, or pick it from Bodies)');
  const r = Math.max((b.radius || 0.01) * 12, 0.6 / state.sceneScale);
  applyPaintSpec({
    kind: 'cloud', body: b.name, radius: r,
    lobes: 2, density: 0.7,
    // 650 km/s, the measured expansion of Eta Carinae's Homunculus, in AU/yr.
    expand: 0.137,
    color: b.teff > 9000 ? 0xbcd6ff : 0xffcf9a,
  });
  toast(`Ejecta shell around ${b.name}, expanding at 650 km/s — the measured speed of η Carinae's Homunculus. It limb-brightens into a rim because it is optically thin and hollow.`, 7000);
}

// ============================================================================
// UI
// ============================================================================
function renderPresetGroups() {
  presetSearchText = (DOM.presetSearch?.value ?? '').trim().toLowerCase();
  const searching = presetSearchText.length > 0;
  let visibleGroups = 0;

  const markup = PRESET_GROUPS.map(group => {
    const groupText = `${group.id} ${group.label}`.toLowerCase();
    const groupMatches = searching && groupText.includes(presetSearchText);
    const visibleKeys = !searching || groupMatches
      ? group.keys
      : group.keys.filter(key => {
          const p = PRESETS[key];
          return `${key} ${p.name}`.toLowerCase().includes(presetSearchText);
        });
    if (!visibleKeys.length) return '';

    visibleGroups++;
    const count = searching && !groupMatches
      ? `${visibleKeys.length}/${group.keys.length}`
      : `${group.keys.length}`;
    const open = searching || openPresetGroups.has(group.id);
    const buttons = visibleKeys.map(key => {
      const p = PRESETS[key];
      const tri = group.id === 'trisolaris' ? ' tri' : '';
      const active = p === state.preset ? ' active' : '';
      return `<button class="preset-btn${tri}${active}" data-preset="${key}">${p.name}</button>`;
    }).join('');

    return `<details class="preset-group" data-group="${group.id}"${open ? ' open' : ''}>
      <summary><span class="preset-group-name">${group.label}</span><span class="preset-group-count">${count}</span></summary>
      <div class="preset-group-items">${buttons}</div>
    </details>`;
  }).join('');

  DOM.presetList.innerHTML = markup;
  DOM.presetList.hidden = visibleGroups === 0;
  DOM.presetEmpty.hidden = visibleGroups !== 0;
  if (DOM.presetEmpty && searching) {
    DOM.presetEmpty.textContent = `No scenarios or categories match "${DOM.presetSearch.value.trim()}"`;
  }
  if (DOM.presetSearchClear) DOM.presetSearchClear.hidden = !searching;

  // Native details provide the dropdown behavior and keyboard accessibility.
  // Search owns the open state while active so every matching category stays
  // visible; manually opened groups are remembered when the query is cleared.
  DOM.presetList.querySelectorAll('.preset-group').forEach(group => {
    group.addEventListener('toggle', () => {
      if (presetSearchText) {
        if (!group.open) group.open = true;
        return;
      }
      if (group.open) openPresetGroups.add(group.dataset.group);
      else openPresetGroups.delete(group.dataset.group);
    });
  });
}

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

  // An open cross-section tracks the focused body. Bodies change — a star
  // being eaten loses mass every frame, and the diagram should say so.
  if (xsecOpen && DOM.xsecPanel && DOM.xsecPanel.style.display !== 'none') {
    const fb = state.bodies.find(b => b.id === state.focusId);
    if (fb) { showCrossSection(fb); liveEditor?.sync(fb); }
    else setPanelOpen('xsecPanel', false);
  }

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
  // The left column is a stack: the scenario list opening or closing moves the
  // editor under it, and the editor being open squeezes the list.
  if (id === 'xsecPanel') document.body.classList.toggle('xsec-open', open && !state.hudHidden);
  if (id === 'scenarioPanel' || id === 'xsecPanel') layoutLeftColumn();
}

// ---------------------------------------------------------------------------
// The left column holds the scenario list with the cross-section + editor under
// it. Neither has a fixed height — the scenario list grows with its groups and
// the editor grows with the body it is showing — so the editor's top edge is
// measured rather than hard-coded, and it slides up when the list is collapsed.
// ---------------------------------------------------------------------------
function layoutLeftColumn() {
  const top = document.getElementById('scenarioPanel');
  const open = top && top.style.display !== 'none';
  const y = open ? Math.round(top.getBoundingClientRect().bottom) + 12 : 92;
  document.documentElement.style.setProperty('--xsec-top', `${y}px`);
}
// The scenario panel changes height when a group is expanded, and the editor
// changes height when the body changes type — so watch, rather than guess.
if (window.ResizeObserver) {
  const ro = new ResizeObserver(() => layoutLeftColumn());
  // The panel itself, and the two children that actually change its height: the
  // scenario list (groups expand) and the blurb (every preset writes a
  // different one). Observing only the panel misses growth that happens in the
  // same frame the observer is installed.
  for (const id of ['scenarioPanel', 'presetList', 'blurb']) {
    const el = document.getElementById(id);
    if (el) ro.observe(el);
  }
}
addEventListener('resize', layoutLeftColumn);

document.querySelectorAll('[data-close]').forEach(btn =>
  btn.addEventListener('click', () => setPanelOpen(btn.dataset.close, false)));
document.querySelectorAll('[data-open]').forEach(btn =>
  btn.addEventListener('click', () => setPanelOpen(btn.dataset.open, true)));
// both start open — this also seeds the body class the hint's position keys off
for (const id of ['scenarioPanel', 'controlPanel']) setPanelOpen(id, true);
// The cross-section starts closed and has no tab: it is opened from a focused
// body, so there is nothing to come back to until one is focused.
setPanelOpen('xsecPanel', false);

function setHudHidden(hidden) {
  state.hudHidden = hidden;
  for (const el of document.querySelectorAll('.hud')) {
    // panels obey their own collapsed state once the HUD comes back
    el.style.display = hidden ? 'none' : '';
  }
  for (const id of ['scenarioPanel', 'controlPanel', 'xsecPanel']) setPanelOpen(id, !collapsed.has(id));
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
  // The sky does not go through the spectral remap — it composites itself at
  // the band's own frequency, because most of what it contains outside the
  // visible is non-thermal and has no temperature to re-image from.
  syncSky(u => applySkyBand(u, state.band));
}

if (DOM.bandGrid) {
  DOM.bandGrid.innerHTML = BANDS.map((b, i) =>
    `<button class="band-btn" data-band="${i}" title="${b.note}">${b.short}</button>`).join('');
  DOM.bandGrid.querySelectorAll('[data-band]').forEach(btn =>
    btn.addEventListener('click', () => setBand(+btn.dataset.band)));
}
setBand(VISIBLE_BAND);

renderPresetGroups();
DOM.presetSearch?.addEventListener('input', renderPresetGroups);
DOM.presetSearchClear?.addEventListener('click', () => {
  DOM.presetSearch.value = '';
  renderPresetGroups();
  DOM.presetSearch.focus();
});
DOM.presetList?.addEventListener('click', event => {
  const btn = event.target.closest('[data-preset]');
  if (btn) loadPreset(btn.dataset.preset);
});

document.querySelectorAll('[data-spawn]').forEach(btn => btn.addEventListener('click', () => spawnOrbiting(btn.dataset.spawn)));
document.querySelectorAll('[data-paint]').forEach(btn => btn.addEventListener('click', () => {
  const b = state.bodies.find(x => x.id === state.focusId);
  switch (btn.dataset.paint) {
    case 'ring':  paintRingOn(b); break;
    case 'belt':  paintBeltOn(b); break;
    case 'cloud': paintCloudOn(b); break;
    case 'clear': painter.clear(); toast('Cleared everything painted'); break;
  }
}));
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
// --- render scale. resize() derives every target size from the pixel ratio,
// so setting it and re-running that is the whole implementation.
const rsEl = document.getElementById('renderScale');
rsEl?.addEventListener('input', () => {
  // The slider asks; devicePixelRatio caps. Report what the framebuffer
  // actually got, so a DPR-1 display does not read "2.00x" at 1.00x pixels.
  const effective = Math.min(devicePixelRatio, parseFloat(rsEl.value));
  renderer.setPixelRatio(effective);
  resize();
  document.getElementById('renderScale-val').textContent = `${effective.toFixed(2)}x`;
});

// --- lens detail: the marcher's resolution as a fraction of the display's.
// Separate from render scale on purpose — this one leaves the star field at
// full resolution, so it costs disc and shadow sharpness and nothing else.
const ldEl = document.getElementById('lensScale');
if (ldEl) {
  ldEl.value = String(lensPass.getScale());
  document.getElementById('lensScale-val').textContent = `${lensPass.getScale().toFixed(2)}x`;
  ldEl.addEventListener('input', () => {
    const v = parseFloat(ldEl.value);
    lensPass.setScale(v);
    document.getElementById('lensScale-val').textContent = `${v.toFixed(2)}x`;
  });
}

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
document.getElementById('resetView').addEventListener('click', () => { setFollow(null); cam.target.set(0, 0, 0); jumpCamRadius(state.preset.camRadius); cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2; setCamMode('orbit'); updateOrbitCam(); });

function setSpawnAtRest(on) {
  state.spawnAtRest = on;
  const btn = document.querySelector('[data-view="spawnrest"]');
  if (btn) {
    btn.classList.toggle('active', on);
    btn.textContent = on ? 'Spawn: At rest' : 'Spawn: In orbit';
  }
}

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
  else if (v === 'spawnrest') setSpawnAtRest(!state.spawnAtRest);
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
  lensPass.setSize(w * pr, h * pr);
  lensMaterial.uniforms.aspect.value = w / h;
  lensMaterial.uniforms.fov.value = camera.fov * Math.PI / 180;
  backdrop.uniforms.aspect.value = w / h;
  // The instrument PSF is pinned to the DEFAULT fov and only moves when the
  // framebuffer does, so zooming spreads a star over more pixels the way a real
  // telescope does instead of concentrating it into a brighter dot.
  syncSky(u => applySkyOptics(u, { fov: camera.fov * Math.PI / 180, height: h * pr }));
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

  // Everything downstream runs on the time that was integrated, so a guarded
  // frame slows the spin, the clouds and the lens together with the bodies
  // instead of letting them run ahead.
  const simStepped = stepPhysics(simDt);
  runPendingCollapse();
  painter.update(simStepped);
  updateSuns();
  postfx.setSceneTemp(sceneMaxTemp());

  // body visual updates
  const holes = getHoles().map(h => ({ posScene: h.viz.group.position, rsScene: h.rsScene, mass: h.mass }));
  const ctx = {
    holes, camera, time: state.time, sceneScale: state.sceneScale,
    simDt: simStepped, suns: state.suns, climate: state.climate,
  };
  for (const b of state.bodies) {
    if (b.type === 'bh') { b.rsScene = b.rs * state.sceneScale; b.radiusScene = b.rsScene; }
    b.viz.update(dt * (state.paused ? 0 : 1) + 0.0001, ctx); // keep shaders animating even paused-ish
    applySizeEase(b, dt);
  }
  // Structural limits, on anything whose mass moved this frame. Accretion and
  // mergers both change mass, so this is where a fed neutron star finds out it
  // is over the TOV limit.
  for (const b of state.bodies.slice()) checkStructuralLimits(b);

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
    easeCamRadius(dt);
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
    // (b.sizeK) — during an edit the mesh is mid-glide, so the marker has to
    // hand over at the size actually being drawn or it pops.
    b.marker.update(camera, b.viz.group.position,
                    Math.max(b.radiusScene, b.rsScene || 0) * (b.sizeK ?? 1),
                    innerHeight, b.id === state.focusId);
  }

  // The star-less fallback light. sunLight is only visible when the scene
  // contains no emitters at all, and it then has to come from SOMEWHERE.
  //
  // A black hole is the honest answer where there is one: its disc is the light
  // in that scene, so the lamp sits on it. Where there is not one — the Blank
  // Canvas, most obviously — there is genuinely nothing illuminating anything,
  // and the choice is between a black screen and admitting to a viewing lamp.
  // It rides the camera, which is what makes it read as a lamp rather than as
  // an invisible star at the origin, and the moment you spawn a real star it
  // switches off and the scene is lit by physics again.
  if (sunLight.visible) {
    // `holes` is the flattened description built for the shaders above, not the
    // bodies themselves: it carries posScene, and reaching for .viz on it threw
    // every frame — which killed the rest of animate(), so the composite never
    // ran and the canvas froze on its last good frame. That is what a star or a
    // neutron star collapsing in a star-less scene used to look like: the sim
    // kept stepping, the HUD kept updating, and the picture stopped, leaving a
    // dead image of the object that no longer existed to click on.
    const lum = holes[0];
    if (lum) sunLight.position.copy(lum.posScene);
    else sunLight.position.copy(camera.position);
  }

  // flashes
  for (let i = flashes.length - 1; i >= 0; i--) {
    const f = flashes[i]; f.life -= dt * (f.decay ?? 0.8);
    if (f.life <= 0) { killFlash(f); flashes.splice(i, 1); continue; }
    const p = 1 - f.life;                                   // 0 → 1 over the life
    // t^½ for ejecta (decelerating), linear for light (nothing is moving)
    const k = 1 + (f.grow ?? 2) * (f.shell ? Math.sqrt(p) : p);
    f.sp.scale.setScalar(f.size * k);
    // Spreading the same emission over k× the radius costs a factor k in
    // surface brightness; light that is not going anywhere just fades.
    f.sp.material.opacity = f.shell ? Math.pow(f.life, 1.5) / k : f.life;
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
  meshMat.uniforms.time.value += simStepped;

  // lensing uniforms
  lensMaterial.uniforms.time.value += simStepped;
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

  // The sky's footprint reference has to track the CURRENT fov, not the one at
  // the last resize: it is what the measured per-pixel footprint is compared
  // against to recover the magnification, so a zoom that changed it silently
  // would make every star near the ring the wrong brightness.
  syncSky(u => { u.uPixAngle.value = (camera.fov * Math.PI / 180) / (innerHeight * renderer.getPixelRatio()); });

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
    // Stars first, geometry over them. On the ground the atmosphere decides how
    // much of this survives — sim/skyview.js fades the whole backdrop out under
    // a lit sky — but it has to be there to be faded.
    drawBackdrop();
    renderer.autoClear = false;
    renderer.render(scene, camera);
    renderer.autoClear = true;
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
    //
    // Internally this is two passes: the geodesics and the disc are marched at
    // state.lensScale, and the star field is evaluated over the resulting
    // direction field at full resolution. See sim/blackhole.js.
    lensPass.render(renderer, postfx.hdr);

    // pass 2 — real geometry back on top, with depth, over the lensed image
    renderer.autoClear = false; renderer.clearDepth();
    renderer.render(scene, camera);
    renderer.autoClear = true;
  } else {
    // No hole, so no marcher to trace the sky — the backdrop draws it instead,
    // from the same GLSL, and the scene composites over it.
    renderer.setRenderTarget(postfx.hdr); renderer.clear();
    drawBackdrop();
    renderer.autoClear = false;
    renderer.render(scene, camera);
    renderer.autoClear = true;
  }
  postfx.render(1.0, state.time);
  updateHUD(dt);
}

// ============================================================================
// OBJECT FOUNDRY + CROSS-SECTION
// ============================================================================
const foundry = DOM.foundry ? createFoundry({
  mount: DOM.foundry,
  onSpawn(spec, structure) {
    const b = spawnBody(placeSpawn({
      ...spec,
      seed: Math.floor(Math.random() * 1e9),
      atmosphere: spec.type === 'planet',
    }));
    setFollow(b);
    // A star built at the very end of its life does not get to sit there. The
    // foundry can put a 200 M☉ star one step from core collapse into the
    // scene, and the only honest thing for it to then do is collapse.
    if (spec.type === 'star' && (spec.phase ?? 0) >= 1.93) {
      pendingCollapse.push({ id: b.id, at: state.time + 1.6 });
      toast(`${b.name} is at core collapse — watch`, 3000);
    } else if (structure?.verdict?.state === VERDICT.explode && spec.type === 'star') {
      toast(structure.verdict.label + ' — ' + structure.verdict.detail.slice(0, 120) + '…', 7000);
    }
  },
}) : null;

// Stars spawned at the end of their lives collapse a moment later, so the
// explosion is something you watch rather than something that has already
// happened by the time the panel closes.
const pendingCollapse = [];
function runPendingCollapse() {
  for (let i = pendingCollapse.length - 1; i >= 0; i--) {
    if (state.time < pendingCollapse[i].at) continue;
    const b = state.bodies.find(x => x.id === pendingCollapse[i].id);
    pendingCollapse.splice(i, 1);
    if (b && b.alive) coreCollapse(b);
  }
}

const inspector = DOM.xsecCanvas ? createInspector({
  canvas: DOM.xsecCanvas, legend: DOM.xsecLegend,
  factsEl: DOM.xsecFacts, verdictEl: DOM.xsecVerdict, notesEl: DOM.xsecNotes,
}) : null;

// The live editor lives in the same panel as the diagram, because they are two
// halves of one idea: the cross-section says what the body is, and the sliders
// under it are the only way to argue with that.
const liveEditor = DOM.liveEdit ? createLiveEditor({
  mount: DOM.liveEdit,
  onEdit(b, patch) {
    editBody(b, patch);
    // The body may no longer be the object it was — a neutron star dragged past
    // the TOV mass is now a black hole — so re-read whatever survived.
    const now = state.bodies.find(x => x.id === b.id);
    if (now) { showCrossSection(now); liveEditor.sync(now); }
    else setPanelOpen('xsecPanel', false);
  },
}) : null;

let xsecOpen = false;
function showCrossSection(b) {
  if (!inspector || !b) return;
  DOM.xsecName.textContent = `#${b.id} ${b.name}`;
  inspector.show(refreshStructure(b), b.structure?.label);
}
DOM.xsecOpen?.addEventListener('click', () => {
  const b = state.bodies.find(x => x.id === state.focusId);
  if (!b) return;
  xsecOpen = true;
  setPanelOpen('xsecPanel', true);
  showCrossSection(b);
  liveEditor?.sync(b);
});
document.querySelector('[data-close="xsecPanel"]')?.addEventListener('click', () => { xsecOpen = false; });

// ============================================================================
// BOOT
// ============================================================================
// There is no build step and no test runner here, so the console IS the
// debugger: `SIM.state.bodies[0].structure` is how you check what the physics
// thinks a body is, `SIM.load('vega')` is faster than editing the hash, and
// `SIM.renderer.info.render` settles "is this thing being drawn at all" in one
// line. This is a deliberate handle, not a leftover.
window.SIM = { state, scene, camera, cam, renderer, THREE, load: loadPreset, refreshStructure, spawnBody, setFollow, placeSpawn, setSpawnAtRest, foundry, liveEditor, editBody, showCrossSection, coreCollapse, painter, applyPaintSpec };

resize();
// Own properties only: a plain `PRESETS[key]` lookup resolves inherited members,
// so opening the page at #constructor or #toString passed the truthiness test,
// walked past loadPreset's own guard and threw on p.build() — the sim never
// booted and the loading overlay never cleared.
const hasPreset = k => Object.prototype.hasOwnProperty.call(PRESETS, k);
loadPreset(hasPreset(location.hash.slice(1)) ? location.hash.slice(1) : 'sandbox');
addEventListener('hashchange', () => { const k = location.hash.slice(1); if (hasPreset(k)) loadPreset(k); });
setTimeout(() => { DOM.loading.classList.add('gone'); animate(); }, 400);
