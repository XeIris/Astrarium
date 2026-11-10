class_name SurfaceVisit
extends RefCounted

# Standing on a world at a pin: the stage's surface view, with the flight pass drawing that world's
# own ground and sky. Created when someone stands there and dropped when they leave; while it does
# not exist, none of the surface runs. It hands back the home world, size convention and view it
# found. The clock is the showcase's.

const EYE_FOV := 60.0
const HUD_EVERY := 0.25

var stage
var body: Body
var pin: PlanetPin
var site: SurfaceSite
var env := {}
var ready := false
var _prev := {}
var _frame_basis := Basis()
var _local_basis := Basis()
var _exposure := -1.0
var _hud_acc := 0.0
var _up := Vector3.UP
var _north := Vector3.FORWARD

func _init(main, b: Body, where: PlanetPin) -> void:
	SurfaceStats.count("visit_init")
	stage = main
	body = b
	pin = where

## Start the survey. The view stays in orbit until there is ground to stand on.
func begin() -> void:
	env = world_env(body)
	site = SurfaceSite.new(stage.flight.local, body, pin, stage.render_quality, int(stage._cmd.get("seed", 0)))
	stage.hud.set_surface_veil(true)

# Ground's ready: take the view down to it, keeping what must go back.
func _arrive() -> void:
	var state = stage.state
	_prev = {"home": state.home_id, "true_scale": state.true_scale, "fov": stage.observer.fov,
		"azimuth": stage.observer.azimuth, "elevation": stage.observer.elevation}
	state.home_id = body.id
	if not state.true_scale: stage.set_true_scale(true)
	stage.flight.local.root.visible = true
	stage.observer.fov = EYE_FOV
	stage.set_cam_mode("surface")
	stage.observer.elevation = 0.06
	ready = true
	_paint_env()
	stage.hud.set_surface_veil(false)

## The home world's id before this visit lent it to the world underfoot.
func home_before() -> Variant:
	return _prev.get("home")

func end() -> void:
	var state = stage.state
	if site != null:
		site.dispose()
		site = null
	if ready:
		ready = false
		state.home_id = _prev.get("home")
		if state.cam_mode == "surface": stage.set_cam_mode("orbit")
		if state.true_scale != bool(_prev.get("true_scale", state.true_scale)): stage.set_true_scale(bool(_prev.true_scale))
		stage.observer.fov = float(_prev.get("fov", stage.observer.fov))
		stage.observer.azimuth = float(_prev.get("azimuth", 0.0))
		stage.observer.elevation = float(_prev.get("elevation", 0.25))
		SkyModel.apply_day_gain(stage.pipe.sky_materials, 1.0)
		if body != null and body.viz != null: body.viz.group.visible = true
	var viz = PlanetPin._viz(body) if body != null and body.viz != null else null
	if viz != null and "display_turn" in viz: viz.display_turn = 0.0
	stage.hud.set_surface_veil(false)
	SurfaceStats.count("visit_end")

## This world's environment for the flight pass. A catalogued air is measured, and stays while the
## world is the one measured; edit it away, and the column on the world is what you stand under.
static func world_env(b: Body) -> Dictionary:
	var e := Rocketry.flight_env(b)
	var cl: Climate = b.climate
	if cl == null: return e
	var bar: float = cl.air.p_dry + cl.steam * cl.steam_bar
	var atm = e.get("atm")
	var catalogued: float = float(atm.p0) * 1e-5 if atm != null and atm.get("p0") != null else 0.0
	if atm == null or catalogued <= 0.0 or absf(bar - catalogued) > 0.2 * maxf(bar, catalogued):
		var own = cl.flight_atmosphere()
		e.atm = U.merged({"g": e.gSurf, "R": e.radius}, own) if own != null else null
	e.oceans = cl.wet and cl.ocean > 0.0
	return e

## The pass's frame: the planet's own, with its pole on −Y as the flight frame has it (Rocketry.spin_frame).
static func _to_flight(v: Vector3) -> DVec3:
	return DVec3.new(v.x, -v.y, -v.z)

