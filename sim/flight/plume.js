import * as THREE from 'three';

// ============================================================================
// EXHAUST, PLASMA AND SMOKE
// ----------------------------------------------------------------------------
// The plume's SHAPE is a function of ambient pressure and nothing else, so one
// shader covers sea level, vacuum and everything in between — which is the
// effect worth having, because you watch it happen during the climb.
//
//   OVER-EXPANDED (low altitude, p_e < p_a): the outside air squeezes the jet
//   into a narrow column, and it recompresses to ambient through a train of
//   oblique shocks — the SHOCK DIAMONDS. Bright where the gas is compressed and
//   heated, dark where it expands again. Three to five are visible on a Falcon 9
//   at liftoff, and their spacing grows as the air thins.
//
//   UNDER-EXPANDED (vacuum, p_e > p_a): nothing confines it, so it opens into a
//   huge translucent bell many times the nozzle diameter and the diamonds
//   disappear entirely. This is why an upper stage looks like it has an enormous
//   ghost of a flame and a first stage looks like a blowtorch.
//
// COLOUR IS THE PROPELLANT, not taste. RP-1/LOX is soot-luminous orange because
// it is burning carbon; LH2/LOX is nearly invisible pale violet because it is
// burning to water with almost no continuum emitter in it; methalox is blue with
// an orange core; a solid is a white-orange torch behind an enormous grey-white
// cloud of aluminium oxide. An ion engine is not a flame at all — it is a
// collimated beam of xenon ions recombining, so it is dim, narrow, does not
// flicker, and must not look powerful at 237 mN.
//
// Every emitter here publishes its true temperature into the HDR buffer's alpha
// (log-encoded, α = ln T / 25.33, the sim/spectrum.js convention) so a 3 500 K
// plume re-images correctly in the infrared band and vanishes in the X-ray.
// ============================================================================

// Flame temperature and appearance per propellant. Chamber temperatures are the
// real ones; what is drawn is the plume, which is cooler.
export const PROPELLANT = {
  kerolox:    { T: 3400, core: [1.00, 0.72, 0.34], edge: [1.00, 0.36, 0.08], soot: 0.85, glow: 1.0 },
  hydrolox:   { T: 3200, core: [0.72, 0.80, 1.00], edge: [0.42, 0.36, 0.95], soot: 0.06, glow: 0.34 },
  methalox:   { T: 3500, core: [0.62, 0.80, 1.00], edge: [1.00, 0.55, 0.22], soot: 0.30, glow: 0.75 },
  solid:      { T: 3000, core: [1.00, 0.90, 0.70], edge: [1.00, 0.55, 0.20], soot: 1.00, glow: 1.35 },
  hypergolic: { T: 3050, core: [1.00, 0.94, 0.72], edge: [0.95, 0.72, 0.35], soot: 0.18, glow: 0.55 },
  // Not thermal at all: a beam of ions recombining, so it gets a low nominal
  // temperature and is dominated by line emission rather than a continuum.
  ion:        { T: 1200, core: [0.55, 0.62, 1.00], edge: [0.40, 0.20, 0.95], soot: 0.0, glow: 0.25, beam: true },
  // The spin drive radiates at 25.98 µm — deep infrared, and invisible. What is
  // drawn is the visible tail of a source that is overwhelmingly not visible,
  // which is why it is a faint red haze and not a torch.
  spin:       { T: 1500, core: [1.00, 0.30, 0.18], edge: [0.55, 0.06, 0.04], soot: 0.0, glow: 0.45, beam: true },
};

const PLUME_VERT = `
  varying vec2 vUv;
  varying float vAxial;      // 0 at the nozzle, 1 at the tip
  varying vec3 vLocal;
  uniform float uExpand;     // 0 = sea level (pinched), 1 = vacuum (bloomed)
  uniform float uLen;
  void main(){
    vUv = uv;
    vLocal = position;
    vAxial = clamp(-position.y / max(uLen, 1e-4), 0.0, 1.0);
    vec3 p = position;
    // The plume's radius profile IS the pressure story: pinched and columnar in
    // thick air, blooming into a bell as the ambient pressure falls away.
    float bloom = mix(0.35 + 0.55 * (1.0 - vAxial), 0.30 + 3.4 * pow(vAxial, 0.7), uExpand);
    p.xz *= bloom;
    p.y *= mix(1.0, 2.1, uExpand);
    gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
  }`;

