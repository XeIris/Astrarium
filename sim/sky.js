import * as THREE from 'three';
import { BANDS, VISIBLE_BAND } from './spectrum.js';

// ============================================================================
// SKY — procedural celestial background, resolution-free and band-aware.
// ============================================================================
// The old sky was a 2048x1024 canvas with 9000 dots painted into it. That fails
// for three separate reasons, and only one of them is "not enough texels".
//
// 1. IT WAS ALREADY UNDER-RESOLVED STANDING STILL. 2048 texels across 360deg is
//    0.176deg/texel; the lens pass renders at ~0.05deg/pixel. The map was ~3.5x
//    coarser than the screen before a black hole touched it.
//
// 2. LENSING MAGNIFICATION IS UNBOUNDED. Near the photon ring the Jacobian of
//    the deflection map is near-singular and one texel covers tens of pixels.
//    No fixed-resolution map survives that, at any resolution. You cannot
//    outrun a divergence by adding texels.
//
// 3. THE LENSING RESPONSE WAS PHYSICALLY WRONG. Gravitational lensing conserves
//    surface brightness (Liouville / conservation of etendue) and amplifies
//    FLUX by the magnification mu = 1/|det J|. So an extended source - a
//    nebula, the galactic band - keeps its brightness and merely distorts,
//    while a POINT source stays point-like and gets BRIGHTER. Sampling stars
//    from a texture forces them into the extended-source behaviour, which is
//    why the Einstein ring read as stretched paint instead of a ring of
//    brilliant points.
//
// THE ORGANISING IDEA: SPLIT THE SKY BY HOW LENSING TREATS IT, NOT BY WHAT IT IS
//
//   point layer      stars, pulsars, X-ray binaries, quasars
//                    -> analytic, procedural, no texture, infinite resolution
//   diffuse layer    galactic band, nebulae, CMB, diffuse X-ray background
//                    -> surface brightness conserved; a smooth field is right
//   absorbing layer  interstellar dust
//                    -> multiplies everything behind it, band-dependent
//
// ONE TERM DOES ALL THE LENSING WORK: THE SCREEN-SPACE JACOBIAN
//
//   Let J = [dD/dx, dD/dy] be the 3x2 derivative of the outgoing ray direction
//   with respect to screen pixels. Both derivatives are taken with dFdx/dFdy in
//   the pass that produced the direction, so J costs nothing to obtain and
//   already contains fov, resolution and lensing together. Everything follows
//   from it:
//
//     - w^2 = |dD/dx x dD/dy| is the solid angle of sky this pixel covers, and
//       carries det J. It shrinks as 1/mu wherever the hole magnifies.
//
//     - Diffuse layers ignore J entirely and are evaluated as plain radiance,
//       so their surface brightness is conserved for free.
//
//     - A star's offset is solved for IN PIXELS: given a star direction s,
//       solve J p = (s - D) in least squares. The PSF is then a fixed circular
//       Gaussian in p, so the star is the same little disc on screen no matter
//       what the lens is doing. Normalising the kernel through J divides by
//       w^2, giving  L = F * G(p) / w^2  — and since w^2 goes as 1/mu, the peak
//       radiance rises exactly as mu. Flux amplification, point sources that
//       stay points, and the anisotropy of the mapping, from one expression.
//
//   Working in PIXELS rather than in source angle is the part that matters.
//   Blur a star by a fixed angle on the source sphere and the lens stretches
//   that kernel tangentially into an arc — which is the correct image of an
//   EXTENDED source, and wrong for a star. The arc is the filter, not the star.
//   Extended things here (galaxies, supernova shells) are deliberately kept in
//   source angle so that they DO arc, which is the honest difference between
//   the two cases.
//
//   This is the ray-bundle filtering of James, von Tunzelmann, Franklin &
//   Thorne (2015) - the DNGR renderer built for Interstellar - who found that
//   point-sampling a star field flickered unacceptably and that the cure was to
//   integrate the sky over each pixel's mapped footprint rather than sample it
//   at a point. Here the bundle is measured rather than traced, which is much
//   cheaper and, for a full-screen pass, just as good.
//
//   The PSF width is a constant number of PIXELS. That is the right invariant:
//   a real instrument's PSF is fixed on its detector by diffraction, not by the
//   pixel grid or the field of view, so a star covers the same little disc
//   however far you zoom. Where a source is smaller than that disc it is
//   clamped in size and DIMMED to conserve flux - the same rule sim/scale.js
//   uses to carry a sub-pixel body on a point-source marker.
//
// THE MAGNITUDE LAW COMES FREE FROM THE CELL SUBDIVISION
//
//   Stars are hashed into cells of a tangent-warped cube map (no equirect pole
//   pinch, no seam, near-equal solid angle per cell). Tier k uses 2^k times as
//   many cells per face edge as tier 0, so tier k holds 4x as many stars as
//   tier k-1. Give each tier one magnitude less flux and you have reproduced
//
//       N(<m)  proportional to  10^(0.6 m)
//
//   the Euclidean star-count law, exactly, as a side effect of the subdivision.
//   Each tier IS one magnitude bin. Calibration anchor: 9096 stars brighter
//   than mag 6.5 over the whole sky (Hipparcos).
//
//   Below the faintest tier the population is not dropped - it is folded into
//   the diffuse layer as INTEGRATED UNRESOLVED STARLIGHT. That is not a cheat:
//   the Milky Way band is unresolved stars. It is also what stops the sky
//   reading as uniform confetti, which was the other half of what looked wrong.
//
// TEMPERATURE, NOT COLOUR
//
//   Every star hashes a TEMPERATURE and gets its colour from the Planck locus,
//   per the house rule in sim/blackhole.js. One number then drives both the
//   visible colour and the band response, so they cannot disagree.
//
//   The temperature is NOT drawn from the initial mass function. A
//   magnitude-limited sky is Malmquist-biased: luminous stars are visible from
//   much further away, so the naked-eye sky is dominated by hot B/A stars and
//   distant giants, not by the M dwarfs that dominate by number. The draw below
//   is weighted for what a magnitude-limited sample actually contains.
//
// BANDS: WHY THE SKY CANNOT GO THROUGH sim/spectrum.js
//
//   spectrum.js re-images BLACKBODY CONTINUUM: it recovers a temperature and
//   evaluates a Planck ratio. That is right for stars and for the disc. It
//   cannot produce a real multiwavelength sky, because nearly everything that
//   dominates the sky outside the visible is not thermal continuum at all -
//   21 cm and CO lines, synchrotron power laws, pi-zero decay gamma rays, and
//   the CMB. spectrum.js says as much in its own header.
//
//   So the sky is composited PER BAND here, at the band's own frequency:
//
//       L(d, nu) = sum_i  spatial_i(d) * spectral_i(nu) * prod_j ext_j(d, nu)
//
//   where spectral_i is a hand-authored per-band weight for the non-thermal
//   components (tables below, with their justification) and a real Planck FLUX
//   ratio for the stars. The result is written already-in-band and marked with
//   SKY_ALPHA so the remap passes it through untouched instead of trying to
//   infer a temperature from it.
//
//   Note the stars need a FLUX ratio, not the surface-brightness ratio
//   spectrum.js uses. In the Rayleigh-Jeans limit a star's surface brightness
//   ratio is ~1, which would keep stars blazing in the radio; what actually
//   removes them is the nu^3 prefactor acting on their tiny solid angle. Carry
//   the prefactor and a 6000 K star comes out 6e-11 times as bright at 1 GHz as
//   in the visible - gone, which is the correct and much more striking answer.
//
//   One consequence worth stating: LENSING IS ACHROMATIC. A black hole deflects
//   every wavelength identically - there is no dispersion in vacuum - so the
//   distortion geometry is pixel-identical in all seven bands and only the
//   source content changes. Switching bands with the ring on screen is a fair
//   demonstration of that.
// ============================================================================

