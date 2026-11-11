class_name GalOrbits
extends RefCounted

# Galaxies' centres under each other's gravity and dynamical friction, by van der Marel et al.'s
# (2012b, §2.2 and Appendix A) semi-analytic method, which they calibrated against N-body
# encounters of the Milky Way, M31 and M33. Each galaxy is one Hernquist halo; the pull of
# galaxy i on galaxy j is −G M_i/(r + a_i)², as if j's mass sat at its centre, softened to a
# constant density inside SOFT. A galaxy is slowed by Chandrasekhar's friction in another
# at least FRICTION_RATIO times its mass, or in one of comparable mass. Units: kpc, Myr,
# 10¹⁰ M☉. docs/physics/galaxies.md#encounters-phase-4.

## Constant-density softening at each centre, kpc (their §2.2).
const SOFT := 2.0
## Coulomb logarithm ln Λ = max(L, α ln(r / (C a_s))), a_s the slowed galaxy's scale (their
## eq. A1): (α, C, L) for galaxies of roughly equal mass and for a satellite (their Appendix A).
const LAMBDA_EQUAL := [0.15, 0.17, 0.02]
const LAMBDA_SATELLITE := [1.0, 1.22, 0.0]
## Galaxies within this mass ratio count as equal; a lighter one by more is a satellite, and
## does not slow the heavier (their M33 on the MW and M31).
const FRICTION_RATIO := 1.5

## Each galaxy: name, G M (kpc³ Myr⁻²), Hernquist a (kpc).
var names := PackedStringArray()
var gm := PackedFloat64Array()
var a := PackedFloat64Array()
## Positions and velocities, 3 per galaxy (kpc, kpc/Myr).
var pos := PackedFloat64Array()
var vel := PackedFloat64Array()
var t := 0.0
var friction := true

## A halo's Hernquist mass and scale from its virial mass (M☉) and concentration, matched to
## the NFW halo's density as r → 0 and its mass within r200 (van der Marel et al. 2012a,
## Appendix A: h 0.7, Ωm 0.27, Δvir 360, so ρ200/ρvir = 2.058). Returns [M_H (M☉), a (kpc),
## r_vir, c200, a/r_s].
static func hernquist_halo(mvir: float, c: float) -> Array:
	var h := 0.7
	var rvir := 206.0 / h * pow(360.0 * 0.27 / 97.2, -1.0 / 3.0) * pow(mvir / (1e12 / h), 1.0 / 3.0)
	var rs := rvir / c
	var c200 := c
	for i in 200: c200 = c * pow(_f(c200) / (2.058 * _f(c)), 1.0 / 3.0)
	var a_rs := 1.0 / (pow(2.0 * _f(c200), -0.5) - 1.0 / c200)
	return [mvir * a_rs * a_rs / (2.0 * _f(c)), a_rs * rs, rvir, c200, a_rs]

static func _f(x: float) -> float:
	return log(1.0 + x) - x / (1.0 + x)

## Adds a galaxy of mass m_sun at p (kpc) moving at v (kpc/Myr).
func add(name: String, m_sun: float, scale: float, p: Vector3, v: Vector3) -> void:
	names.append(name)
	gm.append(GalUnits.G * m_sun / GalUnits.MASS_UNIT_SUN)
	a.append(scale)
	pos.append_array([p.x, p.y, p.z])
	vel.append_array([v.x, v.y, v.z])

func count() -> int:
	return gm.size()

func position(i: int) -> Vector3:
	return Vector3(pos[3 * i], pos[3 * i + 1], pos[3 * i + 2])

func velocity(i: int) -> Vector3:
	return Vector3(vel[3 * i], vel[3 * i + 1], vel[3 * i + 2])

## Hernquist's isotropic one-dimensional dispersion (1990, eq. 10), kpc/Myr.
static func sigma(gm_i: float, a_i: float, r: float) -> float:
	var y := maxf(r, 1e-6) / a_i
	var s2 := gm_i / (12.0 * a_i) * (12.0 * y * pow(1.0 + y, 3.0) * log((1.0 + y) / y) - y / (1.0 + y) * (25.0 + 52.0 * y + 42.0 * y * y + 12.0 * y * y * y))
	return sqrt(maxf(s2, 0.0))

