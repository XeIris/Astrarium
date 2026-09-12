// ============================================================================
// TERRAIN & SURFACE CLIMATE — the shared GLSL that decides what a solid world
// LOOKS like, from the two things that actually decide it on a real planet:
// where its crust is thick, and how much sunlight and rain each patch gets.
// ----------------------------------------------------------------------------
// The old rocky planet was a canvas of fBm run through a colour ramp. That is
// a texture, not a model, and it shows: the elevation histogram of plain fBm is
// a single hump centred on the mean, so a sea-level cut through it gives
// smooth, rounded, contour-like coasts everywhere, and the colour, being a
// function of height alone, puts the same vegetation at the equator and at
// 70 degrees. Nothing in the picture is a consequence of anything.
//
// Three mechanisms replace it, and between them they are most of what you
// recognise when you look at a photograph of the Earth:
//
//   1. ISOSTASY, which is why coastlines are sharp.
//      Continental crust is ~35 km of low-density granitic rock; oceanic crust
//      is ~7 km of dense basalt. Both float on the mantle, so the continents
//      ride about 4.5 km higher, and Earth's hypsometric curve is BIMODAL —
//      two peaks, one at roughly +0.8 km (continental platform) and one at
//      -4 km (abyssal plain), with very little area in between. That gap is
//      the continental slope, and it is why a coastline is a sharp, fractal,
//      dendritic boundary rather than a soft contour: sea level lands in the
//      empty part of the histogram, where the surface is STEEP. Reproducing
//      the bimodality is a one-line transfer function on the noise, and it is
//      the single biggest difference between this and a height-ramped fBm.
//
//   2. PLATE TECTONICS, which is why mountains come in LINES.
//      Relief is not scattered at random over the crust; it is concentrated at
//      plate boundaries, and which kind of relief depends on whether the
//      plates are converging or separating. A cellular (Worley) partition of
//      the sphere gives the plates; each is given a velocity, and the sign of
//      the closing rate across a boundary selects the outcome — a mountain
//      belt where two continents collide, a trench with a volcanic arc just
//      inboard of it where ocean goes under land, a mid-ocean ridge where two
//      oceanic plates separate.
//
//   3. THE GENERAL CIRCULATION, which is why deserts come in BELTS.
//      Air rises at the equator, dries, and descends near 30 degrees; that
//      descending branch of the Hadley cell is the Sahara, Arabia, the Kalahari,
//      the Atacama and the Australian interior, all at the same latitude on
//      different continents. It rises again at the polar front near 55 degrees
//      (the storm tracks, and the world's temperate forests) and descends at
//      the pole (Antarctica is a desert). Combine that with the Clausius–
//      Clapeyron scaling of how much water air can hold, and precipitation
//      falls out as a function of latitude and temperature. Colour then comes
//      from a Whittaker diagram — biome as a function of mean temperature and
//      annual precipitation — rather than from height.
//
// Everything below is pure GLSL exported as strings, so sim/world.js (the
// climate-driven world) and sim/rocky_visual.js (every other solid planet) get
// the same terrain rather than two models that disagree.
// ============================================================================

