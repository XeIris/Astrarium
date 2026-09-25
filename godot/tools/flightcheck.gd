extends SceneTree

# ============================================================================
# FLIGHT CHECK — the GDScript port of the spaceflight model, flown headlessly
# through exactly the scenarios tools/flightref.mjs flies in Node, so the two
# result files can be diffed number by number.
#
#   Godot --headless --path godot --script res://tools/flightcheck.gd -- out=/abs/gd.json
#   node godot/tools/flightref.mjs --compare js.json gd.json
#
# Options (after `--`):  out=<path>   only=<id,id>   bench=1   (RK4 timing)
#
# Everything the scenarios need comes from tools/fixtures/flight_fixture.json,
# written by flightref.mjs: the solar-system bodies (frozen) and each scenario's
# parameters, with every double carried as its exact IEEE-754 bits so the two
# runners start from the same state to the last place.
#
# The driver below is spaceflight.js's — begin(), the terminal count, setWarp's
# interlock, update()'s sub-stepping and the cruise block — transcribed line for
# line from the same lines flightref.mjs transcribes. It is NOT the Godot port of
# spaceflight.js (that is a separate module with rendering in it); it is the
# minimum that drives a Vessel the way the page does.
# ============================================================================

const WARPS := [1, 2, 5, 10, 50, 100, 1000, 10000, 100000, 1000000]
const EARTH_PADS := {
	"starship": { "lat": 25.99684, "lon": -97.15523 },
	"default": { "lat": 28.608402, "lon": -80.604201 },
}
const IGNITION_LEAD := { "saturnv": 8.9, "shuttle": 6.6, "falcon9": 3.0, "starship": 3.0 }

var args := {}

static func unhex(h: String) -> float:
	return h.hex_decode().decode_double(0)

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var fx_text := FileAccess.get_file_as_string("res://tools/fixtures/flight_fixture.json")
	var fixture: Dictionary = JSON.parse_string(fx_text)
	var dt := unhex(fixture.dt)
	if args.has("bench"):
		bench(fixture)
		quit()
		return
	var only: Array = args.only.split(",") if args.has("only") else []
	var results := { "runner": "gd", "spot": spot(fixture.bodies), "scenarios": {} }
	for sc in fixture.scenarios:
		if not only.is_empty() and not only.has(sc.id): continue
		var res := run(sc, fixture.bodies, dt)
		results.scenarios[sc.id] = res
		var s: Dictionary = res.summary
		print("%-16s %-9s met %.1f s frames %d maxQ %.2f kPa @ %.1f s  %s %s (%d ms)" % [
			sc.id, s.phase, s.met, s.frames, s.maxQ / 1000.0, s.maxQMet,
			("touchdown %.2f / %.2f m/s" % [s.landedAt.vVert, s.landedAt.vHoriz]) if s.landedAt != null else "",
			s.failure if s.failure != null else "", s.wallMs])
	var out: String = args.get("out", "user://flight_gd.json")
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(sanitize(results), "", false, true))
	f.close()
	print("wrote ", out)
	quit()

## JSON.stringify(Infinity) is null in JS; Godot would print `inf`. Mirror JS.
static func sanitize(x):
	if x is float:
		return x if is_finite(x) else null
	if x is Array:
		var a := []
		for e in x: a.append(sanitize(e))
		return a
	if x is Dictionary:
		var d := {}
		for k in x: d[k] = sanitize(x[k])
		return d
	if x is DVec3:
		return [x.x, x.y, x.z]
	return x

static func num(x):
	return x if (x is float or x is int) and is_finite(float(x)) else null

# ---- bodies -------------------------------------------------------------------
func body_objects(fix: Array) -> Array:
	var out := []
	var i := 0
	for b in fix:
		var o := Body.new()
		o.id = i; i += 1
		o.name = b.name; o.type = b.type
		o.mass = unhex(b.h.mass); o.radius = unhex(b.h.radius)
		o.day_length = float(b.dayLength)
		o.alive = true
		o.pos = DVec3.new(unhex(b.h.pos[0]), unhex(b.h.pos[1]), unhex(b.h.pos[2]))
		o.vel = DVec3.new(unhex(b.h.vel[0]), unhex(b.h.vel[1]), unhex(b.h.vel[2]))
		out.append(o)
	return out

