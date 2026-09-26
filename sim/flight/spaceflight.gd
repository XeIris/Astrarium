class_name Spaceflight
extends RefCounted

# ============================================================================
# SPACEFLIGHT — the integration layer (port of sim/flight/spaceflight.js)
# ----------------------------------------------------------------------------
# This is the only file in sim/flight/ that knows about the orrery. Everything
# under it is pure: given a vehicle, a body and a state it produces numbers, and
# none of it reaches into main.gd or for a global.
#
# THE TWO CLOCKS PROBLEM, and how it is resolved. The orrery runs on
# simulated YEARS per real second (0.35 by default — a day and a half a second)
# and a rocket runs on seconds. Rather than let two clocks drift, entering
# flight takes over `state.time_scale` and drives it from the flight warp:
#
#     state.time_scale = warp / YR_S       (years per second)
#
# so at 1× the planets advance one second per second, at 10⁵× they advance a
# day per second, and there is only ever ONE clock moving the world.
#
# THE TWO SPACES PROBLEM. See sim/flight/localview.gd — the vehicle is drawn in
# its own metre-scale pass and composited over the orrery's frame.
#
# GODOT NOTES
#   · There is no renderLocal(): render/pipeline.gd draws pipe.local_vp itself
#     whenever the orchestrator has it in Mode.FLIGHT. What this file does each
#     frame is PLACE the local camera (pipe.local_cam, at the origin — see
#     localview.gd's floating origin) and every local object relative to it.
#   · THE ORRERY CAMERA IS SLAVED under main.gd's floating origin. The web
#     build wrote camera.position/quaternion/fov; here update() writes
#     main.cam_pos (a DVec3, absolute scene units — computed in DOUBLE as
#     parent.scene_pos + r·sceneScale/AU_M + (the local camera's offset from
#     the vehicle, rotated out of the local frame)·sceneScale/AU_M),
#     main.cam_basis, main.cam_fov and main.cam_near (0.01 — see update_visual).
#   · `boost` is a Vector3 β for SkyModel.apply_sky_boost (main.gd applies it).
#   · Input arrives as Godot events: key(e: InputEventKey) maps the JS e.code
#     names to physical keycodes; wheel(delta_y) takes the browser's deltaY
#     (main.gd converts a wheel notch to ~100); drag(dx, dy) is unchanged.
#   · The HUD (sim/flight/flightui.gd) is mounted into ctx.panel. planHTML /
#     cruiseHTML became FlightUI.plan_block / cruise_block, which return data.
# ============================================================================

const WARPS := [1, 2, 5, 10, 50, 100, 1000, 10000, 100000, 1000000]
const EARTH_PADS := {
	# NASA's SpaceX Starship environmental assessment lists these coordinates
	# for the Texas launch site and Kennedy's Pad 39A, respectively.
	"starship": {"lat": 25.99684, "lon": -97.15523},
	"default": {"lat": 28.608402, "lon": -80.604201},
}

# ----------------------------------------------------------------------------
# THE TERMINAL COUNT
# ----------------------------------------------------------------------------
# The last ten seconds of a real count, with the events at the times they
# really happen. The lead is the vehicle's own: a Saturn V starts its F-1s at
# T−8.9 s and does not release until they have been running long enough to
# prove themselves, a Shuttle starts the SSMEs at T−6.6 s and lights the
# solids at T−0 (they cannot be shut down, so they go last), and Falcon 9 and
# Starship start at T−3.
#
# This is not ceremony. Watching a vehicle sit still with its engines running
# and then move is what tells you the clock is real; the ignition transient
# is the only part of a launch where something changes fast enough to see.
const IGNITION_LEAD := {"saturnv": 8.9, "shuttle": 6.6, "falcon9": 3.0, "starship": 3.0}

var pipe: RenderPipeline
var state: SimState
var main = null                   # the orchestrator: cam_pos / cam_basis / cam_fov are written
var panel: Control = null
var toast_cb = null               # Callable(msg) or null

var local: LocalView
var fly_cam: LocalView.FlightCamera
var smoke: Plume.SmokeColumn
var rcs_puffs: Plume.RCSPuffs

var vessel: Vessel = null
var autopilot = null              # Guidance.Autopilot (JS: `ap`)
var craft = null                  # CraftModel.Craft
var plumes: Array = []            # Plume.PlumeFx
var entry = null                  # Plume.EntryGlow
var cruise = null                 # Relativity.Cruise
var site = null                   # LaunchSite
var site_pos = null               # DVec3: the pad, in the vessel's parent frame, m
var map_site = null               # {lat, lon} of the mapped geography
var pad_fire = null               # Plume.GroundFlame — the deflected exhaust
var plume_reach := 0.0            # how far the first stage's jet carries, m
# The terminal count. A launch has a beginning, and without one the vehicle
# simply is not on the pad and then is, which is most of why an ascent that
# runs in real time can still read as instantaneous.
var count = null
var saved_speed = null            # the orrery's own speed multiplier, parked for the flight
var warp_idx := 0
var active := false
var hud: FlightUI = null
var target: Body = null
var plan = null
## Relativistic aberration of the sky, β as a vector (zero outside cruise).
var boost := Vector3.ZERO
var _boost_d := DVec3.new()

