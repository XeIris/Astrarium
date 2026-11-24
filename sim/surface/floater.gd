class_name Floater
extends RefCounted

# A rigid body on a sea, in the site's frame (x west, y up, z north), SI, doubles, a fixed 1/120 s step.
# Its hulls are closed triangle meshes; the water presses on each triangle below the surface with the
# hydrostatic pressure, integrated exactly as the linear field it is on the triangle, so a still sea gives
# Archimedes' force and the righting moment of the hull's real shape. Drag and wind work per triangle on the
# velocity relative to the water and the air. The water is OceanField's physics cascades, read on a lattice of
# probes about the hull at 1/10 s and linear between. It reads the sea and writes nothing back.
# docs/physics/ocean.md#what-floats.

const DT := 1.0 / 120.0
## Probes about the hull, a side, and their spacing, m: waves shorter than about twice it are smoothed out.
const PROBES := 5
const PROBE_STEP := 1.5
## How often the probes are refreshed from the field, s.
const SNAP := 0.1
## Pressure drag on a face moving into the liquid, and on one moving out of it, where the flow separates and
## pulls less: estimates for blunt panels.
const CD_PUSH := 1.0
const CD_PULL := 0.3
## Air on a panel facing the wind: a flat plate's.
const CD_AIR := 1.1

## A body bobbing at ω sends waves away at their phase speed g/ω, and a panel pushing at u_n meets the
## pressure ρ(g/ω)u_n, fading as e^{−kd} with depth (k = ω²/g): the waves it makes carry its motion off.
## 0 leaves it out. docs/physics/ocean.md#what-floats.
var radiation_omega := 0.0

var g := 9.81
var rho := 1025.0
var nu := 1.05e-6
var rho_air := 1.225
var mass := 1.0
## Inertia tensor in the body frame about the centre of mass, row-major, kg·m².
var inertia := PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1])
var _inv_inertia := PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1])
## Hulls: {verts: PackedFloat64Array (body frame, about the centre of mass), tris: PackedInt32Array, scale}.
## A hull at scale 0 is not there (an uninflated bag).
var hulls: Array = []
## State: the centre of mass, its velocity, the body-to-site rotation (row-major) and the angular velocity.
var p := PackedFloat64Array([0, 0, 0])
var v := PackedFloat64Array([0, 0, 0])
var rot := PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1])
var w := PackedFloat64Array([0, 0, 0])
var t := 0.0
## Wind at the site, m/s, site frame.
var wind := PackedFloat64Array([0, 0, 0])
## A parachute on a body-frame point, while attached: {at: PackedFloat64Array(3), area, cd}.
var chute = null
var field: OceanField = null
## What the last step measured: whether any of the hull is wet, the submerged volume and the force, N.
var wet := false
var displaced := 0.0
var last_force := PackedFloat64Array([0, 0, 0])
var peak_accel := 0.0

var _probe_t := PackedFloat64Array([-INF, -INF])
var _probe_x0 := 0.0
var _probe_z0 := 0.0
var _probe_h: Array[PackedFloat64Array] = [PackedFloat64Array(), PackedFloat64Array()]
var _probe_d: Array[PackedFloat64Array] = [PackedFloat64Array(), PackedFloat64Array()]
var _acc := 0.0

func _init(gravity: float, liquid: Dictionary, air_density: float) -> void:
	g = gravity
	rho = float(liquid.rho)
	nu = float(liquid.nu)
	rho_air = air_density
	for k in 2:
		_probe_h[k].resize(PROBES * PROBES)
		_probe_d[k].resize(PROBES * PROBES * 2)

func set_inertia(m: float, tensor: PackedFloat64Array) -> void:
	mass = m
	inertia = tensor
	_inv_inertia = _invert3(tensor)

## Run the body on to time `to`, s on the site's clock, in fixed steps.
func advance(to: float) -> void:
	while t + DT <= to + 1e-9:
		_step()