func find_body(bodies: Array, n: String):
	for b in bodies:
		if b.name == n: return b
	return null

func morning_longitude(bodies: Array, body: Body) -> float:
	var src = null
	for b in bodies:
		if b.type == "star" or b.type == "white-dwarf":
			if b.mass > (src.mass if src != null else -1.0): src = b
	if src == null or src == body: return 0.0
	var a := DQuat.nrm(DVec3.new().sub_vectors(src.pos, body.pos))
	var sub := atan2(a.z, a.x) * 180.0 / PI
	return sub - 22.0

func vehicle_for(sc: Dictionary) -> Dictionary:
	var veh: Dictionary = Vehicles.VEHICLES[sc.vehicle]
	if sc.get("stages") == null: return veh
	var out := veh.duplicate(false)
	out.id = sc.id
	var st := []
	for i in sc.stages:
		var s: Dictionary = veh.stages[int(i)]
		if sc.get("prop") != null and int(i) == int(sc.stages[0]):
			s = s.duplicate(false)
			s.prop = float(sc.prop)
		st.append(s)
	out.stages = st
	return out

# ---- the driver state ---------------------------------------------------------
class S extends RefCounted:
	var sc: Dictionary
	var veh: Dictionary
	var vessel: Vessel
	var bodies: Array
	var ap: Guidance.Autopilot
	var count = null
	var warp_idx := 0
	var cruise = null
	var boost := DVec3.new()
	var best := { "q": 0.0, "met": 0.0, "alt": 0.0 }
	var piloted := false

func make_state(sc: Dictionary, fix_bodies: Array) -> S:
	var st := S.new()
	st.sc = sc
	st.bodies = body_objects(fix_bodies)
	var home: Body = find_body(st.bodies, sc.body)
	var veh := vehicle_for(sc)
	st.veh = veh
	var vessel := Vessel.new({ "vehicle": veh, "parent": home, "bodies": st.bodies,
		"payload": veh.carries.mass if veh.get("carries") != null else 0.0 })
	st.vessel = vessel
	if sc.place == "pad":
		var earth_pad = (EARTH_PADS.get(sc.vehicle, EARTH_PADS.default)) if home.name == "Earth" else null
		var lat: float = earth_pad.lat if earth_pad != null else (veh.target.get("inclination", 28.5) if veh.get("target") != null else 28.5)
		vessel.place_on_pad(lat, morning_longitude(st.bodies, home))
	else:
		vessel.place_in_orbit(float(sc.alt), float(sc.get("inc", 0.0)), float(sc.get("phase", 0.0)))
	if sc.get("init") != null and sc.init.get("r") != null:
		var i: Dictionary = sc.init
		vessel.r.set_v(unhex(i.r[0]), unhex(i.r[1]), unhex(i.r[2]))
		vessel.v.set_v(unhex(i.v[0]), unhex(i.v[1]), unhex(i.v[2]))
		vessel.q.set_q(unhex(i.q[0]), unhex(i.q[1]), unhex(i.q[2]), unhex(i.q[3]))
	vessel.vehicle_key = sc.vehicle
	st.ap = Guidance.Autopilot.new(vessel)
	st.ap.mode = Guidance.MODE.PROGRADE
	set_warp(st, 0)
	vessel.log_event("%s — %s, %s t, %s km/s ideal Δv" % [veh.name,
		"on the pad" if vessel.phase == Vessel.PHASE.PRELAUNCH else "in flight",
		U.fixed(Vehicles.gross_mass(veh) / 1000.0, 0), U.fixed(Vehicles.total_delta_v(veh) / 1000.0, 2)])
	if vessel.phase == Vessel.PHASE.PRELAUNCH:
		var twr: float = Vehicles.liftoff_thrust(veh, 101325.0) / (vessel.mass * vessel.env.gSurf)
		vessel.log_event(("HOLD — liftoff thrust-to-weight is %s. It will not leave the pad." % U.fixed(twr, 2)) if twr < 1.0
			else ("Liftoff TWR %s · %s MN" % [U.fixed(twr, 2), U.fixed(Vehicles.liftoff_thrust(veh, 101325.0) / 1e6, 1)]))
	# runProgram()
	if sc.get("program") == "cruise":
		begin_cruise(st)
		return st
	if sc.get("program") != null:
		var ap := st.ap
		ap.plan = null; ap.node = null; ap.site = null; ap.burning = false
		ap.slamming = false; ap.entry_done = false; ap.shield_gone = false; ap.crane_out = false
		if sc.program == "ascent" and vessel.phase == Vessel.PHASE.PRELAUNCH:
			start_count(st, float(sc.get("count", 10)))
		else:
			ap.engage(sc.program)
	return st

