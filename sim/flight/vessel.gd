class_name Vessel
extends RefCounted

# ============================================================================
# THE VESSEL
# ----------------------------------------------------------------------------
# State, forces, staging, structure and clocks. Everything in SI, in a frame
# centred on the vessel's parent body whose axes are parallel to the orrery's.
#
# THE FRAME IS NOT INERTIAL — it accelerates with the parent — and that is
# deliberate, because it is the only frame in which a rocket's numbers stay in
# a float's comfortable range. The price is one extra term in the gravity, and
# it is the term that carries all the interesting physics anyway:
#
#     a = Σᵢ GMᵢ (Rᵢ − R_v)/|Rᵢ − R_v|³  −  Σᵢ≠p GMᵢ (Rᵢ − R_p)/|Rᵢ − R_p|³
#
# The first sum is the pull of every body on the vessel; the second is the pull
# of every body EXCEPT the parent on the frame origin. Subtracting them leaves
# the parent's own gravity intact and reduces every other body's contribution to
# a tidal difference — which is why a vessel in LEO does not get dragged out of
# orbit by the Sun's 6e-3 m/s², and why it nevertheless feels the Moon.
#
# ATTITUDE. Body +Y is the thrust axis, so the nose direction is q·(0,1,0) and
# craftmodel stacks its meshes along +Y to match. The controller is the
# time-optimal rest-to-rest slew — ω_des = sign(e)·min(k|e|, √(2α|e|)) — rather
# than a plain proportional law, because a proportional law commands a rate the
# vehicle cannot stop from and overshoots every large slew. The available α is
# computed from the real gimbal deflection and the real RCS authority, so a
# stage with its engines off genuinely cannot pitch on gimbal alone.
#
# PORT NOTES.
#   · THIS FILE IS THE AU↔SI BOUNDARY, as vessel.js was: the only place the
#     orrery's AU / AU·yr⁻¹ body state (Body.pos, Body.vel) is multiplied into
#     metres. Nothing else in sim/flight/ touches a Body's position.
#   · Every vector is a DVec3 (doubles) and the attitude is a DQuat: the frame
#     is centred on a planet 6.4e6 m in radius, where float32 quantises position
#     to 0.4 m.
#   · Vector normalisation, setLength and angleTo go through DQuat.nrm /
#     set_len / angle_between, which reproduce three.js's arithmetic exactly
#     (see dquat.gd) — the port is verified by diffing trajectories against the
#     JS, and a last-place difference in a normalise is a trajectory that drifts.
#   · The scratch vectors are STATIC, shared by every Vessel, exactly as the JS
#     module-level temporaries were — and the aliasing between them is part of
#     the behaviour (the guidance hands in its own scratch as `dir`, `out`), so
#     it is kept rather than "cleaned up".
#   · JS `log(msg)` is `log_event(msg)` here: a method called `log` would shadow
#     the math function this class also uses. Everything else keeps its name in
#     snake_case (`deltaVRemaining` → `delta_v_remaining`).
#   · The per-stage state is the inner class StageState; `spec` is the vehicle's
#     own stage Dictionary (JS keys). Telemetry and the per-step sample are
#     Dictionaries with the JS keys, since the HUD reads them by name.
# ============================================================================

const PHASE := {
	"PRELAUNCH": "prelaunch", "ASCENT": "ascent", "COAST": "coast", "ORBIT": "orbit",
	"BURN": "burn", "ENTRY": "entry", "DESCENT": "descent", "LANDED": "landed",
	"CRUISE": "cruise", "DESTROYED": "destroyed",
}

# The orrery's year, in seconds, as vessel.js wrote it for the velocity bridge.
const _YR := 3.15576e7

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

