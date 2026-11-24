class_name Spaceflight
extends RefCounted

# Coordinate local SI flight, AU-world motion, modes and camera placement.
# Accepted coordinate seconds cross the world boundary as years; the local
# floating origin and rotated camera offset slave the orrery camera. See AGENTS.md.

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
var cryo: Cryo = null             # frost and boil-off on the vehicle's cold tanks
var vapour: Vapour = null         # condensation collars round its shoulders, in humid air
var craft = null                  # CraftModel.Craft
var interior := CraftInterior.new()
var arms_out := false
var exterior_fov := 55.0
var plumes: Array = []            # Plume.PlumeFx
var sep_plumes: Array = []        # separation motors: [{fx, stage, mount}], see attach_sep_motors
## Dropped pieces flying on their own (Fall) once Separation is done with them.
var falls: Array = []
## The Fall the camera and the local frame follow, or null for the vehicle.
var subject: Fall = null
var entry = null                  # Plume.EntryGlow
var cruise = null                 # Relativity.Cruise
var kerr_demo: Dictionary={}
var berth_pan := Vector2.ZERO
var berth_zoom := 1.0
var docking: DockingSession
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
## The mission the autopilot is flying end to end, or null (sim/flight/mission.gd).
var mission: Mission = null
## A skip in progress: {until: coordinate s, mission}. The world runs at SKIP_WARP
## while the vessel waits on rails, then it is put in the destination's parking orbit.
var skip = null
const SKIP_WARP := 10000000.0
var saved_speed = null            # the orrery's own speed multiplier, parked for the flight
var warp_idx := 0
var active := false
## Off while the orchestrator is undrawn (main.set_drawn): no HUD and no smoke drawn.
## Without `history` only what physics reads goes on (falls, the pad's rotation, the
## separation hand-offs); plumes, smoke, the pad's motion and the cameras wait.
var drawn := true
var history := true
## The flight's own random choices (parking phases). The presentation draws from the
## global generator, so with this one drawing or not cannot change a flight.
var phase_rng := RandomNumberGenerator.new()
var hud: FlightUI = null
var console: FlightConsole = null
var target: Body = null
## A Lagrange point picked on the space map as a navigation target: {pri, sec, idx}, or null.
var nav_point = null
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
var craft_pos := DVec3.new()      # the vehicle in the local frame: (0, alt, 0) unless following a Fall
var ground_pos := DVec3.new()     # the ground patch's own offset (0, −gradeDrop, 0)
## The landing survey the vessel stands on (vessel.ground), drawn once it is the ground.
var ground_site: SurfaceSite = null
var plume_dust: PlumeDust = null    # what a landing's jet raises from the drawn site
var dust_devils: DustDevils = null  # a dry world's afternoon vortices about the drawn site
## A showcase's stated weather at the site (SurfaceWeather.stated): {storm, devils}. Empty: the world's own.
var weather_stated := {}
## The recovery area as drawn, once the vessel's SurfaceSea is stood on.
var sea_site: SurfaceSite = null
var _sea_level_y := 0.0
var _drawn_ground: SurfaceGround = null
## Where the drawn site stands in the local frame this frame: origin and basis.
var _site_at := DVec3.new()
var _site_basis := Basis()
## How far over the drawn site the camera's eye is kept, m.
const CAMERA_CLEAR := 1.5
## A surface vehicle off a landed one (vehicle.rover): its physics on the adopted ground, stepped on the
## flight clock drawn or not, and what draws it. `driving` gives it the keys and the camera.
var rover: Rover = null
var rover_model: RoverModel = null
var rover_dust: RoverDust = null
var rover_tracks: RoverTracks = null
var rover_arm: RoverArm = null
var driving := false
## Whether the keys drive it; a script that sets the rover's throttle and steering itself turns this off.
var rover_keys := true
## A helicopter off the rover (Ingenuity off Perseverance): its physics on the same ground and clock, what
## draws it, and whether it has the keys and the camera.
var heli: Rotorcraft = null
var crane_rig: SkyCraneRig = null  # the Sky Crane's bridles, heat shield and flyaway, drawn only
var _crane_marks := {}             # met of the heat shield's drop, the bridles' start and touchdown
var heli_model: RotorcraftModel = null
var flying := false
## A flyer let go from its shell (Dragonfly) flies itself down before it is given the keys: under this height
## it looks for ground less steep than this to set down on (estimates).
var autoland := false
const AUTOLAND_LOOK := 40.0
const AUTOLAND_SLOPE := 0.21
var _render_quality := "medium"
var site_local := DVec3.new()     # the complex in the local frame
var origin_pos := DVec3.new()     # (0, 0, 0): the sky dome and the smoke
var frame_basis := Basis()        # local → world (columns east, up, north)

## The vehicle picker's list: {key, ...the vehicle Dictionary} in display order.
var vehicles: Array = []
var warp_list := WARPS
var local_camera: Camera3D
## A console handle on local space, in the same spirit as window.SIM.
var local_view: LocalView
## Optional (fly_cam, craft_pos, site_local, dt): repositions fly_cam after its own
## update. The title reel frames its launch shot through it.
var camera_override := Callable()
## The effects lab (tools/fxlab.gd): {alt (m), speed (m/s of airspeed), pitch (rad from
## vertical, toward the east), throttle}. The vehicle is held there with the air
## streaming past it, which for the plume, the trail and the vapour is the same as
## flying through still air. Null in flight.
var lab = null
## Set by a scenario's fast-forward (FlightScenarios.Jump): 1 updates only what
## accumulates history (the pad, separations, falling pieces, plumes, the smoke and
## its trail), 2 only what physics and the pad read; neither touches the sky, the
## lighting or the cameras. 0 draws.
var fast_forward := 0
## Developer time warp (Settings › Developer), or 0: integrated at this rate whatever
## the vehicle is doing, with the rails and atmosphere interlocks off.
var dev_warp := 0.0

