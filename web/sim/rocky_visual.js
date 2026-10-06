import * as THREE from 'three';
import { MAX_SUNS, SUN_UNIFORMS, SUN_GLSL, applySuns, insolationAt, litBy } from './suns.js';
import { TERRAIN_GLSL, NOISE_GLSL, terrainUniforms } from './terrain.js';
import { loadPlanetMap } from './planetmaps.js';

// ============================================================================
// SOLID-SURFACE WORLDS
// ----------------------------------------------------------------------------
// Every planet that is not a gas giant is drawn by this file: Earth, Mars, the
// Moon, Mercury, Pluto, and whatever the Object Foundry makes. Named Earth,
// Mars and Moon bodies use measured imagery for their geography; invented
// worlds and other bodies keep the procedural terrain. Both paths use the same
// shader, lighting, volatile and climate uniforms:
//
//   S        insolation, which the body works out for itself from wherever it
//            happens to be and whatever stars happen to be lighting it. Move a
//            planet and its ice line moves; there is nothing written down.
//   eps      the greenhouse, i.e. how far the surface runs above equilibrium.
//   T_frost  the condensation temperature of its dominant volatile. 273 K is a
//            water world; 148 K is Mars, which grows and loses CO2 caps every
//            winter; 63 K is Pluto, frosted with nitrogen. ONE uniform is the
//            difference between a polar cap of water ice and one of dry ice.
//   crater   whether anything erases impacts. With an atmosphere and plate
//            tectonics, nothing survives; with neither, the surface is a
//            four-billion-year integral of everything that ever hit it.
//
// The procedural terrain and climate belts come from sim/terrain.js. The map
// path replaces only surface geography and base color, not the atmosphere or
// the response to extreme heating and cooling.
// ============================================================================

// ---------------------------------------------------------------------------
// The vertex shader every one of these materials uses. It never forms an
// absolute world position: projection * view * model * p materialises a world
// coordinate in float32, which 35 scene units out quantises to 4e-6 and turns
// a true-scale body into a lump of cubes. modelViewMatrix is assembled on the
// CPU in float64 and carries the CAMERA-relative offset instead, and the
// world-space view vector is recovered by rotating that offset back with the
// transpose of the (orthonormal) view basis.
// ---------------------------------------------------------------------------
const SURF_VERT = `
  varying vec3 vObj; varying vec3 vWN; varying vec3 vView; varying vec2 vMapUv;
  void main(){
    vObj = normalize(position);
    vMapUv = uv;
    vWN  = normalize(mat3(modelMatrix) * normal);
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    mat3 vr = mat3(viewMatrix);
    vView = -vec3(dot(vr[0], mv.xyz), dot(vr[1], mv.xyz), dot(vr[2], mv.xyz));
    gl_Position = projectionMatrix * mv;
  }`;

