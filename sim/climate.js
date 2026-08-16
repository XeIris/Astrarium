import { luminosity } from './stellar.js';

// ============================================================================
// CLIMATE — a zero-dimensional energy-balance model (EBM)
// ----------------------------------------------------------------------------
// The oldest real climate model there is, and the right one here: it captures
// exactly the physics that makes Trisolaris terrifying.
//
//   C · dT/dt = (1 − α(T)) · S/4  −  ε σ T⁴
//
//   S      total stellar flux at the planet, summed over every star:
//          S = Σ L_i / d_i²   (in solar constants, then × 1361 W/m²)
//   α(T)   planetary albedo, which RISES as the planet freezes — the
//          ice-albedo feedback. This is the runaway: a cold snap grows ice,
//          ice reflects sunlight, which deepens the cold snap. Cross the
//          threshold and the planet snowballs and never comes back.
//   ε      effective emissivity, i.e. the greenhouse. ε = 0.61 is calibrated
//          so Earth (S = 1, α = 0.3) sits at 288 K.
//   C      heat capacity of the ocean mixed layer — the planet's thermal
//          flywheel. A deep ocean damps the swings; a shallow one lets the
//          temperature whip around with the orbit.
//
// The result is emergent, not scripted: Stable Eras and Chaotic Eras fall out
// of the orbit, and a bad enough Chaotic Era genuinely sterilises the world.
// ============================================================================

const S0 = 1361;              // solar constant, W/m²
const SIGMA = 5.670374e-8;    // Stefan–Boltzmann, W m⁻² K⁻⁴
const YEAR_S = 3.15576e7;     // seconds per year
const RHO_CW = 1000 * 4181;   // sea water ρ·c_p, J m⁻³ K⁻¹

export const ERAS = {
  DEEP_FREEZE: { key: 'DEEP_FREEZE', label: 'Deep Freeze',  cls: 'era-freeze', desc: 'Oceans locked in ice. Dehydrate and wait.' },
  COLD:        { key: 'COLD',        label: 'Chaotic — Cold', cls: 'era-cold', desc: 'A long winter. The suns are far.' },
  STABLE:      { key: 'STABLE',      label: 'Stable Era',   cls: 'era-stable', desc: 'Temperate. Civilisation may rebuild.' },
  HOT:         { key: 'HOT',         label: 'Chaotic — Hot', cls: 'era-hot',  desc: 'The suns are closing. Heat is rising.' },
  SCORCH:      { key: 'SCORCH',      label: 'Scorching',    cls: 'era-scorch',desc: 'Oceans boiling off. Nothing survives unburied.' },
};

export class Climate {
  constructor(opts = {}) {
    this.mixedLayer = opts.mixedLayer ?? 12;   // metres of ocean
    this.greenhouse = opts.greenhouse ?? 0.61; // effective emissivity ε
    this.albedoBase = opts.albedoBase ?? 0.22; // ice-free albedo
    this.albedoIce  = opts.albedoIce ?? 0.45;  // extra albedo at full glaciation
    this.T = opts.T0 ?? 288;                   // K
    this.S = 1;                                // current insolation, S⊕
    this.perStar = [];                         // [{ name, S, dist, frac }]
    this.era = ERAS.STABLE;
    this.ice = 0;                              // 0..1 glaciated fraction
    this.clouds = 0.4;                         // 0..1 cloud cover
    this.humidity = 0.5;
    this.time = 0;
    // rolling history for the graph: [simYear, S, T]
    this.history = [];
    this.historyMax = 900;
    this._acc = 0;
    // Seeded from the empty interval, not from 1 S⊕: step() only ever narrows
    // these with min/max, so a seed of 1 is reported as an observed extreme on
    // a world that never receives exactly one solar constant. Trisolaris ranges
    // 0.40–3.08 S⊕, so Smin would read a fictitious 1.00 until the first dip.
    this.extremes = { Tmin: this.T, Tmax: this.T, Smin: Infinity, Smax: -Infinity };
  }

  get heatCapacity() { return this.mixedLayer * RHO_CW; }   // J m⁻² K⁻¹

  // Radiative relaxation time of the planet, in years — how long it takes to
  // respond to a change in sunlight. Compare it to the orbital period to know
  // whether the world can even "feel" a season.
  get tauYears() {
    return this.heatCapacity / (4 * this.greenhouse * SIGMA * Math.pow(this.T, 3)) / YEAR_S;
  }

