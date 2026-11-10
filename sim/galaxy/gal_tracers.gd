class_name GalTracers
extends RefCounted

# Massless test particles in a static potential: the stars and gas clouds whose
# motion the galactic scene shows and measures. Drift–kick–drift is symplectic, so
# each tracer's energy error stays bounded, and in an axisymmetric potential the
# kicks have no azimuthal part, so L about the axis is kept to rounding.

## Fixed step, Myr. A circular orbit at 2 kpc takes ~60 Myr, so ~600 steps.
const DT := 0.1

var pot: GalPotential
var n := 0
var pos := PackedFloat64Array()
var vel := PackedFloat64Array()
var acc := PackedFloat64Array()
## Each tracer's population index into `populations`.
var pop := PackedByteArray()
var populations: Array = []
var sense := 1.0
var t := 0.0
var steps := 0
## Each tracer's energy at the start, for the drift diagnostic.
var e0 := PackedFloat64Array()

func _init(model: Dictionary) -> void:
	pot = model.potential
	sense = float(model.get("sense", 1.0))
	populations = model.populations
	var rng := RandomNumberGenerator.new()
	rng.seed = int(model.get("seed", 1))
	for i in populations.size():
		var p: Dictionary = populations[i]
		match p.kind:
			"gas": _seed_gas(p, i, rng)
			"disc": _seed_disc(p, i, rng)
	acc.resize(n * 3)
	pot.accel_into(pos, acc, n)
	e0 = energies()

func _append(i: int, R: float, phi: float, y: float, vr: float, vphi: float, vy: float) -> void:
	var c := cos(phi)
	var s := sin(phi)
	var vp := vphi * sense
	pos.append_array([R * c, y, R * s])
	vel.append_array([vr * c - vp * s, vy, vr * s + vp * c])
	pop.append(i)
	n += 1

# ---- populations
#
# Both populations are drawn from Shu's (1969) distribution function in the plane,
#   f(E, Lz) ∝ F(Rg) / σR²(Rg) · exp(−(E − Ec(Rg)) / σR²(Rg)),
# Rg the guiding radius of Lz and Ec its circular orbit's energy. f depends on the
# integrals only, so the population is stationary (Jeans' theorem) and a measured
# curve is not a relaxation transient. Each tracer: Rg from F, E − Ec exponential
# weighted by the radial period, then a time-uniform phase along the radial orbit.
# Heights follow an isothermal layer in the potential at that radius,
# ρ ∝ exp(−(Φ(R, z) − Φ(R, 0))/σz²), with Gaussian vz (separable, so approximate).

func _seed_gas(p: Dictionary, idx: int, rng: RandomNumberGenerator) -> void:
	var s: float = float(p.sigmaKms) * GalUnits.KMS
	var flat: float = p.flatTo
	var scale: float = p.scale
	_seed_shu(p, idx, rng, func(R: float) -> float: return exp(-maxf(R - flat, 0.0) / scale),
		func(_R: float) -> float: return s, func(_R: float) -> float: return s)

func _seed_disc(p: Dictionary, idx: int, rng: RandomNumberGenerator) -> void:
	var part: Dictionary = pot.part(String(p.part))
	var sr0: float = float(p.sigmaRKms) * GalUnits.KMS
	var sz0: float = float(p.sigmaZKms) * GalUnits.KMS
	var rs: float = p.rSigma
	var rref: float = p.rRef
	_seed_shu(p, idx, rng, func(R: float) -> float: return GalTracers.surface_density(part, R),
		func(R: float) -> float: return sr0 * exp(-(R - rref) / rs),
		func(R: float) -> float: return sz0 * exp(-(R - rref) / rs))

var _plane: Disc2D = null

