import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

// ============================================================================
// CRAFT ASSETS — the authored models, and the rules that keep them honest.
// ----------------------------------------------------------------------------
// Every vehicle in sim/flight/craftmodel.js can be built out of Three.js
// primitives at real dimensions, and that procedural build is still there and
// still works. What it cannot do is BEVEL AN EDGE. A perfectly sharp edge
// catches no specular highlight at all, which is why hard surface assembled
// from CylinderGeometry reads as cardboard however right its silhouette is,
// and there is no bevel modifier at runtime. Nor can a lathe cut a recessed
// panel line: CylinderGeometry takes one radius, so a joint between barrel
// sections can only be a ring strapped round the outside.
//
// So the vehicles are authored in Blender — assets/blender/*.py, where the
// SCRIPT IS THE MODEL and nothing is clicked — and loaded here. The .glb files
// are build artifacts and are not in the repo; assets/blender/build.sh makes
// them, and a fresh clone runs without them.
//
// FOUR RULES THIS MODULE EXISTS TO KEEP.
//
//   · buildCraft() STAYS SYNCHRONOUS. Four call sites depend on it returning a
//     finished vehicle, one of them the studio's audit(), and making it async
//     would ripple through all of them for no gain. So assets are preloaded
//     into a cache and the builder reads the cache — a load is a startup
//     concern, not a per-build one.
//
//   · A MISSING ASSET IS NOT AN ERROR. If a .glb has not loaded, or 404s, or
//     the CDN that serves GLTFLoader is unreachable, the stage falls back to
//     its procedural build and the sim runs. A vehicle that cannot be drawn
//     without a network round trip is a vehicle that cannot be drawn — so the
//     fallback is kept working rather than left to rot.
//
//   · LOAD ONE VEHICLE, NOT NINE. The set is about 12 MB and two thirds of
//     that is the Hail Mary alone; pulling all of it to fly a Falcon 9 would
//     put a multi-megabyte stall in front of a launch for eight models that
//     will not be drawn. preloadCraft(id) fetches exactly one, and everything
//     that builds a craft asks for the one it is about to build.
//
//   · THE MOVING PARTS ARE BOUND BY NAME, and the names are an INTERFACE.
//     craftmodel's update() drives whatever is in `parts`, and spaceflight.js
//     hangs the plumes on the same objects. Rename a node in a .py file and
//     the legs stop deploying — silently, with no error anywhere — so the
//     patterns below and the prefixes in assets/blender/common.py are one
//     agreement written in two places.
// ============================================================================

/** Authored models, resolved against this module so the path is the same from
 *  the page, from the studio in .claude/, and from anything else that imports
 *  the sim. Keys are vehicle ids from sim/flight/vehicles.js. */
const asset = (f) => new URL(`../../assets/${f}`, import.meta.url).href;
export const CRAFT_ASSETS = {
  saturnv:    asset('saturnv.glb'),
  falcon9:    asset('falcon9.glb'),
  shuttle:    asset('shuttle.glb'),
  starship:   asset('starship.glb'),
  lm:         asset('lm.glb'),
  skycrane:   asset('skycrane.glb'),
  ioncruiser: asset('ioncruiser.glb'),
  hailmary:   asset('hailmary.glb'),
  beetle:     asset('beetle.glb'),
};

/**
 * Emitters have to be scaled for an HDR pipeline. Blender writes the strength
 * through KHR_materials_emissive_strength, which three reads into
 * `emissiveIntensity` — but if that extension is ever dropped the value
 * silently comes back as 1.0 and a drive face renders as a dull red disc.
 * Taking the max is idempotent: a no-op when the extension loaded, a rescue
 * when it did not.
 */
const EMISSIVE = { emitPlate: 2.0, emitCell: 6.0 };

/**
 * The node names craftmodel drives, mapped to the `parts` bucket they belong
 * in. Anchored and digit-terminated on purpose: a helper empty called
 * `mount_gimbal_x` or `gimbal_beetle_0_mount` must NOT be collected as a
 * pivot, and a loose `startsWith` would collect both and drive the wrong node.
 * `_fixed` is the one permitted suffix — see bindParts.
 */
const ROLES = [
  ['gimbals', /^gimbal_[A-Za-z0-9]+_\d+(_fixed)?$/],
  ['legs',    /^leg_[A-Za-z0-9]+_\d+$/],
  ['fins',    /^fin_[A-Za-z0-9]+_\d+$/],
  ['arrays',  /^array_[A-Za-z0-9]+_\d+$/],
  ['flaps',   /^flap_[A-Za-z0-9]+_\d+$/],
  ['halves',  /^half_[A-Za-z0-9]+_\d+$/],
];

