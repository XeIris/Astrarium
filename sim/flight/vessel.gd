class_name Vessel
extends RefCounted

# THE VESSEL: state, forces, staging, structure and clocks, in SI, in a frame
# centred on the parent body with axes parallel to the orrery's. This file is the
# AU↔SI boundary: the only place Body.pos / Body.vel become metres.
#
# The frame accelerates with the parent, so gravity carries one extra term:
#     a = Σᵢ GMᵢ (Rᵢ − R_v)/|Rᵢ − R_v|³  −  Σᵢ≠p GMᵢ (Rᵢ − R_p)/|Rᵢ − R_p|³
# The parent's pull stays whole and every other body's becomes a tidal difference
# (LEO feels the Moon, not the Sun's 6e-3 m/s²).
#
# Attitude: body +Y is the thrust axis. The controller is the time-optimal
# rest-to-rest slew, ω_des = sign(e)·min(k|e|, √(2α|e|)), with α from the real
# gimbal deflection and RCS authority.
#
# Vectors are DVec3 and attitude a DQuat (float32 is 0.4 m at planet radius).
# DQuat.nrm / set_len / angle_between reproduce three.js's arithmetic, since
# trajectories are diffed against flightref.mjs. The scratch vectors are static
# and shared, and callers pass them in as `dir`/`out` on purpose. `log_event`, not
# `log` (that would shadow the math function). Telemetry is a Dictionary with
# camelCase keys, read by name by the HUD.

const PHASE := {
	"PRELAUNCH": "prelaunch", "ASCENT": "ascent", "COAST": "coast", "ORBIT": "orbit",
	"BURN": "burn", "ENTRY": "entry", "DESCENT": "descent", "LANDED": "landed",
	"CRUISE": "cruise", "DESTROYED": "destroyed",
}

# The orrery's year in seconds, for the AU/yr → m/s bridge.
const _YR := 3.15576e7
const STEP_GUARD := 400

static var _a := DVec3.new()
static var _b := DVec3.new()
static var _c := DVec3.new()
static var _d := DVec3.new()
static var _e := DVec3.new()
static var _f := DVec3.new()
static var _up := DVec3.new()
static var _vrel := DVec3.new()
static var _g1 := DVec3.new()
static var _g2 := DVec3.new()
static var BODY_FWD := DVec3.new(0.0, 1.0, 0.0)
# RK4 scratch. One set for the whole class: only one vessel integrates at a
# time and the alternative is four vector allocations per substep per frame.
static var _dq := DQuat.new()
static var _k_r0 := DVec3.new()
static var _k_v0 := DVec3.new()
static var _k_r1 := DVec3.new()
static var _k_v1 := DVec3.new()
static var _k_r2 := DVec3.new()
static var _k_v2 := DVec3.new()
static var _k_r3 := DVec3.new()
static var _k_v3 := DVec3.new()
static var _k_a1 := DVec3.new()
static var _k_a2 := DVec3.new()
static var _k_a3 := DVec3.new()
static var _k_a4 := DVec3.new()

static var _next_vessel_id := 1
# Engine-output scratch for propulsion(), _stage_mdot() and authority(), none of
# which calls another.
static var _th1 := Rocketry.Thrust.new()
static var _th2 := Rocketry.Thrust.new()

## What accel() saw at one trial state; sample() turns the last one into telemetry
## and check_structure() judges it.
class Sample extends RefCounted:
	var q: float = 0.0          # dynamic pressure, Pa
	var mach: float = 0.0
	var drag: float = 0.0       # N
	var heat: float = 0.0       # W/m²
	var pa: float = 0.0         # ambient pressure, Pa
	var thrust: float = 0.0     # N
	var mdot: float = 0.0       # kg/s
	var isp: float = 0.0        # s
	var plume = null            # the first lit engine's plume Dictionary
	var engines: int = 0
	var gees: float = 0.0       # sensed acceleration, g (set by sample())
	var alpha: float = 0.0      # angle of attack, rad (set by sample())

## Every lit stage together; `plume` is the first one's look. propulsion() refills
## the same instance on every call, so read it before calling again.
class Propulsion extends RefCounted:
	var F: float = 0.0
	var mdot: float = 0.0
	var isp: float = 0.0
	var plume = null
	var count: int = 0

## One stage's live state: `pending` until ignition, `live` while attached, gone
## once jettisoned. Propellant is per stage.
class StageState extends RefCounted:
	var spec: Dictionary          # the vehicle's stage Dictionary
	var index: int
	var prop: float
	var prop0: float
	var ignited: bool
	var attached: bool = true
	var spent: bool
	var restarts: int
	var rcs_prop: float
	## Engines running on this stage. Shutdown is a non-throttleable engine's only
	## throttle (the Saturn V cut its centre F-1 at T+135 s and centre J-2 at T+460 s).
	var live: int
	var gear_out: bool = false    # spaceflight's G key toggles it

	func _init(s: Dictionary, i: int) -> void:
		spec = s; index = i
		prop = s.prop; prop0 = s.prop
		ignited = i == 0 or s.get("liftoff", false)
		spent = s.prop <= 0.0 and s.get("engine") == null
		restarts = s.get("restarts", 0)
		rcs_prop = s.rcs.prop if s.get("rcs") != null else 0.0
		live = s.count

var id: int
var vehicle: Dictionary
var name: String
var payload_mass: float
var vehicle_key: String = ""        # set by spaceflight
var stages: Array = []              # of StageState
var stage_index: int = 0            # the lowest still-attached stage

# ---- kinematics (SI, parent-centred)
var r := DVec3.new()
var v := DVec3.new()
var q := DQuat.new()
var omega := DVec3.new()            # body rates, world axes, rad/s
var _hold := DVec3.new()            # the attitude point_at asked for this frame (see step's rails branch)
var _prev_dir := DVec3.new()        # the last direction point_at was given, and when (for its rate)
var _prev_met := -1.0
var _w_t := DVec3.new()             # the target direction's own angular velocity, rad/s
var _holding := false
var throttle: float = 0.0
var rcs_on: bool = true

# ---- clocks. `met` is proper time, `coord` coordinate time; `clock_delta` is the
# difference against a clock on the parent's surface at the launch site (GPS:
# +38.7 µs/day in LEO; years at 0.99c).
var met: float = 0.0
var coord: float = 0.0
var clock_delta: float = 0.0
var time_rate: float = 1.0
var step_guard_hit := false

