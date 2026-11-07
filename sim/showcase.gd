class_name Showcase
extends RefCounted

# A mode that puts one world in full focus: the planet large and slowly turning under its own
# light, with a pin dropped on it from the seed. It owns no physics and no scenario; it borrows
# the stage's camera and clock, and hands them back as it found them. It is the way onto the surface
# until there is an exploration mode.

# The planet's half-width against the frame: 3.4 radii away is about 17° at a 50° field of view.
const FRAME_RADII := 3.4
const TURN_RAD_S := 0.035
# One rotation takes this long on screen, so a pin can be watched and is not gone before it is read.
const DAY_ON_SCREEN_S := 240.0
const POLE_RADII := 0.16
# Don't drop a pin until the glide in has mostly finished, so it lands where it can be seen.
const SETTLED := 1.15

var stage
var active := false
var body: Body = null
var pin: PlanetPin = null
var pins_dropped := 0
var marker: Node3D = null
var _prev := {}
var _pending_drop := false
var _pin_track := 0.0
var _hud_acc := 0.0

func _init(main) -> void:
	stage = main

## The world a showcase would open on: the named body, the focus, or the first with a climate.
func pick_world(name: String = "") -> Body:
	var state = stage.state
	if name != "":
		var named: Body = state.body_named(name)
		if named != null and named.climate != null: return named
	var focused: Body = state.body_by_id(state.focus_id)
	if focused != null and focused.climate != null: return focused
	for b: Body in state.bodies:
		if b.climate != null: return b
	return null

func enter(b: Body) -> void:
	var state = stage.state
	var cam = stage.cam
	if not active:
		_prev = {"theta": cam.theta, "phi": cam.phi, "radius": cam.radius, "follow": state.follow_id, "focus": state.focus_id,
			"time_scale": state.time_scale, "speed": state.speed, "paused": state.paused}
	active = true
	body = b
	pin = null
	# `pin=N` on the command line starts the sequence at N, to show one pin again.
	pins_dropped = maxi(int(stage._cmd.get("pin", 1)) - 1, 0)
	_clear_marker()
	state.paused = false
	stage.set_follow(b)
	_set_clock()
	_face_the_sun(b)
	cam.radius_to = minf(b.radius_scene * FRAME_RADII, 20000.0)
	_pending_drop = state.pin_on_focus
	sync_hud()

func leave() -> void:
	if not active: return
	active = false
	body = null
	pin = null
	_pending_drop = false
	_clear_marker()
	PlanetPin.release_maps()
	var state = stage.state
	var cam = stage.cam
	if _prev.is_empty(): return
	state.time_scale = _prev.time_scale
	state.speed = _prev.speed
	state.paused = _prev.paused
	stage.hud.set_slider("timescale", U.log10(state.time_scale), Hud.time_label(state.time_scale))
	state.follow_id = _prev.follow if state.body_by_id(_prev.follow) != null else null
	state.focus_id = _prev.focus if state.body_by_id(_prev.focus) != null else null
	cam.theta = _prev.theta
	cam.phi = _prev.phi
	stage.jump_cam_radius(_prev.radius)
	if state.cam_mode == "orbit": stage.update_orbit_cam()
	stage.refresh_ui()
	_prev = {}

# A day on screen, so the ground turns at a watchable rate whatever its real day is.
func _set_clock() -> void:
	var period := RockyVisual.sidereal_period_yr(body)
	if period <= 0.0: period = body.day_length if body.day_length > 0.0 else 1.0 / 365.25
	stage.set_time_scale(clampf(period / DAY_ON_SCREEN_S, 1e-5, 20.0))

func _brightest() -> Body:
	var best: Body = null
	var flux := -1.0
	for s: Body in stage.get_stars():
		var here: float = float(U.nz(s.luminosity, Stellar.luminosity(s.mass))) / maxf(body.pos.distance_sq_to(s.pos), 1e-8)
		if here > flux:
			flux = here
			best = s
	return best

func _face_the_sun(b: Body) -> void:
	var brightest := _brightest()
	if brightest == null: return
	var d: DVec3 = brightest.pos.sub(b.pos)
	# A little off the sub-solar point, for a terminator to read the relief by.
	stage.cam.phi = atan2(d.z, d.x) + 0.45
	stage.cam.theta = PI * 0.5 - 0.3

## Per drawn frame, while on. Everything here is camera and marker.
func update(dt: float) -> void:
	if not active: return
	if body == null or not body.alive or body.climate == null:
		stage.set_app_mode("sandbox")
		return
	_hud_acc += dt
	if _hud_acc >= 0.25:
		_hud_acc = 0.0
		_sync_world()
	var cam = stage.cam
	if _pending_drop and cam.radius <= body.radius_scene * FRAME_RADII * SETTLED:
		_pending_drop = false
		drop_pin()
	if pin == null:
		cam.phi += TURN_RAD_S * dt
	else:
		_track_pin(dt)
		_keep_marker()

