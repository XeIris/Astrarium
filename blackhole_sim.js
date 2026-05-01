import * as THREE from 'three';

// ============================================================================
// CONSTANTS & STATE
// ============================================================================
const state = {
  mass: 10,
  discIntensity: 0.9,
  discTemp: 0.6,
  showMesh: true,
  showLens: true,
  speed: 1.0,
  paused: false,
  bodies: [],
  consumed: 0,
  nextId: 1,
};

function getRs()   { return state.mass / 10.0; }
function getISCO() { return 3 * getRs(); }

// Cached DOM refs — query once, never again
const DOM = {
  fps:      document.getElementById('fps'),
  rs:       document.getElementById('rs'),
  isco:     document.getElementById('isco'),
  bc:       document.getElementById('bc'),
  cc:       document.getElementById('cc'),
  count:    document.getElementById('count'),
  bodyList: document.getElementById('body-list'),
  loading:  document.getElementById('loading'),
};

// ============================================================================
// SCENE SETUP
// ============================================================================
const scene    = new THREE.Scene();
const camera   = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.1, 2000);
camera.position.set(0, 8, 22);

const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.5));
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setClearColor(0x000000, 1);
document.getElementById('canvas-wrap').appendChild(renderer.domElement);

// ============================================================================
// ORBIT CONTROLS (minimal custom impl)
// ============================================================================
const camState = {
  target: new THREE.Vector3(0, 0, 0),
  radius: 24,
  theta: Math.PI / 2 - 0.35,
  phi: 0,
};
function updateCam() {
  const { radius, theta, phi } = camState;
  const x = radius * Math.sin(theta) * Math.cos(phi);
  const y = radius * Math.cos(theta);
  const z = radius * Math.sin(theta) * Math.sin(phi);
  camera.position.set(x, y, z).add(camState.target);
  camera.lookAt(camState.target);
}
camState.phi = Math.PI / 2;
updateCam();

let dragging = false, lastX = 0, lastY = 0;
renderer.domElement.addEventListener('mousedown', e => { dragging = true; lastX = e.clientX; lastY = e.clientY; });
window.addEventListener('mouseup', () => { dragging = false; });
window.addEventListener('mousemove', e => {
  if (!dragging) return;
  camState.phi   -= (e.clientX - lastX) * 0.005;
  camState.theta  = Math.max(0.1, Math.min(Math.PI - 0.1, camState.theta - (e.clientY - lastY) * 0.005));
  lastX = e.clientX; lastY = e.clientY;
  updateCam();
});
renderer.domElement.addEventListener('wheel', e => {
  e.preventDefault();
  camState.radius = Math.max(3, Math.min(150, camState.radius * (1 + e.deltaY * 0.001)));
  updateCam();
}, { passive: false });
window.addEventListener('keydown', e => {
  if (e.key === 'r' || e.key === 'R') {
    camState.radius = 24; camState.theta = Math.PI / 2 - 0.35; camState.phi = Math.PI / 2;
    camState.target.set(0, 0, 0);
    updateCam();
  }
  if (e.code === 'Space') { e.preventDefault(); state.paused = !state.paused; }
});

