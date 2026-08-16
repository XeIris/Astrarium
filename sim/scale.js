import * as THREE from 'three';
import { AU_PER_KM } from './physics.js';

// ============================================================================
// TRUE-SCALE RENDERING
//
// Every other preset renders bodies at an invented size, because the Solar
// System spans seven orders of magnitude between "how far apart things are"
// and "how big things are". Earth's radius is 4.26e-5 AU sitting in a 1 AU
// orbit: a ratio of 1 : 23 000. Drawn honestly at a camera distance that fits
// Neptune's orbit on screen, Earth covers 0.001 of a pixel.
//
// The exaggeration is therefore not laziness, it is the only way a mesh
// renderer shows anything at all. But it is not the ONLY way to be visible,
// and that is the loophole this module uses.
//
// A real telescope has the same problem and solves it the same way: below the
// resolution limit a body stops being a disc and becomes a POINT SOURCE. Its
// apparent size stops shrinking (it is pinned at the instrument's point-spread
// function) while its brightness keeps falling as 1/r². So we render bodies at
// their true geometric size and, when that drops below a few pixels, cross-fade
// the mesh into a fixed-pixel-size glow. Geometry stays honest; visibility is
// preserved. This is what Celestia and Space Engine do.
//
// The two numerical hazards of true scale, and why they do not bite here:
//
//   Depth precision. A 24-bit depth buffer with near=n resolves roughly
//   z²/(n·2²⁴) at distance z. A body of radius R goes sub-pixel (and hence
//   becomes a marker, with no depth-sensitive geometry left) once
//   z > 2R/θ_px ≈ 2317·R. Its geometry stays well resolved while
//   z < sqrt(1.7e4·R). For Earth those are 0.099 AU and 0.84 AU — the mesh has
//   already handed over to the marker an order of magnitude before depth
//   precision could degrade below the body's own size. The crossover saves us.
//
//   float32 vertex precision. Relative epsilon ~1e-7 of the position
//   magnitude, so a body 40 AU from the origin jitters by ~4e-6 AU. That is
//   invisible until you zoom in far enough for 4e-6 AU to exceed a pixel, which
//   only happens in extreme close-ups of the outer system. Callers that care
//   can subtract a render origin; nothing here assumes one.
// ============================================================================

// ----------------------------------------------------------------------------
// Physical radius (AU) for a non-degenerate body.
//
// A measured radius always wins. Failing that we need a mass–radius relation,
// and there are two distinct regimes because the supporting pressure changes:
//
//   Rocky worlds are held up by electrostatic (Coulomb) forces in a nearly
//   incompressible lattice, so adding mass mostly adds volume, damped by
//   self-compression: R/R⊕ ≈ (M/M⊕)^0.27 across 0.1–10 M⊕.
//
//   Gas giants are held up by partially degenerate electrons, and degeneracy
//   pressure stiffens faster than gravity loads it. The radius is therefore
//   almost flat — every object from 0.3 to 10 M_J sits within ~20% of one
//   Jupiter radius, and Jupiter itself is near the maximum. A constant beats
//   any power law here.
// ----------------------------------------------------------------------------
const R_EARTH_KM = 6371.0;
const R_JUP_KM   = 69911.0;
const M_EARTH_SUN = 3.00348e-6;      // Earth mass in M☉

export function physicalRadiusAU(type, massSun, radiusKm) {
  if (radiusKm > 0) return radiusKm * AU_PER_KM;
  if (type === 'gas-giant') return R_JUP_KM * AU_PER_KM;
  // rocky: 'planet' and 'world'
  const mEarth = Math.max(massSun / M_EARTH_SUN, 1e-4);
  return R_EARTH_KM * Math.pow(mEarth, 0.27) * AU_PER_KM;
}

// ----------------------------------------------------------------------------
// Apparent angular DIAMETER of a body, in screen pixels.
//
// A perspective camera with vertical field of view f maps a viewport of H
// pixels onto 2·z·tan(f/2) world units at distance z, so one pixel spans
// (2·z·tan(f/2))/H there. Dividing the body's diameter by that gives its size
// in pixels — the quantity that decides whether a mesh is worth drawing.
// ----------------------------------------------------------------------------
export function pixelsPerWorldUnit(dist, fovRad, viewportH) {
  return viewportH / Math.max(2 * dist * Math.tan(fovRad / 2), 1e-30);
}

export function apparentPixels(radiusScene, dist, fovRad, viewportH) {
  return 2 * radiusScene * pixelsPerWorldUnit(dist, fovRad, viewportH);
}

// Crossover band. Above FADE_OUT_PX the mesh carries the body on its own and
// the marker is off; below FADE_IN_PX the mesh is sub-pixel mush and the marker
// carries it entirely. Between them both draw, additively, and the handover is
// invisible because the marker's core is about as wide as the disc it replaces.
const FADE_IN_PX  = 2.5;
const FADE_OUT_PX = 7.0;
// Drawn size of the marker quad. The visible core is a small fraction of this;
// the rest is the halo falloff, which needs room or it clips into a square.
const MARKER_QUAD_PX = 14.0;