func _seed_shu(p: Dictionary, idx: int, rng: RandomNumberGenerator, surface: Callable, sigma_r: Callable, sigma_z: Callable) -> void:
	if _plane == null: _plane = Disc2D.new(pot, 120.0)
	var plane := _plane
	var guides := _radii(rng, int(p.count), float(p.rmin), float(p.rmax), surface)
	var heights := GalTracers.isothermal_heights(pot, float(p.rmin) * 0.25, float(p.rmax) * 2.0, sigma_z)
	for rg in guides:
		var s2: float = pow(float(sigma_r.call(rg)), 2.0)
		var vc := plane.vc(rg)
		var lz := rg * vc
		var ec := plane.phi(rg) + 0.5 * vc * vc
		var t_cap: float = plane.radial_orbit(ec + 6.0 * s2, lz, rg).t
		var orbit := {}
		for tries in 200:
			var e := ec - s2 * log(1.0 - rng.randf())
			var o := plane.radial_orbit(e, lz, rg)
			if rng.randf() * t_cap <= o.t:
				orbit = o
				break
		if orbit.is_empty():
			orbit = {"e": ec, "rp": rg, "ra": rg}
		var R: float
		var vr := 0.0
		if orbit.ra - orbit.rp < 1e-9 * rg:
			R = rg
		else:
			# The weight is smooth and peaks near the middle; 25 % over its sampled peak
			# bounds it for the rejection.
			var wmax := 0.0
			for k in 13:
				wmax = maxf(wmax, plane.phase_weight(orbit, lz, PI * (float(k) + 0.5) / 13.0))
			var th := 0.0
			for tries in 400:
				th = rng.randf() * PI
				if rng.randf() * wmax * 1.25 <= plane.phase_weight(orbit, lz, th): break
			R = 0.5 * (orbit.ra + orbit.rp) - 0.5 * (orbit.ra - orbit.rp) * cos(th)
			vr = sqrt(maxf(2.0 * (orbit.e - plane.phi(R)) - lz * lz / (R * R), 0.0))
			if rng.randf() < 0.5: vr = -vr
		var sz: float = sigma_z.call(R)
		_append(idx, R, rng.randf() * TAU, GalTracers.draw_height(heights, R, rng), vr, lz / R, rng.randfn(0.0, sz))

## The potential in the plane, tabulated in ln R for drawing orbits.
class Disc2D extends RefCounted:
	const N := 4096
	var r0 := 0.02
	var h := 0.0
	var phi_t := PackedFloat64Array()
	var vc_t := PackedFloat64Array()

	func _init(p: GalPotential, rmax: float) -> void:
		h = log(rmax / r0) / float(N - 1)
		phi_t.resize(N)
		vc_t.resize(N)
		for i in N:
			var R := r0 * exp(h * float(i))
			phi_t[i] = p.phi(R, 0.0, 0.0)
			vc_t[i] = p.vc(R)

	func _at(t: PackedFloat64Array, R: float) -> float:
		var u := clampf(log(R / r0) / h, 0.0, float(N - 1) - 1e-9)
		var i := int(u)
		return lerpf(t[i], t[i + 1], u - float(i))

	func phi(R: float) -> float: return _at(phi_t, R)
	func vc(R: float) -> float: return _at(vc_t, R)

	func _excess(e: float, lz: float, R: float) -> float:
		return e - phi(R) - 0.5 * lz * lz / (R * R)

	## Pericentre and apocentre of (E, Lz) by bisection either side of Rg.
	func turning_points(e: float, lz: float, rg: float) -> Dictionary:
		var lo := r0
		var hi := rg
		for i in 44:
			var mid := sqrt(lo * hi)
			if _excess(e, lz, mid) > 0.0: hi = mid
			else: lo = mid
		var rp := hi
		lo = rg
		hi = rg * 2.0
		while _excess(e, lz, hi) > 0.0 and hi < r0 * exp(h * float(N - 2)): hi *= 2.0
		for i in 44:
			var mid := sqrt(lo * hi)
			if _excess(e, lz, mid) > 0.0: lo = mid
			else: hi = mid
		return {"rp": rp, "ra": lo}

	## dt/dθ for R = mid − half·cos θ; finite at the turning points.
	func phase_weight(o: Dictionary, lz: float, th: float) -> float:
		var half: float = 0.5 * (o.ra - o.rp)
		var R: float = 0.5 * (o.ra + o.rp) - half * cos(th)
		var v := sqrt(maxf(2.0 * _excess(o.e, lz, R), 1e-30))
		return half * sin(th) / v

	## The radial orbit of (E, Lz): turning points, and the period 2∫dR/vR in θ by the
	## midpoint rule.
	func radial_orbit(e: float, lz: float, rg: float) -> Dictionary:
		var o := turning_points(e, lz, rg)
		o.e = e
		o.t = 0.0
		if o.ra - o.rp < 1e-9 * rg: return o
		var s := 0.0
		for k in 24:
			s += phase_weight(o, lz, PI * (float(k) + 0.5) / 24.0)
		o.t = 2.0 * s * PI / 24.0
		return o

## `count` radii in [rmin, rmax] with density 2πR Σ(R), by inverting a tabulated CDF.
static func _radii(rng: RandomNumberGenerator, count: int, rmin: float, rmax: float, sigma: Callable) -> PackedFloat64Array:
	var m := 512
	var cdf := PackedFloat64Array()
	cdf.resize(m)
	cdf[0] = 0.0
	var dr := (rmax - rmin) / float(m - 1)
	var prev := rmin * float(sigma.call(rmin))
	for i in range(1, m):
		var r := rmin + dr * float(i)
		var cur := r * float(sigma.call(r))
		cdf[i] = cdf[i - 1] + 0.5 * (prev + cur) * dr
		prev = cur
	var out := PackedFloat64Array()
	for k in count:
		var u := rng.randf() * cdf[m - 1]
		var i := cdf.bsearch(u)
		i = clampi(i, 1, m - 1)
		var f := (u - cdf[i - 1]) / maxf(cdf[i] - cdf[i - 1], 1e-300)
		out.append(rmin + dr * (float(i - 1) + f))
	return out

