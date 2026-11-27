class_name SaveGame
extends RefCounted

# What a saved game holds, taken from the stage and put back on it. Every kind keeps the
# world: the scenario's settings, each body's spec with its live state (position, velocity,
# mass, spin, climate), the clock, painted decorations and the camera. A spaceflight adds
# the vessel; a planetary exploration adds the world explored, its pin and whether you
# stand on it. A save is validated whole before the stage changes, and a capture is
# refused if it would not load back. What is and is not kept: docs/save-format.md.

const SCENE_KEYS := ["name", "blurb", "sceneScale", "bodyScale", "camRadius", "focus", "massSlider", "surface", "mesh",
	"spawnAtRest", "lensing", "trueScale", "timeScale", "maxStep", "gwBoost", "discIntensity", "discOuter", "epochJD"]
const SCENE_KINDS := {"name": "s", "blurb": "s", "focus": "s", "massSlider": "b", "surface": "b", "mesh": "b",
	"spawnAtRest": "b", "lensing": "b", "trueScale": "b", "sceneScale": "n", "bodyScale": "n", "camRadius": "n",
	"timeScale": "n", "maxStep": "n", "gwBoost": "n", "discIntensity": "n", "discOuter": "n", "epochJD": "n"}
const KIND_MODE := {"sandbox": "sandbox", "spaceflight": "flight", "planetary": "explore"}

# Field kinds: b bool, n finite number, i integer, s text.
const CLIMATE_FIELDS := {"T": "n", "S": "n", "ocean": "n", "steam": "n", "lost": "n", "ice": "n", "clouds": "n",
	"humidity": "n", "storm": "n", "ice_edge": "n", "snowball": "b", "wet": "b", "time": "n", "pending": "n",
	"escape_flux": "n", "_acc": "n"}
const STAGE_FIELDS := {"attached": "b", "prop": "n", "rcs_prop": "n", "ignited": "b", "spent": "b", "restarts": "i",
	"live": "i", "vac_live": "i", "gear_out": "b", "dropped_met": "n", "chuted": "b", "recession": "n", "ablated": "n",
	"shield_off": "b", "ballast_off": "b"}
const VESSEL_FIELDS := {"met": "n", "coord": "n", "t0": "n", "clock_delta": "n", "time_rate": "n", "throttle": "n",
	"rcs_on": "b", "speedbrake": "n", "auto_stage": "b", "cutoff_in": "n", "chute_deploy": "n", "bridle": "n",
	"max_q": "n", "max_q_t": "n", "max_q_alt": "n", "max_q_mach": "n", "max_mach": "n", "max_g": "n", "heat_load": "n",
	"peak_heat": "n", "downrange": "n", "dv_ideal": "n", "loss_gravity": "n", "loss_steering": "n", "loss_drag": "n",
	"stage_events": "i", "roll_signed": "b"}
## Phases a vessel can be put back in. Rollout and cruise carry state this does not keep.
const PHASES := ["prelaunch", "ascent", "coast", "orbit", "burn", "entry", "descent", "landed"]
## Programs that are not re-engaged on load: each starts something new rather than steering.
const NO_RESUME := ["catch", "cruise"]
const EVENTS_KEPT := 300
const TYPE_LABELS := {"star": ["star", "stars"], "white-dwarf": ["white dwarf", "white dwarfs"],
	"neutron": ["neutron star", "neutron stars"], "bh": ["black hole", "black holes"],
	"gas-giant": ["gas giant", "gas giants"], "rocky": ["rocky world", "rocky worlds"]}

# WHAT CAN BE SAVED

## The kind of game on the stage now, or "" when nothing on it saves.
static func kind_now(main) -> String:
	if main.at_start: return ""
	if main.flight != null and main.flight.active: return "spaceflight"
	var mode: String = main.state.app_mode
	if mode == "flight": return "spaceflight"
	if mode == "explore": return "planetary"
	# A showcase belongs to what opened it; one opened from a lesson or the Observatory saves nothing.
	if mode == "showcase": return {"explore": "planetary", "sandbox": "sandbox"}.get(main.showcase.came_from, "")
	if mode == "sandbox": return "sandbox"
	return ""

## "" when the stage can be saved as `kind` now, or why it cannot.
static func why_not(main, kind: String) -> String:
	if kind == "": return "Only Sandbox, Spaceflight and Planetary exploration games are saved."
	if main._loading: return "Wait for the scenario to finish loading."
	if main.galaxy.active: return "A galaxy scene cannot be saved yet."
	match kind:
		"spaceflight":
			var f = main.flight
			if not f.active or f.vessel == null: return "Choose a craft first: there is no flight to save."
			if main.voyager_replay != null: return "The Voyager replay is a recording, not a flight."
			if f.docking != null: return "A docking approach cannot be saved yet."
			if not f.kerr_demo.is_empty(): return "The Kerr orbit demonstration cannot be saved."
			if f.cruise != null: return "An interstellar cruise cannot be saved yet."
			if f.skip != null: return "Wait until the skip arrives."
			var v: Vessel = f.vessel
			if v.phase == Vessel.PHASE.DESTROYED: return "The vehicle was lost; there is nothing to save."
			if v.phase == Vessel.PHASE.ROLLOUT: return "Wait for the wheels to stop."
			if v.catch_tower != null: return "A booster coming home to its tower cannot be saved."
			if v.bridle > 0.0 and v.phase != Vessel.PHASE.LANDED: return "Wait until the Sky Crane has set down."
		"planetary":
			if not main.showcase.active or main.showcase.body == null: return "Choose a world to explore first."
	return ""

