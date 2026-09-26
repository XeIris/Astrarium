// Long-run numerical check for the same preset builders and integrator used by
// the renderer. It runs as an Electron renderer script so the CDN importmap
// supplies the production Three.js module without adding a Node dependency.
(async () => {
  const THREE = await import('three');
  const { PRESETS } = await import('/sim/presets.js');
  const PHYS = await import('/sim/physics.js');
  const { physicalRadiusAU } = await import('/sim/scale.js');
  const { radiusSun } = await import('/sim/stellar.js');

  const keys = ['trisolaris', 'trisolaris_compact', 'trisolaris_wide', 'trisolaris_alpha'];
  const years = 60000;
  const defaults = { star: 1.0, world: 3e-6 };

  // Match the production spawn path closely enough that the force field sees
  // the same radii and the same collision footprint as the live scene.
  function makeBodies(key) {
    const preset = PRESETS[key];
    const specs = preset.build();
    return specs.map(spec => {
      const mass = spec.mass ?? defaults[spec.type] ?? 1;
      const b = {
        type: spec.type, name: spec.name, mass,
        pos: new THREE.Vector3(...(spec.pos || [0, 0, 0])),
        vel: new THREE.Vector3(...(spec.vel || [0, 0, 0])),
        acc: new THREE.Vector3(), alive: true,
      };
      if (spec.type === 'star') b.radius = PHYS.stellarRadius(mass);
      else b.radius = physicalRadiusAU(spec.type, mass, spec.radiusKm);

      const base = spec.type === 'star' ? 0.34 * radiusSun(mass)
        : spec.type === 'world' ? 0.13 : 0.15;
      const radiusScene = b.radius * preset.sceneScale;
      const boostedScene = base * (preset.bodyScale ?? 1);
      // honour a spec's explicit physical destruction distance, exactly as
      // attachVisual() does in the renderer
      b.contactAU = spec.contactAU
        ?? (preset.trueScale ? radiusScene : boostedScene) / preset.sceneScale;
      return b;
    });
  }

  function dynamicStep(bodies, maxStep) {
    let tMin = maxStep;
    for (let i = 0; i < bodies.length; i++) {
      if (!bodies[i].alive) continue;
      for (let j = i + 1; j < bodies.length; j++) {
        if (!bodies[j].alive) continue;
        const sep = bodies[i].pos.distanceTo(bodies[j].pos);
        const mu = PHYS.G * (bodies[i].mass + bodies[j].mass);
        const tFall = Math.sqrt((sep * sep * sep) / Math.max(mu, 1e-9));
        const vrel = bodies[i].vel.distanceTo(bodies[j].vel);
        const tFly = sep / Math.max(vrel, 1e-6);
        tMin = Math.min(tMin, 0.05 * tFall, 0.08 * tFly);
      }
    }
    return Math.max(tMin, 1e-8);
  }

  function energy(bodies) {
    let e = 0;
    for (const b of bodies) e += 0.5 * b.mass * b.vel.lengthSq();
    for (let i = 0; i < bodies.length; i++) {
      for (let j = i + 1; j < bodies.length; j++) {
        const d = bodies[i].pos.distanceTo(bodies[j].pos);
        e -= PHYS.G * bodies[i].mass * bodies[j].mass / d;
      }
    }
    return e;
  }

  const centreOfMass = bodies => {
    const p = new THREE.Vector3();
    let m = 0;
    for (const b of bodies) { p.addScaledVector(b.pos, b.mass); m += b.mass; }
    return p.multiplyScalar(1 / m);
  };

  function run(key) {
    const preset = PRESETS[key];
    const bodies = makeBodies(key);
    const world = bodies.find(b => b.name === 'Trisolaris');
    const alpha = bodies.find(b => b.name === 'Alpha');
    const beta = bodies.find(b => b.name === 'Beta');
    const gamma = bodies.find(b => b.name === 'Gamma');
    const circumbinary = key !== 'trisolaris_alpha';
    const worldLimit = circumbinary ? 10 : 3;
    const pair = [alpha, beta];
    const initialEnergy = energy(bodies);
    let minSeparation = Infinity;
    let maxWorldRadius = 0;
    let maxOuterRadius = 0;
    let integrated = 0;
    let substeps = 0;
    let failure = null;

    while (integrated < years - 1e-12 && !failure) {
      const h = Math.min(years - integrated, dynamicStep(bodies, preset.maxStep ?? 5e-3));
      PHYS.integrate(bodies, h);
      const events = PHYS.resolveCollisions(bodies);
      if (events.length) failure = `collision at ${integrated.toFixed(3)} yr`;
      integrated += h;
      substeps++;

      if ((substeps & 4095) === 0 || integrated >= years - 1e-12) {
        const reference = circumbinary ? centreOfMass(pair) : alpha.pos;
        const worldRadius = world.pos.distanceTo(reference);
        const inner = centreOfMass([alpha, beta, ...(circumbinary ? [] : [world])]);
        const outerRadius = gamma.pos.distanceTo(inner);
        maxWorldRadius = Math.max(maxWorldRadius, worldRadius);
        maxOuterRadius = Math.max(maxOuterRadius, outerRadius);
        for (let i = 0; i < bodies.length; i++) {
          for (let j = i + 1; j < bodies.length; j++) {
            minSeparation = Math.min(minSeparation, bodies[i].pos.distanceTo(bodies[j].pos));
          }
        }
        if (!Number.isFinite(worldRadius) || !Number.isFinite(outerRadius)) failure = `non-finite state at ${integrated.toFixed(3)} yr`;
        else if (worldRadius > worldLimit) failure = `world escaped at ${integrated.toFixed(3)} yr`;
      }
    }

    const drift = (energy(bodies) - initialEnergy) / Math.abs(initialEnergy);
    // This is intentionally looser than the bounded-orbit checks: the live
    // force field uses source-sized softening, so the simple Newtonian energy
    // diagnostic is a warning signal rather than an exact invariant.
    if (!Number.isFinite(drift) || Math.abs(drift) > 1e-4) {
      failure = failure || `energy drift exceeded tolerance at ${integrated.toFixed(3)} yr`;
    }
    return {
      key, years: integrated, passed: !failure,
      minSeparation, maxWorldRadius, maxOuterRadius,
      relativeEnergyDrift: drift, substeps, failure,
    };
  }

  return { years, results: keys.map(run) };
})()
