// ============================================================================
// Reference shots for the star / compact-object port (tools/startest.gd).
//
//   node godot/tools/stars_shots.mjs > /tmp/stars_shots.json
//   PORT=8793 WEB_ROOT=<checkout> node godot/tools/webref.mjs /tmp/stars_shots.json <out>/
//   Godot --path godot res://tools/startest.tscn -- state=<out>/<name>.json out=<png>
//
// Every shot dumps its state (tools/stars_dump.js) so the Godot harness can
// rebuild the SAME frame — same camera, same spots, same flare, same clocks.
// The sky is switched off in both (the sky port is another module's), so the
// background is black and the comparison is the bodies alone.
// ============================================================================
import { readFileSync } from 'node:fs';
const dump = readFileSync(new URL('./stars_dump.js', import.meta.url), 'utf8');
const noSky = `SIM.setSky({ ...SIM.state.sky, env: {} });`;
const follow = n => `const B = SIM.state.bodies.find(b => b.name.includes(${JSON.stringify(n)})); SIM.setFollow(B);`;
// A forced flare, moved onto a region ~55° round from the sub-camera point so
// the ribbons, the filament on the disc AND the prominence past the limb are
// all in view (ignite() would pick a random region, often on the far side).
const flare = (n, e, x) => `const F = SIM.flare(B, { energy: ${e} }); F.t = F.duration * ${x};
  { const u = B.viz.mat.uniforms, lat = 0.3, om = u.uOmega.value * (1 - 0.19 * Math.sin(lat) ** 2);
    const d = SIM.camera.position.clone().sub(B.viz.group.position).normalize();
    const lon = Math.atan2(d.z, d.x) + 0.95 - om * (u.uTime.value + 0.5);
    F.region = { lat, lon, strength: 0.8, age: 0.1, life: 0.5 }; }`;
const band = i => `SIM.setBand(${i});`;
const shots = [
  { name: 'sun', hash: 'edu_sun', setup: noSky + follow('Sun') + 'SIM.state.timeScale = 0.002;' },
  { name: 'sun_flare', hash: 'edu_sun', setup: noSky + follow('Sun') + 'SIM.state.timeScale = 0.002;' + flare('Sun', 2.5, 0.3) },
  { name: 'sun_flare_xray', hash: 'edu_sun', setup: noSky + follow('Sun') + 'SIM.state.timeScale = 0.002;' + flare('Sun', 2.5, 0.3) + band(6) },
  { name: 'vega', hash: 'vega', setup: noSky + follow('Vega') },
  { name: 'vega_uv', hash: 'vega', setup: noSky + follow('Vega') + band(4) },
  { name: 'proxima_flare', hash: 'alphacen', setup: noSky + follow('Proxima') + 'SIM.state.timeScale = 0.0005;' + flare('Proxima', 2.5, 0.25) },
  { name: 'proxima_flare_xray', hash: 'alphacen', setup: noSky + follow('Proxima') + 'SIM.state.timeScale = 0.0005;' + flare('Proxima', 2.5, 0.25) + band(6) },
  { name: 'sirius_b', hash: 'sirius', setup: noSky + follow('Sirius B') },
  { name: 'pulsar', hash: 'edu_pulsar', setup: noSky + follow('Pulsar') },
  { name: 'pulsar_xray', hash: 'edu_pulsar', setup: noSky + follow('Pulsar') + band(6) },
  { name: 'solar_true', hash: 'solar', setup: noSky + 'SIM.setTrueScale(true);' },
  { name: 'collapse', hash: 'sirius', frames: 40,
    setup: noSky + follow('Sirius A') + 'window.__pre = { radiusScene: B.radiusScene, pos: B.viz.group.position.toArray() }; SIM.coreCollapse(B);' },
];
for (const s of shots) { s.dump = dump; s.frames ??= 30; }
process.stdout.write(JSON.stringify(shots, null, 1));
