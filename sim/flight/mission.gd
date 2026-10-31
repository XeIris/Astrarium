class_name Mission
extends RefCounted

# A mission: a destination and a goal ("orbit" or "land"), planned as legs and
# flown by the autopilot with no input from the pilot. Each burn is a node that
# Guidance flies; between burns the mission coasts on rails, choosing a time warp
# that reaches the next event in a few seconds. The route estimates and the arrival
# guidance are derived in docs/physics/missions.md.

const PARK_ALT := 200e3
## Seconds of real time the warp aims to leave before the next event.
const LOOKAHEAD_S := 4.0
## A burn is handed to the autopilot this long before ignition, so the vehicle
## turns at a warp it can steer at (on rails attitude is held, not flown).
const HANDOVER_S := 240.0
const LANDING_ALT := 15e3

var flight                      # Spaceflight
var dest: Body
var goal := "orbit"
var plan: Dictionary = {}
var leg := 0
var auto_warp := true
var done := false
var failed := ""
var status := ""
## The next scheduled burn: {at: coordinate s, make: Callable() -> DVec3 Δv at `at`, label}.
var _burn = null
var _burn_engaged := false
## Leg-local state.
var _stage := ""
var _t_arr := 0.0
var _fixes := 0
var _aero_rp := 0.0        # the aerocapture pass's periapsis radius, m, once solved
var _aero_in := false      # the pass has entered the air

# PLANNING

static func _mu(b: Body) -> float: return Rocketry.GM_SUN * b.mass
static func _rel_pos(b: Body, c: Body) -> DVec3:
	return DVec3.new().sub_vectors(b.pos, c.pos).scale_in(Rocketry.AU_M)
static func _rel_vel(b: Body, c: Body) -> DVec3:
	return DVec3.new().sub_vectors(b.vel, c.vel).scale_in(Rocketry.AU_M / Rocketry.YR_S)
## The orrery-axis vector `w`, in place, in the vessel's parent frame (that of v.r and v.v).
static func _local(v: Vessel, w: DVec3) -> DVec3:
	return v.to_local(w, w)

## The radius a mission parks at around `b`: above any air, and Apollo's 110 km at the Moon.
static func park_radius(b: Body) -> float:
	var env := Rocketry.flight_env(b)
	var h := 110e3 if b.name == "Moon" else maxf(PARK_ALT * 0.5, float(env.atm.top) * 1.25 if env.atm != null else 0.0)
	if b.name == "Earth": h = PARK_ALT
	return float(env.radius) + h

## Launch to a low parking orbit: the orbital speed less the ground's, plus gravity
## and drag losses (~1.5 km/s from Earth, a few per cent from an airless body).
static func launch_dv(b: Body, r_park: float) -> float:
	var env := Rocketry.flight_env(b)
	var v_orb := sqrt(float(env.mu) / r_park)
	var loss := 1500.0 * sqrt(float(env.gSurf) / 9.81) if env.atm != null else 0.06 * v_orb
	return v_orb - float(env.vRotEq) * 0.9 + loss

## A burn from a circular orbit of radius r0 about mu onto a hyperbola leaving with v∞.
static func escape_dv(mu: float, r0: float, v_inf: float) -> float:
	return sqrt(v_inf * v_inf + 2.0 * mu / r0) - sqrt(mu / r0)

## Bodies `b` orbits, nearest first, ending with the dominant mass.
static func ancestors(v: Vessel, b: Body) -> Array:
	var out: Array = []
	var c = v.primary_of(b)
	var guard := 0
	while c != null and guard < 8:
		out.append(c)
		c = v.primary_of(c)
		guard += 1
	return out

## Seconds until the phase angle (target ahead of the departure body, about their
## common primary) reaches `want`, given each one's mean motion.
static func window_wait(phase_now: float, want: float, n_dep: float, n_tgt: float) -> float:
	var rate := n_tgt - n_dep
	if absf(rate) < 1e-15: return 0.0
	var d := want - phase_now
	var period := 2.0 * PI / absf(rate)
	var t := d / rate
	t = fmod(t, period)
	if t < 0.0: t += period
	return t

# Porkchop results by departure/arrival pair, reused until the clock moves a
# fiftieth of a synodic period (the planner reprices twice a second).
static var _pork_cache := {}

## The cheapest departure in the next synodic period (plus a tenth) from `Pc` to `Dc`
## about `C`, over flight times from 0.6 to 1.4 Hohmann. With a parking radius at
## either end, the cost is the burn there (Oberth); otherwise v∞. Returns the
## porkchop's best cell with t_dep counted from now, plus grid, t_deps and tofs, or {}.
static func porkchop_window(v: Vessel, Pc: Body, Dc: Body, C: Body, r_park_dep: float, r_park_arr: float,
		n_dep: int = 40, n_tof: int = 15) -> Dictionary:
	var muC := _mu(C)
	var rP := _rel_pos(Pc, C).length()
	var rD := _rel_pos(Dc, C).length()
	var h := Orbit.hohmann(muC, rP, rD)
	var now: float = v.coord
	var key := "%d:%d:%d" % [Pc.get_instance_id(), Dc.get_instance_id(), C.get_instance_id()]
	var hit = _pork_cache.get(key)
	if hit != null and absf(now - float(hit.now)) < float(h.synodic) / 50.0 and hit.rp == r_park_dep and hit.ra == r_park_arr:
		var shifted: Dictionary = hit.result.duplicate()
		if not shifted.is_empty(): shifted.t_dep = maxf(float(shifted.t_dep) - (now - float(hit.now)), 0.0)
		return shifted
	var t_deps: Array = []
	var span := float(h.synodic) * 1.1
	for i in n_dep: t_deps.append(span * float(i) / float(n_dep - 1))
	var tofs: Array = []
	for j in n_tof: tofs.append(float(h.tof) * lerpf(0.6, 1.4, float(j) / float(n_tof - 1)))
	var mu_p := _mu(Pc); var mu_d := _mu(Dc)
	var cost := func(vd: float, va: float) -> float:
		var cd := escape_dv(mu_p, r_park_dep, vd) if r_park_dep > 0.0 else vd
		var ca := escape_dv(mu_d, r_park_arr, va) if r_park_arr > 0.0 else va
		return cd + ca
	var pc := Orbit.porkchop(_rel_pos(Pc, C), _rel_vel(Pc, C), muC + mu_p, _rel_pos(Dc, C), _rel_vel(Dc, C), muC + mu_d,
		muC, t_deps, tofs, cost)
	var result := {}
	if not pc.best.is_empty():
		result = pc.best.duplicate()
		result.grid = pc.grid; result.t_deps = t_deps; result.tofs = tofs
		result.hohmann = h
	_pork_cache[key] = {"now": now, "rp": r_park_dep, "ra": r_park_arr, "result": result}
	return result