func set_warp(st: S, i: int) -> void:
	st.warp_idx = clampi(i, 0, WARPS.size() - 1)
	var vessel := st.vessel
	if vessel != null and st.cruise == null:
		var railable := vessel.can_rail()
		if not railable and WARPS[st.warp_idx] > 4:
			var capped := 0
			for k in WARPS.size():
				if WARPS[k] <= 4: capped = k
			st.warp_idx = capped

func start_count(st: S, T: float = 10.0) -> void:
	var lead: float = IGNITION_LEAD.get(st.vessel.vehicle_key, 4.0)
	st.count = { "t": T, "lead": lead, "lit": false, "called": {} }
	st.vessel.held_down = true
	set_warp(st, 0)
	st.vessel.log_event("T−%s — terminal count" % U.fixed(T, 0))

func step_count(st: S, dt_sim: float) -> void:
	var count = st.count
	var vessel := st.vessel
	if count == null: return
	count.t -= dt_sim
	for mark in [8, 5, 3, 2, 1]:
		if count.t <= mark and not count.called.has(mark):
			count.called[mark] = true
			vessel.log_event("T−%d" % mark)
	if not count.lit and count.t <= count.lead:
		count.lit = true; vessel.throttle = 1.0; vessel.log_event("Ignition sequence start")
	if count.t <= 0.0:
		st.count = null; vessel.held_down = false; vessel.log_event("Hold-down release"); st.ap.engage("ascent")

func begin_cruise(st: S) -> void:
	var vessel := st.vessel
	var stg = null
	for s in vessel.stages:
		if s.attached and s.spec.get("engine") != null and s.spec.engine.get("photon", false):
			stg = s; break
	var origin := vessel.parent.pos.clone().add_scaled_in(vessel.r, 1.0 / Rocketry.AU_M)
	var tpos := origin.clone().add_in(DVec3.new(11.9 * Relativity.LY_AU, 0.0, 0.0))
	var a: float = (stg.spec.engine.holdAccel / Rocketry.G0) * Rocketry.G0
	st.cruise = Relativity.Cruise.new({
		"origin": origin, "target": tpos, "accel": a,
		"dryMass": vessel.mass - stg.prop, "propMass": stg.prop, "exhaustMS": 299792458.0, "name": vessel.name,
	})
	vessel.phase = Vessel.PHASE.CRUISE
	var p: Dictionary = st.cruise.plan
	vessel.log_event("Interstellar cruise — %s ly at %s g" % [U.fixed(st.cruise.dist_ly, 2), U.fixed(a / Rocketry.G0, 2)])
	vessel.log_event(("Flip-and-burn: %s yr ship, %s yr coordinate" % [U.fixed(p.tauS / Rocketry.YR_S, 2), U.fixed(p.coordS / Rocketry.YR_S, 2)]) if p.mode == "flip"
		else ("Accelerate–coast–decelerate: burn %s ly, coast %s ly, β %s — %s yr ship, %s yr coordinate" % [
			U.fixed(p.burnLy, 2), U.fixed(p.coastLy, 2), U.fixed(p.betaMax, 4), U.fixed(p.tauS / Rocketry.YR_S, 2), U.fixed(p.coordS / Rocketry.YR_S, 2)]))
	set_warp(st, WARPS.size() - 1)

