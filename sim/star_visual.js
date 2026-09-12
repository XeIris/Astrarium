import * as THREE from 'three';
import { ActivityModel, blackbodyColor, coronaColor, rotationRate } from './stellar.js';
import { granuleFrequency, surfaceBrightness } from './structure.js';
import { createArcade } from './prominence.js';

// ============================================================================
// HIGH-FIDELITY STAR RENDERING
// ----------------------------------------------------------------------------
// The photosphere shader models, in one pass:
//   · granulation — convective cells, two octaves of fBm advected in time
//   · differential rotation — the equator laps the poles (real: Sun 25 d vs 34 d)
//   · starspots — dark umbra + warm penumbra + bright surrounding faculae,
//     placed at the ActivityModel's live active regions
//   · flare ribbons — the TWO ribbons that straddle a flare's neutral line
//     and separate as reconnection climbs (see sim/prominence.js)
//   · limb darkening — the physically correct I(μ)/I(0) = 1 − u(1 − μ) law
//   · a chromospheric H-α rim glowing just past the limb
// Everything is driven by mass → Teff → colour, so an M dwarf and a B star look
// genuinely different rather than being recoloured copies.
// ============================================================================

// Smoothstep on the CPU side, for driving the eruption timeline.
function smoothstep01(a, b, x) {
  const t = Math.min(Math.max((x - a) / (b - a), 0), 1);
  return t * t * (3 - 2 * t);
}

const MAX_SPOTS = 8;
const MAX_FLARES = 4;