// ============================================================================
// STARFIELD — equirectangular canvas texture (1024×512, 5k stars)
// ============================================================================
function makeStarTexture(size = 1024) {
  const c = document.createElement('canvas');
  c.width = size; c.height = size / 2;
  const ctx = c.getContext('2d');

  const g = ctx.createLinearGradient(0, 0, 0, c.height);
  g.addColorStop(0,   '#02030a');
  g.addColorStop(0.5, '#060418');
  g.addColorStop(1,   '#02030a');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, c.width, c.height);

  for (let i = 0; i < 12; i++) {
    const x = Math.random() * c.width;
    const y = Math.random() * c.height;
    const r = 80 + Math.random() * 200;
    const rg  = ctx.createRadialGradient(x, y, 0, x, y, r);
    const hue = 200 + Math.random() * 60;
    rg.addColorStop(0, `hsla(${hue},70%,40%,0.12)`);
    rg.addColorStop(1, 'hsla(0,0%,0%,0)');
    ctx.fillStyle = rg;
    ctx.fillRect(0, 0, c.width, c.height);
  }

  for (let i = 0; i < 5000; i++) {
    const x  = Math.random() * c.width;
    const y  = Math.random() * c.height;
    const sz = Math.pow(Math.random(), 10) * 3 + 0.3;
    const b  = 0.5 + Math.random() * 0.5;
    const t  = Math.random();
    ctx.fillStyle = t < 0.7  ? `rgba(255,255,255,${b})`
                  : t < 0.85 ? `rgba(200,220,255,${b})`
                  : t < 0.95 ? `rgba(255,230,200,${b})`
                  :             `rgba(255,180,180,${b})`;
    ctx.beginPath();
    ctx.arc(x, y, sz, 0, Math.PI * 2);
    ctx.fill();
  }

  const tex = new THREE.CanvasTexture(c);
  tex.mapping    = THREE.EquirectangularReflectionMapping;
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}
const starTex = makeStarTexture();
scene.background = starTex;

