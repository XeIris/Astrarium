class_name GalEncounter
extends RefCounted

# Galaxies meeting, in two regimes. Far apart, each galaxy is a rigid potential (a Hernquist
# halo, a Miyamoto–Nagai disc about its spin and a Hernquist bulge) whose centre moves as
# GalOrbits has it, and its disc and bulge stars are massless test particles in every galaxy's
# potential: cheap, and exact while the galaxies barely touch. Once the two leading galaxies
# come within `live_at`, every galaxy becomes particles (GalLive): its halo, drawn when the
# encounter was built, joins its stars, the stars take their masses, and from then on all of
# them move under each other's gravity, which is what tidal tails and a merger need. The
# restricted kernel's C twin is run_encounter in native/astrarium_native.c; it must stay
# bit-identical (only sqrt). docs/physics/galaxies.md#encounters-phase-4.

## Myr. The innermost disc stars, 1 kpc out in a 220 km/s disc, orbit in ~30 Myr: ~60 steps.
const DT := 0.5
## Per galaxy in the restricted kernel: halo G M and a, disc G M, a, b, bulge G M and a, then
## its local axes x, y (the spin), z in the encounter's frame.
const G_STRIDE := 16
## The live step (Myr) and opening angle. docs/physics/galaxies.md#live says how they were set.
const LIVE_DT := 1.0
const THETA := 0.7
## Toomre's Q of a disc at the reference radius, Hernquist's (1993) normalisation, there the
## Sun's radius in units of the Milky Way's scale length (8.29 / 3.0, van der Marel et al.).
const Q_REF := 1.5
const R_REF := 8.29 / 3.0
## Luminous particles nearest each centre when it goes live, whose mean is its centre after.
const CORE := 64
## The draw tag: galaxy + 4 for a bulge star.
const BULGE_TAG := 4

var orbits: GalOrbits
## Per galaxy: [halo gm, a, disc gm, a, b, bulge gm, a] and its axes (Basis, y the spin).
var params: Array = []
var axes: Array = []
## Per galaxy disc: {gm, rd, z0, sigma_ref} (gm in kpc³ Myr⁻²), or {}.
var discs: Array = []
## Stars: positions and velocities, 3 each (kpc, kpc/Myr), their galaxy and draw tag.
var pos := PackedFloat64Array()
var vel := PackedFloat64Array()
var owner := PackedByteArray()
var tag := PackedByteArray()
## Each star's mass and softening once live (10¹⁰ M☉, kpc).
var star_mass := PackedFloat64Array()
var star_eps := PackedFloat64Array()
var n := 0
var steps := 0
## Per galaxy, its halo as particles about its centre: [positions, velocities, mass each,
## softening], or [].
var haloes: Array = []
## Separation of galaxies 0 and 1 (kpc) at which the encounter goes live; 0 never.
var live_at := 0.0
var live: GalLive = null
var t_live := 0.0
var cores: Array = []
## False forces the GDScript kernels (encountercheck compares them).
var use_native := true
## Each star's float32 (x, y, z, tag), 16 bytes, for the drawing.
var draw_bytes := PackedByteArray()
var _tag_block := PackedFloat64Array()
static var _native := -1

func _init(o: GalOrbits) -> void:
	orbits = o

## Myr since the encounter began.
func time() -> float:
	return t_live + live.t if live != null else orbits.t

## The current step (Myr).
func dt() -> float:
	return LIVE_DT if live != null else DT

func is_live() -> bool:
	return live != null

## Galaxy i's centre (kpc): its moving potential's, then the mean of its core stars.
func centre(i: int) -> Vector3:
	if live == null: return orbits.position(i)
	var core: PackedInt32Array = cores[i]
	if core.is_empty(): return Vector3.ZERO
	var s := [0.0, 0.0, 0.0]
	for j in core:
		var o := GalLive.HDR + GalLive.STRIDE * j
		for c in 3: s[c] += live.buf[o + c]
	return Vector3(s[0], s[1], s[2]) / core.size()

func count() -> int:
	return orbits.count()