var _q := DQuat.new()
var _b := DVec3.new()
var _a := DVec3.new()
var _air := DVec3.new()

func pilot(st: S) -> void:
	var sc := st.sc
	var v := st.vessel
	if not sc.get("pilotStage", false) or st.piloted or st.ap.state_name != "chute": return
	var speed := v.airspeed(v.r, v.v, _air).length()
	if v.altitude() < 1900.0 or speed < 105.0:
		v.stage(); st.piloted = true

func frame(st: S, dt: float) -> void:
	var vessel := st.vessel
	var w: int = WARPS[st.warp_idx]
	var sim_seconds := dt * w
	if st.cruise != null:
		var cruise = st.cruise
		cruise.step(sim_seconds)
		cruise.position(_a)
		vessel.met = cruise.tau; vessel.coord = cruise.t
		vessel.clock_delta = cruise.tau - cruise.t
		var facing := -1.0 if cruise.leg == "decel" else 1.0
		_q.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), _b.copy_from(cruise.dir).scale_in(facing))
		vessel.q.slerp_in(_q, 1.0 - exp(-dt * 1.4))
		Relativity.sky_boost(cruise.dir, cruise.beta, st.boost)
	else:
		st.boost.set_v(0.0, 0.0, 0.0)
		if st.count != null: step_count(st, sim_seconds)
		pilot(st)
		if st.ap != null: st.ap.update(minf(dt, 0.1))
		var rails := w > 4 and vessel.can_rail()
		if rails:
			vessel.step(sim_seconds, { "rails": true })
		else:
			var rem := sim_seconds
			var guard := 0
			while rem > 1e-6 and guard < 24:
				guard += 1
				var h := minf(rem, 0.5 * maxf(w, 1.0))
				vessel.step(h)
				rem -= h
		if w > 4 and not vessel.can_rail(): set_warp(st, 2)

func want_warp(st: S) -> int:
	var sc := st.sc
	if st.cruise != null: return WARPS.size() - 1
	if sc.get("coastWarp") != null and st.ap.program == "circularize" and st.vessel.throttle == 0.0:
		return WARPS.find(int(sc.coastWarp))
	return WARPS.find(int(sc.get("warp", 1)))

func is_done(st: S) -> bool:
	var v := st.vessel
	if st.cruise != null: return st.cruise.leg == "arrived"
	if v.phase == Vessel.PHASE.DESTROYED or v.phase == Vessel.PHASE.LANDED: return true
	if st.sc.get("until") == "orbit": return st.ap.program == null and v.phase == Vessel.PHASE.ORBIT and st.count == null
	return false

func sample_of(st: S, f: int) -> Dictionary:
	var v := st.vessel
	var t := v.telemetry
	var ap := st.ap
	if st.cruise != null:
		var c = st.cruise
		return { "f": f, "tau": c.tau, "t": c.t, "phi": c.phi, "s": c.s, "prop": c.prop, "leg": c.leg,
				 "q": [v.q.x, v.q.y, v.q.z, v.q.w], "boost": [st.boost.x, st.boost.y, st.boost.z] }
	return {
		"f": f, "met": v.met, "coord": v.coord, "clockDelta": v.clock_delta,
		"r": [v.r.x, v.r.y, v.r.z], "v": [v.v.x, v.v.y, v.v.z], "quat": [v.q.x, v.q.y, v.q.z, v.q.w],
		"alt": num(t.get("alt")), "speed": num(t.get("speed")), "q": num(t.get("q")), "mach": num(t.get("mach")),
		"gees": num(t.get("gees")), "thr": v.throttle, "mass": num(t.get("mass")), "apo": num(t.get("apo")),
		"peri": num(t.get("peri")), "ecc": num(t.get("ecc")), "inc": num(t.get("inc")), "dv": num(t.get("dv")),
		"downrange": num(t.get("downrange")), "heat": num(t.get("heat")),
		"phase": v.phase, "prog": ap.program, "st": ap.state_name, "status": ap.status,
		"parent": v.parent.name, "warp": WARPS[st.warp_idx],
	}

