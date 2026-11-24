class_name Rover
extends RefCounted

# A rover on a site's ground: a rigid chassis on sprung wheels, each meeting the drawn triangles
# (SiteScene.drawn_height) and the soil under them: Bekker's pressure–sinkage and compaction resistance,
# Janosi–Hanamoto's shear for traction and side force. The vehicle (LRV, PERSEVERANCE) and the world's soil
# (SOILS) are data. In the site's frame (x west, y up, z north), SI, doubles, fixed steps. It reads the
# ground and writes nothing back. docs/physics/rover.md.

## The Apollo LRV, from NSSDC's page unless marked: 210 kg empty and 490 kg of payload, a 2.3 m wheelbase,
## 81.8 cm × 23 cm tyres, 0.25 hp motors capable of 10 000 rpm through 80:1, front and rear steering to a
## 3.1 m radius, 36 cm of clearance loaded, a 3.1 m frame and 1.14 m high. The tread is the handbook's 72 in.
## Estimates: the centre of mass with two crew aboard, the suspension (5 cm of static deflection, ζ 0.35,
## 18 cm of travel), a wheel's inertia (5.4 kg as a rim), the drive's efficiency, the steering's and the
## brakes' rates.
const LRV := {
	"name": "LRV", "mass": 700.0, "axles": [1.15, -1.15], "steer_axles": [0, 1], "steer_ref": 0.0,
	"track": 1.83, "wheel_r": 0.409, "wheel_b": 0.23, "com_height": 0.76, "clearance": 0.36,
	"size": [1.83, 1.14, 3.1], "design_g": 1.62, "deflection": 0.05, "damping": 0.35, "travel": 0.18,
	"wheel_i": 0.45, "half_width": 1.1, "steer_radius": 3.1, "steer_rate": 0.6,
	"drive": {"kind": "motor", "watts": 186.4, "rpm": 10000.0, "gear": 80.0, "eff": 0.8},
	"park_brake": 60.0, "brake": 40.0,
}
## Perseverance, from NASA's and JPL's pages: 1025 kg, 3 × 2.7 × 2.2 m, six 52.5 cm wheels each with its own
## motor, the corner four steering, a rocker-bogie, 152 m/h on flat hard ground, a 45° tilt without tipping.
## Estimates: the axles' places and the track (inside its 3 × 2.7 m), the tread (narrower than Curiosity's
## 40 cm), the centre of mass, the drive's torque limit, the steering's least radius and rate, and the
## rocker-bogie: a passive linkage, stood in for by stiff springs with its travel, so the loads it shares
## are not the linkage's.
const PERSEVERANCE := {
	"name": "Perseverance", "mass": 1025.0, "axles": [1.0, 0.05, -0.95], "steer_axles": [0, 2], "steer_ref": 0.05,
	"track": 2.3, "wheel_r": 0.2625, "wheel_b": 0.26, "com_height": 1.0, "clearance": 0.6,
	"size": [2.7, 2.2, 3.0], "design_g": 3.71, "deflection": 0.02, "damping": 0.7, "travel": 0.35,
	"wheel_i": 0.3, "half_width": 1.45, "steer_radius": 2.0, "steer_rate": 0.3,
	"drive": {"kind": "speed", "v_max": 152.0 / 3600.0, "torque": 300.0},
	"park_brake": 300.0, "brake": 300.0,
}
const VEHICLES := {"lrv": LRV, "perseverance": PERSEVERANCE}

