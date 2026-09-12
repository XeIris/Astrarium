import * as THREE from 'three';
import { ORDER } from './localview.js';

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

// ---------------------------------------------------------------------------
// ALPHA IS THE TEMPERATURE CHANNEL, so a sprite must not write to it.
// ----------------------------------------------------------------------------
// sim/spectrum.js re-images the frame from the log-encoded temperature every
// emitter publishes into alpha. A Sprite cannot publish one — it has no shader
// of its own — so with ordinary blending it writes its OPACITY there instead,
// which is a temperature of somewhere between 1 K and saturated depending on
// how faded the puff is. Saturated means "no data", and then both the sprite
// AND whatever is behind it fall back to having their temperature guessed from
// their colour.
//
// So every sprite here leaves the channel alone: zero of the source, one of the
// destination. Smoke is not an emitter and has nothing to publish, and the
// engine glow is drawn on top of the jet mesh, which publishes for it.
function passThroughAlpha(m, additive = false) {
  m.blending = THREE.CustomBlending;
  m.blendEquation = THREE.AddEquation;
  m.blendSrc = THREE.SrcAlphaFactor;
  m.blendDst = additive ? THREE.OneFactor : THREE.OneMinusSrcAlphaFactor;
  m.blendEquationAlpha = THREE.AddEquation;
  m.blendSrcAlpha = THREE.ZeroFactor;     // contribute nothing
  m.blendDstAlpha = THREE.OneFactor;      // keep what is already there
  return m;
}

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
  varying float vAng;        // azimuth round the jet, 0..1
  varying vec3 vLocal;
  uniform float uExpand;     // 0 = sea level (pinched), 1 = vacuum (bloomed)
  uniform float uThrottle, uBeam;
  uniform float uLen;
  void main(){
    vUv = uv;
    vLocal = position;
    vAng = uv.x;
    vAxial = clamp(-position.y / max(uLen, 1e-4), 0.0, 1.0);
    vec3 p = position;
    float a = vAxial;
    // THE RADIUS PROFILE IS THE PRESSURE STORY, and it is two different shapes
    // rather than one scaled.
    //
    //   OVER-EXPANDED (sea level): the ambient squeezes the jet back down to a
    //   column barely wider than the throat, and it spreads only as the mixing
    //   layer eats into it — slowly, and roughly linearly. A Merlin at liftoff
    //   is a pencil, not a cone.
    //
    //   UNDER-EXPANDED (vacuum): nothing confines it, so it turns the corner at
    //   the lip and opens as a bell that is several exit diameters across within
    //   one diameter of the nozzle. The a^0.6 is that: nearly all the spread
    //   happens immediately and then it is ballistic.
    // Both profiles start at exactly 1.0 — the nozzle's own exit radius, which
    // the geometry is built at — and then neck or bloom over the first few
    // percent of the length. Starting anywhere else leaves a visible step where
    // the jet meets the bell it is supposed to be coming out of.
    float sea = mix(1.0, 0.52, smoothstep(0.0, 0.05, a)) + 0.95 * pow(a, 1.55);
    float vac = mix(1.0, 0.34, smoothstep(0.0, 0.03, a)) + 4.30 * pow(a, 0.60);
    float bloom = mix(sea, vac, uExpand);
    // A beam does not spread at all — it is collimated, which is the whole
    // difference between an ion engine and a flame.
    bloom = mix(bloom, 0.34 + 0.22 * a, uBeam);
    p.xz *= bloom;
    // A throttled engine has a shorter flame — less mass flow to burn, and the
    // afterburning mixing layer is what most of the length IS. A vacuum plume is
    // longer again because nothing is stopping it.
    p.y *= mix(1.0, 2.3, uExpand) * (0.55 + 0.45 * uThrottle);
    gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 1.0);
  }`;

const PLUME_FRAG = `
  precision highp float;
  varying vec2 vUv; varying float vAxial; varying float vAng; varying vec3 vLocal;
  uniform vec3  uCore, uEdge;
  uniform float uThrottle, uExpand, uTime, uSoot, uGlow, uTemp, uBeam, uDiamonds;

  float hash(vec3 p){ return fract(sin(dot(p, vec3(21.7, 91.3, 47.1))) * 43758.5453); }
  float noise(vec3 p){
    vec3 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    float n000 = hash(i), n100 = hash(i + vec3(1,0,0));
    float n010 = hash(i + vec3(0,1,0)), n110 = hash(i + vec3(1,1,0));
    float n001 = hash(i + vec3(0,0,1)), n101 = hash(i + vec3(1,0,1));
    float n011 = hash(i + vec3(0,1,1)), n111 = hash(i + vec3(1,1,1));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
  }
  float fbm(vec3 p){
    float v = 0.0, a = 0.5;
    for(int i = 0; i < 3; i++){ v += a * noise(p); p *= 2.07; a *= 0.5; }
    return v;
  }

  void main(){
    float a = vAxial;
    float radial = abs(vUv.x - 0.5) * 2.0;
    // Azimuth as a position on a circle, so the turbulence does not have a seam
    // where the cylinder's uv wraps.
    float th = vAng * 6.2831853;
    vec3 sp = vec3(cos(th) * 1.7, sin(th) * 1.7, 0.0);

    // ======================================================================
    // ZONE 1 — THE SUPERSONIC CORE.
    // ----------------------------------------------------------------------
    // The gas leaves the throat at Mach 3-plus and stays supersonic for a few
    // exit diameters before the mixing layer, growing inward from the edge,
    // finally closes on the axis. That length is SHORT — five to ten diameters
    // — and it is where all the shock structure lives. It gets relatively
    // shorter as the jet blooms, because a bloomed jet has far more surface for
    // the shear layer to work on.
    float coreEnd = mix(0.34, 0.13, uExpand);
    float inCore = 1.0 - smoothstep(coreEnd * 0.55, coreEnd * 1.35, a);

    // --- SHOCK DIAMONDS. The jet leaves over-expanded, is turned back by an
    // oblique shock, over-corrects, expands again: a standing train, bright
    // where the gas is compressed and heated and dark where it re-expands. The
    // spacing grows downstream as the jet slows and the shock angle opens, and
    // the whole train disappears with altitude on its own because there is no
    // longer an ambient pressure to be wrong about.
    float sp0 = 0.055 + 0.16 * a;
    float diamonds = 0.5 + 0.5 * cos((a / sp0) * 6.2831853);
    diamonds = pow(max(diamonds, 0.0), 2.6);
    // The train is also a shape, not just a brightness: the bright cells are
    // narrow and the dark ones are wide, so weight it toward the axis.
    float shock = 1.0 + 2.4 * diamonds * (1.0 - radial * 0.65);

    // --- THE MACH DISK. Push the pressure ratio far enough and the oblique
    // train cannot do the job in one reflection: it terminates in a NORMAL
    // shock, a flat disc across the jet that takes the flow subsonic in one
    // step. It is the brightest single feature in a heavily over-expanded plume
    // and it sits within a diameter or so of the exit — which is why a
    // sea-level engine has a hard white knot right at the nozzle and a vacuum
    // engine has nothing of the kind.
    float over = 1.0 - uExpand;
    float aM = 0.045 + 0.075 * over;
    float disk = exp(-pow((a - aM) / 0.028, 2.0)) * smoothstep(0.35, 0.85, over);
    disk *= 1.0 - smoothstep(0.35, 0.95, radial);

    float core = pow(max(1.0 - radial * 1.75, 0.0), 2.6) * inCore;

    // ======================================================================
    // ZONE 2 — THE MIXING LAYER, which is most of what you can see.
    // ----------------------------------------------------------------------
    // Past the core the jet is a turbulent shear layer entraining air, and for
    // anything carbon-bearing it is still BURNING — the exhaust leaves fuel-rich
    // and finishes combusting in the atmosphere. That afterburning is the long
    // soft flame, it is much dimmer than the core, and it is where all the
    // structure is. Brightest in an annulus, because that is where the shear is.
    float shear = exp(-pow((radial - 0.62) / 0.40, 2.0));
    float mixLayer = smoothstep(coreEnd * 0.4, coreEnd * 1.8, a) * pow(1.0 - a, 0.9);

    // Turbulence advected downstream. Three octaves, scrolling on the axial
    // coordinate at the speed the eddies are actually convected, and modulated
    // in time so the field is regenerated rather than translated for ever.
    float turb = fbm(sp + vec3(0.0, 0.0, a * 6.5 - uTime * 5.5));
    turb = mix(turb, fbm(sp * 2.3 + vec3(0.0, 0.0, a * 13.0 - uTime * 9.0)), 0.45);
    // A beam has no turbulence at all: it is collisionless.
    turb = mix(turb, 0.5, uBeam);

    // ======================================================================
    // PUT THEM TOGETHER
    float iCore = (core * 2.2 + disk * 3.4) * mix(1.0, shock, uDiamonds * over);
    // The mixing layer needs SOMETHING TO MIX WITH. Its brightness is
    // afterburning — exhaust that left the chamber fuel-rich finishing its
    // combustion against entrained atmosphere — so in vacuum there is no
    // entrainment, no afterburning, and no turbulence: a vacuum plume is a
    // smooth, translucent, almost structureless cone, and that is not a
    // simplification, it is the observation. Scaling it by "over" is what makes
    // one shader give both a sea-level blowtorch with a billowing mantle and an
    // upper-stage ghost with none.
    float iMix  = shear * mixLayer * (0.35 + 1.5 * turb) * (0.30 + 0.70 * uSoot)
                * (0.18 + 0.82 * over);
    // The body glow behind both, so the jet is never see-through down the axis.
    float body = pow(1.0 - a, 1.25) * (1.0 - pow(radial, uBeam > 0.5 ? 6.0 : 2.2)) * 0.45;

    float i = (iCore + iMix + body) * uThrottle * uGlow;
    if(i <= 0.0006) discard;

    // ======================================================================
    // COLOUR IS A TEMPERATURE, and the temperature falls along the jet.
    // ----------------------------------------------------------------------
    // The gas leaves the throat at the flame temperature and cools as it
    // expands and mixes, so the tail of a kerosene plume is the same gas several
    // hundred kelvin colder — which is exactly why it runs white-yellow at the
    // nozzle and deep orange at the end. Soot is what makes that visible: a
    // hydrogen plume has almost no continuum emitter in it and stays a thin
    // violet whatever its temperature.
    float cool = 1.0 - 0.72 * pow(a, 0.8) * uSoot;
    vec3 col = mix(uEdge, uCore, clamp(core * 1.5 + disk * 2.0 + (1.0 - a) * 0.30, 0.0, 1.0));
    col = mix(col, uEdge * vec3(1.00, 0.52, 0.24), (1.0 - cool));
    // The shock cells are hotter than the gas around them, so they are not just
    // brighter, they are WHITER.
    col = mix(col, vec3(1.0), clamp((disk * 1.8 + diamonds * 0.45 * over * inCore) * uDiamonds, 0.0, 0.85));

    // HDR: emitters are expected to write well above 1.0
    vec3 rgb = col * i * 7.0;
    // Publish the true temperature, log-encoded, for sim/spectrum.js — cooled
    // along the jet, so the tail images as the cooler gas it is.
    float T = uTemp * mix(1.0, cool, 0.85);
    gl_FragColor = vec4(rgb, clamp(log(max(T, 2.0)) / 25.33, 0.006, 0.984));
  }`;

/**
 * One engine's plume. `exitD` sets the scale; everything else is driven per
 * frame from the flight state.
 */
export function createPlume(propellant, exitD, { lengthScale = 18 } = {}) {
  const P = PROPELLANT[propellant] || PROPELLANT.kerolox;
  const L = exitD * lengthScale * (P.beam ? 2.4 : 1);
  // A straight tube at the NOZZLE'S OWN EXIT RADIUS. All the shaping is in the
  // vertex shader, where it is a function of the pressure ratio, so the geometry
  // must not pre-empt any of it — a tapered tube would multiply a taper by a
  // taper and the sea-level jet came out a third the width it should be.
  const geo = new THREE.CylinderGeometry(exitD * 0.5, exitD * 0.5, L, 28, 30, true);
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
  const jet = new THREE.Mesh(geo, material);
  jet.frustumCulled = false;
  jet.renderOrder = ORDER.flame;

  // THE NOZZLE IS A LIGHT SOURCE, and a jet drawn as a tube is not one.
  // The exit plane is the hottest thing on the vehicle and it is looked at down
  // its own axis half the time — from the pad camera as the vehicle climbs
  // away, from behind on every chase shot — where a tube presents its end cap
  // and almost no area. A camera-facing glow at the exit is the part of an
  // engine you actually see first: it is the reason a rocket at twenty
  // kilometres is a star rather than a shape.
  const glow = new THREE.Sprite(passThroughAlpha(new THREE.SpriteMaterial({
    map: glowTexture(), color: 0xffffff, transparent: true, opacity: 0, depthWrite: false,
  }), true));
  glow.renderOrder = ORDER.flame;
  glow.material.color.setRGB(
    Math.min(1, P.core[0] * 1.1 + 0.25), Math.min(1, P.core[1] * 1.1 + 0.2), Math.min(1, P.core[2] * 1.1 + 0.15));

  const mesh = new THREE.Group();
  mesh.add(jet, glow);
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
      const ex = THREE.MathUtils.clamp(1 - pa / p0, 0, 1);
      uniforms.uExpand.value = ex;
      uniforms.uTime.value = time;
      // The glow sits a little inside the exit plane — the flash comes from the
      // gas in the bell, not from a disc hanging in front of it — and grows
      // with the plume, because in vacuum there is far more radiating gas.
      glow.position.y = -exitD * 0.35;
      glow.scale.setScalar(exitD * (2.2 + 3.4 * ex) * (0.6 + 0.4 * throttle) * (P.beam ? 0.35 : 1));
      glow.material.opacity = (P.beam ? 0.18 : 0.85) * P.glow * (0.45 + 0.55 * throttle);
    },
  };
}

/** A soft radial falloff with a hot centre — one texture, shared by every
 *  engine in the sim. */
let _glowTex = null;
function glowTexture() {
  if (_glowTex) return _glowTex;
  const s = 128, cv = document.createElement('canvas'); cv.width = cv.height = s;
  const g = cv.getContext('2d');
  const rg = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
  rg.addColorStop(0.00, 'rgba(255,255,255,1)');
  rg.addColorStop(0.12, 'rgba(255,246,226,0.85)');
  rg.addColorStop(0.35, 'rgba(255,190,120,0.30)');
  rg.addColorStop(0.70, 'rgba(255,140,60,0.07)');
  rg.addColorStop(1.00, 'rgba(255,120,40,0)');
  g.fillStyle = rg; g.fillRect(0, 0, s, s);
  _glowTex = new THREE.CanvasTexture(cv);
  return _glowTex;
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
    const s = new THREE.Sprite(passThroughAlpha(new THREE.SpriteMaterial({
      map: tex, color: 0xbfd8ff, transparent: true, opacity: 0, depthWrite: false,
    }), true));
    s.renderOrder = ORDER.flame;
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
  mesh.renderOrder = ORDER.flame;
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
export function createSmokeColumn(count = 150) {
  const g = new THREE.Group();
  const tex = smokeTexture();
  const parts = [];
  for (let i = 0; i < count; i++) {
    const s = new THREE.Sprite(passThroughAlpha(new THREE.SpriteMaterial({
      map: tex, color: 0xd8d8d4, transparent: true, opacity: 0, depthWrite: false,
    })));
    s.renderOrder = ORDER.smoke;
    s.visible = false; g.add(s);
    parts.push({ s, life: 0, rate: 1, spin: 0, vel: new THREE.Vector3() });
  }
  let next = 0;
  // TWO CLOUDS, NOT ONE, and they are made of different substances.
  //
  //   STEAM is the deluge flashing off the deck — a million litres of water in
  //   forty seconds. It is brilliant white, it is most of the VOLUME, and it
  //   dies quickly because it condenses and rains back out.
  //
  //   SOOT is the exhaust: unburnt carbon out of a fuel-rich kerosene engine,
  //   or aluminium oxide out of a solid. It is dark, it is what the column is
  //   still made of a minute later, and it is the reason the base of a launch
  //   cloud is brown and the top is white.
  //
  // Drawing only the white half is what makes a rendered launch look like a
  // fog machine. The mix follows the propellant's own soot fraction, so a
  // hydrogen launch is genuinely almost clean and a solid is filthy.
  const STEAM = new THREE.Color(0xe8eaec), SOOT = new THREE.Color(0x4a423a);
  const _c = new THREE.Color();
  return {
    group: g,
    /** Emit at the pad. `power` is the thrust fraction; `spread` is in metres. */
    emit(origin, power, spread, dt, soot = 0.7) {
      const n = Math.min(9, Math.ceil(power * 44 * dt));
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
        // Soot is thrown out with the exhaust and stays low and near the middle;
        // steam boils off the whole deck. So which one a puff is depends on
        // where it started, which is what puts the dark core inside the white.
        const dirty = Math.random() < soot * (1 - 0.55 * (r / spread));
        _c.copy(dirty ? SOOT : STEAM);
        // No two puffs the same value, or several hundred of them read as one
        // flat sheet however well each is shaded.
        _c.multiplyScalar(0.80 + Math.random() * 0.35);
        p.s.material.color.copy(_c);
        p.dirty = dirty;
        // Soot survives; steam condenses out. That difference in lifetime is
        // what leaves a dark column standing after the white has gone.
        p.rate = dirty ? 0.10 : 0.30;
        p.life = 1; p.s.visible = true;
        p.s.scale.setScalar(spread * (0.6 + Math.random() * 0.8));
        p.s.material.rotation = Math.random() * 6.28;
        // Rolling, because a puff that holds its orientation while it grows
        // reads as a decal rather than as a turbulent lump.
        p.spin = (Math.random() - 0.5) * 0.5;
      }
    },
    update(dt) {
      for (const p of parts) {
        if (p.life <= 0) continue;
        p.life -= dt * p.rate;
        if (p.life <= 0) { p.s.visible = false; continue; }
        p.s.position.addScaledVector(p.vel, dt);
        p.vel.multiplyScalar(1 - dt * 0.7);
        p.vel.y += dt * 2.4;                       // buoyancy: it is hot
        p.s.scale.multiplyScalar(1 + dt * 0.55);
        p.s.material.rotation += p.spin * dt;
        // Entrained air cools and dilutes it, so a puff pales as it ages — the
        // dark core is dark because it is YOUNG, not because it is a different
        // colour for ever.
        if (p.dirty) p.s.material.color.lerp(STEAM, dt * 0.10);
        p.s.material.opacity = Math.pow(p.life, 1.4) * (p.dirty ? 0.62 : 0.45);
      }
    },
    clear() { for (const p of parts) { p.life = 0; p.s.visible = false; } },
  };
}

// A puff of smoke. The alpha is VALUE NOISE, not a product of a sine and a
// cosine — sin(x)·cos(y) is separable, which means its level sets are a grid,
// which means every sprite in the cloud carried the same diagonal lattice and
// a few hundred of them overlapping turned the whole launch cloud into visible
// cross-hatching. Real noise has no preferred direction, which is the entire
// property being asked for here.
//
// The shading is not flat either: a smoke puff is a lump of scattering medium
// lit from one side, so it is bright where it faces the light and dark in its
// own shadow. One texture with a baked gradient does more for a cloud than any
// number of extra sprites.
function smokeTexture() {
  const s = 128, cv = document.createElement('canvas'); cv.width = cv.height = s;
  const g = cv.getContext('2d');
  const img = g.createImageData(s, s);

  const seed = new Float32Array(64 * 64);
  for (let i = 0; i < seed.length; i++) seed[i] = Math.random();
  const lerp = (a, b, t) => a + (b - a) * t;
  const vnoise = (x, y) => {
    const xi = Math.floor(x), yi = Math.floor(y);
    let fx = x - xi, fy = y - yi;
    fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
    const at = (a, b) => seed[(((b % 64) + 64) % 64) * 64 + (((a % 64) + 64) % 64)];
    return lerp(lerp(at(xi, yi), at(xi + 1, yi), fx),
                lerp(at(xi, yi + 1), at(xi + 1, yi + 1), fx), fy);
  };

  for (let y = 0; y < s; y++) for (let x = 0; x < s; x++) {
    const dx = (x - s / 2) / (s / 2), dy = (y - s / 2) / (s / 2);
    const d = Math.sqrt(dx * dx + dy * dy);
    let n = 0, amp = 0.5, f = 3.5;
    for (let o = 0; o < 5; o++) { n += amp * vnoise(x / s * f, y / s * f); amp *= 0.5; f *= 2.13; }
    // Ragged edge: the noise eats into the disc rather than being added on top,
    // so the puff has holes and tendrils instead of a soft circular rim.
    // The noise EATS the disc — it scales the radius rather than modulating the
    // alpha on top of it — and then the alpha is taken to a power, so the puff
    // is mostly holes and tendrils. Modulating a clean disc instead leaves every
    // sprite a circle with texture on it, and a hundred circles read as a
    // hundred circles however well each one is shaded.
    const bite = Math.pow(Math.max(0, 1 - d * (0.58 + 0.95 * n)), 1.35);
    const a = bite * (0.18 + 1.15 * n * n);
    // Self-shading, as if lit from the upper left. Ambient occlusion in the
    // middle of the puff, highlight on the shoulder.
    const lit = 0.55 + 0.45 * Math.max(0, -dx * 0.7 - dy * 0.7) + 0.25 * n;
    const v = Math.min(255, Math.round(235 * Math.min(lit, 1.25)));
    const i = (y * s + x) * 4;
    img.data[i] = v; img.data[i + 1] = v; img.data[i + 2] = Math.min(255, v + 4);
    img.data[i + 3] = Math.min(255, a * 255);
  }
  g.putImageData(img, 0, 0);
  return new THREE.CanvasTexture(cv);
}

// ---------------------------------------------------------------------------
// THE GROUND FLAME — what the exhaust does after it hits the deck.
// ----------------------------------------------------------------------------
// For the first two or three vehicle lengths of a launch the jet is not going
// anywhere: it hits the deflector and turns through ninety degrees, and what
// comes out is a horizontal sheet of burning gas thrown out along the trench
// faster than it went down. That fan is the largest, brightest thing in the
// frame at T+0, and it is the reason a pad at ignition looks nothing like a
// rocket with a flame under it.
//
// Two things drive it and both are physical:
//
//   IMPINGEMENT — it exists only while the jet still reaches the deck, i.e.
//   while the vehicle's height above the pad is less than the plume is long.
//   It does not fade out on a timer; it goes out because the rocket left.
//
//   SPREAD — the fan's radius grows as the vehicle climbs, because the jet
//   arrives at the deck wider and with more of its momentum already turned by
//   the air. So it opens out and thins at the same time, which is exactly what
//   the ring of fire under a Saturn V does in the first five seconds.
//
// Drawn as a flattened dome rather than a disc: the sheet has thickness, it is
// brightest where you look ALONG it — out at the rim, where the path through
// the burning gas is longest — and a flat disc has none of that.
// ---------------------------------------------------------------------------
export function createGroundFlame(propellant, scale) {
  const P = PROPELLANT[propellant] || PROPELLANT.kerolox;
  const geo = new THREE.SphereGeometry(1, 40, 14, 0, Math.PI * 2, 0, Math.PI * 0.5);
  const uniforms = {
    uCore: { value: new THREE.Vector3(...P.core) },
    uEdge: { value: new THREE.Vector3(...P.edge) },
    uPower: { value: 0 }, uTime: { value: 0 }, uSoot: { value: P.soot },
    uTemp: { value: P.T * 0.82 },   // it has already done work turning the corner
  };
  const mesh = new THREE.Mesh(geo, new THREE.ShaderMaterial({
    uniforms,
    vertexShader: `
      varying vec3 vP; varying vec3 vN;
      void main(){
        vP = position; vN = normalize(normalMatrix * normal);
        gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
      }`,
    fragmentShader: `
      precision highp float;
      varying vec3 vP; varying vec3 vN;
      uniform vec3 uCore, uEdge;
      uniform float uPower, uTime, uSoot, uTemp;
      float hash(vec3 p){ return fract(sin(dot(p, vec3(21.7, 91.3, 47.1))) * 43758.5453); }
      float noise(vec3 p){
        vec3 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
        return mix(mix(mix(hash(i), hash(i+vec3(1,0,0)), f.x), mix(hash(i+vec3(0,1,0)), hash(i+vec3(1,1,0)), f.x), f.y),
                   mix(mix(hash(i+vec3(0,0,1)), hash(i+vec3(1,0,1)), f.x), mix(hash(i+vec3(0,1,1)), hash(i+vec3(1,1,1)), f.x), f.y), f.z);
      }
      void main(){
        if(uPower < 0.002) discard;
        float r = length(vP.xz);               // 0 on the axis, 1 at the rim
        // A THIN SHELL IS BRIGHTEST WHERE YOU LOOK ALONG IT. Shaded like an
        // ordinary surface this is a hard-edged dome; weighted by the path
        // length through the sheet — long at the rim, short face-on — it
        // becomes the low, flat fan it actually is.
        float grazing = pow(1.0 - abs(vN.y), 1.6);
        // The gas is thrown OUT, so it is thin on the axis (that is where the
        // jet is coming down, not spreading) and thickest part-way out.
        float band = smoothstep(0.08, 0.38, r) * (1.0 - smoothstep(0.58, 1.0, r));
        // And it goes out in LOBES, not as a disc. A jet hitting a deflector
        // does not spread evenly — it breaks into a handful of roll cells, they
        // wander, and that is why the fire under a vehicle at ignition has arms
        // rather than a rim. Modelled as a low-order azimuthal mode drifting at
        // its own rate, which is what the wandering is.
        float th = atan(vP.z, vP.x);
        float lobes = 0.60 + 0.40 * sin(th * 5.0 + uTime * 1.7 + sin(th * 2.0 - uTime * 0.9) * 1.4);

        // Billowing, advected radially outward at the speed it is leaving.
        float turb = noise(vec3(cos(th) * 2.6, sin(th) * 2.6, r * 3.4 - uTime * 4.0));
        turb = mix(turb, noise(vec3(cos(th) * 6.4, sin(th) * 6.4, r * 8.5 - uTime * 7.5)), 0.5);
        turb = mix(turb, noise(vec3(cos(th) * 14.0, sin(th) * 14.0, r * 17.0 - uTime * 12.0)), 0.3);
        // Hard contrast on the turbulence, so it EATS the shell rather than
        // shading it. Without this the geometry shows through as exactly what it
        // is — a hemisphere — and no amount of tinting hides a silhouette.
        turb = pow(clamp(turb * 1.55 - 0.22, 0.0, 1.0), 1.7);

        float i = uPower * band * lobes * (0.22 + 1.05 * grazing) * turb * 3.2;
        if(i <= 0.0008) discard;
        // It cools fast on the way out — it is entraining cold air the whole
        // time — so the fan runs white at the root and deep orange at the edge.
        float cool = 1.0 - 0.80 * smoothstep(0.15, 0.95, r) * uSoot;
        vec3 col = mix(uEdge * vec3(1.0, 0.48, 0.20), uCore, cool);
        gl_FragColor = vec4(col * i * 6.0,
          clamp(log(max(uTemp * mix(1.0, cool, 0.9), 2.0)) / 25.33, 0.006, 0.984));
      }`,
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    side: THREE.DoubleSide,
  }));
  mesh.frustumCulled = false;
  mesh.renderOrder = ORDER.flame;
  mesh.visible = false;

  return {
    mesh, uniforms,
    /**
     * @param throttle 0..1
     * @param height   the vehicle's height above the deck, m
     * @param reach    how far the jet carries — the plume's own length, m
     */
    update(throttle, height, reach, time) {
      // It is on while the jet still lands on the deck, and it dies as the
      // vehicle climbs out of its own exhaust. Nothing here is a timer.
      const hit = THREE.MathUtils.clamp(1 - height / Math.max(reach, 1), 0, 1);
      const power = throttle * hit * hit;
      mesh.visible = power > 0.004;
      if (!mesh.visible) return;
      uniforms.uPower.value = power;
      uniforms.uTime.value = time;
      // The fan opens out as the vehicle rises: the jet arrives wider, and more
      // of it is turned before it gets there.
      const rad = scale * (1.0 + 1.8 * (1 - hit));
      // Flat. The fan is a sheet running along the ground, not a fireball — it
      // is the vertical momentum that has been taken OUT of the jet.
      mesh.scale.set(rad, rad * 0.22, rad);
    },
  };
}