var _q := DQuat.new()
var _a := DVec3.new()
var _b := DVec3.new()
var _spectrum_met := -INF
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
	# A closed cabin excludes exterior lights: the local pass casts no hull shadows.
	for light in [local.sun, local.sun2] + local.hemi:
		(light as Light3D).light_cull_mask &= ~CraftInterior.LAYER
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
		var con = ctx.get("console")
		if con != null:
			console = FlightConsole.new()
			con.add_child(console)
		hud = FlightUI.create_flight_hud(panel, {
			"console": console,
			"setMode": func(m: String) -> void:
				if autopilot != null and docking == null:
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

## The longitude on `body` where it is mid-morning (spin along −Y in its own
## equatorial frame, so earlier is a smaller longitude).
func morning_longitude(body: Body) -> float:
	var src: Body = null
	for b in _stars():
		if b.mass > (src.mass if src != null else -1.0): src = b
	if src == null or src == body: return 0.0
	var a := DQuat.rotate(DVec3.new().sub_vectors(src.pos, body.pos), Rocketry.spin_frame(body).invert())
	var sub := atan2(a.z, a.x) * 180.0 / PI
	# 22° west of the subsolar meridian. How high that puts the sun follows the
	# season: 55° at a 28.5° pad at an equinox, 34° in early January.
	return sub - 22.0

## The brightest star's direction from the vessel, for lighting the model.
func sun_direction(out: DVec3) -> DVec3:
	var src := light_sources()
	if src.is_empty() or vessel == null:
		var d := dominant()
		if d == null or vessel == null: return out.set_v(0.0, 1.0, 0.0)
		vessel.body_offset(d, out).sub_in(vessel.r)
		return DQuat.nrm(out)
	return out.copy_from(src[0].dir)

## Where the vessel is in the orrery's frame, AU.
func ship_world(out: DVec3 = null) -> DVec3:
	return vessel.world_pos(out)

## Every star lighting the vessel, brightest first: {dir (unit DVec3 toward the
## star, in the vessel's parent frame), flux (relative to the Sun at Earth, from the
## vessel's position), teff, ang_r, body when it is one}. Includes an interstellar mission's destination.
func light_sources() -> Array:
	var out := []
	if vessel == null: return out
	var w := ship_world()
	for b in _stars():
		var d := DVec3.new().sub_vectors(b.pos, w)
		var r := maxf(d.length(), 1e-6)
		out.append({"dir": vessel.to_local(d.scale_in(1.0 / r), d), "flux": float(U.nz(b.luminosity, 1.0)) / (r * r),
			"teff": float(U.nz(b.teff, 5772.0)), "ang_r": b.radius / r if b.radius > 0.0 else 0.00465 / r,
			"kp": Stellar.storm_kp(b.activity), "body": b})
	if cruise_ctx != null and cruise_ctx.get("star_pos") != null:
		var m: Dictionary = cruise_ctx.mission
		var d := DVec3.new().sub_vectors(cruise_ctx.star_pos, w)
		var r := maxf(d.length(), 1e-6)
		out.append({"dir": vessel.to_local(d.scale_in(1.0 / r), d), "flux": float(m.get("lum", 1.0)) / (r * r),
			"teff": float(m.get("teff", 5772.0)), "ang_r": float(m.get("radius", 1.0)) * 0.00465047 / r})
	out.sort_custom(func(a, b): return a.flux > b.flux)
	return out

# LAUNCH / SPAWN
## opts: {mode: "pad"|"orbit"|"return", body, lat, lon, alt, inc}, plus harness hooks
## `phase` (orbit phase), `vehicle` (a vehicle Dictionary to fly instead) and
## `catch_at` (a return started part-way down, CatchTower.begin_return).
func begin(vehicle_key: String, opts: Dictionary = {}):
	var returning: bool = opts.get("mode") == "return"
	var veh = opts.get("vehicle", Vehicles.booster_return(vehicle_key) if returning else Vehicles.VEHICLES.get(vehicle_key))
	if veh == null: return null
	teardown()
	fly_cam.state.interiorYaw = 0.0
	fly_cam.state.interiorPitch = float(veh.get("interior", {}).get("pitch", 0.18))

	var home := body_named(opts.get("body", veh.get("launchFrom") if veh.get("launchFrom") != null else "Earth"))
	if home == null: home = body_named("Earth")
	if home == null: home = dominant()
	if home == null:
		_toast("No body to fly from in this scenario")
		return null
	if home.type=="bh" and not opts.get("kinematic",false):
		_toast("Use the kinematic Kerr scenario for flight near this black hole")
		return null

	vessel = Vessel.new({"vehicle": veh, "parent": home, "bodies": bodies(),
		"payload": float(veh.carries.mass) if veh.get("carries") != null else 0.0})
	if main != null and "_cmd" in main: vessel.ground_seed = int(main._cmd.get("seed", 0))
	if returning:
		# The booster comes home to the tower it left (CatchTower.begin_return).
		var pad_ll = EARTH_PADS.get(vehicle_key, EARTH_PADS.default) if home.name == "Earth" else {"lat": 28.5, "lon": 0.0}
		vessel.place_on_pad(float(pad_ll.lat), morning_longitude(home))
		map_site = {"lat": float(pad_ll.lat), "lon": float(pad_ll.lon)} if home.name == "Earth" else null
		site_pos = vessel.r.clone()
		var pad_up := DQuat.nrm(site_pos.clone())
		var east := DQuat.nrm(DVec3.new().cross_vectors(DVec3.new(0.0, -1.0, 0.0), pad_up))
		CatchTower.begin_return(vessel, site_pos.clone(), east, opts.get("catch_at"))
		fly_cam.set_mode("chase")
		fly_cam.state.hasPad = true
	elif veh.role == "launch" and opts.get("mode") != "orbit":
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
		if alt == null: alt = float(veh.get("orbitAltitude",15000.0 if veh.role == "lander" else 250000.0))
		var ph = opts.get("phase")
		if ph == null: ph = phase_rng.randf() * 6.28
		vessel.place_in_orbit(float(alt), float(opts.get("inc", 0.0)), float(ph))
		fly_cam.set_mode("chase")
		fly_cam.state.hasPad = false
	vessel.vehicle_key = vehicle_key
	planet_spin = 0.0
	DQuat.set_len(anchor_pos.copy_from(vessel.r), vessel.surface_r(vessel.r))
	# east at the start, in the planet-fixed frame (which is the world frame
	# at spin 0): ω̂ × r̂ with ω̂ = −Y
	var st_up := DQuat.nrm(vessel.r.clone()).to_v3()
	wind_dir = Vector3(0, -1, 0).cross(st_up).normalized() if absf(st_up.y) < 0.999 else Vector3(1, 0, 0)
	autopilot = Guidance.Autopilot.new(vessel)
	autopilot.mode = Guidance.MODE.PROGRADE

	craft = CraftModel.build_craft(veh)
	local.craft_root.add_child(craft.group)
	crane_rig = SkyCraneRig.attach(craft)
	_crane_marks = {}
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
		# A returning booster's tower stands west of the pad, arms reaching east
		# (CatchTower.out); a launch turns the complex to the vehicle's roll.
		site.group.rotation.y = 0.0 if returning else atan2(-cb.x.z, cb.x.x)
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
	cryo = Cryo.build(craft)
	var atm = vessel.env.get("atm")
	vapour = Vapour.create(craft) if atm != null and atm.get("humid", false) else null
	entry = Plume.create_entry_glow(craft)

	fly_cam.state.dist = 3.2
	active = true
	mission = null
	skip = null
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

func begin_kerr(vehicle_key: String,body_name: String,radius_rg: float,phase: float) -> bool:
	var hole:=body_named(body_name)
	if hole==null or hole.type!="bh" or bodies().size()!=1:return false
	var rg:=Rocketry.GM_SUN*hole.mass/pow(Rocketry.C_MS,2)
	var orbit:=KerrCircular.parameters(hole.mass,float(hole.structure.get("spin",0.0)),radius_rg*rg)
	if not orbit.ok or not is_finite(phase):return false
	var start_alt:=float(orbit.radius)-float(Rocketry.flight_env(hole).radius)
	if begin(vehicle_key,{"mode":"orbit","body":body_name,"alt":start_alt,"phase":phase,"kinematic":true})==null:return false
	# The local renderer needs a radius datum; the HUD reports BL radius instead
	# of interpreting distance above this horizon as an ordinary planet altitude.
	vessel.env.radius=float(hole.structure.horizonAU)*Rocketry.AU_M
	vessel.env.atm=null;vessel.env.rotRate=0.0
	vessel.on_rebase=Callable();autopilot=null;target=null
	var prior_aim:={"yaw":fly_cam.state.yaw,"pitch":fly_cam.state.pitch,"userAimed":fly_cam.state.userAimed}
	kerr_demo={"orbit":orbit,"phase":phase,"elapsed":0.0,"mass":hole.mass,"spin":orbit.spin,"priorAim":prior_aim}
	# This oblique view sees both the disc and escaping rays at the scenario radius.
	set_camera_mode("orbit")
	fly_cam.state.merge({"yaw":1.98,"pitch":-.775,"dist":3.05,"fov":48.0,"userAimed":true},true)
	_step_kerr(0.0,Callable())
	vessel.log_event("Kinematic Kerr circular orbit — clock compared with infinity")
	return true

func _step_kerr(requested: float,advance_world: Callable) -> float:
	var orbit: Dictionary=kerr_demo.orbit
	if vessel.bodies.size()!=1 or vessel.parent.type!="bh" or vessel.parent.mass!=kerr_demo.mass \
		or vessel.parent.structure.get("spin")!=kerr_demo.spin:
		state.paused=true
		return 0.0
	var accepted:=requested
	if requested>0.0 and advance_world.is_valid():accepted=float(advance_world.call(requested))
	accepted=clampf(accepted,0.0,requested) if is_finite(accepted) else 0.0
	var proper:=accepted*float(orbit.properRate)
	kerr_demo.elapsed+=accepted
	vessel.coord+=accepted;vessel.met+=proper;vessel.clock_delta+=proper-accepted
	vessel.step_guard_hit=accepted+1e-9<requested
	var pose:=KerrCircular.sample(orbit,kerr_demo.elapsed,kerr_demo.phase)
	vessel.r.copy_from(pose.r);vessel.v.copy_from(pose.v)
	vessel.q.set_from_unit_vectors(Vessel.BODY_FWD,(pose.v as DVec3).normalized())
	vessel.omega.set_v(0,0,0);vessel.throttle=0.0
	vessel.telemetry={"kerr":orbit,"mass":vessel.mass,"period":orbit.period,
		"centrifuge":Centrifuge.telemetry(vessel.stages,vessel.met)}
	return accepted

func begin_docking(carrier: String,slot: String,gap: float) -> bool:
	if vessel==null or vessel.phase!=Vessel.PHASE.ORBIT or docking!=null or not kerr_demo.is_empty():return false
	berth_pan = Vector2.ZERO
	berth_zoom = 1.0
	docking=DockingSession.create(vessel,carrier,slot,gap)
	if docking==null:return false
	arms_out = false
	for st in vessel.stages: st.gear_out = false
	autopilot.mode=Guidance.MODE.OFF
	local.root.add_child(docking.craft.group)
	local.place(docking.craft.group,docking.render_pos)
	set_warp(0)
	return true

func _step_docking(requested: float,advance_world: Callable) -> float:
	if requested<=0.0 or docking.failure!="":return 0.0
	if docking.latched:return docking.step_linked(vessel,requested,bodies(),advance_world)
	var accepted:=vessel.step(requested,{
		"advance_world":func(seconds: float) -> float:return docking.advance(seconds,bodies(),advance_world),
		"controls":func(seconds: float) -> void:docking.steer(vessel,seconds),
		"control_may_thrust":true,
	})
	if accepted>0.0:docking.after_step(vessel)
	if docking.failure!="":
		vessel.log_event("Docking stopped — "+docking.failure)
		state.paused=true
	return accepted

func build_plumes(_veh: Dictionary) -> void:
	for p in plumes:
		if is_instance_valid(p.mesh) and p.mesh.get_parent() != null: p.mesh.get_parent().remove_child(p.mesh)
	var built := attach_plumes(craft)
	plumes = built.plumes
	plume_reach = built.reach
	for b in sep_plumes:
		if is_instance_valid(b.mount): b.mount.queue_free()
	sep_plumes = attach_sep_motors(craft)

## Separation-motor plumes, one per site in `look.sep.motors`, on each piece of the
## stage (or on the stage). Dark until the stage separates. Returns [{fx, stage, mount}].
static func attach_sep_motors(craft: CraftModel.Craft) -> Array:
	var out := []
	for st: CraftModel.CraftStage in craft.stages:
		var m = st.spec.get("look", {}).get("sep", {}).get("motors")
		if m == null: continue
		# Isp is a solid's; it only sets how much exhaust the plume carries.
		var eng := {"name": "BSM", "thrustVac": float(m.thrust), "ispVac": 250.0}
		var bodies: Array = st.parts.pieces if not st.parts.pieces.is_empty() else [st.group]
		for body: Node3D in bodies:
			var side := signf(body.position.x) if body.position.x != 0.0 else 1.0
			for k in (m.sites as Array).size():
				var site: Array = m.sites[k]
				# The jet runs down its mount's −Y, against the push.
				var y_ax := -Separation.exhaust_dir(m, site, side)
				var x_ax := y_ax.cross(Vector3(0, 0, 1) if absf(y_ax.z) < 0.9 else Vector3(1, 0, 0)).normalized()
				var mount := Node3D.new()
				mount.name = "sepmotor_%d" % k
				mount.transform = Transform3D(Basis(x_ax, y_ax, x_ax.cross(y_ax)), Separation.motor_point(site, side))
				var fx := Plume.create_plume("solid", float(m.exitD), 18.0, eng, "single", float(k) + side * 7.0)
				mount.add_child(fx.mesh)
				body.add_child(mount)
				fx.stage_key = st.key
				out.append({"fx": fx, "stage": st, "mount": mount})
	return out

## Hang each engine's plume on a built craft. Returns {plumes, reach}: reach is how
## far the first stage's jet carries, m.
static func attach_plumes(craft: CraftModel.Craft) -> Dictionary:
	var plumes: Array = []
	var plume_reach := 0.0
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
			far.thrust *= pivots.size()
			far.mesh.position = centre
			st.group.add_child(far.mesh)
			if st == craft.stages[0] or plume_reach == 0.0: plume_reach = maxf(plume_reach, far.reach)
			far.stage_key = str(owner_spec.key)
			far.engine = eng
			plumes.append(far)
			lead = far
		if lead != null: Plume.add_flame_light(lead, lead.exit_d)
	return {"plumes": plumes, "reach": plume_reach}

## A pivot's exit plane and width, measured off the mesh, and which engine it is
## (Starship mixes sea-level and vacuum Raptors, told apart by bell size).
static func _measure_bell(pv: Node3D, spec: Dictionary) -> Dictionary:
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

## Near-ground wind for the smoke, m/s in the local frame: a light easterly drift
## (+x is east) and a little from the south.
const PAD_WIND := Vector3(5.0, 0.0, 1.5)

var _smoke_basis := Basis()
var _smoke_origin := DVec3.new()
var _smoke_framed := false

## The local frame moves with the vehicle and the planet turns under it; the smoke
## belongs to the air, so re-express it: x' = B'ᵀ(B x + O + ω×O·t − O').
func _reframe_smoke(new_basis: Basis, up: DVec3, radius: float, spin: float) -> void:
	var origin := up.scaled(radius)
	if _smoke_framed:
		# ω = −Ŷ·rate; the small angle carries the old origin round with the ground.
		var turned := _smoke_origin.clone().add_in(DVec3.new(0.0, -1.0, 0.0).cross(_smoke_origin).scale_in(spin))
		var d := turned.sub_in(origin)
		var e := new_basis.x; var u := new_basis.y; var n := new_basis.z
		var t := Vector3(d.dot(DVec3.from_v3(e)), d.dot(DVec3.from_v3(u)), d.dot(DVec3.from_v3(n)))
		smoke.reframe(new_basis.transposed() * _smoke_basis, t)
	_smoke_basis = new_basis
	_smoke_origin.copy_from(origin)
	_smoke_framed = true

## The exhaust trail: one strand behind each separate smoky column, and one behind each
## lit separation motor, each starting as that plume's own smoke column. Jets whose
## exits are closer than their two exit diameters have merged before the smoke grows
## out of the flame (the Shuttle's SSMEs) and share a strand; farther apart (its two
## SRBs), each lays its own. A cluster's far field is already one plume.
func _lay_trails(in_air: bool, main_on: bool) -> void:
	smoke.trail_begin()
	if main_on:
		# [lead, exits in the craft's frame, summed line density]; the lead goes by plume
		# order, so a strand keeps its key from frame to frame.
		var groups: Array = []
		for pl: Plume.PlumeFx in plumes:
			if not pl.mesh.visible or pl.trail_k <= 0.0: continue
			var xf := _plume_in_craft(pl)
			var mine = null
			for g: Array in groups:
				var lead: Plume.PlumeFx = g[0]
				var lx := _plume_in_craft(lead)
				var ax := (lx.basis * Vector3.DOWN).normalized()
				var d := xf.origin - lx.origin
				if (d - ax * d.dot(ax)).length() < lead.exit_d + pl.exit_d: mine = g; break
			if mine == null: groups.append([pl, [xf.origin], pl.trail_k])
			else:
				mine[1].append(xf.origin)
				mine[2] += pl.trail_k
		for g: Array in groups:
			var centre := Vector3.ZERO
			for e: Vector3 in g[1]: centre += e
			centre /= float(g[1].size())
			# The merged column covers every exit and carries all their exhaust.
			var widen := 0.0
			for e: Vector3 in g[1]: widen = maxf(widen, (e - centre).length())
			_plume_trail(g[0], centre, g[2] / g[0].trail_k, widen)
	if in_air:
		for b in sep_plumes:
			if b.fx.mesh.visible and b.fx.trail_k > 0.0: _plume_trail(b.fx)
	smoke.trail_finish()

## The plume's exit and axis (−Y) in the craft's frame: it hangs on its engine's gimbal
## or motor mount.
func _plume_in_craft(fx: Plume.PlumeFx) -> Transform3D:
	return craft.group.global_transform.affine_inverse() * fx.mesh.global_transform

## `exit` (craft frame) overrides the plume's own; `gain` scales its line density and
## `widen` (m) its radius scale, for a strand that carries several merged jets.
func _plume_trail(fx: Plume.PlumeFx, exit = null, gain := 1.0, widen := 0.0) -> void:
	var rel := _plume_in_craft(fx)
	var at: Vector3 = craft_pos.to_v3() + craft.group.basis * (rel.origin if exit == null else exit)
	var dir: Vector3 = (craft.group.basis * rel.basis * Vector3.DOWN).normalized()
	var col_a := fx.column_a
	var col_k := fx.column_k
	if gain != 1.0 or widen > 0.0:
		col_a = col_a.duplicate(); col_k = col_k.duplicate()
		for i in col_a.size():
			col_a[i] += widen
			col_k[i] *= gain
	# Close enough to follow the column's width and the path's curve; no more than
	# eight a second, so a whole trail's life fits SmokeColumn.NODE_N.
	var spacing := maxf(maxf(col_a[-1] * 3.0, Plume.airspeed * 0.125), 4.0)
	smoke.trail_to(str(fx.get_instance_id()), at, dir, fx.last_len, fx.column_fx, col_a, col_k,
		Plume.smoke_grey(fx.propellant), dir * 15.0 + smoke.wind, spacing)

## The rendering preset's share of the flight scene: clouds and sky (LocalView),
## plume march density and the smoke's form.
func set_render_quality(q: String) -> void:
	_render_quality = q
	local.set_render_quality(q)
	Plume.detail = {"low": 0.6, "medium": 0.8, "high": 1.0, "ultra": 1.8}.get(q, 1.0)
	Plume.smoke_steps = [9, 1] if q == "ultra" else [5, 0]
	Plume.smoke_rate = 40.0 if q == "ultra" else 26.0
	# The plume's column marches about 0.15 of its radius scale a step; coarser steps in
	# a dense trail light it from deeper inside, darker than the plume it continues.
	Plume.trail_steps = {"low": [8, 0], "medium": [10, 0], "high": [12, 0], "ultra": [12, 1]}.get(q, [10, 0])
	Plume.trail_fine = q == "high" or q == "ultra"
	Plume.trail_material()
	Plume.set_smoke_volume(smoke, q == "high" or q == "ultra", local.cloud_shape)

func teardown() -> void:
	weather_stated = {}
	interior.dispose()
	arms_out = false
	if docking!=null:
		local.unplace(docking.craft.group)
		docking.craft.group.queue_free()
		docking=null
	if crane_rig != null:
		crane_rig.dispose()
		crane_rig = null
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
	_drop_ground_site()
	_drop_rover()
	_drop_sea_site()
	if vessel != null: vessel.release_ground()
	ground_pos.y = 0.0
	plumes = []; sep_plumes = []; entry = null; cryo = null; vapour = null
	for f: Fall in falls: _drop_fall(f)
	falls = []; subject = null
	if mission!=null:mission.release()
	mission = null; skip = null
	smoke.clear()
	_smoke_framed = false
	vessel = null; autopilot = null; cruise = null; plan = null; count = null
	if not kerr_demo.is_empty():fly_cam.state.merge(kerr_demo.priorAim,true)
	kerr_demo.clear()
	cruise_ctx = null; pending_cruise = null; star_target = null
	dev_warp = 0.0
	if saved_speed != null:
		state.speed = saved_speed
		saved_speed = null
	active = false
	camera_override = Callable()
	fly_cam.state.fov = 55.0
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
	var origin := vessel.world_pos()
	var tpos := _cruise_target_pos(target_body, mission, origin)
	var dname: String = (target_body as Body).name if target_body != null \
		else (str(mission.name) if mission != null else "deep space")
	# The line has to be clear: wait until r̂·d̂ > 0, when the closest approach is
	# where the ship already is.
	var d_hat := DQuat.nrm(tpos.clone().sub_in(origin))
	if vessel.phase != Vessel.PHASE.PRELAUNCH and vessel.to_world(vessel.r, DVec3.new()).dot(d_hat) < 0.0:
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

## A star's direction, in orrery axes, from J2000 RA (h) and Dec (°).
static func mission_direction(m) -> DVec3:
	if m == null or m.get("ra") == null: return DVec3.new(1.0, 0.0, 0.0)
	return Rocketry.equatorial_dir(float(m.ra) * PI / 12.0, deg_to_rad(float(m.dec)))

## Hand the vessel to a new parent body mid-flight, resetting everything the
## local view keeps in that body's frame (see begin()).
func _adopt_parent(body: Body) -> void:
	if vessel.parent == body: return
	var world := vessel.world_pos()
	var old_frame := vessel.frame.clone()
	vessel.to_world(vessel.v, vessel.v)
	vessel.set_parent(body, bodies())
	vessel.to_local(vessel.v, vessel.v)
	vessel.q.premultiply(old_frame.premultiply(vessel.frame.clone().invert())).normalize_in()
	vessel.to_local(world.sub_in(body.pos).scale_in(Rocketry.AU_M), vessel.r)
	planet_spin = 0.0
	DQuat.set_len(anchor_pos.copy_from(vessel.r), vessel.surface_r(vessel.r))
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
	vessel.to_local(_a.sub_in(vessel.parent.pos).scale_in(Rocketry.AU_M), vessel.r)
	var dir := vessel.to_local(cruise.dir, DVec3.new())
	vessel.v.copy_from(dir).scale_in(cruise.beta * Rocketry.C_MS)
	vessel.met = float(ctx.get("met0", 0.0)) + cruise.tau
	vessel.coord = float(ctx.get("coord0", 0.0)) + cruise.t
	vessel.clock_delta = float(ctx.get("clock_delta0", 0.0)) + cruise.tau - cruise.t
	var st = ctx.stage
	st.prop = cruise.prop
	var burning: bool = cruise.leg == "accel" or cruise.leg == "decel"
	# Along or against the line of flight (flip-and-burn). At a star, hold broadside to it.
	if cruise.leg == "arrived":
		var side := DVec3.new().cross_vectors(dir, DVec3.new(0.0, 1.0, 0.0))
		if side.length_sq() < 1e-6: side.set_v(1.0, 0.0, 0.0)
		_q.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), DQuat.nrm(side))
	else:
		var facing := -1.0 if cruise.leg == "decel" else 1.0
		_q.set_from_unit_vectors(DVec3.new(0.0, 1.0, 0.0), _b.copy_from(dir).scale_in(facing))
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
	if autopilot == null or docking!=null: return
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
	if p == "catch" and vessel.catch_tower == null:
		# Start over as the booster coming home, if this stack's booster is caught.
		var key: String = vessel.vehicle_key
		if Vehicles.booster_return(key) == null:
			_toast("This vehicle's booster is not caught by a tower")
			return
		begin(key, {"mode": "return"})
		_toast("Super Heavy return — after boostback, 95 km up")
	var ap = autopilot
	ap.plan = null; ap.node = null; ap.site = null; ap.burning = false
	ap.slamming = false; ap.entry_done = false; ap.q_guarding = false; ap.shield_gone = false; ap.crane_out = false
	if p == "ascent" and vessel.phase == Vessel.PHASE.PRELAUNCH:
		start_count()
		return
	ap.engage(p)

