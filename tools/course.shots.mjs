// The course's web reference shot list, for tools/webref.mjs:
//
//   node tools/course.shots.mjs > /tmp/course/shots.json
//   PORT=8805 WEB_ROOT=<checkout with assets> node tools/webref.mjs /tmp/course/shots.json /tmp/course/web
//
// Each UI shot resets the progress, opens a lesson, presses Next `n` times and
// pumps `frames` fixed frames — tools/coursetest.tscn does the same with
// the same arguments (see coursetest.sh). Two more write FIXTURES rather than
// pictures: `instruments` (course_instruments.dump.js — the instruments'
// outputs on frozen body states) and `science` (.claude/sciencecheck.js's own
// report), which tools/sciencecheck.gd checks against.
import { readFileSync } from 'node:fs';

export const SHOTS = [
  ['seasons', 'sky/seasons', 0, 30],
  ['phases', 'sky/phases', 1, 30],
  ['kepler', 'gravity/ellipse', 2, 30],
  ['spectrum', 'light/spectrum', 0, 30],
  ['binding', 'stars/sun', 1, 30],
  ['parallax', 'stars/distances', 0, 30],
  ['hr', 'stars/hr', 0, 30],
  ['hrzoo', 'stars/hr', 2, 30],
  ['pulsar', 'lives/neutron', 0, 30],
  ['supernova', 'lives/supernova', 2, 30],
  ['shadow', 'holes/shadow', 0, 30],
  ['gw', 'holes/gw', 0, 180],
  ['transit', 'worlds/transit', 1, 240],
  ['wobble', 'worlds/wobble', 0, 240],
];

// The card's rect and instrument note, plus the LIVE numbers at the moment of
// capture: simulated time, and what gwdetector.js reads off the binary on
// screen right now (the chart's own history is not reachable from outside).
const uiDump = `
  const r = e => { if (!e) return null; const b = e.getBoundingClientRect(); return [b.x, b.y, b.width, b.height]; };
  const g = await import('/sim/gwdetector.js');
  const s = g.strainOf(g.findBinary(SIM.state.bodies));
  return { lesson: SIM.lessons.lessonKey, preset: SIM.state.presetKey, simYears: SIM.state.simYears,
    card: r(document.getElementById('lessonCard')), panel: r(document.getElementById('coursePanel')),
    note: document.querySelector('.lc-instr-note')?.textContent ?? null,
    strain: s && { fGW: s.fGW, h0: s.h0, Mc: s.Mc, rSchwarz: s.rSchwarz } };`;

const here = new URL('.', import.meta.url);
if (import.meta.url === `file://${process.argv[1]}`) {
  const shots = SHOTS.map(([name, key, n, frames]) => ({
    // Sandbox first, then Learn from the setup: localStorage survives from shot
    // to shot, and entering Learn RESUMES the course, so the progress is reset
    // before the mode is entered — a fresh learner, as coursetest.gd makes.
    name, mode: 'sandbox', hud: true, freeze: true, frames,
    setup: `document.querySelector('[data-reset]')?.click(); SIM.setAppMode('learn'); SIM.lessons.openLesson('${key}'); for (let i = 0; i < ${n}; i++) SIM.lessons.next();`,
    dump: uiDump,
  }));
  shots.push({ name: 'instruments', mode: 'sandbox', frames: 0, dump: readFileSync(new URL('course_instruments.dump.js', here), 'utf8') });
  shots.push({ name: 'science', mode: 'sandbox', frames: 0,
    setup: `const s = document.createElement('script'); s.src = '/.claude/sciencecheck.js'; document.body.appendChild(s);
            for (let i = 0; i < 600 && !window.SCIENCE_REPORT; i++) await new Promise(r => setTimeout(r, 200));`,
    dump: 'return window.SCIENCE_REPORT;' });
  console.log(JSON.stringify(shots, null, 1));
}