# ---- telemetry / records
var max_q: float = 0.0
var max_q_t: float = 0.0            # T+ (s after liftoff), altitude and Mach of the max-Q
var max_q_alt: float = 0.0
var max_q_mach: float = 0.0
var max_mach: float = 0.0
var max_g: float = 0.0
var heat_load: float = 0.0
var peak_heat: float = 0.0
var downrange: float = 0.0
var phase: String = PHASE.PRELAUNCH
var failure = null                  # String or null
var events: Array = []              # [{t, msg}]
var _logged := {}                   # the one-shot milestones already in the log (see _milestones)
var _peak_heat_alt: float = 0.0
var _peak_heat_v: float = 0.0
var _peak_heat_seen: float = 0.0
var stage_events: int = 0
var landed_at = null                # {met, vVert, vHoriz} or null
var t0: float = 0.0                 # MET of liftoff

# ---- frame
var parent: Body = null
var env = null                      # Rocketry.flight_env(parent) Dictionary
var bodies: Array = []              # of Body

var telemetry: Dictionary = {}
var held_down: bool = false
var launch_site = null              # {lat, lon, r: DVec3, v: DVec3} or null
var chute_open = null               # the stage's chute Dictionary while deployed
var chute_deploy: float = 0.0       # 0..1 inflation
var bank = null                     # lift bank angle, rad; null = π/3
var auto_stage: bool = false
var pending_stage: bool = false
var _prop := Propulsion.new()

## opts: { vehicle: Dictionary, name?: String, parent: Body, bodies: Array[Body],
## payload?: float }.
func _init(opts: Dictionary) -> void:
	id = _next_vessel_id
	_next_vessel_id += 1
	vehicle = opts.vehicle
	name = opts.get("name") if opts.get("name") else vehicle.name
	payload_mass = opts.get("payload", 0.0)
	var i := 0
	for s in vehicle.stages:
		stages.append(StageState.new(s, i))
		i += 1
	stage_index = 0
	set_parent(opts.parent, opts.get("bodies"))
	telemetry = {}

# Parent / frame
func set_parent(body: Body, bods) -> void:
	parent = body
	env = Rocketry.flight_env(body) if body != null else null
	bodies = bods if bods != null else []

## Place the vessel on the launch pad: on the surface, turning with it.
func place_on_pad(lat_deg: float = 28.5, lon_deg: float = 0.0) -> Vessel:
	var lat := lat_deg * PI / 180.0
	var lon := lon_deg * PI / 180.0
	# The pole is −Y (see orbit.gd), so "north" is −Y and the equator is the XZ
	# plane — the same plane the orrery lays its orbits in.
	var cl := cos(lat)
	r.set_v(env.radius * cl * cos(lon), -env.radius * sin(lat), env.radius * cl * sin(lon))
	# Surface velocity ω × r, ω along −Y (465 m/s at Earth's equator).
	_a.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_a, r)
	v.copy_from(_a)
	# Nose up.
	DQuat.nrm(_up.copy_from(r))
	q.set_from_unit_vectors(BODY_FWD, _up)
	omega.set_v(0.0, 0.0, 0.0)
	phase = PHASE.PRELAUNCH
	held_down = false
	launch_site = { "lat": lat, "lon": lon, "r": r.clone(), "v": v.clone() }
	return self

## Place the vessel on a circular orbit of altitude `alt_m`.
func place_in_orbit(alt_m: float, inc_deg: float = 0.0, phase_rad: float = 0.0) -> Vessel:
	var R: float = env.radius + alt_m
	var inc := inc_deg * PI / 180.0
	var vc := sqrt(env.mu / R)
	r.set_v(R * cos(phase_rad), 0.0, R * sin(phase_rad))
	v.set_v(-vc * sin(phase_rad) * cos(inc), vc * sin(inc), vc * cos(phase_rad) * cos(inc))
	q.set_from_unit_vectors(BODY_FWD, DQuat.nrm(_a.copy_from(v)))
	omega.set_v(0.0, 0.0, 0.0)
	phase = PHASE.ORBIT
	return self

# Mass properties
var mass: float:
	get:
		var m := payload_mass
		for st in stages:
			if st.attached: m += st.spec.dry + st.prop + st.rcs_prop
		return m

## Length of what is still attached — used for the moment of inertia and for
## where the plume comes out.
var length: float:
	get:
		var L := 0.0
		for st in stages:
			if st.attached: L += st.spec.L
		return L

var diameter: float:
	get:
		var D := 0.0
		for st in stages:
			if st.attached: D = maxf(D, st.spec.D)
		return D

## Frontal reference area: the widest live stage. A fairing is wider than the
## rocket under it, which is why jettisoning it is worth Δv.
var area: float:
	get:
		var A := 0.0
		for st in stages:
			if st.attached: A = maxf(A, st.spec.area)
		return A

## Transverse and roll inertia, treating the stack as a uniform slender cylinder.
## Returns { pitch, roll }.
func inertia() -> Dictionary:
	var m := mass
	var L := maxf(length, 0.5)
	var R := maxf(diameter / 2.0, 0.25)
	return { "pitch": m * (L * L / 12.0 + R * R / 4.0), "roll": m * R * R / 2.0 }

# Propulsion
func live_stages() -> Array:
	var out := []
	for s in stages:
		if s.attached and s.ignited and not s.spent: out.append(s)
	return out

## A photon drive holds constant proper acceleration: F = m·a, ṁ = F/c. The plate's
## rating is a ceiling, so a ship too heavy for it accelerates at less.
func photon_output(engine: Dictionary, n: float, out: Rocketry.Thrust = null) -> Rocketry.Thrust:
	if out == null: out = Rocketry.Thrust.new()
	var th: float = 0.0 if throttle <= 0.0 \
		else minf(maxf(throttle, engine.get("throttleMin", 1.0)), engine.get("maxThrottle", 1.0))
	if th <= 0.0 or n <= 0.0: return out.set_to(0.0, 0.0, engine.ispVac, 0.0)
	var F: float = minf(engine.holdAccel * maxf(mass, 1.0), engine.thrustVac * n) * th
	return out.set_to(F, F / Rocketry.C_MS, engine.ispVac, th)

## Total thrust (N) and flow (kg/s) right now, at ambient pressure `pa`.
func propulsion(pa: float) -> Propulsion:
	var F := 0.0
	var mdot := 0.0
	var isp_sum := 0.0
	var w := 0.0
	var plume = null
	var count := 0
	for st in stages:
		if not st.attached or not st.ignited or st.spent: continue
		var s: Dictionary = st.spec
		if s.get("engine") == null or st.prop <= 0.0: continue
		var burned: float = 1.0 - st.prop / maxf(st.prop0, 1.0)
		var o: Rocketry.Thrust = photon_output(s.engine, st.live, _th1) \
			if (s.engine.get("photon", false) and s.engine.get("holdAccel", 0.0) > 0.0) \
			else Rocketry.engine_output(s.engine, st.live, pa, throttle, burned, _th1)
		if s.get("vacEngine") != null:
			var ov := Rocketry.engine_output(s.vacEngine, s.vacCount, pa, throttle, burned, _th2)
			o.F += ov.F; o.mdot += ov.mdot
		F += o.F; mdot += o.mdot; isp_sum += o.isp * o.F; w += o.F
		count += st.live + int(s.get("vacCount", 0))
		if plume == null: plume = s.engine.plume
	var out := _prop
	out.F = F; out.mdot = mdot; out.isp = isp_sum / w if w > 0.0 else 0.0
	out.plume = plume; out.count = count
	return out