## Σ(R) of a part, by integrating its density over height in u = asinh(y/b).
static func surface_density(part: Dictionary, R: float) -> float:
	var b: float = maxf(float(part.get("b", 0.3)), 0.05)
	var umax := asinh(40.0 / b)
	var k := 160
	var du := umax / float(k)
	var s := 0.0
	for i in k + 1:
		var u := du * float(i)
		var w := 1.0 if i == 0 or i == k else (4.0 if i % 2 == 1 else 2.0)
		s += w * GalPotential.density_of(part, R, b * sinh(u)) * b * cosh(u)
	return 2.0 * s * du / 3.0

const H_ROWS := 64
const H_Q := 256

## |z| quantiles of an isothermal layer, ρ ∝ exp(−(Φ(R, z) − Φ(R, 0))/σz²), on H_ROWS
## radii spaced in ln R over [rmin, rmax]: row-major, H_Q + 1 per row.
static func isothermal_heights(p: GalPotential, rmin: float, rmax: float, sigma_z: Callable) -> Dictionary:
	var k := 384
	var out := PackedFloat64Array()
	var cdf := PackedFloat64Array()
	cdf.resize(k + 1)
	for row in H_ROWS:
		var R := rmin * pow(rmax / rmin, float(row) / float(H_ROWS - 1))
		var s2: float = pow(float(sigma_z.call(R)), 2.0)
		var p0 := p.phi(R, 0.0, 0.0)
		# The layer's harmonic thickness sets the grid: z = z0 sinh(u).
		var z0 := sqrt(s2 / maxf(p.nu2(R), 1e-12)) * 0.25
		var umax := asinh(maxf(40.0, 30.0 * z0) / z0)
		var du := umax / float(k)
		cdf[0] = 0.0
		var prev := z0
		for i in range(1, k + 1):
			var u := du * float(i)
			var z := z0 * sinh(u)
			var cur := exp(-(p.phi(R, z, 0.0) - p0) / s2) * z0 * cosh(u)
			cdf[i] = cdf[i - 1] + 0.5 * (prev + cur) * du
			prev = cur
		for q in H_Q + 1:
			var target := cdf[k] * float(q) / float(H_Q)
			var i := clampi(cdf.bsearch(target), 1, k)
			var f := (target - cdf[i - 1]) / maxf(cdf[i] - cdf[i - 1], 1e-300)
			out.append(z0 * sinh(du * (float(i - 1) + f)))
	return {"q": out, "rmin": rmin, "rmax": rmax}

## A height from the table: linear in ln R between rows and in the quantile.
static func draw_height(tab: Dictionary, R: float, rng: RandomNumberGenerator) -> float:
	var q: PackedFloat64Array = tab.q
	var fr := clampf(log(R / tab.rmin) / log(tab.rmax / tab.rmin), 0.0, 1.0) * float(H_ROWS - 1)
	var r0 := mini(int(fr), H_ROWS - 2)
	var wr := fr - float(r0)
	var fq := rng.randf() * float(H_Q)
	var q0 := mini(int(fq), H_Q - 1)
	var wq := fq - float(q0)
	var a := lerpf(q[r0 * (H_Q + 1) + q0], q[r0 * (H_Q + 1) + q0 + 1], wq)
	var b := lerpf(q[(r0 + 1) * (H_Q + 1) + q0], q[(r0 + 1) * (H_Q + 1) + q0 + 1], wq)
	var y := lerpf(a, b, wr)
	return y if rng.randf() < 0.5 else -y

# ---- integration

## `k` drift–kick–drift steps of DT. Test particles don't feel each other, so each
## tracer takes all k steps in turn with the potential inlined (GalPotential.Kernel).
func step(k: int) -> void:
	if k <= 0: return
	var kn := pot.kernel()
	if kn == null:
		for s in k: _step_generic()
	else:
		_step_fused(kn, k)
	steps += k
	t = float(steps) * DT

func _step_generic() -> void:
	var h := DT * 0.5
	for i in n * 3: pos[i] += vel[i] * h
	pot.accel_into(pos, acc, n)
	for i in n * 3:
		vel[i] += acc[i] * DT
		pos[i] += vel[i] * h