func run(sc: Dictionary, fix_bodies: Array, dt: float) -> Dictionary:
	var st := make_state(sc, fix_bodies)
	var samples := []
	var max_frames := int(sc.get("maxFrames", 60000))
	var every := int(sc.get("every", 300))
	var f := 0
	var t0 := Time.get_ticks_usec()
	while f < max_frames:
		set_warp(st, want_warp(st))
		frame(st, dt)
		var v := st.vessel
		if st.cruise == null and v.max_q > st.best.q:
			st.best = { "q": v.max_q, "met": v.met, "alt": v.telemetry.alt }
		if f % every == 0: samples.append(sample_of(st, f))
		if is_done(st): break
		f += 1
	var wall := (Time.get_ticks_usec() - t0) / 1000.0
	samples.append(sample_of(st, f))
	var v := st.vessel
	var t := v.telemetry
	var summary := {
		"frames": f, "phase": v.phase, "failure": v.failure, "met": v.met, "coord": v.coord,
		"clockDelta": v.clock_delta, "mass": v.mass, "maxQ": v.max_q, "maxQMet": st.best.met, "maxQAlt": st.best.alt,
		"maxG": v.max_g, "heatLoad": v.heat_load, "peakHeat": v.peak_heat,
		"apo": num(t.get("apo")), "peri": num(t.get("peri")), "inc": num(t.get("inc")), "ecc": num(t.get("ecc")),
		"landedAt": v.landed_at, "parent": v.parent.name, "wallMs": wall,
	}
	var geared = null
	for s in v.stages:
		if s.attached and s.spec.get("legs", 0):
			geared = s; break
	summary.gear = geared.spec.get("gear") if geared != null else null
	if st.cruise != null:
		var ro: Dictionary = st.cruise.readout()
		ro.erase("plan")
		var lg := []
		for e in st.cruise.log: lg.append([e.tau, e.m])
		ro["log"] = lg
		summary.cruise = ro
		summary.plan = st.cruise.plan
	if sc.get("plan") != null:
		summary.transfer = st.ap.plan_transfer(find_body(st.bodies, sc.plan))
	var ev := []
	for e in v.events: ev.append([e.t, e.msg])
	return { "summary": summary, "samples": samples, "events": ev }

