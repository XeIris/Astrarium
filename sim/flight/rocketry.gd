class_name Rocketry
extends RefCounted

# SI propulsion, aerodynamic and atmosphere models; derived outputs use the
# vehicle catalogue. Source record: web/docs/spaceflight-research.md.

# defined constants
const G0 := 9.80665                 # m/s² — DEFINED, not local gravity
const C_MS := 299792458.0           # m/s — defined
const AU_M := 1.495978707e11        # m — defined
const GM_SUN := 1.32712440018e20    # m³/s² — IAU 2015 nominal
# s — the orrery year: 2π√(AU³/GM☉) = 365.25690 d, the period in which Physics.G =
# 4π² exactly. A Julian year here would make flight and orrery disagree by 3.8e-5 in GM.
const YR_S := 31558196.01824108
const M_EARTH_SUN := 3.00348959e-6  # M⊕ in M☉
const R_GAS := 8.31446261815324     # J/mol/K

# ATMOSPHERE. Layer bases are geometric altitudes; hydrostatics run in geopotential
# height z = R·h/(R + h) with the body's own surface gravity `g` (flight_env fills
# both unless the entry states them). A layer has a lapse rate L (K per geopotential
# metre, 0 for isothermal), with T carried up from the layer below,
#   ρ = ρ_base·(T/T_base)^(g·M/(R·L) − 1),   or ρ_base·exp(−g·M·Δz/(R·T)) when L = 0;
# a stated scale height H; or a `table` of [h, ρ, T] rows, interpolated in log ρ.
# `top` is the edge of the sensible atmosphere for guidance, steps and rails; drag
# alone continues to `exo` through the thin thermosphere, so low orbits decay.