export function surfaceMaterial(seed, opts = {}) {
  return new THREE.ShaderMaterial({
    uniforms: {
      ...SUN_UNIFORMS(),
      ...terrainUniforms(opts),
      uSeed:     { value: seed },
      // Height of the sea-level datum, in km. Raising it floods the world;
      // -60 is "there is no liquid at all", which is how an airless or a
      // boiled-dry body is expressed rather than by a second code path.
      uSeaKm:    { value: opts.seaKm ?? 0 },
      uIce:      { value: 0 },        // glaciated fraction FORCED by an EBM, if any
      uScorch:   { value: 0 },
      // Annual-mean insolation's second Legendre coefficient. See createRocky.
      uS2:       { value: -0.477 },
      uFrostK:   { value: opts.frostK ?? 273 },
      uBiota:    { value: opts.biota ?? 0 },
      uCrater:   { value: opts.crater ?? 0 },
      uRegolith: { value: new THREE.Color(opts.regolith ?? 0x8b8178) },
      uHaze:     { value: opts.haze ?? 0 },
      uAmbient:  { value: new THREE.Color(opts.ambient ?? 0x070b14) },
      uTime:     { value: 0 },
      // Exposure. A planet's albedo is a REFLECTANCE — 0.3 for land, 0.06 for
      // deep water — so lighting it at one solar constant and tone mapping
      // gives a disc near black, which is not what a photograph of a planet
      // looks like, because a camera exposes for the planet. This is that
      // exposure, and it is a constant rather than a per-body knob so two
      // worlds side by side are still comparable.
      uGain:     { value: 1.95 },
      // Seasons, in kelvin of swing between the poles. The annual MEAN
      // insolation profile cannot grow a winter cap: Mars's cap is CO2
      // freezing out at 148 K, and its annual mean polar temperature is
      // nowhere near that — it is the WINTER that gets there, and the cap
      // sublimes again by summer. uDecl is the sine of the sub-solar
      // latitude, which the sim already knows from the star direction and the
      // spin axis; uSeason is how far the surface follows it, which is small
      // under an ocean (Earth's thermal flywheel) and large on bare rock under
      // a thin atmosphere.
      uSeason:   { value: opts.season ?? 8 },
      uDecl:     { value: 0 },
      uMapKind:  { value: 0 }, // 0 procedural, 1 Earth land/water, 2 dry mission mosaic
      uMapScale: { value: 1 },
      uColorMap: { value: null },
      uLandMask: { value: null },
    },
    vertexShader: SURF_VERT,
    fragmentShader: `
      precision highp float;
      ${SUN_GLSL}
      uniform float uSeed, uSeaKm, uIce, uScorch, uS2, uFrostK, uBiota, uCrater, uHaze, uTime, uGain;
      uniform float uSeason, uDecl, uMapKind, uMapScale;
      uniform vec3 uRegolith, uAmbient;
      uniform sampler2D uColorMap, uLandMask;
      varying vec3 vObj; varying vec3 vWN; varying vec3 vView; varying vec2 vMapUv;
      ${TERRAIN_GLSL}

      void main(){
        vec3 p = normalize(vObj);

        // --- relief
        float hKm, rug;
        hKm = 0.0; rug = 0.0;
        if(uMapKind < 0.5) terrain(p, uSeed, hKm, rug);
        float fresh = 0.0;
        if(uMapKind < 0.5 && uCrater > 0.002){
          // A body with no air and no plate tectonics has no orogeny either:
          // its relief IS its impact record, so the tectonic terrain is faded
          // out as the crater record is faded in.
          float ch = craters(p, uSeed, uCrater, fresh);
          hKm = mix(hKm, hKm * 0.30 + ch, clamp(uCrater, 0.0, 1.0));
          rug = mix(rug, clamp(abs(ch) * 0.8, 0.0, 1.0), clamp(uCrater, 0.0, 1.0));
        }
        // uSeaKm is a LEVEL, not an offset applied to the ground. Subtracting
        // it from the terrain was the same arithmetic and a different physical
        // claim: a dry world expresses itself by putting sea level 60 km down,
        // and the lapse rate then read that as 60 km of altitude and took
        // 390 K off the surface — which froze Mars solid under CO2 at an
        // equilibrium temperature of 213 K. Altitude is measured from the
        // geoid; where the sea is, is a separate question.
        float sinLat = clamp(p.y, -1.0, 1.0);
        float lat = asin(sinLat);
        float a = abs(lat);
        bool sea = hKm < uSeaKm;
        if(uMapKind > 0.5 && uMapKind < 1.5)
          sea = texture2D(uLandMask, vMapUv).r < 0.5 && uSeaKm > -2.0;

        // --- temperature, and therefore everything else
        float T = surfaceTemp(sinLat, max(hKm, 0.0), uS2) + uSeason * sinLat * uDecl;

        // --- how wet. Continental interiors are dry because the water fell on
        // the way in; lee slopes are dry because it fell on the way over. The
        // upwind probe is the coarse crust only — what casts a rain shadow is
        // the massif, not the scree on it — and the wind reverses at the
        // trade/westerly boundary near 30 degrees, which is why the wet side
        // of a continent swaps hemisphere by hemisphere.
        //
        // BOTH SIDES OF THE DIFFERENCE ARE THE SAME FIELD. Subtracting the full
        // hKm from the coarse probe does not measure a slope at all: the fine
        // octaves (+-0.9 km) and the tectonic belt (up to 7 km) exist on only
        // one side of it, so the result is the local detail with its sign
        // flipped — speckle on flat ground, and a mountain belt that reads as
        // the WETTEST place on the planet rather than the driest lee.
        float P = 0.0;
        if(uMapKind < 0.5){
          float inland = smoothstep(uSeaKm + 0.05, uSeaKm + 1.4, hKm);
          vec3 east = normalize(cross(vec3(0.0, 1.0, 0.0), p) + 1e-6);
          vec3 probe = normalize(p + east * (a < 0.52 ? -0.04 : 0.04));
          float shadow = clamp((crustHeight(probe, uSeed) - crustHeight(p, uSeed)) * 0.6, 0.0, 1.0);
          P = precipitation(lat, T, inland, shadow);
        }

        // --- albedo
        vec3 albedo; float rough;
        if(sea){
          float depth = clamp((uSeaKm - hKm) / max(uOceanDepth, 0.5), 0.0, 1.0);
          // The continental shelf is only ~130 m deep and is the brightest
          // water on the planet — it is why coastlines are turquoise from
          // orbit and why the shape of a continent reads larger than its land.
          vec3 shelf = vec3(0.06, 0.26, 0.31);
          vec3 abyss = vec3(0.014, 0.050, 0.135);
          albedo = mix(shelf, abyss, smoothstep(0.02, 0.30, depth));
          rough = 0.06;
        } else {
          // Bare ground: the body's own regolith, mottled.
          vec3 rock = uRegolith * (0.72 + 0.55 * fbm(p * 9.0 + vec3(uSeed), 4));
          // Mare basalt: a flooded impact basin is darker and flatter than the
          // highlands around it, which is the Moon's entire two-tone face.
          float mare = uCrater * smoothstep(0.56, 0.74, fbm(p * 1.7 + vec3(uSeed + 13.0), 4));
          rock = mix(rock, rock * 0.42, mare);
          // and the bright ray systems of the craters young enough to still
          // have them
          rock = mix(rock, rock * 1.7, uCrater * fresh * 0.45);
          albedo = mix(rock, biome(T, P, rug), uBiota);
          rough = mix(0.95, 0.6, rug);
        }
        if(uMapKind > 0.5){
          vec3 mapped = texture2D(uColorMap, vMapUv).rgb;
          if(uMapKind < 1.5){
            // NASA's deep ocean is intentionally almost black in the source
            // composite. Restore the measured blue-water reflectance while
            // retaining its shallow-water color and mapped coastline.
            float land = texture2D(uLandMask, vMapUv).r;
            vec3 deep = vec3(0.018, 0.060, 0.155);
            float shelf = smoothstep(0.025, 0.13, mapped.g);
            vec3 water = mix(deep, max(mapped * 0.8, deep), shelf);
            float wet = smoothstep(-5.0, -2.0, uSeaKm);
            vec3 dryBed = vec3(0.15, 0.14, 0.12) * (0.8 + mapped.g * 1.4);
            albedo = mix(mix(dryBed, mapped, land), mix(water, mapped, land), wet);
            rough = mix(0.9, mix(0.06, 0.88, land), wet);
          } else {
            albedo = mapped * uMapScale;
            rough = 0.92;
          }
        }

        // --- volatiles. Everything freezes out below its own condensation
        // point: water at 273, CO2 at 148, nitrogen at 63. A permanent cap
        // needs no precipitation (an ice sheet is the accumulation of ages);
        // a seasonal snowpack does.
        float frost = 0.0;
        if(uMapKind < 0.5){
          float perm = smoothstep(uFrostK - 5.0, uFrostK - 17.0, T);
          float snow = smoothstep(uFrostK + 4.0, uFrostK - 5.0, T) * smoothstep(0.03, 0.28, P);
          float seaIce = sea ? smoothstep(uFrostK + 0.5, uFrostK - 4.0, T) : 0.0;
          frost = clamp(max(max(perm, snow), seaIce), 0.0, 1.0);
        } else if(uMapKind < 1.5){
          // The July image already has Greenland and Antarctica. Additional
          // glaciation appears only if the simulated Earth actually cools.
          float cold = 1.0 - smoothstep(245.0, 280.0, uMeanK);
          frost = cold * smoothstep(0.72 - 0.56 * cold, 0.92 - 0.35 * cold, abs(sinLat));
        }
        // An energy-balance model, where there is one, owns the ice line: its
        // glaciated fraction is a state variable with a feedback on it, and the
        // picture has to agree with the number the model is integrating.
        if(uIce > (uMapKind > 0.5 ? 0.15 : 0.001)){
          float capEdge = 1.0 - uIce * 1.05;
          float jitter = (fbm(p * 3.0 + 11.0, 3) - 0.5) * 0.16;
          frost = max(frost, smoothstep(capEdge - 0.10, capEdge + 0.06, abs(sinLat) + jitter)
                             * smoothstep(0.02, 0.18, uIce));
        }
        // ragged edge — an ice margin is a coastline, not a parallel
        if(frost > 0.0)
          frost = clamp(frost + (fbm(p * 7.0 + 31.0, 4) - 0.5) * 0.35, 0.0, 1.0);
        albedo = mix(albedo, vec3(0.82, 0.87, 0.93), frost);
        rough = mix(rough, 0.62, frost);

        // --- a world baking dry
        albedo = mix(albedo, vec3(0.55, 0.42, 0.26), clamp(uScorch * 1.6, 0.0, 0.85));

        // --- lighting, from every star at once
        vec3 N = normalize(vWN);
        vec3 V = normalize(vView);
        vec3 lit = vec3(0.0);
        vec3 skylight = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          vec3 L = normalize(uSunDir[i]);
          float ndl = dot(N, L);
          // A star is a disc, not a point, so the terminator has a width.
          float diff = smoothstep(-0.08, 0.22, ndl);
          vec3 sc = uSunColor[i] * uSunInt[i];
          lit += albedo * sc * diff * uGain;
          // specular — sun glint off water and off ice, and off nothing else
          vec3 H = normalize(L + V);
          float spec = pow(max(dot(N, H), 0.0), mix(240.0, 20.0, rough)) * (1.0 - rough);
          lit += sc * spec * 0.30 * step(0.0, ndl);
          // The sea is not blue because water is blue. It is blue because it
          // is a mirror lying under a Rayleigh-scattering sky, and at grazing
          // incidence its Fresnel reflectance approaches 1 — which is why the
          // ocean brightens toward the limb and toward the terminator.
          float fres = pow(1.0 - max(dot(N, V), 0.0), 5.0);
          lit += sc * (1.0 - rough) * mix(0.02, 0.35, fres) * diff * uHaze;
          skylight += sc * diff;
        }
        lit += albedo * uAmbient;

        // --- aerial perspective. An atmosphere is between you and the ground,
        // and it scatters blue out of the line of sight, so the limb of a world
        // with air is hazier and bluer than its centre. Without this term a
        // planet with an atmosphere still reads as a bare rock with a ring
        // painted round it.
        float limb = pow(1.0 - abs(dot(N, V)), 2.2);
        lit = mix(lit, lit * 0.75 + skylight * vec3(0.20, 0.34, 0.62) * 0.45, uHaze * limb);

        // --- incandescent once it is truly scorching
        lit += vec3(1.0, 0.28, 0.06) * pow(uScorch, 2.0) * 0.9;

        // Publish the surface temperature, log-encoded, so the spectral imaging
        // pass can re-image the planet in its own thermal band rather than
        // guessing a temperature from the colour of its rocks. A 288 K world is
        // a 10 micron source, and that is exactly what the infrared band should
        // show it as.
        gl_FragColor = vec4(lit, clamp(log(max(T, 1.0)) / 25.33, 0.0, 0.98));
      }`,
  });
}

