class_name FlightScenarios
extends RefCounted

# Named, reproducible flight states for the developer menu, `scenario=<vehicle>:<id>`
# and tools/scenariocheck.gd. A scenario builds its base directly (on the pad in the
# count, in orbit, a descent's start, or part-way through a return as a played flight
# passed it) and then, when `until` is set, flies the real frame loop undrawn until
# that moment. Fidelity and the replay comparison: docs/flight-scenarios.md.
#
# Scenario keys:
#   id, title, group       menu entry (group: Ascent, Orbit, Return, Booster, Landing)
#   base                   {kind: pad|orbit|return|descent|air, ...}; see build()
#   until                  conditions that must all hold (see reached()); none = the base
#   after                  seconds flown on once `until` holds
#   dt                     the fast-forward's frame, where guidance is sensitive to it
#   expect                 what tools/scenariocheck.gd requires at the hand-over
#   tol                    its replay tolerances, where they differ from TOLERANCE

## The frame interval of the fast-forward: the longest a played frame can be
## (main.gd caps dt at 50 ms), so it is a flight played at 20 fps.
const DT := 0.05
const MAX_FRAMES := 400000

const ORDER := ["saturnv", "falcon9", "shuttle", "starship", "lm", "skycrane"]
const NAMES := {"saturnv": "Saturn V", "falcon9": "Falcon 9", "shuttle": "Shuttle", "starship": "Starship",
	"lm": "Lunar Module", "skycrane": "Sky crane"}

static var _list := {}

static func vehicles() -> Array:
	return ORDER

## Every scenario for `vehicle`, in menu order.
static func list(vehicle: String) -> Array:
	if _list.is_empty(): _list = _build_list()
	return _list.get(vehicle, [])

static func find(vehicle: String, id: String):
	for sc: Dictionary in list(vehicle):
		if sc.id == id: return sc
	return null

## "vehicle:id" → the scenario, or null.
static func parse(spec: String):
	var parts := spec.split(":", false, 1)
	if parts.size() != 2: return null
	return find(parts[0], parts[1])

static func _pad() -> Dictionary: return {"kind": "pad", "count": 10.0}

static func _sc(vehicle: String, id: String, title: String, group: String, base: Dictionary,
		until := {}, expect := {}, after := 0.0) -> Dictionary:
	var sc := {"vehicle": vehicle, "id": id, "title": title, "group": group, "base": base,
		"until": until, "after": after, "expect": expect}
	# A booster's landing burn starts on a test made once a frame, and moves by
	# hundreds of metres between 20 and 60 fps: those are flown at 60.
	if base.get("program") in ["catch", "hoverslam"]: sc.dt = 1.0 / 60.0
	# The LM's descent guidance updates once a frame too; flown at 20 fps it lands in
	# P64 a few seconds late (docs/flight-scenarios.md), which is within `tol`.
	if base.get("program") == "land": sc.tol = {"speed": [20.0, 0.06], "mass": [100.0, 0.025], "fpa": [2.0, 0.0]}
	return sc

