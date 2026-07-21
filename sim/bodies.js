import * as THREE from 'three';
import { rockyTexture, gasGiantTexture, GAS_PALETTES } from './textures.js';

// ============================================================================
// BODY VISUALS — each factory builds a THREE.Group and attaches an
// `update(dt, ctx)` closure to b.viz. ctx = { holes, camera, time, sceneScale }.
// Rendered radii are in SCENE units (visually exaggerated); physical radii in
// AU live on the body for collisions/physics.
// ============================================================================

function hex(n) { return '#' + n.toString(16).padStart(6, '0'); }

// Radial-gradient sprite (corona / glow / flare).
function glowSprite(colorHex, stops) {
  const s = 128, cv = document.createElement('canvas'); cv.width = cv.height = s;
  const g = cv.getContext('2d');
  const rg = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
  (stops || [[0, 'ff'], [0.4, '66'], [1, '00']]).forEach(([p, a]) => rg.addColorStop(p, hex(colorHex) + a));
  g.fillStyle = rg; g.fillRect(0, 0, s, s);
  const m = new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(cv), blending: THREE.AdditiveBlending, transparent: true, depthWrite: false });
  return new THREE.Sprite(m);
}

// ---------------------------------------------------------------------------
// STAR surface shader: granulation fBm + limb darkening + flicker.
// ---------------------------------------------------------------------------
function starMaterial(colorHex) {
  const col = new THREE.Color(colorHex);
  return new THREE.ShaderMaterial({
    uniforms: { uTime: { value: 0 }, uColor: { value: col }, uPulse: { value: 1 } },
    vertexShader: `
      varying vec3 vN; varying vec3 vPos;
      void main(){ vN = normalize(normalMatrix * normal); vPos = position;
        gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }`,
    fragmentShader: `
      precision highp float;
      uniform float uTime; uniform vec3 uColor; uniform float uPulse;
      varying vec3 vN; varying vec3 vPos;
      float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1,113.5,7.9)))*43758.5); }
      float noise(vec3 p){ vec3 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
        float n=mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),
                    mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z);
        return n; }
      float fbm(vec3 p){ float v=0.0,a=0.5; for(int i=0;i<5;i++){v+=a*noise(p);p*=2.05;a*=0.5;} return v; }
      void main(){
        vec3 p = normalize(vPos);
        float gran = fbm(p*7.0 + uTime*0.15);
        float cells = fbm(p*16.0 - uTime*0.25);
        float bright = 0.55 + gran*0.7 + cells*0.25;
        // dark sunspots
        float spot = smoothstep(0.62,0.5, fbm(p*4.0+vec3(3.0)+uTime*0.02));
        bright *= mix(1.0, 0.45, spot);
        vec3 base = uColor * bright * uPulse;
        // hot specks
        base += vec3(1.0,0.85,0.5) * pow(max(cells-0.55,0.0),2.0)*1.5;
        // limb darkening
        float limb = pow(max(dot(vN, vec3(0.0,0.0,1.0)),0.0),0.55);
        base *= mix(0.55,1.15, limb);
        gl_FragColor = vec4(base, 1.0);
      }`,
  });
}

