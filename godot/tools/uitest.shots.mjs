// ============================================================================
// The HUD reference set. Writes the shot list webref.mjs consumes, with the
// fixture dump (uitest.dump.js) attached to every shot:
//
//   node godot/tools/uitest.shots.mjs /tmp/ui/shots.json [--flat]
//   PORT=8797 WEB_ROOT=<checkout with assets> node godot/tools/webref.mjs /tmp/ui/shots.json /tmp/ui/web
//
// Each shot yields <name>.png (the page), <name>.bare.png (the same frame
// with the HUD hidden — uitest.gd draws the Godot HUD over it) and
// <name>.json (the state to reproduce). Every state named in the HUD brief is
// here: the start screen, the four open/collapsed states of the left column's
// chain, the settings pages, a search, a climate preset, the three modes, the
// model viewer and a toast.
// ============================================================================
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const dump = await readFile(fileURLToPath(new URL('./uitest.dump.js', import.meta.url)), 'utf8');
const close = id => `document.querySelector('[data-close=${id}]').click();`;
const sec = t => `[...document.querySelectorAll('#controlPanel .sec-head')].find(h => h.textContent.includes(${JSON.stringify(t)})).click();`;
const page = p => `document.querySelector('.set-tab[data-set=${p}]').click();`;

const base = [
  { name: 'start', mode: 'none', frames: 2 },
  { name: 'sandbox' },
  { name: 'chain_settings_closed', setup: close('settingsPanel') },
  { name: 'chain_scenario_closed', setup: close('scenarioPanel') },
  { name: 'chain_both_closed', setup: close('settingsPanel') + close('scenarioPanel') },
  { name: 'settings_render', setup: page('render') },
  { name: 'settings_sim', setup: page('sim') },
  { name: 'settings_sky_adv', setup: `document.getElementById('skyAdvOpen').click();` },
  { name: 'search', setup: `const i = document.getElementById('presetSearch'); i.value = 'star'; i.dispatchEvent(new Event('input'));` },
  { name: 'trisolaris', hash: 'trisolaris', frames: 240, setup: sec('Climate') },
  { name: 'flight', mode: 'flight', wait: 2500, frames: 20 },
  { name: 'learn', mode: 'learn', wait: 500 },
  { name: 'model', setup: `document.getElementById('modelOpen').click();`, wait: 1500 },
  { name: 'toast', setup: `document.getElementById('skyReset').click();` },
  { name: 'controls_closed', setup: close('controlPanel') },
];
// --flat hides the 3D canvas, so the page is the HUD over --bg alone: that is
// the committed reference set (godot/tools/ref/ui), small and pixel-diffable.
// Without it the frame behind the HUD is the live scene, for eyeballing the
// backdrop blur.
const flat = process.argv.includes('--flat');
const flatten = `document.getElementById('canvas-wrap').style.visibility = 'hidden';`;
const shots = [];
for (const s of base) shots.push({ ...s, setup: (flat ? flatten : '') + (s.setup || ''), hud: true, bare: true, dump });
for (const n of ['sandbox', 'trisolaris', 'start', 'chain_scenario_closed']) {
  const s = base.find(x => x.name === n);
  shots.push({ ...s, setup: (flat ? flatten : '') + (s.setup || ''), name: n + '_1600', width: 1600, height: 1000, hud: true, bare: true, dump });
}
await writeFile(process.argv.filter(a => !a.startsWith('--'))[2] || 'shots.json', JSON.stringify(shots, null, 1));
console.log('wrote', shots.length, 'shots');
