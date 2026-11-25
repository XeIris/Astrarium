class_name Rotorcraft
extends RefCounted

# A rotorcraft on a world: rotors by blade-element momentum theory in the air that is there, a rigid body on
# its legs on the drawn ground, the flight software that holds a commanded velocity, climb and heading, and
# the battery that pays for it. Site frame (x west, y up, z north), SI, doubles, a fixed 1/400 s step on the
# flight clock, drawn or not. It reads the ground and the air and writes nothing back.
# docs/physics/rotorcraft.md.

const DT := 1.0 / 400.0
## Induced power over the ideal (Leishman's κ for a real rotor). A coaxial pair's is 1.28 times two isolated rotors',
## its lower one working in the upper's contracted wake (Leishman & Syal 2008); both on one disc, as the pair's inflow
## is found here, is already √2 times them, so of that disc's power it is 1.28/√2.
const KAPPA := 1.15
const COAX_OVER_ISOLATED := 1.28
const KAPPA_COAX := COAX_OVER_ISOLATED / 1.4142135623730951
## Profile power grows with advance ratio as 1 + 4.65μ² (Leishman, "Principles of Helicopter Aerodynamics").
const PROFILE_MU := 4.65
## A fixed-pitch rotor idles at this fraction of its top speed rather than stopping (an estimate).
const IDLE := 0.1

## Ingenuity, from NASA: 1.8 kg, two coaxial counter-rotating rotors of 0.605 m radius, two blades each, a
## blade area of 0.170 m² a rotor (solidity 0.148; Koning et al., NASA TM 2024), held at a constant 2537 rpm and
## flown by collective and cyclic. Estimates: the airfoil's lift slope and drag (a thin cambered section at a
## Reynolds number near 20,000), the hubs' heights, the legs, the body's drag, the motors' efficiency, the
## avionics, and the battery.
const INGENUITY := {
	"name": "Ingenuity", "mass": 1.8, "inertia": Vector3(0.045, 0.06, 0.045), "size": Vector3(0.195, 0.163, 0.136),
	"control": "collective", "rpm": 2537.0, "radius": 0.605, "solidity": 0.148, "blades": 2,
	"cl_alpha": 5.0, "cd0": 0.035, "theta_max": 0.42, "cyclic_max": 0.15,
	"rotors": [{"at": Vector3(0.0, 0.25, 0.0), "pair": 0, "spin": 1.0}, {"at": Vector3(0.0, 0.17, 0.0), "pair": 0, "spin": -1.0}],
	"legs": [Vector3(0.25, -0.17, 0.25), Vector3(-0.25, -0.17, 0.25), Vector3(0.25, -0.17, -0.25), Vector3(-0.25, -0.17, -0.25)],
	"cda": 0.03, "efficiency": 0.75, "avionics": 30.0, "battery_wh": 40.0,
	"v_max": 10.0, "climb_max": 2.0, "tilt_max": 0.35, "yaw_max": 0.6,
}
## Dragonfly, from NASA: 875 kg, 3.85 m across, eight 1.35 m rotors as four coaxial pairs, a 134 Ah battery and
## an MMRTG. Estimates: the arms, the fixed blade pitch and solidity, the rotor speed limit, the airfoil, the
## legs, the body's drag, the motors' efficiency, the avionics and the battery's 14 kWh (Lorenz et al. 2018's
## upper bound, the MMRTG's output over a Titan night).
const DRAGONFLY := {
	"name": "Dragonfly", "mass": 875.0, "inertia": Vector3(400.0, 600.0, 400.0), "size": Vector3(3.85, 1.75, 3.85),
	"control": "rpm", "rpm_max": 1100.0, "radius": 0.675, "solidity": 0.10, "blades": 2,
	"cl_alpha": 5.7, "cd0": 0.012, "theta": 0.24, "cyclic_max": 0.0,
	"rotors": [
		{"at": Vector3(1.25, 0.75, 1.25), "pair": 0, "spin": 1.0}, {"at": Vector3(1.25, 0.55, 1.25), "pair": 0, "spin": -1.0},
		{"at": Vector3(-1.25, 0.75, 1.25), "pair": 1, "spin": -1.0}, {"at": Vector3(-1.25, 0.55, 1.25), "pair": 1, "spin": 1.0},
		{"at": Vector3(1.25, 0.75, -1.25), "pair": 2, "spin": -1.0}, {"at": Vector3(1.25, 0.55, -1.25), "pair": 2, "spin": 1.0},
		{"at": Vector3(-1.25, 0.75, -1.25), "pair": 3, "spin": 1.0}, {"at": Vector3(-1.25, 0.55, -1.25), "pair": 3, "spin": -1.0}],
	"legs": [Vector3(0.9, -0.75, 1.2), Vector3(-0.9, -0.75, 1.2), Vector3(0.9, -0.75, -1.2), Vector3(-0.9, -0.75, -1.2)],
	"cda": 0.8, "efficiency": 0.8, "avionics": 150.0, "battery_wh": 14000.0,
	"v_max": 10.0, "climb_max": 3.0, "tilt_max": 0.35, "yaw_max": 0.3,
}
const VEHICLES := {"ingenuity": INGENUITY, "dragonfly": DRAGONFLY}