## A galaxy's potential for its stars, for galaxy i of the orbits: the halo (M☉, kpc), the disc
## (M☉, a, b) and the bulge (M☉, a), spinning about `spin` (unit, the encounter's frame).
func set_galaxy(i: int, halo: Array, disc: Array, bulge: Array, spin: Vector3) -> void:
	while params.size() <= i:
		params.append([])
		axes.append(Basis())
		discs.append({})
		haloes.append([])
		cores.append(PackedInt32Array())
	var g := GalUnits.G / GalUnits.MASS_UNIT_SUN
	params[i] = [g * float(halo[0]), float(halo[1]), g * float(disc[0]), float(disc[1]), float(disc[2]), g * float(bulge[0]), float(bulge[1])]
	var y := spin.normalized()
	var x := (Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT).cross(y).normalized()
	axes[i] = Basis(x, y, x.cross(y))

## Acceleration at world point (px, py, pz) from galaxy i centred at (cx, cy, cz), added into
## acc[0..2]: the C kernel's order.
func _accel(i: int, px: float, py: float, pz: float, cx: float, cy: float, cz: float, acc: PackedFloat64Array) -> void:
	var P: Array = params[i]
	var B: Basis = axes[i]
	var dx := px - cx
	var dy := py - cy
	var dz := pz - cz
	var r := sqrt(dx * dx + dy * dy + dz * dz)
	if r < 1e-6: return
	var ax := 0.0
	var ay := 0.0
	var az := 0.0
	# Hernquist spheres: G M / (r (r + a)²) toward the centre.
	for k in [0, 5]:
		var gmk: float = P[k]
		if gmk != 0.0:
			var ak: float = P[k + 1]
			var f := -gmk / (r * (r + ak) * (r + ak))
			ax += f * dx
			ay += f * dy
			az += f * dz
	var gd: float = P[2]
	if gd != 0.0:
		var lx := dx * B.x.x + dy * B.x.y + dz * B.x.z
		var ly := dx * B.y.x + dy * B.y.y + dz * B.y.z
		var lz := dx * B.z.x + dy * B.z.y + dz * B.z.z
		var b: float = P[4]
		var zb := sqrt(ly * ly + b * b)
		var s: float = float(P[3]) + zb
		var q := lx * lx + lz * lz + s * s
		var f := -gd / (q * sqrt(q))
		var fx := f * lx
		var fy := f * ly * s / zb
		var fz := f * lz
		ax += fx * B.x.x + fy * B.y.x + fz * B.z.x
		ay += fx * B.x.y + fy * B.y.y + fz * B.z.y
		az += fx * B.x.z + fy * B.y.z + fz * B.z.z
	acc[0] += ax
	acc[1] += ay
	acc[2] += az

## The circular speed in galaxy i's own plane at R (kpc/Myr), from its radial pull there.
func circular_speed(i: int, R: float) -> float:
	var acc := PackedFloat64Array([0.0, 0.0, 0.0])
	var B: Basis = axes[i]
	var p := B.x * R
	_accel(i, p.x, p.y, p.z, 0.0, 0.0, 0.0, acc)
	return sqrt(maxf(-(acc[0] * B.x.x + acc[1] * B.x.y + acc[2] * B.x.z) * R, 0.0))

## Galaxy i's disc surface density at R (G Σ, kpc Myr⁻²).
func _g_sigma(i: int, R: float) -> float:
	var d: Dictionary = discs[i]
	return float(d.gm) / (TAU * float(d.rd) * float(d.rd)) * exp(-R / float(d.rd))

## The disc's mean rotation and dispersions at R for a circular speed vc(R) (a Callable of R):
## σ_R² ∝ e^(−R/R_d) normalised to Q_REF at R_REF R_d (Hernquist 1993), σ_φ from the epicycle,
## σ_z from an isothermal sheet of scale z0 (σ_z² = π G Σ z0), and the mean rotation the Jeans
## equation leaves after asymmetric drift. Returns [v̄_φ, σ_R, σ_φ, σ_z] (kpc/Myr).
func disc_kinematics(i: int, R: float, vc: Callable) -> Array:
	var d: Dictionary = discs[i]
	var rd := float(d.rd)
	var v2 := pow(float(vc.call(R)), 2.0)
	var h := 0.02 * rd
	var dv2 := (pow(float(vc.call(R + h)), 2.0) - pow(float(vc.call(maxf(R - h, 1e-3))), 2.0)) / (R + h - maxf(R - h, 1e-3))
	var omega2 := v2 / (R * R)
	var kappa2 := maxf(dv2 / R + 2.0 * omega2, 1e-12)
	var sr := float(d.sigma_ref) * exp(-(R - R_REF * rd) / (2.0 * rd))
	var sp := sr * sqrt(kappa2 / (4.0 * omega2))
	var sz := sqrt(PI * _g_sigma(i, R) * float(d.z0))
	var vphi2 := v2 + sr * sr * (1.0 - kappa2 / (4.0 * omega2) - 2.0 * R / rd)
	return [sqrt(maxf(vphi2, 0.0)), sr, sp, sz]

