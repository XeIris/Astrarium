class_name Neighbours
extends RefCounted

# One frame's bodies, indexed for the per-body searches over every other body: the
# strongest tidal pull, the discs that can eclipse a star and the brightest planetshine.
# A full scan of each is N² per frame. A search here tests the few heaviest candidates,
# then walks outward through slabs along the widest axis, and within each slab along
# the next, stopping once no body farther out could beat or tie the best so far. Each
# stopping bound is computed in the same rounded arithmetic as the value it bounds, so
# for finite positions the answer is the full scan's, ties going to the earlier body.
# Valid while no position, mass, radius or membership changes: rebuild after one.

## Candidates tested directly, largest weight first, so the bound on the rest is tight.
const HEAVY := 8
const NOT_OCCLUDING := ["star", "bh", "neutron", "white-dwarf"]
const SHINING := ["planet", "world", "gas-giant"]
## pow and the Lambert phase can each round an ulp above their exact bound.
const SHINE_SLACK := 1.0 + 1e-9

enum Kind { TIDE, OCCLUDE, SHINE }

var bodies: Array
var _n := 0
var _x := PackedFloat64Array()
var _y := PackedFloat64Array()
var _z := PackedFloat64Array()
var _mass := PackedFloat64Array()
var _radius := PackedFloat64Array()
var _eligible := {}                    # Kind → PackedByteArray
var _index := {}                       # Body → position in `bodies`
var _axes := Vector2i(0, 2)            # the widest axis, which cuts the slabs, and the next
var _slab_lo := PackedFloat64Array()   # each slab's extent along the first axis
var _slab_hi := PackedFloat64Array()
var _slab_v: Array = []                # per slab, its bodies' second-axis coordinates, ascending
var _slab_j: Array = []                # and the body at each
var _heavy := {}                       # Kind → [PackedInt32Array, PackedByteArray light flags, light max]
# Planetshine from one star: each neighbour's A·2/3 and its unit vector to the star.
var _shine_star: Body = null
var _k := PackedFloat64Array()
var _sx := PackedFloat64Array()
var _sy := PackedFloat64Array()
var _sz := PackedFloat64Array()
var _k_max := 0.0

func _init(p_bodies: Array) -> void:
	bodies = p_bodies
	_n = bodies.size()
	_x.resize(_n); _y.resize(_n); _z.resize(_n); _mass.resize(_n); _radius.resize(_n)
	var tide := PackedByteArray(); tide.resize(_n)
	var occlude := PackedByteArray(); occlude.resize(_n)
	var shine := PackedByteArray(); shine.resize(_n)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var finite := PackedInt32Array()
	for i in _n:
		var b: Body = bodies[i]
		_index[b] = i
		_x[i] = b.pos.x; _y[i] = b.pos.y; _z[i] = b.pos.z
		_mass[i] = b.mass; _radius[i] = b.radius
		tide[i] = 1 if b.alive else 0
		occlude[i] = 1 if b.alive and not b.radius <= 0.0 and not b.type in NOT_OCCLUDING else 0
		shine[i] = 1 if b.alive and not b.radius <= 0.0 and b.type in SHINING else 0
		if b.pos.is_finite_v():
			finite.append(i)
			lo = Vector3(minf(lo.x, b.pos.x), minf(lo.y, b.pos.y), minf(lo.z, b.pos.z))
			hi = Vector3(maxf(hi.x, b.pos.x), maxf(hi.y, b.pos.y), maxf(hi.z, b.pos.z))
	_eligible = {Kind.TIDE: tide, Kind.OCCLUDE: occlude, Kind.SHINE: shine}
	# The widest axes spread the bodies furthest, so a search stops soonest along them.
	var span := hi - lo
	var by_span := [0, 1, 2]
	by_span.sort_custom(func(a, c): return span[a] > span[c])
	_axes = Vector2i(by_span[0], by_span[1])
	var coord := [_x, _y, _z]
	var cu: PackedFloat64Array = coord[_axes.x]
	var cv: PackedFloat64Array = coord[_axes.y]
	var keyed := []
	for i in finite: keyed.append([cu[i], i])
	keyed.sort()
	var per_slab := maxi(8, ceili(sqrt(float(keyed.size()))))
	for start in range(0, keyed.size(), per_slab):
		var stop := mini(start + per_slab, keyed.size())
		_slab_lo.append(keyed[start][0])
		_slab_hi.append(keyed[stop - 1][0])
		var members := []
		for s in range(start, stop): members.append([cv[keyed[s][1]], keyed[s][1]])
		members.sort()
		var vs := PackedFloat64Array(); var js := PackedInt32Array()
		for e in members:
			vs.append(e[0]); js.append(e[1])
		_slab_v.append(vs); _slab_j.append(js)

