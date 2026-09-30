class_name Rocketry
extends RefCounted

# ROCKETRY: propulsion, atmosphere, aerodynamics and flight environment, in SI
# (vessel.gd is the only bridge to AU). The bridge is exact: G = 4π² AU³/M☉/yr² is
# GM☉ = 1.32712440018e20 m³/s², re-expressed.
#   · Thrust ṁ·g₀·Isp(p_a), Isp linear in ambient pressure between the measured
#     sea-level and vacuum values (the A_e(p_e − p_a) term is linear in p_a).
#   · Exponential atmospheres; Earth's troposphere is a lapse-rate layer so max-Q
#     lands at 11–13 km.
#   · A transonic drag curve, which makes max-Q a sharp event.
#   · Sutton–Graves stagnation heating, q̇ ∝ √(ρ/R_n)·v³.
# Plain data (atmospheres, engines, outputs, flight environments) are Dictionaries
# with camelCase keys, read by name.

# ---- defined constants ------------------------------------------------------
const G0 := 9.80665                 # m/s² — DEFINED, not local gravity
const C_MS := 299792458.0           # m/s — defined
const AU_M := 1.495978707e11        # m — defined
const YR_S := 365.25 * 86400.0      # s — Julian year, as the orrery uses
const GM_SUN := 1.32712440018e20    # m³/s² — the same G as sim/physics.gd
const M_EARTH_SUN := 3.00348959e-6  # M⊕ in M☉
const R_GAS := 8.31446261815324     # J/mol/K

# ATMOSPHERE. A layer is isothermal, ρ = ρ_base·exp(−Δh/H), or has a lapse rate,
# ρ = ρ_base·(1 − L·Δh/T_base)^(g·M/(R·L) − 1). Earth's lapse-rate troposphere
# matches the US Standard Atmosphere to 1% up to 20 km and ~15% to 80 km. Upper
# layers are fitted to the table's density ratios. Above `top` drag is exactly zero.

# Measured atmospheres by body name; anything else is derived (derive_atmosphere).
# `tint`/`haze` are sRGB hex (U.lin()).
const ATMOSPHERES := {
	"Earth": {
		"p0": 101325.0, "rho0": 1.225, "T0": 288.15, "molar": 0.0289644, "gamma": 1.4,
		"layers": [
			{ "base": 0.0,     "L": 0.0065, "T": 288.15 },   # troposphere, the US Std lapse rate
			{ "base": 11000.0, "H": 6341.0 },                # isothermal 216.65 K stratosphere
			{ "base": 32000.0, "H": 7044.0 },                # upper stratosphere, warming
			{ "base": 50000.0, "H": 7465.0 },                # mesosphere
		],
		"top": 140e3, "tint": 0x4a7fd0, "haze": 0x8fb6e8,
	},
	# The standard Mars model, H = 11.1 km. rho0 follows from 610 Pa of CO₂ at 210 K
	# (0.0151 kg/m³). A second layer above 60 km. Deep enough to burn you, too thin to
	# stop you.
	"Mars": {
		"p0": 610.0, "rho0": 0.01514, "T0": 210.0, "molar": 0.04334, "gamma": 1.29,
		"layers": [{ "base": 0.0, "H": 11100.0 }, { "base": 60000.0, "H": 8000.0 }],
		"top": 125e3, "tint": 0xc08a5a, "haze": 0xd8a878,
	},
	"Venus": {
		"p0": 9.2e6, "rho0": 65.0, "T0": 737.0, "molar": 0.04345, "gamma": 1.29,
		"layers": [{ "base": 0.0, "L": 0.0081, "T": 737.0 }, { "base": 60000.0, "H": 15900.0 }],
		"top": 250e3, "tint": 0xd8b46a, "haze": 0xf0d9a0,
	},
	"Titan": {
		"p0": 146700.0, "rho0": 5.4, "T0": 94.0, "molar": 0.02834, "gamma": 1.4,
		"layers": [{ "base": 0.0, "H": 21000.0 }], "top": 600e3, "tint": 0xc2924a, "haze": 0xe8c481,
	},
	"Jupiter": {
		"p0": 1e5, "rho0": 0.16, "T0": 165.0, "molar": 0.00226, "gamma": 1.42,
		"layers": [{ "base": 0.0, "H": 27000.0 }], "top": 900e3, "tint": 0xc9a882, "haze": 0xe8d0aa,
	},
	# ~1 Pa of N₂ (New Horizons). Listed because the Jeans test says only whether a
	# world keeps a gas, not how much it has: derived, Pluto would get 1.6 bar. The upper
	# layer is the measured ~100 K inversion.
	"Pluto": {
		"p0": 1.0, "rho0": 7.6e-5, "T0": 44.0, "molar": 0.028, "gamma": 1.4,
		"layers": [{ "base": 0.0, "H": 21000.0 }, { "base": 30000.0, "H": 50000.0 }],
		"top": 300e3, "tint": 0xa89484, "haze": 0xd8c4b4,
	},
}