# Ascent windows are where this build flies them (T+ s, km), not the flown values:
# the check is that a scenario lands where its own flight does.
static func _build_list() -> Dictionary:
	var out := {}
	out.saturnv = [
		_sc("saturnv", "pad", "Pad, T−10 s", "Ascent", _pad(), {}, {"phase": "prelaunch", "count": [9.0, 10.0]}),
		_sc("saturnv", "liftoff", "Liftoff, tower clear", "Ascent", _pad(), {"t_plus": 9.0}, {"alt": [80.0, 400.0]}),
		_sc("saturnv", "max_q", "Max-Q", "Ascent", _pad(), {"past_max_q": true}, {"alt": [9e3, 14e3], "q": [30e3, 40e3]}),
		_sc("saturnv", "sic_staging", "S-IC staging", "Ascent", _pad(), {"burnout_in": ["sic", 4.0]},
			{"alt": [52e3, 64e3], "attached": ["sic"]}),
		_sc("saturnv", "interstage", "S-II interstage jettison", "Ascent", _pad(), {"since_drop": ["sic", 27.0]},
			{"alt": [72e3, 86e3], "attached": ["sii_aft_is", "sii"], "gone": ["sic"]}),
		_sc("saturnv", "sii_staging", "S-II staging, S-IVB ignition", "Ascent", _pad(), {"burnout_in": ["sii", 4.0]},
			{"alt": [100e3, 125e3], "attached": ["sii"]}),
		_sc("saturnv", "orbit", "Parking orbit, S-IVB and CSM", "Orbit",
			{"kind": "orbit", "alt": 185e3, "inc": 32.5, "drop": 3, "prop": {"sivb": 75000.0}}, {},
			{"alt": [180e3, 190e3], "attached": ["sivb", "csm"], "phase": "orbit"}),
	]
	out.falcon9 = [
		_sc("falcon9", "pad", "Pad, T−10 s", "Ascent", _pad(), {}, {"phase": "prelaunch"}),
		_sc("falcon9", "liftoff", "Liftoff", "Ascent", _pad(), {"t_plus": 4.0}, {"alt": [10.0, 200.0]}),
		_sc("falcon9", "max_q", "Max-Q", "Ascent", _pad(), {"past_max_q": true}, {"alt": [8e3, 13e3], "q": [28e3, 38e3]}),
		_sc("falcon9", "meco", "MECO and stage separation", "Ascent", _pad(), {"burnout_in": ["f9s1", 4.0]},
			{"alt": [55e3, 68e3], "attached": ["f9s1"]}),
		# Free-molecular heating falls through 1135 W/m² near 112 km, T+222 s (73 s after
		# staging); the real vehicle drops its fairing about T+3:30 near 110 km.
		_sc("falcon9", "fairing", "Fairing jettison", "Ascent", _pad(), {"since_drop": ["f9s1", 70.0]},
			{"alt": [100e3, 125e3], "attached": ["f9fair"]}),
		_sc("falcon9", "orbit", "Parking orbit", "Orbit",
			{"kind": "orbit", "alt": 210e3, "inc": 28.5, "drop": 1, "jettison": ["f9fair"], "prop": {"f9s2": 15000.0}}, {},
			{"alt": [200e3, 220e3], "attached": ["f9s2", "f9pl"], "phase": "orbit"}),
		# docs/flight-scenarios.md: flightcheck's f9booster start, a booster after its boostback.
		_sc("falcon9", "booster_return", "Booster return, 70 km", "Booster", _f9_booster(), {},
			{"alt": [68e3, 71e3], "program": "hoverslam"}),
		_sc("falcon9", "entry_burn", "Booster entry burn", "Booster", _f9_booster(), {"lit": true},
			{"alt": [30e3, 70e3], "program": "hoverslam"}),
		_sc("falcon9", "landing_burn", "Booster landing burn", "Booster", _f9_booster(), {"ap": ["slamming", true]},
			{"alt": [500.0, 6000.0], "program": "hoverslam"}),
	]
	out.shuttle = [
		_sc("shuttle", "pad", "Pad, T−10 s", "Ascent", _pad(), {}, {"phase": "prelaunch"}),
		_sc("shuttle", "liftoff", "Liftoff, tower clear", "Ascent", _pad(), {"t_plus": 4.0}, {"alt": [40.0, 250.0]}),
		_sc("shuttle", "roll_program", "Roll program", "Ascent", _pad(), {"event": "Roll program"}, {"alt": [50.0, 400.0]}),
		_sc("shuttle", "max_q", "Max-Q, throttle bucket", "Ascent", _pad(), {"past_max_q": true}, {"alt": [9e3, 14e3], "q": [30e3, 38e3]}),
		_sc("shuttle", "srb_sep", "SRB separation", "Ascent", _pad(), {"burnout_in": ["srb", 3.0]},
			{"alt": [42e3, 50e3], "attached": ["srb"]}),
		_sc("shuttle", "meco", "MECO", "Ascent", _pad(), {"event": "MECO"}, {"alt": [105e3, 120e3], "attached": ["et"]}),
		_sc("shuttle", "et_sep", "External tank separation", "Ascent", _pad(), {"event": "MECO"},
			{"alt": [105e3, 120e3], "attached": ["et"]}, 15.0),
		_sc("shuttle", "orbit", "Orbiter in orbit", "Orbit", _orbiter(), {},
			{"alt": [295e3, 305e3], "attached": ["orbiter"], "phase": "orbit"}),
		_sc("shuttle", "deorbit", "Deorbit burn", "Return", _orbiter("glide"), {"event": "Deorbit burn — ignition"},
			{"alt": [295e3, 305e3], "program": "glide"}, 5.0),
		_sc("shuttle", "entry_interface", "Entry interface, 122 km", "Return", _orbiter("glide"), {"alt_below": 122e3},
			{"alt": [119e3, 123e3], "speed": [7400.0, 7900.0], "program": "glide", "state": "entry"}),
		_sc("shuttle", "entry_80km", "Entry, 80 km", "Return", _orbiter_air(80e3), {},
			{"alt": [79e3, 81e3], "airspeed": [7400.0, 7700.0], "program": "glide", "state": "entry"}),
		_sc("shuttle", "peak_heating", "Peak heating", "Return", _orbiter_air(80e3), {"past_peak_heat": true},
			{"alt": [60e3, 72e3], "airspeed": [6600.0, 7300.0], "program": "glide", "state": "entry"}),
		_sc("shuttle", "roll_reversal", "First roll reversal", "Return", _orbiter_air(80e3), {"event": "Roll reversal"},
			{"alt": [50e3, 75e3], "program": "glide", "state": "entry"}),
		_sc("shuttle", "taem", "TAEM, Mach 2.5", "Return", _orbiter_air(24.4e3), {},
			{"alt": [24e3, 25e3], "airspeed": [700.0, 800.0], "program": "glide", "state": "taem"}),
		_sc("shuttle", "final_approach", "Final approach, outer glide slope", "Return", _orbiter_air(3990.0), {},
			{"alt": [3900.0, 4100.0], "program": "glide", "state": "approach"}),
		_sc("shuttle", "flare", "Preflare and touchdown", "Return", _orbiter_air(3990.0), {"state": "flare"},
			{"alt": [300.0, 620.0], "program": "glide", "state": "flare"}),
		_sc("shuttle", "rollout", "Rollout", "Return", _orbiter_air(3990.0), {"phase": "rollout"},
			{"alt": [-5.0, 5.0], "phase": "rollout"}, 2.0),
	]
	out.starship = [
		_sc("starship", "pad", "Pad, T−10 s", "Ascent", _pad(), {}, {"phase": "prelaunch"}),
		_sc("starship", "liftoff", "Liftoff", "Ascent", _pad(), {"t_plus": 5.0}, {"alt": [20.0, 300.0]}),
		_sc("starship", "max_q", "Max-Q", "Ascent", _pad(), {"past_max_q": true}, {"alt": [7e3, 12e3], "q": [30e3, 38e3]}),
		_sc("starship", "hot_staging", "Hot staging", "Ascent", _pad(), {"burnout_in": ["sh", 4.0]},
			{"alt": [52e3, 66e3], "attached": ["sh"]}),
		_sc("starship", "orbit", "Ship in orbit", "Orbit", _ship(), {},
			{"alt": [195e3, 205e3], "attached": ["ss"], "phase": "orbit"}),
		_sc("starship", "deorbit", "Ship deorbit burn", "Return", _ship("bellyflop"), {"event": "Deorbit burn — ignition"},
			{"program": "bellyflop"}, 5.0),
		_sc("starship", "bellyflop", "Belly-flop entry, 80 km", "Return", _ship_air(80e3), {},
			{"alt": [79e3, 81e3], "program": "bellyflop", "state": "entry"}),
		_sc("starship", "subsonic", "Belly-flop fall, 15 km", "Return", _ship_air(15e3), {},
			{"alt": [14e3, 16e3], "airspeed": [150.0, 250.0], "program": "bellyflop", "state": "entry"}),
		_sc("starship", "flip", "Flip", "Return", _ship_air(15e3), {"state": "flip"},
			{"alt": [200.0, 3000.0], "program": "bellyflop", "state": "flip"}),
		_sc("starship", "landing_burn", "Landing burn", "Return", _ship_air(15e3), {"state": "landing"},
			{"alt": [50.0, 2000.0], "program": "bellyflop", "state": "landing"}),
		# Super Heavy alone after its boostback burn (CatchTower.begin_return), 95 km up.
		_sc("starship", "boostback", "Booster after boostback, 95 km", "Booster", {"kind": "return", "program": "catch"}, {},
			{"alt": [90e3, 100e3], "program": "catch"}),
		_sc("starship", "booster_15km", "Booster falling, 15 km", "Booster", _booster_air(), {},
			{"alt": [14.5e3, 15.5e3], "program": "catch"}),
		_sc("starship", "booster_landing_burn", "Booster landing burn", "Booster", _booster_air(), {"state": "landing"},
			{"alt": [5e3, 12e3], "program": "catch", "state": "landing"}),
		_sc("starship", "tower_catch", "Tower catch", "Booster", _booster_air(), {"state": "terminal", "alt_below": 400.0},
			{"alt": [0.0, 400.0], "program": "catch", "state": "terminal"}),
	]
	out.lm = [
		_sc("lm", "powered_descent", "Powered descent initiation, 15 km", "Landing",
			{"kind": "orbit", "alt": 15000.0, "inc": 0.0, "program": "land"}, {}, {"alt": [14e3, 16e3], "program": "land"}),
		_sc("lm", "approach", "P64 approach phase", "Landing", {"kind": "orbit", "alt": 15000.0, "inc": 0.0, "program": "land"},
			{"state": "P64"}, {"alt": [1000.0, 9000.0], "program": "land", "state": "P64"}),
		_sc("lm", "terminal_descent", "P66 terminal descent", "Landing", {"kind": "orbit", "alt": 15000.0, "inc": 0.0, "program": "land"},
			{"state": "P66"}, {"alt": [5.0, 400.0], "program": "land", "state": "P66"}),
	]
	out.skycrane = [
		_sc("skycrane", "entry", "Mars entry, 125 km", "Landing", _skycrane(), {}, {"alt": [120e3, 126e3], "program": "edl"}),
		_sc("skycrane", "parachute", "Parachute", "Landing", _skycrane(), {"state": "chute"},
			{"alt": [4e3, 16e3], "program": "edl", "state": "chute"}),
		_sc("skycrane", "powered_descent", "Powered descent", "Landing", _skycrane(), {"state": "powered"},
			{"alt": [300.0, 3000.0], "program": "edl", "state": "powered"}),
		_sc("skycrane", "sky_crane", "Sky crane", "Landing", _skycrane(), {"ap": ["crane_out", true]},
			{"alt": [5.0, 60.0], "program": "edl"}),
	]
	return out