// ----------------------------------------------------------------------------
// Value noise on a 3D domain. Sampling in 3D on the unit sphere is what keeps
// the surface free of the seam and the polar pinch that any equirectangular
// texture has; there is no (u, v) anywhere in this file.
// ----------------------------------------------------------------------------
export const NOISE_GLSL = `
  float hash(vec3 p){ return fract(sin(dot(p, vec3(17.1,113.5,7.9))) * 43758.5453); }
  vec3 hash33(vec3 p){
    return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)),
                          dot(p, vec3(269.5, 183.3, 246.1)),
                          dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
  }
  float noise(vec3 p){
    vec3 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
    return mix(mix(mix(hash(i),             hash(i+vec3(1,0,0)), f.x),
                   mix(hash(i+vec3(0,1,0)), hash(i+vec3(1,1,0)), f.x), f.y),
               mix(mix(hash(i+vec3(0,0,1)), hash(i+vec3(1,0,1)), f.x),
                   mix(hash(i+vec3(0,1,1)), hash(i+vec3(1,1,1)), f.x), f.y), f.z);
  }
  float fbm(vec3 p, int oct){
    float v = 0.0, a = 0.5;
    for(int i=0;i<8;i++){ if(i>=oct) break; v += a*noise(p); p *= 2.03; a *= 0.5; }
    return v;
  }
  // Ridged noise: |noise| folded about its midline, which turns the smooth
  // humps of fBm into creased lines. Mountain chains are creases.
  float ridged(vec3 p, int oct){
    float v = 0.0, a = 0.5;
    for(int i=0;i<8;i++){ if(i>=oct) break; v += a*(1.0-abs(noise(p)*2.0-1.0)); p *= 2.11; a *= 0.5; }
    return v;
  }
  // Domain warp — displace the sample point by another noise field before
  // evaluating. Un-warped fBm is isotropic and reads as cloud; warped fBm has
  // the stretched, folded, sheared look of material that has been moved
  // around, which is what crust is.
  vec3 warp(vec3 p, float amt){
    return p + amt * vec3(fbm(p + 19.3, 4), fbm(p + 41.7, 4), fbm(p + 73.1, 4));
  }`;

// ----------------------------------------------------------------------------
// PLATES. A Worley partition of the sphere: jitter one feature point per cell
// of a 3D lattice and find the two nearest. F1 names the plate you are on, F2
// the one across the nearest boundary, and F2 - F1 is (twice) the distance to
// that boundary — zero on it, growing inward. Each plate gets a velocity from
// its own hash, projected into the tangent plane, and the closing rate along
// the line joining the two feature points says what kind of boundary it is.
// ----------------------------------------------------------------------------
export const PLATE_GLSL = `
  // c1/c2 come back as the two nearest feature POINTS; d1/d2 their distances.
  void plateField(vec3 p, out float d1, out float d2, out vec3 c1, out vec3 c2){
    vec3 ip = floor(p); vec3 fp = fract(p);
    d1 = 8.0; d2 = 8.0; c1 = p; c2 = p;
    for(int k=-1;k<=1;k++) for(int j=-1;j<=1;j++) for(int i=-1;i<=1;i++){
      vec3 g = vec3(float(i), float(j), float(k));
      vec3 cell = ip + g;
      vec3 f = g + hash33(cell) - fp;
      float d = dot(f, f);
      if(d < d1){ d2 = d1; c2 = c1; d1 = d; c1 = cell + hash33(cell); }
      else if(d < d2){ d2 = d; c2 = cell + hash33(cell); }
    }
    d1 = sqrt(d1); d2 = sqrt(d2);
  }
  // A plate's drift, tangent to the sphere at p.
  vec3 plateVel(vec3 cell, vec3 p){
    vec3 v = hash33(cell + 5.17) * 2.0 - 1.0;
    return normalize(v - p * dot(v, p) + 1e-5);
  }`;

