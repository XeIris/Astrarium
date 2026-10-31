class_name Lagrange
extends RefCounted

# Lagrange points of a primary–secondary pair at their instantaneous separation, and
# halo orbits about L1 and L2 in the circular restricted three-body problem:
# Richardson's (1980) third-order start, made periodic by differential correction.
# docs/physics/missions.md#lagrange-points-and-halo-orbits.

const NAMES := ["L1", "L2", "L3", "L4", "L5"]

## The collinear points' distances, in units of the separation: γ from the secondary
## for L1 (toward the primary) and L2 (beyond it); for L3, from the primary on the far
## side. μ = m₂/(m₁ + m₂). Newton on the quintics (Szebehely 1967).
static func gammas(mu: float) -> Array:
	var out := []
	for k in 3:
		var g := pow(mu / 3.0, 1.0 / 3.0) if k < 2 else 1.0 - 7.0 / 12.0 * mu
		for it in 60:
			var f: float; var df: float
			match k:
				0:   # L1
					f = pow(g, 5.0) - (3.0 - mu) * pow(g, 4.0) + (3.0 - 2.0 * mu) * pow(g, 3.0) - mu * g * g + 2.0 * mu * g - mu
					df = 5.0 * pow(g, 4.0) - 4.0 * (3.0 - mu) * pow(g, 3.0) + 3.0 * (3.0 - 2.0 * mu) * g * g - 2.0 * mu * g + 2.0 * mu
				1:   # L2
					f = pow(g, 5.0) + (3.0 - mu) * pow(g, 4.0) + (3.0 - 2.0 * mu) * pow(g, 3.0) - mu * g * g - 2.0 * mu * g - mu
					df = 5.0 * pow(g, 4.0) + 4.0 * (3.0 - mu) * pow(g, 3.0) + 3.0 * (3.0 - 2.0 * mu) * g * g - 2.0 * mu * g - 2.0 * mu
				_:   # L3, from the primary
					f = pow(g, 5.0) + (2.0 + mu) * pow(g, 4.0) + (1.0 + 2.0 * mu) * pow(g, 3.0) - (1.0 - mu) * g * g - 2.0 * (1.0 - mu) * g - (1.0 - mu)
					df = 5.0 * pow(g, 4.0) + 4.0 * (2.0 + mu) * pow(g, 3.0) + 3.0 * (1.0 + 2.0 * mu) * g * g - 2.0 * (1.0 - mu) * g - 2.0 * (1.0 - mu)
			var step := f / df
			g -= step
			if absf(step) < 1e-15: break
		out.append(g)
	return out

## The rotating frame of `sec` about `pri`, in world AU: {bary, x (pri→sec), y, z (orbit
## normal), sep (AU), omega (rad/yr), vbary (AU/yr)}.
static func frame(pri: Body, sec: Body) -> Dictionary:
	var M := pri.mass + sec.mass
	var r := DVec3.new().sub_vectors(sec.pos, pri.pos)
	var vr := DVec3.new().sub_vectors(sec.vel, pri.vel)
	var sep := r.length()
	var x := r.scaled(1.0 / sep)
	var z := DQuat.nrm(r.cross(vr))
	var bary := pri.pos.scaled(pri.mass / M).add_in(sec.pos.scaled(sec.mass / M))
	var vbary := pri.vel.scaled(pri.mass / M).add_in(sec.vel.scaled(sec.mass / M))
	return {"bary": bary, "x": x, "y": z.cross(x), "z": z, "sep": sep, "omega": r.cross(vr).length() / (sep * sep),
		"vbary": vbary, "mu": sec.mass / M}

## World position (AU) of a point at rotating coordinates (x, y, z) in separations,
## origin at the barycentre.
static func to_world(f: Dictionary, x: float, y: float, z: float) -> DVec3:
	var L: float = f.sep
	return (f.bary as DVec3).clone().add_scaled_in(f.x, x * L).add_scaled_in(f.y, y * L).add_scaled_in(f.z, z * L)