## The thrust axis in world coordinates. `out` defaults to the shared scratch _a.
func forward(out: DVec3 = null) -> DVec3:
	if out == null: out = _a
	return DQuat.rotate(out.copy_from(BODY_FWD), q)

# Forces

## Gravity in the parent-centred non-inertial frame. See the module header.
func gravity(rr: DVec3, out: DVec3) -> DVec3:
	out.set_v(0.0, 0.0, 0.0)
	var p := parent
	if p == null: return out
	for b in bodies:
		if not b.alive: continue
		var gm: float = Rocketry.GM_SUN * b.mass
		# offset of body b from the parent, m. Private scratch: callers pass the shared
		# temporaries as `out`.
		_g1.sub_vectors(b.pos, p.pos).scale_in(Rocketry.AU_M)
		# pull on the vessel
		_g2.copy_from(_g1).sub_in(rr)
		var d2 := _g2.length_sq()
		if d2 > 1e-6: out.add_scaled_in(_g2, gm / (d2 * sqrt(d2)))
		# pull on the frame origin — every body except the parent itself
		if b == p: continue
		var D2 := _g1.length_sq()
		if D2 > 1e-6: out.add_scaled_in(_g1, -gm / (D2 * sqrt(D2)))
	return out

## Altitude above the parent's mean surface, in metres.
func altitude(rr: DVec3 = null) -> float:
	if rr == null: rr = r
	return rr.length() - env.radius

## Velocity relative to the rotating atmosphere, for drag, Mach and heating.
func airspeed(rr: DVec3, vv: DVec3, out: DVec3) -> DVec3:
	_d.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_d, rr)
	return out.sub_vectors(vv, _d)

func _first_attached():
	for s in stages:
		if s.attached: return s
	return null

## Total acceleration at a trial state (four times per RK4 step, so into scratch).
## `sample`, if given, receives what the forces were.
func accel(rr: DVec3, vv: DVec3, out: DVec3, sample: Sample = null) -> DVec3:
	gravity(rr, out)
	var atm = env.atm
	var h := altitude(rr)
	var pa := Rocketry.pressure(atm, h) if atm != null else 0.0

	# ---- thrust
	var prop := propulsion(pa)
	var m := maxf(mass, 1.0)
	if prop.F > 0.0: out.add_scaled_in(forward(_e), prop.F / m)

	# ---- aerodynamics
	var qd := 0.0
	var mach := 0.0
	var drag := 0.0
	var heat := 0.0
	if atm != null and h < atm.top:
		var rho := Rocketry.density(atm, h)
		airspeed(rr, vv, _vrel)
		var va := _vrel.length()
		if rho > 0.0 and va > 0.5:
			qd = 0.5 * rho * va * va
			mach = va / Rocketry.speed_of_sound(atm, h)
			var st = _first_attached()
			var cd := Rocketry.blunt_drag_coefficient(mach) if (st != null and st.spec.get("blunt", false)) else Rocketry.drag_coefficient(mach)
			# Angle of attack costs drag. cos²α is the standard slender-body form,
			# and it is why flying off-prograde in thick air is expensive.
			var fwd := forward(_f)
			var cos_a := absf(fwd.dot(_vrel) / va)
			var cd_eff := cd * (1.0 + 2.2 * (1.0 - cos_a * cos_a))
			drag = qd * cd_eff * area
			out.add_scaled_in(_vrel, -drag / (m * va))
			# Parachutes, if any are out.
			if chute_open != null:
				var ch: Dictionary = chute_open
				out.add_scaled_in(_vrel, -(qd * ch.Cd * ch.area * chute_deploy) / (m * va))
				drag += qd * ch.Cd * ch.area * chute_deploy
			# Blunt-body lift: a Mars aeroshell's offset CoM trims it to L/D ≈ 0.24, and it
			# banks that lift to steer.
			var bl = null
			for s2 in stages:
				if s2.attached and s2.spec.get("lift") != null:
					bl = s2; break
			if bl != null and drag > 0.0:
				DQuat.nrm(_c.copy_from(rr))                    # local up
				_c.add_scaled_in(_vrel, -_c.dot(_vrel) / (va * va))
				if _c.length_sq() > 1e-12:
					# Bank: 60° puts half the lift into the vertical (MSL's range control).
					var bnk: float = bank if bank != null else PI / 3.0
					out.add_scaled_in(DQuat.nrm(_c), (drag * bl.spec.lift.LD * cos(bnk)) / m)
			# Wing or body-flap lift: perpendicular to the airstream, in the plane of the body axis.
			var wing = null
			for s3 in stages:
				if not s3.attached or not s3.ignited or s3.spent: continue
				if s3.spec.get("wings") != null or s3.spec.get("flaps", 0):
					wing = s3; break
			if wing != null and cos_a < 0.999:
				var alpha := acos(DQuat.jclamp(cos_a, -1.0, 1.0))
				var cl_max: float = wing.spec.wings.clMax if wing.spec.get("wings") != null else 1.1
				var area_w: float = wing.spec.wings.area if wing.spec.get("wings") != null else area * 2.2
				# Thin-aerofoil-ish: linear to the stall angle, then flat.
				var cl := cl_max * sin(2.0 * minf(alpha, 0.6))
				var L := qd * cl * area_w
				# lift direction = component of the body axis perpendicular to v
				_c.copy_from(fwd).add_scaled_in(_vrel, -fwd.dot(_vrel) / (va * va))
				if _c.length_sq() > 1e-12: out.add_scaled_in(DQuat.nrm(_c), L / m)
			var nose_r := diameter * 0.25
			var fa = _first_attached()
			if fa != null and fa.spec.get("heatShield") != null and fa.spec.heatShield.get("noseR") != null:
				nose_r = fa.spec.heatShield.noseR
			heat = Rocketry.heat_flux(rho, va, nose_r)
	if sample != null:
		sample.q = qd; sample.mach = mach; sample.drag = drag; sample.heat = heat; sample.pa = pa
		sample.thrust = prop.F; sample.mdot = prop.mdot; sample.isp = prop.isp; sample.plume = prop.plume
		sample.engines = prop.count
	return out

