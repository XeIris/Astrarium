// ============================================================================
// ROCKETRY — propulsion, atmosphere, aerodynamics and the environment a vessel
// flies through.
//
// UNITS. This is the one part of the sim that is NOT in AU/M☉/yr. A rocket is a
// metres-and-seconds object: an ascent lasts 500 s (1.6e-5 yr) and reaches
// 200 km (1.3e-6 AU), so expressing it in the orrery's units throws away most
// of a float's mantissa before the first step. Everything here is SI, and
// sim/flight/vessel.js is the only place the two systems meet.
//
// The bridge is exact rather than fitted. The orrery's G = 4π² AU³/M☉/yr² and
// the SI GM☉ = 1.32712440018e20 m³/s² are the same constant:
//     4π² · (1.495978707e11)³ / (3.15576e7)²  =  1.3273e20
// so nothing is rescaled on the way across, only re-expressed.
//
// The physics implemented here:
//   · Thrust as ṁ·g₀·Isp(p_a), with Isp interpolated linearly in ambient
//     pressure between the engine's published sea-level and vacuum values. The
//     endpoints are measured for every engine in vehicles.js; only the interior
//     is modelled, and the pressure term in F = ṁv_e + A_e(p_e − p_a) really is
//     linear in p_a, so the interpolation is the physics rather than a fudge.
//   · An exponential atmosphere, which is the standard first-order model for
//     trajectory work. Earth gets two layers because one scale height is ~15%
//     wrong at 12 km — which is exactly max-Q altitude, the one place it
//     matters.
//   · A transonic drag curve rather than a constant Cd. This is what puts
//     max-Q where it belongs (11–13 km, ~30 kPa on a Falcon 9 profile) instead
//     of wherever a constant happens to put it.
//   · Sutton–Graves stagnation heating, q̇ ∝ √(ρ/R_n)·v³. The cube is the whole
//     story of re-entry and it drives both the ablation budget and the plasma
//     sheath.
// ============================================================================

// ---- defined constants ------------------------------------------------------
export const G0      = 9.80665;             // m/s² — DEFINED, not local gravity
export const C_MS    = 299792458;           // m/s — defined
export const AU_M    = 1.495978707e11;      // m — defined
export const YR_S    = 365.25 * 86400;      // s — Julian year, as the orrery uses
export const GM_SUN  = 1.32712440018e20;    // m³/s² — the same G as sim/physics.js
export const M_EARTH_SUN = 3.00348959e-6;   // M⊕ in M☉
export const R_GAS   = 8.31446261815324;    // J/mol/K

// ============================================================================
// ATMOSPHERE
// ----------------------------------------------------------------------------
// A layer is either ISOTHERMAL — ρ = ρ_base·exp(−Δh/H) — or has a LAPSE RATE,
// in which case the barometric solution is a power law rather than an
// exponential: ρ = ρ_base·(1 − L·Δh/T_base)^(g·M/(R·L) − 1).
//
// Earth uses both, because the troposphere is where max-Q happens and a single
// exponential is 7% low on density at 11 km — which lands max-Q at the wrong
// altitude and understates the load. With the lapse-rate layer the model
// reproduces the US Standard Atmosphere to better than 1% from the ground to
// 20 km — the whole range that sets max-Q — and stays within ~15% out to 80 km,
// where q has already fallen under a pascal. The upper layers are fitted to the
// standard table's own density ratios rather than to a temperature profile,
// because it is the density the drag term actually asks for.
//
// `top` truncates the model. Above it drag is exactly zero, which is what makes
// an orbit an orbit instead of a slow spiral that costs frame time forever.
// ============================================================================