## World velocity (AU/yr) of a point fixed in the rotating frame at (x, y, z).
static func velocity(f: Dictionary, x: float, y: float, z: float) -> DVec3:
	var rel := (f.x as DVec3).scaled(x).add_in((f.y as DVec3).scaled(y)).add_in((f.z as DVec3).scaled(z)).scale_in(f.sep)
	return (f.vbary as DVec3).clone().add_in((f.z as DVec3).scaled(f.omega).cross(rel))

## L1–L5 for `sec` about `pri`, world AU, in NAMES order.
static func points(pri: Body, sec: Body) -> Array:
	var f := frame(pri, sec)
	var mu: float = f.mu
	var g := gammas(mu)
	var xs := 1.0 - mu
	return [
		to_world(f, xs - float(g[0]), 0.0, 0.0),
		to_world(f, xs + float(g[1]), 0.0, 0.0),
		to_world(f, -mu - float(g[2]), 0.0, 0.0),
		to_world(f, 0.5 - mu, sqrt(3.0) / 2.0, 0.0),
		to_world(f, 0.5 - mu, -sqrt(3.0) / 2.0, 0.0),
	]

## The CR3BP's acceleration in the rotating frame (units: separation, 1/n), into a
## 6-vector derivative of state s = [x, y, z, ẋ, ẏ, ż].
static func _deriv(s: PackedFloat64Array, mu: float) -> PackedFloat64Array:
	var x := s[0]; var y := s[1]; var z := s[2]
	var r1 := sqrt(pow(x + mu, 2.0) + y * y + z * z)
	var r2 := sqrt(pow(x - 1.0 + mu, 2.0) + y * y + z * z)
	var a := (1.0 - mu) / pow(r1, 3.0); var b := mu / pow(r2, 3.0)
	return PackedFloat64Array([s[3], s[4], s[5],
		2.0 * s[4] + x - a * (x + mu) - b * (x - 1.0 + mu),
		-2.0 * s[3] + y - a * y - b * y,
		-a * z - b * z])

static func _rk4(s: PackedFloat64Array, h: float, mu: float) -> PackedFloat64Array:
	var k1 := _deriv(s, mu)
	var t := PackedFloat64Array(); t.resize(6)
	for i in 6: t[i] = s[i] + 0.5 * h * k1[i]
	var k2 := _deriv(t, mu)
	for i in 6: t[i] = s[i] + 0.5 * h * k2[i]
	var k3 := _deriv(t, mu)
	for i in 6: t[i] = s[i] + h * k3[i]
	var k4 := _deriv(t, mu)
	var out := PackedFloat64Array(); out.resize(6)
	for i in 6: out[i] = s[i] + h / 6.0 * (k1[i] + 2.0 * k2[i] + 2.0 * k3[i] + k4[i])
	return out

## Integrate from `s` until y changes sign (the half period), with step `h`. Returns
## [state at the crossing, time].
static func _half(s0: PackedFloat64Array, mu: float, h: float) -> Array:
	var s := s0
	var t := 0.0
	for i in 200000:
		var n := _rk4(s, h, mu)
		if i > 10 and signf(n[1]) != signf(s[1]) and n[1] != 0.0:
			# Bisect the step to the crossing.
			var lo := 0.0; var hi := h
			for k in 50:
				var mid := 0.5 * (lo + hi)
				var m := _rk4(s, mid, mu)
				if signf(m[1]) == signf(s[1]): lo = mid
				else: hi = mid
			return [_rk4(s, hi, mu), t + hi]
		s = n
		t += h
	return [s, t]