/**
 * Alpha sentinel meaning "this pixel is sky, already imaged in the current
 * band - do not infer a temperature, do not apply a Planck ratio".
 *
 * The existing protocol in sim/spectrum.js is: alpha in (0.005, 0.985) carries
 * log T, anything else means "infer T from colour". That fallback is still what
 * lit geometry wants (it writes alpha 1.0 and really is blackbody-coloured), so
 * the sky needs its own value rather than reusing 1.0. 0.995 sits in the unused
 * gap and survives half-float storage comfortably - fp16 spacing near 1.0 is
 * 4.9e-4, so the test window below is ~9 representable steps wide.
 */
export const SKY_ALPHA = 0.995;

// ----------------------------------------------------------------------------
// Per-band spectral weights.
// ----------------------------------------------------------------------------
// Band order matches sim/spectrum.js BANDS:
//   0 radio 1 GHz   1 microwave 100 GHz   2 infrared 10 um   3 visible
//   4 ultraviolet   5 X-ray 0.3 keV       6 gamma ~100 keV
//
// These are RELATIVE radiances within a component, normalised to that
// component's peak band, and they are authored rather than derived because the
// underlying emission is non-thermal. Each entry carries the reason.
const W = {
  // Cosmic-ray electrons spiralling in the galactic magnetic field. Power law,
  // I ~ nu^-0.7, so it is overwhelming at 1 GHz and negligible by the infrared.
  // This is what the 408 MHz all-sky maps are made of: a bright plane plus a
  // huge loop arching out of it.
  synchrotron:  [1.00, 0.10, 0.004, 0.0008, 0.0004, 0.0, 0.0],

  // Neutral atomic hydrogen, 21 cm. A line, and a radio-only one.
  hydrogen21:   [0.60, 0.05, 0.0, 0.0, 0.0, 0.0, 0.0],

  // The cosmic microwave background: 2.725 K, filling the sky in every
  // direction. It exists in exactly one of these windows, and in that window it
  // is the entire sky. Nothing else here does that.
  cmb:          [0.01, 1.00, 0.0, 0.0, 0.0, 0.0, 0.0],

  // Interstellar dust re-radiating the starlight it absorbed, ~20 K. THE key
  // inversion in the whole feature: the lanes that are black in the visible are
  // the brightest structure on screen at 10 um.
  dustEmission: [0.0, 0.25, 1.00, 0.0, 0.0, 0.0, 0.0],

  // Integrated light of stars below the resolution limit - the galactic band
  // itself. Follows the stellar population, so it peaks in the visible/near-IR.
  starGlow:     [0.0, 0.0, 0.35, 1.00, 0.12, 0.0, 0.0],

  // The bulge is an old population dominated by cool K giants: redder than the
  // disc, and almost absent in the ultraviolet.
  bulge:        [0.0, 0.0, 0.60, 1.00, 0.05, 0.0, 0.0],

  // H II regions: recombination lines (H-alpha dominates the visible), warm
  // dust in the IR, thermal free-free bremsstrahlung in the radio.
  hii:          [0.25, 0.10, 0.50, 1.00, 0.30, 0.0, 0.0],

  // Reflection nebulae are starlight scattered off dust - Rayleigh-ish, so they
  // are blue and they survive into the ultraviolet.
  reflection:   [0.0, 0.0, 0.05, 1.00, 0.80, 0.05, 0.0],

  // External galaxies: an integrated stellar population plus their own dust.
  // Broad, and the only component here that is genuinely isotropic.
  galaxies:     [0.05, 0.02, 0.40, 1.00, 0.30, 0.05, 0.01],

  // Diffuse soft X-ray background - the local hot bubble plus the unresolved
  // sum of distant AGN. This is the glow that cold clouds are silhouetted
  // against, which is how the ROSAT all-sky map shows dust as shadows.
  xrayDiffuse:  [0.0, 0.0, 0.0, 0.0, 0.0, 1.00, 0.05],

  // Cosmic rays striking interstellar gas make pi-zeros, which decay to gamma
  // rays. Traces the gas column, so it is a thin bright ridge exactly on the
  // plane, and it is essentially the only diffuse gamma-ray emission there is.
  pionRidge:    [0.0, 0.0, 0.0, 0.0, 0.0, 0.02, 1.00],

  // Supernova remnants: synchrotron shells in the radio, shock-heated gas at
  // 10^6-10^7 K in X-rays. Bright at both ends, nearly invisible between them.
  snr:          [1.00, 0.20, 0.05, 0.02, 0.02, 0.80, 0.10],

  // Pulsars: coherent radio beams and curvature-radiation gamma rays, with
  // almost nothing in between. Crab, Vela and Geminga are gamma-ray point
  // sources long before they are anything else.
  pulsar:       [1.00, 0.15, 0.0, 0.001, 0.001, 0.30, 1.00],

  // X-ray binaries: accretion onto a compact object. The optical counterpart of
  // a bright XRB is often a faint, unremarkable star.
  xrb:          [0.05, 0.0, 0.02, 0.001, 0.01, 1.00, 0.15],

  // Blazars - jets pointed at us. Isotropic on the sky, unlike everything
  // galactic, and they dominate the gamma-ray point-source population.
  blazar:       [0.80, 0.20, 0.05, 0.02, 0.05, 0.50, 1.00],
};

// Extinction by interstellar dust, relative to the visible.
//
// Rising into the ultraviolet is the ordinary ~1/lambda extinction law made
// worse by the 2175 A absorption bump, so UV dust lanes are blacker than
// visible ones. The X-ray entry is a different mechanism entirely -
// photoelectric absorption by metals in the cold gas - but it is large, and it
// is what makes cold clouds appear as shadows against the diffuse X-ray glow.
// Radio and gamma pass through dust essentially untouched.
const EXTINCTION = [0.0, 0.005, 0.06, 1.0, 2.2, 1.4, 0.0];

// Exposure per band, applied to the composited sky before the remap's log
// stretch. This is the sky's own equivalent of a telescope's integration time:
// the bands span too many decades to share one gain. The infrared and
// ultraviolet numbers offset the honest Planck flux ratio for the STARS - at
// 10 um every star is ~20x fainter than in the visible, and lifting that back
// up is exposure, not fudging, because the RELATIVE behaviour between hot and
// cool stars is left exactly as the physics gives it.
// Final per-band exposure trim, applied after the components are summed.
const SKY_GAIN  = [0.75, 0.85, 0.90, 1.0, 0.95, 0.90, 0.80];
// Stars in the visible go to the HDR tone mapper; in every other band they go
// to the remap's log stretch, whose useful range tops out ~35x lower. Hence the
// small numbers outside the visible — it is a change of display scale, not of
// physics. The RELATIVE behaviour between hot and cool stars is left exactly as
// the Planck flux ratio gives it, which is what makes cool giants dominate the
// infrared and hot stars the ultraviolet.
const STAR_GAIN = [0.02, 0.02, 0.10, 1.0, 0.06, 0.02, 0.02];

// ----------------------------------------------------------------------------
// Sky environments.
// ----------------------------------------------------------------------------
// The sim is not obliged to reproduce Earth's sky - these systems are somewhere
// else in the galaxy, or not in one at all. That is a licence worth spending:
// the same code with different parameters gives every preset its own sky, and
// each of these is a real place a star system can be.
export const SKY_ENVIRONMENTS = {
  // Mid-disc, a few kpc out. The familiar arrangement: a band across the sky,
  // a bulge toward the centre, a dust lane bisecting both.
  disc: {
    starDensity: 0.55, planeConcentration: 2.6,
    glow: 1.00, bulge: 1.00, dust: 1.00,
    hii: 1.00, reflection: 1.0, galaxies: 1.0,
    bandScaleH: 0.10, bulgeSize: 0.30,
  },
  // Deep in the core. Sky choked with stars, an enormous bulge, and so much
  // dust that the visible sky is half blocked while the infrared blazes.
  core: {
    starDensity: 3.20, planeConcentration: 3.0,
    glow: 3.20, bulge: 4.50, dust: 2.60,
    hii: 1.80, reflection: 1.4, galaxies: 0.5,
    bandScaleH: 0.13, bulgeSize: 0.85,
  },
  // Inside a globular cluster. Thousands of bright old stars in every
  // direction, no band, no dust, no ongoing star formation.
  globular: {
    // A globular is a halo satellite, so the galaxy is a distant, thin lens
    // seen from OUTSIDE the disc rather than a band wrapped around you — and
    // the cluster's own stars, being local, ignore it entirely.
    starDensity: 9.00, planeConcentration: 0.0,
    glow: 0.45, bulge: 0.55, dust: 0.05,
    hii: 0.0, reflection: 0.0, galaxies: 0.8,
    bandScaleH: 0.045, bulgeSize: 0.22,
  },
  // Out in the halo, or between galaxies. Almost empty: a scattering of faint
  // stars, the galaxy itself reduced to a distant smear, and external galaxies
  // everywhere because nothing is blocking them.
  halo: {
    starDensity: 0.12, planeConcentration: 4.0,
    glow: 0.22, bulge: 0.35, dust: 0.05,
    hii: 0.05, reflection: 0.05, galaxies: 2.6,
    bandScaleH: 0.030, bulgeSize: 0.14,
  },
  // A spiral arm mid-starburst. H-alpha everywhere, blazing OB associations,
  // heavy dust, and the reflection nebulae that go with young hot stars.
  starburst: {
    starDensity: 1.60, planeConcentration: 3.4,
    glow: 1.60, bulge: 0.70, dust: 1.90,
    hii: 4.20, reflection: 2.6, galaxies: 0.9,
    bandScaleH: 0.045, bulgeSize: 0.26,
  },
};