var pad_offset := Vector3.ZERO
var pad_aimed := false
var craft_pos := DVec3.new()      # the vehicle in the local frame: (0, alt, 0)
var ground_pos := DVec3.new()     # the ground patch's own offset (0, −gradeDrop, 0)
var site_local := DVec3.new()     # the complex in the local frame
var origin_pos := DVec3.new()     # (0, 0, 0): the sky dome and the smoke
var frame_basis := Basis()        # local → world (columns east, up, north)

## The vehicle picker's list: {key, ...the vehicle Dictionary} in display order.
var vehicles: Array = []
var warp_list := WARPS
var local_camera: Camera3D
## A console handle on local space, in the same spirit as window.SIM.
var local_view: LocalView

var _q := DQuat.new()
var _a := DVec3.new()
var _b := DVec3.new()

static func create_spaceflight(ctx: Dictionary) -> Spaceflight:
	return Spaceflight.new(ctx)

func _init(ctx: Dictionary) -> void:
	pipe = ctx.pipe
	state = ctx.state
	main = ctx.get("main")
	panel = ctx.get("panel")
	toast_cb = ctx.get("toast")
	local = LocalView.create_local_view(pipe)
	local_view = local
	local_camera = local.camera
	fly_cam = LocalView.create_flight_camera()
	smoke = Plume.create_smoke_column()
	local.root.add_child(smoke.group)
	local.place(smoke.group, origin_pos)
	rcs_puffs = Plume.create_rcs_puffs()
	local.root.add_child(rcs_puffs.group)
	local.place(rcs_puffs.group, origin_pos)
	for k in Vehicles.VEHICLE_ORDER:
		var v: Dictionary = Vehicles.VEHICLES[k].duplicate()
		v["key"] = k
		vehicles.append(v)
	if panel != null:
		hud = FlightUI.create_flight_hud(panel, {
			"setMode": func(m: String) -> void:
				if autopilot != null:
					autopilot.program = null; autopilot.mode = m; autopilot.say("Manual control"),
			"runProgram": run_program,
			"setTarget": set_target,
		})

func _toast(m: String) -> void:
	if toast_cb != null: toast_cb.call(m)

# ----------------------------------------------------------------------------
func bodies() -> Array:
	return state.bodies.filter(func(b): return b.alive)

func body_named(n) -> Body:
	if n == null: return null
	for b in bodies():
		if b.name == n: return b
	return null

func dominant() -> Body:
	var best: Body = null
	for b in bodies():
		if b.mass > (best.mass if best != null else -1.0): best = b
	return best

func _stars() -> Array:
	return bodies().filter(func(b): return b.type == "star" or b.type == "white-dwarf")

## The longitude on `body` where it is mid-morning. The body turns toward
## increasing longitude (its spin is along −Y, matching the orrery's orbital
## sense), so earlier in the day is a smaller longitude.
func morning_longitude(body: Body) -> float:
	var src: Body = null
	for b in _stars():
		if b.mass > (src.mass if src != null else -1.0): src = b
	if src == null or src == body: return 0.0
	var a := DQuat.nrm(DVec3.new().sub_vectors(src.pos, body.pos))
	var sub := atan2(a.z, a.x) * 180.0 / PI
	# 22° west of the subsolar point. At a 28.5° pad that puts the sun 55° up —
	# mid-morning, the light every launch is photographed in, and high enough
	# that the vehicle is lit rather than silhouetted. (35° put it at 46° and
	# the whole complex read as dusk.)
	return sub - 22.0

## The brightest star's direction from the vessel, for lighting the model.
func sun_direction(out: DVec3) -> DVec3:
	var st := _stars()
	var src: Body = st[0] if not st.is_empty() else dominant()
	if src == null or vessel == null: return out.set_v(0.0, 1.0, 0.0)
	out.sub_vectors(src.pos, vessel.parent.pos).scale_in(Rocketry.AU_M).sub_in(vessel.r)
	return DQuat.nrm(out)

