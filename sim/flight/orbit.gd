class_name Orbit
extends RefCounted

# SI two-body osculating elements, transfer estimates and conic propagation.
# Perturbations are integrated by Vessel; analytic rails have an explicit
# failure path. See sim/flight/AGENTS.md.

# Stumpff functions C(z), S(z). The series near z = 0 matter: the closed forms
# are 0/0 there (the parabolic case).
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

## Advance (r, v) by dt on the conic about `mu`, into r_out/v_out (may alias).
## Returns false if it didn't converge; the caller then integrates.
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
	# A rectilinear conic (h² = μp ≈ 0) runs through the centre: leave it to the integrator.
	if r0 * r0 * v0 * v0 - rdotv * rdotv <= 1e-12 * mu * r0: return false

	# Initial universal anomaly (Vallado): √μ·Δt·α is exact for a circle and right in
	# scale for any number of revolutions; the hyperbolic guess keeps Newton sane near
	# parabolic. F(x) is monotonic (dF/dx = r > 0), so the root is unique.
	var x: float
	if alpha > 1e-12:
		x = sqmu * dt * alpha
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

	# Lagrange f and g: the new state from the old r and v, so the plane is preserved.
	var f := 1.0 - (x * x / r0) * C
	var g := dt - (x * x * x / sqmu) * S
	var gd := 1.0 - (x * x / r_mag) * C
	var fd := (sqmu / (r0 * r_mag)) * x * (z * S - 1.0)

	r_out.set_v(f * _r0.x + g * _v0.x, f * _r0.y + g * _v0.y, f * _r0.z + g * _v0.z)
	v_out.set_v(fd * _r0.x + gd * _v0.x, fd * _r0.y + gd * _v0.y, fd * _r0.z + gd * _v0.z)
	return is_finite(r_out.x) and is_finite(v_out.x)

# classical elements
static var _h := DVec3.new()
static var _n := DVec3.new()
static var _e := DVec3.new()
static var _t := DVec3.new()
# The reference pole is −Y: presets place orbits at (a·cos, 0, a·sin) with velocity
# (−v·sin, 0, v·cos), whose r × v is −Y. So a prograde orbit reads 0°, and normal
# targets and plane changes share the sign.
static var K := DVec3.new(0.0, -1.0, 0.0)

## Classical elements from state, radians and metres, in the XZ plane with pole K.
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

## Time from now until a closed orbit next descends through radius `r_target`, s;
## INF if it never reaches it.
static func time_to_radius_descending(el: Dictionary, mu: float, r_target: float) -> float:
	if not (el.e < 1.0) or el.e < 1e-9: return INF
	var p: float = el.a * (1.0 - el.e * el.e)
	var c: float = (p / r_target - 1.0) / el.e
	if absf(c) > 1.0: return INF
	return time_to_anomaly(el, mu, 2.0 * PI - acos(c))

static func time_to_apoapsis(el: Dictionary, mu: float) -> float:  return time_to_anomaly(el, mu, PI)
static func time_to_periapsis(el: Dictionary, mu: float) -> float: return time_to_anomaly(el, mu, 0.0)

# transfers

## Hohmann transfer between circular orbits r1, r2 about `mu`:
## { dv1, dv2, dv, tof, aT, phase, synodic }.
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
	# The synodic (launch window) period: 780 days for Earth/Mars.
	var synodic := absf(1.0 / (1.0 / T1 - 1.0 / T2))
	return { "dv1": dv1, "dv2": dv2, "dv": absf(dv1) + absf(dv2), "tof": tof, "aT": aT, "phase": phase, "synodic": synodic }

## Δv to circularize at `at_radius` (null: apoapsis).
static func circularize_dv(el: Dictionary, mu: float, at_radius = null) -> float:
	var R: float = el.ra if at_radius == null else at_radius
	if not is_finite(R): return 0.0
	var v_circ := sqrt(mu / R)
	var v_here := sqrt(maxf(mu * (2.0 / R - 1.0 / el.a), 0.0))
	return v_circ - v_here

