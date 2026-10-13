class_name ShuttleLines
extends RefCounted
# The Space Shuttle's procedural build: orbiter, external tank and boosters from the
# program's own inch stations. model_sources/blender/shuttle.py is the authored
# build from the same tables; docs/physics/shuttle-geometry.md gives the sources.
# Stage frames: +Y along the stack, the orbiter's top (+Zo) on +Z, +Yo on +X.

const IN := 0.0254
const XO_NOSE := 236.0
const XO_BAY0 := 582.0
const XO_BAY1 := 1307.0
const XO_BASE := 1528.3

## Xo, belly Zo, top Zo, half-width, where the side turns into the roof, chine
## radius, roof superellipse exponent, black/white tile boundary height.
const FUS := [
	[236.0, 335.6, 336.4, 0.4, 336.0, 0.4, 2.0, 999.0],
	[238.0, 327.0, 343.0, 9.0, 334.5, 7.5, 2.0, 999.0],
	[241.0, 320.0, 349.0, 14.0, 334.0, 12.0, 2.0, 999.0],
	[245.0, 313.5, 353.0, 19.0, 334.0, 17.0, 2.0, 999.0],
	[250.0, 308.5, 358.0, 24.0, 334.0, 21.0, 2.0, 999.0],
	[256.0, 304.0, 364.0, 29.0, 335.0, 25.0, 2.0, 999.0],
	[265.0, 300.0, 372.0, 34.0, 337.0, 29.0, 2.0, 380.0],
	[275.0, 296.0, 379.0, 39.0, 339.0, 32.0, 2.05, 375.0],
	[290.0, 291.5, 389.0, 46.0, 342.0, 35.0, 2.1, 370.0],
	[310.0, 288.0, 397.0, 53.0, 346.0, 37.0, 2.15, 365.0],
	[335.0, 283.5, 405.0, 62.0, 350.0, 37.0, 2.2, 358.0],
	[360.0, 281.0, 414.0, 69.0, 355.0, 35.0, 2.2, 352.0],
	[385.0, 279.5, 422.0, 75.0, 360.0, 33.0, 2.2, 346.0],
	[410.0, 278.5, 431.5, 80.5, 366.0, 30.0, 2.2, 340.0],
	[435.0, 277.5, 444.0, 84.8, 372.0, 28.0, 2.25, 335.0],
	[460.0, 276.5, 463.0, 88.7, 380.0, 26.0, 2.3, 330.0],
	[485.0, 275.5, 481.0, 92.8, 388.0, 24.0, 2.35, 325.0],
	[510.0, 274.5, 491.5, 96.5, 396.0, 22.0, 2.4, 320.0],
	[540.0, 273.5, 494.5, 100.0, 404.0, 20.0, 2.3, 316.0],
	[582.0, 272.0, 496.0, 102.0, 410.0, 18.0, 2.1, 312.0],
	[700.0, 267.5, 496.5, 102.0, 410.0, 18.0, 2.1, 308.0],
	[850.0, 264.0, 497.5, 102.0, 410.0, 18.0, 2.1, 306.0],
	[1000.0, 261.0, 498.5, 102.0, 410.0, 18.0, 2.1, 305.0],
	[1150.0, 259.2, 500.0, 102.0, 410.0, 17.0, 2.1, 305.0],
	[1307.0, 259.5, 501.0, 102.0, 410.0, 16.0, 2.1, 305.0],
	[1340.0, 260.0, 503.0, 107.0, 411.0, 15.0, 1.8, 304.0],
	[1400.0, 263.5, 510.0, 118.0, 412.0, 14.0, 1.45, 302.0],
	[1460.0, 268.0, 518.0, 126.0, 412.0, 12.0, 1.3, 300.0],
	[1500.0, 272.0, 522.0, 129.5, 411.0, 12.0, 1.3, 298.0],
	[1528.3, 275.6, 525.0, 131.0, 410.0, 12.0, 1.3, 296.0],
]
## BL, leading- and trailing-edge Xo, thickness (in), thickest chord fraction, chord
## line height at the leading and trailing edge.
const WING := [
	[95.0, 505.0, 1508.0, 66.0, 0.49, 296.0, 280.0],
	[110.0, 607.7, 1505.4, 65.0, 0.46, 294.5, 282.0],
	[140.0, 813.2, 1500.1, 62.0, 0.42, 291.5, 284.0],
	[165.0, 990.0, 1495.6, 57.0, 0.40, 290.0, 286.0],
	[190.0, 1025.7, 1491.2, 53.0, 0.40, 291.5, 289.5],
	[300.0, 1135.7, 1471.7, 39.0, 0.40, 298.2, 296.2],
	[420.0, 1255.7, 1450.4, 23.2, 0.40, 305.6, 303.6],
	[455.0, 1293.0, 1444.2, 18.0, 0.40, 307.8, 305.8],
	[466.0, 1312.0, 1442.2, 13.0, 0.42, 308.5, 306.5],
	[468.34, 1335.0, 1441.8, 5.0, 0.45, 308.6, 306.6],
]
const LOWER := 0.30
## OMS pod: Xo, half-width, half-height, centre Zo; centred Yo ±100.
const POD := [
	[1233.0, 1.0, 1.0, 472.0], [1240.0, 12.0, 13.0, 472.5], [1255.0, 23.0, 25.0, 474.0],
	[1280.0, 32.0, 35.0, 476.0], [1320.0, 39.5, 44.0, 478.0], [1370.0, 44.0, 50.0, 479.5],
	[1420.0, 46.5, 53.0, 480.5], [1450.0, 47.25, 54.0, 481.0], [1493.0, 46.5, 54.5, 481.5],
	[1530.0, 45.0, 53.5, 481.5], [1560.0, 43.5, 52.0, 481.5],
]
## SSME gimbal centres (Xo, Yo, Zo) and cant (pitch-up, outboard yaw), degrees.
const SSME := [[1445.0, 0.0, 443.0, 16.0, 0.0], [1468.17, -53.0, 342.64, 10.0, -3.5],
	[1468.17, 53.0, 342.64, 10.0, 3.5]]