# ----------------------------------------------------------------------------
# LAUNCH / SPAWN
# ----------------------------------------------------------------------------
## opts: {mode: "pad"|"orbit", body, lat, lon, alt, inc} as the web build, plus
## two harness hooks the web reaches by other means: `phase` (the orbit phase
## the JS draws from Math.random) and `vehicle` (a vehicle Dictionary to fly
## instead of the table entry, e.g. a lone booster).
func begin(vehicle_key: String, opts: Dictionary = {}):
	var veh = opts.get("vehicle", Vehicles.VEHICLES.get(vehicle_key))
	if veh == null: return null
	teardown()

	var home := body_named(opts.get("body", veh.get("launchFrom") if veh.get("launchFrom") != null else "Earth"))
	if home == null: home = body_named("Earth")
	if home == null: home = dominant()
	if home == null:
		_toast("No body to fly from in this scenario")
		return null

	vessel = Vessel.new({"vehicle": veh, "parent": home, "bodies": bodies(),
		"payload": float(veh.carries.mass) if veh.get("carries") != null else 0.0})
	if veh.role == "launch" and opts.get("mode") != "orbit":
		var earth_pad = EARTH_PADS.get(vehicle_key, EARTH_PADS.default) if home.name == "Earth" else null
		# Put the pad in the local morning unless asked otherwise. The launch
		# site's longitude decides whether the ascent is watched in daylight or
		# in the dark, and "wherever longitude zero happens to be" is night
		# about half the time.
		var lat = opts.get("lat")
		if lat == null: lat = earth_pad.lat if earth_pad != null else null
		if lat == null: lat = veh.target.get("inclination") if veh.get("target") != null else null
		if lat == null: lat = 28.5
		var lon = opts.get("lon")
		if lon == null: lon = morning_longitude(home)
		vessel.place_on_pad(float(lat), float(lon))
		map_site = {"lat": float(opts.get("lat", earth_pad.lat)), "lon": float(earth_pad.lon)} if earth_pad != null else null
		fly_cam.set_mode("pad")
		fly_cam.state.hasPad = true
		# Where the pad IS, in the parent-centred frame the vessel uses. The
		# local frame's origin follows the vehicle's ground track, so the pad
		# does not stay at the origin for long — it has to be carried, and
		# carried round with the planet's rotation like any other point on the
		# surface.
		site_pos = vessel.r.clone()
	else:
		map_site = null
		var alt = opts.get("alt")
		if alt == null: alt = 15000.0 if veh.role == "lander" else 250000.0
		var ph = opts.get("phase")
		if ph == null: ph = randf() * 6.28
		vessel.place_in_orbit(float(alt), float(opts.get("inc", 0.0)), float(ph))
		fly_cam.set_mode("chase")
		fly_cam.state.hasPad = false
	vessel.vehicle_key = vehicle_key
	autopilot = Guidance.Autopilot.new(vessel)
	autopilot.mode = Guidance.MODE.PROGRADE

	craft = CraftModel.build_craft(veh)
	local.craft_root.add_child(craft.group)
	local.place(local.craft_root, craft_pos)
	# Frame the whole stack from the pad camera rather than a fixed distance —
	# a Saturn V is 111 m and a lunar module is 7, and one number cannot frame
	# both. d = (H/2)/tan(fov·0.34), with the camera a third of the way up so
	# the vehicle is centred rather than sitting on the bottom edge.
	var H: float = craft.height
	if H == 0.0:
		for s2 in veh.stages: H += float(s2.L)
	if site_pos != null:
		site = LaunchSite.create_launch_site(veh, H, vessel.env)
		local.root.add_child(site.group)
		local.place(site.group, site_local)
		# The ground flame belongs to the pad, not to the vehicle — it is what
		# the DECK does with the exhaust — so it is parented to the complex and
		# sits on the deck at the complex's own origin.
		var first = veh.stages[0] if not veh.stages.is_empty() else null
		var prop = first.engine.get("plume", "kerolox") if first != null and first.get("engine") != null else "kerolox"
		pad_fire = Plume.create_ground_flame(prop, maxf(vessel.diameter * 3.4, 22.0))
		site.group.add_child(pad_fire.mesh)
	# The tower, not the vehicle, is what has to fit in frame — it is taller
	# than the stack and it is the thing the climb is read against.
	var F := maxf(H, site.tower_height if site != null else 0.0)
	var d := (F * 0.5) / tan(55.0 * 0.34 * PI / 180.0)
	# Set back and round from the tower so the vehicle is seen against open
	# sky rather than through the lattice, and low, because a launch watched
	# from below is the shot that reads as a launch.
	pad_offset = Vector3(d * 0.62, F * 0.16, d * 0.78)
	fly_cam.state.padPos = DVec3.from_v3(pad_offset)
	pad_aimed = false
	build_plumes(veh)
	entry = Plume.create_entry_glow(maxf(vessel.diameter * 0.75, 2.0))
	craft.group.add_child(entry.mesh)

	fly_cam.state.dist = 3.2
	active = true
	cruise = null
	count = null
	if saved_speed == null: saved_speed = state.speed
	state.speed = 1.0
	set_warp(0)
	vessel.log_event("%s — %s, %s t, %s km/s ideal Δv" % [veh.name,
		"on the pad" if vessel.phase == Vessel.PHASE.PRELAUNCH else "in flight",
		U.fixed(Vehicles.gross_mass(veh) / 1000.0, 0), U.fixed(Vehicles.total_delta_v(veh) / 1000.0, 2)])
	if vessel.phase == Vessel.PHASE.PRELAUNCH:
		var F0: float = Vehicles.liftoff_thrust(veh, 101325.0)
		var twr: float = F0 / (vessel.mass * float(vessel.env.gSurf))
		vessel.log_event(("HOLD — liftoff thrust-to-weight is %s. It will not leave the pad." % U.fixed(twr, 2)) if twr < 1.0
			else ("Liftoff TWR %s · %s MN" % [U.fixed(twr, 2), U.fixed(F0 / 1e6, 1)]))
	refresh_targets()
	return vessel

func build_plumes(_veh: Dictionary) -> void:
	for p in plumes:
		if is_instance_valid(p.mesh) and p.mesh.get_parent() != null: p.mesh.get_parent().remove_child(p.mesh)
	plumes = []
	plume_reach = 0.0
	for st in craft.stages:
		var spec: Dictionary = st.spec
		var eng = spec.get("engine")
		if eng == null: continue
		for pv in st.parts.gimbals:
			var exit_d = eng.get("exitD")
			var pl := Plume.create_plume(eng.get("plume"), float(exit_d) if exit_d else float(spec.D) * 0.2)
			(pv as Node3D).add_child(pl.mesh)
			# The pad flame is lit by the FIRST stage's jet, so the reach it
			# dies at is that stage's plume length and no other's.
			if st == craft.stages[0] or plume_reach == 0.0: plume_reach = maxf(plume_reach, pl.reach)
			pl.stage_key = str(spec.key)
			pl.engine = eng
			plumes.append(pl)

