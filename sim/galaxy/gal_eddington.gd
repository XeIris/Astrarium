class_name GalEddington
extends RefCounted

# An isotropic spherical component in equilibrium: a Hernquist (1990) density, or an NFW one
# tapered as Barnes & Hibbard (2009, eq. B2) taper theirs, sampled with the distribution
# function Eddington's formula gives it in the galaxy's whole spherical potential (Binney &
# Tremaine 2008, eq. 4.46b), so a halo or bulge set live with a disc inside it stays put. The
# disc enters that potential spherically averaged, as its enclosed mass. Units: G M in kpc³
# Myr⁻², kpc, kpc/Myr. docs/physics/galaxies.md#live.

const GRID := 600
const ROWS := 160
const Q_STEPS := 64

## The component: G M and scale a of its Hernquist density, cut off at rmax; or, with `taper`
## > 0, an NFW density of scale a tapered beyond `taper` (gm is then G M within a).
var gm := 0.0
var a := 1.0
var rmax := 1.0
var taper := 0.0
## The potential's parts: ["hernquist", G M, a], ["disc", G M, R_d] or ["nfw", G M(<a), a, b]
## (NFWShape's).
var parts: Array = []
var r := PackedFloat64Array()
var psi := PackedFloat64Array()
var f := PackedFloat64Array()
## The speed CDF at ROWS radii: Q_STEPS values of v/v_esc per row.
var row_r := PackedFloat64Array()
var cdf := PackedFloat64Array()

func _init(comp_gm: float, comp_a: float, cut: float, potential: Array, nfw_taper := 0.0) -> void:
	gm = comp_gm
	a = comp_a
	rmax = cut
	parts = potential
	taper = nfw_taper
	_tabulate()

## An NFW profile of scale a, tapered beyond b as Barnes & Hibbard (2009, eq. B2) taper it:
## ρ ∝ 1/(r (r + a)²) inside b and ρ(b) (r/b)^β e^(−(r − b)/a) beyond, β fixed so the density
## and its slope are continuous at b. Normalised to unit mass within a; tabulated once per
## (a, b): its mass within r and ∫_r^∞ 4π ρ r dr, the outer part of the potential.
class NFWShape:
	const N := 2000
	var a := 1.0
	var b := 1.0
	var beta := 0.0
	var lr := PackedFloat64Array()
	var mass := PackedFloat64Array()
	var outer := PackedFloat64Array()
	var total := 0.0
	func _init(sa: float, sb: float) -> void:
		a = sa
		b = sb
		beta = -1.0 - 2.0 * b / (b + a) + b / a
		var lo := log(1e-6 * a)
		var hi := log(b + 60.0 * a)
		lr.resize(N)
		mass.resize(N)
		outer.resize(N)
		var dl := (hi - lo) / (N - 1)
		var prev := 0.0
		mass[0] = 0.0
		for k in N:
			lr[k] = lo + dl * k
		# dM = 4π r³ ρ dln r, trapezoids in ln r; the first point holds the mass inside it,
		# r²/(2a²)·(1/(ln2 − ½)) to leading order.
		mass[0] = pow(exp(lo), 2.0) / (2.0 * a * a) / (log(2.0) - 0.5)
		prev = _dm(exp(lo))
		for k in range(1, N):
			var d := _dm(exp(lr[k]))
			mass[k] = mass[k - 1] + 0.5 * (prev + d) * dl
			prev = d
		total = mass[N - 1]
		outer[N - 1] = 0.0
		prev = _dout(exp(lr[N - 1]))
		var k := N - 2
		while k >= 0:
			var d := _dout(exp(lr[k]))
			outer[k] = outer[k + 1] + 0.5 * (prev + d) * dl
			prev = d
			k -= 1
	func rho(x: float) -> float:
		if x <= b: return 1.0 / (4.0 * PI * (log(2.0) - 0.5)) / (x * (x + a) * (x + a))
		return rho(b) * pow(x / b, beta) * exp(-(x - b) / a)
	func drho_dr(x: float) -> float:
		if x <= b: return -rho(x) * (1.0 / x + 2.0 / (x + a))
		return rho(x) * (beta / x - 1.0 / a)
	func _dm(x: float) -> float:
		return 4.0 * PI * x * x * x * rho(x)
	func _dout(x: float) -> float:
		return 4.0 * PI * x * x * rho(x)
	## Mass within x (in units of the mass within a) and ∫_x^∞ 4π ρ r dr.
	func at(x: float) -> Vector2:
		var l := log(x)
		if l <= lr[0]: return Vector2(mass[0] * pow(x / exp(lr[0]), 2.0), outer[0])
		if l >= lr[N - 1]: return Vector2(total, 0.0)
		var w := (l - lr[0]) / (lr[1] - lr[0])
		var k := int(w)
		var t := w - k
		return Vector2(lerpf(mass[k], mass[k + 1], t), lerpf(outer[k], outer[k + 1], t))