static var _slopes := []

## A monotone cubic through the FUS columns (Fritsch–Carlson), so the lines are
## smooth between rows without overshooting them.
static func sec(xo: float) -> Dictionary:
	if _slopes.is_empty():
		for k in range(1, 8):
			var n := FUS.size()
			var d := []
			for i in n - 1: d.append((FUS[i + 1][k] - FUS[i][k]) / (FUS[i + 1][0] - FUS[i][0]))
			var m := [d[0]]
			for i in range(1, n - 1):
				if d[i - 1] * d[i] <= 0.0: m.append(0.0)
				else:
					var x0: float = FUS[i - 1][0]; var x1: float = FUS[i][0]; var x2: float = FUS[i + 1][0]
					m.append(3.0 * (x2 - x0) / ((2.0 * x2 - x1 - x0) / d[i - 1] + (x2 + x1 - 2.0 * x0) / d[i]))
			m.append(d[n - 2])
			_slopes.append(m)
	xo = clampf(xo, FUS[0][0], FUS[FUS.size() - 1][0])
	var i := 0
	while i < FUS.size() - 2 and FUS[i + 1][0] < xo: i += 1
	var h: float = FUS[i + 1][0] - FUS[i][0]
	var t: float = (xo - FUS[i][0]) / h
	var out := {"xo": xo}
	var keys := ["zb", "zt", "w", "zs", "rc", "nt", "zl"]
	for k in 7:
		var m: Array = _slopes[k]
		out[keys[k]] = (2 * t * t * t - 3 * t * t + 1) * FUS[i][k + 1] + (t * t * t - 2 * t * t + t) * h * m[i] \
			+ (-2 * t * t * t + 3 * t * t) * FUS[i + 1][k + 1] + (t * t * t - t * t) * h * m[i + 1]
	out.rc = minf(out.rc, minf(out.w, maxf(out.zs - out.zb, 0.0)))
	return out

## Right half of a section, belly centre to roof centre, as (yo, zo).
static func half_profile(c: Dictionary) -> PackedVector2Array:
	var w: float = c.w; var zb: float = c.zb; var zt: float = c.zt; var zs: float = c.zs
	var rc: float = c.rc; var nt: float = c.nt
	var p := PackedVector2Array([Vector2(0.0, zb)])
	if w - rc > 1e-3: p.append(Vector2(w - rc, zb))
	for i in range(1, 9):
		var a := -PI / 2.0 + (i / 8.0) * PI / 2.0
		p.append(Vector2(w - rc + rc * cos(a), zb + rc + rc * sin(a)))
	if zs > zb + rc + 1e-3: p.append(Vector2(w, zs))
	var e := 2.0 / nt
	for i in range(1, 49):
		var a := (i / 48.0) * PI / 2.0
		p.append(Vector2(w * pow(cos(a), e), zs + (zt - zs) * pow(sin(a), e)))
	return p

## One station's profile, evaluated by arc fraction s (0 belly centre, 1 roof
## centre, negative to port; past 1 it wraps over the roof onto the port side).
class Ring:
	var c: Dictionary
	var pts: PackedVector2Array
	var cum := PackedFloat32Array()
	var datum := 0.0
	func _init(xo: float, p_datum: float) -> void:
		c = ShuttleLines.sec(xo)
		pts = ShuttleLines.half_profile(c)
		datum = p_datum
		cum.append(0.0)
		for i in range(1, pts.size()): cum.append(cum[i - 1] + pts[i].distance_to(pts[i - 1]))
	func at(s: float) -> Vector3:
		if s > 1.0: s = -(2.0 - s)
		var sg := -1.0 if s < 0.0 else 1.0
		var d := minf(absf(s), 1.0) * cum[cum.size() - 1]
		var k := 0
		while k < cum.size() - 2 and cum[k + 1] < d: k += 1
		var t := (d - cum[k]) / maxf(cum[k + 1] - cum[k], 1e-9)
		var q := pts[k].lerp(pts[k + 1], t)
		return ShuttleLines.P(c.xo, sg * q.x, q.y, datum)
	func s_at_z(z: float) -> float:
		for k in pts.size() - 1:
			var z0 := pts[k].y; var z1 := pts[k + 1].y
			if (z0 - z) * (z1 - z) <= 0.0 and absf(z1 - z0) > 1e-9:
				return (cum[k] + (z - z0) / (z1 - z0) * (cum[k + 1] - cum[k])) / cum[cum.size() - 1]
		return 1.0 if z > pts[pts.size() - 1].y else 0.0