// Measured atmospheres, keyed by body name. Anything not listed is derived (see
// deriveAtmosphere) — measured beats modelled, as everywhere else in this repo.
const ATMOSPHERES = {
  Earth: {
    p0: 101325, rho0: 1.225, T0: 288.15, molar: 0.0289644, gamma: 1.4,
    layers: [
      { base: 0,     L: 0.0065, T: 288.15 },   // troposphere, the US Std lapse rate
      { base: 11000, H: 6341 },                // isothermal 216.65 K stratosphere
      { base: 32000, H: 7044 },                // upper stratosphere, warming
      { base: 50000, H: 7465 },                // mesosphere
    ],
    top: 140e3, tint: 0x4a7fd0, haze: 0x8fb6e8,
  },
  Mars: {
    // The standard exponential Mars model, H = 11.1 km, which is what every
    // entry-trajectory study uses. rho0 is not quoted separately: it follows
    // from the measured surface pressure and temperature through the gas law —
    // 610 Pa of CO2 at 210 K is 0.0151 kg/m3 — so the three numbers cannot
    // drift apart. Above 60 km the thermosphere warms and thins more slowly,
    // which is the second layer.
    //
    // The scale height is the whole reason a Mars entry is hard: it is a third
    // more than Earth's over a body a third the size, so the atmosphere is deep
    // enough to burn you and far too thin to stop you.
    p0: 610, rho0: 0.01514, T0: 210, molar: 0.04334, gamma: 1.29,
    layers: [{ base: 0, H: 11100 }, { base: 60000, H: 8000 }],
    top: 125e3, tint: 0xc08a5a, haze: 0xd8a878,
  },
  Venus: {
    p0: 9.2e6, rho0: 65.0, T0: 737, molar: 0.04345, gamma: 1.29,
    layers: [{ base: 0, L: 0.0081, T: 737 }, { base: 60000, H: 15900 }],
    top: 250e3, tint: 0xd8b46a, haze: 0xf0d9a0,
  },
  Titan: {
    p0: 146700, rho0: 5.4, T0: 94, molar: 0.02834, gamma: 1.4,
    layers: [{ base: 0, H: 21000 }], top: 600e3, tint: 0xc2924a, haze: 0xe8c481,
  },
  Jupiter: {
    p0: 1e5, rho0: 0.16, T0: 165, molar: 0.00226, gamma: 1.42,
    layers: [{ base: 0, H: 27000 }], top: 900e3, tint: 0xc9a882, haze: 0xe8d0aa,
  },
};

// A world the catalogue does not know. An atmosphere needs a source of gas and
// enough gravity to hold it, so the discriminator is the escape speed against
// the thermal speed of the gas — which is why the Moon has none and Titan, at a
// seventh of Earth's gravity but a third of its temperature, has more than we do.
function deriveAtmosphere(radiusM, gSurf, teqK) {
  const vEsc = Math.sqrt(2 * gSurf * radiusM);
  // Jeans escape: a species survives over the age of a system if v_esc ≳ 6·v_th.
  // N₂ (28 g/mol) is the reference species.
  const vTh = Math.sqrt(2 * R_GAS * Math.max(teqK, 30) / 0.028);
  const retain = vEsc / (6 * vTh);
  if (retain < 1) return null;                       // airless
  const p0 = Math.min(3e5, 1e5 * Math.pow(retain, 2.2));
  const H = R_GAS * teqK / (0.028 * Math.max(gSurf, 0.01));
  const rho0 = p0 * 0.028 / (R_GAS * Math.max(teqK, 30));
  return {
    p0, rho0, T0: teqK, molar: 0.028, gamma: 1.4,
    layers: [{ base: 0, H }], top: H * 14, tint: 0x6a8fc0, haze: 0xa8c4e0,
  };
}