// ============================================================================
// BLACK HOLE LENSING SHADER
// ============================================================================
const lensMaterial = new THREE.ShaderMaterial({
  uniforms: {
    tScene:        { value: null },
    tStars:        { value: starTex },
    resolution:    { value: new THREE.Vector2() },
    bhPos:         { value: new THREE.Vector3() },
    camPos:        { value: new THREE.Vector3() },
    camMat:        { value: new THREE.Matrix4() },
    fov:           { value: 50 * Math.PI / 180 },
    aspect:        { value: 1 },
    rs:            { value: 1.0 },
    discInner:     { value: 3.0 },
    discOuter:     { value: 12.0 },
    discIntensity: { value: 0.9 },
    discTemp:      { value: 0.6 },
    time:          { value: 0 },
    enabled:       { value: 1.0 },
  },
  vertexShader: `
    varying vec2 vUv;
    void main() {
      vUv = uv;
      gl_Position = vec4(position.xy, 0.0, 1.0);
    }
  `,
  fragmentShader: `
    precision highp float;
    varying vec2 vUv;
    uniform sampler2D tScene;
    uniform sampler2D tStars;
    uniform vec2 resolution;
    uniform vec3 bhPos;
    uniform vec3 camPos;
    uniform mat4 camMat;
    uniform float fov;
    uniform float aspect;
    uniform float rs;
    uniform float discInner;
    uniform float discOuter;
    uniform float discIntensity;
    uniform float discTemp;
    uniform float time;
    uniform float enabled;

    #define PI 3.14159265359
    #define STEPS 150
    #define MAX_DIST 200.0

    vec3 sampleStars(vec3 dir) {
      float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
      float v = asin(clamp(dir.y, -1.0, 1.0)) / PI + 0.5;
      return texture2D(tStars, vec2(u, v)).rgb;
    }

    float hash(vec2 p) {
      return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
    }
    float noise(vec2 p) {
      vec2 i = floor(p), f = fract(p);
      vec2 u = f * f * (3.0 - 2.0 * f);
      return mix(mix(hash(i),           hash(i + vec2(1,0)), u.x),
                 mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), u.x), u.y);
    }
    float fbm(vec2 p) {
      float v = 0.0, a = 0.5;
      for (int i = 0; i < 4; i++) { v += a * noise(p); p *= 2.1; a *= 0.5; }
      return v;
    }

    vec3 bbColor(float t) {
      vec3 cold = vec3(1.0, 0.15, 0.02);
      vec3 mid  = vec3(1.0, 0.6,  0.15);
      vec3 hot  = vec3(0.85, 0.92, 1.2);
      if (t < 0.5) return mix(cold, mid, t * 2.0);
      return mix(mid, hot, (t - 0.5) * 2.0);
    }

    vec4 sampleDisc(vec3 p, vec3 rayDir) {
      float r = length(p.xz);
      if (p.y > 0.25 || p.y < -0.25) return vec4(0.0);
      if (r < discInner || r > discOuter) return vec4(0.0);

      float thick  = exp(-p.y * p.y * 25.0);
      float rn     = (r - discInner) / (discOuter - discInner);
      float bright = pow(1.0 - rn, 2.0) + 0.1;

      float ang     = atan(p.z, p.x);
      vec2  uv      = vec2(r * 0.6, ang * 3.5 + r * 0.3 - time * 0.8 / max(r * 0.3, 0.5));
      float n       = fbm(uv) * 0.7 + 0.3;
      float streaks = pow(abs(sin(ang * 8.0 + r * 2.0 - time * 2.0 / max(r, 1.0))), 4.0) * 0.3;
      float density = n + streaks;

      float temp = mix(0.2, 1.0, (1.0 - rn) * discTemp + 0.3);
      vec3  col  = bbColor(temp);

      vec3  vel   = normalize(vec3(-p.z, 0.0, p.x));
      float beta  = clamp(sqrt(rs / (2.0 * r)), 0.0, 0.85);
      float cosTh = dot(vel, -rayDir);
      float doppler      = 1.0 / (1.0 - beta * cosTh);
      float dopplerBoost = pow(doppler, 3.5);
      col *= dopplerBoost;

      float grsh = sqrt(max(1.0 - rs / max(r, rs * 1.01), 0.0));
      col *= mix(vec3(1.0, 0.6, 0.3), vec3(1.0), grsh);

      float alpha = density * thick * bright * discIntensity;
      return vec4(col * alpha, clamp(alpha, 0.0, 1.0));
    }

    void main() {
      vec2  ndc      = vUv * 2.0 - 1.0;
      ndc.x         *= aspect;
      float f        = tan(fov * 0.5);
      vec3  rayLocal = normalize(vec3(ndc.x * f, ndc.y * f, -1.0));
      vec3  rayDir   = normalize((camMat * vec4(rayLocal, 0.0)).xyz);
      vec3  rayPos   = camPos - bhPos;

      vec3 color        = vec3(0.0);
      vec3 transmittance = vec3(1.0);

      if (enabled < 0.5) {
        vec3 starCol = sampleStars(rayDir);
        for (int i = 0; i < 80; i++) {
          float t = float(i) * 0.5;
          vec3  p = rayPos + rayDir * t;
          if (length(p) < rs)       { gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0); return; }
          if (length(p) > MAX_DIST) break;
          vec4 d = sampleDisc(p, rayDir);
          color         += transmittance * d.rgb * 0.5;
          transmittance *= (1.0 - d.a * 0.5);
        }
        color += transmittance * starCol;
        gl_FragColor = vec4(color, 1.0);
        return;
      }

      vec3 vel      = rayDir;
      bool captured = false;

      for (int i = 0; i < STEPS; i++) {
        float r = length(rayPos);
        if (r < rs)        { captured = true; break; }
        if (r > MAX_DIST)  break;

        float adj = clamp(r * 0.08, 0.08, 1.5);

        vec3  h      = cross(rayPos, vel);
        float h2     = dot(h, h);
        vec3  accel  = -1.5 * rs * h2 * rayPos / (r * r * r * r * r);

        vel  = normalize(vel + accel * adj);

        vec3 newPos = rayPos + vel * adj;

        if (sign(rayPos.y) != sign(newPos.y) || abs(rayPos.y) < 0.2) {
          float tCross = abs(rayPos.y) < 0.2 ? 0.0 : rayPos.y / (rayPos.y - newPos.y);
          vec3  crossP = mix(rayPos, newPos, clamp(tCross, 0.0, 1.0));
          vec4  d      = sampleDisc(crossP, vel);
          color         += transmittance * d.rgb;
          transmittance *= (1.0 - d.a);
          if (dot(transmittance, vec3(1.0)) < 0.01) break;
        }

        rayPos = newPos;
      }

      if (captured) {
        gl_FragColor = vec4(color, 1.0);
        return;
      }

      color += transmittance * sampleStars(normalize(vel));
      gl_FragColor = vec4(color, 1.0);
    }
  `,
});