## Developer: the vessel `alt_m` over where it is now, at `speed` m/s through the air
## along its present direction of flight (east if it has none). Off the pad, the
## count and the hold-downs are dropped.
func teleport(alt_m: float, speed: float) -> void:
	if vessel == null or cruise != null or not kerr_demo.is_empty() or docking!=null: return
	var env: Dictionary = vessel.env
	var up := DQuat.nrm(vessel.r.clone())
	var dir := vessel.airspeed(vessel.r, vessel.v, DVec3.new())
	if dir.length() < 1.0: dir = DVec3.new(0.0, -1.0, 0.0).cross(up)
	DQuat.nrm(dir)
	vessel.r.copy_from(up).scale_in(vessel.surface_r(up) + maxf(alt_m, 0.0))
	vessel.v.copy_from(dir).scale_in(speed).add_in(DVec3.new(0.0, -float(env.rotRate), 0.0).cross(vessel.r))
	if vessel.phase == Vessel.PHASE.PRELAUNCH or vessel.phase == Vessel.PHASE.LANDED:
		count = null
		vessel.held_down = false
		vessel.phase = Vessel.PHASE.ASCENT
	vessel.sample(0.0)
	vessel.log_event("Developer teleport — %s km, %s m/s" % [U.fixed(alt_m / 1000.0, 1), U.fixed(speed, 0)])

# TIME
func set_warp(i: int) -> void:
	warp_idx = 0 if docking!=null else clampi(i, 0, WARPS.size() - 1)
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
	var entering: bool = m == "interior" and fly_cam.state.mode != "interior" and camera_modes().has(m)
	if entering:
		exterior_fov = float(fly_cam.state.fov)
		fly_cam.state.fov = 78.0
	elif m != "interior" and fly_cam.state.mode == "interior":
		fly_cam.state.fov = exterior_fov
	fly_cam.set_mode(m if camera_modes().has(m) else "chase")
	if vessel != null and craft != null:
		interior.set_enabled(fly_cam.state.mode == "interior", craft, vessel.vehicle)

func camera_modes() -> Array:
	if docking != null:
		return ["berth", "orbit", "interior"] if vessel.vehicle.has("interior") else ["berth", "orbit"]
	if driving and rover != null and str(rover.spec.name) == "Perseverance": return ["chase", "orbit", "mast"]
	var modes := ["chase", "orbit", "cockpit", "pad"]
	if vessel != null and vessel.vehicle.has("interior") and subject == null:
		modes.insert(3, "interior")
	return modes

## Put the camera on the far side of the vehicle from the sun, the sun `off` rad
## beside it (backlit). `front_lit` goes on the sun's side instead, `off_yaw` round,
## for where nothing else lights the ship.
func aim_camera_at_sun(off_yaw: float = 0.22, off_pitch: float = 0.10, front_lit: bool = false) -> void:
	if vessel == null: return
	if fly_cam.state.mode in ["pad", "cockpit", "interior"]: set_camera_mode("chase")
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

# MISSIONS
## Fly to `dest_name` and orbit it or land on it, with no further input. Returns the
## Mission (check its `failed` for why it could not start).
func start_mission(dest_name: String, goal: String = "orbit") -> Mission:
	if vessel == null or not kerr_demo.is_empty() or docking!=null: return null
	var b := body_named(dest_name)
	if b == null: return null
	abort_mission()
	var m := Mission.create(self, b, goal)
	if m.failed != "":
		_toast("Cannot fly this mission — %s" % m.failed)
		return m
	mission = m
	set_target(b.name)
	refresh_targets()
	return m

func abort_mission() -> void:
	if mission != null and not mission.done and mission.failed == "":
		mission.abort()
	if mission!=null:mission.release()
	mission = null
	skip = null

func _manual_warp() -> void:
	if mission != null and mission.auto_warp and not mission.done:
		mission.auto_warp = false
		_toast("Auto warp off — the mission keeps flying")

## Skip to the mission's destination: charge its propellant and time, then arrive.
func begin_skip(m: Mission) -> void:
	if vessel == null or m == null or not m.plan.get("flyable", false): return
	mission = m
	var grounded: bool = vessel.phase == Vessel.PHASE.PRELAUNCH or vessel.phase == Vessel.PHASE.LANDED
	count = null
	vessel.held_down = false
	vessel.throttle = 0.0
	autopilot.disengage()
	# The flight is not flown, so its staging is done here: everything the burns empty.
	var dv := 0.0
	for l in m.plan.legs:
		if l.key in ["land", "descend"]: continue
		dv += float(l.dv)
	vessel.spend_dv(dv)
	if grounded:
		vessel.place_in_orbit_radius(Mission.park_radius(vessel.parent), 28.5, phase_rng.randf() * TAU)
	var t := 0.0
	for l in m.plan.legs:
		if l.key in ["land", "descend"]: continue
		t += float(l.t)
	skip = {"until": vessel.coord + t, "mission": m}
	vessel.log_event("Skipping to %s — %s of flight, %s km/s of Δv charged" % [m.dest.name, Guidance.fmt_dur(t), U.fixed(dv / 1000.0, 2)])
	set_camera_mode("chase")

func _arrive_skip() -> void:
	var m: Mission = skip.mission
	skip = null
	if not m.dest.alive:
		m.abort("%s is gone" % m.dest.name)
		return
	vessel.rebase(m.dest)
	vessel.place_in_orbit_radius(float(m.plan.r_cap), 0.0, phase_rng.randf() * TAU)
	set_warp(0)
	vessel.log_event("Arrived — parking orbit around %s" % m.dest.name)
	# What is left is flown: the landing, if the mission is one.
	m.leg = 0
	var keep: Array = []
	for l in m.plan.legs:
		if l.key in ["descend", "land"]: keep.append(l)
	m.plan.legs = keep
	m.leg = -1
	m._next()

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

	if lab != null:
		_hold_lab(dt)
		if not advance_world.is_valid(): finish_frame(dt, 0.0)
		return 0.0
	if skip != null and vessel.coord >= float(skip.until): _arrive_skip()
	if mission != null and skip == null: mission.update(dt)
	# Slave the orrery's clock every frame, or the slider desyncs planets and vehicle.
	state.time_scale = (dev_warp if dev_warp > 0.0 else float(WARPS[warp_idx])) / Rocketry.YR_S
	# At warp 1 flight time is wall-clock time; the orrery multiplier is forced to 1.
	var w: float = (dev_warp if dev_warp > 0.0 else float(warp())) * (0.0 if state.paused else 1.0)
	if docking!=null:
		w=0.0 if state.paused else 1.0
		state.time_scale=1.0/Rocketry.YR_S
	if skip != null:
		w = 0.0 if state.paused else minf(SKIP_WARP, maxf((float(skip.until) - vessel.coord) / maxf(dt, 1e-3), 1.0))
		state.time_scale = w / Rocketry.YR_S
	var sim_seconds := dt * w
	var control_frame := {"owed": 0.0, "fraction": 1.0}
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

	if docking!=null:
		sim_seconds=_step_docking(sim_seconds,world if advance_world.is_valid() else Callable())
	elif not kerr_demo.is_empty():
		sim_seconds=_step_kerr(sim_seconds,world if advance_world.is_valid() else Callable())
	elif cruise != null:
		# Ship proper time is the natural variable in cruise — the drive, the
		# fuel and the crew all live on it.
		sim_seconds = _step_cruise(dt, sim_seconds, world if advance_world.is_valid() else Callable())
	else:
		boost = Vector3.ZERO
		if not advance_world.is_valid():
			if count != null: step_count(sim_seconds)
			if sim_seconds > 0.0 and autopilot != null: autopilot.update(minf(dt, 0.1))
		else:
			# Guidance runs once per frame interval of flight time, for at least the
			# interval about to be flown: a warped frame steers as often and with as
			# much authority per flight second as a 1× one, where the orbiter is lost
			# in its entry at 2× if it steers once a frame. Countdown uses every
			# accepted interval.
			opts.controls = func(seconds: float) -> void:
				if count != null: step_count(seconds)
				if autopilot != null and control_frame.owed <= 1e-9:
					var g := maxf(dt, seconds)
					autopilot.update(minf(g * control_frame.fraction, 0.1))
					control_frame.owed += g
				control_frame.owed -= seconds
			opts.control_may_thrust = count != null or (autopilot != null and autopilot.program != null)
		# Physics warp up to 4×; above that the vessel goes on rails, which is
		# only legal unpowered and out of the air (checked inside step()).
		var rails: bool = w > 4.0 and vessel.can_rail() and not opts.get("control_may_thrust", false) and dev_warp <= 0.0
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
		if w > 4.0 and not vessel.can_rail() and dev_warp <= 0.0: set_warp(2)
		if pending_cruise != null:
			begin_cruise(pending_cruise.body, pending_cruise.accel, pending_cruise.mission)

	if rover != null: _step_rover(sim_seconds)
	if vessel.release_flyer and heli == null: _release_flyer()
	if heli != null: _step_heli(sim_seconds)
	if not advance_world.is_valid(): finish_frame(dt, sim_seconds)
	return sim_seconds

# The Sky Crane's moments, from the flight: the heat shield goes at the edl's `shieldJett` height under the
# chute, the bridles pay out from guidance's sky-crane call, and the flyaway counts from touchdown.
func _draw_crane(alt: float) -> void:
	var met := vessel.met
	var shell_on := false
	for st in vessel.stages:
		if crane_rig.shell != null and str(st.spec.key) == crane_rig.shell.key: shell_on = st.attached
	var jett = vessel.vehicle.get("edl", {}).get("shieldJett")
	if jett != null and shell_on and vessel.chute_open != null and alt < float(jett.alt) and not _crane_marks.has("shield"):
		_crane_marks.shield = met
	# Touchdown from the vessel's own record, so a landing flown undrawn still times the flyaway from it, the
	# bridles by then all out.
	if vessel.phase == Vessel.PHASE.LANDED and vessel.landed_at != null and not _crane_marks.has("down"):
		_crane_marks.down = float(vessel.landed_at.met)
		if not _crane_marks.has("crane"): _crane_marks.crane = -INF
	if autopilot != null and autopilot.crane_out and not _crane_marks.has("crane"): _crane_marks.crane = met
	var cable := float(vessel.vehicle.get("edl", {}).get("skycrane", {}).get("cable", 7.5))
	crane_rig.update({"shell": shell_on,
		"shieldT": met - float(_crane_marks.shield) if _crane_marks.has("shield") else -1.0,
		"crane": minf((met - float(_crane_marks.crane)) * SkyCraneRig.PAYOUT_RATE, cable) if _crane_marks.has("crane") else 0.0,
		"flyaway": met - float(_crane_marks.down) if _crane_marks.has("down") else -1.0})