## The orbiter alone in a 300 km, 51.6° orbit with its OMS propellant, as
## tools/missioncheck.gd's orbiter_return starts.
static func _orbiter(program = null) -> Dictionary:
	return {"kind": "orbit", "alt": 300e3, "inc": 51.6, "drop": 2, "program": program}

## The orbiter mid-return, built where tools/scenariocheck.gd's replay of
## _orbiter("glide") passes `alt` (its speed, flight-path angle and guidance filters
## there, at 1×), with the OMS propellant the deorbit burn left. Each also names the
## replay that checks it (`replay`).
const ORBITER_AIR := {
	80e3: {"airspeed": 7568.3, "fpa": -0.981, "mass": 107383.5, "ap": {"_bank_sign": 1.0, "_drag_f": 0.761},
		"state": {"alt_below": 80e3}},
	24.4e3: {"airspeed": 759.6, "fpa": -6.358, "mass": 107361.5, "speedbrake": 0.457, "state": {"state": "taem"}},
	3990.0: {"airspeed": 193.3, "fpa": -19.82, "mass": 107361.5, "speedbrake": 0.748, "ap": {"_sb_trim": 0.6746},
		"state": {"state": "approach"}},
}

static func _orbiter_air(alt: float) -> Dictionary:
	var d: Dictionary = ORBITER_AIR[alt]
	return {"kind": "air", "alt": alt, "inc": 51.6, "drop": 2, "prop": {"orbiter": 8359.5}, "program": "glide",
		"airspeed": d.airspeed, "fpa": d.fpa, "mass": d.mass, "speedbrake": d.get("speedbrake", 0.0), "ap": d.get("ap", {}),
		"replay": {"base": _orbiter("glide"), "until": d.state}}

