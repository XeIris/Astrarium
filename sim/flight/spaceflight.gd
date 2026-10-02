class_name Spaceflight
extends RefCounted

# The spaceflight integration layer: the only file in sim/flight/ that knows the
# orrery exists. Everything under it is pure.
#
# One clock: entering flight takes over state.time_scale and drives it from the
# flight warp, state.time_scale = warp / YR_S, so at 1× the planets advance a
# second per second.
#
# Two spaces: the vehicle is drawn in localview.gd's metre-scale pass
# (pipeline.gd draws pipe.local_vp in Mode.FLIGHT). Each frame this places the
# local camera (at the origin) and every local object, and slaves the orrery
# camera: main.cam_pos is computed in double as parent.scene_pos +
# r·sceneScale/AU_M + the local camera's offset rotated out of the local frame,
# plus main.cam_basis, cam_fov and cam_near. `boost` is β for
# SkyModel.apply_sky_boost. key() maps physical keycodes; wheel(delta_y) takes a
# browser-style deltaY. The HUD (flightui.gd) mounts into ctx.panel.

const WARPS := [1, 2, 5, 10, 50, 100, 1000, 10000, 100000, 1000000]
const EARTH_PADS := {
	# NASA's SpaceX Starship environmental assessment lists these coordinates
	# for the Texas launch site and Kennedy's Pad 39A, respectively.
	"starship": {"lat": 25.99684, "lon": -97.15523},
	"default": {"lat": 28.608402, "lon": -80.604201},
}

# THE TERMINAL COUNT: the last ten seconds, with events at their real times. The
# lead is per vehicle: Saturn V F-1s at T−8.9 s, Shuttle SSMEs at T−6.6 s and the
# solids at T−0, Falcon 9 and Starship at T−3.
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
var autopilot = null              # Guidance.Autopilot
var craft = null                  # CraftModel.Craft
var plumes: Array = []            # Plume.PlumeFx
var entry = null                  # Plume.EntryGlow
var cruise = null                 # Relativity.Cruise
## What the cruise flies between, so the line moves with its end bodies: {parent,
## parent0, target, target0, stage, name, arrived}. Null outside cruise.
var cruise_ctx = null
## A requested cruise waiting because the line runs through the planet: {body,
## mission, accel}. The ship coasts until the line is clear.
var pending_cruise = null
## An interstellar destination picked from the target list — one of the
## vehicle's `missions` — as against `target`, which is always a body.
var star_target = null
var site = null                   # LaunchSite
var site_pos = null               # DVec3: the pad, in the vessel's parent frame, m
var map_site = null               # {lat, lon} of the mapped geography
var pad_fire = null               # Plume.GroundFlame — the deflected exhaust
var plume_reach := 0.0            # how far the first stage's jet carries, m
# The terminal count, so a launch has a visible beginning.
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

var sky_gain := 1.0               # the background's exposure, see update_visual
## The camera's adapted exposure, eased like an eye: 1 in daylight at 1 AU.
## Negative means not adapted yet (snap).
var exposure := -1.0
## Integrated starlight as a fraction of the Sun's irradiance at Earth (2e-4 lux
## against 1e5).
const STARLIGHT := 2.0e-9
## Planet rotation since the flight began, rad (world → planet-fixed is a turn about
## +Y by this). Clouds and ground detail are laid out planet-fixed.
var planet_spin := 0.0
## A point on the surface, carried round with the planet: where the ground's
## detail is laid out from when there is no pad.
var anchor_pos := DVec3.new()
## Which way the wind carries the cloud field, in the planet-fixed frame.
var wind_dir := Vector3.ZERO
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
var _warp_shown := -1
## The target list's prefix for an interstellar destination, which is not a
## body in the scenario and must not be looked up as one.
const MISSION_PREFIX := "★ "

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

## The longitude on `body` where it is mid-morning (spin along −Y, so earlier is a
## smaller longitude).
func morning_longitude(body: Body) -> float:
	var src: Body = null
	for b in _stars():
		if b.mass > (src.mass if src != null else -1.0): src = b
	if src == null or src == body: return 0.0
	var a := DQuat.nrm(DVec3.new().sub_vectors(src.pos, body.pos))
	var sub := atan2(a.z, a.x) * 180.0 / PI
	# 22° west of the subsolar point: the sun 55° up at a 28.5° pad.
	return sub - 22.0

## The brightest star's direction from the vessel, for lighting the model.
func sun_direction(out: DVec3) -> DVec3:
	var src := light_sources()
	if src.is_empty() or vessel == null:
		var d := dominant()
		if d == null or vessel == null: return out.set_v(0.0, 1.0, 0.0)
		out.sub_vectors(d.pos, vessel.parent.pos).scale_in(Rocketry.AU_M).sub_in(vessel.r)
		return DQuat.nrm(out)
	return out.copy_from(src[0].dir)

## Where the vessel is in the orrery's frame, AU.
func ship_world(out: DVec3 = null) -> DVec3:
	if out == null: out = DVec3.new()
	return out.copy_from(vessel.parent.pos).add_scaled_in(vessel.r, 1.0 / Rocketry.AU_M)

## Every star lighting the vessel, brightest first: {dir (unit DVec3 toward the
## star), flux (relative to the Sun at Earth, from the vessel's position), teff,
## ang_r}. Includes an interstellar mission's destination.
func light_sources() -> Array:
	var out := []
	if vessel == null: return out
	var w := ship_world()
	for b in _stars():
		var d := DVec3.new().sub_vectors(b.pos, w)
		var r := maxf(d.length(), 1e-6)
		out.append({"dir": d.scale_in(1.0 / r), "flux": float(U.nz(b.luminosity, 1.0)) / (r * r),
			"teff": float(U.nz(b.teff, 5772.0)), "ang_r": b.radius / r if b.radius > 0.0 else 0.00465 / r})
	if cruise_ctx != null and cruise_ctx.get("star_pos") != null:
		var m: Dictionary = cruise_ctx.mission
		var d := DVec3.new().sub_vectors(cruise_ctx.star_pos, w)
		var r := maxf(d.length(), 1e-6)
		out.append({"dir": d.scale_in(1.0 / r), "flux": float(m.get("lum", 1.0)) / (r * r),
			"teff": float(m.get("teff", 5772.0)), "ang_r": float(m.get("radius", 1.0)) * 0.00465047 / r})
	out.sort_custom(func(a, b): return a.flux > b.flux)
	return out