static func P(xo: float, yo: float, zo: float, datum: float) -> Vector3:
	return Vector3(yo * IN, (datum - xo) * IN, (zo - 400.0) * IN)

static func stations(x0: float, x1: float, step: float) -> Array:
	var n := maxi(int(round((x1 - x0) / step)), 1)
	var out := []
	for i in n + 1: out.append(x0 + (x1 - x0) * i / n)
	return out

## A quad mesh through rows of points, each face wound to agree with outward(centre).
static func grid(rows: Array, mat: Material, outward: Callable) -> MeshInstance3D:
	var g := CraftModel.Geo.new()
	var n: int = rows[0].size()
	for r in rows:
		for p in r: g.pos.append(p)
	for i in rows.size() - 1:
		for j in n - 1:
			var a := i * n + j; var b := a + 1; var c := a + n + 1; var d := a + n
			var ctr: Vector3 = (g.pos[a] + g.pos[b] + g.pos[c] + g.pos[d]) * 0.25
			var nrm: Vector3 = (g.pos[b] - g.pos[a]).cross(g.pos[d] - g.pos[a])
			if nrm.dot(outward.call(ctr)) >= 0.0: g.idx.append_array([a, b, c, a, c, d])
			else: g.idx.append_array([a, c, b, a, d, c])
	CraftModel._compute_normals(g)
	return CraftModel._mesh(g, mat)

## A flat fan from the rim's centroid, facing `out`.
static func fan(rim: Array, mat: Material, out: Vector3) -> MeshInstance3D:
	var ctr := Vector3.ZERO
	for p in rim: ctr += p
	ctr /= rim.size()
	var rows := []
	for p in rim: rows.append([ctr, p])
	return grid(rows, mat, func(_c): return out)