## The ship mid-return, as _orbiter_air, from the replay of _ship("bellyflop").
const SHIP_AIR := {
	80e3: {"airspeed": 7314.5, "fpa": -0.653, "prop": 38083.2, "mass": 138626.1, "state": {"alt_below": 80e3}},
	15e3: {"airspeed": 192.3, "fpa": -77.70, "prop": 38083.2, "mass": 138132.3, "state": {"alt_below": 15e3}},
}

static func _ship_air(alt: float) -> Dictionary:
	var d: Dictionary = SHIP_AIR[alt]
	return {"kind": "air", "alt": alt, "inc": 28.5, "drop": 1, "prop": {"ss": d.prop}, "program": "bellyflop",
		"airspeed": d.airspeed, "fpa": d.fpa, "mass": d.mass, "replay": {"base": _ship("bellyflop"), "until": d.state}}

## Super Heavy 15 km over the tower in its coast, where the replay of the return from
## its boostback apogee passes (relative to the tower, as CatchTower.begin_return
## takes it), so the boostback targeting is not solved again.
static func _booster_air() -> Dictionary:
	return {"kind": "return", "program": "catch", "mass": 397509.0,
		"at": {"alt": 14983.9, "off": [577.84, 15.61], "vel": [-43.451, -1.133, -1087.957]},
		"replay": {"base": {"kind": "return", "program": "catch"}, "until": {"alt_below": 15e3}}}