# LAUNCH / SPAWN
## opts: {mode: "pad"|"orbit", body, lat, lon, alt, inc}, plus harness hooks
## `phase` (orbit phase) and `vehicle` (a vehicle Dictionary to fly instead).
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
		# Pad in the local morning unless asked otherwise.
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
		# The pad in the parent-centred frame, carried round with the planet since the
		# local origin follows the vehicle.
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
	planet_spin = 0.0
	DQuat.set_len(anchor_pos.copy_from(vessel.r), float(vessel.env.radius))
	# east at the start, in the planet-fixed frame (which is the world frame
	# at spin 0): ω̂ × r̂ with ω̂ = −Y
	var st_up := DQuat.nrm(vessel.r.clone()).to_v3()
	wind_dir = Vector3(0, -1, 0).cross(st_up).normalized() if absf(st_up.y) < 0.999 else Vector3(1, 0, 0)
	autopilot = Guidance.Autopilot.new(vessel)
	autopilot.mode = Guidance.MODE.PROGRADE

	craft = CraftModel.build_craft(veh)
	local.craft_root.add_child(craft.group)
	local.place(local.craft_root, craft_pos)
	# Frame the stack by its height: d = (H/2)/tan(fov·0.34), camera a third of the
	# way up.
	var H: float = craft.height
	if H == 0.0:
		for s2 in veh.stages: H += float(s2.L)
	if site_pos != null:
		# Stand the vehicle in its first-frame attitude before the complex measures it,
		# then turn the complex to the vehicle's roll (which depends on the pad's longitude).
		var un := _local_up_north()
		var east0 := DQuat.nrm(DVec3.new().cross_vectors(un[0], un[1]))
		var fb := Basis((east0 as DVec3).to_v3(), (un[0] as DVec3).to_v3(), (un[1] as DVec3).to_v3())
		var cb := (fb.transposed() * Basis(vessel.q.to_quaternion())).orthonormalized()
		craft.group.basis = cb
		site = LaunchSite.create_launch_site(veh, H, vessel.env, craft.group)
		site.group.rotation.y = atan2(-cb.x.z, cb.x.x)
		local.root.add_child(site.group)
		local.place(site.group, site_local)
		# The ground flame belongs to the pad, parented to the complex.
		var first = veh.stages[0] if not veh.stages.is_empty() else null
		var prop = first.engine.get("plume", "kerolox") if first != null and first.get("engine") != null else "kerolox"
		pad_fire = Plume.create_ground_flame(prop, maxf(vessel.diameter * 3.4, 22.0))
		# Under the mount at grade, where the exhaust turns (7.6–23.5 m below the deck).
		pad_fire.mesh.position.y = -site.deck_height
		pad_fire.aspect = Vector2(1.0, 1.0) if site.style == "chopsticks" else Vector2(1.9, 0.55)
		site.group.add_child(pad_fire.mesh)
	# The tower, not the vehicle, is what has to fit in frame — it is taller
	# than the stack and it is the thing the climb is read against.
	var F := maxf(H, site.tower_height if site != null else 0.0)
	var d := (F * 0.5) / tan(55.0 * 0.34 * PI / 180.0)
	# Set back from the tower against open sky, and low.
	pad_offset = Vector3(d * 0.62, F * 0.16, d * 0.78)
	fly_cam.state.padPos = DVec3.from_v3(pad_offset)
	pad_aimed = false
	build_plumes(veh)
	entry = Plume.create_entry_glow(maxf(vessel.diameter * 0.75, 2.0))
	craft.group.add_child(entry.mesh)

	fly_cam.state.dist = 3.2
	active = true
	cruise = null; cruise_ctx = null; pending_cruise = null
	count = null
	exposure = -1.0
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
		var pivots: Array = st.parts.gimbals
		if pivots.is_empty(): continue
		# `engineOn`: the Shuttle's SSMEs are on the orbiter but are the tank's engines, lit
		# from liftoff.
		var owner_spec := spec
		for other in craft.stages:
			var os: Dictionary = other.spec
			if str(os.get("engineOn", "")) == str(spec.key) and int(os.get("count", 0)) == pivots.size():
				owner_spec = os
		eng = owner_spec.engine
		# Clusters of four or more: each engine's near field plus one merged far field.
		var cluster := pivots.size() >= 4
		var lead: Plume.PlumeFx = null
		var inv: Transform3D = st.group.global_transform.affine_inverse()
		var centre := Vector3.ZERO
		var exits: Array = []
		for i in pivots.size():
			var pv: Node3D = pivots[i]
			var bell := _measure_bell(pv, owner_spec)
			var e: Dictionary = bell.engine
			var pl := Plume.create_plume(e.get("plume"), bell.exit_d, 18.0, e,
				"near" if cluster else "single", float(i) + float(hash(str(owner_spec.key)) % 97))
			# the plume starts at the EXIT PLANE, which is where the bell ends —
			# the pivot is at the throat, a bell's length above it
			pl.mesh.position.y = bell.exit_y
			pv.add_child(pl.mesh)
			if st == craft.stages[0] or plume_reach == 0.0: plume_reach = maxf(plume_reach, pl.reach)
			pl.stage_key = str(owner_spec.key)
			pl.engine = e
			plumes.append(pl)
			if lead == null: lead = pl
			var ep: Vector3 = inv * pv.global_transform * Vector3(0.0, bell.exit_y, 0.0)
			centre += ep
			exits.append([ep, bell.exit_d])
		if cluster:
			centre /= float(pivots.size())
			var rad := 0.0
			var ey := 0.0
			for ex in exits:
				var ep: Vector3 = ex[0]
				rad = maxf(rad, Vector2(ep.x - centre.x, ep.z - centre.z).length() + float(ex[1]) * 0.5)
				ey += ep.y
			centre.y = ey / float(exits.size())
			var far := Plume.create_plume(eng.get("plume"), rad * 2.0, 12.0, eng, "far", float(hash(str(spec.key)) % 53))
			far.mesh.position = centre
			st.group.add_child(far.mesh)
			if st == craft.stages[0] or plume_reach == 0.0: plume_reach = maxf(plume_reach, far.reach)
			far.stage_key = str(owner_spec.key)
			far.engine = eng
			plumes.append(far)
			lead = far
		if lead != null: Plume.add_flame_light(lead, lead.exit_d)