// ============================================================================
// GLSL
// ============================================================================
// Everything is prefixed sky_ because this chunk is concatenated into
// sim/blackhole.js's ray marcher, which has its own hash/noise/blackbody with
// the obvious names. Self-contained beats shared here: one collision inside a
// 400-line shader string is a miserable thing to debug.

export const SKY_GLSL = `
// ---- uniforms --------------------------------------------------------------
uniform vec3  uGalNormal;      // unit normal of the galactic plane
uniform vec3  uGalCenter;      // unit direction toward the galactic centre
uniform vec3  uGalEast;        // completes the frame; longitude runs toward it

uniform float uVisibleBand;    // 1.0 in the visible band, 0.0 otherwise
uniform float uTheta;          // h*nu/k for the current band, in kelvin
uniform float uThetaVis;       // the same for the visible band (the reference)
uniform float uNuRatio3;       // (nu / nu_visible)^3
uniform float uExtCoef;        // dust extinction, relative to the visible
uniform float uSkyGain, uStarGain;

uniform float uStarFlux;       // flux of a tier-0 star, in radiance*steradian
uniform float uStarDensity;    // stars per cell, before plane concentration
uniform float uPlaneConc;      // how much the band crowds stars toward itself
uniform float uPsfPx;          // instrument PSF width, in pixels
uniform float uPixAngle;       // unlensed angular size of one pixel, radians
uniform float uSpikes;         // diffraction spikes on the brightest stars

uniform float uGlow, uBulge, uDust, uHii, uRefl, uGalaxies;
uniform float uBandScaleH, uBulgeSize;

// per-component band weights, set from the tables in sim/sky.js
uniform float uwSynch, uwH21, uwCmb, uwDustEm, uwGlow, uwBulge, uwHii;
uniform float uwRefl, uwGalaxies, uwXrayBg, uwPion, uwSnr, uwPulsar;
uniform float uwXrb, uwBlazar;

#define SKY_PI 3.141592653589793
// Six magnitude bins of resolved stars, then the rest as glow. That cutoff is
// the instrument's confusion limit, and it lands near apparent magnitude 8 —
// a little past the naked-eye limit of 6.5, which is about right for something
// that is explicitly a camera.
#define SKY_TIERS 6

// ---- hashing ---------------------------------------------------------------
// Three independent streams from one 3-vector. The star loop needs several
// uncorrelated values per cell (position, brightness, temperature) and pulling
// them from one hash call is most of the cost saved.
vec3 sky_hash33(vec3 p){
  p = fract(p * vec3(0.1031, 0.1030, 0.0973));
  p += dot(p, p.yxz + 33.33);
  return fract((p.xxy + p.yxx) * p.zyx);
}
float sky_hash13(vec3 p){
  p = fract(p * 0.1031);
  p += dot(p, p.zyx + 31.32);
  return fract((p.x + p.y) * p.z);
}

float sky_vnoise(vec3 p){
  vec3 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(mix(sky_hash13(i + vec3(0,0,0)), sky_hash13(i + vec3(1,0,0)), f.x),
                 mix(sky_hash13(i + vec3(0,1,0)), sky_hash13(i + vec3(1,1,0)), f.x), f.y),
             mix(mix(sky_hash13(i + vec3(0,0,1)), sky_hash13(i + vec3(1,0,1)), f.x),
                 mix(sky_hash13(i + vec3(0,1,1)), sky_hash13(i + vec3(1,1,1)), f.x), f.y), f.z);
}
float sky_fbm(vec3 p, int oct){
  float v = 0.0, a = 0.5;
  for(int i = 0; i < 6; i++){
    if(i >= oct) break;
    v += a * sky_vnoise(p); p = p * 2.07 + 13.7; a *= 0.5;
  }
  return v;
}

// ---- Planck ----------------------------------------------------------------
// Same fit as sim/blackhole.js, kept local to avoid a name collision when this
// chunk is concatenated into it.
vec3 sky_blackbody(float T){
  T = clamp(T, 800.0, 42000.0);
  float t = T * 0.01;
  vec3 c;
  c.r = t <= 66.0 ? 255.0 : 329.698727446 * pow(max(t - 60.0, 1e-3), -0.1332047592);
  c.g = t <= 66.0 ? 99.4708025861 * log(t) - 161.1195681661
                  : 288.1221695283 * pow(max(t - 60.0, 1e-3), -0.0755148492);
  c.b = t >= 66.0 ? 255.0
      : (t <= 19.0 ? 0.0 : 138.5177312231 * log(max(t - 10.0, 1e-3)) - 305.0447927307);
  c = clamp(c / 255.0, 0.0, 1.0);
  return pow(c, vec3(2.2));
}

// ln(exp(u) - 1), stable over the ~14 decades of u the bands demand. At 0.3 keV
// off a 6000 K star u is about 1750, and exp(u) is inf on the first line.
float sky_lnExpm1(float u){
  if(u > 20.0) return u;
  if(u < 1e-4) return log(max(u, 1e-30));
  return log(exp(u) - 1.0);
}

// A star's FLUX in the current band, relative to its flux in the visible:
//
//     F_nu / F_vis  =  (nu/nu_vis)^3 * (exp(theta_vis/T) - 1) / (exp(theta/T) - 1)
//
// The nu^3 prefactor is the part spectrum.js can drop and this cannot. For an
// extended source it cancels against the reference; for a point source of fixed
// solid angle it does not, and it is the entire reason stars are absent from
// the radio sky rather than merely dimmer there.
float sky_starBand(float T){
  if(uVisibleBand > 0.5) return 1.0;
  T = max(T, 1.0);
  float ln = log(uNuRatio3)
           + sky_lnExpm1(uThetaVis / T)
           - sky_lnExpm1(uTheta / T);
  return exp(clamp(ln, -80.0, 12.0));
}

// Emission helper: in the visible a component contributes its true colour, in
// every other band a scalar radiance that the false-colour palette will map.
vec3 sky_emit(vec3 col, float bandWeight, float amp){
  return uVisibleBand > 0.5 ? col * amp : vec3(amp * bandWeight);
}

// ---- galactic frame --------------------------------------------------------
// sin(b) is the component along the plane normal; longitude runs from the
// centre direction toward uGalEast. Both are exact, so the band and the bulge
// stay locked together however the frame is oriented per preset.
float sky_sinb(vec3 d){ return dot(d, uGalNormal); }
float sky_lon(vec3 d){ return atan(dot(d, uGalEast), dot(d, uGalCenter)); }

// Surface brightness of the disc as seen from inside it. Two exponential
// components in latitude - a thin young disc and a thicker old one - times a
// longitude term that brightens toward the centre, because that line of sight
// runs through far more of the disc than the anticentre one does.
float sky_bandProfile(vec3 d){
  float b = abs(sky_sinb(d));
  float thin  = exp(-b / max(uBandScaleH, 1e-3));
  // The broad halo matters as much as the bright core. The naked-eye Milky Way
  // has a concentrated ridge a few degrees wide sitting inside a diffuse glow
  // that reaches tens of degrees; with only the ridge the band reads as a
  // painted stripe rather than as something the galaxy is doing.
  float thick = exp(-b / max(uBandScaleH * 5.0, 1e-3)) * 0.45;
  float l = sky_lon(d);
  float toward = 0.35 + 0.65 * exp(-abs(l) / 1.15);
  return (thin + thick) * toward;
}

// The INTERSTELLAR GAS profile, which is not the stellar one. Gas has a much
// smaller scale height than stars — it cools and settles, while stars are
// scattered out of the plane over billions of years — so everything that traces
// gas rather than starlight (synchrotron, 21 cm, dust, the pi-zero ridge) is a
// far sharper ridge than the visible band is.
//
// Getting this wrong is what makes a first attempt at the radio sky come out as
// a flat magenta wash: built on the stellar profile, the emission is still at a
// third of full scale 25 degrees off the plane, and the log stretch turns that
// into saturated false colour across the entire frame. The real 408 MHz sky is
// more than an order of magnitude down by then.
float sky_gasProfile(vec3 d){
  float b = abs(sky_sinb(d));
  float core = exp(-b / max(uBandScaleH * 0.9, 1e-3));
  float halo = exp(-b / max(uBandScaleH * 4.5, 1e-3)) * 0.07;
  float l = sky_lon(d);
  return (core + halo) * (0.4 + 0.6 * exp(-abs(l) / 1.2));
}

// The bulge: a flattened spheroid around the centre direction, wider in
// longitude than in latitude, as a bar seen from inside the disc must be.
float sky_bulgeProfile(vec3 d){
  float b = sky_sinb(d);
  float l = sky_lon(d);
  float q = (l * l) / (uBulgeSize * uBulgeSize)
          + (b * b) / (uBulgeSize * uBulgeSize * 0.16);
  return exp(-q);
}

// Two-armed spiral modulation in longitude. Cheap, and it keeps the H II
// regions and the young stars from being spread evenly along the band.
float sky_arms(vec3 d){
  return 0.55 + 0.45 * sin(2.0 * sky_lon(d) + 1.1);
}

// ---- dust ------------------------------------------------------------------
// Optical depth of the interstellar dust along this line of sight. It hugs the
// plane far more tightly than the stars do - the dust scale height is roughly a
// third of the stellar one - which is why the lane cuts a clean dark stripe
// through the middle of the band instead of dimming it evenly. The fBm on top
// is what makes dark nebulae: real dust is patchy, not a smooth slab.
float sky_dustTau(vec3 d){
  float b = abs(sky_sinb(d));
  float lane = exp(-b / max(uBandScaleH * 0.34, 1e-3));
  // ("patch" is a reserved word in GLSL — tessellation. It compiles nowhere.)
  float veil = sky_fbm(d * 5.5, 4);
  veil = pow(clamp(veil * 1.55 - 0.25, 0.0, 1.0), 1.6);
  float clumps = pow(clamp(sky_fbm(d * 17.0 + 41.0, 3) * 1.7 - 0.45, 0.0, 1.0), 2.0);
  // Kept to tau of order 1 rather than order 5. The dust lane has to darken the
  // band, not delete it: the two profiles peak in the same place, so an opaque
  // lane cancels the glow exactly where the glow is supposed to be brightest
  // and the band disappears entirely instead of splitting in two.
  return uDust * lane * (0.55 * veil + 1.15 * clumps) * 0.95;
}

// Extinction as a multiplier. In the visible it is chromatic - A(lambda) rises
// toward the blue, so a reddened star goes dim AND orange, which is the single
// most recognisable signature of dust. In every other band one coefficient is
// enough, and outside the optical/UV/X-ray it is essentially unity.
vec3 sky_extinction(float tau){
  if(uVisibleBand > 0.5) return exp(-tau * vec3(0.78, 1.0, 1.38));
  return vec3(exp(-tau * uExtCoef));
}

// ---- cube cells ------------------------------------------------------------
// Direction -> cube face and face coordinates in [-1,1]. A cube beats the
// equirectangular map the old texture used on both counts that matter: cell
// solid angle stays within a factor of ~2.6 instead of collapsing to zero at
// the poles, and there is no seam to point the free-fly camera at.
void sky_cube(vec3 d, out float face, out vec2 fc){
  vec3 a = abs(d);
  if(a.x >= a.y && a.x >= a.z){ face = d.x > 0.0 ? 0.0 : 1.0; fc = vec2(d.y, d.z) / a.x; }
  else if(a.y >= a.z)         { face = d.y > 0.0 ? 2.0 : 3.0; fc = vec2(d.z, d.x) / a.y; }
  else                        { face = d.z > 0.0 ? 4.0 : 5.0; fc = vec2(d.x, d.y) / a.z; }
}
vec3 sky_uncube(float face, vec2 fc){
  if(face < 0.5) return normalize(vec3( 1.0, fc.x, fc.y));
  if(face < 1.5) return normalize(vec3(-1.0, fc.x, fc.y));
  if(face < 2.5) return normalize(vec3(fc.y,  1.0, fc.x));
  if(face < 3.5) return normalize(vec3(fc.y, -1.0, fc.x));
  if(face < 4.5) return normalize(vec3(fc.x, fc.y,  1.0));
  return normalize(vec3(fc.x, fc.y, -1.0));
}

// Tangent warp. Plain cube cells vary ~5x in solid angle between face centre
// and corner; warping the grid through tan(g*pi/4) - the standard equiangular
// cube map - cuts that to 1.30, and the residual is corrected by weighting the
// existence probability below. The result is a genuinely uniform star density
// per steradian, which the old equirect texture never had.
vec2 sky_toGrid(vec2 fc){ return atan(fc) * (4.0 / SKY_PI); }
vec2 sky_fromGrid(vec2 g){ return tan(g * (SKY_PI / 4.0)); }

// Residual solid angle per unit grid area, normalised to 1 at the face centre.
float sky_cellWeight(vec2 fc){
  float s = 1.0 + fc.x * fc.x + fc.y * fc.y;
  return (1.0 + fc.x * fc.x) * (1.0 + fc.y * fc.y) / (s * sqrt(s));
}

// ---- stellar temperature ---------------------------------------------------
// Weighted for a MAGNITUDE-LIMITED sample, not for the initial mass function.
// The sky is not a fair sample of stars: luminous ones are visible from vastly
// further away, so what you actually see is mostly B and A stars plus distant
// giants. Sampling the IMF instead would give a sky of red dwarfs, which is
// true of the galaxy and false of the view.
float sky_starTemp(float u, float tier){
  // Bright tiers skew hotter still: at a fixed apparent magnitude the brightest
  // entries are drawn from a larger volume, so the bias compounds.
  u = clamp(u - 0.10 * (2.0 - min(tier, 2.0)) * 0.5, 0.0, 0.9999);
  if(u < 0.020) return mix(20000.0, 34000.0, u / 0.020);        // O / early B
  if(u < 0.300) return mix( 9000.0, 20000.0, (u - 0.020) / 0.280); // B / A
  if(u < 0.550) return mix( 6500.0,  9000.0, (u - 0.300) / 0.250); // A / F
  if(u < 0.720) return mix( 5200.0,  6500.0, (u - 0.550) / 0.170); // F / G
  if(u < 0.880) return mix( 3900.0,  5200.0, (u - 0.720) / 0.160); // K
  return              mix( 3000.0,  3900.0, (u - 0.880) / 0.120);  // M giants
}

// ---- point layer -----------------------------------------------------------
// THE PSF LIVES IN THE IMAGE PLANE, NOT THE SOURCE PLANE.
//
// This is the difference between a ring of brilliant points and a ring of
// smears, and it is worth being precise about. The obvious implementation
// blurs the star by sigma in SOURCE angle. But near the photon ring the
// magnification is wildly anisotropic - tangential magnification runs far ahead
// of radial - so the lens stretches that source-plane kernel into an arc. Arcs
// are the correct image of an EXTENDED source; a star is a point, and a point
// source stays a point under any lens. The arc was the filter, not the star.
//
// So the offset is measured in PIXELS instead. Let J = [dD/dx, dD/dy] be the
// 3x2 Jacobian mapping screen pixels to sky directions. For a star at sdir,
// solve J p = (sdir - dir) in least squares - the normal equations are a 2x2
// inverse - and p is where the star sits relative to this pixel, in pixels. The
// PSF is then a plain circular Gaussian in p: fixed size on screen, no matter
// what the lens is doing.
//
// Normalisation carries the magnification. Pushing a unit-area image-plane
// kernel through J divides by |det J| = w^2, the source solid angle per pixel:
//
//     L  =  F * G(p) / w^2
//
// and w^2 shrinks as 1/mu where the sky is magnified, so the peak radiance
// rises exactly as mu. Flux amplification and a point that stays a point, from
// one expression, with the anisotropy handled by construction.
//
// The kernel is a bright core plus a wide faint halo, which is what a real PSF
// looks like once scattering in the optics is counted. Both terms are
// area-normalised in pixel units, so the pair integrates to unity.
float sky_psf(vec2 p){
  float s2 = uPsfPx * uPsfPx;
  float r2 = dot(p, p);
  float core = exp(-0.5 * r2 / s2) / (6.2831853 * s2);
  float halo = exp(-0.5 * r2 / (9.0 * s2)) / (6.2831853 * 9.0 * s2);
  return 0.86 * core + 0.14 * halo;
}

// Four diffraction spikes, on the brightest stars only. This is an INSTRUMENT
// signature rather than anything the star does - which is legitimate here,
// because the whole sim is framed as an imaging instrument with selectable
// bands, and every real image of a bright star has them. In pixel space they
// are simply arms along p.x and p.y, so they stay straight and screen-aligned
// however the sky underneath is being bent.
float sky_spike(vec2 p){
  if(uSpikes < 0.01) return 0.0;
  float s = uPsfPx * 1.3;
  float arm = exp(-0.5 * p.y * p.y / (s * s)) * exp(-abs(p.x) / (s * 13.0))
            + exp(-0.5 * p.x * p.x / (s * s)) * exp(-abs(p.y) / (s * 13.0));
  return arm * uSpikes * 0.016 / (6.2831853 * uPsfPx * uPsfPx);
}

// ---- clusters --------------------------------------------------------------
// Stars are not sprinkled independently; they are born in groups and a good
// fraction of the sky's texture is that clumping. Two kinds, and they are
// opposites in every respect that shows:
//
//   open clusters      young, blue, loose, and strictly in the plane
//   globular clusters  ancient, red, tightly bound, and OUT of the plane —
//                      they orbit in the halo, so they are the one stellar
//                      structure that ignores the galactic band entirely
//
// Returned as (density multiplier, temperature bias) and folded into the star
// loop, so a cluster is a real local excess of real stars rather than a sprite.
vec2 sky_clusterField(vec3 dir){
  float boost = 0.0, bias = 0.0;
  for(int i = 0; i < 2; i++){
    float open = float(i);                    // 0 = globular, 1 = open
    float cells = mix(7.0, 11.0, open);
    float face; vec2 fc;
    sky_cube(dir, face, fc);
    vec2 g = sky_toGrid(fc);
    vec2 cell = floor((g * 0.5 + 0.5) * cells);

    for(int oy = -1; oy <= 1; oy++){
      for(int ox = -1; ox <= 1; ox++){
        vec2 cc = cell + vec2(float(ox), float(oy));
        if(cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;
        vec3 h = sky_hash33(vec3(cc + 0.5, face * 31.0 + open * 91.7));
        if(h.x > 0.16) continue;

        vec3 cdir = sky_uncube(face, sky_fromGrid((cc + h.yz) / cells * 2.0 - 1.0));
        // open clusters live in the disc; globulars deliberately do not
        float gate = mix(1.0, sky_bandProfile(cdir), open);
        float rad = mix(0.020, 0.035, open) * (0.5 + h.x * 3.0);
        float d = length(dir - cdir);
        float w = exp(-0.5 * d * d / (rad * rad)) * gate;
        boost += w * mix(14.0, 7.0, open);
        // globulars are metal-poor and old: push the temperature draw toward
        // the K/M end. Open clusters are the reverse, and much more so.
        bias += w * mix(0.28, -0.34, open);
      }
    }
  }
  return vec2(boost, bias);
}

// ---- extended and compact populations --------------------------------------
// Galaxies are the one thing on this sky that is genuinely ISOTROPIC. Everything
// galactic crowds the plane; external galaxies do not care, and they are seen
// THROUGH the whole dust column, so in the visible they thin out and vanish
// behind the band — the zone of avoidance — while in the infrared and X-ray
// they come straight back. That contrast is free here, because the same tau
// that reddens the stars is applied to them.
//
// They are also EXTENDED, which is why they are evaluated in source angle
// rather than in pixels: an extended source really does arc under strong
// lensing, and it should. Clamping the width to the pixel filter and letting
// the 1/sigma^2 normalisation dim it is what makes an unresolved galaxy behave
// like a point again — the same rule sim/scale.js uses for a sub-pixel body,
// and the one continuous expression covers both regimes.
float sky_galaxies(vec3 dir, float w2){
  float acc = 0.0;
  float cells = 9.0;
  float face; vec2 fc;
  sky_cube(dir, face, fc);
  vec2 g = sky_toGrid(fc);
  vec2 cell = floor((g * 0.5 + 0.5) * cells);

  for(int oy = -1; oy <= 1; oy++){
    for(int ox = -1; ox <= 1; ox++){
      vec2 cc = cell + vec2(float(ox), float(oy));
      if(cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;
      vec3 h  = sky_hash33(vec3(cc + 0.5, face * 17.0 + 3.7));
      vec3 h2 = sky_hash33(vec3(cc + 0.5, face * 17.0 + 57.1));
      if(h.x > 0.30 * uGalaxies) continue;

      vec3 gdir = sky_uncube(face, sky_fromGrid((cc + h.yz) / cells * 2.0 - 1.0));
      // a few big ones, many small
      float ang = (2.2e-4 + 2.6e-3 * pow(h2.x, 3.0));
      float sig = max(ang, uPsfPx * sqrt(w2));
      vec3 dd = dir - gdir;
      float r2 = dot(dd, dd);
      if(r2 > 30.0 * sig * sig) continue;
      float flux = uStarFlux * 0.15 * (0.25 + h2.y);
      acc += flux * exp(-0.5 * r2 / (sig * sig)) / (6.2831853 * sig * sig);
    }
  }
  return acc;
}

// Compact non-thermal sources. These are the entire reason the radio, X-ray and
// gamma skies have anything in them once the stars have correctly disappeared:
// pulsars and X-ray binaries are faint or invisible points in the optical and
// dominant elsewhere. Rendered in pixel space like stars, because they are
// point sources in every band that can see them.
//
// "plane" gates the population onto the galactic disc. Blazars are set to 0 —
// they are extragalactic, so they scatter uniformly over the sky, which is
// exactly how a gamma-ray point-source map looks: a bright galactic ridge with
// isotropic sources sprinkled over everything else.
float sky_compact(vec3 dir, vec3 ddx, vec3 ddy, float ga, float gb, float gc,
                  float gdet, float w2, float cells, float seed,
                  float plane, float accept, float flux){
  float acc = 0.0;
  float face; vec2 fc;
  sky_cube(dir, face, fc);
  vec2 g = sky_toGrid(fc);
  vec2 cell = floor((g * 0.5 + 0.5) * cells);

  for(int oy = -1; oy <= 1; oy++){
    for(int ox = -1; ox <= 1; ox++){
      vec2 cc = cell + vec2(float(ox), float(oy));
      if(cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;
      vec3 h = sky_hash33(vec3(cc + 0.5, face * 23.0 + seed));
      vec3 sdir = sky_uncube(face, sky_fromGrid((cc + h.yz) / cells * 2.0 - 1.0));
      float gate = mix(1.0, sky_bandProfile(sdir), plane);
      if(h.x > accept * gate) continue;

      vec3 delta = sdir - dir;
      if(dot(delta, delta) > 400.0 * w2 * uPsfPx * uPsfPx) continue;
      float pu = dot(ddx, delta), pv = dot(ddy, delta);
      vec2 p = vec2(gc * pu - gb * pv, ga * pv - gb * pu) / gdet;
      if(dot(p, p) > 64.0) continue;

      // Same flux normalisation as a star: the 1/w2 is what makes these
      // brighten under lensing instead of just moving.
      acc += flux * (0.3 + 2.4 * h.x / max(accept, 1e-4)) * sky_psf(p) / w2;
    }
  }
  return acc;
}

// Supernova remnants: expanding shells, so they are ANNULI on the sky rather
// than points — bright edge, hollow middle, because the shell is a thin surface
// seen through more material at its limb. Extended, hence source-plane again.
float sky_snr(vec3 dir, float w2){
  float acc = 0.0;
  float cells = 6.0;
  float face; vec2 fc;
  sky_cube(dir, face, fc);
  vec2 g = sky_toGrid(fc);
  vec2 cell = floor((g * 0.5 + 0.5) * cells);

  for(int oy = -1; oy <= 1; oy++){
    for(int ox = -1; ox <= 1; ox++){
      vec2 cc = cell + vec2(float(ox), float(oy));
      if(cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;
      vec3 h = sky_hash33(vec3(cc + 0.5, face * 11.0 + 77.3));
      vec3 sdir = sky_uncube(face, sky_fromGrid((cc + h.yz) / cells * 2.0 - 1.0));
      if(h.x > 0.22 * sky_bandProfile(sdir)) continue;

      float rad = 0.010 + 0.045 * h.x / 0.22;
      float thick = max(rad * 0.22, uPsfPx * sqrt(w2));
      float d = length(dir - sdir);
      float e = (d - rad) / thick;
      acc += exp(-0.5 * e * e) * (0.6 + 0.8 * sky_fbm(dir * 40.0, 3)) * 0.55;
    }
  }
  return acc;
}

// ============================================================================
// skyRadiance
// ----------------------------------------------------------------------------
//   dir      outgoing ray direction, normalised (after lensing, if any)
//   ddx,ddy  screen derivatives of that direction. These ARE the lensing, as
//            far as the sky is concerned: their cross product is the pixel's
//            source solid angle and carries det J, and the pair together give
//            the anisotropy that keeps a magnified star from smearing.
// ============================================================================
vec3 skyRadiance(vec3 dir, vec3 ddx, vec3 ddy){
  vec3 total = vec3(0.0);

  // Source solid angle per pixel. Clamped by SCALING THE BASIS rather than the
  // area, so the Jacobian stays consistent with the number it reports.
  //
  // Both ends matter. The lower cap bounds magnification at ~1000x, past which
  // a real point source stops being one anyway. The upper cap is the important
  // one: rays that wind several times around the photon sphere land in
  // completely different places from one pixel to the next, so the derivative
  // there is not a footprint but noise, and without a cap the ring detonates.
  float w2 = max(length(cross(ddx, ddy)), 1e-16);
  float pix2 = max(uPixAngle * uPixAngle, 1e-16);
  float s = 1.0;
  if(w2 < pix2 * 1.0e-3) s = sqrt(pix2 * 1.0e-3 / w2);
  if(w2 > pix2 * 144.0)  s = sqrt(pix2 * 144.0 / w2);
  ddx *= s; ddy *= s; w2 *= s * s;

  // Normal equations for the least-squares pixel offset, hoisted out of the
  // star loop: p = (JtJ)^-1 Jt delta.
  float ga = dot(ddx, ddx), gb = dot(ddx, ddy), gc = dot(ddy, ddy);
  float gdet = max(ga * gc - gb * gb, 1e-24);

  // Characteristic source-plane radius of the PSF, used only to decide which
  // tiers are still resolvable as points.
  float sigma = uPsfPx * sqrt(w2);

  float band  = sky_bandProfile(dir);
  float bulge = sky_bulgeProfile(dir);
  float tau   = sky_dustTau(dir);
  vec3  ext   = sky_extinction(tau);

  // ------------------------------------------------------------------ stars
  // Stars crowd toward the galactic plane for the same reason the band glows:
  // that is where the disc is. Without this the point layer sits uniformly on
  // top of a structured background and immediately reads as fake.
  vec2 clus = sky_clusterField(dir);
  float density = uStarDensity * (1.0 + uPlaneConc * band + clus.x);

  float face; vec2 fc;
  sky_cube(dir, face, fc);
  vec2 g = sky_toGrid(fc);                      // [-1,1] on this face

  for(int t = 0; t < SKY_TIERS; t++){
    float tier  = float(t);
    float cells = 4.0 * exp2(tier);             // cells per face edge
    // Angular size of one cell. Tier k has 4x the cells and 1/2.512 the flux of
    // tier k-1: one magnitude bin per tier, N(<m) ~ 10^(0.6m) for free.
    float cellAng = (SKY_PI * 0.5) / cells;
    float flux    = uStarFlux * pow(0.398, tier);

    // Resolved as points while the cell is comfortably wider than the PSF;
    // otherwise the tier's light is delivered as its mean surface brightness.
    // The crossfade conserves flux across the transition, which is what stops
    // the LOD boundary showing up as a seam - and because w shrinks under
    // magnification, the ring resolves DEEPER into the luminosity function than
    // the rest of the frame, which is exactly what magnification really does.
    float diffuseMix = smoothstep(cellAng * 2.2, cellAng * 0.7, sigma);
    diffuseMix = 1.0 - diffuseMix;

    if(diffuseMix < 0.999){
      vec2 cell = floor((g * 0.5 + 0.5) * cells);
      for(int oy = -1; oy <= 1; oy++){
        for(int ox = -1; ox <= 1; ox++){
          vec2 cc = cell + vec2(float(ox), float(oy));
          // Cells that fall off the face edge are simply skipped. The stars
          // that would live there belong to the neighbouring face and are
          // found when the ray points at it; the seam is invisible because
          // nothing is stretched across it.
          if(cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;

          vec3 key = vec3(cc + 0.5, face * 64.0 + tier * 7.31);
          vec3 h   = sky_hash33(key);
          vec3 h2  = sky_hash33(key + 19.73);

          vec2 sg  = (cc + h.xy) / cells * 2.0 - 1.0;   // grid coords of the star
          vec2 sfc = sky_fromGrid(sg);
          // Clamped, and the clamp is load-bearing. A cell holds at most one
          // star, so an acceptance probability above 1 cannot deliver the extra
          // light it claims — but the unresolved branch below would happily
          // integrate it. In the globular environment uStarDensity is 9.0 and a
          // cluster boost multiplies that again, so the raw figure reaches ~100
          // and the two branches disagree by that factor. Clamping both is what
          // keeps the LOD crossfade flux-conserving instead of stepping in
          // brightness as a tier goes unresolved.
          float pAccept = min(density * sky_cellWeight(sfc) * 0.62, 1.0);
          if(h2.x > pAccept) continue;

          vec3 sdir = sky_uncube(face, sfc);
          vec3 delta = sdir - dir;
          // Cheap reject before the projection: nothing further than a few
          // footprints away can land inside the kernel.
          if(dot(delta, delta) > 400.0 * w2 * uPsfPx * uPsfPx) continue;

          // Least-squares offset in PIXELS. Everything about the star's
          // rendered shape happens here rather than in source angle, which is
          // what keeps a lensed point source a point instead of an arc.
          float pu = dot(ddx, delta), pv = dot(ddy, delta);
          vec2 p = vec2(gc * pu - gb * pv, ga * pv - gb * pu) / gdet;
          if(dot(p, p) > 64.0) continue;

          // half a magnitude of scatter within the bin, so the tiers do not
          // read as five discrete brightness classes
          float f = flux * pow(10.0, -0.4 * (h.z - 0.5));
          // the cluster bias is what makes an open cluster read blue and a
          // globular read amber, rather than both being a local density bump
          float T = sky_starTemp(clamp(h2.y + clus.y, 0.0, 0.9999), tier);

          // Dividing by w2 is what turns the shrinking footprint into flux
          // amplification: peak radiance rises exactly as mu.
          float amp = f * (sky_psf(p) + sky_spike(p) * step(tier, 0.5)) / w2;
          amp *= sky_starBand(T) * uStarGain * (1.0 - diffuseMix);

          total += sky_emit(sky_blackbody(T), 1.0, amp);
        }
      }
    }

    // the unresolved remainder of this tier, as surface brightness
    if(diffuseMix > 0.001){
      float cellOmega = (4.0 * SKY_PI / 6.0) / (cells * cells);
      float meanT = sky_starTemp(0.45, tier);
      // Same clamped acceptance as the resolved branch. cellWeight is taken at
      // the ray's own cell rather than at each star's position — neighbouring
      // cells differ by well under a percent, and it is the clamp that matters.
      float pMean = min(density * sky_cellWeight(fc) * 0.62, 1.0);
      float amp = diffuseMix * pMean * flux / cellOmega
                * sky_starBand(meanT) * uStarGain;
      total += sky_emit(sky_blackbody(meanT), 1.0, amp);
    }
  }

  total *= ext;

  // ------------------------------------------------------- unresolved starlight
  // Everything fainter than the last tier. This is the galactic band itself:
  // not a painted stripe, but the integrated light of the stars the instrument
  // cannot separate. Extinguished by the same dust as the stars in front of it.
  float glow = uGlow * band * 0.30;
  total += sky_emit(vec3(0.62, 0.66, 0.85), uwGlow, glow) * ext;

  // The bulge is older and redder than the disc, and it sits behind more dust.
  float bul = uBulge * bulge * 0.22;
  total += sky_emit(vec3(1.00, 0.78, 0.52), uwBulge, bul) * ext * ext;

  // --------------------------------------------------------------- nebulae
  float arms = sky_arms(dir);

  // H II regions: ionised hydrogen around young hot stars, so they follow the
  // arms and hug the plane. H-alpha at 656 nm is why they are red.
  float hiiN = pow(clamp(sky_fbm(dir * 7.3 + 5.0, 4) * 1.9 - 0.62, 0.0, 1.0), 2.1);
  float hii  = uHii * hiiN * band * arms * 0.42;
  total += sky_emit(vec3(1.00, 0.20, 0.26), uwHii, hii) * ext;

  // Reflection nebulae: starlight scattered off dust rather than emitted by it.
  // Rayleigh scattering makes them blue, and they only exist where there is
  // BOTH dust and a nearby hot star - hence the product with the dust field.
  float reflN = pow(clamp(sky_fbm(dir * 9.1 + 71.0, 3) * 1.8 - 0.70, 0.0, 1.0), 2.0);
  float refl  = uRefl * reflN * clamp(tau, 0.0, 1.4) * band * 0.26;
  total += sky_emit(vec3(0.34, 0.50, 1.00), uwRefl, refl) * ext;

  // ------------------------------------------------------- non-thermal sky
  // These are the components that make the non-visible bands worth switching
  // to. All are weighted to nothing in the visible by their band tables, so
  // they cost a few multiplies and change the frame completely elsewhere.
  //
  // CONTRAST MATTERS MORE THAN AMPLITUDE HERE. The remap in sim/spectrum.js
  // applies a log stretch tuned so that radiances from about 0.002 to about 0.7
  // fill the palette. The real radio sky spans several hundred between the
  // galactic plane and the poles, and a component carrying a fat isotropic
  // floor collapses that range into a flat wash of false colour — which is
  // exactly what a first pass at this looks like. So the profiles below are
  // sharpened and their floors are kept genuinely small.
  float gas = sky_gasProfile(dir);

  // Synchrotron: bright plane plus a huge loop arching well out of it, which is
  // the single most recognisable feature of the low-frequency radio sky.
  // A narrow arc, not a broad glow. The North Polar Spur is a thin filament
  // that reaches most of the way to the pole; drawn wide it stops being a
  // feature and becomes a floor under the whole frame, which is the difference
  // between a radio sky and a magenta rectangle.
  float loop = exp(-pow(abs(length(dir - normalize(uGalNormal * 0.55 + uGalCenter * 0.83)) - 0.62) * 13.0, 2.0));
  float synch = (gas * 2.6 + loop * 0.30 + 0.0015) * (0.55 + 0.90 * sky_fbm(dir * 3.1, 3));
  total += sky_emit(vec3(0.0), uwSynch, synch * 0.26);

  // Neutral hydrogen, 21 cm: diffuse, filamentary, and everywhere along the plane.
  float h21 = gas * (0.45 + 1.05 * sky_fbm(dir * 6.0 + 31.0, 4));
  total += sky_emit(vec3(0.0), uwH21, h21 * 0.30);

  // The CMB: a nearly uniform floor, plus the dipole from the observer's own
  // motion. In the microwave band it is not a background, it is the sky — so a
  // flat mid-tone everywhere is the correct answer here, not a failure of
  // contrast. It is the one component that SHOULD look featureless.
  // Held well below the galactic dust so the plane still reads as the brightest
  // thing in the frame: the CMB is the floor of the microwave sky, not its
  // ceiling. The fBm term stands in for the primordial anisotropies, which are
  // genuinely tiny — parts in 10^5 — and are exaggerated here only enough to
  // stop the background looking like a flat fill.
  float dipole = 1.0 + 0.16 * dot(dir, uGalEast);
  float aniso  = 1.0 + 0.22 * (sky_fbm(dir * 12.0 + 3.0, 3) - 0.5);
  total += sky_emit(vec3(0.0), uwCmb, dipole * aniso * 0.06);

  // Thermal dust emission. Note this reuses the SAME tau that darkens the
  // visible sky: one dust distribution, absorbing in the optical and glowing in
  // the infrared, so the bright IR lanes land exactly on the black visible ones.
  total += sky_emit(vec3(0.0), uwDustEm, tau * 0.65);

  // Cosmic rays on interstellar gas -> pi-zero decay. Traces the gas column, so
  // it is a thinner, harder-edged ridge than the stellar band, and outside it
  // the gamma sky is very nearly empty.
  float ridge = exp(-abs(sky_sinb(dir)) / max(uBandScaleH * 0.40, 1e-3));
  total += sky_emit(vec3(0.0), uwPion, ridge * 0.45 + 0.0012);

  // Diffuse soft X-ray background, absorbed by the cold gas in front of it.
  // This is the one component that is DIMMER where there is more material, and
  // it is how the ROSAT all-sky map shows molecular clouds: as shadows.
  float xbg = (0.55 + 0.35 * sky_fbm(dir * 2.6 + 9.0, 3)) * exp(-tau * 1.4);
  total += sky_emit(vec3(0.0), uwXrayBg, xbg * 0.12);

  // ------------------------------------------------- galaxies and compact sources
  // Galaxies are extinguished by the full dust column — the zone of avoidance
  // in the visible, and its absence in the infrared.
  float gal = sky_galaxies(dir, w2) * uGalaxies;
  total += sky_emit(vec3(0.86, 0.83, 0.78), uwGalaxies, gal) * ext;

  total += sky_emit(vec3(0.0), uwSnr, sky_snr(dir, w2));

  // Densities chosen so the gamma sky is a ridge plus a scattering of points,
  // which is what a gamma-ray point-source catalogue actually looks like, and
  // so the X-ray sky has a handful of blazing binaries rather than a field.
  float cf = uStarFlux * 0.030;
  total += sky_emit(vec3(0.0), uwPulsar,
    sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2, 13.0,  5.0, 1.0, 0.16, cf * 0.6));
  total += sky_emit(vec3(0.0), uwXrb,
    sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2,  9.0, 61.0, 1.0, 0.13, cf * 0.9));
  total += sky_emit(vec3(0.0), uwBlazar,
    sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2, 11.0, 29.0, 0.0, 0.05, cf * 0.7));

  return total * uSkyGain;
}
`;

