// ============================================================================
// WEB REFERENCE FOR THE CRAFT STUDIO — .claude/crafttest.html and
// .claude/craftsheet.html in headless Chrome, for side-by-side comparison with
// tools/crafttest.gd / craftsheet.gd. A sibling of webref.mjs (same
// DevTools-over-WebSocket approach, no dependencies), because those pages have
// no SIM object and no start card for webref to wait on.
//
//   WEB_ROOT=/path/to/checkout PORT=8799 node tools/crafttest.web.mjs outdir [numbers] [shots] [sheet]
//
//   numbers  writes outdir/audit.json and outdir/clearance.json from
//            STUDIO.audit() / STUDIO.clearance()
//   shots    crafttest frames, 1280×720: every vehicle side/iso/detail, and
//            deploy=0 iso for the vehicles with deployables, and `under` for
//            the two ships whose drive faces are emitters
//   sheet    the contact sheet, all nine
//
// WEB_ROOT picks the checkout served: one WITH assets/*.glb measures the
// authored build, one without (a fresh worktree) measures the procedural
// fallback — which is the standing "move the meshes aside" check.
// ============================================================================
import { spawn } from 'node:child_process';
import { writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const requestedRoot = process.env.WEB_ROOT || fileURLToPath(new URL('..', import.meta.url));
const ROOT = existsSync(join(requestedRoot, 'blackhole_sim.html'))
  ? requestedRoot : join(requestedRoot, 'web');
const PORT = Number(process.env.PORT) || 8799;
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const [, , outDir, ...what] = process.argv;
if (!outDir) { console.error('usage: crafttest.web.mjs outdir [numbers] [shots] [sheet]'); process.exit(2); }
await mkdir(outDir, { recursive: true });

export const VEHICLES = ['saturnv', 'falcon9', 'shuttle', 'starship', 'lm', 'skycrane', 'ioncruiser', 'hailmary', 'beetle'];
export const STOWED = ['falcon9', 'starship', 'ioncruiser', 'lm', 'skycrane'];

const server = spawn('node', [join(ROOT, '.claude/serve.mjs')], { env: { ...process.env, PORT: String(PORT) }, stdio: 'ignore' });
const chrome = spawn(CHROME, [
  '--headless=new', `--remote-debugging-port=${PORT + 1}`, `--user-data-dir=${join(outDir, '.chrome-profile')}`,
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
  if (m.method === 'Runtime.exceptionThrown') console.log('[page exception]', m.params.exceptionDetails?.exception?.description ?? m.params.exceptionDetails?.text);
  if (m.method === 'Runtime.consoleAPICalled' && process.env.VERBOSE) console.log('[page]', m.params.args.map(a => a.value ?? a.description).join(' '));
});
const send = (method, params = {}) => new Promise((res, rej) => { const id = ++seq; pending.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
};
await send('Runtime.enable'); await send('Page.enable');

async function open(page, query, w, h, ready) {
  await send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: `http://127.0.0.1:${PORT}/.claude/${page}?${query}&r=${Math.random()}` });
  for (let i = 0; i < 200; i++) { await sleep(150); if (await evaluate(ready).catch(() => false)) return true; }
  console.log('TIMEOUT', page, query); return false;
}
async function shot(name) {
  const s = await send('Page.captureScreenshot', { format: 'png' });
  await writeFile(join(outDir, name + '.png'), Buffer.from(s.data, 'base64'));
  console.log('ok', name);
}

if (what.includes('numbers')) {
  await open('crafttest.html', 'v=saturnv', 1280, 720, 'typeof window.STUDIO === "object"');
  const audit = await evaluate('JSON.stringify(STUDIO.audit())');
  const clear = await evaluate('JSON.stringify(STUDIO.clearance())');
  await writeFile(join(outDir, 'audit.json'), audit + '\n');
  await writeFile(join(outDir, 'clearance.json'), clear + '\n');
  console.log('AUDIT', audit); console.log('CLEAR', clear);
}
if (what.includes('shots')) {
  const list = [];
  const only = process.env.ONLY ? process.env.ONLY.split(',') : null;
  for (const v of VEHICLES) for (const view of ['side', 'iso', 'detail']) list.push([v, view, 1]);
  for (const v of STOWED) list.push([v, 'iso', 0]);
  // The spin drives' faces are EMITTERS and point aft: only `under` sees them.
  for (const v of ['hailmary', 'beetle']) list.push([v, 'under', 1]);
  for (const [v, view, dep] of list) {
    if (only && !only.includes(`${v}_${view}`)) continue;
    if (await open('crafttest.html', `v=${v}&view=${view}&deploy=${dep}`, 1280, 720, 'typeof window.STUDIO === "object"')) {
      await evaluate('STUDIO.draw(); true');
      await sleep(200);
      await shot(`${v}_${view}${dep ? '' : '_stowed'}`);
    }
  }
}
if (what.includes('sheet')) {
  if (await open('craftsheet.html', `v=${VEHICLES.join(',')}&cols=5`, 1700, 1120, 'typeof window.SHEET === "object"')) {
    await sleep(300);
    await shot('craftsheet');
  }
}
ws.close(); cleanup();
process.exit(0);
