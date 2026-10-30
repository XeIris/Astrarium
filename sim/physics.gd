class_name Physics
extends RefCounted

# AU, M☉, years; DVec3 doubles. Newtonian pair gravity plus pairwise 1PN, integrated
# by fourth-order Yoshida; optional circular-power drag illustrates GW losses. See
# docs/physics/compact-dynamics.md.

const G := 4.0 * PI * PI                # 39.478 AU³ M☉⁻¹ yr⁻²; exact for Rocketry.YR_S
const C := Rocketry.C_MS * Rocketry.YR_S / Rocketry.AU_M   # speed of light, AU/yr (63242.27)
const AU_PER_RSUN := 0.00465047         # solar radius in AU
const AU_PER_KM := 6.68459e-9
static var DOUBLE_MIN_NORMAL := pow(2.0, -1022.0)
static var DOUBLE_MAX := (2.0 - pow(2.0, -52.0)) * pow(2.0, 1023.0)

## Schwarzschild radius (AU) for a given mass in M☉.
static func schwarzschild(mass_sun: float) -> float:
	return 2.0 * G * mass_sun / (C * C)

## Black-hole merger remnant for non-spinning holes, from the symmetric mass ratio
## η = m₁m₂/M². Radiated fraction: Barausse, Morozova & Rezzolla (2012), 4.8% at η = ¼
## (GW150914 radiated 3.1 of 65 M☉). Spin: Rezzolla et al. (2008), a* = 0.686 at η = ¼.
## Recoil, km/s: González et al. (2007), zero for equal masses, 175 km/s at its peak.
static func merger_radiated_fraction(eta: float) -> float:
	return eta * (0.0559745 + eta * (0.580951 + eta * (-0.960673 + eta * 3.35241)))
static func merger_spin(eta: float) -> float:
	return eta * (2.0 * sqrt(3.0) + eta * (-3.5171 + eta * 2.5763))
static func merger_kick_kms(eta: float) -> float:
	return 1.2e4 * eta * eta * sqrt(maxf(1.0 - 4.0 * eta, 0.0)) * (1.0 - 0.93 * eta)

## Physical stellar radius (AU) from mass via main-sequence R ∝ M^0.8.
static func stellar_radius(mass_sun: float) -> float:
	return pow(maxf(mass_sun, 0.05), 0.8) * AU_PER_RSUN

# Roche limit (AU) for a self-gravitating body near `massSun`:
#   d = 2.44 R* (rho* / rho_body)^(1/3)
# A few stellar radii for a rocky world round a main-sequence star: the honest
# destruction distance for close passes.
const RHO_SUN := 1.41                   # g/cm^3
static func roche_limit(mass_sun: float, body_density: float = 5.5) -> float:
	var r_au := stellar_radius(mass_sun)
	var r_sun := r_au / AU_PER_RSUN
	var rho_star := RHO_SUN * mass_sun / (r_sun * r_sun * r_sun)
	return 2.44 * r_au * U.cbrt(rho_star / body_density)

# Acceleration field. Fills every live body's `acc`; false when a force is not
# representable. The 1PN terms read each body's current `vel`.
static func compute_accel(bodies: Array) -> bool:
	if not compute_newtonian(bodies): return false
	if not post_newtonian: return true
	_eih(bodies)
	for b in bodies:
		if b.alive and not b.acc.is_finite_v(): return false
	return true