# CAPTURE

## {ok, error, state, summary, name}: the stage as a save of `kind`.
static func capture(main, kind: String) -> Dictionary:
	var why := why_not(main, kind)
	if why != "": return {"ok": false, "error": why}
	var state := {"world": capture_world(main)}
	var body_index := _body_index(main)
	if kind == "spaceflight": state.flight = capture_flight(main, body_index)
	elif kind == "planetary": state.explore = capture_explore(main, body_index)
	# What is written must read back: a body past a supported limit, say, is refused now.
	var err := validate(kind, state)
	if err != "": return {"ok": false, "error": "This scene cannot be saved: %s" % err}
	return {"ok": true, "error": "", "state": state, "summary": summary(main, kind, state), "name": default_name(kind, state)}

static func _body_index(main) -> Dictionary:
	var out := {}
	for b: Body in main.state.bodies:
		if b.alive: out[b.id] = out.size()
	return out

static func capture_world(main) -> Dictionary:
	var state: SimState = main.state
	var p: Dictionary = state.preset if state.preset is Dictionary else {}
	var scene := {"key": state.preset_key}
	for k in SCENE_KEYS:
		if p.get(k) != null: scene[k] = p[k]
	scene.name = str(p.get("name", "Empty space"))
	scene.sceneScale = state.scene_scale
	scene.bodyScale = state.body_scale
	if is_finite(state.epoch_jd): scene.epochJD = state.epoch_jd
	else: scene.erase("epochJD")
	var bodies := []
	for b: Body in state.bodies:
		if not b.alive: continue
		# The spec holds what the body's structure was last derived from, which can trail its
		# live mass, spin and age (main.check_structural_limits refreshes it past a margin);
		# the live values go beside it and are put back after the body is derived again.
		var st: Dictionary = b.structure
		var spec: Dictionary = b.spec.duplicate(true)
		spec.erase("orbit")
		spec.type = b.type
		spec.name = b.name
		spec.mass = float(st.mass) if st.get("mass") is float and float(st.mass) > 0.0 else b.mass
		spec.pos = b.pos.to_array()
		spec.vel = b.vel.to_array()
		if spec.get("spinHz") == null: spec.spinFrac = float(st.get("spinFrac", b.spin_frac))
		if b.type == "star" and b.phase != null: spec.phase = float(st.get("phaseF", b.phase))
		bodies.append({"spec": spec, "mass": b.mass, "spinFrac": b.spin_frac, "phase": b.phase, "mCheck": b.m_check,
			"mass0": b.mass0, "spinOmega": b.spin_omega, "spinTracked": b.spin_tracked,
			"spinPhase": b.spin_phase, "cloudPhase": b.cloud_phase, "dayLength": b.day_length, "extra": b.extra.duplicate(true),
			"climate": _climate_state(b.climate, b.home)})
	var index := _body_index(main)
	var paint := []
	for it in main.painter.items:
		if it.has_meta("save_spec"): paint.append({"spec": it.get_meta("save_spec"), "t": float(it.t)})
	# The Roche check's last sample of each pair: a periapsis passed between two checks is
	# found from it (main._check_tidal_limit), so a load without it can miss a disruption.
	var tides := []
	for key in main._tidal_rv:
		var ids: PackedStringArray = str(key).split(":")
		var i = index.get(int(ids[0])) if ids.size() == 2 else null
		var j = index.get(int(ids[1])) if ids.size() == 2 else null
		if i != null and j != null: tides.append([i, j, float(main._tidal_rv[key][0]), float(main._tidal_rv[key][1])])
	var cam = main.cam
	return {
		"scene": scene,
		"sky": state.sky.duplicate(true),
		"live": {"trueScale": state.true_scale, "timeScale": state.time_scale, "maxStep": state.max_step,
			"gwBoost": state.gw_boost, "discIntensity": state.disc_intensity, "discTemp": state.disc_temp,
			"lensing": state.lensing, "showLens": state.show_lens, "showMesh": state.show_mesh,
			"spawnAtRest": state.spawn_at_rest, "speed": state.speed, "paused": state.paused,
			"simYears": state.sim_years, "yearRemainder": state.year_remainder, "consumed": state.consumed,
			"pinOnFocus": state.pin_on_focus, "climateTurn": main._climate_frame},
		"bodies": bodies,
		"paint": paint,
		"tides": tides,
		"camera": {"mode": state.cam_mode if state.cam_mode in ["orbit", "free"] else "orbit",
			"theta": cam.theta, "phi": cam.phi, "radius": cam.radius, "yaw": cam.yaw, "pitch": cam.pitch,
			"roll": cam.roll, "target": cam.target.to_array(), "offset": cam.offset.to_array(),
			"pos": main.cam_pos.to_array(), "freeSpeed": cam.free_speed,
			"follow": index.get(state.follow_id, -1), "focus": index.get(state.focus_id, -1)},
	}