// ----------------------------------------------------------------------------
// ELEVATION. Returns height in KILOMETRES relative to the datum, so the lapse
// rate below is a real 6.5 K/km and a trench is really 10 km deep. `rug` comes
// back as a 0..1 ruggedness used for shading and for the rain shadow.
// ----------------------------------------------------------------------------
export const ELEVATION_GLSL = `
  uniform float uPlateScale;    // plates across the sphere (Earth: ~3)
  uniform float uLandRelief;    // km from datum to the highest continent
  uniform float uOceanDepth;    // km from datum to the abyssal plain
  uniform float uCrustT;        // the fBm level that IS sea level (see terrainUniforms)

  void terrain(vec3 p, float seed, out float hKm, out float rug){
    vec3 q = warp(p * 1.9 + vec3(seed), 0.55);

    // --- crust thickness. One warped fBm, recentred on the level that makes
    // the requested fraction of the surface continental. The threshold is NOT
    // 1 - landFraction: summed-octave fBm is very nearly Gaussian (measured:
    // mean 0.497, sd 0.1065 over seven octaves), so asking for 32% land by
    // subtracting 0.68 leaves 8% of the surface above the datum. The JS side
    // inverts the normal CDF instead — see terrainUniforms — which is why
    // Earth here has Earth's land fraction rather than a third of it.
    float c = fbm(q, 7) - uCrustT;

    // --- ISOSTASY: push the distribution AWAY from the datum. pow() with an
    // exponent below 1 expands values near zero outward and compresses the
    // tails, turning one hump into two and leaving the continental slope
    // nearly empty. This is the line that makes coastlines sharp.
    float s = sign(c);
    float y = s * pow(min(abs(c) / 0.34, 1.0), 0.55);

    // Continents are rough; the abyssal plain is famously flat (it is buried
    // under kilometres of pelagic sediment), so the two sides get different
    // relief and different detail amplitudes.
    hKm = (y >= 0.0) ? y * uLandRelief : y * uOceanDepth;
    float detailAmp = (y >= 0.0) ? 0.9 : 0.25;
    float fine = (fbm(q * 5.3 + 3.1, 5) - 0.5) * 2.0;
    hKm += fine * detailAmp;

    // --- TECTONICS
    float d1, d2; vec3 c1, c2;
    plateField(p * uPlateScale + vec3(seed * 0.7), d1, d2, c1, c2);
    float edge = (d2 - d1);                          // 0 on the boundary
    float onEdge = 1.0 - smoothstep(0.0, 0.42, edge);
    // Which way the boundary faces, and how fast the two sides close on it.
    vec3 dir = normalize(c2 - c1 + 1e-5);
    float closing = dot(plateVel(c1, p) - plateVel(c2, p), dir);
    float land = smoothstep(-0.2, 0.6, hKm);

    // Convergent: a ridged belt, tall where two continents meet (the Himalaya
    // is 8 km because neither side will subduct), lower as a volcanic arc
    // where ocean goes under land.
    float belt = ridged(warp(p * 7.0 + vec3(seed), 0.2), 5);
    belt = pow(clamp(belt, 0.0, 1.0), 1.6);
    float conv = max(closing, 0.0) * onEdge;
    hKm += belt * conv * mix(2.2, 7.0, land);
    // and the trench that goes with subduction, just OUTBOARD of the arc
    float trench = smoothstep(0.06, 0.0, edge) * conv * (1.0 - land);
    hKm -= trench * 5.0;

    // Divergent: a mid-ocean ridge — a broad swell of young, hot, buoyant
    // crust with a rift valley along its crest.
    float div = max(-closing, 0.0) * onEdge * (1.0 - land);
    hKm += div * (1.6 - 1.1 * smoothstep(0.10, 0.0, edge));

    rug = clamp(belt * conv * 1.6 + abs(fine) * 0.4, 0.0, 1.0);
  }`;

