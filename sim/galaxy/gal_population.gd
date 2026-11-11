class_name GalPopulation
extends RefCounted

# A stellar population today: Kroupa's (2001, MNRAS 322, 231) IMF, ξ(m) ∝ m^−1.3
# below 0.5 M☉ and m^−2.3 above, thinned by main-sequence lifetimes
# (Structure.main_sequence_lifetime) under a star-formation history, plus the light
# of stars past the main sequence by the fuel consumption theorem (Renzini & Buzzoni
# 1986): stars leaving the main sequence at b per year each burn F M☉ of fuel, so
# their phases shine with L = 9.75e10·b·F L☉, F per phase from Maraston (1998,
# MNRAS 300, 872) Table 1. The glow's light-to-mass ratio and colour, and the masses
# the star lattice draws, all come from these tables, so the resolved stars and the
# glow they hand over to carry the same light. Giants are not drawn one by one yet:
# their light stays in the glow everywhere.

const LM_MIN := -1.0969100130080565   # log10 0.08
const LM_MAX := 2.0                   # 100 M☉
const GRID := 2400
## Stars drawn one by one are at least this massive; lighter ones stay in the glow.
const M_RESOLVED := 0.5

## log10 m among resolved stars at the cumulative fractions u_k = 1 − 10^(−Z·k/64),
## k = 0..64: dense toward the top, where a few per cent of the stars span 2 to 100 M☉
## and linear steps in u would draw O stars by the hundred. Mirrored in
## galaxy_stars.gdshader (quantile()).
var quantiles := PackedFloat32Array()
const Q_DECADES := 7.0
var mean_mass := 0.0         # M☉, all main-sequence stars
var mean_l := 0.0            # L☉, all main-sequence stars
## Resolved stars per unit luminosity density: (number fraction ≥ M_RESOLVED)/⟨L⟩.
var resolved_per_l := 0.0
## Share of the light from stars below M_RESOLVED.
var faint_light := 0.0
## Visible light per L☉ of the whole population (visible()): its colour, and through
## the luminance its bolometric correction.
var color := Color(1, 1, 1)
## Mean bolometric L (L☉) of the resolved stars, and their share above 8 M☉.
var resolved_mean_l := 0.0
var resolved_ob := 0.0
## Share of the light from stars past the main sequence.
var post_ms_light := 0.0
## L☉ per M☉ ever formed in the history's window (a constant history's luminosity is
## this times its formation rate times the window).
var light_per_formed := 0.0
var phase_l := PackedFloat64Array()

## The cumulative fraction of the k-th quantile.
static func q_level(k: int) -> float:
	return 1.0 - pow(10.0, -Q_DECADES * float(k) / 64.0)

## log10 m at cumulative fraction u, as the shader interpolates the table.
func quantile_lm(u: float) -> float:
	var z := -log(maxf(1.0 - u, 1e-12)) / log(10.0)
	var f := clampf(z / Q_DECADES, 0.0, 1.0) * 64.0
	var i := mini(int(f), 63)
	return lerpf(quantiles[i], quantiles[i + 1], f - float(i))

## The main sequence on GRID_MS log-mass points: Vector4(r, g, b, L) with (r, g, b)
## the visible light per L☉ (visible()) and L bolometric.
const GRID_MS := 64

static func main_sequence() -> PackedVector4Array:
	var out := PackedVector4Array()
	for i in GRID_MS:
		var lm := lerpf(LM_MIN, LM_MAX, float(i) / float(GRID_MS - 1))
		var m := pow(10.0, lm)
		var c := visible(Stellar.effective_temp(m))
		out.append(Vector4(c.r, c.g, c.b, Stellar.luminosity(m)))
	return out