static func _climate_state(cl: Climate, home: bool) -> Variant:
	if cl == null: return null
	var out := {}
	for k in CLIMATE_FIELDS: out[k] = cl.get(k)
	out.ebm = Array(cl.ebm.T)
	out.extremes = cl.extremes.duplicate()
	out.history = cl.history.duplicate(true)
	if not home: out.drawn = cl.drawn.duplicate()
	return out

static func capture_flight(main, body_index: Dictionary) -> Dictionary:
	var f = main.flight
	var v: Vessel = f.vessel
	var out := {"vehicle": v.vehicle_key, "stageKeys": v.stages.map(func(st): return str(st.spec.key)),
		"parent": body_index.get(v.parent.id, -1), "phase": v.phase}
	if v.phase == Vessel.PHASE.PRELAUNCH:
		# On the pad the save is the vehicle and the world; the count starts again.
		out.pad = true
		return out
	out.pad = false
	out.r = v.r.to_array(); out.v = v.v.to_array(); out.omega = v.omega.to_array()
	out.q = [v.q.x, v.q.y, v.q.z, v.q.w]
	for k in VESSEL_FIELDS: out[k] = v.get(k)
	out.bank = v.bank
	out.landedAt = v.landed_at.duplicate() if v.landed_at is Dictionary else null
	out.chute = v.chute_open.duplicate() if v.chute_open is Dictionary else null
	out.logged = v._logged.keys()
	var site = v.launch_site
	out.site = null if site == null else {"lat": float(site.lat), "lon": float(site.lon), "r": site.r.to_array(),
		"v": site.v.to_array(), "r0": site.r0.to_array(), "coord0": float(site.coord0),
		"body": body_index.get(v._launch_parent.id, -1) if v._launch_parent != null else -1}
	out.stages = []
	for st in v.stages:
		var s := {}
		for k in STAGE_FIELDS: s[k] = st.get(k)
		out.stages.append(s)
	out.events = v.events.slice(maxi(v.events.size() - EVENTS_KEPT, 0)).map(func(e): return {"t": float(e.t), "msg": str(e.msg)})
	var ap = f.autopilot
	out.program = ap.program if ap != null and ap.program != null and str(ap.program) not in NO_RESUME else null
	out.apMode = str(ap.mode) if ap != null else "off"
	var m = f.mission
	out.mission = {"dest": body_index.get(m.dest.id, -1), "goal": str(m.goal)} \
		if m != null and not m.done and m.failed == "" and m.dest != null and m.dest.alive else null
	out.target = body_index.get(f.target.id, -1) if f.target != null else -1
	out.camera = f.camera_mode()
	return out

static func capture_explore(main, body_index: Dictionary) -> Dictionary:
	var sc: Showcase = main.showcase
	return {"body": body_index.get(sc.body.id, -1), "pin": sc.pin.n if sc.pin != null else 0, "pinPending": sc._pending_drop,
		"standing": sc.visit != null}

# DESCRIPTION

## One line for the save list: what the scene is and where it stands.
static func summary(main, kind: String, state: Dictionary) -> String:
	var world: Dictionary = state.world
	var bodies: Array = world.bodies
	match kind:
		"spaceflight":
			var fl: Dictionary = state.flight
			var parent := _name_at(bodies, int(fl.parent))
			var veh := str(Vehicles.VEHICLES.get(fl.vehicle, {}).get("name", fl.vehicle))
			if fl.pad: return "%s on the pad · %s" % [veh, parent]
			var v: Vessel = main.flight.vessel
			var where := "landed on %s" % parent if fl.phase == Vessel.PHASE.LANDED \
				else "%s at %s, %s up" % [str(fl.phase), parent, FlightUI.fmt_dist(maxf(v.altitude(), 0.0))]
			return "%s · %s · T+ %s" % [veh, where, Guidance.fmt_dur(maxf(float(fl.met) - float(fl.t0), 0.0))]
		"planetary":
			var ex: Dictionary = state.explore
			var pin := (" · pin %d" % int(ex.pin)) if int(ex.pin) > 0 else ""
			return "%s%s · %s · %s" % [_name_at(bodies, int(ex.body)), pin, "on the surface" if ex.standing else "from orbit",
				str(world.scene.name)]
	return "%s · %s · %s in" % [str(world.scene.name), body_counts(bodies), _fmt_years(float(world.live.simYears))]

static func default_name(kind: String, state: Dictionary) -> String:
	var bodies: Array = state.world.bodies
	match kind:
		"spaceflight":
			var fl: Dictionary = state.flight
			var veh := str(Vehicles.VEHICLES.get(fl.vehicle, {}).get("name", fl.vehicle))
			return ("%s at %s" % [veh, _name_at(bodies, int(fl.parent))]).left(SaveStore.NAME_MAX)
		"planetary":
			var ex: Dictionary = state.explore
			var pin := (", pin %d" % int(ex.pin)) if int(ex.pin) > 0 else ""
			return ("%s%s" % [_name_at(bodies, int(ex.body)), pin]).left(SaveStore.NAME_MAX)
	return str(state.world.scene.name).left(SaveStore.NAME_MAX)

