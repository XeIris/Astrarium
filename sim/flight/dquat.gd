class_name DQuat
extends RefCounted

# ============================================================================
# A DOUBLE-PRECISION QUATERNION, and the handful of THREE.Vector3 operations
# the flight model relies on BIT FOR BIT.
# ----------------------------------------------------------------------------
# The web build's attitude was a THREE.Quaternion — four JS doubles — and its
# vectors were THREE.Vector3s. Godot's Quaternion is float32, and DVec3 (the
# shared core/dvec3.gd) is double but was written for readability, not for
# reproducing three's exact operation order. Three places where "the same
# maths" is NOT the same arithmetic, and each one moves a trajectory in the
# last place, which a closed-loop guidance then amplifies:
#
#   · three's Vector3.normalize() is divideScalar(length || 1), and
#     divideScalar(s) is multiplyScalar(1/s) — a multiply by the reciprocal,
#     not three divisions. DVec3.normalize_in() divides. Use DQuat.nrm().
#   · setLength(l) is normalize() then multiplyScalar(l) — two roundings.
#   · angleTo() clamps dot/sqrt(|a|²|b|²) and takes acos; it is not
#     atan2(|a×b|, a·b), which is the better formula and a different number.
#
# So every flight module goes through these helpers, and they are written as
# transcriptions of three.js r160, operation for operation. The quaternion
# methods likewise (setFromUnitVectors normalises at the end; multiply is the
# euclideanspace formula; slerp has three's own two special cases).
#
# Precision matters less for attitude than for position — but attitude feeds
# the thrust direction, which feeds the trajectory, and the port is verified by
# flying the JS and the GDScript side by side and diffing them. Anything short
# of the same operations gives a diff that grows, and a diff that grows cannot
# tell a port error from a rounding one.
# ============================================================================

var x: float = 0.0
var y: float = 0.0
var z: float = 0.0
var w: float = 1.0

const EPSILON := 2.220446049250313e-16      # Number.EPSILON

func _init(px: float = 0.0, py: float = 0.0, pz: float = 0.0, pw: float = 1.0) -> void:
	x = px; y = py; z = pz; w = pw

func set_q(px: float, py: float, pz: float, pw: float) -> DQuat:
	x = px; y = py; z = pz; w = pw
	return self

func clone() -> DQuat:
	return DQuat.new(x, y, z, w)

func copy_from(q: DQuat) -> DQuat:
	x = q.x; y = q.y; z = q.z; w = q.w
	return self

func identity() -> DQuat:
	return set_q(0.0, 0.0, 0.0, 1.0)

## Down to Godot's float32 Quaternion — for the RENDER boundary only (a craft
## node's orientation). Attitude state stays here.
func to_quaternion() -> Quaternion:
	return Quaternion(x, y, z, w)

static func from_quaternion(q: Quaternion) -> DQuat:
	return DQuat.new(q.x, q.y, q.z, q.w)

## Quaternion.setFromAxisAngle — assumes a normalised axis.
func set_from_axis_angle(axis: DVec3, angle: float) -> DQuat:
	var half := angle / 2.0
	var s := sin(half)
	x = axis.x * s; y = axis.y * s; z = axis.z * s
	w = cos(half)
	return self

## Quaternion.setFromUnitVectors — assumes both are normalised.
func set_from_unit_vectors(v_from: DVec3, v_to: DVec3) -> DQuat:
	var r := v_from.dot(v_to) + 1.0
	if r < EPSILON:
		# v_from and v_to point in opposite directions
		r = 0.0
		if absf(v_from.x) > absf(v_from.z):
			x = -v_from.y; y = v_from.x; z = 0.0; w = r
		else:
			x = 0.0; y = -v_from.z; z = v_from.y; w = r
	else:
		x = v_from.y * v_to.z - v_from.z * v_to.y
		y = v_from.z * v_to.x - v_from.x * v_to.z
		z = v_from.x * v_to.y - v_from.y * v_to.x
		w = r
	return normalize_in()

## Quaternion.setFromRotationMatrix, from three basis columns (unscaled).
## Columns are (m11,m21,m31), (m12,m22,m32), (m13,m23,m33) — THREE's makeBasis
## order — so the render layer can build the local-frame rotation it used.
func set_from_basis_columns(c0: DVec3, c1: DVec3, c2: DVec3) -> DQuat:
	var m11 := c0.x; var m12 := c1.x; var m13 := c2.x
	var m21 := c0.y; var m22 := c1.y; var m23 := c2.y
	var m31 := c0.z; var m32 := c1.z; var m33 := c2.z
	var trace := m11 + m22 + m33
	if trace > 0.0:
		var s := 0.5 / sqrt(trace + 1.0)
		w = 0.25 / s
		x = (m32 - m23) * s
		y = (m13 - m31) * s
		z = (m21 - m12) * s
	elif m11 > m22 and m11 > m33:
		var s := 2.0 * sqrt(1.0 + m11 - m22 - m33)
		w = (m32 - m23) / s
		x = 0.25 * s
		y = (m12 + m21) / s
		z = (m13 + m31) / s
	elif m22 > m33:
		var s := 2.0 * sqrt(1.0 + m22 - m11 - m33)
		w = (m13 - m31) / s
		x = (m12 + m21) / s
		y = 0.25 * s
		z = (m23 + m32) / s
	else:
		var s := 2.0 * sqrt(1.0 + m33 - m11 - m22)
		w = (m21 - m12) / s
		x = (m13 + m31) / s
		y = (m23 + m32) / s
		z = 0.25 * s
	return self