## A pivot's exit plane and width, measured off the mesh, and which engine it is
## (Starship mixes sea-level and vacuum Raptors, told apart by bell size).
func _measure_bell(pv: Node3D, spec: Dictionary) -> Dictionary:
	var eng: Dictionary = spec.engine
	var inv := pv.global_transform.affine_inverse()
	var lo := INF
	var r := 0.0
	for c in pv.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree(): continue
		var ab := mi.get_aabb()
		var xf := inv * mi.global_transform
		for k in 8:
			var p: Vector3 = xf * ab.get_endpoint(k)
			lo = minf(lo, p.y)
			r = maxf(r, maxf(absf(p.x), absf(p.z)))
	var vac = spec.get("vacEngine")
	if vac != null and r > 0.0 and absf(2.0 * r - float(vac.exitD)) < absf(2.0 * r - float(eng.exitD)):
		eng = vac
	var d := float(eng.get("exitD", float(spec.D) * 0.2))
	var y := lo if is_finite(lo) else -d * 1.3
	return {"engine": eng, "exit_d": d, "exit_y": minf(y, 0.0)}

## Shutdown only: the flight panel's lambdas capture this object, and the panel is
## held here, so the cycle has to be broken.
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
	cruise_ctx = null; pending_cruise = null; star_target = null
	if saved_speed != null:
		state.speed = saved_speed
		saved_speed = null
	active = false
	boost = Vector3.ZERO
	sky_gain = 1.0
	SkyModel.apply_day_gain(pipe.sky_materials, 1.0)

# INTERSTELLAR
## Leave for a star: off the n-body integrator and onto the exact hyperbolic
## solution in relativity.gd. The destination is `target_body`, one of the vehicle's
## `missions` (placed at its real distance and direction), or the first mission.
func begin_cruise(target_body, accel_g = null, mission = null) -> void:
	if vessel == null: return
	var st = _photon_stage()
	if st == null:
		_toast("This vehicle has no interstellar drive — try the Hail Mary")
		return
	if target_body == vessel.parent:
		_toast("Already at %s — pick somewhere else to go" % vessel.parent.name)
		return
	if target_body == null and mission == null:
		var ms := missions()
		if not ms.is_empty():
			mission = ms[0]
			vessel.log_event("No target picked — flying the mission, %s" % mission.name)
	var origin := vessel.parent.pos.clone().add_scaled_in(vessel.r, 1.0 / Rocketry.AU_M)
	var tpos := _cruise_target_pos(target_body, mission, origin)
	var dname: String = (target_body as Body).name if target_body != null \
		else (str(mission.name) if mission != null else "deep space")
	# The line has to be clear: wait until r̂·d̂ > 0, when the closest approach is
	# where the ship already is.
	var d_hat := DQuat.nrm(tpos.clone().sub_in(origin))
	if vessel.phase != Vessel.PHASE.PRELAUNCH and DQuat.nrm(vessel.r.clone()).dot(d_hat) < 0.0:
		if pending_cruise == null:
			vessel.log_event("Coasting to the departure point — the line to %s runs through %s" % [dname, vessel.parent.name])
		pending_cruise = {"body": target_body, "mission": mission, "accel": accel_g}
		if autopilot != null:
			autopilot.program = null
			autopilot.say("Waiting for the line to %s to clear %s" % [dname, vessel.parent.name])
		# Half an orbit at most, so let it go by quickly — a few seconds.
		var want := 0
		for k in WARPS.size():
			if WARPS[k] <= 1000: want = k
		if warp_idx < want: set_warp(want)
		return
	pending_cruise = null

	var a: float = (float(accel_g) if accel_g != null
		else (float(mission.accel) if mission != null and mission.get("accel") != null
		else float(st.spec.engine.holdAccel) / Rocketry.G0)) * Rocketry.G0
	var c = Relativity.Cruise.new({
		"origin": origin, "target": tpos, "accel": a,
		"dryMass": vessel.mass - st.prop, "propMass": st.prop,
		"exhaustMS": 299792458.0, "name": vessel.name,
	})
	var p: Dictionary = c.plan
	if not p.feasible:
		# Not enough to stop. The solver says so rather than inventing fuel, and
		# so does the ship: it does not leave.
		_toast("Not enough astrophage to stop at %s — this ship would fly past it" % dname)
		vessel.log_event("Cruise to %s refused: rapidity %s, a flip-and-burn needs %s" % [
			dname, U.fixed(p.budget, 2), U.fixed(p.flipPhi, 2)])
		return
	cruise = c
	cruise_ctx = {
		"coord0": vessel.coord, "met0": vessel.met, "clock_delta0": vessel.clock_delta,
		"parent": vessel.parent, "parent0": vessel.parent.pos.clone(),
		"target": target_body, "target0": (target_body as Body).pos.clone() if target_body != null else null,
		"stage": st, "name": dname, "arrived": false,
		"mission": mission if target_body == null else null,
		"star_pos": _mission_star_pos(mission, origin) if target_body == null and mission != null else null,
	}
	st.ignited = true
	vessel.phase = Vessel.PHASE.CRUISE
	if autopilot != null:
		autopilot.program = "cruise"
		autopilot.say("Interstellar cruise to %s" % dname)
	var dist_txt: String = ("%s ly" % U.fixed(cruise.dist_ly, 2)) if cruise.dist_ly > 0.01 \
		else ("%s AU" % U.fixed(cruise.dist_au, 3))
	vessel.log_event("Cruise to %s — %s at %s g" % [dname, dist_txt, U.fixed(a / Rocketry.G0, 2)])
	vessel.log_event(("Flip-and-burn: %s ship, %s coordinate" % [Relativity.fmt_years(p.tauS / Rocketry.YR_S), Relativity.fmt_years(p.coordS / Rocketry.YR_S)]) if p.mode == "flip"
		else ("Accelerate–coast–decelerate: burn %s ly, coast %s ly, β %s — %s yr ship, %s yr coordinate" % [
			U.fixed(p.burnLy, 2), U.fixed(p.coastLy, 2), U.fixed(p.betaMax, 4), U.fixed(p.tauS / Rocketry.YR_S, 2), U.fixed(p.coordS / Rocketry.YR_S, 2)]))
	# The warp fits the trip: the rung nearest (in ratio) to a crossing of about a
	# minute. Cruise is exact at any step, so no rails interlock.
	var want := 0
	var ideal := log(maxf(float(p.tauS) / 60.0, 1.0))
	for k in WARPS.size():
		if absf(log(float(WARPS[k])) - ideal) < absf(log(float(WARPS[want])) - ideal): want = k
	set_warp(want)

