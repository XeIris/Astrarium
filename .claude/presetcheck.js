// Load EVERY scenario, run frames in each, and report anything that threw or
// came out empty. The cheap standing check that the catalogue still works —
// the course added thirteen presets and changed how contact radii are derived,
// and both of those reach every scenario in the list.
(async function () {
  const SIM = window.SIM;
  const { PRESETS, PRESET_ORDER } = await import('/sim/presets.js');
  const rep = { n: 0, errors: [], rows: [] };
  const onErr = e => rep.errors.push(e.message);
  addEventListener('error', onErr);
  for (const key of PRESET_ORDER) {
    try {
      SIM.load(key);
      const n0 = SIM.state.bodies.length;
      for (let i = 0; i < 60; i++) SIM.frame(1 / 60);
      const n1 = SIM.state.bodies.length;
      rep.rows.push(`${key}: ${n0}->${n1}`);
      if (n1 < n0 && !/merger|feeding|binarystar|zoo/.test(key)) {
        rep.errors.push(`${key}: lost ${n0 - n1} bodies in one second (${PRESETS[key].name})`);
      }
      rep.n++;
    } catch (err) { rep.errors.push(`${key}: THREW ${err.message}`); }
  }
  removeEventListener('error', onErr);
  window.PRESET_REPORT = rep;
  document.title = `PRESETS ${rep.n} ${rep.errors.length}E`;
})();