## An uncatalogued world: escape speed against the gas's thermal speed decides
## whether it holds an atmosphere.
static func derive_atmosphere(radius_m: float, g_surf: float, teq_k: float):
	var v_esc := sqrt(2.0 * g_surf * radius_m)
	# Jeans escape: a species survives over the age of a system if v_esc ≳ 6·v_th.
	# N₂ (28 g/mol) is the reference species.
	var v_th := sqrt(2.0 * R_GAS * maxf(teq_k, 30.0) / 0.028)
	var retain := v_esc / (6.0 * v_th)
	if retain < 1.0: return null                       # airless
	var p0 := minf(3e5, 1e5 * pow(retain, 2.2))
	var H := R_GAS * teq_k / (0.028 * maxf(g_surf, 0.01))
	var rho0 := p0 * 0.028 / (R_GAS * maxf(teq_k, 30.0))
	return {
		"p0": p0, "rho0": rho0, "T0": teq_k, "molar": 0.028, "gamma": 1.4,
		"layers": [{ "base": 0.0, "H": H }], "top": H * 14.0, "tint": 0x6a8fc0, "haze": 0xa8c4e0,
	}

## Walk the layer stack to `h`, returning [rho, T].
static func profile(atm, h: float) -> Array:
	if atm == null: return [0.0, 3.0]
	if h >= atm.top: return [0.0, atm.T0 * 0.55]
	var hh := maxf(h, 0.0)
	var rho: float = atm.rho0
	var T: float = atm.T0
	var layers: Array = atm.layers
	var nl := layers.size()
	for i in nl:
		var L: Dictionary = layers[i]
		var top_of_layer: float = layers[i + 1].base if i + 1 < nl else INF
		var dh: float = minf(hh, top_of_layer) - L.base
		if dh <= 0.0: break
		if L.has("L"):
			# Lapse-rate layer: T falls linearly, ρ follows the barometric power law.
			var n: float = G0 * atm.molar / (R_GAS * L.L) - 1.0
			var f: float = maxf(1.0 - L.L * dh / L.T, 1e-4)
			rho *= pow(f, n)
			T = L.T * f
		else:
			rho *= exp(-dh / L.H)
			# isothermal: T is whatever the layer below left it at
		if hh <= top_of_layer: break
	return [rho, T]

static func density(atm, h: float) -> float:     return profile(atm, h)[0]
static func temperature(atm, h: float) -> float: return profile(atm, h)[1]

## p = ρRT/M — the ideal gas law, with both inputs coming from the same walk, so
## pressure and density can never disagree about which layer we are in.
static func pressure(atm, h: float) -> float:
	if atm == null: return 0.0
	var p := profile(atm, h)
	return p[0] * R_GAS * p[1] / atm.molar

## Local density scale height, m: the natural step size in air. For a lapse layer,
## the local RT/Mg.
static func scale_height(atm, h: float) -> float:
	if atm == null: return INF
	var L = null
	for l in atm.layers:
		if h >= l.base: L = l
	if L == null: L = atm.layers[0]
	if L.get("H", 0.0): return L.H
	return R_GAS * temperature(atm, h) / (atm.molar * G0)

static func speed_of_sound(atm, h: float) -> float:
	if atm == null: return 1e9                          # no medium ⇒ no Mach number
	return sqrt(atm.gamma * R_GAS * temperature(atm, h) / atm.molar)

# AERODYNAMICS