## The drive a cruise flies on: the first attached stage with a photon engine.
func _photon_stage():
	for s in vessel.stages:
		if s.attached and s.spec.get("engine") != null and s.spec.engine.get("photon", false):
			return s
	return null

## The interstellar destinations on offer: the vehicle's own, or the Hail
## Mary's for anything else with a photon drive (the beetles went where it did).
func missions() -> Array:
	if vessel == null or _photon_stage() == null: return []
	var ms = vessel.vehicle.get("missions")
	if ms == null: ms = Vehicles.VEHICLES.hailmary.get("missions", [])
	return ms

func _cruise_target_pos(body, mission, origin: DVec3) -> DVec3:
	if body != null: return (body as Body).pos.clone()
	var d := mission_direction(mission) if mission != null else DVec3.new(1.0, 0.0, 0.0)
	# Stop √L AU out, where the star is as bright as the Sun at Earth.
	return _mission_star_pos(mission, origin).add_scaled_in(d, -_mission_standoff(mission))

func _mission_star_pos(mission, origin: DVec3) -> DVec3:
	var d := mission_direction(mission) if mission != null else DVec3.new(1.0, 0.0, 0.0)
	var ly: float = float(mission.ly) if mission != null else 11.9
	return origin.clone().add_scaled_in(d, ly * Relativity.LY_AU)

func _mission_standoff(mission) -> float:
	return sqrt(maxf(float(mission.get("lum", 1.0)), 1e-6)) if mission != null else 1.0

## A star's direction from J2000 RA (h) and Dec (°): equatorial → ecliptic by the
## obliquity; ecliptic in XZ with north on −Y and the equinox on +X.
static func mission_direction(m) -> DVec3:
	if m == null or m.get("ra") == null: return DVec3.new(1.0, 0.0, 0.0)
	var ra := float(m.ra) * PI / 12.0
	var dec := deg_to_rad(float(m.dec))
	var eps := deg_to_rad(23.4393)
	var xq := cos(dec) * cos(ra)
	var yq := cos(dec) * sin(ra)
	var zq := sin(dec)
	var ye := yq * cos(eps) + zq * sin(eps)
	var ze := -yq * sin(eps) + zq * cos(eps)
	return DQuat.nrm(DVec3.new(xq, -ze, ye))

## Hand the vessel to a new parent body mid-flight, resetting everything the
## local view keeps in that body's frame (see begin()).
func _adopt_parent(body: Body) -> void:
	if vessel.parent == body: return
	var world := vessel.parent.pos.clone().add_scaled_in(vessel.r, 1.0 / Rocketry.AU_M)
	vessel.set_parent(body, bodies())
	vessel.r.copy_from(world.sub_in(body.pos)).scale_in(Rocketry.AU_M)
	planet_spin = 0.0
	DQuat.set_len(anchor_pos.copy_from(vessel.r), float(vessel.env.radius))
	var st_up := DQuat.nrm(vessel.r.clone()).to_v3()
	wind_dir = Vector3(0, -1, 0).cross(st_up).normalized() if absf(st_up.y) < 0.999 else Vector3(1, 0, 0)

