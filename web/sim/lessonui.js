import * as THREE from 'three';
import { MODULES, FIGURES, LESSON_ORDER, LESSON_COUNT, findLesson, neighbours, presetsUsed } from './lessons.js';
import { createPhotometer } from './lightcurve.js';
import { createGWDetector } from './gwdetector.js';
import { createHRDiagram } from './hrdiagram.js';
import { createCutaway } from './cutaway.js';

// ============================================================================
// THE COURSE, AS AN INTERFACE
// ----------------------------------------------------------------------------
// sim/lessons.js is data and knows nothing about the page. This file is the
// other half: it renders the course, and it EXECUTES a step's `do` block
// against a small stage API that the orchestrator hands in. The split matters
// more than it looks — it is what stops the curriculum from turning into a
// pile of DOM code, and it means a lesson can ask for something the stage does
// not implement yet and simply not get it, instead of throwing.
//
// TWO SURFACES, ON PURPOSE:
//
//   THE PANEL (left column) is the map. Modules, lessons, what you have done,
//   and how far through you are. It takes the scenario list's slot because in
//   this mode the course IS how you choose what to look at.
//
//   THE CARD (bottom centre) is the lesson itself. It is wide rather than tall
//   because it is prose and prose needs a measure, and it is at the BOTTOM
//   because the thing it is talking about is the thing behind it — a panel
//   over the middle of the screen would be covering the argument.
//
// A step that carries an instrument gets a two-column card: the instrument on
// the left at a fixed 340 px, the text beside it. The instruments are live and
// are driven from the orchestrator's own frame loop through update(), because a
// light curve that only advances when you press Next is a picture of a light
// curve.
//
// PROGRESS IS PER-LESSON AND LIVES IN localStorage. A lesson counts as done
// when its last step has been seen. It is deliberately not a score: there is
// nothing to get wrong here, and the only thing the tick is for is finding
// your way back.
// ============================================================================

const STORE = 'bh.course.v1';

function loadProgress() {
  try {
    const p = JSON.parse(localStorage.getItem(STORE));
    const done = {};
    for (const e of LESSON_ORDER) if (p?.done?.[e.key] === true) done[e.key] = true;
    return { done, last: findLesson(p?.last)?.lesson ? p.last : null };
  }
  catch { return { done: {}, last: null }; }
}
function saveProgress(p) {
  try { localStorage.setItem(STORE, JSON.stringify(p)); } catch { /* private mode */ }
}

