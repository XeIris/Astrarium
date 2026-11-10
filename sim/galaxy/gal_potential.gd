class_name GalPotential
extends RefCounted

# A galaxy's gravity as a sum of analytic, axisymmetric components, in GalUnits
# (kpc, Myr, 10¹⁰ M☉). The symmetry axis is the scene's Y; the disc is the XZ plane.
# Every component's potential is zero at infinity. Forms and the Milky Way's numbers
# are Bovy (2015, ApJS 216, 29) as galpy implements them; docs/physics/galaxies.md.

enum Kind { POWER_CUTOFF, MIYAMOTO_NAGAI, NFW, HERNQUIST }

## Each part: {kind, name, and its parameters}. `gm` is G·M in kpc³ Myr⁻² for the
## Miyamoto–Nagai disc and Hernquist sphere, and G·M_s = 4πGρ₀a³ for NFW; `amp` is
## G·ρ₀·r₁^α for the power law with cutoff, whose enclosed mass is tabulated (`tab`).
var parts: Array = []

# The power-law bulge's G·M(r) on a ln r grid, for Hermite interpolation.
const TAB_N := 768
const TAB_R0 := 1e-4
const TAB_R1 := 200.0

static func power_cutoff(name: String, alpha: float, rc: float, amp := 1.0) -> Dictionary:
	var p := {"kind": Kind.POWER_CUTOFF, "name": name, "alpha": alpha, "rc": rc, "amp": amp}
	_tabulate(p)
	return p

static func miyamoto_nagai(name: String, a: float, b: float, gm := 1.0) -> Dictionary:
	return {"kind": Kind.MIYAMOTO_NAGAI, "name": name, "a": a, "b": b, "gm": gm}

static func nfw(name: String, a: float, gm := 1.0) -> Dictionary:
	return {"kind": Kind.NFW, "name": name, "a": a, "gm": gm}

static func hernquist(name: String, a: float, gm := 1.0) -> Dictionary:
	return {"kind": Kind.HERNQUIST, "name": name, "a": a, "gm": gm}

func add(p: Dictionary) -> GalPotential:
	parts.append(p)
	return self

func part(name: String) -> Dictionary:
	for p in parts:
		if p.name == name: return p
	return {}

## galpy's `normalize`: scale each part so that it alone supplies `fractions[i]` of
## v0² at (R0, z = 0), i.e. of the radial force a circular orbit there needs.
func normalize(r0: float, v0: float, fractions: Array) -> GalPotential:
	for i in parts.size():
		var p: Dictionary = parts[i]
		var unit := GalPotential.radial_force_of(p, r0, 0.0) * -r0
		_scale(p, float(fractions[i]) * v0 * v0 / unit)
	return self

static func _scale(p: Dictionary, k: float) -> void:
	if p.kind == Kind.POWER_CUTOFF:
		p.amp *= k
		var t: PackedFloat64Array = p.tab
		var d: PackedFloat64Array = p.dtab
		for i in t.size():
			t[i] *= k
			d[i] *= k
		p.gm_total *= k
	else:
		p.gm *= k

# ---- per-part fields

## G·M(<r) for a spherical part; NaN for the disc.
static func gm_within(p: Dictionary, r: float) -> float:
	match p.kind:
		Kind.POWER_CUTOFF:
			var x: float = r * r / (p.rc * p.rc)
			var s: float = 1.5 - 0.5 * p.alpha
			return TAU * p.amp * pow(p.rc, 3.0 - p.alpha) * exp(gammln(s)) * gamma_p(s, x)
		Kind.NFW:
			var q: float = r / p.a
			return p.gm * (log(1.0 + q) - q / (1.0 + q))
		Kind.HERNQUIST:
			return p.gm * r * r / ((r + p.a) * (r + p.a))
	return NAN