# The Newtonian part. Pairs at ordinary distances take the inline path; the rest use
# _accumulate_pair, which yields identical bits wherever both apply.
static func compute_newtonian(bodies: Array) -> bool:
	var n := bodies.size()
	var soft_sq := PackedFloat64Array()
	soft_sq.resize(n)
	var is_bh := PackedByteArray()
	is_bh.resize(n)
	for k in n:
		var b: Body = bodies[k]
		b.acc.x = 0.0; b.acc.y = 0.0; b.acc.z = 0.0
		var soft := softening_of(b)
		soft_sq[k] = soft * soft
		is_bh[k] = 1 if b.type == "bh" else 0
	for i in n:
		var a: Body = bodies[i]
		if not a.alive: continue
		var ap := a.pos
		var aa := a.acc
		for j in range(i + 1, n):
			var b: Body = bodies[j]
			if not b.alive: continue
			var rx := b.pos.x - ap.x
			var ry := b.pos.y - ap.y
			var rz := b.pos.z - ap.z
			var squared := rx * rx + ry * ry + rz * rz
			if squared >= DOUBLE_MIN_NORMAL and squared <= DOUBLE_MAX:
				var dist := sqrt(squared)
				var kernel: float
				var denominator: float
				if is_bh[i] != 0 or is_bh[j] != 0:
					# Weak-field point masses; horizons set contact, not a binary force law.
					denominator = dist * dist
					kernel = G / denominator
				else:
					var d2 := dist * dist + 0.5 * (soft_sq[i] + soft_sq[j])
					denominator = d2 * sqrt(d2)
					kernel = G * dist / denominator
				var fA := kernel * b.mass
				var fB := kernel * a.mass
				if fA > 0.0 and fA <= DOUBLE_MAX and fB > 0.0 and fB <= DOUBLE_MAX \
						and kernel >= DOUBLE_MIN_NORMAL and denominator >= DOUBLE_MIN_NORMAL:
					var inv := 1.0 / dist
					rx *= inv; ry *= inv; rz *= inv           # unit vector a→b
					aa.x += rx * fA; aa.y += ry * fA; aa.z += rz * fA
					b.acc.x -= rx * fB; b.acc.y -= ry * fB; b.acc.z -= rz * fB
					continue
			if not _accumulate_pair(a, b, rx, ry, rz): return false

	for b in bodies:
		if b.alive and not b.acc.is_finite_v(): return false
	return true

# One pair's mutual acceleration with exceptional intermediates rescaled.
static func _accumulate_pair(a: Body, b: Body, rx: float, ry: float, rz: float) -> bool:
	var dist := distance_xyz(rx, ry, rz)
	if dist == 0.0: return true
	if not is_finite(dist): return false
	var inv := 1.0 / dist
	var kernel: float
	var denominator: float
	if a.type == "bh" or b.type == "bh":
		denominator = dist * dist
		kernel = G / denominator
	else:
		var d2 := dist * dist + pair_softening_sq(a, b)
		denominator = d2 * sqrt(d2)
		kernel = G * dist / denominator
	var fA := kernel * b.mass
	var fB := kernel * a.mass
	if not is_finite(fA) or not is_finite(fB) or fA == 0.0 or fB == 0.0 or (kernel > 0.0 and kernel < DOUBLE_MIN_NORMAL) or denominator < DOUBLE_MIN_NORMAL or not is_finite(inv):
		var softened := dist
		if a.type != "bh" and b.type != "bh":
			softened = softened_distance(dist, a, b)
		fA = scaled_product([G, b.mass, dist], [softened, softened, softened])
		fB = scaled_product([G, a.mass, dist], [softened, softened, softened])
		if not is_finite(fA) or not is_finite(fB): return false
		rx /= dist; ry /= dist; rz /= dist
	else:
		rx *= inv; ry *= inv; rz *= inv
	a.acc.x += rx * fA; a.acc.y += ry * fA; a.acc.z += rz * fA
	b.acc.x -= rx * fB; b.acc.y -= ry * fB; b.acc.z -= rz * fB
	return true

## First post-Newtonian N-body gravity: the Einstein–Infeld–Hoffmann equations as the
## JPL ephemerides use them (Newhall, Standish & Williams 1983, β = γ = 1), added to the
## Newtonian accelerations already in `acc`, which also stand in for the bodies'
## accelerations inside the terms (an O(1/c⁴) difference). They follow from a
## Lagrangian, so eih_energy() is conserved; summed two-body terms are not, and drift
## in a hierarchical triple. With the Sun alone they reduce to the Schwarzschild
## test-particle acceleration: Mercury's 42.98″ per century. Softened bodies take no
## part; a pair past the weak field, G(m₁+m₂)/(rc²) ≥ 0.1, drops both bodies. The
## native kernel repeats this operation for operation. docs/physics/compact-dynamics.md.
const PN_LIMIT := 0.1
## Off only for checks of the Newtonian potential itself.
static var post_newtonian := true

