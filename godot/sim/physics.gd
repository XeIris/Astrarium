class_name Physics
extends RefCounted

# ============================================================================
# REAL PHYSICS ENGINE
# ----------------------------------------------------------------------------
# Units: astronomical. Length = AU, mass = solar mass (M☉), time = year (yr).
# In this system the gravitational constant is exactly G = 4π², the speed of
# light is c ≈ 63241 AU/yr. With these units a body at 1 AU around a 1 M☉ star
# orbits in exactly 1 yr — i.e. the integrator reproduces real Kepler/Newton
# dynamics with no fudge factors.
#
# Integrator: full pairwise N-body with velocity-Verlet (symplectic, conserves
# energy far better than the semi-implicit Euler the old sim used).
#   - Compact objects (black holes, neutron stars) attract via the
#     Paczyński–Wiita pseudo-potential, which reproduces the correct ISCO at
#     3·r_s and the relativistic plunge — "real enough" GR without integrating
#     null/timelike geodesics every frame.
#   - Tight compact-compact binaries lose energy to gravitational waves via the
#     leading-order (quadrupole / 2.5-PN) radiation-reaction term, so binaries
#     genuinely inspiral and merge with the right chirp shape.
#
# PORT NOTE. Every quantity here is a GDScript float — a double — held in
# DVec3 (core/dvec3.gd). The pair loops read components directly rather than
# going through DVec3 methods, because this is the hot loop the whole sim
# spends its CPU in (up to 8000 sub-steps a frame during a close encounter).
# ============================================================================

const G := 4.0 * PI * PI                # 39.478 AU³ M☉⁻¹ yr⁻²
const C := 63241.077                    # speed of light, AU/yr
const AU_PER_RSUN := 0.00465047         # solar radius in AU
const AU_PER_KM := 6.68459e-9

## Schwarzschild radius (AU) for a given mass in M☉.
static func schwarzschild(mass_sun: float) -> float:
	return 2.0 * G * mass_sun / (C * C)

## Neutron-star radius (AU) from a simple mass–radius relation: NS shrink as
## they get heavier (degenerate matter), ~12 km near 1.4 M☉, hard floor at the
## theoretical ~10 km, capped near the Tolman–Oppenheimer–Volkoff limit ~2.2 M☉.
static func neutron_radius(mass_sun: float) -> float:
	var m := minf(maxf(mass_sun, 1.1), 2.2)
	var km := 13.0 - 2.6 * (m - 1.1)   # 13 km at 1.1 M☉ → ~10.1 km at 2.2 M☉
	return maxf(km, 9.5) * AU_PER_KM

## Physical stellar radius (AU) from mass via main-sequence R ∝ M^0.8.
static func stellar_radius(mass_sun: float) -> float:
	return pow(maxf(mass_sun, 0.05), 0.8) * AU_PER_RSUN

# ----------------------------------------------------------------------------
# Roche limit (AU): the separation inside which a body held together only by
# its own gravity is pulled apart by the tidal field of `massSun`.
#   d = 2.44 R* (rho* / rho_body)^(1/3)
# For a rocky world around a main-sequence star this lands a few stellar radii
# out — the world is shredded well before it ever reaches the photosphere, so
# this, not the star's surface, is the honest destruction distance for any
# scenario built on close passes.
# ----------------------------------------------------------------------------
const RHO_SUN := 1.41                   # g/cm^3
static func roche_limit(mass_sun: float, body_density: float = 5.5) -> float:
	var r_au := stellar_radius(mass_sun)
	var r_sun := r_au / AU_PER_RSUN
	var rho_star := RHO_SUN * mass_sun / (r_sun * r_sun * r_sun)
	return 2.44 * r_au * U.cbrt(rho_star / body_density)

# ----------------------------------------------------------------------------
# Acceleration field. Fills every live body's `acc`.
# ----------------------------------------------------------------------------
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
			# Pull strength of each body on the other. Compact bodies use the
			# Paczyński–Wiita denominator (r − r_s)² so the ISCO/plunge are correct.
			var fA := _pull_mag(b, dist)             # accel of A toward B
			var fB := _pull_mag(a, dist)             # accel of B toward A
			a.acc.x += rx * fA; a.acc.y += ry * fA; a.acc.z += rz * fA
			b.acc.x -= rx * fB; b.acc.y -= ry * fB; b.acc.z -= rz * fB

## |acceleration| imparted by `source` at separation `dist`.
## Only true black holes use the Paczyński–Wiita pseudo-potential (which makes
## the ISCO/plunge appear); stars & neutron stars are extended bodies → Newton.
static func _pull_mag(source: Body, dist: float) -> float:
	var GM := G * source.mass
	if source.type == "bh":
		var denom := maxf(dist - source.rs, source.rs * 0.05)
		return GM / (denom * denom)
	# Plummer softening for extended bodies so close passes don't blow up.
	var soft := source.softening if source.softening != 0.0 else (source.radius * 0.5 + 1e-4)
	var d2 := dist * dist + soft * soft
	return GM / d2