export function createLessons({ panel, card, stage }) {
  const progress = loadProgress();
  let key = null;          // 'moduleId/lessonId'
  let stepIx = 0;
  let instrument = null;   // the name the current step asked for
  const open = new Set();  // which module accordions are open

  // Instruments are built once, on first use. A WebGL context (the cutaway) is
  // expensive enough that building all four at boot would be felt.
  const built = {};
  const media = card.querySelector('.lc-media');

  // ---- the curriculum's own consistency check. No test runner exists here, so
  // this is it: a lesson that names a scenario nobody has written is a silent
  // dead end, and a console warning at boot is cheap.
  {
    const missing = presetsUsed().filter(k => !stage.hasPreset(k));
    if (missing.length) console.warn('[course] lessons reference unknown scenarios:', missing.join(', '));
  }

  // =========================================================================
  // THE PANEL
  // =========================================================================
  function renderPanel() {
    const doneCount = Object.keys(progress.done).length;
    const pct = Math.round(100 * doneCount / LESSON_COUNT);
    const cur = key ? findLesson(key) : null;

    panel.innerHTML = `
      <div class="course-progress">
        <div class="cp-bar"><i style="width:${pct}%"></i></div>
        <div class="cp-label">${doneCount} of ${LESSON_COUNT} lessons · ${pct}%</div>
      </div>
      <button class="course-continue" data-continue>${doneCount ? 'Continue' : 'Start the course'}</button>
      <div class="course-mods">
        ${MODULES.map(m => {
          const dn = m.lessons.filter(l => progress.done[`${m.id}/${l.id}`]).length;
          const isOpen = open.has(m.id) || cur?.module.id === m.id;
          return `<details class="course-mod"${isOpen ? ' open' : ''} data-mod="${m.id}">
            <summary>
              <span class="cm-icon">${m.icon}</span>
              <span class="cm-name">${m.title}</span>
              <span class="cm-count">${dn}/${m.lessons.length}</span>
            </summary>
            <div class="cm-blurb">${m.blurb}</div>
            <div class="cm-items">${m.lessons.map(l => {
              const k = `${m.id}/${l.id}`;
              return `<button class="course-lesson${progress.done[k] ? ' done' : ''}${k === key ? ' active' : ''}"
                data-lesson="${k}"><span class="cl-tick">${progress.done[k] ? '✓' : '·'}</span>
                <span class="cl-name">${l.title}</span><span class="cl-mins">${l.mins}m</span></button>`;
            }).join('')}</div>
          </details>`;
        }).join('')}
      </div>
      <button class="course-reset" data-reset>reset progress</button>`;

    panel.querySelectorAll('[data-lesson]').forEach(b =>
      b.addEventListener('click', () => openLesson(b.dataset.lesson)));
    panel.querySelectorAll('.course-mod').forEach(d =>
      d.addEventListener('toggle', () => d.open ? open.add(d.dataset.mod) : open.delete(d.dataset.mod)));
    panel.querySelector('[data-continue]')?.addEventListener('click', resume);
    panel.querySelector('[data-reset]')?.addEventListener('click', () => {
      progress.done = {}; progress.last = null; saveProgress(progress); renderPanel();
    });
  }

  // =========================================================================
  // THE CARD
  // =========================================================================
  function renderCard() {
    const found = key && findLesson(key);
    if (!found) { card.hidden = true; return; }
    const { module: mod, lesson } = found;
    const step = lesson.steps[stepIx];
    const n = lesson.steps.length;
    const nb = neighbours(key);

    card.hidden = false;
    card.classList.toggle('has-media', !!(step.instrument || step.fig));

    card.querySelector('.lc-crumb').textContent = `${mod.title} · ${lesson.title}`;
    card.querySelector('.lc-count').textContent = `${stepIx + 1} / ${n}`;
    card.querySelector('.lc-title').textContent = step.title;

    const parts = [];
    if (stepIx === 0 && lesson.myth) {
      parts.push(`<div class="lc-myth"><b>Commonly believed, and wrong:</b> ${lesson.myth}</div>`);
    }
    parts.push(step.body);
    if (step.look) parts.push(`<div class="lc-look"><b>Look for</b> ${step.look}</div>`);
    if (step.act) parts.push(`<button class="lc-act" data-act>${step.act.label}</button>`);
    card.querySelector('.lc-text').innerHTML = parts.join('');
    card.querySelector('[data-act]')?.addEventListener('click', () => runAct(step.act));

    card.querySelector('.lc-dots').innerHTML = lesson.steps
      .map((_, i) => `<i class="${i === stepIx ? 'on' : i < stepIx ? 'seen' : ''}" data-step="${i}"></i>`).join('');
    card.querySelectorAll('[data-step]').forEach(d =>
      d.addEventListener('click', () => goStep(+d.dataset.step)));

    const back = card.querySelector('[data-back]'), fwd = card.querySelector('[data-next]');
    back.disabled = stepIx === 0 && !nb.prev;
    fwd.textContent = stepIx < n - 1 ? 'Next →' : (nb.next ? 'Next lesson →' : 'Finish');

    setMedia(step);
  }

  // ---- the media column: an instrument, a diagram, or nothing at all
  function setMedia(step) {
    instrument = step.instrument || null;
    built.cutaway?.dispose();
    delete built.cutaway;
    media.innerHTML = '';
    if (step.fig && FIGURES[step.fig]) {
      media.innerHTML = FIGURES[step.fig];
      return;
    }
    if (!instrument) return;

    const wrap = document.createElement('div');
    wrap.className = 'lc-instr';
    const cv = document.createElement('canvas');
    cv.className = 'lc-canvas';
    wrap.appendChild(cv);
    const note = document.createElement('div');
    note.className = 'lc-instr-note';
    wrap.appendChild(note);
    media.appendChild(wrap);

    // A new card owns a new canvas; readings restart with that step’s view.
    if (instrument === 'cutaway') {
      cv.width = 320; cv.height = 210;
      // A WebGLRenderer is bound to one canvas for life and this card builds a
      // fresh one per step, so the cutaway is rebuilt rather than re-parented.
      // The 2D instruments below are rebuilt too, for symmetry and because a
      // rolling buffer that survived a scenario change would be lying anyway.
      built.cutaway?.dispose?.();
      built.cutaway = createCutaway({ canvas: cv });
      note.innerHTML = '<div class="cut-legend"></div>';
    } else {
      cv.width = 340; cv.height = instrument === 'hr' ? 260 : 210;
      if (instrument === 'photometer') {
        built.photometer = createPhotometer({ canvas: cv });
        note.textContent = '';
      } else if (instrument === 'gw') {
        built.gw = createGWDetector({ canvas: cv, distMpc: 410 });
        note.textContent = 'rescaled inspiral · ideal orientation at 410 Mpc · arm motion exaggerated';
      } else if (instrument === 'hr') {
        built.hr = createHRDiagram({ canvas: cv });
        note.textContent = 'the band is sampled from the interior model, not drawn';
      }
    }
    mediaNote = note;
  }
  let mediaNote = null;

  // =========================================================================
  // EXECUTING A STEP
  // =========================================================================
  function applyDo(d) {
    if (!d) return;
    // Order matters and is not arbitrary. Loading a scenario resets the camera
    // and the focus, so anything that sets either must come after it; and
    // following a body reframes the view, so an explicit radius must come
    // after THAT. Getting this order wrong is invisible on the first frame and
    // obvious by the second.
    if (d.preset && stage.currentPreset() !== d.preset) stage.loadPreset(d.preset);
    // The curvature grid is OFF in the course unless a lesson asks for it. It
    // is a good picture of one specific idea and unexplained scenery in every
    // other lesson, and several scenarios switch it on by default — so the
    // course states what it wants rather than inheriting it.
    stage.setMesh(!!d.mesh);
    if (d.sky) stage.setSky(d.sky);
    if (d.trueScale !== undefined) stage.setTrueScale(d.trueScale);

    if (d.paused !== undefined) stage.setPaused(d.paused);
    if (d.focus) stage.setFocus(d.focus);
    if (d.cam) stage.setCam(d.cam);
    // Entering surface mode chooses a default pace; the lesson overrides it.
    if (d.timeScale !== undefined) stage.setTimeScale(d.timeScale);
    if (d.band !== undefined) stage.setBand(d.band);
    if (d.control) for (const [id, v] of Object.entries(d.control)) stage.setControl(id, v);
    // AFTER the controls, not before: `control: { lat: 66 }` moves the observer
    // to the Arctic Circle, and where noon is depends on the latitude it is
    // being asked about. Setting the time first put the Sun overhead for a
    // place the lesson was about to stop standing in.
    if (d.localTime !== undefined) stage.setLocalTime(d.localTime);
    if (d.panel) for (const [id, v] of Object.entries(d.panel)) stage.setPanel(id, v);
    if (d.flare) stage.flare(d.flare);
    if (d.collapse) stage.collapse(d.collapse);
    // A fresh scenario invalidates whatever the instruments had collected.
    built.photometer?.reset();
    built.gw?.reset();
  }

  function runAct(act) {
    if (!act) return;
    if (act.collapse) stage.collapse(act.collapse);
    if (act.flare) stage.flare(act.flare);
    if (act.preset) stage.loadPreset(act.preset);
  }

  // =========================================================================
  // NAVIGATION
  // =========================================================================
  function openLesson(k, step = 0) {
    const found = findLesson(k);
    if (!found) return;
    key = k; stepIx = -1;
    progress.last = k; saveProgress(progress);
    goStep(step);
    renderPanel();
  }

  function goStep(i) {
    const found = findLesson(key);
    if (!found) return;
    const target = Math.max(0, Math.min(i, found.lesson.steps.length - 1));
    // Forward steps preserve a running experiment. Back, dots and direct links
    // reconstruct its prerequisites, since each do block is only a patch.
    if (stepIx < 0 || target !== stepIx + 1) {
      const initial = found.lesson.steps[0].do?.preset || 'edu_galaxy';
      stage.loadPreset(initial);
      stage.setBand(3);
      stage.setPaused(false);
      stage.setControl('speed', 1);
      stage.setControl('lat', 22);
      stage.setPanel('xsecPanel', false);
      stage.setPanel('coursePanel', true);
      for (let j = 0; j <= target; j++) applyDo(found.lesson.steps[j].do);
    } else applyDo(found.lesson.steps[target].do);
    stepIx = target;
    renderCard();
    if (stepIx === found.lesson.steps.length - 1 && !progress.done[key]) {
      progress.done[key] = true; saveProgress(progress); renderPanel();
    }
  }

  function next() {
    const found = findLesson(key);
    if (!found) return;
    if (stepIx < found.lesson.steps.length - 1) return goStep(stepIx + 1);
    const nb = neighbours(key);
    if (nb.next) openLesson(nb.next);
    else { stage.toast('That is the end of the course. Everything in it is still in the sandbox.'); close(); }
  }

  function prev() {
    if (stepIx > 0) return goStep(stepIx - 1);
    const nb = neighbours(key);
    if (nb.prev) {
      const f = findLesson(nb.prev);
      openLesson(nb.prev, f.lesson.steps.length - 1);
    }
  }

  function close() {
    key = null; instrument = null; card.hidden = true;
    built.cutaway?.dispose(); delete built.cutaway;
    renderPanel();
  }

  // Where the course picks up. The lesson you were last on if you did not
  // finish it, otherwise the first one you have not done, otherwise the start.
  function resume() {
    const unfinished = progress.last && !progress.done[progress.last] ? progress.last : null;
    const nextUp = LESSON_ORDER.find(e => !progress.done[e.key]) || LESSON_ORDER[0];
    openLesson(unfinished || nextUp.key);
  }

  card.querySelector('[data-next]')?.addEventListener('click', next);
  card.querySelector('[data-back]')?.addEventListener('click', prev);
  card.querySelector('[data-close-card]')?.addEventListener('click', close);

  // =========================================================================
  // THE FRAME HOOK — the instruments are live, and have to be
  // =========================================================================
  const _u = new THREE.Vector3(), _c = new THREE.Vector3();
  function update(dt) {
    if (!instrument || card.hidden) return;
    const bodies = stage.bodies();

    if (instrument === 'photometer' && built.photometer) {
      // The observer is the camera — see the header of sim/lightcurve.js for
      // why that is the lesson rather than a shortcut. The camera lives in
      // scene units and the bodies in AU, so it is converted rather than
      // compared.
      const s = stage.sceneScale() || 1;
      _c.copy(stage.camera.position).divideScalar(s);
      const star = bodies.find(b => b.luminosity > 0) || null;
      _u.copy(_c);
      if (star) _u.sub(star.pos);
      if (_u.lengthSq() < 1e-18) _u.set(0, 0, 1);
      _u.normalize();
      const m = built.photometer.sample(bodies, _u, stage.simYears());
      built.photometer.draw();
      if (mediaNote) {
        const d = built.photometer.depthPPM, a = built.photometer.amplitude;
        mediaNote.textContent =
          `deepest dip ${d} ppm · RV swing ±${a < 1 ? a.toFixed(2) : a.toFixed(1)} m/s`
          + (m.events.length ? ' · TRANSIT NOW' : '');
      }
    } else if (instrument === 'gw' && built.gw) {
      built.gw.sample(bodies);
      built.gw.draw();
    } else if (instrument === 'hr' && built.hr) {
      built.hr.draw(bodies);
    } else if (instrument === 'cutaway' && built.cutaway) {
      const b = stage.focusBody() || bodies.find(x => x.structure);
      const st = b?.structure;
      if (st && st !== built.cutaway.structure) {
        built.cutaway.show(st);
        const leg = media.querySelector('.cut-legend');
        if (leg) leg.innerHTML = built.cutaway.legend();
      }
      built.cutaway.render(dt);
    }
  }

  renderPanel();
  card.hidden = true;

  return {
    update, renderPanel, openLesson, close, next, prev, resume,
    get active() { return !!key; },
    get lessonKey() { return key; },
  };
}