// ============================================================================
// Uniforms
// ============================================================================

/**
 * The shared uniform block. Both the lensing pass and the standalone backdrop
 * include SKY_GLSL, so both need exactly these.
 */
export function skyUniforms() {
  return {
    uGalNormal: { value: new THREE.Vector3(0.28, 0.93, 0.24).normalize() },
    uGalCenter: { value: new THREE.Vector3(0.91, -0.22, 0.35).normalize() },
    uGalEast:   { value: new THREE.Vector3(0, 0, 1) },

    uVisibleBand: { value: 1 },
    uTheta:     { value: 0 },
    uThetaVis:  { value: 0 },
    uNuRatio3:  { value: 1 },
    uExtCoef:   { value: 1 },
    uSkyGain:   { value: 1 },
    uStarGain:  { value: 1 },

    uStarFlux:   { value: 2.2e-4 },
    uStarDensity:{ value: 0.70 },
    uPlaneConc:  { value: 2.2 },
    uPsfPx:      { value: 1.25 },
    uPixAngle:   { value: 8.7e-4 },
    uSpikes:     { value: 1 },

    uGlow: { value: 1 }, uBulge: { value: 1 }, uDust: { value: 1 },
    uHii:  { value: 1 }, uRefl:  { value: 1 }, uGalaxies: { value: 1 },
    uBandScaleH: { value: 0.055 }, uBulgeSize: { value: 0.30 },

    uwSynch: { value: 0 }, uwH21: { value: 0 }, uwCmb: { value: 0 },
    uwDustEm: { value: 0 }, uwGlow: { value: 1 }, uwBulge: { value: 1 },
    uwHii: { value: 1 }, uwRefl: { value: 1 }, uwGalaxies: { value: 1 },
    uwXrayBg: { value: 0 }, uwPion: { value: 0 }, uwSnr: { value: 0 },
    uwPulsar: { value: 0 }, uwXrb: { value: 0 }, uwBlazar: { value: 0 },
  };
}