# THE ORBITER
static func build_orbiter(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var M := CraftModel.M
	var g := CraftModel._grp()
	var datum: float = XO_NOSE + float(spec.L) / IN
	var out := func(p: Vector3) -> Vector3:
		var c := sec(clampf(datum - p.y / IN, XO_NOSE, XO_BASE))
		var v := Vector3(p.x, 0.0, p.z - ((c.zb + c.zt) * 0.5 - 400.0) * IN)
		if datum - p.y / IN < XO_NOSE + 2.0: v.y = 1.0
		return v
	var band := func(xs: Array, fn: Callable, n: int, mat: Material) -> void:
		var rows := []
		for xo in xs:
			var r := Ring.new(xo, datum)
			var ss: Vector2 = fn.call(r)
			var row := []
			for j in n + 1: row.append(r.at(ss.x + (ss.y - ss.x) * j / n))
			rows.append(row)
		g.add_child(grid(rows, mat, out))
	var black := func(r: Ring) -> Vector2:
		var sl := r.s_at_z(r.c.zl)
		return Vector2(-sl, sl)
	var white := func(r: Ring) -> Vector2:
		var sl := r.s_at_z(r.c.zl)
		return Vector2(sl, 2.0 - sl)
	var fwd := stations(236.0, 262.0, 2.6)
	var fwd2 := stations(262.0, XO_BAY0, 16.0)
	var bay := stations(XO_BAY0, XO_BAY1, 72.5)
	var aft := stations(XO_BAY1, XO_BASE, 22.0)
	band.call(fwd, func(_r): return Vector2(-1.0, 1.0), 28, M.soot)      # RCC nose cap
	band.call(fwd2, black, 16, M.tiles)
	band.call(fwd2, white, 24, M.white)
	band.call(bay, black, 12, M.tiles)
	for sg in [1.0, -1.0]:
		var side := func(r: Ring) -> Vector2:
			var sl := r.s_at_z(r.c.zl); var sh := r.s_at_z(r.c.zs)
			return Vector2(sl, sh) if sg > 0.0 else Vector2(-sh, -sl)
		band.call(bay, side, 6, M.white)
	band.call(aft, black, 12, M.tiles)
	band.call(aft, white, 24, M.white)
	var rb := Ring.new(XO_BASE, datum)
	var rim := []
	for j in 37: rim.append(rb.at(-1.0 + 2.0 * j / 36.0))
	g.add_child(fan(rim, M.tiles, Vector3(0, -1, 0)))
	_windows(g, datum, out)
	_wing(g, datum)
	_tail(g, datum)
	_pods(g, datum)
	_engines(g, datum, parts)
	_body_flap(g, datum, parts)
	_bay(g, datum, parts, out)
	_gear(g, datum, parts)
	return {"group": g, "parts": parts}

## Pivot (Xo, Yo, Zo), strut, tyre diameter and width, in: nose gear under the cabin,
## mains in the wing roots. Built stowed (forward) and swung 90° down by the drive.
const GEAR := [[470.0, 0.0, 300.0, 124.0, 32.0, 9.0], [1180.0, -135.0, 295.0, 123.0, 44.5, 16.0],
	[1180.0, 135.0, 295.0, 123.0, 44.5, 16.0]]

static func _gear(g: Node3D, datum: float, parts: Dictionary) -> void:
	var M := CraftModel.M
	for e in GEAR:
		var mnt := CraftModel._grp()
		mnt.position = P(e[0], e[1], e[2], datum)
		mnt.basis = Basis(Vector3.UP, PI / 2.0)
		var node := CraftModel._grp()
		var inv := mnt.transform.affine_inverse()
		var axle := P(e[0] - e[3], e[1], e[2], datum)
		node.add_child(CraftModel.beam(inv * mnt.position, inv * axle, 5.0 * IN, M.steel, 10))
		for sd in [-1.0, 1.0]:
			var c0 := P(e[0] - e[3], e[1] + sd * 2.0, e[2], datum)
			var c1 := P(e[0] - e[3], e[1] + sd * (2.0 + e[5]), e[2], datum)
			node.add_child(CraftModel.beam(inv * c0, inv * c1, e[4] * 0.5 * IN, M.black, 16))
		mnt.add_child(node); g.add_child(mnt)
		parts.legs.append(node)

## A point on the roof at plan position (xo, yo).
static func roof_point(xo: float, yo: float, datum: float, off := 0.0) -> Vector3:
	var r := Ring.new(xo, datum)
	var c := r.c
	yo = clampf(yo, -c.w + 0.01, c.w - 0.01)
	var u := 1.0 - pow(absf(yo) / c.w, c.nt)
	var z: float = c.zs + (c.zt - c.zs) * pow(maxf(u, 0.0), 1.0 / c.nt)
	var s := r.s_at_z(z) * (1.0 if yo >= 0.0 else -1.0)
	var p := r.at(s)
	if off == 0.0: return p
	var a := Ring.new(xo + 0.6, datum).at(s) - Ring.new(xo - 0.6, datum).at(s)
	var b := r.at(s + 0.003) - r.at(s - 0.003)
	var n := a.cross(b).normalized()
	if n.dot(Vector3(p.x, 0.0, p.z)) < 0.0: n = -n
	return p + n * off * IN

## The six windscreen panes, one C-shaped band, and the two overhead windows.
static func _windows(g: Node3D, datum: float, out: Callable) -> void:
	var M := CraftModel.M
	var lo := func(yo: float) -> float: return 444.0 + 0.0098 * yo * yo
	var hi := func(yo: float) -> float: return 444.0 + 0.0098 * yo * yo + 27.0 - 0.10 * absf(yo)
	var patch := func(y0: float, y1: float, xl: Callable, xh: Callable, off: float, mat: Material, nv: int) -> void:
		var rows := []
		for i in 4:
			var row := []
			for j in nv + 1:
				var yo := y0 + (y1 - y0) * j / nv
				var x0: float = xl.call(yo); var x1: float = xh.call(yo)
				row.append(roof_point(x0 + (x1 - x0) * i / 3.0, yo, datum, off))
			rows.append(row)
		g.add_child(grid(rows, mat, out))
	patch.call(-82.0, 82.0, func(y): return lo.call(y) - 4.0, func(y): return hi.call(y) + 4.0, 0.35, M.tiles, 24)
	var edges := [0.0, 28.0, 54.0, 77.0]
	for sg in [1.0, -1.0]:
		for k in 3:
			var a: float = edges[k] + 1.5; var b: float = edges[k + 1] - 1.5
			patch.call(a if sg > 0.0 else -b, b if sg > 0.0 else -a, lo, hi, 0.9, M.glass, 3)
	patch.call(-31.0, 31.0, func(_y): return 520.0, func(_y): return 552.0, 0.35, M.tiles, 6)
	for yy in [[4.0, 27.0], [-27.0, -4.0]]:
		patch.call(yy[0], yy[1], func(_y): return 524.0, func(_y): return 548.0, 0.9, M.glass, 2)

static func _thick(u: float, um: float) -> float:
	var v := pow(clampf(u, 0.0, 1.0), log(0.3) / log(um))
	return (0.2969 * sqrt(v) - 0.1260 * v - 0.3516 * v * v + 0.2843 * v * v * v - 0.1015 * v * v * v * v) / 0.10002

static func wing_point(st: Array, u: float, side: float, sg: float, datum: float) -> Vector3:
	var xo: float = st[1] + (st[2] - st[1]) * u
	var zc: float = st[5] + (st[6] - st[5]) * u
	var t: float = st[3] * _thick(u, st[4])
	var zo := zc + (1.0 - LOWER) * t if side > 0.0 else zc - LOWER * t
	return P(xo, sg * st[0], zo, datum)

static func _cos_u(n: int, u0: float, u1: float) -> Array:
	var out := []
	for i in n + 1: out.append(u0 + (u1 - u0) * (1.0 - cos(PI * i / n)) / 2.0)
	return out

## The double delta: black tile underneath and along the upper leading edge, grey
## RCC on the main wing's leading edge, white above.
static func _wing(g: Node3D, datum: float) -> void:
	var M := CraftModel.M
	for sg in [1.0, -1.0]:
		var surf := func(sts: Array, u0: float, u1: float, side: float, mat: Material, n: int, up: Vector3) -> void:
			var rows := []
			for st in sts:
				var row := []
				for u in _cos_u(n, u0, u1): row.append(wing_point(st, u, side, sg, datum))
				rows.append(row)
			g.add_child(grid(rows, mat, func(_c): return up))
		surf.call(WING, 0.022, 0.075, 1.0, M.tiles, 3, Vector3.BACK)
		surf.call(WING, 0.075, 1.0, 1.0, M.white, 14, Vector3.BACK)
		surf.call(WING, 0.022, 1.0, -1.0, M.tiles, 16, Vector3.FORWARD)
		for part in [[WING.slice(0, 4), M.tiles], [WING.slice(3), M.soot]]:
			var rows := []
			for st in part[0]:
				var row := []
				for u in _cos_u(3, 0.022, 0.0): row.append(wing_point(st, u, -1.0, sg, datum))
				for u in _cos_u(3, 0.0, 0.022).slice(1): row.append(wing_point(st, u, 1.0, sg, datum))
				rows.append(row)
			g.add_child(grid(rows, part[1], func(_c): return Vector3.UP))

## The fin: 45° leading edge, root chord 268.5 in at WP 500, tip 108.47 at 815.72,
## a 10° wedge thickest at 60% chord.
static func _tail(g: Node3D, datum: float) -> void:
	var M := CraftModel.M
	var sect := func(zo: float) -> Vector2:
		return Vector2(1278.0 + (zo - 500.0), 268.5 + (108.47 - 268.5) * (zo - 500.0) / 315.72)
	var half := func(u: float, ch: float) -> float:
		var T := 0.105 * ch
		return T * 0.5 * pow(minf(u / 0.6, 1.0), 0.62) if u < 0.6 else T * 0.5 * maxf((1.0 - u) / 0.4, 0.0) + 0.15
	var us := _cos_u(14, 0.0, 1.0)
	var rows := []
	var cap := []
	for zo in [494.0, 500.0, 600.0, 700.0, 790.0, 815.72]:
		var sc: Vector2 = sect.call(zo)
		var ring := []
		for k in range(us.size() - 1, -1, -1): ring.append(P(sc.x + us[k] * sc.y, half.call(us[k], sc.y), zo, datum))
		for k in range(1, us.size()): ring.append(P(sc.x + us[k] * sc.y, -half.call(us[k], sc.y), zo, datum))
		rows.append(ring)
		cap = ring
	g.add_child(grid(rows, M.white, func(c: Vector3): return Vector3(c.x, 0.0, 0.0) if absf(c.x) > 1e-4 else Vector3.UP))
	g.add_child(fan(cap, M.white, Vector3.BACK))
	var hs := CraftModel._mesh(CraftModel._box(24.0 * IN, 70.0 * IN, 34.0 * IN), M.white)
	hs.position = P(1564.0, 0.0, 520.0, datum); g.add_child(hs)

## OMS pods on the aft fuselage's shoulders, with their engines at null position
## (15°49' up, 12°17' outboard).
static func _pods(g: Node3D, datum: float) -> void:
	var M := CraftModel.M
	var e := 2.0 / 2.3
	for sg in [1.0, -1.0]:
		var rows := []
		for r in POD:
			var row := []
			for j in 25:
				var a := TAU * j / 24.0
				var ca := cos(a); var sa := sin(a)
				row.append(P(r[0], sg * (100.0 + r[1] * signf(ca) * pow(absf(ca), e)), r[3] + r[2] * signf(sa) * pow(absf(sa), e), datum))
			rows.append(row)
		var ctr_x: float = sg * 100.0 * IN
		var outp := func(c: Vector3) -> Vector3: return Vector3(c.x - ctr_x, 0.0, c.z - 81.0 * IN)
		g.add_child(grid(rows.slice(0, 3), M.tiles, outp))
		g.add_child(grid(rows.slice(2), M.white, outp))
		var last: Array = rows[rows.size() - 1]
		g.add_child(fan(last, M.soot, Vector3.DOWN))
		var mnt := CraftModel._grp()
		mnt.position = P(1518.0, sg * 88.0, 492.0, datum)
		mnt.basis = Basis(Vector3.BACK, deg_to_rad(sg * 12.28)) * Basis(Vector3.RIGHT, deg_to_rad(-15.82))
		var b := CraftModel.bell(1.17, 55)
		b.position.y = -0.30
		mnt.add_child(b); g.add_child(mnt)

## The SSMEs on their gimbals (Xo 1445 / Zo 443, Xo 1468.17 / Yo ±53 / Zo 342.64),
## canted on fixed mounts so the pivots stay at identity; throat 0.95 m aft.
static func _engines(g: Node3D, datum: float, parts: Dictionary) -> void:
	var M := CraftModel.M
	var piv := []
	for e in SSME:
		var mnt := CraftModel._grp()
		mnt.position = P(e[0], e[1], e[2], datum)
		mnt.basis = Basis(Vector3.BACK, deg_to_rad(e[4])) * Basis(Vector3.RIGHT, deg_to_rad(-e[3]))
		var p := CraftModel._grp()
		var b := CraftModel.bell(2.30, 69)
		b.position.y = -0.95
		p.add_child(b)
		var mcc := CraftModel._mesh(CraftModel._cylinder(0.24, 0.30, 0.8, 14), M.hot)
		mcc.position.y = -0.55; p.add_child(mcc)
		mnt.add_child(p); g.add_child(mnt); piv.append(p)
	parts.gimbals = piv

## The body flap, Xo 1520 → 1613, 262 in wide, hinged at Xo 1532.3 / Zo 284.3 and
## driven about its span (the mount turns the node's Z onto X).
static func _body_flap(g: Node3D, datum: float, parts: Dictionary) -> void:
	var M := CraftModel.M
	var mnt := CraftModel._grp()
	mnt.position = P(1532.3, 0.0, 284.3, datum)
	mnt.basis = Basis(Vector3.UP, PI / 2.0)
	var node := CraftModel._grp()
	var inv := mnt.transform.affine_inverse()
	var xs := [1520.0, 1560.0, 1613.0]
	var tops := [296.0, 294.0, 288.0]
	var bots := [273.0, 275.0, 281.0]
	for pair in [[tops, Vector3.BACK], [bots, Vector3.FORWARD]]:
		var rows := []
		for i in 3:
			var row := []
			for yo in [-131.0, 0.0, 131.0]: row.append(inv * P(xs[i], yo, pair[0][i], datum))
			rows.append(row)
		var up: Vector3 = inv.basis * pair[1]
		node.add_child(grid(rows, M.tiles, func(_c): return up))
	for sg in [-1.0, 1.0]:
		var rows := []
		for i in 3: rows.append([inv * P(xs[i], sg * 131.0, tops[i], datum), inv * P(xs[i], sg * 131.0, bots[i], datum)])
		var side: Vector3 = inv.basis * Vector3(sg, 0, 0)
		node.add_child(grid(rows, M.tiles, func(_c): return side))
	mnt.add_child(node); g.add_child(mnt)
	parts.flaps.append(node)

## The payload bay: doors hinged at the sills (driven nodes, local Z on the hinge
## line), radiators inside them, the liner, the RMS, the docking system and a
## logistics module.
static func _bay(g: Node3D, datum: float, parts: Dictionary, out: Callable) -> void:
	var M := CraftModel.M
	var xs := stations(XO_BAY0 + 0.5, XO_BAY1 - 0.5, 72.5)
	for sg in [1.0, -1.0]:
		var mnt := CraftModel._grp()
		mnt.position = Vector3(sg * 102.0 * IN, 0.0, 10.0 * IN)
		mnt.basis = Basis(Vector3.RIGHT, -PI / 2.0 * sg)
		var node := CraftModel._grp()
		var inv := mnt.transform.affine_inverse()
		var outer := []
		var inner := []
		for xo in xs:
			var r := Ring.new(xo, datum)
			# The door laps a little over the sill, below its hinge line.
			var sh := r.s_at_z(r.c.zs) - 0.004
			var ro := []; var ri := []
			for j in 13:
				var s := sh + (0.9985 - sh) * j / 12.0
				var p := r.at(sg * s)
				ro.append(inv * p)
				var axis := Vector3(0.0, p.y, ((r.c.zb + r.c.zt) * 0.5 - 400.0) * IN)
				ri.append(inv * (p - (p - axis).normalized() * 2.0 * IN))
			outer.append(ro); inner.append(ri)
		var to_out := func(c: Vector3) -> Vector3:
			var w: Vector3 = mnt.transform * c
			return mnt.transform.basis.inverse() * out.call(w)
		node.add_child(grid(outer, M.white, to_out))
		node.add_child(grid(inner, M.alu, func(c): return -to_out.call(c)))
		mnt.add_child(node); g.add_child(mnt)
		parts.doors.append(node)
	for sg in [1.0, -1.0]:
		g.add_child(grid([[P(XO_BAY0, sg * 97.0, 300.0, datum), P(XO_BAY0, sg * 97.0, 409.0, datum)],
			[P(XO_BAY1, sg * 97.0, 300.0, datum), P(XO_BAY1, sg * 97.0, 409.0, datum)]], M.dirty, func(_c): return Vector3(-sg, 0, 0)))
	g.add_child(grid([[P(XO_BAY0, -97.0, 300.0, datum), P(XO_BAY0, 97.0, 300.0, datum)],
		[P(XO_BAY1, -97.0, 300.0, datum), P(XO_BAY1, 97.0, 300.0, datum)]], M.dirty, func(_c): return Vector3.BACK))
	# docking system and logistics module, both on the bay axis
	var ods := CraftModel._mesh(CraftModel._cylinder(0.8, 0.8, 3.6, 20), M.dirty)
	ods.rotation.x = PI / 2.0
	ods.position = P(650.0, 0.0, 300.0, datum) + Vector3(0, 0, 1.8); g.add_child(ods)
	var apas := CraftModel._mesh(CraftModel._cylinder(0.55, 0.62, 0.45, 20), M.alu)
	apas.rotation.x = PI / 2.0
	apas.position = P(650.0, 0.0, 300.0, datum) + Vector3(0, 0, 3.82); g.add_child(apas)
	var mp := CraftModel._mesh(CraftModel._cylinder(2.2, 2.2, 252.0 * IN, 28), M.white)
	mp.position = P(XO_BAY1 - 146.0, 0.0, 400.0, datum); g.add_child(mp)
	# the arm along the port sill: shoulder at Xo 679.5, 6.37 m and 7.06 m booms
	var sh := P(679.5, -88.0, 428.0, datum)
	var el := sh + Vector3(0, -6.37, 0); var wr := el + Vector3(0, -7.06, 0)
	g.add_child(CraftModel.beam(sh, el, 0.17, M.white, 12))
	g.add_child(CraftModel.beam(el, wr, 0.17, M.white, 12))
	g.add_child(CraftModel.beam(wr, wr + Vector3(0, -0.5, 0), 0.18, M.dirty, 12))
	for p in [sh, el, wr]:
		var j := CraftModel._mesh(CraftModel._box(0.45, 0.5, 0.45), M.black)
		j.position = p; g.add_child(j)

# THE EXTERNAL TANK: ogive to XT 745, LO2 barrel to 852.8, intertank to 1123, LH2
# barrel to 2058, aft dome to the datum. XT 322.5 is the nose.
static func build_et(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var M := CraftModel.M
	var g := CraftModel._grp()
	var R: float = float(spec.D) / 2.0 / IN
	var aft: float = 322.5 + float(spec.L) / IN
	var y := func(xt: float) -> float: return (aft - xt) * IN
	var L_og := 745.0 - 322.5
	var rho := (R * R + L_og * L_og) / (2.0 * R)
	var pts := PackedVector2Array()
	for i in 9:
		var a := (i / 8.0) * PI / 2.0
		pts.append(Vector2(R * sin(a) * IN, y.call(aft - (aft - 2058.0) * (1.0 - cos(a)))))
	pts.append(Vector2(R * IN, y.call(745.0)))
	for i in range(1, 15):
		var x := L_og * i / 14.0
		pts.append(Vector2(maxf(sqrt(maxf(rho * rho - x * x, 0.0)) - rho + R, 3.0) * IN, y.call(745.0 - x)))
	pts.append(Vector2(0.0, y.call(322.5)))
	g.add_child(CraftModel._mesh(CraftModel._lathe(pts, 40), M.foam))
	# the lightning rod on the nose cone
	g.add_child(CraftModel.beam(Vector3(0, y.call(322.5) - 0.05, 0), Vector3(0, y.call(322.5) + 0.9, 0), 0.025, M.alu))
	# intertank stringers and bands
	var it0 := 852.8; var it1 := 1123.0
	for i in 48:
		var a := i / 48.0 * TAU
		var rib := CraftModel._mesh(CraftModel._box(0.05, (it1 - it0) * IN * 0.98, 0.16), M.foam)
		rib.position = Vector3(cos(a) * (R * IN + 0.02), (y.call(it0) + y.call(it1)) / 2.0, sin(a) * (R * IN + 0.02))
		rib.rotation.y = -a; g.add_child(rib)
	for xt in [it0, it1]:
		var b := CraftModel._mesh(CraftModel._torus(R * IN * 1.012, 0.06, 6, 40), M.foam)
		b.rotation.x = PI / 2.0; b.position.y = y.call(xt); g.add_child(b)
	# LO2 feedline to port, pressurisation line to starboard, both toward the orbiter
	for l in [[deg_to_rad(-26.0), 0.24, R + 16.0], [deg_to_rad(30.0), 0.09, R + 6.0]]:
		var fl := CraftModel._mesh(CraftModel._cylinder(l[1], l[1], (2045.0 - 1110.0) * IN, 12), M.foam)
		fl.position = Vector3(sin(l[0]) * l[2] * IN, (y.call(1110.0) + y.call(2045.0)) / 2.0, cos(l[0]) * l[2] * IN)
		g.add_child(fl)
	# the bipod (orbiter's nose attach) and the aft umbilical plates
	var apex := Vector3(0.0, y.call(1119.0), (336.5 - 121.0) * IN)
	for sg in [-1.0, 1.0]:
		g.add_child(CraftModel.beam(Vector3(sg * 40.0 * IN, y.call(1132.0), sqrt(R * R - 1600.0) * IN), apex, 0.09, M.dirty))
		var u := CraftModel._mesh(CraftModel._box(0.75, 0.75, 0.66), M.dirty)
		u.position = Vector3(sg * 48.0 * IN, y.call(2058.0), (R + 13.0) * IN); g.add_child(u)
	g.add_child(CraftModel.beam(Vector3(-125.0 * IN, y.call(2058.0), (sqrt(R * R - 15625.0) + 4.0) * IN),
		Vector3(125.0 * IN, y.call(2058.0), (sqrt(R * R - 15625.0) + 4.0) * IN), 0.16, M.dirty))
	return {"group": g, "parts": parts}

# THE SOLID ROCKET BOOSTERS at Ys ±250.5: nose cap XB 200 → 326, frustum → 402,
# forward skirt → 532, case to 1819 (field joints XB 851.5, 1171.5, 1491.5; tank
# attach ring 1511), aft skirt flaring to 212 in. y = 0 is the nozzle exit.
static func build_srb(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var M := CraftModel.M
	var g := CraftModel._grp()
	var r: float = float(spec.D) / 2.0
	var exit: float = 200.0 + float(spec.L) / IN
	var y := func(xb: float) -> float: return (exit - xb) * IN
	var seg := func(r0: float, r1: float, xb0: float, xb1: float, mat: Material) -> MeshInstance3D:
		var m := CraftModel._mesh(CraftModel._cylinder(r1, r0, y.call(xb1) - y.call(xb0), 28, 1, true), mat)
		m.position.y = (y.call(xb0) + y.call(xb1)) / 2.0
		return m
	# Each booster is its own piece, nozzle included: they separate on their own paths.
	for side in [-1.0, 1.0]:
		var b := CraftModel._grp()
		b.name = "piece_srb_%d" % (0 if side < 0.0 else 1)
		b.position.x = side * 250.5 * IN
		b.add_child(seg.call(106.0 * IN, r, 1958.0, 1819.0, M.white))       # aft skirt
		b.add_child(seg.call(r, r, 1819.0, 532.0, M.white))                 # motor case
		for xb in [851.5, 1171.5, 1491.5]: b.add_child(seg.call(r * 1.012, r * 1.012, xb + 9.0, xb - 9.0, M.dirty))
		b.add_child(seg.call(r * 1.03, r * 1.03, 1517.0, 1505.0, M.dirty))  # tank attach ring
		b.add_child(seg.call(r, r, 532.0, 402.0, M.white))                  # forward skirt
		# The frustum and nose cap come off on the way down (Fall), so each is a node.
		var i := 0 if side < 0.0 else 1
		var fr := CraftModel._grp()
		fr.name = "frustum_srb_%d" % i
		fr.add_child(seg.call(r, 54.0 * IN, 402.0, 326.0, M.white))
		b.add_child(fr); parts.frustums.append(fr)
		var nc := CraftModel._grp()
		nc.name = "nosecap_srb_%d" % i
		var cap := CraftModel.ogive(y.call(200.0) - y.call(326.0), 108.0 * IN, M.white, 24)
		cap.position.y = y.call(326.0); nc.add_child(cap)
		b.add_child(nc); parts.nosecaps.append(nc)
		var tun := CraftModel._mesh(CraftModel._box(0.32, (1819.0 - 540.0) * IN, 0.22), M.dirty)
		tun.position = Vector3(side * r * 0.99, (y.call(540.0) + y.call(1819.0)) / 2.0, 0.0); b.add_child(tun)
		g.add_child(b); parts.pieces.append(b)
		# The nozzle hangs on a pivot (plumes parent to parts.gimbals); the RSRM
		# vectors 8°, and its throat sits up inside the case.
		var exd := CraftModel._n(spec.engine.get("exitD"), r * 2.0)
		var nzp := CraftModel._grp()
		nzp.position = Vector3(0.0, exd / 2.0 * 2.6, 0.0)
		nzp.set_meta("gimbal_deg", float(spec.engine.gimbal))
		nzp.add_child(CraftModel.bell(exd, 7.7, false))
		b.add_child(nzp); parts.gimbals.append(nzp)
	return {"group": g, "parts": parts}