const lensGeo  = new THREE.PlaneGeometry(2, 2);
const lensMesh = new THREE.Mesh(lensGeo, lensMaterial);
const lensScene = new THREE.Scene();
const lensCam   = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
lensScene.add(lensMesh);

// ============================================================================
// SPACETIME MESH
// ============================================================================
const MESH_SIZE = 80;
const MESH_SEG  = 100;
const meshGeo   = new THREE.PlaneGeometry(MESH_SIZE, MESH_SIZE, MESH_SEG, MESH_SEG);
meshGeo.rotateX(-Math.PI / 2);
const meshMat = new THREE.ShaderMaterial({
  uniforms: {
    rs:        { value: 1.0 },
    time:      { value: 0 },
    bodies:    { value: new Array(16).fill(0).map(() => new THREE.Vector4()) },
    bodyCount: { value: 0 },
  },
  transparent: true,
  wireframe: true,
  vertexShader: `
    uniform float rs;
    uniform float time;
    uniform vec4 bodies[16];
    uniform int bodyCount;
    varying float vDepth;
    varying vec2 vPos;
    void main() {
      vec3 p = position;
      vPos = p.xz;
      float r = length(p.xz);
      float R_far   = 40.0;
      float max_dip = 2.5 * sqrt(rs * max(R_far - rs * 0.999, 0.1));
      float dip = r > rs
        ? max_dip - 2.5 * sqrt(rs * max(r - rs * 0.999, 0.0))
        : max_dip + (rs - r) * 3.0;
      p.y -= dip;
      for (int i = 0; i < 16; i++) {
        if (i >= bodyCount) break;
        float d = distance(vec2(p.x, p.z), bodies[i].xz);
        p.y -= bodies[i].w * 0.8 / (d + 0.5);
      }
      vDepth = -p.y;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
    }
  `,
  fragmentShader: `
    varying float vDepth;
    varying vec2 vPos;
    uniform float time;
    void main() {
      float r         = length(vPos);
      float alpha     = smoothstep(40.0, 15.0, r) * 0.35 + 0.05;
      float intensity = clamp(vDepth * 0.08 + 0.1, 0.0, 1.0);
      vec3  cool      = vec3(0.2, 0.35, 0.6);
      vec3  warm      = vec3(0.8, 0.4, 0.15);
      gl_FragColor    = vec4(mix(cool, warm, intensity), alpha);
    }
  `,
});
const spacetimeMesh = new THREE.Mesh(meshGeo, meshMat);
spacetimeMesh.position.y = -5;
scene.add(spacetimeMesh);

const bhGeo    = new THREE.SphereGeometry(1, 32, 32);
const bhMat    = new THREE.MeshBasicMaterial({ color: 0x000000 });
const bhMarker = new THREE.Mesh(bhGeo, bhMat);
scene.add(bhMarker);

const iscoRingGeo = new THREE.RingGeometry(2.99, 3.01, 128);
iscoRingGeo.rotateX(-Math.PI / 2);
const iscoRingMat = new THREE.MeshBasicMaterial({ color: 0xff8c42, side: THREE.DoubleSide, transparent: true, opacity: 0.3 });
const iscoRing    = new THREE.Mesh(iscoRingGeo, iscoRingMat);
scene.add(iscoRing);

// ============================================================================
// BODIES
// ============================================================================
const bodyTypes = {
  'planet-s': { name: 'PLANET',    radius: 0.12, mass: 0.05, color: 0x4a90e2, glow: 0x1a3050 },
  'planet-l': { name: 'GAS GIANT', radius: 0.28, mass: 0.3,  color: 0xd4a574, glow: 0x5a3820 },
  'star':     { name: 'STAR',      radius: 0.45, mass: 2.0,  color: 0xffe0a0, glow: 0xff8040, emissive: true },
  'neutron':  { name: 'NEUTRON',   radius: 0.08, mass: 1.5,  color: 0xc8e0ff, glow: 0x80c0ff, emissive: true, pulsar: true },
};

