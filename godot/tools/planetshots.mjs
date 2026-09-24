// ============================================================================
// PLANET REFERENCE SHOTS — writes the shots.json that webref.mjs runs over the
// web build for the solid-world / gas-giant / painter port, and the capture
// function every shot's setup installs.
//
//   node godot/tools/planetshots.mjs /abs/shots.json
//   PORT=8795 WEB_ROOT=<checkout> node godot/tools/webref.mjs /abs/shots.json outdir/
//   Godot --path godot res://tools/planettest.tscn -- scene=outdir/<name>.json \
//         out=/abs/<name>_godot.png band=<b> frames=<same as the shot>
//
// Each setup leaves window.__cap = a FUNCTION, which webref evaluates after
// its frames: the camera (absolute scene position, quaternion, fov, near,
// far), every named body's spec, position, spin phases, group transform and
// the live values of every uniform on every material, the sun list, the
// climate, and the painter's items with the options they were made from.
// tools/planettest.gd rebuilds exactly that frame.
// ============================================================================
import { writeFile } from 'node:fs/promises';

const CAPTURE = `
window.__capture = (names, extra) => {
  const S = SIM.state, cam = SIM.camera;
  const val = (v) => {
    if (v == null) return null;
    if (typeof v === 'number' || typeof v === 'boolean') return v;
    if (v.isColor) return [v.r, v.g, v.b];
    if (v.isVector4) return [v.x, v.y, v.z, v.w];
    if (v.isVector3) return [v.x, v.y, v.z];
    if (v.isVector2) return [v.x, v.y];
    if (Array.isArray(v)) return v.map(val);
    if (v instanceof Float32Array) return Array.from(v);
    return undefined;
  };
  const uni = (m) => { const o = {}; if (!m) return null; for (const k in m.uniforms) { const x = val(m.uniforms[k].value); if (x !== undefined) o[k] = x; } return o; };
  const bodies = S.bodies.filter(b => names.includes(b.name) && b.viz).map(b => {
    const v = b.viz, mats = {};
    for (const k of ['surfMat', 'cloudMat', 'atmoMat', 'mat', 'limbMat', 'ringMat']) if (v[k] && v[k].uniforms) mats[k] = uni(v[k]);
    const spec = {}; for (const k in b.spec) if (k !== 'pos' && k !== 'vel' && typeof b.spec[k] !== 'function') spec[k] = b.spec[k];
    return { name: b.name, type: b.type, id: b.id, pos: b.pos.toArray(), mass: b.mass, luminosity: b.luminosity ?? null,
      spin: b.spin ?? null, spinPhase: b.spinPhase ?? 0, cloudPhase: b.cloudPhase ?? 0, dayLength: b.dayLength ?? 0,
      radiusScene: b.radiusScene, radius: b.radius, spec, defColor: b.def ? b.def.color : null,
      gpos: v.group.position.toArray(), gquat: v.group.quaternion.toArray(), gscale: v.group.scale.toArray(),
      coreRotY: (v.surface || v.body || v.core).rotation.y, cloudRotY: v.clouds ? v.clouds.rotation.y : null,
      vortices: v.vortices ? v.vortices.map(x => ({ lat: x.lat, lon: x.lon, size: x.size, strength: x.strength })) : null,
      mats };
  });
  const stars = S.bodies.filter(b => b.type === 'star' || b.type === 'white-dwarf');
  const suns = S.suns.map(s => ({ name: s.body.name, pos: s.body.pos.toArray(), posScene: s.posScene.toArray(),
    color: [s.color.r, s.color.g, s.color.b], intensity: s.intensity, luminosity: s.body.luminosity ?? null, teff: s.body.teff ?? null }));
  const painter = SIM.painter.items.map((it, i) => ({ kind: it.kind, bodyId: it.bodyId, label: it.label, count: it.count ?? null,
    gpos: it.group.position.toArray(), gquat: it.group.quaternion.toArray(), gscale: it.group.scale.toArray(),
    uniforms: it.points ? uni(it.points.material) : (it.group.children[0] ? uni(it.group.children[0].material) : null),
    opts: (window.__paint || [])[i] || null }));
  let tmax = 0; for (const s of stars) tmax = Math.max(tmax, s.teff || 0);
  const cl = S.climate ? { T: S.climate.T, ice: S.climate.ice, clouds: S.climate.clouds, storm: S.climate.storm ?? null, humidity: S.climate.humidity } : null;
  return { preset: S.preset, sceneScale: S.sceneScale, trueScale: S.trueScale, band: S.band, time: S.time,
    cam: { pos: cam.position.toArray(), quat: cam.quaternion.toArray(), fov: cam.fov, near: cam.near, far: cam.far, aspect: cam.aspect },
    bodies, suns, painter, climate: cl, sceneMaxTemp: tmax || 5800, extra: extra || null,
    allBodies: S.bodies.map(b => ({ name: b.name, id: b.id, type: b.type, pos: b.pos.toArray(), luminosity: b.luminosity ?? null, gpos: b.viz ? b.viz.group.position.toArray() : null })) };
};`;