const PLUME_FRAG = `
  precision highp float;
  varying vec2 vUv; varying float vAxial; varying vec3 vLocal;
  uniform vec3  uCore, uEdge;
  uniform float uThrottle, uExpand, uTime, uSoot, uGlow, uTemp, uBeam, uDiamonds;

  float hash(vec2 p){ return fract(sin(dot(p, vec2(21.7, 91.3))) * 43758.5453); }
  float noise(vec2 p){
    vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1,0)), f.x),
               mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), f.x), f.y);
  }

  void main(){
    float a = vAxial;
    // radial coordinate across the plume, 0 on the axis
    float r = clamp(length(vLocal.xz) / max(length(vLocal.xz) + 1e-6, 1e-6), 0.0, 1.0);
    float radial = abs(vUv.x - 0.5) * 2.0;

    // --- SHOCK DIAMONDS. Only an over-expanded jet has them, so they fade out
    // with altitude on their own. Their spacing grows down the plume as the jet
    // slows and the shock angle opens.
    float sp = 0.16 + 0.42 * a;
    float diamonds = 0.5 + 0.5 * cos((a / sp) * 6.2831);
    diamonds = pow(max(diamonds, 0.0), 2.2);
    float shock = mix(1.0, 0.45 + 1.9 * diamonds, uDiamonds * (1.0 - uExpand));

    // --- turbulent structure, stronger where the jet has mixed with air
    float turb = noise(vec2(radial * 6.0 + vLocal.x * 2.0, a * 9.0 - uTime * 14.0));
    float mixing = smoothstep(0.05, 0.9, a);

    // --- brightness: falls along the axis and across it
    float body = pow(1.0 - a, 0.75) * (1.0 - pow(radial, uBeam > 0.5 ? 6.0 : 2.4));
    float core = pow(max(1.0 - radial * 1.9, 0.0), 3.0) * (1.0 - a * 0.55);
    float i = (body * 0.9 + core * 1.6) * shock;
    i *= mix(1.0, 0.55 + 0.9 * turb, mixing * uSoot);
    i *= uThrottle * uGlow;
    if(i <= 0.0005) discard;

    vec3 col = mix(uEdge, uCore, clamp(core * 1.4 + (1.0 - a) * 0.35, 0.0, 1.0));
    // Soot-laden plumes cool visibly along their length — the orange tail of a
    // kerosene engine is the same gas, several hundred kelvin colder.
    col = mix(col, uEdge * vec3(1.0, 0.55, 0.28), uSoot * a * 0.7);

    // HDR: emitters are expected to write well above 1.0
    vec3 rgb = col * i * 7.0;
    // publish the true temperature, log-encoded, for sim/spectrum.js
    gl_FragColor = vec4(rgb, clamp(log(uTemp) / 25.33, 0.006, 0.984));
  }`;

/**
 * One engine's plume. `exitD` sets the scale; everything else is driven per
 * frame from the flight state.
 */
export function createPlume(propellant, exitD, { lengthScale = 14 } = {}) {
  const P = PROPELLANT[propellant] || PROPELLANT.kerolox;
  const L = exitD * lengthScale * (P.beam ? 2.4 : 1);
  const geo = new THREE.CylinderGeometry(exitD * 0.46, exitD * 0.30, L, 20, 24, true);
  geo.translate(0, -L / 2, 0);
  const uniforms = {
    uCore: { value: new THREE.Vector3(...P.core) },
    uEdge: { value: new THREE.Vector3(...P.edge) },
    uThrottle: { value: 0 }, uExpand: { value: 0 }, uTime: { value: 0 },
    uSoot: { value: P.soot }, uGlow: { value: P.glow }, uTemp: { value: P.T },
    uBeam: { value: P.beam ? 1 : 0 }, uDiamonds: { value: P.beam ? 0 : 1 },
    uLen: { value: L },
  };
  const material = new THREE.ShaderMaterial({
    uniforms, vertexShader: PLUME_VERT, fragmentShader: PLUME_FRAG,
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    side: THREE.DoubleSide,
  });
  const mesh = new THREE.Mesh(geo, material);
  mesh.frustumCulled = false;
  mesh.visible = false;

  return {
    mesh, uniforms, propellant: P,
    /** @param throttle 0..1 @param pa ambient pressure, Pa @param p0 reference (sea level) */
    update(throttle, pa, time, p0 = 101325) {
      const on = throttle > 0.001;
      mesh.visible = on;
      if (!on) return;
      uniforms.uThrottle.value = 0.35 + 0.65 * throttle;
      // Expansion state: 0 in a sea-level atmosphere, 1 in vacuum. The plume's
      // whole shape follows this one number.
      uniforms.uExpand.value = THREE.MathUtils.clamp(1 - pa / p0, 0, 1);
      uniforms.uTime.value = time;
    },
  };
}