## Water height and its horizontal and vertical velocity at a site point, now: [h, ux, uy, uz].
func water(x: float, z: float) -> PackedFloat64Array:
	if field == null: return PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	_refresh_probes()
	var f := clampf((t - _probe_t[0]) / SNAP, 0.0, 1.0)
	var u := clampf((x - _probe_x0) / PROBE_STEP, 0.0, PROBES - 1.001)
	var q := clampf((z - _probe_z0) / PROBE_STEP, 0.0, PROBES - 1.001)
	var i := int(u); var j := int(q)
	var fu := u - i; var fq := q - j
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for k in 2:
		var wk := f if k == 1 else 1.0 - f
		var hh := _probe_h[k]
		var a := j * PROBES + i
		var b := a + PROBES
		out[0] += wk * ((hh[a] * (1.0 - fu) + hh[a + 1] * fu) * (1.0 - fq) + (hh[b] * (1.0 - fu) + hh[b + 1] * fu) * fq)
	# Velocities from the probes' change over the interval: the surface's own motion.
	var hd := _probe_h[1]; var h0_ := _probe_h[0]
	var a2 := j * PROBES + i
	var dh := ((hd[a2] - h0_[a2]) * (1.0 - fu) + (hd[a2 + 1] - h0_[a2 + 1]) * fu) / SNAP
	var dd0 := _probe_d[0]; var dd1 := _probe_d[1]
	out[1] = (dd1[a2 * 2] - dd0[a2 * 2]) / SNAP
	out[3] = (dd1[a2 * 2 + 1] - dd0[a2 * 2 + 1]) / SNAP
	out[2] = dh
	return out

func _refresh_probes() -> void:
	if t < _probe_t[1] and _probe_t[0] > -INF: return
	var t0 := floorf(t / SNAP) * SNAP
	# Centred where the body is, on a lattice of its own so a drifting body does not resample every snap.
	var cx := snappedf(p[0], PROBE_STEP) - PROBE_STEP * (PROBES - 1) * 0.5
	var cz := snappedf(p[2], PROBE_STEP) - PROBE_STEP * (PROBES - 1) * 0.5
	var reuse := _probe_t[1] == t0 and cx == _probe_x0 and cz == _probe_z0
	_probe_x0 = cx; _probe_z0 = cz
	if reuse:
		_probe_h[0] = _probe_h[1].duplicate(); _probe_d[0] = _probe_d[1].duplicate()
	else:
		_sample(t0, 0)
	_sample(t0 + SNAP, 1)
	_probe_t[0] = t0; _probe_t[1] = t0 + SNAP

func _sample(at: float, k: int) -> void:
	field.snapshot(at)
	for j in PROBES:
		for i in PROBES:
			var x := _probe_x0 + i * PROBE_STEP
			var z := _probe_z0 + j * PROBE_STEP
			var idx := j * PROBES + i
			_probe_h[k][idx] = field.height_at(x, z)
			var d := field.displacement(x, z)
			_probe_d[k][idx * 2] = d.x
			_probe_d[k][idx * 2 + 1] = d.z

## Force and torque about the centre of mass from the liquid and the air on every hull, site frame:
## [fx, fy, fz, tx, ty, tz]. `still` reads a flat, still sea at height 0 (the hydrostatics checks).
func loads(still := false) -> PackedFloat64Array:
	var out := PackedFloat64Array([0, 0, 0, 0, 0, 0])
	displaced = 0.0
	wet = false
	var pg := rho * g
	for hull in hulls:
		var sc := float(hull.scale)
		if sc <= 0.0: continue
		var bv: PackedFloat64Array = hull.verts
		var tris: PackedInt32Array = hull.tris
		var nv := bv.size() / 3
		# Each vertex in the site frame, relative to the centre of mass, and its depth under the surface.
		var rel := PackedFloat64Array(); rel.resize(nv * 3)
		var depth := PackedFloat64Array(); depth.resize(nv)
		var uw := PackedFloat64Array(); uw.resize(nv * 3)
		for i in nv:
			var bx := bv[i * 3] * sc + float(hull.get("ox", 0.0))
			var by := bv[i * 3 + 1] * sc + float(hull.get("oy", 0.0))
			var bz := bv[i * 3 + 2] * sc + float(hull.get("oz", 0.0))
			var rx := rot[0] * bx + rot[1] * by + rot[2] * bz
			var ry := rot[3] * bx + rot[4] * by + rot[5] * bz
			var rz := rot[6] * bx + rot[7] * by + rot[8] * bz
			rel[i * 3] = rx; rel[i * 3 + 1] = ry; rel[i * 3 + 2] = rz
			var wa := PackedFloat64Array([0.0, 0.0, 0.0, 0.0]) if still else water(p[0] + rx, p[2] + rz)
			depth[i] = wa[0] - (p[1] + ry)
			uw[i * 3] = wa[1]; uw[i * 3 + 1] = wa[2]; uw[i * 3 + 2] = wa[3]
		for tr in tris.size() / 3:
			var ia := tris[tr * 3]; var ib := tris[tr * 3 + 1]; var ic := tris[tr * 3 + 2]
			var pieces := _clip(rel, depth, ia, ib, ic)
			for piece in pieces:
				_panel(piece, pg, out, uw, ia, still)
			if not still:
				_air(rel, depth, ia, ib, ic, out)
	if chute != null and not still:
		_chute(out)
	return out

