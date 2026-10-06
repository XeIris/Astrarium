import * as THREE from 'three';
import { MAX_SUNS, SUN_UNIFORMS, SUN_GLSL, applySuns, insolationAt, litBy } from './suns.js';
import { NOISE_GLSL } from './terrain.js';

// ============================================================================
// GAS GIANTS
// ----------------------------------------------------------------------------
// A gas giant has no surface. What you are looking at is the top of a cloud
// deck a few bars down in an envelope thousands of kilometres deep, and the
// one thing that makes it read as GAS rather than as a painted ball is that it
// does not turn as one object:
//
//   · The interior rotates rigidly, because it is conducting and the magnetic
//     field ties it together. That rate — System III, 9h55m29.7s for Jupiter —
//     is the mesh's own rotation here, and it is the only thing the "core"
//     does.
//   · The visible atmosphere does NOT rotate at that rate. It is organised
//     into a dozen alternating zonal jets, and the equatorial one runs 100 m/s
//     FASTER than the interior while jets a few degrees away run slower. So
//     the cloud field is advected, in the shader, by
//         dlambda(phi) = [u(phi) / (R cos phi)] * t
//     and because that is a function of latitude, adjacent bands SHEAR past
//     each other. Everything that makes Jupiter look alive follows from that
//     one line: the ragged, filamented band edges, the way a vortex is drawn
//     out into an oval, the fact that a feature you were watching has drifted
//     relative to the one beside it a few hours later.
//   · Belts and zones are not stripes of paint either. The jets sit at their
//     BOUNDARIES — the flow is 90 degrees out of phase with the vertical
//     motion — so bright zones are rising ammonia-ice cloud and dark belts are
//     subsiding, cleared air where you are seeing several scale heights deeper
//     into warmer, browner chromophores. One phase function gives both.
//   · There are three optical levels, not one: a deep, warm layer, the main
//     deck, and a thin high haze, each advected at its own rate (the wind
//     shears with depth as well as with latitude) and composited by optical
//     depth. That is what stops the disc looking like a decal.
//
// The poles are deliberately NOT banded. Juno found the jets break down inside
// about 60 degrees latitude into a crowd of packed cyclones, which is why the
// polar view of Jupiter looks nothing like the equatorial one.
// ============================================================================

const MAX_VORTEX = 6;

// zone (rising, bright), belt (sinking, dark), deep (what you see down the
// holes), haze (the thin upper layer over everything).
export const GIANT_PALETTES = {
  // Jupiter has about six alternating jets per hemisphere, so uJets is set so
  // that sin(uJets * lat) completes that many half cycles between equator and
  // pole; jetAmp and eqJet are in the same units as the advection rate.
  jupiter: { zone: 0xc2b190, belt: 0x7d5233, deep: 0x54301e, haze: 0xb5a68c, spot: 0xa5522f,
             jets: 11.0, jetAmp: 0.55, contrast: 1.0, eqJet: 1.0 },
  saturn:  { zone: 0xcfbf96, belt: 0xa88b5e, deep: 0x876236, haze: 0xd2c6aa, spot: 0xb59868,
             jets: 8.5, jetAmp: 0.35, contrast: 0.50, eqJet: 2.6 },
  ice:     { zone: 0x8ec6d6, belt: 0x4f8cb6, deep: 0x27608f, haze: 0xaad8e4, spot: 0x21406f,
             jets: 4.5, jetAmp: 0.30, contrast: 0.22, eqJet: -0.8 },
};