class Rotor:
	var at := Vector3.ZERO
	var pair := 0
	var spin := 1.0
	## Collective pitch, rad; speed, rad/s; and what it gives: thrust, N; torque, N·m; shaft power, W.
	var theta := 0.0
	var omega := 0.0
	var thrust := 0.0
	var torque := 0.0
	var power := 0.0
	## Inflow ratio (through the disc, over the tip speed) and advance ratio.
	var lam := 0.0
	var mu := 0.0
	var saturated := false

var spec: Dictionary
var ground
var g := 3.71
var rho := 0.0165
var sound := 240.0
var rotors: Array[Rotor] = []
var pos := DVec3.new()
var vel := DVec3.new()
var q := DQuat.new()
## Angular velocity in the body frame.
var w := DVec3.new()
var t := 0.0
var energy_wh := 0.0
var power_w := 0.0
var on_ground := true
var crashed := false
## Commands, from keys or a program: velocity over the ground in the body's heading frame (x right, z ahead),
## climb rate, yaw rate (positive to the right). `armed` false idles the rotors.
var cmd_fwd := 0.0
var cmd_side := 0.0
var cmd_climb := 0.0
var cmd_yaw := 0.0
var armed := false
## The height over the ground held while the climb stick is centred, m; −1 while climbing or on the ground.
var hold_agl := -1.0
## Down and told to stay down: once on the ground without a climb command it idles there, bounce or not,
## until a climb lifts it off.
var landed := true
## Leg compression, for drawing and checks.
var leg_load := PackedFloat64Array()
var _split := PackedFloat64Array()
var _acc := 0.0

func _init(on_ground_: Variant, gravity: float, density: float, speed_of_sound: float, vehicle: Dictionary) -> void:
	ground = on_ground_
	g = gravity
	rho = density
	sound = speed_of_sound
	spec = vehicle
	for r: Dictionary in vehicle.rotors:
		var ro := Rotor.new()
		ro.at = r.at; ro.pair = int(r.pair); ro.spin = float(r.spin)
		ro.omega = float(vehicle.get("rpm", 0.0)) * TAU / 60.0
		ro.theta = float(vehicle.get("theta", 0.0))
		rotors.append(ro)
	energy_wh = float(vehicle.battery_wh)
	leg_load.resize(vehicle.legs.size())
	_split.resize(_pairs())
	_split.fill(0.0)

func _upper_spin(p: int) -> float:
	for r in rotors:
		if r.pair == p: return r.spin
	return 1.0

func _pairs() -> int:
	var n := 0
	for r in rotors: n = maxi(n, r.pair + 1)
	return n

