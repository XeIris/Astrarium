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
		# With a solar-activity setting (f107), the thermosphere above 120 km is the
		# Bates–Walker diffusive profile instead of the table; see `thermosphere`.
		# US76's own 120 km boundary: T, the temperature gradient's e-folding rate and
		# number densities (m⁻³), O₂ from the stated 2.222e-8 kg/m³; He with α = −0.38.
		"thermo": { "base": 120e3, "T120": 360.0, "s": 1.875e-5, "Tref": 1000.0, "Rg": 6356766.0,
			"species": [[28.0134, 3.726e17, 0.0], [15.9994, 7.582e16, 0.0], [31.9988, 5.24e16, 0.0],
				[39.948, 1.3e15, 0.0], [4.0026, 3.4e13, -0.38]] },
		# Water vapour to condense in the expansions round a vehicle (Vapour).
		"humid": true, "radiative": "air", "wind": "earth",
		# The flight sky's single-scattering coefficients (sky_dome.gdshader).
		"scatter": "earth",
	},
	# The standard Mars model, H = 11.1 km. rho0 follows from 610 Pa of CO₂ at 210 K
	# (0.0151 kg/m³). A second layer above 60 km. Deep enough to burn you, too thin to
	# stop you.
	"Mars": {
		"p0": 610.0, "rho0": 0.01514, "T0": 210.0, "molar": 0.04334, "gamma": 1.29,
		"kSG": 1.9027e-4,                    # CO₂ Sutton–Graves constant (Tauber & Sutton 1991)
		"radiative": "co2",
		"layers": [{ "base": 0.0, "H": 11100.0 }, { "base": 60000.0, "H": 8000.0 }],
		# Drag goes on into the thermosphere, where aerobraking passes fly (MGS and MRO
		# at 100–130 km); the upper layer's 8 km scale height is held to 250 km.
		"top": 125e3, "exo": 250e3, "tint": 0xc08a5a, "haze": 0xd8a878, "scatter": "mars",
	},
	# VIRA (Seiff et al. 1985), 0–100 km, as lapse layers between its 10 km rows (within
	# 6% in ρ); isothermal above. ρ₀ is 92.1 bar of CO₂ at 735.3 K.
	"Venus": {
		"p0": 9.21e6, "rho0": 65.456, "T0": 735.3, "molar": 0.04345, "gamma": 1.29, "kSG": 1.9027e-4,
		"radiative": "co2",
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
		"layers": [{ "base": 0.0, "H": 21000.0 }], "top": 600e3, "tint": 0xc2924a, "haze": 0xe8c481, "scatter": "titan",
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

## Solar activity: the 10.7 cm flux in solar flux units, or 0 for the standard
## atmosphere's fixed thermosphere (the default; every built flight assumes it).
static var f107 := 0.0

## Exospheric temperature, K, for a 10.7 cm flux: Jacchia's (1971) T_c = 379 + 3.24·F,
## scaled so that F = 150 gives US76's 1000 K (its thermosphere is a moderate-activity one).
static func exospheric_temp(f: float, t_ref: float = 1000.0) -> float:
	return t_ref * (379.0 + 3.24 * f) / (379.0 + 3.24 * 150.0)

## [ρ, T] above the thermosphere's base: each species in diffusive equilibrium on the
## Bates temperature profile, in Walker's (1965) closed form; docs/physics/flight.md#the-thermosphere.
static func thermosphere(th: Dictionary, h: float, t_inf: float, g0: float) -> Array:
	var Rg: float = th.Rg
	var z0: float = th.base
	var zeta := (h - z0) * (Rg + z0) / (Rg + h)
	var T120: float = th.T120
	var s: float = th.s
	var a := (t_inf - T120) / t_inf
	var e := exp(-s * zeta)
	var T := t_inf * (1.0 - a * e)
	var g120 := g0 * pow(Rg / (Rg + z0), 2.0)
	var rho := 0.0
	for sp in th.species:
		var m: float = float(sp[0]) * 1.66053907e-27
		var gam := m * g120 / (s * 1.380649e-23 * t_inf)
		rho += m * float(sp[1]) * pow(T120 / T, 1.0 + float(sp[2]) + gam) * exp(-s * gam * zeta)
	return [rho, T]

## Walk the layer stack to `h`, returning [rho, T].
static func profile(atm, h: float) -> Array:
	if atm == null: return [0.0, 3.0]
	if h >= float(atm.get("exo", atm.top)): return [0.0, atm.T0 * 0.55]
	if f107 > 0.0 and atm.has("thermo") and h >= float(atm.thermo.base):
		return thermosphere(atm.thermo, h, exospheric_temp(f107, float(atm.thermo.Tref)), float(atm.get("g", G0)))
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
## region, then falls away. A stage's `cdTable` ({source, rows: [[M, Cd], ...]})
## replaces this generic curve while that stage is the lowest one attached.
static func drag_coefficient(mach: float, table = null) -> float:
	var M := maxf(mach, 0.0)
	if table != null:
		var rows: Array = table.rows
		if M <= float(rows[0][0]): return float(rows[0][1])
		for i in range(1, rows.size()):
			if M <= float(rows[i][0]):
				var f := (M - float(rows[i - 1][0])) / maxf(float(rows[i][0]) - float(rows[i - 1][0]), 1e-9)
				return lerpf(float(rows[i - 1][1]), float(rows[i][1]), f)
		return float(rows[rows.size() - 1][1])
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
## LEO entry at 5.5. Shock-layer radiation is radiative_heat_flux.
const SUTTON_GRAVES_K := 1.7415e-4
static func heat_flux(rho: float, v: float, nose_radius_m: float, atm = null) -> float:
	if rho <= 0.0: return 0.0
	var k: float = atm.get("kSG", SUTTON_GRAVES_K) if atm != null else SUTTON_GRAVES_K
	var v3 := v * v * v
	return minf(k * sqrt(rho / maxf(nose_radius_m, 0.05)) * v3, 0.5 * rho * v3)

## Equilibrium shock-layer radiation at the stagnation point (Tauber & Sutton 1991,
## J. Spacecraft Rockets 28, 40): q̇ = C·R_n^a·ρ^b·f(V) in W/cm², R_n in m, ρ in
## kg/m³, quoted to ±30% by the authors. In air a = 1.072e6·V^−1.88·ρ^−0.325, capped
## by nose radius; f(V) is tabulated to 16 km/s in air and 9 km/s in CO₂ and held
## beyond (Venus entry at 11 km/s is underestimated). Zero below the tables.
const RADIATIVE := {
	"air": { "C": 4.736e4, "b": 1.22, "f": [
		[9000.0, 1.5], [9250.0, 4.3], [9500.0, 9.7], [9750.0, 19.5], [10000.0, 35.0],
		[10250.0, 55.0], [10500.0, 81.0], [10750.0, 115.0], [11000.0, 151.0], [11500.0, 238.0],
		[12000.0, 359.0], [12500.0, 495.0], [13000.0, 660.0], [13500.0, 850.0], [14000.0, 1065.0],
		[14500.0, 1313.0], [15000.0, 1550.0], [15500.0, 1780.0], [16000.0, 2040.0]] },
	"co2": { "C": 2.35e4, "a": 0.526, "b": 1.19, "f": [
		[6000.0, 0.2], [6150.0, 1.0], [6300.0, 1.95], [6500.0, 3.42], [6700.0, 5.1], [6900.0, 7.1],
		[7000.0, 8.1], [7200.0, 10.2], [7400.0, 12.5], [7600.0, 14.8], [7800.0, 17.1], [8000.0, 19.2],
		[8200.0, 21.4], [8400.0, 24.1], [8600.0, 26.0], [8800.0, 28.9], [9000.0, 32.8]] },
}
static func radiative_heat_flux(rho: float, v: float, nose_radius_m: float, atm = null) -> float:
	if rho <= 0.0 or atm == null or not RADIATIVE.has(atm.get("radiative", "")): return 0.0
	var k: Dictionary = RADIATIVE[atm.radiative]
	var rows: Array = k.f
	if v < float(rows[0][0]): return 0.0
	var fv := float(rows[rows.size() - 1][1])
	for i in range(1, rows.size()):
		if v <= float(rows[i][0]):
			fv = lerpf(float(rows[i - 1][1]), float(rows[i][1]), (v - float(rows[i - 1][0])) / (float(rows[i][0]) - float(rows[i - 1][0])))
			break
	var rn := maxf(nose_radius_m, 0.05)
	var a: float
	if k.has("a"):
		a = k.a
	else:
		a = minf(1.072e6 * pow(v, -1.88) * pow(rho, -0.325), 1.0 if rn < 1.0 else (0.6 if rn < 2.0 else 0.5))
	return k.C * pow(rn, a) * pow(rho, k.b) * fv * 1e4

# GRAVITY FIELDS. Zonal harmonics (unnormalised J_n) about the spin pole, with their
# reference radius. Earth: EGM2008; Mars: MRO120D (Konopliv et al. 2016); Moon:
# LP150Q (Konopliv et al. 2001). Sectoral and tesseral terms, and the lunar mascons
# that make low lunar orbits unstable, are not modelled.
const ZONAL := {
	"Earth": { "R": 6378137.0, "J": [0.0, 0.0, 1.08262668e-3, -2.53265649e-6, -1.61962159e-6] },
	"Mars":  { "R": 3396000.0, "J": [0.0, 0.0, 1.956608e-3, 3.1450e-5, -1.5377e-5] },
	# J_n = −√(2n+1)·C̄n0 of the GRAIL field the tesseral terms come from (LunarGravity).
	"Moon":  { "R": 1738000.0, "J": [0.0, 0.0, 2.032133e-4, 8.459745e-6, -9.704363e-6] },
}

# The rest of a parent's field: every m ≥ 1 term, and zonals past J4, fully normalized,
# indexed n(n+1)/2 + m, in the body-fixed frame (Vessel.body_angle turns it).
# Earth: EGM2008's C̄21, S̄21, C̄22, S̄22 (Pavlis et al. 2012). The Moon: GRAIL's GL0420A to
# degree 16, its mascons included (LunarGravity).
const TESSERAL := {
	"Earth": { "R": 6378136.3, "nmax": 2, "C": [0.0, 0.0, 0.0, 0.0, -2.0662e-10, 2.43938357328e-6],
		"S": [0.0, 0.0, 0.0, 0.0, 1.38441389e-9, -1.40027370385e-6] },
	"Moon": { "R": LunarGravity.R_REF, "nmax": LunarGravity.NMAX, "C": LunarGravity.C, "S": LunarGravity.S },
}
const ZONAL_DEGREE := 4

## Acceleration (m/s²) from a TESSERAL field at `rr` (flight frame, pole on −Y) with the
## body's prime meridian `theta` rad east of the frame's +X; zonals up to ZONAL_DEGREE are
## zonal_accel's. Adds into `out`. Holmes & Featherstone's (2002) normalized recursion,
## gradient in spherical coordinates (Vallado §8.7).
static func tesseral_accel(field, mu: float, rr: DVec3, theta: float, out: DVec3) -> DVec3:
	if field == null: return out
	var ct := cos(theta); var st := sin(theta)
	# Body-fixed: x toward the prime meridian, z north (−Y), y completing the right hand.
	var x := rr.x * ct + rr.z * st
	var y := -rr.x * st + rr.z * ct
	var z := -rr.y
	var rho2 := x * x + y * y
	var r2 := rho2 + z * z
	if r2 < 1.0 or rho2 < 1e-6: return out
	var r := sqrt(r2)
	var rho := sqrt(rho2)
	var sphi := z / r
	var cphi := rho / r
	var lam := atan2(y, x)
	var nmax: int = field.nmax
	var P := _legendre(nmax, sphi, cphi)
	var C: Array = field.C
	var Sn: Array = field.S
	var q := float(field.R) / r
	var dr := 0.0; var dphi := 0.0; var dlam := 0.0
	var qn := q
	for n in range(2, nmax + 1):
		qn *= q
		for m in n + 1:
			if m == 0 and n <= ZONAL_DEGREE: continue
			var k := ((n * (n + 1)) >> 1) + m
			var cm := cos(m * lam); var sm := sin(m * lam)
			var cs := float(C[k]) * cm + float(Sn[k]) * sm
			var pnm: float = P[k]
			dr += qn * (n + 1) * pnm * cs
			# dP̄nm/dφ = √((n−m)(n+m+1)/δ) P̄n,m+1 − m tanφ P̄nm, δ = 2 at m = 0.
			var nxt: float = P[k + 1] if m < n else 0.0
			var dp := sqrt((n - m) * (n + m + 1) / (2.0 if m == 0 else 1.0)) * nxt - m * sphi / cphi * pnm
			dphi += qn * dp * cs
			dlam += qn * m * pnm * (float(Sn[k]) * cm - float(C[k]) * sm)
	var g := mu / r
	var ur := -g / r * dr          # ∂U/∂r
	var up := g * dphi             # ∂U/∂φ
	var ul := g * dlam             # ∂U/∂λ
	var ax := (ur / r - z / (r2 * rho) * up) * x - ul / rho2 * y
	var ay := (ur / r - z / (r2 * rho) * up) * y + ul / rho2 * x
	var az := ur / r * z + rho / r2 * up
	out.x += ax * ct - ay * st
	out.z += ax * st + ay * ct
	out.y -= az
	return out

## The field's potential energy per unit mass, J/kg, matching tesseral_accel.
static func tesseral_potential(field, mu: float, rr: DVec3, theta: float) -> float:
	if field == null: return 0.0
	var ct := cos(theta); var st := sin(theta)
	var x := rr.x * ct + rr.z * st
	var y := -rr.x * st + rr.z * ct
	var z := -rr.y
	var r := sqrt(x * x + y * y + z * z)
	if r < 1.0: return 0.0
	var P := _legendre(int(field.nmax), z / r, sqrt(x * x + y * y) / r)
	var lam := atan2(y, x)
	var q := float(field.R) / r
	var u := 0.0
	var qn := q
	for n in range(2, int(field.nmax) + 1):
		qn *= q
		for m in n + 1:
			if m == 0 and n <= ZONAL_DEGREE: continue
			var k := ((n * (n + 1)) >> 1) + m
			u += qn * float(P[k]) * (float(field.C[k]) * cos(m * lam) + float(field.S[k]) * sin(m * lam))
	return -mu / r * u

## Fully normalized P̄nm(sin φ) to degree nmax (and P̄n,n+1 = 0 implied), index n(n+1)/2 + m.
static func _legendre(nmax: int, s: float, c: float) -> PackedFloat64Array:
	var P := PackedFloat64Array()
	P.resize((((nmax + 1) * (nmax + 2)) >> 1) + 1)
	P[0] = 1.0
	for m in range(1, nmax + 1):
		var k := ((m * (m + 1)) >> 1) + m
		var km := (((m - 1) * m) >> 1) + m - 1
		P[k] = sqrt((2.0 * m + 1.0) / (2.0 * m)) * c * P[km] if m > 1 else sqrt(3.0) * c
	for m in nmax + 1:
		for n in range(m + 1, nmax + 1):
			var k := ((n * (n + 1)) >> 1) + m
			var k1 := (((n - 1) * n) >> 1) + m
			var a := sqrt((2.0 * n + 1.0) * (2.0 * n - 1.0) / ((n - m) * (n + m)))
			var v := a * s * P[k1]
			if n - 2 >= m:
				var k2 := (((n - 2) * (n - 1)) >> 1) + m
				v -= sqrt((2.0 * n + 1.0) * (n + m - 1.0) * (n - m - 1.0) / ((n - m) * (n + m) * (2.0 * n - 3.0))) * P[k2]
			P[k] = v
	return P

## Acceleration (m/s²) from J2–J4 at `rr`, metres from the centre in the flight frame
## (pole on −Y, so the polar coordinate is −y). Adds into `out`.
static func zonal_accel(zonal, mu: float, rr: DVec3, out: DVec3) -> DVec3:
	if zonal == null: return out
	var J: Array = zonal.J
	var x := rr.x
	var y := rr.z
	var z := -rr.y
	var r2 := x * x + y * y + z * z
	if r2 < 1.0: return out
	var r := sqrt(r2)
	var s := z / r
	var s2 := s * s
	var re_r := float(zonal.R) / r
	var g := mu / r2
	# −∇ of Φ = (μ/r)·Σ J_n (R/r)ⁿ P_n(s), in radial and polar parts (Vallado §8.7).
	var j2 := float(J[2]) * re_r * re_r
	var j3 := float(J[3]) * re_r * re_r * re_r
	var j4 := float(J[4]) * re_r * re_r * re_r * re_r
	var fxy := -g * (1.5 * j2 * (1.0 - 5.0 * s2) + 2.5 * j3 * (3.0 * s - 7.0 * s2 * s) \
		- 1.875 * j4 * (1.0 - 14.0 * s2 + 21.0 * s2 * s2))
	var fz := -g * (1.5 * j2 * (3.0 - 5.0 * s2) * s + 2.5 * j3 * (6.0 * s2 - 7.0 * s2 * s2 - 0.6) \
		- 1.875 * j4 * s * (5.0 - 70.0 / 3.0 * s2 + 21.0 * s2 * s2))
	out.x += fxy * x / r
	out.z += fxy * y / r
	out.y -= fz
	return out

## μ for conic elements under J2: its orbit-averaged radial pull at inclination i,
## μ·[1 + 3/2·J2·(R/r)²·(1 − 3/2·sin²i)]. Two-body elements with the bare μ read a
## circular 200 km orbit at 28.5° as 13 km eccentric; the ±2 km short-period terms
## remain.
static func effective_mu(zonal, mu: float, rr: DVec3, vv: DVec3) -> float:
	if zonal == null: return mu
	var hx := rr.y * vv.z - rr.z * vv.y
	var hy := rr.z * vv.x - rr.x * vv.z
	var hz := rr.x * vv.y - rr.y * vv.x
	var h2 := hx * hx + hy * hy + hz * hz
	var r2 := rr.length_sq()
	if h2 <= 0.0 or r2 <= 0.0: return mu
	var cos_i := -hy / sqrt(h2)
	var sin2 := 1.0 - cos_i * cos_i
	return mu * (1.0 + 1.5 * float(zonal.J[2]) * float(zonal.R) * float(zonal.R) / r2 * (1.0 - 1.5 * sin2))

## The zonal part of the potential, J/kg, matching zonal_accel.
static func zonal_potential(zonal, mu: float, rr: DVec3) -> float:
	if zonal == null: return 0.0
	var J: Array = zonal.J
	var r := rr.length()
	if r < 1.0: return 0.0
	var s := -rr.y / r
	var q := float(zonal.R) / r
	var p2 := 0.5 * (3.0 * s * s - 1.0)
	var p3 := 0.5 * (5.0 * s * s * s - 3.0 * s)
	var p4 := (35.0 * s * s * s * s - 30.0 * s * s + 3.0) / 8.0
	return mu / r * (float(J[2]) * q * q * p2 + float(J[3]) * q * q * q * p3 + float(J[4]) * q * q * q * q * p4)

# WIND. A zonal climatology, not weather: easterly trades and mid-latitude
# westerlies at the surface (±6 m/s), a 1/7-power boundary layer to 1 km, and a
# 35 m/s westerly jet near 12 km centred at 35° latitude, after the annual-mean
# zonal wind of HWM14 (Drob et al. 2015) and the ERA reanalyses. Eastward m/s.
## Off by default (Settings › Sim, `winds=1`): the scenarios' built bases were recorded
## in still air, and the frozen numeric reference has none.
static var winds_enabled := false
const WINDS := {
	"earth": { "surf": 6.0, "jet": 35.0, "jetH": 12000.0, "jetW": 4500.0, "jetLat": 35.0, "jetLatW": 15.0,
		"bl": 1000.0, "decay": 10000.0 },
}
static func zonal_wind(atm, h: float, lat: float) -> float:
	if atm == null or not WINDS.has(atm.get("wind", "")): return 0.0
	var w: Dictionary = WINDS[atm.wind]
	var hh := maxf(h, 0.0)
	var bl := pow(clampf(hh, 1.0, w.bl) / float(w.bl), 1.0 / 7.0) * exp(-maxf(hh - float(w.bl), 0.0) / float(w.decay))
	var surface := -float(w.surf) * cos(3.0 * lat) * bl
	var dl := (absf(lat) * 180.0 / PI - float(w.jetLat)) / float(w.jetLatW)
	var dh := (hh - float(w.jetH)) / float(w.jetW)
	return surface + float(w.jet) * exp(-dl * dl - dh * dh)

## The wind at `rr` (flight frame, pole on −Y) as a velocity, m/s, into `out`.
static func wind_at(atm, rr: DVec3, radius: float, out: DVec3) -> DVec3:
	out.set_v(0.0, 0.0, 0.0)
	if not winds_enabled or atm == null or not WINDS.has(atm.get("wind", "")): return out
	var r := rr.length()
	var ex := -rr.z
	var ez := rr.x
	var el := sqrt(ex * ex + ez * ez)
	if r < 1.0 or el < 1e-6: return out
	var u := zonal_wind(atm, r - radius, asin(clampf(-rr.y / r, -1.0, 1.0)))
	# East is (−Y) × r̂, the direction a prograde surface turns.
	return out.set_v(u * ex / el, 0.0, u * ez / el)

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

# SPIN POLES: IAU WGCCRE north poles at J2000, [RA°, Dec°] in ICRF (Archinal et al. 2018,
# Celest. Mech. Dyn. Astron. 130:22, tables 1–2), periodic terms summed at J2000 for the
# Moon, Mars and Neptune; no precession. "North" is the ecliptic-north side, so a negative
# SURFACES `day` turns retrograde about it. Pluto's report gives the positive pole; this
# is its opposite. A star keeps the ecliptic frame, where heliocentric inclinations are read.
const POLES := {
	"Mercury": [281.0103, 61.4155], "Venus": [272.76, 67.16],
	"Earth": [0.0, 90.0], "Moon": [266.8628, 65.6414], "Mars": [317.6809, 52.8864],
	"Jupiter": [268.056595, 64.495303], "Saturn": [40.589, 83.537], "Uranus": [257.311, -15.175],
	"Neptune": [299.3337, 42.9504], "Pluto": [312.993, 6.163], "Titan": [39.4827, 83.4279],
	"Europa": [268.08, 64.51],
}
const OBLIQUITY_J2000 := 84381.448 / 3600.0 * PI / 180.0   # IAU 1976 ε at J2000

# Range-safety azimuth windows (degrees clockwise from north) for Earth's ranges, found
# by the pad's latitude. Eastern Range 35°–120° (KSC and the Cape); Western Range
# 147°–201° from Vandenberg, south over open sea to polar and sun-synchronous orbits;
# Baikonur's drop zones allow 51.6°–70° inclinations, azimuths 29°–63°. Elsewhere,
# Starbase included, nothing is limited.
const LAUNCH_RANGES := [
	{"name": "Eastern Range", "lat": 28.5, "az": [35.0, 120.0]},
	{"name": "Western Range", "lat": 34.7, "az": [147.0, 201.0]},
	{"name": "Baikonur", "lat": 45.9, "az": [29.4, 63.3]},
]

## The inertial launch azimuth (rad, clockwise from north) for inclination `inc_deg`
## from latitude `lat`, sin β = cos i / cos φ, on whichever branch (north- or
## south-going) the range allows, clamped to the window. {az, range, limited}.
static func launch_azimuth(lat: float, inc_deg: float, body_name: String = "Earth") -> Dictionary:
	var sb := DQuat.jclamp(cos(deg_to_rad(inc_deg)) / maxf(cos(lat), 1e-3), -1.0, 1.0)
	var north := asin(sb)
	var south := PI - north
	var rng = null
	if body_name == "Earth":
		for r in LAUNCH_RANGES:
			if absf(rad_to_deg(lat) - float(r.lat)) < 0.6: rng = r
	if rng == null: return {"az": fposmod(north, TAU), "range": "", "limited": false}
	var lo := deg_to_rad(float(rng.az[0])); var hi := deg_to_rad(float(rng.az[1]))
	for az in [fposmod(north, TAU), fposmod(south, TAU)]:
		if az >= lo and az <= hi: return {"az": az, "range": rng.name, "limited": false}
	# Neither branch is allowed: the window's nearer edge.
	var best := lo
	var gap := INF
	for edge in [lo, hi]:
		for az in [fposmod(north, TAU), fposmod(south, TAU)]:
			var d := absf(angle_difference(az, edge))
			if d < gap: gap = d; best = edge
	return {"az": best, "range": rng.name, "limited": true}

## A J2000 equatorial direction (RA, Dec in radians) in orrery axes: the ecliptic in
## XZ, north on −Y, the equinox on +X.
static func equatorial_dir(ra: float, dec: float) -> DVec3:
	var eps := OBLIQUITY_J2000
	var xq := cos(dec) * cos(ra)
	var yq := cos(dec) * sin(ra)
	var zq := sin(dec)
	var ye := yq * cos(eps) + zq * sin(eps)
	var ze := -yq * sin(eps) + zq * cos(eps)
	return DQuat.nrm(DVec3.new(xq, -ze, ye))

## The rotation from `body`'s equatorial frame (its north pole on −Y) to orrery axes:
## world = frame · local. The shortest arc from −Y, so Earth's frame keeps the
## equinox on +X and is J2000 equatorial in the orrery's axis convention. A world
## with no measured pole tilts by its `obliquity` about +Z, as RockyVisual draws it.
static func spin_frame(body: Body) -> DQuat:
	var south := DVec3.new(0.0, -1.0, 0.0)
	var pole: DVec3
	if POLES.has(body.name):
		var p: Array = POLES[body.name]
		pole = equatorial_dir(deg_to_rad(float(p[0])), deg_to_rad(float(p[1])))
	elif is_finite(body.obliquity) and body.obliquity != 0.0:
		pole = DVec3.new(sin(body.obliquity), -cos(body.obliquity), 0.0)
	else:
		return DQuat.new()
	return DQuat.new().set_from_unit_vectors(south, pole)

## Measured mean radii (km) for the moons and worlds a preset may not carry one
## for. Used only when the body itself has no radiusKm.
const RADII_KM := { "Moon": 1737.4, "Titan": 2574.7, "Europa": 1560.8, "Phobos": 11.27 }

## Everything a vessel needs about one body, in SI. `mu` comes from the body's
## current mass, so an edited planet flies differently at once. Reads name, mass,
## radius, obliquity and day_length (only without a SURFACES entry). Returns name, body,
## mu, radius, gSurf, atm (or null), teq, rotRate, vRotEq, daySec, frame (spin_frame),
## ground, rock, oceans, sea, vEsc, vCirc, karman.
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
		"frame": spin_frame(body),
		"ground": surf.get("ground", 0x7a7266), "rock": surf.get("rock", 0x5f584f),
		"oceans": surf.get("oceans", false), "sea": surf.get("sea", 0x1b3a6b),
		# Escape speed and circular speed at the surface — the two numbers that say
		# what kind of place this is to fly from.
		"zonal": ZONAL.get(name),
		"tesseral": TESSERAL.get(name),
		"locked": body.spec.get("tidalLock"),
		"vEsc": sqrt(2.0 * mu / radius),
		"vCirc": sqrt(mu / radius),
		# Where "space" starts, for the purposes of the HUD and the rails interlock.
		"karman": atm.top * 0.72 if atm != null else 0.0,
	}