## Bodies in the 1PN set, and each one's Newtonian potential G·Σm/r over that set.
static func _pn_set(bodies: Array) -> Array:
	var n := bodies.size()
	var ok := PackedByteArray()
	ok.resize(n)
	for k in n:
		var b: Body = bodies[k]
		ok[k] = 1 if b.alive and (b.type == "bh" or b.softening == 0.0) else 0
	var limit := PN_LIMIT * C * C
	for i in n:
		for j in range(i + 1, n):
			if ok[i] == 0 or ok[j] == 0: continue
			var a: Body = bodies[i]; var b: Body = bodies[j]
			var r := distance_xyz(b.pos.x - a.pos.x, b.pos.y - a.pos.y, b.pos.z - a.pos.z)
			if not (G * (a.mass + b.mass) / r < limit):
				ok[i] = 0; ok[j] = 0
	var phi := PackedFloat64Array()
	phi.resize(n)
	for i in n:
		if ok[i] == 0: continue
		var a: Body = bodies[i]
		var sum := 0.0
		for l in n:
			if l == i or ok[l] == 0: continue
			var b: Body = bodies[l]
			sum += G * b.mass / distance_xyz(b.pos.x - a.pos.x, b.pos.y - a.pos.y, b.pos.z - a.pos.z)
		phi[i] = sum
	return [ok, phi]

## `pn` is _pn_set(bodies) when the caller already has it for these positions.
static func _eih(bodies: Array, pn: Array = []) -> void:
	var n := bodies.size()
	if pn.is_empty(): pn = _pn_set(bodies)
	var ok: PackedByteArray = pn[0]
	var phi: PackedFloat64Array = pn[1]
	var aN := PackedFloat64Array()
	aN.resize(n * 3)
	for k in n:
		var b: Body = bodies[k]
		aN[k * 3] = b.acc.x; aN[k * 3 + 1] = b.acc.y; aN[k * 3 + 2] = b.acc.z
	var c2 := C * C
	for i in n:
		if ok[i] == 0: continue
		var a: Body = bodies[i]
		var vi2 := a.vel.x * a.vel.x + a.vel.y * a.vel.y + a.vel.z * a.vel.z
		var cx := 0.0; var cy := 0.0; var cz := 0.0
		for j in n:
			if j == i or ok[j] == 0: continue
			var b: Body = bodies[j]
			var dx := b.pos.x - a.pos.x; var dy := b.pos.y - a.pos.y; var dz := b.pos.z - a.pos.z
			var r := distance_xyz(dx, dy, dz)
			var mu := G * b.mass
			var inv_r3 := 1.0 / (r * r * r)
			var ajx := aN[j * 3]; var ajy := aN[j * 3 + 1]; var ajz := aN[j * 3 + 2]
			var vj2 := b.vel.x * b.vel.x + b.vel.y * b.vel.y + b.vel.z * b.vel.z
			var vivj := a.vel.x * b.vel.x + a.vel.y * b.vel.y + a.vel.z * b.vel.z
			var nvj := -(dx * b.vel.x + dy * b.vel.y + dz * b.vel.z) / r
			var xa := dx * ajx + dy * ajy + dz * ajz
			var coef := -4.0 * phi[i] - phi[j] + vi2 + 2.0 * vj2 - 4.0 * vivj - 1.5 * nvj * nvj + 0.5 * xa
			var t1 := mu * inv_r3 * coef
			var s := -(dx * (4.0 * a.vel.x - 3.0 * b.vel.x) + dy * (4.0 * a.vel.y - 3.0 * b.vel.y) + dz * (4.0 * a.vel.z - 3.0 * b.vel.z))
			var t2 := mu * inv_r3 * s
			var t3 := 3.5 * mu / r
			cx += t1 * dx + t2 * (a.vel.x - b.vel.x) + t3 * ajx
			cy += t1 * dy + t2 * (a.vel.y - b.vel.y) + t3 * ajy
			cz += t1 * dz + t2 * (a.vel.z - b.vel.z) + t3 * ajz
		cx /= c2; cy /= c2; cz /= c2
		if is_finite(cx) and is_finite(cy) and is_finite(cz):
			a.acc.x += cx; a.acc.y += cy; a.acc.z += cz

