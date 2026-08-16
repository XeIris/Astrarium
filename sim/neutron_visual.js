import * as THREE from 'three';

// ============================================================================
// NEUTRON STAR
// ----------------------------------------------------------------------------
// A neutron star is a ~12 km sphere with the mass of the Sun, a surface at
// ~10⁶ K, and a magnetic field of 10⁸–10¹⁵ gauss. Almost every visually
// interesting thing about it is a consequence of one of those three numbers,
// and none of them are served by a white ball with two cones stuck on it.
//
// WHAT IS MODELLED
//
//  · Colour from temperature. At ~10⁶ K the Planck peak is deep in the soft
//    X-ray; the visible tail is the Rayleigh–Jeans slope, which is why the few
//    optically detected neutron stars (RX J1856−3754 and friends) look faint
//    blue-white rather than "hot orange". The surface is therefore a saturated
//    blue-white driven far above 1.0 so the tone mapper clips its core to pure
//    white while the limb keeps its colour.
//
//  · Its own gravitational lensing. R ≈ 2.5 r_s here, so the star bends the
//    light leaving it hard enough that you see well past the geometric limb.
//    The exact Schwarzschild relation for the visible colatitude is
//        cos ψ = 1 − (1 − μ)/(1 − r_s/R)
//    where μ is the cosine on the apparent disc. At r_s/R = 0.4 the limb
//    (μ = 0) maps to ψ ≈ 132°, so roughly 60% of the surface is visible at
//    once instead of 50% — and a hot polar cap stays in view for far more of
//    the rotation than naive geometry allows.
//
//  · Magnetic polar caps. The field funnels returning particles onto two small
//    caps around the magnetic axis, which run hotter than the rest of the
//    surface. They are the actual source of the pulse.
//
//  · A misaligned dipole. The magnetic axis is tilted from the spin axis, so
//    the caps and their beams sweep — the lighthouse. The observed pulse is
//    sharpened by relativistic beaming from the co-rotating magnetosphere, so
//    the flash is a narrow spike rather than a slow sinusoid.
//
//  · Dipole field lines, r = r₀·sin²θ, drawn as glowing tubes. This is the real
//    shape of the closed magnetosphere and it is what actually reads as
//    "neutron star" at a glance.
//
//  · Hollow radio/X-ray beams. Emission comes from a cone WALL near the last
//    open field lines, not from a filled cone, so the beams are rendered as
//    bright-edged hollow shells with filamentary structure.
// ============================================================================

const SURF_VERT = `
  varying vec3 vObj; varying vec3 vWN; varying vec3 vWP;
  void main(){
    vObj = normalize(position);
    vWN  = normalize(mat3(modelMatrix) * normal);
    vec4 wp = modelMatrix * vec4(position, 1.0);
    vWP = wp.xyz;
    gl_Position = projectionMatrix * viewMatrix * wp;
  }`;