// ---------------------------------------------------------------------------
// The zonal wind profile, shared by the shader (which advects the cloud with
// it) and by JS (which drifts the vortices with it), so a spot always travels
// at the speed of the jet it is sitting in.
// ---------------------------------------------------------------------------
const WIND_GLSL = `
  uniform float uJets;      // jets per radian of latitude
  uniform float uJetAmp;    // amplitude of the alternating jets
  uniform float uEqJet;     // equatorial superrotation (Saturn's is enormous)

  // Phase of the jet system. The jets go as cos(theta), the vertical motion as
  // sin(theta): a quarter cycle apart, which is the observed relationship
  // between the jets and the belt/zone boundaries they sit on.
  float jetPhase(float lat){ return uJets * lat; }

  float zonalWind(float lat){
    float a = abs(lat);
    // equatorial jet, then the alternating mid-latitude system, damped out
    // toward the poles where the banded regime breaks down entirely
    float env = exp(-pow(a / 1.05, 4.0));
    return uEqJet * exp(-pow(a / 0.24, 2.0)) + uJetAmp * cos(jetPhase(lat)) * env;
  }

  // Angular drift rate. u is a LINEAR speed along a latitude circle, so the
  // angular rate carries the 1/cos(phi) — which is why the high-latitude jets
  // wrap the planet faster in longitude than their wind speed suggests.
  float zonalOmega(float lat){
    return zonalWind(lat) / max(cos(lat), 0.15);
  }`;

const ROT_GLSL = `
  vec3 rotY(vec3 p, float a){
    float c = cos(a), s = sin(a);
    return vec3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
  }
  // Rodrigues — rotate p about an arbitrary unit axis. Used to spin the
  // sampled coordinate inside a vortex, which is what turns a coloured oval
  // into something with visible circulation in it.
  vec3 rotAxis(vec3 p, vec3 axis, float a){
    float c = cos(a), s = sin(a);
    return p * c + cross(axis, p) * s + axis * dot(axis, p) * (1.0 - c);
  }`;