## The route from where the vessel is to `dest`, with each leg's Δv and duration, the
## propellant it costs and whether the tanks hold it. Keys: ok, flyable, why, case,
## type, legs [{key, label, dv, t}], dv, dv_avail, prop, prop_avail, short, wait, tof,
## total, r_cap.
static func plan_route(v: Vessel, target: Body, want: String = "orbit") -> Dictionary:
	var out := {"ok": false, "flyable": false, "why": "", "case": "", "type": "", "legs": [],
		"dv": 0.0, "dv_avail": v.delta_v_remaining(0.0), "prop": 0.0, "prop_avail": 0.0,
		"short": 0.0, "wait": 0.0, "tof": 0.0, "total": 0.0, "r_cap": 0.0, "goal": want}
	for st in v.stages:
		if st.attached and st.spec.get("engine") != null: out.prop_avail += st.prop
	if target == null or not target.alive:
		out.why = "No destination"
		return out
	var P: Body = v.parent
	var legs: Array = out.legs
	var grounded: bool = v.phase == Vessel.PHASE.PRELAUNCH or v.phase == Vessel.PHASE.LANDED
	# Off the ground, the route starts from the orbit the vessel is in, so it must be one:
	# climbing, coming down or suborbital it has no launch leg, and a burn or a skip from
	# there would cut the ascent short or coast it through the air.
	if not grounded:
		if [Vessel.PHASE.ASCENT, Vessel.PHASE.ENTRY, Vessel.PHASE.DESCENT, Vessel.PHASE.ROLLOUT].has(v.phase):
			out.why = "Reach orbit first"
			return out
		var floor_r := float(v.env.radius) + (float(v.env.atm.top) if v.env.atm != null else 0.0)
		if float(Orbit.elements(v.r, v.v, v.env.mu).rp) < floor_r:
			out.why = "Reach orbit first: the periapsis is %s" % ("in the air" if v.env.atm != null else "below the surface")
			return out
	var r0 := park_radius(P) if grounded else maxf(v.r.length(), float(v.env.radius))
	if grounded:
		legs.append({"key": "launch", "label": "Launch to orbit around %s" % P.name, "dv": launch_dv(P, r0), "t": 600.0})
	var dest_env := Rocketry.flight_env(target)
	var r_cap := park_radius(target)
	out.r_cap = r_cap
	var mu_d := _mu(target)
	var muP := _mu(P)
	var anc_p := ancestors(v, P)
	var anc_d := ancestors(v, target)

	if target == P:
		out.case = "here"
		out.type = "Orbit around %s" % P.name if want == "orbit" else "Landing on %s" % P.name
		if not grounded and want == "orbit":
			out.type = "Already in orbit around %s" % P.name
	elif not anc_d.is_empty() and anc_d[0] == P:
		# A moon of the body we are at: a Hohmann about it, then capture.
		out.case = "moon"
		var r2 := _rel_pos(target, P).length()
		var h := Orbit.hohmann(muP, r0, r2)
		var v_apo := sqrt(muP * 2.0 * r0 / (r2 * (r0 + r2)))
		var v_inf := absf(_rel_vel(target, P).length() - v_apo)
		var rel := _local(v, _rel_pos(target, P))
		var phase_now := Orbit.phase_angle(rel.scaled(-1.0), rel) if grounded \
			else Orbit.phase_angle(v.r, rel, v.r.cross(v.v))
		var wait := window_wait(phase_now, h.phase, sqrt(muP / pow(r0, 3.0)), sqrt(muP / pow(r2, 3.0)))
		out.type = "Hohmann transfer to a moon of %s" % P.name
		legs.append({"key": "depart", "label": "Transfer burn", "dv": absf(h.dv1), "t": wait})
		legs.append({"key": "midcourse", "label": "Course corrections", "dv": plane_fix_dv(v, target, P, r0, r2) + 15.0, "t": h.tof})
		legs.append({"key": "approach", "label": "Aim the arrival", "dv": 0.04 * v_inf + 15.0, "t": 0.0})
		legs.append({"key": "capture", "label": "Capture into orbit", "dv": escape_dv(mu_d, r_cap, v_inf), "t": 3600.0})
		out.wait = wait; out.tof = h.tof
	elif not anc_p.is_empty() and anc_p[0] == target:
		# Back from a moon to the planet it circles: leave on an ellipse whose
		# periapsis is the parking orbit, then capture at periapsis.
		out.case = "parent"
		var aP := _rel_pos(P, target).length()
		var vP := _rel_vel(P, target).length()
		var v_apo := sqrt(mu_d * 2.0 * r_cap / (aP * (aP + r_cap)))
		var v_inf := absf(vP - v_apo)
		var tof := PI * sqrt(pow((aP + r_cap) * 0.5, 3.0) / mu_d)
		var v_peri := sqrt(mu_d * 2.0 * aP / (r_cap * (aP + r_cap)))
		out.type = "Return to %s" % target.name
		legs.append({"key": "escape", "label": "Departure burn", "dv": escape_dv(muP, r0, v_inf), "t": 0.0})
		legs.append({"key": "approach", "label": "Aim the arrival", "dv": 25.0, "t": tof})
		legs.append({"key": "capture", "label": "Capture into orbit", "dv": v_peri - sqrt(mu_d / r_cap), "t": 3600.0})
		out.tof = tof
	else:
		# Different branches: a Hohmann about the lowest common primary.
		var C = null
		for a in anc_p:
			if anc_d.has(a) or a == target: C = a; break
		if C == null:
			out.why = "No common primary between %s and %s" % [P.name, target.name]
			return out
		var Pc: Body = P
		for a in [P] + anc_p:
			if v.primary_of(a) == C: Pc = a; break
		var Dc: Body = target
		for a in [target] + anc_d:
			if v.primary_of(a) == C: Dc = a; break
		var muC := _mu(C)
		var rP := _rel_pos(Pc, C).length()
		var rD := _rel_pos(Dc, C).length()
		var h := Orbit.hohmann(muC, rP, rD)
		var v_inf_dep := absf(h.dv1)
		var v_inf_arr := absf(h.dv2)
		var phase_now := Orbit.phase_angle(_rel_pos(Pc, C), _rel_pos(Dc, C))
		var wait := window_wait(phase_now, h.phase, sqrt(muC / pow(rP, 3.0)), sqrt(muC / pow(rD, 3.0)))
		var tof: float = h.tof
		# The real orbits are eccentric and inclined, so the window and its cost come
		# from a porkchop of Lambert arcs; the circular Hohmann is the fallback.
		var pc := porkchop_window(v, Pc, Dc, C, r0 if Pc == P else 0.0, r_cap if Dc == target else 0.0)
		if not pc.is_empty():
			v_inf_dep = pc.v_inf_dep; v_inf_arr = pc.v_inf_arr
			wait = pc.t_dep; tof = pc.tof
			out["porkchop"] = pc
		var dep := escape_dv(muP, r0, v_inf_dep)
		if Pc != P:
			# From a moon: leave it, then the planet it circles, on the same hyperbola.
			var v_inf_p := escape_dv(_mu(Pc), _rel_pos(P, Pc).length(), v_inf_dep) + sqrt(_mu(Pc) / _rel_pos(P, Pc).length())
			dep = escape_dv(muP, r0, absf(v_inf_p - _rel_vel(P, Pc).length()))
		var cap := escape_dv(mu_d, r_cap, v_inf_arr)
		if Dc != target:
			cap = escape_dv(_mu(Dc), _rel_pos(target, Dc).length(), v_inf_arr) + escape_dv(mu_d, r_cap, 0.0) * 0.3
		out.case = "planet" if (Pc == P and Dc == target) else "other"
		var kind := "Lambert transfer" if out.has("porkchop") else "Hohmann transfer"
		out.type = "Interplanetary %s" % kind.to_lower() if C.type == "star" else "%s about %s" % [kind, C.name]
		legs.append({"key": "escape", "label": "Departure burn (escape %s)" % P.name, "dv": dep, "t": wait})
		legs.append({"key": "midcourse", "label": "Course corrections", "dv": 0.03 * v_inf_dep + 20.0, "t": tof})
		legs.append({"key": "approach", "label": "Aim the arrival", "dv": 0.02 * v_inf_arr + 20.0, "t": 0.0})
		if Dc == target and aero_capable(v, target):
			# Through the air heat shield first, out on an ellipse to the parking radius,
			# then a burn there lifts the periapsis out of the air.
			var rp_a := float(dest_env.radius) + 0.5 * float(dest_env.atm.top)
			var raise := sqrt(mu_d / r_cap) - sqrt(mu_d * 2.0 * rp_a / (r_cap * (rp_a + r_cap)))
			legs.append({"key": "aerocapture", "label": "Aerocapture, then raise the periapsis", "dv": raise, "t": 3600.0})
			out["aero"] = true
		elif Dc == target and dest_env.atm != null:
			# No heat shield: capture onto a long ellipse, then let the upper air take the
			# apoapsis down pass by pass, as Magellan, MGS and MRO did.
			var ra_c := AEROBRAKE_RA * r_cap
			var cap_e := sqrt(v_inf_arr * v_inf_arr + 2.0 * mu_d / r_cap) - sqrt(mu_d * 2.0 * ra_c / (r_cap * (r_cap + ra_c)))
			legs.append({"key": "capture", "label": "Capture onto a long ellipse", "dv": cap_e, "t": 3600.0})
			legs.append({"key": "aerobrake", "label": "Aerobrake, then raise the periapsis", "dv": 30.0,
				"t": aerobrake_estimate(v, target, r_cap, ra_c)})
			out["ra_cap"] = ra_c
			out["aero"] = true
		else:
			legs.append({"key": "capture", "label": "Capture into orbit", "dv": cap, "t": 3600.0})
		out.wait = wait; out.tof = tof
		out["primary"] = C
	if want == "land":
		if dest_env.atm != null:
			out.why = "Landing through an atmosphere isn't planned yet — the autopilot can take you to orbit"
		else:
			var v_c := sqrt(mu_d / r_cap)
			legs.append({"key": "descend", "label": "Descent orbit", "dv": v_c - sqrt(mu_d * 2.0 * (float(dest_env.radius) + LANDING_ALT) / (r_cap * (r_cap + float(dest_env.radius) + LANDING_ALT))), "t": 3600.0})
			legs.append({"key": "land", "label": "Powered descent and landing", "dv": sqrt(mu_d / (float(dest_env.radius) + LANDING_ALT)) * 1.08, "t": 720.0})
	var dv := 0.0
	var t_total := 0.0
	for l in legs:
		dv += float(l.dv); t_total += float(l.t)
	out.dv = dv
	out.total = t_total
	out.prop = propellant_for(v, dv)
	out.short = maxf(dv - float(out.dv_avail), 0.0)
	out.ok = out.why == ""
	out.flyable = out.ok and out.case in ["here", "moon", "parent", "planet"] and out.short <= 0.0 \
		and (want != "land" or _can_land(v, target))
	if out.ok and want == "land" and not _can_land(v, target):
		out.why = "This vehicle has no landing gear or too little thrust for %s's gravity" % target.name
	return out