## The ship alone in a 200 km orbit with 40 t of landing propellant, as
## missioncheck's ship_return starts.
static func _ship(program = null) -> Dictionary:
	return {"kind": "orbit", "alt": 200e3, "inc": 28.5, "drop": 1, "prop": {"ss": 40000.0}, "program": program}

## flightcheck's f9booster: the first stage alone, 61.65 t left, 70 km up and falling.
static func _f9_booster() -> Dictionary:
	return {"kind": "descent", "stages": [0], "prop": {"f9s1": 61650.0}, "alt": 70e3, "v_vert": -1000.0, "v_horiz": 200.0,
		"program": "hoverslam"}

## flightcheck's skycrane: 125 km over Mars at 5.8 km/s inertial, 15.5° down.
static func _skycrane() -> Dictionary:
	return {"kind": "descent", "alt": 125e3, "v_inertial": 5800.0, "fpa": -15.5, "program": "edl"}

# BUILDING
## Build the scenario's base on `main.flight`. Models must be ready (CraftAssets).
## Returns "" or why it could not be built.
static func build(main, sc: Dictionary) -> String:
	var f: Spaceflight = main.flight
	var b: Dictionary = sc.base
	var key: String = sc.vehicle
	var v: Vessel = null
	match str(b.kind):
		"pad":
			v = f.begin(key, {"mode": "pad"})
		"return":
			v = f.begin(key, {"mode": "return", "catch_at": b.get("at")})
		"orbit":
			v = f.begin(key, {"mode": "orbit", "alt": float(b.alt), "inc": float(b.get("inc", 0.0)),
				"phase": float(b.get("phase", 0.0))})
		"descent":
			v = f.begin(key, {"mode": "orbit", "alt": float(b.alt), "phase": 0.0, "vehicle": _subset(key, b)})
			if v != null: _descent_state(v, b)
		"air":
			v = f.begin(key, {"mode": "orbit", "alt": float(b.alt), "inc": float(b.get("inc", 0.0)), "phase": 0.0})
		_:
			return "unknown base %s" % b.kind
	if v == null: return "%s cannot fly from here" % key
	var gone := []
	for i in int(b.get("drop", 0)): gone.append(v.stage(true))
	for k in b.get("jettison", []): gone.append(v.jettison(str(k)))
	for st in gone:
		# Gone before the scenario starts, so nothing separates on the first frame.
		if st != null and f.craft != null and f.craft.stage(str(st.spec.key)) != null:
			f.craft.stage(str(st.spec.key)).group.visible = false
	for k in b.get("prop", {}):
		for st in v.stages:
			if str(st.spec.key) == k: st.prop = float(b.prop[k])
	if b.has("mass"):
		# What the RCS had used by then, which nothing else in the base records.
		var extra: float = v.mass - float(b.mass)
		for st in v.stages:
			if not st.attached or extra <= 0.0: continue
			var take := minf(extra, st.rcs_prop)
			st.rcs_prop -= take
			extra -= take
	if b.kind == "air": _air_state(v, b)
	if b.get("program") != null:
		f.run_program(str(b.program))
	if b.kind == "air" or b.has("at"): _settle(f, b)
	if b.kind == "pad":
		# run_program("ascent") on the pad starts the count; hold it at the base's T−.
		if f.count == null: f.start_count(float(b.get("count", 10.0)))
		f.count.t = float(b.get("count", 10.0))
	v.sample(0.0)
	return ""

