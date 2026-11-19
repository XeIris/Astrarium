class_name Atmosphere
extends RefCounted

# A column of dry gas over a surface: its outgoing longwave and what it scatters. The
# fits, their anchors and their domain: docs/physics/climate.md#an-atmosphere-with-composition.

# Partial pressures in bar. m kg/mol; cp J mol⁻¹ K⁻¹; rayleigh m² per molecule at 550 nm,
# from He et al. (2021) Table 1's refractive indices and King factors. Ar is not in that
# table and SO₂ is a trace, so each takes the nearest gas's value (assumed).
# label, colour and foot (log₁₀ bar at the foot of its slider) are how the composition editor
# shows the gas, so a new row here reaches the HUD; its upper limit is ClimateInputs.DOMAIN's.
const GASES := {
	"pN2":  { "m": 0.0280134, "cp": 29.1, "rayleigh": 4.631e-31, "label": "N₂", "color": 0x6f93c4, "foot": -5.0 },
	"pO2":  { "m": 0.0319988, "cp": 29.4, "rayleigh": 4.049e-31, "label": "O₂", "color": 0x63d0c4, "foot": -5.0 },
	"pAr":  { "m": 0.039948,  "cp": 20.8, "rayleigh": 4.631e-31, "label": "Ar", "color": 0xb49ae0, "foot": -6.0 },
	# cp is the value at about 400 K: R/c_p runs from 0.24 at 250 K to 0.16 at 735 K.
	"pCO2": { "m": 0.0440095, "cp": 41.6, "rayleigh": 1.164e-30, "label": "CO₂", "color": 0xe8935a, "foot": -6.0 },
	"pCH4": { "m": 0.016043,  "cp": 35.7, "rayleigh": 9.905e-31, "label": "CH₄", "color": 0x8fd46e, "foot": -9.0 },
	"pSO2": { "m": 0.064066,  "cp": 40.0, "rayleigh": 1.164e-30, "label": "SO₂", "color": 0xe8d25a, "foot": -8.0 },
}
# Water vapour's cross section: Kopparapu et al. (2013) give 2.6e-27 cm² at 600 nm.
const RAYLEIGH_H2O := 3.68e-31
const M_H2O := 0.018015
const R_GAS := 8.314
const AMU_PER_KG_MOL := 6.02214076e23
const G_EARTH := 9.82      # m/s², NSSDC's mean
const P_EARTH := 1.014     # bar
const SIGMA := 5.670374e-8

# CO₂ band: width 2l·ln(1 + x/x₀) in cm⁻¹ at 667 cm⁻¹, x = pCO₂·p/(g/g⊕). 2l makes today's
# Earth lose 5.35 W/m² per e-fold (Myhre et al. 1998); x₀ puts Mars at its measured 214 K.
const BAND_2L := 18.8744
const BAND_X0 := 8.4721e-7
const C2_NU := 1.4388 * 667.0             # hc·ν/k, K
const PI_B_NU3 := PI * 1.191043e-8 * 296740963.0   # πB's numerator at 667 cm⁻¹, W m⁻² per cm⁻¹
# The band's core radiates from the stratosphere: 214.7 K over Earth's 288.15 K.
const STRAT := 0.745
# Grey continuum D·τ = (K_CO2·pCO₂ + K_SO2·pSO₂)·p/(g/g⊕), bar⁻²: collisional, so p². K_CO2
# fits Kopparapu's dense CO₂; K_SO2 stands for the sulphuric deck and puts Venus at 737 K.
const K_CO2 := 0.45
const K_SO2 := 2.5577e4
# A dense CO₂ sky, opaque at every infrared wavelength, levels out (Kopparapu Fig. 5a: ~65 W/m² at 273 K).
const DENSE_CO2_BAR := 1.0
const DENSE_CO2_OLR := 65.0
# Myhre's √ term for CH₄, as a share of the Planck flux: 0.036·√(ppb) of 390.9 W/m².
const CH4_FRACTION := 0.036 / 390.92
# Wet sky. The water-opaque share (1 − WINDOW) radiates at the temperature where the
# vapour pressure reaches PV_STAR·(g/g⊕)/(p/bar) Pa. Both set by Earth: OLR(288.15 K) =
# 0.61σT⁴ and dOLR/dT = LatitudeEBM.B.
const WINDOW := 0.4526
const PV_STAR := 50.103
# Limb brightness 1 − exp(−m·τ), m = air masses through the shell. m puts Venus's 16 at the
# 2.4 its look was authored at; Earth's own column is the reference, so its sky is unchanged.
const LIMB_AIRMASS := 5.27
const TAU_EARTH := 0.09686
const PRIMARIES_NM := [680.0, 550.0, 440.0]

var p_dry := 0.0                # bar
var mean_molar := 0.0289644     # kg/mol
var gamma := 1.4                # c_p/c_v
var kappa := 0.2857             # R/c_p
var tau550 := 0.0               # vertical Rayleigh optical depth at 550 nm
var _gravity := G_EARTH
var _rayleigh := 0.0            # m² per molecule, the mean
var emit_k := 1.0               # emission temperature per surface kelvin
var _co2_width := 0.0           # cm⁻¹
var _ch4_share := 0.0
var _t_vapour := 0.0            # K
var _sigma_t_vapour4 := 0.0
var _dense_floor := 0.0
var water_opaque_column := 0.0  # kg/m²: the vapour that closes the water bands

