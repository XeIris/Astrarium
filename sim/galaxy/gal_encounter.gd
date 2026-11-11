class_name GalEncounter
extends RefCounted

# Galaxies meeting: their centres move as GalOrbits has them, and each galaxy's disc is massless
# stars in every galaxy's potential about its moving centre, a restricted N-body encounter as
# Toomre & Toomre (1972) drew tidal tails. Each potential is rigid: a Hernquist halo, a
# Miyamoto–Nagai disc about the galaxy's spin axis and a Hernquist bulge. Stars take drift–kick–
# drift steps of DT with the centres at mid-step. native/astrarium_native.c (run_encounter) is
# the C twin and must stay bit-identical: its forces use only sqrt, which every platform rounds
# the same. docs/physics/galaxies.md#encounters.

## Myr. The innermost disc stars, 1 kpc out in a 220 km/s disc, orbit in ~30 Myr: ~60 steps.
const DT := 0.5
## Per galaxy in the kernel: halo G M and a, disc G M, a, b, bulge G M and a, then its local
## axes x, y (the spin), z in the encounter's frame.
const G_STRIDE := 16

var orbits: GalOrbits
## Per galaxy: [halo gm, a, disc gm, a, b, bulge gm, a] and its axes (Basis, y the spin).
var params: Array = []
var axes: Array = []
## Stars: positions and velocities, 3 each (kpc, kpc/Myr), and which galaxy each began in.
var pos := PackedFloat64Array()
var vel := PackedFloat64Array()
var owner := PackedByteArray()
var n := 0
var steps := 0
## False forces the GDScript kernel (encountercheck compares the two).
var use_native := true
static var _native := -1

func _init(o: GalOrbits) -> void:
	orbits = o

## A galaxy's potential for its stars, for galaxy i of the orbits: the halo (M☉, kpc), the disc
## (M☉, a, b) and the bulge (M☉, a), spinning about `spin` (unit, the encounter's frame).
func set_galaxy(i: int, halo: Array, disc: Array, bulge: Array, spin: Vector3) -> void:
	while params.size() <= i:
		params.append([])
		axes.append(Basis())
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

## Galaxy i's disc as `count` stars: exponential in radius with scale rd out to 6 rd, sech² in
## height with z0, on circular orbits with a dispersion of `sigma_frac` of the circular speed
## in each direction (a cold disc: the tails Toomre & Toomre drew come from it).
func seed_disc(i: int, count: int, rd: float, z0: float, sigma_frac: float, seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var B: Basis = axes[i]
	var c := orbits.position(i)
	var v0 := orbits.velocity(i)
	for k in count:
		# Σ ∝ e^(−R/rd) gives R e^(−R/rd) dR: a Gamma(2) radius.
		var R := 6.0 * rd
		while R >= 6.0 * rd: R = -rd * log(maxf(rng.randf(), 1e-12) * maxf(rng.randf(), 1e-12))
		var phi := rng.randf() * TAU
		var z := z0 * atanh(2.0 * rng.randf() - 1.0)
		var e_r := B.x * cos(phi) + B.z * sin(phi)
		var e_t := B.y.cross(e_r)
		var vc := circular_speed(i, R)
		var s := sigma_frac * vc
		var p := c + e_r * R + B.y * z
		var v := v0 + e_t * vc + (e_r * rng.randfn() + e_t * rng.randfn() + B.y * rng.randfn()) * s
		pos.append_array([p.x, p.y, p.z])
		vel.append_array([v.x, v.y, v.z])
		owner.append(i)
		n += 1

static func native_available() -> bool:
	if _native < 0:
		_native = 1 if ClassDB.class_exists("NBodyKernel") and ClassDB.class_has_method("NBodyKernel", "encounter") else 0
	return _native == 1

## k steps of DT: the centres by GalOrbits (Runge–Kutta), then every star through them at
## mid-step.
func step(k: int) -> void:
	if k <= 0: return
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
	else:
		_step_gd(k, mids)
	steps += k

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
	b[0] = float(b.size())
	return b

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
