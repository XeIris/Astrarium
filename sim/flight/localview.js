import * as THREE from 'three';
import { density, pressure, scaleHeight } from './rocketry.js';

// ============================================================================
// LOCAL SPACE
// ----------------------------------------------------------------------------
// The orrery draws in scene units where one unit is an AU. A rocket is 100 m —
// 7e-10 AU — so at the camera distances a launch is watched from, the near
// plane, the depth buffer and float32 vertex precision all fail at once. This is
// not a tuning problem; it is eleven orders of magnitude and no single
// projection covers it.
//
// So spaceflight is drawn in a SECOND pass with its own scene and its own
// camera, in metres, and composited over the orrery's frame. Every space
// simulator that has ever worked does this — KSP calls the two halves "scaled
// space" and "local space" — and the split is clean here because the two never
// need to see each other: from a hundred metres the whole rest of the universe
// is background, and from a hundred kilometres the vehicle is a point.
//
// What local space contains:
//   · the vehicle and its plumes (sim/flight/craftmodel.js, plume.js)
//   · a GROUND PATCH with real planetary curvature, so the horizon sits where
//     it belongs: √(2Rh) away, 35.7 km from a 100 m tower, 357 km from 10 km up
//   · an ATMOSPHERE that thins with altitude on the body's own scale height, so
//     the sky goes from blue to black over exactly the range it should
//
// The ground is a parabolic sheet, y = −r²/2R, not a piece of a sphere. Over a
// few hundred kilometres the two are identical to well under a metre, and the
// sphere would put 6.4e6 into a float32 vertex where the resolution is already
// 0.4 m before the rocket's own geometry gets a look in.
// ============================================================================

const GROUND_VERT = `
  uniform float uRadius;      // planet radius, m
  uniform float uPatch;       // patch radius, m
  uniform float uEye;         // observer altitude, m
  varying float vDist;
  varying vec3  vWorld;
  varying float vDrop;
  void main(){
    // The unit disc is stretched to the patch radius with a quadratic
    // distribution, so the vertices crowd where the detail is: near the vehicle.
    vec3 p = position;
    float u = length(p.xz);
    float r = uPatch * u * u;
    vec2 d = u > 1e-6 ? p.xz / u : vec2(0.0);
    // planetary curvature — the horizon drop
    float drop = (r * r) / (2.0 * uRadius);
    vec3 q = vec3(d.x * r, -drop, d.y * r);
    vDist = r; vWorld = q; vDrop = drop;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(q, 1.0);
  }`;