## Soils. The Moon: Bekker's moduli from the Lunar Sourcebook's Table 9.14 (kc 1.4 kN/m^(n+1), kφ 820
## kN/m^(n+2), n 1) and Mohr–Coulomb strength for the top 15 cm (c 0.52 kPa, φ 42°), as arXiv 2610.30080
## quotes them; K, 1.8 cm, is an estimate in Wong's range for dry sands. Mars: M90, a simulant of the sand of
## Martian dunes and ripples (Oravec et al. 2021, as arXiv 2606.06790's Table 2 gives it, untuned): kc 572.1
## kN/m^(n+1), kφ 4915.3 kN/m^(n+2), n 1.3, c 2 kPa, φ 35°, K 0.0254 (labelled mm there; an inch, in metres,
## is what the values for dry sand beside it make sense as).
const LUNAR_SOIL := {"kc": 1400.0, "kphi": 820000.0, "n": 1.0, "c": 520.0, "phi": 0.733, "K": 0.018}
const MARS_SAND := {"kc": 572100.0, "kphi": 4915300.0, "n": 1.3, "c": 2000.0, "phi": 0.6109, "K": 0.0254}
const SOILS := {"Moon": LUNAR_SOIL, "Mars": MARS_SAND}

## The integration step, s, and the speed under which slip is measured against this instead, m/s.
const DT := 1.0 / 600.0
const V_EPS := 0.05
const OBSTACLE_K := 2.0e4
const OBSTACLE_C := 4.0e3

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
## chassis (spec.half_width from its centre to a wheel's outside) is pushed out of.
var obstacles: Array = []
## The vehicle and the soil under it.
var spec: Dictionary = LRV
var soil: Dictionary = LUNAR_SOIL
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
	var steers := false
	var axle_z := 0.0
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

func _init(ground_ = null, gravity := 1.62, vehicle: Dictionary = LRV, ground_soil: Dictionary = LUNAR_SOIL) -> void:
	ground = ground_
	g = gravity
	spec = vehicle
	soil = ground_soil
	var axles: Array = spec.axles
	var share := float(spec.mass) / (2.0 * axles.size())
	# Springs sized for the world the vehicle was built for: the deflection it was designed to stand at.
	_k = share * float(spec.design_g) / float(spec.deflection)
	_c = 2.0 * float(spec.damping) * sqrt(_k * share)
	# A box of the vehicle's size: inertia about body x, y, z.
	var w := float(spec.size[0])
	var h := float(spec.size[1])
	var l := float(spec.size[2])
	var m := float(spec.mass)
	_inertia = Vector3(m / 12.0 * (h * h + l * l), m / 12.0 * (w * w + l * l), m / 12.0 * (w * w + h * h))
	# The hub's height over the centre of mass at full extension: loaded, it stands at r less the static
	# sinkage over the ground, and the spring takes up its load here.
	var r := float(spec.wheel_r)
	var hub_y := r - sinkage_for(share * g) - float(spec.com_height) - share * g / _k
	for a in axles.size():
		for left in [true, false]:
			var wh := Wheel.new()
			wh.front = float(axles[a]) > float(spec.steer_ref)
			wh.left = left
			wh.steers = (spec.steer_axles as Array).has(a)
			wh.axle_z = float(axles[a])
			wh.mount = Vector3((1.0 if left else -1.0) * float(spec.track) * 0.5, hub_y, float(axles[a]))
			wheels.append(wh)

## Stand it at (e, n) on the ground, heading `heading` rad from north toward east, at rest and settled.
func place(e: float, n: float, heading: float) -> void:
	var y: float = ground.height(e, n)
	# On the ground's own plane under the wheelbase, so no wheel starts in the ground.
	var span := absf(float(spec.axles[0]) - float(spec.axles[-1])) * 0.5
	var hx: float = ground.height(e + span, n) - ground.height(e - span, n)
	var hz: float = ground.height(e, n + span) - ground.height(e, n - span)
	var nrm := DQuat.nrm(DVec3.new(hx / (2.0 * span), 1.0, -hz / (2.0 * span)))
	var yaw := DQuat.new()
	yaw.set_from_axis_angle(DVec3.new(0.0, 1.0, 0.0), -heading)
	var tilt := DQuat.new()
	tilt.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), nrm)
	q.copy_from(tilt).multiply(yaw).normalize_in()
	pos.set_v(-e, y, n).add_scaled_in(nrm, float(spec.com_height))
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
func sinkage_for(load: float) -> float:
	var n := float(soil.n)
	var b := float(spec.wheel_b)
	var k := float(soil.kc) / b + float(soil.kphi)
	return pow(3.0 * maxf(load, 0.0) / ((3.0 - n) * k * b * sqrt(2.0 * float(spec.wheel_r))), 2.0 / (2.0 * n + 1.0))