## The 1PN part of the EIH Lagrangian's conserved energy (Landau & Lifshitz, Classical
## Theory of Fields, §106), over the same set as _eih:
## Σ⅜mv⁴ + Σ_{a≠b} (Gm_am_b/2r)[3v_a² − ⁷⁄₂v_a·v_b − (n·v_a)(n·v_b)/2] + Σ m_aΦ_a²/2, over c².
static func eih_energy(bodies: Array) -> float:
	if not post_newtonian: return 0.0
	var n := bodies.size()
	var pn := _pn_set(bodies)
	var ok: PackedByteArray = pn[0]
	var phi: PackedFloat64Array = pn[1]
	var e := 0.0
	for i in n:
		if ok[i] == 0: continue
		var a: Body = bodies[i]
		var vi2 := a.vel.length_sq()
		e += 0.375 * a.mass * vi2 * vi2 + 0.5 * a.mass * phi[i] * phi[i]
		for j in n:
			if j == i or ok[j] == 0: continue
			var b: Body = bodies[j]
			var dx := b.pos.x - a.pos.x; var dy := b.pos.y - a.pos.y; var dz := b.pos.z - a.pos.z
			var r := distance_xyz(dx, dy, dz)
			var nva := (dx * a.vel.x + dy * a.vel.y + dz * a.vel.z) / r
			var nvb := (dx * b.vel.x + dy * b.vel.y + dz * b.vel.z) / r
			e += G * a.mass * b.mass / (2.0 * r) * (3.0 * vi2 - 3.5 * a.vel.dot(b.vel) - 0.5 * nva * nvb)
	var value := e / (C * C)
	return value if is_finite(value) else 0.0

## Total momentum the EIH equations conserve (M☉·AU/yr): Σ∂L/∂v of the same Lagrangian,
##   Σ m_a v_a (1 + v_a²/2c² − Φ_a/2c²) − (1/2c²) Σ_{a≠b} (Gm_am_b/r)(n·v_b) n,
## with Φ over the 1PN set; Newtonian Σmv for bodies outside it. Σmv alone oscillates at
## O(v²/c²) under 1PN forces.
static func total_momentum(bodies: Array) -> DVec3:
	var out := DVec3.new()
	var n := bodies.size()
	var pn := _pn_set(bodies) if post_newtonian else [PackedByteArray(), PackedFloat64Array()]
	var ok: PackedByteArray = pn[0]
	var phi: PackedFloat64Array = pn[1]
	var c2 := C * C
	for i in n:
		var a: Body = bodies[i]
		if not a.alive: continue
		if not post_newtonian or ok[i] == 0:
			out.add_scaled_in(a.vel, a.mass)
			continue
		out.add_scaled_in(a.vel, a.mass * (1.0 + (a.vel.length_sq() - phi[i]) / (2.0 * c2)))
		for j in n:
			if j == i or ok[j] == 0: continue
			var b: Body = bodies[j]
			var d := DVec3.new().sub_vectors(b.pos, a.pos)
			var r := d.length()
			d.scale_in(1.0 / r)
			out.add_scaled_in(d, -G * a.mass * b.mass / r * d.dot(b.vel) / (2.0 * c2))
	return out

# Keep ordinary rounding; scale only when the squared norm over/underflows.
static func distance_xyz(x: float, y: float, z: float) -> float:
	var squared := x * x + y * y + z * z
	if is_finite(squared) and squared >= DOUBLE_MIN_NORMAL: return sqrt(squared)
	var scale := maxf(absf(x), maxf(absf(y), absf(z)))
	if scale == 0.0 or not is_finite(scale): return scale
	x /= scale; y /= scale; z /= scale
	return scale * sqrt(x * x + y * y + z * z)

