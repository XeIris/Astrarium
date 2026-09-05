// ============================================================================
// THE VEHICLE CATALOGUE
// ----------------------------------------------------------------------------
// Published numbers for vehicles that flew, and derived numbers for the two
// that did not. Nothing here is tuned for playability: a stage's Δv is computed
// from its own dry and propellant masses through the rocket equation, so if a
// vehicle cannot reach orbit in the sim it could not reach orbit.
//
// Sources are in docs/spaceflight-research.md. Masses in kg, thrust in N,
// lengths in m, Isp in seconds.
//
// `limits` are STRUCTURAL margins, not flown values, and the distinction is the
// point: a Saturn V flew a max-q of 34 kPa and a Falcon 9 flies about 30, but
// neither airframe fails there. The limit is where it does. So a good ascent
// profile stays well under its limit and a bad one finds it — which is exactly
// what should happen, and the sim will tell you which of the four modes broke
// the vehicle.
//
// One convention that matters everywhere below: `thrustVac` and the two Isp
// figures are the MEASURED per-engine values, and sea-level thrust is a derived
// consequence of ispSL rather than a second number that can drift out of sync
// with it (see sim/flight/rocketry.js's engineOutput). Where a source quotes a
// sea-level thrust, it has been used to back out ispSL and the pair is
// consistent by construction.
// ============================================================================