## The plane change the course corrections make: about half the angle between the
## parking orbit and the moon's (the transfer burn is made near where the planes
## cross), turned at the transfer's speed most of the way out. From the ground the
## parking orbit is the one a launch due east would reach now: its pole is the
## site's north.
static func plane_fix_dv(v: Vessel, target: Body, P: Body, r0: float, r2: float) -> float:
	var n_moon := _local(v, DVec3.new().cross_vectors(_rel_pos(target, P), _rel_vel(target, P)))
	var n_park := DVec3.new().cross_vectors(v.r, v.v)
	if v.phase != Vessel.PHASE.ORBIT:
		var up := DQuat.nrm(v.r.clone())
		n_park = Orbit.K.clone().add_scaled_in(up, -Orbit.K.dot(up))
		if n_park.length_sq() < 1e-12: n_park = Orbit.K.clone()
	var ang := acos(DQuat.jclamp(n_moon.dot(n_park) / maxf(n_moon.length() * n_park.length(), 1e-30), -1.0, 1.0))
	return 2.0 * _transfer_speed(_mu(P), r0, r2, 0.85) * sin(ang * 0.25)

## Speed on the r0 → r2 transfer ellipse at fraction `f` of the way out in radius.
static func _transfer_speed(mu: float, r0: float, r2: float, f: float) -> float:
	var r := lerpf(r0, r2, f)
	return sqrt(maxf(mu * (2.0 / r - 2.0 / (r0 + r2)), 0.0))

## A vehicle can land somewhere if something attached has gear and enough thrust.
static func _can_land(v: Vessel, b: Body) -> bool:
	var gear := false
	var thrust := 0.0
	for st in v.stages:
		if not st.attached: continue
		if st.spec.get("gear") != null: gear = true
		var e = st.spec.get("engine")
		if e != null: thrust = maxf(thrust, float(e.get("thrustVac", 0.0)) * float(st.spec.get("count", 1)))
	var env := Rocketry.flight_env(b)
	return gear and thrust / maxf(v.mass * float(env.gSurf), 1.0) > 1.2

## Propellant a Δv costs from the attached stages, lowest first, by the rocket equation.
static func propellant_for(v: Vessel, dv: float) -> float:
	var live: Array = []
	for st in v.stages:
		if st.attached: live.append(st)
	var mass := v.mass
	var used := 0.0
	var rem := dv
	for st in live:
		if rem <= 0.0: break
		var e = st.spec.get("engine")
		if e == null or st.prop <= 0.0:
			continue
		var ve: float = Rocketry.G0 * float(e.ispVac)
		var need := mass * (1.0 - exp(-rem / ve))
		var take := minf(need, st.prop)
		used += take
		rem -= ve * log(mass / (mass - take))
		mass -= take + st.spec.dry
	return used

# FLYING

static func create(f, target: Body, want: String) -> Mission:
	var m := Mission.new()
	m.flight = f
	m.dest = target
	m.goal = want
	m.plan = plan_route(f.vessel, target, want)
	if not m.plan.flyable:
		m.failed = m.plan.why if m.plan.why != "" else ("%s km/s short" % U.fixed(float(m.plan.short) / 1000.0, 2))
	else:
		f.vessel.log_event("Mission — %s: %s" % [m.title(), m.plan.type])
	return m

func title() -> String:
	return ("Land on %s" if goal == "land" else "Orbit %s") % dest.name

func legs() -> Array: return plan.get("legs", [])

func leg_key() -> String:
	var l := legs()
	return str(l[leg].key) if leg < l.size() else ""

func abort(why: String = "Mission aborted") -> void:
	failed = why
	var ap = flight.autopilot
	if ap != null and ap.program == "node": ap.disengage()
	flight.vessel.log_event(why)

func _next() -> void:
	leg += 1
	_stage = ""
	_burn = null
	_burn_engaged = false
	_fixes = 0
	_aero_in = false
	if leg >= legs().size():
		done = true
		status = "Mission complete — %s" % title()
		flight.vessel.log_event(status)
		if auto_warp: flight.set_warp(0)