// ----------------------------------------------------------------------------
// The marker itself: a camera-facing quad with an Airy-like profile — a tight
// core plus a broad faint halo, which is what an unresolved source actually
// looks like once optics and the atmosphere are done with it.
//
// Blending is deliberately split. RGB adds (the marker is an emitter, and
// premultiplying by coverage in the shader keeps it energy-consistent), but
// ALPHA takes the MAX. Alpha in this pipeline is not opacity — it is the
// log-encoded true temperature that sim/spectrum.js reads to re-image the
// frame in a non-visible band (see CLAUDE.md). Adding temperatures would be
// meaningless; taking the hottest contributor at a pixel is the correct
// composite, and it matters here more than anywhere else, because a sub-pixel
// star has NO mesh fragments left — the marker is the only thing publishing a
// temperature for it.
// ----------------------------------------------------------------------------
export function createMarker({ color, teff, gain = 1 }) {
  const mat = new THREE.ShaderMaterial({
    uniforms: {
      uColor:   { value: new THREE.Color(color) },
      uOpacity: { value: 0 },
      uGain:    { value: gain },
      uSel:     { value: 0 },
      // same encoding as the surface shaders: log(T)/25.33, clamped below 1
      uTempA:   { value: teff > 0 ? Math.min(Math.log(Math.max(teff, 1)) / 25.33, 0.98) : 0 },
    },
    vertexShader: `
      varying vec2 vUv;
      void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }`,
    fragmentShader: `
      precision highp float;
      uniform vec3 uColor; uniform float uOpacity; uniform float uGain; uniform float uTempA;
      uniform float uSel;
      varying vec2 vUv;
      void main(){
        float r = length(vUv - 0.5) * 2.0;
        if (r > 1.0) discard;
        float core = exp(-r * r * 30.0);
        float halo = exp(-r * r * 3.2) * 0.28;
        float a = (core + halo) * uOpacity;
        // Selection reticle. Once every planet is an honest point of light it is
        // indistinguishable from the background starfield, so picking one out of
        // the Bodies list has to show you WHERE it is. The ring sits well
        // outside the core so it frames the body without hiding it.
        float ring = uSel * uOpacity * 0.5 *
                     (smoothstep(0.58, 0.65, r) - smoothstep(0.71, 0.78, r));
        if (a <= 0.003 && ring <= 0.003) discard;
        // premultiplied: colour already carries its own coverage
        vec3 rgb = uColor * a * uGain + vec3(0.5, 0.72, 1.0) * ring;
        // alpha is temperature, not coverage — publish it only where the marker
        // is actually bright, so neither the faint halo nor the purely cosmetic
        // reticle paints a bogus temperature into the imaging bands
        gl_FragColor = vec4(rgb, uTempA * step(0.05, a));
      }`,
    transparent: true,
    depthWrite: false,
    blending: THREE.CustomBlending,
    blendEquation: THREE.AddEquation,      blendSrc: THREE.OneFactor,      blendDst: THREE.OneFactor,
    blendEquationAlpha: THREE.MaxEquation, blendSrcAlpha: THREE.OneFactor, blendDstAlpha: THREE.OneFactor,
  });

  const mesh = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), mat);
  mesh.frustumCulled = false;   // it is one quad, and its own scale is dynamic
  mesh.visible = false;
  mesh.renderOrder = 3;

  // Called per frame with the body's world position and its rendered radius.
  // Returns the marker's opacity, so the caller can tell whether the body is
  // currently being carried by the marker rather than by its mesh.
  function update(camera, worldPos, radiusScene, viewportH, selected = false) {
    mat.uniforms.uSel.value = selected ? 1 : 0;
    const dist = camera.position.distanceTo(worldPos);
    const fovRad = camera.fov * Math.PI / 180;
    const px = apparentPixels(radiusScene, dist, fovRad, viewportH);

    // 1 when the body is sub-pixel, 0 once the mesh is comfortably resolved
    const t = THREE.MathUtils.clamp((FADE_OUT_PX - px) / (FADE_OUT_PX - FADE_IN_PX), 0, 1);
    const opacity = t * t * (3 - 2 * t);          // smoothstep — no popping
    mat.uniforms.uOpacity.value = opacity;
    mesh.visible = opacity > 0.002;
    if (!mesh.visible) return 0;

    mesh.position.copy(worldPos);
    mesh.quaternion.copy(camera.quaternion);       // billboard
    // hold a constant on-screen size, which is the whole point of the marker
    mesh.scale.setScalar(MARKER_QUAD_PX / pixelsPerWorldUnit(dist, fovRad, viewportH));
    return opacity;
  }

  function dispose() { mesh.geometry.dispose(); mat.dispose(); }

  return { mesh, update, dispose, material: mat };
}
