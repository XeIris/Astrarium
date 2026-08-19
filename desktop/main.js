// ============================================================================
// Astrarium — Electron shell
// ============================================================================
// This hosts the EXACT same files the browser build serves. There is no
// desktop-specific branch of the simulation, no bundler and no build step: the
// window points at ../blackhole_sim.html and everything else is identical.
// Deleting this directory leaves the web build untouched, which is the whole
// design constraint — the project's stack convention (see CLAUDE.md) is "no
// package.json, no dependencies", so the one package.json that exists lives
// down here and the root stays clean.
//
// WHAT THE SHELL IS ACTUALLY FOR
//
// Not frame time. It is the same Chromium, the same ANGLE→Metal translation
// and the same shaders, so a frame that costs 11 ms in a tab costs 11 ms here.
// What it buys is everything around that:
//
//   · A profiling attempt that is at least possible. Chrome exposes
//     EXT_disjoint_timer_query_webgl2 in a normal tab but zeroes the results;
//     the switches below ask for real ones. On this stack they do not arrive —
//     ANGLE's Metal backend implements no GPU timestamps, so the queries still
//     return 0 here (see PORTING.md). macOS measurement therefore uses the
//     readPixels fallback, and the switch is kept for the platforms where it
//     does work.
//   · No background throttling. requestAnimationFrame in a hidden tab is
//     frozen, which makes unattended measurement impossible.
//   · No vsync ceiling, so a frame that takes 6 ms reports as 6 ms instead of
//     queueing to the next 16.7 ms boundary.
//   · A native process, which Instruments and Metal System Trace can attach to.
//   · A pinned Chromium, so the renderer does not change under you.
// ============================================================================

const { app, BrowserWindow, shell } = require('electron');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const stabilityMode = !!process.env.ASTRARIUM_STABILITY;
const ENTRY = stabilityMode ? 'desktop/stability.html' : 'blackhole_sim.html';

// ---- GPU switches ----------------------------------------------------------
// These must be set before app 'ready'.
//
// enable-gpu-benchmarking is the one that would matter: it is what un-blunts
// EXT_disjoint_timer_query_webgl2 on backends that implement timestamps.
// ANGLE/Metal does not, so on macOS the queries return 0 with or without it
// and desktop/bench.js reports timerQueriesReturnRealValues: false.
app.commandLine.appendSwitch('enable-gpu-benchmarking');
app.commandLine.appendSwitch('enable-webgl-draft-extensions');
// Uncap: report the true frame cost instead of the vsync interval.
app.commandLine.appendSwitch('disable-gpu-vsync');
app.commandLine.appendSwitch('disable-frame-rate-limit');
// Available for when the marcher wants compute shaders; harmless until then.
app.commandLine.appendSwitch('enable-unsafe-webgpu');
app.commandLine.appendSwitch('ignore-gpu-blocklist');

// ---- static server ---------------------------------------------------------
// The sim is ES modules with a CDN importmap, and modules cannot load over
// file:// (opaque origin). So serve the folder over loopback on an ephemeral
// port — the same arrangement as .claude/serve.mjs, for the same reason.
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.webp': 'image/webp',
};

function startServer() {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const url = decodeURIComponent((req.url || '/').split('?')[0]);
      const rel = path.normalize(url === '/' ? `/${ENTRY}` : url).replace(/^(\.\.[/\\])+/, '');
      const file = path.join(ROOT, rel);
      // Never serve outside the project directory.
      if (!file.startsWith(ROOT)) { res.writeHead(403).end('forbidden'); return; }
      fs.readFile(file, (err, buf) => {
        if (err) { res.writeHead(404).end('not found'); return; }
        res.writeHead(200, {
          'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
          // Same reason as the dev server: never hand back a stale module.
          'Cache-Control': 'no-store',
        });
        res.end(buf);
      });
    });
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

async function createWindow() {
  const port = await startServer();
  const hash = process.env.ASTRARIUM_SCENARIO ? `#${process.env.ASTRARIUM_SCENARIO}` : '';

  const win = new BrowserWindow({
    width: 1600,
    height: 900,
    backgroundColor: '#000000',
    title: 'Astrarium',
    show: false,
    webPreferences: {
      // The sim is a local, self-contained document; it needs no Node access.
      nodeIntegration: false,
      contextIsolation: true,
      // The point of a desktop shell: keep rendering when not focused, so a
      // long integration or an unattended measurement actually runs.
      backgroundThrottling: false,
    },
  });

  win.once('ready-to-show', () => win.show());
  win.loadURL(`http://127.0.0.1:${port}/${ENTRY}${hash}`);

  // Keep external links out of the app window.
  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });

  if (process.env.ASTRARIUM_DEVTOOLS) win.webContents.openDevTools({ mode: 'detach' });

  // ---- automation modes ----------------------------------------------------
  // Both modes run in a hidden renderer, print JSON, and exit. This keeps the
  // visual benchmark and the long numerical stability check out of the normal
  // interactive shell while still exercising the browser's actual modules.
  const automation = stabilityMode ? 'stability.js' : (process.env.ASTRARIUM_BENCH ? 'bench.js' : null);
  if (automation) {
    win.webContents.once('did-finish-load', async () => {
      // Exit status is the only thing CI or a shell caller can read without
      // parsing the JSON, so a failed stability run and a thrown automation
      // script must both be non-zero.
      let exitCode = 0;
      try {
        const src = fs.readFileSync(path.join(__dirname, automation), 'utf8');
        const result = await win.webContents.executeJavaScript(src, true);
        const label = stabilityMode ? 'STABILITY' : 'BENCH';
        process.stdout.write(`\n===${label}===\n` + JSON.stringify(result, null, 2) + `\n===END===\n`);
        if (stabilityMode && !(result && Array.isArray(result.results) && result.results.every((r) => r.passed))) exitCode = 1;
      } catch (err) {
        const label = stabilityMode ? 'STABILITY' : 'BENCH';
        process.stdout.write(`\n===${label}-ERROR===\n` + (err && err.stack || String(err)) + '\n');
        exitCode = 1;
      }
      app.exit(exitCode);
    });
  }
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