## Current phase angle from `r` to `r_target`, in radians: about +Y in the XZ plane,
## or, given an orbit `normal` (r × v), in that orbit's plane, positive prograde.
static func phase_angle(r: DVec3, r_target: DVec3, normal: DVec3 = null) -> float:
	if normal != null and normal.length_sq() > 0.0:
		var n := DQuat.nrm(normal.clone())
		var p := r.clone().add_scaled_in(n, -r.dot(n))
		var t := r_target.clone().add_scaled_in(n, -r_target.dot(n))
		return atan2(p.cross(t).dot(n), p.dot(t))
	var a := atan2(r.z, r.x)
	var b := atan2(r_target.z, r_target.x)
	var d := b - a
	while d > PI: d -= 2.0 * PI
	while d < -PI: d += 2.0 * PI
	return d

## Sphere of influence, r_SOI = a·(m/M)^(2/5) (the Laplace radius).
static func sphere_of_influence(a_m: float, mass_body: float, mass_primary: float) -> float:
	if not (mass_primary > 0.0) or not (a_m > 0.0): return INF
	return a_m * pow(mass_body / mass_primary, 0.4)

## Time to the next periapsis on any conic, seconds; INF once a hyperbola is past it.
static func time_to_periapsis_any(el: Dictionary, mu: float) -> float:
	if el.e < 1.0: return time_to_periapsis(el, mu)
	if not is_finite(el.a) or el.a >= 0.0: return INF
	var n := sqrt(mu / pow(-el.a, 3.0))
	var nu: float = el.nu
	if nu > PI: nu -= 2.0 * PI
	var F := 2.0 * atanh(DQuat.jclamp(sqrt((el.e - 1.0) / (el.e + 1.0)) * tan(nu * 0.5), -0.999999, 0.999999))
	var M: float = el.e * sinh(F) - F
	return -M / n if M < 0.0 else INF

## A porkchop: Lambert arcs about `mu` from a departure body on (r_dep, v_dep) to an
## arrival body on (r_arr, v_arr), both given at t = 0 and propagated as conics about
## their own μ sums. Departures at `t_deps`, flight times `tofs` (s); `cost(v∞_dep,
## v∞_arr)` ranks the cells. Arcs within ~2° of 180° have no defined plane and are
## skipped. Returns {best: {t_dep, tof, v_inf_dep, v_inf_arr, v_dep, cost} or {},
## grid: [[cost or INF per tof] per departure]}.
static func porkchop(r_dep: DVec3, v_dep: DVec3, mu_dep: float, r_arr: DVec3, v_arr: DVec3, mu_arr: float,
		mu: float, t_deps: Array, tofs: Array, cost: Callable) -> Dictionary:
	var grid: Array = []
	var best := {}
	var best_cost := INF
	var rd := DVec3.new(); var vd := DVec3.new()
	var ra := DVec3.new(); var va := DVec3.new()
	var a1 := DVec3.new(); var a2 := DVec3.new()
	var nrm := DVec3.new()
	for td in t_deps:
		var row := PackedFloat64Array()
		row.resize(tofs.size())
		row.fill(INF)
		if propagate(r_dep, v_dep, mu_dep, float(td), rd, vd):
			nrm.cross_vectors(rd, vd)
			for j in tofs.size():
				var tof := float(tofs[j])
				if not propagate(r_arr, v_arr, mu_arr, float(td) + tof, ra, va): continue
				if rd.dot(ra) / (rd.length() * ra.length()) < -0.9994: continue
				if not lambert(rd, ra, tof, mu, nrm, a1, a2): continue
				var vi_d := a1.clone().sub_in(vd)
				var vi_a := a2.clone().sub_in(va).length()
				var c: float = cost.call(vi_d.length(), vi_a)
				row[j] = c
				if c < best_cost:
					best_cost = c
					best = {"t_dep": float(td), "tof": tof, "v_inf_dep": vi_d.length(), "v_inf_arr": vi_a,
						"v_dep": vi_d, "cost": c}
		grid.append(row)
	return {"best": best, "grid": grid}

static var _zr := DVec3.new()
static var _za := DVec3.new()

