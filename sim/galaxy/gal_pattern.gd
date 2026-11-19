class_name GalPattern
extends RefCounted

# Rotating, non-axisymmetric parts of a galaxy's gravity: a bar and a spiral, each a
# pattern turning rigidly at its own speed and grown in smoothly. Scene axes as
# GalPotential (Y up, azimuth φ = atan2(z, x) growing with the rotation for
# sense = +1). These functions are the reference; the tracer kernels inline the same
# arithmetic (GalTracers, native/astrarium_native.c). docs/physics/galaxies.md.
#
# Bar: Dehnen (2000) in the 3D form of Monari et al. (2016), as galpy has it:
#   Φ = A(t) cos 2(φ − φb(t)) (R/r)² g(r),  g = −(Rb/r)³ beyond Rb, (r/Rb)³ − 2 inside.
# Spiral: Cox & Gómez (2002), one term:
#   Φ = −A(t) e^{−(R−r0)/Rs} cos γ sech^B(Ky/B) / (K D),  γ = N (φ − φp(t) + ln(R/r0)/tan α),
#   K = N/(R sin α), B = KH(1 + 0.4KH), D = (1 + KH + 0.3(KH)²)/(1 + 0.3KH),
# whose crests (γ = 0) trail the rotation. Both grow by Dehnen's quintic over
# [tForm, tForm + tGrow] and turn at Ω: φb(t) = φb0 + Ω t.

enum Kind { BAR, SPIRAL }

static func bar(omega: float, angle0: float, rb: float, af: float, t_form: float, t_grow: float) -> Dictionary:
	return {"kind": Kind.BAR, "omega": omega, "angle0": angle0, "rb": rb, "amp": af, "tForm": t_form, "tGrow": t_grow}

## `amp` is 4πG H ρ0 (kpc² Myr⁻²) with ρ0 the arm density amplitude at r0.
static func spiral(omega: float, angle0: float, n: int, pitch: float, r0: float, rs: float, h: float, amp: float,
		t_form: float, t_grow: float) -> Dictionary:
	return {"kind": Kind.SPIRAL, "omega": omega, "angle0": angle0, "n": float(n), "pitch": pitch, "r0": r0,
		"rs": rs, "h": h, "amp": amp, "tForm": t_form, "tGrow": t_grow}

## Dehnen's (2000) growth factor, 0 before tForm and 1 after tForm + tGrow.
static func growth(p: Dictionary, t: float) -> float:
	var t0: float = p.tForm
	var tg: float = p.tGrow
	if t <= t0: return 0.0
	if t >= t0 + tg: return 1.0
	var xi := 2.0 * (t - t0) / tg - 1.0
	return 3.0 / 16.0 * pow(xi, 5.0) - 5.0 / 8.0 * pow(xi, 3.0) + 15.0 / 16.0 * xi + 0.5

static func growth_rate(p: Dictionary, t: float) -> float:
	var t0: float = p.tForm
	var tg: float = p.tGrow
	if t <= t0 or t >= t0 + tg: return 0.0
	var xi := 2.0 * (t - t0) / tg - 1.0
	return (15.0 / 16.0 * pow(xi, 4.0) - 15.0 / 8.0 * xi * xi + 15.0 / 16.0) * 2.0 / tg

## The pattern's angle at t.
static func angle(p: Dictionary, t: float) -> float:
	return float(p.angle0) + float(p.omega) * t

## Φ at full strength and its derivative in azimuth (for ∂Φ/∂t = −Ω ∂Φ/∂φ), in double.
static func _full(p: Dictionary, x: float, y: float, z: float, t: float) -> PackedFloat64Array:
	var R2 := x * x + z * z
	var R := sqrt(R2)
	var phi := atan2(z, x)
	match p.kind:
		Kind.BAR:
			var r2 := R2 + y * y
			var r := sqrt(r2)
			if r < 1e-9: return PackedFloat64Array([0.0, 0.0])
			var rb: float = p.rb
			var g := -pow(rb / r, 3.0) if r >= rb else pow(r / rb, 3.0) - 2.0
			var a: float = 2.0 * (phi - GalPattern.angle(p, t))
			var k: float = p.amp * R2 / r2 * g
			return PackedFloat64Array([k * cos(a), -2.0 * k * sin(a)])
		Kind.SPIRAL:
			if R < 1e-6: return PackedFloat64Array([0.0, 0.0])
			var n: float = p.n
			var sa := sin(float(p.pitch))
			var ta := tan(float(p.pitch))
			var K := n / (R * sa)
			var q := K * float(p.h)
			var B := q * (1.0 + 0.4 * q)
			var D := (1.0 + q + 0.3 * q * q) / (1.0 + 0.3 * q)
			var gam := n * (phi - GalPattern.angle(p, t) + log(R / float(p.r0)) / ta)
			var S := exp(-B * GalPattern.log_cosh(K * y / B))
			var f := exp(-(R - float(p.r0)) / float(p.rs)) / (K * D)
			return PackedFloat64Array([-float(p.amp) * f * cos(gam) * S, float(p.amp) * f * n * sin(gam) * S])
	return PackedFloat64Array([0.0, 0.0])