// ---------------------------------------------------------------------------
// ENGINES
//
// `throttleMin` is the real deep-throttle limit and it is a gameplay-shaping
// number, not a detail: a Merlin cannot go below 57%, which is why a nearly
// empty first stage cannot hover and must land by hoverslam. The Apollo DPS is
// the interesting one — it has a FORBIDDEN BAND between 60% and 92.5%, because
// sustained operation there eroded the throttle valve, so the descent guidance
// really does have to avoid it.
// ---------------------------------------------------------------------------
export const ENGINES = {
  F1: {
    name: 'F-1', prop: 'RP-1/LOX',
    thrustVac: 7770e3, ispSL: 263, ispVac: 304, throttleMin: 1, gimbal: 5.15,
    exitD: 3.53, plume: 'kerolox',
  },
  J2: {
    name: 'J-2', prop: 'LH2/LOX',
    thrustVac: 1033e3, ispSL: 200, ispVac: 421, throttleMin: 1, gimbal: 7.0,
    exitD: 2.01, plume: 'hydrolox',
  },
  MERLIN1D: {
    name: 'Merlin 1D', prop: 'RP-1/LOX',
    thrustVac: 932e3, ispSL: 282, ispVac: 311, throttleMin: 0.57, gimbal: 5.0,
    exitD: 0.92, plume: 'kerolox',
  },
  MVAC: {
    name: 'Merlin 1D Vacuum', prop: 'RP-1/LOX',
    thrustVac: 981e3, ispSL: 200, ispVac: 348, throttleMin: 0.39, gimbal: 5.0,
    exitD: 3.30, plume: 'kerolox',
  },
  RS25: {
    name: 'RS-25 (SSME)', prop: 'LH2/LOX',
    thrustVac: 2279e3, ispSL: 366, ispVac: 452.3, throttleMin: 0.67, gimbal: 10.5,
    maxThrottle: 1.09, exitD: 2.30, plume: 'hydrolox',
  },
  SRB_RSRM: {
    name: 'RSRM solid booster', prop: 'APCP solid',
    thrustVac: 14000e3, ispSL: 242, ispVac: 268, throttleMin: 1, gimbal: 8.0,
    // A solid follows its grain, not the throttle — see solidThrustFraction.
    solid: true, exitD: 3.75, plume: 'solid',
  },
  RAPTOR2: {
    name: 'Raptor 2', prop: 'CH4/LOX',
    thrustVac: 2394e3, ispSL: 327, ispVac: 347, throttleMin: 0.40, gimbal: 15.0,
    exitD: 1.30, plume: 'methalox',
  },
  RAPTOR_VAC: {
    name: 'Raptor Vacuum', prop: 'CH4/LOX',
    thrustVac: 2530e3, ispSL: 200, ispVac: 380, throttleMin: 0.40, gimbal: 0,
    exitD: 2.40, plume: 'methalox',
  },
  DPS: {
    name: 'LM Descent Engine', prop: 'Aerozine-50/N2O4',
    thrustVac: 45040, ispSL: 200, ispVac: 311, throttleMin: 0.10, gimbal: 6.0,
    // The valve-erosion band. Guidance must sit either below 0.60 or above 0.925.
    forbidden: [0.60, 0.925], exitD: 1.52, plume: 'hypergolic',
  },
  APS: {
    name: 'LM Ascent Engine', prop: 'Aerozine-50/N2O4',
    thrustVac: 15600, ispSL: 200, ispVac: 311, throttleMin: 1, gimbal: 0,
    exitD: 0.86, plume: 'hypergolic',
  },
  SPS: {
    name: 'Service Propulsion System', prop: 'Aerozine-50/N2O4',
    thrustVac: 91200, ispSL: 200, ispVac: 314, throttleMin: 1, gimbal: 6.0,
    exitD: 2.24, plume: 'hypergolic',
  },
  MLE: {
    name: 'Mars Descent Engine (MLE)', prop: 'Hydrazine',
    // The eight MLEs are fixed, but they are individually throttleable and the
    // stage steers by differential throttle. That is a torque about the same
    // axes a gimbal would give, so it is modelled as an equivalent deflection —
    // without it the descent stage has no attitude authority at all and thrusts
    // in whatever direction the entry left it pointing.
    thrustVac: 3060, ispSL: 200, ispVac: 210, throttleMin: 0.20, gimbal: 5,
    exitD: 0.20, plume: 'hypergolic',
  },
  NEXT_ION: {
    name: 'NEXT gridded ion', prop: 'Xenon',
    // 237 mN at 6.9 kW, Isp 4190 s. Four orders of magnitude below a Merlin, and
    // that is the whole character of the vehicle it flies on.
    thrustVac: 0.237, ispSL: 4190, ispVac: 4190, throttleMin: 0.10, gimbal: 2.0,
    electric: true, powerW: 6900, exitD: 0.36, plume: 'ion',
  },
  SPIN_DRIVE: {
    name: 'Astrophage spin drive', prop: 'Astrophage',
    // A PHOTON ROCKET, and derived rather than invented. The book puts a gram of
    // astrophage at ~9e13 J, i.e. 9e16 J/kg — which is c² to two figures, so
    // astrophage is a perfect mass-to-energy converter. A drive that turns fuel
    // fully into light carries away momentum E/c = mc, so its exhaust velocity
    // is exactly c and its specific impulse is c/g₀ = 3.06e7 s.
    //
    // Thrust is not a constant here: the drive is throttled to hold a constant
    // PROPER acceleration (1.5 g in the book), so vessel.js sets F = m·a each
    // step and takes ṁ = F/c. See sim/flight/relativity.js.
    thrustVac: 3.1e7, ispSL: 3.0570e7, ispVac: 3.0570e7, throttleMin: 0.001,
    gimbal: 0, photon: true, holdAccel: 1.5 * 9.80665, exitD: 4.0, plume: 'spin',
  },
  BEETLE_DRIVE: {
    name: 'Beetle spin drive', prop: 'Astrophage',
    thrustVac: 1.4e5, ispSL: 3.0570e7, ispVac: 3.0570e7, throttleMin: 0.001,
    gimbal: 0, photon: true, holdAccel: 1.5 * 9.80665, exitD: 0.9, plume: 'spin',
  },
  DRACO: {
    name: 'Draco RCS', prop: 'MMH/NTO',
    thrustVac: 400, ispSL: 150, ispVac: 300, throttleMin: 0.05, gimbal: 0,
    exitD: 0.09, plume: 'hypergolic',
  },
};

// ---------------------------------------------------------------------------
// A helper so a stage reads as a table row rather than as an object literal.
// `look` is the only field the physics ignores: it is what craftmodel.js builds
// the mesh from, and it is kept beside the masses so a stage cannot be described
// twice in two places and disagree with itself.
// ---------------------------------------------------------------------------
const stage = (o) => ({
  gimbalDeg: o.engine?.gimbal ?? 0,
  sep: 'jettison',
  ...o,
  // Reference area for drag: the stage's own frontal area unless something
  // wider is stacked on it. The vessel takes the maximum over live stages.
  area: o.area ?? Math.PI * (o.D / 2) ** 2,
});

