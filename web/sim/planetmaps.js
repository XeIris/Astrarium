import * as THREE from 'three';

// These are offline copies of mission maps, not network dependencies at run
// time. Only real Solar System bodies use them; invented worlds keep terrain().
const SOURCES = {
  Earth: { color: 'earth-july.jpg', mask: 'earth-land.png', kind: 1, scale: 1 },
  Mars:  { color: 'mars-viking.jpg', kind: 2, scale: 1.5 },
  Moon:  { color: 'moon-lro.jpg', kind: 2, scale: 0.24 },
};
const cache = new Map();
const loader = new THREE.TextureLoader();

export function loadPlanetMap(name, ready) {
  const source = SOURCES[name];
  if (!source) return false;
  let entry = cache.get(name);
  if (!entry) {
    entry = { ...source, color: null, mask: null, waiting: [], failed: false };
    cache.set(name, entry);
    const finish = () => {
      if (entry.failed || !entry.color || (source.mask && !entry.mask)) return;
      for (const callback of entry.waiting.splice(0)) callback(entry);
    };
    const fail = () => {
      entry.failed = true;
      entry.waiting.length = 0;
      console.warn(`Planet map for ${name} could not be loaded; using procedural surface`);
    };
    const color = loader.load(`./assets/planet-maps/${source.color}`, finish, undefined, fail);
    color.colorSpace = THREE.SRGBColorSpace;
    color.wrapS = THREE.RepeatWrapping;
    color.anisotropy = 8;
    entry.color = color;
    if (source.mask) {
      const mask = loader.load(`./assets/planet-maps/${source.mask}`, finish, undefined, fail);
      mask.wrapS = THREE.RepeatWrapping;
      entry.mask = mask;
    }
  }
  if (entry.failed) return false;
  if (entry.color?.image && (!source.mask || entry.mask?.image)) ready(entry);
  else entry.waiting.push(ready);
  return true;
}