## Plummer softening length (AU): an explicit spec value, else none. Contact merges
## a pair before the separation reaches the bodies' radii, so a default length would
## only distort resolved orbits (a 1e-3 AU length precesses Mercury by −1.6e4″/cy).
static func softening_of(b: Body) -> float:
	return b.softening

## RMS softening preserves each body's scale while giving a symmetric pair potential.
static func pair_softening_sq(a: Body, b: Body) -> float:
	var sa := softening_of(a)
	var sb := softening_of(b)
	return 0.5 * (sa * sa + sb * sb)

## sqrt(dist² + pair_softening_sq) without overflowing or underflowing the squares.
static func softened_distance(dist: float, a: Body, b: Body) -> float:
	var sa := softening_of(a)
	var sb := softening_of(b)
	var scale := maxf(dist, maxf(absf(sa), absf(sb)))
	if not is_finite(scale): return NAN
	return scale * sqrt(pow(dist / scale, 2.0) + 0.5 * (pow(sa / scale, 2.0) + pow(sb / scale, 2.0)))

## Product of positive factors over positive divisors, normalised by exact powers of
## two so no intermediate overflows or underflows. Returns 0 below the subnormal
## range, INF above double range and NAN for a non-finite or non-positive input.
static func scaled_product(factors: Array, divisors: Array = []) -> float:
	var mantissa := 1.0
	var exponent := 0
	for k in factors.size() + divisors.size():
		var divide := k >= factors.size()
		var value: float = divisors[k - factors.size()] if divide else factors[k]
		if not is_finite(value) or value <= 0.0: return NAN
		var shift := clampi(int(floor(log(value) / log(2.0))), -1022, 1023)
		value /= pow(2.0, shift)
		while value < 1.0: value *= 2.0; shift -= 1
		while value >= 2.0: value *= 0.5; shift += 1
		if divide: mantissa /= value; exponent -= shift
		else: mantissa *= value; exponent += shift
	while mantissa < 1.0: mantissa *= 2.0; exponent -= 1
	while mantissa >= 2.0: mantissa *= 0.5; exponent += 1
	if exponent > 1023: return INF
	if exponent < -1075: return 0.0
	return mantissa * pow(2.0, exponent) if exponent >= -1022 else (mantissa * pow(2.0, exponent + 1022)) * DOUBLE_MIN_NORMAL

## Live bodies have positive finite masses and finite positions and velocities
## (x·0 is ±0 for finite x and NaN otherwise, so one sum covers every component).
static func finite_state(bodies: Array) -> bool:
	var zero := 0.0
	for b: Body in bodies:
		if not b.alive: continue
		if not (b.mass > 0.0 and b.mass <= DOUBLE_MAX): return false
		var p := b.pos; var v := b.vel
		zero += p.x * 0.0 + p.y * 0.0 + p.z * 0.0 + v.x * 0.0 + v.y * 0.0 + v.z * 0.0
	return zero == 0.0

static func restore_step(bodies: Array) -> void:
	for b in bodies:
		if b.alive:
			b.pos.copy_from(b.step_pos)
			b.vel.copy_from(b.step_vel)