## A blackbody's light as the eye takes it, per unit bolometric luminosity: Planck
## through the CIE 1931 functions (PlasmaSpectrum.cmf) into linear sRGB, divided by
## σT⁴ and scaled so the Sun (5772 K) has luminance 1. A hot star puts most of its
## power into the ultraviolet, so per L☉ it is dimmer than the Sun in visible light.
## Tabulated on VIS_N points in ln T over 1000–60 000 K (linear between, within 1e-4 of
## the integral), since a population build asks for it thousands of times.
static func visible(T: float) -> Color:
	if _vis_table.is_empty():
		var sun := _visible_raw(5772.0)
		var y_sun := 0.2126 * sun.r + 0.7152 * sun.g + 0.0722 * sun.b
		for i in VIS_N:
			var c := _visible_raw(exp(lerpf(log(VIS_T0), log(VIS_T1), float(i) / float(VIS_N - 1))))
			_vis_table.append(Color(c.r / y_sun, c.g / y_sun, c.b / y_sun))
	var f := clampf((log(T) - log(VIS_T0)) / (log(VIS_T1) - log(VIS_T0)), 0.0, 1.0) * float(VIS_N - 1)
	var i := mini(int(f), VIS_N - 2)
	return (_vis_table[i] as Color).lerp(_vis_table[i + 1], f - float(i))

## An emission line's light as the eye takes it, per L☉ of the line's power, in visible()'s
## units (the Sun's light has luminance 1 per L☉): its colour-matching value over the Sun's
## luminance per unit power, Σ ȳ B_λ Δλ / ∫B_λ dλ on visible()'s grid. Unclipped: a line
## outside the sRGB gamut (Hα) has a negative channel, to be summed with what shines beside it.
static func visible_line(nm: float) -> Color:
	var sun := _visible_raw(5772.0)
	var y_sun := 0.2126 * sun.r + 0.7152 * sun.g + 0.0722 * sun.b
	# ∫ λ⁻⁵/(e^(hc/λkT) − 1) dλ = (kT/hc)⁴ π⁴/15, in the raw sum's units (λ in m, 5 nm steps).
	var total := pow(5772.0 / 0.0143877688, 4.0) * pow(PI, 4.0) / 15.0
	var c := PlasmaSpectrum.xyz_to_rgb(PlasmaSpectrum.cmf(nm))
	var k := total / (5e-9 * y_sun)
	return Color(c.r * k, c.g * k, c.b * k)

const VIS_N := 1024
const VIS_T0 := 1000.0
const VIS_T1 := 60000.0
static var _vis_table: Array = []
static var _built := {}
static var _built_mutex := Mutex.new()

## The B−V a colour implies: the blackbody whose visible() colour has the same blue to
## red ratio, through Ballesteros' (2012) blackbody B−V relation (BrightStars.bv_teff).
## A blackbody stand-in, so an estimate.
static func bv_of(c: Color) -> float:
	var want := log(c.b / c.r)
	var lo := 1500.0
	var hi := 40000.0
	for i in 60:
		var mid := sqrt(lo * hi)
		var v := visible(mid)
		if log(v.b / v.r) < want: lo = mid
		else: hi = mid
	var t := sqrt(lo * hi)
	var a := -0.4
	var b := 2.0
	for i in 60:
		var m := 0.5 * (a + b)
		if BrightStars.bv_teff(m) > t: a = m
		else: b = m
	return 0.5 * (a + b)

static func _visible_raw(T: float) -> Color:
	var acc := Color(0, 0, 0)
	for i in 81:
		var nm := 380.0 + 5.0 * float(i)
		var lam := nm * 1e-9
		var x := 0.0143877688 / (lam * T)
		var b := 1.0 / (pow(lam, 5.0) * (exp(minf(x, 700.0)) - 1.0))
		acc += PlasmaSpectrum.xyz_to_rgb(PlasmaSpectrum.cmf(nm)) * b
	var t4 := pow(T / 5772.0, 4.0)
	return Color(acc.r / t4, acc.g / t4, acc.b / t4)

