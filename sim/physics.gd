class_name Physics
extends RefCounted

# AU, M☉, years; DVec3 doubles. Newtonian pair gravity with velocity-Verlet;
# optional circular-power drag illustrates GW losses. See docs/physics/compact-dynamics.md.

const G := 4.0 * PI * PI                # 39.478 AU³ M☉⁻¹ yr⁻²
const C := 63241.077                    # speed of light, AU/yr
const AU_PER_RSUN := 0.00465047         # solar radius in AU
const AU_PER_KM := 6.68459e-9

## Schwarzschild radius (AU) for a given mass in M☉.
static func schwarzschild(mass_sun: float) -> float:
	return 2.0 * G * mass_sun / (C * C)

## Neutron-star radius (AU): shrinks with mass, ~12 km near 1.4 M☉, floored at ~10 km,
## capped near TOV (~2.2 M☉).
static func neutron_radius(mass_sun: float) -> float:
	var m := minf(maxf(mass_sun, 1.1), 2.2)
	var km := 13.0 - 2.6 * (m - 1.1)   # 13 km at 1.1 M☉ → ~10.1 km at 2.2 M☉
	return maxf(km, 9.5) * AU_PER_KM

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

# Acceleration field. Fills every live body's `acc`.
static func compute_accel(bodies: Array) -> void:
	for b in bodies:
		b.acc.x = 0.0; b.acc.y = 0.0; b.acc.z = 0.0
	var n := bodies.size()
	for i in n:
		var a: Body = bodies[i]
		if not a.alive: continue
		var ap := a.pos
		for j in range(i + 1, n):
			var b: Body = bodies[j]
			if not b.alive: continue
			var rx := b.pos.x - ap.x
			var ry := b.pos.y - ap.y
			var rz := b.pos.z - ap.z
			var dist := sqrt(rx * rx + ry * ry + rz * rz)
			if dist < 1e-9: continue
			var inv := 1.0 / dist
			rx *= inv; ry *= inv; rz *= inv           # unit vector a→b
			var kernel: float
			if a.type == "bh" or b.type == "bh":
				# Weak-field point masses; horizons set contact, not a binary force law.
				kernel = G / (dist * dist)
			else:
				var d2 := dist * dist + pair_softening_sq(a, b)
				kernel = G * dist / (d2 * sqrt(d2))
			var fA := kernel * b.mass
			var fB := kernel * a.mass
			a.acc.x += rx * fA; a.acc.y += ry * fA; a.acc.z += rz * fA
			b.acc.x -= rx * fB; b.acc.y -= ry * fB; b.acc.z -= rz * fB

## RMS softening preserves each body's scale while giving a symmetric pair potential.
static func pair_softening_sq(a: Body, b: Body) -> float:
	var sa := a.softening if a.softening != 0.0 else a.radius * 0.5 + 1e-4
	var sb := b.softening if b.softening != 0.0 else b.radius * 0.5 + 1e-4
	return 0.5 * (sa * sa + sb * sb)

# Circular weak-field quadrupole power converted to illustrative relative-velocity
# drag, not general 2.5-PN dynamics. Boost, window and kick cap alter physical rates.
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
			var r := sqrt(rx * rx + ry * ry + rz * rz)
			# The illustrative drag window uses physical contact distances.
			var cSum := _or3(a.contact_au, a.radius, a.rs) + _or3(b.contact_au, b.radius, b.rs)
			if r > 400.0 * cSum or r < cSum * 0.5: continue

			var vx := b.vel.x - a.vel.x; var vy := b.vel.y - a.vel.y; var vz := b.vel.z - a.vel.z
			var m1 := a.mass; var m2 := b.mass; var M := m1 + m2; var mu := m1 * m2 / M

			# dE/dt for a circular binary: −32/5 · G⁴ m1²m2²(m1+m2) / (c⁵ r⁵)
			var dEdt := (32.0 / 5.0) * G4 * m1 * m1 * m2 * m2 * M / (C5 * pow(r, 5.0)) * boost

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
static func integrate(bodies: Array, dt: float) -> void:
	var live := []
	for b in bodies:
		if b.alive: live.append(b)
	if live.is_empty(): return

	compute_accel(live)
	var hdt2 := 0.5 * dt * dt
	for b in live:
		# x += v·dt + ½a·dt² as two additions, the reference's rounding order.
		b.pos.x += b.vel.x * dt
		b.pos.y += b.vel.y * dt
		b.pos.z += b.vel.z * dt
		b.pos.x += b.acc.x * hdt2
		b.pos.y += b.acc.y * hdt2
		b.pos.z += b.acc.z * hdt2
		b.a_prev.x = b.acc.x; b.a_prev.y = b.acc.y; b.a_prev.z = b.acc.z
	compute_accel(live)
	var hdt := 0.5 * dt
	for b in live:
		# v += ½(a_old + a_new)·dt
		b.vel.x += (b.a_prev.x + b.acc.x) * hdt
		b.vel.y += (b.a_prev.y + b.acc.y) * hdt
		b.vel.z += (b.a_prev.z + b.acc.z) * hdt

# Collision / accretion resolution. Returns an array of merger events
# ({survivor, absorbed, separation}).
static func resolve_collisions(bodies: Array) -> Array:
	var events := []
	var n := bodies.size()
	for i in n:
		var a: Body = bodies[i]
		if not a.alive: continue
		for j in range(i + 1, n):
			var b: Body = bodies[j]
			if not b.alive: continue
			var d := a.pos.distance_to(b.pos)

			# Physical contact only; drawing magnification must not affect mergers.
			var ca := a.rs if a.type == "bh" else (a.contact_au if a.contact_au != 0.0 else a.radius)
			var cb := b.rs if b.type == "bh" else (b.contact_au if b.contact_au != 0.0 else b.radius)
			if d > ca + cb: continue

			# merge lighter into heavier; conserve momentum
			var big: Body = a if a.mass >= b.mass else b
			var small: Body = b if big == a else a
			var M := big.mass + small.mass
			big.vel.scale_in(big.mass).add_scaled_in(small.vel, small.mass).scale_in(1.0 / M)
			big.pos.scale_in(big.mass).add_scaled_in(small.pos, small.mass).scale_in(1.0 / M)
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