func angle_to(q: DQuat) -> float:
	return 2.0 * acos(absf(clampf(dot(q), -1.0, 1.0)))

## invert() — THREE assumes unit length, so it is the conjugate.
func invert() -> DQuat:
	x *= -1.0; y *= -1.0; z *= -1.0
	return self

func dot(q: DQuat) -> float:
	return x * q.x + y * q.y + z * q.z + w * q.w

func length_sq() -> float:
	return x * x + y * y + z * z + w * w

func length() -> float:
	return sqrt(x * x + y * y + z * z + w * w)

func normalize_in() -> DQuat:
	var l := length()
	if l == 0.0:
		x = 0.0; y = 0.0; z = 0.0; w = 1.0
	else:
		l = 1.0 / l
		x = x * l; y = y * l; z = z * l; w = w * l
	return self

## this = this × q
func multiply(q: DQuat) -> DQuat:
	return multiply_quaternions(self, q)

## this = q × this
func premultiply(q: DQuat) -> DQuat:
	return multiply_quaternions(q, self)

func multiply_quaternions(a: DQuat, b: DQuat) -> DQuat:
	var qax := a.x; var qay := a.y; var qaz := a.z; var qaw := a.w
	var qbx := b.x; var qby := b.y; var qbz := b.z; var qbw := b.w
	x = qax * qbw + qaw * qbx + qay * qbz - qaz * qby
	y = qay * qbw + qaw * qby + qaz * qbx - qax * qbz
	z = qaz * qbw + qaw * qbz + qax * qby - qay * qbx
	w = qaw * qbw - qax * qbx - qay * qby - qaz * qbz
	return self

## Quaternion.slerp(qb, t), three's version including both special cases.
func slerp_in(qb: DQuat, t: float) -> DQuat:
	if t == 0.0: return self
	if t == 1.0: return copy_from(qb)
	var x0 := x; var y0 := y; var z0 := z; var w0 := w
	var cos_half := w0 * qb.w + x0 * qb.x + y0 * qb.y + z0 * qb.z
	if cos_half < 0.0:
		w = -qb.w; x = -qb.x; y = -qb.y; z = -qb.z
		cos_half = -cos_half
	else:
		copy_from(qb)
	if cos_half >= 1.0:
		w = w0; x = x0; y = y0; z = z0
		return self
	var sqr_sin_half := 1.0 - cos_half * cos_half
	if sqr_sin_half <= EPSILON:
		var s := 1.0 - t
		w = s * w0 + t * w
		x = s * x0 + t * x
		y = s * y0 + t * y
		z = s * z0 + t * z
		normalize_in()
		return self
	var sin_half := sqrt(sqr_sin_half)
	var half_theta := atan2(sin_half, cos_half)
	var ratio_a := sin((1.0 - t) * half_theta) / sin_half
	var ratio_b := sin(t * half_theta) / sin_half
	w = (w0 * ratio_a + w * ratio_b)
	x = (x0 * ratio_a + x * ratio_b)
	y = (y0 * ratio_a + y * ratio_b)
	z = (z0 * ratio_a + z * ratio_b)
	return self

func _to_string() -> String:
	return "DQuat(%s, %s, %s, %s)" % [x, y, z, w]

# ============================================================================
# THREE.Vector3 OPERATIONS, EXACTLY — static, on DVec3, in place.
# ============================================================================

## Vector3.normalize(): multiply by 1/(length || 1).
static func nrm(v: DVec3) -> DVec3:
	var l := sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if l == 0.0 or is_nan(l):
		l = 1.0
	var k := 1.0 / l
	v.x *= k; v.y *= k; v.z *= k
	return v

## Vector3.setLength(l): normalize() then multiplyScalar(l).
static func set_len(v: DVec3, l: float) -> DVec3:
	nrm(v)
	v.x *= l; v.y *= l; v.z *= l
	return v

## Vector3.angleTo(b).
static func angle_between(a: DVec3, b: DVec3) -> float:
	var denominator := sqrt(a.length_sq() * b.length_sq())
	if denominator == 0.0:
		return PI / 2.0
	var theta := a.dot(b) / denominator
	return acos(clampf(theta, -1.0, 1.0))

## Vector3.applyQuaternion(q), in place.
static func rotate(v: DVec3, q: DQuat) -> DVec3:
	var vx := v.x; var vy := v.y; var vz := v.z
	var qx := q.x; var qy := q.y; var qz := q.z; var qw := q.w
	var tx := 2.0 * (qy * vz - qz * vy)
	var ty := 2.0 * (qz * vx - qx * vz)
	var tz := 2.0 * (qx * vy - qy * vx)
	v.x = vx + qw * tx + qy * tz - qz * ty
	v.y = vy + qw * ty + qz * tx - qx * tz
	v.z = vz + qw * tz + qx * ty - qy * tx
	return v

static var _aa := DQuat.new()
## Vector3.applyAxisAngle(axis, angle) — through a shared scratch quaternion,
## as three does it.
static func apply_axis_angle(v: DVec3, axis: DVec3, angle: float) -> DVec3:
	return rotate(v, _aa.set_from_axis_angle(axis, angle))

## THREE.MathUtils.clamp(v, lo, hi) = max(lo, min(hi, v)).
static func jclamp(v: float, lo: float, hi: float) -> float:
	return maxf(lo, minf(hi, v))
