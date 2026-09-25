// ============================================================================
// Compare physref.mjs (web build) against physcheck.gd (Godot port).
//   node godot/tools/physdiff.mjs ref.json gd.json [--all]
// Walks both trees together. Numbers are compared by relative error
// |a−b| / max(|a|,|b|); strings, booleans and structure must match exactly; a
// key the JS left undefined is the same as one the port left null. Prints the
// maximum relative error per section and every mismatch above 1e-12 (or all
// with --all), and exits non-zero on any structural or string mismatch.
// ============================================================================
import { readFileSync } from 'node:fs';
const [refPath, gdPath, flag] = process.argv.slice(2);
const A = JSON.parse(readFileSync(refPath, 'utf8'));
const B = JSON.parse(readFileSync(gdPath, 'utf8'));
delete A.cases;

const stats = {};             // section → { n, max, where }
const bad = [];               // structural / string mismatches
const loose = [];             // numeric mismatches above the threshold
const THRESH = 1e-12;

function sectionOf(p) {
  const s = p.split('.');
  if (s[0] === 'presets' || s[0] === 'frames') return s.slice(0, 2).join('.');
  return s[0];
}
function walk(a, b, p) {
  if (a === undefined) a = null;
  if (b === undefined) b = null;
  if (typeof a === 'number' && typeof b === 'number') {
    const d = Math.abs(a - b), m = Math.max(Math.abs(a), Math.abs(b));
    const rel = d === 0 ? 0 : (m < 1e-300 ? 0 : d / m);
    const sec = sectionOf(p);
    const st = stats[sec] ??= { n: 0, max: 0, where: '' };
    st.n++;
    if (rel > st.max) { st.max = rel; st.where = `${p}: ${a} vs ${b}`; }
    if (rel > THRESH || flag === '--all' && rel > 0) loose.push({ p, a, b, rel });
    return;
  }
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') {
    if (a !== b) bad.push({ p, a, b });
    return;
  }
  if (Array.isArray(a) !== Array.isArray(b)) { bad.push({ p, a: 'array?' + Array.isArray(a), b: 'array?' + Array.isArray(b) }); return; }
  if (Array.isArray(a)) {
    if (a.length !== b.length) bad.push({ p: p + '.length', a: a.length, b: b.length });
    for (let i = 0; i < Math.min(a.length, b.length); i++) walk(a[i], b[i], `${p}.${i}`);
    return;
  }
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  // wall-clock timings are measurements of the machine, not results
  for (const k of ['ms', 'stepsPerSec']) keys.delete(k);
  for (const k of keys) walk(a[k], b[k], p ? `${p}.${k}` : k);
}
walk(A, B, '');

const secs = Object.keys(stats).sort();
console.log('section'.padEnd(34), 'numbers'.padStart(8), '  max rel err');
for (const s of secs) console.log(s.padEnd(34), String(stats[s].n).padStart(8), '  ' + stats[s].max.toExponential(2));
const worst = secs.reduce((m, s) => Math.max(m, stats[s].max), 0);
console.log(`\noverall max relative error: ${worst.toExponential(2)}`);
if (loose.length) {
  console.log(`\n${loose.length} numeric differences above ${THRESH}:`);
  for (const l of loose.slice(0, 60)) console.log(`  ${l.p}: ${l.a} vs ${l.b} (rel ${l.rel.toExponential(2)})`);
}
if (bad.length) {
  console.log(`\n${bad.length} STRUCTURAL / STRING mismatches:`);
  for (const x of bad.slice(0, 60)) console.log(`  ${x.p}:\n    js: ${JSON.stringify(x.a)?.slice(0, 300)}\n    gd: ${JSON.stringify(x.b)?.slice(0, 300)}`);
  process.exit(1);
}
