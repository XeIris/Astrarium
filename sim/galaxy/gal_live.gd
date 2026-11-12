class_name GalLive
extends RefCounted

# Live galaxies: every particle (halo, bulge and disc) pulls on every other through a
# Barnes–Hut octree (Barnes & Hut 1986) of monopole cells, with Plummer softening, stepped
# kick–drift–kick at a fixed DT. This is what a merger needs and a rigid potential cannot
# give: the discs' own gravity and the haloes taking up the orbit's energy. The native kernel
# (run_live in native/astrarium_native.c) is the twin and must stay bit-identical: same tree,
# same traversal order, only sqrt. Units kpc, Myr, 10¹⁰ M☉. docs/physics/galaxies.md#live.

const HDR := 10
const STRIDE := 12
const LEAF := 8
const DEPTH := 48
const GROUP := 32

## Header slots.
const H_LEN := 0
const H_N := 1
const H_K := 2
const H_DT := 3
const H_THETA := 4
const H_G := 5
const H_ACC := 6
const H_PHI := 7
const H_NL := 8
const H_THREADS := 9

## Particle slots.
const X := 0
const VX := 3
const AX := 6
const M := 9
const EPS := 10
const PHI := 11

var n := 0
## The first nl particles are drawn (discs and bulges); haloes follow.
var nl := 0
var buf := PackedFloat64Array()
var steps := 0
var t := 0.0
var use_native := true
## The native kernel could not allocate a step's tree: the run stopped there, and steps
## no further.
var failed := false
## Threads for the native kernel: 0 for every core.
var threads := 0
## Each luminous particle's float32 (x, y, z, tag), 16 bytes, for the drawing.
var draw_bytes := PackedByteArray()
var _tags := PackedFloat64Array()

static var _native := -1

## n particles, the first nl drawn; dt Myr, θ the opening angle.
func _init(count: int, luminous: int, dt: float, theta: float) -> void:
	n = count
	nl = luminous
	buf.resize(HDR + STRIDE * n + 2 * nl)
	buf[H_N] = float(n)
	buf[H_DT] = dt
	buf[H_THETA] = theta
	buf[H_G] = GalUnits.G
	buf[H_NL] = float(nl)
	buf[H_LEN] = float(buf.size())

func dt() -> float:
	return buf[H_DT]

## Particle i: position (kpc), velocity (kpc/Myr), mass (10¹⁰ M☉), softening (kpc), and for a
## drawn particle the tag the drawing reads.
func set_particle(i: int, p: Array, v: Array, m: float, eps: float, tag := 0.0) -> void:
	var o := HDR + STRIDE * i
	for c in 3:
		buf[o + X + c] = float(p[c])
		buf[o + VX + c] = float(v[c])
	assert(eps > 0.0, "a live particle needs a softening: it meets itself at zero separation")
	buf[o + M] = m
	buf[o + EPS] = eps
	buf[H_ACC] = 0.0
	if i < nl:
		if _tags.size() != nl: _tags.resize(nl)
		_tags[i] = tag

func position(i: int) -> Vector3:
	var o := HDR + STRIDE * i
	return Vector3(buf[o], buf[o + 1], buf[o + 2])

func velocity(i: int) -> Vector3:
	var o := HDR + STRIDE * i
	return Vector3(buf[o + 3], buf[o + 4], buf[o + 5])

func mass(i: int) -> float:
	return buf[HDR + STRIDE * i + M]

static func native_available() -> bool:
	if _native < 0:
		_native = 1 if ClassDB.class_exists("NBodyKernel") and ClassDB.class_has_method("NBodyKernel", "live") else 0
	return _native == 1

## k steps of DT.
func step(k: int) -> void:
	if k <= 0 or n == 0 or failed: return
	var done := _run(k, false)
	steps += done
	t += done * dt()

## Accelerations now, without stepping.
func accelerate() -> void:
	buf[H_ACC] = 0.0
	_run(0, false)

## Kinetic and potential energy now (10¹⁰ M☉ kpc² Myr⁻²), from one force pass.
func energy() -> Array:
	_run(0, true)
	var kin := 0.0
	var pot := 0.0
	for i in n:
		var o := HDR + STRIDE * i
		var m := buf[o + M]
		kin += 0.5 * m * (buf[o + 3] * buf[o + 3] + buf[o + 4] * buf[o + 4] + buf[o + 5] * buf[o + 5])
		pot += 0.5 * m * buf[o + PHI]
	return [kin, pot]