// Walk the layer stack to `h`, returning { rho, T }. One pass gives both,
// because the temperature is what the layer structure is really describing and
// the density is its consequence.
function profile(atm, h) {
  if (!atm) return { rho: 0, T: 3 };
  if (h >= atm.top) return { rho: 0, T: atm.T0 * 0.55 };
  const hh = Math.max(h, 0);
  let rho = atm.rho0, T = atm.T0;
  for (let i = 0; i < atm.layers.length; i++) {
    const L = atm.layers[i];
    const next = atm.layers[i + 1];
    const topOfLayer = next ? next.base : Infinity;
    const dh = Math.min(hh, topOfLayer) - L.base;
    if (dh <= 0) break;
    if (L.L != null) {
      // Lapse-rate layer: T falls linearly, ρ follows the barometric power law.
      const n = G0 * atm.molar / (R_GAS * L.L) - 1;
      const f = Math.max(1 - L.L * dh / L.T, 1e-4);
      rho *= Math.pow(f, n);
      T = L.T * f;
    } else {
      rho *= Math.exp(-dh / L.H);
      // isothermal: T is whatever the layer below left it at
    }
    if (hh <= topOfLayer) break;
  }
  return { rho, T };
}

export function density(atm, h)     { return profile(atm, h).rho; }
export function temperature(atm, h) { return profile(atm, h).T; }

// p = ρRT/M — the ideal gas law, with both inputs coming from the same walk, so
// pressure and density can never disagree about which layer we are in.
export function pressure(atm, h) {
  if (!atm) return 0;
  const { rho, T } = profile(atm, h);
  return rho * R_GAS * T / atm.molar;
}
/**
 * Local density scale height (m) — the distance over which ρ falls by e.
 *
 * Exported because it is the natural step size for anything flying through the
 * air: an integrator that moves a large fraction of a scale height in one step
 * is evaluating the drag at an altitude the vehicle has already left. A lapse
 * layer has no stored H (its profile is a power law), so this returns the local
 * RT/Mg, which is what the exponential layers store anyway.
 */
export function scaleHeight(atm, h) {
  if (!atm) return Infinity;
  const L = atm.layers.filter(l => h >= l.base).pop() || atm.layers[0];
  if (L.H) return L.H;
  return R_GAS * temperature(atm, h) / (atm.molar * G0);
}

export function speedOfSound(atm, h) {
  if (!atm) return 1e9;                              // no medium ⇒ no Mach number
  return Math.sqrt(atm.gamma * R_GAS * temperature(atm, h) / atm.molar);
}

// ============================================================================
// AERODYNAMICS
// ============================================================================

// Drag coefficient against Mach number for a slender launch vehicle.
//
// This is a curve rather than a constant because the whole shape of an ascent
// depends on it: Cd nearly triples through the transonic region as the bow
// shock forms, which is what makes max-Q a sharp event you can hear the engines
// throttle for, and then falls away again so that the hypersonic part of the
// climb is cheap. A constant 0.3 removes the event entirely.
export function dragCoefficient(mach) {
  const M = Math.max(mach, 0);
  if (M < 0.8) return 0.30 + 0.05 * M * M;           // subsonic, slowly rising
  if (M < 1.1) return 0.32 + 1.45 * (M - 0.8);       // transonic rise to the peak
  if (M < 1.4) return 0.755 - 0.30 * (M - 1.1);      // just past the peak
  if (M < 4.0) return 0.665 - 0.148 * (M - 1.4);     // supersonic decay
  return Math.max(0.28 - 0.004 * (M - 4), 0.16);     // hypersonic floor
}

// Ballistic/blunt-body Cd — for capsules, aeroshells and a booster falling
// engines-first. A blunt body's drag is dominated by base pressure and barely
// moves with Mach, which is the entire reason re-entry vehicles are blunt.
export function bluntDragCoefficient(mach) {
  return mach > 1.2 ? 1.45 : 1.05 + 0.33 * Math.max(mach - 0.4, 0);
}

// Sutton–Graves stagnation-point convective heat flux (W/m²).
//   q̇ = k √(ρ/R_n) v³ ,  k = 1.7415e-4 in SI for air.
// The cube is the point: entry at 11 km/s (lunar return) heats eight times as
// hard as entry at 5.5 km/s (LEO), which is why one needs an ablator and the
// other needs tiles.
export const SUTTON_GRAVES_K = 1.7415e-4;
export function heatFlux(rho, v, noseRadiusM) {
  if (rho <= 0) return 0;
  return SUTTON_GRAVES_K * Math.sqrt(rho / Math.max(noseRadiusM, 0.05)) * v * v * v;
}