## One stage's live state. A stage is `pending` until its ignition event, `live`
## while it is attached, and gone once jettisoned. Propellant is tracked per
## stage because that is what staging actually throws away.
class StageState extends RefCounted:
	var spec: Dictionary          # the vehicle's stage Dictionary (JS keys)
	var index: int
	var prop: float
	var prop0: float
	var ignited: bool
	var attached: bool = true
	var spent: bool
	var restarts: int
	var rcs_prop: float
	## How many of this stage's engines are running. Shutting engines down is
	## the only throttle a non-throttleable engine has, and it is what the
	## Saturn V actually did: the centre F-1 was cut at T+135 s to hold the
	## crew under 4 g, and the centre J-2 at T+460 s for the same reason.
	var live: int
	var gear_out: bool = false    # spaceflight's G key toggles it (JS: st.gearOut)

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
var vehicle_key: String = ""        # set by spaceflight (JS: vessel.vehicleKey)
var stages: Array = []              # of StageState
var stage_index: int = 0            # the lowest still-attached stage

# ---- kinematics (SI, parent-centred)
var r := DVec3.new()
var v := DVec3.new()
var q := DQuat.new()
var omega := DVec3.new()            # body rates, world axes, rad/s
var throttle: float = 0.0
var rcs_on: bool = true

# ---- clocks. `met` is the vessel's own PROPER time and `coord` is the
# coordinate time the rest of the sim runs on; `clock_delta` is the
# accumulated difference against a clock sitting on the parent's surface at
# the launch site. In LEO that is tens of microseconds a day (GPS's famous
# +38.7 µs); at 0.99c it is years. Same expression.
var met: float = 0.0
var coord: float = 0.0
var clock_delta: float = 0.0
var time_rate: float = 1.0

# ---- telemetry / records
var max_q: float = 0.0
var max_g: float = 0.0
var heat_load: float = 0.0
var peak_heat: float = 0.0
var downrange: float = 0.0
var phase: String = PHASE.PRELAUNCH
var failure = null                  # String or null
var events: Array = []              # [{t, msg}]
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

## opts: { vehicle: Dictionary, name?: String, parent: Body, bodies: Array[Body],
## payload?: float } — the JS constructor's option object.
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

# -------------------------------------------------------------------------
# Parent / frame
# -------------------------------------------------------------------------
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
	# Surface velocity from the parent's rotation: ω × r, with ω along −Y so an
	# eastward launch gains it. 465 m/s at Earth's equator, and the reason a pad
	# near the equator is worth building.
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

# -------------------------------------------------------------------------
# Mass properties
# -------------------------------------------------------------------------
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

## Transverse and roll moments of inertia, treating the live stack as a
## uniform slender cylinder. Crude for a Shuttle, right for everything else,
## and what matters is the ORDER: a 110 m Saturn V has 300× the pitch inertia
## of a lunar module and turns like it. Returns { pitch, roll }.
func inertia() -> Dictionary:
	var m := mass
	var L := maxf(length, 0.5)
	var R := maxf(diameter / 2.0, 0.25)
	return { "pitch": m * (L * L / 12.0 + R * R / 4.0), "roll": m * R * R / 2.0 }

# -------------------------------------------------------------------------
# Propulsion
# -------------------------------------------------------------------------
func live_stages() -> Array:
	var out := []
	for s in stages:
		if s.attached and s.ignited and not s.spent: out.append(s)
	return out

## A photon drive is throttled to hold a constant PROPER ACCELERATION, so its
## thrust follows the ship's mass rather than the other way round: F = m·a,
## and ṁ = F/c because the exhaust is light and carries E/c of momentum. Put
## through engine_output instead it produced the plate's full rating whatever
## the ship weighed — which is a drive that pulls 1.5 g at departure and 15 g
## with the tanks nearly dry, and a vehicle whose documented contract the
## integrator did not honour.
##
## The emitter's rating is still a ceiling: a ship too heavy for its plate
## accelerates at less than the hold, which is the honest answer.
func photon_output(engine: Dictionary, n: float) -> Dictionary:
	var th: float = 0.0 if throttle <= 0.0 \
		else minf(maxf(throttle, engine.get("throttleMin", 1.0)), engine.get("maxThrottle", 1.0))
	if th <= 0.0 or n <= 0.0: return { "F": 0.0, "mdot": 0.0, "isp": engine.ispVac, "throttle": 0.0 }
	var F: float = minf(engine.holdAccel * maxf(mass, 1.0), engine.thrustVac * n) * th
	return { "F": F, "mdot": F / Rocketry.C_MS, "isp": engine.ispVac, "throttle": th }

