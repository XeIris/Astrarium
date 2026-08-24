import * as THREE from 'three';
import { baseLuminosity, baseRadiusSun } from './structure.js';

// ============================================================================
// STELLAR ASTROPHYSICS — the numbers behind a star.
// ----------------------------------------------------------------------------
// Everything here is derived from ONE input: the mass in M☉. Main-sequence
// scaling relations give radius, luminosity and effective temperature; Teff
// gives the colour via a Planck-curve fit. So a 2 M☉ star really is bigger,
// hotter, bluer and ~11× more luminous than the Sun without any of it being
// hand-tuned per body.
// ============================================================================

// Mass–luminosity and mass–radius. Both live in sim/structure.js, which is the
// single place that decides what a star of a given mass is; they are re-exported
// here because this module's own name is what the rest of the sim reaches for.
//
// Keeping one copy matters above ~20 M☉, where the piecewise L ∝ M^3.5 that used
// to be here runs away — it returns 1.7e6 L☉ at 55 M☉ against a real ~5e5, and
// the Eddington factor computed from it would say every massive star is unbound.
// See MASSIVE_L there.
export { baseLuminosity as luminosity, baseRadiusSun as radiusSun } from './structure.js';

// Effective temperature from Stefan–Boltzmann: L = 4πR²σT⁴  ⇒  T ∝ (L/R²)^¼.
// Normalised so 1 M☉ → 5772 K.
export function effectiveTemp(massSun) {
  const L = baseLuminosity(massSun), R = baseRadiusSun(massSun);
  return 5772 * Math.pow(L / (R * R), 0.25);
}

// Harvard spectral class letter, for the HUD.
export function spectralClass(teff) {
  if (teff >= 30000) return 'O';
  if (teff >= 10000) return 'B';
  if (teff >= 7500)  return 'A';
  if (teff >= 6000)  return 'F';
  if (teff >= 5200)  return 'G';
  if (teff >= 3700)  return 'K';
  return 'M';
}

// ----------------------------------------------------------------------------
// Blackbody colour. Tanner Helland's piecewise fit to the Planck locus, then
// normalised to keep the perceived brightness roughly constant (we convey
// luminosity through size/glow/light intensity, not by dimming the disc).
// ----------------------------------------------------------------------------
export function blackbodyColor(kelvin) {
  const t = THREE.MathUtils.clamp(kelvin, 1000, 40000) / 100;
  let r, g, b;
  if (t <= 66) { r = 255; }
  else { r = 329.698727446 * Math.pow(t - 60, -0.1332047592); }
  if (t <= 66) { g = 99.4708025861 * Math.log(t) - 161.1195681661; }
  else { g = 288.1221695283 * Math.pow(t - 60, -0.0755148492); }
  if (t >= 66) { b = 255; }
  else if (t <= 19) { b = 0; }
  else { b = 138.5177312231 * Math.log(t - 10) - 305.0447927307; }
  const c = new THREE.Color(
    THREE.MathUtils.clamp(r, 0, 255) / 255,
    THREE.MathUtils.clamp(g, 0, 255) / 255,
    THREE.MathUtils.clamp(b, 0, 255) / 255,
  );
  // renormalise so every star reads as "bright", differing in hue not exposure
  const peak = Math.max(c.r, c.g, c.b) || 1;
  return c.multiplyScalar(1 / peak);
}

// A hotter, whiter version of the photosphere colour for the corona/flares.
export function coronaColor(kelvin) {
  const c = blackbodyColor(kelvin);
  return c.lerp(new THREE.Color(1, 1, 1), 0.35);
}

// ----------------------------------------------------------------------------
// Rotation. Real stars rotate differentially — the equator laps the poles.
// The Sun: ~25 d equatorial, ~34 d polar. Massive stars spin much faster.
// Returned in radians per year (sim time unit).
// ----------------------------------------------------------------------------
export function rotationRate(massSun) {
  const days = 25 * Math.pow(Math.max(massSun, 0.1), -0.6);   // equatorial period
  return 2 * Math.PI / (days / 365.25);
}

// ----------------------------------------------------------------------------
// MAGNETIC ACTIVITY
// Cool stars with deep convective envelopes are the flare stars; hot massive
// stars have radiative envelopes and almost no spots. This drives how often a
// star flares and how heavily it's spotted.
// ----------------------------------------------------------------------------
export function activityLevel(massSun) {
  // peaks for late-K/M dwarfs, falls off sharply above ~1.4 M☉
  const m = Math.max(massSun, 0.08);
  return THREE.MathUtils.clamp(Math.pow(0.9 / m, 1.6), 0.08, 3.0);
}