## Can the vehicle put its rover down here: landed, on a surveyed ground, carrying one.
func can_deploy_rover() -> bool:
	return vessel != null and vessel.phase == Vessel.PHASE.LANDED and vessel.ground != null \
		and vessel.ground.adopted and vessel.vehicle.get("rover") != null

## Put the rover down beside the vehicle (7 m east of its centre, clear of an LM's 9.4 m leg span, facing
## north) and take the wheel; the vehicle stands in its way as a cylinder of its own diameter. A rover that
## is the landed stage itself (`roverOffset` 0, the Sky Crane's) starts where it stands, and what lowered it
## has gone.
func deploy_rover() -> bool:
	if rover != null or not can_deploy_rover(): return false
	var g: SurfaceGround = vessel.ground
	var at := g.site_point(vessel, vessel.r)
	var spec: Dictionary = Rover.VEHICLES.get(str(vessel.vehicle.rover), Rover.LRV)
	var soil: Dictionary = Rover.SOILS.get(vessel.parent.name, Rover.LUNAR_SOIL)
	rover = Rover.new(Rover.SiteGround.new(g.relief.grids, g.patch_y, g.relief.radius_m), float(vessel.env.gSurf), spec, soil)
	var offset := float(vessel.vehicle.get("roverOffset", 7.0))
	if offset > 0.0: rover.obstacles = [[Vector2(at.x, at.z), maxf(float(vessel.diameter) * 0.6, 1.0)]]
	elif crane_rig != null: crane_rig.deployed = true   # the stage flies off; it hides once gone
	elif craft != null: craft.group.visible = false
	rover.place(-at.x + offset, at.z, 0.0)
	rover_arm = RoverArm.new() if str(spec.name) == "Perseverance" else null
	rover_tracks = RoverTracks.new()
	rover_dust = RoverDust.new(rover.g, 0.0 if vessel.env.atm == null else 4.0, vessel.id)
	driving = true
	vessel.log_event("%s deployed%s" % [str(spec.name), (" — %s m east of the lander" % U.fixed(offset, 0)) if offset > 0.0 else ""])
	return true

## Can Ingenuity come off the rover here: Perseverance down and deployed, the helicopter not yet out.
func can_deploy_heli() -> bool:
	return heli == null and rover != null and str(rover.spec.name) == "Perseverance" and vessel.ground != null and vessel.ground.adopted

## Set Ingenuity down 4 m ahead and to the left of the rover, as Perseverance dropped it and drove off, in the
## air the site has, and take its controls.
func deploy_heli() -> bool:
	if not can_deploy_heli(): return false
	var g: SurfaceGround = vessel.ground
	var ground := Rover.SiteGround.new(g.relief.grids, g.patch_y, g.relief.radius_m)
	var y := rover.pos.y
	var atm = vessel.env.atm
	heli = Rotorcraft.new(ground, float(vessel.env.gSurf), Rocketry.density(atm, y), Rocketry.speed_of_sound(atm, y), Rotorcraft.INGENUITY)
	var fwd := DQuat.rotate(DVec3.new(0.0, 0.0, 1.0), rover.q)
	var left := DQuat.rotate(DVec3.new(1.0, 0.0, 0.0), rover.q)
	var at := rover.pos.clone().add_scaled_in(fwd, 4.0).add_scaled_in(left, 2.5)
	heli.place(-at.x, at.z, rover.heading())
	heli.t = rover_t()
	heli.armed = true
	flying = true
	driving = false
	rover.throttle = 0.0
	rover.steer = 0.0
	vessel.log_event("Ingenuity deployed — air %s kg/m³, %s%% of Earth's" % [U.fixed(heli.rho, 4), U.fixed(heli.rho / 1.225 * 100.0, 2)])
	return true

## A flyer out of its shell, where the vessel was let go, at its velocity over the ground, level: it then
## flies itself down at its descent rate, and the vessel is held under it.
func _release_flyer() -> void:
	var g: SurfaceGround = vessel.ground
	if g == null or not g.adopted: return
	var spec: Dictionary = Rotorcraft.VEHICLES.get(str(vessel.vehicle.get("flyer", "")), Rotorcraft.DRAGONFLY)
	var atm = vessel.env.atm
	var ground_h := vessel.altitude() - vessel.height_above_ground()
	heli = Rotorcraft.new(Rover.SiteGround.new(g.relief.grids, g.patch_y, g.relief.radius_m), float(vessel.env.gSurf),
		Rocketry.density(atm, ground_h), Rocketry.speed_of_sound(atm, ground_h), spec)
	var at := g.site_point(vessel, vessel.r)
	heli.pos = DVec3.from_v3(at)
	var ax := g.site_axes(vessel)
	var to_site := Basis(ax[1].to_v3(), ax[2].to_v3(), ax[3].to_v3()).inverse()
	heli.vel = DVec3.from_v3(to_site * vessel.ground_velocity(vessel.r, vessel.v, DVec3.new()).to_v3())
	heli.q = DQuat.new()
	heli.on_ground = false
	heli.landed = false
	heli.t = vessel.coord
	heli.armed = true
	autoland = true
	vessel.flown = true
	vessel.phase = Vessel.PHASE.LANDED
	vessel.throttle = 0.0
	if craft != null: craft.group.visible = false

func rover_t() -> float:
	return vessel.coord

func _step_heli(sim_seconds: float) -> void:
	if autoland:
		# Down at its descent rate; low over ground steeper than it can stand on, it holds its height and moves
		# on until it is over flatter ground, as Dragonfly's hazard lidar picks its spot.
		heli.cmd_yaw = 0.0
		var steep := heli.height_above_ground() < AUTOLAND_LOOK and heli.ground_slope(float(heli.spec.size.x) * 0.5) > AUTOLAND_SLOPE
		heli.cmd_fwd = 0.4 if steep else 0.0
		heli.cmd_climb = 0.0 if steep else -1.0
		if heli.on_ground and heli.vel.length() < 0.2:
			autoland = false
			flying = true
			heli.cmd_climb = 0.0
			vessel.log_event("%s down — %s m/s at the last, %s Wh used" % [str(heli.spec.name), U.fixed(heli.vel.length(), 2),
				U.fixed(float(heli.spec.battery_wh) - heli.energy_wh, 0)])
	elif flying and rover_keys and main != null and "keys" in main and drawn:
		var c = main.controls
		heli.cmd_fwd = (1.0 if c.held("drive_forward", main.keys) else 0.0) - (1.0 if c.held("drive_back", main.keys) else 0.0)
		heli.cmd_yaw = (1.0 if c.held("steer_right", main.keys) else 0.0) - (1.0 if c.held("steer_left", main.keys) else 0.0)
		heli.cmd_climb = (1.0 if c.held("climb", main.keys) else 0.0) - (1.0 if c.held("descend", main.keys) else 0.0)
	# At most a few seconds of flight in one frame, as for the rover.
	heli.advance(heli.t + minf(sim_seconds, 4.0))

## Ingenuity in the local frame: its centre of mass.
func heli_local() -> DVec3:
	return _site_at.clone().add_in(DVec3.from_v3(_site_basis * heli.pos.to_v3()))

## The helicopter's line on the flight HUD.
func heli_readout() -> String:
	var r := heli.rotors[0]
	var line := "%s · %s m up · %s m/s · heading %s° · %s rpm, collective %s° · %s W · battery %s%%" % [str(heli.spec.name),
		U.fixed(heli.height_above_ground(), 1), U.fixed(heli.vel.length(), 1), U.fixed(fposmod(rad_to_deg(heli.heading()), 360.0), 0),
		U.fixed(r.omega * 60.0 / TAU, 0), U.fixed(rad_to_deg(r.theta), 1), U.fixed(heli.power_w, 0),
		U.fixed(100.0 * heli.energy_wh / float(heli.spec.battery_wh), 0)]
	if heli.crashed: line += " · crashed"
	elif heli.energy_wh <= 0.0: line += " · battery flat"
	return line

func _step_rover(sim_seconds: float) -> void:
	if driving and rover_keys and main != null and "keys" in main and drawn:
		var c = main.controls
		rover.throttle = (1.0 if c.held("drive_forward", main.keys) else 0.0) - (1.0 if c.held("drive_back", main.keys) else 0.0)
		rover.steer = (1.0 if c.held("steer_left", main.keys) else 0.0) - (1.0 if c.held("steer_right", main.keys) else 0.0)
	# At most a few seconds of driving in one frame: warped time on the ground is the rover's too.
	rover.advance(minf(sim_seconds, 4.0))
	if rover_arm != null: rover_arm.advance(minf(sim_seconds, 4.0))
	rover_tracks.step(rover)
	if history and rover_dust != null: rover_dust.step(rover, minf(sim_seconds, 0.25))

func _drop_rover_views() -> void:
	if rover_model != null and is_instance_valid(rover_model.group): rover_model.group.queue_free()
	rover_model = null
	if heli_model != null and is_instance_valid(heli_model.group): heli_model.group.queue_free()
	heli_model = null
	if rover_dust != null: rover_dust.dispose()
	if rover_tracks != null: rover_tracks.dispose()

func _drop_rover() -> void:
	_drop_rover_views()
	heli = null
	flying = false
	autoland = false
	rover = null
	rover_dust = null
	rover_tracks = null
	rover_arm = null
	driving = false

## Send the arm's turret to the ground 1.5 m ahead of the body, or stow it.
func _toggle_arm() -> void:
	if not rover_arm.stowed:
		rover_arm.stow()
		_toast("Arm stowing")
		return
	var at_ground := rover_ground_ahead(1.5)
	if rover_arm.reach(at_ground): _toast("Arm to the ground ahead")
	else: _toast("The ground ahead is out of the arm's reach")

## The ground `ahead` m in front of the rover's body, on its centreline, in the body frame.
func rover_ground_ahead(ahead: float) -> Vector3:
	var fwd := DQuat.rotate(DVec3.new(0.0, 0.0, 1.0), rover.q)
	var p := rover.pos.clone().add_scaled_in(fwd, ahead + 0.85)
	var y: float = rover.ground.height(-p.x, p.z)
	p.y = y
	return DQuat.rotate(p.sub(rover.pos), rover.q.clone().invert()).to_v3()

## The rover in the local frame, where the camera and placement work: its centre of mass.
func rover_local() -> DVec3:
	return _site_at.clone().add_in(DVec3.from_v3(_site_basis * rover.pos.to_v3()))

func _hold_lab(dt: float) -> void:
	var env: Dictionary = vessel.env
	var up := DQuat.nrm(vessel.r.clone())
	var spin := DVec3.new(0.0, -float(env.rotRate), 0.0)
	var east := DVec3.new(0.0, -1.0, 0.0).cross(up)
	if east.length() < 1e-6: east.set_v(1.0, 0.0, 0.0)
	DQuat.nrm(east)
	var p := float(lab.get("pitch", 0.0))
	var fwd := up.clone().scale_in(cos(p)).add_scaled_in(east, sin(p))
	vessel.r.copy_from(up).scale_in(vessel.surface_r(up) + float(lab.alt))
	# Airspeed along the axis, on top of the air turning with the planet.
	vessel.v.copy_from(fwd).scale_in(float(lab.speed)).add_in(spin.cross(vessel.r))
	# `alpha` raises the nose above the airflow, belly (body −Z) into it, as an entry flies.
	var a := float(lab.get("alpha", 0.0))
	if a != 0.0:
		var top := up.clone().add_scaled_in(fwd, -up.dot(fwd))
		if top.length() < 1e-6: top = east.clone()
		DQuat.nrm(top)
		var nose := fwd.clone().scale_in(cos(a)).add_scaled_in(top, sin(a))
		var z := top.clone().scale_in(cos(a)).add_scaled_in(fwd, -sin(a))
		vessel.q.set_from_basis_columns(nose.cross(z), nose, z)
	else: vessel.q.set_from_unit_vectors(Vessel.BODY_FWD, fwd)
	vessel.omega.set_v(0.0, 0.0, 0.0)
	vessel.throttle = float(lab.get("throttle", 1.0))
	vessel.held_down = false
	if vessel.phase == Vessel.PHASE.PRELAUNCH: vessel.t0 = vessel.met
	vessel.phase = Vessel.PHASE.ASCENT
	vessel.met += dt
	vessel.sample(0.0)

func finish_frame(dt: float, coordinate_seconds: float) -> void:
	if not active or vessel == null: return
	update_visual(dt, coordinate_seconds)
	if hud != null and drawn: update_hud()

## Where the local frame sits: under the followed piece, else under the vehicle.
func _subject_r() -> DVec3:
	return subject.r if subject != null else vessel.r

## Local up and north at `rr` (the vehicle by default), in the parent frame.
func _local_up_north(rr: DVec3 = null) -> Array:
	var up := DQuat.nrm((rr if rr != null else vessel.r).clone())
	var north := DVec3.new(0.0, -1.0, 0.0)
	if absf(north.dot(up)) > 0.98: north.set_v(1.0, 0.0, 0.0)
	north.add_scaled_in(up, -north.dot(up))
	DQuat.nrm(north)
	return [up, north]

