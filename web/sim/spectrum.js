// ============================================================================
// SIMULATED MULTI-WAVELENGTH IMAGING
// ----------------------------------------------------------------------------
// Real astronomy almost never looks at things in visible light. The same black
// hole is a faint smudge to the eye, a blazing point in X-rays, and a pair of
// jets in the radio — because what you see is not "the object" but the object's
// Planck spectrum sampled through one narrow window.
//
// This module re-images the rendered frame through a chosen window. It needs
// one thing per pixel that a colour buffer does not normally carry: the
// emitting material's TEMPERATURE. So the emitters publish it directly —
// the accretion disc, stellar photospheres and neutron-star surfaces each
// write their true temperature, log-encoded, into the alpha channel of the HDR
// buffer. Pixels with no such data (lit geometry) fall back to inferring T from
// colour, which works because those were coloured from the Planck locus in the
// first place.
//
// The celestial background does neither. sim/sky.js composites it at the band's
// own frequency and marks it with SKY_ALPHA so this pass hands it straight to
// the palette — see the pass-through in main(). It has to work that way,
// because the non-visible sky is mostly non-thermal and has no temperature for
// a Planck ratio to consume.
//
// Publishing it matters rather than always inferring it: the disc is DRAWN in a
// rescaled palette so it has visible colour at all, and a neutron star's 10⁶ K
// is far off the end of any RGB gamut. Read back from the pixels, both would
// come out at a few thousand kelvin and neither would ever light up in X-rays.
//
// THE CHAIN, PER PIXEL
//
//   1. Recover T — from alpha where an emitter published it, otherwise from the
//      blue/red ratio in linear light, which is monotonic along the Planck locus.
//
//   2. Evaluate the band's surface brightness relative to the band's reference
//      temperature. With B_ν = 2hν³/c² / (exp(hν/kT) − 1), the ν³ prefactor is
//      common to both and cancels, leaving only the Planck exponent — which is
//      the whole story anyway, because the Wien cutoff is what makes the bands
//      differ. A source appears in a band if and only if kT is comparable to
//      hν. Everything is computed in logs: hν/kT reaches ~1750 for soft X-rays
//      off a 6000 K star, which overflows a float on the first line otherwise.
//
//   3. The rendered luminance is used only as a coverage mask — "is there
//      emitting material on this pixel" — never as the band radiance.
//
//   4. Per-band gain, log stretch, false-colour ramp. All three are what a real
//      observatory image does: no telescope image outside the visible is shown
//      in "true" colour, the gain is set for the intended targets, and the
//      dynamic range within one band is far too large for a linear map.
//
// WHAT THIS IS NOT: it re-images blackbody continuum only. Real non-thermal
// emission — synchrotron from a jet, cyclotron lines, molecular lines, 21 cm —
// is not modelled, and neither is reflected starlight or a planet's own thermal
// glow, which is why worlds go dark outside the visible here when a real
// infrared image would show them plainly.
// ============================================================================

// h/k, in kelvin·seconds — converts a frequency straight to the temperature
// scale where that frequency's Planck exponent is unity.
const H_OVER_K = 4.799243e-11;

/**
 * @typedef {Object} Band
 * @property {string} id     internal key
 * @property {string} label  UI label
 * @property {string} short  compact label for the readout
 * @property {number} nu     representative frequency, Hz
 * @property {number} trefFactor  gain, as a multiple of the scene's hottest source
 * @property {number} trefFloor   coldest reference this band may ever expose for, K
 * @property {string} note   one-line description of what it reveals
 */

// Each band's gain is set the way an observer sets one: expose for the
// brightest target actually in the field. `trefFactor` scales the hottest
// source present (a factor of 1 puts it near full scale, larger under-exposes),
// and `trefFloor` is a hard physical limit that scene-adaptive exposure must
// never cross — it is what keeps the statement "you need a million kelvin to
// emit soft X-rays" true. Without the floor, auto-exposure would happily make
// a 5000 K star blaze in the gamma band.
/** @type {Band[]} */
export const BANDS = [
  {
    id: 'radio', label: 'Radio', short: 'RADIO',
    nu: 1e9, trefFactor: 1.8, trefFloor: 2000,
    note: '1 GHz. Far down the Rayleigh–Jeans tail of everything here, where brightness is simply proportional to temperature — so nothing is cut off, and the image is the scene\u2019s temperature map at low gain.',
  },
  {
    id: 'microwave', label: 'Microwave', short: 'MICRO',
    nu: 1e11, trefFactor: 1.3, trefFloor: 2000,
    note: '100 GHz. Still Rayleigh–Jeans for every source in this scene, so it differs from radio only in sensitivity. That similarity is the real physics, not a shortcut.',
  },
  {
    id: 'infrared', label: 'Infrared', short: 'IR',
    nu: 3e13, trefFactor: 1.0, trefFloor: 2000,
    note: '10 µm. The coolest band with a Wien cutoff that bites in this scene: material below ~1500 K begins to fade while stars and the disc stay bright.',
  },
  {
    id: 'visible', label: 'Visible', short: 'VIS',
    nu: 5.45e14, trefFactor: 1.0, trefFloor: 2000,
    note: '550 nm. True colour — the frame exactly as rendered, with no remapping.',
  },
  {
    id: 'ultraviolet', label: 'Ultraviolet', short: 'UV',
    nu: 1.5e15, trefFactor: 1.0, trefFloor: 8000,
    note: '200 nm. The cutoff bites hard: cool K and M stars all but vanish while hot A/B stars and the inner accretion disc blaze.',
  },
  {
    id: 'xray', label: 'X-ray', short: 'X-RAY',
    nu: 7.3e16, trefFactor: 1.0, trefFloor: 1.0e6,
    note: '0.3 keV soft X-ray. Only million-kelvin material survives — the inner disc and neutron-star surfaces. Ordinary stars are black silhouettes.',
  },
  {
    id: 'gamma', label: 'Gamma', short: 'GAMMA',
    nu: 2.4e19, trefFactor: 1.0, trefFloor: 3.0e8,
    note: '~100 keV. Nothing thermal in this scene is hot enough to reach here, so the frame goes black. Real gamma sources are non-thermal (synchrotron, pair processes), which this model does not simulate.',
  },
];