function addBody(typeKey) {
  const t = bodyTypes[typeKey];
  if (!t) return;

  const orbitR = 6 + Math.random() * 12;
  const theta  = Math.random() * Math.PI * 2;
  const y      = (Math.random() - 0.5) * 1.5;

  const group = new THREE.Group();

  const geo = new THREE.SphereGeometry(t.radius, 24, 24);
  const mat = t.emissive
    ? new THREE.MeshBasicMaterial({ color: t.color })
    : new THREE.MeshStandardMaterial({ color: t.color, emissive: t.glow, emissiveIntensity: 0.2, roughness: 0.8 });
  group.add(new THREE.Mesh(geo, mat));

  const glowCanvas = document.createElement('canvas');
  glowCanvas.width = 128; glowCanvas.height = 128;
  const gctx = glowCanvas.getContext('2d');
  const grad  = gctx.createRadialGradient(64, 64, 0, 64, 64, 64);
  const colHex = '#' + t.glow.toString(16).padStart(6, '0');
  grad.addColorStop(0,   colHex + 'cc');
  grad.addColorStop(0.5, colHex + '44');
  grad.addColorStop(1,   colHex + '00');
  gctx.fillStyle = grad;
  gctx.fillRect(0, 0, 128, 128);
  const spriteMat = new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(glowCanvas), blending: THREE.AdditiveBlending, transparent: true, depthWrite: false });
  const sprite    = new THREE.Sprite(spriteMat);
  sprite.scale.set(t.radius * 5, t.radius * 5, 1);
  group.add(sprite);

  const trailMax = 200;
  const trailGeo = new THREE.BufferGeometry();
  trailGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(trailMax * 3), 3));
  const trailMat = new THREE.LineBasicMaterial({ color: t.color, transparent: true, opacity: 0.3, blending: THREE.AdditiveBlending });
  const trail    = new THREE.Line(trailGeo, trailMat);
  scene.add(trail);
  scene.add(group);

  const pos = new THREE.Vector3(Math.cos(theta) * orbitR, y, Math.sin(theta) * orbitR);
  group.position.copy(pos);

  const rs  = getRs();
  const v   = Math.sqrt(rs / orbitR) * 2.5;
  const vel = new THREE.Vector3(-Math.sin(theta), (Math.random() - 0.5) * v * 0.1, Math.cos(theta)).multiplyScalar(v);

  const mesh = group.children[0];

  state.bodies.push({
    id:          state.nextId++,
    type:        typeKey,
    typeName:    t.name,
    group, mesh, sprite, trail,
    trailBuf:    new Float32Array(trailMax * 3),
    trailHead:   0,
    trailCount:  0,
    trailMax,
    pos:         pos.clone(),
    vel:         vel.clone(),
    mass:        t.mass,
    radius:      t.radius,
    alive:       true,
    pulsar:      t.pulsar || false,
    pulsarPhase: Math.random() * Math.PI * 2,
    color:       t.color,
  });

  updateBodyList();
  updateReadout();
}

function removeBody(id) {
  const idx = state.bodies.findIndex(b => b.id === id);
  if (idx < 0) return;
  const b = state.bodies[idx];
  scene.remove(b.group);
  scene.remove(b.trail);
  b.mesh.geometry.dispose();
  b.trail.geometry.dispose();
  state.bodies.splice(idx, 1);
  updateBodyList();
  updateReadout();
}

function clearBodies() {
  while (state.bodies.length) removeBody(state.bodies[0].id);
  state.consumed = 0;
  updateReadout();
}

const ambient  = new THREE.AmbientLight(0x202030, 0.4);
const bhLight  = new THREE.PointLight(0xff8c42, 3, 60, 1.5);
scene.add(ambient);
scene.add(bhLight);

// ============================================================================
// PHYSICS — zero-allocation hot path
// ============================================================================
const _physAccel = new THREE.Vector3();

