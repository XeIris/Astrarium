class_name Orbit
extends RefCounted

# ============================================================================
# TWO-BODY ORBITAL MECHANICS
# ----------------------------------------------------------------------------
# Everything here is about ONE body's gravity, in SI, in a frame centred on it.
# The sim's real force model is the full n-body sum (see vessel.gd); this module
# exists for the two jobs that genuinely want the two-body answer:
#
#   1. THE INSTRUMENTS. "Apoapsis 412 km" is a statement about the conic the
#      vessel is on right now, and the conic is what the crew steers by. It is
#      recomputed every frame from the live state, so perturbations show up as
#      the numbers drifting, which is exactly what they do in reality.
#
#   2. ON-RAILS TIME WARP. Above ~1000x the integrator cannot keep up with an
#      orbit — a 90-minute LEO orbit passes in 5 ms of wall clock — so an
#      unpowered vessel outside the atmosphere is taken off the integrator and
#      advanced along its conic analytically. That is exactly what KSP does and
#      for the same reason. The propagation is EXACT for the two-body problem,
#      so it neither drifts nor cares about the step size; what it drops is the
#      perturbations, which is an honest and clearly-bounded trade.
#
# The propagator is the universal-variable (Stumpff) formulation rather than a
# per-conic one. That is not an aesthetic choice: a vessel on an escape
# trajectory passes through e = 1, and a formulation with separate elliptic and
# hyperbolic branches divides by zero exactly there. The universal form has no
# branch — it is one series that covers ellipse, parabola and hyperbola.
#
# PORT NOTES. Vectors are DVec3 (metres, m/s — never float32). `elements()`
# returns a Dictionary with the JS keys (a, e, inc, raan, argp, nu, rp, ra, h,
# energy, period, r, v); INF where the JS had Infinity.
# ============================================================================

# ---- Stumpff functions ------------------------------------------------------
# C(z) and S(z) are the even and odd parts of the universal anomaly series. The
# series expansions near z = 0 are not an optimisation: the closed forms are
# 0/0 there, which is precisely the parabolic case.
static func stumpff_c(z: float) -> float:
	if z > 1e-6:
		var s := sqrt(z)
		return (1.0 - cos(s)) / z
	if z < -1e-6:
		var s := sqrt(-z)
		return (cosh(s) - 1.0) / -z
	return 0.5 - z / 24.0 + z * z / 720.0

static func stumpff_s(z: float) -> float:
	if z > 1e-6:
		var s := sqrt(z)
		return (s - sin(s)) / (z * s)
	if z < -1e-6:
		var s := sqrt(-z)
		return (sinh(s) - s) / (-z * s)
	return 1.0 / 6.0 - z / 120.0 + z * z / 5040.0

static var _r0 := DVec3.new()
static var _v0 := DVec3.new()

