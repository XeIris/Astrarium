// A scripted browser mission: size the canvas, launch, engage the ascent
// autopilot, run it forward in fixed real-frame steps and snapshot telemetry
// plus a coarse framebuffer render at each checkpoint.
// launchCraft is ASYNC — it awaits this vehicle's authored mesh before it
// builds — so reading f.vessel without awaiting it samples the PREVIOUS
// mission's vessel, or null on the first run.
window.__mission = async function (vehicle, opts) {
  opts = opts || {};
  Object.defineProperty(window, 'innerWidth',  { value: opts.w || 1280, configurable: true });
  Object.defineProperty(window, 'innerHeight', { value: opts.h || 720,  configurable: true });
  window.dispatchEvent(new Event('resize'));
  await SIM.launchCraft(vehicle);
  const f = SIM.flight, v = f.vessel, ap = f.autopilot;
  if (opts.program) ap.engage(opts.program);
  if (opts.cam) f.setCameraMode(opts.cam);
  if (opts.warp != null) f.setWarp(opts.warp);
  const marks = [];
  const every = opts.every || 60;                 // frames between samples
  const total = opts.frames || 1800;
  const dt = opts.dt || 1 / 30;                   // fixed step, so runs repeat
  for (let i = 0; i < total; i++) {
    SIM.frame(dt);
    if (i % every === 0 || i === total - 1) {
      const t = v.telemetry;
      marks.push({
        f: i, met: +v.met.toFixed(1), alt: +(t.alt / 1000).toFixed(2),
        v: +t.speed.toFixed(0), q: +(t.q / 1000).toFixed(1), M: +(t.mach || 0).toFixed(2),
        g: +(t.gees || 0).toFixed(2), thr: +v.throttle.toFixed(2),
        m: +(t.mass / 1000).toFixed(1),
        apo: Number.isFinite(t.apo) ? +(t.apo / 1000).toFixed(0) : 'esc',
        peri: +(t.peri / 1000).toFixed(0), ecc: +(t.ecc || 0).toFixed(4),
        dv: +(t.dv / 1000).toFixed(2), phase: v.phase, st: ap.status.slice(0, 46),
        dt: v.clockDelta,
      });
    }
    if (v.phase === 'destroyed' || v.phase === 'landed') break;
  }
  const art = window.__art(opts.cols || 84, opts.rows || 26, 1);
  return { marks, art: art.art, events: v.events.map(e => `${e.t.toFixed(1)}s ${e.msg}`),
           final: marks[marks.length - 1] };
};