# Maraston (1998) Table 1: turnoff mass, then hydrogen and helium burned (M☉) in the
# SGB, RGB, HB, E-AGB and TP-AGB phases (mH, then mH, mHe pairs).
const FUEL := [
	[0.9380, 0.0659, 0.1991, 0.0508, 0.2598, 0.0124, 0.2598, 0.0090, 0.0136],
	[1.0110, 0.0660, 0.1947, 0.0560, 0.2671, 0.0086, 0.2671, 0.0151, 0.0228],
	[1.0588, 0.0653, 0.1921, 0.0583, 0.2693, 0.0076, 0.2710, 0.0191, 0.0289],
	[1.1341, 0.0625, 0.1885, 0.0595, 0.2665, 0.0090, 0.2750, 0.0254, 0.0384],
	[1.2651, 0.0572, 0.1806, 0.0618, 0.2594, 0.0116, 0.2827, 0.0363, 0.0550],
	[1.3844, 0.0509, 0.1689, 0.0646, 0.2472, 0.0139, 0.2921, 0.0463, 0.0701],
	[1.5784, 0.0431, 0.1595, 0.0621, 0.2373, 0.0113, 0.3083, 0.0747, 0.1132],
	[1.7408, 0.0364, 0.1453, 0.0668, 0.2386, 0.0107, 0.2969, 0.0979, 0.1483],
	[1.9985, 0.0307, 0.0993, 0.0815, 0.2349, 0.0119, 0.2802, 0.1427, 0.2163],
	[2.1640, 0.0315, 0.0388, 0.1108, 0.2201, 0.0153, 0.2867, 0.1744, 0.2643],
	[2.3977, 0.0329, 0.0108, 0.1136, 0.2366, 0.0181, 0.2971, 0.1931, 0.2927],
	[2.7777, 0.0331, 0.0041, 0.1109, 0.2647, 0.0110, 0.3448, 0.2071, 0.3138],
	[3.6001, 0.0323, 0.0031, 0.1233, 0.3115, 0.0081, 0.3918, 0.0339, 0.0491],
	[4.7334, 0.0296, 0.0046, 0.1482, 0.3993, 0.0015, 0.4567, 0.0339, 0.0491],
	[5.9188, 0.0267, 0.0059, 0.1898, 0.5211, 0.0000, 0.4210, 0.0339, 0.0491],
	[8.2247, 0.0222, 0.0058, 0.3116, 0.8280, 0.0000, 0.2091, 0.0339, 0.0491],
]
## Each phase's effective temperature (K), read from the ranges in Maraston's Table 3
## for ages above 1 Gyr (log Te: SGB ≈ 3.76, RGB 3.60–3.72, HB ≈ 3.69, E-AGB
## 3.60–3.66); TP-AGB stars are cooler than the table goes. An estimate.
const PHASE_TEFF := [5800.0, 4400.0, 4900.0, 4000.0, 3300.0]
## L☉·yr released per M☉ of hydrogen-equivalent fuel (Renzini & Buzzoni's constant).
const FUEL_LYR := 9.75e10

## Fuel (M☉, helium at a tenth of hydrogen's yield) by phase for a star of mass m,
## linear in the table and held at its ends.
static func fuel(m: float) -> PackedFloat64Array:
	var rows := FUEL
	var i := 0
	while i < rows.size() - 2 and m > float(rows[i + 1][0]): i += 1
	var a: Array = rows[i]
	var b: Array = rows[i + 1]
	var f := clampf((m - float(a[0])) / (float(b[0]) - float(a[0])), 0.0, 1.0)
	var r := func(k: int) -> float: return lerpf(float(a[k]), float(b[k]), f)
	return PackedFloat64Array([r.call(1), r.call(2), r.call(3) + 0.1 * r.call(4), r.call(5) + 0.1 * r.call(6), r.call(7) + 0.1 * r.call(8)])

static func _imf(m: float) -> float:
	# Continuous at 0.5 M☉.
	return pow(m, -1.3) if m < 0.5 else 0.5 * pow(m, -2.3)

## `history`: {"kind": "constant", "gyr": T, "fromGyr": a} formed stars evenly at
## ages a to T Gyr (a = 0 by default); {"kind": "burst", "gyr": A} formed them all A
## Gyr ago.
static func build(history: Dictionary) -> GalPopulation:
	var key := JSON.stringify(history, "", true)
	_built_mutex.lock()
	var hit: GalPopulation = _built.get(key)
	_built_mutex.unlock()
	if hit != null: return hit
	var p := GalPopulation._build(history)
	_built_mutex.lock()
	_built[key] = p
	_built_mutex.unlock()
	return p