function giantMaterial(seed, pal, opts) {
  return new THREE.ShaderMaterial({
    uniforms: {
      ...SUN_UNIFORMS(),
      uTime:     { value: 0 },
      uSeed:     { value: seed },
      uZone:     { value: new THREE.Color(pal.zone) },
      uBelt:     { value: new THREE.Color(pal.belt) },
      uDeep:     { value: new THREE.Color(pal.deep) },
      uHaze:     { value: new THREE.Color(pal.haze) },
      uContrast: { value: pal.contrast },
      uJets:     { value: pal.jets },
      uJetAmp:   { value: pal.jetAmp },
      uEqJet:    { value: pal.eqJet },
      uTeff:     { value: 124 },
      // vortices: (sin lat, longitude, angular radius, strength)
      uVortex:   { value: Array.from({ length: MAX_VORTEX }, () => new THREE.Vector4()) },
      uVortexCol:{ value: Array.from({ length: MAX_VORTEX }, () => new THREE.Color(pal.spot)) },
      uVortexN:  { value: 0 },
      // ring shadow cast ONTO the planet: inner/outer radius in body radii, 0 = none
      uRingIn:   { value: 0 },
      uRingOut:  { value: 0 },
      uSunObj:   { value: Array.from({ length: MAX_SUNS }, () => new THREE.Vector3(1, 0, 0)) },
    },
    vertexShader: `
      varying vec3 vObj; varying vec3 vWN; varying vec3 vView;
      void main(){
        vObj = normalize(position);
        vWN  = normalize(mat3(modelMatrix) * normal);
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        mat3 vr = mat3(viewMatrix);
        vView = -vec3(dot(vr[0], mv.xyz), dot(vr[1], mv.xyz), dot(vr[2], mv.xyz));
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: `
      precision highp float;
      ${SUN_GLSL}
      uniform float uTime, uSeed, uContrast, uTeff, uRingIn, uRingOut;
      uniform vec3 uZone, uBelt, uDeep, uHaze;
      uniform vec4 uVortex[${MAX_VORTEX}];
      uniform vec3 uVortexCol[${MAX_VORTEX}];
      uniform int uVortexN;
      uniform vec3 uSunObj[${MAX_SUNS}];
      varying vec3 vObj; varying vec3 vWN; varying vec3 vView;
      ${NOISE_GLSL}
      ${WIND_GLSL}
      ${ROT_GLSL}

      // Turbulence sampled with more latitudinal than longitudinal frequency:
      // a zonal flow stretches everything it carries along the direction it
      // flows, so the eddies are long thin filaments, not blobs. The stretch
      // is 2.5 rather than the 4 it wants to be, and the octave counts are
      // low, for a reason that matters here: this is procedural noise with no
      // mip chain, so an octave finer than a pixel does not add detail, it
      // ALIASES — and on a banded planet it aliases into exactly the thing the
      // bands are made of, a moire of horizontal stripes that moves with the
      // camera. Detail that cannot be resolved is worse than no detail.
      float zonalTurb(vec3 q, float s, int oct){
        return fbm(vec3(q.x, q.y * 2.5, q.z) * s + vec3(uSeed), oct);
      }
      // The flow map: two copies of the field, half a period out of step.
      float turb(vec3 qa, vec3 qb, float w, float s, int oct){
        return mix(zonalTurb(qb, s, oct), zonalTurb(qa, s, oct), w);
      }

      void main(){
        vec3 p = normalize(vObj);
        float lat = asin(clamp(p.y, -1.0, 1.0));
        float a = abs(lat);

        // --- ADVECTION, and the one thing that has to be got right about it.
        //
        // The cloud is carried by the zonal wind, which is a function of
        // latitude, so the longitude offset between two adjacent latitudes
        // grows linearly and WITHOUT BOUND. Sample a frozen noise field at
        // that offset and after a few minutes the field's latitudinal
        // frequency has been wound up past a pixel and the planet dissolves
        // into moire — the shear is real, but a frozen field cannot express
        // arbitrarily much of it. A real atmosphere escapes this because its
        // eddies are continuously regenerated at their own scale, not stretched
        // for ever.
        //
        // So the field is regenerated too, by the standard flow-map device:
        // advect two copies whose clocks are half a period out of step, and
        // cross-fade between them so that whichever copy is being looked at is
        // always the one near the start of its wind-up. The winding is then
        // bounded by omega * period, the motion is continuous, and nothing
        // accumulates.
        // The period is what bounds the shear, so it is short: with jets a
        // fifth of a radian apart and an angular rate differing by a few per
        // radian across them, half a minute of winding already puts several
        // radians of phase between one side of a band and the other, which is
        // finer than the band. Sixteen seconds keeps the filaments legible.
        float per = 16.0;
        float ta = mod(uTime, per);
        float tb = mod(uTime + per * 0.5, per);
        // Each copy's weight falls to ZERO exactly when its own clock wraps,
        // so the reset is never visible and the worst winding ever shown is
        // half a period's worth.
        float wx = 1.0 - abs(2.0 * ta / per - 1.0);

        float om = zonalOmega(lat);
        vec3 qa = rotY(p, -om * ta);
        vec3 qb = rotY(p, -om * tb);

        // --- vortices. Each one drifts with its own jet (JS advances its
        // longitude), is stretched into an oval by the ambient shear, and spins
        // the coordinate inside it so the cloud there is visibly circulating.
        float vortexMask = 0.0;
        float vortexCollar = 0.0;
        vec3 vortexCol = uZone;
        for(int i=0;i<${MAX_VORTEX};i++){
          if(i >= uVortexN) break;
          vec4 V = uVortex[i];
          float vlat = asin(clamp(V.x, -1.0, 1.0));
          vec3 ctr = vec3(cos(vlat) * cos(V.y), V.x, cos(vlat) * sin(V.y));
          // distance in an anisotropic metric — 2.4:1, the aspect ratio the
          // shear holds a long-lived oval at
          vec3 d = p - ctr;
          float dy = d.y, dxz = length(d - vec3(0.0, dy, 0.0));
          float r = sqrt(pow(dxz / 2.4, 2.0) + dy * dy) / max(V.z, 1e-3);
          if(r < 1.6){
            float m = smoothstep(1.10, 0.30, r) * V.w;
            // a raised, brighter collar round the oval — the ring of cloud the
            // vortex has lifted is the part you actually see first
            vortexCollar = max(vortexCollar, smoothstep(1.30, 1.00, r) * smoothstep(0.75, 1.00, r) * V.w);
            // differential spin inside the oval: fastest at the collar
            float sp0 = (1.0 - smoothstep(0.0, 1.2, r)) * 0.55;
            qa = rotAxis(qa, ctr, sp0 * ta);
            qb = rotAxis(qb, ctr, sp0 * tb);
            vortexMask = max(vortexMask, m);
            vortexCol = uVortexCol[i];
          }
        }

        // --- belts and zones: sin of the jet phase, i.e. a quarter cycle out
        // of step with the jets themselves.
        //
        // The wobble goes on the LATITUDE, not on the result. A real band
        // boundary is a jet, and a jet meanders: it is displaced north and
        // south by the eddies it is shedding, so the boundary between a belt
        // and a zone is a train of interlocking scallops and festoons, and two
        // adjacent boundaries meander independently. Adding the noise to the
        // finished band value instead just mottles the stripes, which is what
        // a painted planet looks like.
        // The displacement is a fraction of the jet SPACING (pi/uJets): a
        // meander of order the spacing itself does not ripple the boundary, it
        // erases the band.
        float sp = 3.14159 / max(uJets, 1.0);
        float meander = (turb(qa, qb, wx, 1.5, 4) - 0.5) * sp * 0.55
                      + (turb(qa, qb, wx, 3.4, 3) - 0.5) * sp * 0.18;
        float band = sin(jetPhase(lat + meander));
        // a weaker, finer second system riding on the first
        band += 0.22 * sin(jetPhase(lat * 2.7 + meander * 1.8));
        band = clamp(band * uContrast * 1.6, -1.0, 1.0);

        // Poleward of about 60 degrees the banded regime is gone and the flow
        // is a crowd of cyclones instead.
        float polar = smoothstep(0.90, 1.25, a);
        float chaos = mix(ridged(qb * 4.5 + vec3(uSeed + 9.0), 3), ridged(qa * 4.5 + vec3(uSeed + 9.0), 3), wx);
        band = mix(band, (chaos - 0.55) * 2.0, polar);

        vec3 col = mix(uBelt, uZone, band * 0.5 + 0.5);

        // --- optical depth of the main deck. Where it is thin you are looking
        // down into the warm deep layer; that is what a belt IS.
        float tau = turb(qa, qb, wx, 2.6, 5);
        float clear = smoothstep(0.62, 0.34, tau + band * 0.20);
        col = mix(col, uDeep, clear * 0.75);

        // --- filaments and festoons, concentrated where the shear is: the
        // middle of a zone is bland and the boundary is a mess of streamers,
        // because that is where the velocity gradient is.
        float shear = 1.0 - abs(band);
        float fil = mix(ridged(vec3(qb.x, qb.y * 3.5, qb.z) * 3.0 + vec3(uSeed + 4.0), 3),
                        ridged(vec3(qa.x, qa.y * 3.5, qa.z) * 3.0 + vec3(uSeed + 4.0), 3), wx);
        col *= 1.0 + (fil - 0.55) * (0.22 + 0.55 * shear);

        // --- the high haze, which is thin at the equator and piles up over
        // the poles (it is why Saturn's poles are flat grey-blue). It is
        // advected RIGIDLY, at one rate for the whole planet: it sits above
        // the jets, it has almost no structure of its own, and a layer with no
        // shear in it needs no flow map.
        float hz = zonalTurb(rotY(p, -uTime * 0.018), 1.6, 4);
        float hazeAmt = clamp(0.12 + 0.55 * polar + 0.25 * hz, 0.0, 0.85);
        col = mix(col, uHaze, hazeAmt * 0.6);

        // --- vortices on top of all of it
        col = mix(col, uZone, vortexCollar * 0.7);
        col = mix(col, vortexCol, vortexMask);

        // --- lighting. A gas giant has no surface to be rough or smooth, so
        // there is no specular term at all; what it has instead is very strong
        // limb darkening, because near the limb you are looking through a long
        // slant path and seeing only the topmost, thinnest haze.
        vec3 N = normalize(vWN);
        vec3 V = normalize(vView);
        float mu = max(dot(N, V), 0.0);
        vec3 lit = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          vec3 L = normalize(uSunDir[i]);
          float ndl = dot(N, L);
          float diff = smoothstep(-0.06, 0.20, ndl);
          // Limb darkening, and a lot of it: near the limb the line of sight
          // is a long slant path that never reaches the deck, so you see only
          // the thin haze above it. A giant fades to its edge.
          float minn = mix(0.28, 1.0, pow(mu, 0.60));
          float sh = 1.0;
          if(uRingOut > 0.0){
            // Ring shadow. Walk from this point toward the star and see where
            // the line crosses the equatorial plane; if it crosses inside the
            // ring system, the star is behind the rings from here. It is the
            // single most recognisable thing about Saturn at low tilt.
            vec3 Lo = normalize(uSunObj[i]);
            if(abs(Lo.y) > 1e-3){
              float t = -p.y / Lo.y;
              if(t > 0.0){
                vec3 hit = p + Lo * t;
                float rr = length(vec2(hit.x, hit.z));
                if(rr > uRingIn && rr < uRingOut){
                  // the shadow carries the ring system's own optical depth,
                  // so the Cassini division shows as a bright line across it
                  float g = smoothstep(uRingIn, uRingIn + 0.04, rr) * smoothstep(uRingOut, uRingOut - 0.04, rr);
                  float band = smoothstep(1.52, 1.56, rr) * smoothstep(1.96, 1.92, rr);   // B
                  float bandA = 0.45 * smoothstep(2.02, 2.06, rr) * smoothstep(2.27, 2.24, rr);
                  sh = 1.0 - 0.85 * g * clamp(0.25 + band + bandA, 0.0, 1.0);
                }
              }
            }
          }
          lit += col * uSunColor[i] * uSunInt[i] * diff * minn * sh;
        }
        lit += col * vec3(0.012, 0.014, 0.020);

        // A giant is warm from the inside: Jupiter radiates 1.67 times what it
        // absorbs, left over from contraction. Publishing that temperature is
        // what lets the infrared band image it as the source it is.
        gl_FragColor = vec4(lit, clamp(log(max(uTeff, 1.0)) / 25.33, 0.0, 0.98));
      }`,
  });
}

// ---------------------------------------------------------------------------
// LIMB HAZE — a giant has no edge. The disc fades into a thin bright rim of
// forward-scattering aerosol several scale heights above the deck, and without
// it the silhouette is a hard circle, which is the tell that you are looking at
// a solid ball.
// ---------------------------------------------------------------------------
function limbMaterial(pal) {
  return new THREE.ShaderMaterial({
    uniforms: { ...SUN_UNIFORMS(), uTint: { value: new THREE.Color(pal.haze) } },
    transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.BackSide,
    vertexShader: `
      varying vec3 vWN; varying vec3 vView;
      void main(){
        vWN = normalize(mat3(modelMatrix) * normal);
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        mat3 vr = mat3(viewMatrix);
        vView = -vec3(dot(vr[0], mv.xyz), dot(vr[1], mv.xyz), dot(vr[2], mv.xyz));
        gl_Position = projectionMatrix * mv; }`,
    fragmentShader: `
      precision highp float;
      ${SUN_GLSL}
      uniform vec3 uTint;
      varying vec3 vWN; varying vec3 vView;
      void main(){
        vec3 N = normalize(vWN), V = normalize(vView);
        float rim = pow(1.0 - abs(dot(N, V)), 3.0);
        vec3 col = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          vec3 L = normalize(uSunDir[i]);
          float lam = smoothstep(-0.30, 0.45, dot(N, L));
          float fwd = 0.4 + 1.6 * pow(max(dot(V, -L), 0.0), 3.0);
          col += uTint * uSunColor[i] * uSunInt[i] * lam * fwd;
        }
        gl_FragColor = vec4(col * rim * 0.30, 1.0);
      }`,
  });
}

// ---------------------------------------------------------------------------
// RINGS. Not an annulus of flat colour: a ring system is a swarm of individual
// orbiting particles with a RADIAL OPTICAL DEPTH PROFILE, and the profile is
// the recognisable part. Saturn's, in units of its own radius:
//
//   C ring      1.24 – 1.53   tau ~ 0.1, nearly transparent
//   B ring      1.53 – 1.95   tau ~ 1.5, the bright one
//   Cassini     1.95 – 2.03   a resonance-swept gap, not empty but close
//   A ring      2.03 – 2.27   tau ~ 0.5, with the Encke gap at 2.21
//
// Each boundary is a resonance with a moon, which is why they are sharp. The
// transparency then follows from tau along the actual slant path, 1 - exp(-tau/mu),
// so the rings really do go more opaque as you view them edge-on, and the
// planet really is visible through the C ring and not through the B ring.
// ---------------------------------------------------------------------------
function ringMaterial(pal, opts) {
  return new THREE.ShaderMaterial({
    uniforms: {
      ...SUN_UNIFORMS(),
      uColor: { value: new THREE.Color(opts.ringColor ?? 0xd8c9a6) },
      uInner: { value: opts.ringInner ?? 1.24 },
      uOuter: { value: opts.ringOuter ?? 2.27 },
      uBodyR: { value: 1 },
      uSeed:  { value: opts.seed ?? 1 },
      uSunObj:{ value: Array.from({ length: MAX_SUNS }, () => new THREE.Vector3(1, 0, 0)) },
    },
    transparent: true, depthWrite: false, side: THREE.DoubleSide,
    vertexShader: `
      varying vec3 vLocal; varying vec3 vView; varying vec3 vNrm;
      void main(){
        vLocal = position;                    // ring plane is the mesh's own XY
        vNrm = normalize(mat3(modelMatrix) * vec3(0.0, 0.0, 1.0));
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        mat3 vr = mat3(viewMatrix);
        vView = -vec3(dot(vr[0], mv.xyz), dot(vr[1], mv.xyz), dot(vr[2], mv.xyz));
        gl_Position = projectionMatrix * mv; }`,
    fragmentShader: `
      precision highp float;
      ${SUN_GLSL}
      uniform vec3 uColor; uniform float uInner, uOuter, uBodyR, uSeed;
      uniform vec3 uSunObj[${MAX_SUNS}];
      varying vec3 vLocal; varying vec3 vView; varying vec3 vNrm;
      ${NOISE_GLSL}

      // Optical depth vs radius, in body radii.
      float tauAt(float r){
        float t = 0.0;
        t += 0.12 * smoothstep(1.235, 1.27, r) * smoothstep(1.53, 1.50, r);   // C
        t += 1.50 * smoothstep(1.525, 1.56, r) * smoothstep(1.951, 1.93, r);  // B
        t += 0.06 * smoothstep(1.951, 1.96, r) * smoothstep(2.025, 2.015, r); // Cassini
        t += 0.55 * smoothstep(2.025, 2.04, r) * smoothstep(2.269, 2.25, r);  // A
        t *= 1.0 - 0.85 * smoothstep(2.209, 2.214, r) * smoothstep(2.219, 2.214, r); // Encke
        return t;
      }

      void main(){
        float r = length(vLocal.xy) / max(uBodyR, 1e-6);
        if(r < uInner || r > uOuter) discard;
        float tau = tauAt(r);
        // Ringlets. The fine structure is spiral density waves driven by the
        // moons, so it is RADIAL and has no azimuthal structure at all — the
        // rings are grooved like a record, not mottled. Two scales, because
        // the waves come in trains.
        tau *= 0.62 + 0.50 * fbm(vec3(r * 42.0, uSeed, 0.0), 3)
             + 0.26 * fbm(vec3(r * 150.0, uSeed + 3.0, 0.0), 2);
        if(tau < 0.004) discard;

        // Slant path: the transmitted fraction is exp(-tau/mu) with mu the
        // cosine to the ring PLANE NORMAL, so a ring system seen edge-on goes
        // opaque and the same ring seen face-on is a haze. That is one law, not
        // two opacities.
        vec3 V = normalize(vView);
        float mu = max(abs(dot(normalize(vNrm), V)), 0.05);
        float alpha = 1.0 - exp(-tau / mu);

        vec3 lit = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          vec3 L = normalize(uSunDir[i]);
          // the planet's own shadow falling across the rings
          vec3 Lo = normalize(uSunObj[i]);
          // The mesh is turned -90 degrees about X to lie in the equator, so
          // its local (x, y) is the body frame's (x, -z). Get that wrong and
          // the planet's shadow falls on the wrong side of the system.
          vec2 q = vLocal.xy / max(uBodyR, 1e-6);
          vec3 pt = vec3(q.x, 0.0, -q.y);
          float along = dot(pt, Lo);
          float perp = length(pt - Lo * along);
          // The planet's shadow is a CYLINDER of its own radius laid along the
          // line to the star, so on a tilted ring system it is a parallel-sided
          // band, not a circle — and its edge is soft because the star is a
          // disc, not a point.
          float sh = (along < 0.0) ? mix(0.10, 1.0, smoothstep(0.92, 1.12, perp)) : 1.0;
          // Ring particles are icy and forward-scatter strongly: the far side
          // of the system, seen against the sun, is much the brighter.
          float fwd = 0.45 + 0.9 * pow(max(dot(V, -L), 0.0), 2.5);
          // denser material is brighter as well as more opaque
          lit += uColor * uSunColor[i] * uSunInt[i] * sh * fwd * (0.55 + 0.45 * min(tau, 1.2));
        }
        lit += uColor * 0.015;
        gl_FragColor = vec4(lit * 0.75, clamp(alpha, 0.0, 1.0));
      }`,
  });
}

// ---------------------------------------------------------------------------
export function createGiantVisual(b, opts = {}) {
  const g = new THREE.Group();
  const R = opts.radiusScene;
  const pal = { ...(opts.giantPalette || GIANT_PALETTES.jupiter) };
  const seed = (((b.id * 2654435761) >>> 0) % 997) / 5.9;

  const mat = giantMaterial(seed, pal, opts);
  const body = new THREE.Mesh(new THREE.SphereGeometry(R, 96, 64), mat);
  g.add(body);

  const limbMat = limbMaterial(pal);
  const limb = new THREE.Mesh(new THREE.SphereGeometry(R * 1.035, 48, 32), limbMat);
  g.add(limb);

  // --- long-lived vortices. They sit where the shear is anticyclonic, which
  // is the poleward side of a prograde jet; the Great Red Spot has been at
  // 22 degrees south for at least 190 years for exactly that reason.
  const rnd = mulberry(seed * 1000 + 7);
  const vortices = [];
  const nV = opts.vortices ?? (pal.contrast > 0.6 ? 3 : pal.contrast > 0.3 ? 2 : 1);
  for (let i = 0; i < Math.min(nV, MAX_VORTEX); i++) {
    // pick a latitude at an anticyclonic phase of the jet system
    const k = i === 0 ? -0.39 : (rnd() - 0.5) * 1.6;
    const lat = i === 0 ? -0.39 : k;
    vortices.push({
      lat, lon: rnd() * Math.PI * 2,
      size: (i === 0 ? 0.135 : 0.045 + rnd() * 0.04) * (opts.vortexScale ?? 1),
      strength: i === 0 ? 0.85 : 0.45 + rnd() * 0.3,
      color: new THREE.Color(i === 0 ? pal.spot : pal.zone).lerp(new THREE.Color(pal.deep), rnd() * 0.4),
    });
  }
  mat.uniforms.uVortexN.value = vortices.length;
  vortices.forEach((v, i) => mat.uniforms.uVortexCol.value[i].copy(v.color));

  // --- rings
  let rings = null, ringMat = null;
  if (opts.rings) {
    const inner = opts.ringInner ?? 1.24, outer = opts.ringOuter ?? 2.27;
    // The visual radius is exaggerated along with the body, so the ring system
    // is built in BODY RADII and scaled with it — a ring is at a resonance
    // with a moon, not at an absolute distance.
    const geo = new THREE.RingGeometry(R * inner, R * outer, 192, 8);
    ringMat = ringMaterial(pal, { ...opts, seed });
    ringMat.uniforms.uBodyR.value = R;
    rings = new THREE.Mesh(geo, ringMat);
    rings.rotation.x = -Math.PI / 2;
    g.add(rings);
    mat.uniforms.uRingIn.value = inner;
    mat.uniforms.uRingOut.value = outer;
  }

  // Axial tilt. Rings are equatorial, so they are inside this group and tip
  // with it — which is the whole reason Saturn's rings open and close.
  g.rotation.z = opts.obliquity ?? 0.05;

  b.viz = {
    group: g, core: body, body, limb, rings, mat, limbMat, ringMat,
    baseR: R, R, isGiant: true, vortices,
  };

  // System III: the rigid interior rate. Everything above moves relative to it.
  b.spin = b.spin ?? (0.9 + Math.random() * 0.5);
  b.spinPhase = b.spinPhase ?? 0;
  const TAU = Math.PI * 2;
  const albedo = opts.albedo ?? 0.5;
  // Internal heat: Jupiter radiates 1.67x what it absorbs, Saturn 1.78x, from
  // contraction and (on Saturn) helium rain. Neptune 2.6x; Uranus, oddly, ~1.
  const internal = opts.internalHeat ?? 1.67;

  b.viz.update = (dt, ctx) => {
    b.spinPhase = (b.spinPhase + b.spin * dt) % TAU;
    body.rotation.y = b.spinPhase;               // the core, and only the core
    mat.uniforms.uTime.value += dt;

    // Each vortex rides its own jet. Same profile the shader advects the cloud
    // with, so a spot never drifts out of the band it belongs to.
    const u = (lat) => {
      const a = Math.abs(lat);
      const env = Math.exp(-Math.pow(a / 1.05, 4));
      return pal.eqJet * Math.exp(-Math.pow(a / 0.24, 2)) + pal.jetAmp * Math.cos(pal.jets * lat) * env;
    };
    for (let i = 0; i < vortices.length; i++) {
      const v = vortices[i];
      v.lon = (v.lon + (u(v.lat) / Math.max(Math.cos(v.lat), 0.15)) * dt) % TAU;
      mat.uniforms.uVortex.value[i].set(Math.sin(v.lat), v.lon, v.size, v.strength);
    }

    const suns = litBy(ctx);
    if (suns) {
      applySuns([mat, limbMat, ringMat].filter(Boolean), suns, g.position);
      // Effective temperature: what it absorbs plus what it makes.
      const S = (ctx.suns && ctx.suns.length) ? insolationAt(b, ctx.suns) : suns[0].intensity;
      const Teq = 278.6 * Math.pow(Math.max(S, 1e-9) * (1 - albedo), 0.25);
      mat.uniforms.uTeff.value = Teq * Math.pow(internal, 0.25);
      // Sun directions in the BODY frame, for the two shadow tests. The group
      // carries the axial tilt, so this is where the ring shadow learns which
      // way the rings are leaning.
      const inv = g.quaternion.clone().invert();
      // The RING mesh is not spun, so the group frame is its frame. The BODY
      // mesh is: rotation.y carries System III, and its shader tests the ring
      // shadow against vObj, its own local position. Handing it the group-frame
      // direction leaves the two frames a spin phase apart, and the shadow then
      // travels round the planet at the interior rotation rate instead of
      // staying under the sunward side of the ring plane. Taken back out with
      // the mesh's own quaternion rather than a hand-written rotation, because
      // the sign of that is exactly the trap this is.
      _bodyInv.copy(body.quaternion).invert();
      const n = Math.min(suns.length, MAX_SUNS);
      for (let i = 0; i < n; i++) {
        const d = _v.copy(suns[i].posScene).sub(g.position).normalize().applyQuaternion(inv);
        if (ringMat) ringMat.uniforms.uSunObj.value[i].copy(d);
        mat.uniforms.uSunObj.value[i].copy(d).applyQuaternion(_bodyInv);
      }
    }
  };

  return b.viz;
}

const _v = new THREE.Vector3();
const _bodyInv = new THREE.Quaternion();

function mulberry(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