## For shutdown only. The flight panel's hooks are lambdas that capture this
## object, and the panel is held here, so the two keep each other alive — and
## the orrery's state with them — until something breaks the ring.
func release() -> void:
	if active: teardown()
	hud = null
	target = null
	state = null

func teardown() -> void:
	if craft != null:
		if is_instance_valid(craft.group):
			craft.group.get_parent().remove_child(craft.group)
			craft.group.queue_free()
		craft = null
	if site != null:
		local.unplace(site.group)
		site.dispose()
		site = null
		site_pos = null
	map_site = null
	pad_fire = null
	ground_pos.y = 0.0
	plumes = []; entry = null
	smoke.clear()
	vessel = null; autopilot = null; cruise = null; plan = null; count = null
	if saved_speed != null:
		state.speed = saved_speed
		saved_speed = null
	active = false
	boost = Vector3.ZERO

# ----------------------------------------------------------------------------
# INTERSTELLAR
# ----------------------------------------------------------------------------
## Leave the solar system for a star. This is a different regime, not a longer
## burn: the vessel comes off the n-body integrator and onto the exact
## hyperbolic solution in sim/flight/relativity.gd, because at γ = 2 the
## Newtonian one is simply wrong and no step size fixes that.
func begin_cruise(target_body, accel_g = null) -> void:
	if vessel == null: return
	var st = null
	for s in vessel.stages:
		if s.attached and s.spec.get("engine") != null and s.spec.engine.get("photon", false):
			st = s; break
	if st == null:
		_toast("This vehicle has no interstellar drive — try the Hail Mary")
		return
	var origin := vessel.parent.pos.clone().add_scaled_in(vessel.r, 1.0 / Rocketry.AU_M)
	var tpos: DVec3 = (target_body as Body).pos.clone() if target_body != null \
		else origin.clone().add_in(DVec3.new(11.9 * Relativity.LY_AU, 0.0, 0.0))
	var a: float = (float(accel_g) if accel_g != null else float(st.spec.engine.holdAccel) / Rocketry.G0) * Rocketry.G0
	cruise = Relativity.Cruise.new({
		"origin": origin, "target": tpos, "accel": a,
		"dryMass": vessel.mass - st.prop, "propMass": st.prop,
		"exhaustMS": 299792458.0, "name": vessel.name,
	})
	vessel.phase = Vessel.PHASE.CRUISE
	var p: Dictionary = cruise.plan
	vessel.log_event("Interstellar cruise — %s ly at %s g" % [U.fixed(cruise.dist_ly, 2), U.fixed(a / Rocketry.G0, 2)])
	vessel.log_event(("Flip-and-burn: %s yr ship, %s yr coordinate" % [U.fixed(p.tauS / Rocketry.YR_S, 2), U.fixed(p.coordS / Rocketry.YR_S, 2)]) if p.mode == "flip"
		else ("Accelerate–coast–decelerate: burn %s ly, coast %s ly, β %s — %s yr ship, %s yr coordinate" % [
			U.fixed(p.burnLy, 2), U.fixed(p.coastLy, 2), U.fixed(p.betaMax, 4), U.fixed(p.tauS / Rocketry.YR_S, 2), U.fixed(p.coordS / Rocketry.YR_S, 2)]))
	# A crossing is measured in years, so it starts at the top of the warp
	# ladder. The rails interlock does not apply: an interstellar cruise is on
	# the exact hyperbolic solution, and that is valid at any step size.
	set_warp(WARPS.size() - 1)

# ----------------------------------------------------------------------------
# THE TERMINAL COUNT
# ----------------------------------------------------------------------------
func start_count(T: float = 10.0) -> void:
	var lead: float = IGNITION_LEAD.get(vessel.vehicle_key, 4.0)
	count = {"t": T, "lead": lead, "lit": false, "called": {}}
	vessel.held_down = true
	# Warp has to be 1× for the count to mean anything, and the interlock would
	# force it there a moment later anyway.
	set_warp(0)
	vessel.log_event("T−%s — terminal count" % U.fixed(T, 0))

func step_count(dt_sim: float) -> void:
	if count == null: return
	count.t -= dt_sim
	for mark in [8, 5, 3, 2, 1]:
		if count.t <= mark and not count.called.has(mark):
			count.called[mark] = true
			vessel.log_event("T−%d" % mark)
	if not count.lit and count.t <= count.lead:
		count.lit = true
		# Ignition, but still held down. The engines come up against the
		# hold-downs, which is exactly what the lead time is for: if one does
		# not reach thrust, the count stops with the vehicle still on the pad.
		vessel.throttle = 1.0
		vessel.log_event("Ignition sequence start")
	if count.t <= 0.0:
		count = null
		vessel.held_down = false
		vessel.log_event("Hold-down release")
		autopilot.engage("ascent")

## The flight panel's program buttons (JS: hooks.runProgram).
func run_program(p: String) -> void:
	if autopilot == null: return
	if p == "cruise":
		begin_cruise(target, null)
		return
	if p == "transfer" and target == null:
		_toast("Pick a target body first")
		return
	var ap = autopilot
	ap.plan = null; ap.node = null; ap.site = null; ap.burning = false
	ap.slamming = false; ap.entry_done = false; ap.shield_gone = false; ap.crane_out = false
	if p == "ascent" and vessel.phase == Vessel.PHASE.PRELAUNCH:
		start_count()
		return
	ap.engage(p)