// Common setup: load, hide what is not ours (trails, the spacetime grid, the
// markers), pause the integrator so positions hold still, then frame `focus`
// with the camera `off` radians round from the sun direction.
function setup({ preset, focus, names, band = 3, trueScale, off = 1.4, theta = null, radiusK = 0.5, paint = '', extra = '', pause = true }) {
  return `${CAPTURE}
    SIM.state.showMesh = false;
    SIM.load(${JSON.stringify(preset)});
    SIM.scene.children.forEach(o => { if (o.isMesh && o.geometry && o.geometry.type === 'PlaneGeometry') o.visible = false; });
    ${trueScale != null ? `SIM.setTrueScale(${trueScale});` : ''}
    SIM.state.paused = ${pause};
    for (let i = 0; i < 3; i++) SIM.frame(1/60);
    const B = n => SIM.state.bodies.find(b => b.name === n);
    window.__paint = [];
    const paint = (spec) => { window.__paint.push(spec); return SIM.applyPaintSpec(spec); };
    ${paint}
    ${extra}
    const f = B(${JSON.stringify(focus)});
    SIM.setFollow(f);
    const sun = SIM.state.suns[0] ? SIM.state.suns[0].body : null;
    if (sun) { const d = sun.pos.clone().sub(f.pos); SIM.cam.phi = Math.atan2(d.z, d.x) + ${off}; }
    ${theta != null ? `SIM.cam.theta = ${theta};` : ''}
    SIM.cam.radius *= ${radiusK};
    SIM.setBand(${band});
    // setFollow GLIDES: the old target becomes an offset decaying at 5/s.
    // Seven seconds of frames leaves e^-35 of it, i.e. none.
    for (let i = 0; i < 420; i++) SIM.frame(1/60);
    SIM.state.bodies.forEach(b => { if (b.trail) b.trail.visible = false; });
    window.__cap = () => { SIM.state.bodies.forEach(b => { if (b.trail) b.trail.visible = false; }); return window.__capture(${JSON.stringify(names)}); };
  `;
}

const shots = [
  { name: 'earth_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Earth', names: ['Earth'] }) },
  { name: 'earth_ir', frames: 30, setup: setup({ preset: 'solar', focus: 'Earth', names: ['Earth'], band: 2 }) },
  { name: 'mars_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Mars', names: ['Mars'], off: 0.9, theta: 1.1 }) },
  { name: 'moon_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Moon', names: ['Moon'], off: 0.7 }) },
  { name: 'jupiter_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Jupiter', names: ['Jupiter'], off: 0.5 }) },
  { name: 'jupiter_run', frames: 900, setup: setup({ preset: 'solar', focus: 'Jupiter', names: ['Jupiter'], off: 0.5 }) },
  { name: 'jupiter_ir', frames: 30, setup: setup({ preset: 'solar', focus: 'Jupiter', names: ['Jupiter'], off: 0.5, band: 2 }) },
  { name: 'saturn_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Saturn', names: ['Saturn'], off: 0.6, theta: 1.15, radiusK: 0.75 }) },
  { name: 'neptune_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Neptune', names: ['Neptune'], off: 0.5 }) },
  { name: 'trisolaris_vis', frames: 30, setup: setup({ preset: 'trisolaris', focus: 'Trisolaris', names: ['Trisolaris'], off: 1.3 }) },
  { name: 'trisolaris_ir', frames: 30, setup: setup({ preset: 'trisolaris', focus: 'Trisolaris', names: ['Trisolaris'], off: 1.3, band: 2 }) },
  // A Foundry-style hot world: an Earth-like planet with air and water at
  // 0.6 AU, which the model has to dry out and scorch on its own.
  { name: 'hotworld_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Hotworld', names: ['Hotworld'], off: 1.0,
    extra: `SIM.spawnBody({ type: 'planet', name: 'Hotworld', mass: 3e-6, radiusKm: 6371, atmosphere: true, land: 0.35, biota: 1,
      albedo: 0.3, greenhouse: 0.61, obliquity: 0.3, pos: [0.6, 0, 0], vel: [0, 0, 8.11] }); for (let i = 0; i < 90; i++) SIM.frame(1/60);` }) },
  // A painted ring (Roche span) around Jupiter, and a belt round the Sun.
  { name: 'ring_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Jupiter', names: ['Jupiter'], off: 0.5, theta: 1.2, radiusK: 1.1,
    paint: `{ const j = B('Jupiter'); paint({ kind: 'ring', body: 'Jupiter', inner: j.radius * 1.2, outer: j.radius * 2.6, tilt: 0.1, color: 0xcdbb99 }); }` }) },
  { name: 'belt_vis', frames: 30, setup: setup({ preset: 'solar', focus: 'Sun', names: [], off: 0, theta: 0.9, radiusK: 1,
    paint: `paint({ kind: 'belt', body: 'Sun', inner: 2.1, outer: 3.4, perturber: 5.2, color: 0x9a8d7c, surfaceDensity: -1.0 });`,
    extra: `SIM.setFollow(B('Sun')); ` }) },
];
// The belt is framed from outside the inner system, not at seven solar radii.
shots.find(s => s.name === 'belt_vis').setup += `SIM.cam.radius = 9; SIM.cam.radiusTo = null; SIM.frame(1/60);`;

await writeFile(process.argv[2], JSON.stringify(shots, null, 1));
console.log('wrote', shots.length, 'shots');