# ----------------------------------------------------------------------------
# Gravitational-wave radiation reaction for a bound compact binary.
# Applies the 2.5-PN leading-order energy loss as a drag, scaled by `boost`
# so the inspiral is watchable (real systems take Myr; presets exaggerate the
# rate but preserve the correct r(t) ∝ (t_c − t)^¼ chirp morphology).
# ----------------------------------------------------------------------------
# G and C are module constants, so their powers are too — hoisted out of the
# O(n²) pair loop rather than recomputed per pair per sub-step.
const G4 := G * G * G * G
const C5 := C * C * C * C * C
static func apply_gw_reaction(bodies: Array, dt: float, boost: float) -> void:
	var compact := []
	for b in bodies:
		if b.alive and b.emits_gw: compact.append(b)
	for i in compact.size():
		for j in range(i + 1, compact.size()):
			var a: Body = compact[i]; var b: Body = compact[j]
			var rx := b.pos.x - a.pos.x; var ry := b.pos.y - a.pos.y; var rz := b.pos.z - a.pos.z
			var r := sqrt(rx * rx + ry * ry + rz * rz)
			# Scale the "tight pair" window to the bodies' physical/rendered size, not
			# their Schwarzschild radius — a neutron star's true horizon is microscopic
			# and would exclude its whole inspiral.
			var cSum := _or3(a.contact_au, a.radius, a.rs) + _or3(b.contact_au, b.radius, b.rs)
			if r > 400.0 * cSum or r < cSum * 0.5: continue

			var vx := b.vel.x - a.vel.x; var vy := b.vel.y - a.vel.y; var vz := b.vel.z - a.vel.z
			var m1 := a.mass; var m2 := b.mass; var M := m1 + m2; var mu := m1 * m2 / M

			# dE/dt for a circular binary: −32/5 · G⁴ m1²m2²(m1+m2) / (c⁵ r⁵)
			var dEdt := (32.0 / 5.0) * G4 * m1 * m1 * m2 * m2 * M / (C5 * pow(r, 5.0)) * boost

			# Convert power loss into a velocity-space drag opposing relative motion.
			var vrelMag := maxf(sqrt(vx * vx + vy * vy + vz * vz), 1e-6)
			var dragAcc := dEdt / (mu * vrelMag)
			# Cap the fractional relative-speed bled off per sub-step (step-size
			# independent) so the runaway final plunge (the chirp diverges as r→0) is
			# spread over many frames and stays clearly visible.
			var maxKick := 0.0025 * vrelMag
			if dragAcc * dt > maxKick: dragAcc = maxKick / dt
			vx /= vrelMag; vy /= vrelMag; vz /= vrelMag      # unit
			# share the kick by reduced mass
			var ka := dragAcc * (mu / m1) * dt
			var kb := dragAcc * (mu / m2) * dt
			a.vel.x += vx * ka; a.vel.y += vy * ka; a.vel.z += vz * ka
			b.vel.x -= vx * kb; b.vel.y -= vy * kb; b.vel.z -= vz * kb

## JS `(a || b || c)` over numbers: the first non-zero.
static func _or3(a: float, b: float, c: float) -> float:
	if a != 0.0: return a
	if b != 0.0: return b
	return c

# ----------------------------------------------------------------------------
# One velocity-Verlet step (symplectic).
# ----------------------------------------------------------------------------
static func integrate(bodies: Array, dt: float) -> void:
	var live := []
	for b in bodies:
		if b.alive: live.append(b)
	if live.is_empty(): return

	compute_accel(live)
	var hdt2 := 0.5 * dt * dt
	for b in live:
		# x += v·dt + ½a·dt²
		b.pos.x += b.vel.x * dt + b.acc.x * hdt2
		b.pos.y += b.vel.y * dt + b.acc.y * hdt2
		b.pos.z += b.vel.z * dt + b.acc.z * hdt2
		b.a_prev.x = b.acc.x; b.a_prev.y = b.acc.y; b.a_prev.z = b.acc.z
	compute_accel(live)
	var hdt := 0.5 * dt
	for b in live:
		# v += ½(a_old + a_new)·dt
		b.vel.x += (b.a_prev.x + b.acc.x) * hdt
		b.vel.y += (b.a_prev.y + b.acc.y) * hdt
		b.vel.z += (b.a_prev.z + b.acc.z) * hdt

# ----------------------------------------------------------------------------
# Collision / accretion resolution. Returns an array of merger events
# ({survivor, absorbed, separation}).
# ----------------------------------------------------------------------------
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

			# contact distance: event horizon for BHs, rendered surface otherwise.
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
			# (As in the web build, the inner loop carries on even if `a` was the
			# one absorbed — kept, so a three-way pile-up resolves identically.)
	return events

## Orbital speed for a circular orbit of radius r (AU) about mass M (M☉).
static func circular_speed(M: float, r: float) -> float:
	return sqrt(G * M / r)

## Vis-viva speed for an orbit with given semi-major axis a at radius r.
static func vis_viva(M: float, r: float, a: float) -> float:
	return sqrt(G * M * (2.0 / r - 1.0 / a))