# ----------------------------------------------------------------------------
# TIME
# ----------------------------------------------------------------------------
func set_warp(i: int) -> void:
	warp_idx = clampi(i, 0, WARPS.size() - 1)
	# The interlocks are real: on rails the thrust and drag terms are not
	# evaluated at all, so allowing high warp while either is acting silently
	# deletes them. Same rule KSP enforces, same reason.
	if vessel != null and cruise == null:
		var railable := vessel.can_rail()
		if not railable and WARPS[warp_idx] > 4:
			# The highest rung still integrated rather than railed.
			var capped := 0
			for k in WARPS.size():
				if WARPS[k] <= 4: capped = k
			if warp_idx != capped: _toast("Time warp limited — under thrust or inside the atmosphere")
			warp_idx = capped
	state.time_scale = WARPS[warp_idx] / Rocketry.YR_S

func warp() -> int:
	return WARPS[warp_idx]

func warp_index() -> int:
	return warp_idx

func camera_mode() -> String:
	return fly_cam.state.mode

func set_camera_mode(m: String) -> void:
	fly_cam.set_mode(m)

# ----------------------------------------------------------------------------
# TARGETING
# ----------------------------------------------------------------------------
func refresh_targets() -> void:
	if hud == null: return
	var names := []
	for b in bodies(): names.append(b.name)
	hud.set_targets(names, target.name if target != null else null)

func set_target(n) -> void:
	target = body_named(n) if n != null and n != "" else null
	plan = null
	if autopilot != null:
		autopilot.target = target
		autopilot.plan = null

# ----------------------------------------------------------------------------
# UPDATE
# ----------------------------------------------------------------------------
func update(dt: float, _frame = null) -> void:
	if not active or vessel == null: return
	vessel.bodies = bodies()
	if not vessel.bodies.has(vessel.parent):
		var d := dominant()
		if d != null: vessel.set_parent(d, vessel.bodies)
		else: return

	# Keep the orrery's clock slaved to the flight warp every frame, not just
	# when the warp changes — otherwise the time-scale slider silently
	# desynchronises the planets from the vehicle flying between them.
	state.time_scale = WARPS[warp_idx] / Rocketry.YR_S
	# Flight time is 1:1 with the wall clock at warp 1, and the ONLY handle on
	# it is the warp ladder. The orrery's own speed multiplier is forced to 1
	# for the duration (see begin/teardown), or the count, the staging times
	# and the max-q on the HUD would all be silently multiples of the real ones.
	var w: float = warp() * (0.0 if state.paused else 1.0)
	var sim_seconds := dt * w

	if cruise != null:
		# Ship proper time is the natural variable in cruise — the drive, the
		# fuel and the crew all live on it.
		cruise.step(sim_seconds)
		cruise.position(_a)
		vessel.met = cruise.tau; vessel.coord = cruise.t
		vessel.clock_delta = cruise.tau - cruise.t
		# Point the ship along or against the line of flight, which is what a
		# flip-and-burn looks like from outside.
		var facing := -1.0 if cruise.leg == "decel" else 1.0
		_q.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), _b.copy_from(cruise.dir).scale_in(facing))
		vessel.q.slerp_in(_q, 1.0 - exp(-dt * 1.4))
		Relativity.sky_boost(cruise.dir, cruise.beta, _boost_d)
		boost = _boost_d.to_v3()
	else:
		boost = Vector3.ZERO
		if count != null: step_count(sim_seconds)
		if autopilot != null: autopilot.update(minf(dt, 0.1))
		# Physics warp up to 4×; above that the vessel goes on rails, which is
		# only legal unpowered and out of the air (checked inside step()).
		var rails := w > 4.0 and vessel.can_rail()
		if rails:
			vessel.step(sim_seconds, {"rails": true})
		else:
			# Sub-step so a big real-time dt never becomes one huge integration.
			var rem := sim_seconds
			var guard := 0
			while rem > 1e-6 and guard < 24:
				guard += 1
				var h := minf(rem, 0.5 * maxf(w, 1.0))
				vessel.step(h)
				rem -= h
		if w > 4.0 and not vessel.can_rail(): set_warp(2)

	update_visual(dt, sim_seconds)
	if hud != null: update_hud()

# ----------------------------------------------------------------------------
func _local_up_north() -> Array:
	var up := DQuat.nrm(vessel.r.clone())
	var north := DVec3.new(0.0, -1.0, 0.0)
	if absf(north.dot(up)) > 0.98: north.set_v(1.0, 0.0, 0.0)
	north.add_scaled_in(up, -north.dot(up))
	DQuat.nrm(north)
	return [up, north]