const SURF_FRAG = `
  precision highp float;
  uniform float uTime, uGain, uCompact, uCapGlow, uTeffK;
  uniform vec3  uColor, uCapColor, uMagAxis;
  varying vec3 vObj; varying vec3 vWN; varying vec3 vWP;

  float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1, 113.5, 7.9))) * 43758.5453); }
  float noise(vec3 p){
    vec3 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash(i), hash(i+vec3(1,0,0)), f.x), mix(hash(i+vec3(0,1,0)), hash(i+vec3(1,1,0)), f.x), f.y),
               mix(mix(hash(i+vec3(0,0,1)), hash(i+vec3(1,0,1)), f.x), mix(hash(i+vec3(0,1,1)), hash(i+vec3(1,1,1)), f.x), f.y), f.z);
  }
  float fbm(vec3 p){ float v=0.0,a=0.5; for(int i=0;i<4;i++){ v+=a*noise(p); p*=2.11; a*=0.5; } return v; }

  void main(){
    vec3 V  = normalize(cameraPosition - vWP);
    vec3 N  = normalize(vWN);
    float mu = clamp(dot(N, V), 0.0, 1.0);

    // --- gravitational self-lensing.
    // cos(psi) = 1 - (1 - mu) / (1 - rs/R).  uCompact = rs/R.
    // Points on the apparent disc map back to a LARGER colatitude than they
    // would in flat space, which is how the far side comes into view.
    float cosPsi = 1.0 - (1.0 - mu) / max(1.0 - uCompact, 0.05);
    cosPsi = clamp(cosPsi, -1.0, 1.0);

    // Rebuild the true surface direction: keep the object-space azimuth around
    // the view axis, but replace the colatitude with the lensed one.
    vec3 tangential = normalize(vObj - dot(vObj, V) * V + vec3(1e-6));
    vec3 pTrue = normalize(V * cosPsi + tangential * sqrt(max(1.0 - cosPsi * cosPsi, 0.0)));

    // --- surface: a smooth degenerate crust. Almost featureless — it is
    // crushed to nuclear density and about as flat as anything in nature —
    // so only a faint mottling from field-line footprints.
    float mot = fbm(pTrue * 9.0 + uTime * 0.05);
    float base = 0.85 + mot * 0.30;

    // --- hot magnetic caps around ±magnetic axis
    float capA = dot(pTrue,  normalize(uMagAxis));
    float cap  = smoothstep(0.80, 0.985, abs(capA));
    // ragged rim where the open field lines end
    cap *= 0.7 + 0.6 * fbm(pTrue * 22.0 + uTime * 0.6);

    vec3 col = uColor * base;
    col += uCapColor * cap * (2.2 + uCapGlow * 5.0);

    // --- limb darkening. Hot, mostly-scattering atmosphere: shallow law.
    col *= 1.0 - 0.35 * (1.0 - mu);

    // --- the lensed rim. Light from the far side piles up into a bright
    // ring right at the apparent edge, which is a real signature of a compact
    // enough object and the thing that makes it read as *dense*.
    float rim = pow(1.0 - mu, 3.5);
    col += uColor * rim * 2.6;

    // alpha = log-encoded surface temperature (~10⁶ K) for sim/spectrum.js.
    // This is why a neutron star is the one thing in the sim that blazes in
    // the X-ray band while every star in the field goes black.
    gl_FragColor = vec4(col * uGain, clamp(log(max(uTeffK, 1.0)) / 25.33, 0.0, 0.98));
  }`;

// Hollow, filamentary emission cone along +Y of its own frame.
const BEAM_FRAG = `
  precision highp float;
  uniform vec3  uColor;
  uniform float uAlpha, uTime, uOpen;
  varying vec3 vObj; varying float vAxial;

  float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float noise(vec2 p){
    vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i+vec2(1,0)), f.x), mix(hash(i+vec2(0,1)), hash(i+vec2(1,1)), f.x), f.y);
  }
  float fbm(vec2 p){ float v=0.0,a=0.5; for(int i=0;i<4;i++){ v+=a*noise(p); p*=2.2; a*=0.5; } return v; }

  void main(){
    // radial position across the cone wall, 0 = axis, 1 = mouth
    float rr = length(vObj.xz) / max(uOpen, 1e-3);

    // HOLLOW: emission comes from the last open field lines, so the wall is
    // bright and the axis is comparatively empty.
    float wall = exp(-pow((rr - 0.72) / 0.30, 2.0));
    wall += exp(-pow(rr / 0.55, 2.0)) * 0.22;

    // filamentary structure streaming outward along the beam
    float ang = atan(vObj.z, vObj.x);
    float fil = 0.45 + 0.75 * fbm(vec2(ang * 3.5, vAxial * 4.0 - uTime * 1.8));

    // fade out along the length — the beam is not a solid rod
    float fall = exp(-vAxial * 1.9) * smoothstep(0.0, 0.06, vAxial);

    float a = wall * fil * fall * uAlpha;
    gl_FragColor = vec4(uColor * a * 2.4, a * 0.75);
  }`;