// ----------------------------------------------------------------------------
// SURFACE CLIMATE. Temperature from the annual-mean insolation distribution,
// precipitation from the cells of the general circulation, colour from the two
// together.
// ----------------------------------------------------------------------------
export const CLIMATE_GLSL = `
  uniform float uMeanK;      // global mean surface temperature, K
  uniform float uTransport;  // 0 = radiative equilibrium, 1 = isothermal planet
  uniform float uArid;       // 0..1 global dryness (a world with little water)

  // Annual-mean insolation vs latitude, the standard form used by every 1-D
  // energy-balance model since Budyko and Sellers:
  //     S(phi)/Sbar = 1 + s2 * P2(sin phi),   P2(x) = (3x^2 - 1)/2
  // s2 = -0.482 for Earth's 23.4 degree obliquity; a world tipped further over
  // has a flatter profile, and past 54 degrees s2 changes SIGN and the poles
  // become the hottest part of the planet.
  float insolation(float sinLat, float s2){
    float P2 = 0.5 * (3.0 * sinLat * sinLat - 1.0);
    return max(1.0 + s2 * P2, 0.02);
  }

  // Surface temperature: the radiative-equilibrium gradient T ~ S^(1/4),
  // relaxed toward the global mean by however much heat the atmosphere and
  // ocean move poleward, then a dry-ish 6.5 K/km lapse rate with altitude.
  float surfaceTemp(float sinLat, float hKm, float s2){
    float f = pow(insolation(sinLat, s2), 0.25);
    float T = uMeanK * mix(f, 1.0, uTransport);
    return T - 6.5 * max(hKm, 0.0);
  }

  // Precipitation, 0..1, from the three overturning cells plus Clausius-
  // Clapeyron: saturation vapour pressure rises about 7% per kelvin, so warm
  // air carries far more water and a cold desert is as dry as a hot one.
  // The coefficients are fitted to Earth's annual-mean zonal precipitation:
  // a maximum at the equator, a trough near 30 degrees that is DRY BUT NOT
  // ZERO, a broad secondary maximum over the storm tracks at 45-60, and a
  // polar desert. Getting the trough wrong is what puts a Sahara at the
  // latitude of France.
  float precipitation(float lat, float T, float inland, float shadow){
    float a = abs(lat);
    float itcz  = 0.75 * exp(-pow(a / 0.30, 2.0));           // rising, equator
    float front = 0.42 * exp(-pow((a - 0.90) / 0.40, 2.0));  // rising, ~52 deg
    float horse = 0.42 * exp(-pow((a - 0.55) / 0.22, 2.0));  // sinking, ~31 deg
    float polar = 0.45 * smoothstep(1.00, 1.45, a);          // sinking, pole
    float P = clamp(0.30 + itcz + front - horse - polar, 0.0, 1.0);
    P *= clamp(exp((T - 288.0) / 20.0), 0.05, 1.6);          // moisture capacity
    P *= mix(1.0, 0.45, inland);                             // continentality
    P *= mix(1.0, 0.45, shadow);                             // rain shadow
    return clamp(P * (1.0 - uArid), 0.0, 1.0);
  }

  // Whittaker's biome diagram: what grows somewhere is a function of mean
  // temperature and annual precipitation, and almost nothing else. Read off
  // as a 2-D blend rather than as a lookup so the boundaries are gradients,
  // which is what they are on the ground.
  // The values are ALBEDOS, not palette picks: sand really is around 0.38 and
  // closed-canopy forest really is around 0.12, and it is that three-to-one
  // ratio that makes a photograph of a continent look the way it does. Choose
  // them by eye instead and the deserts come out the same brightness as the
  // grassland, which is the single most obvious way a rendered planet stops
  // looking like a planet.
  vec3 biome(float T, float P, float rug){
    float t = clamp((T - 258.0) / 48.0, 0.0, 1.0);   // -15 C .. +48 C
    vec3 desert  = mix(vec3(0.34,0.30,0.25), vec3(0.44,0.35,0.22), t); // cold->hot
    vec3 grass   = mix(vec3(0.21,0.21,0.14), vec3(0.28,0.26,0.13), t);
    vec3 forest  = mix(vec3(0.07,0.11,0.08), vec3(0.09,0.17,0.07), t); // boreal->temperate
    vec3 jungle  = vec3(0.05,0.12,0.05);
    vec3 tundra  = vec3(0.20,0.19,0.16);

    vec3 col = mix(desert, grass, smoothstep(0.07, 0.22, P));
    col = mix(col, forest,  smoothstep(0.22, 0.44, P));
    col = mix(col, jungle,  smoothstep(0.50, 0.75, P) * smoothstep(0.55, 0.80, t));
    // too cold for trees: the treeline, which is a temperature line
    col = mix(col, tundra, smoothstep(0.16, 0.02, t));
    // exposed rock where the ground is too steep to hold soil
    col = mix(col, vec3(0.23,0.21,0.20), smoothstep(0.45, 0.85, rug));
    return col;
  }`;


// ----------------------------------------------------------------------------
// A CHEAP crust probe — warp + isostasy only, no plates and no fine detail.
// The rain-shadow test needs to know how high the ground is UPWIND, and
// evaluating the full terrain a second time per fragment to find out is not
// worth it: what casts a shadow is the massif, not the scree on it.
// ----------------------------------------------------------------------------
export const COARSE_GLSL = `
  float crustHeight(vec3 p, float seed){
    vec3 q = warp(p * 1.9 + vec3(seed), 0.55);
    float c = fbm(q, 5) - uCrustT;
    float y = sign(c) * pow(min(abs(c) / 0.34, 1.0), 0.55);
    return (y >= 0.0) ? y * uLandRelief : y * uOceanDepth;
  }`;