static func _build(history: Dictionary) -> GalPopulation:
	var p := GalPopulation.new()
	var age := float(history.gyr) * 1e9
	var young := float(history.get("fromGyr", 0.0)) * 1e9
	var span := age - young
	var constant: bool = history.kind == "constant"
	var formed := 0.0
	var dn := PackedFloat64Array()
	dn.resize(GRID)
	var n := 0.0; var mm := 0.0; var ll := 0.0; var nr := 0.0; var lf := 0.0
	var cr := 0.0; var cg := 0.0; var cb := 0.0
	var dl := (LM_MAX - LM_MIN) / float(GRID)
	for i in GRID:
		var lm := LM_MIN + (float(i) + 0.5) * dl
		var m := pow(10.0, lm)
		var L := Stellar.luminosity(m)
		var tau := Structure.main_sequence_lifetime(m, L)
		var alive := clampf((tau - young) / span, 0.0, 1.0) if constant else (1.0 if tau > age else 0.0)
		# dN/dlog m ∝ m ξ(m)
		var w := m * _imf(m) * alive * dl
		formed += m * m * _imf(m) * dl
		var c := visible(Stellar.effective_temp(m))
		n += w; mm += w * m; ll += w * L
		cr += w * L * c.r; cg += w * L * c.g; cb += w * L * c.b
		if m >= M_RESOLVED:
			nr += w
			dn[i] = w
			p.resolved_mean_l += w * L
			if m >= 8.0: p.resolved_ob += w
		else:
			lf += w * L
	# Stars leaving the main sequence: under a constant history every mass whose
	# lifetime is shorter than T dies at its formation rate; a burst's turnoff mass
	# dies at b = (dN/dlog m)·|dlog m/dt|.
	var lp := 0.0
	var phase_l := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
	for i in GRID:
		var lm := LM_MIN + (float(i) + 0.5) * dl
		var m := pow(10.0, lm)
		var tau := Structure.main_sequence_lifetime(m, Stellar.luminosity(m))
		var rate := 0.0
		if constant:
			if tau < age and tau > young: rate = m * _imf(m) * dl / span
		else:
			var tau2 := Structure.main_sequence_lifetime(pow(10.0, lm + dl), Stellar.luminosity(pow(10.0, lm + dl)))
			if tau >= age and tau2 < age: rate = m * _imf(m) / maxf((tau - tau2) / dl, 1e-30)
		if rate <= 0.0: continue
		var f := fuel(m)
		for j in 5: phase_l[j] += rate * FUEL_LYR * f[j]
	for j in 5:
		lp += phase_l[j]
		var c := visible(PHASE_TEFF[j])
		cr += phase_l[j] * c.r; cg += phase_l[j] * c.g; cb += phase_l[j] * c.b
	p.post_ms_light = lp / (ll + lp)
	ll += lp
	p.light_per_formed = ll / formed
	lf += lp
	p.resolved_mean_l /= nr
	p.resolved_ob /= nr
	p.mean_mass = mm / n
	p.mean_l = ll / n
	p.resolved_per_l = (nr / n) / p.mean_l
	p.faint_light = lf / ll
	p.color = Color(cr / ll, cg / ll, cb / ll)
	p.phase_l = phase_l
	var cdf := 0.0
	var k := 1
	p.quantiles.append(log(M_RESOLVED) / log(10.0))
	for i in GRID:
		var before := cdf
		cdf += dn[i] / nr
		while k < 65 and cdf >= GalPopulation.q_level(k):
			var f := (GalPopulation.q_level(k) - before) / maxf(cdf - before, 1e-300)
			p.quantiles.append(LM_MIN + (float(i) + f) * dl)
			k += 1
	while p.quantiles.size() < 65: p.quantiles.append(LM_MAX)
	return p