## Total thrust (N) and flow (kg/s) right now, at ambient pressure `pa`.
## Returns { F, mdot, isp, plume, count }.
func propulsion(pa: float) -> Dictionary:
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
		var o: Dictionary = photon_output(s.engine, st.live) \
			if (s.engine.get("photon", false) and s.engine.get("holdAccel", 0.0) > 0.0) \
			else Rocketry.engine_output(s.engine, st.live, pa, throttle, burned)
		if s.get("vacEngine") != null:
			var ov := Rocketry.engine_output(s.vacEngine, s.vacCount, pa, throttle, burned)
			o.F += ov.F; o.mdot += ov.mdot
		F += o.F; mdot += o.mdot; isp_sum += o.isp * o.F; w += o.F
		count += st.live + int(s.get("vacCount", 0))
		if plume == null: plume = s.engine.plume
	return { "F": F, "mdot": mdot, "isp": isp_sum / w if w > 0.0 else 0.0, "plume": plume, "count": count }

## The thrust axis in world coordinates. `out` defaults to the shared scratch
## (JS: forward(out = _a)).
func forward(out: DVec3 = null) -> DVec3:
	if out == null: out = _a
	return DQuat.rotate(out.copy_from(BODY_FWD), q)

# -------------------------------------------------------------------------
# Forces
# -------------------------------------------------------------------------

## Gravity in the parent-centred non-inertial frame. See the module header.
func gravity(rr: DVec3, out: DVec3) -> DVec3:
	out.set_v(0.0, 0.0, 0.0)
	var p := parent
	if p == null: return out
	for b in bodies:
		if not b.alive: continue
		var gm: float = Rocketry.GM_SUN * b.mass
		# offset of body b from the parent, in metres. PRIVATE scratch: callers
		# routinely pass one of the shared temporaries as `out`, and reusing one
		# here would have this function overwrite its own accumulator.
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

## Velocity relative to the rotating atmosphere. This is what drag, Mach and
## heating all use — an equatorial launch site is already doing 465 m/s
## through space and 0 m/s through the air.
func airspeed(rr: DVec3, vv: DVec3, out: DVec3) -> DVec3:
	_d.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_d, rr)
	return out.sub_vectors(vv, _d)

func _first_attached():
	for s in stages:
		if s.attached: return s
	return null

## Total acceleration at a trial state. Called four times per RK4 step, so it
## writes into scratch and allocates as little as it can. `sample` (a
## Dictionary, or null) receives q, mach, drag, heat, pa, thrust, mdot, isp,
## plume, engines.
func accel(rr: DVec3, vv: DVec3, out: DVec3, sample = null) -> DVec3:
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
			# BLUNT-BODY LIFT. A Mars aeroshell is not a ballistic capsule: an
			# offset centre of mass makes it fly at a trim angle of attack with a
			# lift-to-drag ratio of about 0.24, and it banks that lift vector to
			# steer. Flown lift-up it stretches the trajectory by tens of
			# kilometres, which is the difference between deploying the parachute
			# at Mach 1.7 with 11 km to spare and arriving supersonic at the ground.
			var bl = null
			for s2 in stages:
				if s2.attached and s2.spec.get("lift") != null:
					bl = s2; break
			if bl != null and drag > 0.0:
				DQuat.nrm(_c.copy_from(rr))                    # local up
				_c.add_scaled_in(_vrel, -_c.dot(_vrel) / (va * va))
				if _c.length_sq() > 1e-12:
					# Banked lift. An entry vehicle rolls its lift vector to control
					# range: straight up stretches the trajectory the most and skips if
					# overdone, so a guided entry flies a partial bank. 60° puts half
					# the lift into the vertical, which is where MSL's range control
					# lived.
					var bnk: float = bank if bank != null else PI / 3.0
					out.add_scaled_in(DQuat.nrm(_c), (drag * bl.spec.lift.LD * cos(bnk)) / m)
			# Lift, for anything with a wing or a body flap. Perpendicular to the
			# airstream, in the plane containing the body axis — this is what lets
			# the Shuttle fly a hypersonic bank and Starship belly-flop.
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

# -------------------------------------------------------------------------
# Attitude
# -------------------------------------------------------------------------