## Returns the steps taken: k, or fewer when the native kernel failed.
func _run(k: int, phi: bool) -> int:
	buf[H_K] = float(k)
	buf[H_PHI] = 1.0 if phi else 0.0
	buf[H_THREADS] = float(threads)
	if phi: buf[H_ACC] = 0.0
	_fill_tags()
	if use_native and GalLive.native_available():
		buf = ClassDB.class_call_static("NBodyKernel", "live", buf)
		var o := HDR + STRIDE * n
		draw_bytes = buf.slice(o, o + 2 * nl).to_byte_array()
		if buf[H_THREADS] < 0.0:
			failed = true
			push_error("GalLive: the native kernel could not allocate its tree after %d of %d steps; the run stops" % [int(buf[H_K]), k])
			return int(buf[H_K])
	else:
		_run_gd(k, phi)
		var f := PackedFloat32Array()
		f.resize(4 * nl)
		for i in nl:
			var o := HDR + STRIDE * i
			f[4 * i] = buf[o]
			f[4 * i + 1] = buf[o + 1]
			f[4 * i + 2] = buf[o + 2]
			f[4 * i + 3] = _tags[i] if i < _tags.size() else 0.0
		draw_bytes = f.to_byte_array()
	return k

## The draw block's tags, written once: the kernel writes only x, y, z.
var _tags_written := false
func _fill_tags() -> void:
	if _tags_written: return
	_tags_written = true
	var f := PackedFloat32Array()
	f.resize(4 * nl)
	for i in nl: f[4 * i + 3] = _tags[i] if i < _tags.size() else 0.0
	var d := f.to_byte_array().to_float64_array()
	var o := HDR + STRIDE * n
	for c in d.size(): buf[o + c] = d[c]

# The GDScript kernel, the C one's twin.

var _nm := PackedFloat64Array()
var _nsx := PackedFloat64Array()
var _nsy := PackedFloat64Array()
var _nsz := PackedFloat64Array()
var _ncx := PackedFloat64Array()
var _ncy := PackedFloat64Array()
var _ncz := PackedFloat64Array()
var _nro2 := PackedFloat64Array()
var _neps := PackedFloat64Array()
var _nfirst := PackedInt32Array()
var _ncount := PackedInt32Array()
var _nlo := PackedInt32Array()
var _nhi := PackedInt32Array()
var _nn := 0
var _idx := PackedInt32Array()
var _tmp := PackedInt32Array()
var _theta := 0.6

func _new_node() -> int:
	if _nn == _nm.size():
		var cap := maxi(1024, 2 * _nm.size())
		# Packed arrays are values: each is resized by name.
		_nm.resize(cap); _nsx.resize(cap); _nsy.resize(cap); _nsz.resize(cap); _ncx.resize(cap)
		_ncy.resize(cap); _ncz.resize(cap); _nro2.resize(cap); _neps.resize(cap)
		_nfirst.resize(cap); _ncount.resize(cap); _nlo.resize(cap); _nhi.resize(cap)
	_nfirst[_nn] = 0
	_ncount[_nn] = 0
	_nn += 1
	return _nn - 1

func _octant(j: int, x0: float, y0: float, z0: float) -> int:
	var o := HDR + STRIDE * j
	return (1 if buf[o] >= x0 else 0) | (2 if buf[o + 1] >= y0 else 0) | (4 if buf[o + 2] >= z0 else 0)

