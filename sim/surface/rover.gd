class_name Rover
extends RefCounted

# The Apollo Lunar Roving Vehicle on a site's ground: a rigid chassis on four torsion-bar wheels, each
# meeting the drawn triangles (SiteScene.drawn_height) and the soil under them: Bekker's pressure–sinkage
# and compaction resistance, Janosi–Hanamoto's shear for traction and side force. Four hub motors through
# 80:1 drives, double Ackermann steering. In the site's frame (x west, y up, z north), SI, doubles, fixed
# steps. It reads the ground and writes nothing back. docs/physics/rover.md.

## The vehicle, from NSSDC's LRV page unless marked: frame 3.1 m, wheelbase 2.3 m, 81.8 cm × 23 cm tyres,
## 210 kg empty and 490 kg of payload, 0.25 hp motors at 10 000 rpm through 80:1, 3.1 m steering radius,
## 36 cm of ground clearance loaded.
const MASS := 700.0
const WHEELBASE := 2.3
## The tread, the LRV handbook's 72 in. NSSDC's page does not give it.
const TRACK := 1.83
const WHEEL_R := 0.409
const WHEEL_B := 0.23
const MOTOR_W := 186.4
const MOTOR_RPM := 10000.0
const GEAR := 80.0
const STEER_RADIUS := 3.1
const CLEARANCE := 0.36
## Estimates, none of them published: the drive train's efficiency, the centre of mass over the ground
## with two crew aboard, a wheel's inertia (5.4 kg as a thin rim), the suspension's static deflection in
## lunar gravity and its damping ratio, its travel, and the steering motors' rate.
const DRIVE_EFF := 0.8
const COM_HEIGHT := 0.76
const WHEEL_I := 0.45
const STATIC_DEFLECTION := 0.05
const DAMPING_RATIO := 0.35
const TRAVEL := 0.18
const STEER_RATE := 0.6
## The soil: Bekker's moduli from the Lunar Sourcebook's Table 9.14 (kc 1.4 kN/m^(n+1), kφ 820 kN/m^(n+2),
## n 1, as arXiv 2610.30080 quotes it), and Mohr–Coulomb strength for the top 15 cm (c 0.52 kPa, φ 42°,
## from the same). K, the shear deformation modulus, is an estimate: 1.8 cm, in the range Wong gives for
## dry sands.
const KC := 1400.0
const KPHI := 820000.0
const N := 1.0
const COHESION := 520.0
const PHI := 0.733
const SHEAR_K := 0.018
## The integration step, s, and the speed under which slip is measured against this instead, m/s.
const DT := 1.0 / 600.0
const V_EPS := 0.05

## The ground: an object with height(e, n) -> the drawn surface's y in the site's frame, m, and g, m/s².
var ground
var g := 1.62
## The chassis: position (its centre of mass) and velocity in the site's frame, attitude, angular velocity.
var pos := DVec3.new()
var vel := DVec3.new()
var q := DQuat.new()
var omega := DVec3.new()
## Driver's inputs, −1..1 (steer positive to the left), and the steering as it is.
var throttle := 0.0
var steer := 0.0
var steer_now := 0.0
## The parking brake: set once the vehicle is nearly still with the controller centred, released by it.
var parked := false
var wheels: Array = []
## What it cannot drive through: [Vector2(x, z) in the site's frame, radius m], as vertical cylinders the
## chassis (1.1 m from its centre to a wheel's outside) is pushed out of.
var obstacles: Array = []
const OBSTACLE_K := 2.0e4
const OBSTACLE_C := 4.0e3
const HALF_WIDTH := 1.1
var time := 0.0
var _acc := 0.0
var _k := 0.0
var _c := 0.0
var _inertia := Vector3.ONE

## A wheel's state, and what the soil did to it on the last step.
class Wheel:
	var mount := Vector3.ZERO     # hub at full extension, body frame (x left, y up, z forward: facing north, x is west)
	var front := true
	var left := true
	var spin := 0.0               # rad/s, positive rolling forward
	var angle := 0.0              # how far it has turned, rad, for drawing
	var compression := 0.0
	var load := 0.0               # N, along the ground's normal
	var sinkage := 0.0
	var slip := 0.0
	var side_slip := 0.0          # rad
	var contact := false
	var contact_point := DVec3.new()   # site frame
	var steer := 0.0