## The lowest and highest radius flown, m, over `span` s from (r, v) about `mu` with the
## zonal terms `zonal` (a Rocketry.ZONAL entry), by RK4 at `h` s. With `to_peak` it
## stops once a rising radius starts to fall: the coming apoapsis. [lo, hi]. Conic elements
## miss J2's short-period terms, several km in low orbit.
static func zonal_extremes(r: DVec3, v: DVec3, mu: float, zonal, span: float, to_peak := false, h := 5.0) -> PackedFloat64Array:
	var s := PackedFloat64Array([r.x, r.y, r.z, v.x, v.y, v.z])
	var k := PackedFloat64Array(); k.resize(24)
	var tmp := PackedFloat64Array(); tmp.resize(6)
	var lo := r.length()
	var hi := lo
	var prev := lo
	var rising := false
	var n := int(ceil(span / h))
	for step in n:
		for stage in 4:
			var f := 0.0 if stage == 0 else (0.5 if stage < 3 else 1.0)
			for i in 6: tmp[i] = s[i] + (k[(stage - 1) * 6 + i] * h * f if stage > 0 else 0.0)
			_zr.set_v(tmp[0], tmp[1], tmp[2])
			var r2 := _zr.length_sq()
			var g := -mu / (r2 * sqrt(r2))
			_za.set_v(tmp[0] * g, tmp[1] * g, tmp[2] * g)
			Rocketry.zonal_accel(zonal, mu, _zr, _za)
			var o := stage * 6
			k[o] = tmp[3]; k[o + 1] = tmp[4]; k[o + 2] = tmp[5]
			k[o + 3] = _za.x; k[o + 4] = _za.y; k[o + 5] = _za.z
		for i in 6: s[i] += h / 6.0 * (k[i] + 2.0 * k[6 + i] + 2.0 * k[12 + i] + k[18 + i])
		var rr := sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
		if to_peak and rising and rr < prev: break
		rising = rising or rr > prev
		prev = rr
		lo = minf(lo, rr); hi = maxf(hi, rr)
	return PackedFloat64Array([lo, hi])

static var _l1 := DVec3.new()

## Lambert's problem, one revolution: the velocities at r1 and r2 of the conic about
## `mu` that joins them in `dt` seconds, turning the way `normal` points (r × v).
## Universal variables (Bate, Mueller & White §5.3), solved by bisection on z, since
## F(z) increases monotonically there. Returns false if no single-revolution conic fits.
static func lambert(r1: DVec3, r2: DVec3, dt: float, mu: float, normal: DVec3, v1_out: DVec3, v2_out: DVec3) -> bool:
	var R1 := r1.length()
	var R2 := r2.length()
	if R1 <= 0.0 or R2 <= 0.0 or dt <= 0.0: return false
	var cos_th := DQuat.jclamp(r1.dot(r2) / (R1 * R2), -1.0, 1.0)
	var th := acos(cos_th)
	if _l1.cross_vectors(r1, r2).dot(normal) < 0.0: th = 2.0 * PI - th
	if absf(1.0 - cos_th) < 1e-12: return false
	var A := sin(th) * sqrt(R1 * R2 / (1.0 - cos_th))
	if absf(A) < 1e-9: return false
	var sq_mu := sqrt(mu)
	var y_of := func(z: float) -> float:
		return R1 + R2 + A * (z * stumpff_s(z) - 1.0) / sqrt(stumpff_c(z))
	var f_of := func(z: float) -> float:
		var y: float = y_of.call(z)
		if y < 0.0: return -INF
		var C := stumpff_c(z)
		return pow(y / C, 1.5) * stumpff_s(z) + A * sqrt(y) - sq_mu * dt
	var lo := -4.0 * PI * PI
	while float(y_of.call(lo)) < 0.0 and lo < 4.0 * PI * PI: lo += 0.25
	var hi := 4.0 * PI * PI - 1e-6
	if float(f_of.call(lo)) > 0.0 or float(f_of.call(hi)) < 0.0: return false
	for i in 90:
		var mid := (lo + hi) * 0.5
		if float(f_of.call(mid)) < 0.0: lo = mid
		else: hi = mid
	var z := (lo + hi) * 0.5
	var y: float = y_of.call(z)
	var f := 1.0 - y / R1
	var g := A * sqrt(y / mu)
	var gd := 1.0 - y / R2
	v1_out.set_v((r2.x - f * r1.x) / g, (r2.y - f * r1.y) / g, (r2.z - f * r1.z) / g)
	v2_out.set_v((gd * r2.x - r1.x) / g, (gd * r2.y - r1.y) / g, (gd * r2.z - r1.z) / g)
	return is_finite(v1_out.x) and is_finite(v2_out.x)
