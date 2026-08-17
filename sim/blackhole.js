import * as THREE from 'three';
import { SKY_GLSL, SKY_ALPHA, skyUniforms } from './sky.js';

// ============================================================================
// BLACK HOLE — general-relativistic ray marcher + volumetric accretion disc.
// ============================================================================
// Everything you see of a black hole is light that *missed*. There is no
// surface to shade, so this is a full-screen pass that integrates null
// geodesics backwards from the eye and reports what each one ran into.
//
// WHAT IS PHYSICALLY MODELLED
//
//  · Null geodesics. In Schwarzschild geometry the orbit equation for a photon
//    reduces (via Binet) to a Cartesian acceleration
//        d²x/dλ² = −(3/2) r_s h² x̂ / r⁵ ,    h = |x × v|, |v| = 1
//    which is EXACT for light, not a Newtonian approximation. Integrated with
//    an RK2 midpoint step that shrinks as (r − r_s), so rays that graze the
//    photon sphere at 1.5 r_s are resolved instead of tunnelling through it.
//
//  · The shadow. Nothing is drawn for the hole itself. A ray that crosses the
//    horizon simply stops and returns whatever disc light it had already
//    collected. The dark region that results has an apparent radius of
//    (√27/2)·r_s ≈ 2.6 r_s — noticeably LARGER than the horizon, because the
//    photon sphere is what casts it. Drawing a black sphere at r_s (the old
//    behaviour) both got the size wrong and implied a solid object where the
//    theory has a singularity and a one-way surface.
//
//  · The photon ring. Rays with impact parameter near the critical value wind
//    around the hole one or more times, crossing the disc on each pass, and
//    stack that emission into the thin brilliant ring that hugs the shadow.
//    It is not drawn — it falls out of the integration, which is the point.
//
//  · Shakura–Sunyaev disc. T(r) ∝ (r_in/r)^¾ · (1 − √(r_in/r))^¼ — the
//    standard thin-disc profile. It vanishes AT the ISCO and peaks a little
//    outside it, so the disc has a genuinely dark inner gap and a hot ridge
//    rather than being brightest where it touches the hole.
//
//  · Relativistic transfer. The disc orbits at v = √(r_s/2r)/√(1 − r_s/r); the
//    combined Doppler + gravitational factor g = δ·√(1 − r_s/r) is applied to
//    BOTH the observed colour temperature (T_obs = g·T_emit) and the intensity
//    (I_obs ∝ g⁴, from the invariance of I_ν/ν³). That single term is what
//    produces the famous asymmetry: the approaching limb goes blue-white and
//    ~80× brighter, the receding limb sinks into dull red.
//
//  · Volumetric emission/absorption through a flared, geometrically thin slab
//    of height H(r) ∝ r^9/8, so the disc occludes itself and the far side is
//    genuinely seen *through* the near side.
//
// THE FILAMENTARY STRUCTURE
//
//    Real discs are not smooth. Magnetorotational turbulence injects eddies,
//    and Keplerian shear — Ω(r) ∝ r^(−3/2), so the inner disc laps the outer —
//    stretches every one of them into a long thin arc. Reproducing that is a
//    matter of sampling noise in the CO-ROTATING frame: define
//        ψ = φ + Ω(r)·t
//    and evaluate fBm at ψ with the azimuthal axis compressed and the radial
//    axis expanded (here ~8:1). Features come out long in φ and thin in r —
//    strands, not clouds. A slow drift along the noise's third axis stands in
//    for the constant regeneration that stops real turbulence from winding
//    into infinitely tight spirals, and a low-frequency domain warp braids the
//    strands over each other.
// ============================================================================

export const MAX_HOLES = 2;

