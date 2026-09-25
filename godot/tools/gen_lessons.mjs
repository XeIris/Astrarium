// Generates godot/sim/lessons.gd from sim/lessons.js: the header comment is
// carried over verbatim (// → #), the data is serialised as GDScript literals
// with the JS keys verbatim. Run from the worktree root:
//   node godot/tools/gen_lessons.mjs > godot/sim/lessons.gd
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const src = readFileSync('sim/lessons.js', 'utf8').split('\n');
const L = await import(pathToFileURL(resolve('sim/lessons.js')).href);

// header: lines up to the first line that is not a comment
const header = [];
for (const ln of src) { if (!ln.startsWith('//')) break; header.push(ln); }
const figComment = [];
{
  const i = src.findIndex(l => l.startsWith('// FIGURES'));
  for (let j = i - 1; j < src.length && src[j].startsWith('//'); j++) figComment.push(src[j]);
}
const cm = s => s.replace(/^\/\/ ?/, '# ').replace(/^# $/, '#').replace(/=+$/, m => m).replace(/^# (-+|=+)$/, (m, d) => '# ' + d);

function str(s) {
  if (s.includes('\n')) {
    if (s.includes('"""') || s.includes('\\')) throw new Error('cannot triple-quote: ' + s.slice(0, 40));
    return '"""' + s + '"""';
  }
  return JSON.stringify(s);
}
function val(v, ind) {
  const pad = '\t'.repeat(ind);
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'string') return str(v);
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(v);
  if (typeof v === 'boolean') return String(v);
  if (Array.isArray(v)) {
    if (!v.length) return '[]';
    return '[\n' + v.map(x => pad + '\t' + val(x, ind + 1) + ',').join('\n') + '\n' + pad + ']';
  }
  const ks = Object.keys(v);
  if (!ks.length) return '{}';
  // small flat objects (do-blocks, cam, control) on one line, as the JS has them
  const flat = ks.every(k => typeof v[k] !== 'object' || v[k] === null || (!Array.isArray(v[k]) && Object.values(v[k]).every(x => typeof x !== 'object')));
  const inline = ks.map(k => JSON.stringify(k) + ': ' + val(v[k], ind + 1)).join(', ');
  if (flat && !inline.includes('\n') && inline.length < 110) return '{' + inline + '}';
  return '{\n' + ks.map(k => pad + '\t' + JSON.stringify(k) + ': ' + val(v[k], ind + 1) + ',').join('\n') + '\n' + pad + '}';
}

const out = [];
out.push('class_name Lessons');
out.push('extends RefCounted');
out.push('');
for (const h of header) out.push(cm(h)
  .replace('sim/lessonui.js executes it against', 'sim/lessonui.gd executes it against')
  .replace('sim/lessonui.js executes', 'sim/lessonui.gd executes')
  .replace('(see sim/presets.js and sim/edupresets.js)', '(see sim/presets.gd and sim/edupresets.gd)')
  .replace('(see sim/spectrum.js BANDS)', '(see sim/spectrum.gd BANDS)'));