## Stand it on the ground at site (east, north), facing `heading` rad from north toward east.
func place(e: float, n: float, heading: float) -> void:
	var y: float = ground.height(e, n)
	var low := 0.0
	for leg: Vector3 in spec.legs: low = minf(low, leg.y)
	pos.set_v(-e, y - low, n)
	q.set_from_axis_angle(DVec3.new(0.0, 1.0, 0.0), -heading)
	vel.set_v(0.0, 0.0, 0.0)
	w.set_v(0.0, 0.0, 0.0)
	on_ground = true

## Run on to time `to`, s.
func advance(to: float) -> void:
	while t + DT <= to + 1e-9:
		_step()
		t += DT

## Run `dt` s of the flight's clock in fixed steps, what is left of one kept for the next call.
func run(dt: float) -> void:
	_acc += dt
	while _acc >= DT:
		_step()
		t += DT
		_acc -= DT

## Heading, rad from north toward east.
func heading() -> float:
	var f := DQuat.rotate(DVec3.new(0.0, 0.0, 1.0), q)
	return atan2(-f.x, f.z)

## Height of the body's lowest leg over the ground under it, m.
func height_above_ground() -> float:
	var low := INF
	for leg: Vector3 in spec.legs:
		var p := DQuat.rotate(DVec3.from_v3(leg), q).add_in(pos)
		low = minf(low, p.y - float(ground.height(-p.x, p.z)))
	return low

## The ground's steepest slope under the craft across `span` m, rad: what a hazard lidar sees.
func ground_slope(span: float) -> float:
	var e := -pos.x
	var n := pos.z
	var gx := (float(ground.height(e + span, n)) - float(ground.height(e - span, n))) / (2.0 * span)
	var gz := (float(ground.height(e, n + span)) - float(ground.height(e, n - span))) / (2.0 * span)
	return atan(sqrt(gx * gx + gz * gz))

## ROTORS

## A rotor's thrust coefficient for collective θ at inflow λ: C_T = σa/2 (θ/3 − λ/2), uniform inflow, untwisted.
func ct_of(theta: float, lam: float) -> float:
	return float(spec.solidity) * float(spec.cl_alpha) * 0.5 * (theta / 3.0 - lam * 0.5)

## Inflow ratio λ through a disc at thrust coefficient C_T, advance ratio μ and climb inflow λ_c: Glauert's
## λ = λ_c + C_T/(2√(μ² + λ²)), by Newton from the axial solution.
static func inflow(ct: float, mu: float, lc: float) -> float:
	if ct <= 0.0: return lc
	var lam := lc * 0.5 + sqrt(lc * lc * 0.25 + ct * 0.5)
	for i in 8:
		var s2 := maxf(mu * mu + lam * lam, 1e-12)
		var f := lam - lc - ct / (2.0 * sqrt(s2))
		var df := 1.0 + ct * lam / (2.0 * pow(s2, 1.5))
		lam -= f / df
	return lam

