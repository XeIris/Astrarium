class_name Guidance
extends RefCounted

# Closed-loop guidance consumes current vessel state, with shared throttle and
# attitude limits. Preserve actual coast, staging and landing gates; see AGENTS.md.

static var _a := DVec3.new()
static var _b := DVec3.new()
static var _c := DVec3.new()
static var _d := DVec3.new()
static var _e := DVec3.new()
static var _up := DVec3.new()
static var _f := DVec3.new()
static var _g := DVec3.new()
# aero_limit's own scratch: a caller passes _b as `out`, and sharing it would
# silently disable the q·α limit.
static var _air := DVec3.new()

const MODE := {
	"OFF": "off", "PROGRADE": "prograde", "RETROGRADE": "retrograde",
	"NORMAL": "normal", "ANTINORMAL": "antinormal",
	"RADIAL": "radial", "ANTIRADIAL": "antiradial",
	"SURFACE": "surface", "TARGET": "target", "ANTITARGET": "antitarget",
	"NODE": "node", "HOLD": "hold",
}

## Thrust-axis direction for a mode (the shared _a), or null. Prograde is
## surface-relative inside the air and orbital outside it.
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

# THE AUTOPILOT
class Autopilot extends RefCounted:
	var v: Vessel
	var mode: String = "off"
	var program = null           # the active flight program (String), if any
	var target = null            # a Body, for transfers and rendezvous
	var node = null              # { dv: DVec3, t: seconds from now, label }
	var status: String = "Manual control"
	var log: Array = []
	## Ascent profile: the pilot's choice, not the vehicle's.
	var ascent: Dictionary
	var last_throttle: float = 1.0
	var aim = null               # DVec3 (a clone) — what the vessel is steering to

	# program state
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
	var _pitch_cmd = null        # the last commanded ascent pitch, rad (see _rate_limit_pitch)
	var _meco_met: float = -1.0  # when the ascent cut off (for a tank dropped after MECO)
	var _pitch_met: float = 0.0
	var _last_note = null
	var _node_ref = null

	func _init(vessel: Vessel) -> void:
		v = vessel
		var tgt = vessel.vehicle.get("target")
		ascent = {
			"targetApo": tgt.get("apoapsis", 200e3) if tgt != null else 200e3,
			"inclination": tgt.get("inclination", 28.5) if tgt != null else 28.5,
			"pitchStart": 55.0,       # m/s at which the pitch program starts
			"turnV0": 600.0,          # m/s past pitchStart at which the program is at 45°
		}
		last_throttle = 1.0

	# `say` sets the transient status line; `note` also writes the event log, once.
	func say(s: String) -> void: status = s
	func note(s: String) -> void:
		if _last_note != s:
			_last_note = s; status = s; v.log_event(s)

	func engage(prog: String, opts: Dictionary = {}) -> void:
		program = prog
		state_name = null
		_integ = 0.0
		_pitch_cmd = null
		for k in opts:
			set(String(k).to_snake_case(), opts[k])
		v.auto_stage = true
		note("Autopilot — %s" % prog)

	func disengage() -> void:
		program = null; mode = MODE.OFF; note("Manual control")

	func update(dt: float) -> void:
		if v.phase == Vessel.PHASE.DESTROYED:
			program = null
			return
		# Guidance runs before the integrator, so the first cycle has no telemetry yet.
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

	# ASCENT
	func ascent_guidance(dt: float, pa: float):
		var A := ascent
		var t := v.telemetry
		var env: Dictionary = v.env
		DQuat.nrm(Guidance._up.copy_from(v.r))
		# Launch azimuth from cos(i) = cos(lat)·sin(az), clamped: a site can't reach an
		# inclination below its own latitude.
		var lat := asin(DQuat.jclamp(-Guidance._up.y, -1.0, 1.0))
		var inc: float = A.inclination * PI / 180.0
		var sin_az := DQuat.jclamp(cos(inc) / maxf(cos(lat), 1e-3), -1.0, 1.0)
		var az := asin(sin_az)
		Guidance._b.set_v(0.0, -1.0, 0.0)
		DQuat.nrm(Guidance._c.cross_vectors(Guidance._b, Guidance._up))                 # local east
		DQuat.nrm(Guidance._d.cross_vectors(Guidance._up, Guidance._c))                 # local north
		var heading := DQuat.nrm(Guidance._e.copy_from(Guidance._c).scale_in(sin(az)).add_scaled_in(Guidance._d, cos(az))).clone()

		v.airspeed(v.r, v.v, Guidance._a)
		var v_surf := Guidance._a.length()
		var alt := v.altitude()
		var a_thrust := full_thrust(pa) / maxf(v.mass, 1.0)
		var g_loc: float = env.mu / v.r.length_sq()

		# throttle: the shared limiter
		v.throttle = limit_throttle(1.0, pa, dt)

		# phase 1: vertical rise, until the fins and gimbal have authority.
		if v_surf < A.pitchStart and alt < 2500.0:
			v.throttle = 1.0; last_throttle = 1.0
			state_name = "vertical"
			note("Ascent — vertical rise")
			pitch_deg = 90.0
			_pitch_cmd = PI / 2.0; _pitch_met = v.met
			return Guidance._a.copy_from(Guidance._up)

		# phase 2: pitch θ = 90°·v₀/(v₀ + v − v_start), clamped within α_max of the
		# velocity vector (α_max from the airframe's q·α limit), so thick air flies a
		# gravity turn. Saturn V stages at 62 km / 2.45 km/s / 19° (AS-506: 67 / 2.4 / 21°).
		if t.q > 1200.0 or alt < 42000.0:
			state_name = "turn"
			var prog: float = (PI / 2.0) * A.turnV0 / (A.turnV0 + maxf(v_surf - A.pitchStart, 0.0))
			var dir: DVec3 = DQuat.nrm(Guidance._b.copy_from(v.airspeed(v.r, v.v, Guidance._b))) if v_surf > 1.0 else Guidance._b.copy_from(Guidance._up)
			var pro_pitch := asin(DQuat.jclamp(dir.dot(Guidance._up), -1.0, 1.0))
			var a_max := DQuat.jclamp(v.vehicle.limits.qAlpha / maxf(t.q, 1.0), 0.008, 0.30)
			var pitch := DQuat.jclamp(prog, pro_pitch - a_max, pro_pitch + a_max)
			_pitch_cmd = pitch; _pitch_met = v.met
			pitch_deg = pitch * 180.0 / PI
			say("Ascent — pitch program %s°, q %s kPa" % [U.fixed(pitch * 180.0 / PI, 0), U.fixed(t.q / 1000.0, 1)])
			# Horizontal component follows the launch azimuth until there is a real
			# orbital plane to follow, then the plane itself.
			Guidance._c.copy_from(v.v).add_scaled_in(Guidance._up, -v.v.dot(Guidance._up))
			var horiz: DVec3 = DQuat.nrm(Guidance._c) if Guidance._c.length_sq() > 4e4 else Guidance._c.copy_from(heading)
			return DQuat.nrm(Guidance._a.copy_from(horiz).scale_in(cos(pitch)).add_scaled_in(Guidance._up, sin(pitch)))

		# phase 3: explicit guidance, out of the air.
		state_name = "closed"
		var el: Dictionary = t.el
		var apo_alt: float = el.ra - env.radius
		# Hand over at the target apoapsis, or once the periapsis clears the air with
		# nothing left to burn (the ascent cuts off low on purpose).
		var safe_alt: float = env.atm.top * 0.6 if env.atm != null else env.radius * 0.002
		if is_finite(el.ra) and (apo_alt >= A.targetApo * 0.998 \
				or ((el.rp - env.radius) > safe_alt and full_thrust(pa) <= 0.0 and v.next_stage == null)):
			v.throttle = 0.0
			_meco_met = v.met
			note("MECO — %s × %s km, coasting" % [U.fixed(apo_alt / 1000.0, 0), U.fixed((el.rp - env.radius) / 1000.0, 0)])
			engage("circularize")
			return Guidance.attitude_for(MODE.PROGRADE, v)
		var v_vert := v.v.dot(Guidance._up)
		Guidance._c.copy_from(v.v).add_scaled_in(Guidance._up, -v_vert)
		var v_horiz := Guidance._c.length()
		var R := v.r.length()
		# Explicit guidance (Cherry's E-guidance, ancestor of the Shuttle's PEG). T_go is
		# the rocket-equation burn time for the horizontal speed still missing. Ending at
		# the insertion altitude with zero climb rate fixes a_v = 6·Δh/T² − 4·ḣ/T,
		# re-solved every step. Insertion is not the target orbit: cut off just above the
		# air on an ellipse whose apoapsis is the target, then circularize there. That is
		# the Shuttle's profile, and the only one its 0.9 g sustainer reaches orbit on.
		var h_ins: float = minf(A.targetApo, env.atm.top * 0.8) if env.atm != null else A.targetApo
		var r_a: float = env.radius + A.targetApo
		var v_ins: float = _perigee_speed(env, h_ins, r_a)
		# With a fairing on, raise the insertion perigee until the Sutton–Graves flux there
		# is under its jettison limit (why a Falcon 9's second stage lofts).
		var q_lim := _fairing_heat_limit()
		if q_lim > 0.0 and env.atm != null:
			var air_frac: float = t.airspeed / maxf(t.speed, 1.0)
			while h_ins < A.targetApo and Rocketry.heat_flux(Rocketry.density(env.atm, h_ins),
					v_ins * air_frac, v.diameter * 0.25) > q_lim:
				h_ins = minf(h_ins + 2000.0, A.targetApo)
				v_ins = _perigee_speed(env, h_ins, r_a)
		var dv_h: float = maxf(v_ins - v_horiz, 0.0)
		var T_go: float = DQuat.jclamp(Rocketry.burn_time_for(dv_h, v.mass, full_thrust(pa), current_isp(pa)), 20.0, 900.0)
		var a_v: float = 6.0 * (h_ins - alt) / (T_go * T_go) - 4.0 * v_vert / T_go
		# Thrust holds the vehicle up (g), less what horizontal speed already supplies
		# (v²/R), plus guidance. At orbital speed the pitch goes to zero by itself.
		var a_vert: float = g_loc - (v_horiz * v_horiz) / R + a_v
		# Pitch floor just below the horizon, or a stage separating with excess climb rate
		# dives to shed it.
		var pitch := DQuat.jclamp(
			asin(DQuat.jclamp(a_vert / maxf(a_thrust, 1e-3), -0.95, 0.95)),
			-0.10, 0.95)
		# Rate-limit the attitude, as the LVDC and IGM do: the answer steps at the
		# handover and at every staging. Simulated seconds, so it holds under warp.
		pitch = _rate_limit_pitch(pitch)
		pitch_deg = pitch * 180.0 / PI
		say("Ascent — closed loop · apo %s/%s km, pitch %s°" % [U.fixed(apo_alt / 1000.0, 0), U.fixed(A.targetApo / 1000.0, 0), U.fixed(pitch * 180.0 / PI, 0)])
		Guidance._c.copy_from(v.v).add_scaled_in(Guidance._up, -v.v.dot(Guidance._up))
		var horiz: DVec3 = DQuat.nrm(Guidance._c) if Guidance._c.length_sq() > 4e4 else Guidance._c.copy_from(heading)
		return DQuat.nrm(Guidance._a.copy_from(horiz).scale_in(cos(pitch)).add_scaled_in(Guidance._up, sin(pitch)))

	## The speed at perigee altitude `h` of an orbit whose apoapsis radius is r_a.
	func _perigee_speed(env: Dictionary, h: float, r_a: float) -> float:
		var r_p: float = env.radius + h
		return sqrt(env.mu * 2.0 * r_a / (r_p * (r_p + r_a)))

	## The lowest jettison heat flux among the fairings still attached, W/m²,
	## or 0 if there are none.
	func _fairing_heat_limit() -> float:
		var lim := 0.0
		for st in v.stages:
			if not st.attached: continue
			var j = st.spec.get("jettisonAt")
			if j != null and j.get("heat") != null:
				lim = float(j.heat) if lim == 0.0 else minf(lim, float(j.heat))
		return lim

	## Walk the commanded pitch toward `want` at no more than PITCH_RATE per
	## simulated second (see the closed loop above for why).
	const PITCH_RATE := 1.0 * PI / 180.0
	func _rate_limit_pitch(want: float) -> float:
		if _pitch_cmd == null:
			# a fresh program starts from wherever the nose actually is, so the
			# handover from the ascent (or from manual control) is continuous
			_pitch_cmd = asin(DQuat.jclamp(v.forward(Guidance._f).dot(Guidance._up), -1.0, 1.0))
			_pitch_met = v.met
		var step := PITCH_RATE * maxf(v.met - _pitch_met, 0.0)
		_pitch_cmd = DQuat.jclamp(want, _pitch_cmd - step, _pitch_cmd + step)
		_pitch_met = v.met
		return _pitch_cmd

	# NODES
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
		# Propagate to the apsis for its horizontal: the orbit may be inclined.
		var rA := DVec3.new()
		var vA := DVec3.new()
		if not Orbit.propagate(v.r, v.v, mu, t_go_s, rA, vA): return null
		var dir := DQuat.nrm(vA)
		return { "dv": dir.scale_in(v_circ - v_at), "t": t_go_s, "label": "Circularize at apoapsis" if at_apo else "Circularize at periapsis" }

	## Orbital insertion: the ascent's closed loop aimed at zero vertical speed,
	##   a_vertical = g − v_horiz²/r + (0 − ṙ)/τ
	## A long insertion burn can't be flown as a node: over minutes the orbit rotates
	## out from under a direction frozen at ignition.
	func circularize_guidance(dt: float, pa: float):
		var env: Dictionary = v.env
		var t := v.telemetry
		# A tank that can't relight is finished at MECO: it separates after its interval
		# and the stage above makes the insertion (the Shuttle's ET, then OMS-2).
		var cs = v.current_stage
		if cs != null and cs.spec.get("sepAfterCutoff") != null and _meco_met >= 0.0:
			v.throttle = 0.0
			var wait: float = float(cs.spec.sepAfterCutoff) - (v.met - _meco_met)
			if wait > 0.0:
				say("MECO — tank separation in %s s" % U.fixed(wait, 0))
				return Guidance.attitude_for(MODE.PROGRADE, v)
			v.stage(true)
		DQuat.nrm(Guidance._up.copy_from(v.r))
		var R := v.r.length()
		var v_vert := v.v.dot(Guidance._up)
		Guidance._c.copy_from(v.v).add_scaled_in(Guidance._up, -v_vert)
		var v_horiz := Guidance._c.length()
		var target_r: float = ascent.targetApo + env.radius

		# Done when the periapsis reaches the target (eccentricity alone accepts a
		# 1300 × 3 km orbit), or when an ascent that fell short is round and clear of the air.
		var safe: float = env.atm.top * 0.62 if env.atm != null else env.radius * 0.001
		if t.peri >= (target_r - env.radius) * 0.92 \
				or (t.ecc < 0.014 and t.peri > safe and t.apo < (target_r - env.radius) * 0.9):
			v.throttle = 0.0; program = null; mode = MODE.PROGRADE
			v.phase = Vessel.PHASE.ORBIT
			note("Orbit — %s × %s km, e = %s" % [U.fixed(t.apo / 1000.0, 0), U.fixed(t.peri / 1000.0, 0), U.fixed(t.ecc, 4)])
			return Guidance.attitude_for(MODE.PROGRADE, v)
		# Periapsis clear of the air: coast to apoapsis. Otherwise: burn now. Don't gate
		# on a narrow window around apoapsis; it gets missed between samples.
		var t_apo := Orbit.time_to_apoapsis(t.el, env.mu)
		var a_thrust := full_thrust(pa) / maxf(v.mass, 1.0)
		var dv_need: float = maxf(sqrt(env.mu / maxf(t.el.ra, R)) - v_horiz, 0.0)
		var t_burn := Rocketry.burn_time_for(dv_need, v.mass, full_thrust(pa), current_isp(pa))
		# (also just after apoapsis: a few seconds late beats an orbit late)
		var since_apo: float = float(t.el.period) - t_apo if is_finite(float(t.el.period)) else INF
		if t.peri > safe and is_finite(t_apo) and t_apo > t_burn * 0.5 + 25.0 and since_apo > t_burn * 0.5 + 90.0:
			v.throttle = 0.0
			say("Coasting to apoapsis — T-%s s, insertion Δv %s m/s" % [U.fixed(t_apo, 0), U.fixed(dv_need, 0)])
			return Guidance.attitude_for(MODE.PROGRADE, v)

		var g_loc: float = env.mu / (R * R)
		# Same balance as the ascent loop, aimed at zero climb rate, with the same pitch
		# floor so a stage still climbing doesn't dive its periapsis into the ground.
		var a_vert := g_loc - (v_horiz * v_horiz) / R + (0.0 - v_vert) / 22.0
		var pitch := DQuat.jclamp(
			asin(DQuat.jclamp(a_vert / maxf(a_thrust, 1e-3), -0.9, 0.9)), -0.30, 0.9)
		pitch = _rate_limit_pitch(pitch)   # the ascent's attitude-rate limit, carried across the handover
		if full_thrust(pa) <= 0.0 and v.next_stage != null: v.stage()
		var horiz: DVec3 = DQuat.nrm(Guidance._c) if v_horiz > 50.0 else Guidance._c.copy_from(v.forward(Guidance._d))
		var dir := DQuat.nrm(Guidance._a.copy_from(horiz).scale_in(cos(pitch)).add_scaled_in(Guidance._up, sin(pitch)))
		# Burn only within 20° of the command, as for a node: after a coast on rails the
		# nose is off by however far the orbit turned.
		var err := DQuat.angle_between(v.forward(Guidance._d), dir)
		v.throttle = limit_throttle(1.0, pa, dt) if err < 0.35 else 0.0
		say(("Insertion burn — %s × %s km, e %s, Δv %s m/s" if err < 0.35 else "Insertion — aligning, %s × %s km, e %s, Δv %s m/s") % [U.fixed(t.apo / 1000.0, 0), U.fixed(t.peri / 1000.0, 0), U.fixed(t.ecc, 3), U.fixed(dv_need, 0)])
		return dir

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
			# Seed once per node; re-seeding every cycle holds the countdown still.
			_node_ref = nd
			node_vec = (nd.dv as DVec3).clone()
			node_t = nd.t
			node_dv_total = (nd.dv as DVec3).length()
			burn_remaining = node_dv_total
		var dir := DQuat.nrm(Guidance._a.copy_from(node_vec))
		# Nothing lit: light the next stage first (the S-IVB after S-II cutoff).
		if full_thrust(pa) <= 0.0 and v.next_stage != null: v.stage()
		var prop_f := v.propulsion(pa).F
		var ft := full_thrust(pa)
		var t_burn := Rocketry.burn_time_for(burn_remaining, v.mass, ft, current_isp(pa))
		node_t -= dt
		var label: String = nd.get("label") if nd.get("label") else "Node"

		if not burning and node_t > t_burn / 2.0:
			v.throttle = 0.0
			say("%s — T-%s s, Δv %s m/s" % [label, U.fixed(maxf(node_t - t_burn / 2.0, 0.0), 0), U.fixed(burn_remaining, 1)])
			# Slew to the node only when the burn is near; until then hold prograde. Chasing
			# a fixed direction for an orbit empties the RCS.
			var lead := maxf(3.0 * t_burn, 90.0)
			return dir if node_t < lead else Guidance.attitude_for(MODE.PROGRADE, v)
		# ignition
		if not burning:
			burning = true
			note("%s — ignition, Δv %s m/s" % [label, U.fixed(burn_remaining, 1)])
		# Burn within 20° and charge the cosine loss. A tighter gate deadlocks a vehicle
		# whose only authority is its gimbal.
		var err := DQuat.angle_between(v.forward(Guidance._b), dir)
		v.throttle = limit_throttle(1.0, pa, dt) if err < 0.35 else 0.0
		if prop_f > 0.0: burn_remaining -= (prop_f / v.mass) * cos(err) * dt
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

	## The throttle every program should command: solved q and g limits, plus engine
	## shutdown when the throttle runs out of authority. Upper stages need it too.
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
		# Engine shutdown is decided from what the throttle floor WOULD produce, before
		# thrust is commanded: a frame at 8 g loses the vehicle.
		shut_cool = maxf(0.0, shut_cool - dt)
		var st_c = v.current_stage
		# (never a solid: once lit it burns out, and there is nothing to shut)
		if want > 0.0 and shut_cool == 0.0 and not manual_engines \
				and st_c != null and st_c.spec.get("engine") != null and f_full > 0.0 and st_c.live > 1 \
				and not st_c.spec.engine.get("solid", false):
			var eng: Dictionary = st_c.spec.engine
			var floor_th: float = 1.0 if eng.get("solid", false) else eng.get("throttleMin", 1.0)
			var g_at_floor := (f_full * floor_th - tdrag) / (v.mass * Rocketry.G0)
			if th <= floor_th + 1e-6 and g_at_floor > g_target:
				# Solve how many engines can stay lit, rather than stepping one at a time.
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

	## Full-throttle thrust from the engines actually running (`st.live`, not the built count).
	func full_thrust(pa: float) -> float:
		var F := 0.0
		for st in v.live_stages():
			if st.spec.get("engine") == null or st.prop <= 0.0: continue
			# A solid's thrust is read at its current point in the grain.
			var burned: float = 1.0 - st.prop / maxf(st.prop0, 1.0)
			F += Rocketry.engine_output(st.spec.engine, st.live, pa, 1.0, burned).F
			if st.spec.get("vacEngine") != null:
				F += Rocketry.engine_output(st.spec.vacEngine, st.spec.vacCount, pa, 1.0, burned).F
		return F

	func current_isp(pa: float) -> float:
		for st in v.live_stages():
			if st.spec.get("engine") != null and st.prop > 0.0:
				return Rocketry.engine_output(st.spec.engine, st.live, pa, 1.0).isp
		return 300.0

	# INTERPLANETARY TRANSFER
	## Plan a transfer to `tgt`.
	##   same parent   Hohmann, waiting for the phase angle
	##   other parent  escape with the right v∞; the departure burn is far smaller than
	##                 the heliocentric Δv (Oberth), and the plan reports both
	## Returns {kind: "hohmann", ...hohmann(), waitS, label}, {kind: "escape", vInf, soi,
	## dvBurn, dvHelio, tof, phase, synodic, label}, or null.
	func plan_transfer(tgt):
		var dominant = null
		for b in v.bodies:
			if b.mass > (dominant.mass if dominant != null else -1.0): dominant = b
		if tgt == null or dominant == null or tgt == v.parent: return null

		# Same well: a Moon shot from LEO is a Hohmann about the Earth. Test which body
		# dominates at the target, not which is heaviest.
		if v.primary_of(tgt) == v.parent or v.parent == dominant:
			var r1 := v.r.length()
			var r2 := Guidance._a.sub_vectors(tgt.pos, v.parent.pos).scale_in(Rocketry.AU_M).length()
			var h := Orbit.hohmann(v.env.mu, r1, r2)
			var want: float = h.phase
			var now := Orbit.phase_angle(v.r, Guidance._a)
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
		var r2b := Guidance._a.sub_vectors(tgt.pos, dominant.pos).scale_in(Rocketry.AU_M).length()
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
				U.fixed(Orbit.phase_angle(v.r, Guidance._a.sub_vectors(target.pos, v.parent.pos)) * 180.0 / PI, 1),
				U.fixed(p.phase * 180.0 / PI, 1)])
			return Guidance.attitude_for(MODE.PROGRADE, v)
		if node == null:
			node = { "dv": DQuat.nrm(Guidance._a.copy_from(v.v)).scale_in(p.dv1).clone(), "t": 0.0, "label": p.label }
		return node_guidance(dt, pa, node)

	# POWERED DESCENT — Apollo's programs, on Apollo's gates
	## The quadratic guidance law. Returns the commanded THRUST acceleration
	## (gravity already added back), in the parent frame, written into `out`.
	func quadratic(rT: DVec3, vT: DVec3, tgo: float, out: DVec3) -> DVec3:
		# Δr = r_T − r − v·t_go , Δv = v_T − v
		Guidance._b.copy_from(rT).sub_in(v.r).add_scaled_in(v.v, -tgo)
		Guidance._c.copy_from(vT).sub_in(v.v)
		out.copy_from(Guidance._b).scale_in(6.0 / (tgo * tgo)).add_scaled_in(Guidance._c, -2.0 / tgo)
		# the engine also has to hold the vehicle up
		v.gravity(v.r, Guidance._d)
		out.sub_in(Guidance._d)
		return out

	## The terminal descent law, shared by every landing. Returns the commanded thrust
	## acceleration in Guidance._e, ground-relative. Vertical and lateral are separate
	## channels; a combined law saturates on a large lateral error and falls on course.
	##   vertical  v_ref(h) = −(v_touch + √(2·a_dec·h)), a_dec = k·(F/m − g), closed
	##             over τ and clamped at zero (free fall above the profile is fuel-optimal)
	##   lateral   null the drift and close on the site, capped at a maximum tilt
	func descent_law(a_max: float, v_touch: float, max_tilt_rad: float, tau: float,
			dec_frac: float = 0.6, v_cap: float = INF, hold_below: float = 0.0) -> DVec3:
		var env: Dictionary = v.env
		var alt := maxf(v.altitude(), 0.0)
		DQuat.nrm(Guidance._up.copy_from(v.r))
		var g: float = env.mu / maxf(v.r.length_sq(), 1.0)
		v.airspeed(v.r, v.v, Guidance._g)
		var v_vert := Guidance._g.dot(Guidance._up)
		Guidance._b.copy_from(Guidance._g).add_scaled_in(Guidance._up, -v_vert)           # lateral drift

		var a_dec := maxf(dec_frac * (a_max - g), 0.05)
		# The reference is capped (Apollo's approach is ~45 m/s at hi-gate). Below
		# `hold_below` it is the touchdown rate: a held-rate final descent.
		var vref := -v_touch if alt < hold_below else -minf(v_touch + sqrt(2.0 * a_dec * alt), v_cap)
		# Feed forward a_dec, the profile's own deceleration: without it a vehicle on the
		# profile is only told to hold speed. None in the held-rate region.
		var a_ff := a_dec if (v_vert < 0.0 and alt >= hold_below) else 0.0
		# Near the ground, floor at g instead of free fall: no altitude is left to recover.
		var floor_a := g if alt < hold_below * 5.0 else 0.0
		var a_vert := maxf(g + a_ff + (vref - v_vert) / tau, floor_a)

		# lateral: kill the drift, and lean gently toward the site
		Guidance._c.set_v(0.0, 0.0, 0.0)
		if site != null:
			Guidance._c.sub_vectors(site, v.r)
			Guidance._c.add_scaled_in(Guidance._up, -Guidance._c.dot(Guidance._up))
			var off := Guidance._c.length()
			# Site-seeking is deliberately weak, or it fights the drift damping.
			if off > 1e-3: Guidance._c.scale_in(minf(off, 25.0) / off * 0.02)
		Guidance._d.copy_from(Guidance._b).scale_in(-1.0 / (tau * 0.7)).add_in(Guidance._c)
		# Lateral authority is a fraction of the engine, not of the vertical command (on
		# the Moon that would allow a tenth of a g).
		var max_lat := a_max * sin(max_tilt_rad)
		if Guidance._d.length() > max_lat: DQuat.set_len(Guidance._d, max_lat)

		v_ref = vref; v_vert_now = v_vert; lat_now = Guidance._b.length()
		return Guidance._e.copy_from(Guidance._up).scale_in(a_vert).add_in(Guidance._d)

	## Rotate a thrust command back toward the airstream until α ≤ α_max = qα_limit / q.
	func aero_limit(cmd: DVec3, out: DVec3) -> DVec3:
		var t := v.telemetry
		var tq: float = t.get("q", 0.0)
		if v.env.atm == null or not (tq > 200.0): return DQuat.nrm(out.copy_from(cmd))
		v.airspeed(v.r, v.v, Guidance._air)
		var va := Guidance._air.length()
		if va < 1.0: return DQuat.nrm(out.copy_from(cmd))
		Guidance._air.scale_in(-1.0 / va)                       # retrograde, the aligned attitude
		DQuat.nrm(out.copy_from(cmd))
		# 0.85 of the limit, leaving margin for gusts and lag.
		var a_max_rad := DQuat.jclamp(0.85 * v.vehicle.limits.qAlpha / tq, 0.01, PI)
		var ang := DQuat.angle_between(out, Guidance._air)
		if ang <= a_max_rad: return out
		# rotate `out` toward the airstream until it is within the limit
		Guidance._c.cross_vectors(Guidance._air, out)
		if Guidance._c.length_sq() < 1e-12: return out.copy_from(Guidance._air)
		DQuat.nrm(Guidance._c)
		return DQuat.apply_axis_angle(out.copy_from(Guidance._air), Guidance._c, a_max_rad)

	## Carry the landing site round with its body by ω × r, the same expression as `place_on_pad`.
	func spin_site(dt: float) -> void:
		if site == null: return
		Guidance._a.set_v(0.0, -v.env.rotRate, 0.0).cross_vectors(Guidance._a, site)
		DQuat.set_len(site.add_scaled_in(Guidance._a, dt), v.env.radius)

	func landing_guidance(dt: float, pa: float):
		var env: Dictionary = v.env
		var t := v.telemetry
		spin_site(dt)
		var prof = v.vehicle.get("descent")
		var alt := v.altitude()
		DQuat.nrm(Guidance._up.copy_from(v.r))
		var v_vert := v.v.dot(Guidance._up)
		var a_max := full_thrust(pa) / v.mass

		if site == null:
			# Place the site where this vehicle can stop: braking from v_h to the hi-gate
			# speed covers (v₁ + v₂)/2 · (v₁ − v₂)/a. A site too short makes the law loft.
			var vh := sqrt(maxf(t.speed * t.speed - v_vert * v_vert, 0.0))
			var v_gate: float = prof.hiGate.vHoriz if prof != null else 130.0
			var brake := maxf(a_max * 0.72, 0.05)
			var rng := maxf((vh + v_gate) * 0.5 * maxf(vh - v_gate, 0.0) / brake,
							(prof.hiGate.range if prof != null else 7000.0) * 2.0)
			var ang: float = rng / env.radius
			DQuat.nrm(Guidance._b.copy_from(v.v).add_scaled_in(Guidance._up, -v_vert))
			site = Guidance._up.clone().scale_in(cos(ang)).add_scaled_in(Guidance._b, sin(ang)).scale_in(env.radius)
			state_name = "P63"
			note("P63 — braking phase")
		var st: DVec3 = site

		if state_name == "P63":
			var gate: Dictionary = prof.hiGate if prof != null else { "alt": 2400.0, "range": 7000.0, "vVert": -45.0, "vHoriz": 129.0 }
			# hi-gate target: `gate.alt` above the site, `gate.range` short of it
			DQuat.nrm(Guidance._a.copy_from(st))
			Guidance._b.copy_from(v.v).add_scaled_in(Guidance._up, -v.v.dot(Guidance._up))
			if Guidance._b.length_sq() < 1.0: Guidance._b.copy_from(Guidance._up).cross_vectors(Guidance._b, Guidance._a)
			DQuat.nrm(Guidance._b)
			var rT := Guidance._a.clone().scale_in(env.radius + gate.alt).add_scaled_in(Guidance._b, -gate.range)
			var vT := Guidance._b.clone().scale_in(gate.vHoriz).add_scaled_in(Guidance._a, gate.vVert)
			# Aim just above the DPS's forbidden throttle band, so P63 flies at full thrust.
			var tgo := track_t_go(rT, vT, a_max, dt, 0.96)
			var cmd := quadratic(rT, vT, tgo, Guidance._e)
			var need := cmd.length()
			v.throttle = limit_throttle(need / maxf(a_max, 1e-6), pa, dt)
			say("P63 — braking · %s km, %s m/s, %s s to hi-gate" % [U.fixed(alt / 1000.0, 1), U.fixed(t.speed, 0), U.fixed(tgo, 0)])
			if alt < gate.alt * 1.12 or tgo < 2.0:
				state_name = "P64"; note("P64 — approach phase")
			return DQuat.nrm(cmd)

		if state_name == "P64":
			var gate: Dictionary = prof.loGate if prof != null else { "alt": 30.0, "range": 11.0 }
			DQuat.nrm(Guidance._a.copy_from(st))
			var _rT := Guidance._a.clone().scale_in(env.radius + gate.alt)
			var _vT := Guidance._a.clone().scale_in(-1.2)
			var cmd := descent_law(a_max, 2.0, 0.60, 3.5, 0.6, 50.0)
			v.throttle = limit_throttle(cmd.length() / maxf(a_max, 1e-6), pa, dt)
			say("P64 — approach · %s m, %s of %s m/s, %s m/s lateral" % [U.fixed(alt, 0), U.fixed(v_vert_now, 1), U.fixed(v_ref, 1), U.fixed(lat_now, 1)])
			# Lo-gate is a state (30 m up, 11 m short, nearly stopped), not an altitude.
			Guidance._b.copy_from(v.v).add_scaled_in(Guidance._up, -v.v.dot(Guidance._up))
			var lateral := Guidance._b.length()
			if (alt < gate.alt * 3.0 and lateral < 8.0) or alt < gate.alt * 0.7:
				state_name = "P66"; t_go = null; note("P66 — terminal descent")
			return DQuat.nrm(cmd)

		# P66: the same law at the rated touchdown rate, with a tighter τ and more lean.
		var a_cmd := descent_law(a_max, 0.8, 0.35, 1.4, 0.55, 20.0, 12.0)
		v.throttle = limit_throttle(a_cmd.length() / maxf(a_max, 1e-6), pa, dt)
		say("P66 — terminal · %s m, %s m/s, %s m/s lateral" % [U.fixed(alt, 1), U.fixed(v_vert_now, 2), U.fixed(lat_now, 2)])
		if v.phase == Vessel.PHASE.LANDED:
			note("Landed"); program = null; v.throttle = 0.0
		return DQuat.nrm(a_cmd)

	## t_go that puts the commanded acceleration at `frac` of the engine's, by
	## bisection: |a_cmd| falls monotonically with t_go (Apollo solved a quartic). The
	## upper bracket is braking Δv over the available acceleration (Apollo PDI: 530 s,
	## flown in 514). track_t_go counts down and nudges toward the fresh solution;
	## re-solving outright jumps between frames and the throttle chatters.
	func track_t_go(rT: DVec3, vT: DVec3, a_max: float, dt: float, frac: float) -> float:
		var solved := solve_t_go(rT, vT, a_max, frac)
		t_go = solved if t_go == null else maxf(t_go - dt, 1.0) * 0.97 + solved * 0.03
		return t_go

	func solve_t_go(rT: DVec3, vT: DVec3, a_max: float, frac: float = 0.72) -> float:
		var dv := Guidance._e.copy_from(vT).sub_in(v.v).length()
		var est := DQuat.jclamp(dv / maxf(a_max * 0.85, 0.05), 4.0, 4000.0)
		var lo := 2.0
		var hi := est * 2.2
		var want := a_max * frac
		# |a_cmd| decreasing in t_go, so bisect on the sign of (a − want).
		for i in 34:
			var mid := 0.5 * (lo + hi)
			var a := quadratic(rT, vT, mid, Guidance._e).length()
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
		# Below the deep-throttle floor, sit at the floor; zero is only for a real shutdown.
		var floor_th: float = eng.get("throttleMin", 0.0)
		if th < floor_th: th = 0.0 if x < 0.02 else floor_th
		# The Apollo DPS couldn't run between 60% and 92.5%: go to the nearer edge.
		var fb = eng.get("forbidden")
		if fb != null and th > fb[0] and th < fb[1]:
			th = fb[0] if (th - fb[0]) < (fb[1] - th) else fb[1]
		return th

	# HOVERSLAM — propulsive booster recovery
	func hoverslam_guidance(dt: float, pa: float):
		var env: Dictionary = v.env
		var alt := v.altitude()
		DQuat.nrm(Guidance._up.copy_from(v.r))
		v.airspeed(v.r, v.v, Guidance._a)
		var speed := Guidance._a.length()
		var v_vert := v.v.dot(Guidance._up)
		var g: float = env.mu / v.r.length_sq()
		var _m_min := throttle_for(0.0001)
		var a_max := full_thrust(pa) / v.mass

		# The landing burn has priority over the entry burn. The handover tests the
		# shortest possible landing burn (every engine, full throttle), not the selected
		# engine count, which jumps and would make the burn stutter.
		var st_e = v.current_stage
		var per_e: float = Rocketry.engine_output(st_e.spec.engine, 1, pa, 1.0).F / maxf(v.mass, 1.0) \
			if (st_e != null and st_e.spec.get("engine") != null) else 0.0
		var a_full := maxf((st_e.spec.count if st_e != null else 1) * per_e - g, 0.3)
		var h_burn_pre := (v_vert * v_vert) / (2.0 * a_full)
		# Entry burn: scheduled by dynamic pressure, not altitude, so it adapts to the trajectory.
		var q_lim: float = v.vehicle.limits.maxQ
		# The landing-burn test comes first, so the entry burn can't run to the ground.
		var sel_pre := solve_landing_burn(alt, v_vert, pa, g)
		# The landing burn belongs in the last few km; above that, air and the entry burn brake.
		var terminal_ceiling: float = env.atm.top * 0.08 if env.atm != null else INF
		# Ignite at h_burn, not before: with TWR > 1 at minimum throttle, early ignition climbs.
		var must_land: bool = slamming or (alt <= sel_pre.hBurn * 1.05 and alt < terminal_ceiling)
		# Hysteresis on q: start at a tenth of the limit (~40 km on a booster), stop at 6%.
		var q_on := q_lim * (0.06 if entry_burning else 0.10)
		var tq: float = v.telemetry.get("q", 0.0)
		# The entry burn stops by half the terminal ceiling; otherwise near-surface q keeps
		# it lit all the way down.
		if env.atm != null and not must_land and alt > terminal_ceiling * 0.5 \
				and alt > h_burn_pre * 1.6 and tq > q_on:
			# Throttle on how far q is over the line, on three engines as the real booster uses.
			v.set_engine_count(3)
			manual_engines = true
			var over := tq / (q_lim * 0.10) - 1.0
			# Through the shared limiter, so the g cap and engine shutdown apply here too.
			v.throttle = limit_throttle(DQuat.jclamp(0.45 + over * 2.5, 0.0, 1.0), pa, dt)
			if not entry_burning:
				entry_burning = true
				note("Entry burn — %s km, %s m/s, q %s kPa" % [U.fixed(alt / 1000.0, 0), U.fixed(speed, 0), U.fixed(tq / 1000.0, 1)])
			say("Entry burn — %s km, %s m/s, q %s kPa" % [U.fixed(alt / 1000.0, 0), U.fixed(speed, 0), U.fixed(tq / 1000.0, 1)])
			return Guidance.attitude_for(MODE.RETROGRADE, v)
		if entry_burning:
			entry_burning = false; entry_done = true; v.throttle = 0.0; note("Entry burn cutoff")

		# h_burn(n) = v²/(2·(n·F_engine/m − g)), for the engine count solve_landing_burn picked.
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
		# Same terminal law; for a booster the reference is the hoverslam profile. Keep the
		# tilt small: 6° at 25 kPa is already half the airframe's q·α.
		var cmd := descent_law(a_max, 2.0, 0.10, 1.0, 0.55, INF, 30.0)
		v.throttle = limit_throttle(cmd.length() / maxf(a_max, 1e-6), pa, dt)
		say("Landing burn — %s m, %s of %s m/s, throttle %s%%" % [U.fixed(alt, 0), U.fixed(v_vert_now, 1), U.fixed(v_ref, 1), U.fixed(v.throttle * 100.0, 0)])
		if v.phase == Vessel.PHASE.LANDED:
			program = null; v.throttle = 0.0; note("Booster recovered")
		return aero_limit(cmd, Guidance._a)

	## Engine count and ignition altitude for the landing burn: { n: int, hBurn: float }.
	func solve_landing_burn(_alt: float, v_vert: float, pa: float, g: float) -> Dictionary:
		var st = v.current_stage
		if st == null or st.spec.get("engine") == null: return { "n": 1, "hBurn": 0.0 }
		var per: float = Rocketry.engine_output(st.spec.engine, 1, pa, 1.0).F / maxf(v.mass, 1.0)
		# The most engines the g limit allows: more deceleration means a later ignition
		# and less time holding the vehicle up.
		var g_limit: float = (v.vehicle.limits.maxG * 0.85 * Rocketry.G0 + g)
		var n := int(DQuat.jclamp(floor(g_limit / maxf(per, 1e-6)), 1.0, float(st.spec.count)))
		# Size ignition on a deceleration margin like the descent law's, not on the full
		# deceleration, or any lag arrives short.
		var a := maxf(0.58 * (n * per - g), 0.3)
		return { "n": n, "hBurn": (v_vert * v_vert) / (2.0 * a) }

	# ENTRY, DESCENT AND LANDING — the atmospheric one
	func edl_guidance(dt: float, pa: float):
		var env: Dictionary = v.env
		var t := v.telemetry
		spin_site(dt)
		var plan_edl = v.vehicle.get("edl")
		var alt := v.altitude()
		DQuat.nrm(Guidance._up.copy_from(v.r))
		v.airspeed(v.r, v.v, Guidance._a)
		var speed := Guidance._a.length()
		var v_vert := v.v.dot(Guidance._up)
		v.throttle = 0.0

		if state_name == null:
			state_name = "entry"
			note("Entry interface — %s km, %s km/s, flight path %s°" % [U.fixed(alt / 1000.0, 0), U.fixed(speed / 1000.0, 2),
				U.fixed(asin(clampf(v_vert / maxf(speed, 1.0), -1.0, 1.0)) * 180.0 / PI, 1)])

		if state_name == "entry":
			say("Entry — %s km, %s m/s, %s W/cm²" % [U.fixed(alt / 1000.0, 1), U.fixed(speed, 0), U.fixed(t.heat / 1e4, 1)])
			# Heat shield forward. Deploy on Mach and q, as a chute is qualified (MSL: Mach 1.7,
			# ~750 Pa), not on altitude.
			var ch: Dictionary = plan_edl.chute if (plan_edl != null and plan_edl.get("chute") != null) else { "mach": 1.7, "deployQ": 750.0 }
			var dq: float = ch.get("deployQ", 750.0)
			# The q lower bound keeps it from firing in vacuum at the entry interface.
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
			# Release the backshell low and slow (~1.8 km, 100 m/s): the chute does the braking.
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
		if site == null: site = Guidance._up.clone().scale_in(env.radius)
		DQuat.nrm(Guidance._a.copy_from(site))
		var _rT := Guidance._a.clone().scale_in(env.radius + 0.5)
		var cmd := descent_law(a_max, absf(sk.vTouch), 0.35, 1.8, 0.55, 120.0, sk.alt * 1.5)
		v.throttle = limit_throttle(cmd.length() / maxf(a_max, 1e-6), pa, dt)
		if alt < sk.alt and not crane_out:
			crane_out = true
			note("Sky crane — rover on the cables")
		say("Powered descent — %s m, %s m/s" % [U.fixed(alt, 0), U.fixed(v_vert, 2)])
		if v.phase == Vessel.PHASE.LANDED:
			program = null; v.throttle = 0.0; note("Touchdown")
		return aero_limit(cmd, Guidance._b)

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
			node = { "dv": DQuat.nrm(Guidance._a.copy_from(v.v)).scale_in(dv).clone(), "t": 0.0, "label": "Deorbit burn" }
		return node_guidance(dt, pa, node)