# Attitude

## Achievable angular acceleration about a transverse axis, rad/s². Gimbal only
## while lit. Returns { alpha, tau, I }.
func authority(pa: float) -> Dictionary:
	var I := inertia()
	var L := maxf(length, 1.0)
	var tau := 0.0
	var gimballed := false
	# RCS on every attached stage, lit or not (the orbiter turns the stack before OMS
	# fires).
	for st in stages:
		if not st.attached: continue
		var s: Dictionary = st.spec
		var lit: bool = st.ignited and not st.spent
		if lit and s.get("engine") != null and st.prop > 0.0 and throttle > 0.0 and s.gimbalDeg > 0.0:
			var o := Rocketry.engine_output(s.engine, st.live, pa, throttle, 0.0, _th1)
			# The gimbal acts at the engine plane, roughly a half-length from the
			# centre of mass.
			tau += o.F * sin(s.gimbalDeg * PI / 180.0) * (L * 0.45)
			gimballed = gimballed or o.F > 0.0
		if rcs_on and s.get("rcs") != null and st.rcs_prop > 0.0:
			# A quarter of the thrusters bear on any one axis, at a lever arm of
			# roughly the radius plus a fraction of the length.
			tau += s.rcs.thrust * maxf(float(s.rcs.count) / 4.0, 1.0) * (diameter * 0.5 + L * 0.25)
	return { "alpha": tau / maxf(I.pitch, 1.0), "tau": tau, "I": I, "gimballed": gimballed }

## Steer the +Y axis toward a world direction; returns the pointing error, rad.
## Time-optimal rest-to-rest: never command a rate that can't be stopped within the
## remaining error.
func point_at(dir, dt: float, pa: float, _roll_ref = null) -> float:
	if dir == null or dir.length_sq() < 1e-12: return 0.0
	DQuat.nrm(_a.copy_from(dir))
	_hold.copy_from(_a); _holding = true
	var fwd := forward(_b)
	var err := DQuat.angle_between(fwd, _a)
	if dt <= 0.0: return err
	var auth := authority(pa)
	var alpha: float = auth.alpha
	# Feed-forward: a held attitude usually turns (prograde, a pitch program), so the
	# target's own rate is measured from its last direction and the law works on the
	# rate relative to it. Without this the controller stops in its deadband, falls
	# behind, and fires every few seconds.
	_w_t.set_v(0.0, 0.0, 0.0)
	if _prev_met >= 0.0 and met > _prev_met and DQuat.angle_between(_prev_dir, _a) < 0.05:
		_w_t.cross_vectors(_prev_dir, _a).scale_in(1.0 / (met - _prev_met))
	_prev_dir.copy_from(_a); _prev_met = met
	if alpha <= 0.0: return err
	omega.add_scaled_in(_w_t, -1.0)          # from here on, omega is relative
	# rotation axis
	_c.cross_vectors(fwd, _a)
	if _c.length_sq() < 1e-14:
		# exactly 180° out — any perpendicular axis will do
		_c.set_v(fwd.y, -fwd.x, 0.0)
		if _c.length_sq() < 1e-14: _c.set_v(0.0, fwd.z, -fwd.y)
	DQuat.nrm(_c)
	# Deadband: once pointed, only stop turning, so gated logic doesn't flicker.
	if err < 0.004:
		var w := omega.length()
		if w > 1e-6: omega.scale_in(maxf(0.0, 1.0 - minf(alpha * dt / w, 1.0)))
		omega.add_in(_w_t)
		return err
	var w_max := minf(sqrt(2.0 * alpha * err), 0.35)   # rad/s cap: real vehicles are slow
	# current rate about the error axis
	var w_now := omega.dot(_c)
	# Command the profile rate; the residual is corrected by the same law next
	# step, which is what makes it settle instead of ringing.
	var dw := DQuat.jclamp(w_max - w_now, -alpha * dt, alpha * dt)
	omega.add_scaled_in(_c, dw)
	# Damp any rate that is not about the error axis — this is the RCS holding
	# attitude, and it is why a spacecraft does not tumble after a slew.
	_d.copy_from(omega).add_scaled_in(_c, -omega.dot(_c))
	var damp := minf(alpha * dt, _d.length())
	if _d.length_sq() > 1e-16: omega.add_scaled_in(DQuat.nrm(_d), -damp)
	# RCS costs propellant only when no gimballed engine is lit.
	if not auth.gimballed: spend_rcs(absf(dw) * inertia().pitch, dt)
	omega.add_in(_w_t)
	return err

## Integrate the attitude by the current body rates.
func spin(dt: float) -> void:
	var w := omega.length()
	if w < 1e-9: return
	_a.copy_from(omega).scale_in(1.0 / w)
	_dq.set_from_axis_angle(_a, w * dt)
	q.premultiply(_dq).normalize_in()

## Book an RCS impulse against the tanks. Torque impulse → propellant.
func spend_rcs(angular_impulse: float, _dt: float) -> void:
	for st in stages:
		if not st.attached: continue
		var rcs = st.spec.get("rcs")
		if rcs == null or st.rcs_prop <= 0.0: continue
		var arm := diameter * 0.5 + length * 0.25
		var mdot: float = angular_impulse / maxf(arm * Rocketry.G0 * rcs.isp, 1e-6)
		st.rcs_prop = maxf(0.0, st.rcs_prop - mdot)
		return

# Staging

## Fire the next staging event; returns the dropped StageState, or null. First drop
## the lowest attached stage with nothing left to give, then light the lowest unlit
## one (the other order lights inside the interstage). `sep: 'none'` stages are never
## dropped but can still ignite. `force` drops a stage with propellant left (the
## Shuttle ET after MECO).
func stage(force := false):
	var dropped = null
	for st in stages:
		if not st.attached: continue
		var done: bool = st.spec.get("engine") == null or st.prop <= 1e-6
		# The lowest attached stage still has propellant and is lit: nothing at
		# the bottom is finished, so this event only ignites.
		if not done and st.ignited and not force: break
		if st.spec.sep == "none": break
		st.attached = false; st.spent = true
		dropped = st; stage_events += 1
		log_event(("Fairing separation — %s away" if st.spec.sep == "fairing" else "Staging — %s away") % st.spec.name + _where())
		break
	# Light the next stage only if nothing is still burning.
	var still_burning := false
	if dropped != null:
		for st in stages:
			if st.attached and st.ignited and not st.spent and st.spec.get("engine") != null and st.prop > 0.0:
				still_burning = true
				break
	for st in stages:
		if still_burning: break
		if not st.attached or st.ignited or st.spec.get("engine") == null: continue
		st.ignited = true
		log_event("Ignition — %s" % st.spec.name)
		break
	stage_index = -1
	for i in stages.size():
		if stages[i].attached:
			stage_index = i; break
	return dropped