// ---------------------------------------------------------------------------
// CLOUDS. Not a noise field wrapped round a ball: the same three overturning
// cells that put the deserts at 30 degrees put the CLOUD there too, or rather
// take it away — a satellite image of Earth is a bright convective band at the
// equator, two clear subtropical belts, and two ragged storm-track spirals at
// mid latitude. The deck is also advected by the zonal wind, which reverses
// between the trades and the westerlies, so the bands visibly shear past each
// other instead of turning as one rigid shell.
// ---------------------------------------------------------------------------
export function cloudMaterial(seed) {
  return new THREE.ShaderMaterial({
    uniforms: {
      ...SUN_UNIFORMS(),
      uTime:  { value: 0 },
      uCover: { value: 0.45 },
      uStorm: { value: 0.25 },
      uSeed:  { value: seed },
      uTint:  { value: new THREE.Color(0xffffff) },
    },
    transparent: true, depthWrite: false,
    vertexShader: SURF_VERT,
    fragmentShader: `
      precision highp float;
      ${SUN_GLSL}
      uniform float uTime, uCover, uStorm, uSeed;
      uniform vec3 uTint;
      varying vec3 vObj; varying vec3 vWN; varying vec3 vView;
      ${NOISE_GLSL}

      void main(){
        vec3 p = normalize(vObj);
        float lat = asin(clamp(p.y, -1.0, 1.0));
        float a = abs(lat);

        // Zonal wind: easterly trades under ~30 degrees, westerlies above. The
        // deck is carried by it, so the cloud bands slide past each other
        // instead of turning as one rigid shell.
        // Gaussians squared directly: pow() is undefined for a negative base,
        // and the westerly term's base is negative equatorward of 53 degrees.
        float ut = a / 0.42, uw = (a - 0.92) / 0.38;
        float u = -0.55 * exp(-ut * ut) + 1.00 * exp(-uw * uw);

        // The offset between two latitudes grows without bound, and a frozen
        // noise field sheared for ever becomes a smear of streaks — which is
        // exactly what a fast-forwarded climate world looked like. Two copies
        // of the field, half a period out of step, cross-faded so that each
        // one's weight is zero at the moment its own clock wraps: the motion
        // is continuous, and the winding never exceeds half a period's worth.
        // Same device as the gas giants (sim/giant_visual.js), same reason.
        float per = 20.0;
        float ta = mod(uTime, per), tb = mod(uTime + per * 0.5, per);
        float wx = 1.0 - abs(2.0 * ta / per - 1.0);
        float ca = cos(ta * u * 0.05), sa = sin(ta * u * 0.05);
        float cb = cos(tb * u * 0.05), sb = sin(tb * u * 0.05);
        vec3 qa = vec3(ca * p.x - sa * p.z, p.y, sa * p.x + ca * p.z);
        vec3 qb = vec3(cb * p.x - sb * p.z, p.y, sb * p.x + cb * p.z);

        float d = mix(fbm(qb * 5.5 + vec3(uSeed) + vec3(0.0, tb * 0.012, 0.0), 7),
                      fbm(qa * 5.5 + vec3(uSeed) + vec3(0.0, ta * 0.012, 0.0), 7), wx);
        // cyclones: ridged noise is all creases, which is what a frontal band is
        float st = mix(ridged(qb * 7.0 - tb * 0.03, 5), ridged(qa * 7.0 - ta * 0.03, 5), wx) * uStorm;
        d += st * 0.30;

        // where the air is rising there is cloud, where it sinks there is none
        float bi = a / 0.25, bf = (a - 0.95) / 0.30, bh = (a - 0.52) / 0.22;
        float band = clamp(1.00 * exp(-bi * bi)
                         + 0.70 * exp(-bf * bf)
                         - 0.80 * exp(-bh * bh), 0.0, 1.25);
        float cover = clamp(uCover * mix(0.30, 1.25, band), 0.0, 1.0);
        float al = smoothstep(0.62 - cover * 0.44, 0.88 - cover * 0.32, d);
        if(al < 0.01) discard;

        vec3 N = normalize(vWN);
        vec3 lit = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          float diff = smoothstep(-0.12, 0.28, dot(N, normalize(uSunDir[i])));
          lit += uSunColor[i] * uSunInt[i] * diff;
        }
        lit += vec3(0.04, 0.06, 0.10);
        gl_FragColor = vec4(lit * uTint * mix(1.0, 0.78, uStorm), al * 0.93);
      }`,
  });
}

