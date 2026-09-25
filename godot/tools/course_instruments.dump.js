// Fixture for godot/tools/sciencecheck.gd: the web instruments' own outputs on
// frozen body states, so the Godot port can be checked to rounding on the SAME
// input (a live comparison drifts: the page's requestAnimationFrame keeps
// integrating between a screenshot and a dump). Used as the `dump` of a
// webref.mjs shot (see godot/tools/course.shots.json); a function body.
const { measure } = await import('/sim/lightcurve.js');
const g = await import('/sim/gwdetector.js');
const { Vector3 } = await import('three');
SIM.state.paused = true;
const ser = bs => bs.map(b => ({ name: b.name, type: b.type, mass: b.mass, radius: b.radius, rs: b.rs || 0,
  contactAU: b.contactAU || 0, luminosity: b.luminosity ?? null, alive: b.alive !== false,
  pos: [b.pos.x, b.pos.y, b.pos.z], vel: [b.vel.x, b.vel.y, b.vel.z] }));
const out = {};
const dirs = [[0, 0, 1], [0.3, 0.1, 0.95], [0, 1, 0], [1, 0.02, 0], [-0.7, 0.05, 0.7]];
for (const key of ['edu_transit', 'alphacen', 'sirius']) {
  SIM.load(key);
  // move the planet onto the line of sight for a transit, whatever the phase
  const bodies = SIM.state.bodies;
  const rows = dirs.map(d => {
    const u = new Vector3(...d).normalize();
    const m = measure(bodies, u);
    return { u: [u.x, u.y, u.z], rel: m.rel, flux: m.flux, total: m.total, rv: m.rv, events: m.events.length,
      depths: m.events.map(e => e.depth ?? null) };
  });
  // and a direction straight through each non-star body from its star, so every
  // scenario has an in-transit case in the fixture
  const star = bodies.find(b => b.luminosity > 0);
  for (const p of bodies) {
    if (p === star) continue;
    const u = p.pos.clone().sub(star.pos).normalize();
    const u2 = u.clone().add(new Vector3(0, p.radius * 0.5 / p.pos.distanceTo(star.pos), 0)).normalize();
    for (const uu of [u, u2]) {
      const m = measure(bodies, uu);
      rows.push({ u: [uu.x, uu.y, uu.z], rel: m.rel, flux: m.flux, total: m.total, rv: m.rv, events: m.events.length,
        depths: m.events.map(e => e.depth ?? null) });
    }
  }
  out[key] = { bodies: ser(bodies), rows };
}
for (const key of ['bhmerger', 'nsmerger']) {
  SIM.load(key);
  const pair = g.findBinary(SIM.state.bodies);
  out[key] = { bodies: ser(SIM.state.bodies), pair: pair ? [pair.a.name, pair.b.name] : null,
    s410: g.strainOf(pair), s40i: g.strainOf(pair, { distMpc: 40, incl: 0.5 }) };
}
return out;