const CACHE = new Map();          // id -> Map<stageKey, Object3D> | null
const PENDING = new Map();        // id -> Promise<boolean>
let loader = null;

function prepare(root) {
  root.traverse((o) => {
    if (!o.isMesh) return;
    o.frustumCulled = false;          // one object, drawn every frame anyway
    const mats = Array.isArray(o.material) ? o.material : [o.material];
    for (const m of mats) {
      if (!m) continue;
      // Most of this set is open shells — a lathed bell, an aft skirt, an
      // interstage, a fairing half — and a single-sided shell has no inner
      // wall: you look into an engine bell and see sky. The exporter already
      // writes doubleSided; this is the belt.
      m.side = THREE.DoubleSide;
      const want = EMISSIVE[m.name];
      if (want) m.emissiveIntensity = Math.max(m.emissiveIntensity ?? 1, want);
    }
  });
  return root;
}

/**
 * Split a loaded scene into its per-stage subtrees.
 *
 * A vehicle is one file with one `stage_<key>` node per stage, because
 * buildCraft positions each stage's group itself — a mounted stage does not
 * even sit where the file has it (the Shuttle's orbiter is bolted to the side
 * of the tank). So the subtrees are detached here and handed out one at a
 * time, each still carrying its own internal offset.
 */
function splitStages(scene) {
  const stages = new Map();
  scene.traverse((o) => {
    if (o.name.startsWith('stage_')) stages.set(o.name.slice(6), o);
  });
  for (const s of stages.values()) s.parent?.remove(s);
  return stages;
}

/** Load one vehicle's model. Resolves either way — a rejection here would take
 *  the whole sim down for a decoration. */
export function preloadCraft(id) {
  if (PENDING.has(id)) return PENDING.get(id);
  const url = CRAFT_ASSETS[id];
  if (!url) { CACHE.set(id, null); return Promise.resolve(false); }
  loader = loader || new GLTFLoader();
  const p = new Promise((res) => {
    loader.load(url,
      (gltf) => { CACHE.set(id, splitStages(prepare(gltf.scene))); res(true); },
      undefined,
      (err) => {
        console.warn(`[craftassets] ${id} unavailable, using the procedural build`, err);
        CACHE.set(id, null);
        res(false);
      });
  });
  PENDING.set(id, p);
  return p;
}

/**
 * Settle the models for the given vehicle ids, or for ALL of them if none is
 * named. Anything that builds a craft has to await this first or it silently
 * measures the fallback — which for the studio's audit() means reporting the
 * fallback's triangle count as the regression number.
 */
export function craftModelsReady(...ids) {
  const want = ids.flat().filter(Boolean);
  return Promise.all((want.length ? want : Object.keys(CRAFT_ASSETS)).map(preloadCraft));
}

/**
 * A fresh instance of one authored stage, or null if there isn't one.
 * `clone(true)` shares geometry and materials with the template, so a second
 * vehicle costs a hierarchy and nothing else.
 */
export function craftStage(vehicleId, stageKey) {
  const v = CACHE.get(vehicleId);
  const t = v && v.get(stageKey);
  return t ? t.clone(true) : null;
}

/**
 * Bind an authored stage's moving parts into the `parts` record craftmodel
 * keeps. Sorted by name so the order is deterministic across loads — the
 * plumes are created in this order and an engine that swaps index between
 * runs would swap its exhaust with its neighbour.
 */
export function bindParts(root, parts, spec) {
  let n = 0;
  for (const [bucket, re] of ROLES) {
    const found = [];
    root.traverse((o) => { if (re.test(o.name)) found.push(o); });
    found.sort((a, b) => a.name.localeCompare(b.name));
    for (const p of found) {
      if (bucket === 'gimbals') {
        // A PIVOT DECLARES HOW FAR IT MAY SWING and update() clamps to it,
        // because a cluster is not all one engine: Starship's three vacuum
        // Raptors are rigid and sit in the same list as its three that steer,
        // and twenty of Super Heavy's thirty-three are bolted down. The model
        // says which by suffixing the node `_fixed`; everything else gets the
        // engine's published authority. Without this the Hail Mary's rigid
        // spin drives sat visibly canted and waggled once a second.
        p.userData.gimbalDeg = p.name.endsWith('_fixed') ? 0 : (spec?.engine?.gimbal ?? 0);
      }
      parts[bucket].push(p);
      n++;
    }
  }
  return n;
}