## Shut down `n` engines, symmetrically: the centre first, then pairs.
func shutdown_engines(n: int = 1) -> int:
	var st = current_stage
	if st == null or st.live <= 1: return 0
	var off := mini(n, st.live - 1)
	st.live -= off
	log_event("Engine shutdown — %d of %d on %s (%d running)" % [off, st.spec.count, st.spec.name, st.live])
	return off

## Set the burning stage's engine count (Falcon 9: three for entry, one to land).
## Shutdown is reversible.
func set_engine_count(n: float) -> int:
	var st = current_stage
	if st == null or not st.spec.count: return 0
	var want := maxi(1, mini(int(n), st.spec.count))
	if want == st.live: return st.live
	log_event(("Engine relight — %d of %d on %s" % [want, st.spec.count, st.spec.name]) if want > st.live
		else ("Engine shutdown — %d of %d on %s (%d running)" % [st.live - want, st.spec.count, st.spec.name, want]))
	st.live = want
	return st.live

## Drop a specific stage by key — used by the scripted sequences (heat-shield
## jettison, backshell separation, sky-crane release).
func jettison(key: String):
	var st = null
	for s in stages:
		if s.spec.key == key and s.attached:
			st = s; break
	if st == null: return null
	st.attached = false; st.spent = true; stage_events += 1
	log_event("Separation — %s" % st.spec.name + _where())
	return st

var current_stage:
	get:
		for s in stages:
			if s.attached and s.ignited and not s.spent: return s
		return null

var next_stage:
	get:
		for s in stages:
			if s.attached and not s.ignited and s.spec.get("engine") != null: return s
		return null

## Δv remaining in everything still attached, from the rocket equation.
func delta_v_remaining(pa: float = 0.0) -> float:
	var dv := 0.0
	# Walk from the top down so each stage's payload is what is above it.
	var above := payload_mass
	var live := []
	for s in stages:
		if s.attached: live.append(s)
	for i in range(live.size() - 1, -1, -1):
		var st = live[i]
		above += st.spec.dry + st.rcs_prop
		if st.spec.get("engine") != null and st.prop > 0.0:
			var ve: float = Rocketry.G0 * (st.spec.engine.ispSL if pa > 0.0 else st.spec.engine.ispVac)
			dv += ve * log((above + st.prop) / above)
		above += st.prop
	return dv

# Structure
## Four ways to lose a vehicle, each against a real limit. A failure destroys the
## vessel and says which.
func check_structure(s: Sample, _dt: float) -> void:
	var lim: Dictionary = vehicle.limits
	if phase == PHASE.DESTROYED: return
	var sq := s.q
	var sg := s.gees
	var sa := s.alpha
	var sh := s.heat
	if sq > lim.maxQ:
		destroy("aerodynamic breakup — %s kPa exceeded the %s kPa airframe limit" % [U.fixed(sq / 1000.0, 1), U.fixed(lim.maxQ / 1000.0, 0)]); return
	if sg > lim.maxG:
		destroy("structural failure — %s g exceeded the %s g limit" % [U.fixed(sg, 1), js_num(lim.maxG)]); return
	if sq * sa > lim.qAlpha:
		destroy("loss of control — q·α of %s kPa·rad exceeded %s" % [U.fixed(sq * sa / 1000.0, 1), U.fixed(lim.qAlpha / 1000.0, 0)]); return
	if lim.heatLoad > 0.0 and heat_load > lim.heatLoad:
		destroy("thermal failure — %s MJ/m² burned through the shield" % U.fixed(heat_load / 1e6, 0)); return
	# No shield: bare aluminium fails around 80 W/cm².
	if lim.heatLoad == 0.0 and sh > 8e5:
		destroy("burned up on entry — %s W/cm² on a vehicle with no heat shield" % U.fixed(sh / 1e4, 0)); return

func destroy(why: String) -> void:
	if phase == PHASE.DESTROYED: return
	phase = PHASE.DESTROYED
	failure = why
	throttle = 0.0
	log_event("LOSS OF VEHICLE — %s" % why)

## " · 62.1 km, 2.45 km/s" — where a staging or a cutoff happened, which is
## most of what makes one line of a flight log worth reading.
func _where() -> String:
	return " · %s km, %s km/s" % [U.fixed(altitude() / 1000.0, 1), U.fixed(v.length() / 1000.0, 2)]

## Milestones, each logged once. Max-Q and peak heating are logged once the value has
## fallen 10% (20% for heating) off its peak, reporting the peak and its T+.
func _milestones(t: Dictionary) -> void:
	if phase == PHASE.PRELAUNCH or phase == PHASE.LANDED or phase == PHASE.DESTROYED: return
	if env.atm == null: return
	var alt: float = t.alt
	if not _logged.has("mach1") and t.mach >= 1.0 and t.vertical > 0.0:
		_logged.mach1 = true
		log_event("Mach 1 — supersonic at %s km" % U.fixed(alt / 1000.0, 1))
	if not _logged.has("maxq") and max_q > 5000.0 and t.q < 0.9 * max_q:
		_logged.maxq = true
		log_event("Max-Q — %s kPa at T+%s s · %s km, Mach %s" % [U.fixed(max_q / 1000.0, 1),
			U.fixed(max_q_t, 1), U.fixed(max_q_alt / 1000.0, 1), U.fixed(max_q_mach, 2)])
	if not _logged.has("karman") and alt >= env.karman and t.vertical > 0.0:
		_logged.karman = true
		log_event("Space — through the Kármán line at %s km/s" % U.fixed(t.speed / 1000.0, 2))
	if t.heat > _peak_heat_seen:
		_peak_heat_seen = t.heat; _peak_heat_alt = alt; _peak_heat_v = t.speed
	if not _logged.has("heat") and _peak_heat_seen > 5e4 and t.heat < 0.8 * _peak_heat_seen:
		_logged.heat = true
		log_event("Peak heating — %s W/cm² at %s km, %s km/s" % [U.fixed(_peak_heat_seen / 1e4, 1),
			U.fixed(_peak_heat_alt / 1000.0, 1), U.fixed(_peak_heat_v / 1000.0, 2)])

## Append to the event log the HUD shows, capped at 120.
func log_event(msg: String) -> void:
	events.append({ "t": met, "msg": msg })
	if events.size() > 120: events.pop_front()

## A number printed without a trailing .0 (6 → "6", 4.5 → "4.5").
static func js_num(x: float) -> String:
	if x == floor(x) and absf(x) < 1e15: return str(int(x))
	return str(x)

