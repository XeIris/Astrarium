class_name GalEddington
extends RefCounted

# An isotropic spherical component in equilibrium: a Hernquist (1990) density sampled with the
# distribution function Eddington's formula gives it in the galaxy's whole spherical potential
# (Binney & Tremaine 2008, eq. 4.46b), so a halo or bulge set live with a disc inside it stays
# put. The disc enters that potential spherically averaged, as its enclosed mass. Units: G M in
# kpc³ Myr⁻², kpc, kpc/Myr. docs/physics/galaxies.md#live.

const GRID := 600
const ROWS := 160
const Q_STEPS := 64

## The component: G M and scale a of its Hernquist density, cut off at rmax.
var gm := 0.0
var a := 1.0
var rmax := 1.0
## The potential's parts: ["hernquist", G M, a] or ["disc", G M, R_d].
var parts: Array = []
var r := PackedFloat64Array()
var psi := PackedFloat64Array()
var f := PackedFloat64Array()
## The speed CDF at ROWS radii: Q_STEPS values of v/v_esc per row.
var row_r := PackedFloat64Array()
var cdf := PackedFloat64Array()

func _init(comp_gm: float, comp_a: float, cut: float, potential: Array) -> void:
	gm = comp_gm
	a = comp_a
	rmax = cut
	parts = potential
	_tabulate()

## Ψ = −Φ (kpc² Myr⁻²) at radius x.
func psi_at(x: float) -> float:
	var s := 0.0
	for p in parts:
		if p[0] == "hernquist": s += float(p[1]) / (x + float(p[2]))
		else:
			var rd := float(p[2])
			var y := x / rd
			# An exponential disc's mass within x taken as a sphere: the potential of that
			# shell structure is G M [(1 − (1 + y) e^−y)/x + e^−y / R_d].
			s += float(p[1]) * ((1.0 - (1.0 + y) * exp(-y)) / x + exp(-y) / rd)
	return s

## G M(<x) of the whole potential.
func gm_within(x: float) -> float:
	var s := 0.0
	for p in parts:
		if p[0] == "hernquist":
			var ap := float(p[2])
			s += float(p[1]) * x * x / ((x + ap) * (x + ap))
		else:
			var y := x / float(p[2])
			s += float(p[1]) * (1.0 - (1.0 + y) * exp(-y))
	return s

func _rho(x: float) -> float:
	return a / (x * pow(x + a, 3.0))

func _tabulate() -> void:
	var scale := a
	for p in parts: scale = maxf(scale, float(p[2]))
	var lo := log(1e-4 * a)
	var hi := log(1e3 * scale)
	r.resize(GRID)
	psi.resize(GRID)
	var drho_dpsi := PackedFloat64Array()
	drho_dpsi.resize(GRID)
	for k in GRID:
		var x := exp(lo + (hi - lo) * k / (GRID - 1))
		r[k] = x
		psi[k] = psi_at(x)
		var drho_dr := -_rho(x) * (1.0 / x + 3.0 / (x + a))
		var dpsi_dr := -gm_within(x) / (x * x)
		drho_dpsi[k] = drho_dr / dpsi_dr
	# F(ℰ) = ∫₀^ℰ dρ/dΨ dΨ / √(ℰ − Ψ), dρ/dΨ constant on each interval of the grid and the
	# square root integrated exactly across it; f(ℰ) ∝ dF/dℰ.
	var big_f := PackedFloat64Array()
	big_f.resize(GRID)
	for k in GRID:
		var e := psi[k]
		var s := 0.0
		for j in range(k, GRID - 1):
			var g := 0.5 * (drho_dpsi[j] + drho_dpsi[j + 1])
			s += g * 2.0 * (sqrt(maxf(e - psi[j + 1], 0.0)) - sqrt(maxf(e - psi[j], 0.0)))
		big_f[k] = s
	f.resize(GRID)
	for k in GRID:
		var k0 := maxi(k - 1, 0)
		var k1 := mini(k + 1, GRID - 1)
		f[k] = maxf((big_f[k0] - big_f[k1]) / (psi[k0] - psi[k1]), 0.0)
	# Speeds: p(q) ∝ q² f(Ψ (1 − q²)) for q = v / v_esc, at ROWS radii out to rmax.
	row_r.resize(ROWS)
	cdf.resize(ROWS * Q_STEPS)
	var rlo := log(1e-3 * a)
	var rhi := log(rmax)
	for j in ROWS:
		var x := exp(rlo + (rhi - rlo) * j / (ROWS - 1))
		row_r[j] = x
		var ps := psi_at(x)
		var acc := 0.0
		var prev := 0.0
		cdf[j * Q_STEPS] = 0.0
		for q in range(1, Q_STEPS):
			var u := float(q) / (Q_STEPS - 1)
			var p := u * u * f_at(ps * (1.0 - u * u))
			acc += 0.5 * (p + prev) / (Q_STEPS - 1)
			prev = p
			cdf[j * Q_STEPS + q] = acc
		for q in Q_STEPS: cdf[j * Q_STEPS + q] /= maxf(acc, 1e-300)

## f at binding energy ℰ, linear between grid points (ψ falls along the grid).
func f_at(e: float) -> float:
	if e <= psi[GRID - 1]: return 0.0
	if e >= psi[0]: return f[0]
	var lo := 0
	var hi := GRID - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if psi[mid] > e: lo = mid
		else: hi = mid
	var w := (e - psi[hi]) / (psi[lo] - psi[hi])
	return f[hi] + w * (f[lo] - f[hi])

## count particles about the origin: positions and velocities, 3 each. They come in mirrored
## pairs (x, v) and (−x, −v), so the whole sits exactly at the origin at rest.
func sample(rng: RandomNumberGenerator, count: int) -> Array:
	var pos := PackedFloat64Array()
	var vel := PackedFloat64Array()
	pos.resize(3 * count)
	vel.resize(3 * count)
	# M(<x)/M = u² with u = x/(x + a), inverted, the cut-off as u's largest value.
	var umax := rmax / (rmax + a)
	var rlo := log(1e-3 * a)
	var rhi := log(rmax)
	for i in count:
		if i % 2 == 1:
			for c in 3:
				pos[3 * i + c] = -pos[3 * i - 3 + c]
				vel[3 * i + c] = -vel[3 * i - 3 + c]
			continue
		var s := sqrt(rng.randf()) * umax
		var x := maxf(a * s / (1.0 - s), 1e-3 * a)
		var d := _direction(rng)
		var w := (log(x) - rlo) / (rhi - rlo) * (ROWS - 1)
		var j := clampi(int(floor(w)), 0, ROWS - 2)
		if rng.randf() < clampf(w - j, 0.0, 1.0): j += 1
		var q := _invert(j, rng.randf())
		var v := q * sqrt(2.0 * psi_at(x))
		var e := _direction(rng)
		for c in 3:
			pos[3 * i + c] = d[c] * x
			vel[3 * i + c] = e[c] * v
	return [pos, vel]

func _invert(j: int, u: float) -> float:
	var o := j * Q_STEPS
	for q in range(1, Q_STEPS):
		if cdf[o + q] >= u:
			var c0 := cdf[o + q - 1]
			var t := (u - c0) / maxf(cdf[o + q] - c0, 1e-300)
			return (q - 1 + t) / (Q_STEPS - 1)
	return 1.0

static func _direction(rng: RandomNumberGenerator) -> Vector3:
	var z := 2.0 * rng.randf() - 1.0
	var phi := TAU * rng.randf()
	var s := sqrt(maxf(1.0 - z * z, 0.0))
	return Vector3(s * cos(phi), s * sin(phi), z)