  albedo(T) {
    // ice fraction ramps in between 278 K and 233 K
    const ice = Math.min(Math.max((278 - T) / 45, 0), 1);
    return { alb: this.albedoBase + this.albedoIce * ice, ice };
  }

  // Insolation from every luminous body, in units of Earth's solar constant.
  // `planet` and `stars` carry positions in AU.
  insolation(planet, stars) {
    let S = 0;
    this.perStar.length = 0;
    for (const s of stars) {
      const L = s.luminosity ?? luminosity(s.mass);
      const d = Math.max(planet.pos.distanceTo(s.pos), 1e-4);
      // flares briefly brighten the star; activity.flux is 1 when quiet
      const flux = s.activity ? s.activity.flux : 1;
      const contrib = L * flux / (d * d);
      S += contrib;
      this.perStar.push({ name: s.name, S: contrib, dist: d, mass: s.mass });
    }
    for (const p of this.perStar) p.frac = S > 0 ? p.S / S : 0;
    this.perStar.sort((a, b) => b.S - a.S);
    return S;
  }

  classify(T) {
    if (T < 233) return ERAS.DEEP_FREEZE;
    if (T < 273) return ERAS.COLD;
    if (T > 345) return ERAS.SCORCH;
    if (T > 305) return ERAS.HOT;
    return ERAS.STABLE;
  }

  // Advance the climate by `dtYears` of simulated time.
  step(dtYears, planet, stars) {
    if (!(dtYears > 0)) return;
    this.time += dtYears;
    this.S = this.insolation(planet, stars);

    // Sub-step so a big frame-step can't overshoot the T⁴ term into instability.
    const tau = Math.max(this.tauYears, 1e-4);
    const n = Math.min(64, Math.max(1, Math.ceil(dtYears / (tau * 0.25))));
    const h = dtYears / n;
    for (let i = 0; i < n; i++) {
      const { alb, ice } = this.albedo(this.T);
      const absorbed = (1 - alb) * this.S * S0 / 4;
      const emitted = this.greenhouse * SIGMA * Math.pow(this.T, 4);
      this.T += (absorbed - emitted) / this.heatCapacity * (h * YEAR_S);
      this.T = Math.max(this.T, 3);
      this.ice = ice;
    }

    // Diagnostics that ride on temperature: humidity → cloud → weather.
    // Saturation vapour pressure roughly doubles every 10 K (Clausius–Clapeyron),
    // so a warm world is a wet, cloudy, stormy one.
    const cc = Math.pow(2, (this.T - 288) / 10);
    this.humidity = Math.min(1, cc * (1 - this.ice) * 0.5);
    this.clouds = Math.min(0.95, 0.12 + this.humidity * 0.75);
    // storminess scales with how hard the insolation is changing plus raw heat
    this.storm = Math.min(1, this.humidity * 0.8 + Math.max(0, (this.T - 300) / 60));

    this.era = this.classify(this.T);

    const e = this.extremes;
    e.Tmin = Math.min(e.Tmin, this.T); e.Tmax = Math.max(e.Tmax, this.T);
    e.Smin = Math.min(e.Smin, this.S); e.Smax = Math.max(e.Smax, this.S);

    // sample the history on a cadence tied to sim time, not frame rate
    this._acc += dtYears;
    const cadence = Math.max(0.004, dtYears);
    if (this._acc >= cadence) {
      this._acc = 0;
      this.history.push([this.time, this.S, this.T]);
      if (this.history.length > this.historyMax) this.history.shift();
    }
  }

  reset(T0 = 288) {
    this.T = T0; this.time = 0; this.history.length = 0;
    // Every derived quantity has to go back with it. sim/world.js reads cl.ice
    // straight into the surface shader and the HUD reads era/clouds, so leaving
    // these behind leaves the old run's ice caps and era badge on screen until
    // the next step() completes.
    this.S = 1; this.ice = 0; this.clouds = 0.4; this.humidity = 0.5;
    this.era = ERAS.STABLE;
    this.perStar.length = 0; this._acc = 0;
    this.extremes = { Tmin: T0, Tmax: T0, Smin: Infinity, Smax: -Infinity };
  }

  get celsius() { return this.T - 273.15; }
}