## One frame of cruise: advance the exact solution, place the ship, refill the
## orbital readouts.
func _step_cruise(dt: float, sim_seconds: float, advance_world: Callable = Callable()) -> float:
	# One call whatever the warp: the step splits itself at every leg boundary
	# (see Relativity.Cruise.step), so a big one lands exactly as a small one.
	var before: float = cruise.t
	cruise.step(sim_seconds, advance_world)
	var elapsed: float = cruise.t - before
	var ctx: Dictionary = cruise_ctx
	# The line's ends move with their bodies, blended by progress, so there's no jump
	# at either end.
	var total_m: float = maxf(cruise.dist_ly * Relativity.LY_M, 1.0)
	var f := clampf(cruise.s / total_m, 0.0, 1.0)
	cruise.position(_a)
	var par: Body = ctx.parent
	if par.alive: _a.add_scaled_in(_b.sub_vectors(par.pos, ctx.parent0), 1.0 - f)
	var tb = ctx.target
	if tb != null and (tb as Body).alive:
		_a.add_scaled_in(_b.sub_vectors(tb.pos, ctx.target0), f)
		# Past halfway the destination is the body that matters: its name on
		# the panel, its ground and air in local space when the ship gets there.
		if f > 0.5: _adopt_parent(tb)
	vessel.r.copy_from(_a).sub_in(vessel.parent.pos).scale_in(Rocketry.AU_M)
	vessel.v.copy_from(cruise.dir).scale_in(cruise.beta * Rocketry.C_MS)
	vessel.met = float(ctx.get("met0", 0.0)) + cruise.tau
	vessel.coord = float(ctx.get("coord0", 0.0)) + cruise.t
	vessel.clock_delta = float(ctx.get("clock_delta0", 0.0)) + cruise.tau - cruise.t
	var st = ctx.stage
	st.prop = cruise.prop
	var burning: bool = cruise.leg == "accel" or cruise.leg == "decel"
	# Along or against the line of flight (flip-and-burn). At a star, hold broadside to it.
	if cruise.leg == "arrived":
		var side := DVec3.new().cross_vectors(cruise.dir, DVec3.new(0.0, 1.0, 0.0))
		if side.length_sq() < 1e-6: side.set_v(1.0, 0.0, 0.0)
		_q.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), DQuat.nrm(side))
	else:
		var facing := -1.0 if cruise.leg == "decel" else 1.0
		_q.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), _b.copy_from(cruise.dir).scale_in(facing))
	vessel.q.slerp_in(_q, 1.0 - exp(-dt * 1.4))
	# ...and once it has turned, go round to the lit side to look at it.
	if cruise.leg == "arrived" and not ctx.get("framed", false) and vessel.q.dot(_q) ** 2 > 0.9995:
		ctx["framed"] = true
		aim_camera_at_sun(0.6, 0.25, true)
	Relativity.sky_boost(cruise.dir, cruise.beta, _boost_d)
	boost = _boost_d.to_v3()
	# THE READOUTS. Sampled unpowered (nothing about the drive belongs in the
	# Newtonian force sum), then the drive's own numbers written over it.
	vessel.throttle = 0.0
	var t: Dictionary = vessel.sample(0.0)
	var m := maxf(vessel.mass, 1.0)
	var acc: float = cruise.a * cruise.throttle if burning else 0.0
	t.thrust = m * acc
	t.gees = acc / Rocketry.G0
	t.isp = Rocketry.C_MS / Rocketry.G0
	t.mdot = t.thrust / Rocketry.C_MS
	t.twr = t.thrust / (m * maxf(float(t.gSurf), 1e-12))
	# Δv on a photon drive is c times the rapidity left: c·ln(m/m_dry).
	t.dv = Rocketry.C_MS * log(m / maxf(m - cruise.prop, 1.0))
	vessel.throttle = 1.0 if burning else 0.0
	if cruise.leg == "arrived" and not ctx.arrived:
		ctx.arrived = true
		_arrive(tb)
	return elapsed

## End of a crossing: a parking orbit at a body, or a stop at a star.
func _arrive(body) -> void:
	var name_: String = cruise_ctx.name
	var summary := "%s ship, %s coordinate" % [Relativity.fmt_years(cruise.tau / Rocketry.YR_S), Relativity.fmt_years(cruise.t / Rocketry.YR_S)]
	set_warp(0)
	if body == null or not (body as Body).alive:
		boost = Vector3.ZERO
		vessel.throttle = 0.0
		vessel.log_event("Arrived at %s — %s" % [name_, summary])
		_toast("Arrived at %s — %s" % [name_, summary])
		return
	_adopt_parent(body)
	# Parking orbit clear of air, in the arrival plane and longitude.
	var alt := maxf(250000.0, float(vessel.env.radius) * 0.04)
	vessel.place_in_orbit(alt, 0.0, atan2(vessel.r.z, vessel.r.x))
	var st = cruise_ctx.stage
	st.prop = cruise.prop
	var met: float = vessel.met
	var coord: float = vessel.coord
	cruise = null; cruise_ctx = null
	boost = Vector3.ZERO
	vessel.met = met; vessel.coord = coord
	vessel.throttle = 0.0
	if autopilot != null:
		autopilot.program = null; autopilot.mode = Guidance.MODE.PROGRADE
		autopilot.say("In orbit at %s" % (body as Body).name)
	plan = null
	vessel.log_event("Arrived at %s — %s. Parking orbit, %s km" % [name_, summary, U.fixed(alt / 1000.0, 0)])
	_toast("Arrived at %s — in orbit" % name_)

# THE TERMINAL COUNT
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
		# Ignition against the hold-downs.
		vessel.throttle = 1.0
		vessel.log_event("Ignition sequence start")
	if count.t <= 0.0:
		count = null
		vessel.held_down = false
		vessel.log_event("Hold-down release")
		autopilot.engage("ascent")

## The flight panel's program buttons.
func run_program(p: String) -> void:
	if autopilot == null: return
	if cruise != null and cruise.leg != "arrived":
		_toast("In interstellar cruise — nothing to steer until arrival")
		return
	if p == "cruise":
		pending_cruise = null
		begin_cruise(target, null, star_target)
		return
	pending_cruise = null
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

# TIME
func set_warp(i: int) -> void:
	warp_idx = clampi(i, 0, WARPS.size() - 1)
	# Rails interlocks: thrust and drag are not evaluated on rails.
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