# ============================================================================
# PURE-FUNCTION SPOT CHECKS — the same inputs as flightref.mjs's spot()
# ============================================================================
func spot(fix_bodies: Array) -> Dictionary:
	var out := {}
	var bodies := body_objects(fix_bodies)
	for b in bodies:
		var e := Rocketry.flight_env(b)
		out["env_" + b.name] = { "mu": e.mu, "radius": e.radius, "gSurf": e.gSurf, "rotRate": e.rotRate, "vRotEq": e.vRotEq,
			"daySec": e.daySec, "vEsc": e.vEsc, "vCirc": e.vCirc, "karman": e.karman, "hasAtm": e.atm != null,
			"atm": { "p0": e.atm.p0, "rho0": e.atm.rho0, "T0": e.atm.T0, "top": e.atm.top } if e.atm != null else null }
	var atm_e = Rocketry.flight_env(find_body(bodies, "Earth")).atm
	var atm_m = Rocketry.flight_env(find_body(bodies, "Mars")).atm
	var rows := []
	for h in [-100.0, 0.0, 500.0, 5000.0, 11000.0, 12500.0, 20000.0, 32000.0, 45000.0, 50000.0, 80000.0, 139999.0, 140000.0, 2e5]:
		rows.append([h, Rocketry.density(atm_e, h), Rocketry.pressure(atm_e, h), Rocketry.temperature(atm_e, h), Rocketry.scale_height(atm_e, h),
			Rocketry.speed_of_sound(atm_e, h), Rocketry.density(atm_m, h), Rocketry.pressure(atm_m, h), Rocketry.scale_height(atm_m, h)])
	out.atmosphere = rows
	var cd := []
	for M in [0.0, 0.5, 0.8, 0.95, 1.1, 1.25, 1.4, 2.5, 4.0, 8.0, 40.0]:
		cd.append([M, Rocketry.drag_coefficient(M), Rocketry.blunt_drag_coefficient(M)])
	out.cd = cd
	out.heat = [Rocketry.heat_flux(1e-4, 7800.0, 1.0), Rocketry.heat_flux(0.01, 5500.0, 0.02), Rocketry.heat_flux(0.0, 1000.0, 1.0)]
	var sol := []
	for x in [0.0, 0.02, 0.1, 0.3, 0.5, 0.9, 1.0, 1.2]: sol.append(Rocketry.solid_thrust_fraction(x))
	out.solid = sol
	var eng := []
	for k in Vehicles.ENGINES:
		for row in [[1, 101325.0, 1.0, 0.0], [3, 50000.0, 0.7, 0.3], [2, 0.0, 0.05, 0.9], [1, 0.0, 0.0, 0.0]]:
			var o := Rocketry.engine_output(Vehicles.ENGINES[k], row[0], row[1], row[2], row[3])
			eng.append([k, row[0], row[1], row[2], o.F, o.mdot, o.isp, o.throttle])
	out.engine = eng
	out.burnTime = [Rocketry.burn_time_for(1000.0, 5e5, 1e6, 350.0), Rocketry.burn_time_for(0.0, 1.0, 1.0, 1.0), Rocketry.burn_time_for(3137.0, 140000.0, 1033e3, 421.0)]
	var vd := {}
	for k in Vehicles.VEHICLE_ORDER:
		var veh: Dictionary = Vehicles.VEHICLES[k]
		var sdv := []
		var areas := []
		for i in veh.stages.size():
			sdv.append(Vehicles.stage_delta_v(veh, i))
			areas.append(veh.stages[i].area)
		vd[k] = { "gross": Vehicles.gross_mass(veh), "dv": Vehicles.total_delta_v(veh), "twr": Vehicles.pad_twr(veh),
				  "F": Vehicles.liftoff_thrust(veh), "stageDv": sdv, "areas": areas }
	out.vehicles = vd
	var mu := 3.986e14
	var cases := [
		[[6.771e6, 0.0, 0.0], [0.0, 0.0, 7672.0]], [[7e6, 1e5, -2e5], [100.0, -300.0, 8200.0]],
		[[6.6e6, 0.0, 0.0], [0.0, 2000.0, 11200.0]], [[4e7, 3e6, 1e6], [-200.0, 50.0, 3000.0]],
		[[6.5e6, 0.0, 1e5], [0.0, 0.0, 11050.0]],
	]
	var orb := []
	for c in cases:
		var rv := DVec3.new(c[0][0], c[0][1], c[0][2])
		var vv := DVec3.new(c[1][0], c[1][1], c[1][2])
		var el := Orbit.elements(rv, vv, mu)
		var elo := {}
		for k in el: elo[k] = num(el[k])
		var res := { "el": elo }
		res.tApo = num(Orbit.time_to_apoapsis(el, mu)); res.tPeri = num(Orbit.time_to_periapsis(el, mu))
		res.circ = num(Orbit.circularize_dv(el, mu))
		for d in [60.0, 1800.0, 86400.0, -900.0]:
			var ro := DVec3.new()
			var vo := DVec3.new()
			var ok := Orbit.propagate(rv, vv, mu, d, ro, vo)
			res["p" + str(int(d))] = [ok, ro.x, ro.y, ro.z, vo.x, vo.y, vo.z]
		orb.append(res)
	out.orbit = orb
	var stu := []
	for z in [-50.0, -1.0, -1e-7, 0.0, 1e-7, 1.0, 30.0]: stu.append([Orbit.stumpff_c(z), Orbit.stumpff_s(z)])
	out.stumpff = stu
	out.hohmann = [Orbit.hohmann(3.986e14, 6.671e6, 4.2164e7), Orbit.hohmann(1.32712440018e20, 1.496e11, 2.279e11)]
	out.soi = [Orbit.sphere_of_influence(3.844e8, 3.69e-8, 3e-6), Orbit.sphere_of_influence(0.0, 1.0, 1.0)]
	out.phase = Orbit.phase_angle(DVec3.new(1.0, 0.0, 0.0), DVec3.new(-1.0, 0.0, -0.1))
	var yrs := []
	for y in [1e-4, 0.5, 13.9, 5000.0, 3e7, INF]: yrs.append(Relativity.fmt_years(y))
	var budget := Relativity.rapidity_budget(1e5, 2e6, 299792458.0)
	out.rel = {
		"budget": budget,
		"tau": Relativity.solve_profile(11.9, 1.5 * 9.80665, budget),
		"flip": Relativity.solve_profile(4.246, 9.80665, 10.0),
		"short": Relativity.solve_profile(11.9, 9.80665, 0.1),
		"doppler": [Relativity.doppler_factor(0.5, 1.0), Relativity.doppler_factor(0.9, -0.3)],
		"cone": Relativity.aberration_cone(0.9), "beta": Relativity.beta_of(1.2), "gamma": Relativity.gamma_of(1.2),
		"rap": Relativity.rapidity_of(0.99), "years": yrs,
	}
	var fd := []
	for s in [0.0, 59.9, 3725.0, 90061.0, -45.0, INF]: fd.append(Guidance.fmt_dur(s))
	out.fmtDur = fd
	return out

