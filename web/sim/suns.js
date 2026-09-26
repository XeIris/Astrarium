import * as THREE from 'three';

// ============================================================================
// MULTI-SUN LIGHTING — the uniform block every surface in the orrery is lit by.
// ----------------------------------------------------------------------------
// A body here is never lit by "the" sun: a Trisolaran world has three
// terminators crossing its disc at once, in three different colours, and a
// circumbinary planet has two. So lighting is an ARRAY, and every material
// that faces a star declares the same block and is fed by the same applySuns().
//
// It lives in its own module because both the solid-surface shaders
// (sim/rocky_visual.js, sim/world.js) and the gas giant (sim/giant_visual.js)
// need it, and none of them should have to import each other to get it.
// ============================================================================

export const MAX_SUNS = 4;

export const SUN_UNIFORMS = () => ({
  uSunDir:   { value: Array.from({ length: MAX_SUNS }, () => new THREE.Vector3(1, 0, 0)) },
  uSunColor: { value: Array.from({ length: MAX_SUNS }, () => new THREE.Color(1, 1, 1)) },
  uSunInt:   { value: new Float32Array(MAX_SUNS) },
  uSunCount: { value: 0 },
});

// The GLSL declaration that matches SUN_UNIFORMS, so the two cannot drift apart.
export const SUN_GLSL = `
  uniform vec3 uSunDir[${MAX_SUNS}]; uniform vec3 uSunColor[${MAX_SUNS}];
  uniform float uSunInt[${MAX_SUNS}]; uniform int uSunCount;`;

// Point every sun-aware material at the current star set. `suns` entries carry
// { posScene, color, intensity }.
export function applySuns(materials, suns, targetScene) {
  const n = Math.min(suns.length, MAX_SUNS);
  for (const m of materials) {
    const u = m.uniforms;
    if (!u || !u.uSunDir) continue;
    for (let i = 0; i < n; i++) {
      u.uSunDir.value[i].copy(suns[i].posScene).sub(targetScene).normalize();
      u.uSunColor.value[i].copy(suns[i].color);
      u.uSunInt.value[i] = suns[i].intensity;
    }
    u.uSunCount.value = n;
  }
}

// Total insolation at a body, in solar constants (S_Earth = 1), summed over
// every star: S = sum L_i / d_i^2 with L in solar luminosities and d in AU.
// This is the same quantity sim/climate.js integrates, computed for a body
// that has no climate model of its own — which is what lets an ordinary planet
// know its own temperature, and therefore where its ice line and its deserts
// are, without anything being written down per preset.
export function insolationAt(body, suns) {
  if (!suns || !suns.length) return 0;
  let S = 0;
  for (const s of suns) {
    const star = s.body;
    if (!star || star === body) continue;
    const L = star.luminosity ?? 1;
    const d = Math.max(star.pos.distanceTo(body.pos), 1e-4);
    S += L / (d * d);
  }
  return S;
}

// The light in a scene that has no stars in it. A black hole's accretion disc
// is the brightest thing in the universe per unit mass, so a planet beside one
// is lit — but by WHAT is not something this model knows: sim/blackhole.js
// draws a Shakura-Sunyaev disc without ever exporting a luminosity from it. So
// this is a deliberately modest stand-in with a disc's colour temperature
// rather than a derived flux, and its only job is to stop a body next to a
// black hole rendering as a flat silhouette. If a disc luminosity is ever
// derived, this is the one place that should read it.
const _discColor = new THREE.Color(0xffd2a0);
export function litBy(ctx) {
  if (ctx.suns && ctx.suns.length) return ctx.suns;
  if (!ctx.holes || !ctx.holes.length) return null;
  let near = ctx.holes[0];
  return [{ posScene: near.posScene, color: _discColor, intensity: 1.2 }];
}
