import { circularSpeed, G } from './physics.js';
import { luminosity } from './stellar.js';
import { phaseById, baseRadiusSun } from './structure.js';
import { starSpec } from './starcat.js';

// ============================================================================
// TEACHING SCENARIOS
// ----------------------------------------------------------------------------
// These are PRESETS like any other — same units (AU, M☉, yr), same build()
// contract, merged into PRESETS by sim/presets.js — and they are kept in their
// own file only because the catalogue was already 860 lines.
//
// What makes one of these different from a scenario in sim/presets.js is what
// it is FOR. A scenario there is an object worth looking at; a scenario here is
// the minimum arrangement that makes ONE idea visible and nothing else. That
// cuts both ways:
//
//   · Everything irrelevant is removed. The seasons are about the tilt, so the
//     seasons scenario has one planet and one star in it and no Jupiter to
//     wonder about. A scenario that shows three things at once teaches none.
//   · Nothing is faked to make the point. Every number below is real, and the
//     lesson is exactly what the integrator does with it. Where something IS
//     adjusted for watchability — a rotation slowed, a disc drawn at the wrong
//     radius — it is called out in the blurb and in a comment here, because a
//     teaching scenario that lies quietly is worse than no scenario at all.
//
// THE ONE THING THAT IS ALWAYS ADJUSTED is the clock, and it has to be. Earth
// turns 365 times per orbit; a pace that makes the year watchable makes the day
// a strobe and a pace that makes the day watchable makes the year twenty
// minutes long. There is no single answer, so each scenario picks the one its
// lesson needs and the blurb says which.
// ============================================================================

const DEG = Math.PI / 180;

// circular orbit about a dominant central mass at the origin, at a stated phase
function orbiter(Mc, a, spec, angle = 0, incl = 0) {
  const v = circularSpeed(Mc, a);
  return {
    ...spec,
    pos: [Math.cos(angle) * a, Math.sin(angle) * Math.sin(incl) * a, Math.sin(angle) * Math.cos(incl) * a],
    vel: [-Math.sin(angle) * v, Math.cos(angle) * Math.sin(incl) * v, Math.cos(angle) * Math.cos(incl) * v],
  };
}

// A satellite placed relative to its parent's ACTUAL state — see the note on
// moonOf() in sim/presets.js for why the parent's semi-major axis is not enough.
function moonOf(parent, distM, massSun, radiusKm, name, extra = {}) {
  const a = distM / 1.495978707e11;
  const [px, py, pz] = parent.pos, [vx, vy, vz] = parent.vel;
  const r = Math.hypot(px, pz) || 1;
  const ux = px / r, uz = pz / r;
  const v = circularSpeed(parent.mass + massSun, a);
  return {
    type: 'planet', name, mass: massSun, radiusKm, hot: true, ...extra,
    pos: [px + ux * a, py, pz + uz * a],
    vel: [vx - uz * v, vy, vz + ux * v],
  };
}

// An eccentric orbit started at APOAPSIS, which is where an orbit is slowest
// and therefore where a lesson about orbital speed should begin. Vis-viva at
// r = a(1+e) gives v = √(GM (1-e)/(a(1+e))).
function eccentric(Mc, a, e, spec, angle = 0) {
  const r = a * (1 + e);
  const v = Math.sqrt(G * Mc * (1 - e) / (a * (1 + e)));
  return {
    ...spec,
    pos: [Math.cos(angle) * r, 0, Math.sin(angle) * r],
    vel: [-Math.sin(angle) * v, 0, Math.cos(angle) * v],
  };
}

// The Earth, as the climate model's home world rather than as one more rocky
// planet. Everything here is measured: 23.44° of obliquity, 0.306 Bond albedo,
// 29% land, and a 0.61 greenhouse factor that puts a 255 K equilibrium
// temperature at the 288 K the surface actually has.
const EARTH = {
  type: 'world', name: 'Earth', mass: 3.0035e-6, radiusKm: 6371,
  atmosphere: true, land: 0.29, biota: 1, albedo: 0.306, greenhouse: 0.61,
  obliquity: 23.44 * DEG, cloudCover: 0.44, season: 11, home: true,
};

const MOON = { hot: true, crater: 1.0, regolith: 0x9a958c, albedo: 0.12, obliquity: 0.0268 };