## Toomre's Q of galaxy i's disc at R for the circular speed vc(R).
func toomre_q(i: int, R: float, vc: Callable) -> float:
	var k := disc_kinematics(i, R, vc)
	var h := 0.02 * float(discs[i].rd)
	var v2 := pow(float(vc.call(R)), 2.0)
	var dv2 := (pow(float(vc.call(R + h)), 2.0) - pow(float(vc.call(R - h)), 2.0)) / (2.0 * h)
	var kappa := sqrt(maxf(dv2 / R + 2.0 * v2 / (R * R), 1e-12))
	return float(k[1]) * kappa / (3.36 * _g_sigma(i, R))

## Galaxy i's disc as `count` stars of md_sun in all (M☉): exponential in radius with scale rd
## out to 6 rd, sech² in height with z0, warm as disc_kinematics has it in the rigid potential.
func seed_disc(i: int, count: int, md_sun: float, rd: float, z0: float, eps: float, seed: int) -> void:
	discs[i] = {"gm": GalUnits.G * md_sun / GalUnits.MASS_UNIT_SUN, "rd": rd, "z0": z0, "sigma_ref": 0.0}
	var vc := func(R: float) -> float: return circular_speed(i, R)
	# σ_R at the reference radius for Q there: Q = σ_R κ / (3.36 G Σ).
	var rr := R_REF * rd
	var h := 0.02 * rd
	var v2 := pow(circular_speed(i, rr), 2.0)
	var dv2 := (pow(circular_speed(i, rr + h), 2.0) - pow(circular_speed(i, rr - h), 2.0)) / (2.0 * h)
	var kappa := sqrt(dv2 / rr + 2.0 * v2 / (rr * rr))
	discs[i].sigma_ref = Q_REF * 3.36 * _g_sigma(i, rr) / kappa
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var B: Basis = axes[i]
	var c := orbits.pos.slice(3 * i, 3 * i + 3)
	var v0 := orbits.vel.slice(3 * i, 3 * i + 3)
	var by := [B.y.x, B.y.y, B.y.z]
	var m := md_sun / GalUnits.MASS_UNIT_SUN / count
	for k in count:
		# Σ ∝ e^(−R/rd) gives R e^(−R/rd) dR: a Gamma(2) radius.
		var R := 6.0 * rd
		while R >= 6.0 * rd: R = -rd * log(maxf(rng.randf(), 1e-12) * maxf(rng.randf(), 1e-12))
		var phi := rng.randf() * TAU
		var z := z0 * atanh(2.0 * rng.randf() - 1.0)
		# In double throughout: the basis's components, then every product and sum.
		var cp := cos(phi)
		var sp := sin(phi)
		var er := [B.x.x * cp + B.z.x * sp, B.x.y * cp + B.z.y * sp, B.x.z * cp + B.z.z * sp]
		var et := [by[1] * er[2] - by[2] * er[1], by[2] * er[0] - by[0] * er[2], by[0] * er[1] - by[1] * er[0]]
		var kin := disc_kinematics(i, R, vc)
		# The draws in the order they always took: along the rotation, outward, up.
		var vt := float(kin[0]) + float(kin[2]) * rng.randfn()
		var vr := float(kin[1]) * rng.randfn()
		var vz := float(kin[3]) * rng.randfn()
		var p := PackedFloat64Array()
		var v := PackedFloat64Array()
		for a in 3:
			p.append(c[a] + float(er[a]) * R + float(by[a]) * z)
			v.append(v0[a] + float(et[a]) * vt + float(er[a]) * vr + float(by[a]) * vz)
		_add_star(i, i, p, v, m, eps)

