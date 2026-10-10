class_name TitleReel
extends RefCounted

# The title screen's backdrop: real scenes from the game, staged and filmed in turn.
# Each shot loads its own scenario through the stage and owns the camera while it
# runs. Nothing here touches the physics: a shot chooses where bodies start (on
# real orbits) and where the camera stands.

const ORDER := ["hole", "launch", "jupiter"]
## Seconds per shot, and to or from black at each end.
const LENGTH := {"hole": 16.0, "launch": 19.0, "jupiter": 15.0}
const FADE := 1.4
const KM_AU := 1000.0 / Rocketry.AU_M

var main = null
var running := false
## The shot draws in the flight pass (the Hail Mary in front of the hole).
var local_overlay := false

var _shot := ""
var _index := -1
var _t := 0.0
var _staged := false
var _pinned := false
## Bumped by every shot change, so an awaited setup that finishes late is dropped.
var _generation := 0
## User settings a shot borrows, restored by stop().
var _saved := {}
## The hole shot's foreground: its own nodes in the local world.
var _ship_root: Node3D = null
var _ship: CraftModel.Craft = null
var _ship_plumes: Array = []
var _light_key: DirectionalLight3D = null

func _init(orchestrator) -> void:
	main = orchestrator

## Start the reel. `only` holds it on one shot (no cycling, no fades), for screenshots.
func begin(only: String = "") -> void:
	if running: stop()
	running = true
	_pinned = ORDER.has(only)
	var st: SimState = main.state
	_saved = {"paused": st.paused, "speed": st.speed, "disc_temp": st.disc_temp}
	st.paused = false
	st.speed = 1.0
	_index = ORDER.find(only) if _pinned else 0
	_load(ORDER[_index])

## End the reel and give back what it borrowed. The caller resets the stage.
func stop() -> void:
	if not running: return
	_teardown_shot()
	running = false
	_generation += 1
	var st: SimState = main.state
	st.paused = _saved.get("paused", st.paused)
	st.speed = _saved.get("speed", st.speed)
	st.disc_temp = _saved.get("disc_temp", st.disc_temp)
	main.hud.set_title_veil(0.0)

## Advance the reel's clock. True when a staged shot should be drawn this frame.
func update(dt: float) -> bool:
	if not running: return false
	if not _staged:
		main.hud.set_title_veil(1.0)
		return false
	_t += dt
	var length: float = LENGTH[_shot]
	var veil := 0.0
	if not _pinned:
		veil = clampf(maxf(1.0 - _t / FADE, (_t - (length - FADE)) / FADE), 0.0, 1.0)
	main.hud.set_title_veil(veil)
	if not _pinned and _t >= length:
		_index = (_index + 1) % ORDER.size()
		_load(ORDER[_index])
		return false
	return true

## Orrery shots place the camera themselves; the launch is framed by the flight pass.
func drives_camera() -> bool:
	return running and _staged and _shot != "launch"

func place_camera(dt: float) -> void:
	match _shot:
		"jupiter": _jupiter_camera(dt)
		"hole": _hole_camera(dt)

func _load(shot: String) -> void:
	_teardown_shot()
	main.reset_stage()
	_generation += 1
	_shot = shot
	_t = 0.0
	_staged = false
	main.hud.set_title_veil(1.0)
	match shot:
		"jupiter": _stage_jupiter()
		"hole": _stage_hole()
		"launch": _stage_launch()

func _teardown_shot() -> void:
	local_overlay = false
	if _ship_root != null:
		_ship_root.get_parent().remove_child(_ship_root)
		_ship_root.queue_free()
		_ship_root = null
		_ship = null
		_ship_plumes = []
		_light_key = null
		main.flight.local.root.visible = true
		_restore_local_env()
	_staged = false

## Every shot is orbits and a camera: no trails and no spacetime mesh.
func _quiet_stage() -> void:
	main.toggle_mesh(false)
	for b in main.state.bodies:
		if b.trail != null: b.trail.node.visible = false

# JUPITER: a telephoto view from just beyond Io, all at true scale. Io is the only
# Galilean moon close enough to Jupiter for both to fill a frame together.