## Angular acceleration the vehicle can actually produce, rad/s², about a
## transverse axis. Gimbal only works while the engines are lit.
## Returns { alpha, tau, I }.
func authority(pa: float) -> Dictionary:
	var I := inertia()
	var L := maxf(length, 1.0)
	var tau := 0.0
	for st in live_stages():
		var s: Dictionary = st.spec
		if s.get("engine") != null and st.prop > 0.0 and throttle > 0.0 and s.gimbalDeg > 0.0:
			var o := Rocketry.engine_output(s.engine, st.live, pa, throttle)
			# The gimbal acts at the engine plane, roughly a half-length from the
			# centre of mass.
			tau += o.F * sin(s.gimbalDeg * PI / 180.0) * (L * 0.45)
		if rcs_on and s.get("rcs") != null and st.rcs_prop > 0.0:
			# A quarter of the thrusters bear on any one axis, at a lever arm of
			# roughly the radius plus a fraction of the length.
			tau += s.rcs.thrust * maxf(float(s.rcs.count) / 4.0, 1.0) * (diameter * 0.5 + L * 0.25)
	return { "alpha": tau / maxf(I.pitch, 1.0), "tau": tau, "I": I }

## Steer toward a world-space direction for the +Y axis. Returns the pointing
## error, rad.
##
## The commanded rate is the TIME-OPTIMAL rest-to-rest profile: accelerate at
## α, then decelerate at α, which means never asking for a rate you cannot
## stop from inside the remaining error. A plain proportional law overshoots
## every large slew and then hunts, which is the exact complaint Orbiter's PID
## autopilot exists to fix.
func point_at(dir, dt: float, pa: float, _roll_ref = null) -> float:
	if dir == null or dir.length_sq() < 1e-12: return 0.0
	DQuat.nrm(_a.copy_from(dir))
	var fwd := forward(_b)
	var err := DQuat.angle_between(fwd, _a)
	var alpha: float = authority(pa).alpha
	if alpha <= 0.0: return err
	# rotation axis
	_c.cross_vectors(fwd, _a)
	if _c.length_sq() < 1e-14:
		# exactly 180° out — any perpendicular axis will do
		_c.set_v(fwd.y, -fwd.x, 0.0)
		if _c.length_sq() < 1e-14: _c.set_v(0.0, fwd.z, -fwd.y)
	DQuat.nrm(_c)
	# Deadband. Below it the vehicle is pointed and the only job left is to
	# stop turning — without this the controller chatters across the target and
	# anything gated on the pointing error flickers with it.
	if err < 0.004:
		var w := omega.length()
		if w > 1e-6: omega.scale_in(maxf(0.0, 1.0 - minf(alpha * dt / w, 1.0)))
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
	# RCS costs propellant. Gimbal does not (it is already burning).
	spend_rcs(absf(dw) * inertia().pitch, dt)
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
	for st in live_stages():
		var rcs = st.spec.get("rcs")
		if rcs == null or st.rcs_prop <= 0.0: continue
		var arm := diameter * 0.5 + length * 0.25
		var mdot: float = angular_impulse / maxf(arm * Rocketry.G0 * rcs.isp, 1e-6)
		st.rcs_prop = maxf(0.0, st.rcs_prop - mdot)
		return

# -------------------------------------------------------------------------
# Staging
# -------------------------------------------------------------------------

## Fire the next staging event. Returns the dropped StageState, or null.
##
## A staging event is two things at once and they have to happen in this
## order: drop the lowest attached stage that has nothing left to give, then
## light the lowest stage that has not been lit. Doing it the other way round
## ignites an upper stage inside the interstage it is still attached to.
##
## `sep: 'none'` marks a stage that is never thrown away — a capsule, an
## orbiter, the Hail Mary itself — so it is skipped by the jettison pass but
## still eligible for ignition.
func stage():
	var dropped = null
	for st in stages:
		if not st.attached: continue
		var done: bool = st.spec.get("engine") == null or st.prop <= 1e-6
		# The lowest attached stage still has propellant and is lit: nothing at
		# the bottom is finished, so this event only ignites.
		if not done and st.ignited: break
		if st.spec.sep == "none": break
		st.attached = false; st.spent = true
		dropped = st; stage_events += 1
		log_event(("Fairing separation — %s away" if st.spec.sep == "fairing" else "Staging — %s away") % st.spec.name)
		break
	for st in stages:
		if not st.attached or st.ignited or st.spec.get("engine") == null: continue
		st.ignited = true
		log_event("Ignition — %s" % st.spec.name)
		break
	stage_index = -1
	for i in stages.size():
		if stages[i].attached:
			stage_index = i; break
	return dropped