out.push('#');
out.push('# THE PORT. This file is generated from sim/lessons.js and holds the same');
out.push('# data as Dictionaries with the JS keys VERBATIM (camelCase and all), because');
out.push('# the course is data that the executor reads by key. Text is text: every body');
out.push('# is the same HTML fragment the web build set as innerHTML, and');
out.push('# sim/lessonui.gd interprets the handful of tags it uses (<p>, <em>, <strong>,');
out.push('# <kbd>, and the <b> of the myth and look-for boxes). Integers stay integers');
out.push('# (a band index is an index); the executor converts where a number is a scale.');
out.push('# ============================================================================');
out.push('');
out.push('# The web build wrapped every figure with');
out.push('#   svg(viewBox, inner) = `<svg viewBox="${viewBox}" class="lfig" ...>${inner}</svg>`');
out.push('# and built the repetitive ones (the ladder rungs, the redshift strips, the');
out.push('# spectrum ticks) with .map().join(). What is stored here is the expanded');
out.push('# result, character for character; sim/lessonui.gd rasterises the shapes and');
out.push('# sets the <text> itself (Godot\'s SVG loader has no text).');
for (const h of figComment) out.push(cm(h));
out.push('const FIGURES := {');
for (const [k, v] of Object.entries(L.FIGURES)) out.push('\t' + JSON.stringify(k) + ': ' + str(v) + ',');
out.push('}');
out.push('');
out.push('# ============================================================================');
out.push('# THE MODULES');
out.push('# ============================================================================');
out.push('const MODULES := [');
for (const m of L.MODULES) {
  out.push('');
  out.push('# ---------------------------------------------------------------------------');
  out.push('{');
  for (const k of Object.keys(m)) {
    if (k === 'lessons') continue;
    out.push('\t' + JSON.stringify(k) + ': ' + val(m[k], 1) + ',');
  }
  out.push('\t"lessons": [');
  for (const l of m.lessons) {
    out.push('');
    out.push('\t{');
    for (const k of Object.keys(l)) {
      if (k === 'steps') continue;
      out.push('\t\t' + JSON.stringify(k) + ': ' + val(l[k], 2) + ',');
    }
    out.push('\t\t"steps": [');
    for (const s of l.steps) {
      out.push('\t\t\t{');
      for (const k of Object.keys(s)) out.push('\t\t\t\t' + JSON.stringify(k) + ': ' + val(s[k], 4) + ',');
      out.push('\t\t\t},');
    }
    out.push('\t\t],');
    out.push('\t},');
  }
  out.push('\t],');
  out.push('},');
}
out.push(']');
out.push(`
# ---------------------------------------------------------------------------
# The course as a flat, ordered list. Two ways through it are both first-class:
# straight down the line, and jumping to whatever you came for. The linear
# order is what "next" means and what the progress bar measures; the module
# list is what makes jumping possible. Neither is the "real" one.
# ---------------------------------------------------------------------------
static var LESSON_ORDER: Array = _order()
static var LESSON_COUNT: int = LESSON_ORDER.size()
static var STEP_COUNT: int = _step_count()

static func _order() -> Array:
	var out: Array = []
	for m in MODULES:
		for l in m.lessons:
			out.append({"moduleId": m.id, "lessonId": l.id, "key": "%s/%s" % [m.id, l.id]})
	return out

static func _step_count() -> int:
	var n := 0
	for m in MODULES:
		for l in m.lessons:
			n += l.steps.size()
	return n

## { module, lesson, key } for "moduleId/lessonId", or null.
static func find_lesson(key) -> Variant:
	var parts := str(key if key != null else "").split("/")
	var mid := parts[0]
	var lid := parts[1] if parts.size() > 1 else ""
	for m in MODULES:
		if m.id != mid: continue
		for l in m.lessons:
			if l.id == lid:
				return {"module": m, "lesson": l, "key": key}
		return null
	return null

static func neighbours(key) -> Dictionary:
	var i := -1
	for j in LESSON_ORDER.size():
		if LESSON_ORDER[j].key == key:
			i = j
			break
	return {
		"index": i,
		"prev": LESSON_ORDER[i - 1].key if i > 0 else null,
		"next": LESSON_ORDER[i + 1].key if i >= 0 and i < LESSON_ORDER.size() - 1 else null,
	}

# Every scenario key the course asks for, so a start-up check can prove the
# curriculum and the preset catalogue have not drifted apart. There is no test
# runner here; this is the next best thing, and sim/lessonui.gd runs it once.
static func presets_used() -> Array:
	var seen := {}
	var out: Array = []
	for m in MODULES:
		for l in m.lessons:
			for s in l.steps:
				var d = s.get("do")
				if d is Dictionary and d.get("preset") and not seen.has(d.preset):
					seen[d.preset] = true
					out.append(d.preset)
	return out`);
console.log(out.join('\n'));
