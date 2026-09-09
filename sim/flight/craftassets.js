import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

// ============================================================================
// CRAFT ASSETS — the authored models, and why there are any.
// ----------------------------------------------------------------------------
// Every vehicle in sim/flight/craftmodel.js is built out of Three.js primitives
// at real dimensions, and for eight of the nine that is the right trade: a
// Saturn V is a stack of cylinders and cones, it is genuinely parametric, and
// there is no asset to keep in step with the code.
//
// The Hail Mary is the one that is not. Its shape is three bent pressure
// vessels nested against a lathed spine, and what makes hard surface read is a
// BEVEL on every edge — a perfectly sharp edge catches no specular highlight at
// all, which is why a model assembled from CylinderGeometry looks like
// cardboard however right its silhouette is. There is no bevel modifier at
// runtime and adding one would cost more than loading a mesh. So that one ship
// is authored in Blender (assets/blender/hailmary.py — the script IS the
// model, nothing is clicked) and loaded here.
//
// THREE RULES THIS MODULE EXISTS TO KEEP.
//
//   · buildCraft() STAYS SYNCHRONOUS. Four call sites depend on it returning a
//     finished vehicle, one of them the studio's audit(), and making it async
//     would ripple through all of them for no gain. So the assets are preloaded
//     into a cache and the builder reads the cache — a load is a startup
//     concern, not a per-build one.
//
//   · A MISSING ASSET IS NOT AN ERROR. If the .glb has not loaded, or 404s, or
//     the CDN that serves GLTFLoader is unreachable, buildHailMary falls back to
//     its procedural build and the sim runs. A vehicle that cannot be drawn
//     without a network round trip is a vehicle that cannot be drawn.
//
//   · THE MOVING PARTS ARE BOUND BY NAME. craftmodel's update() drives whatever
//     is in `parts.gimbals`, and spaceflight.js hangs the plumes on the same
//     objects. In the .glb those are four empties named `gimbal_0` … `gimbal_3`,
//     each with identity rotation and its origin ON THE DRIVE'S EXIT PLANE.
// ============================================================================

/** Authored models, resolved against this module so the path is the same from
 *  the page, from the studio in .claude/, and from anything else that imports
 *  the sim. */
export const CRAFT_ASSETS = {
  hailmary: new URL('../../assets/hailmary.glb', import.meta.url).href,
};

/**
 * Emitters have to be scaled for an HDR pipeline. Blender writes the strength
 * through KHR_materials_emissive_strength, which three reads into
 * `emissiveIntensity` — but if that extension is ever dropped the value silently
 * comes back as 1.0 and a drive face renders as a dull red disc. Taking the max
 * is idempotent: it is a no-op when the extension loaded and a rescue when it
 * did not.
 */
const EMISSIVE = { emitPlate: 2.0, emitCell: 6.0 };

const CACHE = new Map();
let pending = null;

function prepare(root) {
  root.traverse((o) => {
    if (!o.isMesh) return;
    o.frustumCulled = false;          // one object, drawn every frame anyway
    const mats = Array.isArray(o.material) ? o.material : [o.material];
    for (const m of mats) {
      if (!m) continue;
      // Most of this vehicle is open shells — a lathed reflector, an aft skirt,
      // a bulkhead ring — and a single-sided shell has no inner wall: you look
      // into a drive and see sky. The exporter already writes doubleSided, this
      // is the belt.
      m.side = THREE.DoubleSide;
      const want = EMISSIVE[m.name];
      if (want) m.emissiveIntensity = Math.max(m.emissiveIntensity ?? 1, want);
    }
  });
  return root;
}

/**
 * Load every authored model. Resolves either way — a rejection here would take
 * the whole sim down for a decoration.
 */
export function preloadCraftModels() {
  if (pending) return pending;
  const loader = new GLTFLoader();
  pending = Promise.all(Object.entries(CRAFT_ASSETS).map(([key, url]) =>
    new Promise((res) => {
      loader.load(url,
        (gltf) => { CACHE.set(key, prepare(gltf.scene)); res(true); },
        undefined,
        (err) => {
          console.warn(`[craftassets] ${key} unavailable, using the procedural build`, err);
          res(false);
        });
    })));
  return pending;
}

/** True once the preload has settled, whatever it found. */
export function craftModelsReady() { return preloadCraftModels(); }

/**
 * A fresh instance of an authored model, or null if there isn't one.
 * `clone(true)` shares geometry and materials with the template, so a second
 * vehicle costs a hierarchy and nothing else.
 */
export function craftModel(key) {
  const t = CACHE.get(key);
  return t ? t.clone(true) : null;
}

/**
 * Bind the model's moving parts into the `parts` record craftmodel keeps.
 * Only the four drive pivots move on this ship — its wings and radiators are
 * FIXED structure, and anything put in `parts.arrays` flies stowed until the
 * flight state asks for it, which for a heat rejection system is wrong.
 */
export function bindParts(root, parts) {
  const found = [];
  root.traverse((o) => { if (/^gimbal_\d+$/.test(o.name)) found.push(o); });
  found.sort((a, b) => a.name.localeCompare(b.name));
  for (const p of found) {
    // A spin drive is RIGID — it steers by differential power across four of
    // them, not by swinging. Declaring that is what stops update() canting it.
    p.userData.gimbalDeg = 0;
    parts.gimbals.push(p);
  }
  return found.length;
}