## The body pulling `b` hardest by M/d³, the tidal test's primary; null if none does.
func strongest_pull(b: Body) -> Body:
	var top := _search(Kind.TIDE, b, 1, INF)
	return bodies[top[0][0]] if not top[0].is_empty() else null

## Up to `count` bodies nearer to `b` than `limit` (AU) that could cover a star, the
## largest angular radius R/d first.
func occluders(b: Body, limit: float, count: int) -> Array:
	var out := []
	for j in _search(Kind.OCCLUDE, b, count, limit)[0]: out.append(bodies[j])
	return out

## The neighbour lighting `b` most by planetshine from `star` (Suns.shine_fraction) and
## that fraction: [Body, f], or [null, 0.0].
func shine(b: Body, star: Body) -> Array:
	if star != _shine_star: _prepare_shine(star)
	var top := _search(Kind.SHINE, b, 1, INF)
	return [bodies[top[0][0]], top[1][0]] if not top[0].is_empty() else [null, 0.0]

func _prepare_shine(star: Body) -> void:
	_shine_star = star
	_k.resize(_n); _sx.resize(_n); _sy.resize(_n); _sz.resize(_n)
	_k_max = 0.0
	var shining: PackedByteArray = _eligible[Kind.SHINE]
	for j in _n:
		if shining[j] == 0: continue
		var b: Body = bodies[j]
		_k[j] = Suns.shine_albedo(b) * 2.0 / 3.0
		_k_max = _larger(_k_max, _k[j])
		var to_star := star.pos.sub(b.pos).normalize_in()
		_sx[j] = to_star.x; _sy[j] = to_star.y; _sz[j] = to_star.z

# The `count` best candidates of `kind` for `b`: [indices, values], best first.
func _search(kind: int, b: Body, count: int, limit: float) -> Array:
	var i: int = _index.get(b, -1)
	var rx := b.pos.x; var ry := b.pos.y; var rz := b.pos.z
	var top_j := PackedInt32Array()
	var top_v := PackedFloat64Array()
	# A planetshine or a tide must be positive to count; any eclipsing disc counts.
	var floor_v := -INF if kind == Kind.OCCLUDE else 0.0
	if not b.pos.is_finite_v():
		var ok: PackedByteArray = _eligible[kind]
		for j in _n:
			if j != i and ok[j] == 1: _offer(top_j, top_v, count, floor_v, j, _value(kind, j, rx, ry, rz, limit))
		return [top_j, top_v]
	var heavy: Array = _heavy_of(kind)
	var light: PackedByteArray = heavy[1]
	var light_max: float = heavy[2]
	for j in heavy[0]:
		if j != i: _offer(top_j, top_v, count, floor_v, j, _value(kind, j, rx, ry, rz, limit))
	var full := top_j.size() == count
	var thr := top_v[count - 1] if full else floor_v
	var r := [rx, ry, rz]
	var ru: float = r[_axes.x]
	var rv: float = r[_axes.y]
	# Slabs in order of their gap along the first axis, then each slab's bodies in order
	# of their offset along the second. fl(gap² + dv²) is at most the rounded d² of every
	# body beyond, whichever axes these are, so a bound taken there holds for all of them.
	var right := _slab_hi.bsearch(ru)
	var left := right - 1
	var slabs := _slab_lo.size()
	while left >= 0 or right < slabs:
		var gap_l := ru - _slab_hi[left] if left >= 0 else INF
		var gap_r := maxf(_slab_lo[right] - ru, 0.0) if right < slabs else INF
		var k: int
		var gap: float
		if gap_l <= gap_r:
			k = left; gap = gap_l; left -= 1
		else:
			k = right; gap = gap_r; right += 1
		var gap2 := gap * gap
		var bound := _bound(kind, gap2, light_max, limit)
		if bound < thr or (bound == thr and not full): break
		var vs: PackedFloat64Array = _slab_v[k]
		var js: PackedInt32Array = _slab_j[k]
		var up := vs.bsearch(rv)
		var down := up - 1
		var m := vs.size()
		while down >= 0 or up < m:
			var s: int
			if up >= m or (down >= 0 and rv - vs[down] <= vs[up] - rv):
				s = down; down -= 1
			else:
				s = up; up += 1
			var dv := vs[s] - rv
			bound = _bound(kind, gap2 + dv * dv, light_max, limit)
			if bound < thr or (bound == thr and not full): break
			var j := js[s]
			if light[j] == 0 or j == i: continue
			var v := _value(kind, j, rx, ry, rz, limit)
			if v > thr or (full and v == thr and j < top_j[count - 1]):
				_offer(top_j, top_v, count, floor_v, j, v)
				full = top_j.size() == count
				thr = top_v[count - 1] if full else floor_v
	return [top_j, top_v]