## "1 star, 8 planets": what a world holds, by kind.
static func body_counts(bodies: Array) -> String:
	if bodies.is_empty(): return "no bodies"
	var n := {}
	for e in bodies:
		var t := str(e.spec.type)
		if t in ["planet", "world"]: t = "rocky"
		n[t] = int(n.get(t, 0)) + 1
	var parts := []
	for t in ["star", "white-dwarf", "neutron", "bh", "gas-giant", "rocky"]:
		if n.has(t): parts.append("%d %s" % [n[t], TYPE_LABELS[t][0] if n[t] == 1 else TYPE_LABELS[t][1]])
	return ", ".join(parts)

static func _fmt_years(y: float) -> String:
	if y < 1.0: return "%s d" % U.fixed(y * 365.25, 1)
	if y < 1000.0: return "%s yr" % U.fixed(y, 2)
	return "%s kyr" % U.fixed(y / 1000.0, 2)

static func _name_at(bodies: Array, i: int) -> String:
	return str(bodies[i].spec.name) if i >= 0 and i < bodies.size() else "?"

# VALIDATION: everything a restore reads, before it changes anything.

## "" or what makes `state` unfit to load as `kind`.
static func validate(kind: String, state: Dictionary) -> String:
	if not SaveStore.KINDS.has(kind): return "unknown save kind %s." % kind
	var allowed := ["world"]
	if kind == "spaceflight": allowed.append("flight")
	if kind == "planetary": allowed.append("explore")
	for k in state:
		if k not in allowed: return "unknown section \"%s\"." % str(k)
	for k in allowed:
		if not state.get(k) is Dictionary: return "the %s section is missing." % k
	var err := _world_error(state.world)
	if err != "": return err
	var bodies: Array = state.world.bodies
	if kind == "spaceflight": return _flight_error(state.flight, bodies)
	if kind == "planetary": return _explore_error(state.explore, bodies)
	return ""

static func _num(v) -> bool:
	return (v is float or v is int) and is_finite(float(v))

static func _vec(v, n := 3) -> bool:
	if not v is Array or (v as Array).size() != n: return false
	for x in v:
		if not _num(x): return false
	return true

static func _field_error(d: Dictionary, fields: Dictionary, at: String) -> String:
	for k in fields:
		if not d.has(k): return "%s has no %s." % [at, k]
		var v = d[k]
		match fields[k]:
			"b": if not v is bool: return "%s.%s must be true or false." % [at, k]
			"n": if not _num(v): return "%s.%s must be a finite number." % [at, k]
			"i": if not (v is int or (v is float and is_finite(v) and v == floorf(v))): return "%s.%s must be a whole number." % [at, k]
			"s": if not v is String: return "%s.%s must be text." % [at, k]
	return ""