func update_visual(dt: float, sim_seconds: float) -> void:
	var env: Dictionary = vessel.env
	var alt := vessel.altitude()
	for f: Fall in falls: f.step(sim_seconds, vessel)
	# The local frame and the view run from the followed piece when there is one.
	var eye_alt := subject.altitude(vessel) if subject != null else alt
	var un := _local_up_north(_subject_r())
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
	if not kerr_demo.is_empty():
		# A display key from the disc direction makes the craft legible without
		# implying a local radiative flux or changing the test-particle orbit.
		sun.copy_from(up).negate_in();f_key=.05;f_total=f_key+STARLIGHT
	# Auto-exposure: target brightness F^0.3 below daylight (floor 0.06), none above;
	# eased in log over ~1.5 s.
	var shown := f_total if f_total >= 1.0 else maxf(pow(f_total, 0.3), 0.06)
	# Metering: away from a planet's shine, open up by up to 1.8× (800 km → a few 1000 km).
	shown *= lerpf(1.0, 1.8, U.smooth(eye_alt, 8.0e5, 5.0e6))
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
		if vessel.catch_tower != null:
			site_pos.copy_from(vessel.catch_tower.pos)
		elif vessel.phase == Vessel.PHASE.PRELAUNCH:
			site_pos.copy_from(vessel.r)
		else:
			# ω × r — see AGENTS.md: a point fixed to a rotating body.
			_a.set_v(0.0, -float(env.rotRate), 0.0).cross_vectors(_a, site_pos)
			site_pos.add_scaled_in(_a, sim_seconds)
			DQuat.set_len(site_pos, vessel.surface_r(site_pos))
	# The planet turns under the frame; see planet_spin.
	planet_spin = fposmod(planet_spin + float(env.rotRate) * sim_seconds, TAU)
	_a.set_v(0.0, -float(env.rotRate), 0.0).cross_vectors(_a, anchor_pos)
	anchor_pos.add_scaled_in(_a, sim_seconds)
	DQuat.set_len(anchor_pos, vessel.surface_r(anchor_pos))
	# The local scene's ground is the sphere of the surface radius under the subject.
	var R_loc := vessel.surface_r(_subject_r())
	var fr: Dictionary = {} if not history or fast_forward > 0 else local.update({"env": env, "altitude": eye_alt,
		"surfaceR": R_loc, "sunDirWorld": sun, "upWorld": up, "northWorld": north,
		"starFlux": star_flux, "padWorld": site_pos, "mapSite": map_site,
		"planetSpin": planet_spin, "anchorWorld": anchor_pos, "dt": dt, "maria": _maria(),
		"dunes": vessel.parent.spec.get("dunes") if vessel.parent != null else null,
		"geoTheta": vessel.body_angle(vessel.coord) if vessel.parent != null else null,
		"frame": Basis(vessel.frame.to_quaternion()),
		# a steady 9 m/s westerly, the trade-wind belt's upper flow reversed
		"cloudWind": wind_dir * (9.0 * vessel.met),
		"sunUnblocked": key == null or key.get("body") == vessel.parent,
		"sunAngR": float(key.ang_r) if key != null else 0.00465,
		"sunTeff": float(key.teff) if key != null else 5772.0,
		"kp": float(key.get("kp", 2.0)) if key != null else 0.0,
		# the other sun, and the sky's own light, through the same exposure
		"sun2World": second.dir if second != null else null,
		"sun2Unblocked": second != null and second.get("body") == vessel.parent,
		"sun2Flux": float(second.flux) * exposure if second != null else 0.0,
		"sun2Teff": float(second.teff) if second != null else 5772.0,
		"starlight": maxf(STARLIGHT * exposure, 0.05 * shadow_lift) if kerr_demo.is_empty() else .18*star_flux})
	# Sky exposure ∝ 1/illuminance (1/400 at Earth), eased (SkyModel.apply_day_gain).
	if fast_forward == 0:
		var want := 1.0 / (1.0 + 400.0 * f_key * float(fr.get("sun_visible", 0.0)))
		sky_gain += (want - sky_gain) * (1.0 - exp(-maxf(dt, 0.0) / 0.8))
		SkyModel.apply_day_gain(pipe.sky_materials, sky_gain)

	# Attitude in the local frame (+Y = local up).
	var east := DQuat.nrm(DVec3.new().cross_vectors(up, north))
	var new_basis := Basis(east.to_v3(), up.to_v3(), north.to_v3())
	_reframe_smoke(new_basis, up, R_loc, float(env.rotRate) * sim_seconds)
	frame_basis = new_basis
	var craft_basis := frame_basis.transposed() * Basis(vessel.q.to_quaternion())
	# The local origin is on the ground under the subject: the vehicle is at (0, alt, 0)
	# unless a dropped piece is followed.
	_a.copy_from(vessel.r).add_scaled_in(up, -R_loc)
	craft_pos.set_v(_a.dot(east), _a.dot(up), _a.dot(north))
	craft.group.position = Vector3.ZERO
	craft.group.basis = craft_basis.orthonormalized()

	# the launch complex. The local origin is under the vehicle, so the pad moves
	# back through the frame. A point θ away is (R sinθ, R(cosθ−1), …) on the ground
	# patch's sphere R_loc, so the pad sits on the drawn ground; off the parallel the
	# ellipsoid departs from that sphere by up to 2.8 m per km, which only a distant
	# complex shows.
	if site != null and site_pos != null:
		var sx: float = site_pos.dot(east)
		var sy: float = DQuat.nrm(_b.copy_from(site_pos)).dot(up) * R_loc - R_loc
		var sz: float = site_pos.dot(north)
		site_local.set_v(sx, sy, sz)
		# Drop the ground patch by the deck height and the hardstand's rise (grade_drop).
		# A followed piece is out over the sea, which is at altitude zero.
		ground_pos.y = -site.grade_drop if subject == null else 0.0
		var rng := Vector2(sx, sz).length()
		# Past a few tens of kilometres the whole complex is under a pixel, and
		# the ground patch's own detail is the better picture.
		site.group.visible = eye_alt < 8e4 and rng < 1.2e5
		if site.group.visible and history:
			var tw = vessel.catch_tower
			var catch_pose = null
			if tw != null:
				# The booster's base in the complex's frame (the craft is at the local origin).
				var rel: Vector3 = site.group.basis.inverse() * Vector3(-sx, 0.0, -sz)
				catch_pose = {"rail": tw.rail_alt, "closed": tw.closed, "settle": tw.settle,
					"booster": rel, "radius": vessel.diameter * 0.5}
			site.update({
				# Seconds to hold-down release. Without a count, engines lit on the pad
				# count as release, so nothing is left in the vehicle's way.
				"t_minus": float(count.t) if count != null else (INF if vessel.phase == Vessel.PHASE.PRELAUNCH \
					and vessel.throttle <= 0.0 else -1.0),
				# No deluge for a catch: the engines are 80 m up.
				"throttle": 0.0 if tw != null else (vessel.throttle if float(vessel.telemetry.get("thrust", 0.0)) > 0.0 else 0.0),
				"dt": minf(sim_seconds, 0.25),
				"catch": catch_pose,
			})
		# Put the camera on the sunlit side once the sun's local azimuth is known.
		if not pad_aimed:
			pad_aimed = true
			var sun_az := atan2(sun.dot(north), sun.dot(east))
			var r := Vector2(pad_offset.x, pad_offset.z).length()
			pad_offset = Vector3(cos(sun_az) * r, pad_offset.y, sin(sun_az) * r)
		# The pad camera stands ON the pad, so it moves with it.
		fly_cam.state.padPos = site_local.clone().add_in(DVec3.from_v3(pad_offset))
	_place_ground(east, up, north, R_loc, fr, float(key.ang_r) if key != null else 0.00465)
	if ground_site != null and ground_site.built and craft != null: _step_plume_dust(minf(sim_seconds, 0.25), fr)
	if ground_site != null and ground_site.built: _step_site_weather(minf(sim_seconds, 4.0), fr)
	_place_sea(east, up, north, R_loc, fr, dt)
	local.place(local.ground, ground_pos)

	# moving parts
	var deploy := {}
	var gear := {}
	var v_up := vessel.v.dot(DQuat.nrm(vessel.r.clone()))
	for st in vessel.stages:
		var s: Dictionary = st.spec
		var d := 0.0
		var look = s.get("look")
		if look != null and look.get("evapod", false): d = 1.0 if arms_out else 0.0
		if s.get("legs") and not (look != null and look.get("gearSwing")):
			d = 1.0 if (vessel.phase == Vessel.PHASE.LANDED or (alt < 3000.0 and v_up < 0.0)) else 0.0
		# Super Heavy's grid fins are fixed out; they steer by twisting.
		if s.get("gridFins"): d = 1.0
		if s.get("solar") or (look != null and look.get("arrays")): d = 1.0
		# The payload bay doors open once in orbit (the radiators are inside them) and
		# close again for the deorbit.
		if look != null and look.get("doors") and vessel.phase == Vessel.PHASE.ORBIT \
				and (autopilot == null or not ["deorbit", "glide"].has(autopilot.program)):
			d = 1.0
		deploy[s.key] = d
		gear[s.key] = 1.0 if (st.gear_out or vessel.phase == Vessel.PHASE.LANDED) else 0.0
	# Gimbal deflection, from the attitude error the controller is working on.
	var gerr := 0.0
	if autopilot != null and autopilot.aim != null:
		gerr = DQuat.angle_between(vessel.forward(_b), autopilot.aim)
	var sg := signf(sin(vessel.met * 3.0))
	var gx := clampf(gerr * 2.4, 0.0, 0.12) * (sg if sg != 0.0 else 1.0)
	var attached := {}
	for st in vessel.stages: attached[st.spec.key] = st.attached
	# Control surfaces. A falling booster's grid fins twist with the attitude error; a
	# ship's flaps take what the return program asks (+ folds leeward; the two sides of
	# the ship turn opposite ways to do it).
	var q_now := float(vessel.telemetry.get("q", 0.0))
	var steer := clampf(gerr * 3.0, 0.0, 0.45) * (sg if sg != 0.0 else 1.0) * clampf(q_now / 2000.0, 0.0, 1.0)
	var twist := [steer, -steer, steer * 0.6] if float(vessel.telemetry.get("vertical", 0.0)) < 0.0 else [0.0, 0.0, 0.0]
	var flaps := [0.0, 0.0, 0.0, 0.0]
	# A lone orbiter: the body flap and elevons as glide left them, and the speed brake's
	# halves each opening half its angle.
	var orb = vessel._first_attached()
	if orb != null and orb.spec.get("wings") != null and vessel._alone(orb):
		var fc: Array = autopilot.flap_cmd if autopilot != null else [0.0, 0.0]
		var e := float(fc[1])
		var sb := vessel.speedbrake * deg_to_rad(98.6) * 0.5
		flaps = [float(fc[0]), e, e, e, e, sb, sb]
	if autopilot != null and autopilot.program == "bellyflop":
		var fc: Array = autopilot.flap_cmd
		flaps = [-float(fc[0]), float(fc[1]), -float(fc[2]), float(fc[3])]
	# The stack's non-gravitational acceleration in the craft frame: what a dropped stage
	# falls behind at. Standing on the ground, the ground's push.
	var to_craft := Basis(vessel.q.to_quaternion()).inverse()
	var g_craft := to_craft * vessel.gravity(vessel.r, DVec3.new()).to_v3() if kerr_demo.is_empty() else Vector3.ZERO
	var accel := -g_craft
	if vessel.phase != Vessel.PHASE.LANDED and kerr_demo.is_empty():
		accel = to_craft * vessel.accel(vessel.r, vessel.v, DVec3.new()).to_v3() - g_craft
	# A stage that has just let go leaves under Separation. Before update(), which hides
	# a detached stage that is not leaving; a stage already gone stays gone.
	for st in vessel.stages:
		var cs = craft.stage(str(st.spec.key))
		if not st.attached and cs != null and cs.sep == null and not cs.handed and cs.group.visible:
			craft.separate(str(st.spec.key), {"mass": vessel.mass,
				"support": -g_craft if vessel.phase == Vessel.PHASE.LANDED else Vector3.ZERO})
	# The drag chute streams downstream of the vehicle, in the air it moves through.
	var chute := {}
	var rs: Vessel.Rollout = vessel.rolling
	if rs != null and rs.chute_t >= 0.0:
		var wind := vessel.airspeed(vessel.r, vessel.v, DVec3.new()).to_v3()
		var st0 = vessel._first_attached()
		chute[str(st0.spec.key) if st0 != null else ""] = {"t": rs.chute_t,
			"gone": vessel.met - rs.chute_gone_met if rs.chute_gone else -1.0,
			"dir": to_craft * -wind.normalized() if wind.length() > 1.0 else Vector3.DOWN, "gs": wind.length()}
	craft.update({"dt": dt, "simDt": sim_seconds, "properTime": vessel.met, "attached": attached, "deploy": deploy, "gear": gear,
		"gimbal": {"x": gx, "z": 0.0}, "flap": flaps, "finTwist": twist, "accel": accel, "release": _release,
		"chute": chute})
	if crane_rig != null: _draw_crane(alt)
	if docking!=null and drawn:
		var offset:=docking.carrier.r.clone().sub_in(vessel.r)
		docking.render_pos.copy_from(craft_pos).add_in(DVec3.new(offset.dot(east),offset.dot(up),offset.dot(north)))
		docking.craft.group.basis=(frame_basis.transposed()*Basis(docking.carrier.q.to_quaternion())).orthonormalized()
		docking.draw_pose(dt)
	_place_falls(east, up, north, R_loc)
	if not history:
		_pad_view_lost(alt)
		return
	if fast_forward > 0:
		_history(dt, alt)
		return

	# The light the plumes' smoke scatters: the sun where it reaches the
	# vehicle (clouds included), with a floor for the sky's own light.
	var sl: Vector3 = fr.get("sun_local", Vector3.UP)
	# Over the vehicle's own horizon: from altitude the Sun still shines from under the local one.
	var over_limb := float(fr.get("sun_over_limb", sl.y))
	Plume.daylight = clampf(over_limb * 2.0 + 0.25, 0.0, 1.0) * local.sun_through * clampf(star_flux, 0.05, 4.0) + 0.04
	Plume.sprite_material(false, 2, Plume.ORDER_SMOKE).set_shader_parameter("uLight", clampf(Plume.daylight, 0.08, 1.4))
	Plume.sun_local = sl
	var sc := local.sun.light_color
	var day := Plume.daylight
	Plume.light_sun = Vector3(sc.r, sc.g, sc.b) * day * 1.15
	# Skylight from above and the ground's bounce from below, under the same light.
	Plume.light_sky = Vector3(0.30, 0.38, 0.52) * day * 0.75
	Plume.light_ground = Vector3(0.17, 0.15, 0.12) * day * 0.6
	if Plume.smoke_volume:
		var vm := Plume.smoke_volume_material(null)
		Plume.apply_smoke_light(vm)
		vm.set_shader_parameter("uTime", vessel.met)
	_update_plumes(alt)
	if cruise != null:
		for pl in plumes:
			pl.update(0.0 if (cruise.leg == "coast" or cruise.leg == "arrived") else 1.0, 0.0, cruise.tau / 100.0, 101325.0)

	if vapour != null:
		var vatt := {}
		for st in vessel.stages: vatt[str(st.spec.key)] = st.attached
		vapour.update({"mach": float(vessel.telemetry.get("mach", 0.0)),
			"T": Rocketry.temperature(env.atm, maxf(alt, 0.0)), "rh": Plume.humidity, "alt": alt,
			"time": vessel.met, "attached": vatt, "sun": craft_basis.inverse() * sl,
			"light": Plume.daylight})

	# Re-entry plasma, from the same heat flux that is burning the shield down: the
	# stack's on its attached stages, and each falling piece's own.
	if entry != null:
		var to_world: Basis = local.root.global_basis * frame_basis.transposed()
		var air: Vector3 = to_world * vessel.airspeed(vessel.r, vessel.v, _b).to_v3()
		var q := float(U.nz(vessel.telemetry.get("heat"), 0.0))
		for st in vessel.stages:
			var cs = craft.stage(str(st.spec.key))
			if cs != null and st.attached and not cs.handed: entry.drive(cs.group, q, air)
		var atm = vessel.env.get("atm")
		for f: Fall in falls:
			if f.state != "fall" or atm == null or not is_instance_valid(f.body): continue
			var fa := vessel.airspeed(f.r, f.v, _b)
			var fq := Rocketry.heat_flux(Rocketry.density(atm, f.altitude(vessel)), fa.length(), f.D * 0.25, atm)
			entry.drive(f.body, fq, to_world * fa.to_v3())
		# The layer's spectrum, solved once a second of flight like the blackout.
		if atm != null and q > Plume.EntryGlow.Q_ON * 0.5 and (vessel.met - _spectrum_met >= 1.0 or vessel.met < _spectrum_met):
			_spectrum_met = vessel.met
			var pr := Rocketry.profile(atm, maxf(alt, 0.0))
			entry.spectrum(PlasmaSpectrum.shock_state(atm, pr[0], pr[1], air.length(), str(env.name)), q)
		entry.update(dt, vessel.met)

	# The deflected exhaust. Only while the jet still lands on the deck, which
	# the ground flame works out for itself from the vehicle's height.
	if pad_fire != null:
		var lit: float = vessel.throttle if float(vessel.telemetry.get("thrust", 0.0)) > 0.0 else 0.0
		pad_fire.update(lit if site.group.visible else 0.0, alt + site.deck_height, plume_reach, vessel.met)
		# The same fire lights the smoke from below while the jet still reaches the deck.
		Plume.fire_level = lit * clampf(1.0 - (alt + site.deck_height) / maxf(plume_reach * 1.5, 1.0), 0.0, 1.0)
		smoke.fire_pos = Vector3(site_local.x, 0.0, site_local.z)
	else:
		Plume.fire_level = 0.0

	_update_smoke(dt, alt)

	_pad_view_lost(alt)

	# cameras. The local camera is real; the orrery camera is slaved to it.
	var sun_l := Vector3(sun.dot(east), sun.dot(up), sun.dot(north)).normalized()
	if subject != null:
		# A falling piece tumbles: frame it world-locked, chutes and all.
		fly_cam.update({"craftPos": subject.pos, "craftBasis": Basis(), "length": subject.frame_length(),
			"up": Vector3(0, 1, 0), "dt": dt, "sunLocal": sun_l})
		# A piece afloat sits partly under the sea; keep the eye above it.
		if fly_cam.pos.y < 2.0:
			fly_cam.pos.y = 2.0
			fly_cam.look_at(subject.pos, Vector3.UP)
	elif (flying or autoland) and heli != null and ground_site != null:
		interior.set_enabled(false, craft, vessel.vehicle)
		var hb := _site_basis * Basis(heli.q.to_quaternion())
		fly_cam.update({"craftPos": heli_local(), "craftBasis": hb,
			"length": 1.2, "up": Vector3(0, 1, 0), "dt": dt, "sunLocal": sun_l, "interior": {}})
	elif driving and rover != null and ground_site != null:
		interior.set_enabled(false, craft, vessel.vehicle)
		var rb := _site_basis * Basis(rover.q.to_quaternion())
		if fly_cam.state.mode == "mast":
			# The mast's head, 2.2 m over the ground, looking ahead and a little down, as its cameras do.
			var head := Vector3(-0.45, 2.2 - float(rover.spec.com_height) - 0.12, 0.95)
			fly_cam.pos.copy_from(rover_local()).add_in(DVec3.from_v3(rb * head))
			fly_cam.look_at(fly_cam.pos.clone().add_in(DVec3.from_v3(rb * Vector3(0.0, -0.25, 1.0))), Vector3.UP)
			fly_cam.near = 0.05
		else:
			fly_cam.update({"craftPos": rover_local(), "craftBasis": rb,
				"length": float(rover.spec.size[2]), "up": Vector3(0, 1, 0), "dt": dt, "sunLocal": sun_l, "interior": {}})
	else:
		interior.set_enabled(fly_cam.state.mode == "interior", craft, vessel.vehicle)
		var afloat := vessel.afloat()
		# A capsule is framed by its own size, not its canopies'; afloat it rolls with the sea, so it is
		# framed level.
		var hull = SurfaceSea.hull_for(vessel.vehicle)
		var span: float = hull.span() if craft.stage(hull.stage_key()) != null else (craft.height if craft.height else vessel.length)
		fly_cam.update({"craftPos": craft_pos, "craftBasis": Basis() if afloat else craft_basis,
			"length": span, "up": Vector3(0, 1, 0),
			"dt": dt, "sunLocal": sun_l, "interior": vessel.vehicle.get("interior", {})})
		if afloat and fly_cam.state.mode != "interior" and fly_cam.pos.y < _sea_level_y + 1.2:
			fly_cam.pos.y = _sea_level_y + 1.2
			fly_cam.look_at(craft_pos, Vector3.UP)
	if docking != null and fly_cam.state.mode == "berth":
		var pod := vessel.vehicle_key == "evapod"
		var offset := Vector3(-13, 8, -9) if pod else Vector3(-52, 40, -38)
		var aim := Vector3(0, -5, -1.5) if pod else Vector3(0, -14, -7)
		var basis_ := docking.craft.group.basis
		var boom := (offset-aim).rotated(Vector3.BACK,berth_pan.x)
		boom = boom.rotated(boom.cross(Vector3.BACK).normalized(),berth_pan.y)
		fly_cam.pos.copy_from(craft_pos).add_in(DVec3.from_v3(basis_ * (aim+boom*berth_zoom)))
		fly_cam.look_at(craft_pos.clone().add_in(DVec3.from_v3(basis_ * aim)), basis_ * Vector3.BACK)
		fly_cam.near = .05
	if camera_override.is_valid(): camera_override.call(fly_cam, craft_pos, site_local, dt)
	_camera_over_ground(subject.pos if subject != null else (heli_local() if (flying or autoland) and heli != null and ground_site != null
		else (rover_local() if driving and rover != null and ground_site != null else craft_pos)))
	local.cam_pos.copy_from(fly_cam.pos)
	# The cockpit needs centimetre depth; distant bodies remain in the orrery pass.
	local.camera.far = 1.0e5 if fly_cam.state.mode == "interior" else 4.0e6
	local.camera.near = maxf(fly_cam.near, local.camera.far * 1.0e-7)
	local.camera.fov = float(fly_cam.state.fov)
	local.apply_origin(fly_cam.basis)
	if drawn and interior.authored: interior.light_windows(local.sun, local.sun2)
	# Back to front for this frame's camera, now that it is placed.
	if drawn: smoke.draw(local.camera, site.steam if site != null else null)

	# Map the local camera into the orrery, in double (it is the floating origin).
	if main != null:
		var ss: float = state.scene_scale
		var parent_scene: DVec3 = vessel.parent.scene_pos
		var cl := fly_cam.pos.sub(craft_pos)
		# rotate the local offset out of the local frame, then the parent's, into world axes
		var world_off := east.scaled(cl.x).add_scaled_in(up, cl.y).add_scaled_in(north, cl.z).add_in(vessel.r)
		if not kerr_demo.is_empty():
			# The lens uses Cartesian Kerr–Schild positions. On the equator its
			# cylindrical radius is sqrt(r_BL² + a²), not the clock formula's r_BL.
			var orbit: Dictionary=kerr_demo.orbit
			world_off.add_scaled_in(vessel.r,sqrt(1.0+pow(float(orbit.spin)/float(orbit.radiusM),2))-1.0)
		vessel.to_world(world_off, world_off)
		var k := ss / Rocketry.AU_M
		# In place: the orbit camera holds this same DVec3 as its position.
		main.cam_pos.copy_from(parent_scene).add_scaled_in(world_off, k)
		main.cam_basis = (Basis(vessel.frame.to_quaternion()) * frame_basis * fly_cam.basis).orthonormalized()
		main.cam_fov = float(fly_cam.state.fov)
		# Near stated explicitly: main.gd ties far to it, and a close-up's 1e-6 would cull
		# every planet past 10 scene units.
		main.cam_near = 0.01

