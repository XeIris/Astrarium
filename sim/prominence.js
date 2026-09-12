import * as THREE from 'three';

// ============================================================================
// PROMINENCES, FILAMENTS AND THE POST-FLARE ARCADE
// ----------------------------------------------------------------------------
// What used to stand over an erupting active region here was a single tube
// swept along one cubic Bezier: a smooth semicircular arch of uniform
// thickness and uniform colour. Nothing about a real eruption is like that,
// and the differences are not stylistic:
//
//   · PLASMA IS TIED TO FIELD LINES. Coronal gas has a plasma beta far below
//     one, so it cannot cross the magnetic field — it can only slide along it.
//     What you see is therefore a bundle of THREADS, each one a separate flux
//     tube lit up along its own length, not a single solid body. The threading
//     is the texture, and one tube cannot have it.
//
//   · A FLARE MAKES AN ARCADE, NOT AN ARCH. Reconnection proceeds along a
//     magnetic neutral line and works its way upward, so the loops come in a
//     row — dozens of them, anchored in two parallel ribbons, each rooted a
//     little further along and each taller than the last. That row is the
//     single most recognisable thing in any EUV image of a flare.
//
//   · THE ARCADE IS SHEARED, AND THAT SHEAR IS THE ENERGY. A potential field
//     has its loops square across the neutral line and stores nothing. The
//     free energy that a flare releases is exactly the energy of the shear, so
//     a pre-flare arcade is strongly skewed and a post-flare one has relaxed
//     back toward square. Drawing loops perpendicular to the neutral line is
//     drawing a field with nothing to release.
//
//   · A BIPOLE IS NOT ORIENTED AT RANDOM. Hale's polarity law and JOY'S LAW:
//     active regions are bipolar, aligned very nearly east-west, with a tilt
//     that grows with latitude — roughly half the latitude, leading polarity
//     equatorward. So the neutral line runs nearly north-south, tipped a
//     little, and every arcade on a given star leans the same way in a given
//     hemisphere. See createArcade's caller in sim/star_visual.js.
//
//   · ON THE DISC IT IS DARK. The same cool, dense material that glows as a
//     bright PROMINENCE off the limb is seen in absorption against the
//     photosphere behind it, where it is called a FILAMENT — it is the same
//     object, and which one you are looking at depends only on where it is.
//     That is why this file draws the arcade twice, once in emission and once
//     in absorption, each discarding where the other applies.
//
//   · THE FOOTPOINTS ARE THE BRIGHT PART. Particles accelerated at the
//     reconnection site stream down the legs and dump their energy where the
//     density rises, so a flaring loop is brightest at its feet and thin and
//     tenuous at its apex, and material condenses and drains back down the
//     legs afterwards as coronal rain.
//
// Geometry is generated in the VERTEX SHADER from a parametric field line, so
// the whole arcade can rise, stretch, shear and untwist over the course of an
// eruption without a single buffer being rewritten.
// ============================================================================

const THREADS = 22;     // flux tubes across the arcade
const SEGS = 44;        // samples along each