# Measured atmospheres by body name; anything else is derived (derive_atmosphere).
# `tint`/`haze` are sRGB hex (U.lin()).
const ATMOSPHERES := {
	# US Standard Atmosphere 1976 (NASA-TM-X-74335): the seven lapse layers to 86 km,
	# their geopotential bases given here as geometric heights, then its table to
	# 1000 km. It is the standard's own g₀ and r₀, not the flight_env sphere.
	"Earth": {
		"p0": 101325.0, "rho0": 1.225, "T0": 288.15, "molar": 0.0289644, "gamma": 1.4,
		"g": 9.80665, "R": 6356766.0,
		"layers": [
			{ "base": 0.0,     "L": 0.0065 },    # troposphere
			{ "base": 11019.1, "L": 0.0 },       # tropopause
			{ "base": 20063.1, "L": -0.001 },    # stratosphere
			{ "base": 32161.9, "L": -0.0028 },
			{ "base": 47350.1, "L": 0.0 },       # stratopause
			{ "base": 51412.5, "L": 0.0028 },    # mesosphere
			{ "base": 71802.0, "L": 0.002 },
			# Thermosphere: molar mass falls above ~100 km, so p = ρRT/M is only
			# indicative there; ρ and T are the standard's.
			{ "base": 86000.0, "table": [
				[86e3, 6.958e-6, 186.87], [90e3, 3.416e-6, 186.87], [100e3, 5.604e-7, 195.08],
				[110e3, 9.708e-8, 240.0], [120e3, 2.222e-8, 360.0], [130e3, 8.152e-9, 469.27],
				[140e3, 3.831e-9, 559.63], [150e3, 2.076e-9, 634.39], [160e3, 1.233e-9, 696.29],
				[180e3, 5.194e-10, 787.94], [200e3, 2.541e-10, 854.56], [250e3, 6.073e-11, 941.33],
				[300e3, 1.916e-11, 976.01], [350e3, 7.014e-12, 990.06], [400e3, 2.803e-12, 995.83],
				[450e3, 1.184e-12, 998.22], [500e3, 5.215e-13, 999.24], [600e3, 1.137e-13, 999.85],
				[700e3, 3.070e-14, 999.97], [800e3, 1.136e-14, 999.99], [900e3, 5.759e-15, 1000.0],
				[1000e3, 3.561e-15, 1000.0]] },
		],
		"top": 140e3, "exo": 1000e3, "tint": 0x4a7fd0, "haze": 0x8fb6e8,
		# Water vapour to condense in the expansions round a vehicle (Vapour).
		"humid": true,
	},
	# The standard Mars model, H = 11.1 km. rho0 follows from 610 Pa of CO₂ at 210 K
	# (0.0151 kg/m³). A second layer above 60 km. Deep enough to burn you, too thin to
	# stop you.
	"Mars": {
		"p0": 610.0, "rho0": 0.01514, "T0": 210.0, "molar": 0.04334, "gamma": 1.29,
		"kSG": 1.9027e-4,                    # CO₂ Sutton–Graves constant (Tauber & Sutton 1991)
		"layers": [{ "base": 0.0, "H": 11100.0 }, { "base": 60000.0, "H": 8000.0 }],
		"top": 125e3, "tint": 0xc08a5a, "haze": 0xd8a878,
	},
	# VIRA (Seiff et al. 1985), 0–100 km, as lapse layers between its 10 km rows (within
	# 6% in ρ); isothermal above. ρ₀ is 92.1 bar of CO₂ at 735.3 K.
	"Venus": {
		"p0": 9.21e6, "rho0": 65.456, "T0": 735.3, "molar": 0.04345, "gamma": 1.29, "kSG": 1.9027e-4,
		"layers": [
			{ "base": 0.0, "L": 0.0077227 }, { "base": 10000.0, "L": 0.0077885 },
			{ "base": 20000.0, "L": 0.0084494 }, { "base": 30000.0, "L": 0.008022 },
			{ "base": 40000.0, "L": 0.0068102 }, { "base": 50000.0, "L": 0.0089301 },
			{ "base": 60000.0, "L": 0.0033713 }, { "base": 70000.0, "L": 0.0033516 },
			{ "base": 80000.0, "L": 0.0028484 }, { "base": 90000.0, "L": -0.000619 },
			{ "base": 100000.0, "L": 0.0 },
		],
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
	if h >= float(atm.get("exo", atm.top)): return [0.0, atm.T0 * 0.55]
	var hh := maxf(h, 0.0)
	var g: float = atm.get("g", G0)
	var R: float = atm.get("R", INF)
	var rho: float = atm.rho0
	var T: float = atm.T0
	var layers: Array = atm.layers
	var nl := layers.size()
	for i in nl:
		var L: Dictionary = layers[i]
		if L.has("table"):
			var at_base := _table_at(L.table, L.base)
			var at_h := _table_at(L.table, hh)
			return [rho * at_h[0] / at_base[0], at_h[1]]
		if hh <= L.base: break
		var top_of_layer: float = layers[i + 1].base if i + 1 < nl else INF
		var h1 := minf(hh, top_of_layer)
		if L.has("H"):
			rho *= exp(-(h1 - L.base) / L.H)
		else:
			var dz := _geopotential(h1, R) - _geopotential(L.base, R)
			var lapse: float = L.L
			if lapse != 0.0:
				var T1 := maxf(T - lapse * dz, 1.0)
				rho *= pow(T1 / T, g * atm.molar / (R_GAS * lapse) - 1.0)
				T = T1
			else:
				rho *= exp(-g * atm.molar * dz / (R_GAS * T))
		if hh <= top_of_layer: break
	return [rho, T]

static func _geopotential(h: float, R: float) -> float:
	return h if R == INF else R * h / (R + h)

## [ρ, T] from [h, ρ, T] rows: log-linear in ρ, linear in T, held past the last row.
static func _table_at(rows: Array, h: float) -> Array:
	for j in rows.size() - 1:
		var a: Array = rows[j]; var b: Array = rows[j + 1]
		if h <= b[0]:
			var f := clampf((h - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			return [exp(lerpf(log(a[1]), log(b[1]), f)), lerpf(a[2], b[2], f)]
	var last: Array = rows[rows.size() - 1]
	return [last[1], last[2]]

static func density(atm, h: float) -> float:     return profile(atm, h)[0]
static func temperature(atm, h: float) -> float: return profile(atm, h)[1]

## p = ρRT/M — the ideal gas law, with both inputs coming from the same walk, so
## pressure and density can never disagree about which layer we are in.
static func pressure(atm, h: float) -> float:
	if atm == null: return 0.0
	var p := profile(atm, h)
	return p[0] * R_GAS * p[1] / atm.molar

## Local density scale height, m: the natural step size in air.
static func scale_height(atm, h: float) -> float:
	if atm == null: return INF
	var L = null
	for l in atm.layers:
		if h >= l.base: L = l
	if L == null: L = atm.layers[0]
	if L.get("H", 0.0): return L.H
	if L.has("table"):
		var a := _table_at(L.table, h)
		var b := _table_at(L.table, h + 1000.0)
		return 1000.0 / maxf(log(a[0] / b[0]), 1e-9)
	return R_GAS * temperature(atm, h) / (atm.molar * float(atm.get("g", G0)))

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

## Stagnation heat flux (W/m²): Sutton–Graves in continuum flow,
##   q̇ = k √(ρ/R_n) v³,  k = 1.7415e-4 (SI) for air, an atmosphere's `kSG` otherwise,
## capped by the free-molecular limit ½ρv³ (the whole kinetic energy flux), which takes
## over in the rarefied air above ~110 km. Lunar return at 11 km/s heats 8× as hard as
## LEO entry at 5.5. Shock-layer radiation, which matters above ~10 km/s, is not modelled.
const SUTTON_GRAVES_K := 1.7415e-4
static func heat_flux(rho: float, v: float, nose_radius_m: float, atm = null) -> float:
	if rho <= 0.0: return 0.0
	var k: float = atm.get("kSG", SUTTON_GRAVES_K) if atm != null else SUTTON_GRAVES_K
	var v3 := v * v * v
	return minf(k * sqrt(rho / maxf(nose_radius_m, 0.05)) * v3, 0.5 * rho * v3)

# ENGINES: two measured Isps and a vacuum thrust; everything else follows.

## Effective Isp at p_a, linear between the endpoints, clamped below (an
## over-pressured nozzle separates).
static func isp_at(engine: Dictionary, pa: float) -> float:
	var f := minf(maxf(pa / 101325.0, 0.0), 1.4)
	return maxf(engine.ispVac - (engine.ispVac - engine.ispSL) * f, engine.ispSL * 0.55)

## A solid's thrust is set by its grain. Fractions of the vacuum rating (the peak)
## against fraction burned, from the RSRM population-nominal vacuum thrust at 60 °F
## (Thiokol TWR-17543-10, NTRS 19900003336, fig. 3.8): 3.15 Mlbf at ignition, 3.32 at
## 21 s, the max-q bucket at 52 s, burnout at the 123.4 s action time. Mass × Isp sets
## the impulse. How the knots were read: docs/physics/srb-separation.md#the-solids-thrust.
const RSRM_PROFILE := [
	[0.000, 0.949], [0.031, 0.951], [0.070, 0.982], [0.102, 0.992], [0.233, 1.000], [0.296, 0.913],
	[0.366, 0.838], [0.445, 0.767], [0.518, 0.717], [0.707, 0.773], [0.741, 0.771], [0.774, 0.743],
	[0.833, 0.667], [0.862, 0.648], [0.904, 0.598], [0.969, 0.495], [0.979, 0.438], [0.983, 0.399],
	[0.987, 0.316], [0.992, 0.206], [0.996, 0.131], [1.000, 0.029],
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
## What a set of engines delivers right now: thrust (N), flow (kg/s), Isp (s) and
## the throttle actually applied.
class Thrust extends RefCounted:
	var F: float = 0.0
	var mdot: float = 0.0
	var isp: float = 0.0
	var throttle: float = 0.0

	func set_to(p_F: float, p_mdot: float, p_isp: float, p_throttle: float) -> Thrust:
		F = p_F; mdot = p_mdot; isp = p_isp; throttle = p_throttle
		return self

## `out` is filled and returned when given: the integrator passes scratch, since
## allocating an object costs more than the Dictionary it replaced.
static func engine_output(engine: Dictionary, n: float, pa: float, throttle: float, burned_frac: float = 0.0,
		out: Thrust = null) -> Thrust:
	if out == null: out = Thrust.new()
	var th: float = 0.0 if throttle <= 0.0 else minf(maxf(throttle, engine.get("throttleMin", 1.0)), engine.get("maxThrottle", 1.0))
	# A solid ignores the throttle entirely and follows its grain.
	if engine.get("solid", false):
		th = solid_thrust_fraction(burned_frac, engine.get("profile")) if throttle > 0.0 else 0.0
	if th <= 0.0 or n <= 0.0:
		return out.set_to(0.0, 0.0, engine.ispVac, 0.0)
	var mdot_vac: float = engine.thrustVac / (G0 * engine.ispVac)
	var isp := isp_at(engine, pa)
	var mdot := mdot_vac * th * n
	return out.set_to(mdot * G0 * isp, mdot, isp, th)

## Burn time for a Δv at the current thrust and mass:
##   t = (m·g₀·Isp/F)·(1 − exp(−Δv/(g₀·Isp)))
static func burn_time_for(dv: float, mass: float, thrust_n: float, isp: float) -> float:
	if thrust_n <= 0.0 or dv <= 0.0: return 0.0
	var ve := G0 * isp
	return (mass * ve / thrust_n) * (1.0 - exp(-dv / ve))

# FLIGHT ENVIRONMENT. Surface data the orrery doesn't carry: rotation, ground and air.
# `day` is the sidereal rotation period, s; negative is retrograde.
const SURFACES := {
	"Earth":   { "day": 86164.1,   "albedo": 0.30, "teq": 255.0, "ground": 0x4a6b3f, "rock": 0x6b5a45, "sea": 0x1b3a6b, "oceans": true },
	"Moon":    { "day": 2360591.0, "albedo": 0.12, "teq": 270.0, "ground": 0x8a8378, "rock": 0x6e6860 },
	"Mars":    { "day": 88642.7,   "albedo": 0.25, "teq": 210.0, "ground": 0xa8562f, "rock": 0x7d4426 },
	"Venus":   { "day": -20997153.0, "albedo": 0.77, "teq": 737.0, "ground": 0xb08040, "rock": 0x8a5f30 },
	"Mercury": { "day": 5067360.0, "albedo": 0.14, "teq": 440.0, "ground": 0x8c8378, "rock": 0x6b645c },
	"Jupiter": { "day": 35730.0,   "albedo": 0.54, "teq": 165.0, "ground": 0xc9a882, "rock": 0xa88a60 },
	"Titan":   { "day": 1377648.0, "albedo": 0.22, "teq": 94.0,  "ground": 0x9a7a3c, "rock": 0x7a5f30 },
	"Saturn":  { "day": 38018.0 },
	"Uranus":  { "day": -62064.0 },
	"Neptune": { "day": 57996.0 },
	"Pluto":   { "day": -551854.0,  "albedo": 0.52, "teq": 44.0,  "ground": 0xa89484, "rock": 0x8a7466 },
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
	if atm != null: atm = U.merged({ "g": g_surf, "R": radius }, atm)
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