function createStar(b, opts) {
  const g = new THREE.Group();
  const R = opts.radiusScene;
  const colorHex = opts.color;

  const mat = starMaterial(colorHex);
  const core = new THREE.Mesh(new THREE.SphereGeometry(R, 48, 48), mat);
  g.add(core);

  // gassy outer layer — slightly larger, additive, semi-transparent
  const layerMat = mat.clone(); layerMat.transparent = true; layerMat.blending = THREE.AdditiveBlending; layerMat.depthWrite = false;
  layerMat.uniforms = THREE.UniformsUtils.clone(mat.uniforms);
  layerMat.uniforms.uColor.value = new THREE.Color(colorHex);
  const layer = new THREE.Mesh(new THREE.SphereGeometry(R * 1.08, 32, 32), layerMat);
  layer.material.opacity = 0.25; g.add(layer);

  const corona = glowSprite(opts.glow, [[0, '88'], [0.3, '40'], [1, '00']]);
  corona.scale.setScalar(R * 6); g.add(corona);

  // prominences / flares: a few flame sprites that wax & wane
  const flares = [];
  for (let i = 0; i < 4; i++) {
    const f = glowSprite(opts.glow, [[0, 'cc'], [0.5, '30'], [1, '00']]);
    const a = Math.random() * Math.PI * 2;
    f.position.set(Math.cos(a) * R, Math.sin(a) * R * 0.6, (Math.random() - 0.5) * R);
    f.scale.setScalar(R * 1.5); f.userData = { phase: Math.random() * 6.28, a };
    g.add(f); flares.push(f);
  }

  const stream = new AccretionStream(opts.glow);
  g.add(stream.points);

  b.viz = { group: g, core, mat, layer, corona, flares, stream, baseR: R, R, colorHex };
  b.viz.update = (dt, ctx) => {
    mat.uniforms.uTime.value += dt;
    layer.material.uniforms.uTime.value += dt * 0.6;
    // slow swelling pulsation (stellar variability)
    const pulse = 1 + Math.sin(ctx.time * 0.6 + b.id) * 0.04;
    core.scale.setScalar(pulse); layer.scale.setScalar(pulse);
    mat.uniforms.uPulse.value = 0.9 + Math.sin(ctx.time * 4 + b.id) * 0.04;
    corona.material.opacity = 0.8 + Math.sin(ctx.time * 1.3 + b.id) * 0.15;
    for (const f of flares) {
      const e = 0.4 + 0.6 * Math.pow(Math.max(0, Math.sin(ctx.time * 1.1 + f.userData.phase)), 3);
      f.material.opacity = e; f.scale.setScalar(R * (1.0 + e * 1.2));
    }
    accrete(b, ctx, stream, dt);
  };
  return b.viz;
}