static var _shapes := {}

static func nfw_shape(sa: float, sb: float) -> NFWShape:
	var key := "%s|%s" % [sa, sb]
	if not _shapes.has(key): _shapes[key] = NFWShape.new(sa, sb)
	return _shapes[key]

## Ψ = −Φ (kpc² Myr⁻²) at radius x.
func psi_at(x: float) -> float:
	var s := 0.0
	for p in parts:
		if p[0] == "hernquist": s += float(p[1]) / (x + float(p[2]))
		elif p[0] == "nfw":
			var m := nfw_shape(float(p[2]), float(p[3])).at(x)
			s += float(p[1]) * (m.x / x + m.y)
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
		elif p[0] == "nfw":
			s += float(p[1]) * nfw_shape(float(p[2]), float(p[3])).at(x).x
		else:
			var y := x / float(p[2])
			s += float(p[1]) * (1.0 - (1.0 + y) * exp(-y))
	return s

func _rho(x: float) -> float:
	if taper > 0.0: return nfw_shape(a, taper).rho(x)
	return a / (x * pow(x + a, 3.0))

func _drho_dr(x: float) -> float:
	if taper > 0.0: return nfw_shape(a, taper).drho_dr(x)
	return -_rho(x) * (1.0 / x + 3.0 / (x + a))

func _tabulate() -> void:
	var scale := maxf(a, taper)
	for p in parts: scale = maxf(scale, float(p[2]) if p[0] != "nfw" else float(p[3]) + 10.0 * float(p[2]))
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
		var drho_dr := _drho_dr(x)
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
	# Hernquist: M(<x)/M = u² with u = x/(x + a), inverted, the cut-off as u's largest value.
	var umax := rmax / (rmax + a)
	var shape: NFWShape = nfw_shape(a, taper) if taper > 0.0 else null
	var mcut := shape.at(rmax).x if shape != null else 0.0
	var rlo := log(1e-3 * a)
	var rhi := log(rmax)
	for i in count:
		if i % 2 == 1:
			for c in 3:
				pos[3 * i + c] = -pos[3 * i - 3 + c]
				vel[3 * i + c] = -vel[3 * i - 3 + c]
			continue
		var x := 0.0
		if shape != null: x = maxf(_nfw_radius(shape, rng.randf() * mcut), 1e-3 * a)
		else:
			var s := sqrt(rng.randf()) * umax
			x = maxf(a * s / (1.0 - s), 1e-3 * a)
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

## The radius within which the tapered NFW holds mass m (bisection on its table).
static func _nfw_radius(shape: NFWShape, m: float) -> float:
	var lo := 0
	var hi := NFWShape.N - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if shape.mass[mid] < m: lo = mid
		else: hi = mid
	var t := (m - shape.mass[lo]) / maxf(shape.mass[hi] - shape.mass[lo], 1e-300)
	return exp(lerpf(shape.lr[lo], shape.lr[hi], clampf(t, 0.0, 1.0)))

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