## Shut down `n` engines on the burning stage. Symmetric shutdown only: with a
## centre engine it goes first (a Saturn V or a Falcon 9 shuts the centre), and
## after that they come off in pairs, because an asymmetric thrust pattern the
## gimbal cannot trim is how you lose the vehicle.
func shutdown_engines(n: int = 1) -> int:
	var st = current_stage
	if st == null or st.live <= 1: return 0
	var off := mini(n, st.live - 1)
	st.live -= off
	log_event("Engine shutdown — %d of %d on %s (%d running)" % [off, st.spec.count, st.spec.name, st.live])
	return off

## Ask for a specific number of engines on the burning stage. Real vehicles
## choose their engine count per phase rather than throttling nine engines to
## their floor and hoping — a Falcon 9 lights three for the entry burn and one
## for the landing — and shutdown has to be reversible for that to be possible.
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
	log_event("Separation — %s" % st.spec.name)
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

# -------------------------------------------------------------------------
# Structure
# -------------------------------------------------------------------------
## Four independent ways to lose a vehicle, each against a real limit. A
## verdict here is an EVENT — the vessel is destroyed and the sim says which
## of the four did it — not a warning light.
func check_structure(s: Dictionary, _dt: float) -> void:
	var lim: Dictionary = vehicle.limits
	if phase == PHASE.DESTROYED: return
	var sq: float = s.get("q", 0.0)
	var sg: float = s.get("gees", 0.0)
	var sa: float = s.get("alpha", 0.0)
	var sh: float = s.get("heat", 0.0)
	if sq > lim.maxQ:
		destroy("aerodynamic breakup — %s kPa exceeded the %s kPa airframe limit" % [U.fixed(sq / 1000.0, 1), U.fixed(lim.maxQ / 1000.0, 0)]); return
	if sg > lim.maxG:
		destroy("structural failure — %s g exceeded the %s g limit" % [U.fixed(sg, 1), js_num(lim.maxG)]); return
	if sq * sa > lim.qAlpha:
		destroy("loss of control — q·α of %s kPa·rad exceeded %s" % [U.fixed(sq * sa / 1000.0, 1), U.fixed(lim.qAlpha / 1000.0, 0)]); return
	if lim.heatLoad > 0.0 and heat_load > lim.heatLoad:
		destroy("thermal failure — %s MJ/m² burned through the shield" % U.fixed(heat_load / 1e6, 0)); return
	# No shield at all: bare aluminium structure fails somewhere around
	# 80 W/cm² of stagnation heating, which is why a stage that comes back
	# without one comes back as a debris field.
	if lim.heatLoad == 0.0 and sh > 8e5:
		destroy("burned up on entry — %s W/cm² on a vehicle with no heat shield" % U.fixed(sh / 1e4, 0)); return

func destroy(why: String) -> void:
	if phase == PHASE.DESTROYED: return
	phase = PHASE.DESTROYED
	failure = why
	throttle = 0.0
	log_event("LOSS OF VEHICLE — %s" % why)

## JS `log(msg)`: append to the event log the HUD shows, capped at 120.
func log_event(msg: String) -> void:
	events.append({ "t": met, "msg": msg })
	if events.size() > 120: events.pop_front()

## A number as JS's `${x}` prints it (6 → "6", 4.5 → "4.5").
static func js_num(x: float) -> String:
	if x == floor(x) and absf(x) < 1e15: return str(int(x))
	return str(x)