// ---------------------------------------------------------------------------
// NEUTRON STAR — tiny, brilliant, fast axial spin + lighthouse pulsar beams.
// ---------------------------------------------------------------------------
function createNeutron(b, opts) {
  const g = new THREE.Group();
  const R = opts.radiusScene;
  const mat = new THREE.MeshBasicMaterial({ color: 0xdff0ff });
  const core = new THREE.Mesh(new THREE.SphereGeometry(R, 24, 24), mat);
  g.add(core);
  const halo = glowSprite(0x99ccff, [[0, 'ff'], [0.25, '55'], [1, '00']]);
  halo.scale.setScalar(R * 10); g.add(halo);

  // spin + tilted magnetic axis carrying two opposed beams
  const spinAxis = new THREE.Group();
  g.add(spinAxis);
  const magAxis = new THREE.Group();
  magAxis.rotation.z = 0.5 + Math.random() * 0.6;  // misaligned dipole
  spinAxis.add(magAxis);
  const beamMat = new THREE.MeshBasicMaterial({ color: 0xbfe3ff, transparent: true, opacity: 0.35, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
  const beamLen = R * 28;
  for (const s of [1, -1]) {
    const cone = new THREE.Mesh(new THREE.ConeGeometry(beamLen * 0.18, beamLen, 20, 1, true), beamMat);
    cone.position.y = s * beamLen / 2; cone.rotation.x = s > 0 ? 0 : Math.PI;
    magAxis.add(cone);
  }

  const stream = new AccretionStream(0x99ccff);
  g.add(stream.points);

  b.viz = { group: g, core, halo, spinAxis, magAxis, stream, baseR: R, R };
  b.spin = b.spin ?? (8 + Math.random() * 20);  // rad/s (pulsar period exaggerated)
  b.viz.update = (dt, ctx) => {
    spinAxis.rotation.y += b.spin * dt;
    // lighthouse: brightness peaks when a beam sweeps toward the camera
    const beamDir = new THREE.Vector3(0, 1, 0).applyQuaternion(magAxis.getWorldQuaternion(new THREE.Quaternion()));
    const toCam = ctx.camera.position.clone().sub(g.getWorldPosition(new THREE.Vector3())).normalize();
    const align = Math.abs(beamDir.dot(toCam));
    const flash = Math.pow(align, 8);
    halo.material.opacity = 0.5 + flash * 1.2;
    core.material.color.setScalar(0.85 + flash * 0.6);
    beamMat.opacity = 0.18 + flash * 0.4;
    accrete(b, ctx, stream, dt);
  };
  return b.viz;
}

// ---------------------------------------------------------------------------
// PLANETS — procedurally textured, with a thin atmospheric rim for rocky worlds
// and a soft haze for gas giants.
// ---------------------------------------------------------------------------
function createPlanet(b, opts) {
  const g = new THREE.Group();
  const R = opts.radiusScene;
  const seed = (b.id * 2654435761) >>> 0 ^ (opts.seed || 0);
  let tex, rim;
  if (opts.gas) {
    tex = gasGiantTexture(seed, opts.palette || GAS_PALETTES.jupiter);
    const mat = new THREE.MeshStandardMaterial({ map: tex, roughness: 1, metalness: 0, emissive: new THREE.Color(opts.glow).multiplyScalar(0.04) });
    g.add(new THREE.Mesh(new THREE.SphereGeometry(R, 48, 48), mat));
    // haze shell
    const haze = new THREE.Mesh(new THREE.SphereGeometry(R * 1.03, 32, 32),
      new THREE.MeshBasicMaterial({ color: opts.glow, transparent: true, opacity: 0.12, blending: THREE.AdditiveBlending, side: THREE.BackSide, depthWrite: false }));
    g.add(haze);
    if (opts.rings) g.add(makeRings(R, opts.ringColor || 0xcdbb99));
  } else {
    tex = rockyTexture(seed, { hot: opts.hot, seaLevel: opts.seaLevel });
    const mat = new THREE.MeshStandardMaterial({ map: tex, roughness: 0.95, metalness: 0.02 });
    g.add(new THREE.Mesh(new THREE.SphereGeometry(R, 48, 48), mat));
    if (opts.atmosphere) {
      rim = new THREE.Mesh(new THREE.SphereGeometry(R * 1.025, 32, 32),
        new THREE.MeshBasicMaterial({ color: opts.atmColor || 0x6aa6ff, transparent: true, opacity: 0.18, blending: THREE.AdditiveBlending, side: THREE.BackSide, depthWrite: false }));
      g.add(rim);
    }
  }
  const core = g.children[0];
  const stream = new AccretionStream(opts.glow || 0x886644);
  g.add(stream.points);

  b.viz = { group: g, core, baseR: R, R };
  b.spin = b.spin ?? (0.4 + Math.random() * 1.2) * (Math.random() < 0.1 ? -1 : 1);
  b.viz.update = (dt, ctx) => { core.rotation.y += b.spin * dt; accrete(b, ctx, stream, dt); };
  return b.viz;
}

function makeRings(R, colorHex) {
  const geo = new THREE.RingGeometry(R * 1.4, R * 2.3, 96);
  geo.rotateX(-Math.PI / 2 + 0.25);
  const m = new THREE.MeshBasicMaterial({ color: colorHex, side: THREE.DoubleSide, transparent: true, opacity: 0.55 });
  return new THREE.Mesh(geo, m);
}

// ---------------------------------------------------------------------------
// BLACK HOLE marker (the lensing/disc is drawn by the screen-space shader).
// ---------------------------------------------------------------------------
function createBlackHole(b, opts) {
  const g = new THREE.Group();
  const core = new THREE.Mesh(new THREE.SphereGeometry(1, 32, 32), new THREE.MeshBasicMaterial({ color: 0x000000 }));
  g.add(core);
  b.viz = { group: g, core, baseR: 1, R: 1, isHole: true };
  b.viz.update = (dt, ctx) => { core.scale.setScalar(b.rsScene || 1); };
  return b.viz;
}

// ---------------------------------------------------------------------------
// ACCRETION STREAM — a GPU point pool. When a body is inside a hole's tidal
// radius it sheds particles that spiral toward the hole, and visibly loses
// mass (mass + rendered radius shrink).
// ---------------------------------------------------------------------------
class AccretionStream {
  constructor(colorHex) {
    this.max = 240; this.head = 0;
    const geo = new THREE.BufferGeometry();
    this.posArr = new Float32Array(this.max * 3);
    this.velArr = new Float32Array(this.max * 3);
    this.lifeArr = new Float32Array(this.max);
    geo.setAttribute('position', new THREE.BufferAttribute(this.posArr, 3));
    const aArr = new Float32Array(this.max); geo.setAttribute('alpha', new THREE.BufferAttribute(aArr, 1));
    this.alphaArr = aArr;
    const mat = new THREE.ShaderMaterial({
      uniforms: { uColor: { value: new THREE.Color(colorHex) }, uSize: { value: 60 } },
      transparent: true, blending: THREE.AdditiveBlending, depthWrite: false,
      vertexShader: `attribute float alpha; varying float vA; uniform float uSize;
        void main(){ vA=alpha; vec4 mv=modelViewMatrix*vec4(position,1.0);
          gl_PointSize=uSize*alpha/max(-mv.z,0.5); gl_Position=projectionMatrix*mv; }`,
      fragmentShader: `varying float vA; uniform vec3 uColor;
        void main(){ float d=length(gl_PointCoord-0.5); if(d>0.5) discard;
          gl_FragColor=vec4(uColor, vA*(1.0-d*2.0)); }`,
    });
    this.points = new THREE.Points(geo, mat);
    this.points.frustumCulled = false;
  }
  // emit a particle in the group's LOCAL space heading toward localHoleDir
  emit(originLocal, towardLocal) {
    const i = this.head; this.head = (this.head + 1) % this.max;
    this.posArr.set([originLocal.x, originLocal.y, originLocal.z], i * 3);
    const spread = 0.3;
    this.velArr[i * 3] = towardLocal.x + (Math.random() - 0.5) * spread;
    this.velArr[i * 3 + 1] = towardLocal.y + (Math.random() - 0.5) * spread;
    this.velArr[i * 3 + 2] = towardLocal.z + (Math.random() - 0.5) * spread;
    this.lifeArr[i] = 1;
  }
  step(dt) {
    for (let i = 0; i < this.max; i++) {
      if (this.lifeArr[i] <= 0) { this.alphaArr[i] = 0; continue; }
      this.lifeArr[i] -= dt * 0.6;
      this.posArr[i * 3] += this.velArr[i * 3] * dt;
      this.posArr[i * 3 + 1] += this.velArr[i * 3 + 1] * dt;
      this.posArr[i * 3 + 2] += this.velArr[i * 3 + 2] * dt;
      this.alphaArr[i] = Math.max(0, this.lifeArr[i]);
    }
    this.points.geometry.attributes.position.needsUpdate = true;
    this.points.geometry.attributes.alpha.needsUpdate = true;
  }
}

function accrete(b, ctx, stream, dt) {
  stream.step(dt);
  if (!ctx.holes || !ctx.holes.length || b.viz.isHole) return;
  const wpos = b.viz.group.getWorldPosition(new THREE.Vector3());
  let nearest = null, nd = Infinity;
  for (const h of ctx.holes) { const d = h.posScene.distanceTo(wpos); if (d < nd) { nd = d; nearest = h; } }
  if (!nearest) return;
  // tidal (Roche-ish) reach ~ a few times the rendered horizon
  const reach = nearest.rsScene * 14 + b.viz.R * 3;
  if (nd > reach) return;
  const strength = THREE.MathUtils.clamp(1 - (nd - nearest.rsScene * 2) / reach, 0, 1);
  // local-space direction toward hole
  const inv = b.viz.group.matrixWorld.clone().invert();
  const holeLocal = nearest.posScene.clone().applyMatrix4(inv);
  const dir = holeLocal.clone().normalize().multiplyScalar(b.viz.R * (4 + 6 * strength));
  const emitN = Math.random() < strength * 0.9 ? 1 + Math.floor(strength * 2) : 0;
  for (let k = 0; k < emitN; k++) {
    const o = new THREE.Vector3().randomDirection().multiplyScalar(b.viz.R * b.viz.core.scale.x);
    stream.emit(o, dir);
  }
  // visible mass loss + accretion drag → a slow inward death-spiral
  if (strength > 0.03) {
    if (b.mass > 0.02) {
      const loss = b.mass * strength * dt * 0.18;
      b.mass = Math.max(0.01, b.mass - loss);
      const shrink = Math.max(0.18, Math.pow(b.mass / (b.mass0 || b.mass), 0.33));
      b.viz.group.scale.setScalar(shrink * (b.viz.group.userData.baseScale || 1));
    }
    // bleed a little orbital energy so it gradually descends rather than orbiting forever
    if (b.vel) b.vel.multiplyScalar(1 - strength * dt * 0.06);
  }
}

// ---------------------------------------------------------------------------
export function createBodyVisual(b, opts) {
  switch (b.type) {
    case 'bh':        return createBlackHole(b, opts);
    case 'star':      return createStar(b, opts);
    case 'neutron':   return createNeutron(b, opts);
    case 'gas-giant': return createPlanet(b, { ...opts, gas: true });
    default:          return createPlanet(b, opts);   // rocky
  }
}