# The value the full scan compares; NAN when j is not a candidate for this receiver.
func _value(kind: int, j: int, rx: float, ry: float, rz: float, limit: float) -> float:
	match kind:
		Kind.TIDE:
			var dx := rx - _x[j]; var dy := ry - _y[j]; var dz := rz - _z[j]
			var d2 := dx * dx + dy * dy + dz * dz
			return _mass[j] / (d2 * sqrt(d2)) if d2 > 0.0 else NAN
		Kind.OCCLUDE:
			var dx := _x[j] - rx; var dy := _y[j] - ry; var dz := _z[j] - rz
			var d := sqrt(dx * dx + dy * dy + dz * dz)
			return _radius[j] / maxf(d, 1e-12) if not d >= limit else NAN
		_:
			# Neighbour → receiver, normalised as DVec3.normalized() does.
			var tx := (_x[j] - rx) * -1.0; var ty := (_y[j] - ry) * -1.0; var tz := (_z[j] - rz) * -1.0
			var d := sqrt(tx * tx + ty * ty + tz * tz)
			if d > 0.0:
				tx /= d; ty /= d; tz /= d
			return Suns.shine_fraction(_k[j], _radius[j], d, tx * _sx[j] + ty * _sy[j] + tz * _sz[j])

# The most any light candidate at a rounded squared distance of at least `d2` can score;
# −INF past an occluder's `limit`. Each value's operations are monotonic in d², weight.
func _bound(kind: int, d2: float, light_max: float, limit: float) -> float:
	match kind:
		Kind.TIDE: return light_max / (d2 * sqrt(d2))
		Kind.OCCLUDE: return light_max / maxf(sqrt(d2), 1e-12) if sqrt(d2) < limit else -INF
		_: return _k_max * pow(light_max / maxf(sqrt(d2), 1e-12), 2.0) * SHINE_SLACK

# Keep the `count` best, ordered by value and then by body order, as a full scan that
# replaces only on a strictly larger value finds them.
static func _offer(top_j: PackedInt32Array, top_v: PackedFloat64Array, count: int, floor_v: float, j: int, v: float) -> void:
	if not v > floor_v: return
	var at := top_j.size()
	if at == count:
		if not (v > top_v[at - 1] or (v == top_v[at - 1] and j < top_j[at - 1])): return
		at -= 1
		top_j.remove_at(at); top_v.remove_at(at)
	while at > 0 and (v > top_v[at - 1] or (v == top_v[at - 1] and j < top_j[at - 1])): at -= 1
	top_j.insert(at, j); top_v.insert(at, v)

# Up to HEAVY of the largest candidates of `kind` by its weight (mass for a tide, radius
# for a disc or a shine), each heavier than every other candidate; the others' flags; the
# largest weight among those. NaN weighs most.
func _heavy_of(kind: int) -> Array:
	if _heavy.has(kind): return _heavy[kind]
	var weight := _mass if kind == Kind.TIDE else _radius
	var ok: PackedByteArray = _eligible[kind]
	var top_j := PackedInt32Array()
	var top_v := PackedFloat64Array()
	for j in _n:
		if ok[j] == 1:
			var w := weight[j]
			_offer(top_j, top_v, HEAVY, -INF, j, INF if is_nan(w) else w)
	var light := ok.duplicate()
	for j in top_j: light[j] = 0
	var light_max := 0.0
	for j in _n:
		if light[j] == 1: light_max = _larger(light_max, weight[j])
	# One no heavier than the rest only costs a test: it tightens no bound.
	while not top_j.is_empty() and top_v[-1] <= light_max:
		light[top_j[-1]] = 1
		top_j.remove_at(top_j.size() - 1); top_v.remove_at(top_v.size() - 1)
	_heavy[kind] = [top_j, light, light_max]
	return _heavy[kind]

# max that keeps a NaN, so a bound built on it never stops a search.
static func _larger(a: float, b: float) -> float:
	return NAN if is_nan(a) or is_nan(b) else maxf(a, b)