## Cd against Mach for a slender launcher: it nearly triples through the transonic
## region, then falls away.
static func drag_coefficient(mach: float) -> float:
	var M := maxf(mach, 0.0)
	if M < 0.8: return 0.30 + 0.05 * M * M           # subsonic, slowly rising
	if M < 1.1: return 0.32 + 1.45 * (M - 0.8)       # transonic rise to the peak
	if M < 1.4: return 0.755 - 0.30 * (M - 1.1)      # just past the peak
	if M < 4.0: return 0.665 - 0.148 * (M - 1.4)     # supersonic decay
	return maxf(0.28 - 0.004 * (M - 4.0), 0.16)      # hypersonic floor

## Blunt-body Cd (capsules, aeroshells, a booster falling engines first): nearly
## flat with Mach.
static func blunt_drag_coefficient(mach: float) -> float:
	return 1.45 if mach > 1.2 else 1.05 + 0.33 * maxf(mach - 0.4, 0.0)

## Sutton–Graves stagnation heat flux (W/m²):
##   q̇ = k √(ρ/R_n) v³,  k = 1.7415e-4 (SI, air)
## Lunar return at 11 km/s heats 8× as hard as LEO entry at 5.5.
const SUTTON_GRAVES_K := 1.7415e-4
static func heat_flux(rho: float, v: float, nose_radius_m: float) -> float:
	if rho <= 0.0: return 0.0
	return SUTTON_GRAVES_K * sqrt(rho / maxf(nose_radius_m, 0.05)) * v * v * v

# ENGINES: two measured Isps and a vacuum thrust; everything else follows.

## Effective Isp at p_a, linear between the endpoints, clamped below (an
## over-pressured nozzle separates).
static func isp_at(engine: Dictionary, pa: float) -> float:
	var f := minf(maxf(pa / 101325.0, 0.0), 1.4)
	return maxf(engine.ispVac - (engine.ispVac - engine.ispSL) * f, engine.ispSL * 0.55)

## A solid's thrust is set by its grain. The RSRM's thrust drops about a third
## mid-burn, holding the Shuttle under max-q and its g limit. Fractions of the vacuum
## rating against fraction burned; this curve burns out at ~127 s (RSRM action time
## 123.6 s).
const RSRM_PROFILE := [
	[0.00, 0.88], [0.04, 1.00], [0.10, 0.96], [0.22, 0.84],
	[0.36, 0.74], [0.55, 0.80], [0.78, 0.78], [0.92, 0.64], [1.00, 0.25],
]
static func solid_thrust_fraction(burned_frac: float, prof = null) -> float:
	var pr: Array = RSRM_PROFILE if prof == null else prof
	var x := minf(maxf(burned_frac, 0.0), 1.0)
	for i in range(1, pr.size()):
		if x <= pr[i][0]:
			var x0: float = pr[i - 1][0]; var y0: float = pr[i - 1][1]
			var x1: float = pr[i][0]; var y1: float = pr[i][1]
			return y0 + (y1 - y0) * (x - x0) / maxf(x1 - x0, 1e-9)
	return pr[pr.size() - 1][1]

## Thrust (N) and flow (kg/s) for `n` engines at a throttle: { F, mdot, isp, throttle }.
## ṁ comes from the vacuum figures and doesn't depend on altitude; thrust follows
## the pressure-dependent Isp.
static func engine_output(engine: Dictionary, n: float, pa: float, throttle: float, burned_frac: float = 0.0) -> Dictionary:
	var th: float = 0.0 if throttle <= 0.0 else minf(maxf(throttle, engine.get("throttleMin", 1.0)), engine.get("maxThrottle", 1.0))
	# A solid ignores the throttle entirely and follows its grain.
	if engine.get("solid", false):
		th = solid_thrust_fraction(burned_frac, engine.get("profile")) if throttle > 0.0 else 0.0
	if th <= 0.0 or n <= 0.0:
		return { "F": 0.0, "mdot": 0.0, "isp": engine.ispVac, "throttle": 0.0 }
	var mdot_vac: float = engine.thrustVac / (G0 * engine.ispVac)
	var isp := isp_at(engine, pa)
	var mdot := mdot_vac * th * n
	return { "F": mdot * G0 * isp, "mdot": mdot, "isp": isp, "throttle": th }

## Burn time for a Δv at the current thrust and mass:
##   t = (m·g₀·Isp/F)·(1 − exp(−Δv/(g₀·Isp)))
static func burn_time_for(dv: float, mass: float, thrust_n: float, isp: float) -> float:
	if thrust_n <= 0.0 or dv <= 0.0: return 0.0
	var ve := G0 * isp
	return (mass * ve / thrust_n) * (1.0 - exp(-dv / ve))