## A halo orbit about L1 (point 0) or L2 (point 1) of mass ratio μ with out-of-plane
## amplitude `az` (separations), northern family. Richardson's third-order initial
## state, then symmetric differential correction on (z₀, ẏ₀) so the orbit closes
## (ẋ = ż = 0 at the half period). Returns {state: [x,0,z,0,ẏ,0], period, path (rotating,
## separations), residual}, or {} if the correction fails.
static func halo(mu: float, point: int, az: float) -> Dictionary:
	var gam: float = gammas(mu)[point]
	# Richardson (1980): c_n from the Legendre expansion about the point.
	var c := func(n: int) -> float:
		if point == 0: return (mu + pow(-1.0, n) * (1.0 - mu) * pow(gam / (1.0 - gam), n + 1)) / pow(gam, 3.0)
		return (pow(-1.0, n) * mu + pow(-1.0, n) * (1.0 - mu) * pow(gam / (1.0 + gam), n + 1)) / pow(gam, 3.0)
	var c2: float = c.call(2); var c3: float = c.call(3); var c4: float = c.call(4)
	var lam := sqrt((2.0 - c2 + sqrt(9.0 * c2 * c2 - 8.0 * c2)) / 2.0)
	var k := 2.0 * lam / (lam * lam + 1.0 - c2)
	var d1 := 3.0 * lam * lam / k * (k * (6.0 * lam * lam - 1.0) - 2.0 * lam)
	var d2 := 8.0 * lam * lam / k * (k * (11.0 * lam * lam - 1.0) - 2.0 * lam)
	var a21 := 3.0 * c3 * (k * k - 2.0) / (4.0 * (1.0 + 2.0 * c2))
	var a22 := 3.0 * c3 / (4.0 * (1.0 + 2.0 * c2))
	var a23 := -3.0 * c3 * lam / (4.0 * k * d1) * (3.0 * k * k * k * lam - 6.0 * k * (k - lam) + 4.0)
	var a24 := -3.0 * c3 * lam / (4.0 * k * d1) * (2.0 + 3.0 * k * lam)
	var b21 := -3.0 * c3 * lam / (2.0 * d1) * (3.0 * k * lam - 4.0)
	var b22 := 3.0 * c3 * lam / d1
	var d21 := -c3 / (2.0 * lam * lam)
	var a31 := -9.0 * lam / (4.0 * d2) * (4.0 * c3 * (k * a23 - b21) + k * c4 * (4.0 + k * k)) \
		+ (9.0 * lam * lam + 1.0 - c2) / (2.0 * d2) * (3.0 * c3 * (2.0 * a23 - k * b21) + c4 * (2.0 + 3.0 * k * k))
	var a32 := -9.0 * lam / (4.0 * d2) * (4.0 * c3 * (3.0 * k * a24 - b22) + k * c4) \
		- 3.0 * (9.0 * lam * lam + 1.0 - c2) / (2.0 * d2) * (c3 * (k * b22 + d21 - 2.0 * a24) - c4)
	var b31 := 3.0 / (8.0 * d2) * (8.0 * lam * (3.0 * c3 * (k * b21 - 2.0 * a23) - c4 * (2.0 + 3.0 * k * k)) \
		+ (9.0 * lam * lam + 1.0 + 2.0 * c2) * (4.0 * c3 * (k * a23 - b21) + k * c4 * (4.0 + k * k)))
	var b32 := 1.0 / d2 * (9.0 * lam * (c3 * (k * b22 + d21 - 2.0 * a24) - c4) \
		+ 3.0 / 8.0 * (9.0 * lam * lam + 1.0 + 2.0 * c2) * (4.0 * c3 * (k * a24 - b22) + k * c4))
	var d31 := 3.0 / (64.0 * lam * lam) * (4.0 * c3 * a24 + c4)
	var d32 := 3.0 / (64.0 * lam * lam) * (4.0 * c3 * (a23 - d21) + c4 * (4.0 + k * k))
	var s1 := (1.5 * c3 * (2.0 * a21 * (k * k - 2.0) - a23 * (k * k + 2.0) - 2.0 * k * b21) - 3.0 / 8.0 * c4 * (3.0 * pow(k, 4.0) - 8.0 * k * k + 8.0)) \
		/ (2.0 * lam * (lam * (1.0 + k * k) - 2.0 * k))
	var s2 := (1.5 * c3 * (2.0 * a22 * (k * k - 2.0) + a24 * (k * k + 2.0) + 2.0 * k * b22 + 5.0 * d21) + 3.0 / 8.0 * c4 * (12.0 - k * k)) \
		/ (2.0 * lam * (lam * (1.0 + k * k) - 2.0 * k))
	var l1 := -1.5 * c3 * (2.0 * a21 + a23 + 5.0 * d21) - 3.0 / 8.0 * c4 * (12.0 - k * k) + 2.0 * lam * lam * s1
	var l2 := 1.5 * c3 * (a24 - 2.0 * a22) + 9.0 / 8.0 * c4 + 2.0 * lam * lam * s2
	var dd := lam * lam - c2
	var Az := az / gam
	var Ax := sqrt(maxf((-dd - l2 * Az * Az) / l1, 0.0))
	var w := 1.0 + s1 * Ax * Ax + s2 * Az * Az
	# Phase τ₁ = 0 of the northern family (δ_m = 1): x and z at their extremes, y = 0.
	var xr := a21 * Ax * Ax + a22 * Az * Az - Ax + (a23 * Ax * Ax - a24 * Az * Az) + (a31 * pow(Ax, 3.0) - a32 * Ax * Az * Az)
	var zr := Az - 2.0 * d21 * Ax * Az + (d32 * Az * Ax * Ax - d31 * pow(Az, 3.0))
	var ydr := lam * w * (k * Ax + 2.0 * (b21 * Ax * Ax - b22 * Az * Az) + 3.0 * (b31 * pow(Ax, 3.0) - b32 * Ax * Az * Az))
	var x_pt := (1.0 - mu - gam) if point == 0 else (1.0 - mu + gam)
	var T_guess := 2.0 * PI / (lam * w)
	var h := T_guess / 600.0
	# Conventions for the x axis and the sense of circulation differ between sources;
	# take whichever start the correction closes into an orbit of the asked size.
	for sx in [-1.0, 1.0]:
		for sy in [1.0, -1.0]:
			var st0 := PackedFloat64Array([x_pt + sx * gam * xr, 0.0, gam * zr, 0.0, sy * gam * ydr, 0.0])
			var got := _correct(st0, mu, h)
			if got.is_empty(): continue
			var zmax := 0.0
			for q in got.path: zmax = maxf(zmax, absf(q.z))
			if absf(zmax / az - 1.0) < 0.5: return got
	return {}