// ============================================================================
// VEHICLES
// ============================================================================
export const VEHICLES = {

  // --------------------------------------------------------------------------
  // SATURN V — the expendable superheavy. Three stages, and the only vehicle
  // here whose third stage restarts to leave Earth entirely.
  // --------------------------------------------------------------------------
  saturnv: {
    id: 'saturnv', name: 'Saturn V / Apollo', role: 'launch', launchFrom: 'Earth',
    era: '1967–1973',
    blurb: 'Three stages, 2 970 t on the pad, 111 m tall. The S-IVB restarts for translunar injection; the CSM and LM ride under the fairing.',
    limits: { maxQ: 42e3, maxG: 4.5, qAlpha: 5e3, heatLoad: 0 },
    target: { apoapsis: 185e3, inclination: 32.5 },
    stages: [
      stage({ key: 'sic', name: 'S-IC', dry: 137000, prop: 2077000,
        engine: ENGINES.F1, count: 5, L: 42.0, D: 10.06,
        look: { skin: 'white', pattern: 'saturn', fins: 4, interstage: 3.5 } }),
      stage({ key: 'sii', name: 'S-II', dry: 36200, prop: 443000,
        engine: ENGINES.J2, count: 5, L: 24.9, D: 10.06,
        rcs: { thrust: 3300, isp: 190, prop: 400, count: 8 },
        look: { skin: 'white', interstage: 5.5 } }),
      stage({ key: 'sivb', name: 'S-IVB', dry: 13500, prop: 109500,
        engine: ENGINES.J2, count: 1, L: 17.8, D: 6.60, restarts: 1,
        // The auxiliary propulsion modules — also what settles the propellant
        // before the restart for translunar injection.
        rcs: { thrust: 654, isp: 274, prop: 250, count: 6 },
        look: { skin: 'white', band: 'black', aftSkirt: true } }),
      stage({ key: 'csm', name: 'CSM "Columbia"', dry: 11900, prop: 18410,
        engine: ENGINES.SPS, count: 1, L: 11.0, D: 3.9, sep: 'none',
        rcs: { thrust: 445, isp: 290, prop: 550, count: 16 },
        look: { skin: 'metal', capsule: true, dish: true, radiators: true } }),
    ],
    // Carried inside the spacecraft-LM adapter and extracted after TLI. It is a
    // vehicle in its own right (see `lm`), listed here so the stack has its mass.
    carries: { vehicle: 'lm', mass: 15200, at: 'sivb' },
  },

  // --------------------------------------------------------------------------
  // FALCON 9 BLOCK 5 — the working reusable launcher. The first stage is the
  // interesting object: it separates at ~65 km with a third of its Δv still in
  // the tanks, and spends it on coming back.
  // --------------------------------------------------------------------------
  falcon9: {
    id: 'falcon9', name: 'Falcon 9 Block 5', role: 'launch', launchFrom: 'Earth',
    era: '2018–',
    blurb: 'Nine Merlins, a recoverable first stage with grid fins and legs, and a hoverslam that has to be solved for rather than scripted — minimum throttle gives TWR > 1, so it cannot hover.',
    limits: { maxQ: 45e3, maxG: 6.0, qAlpha: 5e3, heatLoad: 180e6 },
    target: { apoapsis: 200e3, inclination: 28.5 },
    stages: [
      stage({ key: 'f9s1', name: 'Stage 1', dry: 22200, prop: 411000,
        engine: ENGINES.MERLIN1D, count: 9, L: 41.2, D: 3.66,
        recover: 'droneship', gridFins: 4, legs: 4,
        // The landing legs are rated well above Apollo's, because a hoverslam
        // arrives with no margin and the vehicle has to survive being a little
        // late rather than being written off by it.
        gear: { vVert: 6.0, vHoriz: 2.0 },
        rcs: { thrust: 400, isp: 70, prop: 400, count: 8 },
        // Reserve held back for boostback, entry and landing. Not invented: it
        // is what a droneship profile actually keeps, ~8% of the load.
        reserve: 0.08,
        look: { skin: 'white', soot: true, octaweb: true, interstage: 4.0 } }),
      stage({ key: 'f9s2', name: 'Stage 2', dry: 4000, prop: 111500,
        engine: ENGINES.MVAC, count: 1, L: 13.8, D: 3.66, restarts: 2,
        // Cold-gas nitrogen thrusters. Without attitude control that does not
        // need the main engine, an upper stage cannot point at the burn it has
        // to make — the gimbal only has authority while it is already thrusting.
        rcs: { thrust: 220, isp: 70, prop: 400, count: 8 },
        look: { skin: 'white', nozzleExt: true } }),
      stage({ key: 'f9fair', name: 'Payload fairing', dry: 1900, prop: 0,
        engine: null, count: 0, L: 13.1, D: 5.2, sep: 'fairing',
        // Free-molecular heating below ~1135 W/m² is the real criterion, not an
        // altitude — so a lofted ascent sheds it earlier, as it should.
        jettisonAt: { heat: 1135 },
        look: { fairing: true } }),
      stage({ key: 'f9pl', name: 'Payload', dry: 13000, prop: 0,
        engine: null, count: 0, L: 5.0, D: 3.4, sep: 'none',
        look: { satellite: true } }),
    ],
  },

  // --------------------------------------------------------------------------
  // SPACE SHUTTLE — the winged one, and the only stack here that is not a
  // stack: the orbiter's engines light on the pad and burn all the way to
  // cutoff, fed from a tank it throws away.
  // --------------------------------------------------------------------------
  shuttle: {
    id: 'shuttle', name: 'Space Shuttle', role: 'launch', launchFrom: 'Earth',
    era: '1981–2011',
    blurb: 'Two solids that cannot be shut down, three engines fed from a tank that is not part of the orbiter, and a wing that only matters for the last twenty minutes of the mission.',
    limits: { maxQ: 45e3, maxG: 3.2, qAlpha: 4e3, heatLoad: 900e6 },
    target: { apoapsis: 300e3, inclination: 51.6 },
    stages: [
      stage({ key: 'srb', name: 'SRB pair', dry: 172000, prop: 1004000,
        engine: ENGINES.SRB_RSRM, count: 2, L: 45.5, D: 3.71, liftoff: true,
        // A solid cannot be throttled or shut down. Once lit, it burns out.
        look: { skin: 'white', srb: true, chutes: 3 } }),
      stage({ key: 'et', name: 'External Tank + SSME', dry: 26500, prop: 719000,
        engine: ENGINES.RS25, count: 3, L: 46.9, D: 8.40,
        // The SSMEs light on the pad alongside the solids and keep burning for
        // six minutes after they are gone. This is the one stack here that is
        // not a stack, and `liftoff` is what says so.
        liftoff: true, engineOn: 'orbiter',
        rcs: { thrust: 3870, isp: 289, prop: 800, count: 44 },
        look: { skin: 'foam', tank: true } }),
      stage({ key: 'orbiter', name: 'Orbiter + payload', dry: 99000, prop: 10800,
        engine: ENGINES.SPS, count: 2, L: 37.2, D: 5.6, sep: 'none',
        wings: { span: 23.8, area: 250, clMax: 1.4 },
        rcs: { thrust: 3870, isp: 289, prop: 1460, count: 44 },
        look: { skin: 'tiles', orbiter: true } }),
    ],
  },

  // --------------------------------------------------------------------------
  // SUPER HEAVY / STARSHIP — both halves come back, which makes it the only
  // vehicle here with two landings per flight.
  // --------------------------------------------------------------------------
  starship: {
    id: 'starship', name: 'Starship / Super Heavy', role: 'launch', launchFrom: 'Earth',
    era: '2023–',
    blurb: '33 Raptors under 3 400 t of methalox. Both stages return: the booster to the tower, the ship belly-first through the atmosphere and then flipped upright in the last seconds.',
    limits: { maxQ: 45e3, maxG: 4.0, qAlpha: 6e3, heatLoad: 1.4e9 },
    target: { apoapsis: 250e3, inclination: 28.5 },
    stages: [
      stage({ key: 'sh', name: 'Super Heavy', dry: 275000, prop: 3400000,
        engine: ENGINES.RAPTOR2, count: 33, L: 71.0, D: 9.0,
        recover: 'tower', gridFins: 4, reserve: 0.06,
        rcs: { thrust: 8000, isp: 80, prop: 3000, count: 8 },
        look: { skin: 'steel', hotStage: true } }),
      stage({ key: 'ss', name: 'Starship', dry: 120000, prop: 1200000,
        engine: ENGINES.RAPTOR2, count: 3, vacEngine: ENGINES.RAPTOR_VAC, vacCount: 3,
        L: 52.0, D: 9.0, recover: 'tower', restarts: 3,
        rcs: { thrust: 6000, isp: 300, prop: 2000, count: 12 },
        flaps: 4, heatShield: { area: 400, ablator: false, tiles: true },
        look: { skin: 'steel', tiles: true, nosecone: true } }),
    ],
  },

  // --------------------------------------------------------------------------
  // APOLLO LM — the lander, and the only crewed vehicle ever built that could
  // not fly in an atmosphere at all.
  // --------------------------------------------------------------------------
  lm: {
    id: 'lm', name: 'Apollo Lunar Module', role: 'lander', launchFrom: 'Moon',
    era: '1969–1972', airless: true,
    blurb: 'Two stages: a throttleable descent stage that lands, and an ascent stage that uses it as a launch pad. Descent follows the real P63 / P64 / P66 program sequence and its published gate conditions.',
    limits: { maxQ: 1e9, maxG: 6, qAlpha: 1e9, heatLoad: 0 },
    stages: [
      stage({ key: 'des', name: 'Descent stage', dry: 2134, prop: 8248,
        engine: ENGINES.DPS, count: 1, L: 3.05, D: 4.27, legs: 4,
        gear: { vVert: 3.0, vHoriz: 1.2 },       // the qualified Apollo rating
        rcs: { thrust: 445, isp: 290, prop: 287, count: 16 },
        look: { skin: 'mli-gold', octagon: true, legs: true, ladder: true } }),
      stage({ key: 'asc', name: 'Ascent stage', dry: 2150, prop: 2376,
        engine: ENGINES.APS, count: 1, L: 3.76, D: 4.29, sep: 'none',
        rcs: { thrust: 445, isp: 290, prop: 287, count: 16 },
        look: { skin: 'mli-gold', cabin: true, windows: 2, dish: true } }),
    ],
    // Apollo's own descent program, with the gate conditions from LUMINARY 1A.
    descent: {
      pdi:    { alt: 15240, vHoriz: 1697, range: 457000 },
      hiGate: { alt: 2377, range: 7000, vVert: -45, vHoriz: 129 },
      loGate: { alt: 30, range: 11 },
      touchdown: { vVert: -1.0, vHoriz: 0.5 },
    },
  },

  // --------------------------------------------------------------------------
  // MARS SKY CRANE — an aeroshell, a supersonic parachute, a rocket-powered
  // descent stage and a rover on cables. Four separations in seven minutes.
  // --------------------------------------------------------------------------
  skycrane: {
    id: 'skycrane', name: 'Mars EDL — Sky Crane', role: 'lander', launchFrom: 'Mars',
    era: '2012, 2021',
    blurb: 'Entry at 5.8 km/s behind a heat shield, a supersonic chute at Mach 1.7, then a descent stage that lowers the rover on cables and flies away to crash somewhere else.',
    // A Mars entry really does peak near 15 g — Curiosity's did — so the
    // structural limit has to be above the nominal entry, not at it.
    limits: { maxQ: 22e3, maxG: 20, qAlpha: 8e3, heatLoad: 120e6 },
    stages: [
      stage({ key: 'shell', name: 'Aeroshell', dry: 600, prop: 0,
        engine: null, count: 0, L: 2.7, D: 4.5, sep: 'jettison',
        blunt: true, heatShield: { area: 15.9, ablator: true, mass: 385, noseR: 1.125 },
        // An offset centre of mass trims the capsule to a lifting attitude.
        // L/D 0.24 is the flown value for the MSL aeroshell.
        lift: { LD: 0.24 },
        chute: { area: 200, deployMach: 1.7, deployQ: 750, Cd: 0.62 },
        look: { skin: 'ablator', aeroshell: true } }),
      stage({ key: 'desc', name: 'Descent stage', dry: 829, prop: 390,
        engine: ENGINES.MLE, count: 8, L: 2.0, D: 3.2, sep: 'skycrane',
        rcs: { thrust: 60, isp: 220, prop: 25, count: 8 },
        look: { skin: 'metal', skycrane: true } }),
      stage({ key: 'rover', name: 'Rover', dry: 1025, prop: 0,
        engine: null, count: 0, L: 2.2, D: 2.7, sep: 'none',
        // The six wheels ARE the landing gear — the rover is lowered onto them
        // on cables and they take the touchdown load. It has no other legs.
        legs: 6, gear: { vVert: 3.0, vHoriz: 1.0 },
        look: { skin: 'metal', rover: true, rtg: true } }),
    ],
    edl: {
      entry:      { alt: 125000, v: 5800, fpa: -15.5 },
      chute:      { mach: 1.7, altMax: 11000 },
      shieldJett: { alt: 8000 },
      backshell:  { alt: 1800, v: 100 },
      skycrane:   { alt: 20, cable: 7.5, vTouch: -0.75 },
    },
  },

  // --------------------------------------------------------------------------
  // ION CRUISER — the interplanetary workhorse. 237 mN and months of burn: it
  // is the vehicle that makes the warp ladder necessary.
  // --------------------------------------------------------------------------
  ioncruiser: {
    id: 'ioncruiser', name: 'Ion Cruiser (Dawn-class)', role: 'cruiser', launchFrom: null,
    era: '2007–',
    blurb: 'Three NEXT gridded ion engines and 425 kg of xenon. A quarter of a newton of thrust — a tenth the weight of a postcard — held for months at a time, which is why it can visit two main-belt worlds on one tank.',
    limits: { maxQ: 200, maxG: 1.2, qAlpha: 100, heatLoad: 0 },
    stages: [
      stage({ key: 'bus', name: 'Spacecraft bus', dry: 747, prop: 425,
        engine: ENGINES.NEXT_ION, count: 3, L: 2.36, D: 1.64, sep: 'none',
        rcs: { thrust: 0.9, isp: 220, prop: 45, count: 12 },
        solar: { span: 19.7, area: 36.4, powerAU: 10000 },
        look: { skin: 'mli-gold', bus: true, arrays: 2, dish: true } }),
    ],
  },

  // --------------------------------------------------------------------------
  // HAIL MARY — the interstellar ship, built from the book and the 2026 film.
  //
  // The one performance number worth deriving here, because it decides whether
  // the whole mission is possible: the book puts a gram of astrophage at ~9e13 J,
  // which is 9e16 J/kg — c² to two figures. So the spin drive converts fuel
  // completely into light and its exhaust velocity is exactly c, giving a total
  // available rapidity of ln(mass ratio) = ln(21) = 3.05 on 2 000 t of fuel and
  // a 100 t ship.
  //
  // That is NOT enough for a flip-and-burn crossing of the 11.9 ly to Tau Ceti,
  // which needs rapidity 6.03 at 1.5 g. It IS enough for accelerate–coast–
  // decelerate, which is what the ship actually does: burn to rapidity 1.52
  // (0.909 c, γ = 2.39), coast 10.1 ly, and turn over. That profile takes
  //     13.9 years of Earth time and 6.6 years of ship time
  // — and thirteen years is exactly what the book says the outbound trip takes.
  // The mission planner in guidance.js solves for the coast fraction rather than
  // assuming one, so this comes out of the numbers instead of being asserted.
  // --------------------------------------------------------------------------
  hailmary: {
    id: 'hailmary', name: 'Hail Mary', role: 'interstellar', launchFrom: null,
    era: 'Project Hail Mary',
    blurb: 'Three parallel astrophage tanks, a pressure vessel forward of them, and a nose that holds four beetles. Photon drive at 1.5 g, 2 000 t of fuel — enough to reach Tau Ceti in thirteen Earth years and six and a half aboard.',
    limits: { maxQ: 1e9, maxG: 4, qAlpha: 1e9, heatLoad: 0 },
    stages: [
      stage({ key: 'hm', name: 'Hail Mary', dry: 100000, prop: 2000000,
        engine: ENGINES.SPIN_DRIVE, count: 3, L: 47.0, D: 12.0, sep: 'none',
        rcs: { thrust: 2200, isp: 300, prop: 900, count: 16 },
        centrifuge: false,
        look: { skin: 'panel-white', hailmary: true, tanks: 3, beetles: 4, radiators: 4 } }),
    ],
    // The mission the ship was built for. Distances in light years.
    missions: [
      { name: 'Tau Ceti', ly: 11.9, accel: 1.5 },
      { name: 'Proxima Centauri', ly: 4.246, accel: 1.5 },
      { name: '40 Eridani', ly: 16.3, accel: 1.5 },
    ],
  },

  // --------------------------------------------------------------------------
  // BEETLE — the data-return probe. Four of them ride in the Hail Mary's nose;
  // their only job is to be small enough that the mass ratio works for the trip
  // home, which the mothership's does not.
  // --------------------------------------------------------------------------
  beetle: {
    id: 'beetle', name: 'Beetle probe', role: 'interstellar', launchFrom: null,
    era: 'Project Hail Mary',
    blurb: 'A one-way courier: no crew, no life support, and a mass ratio the Hail Mary itself cannot reach. It is the only part of the mission that was always going to make it home.',
    limits: { maxQ: 1e9, maxG: 20, qAlpha: 1e9, heatLoad: 0 },
    stages: [
      stage({ key: 'beetle', name: 'Beetle', dry: 850, prop: 20000,
        engine: ENGINES.BEETLE_DRIVE, count: 1, L: 4.2, D: 2.4, sep: 'none',
        rcs: { thrust: 40, isp: 240, prop: 30, count: 8 },
        look: { skin: 'panel-white', beetle: true } }),
    ],
  },
};