## Advance (r, v) by dt seconds on the two-body conic about `mu`.
## Writes into r_out/v_out (which may alias r/v). Returns false if it failed to
## converge, in which case the caller must fall back to integrating.
static func propagate(r: DVec3, v: DVec3, mu: float, dt: float, r_out: DVec3, v_out: DVec3) -> bool:
	if dt == 0.0:
		r_out.copy_from(r); v_out.copy_from(v)
		return true
	_r0.copy_from(r); _v0.copy_from(v)
	var r0 := _r0.length()
	var v0 := _v0.length()
	if r0 < 1e-6 or not is_finite(r0): return false
	var sqmu := sqrt(mu)
	var rdotv := _r0.dot(_v0)
	var alpha := 2.0 / r0 - v0 * v0 / mu               # = 1/a; negative ⇒ hyperbolic

	# Initial guess for the universal anomaly. The elliptic guess is exact for a
	# circle; the hyperbolic one is Vallado's, and matters because a bad guess on
	# a near-parabolic orbit sends Newton off to infinity.
	var x: float
	if alpha > 1e-12:
		x = sqmu * dt * alpha
		# Guard the near-2π case, where the elliptic guess overshoots a whole rev.
		if absf(alpha * sqmu * dt) > 2.0 * PI:
			x = signf(dt) * sqrt(1.0 / alpha) * 2.0 * PI
	elif alpha < -1e-12:
		var a := 1.0 / alpha
		var s := signf(dt) * sqrt(-a)
		var num := -2.0 * mu * alpha * dt
		var den := rdotv + s * sqrt(-mu * a) * (1.0 - r0 * alpha)
		x = s * log(maxf(num / den, 1e-12))
	else:
		x = sqmu * dt / r0                               # parabolic

	var z := 0.0
	var C := 0.5
	var S := 1.0 / 6.0
	var r_mag := r0
	var ok := false
	for i in 60:
		z = alpha * x * x
		C = stumpff_c(z); S = stumpff_s(z)
		r_mag = x * x * C + (rdotv / sqmu) * x * (1.0 - z * S) + r0 * (1.0 - z * C)
		var F := (rdotv / sqmu) * x * x * C + (1.0 - alpha * r0) * x * x * x * S + r0 * x - sqmu * dt
		if absf(F) < 1e-7 * maxf(1.0, absf(sqmu * dt)):
			ok = true
			break
		if r_mag < 1e-9: return false
		x -= F / r_mag                                   # dF/dx = rMag exactly
		if not is_finite(x): return false
	if not ok: return false

	# Lagrange f and g. These reconstruct the new state as a linear combination of
	# the OLD position and velocity, which is why the propagation is exact rather
	# than integrated: the orbit plane is preserved to machine precision.
	var f := 1.0 - (x * x / r0) * C
	var g := dt - (x * x * x / sqmu) * S
	var gd := 1.0 - (x * x / r_mag) * C
	var fd := (sqmu / (r0 * r_mag)) * x * (z * S - 1.0)

	r_out.set_v(f * _r0.x + g * _v0.x, f * _r0.y + g * _v0.y, f * _r0.z + g * _v0.z)
	v_out.set_v(fd * _r0.x + gd * _v0.x, fd * _r0.y + gd * _v0.y, fd * _r0.z + gd * _v0.z)
	return is_finite(r_out.x) and is_finite(v_out.x)

# ---- classical elements -----------------------------------------------------
static var _h := DVec3.new()
static var _n := DVec3.new()
static var _e := DVec3.new()
static var _t := DVec3.new()
# The reference pole. It is −Y, not +Y, and that is measured rather than
# chosen: sim/presets.js places every standard orbit at (a·cos, 0, a·sin) with
# velocity (−v·sin, 0, v·cos), whose angular momentum r × v points along −Y. So
# the orrery's own "orbital north" is −Y, and defining it that way here is what
# makes a normal prograde orbit read as inclination 0° in the HUD instead of
# 180°. Everything else — the normal/anti-normal attitude targets, the plane
# change planner — inherits the same sign for free.
static var K := DVec3.new(0.0, -1.0, 0.0)

## Classical elements from state. Angles in radians, lengths in metres.
## The reference plane is the sim's XZ plane and the pole is K = −Y, matching
## the orrery — so an inclination reported here is measured against the same
## plane the presets lay their orbits in, and a prograde orbit reads 0° rather
## than 180°. See the derivation on K above; the sign is the whole of it.
static func elements(r: DVec3, v: DVec3, mu: float) -> Dictionary:
	var R := r.length()
	var V := v.length()
	_h.cross_vectors(r, v)
	var h := _h.length()
	var energy := V * V / 2.0 - mu / R
	# a from the vis-viva energy. Infinite exactly at escape, which is correct and
	# is why the periapsis/apoapsis readouts have to handle a non-finite `a`.
	var a := INF if absf(energy) < 1e-12 else -mu / (2.0 * energy)
	_e.copy_from(v).cross_vectors(_e, _h).scale_in(1.0 / mu).sub_in(_t.copy_from(r).scale_in(1.0 / R))
	var e := _e.length()
	var inc := acos(DQuat.jclamp(_h.dot(K) / maxf(h, 1e-12), -1.0, 1.0))
	_n.cross_vectors(K, _h)
	var n_mag := _n.length()
	var raan := atan2(_n.z, _n.x) if n_mag > 1e-9 else 0.0
	var argp := 0.0
	if n_mag > 1e-9 and e > 1e-9:
		argp = acos(DQuat.jclamp(_n.dot(_e) / (n_mag * e), -1.0, 1.0))
		if _e.dot(K) < 0.0: argp = 2.0 * PI - argp
	var nu := 0.0
	if e > 1e-9:
		nu = acos(DQuat.jclamp(_e.dot(r) / (e * R), -1.0, 1.0))
		if r.dot(v) < 0.0: nu = 2.0 * PI - nu
	else:
		nu = atan2(r.dot(_t.cross_vectors(_h, _e.set_v(1.0, 0.0, 0.0))), r.x)
	var rp := a * (1.0 - e) if e < 1.0 else (h * h / mu) / (1.0 + e)
	var ra := a * (1.0 + e) if e < 1.0 else INF
	var period := 2.0 * PI * sqrt(a * a * a / mu) if (e < 1.0 and is_finite(a)) else INF
	return { "a": a, "e": e, "inc": inc, "raan": raan, "argp": argp, "nu": nu, "rp": rp, "ra": ra,
			 "h": h, "energy": energy, "period": period, "r": R, "v": V }