func _fill(nd: int, lo: int, hi: int, x0: float, y0: float, z0: float, half: float, depth: int) -> void:
	var m := 0.0
	var sx := 0.0
	var sy := 0.0
	var sz := 0.0
	var eps := 0.0
	_nlo[nd] = lo
	_nhi[nd] = hi
	if hi - lo <= LEAF or depth >= DEPTH:
		for q in range(lo, hi):
			var o := HDR + STRIDE * _idx[q]
			var mj := buf[o + M]
			m += mj
			sx += mj * buf[o]
			sy += mj * buf[o + 1]
			sz += mj * buf[o + 2]
			if buf[o + EPS] > eps: eps = buf[o + EPS]
	else:
		var cnt := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0])
		var off := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0])
		for q in range(lo, hi): cnt[_octant(_idx[q], x0, y0, z0)] += 1
		var o := lo
		var kids := 0
		for c in 8:
			off[c] = o
			o += cnt[c]
			if cnt[c] > 0: kids += 1
		for q in range(lo, hi):
			var j := _idx[q]
			var c := _octant(j, x0, y0, z0)
			_tmp[off[c]] = j
			off[c] += 1
		for q in range(lo, hi): _idx[q] = _tmp[q]
		var first := _nn
		for c in kids: _new_node()
		_nfirst[nd] = first
		_ncount[nd] = kids
		var h := 0.5 * half
		var k := 0
		var a := lo
		for c in 8:
			if cnt[c] == 0: continue
			_fill(first + k, a, a + cnt[c], x0 + (h if c & 1 else -h), y0 + (h if c & 2 else -h), z0 + (h if c & 4 else -h), h, depth + 1)
			a += cnt[c]
			k += 1
		for c in kids:
			var ch := first + c
			m += _nm[ch]
			sx += _nsx[ch]
			sy += _nsy[ch]
			sz += _nsz[ch]
			if _neps[ch] > eps: eps = _neps[ch]
	_nm[nd] = m
	_nsx[nd] = sx
	_nsy[nd] = sy
	_nsz[nd] = sz
	_neps[nd] = eps
	_ncx[nd] = sx / m
	_ncy[nd] = sy / m
	_ncz[nd] = sz / m
	var dx := _ncx[nd] - x0
	var dy := _ncy[nd] - y0
	var dz := _ncz[nd] - z0
	var ropen := 2.0 * half / _theta + sqrt(dx * dx + dy * dy + dz * dz)
	_nro2[nd] = ropen * ropen

func _build() -> void:
	_theta = buf[H_THETA]
	_nn = 0
	_idx.resize(n)
	_tmp.resize(n)
	var lo := [buf[HDR], buf[HDR + 1], buf[HDR + 2]]
	var hi := [buf[HDR], buf[HDR + 1], buf[HDR + 2]]
	for i in n:
		_idx[i] = i
		for c in 3:
			var v := buf[HDR + STRIDE * i + c]
			if v < lo[c]: lo[c] = v
			if v > hi[c]: hi[c] = v
	var half := 0.0
	for c in 3:
		if 0.5 * (float(hi[c]) - float(lo[c])) > half: half = 0.5 * (float(hi[c]) - float(lo[c]))
	if half <= 0.0: half = 1.0
	var root := _new_node()
	_fill(root, 0, n, 0.5 * (float(lo[0]) + float(hi[0])), 0.5 * (float(lo[1]) + float(hi[1])), 0.5 * (float(lo[2]) + float(hi[2])), half, 0)

## The groups: the highest nodes holding at most GROUP particles, in tree order. Each walks
## the tree once for all its particles (Barnes 1990).
func _groups(nd: int, out: PackedInt32Array) -> void:
	if _nhi[nd] - _nlo[nd] <= GROUP or _ncount[nd] == 0:
		out.append(nd)
		return
	for c in _ncount[nd]: _groups(_nfirst[nd] + c, out)

static func _gap(c: float, lo: float, hi: float) -> float:
	return lo - c if c < lo else (c - hi if c > hi else 0.0)

## Group g's interaction list, gathered into _lx.._lj: a cell is taken whole when the group's
## bounding box lies outside its opening sphere; _lj is the particle (−1 for a cell).
func _list(g: int) -> int:
	var o0 := HDR + STRIDE * _idx[_nlo[g]]
	var lx := buf[o0]
	var ly := buf[o0 + 1]
	var lz := buf[o0 + 2]
	var hx := lx
	var hy := ly
	var hz := lz
	for q in range(_nlo[g], _nhi[g]):
		var o := HDR + STRIDE * _idx[q]
		if buf[o] < lx: lx = buf[o]
		if buf[o] > hx: hx = buf[o]
		if buf[o + 1] < ly: ly = buf[o + 1]
		if buf[o + 1] > hy: hy = buf[o + 1]
		if buf[o + 2] < lz: lz = buf[o + 2]
		if buf[o + 2] > hz: hz = buf[o + 2]
	var stack := PackedInt32Array([0])
	var length := 0
	while stack.size() > 0:
		var nd := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		var gx := _gap(_ncx[nd], lx, hx)
		var gy := _gap(_ncy[nd], ly, hy)
		var gz := _gap(_ncz[nd], lz, hz)
		if gx * gx + gy * gy + gz * gz > _nro2[nd]:
			length = _push(length, _ncx[nd], _ncy[nd], _ncz[nd], _nm[nd], _neps[nd], -1)
		elif _ncount[nd] == 0:
			for q in range(_nlo[nd], _nhi[nd]):
				var j := _idx[q]
				var o := HDR + STRIDE * j
				length = _push(length, buf[o], buf[o + 1], buf[o + 2], buf[o + M], buf[o + EPS], j)
		else:
			var c := _ncount[nd] - 1
			while c >= 0:
				stack.append(_nfirst[nd] + c)
				c -= 1
	return length