// ---------------------------------------------------------------------------
// ATMOSPHERE. Rayleigh scattering goes as lambda^-4, so the cross sections for
// R, G, B are in the ratio 5.8 : 13.5 : 33.1 per 10^-6 m^-1 — that ratio IS
// why the sky is blue and why the same sky is red along a long path at sunset,
// and it is the only colour information this shell needs.
// ---------------------------------------------------------------------------
export function atmosphereMaterial(tint) {
  return new THREE.ShaderMaterial({
    uniforms: {
      ...SUN_UNIFORMS(),
      uThick: { value: 1 },
      uTint:  { value: new THREE.Color(tint ?? 0xffffff) },
    },
    transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.BackSide,
    vertexShader: SURF_VERT,
    fragmentShader: `
      precision highp float;
      ${SUN_GLSL}
      uniform float uThick; uniform vec3 uTint;
      varying vec3 vObj; varying vec3 vWN; varying vec3 vView;
      void main(){
        vec3 N = normalize(vWN);
        vec3 V = normalize(vView);
        // Path length through a thin shell goes as 1/|N.V| at grazing angles;
        // that divergence is the bright ring on the limb, and it is capped
        // because the shell is not actually infinitely thin.
        float mu = abs(dot(N, V));
        float path = min(1.0 / max(mu, 0.06), 7.0) - 1.0;
        vec3 beta = normalize(vec3(5.8, 13.5, 33.1));
        vec3 col = vec3(0.0);
        for(int i=0;i<${MAX_SUNS};i++){
          if(i >= uSunCount) break;
          vec3 L = normalize(uSunDir[i]);
          float lam = smoothstep(-0.35, 0.5, dot(N, L));
          // Along a long path the blue has already been scattered OUT, so what
          // is left arriving is red. That is the sunset, and it belongs on the
          // limb nearest the star.
          float fwd = pow(max(dot(V, -L), 0.0), 4.0);
          vec3 tone = mix(beta, vec3(1.0, 0.40, 0.16), fwd * 0.85);
          col += tone * uSunColor[i] * uSunInt[i] * lam;
        }
        gl_FragColor = vec4(col * uTint * path * 0.085 * uThick, 1.0);
      }`,
  });
}