## Stand the observer on the pin, from the visual's own orientation.
func place(observer: SkyView.SurfaceObserver, _home: Body, camera: Camera3D) -> void:
	var viz = PlanetPin._viz(body)
	var turn: Quaternion = viz.group.quaternion * viz.surface.basis.get_rotation_quaternion()
	_up = (turn * pin.p).normalized()
	var axis: Vector3 = turn * Vector3.UP
	_north = axis - _up * axis.dot(_up)
	if _north.length_squared() < 1e-8: _north = turn * Vector3.RIGHT
	_north = _north.normalized()
	var eye: DVec3 = body.scene_pos.add(DVec3.from_v3(_up).scaled(body.radius_scene * 1.0001))
	observer.update_fixed(_up, _north, eye, camera)
	_frame_basis = Basis(_up.cross(_north).normalized(), _up, _north)
	_local_basis = _frame_basis.transposed() * camera.transform.basis

func local_pass() -> bool:
	return ready and stage.state.cam_mode == "surface"

## One frame. `sim_years` is what the stage's clock took.
func update(dt: float, sim_years: float) -> void:
	if site == null: return
	if not ready:
		if not site.poll():
			stage.hud.set_surface_veil(true, site.relief.progress)
			return
		_arrive()
	_drive_sky(dt, sim_years)
	_hud_acc += dt
	if _hud_acc >= HUD_EVERY:
		_hud_acc = 0.0
		stage.showcase.sync_surface(readouts())

# The planet's patch past the grids wears the site's colours, in the sky's light.
func _paint_env() -> void:
	var pal := site._palette()
	var tint := site._fill_tint()
	env.ground = _tinted(int(pal.soil), tint)
	env.rock = _tinted(int(pal.a), tint)
	env.sea = 0x10304f

static func _tinted(hex: int, tint: Vector3) -> int:
	var r := mini(int(((hex >> 16) & 255) * tint.x), 255)
	var g := mini(int(((hex >> 8) & 255) * tint.y), 255)
	var b := mini(int((hex & 255) * tint.z), 255)
	return (r << 16) | (g << 8) | b

func _key_star() -> Body:
	var best: Body = null
	var best_flux := -1.0
	for s: Body in stage.get_stars():
		var d2: float = maxf(body.pos.distance_sq_to(s.pos), 1e-8)
		var flux: float = float(U.nz(s.luminosity, Stellar.luminosity(s.mass))) / d2
		if flux > best_flux:
			best_flux = flux
			best = s
	return best

