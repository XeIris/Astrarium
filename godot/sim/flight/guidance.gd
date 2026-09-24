class_name Guidance
extends RefCounted

# ============================================================================
# GUIDANCE — the autopilot, and the attitude references it steers to.
#
# Every program here is a CLOSED LOOP on the vehicle's own state. None of them
# replay a stored trajectory, and that is the difference that matters: a
# scripted ascent looks identical whatever you do to the vehicle, while a
# closed loop flies a heavier rocket differently and gives up when it genuinely
# cannot make orbit.
#
# The four laws, and where each comes from:
#
#   ASCENT — vertical rise, pitch kick, gravity turn at zero angle of attack
#   while the air is thick, then a closed-loop phase that holds TIME TO
#   APOAPSIS at a set value until the apoapsis reaches its target. The
#   time-to-apoapsis hold is the practical cousin of Powered Explicit Guidance:
#   both answer "am I climbing too fast or too slow for the energy I have
#   left", and this one does it without re-solving a transcendental every cycle.
#
#   NODE — a Δv vector at a time. Ignition at T − t_burn/2 so a finite burn
#   straddles the impulsive solution it was planned as; cutoff on the REMAINING
#   Δv projected onto the node direction going negative, never on elapsed time,
#   so a wrong burn-time estimate cannot overburn.
#
#   POWERED DESCENT — the Apollo quadratic law. For a linear acceleration
#   profile that arrives at (r_T, v_T) in t_go:
#        a_cmd = 6·Δr/t_go² − 2·Δv/t_go   with  Δr = r_T − r − v·t_go
#   which is the minimum-∫a² solution of the two-point boundary problem, and is
#   what P63 and P64 actually compute. Gravity is added on top, because the
#   engine has to hold the vehicle up as well as steer it.
#
#   HOVERSLAM — one line, and the whole manoeuvre:
#        h_burn = v² / (2·(F/m − g))
#   evaluated every step. Ignition is when the altitude reaches it. The vehicle
#   cannot hover — minimum throttle already gives TWR > 1 — so arriving at zero
#   velocity and zero altitude simultaneously is the only solution there is.
#
# PORT NOTES.
#   · The Autopilot is the inner class `Guidance.Autopilot` (one JS module, one
#     GDScript file). MODE, attitude_for, target_offset and fmt_dur are statics
#     here, as they were module exports.
#   · The scratch vectors are static and SHARED, as the JS module temporaries
#     were, and several functions return one of them (attitude_for returns _a,
#     descent_law returns _e). Callers that keep a result clone it —
#     Autopilot.update does (`aim`), and so must anything that holds on to one.
#   · A node is a Dictionary { dv: DVec3, t: float, label: String }, and is
#     compared BY IDENTITY (is_same), as the JS `!==` did — GDScript's `==` on
#     Dictionaries compares contents, which would re-seed on an equal new node.
#   · `engage(program, opts)` is Object.assign: camelCase keys in `opts` are
#     set on the snake_case member of the same name.
# ============================================================================

static var _a := DVec3.new()
static var _b := DVec3.new()
static var _c := DVec3.new()
static var _d := DVec3.new()
static var _e := DVec3.new()
static var _up := DVec3.new()
static var _f := DVec3.new()
static var _g := DVec3.new()
# aero_limit's own airstream vector. It cannot borrow one of the shared scratch
# vectors above: `out` is caller-supplied and one call site passes _b, so the
# limit would compare a vector with itself, find no angle, and pass the
# unlimited command straight through — silently deleting the q·α protection on
# exactly the vehicle that needs it most.
static var _air := DVec3.new()

const MODE := {
	"OFF": "off", "PROGRADE": "prograde", "RETROGRADE": "retrograde",
	"NORMAL": "normal", "ANTINORMAL": "antinormal",
	"RADIAL": "radial", "ANTIRADIAL": "antiradial",
	"SURFACE": "surface", "TARGET": "target", "ANTITARGET": "antitarget",
	"NODE": "node", "HOLD": "hold",
}

## The attitude reference for a mode, as a world-space direction for the +Y
## (thrust) axis — the shared scratch _a, or null. Prograde is relative to the
## SURFACE while inside the atmosphere and to the orbit outside it, because
## those are the two things a pilot actually wants to line up with and they
## differ by 465 m/s at the pad.
static func attitude_for(mode: String, v: Vessel, target = null):
	var r := v.r
	DQuat.nrm(_up.copy_from(r))
	var in_air: bool = v.env.atm != null and v.altitude() < v.env.atm.top * 0.6
	var vel: DVec3 = v.airspeed(r, v.v, _b) if in_air else _b.copy_from(v.v)
	var speed := vel.length()
	match mode:
		"prograde":   return DQuat.nrm(_a.copy_from(vel)) if speed > 0.5 else _a.copy_from(_up)
		"retrograde": return DQuat.nrm(_a.copy_from(vel)).negate_in() if speed > 0.5 else _a.copy_from(_up)
		"normal":     return DQuat.nrm(_a.cross_vectors(r, v.v))
		"antinormal": return DQuat.nrm(_a.cross_vectors(r, v.v)).negate_in()
		"radial":     return _a.copy_from(_up)
		"antiradial": return _a.copy_from(_up).negate_in()
		"surface":    return _a.copy_from(_up)
		"target":
			if target == null: return null
			return DQuat.nrm(_a.copy_from(target_offset(v, target)))
		"antitarget":
			if target == null: return null
			return DQuat.nrm(_a.copy_from(target_offset(v, target))).negate_in()
		_: return null

## Vector from the vessel to another body, in the vessel's parent frame (m).
## `out` defaults to the shared scratch _c.
static func target_offset(v: Vessel, body: Body, out: DVec3 = null) -> DVec3:
	if out == null: out = _c
	out.sub_vectors(body.pos, v.parent.pos).scale_in(Rocketry.AU_M).sub_in(v.r)
	return out

static func fmt_dur(s: float) -> String:
	if not is_finite(s): return "—"
	var neg := s < 0.0
	s = absf(s)
	var d := int(floor(s / 86400.0))
	var h := int(floor(fmod(s, 86400.0) / 3600.0))
	var m := int(floor(fmod(s, 3600.0) / 60.0))
	var sec := int(floor(fmod(s, 60.0)))
	var out := ("%dd %dh %dm" % [d, h, m]) if d > 0 else (("%dh %dm %ds" % [h, m, sec]) if h > 0 else ("%dm %ds" % [m, sec]))
	return ("-" if neg else "") + out