static func _world_error(w: Dictionary) -> String:
	for k in ["scene", "sky", "live", "bodies", "paint", "tides", "camera"]:
		if not w.has(k): return "the world has no %s." % k
	for k in w:
		if k not in ["scene", "sky", "live", "bodies", "paint", "tides", "camera"]: return "the world has an unknown field \"%s\"." % str(k)
	var scene = w.scene
	if not scene is Dictionary: return "the scene is not a dictionary."
	for k in scene:
		if k != "key" and k not in SCENE_KEYS: return "the scene has an unknown field \"%s\"." % str(k)
	if not scene.get("key") is String or not scene.get("name") is String: return "the scene has no name."
	var present := {}
	for k in SCENE_KINDS:
		if scene.has(k): present[k] = SCENE_KINDS[k]
	var kinds_err := _field_error(scene, present, "scene")
	if kinds_err != "": return kinds_err
	for k in ["sceneScale", "bodyScale"]:
		if not _num(scene.get(k)) or float(scene[k]) <= 0.0: return "the scene's %s must be a positive number." % k
	if scene.has("camRadius") and (not _num(scene.camRadius) or float(scene.camRadius) < OrreryCamera.MIN_REQUEST_RADIUS \
			or float(scene.camRadius) > OrreryCamera.MAX_REQUEST_RADIUS):
		return "the scene's camera distance is out of range."
	for k in ["timeScale", "maxStep", "gwBoost", "discIntensity", "discOuter", "epochJD"]:
		if scene.has(k) and not _num(scene[k]): return "the scene's %s must be a finite number." % k
	var sky_error := SkyModel.request_error(w.sky)
	if sky_error != "": return "the sky: %s" % sky_error
	var live = w.live
	if not live is Dictionary: return "the live settings are missing."
	var err := _field_error(live, {"trueScale": "b", "timeScale": "n", "maxStep": "n", "gwBoost": "n", "discIntensity": "n",
		"discTemp": "n", "lensing": "b", "showLens": "b", "showMesh": "b", "spawnAtRest": "b", "speed": "n", "paused": "b",
		"simYears": "n", "yearRemainder": "n", "consumed": "i", "pinOnFocus": "b", "climateTurn": "i"}, "live")
	if err != "": return err
	if float(live.timeScale) <= 0.0 or float(live.maxStep) <= 0.0: return "the time scale and step must be positive."
	var bodies = w.bodies
	if not bodies is Array: return "the bodies are not a list."
	if bodies.size() > ScenarioFile.MAX_BODIES: return "more than %d bodies." % ScenarioFile.MAX_BODIES
	var names := {}
	for i in bodies.size():
		var e = bodies[i]
		var at := "body %d" % (i + 1)
		if not e is Dictionary or not e.get("spec") is Dictionary: return "%s has no spec." % at
		err = _field_error(e, {"mass": "n", "spinFrac": "n", "mass0": "n", "spinOmega": "n", "spinTracked": "b",
			"spinPhase": "n", "cloudPhase": "n", "dayLength": "n"}, at)
		if err != "": return err
		if float(e.mass) <= 0.0 or float(e.spinFrac) < 0.0: return "%s has a mass or spin out of range." % at
		if not e.has("phase") or (e.phase != null and not _num(e.phase)): return "%s has no phase, or one that is not a number." % at
		if e.get("mCheck") != null and not _num(e.mCheck): return "%s has a structural memo that is not a number." % at
		if not e.get("extra") is Dictionary: return "%s.extra must be a dictionary." % at
		var spec: Dictionary = e.spec
		if not spec.get("name") is String: return "%s has no name." % at
		at = "%s (%s)" % [at, spec.name]
		if not spec.get("type") is String or spec.type not in ScenarioFile.TYPES: return "%s has an unknown type." % at
		if not _vec(spec.get("pos")) or not _vec(spec.get("vel")): return "%s needs a finite position and velocity." % at
		var reason := Structure.input_error(spec)
		if reason != "": return "%s: %s" % [at, reason]
		if e.get("climate") != null:
			err = _climate_error(e.climate, at)
			if err != "": return err
		names[spec.name] = true
	var paint = w.paint
	if not paint is Array: return "the painted decorations are not a list."
	for i in paint.size():
		var it = paint[i]
		if not it is Dictionary or not it.get("spec") is Dictionary or not _num(it.get("t")) or float(it.t) < 0.0:
			return "painted decoration %d is malformed." % (i + 1)
		var ps: Dictionary = it.spec
		if ps.get("kind") not in ["ring", "belt", "cloud"]: return "painted decoration %d has an unknown kind." % (i + 1)
		if ps.get("body") != null and (not ps.body is String or not names.has(ps.body)):
			return "painted decoration %d is on a body that is not saved." % (i + 1)
		if ps.get("label") != null and not ps.label is String: return "painted decoration %d has a label that is not text." % (i + 1)
		if ps.get("centralMass") != null and (not _num(ps.centralMass) or float(ps.centralMass) <= 0.0):
			return "painted decoration %d orbits a mass that is not positive." % (i + 1)
		for k in ps:
			if k not in ["kind", "body", "label"] and ps[k] != null and not _num(ps[k]):
				return "painted decoration %d has a non-numeric %s." % [i + 1, k]
	if not w.tides is Array: return "the tidal samples are not a list."
	for row in w.tides:
		if not _vec(row, 4) or row[0] != floorf(row[0]) or row[1] != floorf(row[1]) \
				or int(row[0]) < 0 or int(row[0]) >= bodies.size() or int(row[1]) < 0 or int(row[1]) >= bodies.size():
			return "a tidal sample is malformed."
	var c = w.camera
	if not c is Dictionary: return "the camera is missing."
	err = _field_error(c, {"theta": "n", "phi": "n", "radius": "n", "yaw": "n", "pitch": "n", "roll": "n",
		"freeSpeed": "n", "follow": "i", "focus": "i", "mode": "s"}, "camera")
	if err != "": return err
	if c.mode not in ["orbit", "free"]: return "the camera mode is unknown."
	if float(c.radius) <= 0.0: return "the camera distance must be positive."
	for k in ["target", "offset", "pos"]:
		if not _vec(c.get(k)): return "the camera's %s must be three finite numbers." % k
	for k in ["follow", "focus"]:
		if int(c[k]) < -1 or int(c[k]) >= bodies.size(): return "the camera's %s names no saved body." % k
	return ""

static func _climate_error(c, at: String) -> String:
	if not c is Dictionary: return "%s: the climate is malformed." % at
	var err := _field_error(c, CLIMATE_FIELDS, "%s climate" % at)
	if err != "": return err
	if not c.get("ebm") is Array or (c.ebm as Array).is_empty() or not _vec(c.ebm, (c.ebm as Array).size()):
		return "%s: the climate's latitude profile is malformed." % at
	if not c.get("extremes") is Dictionary or not c.get("history") is Array: return "%s: the climate's record is malformed." % at
	for row in c.history:
		if not _vec(row, 3): return "%s: the climate's history is malformed." % at
	if c.has("drawn"):
		var d = c.drawn
		if not d is Dictionary: return "%s: the drawn climate inputs are malformed." % at
		for k in ["mixedLayer", "albedoBase", "albedoIce", "land", "oceanDepth", "salinity"] + Atmosphere.GASES.keys():
			if not _num(d.get(k)): return "%s: the drawn climate input %s is missing." % [at, k]
		if not d.get("oceans") is bool: return "%s: the drawn climate input oceans is missing." % at
	return ""

