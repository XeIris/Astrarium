class_name OrreryCamera
extends RefCounted

const MIN_REQUEST_RADIUS := 1e-6
const MAX_REQUEST_RADIUS := 20000.0

## Orbit/free motion in scene units. The stage owns the shared absolute position;
## flight and surface cameras may write it before switching back to this controller.
var position: DVec3
var target := DVec3.new()
var offset := DVec3.new()
var radius := 24.0
var radius_to: Variant = null
var theta := PI / 2.0 - 0.35
var phi := PI / 2.0
var yaw := 0.0
var pitch := 0.0
var free_speed := 12.0

func _init(shared_position: DVec3) -> void:
	position = shared_position

static func request_error(request: Variant) -> String:
	if not request is Dictionary: return "cam must be a dictionary."
	for key in request:
		if key not in ["mode", "theta", "phi", "radius"]:
			return "Unknown cam field \"%s\"." % str(key)
	if request.has("mode") and request.mode not in ["orbit", "free", "surface", "flight"]:
		return "cam.mode must be orbit, free, surface or flight."
	for key in ["theta", "phi", "radius"]:
		if not request.has(key) or request[key] == null: continue
		var value: Variant = request[key]
		if not (value is int or value is float) or not is_finite(float(value)):
			return "cam.%s must be a finite number." % key
		if key == "radius" and (float(value) < MIN_REQUEST_RADIUS or float(value) > MAX_REQUEST_RADIUS):
			return "cam.radius must be between 1e-6 and 20000 scene units, inclusive."
	return ""

## Invalid patches leave all camera state untouched. The stage validates before mode side effects.
func apply_request(request: Dictionary) -> bool:
	if not request_error(request).is_empty(): return false
	if request.get("theta") != null: theta = clampf(float(request.theta), 0.02, PI - 0.02)
	if request.get("phi") != null: phi = float(request.phi)
	if request.get("radius") != null: jump_radius(float(request.radius))
	return true

func jump_radius(value: float) -> void:
	radius = value
	radius_to = null

func frame_radius(body: Body) -> float:
	var geometric := maxf(body.radius_scene, body.rs_scene) * 7.0
	var resolvable := maxf(1e-6, body.scene_pos.length() * 1e-5)
	if geometric >= resolvable: return geometric
	return maxf(radius, resolvable)

func ease_radius(dt: float) -> void:
	if radius_to == null: return
	var ratio: float = radius_to / radius
	if absf(log(ratio)) < 0.01:
		jump_radius(radius_to)
		return
	# Log-space interpolation makes distance easing independent of frame rate.
	radius *= pow(ratio, 1.0 - exp(-dt * 6.0))

func track_follow(body: Body, dt: float) -> void:
	if offset.length_sq() > 0.0:
		offset.scale_in(exp(-dt * 5.0))
		if offset.length_sq() < pow(radius * 1e-4, 2.0): offset.set_v(0, 0, 0)
	# Exact tracking avoids a first-order lag behind a fast moving body.
	target.copy_from(body.scene_pos).add_in(offset)

func glide_target_to(destination: DVec3) -> void:
	offset.copy_from(target).sub_in(destination)
	if offset.length_sq() > pow(radius * 40.0, 2.0): offset.set_v(0, 0, 0)
	target.copy_from(destination).add_in(offset)

func update_orbit(current_basis := Basis()) -> Basis:
	position.set_v(radius * sin(theta) * cos(phi), radius * cos(theta), radius * sin(theta) * sin(phi)).add_in(target)
	var direction := target.rel_v3(position)
	return Basis.looking_at(direction.normalized(), Vector3.UP) if direction.length_squared() > 0.0 else current_basis

func drag_orbit(dx: float, dy: float) -> void:
	phi -= dx * 0.005
	theta = clampf(theta - dy * 0.005, 0.05, PI - 0.05)

func drag_free(dx: float, dy: float) -> void:
	yaw -= dx * 0.0025
	pitch = clampf(pitch - dy * 0.0025, -1.5, 1.5)

func zoom_orbit(delta_y: float) -> void:
	jump_radius(clampf(radius * (1.0 + delta_y * 0.001), MIN_REQUEST_RADIUS, MAX_REQUEST_RADIUS))

func seed_free() -> void:
	var direction := target.rel_v3(position).normalized()
	yaw = atan2(direction.x, direction.z)
	pitch = asin(clampf(direction.y, -1.0, 1.0))

func update_free(dt: float, controls: ControlBindings, keys: Dictionary) -> Basis:
	var forward := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)).normalized()
	var right := forward.cross(Vector3.UP).normalized()
	var speed := free_speed * (4.0 if controls.held("move_fast", keys) else 1.0) * dt
	var movement := Vector3.ZERO
	if controls.held("move_forward", keys): movement += forward * speed
	if controls.held("move_back", keys): movement -= forward * speed
	if controls.held("move_right", keys): movement += right * speed
	if controls.held("move_left", keys): movement -= right * speed
	if controls.held("move_up", keys): movement += Vector3.UP * speed
	if controls.held("move_down", keys): movement -= Vector3.UP * speed
	position.x += movement.x; position.y += movement.y; position.z += movement.z
	return Basis.looking_at(forward, Vector3.UP)

static func pick_radius(body: Body) -> float:
	var geometric := maxf(body.radius_scene, body.rs_scene) * 1.6
	if body.marker == null or not body.marker.mesh.visible: return geometric
	return maxf(geometric, body.marker.mesh.scale.x * 0.42)

func pick(bodies: Array, screen: Vector2, viewport: Vector2, fov: float, basis: Basis) -> Body:
	var ndc := Vector2(screen.x / viewport.x * 2.0 - 1.0, -(screen.y / viewport.y) * 2.0 + 1.0)
	var tangent := tan(deg_to_rad(fov) * 0.5)
	var direction := (basis * Vector3(ndc.x * tangent * viewport.x / viewport.y, ndc.y * tangent, -1.0)).normalized()
	var best: Body = null
	var best_distance := INF
	for body: Body in bodies:
		var relative := body.scene_pos.rel_v3(position)
		var along := relative.dot(direction)
		if along < 0.0: continue
		var distance := (relative - direction * along).length()
		if distance < pick_radius(body) and along < best_distance:
			best = body
			best_distance = along
	return best

func near_plane(bodies: Array, free: bool, current: float) -> float:
	var distance := radius
	if free:
		distance = INF
		for body: Body in bodies:
			distance = minf(distance, position.distance_to(body.scene_pos) - maxf(body.radius_scene, body.rs_scene))
		distance = maxf(distance, 1e-6) if is_finite(distance) else 1.0
	# A far/near ratio above 1e7 degenerates Godot's float32 culling frustum.
	var near := clampf(distance * 0.05, 1e-7, 0.01)
	return near if absf(log(near / current)) > 0.05 else current