## The next pin in this world's sequence.
func drop_pin() -> void:
	if body == null: return
	_pending_drop = false
	pins_dropped += 1
	pin = PlanetPin.drop(body, pins_dropped, int(stage._cmd.get("seed", 0)))
	_pin_track = 0.0
	_clear_marker()
	_keep_marker()
	sync_hud()

# The pin on the side we are looking at. The camera comes round to it and rides with it, since the
# surface it stands on keeps turning.
func _track_pin(dt: float) -> void:
	var viz = PlanetPin._viz(body)
	if viz == null: return
	var world: Vector3 = (viz.group.global_transform.basis * viz.surface.basis).orthonormalized() * pin.p
	# Pulled towards the star, so a pin near the terminator is seen with the lit side behind it; from
	# the side, so it stands up rather than pointing at the lens.
	var view := world
	var star := _brightest()
	if star != null: view = (world + star.pos.sub(body.pos).to_v3().normalized() * 0.55).normalized()
	var phi := atan2(view.z, view.x) + 0.35
	var theta := clampf(acos(clampf(view.y, -1.0, 1.0)) - 0.2, 0.1, PI - 0.1)
	_pin_track = minf(_pin_track + dt * 0.8, 1.0)
	var k := 1.0 - exp(-dt * (0.4 + 4.0 * _pin_track))
	var cam = stage.cam
	cam.phi += wrapf(phi - cam.phi, -PI, PI) * k
	cam.theta += (theta - cam.theta) * k

func _clear_marker() -> void:
	if marker != null and is_instance_valid(marker):
		if marker.get_parent() != null: marker.get_parent().remove_child(marker)
		marker.queue_free()
	marker = null

# On the surface mesh, so it turns with the ground. A rebuilt visual loses it, so it is put back.
func _keep_marker() -> void:
	var viz = PlanetPin._viz(body)
	if viz == null or pin == null: return
	if marker != null and is_instance_valid(marker) and marker.get_parent() == viz.surface: return
	_clear_marker()
	marker = build_marker(float(viz.R))
	viz.surface.add_child(marker)
	# Stands on the ball: a mesh's y is its pole's axis.
	var up := pin.p
	var ref := Vector3.FORWARD if absf(up.y) > 0.99 else Vector3.UP
	var x := ref.cross(up).normalized()
	marker.transform = Transform3D(Basis(x, up, x.cross(up)), up * float(viz.R))

const PIN_SHADER := preload("res://shaders/bodies/pin_marker.gdshader")

static func build_marker(radius: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Pin"
	var mat := ShaderMaterial.new()
	mat.shader = PIN_SHADER
	var pole := CylinderMesh.new()
	var height := radius * POLE_RADII
	pole.top_radius = radius * 0.004
	pole.bottom_radius = radius * 0.004
	pole.height = height
	pole.radial_segments = 8
	pole.rings = 1
	var stem := MeshInstance3D.new()
	stem.mesh = pole
	stem.material_override = mat
	stem.position.y = height * 0.5
	stem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(stem)
	var ball := SphereMesh.new()
	ball.radius = radius * 0.02
	ball.height = radius * 0.04
	ball.radial_segments = 12
	ball.rings = 6
	var head := MeshInstance3D.new()
	head.mesh = ball
	head.material_override = mat
	head.position.y = height
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)
	return root

func sync_hud() -> void:
	if not active or body == null: return
	var hud = stage.hud
	hud.set_text("scWorld", body.name)
	hud.set_text("scPinNo", "Pin %d" % pin.n if pin != null else "No pin yet")
	if pin != null:
		var lat := rad_to_deg(pin.lat)
		var lon := rad_to_deg(pin.lon)
		hud.set_text("scPinAt", "%s° %s, %s° %s" % [U.fixed(absf(lat), 2), "N" if lat >= 0.0 else "S", U.fixed(absf(lon), 2), "E" if lon >= 0.0 else "W"])
		hud.set_prose("scPinGround", str(pin.ground.text))
	else:
		hud.set_text("scPinAt", "—")
		hud.set_prose("scPinGround", "Drop a pin to see what is there." if not stage.state.pin_on_focus else "A pin drops once the world is in full focus.")
	hud.set_active("scPinAuto", stage.state.pin_on_focus)
	_sync_world()

# The world's own numbers, as they move.
func _sync_world() -> void:
	var cl: Climate = body.climate
	var hud = stage.hud
	hud.set_prose("scEra", "%s. %s" % [cl.era.label, cl.era.desc])
	hud.set_text("scTemp", "%s °C" % U.fixed(cl.celsius, 0))
	hud.set_text("scAir", Hud.format_bar(cl.air.p_dry + cl.steam * cl.steam_bar))
	hud.set_text("scGravity", "%s m/s²" % U.prec(cl.gravity, 3))
	hud.set_text("scSea", Composition.sea_state(cl))