## The vehicle with only the base's stages, as flightcheck's vehicle_for.
static func _subset(key: String, b: Dictionary) -> Dictionary:
	var veh: Dictionary = Vehicles.VEHICLES[key]
	if b.get("stages") == null: return veh
	var out := veh.duplicate(false)
	out.stages = (b.stages as Array).map(func(i): return veh.stages[int(i)])
	return out

## Speed and attitude of a descent's start: the velocity relative to the turning air,
## nose against it ("retro-air").
static func _descent_state(v: Vessel, b: Dictionary) -> void:
	var up := DQuat.nrm(v.r.clone())
	var east := DQuat.nrm(DVec3.new(0.0, -1.0, 0.0).cross(up))
	var spin := DVec3.new(0.0, -float(v.env.rotRate), 0.0).cross(v.r)
	if b.has("v_inertial"):
		var g := deg_to_rad(float(b.fpa))
		v.v.copy_from(east).scale_in(float(b.v_inertial) * cos(g)).add_scaled_in(up, float(b.v_inertial) * sin(g))
	else:
		v.v.copy_from(up).scale_in(float(b.v_vert)).add_scaled_in(east, float(b.v_horiz)).add_in(spin)
	var air := v.airspeed(v.r, v.v, DVec3.new())
	v.q.set_from_unit_vectors(Vessel.BODY_FWD, DQuat.nrm(air.scale_in(-1.0)))
	v.omega.set_v(0.0, 0.0, 0.0)
	v.phase = Vessel.PHASE.DESCENT

## In the air: `airspeed` m/s through air that turns with the planet, along the
## orbit's track, `fpa` degrees above the horizon (negative descending). _settle sets
## the attitude.
static func _air_state(v: Vessel, b: Dictionary) -> void:
	var up := DQuat.nrm(v.r.clone())
	var track := v.v.clone().add_scaled_in(up, -v.v.dot(up))
	DQuat.nrm(track)
	var g := deg_to_rad(float(b.fpa))
	var va := float(b.airspeed)
	v.v.copy_from(track).scale_in(va * cos(g)).add_scaled_in(up, va * sin(g))
	v.v.add_in(DVec3.new(0.0, -float(v.env.rotRate), 0.0).cross(v.r))
	v.speedbrake = float(b.get("speedbrake", 0.0))

## Guidance's first cycle on the built state, then the vehicle put in the attitude it
## asked for (nose on its aim, body +X on its roll reference) at rest, and the
## program's filters seeded with what they held in flight (`ap`).
static func _settle(f: Spaceflight, b: Dictionary) -> void:
	var v := f.vessel
	var ap = f.autopilot
	v.sample(0.0)
	ap.update(DT)
	if ap.aim != null:
		var y := DQuat.nrm((ap.aim as DVec3).clone())
		var ref: DVec3 = ap.aim_roll if ap.aim_roll != null else DVec3.new(0.0, -1.0, 0.0).cross(y)
		var x := ref.clone().add_scaled_in(y, -ref.dot(y))
		if x.length_sq() > 1e-12:
			DQuat.nrm(x)
			v.q.set_from_basis_columns(x, y, x.cross(y))
	v.omega.set_v(0.0, 0.0, 0.0)
	for k in b.get("ap", {}): ap.set(k, b.ap[k])
	v.sample(0.0)