## Compaction resistance at sinkage z, N: b (kc/b + kφ) z^(n+1)/(n+1).
func compaction(z: float) -> float:
	var n := float(soil.n)
	var b := float(spec.wheel_b)
	return b * (float(soil.kc) / b + float(soil.kphi)) * pow(z, n + 1.0) / (n + 1.0)

## Janosi–Hanamoto's fraction of the soil's strength a shear displacement of `j` m mobilises.
func shear_fraction(j: float) -> float:
	if j <= 1e-9: return 0.0
	var K := float(soil.K)
	return 1.0 - K / j * (1.0 - exp(-j / K))

## A motor's torque at the wheel, N·m, at wheel speed `w` rad/s and throttle `t`, for a "motor" drive: a
## straight torque–speed line from stall to no load, peak power at half speed (an estimate of a series motor).
func drive_torque(t: float, w: float) -> float:
	var d: Dictionary = spec.drive
	var w0 := float(d.rpm) * TAU / 60.0
	var stall := 4.0 * float(d.watts) / w0
	var wm := absf(w) * float(d.gear)
	var along := signf(t) * signf(w) if absf(w) > 1e-6 else 1.0
	var tm := stall * (1.0 - wm / w0) if along > 0.0 else stall
	return t * maxf(tm, 0.0) * float(d.gear) * float(d.eff)

## A wheel's steering angle at full lock, rad: its axle about the reference, at the steering radius.
func max_steer() -> float:
	var far := 0.0
	for a in (spec.steer_axles as Array): far = maxf(far, absf(float(spec.axles[a]) - float(spec.steer_ref)))
	return atan(far / float(spec.steer_radius))