## Put the camera on the far side of the vehicle from the sun, the sun `off` rad
## beside it (backlit). `front_lit` goes on the sun's side instead, `off_yaw` round,
## for where nothing else lights the ship.
func aim_camera_at_sun(off_yaw: float = 0.22, off_pitch: float = 0.10, front_lit: bool = false) -> void:
	if vessel == null: return
	if fly_cam.state.mode == "pad" or fly_cam.state.mode == "cockpit": fly_cam.set_mode("chase")
	var un := _local_up_north()
	var up: DVec3 = un[0]
	var north: DVec3 = un[1]
	var east := DQuat.nrm(DVec3.new().cross_vectors(up, north))
	var sun := sun_direction(DVec3.new())
	var sun_l := Vector3(sun.dot(east), sun.dot(up), sun.dot(north)).normalized()
	# the same turntable basis FlightCamera.place() builds
	var fb := Basis(east.to_v3(), up.to_v3(), north.to_v3())
	var cb := fb.transposed() * Basis(vessel.q.to_quaternion())
	var uu: Vector3 = (cb * Vector3(0, 1, 0)) if fly_cam.state.mode == "chase" else Vector3.UP
	uu = uu.normalized()
	var ref := Vector3(1, 0, 0) if absf(uu.y) > 0.95 else Vector3(0, 1, 0)
	var right := uu.cross(ref).normalized()
	var fwd := right.cross(uu).normalized()
	fly_cam.state.userAimed = true
	if front_lit:
		# Camera offset = +sun, turned off it. A sun near the vehicle's axis would put the
		# camera on the axis too, so hold it near broadside, tipped 17° sunward.
		var su := sun_l.dot(uu)
		fly_cam.state.yaw = atan2(sun_l.dot(fwd), sun_l.dot(right)) + off_yaw
		fly_cam.state.pitch = signf(su) * 0.3 if absf(su) > 0.75 \
			else clampf(asin(clampf(su, -1.0, 1.0)) + off_pitch, -1.45, 1.45)
		return
	# camera offset from the vehicle = −sun: it looks through the vehicle at it
	fly_cam.state.yaw = atan2(-sun_l.dot(fwd), -sun_l.dot(right)) + off_yaw
	fly_cam.state.pitch = clampf(asin(clampf(-sun_l.dot(uu), -1.0, 1.0)) + off_pitch, -1.45, 1.45)

# TARGETING
func refresh_targets() -> void:
	if hud == null: return
	var names := []
	# A ship that can cross to another star lists the stars first: they are
	# what it is for, and they are not bodies in the scenario.
	for m in missions(): names.append(MISSION_PREFIX + str(m.name))
	for b in bodies(): names.append(b.name)
	var cur = null
	if target != null: cur = target.name
	elif star_target != null: cur = MISSION_PREFIX + str(star_target.name)
	hud.set_targets(names, cur)

func set_target(n) -> void:
	star_target = null
	target = null
	pending_cruise = null
	if n != null and str(n).begins_with(MISSION_PREFIX):
		var want := str(n).substr(MISSION_PREFIX.length())
		for m in missions():
			if str(m.name) == want: star_target = m
	else:
		target = body_named(n) if n != null and n != "" else null
	plan = null
	if autopilot != null:
		autopilot.target = target
		autopilot.plan = null

# UPDATE
## dt is wall time; returns accepted coordinate seconds (cruise requests ship proper time).
## advance_world advances the orrery and returns its accepted coordinate seconds.
func update(dt: float, _frame = null, advance_world: Callable = Callable()) -> float:
	if not active or vessel == null: return 0.0
	vessel.bodies = bodies()
	if not vessel.bodies.has(vessel.parent):
		var d := dominant()
		if d != null: vessel.rebase(d)
		else:
			active = false
			return 0.0

	# Slave the orrery's clock every frame, or the slider desyncs planets and vehicle.
	state.time_scale = WARPS[warp_idx] / Rocketry.YR_S
	# At warp 1 flight time is wall-clock time; the orrery multiplier is forced to 1.
	var w: float = warp() * (0.0 if state.paused else 1.0)
	var sim_seconds := dt * w
	var control_frame := {"guided": false, "fraction": 1.0}
	var world := func(seconds: float) -> float:
		var accepted: float = advance_world.call(seconds)
		control_frame.fraction = clampf(accepted / seconds, 0.0, 1.0) if seconds > 0.0 else 0.0
		vessel.bodies = bodies()
		if not vessel.bodies.has(vessel.parent) or not vessel.parent.alive:
			var d := dominant()
			if d != null: vessel.rebase(d)
			else:
				active = false
				vessel.phase = Vessel.PHASE.DESTROYED
		return accepted
	var opts := {}
	if advance_world.is_valid(): opts.advance_world = world

	if cruise != null:
		# Ship proper time is the natural variable in cruise — the drive, the
		# fuel and the crew all live on it.
		sim_seconds = _step_cruise(dt, sim_seconds, world if advance_world.is_valid() else Callable())
	else:
		boost = Vector3.ZERO
		if not advance_world.is_valid():
			if count != null: step_count(sim_seconds)
			if sim_seconds > 0.0 and autopilot != null: autopilot.update(minf(dt, 0.1))
		else:
			# Stateful guidance keeps its frame cadence; countdown uses every accepted interval.
			opts.controls = func(seconds: float) -> void:
				if count != null: step_count(seconds)
				if not control_frame.guided and autopilot != null:
					control_frame.guided = true
					autopilot.update(minf(dt * control_frame.fraction, 0.1))
			opts.control_may_thrust = count != null or (autopilot != null and autopilot.program != null)
		# Physics warp up to 4×; above that the vessel goes on rails, which is
		# only legal unpowered and out of the air (checked inside step()).
		var rails: bool = w > 4.0 and vessel.can_rail() and not opts.get("control_may_thrust", false)
		if rails:
			opts.rails = true
			sim_seconds = vessel.step(sim_seconds, opts)
		else:
			# Sub-step so a big real-time dt never becomes one huge integration.
			var rem := sim_seconds
			var guard := 0
			var elapsed := 0.0
			var was_guarded: bool = vessel.step_guard_hit
			while rem > 1e-6 and guard < 24:
				guard += 1
				var h := minf(rem, 0.5 * maxf(w, 1.0))
				var advanced: float = vessel.step(h, opts)
				elapsed += advanced
				rem -= advanced
				if vessel.step_guard_hit: break
			if rem > 1e-6 and not vessel.step_guard_hit:
				vessel.step_guard_hit = true
				if not was_guarded:
					vessel.log_event("Flight frame limit — advanced %s of %s s; reduce time warp" % [U.fixed(elapsed, 3), U.fixed(sim_seconds, 3)])
			sim_seconds = elapsed
		if w > 4.0 and not vessel.can_rail(): set_warp(2)
		if pending_cruise != null:
			begin_cruise(pending_cruise.body, pending_cruise.accel, pending_cruise.mission)

	if not advance_world.is_valid(): finish_frame(dt, sim_seconds)
	return sim_seconds