# THE CONDITIONS
## Whether every condition in `u` holds. `t_plus`: seconds since liftoff;
## `past_max_q` / `past_peak_heat`: dynamic pressure / heat flux has peaked and fallen
## 3 %; `burnout_in`: [stage, s] burn time left at the present flow; `since_drop`:
## [stage, s] since it separated; `event`: a log line starting with it, since `from`;
## `state` / `phase`: the autopilot state / vessel phase; `alt_below`; `lit`: an engine
## burning; `ap`: [autopilot field, value].
static func reached(f: Spaceflight, u: Dictionary, from := 0) -> bool:
	var v := f.vessel
	var ap = f.autopilot
	var t: Dictionary = v.telemetry
	for k in u:
		var want = u[k]
		var ok := false
		match k:
			"t_plus": ok = f.count == null and v.phase != Vessel.PHASE.PRELAUNCH and v.met - v.t0 >= float(want)
			"past_max_q": ok = v.max_q > 5000.0 and float(t.get("q", 0.0)) < 0.97 * v.max_q
			"past_peak_heat":
				var heat := float(U.nz(t.get("heat"), 0.0))
				ok = v.peak_heat > 1e5 and heat < 0.97 * v.peak_heat
			"burnout_in":
				var st = _stage(v, str(want[0]))
				if st != null and st.attached and v.lit(st):
					var md: float = v._stage_mdot(st)
					ok = md > 0.0 and st.prop / md <= float(want[1])
			"since_drop":
				var st = _stage(v, str(want[0]))
				ok = st != null and st.dropped_met >= 0.0 and v.met - st.dropped_met >= float(want[1])
			"event":
				for i in range(from, v.events.size()):
					if str(v.events[i].msg).begins_with(str(want)): ok = true
			"state": ok = ap != null and str(ap.state_name) == str(want)
			"phase": ok = v.phase == str(want)
			"alt_below": ok = v.altitude() < float(want)
			"lit": ok = v.throttle > 0.0 and float(t.get("thrust", 0.0)) > 0.0
			"ap": ok = ap != null and ap.get(str(want[0])) == want[1]
		if not ok: return false
	return true

static func _stage(v: Vessel, key: String):
	for st in v.stages:
		if str(st.spec.key) == key: return st
	return null

## The warp rung a scenario is flown at: 1× in the count and in the air; above it 2×
## under power (the most the flight panel integrates at) and 10× on unpowered coasts,
## as tools/missioncheck.gd flies them. Not 2× in the air: a Shuttle ascent flown
## that way cuts off 10 km higher than at 1×.
static func played_warp(f: Spaceflight) -> int:
	var v := f.vessel
	var top: float = float(v.env.atm.top) if v.env.atm != null else 0.0
	if f.count != null or v.phase == Vessel.PHASE.PRELAUNCH or v.altitude() <= top: return 0
	var coasting: bool = v.throttle == 0.0 and not f.autopilot.burning
	return 3 if coasting and v.altitude() > top + 5000.0 else 1

## The base a scenario's replay starts from, and the condition it flies to: a built
## mid-flight state names the flight it stands in for (`replay`).
static func replay_of(sc: Dictionary) -> Dictionary:
	var r = sc.base.get("replay")
	if r == null: return {"base": sc.base, "until": sc.until}
	return {"base": r.base, "until": sc.until if not (sc.until as Dictionary).is_empty() else r.until}