// ---------------------------------------------------------------------------
// RCS — short, cold, translucent puffs. They matter because they are the only
// visible sign that the vehicle is holding attitude.
// ---------------------------------------------------------------------------
export function createRCSPuffs(count = 12) {
  const g = new THREE.Group();
  const puffs = [];
  const tex = puffTexture();
  for (let i = 0; i < count; i++) {
    const s = new THREE.Sprite(new THREE.SpriteMaterial({
      map: tex, color: 0xbfd8ff, transparent: true, opacity: 0,
      blending: THREE.AdditiveBlending, depthWrite: false,
    }));
    s.visible = false; g.add(s); puffs.push({ sprite: s, life: 0 });
  }
  let next = 0;
  return {
    group: g,
    /** Fire a puff at a local position, in a local direction. */
    fire(pos, dir, size = 1) {
      const p = puffs[next = (next + 1) % puffs.length];
      p.sprite.position.copy(pos).addScaledVector(dir, size * 0.6);
      p.sprite.scale.setScalar(size);
      p.life = 1; p.sprite.visible = true; p.dir = dir.clone(); p.size = size;
    },
    update(dt) {
      for (const p of puffs) {
        if (p.life <= 0) continue;
        p.life -= dt * 4.5;
        if (p.life <= 0) { p.sprite.visible = false; continue; }
        p.sprite.material.opacity = p.life * 0.55;
        p.sprite.scale.setScalar(p.size * (1 + (1 - p.life) * 2.2));
        p.sprite.position.addScaledVector(p.dir, dt * p.size * 4);
      }
    },
  };
}

function puffTexture() {
  const s = 64, cv = document.createElement('canvas'); cv.width = cv.height = s;
  const g = cv.getContext('2d');
  const rg = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
  rg.addColorStop(0, 'rgba(255,255,255,0.9)');
  rg.addColorStop(0.4, 'rgba(200,225,255,0.35)');
  rg.addColorStop(1, 'rgba(160,200,255,0)');
  g.fillStyle = rg; g.fillRect(0, 0, s, s);
  return new THREE.CanvasTexture(cv);
}