// h/k in kelvin-seconds, as in sim/spectrum.js.
const H_OVER_K = 4.799243e-11;
const NU_VIS = BANDS[VISIBLE_BAND].nu;

/**
 * Point every band-dependent uniform at `bandIndex`. Everything the sky needs
 * to know about the imaging band is set here and nowhere else.
 */
export function applySkyBand(uniforms, bandIndex) {
  const i = Math.max(0, Math.min(BANDS.length - 1, bandIndex | 0));
  const nu = BANDS[i].nu;
  uniforms.uVisibleBand.value = i === VISIBLE_BAND ? 1 : 0;
  uniforms.uTheta.value = H_OVER_K * nu;
  uniforms.uThetaVis.value = H_OVER_K * NU_VIS;
  uniforms.uNuRatio3.value = Math.pow(nu / NU_VIS, 3);
  uniforms.uExtCoef.value = EXTINCTION[i];
  uniforms.uSkyGain.value = SKY_GAIN[i];
  uniforms.uStarGain.value = STAR_GAIN[i];

  const set = (name, table) => { uniforms[name].value = table[i]; };
  set('uwSynch', W.synchrotron);   set('uwH21', W.hydrogen21);
  set('uwCmb', W.cmb);             set('uwDustEm', W.dustEmission);
  set('uwGlow', W.starGlow);       set('uwBulge', W.bulge);
  set('uwHii', W.hii);             set('uwRefl', W.reflection);
  set('uwGalaxies', W.galaxies);   set('uwXrayBg', W.xrayDiffuse);
  set('uwPion', W.pionRidge);      set('uwSnr', W.snr);
  set('uwPulsar', W.pulsar);       set('uwXrb', W.xrb);
  set('uwBlazar', W.blazar);
}