## The ground under the vessel as drawn: the adopted survey in the local frame, with the planet's patch
## dropped under its grids; over the measured grid alone, the patch at the height under the subject, so
## the gear and the drawn ground meet either way.
func _place_ground(east: DVec3, up: DVec3, north: DVec3, R_loc: float, fr: Dictionary, sun_ang: float) -> void:
	var g: SurfaceGround = vessel.ground
	if g != _drawn_ground:
		_drop_ground_site()
		_drawn_ground = g
	if g == null: return
	if not g.adopted:
		var sub := _subject_r()
		ground_pos.y = vessel.altitude(sub) - vessel.height_above_ground(sub)
		return
	if ground_site == null:
		# Built when drawn: an undrawn flight needs only the physics' grids.
		if fr.is_empty(): return
		ground_site = SurfaceSite.new(local, vessel.parent, g.pin, _render_quality, g.run_seed, g.relief)
		ground_site.poll()
		local.set_ground_shadows(true)
	# The planet's patch past the grids wears the site's colours, so the far grid's rim fades into it; the
	# flight's own colours come back when the site goes.
	if ground_site.built and _patch_saved.is_empty():
		_patch_saved = {"ground": vessel.env.ground, "rock": vessel.env.rock}
		var ph := ground_site.patch_hex()
		vessel.env.ground = ph.ground
		vessel.env.rock = ph.rock
	var ax := g.site_axes(vessel)
	var rel := (ax[0] as DVec3).clone().add_scaled_in(up, -R_loc)
	var at := DVec3.new(rel.dot(east), rel.dot(up), rel.dot(north))
	var axis := func(d: DVec3) -> Vector3: return Vector3(d.dot(east), d.dot(up), d.dot(north))
	var basis := Basis(axis.call(ax[1]), axis.call(ax[2]), axis.call(ax[3])).orthonormalized()
	ground_site.group.basis = basis
	local.place(ground_site.group, at)
	_site_at.copy_from(at)
	_site_basis = basis
	ground_pos.y = at.y + ground_site.patch_y
	if rover != null: _draw_rover(basis.inverse() * (fr.sun_local as Vector3) if fr.has("sun_local") else Vector3.UP)
	if heli != null:
		if heli_model == null:
			heli_model = RotorcraftModel.build(heli.spec)
			ground_site.group.add_child(heli_model.group)
		heli_model.update(heli)
	if not fr.is_empty():
		var to_site := basis.inverse()
		ground_site.light_terrain(to_site * (fr.sun_local as Vector3), (to_site * craft_pos.sub(at).to_v3()).y, 0.0, sun_ang)
		# The rocks follow the eye over the ground (the site's x runs west).
		var eye := to_site * local.cam_pos.sub(at).to_v3()
		ground_site.follow_eye(-eye.x, eye.z)