# The parts of a triangle under the surface, as triangles of [x, y, z, depth] corners (relative to the centre of
# mass), cut where the depth along each edge is zero.
func _clip(rel: PackedFloat64Array, depth: PackedFloat64Array, ia: int, ib: int, ic: int) -> Array:
	var corners := [ia, ib, ic]
	var wet_n := 0
	for i: int in corners: if depth[i] > 0.0: wet_n += 1
	if wet_n == 0: return []
	if wet_n == 3: return [[_pt(rel, depth, ia), _pt(rel, depth, ib), _pt(rel, depth, ic)]]
	# Rotate the corners so the odd one out comes first, keeping the winding.
	for r in 3:
		var a: int = corners[r]; var b: int = corners[(r + 1) % 3]; var c: int = corners[(r + 2) % 3]
		var a_wet := depth[a] > 0.0
		if wet_n == 1 and a_wet:
			return [[_pt(rel, depth, a), _cut(rel, depth, a, b), _cut(rel, depth, a, c)]]
		if wet_n == 2 and not a_wet:
			var ab := _cut(rel, depth, a, b)
			var ac := _cut(rel, depth, a, c)
			return [[ab, _pt(rel, depth, b), _pt(rel, depth, c)], [ab, _pt(rel, depth, c), ac]]
	return []

static func _pt(rel: PackedFloat64Array, depth: PackedFloat64Array, i: int) -> PackedFloat64Array:
	return PackedFloat64Array([rel[i * 3], rel[i * 3 + 1], rel[i * 3 + 2], depth[i]])

static func _cut(rel: PackedFloat64Array, depth: PackedFloat64Array, a: int, b: int) -> PackedFloat64Array:
	var s := depth[a] / (depth[a] - depth[b])
	return PackedFloat64Array([rel[a * 3] + s * (rel[b * 3] - rel[a * 3]), rel[a * 3 + 1] + s * (rel[b * 3 + 1] - rel[a * 3 + 1]),
		rel[a * 3 + 2] + s * (rel[b * 3 + 2] - rel[a * 3 + 2]), 0.0])