## Called each frame before guidance. dt is wall time.
func update(dt: float) -> void:
	if done or failed != "": return
	var v: Vessel = flight.vessel
	var ap = flight.autopilot
	if v == null or ap == null: return
	if v.phase == Vessel.PHASE.DESTROYED:
		failed = "Vehicle lost — %s" % str(v.failure)
		return
	if not dest.alive:
		abort("%s is gone" % dest.name); return
	match leg_key():
		"launch": _leg_launch(v, ap)
		"circularize": _leg_circularize(v, ap)
		"depart": _leg_depart_moon(v, ap)
		"escape": _leg_escape(v, ap)
		"midcourse": _leg_midcourse(v, ap)
		"approach": _leg_approach(v, ap)
		"capture": _leg_capture(v, ap)
		"aerocapture": _leg_aerocapture(v, ap)
		"aerobrake": _leg_aerobrake(v, ap)
		"descend": _leg_descend(v, ap)
		"land": _leg_land(v, ap)
		_: _next()
	if done or failed != "": return
	_fly_burn(v, ap)
	if auto_warp: _pace(v, ap)

# The legs. Each sets `status`, schedules at most one burn, and calls _next() when
# its condition is met.

func _leg_launch(v: Vessel, ap) -> void:
	if _stage == "":
		_stage = "flying"
		if v.phase == Vessel.PHASE.PRELAUNCH:
			flight.run_program("ascent")
		elif v.phase == Vessel.PHASE.LANDED:
			ap.engage("ascent")
	status = "Launch — %s" % ap.status
	if flight.count == null and ap.program == null:
		if v.phase == Vessel.PHASE.ORBIT and float(v.telemetry.get("peri", 0.0)) > 0.0:
			_next()
		elif v.phase != Vessel.PHASE.PRELAUNCH:
			abort("Launch did not reach orbit")

func _leg_circularize(v: Vessel, ap) -> void:
	if _stage == "":
		_stage = "flying"
		ap.engage("circularize")
	status = "Circularize — %s" % ap.status
	if ap.program == null: _next()

## A moon of the parent: wait for the Hohmann phase, then burn to raise the
## apoapsis to the moon's distance.
func _leg_depart_moon(v: Vessel, ap) -> void:
	var P: Body = v.parent
	var mu := _mu(P)
	if _stage == "":
		var r1 := v.r.length()
		var r2 := _rel_pos(dest, P).length()
		var h := Orbit.hohmann(mu, r1, r2)
		var wait := window_wait(Orbit.phase_angle(v.r, _local(v, _rel_pos(dest, P)), v.r.cross(v.v)), h.phase,
			sqrt(mu / pow(r1, 3.0)), _rel_vel(dest, P).length() / r2)
		var at := v.coord + maxf(wait, 300.0)
		_t_arr = at + h.tof
		_schedule(at, "Transfer burn", func() -> DVec3:
			var rb := DVec3.new(); var vb := DVec3.new()
			Orbit.propagate(v.r, v.v, mu, float(_burn.at) - v.coord, rb, vb)
			var R := rb.length()
			var want := sqrt(mu * (2.0 / R - 2.0 / (R + r2)))
			return DQuat.nrm(vb.clone()).scale_in(want - vb.length()))
		_stage = "burn"
	status = _burn_status("Transfer to %s" % dest.name)
	if _stage == "burn" and _burn_done(ap): _next()

## Another planet (or home from a moon): wait for the window, then leave from the
## point of the parking orbit whose escape asymptote points along the transfer.
func _leg_escape(v: Vessel, ap) -> void:
	var P: Body = v.parent
	var mu := _mu(P)
	if _stage == "":
		var d_inf := DVec3.new()
		var v_inf := 0.0
		var at := v.coord + 300.0
		if plan.case == "parent":
			# Home from a moon: leave backwards along the moon's own orbit.
			var aP := _rel_pos(P, dest).length()
			var v_apo := sqrt(_mu(dest) * 2.0 * plan.r_cap / (aP * (aP + plan.r_cap)))
			var vP := _rel_vel(P, dest)
			v_inf = absf(vP.length() - v_apo)
			d_inf = DQuat.nrm(_local(v, vP.clone())).scale_in(-1.0)
			_t_arr = at + PI * sqrt(pow((aP + plan.r_cap) * 0.5, 3.0) / _mu(dest))
		else:
			var C: Body = plan.primary
			var muC := _mu(C)
			var rP := _rel_pos(P, C).length()
			var rD := _rel_pos(dest, C).length()
			var h := Orbit.hohmann(muC, rP, rD)
			var wait := window_wait(Orbit.phase_angle(_rel_pos(P, C), _rel_pos(dest, C)), h.phase,
				sqrt(muC / pow(rP, 3.0)), sqrt(muC / pow(rD, 3.0)))
			var pc := porkchop_window(v, P, dest, C, v.r.length(), plan.r_cap) if plan.has("porkchop") else {}
			if not pc.is_empty(): wait = pc.t_dep
			at = v.coord + maxf(wait, 300.0)
			# Without a porkchop, leave along the planet's own motion with the Hohmann
			# v∞ (a 180° transfer has no Lambert plane); the course corrections take
			# out what eccentric, inclined orbits leave.
			v_inf = absf(h.dv1)
			# The planet's velocity at the departure, which can be a year or more away.
			var rE := DVec3.new(); var vE := DVec3.new()
			if not Orbit.propagate(_rel_pos(P, C), _rel_vel(P, C), muC + mu, at - v.coord, rE, vE):
				vE = _rel_vel(P, C)
			d_inf = DQuat.nrm(_local(v, vE)).scale_in(signf(h.dv1))
			_t_arr = at + h.tof
			if not pc.is_empty():
				# The porkchop's arc is never within 2° of 180°, so its v∞ has a direction.
				v_inf = pc.v_inf_dep
				d_inf = DQuat.nrm(_local(v, (pc.v_dep as DVec3).clone()))
				_t_arr = at + float(pc.tof)
		var tb := _align_time(v, mu, at, d_inf, v_inf)
		_schedule(tb, "Departure burn", func() -> DVec3:
			var rb := DVec3.new(); var vb := DVec3.new()
			Orbit.propagate(v.r, v.v, mu, float(_burn.at) - v.coord, rb, vb)
			var want := sqrt(v_inf * v_inf + 2.0 * mu / rb.length())
			return DQuat.nrm(vb.clone()).scale_in(want - vb.length()))
		# Thousands of revolutions on from now the parking orbit's phase is anyone's
		# guess (the Moon and the Sun pull on it), so the point is found again from
		# the orbit as it is, once the window is near.
		_burn["retime"] = func() -> float:
			return _align_time(v, mu, v.coord + HANDOVER_S + 60.0, d_inf, v_inf)
		_stage = "burn"
	status = _burn_status("Departure for %s" % dest.name)
	if _stage == "burn" and _burn_done(ap):
		_next()

## The time, at or after `t0`, at which a prograde burn up to `v_inf` leaves on an
## escape asymptote closest to `d_inf`. Each candidate's hyperbola is solved for its
## outgoing asymptote, cos ν∞·P̂ + sin ν∞·Q̂ with ν∞ = acos(−1/e), so no sign of a
## turning angle can be got wrong.
func _align_time(v: Vessel, mu: float, t0: float, d_inf: DVec3, v_inf: float) -> float:
	var el := Orbit.elements(v.r, v.v, mu)
	var T: float = el.period if is_finite(float(el.period)) else 5400.0
	var best := t0
	var best_dot := -2.0
	var rb := DVec3.new(); var vb := DVec3.new()
	for i in 240:
		var t := t0 + T * float(i) / 240.0
		if not Orbit.propagate(v.r, v.v, mu, t - v.coord, rb, vb): continue
		var R := rb.length()
		var vh := DQuat.nrm(vb.clone()).scale_in(sqrt(v_inf * v_inf + 2.0 * mu / R))
		var asym = _asymptote(rb, vh, mu)
		if asym == null: continue
		var dd: float = (asym as DVec3).dot(d_inf)
		if dd > best_dot: best_dot = dd; best = t
	return best