export const VISIBLE_BAND = BANDS.findIndex(b => b.id === 'visible');

/**
 * Uniform values for a band, exposed for a scene whose hottest emitter is
 * `sceneMaxT` kelvin.
 */
export function bandUniformData(index, sceneMaxT = 5800) {
  const b = BANDS[Math.max(0, Math.min(BANDS.length - 1, index))];
  return {
    theta: H_OVER_K * b.nu,
    tref: Math.max(sceneMaxT * b.trefFactor, b.trefFloor),
  };
}

// ----------------------------------------------------------------------------
// The fragment shader. Exported as a string so postfx.js owns the plumbing.
// ----------------------------------------------------------------------------
export const REMAP_FRAG = `
  precision highp float;
  varying vec2 vUv;
  uniform sampler2D tSrc;
  // uTheta = hν/k for the band, in kelvin: the temperature at which this
  // band's Planck exponent is unity, and therefore the band's Wien cutoff.
  uniform float uTheta, uTref;
  uniform int   uPalette;
  uniform float uStretch;

  // --- inverse of the Planck-locus colour fit -------------------------------
  // x = ln(b/r) in LINEAR light. The knots below are that fit evaluated at
  // known temperatures; the curve is steep in the cool half and saturates in
  // the hot half, so a straight exponential fit will not do — this is a
  // piecewise-linear inverse through the tabulated points.
  float estimateT(vec3 c){
    float r = max(c.r, 1e-7);
    float b = max(c.b, 1e-7);
    float x = log(b / r);

    // (x, lnT) knots: 1200 K … 40000 K
    const int N = 7;
    float xs[7]; float ts[7];
    xs[0] = -9.00; ts[0] = 7.090;   //  1200 K
    xs[1] = -6.40; ts[1] = 7.601;   //  2000 K
    xs[2] = -1.851; ts[2] = 8.006;  //  3000 K
    xs[3] = -0.223; ts[3] = 8.661;  //  5772 K
    xs[4] =  0.516; ts[4] = 9.210;  // 10000 K
    xs[5] =  0.883; ts[5] = 9.903;  // 20000 K
    xs[6] =  1.142; ts[6] = 10.597; // 40000 K

    if(x <= xs[0]) return exp(ts[0]);
    for(int i = 1; i < N; i++){
      if(x <= xs[i]){
        float f = (x - xs[i-1]) / max(xs[i] - xs[i-1], 1e-6);
        // Capped well below the fit's own ceiling. Inference is only
        // trustworthy for pixels that really are blackbody-coloured; anything
        // genuinely hotter than this publishes its temperature in alpha
        // instead, so the top of the table only ever gets reached by things
        // that merely happen to be blue — and calling those 40 000 K makes
        // them erupt in the ultraviolet.
        return clamp(exp(mix(ts[i-1], ts[i], f)), 1200.0, 20000.0);
      }
    }
    return 20000.0;
  }

  // ln(exp(u) − 1), stable across the ~14 decades of u this has to span.
  // For a 6000 K star imaged at 1 keV, u ≈ 1750 — evaluate exp(u) directly and
  // the whole calculation becomes inf/inf on the first line.
  float lnExpm1(float u){
    if(u > 20.0)  return u;                        // the −1 is irrelevant
    if(u < 1e-4)  return log(max(u, 1e-30));       // exp(u)−1 → u
    return log(exp(u) - 1.0);
  }

  // Surface brightness in the band at temperature T, relative to the band's
  // reference temperature. The ν³ prefactor is identical top and bottom and
  // cancels, so only the Planck exponent survives — which is the part that
  // does all the work: it is the Wien cutoff, and the Wien cutoff is the
  // entire reason the bands look different from one another. A source shows up
  // in a band if and only if kT is comparable to hν.
  float bandBrightness(float T){
    float lnB = lnExpm1(uTheta / max(uTref, 1.0)) - lnExpm1(uTheta / max(T, 1.0));
    return exp(clamp(lnB, -60.0, 20.0));
  }

  // --- false colour ---------------------------------------------------------
  vec3 ramp(vec3 a, vec3 b, vec3 c, vec3 d, float v){
    v = clamp(v, 0.0, 1.0);
    if(v < 0.3333) return mix(a, b, v * 3.0);
    if(v < 0.6667) return mix(b, c, (v - 0.3333) * 3.0);
    return mix(c, d, (v - 0.6667) * 3.0);
  }

  vec3 palette(float v){
    if(uPalette == 0)        // radio — magenta/orange, VLA-ish
      return ramp(vec3(0.0), vec3(0.16,0.0,0.22), vec3(0.64,0.0,0.43), vec3(1.0,0.62,0.24), v);
    else if(uPalette == 1)   // microwave — cold blue to white, Planck-ish
      return ramp(vec3(0.0), vec3(0.02,0.06,0.24), vec3(0.15,0.55,0.80), vec3(1.0,1.0,1.0), v);
    else if(uPalette == 2)   // infrared — Spitzer/JWST heat scale
      return ramp(vec3(0.0), vec3(0.24,0.04,0.0), vec3(1.0,0.35,0.0), vec3(1.0,0.93,0.72), v);
    else if(uPalette == 4)   // ultraviolet — GALEX-ish indigo
      return ramp(vec3(0.0), vec3(0.10,0.03,0.28), vec3(0.42,0.30,0.95), vec3(0.82,0.93,1.0), v);
    else if(uPalette == 5)   // X-ray — Chandra-ish blue/purple
      return ramp(vec3(0.0), vec3(0.02,0.08,0.30), vec3(0.48,0.22,0.85), vec3(1.0,1.0,1.0), v);
    else                     // gamma — Fermi-ish green/yellow
      return ramp(vec3(0.0), vec3(0.0,0.16,0.06), vec3(0.42,0.86,0.16), vec3(1.0,1.0,0.85), v);
  }

  void main(){
    vec4 src = texture2D(tSrc, vUv);
    vec3 c = src.rgb;
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    if(lum <= 1e-6){ gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0); return; }

    // Emitters publish their TRUE temperature in alpha, log-encoded. This
    // matters because the rendered colour is not always the physical one: the
    // accretion disc is drawn in a rescaled palette so it has visible colour at
    // all, and a neutron star's 10⁶ K is far off the end of any RGB gamut. The
    // reserved value 1.0 means "no data", and those pixels fall back to
    // inferring T from the colour — which is exactly right for the starfield.
    float a = src.a;

    // SKY_ALPHA (0.995, from sim/sky.js) means "already imaged in this band".
    // The celestial background cannot come through the temperature route at
    // all: most of what dominates the sky outside the visible is non-thermal —
    // synchrotron power laws, 21 cm and CO lines, pi-zero decay gammas, the CMB
    // — and none of those have a temperature that a Planck ratio could use. So
    // sim/sky.js composites the sky at the band's own frequency and hands over
    // a finished band radiance; here it only needs the log stretch and the
    // palette, with no coverage mask and no Wien cutoff applied on top.
    if(a > 0.990 && a < 0.9985){
      float sky = dot(c, vec3(0.2126, 0.7152, 0.0722));
      float vs = log(1.0 + sky * uStretch) / log(1.0 + 3.0 * uStretch);
      gl_FragColor = vec4(palette(vs) * 1.55, 1.0);
      return;
    }

    float T = (a > 0.005 && a < 0.985) ? exp(a * 25.33) : estimateT(c);

    // The rendered luminance is used only as a COVERAGE mask — "is there
    // emitting material on this pixel" — never as the band radiance. It cannot
    // be the latter: the accretion disc is drawn in a rescaled palette, so its
    // visible brightness is not B_ν(ν_vis, T_true) and any ratio built on it
    // would be wrong by orders of magnitude. Brightness in the band comes from
    // the temperature alone, which is the physically meaningful route.
    // The mask has to have a real threshold, not just a scale. The sky is not
    // black — there is a faint nebular gradient a few thousandths above zero —
    // and a band gain of several hundred will happily amplify that into a
    // glowing field that swamps the actual sources. Anything this dim is
    // background, not an emitter, and is excluded outright.
    float cover = smoothstep(0.02, 0.25, lum) * clamp(lum / 1.2, 0.05, 1.2);
    float band = cover * bandBrightness(T);

    // Log stretch, anchored so full scale sits a little above the band's
    // reference source. Every astronomical image outside the visible is
    // displayed this way — the dynamic range within one band is far too large
    // for a linear map.
    float v = log(1.0 + band * uStretch) / log(1.0 + 3.0 * uStretch);

    gl_FragColor = vec4(palette(v) * 1.55, 1.0);
  }`;