# Clocks
## Advance the proper-time clocks:
##   dτ/dt = √(1 − v²/c² − 2Φ/c²)
## with Φ the Newtonian potential summed over every body. The difference against a
## ground clock uses √A − √B = (A − B)/(√A + √B), avoiding cancellation.
func step_clocks(dt: float) -> void:
	var c2 := Rocketry.C_MS * Rocketry.C_MS
	# vessel: speed in the coordinate frame = parent's own speed + local v
	_a.copy_from(parent.vel).scale_in(Rocketry.AU_M / _YR).add_in(v)
	var v_ship2 := _a.length_sq()
	var phi_ship := potential(r)
	# ground reference: a clock on the parent's surface at the launch latitude
	var site: DVec3 = launch_site.r if launch_site != null else DQuat.set_len(_b.copy_from(r), env.radius)
	_c.copy_from(parent.vel).scale_in(Rocketry.AU_M / _YR)
	_d.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_d, site)
	var v_gnd2 := _c.add_in(_d).length_sq()
	var phi_gnd := potential(site)

	var A := maxf(1.0 - v_ship2 / c2 - 2.0 * phi_ship / c2, 1e-12)
	var B := maxf(1.0 - v_gnd2 / c2 - 2.0 * phi_gnd / c2, 1e-12)
	var rate := sqrt(A)
	met += dt * rate
	coord += dt
	# (A − B) is formed from differences of the *terms*, never of the rates.
	var dA := (v_gnd2 - v_ship2) / c2 - 2.0 * (phi_ship - phi_gnd) / c2
	clock_delta += dt * dA / (rate + sqrt(B))
	time_rate = rate

## Newtonian potential (negative, J/kg) at a parent-frame position.
func potential(rr: DVec3) -> float:
	var phi := 0.0
	_f.copy_from(rr)
	for b in bodies:
		if not b.alive: continue
		_e.sub_vectors(b.pos, parent.pos).scale_in(Rocketry.AU_M).sub_in(_f)
		var br: float = b.radius if (b.radius != 0.0 and not is_nan(b.radius)) else 1e-9
		var d := maxf(_e.length(), br * Rocketry.AU_M * 0.5)
		phi -= Rocketry.GM_SUN * b.mass / d
	return phi

# Stepping

## Advance `dt` seconds; opts.rails = true asks for the analytic conic. Rails only
## unpowered, out of the air and off the ground, since thrust and drag aren't
## evaluated there. Entering and leaving rails re-seeds from the analytic state.
## Returns the coordinate time advanced; the guard can shorten an RK4 step.
## opts.advance_world(seconds) accepts world time before each vessel interval;
## opts.controls runs only for an interval accepting positive time.
func step(dt: float, opts: Dictionary = {}) -> float:
	var was_guarded := step_guard_hit
	step_guard_hit = false
	if phase == PHASE.DESTROYED:
		dt = _advance_world(dt, opts)
		coord += dt
		return dt
	if phase == PHASE.LANDED and throttle <= 0.0:
		dt = _advance_world(dt, opts)
		if phase == PHASE.DESTROYED:
			coord += dt
			return dt
		# Landed: sit on the surface, turning with it. +Ω dt, not −: with ω on −Y only the
		# positive sign agrees with ω × r (see guidance.gd spin_site).
		var w: float = env.rotRate * dt
		var cw := cos(w)
		var sw := sin(w)
		var x := r.x
		var z := r.z
		r.set_v(x * cw - z * sw, r.y, x * sw + z * cw)
		_a.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_a, r)
		v.copy_from(_a)
		step_clocks(dt)
		sample(0.0)
		return dt

	if opts.get("rails", false) and can_rail():
		var rail_r := DVec3.new()
		var rail_v := DVec3.new()
		# A failed conic must leave the world budget available to RK4.
		if Orbit.propagate(r, v, env.mu, dt, rail_r, rail_v):
			var requested := dt
			var rail_parent := parent
			dt = _advance_world(dt, opts)
			if phase == PHASE.DESTROYED:
				coord += dt
				return dt
			if (dt != requested or parent != rail_parent) and not Orbit.propagate(r, v, env.mu, dt, rail_r, rail_v):
				phase = PHASE.DESTROYED
				coord += dt
				log_event("Analytic orbit failed after world time was accepted — flight stopped")
				return dt
			r.copy_from(rail_r); v.copy_from(rail_v)
			# On rails, hold whatever point_at last asked for (nothing integrates attitude).
			if _holding and authority(0.0).alpha > 0.0:
				_dq.set_from_unit_vectors(forward(_b), _hold)
				q.premultiply(_dq).normalize_in()
				omega.set_v(0.0, 0.0, 0.0)
			_holding = false
			step_clocks(dt)
			sample(dt)
			check_soi()
			return dt

	# ---- RK4, with the substep bounded by how fast the state is changing.
	var remaining := dt
	var elapsed := 0.0
	var guard := 0
	var s := Sample.new()
	while remaining > 1e-9 and guard < STEP_GUARD:
		guard += 1
		var h := minf(remaining, step_bound())
		# A frame's pending guidance can ignite an engine at the accepted boundary.
		if opts.get("control_may_thrust", false): h = minf(h, 0.25)
		h = _advance_world(h, opts)
		if h <= 0.0: break
		if phase == PHASE.DESTROYED:
			coord += elapsed + h
			return elapsed + h
		rk4(h, s)
		remaining -= h
		elapsed += h
	step_guard_hit = remaining > 1e-9
	if not step_guard_hit and not opts.get("advance_world", Callable()).is_valid(): elapsed = dt
	step_clocks(elapsed)
	sample(elapsed, s)
	auto_jettison()
	check_soi()
	contact(elapsed)
	if step_guard_hit and not was_guarded:
		log_event("Flight integrator limit — advanced %s of %s s; reduce time warp" % [U.fixed(elapsed, 3), U.fixed(dt, 3)])
	return elapsed

func _advance_world(seconds: float, opts: Dictionary) -> float:
	var advance: Callable = opts.get("advance_world", Callable())
	if advance.is_valid():
		var accepted: float = advance.call(seconds)
		if accepted < seconds - maxf(1e-9, seconds * 1e-12): step_guard_hit = true
		seconds = clampf(accepted, 0.0, seconds)
	var controls: Callable = opts.get("controls", Callable())
	if seconds > 0.0 and controls.is_valid(): controls.call(seconds)
	return seconds