static func phi_of(p: Dictionary, x: float, y: float, z: float) -> float:
	var R2 := x * x + z * z
	var r := sqrt(R2 + y * y)
	match p.kind:
		Kind.POWER_CUTOFF:
			var rc: float = p.rc
			var xx := r * r / (rc * rc)
			var s0: float = 1.0 - 0.5 * p.alpha
			var outer: float = TAU * p.amp * pow(rc, 2.0 - p.alpha) * exp(gammln(s0)) * gamma_q(s0, xx)
			# G·M(r)/r ∝ r^(2−α) vanishes at the centre for α < 2.
			if r == 0.0: return -outer
			return -GalPotential.gm_within(p, r) / r - outer
		Kind.MIYAMOTO_NAGAI:
			var s: float = p.a + sqrt(y * y + p.b * p.b)
			return -p.gm / sqrt(R2 + s * s)
		Kind.NFW:
			if r == 0.0: return -p.gm / p.a
			return -p.gm * log(1.0 + r / p.a) / r
		Kind.HERNQUIST:
			return -p.gm / (r + p.a)
	return 0.0

## F_R (kpc Myr⁻²) at cylindrical radius R and height y.
static func radial_force_of(p: Dictionary, R: float, y: float) -> float:
	var r := sqrt(R * R + y * y)
	match p.kind:
		Kind.MIYAMOTO_NAGAI:
			var s: float = p.a + sqrt(y * y + p.b * p.b)
			var d := R * R + s * s
			return -p.gm * R / (d * sqrt(d))
	if r == 0.0: return 0.0
	return -GalPotential.gm_within(p, r) * R / (r * r * r)

## Mass density in 10¹⁰ M☉ kpc⁻³.
static func density_of(p: Dictionary, R: float, y: float) -> float:
	var r := sqrt(R * R + y * y)
	var g := GalUnits.G
	match p.kind:
		Kind.POWER_CUTOFF:
			if r == 0.0: return INF
			return p.amp / g * pow(r, -p.alpha) * exp(-r * r / (p.rc * p.rc))
		Kind.MIYAMOTO_NAGAI:
			var a: float = p.a
			var b2: float = p.b * p.b
			var zb := sqrt(y * y + b2)
			var s := a + zb
			return p.gm / g * b2 / (4.0 * PI) * (a * R * R + (a + 3.0 * zb) * s * s) \
				/ (pow(R * R + s * s, 2.5) * zb * zb * zb)
		Kind.NFW:
			var q: float = r / p.a
			return p.gm / g / (4.0 * PI * p.a * p.a * p.a) / (q * (1.0 + q) * (1.0 + q))
		Kind.HERNQUIST:
			return p.gm / g * p.a / (TAU * r * pow(r + p.a, 3.0))
	return 0.0

## Total G·M of a part (NFW's diverges: INF).
static func gm_total(p: Dictionary) -> float:
	match p.kind:
		Kind.POWER_CUTOFF: return p.gm_total
		Kind.NFW: return INF
	return p.gm

# ---- the composite

## The parts flattened for an inlined loop: at most one disc, two analytic spheres
## (NFW or Hernquist) and one tabulated sphere. Null when the parts don't fit.
class Kernel extends RefCounted:
	var mn_gm := 0.0
	var mn_a := 0.0
	var mn_b2 := 0.0
	var s1_gm := 0.0
	var s1_a := 1.0
	var s1_nfw := false
	var s2_gm := 0.0
	var s2_a := 1.0
	var s2_nfw := false
	var tab := PackedFloat64Array()
	var dtab := PackedFloat64Array()
	var tab_h := 1.0
	var tab_r0 := TAB_R0
	var tab_n := 0
	var tab_gm := 0.0
	var tab_alpha := 0.0

var _kernel: Kernel = null
var _kernel_built := false

func kernel() -> Kernel:
	if _kernel_built: return _kernel
	_kernel_built = true
	var k := Kernel.new()
	var spheres := 0
	for p in parts:
		match p.kind:
			Kind.MIYAMOTO_NAGAI:
				if k.mn_gm != 0.0: return null
				k.mn_gm = p.gm; k.mn_a = p.a; k.mn_b2 = p.b * p.b
			Kind.POWER_CUTOFF:
				if k.tab_n != 0: return null
				k.tab = p.tab; k.dtab = p.dtab; k.tab_h = p.tab_h; k.tab_n = TAB_N
				k.tab_gm = p.gm_total; k.tab_alpha = p.alpha
			_:
				spheres += 1
				if spheres == 1:
					k.s1_gm = p.gm; k.s1_a = p.a; k.s1_nfw = p.kind == Kind.NFW
				elif spheres == 2:
					k.s2_gm = p.gm; k.s2_a = p.a; k.s2_nfw = p.kind == Kind.NFW
				else:
					return null
	_kernel = k
	return k