// ----------------------------------------------------------------------------
// pass 1 — the marcher
// ----------------------------------------------------------------------------
// This runs at the LENS SCALE, not at display resolution, and it deliberately
// does not know the sky exists. Splitting there is what makes the scale
// reduction affordable: the geodesic integration and the disc integral are
// per-RAY costs and tolerate being traced at half rate, because their result is
// a smooth field. The star field is a per-PIXEL cost and does not tolerate it
// at all - a point source resampled at half rate stops being a point - so
// sim/sky.js is evaluated in pass 2 at full resolution, on the direction field
// this pass hands over.
//
// GLSL ES 3.00, and RawShaderMaterial, purely so this can write two
// attachments. Nothing else here needs it.
const MARCH_FRAG = `
precision highp float;
in vec2 vUv;

// Both attachments are RGBA16F at the march resolution:
//   gMarch0   disc emission (rgb), transmittance (a)
//   gMarch1   outgoing direction as a delta from the undeflected ray (rgb),
//             log of the disc's luminance-weighted mean temperature (a)
layout(location = 0) out vec4 gMarch0;
layout(location = 1) out vec4 gMarch1;

uniform vec3  holePos[${MAX_HOLES}];
uniform float holeRs[${MAX_HOLES}];
uniform int   holeCount;
uniform vec3  camPos;
uniform mat4  camMat;
uniform float fov, aspect, time;
uniform float discIntensity, discTemp;
// The disc's TRUE peak temperature, in kelvin, from the hole's mass. The
// rendered colour is deliberately rescaled to something an eye can read (see
// discSource), but the multi-wavelength imaging in sim/spectrum.js needs the
// real number — a 10 M☉ disc is an X-ray source at ~10⁷ K, and no amount of
// staring at its visible colour will tell you that.
uniform float discTpeakPhys;
// Outer edge of the disc, in r_s. Not a universal constant: it is set by where
// gas is actually supplied, so a preset that puts a star on a 6 AU orbit needs
// a smaller disc than an isolated hole fed from far out.
uniform float discOuter;

#define PI 3.141592653589793
#define STEPS 240

// inner edge of the disc, in r_s — the ISCO of a Schwarzschild hole
#define R_ISCO 3.0

// ----------------------------------------------------------------------------
// noise
// ----------------------------------------------------------------------------
float hash31(vec3 p){
  p = fract(p * vec3(0.1031, 0.1030, 0.0973));
  p += dot(p, p.yxz + 33.33);
  return fract((p.x + p.y) * p.z);
}
float vnoise(vec3 p){
  vec3 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(mix(hash31(i + vec3(0,0,0)), hash31(i + vec3(1,0,0)), f.x),
                 mix(hash31(i + vec3(0,1,0)), hash31(i + vec3(1,1,0)), f.x), f.y),
             mix(mix(hash31(i + vec3(0,0,1)), hash31(i + vec3(1,0,1)), f.x),
                 mix(hash31(i + vec3(0,1,1)), hash31(i + vec3(1,1,1)), f.x), f.y), f.z);
}
float fbm(vec3 p){
  float v = 0.0, a = 0.5;
  for(int i = 0; i < 4; i++){ v += a * vnoise(p); p = p * 2.13 + 17.3; a *= 0.5; }
  return v;
}
float fbm2(vec3 p){   // cheaper, for the domain warp
  return vnoise(p) * 0.65 + vnoise(p * 2.17 + 5.1) * 0.35;
}

// ----------------------------------------------------------------------------
// Planck locus → linear RGB. Colour comes from a temperature, never from a
// hand-picked gradient, so the disc, the stars and the redshift all agree.
// ----------------------------------------------------------------------------
vec3 blackbody(float T){
  T = clamp(T, 800.0, 42000.0);
  float t = T * 0.01;
  vec3 c;
  c.r = t <= 66.0 ? 255.0 : 329.698727446 * pow(max(t - 60.0, 1e-3), -0.1332047592);
  c.g = t <= 66.0 ? 99.4708025861 * log(t) - 161.1195681661
                  : 288.1221695283 * pow(max(t - 60.0, 1e-3), -0.0755148492);
  c.b = t >= 66.0 ? 255.0
      : (t <= 19.0 ? 0.0 : 138.5177312231 * log(max(t - 10.0, 1e-3)) - 305.0447927307);
  c = clamp(c / 255.0, 0.0, 1.0);
  return pow(c, vec3(2.2));                 // sRGB fit → linear
}

// ----------------------------------------------------------------------------
// disc
// ----------------------------------------------------------------------------

// Flaring scale height. Thin discs run H/R ≈ 0.05 and flare outward as r^(9/8).
float scaleHeight(float r, float rs){
  return rs * (0.045 * pow(r / (R_ISCO * rs), 1.125) + 0.012);
}

// Shakura–Sunyaev radial temperature, normalised to peak at 1.
// Peaks at r = (49/36)·r_in where the profile reaches 0.4880.
float ssTemp(float r, float rin){
  float x = rin / r;
  if(x >= 1.0) return 0.0;
  return pow(x, 0.75) * pow(max(1.0 - sqrt(x), 0.0), 0.25) * 2.0492;
}

// Turbulent density in the co-rotating frame — the strands.
float discDensity(vec3 p, float rs, float r, float H){
  float y = p.y / H;
  if(abs(y) > 2.6) return 0.0;
  float vert = exp(-0.5 * y * y);

  float lr  = log(r / rs);
  float phi = atan(p.z, p.x);

  // Keplerian shear. Everything downstream is evaluated at ψ, so the pattern
  // is frozen into the flow: it orbits with the gas rather than sliding over it.
  float om  = 5.0 * pow(r / rs, -1.5);
  float psi = phi + om * time;

  // low-frequency warp braids neighbouring strands over one another
  float w = fbm2(vec3(cos(psi) * 0.55, sin(psi) * 0.55, lr * 2.0 + time * 0.03));
  psi += (w - 0.5) * 1.3;

  // The strong anisotropy is the whole trick: a small azimuthal radius on the
  // noise circle plus a large radial multiplier gives features many radians
  // long and a fraction of a scale-length thick. The y term keeps the field
  // genuinely three-dimensional — extrude a 2D pattern vertically and the
  // disc looks like printed wrapping paper from any angle off the pole.
  float yv = p.y / max(H, 1e-5) * 0.35;
  vec3 q1 = vec3(cos(psi), sin(psi), 0.0) * 0.80 + vec3(0.0, yv, lr * 11.0);
  vec3 q2 = vec3(cos(psi), sin(psi), 0.0) * 2.20 + vec3(0.0, yv * 2.0, lr * 30.0);
  float f1 = fbm(q1 + vec3(0.0, 0.0,  time * 0.035));   // slow decorrelation
  float f2 = fbm(q2 - vec3(0.0, 0.0,  time * 0.080));

  float strands = f1 * 0.70 + f2 * 0.44;
  // Contrast curve. This is what decides whether you see strands at all: the
  // disc is optically thick, so structure is only visible where the optical
  // depth swings from ≫1 (opaque filament) to ≪1 (see-through gap). A gentle
  // curve leaves everything uniformly opaque and the disc reads as a smooth
  // painted sheet, which is precisely the "cartoony" failure mode.
  strands = pow(clamp(strands * 1.70 - 0.52, 0.0, 1.0), 2.2);

  // a pair of broad spiral density waves, wound by the same shear
  float arms = 0.72 + 0.28 * sin(2.0 * psi + lr * 4.5);

  // taper both edges so the disc doesn't end on a hard rim
  float rn    = (r / rs - R_ISCO) / max(discOuter - R_ISCO, 1e-3);
  float edge  = smoothstep(0.0, 0.10, rn) * (1.0 - smoothstep(0.55, 1.0, rn));

  return strands * arms * vert * edge * 9.0;
}

// The SOURCE FUNCTION S = j/κ at one point of the disc, already transported to
// the observer. Note it does not depend on density: for an optically thick
// medium you see a photosphere whose brightness is set by temperature alone,
// and density only decides how deep into it you can see. Density enters this
// integral through the optical depth, never through the emissivity.
vec3 discSource(vec3 p, vec3 rd, float rs, float r, float dens, out float Tphys){
  float rin = R_ISCO * rs;
  float Tn  = ssTemp(r, rin);

  // Peak colour temperature — the "Disc Temp" control. A real stellar-mass
  // disc runs to ~10⁷ K and is an X-ray source with no visible colour left at
  // all, so this is the one place the physics is deliberately rescaled: the
  // range is set so the visible gradient spans the same *shape* the true
  // profile has (hot inner ridge → cool outer rim) in colours an eye can read.
  // T falls only as r^(−3/4), so across 3→15 r_s the profile drops to ~0.53 of
  // peak — the peak has to sit low enough that the outer disc lands in warm
  // orange rather than everything being 6000 K and white.
  float Tpeak = mix(3200.0, 12000.0, discTemp);
  float Temit = Tpeak * max(Tn, 0.02);

  // circular-orbit speed measured by a static local observer
  float grav = sqrt(max(1.0 - rs / r, 1e-4));
  float beta = clamp(sqrt(0.5 * rs / r) / grav, 0.0, 0.96);
  float gam  = 1.0 / sqrt(max(1.0 - beta * beta, 1e-4));

  vec3 vhat = normalize(vec3(-p.z, 0.0, p.x));      // prograde tangent
  vec3 nobs = -rd;                                   // back along the ray, to the eye
  float dop = 1.0 / (gam * (1.0 - beta * dot(vhat, nobs)));

  float g = clamp(dop * grav, 0.04, 5.0);

  // T_obs = g·T_emit — the approaching limb is genuinely hotter-looking, not
  // just brighter. This is what turns one side blue-white and the other red.
  vec3 col = blackbody(Temit * g);

  // The physically true observed temperature, carried alongside the display
  // colour. Same profile, same redshift — only the peak differs.
  Tphys = discTpeakPhys * max(Tn, 0.02) * g;

  // I_obs ∝ g⁴ (Liouville, bolometric). Radial falloff is softened from the
  // strict T⁴ of Stefan–Boltzmann to T^2.6 — the true law makes everything
  // outside ~6 r_s numerically black, which is accurate and unwatchable.
  float emis = pow(Tn, 2.6) * pow(g, 4.0);

  // Turbulent heating. Angular-momentum transport is not smooth: the magnetic
  // stress that actually dissipates the orbital energy is concentrated in the
  // dense filaments, so they run hotter and brighter than the gas between
  // them. Without this the strands only show as *opacity*, which is visible
  // near the inner edge and invisible across the optically thick outer disc —
  // the whole outer disc reads as one smooth painted sheet.
  float heat = 0.40 + 0.85 * min(dens, 1.8);

  return col * emis * heat * discIntensity * 0.62;
}

// ----------------------------------------------------------------------------
// null geodesic
// ----------------------------------------------------------------------------
vec3 geoAccel(vec3 pos, vec3 vel){
  vec3 a = vec3(0.0);
  for(int k = 0; k < ${MAX_HOLES}; k++){
    if(k >= holeCount) break;
    vec3 rv = pos - holePos[k];
    float r = max(length(rv), 1e-5);
    vec3 hv = cross(rv, vel);
    a += -1.5 * holeRs[k] * dot(hv, hv) * rv / (r * r * r * r * r);
  }
  return a;
}

void main(){
  vec2 ndc = vUv * 2.0 - 1.0;
  ndc.x *= aspect;
  float f = tan(fov * 0.5);
  vec3 rl = normalize(vec3(ndc.x * f, ndc.y * f, -1.0));
  vec3 rd = normalize((camMat * vec4(rl, 0.0)).xyz);

  vec3 pos = camPos;
  vec3 vel = rd;
  vec3 color = vec3(0.0);
  // Grey by construction: every attenuation below is exp(-tau) with a scalar
  // tau, so the three channels were always carrying the same number.
  float trans = 1.0;
  bool captured = false;
  float tSum = 0.0, tWeight = 0.0;      // luminance-weighted mean disc temperature

  float rsMax = holeRs[0];
  for(int k = 1; k < ${MAX_HOLES}; k++){ if(k < holeCount) rsMax = max(rsMax, holeRs[k]); }

  // escape radius: comfortably outside both the disc and the camera
  float camR = distance(camPos, holePos[0]);
  float far  = max(camR * 1.4 + 40.0 * rsMax, 120.0 * rsMax);

  for(int i = 0; i < STEPS; i++){
    // ---- adaptive step: fine near a horizon and near a disc plane, coarse in
    // empty space. This is what resolves the photon ring without 2000 steps.
    float step = 1e9;
    float minr = 1e9;
    for(int k = 0; k < ${MAX_HOLES}; k++){
      if(k >= holeCount) break;
      float rs = holeRs[k];
      vec3 pl  = pos - holePos[k];
      float r  = length(pl);
      minr = min(minr, r);
      if(r < rs){ captured = true; }

      step = min(step, max(0.16 * (r - rs), 0.012 * rs));
      step = min(step, r * 0.30);

      // never leap over the slab: cap by the distance to the equatorial plane
      float rcyl = length(pl.xz);
      if(rcyl < discOuter * rs * 1.5 && abs(pl.y) < discOuter * rs){
        float H = scaleHeight(max(rcyl, R_ISCO * rs), rs);
        step = min(step, max(abs(pl.y) * 0.45, H * 0.7));
      }
    }
    if(captured) break;
    if(minr > far) break;
    step = clamp(step, rsMax * 0.010, 12.0 * rsMax);

    // ---- RK2 midpoint on the exact null-geodesic equation
    vec3 k1  = geoAccel(pos, vel);
    vec3 vh  = normalize(vel + k1 * (step * 0.5));
    vec3 ph  = pos + vel * (step * 0.5);
    vec3 k2  = geoAccel(ph, vh);
    vec3 nvel = normalize(vel + k2 * step);
    vec3 npos = pos + nvel * step;

    // ---- volumetric disc sample at the segment midpoint
    vec3 mid = mix(pos, npos, 0.5);
    for(int k = 0; k < ${MAX_HOLES}; k++){
      if(k >= holeCount) break;
      float rs = holeRs[k];
      vec3 pl = mid - holePos[k];
      float r = length(pl.xz);
      if(r < R_ISCO * rs || r > discOuter * rs) continue;
      float H = scaleHeight(r, rs);
      float dens = discDensity(pl, rs, r, H);
      if(dens <= 0.0015) continue;

      // emission with absorption over the segment — the near side of the disc
      // really does occlude the lensed image of the far side
      // Exact solution of dI/dτ = S − I over the segment: I += S(1 − e^−τ).
      // A Shakura–Sunyaev disc is optically THICK, so dense filaments saturate
      // at the source function instead of integrating without bound the way a
      // glowing fog would — and the near side genuinely occludes the lensed
      // image of the far side underneath it.
      float dl  = step / max(rs, 1e-4);
      float tau = dens * dl * 4.5;
      float att = exp(-tau);
      float Tphys;
      vec3 add = trans * discSource(pl, nvel, rs, r, dens, Tphys) * (1.0 - att);
      color += add;
      // weight by how much this sample actually contributed to the pixel, so
      // the reported temperature is the one you are really looking at
      float w = dot(add, vec3(0.2126, 0.7152, 0.0722));
      tSum += w * Tphys; tWeight += w;
      trans *= att;
    }

    if(trans < 0.004) break;
    vel = nvel;
    pos = npos;
  }

  // ---- hand over to the resolve pass
  //
  // The direction is stored as a DELTA from the undeflected ray rather than
  // absolutely, and that is not a packing trick - it is what makes half-float
  // survivable here. Deflection falls to zero away from the hole, which is most
  // of the frame, so the delta is smallest exactly where the sky needs the most
  // angular precision, and fp16 spends its mantissa on the bend instead of on
  // the unit vector the bend is a small correction to. It also means the
  // resolve pass reconstructs d as (exact full-res ray + interpolated delta),
  // so the interpolation error is proportional to the deflection gradient
  // rather than to the direction itself.
  vec3 d = normalize(vel);

  // Zeroing transmittance on capture is what removes the need for a separate
  // captured flag: the resolve pass multiplies the sky by it, and a captured
  // ray contributes no sky by construction.
  float tr = captured ? 0.0 : trans;

  float Tmean = tWeight > 1e-9 ? tSum / tWeight : 0.0;

  gMarch0 = vec4(color, tr);
  gMarch1 = vec4(d - rd, Tmean > 1.0 ? log(Tmean) : 0.0);
}`;