export const VEHICLE_ORDER = [
  'saturnv', 'falcon9', 'shuttle', 'starship', 'lm', 'skycrane',
  'ioncruiser', 'hailmary', 'beetle',
];

// ---------------------------------------------------------------------------
// Ideal Δv of a whole vehicle, stage by stage, from the rocket equation.
// Nothing stores this — it is derived, so editing a mass anywhere above changes
// it and the HUD immediately says so.
//
// Each stage carries everything above it, which is what makes the first stage's
// Δv small and the last stage's large despite the first holding 90% of the
// propellant. `pa` lets the caller ask for the sea-level or vacuum answer.
// ---------------------------------------------------------------------------
import { G0, ispAt } from './rocketry.js';

export function stageDeltaV(vehicle, index, pa = 0, extraPayload = 0) {
  const st = vehicle.stages;
  let above = extraPayload;
  for (let i = index + 1; i < st.length; i++) above += st[i].dry + st[i].prop;
  const s = st[index];
  if (!s.engine || s.prop <= 0) return 0;
  // Parallel boosters burn alongside the stage above them, so their propellant
  // is not available to it; serial stages carry theirs whole.
  const m0 = s.dry + s.prop + above;
  const m1 = s.dry + above + (s.reserve ? s.prop * s.reserve : 0);
  const ve = G0 * ispAt(s.engine, pa);
  return ve * Math.log(m0 / Math.max(m1, 1));
}