func update_visual(dt: float, sim_seconds: float) -> void:
	var env: Dictionary = vessel.env
	var alt := vessel.altitude()
	var un := _local_up_north()
	var up: DVec3 = un[0]
	var north: DVec3 = un[1]
	var sun := sun_direction(DVec3.new())

	# Irradiance relative to Earth's, so a launch from Mars is visibly dimmer
	# and one from Mercury is blinding — 1/r² from the brightest star.
	var star: Body = null
	for b in bodies():
		if b.type == "star":
			star = b; break
	var d_au := maxf(star.pos.distance_to(vessel.parent.pos), 1e-4) if star != null else 1.0
	var star_flux: float = (float(U.nz(star.luminosity, 1.0)) / (d_au * d_au)) if star != null else 1.0
	# Advance the fixed launch site before sampling the map. Its rotation and
	# the local ground's geographic frame must describe the same instant.
	if site != null and site_pos != null:
		if vessel.phase == Vessel.PHASE.PRELAUNCH:
			site_pos.copy_from(vessel.r)
		else:
			# ω × r — see AGENTS.md: a point fixed to a rotating body.
			_a.set_v(0.0, -float(env.rotRate), 0.0).cross_vectors(_a, site_pos)
			DQuat.set_len(site_pos.add_scaled_in(_a, sim_seconds), float(env.radius))
	var fr := local.update({"env": env, "altitude": alt, "sunDirWorld": sun, "upWorld": up, "northWorld": north,
		"starFlux": star_flux, "padWorld": site_pos, "mapSite": map_site})

	# The craft sits at the origin of the local frame with the local up as +Y,
	# so its attitude has to be expressed in that frame rather than in world
	# axes — the two differ by wherever on the planet it happens to be.
	var east := DQuat.nrm(DVec3.new().cross_vectors(up, north))
	frame_basis = Basis(east.to_v3(), up.to_v3(), north.to_v3())
	var craft_basis := frame_basis.transposed() * Basis(vessel.q.to_quaternion())
	craft_pos.set_v(0.0, alt, 0.0)
	craft.group.position = Vector3.ZERO
	craft.group.basis = craft_basis.orthonormalized()

	# ---- the launch complex. The local frame's origin is the point on the
	# surface directly under the VEHICLE, so as the vehicle flies downrange the
	# pad has to move backwards through the frame — which is the parallax that
	# makes a launch look like one. Exact rather than approximated: for a point
	# at angular distance θ from the origin, (r·east, r·up − R, r·north) is
	# (R sinθ, R(cosθ−1), …), and R(cosθ−1) is to second order the same −x²/2R
	# drop the ground patch is drawn with, so the pad sits ON the ground.
	if site != null and site_pos != null:
		var sx: float = site_pos.dot(east)
		var sy: float = site_pos.dot(up) - float(env.radius)
		var sz: float = site_pos.dot(north)
		site_local.set_v(sx, sy, sz)
		# The pad deck is the datum: the vessel reads zero altitude standing on
		# its launch mount, which on a real complex is 7.6 m to 23.5 m above
		# grade. So the ground patch is dropped by that much — and by the
		# HARDSTAND's rise as well, or the mound's top face and the patch are
		# two coplanar surfaces a hundred metres across fighting for depth.
		ground_pos.y = -site.grade_drop
		var rng := Vector2(sx, sz).length()
		# Past a few tens of kilometres the whole complex is under a pixel, and
		# the ground patch's own detail is the better picture.
		site.group.visible = alt < 8e4 and rng < 1.2e5
		if site.group.visible:
			site.update({
				"released": vessel.phase != Vessel.PHASE.PRELAUNCH and alt > 1.0,
				"throttle": vessel.throttle if float(vessel.telemetry.get("thrust", 0.0)) > 0.0 else 0.0,
				"dt": minf(sim_seconds, 0.25),
			})
		# Put the camera on the SUNLIT side once, on the first frame, when the
		# sun's azimuth in the local frame is finally known. A white rocket
		# photographed from its shadow side is a black rocket.
		if not pad_aimed:
			pad_aimed = true
			var sun_az := atan2(sun.dot(north), sun.dot(east))
			var r := Vector2(pad_offset.x, pad_offset.z).length()
			pad_offset = Vector3(cos(sun_az) * r, pad_offset.y, sin(sun_az) * r)
		# The pad camera stands ON the pad, so it moves with it.
		fly_cam.state.padPos = site_local.clone().add_in(DVec3.from_v3(pad_offset))
	local.place(local.ground, ground_pos)

	# moving parts
	var deploy := {}
	for st in vessel.stages:
		var s: Dictionary = st.spec
		var d := 0.0
		var v_up := vessel.v.dot(up)
		if s.get("legs"): d = 1.0 if (vessel.phase == Vessel.PHASE.LANDED or (alt < 3000.0 and v_up < 0.0)) else 0.0
		if s.get("gridFins"): d = 1.0 if (alt < (float(env.atm.top) if env.atm != null else 0.0) and v_up < 0.0) else 0.0
		var look = s.get("look")
		if s.get("solar") or (look != null and look.get("arrays")): d = 1.0
		deploy[s.key] = d
	# Gimbal deflection, from the attitude error the controller is working on.
	var gerr := 0.0
	if autopilot != null and autopilot.aim != null:
		gerr = DQuat.angle_between(vessel.forward(_b), autopilot.aim)
	var sg := signf(sin(vessel.met * 3.0))
	var gx := clampf(gerr * 2.4, 0.0, 0.12) * (sg if sg != 0.0 else 1.0)
	var attached := {}
	for st in vessel.stages: attached[st.spec.key] = st.attached
	craft.update({"dt": dt, "attached": attached, "deploy": deploy, "gimbal": {"x": gx, "z": 0.0}, "flap": 0.0})
	for st in vessel.stages:
		var cs = craft.stage(str(st.spec.key))
		if not st.attached and cs != null and cs.sep == null and cs.group.visible:
			craft.separate(str(st.spec.key), 4.0 + randf() * 4.0, 0.2 + randf() * 0.5)

	# plumes — each engine's own, at the ambient pressure it is actually in
	var pa: float = Rocketry.pressure(env.atm, maxf(alt, 0.0)) if env.atm != null else 0.0
	var p0: float = float(env.atm.p0) if env.atm != null else 101325.0
	for pl in plumes:
		var st = null
		for s in vessel.stages:
			if str(s.spec.key) == pl.stage_key: st = s
		var on: bool = st != null and st.attached and st.ignited and not st.spent and st.prop > 0.0 and vessel.throttle > 0.0
		pl.update(vessel.throttle if on else 0.0, pa, vessel.met, p0)
	if cruise != null:
		for pl in plumes:
			pl.update(0.0 if (cruise.leg == "coast" or cruise.leg == "arrived") else 1.0, 0.0, cruise.tau / 100.0, 101325.0)

	# re-entry sheath, from the same heat flux that is burning the shield down
	if entry != null:
		entry.mesh.basis = craft.group.basis.inverse()
		entry.mesh.position = Vector3.ZERO
		entry.update(float(U.nz(vessel.telemetry.get("heat"), 0.0)), vessel.met)

	# The deflected exhaust. Only while the jet still lands on the deck, which
	# the ground flame works out for itself from the vehicle's height.
	if pad_fire != null:
		var lit: float = vessel.throttle if float(vessel.telemetry.get("thrust", 0.0)) > 0.0 else 0.0
		pad_fire.update(lit if site.group.visible else 0.0, alt, plume_reach, vessel.met)

	# launch smoke: only where there is an atmosphere and a surface to hit
	if env.atm != null and alt < 900.0 and vessel.throttle > 0.0 and float(vessel.telemetry.get("thrust", 0.0)) > 0.0:
		# How dirty the cloud is comes from the propellant, not from taste — a
		# solid throws alumina, an RP-1 engine throws carbon, and a hydrogen
		# engine throws steam and very little else.
		var soot := 0.7
		var s0 = vessel.stages[0].spec if not vessel.stages.is_empty() else null
		if s0 != null and s0.get("engine") != null and Plume.PROPELLANT.has(s0.engine.get("plume", "")):
			soot = Plume.PROPELLANT[s0.engine.plume].soot
		smoke.emit(Vector3(0.0, maxf(alt - vessel.length * 0.5, 0.0), 0.0),
			vessel.throttle, maxf(vessel.diameter * 2.2, 12.0), dt, soot)
	smoke.update(dt)
	rcs_puffs.update(dt)

	# The pad camera is fixed on the ground, so it is the right view for the
	# first few seconds and useless after that. Hand over to the chase camera
	# once the vehicle has climbed out of its frame — which is what a launch
	# broadcast does, and for the same reason.
	if fly_cam.state.mode == "pad" and alt > maxf(craft.height * 22.0, 1500.0):
		fly_cam.set_mode("chase")
		vessel.log_event("Camera — pad view lost, tracking from the vehicle")

	# ---- cameras. The local camera is the real one; the orrery's camera is
	# slaved to it so the planet, the stars and the lensing all agree with the
	# view the vehicle is being watched from.
	var sun_l := Vector3(sun.dot(east), sun.dot(up), sun.dot(north)).normalized()
	fly_cam.update({"craftPos": craft_pos, "craftBasis": craft_basis,
		"length": craft.height if craft.height else vessel.length, "up": Vector3(0, 1, 0),
		"dt": dt, "sunLocal": sun_l})
	local.cam_pos.copy_from(fly_cam.pos)
	# far/near may not pass ~1e7 here (PORT_GUIDE.md §3: Godot builds the
	# culling frustum in float32 and past that it degenerates and culls the
	# whole pass — measured: the cockpit view, near 0.05 m against the 4e6 m
	# far plane the sky dome needs, drew nothing at all). So the near plane is
	# floored at far·1e-7 = 0.4 m. The web build's own floor is 0.05 m, reached
	# only from inside the stack (cockpit), where nothing is closer than the
	# tank wall metres away; everywhere else its near plane is already larger.
	local.camera.far = 4.0e6
	local.camera.near = maxf(fly_cam.near, local.camera.far * 1.0e-7)
	local.camera.fov = 55.0
	local.apply_origin(fly_cam.basis)

	# Map the local camera into the orrery: same orientation, position offset
	# from the vessel by the local offset converted to scene units — all of it
	# in double, because the result is the orrery's floating origin.
	if main != null:
		var ss: float = state.scene_scale
		var parent_scene: DVec3 = vessel.parent.scene_pos
		var cl := fly_cam.pos.sub(craft_pos)
		# rotate the local offset out of the local frame back into world axes
		var world_off := east.scaled(cl.x).add_scaled_in(up, cl.y).add_scaled_in(north, cl.z)
		var k := ss / Rocketry.AU_M
		main.cam_pos = parent_scene.clone().add_scaled_in(vessel.r, k).add_scaled_in(world_off, k)
		main.cam_basis = (frame_basis * fly_cam.basis).orthonormalized()
		main.cam_fov = 55.0
		# The web build left camera.near alone in flight, which in practice is
		# the 0.01 that setCamMode restores and that every system-scale view
		# already has (its reference shots report exactly that). It is stated
		# here rather than inherited because main.gd's far plane is tied to it
		# (far = min(1e5, near·1e7), PORT_GUIDE.md §3): entering flight from a
		# close-up would otherwise carry a 1e-6 near plane into the launch and
		# cull every planet past 10 scene units.
		main.cam_near = 0.01