const JOVIAN := [
	# name, orbit km, M☉, radius km, look
	# Io draws its Galileo mosaic (PlanetMaps); the rest stand in procedurally.
	["Io", 421700.0, 4.49e-8, 1821.6, {"crater": 0.0, "regolith": 0xc9b25c, "albedo": 0.63}],
	["Europa", 671034.0, 2.41e-8, 1560.8, {"crater": 0.08, "regolith": 0xcfc6b4, "albedo": 0.67}],
	["Ganymede", 1070412.0, 7.45e-8, 2634.1, {"crater": 0.6, "regolith": 0x8a8274, "albedo": 0.43}],
	["Callisto", 1882709.0, 5.41e-8, 2410.3, {"crater": 1.0, "regolith": 0x5e564b, "albedo": 0.22}],
]
## Each moon's phase from the Sun's direction, rad (+ is the orbital sense).
const JOVIAN_PHASE := {"Io": 0.75, "Europa": -2.6, "Ganymede": 2.2, "Callisto": -1.2}

## The Jupiter shot's pace: five minutes a second.
const JOVIAN_TIME := 300.0

static func jovian_system() -> Array:
	var a_j := 5.203
	var m_j := 9.54e-4
	var v_j := Physics.circular_speed(1.0, a_j)
	var jupiter := {"type": "gas-giant", "name": "Jupiter", "mass": m_j, "radiusKm": 69911.0,
		"palette": "jupiter", "obliquity": 0.0546, "internalHeat": 1.67, "albedo": 0.503,
		# System III (9 h 55.5 m) at the shot's pace, so the turn on screen is real.
		"visualSpinRadS": TAU / 35730.0 * JOVIAN_TIME,
		"pos": [a_j, 0.0, 0.0], "vel": [0.0, 0.0, v_j]}
	var out: Array = [
		{"type": "star", "name": "Sun", "mass": 1.0, "color": 0xfff2cc, "glow": 0xffaa33,
			"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0]},
		jupiter,
	]
	for m in JOVIAN:
		var a: float = m[1] * KM_AU
		var v := Physics.circular_speed(m_j + float(m[2]), a)
		# Angles about Jupiter as the orrery measures them; the Sun is at π.
		var th: float = PI - float(JOVIAN_PHASE[m[0]])
		out.append(U.merged({"type": "planet", "name": m[0], "mass": m[2], "radiusKm": m[3], "hot": true}, U.merged(m[4], {
			"pos": [a_j + cos(th) * a, 0.0, sin(th) * a],
			"vel": [-sin(th) * v, 0.0, v_j + cos(th) * v]})))
	return out

func _stage_jupiter() -> void:
	main.load_preset_spec("title_jupiter", {
		"sky": {"env": "disc", "tilt": 0.22, "roll": 2.6},
		"name": "Jupiter", "sceneScale": 1.0, "bodyScale": 1.0, "trueScale": true,
		"camRadius": 1.0, "lensing": false, "mesh": false,
		"timeScale": JOVIAN_TIME / Rocketry.YR_S, "maxStep": 2e-7,
		"build": func() -> Array: return jovian_system(),
	})
	_quiet_stage()
	_staged = true

func _jupiter_camera(_dt: float) -> void:
	var st: SimState = main.state
	var jupiter: Body = st.body_named("Jupiter")
	var io: Body = st.body_named("Io")
	if jupiter == null or io == null: return
	var u := clampf(_t / LENGTH.jupiter, 0.0, 1.0)
	# Hang the camera off Io, outward and a little right and above, so Io sits low
	# and left of Jupiter; ease in for parallax.
	var out := io.scene_pos.sub(jupiter.scene_pos).to_v3().normalized()
	var right := (-out).cross(Vector3.UP).normalized()
	var w := (out + right * tan(lerpf(0.215, 0.20, u)) + Vector3.UP * tan(0.12)).normalized()
	var d := lerpf(33000.0, 29000.0, u) * KM_AU * st.scene_scale
	main.cam_pos.copy_from(io.scene_pos).add_in(DVec3.from_v3(w * d))
	var look := jupiter.scene_pos.rel_v3(main.cam_pos).normalized()
	main.cam_fov = 21.0
	main.cam_basis = _framed(look, 0.15, -0.025)
	main.cam_near = maxf(d - io.radius_scene, 1e-9) * 0.5

## A look basis turned so the subject sits right of centre (`side`, rad) and
## `lift` rad above it; the menu takes the left of the frame.
static func _framed(look: Vector3, side: float, lift: float) -> Basis:
	var b := Basis.looking_at(look, Vector3.UP)
	return (b * Basis(Vector3.UP, side) * Basis(Vector3.RIGHT, lift)).orthonormalized()

# THE HOLE: a 10 M☉ hole and its disc, lensed by the marcher, with the Hail Mary
# drawn in the flight pass in front of it. The ship is composited, not simulated.

const HOLE_DISC_TEMP := 0.17

func _stage_hole() -> void:
	main.load_preset_spec("title_hole", {
		"sky": {"env": "disc", "tilt": 0.62, "roll": 1.9},
		"name": "Black hole", "sceneScale": 2.0, "bodyScale": 1.0, "camRadius": 30.0,
		"lensing": true, "mesh": false, "discIntensity": 2.2, "discOuter": 15.0,
		"build": func() -> Array: return [{"type": "bh", "name": "Singularity", "mass": 10.0,
			"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0]}],
	})
	main.state.disc_temp = HOLE_DISC_TEMP
	_quiet_stage()
	var generation := _generation
	await CraftAssets.craft_models_ready(["hailmary"])
	if generation != _generation: return
	_build_ship()
	local_overlay = true
	_staged = true

func _build_ship() -> void:
	var flight: Spaceflight = main.flight
	var pipe: RenderPipeline = main.pipe
	flight.local.root.visible = false
	_ship_root = Node3D.new()
	_ship_root.name = "TitleShip"
	pipe.local_root.add_child(_ship_root)
	_ship = CraftModel.build_craft(Vehicles.VEHICLES.hailmary)
	_ship_root.add_child(_ship.group)
	_ship_plumes = Spaceflight.attach_plumes(_ship).plumes
	# Disc light from ahead and above, a cold rim from the galaxy behind the camera.
	_light_key = DirectionalLight3D.new()
	_light_key.light_color = Color(1.0, 0.72, 0.45)
	_light_key.light_energy = 1.6
	_ship_root.add_child(_light_key)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.55, 0.65, 0.9)
	fill.light_energy = 0.18
	fill.basis = Basis.looking_at(Vector3(0.3, -0.4, -1.0).normalized(), Vector3.UP)
	_ship_root.add_child(fill)
	var env: Environment = pipe.env_local
	_saved.env = {"src": env.ambient_light_source, "color": env.ambient_light_color,
		"energy": env.ambient_light_energy, "sky": env.sky}
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.05, 0.045, 0.05)
	env.ambient_light_energy = 1.0
	env.sky = null

func _restore_local_env() -> void:
	var saved = _saved.get("env")
	if saved == null: return
	var env: Environment = main.pipe.env_local
	env.ambient_light_source = saved.src
	env.ambient_light_color = saved.color
	env.ambient_light_energy = saved.energy
	env.sky = saved.sky
	_saved.erase("env")

func _hole_camera(dt: float) -> void:
	var st: SimState = main.state
	var hole: Body = st.body_named("Singularity")
	if hole == null: return
	var u := clampf(_t / LENGTH.hole, 0.0, 1.0)
	# A slow arc round the hole, just above the disc plane.
	var r := lerpf(34.0, 30.0, u)
	var az := lerpf(0.55, 0.75, u)
	var el := lerpf(0.13, 0.10, u)
	var off := Vector3(cos(az) * cos(el), sin(el), sin(az) * cos(el)) * r
	main.cam_pos.copy_from(hole.scene_pos).add_in(DVec3.from_v3(off))
	var look := hole.scene_pos.rel_v3(main.cam_pos).normalized()
	main.cam_fov = 50.0
	main.cam_basis = _framed(look, 0.24, -0.02)
	main.cam_near = 0.01
	_place_ship(dt, u)

## The ship in camera space, metres: below and right of centre, heading for the hole.
func _place_ship(dt: float, u: float) -> void:
	if _ship == null: return
	var cam_b: Basis = main.cam_basis
	var cam: Camera3D = main.pipe.local_cam
	cam.transform = Transform3D(cam_b, Vector3.ZERO)
	cam.fov = main.cam_fov
	cam.near = 0.5
	cam.far = 4.0e4
	var along := lerpf(64.0, 82.0, u)
	var p_cam := Vector3(lerpf(4.0, 6.0, u), lerpf(-13.0, -11.5, u), -along)
	_ship.group.position = cam_b * p_cam
	# Nose toward the hole's image, rolled slowly; the craft's +Y is its nose.
	var hole_dir: Vector3 = cam_b * (Basis(Vector3.UP, -0.24) * Vector3(0, 0, -1))
	var nose := (hole_dir - _ship.group.position.normalized() * 0.15).normalized()
	var side := nose.cross(Vector3.UP).normalized()
	var up_b := Basis(side, nose, side.cross(nose)).orthonormalized()
	_ship.group.basis = up_b * Basis(Vector3.UP, 2.5 + 0.05 * _t)
	_light_key.basis = Basis.looking_at(-hole_dir + Vector3(0, -0.6, 0), Vector3.UP)
	_ship.update({"dt": dt, "attached": {}, "deploy": {}, "gimbal": {"x": 0.0, "z": 0.0}, "flap": 0.0})
	for pl in _ship_plumes:
		pl.update(0.45, 0.0, _t, 101325.0)

# THE LAUNCH: Saturn V from the flight simulator, counted down on its own pad
# and filmed from above as it clears the tower.

const LAUNCH_COUNT := 6.0

func _stage_launch() -> void:
	main.load_preset("solar")
	_quiet_stage()
	var generation := _generation
	await CraftAssets.craft_models_ready(["saturnv"])
	if generation != _generation: return
	var flight: Spaceflight = main.flight
	# The pad's default morning puts the sun ~55° up; 28° further east it is ~30°
	# up, low enough to warm and to rake the deck.
	var earth: Body = main.state.body_named("Earth")
	var lon := flight.morning_longitude(earth) - 28.0
	if flight.begin("saturnv", {"mode": "pad", "lon": lon}) == null: return
	main.set_cam_mode("flight")
	flight.start_count(LAUNCH_COUNT)
	flight.camera_override = _launch_camera
	flight.fly_cam.state.fov = 40.0
	_staged = true

func _launch_camera(fly_cam: LocalView.FlightCamera, craft_pos: DVec3, site_local: DVec3, _dt: float) -> void:
	var flight: Spaceflight = main.flight
	var H: float = flight.craft.height
	var u := clampf(_t / LENGTH.launch, 0.0, 1.0)
	# High over the deck, rising with the climb, on the mount's +x side so the tower
	# (on its −x side) stands behind the stack; of the angles round that side, the
	# one most toward the sun, so the stack is front-lit.
	var away: Vector3 = flight.site.group.basis * Vector3(1.0, 0.0, 0.0) if flight.site != null else Vector3.RIGHT
	var sun_l := flight.frame_basis.transposed() * flight.sun_direction(DVec3.new()).to_v3()
	var az0 := atan2(away.z, away.x)
	var sun_az := atan2(sun_l.z, sun_l.x)
	var az := az0
	var best := -INF
	for off in [-1.1, -0.55, 0.55, 1.1]:
		var score := cos(az0 + off - sun_az) + 0.3 * cos(off)
		if score > best:
			best = score
			az = az0 + off
	var reach := H * lerpf(1.05, 0.95, u)
	var height := H * lerpf(1.55, 1.75, u) + craft_pos.y * 0.6
	var pos := site_local.clone().add_in(DVec3.new(cos(az) * reach, height, sin(az) * reach))
	fly_cam.pos.copy_from(pos)
	var aim := craft_pos.clone().add_in(DVec3.new(0.0, H * 0.42, 0.0))
	fly_cam.look_at(aim, Vector3.UP)
	fly_cam.basis = (fly_cam.basis * Basis(Vector3.UP, 0.2) * Basis(Vector3.RIGHT, 0.04)).orthonormalized()
	fly_cam.depth_range(craft_pos, H)