func _init(pressures: Dictionary = {}, gravity: float = G_EARTH) -> void:
	_gravity = maxf(gravity, 1e-3)
	var moles := 0.0
	var cp := 0.0
	var scatter := 0.0
	for key in GASES:
		var p := float(pressures.get(key, 0.0))
		if p <= 0.0: continue
		var gas: Dictionary = GASES[key]
		p_dry += p
		moles += p * float(gas.m)
		cp += p * float(gas.cp)
		scatter += p * float(gas.rayleigh)
	if p_dry > 0.0:
		mean_molar = moles / p_dry
		_rayleigh = scatter / p_dry
		var c := cp / p_dry
		kappa = R_GAS / c
		gamma = c / (c - R_GAS)
	tau550 = _rayleigh * column_molecules(p_dry)
	var co2 := float(pressures.get("pCO2", 0.0))
	var so2 := float(pressures.get("pSO2", 0.0))
	var g_ratio := _gravity / G_EARTH
	var opacity := (K_CO2 * co2 + K_SO2 * so2) * p_dry / g_ratio
	emit_k = pow(1.0 + opacity, -0.5 * kappa)
	_co2_width = BAND_2L * log(1.0 + co2 * p_dry / g_ratio / BAND_X0)
	if p_dry > 0.0:
		_ch4_share = CH4_FRACTION * sqrt(float(pressures.get("pCH4", 0.0)) / p_dry * 1e9)
	# Thin air broadens the water lines less, so the level that closes them sits lower and warmer.
	var pv := PV_STAR * g_ratio / maxf(p_dry, 1e-6)
	_t_vapour = saturation_T(pv * 1e-5)
	_sigma_t_vapour4 = SIGMA * pow(_t_vapour, 4.0)
	water_opaque_column = pv * M_H2O / mean_molar / _gravity
	_dense_floor = DENSE_CO2_OLR if co2 >= DENSE_CO2_BAR else 0.0

## Molecules per m² over a surface, for `bar` of this air.
func column_molecules(bar: float) -> float:
	return bar * 1e5 / (mean_molar / AMU_PER_KG_MOL * _gravity)

## Saturation temperature (K) at `bar`, by Clausius–Clapeyron at L = 40.7 kJ/mol from 373.15 K at 1 bar.
static func saturation_T(bar: float) -> float:
	return 1.0 / (1.0 / 373.15 - R_GAS / 40700.0 * log(maxf(bar, 1e-30)))

## Saturation vapour pressure (bar) at `t` K, the inverse of saturation_T.
static func saturation_bar(t: float) -> float:
	return exp(40700.0 / R_GAS * (1.0 / 373.15 - 1.0 / maxf(t, 1.0)))

static func _band(t: float) -> float:
	return PI_B_NU3 / (exp(C2_NU / t) - 1.0)

## Outgoing longwave (W/m²) at surface temperature `t` K, with the water bands weighted by
## `water` (0 dry, 1 opaque).
func olr(t: float, water: float = 0.0) -> float:
	var r := t * emit_k
	var r2 := r * r
	var e := SIGMA * r2 * r2
	var out := e * (1.0 - _ch4_share)
	if _co2_width > 0.0:
		out -= _co2_width * (_band(r) - _band(r * STRAT))
	if water > 0.0 and r > _t_vapour:
		out -= water * (1.0 - WINDOW) * (e - _sigma_t_vapour4)
	# Never below what the band's core radiates, whatever the fits above say out of range.
	out = maxf(out, e * STRAT * STRAT * STRAT * STRAT)
	if _dense_floor > 0.0:
		out = maxf(out, minf(SIGMA * t * t * t * t, _dense_floor))
	return out

## Limb brightness (relative to Earth's) and tint for a column with `water_bar` of vapour on
## top. `thick` is what rocky_atmosphere.gdshader's uThick takes and `tint` its uTint; that
## shader's own β already carries λ⁻⁴, so Earth's column is 1 and white.
func limb(water_bar: float = 0.0) -> Dictionary:
	var tau := tau550
	if water_bar > 0.0:
		var total := p_dry + water_bar
		var molar := (p_dry * mean_molar + water_bar * M_H2O) / total
		tau = (p_dry * _rayleigh + water_bar * RAYLEIGH_H2O) * 1e5 / (molar / AMU_PER_KG_MOL * _gravity)
	var channel := func(i: int) -> float:
		var lam: float = 550.0 / float(PRIMARIES_NM[i])
		var scale := lam * lam * lam * lam
		return (1.0 - exp(-LIMB_AIRMASS * tau * scale)) / (1.0 - exp(-LIMB_AIRMASS * TAU_EARTH * scale))
	var green: float = channel.call(1)
	if green <= 0.0: return { "thick": 0.0, "tint": Vector3.ONE, "tau": 0.0 }
	return { "thick": green, "tint": Vector3(channel.call(0) / green, 1.0, channel.call(2) / green), "tau": tau }

## Scattering relative to Earth's column, for the flight sky's grey path.
func sky_thickness(tau: float) -> float:
	return tau / TAU_EARTH