/**
 * Apply a named environment from SKY_ENVIRONMENTS (or an explicit override
 * object) plus the galactic frame orientation.
 *
 * `lat`/`lon` place the observer's view of the galaxy rather than the observer:
 * they rotate the galactic frame relative to the scene, which is what decides
 * where the band crosses the sky.
 */
export function applySkyEnvironment(uniforms, spec = {}) {
  const env = SKY_ENVIRONMENTS[spec.env] || SKY_ENVIRONMENTS.disc;
  const p = { ...env, ...spec };

  uniforms.uStarDensity.value = p.starDensity;
  uniforms.uPlaneConc.value = p.planeConcentration;
  uniforms.uGlow.value = p.glow;
  uniforms.uBulge.value = p.bulge;
  uniforms.uDust.value = p.dust;
  uniforms.uHii.value = p.hii;
  uniforms.uRefl.value = p.reflection;
  uniforms.uGalaxies.value = p.galaxies;
  uniforms.uBandScaleH.value = p.bandScaleH;
  uniforms.uBulgeSize.value = p.bulgeSize;

  // Orient the galactic frame. tilt/roll are plain Euler angles on the plane
  // normal; the centre direction is then any unit vector orthogonal to it.
  const tilt = spec.tilt !== undefined ? spec.tilt : 0.34;
  const roll = spec.roll !== undefined ? spec.roll : 0.9;
  const n = new THREE.Vector3(Math.sin(tilt) * Math.cos(roll), Math.cos(tilt),
                              Math.sin(tilt) * Math.sin(roll)).normalize();
  // Pick any vector not parallel to n, project it out, and that is "toward the
  // centre"; uGalEast completes a right-handed frame so longitude is well
  // defined everywhere.
  const seed = Math.abs(n.y) > 0.9 ? new THREE.Vector3(1, 0, 0) : new THREE.Vector3(0, 1, 0);
  const c = seed.clone().sub(n.clone().multiplyScalar(seed.dot(n))).normalize();
  const e = new THREE.Vector3().crossVectors(n, c).normalize();

  uniforms.uGalNormal.value.copy(n);
  uniforms.uGalCenter.value.copy(c);
  uniforms.uGalEast.value.copy(e);
}