func finish_frame(dt: float, coordinate_seconds: float) -> void:
	if not active or vessel == null: return
	update_visual(dt, coordinate_seconds)
	if hud != null: update_hud()

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

	# Light from each star at 1/r² from the vessel's position.
	var srcs := light_sources()
	var key = srcs[0] if not srcs.is_empty() else null
	var second = srcs[1] if srcs.size() > 1 else null
	var f_key: float = float(key.flux) if key != null else 1.0
	var f_total := STARLIGHT
	for L in srcs: f_total += float(L.flux)
	# Auto-exposure: target brightness F^0.3 below daylight (floor 0.06), none above;
	# eased in log over ~1.5 s.
	var shown := f_total if f_total >= 1.0 else maxf(pow(f_total, 0.3), 0.06)
	# Metering: away from a planet's shine, open up by up to 1.8× (800 km → a few 1000 km).
	shown *= lerpf(1.0, 1.8, U.smooth(alt, 8.0e5, 5.0e6))
	var want_e := shown / f_total
	if exposure <= 0.0: exposure = want_e
	else: exposure = exp(lerpf(log(exposure), log(want_e), 1.0 - exp(-maxf(dt, 0.0) / 1.5)))
	var star_flux := f_key * exposure
	# Shadow lift below 1% of daylight, so the unlit side of a ship between the stars
	# stays readable. Off inside ~10 AU.
	var shadow_lift := U.smooth(-log(maxf(f_total, 1e-30)), -log(0.01), -log(1e-4))
	# Advance the fixed launch site before sampling the map. Its rotation and
	# the local ground's geographic frame must describe the same instant.
	if site != null and site_pos != null:
		if vessel.phase == Vessel.PHASE.PRELAUNCH:
			site_pos.copy_from(vessel.r)
		else:
			# ω × r — see AGENTS.md: a point fixed to a rotating body.
			_a.set_v(0.0, -float(env.rotRate), 0.0).cross_vectors(_a, site_pos)
			DQuat.set_len(site_pos.add_scaled_in(_a, sim_seconds), float(env.radius))
	# The planet turns under the frame; see planet_spin.
	planet_spin = fposmod(planet_spin + float(env.rotRate) * sim_seconds, TAU)
	_a.set_v(0.0, -float(env.rotRate), 0.0).cross_vectors(_a, anchor_pos)
	DQuat.set_len(anchor_pos.add_scaled_in(_a, sim_seconds), float(env.radius))
	var fr := local.update({"env": env, "altitude": alt, "sunDirWorld": sun, "upWorld": up, "northWorld": north,
		"starFlux": star_flux, "padWorld": site_pos, "mapSite": map_site,
		"planetSpin": planet_spin, "anchorWorld": anchor_pos, "dt": dt,
		# a steady 9 m/s westerly, the trade-wind belt's upper flow reversed
		"cloudWind": wind_dir * (9.0 * vessel.met),
		"sunAngR": float(key.ang_r) if key != null else 0.00465,
		"sunTeff": float(key.teff) if key != null else 5772.0,
		# the other sun, and the sky's own light, through the same exposure
		"sun2World": second.dir if second != null else null,
		"sun2Flux": float(second.flux) * exposure if second != null else 0.0,
		"sun2Teff": float(second.teff) if second != null else 5772.0,
		"starlight": maxf(STARLIGHT * exposure, 0.05 * shadow_lift)})
	# Sky exposure ∝ 1/illuminance (1/400 at Earth), eased (SkyModel.apply_day_gain).
	var want := 1.0 / (1.0 + 400.0 * f_key * float(fr.get("sun_visible", 0.0)))
	sky_gain += (want - sky_gain) * (1.0 - exp(-maxf(dt, 0.0) / 0.8))
	SkyModel.apply_day_gain(pipe.sky_materials, sky_gain)

	# Attitude in the local frame (+Y = local up).
	var east := DQuat.nrm(DVec3.new().cross_vectors(up, north))
	frame_basis = Basis(east.to_v3(), up.to_v3(), north.to_v3())
	var craft_basis := frame_basis.transposed() * Basis(vessel.q.to_quaternion())
	craft_pos.set_v(0.0, alt, 0.0)
	craft.group.position = Vector3.ZERO
	craft.group.basis = craft_basis.orthonormalized()

	# ---- the launch complex. The local origin is under the vehicle, so the pad moves
	# back through the frame. Exact: a point θ away is (R sinθ, R(cosθ−1), …), the same
	# drop the ground patch uses, so the pad sits on the ground.
	if site != null and site_pos != null:
		var sx: float = site_pos.dot(east)
		var sy: float = site_pos.dot(up) - float(env.radius)
		var sz: float = site_pos.dot(north)
		site_local.set_v(sx, sy, sz)
		# Drop the ground patch by the deck height and the hardstand's rise (grade_drop).
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
		# Put the camera on the sunlit side once the sun's local azimuth is known.
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

	# The light the plumes' smoke scatters: the sun where it reaches the
	# vehicle (clouds included), with a floor for the sky's own light.
	var sl: Vector3 = fr.get("sun_local", Vector3.UP)
	Plume.daylight = clampf(sl.y * 2.0 + 0.25, 0.0, 1.0) * local.sun_through * clampf(star_flux, 0.05, 4.0) + 0.04
	Plume.sprite_material(false, 2, Plume.ORDER_SMOKE).set_shader_parameter("uLight", clampf(Plume.daylight, 0.08, 1.4))
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
		pad_fire.update(lit if site.group.visible else 0.0, alt + site.deck_height, plume_reach, vessel.met)

	# launch smoke: only where there is an atmosphere and a surface to hit
	if env.atm != null and alt < 900.0 and vessel.throttle > 0.0 and float(vessel.telemetry.get("thrust", 0.0)) > 0.0:
		# Soot from the propellant: alumina (solid), carbon (RP-1), steam (hydrogen).
		var soot := 0.7
		var s0 = vessel.stages[0].spec if not vessel.stages.is_empty() else null
		if s0 != null and s0.get("engine") != null and Plume.PROPELLANT.has(s0.engine.get("plume", "")):
			soot = Plume.PROPELLANT[s0.engine.plume].soot
		smoke.emit(Vector3(0.0, maxf(alt - vessel.length * 0.5, 0.0), 0.0),
			vessel.throttle, maxf(vessel.diameter * 2.2, 12.0), dt, soot)
	smoke.update(dt)
	rcs_puffs.update(dt)

	# Hand the pad camera over to chase once the vehicle climbs out of frame.
	if fly_cam.state.mode == "pad" and alt > maxf(craft.height * 22.0, 1500.0):
		fly_cam.set_mode("chase")
		vessel.log_event("Camera — pad view lost, tracking from the vehicle")

	# ---- cameras. The local camera is real; the orrery camera is slaved to it.
	var sun_l := Vector3(sun.dot(east), sun.dot(up), sun.dot(north)).normalized()
	fly_cam.update({"craftPos": craft_pos, "craftBasis": craft_basis,
		"length": craft.height if craft.height else vessel.length, "up": Vector3(0, 1, 0),
		"dt": dt, "sunLocal": sun_l})
	local.cam_pos.copy_from(fly_cam.pos)
	# Keep far/near ≤ ~1e7 (docs/godot.md): near is floored at far·1e-7 = 0.4 m.
	local.camera.far = 4.0e6
	local.camera.near = maxf(fly_cam.near, local.camera.far * 1.0e-7)
	local.camera.fov = 55.0
	local.apply_origin(fly_cam.basis)
	# Back to front for this frame's camera, now that it is placed.
	smoke.draw(local.camera, site.steam if site != null else null)

	# Map the local camera into the orrery, in double (it is the floating origin).
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
		# Near stated explicitly: main.gd ties far to it, and a close-up's 1e-6 would cull
		# every planet past 10 scene units.
		main.cam_near = 0.01

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
	elif star_target != null and _photon_stage() != null:
		var st = _photon_stage()
		var budget := Relativity.rapidity_budget(vessel.mass - st.prop, st.prop, Rocketry.C_MS)
		var a := float(U.nz(star_target.get("accel"), 1.5)) * Rocketry.G0
		plan_data = FlightUI.mission_block(str(star_target.name), float(star_target.ly),
			Relativity.solve_profile(float(star_target.ly), a, budget))
	if warp_idx != _warp_shown:
		_warp_shown = warp_idx
		if main != null and main.has_method("sync_warp_label"): main.sync_warp_label()
	hud.update({
		"vessel": vessel, "telemetry": t, "up": (un[0] as DVec3).to_v3(), "north": (un[1] as DVec3).to_v3(),
		"markers": markers,
		"status": ("Interstellar cruise — %s" % cruise.leg) if cruise != null else (autopilot.status if autopilot != null else "Manual control"),
		"mode": autopilot.mode if autopilot != null else null,
		"program": autopilot.program if autopilot != null else null,
		"warp": str(warp()),
		"parentName": vessel.parent.name,
		"plan": plan_data,
		"cruise": cruise != null,
	})

