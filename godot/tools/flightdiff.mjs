// ============================================================================
// FLIGHT DIFF — per-scenario, per-field deviation between the JS reference run
// (tools/flightref.mjs) and the GDScript run (tools/flightcheck.gd).
//
//   node godot/tools/flightdiff.mjs js.json gd.json [scenario]
//
// flightref.mjs --compare reports the single worst number per scenario, which
// for a launch is always something like downrange at T-0 (0 m against 0.13 m:
// an acos of a dot product that is 1 in one runner and 1 − 1 ulp in the
// other). This breaks it down by FIELD, as absolute and relative deviation,
// and diffs the event logs — the event log is where a discrete divergence (a
// staging, an engine shutdown, a phase change on a different frame) shows up.
// ============================================================================
import { readFileSync } from 'node:fs';

const [pa, pb, only] = process.argv.slice(2);
const A = JSON.parse(readFileSync(pa, 'utf8')), B = JSON.parse(readFileSync(pb, 'utf8'));

for (const id of Object.keys(A.scenarios)) {
  if (only && id !== only) continue;
  const a = A.scenarios[id], b = B.scenarios[id];
  if (!b) { console.log(`${id}: missing`); continue; }
  console.log(`\n== ${id}   (${a.samples.length} vs ${b.samples.length} samples, ${a.summary.frames} vs ${b.summary.frames} frames)`);
  const fields = {};
  const n = Math.min(a.samples.length, b.samples.length);
  for (let i = 0; i < n; i++) {
    const x = a.samples[i], y = b.samples[i];
    for (const k of Object.keys(x)) {
      const xv = Array.isArray(x[k]) ? x[k] : [x[k]], yv = Array.isArray(y[k]) ? y[k] : [y[k]];
      xv.forEach((u, j) => {
        const w = yv[j];
        const f = fields[k] ??= { abs: 0, rel: 0, at: -1, str: 0 };
        if (typeof u === 'number' && typeof w === 'number') {
          const d = Math.abs(u - w);
          const r = d === 0 ? 0 : d / Math.max(Math.abs(u), Math.abs(w));
          if (d > f.abs) { f.abs = d; f.at = x.f ?? i; }
          if (r > f.rel) f.rel = r;
        } else if (u !== w) f.str++;
      });
    }
  }
  for (const [k, f] of Object.entries(fields)) {
    if (f.abs === 0 && f.str === 0) continue;
    console.log(`   ${k.padEnd(11)} max |Δ| ${f.abs.toExponential(3).padEnd(11)} max rel ${f.rel.toExponential(2).padEnd(10)} (frame ${f.at})${f.str ? `  ${f.str} string/bool diffs` : ''}`);
  }
  // summary
  const sd = [];
  for (const k of Object.keys(a.summary)) {
    if (k === 'wallMs') continue;
    const u = a.summary[k], w = b.summary[k];
    if (typeof u === 'number' && typeof w === 'number') { if (u !== w) sd.push(`${k} ${u} vs ${w}`); }
    else if (JSON.stringify(u) !== JSON.stringify(w) && typeof u !== 'object') sd.push(`${k} ${JSON.stringify(u)} vs ${JSON.stringify(w)}`);
  }
  if (sd.length) console.log('   summary: ' + sd.join('; '));
  // events: same messages, time deviation
  let maxDt = 0, msgDiff = 0;
  const m = Math.max(a.events.length, b.events.length);
  for (let i = 0; i < m; i++) {
    const e = a.events[i], g = b.events[i];
    if (!e || !g || e[1] !== g[1]) { if (msgDiff++ < 4) console.log(`   event ${i}: ${JSON.stringify(e)} vs ${JSON.stringify(g)}`); continue; }
    maxDt = Math.max(maxDt, Math.abs(e[0] - g[0]));
  }
  console.log(`   events: ${a.events.length} vs ${b.events.length}, ${msgDiff} message diffs, max time Δ ${maxDt.toExponential(2)} s`);
}