function stepPhysics(dt) {
  const rs = getRs();
  const GM = rs / 2 * 6.25;

  for (const b of state.bodies) {
    const r = b.pos.length();

    if (r < rs * 1.1 + b.radius) { state.consumed++; b.alive = false; continue; }

    const denom = r - rs;
    if (denom < 0.01) { state.consumed++; b.alive = false; continue; }

    // Paczynski-Wiita potential: a = -GM / (r-rs)^2 * r̂
    _physAccel.copy(b.pos).normalize().multiplyScalar(-GM / (denom * denom));
    b.vel.addScaledVector(_physAccel, dt);
    b.pos.addScaledVector(b.vel, dt);
    b.group.position.copy(b.pos);

    // circular buffer trail — no Array.splice, no GC
    const h = b.trailHead;
    b.trailBuf[h * 3]     = b.pos.x;
    b.trailBuf[h * 3 + 1] = b.pos.y;
    b.trailBuf[h * 3 + 2] = b.pos.z;
    b.trailHead  = (h + 1) % b.trailMax;
    b.trailCount = Math.min(b.trailCount + 1, b.trailMax);

    const tp      = b.trail.geometry.attributes.position.array;
    const oldest  = (b.trailHead - b.trailCount + b.trailMax) % b.trailMax;
    const firstSeg = b.trailMax - oldest;
    if (b.trailCount <= firstSeg) {
      tp.set(b.trailBuf.subarray(oldest * 3, (oldest + b.trailCount) * 3), 0);
    } else {
      tp.set(b.trailBuf.subarray(oldest * 3), 0);
      tp.set(b.trailBuf.subarray(0, (b.trailCount - firstSeg) * 3), firstSeg * 3);
    }
    b.trail.geometry.setDrawRange(0, b.trailCount);
    b.trail.geometry.attributes.position.needsUpdate = true;

    if (b.pulsar) {
      b.pulsarPhase += dt * 8;
      const blink = 0.5 + 0.5 * Math.pow(Math.max(0, Math.sin(b.pulsarPhase)), 6);
      b.sprite.material.opacity          = 0.5 + blink * 0.5;
      b.mesh.material.color.setScalar(0.8 + blink * 0.4);
    }
  }

  const dead = state.bodies.filter(b => !b.alive);
  for (const b of dead) removeBody(b.id);
}

// ============================================================================
// RENDER TARGET + RESIZE
// ============================================================================
const sceneTarget = new THREE.WebGLRenderTarget(1, 1, {
  type:      THREE.HalfFloatType,
  minFilter: THREE.LinearFilter,
  magFilter: THREE.LinearFilter,
});

function resize() {
  const w = window.innerWidth, h = window.innerHeight;
  renderer.setSize(w, h);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  const pr = renderer.getPixelRatio();
  sceneTarget.setSize(w * pr, h * pr);
  lensMaterial.uniforms.resolution.value.set(w * pr, h * pr);
  lensMaterial.uniforms.aspect.value = w / h;
  lensMaterial.uniforms.fov.value    = camera.fov * Math.PI / 180;
}
window.addEventListener('resize', resize);
resize();

// ============================================================================
// UI WIRING
// ============================================================================
function updateBodyList() {
  if (state.bodies.length === 0) {
    DOM.bodyList.innerHTML = '<div class="empty">— none in orbit —</div>';
  } else {
    DOM.bodyList.innerHTML = state.bodies.map(b =>
      `<div class="body-item"><span><span class="type">#${b.id} ${b.typeName}</span></span><button class="rm" data-rm="${b.id}">✕</button></div>`
    ).join('');
    DOM.bodyList.querySelectorAll('[data-rm]').forEach(btn => {
      btn.addEventListener('click', () => removeBody(parseInt(btn.dataset.rm)));
    });
  }
  DOM.count.textContent = `(${state.bodies.length})`;
}

function updateReadout() {
  DOM.rs.textContent   = getRs().toFixed(2);
  DOM.isco.textContent = getISCO().toFixed(2);
  DOM.bc.textContent   = state.bodies.length;
  DOM.cc.textContent   = state.consumed;
}

