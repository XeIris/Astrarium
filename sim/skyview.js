import * as THREE from 'three';
import { MAX_SUNS } from './world.js';

// ============================================================================
// SURFACE VIEW — standing on the planet, looking up.
// ----------------------------------------------------------------------------
// Rendered as a full-screen composite pass (same structure as the lensing pass)
// rather than as dome geometry, so there are no depth-precision or draw-order
// fights between a sky that spans 5 orders of magnitude and stars 30 AU away.
//
// The sky is single-scattering Rayleigh + Mie, evaluated INDEPENDENTLY FOR
// EVERY SUN and summed:
//
//   L(v) = Σ_i  I_i · T(m_sun,i) · (β_s·P(θ_i)/β_e) · (1 − exp(−β_e·m_view))
//
//   β_R ∝ 1/λ⁴  → the sky is blue, and a low sun is red because its light has
//                 crossed a long air mass and lost the blue end.
//   P_M          Henyey–Greenstein, g = 0.76 → the bright aureole hugging each sun.
//   m            Kasten–Young air mass, so the reddening is driven by real
//                 geometry: each sun reddens on its own schedule as it sets.
//
// Because the terms are per-sun, a Trisolaran sky does what the books describe:
// one sun can be setting red on one horizon while another burns white overhead,
// the shadows cross, and the sky colour is the sum of all of them.
// ============================================================================

