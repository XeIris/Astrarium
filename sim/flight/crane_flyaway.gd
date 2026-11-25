class_name CraneFlyaway
extends RefCounted

# The Sky Crane's descent stage after the cut: a body of its own in the vessel's parent-centred frame, under
# gravity and its own engines: straight up, pitched over at a held height, then a fall to where it meets the ground. It reads the vessel's frame and ground and never acts on the vessel.
# docs/physics/sky-crane.md#the-flyaway.

## Straight up for CLIMB_S at CLIMB_A over the weight, then at PITCH holding its height until BURN_S after the cut;
## then it falls. PITCH and BURN_S are set so that it comes down as Curiosity's was reported to, 650 m off and some
## 20 s after the release; the climb is an estimate.
const CLIMB_S := 2.5
const CLIMB_A := 3.0
const PITCH := 1.0
const PITCH_RATE := 0.6
const BURN_S := 16.0
const STEP := 0.02
## Its drag area, m²: a 2.3 m disk's, Cd 1 (an estimate; at 60 m/s it is under 2% of its weight).
const CDA := 4.0

var r := DVec3.new()
var v := DVec3.new()
var mass := 0.0
var prop := 0.0
var t := 0.0
## Thrust now, as a fraction of `f_max`, and the tilt from the vertical, rad.
var burn := 0.0
var tilt := 0.0
## The horizontal direction it leaves in, a unit vector.
var dir := DVec3.new()
var f_max := 0.0
var isp := 210.0
var down := false
var flown_m := 0.0
var _g := DVec3.new()
var _air := DVec3.new()
var _a := DVec3.new()
var _up := DVec3.new()

## From the vessel's descent stage at `at`, moving with the ground, leaving along `heading` (made horizontal).
static func start(vessel: Vessel, st, at: DVec3, heading: DVec3) -> CraneFlyaway:
	var f := CraneFlyaway.new()
	f.r.copy_from(at)
	f.v.set_v(0.0, -float(vessel.env.rotRate), 0.0).cross_vectors(f.v, at)
	var up := DQuat.nrm(at.clone())
	DQuat.nrm(f.dir.copy_from(heading).add_scaled_in(up, -heading.dot(up)))
	f.mass = float(st.spec.dry) + st.prop + st.rcs_prop
	f.prop = st.prop
	var o := Rocketry.engine_output(st.spec.engine, maxi(int(st.live), 1), 0.0, 1.0, 0.0)
	f.f_max = o.F
	f.isp = float(st.spec.engine.ispVac)
	return f

func step(dt: float, vessel: Vessel) -> void:
	var left := dt
	while left > 0.0 and not down:
		var h := minf(left, STEP)
		_step(h, vessel)
		left -= h
	# Down, it turns with the ground it lies on, to the frame's end, where the vessel already is.
	if left > 0.0: DQuat.apply_axis_angle(r, _a.set_v(0.0, -1.0, 0.0), float(vessel.env.rotRate) * left)
	if down and flown_m == 0.0: flown_m = r.sub(vessel.r).length()

func _step(h: float, vessel: Vessel) -> void:
	# The heading turns with the planet, as the ground it leaves does.
	DQuat.apply_axis_angle(dir, _a.set_v(0.0, -1.0, 0.0), float(vessel.env.rotRate) * h)
	DQuat.nrm(_up.copy_from(r))
	vessel.gravity(r, _g)
	var g := _g.length()
	var want := 0.0
	if t < CLIMB_S:
		want = g + CLIMB_A
		tilt = 0.0
	elif t < BURN_S:
		tilt = minf(tilt + PITCH_RATE * h, PITCH)
		# Its climb is held off and its height kept: the vertical is the weight less what stops the climb.
		var vz := vessel.ground_velocity(r, v, _a).dot(_up)
		want = maxf(g - vz / 1.5, 0.5 * g) / cos(tilt)
	var f := minf(want * mass, f_max) if prop > 0.0 else 0.0
	burn = f / f_max
	var dm := minf(f / (isp * Rocketry.G0) * h, prop)
	_a.copy_from(_g)
	if f > 0.0:
		_a.add_scaled_in(_up, f / mass * cos(tilt)).add_scaled_in(dir, f / mass * sin(tilt))
	if vessel.env.atm != null:
		var rho := Rocketry.density(vessel.env.atm, vessel.altitude(r))
		var va := vessel.airspeed(r, v, _air).length()
		_a.add_scaled_in(_air, -0.5 * rho * va * CDA / mass)
	r.add_scaled_in(v, h).add_scaled_in(_a, 0.5 * h * h)
	v.add_scaled_in(_a, h)
	mass -= dm
	prop -= dm
	t += h
	if t > 1.0 and vessel.height_above_ground(r) <= 0.0:
		down = true
		burn = 0.0
		DQuat.set_len(r, vessel.ground_r(r))