const GROUND_FRAG = `
  precision highp float;
  varying float vDist; varying vec3 vWorld; varying float vDrop;
  uniform vec3  uGround, uRock, uHaze, uSunDir;
  uniform float uEye, uScaleH, uDensity, uPatch, uHasAir, uSeaLevel, uOceans;
  uniform float uSunI, uSkyI;
  uniform vec3  uSea;

  float hash(vec2 p){ return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453); }
  float noise(vec2 p){
    vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1,0)), f.x),
               mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), f.x), f.y);
  }
  float fbm(vec2 p){ float v = 0.0, a = 0.5; for(int i = 0; i < 5; i++){ v += a * noise(p); p *= 2.13; a *= 0.5; } return v; }

  void main(){
    // Terrain colour: two rock tones mixed by a large-scale field, with a fine
    // grain that only survives close to the camera — past a few kilometres it
    // is below a pixel anyway and keeping it just aliases.
    float big = fbm(vWorld.xz * 0.00008);
    // Raise the ground under the launch site. Every pad ever built is on a
    // coast — for range safety — so this is what a launch site actually looks
    // like from the tower: land under you, water a few kilometres out.
    big += 0.40 * exp(-vDist / 7000.0);
    // Three scales of detail, each fading out at the range where it stops being
    // resolvable and starts being aliasing. The MID octave is the one that
    // matters for a launch: it is the only thing in view with a known size, so
    // it is what the eye reads the climb rate against. Without it a rocket
    // rising over a smooth sheet looks stationary, then teleported.
    float mid  = fbm(vWorld.xz * 0.0011);
    float fine = fbm(vWorld.xz * 0.02);
    float midK  = exp(-vDist / 9000.0);
    float fineK = exp(-vDist / 900.0);
    vec3 col = mix(uRock, uGround, clamp(big * 1.5 - 0.15, 0.0, 1.0));
    col *= 0.72 + 0.30 * mix(0.5, mid, midK) + 0.34 * mix(0.5, fine, fineK);
    if(uOceans > 0.5 && big < uSeaLevel){
      float dep = smoothstep(uSeaLevel, uSeaLevel - 0.18, big);
      col = mix(col, uSea, dep * 0.92);
    }

    // Lambert against the local sun. uSunI carries the same irradiance the
    // DirectionalLight gives the vehicle, so the ground and the rocket standing
    // on it are lit by the same sun — without it the albedo is used as if the
    // incident flux were unity and the whole world comes out nearly black.
    // uSkyI is the diffuse skylight, which is the ONLY light on the night side
    // of a body with an atmosphere and is why a terminator is not a hard edge.
    // The 1/pi is not decoration: the vehicle standing on this ground is a
    // MeshStandardMaterial, whose Lambert BRDF is albedo/pi, and uSunI is the
    // same irradiance its DirectionalLight gets. Without it the ground is pi
    // times brighter than the rocket on it, which clips the terrain to a flat
    // glare and leaves nothing for the eye to judge the climb against.
    const float INV_PI = 0.3183099;
    float ndl = clamp(uSunDir.y, -0.2, 1.0);
    col *= INV_PI * (uSunI * max(ndl, 0.0) + uSkyI * (0.35 + 0.65 * clamp(uSunDir.y + 0.25, 0.0, 1.0)));

    // AERIAL PERSPECTIVE. The optical depth along a horizontal path is the
    // integral of the density, which for an exponential atmosphere seen from
    // altitude h is ρ(h)·distance — so the haze thins with height on the body's
    // own scale height with nothing extra to tune.
    float rho = uHasAir > 0.5 ? exp(-uEye / uScaleH) : 0.0;
    float tau = rho * uDensity * vDist;
    float fog = 1.0 - exp(-tau);
    col = mix(col, uHaze * (0.35 + 0.75 * max(ndl, 0.0)), clamp(fog, 0.0, 1.0));

    // The patch has to end somewhere; fade it out rather than showing an edge.
    float edge = 1.0 - smoothstep(0.86, 1.0, vDist / uPatch);
    if(edge <= 0.002) discard;
    gl_FragColor = vec4(col, edge);
  }`;

const SKY_VERT = `
  varying vec3 vDir;
  void main(){ vDir = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`;

const SKY_FRAG = `
  precision highp float;
  varying vec3 vDir;
  uniform vec3  uSunDir, uTint, uHaze;
  uniform float uEye, uScaleH, uHasAir, uThick;
  void main(){
    if(uHasAir < 0.5) discard;
    vec3 d = normalize(vDir);
    float up = clamp(d.y, -1.0, 1.0);
    // Column density along the line of sight, from a plane-parallel atmosphere
    // with the Kasten–Young-ish 1/(cos+eps) air mass. Saturating rather than
    // linear, so the horizon goes pale instead of blowing out.
    float rho = exp(-uEye / uScaleH);
    float airmass = 1.0 / max(up + 0.09, 0.06);
    float tau = rho * uThick * airmass;
    float scatter = 1.0 - exp(-tau);

    float cosT = dot(d, uSunDir);
    // Rayleigh phase, and a forward Mie lobe for the glare around the sun.
    float ray = 0.75 * (1.0 + cosT * cosT);
    float mie = pow(max(cosT, 0.0), 14.0);

    float sun = clamp(uSunDir.y * 2.0 + 0.25, 0.0, 1.0);
    vec3 col = uTint * ray * scatter * sun;
    col = mix(col, uHaze * scatter * sun, clamp(scatter * 1.3 - 0.25, 0.0, 1.0));
    col += vec3(1.0, 0.82, 0.60) * mie * scatter * sun * 1.6;
    // At sunrise/sunset the path through the atmosphere reddens what is left.
    col *= mix(vec3(1.0, 0.45, 0.22), vec3(1.0), clamp(uSunDir.y * 3.0 + 0.35, 0.0, 1.0));

    // Alpha is the coverage. It is deliberately much steeper than the scattered
    // radiance: the reason stars are invisible in daylight is not that the air
    // is opaque — the zenith optical depth is about 0.1 — but that the sky is
    // four orders of magnitude brighter than they are. With no adapted exposure
    // in this pass the only way to say that is to cover them, so the sky goes
    // fully opaque well before its optical depth would suggest, and thins back
    // out with altitude and at twilight exactly when the stars really do appear.
    float a = clamp(scatter * 3.2, 0.0, 1.0) * sun;
    // 0.85, not 1.5: the horizon term reaches uHaze·scatter ≈ (0.56, 0.71, 0.91)
    // on its own, and scaling that up put every channel past 1.0, where the tone
    // curve's shoulder flattens it to a featureless white band — which is also
    // what a white rocket in front of it has to be read against.
    gl_FragColor = vec4(col * 0.85, a);
  }`;