// ---------------------------------------------------------------------------
// Annual-mean insolation's second Legendre coefficient, from the obliquity.
//
//   S(phi)/Sbar = 1 + s2 * P2(sin phi),   s2 = -(5/8)(1 - (3/2) sin^2 eps)
//
// At Earth's 23.44 degrees this gives -0.477, which is the number every 1-D
// energy-balance model since Budyko uses. It is worth carrying the whole
// function rather than the constant, because it CHANGES SIGN at eps = 54.7
// degrees: past that tilt the poles receive more annual sunlight than the
// equator, the temperature gradient inverts, and the ice caps form around the
// EQUATOR. Uranus is over on its side like that, and so is anything the
// Foundry is asked to tip past 55 degrees.
// ---------------------------------------------------------------------------
export function insolationS2(obliquity) {
  const s = Math.sin(obliquity);
  return -0.625 * (1 - 1.5 * s * s);
}

// Surface temperature of a body in radiative balance with its stars, warmed by
// whatever greenhouse it has. eps is the effective emissivity: 0.61 puts Earth
// at 288 K for S = 1 and an albedo of 0.3, and 1.0 is an airless rock.
export function surfaceTempK(S, albedo, eps) {
  const Teq = 278.6 * Math.pow(Math.max(S, 1e-9) * (1 - albedo), 0.25);
  return Teq / Math.pow(Math.max(eps, 1e-3), 0.25);
}