# Pressure, drag and skin friction on one wetted triangle.
func _panel(q: Array, pg: float, out: PackedFloat64Array, uw: PackedFloat64Array, ia: int, still: bool) -> void:
	var a: PackedFloat64Array = q[0]; var b: PackedFloat64Array = q[1]; var c: PackedFloat64Array = q[2]
	var e1x := b[0] - a[0]; var e1y := b[1] - a[1]; var e1z := b[2] - a[2]
	var e2x := c[0] - a[0]; var e2y := c[1] - a[1]; var e2z := c[2] - a[2]
	# Twice the area times the outward normal.
	var nx := e1y * e2z - e1z * e2y
	var ny := e1z * e2x - e1x * e2z
	var nz := e1x * e2y - e1y * e2x
	var area2 := sqrt(nx * nx + ny * ny + nz * nz)
	if area2 <= 1e-14: return
	var area := 0.5 * area2
	var ux := nx / area2; var uy := ny / area2; var uz := nz / area2
	wet = true
	# Linear pressure p = ρg·depth over the triangle: the force is its mean, and ∫p r dA = A/12 (Σpᵢrᵢ + Σpᵢ Σrᵢ).
	var pa := pg * a[3]; var pb := pg * b[3]; var pc := pg * c[3]
	var psum := pa + pb + pc
	var fmag := area * psum / 3.0
	out[0] -= ux * fmag; out[1] -= uy * fmag; out[2] -= uz * fmag
	var k := area / 12.0
	var mx := k * (pa * a[0] + pb * b[0] + pc * c[0] + psum * (a[0] + b[0] + c[0]))
	var my := k * (pa * a[1] + pb * b[1] + pc * c[1] + psum * (a[1] + b[1] + c[1]))
	var mz := k * (pa * a[2] + pb * b[2] + pc * c[2] + psum * (a[2] + b[2] + c[2]))
	# τ = −(∫p r dA) × n̂.
	out[3] -= my * uz - mz * uy
	out[4] -= mz * ux - mx * uz
	out[5] -= mx * uy - my * ux
	# Volume under the surface, by the divergence theorem with F = (0, −depth, 0) over the wetted hull; the
	# waterline cap, at depth 0, adds nothing.
	displaced -= area * (a[3] + b[3] + c[3]) / 3.0 * uy
	if still: return
	# Drag on the panel's centroid velocity relative to the water.
	var cx := (a[0] + b[0] + c[0]) / 3.0; var cy := (a[1] + b[1] + c[1]) / 3.0; var cz := (a[2] + b[2] + c[2]) / 3.0
	var vx := v[0] + w[1] * cz - w[2] * cy - uw[ia * 3]
	var vy := v[1] + w[2] * cx - w[0] * cz - uw[ia * 3 + 1]
	var vz := v[2] + w[0] * cy - w[1] * cx - uw[ia * 3 + 2]
	var un := vx * ux + vy * uy + vz * uz
	var cd := CD_PUSH if un > 0.0 else CD_PULL
	var fd := -0.5 * rho * cd * area * un * absf(un)
	if radiation_omega > 0.0:
		var kr := radiation_omega * radiation_omega / g
		fd -= rho * g / radiation_omega * area * un * exp(-kr * (a[3] + b[3] + c[3]) / 3.0)
	var tx := vx - un * ux; var ty := vy - un * uy; var tz := vz - un * uz
	var ut := sqrt(tx * tx + ty * ty + tz * tz)
	# ITTC 1957 friction on a 4 m hull.
	var re := maxf(ut * 4.0 / nu, 1e5)
	var cf := 0.075 / pow(log(re) / log(10.0) - 2.0, 2.0)
	var ff := -0.5 * rho * cf * area * ut
	var fx := fd * ux + ff * tx; var fy := fd * uy + ff * ty; var fz := fd * uz + ff * tz
	_apply(out, fx, fy, fz, cx, cy, cz)

# Wind on a triangle above the surface, on the velocity relative to the air.
func _air(rel: PackedFloat64Array, depth: PackedFloat64Array, ia: int, ib: int, ic: int, out: PackedFloat64Array) -> void:
	if depth[ia] > 0.0 or depth[ib] > 0.0 or depth[ic] > 0.0: return
	var e1x := rel[ib * 3] - rel[ia * 3]; var e1y := rel[ib * 3 + 1] - rel[ia * 3 + 1]; var e1z := rel[ib * 3 + 2] - rel[ia * 3 + 2]
	var e2x := rel[ic * 3] - rel[ia * 3]; var e2y := rel[ic * 3 + 1] - rel[ia * 3 + 1]; var e2z := rel[ic * 3 + 2] - rel[ia * 3 + 2]
	var nx := e1y * e2z - e1z * e2y; var ny := e1z * e2x - e1x * e2z; var nz := e1x * e2y - e1y * e2x
	var area2 := sqrt(nx * nx + ny * ny + nz * nz)
	if area2 <= 1e-14: return
	var ux := nx / area2; var uy := ny / area2; var uz := nz / area2
	var cx := (rel[ia * 3] + rel[ib * 3] + rel[ic * 3]) / 3.0
	var cy := (rel[ia * 3 + 1] + rel[ib * 3 + 1] + rel[ic * 3 + 1]) / 3.0
	var cz := (rel[ia * 3 + 2] + rel[ib * 3 + 2] + rel[ic * 3 + 2]) / 3.0
	var vx := v[0] + w[1] * cz - w[2] * cy - wind[0]
	var vy := v[1] + w[2] * cx - w[0] * cz - wind[1]
	var vz := v[2] + w[0] * cy - w[1] * cx - wind[2]
	var un := vx * ux + vy * uy + vz * uz
	if un <= 0.0: return
	var fd := -0.5 * rho_air * CD_AIR * 0.5 * area2 * un * un
	_apply(out, fd * ux, fd * uy, fd * uz, cx, cy, cz)