var _lx := PackedFloat64Array()
var _ly := PackedFloat64Array()
var _lz := PackedFloat64Array()
var _lm := PackedFloat64Array()
var _le := PackedFloat64Array()
var _lj := PackedInt32Array()

func _push(length: int, x: float, y: float, z: float, m: float, e: float, j: int) -> int:
	if length == _lx.size():
		var cap := maxi(4096, 2 * length)
		_lx.resize(cap); _ly.resize(cap); _lz.resize(cap); _lm.resize(cap); _le.resize(cap); _lj.resize(cap)
	_lx[length] = x
	_ly[length] = y
	_lz[length] = z
	_lm[length] = m
	_le[length] = e
	_lj[length] = j
	return length + 1

## Every particle of group g against its list, the list outermost as the C kernel has it. A
## particle meets itself at zero separation, softened, and gains exactly nothing; only the
## potential skips it.
func _group(g: int, length: int, grav: float, phi_on: bool) -> void:
	var b := _nlo[g]
	while b < _nhi[g]:
		var k := mini(_nhi[g] - b, GROUP)
		var x := PackedFloat64Array(); x.resize(k)
		var y := PackedFloat64Array(); y.resize(k)
		var z := PackedFloat64Array(); z.resize(k)
		var e := PackedFloat64Array(); e.resize(k)
		var ax := PackedFloat64Array(); ax.resize(k)
		var ay := PackedFloat64Array(); ay.resize(k)
		var az := PackedFloat64Array(); az.resize(k)
		var phi := PackedFloat64Array(); phi.resize(k)
		var id := PackedInt32Array(); id.resize(k)
		for a in k:
			id[a] = _idx[b + a]
			var o := HDR + STRIDE * id[a]
			x[a] = buf[o]
			y[a] = buf[o + 1]
			z[a] = buf[o + 2]
			e[a] = buf[o + EPS]
		for q in length:
			var cx := _lx[q]
			var cy := _ly[q]
			var cz := _lz[q]
			var gm := grav * _lm[q]
			var eq := _le[q]
			for a in k:
				var s := e[a] if e[a] > eq else eq
				var dx := cx - x[a]
				var dy := cy - y[a]
				var dz := cz - z[a]
				var r2 := dx * dx + dy * dy + dz * dz + s * s
				var r := sqrt(r2)
				var f := gm / (r2 * r)
				ax[a] += f * dx
				ay[a] += f * dy
				az[a] += f * dz
			if phi_on:
				for a in k:
					if _lj[q] == id[a]: continue
					var s := e[a] if e[a] > eq else eq
					var dx := cx - x[a]
					var dy := cy - y[a]
					var dz := cz - z[a]
					phi[a] -= gm / sqrt(dx * dx + dy * dy + dz * dz + s * s)
		for a in k:
			var o := HDR + STRIDE * id[a]
			buf[o + AX] = ax[a]
			buf[o + AX + 1] = ay[a]
			buf[o + AX + 2] = az[a]
			if phi_on: buf[o + PHI] = phi[a]
		b += GROUP

func _forces(phi_on: bool) -> void:
	_build()
	var grav := buf[H_G]
	var groups := PackedInt32Array()
	_groups(0, groups)
	for nd in groups: _group(nd, _list(nd), grav, phi_on)

func _run_gd(k: int, phi_on: bool) -> void:
	var step_dt := buf[H_DT]
	var h := 0.5 * step_dt
	if buf[H_ACC] == 0.0:
		_forces(phi_on)
		buf[H_ACC] = 1.0
	for s in k:
		for i in n:
			var o := HDR + STRIDE * i
			for c in 3: buf[o + VX + c] += buf[o + AX + c] * h
			for c in 3: buf[o + c] += buf[o + VX + c] * step_dt
		_forces(phi_on)
		for i in n:
			var o := HDR + STRIDE * i
			for c in 3: buf[o + VX + c] += buf[o + AX + c] * h
	buf[H_THREADS] = 1.0