## Set every rotor of pair `p` to share `thrust` N between them, the upper taking (1 + k)/2, in air meeting the disc
## at `v_axial` (m/s, positive climbing) along the shaft and `v_disc` across it. The pair's one inflow, m/s, is what
## its thrust makes (Glauert); each rotor's control, collective or speed, is what gives its share at that inflow. Where
## a control stops short the thrust is less, and the inflow is found again for that.
func _pair_state(p: int, thrust: float, k: float, v_axial: float, v_disc: float) -> void:
	var R := float(spec.radius)
	var A := PI * R * R
	var sa := float(spec.solidity) * float(spec.cl_alpha) * 0.5
	var members: Array[Rotor] = []
	for r in rotors: if r.pair == p: members.append(r)
	var coax := members.size() > 1
	var shares := [0.5 * (1.0 + k), 0.5 * (1.0 - k)] if coax else [1.0]
	var total := maxf(thrust, 0.0)
	var through := v_axial
	for it in 24:
		through = inflow(total / (rho * A), absf(v_disc), v_axial)
		var made := 0.0
		for i in members.size():
			var r := members[i]
			var want := maxf(thrust * float(shares[i]), 0.0)
			r.saturated = false
			if str(spec.control) == "collective":
				r.omega = float(spec.rpm) * TAU / 60.0
				var tip := r.omega * R
				var th := 3.0 * (want / (rho * A * tip * tip * sa) + through / tip * 0.5)
				if th > float(spec.theta_max):
					th = float(spec.theta_max); r.saturated = true
				r.theta = th
			else:
				# A fixed-pitch rotor makes its thrust by speed: T = ρAσa/2 (θ/3·x² − V x/2) in its tip speed x.
				var om_max := float(spec.rpm_max) * TAU / 60.0
				var x := (through * 0.5 + sqrt(through * through * 0.25 + 4.0 * r.theta / 3.0 * want / (rho * A * sa))) / (2.0 * r.theta / 3.0)
				var om := maxf(x / R, IDLE * om_max)
				if om > om_max:
					om = om_max; r.saturated = true
				r.omega = om
			var tip_now := r.omega * R
			r.lam = through / tip_now
			r.mu = absf(v_disc) / tip_now
			r.thrust = maxf(ct_of(r.theta, r.lam), 0.0) * rho * A * tip_now * tip_now
			made += r.thrust
		if absf(made - total) <= 1e-9 * maxf(total, 1e-6): break
		total = 0.5 * (total + made)
	# Power and torque: induced (with the losses), climb, and profile.
	for r in members:
		var tip := r.omega * R
		var induced := KAPPA * (KAPPA_COAX if coax else 1.0) * r.thrust * (through - v_axial)
		var profile := float(spec.solidity) * float(spec.cd0) / 8.0 * (1.0 + PROFILE_MU * r.mu * r.mu) * rho * A * tip * tip * tip
		r.power = maxf(induced + r.thrust * v_axial + profile, 0.0)
		r.torque = r.power / maxf(r.omega, 1e-6)

## The power the rotors need to hover at weight `w` N in still air, W, and the controls they settle at.
func hover_power(weight: float) -> float:
	var pairs := _pairs()
	var total := 0.0
	for p in pairs:
		_pair_state(p, weight / pairs, 0.0, 0.0, 0.0)
	for r in rotors: total += r.power
	return total

## Tip Mach number of the fastest rotor.
func tip_mach() -> float:
	var m := 0.0
	for r in rotors: m = maxf(m, r.omega * float(spec.radius) / sound)
	return m

## FLIGHT