static func _flight_error(fl: Dictionary, bodies: Array) -> String:
	var err := _field_error(fl, {"vehicle": "s", "parent": "i", "phase": "s"}, "flight")
	if err != "": return err
	if not Vehicles.VEHICLES.has(fl.vehicle): return "there is no vehicle \"%s\"." % fl.vehicle
	if not fl.get("pad") is bool: return "the flight does not say whether it is on the pad."
	var p := int(fl.parent)
	if p < 0 or p >= bodies.size(): return "the vessel's parent body is not saved."
	if str(bodies[p].spec.type) == "bh": return "a flight about a black hole cannot be loaded."
	var keys = fl.get("stageKeys")
	if not keys is Array or keys.is_empty(): return "the vehicle's stages are missing."
	if vehicle_for(str(fl.vehicle), keys) == null: return "the saved stages do not match %s." % fl.vehicle
	if fl.phase not in PHASES: return "a vessel cannot be put back in phase \"%s\"." % fl.phase
	if fl.pad != (fl.phase == Vessel.PHASE.PRELAUNCH): return "the flight's pad flag and its phase disagree."
	if fl.pad: return ""
	for k in ["bank", "landedAt", "chute", "site", "program", "mission"]:
		if not fl.has(k): return "the flight has no %s." % k
	for k in ["r", "v", "omega"]:
		if not _vec(fl.get(k)): return "the vessel's %s must be three finite numbers." % k
	if not _vec(fl.get("q"), 4): return "the vessel's attitude is malformed."
	var ql := Vector4(fl.q[0], fl.q[1], fl.q[2], fl.q[3]).length()
	if absf(ql - 1.0) > 1e-6: return "the vessel's attitude is not a rotation."
	err = _field_error(fl, VESSEL_FIELDS, "flight")
	if err != "": return err
	if float(fl.throttle) < 0.0 or float(fl.throttle) > 1.0: return "the throttle is out of range."
	if fl.get("bank") != null and not _num(fl.bank): return "the bank angle must be a number."
	for k in ["landedAt", "chute"]:
		var d = fl.get(k)
		if d == null: continue
		if not d is Dictionary: return "the vessel's %s is malformed." % k
		for x in d:
			if not _num(d[x]): return "the vessel's %s.%s must be a number." % [k, x]
	if not fl.get("logged") is Array: return "the milestone log is malformed."
	var site = fl.get("site")
	if site != null:
		if not site is Dictionary or not _num(site.get("lat")) or not _num(site.get("lon")) or not _num(site.get("coord0")) \
				or not _num(site.get("body")) or int(site.body) < -1 or int(site.body) >= bodies.size():
			return "the launch site is malformed."
		for k in ["r", "v", "r0"]:
			if not _vec(site.get(k)): return "the launch site's %s is malformed." % k
	var stages = fl.get("stages")
	if not stages is Array or stages.size() != keys.size(): return "the stage states do not match the vehicle."
	var any_attached := false
	for i in stages.size():
		if not stages[i] is Dictionary: return "stage %d is malformed." % (i + 1)
		err = _field_error(stages[i], STAGE_FIELDS, "stage %d" % (i + 1))
		if err != "": return err
		if float(stages[i].prop) < 0.0 or float(stages[i].rcs_prop) < 0.0: return "stage %d has negative propellant." % (i + 1)
		any_attached = any_attached or stages[i].attached
	if not any_attached: return "no stage is attached."
	var events = fl.get("events")
	if not events is Array: return "the flight log is malformed."
	for e in events:
		if not e is Dictionary or not _num(e.get("t")) or not e.get("msg") is String: return "the flight log is malformed."
	if fl.get("program") != null and (not fl.program is String or fl.program in NO_RESUME): return "the autopilot program is malformed."
	if not fl.get("apMode") is String or fl.apMode not in Guidance.MODE.values(): return "the autopilot mode is unknown."
	var m = fl.get("mission")
	if m != null:
		if not m is Dictionary or not _num(m.get("dest")) or not m.get("goal") is String: return "the mission is malformed."
		if int(m.dest) < 0 or int(m.dest) >= bodies.size(): return "the mission's destination is not saved."
	if not _num(fl.get("target")) or int(fl.target) < -1 or int(fl.target) >= bodies.size(): return "the target is not saved."
	if not fl.get("camera") is String: return "the flight camera is malformed."
	return ""

static func _explore_error(ex: Dictionary, bodies: Array) -> String:
	var err := _field_error(ex, {"body": "i", "pin": "i", "pinPending": "b", "standing": "b"}, "exploration")
	if err != "": return err
	var i := int(ex.body)
	if i < 0 or i >= bodies.size(): return "the explored world is not saved."
	if not ClimateInputs.applies(str(bodies[i].spec.type)): return "%s has no surface to explore." % bodies[i].spec.name
	if int(ex.pin) < 0 or int(ex.pin) > 100000: return "the pin number is out of range."
	if ex.standing and int(ex.pin) < 1: return "standing needs a pin."
	return ""

## The vehicle the saved stages fly: the catalogue's, or a subset of its stages by key.
static func vehicle_for(key: String, stage_keys: Array):
	var veh = Vehicles.VEHICLES.get(key)
	if veh == null: return null
	var have: Array = veh.stages.map(func(s): return str(s.key))
	if have == stage_keys: return veh
	var picked := []
	for k in stage_keys:
		var i := have.find(str(k))
		if i < 0: return null
		picked.append(veh.stages[i])
	var out: Dictionary = veh.duplicate(false)
	out.stages = picked
	return out