## Accelerations for positions p and velocities v (3 per galaxy), written into acc.
func accel(p: PackedFloat64Array, v: PackedFloat64Array, acc: PackedFloat64Array) -> void:
	var n := count()
	acc.fill(0.0)
	for j in n:
		for i in n:
			if i == j: continue
			var dx := p[3 * i] - p[3 * j]
			var dy := p[3 * i + 1] - p[3 * j + 1]
			var dz := p[3 * i + 2] - p[3 * j + 2]
			var r := sqrt(dx * dx + dy * dy + dz * dz)
			var f := gm[i] / pow(r + a[i], 2.0) / r if r > SOFT else gm[i] / pow(SOFT + a[i], 2.0) / SOFT
			acc[3 * j] += f * dx
			acc[3 * j + 1] += f * dy
			acc[3 * j + 2] += f * dz
	if friction: _friction(p, v, acc)
	# Neither the pulls nor the friction are equal and opposite: the system's mean acceleration
	# is taken out, as van der Marel et al. do.
	var mt := 0.0
	var cm := [0.0, 0.0, 0.0]
	for j in n:
		mt += gm[j]
		for k in 3: cm[k] += gm[j] * acc[3 * j + k]
	for j in n:
		for k in 3: acc[3 * j + k] -= cm[k] / mt

func _friction(p: PackedFloat64Array, v: PackedFloat64Array, acc: PackedFloat64Array) -> void:
	var n := count()
	for j in n:
		for i in n:
			if i == j or gm[j] > FRICTION_RATIO * gm[i]: continue
			var lam: Array = LAMBDA_EQUAL if gm[i] < FRICTION_RATIO * gm[j] else LAMBDA_SATELLITE
			var dx := p[3 * j] - p[3 * i]
			var dy := p[3 * j + 1] - p[3 * i + 1]
			var dz := p[3 * j + 2] - p[3 * i + 2]
			var r := maxf(sqrt(dx * dx + dy * dy + dz * dz), 1e-6)
			var ux := v[3 * j] - v[3 * i]
			var uy := v[3 * j + 1] - v[3 * i + 1]
			var uz := v[3 * j + 2] - v[3 * i + 2]
			var u := sqrt(ux * ux + uy * uy + uz * uz)
			if u < 1e-12: continue
			var ln_l := maxf(float(lam[2]), float(lam[0]) * log(r / (float(lam[1]) * a[j])))
			var x := u / (sqrt(2.0) * maxf(sigma(gm[i], a[i], r), 1e-12))
			var rho_g := gm[i] / TAU * a[i] / (r * pow(r + a[i], 3.0))
			# 4π G² M ρ ln Λ / u² [erf X − 2X e^{−X²}/√π], with G M and G ρ.
			var drag := 4.0 * PI * gm[j] * rho_g * ln_l / (u * u) * (_erf(x) - 2.0 * x / sqrt(PI) * exp(-x * x))
			acc[3 * j] -= drag * ux / u
			acc[3 * j + 1] -= drag * uy / u
			acc[3 * j + 2] -= drag * uz / u

## Abramowitz & Stegun 7.1.26, |error| < 1.5e-7, for x ≥ 0.
static func _erf(x: float) -> float:
	var t := 1.0 / (1.0 + 0.3275911 * x)
	var y := t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))))
	return 1.0 - y * exp(-x * x)

## One classical Runge–Kutta step of dt Myr: the friction depends on velocity, so the scheme
## need not be symplectic, and with friction nothing is conserved for it to keep.
func step(dt: float) -> void:
	var n := 3 * count()
	var k1v := PackedFloat64Array(); k1v.resize(n)
	var k2v := PackedFloat64Array(); k2v.resize(n)
	var k3v := PackedFloat64Array(); k3v.resize(n)
	var k4v := PackedFloat64Array(); k4v.resize(n)
	var p := PackedFloat64Array(); p.resize(n)
	var v := PackedFloat64Array(); v.resize(n)
	accel(pos, vel, k1v)
	for k in n:
		p[k] = pos[k] + 0.5 * dt * vel[k]
		v[k] = vel[k] + 0.5 * dt * k1v[k]
	var v2 := v.duplicate()
	accel(p, v, k2v)
	for k in n:
		p[k] = pos[k] + 0.5 * dt * v2[k]
		v[k] = vel[k] + 0.5 * dt * k2v[k]
	var v3 := v.duplicate()
	accel(p, v, k3v)
	for k in n:
		p[k] = pos[k] + dt * v3[k]
		v[k] = vel[k] + dt * k3v[k]
	var v4 := v.duplicate()
	accel(p, v, k4v)
	for k in n:
		pos[k] += dt / 6.0 * (vel[k] + 2.0 * v2[k] + 2.0 * v3[k] + v4[k])
		vel[k] += dt / 6.0 * (k1v[k] + 2.0 * k2v[k] + 2.0 * k3v[k] + k4v[k])
	t += dt

## In double: positions are physics state.
func separation(i: int, j: int) -> float:
	var dx := pos[3 * i] - pos[3 * j]
	var dy := pos[3 * i + 1] - pos[3 * j + 1]
	var dz := pos[3 * i + 2] - pos[3 * j + 2]
	return sqrt(dx * dx + dy * dy + dz * dz)