## Conditional separations. The fairing goes when free-molecular heating drops below
## ~1135 W/m² (usually near 110 km), so a lofted trajectory sheds it earlier.
func auto_jettison() -> void:
	for st in stages:
		var j = st.spec.get("jettisonAt")
		if j == null or not st.attached: continue
		var t := telemetry
		if j.get("heat") != null and t.get("heat") != null and t.heat < j.heat and altitude() > 60000.0:
			jettison(st.spec.key)
		elif j.get("alt") != null and altitude() > j.alt:
			jettison(st.spec.key)

## Largest safe substep, seconds.
func step_bound() -> float:
	var alt := altitude()
	var atm = env.atm
	# In the air, move at most a fraction of a scale height per step.
	if atm != null and alt < atm.top:
		var H := Rocketry.scale_height(atm, maxf(alt, 0.0))
		var vv := maxf(v.length(), 1.0)
		return DQuat.jclamp(0.02 * H / vv, 0.004, 0.5)
	if throttle > 0.0: return 0.25
	# Ballistic: a fraction of the local orbital period.
	var R := maxf(r.length(), env.radius)
	var T: float = 2.0 * PI * sqrt(R * R * R / env.mu)
	return DQuat.jclamp(T / 900.0, 0.05, 60.0)

func rk4(h: float, s: Sample) -> void:
	var r0 := _k_r0.copy_from(r)
	var v0 := _k_v0.copy_from(v)
	accel(r0, v0, _k_a1, s)
	_k_r1.copy_from(r0).add_scaled_in(v0, h / 2.0)
	_k_v1.copy_from(v0).add_scaled_in(_k_a1, h / 2.0)
	accel(_k_r1, _k_v1, _k_a2)
	_k_r2.copy_from(r0).add_scaled_in(_k_v1, h / 2.0)
	_k_v2.copy_from(v0).add_scaled_in(_k_a2, h / 2.0)
	accel(_k_r2, _k_v2, _k_a3)
	_k_r3.copy_from(r0).add_scaled_in(_k_v2, h)
	_k_v3.copy_from(v0).add_scaled_in(_k_a3, h)
	accel(_k_r3, _k_v3, _k_a4)

	r.add_scaled_in(v0, h / 6.0).add_scaled_in(_k_v1, h / 3.0) \
		.add_scaled_in(_k_v2, h / 3.0).add_scaled_in(_k_v3, h / 6.0)
	v.add_scaled_in(_k_a1, h / 6.0).add_scaled_in(_k_a2, h / 3.0) \
		.add_scaled_in(_k_a3, h / 3.0).add_scaled_in(_k_a4, h / 6.0)

	# Propellant is spent on the same step at the reported flow (exact at fixed throttle).
	if s.mdot > 0.0: burn(s.mdot * h)
	spin(h)
	heat_load += s.heat * h
	if s.heat > peak_heat: peak_heat = s.heat

## One burning stage's own propellant flow, kg/s — propulsion()'s per-stage
## term. Flow is set by the vacuum rating, so no ambient pressure is needed.
func _stage_mdot(st) -> float:
	var s: Dictionary = st.spec
	if s.get("engine") == null or st.prop <= 0.0: return 0.0
	var burned: float = 1.0 - st.prop / maxf(st.prop0, 1.0)
	var o: Rocketry.Thrust = photon_output(s.engine, st.live, _th1) \
		if (s.engine.get("photon", false) and s.engine.get("holdAccel", 0.0) > 0.0) \
		else Rocketry.engine_output(s.engine, st.live, 0.0, throttle, burned, _th1)
	var m: float = o.mdot
	if s.get("vacEngine") != null:
		m += Rocketry.engine_output(s.vacEngine, s.vacCount, 0.0, throttle, burned, _th2).mdot
	return m

## Draw `kg` from the live stages, each in proportion to its own engines' flow, and
## auto-stage when one runs dry if the plan says to.
func burn(kg: float) -> void:
	var lst := live_stages()
	var shares: Array[float] = []
	var tot := 0.0
	for st in lst:
		var m := _stage_mdot(st)
		shares.append(m); tot += m
	for i in lst.size():
		var st = lst[i]
		if st.spec.get("engine") == null or st.prop <= 0.0: continue
		if tot > 0.0 and shares[i] <= 0.0: continue
		var take := minf(st.prop, kg * (shares[i] / tot) if tot > 0.0 else kg)
		st.prop -= take
		if tot <= 0.0: kg -= take
		if st.prop <= 1e-6:
			st.spent = true
			log_event("%s — cutoff (propellant depleted)" % st.spec.name + _where())
			if auto_stage: pending_stage = true
		if tot <= 0.0 and kg <= 0.0: break

func can_rail() -> bool:
	if throttle > 0.0: return false
	if phase == PHASE.LANDED or phase == PHASE.PRELAUNCH: return false
	var atm = env.atm
	if atm != null and altitude() < atm.top: return false
	if chute_open != null: return false
	return true

## A body's primary: the smallest Hill sphere it is inside, r_Hill = d·(m/3M)^⅓,
## else the dominant mass. Not "strongest pull": the Sun pulls the Moon twice as hard
## as the Earth does. Getting it wrong puts the Moon's SOI at 129 000 km around an
## Earth inside it, and the handover oscillates.
func primary_of(body: Body):
	var root = null
	for b in bodies:
		if b.alive and b.mass > (root.mass if root != null else -1.0): root = b
	if root == null or root == body: return null
	var best = null
	var best_hill := INF
	for c in bodies:
		if c == body or c == root or not c.alive or c.mass <= body.mass: continue
		var d_root: float = c.pos.distance_to(root.pos) * Rocketry.AU_M
		if not (d_root > 0.0): continue
		var hill := d_root * U.cbrt(c.mass / (3.0 * root.mass))
		if body.pos.distance_to(c.pos) * Rocketry.AU_M < hill and hill < best_hill:
			best = c; best_hill = hill
	return best if best != null else root

## SOI radius of `body` about its own primary, in metres.
func soi_of(body: Body) -> float:
	var p = primary_of(body)
	if p == null: return INF
	return Orbit.sphere_of_influence(body.pos.distance_to(p.pos) * Rocketry.AU_M, body.mass, p.mass)

## Patched-conic handover: left the parent's SOI, or entered a smaller nested one
## (the smallest enclosing wins).
func check_soi() -> void:
	if bodies.is_empty(): return
	var R := r.length()

	# entering: the deepest SOI that contains us and is not the parent's own
	var best = null
	var best_soi := INF
	for b in bodies:
		if b == parent or not b.alive: continue
		var soi := soi_of(b)
		if not is_finite(soi): continue
		_a.sub_vectors(b.pos, parent.pos).scale_in(Rocketry.AU_M)
		if r.distance_to(_a) < soi and soi < best_soi:
			best = b; best_soi = soi
	# leaving: outside the parent's own SOI
	var own := soi_of(parent)
	if R > own:
		var up = primary_of(parent)
		# Only climb out if the parent above isn't itself a smaller, closer option.
		if up != null and not (best != null and best_soi < own):
			rebase(up)
			return
	if best != null and best_soi < own:
		rebase(best)