const MARCH_VERT = `
precision highp float;
in vec3 position;
in vec2 uv;
out vec2 vUv;
void main(){ vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }`;

// ----------------------------------------------------------------------------
// pass 2 — resolve
// ----------------------------------------------------------------------------
// Full display resolution. Reads the marched direction field, evaluates the sky
// along it, and composites. This is where the alpha protocol is decided, so the
// reasoning that used to live at the end of the marcher lives here now.
const RESOLVE_FRAG = `
precision highp float;
varying vec2 vUv;

uniform sampler2D tMarch0, tMarch1;
uniform mat4  camMat;
uniform float fov, aspect;

// The sky. Procedural, resolution-free and band-aware — see sim/sky.js for why
// a texture cannot survive this pass. It brings its own uniforms and its own
// hash/noise/blackbody, all prefixed sky_, so nothing here collides with it.
${SKY_GLSL}

void main(){
  // The undeflected ray, recomputed exactly as the marcher built it, at FULL
  // resolution. Adding back the stored delta reconstructs the outgoing
  // direction; the half of that sum which carries the pixel grid is exact.
  vec2 ndc = vUv * 2.0 - 1.0;
  ndc.x *= aspect;
  float f = tan(fov * 0.5);
  vec3 rl = normalize(vec3(ndc.x * f, ndc.y * f, -1.0));
  vec3 rd = normalize((camMat * vec4(rl, 0.0)).xyz);

  vec4 m0 = texture2D(tMarch0, vUv);   // disc rgb, transmittance
  vec4 m1 = texture2D(tMarch1, vUv);   // direction delta, log mean T

  vec3  color = m0.rgb;
  float tr    = m0.a;
  vec3  d     = normalize(rd + m1.xyz);

  // These two derivatives are the whole lensing story as far as the sky is
  // concerned. dFdx/dFdy of the OUTGOING direction span the patch of sky this
  // pixel maps back onto: their cross product is its solid angle and carries
  // det J, and the pair together carry the anisotropy. sim/sky.js turns that
  // into stars that stay point-like and brighten by the magnification, with
  // extended sources holding their surface brightness — which is what lensing
  // actually does, and the thing a texture lookup could never reproduce.
  //
  // They are taken OUTSIDE the branch on purpose: dFdx/dFdy are only defined
  // under uniform control flow, and transmittance goes to zero from pixel to
  // pixel along the entire edge of the shadow — precisely where the ring is.
  //
  // Taken at full resolution on a field that was marched more coarsely. Where
  // that field is smooth, bilinear interpolation is exact to first order and
  // this is the same Jacobian the single-pass version computed. Where it is not
  // smooth the derivative blows up — and sim/sky.js already clamps w2 for
  // exactly that reason, because a ray that winds several times around the
  // photon sphere lands somewhere unrelated to its neighbour at ANY resolution.
  // Marching coarsely widens that region; it does not create it.
  vec3 ddx = dFdx(d), ddy = dFdy(d);

  vec3 skyCol = vec3(0.0);
  if(tr > 0.001) skyCol = tr * skyRadiance(d, ddx, ddy);
  color += skyCol;

  // Alpha carries the physical temperature, log-encoded, for the spectral
  // re-imaging pass. A pixel with no emitter on it is SKY_ALPHA rather than
  // 1.0: the sky is composited in the current band already (sim/spectrum.js
  // cannot re-image synchrotron, line emission or the CMB from a temperature),
  // so the remap must pass it through rather than infer a temperature from it.
  // 1.0 still means "infer from colour", which is what lit geometry wants.
  //
  // ONE ALPHA, TWO POSSIBLE SOURCES. A pixel looking through a partly
  // transparent disc holds both, and a single channel cannot label both, so it
  // is labelled by whichever actually DOMINATES it. Without the comparison the
  // disc claimed the pixel on any emission at all, however faint — so the thin
  // outer disc, contributing a few percent of the light, took the label and
  // deleted a whole star field pixel from every non-visible band.
  //
  // The disc's luminance-weighted contribution is just the luminance of what it
  // accumulated, so the two are directly comparable. This does not make mixed
  // pixels correct — the minority component is still dropped — and doing that
  // properly means giving the sky its own render target. It removes the visible
  // failure mode.
  float tWeight = dot(m0.rgb, vec3(0.2126, 0.7152, 0.0722));
  float skyLum  = dot(skyCol, vec3(0.2126, 0.7152, 0.0722));
  bool discWins = m1.a > 0.0 && tWeight > skyLum;
  float a = discWins ? clamp(m1.a / 25.33, 0.0, 0.98) : ${SKY_ALPHA};
  gl_FragColor = vec4(color, a);
}`;