// ----------------------------------------------------------------------------
// CRATERS. On a body with no atmosphere and no plate tectonics, nothing erases
// an impact: the Moon's surface is a four-billion-year integral of everything
// that ever hit it, and the size distribution is a power law, so every big
// crater is pocked with smaller ones. That is the whole look, and it is not
// something fBm produces — a crater is a DISC with a rim, not a bump.
//
// One layer scatters at most one impact per lattice cell, each with its own
// radius, and draws the real profile: a parabolic bowl inside the rim, an
// uplifted rim at the radius itself, and an ejecta blanket fading outside it.
// Three layers an octave apart give the power law.
// ----------------------------------------------------------------------------
export const CRATER_GLSL = `
  float craterLayer(vec3 p, float seed){
    vec3 ip = floor(p), fp = fract(p);
    float h = 0.0;
    for(int k=-1;k<=1;k++) for(int j=-1;j<=1;j++) for(int i=-1;i<=1;i++){
      vec3 g = vec3(float(i), float(j), float(k));
      vec3 r = hash33(ip + g + seed);
      if(r.z > 0.55) continue;                 // not every cell is hit
      float d = length(g + r - fp);
      float rad = 0.18 + 0.26 * r.z;
      float t = d / rad;
      if(t > 2.0) continue;
      float bowl = (t < 1.0) ? -(1.0 - t*t) * 0.85 : 0.0;
      float rim  = exp(-pow((t - 1.0) * 3.4, 2.0)) * 0.55;
      float ej   = exp(-pow((t - 1.45) * 2.0, 2.0)) * 0.10;
      h += bowl + rim + ej;
    }
    return h;
  }
  // Kilometres of crater relief, plus a 0..1 "freshness" that bright ray
  // systems and dark basin floors are keyed off.
  float craters(vec3 p, float seed, float density, out float fresh){
    float h = craterLayer(p * 7.0  + vec3(seed), seed)
            + craterLayer(p * 15.0 + vec3(seed + 3.0), seed + 3.0) * 0.5
            + craterLayer(p * 31.0 + vec3(seed + 7.0), seed + 7.0) * 0.25;
    fresh = clamp(h * 0.9, 0.0, 1.0);
    return h * 1.6 * density;
  }`;

// Everything a solid-surface shader needs, in dependency order.
export const TERRAIN_GLSL = NOISE_GLSL + PLATE_GLSL + ELEVATION_GLSL + COARSE_GLSL + CRATER_GLSL + CLIMATE_GLSL;

// The fBm level that leaves `land` of the sphere above it. Seven octaves of
// value noise sum to something very close to a normal distribution — measured
// mean 0.4970, standard deviation 0.1065 — so the level is the inverse normal
// CDF, and asking for 29% land gets 29% land. The approximation below is
// Moro's; it is good to about 1e-4 over the range that matters here, which is
// far finer than a coastline.
export function crustThreshold(land) {
  const q = 1 - Math.min(Math.max(land, 0.002), 0.998);
  // rational approximation to the standard normal quantile
  const tail = Math.min(q, 1 - q);
  const t = Math.sqrt(-2 * Math.log(tail));
  let z = t - (2.515517 + 0.802853 * t + 0.010328 * t * t) /
              (1 + 1.432788 * t + 0.189269 * t * t + 0.001308 * t * t * t);
  if (q < 0.5) z = -z;
  return 0.4970 + 0.1065 * z;
}

// JS-side defaults for the uniforms the blocks above declare. A preset can
// override any of them per body.
export function terrainUniforms(opts = {}) {
  return {
    uPlateScale: { value: opts.plateScale ?? 2.6 },
    uLandRelief: { value: opts.landRelief ?? 3.2 },
    uOceanDepth: { value: opts.oceanDepth ?? 4.6 },
    uCrustT:     { value: crustThreshold(opts.continent ?? 0.35) },
    uMeanK:      { value: opts.meanK ?? 288 },
    uTransport:  { value: opts.transport ?? 0.42 },
    uArid:       { value: opts.arid ?? 0 },
  };
}