func _init(ground_ = null, gravity := 1.62) -> void:
	ground = ground_
	g = gravity
	var quarter := MASS / 4.0
	_k = quarter * g / STATIC_DEFLECTION
	_c = 2.0 * DAMPING_RATIO * sqrt(_k * quarter)
	# A box of the vehicle's size, the crew's height in it: inertia about body x, y, z.
	var w := TRACK
	var h := 1.14
	var l := 3.1
	_inertia = Vector3(MASS / 12.0 * (h * h + l * l), MASS / 12.0 * (w * w + l * l), MASS / 12.0 * (w * w + h * h))
	# The hub's height over the chassis's centre at full extension: loaded, it stands at r less the
	# static sinkage over the ground, and the spring takes up STATIC_DEFLECTION.
	var hub_y := WHEEL_R - static_sinkage(MASS * g / 4.0) - COM_HEIGHT - STATIC_DEFLECTION
	for i in 4:
		var wh := Wheel.new()
		wh.front = i < 2
		wh.left = i % 2 == 0
		wh.mount = Vector3((1.0 if wh.left else -1.0) * TRACK * 0.5, hub_y, (1.0 if wh.front else -1.0) * WHEELBASE * 0.5)
		wheels.append(wh)

## Stand it at (e, n) on the ground, heading `heading` rad from north toward east, at rest and settled.
func place(e: float, n: float, heading: float) -> void:
	var y: float = ground.height(e, n)
	# On the ground's own plane under the wheelbase, so no wheel starts in the ground.
	var span := WHEELBASE * 0.5
	var hx: float = ground.height(e + span, n) - ground.height(e - span, n)
	var hz: float = ground.height(e, n + span) - ground.height(e, n - span)
	var nrm := DQuat.nrm(DVec3.new(hx / (2.0 * span), 1.0, -hz / (2.0 * span)))
	var yaw := DQuat.new()
	yaw.set_from_axis_angle(DVec3.new(0.0, 1.0, 0.0), -heading)
	var tilt := DQuat.new()
	tilt.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), nrm)
	q.copy_from(tilt).multiply(yaw).normalize_in()
	pos.set_v(-e, y, n).add_scaled_in(nrm, COM_HEIGHT)
	vel.set_v(0.0, 0.0, 0.0)
	omega.set_v(0.0, 0.0, 0.0)
	for wh: Wheel in wheels: wh.spin = 0.0
	for i in 1200: _step(DT)

## Run `dt` seconds of the world's clock in fixed steps.
func advance(dt: float) -> void:
	_acc += dt
	var guard := 0
	while _acc >= DT and guard < 6000:
		_step(DT)
		_acc -= DT
		guard += 1

## Bekker's static sinkage of a rigid wheel under `load` N, m: z = [3W / ((3 − n)(kc/b + kφ) b √D)]^(2/(2n+1)).
static func static_sinkage(load: float) -> float:
	var k := KC / WHEEL_B + KPHI
	return pow(3.0 * maxf(load, 0.0) / ((3.0 - N) * k * WHEEL_B * sqrt(2.0 * WHEEL_R)), 2.0 / (2.0 * N + 1.0))

## Compaction resistance at sinkage z, N: b (kc/b + kφ) z^(n+1)/(n+1).
static func compaction(z: float) -> float:
	return WHEEL_B * (KC / WHEEL_B + KPHI) * pow(z, N + 1.0) / (N + 1.0)

## Janosi–Hanamoto's fraction of the soil's strength a slip of `j` m over contact length `L` mobilises.
static func shear_fraction(j: float, L: float) -> float:
	if j <= 1e-9: return 0.0
	return 1.0 - SHEAR_K / j * (1.0 - exp(-j / SHEAR_K))

## Each motor's torque at the wheel, N·m, at wheel speed `w` rad/s and throttle `t`: a straight
## torque–speed line from stall to no load, peak power at half speed (an estimate of the series motor).
static func drive_torque(t: float, w: float) -> float:
	var w0 := MOTOR_RPM * TAU / 60.0
	var stall := 4.0 * MOTOR_W / w0
	var wm := absf(w) * GEAR
	var along := signf(t) * signf(w) if absf(w) > 1e-6 else 1.0
	var tm := stall * (1.0 - wm / w0) if along > 0.0 else stall
	return t * maxf(tm, 0.0) * GEAR * DRIVE_EFF