func set_size(w: float, h: float) -> void:
	local.set_size(w, h)

# INPUT
## The orchestrator resolves configurable physical keys before dispatching the
## flight action. Returns true when the active vessel accepted it.
func key_action(action: String) -> bool:
	if not active or vessel == null: return false
	match action:
		"warp_down":
			set_warp(warp_idx - 1); return true
		"warp_up":
			set_warp(warp_idx + 1); return true
		"throttle_cut":
			vessel.throttle = 0.0; return true
		"throttle_full":
			vessel.throttle = 1.0; return true
		"throttle_up":
			vessel.throttle = minf(1.0, vessel.throttle + 0.06); return true
		"throttle_down":
			vessel.throttle = maxf(0.0, vessel.throttle - 0.06); return true
		"stage":
			vessel.stage(); return true
		"gear":
			for st in vessel.stages:
				if st.attached and st.spec.get("legs"):
					st.gear_out = not st.gear_out
					break
			return true
		"flight_camera":
			var modes := ["chase", "orbit", "cockpit", "pad"]
			var i := modes.find(fly_cam.state.mode)
			fly_cam.set_mode(modes[(i + 1) % modes.size()])
			return true
	return false

## The pad camera is a tripod you can walk round the vehicle and raise up the tower,
## kept as an offset from the (moving) pad.
func pad_orbit(d_az: float, d_el: float, scale: float) -> void:
	var r := Vector2(pad_offset.x, pad_offset.z).length()
	if r == 0.0: r = 1.0
	var az := atan2(pad_offset.z, pad_offset.x) + d_az
	# Elevation is a height, so raising doesn't walk in. Floor at head height.
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