## The outgoing asymptote's direction of the hyperbola through (r, v), or null.
static func _asymptote(r: DVec3, v: DVec3, mu: float):
	var h := DVec3.new().cross_vectors(r, v)
	var hl := h.length()
	if hl <= 0.0: return null
	var e_vec := DVec3.new().cross_vectors(v, h).scale_in(1.0 / mu).sub_in(r.clone().scale_in(1.0 / r.length()))
	var e := e_vec.length()
	if e <= 1.0: return null
	var P := e_vec.scale_in(1.0 / e)
	var Q := DVec3.new().cross_vectors(h.scale_in(1.0 / hl), P)
	var nu := acos(-1.0 / e)
	return P.scaled(cos(nu)).add_in(Q.scaled(sin(nu)))

## Course corrections in the frame of the primary the transfer crosses: a Lambert arc
## from here to where the destination will be at the planned arrival.
func _leg_midcourse(v: Vessel, ap) -> void:
	var C: Body = plan.get("primary", v.parent) if plan.case != "moon" else _home_of_moon()
	if v.parent == dest:
		_next(); return
	if v.parent != C:
		status = "Coasting out of %s's sphere of influence" % v.parent.name
		return
	if _stage == "" or (_stage == "fixed" and _fixes < 2):
		var remaining := _t_arr - v.coord
		if remaining < 3600.0:
			_next(); return
		# The first fix takes out the plane change, cheapest where the coast is slow;
		# the second trims what the first left.
		var at := v.coord + remaining * (0.4 if _fixes == 0 else 0.6)
		var muC := _mu(C)
		_schedule(at, "Course correction %d" % (_fixes + 1), func() -> DVec3:
			var rb := DVec3.new(); var vb := DVec3.new()
			Orbit.propagate(v.r, v.v, muC, at - v.coord, rb, vb)
			# The arrival time is free within reason: the cheapest arc wins.
			var rem := _t_arr - at
			var best := _best_arc(rb, vb, at, C, at + rem * 0.7, at + rem * 1.35, 24,
				func(now_dv: float, arr: float) -> float: return now_dv + 0.08 * arr)
			if best.is_empty(): return DVec3.new()
			_t_arr = best.t_arr
			return best.dv)
		_stage = "burn"
	status = _burn_status("Cruise to %s" % dest.name)
	if _stage == "burn" and _burn_done(ap):
		_fixes += 1
		_stage = "fixed"
	if _stage == "fixed":
		status = "Cruise to %s — arrival in %s" % [dest.name, Guidance.fmt_dur(maxf(_t_arr - v.coord, 0.0))]
		if _fixes >= 2: _stage = "coast"
	if _stage == "coast":
		status = "Cruise to %s — arrival in %s" % [dest.name, Guidance.fmt_dur(maxf(_t_arr - v.coord, 0.0))]


## The cheapest Lambert arc from (r1, v1) at `t_dep` to the destination, over
## arrival times in [t_lo, t_hi]. `cost` prices (Δv now, v∞ at arrival); a burn
## made deep in a gravity well is far cheaper than its v∞ (Oberth), so the caller
## says what each end really costs. A transfer within ~2° of 180° has no defined
## plane and is skipped. Returns {dv, t_arr} or {}.
func _best_arc(r1: DVec3, v1: DVec3, t_dep: float, C: Body, t_lo: float, t_hi: float, n: int, cost_of: Callable) -> Dictionary:
	var muC := _mu(C)
	var now: float = flight.vessel.coord
	var nrm := DVec3.new().cross_vectors(r1, v1)
	var best := {}
	var best_cost := INF
	var rd := DVec3.new(); var vd := DVec3.new()
	var a1 := DVec3.new(); var a2 := DVec3.new()
	for i in n:
		var t_arr := lerpf(t_lo, t_hi, float(i) / float(n - 1))
		if not Orbit.propagate(_rel_pos(dest, C), _rel_vel(dest, C), muC + _mu(dest), t_arr - now, rd, vd): continue
		# C is the vessel's parent here (_leg_midcourse), so its frame is r1's.
		_local(flight.vessel, rd); _local(flight.vessel, vd)
		var c := r1.dot(rd) / (r1.length() * rd.length())
		if c < -0.9994: continue
		if not Orbit.lambert(r1, rd, t_arr - t_dep, muC, nrm, a1, a2): continue
		var cost: float = cost_of.call(a1.clone().sub_in(v1).length(), a2.clone().sub_in(vd).length())
		if cost < best_cost:
			best_cost = cost
			best = {"dv": a1.clone().sub_in(v1), "t_arr": t_arr}
	return best

func _home_of_moon() -> Body:
	var anc := ancestors(flight.vessel, dest)
	return anc[0] if not anc.is_empty() else flight.vessel.parent

## Before the arrival is trimmed, so the parent's tide (8e-4 m/s² at the edge of the
## Moon's sphere, hundreds of km of periapsis over the coast in) has little time left.
const TRIM_BEFORE_S := 3.0 * 3600.0

## Inside the destination's sphere: a burn that sets the periapsis to the parking
## radius, keeping the speed (so the energy) and turning the velocity in its own plane;
## the conic leaves out the parent's tide, so it is trimmed again near the end.
func _leg_approach(v: Vessel, ap) -> void:
	if v.parent != dest:
		status = "Cruise to %s — arrival in %s" % [dest.name, Guidance.fmt_dur(maxf(_t_arr - v.coord, 0.0))]
		return
	var mu := _mu(dest)
	var rp_t: float = plan.r_cap
	var el := Orbit.elements(v.r, v.v, mu)
	var R_b := float(v.env.radius)
	var tol := 0.25 * (rp_t - R_b)
	if leg + 1 < legs().size() and str(legs()[leg + 1].key) == "aerocapture":
		# The corridor is a few km wide: aim the pass the predictor says leaves the
		# vessel at the parking radius, re-solved at each trim.
		if _aero_rp <= 0.0 or _stage == "": _aero_rp = aero_periapsis(v, v.r, v.v, mu, v.env, float(plan.r_cap))
		if _aero_rp > 0.0:
			rp_t = _aero_rp
			tol = 1000.0
	var aimed: bool = absf(float(el.rp) - rp_t) < tol and v.r.dot(v.v) < 0.0
	if _stage == "coast":
		var t_p := Orbit.time_to_periapsis_any(el, mu)
		status = "Approach to %s — periapsis %s km in %s" % [dest.name, U.fixed((float(el.rp) - R_b) / 1000.0, 0), Guidance.fmt_dur(t_p)]
		if is_finite(t_p) and t_p > TRIM_BEFORE_S: return
		if aimed:
			_next(); return
		_stage = ""
	if _stage == "":
		if aimed:
			_next(); return
		var at := v.coord + (180.0 if _fixes == 0 else 60.0)
		_schedule(at, "Arrival targeting" if _fixes == 0 else "Arrival trim", func() -> DVec3:
			var rb := DVec3.new(); var vb := DVec3.new()
			Orbit.propagate(v.r, v.v, mu, float(_burn.at) - v.coord, rb, vb)
			var R := rb.length()
			var V := vb.length()
			var vp := sqrt(maxf(V * V - 2.0 * mu / R + 2.0 * mu / rp_t, 0.0))
			var vt := minf(rp_t * vp / R, V * 0.999)
			var rhat := DQuat.nrm(rb.clone())
			var t := vb.clone().add_scaled_in(rhat, -vb.dot(rhat))
			if t.length() < 1e-6:
				t = DVec3.new().cross_vectors(Orbit.K, rhat)
			DQuat.nrm(t)
			var want := rhat.scaled(-sqrt(maxf(V * V - vt * vt, 0.0))).add_in(t.scaled(vt))
			return want.sub_in(vb))
		_stage = "burn"
	status = _burn_status("Approach to %s" % dest.name)
	if _stage == "burn" and _burn_done(ap):
		_fixes += 1
		if _fixes < 2: _stage = "coast"
		else: _next()