const SKY_FRAG = /* glsl */`
precision highp float;
varying vec2 vUv;
uniform sampler2D tScene;
uniform vec3 uCamPos; uniform mat4 uCamMat;
uniform float uFov, uAspect;
uniform vec3 uUp;                        // local vertical at the observer
uniform vec3 uNorth;                     // a horizon reference direction
uniform vec3 uSunDir[${MAX_SUNS}];       // unit vectors to each sun
uniform vec3 uSunColor[${MAX_SUNS}];
uniform float uSunInt[${MAX_SUNS}];      // relative flux (1 = one solar constant)
uniform float uSunAng[${MAX_SUNS}];      // angular RADIUS in radians
uniform int uSunCount;
uniform float uIce, uScorch, uClouds, uHumidity, uStorm, uTime, uNight, uExposure;

#define PI 3.14159265359

// optical depth of the whole atmosphere at zenith (β · H)
const vec3 TAU_R = vec3(0.0490, 0.1136, 0.2784);
const float TAU_M = 0.0180;

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7)))*43758.5453); }
float noise(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(hash(i),hash(i+vec2(1,0)),f.x), mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x), f.y); }
float fbm(vec2 p){ float v=0.0,a=0.5; for(int i=0;i<5;i++){ v+=a*noise(p); p*=2.07; a*=0.5; } return v; }

// Kasten–Young air mass for a given cosine of the zenith angle.
float airMass(float cz){
  float z = degrees(acos(clamp(cz, -1.0, 1.0)));
  return 1.0 / (max(cz, 0.0) + 0.50572 * pow(max(96.07995 - z, 0.01), -1.6364));
}

float phaseRayleigh(float c){ return 3.0 / (16.0 * PI) * (1.0 + c*c); }
float phaseMie(float c){
  const float g = 0.76;
  float gg = g*g;
  return (1.0 - gg) / (4.0*PI * pow(1.0 + gg - 2.0*g*c, 1.5));
}

// Single-scattered radiance along a view ray of air mass mView.
//
// The naive form is (beta_scatter * phase) * mView, which grows WITHOUT BOUND as
// you look toward the horizon — at the horizon mView ~ 38, so the horizon comes
// out 38x the zenith and whites out the frame. That is wrong: light scattered
// toward you is also extinguished on its way to you. Integrating both through a
// uniform slab gives a SATURATING result,
//
//     L = (beta_s * P / beta_e) * (1 - exp(-beta_e * m))
//
// which tends to the single-scattering albedo as the path gets optically thick.
// It is why a real horizon is pale and bright but not blinding.
vec3 inScatter(float cosTheta, float mView){
  vec3 betaE = TAU_R + TAU_M;
  vec3 betaS = TAU_R * phaseRayleigh(cosTheta) + vec3(TAU_M * phaseMie(cosTheta));
  return (betaS / betaE) * (1.0 - exp(-betaE * mView));
}

// ACES-style filmic curve: highlights roll off into white instead of clipping
// flat, so a sun in frame stops flash-banging everything around it.
vec3 tonemap(vec3 x){
  const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main(){
  vec2 ndc = vUv * 2.0 - 1.0; ndc.x *= uAspect;
  float f = tan(uFov * 0.5);
  vec3 rd = normalize((uCamMat * vec4(normalize(vec3(ndc.x*f, ndc.y*f, -1.0)), 0.0)).xyz);

  float elev = dot(rd, uUp);                 // sine of the view elevation
  vec3 scene = texture2D(tScene, vUv).rgb;

  // Extinction on the SUN'S OWN DISC. The rendered star knows nothing about the
  // air it is being seen through, so redden it here: a sun on the horizon is
  // looking at us through ~38 air masses, which is why it goes blood red before
  // it sets. Applied per sun, so each one reddens on its own schedule.
  vec3 tint = vec3(1.0);
  for(int i=0;i<${MAX_SUNS};i++){
    if(i >= uSunCount) break;
    float ang = acos(clamp(dot(rd, uSunDir[i]), -1.0, 1.0));
    float onDisc = 1.0 - smoothstep(uSunAng[i] * 0.9, uSunAng[i] * 3.5, ang);
    if(onDisc <= 0.001) continue;
    float sElev = dot(uSunDir[i], uUp);
    vec3 tr = exp(-(TAU_R + TAU_M) * airMass(max(sElev, 0.0)));
    // below the horizon the disc is cut off by the planet itself
    tr *= smoothstep(-0.02, 0.01, sElev);
    tint = mix(tint, tr, onDisc);
  }
  scene *= tint;

  // ---------------------------------------------------------------- sky
  float mView = airMass(max(elev, 0.0));
  vec3 sky = vec3(0.0);
  vec3 sunGlare = vec3(0.0);
  float dayness = 0.0;

  for(int i=0;i<${MAX_SUNS};i++){
    if(i >= uSunCount) break;
    vec3 L = uSunDir[i];
    float sElev = dot(L, uUp);
    // a sun below the horizon still lights the sky for a while — twilight
    float vis = smoothstep(-0.18, 0.02, sElev);
    if(vis <= 0.0) continue;

    float mSun = airMass(max(sElev, 0.0));
    vec3 trans = exp(-(TAU_R + TAU_M) * mSun);      // reddening on the way in
    float c = dot(rd, L);

    vec3 I = uSunColor[i] * uSunInt[i] * vis;
    sky += I * trans * inScatter(c, mView) * 134.0;

    // aureole: the bright, tight halo right around the disc
    float halo = pow(max(c, 0.0), 900.0) * 0.5 + pow(max(c, 0.0), 60.0) * 0.06;
    sunGlare += I * trans * halo * 2.0;

    dayness = max(dayness, vis * uSunInt[i] * max(sElev, 0.0));
  }

  // haze / humidity greys the sky out; storms darken it
  float haze = uHumidity * 0.35 + uStorm * 0.25;
  float lum = dot(sky, vec3(0.2126, 0.7152, 0.0722));
  sky = mix(sky, vec3(lum) * 1.05, clamp(haze, 0.0, 0.7));
  sky *= (1.0 - uStorm * 0.35);

  // a scorched world hazes over with dust and steam
  sky = mix(sky, sky * vec3(1.25, 0.85, 0.6) + vec3(0.03,0.01,0.0), uScorch * 0.8);

  // ---------------------------------------------------------------- ground
  vec3 ground = vec3(0.0);
  float groundMix = 0.0;
  if(elev < 0.0){
    // intersect the local ground plane; distance drives the fog
    float dist = -1.0 / min(elev, -1e-4);
    vec2 gp = vec2(dot(rd, uNorth), dot(rd, cross(uUp, uNorth))) * dist;

    float relief = fbm(gp * 0.35) * 0.7 + fbm(gp * 1.7) * 0.3;
    vec3 rock = mix(vec3(0.16,0.13,0.11), vec3(0.30,0.25,0.20), relief);
    vec3 veg  = mix(vec3(0.10,0.16,0.07), vec3(0.20,0.26,0.11), relief);
    // vegetation only in the temperate band, desert when scorched, ice when frozen
    vec3 base = mix(rock, veg, clamp((1.0 - uIce) * (1.0 - uScorch) * 0.9, 0.0, 1.0));
    base = mix(base, vec3(0.45,0.34,0.20), uScorch * 0.7);
    base = mix(base, vec3(0.80,0.85,0.92), smoothstep(0.05, 0.75, uIce));

    // lit by every sun that is up
    vec3 lit = vec3(0.0);
    for(int i=0;i<${MAX_SUNS};i++){
      if(i >= uSunCount) break;
      float sElev = dot(uSunDir[i], uUp);
      float vis = smoothstep(-0.05, 0.12, sElev);
      vec3 trans = exp(-(TAU_R + TAU_M) * airMass(max(sElev, 0.0)));
      // slope shading: relief gradient against the sun's azimuth
      float shade = 0.55 + 0.45 * relief;
      lit += uSunColor[i] * uSunInt[i] * vis * trans * max(sElev, 0.0) * shade;
    }
    lit += (0.10 + 0.16 * uIce) * max(sky, vec3(0.0)); // skylight bounced from the sky itself
    ground = base * lit * 7.5;
    ground += vec3(0.9,0.25,0.05) * pow(uScorch, 2.0) * 0.35;

    // aerial perspective: distant ground dissolves into the horizon sky
    float fog = 1.0 - exp(-dist * 0.0016 * (1.0 + haze * 2.0));
    vec3 horizonSky = sky * 1.15;
    ground = mix(ground, horizonSky, clamp(fog, 0.0, 1.0));
    // NB: smoothstep is undefined for edge0 >= edge1, so invert rather than
    // passing the edges backwards.
    groundMix = 1.0 - smoothstep(-0.006, 0.0, elev);
  }

  // ---------------------------------------------------------------- composite
  // Sky opacity: an bright sky hides the starfield, a dark one lets it through.
  float skyLum = dot(sky, vec3(0.2126,0.7152,0.0722));
  float opacity = clamp(skyLum * 2.6, 0.0, 1.0);
  // never fully mask the suns themselves — they outshine their own sky
  float sunMask = 0.0;
  for(int i=0;i<${MAX_SUNS};i++){
    if(i >= uSunCount) break;
    float c = dot(rd, uSunDir[i]);
    float ang = acos(clamp(c, -1.0, 1.0));
    sunMask = max(sunMask, 1.0 - smoothstep(uSunAng[i] * 0.85, uSunAng[i] * 2.6, ang));
  }
  opacity *= (1.0 - sunMask * 0.92);

  // The rendered star discs live in the same linear space as the sky, but their
  // shader is tuned for the un-tonemapped orbit view, so lift them here to keep
  // a sun reading as a sun once the filmic curve is applied.
  vec3 col = mix(scene * 1.5, sky, opacity) + sunGlare * (1.0 - groundMix);

  // cloud deck overhead, thickening with humidity
  if(elev > 0.0 && uClouds > 0.02){
    float d = 1.0 / max(elev, 0.02);
    vec2 cp = vec2(dot(rd, uNorth), dot(rd, cross(uUp, uNorth))) * d * 0.5;
    float cd = fbm(cp * 0.6 + uTime * 0.01);
    float cov = smoothstep(0.60 - uClouds*0.45, 0.80 - uClouds*0.30, cd);
    cov *= smoothstep(0.0, 0.16, elev);       // thin out toward the horizon
    vec3 cloudLit = vec3(0.0);
    for(int i=0;i<${MAX_SUNS};i++){
      if(i >= uSunCount) break;
      float sElev = dot(uSunDir[i], uUp);
      float vis = smoothstep(-0.20, 0.06, sElev);
      vec3 trans = exp(-(TAU_R + TAU_M) * airMass(max(sElev, 0.0)));
      cloudLit += uSunColor[i] * uSunInt[i] * vis * trans;
    }
    cloudLit = cloudLit * mix(0.55, 0.16, uStorm) + vec3(0.02,0.025,0.04);
    col = mix(col, cloudLit, cov * clamp(uClouds, 0.0, 0.95) * 0.9);
  }

  if(groundMix > 0.0) col = mix(col, ground, groundMix);

  // Exposure, then the filmic curve. uExposure is driven from the CPU by how
  // much sunlight is actually reaching the observer and lags behind it, so the
  // view adapts the way an eye does instead of blowing out the moment a sun
  // clears the horizon.
  gl_FragColor = vec4(tonemap(col * uExposure), 1.0);
}`;