const BEAM_VERT = `
  varying vec3 vObj; varying float vAxial;
  uniform float uLength;
  void main(){
    vObj = position;
    vAxial = clamp(position.y / max(uLength, 1e-4), 0.0, 1.0);
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }`;

// Field lines glow from the plasma trapped on them, which is densest close to
// the star. A flat additive tube lands in a uniform mid-grey and reads as a
// plastic pipe; brightness falling as 1/r makes the same geometry read as
// something luminous, brilliant at the poles and fading into the dark.
const FIELD_VERT = `
  uniform float uR;
  varying float vFall;
  void main(){
    vec4 wp = modelMatrix * vec4(position, 1.0);
    // the attribute is already in the dipole's own frame, centred on the star,
    // so its length is the distance from the centre in scene units.
    float rr = length(position) / max(uR, 1e-5);
    vFall = 1.0 / (0.25 + rr * rr * 0.55);
    gl_Position = projectionMatrix * viewMatrix * wp;
  }`;

const FIELD_FRAG = `
  precision highp float;
  uniform vec3 uColor; uniform float uAlpha;
  varying float vFall;
  void main(){
    float a = clamp(vFall * uAlpha, 0.0, 6.0);
    gl_FragColor = vec4(uColor * a, min(a, 1.0));
  }`;

// A closed dipole field line: r = r0·sin²θ, swept from one pole to the other.
function fieldLineGeometry(R, r0, segments = 48) {
  const pts = [];
  for (let i = 0; i <= segments; i++) {
    const th = (i / segments) * Math.PI;
    const s = Math.sin(th);
    const r = r0 * s * s;
    if (r < R * 0.98) continue;                 // clip where it enters the crust
    pts.push(new THREE.Vector3(r * s, r * Math.cos(th), 0));
  }
  if (pts.length < 2) return null;
  return new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts), 40, R * 0.010, 5, false);
}