## Can `v` aerocapture at `b`: air to fly through and a heat shield to fly on, and not a
## winged body (its lift is not in the predictor).
static func aero_capable(v: Vessel, b: Body) -> bool:
	var env := Rocketry.flight_env(b)
	if env.atm == null or float(v.vehicle.limits.get("heatLoad", 0.0)) <= 0.0: return false
	for st in v.stages:
		if st.attached and st.spec.get("wings") != null: return false
	return true

## Mass over C_D·A, kg/m², heat shield first (Vessel's blunt-body drag at hypersonic speed).
static func ballistic(v: Vessel) -> float:
	return v.mass / (Rocketry.blunt_drag_coefficient(25.0) * maxf(v.area, 1.0))

## The conic periapsis radius (m) to aim for so that the pass through the air leaves the
## vessel climbing to apoapsis `ra_want`. Each trial turns the velocity at (r, vv) in its
## own plane, as the arrival trim does, and flies Orbit.aero_pass from there, so the
## parent's J2 on the way in counts. Bisection: a deeper pass leaves less energy. 0 if
## no pass in the air captures.
static func aero_periapsis(v: Vessel, r: DVec3, vv: DVec3, mu: float, env: Dictionary, ra_want: float) -> float:
	var atm = env.atm
	var R := float(env.radius)
	var top := float(atm.get("exo", atm.top))
	var bc := ballistic(v)
	var apo_of := func(rp: float) -> float:
		var u := aimed_velocity(r, vv, mu, rp)
		var res := Orbit.aero_pass(r, u, mu, R, atm, float(env.rotRate), bc, v.diameter * 0.5, env.get("zonal"), 86400.0 * 4.0, env.get("figure"))
		if res.crashed: return -1.0
		var el := Orbit.elements(res.r, res.v, mu)
		return float(el.ra) if float(el.e) < 1.0 else INF
	var lo := R
	var hi := R + top * 1.2
	if apo_of.call(hi) <= ra_want: return 0.0
	for i in 40:
		var mid := 0.5 * (lo + hi)
		if apo_of.call(mid) > ra_want: hi = mid
		else: lo = mid
		if hi - lo < 20.0: break
	return 0.5 * (lo + hi)

## The velocity at r with the same speed, turned in its plane so the conic's periapsis
## radius is `rp` (the arrival trim's aim).
static func aimed_velocity(r: DVec3, vv: DVec3, mu: float, rp: float) -> DVec3:
	var Rr := r.length()
	var V := vv.length()
	var vp := sqrt(maxf(V * V - 2.0 * mu / Rr + 2.0 * mu / rp, 0.0))
	var vt := minf(rp * vp / Rr, V * 0.999)
	var rhat := DQuat.nrm(r.clone())
	var t := vv.clone().add_scaled_in(rhat, -vv.dot(rhat))
	if t.length() < 1e-6: t = DVec3.new().cross_vectors(Orbit.K, rhat)
	DQuat.nrm(t)
	return rhat.scaled(-sqrt(maxf(V * V - vt * vt, 0.0))).add_in(t.scaled(vt))

## Aerobraking: the apoapsis an ellipse is captured to, in parking radii.
const AEROBRAKE_RA := 12.0
## Peak dynamic pressure aimed for at each periapsis, Pa: MRO's passes ran at ~0.3–0.5.
const AEROBRAKE_Q := 0.4
## Done once the apoapsis is within this factor of the parking radius.
const AEROBRAKE_DONE := 1.15

## The periapsis radius (m) at which a pass of orbit (rp, ra) peaks at AEROBRAKE_Q.
static func aerobrake_periapsis(env: Dictionary, ra: float, q := AEROBRAKE_Q) -> float:
	var mu := float(env.mu)
	var R := float(env.radius)
	var lo := R; var hi := R + float(env.atm.get("exo", env.atm.top)) * 1.5
	for i in 50:
		var rp := 0.5 * (lo + hi)
		var vp2 := mu * 2.0 * ra / (rp * (rp + ra))
		if 0.5 * Rocketry.density(env.atm, rp - R) * vp2 > q: lo = rp
		else: hi = rp
	return 0.5 * (lo + hi)

## Seconds of aerobraking from apoapsis ra0 down to ra1. Each pass takes
## Δv = ρ_p·v_p·√(2π·r_p·H)/β at periapsis (an exponential atmosphere's drag integral),
## so it is closed form per pass; capped at 5000 passes.
static func aerobrake_estimate(v: Vessel, b: Body, ra1: float, ra0: float) -> float:
	var env := Rocketry.flight_env(b)
	var mu := float(env.mu)
	var R := float(env.radius)
	var bc := ballistic(v)
	var ra := ra0
	var t := 0.0
	for i in 5000:
		if ra <= ra1 * AEROBRAKE_DONE: break
		var rp := aerobrake_periapsis(env, ra)
		var a := 0.5 * (rp + ra)
		t += TAU * sqrt(a * a * a / mu)
		var vp := sqrt(mu * 2.0 * ra / (rp * (rp + ra)))
		var H := Rocketry.scale_height(env.atm, rp - R)
		var dv := Rocketry.density(env.atm, rp - R) * vp * sqrt(TAU * rp * H) / bc
		var e := 0.5 * pow(vp - dv, 2.0) - mu / rp
		if e >= 0.0 or dv <= 0.0: break
		ra = 2.0 * (-mu / (2.0 * e)) - rp
	return t