const VERT = `
  varying vec2 vUv;
  void main(){ vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }`;

/**
 * Default lens scale — the marcher's resolution as a fraction of the display's.
 *
 * The pass scales very nearly linearly with pixel count (measured: 3.89x faster
 * for 4x fewer pixels, close in on a merger), because it is one fullscreen
 * shader with no geometry, so this is the strongest single control there is.
 * Half is the point where the disc and the shadow are still clean and the cost
 * has come down by ~4x; the sky does not participate, so the stars are full
 * resolution either way.
 */
export const DEFAULT_LENS_SCALE = 0.5;

export function createBlackHolePass() {
  // ONE uniforms object, shared by both materials. The orchestrator sets hole
  // positions, camera and disc parameters in one place and does not have to
  // know the pass is split; Three uploads to each program only what that
  // program actually declares.
  const uniforms = Object.assign(skyUniforms(), {
    holePos: { value: Array.from({ length: MAX_HOLES }, () => new THREE.Vector3()) },
    holeRs: { value: new Array(MAX_HOLES).fill(0) },
    holeCount: { value: 1 },
    camPos: { value: new THREE.Vector3() },
    camMat: { value: new THREE.Matrix4() },
    fov: { value: 0.87 },
    aspect: { value: 1 },
    time: { value: 0 },
    discIntensity: { value: 0.9 },
    discTemp: { value: 0.6 },
    discOuter: { value: 15.0 },
    discTpeakPhys: { value: 1.1e7 },
    tMarch0: { value: null },
    tMarch1: { value: null },
  });

  // RawShaderMaterial because the marcher writes two attachments, and Three
  // declares its own location-0 output for an ordinary ShaderMaterial.
  const marchMaterial = new THREE.RawShaderMaterial({
    uniforms,
    vertexShader: MARCH_VERT,
    fragmentShader: MARCH_FRAG,
    glslVersion: THREE.GLSL3,
    depthTest: false,
    depthWrite: false,
  });

  const resolveMaterial = new THREE.ShaderMaterial({
    uniforms,
    vertexShader: VERT,
    fragmentShader: RESOLVE_FRAG,
    depthTest: false,
    depthWrite: false,
    // the sky's footprint measurement needs dFdx/dFdy
    extensions: { derivatives: true },
  });

  const quad = new THREE.PlaneGeometry(2, 2);
  const mkScene = (mat) => {
    const s = new THREE.Scene();
    const m = new THREE.Mesh(quad, mat);
    m.frustumCulled = false;
    s.add(m);
    return s;
  };
  const marchScene = mkScene(marchMaterial);
  const resolveScene = mkScene(resolveMaterial);
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

  // Linear filtering is the point: the resolve pass reads this magnified, and
  // the direction field has to interpolate rather than step.
  const mrt = new THREE.WebGLMultipleRenderTargets(1, 1, 2, {
    type: THREE.HalfFloatType,
    minFilter: THREE.LinearFilter,
    magFilter: THREE.LinearFilter,
  });

  let scale = DEFAULT_LENS_SCALE, vw = 1, vh = 1;
  const sizeMRT = () => mrt.setSize(Math.max(1, Math.round(vw * scale)),
                                    Math.max(1, Math.round(vh * scale)));

  return {
    scene: resolveScene, camera, material: resolveMaterial, uniforms,

    /** Display-resolution size, in device pixels. */
    setSize(w, h) { vw = w; vh = h; sizeMRT(); },
    setScale(s) { scale = Math.max(0.1, Math.min(1, s)); sizeMRT(); },
    getScale() { return scale; },
    marchSize() { return [mrt.width, mrt.height]; },

    /** March at lens scale, then resolve into `target` at full resolution. */
    render(renderer, target) {
      renderer.setRenderTarget(mrt);
      renderer.clear();
      renderer.render(marchScene, camera);

      uniforms.tMarch0.value = mrt.texture[0];
      uniforms.tMarch1.value = mrt.texture[1];

      renderer.setRenderTarget(target);
      renderer.clear();
      renderer.render(resolveScene, camera);
    },

    dispose() { mrt.dispose(); quad.dispose(); marchMaterial.dispose(); resolveMaterial.dispose(); },
  };
}
