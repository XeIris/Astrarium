// ============================================================================
// WEB REFERENCE CAPTURE — screenshots of the web build, for side-by-side
// comparison with the Godot port. No dependencies: it launches Chrome with the
// DevTools protocol open and speaks it over Node's built-in WebSocket.
//
//   node godot/tools/webref.mjs shots.json outdir/
//
// shots.json is an array of { name, hash?, query?, setup?, frames?, dt?, hud?,
// width?, height?, wait? }:
//   setup   JS evaluated in the page once SIM exists (a string; may be async).
//           Runs after the start screen is dismissed with the chosen mode.
//   mode    'sandbox' | 'learn' | 'flight' (default sandbox) — the start card
//   frames  SIM.frame(dt) calls to pump after setup (deterministic stepping)
//   hud     false (default) hides the HUD for a clean 3D frame
//   wait    ms of real time to let async things settle (model loads)
//   page    another page under the web root instead of blackhole_sim.html
//           (e.g. '.claude/skytest.html'); `ready` is then the JS expression
//           waited on (default: the SIM test), and frames are only pumped if
//           the page has a SIM
//   mode    'none' leaves the start screen up (a shot OF the start screen)
//   bare    true also writes <name>.bare.png: the same frame with every HUD
//           element hidden — the 3D background alone, for overlay tests
//   dump    JS evaluated after the capture; its JSON value is written to
//           outdir/<name>.json. An expression (may be async), or a function
//           body if it contains `return`.
//
// The page is served by .claude/serve.mjs, started here on PORT (default 8779)
// so it never collides with a preview already running on 8777.
// ============================================================================
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// WEB_ROOT overrides the checkout served — a git worktree has no assets/*.glb
// (they are build artifacts), so point it at a checkout that has them.
const ROOT = process.env.WEB_ROOT || fileURLToPath(new URL('../..', import.meta.url));
const PORT = Number(process.env.PORT) || 8779;
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const sleep = ms => new Promise(r => setTimeout(r, ms));

const [, , shotsPath, outDir] = process.argv;
if (!shotsPath || !outDir) { console.error('usage: webref.mjs shots.json outdir'); process.exit(2); }
const shots = JSON.parse(await readFile(shotsPath, 'utf8'));
await mkdir(outDir, { recursive: true });

const server = spawn('node', [join(ROOT, '.claude/serve.mjs')], { env: { ...process.env, PORT: String(PORT) }, stdio: 'ignore' });
const profile = join(outDir, '.chrome-profile');
const chrome = spawn(CHROME, [
  '--headless=new', `--remote-debugging-port=${PORT + 1}`, `--user-data-dir=${profile}`,
  '--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader',
  '--hide-scrollbars', '--mute-audio', '--no-first-run', '--window-size=1280,720', 'about:blank',
], { stdio: 'ignore' });
const cleanup = () => { try { chrome.kill(); } catch {} try { server.kill(); } catch {} };
process.on('exit', cleanup);

let wsUrl = null;
for (let i = 0; i < 60 && !wsUrl; i++) {
  await sleep(250);
  try {
    const list = await (await fetch(`http://127.0.0.1:${PORT + 1}/json/list`)).json();
    const page = list.find(t => t.type === 'page');
    if (page) wsUrl = page.webSocketDebuggerUrl;
  } catch {}
}
if (!wsUrl) { console.error('chrome did not come up'); cleanup(); process.exit(1); }

const ws = new WebSocket(wsUrl);
await new Promise(r => ws.addEventListener('open', r, { once: true }));
let seq = 0; const pending = new Map();
ws.addEventListener('message', ev => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); }
  if (m.method === 'Runtime.consoleAPICalled' && process.env.VERBOSE) console.log('[page]', m.params.args.map(a => a.value ?? a.description).join(' '));
  if (m.method === 'Runtime.exceptionThrown') console.log('[page exception]', m.params.exceptionDetails?.exception?.description ?? m.params.exceptionDetails?.text);
});
const send = (method, params = {}) => new Promise((res, rej) => { const id = ++seq; pending.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
};
await send('Runtime.enable'); await send('Page.enable');

for (const s of shots) {
  const w = s.width || 1280, h = s.height || 720;
  await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: false });
  const url = `http://127.0.0.1:${PORT}/${s.page || 'blackhole_sim.html'}${s.query ? '?' + s.query : '?r=' + Math.random()}${s.hash ? '#' + s.hash : ''}`;
  await send('Page.navigate', { url });
  const ready = s.ready || 'typeof window.SIM === "object" && !!SIM.state.preset';
  for (let i = 0; i < 80; i++) { await sleep(150); if (await evaluate(ready).catch(() => false)) break; }
  await sleep(500);
  try {
    await evaluate(`(() => {
      const m = ${JSON.stringify(s.mode || 'sandbox')};
      if (m === 'none') return true;
      const card = document.querySelector('[data-start="' + m + '"]');
      if (card) card.click();
      const st = document.getElementById('startScreen'); if (st) st.style.display = 'none';
      return true; })()`);
    await sleep(300);
    if (s.setup) await evaluate(`(async () => { ${s.setup} })()`);
    if (s.hud === false || s.hud === undefined) await evaluate(`document.body.classList.add('hud-hidden'); true`);
    if (s.wait) await sleep(s.wait);
    const frames = s.frames ?? 30, dt = s.dt ?? 1 / 60;
    await evaluate(`(() => { if (typeof SIM === 'undefined') return true; for (let i = 0; i < ${frames}; i++) SIM.frame(${dt}); return true; })()`);
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    await writeFile(join(outDir, s.name + '.png'), Buffer.from(shot.data, 'base64'));
    if (s.dump) {
      const expr = /\breturn\b/.test(s.dump) ? `(async () => { ${s.dump} })()` : `(async () => (${s.dump}))()`;
      await writeFile(join(outDir, s.name + '.json'), JSON.stringify(await evaluate(expr), null, 1));
    } else {
      // Otherwise, whatever the setup left in window.__cap (camera, uniforms,
      // body state) is written beside the PNG, so a Godot harness can rebuild
      // the same frame. Evaluated AFTER the frames, so it can be a function.
      const cap = await evaluate(`(() => { const c = window.__cap; const v = typeof c === 'function' ? c() : c; return v ? JSON.stringify(v) : null; })()`);
      if (cap) await writeFile(join(outDir, s.name + '.json'), cap);
    }
    if (s.bare) {
      await evaluate(`(() => { for (const e of document.body.children) if (e.id !== 'canvas-wrap' && e.tagName !== 'SCRIPT') e.style.visibility = 'hidden'; return true; })()`);
      await sleep(100);
      const b = await send('Page.captureScreenshot', { format: 'png' });
      await writeFile(join(outDir, s.name + '.bare.png'), Buffer.from(b.data, 'base64'));
    }
    console.log('ok', s.name);
  } catch (e) {
    console.log('FAIL', s.name, e.message);
  }
}
ws.close(); cleanup();
process.exit(0);