func phi(x: float, y: float, z: float) -> float:
	var s := 0.0
	for p in parts: s += GalPotential.phi_of(p, x, y, z)
	return s

func radial_force(R: float, y := 0.0) -> float:
	var s := 0.0
	for p in parts: s += GalPotential.radial_force_of(p, R, y)
	return s

## Circular speed in the plane, kpc/Myr.
func vc(R: float) -> float:
	return sqrt(maxf(-R * radial_force(R), 0.0))

func vc_of(name: String, R: float) -> float:
	return sqrt(maxf(-R * GalPotential.radial_force_of(part(name), R, 0.0), 0.0))

func density(R: float, y: float) -> float:
	var s := 0.0
	for p in parts: s += GalPotential.density_of(p, R, y)
	return s

## Epicyclic κ² and vertical ν² (Myr⁻²) at R in the plane, by central differences.
func kappa2(R: float) -> float:
	var h := R * 1e-4
	var f := radial_force(R)
	var dfdr := (radial_force(R + h) - radial_force(R - h)) / (2.0 * h)
	return -dfdr - 3.0 * f / R

func nu2(R: float) -> float:
	var h := 1e-4
	return (phi(R, h, 0.0) - 2.0 * phi(R, 0.0, 0.0) + phi(R, -h, 0.0)) / (h * h)

## Accelerations for `count` points packed as x, y, z; written over `acc`.
func accel_into(pos: PackedFloat64Array, acc: PackedFloat64Array, count: int) -> void:
	acc.fill(0.0)
	for p in parts:
		match p.kind:
			Kind.MIYAMOTO_NAGAI: _acc_mn(p, pos, acc, count)
			Kind.POWER_CUTOFF: _acc_tab(p, pos, acc, count)
			_: _acc_spherical(p, pos, acc, count)

static func _acc_mn(p: Dictionary, pos: PackedFloat64Array, acc: PackedFloat64Array, n: int) -> void:
	var gm: float = p.gm
	var a: float = p.a
	var b2: float = p.b * p.b
	for i in n:
		var k := i * 3
		var x := pos[k]
		var y := pos[k + 1]
		var z := pos[k + 2]
		var zb := sqrt(y * y + b2)
		var s := a + zb
		var d := x * x + z * z + s * s
		var f := -gm / (d * sqrt(d))
		acc[k] += f * x
		acc[k + 1] += f * y * s / zb
		acc[k + 2] += f * z

static func _acc_spherical(p: Dictionary, pos: PackedFloat64Array, acc: PackedFloat64Array, n: int) -> void:
	var gm: float = p.gm
	var a: float = p.a
	var nfw: bool = p.kind == Kind.NFW
	for i in n:
		var k := i * 3
		var x := pos[k]
		var y := pos[k + 1]
		var z := pos[k + 2]
		var r2 := x * x + y * y + z * z
		var r := sqrt(r2)
		var m: float
		if nfw:
			var q := r / a
			# Below q ~ 1e-4 the two terms cancel; the series is (q²/2)(1 − 4q/3).
			m = gm * (log(1.0 + q) - q / (1.0 + q)) if q > 1e-4 else gm * q * q * (0.5 - q * 2.0 / 3.0)
		else:
			m = gm * r2 / ((r + a) * (r + a))
		var f := -m / (r2 * r) if r > 0.0 else 0.0
		acc[k] += f * x
		acc[k + 1] += f * y
		acc[k + 2] += f * z

static func _acc_tab(p: Dictionary, pos: PackedFloat64Array, acc: PackedFloat64Array, n: int) -> void:
	for i in n:
		var k := i * 3
		var x := pos[k]
		var y := pos[k + 1]
		var z := pos[k + 2]
		var r2 := x * x + y * y + z * z
		var r := sqrt(r2)
		var f := -GalPotential.gm_tab(p, r) / (r2 * r) if r > 0.0 else 0.0
		acc[k] += f * x
		acc[k + 1] += f * y
		acc[k + 2] += f * z