# RESTORE

## Put a validated world on the stage, replacing what is there.
static func restore_world(main, w: Dictionary) -> void:
	var state: SimState = main.state
	var scene: Dictionary = w.scene
	var specs := []
	for e in w.bodies: specs.append((e.spec as Dictionary).duplicate(true))
	var p: Dictionary = scene.duplicate(true)
	p.erase("key")
	p.sky = (w.sky as Dictionary).duplicate(true)
	if not p.has("camRadius"): p.camRadius = float(w.camera.radius)
	p.build = func() -> Array: return specs
	main.load_preset_spec(str(scene.key), p)
	var live: Dictionary = w.live
	if bool(live.trueScale) != state.true_scale: main.set_true_scale(bool(live.trueScale))
	state.max_step = float(live.maxStep)
	state.gw_boost = float(live.gwBoost)
	main.sync_sim_controls()
	state.disc_intensity = float(live.discIntensity)
	state.disc_temp = float(live.discTemp)
	main.hud.set_slider("disc", state.disc_intensity, U.fixed(state.disc_intensity, 2))
	state.lensing = bool(live.lensing)
	state.show_lens = bool(live.showLens)
	main.hud.set_active("[data-view=lens]", state.show_lens)
	main.hud.set_button_text("[data-view=lens]", "Lens ON" if state.show_lens else "Lens OFF")
	main.toggle_mesh(bool(live.showMesh))
	main.set_spawn_at_rest(bool(live.spawnAtRest))
	main.set_time_scale(float(live.timeScale))
	state.speed = float(live.speed)
	state.paused = bool(live.paused)
	state.consumed = int(live.consumed)
	if bool(live.pinOnFocus) != state.pin_on_focus: main._on_showcase_action("auto")
	state.sim_years = float(live.simYears)
	state.year_remainder = float(live.yearRemainder)
	# Which worlds' climates step on the next frame (main._step_climate takes turns).
	main._climate_frame = int(live.climateTurn)
	for i in w.bodies.size():
		_restore_body(main, state.bodies[i], w.bodies[i])
	for it in w.paint:
		var item = main.apply_paint_spec(it.spec)
		if item != null and float(it.t) > 0.0: item.update(float(it.t), state.scene_scale)
	main._tidal_rv.clear()
	for row in w.tides:
		main._tidal_rv["%d:%d" % [state.bodies[int(row[0])].id, state.bodies[int(row[1])].id]] = [float(row[2]), float(row[3])]
	main.update_suns()
	_restore_camera(main, w.camera)
	var home: Body = main.get_home()
	if home: main.hud.set_slider("daylen", home.day_length * 365.25, "%s d" % U.fixed(home.day_length * 365.25, 1))
	main._preset_clean = false
	state.energy0 = null
	main.refresh_ui()

static func _restore_body(main, b: Body, e: Dictionary) -> void:
	b.mass = float(e.mass)
	b.spin_frac = float(e.spinFrac)
	if e.phase != null: b.phase = float(e.phase)
	# When the structure was last checked, so it is re-derived when the original's would be.
	b.m_check = float(e.mCheck) if e.get("mCheck") != null else null
	b.spin_omega = float(e.spinOmega)
	b.spin_tracked = bool(e.spinTracked)
	b.tide_k2 = float(b.structure.get("secular", {}).get("k2", 0.0)) if b.spin_tracked else 0.0
	b.spin_phase = float(e.spinPhase)
	b.cloud_phase = float(e.cloudPhase)
	# The Day length slider sets this directly, not through the spec.
	b.day_length = float(e.dayLength)
	b.extra = (e.extra as Dictionary).duplicate(true)
	if float(e.mass0) != b.mass0:
		b.mass0 = float(e.mass0)
		main.detach_visual(b)
		main.attach_visual(b)
	var c = e.get("climate")
	if c == null or b.climate == null: return
	var cl: Climate = b.climate
	if c.has("drawn") and not b.home:
		cl.drawn = (c.drawn as Dictionary).duplicate()
		cl.wet = bool(c.wet)
		cl.apply_inputs(ClimateInputs.stated(b.spec))
	for k in CLIMATE_FIELDS: cl.set(k, c[k])
	if cl.ebm.T.size() == c.ebm.size(): cl.ebm.T = PackedFloat64Array(c.ebm)
	var ex: Dictionary = c.extremes
	cl.extremes = {"Tmin": float(ex.get("Tmin", cl.T)), "Tmax": float(ex.get("Tmax", cl.T)),
		"Smin": float(ex.get("Smin", INF)), "Smax": float(ex.get("Smax", -INF))}
	cl.history = (c.history as Array).duplicate(true)
	cl.era = cl.classify(cl.T)
	cl._refresh_sky()
	var v = b.viz.inner if b.viz is Bodies.AccretionWrap else b.viz
	if v != null and v.has_method("snap_climate"): v.snap_climate()