# ============================================================================
# PERFORMANCE — how many vessel RK4 steps a second GDScript sustains
# ============================================================================
func bench(fixture: Dictionary) -> void:
	var bodies := body_objects(fixture.bodies)
	var earth: Body = find_body(bodies, "Earth")
	for case_i in 3:
		var veh: Dictionary = Vehicles.VEHICLES["saturnv" if case_i < 2 else "falcon9"]
		var vessel := Vessel.new({ "vehicle": veh, "parent": earth, "bodies": bodies, "payload": 0.0 })
		var label := ""
		if case_i == 0:
			# powered, in thick air: every term in accel() is live
			vessel.place_in_orbit(10000.0, 0.0, 0.0)
			vessel.v.scale_in(0.1)
			vessel.throttle = 1.0
			label = "powered, in the atmosphere (Saturn V, 11 bodies)"
		elif case_i == 1:
			vessel.place_in_orbit(250000.0, 0.0, 0.0)
			label = "coasting in vacuum (Saturn V, 11 bodies)"
		else:
			vessel.place_in_orbit(250000.0, 0.0, 0.0)
			label = "rails: Orbit.propagate (Falcon 9)"
		var s := {}
		var n := 20000
		var t0 := Time.get_ticks_usec()
		if case_i < 2:
			for i in n: vessel.rk4(0.01, s)
		else:
			for i in n: Orbit.propagate(vessel.r, vessel.v, vessel.env.mu, 60.0, vessel.r, vessel.v)
		var us := float(Time.get_ticks_usec() - t0)
		print("%-52s %8.1f µs/step  %9.0f steps/s" % [label, us / n, n / (us / 1e6)])
	# A whole guided frame: autopilot + substeps + sample, as spaceflight runs it.
	var vessel2 := Vessel.new({ "vehicle": Vehicles.VEHICLES.falcon9, "parent": earth, "bodies": bodies, "payload": 0.0 })
	vessel2.place_on_pad(28.6, 0.0)
	var ap := Guidance.Autopilot.new(vessel2)
	ap.engage("ascent")
	var frames := 0
	var t1 := Time.get_ticks_usec()
	while vessel2.met < 150.0:
		ap.update(1.0 / 60.0)
		vessel2.step(1.0 / 60.0)
		frames += 1
	var us2 := float(Time.get_ticks_usec() - t1)
	print("%-52s %8.1f µs/frame over %d frames (1× launch at 60 fps)" % ["guided ascent frame (Falcon 9, T+0…150 s)", us2 / frames, frames])