// ============================================================================
// ENGINES
// ----------------------------------------------------------------------------
// An engine is defined by its two MEASURED specific impulses and its vacuum
// thrust. Everything else follows.
// ============================================================================

// Effective Isp at ambient pressure p_a. Linear between the published endpoints;
// clamped below because a nozzle in a pressure higher than it was designed for
// separates rather than producing negative thrust.
export function ispAt(engine, pa) {
  const f = Math.min(Math.max(pa / 101325, 0), 1.4);
  return Math.max(engine.ispVac - (engine.ispVac - engine.ispSL) * f, engine.ispSL * 0.55);
}

// A solid motor's thrust is set by its grain geometry and cannot be commanded.
// The RSRM's grain is an 11-point star at the forward end tapering to a circle
// aft, and it is shaped so the thrust DROPS by about a third through the middle
// of the burn — which is what holds the Shuttle stack under max-q and under its
// g limit at a time when nothing aboard could throttle. Modelling a solid as a
// constant is the single biggest way to get a Shuttle ascent wrong.
//
// Fractions of the vacuum rating against fraction of propellant burned.
const RSRM_PROFILE = [
  [0.00, 0.86], [0.04, 1.00], [0.10, 0.94], [0.22, 0.78],
  [0.36, 0.66], [0.55, 0.74], [0.78, 0.72], [0.92, 0.52], [1.00, 0.18],
];
export function solidThrustFraction(burnedFrac, profile = RSRM_PROFILE) {
  const x = Math.min(Math.max(burnedFrac, 0), 1);
  for (let i = 1; i < profile.length; i++) {
    if (x <= profile[i][0]) {
      const [x0, y0] = profile[i - 1], [x1, y1] = profile[i];
      return y0 + (y1 - y0) * (x - x0) / Math.max(x1 - x0, 1e-9);
    }
  }
  return profile[profile.length - 1][1];
}
export { RSRM_PROFILE };

// Thrust (N) and propellant flow (kg/s) for `n` engines at a throttle setting.
//
// Mass flow is set by the vacuum figures and is INDEPENDENT of altitude — the
// turbopump does not know what the outside pressure is. Thrust then follows the
// pressure-dependent Isp. Getting this the wrong way round (scaling ṁ instead of
// F) makes a first stage burn its tanks dry early at sea level, which is a
// classic and very visible bug.
export function engineOutput(engine, n, pa, throttle, burnedFrac = 0) {
  let th = throttle <= 0 ? 0 : Math.min(Math.max(throttle, engine.throttleMin ?? 1), engine.maxThrottle ?? 1);
  // A solid ignores the throttle entirely and follows its grain.
  if (engine.solid) th = throttle > 0 ? solidThrustFraction(burnedFrac, engine.profile) : 0;
  if (th <= 0 || n <= 0) return { F: 0, mdot: 0, isp: engine.ispVac, throttle: 0 };
  const mdotVac = engine.thrustVac / (G0 * engine.ispVac);
  const isp = ispAt(engine, pa);
  const mdot = mdotVac * th * n;
  return { F: mdot * G0 * isp, mdot, isp, throttle: th };
}

// Burn time for a Δv from the rocket equation, at the CURRENT thrust and mass.
//   t = (m·g₀·Isp/F)·(1 − exp(−Δv/(g₀·Isp)))
// This is the exact answer for constant thrust and constant Isp, and it is what
// the node-execution autopilot centres its burn on.
export function burnTimeFor(dv, mass, thrustN, isp) {
  if (thrustN <= 0 || dv <= 0) return 0;
  const ve = G0 * isp;
  return (mass * ve / thrustN) * (1 - Math.exp(-dv / ve));
}