## Rebase onto a new parent, offsetting position and velocity.
func rebase(body: Body) -> void:
	if body == parent: return
	_a.sub_vectors(parent.pos, body.pos).scale_in(Rocketry.AU_M)
	_b.sub_vectors(parent.vel, body.vel).scale_in(Rocketry.AU_M / _YR)
	r.add_in(_a); v.add_in(_b)
	var old := parent.name
	set_parent(body, bodies)
	log_event("Sphere of influence — %s → %s" % [old, body.name])

## Ground contact: a landing if the legs are down and vertical speed is within the
## gear rating, otherwise a crash.
func contact(_dt: float) -> void:
	var alt := altitude()
	# Held down on the mount: before the airborne branch, since the integrator moves
	# the vehicle a few cm before contact() runs.
	if phase == PHASE.PRELAUNCH and held_down:
		DQuat.set_len(r, env.radius)
		_c.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_c, r)
		v.copy_from(_c)
		return
	if alt > 0.0:
		# Liftoff is detected here: at TWR 1.4 the vehicle is off the pad in one step.
		if phase == PHASE.PRELAUNCH:
			phase = PHASE.ASCENT; t0 = met; log_event("Liftoff")
		return
	var up := DQuat.nrm(_a.copy_from(r))
	airspeed(r, v, _vrel)
	var v_vert := v.dot(up)
	if phase == PHASE.PRELAUNCH:
		# held down on the pad until thrust exceeds weight
		DQuat.set_len(r, env.radius)
		var w: float = mass * env.gSurf
		var s := Sample.new()
		accel(r, v, _b, s)
		# Hold-downs release once thrust exceeds weight, so a failed spin-up is a scrub.
		if s.thrust > w and not held_down:
			phase = PHASE.ASCENT; log_event("Liftoff"); t0 = met
		else:
			_c.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_c, r); v.copy_from(_c)
		return
	# Gear rating is per vehicle (Apollo 3 m/s; Falcon 9 about twice that).
	var geared = null
	for s2 in stages:
		if s2.attached and s2.spec.get("legs", 0):
			geared = s2; break
	var legs := geared != null
	var rate: Dictionary = geared.spec.gear if (geared != null and geared.spec.get("gear") != null) else { "vVert": 3.0, "vHoriz": 1.2 }
	# Lateral speed against the ground (240 m/s of difference at Mars's equator).
	var v_horiz := _b.copy_from(_vrel).add_scaled_in(up, -_vrel.dot(up)).length()
	var limit_v: float = rate.vVert if legs else 1.0
	var limit_h: float = rate.vHoriz if legs else 0.5
	if v_vert < -limit_v or v_horiz > limit_h * 3.0:
		destroy("impact at %s m/s vertical, %s m/s lateral — gear rated to %s m/s" % [U.fixed(absf(v_vert), 1), U.fixed(v_horiz, 1), js_num(limit_v)])
		return
	DQuat.set_len(r, env.radius)
	_c.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_c, r)
	v.copy_from(_c)
	omega.set_v(0.0, 0.0, 0.0)
	if phase != PHASE.LANDED:
		phase = PHASE.LANDED
		landed_at = { "met": met, "vVert": v_vert, "vHoriz": v_horiz }
		log_event("Touchdown — %s m/s vertical, %s m/s lateral" % [U.fixed(absf(v_vert), 2), U.fixed(v_horiz, 2)])

# Telemetry
## Refresh `telemetry` (and the records) from the current state. `s` is the
## last integration sample, or null to take a fresh one. Returns telemetry.
func sample(dt: float, s: Sample = null) -> Dictionary:
	if s == null:
		s = Sample.new()
		accel(r, v, _b, s)
	var m := maxf(mass, 1.0)
	var alt := altitude()
	airspeed(r, v, _vrel)
	# g-load is what an accelerometer reads: every force EXCEPT gravity, which
	# is why a coasting vessel reads zero however hard it is falling.
	var a_net: float = absf(s.thrust - s.drag) / m
	var fwd := forward(_e)
	var va := _vrel.length()
	# Angle of attack is unsigned: entry vehicles fly heat shield first, α ≈ 180° signed.
	var alpha := acos(DQuat.jclamp(absf(fwd.dot(_vrel)) / va, 0.0, 1.0)) if va > 1.0 else 0.0
	var el := Orbit.elements(r, v, env.mu)
	if s.q > max_q:
		max_q = s.q; max_q_t = met - t0; max_q_alt = alt; max_q_mach = s.mach
	if s.mach > max_mach: max_mach = s.mach
	if a_net / Rocketry.G0 > max_g: max_g = a_net / Rocketry.G0
	if launch_site != null:
		# Carry the pad round with the body (ω × r) before measuring against it.
		var site_r: DVec3 = launch_site.r
		if dt > 0.0:
			_a.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_a, site_r)
			DQuat.set_len(site_r.add_scaled_in(_a, dt), env.radius)
		# great-circle distance from the pad, along the surface
		var ang := DQuat.angle_between(site_r, r)
		downrange = ang * env.radius
	var t := telemetry
	t.alt = alt; t.altKm = alt / 1000.0
	t.speed = v.length(); t.airspeed = va
	t.vertical = v.dot(DQuat.nrm(_a.copy_from(r)))
	t.horizontal = sqrt(maxf(t.speed * t.speed - t.vertical * t.vertical, 0.0))
	t.q = s.q; t.mach = s.mach; t.drag = s.drag; t.heat = s.heat
	t.thrust = s.thrust; t.isp = s.isp; t.mdot = s.mdot
	t.plume = s.plume; t.engines = s.engines
	t.mass = m; t.gees = a_net / Rocketry.G0; t.alpha = alpha
	var rl2 := r.length_sq()
	t.twr = s.thrust / (m * env.mu / (rl2 if rl2 != 0.0 else 1.0))
	t.el = el
	t.apo = el.ra - env.radius; t.peri = el.rp - env.radius
	t.period = el.period; t.ecc = el.e; t.inc = el.inc * 180.0 / PI
	t.pressure = s.pa
	t.dv = delta_v_remaining(s.pa)
	t.downrange = downrange
	t.gSurf = env.mu / (rl2 if rl2 != 0.0 else 1.0)
	# The gate the structure checks are made against.
	s.gees = t.gees; s.alpha = alpha
	if dt > 0.0: check_structure(s, dt)
	if dt > 0.0: _milestones(t)
	if pending_stage:
		pending_stage = false
		stage()
	return t
