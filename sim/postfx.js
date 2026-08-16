import * as THREE from 'three';
import { REMAP_FRAG, BANDS, VISIBLE_BAND, bandUniformData } from './spectrum.js';

// ============================================================================
// POST-PROCESSING — HDR bloom + filmic tone mapping.
// ----------------------------------------------------------------------------
// This is the single biggest reason the sim used to read as "cartoony": every
// emitter was clamped to 1.0 at the framebuffer, so a star, a flare and the
// inner edge of an accretion disc all resolved to exactly the same flat white.
// Real cameras and real eyes do neither of those things — they bloom, and they
// roll highlights off along a filmic curve instead of clipping.
//
// The chain:
//   scene  →  HDR target (half-float, values well above 1)
//          →  bright-pass, then a 5-level progressive down/upsample bloom
//             (the "dual filter" used by Unreal/CoD — cheap, and it produces a
//             wide, smooth halo instead of a visible gaussian donut)
//          →  composite: ACES RRT+ODT fit, vignette, grain, ordered dither
//
// Because the tone curve compresses rather than clips, an object can now be
// 40× over white and still show its own colour at the edges — which is exactly
// how the Doppler-boosted side of a disc, or the core of an O star, behaves.
// ============================================================================

const QUAD = new THREE.PlaneGeometry(2, 2);
const VERT = `
  varying vec2 vUv;
  void main(){ vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }`;

function makePass(fragmentShader, uniforms) {
  const material = new THREE.ShaderMaterial({
    uniforms, vertexShader: VERT, fragmentShader,
    depthTest: false, depthWrite: false,
  });
  const scene = new THREE.Scene();
  scene.add(new THREE.Mesh(QUAD, material));
  return { scene, material, uniforms };
}

function target(w, h) {
  return new THREE.WebGLRenderTarget(Math.max(1, w), Math.max(1, h), {
    type: THREE.HalfFloatType,
    minFilter: THREE.LinearFilter,
    magFilter: THREE.LinearFilter,
    wrapS: THREE.ClampToEdgeWrapping,
    wrapT: THREE.ClampToEdgeWrapping,
    depthBuffer: false,
    generateMipmaps: false,
  });
}

// Karis average — weight by 1/(1+luma) before averaging so a single blazing
// pixel (a star, a flare kernel) doesn't detonate into a flickering firefly
// when it gets downsampled.
const BRIGHT_FRAG = `
  precision highp float;
  varying vec2 vUv;
  uniform sampler2D tSrc;
  uniform vec2 texel;
  uniform float threshold, knee;
  float luma(vec3 c){ return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
  vec3 tap(vec2 o){
    vec3 c = texture2D(tSrc, vUv + o * texel).rgb;
    return c / (1.0 + luma(c));
  }
  void main(){
    // 4-tap box in the source, Karis-weighted
    vec3 s = tap(vec2(-1.0,-1.0)) + tap(vec2(1.0,-1.0))
           + tap(vec2(-1.0, 1.0)) + tap(vec2(1.0, 1.0));
    s *= 0.25;
    s = s / max(1.0 - luma(s), 1e-4);     // undo the Karis weighting

    // soft-knee threshold: a gentle shoulder instead of a hard cutoff, so
    // things don't pop in and out of the bloom as they brighten
    float l = luma(s);
    float soft = clamp(l - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float w = max(soft, l - threshold) / max(l, 1e-4);
    gl_FragColor = vec4(s * w, 1.0);
  }`;

const DOWN_FRAG = `
  precision highp float;
  varying vec2 vUv;
  uniform sampler2D tSrc;
  uniform vec2 texel;
  vec3 t(vec2 o){ return texture2D(tSrc, vUv + o * texel).rgb; }
  void main(){
    // 13-tap partial-tent kernel (Jimenez / CoD): far better mip stability
    // than a box filter, which is what stops the halo from crawling.
    vec3 a = t(vec2(-2.0, 2.0)), b = t(vec2(0.0, 2.0)), c = t(vec2(2.0, 2.0));
    vec3 d = t(vec2(-2.0, 0.0)), e = t(vec2(0.0, 0.0)), f = t(vec2(2.0, 0.0));
    vec3 g = t(vec2(-2.0,-2.0)), h = t(vec2(0.0,-2.0)), i = t(vec2(2.0,-2.0));
    vec3 j = t(vec2(-1.0, 1.0)), k = t(vec2(1.0, 1.0));
    vec3 l = t(vec2(-1.0,-1.0)), m = t(vec2(1.0,-1.0));
    vec3 o = e * 0.125;
    o += (a + c + g + i) * 0.03125;
    o += (b + d + f + h) * 0.0625;
    o += (j + k + l + m) * 0.125;
    gl_FragColor = vec4(o, 1.0);
  }`;