// aThread: -1..1 across the arcade   aS: 0..1 along the loop
// aSide:   -1/+1 ribbon edge         aSeed: per-thread randomiser
//
// ONE buffer, shared by every arcade on every star in the scene. It carries no
// shape at all — the shape is entirely in the vertex shader, and two arcades
// differ only by their uniforms — so allocating a copy per flare slot per star
// would be megabytes of identical parameter values. It is never disposed for
// the same reason: it outlives any one star.
let _geo = null;
function arcadeGeometry() {
  if (_geo) return _geo;
  const verts = THREADS * (SEGS + 1) * 2;
  const aThread = new Float32Array(verts);
  const aS = new Float32Array(verts);
  const aSide = new Float32Array(verts);
  const aSeed = new Float32Array(verts);
  const pos = new Float32Array(verts * 3);      // unused; the shader builds it
  const index = [];
  let v = 0;
  for (let t = 0; t < THREADS; t++) {
    const k = THREADS === 1 ? 0 : (t / (THREADS - 1)) * 2 - 1;
    const seed = t * 0.6180339887;
    const base = v;
    for (let s = 0; s <= SEGS; s++) {
      for (let side = 0; side < 2; side++) {
        aThread[v] = k; aS[v] = s / SEGS; aSide[v] = side * 2 - 1; aSeed[v] = seed;
        v++;
      }
    }
    for (let s = 0; s < SEGS; s++) {
      const a = base + s * 2;
      index.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
    }
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  geo.setAttribute('aThread', new THREE.BufferAttribute(aThread, 1));
  geo.setAttribute('aS', new THREE.BufferAttribute(aS, 1));
  geo.setAttribute('aSide', new THREE.BufferAttribute(aSide, 1));
  geo.setAttribute('aSeed', new THREE.BufferAttribute(aSeed, 1));
  geo.setIndex(index);
  _geo = geo;
  return geo;
}

// ---------------------------------------------------------------------------
// The field line. Local frame: +Y is the local vertical, +Z the bipole axis
// (so the footpoints separate along Z), +X the neutral line (so the arcade
// extends along X). Lengths in X and Z are tangent-plane offsets in stellar
// radii; Y is a RADIAL height, also in stellar radii, and onSphere() turns the
// triple into a point on or above the actual sphere — which is what keeps the
// footpoints welded to the surface instead of hovering over it on a big star.
// ---------------------------------------------------------------------------
const LINE_GLSL = `
  uniform float uR, uSpan, uLen, uHeight, uShear, uTwist, uErupt, uWidth, uTime, uMode;

  float h1(float x){ return fract(sin(x * 127.1) * 43758.5453); }

  vec3 fieldLine(float s, float k, float seed){
    float taper = sqrt(max(1.0 - k * k, 0.0));
    // Loops near the ends of the arcade are shorter and lower: the neutral
    // line has ends, and the field closes down at them.
    float w = uSpan  * (0.42 + 0.58 * taper) * (0.85 + 0.30 * h1(seed));
    float h = uHeight * pow(max(taper, 1e-3), 0.55) * (0.50 + 1.05 * h1(seed + 3.1));
    // The eruption: the rope rises and stretches, faster than it widens.
    h *= 1.0 + uErupt * 2.8;
    w *= 1.0 + uErupt * 0.65;

    float th = 3.14159265 * s;
    float z = -w * cos(th);
    float y =  h * sin(th);
    // SHEAR: the apex is displaced ALONG the neutral line relative to the
    // feet. This is the stored free energy, and it relaxes as the flare
    // proceeds (the caller winds uShear down).
    // The threads are also jittered off their nominal spacing — evenly spaced
    // identical loops read as a comb, and a comb is the one thing an arcade
    // never looks like.
    // The arcade also SPLAYS as it erupts: the rope expands sideways as it
    // rises, so the threads fan apart instead of climbing in parallel.
    float x = (k + (h1(seed + 2.2) - 0.5) * 0.16) * uLen * (1.0 + uErupt * 0.9)
            + uShear * uSpan * sin(th);

    // TWIST: a flux rope is braided, and the braid tightens as it erupts.
    float ph = 6.2831853 * (uTwist * s + seed * 3.7);
    float amp = 0.055 * uSpan * (0.35 + uErupt);
    x += amp * cos(ph);
    y += amp * sin(ph) * 0.55;
    // and every thread sags differently under its own weight
    y -= 0.06 * uSpan * sin(th) * (h1(seed + 7.7) - 0.35);
    return vec3(x, y, z);
  }

  // Tangent offsets to a real point above a real sphere. The star's centre is
  // at (0, -uR, 0) in this frame.
  vec3 onSphere(vec3 p){
    vec3 dir = normalize(vec3(p.x, 1.0, p.z));
    return dir * (uR * (1.0 + p.y)) - vec3(0.0, uR, 0.0);
  }`;

const ARC_VERT = `
  attribute float aThread; attribute float aS; attribute float aSide; attribute float aSeed;
  varying float vS; varying float vSide; varying float vThread; varying float vSeed;
  varying vec3 vVP; varying vec3 vCV;
  ${LINE_GLSL}
  void main(){
    vS = aS; vSide = aSide; vThread = aThread; vSeed = aSeed;
    vec3 a = onSphere(fieldLine(aS, aThread, aSeed));
    vec3 b = onSphere(fieldLine(min(aS + 0.015, 1.0), aThread, aSeed));
    vec4 mv = modelViewMatrix * vec4(a, 1.0);
    vec4 mv2 = modelViewMatrix * vec4(b, 1.0);
    // Ribbon: widen perpendicular to the loop AND to the line of sight, so a
    // thread is the same apparent thickness whichever way it runs. Done in
    // view space, which is camera-relative and therefore float-safe at the
    // distances this sim works at.
    vec3 tv = normalize(mv2.xyz - mv.xyz + vec3(1e-9));
    vec3 side = normalize(cross(tv, normalize(-mv.xyz)));
    float w = uWidth * uR * (0.55 + 0.9 * h1(aSeed + 1.3));
    // a loop is fatter at its apex, where the field has spread out
    w *= 0.7 + 0.6 * sin(3.14159265 * aS);
    // In ABSORPTION the threads are drawn fatter so they overlap into one
    // coherent dark spine. A filament on the disc is a single sinuous ribbon,
    // not a row of separate scratches — the threading is only resolvable off
    // the limb, where it is seen against the sky rather than through the
    // column of everything in front of it.
    w *= mix(1.0, 1.7, step(0.5, uMode));
    mv.xyz += side * (aSide * w);
    vVP = mv.xyz;
    vCV = (modelViewMatrix * vec4(0.0, -uR, 0.0, 1.0)).xyz;
    gl_Position = projectionMatrix * mv;
  }`;

const ARC_FRAG = `
  precision highp float;
  uniform vec3 uCool, uHot;
  uniform float uAmp, uMode, uPlasmaT;
  uniform float uR, uSpan, uLen, uHeight, uShear, uTwist, uErupt, uWidth, uTime;
  varying float vS; varying float vSide; varying float vThread; varying float vSeed;
  varying vec3 vVP; varying vec3 vCV;

  float h2(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
  float n2(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
    return mix(mix(h2(i), h2(i+vec2(1,0)), f.x), mix(h2(i+vec2(0,1)), h2(i+vec2(1,1)), f.x), f.y); }
  float fbm2(vec2 p){ float v=0.0, a=0.5; for(int i=0;i<4;i++){ v+=a*n2(p); p*=2.1; a*=0.5; } return v; }

  void main(){
    // Optically thin thread: a soft Gaussian across, so the edges of a loop
    // are limb-brightened the way a hollow tube of emitting gas is.
    float prof = exp(-vSide * vSide * 2.7);
    // No two flux tubes carry the same amount of plasma.
    float tw = 0.45 + 1.05 * h2(vec2(vSeed * 31.0, 7.3));

    // Brightest at the feet. Particles accelerated at the reconnection site
    // run down the legs and stop where the density rises, which is why a
    // flaring loop has bright footpoints and a faint apex.
    float fp = exp(-vS * 5.5) + exp(-(1.0 - vS) * 5.5);

    // Coronal rain: condensations sliding back down both legs.
    float dir = vS < 0.5 ? -1.0 : 1.0;
    float rain = 0.55 + 0.75 * fbm2(vec2(vS * 9.0 + dir * uTime * 0.55, vThread * 5.0 + vSeed * 17.0));

    // Reconnection walks ALONG the neutral line, so the arcade does not light
    // up all at once — each loop in the row brightens a little after its
    // neighbour.
    float stagger = clamp(uAmp * 1.6 - abs(vThread) * 0.55, 0.0, 1.0);

    float a = prof * (0.30 + 0.70 * fp) * rain * stagger * tw;
    // An erupting loop drains: the legs stay lit and the apex thins out and
    // goes, which is why a filament eruption looks like it is being pulled
    // apart rather than lifted off in one piece.
    a *= mix(1.0, 0.30 + 0.70 * abs(vS * 2.0 - 1.0), clamp(uErupt * 0.8, 0.0, 1.0));

    // Hot where the beam lands, cool prominence material higher up.
    vec3 col = mix(uCool, uHot, clamp(fp * 0.75 + uErupt * 0.35, 0.0, 1.0));

    // --- filament or prominence? The same material, and the only difference
    // is whether the photosphere is behind it. vCV is the star's centre in
    // view space, so the perpendicular distance from the line of sight to the
    // centre says whether this point projects inside the disc.
    vec3 n = normalize(vCV);
    float perp = length(vVP - n * dot(vVP, n));
    float onDisc = 1.0 - smoothstep(uR * 0.96, uR * 1.02, perp);

    if(uMode < 0.5){
      a *= 1.0 - onDisc;
      if(a < 0.004) discard;
      // Published temperature, log-encoded, for sim/spectrum.js. Flare plasma
      // reaches 10^7 K, which is precisely why a flare is an X-RAY source and
      // barely a visible-light one — so this is what makes an eruption show up
      // in the X-ray band as the brightest thing on the star. The alpha
      // channel is written rather than accumulated (see the blend mode), or
      // adding it to the photosphere's own published value would destroy both.
      gl_FragColor = vec4(col * a * 1.7, clamp(log(max(uPlasmaT, 1.0)) / 25.33, 0.0, 0.98));
    } else {
      // A filament is darkest where the column through it is longest, which is
      // along its spine and at its top — the footpoint brightening belongs to
      // emission, not to absorption.
      a *= onDisc * (1.0 - 0.45 * fp);
      if(a < 0.010) discard;
      // In absorption the filament is dark and slightly red — it is cool
      // material in front of a hot continuum, not a shadow, so it never goes
      // fully black.
      gl_FragColor = vec4(uCool * 0.18, clamp(a * 0.55, 0.0, 0.80));
    }
  }`;

function arcadeMaterial(cool, hot, mode) {
  const m = new THREE.ShaderMaterial({
    uniforms: {
      uR: { value: 1 }, uSpan: { value: 0.22 }, uLen: { value: 0.30 },
      uHeight: { value: 0.34 }, uShear: { value: 0.5 }, uTwist: { value: 0.6 },
      uErupt: { value: 0 }, uWidth: { value: 0.012 }, uTime: { value: 0 },
      uAmp: { value: 0 }, uMode: { value: mode }, uPlasmaT: { value: 1.2e7 },
      uCool: { value: cool.clone() }, uHot: { value: hot.clone() },
    },
    vertexShader: ARC_VERT,
    fragmentShader: ARC_FRAG,
    transparent: true, depthWrite: false, side: THREE.DoubleSide,
    blending: THREE.CustomBlending,
    blendEquation: THREE.AddEquation,
  });
  if (mode < 0.5) {
    // Additive colour, but alpha REPLACED rather than summed: alpha is not
    // opacity in this renderer, it is the published temperature channel that
    // sim/spectrum.js images the frame from.
    m.blendSrc = THREE.OneFactor; m.blendDst = THREE.OneFactor;
    m.blendSrcAlpha = THREE.OneFactor; m.blendDstAlpha = THREE.ZeroFactor;
  } else {
    // Ordinary over-compositing for the dark filament, but LEAVING the alpha
    // channel alone: the photosphere behind it has already published its own
    // temperature there and a filament does not change what band the pixel
    // should be imaged in.
    m.blendSrc = THREE.SrcAlphaFactor; m.blendDst = THREE.OneMinusSrcAlphaFactor;
    m.blendSrcAlpha = THREE.ZeroFactor; m.blendDstAlpha = THREE.OneFactor;
  }
  m.blendEquationAlpha = THREE.AddEquation;
  return m;
}

// ---------------------------------------------------------------------------
// One arcade: a group carrying the same geometry twice, once in emission and
// once in absorption. Place and orient the group so +Y is the local vertical
// and +Z the bipole axis, then drive it with set().
// ---------------------------------------------------------------------------
export function createArcade(cool, hot) {
  const geo = arcadeGeometry();
  const emitMat = arcadeMaterial(cool, hot, 0);
  const absMat = arcadeMaterial(cool, hot, 1);
  const group = new THREE.Group();
  for (const mat of [emitMat, absMat]) {
    const mesh = new THREE.Mesh(geo, mat);
    mesh.frustumCulled = false;     // the shader, not the buffer, has the shape
    group.add(mesh);
  }
  group.visible = false;

  return {
    group, geo, emitMat, absMat,
    set(p) {
      for (const m of [emitMat, absMat]) {
        const u = m.uniforms;
        u.uR.value = p.R;
        u.uSpan.value = p.span;
        u.uLen.value = p.len;
        u.uHeight.value = p.height;
        u.uShear.value = p.shear;
        u.uTwist.value = p.twist;
        u.uErupt.value = p.erupt;
        u.uWidth.value = p.width;
        u.uAmp.value = p.amp;
        u.uPlasmaT.value = p.plasmaT;
        u.uTime.value += p.dt;
      }
    },
    // the geometry is shared and outlives this arcade; only the materials go
    dispose() { emitMat.dispose(); absMat.dispose(); },
  };
}

export { THREADS, SEGS };