# A vehicle's speed scale, m/s: what "nearly still" is measured against.
func _top_speed() -> float:
	var d: Dictionary = spec.drive
	if str(d.kind) == "speed": return float(d.v_max)
	return float(d.rpm) * TAU / 60.0 / float(d.gear) * float(spec.wheel_r)

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
	elif vel.length() < 0.3 * minf(1.0, _top_speed() / 3.0): parked = true
	steer_now = move_toward(steer_now, clampf(steer, -1.0, 1.0), float(spec.steer_rate) * dt / max_steer())
	var mass := float(spec.mass)
	var r := float(spec.wheel_r)
	var b := float(spec.wheel_b)
	var travel := float(spec.travel)
	var wheel_i := float(spec.wheel_i)
	var tan_phi := tan(float(soil.phi))
	var drive_spec: Dictionary = spec.drive
	var force := DVec3.new(0.0, -mass * g, 0.0)
	var torque := DVec3.new()
	var up_b := _body(Vector3.UP)
	var fwd_b := _body(Vector3(0, 0, 1))
	var R := float(spec.steer_radius) / maxf(absf(steer_now), 1e-3)
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
		var comp := gy + r - z - mount.y
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
		if comp > travel: spring += 40.0 * _k * (comp - travel)
		var W := maxf(spring, 0.0) * maxf(nrm.dot(up_b), 0.2)
		wh.load = W
		wh.sinkage = minf(sinkage_for(W), r * 0.5)
		z = wh.sinkage
		var cp := DVec3.new(mount.x, gy - z, mount.z)
		wh.contact_point.copy_from(cp)
		# Ackermann about a centre R to the side of the reference axle: the inner wheel turns harder, and
		# wheels behind the reference turn the other way (both ends on the LRV, the corners on Perseverance).
		var inner := (steer_now > 0.0) == wh.left
		var d := 0.0
		if wh.steers and absf(steer_now) > 1e-3:
			var half_track := float(spec.track) * 0.5
			d = atan((wh.axle_z - float(spec.steer_ref)) / maxf(R + (-half_track if inner else half_track), 0.3))
			d *= signf(steer_now)
		wh.steer = d
		var heading_w := DQuat.rotate(DVec3.from_v3(Vector3(sin(d), 0.0, cos(d))), q)
		var h := DQuat.nrm(heading_w.add_scaled_in(nrm, -heading_w.dot(nrm)))
		var l := DVec3.new().cross_vectors(nrm, h)
		var arm := cp.sub(pos)
		var vc := vel.clone().add_in(DVec3.new().cross_vectors(omega, arm))
		var vx := vc.dot(h)
		var vy := vc.dot(l)
		var L := sqrt(2.0 * r * maxf(z, 1e-5))
		var tau := b * L * float(soil.c) + W * tan_phi
		var rim := wh.spin * r
		var s := (rim - vx) / maxf(maxf(absf(rim), absf(vx)), V_EPS)
		s = clampf(s, -1.0, 1.0)
		wh.slip = s
		var fx := signf(s) * tau * shear_fraction(absf(s) * L)
		var alpha := atan2(vy, absf(vx) + V_EPS)
		wh.side_slip = alpha
		var fy := -signf(vy) * tau * shear_fraction(L * absf(tan(clampf(alpha, -1.4, 1.4))))
		var mag := sqrt(fx * fx + fy * fy)
		if mag > tau and mag > 0.0:
			fx *= tau / mag
			fy *= tau / mag
		var roll := compaction(z) * (vx / maxf(absf(vx), V_EPS))
		# Coasting with the controller centred, and held by the parking brake once nearly still, as the crews
		# set it; braking too when the controller is pulled against the motion (estimates of the torques).
		var brake := 0.0
		if parked: brake = float(spec.park_brake)
		elif absf(throttle) >= 0.05 and signf(throttle) != signf(wh.spin) and absf(wh.spin) > 0.5: brake = float(spec.brake)
		if str(drive_spec.kind) == "motor":
			wh.spin += (drive_torque(throttle, wh.spin) - fx * r) / wheel_i * dt
		else:
			# A speed-controlled drive: the soil's torque acts, then the motor holds the commanded rate as far
			# as its torque allows.
			wh.spin -= fx * r / wheel_i * dt
			if not parked:
				# Each wheel commanded for its own arc about the turn's centre, as a rover's drive does.
				var arc := 1.0
				if absf(steer_now) > 1e-3:
					var side_y := (1.0 if wh.left else -1.0) * float(spec.track) * 0.5 * signf(steer_now)
					arc = Vector2(R - side_y, wh.axle_z - float(spec.steer_ref)).length() / R
				var want := throttle * float(drive_spec.v_max) * arc / r
				wh.spin = move_toward(wh.spin, want, float(drive_spec.torque) / wheel_i * dt)
				brake = 0.0
		if brake > 0.0:
			var stop := brake / wheel_i * dt
			wh.spin = 0.0 if absf(wh.spin) <= stop else wh.spin - signf(wh.spin) * stop
		wh.angle += wh.spin * dt
		var f := nrm.clone().scale_in(W).add_scaled_in(h, fx - roll).add_scaled_in(l, fy)
		force.add_in(f)
		torque.add_in(DVec3.new().cross_vectors(arm, f))
	for ob: Array in obstacles:
		var c: Vector2 = ob[0]
		var d := Vector2(pos.x - c.x, pos.z - c.y)
		var reach := float(ob[1]) + float(spec.half_width)
		var dist := d.length()
		if dist >= reach or dist < 1e-6: continue
		var out := d / dist
		var closing := minf(vel.x * out.x + vel.z * out.y, 0.0)
		var push := OBSTACLE_K * (reach - dist) - OBSTACLE_C * closing
		force.add_in(DVec3.new(out.x * push, 0.0, out.y * push))
	vel.add_scaled_in(force, dt / mass)
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