// ---------------------------------------------------------------------------
// RE-ENTRY PLASMA
// ----------------------------------------------------------------------------
// A bow-shock cap ahead of the vehicle whose brightness and colour follow the
// Sutton–Graves heat flux — the same number that is burning the shield down and
// that will destroy the vehicle if it gets too large. So nothing here is
// decorative: if you see a lot of it, you are in trouble, and the HUD agrees.
// ---------------------------------------------------------------------------
export function createEntryGlow(radius) {
  const geo = new THREE.SphereGeometry(radius, 28, 18, 0, Math.PI * 2, 0, Math.PI * 0.62);
  const uniforms = {
    uHeat: { value: 0 }, uTime: { value: 0 }, uTemp: { value: 2000 },
  };
  const material = new THREE.ShaderMaterial({
    uniforms,
    vertexShader: `
      varying vec3 vN; varying vec3 vP;
      void main(){ vN = normalize(normalMatrix * normal); vP = position;
        gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
    fragmentShader: `
      precision highp float;
      varying vec3 vN; varying vec3 vP;
      uniform float uHeat, uTime, uTemp;
      float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1,113.5,7.9))) * 43758.5); }
      void main(){
        if(uHeat < 0.001) discard;
        // The sheath is brightest at the stagnation point and streams back.
        float front = clamp(-vN.y * 0.5 + 0.5, 0.0, 1.0);
        float rim   = pow(1.0 - abs(vN.z), 2.0);
        float flick = 0.75 + 0.25 * hash(floor(vP * 9.0 + uTime * 26.0));
        float i = uHeat * (pow(front, 2.4) * 1.6 + rim * 0.5) * flick;
        // colour runs dull red → orange → blue-white as the flux climbs, which
        // is the real progression from a shallow entry to a lunar-return one
        vec3 c = mix(vec3(1.0, 0.24, 0.06), vec3(1.0, 0.72, 0.35), clamp(uHeat * 1.6, 0.0, 1.0));
        c = mix(c, vec3(0.75, 0.86, 1.0), clamp(uHeat * 0.65 - 0.55, 0.0, 1.0));
        gl_FragColor = vec4(c * i * 5.0, clamp(log(uTemp) / 25.33, 0.006, 0.984));
      }`,
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    side: THREE.BackSide,
  });
  const mesh = new THREE.Mesh(geo, material);
  mesh.frustumCulled = false; mesh.visible = false;
  return {
    mesh, uniforms,
    /** @param q W/m² from sim/flight/rocketry.js's heatFlux */
    update(q, time) {
      // 1 MW/m² is a hard entry; scale so a shallow one is a visible glow and a
      // lunar return is blinding.
      const h = THREE.MathUtils.clamp(q / 1.1e6, 0, 2.5);
      mesh.visible = h > 0.004;
      uniforms.uHeat.value = h;
      uniforms.uTime.value = time;
      // Shock-layer temperature from the flux, so it re-images correctly in IR.
      uniforms.uTemp.value = THREE.MathUtils.clamp(1400 + q * 0.006, 900, 12000);
    },
  };
}

// ---------------------------------------------------------------------------
// LAUNCH SMOKE — the ground cloud, which only exists where there is an
// atmosphere AND a surface to bounce off. It is billboards rather than a
// volume, because that is what a few hundred of them can afford to be.
// ---------------------------------------------------------------------------
export function createSmokeColumn(count = 90) {
  const g = new THREE.Group();
  const tex = smokeTexture();
  const parts = [];
  for (let i = 0; i < count; i++) {
    const s = new THREE.Sprite(new THREE.SpriteMaterial({
      map: tex, color: 0xd8d8d4, transparent: true, opacity: 0, depthWrite: false,
    }));
    s.visible = false; g.add(s);
    parts.push({ s, life: 0, vel: new THREE.Vector3() });
  }
  let next = 0;
  return {
    group: g,
    /** Emit at the pad. `power` is the thrust fraction; `spread` is in metres. */
    emit(origin, power, spread, dt) {
      const n = Math.min(6, Math.ceil(power * 26 * dt * 60 / 60));
      for (let k = 0; k < n; k++) {
        const p = parts[next = (next + 1) % parts.length];
        const a = Math.random() * Math.PI * 2;
        const r = spread * (0.2 + Math.random() * 0.9);
        p.s.position.set(origin.x + Math.cos(a) * r, origin.y + Math.random() * spread * 0.2,
                         origin.z + Math.sin(a) * r);
        // The cloud rolls OUTWARD first and only then rises — the deflected
        // exhaust is going sideways at the speed of sound.
        p.vel.set(Math.cos(a) * spread * (0.7 + Math.random()), spread * 0.25 * Math.random(),
                  Math.sin(a) * spread * (0.7 + Math.random()));
        p.life = 1; p.s.visible = true;
        p.s.scale.setScalar(spread * (0.6 + Math.random() * 0.8));
        p.s.material.rotation = Math.random() * 6.28;
      }
    },
    update(dt) {
      for (const p of parts) {
        if (p.life <= 0) continue;
        p.life -= dt * 0.22;
        if (p.life <= 0) { p.s.visible = false; continue; }
        p.s.position.addScaledVector(p.vel, dt);
        p.vel.multiplyScalar(1 - dt * 0.7);
        p.vel.y += dt * 2.4;                       // buoyancy: it is hot
        p.s.scale.multiplyScalar(1 + dt * 0.55);
        p.s.material.opacity = Math.pow(p.life, 1.4) * 0.5;
      }
    },
    clear() { for (const p of parts) { p.life = 0; p.s.visible = false; } },
  };
}

function smokeTexture() {
  const s = 128, cv = document.createElement('canvas'); cv.width = cv.height = s;
  const g = cv.getContext('2d');
  const img = g.createImageData(s, s);
  for (let y = 0; y < s; y++) for (let x = 0; x < s; x++) {
    const dx = (x - s / 2) / (s / 2), dy = (y - s / 2) / (s / 2);
    const d = Math.sqrt(dx * dx + dy * dy);
    // a few octaves of value noise so the edge is ragged rather than a disc
    let n = 0, amp = 0.5, f = 3;
    for (let o = 0; o < 4; o++) {
      n += amp * (Math.sin(x * f * 0.11 + o * 2.3) * Math.cos(y * f * 0.13 + o * 1.7) * 0.5 + 0.5);
      amp *= 0.5; f *= 2.1;
    }
    const a = Math.max(0, 1 - d) * (0.55 + n * 0.75);
    const i = (y * s + x) * 4;
    img.data[i] = img.data[i + 1] = img.data[i + 2] = 235;
    img.data[i + 3] = Math.min(255, a * 255);
  }
  g.putImageData(img, 0, 0);
  return new THREE.CanvasTexture(cv);
}