# ----------------------------------------------------------------------------
func update_hud() -> void:
	var t: Dictionary = vessel.telemetry
	var un := _local_up_north()
	var markers := {}
	for k in ["prograde", "retrograde", "normal", "antinormal", "radial"]:
		var d = Guidance.attitude_for(k, vessel, target)
		if d != null: markers[k] = (d as DVec3).to_v3()
	if target != null:
		markers["target"] = DQuat.nrm(Guidance.target_offset(vessel, target, DVec3.new())).to_v3()
	if autopilot != null and autopilot.aim != null:
		markers["node"] = (autopilot.aim as DVec3).to_v3()

	if target != null and autopilot != null and plan == null: plan = autopilot.plan_transfer(target)
	var plan_data := {}
	if cruise != null: plan_data = FlightUI.cruise_block(cruise.readout())
	elif target != null: plan_data = FlightUI.plan_block(plan, target.name)
	hud.update({
		"vessel": vessel, "telemetry": t, "up": (un[0] as DVec3).to_v3(), "north": (un[1] as DVec3).to_v3(),
		"markers": markers,
		"status": ("Interstellar cruise — %s" % cruise.leg) if cruise != null else (autopilot.status if autopilot != null else "Manual control"),
		"mode": autopilot.mode if autopilot != null else null,
		"program": autopilot.program if autopilot != null else null,
		"warp": str(warp()),
		"parentName": vessel.parent.name,
		"plan": plan_data,
	})