## Lower the periapsis into the upper air, let each pass take the apoapsis down, and
## walk the periapsis to hold the peak pressure as the orbit shrinks; then raise it.
var _ab_passes := 0
var _ab_was_out := true
func _leg_aerobrake(v: Vessel, ap) -> void:
	var mu := _mu(dest)
	var R := float(v.env.radius)
	var top: float = float(v.env.atm.get("exo", v.env.atm.top))
	var el := Orbit.elements(v.r, v.v, mu)
	var ra := float(el.ra)
	if _stage == "" or _stage == "walk":
		if _stage == "" and ra <= float(plan.r_cap) * AEROBRAKE_DONE:
			_stage = "done"
		else:
			var rp_t := aerobrake_periapsis(v.env, ra)
			if absf(float(el.rp) - rp_t) > 1500.0 or _stage == "":
				var label := "Walk-in to %s km" % U.fixed((rp_t - R) / 1000.0, 1) if _stage == "" else "Periapsis walk to %s km" % U.fixed((rp_t - R) / 1000.0, 1)
				_schedule(v.coord + Orbit.time_to_apoapsis(el, mu), label, func() -> DVec3:
					var rb := DVec3.new(); var vb := DVec3.new()
					Orbit.propagate(v.r, v.v, mu, maxf(float(_burn.at) - v.coord, 0.0), rb, vb)
					var rr := rb.length()
					var rhat := DQuat.nrm(rb.clone())
					var t := vb.clone().add_scaled_in(rhat, -vb.dot(rhat))
					DQuat.nrm(t)
					return t.scale_in(sqrt(mu * 2.0 * rp_t / (rr * (rr + rp_t)))).sub_in(vb))
				_stage = "burn"
			else:
				_stage = "passes"
	if _stage == "burn":
		status = _burn_status("Aerobraking at %s" % dest.name)
		if _burn_done(ap): _stage = "passes"
		return
	if _stage == "passes":
		var inside := v.altitude() < top
		if inside and _ab_was_out:
			_ab_passes += 1
		if not inside and not _ab_was_out:
			v.log_event("Aerobraking pass %d — apoapsis %s km" % [_ab_passes, U.fixed((ra - R) / 1000.0, 0)])
		_ab_was_out = not inside
		status = "Aerobraking at %s — pass %d, apoapsis %s km" % [dest.name, _ab_passes, U.fixed((ra - R) / 1000.0, 0)]
		# Re-plan once per orbit, past apoapsis, out of the air.
		if not inside and v.r.dot(v.v) < 0.0 and v.r.length() > 0.5 * (float(el.rp) + ra):
			if ra <= float(plan.r_cap) * AEROBRAKE_DONE: _stage = "done"
			elif absf(float(el.rp) - aerobrake_periapsis(v.env, ra)) > 1500.0: _stage = "walk"
		if _stage != "done": return
	if _stage == "done":
		_schedule(v.coord + Orbit.time_to_apoapsis(el, mu), "Periapsis raise", circ_now(v, mu))
		_burn["track"] = circ_now(v, mu)
		_stage = "raise"
	status = _burn_status("Aerobraking at %s — raising the periapsis" % dest.name)
	if _stage == "raise" and _burn_done(ap):
		if float(Orbit.elements(v.r, v.v, mu).rp) - R < top:
			abort("Periapsis raise did not clear the air")
			return
		v.phase = Vessel.PHASE.ORBIT
		_next()

## Through the air heat shield first, then at apoapsis a burn to circular there, which
## lifts the periapsis out of the air.
func _leg_aerocapture(v: Vessel, ap) -> void:
	if v.parent != dest:
		status = "Cruise to %s — arrival in %s" % [dest.name, Guidance.fmt_dur(maxf(_t_arr - v.coord, 0.0))]
		return
	var mu := _mu(dest)
	var top: float = float(v.env.atm.get("exo", v.env.atm.top))
	var alt := v.altitude()
	if _stage == "":
		if ap.program != null: ap.disengage()
		ap.mode = Guidance.MODE.RETROGRADE
		_stage = "pass"
		v.log_event("Aerocapture — heat shield first, periapsis %s km" % U.fixed((float(Orbit.elements(v.r, v.v, mu).rp) - float(v.env.radius)) / 1000.0, 1))
	if _stage == "pass":
		if alt < top: _aero_in = true
		status = "Aerocapture — %s km, %s" % [U.fixed(alt / 1000.0, 0), FlightUI.fmt_speed(v.v.length())]
		if not (_aero_in and alt > top and v.r.dot(v.v) > 0.0): return
		var el := Orbit.elements(v.r, v.v, mu)
		if float(el.e) >= 1.0:
			abort("Aerocapture skipped out — still on a hyperbola")
			return
		if float(el.ra) - float(v.env.radius) < top:
			abort("Aerocapture too deep — the orbit falls back into the air")
			return
		v.log_event("Aerocapture — out of the air on a %s × %s km orbit" % [U.fixed((float(el.ra) - float(v.env.radius)) / 1000.0, 0), U.fixed((float(el.rp) - float(v.env.radius)) / 1000.0, 0)])
		ap.mode = Guidance.MODE.PROGRADE
		var at := v.coord + Orbit.time_to_apoapsis(el, mu)
		_schedule(at, "Periapsis raise", func() -> DVec3:
			var rb := DVec3.new(); var vb := DVec3.new()
			Orbit.propagate(v.r, v.v, mu, maxf(float(_burn.at) - v.coord, 0.0), rb, vb)
			var rhat := DQuat.nrm(rb.clone())
			var t := vb.clone().add_scaled_in(rhat, -vb.dot(rhat))
			DQuat.nrm(t)
			return t.scale_in(sqrt(mu / rb.length())).sub_in(vb))
		_burn["track"] = circ_now(v, mu)
		_stage = "burn"
	status = _burn_status("Aerocapture at %s" % dest.name)
	if _stage == "burn" and _burn_done(ap):
		var el := Orbit.elements(v.r, v.v, mu)
		if float(el.rp) - float(v.env.radius) < top:
			_fixes += 1
			if _fixes > 2:
				abort("Periapsis raise did not clear the air")
				return
			_schedule(v.coord + 60.0, "Orbit trim", circ_now(v, mu))
			_burn["track"] = circ_now(v, mu)
			return
		v.phase = Vessel.PHASE.ORBIT
		_next()

## Capture at periapsis: retrograde down to circular.
func _leg_capture(v: Vessel, ap) -> void:
	if v.parent != dest:
		status = "Cruise to %s — arrival in %s" % [dest.name, Guidance.fmt_dur(maxf(_t_arr - v.coord, 0.0))]
		return
	var mu := _mu(dest)
	if _stage == "":
		var el := Orbit.elements(v.r, v.v, mu)
		var t_p := Orbit.time_to_periapsis_any(el, mu)
		if not is_finite(t_p):
			# Past periapsis already (a short hop): circularize where we are.
			t_p = 120.0
		var at := v.coord + maxf(t_p, 120.0)
		# Closed loop: the burn chases circular speed at wherever the vehicle is, so a
		# long burn ends circular rather than wherever a frozen vector would leave it.
		var circ := func() -> DVec3:
			var rhat := DQuat.nrm(v.r.clone())
			var t := v.v.clone().add_scaled_in(rhat, -v.v.dot(rhat))
			DQuat.nrm(t)
			return t.scale_in(sqrt(mu / v.r.length())).sub_in(v.v)
		var ra_c := float(plan.get("ra_cap", 0.0))
		_schedule(at, "Orbit insertion", func() -> DVec3:
			var rb := DVec3.new(); var vb := DVec3.new()
			Orbit.propagate(v.r, v.v, mu, maxf(float(_burn.at) - v.coord, 0.0), rb, vb)
			var rhat := DQuat.nrm(rb.clone())
			var t := vb.clone().add_scaled_in(rhat, -vb.dot(rhat))
			DQuat.nrm(t)
			var rr := rb.length()
			var want := sqrt(mu / rr) if ra_c <= rr else sqrt(mu * 2.0 * ra_c / (rr * (rr + ra_c)))
			return t.scale_in(want).sub_in(vb))
		_burn["retime"] = func() -> float:
			return v.coord + Orbit.time_to_periapsis_any(Orbit.elements(v.r, v.v, mu), mu)
		if ra_c <= 0.0: _burn["track"] = circ
		_stage = "burn"
	status = _burn_status("Orbit insertion at %s" % dest.name)
	if _stage == "burn" and _burn_done(ap):
		v.phase = Vessel.PHASE.ORBIT
		var el := Orbit.elements(v.r, v.v, mu)
		var floor_r := float(v.env.radius) + (float(v.env.atm.top) if v.env.atm != null else 20e3)
		if float(el.rp) < floor_r or (float(el.e) > 0.2 and float(plan.get("ra_cap", 0.0)) <= 0.0):
			# A capture that left the orbit low or loose: circularize again where we are.
			_fixes += 1
			if _fixes > 2:
				abort("Capture did not settle into orbit (periapsis %s km)" % U.fixed((float(el.rp) - float(v.env.radius)) / 1000.0, 0))
				return
			_schedule(v.coord + 60.0, "Orbit trim", circ_now(v, mu))
			_burn["track"] = circ_now(v, mu)
			return
		_next()