static func _restore_camera(main, c: Dictionary) -> void:
	var state: SimState = main.state
	var cam = main.cam
	var bodies: Array = state.bodies
	var follow: Body = bodies[int(c.follow)] if int(c.follow) >= 0 else null
	var focus: Body = bodies[int(c.focus)] if int(c.focus) >= 0 else null
	state.follow_id = follow.id if follow != null else null
	state.focus_id = focus.id if focus != null else null
	main.set_cam_mode(str(c.mode))
	cam.theta = float(c.theta); cam.phi = float(c.phi)
	cam.yaw = float(c.yaw); cam.pitch = float(c.pitch); cam.roll = float(c.roll)
	cam.free_speed = float(c.freeSpeed)
	main.jump_cam_radius(float(c.radius))
	cam.target.copy_from(DVec3.from_array(c.target))
	cam.offset.copy_from(DVec3.from_array(c.offset))
	main.cam_pos.copy_from(DVec3.from_array(c.pos))
	if state.cam_mode == "orbit": main.update_orbit_cam()

## Build the saved vessel on the restored world. Returns "" or why it could not fly.
static func restore_flight(main, fl: Dictionary) -> String:
	var f = main.flight
	var state: SimState = main.state
	var key := str(fl.vehicle)
	var parent: Body = state.bodies[int(fl.parent)]
	await CraftAssets.craft_models_ready([key])
	var veh = vehicle_for(key, fl.stageKeys)
	var v: Vessel
	if fl.pad:
		v = f.begin(key, {"mode": "pad", "body": parent.name, "vehicle": veh})
	else:
		v = f.begin(key, {"mode": "orbit", "body": parent.name, "vehicle": veh, "alt": 250e3, "phase": 0.0})
	if v == null: return "%s cannot fly from %s." % [str(veh.name), parent.name]
	if v.parent != parent: v.set_parent(parent, f.bodies())
	if not fl.pad:
		v.r.copy_from(DVec3.from_array(fl.r))
		v.v.copy_from(DVec3.from_array(fl.v))
		v.omega.copy_from(DVec3.from_array(fl.omega))
		v.q.set_q(float(fl.q[0]), float(fl.q[1]), float(fl.q[2]), float(fl.q[3]))
		v.phase = str(fl.phase)
		for k in VESSEL_FIELDS: v.set(k, fl[k])
		v.bank = fl.bank
		v.landed_at = (fl.landedAt as Dictionary).duplicate() if fl.landedAt is Dictionary else null
		v.chute_open = (fl.chute as Dictionary).duplicate() if fl.chute is Dictionary else null
		v._logged = {}
		for k in fl.logged: v._logged[str(k)] = true
		if fl.site is Dictionary:
			v.launch_site = {"lat": float(fl.site.lat), "lon": float(fl.site.lon), "r": DVec3.from_array(fl.site.r),
				"v": DVec3.from_array(fl.site.v), "r0": DVec3.from_array(fl.site.r0), "coord0": float(fl.site.coord0)}
			v._launch_parent = state.bodies[int(fl.site.body)] if int(fl.site.body) >= 0 else null
		for i in v.stages.size():
			for k in STAGE_FIELDS: v.stages[i].set(k, fl.stages[i][k])
		v._find_stage_index()
		v.events = (fl.events as Array).map(func(e): return {"t": float(e.t), "msg": str(e.msg)})
		# Gone before the load, so nothing separates on the first frame.
		if f.craft != null:
			for st in v.stages:
				var cs = f.craft.stage(str(st.spec.key))
				if not st.attached and cs != null: cs.group.visible = false
		f.planet_spin = 0.0
		DQuat.set_len(f.anchor_pos.copy_from(v.r), v.surface_r(v.r))
		var up := DQuat.nrm(v.r.clone()).to_v3()
		f.wind_dir = Vector3(0, -1, 0).cross(up).normalized() if absf(up.y) < 0.999 else Vector3(1, 0, 0)
		f.autopilot.mode = str(fl.apMode)
		if fl.program != null: f.run_program(str(fl.program))
		var m = fl.mission
		if m is Dictionary: f.start_mission(state.bodies[int(m.dest)].name, str(m.goal))
		if int(fl.target) >= 0: f.set_target(state.bodies[int(fl.target)].name)
		f.refresh_targets()
		# Down on a mapped world: survey the same ground it stood on.
		if v.phase in [Vessel.PHASE.LANDED, Vessel.PHASE.DESCENT]: v.request_ground(v.r)
		v.sample(0.0)
		v.log_event("Loaded from a save")
	f.set_warp(0)
	f.set_camera_mode(str(fl.get("camera", "chase")) if not fl.pad else "pad")
	return ""

## Stand where the save stood: the world in full focus, its pin, and the ground if it was stood on.
static func restore_explore(main, ex: Dictionary) -> void:
	var sc: Showcase = main.showcase
	var b: Body = main.state.bodies[int(ex.body)]
	main.enter_world(b)
	# A pin still to drop once the camera settles, as it was at the save, and no other.
	sc._pending_drop = bool(ex.pinPending) and int(ex.pin) == 0
	if int(ex.pin) > 0:
		sc.pins_dropped = int(ex.pin) - 1
		sc.drop_pin()
	if ex.standing: sc.stand()