# -------------------------------------------------------------------------
# Clocks
# -------------------------------------------------------------------------
## Advance the proper-time clocks.
##
##   dτ/dt = √(1 − v²/c² − 2Φ/c²)
##
## with Φ the (negative) Newtonian potential summed over every body. The two
## ends of this are twelve orders of magnitude apart, so the DIFFERENCE
## against a ground clock is accumulated through
##
##   √A − √B = (A − B)/(√A + √B)
##
## which never subtracts two nearly-equal numbers. At LEO that recovers GPS's
## +38.7 µs/day; at 0.99c it accumulates years — from one expression.
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

# -------------------------------------------------------------------------
# Stepping
# -------------------------------------------------------------------------

## Advance `dt` seconds. opts.rails = true asks for the analytic conic.
##
## RAILS is only legal unpowered, out of the atmosphere and off the ground —
## the same interlocks KSP uses, and for the same reason: on rails the thrust
## and drag terms are not evaluated at all, so allowing it while either is
## acting silently deletes them. Entering and leaving rails re-seeds from the
## analytic state, so there is no boundary to cross badly.
func step(dt: float, opts: Dictionary = {}) -> void:
	if phase == PHASE.DESTROYED:
		coord += dt
		return
	if phase == PHASE.LANDED and throttle <= 0.0:
		# Sit on the surface, turning with it, rather than integrating a
		# contact force that is exactly cancelling gravity.
		# +Ω dt, not −. With ω along −Y the small-angle form of
		# x' = x cos w − z sin w agrees with the ω × r velocity set below ONLY
		# for the positive sign; written the intuitive way the position goes
		# west while the velocity goes east and a landed vehicle walks off its
		# own site at twice the surface speed. Same trap guidance.gd spin_site
		# documents.
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
		return

	if opts.get("rails", false) and can_rail():
		if Orbit.propagate(r, v, env.mu, dt, r, v):
			step_clocks(dt)
			sample(dt)
			check_soi()
			return

	# ---- RK4. The substep is bounded by how fast the state is changing: in
	# thick air with the engines lit that is a few hundredths of a second, in
	# orbit it can be tens. Choosing it from the acceleration rather than
	# fixing it is what lets one integrator cover both.
	var remaining := dt
	var guard := 0
	var s := {}
	while remaining > 1e-9 and guard < 400:
		guard += 1
		var h := minf(remaining, step_bound())
		rk4(h, s)
		remaining -= h
	step_clocks(dt)
	sample(dt, s)
	auto_jettison()
	check_soi()
	contact(dt)

## Conditional separations that are not staging events — the fairing, most
## obviously. Its real criterion is not an altitude but a HEAT FLUX: the
## fairing comes off once free-molecular heating on the bare payload drops
## below about 1135 W/m², which is the number the industry quotes and which
## happens somewhere around 110 km depending entirely on how the vehicle flew.
## Keying it to the flux rather than to an altitude means a lofted trajectory
## really does shed its fairing earlier.
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
	# In the atmosphere the density scale height is what limits it: never move
	# more than a fraction of a scale height in one step, or the drag is
	# evaluated at an altitude the vehicle has already left.
	if atm != null and alt < atm.top:
		var H := Rocketry.scale_height(atm, maxf(alt, 0.0))
		var vv := maxf(v.length(), 1.0)
		return DQuat.jclamp(0.02 * H / vv, 0.004, 0.5)
	if throttle > 0.0: return 0.25
	# Ballistic: a fraction of the local orbital period.
	var R := maxf(r.length(), env.radius)
	var T: float = 2.0 * PI * sqrt(R * R * R / env.mu)
	return DQuat.jclamp(T / 900.0, 0.05, 60.0)

func rk4(h: float, s: Dictionary) -> void:
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

	# Propellant is spent on the same step, from the flow the first evaluation
	# reported — the flow is constant at a given throttle, so this is exact
	# rather than a first-order approximation.
	if s.get("mdot", 0.0) > 0.0: burn(s.mdot * h)
	spin(h)
	heat_load += s.get("heat", 0.0) * h
	if s.get("heat", 0.0) > peak_heat: peak_heat = s.heat