## Time from now to the next periapsis/apoapsis passage, seconds. Only defined
## on a closed orbit; on a hyperbola apoapsis never arrives.
static func time_to_anomaly(el: Dictionary, _mu: float, target_nu: float) -> float:
	if not (el.e < 1.0) or not is_finite(el.period): return INF
	var d_m: float = _mean_anomaly(el.e, target_nu) - _mean_anomaly(el.e, el.nu)
	while d_m < 0.0: d_m += 2.0 * PI
	return d_m / (2.0 * PI) * el.period

static func _mean_anomaly(e: float, nu: float) -> float:
	var ecc := 2.0 * atan2(sqrt(1.0 - e) * sin(nu / 2.0), sqrt(1.0 + e) * cos(nu / 2.0))
	return ecc - e * sin(ecc)

static func time_to_apoapsis(el: Dictionary, mu: float) -> float:  return time_to_anomaly(el, mu, PI)
static func time_to_periapsis(el: Dictionary, mu: float) -> float: return time_to_anomaly(el, mu, 0.0)

# ---- transfers --------------------------------------------------------------

## Hohmann transfer between two circular orbits of radii r1, r2 about `mu`.
## The minimum-energy two-impulse transfer, and the number every mission plan
## starts from. Returns { dv1, dv2, dv, tof, aT, phase, synodic }.
static func hohmann(mu: float, r1: float, r2: float) -> Dictionary:
	var aT := (r1 + r2) / 2.0
	var v1 := sqrt(mu / r1)
	var v2 := sqrt(mu / r2)
	var dv1 := v1 * (sqrt(2.0 * r2 / (r1 + r2)) - 1.0)
	var dv2 := v2 * (1.0 - sqrt(2.0 * r1 / (r1 + r2)))
	var tof := PI * sqrt(aT * aT * aT / mu)
	# Phase angle the TARGET must lead the vessel by at departure: the target
	# travels ω₂·tof while the vessel sweeps exactly π.
	var T2 := 2.0 * PI * sqrt(r2 * r2 * r2 / mu)
	var phase := PI - 2.0 * PI * tof / T2
	var T1 := 2.0 * PI * sqrt(r1 * r1 * r1 / mu)
	# How long until the same geometry comes round again — i.e. the launch window
	# period. 780 days for Earth/Mars, which is why Mars missions come in pairs
	# of years and not whenever anyone feels like it.
	var synodic := absf(1.0 / (1.0 / T1 - 1.0 / T2))
	return { "dv1": dv1, "dv2": dv2, "dv": absf(dv1) + absf(dv2), "tof": tof, "aT": aT, "phase": phase, "synodic": synodic }

## Δv to circularize at the current radius — the standard "raise the periapsis
## to match" burn, evaluated where the vessel is right now. `at_radius` null
## means "at apoapsis" (JS: atRadius ?? el.ra).
static func circularize_dv(el: Dictionary, mu: float, at_radius = null) -> float:
	var R: float = el.ra if at_radius == null else at_radius
	if not is_finite(R): return 0.0
	var v_circ := sqrt(mu / R)
	var v_here := sqrt(maxf(mu * (2.0 / R - 1.0 / el.a), 0.0))
	return v_circ - v_here

## Current phase angle from `r` to `r_target`, signed about +Y, in radians.
static func phase_angle(r: DVec3, r_target: DVec3) -> float:
	var a := atan2(r.z, r.x)
	var b := atan2(r_target.z, r_target.x)
	var d := b - a
	while d > PI: d -= 2.0 * PI
	while d < -PI: d += 2.0 * PI
	return d

## Sphere of influence (m): the radius at which `body`'s pull dominates its
## primary's. r_SOI = a·(m/M)^(2/5) — the Laplace radius, which is what the
## patched-conic approximation patches at.
static func sphere_of_influence(a_m: float, mass_body: float, mass_primary: float) -> float:
	if not (mass_primary > 0.0) or not (a_m > 0.0): return INF
	return a_m * pow(mass_body / mass_primary, 0.4)