# THE FAST-FORWARD
## Flies a built scenario to its moment through main.step_flight, a slice at a time
## (step() returns when its wall-clock budget is spent), so a menu can show progress.
class Jump extends RefCounted:
	var main
	var sc: Dictionary
	var frames := 0
	var sim_s := 0.0          # coordinate seconds flown
	var rails_s := 0.0        # of which on the coast's exact conic
	var done := false
	var error := ""
	var _met_hit := -1.0      # MET when `until` first held
	var _from := 0            # first event index to search
	var _wall_us := 0
	var dt := DT

	func _init(orchestrator, scenario: Dictionary) -> void:
		main = orchestrator
		sc = scenario
		_from = main.flight.vessel.events.size()
		dt = float(sc.get("dt", DT))
		done = (sc.until as Dictionary).is_empty() and float(sc.after) <= 0.0

	## Milliseconds spent flying so far.
	func wall_ms() -> float: return _wall_us / 1000.0

	## Fly on for up to `budget_ms`. True when done (check `error`).
	func step(budget_ms: float) -> bool:
		if done: return true
		var t0 := Time.get_ticks_usec()
		var f: Spaceflight = main.flight
		while Time.get_ticks_usec() - t0 < budget_ms * 1000.0:
			var v := f.vessel
			if v == null or not f.active or v.phase == Vessel.PHASE.DESTROYED:
				error = "the flight ended (%s)" % (str(v.failure) if v != null and v.failure != null else "destroyed")
				break
			if frames >= MAX_FRAMES:
				error = "not reached after %d frames: %s" % [frames, _status(f)]
				break
			if _met_hit < 0.0 and FlightScenarios.reached(f, sc.until, _from): _met_hit = v.met
			if _met_hit >= 0.0 and v.met - _met_hit >= float(sc.after):
				done = true
				break
			if not _coast(f): _frame(f)
		_wall_us += Time.get_ticks_usec() - t0
		if error != "": done = true
		if done:
			f.fast_forward = 0
			f.set_warp(0)
		return done

	func _frame(f: Spaceflight) -> void:
		_pick_warp(f)
		# In the air the pad cloud and the trail are laid as they flew (Plume.SmokeColumn); above it only what physics reads is kept.
		var v := f.vessel
		f.fast_forward = 1 if v.env.atm != null and v.altitude() < float(v.env.atm.top) else 2
		main.state.time += dt
		var seconds: float = main.step_flight(dt)
		f.update_visual(dt, seconds)
		sim_s += seconds
		frames += 1

	func _pick_warp(f: Spaceflight) -> void:
		var want := FlightScenarios.played_warp(f)
		if f.warp_index() != want: f.set_warp(want)

	## An unpowered coast down to the air with nothing to steer for is flown on its
	## exact conic in one step (Vessel.step's rails), to 25 km above the atmosphere's
	## top; guidance takes the attitude over again from there. Returns whether it did.
	func _coast(f: Spaceflight) -> bool:
		var v := f.vessel
		var ap = f.autopilot
		if v.env.atm == null or f.count != null or v.throttle > 0.0: return false
		if ap.burning or ap.node != null: return false
		var steady: bool = ap.program == null or (ap.program in ["glide", "bellyflop"] and ap.state_name == "entry")
		if not steady or v.r.dot(v.v) >= 0.0: return false
		var R: float = v.env.radius
		var target: float = R + float(v.env.atm.top) + 25000.0
		if v.r.length() < target + 2000.0: return false
		var t := Orbit.time_to_radius_descending(Orbit.elements(v.r, v.v, v.env.mu), v.env.mu, target)
		if not is_finite(t) or t < 30.0: return false
		main.state.last_steps = 0
		var accepted: float = v.step(t, {"rails": true, "advance_world": main._advance_flight_world})
		main._commit_positions(true)
		main.state.time += dt
		f.fast_forward = 2
		f.update_visual(dt, accepted)
		sim_s += accepted
		rails_s += accepted
		frames += 1
		return accepted > 0.0

	func _status(f: Spaceflight) -> String:
		var v := f.vessel
		return "%s, %s/%s at %s km, T+%s s" % [v.phase, f.autopilot.program, f.autopilot.state_name,
			U.fixed(v.altitude() / 1000.0, 1), U.fixed(v.met - v.t0, 0)]