export function totalDeltaV(vehicle, extraPayload = 0) {
  // First stage at sea level (it spends most of its burn in air), everything
  // above it in vacuum. This is the standard way the number is quoted and it is
  // within a few percent of an integrated ascent.
  return vehicle.stages.reduce(
    (a, _, i) => a + stageDeltaV(vehicle, i, i === 0 ? 101325 * 0.4 : 0, extraPayload), 0);
}

export function grossMass(vehicle, extraPayload = 0) {
  return vehicle.stages.reduce((a, s) => a + s.dry + s.prop, extraPayload);
}

// Thrust-to-weight on the pad. Below 1.0 the vehicle does not move; a real
// launcher sits between 1.2 and 1.5, because anything higher wastes propellant
// fighting drag and anything lower wastes it fighting gravity.
export function padTWR(vehicle, gSurf = 9.80665, extraPayload = 0, pa = 101325) {
  return liftoffThrust(vehicle, pa) / (grossMass(vehicle, extraPayload) * gSurf);
}

// Sea-level thrust of everything that is lit at T-0. Used by the HUD and by the
// launch check, which refuses to release the hold below TWR 1.0 — a real
// constraint that a vehicle edited in the Foundry can genuinely fail.
export function liftoffThrust(vehicle, pa = 101325) {
  let F = 0;
  vehicle.stages.forEach((s, i) => {
    if (!s.engine || !(i === 0 || s.liftoff)) return;
    const mdot = s.engine.thrustVac / (G0 * s.engine.ispVac);
    F += mdot * s.count * G0 * ispAt(s.engine, pa);
  });
  return F;
}