## G·M(<r) of a tabulated part. A spherical force is conservative whatever the
## interpolation, so tracers conserve the energy of the interpolated potential; its
## difference from the exact one is ~1e-9 of the bulge's (galaxycheck).
static func gm_tab(p: Dictionary, r: float) -> float:
	var t: PackedFloat64Array = p.tab
	var d: PackedFloat64Array = p.dtab
	var h: float = p.tab_h
	if r <= TAB_R0: return t[0] * pow(r / TAB_R0, 3.0 - p.alpha)
	var u := log(r / TAB_R0) / h
	var i := int(u)
	if i >= TAB_N - 1: return p.gm_total
	var s := u - float(i)
	var s2 := s * s
	var s3 := s2 * s
	return (2.0 * s3 - 3.0 * s2 + 1.0) * t[i] + (s3 - 2.0 * s2 + s) * h * d[i] \
		+ (-2.0 * s3 + 3.0 * s2) * t[i + 1] + (s3 - s2) * h * d[i + 1]

static func _tabulate(p: Dictionary) -> void:
	var t := PackedFloat64Array()
	var d := PackedFloat64Array()
	t.resize(TAB_N)
	d.resize(TAB_N)
	var h := log(TAB_R1 / TAB_R0) / float(TAB_N - 1)
	for i in TAB_N:
		var r := TAB_R0 * exp(h * float(i))
		t[i] = GalPotential.gm_within(p, r)
		# dGM/dln r = 4πG r³ ρ(r)
		d[i] = 2.0 * TAU * p.amp * pow(r, 3.0 - p.alpha) * exp(-r * r / (p.rc * p.rc))
	p.tab = t
	p.dtab = d
	p.tab_h = h
	var s: float = 1.5 - 0.5 * p.alpha
	p.gm_total = TAU * p.amp * pow(p.rc, 3.0 - p.alpha) * exp(gammln(s))

# ---- special functions (Numerical Recipes, 3rd ed., §6.1–6.2)

static func gammln(xx: float) -> float:
	const COF := [57.1562356658629235, -59.5979603554754912, 14.1360979747417471,
		-0.491913816097620199, 0.339946499848118887e-4, 0.465236289270485756e-4,
		-0.983744753048795646e-4, 0.158088703224912494e-3, -0.210264441724104883e-3,
		0.217439618115212643e-3, -0.164318106536763890e-3, 0.844182239838527433e-4,
		-0.261908384015814087e-4, 0.368991826595316234e-5]
	var x := xx
	var y := xx
	var tmp := x + 5.24218750000000000
	tmp = (x + 0.5) * log(tmp) - tmp
	var ser := 0.999999999999997092
	for c in COF:
		y += 1.0
		ser += float(c) / y
	return tmp + log(2.5066282746310005 * ser / x)

## Regularised lower incomplete gamma P(a, x).
static func gamma_p(a: float, x: float) -> float:
	if x <= 0.0: return 0.0
	if x < a + 1.0: return _gser(a, x)
	return 1.0 - _gcf(a, x)

## Upper Γ(a, x) / Γ(a).
static func gamma_q(a: float, x: float) -> float:
	if x <= 0.0: return 1.0
	if x < a + 1.0: return 1.0 - _gser(a, x)
	return _gcf(a, x)

static func _gser(a: float, x: float) -> float:
	var ap := a
	var s := 1.0 / a
	var del := s
	for i in 400:
		ap += 1.0
		del *= x / ap
		s += del
		if absf(del) < absf(s) * 1e-16: break
	return s * exp(-x + a * log(x) - gammln(a))

static func _gcf(a: float, x: float) -> float:
	var tiny := 1e-300
	var b := x + 1.0 - a
	var c := 1.0 / tiny
	var d := 1.0 / b
	var h := d
	for i in range(1, 400):
		var an := -float(i) * (float(i) - a)
		b += 2.0
		d = an * d + b
		if absf(d) < tiny: d = tiny
		c = b + an / c
		if absf(c) < tiny: c = tiny
		d = 1.0 / d
		var del := d * c
		h *= del
		if absf(del - 1.0) < 1e-16: break
	return exp(-x + a * log(x) - gammln(a)) * h