# Instantaneous quadrupole power converted to illustrative relative-velocity drag,
# not general 2.5-PN dynamics. Boost, window and kick cap alter physical rates.
static var G3 := pow(G, 3.0)
static var G4 := pow(G, 4.0)
static var C5 := pow(C, 5.0)
static func apply_gw_reaction(bodies: Array, dt: float, boost: float) -> void:
	var compact := []
	for b in bodies:
		if b.alive and b.emits_gw: compact.append(b)
	for i in compact.size():
		for j in range(i + 1, compact.size()):
			var a: Body = compact[i]; var b: Body = compact[j]
			var rx := b.pos.x - a.pos.x; var ry := b.pos.y - a.pos.y; var rz := b.pos.z - a.pos.z
			var r := distance_xyz(rx, ry, rz)
			# The illustrative drag window uses physical contact distances.
			var cSum := _or3(a.contact_au, a.radius, a.rs) + _or3(b.contact_au, b.radius, b.rs)
			if r > 400.0 * cSum or r < cSum * 0.5: continue

			var vx := b.vel.x - a.vel.x; var vy := b.vel.y - a.vel.y; var vz := b.vel.z - a.vel.z
			var m1 := a.mass; var m2 := b.mass; var M := m1 + m2; var mu := m1 * m2 / M

			# Peters & Mathews (1963), Keplerian motion: −(8/15) G³m1²m2² (12v² − 11ṙ²)/(c⁵r⁴).
			# 32/5·G⁴m1²m2²M/(c⁵r⁵) on a circle; its orbit average carries Peters' f(e).
			var v2 := vx * vx + vy * vy + vz * vz
			var rdot := (rx * vx + ry * vy + rz * vz) / r
			var dEdt := (8.0 / 15.0) * G3 * m1 * m1 * m2 * m2 * (12.0 * v2 - 11.0 * rdot * rdot) / (C5 * pow(r, 4.0)) * boost

			# Convert power loss into a velocity-space drag opposing relative motion.
			var vrelMag := maxf(sqrt(vx * vx + vy * vy + vz * vz), 1e-6)
			var dragAcc := dEdt / (mu * vrelMag)
			# This numerical cap makes saturated drag timestep-dependent.
			var maxKick := 0.0025 * vrelMag
			if dragAcc * dt > maxKick: dragAcc = maxKick / dt
			var inv_v := 1.0 / vrelMag
			vx *= inv_v; vy *= inv_v; vz *= inv_v            # unit
			# share the kick by reduced mass
			var ka := dragAcc * (mu / m1) * dt
			var kb := dragAcc * (mu / m2) * dt
			a.vel.x += vx * ka; a.vel.y += vy * ka; a.vel.z += vz * ka
			b.vel.x -= vx * kb; b.vel.y -= vy * kb; b.vel.z -= vz * kb

## The first non-zero of three numbers.
static func _or3(a: float, b: float, c: float) -> float:
	if a != 0.0: return a
	if b != 0.0: return b
	return c

# A fixed step is symplectic for unchanged conservative pair potentials.
# Yoshida (1990) fourth-order composition of three time-symmetric leapfrog substeps,
# w₁ = 1/(2 − 2^⅓) and w₀ = 1 − 2w₁ < 0. Against single Verlet at the same step it
# cuts Mercury's perihelion error ~115× and energy error ~100×.
const YOSHIDA_W1 := 1.3512071919596578
const YOSHIDA_W0 := 1.0 - 2.0 * YOSHIDA_W1

static func integrate(bodies: Array, dt: float) -> bool:
	var live := []
	for b in bodies:
		if b.alive: live.append(b)
	if live.is_empty(): return true
	for b: Body in live:
		var sp := b.step_pos; var sv := b.step_vel
		sp.x = b.pos.x; sp.y = b.pos.y; sp.z = b.pos.z
		sv.x = b.vel.x; sv.y = b.vel.y; sv.z = b.vel.z
	for w in [YOSHIDA_W1, YOSHIDA_W0, YOSHIDA_W1]:
		if not _leapfrog_substep(live, w * dt):
			restore_step(live)
			return false
	for b in live:
		# A force-free mover must not spend accepted time with its entire drift lost.
		if (b.acc.x == 0.0 and b.acc.y == 0.0 and b.acc.z == 0.0
				and (b.step_vel.x != 0.0 or b.step_vel.y != 0.0 or b.step_vel.z != 0.0)
				and b.pos.x == b.step_pos.x and b.pos.y == b.step_pos.y and b.pos.z == b.step_pos.z):
			restore_step(live)
			return false
	return true