# ============================================================================
# THE AUTOPILOT
# ============================================================================
class Autopilot extends RefCounted:
	var v: Vessel
	var mode: String = "off"
	var program = null           # the active flight program (String), if any
	var target = null            # a Body, for transfers and rendezvous
	var node = null              # { dv: DVec3, t: seconds from now, label }
	var status: String = "Manual control"
	var log: Array = []
	## Ascent parameters. These are the pilot's, not the vehicle's — a launch
	## profile is a choice, and the same rocket flies differently with a
	## different one. JS keys: targetApo, inclination, pitchStart, turnEndV,
	## turnExp, climbTime, tauVert.
	var ascent: Dictionary
	var last_throttle: float = 1.0
	var aim = null               # DVec3 (a clone) — what the vessel is steering to

	# ---- program state (all of it was ad-hoc fields on the JS object)
	var state_name = null
	var pitch_deg: float = 0.0
	var plan = null              # transfer plan Dictionary
	var burning: bool = false
	var node_vec := DVec3.new()
	var node_t: float = 0.0
	var node_dv_total: float = 0.0
	var burn_remaining: float = 0.0
	var shut_cool: float = 0.0
	var manual_engines: bool = false
	var site = null              # DVec3 landing site, parent frame, m
	var t_go = null              # float or null
	var v_ref: float = 0.0
	var v_vert_now: float = 0.0
	var lat_now: float = 0.0
	var slamming: bool = false
	var entry_burning: bool = false
	var entry_done: bool = false
	var shield_gone: bool = false
	var crane_out: bool = false
	var _integ: float = 0.0
	var _last_note = null
	var _node_ref = null

	func _init(vessel: Vessel) -> void:
		v = vessel
		var tgt = vessel.vehicle.get("target")
		ascent = {
			"targetApo": tgt.get("apoapsis", 200e3) if tgt != null else 200e3,
			"inclination": tgt.get("inclination", 28.5) if tgt != null else 28.5,
			"pitchStart": 55.0,       # m/s at which the pitch program starts
			"turnEndV": 2350.0,       # m/s at which the program reaches horizontal
			"turnExp": 0.62,          # shape of θ = 90°(1 − v/v_turn)^k
			"climbTime": 170.0,       # s over which the closed loop closes the altitude deficit
			"tauVert": 22.0,          # s — vertical-rate time constant
		}
		last_throttle = 1.0

	# The HUD status line changes every frame; the event log must not. `say` is
	# the transient one, `note` is the one that goes in the log — and separating
	# them is the difference between a flight log and a countdown transcript.
	func say(s: String) -> void: status = s
	func note(s: String) -> void:
		if _last_note != s:
			_last_note = s; status = s; v.log_event(s)

	func engage(prog: String, opts: Dictionary = {}) -> void:
		program = prog
		state_name = null
		_integ = 0.0
		for k in opts:
			set(String(k).to_snake_case(), opts[k])
		v.auto_stage = true
		note("Autopilot — %s" % prog)

	func disengage() -> void:
		program = null; mode = MODE.OFF; note("Manual control")

	# -------------------------------------------------------------------------
	func update(dt: float) -> void:
		if v.phase == Vessel.PHASE.DESTROYED:
			program = null
			return
		# Guidance runs before the integrator, so on the very first cycle there is
		# no telemetry yet. Take a reading rather than guarding every use of it.
		if v.telemetry.get("el") == null: v.sample(0.0)
		var pa := Rocketry.pressure(v.env.atm, maxf(v.altitude(), 0.0)) if v.env.atm != null else 0.0
		var aim_dir = null
		match program:
			"ascent":      aim_dir = ascent_guidance(dt, pa)
			"circularize": aim_dir = circularize_guidance(dt, pa)
			"node":        aim_dir = node_guidance(dt, pa, node)
			"transfer":    aim_dir = transfer_guidance(dt, pa)
			"land":        aim_dir = landing_guidance(dt, pa)
			"hoverslam":   aim_dir = hoverslam_guidance(dt, pa)
			"edl":         aim_dir = edl_guidance(dt, pa)
			"deorbit":     aim_dir = deorbit_guidance(dt, pa)
			_:             aim_dir = Guidance.attitude_for(mode, v, target)
		if aim_dir != null: v.point_at(aim_dir, dt, pa)
		aim = aim_dir.clone() if aim_dir != null else null

	# -------------------------------------------------------------------------
	# ASCENT
	# -------------------------------------------------------------------------
	func ascent_guidance(dt: float, pa: float):
		var A := ascent
		var t := v.telemetry
		var env: Dictionary = v.env
		DQuat.nrm(_up.copy_from(v.r))
		# The launch azimuth that reaches the requested inclination, from the
		# spherical-triangle relation cos(i) = cos(lat)·sin(az). A site cannot
		# reach an inclination below its own latitude, which is why Baikonur
		# cannot launch to 28.5° and why this clamps rather than pretending.
		var lat := asin(DQuat.jclamp(-_up.y, -1.0, 1.0))
		var inc: float = A.inclination * PI / 180.0
		var sin_az := DQuat.jclamp(cos(inc) / maxf(cos(lat), 1e-3), -1.0, 1.0)
		var az := asin(sin_az)
		_b.set_v(0.0, -1.0, 0.0)
		DQuat.nrm(_c.cross_vectors(_b, _up))                 # local east
		DQuat.nrm(_d.cross_vectors(_up, _c))                 # local north
		var heading := DQuat.nrm(_e.copy_from(_c).scale_in(sin(az)).add_scaled_in(_d, cos(az))).clone()

		v.airspeed(v.r, v.v, _a)
		var v_surf := _a.length()
		var alt := v.altitude()
		var a_thrust := full_thrust(pa) / maxf(v.mass, 1.0)
		var g_loc: float = env.mu / v.r.length_sq()

		# ---- throttle: the shared limiter, which is also what protects the
		# circularization and every other powered phase.
		v.throttle = limit_throttle(1.0, pa, dt)

		# ---- phase 1: vertical rise, to clear the tower and build enough speed
		# for the fins/gimbal to have authority.
		if v_surf < A.pitchStart and alt < 2500.0:
			v.throttle = 1.0; last_throttle = 1.0
			state_name = "vertical"
			note("Ascent — vertical rise")
			pitch_deg = 90.0
			return _a.copy_from(_up)

		# ---- phase 2: the pitch program, flown inside an angle-of-attack limit.
		#
		# The programmed pitch is θ = 90°·(1 − v/v_turn)^k, which is the shape every
		# launcher flies: most of the turn happens early and cheaply, and by the
		# time the vehicle is fast it is nearly horizontal. What keeps it honest is
		# the SECOND term: the command is clamped to within α_max of the velocity
		# vector, and α_max is itself set by the q·α the airframe can take. In
		# thick air that is a fraction of a degree, so the vehicle really is flying
		# a gravity turn there; high up the clamp opens and the program leads.
		if t.q > 1200.0 or alt < 42000.0:
			state_name = "turn"
			var x := DQuat.jclamp(v_surf / A.turnEndV, 0.0, 1.0)
			var prog := (PI / 2.0) * pow(1.0 - x, A.turnExp)
			var dir: DVec3 = DQuat.nrm(_b.copy_from(v.airspeed(v.r, v.v, _b))) if v_surf > 1.0 else _b.copy_from(_up)
			var pro_pitch := asin(DQuat.jclamp(dir.dot(_up), -1.0, 1.0))
			var a_max := DQuat.jclamp(v.vehicle.limits.qAlpha / maxf(t.q, 1.0), 0.008, 0.30)
			var pitch := DQuat.jclamp(prog, pro_pitch - a_max, pro_pitch + a_max)
			pitch_deg = pitch * 180.0 / PI
			say("Ascent — pitch program %s°, q %s kPa" % [U.fixed(pitch * 180.0 / PI, 0), U.fixed(t.q / 1000.0, 1)])
			# Horizontal component follows the launch azimuth until there is a real
			# orbital plane to follow, then the plane itself.
			_c.copy_from(v.v).add_scaled_in(_up, -v.v.dot(_up))
			var horiz: DVec3 = DQuat.nrm(_c) if _c.length_sq() > 4e4 else _c.copy_from(heading)
			return DQuat.nrm(_a.copy_from(horiz).scale_in(cos(pitch)).add_scaled_in(_up, sin(pitch)))

		# ---- phase 3: closed loop, out of the air.
		#
		# Hold a VERTICAL SPEED that runs the remaining altitude deficit down over
		# T_climb, and pitch to whatever that needs. As the deficit closes the
		# commanded rate falls to zero and the required pitch falls with it, so the
		# vehicle flattens on its own — no separate "now go horizontal" rule and no
		# discontinuity. Everything left over goes into horizontal speed, which is
		# what actually buys the orbit.
		state_name = "closed"
		var el: Dictionary = t.el
		var apo_alt: float = el.ra - env.radius
		# Hand over when the apoapsis is where it was asked to be — OR when the
		# periapsis has already climbed clear of the atmosphere, which means the
		# vehicle is in orbit whatever the apoapsis says. Without the second test a
		# launcher that ends up in a 178 × 80 km orbit while aiming for 185 keeps
		# flying an ascent forever, seven kilometres short of a number that no
		# longer means anything.
		var safe_alt: float = env.atm.top * 0.6 if env.atm != null else env.radius * 0.002
		if is_finite(el.ra) and (apo_alt >= A.targetApo * 0.998 or (el.rp - env.radius) > safe_alt):
			v.throttle = 0.0
			note("MECO — %s × %s km, coasting" % [U.fixed(apo_alt / 1000.0, 0), U.fixed((el.rp - env.radius) / 1000.0, 0)])
			engage("circularize")
			return Guidance.attitude_for(MODE.PROGRADE, v)
		var v_vert := v.v.dot(_up)
		_c.copy_from(v.v).add_scaled_in(_up, -v_vert)
		var v_horiz := _c.length()
		var R := v.r.length()
		var want_vert := DQuat.jclamp((A.targetApo - alt) / A.climbTime, 0.0, 1500.0)
		# The vertical acceleration the engine must supply: hold the vehicle up
		# (gravity), minus what the horizontal speed is ALREADY supplying
		# (centripetal), plus the correction that walks the climb rate toward its
		# target over τ. The centripetal term is what retires the loop on its own —
		# as the vehicle approaches orbital speed it cancels gravity, the required
		# pitch goes to zero, and the vehicle is level and in orbit.
		var a_vert: float = g_loc - (v_horiz * v_horiz) / R + (want_vert - v_vert) / A.tauVert
		# The nose never goes below the horizon on the way up. Without this floor a
		# stage that separates with more climb rate than the loop wants points
		# itself downward to shed it, which converts most of an upper stage into
		# nothing at all.
		var pitch := DQuat.jclamp(
			asin(DQuat.jclamp(a_vert / maxf(a_thrust, 1e-3), -0.95, 0.95)),
			-0.10, 0.95)
		pitch_deg = pitch * 180.0 / PI
		say("Ascent — closed loop · apo %s/%s km, pitch %s°" % [U.fixed(apo_alt / 1000.0, 0), U.fixed(A.targetApo / 1000.0, 0), U.fixed(pitch * 180.0 / PI, 0)])
		_c.copy_from(v.v).add_scaled_in(_up, -v.v.dot(_up))
		var horiz: DVec3 = DQuat.nrm(_c) if _c.length_sq() > 4e4 else _c.copy_from(heading)
		return DQuat.nrm(_a.copy_from(horiz).scale_in(cos(pitch)).add_scaled_in(_up, sin(pitch)))

	# -------------------------------------------------------------------------
	# NODES
	# -------------------------------------------------------------------------
	## A node that circularizes at whichever apsis is ahead — apoapsis if we are
	## climbing to it, periapsis if the orbit is already closed and low.
	func plan_circularize(at_apo: bool = true):
		var el: Dictionary = v.telemetry.el
		var mu: float = v.env.mu
		if not is_finite(el.ra) and at_apo: return null
		var R: float = el.ra if at_apo else el.rp
		var t_go_s := Orbit.time_to_apoapsis(el, mu) if at_apo else Orbit.time_to_periapsis(el, mu)
		if not is_finite(R) or not is_finite(t_go_s): return null
		# At an apsis the velocity is purely horizontal, so circularizing is a pure
		# prograde (or retrograde) burn of |v_circ − v_apsis|.
		var v_circ := sqrt(mu / R)
		var v_at := sqrt(maxf(mu * (2.0 / R - 1.0 / el.a), 0.0))
		# Direction: the horizontal at that apsis. Propagate to find it rather than
		# guessing — the orbit may be inclined and the apsis is not "over there".
		var rA := DVec3.new()
		var vA := DVec3.new()
		if not Orbit.propagate(v.r, v.v, mu, t_go_s, rA, vA): return null
		var dir := DQuat.nrm(vA)
		return { "dv": dir.scale_in(v_circ - v_at), "t": t_go_s, "label": "Circularize at apoapsis" if at_apo else "Circularize at periapsis" }

	## ORBITAL INSERTION — the same law as the ascent's closed loop, aimed at zero
	## vertical speed instead of a climb rate.
	##
	## A node is the wrong tool for this. A circularization from a steep insertion
	## can be a thousand metres per second, which on an upper stage is a burn two
	## or three minutes long — and over two minutes the orbit rotates out from
	## under a direction that was frozen at ignition, the cosine loss climbs, and
	## eventually the vehicle is thrusting sideways to the burn it thinks it is
	## making. Real vehicles do not fly a long insertion burn as an impulse; they
	## fly it as guidance. So does this:
	##
	##   pitch so that   a_vertical = g − v_horiz²/r + (0 − ṙ)/τ
	##
	## i.e. hold the vehicle in the vertical balance a circular orbit requires,
	## and put everything else into horizontal speed. When the centripetal term
	## cancels gravity the required pitch is zero and the orbit is circular, so
	## the loop retires itself.
	func circularize_guidance(dt: float, pa: float):
		var env: Dictionary = v.env
		var t := v.telemetry
		DQuat.nrm(_up.copy_from(v.r))
		var R := v.r.length()
		var v_vert := v.v.dot(_up)
		_c.copy_from(v.v).add_scaled_in(_up, -v_vert)
		var v_horiz := _c.length()
		var target_r: float = ascent.targetApo + env.radius

		# Done when the PERIAPSIS is where it was asked to be, or when the orbit is
		# round and high enough to stay up. Testing the periapsis is what stops a
		# high-Δv upper stage running away: eccentricity alone is satisfied by a
		# 1 300 × 3 km orbit as easily as by a circular one, and only one of those
		# survives the next hour.
		var safe: float = env.atm.top * 0.62 if env.atm != null else env.radius * 0.001
		# "In orbit" is a physical statement, not a cosmetic one: the periapsis is
		# clear of the atmosphere and the orbit is round enough to stay that way.
		# Chasing a perfectly circular orbit past that point spends propellant on a
		# number rather than on the mission, and a real upper stage does not.
		if t.peri >= (target_r - env.radius) * 0.92 or (t.ecc < 0.014 and t.peri > safe):
			v.throttle = 0.0; program = null; mode = MODE.PROGRADE
			v.phase = Vessel.PHASE.ORBIT
			note("Orbit — %s × %s km, e = %s" % [U.fixed(t.apo / 1000.0, 0), U.fixed(t.peri / 1000.0, 0), U.fixed(t.ecc, 4)])
			return Guidance.attitude_for(MODE.PROGRADE, v)
		# Where to burn. Two cases, and separating them is what makes this
		# reliable:
		#
		#   The periapsis is already clear of the atmosphere — the orbit is safe,
		#   so there is time to be efficient, and the burn waits for apoapsis where
		#   raising the periapsis is cheapest.
		#
		#   The periapsis is NOT clear — the vehicle is on a trajectory that ends in
		#   the atmosphere, and waiting is how you arrive there. Burn now.
		#
		# The earlier version waited for a window of tBurn·0.65 + 20 seconds around
		# apoapsis, which for a 30 m/s trim burn is a 22-second slot that the
		# vehicle can pass through between samples — and having missed it, it
		# cheerfully coasted another 85 minutes for the next one. A rule that
		# depends on catching a narrow window is a rule that will miss it.
		var t_apo := Orbit.time_to_apoapsis(t.el, env.mu)
		var a_thrust := full_thrust(pa) / maxf(v.mass, 1.0)
		var dv_need: float = maxf(sqrt(env.mu / maxf(t.el.ra, R)) - v_horiz, 0.0)
		var t_burn := Rocketry.burn_time_for(dv_need, v.mass, full_thrust(pa), current_isp(pa))
		if t.peri > safe and is_finite(t_apo) and t_apo > t_burn * 0.5 + 25.0:
			v.throttle = 0.0
			say("Coasting to apoapsis — T-%s s, insertion Δv %s m/s" % [U.fixed(t_apo, 0), U.fixed(dv_need, 0)])
			return Guidance.attitude_for(MODE.PROGRADE, v)

		var g_loc: float = env.mu / (R * R)
		# The vertical acceleration a circular orbit needs here: gravity minus what
		# the horizontal speed already supplies, plus the correction that drives
		# the climb rate to zero.
		# Same balance as the ascent loop, aimed at zero climb rate. The floor on
		# the pitch matters as much here: a stage that reaches its target apoapsis
		# still climbing at several hundred metres per second will otherwise point
		# itself steeply down to null that out, and spend the insertion budget
		# digging its own periapsis into the ground.
		var a_vert := g_loc - (v_horiz * v_horiz) / R + (0.0 - v_vert) / 22.0
		var pitch := DQuat.jclamp(
			asin(DQuat.jclamp(a_vert / maxf(a_thrust, 1e-3), -0.9, 0.9)), -0.30, 0.9)
		v.throttle = limit_throttle(1.0, pa, dt)
		say("Insertion burn — %s × %s km, e %s, Δv %s m/s" % [U.fixed(t.apo / 1000.0, 0), U.fixed(t.peri / 1000.0, 0), U.fixed(t.ecc, 3), U.fixed(dv_need, 0)])
		if full_thrust(pa) <= 0.0 and v.next_stage != null: v.stage()
		var horiz: DVec3 = DQuat.nrm(_c) if v_horiz > 50.0 else _c.copy_from(v.forward(_d))
		return DQuat.nrm(_a.copy_from(horiz).scale_in(cos(pitch)).add_scaled_in(_up, sin(pitch)))

	## Execute a node. The three parts that make this reliable:
	##   · point at the node vector and WAIT — a burn started before the vehicle
	##     has turned is a burn in the wrong direction;
	##   · ignite at T − t_burn/2, from the rocket equation at the current mass;
	##   · cut when the remaining Δv projected onto the node goes negative.
	func node_guidance(dt: float, pa: float, nd):
		if nd == null:
			say("No node"); v.throttle = 0.0
			return Guidance.attitude_for(MODE.PROGRADE, v)
		if not is_same(_node_ref, nd):
			# Seed ONCE per node. Re-seeding every cycle while the burn has not
			# started puts node_t back to node.t just before the decrement below
			# takes one dt off it, so the countdown holds at node.t − dt forever and
			# the ignition gate never opens. Nothing decrements node.t itself, so a
			# node planned for apoapsis simply never fires.
			_node_ref = nd
			node_vec = (nd.dv as DVec3).clone()
			node_t = nd.t
			node_dv_total = (nd.dv as DVec3).length()
			burn_remaining = node_dv_total
		var dir := DQuat.nrm(_a.copy_from(node_vec))
		# Nothing lit and nothing left to burn in what IS lit: the next stage has
		# to be ignited before there is a burn to execute at all. This is the case
		# where an ascent reaches its target apoapsis mid-stage — Apollo's S-II cut
		# off at insertion and the S-IVB lit for the circularization, and without
		# this the vehicle counts down to a burn it has no engine for.
		if full_thrust(pa) <= 0.0 and v.next_stage != null: v.stage()
		var prop := v.propulsion(pa)
		var ft := full_thrust(pa)
		var t_burn := Rocketry.burn_time_for(burn_remaining, v.mass, ft, current_isp(pa))
		node_t -= dt
		var label: String = nd.get("label") if nd.get("label") else "Node"

		if not burning and node_t > t_burn / 2.0:
			v.throttle = 0.0
			say("%s — T-%s s, Δv %s m/s" % [label, U.fixed(maxf(node_t - t_burn / 2.0, 0.0), 0), U.fixed(burn_remaining, 1)])
			# Only slew to the node when the burn is close. The node vector is fixed
			# in space but the vessel is not, so "point at the node" a whole orbit
			# early means chasing a target that sweeps 180° — which a real crew would
			# never do and which, on cold gas at 70 s of specific impulse, empties the
			# attitude tanks long before the burn. Until then, hold prograde: free,
			# stable, and already within a few degrees of most node directions.
			var lead := maxf(3.0 * t_burn, 90.0)
			return dir if node_t < lead else Guidance.attitude_for(MODE.PROGRADE, v)
		# ignition
		if not burning:
			burning = true
			note("%s — ignition, Δv %s m/s" % [label, U.fixed(burn_remaining, 1)])
		# Burn while pointing near enough, and account for the cosine loss rather
		# than pretending there is none. Gating the throttle on a TIGHT error is
		# what deadlocks a vehicle whose only attitude authority is its own gimbal:
		# it cannot turn without thrusting and will not thrust until it has turned.
		# 20° is loose enough to break that and tight enough that the loss (6%) is
		# charged honestly to the burn.
		var err := DQuat.angle_between(v.forward(_b), dir)
		v.throttle = limit_throttle(1.0, pa, dt) if err < 0.35 else 0.0
		if prop.F > 0.0: burn_remaining -= (prop.F / v.mass) * cos(err) * dt
		if burn_remaining <= 0.05 or v.delta_v_remaining(pa) < 0.01:
			v.throttle = 0.0; burning = false
			note("%s — cutoff" % label)
			node = null; _node_ref = null
			if program == "circularize" or program == "node":
				program = null; mode = MODE.PROGRADE
				v.phase = Vessel.PHASE.ORBIT
				note("In orbit")
			else:
				state_name = "done"
		return dir

	## The throttle every program should actually command, given what it wants.
	##
	## Two limits, both solved rather than nudged, plus the engine-shutdown escape
	## hatch for when the throttle has run out of authority. This lives here and
	## not in the ascent because a light upper stage circularizing is exactly as
	## capable of tearing itself apart as one climbing — the Starship's third burn
	## pulls more g than its first.
	func limit_throttle(want: float, pa: float, dt: float) -> float:
		var t := v.telemetry
		var lim: Dictionary = v.vehicle.limits
		var th := want
		var tq: float = t.get("q", 0.0)
		var tdrag: float = t.get("drag", 0.0)
		var q_target: float = lim.maxQ * 0.70
		if tq > q_target: th = minf(th, 1.0 - 2.2 * (tq / q_target - 1.0))
		var g_target: float = lim.maxG * 0.88
		var f_full := full_thrust(pa)
		if f_full > 0.0: th = minf(th, (g_target * Rocketry.G0 * v.mass + tdrag) / f_full)
		# ENGINE SHUTDOWN, decided BEFORE the thrust is commanded rather than after
		# it has been felt. A nine-engine booster at its 57% floor pulls 8 g on an
		# empty tank, and one frame of that is enough to lose the vehicle — so
		# waiting to measure the overload and then reacting is a guidance law that
		# reliably arrives one step too late. The test is on what the floor WOULD
		# produce, which is knowable in advance.
		shut_cool = maxf(0.0, shut_cool - dt)
		var st_c = v.current_stage
		if want > 0.0 and shut_cool == 0.0 and not manual_engines \
				and st_c != null and st_c.spec.get("engine") != null and f_full > 0.0 and st_c.live > 1:
			var eng: Dictionary = st_c.spec.engine
			var floor_th: float = 1.0 if eng.get("solid", false) else eng.get("throttleMin", 1.0)
			var g_at_floor := (f_full * floor_th - tdrag) / (v.mass * Rocketry.G0)
			if th <= floor_th + 1e-6 and g_at_floor > g_target:
				# How many engines can stay lit and still keep the floor under the
				# target. Solved rather than stepped one at a time, because on a nearly
				# empty stage the acceleration climbs by a g a second.
				var ratio := (g_target * Rocketry.G0 * v.mass + tdrag) / (f_full * floor_th)
				var keep := maxi(1, int(floor(st_c.live * minf(ratio, 1.0))))
				if keep < st_c.live:
					v.shutdown_engines(st_c.live - keep)
					shut_cool = 1.0
					# Re-solve against the thrust that is actually left.
					var f2 := full_thrust(pa)
					if f2 > 0.0: th = minf(1.0, (g_target * Rocketry.G0 * v.mass + tdrag) / f2)
		th = throttle_for(DQuat.jclamp(th, 0.0, 1.0))
		last_throttle = th if th != 0.0 else 1.0
		return th

	## Thrust at full throttle from the engines that are actually RUNNING —
	## `st.live`, not the stage's built count. Using the built count makes every
	## throttle solve, burn-time estimate and g prediction wrong by the ratio of
	## the two the moment anything shuts an engine down, and the shutdown logic
	## then reads its own output as an overload and shuts down again.
	func full_thrust(pa: float) -> float:
		var F := 0.0
		for st in v.live_stages():
			if st.spec.get("engine") == null or st.prop <= 0.0: continue
			F += Rocketry.engine_output(st.spec.engine, st.live, pa, 1.0).F
			if st.spec.get("vacEngine") != null:
				F += Rocketry.engine_output(st.spec.vacEngine, st.spec.vacCount, pa, 1.0).F
		return F

	func current_isp(pa: float) -> float:
		for st in v.live_stages():
			if st.spec.get("engine") != null and st.prop > 0.0:
				return Rocketry.engine_output(st.spec.engine, st.live, pa, 1.0).isp
		return 300.0

	# -------------------------------------------------------------------------
	# INTERPLANETARY TRANSFER
	# -------------------------------------------------------------------------
	## Plan a transfer to `tgt`. Two cases, and the difference is which body's
	## gravity dominates the answer:
	##
	##   SAME PARENT — a straight Hohmann between the two orbits, with a wait for
	##   the phase angle. This is the LEO→GEO and Earth→Mars-around-the-Sun case.
	##
	##   DIFFERENT PARENT — the vessel must first leave its parent's sphere of
	##   influence with the right hyperbolic excess velocity, and the departure
	##   burn is far smaller than the heliocentric Δv it buys because it is made
	##   deep in the parent's well (the Oberth effect). The planner reports both
	##   numbers, because confusing them is the single most common way to get an
	##   interplanetary Δv budget wrong by 2 km/s.
	##
	## Returns a Dictionary — kind 'hohmann' (the hohmann() keys plus waitS,
	## label) or kind 'escape' (vInf, soi, dvBurn, dvHelio, tof, phase, synodic,
	## label) — or null.
	func plan_transfer(tgt):
		var dominant = null
		for b in v.bodies:
			if b.mass > (dominant.mass if dominant != null else -1.0): dominant = b
		if tgt == null or dominant == null or tgt == v.parent: return null

		# THE TARGET IS IN THE SAME WELL. A Moon shot from Earth orbit is a Hohmann
		# about the EARTH — that is what a translunar injection is — and planning
		# it about the Sun instead compares two almost identical heliocentric
		# orbits and reports a transfer costing twenty metres per second. The test
		# is whose gravity actually dominates at the target, not which body is
		# heaviest in the scene.
		if v.primary_of(tgt) == v.parent or v.parent == dominant:
			# (the second case — heliocentric-to-heliocentric — is the same
			# arithmetic, written out twice in the JS)
			var r1 := v.r.length()
			var r2 := _a.sub_vectors(tgt.pos, v.parent.pos).scale_in(Rocketry.AU_M).length()
			var h := Orbit.hohmann(v.env.mu, r1, r2)
			var want: float = h.phase
			var now := Orbit.phase_angle(v.r, _a)
			var wait := want - now
			while wait < 0.0: wait += 2.0 * PI
			var T1: float = v.telemetry.el.period
			var T2: float = 2.0 * PI * sqrt(pow(r2, 3.0) / v.env.mu)
			var rate := 2.0 * PI * (1.0 / T2 - 1.0 / T1)
			var wait_s := wait / -rate if absf(rate) > 1e-12 else 0.0
			var out := { "kind": "hohmann" }
			for k in h: out[k] = h[k]
			out["waitS"] = wait_s if wait_s > 0.0 else wait_s + absf(h.synodic)
			out["label"] = "Transfer to %s" % tgt.name
			return out

		# escape the current parent first
		var a_au: float = v.parent.pos.distance_to(dominant.pos)
		var soi := Orbit.sphere_of_influence(a_au * Rocketry.AU_M, v.parent.mass, dominant.mass)
		var mu_p: float = Rocketry.GM_SUN * dominant.mass
		var r1b := a_au * Rocketry.AU_M
		var r2b := _a.sub_vectors(tgt.pos, dominant.pos).scale_in(Rocketry.AU_M).length()
		var hb := Orbit.hohmann(mu_p, r1b, r2b)
		# v∞ needed, then the burn from the current orbit — the Oberth saving is
		# the difference between these two, and it is large.
		var v_inf: float = absf(hb.dv1)
		var R := v.r.length()
		var v_esc2: float = 2.0 * v.env.mu / R
		var v_needed := sqrt(v_esc2 + v_inf * v_inf)
		var v_now := v.v.length()
		return {
			"kind": "escape", "vInf": v_inf, "soi": soi,
			"dvBurn": v_needed - v_now, "dvHelio": hb.dv, "tof": hb.tof,
			"phase": hb.phase, "synodic": hb.synodic,
			"label": "Depart %s for %s" % [v.parent.name, tgt.name],
		}

	func transfer_guidance(dt: float, pa: float):
		if plan == null: plan = plan_transfer(target)
		var p = plan
		if p == null:
			say("No transfer solution"); program = null
			return null

		if p.kind == "escape":
			if node == null:
				# Burn prograde at the next periapsis — deepest in the well, where the
				# Oberth benefit is largest.
				var el: Dictionary = v.telemetry.el
				var t_go_s := Orbit.time_to_periapsis(el, v.env.mu)
				var rP := DVec3.new()
				var vP := DVec3.new()
				if not Orbit.propagate(v.r, v.v, v.env.mu, t_go_s if is_finite(t_go_s) else 0.0, rP, vP): return null
				node = { "dv": DQuat.nrm(vP).scale_in(p.dvBurn), "t": t_go_s if is_finite(t_go_s) else 0.0,
						 "label": p.label }
			return node_guidance(dt, pa, node)
		# heliocentric Hohmann: wait for the window, then burn
		if p.waitS > 0.0:
			p.waitS -= dt
			v.throttle = 0.0
			say("Transfer window in %s — phase %s°, want %s°" % [Guidance.fmt_dur(p.waitS),
				U.fixed(Orbit.phase_angle(v.r, _a.sub_vectors(target.pos, v.parent.pos)) * 180.0 / PI, 1),
				U.fixed(p.phase * 180.0 / PI, 1)])
			return Guidance.attitude_for(MODE.PROGRADE, v)
		if node == null:
			node = { "dv": DQuat.nrm(_a.copy_from(v.v)).scale_in(p.dv1).clone(), "t": 0.0, "label": p.label }
		return node_guidance(dt, pa, node)

	# -------------------------------------------------------------------------
	# POWERED DESCENT — Apollo's programs, on Apollo's gates
	# -------------------------------------------------------------------------
	## The quadratic guidance law. Returns the commanded THRUST acceleration
	## (gravity already added back), in the parent frame, written into `out`.
	func quadratic(rT: DVec3, vT: DVec3, tgo: float, out: DVec3) -> DVec3:
		# Δr = r_T − r − v·t_go , Δv = v_T − v
		_b.copy_from(rT).sub_in(v.r).add_scaled_in(v.v, -tgo)
		_c.copy_from(vT).sub_in(v.v)
		out.copy_from(_b).scale_in(6.0 / (tgo * tgo)).add_scaled_in(_c, -2.0 / tgo)
		# the engine also has to hold the vehicle up
		v.gravity(v.r, _d)
		out.sub_in(_d)
		return out

	## THE TERMINAL DESCENT LAW — one controller, used by every landing.
	## Returns the commanded thrust acceleration in the shared scratch _e.
	##
	## The vertical and lateral axes are treated SEPARATELY, and that separation
	## is the whole design. A single three-dimensional "fly to the target" law
	## saturates: a vehicle a kilometre up with a hundred metres per second of
	## sideways drift asks for more lateral acceleration than the engine has, the
	## command ends up pointing nearly horizontal, and the vehicle falls out of
	## the sky perfectly on course.
	##
	## VERTICAL — a reference descent rate that is exactly what the vehicle can
	## still stop from, plus the rate it wants to touch down at:
	##
	##     v_ref(h) = −( v_touch + √(2·a_dec·h) ),   a_dec = k·(F/m − g)
	##
	## The commanded vertical acceleration closes the gap over τ, and is CLAMPED
	## AT ZERO: an engine cannot push downward, and a vehicle descending slower
	## than the reference should simply fall until it catches it. That free fall
	## is not a gap in the law, it is the fuel-optimal thing to do — every second
	## spent holding a vehicle up is a second of gravity loss.
	##
	## LATERAL — null the ground-relative drift and close on the site, with the
	## result capped at a maximum TILT. A lander leans a few degrees to stop
	## drifting; it never points sideways, and capping the tilt is what guarantees
	## the vertical channel keeps the authority it was promised.
	##
	## Everything is ground-relative, because a landing site is a place on a
	## rotating body and the gear cares about motion relative to it.
	func descent_law(a_max: float, v_touch: float, max_tilt_rad: float, tau: float,
			dec_frac: float = 0.6, v_cap: float = INF, hold_below: float = 0.0) -> DVec3:
		var env: Dictionary = v.env
		var alt := maxf(v.altitude(), 0.0)
		DQuat.nrm(_up.copy_from(v.r))
		var g: float = env.mu / maxf(v.r.length_sq(), 1.0)
		v.airspeed(v.r, v.v, _g)
		var v_vert := _g.dot(_up)
		_b.copy_from(_g).add_scaled_in(_up, -v_vert)           # lateral drift

		var a_dec := maxf(dec_frac * (a_max - g), 0.05)
		# The reference is also CAPPED. Without a cap it is whatever the vehicle
		# could survive — 113 m/s at the Apollo approach gate — and the free-fall
		# clamp then means the lander does not touch its engine until it is going
		# that fast, arriving at the surface having spent the whole approach
		# accelerating. A real approach phase descends at a chosen rate (Apollo's
		# is about 45 m/s at hi-gate) so that there is time to do the other things
		# an approach is for: fly out the sideways drift, and look at the site.
		# Below `hold_below` the reference is simply the touchdown rate — a
		# constant-rate final descent. The square-root profile is still several
		# metres per second a metre off the ground, which is more than any landing
		# gear is rated for, so the last stretch has to be flown at a held rate
		# instead. This is not a smoothing hack: it is what a sky crane does for
		# its last twenty metres and what a lunar module does for its last ten.
		var vref := -v_touch if alt < hold_below else -minf(v_touch + sqrt(2.0 * a_dec * alt), v_cap)
		# FEED-FORWARD. Following the reference means decelerating at a_dec — the
		# profile is √(2·a_dec·h), and differentiating it along the trajectory
		# gives exactly that. Without the term, a vehicle sitting perfectly on the
		# reference is commanded g and nothing more, i.e. told to hold its speed,
		# and it rides its own profile straight into the ground: the error term
		# only ever reacts to falling BEHIND, and by then there is no altitude left
		# to catch up in. The zero clamp still gives free fall when the vehicle is
		# above the profile, which is the fuel-optimal thing to do.
		# No feed-forward in the held-rate region: the reference is constant there,
		# so following it needs gravity and nothing else.
		var a_ff := a_dec if (v_vert < 0.0 and alt >= hold_below) else 0.0
		# Free fall is fuel-optimal a long way up and reckless close in: a vehicle
		# that is slower than its reference at 150 m and takes the free ride
		# arrives at the held-rate region 40% faster than it left, with no altitude
		# left to fix it. Below a few times the hold altitude the command floors at
		# g — hold what you have — rather than at zero.
		var floor_a := g if alt < hold_below * 5.0 else 0.0
		var a_vert := maxf(g + a_ff + (vref - v_vert) / tau, floor_a)

		# lateral: kill the drift, and lean gently toward the site
		_c.set_v(0.0, 0.0, 0.0)
		if site != null:
			_c.sub_vectors(site, v.r)
			_c.add_scaled_in(_up, -_c.dot(_up))
			var off := _c.length()
			# Deliberately weak, and capped hard. Landing on the exact spot is worth
			# something; not landing sideways is worth more. A strong site-seeking
			# term fights the drift-killing term whenever the vehicle is already
			# moving toward the site, and the two settle at a lateral speed neither
			# of them wanted.
			if off > 1e-3: _c.scale_in(minf(off, 25.0) / off * 0.02)
		_d.copy_from(_b).scale_in(-1.0 / (tau * 0.7)).add_in(_c)
		# The lateral authority is a fraction of the ENGINE, not a fraction of
		# whatever the vertical channel happens to be asking for right now. Tying
		# it to the vertical command starves the lateral axis exactly when the
		# vehicle is coasting down a capped reference and the vertical command is
		# only enough to hold it up — on the Moon that is 1.6 m/s², which allows
		# a tenth of a g of lateral correction and leaves the lander to arrive with
		# most of its approach speed intact.
		var max_lat := a_max * sin(max_tilt_rad)
		if _d.length() > max_lat: DQuat.set_len(_d, max_lat)

		v_ref = vref; v_vert_now = v_vert; lat_now = _b.length()
		return _e.copy_from(_up).scale_in(a_vert).add_in(_d)

	## Keep a commanded thrust direction inside what the airframe can take.
	##
	## q·α is one of the four ways this vehicle breaks, so a controller that asks
	## for a large lateral correction in thick air is asking to be destroyed. The
	## allowable misalignment is α_max = qα_limit / q, and the command is rotated
	## back toward the airstream until it fits — which is why a booster's lateral
	## authority vanishes as it descends, and why it has to be pointed at the pad
	## long before it gets there.
	func aero_limit(cmd: DVec3, out: DVec3) -> DVec3:
		var t := v.telemetry
		var tq: float = t.get("q", 0.0)
		if v.env.atm == null or not (tq > 200.0): return DQuat.nrm(out.copy_from(cmd))
		v.airspeed(v.r, v.v, _air)
		var va := _air.length()
		if va < 1.0: return DQuat.nrm(out.copy_from(cmd))
		_air.scale_in(-1.0 / va)                       # retrograde, the aligned attitude
		DQuat.nrm(out.copy_from(cmd))
		# 0.85 of the limit, because the limit is where the vehicle breaks and
		# steering to exactly there leaves nothing for a gust or a lag.
		var a_max_rad := DQuat.jclamp(0.85 * v.vehicle.limits.qAlpha / tq, 0.01, PI)
		var ang := DQuat.angle_between(out, _air)
		if ang <= a_max_rad: return out
		# rotate `out` toward the airstream until it is within the limit
		_c.cross_vectors(_air, out)
		if _c.length_sq() < 1e-12: return out.copy_from(_air)
		DQuat.nrm(_c)
		return DQuat.apply_axis_angle(out.copy_from(_air), _c, a_max_rad)

	## Carry the landing site round with the body it is on.
	##
	## At its own surface velocity, ω × r — the same expression `place_on_pad`
	## uses to give a vehicle its free eastward motion, and deliberately not an
	## independently written rotation matrix. Written as one of those it went
	## round the WRONG WAY: with ω along −Y (the pole convention in orbit.gd) the
	## small-angle form of x' = x cos w − z sin w matches ω × r only for
	## w = +Ω dt, so a site at 28.5° receded from the vehicle at 816 m/s instead
	## of travelling with it at 408. Deriving both from one line is what makes
	## that class of error impossible rather than merely unlikely.
	func spin_site(dt: float) -> void:
		if site == null: return
		_a.set_v(0.0, -v.env.rotRate, 0.0).cross_vectors(_a, site)
		DQuat.set_len(site.add_scaled_in(_a, dt), v.env.radius)

	func landing_guidance(dt: float, pa: float):
		var env: Dictionary = v.env
		var t := v.telemetry
		spin_site(dt)
		var prof = v.vehicle.get("descent")
		var alt := v.altitude()
		DQuat.nrm(_up.copy_from(v.r))
		var v_vert := v.v.dot(_up)
		var a_max := full_thrust(pa) / v.mass

		if site == null:
			# Put the landing site where this vehicle can actually stop, straight
			# down-track. Braking from v_h to the hi-gate speed at the available
			# acceleration covers  (v₁ + v₂)/2 · (v₁ − v₂)/a  — so the range is
			# derived from the vehicle rather than read out of a stored number that
			# belonged to a different one. A site placed short forces the guidance to
			# brake harder than the engine can, and the quadratic law answers that by
			# lofting: the lander climbs twenty kilometres on its way down.
			var vh := sqrt(maxf(t.speed * t.speed - v_vert * v_vert, 0.0))
			var v_gate: float = prof.hiGate.vHoriz if prof != null else 130.0
			var brake := maxf(a_max * 0.72, 0.05)
			var rng := maxf((vh + v_gate) * 0.5 * maxf(vh - v_gate, 0.0) / brake,
							(prof.hiGate.range if prof != null else 7000.0) * 2.0)
			var ang: float = rng / env.radius
			DQuat.nrm(_b.copy_from(v.v).add_scaled_in(_up, -v_vert))
			site = _up.clone().scale_in(cos(ang)).add_scaled_in(_b, sin(ang)).scale_in(env.radius)
			state_name = "P63"
			note("P63 — braking phase")
		var st: DVec3 = site

		if state_name == "P63":
			var gate: Dictionary = prof.hiGate if prof != null else { "alt": 2400.0, "range": 7000.0, "vVert": -45.0, "vHoriz": 129.0 }
			# hi-gate target: `gate.alt` above the site, `gate.range` short of it
			DQuat.nrm(_a.copy_from(st))
			_b.copy_from(v.v).add_scaled_in(_up, -v.v.dot(_up))
			if _b.length_sq() < 1.0: _b.copy_from(_up).cross_vectors(_b, _a)
			DQuat.nrm(_b)
			var rT := _a.clone().scale_in(env.radius + gate.alt).add_scaled_in(_b, -gate.range)
			var vT := _b.clone().scale_in(gate.vHoriz).add_scaled_in(_a, gate.vVert)
			# Aim the braking phase just ABOVE the DPS's forbidden throttle band, so
			# it flies at full thrust the way the real P63 does, rather than
			# repeatedly commanding a setting the engine is not allowed to hold and
			# being rounded down to 60% of it.
			var tgo := track_t_go(rT, vT, a_max, dt, 0.96)
			var cmd := quadratic(rT, vT, tgo, _e)
			var need := cmd.length()
			v.throttle = limit_throttle(need / maxf(a_max, 1e-6), pa, dt)
			say("P63 — braking · %s km, %s m/s, %s s to hi-gate" % [U.fixed(alt / 1000.0, 1), U.fixed(t.speed, 0), U.fixed(tgo, 0)])
			if alt < gate.alt * 1.12 or tgo < 2.0:
				state_name = "P64"; note("P64 — approach phase")
			return DQuat.nrm(cmd)

		if state_name == "P64":
			var gate: Dictionary = prof.loGate if prof != null else { "alt": 30.0, "range": 11.0 }
			DQuat.nrm(_a.copy_from(st))
			var _rT := _a.clone().scale_in(env.radius + gate.alt)
			var _vT := _a.clone().scale_in(-1.2)
			var cmd := descent_law(a_max, 2.0, 0.60, 3.5, 0.6, 50.0)
			v.throttle = limit_throttle(cmd.length() / maxf(a_max, 1e-6), pa, dt)
			say("P64 — approach · %s m, %s of %s m/s, %s m/s lateral" % [U.fixed(alt, 0), U.fixed(v_vert_now, 1), U.fixed(v_ref, 1), U.fixed(lat_now, 1)])
			# Hand to terminal descent when the vehicle is genuinely over the site,
			# not merely low. Apollo's lo-gate is a STATE — 30 m up, 11 m short, and
			# essentially stopped — and transitioning on the altitude alone hands
			# P66 a vehicle still moving 40 m/s sideways with five seconds to fix it.
			_b.copy_from(v.v).add_scaled_in(_up, -v.v.dot(_up))
			var lateral := _b.length()
			if (alt < gate.alt * 3.0 and lateral < 8.0) or alt < gate.alt * 0.7:
				state_name = "P66"; t_go = null; note("P66 — terminal descent")
			return DQuat.nrm(cmd)

		# P66 — terminal descent. Same law, aimed at the gear's rated touchdown
		# rate with a tighter time constant and a bigger allowed lean, because this
		# is the phase where the last metre per second of sideways drift has to go.
		var a_cmd := descent_law(a_max, 0.8, 0.35, 1.4, 0.55, 20.0, 12.0)
		v.throttle = limit_throttle(a_cmd.length() / maxf(a_max, 1e-6), pa, dt)
		say("P66 — terminal · %s m, %s m/s, %s m/s lateral" % [U.fixed(alt, 1), U.fixed(v_vert_now, 2), U.fixed(lat_now, 2)])
		if v.phase == Vessel.PHASE.LANDED:
			note("Landed"); program = null; v.throttle = 0.0
		return DQuat.nrm(a_cmd)

	## Choose t_go so the commanded acceleration sits at a comfortable fraction of
	## what the engine can give.
	##
	## Apollo solved a quartic for this. Bisection gets to the same place and
	## cannot diverge, which matters because |a_cmd| falls monotonically with t_go
	## and a multiplicative search seeded badly walks the wrong way: seeded at the
	## 3000 s ceiling, the quadratic law's commanded acceleration collapses to
	## "cancel gravity", the throttle holds a TWR above 1, and a lander told to
	## descend climbs instead — which is exactly what it did.
	##
	## The bracket's upper end is a real physical estimate rather than a constant:
	## braking Δv at the available acceleration. For an Apollo PDI that is
	## 1570 m/s at 2.96 m/s², i.e. 530 s — against the 514 s the real thing took.
	##
	## track_t_go: time-to-go as a COUNTDOWN that is nudged, not re-solved from
	## nothing every cycle. Time really is passing, so the honest update is to
	## subtract dt and correct slowly toward the freshly solved value; re-solving
	## outright each frame lets the answer jump by hundreds of seconds between
	## steps, and the throttle chatters between its deep-throttle floor and full
	## power because the commanded acceleration is following it.
	func track_t_go(rT: DVec3, vT: DVec3, a_max: float, dt: float, frac: float) -> float:
		var solved := solve_t_go(rT, vT, a_max, frac)
		t_go = solved if t_go == null else maxf(t_go - dt, 1.0) * 0.97 + solved * 0.03
		return t_go

	func solve_t_go(rT: DVec3, vT: DVec3, a_max: float, frac: float = 0.72) -> float:
		var dv := _e.copy_from(vT).sub_in(v.v).length()
		var est := DQuat.jclamp(dv / maxf(a_max * 0.85, 0.05), 4.0, 4000.0)
		var lo := 2.0
		var hi := est * 2.2
		var want := a_max * frac
		# |a_cmd| decreasing in t_go, so bisect on the sign of (a − want).
		for i in 34:
			var mid := 0.5 * (lo + hi)
			var a := quadratic(rT, vT, mid, _e).length()
			if a > want: lo = mid
			else: hi = mid
			if hi - lo < 0.5: break
		return 0.5 * (lo + hi)

	## Respect the engine's real throttle limits, including a forbidden band.
	func throttle_for(x: float) -> float:
		var st = null
		for s in v.live_stages():
			if s.spec.get("engine") != null and s.prop > 0.0:
				st = s; break
		if st == null: return 0.0
		var eng: Dictionary = st.spec.engine
		var th := DQuat.jclamp(x, 0.0, eng.get("maxThrottle", 1.0))
		# Below the deep-throttle floor there are two options and only one of them
		# is safe. Cutting to zero is what the old rule did whenever the request
		# fell under half the floor — and in a landing burn, where the commanded
		# acceleration drops the moment the vehicle starts tracking its reference,
		# that turns the last hundred metres into a series of free falls. A real
		# engine cannot go below its floor, so it sits AT the floor, over-brakes a
		# little, and the loop asks for less next cycle. Zero is reserved for a
		# genuine shutdown command.
		var floor_th: float = eng.get("throttleMin", 0.0)
		if th < floor_th: th = 0.0 if x < 0.02 else floor_th
		# The Apollo DPS could not be run between 60% and 92.5% without eroding the
		# throttle valve, so a command inside the band has to go to one edge or the
		# other. It goes UP. Rounding down looks thriftier and is the wrong answer:
		# the guidance asked for that acceleration because it needs it, and a
		# lander that consistently delivers 60% of a 72% command arrives at the
		# surface still moving 40 m/s sideways. Propellant is recoverable; the
		# approach is not.
		var fb = eng.get("forbidden")
		if fb != null and th > fb[0] and th < fb[1]:
			th = fb[0] if (th - fb[0]) < (fb[1] - th) else fb[1]
		return th

	# -------------------------------------------------------------------------
	# HOVERSLAM — propulsive booster recovery
	# -------------------------------------------------------------------------
	func hoverslam_guidance(dt: float, pa: float):
		var env: Dictionary = v.env
		var alt := v.altitude()
		DQuat.nrm(_up.copy_from(v.r))
		v.airspeed(v.r, v.v, _a)
		var speed := _a.length()
		var v_vert := v.v.dot(_up)
		var g: float = env.mu / v.r.length_sq()
		var _m_min := throttle_for(0.0001)
		var a_max := full_thrust(pa) / v.mass

		# The landing burn takes priority over the entry burn: once the vehicle is
		# inside the envelope where it must burn continuously to stop, an entry
		# burn that switches itself off because the speed dropped under a threshold
		# hands it back a vehicle it can no longer save.
		# The shortest landing burn the vehicle could possibly fly — every engine,
		# full throttle. The entry burn hands over when even that would no longer
		# fit with margin. It is used rather than the SELECTED burn's altitude
		# because the selected engine count is a discrete choice that flips between
		# two values as the altitude falls, and gating a burn on a number that
		# jumps makes the burn stutter on and off every frame.
		var st_e = v.current_stage
		var per_e: float = Rocketry.engine_output(st_e.spec.engine, 1, pa, 1.0).F / maxf(v.mass, 1.0) \
			if (st_e != null and st_e.spec.get("engine") != null) else 0.0
		var a_full := maxf((st_e.spec.count if st_e != null else 1) * per_e - g, 0.3)
		var h_burn_pre := (v_vert * v_vert) / (2.0 * a_full)
		# ENTRY BURN. Scheduled by the dynamic pressure it is there to prevent,
		# not by an altitude: the vehicle burns retrograde whenever q climbs past a
		# third of what the airframe can take, and stops when it falls back under.
		# That is self-scheduling — a steeper return starts the burn higher and a
		# shallow one may not need it at all — and it cannot be caught out by a
		# trajectory the numbers were not written for. A fixed "70 km to 40 km at
		# over 1800 m/s" window simply does not fire on a booster that separates
		# slower, and the vehicle then meets max-q with the engines cold.
		var q_lim: float = v.vehicle.limits.maxQ
		# THE HANDOVER. Solved first and tested first, so the landing burn always
		# wins: an entry burn that keeps running because its own deceleration keeps
		# shrinking the predicted landing-burn altitude will run the vehicle all
		# the way to the ground, and hand over at forty metres.
		var sel_pre := solve_landing_burn(alt, v_vert, pa, g)
		# The terminal landing burn belongs in the last few kilometres. Above that
		# the atmosphere and the entry burn do the braking, and they are far better
		# at it than the engines: a booster at 34 km is doing over a kilometre a
		# second, its predicted burn altitude is larger than its altitude, and
		# reading that as "burn now" starts a landing burn thirty kilometres up
		# that runs the tanks dry long before the ground.
		var terminal_ceiling: float = env.atm.top * 0.08 if env.atm != null else INF
		# Ignition is at h_burn and NOT before. This is the part of a hoverslam
		# that is genuinely unforgiving: minimum throttle already gives a
		# thrust-to-weight above one, so the vehicle cannot hover, and lighting
		# early does not buy margin — it buys an ascent. Igniting at two kilometres
		# "to be safe" makes the booster stop at a hundred metres, climb back to
		# four hundred, and oscillate until the tanks are dry.
		var must_land := slamming or (alt <= sel_pre.hBurn * 1.05 and alt < terminal_ceiling)
		# Hysteresis on q: start at a third of the limit, stop at a fifth. An entry
		# burn is not a thing you pulse.
		# Start the entry burn early — a tenth of the airframe limit, which on a
		# returning booster is around 40 km — and hold it. Waiting until a third of
		# the limit means starting at 30 km with a kilometre and a half a second
		# still on the clock, and by then the air is arriving faster than the
		# engines can take it away.
		var q_on := q_lim * (0.06 if entry_burning else 0.10)
		var tq: float = v.telemetry.get("q", 0.0)
		# The entry burn also stops well before the ground. Its job is to protect
		# the vehicle from the air, and its throttle is set by dynamic pressure —
		# which near the surface is still high enough to keep it lit, so it flies
		# the booster gently down to a hundred metres and hands over a vehicle
		# whose landing burn is now twenty metres long. Below half the terminal
		# ceiling the vehicle either falls or lands; nothing else.
		if env.atm != null and not must_land and alt > terminal_ceiling * 0.5 \
				and alt > h_burn_pre * 1.6 and tq > q_on:
			# Throttle on how far over the line q is, so it is a trim rather than a
			# hammer, and hard over if the vehicle is genuinely in trouble.
			# Three engines for the entry burn — the count the real vehicle uses, and
			# the reason it can pull the deceleration it needs without the throttle
			# floor of nine putting it over its g limit.
			v.set_engine_count(3)
			manual_engines = true
			var over := tq / (q_lim * 0.10) - 1.0
			# Through the shared limiter, so the same g cap and the same engine
			# shutdown apply here as on the way up. A nine-engine booster at its 57%
			# floor pulls 5 g on an empty tank; the limiter is what turns that into
			# the three-engine burn the real one uses.
			v.throttle = limit_throttle(DQuat.jclamp(0.45 + over * 2.5, 0.0, 1.0), pa, dt)
			if not entry_burning:
				entry_burning = true
				note("Entry burn — %s km, %s m/s, q %s kPa" % [U.fixed(alt / 1000.0, 0), U.fixed(speed, 0), U.fixed(tq / 1000.0, 1)])
			say("Entry burn — %s km, %s m/s, q %s kPa" % [U.fixed(alt / 1000.0, 0), U.fixed(speed, 0), U.fixed(tq / 1000.0, 1)])
			return Guidance.attitude_for(MODE.RETROGRADE, v)
		if entry_burning:
			entry_burning = false; entry_done = true; v.throttle = 0.0; note("Entry burn cutoff")

		# THE ONE LINE THAT IS THE WHOLE MANOEUVRE — generalised over how many
		# engines are lit, because that is the other half of the decision.
		#
		#     h_burn(n) = v² / (2·(n·F_engine/m − g))
		#
		# Fewer engines means a lower deceleration and a higher ignition altitude.
		# The vehicle picks the FEWEST engines whose burn still fits in the
		# altitude it has left, which is exactly why a Falcon 9 lands on one engine
		# when it can and three when it cannot. Choosing the count first and then
		# computing h_burn for a different count is how you arrive at 900 m needing
		# 3 900 m of braking.
		var sel := sel_pre
		var h_burn: float = sel.hBurn
		if not must_land:
			v.throttle = 0.0
			say("Falling — %s km, %s m/s, ignite at %s km" % [U.fixed(alt / 1000.0, 1), U.fixed(-v_vert, 0), U.fixed(h_burn / 1000.0, 2)])
			return Guidance.attitude_for(MODE.RETROGRADE, v)
		if not slamming:
			slamming = true
			v.set_engine_count(sel.n)
			manual_engines = true
			note("Landing burn — %d engine%s, ignition at %s m" % [sel.n, "s" if sel.n > 1 else "", U.fixed(h_burn, 0)])
		# Same terminal law. For a booster the reference rate IS the hoverslam
		# profile — √(2·a_net·h) is what "arrive at zero velocity at zero altitude"
		# means — and the zero clamp on the vertical command is what lets it keep
		# falling between the entry burn and the landing burn instead of hovering.
		# A booster barely leans. Six degrees of tilt against 25 kPa of dynamic
		# pressure is already 2.6 kPa·rad of the 5 the airframe allows, and the
		# attitude lags the command — so the commanded tilt has to sit well inside
		# the limit, not at it.
		var cmd := descent_law(a_max, 2.0, 0.10, 1.0, 0.55, INF, 30.0)
		v.throttle = limit_throttle(cmd.length() / maxf(a_max, 1e-6), pa, dt)
		say("Landing burn — %s m, %s of %s m/s, throttle %s%%" % [U.fixed(alt, 0), U.fixed(v_vert_now, 1), U.fixed(v_ref, 1), U.fixed(v.throttle * 100.0, 0)])
		if v.phase == Vessel.PHASE.LANDED:
			program = null; v.throttle = 0.0; note("Booster recovered")
		return aero_limit(cmd, _a)

	## The fewest engines whose landing burn still fits inside the altitude left,
	## and the altitude that burn has to start at. Scanned rather than assumed:
	## the answer depends on the vehicle's current mass, which is why it is one
	## engine on a nearly empty booster and three on a heavy one.
	## Returns { n: int, hBurn: float }.
	func solve_landing_burn(_alt: float, v_vert: float, pa: float, g: float) -> Dictionary:
		var st = v.current_stage
		if st == null or st.spec.get("engine") == null: return { "n": 1, "hBurn": 0.0 }
		var per: float = Rocketry.engine_output(st.spec.engine, 1, pa, 1.0).F / maxf(v.mass, 1.0)
		# The MOST engines the g limit allows, which is what makes this a hoverslam
		# rather than a descent: more deceleration means a later ignition, and the
		# whole point of the manoeuvre is to arrive at zero velocity and zero
		# altitude at the same instant, having spent as little time as possible
		# holding the vehicle up against gravity. Picking the FEWEST engines
		# instead gives an ignition altitude of thirty kilometres and a burn that
		# is mostly hover.
		var g_limit: float = (v.vehicle.limits.maxG * 0.85 * Rocketry.G0 + g)
		var n := int(DQuat.jclamp(floor(g_limit / maxf(per, 1e-6)), 1.0, float(st.spec.count)))
		# The SAME margin the descent law flies with (decFrac), so the ignition
		# altitude and the profile the vehicle then tracks are the same curve. Sized
		# on the full deceleration instead, the burn starts exactly where a perfect
		# controller would need it and a real one with any lag at all arrives short.
		# 70% of the available deceleration, so ignition is about 20% higher than a
		# perfect controller would need. A hoverslam has no margin by construction;
		# this is the only place to put any, and without it the vehicle arrives
		# saturated at full throttle and still moving.
		var a := maxf(0.58 * (n * per - g), 0.3)
		return { "n": n, "hBurn": (v_vert * v_vert) / (2.0 * a) }

	# -------------------------------------------------------------------------
	# ENTRY, DESCENT AND LANDING — the atmospheric one
	# -------------------------------------------------------------------------
	func edl_guidance(dt: float, pa: float):
		var env: Dictionary = v.env
		var t := v.telemetry
		spin_site(dt)
		var plan_edl = v.vehicle.get("edl")
		var alt := v.altitude()
		DQuat.nrm(_up.copy_from(v.r))
		v.airspeed(v.r, v.v, _a)
		var speed := _a.length()
		var v_vert := v.v.dot(_up)
		v.throttle = 0.0

		if state_name == null:
			state_name = "entry"; note("Entry interface")

		if state_name == "entry":
			say("Entry — %s km, %s m/s, %s W/cm²" % [U.fixed(alt / 1000.0, 1), U.fixed(speed, 0), U.fixed(t.heat / 1e4, 1)])
			# Heat-shield forward, which is the entire job of the aeroshell.
			# A parachute is qualified for a Mach number and a dynamic pressure, not
			# an altitude — MSL's supersonic disk-gap-band deploys at Mach 1.7 and
			# about 750 Pa, wherever on the profile that happens to be. Gating on a
			# stored altitude means an entry that decelerates higher than expected
			# falls past its own deployment box with the chute still packed.
			var ch: Dictionary = plan_edl.chute if (plan_edl != null and plan_edl.get("chute") != null) else { "mach": 1.7, "deployQ": 750.0 }
			var dq: float = ch.get("deployQ", 750.0)
			# The lower bound matters as much as the upper one: at the entry
			# interface there is no atmosphere at all, so Mach and q are both zero
			# and a test written only as "Mach below 1.7" fires on the first frame,
			# 125 km up, into vacuum. A parachute needs dynamic pressure to inflate.
			if t.mach < ch.mach and t.mach > 0.05 and t.q > dq * 0.25 and t.q < dq * 1.6:
				state_name = "chute"
				var sh = null
				for s in v.stages:
					if s.attached and s.spec.get("chute") != null:
						sh = s; break
				v.chute_open = sh.spec.chute if sh != null else { "area": 200.0, "Cd": 0.62 }
				v.chute_deploy = 0.0
				note("Parachute deploy — Mach %s, %s km" % [U.fixed(t.mach, 2), U.fixed(alt / 1000.0, 1)])
			return Guidance.attitude_for(MODE.RETROGRADE, v)

		if state_name == "chute":
			# Inflation takes a couple of seconds, and the load during it is the
			# largest of the whole descent.
			v.chute_deploy = minf(1.0, v.chute_deploy + dt / 2.2)
			say("On the chute — %s km, %s m/s" % [U.fixed(alt / 1000.0, 2), U.fixed(speed, 0)])
			# The backshell — and the chute with it — is released LOW and SLOW, at
			# about 1.8 km and 100 m/s, and only then does the descent stage light.
			# Dropping it at parachute deploy instead leaves the descent stage to fly
			# the whole remaining descent on 390 kg of hydrazine, which is a fifth of
			# what that would take. The chute does the work; the rockets do the last
			# kilometre.
			var bs: Dictionary = plan_edl.backshell if (plan_edl != null and plan_edl.get("backshell") != null) else { "alt": 1800.0, "v": 100.0 }
			if (alt < bs.alt or speed < bs.v) and not shield_gone:
				shield_gone = true; v.jettison("shell"); v.chute_open = null
				state_name = "powered"
				note("Backshell separation — %s km, %s m/s" % [U.fixed(alt / 1000.0, 2), U.fixed(speed, 0)])
			return Guidance.attitude_for(MODE.RETROGRADE, v)

		# powered descent + sky crane, on the same glide slope as every other
		# terminal phase
		var a_max := full_thrust(pa) / v.mass
		var sk: Dictionary = plan_edl.skycrane if (plan_edl != null and plan_edl.get("skycrane") != null) else { "alt": 20.0, "vTouch": -0.75 }
		if site == null: site = _up.clone().scale_in(env.radius)
		DQuat.nrm(_a.copy_from(site))
		var _rT := _a.clone().scale_in(env.radius + 0.5)
		var cmd := descent_law(a_max, absf(sk.vTouch), 0.35, 1.8, 0.55, 120.0, sk.alt * 1.5)
		v.throttle = limit_throttle(cmd.length() / maxf(a_max, 1e-6), pa, dt)
		if alt < sk.alt and not crane_out:
			crane_out = true
			note("Sky crane — rover on the cables")
		say("Powered descent — %s m, %s m/s" % [U.fixed(alt, 0), U.fixed(v_vert, 2)])
		if v.phase == Vessel.PHASE.LANDED:
			program = null; v.throttle = 0.0; note("Touchdown")
		return aero_limit(cmd, _b)

	# -------------------------------------------------------------------------
	func deorbit_guidance(dt: float, pa: float):
		var el: Dictionary = v.telemetry.el
		var mu: float = v.env.mu
		if node == null:
			# Drop the periapsis to a target inside the atmosphere (or just under the
			# surface for an airless body), from the current apoapsis.
			var target_peri: float = v.env.radius + (v.env.atm.top * 0.35 if v.env.atm != null else -v.env.radius * 0.02)
			var R: float = el.r
			var a_new := (R + target_peri) / 2.0
			var v_new := sqrt(maxf(mu * (2.0 / R - 1.0 / a_new), 0.0))
			var dv: float = v_new - el.v
			node = { "dv": DQuat.nrm(_a.copy_from(v.v)).scale_in(dv).clone(), "t": 0.0, "label": "Deorbit burn" }
		return node_guidance(dt, pa, node)