const bindSlider = (id, key, fmt = v => v.toFixed(2)) => {
  const el  = document.getElementById(id);
  const val = document.getElementById(id + '-val');
  el.addEventListener('input', () => {
    state[key]    = parseFloat(el.value);
    val.textContent = fmt(state[key]);
    if (key === 'mass') updateReadout();
  });
};
bindSlider('mass',  'mass',         v => v.toFixed(1));
bindSlider('disc',  'discIntensity');
bindSlider('temp',  'discTemp');
bindSlider('speed', 'speed');

document.querySelectorAll('[data-spawn]').forEach(btn => {
  btn.addEventListener('click', () => addBody(btn.dataset.spawn));
});
document.getElementById('clear').addEventListener('click', clearBodies);

document.querySelectorAll('[data-view]').forEach(btn => {
  btn.addEventListener('click', () => {
    const view = btn.dataset.view;
    if (view === 'mesh') {
      state.showMesh = !state.showMesh;
      btn.classList.toggle('active', state.showMesh);
      btn.textContent = state.showMesh ? 'Mesh ON' : 'Mesh OFF';
      spacetimeMesh.visible = state.showMesh;
      iscoRing.visible      = state.showMesh;
    } else if (view === 'lens') {
      state.showLens = !state.showLens;
      btn.classList.toggle('active', state.showLens);
      btn.textContent = state.showLens ? 'Lens ON' : 'Lens OFF';
    }
  });
});

updateBodyList();
updateReadout();
addBody('planet-l');
addBody('star');

// ============================================================================
// ANIMATION LOOP
// ============================================================================
let lastT = performance.now();
let fpsAcc = 0, fpsCount = 0, fpsTime = 0;

function animate() {
  requestAnimationFrame(animate);
  const now  = performance.now();
  let   dt   = (now - lastT) / 1000;
  lastT = now;
  dt = Math.min(dt, 0.05);
  const simDt = state.paused ? 0 : dt * state.speed;

  fpsAcc  += 1 / dt; fpsCount++; fpsTime += dt;
  if (fpsTime > 0.5) {
    DOM.fps.textContent = Math.round(fpsAcc / fpsCount);
    fpsAcc = 0; fpsCount = 0; fpsTime = 0;
  }

  stepPhysics(simDt);

  const rs = getRs();
  bhMarker.scale.setScalar(rs);
  iscoRing.scale.setScalar(getISCO() / 3);
  meshMat.uniforms.rs.value    = rs;
  meshMat.uniforms.time.value += simDt;
  bhLight.intensity = rs * 0.8 + 1.5;

  const bodyArr = meshMat.uniforms.bodies.value;
  const n = Math.min(state.bodies.length, 16);
  for (let i = 0; i < n; i++) {
    bodyArr[i].set(state.bodies[i].pos.x, 0, state.bodies[i].pos.z, state.bodies[i].mass);
  }
  meshMat.uniforms.bodyCount.value = n;

  lensMaterial.uniforms.rs.value            = rs;
  lensMaterial.uniforms.discInner.value      = 3.0 * rs;
  lensMaterial.uniforms.discOuter.value      = 12.0 * rs;
  lensMaterial.uniforms.discIntensity.value  = state.discIntensity;
  lensMaterial.uniforms.discTemp.value       = state.discTemp;
  lensMaterial.uniforms.time.value          += simDt;
  lensMaterial.uniforms.camPos.value.copy(camera.position);
  lensMaterial.uniforms.camMat.value.copy(camera.matrixWorld);
  lensMaterial.uniforms.enabled.value        = state.showLens ? 1.0 : 0.0;

  renderer.setRenderTarget(sceneTarget);
  renderer.clear();
  bhMarker.visible = !state.showLens;
  renderer.render(scene, camera);

  renderer.setRenderTarget(null);
  renderer.clear();
  if (state.showLens) {
    lensMaterial.uniforms.tScene.value = sceneTarget.texture;
    renderer.render(lensScene, lensCam);
    renderer.autoClear = false;
    renderer.clearDepth();
    scene.background = null;
    renderer.render(scene, camera);
    scene.background  = starTex;
    renderer.autoClear = true;
  } else {
    renderer.render(scene, camera);
  }
}

setTimeout(() => {
  DOM.loading.classList.add('gone');
  animate();
}, 400);