func set_size(w: float, h: float) -> void:
	local.set_size(w, h)

# ----------------------------------------------------------------------------
# INPUT
# ----------------------------------------------------------------------------
## The flight keys, by the JS e.code they were bound to. Returns true when the
## key was taken.
func key(e: InputEventKey) -> bool:
	if not active or vessel == null: return false
	if not e.pressed: return false
	match e.physical_keycode:
		KEY_COMMA:
			set_warp(warp_idx - 1); return true
		KEY_PERIOD:
			set_warp(warp_idx + 1); return true
		KEY_X:
			vessel.throttle = 0.0; return true
		KEY_Z:
			vessel.throttle = 1.0; return true
		KEY_SHIFT:
			# ShiftLeft only, as the web build bound it
			if e.location == KEY_LOCATION_RIGHT: return false
			vessel.throttle = minf(1.0, vessel.throttle + 0.06); return true
		KEY_CTRL:
			if e.location == KEY_LOCATION_RIGHT: return false
			vessel.throttle = maxf(0.0, vessel.throttle - 0.06); return true
		KEY_SPACE:
			if e.shift_pressed:
				vessel.stage()
				return true
			return false
		KEY_G:
			for st in vessel.stages:
				if st.attached and st.spec.get("legs"):
					st.gear_out = not st.gear_out
					break
			return true
		KEY_C:
			var modes := ["chase", "orbit", "cockpit", "pad"]
			var i := modes.find(fly_cam.state.mode)
			fly_cam.set_mode(modes[(i + 1) % modes.size()])
			return true
	return false

## The pad camera is a camera on a tripod, not a fixed frame grab: you should
## be able to walk it round the vehicle and raise it up the tower, the way
## every launch broadcast cuts between half a dozen positions on the same pad.
## It is expressed as an offset from the pad rather than as yaw/pitch/distance
## because the pad itself is moving through the local frame at 408 m/s.
func pad_orbit(d_az: float, d_el: float, scale: float) -> void:
	var r := Vector2(pad_offset.x, pad_offset.z).length()
	if r == 0.0: r = 1.0
	var az := atan2(pad_offset.z, pad_offset.x) + d_az
	# Elevation is held as a height, not an angle, so raising the camera does
	# not walk it in toward the vehicle. Floor is head height; ceiling is above
	# the tower.
	var y := clampf(pad_offset.y + d_el * r, 1.7, r * 3.0)
	var nr := clampf(r * scale, maxf(vessel.length * 0.35, 12.0), 6000.0)
	pad_offset = Vector3(cos(az) * nr, y * (nr / r), sin(az) * nr)
	pad_aimed = true

## deltaY as a browser reports it (a wheel notch is ~100).
func wheel(delta_y: float) -> bool:
	if not active: return false
	if fly_cam.state.mode == "pad" and site != null:
		pad_orbit(0.0, 0.0, 1.0 + delta_y * 0.001)
		return true
	fly_cam.state.dist = clampf(fly_cam.state.dist * (1.0 + delta_y * 0.001), 0.6, 400.0)
	return true

func drag(dx: float, dy: float) -> bool:
	if not active: return false
	if fly_cam.state.mode == "pad" and site != null:
		pad_orbit(dx * 0.006, -dy * 0.004, 1.0)
		return true
	fly_cam.state.userAimed = true
	fly_cam.state.yaw -= dx * 0.006
	fly_cam.state.pitch = clampf(fly_cam.state.pitch - dy * 0.006, -1.45, 1.45)
	return true
