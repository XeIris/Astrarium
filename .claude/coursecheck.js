// ============================================================================
// COURSE WALK — the regression check for the education mode
// ----------------------------------------------------------------------------
// There is no test runner in this repo, so this is it: inject it into the page
// and it opens EVERY lesson, steps through EVERY step, runs a frame at each
// one, and reports anything that threw, any scenario that came up empty when
// it should not have, and any body a lesson asked to focus on that does not
// exist in the scenario it opened.
//
// That last check is the one worth having. A lesson naming `focus: 'Sol'` in a
// scenario whose star is called 'Sun' fails silently — the camera simply does
// not move — and it is invisible in a screenshot.
//
// Usage, from the browser tools (page globals are not visible to an isolated
// world, so it has to be injected as a script element):
//
//   const s = document.createElement('script');
//   s.src = '/.claude/coursecheck.js';
//   document.body.appendChild(s);
//   // then read window.COURSE_REPORT
// ============================================================================
(async function () {
  const SIM = window.SIM;
  const report = { steps: 0, lessons: 0, errors: [], warnings: [] };
  const onErr = e => report.errors.push(`${e.message} @ ${e.filename}:${e.lineno}`);
  addEventListener('error', onErr);
  const origWarn = console.warn;
  console.warn = (...a) => { report.warnings.push(a.join(' ')); origWarn(...a); };

  const { MODULES } = await import('/sim/lessons.js');
  SIM.setAppMode('learn', { quiet: true });

  for (const mod of MODULES) {
    for (const lesson of mod.lessons) {
      const key = `${mod.id}/${lesson.id}`;
      report.lessons++;
      // Walked IN ORDER with next(), not jumped to. A step's `do` block is a
      // patch on whatever the previous step left behind — "same scenario,
      // closer camera" is the normal case — so checking a step in isolation
      // would be checking something no learner ever sees.
      SIM.lessons.openLesson(key);
      for (let i = 0; i < lesson.steps.length; i++) {
        const step = lesson.steps[i];
        const where = `${key}#${i + 1} "${step.title}"`;
        try {
          if (i > 0) SIM.lessons.next();
          SIM.frame(1 / 60);
          SIM.frame(1 / 60);
          report.steps++;

          const d = step.do || {};
          if (d.preset && SIM.state.presetKey !== d.preset) {
            report.errors.push(`${where}: asked for scenario "${d.preset}", got "${SIM.state.presetKey}"`);
          }
          if (d.focus) {
            const b = SIM.state.bodies.find(x => x.name === d.focus);
            if (!b) report.errors.push(`${where}: no body named "${d.focus}" in ${SIM.state.presetKey}`);
            else if (SIM.state.focusId !== b.id) report.errors.push(`${where}: focus did not take`);
            // Is the camera actually OUTSIDE the thing the lesson is pointing
            // at? A viewing distance written for one size convention puts the
            // camera inside the planet under the other, and the symptom is a
            // screen of flat colour that looks like a shader bug.
            else if (SIM.state.camMode === 'orbit' && SIM.cam.radius < b.radiusScene * 1.15) {
              report.errors.push(`${where}: camera at ${SIM.cam.radius.toExponential(2)} is inside ${d.focus} (drawn radius ${b.radiusScene.toExponential(2)})`);
            }
          }
          if (step.act?.collapse && !SIM.state.bodies.some(x => x.name === step.act.collapse)) {
            report.errors.push(`${where}: act targets missing body "${step.act.collapse}"`);
          }
          if (d.control) {
            for (const id of Object.keys(d.control)) {
              if (!document.getElementById(id)) report.errors.push(`${where}: no control "${id}"`);
            }
          }
          if (d.panel) {
            for (const id of Object.keys(d.panel)) {
              if (!document.getElementById(id)) report.errors.push(`${where}: no panel "${id}"`);
            }
          }
          if (d.preset && d.preset !== 'edu_galaxy' && d.preset !== 'edu_cluster'
              && d.preset !== 'blank' && SIM.state.bodies.length === 0) {
            report.errors.push(`${where}: scenario "${d.preset}" built no bodies`);
          }
        } catch (err) {
          report.errors.push(`${where}: THREW ${err.message}`);
        }
      }
    }
  }
  console.warn = origWarn;
  removeEventListener('error', onErr);
  report.ok = report.errors.length === 0;
  window.COURSE_REPORT = report;
  document.title = `COURSE ${report.lessons}L ${report.steps}S ${report.errors.length}E`;
})();