/**
 * The unlensed pixel footprint — the reference the measured per-pixel footprint
 * is compared against to recover the magnification, and the anchor for both
 * ends of the magnification clamp.
 *
 * The PSF itself is not set here. It is a constant number of PIXELS, which is
 * the right invariant for this renderer: an instrument's PSF is fixed on its
 * detector, so a star covers the same little disc on screen whatever the fov
 * and whatever the lens in front of it is doing.
 */
export function applySkyOptics(uniforms, { fov, height }) {
  uniforms.uPixAngle.value = fov / Math.max(1, height);
}

// ============================================================================
// Backdrop pass — the sky when there is no black hole in the scene
// ============================================================================
// Most presets have no hole at all, and those used to rely on
// `scene.background = starTex`. With the sky analytic there is no texture to
// assign, so the non-lensed path needs its own full-screen pass. Keeping a
// baked fallback was the alternative and was rejected: two sources of truth for
// the sky is how "it looks different in the other view" bugs begin.
const BACKDROP_FRAG = `
precision highp float;
varying vec2 vUv;
// No camPos: a sky at infinity does not care where the camera is, only where it
// points. The ray direction comes from camMat/fov/aspect alone.
uniform mat4  camMat;
uniform float fov, aspect;

${SKY_GLSL}

void main(){
  vec2 uv = vUv * 2.0 - 1.0;
  float th = tan(fov * 0.5);
  vec3 dir = normalize((camMat * vec4(uv.x * th * aspect, uv.y * th, -1.0, 0.0)).xyz);

  // Same footprint measurement as the lensed path, so the two views agree on
  // how large and how bright a star is. With no hole in the way the Jacobian is
  // just the pixel grid, and skyRadiance reduces to an ordinary star field.
  gl_FragColor = vec4(skyRadiance(dir, dFdx(dir), dFdy(dir)), ${SKY_ALPHA});
}`;

const BACKDROP_VERT = `
  varying vec2 vUv;
  void main(){ vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }`;

/**
 * A full-screen sky for scenes with no lensing pass. Same GLSL, same uniforms,
 * same look.
 */
export function createSkyBackdrop() {
  const uniforms = Object.assign(skyUniforms(), {
    camMat: { value: new THREE.Matrix4() },
    fov: { value: 0.87 },
    aspect: { value: 1 },
  });

  const material = new THREE.ShaderMaterial({
    uniforms,
    vertexShader: BACKDROP_VERT,
    fragmentShader: BACKDROP_FRAG,
    depthTest: false,
    depthWrite: false,
    extensions: { derivatives: true },
  });

  const scene = new THREE.Scene();
  scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), material));
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

  return { scene, camera, material, uniforms };
}