# The jet of the lit stage over the drawn site: where its axis meets the ground, and how high its nozzles stand.
func _step_plume_dust(dt: float, fr: Dictionary) -> void:
	var thrust := float(vessel.telemetry.get("thrust", 0.0)) if vessel.throttle > 0.0 else 0.0
	if plume_dust == null:
		if thrust <= 0.0: return
		plume_dust = PlumeDust.new(float(vessel.env.gSurf), vessel.env.atm != null, hash(vessel.id))
	# Flown undrawn for a while: what it raised has long settled.
	if vessel.met - plume_dust.met > 2.0: plume_dust.count = 0
	plume_dust.met = vessel.met
	var nozzle_c := Vector3.ZERO
	for st in vessel.stages:
		if st.attached and vessel.lit(st):
			var cs = craft.stage(str(st.spec.key))
			if cs != null: nozzle_c = cs.group.position
			break
	var to_site := _site_basis.inverse()
	var nozzle: Vector3 = to_site * (craft_pos.sub(_site_at).to_v3() + craft.group.basis * nozzle_c)
	var axis: Vector3 = (to_site * (craft.group.basis * Vector3.DOWN)).normalized()
	var rel := ground_site.relief
	var hit := nozzle
	if axis.y < -0.2:
		for i in 2:
			var gy := SiteScene.drawn_height(rel.grids, -hit.x, hit.z, ground_site.patch_y, rel.radius_m, false)
			if is_nan(gy): return
			hit = nozzle + axis * ((nozzle.y - gy) / -axis.y)
	else:
		thrust = 0.0
	plume_dust.step(dt, hit, nozzle.distance_to(hit), thrust)
	var tint := (ground_site._mat.get_shader_parameter("uSoil") as Vector3)
	# Drawn unshaded, so lit here: by the day that reaches the site, dark under a night sky.
	var sun_y: float = (to_site * (fr.get("sun_local", Vector3.UP) as Vector3)).normalized().y
	var day := clampf(sun_y * 3.0, 0.03, 1.0)
	plume_dust.draw(ground_site.group, (Color(tint.x, tint.y, tint.z) * day).linear_to_srgb())

# The drawn site's dust: what a storm has lifted (LocalView's fog and the Sun's extinction) and the devils.
func _step_site_weather(dt: float, fr: Dictionary) -> void:
	var wx := ground_site.weather
	wx.stated = weather_stated
	var w := wx.now()
	var soil := (ground_site._mat.get_shader_parameter("uSoil") as Vector3)
	local.dust_extra = maxf(float(w.dust_tau) - wx.dust_tau, 0.0)
	local.dust_tint = Color(soil.x, soil.y, soil.z) * 1.3
	if wx.dust_tau <= 0.0 or fr.is_empty(): return
	if dust_devils == null: dust_devils = DustDevils.new(hash([vessel.id, "devils"]))
	dust_devils.scale = float(weather_stated.get("devils", 1.0))
	var to_site := _site_basis.inverse()
	var sun_site: Vector3 = (to_site * (fr.get("sun_local", Vector3.UP) as Vector3)).normalized()
	var wv := SurfaceSite.wind_vector(float(w.wind_dir)) * float(w.wind)
	var eye := to_site * local.cam_pos.sub(_site_at).to_v3()
	var rel := ground_site.relief
	var py := ground_site.patch_y
	dust_devils.step(dt, asin(clampf(sun_site.y, -1.0, 1.0)), Vector2(-wv.x, wv.z), Vector2(-eye.x, eye.z), TAU / maxf(wx.omega, 1e-7))
	var day := clampf(sun_site.y * 3.0, 0.05, 1.0)
	dust_devils.draw(ground_site.group, (Color(soil.x, soil.y, soil.z) * day).linear_to_srgb(),
		func(e: float, n: float) -> float: return SiteScene.drawn_height(rel.grids, e, n, py, rel.radius_m, false))

func _draw_rover(sun_site := Vector3.UP) -> void:
	if rover_model == null:
		rover_model = RoverModel.build(rover.spec)
		ground_site.group.add_child(rover_model.group)
	rover_model.group.transform = RoverModel.site_transform(rover)
	rover_model.update(rover, rover_arm)
	rover_tracks.draw(ground_site.group, sun_site)
	var tint := (ground_site._mat.get_shader_parameter("uSoil") as Vector3)
	rover_dust.draw(ground_site.group, Color(tint.x, tint.y, tint.z).linear_to_srgb())

# Real ground can rise between a chase camera and its subject: keep the eye over the drawn site and
# still looking at the subject.
func _camera_over_ground(target: DVec3) -> void:
	if ground_site == null or not ground_site.built or fly_cam.state.mode == "interior": return
	var rel := _site_basis.inverse() * fly_cam.pos.sub(_site_at).to_v3()
	var g := SiteScene.drawn_height(ground_site.relief.grids, -rel.x, rel.z, ground_site.patch_y, ground_site.relief.radius_m, false)
	if is_nan(g) or rel.y >= g + CAMERA_CLEAR: return
	fly_cam.pos.add_in(DVec3.from_v3(_site_basis * Vector3(0.0, g + CAMERA_CLEAR - rel.y, 0.0)))
	fly_cam.look_at(target, Vector3.UP)

var _patch_saved := {}

func _drop_ground_site() -> void:
	if not _patch_saved.is_empty() and vessel != null:
		vessel.env.ground = _patch_saved.ground
		vessel.env.rock = _patch_saved.rock
	_patch_saved = {}
	if plume_dust != null:
		plume_dust.dispose()
		plume_dust = null
	if dust_devils != null:
		dust_devils.dispose()
		dust_devils = null
	local.dust_extra = 0.0
	if ground_site != null:
		_drop_rover_views()
		ground_site.dispose()
		ground_site = null
		local.set_ground_shadows(false)
	_drawn_ground = null

## The sea under a vessel coming down to float: the recovery area's site, drawn from the vessel's own field
## and clock, the patch dropped under it, and, afloat, the craft where its Floater has it.
func _place_sea(east: DVec3, up: DVec3, north: DVec3, R_loc: float, fr: Dictionary, dt: float) -> void:
	var sea: SurfaceSea = vessel.sea
	if sea == null or not sea.adopted:
		_drop_sea_site()
		_pose_capsule()
		return
	var ax := sea.site_axes(vessel)
	var rel := (ax[0] as DVec3).clone().add_scaled_in(up, -R_loc)
	var at := DVec3.new(rel.dot(east), rel.dot(up), rel.dot(north))
	var axis := func(d: DVec3) -> Vector3: return Vector3(d.dot(east), d.dot(up), d.dot(north))
	var basis := Basis(axis.call(ax[1]), axis.call(ax[2]), axis.call(ax[3])).orthonormalized()
	_sea_level_y = at.y
	if vessel.afloat():
		# The craft's stage origin is the shield's lowest point; the floater's, its centre of mass.
		var centre: Vector3 = sea.hull.centre()
		var pose := sea.floater.transform() * Transform3D(Basis(), -centre)
		craft_pos.copy_from(at).add_in(DVec3.from_v3(basis * pose.origin))
		craft.group.basis = (basis * pose.basis).orthonormalized()
	_pose_capsule()
	if fr.is_empty(): return
	if sea_site == null:
		sea_site = SurfaceSite.new(local, vessel.parent, sea.pin, _render_quality, vessel.ground_seed)
		sea_site.use_ocean(sea.field)
	if not sea_site.built:
		sea_site.poll()
		if not sea_site.built: return
	sea_site.group.basis = basis
	local.place(sea_site.group, at)
	ground_pos.y = at.y + sea_site.patch_y
	var to_site := basis.inverse()
	var cam_site := to_site * local.cam_pos.sub(at).to_v3()
	var tint := Vector3(0.3, 0.45, 0.7)
	var atm = vessel.env.atm
	if atm != null:
		var c := Color.hex((int(atm.tint) << 8) | 0xff)
		tint = Vector3(c.r, c.g, c.b)
	var gm := local.ground_mat
	sea_site.sea_time = sea.site_time(vessel)
	var w := sea.weather.now()
	# The sea in the ground's light: the star's flux through the exposure (uSunI is 3 at Earth's) and what the
	# air leaves of the sunlight, so a sea at Saturn is not lit as one at 1 AU.
	var flux := float(gm.get_shader_parameter("uSunI")) / 3.0
	var through: Vector3 = gm.get_shader_parameter("uSunTint")
	sea_site.draw_sea(dt, to_site * (fr.sun_local as Vector3), through * flux * float(fr.get("sun_visible", 1.0)), tint * 0.55 * flux,
		gm.get_shader_parameter("uHaze"), float(gm.get_shader_parameter("uDensity")), float(gm.get_shader_parameter("uScaleH")),
		float(w.cover), cam_site, sea_site.fill_tint() * flux)

# The parent's stated seas in the flight frame now: [[unit centre, angular radius rad], …], for the ground patch.
func _maria() -> Array:
	var b: Body = vessel.parent
	if b == null or not StatedSeas.has(b.name): return []
	var theta := vessel.body_angle(vessel.coord)
	var out := []
	for cap: Array in StatedSeas.caps(b.name, b.radius * Rocketry.AU_M):
		out.append([SurfaceGround.from_mesh(DVec3.from_v3(cap[0]), theta, DVec3.new()), cap[1]])
	return out

# A floating capsule's bags and canopies: the vessel's chute in the air, the Floater's on the sea.
func _pose_capsule() -> void:
	if craft == null: return
	var hull = SurfaceSea.hull_for(vessel.vehicle)
	var cs = craft.stage(hull.stage_key())
	if cs == null: return
	var sea: SurfaceSea = vessel.sea
	if vessel.afloat():
		var fill := clampf((sea.site_time(vessel) - sea.bags_at) / Capsule.INFLATE_S, 0.0, 1.0) if sea.bags_at >= 0.0 else 0.0
		hull.pose_model(cs.group, fill, "mains" if sea.floater.chute != null else "", 1.0)
		return
	var ch = vessel.chute_open
	# The first chute out is the CM's drogues or TiME's main; the second, the CM's mains or TiME's stabiliser.
	var second: bool = autopilot != null and autopilot.mains_out
	hull.pose_model(cs.group, 0.0, "" if ch == null else ("mains" if second else "drogue"), vessel.chute_deploy)

func _drop_sea_site() -> void:
	if sea_site != null:
		sea_site.dispose()
		sea_site = null

## The floating craft's line on the flight HUD: how it floats, the sea and the wind.
func sea_readout() -> String:
	var sea: SurfaceSea = vessel.sea
	var f := sea.floater
	var heel := sea.heel()
	var cm: bool = sea.hull == Capsule
	var attitude := ("Stable I (upright)" if cm else "upright") if heel < 60.0 else ("on its side" if heel < 100.0 else
		("Stable II (inverted)" if cm else "capsized"))
	var w := sea.weather.now()
	var line := "Afloat · %s, heel %s° · Hs %s m, %s s · wind %s m/s · drift %s m" % [attitude, U.fixed(heel, 0),
		U.fixed(sea.field.hs(), 1), U.fixed(TAU / sea.field.peak_omega, 1), U.fixed(float(w.wind), 1), U.fixed(Vector2(f.p[0], f.p[2]).length(), 0)]
	if sea.bags_at >= 0.0:
		line += " · bags %s%%" % U.fixed(100.0 * clampf((sea.site_time(vessel) - sea.bags_at) / Capsule.INFLATE_S, 0.0, 1.0), 0)
	elif heel > 60.0 and cm:
		line += " · G inflates the uprighting bags"
	return line

## Hand the pad camera over to chase once the vehicle climbs out of frame.
func _pad_view_lost(alt: float) -> void:
	if fly_cam.state.mode == "pad" and alt > maxf(craft.height * 22.0, 1500.0):
		fly_cam.set_mode("chase")
		vessel.log_event("Camera — pad view lost, tracking from the vehicle")

## What a fast-forward keeps of the presentation: the plumes and the smoke, whose
## trail and pad cloud are history (see fast_forward), and the pad camera's hand-over.
func _history(dt: float, alt: float) -> void:
	if fast_forward == 1:
		_update_plumes(alt)
		_update_smoke(dt, alt)
	_pad_view_lost(alt)

## Each engine's plume at the ambient pressure it is actually in, and the separation
## motors on their stage's clock from the moment it let go.
func _update_plumes(alt: float) -> void:
	var env: Dictionary = vessel.env
	Plume.freestream_q = float(vessel.telemetry.get("q", 0.0)) if env.atm != null else 0.0
	Plume.airspeed = float(vessel.telemetry.get("airspeed", 0.0)) if env.atm != null else 0.0
	var pa: float = Rocketry.pressure(env.atm, maxf(alt, 0.0)) if env.atm != null else 0.0
	var p0: float = float(env.atm.p0) if env.atm != null else 101325.0
	for pl in plumes:
		var st = null
		for s in vessel.stages:
			if str(s.spec.key) == pl.stage_key: st = s
		var on: bool = st != null and vessel.lit(st) and vessel.throttle > 0.0
		pl.update(vessel.throttle if on else 0.0, pa, vessel.met, p0)
	for b in sep_plumes:
		var cs: CraftModel.CraftStage = b.stage
		var thr := 0.0
		if cs.sep != null and cs.sep.motors != null:
			thr = Separation.motor_fraction(float(cs.sep.t), cs.sep.motors)
		b.fx.update(thr, pa, vessel.met, p0)

## Launch smoke: the pad cloud while the jet still reaches the deck, then the trail.
func _update_smoke(dt: float, alt: float) -> void:
	var env: Dictionary = vessel.env
	var craft_basis := frame_basis.transposed() * Basis(vessel.q.to_quaternion())
	var thrusting := vessel.throttle > 0.0 and float(vessel.telemetry.get("thrust", 0.0)) > 0.0
	smoke.wind = PAD_WIND
	# Held in the lab, the vehicle stands still and the air goes by.
	if lab != null: smoke.wind -= craft_basis * Vector3.UP * float(lab.speed)
	if env.atm != null and thrusting and site != null and site.group.visible and alt < 900.0:
		# Soot from the propellant: alumina (solid), carbon (RP-1), steam (hydrogen).
		var soot := 0.7
		var s0 = vessel.stages[0].spec if not vessel.stages.is_empty() else null
		if s0 != null and s0.get("engine") != null and Plume.PROPELLANT.has(s0.engine.get("plume", "")):
			soot = Plume.PROPELLANT[s0.engine.plume].soot
		var spread := maxf(vessel.diameter * 2.2, 12.0)
		var reach_k := clampf(1.0 - (alt + site.deck_height) / maxf(plume_reach * 1.5, 1.0), 0.0, 1.0)
		# A trench throws it out of both ends; an open deflector every way.
		var axis: Vector3 = Vector3.ZERO if site.style == "chopsticks" else (site.group.basis * Vector3(1, 0, 0)).normalized()
		smoke.emit(Vector3(site_local.x, -site.deck_height * 0.6, site_local.z), vessel.throttle * reach_k, spread, dt, soot, axis)
	_lay_trails(env.atm != null, env.atm != null and thrusting and alt > 20.0)
	if cryo != null:
		var fuelled := vessel.phase == Vessel.PHASE.PRELAUNCH and env.atm != null
		cryo.update(dt, fuelled, vessel.met, smoke)
	smoke.update(dt)
	rcs_puffs.update(dt)