# The canopy's drag on its riser point, along the air's velocity relative to that point.
func _chute(out: PackedFloat64Array) -> void:
	var at: PackedFloat64Array = chute.at
	var cx := rot[0] * at[0] + rot[1] * at[1] + rot[2] * at[2]
	var cy := rot[3] * at[0] + rot[4] * at[1] + rot[5] * at[2]
	var cz := rot[6] * at[0] + rot[7] * at[1] + rot[8] * at[2]
	var vx := v[0] + w[1] * cz - w[2] * cy - wind[0]
	var vy := v[1] + w[2] * cx - w[0] * cz - wind[1]
	var vz := v[2] + w[0] * cy - w[1] * cx - wind[2]
	var s := sqrt(vx * vx + vy * vy + vz * vz)
	var k := -0.5 * rho_air * float(chute.cd) * float(chute.area) * s
	_apply(out, k * vx, k * vy, k * vz, cx, cy, cz)

static func _apply(out: PackedFloat64Array, fx: float, fy: float, fz: float, cx: float, cy: float, cz: float) -> void:
	out[0] += fx; out[1] += fy; out[2] += fz
	out[3] += cy * fz - cz * fy
	out[4] += cz * fx - cx * fz
	out[5] += cx * fy - cy * fx

func _step() -> void:
	var f := loads()
	f[1] -= mass * g
	last_force = PackedFloat64Array([f[0], f[1], f[2]])
	var ax := f[0] / mass; var ay := f[1] / mass; var az := f[2] / mass
	peak_accel = maxf(peak_accel, sqrt(ax * ax + (ay + g) * (ay + g) + az * az))
	v[0] += ax * DT; v[1] += ay * DT; v[2] += az * DT
	p[0] += v[0] * DT; p[1] += v[1] * DT; p[2] += v[2] * DT
	# Euler's equations in the site frame: I = R I_b Rᵀ, dω/dt = I⁻¹(τ − ω × Iω).
	var iw := _world_apply(inertia, w)
	var gx := f[3] - (w[1] * iw[2] - w[2] * iw[1])
	var gy := f[4] - (w[2] * iw[0] - w[0] * iw[2])
	var gz := f[5] - (w[0] * iw[1] - w[1] * iw[0])
	var dw := _world_apply(_inv_inertia, PackedFloat64Array([gx, gy, gz]))
	w[0] += dw[0] * DT; w[1] += dw[1] * DT; w[2] += dw[2] * DT
	_rotate(DT)
	t += DT

# A world-frame vector through a body-frame tensor: R M Rᵀ x.
func _world_apply(m: PackedFloat64Array, x: PackedFloat64Array) -> PackedFloat64Array:
	var bx := rot[0] * x[0] + rot[3] * x[1] + rot[6] * x[2]
	var by := rot[1] * x[0] + rot[4] * x[1] + rot[7] * x[2]
	var bz := rot[2] * x[0] + rot[5] * x[1] + rot[8] * x[2]
	var mx := m[0] * bx + m[1] * by + m[2] * bz
	var my := m[3] * bx + m[4] * by + m[5] * bz
	var mz := m[6] * bx + m[7] * by + m[8] * bz
	return PackedFloat64Array([rot[0] * mx + rot[1] * my + rot[2] * mz, rot[3] * mx + rot[4] * my + rot[5] * mz,
		rot[6] * mx + rot[7] * my + rot[8] * mz])