func _drive_sky(dt: float, sim_years: float) -> void:
	var local: LocalView = stage.flight.local
	var viz = PlanetPin._viz(body)
	var turn: Quaternion = viz.group.quaternion * viz.surface.basis.get_rotation_quaternion()
	var to_mesh := turn.inverse()
	var up_f := _to_flight(pin.p)
	var north_f := _to_flight((to_mesh * _north).normalized())
	var key := _key_star()
	var sun_mesh := Vector3.UP
	var flux := 0.0
	var teff := 5772.0
	if key != null:
		var d: DVec3 = key.pos.sub(body.pos)
		sun_mesh = to_mesh * d.to_v3().normalized()
		flux = float(U.nz(key.luminosity, Stellar.luminosity(key.mass))) / maxf(d.length_sq(), 1e-8)
		teff = float(U.nz(key.teff, 5772.0))
	var sun_f := _to_flight(sun_mesh)
	# As flight's exposure: brightness F^0.3 below daylight, floor 0.06, none above; eased.
	var shown := flux if flux >= 1.0 else maxf(pow(maxf(flux, 1e-9), 0.3), 0.06)
	var want := shown / maxf(flux, 1e-9)
	_exposure = want if _exposure <= 0.0 else exp(lerpf(log(_exposure), log(want), 1.0 - exp(-maxf(dt, 0.0) / 1.5)))
	var star_flux := flux * _exposure
	var eye_y: float = site.eye_y
	var R: float = float(env.radius)
	var clouds_on: bool = env.atm != null and (body.climate.wet or site.sky_cover > 0.0)
	var fr: Dictionary = local.update({"env": env, "altitude": eye_y, "surfaceR": R, "sunDirWorld": sun_f,
		"upWorld": up_f, "northWorld": north_f, "starFlux": star_flux, "padWorld": null, "anchorWorld": up_f.scaled(R),
		"mapSite": null, "planetSpin": 0.0, "dt": dt, "frame": Basis(), "cloudWind": site.cloud_wind,
		"cloudCover": site.sky_cover, "cloudsOn": clouds_on, "cloudLift": maxf(site.ground_y, 0.0), "sunAngR": atan(float(key.radius) / maxf(body.pos.distance_to(key.pos), 1e-6)) if key != null else 0.00465,
		"sunTeff": teff, "kp": 0.0, "sun2World": null, "sun2Flux": 0.0, "sun2Teff": 5772.0, "starlight": 0.0})
	local.place(local.ground, DVec3.new(0.0, site.patch_y, 0.0))
	local.cam_pos.set_v(0.0, eye_y, 0.0)
	local.camera.fov = stage.cam_fov
	local.camera.far = 4.0e6
	local.camera.near = local.camera.far * 1.0e-7
	local.apply_origin(_local_basis)
	var sun_l: Vector3 = fr.sun_local
	var alt := rad_to_deg(asin(clampf(sun_l.y, -1.0, 1.0)))
	SkyModel.apply_day_gain(stage.pipe.sky_materials, SkyConditions.star_gain(SkyConditions.SITES.custom, alt) if env.atm != null else 1.0)
	var atm = env.atm
	var tint := LocalView._v3(int(atm.tint)) if atm != null else Vector3.ZERO
	var haze := LocalView._v3(int(atm.haze)) if atm != null else Vector3.ZERO
	var sun_rgb := local.sun_extinction * clampf(3.0 * star_flux, 0.0, 12.0) * maxf(sun_l.y, 0.0)
	var density := float(local.ground_mat.get_shader_parameter("uDensity"))
	var scale_h := float(local.ground_mat.get_shader_parameter("uScaleH"))
	site.update(dt, sim_years * Rocketry.YR_S, _up, stage.state.bodies, eye_y, sun_l, sun_rgb, tint * 0.55, haze, density, scale_h)

## Turn the world under the pin until the key star stands at sine `height`, or as high as it gets. A display
## shift of the visual's own spin: the orbit and climate are untouched.
func turn_to_noon(height: float) -> void:
	var key := _key_star()
	if key == null: return
	var viz = PlanetPin._viz(body)
	var d: Vector3 = key.pos.sub(body.pos).to_v3().normalized()
	# A locked world's surface carries the lock's own frame after its spin, and the lock sets the spin
	# each frame: the turn goes on top of it.
	var locked: bool = "display_turn" in viz and RockyVisual.truthy(viz.opts.tidal_lock)
	var after := Quaternion(RockyVisual.NORTH_ON_ORBIT_POLE) if locked else Quaternion()
	var best_phase: float = body.spin_phase
	var best := -INF
	for i in 96:
		var phase := TAU * i / 96.0
		var turn: Quaternion = viz.group.quaternion * Quaternion(Vector3.UP, phase) * after
		var y := (turn * pin.p).normalized().dot(d)
		var score := -absf(y - height)
		if score > best:
			best = score
			best_phase = phase
	if locked: viz.display_turn = wrapf(best_phase - (body.spin_phase - viz.display_turn), -PI, PI)
	body.spin_phase = best_phase

## What the panel reads at the pin.
func readouts() -> Dictionary:
	var w: Dictionary = site.current
	var out := {
		"temp": site.temp_here,
		"pressure": site.pressure_here,
		"gravity": body.climate.gravity,
		"wind": float(w.get("wind", 0.0)),
		"rain": float(w.get("rain_mm_h", 0.0)),
		"kind": str(w.get("kind", "none")),
		"cover": float(w.get("cover", 0.0)),
		"near_km": float(w.get("near_km", -1.0)),
		"hadley": rad_to_deg(site.weather.hadley),
		"rossby_km": site.weather.rossby / 1000.0,
		"life_d": site.weather.life_s / 86400.0,
		"tide": float(site.tide.get("height", 0.0)),
		"hs": float(site.sea.get("hs", 0.0)),
		"period": float(site.sea.get("peak_period", 0.0)),
		"has_sea": site.has_sea,
		"height": site.ground_y,
	}
	return out
