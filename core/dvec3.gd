class_name DVec3
extends RefCounted

# ============================================================================
# A DOUBLE-PRECISION 3-VECTOR.
# ----------------------------------------------------------------------------
# Godot's Vector3 is float32 in a standard build. The web version never had to
# think about this, because every THREE.Vector3 it did physics with was a pair
# of JS doubles — and the physics depends on it. The orrery integrates in AU
# with G = 4π² and needs ~1e-12 relative precision to hold Trisolaris at 1e-7
# energy drift; the flight model integrates in METRES about a planet 6.4e6 m in
# radius, where float32 quantises position to 0.4 m and an RK4 step to garbage.
#
# GDScript's `float` IS a double, so this is simply three of them. It is a
# class rather than a PackedFloat64Array because the ported physics reads like
# the original that way (`a.add(b).scale(k)`), which is what keeps a 1:1 port
# checkable against the JavaScript line by line.
#
# CONVENTIONS, mirroring THREE.Vector3 so the port stays mechanical:
#   · The mutating methods (set_v, add_in, sub_in, scale_in, add_scaled_in,
#     copy_from, normalize_in…) change `self` and return it, like THREE's.
#   · The pure methods (add, sub, scaled, cross, normalized, clone…) allocate.
#     Prefer the mutating form in hot loops — allocation is the cost here.
#   · to_v3() is the ONLY way down to float32, and it belongs at the render
#     boundary, after the camera origin has been subtracted (see PORT_GUIDE.md,
#     "floating origin"). Never convert an absolute AU/metre position.
# ============================================================================

var x: float
var y: float
var z: float

func _init(px: float = 0.0, py: float = 0.0, pz: float = 0.0) -> void:
	x = px; y = py; z = pz

static func from_v3(v: Vector3) -> DVec3:
	return DVec3.new(v.x, v.y, v.z)

static func from_array(a) -> DVec3:
	if a == null or a.size() < 3:
		return DVec3.new()
	return DVec3.new(float(a[0]), float(a[1]), float(a[2]))

func to_v3() -> Vector3:
	return Vector3(x, y, z)

func to_array() -> Array:
	return [x, y, z]

func clone() -> DVec3:
	return DVec3.new(x, y, z)

# ---- mutating (THREE-style, return self) -----------------------------------
func set_v(px: float, py: float, pz: float) -> DVec3:
	x = px; y = py; z = pz
	return self

func copy_from(o: DVec3) -> DVec3:
	x = o.x; y = o.y; z = o.z
	return self

func copy_v3(v: Vector3) -> DVec3:
	x = v.x; y = v.y; z = v.z
	return self

func add_in(o: DVec3) -> DVec3:
	x += o.x; y += o.y; z += o.z
	return self

func sub_in(o: DVec3) -> DVec3:
	x -= o.x; y -= o.y; z -= o.z
	return self

func scale_in(k: float) -> DVec3:
	x *= k; y *= k; z *= k
	return self

func add_scaled_in(o: DVec3, k: float) -> DVec3:
	x += o.x * k; y += o.y * k; z += o.z * k
	return self

func add_vectors(a: DVec3, b: DVec3) -> DVec3:
	x = a.x + b.x; y = a.y + b.y; z = a.z + b.z
	return self

func sub_vectors(a: DVec3, b: DVec3) -> DVec3:
	x = a.x - b.x; y = a.y - b.y; z = a.z - b.z
	return self

func cross_vectors(a: DVec3, b: DVec3) -> DVec3:
	var cx := a.y * b.z - a.z * b.y
	var cy := a.z * b.x - a.x * b.z
	var cz := a.x * b.y - a.y * b.x
	x = cx; y = cy; z = cz
	return self

func normalize_in() -> DVec3:
	var l := length()
	if l > 0.0:
		x /= l; y /= l; z /= l
	return self

func negate_in() -> DVec3:
	x = -x; y = -y; z = -z
	return self

func lerp_in(o: DVec3, t: float) -> DVec3:
	x += (o.x - x) * t; y += (o.y - y) * t; z += (o.z - z) * t
	return self

## THREE's applyQuaternion, with the quaternion given as float components so a
## float32 Quaternion can rotate a double vector without losing the vector.
func apply_quat_in(q: Quaternion) -> DVec3:
	var qx := float(q.x); var qy := float(q.y); var qz := float(q.z); var qw := float(q.w)
	var tx := 2.0 * (qy * z - qz * y)
	var ty := 2.0 * (qz * x - qx * z)
	var tz := 2.0 * (qx * y - qy * x)
	var nx := x + qw * tx + qy * tz - qz * ty
	var ny := y + qw * ty + qz * tx - qx * tz
	var nz := z + qw * tz + qx * ty - qy * tx
	x = nx; y = ny; z = nz
	return self

## Rotate by a Basis (float32 matrix, double vector).
func apply_basis_in(b: Basis) -> DVec3:
	var nx := float(b.x.x) * x + float(b.y.x) * y + float(b.z.x) * z
	var ny := float(b.x.y) * x + float(b.y.y) * y + float(b.z.y) * z
	var nz := float(b.x.z) * x + float(b.y.z) * y + float(b.z.z) * z
	x = nx; y = ny; z = nz
	return self

# ---- pure -------------------------------------------------------------------
func add(o: DVec3) -> DVec3:
	return DVec3.new(x + o.x, y + o.y, z + o.z)

func sub(o: DVec3) -> DVec3:
	return DVec3.new(x - o.x, y - o.y, z - o.z)

func scaled(k: float) -> DVec3:
	return DVec3.new(x * k, y * k, z * k)

func cross(o: DVec3) -> DVec3:
	return DVec3.new(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)

func normalized() -> DVec3:
	return clone().normalize_in()

func dot(o: DVec3) -> float:
	return x * o.x + y * o.y + z * o.z

func length() -> float:
	return sqrt(x * x + y * y + z * z)

func length_sq() -> float:
	return x * x + y * y + z * z

func distance_to(o: DVec3) -> float:
	var dx := x - o.x; var dy := y - o.y; var dz := z - o.z
	return sqrt(dx * dx + dy * dy + dz * dz)

func distance_sq_to(o: DVec3) -> float:
	var dx := x - o.x; var dy := y - o.y; var dz := z - o.z
	return dx * dx + dy * dy + dz * dz

## (self − origin) as a float32 Vector3: the one sanctioned way to a render
## position. The subtraction happens in double precision FIRST, which is the
## whole of the floating-origin scheme.
func rel_v3(origin: DVec3) -> Vector3:
	return Vector3(x - origin.x, y - origin.y, z - origin.z)

## (self·k − origin) as float32 — for AU positions scaled into scene units.
func scaled_rel_v3(k: float, origin: DVec3) -> Vector3:
	return Vector3(x * k - origin.x, y * k - origin.y, z * k - origin.z)

func is_finite_v() -> bool:
	return is_finite(x) and is_finite(y) and is_finite(z)

func _to_string() -> String:
	return "DVec3(%s, %s, %s)" % [x, y, z]
