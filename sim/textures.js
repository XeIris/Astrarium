import * as THREE from 'three';

// ============================================================================
// PROCEDURAL TEXTURES — value-noise fBm on a canvas, seeded per body so every
// world is unique and stable across frames.
// ============================================================================

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Tileable value-noise grid → sampler with bilinear interpolation.
function makeNoise(rand, size = 64) {
  const g = new Float32Array(size * size);
  for (let i = 0; i < g.length; i++) g[i] = rand();
  const at = (x, y) => g[((y % size + size) % size) * size + (x % size + size) % size];
  return (x, y) => {
    const xi = Math.floor(x), yi = Math.floor(y);
    const xf = x - xi, yf = y - yi;
    const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
    const a = at(xi, yi), b = at(xi + 1, yi), c = at(xi, yi + 1), d = at(xi + 1, yi + 1);
    return a * (1 - u) * (1 - v) + b * u * (1 - v) + c * (1 - u) * v + d * u * v;
  };
}

function fbm(noise, x, y, oct = 5) {
  let v = 0, amp = 0.5, freq = 1, norm = 0;
  for (let i = 0; i < oct; i++) { v += amp * noise(x * freq, y * freq); norm += amp; amp *= 0.5; freq *= 2.07; }
  return v / norm;
}

function lerp(a, b, t) { return a + (b - a) * t; }
function ramp(stops, t) {
  for (let i = 0; i < stops.length - 1; i++) {
    const [p0, c0] = stops[i], [p1, c1] = stops[i + 1];
    if (t <= p1) {
      const k = (t - p0) / (p1 - p0 || 1);
      return [lerp(c0[0], c1[0], k), lerp(c0[1], c1[1], k), lerp(c0[2], c1[2], k)];
    }
  }
  return stops[stops.length - 1][1];
}

function toTexture(canvas) {
  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  return tex;
}

// ----------------------------------------------------------------------------
// ROCKY PLANET: continents from elevation fBm, oceans, polar ice, hot worlds.
// ----------------------------------------------------------------------------
export function rockyTexture(seed, opts = {}) {
  const W = 512, H = 256;
  const c = document.createElement('canvas'); c.width = W; c.height = H;
  const ctx = c.getContext('2d');
  const img = ctx.createImageData(W, H);
  const rand = mulberry32(seed);
  const noise = makeNoise(rand, 64);
  const sea = opts.seaLevel ?? 0.5;
  const hot = opts.hot ?? false;     // Mars/Mercury-like dry world

  const land = hot
    ? [[0, [90, 50, 35]], [0.5, [150, 90, 60]], [0.8, [190, 130, 95]], [1, [225, 200, 180]]]
    : [[0, [40, 90, 45]], [0.45, [90, 130, 60]], [0.7, [150, 130, 90]], [0.88, [130, 105, 80]], [1, [255, 255, 255]]];
  const ocean = [[0, [4, 20, 55]], [1, [20, 70, 120]]];

  for (let y = 0; y < H; y++) {
    const lat = (y / H - 0.5) * 2;              // -1..1
    for (let x = 0; x < W; x++) {
      const u = x / W * 6, v = y / H * 3;
      let e = fbm(noise, u, v, 6);
      e += 0.12 * fbm(noise, u * 4 + 11, v * 4 + 7, 3); // ridged detail
      let col;
      if (!hot && e < sea) {
        col = ramp(ocean, e / sea);
      } else {
        const t = hot ? e : (e - sea) / (1 - sea);
        col = ramp(land, Math.min(t, 1)).slice();
        // ice caps toward the poles, modulated by terrain noise
        const ice = Math.max(0, Math.abs(lat) - 0.7 + 0.15 * (fbm(noise, u + 3, v + 9, 2) - 0.5));
        if (!hot && ice > 0) { const k = Math.min(ice * 2, 1); col = [lerp(col[0], 250, k), lerp(col[1], 252, k), lerp(col[2], 255, k)]; }
      }
      const i = (y * W + x) * 4;
      img.data[i] = col[0]; img.data[i + 1] = col[1]; img.data[i + 2] = col[2]; img.data[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  return toTexture(c);
}

// ----------------------------------------------------------------------------
// GAS GIANT: zonal bands (latitude) warped by turbulence + a great storm spot.
// ----------------------------------------------------------------------------
export function gasGiantTexture(seed, palette) {
  const W = 512, H = 256;
  const c = document.createElement('canvas'); c.width = W; c.height = H;
  const ctx = c.getContext('2d');
  const img = ctx.createImageData(W, H);
  const rand = mulberry32(seed);
  const noise = makeNoise(rand, 64);
  const pal = palette || [[210, 180, 140], [180, 140, 100], [230, 210, 180], [150, 110, 80]];
  const bands = 7 + Math.floor(rand() * 6);
  const spotLat = (rand() - 0.5) * 1.0;
  const spotLon = rand();
  const spotR = 0.06 + rand() * 0.05;
  const spotCol = [220, 120, 90];

  for (let y = 0; y < H; y++) {
    const lat = y / H;
    for (let x = 0; x < W; x++) {
      const lon = x / W;
      // turbulent warp of the latitude coordinate → wavy bands
      const warp = (fbm(noise, lon * 8, lat * 3, 4) - 0.5) * 0.08;
      const b = (lat + warp) * bands;
      const t = (Math.sin(b * Math.PI) * 0.5 + 0.5);
      const idx = ((Math.floor(b) % pal.length) + pal.length) % pal.length;
      const cA = pal[idx], cB = pal[(idx + 1) % pal.length];
      let col = [lerp(cA[0], cB[0], t), lerp(cA[1], cB[1], t), lerp(cA[2], cB[2], t)];
      // fine swirl detail
      const sw = (fbm(noise, lon * 24, lat * 10 + 4, 3) - 0.5) * 30;
      col = [col[0] + sw, col[1] + sw, col[2] + sw];
      // great storm
      const dLat = (lat - 0.5 - spotLat * 0.5);
      let dLon = Math.abs(lon - spotLon); dLon = Math.min(dLon, 1 - dLon);
      const sd = Math.sqrt((dLon * 2.2) ** 2 + (dLat * 4) ** 2);
      if (sd < spotR) {
        const k = (1 - sd / spotR) * 0.85;
        col = [lerp(col[0], spotCol[0], k), lerp(col[1], spotCol[1], k), lerp(col[2], spotCol[2], k)];
      }
      const i = (y * W + x) * 4;
      img.data[i] = col[0]; img.data[i + 1] = col[1]; img.data[i + 2] = col[2]; img.data[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  return toTexture(c);
}

export const GAS_PALETTES = {
  jupiter: [[200, 165, 130], [170, 120, 85], [225, 205, 175], [140, 95, 70]],
  saturn:  [[225, 205, 160], [200, 180, 140], [240, 225, 195], [185, 160, 120]],
  ice:     [[140, 190, 215], [100, 150, 190], [180, 215, 230], [80, 130, 170]],   // Uranus/Neptune
};
