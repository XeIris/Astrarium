class_name RoverDust
extends RefCounted

# What the wheels throw: each grain leaves the rim at the velocity the rim had there, then flies on its own.
# A rim point θ behind the contact, on a wheel turning at rim speed u on a vehicle moving at v, moves at
# v·h + u(−cos θ·h + sin θ·up): with no slip it rises up and forward, which is why the LRV had dust guards,
# and a slipping wheel throws it back. No air: an exact parabola under g, so the roostertail is as high as
# the rim speed makes it. With air, Stokes drag on a 50 µm grain (an estimate of the size). Drawing only:
# nothing here reaches the physics. docs/physics/rover.md#dust.

const MAX := 1600
## Grains a second per wheel at the rim speed RIM_FULL, m/s, falling with the rim speed: an estimate.
const RATE := 260.0
const RIM_FULL := 3.6
## The guards cover the wheel's top this far either side of it, rad, and catch what leaves under them.
const GUARD := 0.9

var g := 1.62
## Drag rate, 1/s: 0 with no air.
var drag := 0.0
var pos := PackedVector3Array()
var vel := PackedVector3Array()
var floor_y := PackedFloat32Array()
var count := 0
var _rng := RandomNumberGenerator.new()
var _owed: Array = []
var view: MultiMeshInstance3D = null

func _init(gravity := 1.62, air_drag := 0.0, seed_ := 1) -> void:
	g = gravity
	drag = air_drag
	_rng.seed = seed_
	pos.resize(MAX); vel.resize(MAX); floor_y.resize(MAX)

## A grain's velocity leaving the rim θ rad behind the contact: v forward, u rim speed, h heading, up the normal.
static func release_velocity(v: float, u: float, theta: float, h: Vector3, up: Vector3) -> Vector3:
	return h * (v - u * cos(theta)) + up * (u * sin(theta))

## Throw this step's grains from each wheel in contact and fly the rest. `dt` of the world's clock.
func step(rover: Rover, dt: float) -> void:
	var fwd := DQuat.rotate(DVec3.from_v3(Vector3(0, 0, 1)), rover.q).to_v3()
	var v := rover.speed()
	while _owed.size() < rover.wheels.size(): _owed.append(0.0)
	for i in rover.wheels.size():
		var wh: Rover.Wheel = rover.wheels[i]
		if not wh.contact: continue
		var u := wh.spin * float(rover.spec.wheel_r)
		var share := clampf(absf(u) / RIM_FULL, 0.0, 1.5)
		_owed[i] += RATE * share * dt
		var h := fwd.rotated(Vector3.UP, wh.steer) * signf(u if absf(u) > 1e-3 else 1.0)
		var cp := wh.contact_point.to_v3()
		while _owed[i] >= 1.0:
			_owed[i] -= 1.0
			var theta := _rng.randf_range(0.15, PI)
			# Under the guard: caught.
			if absf(theta - PI) < GUARD: continue
			var r := float(rover.spec.wheel_r)
			var at := cp + Vector3.UP * (r - r * cos(theta)) - h * (r * sin(theta))
			var vv := release_velocity(absf(v), absf(u), theta, h, Vector3.UP) * _rng.randf_range(0.85, 1.05)
			vv += Vector3(_rng.randf_range(-0.15, 0.15), 0.0, _rng.randf_range(-0.15, 0.15)) * absf(u)
			_add(at, vv, cp.y)
	_fly(dt)

func _add(p: Vector3, v: Vector3, ground: float) -> void:
	if count >= MAX: return
	pos[count] = p
	vel[count] = v
	floor_y[count] = ground
	count += 1

func _fly(dt: float) -> void:
	var i := 0
	while i < count:
		var v := vel[i]
		if drag > 0.0:
			v *= exp(-drag * dt)
		pos[i] += v * dt + Vector3(0.0, -0.5 * g * dt * dt, 0.0)
		v.y -= g * dt
		vel[i] = v
		if pos[i].y < floor_y[i] - 0.02:
			count -= 1
			pos[i] = pos[count]; vel[i] = vel[count]; floor_y[i] = floor_y[count]
			continue
		i += 1

## The grains as a MultiMesh under `parent` (the site's group: site frame).
func draw(parent: Node3D, tint: Color) -> void:
	if view == null:
		view = MultiMeshInstance3D.new()
		view.name = "lrv_dust"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.instance_count = MAX
		var quad := QuadMesh.new()
		quad.size = Vector2(0.018, 0.018)
		var m := StandardMaterial3D.new()
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.albedo_color = tint
		m.roughness = 1.0
		quad.material = m
		mm.mesh = quad
		view.multimesh = mm
		view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		view.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))
		parent.add_child(view)
	var mm2 := view.multimesh
	mm2.visible_instance_count = count
	for k in count: mm2.set_instance_transform(k, Transform3D(Basis(), pos[k]))

func dispose() -> void:
	if view != null and is_instance_valid(view): view.queue_free()
	view = null