function photosphereMaterial(color, hotColor, limbU) {
  return new THREE.ShaderMaterial({
    uniforms: {
      uTime:      { value: 0 },
      uColor:     { value: color.clone() },
      uHot:       { value: hotColor.clone() },
      uPulse:     { value: 1 },
      uLimbU:     { value: limbU },
      // physical Teff, published to the spectral imaging pass via alpha
      uTeff:      { value: 5772 },
      uOmega:     { value: 1 },
      // Rotation. uSpin is Ω/Ω_crit — the ONE number that sets both the shape
      // and the temperature map (see sim/structure.js). At 0 everything below
      // collapses to the non-rotating case exactly.
      uSpin:      { value: 0 },
      uGdBeta:    { value: 0.25 },
      uColPole:   { value: new THREE.Color(1, 1, 1) },
      uColEq:     { value: new THREE.Color(1, 1, 1) },
      uTpole:     { value: 5772 },
      // Just past 1.0. The disc has to land ON the tone curve's shoulder, not
      // beyond it: photograph the Sun in white light and you get an obviously
      // limb-darkened disc with granulation and spots on it, not a uniform
      // white circle. Overdrive it and ACES flattens every one of those
      // features into the same clipped white — which is exactly the look this
      // was meant to get rid of. Brightness is carried by the bloom halo and
      // by the real lights instead.
      uGain:      { value: 1.00 },
      uGranScale: { value: 9 },
      uSpots:     { value: Array.from({ length: MAX_SPOTS }, () => new THREE.Vector4()) },
      uSpotCount: { value: 0 },
      uFlares:    { value: Array.from({ length: MAX_FLARES }, () => new THREE.Vector4()) },
      // xyz = the bipole axis (across the neutral line), w = how far the two
      // ribbons have separated. A flare is a TWO-ribbon event: the loops that
      // reconnect are rooted in a pair of parallel strips either side of the
      // neutral line, and the strips move APART as reconnection works its way
      // up through higher, wider field. One blob centred on the region is the
      // one thing a flare never looks like.
      uFlareAxis: { value: Array.from({ length: MAX_FLARES }, () => new THREE.Vector4()) },
      uFlareCount:{ value: 0 },
    },
    vertexShader: `
      uniform float uSpin;
      varying vec3 vObj; varying vec3 vVN; varying vec3 vVP; varying float vG;

      // The Roche equipotential, R(theta)/R_pole, solved in closed form. See
      // the derivation in sim/structure.js — this is the same function, and at
      // u = 1 it returns exactly 1.5, the hard geometric limit on how flat a
      // self-gravitating body can be.
      float rocheShape(float u){
        u = clamp(u, 0.0, 1.0);
        if (u < 1e-3) return 1.0 + 0.148148 * u * u;   // series; the form below is 0/0 here
        return (3.0 / u) * cos((3.14159265 + acos(u)) / 3.0);
      }

      void main(){
        vec3 dir = normalize(position);
        vObj = dir;
        float sinT = length(dir.xz);
        float x = rocheShape(uSpin * sinT);
        vec3 p = position * x;                  // radial stretch onto the spheroid

        // Effective gravity at this point, in units of its polar value: the
        // Newtonian pull plus the centrifugal term, on the Roche surface.
        // With GM = 1 and R_pole = 1, Omega^2 = (8/27) uSpin^2.
        float om2 = 0.296296 * uSpin * uSpin;
        float gr  = -1.0 / (x * x) + om2 * x * sinT * sinT;
        float gt  = om2 * x * sinT * dir.y;
        vG = sqrt(gr * gr + gt * gt);           // exactly 1 at the pole

        // The surface normal of a radially stretched sphere is no longer
        // radial. Rather than carry the analytic gradient of the equipotential
        // through, tilt the radial normal toward the meridian by the same
        // ratio the gravity vector is tilted by — which is the gradient, since
        // the surface IS an equipotential and g is normal to it.
        vec3 er = dir;
        vec3 et = normalize(vec3(dir.x * dir.y, -sinT * sinT, dir.z * dir.y) + vec3(1e-6));
        vec3 n  = normalize(er * (-gr) + et * (-gt));

        // View space, not world space — and that is a precision decision, not
        // a style one. Going through the world (projection * view * model * p)
        // materialises an absolute world coordinate in float32 first: in the
        // stellar zoo a star sits 35 scene units from the origin, where float32
        // steps by 35·2⁻²³ ≈ 4e-6, while Sirius B's true-scale radius is 2e-5.
        // The sphere is then quantised onto a grid five steps across its own
        // radius and renders as a lump of cubes. modelViewMatrix is assembled
        // on the CPU in float64 and carries the CAMERA-RELATIVE offset, which
        // is ~1e-4 here and therefore exact — the 35 never enters a float32.
        // Same reason the view vector below is (-position) in view space rather
        // than cameraPosition minus a world position: that difference is 1e-4
        // between two numbers of magnitude 35, i.e. almost entirely cancellation
        // error once the body is drawn at its true size.
        vVN = normalize(normalMatrix * n);
        vec4 mv = modelViewMatrix * vec4(p, 1.0);
        vVP = mv.xyz;
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: `
      precision highp float;
      uniform float uTime, uPulse, uLimbU, uOmega, uGranScale, uGain, uTeff;
      uniform float uSpin, uGdBeta, uTpole;
      uniform vec3 uColor, uHot, uColPole, uColEq;
      uniform vec4 uSpots[${MAX_SPOTS}];   // xyz = surface direction, w = strength
      uniform int  uSpotCount;
      uniform vec4 uFlares[${MAX_FLARES}];    // xyz = region direction, w = amplitude
      uniform vec4 uFlareAxis[${MAX_FLARES}]; // xyz = bipole axis, w = ribbon separation
      uniform int  uFlareCount;
      varying vec3 vObj; varying vec3 vVN; varying vec3 vVP; varying float vG;

      float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1,113.5,7.9))) * 43758.5453); }
      float noise(vec3 p){
        vec3 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
        return mix(mix(mix(hash(i),               hash(i+vec3(1,0,0)), f.x),
                       mix(hash(i+vec3(0,1,0)),   hash(i+vec3(1,1,0)), f.x), f.y),
                   mix(mix(hash(i+vec3(0,0,1)),   hash(i+vec3(1,0,1)), f.x),
                       mix(hash(i+vec3(0,1,1)),   hash(i+vec3(1,1,1)), f.x), f.y), f.z);
      }
      float fbm(vec3 p){ float v=0.0, a=0.5; for(int i=0;i<5;i++){ v+=a*noise(p); p*=2.07; a*=0.5; } return v; }

      // rotate a point about the Y axis
      vec3 rotY(vec3 p, float a){ float c=cos(a), s=sin(a); return vec3(c*p.x - s*p.z, p.y, s*p.x + c*p.z); }

      void main(){
        vec3 p = normalize(vObj);

        // --- differential rotation: Ω(lat) = Ω_eq (1 − 0.19 sin²lat), as on the Sun.
        float sinLat = clamp(p.y, -1.0, 1.0);
        float omega  = uOmega * (1.0 - 0.19 * sinLat * sinLat);
        vec3  s      = rotY(p, -omega * uTime);   // co-rotating surface coordinate

        // --- granulation.
        // A real photosphere is a packed mosaic of convective CELLS: bright,
        // roughly polygonal granule tops separated by narrow dark intergranular
        // lanes where the cooled gas sinks. Plain fBm cannot produce that — it
        // gives soft blobs, which is exactly what made the star read as a
        // fluffy cartoon sun. The lanes are recovered with the ridge trick:
        // the set where a noise field crosses its own mid-value is a thin
        // connected network, so |n − ½| near zero IS the lane pattern.
        float nA = fbm(s * uGranScale + vec3(0.0, uTime * 0.05, 0.0));
        float nB = fbm(s * (uGranScale * 2.7) - vec3(uTime * 0.09));

        float laneA = 1.0 - smoothstep(0.0, 0.075, abs(nA - 0.5));
        float laneB = 1.0 - smoothstep(0.0, 0.055, abs(nB - 0.5));
        float lanes = clamp(laneA * 0.75 + laneB * 0.55, 0.0, 1.0);

        // granule interiors: bright, with a slight dome from centre to rim
        float cellA = smoothstep(0.42, 0.72, nA);
        float cellB = smoothstep(0.44, 0.70, nB);

        // Contrast is deliberately small. Real granulation is only ~15–20%
        // peak-to-peak; crank it and you get a golf ball.
        float bright = 0.88 + cellA * 0.19 + cellB * 0.10 - lanes * 0.30;

        // --- starspots: dark umbra, warm penumbra with radial filaments,
        // bright faculae ring
        float spotMask = 0.0, penumbra = 0.0, facula = 0.0;
        for(int i=0;i<${MAX_SPOTS};i++){
          if(i >= uSpotCount) break;
          vec4 sp = uSpots[i];
          float d = distance(p, sp.xyz);                 // chord distance on unit sphere
          float rad = 0.10 + 0.26 * sp.w;
          // ragged edge so spots aren't perfect discs
          float wob = (fbm(p * 14.0 + float(i) * 5.0) - 0.5) * 0.10;
          float u = 1.0 - smoothstep(rad * 0.42, rad + wob, d); // 1 in the umbra
          spotMask = max(spotMask, u * sp.w);

          // Penumbral filaments: the field is nearly horizontal in the
          // penumbra, so it combs the gas into radial threads pointing at the
          // umbra. It is the single most recognisable feature of a real spot.
          float ring = (1.0 - smoothstep(rad * 0.85, rad * 1.35, d)) * (1.0 - u);
          vec3  rel  = normalize(p - sp.xyz * dot(p, sp.xyz) + vec3(1e-5));
          float comb = 0.5 + 0.5 * sin(dot(rel, normalize(cross(sp.xyz, vec3(0.0,1.0,0.001)))) * 90.0
                                       + fbm(p * 30.0) * 6.0);
          penumbra = max(penumbra, ring * sp.w * (0.45 + comb * 0.55));

          facula   = max(facula, (1.0 - smoothstep(rad, rad * 1.55, d)) * (1.0 - u) * sp.w);
        }
        bright *= mix(1.0, 0.20, spotMask);
        bright *= mix(1.0, 0.62, penumbra);
        bright += facula * 0.35;

        // --- the two flare ribbons straddling the neutral line
        vec3 flareGlow = vec3(0.0);
        for(int i=0;i<${MAX_FLARES};i++){
          if(i >= uFlareCount) break;
          vec4 fl = uFlares[i];
          vec4 fx = uFlareAxis[i];
          vec3 rel = p - fl.xyz;
          float across = dot(rel, fx.xyz);                          // across the line
          float along  = dot(rel, cross(fl.xyz, fx.xyz));           // along it
          // Two strips at +-sep, each narrow, both running the length of the
          // neutral line. sep GROWS with the flare: the field that reconnects
          // gets higher and wider as the event proceeds, so its footpoints
          // land further out, and the ribbons visibly draw apart.
          // Squared directly, not through pow(): GLSL ES leaves pow undefined
          // for a negative base, and this base is negative everywhere BETWEEN
          // the two ribbons — i.e. over the whole arcade.
          float rd = (abs(across) - fx.w) / 0.055;
          float rb = exp(-rd * rd);
          rb *= 1.0 - smoothstep(0.14, 0.30, abs(along));
          rb *= 1.0 - smoothstep(0.30, 0.50, length(rel));
          // filamentary kernels inside each ribbon
          float fil = 0.5 + 0.5 * fbm(p * 30.0 + uTime * 3.0);
          flareGlow += vec3(1.0, 0.93, 0.85) * rb * fil * fl.w * 3.4;
        }

        // The disc itself is kept near 1.0 so the tone curve still has slope
        // left to resolve granulation and spots. What sells "blazing" is not a
        // brighter disc — it is the hot granule cores and faculae punching far
        // past 1.0 and lighting up the bloom pass, while the mean stays put.
        // --- GRAVITY DARKENING (von Zeipel 1924).
        // The rotating surface is an equipotential but not an equal-flux
        // surface: the radiative flux is proportional to the local effective
        // gravity, so T_eff ~ g^beta and F ~ g^(4 beta). The equator, further
        // out and centrifugally supported, is both cooler and dimmer than the
        // pole. On Vega that is 10 260 K against 8 610 K; on Regulus it is
        // 14 500 against 11 000, and both are directly measured.
        //
        // beta is 1/4 for a radiative envelope and ~0.08 for a convective one
        // (Lucy 1967) — the CPU side picks which, from Teff.
        float gDark = pow(max(vG, 1e-4), uGdBeta);            // T_local / T_pole
        float gFlux = pow(max(vG, 1e-4), 4.0 * uGdBeta);      // F_local / F_pole
        // The two endpoint colours are true blackbody colours for the pole and
        // equator temperatures, computed once on the CPU; g is monotonic
        // between them, so it is also the blend coordinate.
        float gEqv  = pow(max(1.0 - 0.5 * uSpin * uSpin, 1e-4), uGdBeta);
        float tBlend = uSpin > 0.02
          ? clamp((1.0 - gDark) / max(1.0 - gEqv, 1e-4), 0.0, 1.0) : 0.0;
        vec3 surfCol = mix(uColPole, uColEq, tBlend);

        vec3 base = surfCol * bright * uPulse * uGain * gFlux;
        // hot granule cores read as the star's own hotter continuum
        base += uHot * pow(max(nB - 0.60, 0.0), 2.0) * 5.5 * uGain * gFlux;
        base += flareGlow * uGain;

        // --- limb darkening: I(mu)/I(0) = 1 - u(1 - mu), mu = cos(view angle)
        vec3 V = normalize(-vVP);
        float mu = clamp(dot(normalize(vVN), V), 0.0, 1.0);
        base *= (1.0 - uLimbU * (1.0 - mu));

        // --- chromosphere: H-alpha reddening right at the limb
        float rim = pow(1.0 - mu, 3.0);
        base += vec3(1.0, 0.28, 0.16) * rim * 0.85 * uGain;

        // alpha = log-encoded true temperature for sim/spectrum.js. It is the
        // LOCAL temperature, not the star's mean: on a fast rotator the pole
        // really is 1500 K hotter, and the imaging bands should see that — flip
        // to UV on Vega and the poles brighten while the equator does not.
        float tLocal = uSpin > 0.02 ? uTpole * gDark : uTeff;
        gl_FragColor = vec4(base, clamp(log(max(tLocal, 1.0)) / 25.33, 0.0, 0.98));
      }`,
  });
}

// Corona / aureole.
// Drawn as a CAMERA-FACING BILLBOARD rather than a sphere shell: a shell's
// fresnel term peaks at the shell's own limb, which puts a hard-edged bubble
// ring in space around the star. A billboard lets the brightness fall off
// smoothly with radius, the way a real corona does, and lets us draw radial
// streamers in screen space.
function coronaMaterial(color) {
  return new THREE.ShaderMaterial({
    uniforms: {
      uTime: { value: 0 }, uColor: { value: color.clone() },
      uFlux: { value: 1 }, uSize: { value: 1 }, uCore: { value: 0.22 },
    },
    transparent: true, blending: THREE.AdditiveBlending,
    depthWrite: false, depthTest: false,
    vertexShader: `
      uniform float uSize;
      varying vec2 vP;
      void main(){
        vP = position.xy;
        // billboard: offset in view space from the object's origin
        vec4 centre = modelViewMatrix * vec4(0.0, 0.0, 0.0, 1.0);
        gl_Position = projectionMatrix * (centre + vec4(position.xy * uSize, 0.0, 0.0));
      }`,
    fragmentShader: `
      precision highp float;
      uniform float uTime, uFlux, uCore; uniform vec3 uColor;
      varying vec2 vP;
      float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7)))*43758.5453); }
      float noise(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
        return mix(mix(hash(i),hash(i+vec2(1,0)),f.x), mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x), f.y); }
      float fbm(vec2 p){ float v=0.0,a=0.5; for(int i=0;i<4;i++){ v+=a*noise(p); p*=2.1; a*=0.5; } return v; }
      void main(){
        float r = length(vP);
        if(r > 1.0) discard;
        float ang = atan(vP.y, vP.x);

        // smooth radial falloff — no hard edge anywhere
        float glow = exp(-(r - uCore) * 5.5);
        // a tight, bright inner aureole hugging the photosphere
        glow += exp(-(r - uCore) * 26.0) * 1.4;

        // radial streamers, slowly churning
        float streak = fbm(vec2(ang * 3.2, r * 3.0 - uTime * 0.05));
        glow *= 0.55 + streak * 0.95;

        // fade to nothing at the quad's edge so the billboard never shows
        glow *= 1.0 - smoothstep(0.72, 1.0, r);

        float a = clamp(glow, 0.0, 4.0) * uFlux;
        gl_FragColor = vec4(uColor * a, a * 0.5);
      }`,
  });
}

// ---------------------------------------------------------------------------
// A CORONAL MASS EJECTION.
// ----------------------------------------------------------------------------
// A CME has a three-part structure, and it has had one in every coronagraph
// image since OSO-7 saw the first of them in 1971:
//
//   · a BRIGHT LEADING EDGE — coronal material swept up and compressed ahead
//     of the eruption, a thin shell,
//   · a DARK CAVITY behind it — the evacuated flux rope itself, which is the
//     thing that is actually erupting, and
//   · a BRIGHT CORE inside that — the prominence material the rope is
//     carrying out with it, which is the same cool plasma that was hanging in
//     the arcade a few minutes earlier (see sim/prominence.js).
//
// So it is drawn as two thin shells with a gap between them, additively, and
// the gap IS the cavity: nothing needs to darken anything.
//
// The other half of it is that a thin shell is brightest where you look ALONG
// it. Shaded as an ordinary surface, a shell renders as a solid crescent with
// a hard silhouette, which is what this used to be; weighted by the path
// length through it — long at the rim, short face-on — the same geometry
// renders as the arc-and-legs shape a CME actually has.
// ---------------------------------------------------------------------------
function cmeMaterial(color, rimPow, filScale) {
  const m = new THREE.ShaderMaterial({
    uniforms: {
      uColor: { value: color.clone() }, uAlpha: { value: 1 },
      uDir: { value: new THREE.Vector3(0, 1, 0) }, uWidth: { value: 0.5 },
      uTime: { value: 0 }, uSeed: { value: 0 },
      uRimPow: { value: rimPow }, uFil: { value: filScale },
      uPlasmaT: { value: 1.6e6 },
    },
    transparent: true, depthWrite: false, side: THREE.DoubleSide,
    blending: THREE.CustomBlending,
    vertexShader: `varying vec3 vObj; varying vec3 vVN; varying vec3 vVP;
      void main(){ vObj = normalize(position);
        vVN = normalize(normalMatrix * normal);
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        vVP = mv.xyz;
        gl_Position = projectionMatrix * mv; }`,
    fragmentShader: `
      precision highp float;
      uniform vec3 uColor, uDir;
      uniform float uAlpha, uWidth, uTime, uSeed, uRimPow, uFil, uPlasmaT;
      varying vec3 vObj; varying vec3 vVN; varying vec3 vVP;
      float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1,113.5,7.9)))*43758.5453); }
      float noise(vec3 p){ vec3 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
        return mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),
                   mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z); }
      float fbm(vec3 p){ float v=0.0,a=0.5; for(int i=0;i<4;i++){v+=a*noise(p);p*=2.2;a*=0.5;} return v; }
      void main(){
        float c = dot(vObj, normalize(uDir));
        // The cone has soft flanks: the field opens gradually, it does not end.
        float cone = smoothstep(1.0 - uWidth, 1.0 - uWidth * 0.35, c);
        if(cone <= 0.002) discard;

        // Path length through a thin shell. This is the whole difference
        // between a crescent and an arc with legs.
        vec3 N = normalize(vVN), V = normalize(-vVP);
        float rim = pow(1.0 - abs(dot(N, V)), uRimPow);

        // Streamer-like striations: the ejecta is threaded on the field it
        // dragged out with it, so the structure is RADIAL.
        float n = fbm(vObj * uFil + vec3(uSeed) + uTime * 0.2);
        float a = cone * rim * uAlpha * (0.20 + n * 1.25);
        if(a < 0.003) discard;
        // Published temperature: a CME front is ~1.5 MK compressed corona and
        // its core is the ~10 kK prominence material it carried out, which is
        // why the two look nothing alike outside the visible.
        gl_FragColor = vec4(uColor * a * 2.0, clamp(log(max(uPlasmaT, 1.0)) / 25.33, 0.0, 0.98));
      }`,
  });
  // Additive colour, alpha replaced — see the same note in sim/prominence.js.
  m.blendEquation = THREE.AddEquation;
  m.blendSrc = THREE.OneFactor; m.blendDst = THREE.OneFactor;
  m.blendEquationAlpha = THREE.AddEquation;
  m.blendSrcAlpha = THREE.OneFactor; m.blendDstAlpha = THREE.ZeroFactor;
  return m;
}

// ---------------------------------------------------------------------------
export function createStarVisual(b, opts) {
  const g = new THREE.Group();
  const R = opts.radiusScene;
  const teff = opts.teff;
  const photo = opts.color instanceof THREE.Color ? opts.color.clone() : blackbodyColor(teff);
  const hot = coronaColor(teff);

  // Limb darkening is stronger for cool stars, weaker for hot ones.
  const limbU = THREE.MathUtils.clamp(0.85 - (teff - 3000) / 22000, 0.32, 0.85);

  const mat = photosphereMaterial(photo, hot, limbU);
  mat.uniforms.uTeff.value = teff;
  // Rotation, from the structure model (sim/structure.js) via sim/bodies.js.
  const spin = THREE.MathUtils.clamp(opts.spinFrac ?? 0, 0, 1);
  mat.uniforms.uSpin.value = spin;
  mat.uniforms.uGdBeta.value = opts.gdBeta ?? 0.25;
  mat.uniforms.uTpole.value = opts.tPole ?? teff;
  mat.uniforms.uColPole.value.copy(opts.tPole ? blackbodyColor(opts.tPole) : photo);
  mat.uniforms.uColEq.value.copy(opts.tEq ? blackbodyColor(opts.tEq) : photo);
  mat.uniforms.uOmega.value = rotationRate(b.mass) * 0.02;   // slowed for legibility
  // Granule size from the pressure scale height rather than from mass — see
  // granuleFrequency() in sim/structure.js. This is what turns a red supergiant
  // from a scaled-up Sun into a surface made of three or four vast cells.
  const radSun = opts.radiusSun ?? (b.radius ? b.radius / 0.00465047 : 1);
  mat.uniforms.uGranScale.value = granuleFrequency(teff, radSun, b.mass);
  // Disc brightness from Stefan–Boltzmann. Every star used to be drawn at the
  // same surface brightness, which is why a 3600 K supergiant came out the same
  // white as a 10 000 K A star; the tone curve then finished the job. F ∝ T⁴
  // spans 0.15 to 200 over the stars in this sim, and the HDR buffer is there
  // precisely so that range can be carried and rolled off once at the end.
  mat.uniforms.uGain.value = surfaceBrightness(teff);
  const core = new THREE.Mesh(new THREE.SphereGeometry(R, 64, 48), mat);
  g.add(core);

  // corona billboard. The quad spans ±1 and is scaled in the vertex shader, so
  // uCore is the photosphere's radius in quad units — the glow starts exactly
  // at the stellar limb however far away the camera is.
  // The photosphere is R at the pole but up to 1.5 R at the equator, and the
  // corona is a screen-space billboard with no idea about that — sized to the
  // polar radius it would cut across a fast rotator's own bulge. Size it to the
  // largest radius the star actually reaches.
  const Rmax = R * (opts.oblate ?? 1);
  const CORONA_SPAN = 4.0;                       // in stellar radii
  const coronaMat = coronaMaterial(hot);
  coronaMat.uniforms.uSize.value = Rmax * CORONA_SPAN;
  coronaMat.uniforms.uCore.value = 1 / CORONA_SPAN;
  const corona = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), coronaMat);
  corona.frustumCulled = false;
  corona.renderOrder = -1;                       // behind the photosphere
  g.add(corona);

  // Prominence pool, two arcades per possible concurrent flare — see
  // sim/prominence.js. They are two different things and both are always
  // present in a real event: the ERUPTING FLUX ROPE, which is the filament
  // that was sitting there beforehand tearing itself off and leaving, and the
  // POST-FLARE ARCADE, the row of hot loops that forms underneath it as the
  // field reconnects and closes back down. The rope rises and fades; the
  // arcade stays, grows taller, and cools.
  //
  // Halpha is Halpha whatever the star is, so the cool prominence material is
  // the same red-orange on a B star as on an M dwarf; only the footpoints,
  // heated by the beam, take the star's own hot continuum colour.
  const chromo = new THREE.Color(0xff6a44);
  const foot = hot.clone().lerp(new THREE.Color(0xffffff), 0.55);
  const erupt = [];
  for (let i = 0; i < MAX_FLARES; i++) {
    const holder = new THREE.Group();
    const rope = createArcade(chromo, foot);
    const arcade = createArcade(chromo, foot);
    holder.add(rope.group, arcade.group);
    holder.visible = false;
    g.add(holder);
    erupt.push({ holder, rope, arcade });
  }

  // CME pool — a leading edge and a core per event, with the cavity between
  // them left empty because that is what a cavity is.
  const cmeGeo = new THREE.SphereGeometry(1, 40, 28);
  const cmes = [];
  for (let i = 0; i < 3; i++) {
    const frontMat = cmeMaterial(hot, 1.7, 5.0);
    const coreMat = cmeMaterial(chromo, 1.25, 8.0);
    coreMat.uniforms.uPlasmaT.value = 1.2e4;
    const front = new THREE.Mesh(cmeGeo, frontMat);
    const core = new THREE.Mesh(cmeGeo, coreMat);
    const holder = new THREE.Group();
    holder.add(front, core);
    holder.visible = false;
    g.add(holder);
    cmes.push({ holder, front, core, frontMat, coreMat, seed: Math.random() * 40 });
  }

  const activity = new ActivityModel(b.mass);
  // Degenerate stars have no convection zone to run a dynamo, so no spots and
  // no flares. Emptying the regions and pushing the next arrival past any
  // watchable timescale leaves the same object with its magnetism switched off.
  if (opts.quiet) { activity.regions.length = 0; activity.next = Infinity; }
  b.activity = activity;

  const _v = new THREE.Vector3();
  const _up = new THREE.Vector3(0, 1, 0);
  const _east = new THREE.Vector3(), _north = new THREE.Vector3();
  const _bip = new THREE.Vector3(), _nl = new THREE.Vector3();
  const _m = new THREE.Matrix4();

  b.viz = { group: g, core, mat, corona, baseR: R, R, colorHex: photo.getHex(), isStar: true, activity };

  b.viz.update = (dt, ctx) => {
    const simDt = ctx.simDt ?? dt;
    mat.uniforms.uTime.value += dt;
    coronaMat.uniforms.uTime.value += dt;

    activity.step(simDt);

    // --- publish live starspots (rotated to their current longitude)
    const spots = mat.uniforms.uSpots.value;
    let sc = 0;
    const omega = mat.uniforms.uOmega.value;
    const t = mat.uniforms.uTime.value;
    for (const r of activity.regions) {
      if (sc >= MAX_SPOTS) break;
      const om = omega * (1 - 0.19 * Math.sin(r.lat) ** 2);
      const lon = r.lon + om * t;
      const cl = Math.cos(r.lat);
      // spots grow then decay over their lifetime
      const age = r.age / r.life;
      const s = r.strength * Math.sin(Math.min(age, 1) * Math.PI) ** 0.5;
      spots[sc++].set(cl * Math.cos(lon), Math.sin(r.lat), cl * Math.sin(lon), s);
    }
    mat.uniforms.uSpotCount.value = sc;

    // --- flares: the two ribbons on the surface, and the two arcades over it
    const fu = mat.uniforms.uFlares.value;
    const fa = mat.uniforms.uFlareAxis.value;
    let fc = 0;
    for (const e of erupt) e.holder.visible = false;
    for (const f of activity.flares) {
      if (fc >= MAX_FLARES) break;
      const om = omega * (1 - 0.19 * Math.sin(f.region.lat) ** 2);
      const lon = f.region.lon + om * t;
      const cl = Math.cos(f.region.lat);
      _v.set(cl * Math.cos(lon), Math.sin(f.region.lat), cl * Math.sin(lon));

      // JOY'S LAW. An active region is a bipole, and it is not oriented at
      // random: it lies very nearly east-west with a tilt that grows with
      // latitude — about half the latitude, leading polarity equatorward — so
      // every arcade in a given hemisphere leans the same way. The neutral
      // line runs across the bipole, and that is the axis the whole eruption
      // is built on.
      _east.crossVectors(_up, _v);
      if (_east.lengthSq() < 1e-8) _east.set(1, 0, 0);   // straight over a pole
      _east.normalize();
      _north.crossVectors(_v, _east).normalize();
      const joy = 0.5 * f.region.lat;
      _bip.copy(_east).multiplyScalar(Math.cos(joy))
          .addScaledVector(_north, Math.sin(joy)).normalize();
      _nl.crossVectors(_v, _bip).normalize();

      const x = Math.min(f.t / f.duration, 1);
      const E = Math.min(f.energy, 2.5);
      const sc = 0.55 + E * 0.42;

      fu[fc].set(_v.x, _v.y, _v.z, f.amp * Math.min(f.energy, 2));
      // The ribbons start almost on top of each other and draw apart as the
      // reconnection point climbs into higher, wider field.
      fa[fc].set(_bip.x, _bip.y, _bip.z, (0.045 + 0.13 * Math.min(x * 2.2, 1)) * sc);

      const E2 = erupt[fc];
      E2.holder.visible = true;
      E2.holder.position.copy(_v).multiplyScalar(R);
      _m.makeBasis(_nl, _v, _bip);
      E2.holder.quaternion.setFromRotationMatrix(_m);

      // The rope: already there, torn loose early, gone by mid-event. Its
      // shear relaxes as it goes, because the shear is what is being spent.
      const rise = smoothstep01(0.02, 0.5, x);
      const ropeAmp = Math.min(0.55 + f.amp * 0.9, 1.5) * (1 - smoothstep01(0.22, 0.62, x));
      E2.rope.group.visible = ropeAmp > 0.01;
      // An arcade is LONG compared with the loops in it — a neutral line runs
      // for many times a single loop's span, which is why the thing reads as a
      // row. Make it short and the loops pile up on each other into a ball of
      // wool, which is what one tube was trying to avoid in the first place.
      E2.rope.set({
        R, span: 0.075 * sc, len: 0.30 * sc, height: 0.17 * sc,
        shear: 0.95 - 0.55 * x, twist: 0.8 + 1.1 * rise, erupt: rise,
        width: 0.011, amp: ropeAmp, plasmaT: 1.2e4 + 2e6 * rise, dt,
      });

      // The post-flare arcade: forms under the rope once reconnection starts,
      // grows taller as the reconnection point rises, and cools for the rest
      // of the event. It is square across the neutral line, not sheared —
      // that is what it means for the field to have relaxed.
      const arcAmp = smoothstep01(0.05, 0.15, x) * Math.min(f.amp * 1.3 + 0.15, 1.4);
      E2.arcade.group.visible = arcAmp > 0.01;
      E2.arcade.set({
        R, span: (0.045 + 0.055 * Math.min(x * 2.0, 1)) * sc, len: 0.34 * sc,
        height: (0.040 + 0.095 * Math.min(x * 2.0, 1)) * sc,
        shear: 0.30 * (1 - x), twist: 0.22, erupt: 0,
        width: 0.009, amp: arcAmp, plasmaT: 1.5e7 * Math.exp(-x * 1.6) + 3e5, dt,
      });
      fc++;
    }
    mat.uniforms.uFlareCount.value = fc;

    // --- CMEs
    for (let i = 0; i < cmes.length; i++) {
      const c = activity.cmes[i];
      const slot = cmes[i];
      if (!c) { slot.holder.visible = false; continue; }
      slot.holder.visible = true;
      // The core trails the front: the rope is inside the shell it is
      // driving, and the gap between them widens as the whole thing expands.
      slot.front.scale.setScalar(c.radius * R);
      slot.core.scale.setScalar(c.radius * R * 0.58);
      for (const [m, k] of [[slot.frontMat, 0.5], [slot.coreMat, 0.75]]) {
        m.uniforms.uAlpha.value = c.alpha * k;
        m.uniforms.uDir.value.copy(c.dir);
        m.uniforms.uSeed.value = slot.seed;
        m.uniforms.uTime.value += dt;
      }
      // The core occupies the inner part of the same cone.
      slot.frontMat.uniforms.uWidth.value = c.width;
      slot.coreMat.uniforms.uWidth.value = c.width * 0.55;
    }

    // --- brightness: slow pulsation + flare contribution
    const pulse = 1 + Math.sin(ctx.time * 0.6 + b.id) * 0.02;
    core.scale.setScalar(pulse);
    mat.uniforms.uPulse.value = activity.flux;
    // The corona billboard is now only the structured part — the streamers and
    // the tight inner aureole. The broad soft halo it used to have to fake is
    // produced for real by the bloom pass, so this is dialled well back to
    // stop the two stacking into a glowing ball.
    coronaMat.uniforms.uFlux.value = 0.15 + (activity.flux - 1) * 0.8;
  };

  return b.viz;
}