func _step() -> void:
	if crashed: return
	var up_b := DQuat.rotate(DVec3.new(0.0, 1.0, 0.0), q)
	var mass := float(spec.mass)
	var inertia: Vector3 = spec.inertia
	# Air through the rotors: the craft's velocity (still air) along the shaft, positive climbing, and across it.
	var v_axial := vel.dot(up_b)
	var v_disc := vel.clone().add_scaled_in(up_b, -vel.dot(up_b)).length()
	var force := DVec3.new(0.0, -mass * g, 0.0)
	var torque_b := Vector3.ZERO
	var pairs := _pairs()
	if armed and energy_wh > 0.0:
		var ctl := _control(up_b, mass, inertia)
		var thrust_total: float = ctl.thrust
		var tau: Vector3 = ctl.torque
		var per := _pair_thrusts(thrust_total, tau, pairs)
		for p in pairs:
			# Yaw from the difference between a pair's upper and lower rotor torques: more on the rotor that
			# turns against the wanted yaw, whose reaction then turns the body with it.
			# Held at zero while the rotors are not carrying the craft, so a creep on the ground does not wind it up.
			if thrust_total < 0.3 * mass * g: _split[p] = 0.0
			else: _split[p] = clampf(_split[p] - _upper_spin(p) * tau.y * DT * 4.0 / maxf(thrust_total * float(spec.radius), 1e-3), -0.4, 0.4)
			_pair_state(p, per[p], _split[p], v_axial, v_disc)
		var tilt: Vector2 = ctl.cyclic
		for r in rotors:
			var dir := Vector3(tilt.x, 1.0, tilt.y).normalized()
			var f_b := dir * r.thrust
			force.add_in(DQuat.rotate(DVec3.from_v3(f_b), q))
			torque_b += r.at.cross(f_b) - Vector3(0.0, r.spin * r.torque, 0.0)
	else:
		for r in rotors:
			r.thrust = 0.0; r.torque = 0.0; r.power = 0.0
	power_w = float(spec.avionics)
	for r in rotors: power_w += r.power / float(spec.efficiency)
	energy_wh = maxf(energy_wh - power_w * DT / 3600.0, 0.0)
	# The body's own drag.
	var s := vel.length()
	if s > 1e-6: force.add_scaled_in(vel, -0.5 * rho * float(spec.cda) * s)
	# Legs on the ground: a spring, a damper and Coulomb friction, each leg.
	on_ground = false
	var k_leg := mass * g * 40.0
	var c_leg := 2.0 * sqrt(k_leg * mass / 4.0) * 0.6
	for i in spec.legs.size():
		var leg: Vector3 = spec.legs[i]
		var r_s := DQuat.rotate(DVec3.from_v3(leg), q)
		var p := r_s.clone().add_in(pos)
		var gy: float = ground.height(-p.x, p.z)
		var depth := gy - p.y
		leg_load[i] = 0.0
		# Nor is there ground to stand on where the survey ends.
		if not (depth > 0.0): continue
		on_ground = true
		var w_s := DQuat.rotate(w.clone(), q)
		var pv := vel.clone().add_in(w_s.cross(r_s))
		var n := maxf(k_leg * depth - c_leg * pv.y, 0.0)
		leg_load[i] = n
		var fr := DVec3.new(pv.x, 0.0, pv.z)
		var slide := fr.length()
		var f := DVec3.new(0.0, n, 0.0)
		if slide > 1e-6: f.add_scaled_in(fr, -minf(0.8 * n, mass * slide / DT * 0.2) / slide)
		force.add_in(f)
		torque_b += DQuat.rotate(r_s.cross(f), q.clone().invert()).to_v3()
		if pv.y < -6.0: crashed = true
	vel.add_scaled_in(force, DT / mass)
	pos.add_scaled_in(vel, DT)
	# Euler's equations about principal axes.
	var wv := w.to_v3()
	var iw := Vector3(inertia.x * wv.x, inertia.y * wv.y, inertia.z * wv.z)
	var dw := torque_b - wv.cross(iw)
	w.add_in(DVec3.new(dw.x / inertia.x, dw.y / inertia.y, dw.z / inertia.z).scale_in(DT))
	var ang := w.length() * DT
	if ang > 1e-12:
		var dq := DQuat.new().set_from_axis_angle(w.clone().scale_in(1.0 / w.length()), ang)
		q.multiply(dq).normalize_in()
	if DQuat.rotate(DVec3.new(0.0, 1.0, 0.0), q).y < 0.2 and on_ground: crashed = true