# R ← exp([ω]× dt) R by Rodrigues, then re-orthonormalised.
func _rotate(dt: float) -> void:
	var ang := sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) * dt
	if ang < 1e-15: return
	var kx := w[0] * dt / ang; var ky := w[1] * dt / ang; var kz := w[2] * dt / ang
	var c := cos(ang); var s := sin(ang); var cc := 1.0 - c
	var m := PackedFloat64Array([c + kx * kx * cc, kx * ky * cc - kz * s, kx * kz * cc + ky * s,
		ky * kx * cc + kz * s, c + ky * ky * cc, ky * kz * cc - kx * s,
		kz * kx * cc - ky * s, kz * ky * cc + kx * s, c + kz * kz * cc])
	var r := PackedFloat64Array(); r.resize(9)
	for i in 3:
		for j in 3:
			r[i * 3 + j] = m[i * 3] * rot[j] + m[i * 3 + 1] * rot[3 + j] + m[i * 3 + 2] * rot[6 + j]
	rot = _orthonormal(r)

static func _orthonormal(r: PackedFloat64Array) -> PackedFloat64Array:
	# Columns are the body axes in the site frame.
	var ax := DVec3.new(r[0], r[3], r[6]).normalized()
	var bx := DVec3.new(r[1], r[4], r[7])
	bx.add_scaled_in(ax, -bx.dot(ax)).normalize_in()
	var cx := ax.cross(bx)
	return PackedFloat64Array([ax.x, bx.x, cx.x, ax.y, bx.y, cx.y, ax.z, bx.z, cx.z])

static func _invert3(m: PackedFloat64Array) -> PackedFloat64Array:
	var a := m[0]; var b := m[1]; var c := m[2]; var d := m[3]; var e := m[4]; var f := m[5]
	var gg := m[6]; var h := m[7]; var i := m[8]
	var det := a * (e * i - f * h) - b * (d * i - f * gg) + c * (d * h - e * gg)
	return PackedFloat64Array([(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
		(f * gg - d * i) / det, (a * i - c * gg) / det, (c * d - a * f) / det,
		(d * h - e * gg) / det, (b * gg - a * h) / det, (a * e - b * d) / det])

## The body's axis `b` (body frame unit vector) in the site frame.
func axis(bx: float, by: float, bz: float) -> Vector3:
	return Vector3(rot[0] * bx + rot[1] * by + rot[2] * bz, rot[3] * bx + rot[4] * by + rot[5] * bz,
		rot[6] * bx + rot[7] * by + rot[8] * bz)

## The pose for drawing: site-frame transform of the body frame.
func transform() -> Transform3D:
	return Transform3D(Basis(Vector3(rot[0], rot[3], rot[6]), Vector3(rot[1], rot[4], rot[7]), Vector3(rot[2], rot[5], rot[8])),
		Vector3(p[0], p[1], p[2]))

## Set the attitude from a body-to-site Basis.
func set_basis(bs: Basis) -> void:
	rot = _orthonormal(PackedFloat64Array([bs.x.x, bs.y.x, bs.z.x, bs.x.y, bs.y.y, bs.z.y, bs.x.z, bs.y.z, bs.z.z]))

## Volume of a closed hull, m³, by the divergence theorem.
static func volume(verts: PackedFloat64Array, tris: PackedInt32Array) -> float:
	var vol := 0.0
	for tr in tris.size() / 3:
		var a := tris[tr * 3] * 3; var b := tris[tr * 3 + 1] * 3; var c := tris[tr * 3 + 2] * 3
		vol += (verts[a] * (verts[b + 1] * verts[c + 2] - verts[b + 2] * verts[c + 1])
			- verts[a + 1] * (verts[b] * verts[c + 2] - verts[b + 2] * verts[c])
			+ verts[a + 2] * (verts[b] * verts[c + 1] - verts[b + 1] * verts[c])) / 6.0
	return vol