// ---------------------------------------------------------------------------
export function createRockyVisual(b, opts = {}) {
  const g = new THREE.Group();
  const R = opts.radiusScene;
  const seed = (((b.id * 2654435761) >>> 0) % 1000) / 7.3 + (opts.seed || 0) * 0.017;

  // A world with no liquid at all is expressed by putting the sea-level datum
  // below the deepest point there is, not by a second branch in the shader.
  const dry = opts.hot || opts.airless || (opts.water ?? 1) <= 0;
  const surfOpts = {
    ...opts,
    continent: opts.land ?? (opts.seaLevel != null ? 1 - opts.seaLevel * 0.72 : 0.34),
    seaKm: dry ? -60 : (opts.seaKm ?? 0),
    crater: opts.crater ?? (opts.atmosphere ? 0 : 0.85),
    biota: opts.biota ?? 0,
    haze: opts.haze ?? (opts.atmosphere ? 0.45 : 0),
    regolith: opts.regolith ?? (opts.hot ? 0xb08058 : 0x8d8478),
    frostK: opts.frostK ?? 273,
  };

  const surfMat = surfaceMaterial(seed, surfOpts);
  loadPlanetMap(b.name, ({ color, mask, kind, scale }) => {
    surfMat.uniforms.uColorMap.value = color;
    surfMat.uniforms.uLandMask.value = mask;
    surfMat.uniforms.uMapScale.value = scale;
    surfMat.uniforms.uMapKind.value = kind;
  });
  const surface = new THREE.Mesh(new THREE.SphereGeometry(R, 96, 64), surfMat);
  g.add(surface);

  let clouds = null, cloudMat = null, atmo = null, atmoMat = null;
  if (opts.atmosphere) {
    cloudMat = cloudMaterial(seed + 3.7);
    if (opts.cloudColor) cloudMat.uniforms.uTint.value.set(opts.cloudColor);
    cloudMat.uniforms.uCover.value = opts.cloudCover ?? 0.45;
    clouds = new THREE.Mesh(new THREE.SphereGeometry(R * 1.008, 64, 48), cloudMat);
    g.add(clouds);

    atmoMat = atmosphereMaterial(opts.atmColor);
    atmoMat.uniforms.uThick.value = opts.atmThick ?? 1;
    atmo = new THREE.Mesh(new THREE.SphereGeometry(R * 1.035, 72, 48), atmoMat);
    g.add(atmo);
  }

  // Obliquity is what gives a world seasons on top of whatever its orbit is
  // already doing, and it also sets the insolation profile below.
  const obliquity = opts.obliquity ?? 0.35;
  g.rotation.z = obliquity;
  surfMat.uniforms.uS2.value = insolationS2(obliquity);

  const albedo = opts.albedo ?? 0.3;
  const eps = opts.greenhouse ?? (opts.atmosphere ? 0.61 : 1.0);
  // The sea-level datum this body was BUILT with. A world that bakes past the
  // boiling point loses its ocean, and the way that is expressed here is the
  // datum dropping (see the note on uSeaKm above) — so the undried value has
  // to be kept, or there is nothing to come back to when it cools.
  const seaKm0 = surfMat.uniforms.uSeaKm.value;
  const _pole = new THREE.Vector3(), _sun = new THREE.Vector3();

  b.viz = {
    group: g, core: surface, surface, clouds, atmo, surfMat, cloudMat, atmoMat,
    baseR: R, R, isRocky: true,
  };
  b.spin = b.spin ?? (0.4 + Math.random() * 1.2) * (Math.random() < 0.1 ? -1 : 1);
  b.spinPhase = b.spinPhase ?? 0;
  b.cloudPhase = b.cloudPhase ?? 0;
  const TAU = Math.PI * 2;

  b.viz.update = (dt, ctx) => {
    // Both phases wrap: rotation.y reaches the GPU as a float32 matrix entry,
    // and once its magnitude passes ~1e5 the per-frame increment is under one
    // ulp and the spin quantises and then stops. A rotation is exactly
    // 2*pi-periodic, so wrapping costs nothing.
    const parent = opts.tidalLock && ctx.bodies?.find(x => x.name === opts.tidalLock);
    if (parent) {
      // A synchronously rotating moon keeps its local +X meridian toward its
      // parent. Transform into the tilted body frame before reading longitude.
      const toward = parent.pos.clone().sub(b.pos).applyQuaternion(g.quaternion.clone().invert());
      b.spinPhase = Math.atan2(-toward.z, toward.x);
    } else b.spinPhase = (b.spinPhase + b.spin * dt) % TAU;
    surface.rotation.y = b.spinPhase;
    if (clouds) {
      // The deck super-rotates slightly; it also needs its own accumulator
      // rather than a scaled read of spinPhase, which would jump at each wrap.
      b.cloudPhase = (b.cloudPhase + b.spin * dt * 0.985) % TAU;
      clouds.rotation.y = b.cloudPhase;
      cloudMat.uniforms.uTime.value += dt;
    }
    surfMat.uniforms.uTime.value += dt;

    // The body works out its own temperature from where it currently is. This
    // is what makes the appearance a consequence rather than a setting: edit a
    // planet's orbit in flight and its ice line moves.
    const suns = litBy(ctx);
    if (suns) {
      // Insolation from the real stars where there are any; where there are
      // none, the stand-in disc light's own intensity, so the body's
      // temperature and its lighting rest on the same assumption instead of
      // disagreeing (a lit planet at 0 K would frost over solid).
      const S = (ctx.suns && ctx.suns.length) ? insolationAt(b, ctx.suns) : suns[0].intensity;
      const T = opts.surfaceK ?? (S > 1e-8 ? surfaceTempK(S, albedo, eps) : (opts.meanK ?? 60));
      surfMat.uniforms.uMeanK.value += (T - surfMat.uniforms.uMeanK.value) * Math.min(1, dt * 2);

      // THE HOT END IS A CONSEQUENCE TOO. The cold end always was — everything
      // freezes out below its own condensation point, and the caps follow the
      // temperature this closure already derives. The hot end was not: the
      // uniforms that dry a world out (uSeaKm, uScorch, uArid) were driven only
      // by the energy-balance model in sim/world.js, which exists for the one
      // home world a scenario may have. So an ordinary planet at 388 K — inside
      // the inner edge of its star's habitable zone, past the runaway
      // greenhouse — was drawn with oceans and fair-weather cloud, which is the
      // one thing the habitable-zone lesson must not show.
      //
      // ONLY FOR A BODY THAT HAS WATER TO LOSE. An airless cratered rock at
      // 440 K (Mercury) is not "scorched", it is just warm: there is no ocean
      // to boil and no vegetation to bake, and tinting it ochre and giving it
      // a red glow would be inventing a phenomenon. The gate is the atmosphere,
      // which is also what `dry` above keys off. A STATED surface temperature
      // counts: Venus's 737 K is stated because no greenhouse parameter reaches
      // it, and a world at 737 K under 92 bar of CO2 is the archetype of this
      // branch rather than an exception to it.
      if (opts.atmosphere) {
        const clamp01 = x => Math.min(Math.max(x, 0), 1);
        // Near-Earth-pressure teaching model: dry out by water’s boiling point.
        const boil = clamp01((T - 350) / 23.15);
        surfMat.uniforms.uSeaKm.value = seaKm0 + (-60.0 - seaKm0) * boil;
        surfMat.uniforms.uScorch.value = clamp01((T - 330) / 140);
        surfMat.uniforms.uArid.value = Math.min(clamp01((T - 310) / 80), 0.8);
        if (cloudMat) {
          // Cloud does not simply vanish — a runaway greenhouse ends up under
          // MORE of it, not less (Venus is the reference case and is completely
          // covered). What goes is the fair-weather structure in between.
          const base = opts.cloudCover ?? 0.45;
          cloudMat.uniforms.uCover.value = base + (1.0 - base) * clamp01((T - 340) / 110);
        }
      }
      // The season is just where the star is, relative to the spin axis: the
      // sine of the sub-solar latitude. It falls out of the geometry the orrery
      // is already integrating, so a world on an eccentric or a chaotic orbit
      // gets the seasons that orbit actually gives it.
      _pole.set(0, 1, 0).applyQuaternion(g.quaternion);
      _sun.copy(suns[0].posScene).sub(g.position).normalize();
      surfMat.uniforms.uDecl.value = _pole.dot(_sun);
      applySuns([surfMat, cloudMat, atmoMat].filter(Boolean), suns, g.position);
    }
  };

  return b.viz;
}