const UP_FRAG = `
  precision highp float;
  varying vec2 vUv;
  uniform sampler2D tSrc;
  uniform vec2 texel;
  uniform float radius;
  vec3 t(vec2 o){ return texture2D(tSrc, vUv + o * texel * radius).rgb; }
  void main(){
    // 9-tap tent, additively blended into the larger mip
    vec3 o = t(vec2( 0.0, 0.0)) * 4.0;
    o += (t(vec2(-1.0, 0.0)) + t(vec2(1.0, 0.0))
        + t(vec2( 0.0,-1.0)) + t(vec2(0.0, 1.0))) * 2.0;
    o +=  t(vec2(-1.0,-1.0)) + t(vec2(1.0,-1.0))
        + t(vec2(-1.0, 1.0)) + t(vec2(1.0, 1.0));
    gl_FragColor = vec4(o / 16.0, 1.0);
  }`;

const COMPOSITE_FRAG = `
  precision highp float;
  varying vec2 vUv;
  uniform sampler2D tScene, tBloom;
  uniform float bloomStrength, exposure, vignette, grain, time;
  uniform vec2 resolution;

  // ACES RRT+ODT, Stephen Hill's fit. Unlike the cheap Narkowicz curve this
  // keeps the characteristic hue shift as things saturate: a red-hot disc edge
  // slides orange → yellow → white on its way up, the way film and sensors do.
  const mat3 ACESIn = mat3(
    0.59719, 0.07600, 0.02840,
    0.35458, 0.90834, 0.13383,
    0.04823, 0.01566, 0.83777);
  const mat3 ACESOut = mat3(
     1.60475, -0.10208, -0.00327,
    -0.53108,  1.10813, -0.07276,
    -0.07367, -0.00605,  1.07602);
  vec3 rrt(vec3 v){
    vec3 a = v * (v + 0.0245786) - 0.000090537;
    vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    return a / b;
  }
  vec3 acesFitted(vec3 c){
    c = ACESIn * c;
    c = rrt(c);
    c = ACESOut * c;
    return clamp(c, 0.0, 1.0);
  }

  float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

  void main(){
    vec3 col = texture2D(tScene, vUv).rgb;
    col += texture2D(tBloom, vUv).rgb * bloomStrength;

    col *= exposure;
    col = acesFitted(col);

    // Optical vignette — a real lens falls off toward the corners, and the
    // darker frame edge makes the bright centre read as brighter still.
    float r = length(vUv - 0.5) * 1.414;
    col *= 1.0 - vignette * pow(clamp(r, 0.0, 1.0), 2.4);

    // Sensor grain, scaled down in the highlights the way shot noise really is.
    float n = hash(gl_FragCoord.xy + fract(time) * 137.0) - 0.5;
    col += n * grain * (1.0 - 0.7 * dot(col, vec3(0.333)));

    // linear → sRGB
    col = max(col, vec3(0.0));
    vec3 srgb = mix(col * 12.92,
                    1.055 * pow(col, vec3(1.0 / 2.4)) - 0.055,
                    step(0.0031308, col));

    // Ordered-ish dither. 8-bit output over a smooth ACES shoulder bands very
    // visibly against a black sky; a sub-LSB of noise removes it entirely.
    srgb += (hash(gl_FragCoord.xy * 1.7) - 0.5) / 255.0;
    gl_FragColor = vec4(srgb, 1.0);
  }`;

const MIPS = 5;

