import * as THREE from 'three';
import { MAX_SUNS, applySuns } from './suns.js';
import { surfaceMaterial, cloudMaterial, atmosphereMaterial, insolationS2 } from './rocky_visual.js';

// ============================================================================
// THE LIVING WORLD
// ----------------------------------------------------------------------------
// A rocky planet whose APPEARANCE IS DRIVEN BY THE CLIMATE MODEL: ice caps
// advance and retreat with the glaciated fraction the EBM is integrating, seas
// shrink as they boil away, cloud decks thicken with humidity, and the ground
// glows when it is hot enough to.
//
// It is lit by every star at once. That is the whole point — a Trisolaran
// sunset has two or three terminators crossing the disc at different angles,
// in different colours, and you can see it directly here.
//
// The terrain, the biomes and the atmosphere are the SAME ones every other
// solid planet gets (sim/rocky_visual.js, over sim/terrain.js). This file is
// only the wiring between the energy-balance model and those uniforms: a
// second terrain model here would be a second answer to what a rocky planet
// looks like, and the two would drift apart.
// ============================================================================

export { MAX_SUNS, applySuns };

export function createWorldVisual(b, opts) {
  const g = new THREE.Group();
  const R = opts.radiusScene;
  const seed = ((b.id * 2654435761) >>> 0) % 1000 / 7.3;

  const surfMat = surfaceMaterial(seed, {
    // A world the climate model is standing on is by construction one with
    // oceans, air and life on it.
    continent: opts.land ?? 0.34,
    biota: 1,
    crater: 0,
    haze: 0.45,
    frostK: 273,
    transport: 0.42,
  });
  const surface = new THREE.Mesh(new THREE.SphereGeometry(R, 96, 64), surfMat);
  g.add(surface);

  const cloudMat = cloudMaterial(seed + 3.7);
  const clouds = new THREE.Mesh(new THREE.SphereGeometry(R * 1.008, 64, 48), cloudMat);
  g.add(clouds);

  const atmoMat = atmosphereMaterial(opts.atmColor);
  const atmo = new THREE.Mesh(new THREE.SphereGeometry(R * 1.035, 72, 48), atmoMat);
  g.add(atmo);

  // The spin axis is tilted — obliquity is what gives a world seasons on top of
  // whatever its orbit is already doing, and it also sets how steep the
  // pole-to-equator insolation gradient is (see insolationS2).
  const tilt = opts.obliquity ?? 0.35;
  g.rotation.z = tilt;
  surfMat.uniforms.uS2.value = insolationS2(tilt);

  b.viz = {
    group: g, core: surface, surface, clouds, atmo,
    surfMat, cloudMat, atmoMat, baseR: R, R, isWorld: true,
  };

  b.spinPhase = 0;
  b.cloudPhase = 0;

  const TAU = Math.PI * 2;

  b.viz.update = (dt, ctx) => {
    const simDt = ctx.simDt ?? 0;
    // planet rotation — b.dayLength is in years
    const day = b.dayLength || 0.01;
    // Both phases wrap. At system speeds this advances hundreds of radians per
    // frame, and rotation.y reaches the GPU as a float32 matrix entry: once the
    // magnitude passes ~1e5 the per-frame increment is under one ulp and the
    // spin quantises and then stops. A rotation is exactly 2π-periodic, so
    // wrapping is free of artefacts — but the cloud deck super-rotates at 0.985
    // of the surface, so it needs its own accumulator rather than a scaled read
    // of spinPhase, which would jump at every wrap.
    b.spinPhase = (b.spinPhase + (simDt / day) * TAU) % TAU;
    b.cloudPhase = (b.cloudPhase + (simDt / day) * TAU * 0.985) % TAU;
    surface.rotation.y = b.spinPhase;
    clouds.rotation.y = b.cloudPhase;          // super-rotating cloud deck

    surfMat.uniforms.uTime.value += dt;
    // The cloud shader feeds uTime into fbm/ridged domains, which are not
    // periodic — wrapping it would pop the cloud field. Bound the sim-time term
    // instead: it is a drift cue, and above a few radians per frame the deck is
    // a blur anyway, so capping it costs nothing visually and keeps the uniform
    // growing at real-time rates.
    cloudMat.uniforms.uTime.value += dt + Math.min(simDt * 40, 2);

    const cl = ctx.climate;
    if (cl) {
      // The EBM owns the global mean temperature AND the glaciated fraction.
      // Handing over both is deliberate: the shader would reach its own ice
      // line from the temperature alone, but the ice-albedo feedback means the
      // fraction is a state variable with hysteresis in it — a snowballed
      // planet stays snowballed at a temperature it would never have frozen
      // at. The picture has to show the state, not re-derive it.
      surfMat.uniforms.uMeanK.value = cl.T;
      surfMat.uniforms.uIce.value = cl.ice;
      // Oceans retreat as the world bakes past the boiling point: the datum
      // drops, in kilometres, until the abyssal plains are dry land.
      const boil = THREE.MathUtils.clamp((cl.T - 350) / 90, 0, 1);
      surfMat.uniforms.uSeaKm.value = -boil * 5.0;
      surfMat.uniforms.uScorch.value = THREE.MathUtils.clamp((cl.T - 330) / 140, 0, 1);
      surfMat.uniforms.uArid.value = THREE.MathUtils.clamp((cl.T - 310) / 80, 0, 0.8);
      cloudMat.uniforms.uCover.value = cl.clouds;
      cloudMat.uniforms.uStorm.value = cl.storm ?? 0.2;
      atmoMat.uniforms.uThick.value = 0.6 + cl.humidity * 0.8;
    }

    // feed the multi-star lighting
    if (ctx.suns) applySuns([surfMat, cloudMat, atmoMat], ctx.suns, b.viz.group.position);
  };

  return b.viz;
}
