// ============================================================================
// STATE DUMP for tools/startest.gd — evaluated in the web page (webref.mjs
// `dump`) right after the reference frame is captured. It writes out exactly
// what that frame was drawn from: the camera, every body's visual inputs (the
// opts attachVisual built), the live activity state (regions, flares, CMEs),
// every shader clock, the markers, the flash sprites and the spacetime slab.
// The Godot harness rebuilds the same frame from it, so a difference in the
// picture is a difference in the port, not in random state.
// ============================================================================
const S = SIM.state, cam = SIM.camera;
const st = await import('/sim/structure.js');
const PH = await import('/sim/physics.js');
const col = c => (c && c.isColor) ? [c.r, c.g, c.b] : null;
const arr = v => (v && v.toArray) ? v.toArray() : v;
const out = {
  time: S.time, band: S.band, sceneScale: S.sceneScale, trueScale: S.trueScale,
  cam: { pos: cam.position.toArray(), quat: cam.quaternion.toArray(), fov: cam.fov, near: cam.near, far: cam.far },
  viewport: [innerWidth, innerHeight], focusId: S.focusId, pre: window.__pre ?? null,
  bodies: [], sprites: [], mesh: null, sceneMaxT: 0,
};
for (const b of S.bodies) {
  if (b.type === 'star' || b.type === 'white-dwarf') out.sceneMaxT = Math.max(out.sceneMaxT, b.teff ?? 0);
  else if (b.type === 'neutron') out.sceneMaxT = Math.max(out.sceneMaxT, 1.0e6);
  else if (b.type === 'bh') out.sceneMaxT = Math.max(out.sceneMaxT, 2.0e7 * Math.pow(Math.max(b.mass, 0.1), -0.25));
  const v = b.viz, spec = b.spec || {}, def = b.def || {};
  const e = {
    id: b.id, name: b.name, type: b.type, mass: b.mass, mass0: b.mass0, radius: b.radius, rs: b.rs ?? 0,
    teff: b.teff ?? null, spinFrac: b.spinFrac ?? 0, radiusSun: b.radiusSun ?? null, spin: b.spin ?? null,
    radiusScene: b.radiusScene, rsScene: b.rsScene ?? 0,
    pos: v.group.position.toArray(), scale: v.group.scale.toArray(),
  };
  const isStarLike = b.type === 'star' || b.type === 'white-dwarf';
  const gd = (isStarLike && b.teff) ? st.gravityDarkenedTemps(b.teff, b.spinFrac ?? 0) : null;
  const fl = b.structure?.flattening;
  e.opts = {
    radiusScene: b.radiusScene, oblate: fl ? 1 / (1 - fl) : 1, spinFrac: b.spinFrac ?? 0,
    tPole: gd?.tPole ?? null, tEq: gd?.tEq ?? null, gdBeta: gd?.beta ?? null,
    radiusSun: b.radiusSun ?? (b.radius ? b.radius / PH.AU_PER_RSUN : null),
    color: (isStarLike && v.mat) ? col(v.mat.uniforms.uColor.value) : null,
    teff: b.teff ?? null, glow: spec.glow ?? def.glow ?? null,
  };
  if (v.mat && v.mat.uniforms.uGranScale) {
    const u = v.mat.uniforms;
    e.u = {};
    for (const k of ['uTime', 'uPulse', 'uLimbU', 'uTeff', 'uOmega', 'uSpin', 'uGdBeta', 'uTpole', 'uGain', 'uGranScale', 'uSpotCount', 'uFlareCount'])
      e.u[k] = u[k].value;
    e.u.uColPole = col(u.uColPole.value); e.u.uColEq = col(u.uColEq.value); e.u.uHot = col(u.uHot.value);
    e.coronaTime = v.corona.material.uniforms.uTime.value;
    e.coronaFlux = v.corona.material.uniforms.uFlux.value;
    e.coreScale = v.core.scale.x;
    const ch = v.group.children;
    e.arcTimes = [2, 3, 4, 5].map(i => ch[i].children.map(g => g.children[0].material.uniforms.uTime.value));
    e.cmeSlots = [6, 7, 8].map(i => ({ seed: ch[i].children[0].material.uniforms.uSeed.value,
      time: ch[i].children[0].material.uniforms.uTime.value }));
    const a = b.activity;
    const reg = r => ({ lat: r.lat, lon: r.lon, strength: r.strength, age: r.age, life: r.life });
    e.activity = {
      flux: a.flux, next: a.next,
      regions: a.regions.map(reg),
      flares: a.flares.map(f => ({ t: f.t, duration: f.duration, energy: f.energy, amp: f.amp, dir: arr(f.dir), region: reg(f.region) })),
      cmes: a.cmes.map(c => ({ t: c.t, life: c.life, radius: c.radius, speed: c.speed, alpha: c.alpha, dir: arr(c.dir), width: c.width })),
    };
  }
  if (v.isNeutron) {
    e.neutron = {
      spinY: v.spinAxis.rotation.y, time: v.core.material.uniforms.uTime.value,
      capGlow: v.core.material.uniforms.uCapGlow.value,
      beamTime: v.magAxis.children[1].material.uniforms.uTime.value,
    };
  }
  if (b.marker) {
    const u = b.marker.material.uniforms;
    e.marker = { visible: b.marker.mesh.visible, opacity: u.uOpacity.value, color: col(u.uColor.value),
      gain: u.uGain.value, tempA: u.uTempA.value, sel: u.uSel.value, scale: b.marker.mesh.scale.x };
  }
  out.bodies.push(e);
}
for (const o of SIM.scene.children) {
  if (o.isSprite) out.sprites.push({ pos: o.position.toArray(), scale: o.scale.x, opacity: o.material.opacity });
  if (o.isMesh && o.material && o.material.wireframe && o.material.uniforms && o.material.uniforms.wells) {
    const u = o.material.uniforms;
    out.mesh = { visible: o.visible, pos: o.position.toArray(), wellCount: u.wellCount.value,
      wells: u.wells.value.map(w => w.toArray()), time: u.time.value };
  }
}
return out;