## Symmetric differential correction: hold x₀, vary (z₀, ẏ₀) until ẋ and ż vanish at
## the half period. {} if it does not converge.
static func _correct(s0: PackedFloat64Array, mu: float, h: float) -> Dictionary:
	var s := s0.duplicate()
	var res := INF
	for it in 25:
		var half := _half(s, mu, h)
		var e: PackedFloat64Array = half[0]
		res = maxf(absf(e[3]), absf(e[5]))
		if res < 1e-10: break
		var J := []
		for j in [2, 4]:
			var p := s.duplicate()
			p[j] += 1e-7
			var hp: PackedFloat64Array = _half(p, mu, h)[0]
			J.append([(hp[3] - e[3]) / 1e-7, (hp[5] - e[5]) / 1e-7])
		var det: float = float(J[0][0]) * float(J[1][1]) - float(J[1][0]) * float(J[0][1])
		if absf(det) < 1e-300 or not is_finite(det): return {}
		s[2] += (-e[3] * float(J[1][1]) + e[5] * float(J[1][0])) / det
		s[4] += (-e[5] * float(J[0][0]) + e[3] * float(J[0][1])) / det
		if not is_finite(s[2]) or absf(s[2]) > 1.0: return {}
	if res > 1e-8: return {}
	var period: float = 2.0 * float(_half(s, mu, h)[1])
	var path := PackedVector3Array()
	var st := s
	var n := 240
	var hh := period / n
	for i in n + 1:
		path.append(Vector3(st[0], st[1], st[2]))
		for sub in 8: st = _rk4(st, hh / 8.0, mu)
	return {"state": s, "period": period, "path": path, "residual": res}