export const EDU_PRESETS = {

  // ==========================================================================
  // WHY THERE ARE SEASONS
  // --------------------------------------------------------------------------
  // The single most robust misconception in astronomy education is that summer
  // is when the Earth is nearer the Sun — it survives a physics degree, and the
  // reason it survives is that nobody is ever shown the geometry moving. So
  // this scenario contains exactly two things that matter: an axis that keeps
  // pointing the same way in space, and an orbit for it to go round.
  //
  // The orbit here is Earth's REAL one, e = 0.0167, and that is the whole
  // argument: perihelion is on 3 January. The Earth is closest to the Sun in
  // northern winter. The 3.4% change in distance over a year is a 6.8% change
  // in insolation — real, measurable, and the wrong sign for the explanation
  // everyone gives. What does the work is 23.44° of tilt, which at 67°N is the
  // difference between the Sun never setting and never rising.
  // ==========================================================================
  edu_seasons: {
    sky: { env: 'disc', tilt: 0.38, roll: 2.1 },
    name: 'Why there are seasons',
    blurb: 'One star, one planet, and the real 23.44° tilt. Earth\'s orbit is its real one — eccentricity 0.0167, with perihelion in January — so the planet is CLOSEST to the Sun during northern winter. Watch the terminator: the axis keeps pointing at the same place in the sky all year, so first one pole leans into the light and then the other. The ONE thing changed from reality is the length of the day: this world turns 20 times a year rather than 365, because no single pace makes both the day and the year watchable and the course needs both.',
    sceneScale: 34, bodyScale: 0.5, camRadius: 12, lensing: false, mesh: false,
    timeScale: 0.06, maxStep: 1e-3,
    surface: true, focus: 'Earth',
    climate: { mixedLayer: 60, T0: 288 },
    build() {
      const Ms = 1.0;
      const sun = { type: 'star', name: 'Sun', mass: Ms, color: 0xfff2cc, glow: 0xffaa33, pos: [0, 0, 0], vel: [0, 0, 0] };
      // Started at aphelion (early July) so the first thing that happens is the
      // planet falling toward the Sun through northern autumn — i.e. getting
      // nearer as it gets colder, which is the point.
      // 20 days to the year. At the real 365 the planet is a strobe at any
      // clock that makes the orbit watchable, and at a clock slow enough for
      // the rotation the year takes an hour. The lessons then pick their own
      // pace on top of this: the day/night lesson runs at 0.003 yr/s (a day in
      // 17 seconds), the seasons lesson at 0.06 (a year in 17 seconds).
      const earth = eccentric(Ms, 1.00000011, 0.0167, { ...EARTH, dayLength: 1 / 20 });
      return [sun, earth];
    },
  },

  // ==========================================================================
  // PHASES AND ECLIPSES
  // --------------------------------------------------------------------------
  // The second great misconception: that the Moon's phases are the Earth's
  // shadow. The refutation is geometric and needs no words — half the Moon is
  // lit at every instant, always the half facing the Sun, and a phase is just
  // how much of that lit half happens to face us. The Earth's shadow does fall
  // on the Moon, twice a year at most, and when it does the Moon goes dark red
  // in an hour rather than over a fortnight. This scene shows the alignment; mutual eclipse shadows are not rendered.
  //
  // The Moon's orbit is tilted 5.14° to the ecliptic, and that number is why
  // eclipses are rare rather than monthly: the Moon misses the shadow by up to
  // ten Earth diameters at most new moons. It is in here as a real inclination,
  // so the alignments come round on their own.
  // ==========================================================================
  edu_moon: {
    sky: { env: 'disc', tilt: 0.38, roll: 2.1 },
    name: 'Phases, and why eclipses are rare',
    blurb: 'The Earth–Moon system at its real separation — 384 400 km, thirty Earth diameters, which is already further apart than almost every diagram draws it. The Sun lights exactly half the Moon at every instant; the phase is how much of that half you can see from here. The geometry shows eclipse alignments; mutual eclipse shadows are not rendered. Earth’s rotation is slowed to 80 turns per year. The orbit carries its real 5.14° tilt to the ecliptic, which is the entire reason there is not an eclipse every month: at most new moons the shadow misses by several Earth diameters.',
    sceneScale: 900, bodyScale: 0.25, camRadius: 6.5, lensing: false, mesh: false,
    // A lunar month in about twelve seconds. The Moon's orbit is the clock this
    // scenario is about, so it is the one the pace is chosen for.
    trueScale: true, timeScale: 0.006, maxStep: 2e-4,
    surface: true, focus: 'Earth',
    climate: { mixedLayer: 60, T0: 288 },
    build() {
      const Ms = 1.0;
      const sun = { type: 'star', name: 'Sun', mass: Ms, color: 0xfff2cc, glow: 0xffaa33, pos: [0, 0, 0], vel: [0, 0, 0] };
      const earth = orbiter(Ms, 1.0, { ...EARTH, dayLength: 1 / 80 }, 0);
      const moon = moonOf(earth, 3.844e8, 3.6923e-8, 1737.4, 'Moon', { ...MOON, tidalLock: 'Earth' });
      // The 5.14° tilt, applied to the moon's state RELATIVE to the Earth so
      // the inclination is of the lunar orbit and not of the Earth's.
      const i = 5.145 * DEG, c = Math.cos(i), s = Math.sin(i);
      const rot = (v, o) => {
        const dx = v[0] - o[0], dy = v[1] - o[1], dz = v[2] - o[2];
        // rotate about the x axis (the line of nodes, put along x by construction)
        return [o[0] + dx, o[1] + dy * c - dz * s, o[2] + dy * s + dz * c];
      };
      moon.pos = rot(moon.pos, earth.pos);
      moon.vel = rot(moon.vel, earth.vel);
      return [sun, earth, moon];
    },
  },

  // ==========================================================================
  // KEPLER'S LAWS, AS AN EXPERIMENT
  // --------------------------------------------------------------------------
  // Three planets, and the arrangement IS the argument:
  //
  //   Circle and Ellipse are both at a = 1.5 AU — one on a circle, one on an
  //   e = 0.72 ellipse that runs from 0.42 to 2.58 AU. THE THIRD LAW SAYS THEY
  //   HAVE THE SAME PERIOD, because the period depends on the semi-major axis
  //   and on nothing else, and there is no way to believe that until you watch
  //   two wildly different orbits keep meeting up. They are started together
  //   at apoapsis and they return together, forever.
  //
  //   Far is at a = 1.5 × 4^(1/3) = 2.3811 AU, chosen so that a³ is exactly
  //   four times the inner one's. P² ∝ a³ then makes its period exactly twice
  //   theirs: two laps of Circle to one of Far, every time, and you can count
  //   them rather than take the exponent on trust.
  //
  // The second law needs no third body at all: on the ellipse the planet runs
  // 6.1 times faster at periapsis than at apoapsis (the ratio is (1+e)/(1-e)),
  // and the trail bunches where it is slow and stretches where it is fast.
  // ==========================================================================
  edu_kepler: {
    sky: { env: 'disc', tilt: 0.30, roll: 1.1 },
    name: "Kepler's laws",
    blurb: 'Three planets round one star. Circle and Ellipse have the SAME semi-major axis — 1.5 AU — and wildly different shapes, and they keep arriving back together, because the period depends on the semi-major axis and on nothing else. Far sits at 2.381 AU, where a³ is exactly four times theirs, so it takes exactly two of their years to go round once: count the laps. On the ellipse the planet moves 6.1 times faster at its closest point than at its furthest, which is the second law — the trail bunches up where it is slow.',
    sceneScale: 22, bodyScale: 0.35, camRadius: 62, lensing: false, mesh: false,
    timeScale: 0.6, maxStep: 1e-3,
    build() {
      const Ms = 1.0, a = 1.5;
      const sun = { type: 'star', name: 'Sun', mass: Ms, color: 0xfff2cc, glow: 0xffaa33, pos: [0, 0, 0], vel: [0, 0, 0] };
      const rock = (name, color) => ({
        type: 'planet', name, mass: 3.0e-6, radiusKm: 6371, hot: true,
        crater: 0.4, regolith: color, albedo: 0.22, obliquity: 0.2,
      });
      return [
        sun,
        orbiter(Ms, a, rock('Circle', 0x8fa3b8), 0),
        eccentric(Ms, a, 0.72, rock('Ellipse', 0xb8896a), 0),
        // a³ = 4 × 1.5³ → a = 1.5 × 4^(1/3) = 2.3811 AU, period exactly 2×.
        orbiter(Ms, a * Math.cbrt(4), rock('Far', 0x7f8f7a), Math.PI),
      ];
    },
  },

  // ==========================================================================
  // WHERE STARS COME FROM
  // --------------------------------------------------------------------------
  // A star forms when a cold, dense core inside a molecular cloud becomes
  // heavier than its own Jeans mass and can no longer hold itself up:
  //
  //     M_J ≈ 2 M☉ (T/10 K)^1.5 (n/10⁴ cm⁻³)^-0.5
  //
  // — a few solar masses for a core at 10 K, which is why stars come out at
  // the masses they do rather than at planetary or galactic ones. What collapses
  // is rotating, and it cannot lose that rotation, so it lands on a DISC rather
  // than a point: the material at 30 AU has too much angular momentum to fall
  // any further in until friction takes it away.
  //
  // The protostar at the middle is not yet a star. It is held up by the heat of
  // its own contraction — see PHASES in sim/structure.js — and it is bigger,
  // cooler and redder than it will ever be again once hydrogen lights.
  //
  // WHAT IS NOT SIMULATED, and is said rather than implied: the collapse. It
  // takes 10⁵ years, and the disc particles here are analytic test particles on
  // fixed Keplerian orbits (sim/painter.js) rather than infalling gas. What the
  // scenario shows is the ARRANGEMENT a collapse leaves behind, which is the
  // part a lesson can actually argue from.
  // ==========================================================================
  edu_starbirth: {
    // The cloud is the SKY here, not a painted object. sim/painter.js's nebula
    // is an optically thin SHELL — right for ejecta, where a crisp limb-
    // brightened rim is what a thrown-off envelope genuinely looks like, and
    // wrong for an infalling one, where it renders as a soap bubble with a hard
    // silhouette. sim/sky.js already has H II regions, reflection nebulosity
    // and dust as populations, so turning those up puts the star inside a real
    // star-forming region instead of inside a balloon.
    sky: { env: { starburst: 1, disc: 0.35 }, tilt: 0.44, roll: 0.8,
           hii: 5.4, reflection: 3.4, dust: 2.3, starDensity: 2.0 },
    name: 'The birth of a star',
    blurb: 'A protostar in a star-forming region, with the disc it cannot avoid having. What collapsed was rotating, and rotation cannot be thrown away, so the infalling gas lands on a disc instead of on the star — which is where the planets come from, and why every planet in our solar system goes round the same way. The star at the centre is not fusing anything yet: it shines on the heat of its own collapse, and it is larger and redder now than it will ever be again. The nebulosity is the sky, not an object: the H II and reflection components of sim/sky.js turned up, because that is genuinely where young stars are. The cloud core immediately around it is NOT drawn — the painter models optically thin shells, which is right for a thrown-off envelope and wrong for an infalling one.',
    sceneScale: 0.9, bodyScale: 0.8, camRadius: 32, lensing: false, mesh: false,
    timeScale: 2.0, maxStep: 2e-3,
    paint: [
      // Σ ∝ r^-1, the minimum-mass solar nebula's profile, from the dust
      // sublimation radius out to where the cloud is still falling in.
      { kind: 'belt', body: 'Protostar', inner: 0.35, outer: 26, color: 0xc8956a, surfaceDensity: -1.0 },
    ],
    build() {
      const pr = phaseById('protostar');
      const M = 1.0;
      const star = {
        type: 'star', name: 'Protostar', mass: M, phase: pr.f,
        // The Hayashi track: nearly fixed at ~4000 K while the radius shrinks.
        teff: 4100, radiusSun: baseRadiusSun(M) * pr.rMul, luminosity: 1.6,
        color: 0xffb070, glow: 0xff6a28, pos: [0, 0, 0], vel: [0, 0, 0],
      };
      return [
        star,
        // Two bodies that have already swept their own lanes clear — the first
        // planets, at the distances where the disc is dense enough to build one.
        orbiter(M, 5.2, { type: 'gas-giant', name: 'Protoplanet', mass: 3.0e-4, palette: 'jupiter', internalHeat: 4.0 }, 0.7),
        orbiter(M, 12.0, { type: 'planet', name: 'Planetesimal', mass: 2.0e-6, radiusKm: 4000, hot: true, crater: 0.9, regolith: 0x8a7a6a }, 3.6),
      ];
    },
  },

  // ==========================================================================
  // THE SUN, CLOSE UP
  // --------------------------------------------------------------------------
  // A star on its own, on a clock slow enough that a flare is an event rather
  // than a single frame. Flares arrive years apart and last days; at any pace
  // that makes an orbit legible the whole eruption is over inside one frame,
  // which is why this scenario has no orbit in it at all.
  // ==========================================================================
  edu_sun: {
    sky: { env: 'disc', tilt: 0.38, roll: 2.1 },
    name: 'The Sun, close up',
    blurb: 'One ordinary G2 star at 5772 K, filling the frame, on a clock slowed to about a day per second — because a solar flare lasts hours and erupts once every few years, and at orbital pace the entire event happens between two frames. Everything on the surface is derived: the granulation is convection cells at the size the pressure scale height gives, the spots are where the field is strong enough to choke that convection, and the loops above them are gas that cannot cross a magnetic field line and so slides along it.',
    sceneScale: 210, bodyScale: 1.0, camRadius: 6.0, lensing: false, mesh: false,
    trueScale: true, timeScale: 0.0028, maxStep: 5e-4,
    build() { return [starSpec('sun', { pos: [0, 0, 0], vel: [0, 0, 0] })]; },
  },

  // ==========================================================================
  // ONE STAR, WHOLE LIFE
  // --------------------------------------------------------------------------
  // A single solar-mass star with nothing near it, so the cross-section panel's
  // phase slider has the frame to itself. The slider is not an animation: each
  // stop is a real point on the evolutionary track (PHASES in sim/structure.js)
  // and the radius, luminosity, colour and interior layers are recomputed by
  // structureOf() at every step. The star swells by a factor of 130 between the
  // main sequence and the AGB, which is why nothing else is in the scene.
  // ==========================================================================
  edu_lifecycle: {
    sky: { env: 'disc', tilt: 0.40, roll: 0.3 },
    name: 'One star, whole life',
    blurb: 'A single solar-mass star, with the cross-section panel open and its phase slider free. Every stop on it is a real point on the evolutionary track — the radius, the temperature, the colour and the interior layers are all recomputed from the model, not cross-faded between pictures. Drag it right and watch the star leave the main sequence, swell 25-fold into a red giant, and then 130-fold again; the inner planet is at Mercury\'s distance to show what that means for anything in the way.',
    // A star that runs from 0.9 R☉ to 130 is a range of 144 to 1, and no single
    // viewing distance covers it. The opening one frames the ZAMS star; after
    // that the follow camera reframes as the star grows (editBody asks it to
    // glide), so the zoom is a consequence of the slider rather than a setting.
    sceneScale: 26, bodyScale: 1.0, camRadius: 1.1, lensing: false, mesh: false,
    trueScale: true, timeScale: 0.4, maxStep: 1e-3,
    focus: 'Sol',
    build() {
      const M = 1.0;
      return [
        // DELIBERATELY UNMEASURED. A spec that states radiusSun, teff or
        // luminosity is telling the model those are observations of one real
        // star, and starStructure() then holds them fixed against everything
        // else — including the phase. Which is right for Betelgeuse and exactly
        // wrong here: this star's whole purpose is to be walked along its
        // evolutionary track, so it gives its mass and its starting phase and
        // lets the track say what it looks like at each stop.
        { type: 'star', name: 'Sol', mass: M, phase: phaseById('zams').f,
          pos: [0, 0, 0], vel: [0, 0, 0] },
        orbiter(M, 0.387, { type: 'planet', name: 'Inner world', mass: 1.66e-7, radiusKm: 2439.7,
          hot: true, crater: 0.95, regolith: 0x8b8279, albedo: 0.12 }, 0.5),
        orbiter(M, 1.0, { type: 'planet', name: 'Earth-like', mass: 3.0035e-6, radiusKm: 6371,
          atmosphere: true, land: 0.29, albedo: 0.306, greenhouse: 0.61, obliquity: 23.44 * DEG,
          cloudCover: 0.44, hot: true }, 3.4),
      ];
    },
  },

  // ==========================================================================
  // A STAR THAT IS ABOUT TO EXPLODE
  // --------------------------------------------------------------------------
  // 20 M☉ at the pre-collapse stop: an iron core the size of the Earth under
  // silicon, oxygen, neon, carbon, helium and hydrogen shells, radiating six
  // thousand times the Sun's luminosity out of a photosphere 220 times the
  // radius. Iron is where nuclear binding energy peaks, so burning it takes
  // energy in rather than giving it out; the moment the core passes its own
  // Chandrasekhar mass there is nothing left holding it up and it falls in
  // about a quarter of a second.
  //
  // endStateOf() in sim/structure.js decides what is left, and at 20 M☉ that is
  // a black hole. Below about 20 it is a neutron star. Nothing here is scripted:
  // the lesson triggers the collapse and the structure model answers.
  // ==========================================================================
  edu_supernova: {
    sky: { env: ['starburst', 'disc'], tilt: 0.5, roll: 1.4 },
    name: 'A star about to explode',
    blurb: 'Twenty solar masses at the last stop before the end. Silicon burning in the core takes about a day and builds an iron core — and iron is where nuclear binding energy peaks, so burning it costs energy instead of releasing it. When that core passes its own Chandrasekhar mass it falls in inside a quarter of a second, and what is left over depends only on how heavy it was. The scenario knows which; it is not told.',
    sceneScale: 1.6, bodyScale: 1.0, camRadius: 44, lensing: false, mesh: false,
    trueScale: true, timeScale: 0.25, maxStep: 2e-3,
    focus: 'Doomed',
    build() {
      const M = 20;
      const p = phaseById('preSN');
      return [{
        type: 'star', name: 'Doomed', mass: M, phase: p.f,
        radiusSun: baseRadiusSun(M) * p.rMul, luminosity: luminosity(M) * 0.06,
        teff: 3600, color: 0xff8a50, glow: 0xff5a20, pos: [0, 0, 0], vel: [0, 0, 0],
      }];
    },
  },

  // ==========================================================================
  // A LIGHTHOUSE MADE OF NEUTRONS
  // --------------------------------------------------------------------------
  // 1.4 M☉ inside 12 km: a teaspoon weighs as much as a mountain range, the
  // surface gravity is 2×10¹¹ g, and light leaving the surface is bent so hard
  // that you can see more than half the sphere at once — which sim/neutron_visual.js
  // ray-traces rather than approximates.
  //
  // The beams come out of the MAGNETIC poles and the magnetic axis is not the
  // rotation axis, so they sweep. That is the entire pulsar phenomenon: not a
  // blinking star, a rotating one, seen by anyone the beam happens to cross.
  // ==========================================================================
  edu_pulsar: {
    sky: { env: ['disc', 'halo'], tilt: 0.58, roll: 2.2 },
    name: 'A pulsar',
    blurb: 'One and a half solar masses inside a sphere 24 km across, turning 30 times a second. Its gravity bends the light leaving its own surface far enough that you see well past the limb — more than half the star at once. The beams come out of the magnetic poles, which are not the rotation poles, so they sweep: a pulsar does not blink, it rotates, and we only call it a pulsar because the beam happens to cross us. Switch to the RADIO band to see what a radio telescope sees.',
    // 12.5 km across at true scale. sceneScale is chosen so the star is about
    // one scene unit wide (8.35e-8 AU × 1.2e7 = 1.0) — everything else in this
    // sim is AU-sized, and a body eight orders of magnitude smaller has to be
    // given a scale of its own or the camera cannot get near it before the near
    // plane eats it.
    sceneScale: 1.2e7, bodyScale: 1.0, camRadius: 6.5, lensing: false, mesh: false,
    trueScale: true, timeScale: 2.0e-7, maxStep: 1e-8,
    focus: 'Pulsar',
    build() {
      return [{ type: 'neutron', name: 'Pulsar', mass: 1.4, spin: 30, spinFrac: 0.02,
        pos: [0, 0, 0], vel: [0, 0, 0] }];
    },
  },

  // ==========================================================================
  // HOW WE FIND PLANETS ROUND OTHER STARS
  // --------------------------------------------------------------------------
  // Two planets on nearly edge-on orbits, chosen so that both detection methods
  // work on the same system and the numbers come out as the real ones do:
  //
  //   Giant  1.2 M_J, 1.3 R_J, a = 0.05 AU. Period 4.08 d. It covers
  //          (1.3 × 69911 / 695700)² = 1.70% of the star's AREA, and pulls the
  //          star around at K = 28.43 (M_p/M_J)(a/AU)^-½ = 152 m/s — both
  //          comfortably measurable, which is why every early exoplanet was a
  //          hot Jupiter and why people briefly thought hot Jupiters were the
  //          normal kind of planet.
  //   Rock   1 R⊕ at a = 0.28 AU. Area ratio (6371/695700)² = 84 parts per
  //          million, a factor of 200 shallower, and a wobble of 17 cm/s.
  //
  // THE MEASURED DIP IS DEEPER THAN THE AREA RATIO, and that is not an error in
  // either number: a stellar disc is limb darkened, so a planet crossing the
  // middle of it blocks brighter-than-average light. For the linear law with
  // u = 0.6 the central intensity is 1/(1−u/3) = 1.25 times the mean, so a
  // small planet near mid-transit blocks up to about 1.25 × the area ratio and
  // the floor of the dip is rounded rather than flat. The photometer integrates
  // that rather than assuming it — see sim/lightcurve.js — which is why it
  // reads about 2.1% here and not 1.70%.
  //
  // The observer is the CAMERA, so the transit only happens when you are in the
  // orbital plane — which is also the honest statement of the method's biggest
  // limitation: a transit needs the geometry to cooperate, and for a planet at
  // 1 AU round a Sun the chance of that is about 0.5%.
  // ==========================================================================
  edu_transit: {
    sky: { env: 'disc', tilt: 0.34, roll: 1.9 },
    name: 'Finding planets: transits and wobbles',
    blurb: 'A Sun-like star with two planets on almost edge-on orbits. The hot Jupiter covers 1.7% of the star every 4.08 days and hauls it around at 152 m/s; the Earth-sized planet further out covers 84 parts per million and moves the star at 17 cm/s. Both are real numbers for those planets. The measured dip is a little deeper than the area ratio, because a stellar disc is brighter in the middle than at the edge. The observer is the camera — so climb out of the orbital plane and the transits stop, which is exactly why we have only found the planets whose orbits happen to point at us.',
    sceneScale: 300, bodyScale: 0.5, camRadius: 26, lensing: false, mesh: false,
    // 0.005 yr/s puts the hot Jupiter's 4.08-day year at about 2.2 seconds, so
    // a few whole orbits fit in the photometer's window at once. Any faster and
    // the dips arrive several per second, which is a texture rather than a
    // measurement.
    timeScale: 0.005, maxStep: 2e-5,
    focus: 'Kepler-ish',
    build() {
      const M = 1.0;
      const star = { type: 'star', name: 'Kepler-ish', mass: M, radiusSun: 1.0, teff: 5772,
        luminosity: 1.0, color: 0xfff2cc, glow: 0xffaa33, pos: [0, 0, 0], vel: [0, 0, 0] };
      // 1.2 Jupiter masses in solar units, and an inflated 1.3 R_J — hot
      // Jupiters really are puffed up by the irradiation they sit under.
      const giant = orbiter(M, 0.05, {
        type: 'gas-giant', name: 'Giant b', mass: 1.2 * 9.5459e-4, radiusKm: 1.3 * 69911,
        palette: 'jupiter', internalHeat: 3.0,
      }, 0.0, 1.2 * DEG);
      const rock = orbiter(M, 0.28, {
        type: 'planet', name: 'Rock c', mass: 3.0035e-6, radiusKm: 6371, hot: true,
        crater: 0.3, regolith: 0xa08878, albedo: 0.25,
      }, 2.4, 0.4 * DEG);
      // The star's own reflex motion. `orbiter` puts the planets on orbits about
      // a fixed centre, which leaves the barycentre drifting; giving the star
      // the balancing momentum is what makes the radial-velocity lesson honest —
      // the wobble it measures has to be the wobble the integrator produces.
      const px = giant.mass * giant.vel[0] + rock.mass * rock.vel[0];
      const py = giant.mass * giant.vel[1] + rock.mass * rock.vel[1];
      const pz = giant.mass * giant.vel[2] + rock.mass * rock.vel[2];
      star.vel = [-px / M, -py / M, -pz / M];
      return [star, giant, rock];
    },
  },

  // ==========================================================================
  // THE HABITABLE ZONE
  // --------------------------------------------------------------------------
  // Three identical planets — same mass, same radius, same albedo, same air —
  // at 0.55, 1.00 and 1.90 AU from the same star. Nothing about their
  // appearance is set. Each one works out its own insolation from where it is
  // (insolationAt() in sim/suns.js), turns that into a surface temperature, and
  // the ice line, the desert belts and the biomes follow:
  //
  //     S = L / r²   →  T_eq = 278.6 K · (L/r²)^¼ · (1-A)^¼
  //
  //   0.55 AU  S = 3.31 S⊕   T_eq = 344 K  — water cannot stay liquid; runaway
  //   1.00 AU  S = 1.00 S⊕   T_eq = 255 K  — 288 K with the greenhouse
  //   1.90 AU  S = 0.28 S⊕   T_eq = 185 K  — frozen from pole to pole
  //
  // The zone is not a line on a diagram. It is where those three numbers put
  // you, and moving a planet in flight (the live editor is right there) moves
  // its ice caps within a second.
  // ==========================================================================
  edu_habitable: {
    sky: { env: 'disc', tilt: 0.36, roll: 0.7 },
    name: 'The habitable zone',
    blurb: 'Three identical planets at 0.55, 1.0 and 1.9 AU from the same star. Identical: same mass, same radius, same albedo, same atmosphere. Nothing about how they look is set anywhere — each one computes the sunlight falling on it from where it actually is, turns that into a surface temperature, and its ice caps, its deserts and its vegetation follow. One of them is a furnace, one is frozen, and the one in between is not special in any way except its distance.',
    // The exaggeration is heavy here and it has to be: this is a COMPARISON,
    // and at true scale three Earths spread over 1.35 AU are three points of
    // light with no visible surfaces to compare. sceneScale is low enough that
    // all three orbits fit in one frame at once, which is the other half of
    // the comparison.
    sceneScale: 8, bodyScale: 3.0, camRadius: 22, lensing: false, mesh: false,
    timeScale: 0.25, maxStep: 1e-3,
    build() {
      const M = 1.0;
      const sun = { type: 'star', name: 'Sun', mass: M, radiusSun: 1.0, teff: 5772, luminosity: 1.0,
        color: 0xfff2cc, glow: 0xffaa33, pos: [0, 0, 0], vel: [0, 0, 0] };
      const world = (name, a, angle) => orbiter(M, a, {
        type: 'planet', name, mass: 3.0035e-6, radiusKm: 6371,
        atmosphere: true, land: 0.29, biota: 1, albedo: 0.306, greenhouse: 0.61,
        obliquity: 23.44 * DEG, cloudCover: 0.44, season: 11,
      }, angle);
      return [sun, world('Scorched', 0.55, 0.4), world('Temperate', 1.00, 2.6), world('Frozen', 1.90, 4.6)];
    },
  },

  // ==========================================================================
  // A BLACK HOLE WITH NOTHING AROUND IT
  // --------------------------------------------------------------------------
  // No disc, no companion, no debris: a black hole is not a thing you can see,
  // it is a place where the sky is missing. What is left in the frame is the
  // shadow (2.6 Schwarzschild radii in radius, not 1 — light that grazes closer
  // than the photon sphere at 1.5 r_s is captured), the photon ring at its
  // edge, and the Einstein ring of whatever is directly behind.
  //
  // The star field behind it is analytic and filtered through the screen-space
  // Jacobian precisely so this works: magnification near the ring is unbounded,
  // and any baked sky texture turns those arcs into smears.
  // ==========================================================================
  edu_hole: {
    sky: { env: ['halo', 'disc'], tilt: 0.26, roll: 2.7 },
    name: 'A black hole, alone',
    discIntensity: 0,
    blurb: 'Eight solar masses and nothing else in the frame. There is nothing to see here in the ordinary sense — a black hole emits nothing — so everything you can see is the sky BEHIND it being bent. The dark disc is the shadow, and it is 5.2 Schwarzschild radii across rather than 2, because any light that comes closer than the photon sphere at 1.5 r_s spirals in. The bright circle round it is the photon ring: light that went most of the way round and came back out. Turn the accretion disc up and the same geometry shows you the far side of the disc over the top of the hole.',
    sceneScale: 2.4, bodyScale: 1.0, camRadius: 26, lensing: true, mesh: false,
    timeScale: 0.4,
    build() {
      return [{ type: 'bh', name: 'Hole', mass: 8, rs: 0.5, pos: [0, 0, 0], vel: [0, 0, 0] }];
    },
  },

  // ==========================================================================
  // THE SKY FROM INSIDE THE GALAXY
  // --------------------------------------------------------------------------
  // Nothing in the scene at all. The lesson IS the background: the Milky Way is
  // a flat disc and we are in it, two thirds of the way out, so it is not an
  // object in our sky — it is a BAND round the whole sky, and its thickness is
  // the disc's scale height seen edge-on from inside.
  //
  // Everything in sim/sky.js is band-aware, which is what makes the multi-
  // wavelength lesson possible from this one scenario: the dust that blocks the
  // galactic centre in visible light is what glows in the infrared, and the
  // non-thermal populations take over entirely in radio and gamma.
  // ==========================================================================
  edu_galaxy: {
    sky: { env: 'disc', tilt: 0.0, roll: 0.9 },
    name: 'The Milky Way, from inside it',
    blurb: 'An empty scene: everything here is the sky itself. The Milky Way is a disc about 100 000 light years across and 1000 thick, and we are inside it — so it is not an object we look at, it is a band that goes all the way round us, and its narrowness is the disc seen edge-on. The dark lanes splitting it are not gaps, they are dust in the way. Change the imaging band and that same dust becomes the brightest thing in the sky.',
    sceneScale: 2.0, bodyScale: 1.0, camRadius: 12, lensing: false, mesh: false,
    timeScale: 0.1,
    build() { return []; },
  },

  edu_cluster: {
    sky: { env: ['globular', 'halo'], tilt: 0.4, roll: 1.7 },
    name: 'Inside a globular cluster',
    blurb: 'A million stars inside thirty light years, bound to each other and orbiting the galaxy as one object for twelve billion years. From in here the naked-eye sky holds tens of thousands of stars instead of three thousand, and the galaxy the cluster orbits is a distant object rather than a band overhead — because you are outside the disc looking back at it. Globulars are the oldest things in the galaxy, which is why almost every star in one is either a red dwarf or a red giant: everything heavier has already died.',
    sceneScale: 2.0, bodyScale: 1.0, camRadius: 12, lensing: false, mesh: false,
    timeScale: 0.1,
    build() { return []; },
  },
};

export const EDU_ORDER = [
  'edu_seasons', 'edu_moon', 'edu_kepler', 'edu_habitable',
  'edu_starbirth', 'edu_sun', 'edu_lifecycle', 'edu_supernova', 'edu_pulsar',
  'edu_transit', 'edu_hole', 'edu_galaxy', 'edu_cluster',
];