export function createSkyPass() {
  const material = new THREE.ShaderMaterial({
    uniforms: {
      tScene:   { value: null },
      uCamPos:  { value: new THREE.Vector3() },
      uCamMat:  { value: new THREE.Matrix4() },
      uFov:     { value: 1.0 }, uAspect: { value: 1 },
      uUp:      { value: new THREE.Vector3(0, 1, 0) },
      uNorth:   { value: new THREE.Vector3(1, 0, 0) },
      uSunDir:  { value: Array.from({ length: MAX_SUNS }, () => new THREE.Vector3(0, 1, 0)) },
      uSunColor:{ value: Array.from({ length: MAX_SUNS }, () => new THREE.Color(1, 1, 1)) },
      uSunInt:  { value: new Float32Array(MAX_SUNS) },
      uSunAng:  { value: new Float32Array(MAX_SUNS) },
      uSunCount:{ value: 0 },
      uIce:     { value: 0 }, uScorch: { value: 0 },
      uClouds:  { value: 0.4 }, uHumidity: { value: 0.4 }, uStorm: { value: 0.2 },
      uTime:    { value: 0 }, uNight: { value: 0 }, uExposure: { value: 1 },
    },
    vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }`,
    fragmentShader: SKY_FRAG,
    depthTest: false, depthWrite: false,
  });
  const scene = new THREE.Scene();
  scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), material));
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  return { material, scene, camera };
}

// ============================================================================
// SURFACE OBSERVER
// ----------------------------------------------------------------------------
// Places the camera on the planet's surface at a chosen latitude and rides the
// planet's rotation, so the suns rise and set because the ground is turning —
// not because anything is animating them.
// ============================================================================
export class SurfaceObserver {
  constructor() {
    this.latitude = 0.38;     // radians
    this.azimuth = 0;         // where the observer is looking
    this.elevation = 0.25;
    this.fov = 62;
    this.up = new THREE.Vector3(0, 1, 0);
    this.north = new THREE.Vector3(1, 0, 0);
    this.eye = new THREE.Vector3();
  }

  // Recompute the observer frame from the planet's orientation and spin phase.
  update(planet, camera) {
    const g = planet.viz.group;
    const R = planet.viz.R;
    const phase = planet.spinPhase || 0;

    // local vertical in the planet's own (untilted) frame
    const cl = Math.cos(this.latitude), sl = Math.sin(this.latitude);
    this.up.set(cl * Math.cos(phase), sl, cl * Math.sin(phase));
    // carry the axial tilt: the group holds the obliquity rotation
    this.up.applyQuaternion(g.getWorldQuaternion(_q));

    // north = component of the spin axis perpendicular to the local vertical
    _axis.set(0, 1, 0).applyQuaternion(_q);
    this.north.copy(_axis).addScaledVector(this.up, -_axis.dot(this.up));
    if (this.north.lengthSq() < 1e-8) this.north.set(1, 0, 0);
    this.north.normalize();

    // eye sits a hair above the surface
    this.eye.copy(g.position).addScaledVector(this.up, R * 1.004);

    // build the look direction from azimuth (about the local vertical) and elevation
    _east.crossVectors(this.up, this.north).normalize();
    _look.copy(this.north).multiplyScalar(Math.cos(this.azimuth))
         .addScaledVector(_east, Math.sin(this.azimuth));
    _look.multiplyScalar(Math.cos(this.elevation))
         .addScaledVector(this.up, Math.sin(this.elevation)).normalize();

    camera.position.copy(this.eye);
    camera.up.copy(this.up);
    camera.lookAt(_tmp.copy(this.eye).add(_look));
    camera.fov = this.fov;
    camera.updateProjectionMatrix();
    // The sky pass reconstructs view rays from camera.matrixWorld. Three.js only
    // refreshes that during render, so without this the sky would be built from
    // LAST frame's orientation — the horizon tilts away from the rendered scene
    // and the suns drift out of their own cut-outs.
    camera.updateMatrixWorld(true);
  }

  look(dx, dy) {
    this.azimuth += dx;
    this.elevation = THREE.MathUtils.clamp(this.elevation + dy, -1.35, 1.45);
  }
  zoom(f) {
    this.fov = THREE.MathUtils.clamp(this.fov * f, 12, 100);
  }
}

const _q = new THREE.Quaternion();
const _axis = new THREE.Vector3();
const _east = new THREE.Vector3();
const _look = new THREE.Vector3();
const _tmp = new THREE.Vector3();