/**
 * Build the local-space scene. `sceneRadius` is how far the ground patch and the
 * sky dome extend in metres at their largest.
 */
export function createLocalView() {
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(55, 1, 0.05, 4.0e6);

  // Lights. A directional sun (parallel rays: the real thing is 1.5e11 m away),
  // a dim fill for the shadowed side, and a hemisphere term standing in for
  // light bounced off the planet — which is a large part of what actually lights
  // a spacecraft in low orbit.
  const sun = new THREE.DirectionalLight(0xfff4e2, 3.1);
  sun.position.set(0, 1, 0);
  scene.add(sun);
  const fill = new THREE.AmbientLight(0x223044, 0.30);
  scene.add(fill);
  const bounce = new THREE.HemisphereLight(0x8899aa, 0x33302c, 0.55);
  scene.add(bounce);

  // ---- ground
  const gGeo = new THREE.CircleGeometry(1, 128, 0, Math.PI * 2);
  // re-tessellate radially so there are rings, not one fan
  const rings = 90, segs = 128;
  const pos = [], idx = [];
  for (let r = 0; r <= rings; r++) {
    const u = r / rings;
    for (let s = 0; s < segs; s++) {
      const a = s / segs * Math.PI * 2;
      pos.push(Math.cos(a) * u, 0, Math.sin(a) * u);
    }
  }
  for (let r = 0; r < rings; r++) for (let s = 0; s < segs; s++) {
    const a = r * segs + s, b = r * segs + (s + 1) % segs;
    const c = (r + 1) * segs + s, d = (r + 1) * segs + (s + 1) % segs;
    idx.push(a, c, b, b, c, d);
  }
  const groundGeo = new THREE.BufferGeometry();
  groundGeo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  groundGeo.setIndex(idx);
  groundGeo.computeVertexNormals();
  gGeo.dispose();

  const groundU = {
    uRadius: { value: 6.371e6 }, uPatch: { value: 4e4 }, uEye: { value: 0 },
    uGround: { value: new THREE.Color(0x4a6b3f) }, uRock: { value: new THREE.Color(0x6b5a45) },
    uHaze: { value: new THREE.Color(0x8fb6e8) }, uSea: { value: new THREE.Color(0x1b3a6b) },
    uSunDir: { value: new THREE.Vector3(0, 1, 0) },
    uScaleH: { value: 8500 }, uDensity: { value: 2.4e-5 }, uHasAir: { value: 1 },
    uSeaLevel: { value: 0.42 }, uOceans: { value: 1 },
    uSunI: { value: 3.0 }, uSkyI: { value: 0.35 },
  };
  const ground = new THREE.Mesh(groundGeo, new THREE.ShaderMaterial({
    uniforms: groundU, vertexShader: GROUND_VERT, fragmentShader: GROUND_FRAG,
    transparent: true, depthWrite: true, side: THREE.DoubleSide,
  }));
  ground.frustumCulled = false;
  scene.add(ground);

  // ---- sky dome. Drawn after the ground with no depth write, so it tints the
  // ground near the horizon as well as filling the sky.
  const skyU = {
    uSunDir: { value: new THREE.Vector3(0, 1, 0) },
    uTint: { value: new THREE.Color(0x4a7fd0) }, uHaze: { value: new THREE.Color(0x8fb6e8) },
    uEye: { value: 0 }, uScaleH: { value: 8500 }, uHasAir: { value: 1 }, uThick: { value: 1.05 },
  };
  // The dome is depth-TESTED. It used to be drawn with depthTest off and a
  // renderOrder of −10, on the reasoning that it should be behind everything —
  // but three draws every opaque object before any transparent one, and
  // renderOrder only sorts within those lists. So the dome was drawn LAST, over
  // the top of the vehicle, at an alpha that reaches 1.0 near the horizon: the
  // rocket was there, fully lit, and then painted out by the sky in front of
  // it. That is the "washed out and see-through" launch.
  //
  // Its radius is larger than the ground patch can ever be (1.2e6) so the two
  // never intersect, and comfortably inside the camera's far plane.
  const sky = new THREE.Mesh(
    new THREE.SphereGeometry(3.0e6, 48, 28),
    new THREE.ShaderMaterial({
      uniforms: skyU, vertexShader: SKY_VERT, fragmentShader: SKY_FRAG,
      transparent: true, depthWrite: false, depthTest: true, side: THREE.BackSide,
    }));
  sky.frustumCulled = false;
  sky.renderOrder = -10;
  scene.add(sky);

  // Everything that belongs to the vehicle hangs off here, so the whole craft
  // can be swapped without touching the world.
  const craftRoot = new THREE.Group();
  scene.add(craftRoot);

  const _up = new THREE.Vector3(), _sun = new THREE.Vector3(), _e = new THREE.Vector3();

  return {
    scene, camera, sun, ground, sky, craftRoot,

    /**
     * Point the local world at the vehicle's actual situation.
     *
     * The local frame is defined so that +Y is the vehicle's local UP and the
     * origin is directly beneath it on the surface — which makes the ground
     * patch a flat sheet in this frame, and makes the vehicle's height above it
     * literally its altitude.
     */
    update({ env, altitude, sunDirWorld, upWorld, northWorld, starFlux }) {
      const hasAir = env.atm ? 1 : 0;
      const h = Math.max(altitude, 0);
      // Horizon distance √(2Rh), with a floor so there is always ground to see,
      // and a ceiling because past a few hundred km the orrery's own planet mesh
      // is the better picture.
      const horizon = Math.sqrt(2 * env.radius * Math.max(h, 3)) * 1.35;
      const patch = THREE.MathUtils.clamp(horizon, 2.5e4, 1.2e6);
      groundU.uPatch.value = patch;
      groundU.uRadius.value = env.radius;
      groundU.uEye.value = h;
      groundU.uHasAir.value = hasAir;
      groundU.uScaleH.value = env.atm ? scaleHeight(env.atm, h) : 1;
      groundU.uGround.value.setHex(env.ground);
      groundU.uRock.value.setHex(env.rock);
      groundU.uOceans.value = env.oceans ? 1 : 0;
      groundU.uSea.value.setHex(env.sea);
      if (env.atm) {
        groundU.uHaze.value.setHex(env.atm.haze);
        skyU.uTint.value.setHex(env.atm.tint);
        skyU.uHaze.value.setHex(env.atm.haze);
        skyU.uScaleH.value = scaleHeight(env.atm, h);
        // Optical thickness scaled off the body's surface density, so Mars gets
        // its thin butterscotch sky and Venus a wall of it, from one number.
        skyU.uThick.value = THREE.MathUtils.clamp(env.atm.rho0 * 0.9, 0.02, 6);
        groundU.uDensity.value = 2.6e-5 * THREE.MathUtils.clamp(env.atm.rho0, 0.02, 4);
      }
      skyU.uEye.value = h;
      skyU.uHasAir.value = hasAir;
      // Irradiance falls as 1/r² from the star; the local sun light and the
      // ground shader are driven from the same number so they cannot disagree.
      const flux = THREE.MathUtils.clamp(3.0 * (starFlux ?? 1), 0.05, 12);
      groundU.uSunI.value = flux;
      sun.intensity = flux;
      // Skylight only exists where there is air to scatter in.
      groundU.uSkyI.value = env.atm ? 0.42 * Math.exp(-h / Math.max(groundU.uScaleH.value * 2, 1)) : 0.03;
      // Ground fades out entirely once the orrery's planet takes over.
      ground.visible = h < 4.0e5;
      sky.visible = !!env.atm && h < (env.atm ? env.atm.top * 1.6 : 0);

      // Sun direction expressed in the local frame: its component along the
      // local up is what decides day, night and the colour of both.
      _up.copy(upWorld).normalize();
      const east = _e.crossVectors(_up, northWorld).normalize();
      const north = new THREE.Vector3().crossVectors(east, _up).normalize();
      _sun.set(sunDirWorld.dot(east), sunDirWorld.dot(_up), sunDirWorld.dot(north)).normalize();
      groundU.uSunDir.value.copy(_sun);
      skyU.uSunDir.value.copy(_sun);
      sun.position.copy(_sun).multiplyScalar(1e6);
      sun.target.position.set(0, 0, 0);
      // Planetshine: strong in low orbit over a bright planet, gone in deep space.
      bounce.intensity = THREE.MathUtils.clamp(0.75 * (1 - h / 8e5), 0.04, 0.75);
      return { east, north, up: _up.clone() };
    },

    setSize(w, h) {
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
    },

    dispose() {
      groundGeo.dispose(); ground.material.dispose();
      sky.geometry.dispose(); sky.material.dispose();
    },
  };
}