export function createPostFX(renderer) {
  const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

  // The frame is composed here, in linear HDR, before anything is tone mapped.
  const hdr = new THREE.WebGLRenderTarget(1, 1, {
    type: THREE.HalfFloatType,
    minFilter: THREE.LinearFilter,
    magFilter: THREE.LinearFilter,
    depthBuffer: true,
    generateMipmaps: false,
  });

  const mips = Array.from({ length: MIPS }, () => target(1, 1));

  // Spectral re-imaging target. The remap runs BEFORE the bloom, not after:
  // bloom is the instrument's point-spread function, so it has to spread the
  // band image. Blooming the visible frame and then recolouring it would put
  // haloes around sources that the band cannot even see.
  const banded = target(1, 1);
  const remap = makePass(REMAP_FRAG, {
    tSrc: { value: null },
    uTheta: { value: 0 }, uTref: { value: 5800 },
    uPalette: { value: 0 },
    uStretch: { value: 120 },
  });
  let bandIndex = VISIBLE_BAND;
  let sceneMaxT = 5800;         // hottest emitter in the scene, drives the gain

  const bright = makePass(BRIGHT_FRAG, {
    tSrc: { value: null }, texel: { value: new THREE.Vector2() },
    threshold: { value: 1.5 }, knee: { value: 0.7 },
  });
  const down = makePass(DOWN_FRAG, {
    tSrc: { value: null }, texel: { value: new THREE.Vector2() },
  });
  const up = makePass(UP_FRAG, {
    tSrc: { value: null }, texel: { value: new THREE.Vector2() },
    radius: { value: 0.85 },
  });
  const composite = makePass(COMPOSITE_FRAG, {
    tScene: { value: null }, tBloom: { value: null },
    bloomStrength: { value: 0.11 }, exposure: { value: 1.0 },
    vignette: { value: 0.30 }, grain: { value: 0.012 },
    time: { value: 0 }, resolution: { value: new THREE.Vector2() },
  });

  function applyBandGain() {
    const d = bandUniformData(bandIndex, sceneMaxT);
    remap.uniforms.uTheta.value = d.theta;
    remap.uniforms.uTref.value = d.tref;
  }

  // Additive blending is how the upsampled mips accumulate back up the chain.
  const upMesh = up.scene.children[0];
  upMesh.material.blending = THREE.AdditiveBlending;
  upMesh.material.transparent = true;

  const api = {
    hdr,
    params: {
      set bloom(v) { composite.uniforms.bloomStrength.value = v; },
      get bloom() { return composite.uniforms.bloomStrength.value; },
      set threshold(v) { bright.uniforms.threshold.value = v; },
      set radius(v) { up.uniforms.radius.value = v; },
      set vignette(v) { composite.uniforms.vignette.value = v; },
      set grain(v) { composite.uniforms.grain.value = v; },
    },

    get band() { return bandIndex; },

    /** Switch the imaging band. VISIBLE_BAND bypasses the remap entirely. */
    setBand(i) {
      bandIndex = Math.max(0, Math.min(BANDS.length - 1, i | 0));
      remap.uniforms.uPalette.value = bandIndex;
      applyBandGain();
      return BANDS[bandIndex];
    },

    /**
     * The temperature of the hottest emitter in the scene. The band gain is
     * anchored to it — an observer exposes for the brightest target in the
     * field, and without that a preset with only 5000 K stars would render as
     * a black frame in every band above the visible.
     */
    setSceneTemp(t) {
      if (!(t > 0) || Math.abs(t - sceneMaxT) < sceneMaxT * 0.01) return;
      sceneMaxT = t;
      applyBandGain();
    },

    setSize(w, h) {
      hdr.setSize(Math.max(1, w), Math.max(1, h));
      banded.setSize(Math.max(1, w), Math.max(1, h));
      composite.uniforms.resolution.value.set(w, h);
      let mw = w, mh = h;
      for (let i = 0; i < MIPS; i++) {
        mw = Math.max(1, Math.floor(mw / 2));
        mh = Math.max(1, Math.floor(mh / 2));
        mips[i].setSize(mw, mh);
      }
    },

    // hdr → screen
    render(exposure = 1, time = 0) {
      const prevAutoClear = renderer.autoClear;
      renderer.autoClear = true;

      // 0. spectral re-imaging, when we are not looking in visible light
      let src = hdr;
      if (bandIndex !== VISIBLE_BAND) {
        remap.uniforms.tSrc.value = hdr.texture;
        renderer.setRenderTarget(banded);
        renderer.render(remap.scene, camera);
        src = banded;
      }

      // 1. bright pass into mip 0
      bright.uniforms.tSrc.value = src.texture;
      bright.uniforms.texel.value.set(1 / src.width, 1 / src.height);
      renderer.setRenderTarget(mips[0]);
      renderer.render(bright.scene, camera);

      // 2. progressive downsample
      for (let i = 1; i < MIPS; i++) {
        down.uniforms.tSrc.value = mips[i - 1].texture;
        down.uniforms.texel.value.set(1 / mips[i - 1].width, 1 / mips[i - 1].height);
        renderer.setRenderTarget(mips[i]);
        renderer.render(down.scene, camera);
      }

      // 3. upsample + accumulate back down the chain (additive)
      renderer.autoClear = false;
      for (let i = MIPS - 1; i > 0; i--) {
        up.uniforms.tSrc.value = mips[i].texture;
        up.uniforms.texel.value.set(1 / mips[i].width, 1 / mips[i].height);
        renderer.setRenderTarget(mips[i - 1]);
        renderer.render(up.scene, camera);
      }
      renderer.autoClear = true;

      // 4. composite to the screen
      composite.uniforms.tScene.value = src.texture;
      composite.uniforms.tBloom.value = mips[0].texture;
      composite.uniforms.exposure.value = exposure;
      composite.uniforms.time.value = time;
      renderer.setRenderTarget(null);
      renderer.render(composite.scene, camera);

      renderer.autoClear = prevAutoClear;
    },

    dispose() {
      hdr.dispose();
      banded.dispose();
      for (const m of mips) m.dispose();
    },
  };

  return api;
}