## Circular speed at the current position, in the current plane, less the velocity.
static func circ_now(v: Vessel, mu: float) -> Callable:
	return func() -> DVec3:
		var rhat := DQuat.nrm(v.r.clone())
		var t := v.v.clone().add_scaled_in(rhat, -v.v.dot(rhat))
		DQuat.nrm(t)
		return t.scale_in(sqrt(mu / v.r.length())).sub_in(v.v)

## Lower the periapsis to the landing program's starting altitude.
func _leg_descend(v: Vessel, ap) -> void:
	var mu := _mu(dest)
	var R_b := float(v.env.radius)
	if _stage == "":
		var at := v.coord + 180.0
		_schedule(at, "Descent orbit insertion", func() -> DVec3:
			var rb := DVec3.new(); var vb := DVec3.new()
			Orbit.propagate(v.r, v.v, mu, float(_burn.at) - v.coord, rb, vb)
			var R := rb.length()
			var a_new := (R + R_b + LANDING_ALT) * 0.5
			var want := sqrt(mu * (2.0 / R - 1.0 / a_new))
			return DQuat.nrm(vb.clone()).scale_in(want - vb.length()))
		_stage = "burn"
	status = _burn_status("Descent orbit")
	if _stage == "burn" and _burn_done(ap):
		_stage = "coast"
	if _stage == "coast":
		var el := Orbit.elements(v.r, v.v, mu)
		var t_p := Orbit.time_to_periapsis(el, mu)
		status = "Coasting to powered descent — %s" % Guidance.fmt_dur(t_p)
		if t_p < 90.0 or v.altitude() < LANDING_ALT * 1.3: _next()

func _leg_land(v: Vessel, ap) -> void:
	if _stage == "":
		_stage = "flying"
		ap.engage("land")
	status = "Landing — %s" % ap.status
	if v.phase == Vessel.PHASE.LANDED: _next()
	elif ap.program == null and v.phase != Vessel.PHASE.LANDED: abort("Landing program ended without touchdown")

# BURNS

func _schedule(at: float, label: String, make: Callable) -> void:
	_burn = {"at": at, "make": make, "label": label}
	_burn_engaged = false
	flight.vessel.log_event("%s planned in %s" % [label, Guidance.fmt_dur(maxf(at - flight.vessel.coord, 0.0))])

## Hand the next burn to the autopilot a few minutes before ignition.
func _fly_burn(v: Vessel, ap) -> void:
	if _burn == null: return
	if _burn_engaged:
		# Guidance counts its node down in its own steps; the schedule is in
		# coordinate time, which runs ahead under warp.
		if ap.program == "node" and not ap.burning and ap.node != null:
			ap.node_t = float(_burn.at) - v.coord
		# A tracked burn re-aims and re-sizes itself every step.
		if ap.program == "node" and ap.burning and _burn.has("track"):
			var dv: DVec3 = _burn.track.call()
			if not _burn.has("dir0"): _burn["dir0"] = DQuat.nrm(dv.clone())
			# Past the target (the remainder points back) or within a step of it: done.
			if dv.dot(_burn.dir0) <= 0.0 or dv.length() < 0.5:
				ap.burn_remaining = 0.0
			else:
				ap.node_vec.copy_from(dv)
				ap.burn_remaining = dv.length()
		return
	# A burn timed from a conic hours ago drifts with the other bodies' pull: re-time it.
	if _burn.has("retime") and not _burn.has("retimed") and float(_burn.at) - v.coord < HANDOVER_S * 4.0:
		_burn["retimed"] = true
		var t: float = _burn.retime.call()
		if is_finite(t): _burn.at = t
	var t_go: float = _burn.at - v.coord
	if t_go > HANDOVER_S: return
	var dv: DVec3 = _burn.make.call()
	_burn_engaged = true
	if dv.length() < 0.3:
		v.log_event("%s — not needed" % _burn.label)
		_burn["skipped"] = true
		return
	ap.plan = null; ap.burning = false
	ap.node = {"dv": dv, "t": maxf(t_go, 30.0), "label": _burn.label}
	ap.engage("node")

func _burn_done(ap) -> bool:
	if _burn == null: return true
	if not _burn_engaged: return false
	return _burn.get("skipped", false) or ap.program == null

func _burn_status(what: String) -> String:
	if _burn == null: return what
	var ap = flight.autopilot
	var t_go: float = _burn.at - flight.vessel.coord
	if _burn_engaged and ap.program == "node": return "%s — %s" % [what, ap.status]
	return "%s — %s in %s" % [what, _burn.label.to_lower(), Guidance.fmt_dur(maxf(t_go, 0.0))]

## Seconds to the next thing that needs normal speed, or INF.
func next_event_s() -> float:
	var v: Vessel = flight.vessel
	var t := INF
	if _burn != null and not _burn_engaged: t = minf(t, float(_burn.at) - v.coord - HANDOVER_S)
	if leg_key() in ["midcourse", "approach", "capture", "aerocapture", "aerobrake"] and v.parent != dest:
		# Slow before the destination's sphere so the crossing is not stepped over.
		var soi := v.soi_of(dest)
		var d := v.body_offset(dest, DVec3.new()).sub_in(v.r).length()
		var closing := maxf(_local(v, _rel_vel(dest, v.parent)).sub_in(v.v).length(), 100.0)
		t = minf(t, maxf(d - soi, 0.0) / closing)
	if leg_key() == "approach" and _stage == "coast":
		t = minf(t, Orbit.time_to_periapsis_any(Orbit.elements(v.r, v.v, _mu(dest)), _mu(dest)) - TRIM_BEFORE_S)
	if leg_key() == "descend" and _stage == "coast":
		var el := Orbit.elements(v.r, v.v, _mu(dest))
		t = minf(t, Orbit.time_to_periapsis(el, _mu(dest)) - 90.0)
	return t

## Time warp: real time near events and under thrust, rails between them.
func _pace(v: Vessel, ap) -> void:
	var want := 0
	if flight.count != null or ap.program == "land":
		want = 0
	elif ap.program == "ascent":
		want = 0 if v.met - v.t0 < 25.0 else 1
	elif ap.program == "circularize":
		want = 3 if v.throttle == 0.0 and Orbit.time_to_apoapsis(v.telemetry.el, v.env.mu) > 150.0 else 0
	elif ap.program == "node":
		var t_ign: float = ap.node_t - 0.5 * Rocketry.burn_time_for(ap.burn_remaining, v.mass, ap.full_thrust(0.0), ap.current_isp(0.0))
		want = 0 if (ap.burning or t_ign < 100.0) else (3 if t_ign > 400.0 else 1)
	else:
		var t := next_event_s()
		if is_finite(t) and t > 0.0 and v.can_rail():
			for i in Spaceflight.WARPS.size():
				if Spaceflight.WARPS[i] * LOOKAHEAD_S <= t: want = i
		elif not is_finite(t) and v.can_rail():
			want = 6
	if want != flight.warp_index(): flight.set_warp(want)

# SKIPPING

## Jump to the destination instead of flying there: the propellant and the time are
## charged as planned, and the vehicle is put in the parking orbit on arrival. The
## trajectory itself is not flown.
func skip() -> void:
	flight.begin_skip(self)