// ============================================================================
// FLIGHT ENVIRONMENT — one simulation body, expressed the way a rocket needs it
// ----------------------------------------------------------------------------
// Radii and rotation rates for the bodies you can actually launch from or land
// on. A preset that carries a measured radiusKm already has the radius; this
// adds the things the orrery has no reason to know: how fast the surface turns,
// what the ground looks like, and whether there is any air.
// ============================================================================
const SURFACES = {
  Earth:   { day: 86164.1,  albedo: 0.30, teq: 255, ground: 0x4a6b3f, rock: 0x6b5a45, sea: 0x1b3a6b, oceans: true },
  Moon:    { day: 2360591,  albedo: 0.12, teq: 270, ground: 0x8a8378, rock: 0x6e6860 },
  Mars:    { day: 88642.7,  albedo: 0.25, teq: 210, ground: 0xa8562f, rock: 0x7d4426 },
  Venus:   { day: -10087200, albedo: 0.77, teq: 737, ground: 0xb08040, rock: 0x8a5f30 },
  Mercury: { day: 5067360,  albedo: 0.14, teq: 440, ground: 0x8c8378, rock: 0x6b645c },
  Jupiter: { day: 35730,    albedo: 0.54, teq: 165, ground: 0xc9a882, rock: 0xa88a60 },
  Titan:   { day: 1377648,  albedo: 0.22, teq: 94,  ground: 0x9a7a3c, rock: 0x7a5f30 },
  Pluto:   { day: 551854,   albedo: 0.52, teq: 44,  ground: 0xa89484, rock: 0x8a7466 },
};

// Measured mean radii (km) for the moons and worlds a preset may not carry one
// for. Used only when the body itself has no radiusKm.
const RADII_KM = { Moon: 1737.4, Titan: 2574.7, Europa: 1560.8, Phobos: 11.27 };

/**
 * Everything a vessel needs to know about one body, in SI.
 *
 * `mu` is GM in m³/s², taken straight from the body's simulation mass, so a
 * planet whose mass was just dragged in the live editor immediately flies
 * differently — there is no second copy of the mass to fall out of sync.
 */
export function flightEnv(body) {
  const name = body.name;
  const massSun = body.mass;
  const mu = GM_SUN * massSun;
  // b.radius is in AU and comes from structureOf() or a measured radiusKm, so
  // it is the same radius the cross-section and the collision test use.
  const radius = (body.radius || 0) * AU_M
    || (RADII_KM[name] ? RADII_KM[name] * 1000 : 6.371e6);
  const surf = SURFACES[name] || {};
  const gSurf = mu / (radius * radius);
  const teq = surf.teq ?? 255;
  const atm = ATMOSPHERES[name] !== undefined
    ? ATMOSPHERES[name]
    : deriveAtmosphere(radius, gSurf, teq);
  const daySec = Math.abs(surf.day ?? (body.dayLength ? body.dayLength * YR_S : 86400));
  return {
    name, body, mu, radius, gSurf, atm,
    // Surface velocity at the equator — free Δv for an eastward launch, and the
    // reason Kourou exists. 465 m/s on Earth.
    rotRate: (surf.day && surf.day < 0 ? -1 : 1) * 2 * Math.PI / daySec,
    vRotEq: 2 * Math.PI * radius / daySec,
    daySec,
    ground: surf.ground ?? 0x7a7266, rock: surf.rock ?? 0x5f584f,
    oceans: !!surf.oceans, sea: surf.sea ?? 0x1b3a6b,
    // Escape speed and circular speed at the surface — the two numbers that say
    // what kind of place this is to fly from.
    vEsc: Math.sqrt(2 * mu / radius),
    vCirc: Math.sqrt(mu / radius),
    // Where "space" starts, for the purposes of the HUD and the rails interlock.
    karman: atm ? atm.top * 0.72 : 0,
  };
}

export { ATMOSPHERES, SURFACES };