// Mean interval between significant flares, in sim years.
export function flareInterval(massSun) {
  return 0.06 / activityLevel(massSun);
}

// ============================================================================
// FLARE / CME EVENT MODEL
// ----------------------------------------------------------------------------
// A star carries a small population of active regions (starspot groups). Flares
// erupt from those regions: a fast rise, an exponential decay, and — for the
// biggest events — a coronal mass ejection that expands away from the surface.
// ============================================================================
export class ActivityModel {
  constructor(massSun, rng = Math.random) {
    this.rng = rng;
    this.activity = activityLevel(massSun);
    this.interval = flareInterval(massSun);
    this.next = this.interval * (0.4 + rng());
    this.flares = [];        // live flare events
    this.cmes = [];          // live coronal mass ejections
    this.regions = [];       // active longitudes/latitudes (spot groups)
    const n = Math.round(THREE.MathUtils.clamp(2 + this.activity * 3, 2, 8));
    for (let i = 0; i < n; i++) this.regions.push(this.newRegion());
    this.flux = 1;           // instantaneous brightness multiplier
  }

  newRegion() {
    // spots emerge in mid-latitude "activity belts", not at the poles
    const lat = (0.15 + this.rng() * 0.45) * (this.rng() < 0.5 ? 1 : -1);
    return {
      lat, lon: this.rng() * Math.PI * 2,
      strength: 0.3 + this.rng() * 0.7,
      age: 0, life: 0.15 + this.rng() * 0.5,      // years
    };
  }

  // Unit vector of a region on the (unrotated) stellar surface.
  regionDir(r, out = new THREE.Vector3()) {
    const cl = Math.cos(r.lat);
    return out.set(cl * Math.cos(r.lon), Math.sin(r.lat), cl * Math.sin(r.lon)).normalize();
  }

  step(dt) {
    // age the active regions; retire and replace the spent ones
    for (let i = this.regions.length - 1; i >= 0; i--) {
      const r = this.regions[i];
      r.age += dt;
      if (r.age > r.life) this.regions[i] = this.newRegion();
    }

    // flare arrivals — Poisson-ish, anchored to an active region
    this.next -= dt;
    if (this.next <= 0) {
      this.next = this.interval * (0.5 + this.rng() * 1.4);
      this.ignite();
    }

    // advance flares: fast rise, exponential decay
    let flux = 1;
    for (let i = this.flares.length - 1; i >= 0; i--) {
      const f = this.flares[i];
      f.t += dt;
      const x = f.t / f.duration;
      if (x >= 1) { this.flares.splice(i, 1); continue; }
      // rise over the first 12% of the event, then exponential decay
      f.amp = x < 0.12 ? (x / 0.12) : Math.exp(-(x - 0.12) * 5.5);
      flux += f.amp * f.energy * 0.35;
    }
    this.flux = flux;

    // advance CMEs — a shell expanding at roughly constant speed, fading
    for (let i = this.cmes.length - 1; i >= 0; i--) {
      const c = this.cmes[i];
      c.t += dt;
      c.radius += c.speed * dt;
      c.alpha = Math.max(0, 1 - c.t / c.life);
      if (c.alpha <= 0) this.cmes.splice(i, 1);
    }
  }

  ignite() {
    // A star with no active regions has nothing to flare from (see the `quiet`
    // path in sim/star_visual.js for degenerate stars).
    if (!this.regions.length) return;
    const region = this.regions[Math.floor(this.rng() * this.regions.length)];
    // flare energies follow a power law: many small, rare huge ones
    const energy = Math.pow(this.rng(), 2.2) * 3 * this.activity + 0.15;
    const f = {
      t: 0,
      duration: 0.004 + this.rng() * 0.02,      // years (~1.5–9 days)
      energy, amp: 0,
      dir: this.regionDir(region).clone(),
      region,
    };
    this.flares.push(f);
    // only the energetic events launch a CME
    if (energy > 1.1 * this.activity) {
      this.cmes.push({
        t: 0, life: 0.05 + this.rng() * 0.06,
        radius: 1.0, speed: 14 + this.rng() * 20,   // in stellar radii per year
        alpha: 1, dir: f.dir.clone(),
        width: 0.35 + this.rng() * 0.4,
      });
    }
  }
}
