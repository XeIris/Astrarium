import * as THREE from 'three';
import { ActivityModel, blackbodyColor, coronaColor, rotationRate } from './stellar.js';
import { granuleFrequency, surfaceBrightness } from './structure.js';

// ============================================================================
// HIGH-FIDELITY STAR RENDERING
// ----------------------------------------------------------------------------
// The photosphere shader models, in one pass:
//   · granulation — convective cells, two octaves of fBm advected in time
//   · differential rotation — the equator laps the poles (real: Sun 25 d vs 34 d)
//   · starspots — dark umbra + warm penumbra + bright surrounding faculae,
//     placed at the ActivityModel's live active regions
//   · flare ribbons — a hot, white-blue kernel over the erupting region
//   · limb darkening — the physically correct I(μ)/I(0) = 1 − u(1 − μ) law
//   · a chromospheric H-α rim glowing just past the limb
// Everything is driven by mass → Teff → colour, so an M dwarf and a B star look
// genuinely different rather than being recoloured copies.
// ============================================================================

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
      uFlareCount:{ value: 0 },
    },
    vertexShader: `
      uniform float uSpin;
      varying vec3 vObj; varying vec3 vWN; varying vec3 vWP; varying float vG;

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

        vWN = normalize(mat3(modelMatrix) * n);
        vec4 wp = modelMatrix * vec4(p, 1.0);
        vWP = wp.xyz;
        gl_Position = projectionMatrix * viewMatrix * wp;
      }`,
    fragmentShader: `
      precision highp float;
      uniform float uTime, uPulse, uLimbU, uOmega, uGranScale, uGain, uTeff;
      uniform float uSpin, uGdBeta, uTpole;
      uniform vec3 uColor, uHot, uColPole, uColEq;
      uniform vec4 uSpots[${MAX_SPOTS}];   // xyz = surface direction, w = strength
      uniform int  uSpotCount;
      uniform vec4 uFlares[${MAX_FLARES}]; // xyz = direction, w = amplitude
      uniform int  uFlareCount;
      varying vec3 vObj; varying vec3 vWN; varying vec3 vWP; varying float vG;

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

        // --- flare ribbons over the erupting active region
        vec3 flareGlow = vec3(0.0);
        for(int i=0;i<${MAX_FLARES};i++){
          if(i >= uFlareCount) break;
          vec4 fl = uFlares[i];
          float d = distance(p, fl.xyz);
          float ribbon = 1.0 - smoothstep(0.06, 0.42, d);
          // filamentary structure inside the ribbon
          float fil = 0.55 + 0.45 * fbm(p * 26.0 + uTime * 3.0);
          flareGlow += vec3(1.0, 0.93, 0.85) * ribbon * fil * fl.w * 2.4;
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
        vec3 V = normalize(cameraPosition - vWP);
        float mu = clamp(dot(normalize(vWN), V), 0.0, 1.0);
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

// A coronal mass ejection: a bright shell expanding inside a cone.
function cmeMaterial(color) {
  return new THREE.ShaderMaterial({
    uniforms: {
      uColor: { value: color.clone() }, uAlpha: { value: 1 },
      uDir: { value: new THREE.Vector3(0, 1, 0) }, uWidth: { value: 0.5 }, uTime: { value: 0 },
    },
    transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide,
    vertexShader: `varying vec3 vObj;
      void main(){ vObj = normalize(position);
        gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }`,
    fragmentShader: `
      precision highp float;
      uniform vec3 uColor, uDir; uniform float uAlpha, uWidth, uTime;
      varying vec3 vObj;
      float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1,113.5,7.9)))*43758.5453); }
      float noise(vec3 p){ vec3 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
        return mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),
                   mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z); }
      float fbm(vec3 p){ float v=0.0,a=0.5; for(int i=0;i<4;i++){v+=a*noise(p);p*=2.2;a*=0.5;} return v; }
      void main(){
        float c = dot(vObj, normalize(uDir));
        float cone = smoothstep(1.0 - uWidth, 1.0 - uWidth * 0.25, c);
        if(cone <= 0.001) discard;
        // turbulent, filamentary plasma front
        float n = fbm(vObj * 7.0 + uTime * 0.4);
        float a = cone * uAlpha * (0.25 + n * 0.95);
        gl_FragColor = vec4(uColor * a * 2.0, a * 0.8);
      }`,
  });
}

// A prominence: a plasma loop arcing out of the surface and back.
function makeLoop(R, color) {
  const curve = new THREE.CubicBezierCurve3(
    new THREE.Vector3(-0.22 * R, 0, 0),
    new THREE.Vector3(-0.16 * R, 0.55 * R, 0),
    new THREE.Vector3( 0.16 * R, 0.55 * R, 0),
    new THREE.Vector3( 0.22 * R, 0, 0),
  );
  const geo = new THREE.TubeGeometry(curve, 26, R * 0.035, 8, false);
  const mat = new THREE.MeshBasicMaterial({
    color, transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false,
  });
  return new THREE.Mesh(geo, mat);
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

  // prominence loop pool, one per possible concurrent flare
  const loops = [];
  for (let i = 0; i < MAX_FLARES; i++) {
    const holder = new THREE.Group();
    const loop = makeLoop(R, hot);
    holder.add(loop);
    holder.visible = false;
    g.add(holder);
    loops.push({ holder, loop });
  }

  // CME shell pool
  const cmes = [];
  for (let i = 0; i < 3; i++) {
    const cm = cmeMaterial(hot);
    const mesh = new THREE.Mesh(new THREE.SphereGeometry(1, 32, 24), cm);
    mesh.visible = false;
    g.add(mesh);
    cmes.push({ mesh, mat: cm });
  }

  const activity = new ActivityModel(b.mass);
  // Degenerate stars have no convection zone to run a dynamo, so no spots and
  // no flares. Emptying the regions and pushing the next arrival past any
  // watchable timescale leaves the same object with its magnetism switched off.
  if (opts.quiet) { activity.regions.length = 0; activity.next = Infinity; }
  b.activity = activity;

  const _v = new THREE.Vector3();
  const _up = new THREE.Vector3(0, 1, 0);
  const _q = new THREE.Quaternion();

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

    // --- flares: shader ribbons + a prominence loop standing over the region
    const fu = mat.uniforms.uFlares.value;
    let fc = 0;
    for (const l of loops) l.holder.visible = false;
    for (const f of activity.flares) {
      if (fc >= MAX_FLARES) break;
      const om = omega * (1 - 0.19 * Math.sin(f.region.lat) ** 2);
      const lon = f.region.lon + om * t;
      const cl = Math.cos(f.region.lat);
      _v.set(cl * Math.cos(lon), Math.sin(f.region.lat), cl * Math.sin(lon));
      fu[fc].set(_v.x, _v.y, _v.z, f.amp * Math.min(f.energy, 2));

      // stand a loop on the surface, its axis along the local vertical
      const L = loops[fc];
      L.holder.visible = true;
      L.holder.position.copy(_v).multiplyScalar(R * 0.92);
      L.holder.quaternion.copy(_q.setFromUnitVectors(_up, _v));
      const scl = 0.7 + Math.min(f.energy, 2.5) * 0.5;
      L.holder.scale.setScalar(scl);
      L.loop.material.opacity = Math.min(f.amp * 0.9, 1) * 0.85;
      fc++;
    }
    mat.uniforms.uFlareCount.value = fc;

    // --- CMEs
    for (let i = 0; i < cmes.length; i++) {
      const c = activity.cmes[i];
      const slot = cmes[i];
      if (!c) { slot.mesh.visible = false; continue; }
      slot.mesh.visible = true;
      slot.mesh.scale.setScalar(c.radius * R);
      slot.mat.uniforms.uAlpha.value = c.alpha * 0.55;
      slot.mat.uniforms.uDir.value.copy(c.dir);
      slot.mat.uniforms.uWidth.value = c.width;
      slot.mat.uniforms.uTime.value += dt;
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