# DROPPED PIECES
## Separation is done with a stage that has a fate (`look.fall`): each of its pieces
## flies on as a Fall, drawn in the local frame and no longer part of the craft.
func _release(cs: CraftModel.CraftStage, s: Dictionary) -> void:
	for b: Dictionary in s.bodies:
		var f := Fall.handoff(vessel, craft, cs, s, b)
		# Plumes that hang on the piece go with it; nothing drives them now.
		plumes = plumes.filter(func(pl): return not f.body.is_ancestor_of(pl.mesh))
		sep_plumes = sep_plumes.filter(func(sp): return not f.body.is_ancestor_of(sp.mount))
		f.holder = Node3D.new()
		f.body.reparent(f.holder, false)
		_adopt(f)

func _adopt(f: Fall) -> void:
	f.holder.name = "fall_" + f.name.to_snake_case()
	if entry != null and f.body != null: entry.split(f.body, f.D)
	local.root.add_child(f.holder)
	local.place(f.holder, f.pos)
	falls.append(f)

func _drop_fall(f: Fall) -> void:
	if f.holder != null and is_instance_valid(f.holder):
		local.unplace(f.holder)
		f.holder.queue_free()

## Take in what the pieces shed this frame, retire the finished ones, and draw the rest
## in the local frame (origin `up`·R, axes east, up, north).
func _place_falls(east: DVec3, up: DVec3, north: DVec3, radius: float) -> void:
	var i := 0
	while i < falls.size():
		var f: Fall = falls[i]
		for c: Fall in f.shed: _adopt(c)
		f.shed.clear()
		i += 1
	var origin := up.scaled(radius)
	var to_local := frame_basis.transposed()
	for f: Fall in falls:
		if f.follow: _log_fall(f)
	for f: Fall in falls.duplicate():
		if f.retired(f == subject):
			if f == subject: follow(null)
			_drop_fall(f)
			falls.erase(f)
			continue
		f.place(vessel, origin, to_local, east, up, north)
		# Past a couple of thousand kilometres it is under a pixel and over the horizon.
		f.holder.visible = f.pos.length() < 2.0e6

const FALL_EVENTS := {"apogee": "apogee", "noseCap": "nose cap off, pilot chute", "drogue": "drogue",
	"frustum": "frustum away, main chutes", "splashdown": "splashdown", "breakup": "breaks up"}

## A main piece's events in the mission log, with where they happened.
func _log_fall(f: Fall) -> void:
	while f.logged < f.events.size():
		var e: Dictionary = f.events[f.logged]
		f.logged += 1
		if not FALL_EVENTS.has(e.name): continue
		var msg := "%s — %s · %s km, %s m/s" % [f.name, FALL_EVENTS[e.name], U.fixed(float(e.alt) / 1000.0, 1),
			U.fixed(float(e.speed), 0)]
		if e.name == "splashdown" and site_pos != null:
			msg += ", %s km downrange" % U.fixed(float(vessel.env.radius) * DQuat.angle_between(site_pos, f.r) / 1000.0, 0)
		var geo = geo_of(f.r)
		if e.name == "breakup" and geo != null:
			msg += ", %s° %s %s° %s" % [U.fixed(absf(geo.x), 1), "N" if geo.x >= 0.0 else "S",
				U.fixed(absf(geo.y), 1), "E" if geo.y >= 0.0 else "W"]
		vessel.log_event(msg)

## Latitude and longitude, degrees, of a point in the parent frame: from the pad, which
## turns with the planet, and its mapped coordinates. Null with no mapped pad.
func geo_of(p: DVec3):
	if map_site == null or site_pos == null: return null
	var pole := DVec3.new(0.0, -1.0, 0.0)
	var u := DQuat.nrm(p.clone())
	var s := DQuat.nrm(site_pos.clone().add_scaled_in(pole, -site_pos.dot(pole)))
	# East at the pad: ω̂ × r̂, with ω̂ = −Y.
	var e := pole.cross(s)
	var dlon := rad_to_deg(atan2(u.dot(e), u.dot(s)))
	return Vector2(rad_to_deg(asin(clampf(u.dot(pole), -1.0, 1.0))), wrapf(float(map_site.lon) + dlon, -180.0, 180.0))

## Follow a dropped piece with the camera and the local frame, or the vehicle (null).
func follow(f) -> void:
	if f == subject: return
	subject = f
	if fly_cam.state.mode in ["cockpit", "interior"]: set_camera_mode("chase")
	if vessel != null:
		vessel.log_event("Camera — following the %s" % f.name.to_lower() if f != null else "Camera — back on the vehicle")

## The next piece the camera can follow, then back to the vehicle.
func follow_next() -> void:
	var can := falls.filter(func(f: Fall) -> bool: return f.follow and f.state != "gone")
	if can.is_empty():
		follow(null)
		return
	var i := can.find(subject)
	follow(can[i + 1] if i + 1 < can.size() else null)

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
	var status: String=("Interstellar cruise — %s" % cruise.leg) if cruise != null else (autopilot.status if autopilot != null else "Manual control")
	if not kerr_demo.is_empty():
		var orbit: Dictionary=kerr_demo.orbit
		status="r = %s GM/c² · dt/dτ = %s× · reference at infinity"%[U.fixed(orbit.radiusM,2),U.fixed(orbit.dilation,3)]
	if heli != null and (flying or autoland):
		status = heli_readout()
	elif rover != null and driving:
		status = rover_readout()
	elif vessel.afloat():
		status = sea_readout()
	if docking!=null:
		var d: Dictionary=docking.capture if docking.latched else docking.readout
		status=("%s · %s m · %s m/s · %s rpm"%[docking.status,U.fixed(d.gap,2),U.fixed(d.speed,2),U.fixed(d.rpm,1)]) if docking.failure=="" else docking.failure
	hud.update({
		"vessel": vessel, "telemetry": t, "up": (un[0] as DVec3).to_v3(), "north": (un[1] as DVec3).to_v3(),
		"markers": markers,
		"status": status,
		"mode": autopilot.mode if autopilot != null else null,
		"program": autopilot.program if autopilot != null else null,
		"warp": str(warp()),
		"parentName": vessel.parent.name,
		"date": TimeScales.readout(state.epoch_jd, state.sim_years) if state != null and not is_nan(state.epoch_jd) else null,
		"navPoint": nav_point_readout(),
		"plan": plan_data,
		"cruise": cruise != null,
		"mission": mission,
		"docking":docking,
		"retreatKey":main.hud.binding_label(main.controls.bindings.throttle_cut) if docking != null and main != null else "",
		"dockKey":main.hud.binding_label(main.controls.bindings.dock_command) if docking != null and main != null else "",
		"skip": skip != null,
	})

## The rover's line on the flight HUD: speed, heading, slip, the tracks it leaves and how far it is from the LM.
func rover_readout() -> String:
	var slip := 0.0
	var sink := 0.0
	for wh: Rover.Wheel in rover.wheels:
		slip = maxf(slip, absf(wh.slip))
		sink = maxf(sink, wh.sinkage)
	var home := vessel.ground.site_point(vessel, vessel.r) if vessel.ground != null else Vector3.ZERO
	var away := Vector2(rover.pos.x - home.x, rover.pos.z - home.z).length()
	var name := str(rover.spec.name)
	var line := "%s · %s · heading %s° · slip %s%% · tracks %s cm · %s m from where it landed" % [name,
		("%s km/h" % U.fixed(absf(rover.speed()) * 3.6, 1)) if name == "LRV" else ("%s m/h" % U.fixed(absf(rover.speed()) * 3600.0, 0)),
		U.fixed(fposmod(rad_to_deg(rover.heading()), 360.0), 0), U.fixed(slip * 100.0, 0), U.fixed(sink * 100.0, 1), U.fixed(away, 0)]
	if rover_arm != null:
		line += " · arm %s" % ("stowed" if rover_arm.stowed and rover_arm.joints == rover_arm.target else ("on the ground" if rover_arm.placed else "moving"))
	# MEDA's air: the site's, as the surface model has it here (SurfaceSite: its weather, at the ground).
	if ground_site != null and vessel.env.atm != null:
		var w := ground_site.weather.now()
		line += " · MEDA %s Pa, %s °C, wind %s m/s" % [U.fixed(ground_site.pressure_here * 1e5, 0), U.fixed(ground_site.temp_here - 273.15, 0), U.fixed(float(w.wind), 1)]
	return line

## Distance (m) and speed (m/s) of the vessel relative to the navigation point, which
## moves with its pair's rotating frame: {name, dist, speed, closing}, or null.
func nav_point_readout():
	if nav_point == null or vessel == null: return null
	var pri: Body = nav_point.pri; var sec: Body = nav_point.sec
	if not pri.alive or not sec.alive:
		nav_point = null
		return null
	var f := Lagrange.frame(pri, sec)
	var p: DVec3 = Lagrange.points(pri, sec)[int(nav_point.idx)]
	var lx := (p.clone().sub_in(f.bary)).dot(f.x) / float(f.sep)
	var ly := (p.clone().sub_in(f.bary)).dot(f.y) / float(f.sep)
	var pv := Lagrange.velocity(f, lx, ly, 0.0)
	var dr := vessel.world_pos().sub_in(p).scale_in(Rocketry.AU_M)
	var dv := vessel.to_world(vessel.v, DVec3.new()).scale_in(Rocketry.YR_S / Rocketry.AU_M).add_in(vessel.parent.vel) \
		.sub_in(pv).scale_in(Rocketry.AU_M / Rocketry.YR_S)
	var d := dr.length()
	return {"name": "%s–%s %s" % [pri.name, sec.name, Lagrange.NAMES[int(nav_point.idx)]], "dist": d,
		"speed": dv.length(), "closing": -dr.dot(dv) / maxf(d, 1.0)}

# INPUT
## The orchestrator resolves configurable physical keys before dispatching the
## flight action. Returns true when the active vessel accepted it.
func key_action(action: String) -> bool:
	if not active or vessel == null: return false
	if docking != null:
		if action == "throttle_cut":
			docking.back_away()
			return true
		if action == "dock_command":
			docking.command_hold()
			return true
		if action != "flight_camera": return false
	if not kerr_demo.is_empty() and action not in ["warp_down","warp_up","flight_camera"]:return false
	match action:
		"warp_down":
			_manual_warp(); set_warp(warp_idx - 1); return true
		"warp_up":
			_manual_warp(); set_warp(warp_idx + 1); return true
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
		"flight_follow":
			follow_next(); return true
		"gear":
			if driving and rover_arm != null:
				_toggle_arm()
				return true
			if vessel.afloat():
				vessel.sea.inflate_bags(vessel)
				return true
			for st in vessel.stages:
				if st.attached and int(st.spec.get("look", {}).get("arms", 0)) > 0:
					arms_out = not arms_out
					_toast("Manipulators extended" if arms_out else "Manipulators parked")
					return true
			for st in vessel.stages:
				if st.attached and st.spec.get("legs"):
					st.gear_out = not st.gear_out
					break
			return true
		"helicopter":
			if heli != null and rover == null: return true
			if heli == null:
				if not deploy_heli():
					_toast("Ingenuity rides under Perseverance: land the Sky Crane and deploy the rover first")
				return true
			flying = not flying
			driving = not flying
			heli.cmd_fwd = 0.0; heli.cmd_yaw = 0.0; heli.cmd_climb = 0.0
			_toast("Flying Ingenuity" if flying else "Back at Perseverance")
			return true
		"rover":
			if rover == null:
				if not deploy_rover():
					_toast("No rover to deploy here" if vessel.vehicle.get("rover") == null else "Land on surveyed ground first")
				return true
			driving = not driving
			if driving: flying = false
			rover.throttle = 0.0
			rover.steer = 0.0
			_toast("Driving the LRV" if driving else "Back at the LM")
			return true
		"flight_camera":
			var modes := camera_modes()
			var i := modes.find(fly_cam.state.mode)
			set_camera_mode(modes[(i + 1) % modes.size()])
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
	if fly_cam.state.mode == "berth":
		berth_zoom = clampf(berth_zoom * (1.0 + delta_y*.001),.75,2.4)
		return true
	if fly_cam.state.mode == "pad" and site != null:
		pad_orbit(0.0, 0.0, 1.0 + delta_y * 0.001)
		return true
	fly_cam.state.dist = clampf(fly_cam.state.dist * (1.0 + delta_y * 0.001), 0.6, 400.0)
	return true

func drag(dx: float, dy: float) -> bool:
	if not active: return false
	if fly_cam.state.mode == "berth":
		berth_pan = (berth_pan - Vector2(dx,dy)*.004).clamp(Vector2(-.65,-.42),Vector2(.65,.42))
		return true
	if fly_cam.state.mode == "interior":
		fly_cam.state.interiorYaw = wrapf(fly_cam.state.interiorYaw - dx * 0.004, -PI, PI)
		fly_cam.state.interiorPitch = clampf(fly_cam.state.interiorPitch - dy * 0.004, -1.05, 1.05)
		return true
	if fly_cam.state.mode == "pad" and site != null:
		pad_orbit(dx * 0.006, -dy * 0.004, 1.0)
		return true
	fly_cam.state.userAimed = true
	fly_cam.state.yaw -= dx * 0.006
	fly_cam.state.pitch = clampf(fly_cam.state.pitch - dy * 0.006, -1.45, 1.45)
	return true