export function createNeutronVisual(b, opts) {
  const g = new THREE.Group();
  const R = opts.radiusScene;

  // r_s/R for a real neutron star: r_s ≈ 4.1 km per M☉, R ≈ 12 km ⇒ ~0.4 at
  // 1.4 M☉. Taken from the body's own numbers when they exist.
  const compact = THREE.MathUtils.clamp(
    (b.rs ?? 0) > 0 && (b.radius ?? 0) > 0 ? b.rs / b.radius : 0.4, 0.15, 0.65);

  // ~10⁶ K: we are on the Rayleigh–Jeans tail, so a hard blue-white.
  const surfColor = new THREE.Color(0.30, 0.52, 1.0);
  const capColor  = new THREE.Color(0.80, 0.90, 1.0);
  const magColor  = new THREE.Color(0.45, 0.72, 1.0);

  const magAxisVec = new THREE.Vector3(Math.sin(0.55), Math.cos(0.55), 0).normalize();

  const surfMat = new THREE.ShaderMaterial({
    uniforms: {
      uTime: { value: 0 },
      // Bright enough that the caps and the lensed rim clip to white, but not
      // so bright that the whole disc does — the blue-white of the crust has to
      // survive tone mapping or the star is just a lamp again.
      uGain: { value: 1.35 },
      uCompact: { value: compact },
      uCapGlow: { value: 0 },
      uTeffK: { value: 1.0e6 },     // typical young neutron-star surface
      uColor: { value: surfColor.clone() },
      uCapColor: { value: capColor.clone() },
      uMagAxis: { value: magAxisVec.clone() },
    },
    vertexShader: SURF_VERT,
    fragmentShader: SURF_FRAG,
  });
  const core = new THREE.Mesh(new THREE.SphereGeometry(R, 48, 36), surfMat);
  g.add(core);

  // --- spin axis → tilted magnetic axis (the misaligned dipole)
  const spinAxis = new THREE.Group();
  g.add(spinAxis);
  const magAxis = new THREE.Group();
  magAxis.rotation.z = 0.55;
  spinAxis.add(magAxis);

  // --- closed magnetosphere: dipole field lines around the magnetic axis
  const fieldMat = new THREE.ShaderMaterial({
    uniforms: {
      uColor: { value: magColor.clone() },
      uAlpha: { value: 0.6 },
      uR: { value: R },
    },
    vertexShader: FIELD_VERT,
    fragmentShader: FIELD_FRAG,
    transparent: true, blending: THREE.AdditiveBlending, depthWrite: false,
  });
  const fieldLines = new THREE.Group();
  for (let shell = 0; shell < 3; shell++) {
    const r0 = R * (2.6 + shell * 2.1);
    const geo = fieldLineGeometry(R, r0);
    if (!geo) continue;
    for (let i = 0; i < 5; i++) {
      const line = new THREE.Mesh(geo, fieldMat);
      line.rotation.y = (i / 5) * Math.PI * 2 + shell * 0.4;
      fieldLines.add(line);
    }
  }
  magAxis.add(fieldLines);

  // --- the two beams
  const beamLen = R * 16;
  const beamOpen = beamLen * 0.30;
  const beams = [];
  for (const s of [1, -1]) {
    const mat = new THREE.ShaderMaterial({
      uniforms: {
        uColor: { value: magColor.clone() },
        uAlpha: { value: 0.45 },
        uTime: { value: 0 },
        uOpen: { value: beamOpen },
        uLength: { value: beamLen },
      },
      vertexShader: BEAM_VERT,
      fragmentShader: BEAM_FRAG,
      transparent: true, blending: THREE.AdditiveBlending,
      depthWrite: false, side: THREE.DoubleSide,
    });
    const cone = new THREE.Mesh(
      new THREE.ConeGeometry(beamOpen, beamLen, 40, 24, true), mat);
    // ConeGeometry is centred on the origin with its apex at +Y; move the apex
    // to the star and point the mouth outward.
    cone.geometry.translate(0, -beamLen / 2, 0);
    cone.geometry.scale(1, -1, 1);
    cone.rotation.x = s > 0 ? 0 : Math.PI;
    magAxis.add(cone);
    beams.push(mat);
  }

  b.spin = b.spin ?? (8 + Math.random() * 20);

  const _beamDir = new THREE.Vector3();
  const _toCam = new THREE.Vector3();
  const _wq = new THREE.Quaternion();
  const _wp = new THREE.Vector3();

  b.viz = { group: g, core, spinAxis, magAxis, baseR: R, R, isNeutron: true };
  b.viz.update = (dt, ctx) => {
    surfMat.uniforms.uTime.value += dt;
    spinAxis.rotation.y += b.spin * dt;

    // keep the shader's cap axis in sync with the rotating dipole, in the
    // body's own object space
    magAxis.getWorldQuaternion(_wq);
    _beamDir.set(0, 1, 0).applyQuaternion(_wq);
    surfMat.uniforms.uMagAxis.value.copy(_beamDir)
      .applyQuaternion(g.getWorldQuaternion(new THREE.Quaternion()).invert());

    // --- the lighthouse. Relativistic beaming from the co-rotating
    // magnetosphere concentrates the emission into a narrow forward lobe, so
    // the observed pulse is a sharp spike, not a sinusoid.
    g.getWorldPosition(_wp);
    _toCam.copy(ctx.camera.position).sub(_wp).normalize();
    const align = Math.abs(_beamDir.dot(_toCam));
    const flash = Math.pow(align, 14.0);

    surfMat.uniforms.uCapGlow.value = flash;
    for (const m of beams) {
      m.uniforms.uTime.value += dt;
      m.uniforms.uAlpha.value = 0.35 + flash * 1.5;
    }
    fieldMat.uniforms.uAlpha.value = 0.5 + flash * 0.9;
  };

  return b.viz;
}