static func log_cosh(x: float) -> float:
	var a := absf(x)
	return a + log(1.0 + exp(-2.0 * a)) - log(2.0)

static func phi(p: Dictionary, x: float, y: float, z: float, t: float) -> float:
	return GalPattern.growth(p, t) * GalPattern._full(p, x, y, z, t)[0]

## ∂Φ/∂t at a fixed point: the growth term plus the pattern turning past it.
static func dphi_dt(p: Dictionary, x: float, y: float, z: float, t: float) -> float:
	var f := GalPattern._full(p, x, y, z, t)
	return GalPattern.growth_rate(p, t) * f[0] - GalPattern.growth(p, t) * float(p.omega) * f[1]

## Adds −∇Φ at (x, y, z, t) into out[k..k+2].
static func add_accel(p: Dictionary, x: float, y: float, z: float, t: float, out: PackedFloat64Array, k: int) -> void:
	var s := GalPattern.growth(p, t)
	if s == 0.0: return
	var R2 := x * x + z * z
	var R := sqrt(R2)
	var phi := atan2(z, x)
	match p.kind:
		Kind.BAR:
			var r2 := R2 + y * y
			var r := sqrt(r2)
			if r < 1e-9: return
			var rb: float = p.rb
			var a: float = 2.0 * GalPattern.angle(p, t)
			var c := cos(a)
			var sn := sin(a)
			# (R/r)² cos 2(φ − φb) = Q/r² with Q = (x² − z²) cos 2φb + 2xz sin 2φb.
			var Q := (x * x - z * z) * c + 2.0 * x * z * sn
			var h: float
			var dh: float
			if r >= rb:
				h = -rb * rb * rb / (r2 * r2 * r)
				dh = 5.0 * rb * rb * rb / (r2 * r2 * r2)
			else:
				h = r / (rb * rb * rb) - 2.0 / r2
				dh = 1.0 / (rb * rb * rb) + 4.0 / (r2 * r)
			var A: float = s * float(p.amp)
			var radial := A * Q * dh / r
			out[k] -= A * h * (2.0 * x * c + 2.0 * z * sn) + radial * x
			out[k + 1] -= radial * y
			out[k + 2] -= A * h * (-2.0 * z * c + 2.0 * x * sn) + radial * z
		Kind.SPIRAL:
			if R < 1e-6: return
			var n: float = p.n
			var sa := sin(float(p.pitch))
			var ta := tan(float(p.pitch))
			var H: float = p.h
			var K := n / (R * sa)
			var dK := -K / R
			var q := K * H
			var dq := dK * H
			var B := q * (1.0 + 0.4 * q)
			var dB := dq * (1.0 + 0.8 * q)
			var den := 1.0 + 0.3 * q
			var D := (1.0 + q + 0.3 * q * q) / den
			var dD := ((1.0 + 0.6 * q) * den - 0.3 * (1.0 + q + 0.3 * q * q)) / (den * den) * dq
			var gam := n * (phi - GalPattern.angle(p, t) + log(R / float(p.r0)) / ta)
			var xx := K * y / B
			var lc := GalPattern.log_cosh(xx)
			var th := tanh(xx)
			var S := exp(-B * lc)
			var f := exp(-(R - float(p.r0)) / float(p.rs)) / (K * D)
			var A: float = s * float(p.amp)
			var cg := cos(gam)
			var sg := sin(gam)
			var df_f := -1.0 / float(p.rs) - dK / K - dD / D
			var dS_S := -dB * lc - th * y * (dK - K * dB / B)
			var g_R := n / (R * ta)
			# Φ = −A f cos γ S
			var dPhi_dR := -A * f * S * (df_f * cg - g_R * sg + dS_S * cg)
			var dPhi_dphi := A * f * n * sg * S
			var dPhi_dy := A * f * cg * S * K * th
			out[k] -= dPhi_dR * x / R - dPhi_dphi * z / R2
			out[k + 1] -= dPhi_dy
			out[k + 2] -= dPhi_dR * z / R + dPhi_dphi * x / R2