# FLIGHT ENVIRONMENT. Surface data the orrery doesn't carry: rotation, ground and air.
const SURFACES := {
	"Earth":   { "day": 86164.1,   "albedo": 0.30, "teq": 255.0, "ground": 0x4a6b3f, "rock": 0x6b5a45, "sea": 0x1b3a6b, "oceans": true },
	"Moon":    { "day": 2360591.0, "albedo": 0.12, "teq": 270.0, "ground": 0x8a8378, "rock": 0x6e6860 },
	"Mars":    { "day": 88642.7,   "albedo": 0.25, "teq": 210.0, "ground": 0xa8562f, "rock": 0x7d4426 },
	"Venus":   { "day": -10087200.0, "albedo": 0.77, "teq": 737.0, "ground": 0xb08040, "rock": 0x8a5f30 },
	"Mercury": { "day": 5067360.0, "albedo": 0.14, "teq": 440.0, "ground": 0x8c8378, "rock": 0x6b645c },
	"Jupiter": { "day": 35730.0,   "albedo": 0.54, "teq": 165.0, "ground": 0xc9a882, "rock": 0xa88a60 },
	"Titan":   { "day": 1377648.0, "albedo": 0.22, "teq": 94.0,  "ground": 0x9a7a3c, "rock": 0x7a5f30 },
	"Pluto":   { "day": 551854.0,  "albedo": 0.52, "teq": 44.0,  "ground": 0xa89484, "rock": 0x8a7466 },
}

## Measured mean radii (km) for the moons and worlds a preset may not carry one
## for. Used only when the body itself has no radiusKm.
const RADII_KM := { "Moon": 1737.4, "Titan": 2574.7, "Europa": 1560.8, "Phobos": 11.27 }

## Everything a vessel needs about one body, in SI. `mu` comes from the body's
## current mass, so an edited planet flies differently at once. Reads name, mass,
## radius and day_length (only without a SURFACES entry). Returns name, body, mu,
## radius, gSurf, atm (or null), teq, rotRate, vRotEq, daySec, ground, rock, oceans,
## sea, vEsc, vCirc, karman.
static func flight_env(body: Body) -> Dictionary:
	var name := body.name
	var mass_sun := body.mass
	var mu := GM_SUN * mass_sun
	# b.radius is in AU and comes from structureOf() or a measured radiusKm, so
	# it is the same radius the cross-section and the collision test use.
	var radius := body.radius * AU_M
	if not (radius != 0.0 and not is_nan(radius)):     # falsy or NaN → fallback
		radius = RADII_KM[name] * 1000.0 if RADII_KM.has(name) else 6.371e6
	var surf: Dictionary = SURFACES.get(name, {})
	var g_surf := mu / (radius * radius)
	var teq: float = surf.get("teq", 255.0)
	var atm = ATMOSPHERES[name] if ATMOSPHERES.has(name) else derive_atmosphere(radius, g_surf, teq)
	var day_sec: float
	if surf.has("day"):
		day_sec = absf(surf.day)
	else:
		day_sec = absf(body.day_length * YR_S if body.day_length else 86400.0)
	var has_neg_day: bool = surf.has("day") and surf.day < 0.0
	return {
		"name": name, "body": body, "mu": mu, "radius": radius, "gSurf": g_surf, "atm": atm, "teq": teq,
		# Surface velocity at the equator — free Δv for an eastward launch, and the
		# reason Kourou exists. 465 m/s on Earth.
		"rotRate": (-1.0 if has_neg_day else 1.0) * 2.0 * PI / day_sec,
		"vRotEq": 2.0 * PI * radius / day_sec,
		"daySec": day_sec,
		"ground": surf.get("ground", 0x7a7266), "rock": surf.get("rock", 0x5f584f),
		"oceans": surf.get("oceans", false), "sea": surf.get("sea", 0x1b3a6b),
		# Escape speed and circular speed at the surface — the two numbers that say
		# what kind of place this is to fly from.
		"vEsc": sqrt(2.0 * mu / radius),
		"vCirc": sqrt(mu / radius),
		# Where "space" starts, for the purposes of the HUD and the rails interlock.
		"karman": atm.top * 0.72 if atm != null else 0.0,
	}