## Draw `kg` from the live stages, bottom first, and auto-stage when a stage
## runs dry if the flight plan says to.
func burn(kg: float) -> void:
	for st in live_stages():
		if st.spec.get("engine") == null or st.prop <= 0.0: continue
		var take := minf(st.prop, kg)
		st.prop -= take; kg -= take
		if st.prop <= 1e-6:
			st.spent = true
			log_event("%s — cutoff (propellant depleted)" % st.spec.name)
			if auto_stage: pending_stage = true
		if kg <= 0.0: break

func can_rail() -> bool:
	if throttle > 0.0: return false
	if phase == PHASE.LANDED or phase == PHASE.PRELAUNCH: return false
	var atm = env.atm
	if atm != null and altitude() < atm.top: return false
	if chute_open != null: return false
	return true

## A body's own primary — the body it is gravitationally BOUND to.
##
## The obvious test, "whose pull is strongest here", is wrong, and famously so:
## the Sun pulls the Moon about twice as hard as the Earth does. The Moon
## orbits the Earth anyway, because what decides that is not the pull but the
## TIDAL difference — whether the Moon sits inside the Earth's Hill sphere,
##
##     r_Hill = d·(m/3M)^⅓ ,
##
## which for the Earth is 1.5 million km against the Moon's 384 000. So the
## primary is the smallest Hill sphere the body is inside; failing all of
## them, the system's dominant mass.
##
## Getting this wrong is not cosmetic. It puts the Moon's sphere of influence
## at 129 000 km instead of 66 000 with the Earth's *inside* it, so a vessel in
## low lunar orbit is simultaneously inside both and the handover oscillates
## every frame; and it plans a translunar injection as a heliocentric transfer
## between two nearly identical orbits, costing twenty metres per second.
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

## Has the vessel left the parent's sphere of influence, or entered a smaller
## one nested inside it? This is the patched-conic handover, and it is where
## the HUD's numbers jump — because the conic they describe genuinely changed.
##
## Entering picks the SMALLEST enclosing SOI, so a vessel in low lunar orbit
## is handed to the Moon and not to the Earth it is also technically inside.
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
		# Only climb out if the parent we would climb to is not itself a smaller,
		# closer option — otherwise the two rules can hand the vessel back and
		# forth across the same boundary.
		if up != null and not (best != null and best_soi < own):
			rebase(up)
			return
	if best != null and best_soi < own:
		rebase(best)

## Move the vessel's frame to a new parent, preserving the absolute state.
## Position and velocity are both offset — forgetting the velocity offset is
## the classic patched-conic bug and it puts the vessel on a wildly wrong
## conic the instant it crosses a boundary.
func rebase(body: Body) -> void:
	if body == parent: return
	_a.sub_vectors(parent.pos, body.pos).scale_in(Rocketry.AU_M)
	_b.sub_vectors(parent.vel, body.vel).scale_in(Rocketry.AU_M / _YR)
	r.add_in(_a); v.add_in(_b)
	var old := parent.name
	set_parent(body, bodies)
	log_event("Sphere of influence — %s → %s" % [old, body.name])

## Ground contact. A landing is a landing if the legs are down and the
## vertical speed is inside what the gear can take; otherwise it is a crash,
## and the threshold is the real one (Apollo's gear was rated to 3 m/s).
func contact(_dt: float) -> void:
	var alt := altitude()
	# Bolted to the mount. This has to come before the airborne branch: the
	# integrator moves the vehicle a few centimetres before contact() ever
	# runs, and an altitude test alone would call that liftoff on the first
	# step after ignition — which is precisely the moment the hold-downs exist
	# to bridge.
	if phase == PHASE.PRELAUNCH and held_down:
		DQuat.set_len(r, env.radius)
		_c.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_c, r)
		v.copy_from(_c)
		return
	if alt > 0.0:
		# Liftoff is detected here rather than in the pad branch below, because a
		# vehicle with a TWR of 1.4 is already off the ground by the end of its
		# first step and the pad branch never runs again.
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
		var s := {}
		accel(r, v, _b, s)
		# Hold-downs. A launch vehicle is bolted to its mount and stays there
		# while the engines come up, so that a failure to reach thrust is a
		# scrubbed count rather than a vehicle that lifts a metre and falls back.
		# Releasing on thrust alone made ignition and liftoff the same instant,
		# which is the one moment of a launch that is worth watching happen.
		if s.thrust > w and not held_down:
			phase = PHASE.ASCENT; log_event("Liftoff"); t0 = met
		else:
			_c.set_v(0.0, -env.rotRate, 0.0).cross_vectors(_c, r); v.copy_from(_c)
		return
	# Gear rating is a property of the GEAR, not a global constant. Apollo's
	# legs were qualified to 3 m/s of vertical touchdown; a Falcon 9's are
	# built for about twice that because a hoverslam has no margin to spare.
	var geared = null
	for s2 in stages:
		if s2.attached and s2.spec.get("legs", 0):
			geared = s2; break
	var legs := geared != null
	var rate: Dictionary = geared.spec.gear if (geared != null and geared.spec.get("gear") != null) else { "vVert": 3.0, "vHoriz": 1.2 }
	# Lateral speed is measured against the GROUND, not against the stars. A
	# landing gear is dragged sideways by how fast the pad is moving under it,
	# and at Mars's equator that is 240 m/s of difference between the two.
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

