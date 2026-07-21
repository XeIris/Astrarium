import * as THREE from 'three';
import * as PHYS from './sim/physics.js';
import { createBodyVisual } from './sim/bodies.js';
import { GAS_PALETTES } from './sim/textures.js';
import { PRESETS, PRESET_ORDER } from './sim/presets.js';

// ============================================================================
// STATE
// ============================================================================
const state = {
  preset: null,            // active preset object
  sceneScale: 2.0,         // scene units per AU
  bodyScale: 1.0,
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

  camMode: 'orbit',        // 'orbit' | 'free'
  followId: null,          // body id the orbit camera tracks
  focusId: null,           // selected body id

  bodies: [],
  consumed: 0,
  nextId: 1,
  time: 0,
};

const DOM = {};
['fps', 'rs', 'isco', 'bc', 'cc', 'count', 'bodyList', 'loading', 'massRow',
 'blurb', 'presetName', 'focusName', 'focusPanel', 'camOrbit', 'camFree',
 'discRow', 'tempRow', 'speedVal'].forEach(id => DOM[id] = document.getElementById(id));

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
document.getElementById('canvas-wrap').appendChild(renderer.domElement);

const ambient = new THREE.AmbientLight(0x223044, 0.6); scene.add(ambient);
const sunLight = new THREE.PointLight(0xffffff, 2.2, 0, 0); scene.add(sunLight);

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
// LENSING SHADER (supports up to 2 black holes)
// ============================================================================
const lensMaterial = new THREE.ShaderMaterial({
  uniforms: {
    tScene: { value: null }, tStars: { value: starTex },
    resolution: { value: new THREE.Vector2() },
    holePos: { value: [new THREE.Vector3(), new THREE.Vector3()] },
    holeRs: { value: [1.0, 0.0] }, holeCount: { value: 1 },
    camPos: { value: new THREE.Vector3() }, camMat: { value: new THREE.Matrix4() },
    fov: { value: 0.87 }, aspect: { value: 1 },
    discInner: { value: 3 }, discOuter: { value: 12 },
    discIntensity: { value: 0.9 }, discTemp: { value: 0.6 }, time: { value: 0 }, enabled: { value: 1 },
  },
  vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy,0.0,1.0); }`,
  fragmentShader: `
    precision highp float;
    varying vec2 vUv;
    uniform sampler2D tScene, tStars; uniform vec2 resolution;
    uniform vec3 holePos[2]; uniform float holeRs[2]; uniform int holeCount;
    uniform vec3 camPos; uniform mat4 camMat; uniform float fov, aspect;
    uniform float discInner, discOuter, discIntensity, discTemp, time, enabled;
    #define PI 3.14159265359
    #define STEPS 160
    #define MAX_DIST 400.0
    vec3 sampleStars(vec3 d){ float u=atan(d.z,d.x)/(2.0*PI)+0.5; float v=asin(clamp(d.y,-1.0,1.0))/PI+0.5; return texture2D(tStars,vec2(u,v)).rgb; }
    float hash(vec2 p){ return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
    float noise(vec2 p){ vec2 i=floor(p),f=fract(p); vec2 u=f*f*(3.0-2.0*f);
      return mix(mix(hash(i),hash(i+vec2(1,0)),u.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),u.x),u.y); }
    float fbm(vec2 p){ float v=0.0,a=0.5; for(int i=0;i<4;i++){v+=a*noise(p);p*=2.1;a*=0.5;} return v; }
    vec3 bb(float t){ vec3 c=vec3(1.0,0.15,0.02),m=vec3(1.0,0.6,0.15),h=vec3(0.85,0.92,1.2);
      return t<0.5?mix(c,m,t*2.0):mix(m,h,(t-0.5)*2.0); }
    vec4 disc(vec3 p, vec3 rd, float rs){
      float inner = rs*3.0, outer = rs*12.0;          // each hole carries its own disc
      float r=length(p.xz); if(p.y>0.3||p.y<-0.3) return vec4(0.0);
      if(r<inner||r>outer) return vec4(0.0);
      float thick=exp(-p.y*p.y*22.0); float rn=(r-inner)/(outer-inner);
      float bright=pow(1.0-rn,2.0)+0.1; float ang=atan(p.z,p.x);
      vec2 uv=vec2(r*0.6, ang*3.5+r*0.3-time*0.8/max(r*0.3,0.5));
      float n=fbm(uv)*0.7+0.3;
      float streaks=pow(abs(sin(ang*8.0+r*2.0-time*2.0/max(r,1.0))),4.0)*0.3;
      float dens=n+streaks; float temp=mix(0.2,1.0,(1.0-rn)*discTemp+0.3);
      vec3 col=bb(temp); vec3 vel=normalize(vec3(-p.z,0.0,p.x));
      float beta=clamp(sqrt(rs/(2.0*r)),0.0,0.85); float ct=dot(vel,-rd);
      col*=pow(1.0/(1.0-beta*ct),3.5);
      float grsh=sqrt(max(1.0-rs/max(r,rs*1.01),0.0)); col*=mix(vec3(1.0,0.6,0.3),vec3(1.0),grsh);
      float a=dens*thick*bright*discIntensity; return vec4(col*a,clamp(a,0.0,1.0));
    }
    void main(){
      vec2 ndc=vUv*2.0-1.0; ndc.x*=aspect; float f=tan(fov*0.5);
      vec3 rl=normalize(vec3(ndc.x*f,ndc.y*f,-1.0));
      vec3 rd=normalize((camMat*vec4(rl,0.0)).xyz);
      vec3 pos=camPos; vec3 vel=rd; vec3 color=vec3(0.0); vec3 trans=vec3(1.0);
      bool captured=false;
      for(int i=0;i<STEPS;i++){
        // gravitational deflection summed over holes; capture if inside any horizon
        vec3 accel=vec3(0.0); float minr=MAX_DIST;
        for(int k=0;k<2;k++){
          if(k>=holeCount) break;
          vec3 rv=pos-holePos[k]; float r=length(rv); minr=min(minr,r);
          if(r<holeRs[k]){ captured=true; }
          vec3 h=cross(rv,vel); float h2=dot(h,h);
          accel += -1.5*holeRs[k]*h2*rv/(r*r*r*r*r);
        }
        if(captured) break;
        if(minr>MAX_DIST) break;
        float adj=clamp(minr*0.08,0.06,1.5);
        vec3 nvel=normalize(vel+accel*adj);
        vec3 npos=pos+nvel*adj;
        // every black hole carries its own accretion disc in its equatorial plane
        for(int k=0;k<2;k++){
          if(k>=holeCount) break;
          vec3 pl=pos-holePos[k]; vec3 npl=npos-holePos[k];
          if(sign(pl.y)!=sign(npl.y)||abs(pl.y)<0.25){
            float tc=abs(pl.y)<0.25?0.0:pl.y/(pl.y-npl.y);
            vec4 d=disc(mix(pl,npl,clamp(tc,0.0,1.0)),nvel,holeRs[k]);
            color+=trans*d.rgb; trans*=(1.0-d.a);
          }
        }
        if(dot(trans,vec3(1.0))<0.01) break;
        vel=nvel; pos=npos;
      }
      if(captured){ gl_FragColor=vec4(color,1.0); return; }
      color+=trans*sampleStars(normalize(vel));
      gl_FragColor=vec4(color,1.0);
    }`,
});
const lensScene = new THREE.Scene();
const lensCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
lensScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), lensMaterial));

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
    void main(){ float r=length(vPos); float alpha=smoothstep(60.0,18.0,r)*0.30+0.04;
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
    case 'star': return 0.4 * Math.pow(Math.max(mass, 0.1), 0.22);
    case 'neutron': return 0.09;
    case 'gas-giant': return 0.30;
    case 'planet': return 0.15;
    default: return 0.2;
  }
}
const TYPE_DEFAULTS = {
  star:    { mass: 1.0, color: 0xffe0a0, glow: 0xff8040 },
  neutron: { mass: 1.4, color: 0xcfe8ff, glow: 0x88c4ff },
  'gas-giant': { mass: 9.5e-4, color: 0xd4a574, glow: 0x6a4828 },
  planet:  { mass: 3e-6, color: 0x6a90c0, glow: 0x3a6a9a },
  bh:      { mass: 10, color: 0x000000, glow: 0x000000 },
};

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
  } else {
    b.radius = 0.0001;
  }

  const radiusScene = (spec.type === 'bh')
    ? (b.rs * state.sceneScale)
    : baseRadius(spec.type, mass) * state.bodyScale;
  b.radiusScene = radiusScene;
  b.contactAU = radiusScene / state.sceneScale;
  if (spec.type === 'bh') b.rsScene = radiusScene;

  const palette = spec.palette ? GAS_PALETTES[spec.palette] : null;
  const viz = createBodyVisual(b, {
    radiusScene,
    color: spec.color ?? def.color,
    glow: spec.glow ?? def.glow,
    seed: spec.seed,
    palette, hot: spec.hot, atmosphere: spec.atmosphere, atmColor: spec.atmColor,
    seaLevel: spec.seaLevel, rings: spec.rings, ringColor: spec.ringColor,
  });
  viz.group.userData.bodyId = b.id;
  viz.group.userData.baseScale = 1;
  viz.group.position.copy(b.pos).multiplyScalar(state.sceneScale);
  scene.add(viz.group);

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
  scene.remove(b.viz.group); scene.remove(b.trail);
  b.viz.group.traverse(o => { o.geometry?.dispose?.(); o.material?.dispose?.(); });
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
  // commit visual positions + trails after the sub-steps
  for (const b of state.bodies) {
    b.viz.group.position.copy(b.pos).multiplyScalar(state.sceneScale);
    pushTrail(b);
  }
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
function updateOrbitCam() {
  const { radius, theta, phi } = cam;
  camera.position.set(radius * Math.sin(theta) * Math.cos(phi), radius * Math.cos(theta), radius * Math.sin(theta) * Math.sin(phi)).add(cam.target);
  camera.lookAt(cam.target);
}
function setFollow(body) {
  state.followId = body ? body.id : null;
  state.focusId = body ? body.id : null;
  if (body) {
    cam.target.copy(body.viz.group.position);
    cam.radius = Math.max(body.radiusScene * 6, 4);
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
  } else {
    cam.yaw -= dx * 0.0025; cam.pitch = Math.max(-1.5, Math.min(1.5, cam.pitch - dy * 0.0025));
  }
});
el.addEventListener('wheel', e => {
  e.preventDefault();
  if (state.camMode === 'orbit') { cam.radius = Math.max(0.05, Math.min(20000, cam.radius * (1 + e.deltaY * 0.001))); updateOrbitCam(); }
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
    const hitR = Math.max(b.radiusScene, b.rsScene || 0) * 1.6;
    if (d < hitR && along < bestD) { best = b; bestD = along; }
  }
  if (best) setFollow(best); else setFollow(null);
}

addEventListener('keydown', e => {
  keys[e.code] = true;
  if (e.key === 'r' || e.key === 'R') { cam.target.set(0, 0, 0); cam.radius = state.preset.camRadius; cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2; if (state.camMode === 'orbit') updateOrbitCam(); }
  if (e.code === 'Space') { e.preventDefault(); state.paused = !state.paused; }
  if (e.key === 'f' || e.key === 'F') setCamMode(state.camMode === 'orbit' ? 'free' : 'orbit');
  if ((e.key === 'Delete' || e.key === 'Backspace') && state.focusId != null) removeBody(state.focusId);
});
addEventListener('keyup', e => { keys[e.code] = false; });

function setCamMode(mode) {
  if (mode === 'free' && state.camMode !== 'free') {
    // seed yaw/pitch from current look direction
    const dir = cam.target.clone().sub(camera.position).normalize();
    cam.yaw = Math.atan2(dir.x, dir.z); cam.pitch = Math.asin(THREE.MathUtils.clamp(dir.y, -1, 1));
  }
  state.camMode = mode;
  DOM.camOrbit.classList.toggle('active', mode === 'orbit');
  DOM.camFree.classList.toggle('active', mode === 'free');
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
  state.timeScale = p.timeScale ?? 2;
  state.maxStep = p.maxStep ?? 5e-3;
  state.gwBoost = p.gwBoost ?? 0;
  state.lensing = p.lensing;
  state.showLens = p.lensing;
  state.speed = 1;
  state.consumed = 0;
  state.focusId = state.followId = null;

  for (const spec of p.build()) spawnBody(spec);

  // camera reset
  cam.target.set(0, 0, 0); cam.radius = p.camRadius; cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2;
  setCamMode('orbit'); updateOrbitCam();

  // UI
  DOM.presetName.textContent = p.name;
  DOM.blurb.textContent = p.blurb;
  DOM.massRow.style.display = key === 'sandbox' ? '' : 'none';
  DOM.discRow.style.display = p.lensing ? '' : 'none';
  DOM.tempRow.style.display = p.lensing ? '' : 'none';
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

document.querySelectorAll('[data-spawn]').forEach(btn => btn.addEventListener('click', () => spawnOrbiting(btn.dataset.spawn)));
document.querySelectorAll('[data-preset]').forEach(btn => btn.addEventListener('click', () => loadPreset(btn.dataset.preset)));
document.getElementById('clear').addEventListener('click', clearBodies);
document.getElementById('delFocus').addEventListener('click', () => { if (state.focusId != null) removeBody(state.focusId); });
DOM.camOrbit.addEventListener('click', () => setCamMode('orbit'));
DOM.camFree.addEventListener('click', () => setCamMode('free'));
document.getElementById('resetView').addEventListener('click', () => { setFollow(null); cam.target.set(0, 0, 0); cam.radius = state.preset.camRadius; cam.theta = Math.PI / 2 - 0.35; cam.phi = Math.PI / 2; setCamMode('orbit'); updateOrbitCam(); });

document.querySelectorAll('[data-view]').forEach(btn => btn.addEventListener('click', () => {
  const v = btn.dataset.view;
  if (v === 'mesh') { state.showMesh = !state.showMesh; spacetimeMesh.visible = state.showMesh; btn.classList.toggle('active', state.showMesh); btn.textContent = state.showMesh ? 'Mesh ON' : 'Mesh OFF'; }
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
  lensMaterial.uniforms.resolution.value.set(w * pr, h * pr);
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

  // body visual updates
  const holes = getHoles().map(h => ({ posScene: h.viz.group.position, rsScene: h.rsScene, mass: h.mass }));
  const ctx = { holes, camera, time: state.time, sceneScale: state.sceneScale };
  for (const b of state.bodies) {
    if (b.type === 'bh') { b.rsScene = b.rs * state.sceneScale; b.radiusScene = b.rsScene; }
    b.viz.update(dt * (state.paused ? 0 : 1) + 0.0001, ctx); // keep shaders animating even paused-ish
  }
  // bodies stripped down to nothing are fully consumed
  for (const b of state.bodies.slice()) {
    if (b.type !== 'bh' && b.mass <= 0.012) {
      spawnFlash(b.viz.group.position.clone(), 0xffcaa0, b.radiusScene * 10, 0.7);
      state.consumed++; removeBody(b.id);
    }
  }

  // camera follow / movement
  if (state.camMode === 'free') updateFreeCam(dt);
  else {
    if (state.followId != null) {
      const fb = state.bodies.find(b => b.id === state.followId);
      if (fb) cam.target.lerp(fb.viz.group.position, 0.2);
    }
    updateOrbitCam();
  }

  // light at dominant star/bh
  const lum = state.bodies.find(b => b.type === 'star') || holes[0] && state.bodies.find(b => b.type === 'bh');
  if (lum) sunLight.position.copy(lum.viz.group.position);

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
    const n = Math.min(holes.length, 2);
    for (let i = 0; i < n; i++) {
      lensMaterial.uniforms.holePos.value[i].copy(holes[i].posScene);
      lensMaterial.uniforms.holeRs.value[i] = holes[i].rsScene;
    }
    lensMaterial.uniforms.holeCount.value = n;
    lensMaterial.uniforms.discInner.value = holes[0].rsScene * 3;
    lensMaterial.uniforms.discOuter.value = holes[0].rsScene * 12;
    lensMaterial.uniforms.discIntensity.value = state.discIntensity;
    lensMaterial.uniforms.discTemp.value = state.discTemp;
    lensMaterial.uniforms.camPos.value.copy(camera.position);
    lensMaterial.uniforms.camMat.value.copy(camera.matrixWorld);
    lensMaterial.uniforms.fov.value = camera.fov * Math.PI / 180;
  }

  // render
  if (useLens) {
    renderer.setRenderTarget(sceneTarget); renderer.clear();
    for (const h of getHoles()) h.viz.group.visible = false;
    renderer.render(scene, camera);
    for (const h of getHoles()) h.viz.group.visible = true;
    renderer.setRenderTarget(null); renderer.clear();
    lensMaterial.uniforms.tScene.value = sceneTarget.texture;
    renderer.render(lensScene, lensCam);
    renderer.autoClear = false; renderer.clearDepth();
    scene.background = null; renderer.render(scene, camera); scene.background = starTex; renderer.autoClear = true;
  } else {
    renderer.setRenderTarget(null);
    renderer.render(scene, camera);
  }
}

// ============================================================================
// BOOT
// ============================================================================
resize();
loadPreset(PRESETS[location.hash.slice(1)] ? location.hash.slice(1) : 'sandbox');
addEventListener('hashchange', () => { if (PRESETS[location.hash.slice(1)]) loadPreset(location.hash.slice(1)); });
setTimeout(() => { DOM.loading.classList.add('gone'); animate(); }, 400);