## The steering angle for a radius of STEER_RADIUS at full lock, rad, both ends turning: tan δ = (L/2)/R.
static func max_steer() -> float:
	return atan(WHEELBASE * 0.5 / STEER_RADIUS)

## Forward over the ground's plane, m/s.
func speed() -> float:
	var f := _body(Vector3.FORWARD * -1.0)
	return vel.dot(f)

## Heading, rad from north toward east.
func heading() -> float:
	var f := _body(Vector3(0, 0, 1))
	return atan2(-f.x, f.z)

func _body(v: Vector3) -> DVec3:
	return DQuat.rotate(DVec3.from_v3(v), q)

func _step(dt: float) -> void:
	time += dt
	if absf(throttle) >= 0.05: parked = false
	elif vel.length() < 0.3: parked = true
	steer_now = move_toward(steer_now, clampf(steer, -1.0, 1.0), STEER_RATE * dt / max_steer())
	var force := DVec3.new(0.0, -MASS * g, 0.0)
	var torque := DVec3.new()
	var up_b := _body(Vector3.UP)
	var fwd_b := _body(Vector3(0, 0, 1))
	var R := STEER_RADIUS / maxf(absf(steer_now), 1e-3)
	for wh: Wheel in wheels:
		var mount := DVec3.from_v3(Vector3.ZERO).add_in(pos).add_in(_body(wh.mount))
		var e := -mount.x
		var n := mount.z
		var gy: float = ground.height(e, n)
		if is_nan(gy):
			wh.contact = false
			continue
		# The ground's normal, off the drawn surface 10 cm either way.
		var hx: float = ground.height(e + 0.1, n) - ground.height(e - 0.1, n)
		var hz: float = ground.height(e, n + 0.1) - ground.height(e, n - 0.1)
		var nrm := DQuat.nrm(DVec3.new(hx / 0.2, 1.0, -hz / 0.2))
		var z := wh.sinkage
		var comp := gy + WHEEL_R - z - mount.y
		if comp <= 0.0:
			wh.contact = false
			wh.compression = 0.0
			wh.load = 0.0
			wh.sinkage = 0.0
			wh.spin *= exp(-dt * 0.5)
			continue
		wh.contact = true
		# The damper works on how fast the mount closes on the ground, not on the step's change in compression.
		var mount_arm := mount.sub(pos)
		var rate := -(vel.y + DVec3.new().cross_vectors(omega, mount_arm).y)
		wh.compression = comp
		var spring := _k * comp + _c * rate
		if comp > TRAVEL: spring += 40.0 * _k * (comp - TRAVEL)
		var W := maxf(spring, 0.0) * maxf(nrm.dot(up_b), 0.2)
		wh.load = W
		wh.sinkage = minf(static_sinkage(W), WHEEL_R * 0.5)
		z = wh.sinkage
		var cp := DVec3.new(mount.x, gy - z, mount.z)
		wh.contact_point.copy_from(cp)
		# Double Ackermann about a centre R to the side: the inner wheel turns harder, front and rear opposite.
		var inner := (steer_now > 0.0) == wh.left
		var d := 0.0
		if absf(steer_now) > 1e-3:
			d = atan(WHEELBASE * 0.5 / maxf(R + (-TRACK * 0.5 if inner else TRACK * 0.5), 0.3))
			d *= signf(steer_now) * (1.0 if wh.front else -1.0)
		wh.steer = d
		var heading_w := DQuat.rotate(DVec3.from_v3(Vector3(sin(d), 0.0, cos(d))), q)
		var h := DQuat.nrm(heading_w.add_scaled_in(nrm, -heading_w.dot(nrm)))
		var l := DVec3.new().cross_vectors(nrm, h)
		var arm := cp.sub(pos)
		var vc := vel.clone().add_in(DVec3.new().cross_vectors(omega, arm))
		var vx := vc.dot(h)
		var vy := vc.dot(l)
		var L := sqrt(2.0 * WHEEL_R * maxf(z, 1e-5))
		var tau := WHEEL_B * L * COHESION + W * tan(PHI)
		var rim := wh.spin * WHEEL_R
		var s := (rim - vx) / maxf(maxf(absf(rim), absf(vx)), V_EPS)
		s = clampf(s, -1.0, 1.0)
		wh.slip = s
		var fx := signf(s) * tau * shear_fraction(absf(s) * L, L)
		var alpha := atan2(vy, absf(vx) + V_EPS)
		wh.side_slip = alpha
		var fy := -signf(vy) * tau * shear_fraction(L * absf(tan(clampf(alpha, -1.4, 1.4))), L)
		var mag := sqrt(fx * fx + fy * fy)
		if mag > tau and mag > 0.0:
			fx *= tau / mag
			fy *= tau / mag
		var roll := compaction(z) * (vx / maxf(absf(vx), V_EPS))
		var drive := drive_torque(throttle, wh.spin)
		# Coasting with the controller centred, and held by the parking brake once nearly still, as the crews
		# set it; braking too when the controller is pulled against the motion (estimates of the torques).
		var brake := 0.0
		if parked: brake = 60.0
		elif absf(throttle) >= 0.05 and signf(throttle) != signf(wh.spin) and absf(wh.spin) > 0.5: brake = 40.0
		var t_net := drive - fx * WHEEL_R
		wh.spin += t_net / WHEEL_I * dt
		if brake > 0.0:
			var stop := brake / WHEEL_I * dt
			wh.spin = 0.0 if absf(wh.spin) <= stop else wh.spin - signf(wh.spin) * stop
		wh.angle += wh.spin * dt
		var f := nrm.clone().scale_in(W).add_scaled_in(h, fx - roll).add_scaled_in(l, fy)
		force.add_in(f)
		torque.add_in(DVec3.new().cross_vectors(arm, f))
	for ob: Array in obstacles:
		var c: Vector2 = ob[0]
		var d := Vector2(pos.x - c.x, pos.z - c.y)
		var reach := float(ob[1]) + HALF_WIDTH
		var dist := d.length()
		if dist >= reach or dist < 1e-6: continue
		var out := d / dist
		var closing := minf(vel.x * out.x + vel.z * out.y, 0.0)
		var push := OBSTACLE_K * (reach - dist) - OBSTACLE_C * closing
		force.add_in(DVec3.new(out.x * push, 0.0, out.y * push))
	vel.add_scaled_in(force, dt / MASS)
	pos.add_scaled_in(vel, dt)
	# Angular: in body axes, where the inertia is diagonal.
	var inv := q.clone().invert()
	var wb := DQuat.rotate(omega.clone(), inv).to_v3()
	var tb := DQuat.rotate(torque.clone(), inv).to_v3()
	var Iw := wb * _inertia
	var dw := (tb - wb.cross(Iw)) / _inertia
	wb += dw * dt
	omega.copy_from(DQuat.rotate(DVec3.from_v3(wb), q))
	var ang := omega.length() * dt
	if ang > 0.0:
		var dq := DQuat.new()
		dq.set_from_axis_angle(omega.clone().scale_in(1.0 / omega.length()), ang)
		q.premultiply(dq).normalize_in()

## The drawn ground of a surveyed site, for a rover: SiteScene.drawn_height, the mesh's own triangles.
class SiteGround:
	var grids: Array
	var patch_y := 0.0
	var radius := 1.7374e6
	func _init(site_grids: Array, patch: float, R: float) -> void:
		grids = site_grids
		patch_y = patch
		radius = R
	func height(e: float, n: float) -> float:
		return SiteScene.drawn_height(grids, e, n, patch_y, radius, false)

## A plane through the origin rising `slope` (rad) toward `toward` (rad from north toward east), for checks.
class PlaneGround:
	var tan_s := 0.0
	var dir := Vector2(0.0, 1.0)
	func _init(slope := 0.0, toward := 0.0) -> void:
		tan_s = tan(slope)
		dir = Vector2(sin(toward), cos(toward))
	func height(e: float, n: float) -> float:
		return (e * dir.x + n * dir.y) * tan_s