func _step_fused(kn: GalPotential.Kernel, k: int) -> void:
	var h := DT * 0.5
	var dt := DT
	var mn_gm := kn.mn_gm
	var mn_a := kn.mn_a
	var mn_b2 := kn.mn_b2
	var s1_gm := kn.s1_gm
	var s1_a := kn.s1_a
	var s1_nfw := kn.s1_nfw
	var s2_gm := kn.s2_gm
	var s2_a := kn.s2_a
	var s2_nfw := kn.s2_nfw
	var tb: PackedFloat64Array = kn.tab
	var td: PackedFloat64Array = kn.dtab
	var th := kn.tab_h
	var tr0 := kn.tab_r0
	var tn := kn.tab_n
	var tgm := kn.tab_gm
	var talpha := kn.tab_alpha
	var has_tab := tn > 0
	for i in n:
		var c := i * 3
		var x := pos[c]; var y := pos[c + 1]; var z := pos[c + 2]
		var vx := vel[c]; var vy := vel[c + 1]; var vz := vel[c + 2]
		for s in k:
			x += vx * h; y += vy * h; z += vz * h
			var ax := 0.0; var ay := 0.0; var az := 0.0
			if mn_gm != 0.0:
				var zb := sqrt(y * y + mn_b2)
				var sa := mn_a + zb
				var d := x * x + z * z + sa * sa
				var f := -mn_gm / (d * sqrt(d))
				ax += f * x; ay += f * y * sa / zb; az += f * z
			var r2 := x * x + y * y + z * z
			var r := sqrt(r2)
			var m := 0.0
			if s1_gm != 0.0:
				var q := r / s1_a
				if s1_nfw:
					m += s1_gm * (log(1.0 + q) - q / (1.0 + q)) if q > 1e-4 else s1_gm * q * q * (0.5 - q * 2.0 / 3.0)
				else:
					m += s1_gm * r2 / ((r + s1_a) * (r + s1_a))
			if s2_gm != 0.0:
				var q := r / s2_a
				if s2_nfw:
					m += s2_gm * (log(1.0 + q) - q / (1.0 + q)) if q > 1e-4 else s2_gm * q * q * (0.5 - q * 2.0 / 3.0)
				else:
					m += s2_gm * r2 / ((r + s2_a) * (r + s2_a))
			if has_tab:
				if r <= tr0:
					m += tb[0] * pow(r / tr0, 3.0 - talpha)
				else:
					var u := log(r / tr0) / th
					var j := int(u)
					if j >= tn - 1:
						m += tgm
					else:
						var w := u - float(j)
						var w2 := w * w
						var w3 := w2 * w
						m += (2.0 * w3 - 3.0 * w2 + 1.0) * tb[j] + (w3 - 2.0 * w2 + w) * th * td[j] \
							+ (-2.0 * w3 + 3.0 * w2) * tb[j + 1] + (w3 - w2) * th * td[j + 1]
			if r > 0.0:
				var g := -m / (r2 * r)
				ax += g * x; ay += g * y; az += g * z
			vx += ax * dt; vy += ay * dt; vz += az * dt
			x += vx * h; y += vy * h; z += vz * h
		pos[c] = x; pos[c + 1] = y; pos[c + 2] = z
		vel[c] = vx; vel[c + 1] = vy; vel[c + 2] = vz

# ---- diagnostics

## Specific energy of each tracer, kpc² Myr⁻².
func energies() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n)
	for i in n:
		var k := i * 3
		var v2 := vel[k] * vel[k] + vel[k + 1] * vel[k + 1] + vel[k + 2] * vel[k + 2]
		out[i] = 0.5 * v2 + pot.phi(pos[k], pos[k + 1], pos[k + 2])
	return out

## Angular momentum about the symmetry axis, in the rotation's sense.
func lz(i: int) -> float:
	var k := i * 3
	return (pos[k] * vel[k + 2] - pos[k + 2] * vel[k]) * sense

## Largest |ΔE/E| since the start over every `stride`-th tracer (Φ of the bulge costs
## incomplete gamma functions, so the HUD samples).
func energy_drift(stride := 1) -> float:
	var worst := 0.0
	for i in range(0, n, maxi(stride, 1)):
		var k := i * 3
		var v2 := vel[k] * vel[k] + vel[k + 1] * vel[k + 1] + vel[k + 2] * vel[k + 2]
		var e := 0.5 * v2 + pot.phi(pos[k], pos[k + 1], pos[k + 2])
		worst = maxf(worst, absf((e - e0[i]) / e0[i]))
	return worst

func population_index(name: String) -> int:
	for i in populations.size():
		if populations[i].name == name: return i
	return -1