# Drift–kick–drift. The kick's velocity-dependent 1PN term sees the mean of the old and
# new velocities (one fixed-point pass, residual O(dt·(v/c)⁴)), which keeps the substep
# time-symmetric: a predicted-velocity kick is not, and drifts secularly in energy.
static func _leapfrog_substep(live: Array, dt: float) -> bool:
	var half := 0.5 * dt
	for b in live:
		b.pos.x += b.vel.x * half
		b.pos.y += b.vel.y * half
		b.pos.z += b.vel.z * half
	if not finite_state(live) or not compute_newtonian(live): return false
	if post_newtonian:
		for b in live:
			b.a_prev.copy_from(b.acc)
			b.aux_vel.copy_from(b.vel)
		var pn := _pn_set(live)          # positions are fixed through both passes
		_eih(live, pn)
		for b in live:
			# v_mid = v + ½·dt·a(v), then the Newtonian part back for the second pass.
			b.vel.x = b.aux_vel.x + b.acc.x * half
			b.vel.y = b.aux_vel.y + b.acc.y * half
			b.vel.z = b.aux_vel.z + b.acc.z * half
			b.acc.copy_from(b.a_prev)
		_eih(live, pn)
		for b in live:
			b.vel.copy_from(b.aux_vel)
	for b in live:
		b.vel.x += b.acc.x * dt
		b.vel.y += b.acc.y * dt
		b.vel.z += b.acc.z * dt
		b.pos.x += b.vel.x * half
		b.pos.y += b.vel.y * half
		b.pos.z += b.vel.z * half
	return finite_state(live)

static var collision_limited := false

# Collision / accretion resolution. Returns an array of merger events
# ({survivor, absorbed, separation}).
static func resolve_collisions(bodies: Array) -> Array:
	collision_limited = false
	var events := []
	var n := bodies.size()
	for i in n:
		var a: Body = bodies[i]
		if not a.alive: continue
		for j in range(i + 1, n):
			var b: Body = bodies[j]
			if not b.alive: continue
			var dx := b.pos.x - a.pos.x; var dy := b.pos.y - a.pos.y; var dz := b.pos.z - a.pos.z
			var sq := dx * dx + dy * dy + dz * dz
			var d := sqrt(sq) if sq >= DOUBLE_MIN_NORMAL and sq <= DOUBLE_MAX else distance_xyz(dx, dy, dz)

			# Physical contact only; drawing magnification must not affect mergers.
			var ca := a.rs if a.type == "bh" else (a.contact_au if a.contact_au != 0.0 else a.radius)
			var cb := b.rs if b.type == "bh" else (b.contact_au if b.contact_au != 0.0 else b.radius)
			if not is_finite(d) or not is_finite(ca + cb):
				collision_limited = true
				return events
			if d > ca + cb: continue

			# merge lighter into heavier; conserve momentum
			var big: Body = a if a.mass >= b.mass else b
			var small: Body = b if big == a else a
			var M := big.mass + small.mass
			var inv_mass := 1.0 / M
			big.step_vel.copy_from(big.vel).scale_in(big.mass).add_scaled_in(small.vel, small.mass).scale_in(inv_mass)
			big.step_pos.copy_from(big.pos).scale_in(big.mass).add_scaled_in(small.pos, small.mass).scale_in(inv_mass)
			if not is_finite(M) or M <= 0.0 or not big.step_pos.is_finite_v() or not big.step_vel.is_finite_v():
				collision_limited = true
				return events
			big.vel.copy_from(big.step_vel)
			big.pos.copy_from(big.step_pos)
			big.mass = M
			small.alive = false
			events.append({"survivor": big, "absorbed": small, "separation": d})
			if not a.alive: break
	return events

## Orbital speed for a circular orbit of radius r (AU) about mass M (M☉).
static func circular_speed(M: float, r: float) -> float:
	return sqrt(G * M / r)

## Vis-viva speed for an orbit with given semi-major axis a at radius r.
static func vis_viva(M: float, r: float, a: float) -> float:
	return sqrt(G * M * (2.0 / r - 1.0 / a))