## Galaxy i's bulge as `count` stars of mb_sun in all, from the bulge's equilibrium sampler.
func seed_bulge(i: int, count: int, mb_sun: float, sampler: GalEddington, eps: float, seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var s := sampler.sample(rng, count)
	var c := orbits.pos.slice(3 * i, 3 * i + 3)
	var v0 := orbits.vel.slice(3 * i, 3 * i + 3)
	var m := mb_sun / GalUnits.MASS_UNIT_SUN / count
	var p: PackedFloat64Array = s[0]
	var v: PackedFloat64Array = s[1]
	for k in count:
		var q := 3 * k
		_add_star(i, i + BULGE_TAG, PackedFloat64Array([c[0] + p[q], c[1] + p[q + 1], c[2] + p[q + 2]]),
			PackedFloat64Array([v0[0] + v[q], v0[1] + v[q + 1], v0[2] + v[q + 2]]), m, eps)

## Galaxy i's halo, `count` particles of mh_sun in all, from its sampler; it waits, about the
## galaxy's centre, until the encounter goes live.
func seed_halo(i: int, count: int, mh_sun: float, sampler: GalEddington, eps: float, seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var s := sampler.sample(rng, count)
	haloes[i] = [s[0], s[1], mh_sun / GalUnits.MASS_UNIT_SUN / count, eps]

## Position (kpc) and velocity (kpc/Myr), three doubles each.
func _add_star(g: int, t: int, p: PackedFloat64Array, v: PackedFloat64Array, m: float, eps: float) -> void:
	pos.append_array(p)
	vel.append_array(v)
	owner.append(g)
	tag.append(t)
	star_mass.append(m)
	star_eps.append(eps)
	n += 1

static func native_available() -> bool:
	if _native < 0:
		_native = 1 if ClassDB.class_exists("NBodyKernel") and ClassDB.class_has_method("NBodyKernel", "encounter") else 0
	return _native == 1

## Whether the leading pair has come within live_at and the encounter is still restricted.
func due_live() -> bool:
	return live == null and live_at > 0.0 and orbits.count() > 1 and orbits.separation(0, 1) < live_at

## k steps of the current step; the encounter goes live first if due, after which a step is
## LIVE_DT: a caller sizing k in time asks due_live() first.
func step(k: int) -> void:
	if k <= 0: return
	if due_live(): go_live()
	if live != null:
		live.step(k)
		draw_bytes = live.draw_bytes
		steps += k
		return
	var ng := orbits.count()
	var mids := PackedFloat64Array()
	mids.resize(k * ng * 3)
	for s in k:
		var before := orbits.pos.duplicate()
		orbits.step(DT)
		for c in ng * 3: mids[s * ng * 3 + c] = 0.5 * (before[c] + orbits.pos[c])
	if use_native and GalEncounter.native_available():
		var b: PackedFloat64Array = ClassDB.class_call_static("NBodyKernel", "encounter", pack(k, mids))
		var o := 5 + G_STRIDE * ng + k * ng * 3
		pos = b.slice(o, o + 3 * n)
		vel = b.slice(o + 3 * n, o + 6 * n)
		draw_bytes = b.slice(o + 6 * n, o + 8 * n).to_byte_array()
	else:
		_step_gd(k, mids)
		var f := PackedFloat32Array()
		f.resize(4 * n)
		for i in n:
			f[4 * i] = pos[3 * i]
			f[4 * i + 1] = pos[3 * i + 1]
			f[4 * i + 2] = pos[3 * i + 2]
			f[4 * i + 3] = float(tag[i])
		draw_bytes = f.to_byte_array()
	steps += k

## Every galaxy becomes particles: the stars keep their places and take their masses, each
## halo is placed about its galaxy's centre at its velocity, and each disc's mean rotation is
## re-set from the pull of its own galaxy's particles, which differs a little from the rigid
## potential's (an exponential disc is not a Miyamoto–Nagai one).
func go_live() -> void:
	var ng := orbits.count()
	var nh := 0
	for i in ng:
		var h: Array = haloes[i] if i < haloes.size() else []
		if not h.is_empty(): nh += (h[0] as PackedFloat64Array).size() / 3
	for i in ng:
		if i < discs.size() and not (discs[i] as Dictionary).is_empty(): _remap_disc(i)
	var L := GalLive.new(n + nh, n, LIVE_DT, THETA)
	L.use_native = use_native
	for j in n:
		L.set_particle(j, [pos[3 * j], pos[3 * j + 1], pos[3 * j + 2]], [vel[3 * j], vel[3 * j + 1], vel[3 * j + 2]], star_mass[j], star_eps[j], float(tag[j]))
	var o := n
	for i in ng:
		var h: Array = haloes[i] if i < haloes.size() else []
		if h.is_empty(): continue
		var c := orbits.pos.slice(3 * i, 3 * i + 3)
		var v := orbits.vel.slice(3 * i, 3 * i + 3)
		var hp: PackedFloat64Array = h[0]
		var hv: PackedFloat64Array = h[1]
		for q in hp.size() / 3:
			L.set_particle(o, [c[0] + hp[3 * q], c[1] + hp[3 * q + 1], c[2] + hp[3 * q + 2]], [v[0] + hv[3 * q], v[1] + hv[3 * q + 1], v[2] + hv[3 * q + 2]], float(h[2]), float(h[3]))
			o += 1
	for i in ng: cores[i] = _core(i)
	t_live = orbits.t
	live = L

## The CORE stars of galaxy i nearest its centre.
func _core(i: int) -> PackedInt32Array:
	var c := orbits.pos.slice(3 * i, 3 * i + 3)
	var near := []
	for j in n:
		if owner[j] != i: continue
		var dx := pos[3 * j] - c[0]
		var dy := pos[3 * j + 1] - c[1]
		var dz := pos[3 * j + 2] - c[2]
		near.append([dx * dx + dy * dy + dz * dz, j])
	near.sort_custom(func(a, b): return a[0] < b[0])
	var out := PackedInt32Array()
	for q in mini(CORE, near.size()): out.append(int(near[q][1]))
	return out

## Galaxy i alone as particles about the origin, its stars where they are now.
func _galaxy_alone(i: int) -> GalLive:
	var c := orbits.pos.slice(3 * i, 3 * i + 3)
	var h: Array = haloes[i]
	var idx := PackedInt32Array()
	for j in n: if owner[j] == i: idx.append(j)
	var hp: PackedFloat64Array = h[0] if not h.is_empty() else PackedFloat64Array()
	var nh := hp.size() / 3
	var L := GalLive.new(idx.size() + nh, 0, LIVE_DT, THETA)
	L.use_native = use_native
	for q in idx.size():
		var j := idx[q]
		L.set_particle(q, [pos[3 * j] - c[0], pos[3 * j + 1] - c[1], pos[3 * j + 2] - c[2]], [0, 0, 0], star_mass[j], star_eps[j])
	for q in nh:
		L.set_particle(idx.size() + q, [hp[3 * q], hp[3 * q + 1], hp[3 * q + 2]], [0, 0, 0], float(h[2]), float(h[3]))
	return L

## Galaxy i's circular speed in its plane from its own particles, in rings of R_d / 4 out to
## 6 R_d: [ring radii, v_c] (kpc, kpc/Myr).
func live_rotation(i: int) -> Array:
	var L := _galaxy_alone(i)
	L.accelerate()
	var B: Basis = axes[i]
	var rd := float(discs[i].rd)
	var bins := 24
	var sum := PackedFloat64Array()
	var cnt := PackedFloat64Array()
	sum.resize(bins)
	cnt.resize(bins)
	var q := 0
	for j in n:
		if owner[j] != i: continue
		if tag[j] == i:
			var p := L.position(q)
			var e := p - B.y * p.dot(B.y)
			var R := e.length()
			var b := int(R / (0.25 * rd))
			if b < bins and R > 0.0:
				var a := Vector3(L.buf[GalLive.HDR + GalLive.STRIDE * q + GalLive.AX], L.buf[GalLive.HDR + GalLive.STRIDE * q + GalLive.AX + 1], L.buf[GalLive.HDR + GalLive.STRIDE * q + GalLive.AX + 2])
				sum[b] += -a.dot(e / R) * R
				cnt[b] += 1.0
		q += 1
	var rr := PackedFloat64Array()
	var vc := PackedFloat64Array()
	for b in bins:
		if cnt[b] < 20.0: continue
		rr.append((b + 0.5) * 0.25 * rd)
		vc.append(sqrt(maxf(sum[b] / cnt[b], 0.0)))
	return [rr, vc]

static func _interp(xs: PackedFloat64Array, ys: PackedFloat64Array, x: float) -> float:
	if xs.is_empty(): return 0.0
	if x <= xs[0]: return ys[0] * x / xs[0]
	for k in range(1, xs.size()):
		if x <= xs[k]: return lerpf(ys[k - 1], ys[k], (x - xs[k - 1]) / (xs[k] - xs[k - 1]))
	return ys[ys.size() - 1]

func _remap_disc(i: int) -> void:
	var rot := live_rotation(i)
	var xs: PackedFloat64Array = rot[0]
	var ys: PackedFloat64Array = rot[1]
	var live_vc := func(R: float) -> float: return _interp(xs, ys, R)
	var rigid_vc := func(R: float) -> float: return circular_speed(i, R)
	var B: Basis = axes[i]
	var c := orbits.pos.slice(3 * i, 3 * i + 3)
	var by := [B.y.x, B.y.y, B.y.z]
	for j in n:
		if tag[j] != i: continue
		var p := [pos[3 * j] - c[0], pos[3 * j + 1] - c[1], pos[3 * j + 2] - c[2]]
		var up: float = p[0] * by[0] + p[1] * by[1] + p[2] * by[2]
		var e := [p[0] - by[0] * up, p[1] - by[1] * up, p[2] - by[2] * up]
		var R := sqrt(e[0] * e[0] + e[1] * e[1] + e[2] * e[2])
		if R <= 0.0: continue
		var e_t := [(by[1] * e[2] - by[2] * e[1]) / R, (by[2] * e[0] - by[0] * e[2]) / R, (by[0] * e[1] - by[1] * e[0]) / R]
		var dv := float(disc_kinematics(i, R, live_vc)[0]) - float(disc_kinematics(i, R, rigid_vc)[0])
		for k in 3: vel[3 * j + k] += e_t[k] * dv

## The kernel's buffer: [0] length, [1] n, [2] k, [3] dt, [4] galaxies, G_STRIDE per galaxy, the
## mid-step centres (k × galaxies × 3), positions, velocities.
func pack(k: int, mids: PackedFloat64Array) -> PackedFloat64Array:
	var ng := orbits.count()
	var b := PackedFloat64Array([0.0, float(n), float(k), DT, float(ng)])
	for i in ng:
		var P: Array = params[i] if i < params.size() and not (params[i] as Array).is_empty() else [0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0]
		var B: Basis = axes[i] if i < axes.size() else Basis()
		b.append_array([P[0], P[1], P[2], P[3], P[4], P[5], P[6], B.x.x, B.x.y, B.x.z, B.y.x, B.y.y, B.y.z, B.z.x, B.z.y, B.z.z])
	b.append_array(mids)
	b.append_array(pos)
	b.append_array(vel)
	b.append_array(_draw_block())
	b[0] = float(b.size())
	return b

## 2n doubles holding each star's float32 (x, y, z, tag): the kernel writes x, y, z and keeps
## the tag, which never changes.
func _draw_block() -> PackedFloat64Array:
	if _tag_block.size() != 2 * n:
		var f := PackedFloat32Array()
		f.resize(4 * n)
		for i in n: f[4 * i + 3] = float(tag[i])
		_tag_block = f.to_byte_array().to_float64_array()
	return _tag_block

func _step_gd(k: int, mids: PackedFloat64Array) -> void:
	var ng := orbits.count()
	var h := DT * 0.5
	var acc := PackedFloat64Array([0.0, 0.0, 0.0])
	for i in n:
		var c := i * 3
		var x := pos[c]
		var y := pos[c + 1]
		var z := pos[c + 2]
		var vx := vel[c]
		var vy := vel[c + 1]
		var vz := vel[c + 2]
		for s in k:
			x += vx * h
			y += vy * h
			z += vz * h
			acc[0] = 0.0
			acc[1] = 0.0
			acc[2] = 0.0
			for g in ng:
				if g >= params.size() or (params[g] as Array).is_empty(): continue
				var m := (s * ng + g) * 3
				_accel(g, x, y, z, mids[m], mids[m + 1], mids[m + 2], acc)
			vx += acc[0] * DT
			vy += acc[1] * DT
			vz += acc[2] * DT
			x += vx * h
			y += vy * h
			z += vz * h
		pos[c] = x
		pos[c + 1] = y
		pos[c + 2] = z
		vel[c] = vx
		vel[c + 1] = vy
		vel[c + 2] = vz
