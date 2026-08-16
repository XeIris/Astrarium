// Minimal static file server for previewing the sim (no dependencies).
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { extname, join, normalize } from 'node:path';

// fileURLToPath, not .pathname: the latter keeps percent-escapes, so a checkout
// under a path with a space or a non-ASCII character yields a ROOT that no
// readFile can resolve.
const ROOT = fileURLToPath(new URL('..', import.meta.url));
// Honour PORT so a second instance can run beside an existing one.
const PORT = Number(process.env.PORT) || 8777;

const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.json': 'application/json', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
};

createServer(async (req, res) => {
  let p;
  try {
    // A malformed escape ('%E0%A4%A') makes decodeURIComponent throw URIError.
    // Uncaught inside an async request handler that rejects the whole process,
    // so a stray bad URL would take the preview server down mid-session.
    p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  } catch {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end('400');
    return;
  }
  if (p === '/') p = '/blackhole_sim.html';
  const file = join(ROOT, normalize(p).replace(/^(\.\.[/\\])+/, ''));
  try {
    const data = await readFile(file);
    res.writeHead(200, {
      'Content-Type': TYPES[extname(file)] || 'application/octet-stream',
      // Without this the browser applies heuristic caching to responses that
      // carry neither Last-Modified nor Cache-Control, and silently keeps
      // serving stale ES modules after an edit — you reload, see the old
      // shader, and go hunting for a bug that isn't there.
      'Cache-Control': 'no-store, must-revalidate',
    });
    res.end(data);
  } catch (err) {
    // Only a genuinely absent file is a 404. A permission error or an EISDIR
    // reported as "not found" sends you looking for a typo in a path that is
    // in fact correct.
    if (err.code === 'ENOENT') {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('404');
    } else {
      console.error(`${file}: ${err.code || err.message}`);
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('500');
    }
  }
  // Loopback only. This serves the repository root with no path allow-list, so
  // on 0.0.0.0 every device on the network could read the checkout.
}).listen(PORT, '127.0.0.1', () => console.log(`serving on http://localhost:${PORT}`));