# -------------------------------------------------------------------------
# Telemetry
# -------------------------------------------------------------------------
## Refresh `telemetry` (and the records) from the current state. `s` is the
## last integration sample, or null to take a fresh one. Returns telemetry.
func sample(dt: float, s = null) -> Dictionary:
	if s == null:
		s = {}
		accel(r, v, _b, s)
	var m := maxf(mass, 1.0)
	var alt := altitude()
	airspeed(r, v, _vrel)
	# g-load is what an accelerometer reads: every force EXCEPT gravity, which
	# is why a coasting vessel reads zero however hard it is falling.
	var a_net: float = absf(s.get("thrust", 0.0) - s.get("drag", 0.0)) / m
	var fwd := forward(_e)
	var va := _vrel.length()
	# Angle of attack is how far the airstream is OFF THE AXIS, which is what
	# the q·α structural limit is about — not which end is forward. Every entry
	# vehicle ever flown flies backwards on purpose: an Apollo command module,
	# a Mars aeroshell and a returning booster all put their axis along the
	# airstream and their heat shield into it. Measured signed, all three read
	# α = 180° and tear themselves apart the instant they enter the atmosphere.
	var alpha := acos(DQuat.jclamp(absf(fwd.dot(_vrel)) / va, 0.0, 1.0)) if va > 1.0 else 0.0
	var el := Orbit.elements(r, v, env.mu)
	if s.get("q", 0.0) > max_q: max_q = s.q
	if a_net / Rocketry.G0 > max_g: max_g = a_net / Rocketry.G0
	if launch_site != null:
		# Carry the pad round with the body before measuring against it. Stored
		# as a fixed clone it is the pad's position at T-0, and the pad itself
		# travels 465 m/s at Earth's equator — 232 km of pure bookkeeping error
		# over a 500 s ascent. ω × r, the same expression place_on_pad used to
		# give the vehicle its eastward motion.
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
	t.q = s.get("q", 0.0); t.mach = s.get("mach", 0.0); t.drag = s.get("drag", 0.0); t.heat = s.get("heat", 0.0)
	t.thrust = s.get("thrust", 0.0); t.isp = s.get("isp", 0.0); t.mdot = s.get("mdot", 0.0)
	t.plume = s.get("plume"); t.engines = s.get("engines", 0)
	t.mass = m; t.gees = a_net / Rocketry.G0; t.alpha = alpha
	var rl2 := r.length_sq()
	t.twr = s.get("thrust", 0.0) / (m * env.mu / (rl2 if rl2 != 0.0 else 1.0))
	t.el = el
	t.apo = el.ra - env.radius; t.peri = el.rp - env.radius
	t.period = el.period; t.ecc = el.e; t.inc = el.inc * 180.0 / PI
	t.pressure = s.get("pa", 0.0)
	t.dv = delta_v_remaining(s.get("pa", 0.0))
	t.downrange = downrange
	t.gSurf = env.mu / (rl2 if rl2 != 0.0 else 1.0)
	# The gate the structure checks are made against.
	s.gees = t.gees; s.alpha = alpha
	if dt > 0.0: check_structure(s, dt)
	if pending_stage:
		pending_stage = false
		stage()
	return t
