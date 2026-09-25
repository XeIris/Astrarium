// Finds float literals in .gd files that Godot parses to a different double
// than IEEE round-to-nearest (see literalcheck.gd for why that happens).
//   node godot/tools/literalcheck.mjs godot/sim/*.gd
// Prints each mis-parsed literal with the value Godot gets, the correct one,
// and the ULP distance. Exit code 1 if any.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const here = path.dirname(fileURLToPath(import.meta.url));
const files = process.argv.slice(2);
const seen = new Map();   // literal → [file:line]
const re = /(?<![\w.#"])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+|\.\d+(?:[eE][+-]?\d+)?)(?![\w.])/g;
for (const f of files) {
  readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
    const code = line.replace(/#.*$/, '').replace(/"(?:[^"\\]|\\.)*"/g, '""');
    for (const m of code.matchAll(re)) {
      const l = m[1];
      if (!seen.has(l)) seen.set(l, []);
      seen.get(l).push(`${path.basename(f)}:${i + 1}`);
    }
  });
}
const lits = [...seen.keys()];
const dir = mkdtempSync(path.join(os.tmpdir(), 'lit-'));
writeFileSync(path.join(dir, 'in.json'), JSON.stringify(lits));
const godot = process.env.GODOT || '/Applications/Godot.app/Contents/MacOS/Godot';
execFileSync(godot, ['--headless', '--quit-after', '100', '--path', path.join(here, '..'), '--script', 'res://tools/literalcheck.gd', '--',
  `in=${path.join(dir, 'in.json')}`, `out=${path.join(dir, 'out.json')}`], { stdio: 'ignore' });
const got = JSON.parse(readFileSync(path.join(dir, 'out.json'), 'utf8'));
const bits = (x) => { const b = Buffer.alloc(8); b.writeDoubleLE(x); return b; };
let bad = 0;
lits.forEach((l, i) => {
  const want = Number(l);
  const g = Buffer.from(got[i], 'hex');
  if (!g.equals(bits(want))) {
    bad++;
    const ulp = Number(g.readBigInt64LE() - bits(want).readBigInt64LE());
    console.log(`${l.padEnd(24)} godot ${g.readDoubleLE().toPrecision(17)}  ieee ${want.toPrecision(17)}  (${ulp > 0 ? '+' : ''}${ulp} ulp)  ${seen.get(l).slice(0, 4).join(', ')}`);
  }
});
console.log(`${lits.length} distinct float literals, ${bad} mis-parsed by Godot`);
process.exit(bad ? 1 : 0);