// ---------------------------------------------------------------------------
// THE FLIGHT CAMERA
// ----------------------------------------------------------------------------
// Three modes, and they exist because a launch, an orbit and a landing are
// looked at from completely different places:
//
//   CHASE   — behind and above, framing the vehicle against what it is flying
//             over. The distance follows the vehicle's own length, so a Saturn V
//             and a lunar module are both framed rather than one being a dot.
//   ORBIT   — a free turntable around the vehicle. This is the inspection mode.
//   COCKPIT — at the top of the stack looking along the thrust axis.
//   PAD     — fixed on the ground, watching it go. Only meaningful near a
//             surface, and it is the one that sells a launch.
// ---------------------------------------------------------------------------
export function createFlightCamera() {
  const state = {
    mode: 'chase', dist: 1, yaw: 2.2, pitch: 0.28, fov: 55, userAimed: false,
    padPos: new THREE.Vector3(), hasPad: false,
  };
  const _o = new THREE.Vector3(), _t = new THREE.Vector3(), _u = new THREE.Vector3();
  return {
    state,
    setMode(m) { state.mode = m; },
    /** @param craftPos local-frame position of the vehicle (m) */
    update(camera, { craftPos, craftQuat, length, up, velocity, dt, sunLocal }) {
      const L = Math.max(length, 3);
      if (state.mode === 'pad' && state.hasPad) {
        camera.position.copy(state.padPos);
        camera.up.copy(up);
        // Aim at the middle of the stack, not at its base. craftPos is the
        // vehicle's ORIGIN, which is where the engine bells are — pointing the
        // camera there puts the whole vehicle above the centre line and runs
        // most of it off the top of the frame.
        _t.copy(craftPos).addScaledVector(up, L * 0.45);
        camera.lookAt(_t);
        return;
      }
      if (state.mode === 'cockpit') {
        _u.set(0, 1, 0).applyQuaternion(craftQuat);
        camera.position.copy(craftPos).addScaledVector(_u, L * 0.52);
        _t.copy(camera.position).addScaledVector(_u, L);
        camera.up.copy(up);
        camera.lookAt(_t);
        return;
      }
      // chase / orbit share a turntable; chase keeps the vehicle's own up.
      const d = state.dist * L;
      // Basis from the vehicle's own axis, so the camera rolls with it in chase
      // mode and stays world-locked in orbit mode.
      _u.copy(state.mode === 'chase' ? _u.set(0, 1, 0).applyQuaternion(craftQuat) : up).normalize();
      const ref = Math.abs(_u.y) > 0.95 ? _o.set(1, 0, 0) : _o.set(0, 1, 0);
      const right = new THREE.Vector3().crossVectors(_u, ref).normalize();
      const fwd = new THREE.Vector3().crossVectors(right, _u).normalize();
      // Until the viewer takes the turntable themselves, stand on the SUNLIT
      // side. A vehicle photographed from its own shadow is a silhouette, and a
      // silhouette of a white rocket against a bright sky is the one thing that
      // makes all this modelling invisible. Eased rather than snapped, because
      // the sun's bearing swings as the vehicle flies round the planet.
      if (sunLocal && !state.userAimed) {
        const want = Math.atan2(sunLocal.dot(fwd), sunLocal.dot(right));
        let e = want - state.yaw;
        e = Math.atan2(Math.sin(e), Math.cos(e));      // shortest way round
        state.yaw += e * (1 - Math.exp(-Math.max(dt, 0) * 1.2));
      }
      const cy2 = Math.cos(state.yaw), sy2 = Math.sin(state.yaw);
      const cp2 = Math.cos(state.pitch), sp2 = Math.sin(state.pitch);
      camera.position.copy(craftPos)
        .addScaledVector(right, d * cp2 * cy2)
        .addScaledVector(fwd, d * cp2 * sy2)
        .addScaledVector(_u, d * sp2);
      camera.up.copy(_u);
      camera.lookAt(craftPos);
    },
  };
}