# The flight software: the commanded velocity (heading frame) and climb, flown as a thrust vector; the
# attitude that points it, as body torques; and the cyclic that makes them on a single-axis craft.
func _control(up_b: DVec3, mass: float, inertia: Vector3) -> Dictionary:
	var hd := heading()
	var fwd := Vector3(-sin(hd), 0.0, cos(hd))
	var left := Vector3(cos(hd), 0.0, sin(hd))
	var v_want := fwd * clampf(cmd_fwd, -1.0, 1.0) * float(spec.v_max) - left * clampf(cmd_side, -1.0, 1.0) * float(spec.v_max) * 0.5
	v_want.y = clampf(cmd_climb, -1.0, 1.0) * float(spec.climb_max)
	# A laser altimeter, as both craft fly with: with the stick centred, hold the height over the ground
	# below the centre of mass, so rising ground lifts the craft rather than meets it.
	if on_ground and cmd_climb <= 0.0: landed = true
	if cmd_climb > 0.0: landed = false
	if cmd_climb != 0.0 or landed:
		hold_agl = -1.0
	else:
		var below := pos.y - float(ground.height(-pos.x, pos.z))
		if is_nan(below): below = maxf(hold_agl, 1.0)
		if hold_agl < 0.0: hold_agl = below
		v_want.y = clampf((hold_agl - below) * 0.8, -float(spec.climb_max), float(spec.climb_max))
		# Where the ground rises faster than it can climb, it slows across it.
		var keep := clampf(below / maxf(hold_agl, 1.0) * 2.0 - 1.0, 0.1, 1.0)
		v_want.x *= keep
		v_want.z *= keep
	# Where the survey ends there is nothing to fly over: it stops, and may come back.
	var ahead := pos.clone().add_scaled_in(vel, 2.0)
	if is_nan(float(ground.height(-ahead.x, ahead.z))) or is_nan(float(ground.height(-pos.x, pos.z))):
		var inward := Vector3(-pos.x, 0.0, -pos.z).normalized()
		if Vector3(v_want.x, 0.0, v_want.z).dot(inward) <= 0.0:
			v_want.x = 0.0
			v_want.z = 0.0
	var v := vel.to_v3()
	# On the ground a craft asked to stay down sits there; a climb command lifts it off.
	var a := (v_want - v) * Vector3(1.2, 2.5, 1.2)
	if landed: a = Vector3(0.0, -1.0, 0.0)
	var want := a + Vector3(0.0, g, 0.0)
	var tilt_max := float(spec.tilt_max)
	var horiz := Vector2(want.x, want.z)
	if horiz.length() > want.y * tan(tilt_max):
		horiz = horiz.normalized() * want.y * tan(tilt_max)
		want = Vector3(horiz.x, want.y, horiz.y)
	var up_d := want.normalized() if want.y > 0.0 else Vector3.UP
	var thrust := mass * maxf(want.y, 0.0) / maxf(up_b.y, 0.3)
	if landed: thrust = 0.0
	# The attitude: turn body up onto up_d, and yaw at the commanded rate.
	var u := up_b.to_v3()
	var err_s := u.cross(up_d)
	var inv := q.clone().invert()
	var err_b := DQuat.rotate(DVec3.from_v3(err_s), inv).to_v3()
	var wv := w.to_v3()
	var wn := 8.0
	var tau := Vector3(inertia.x * (wn * wn * err_b.x - 2.0 * 0.8 * wn * wv.x),
		inertia.y * 3.0 * (-clampf(cmd_yaw, -1.0, 1.0) * float(spec.yaw_max) - wv.y),
		inertia.z * (wn * wn * err_b.z - 2.0 * 0.8 * wn * wv.z))
	var cyc := Vector2.ZERO
	if float(spec.cyclic_max) > 0.0:
		# Single axis: the thrust leans with the cyclic, its moment arm the hubs' mean height.
		var h := 0.0
		for r in rotors: h += r.at.y / rotors.size()
		var tt := maxf(thrust, mass * g * 0.3)
		cyc = Vector2(clampf(-tau.z / (h * tt), -float(spec.cyclic_max), float(spec.cyclic_max)),
			clampf(tau.x / (h * tt), -float(spec.cyclic_max), float(spec.cyclic_max)))
		tau.x = 0.0; tau.z = 0.0
	return {"thrust": thrust, "torque": tau, "cyclic": cyc}

# Each pair's share of the thrust, less or more to make the roll and pitch torques with their arms.
func _pair_thrusts(total: float, tau: Vector3, pairs: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(pairs)
	var at := []
	var sxx := 0.0; var szz := 0.0
	for p in pairs:
		var c := Vector3.ZERO
		var n := 0
		for r in rotors:
			if r.pair == p: c += r.at; n += 1
		c /= maxf(n, 1)
		at.append(c)
		sxx += c.x * c.x; szz += c.z * c.z
	for p in pairs:
		var c: Vector3 = at[p]
		var share := total / pairs
		if szz > 1e-6: share -= tau.x * c.z / szz
		if sxx > 1e-6: share += tau.z * c.x / sxx
		out[p] = maxf(share, 0.0)
	return out
