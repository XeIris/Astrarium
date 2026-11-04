class_name Observatory
extends RefCounted

# The Observatory mode: the solar preset seen from a site on Earth on a civil date.
# The stage keeps the bodies, physics and sky; this sets the date, stands the
# camera on the WGS-84 surface and turns the observer with Earth's orientation on
# that date (EarthFrame). The ground, buildings and air are the flight pass's
# (SiteScene, LocalView). It opens on a picker that films each facility from the air.
# Accuracy by date: docs/physics/observatory.md.

## Clock rates, simulated seconds per real second.
const RATES := {"pause": 0.0, "1x": 1.0, "60x": 60.0, "3600x": 3600.0}
const JD_UNIX := 2440587.5
## The tightest zoom, degrees: Camera3D rejects anything under 1°.
const MIN_FOV := 1.0
## Simulated days the integration runs before the bodies are restated from their sources.
## Unchecked, the Moon leaves LunarTheory by 0.18° in 30 days; a day leaves 0.003° at most.
const RESTATE_DAYS := 1.0

var stage   # main.gd
var active := false
var site_key := "jodrell"
var lat := 0.0     # degrees
var lon := 0.0
var h := 0.0       # m
var rate := "60x"
var show_lines := true
var show_names := true
var show_bounds := false
## The last EarthFrame.site() result, refreshed every frame.
var frame := {}
var overlay: ConstellationOverlay
var picker: SitePicker
## The picker is up, filming the site.
var picking := false
var site_scene: SiteScene = null
var _hud_acc := 0.0
var _prev_home = null
var _env := {}
var _sky_gain := 1.0
## The local camera: position (m, site frame) and basis (x west, y up, z north).
var _local_pos := Vector3(0, 2, 0)
var _local_basis := Basis()
## The frame's axes in orrery space: x west, y up, z north.
var _frame_basis := Basis()
var _orbit := 0.0
var _orbit_a0 := 0.0
## A pending change of site behind the veil: "" for none.
var _swap := ""
var _veil := 0.0
## The Sun in the local frame (x west, y up, z north), for the check.
var sun_local := Vector3.UP
## The body the view follows as the sky turns, "" for none.
var tracking := ""
## Or the J2000 direction it follows, for a star or coordinates; null for none.
var tracking_dir: DVec3 = null
var _point_next := ""
var _desk_next := {}
## The instrument desk.
var desk: ObservatoryInstruments
## The stage's clock and observer settings as the mode found them, restored by leave().
var _prev_clock := {}
var _prev_fov := 0.0
var _restated_tt := NAN

func _init(main) -> void:
	stage = main
	desk = ObservatoryInstruments.new(self)
	set_site(site_key)

## Load the solar preset if needed and stand at the site on `jd` (civil, UTC from
## 1972; null = now). `opts`: site, jd or date (set_date_text), az (deg from north),
## alt (deg), rate, view (the overlays to show: "lines", "names", "bounds").
func enter(opts: Dictionary = {}) -> void:
	if stage.state.preset_key != "solar": stage.load_preset("solar")
	if not active:
		_prev_home = stage.state.home_id
		_prev_clock = {"speed": stage.state.speed, "paused": stage.state.paused, "time_scale": stage.state.time_scale}
		_prev_fov = stage.observer.fov
	active = true
	# The solar preset has no home world; the surface view stands on one.
	var earth: Body = stage.state.body_named("Earth")
	if earth != null: stage.state.home_id = earth.id
	if not stage.state.true_scale: stage.set_true_scale(true)
	_env = Rocketry.flight_env(earth)
	if site_scene == null: site_scene = SiteScene.new(stage.flight.local)
	stage.flight.local.root.visible = true
	set_site(String(opts.get("site", site_key)))
	set_civil(float(opts.jd) if opts.get("jd") != null else now_jd())
	if opts.has("date") and not set_date_text(String(opts.date)):
		push_error("observatory: not a date: %s" % opts.date)
	stage.set_cam_mode("surface")
	set_rate(String(opts.get("rate", rate)))
	if opts.has("view"):
		for k in ["lines", "names", "bounds"]: set("show_" + k, (opts.view as Array).has(k))
	stage.observer.fov = 70.0
	stage.observer.min_fov = MIN_FOV
	look(float(opts.get("az", 180.0 if lat >= 0.0 else 0.0)), float(opts.get("alt", 28.0)))
	if overlay: overlay.visible = true
	sync_hud()
	desk.follow_site()
	if opts.get("picker", false):
		open_picker()
		_orbit = float(opts.get("orbit", 0.0))
	elif opts.has("point"):
		_point_next = String(opts.point)
	_desk_next = opts

func leave() -> void:
	active = false
	desk.finish()
	stage.observer.min_fov = SkyView.SurfaceObserver.MIN_FOV
	if picking: _close_picker()
	# Only while it is the home world does the stage hide or show it.
	var earth: Body = stage.state.body_named("Earth")
	if earth != null and earth.viz != null: earth.viz.group.visible = true
	if stage.state.preset_key == "solar": stage.state.home_id = _prev_home
	for k in _prev_clock: stage.state.set(k, _prev_clock[k])
	stage.observer.fov = _prev_fov
	if overlay: overlay.visible = false
	if site_scene != null:
		site_scene.dispose()
		site_scene = null
	SkyModel.apply_day_gain(stage.pipe.sky_materials, 1.0)

## True while this mode's world is drawn in the flight pass.
func local_pass() -> bool:
	return active and stage.state.cam_mode == "surface"

# THE PICKER

## Show the facility from the air, an arrow each side, with its evening light.
func open_picker() -> void:
	if site_key == "custom": set_site(ObservatorySites.ORDER[0])
	picking = true
	tracking = ""
	tracking_dir = null
	stage.hud.set_panel_open("controlPanel", false)
	stage.hud.set_obs_picking(true)
	if overlay: overlay.visible = false
	picker.visible = true
	_film(site_key)

func _close_picker() -> void:
	picking = false
	picker.visible = false
	picker.set_veil(0.0)
	_swap = ""
	_veil = 0.0
	stage.hud.set_obs_picking(false)

## Start the film of `key`: its site, at this evening's low sun, the camera on the lit side.
func _film(key: String) -> void:
	set_site(key)
	set_civil(evening_jd(now_jd()))
	set_rate("60x")
	_orbit = 0.0
	var d: Dictionary = EarthFrame.site(tt(), deg_to_rad(lat), deg_to_rad(lon), h)
	var at := solar_state(tt())
	var sun := EarthFrame.from_scene(at.Sun[0].sub(at.Earth[0])).normalized()
	_orbit_a0 = EarthFrame.azimuth(d, sun) + 0.45
	var i := ObservatorySites.ORDER.find(key)
	picker.show_site(i, ObservatorySites.ORDER.size(), "%s, %s" % [ObservatorySites.SITES[key].name, ObservatorySites.SITES[key].where], Facilities.DATA[key])

## Move to the previous or next facility, through a fade.
func picker_step(dir: int) -> void:
	if not picking: return
	var order: Array = ObservatorySites.ORDER
	_swap = order[posmod(order.find(site_key) + dir, order.size())]

## Leave the film for the ground, at the present moment.
func observe() -> void:
	if not picking: return
	_close_picker()
	tracking = ""
	tracking_dir = null
	stage.hud.set_panel_open("controlPanel", true)
	stage.hud.set_panel_open("instrumentPanel", true)
	stage.hud.set_section_open(stage.hud.section("Observatory"), true)
	set_civil(now_jd())
	set_rate("60x")
	if overlay: overlay.visible = true
	var view: Dictionary = Facilities.DATA[site_key].view
	stage.observer.fov = 70.0
	look(float(view.az), float(view.alt))
	sync_hud()

## The civil Julian date near `jd` on its day when the Sun sets through +17° at the site.
func evening_jd(jd: float) -> float:
	var day := floorf(jd - 0.5) + 0.5
	var la := deg_to_rad(lat); var lo := deg_to_rad(lon)
	var prev := NAN
	for i in 145:
		var t := day + float(i) / 144.0
		var tti := EarthFrame.tt_of_civil(t)
		var at := solar_state(tti)
		var a := rad_to_deg(EarthFrame.altitude(EarthFrame.site(tti, la, lo, h), EarthFrame.from_scene(at.Sun[0].sub(at.Earth[0])).normalized()))
		if not is_nan(prev) and prev >= 17.0 and a < 17.0: return t
		prev = a
	return jd

func _camera_step(dt: float) -> void:
	if not picking:
		var d = Facilities.DATA.get(site_key)
		if d == null:
			# A custom site has no tile: its ground is its stated height, for the air and the patch.
			site_scene.patch_y = h
			_local_pos = Vector3(0.0, h + 2.0, 0.0)
		else:
			var v: Dictionary = d.view
			_local_pos = Vector3(-float(v.e), site_scene.height_at(v.e, v.n) + float(v.eye), float(v.n))
		return
	var o: Dictionary = Facilities.DATA[site_key].orbit
	var secs: float = o.secs
	_orbit += dt / secs
	# One slow turn, then round again from the same light.
	if _orbit >= 1.0 and _swap == "": _swap = site_key
	var a := _orbit_a0 + _orbit * TAU
	var r: float = float(o.radius) * (1.0 + 0.1 * sin(a * 2.0))
	var e: float = float(o.e) + r * sin(a)
	var n: float = float(o.n) + r * cos(a)
	var datum := site_scene.height_at(o.e, o.n)
	var y := maxf(site_scene.height_at(e, n) + 6.0, datum + float(o.height) * (1.0 + 0.35 * sin(a + 1.0)))
	_local_pos = Vector3(-e, y, n)
	var target := Vector3(-float(o.e), datum + float(o.look), float(o.n))
	_local_basis = Basis.looking_at(target - _local_pos, Vector3.UP)

func _fade_step(dt: float) -> void:
	if _swap != "":
		_veil = minf(_veil + dt / 0.4, 1.0)
		if _veil >= 1.0:
			var next := _swap
			_swap = ""
			_film(next)
	elif _veil > 0.0:
		_veil = maxf(_veil - dt / 0.6, 0.0)
	picker.set_veil(_veil)

static func now_jd() -> float:
	return Time.get_unix_time_from_system() / 86400.0 + JD_UNIX

## Face compass azimuth `az_deg` (from north through east) at altitude `alt_deg`.
func look(az_deg: float, alt_deg: float) -> void:
	stage.observer.azimuth = -deg_to_rad(az_deg)
	stage.observer.elevation = deg_to_rad(alt_deg)

func set_site(key: String) -> void:
	if not ObservatorySites.SITES.has(key): return
	site_key = key
	var s: Dictionary = ObservatorySites.SITES[key]
	lat = s.lat; lon = s.lon; h = s.h
	if site_scene != null: site_scene.build(key)
	if active:
		desk.follow_site()
		sync_hud()

## A custom site; NaN keeps that coordinate.
func set_custom(la: float, lo: float, he: float) -> void:
	site_key = "custom"
	if not is_nan(la): lat = clampf(la, -90.0, 90.0)
	if not is_nan(lo): lon = wrapf(lo, -180.0, 180.0)
	if not is_nan(he): h = clampf(he, -500.0, 9000.0)
	if site_scene != null: site_scene.build("")
	if active:
		desk.follow_site()
		sync_hud()

func set_rate(key: String) -> void:
	if not RATES.has(key): return
	rate = key
	stage.state.speed = 1.0
	stage.state.paused = RATES[key] == 0.0
	# Below the Time panel's 1e-5 yr/s floor: that slider is hidden in this mode.
	stage.state.time_scale = maxf(float(RATES[key]), 1.0) / Rocketry.YR_S
	for k in RATES: stage.hud.set_active("[data-obs-rate=%s]" % k, k == key)

# TIME

func tdb() -> float:
	return TimeScales.tdb_jd(stage.state.epoch_jd, stage.state.sim_years)

func tt() -> float:
	return EarthFrame.tt_of_tdb(tdb())

func civil() -> float:
	return EarthFrame.civil_of_tt(tt())

## Jump to civil Julian date `jd`: the stage rebuilds the Solar System there.
func set_civil(jd: float) -> void:
	if not is_finite(jd): return
	var t := EarthFrame.tt_of_civil(jd)
	stage.restate_solar(EarthFrame.tdb_of_tt(t))
	_restated_tt = t
	_refresh_stars()
	if active: sync_hud()

## "YYYY-MM-DD" or "YYYY-MM-DD HH:MM[:SS]" (astronomical years), keeping the time of
## day when none is given. Returns false for text that is not a date.
func set_date_text(text: String) -> bool:
	var rx := RegEx.create_from_string("^\\s*(-?\\d{1,4})-(\\d{1,2})-(\\d{1,2})(?:[ T](\\d{1,2}):(\\d{2})(?::(\\d{2}(?:\\.\\d*)?))?)?\\s*$")
	var m := rx.search(text)
	if m == null: return false
	var mo := int(m.get_string(2)); var d := int(m.get_string(3))
	if mo < 1 or mo > 12 or d < 1 or d > 31: return false
	var frac := fposmod(civil() + 0.5, 1.0)
	if m.get_string(4) != "":
		frac = (float(m.get_string(4)) * 3600.0 + float(m.get_string(5)) * 60.0 + float(m.get_string(6))) / 86400.0
	set_civil(julian_day(int(m.get_string(1)), mo, d) + frac)
	return true

## Julian date of 0h on a calendar date: Gregorian from 1582 October 15, Julian before
## (Meeus, Astronomical Algorithms ch. 7), astronomical years.
static func julian_day(y: int, mo: int, d: int) -> float:
	var yy := y; var mm := mo
	if mm <= 2: yy -= 1; mm += 12
	var b := 0
	if y > 1582 or (y == 1582 and (mo > 10 or (mo == 10 and d >= 15))):
		var a := floori(yy / 100.0)
		b = 2 - a + floori(a / 4.0)
	return floorf(365.25 * (yy + 4716)) + floorf(30.6001 * (mm + 1)) + d + b - 1524.5

## Keep the date and set the civil time of day (hours).
func set_time_of_day(hours: float) -> void:
	set_civil(floorf(civil() - 0.5) + 0.5 + hours / 24.0)

## Keep the year and time of day and set the day of the year (1 = January 1).
func set_day_of_year(day: float) -> void:
	var c := TimeScales.calendar(civil())
	var jan1 := julian_day(int(c[0]), 1, 1)
	set_civil(jan1 + floorf(day) - 1.0 + fposmod(civil() + 0.5, 1.0))

## Keep the month, day and time of day and set the year.
func set_year(y: int) -> void:
	var c := TimeScales.calendar(civil())
	var d := mini(int(c[2]), 28 if int(c[1]) == 2 else 30 if int(c[1]) in [4, 6, 9, 11] else 31)
	set_civil(julian_day(y, int(c[1]), d) + fposmod(civil() + 0.5, 1.0))

## The Solar System at TT `tt`, name → [position (AU), velocity (AU/yr)], orrery axes:
## the solar preset's builder (JPL mean elements), with the Earth–Moon pair split about
## its barycentre by LunarTheory's Moon instead of the Moon's mean elements.
static func solar_state(tt: float) -> Dictionary:
	var out := {}
	var mass := {}
	for spec in Presets._build_solar((tt - EarthFrame.J2000) / 36525.0):
		out[spec.name] = [DVec3.from_array(spec.pos), DVec3.from_array(spec.vel)]
		mass[spec.name] = float(spec.mass)
	var f: float = mass.Moon / (mass.Earth + mass.Moon)
	var rel := [LunarTheory.position(tt), LunarTheory.velocity(tt)]
	for k in 2:
		var emb: DVec3 = out.Earth[k].scaled(1.0 - f).add(out.Moon[k].scaled(f))
		out.Earth[k] = emb.sub(rel[k].scaled(f))
		out.Moon[k] = emb.add(rel[k].scaled(1.0 - f))
	return out

# THE OBSERVER

## Per frame, in place of SurfaceObserver.update: stand on Earth's WGS-84 surface at
## the site with Earth's orientation on this date.
func place(observer: SkyView.SurfaceObserver, earth: Body, camera: Camera3D) -> void:
	# Before the eye is taken from Earth, so the whole frame sees the same bodies.
	if absf(tt() - _restated_tt) >= RESTATE_DAYS:
		_restated_tt = tt()
		stage.restate_solar(tdb())
	frame = EarthFrame.site(tt(), deg_to_rad(lat), deg_to_rad(lon), h)
	var up := EarthFrame.to_scene(frame.up)
	var north := EarthFrame.to_scene(frame.north)
	var k: float = stage.state.scene_scale / Rocketry.AU_M
	var eye: DVec3 = earth.scene_pos.add(EarthFrame.to_scene(frame.offset).scaled(k))
	if tracking != "" and not picking:
		var d := target_azalt(tracking, eye)
		if d.is_empty(): tracking = ""
		else:
			observer.azimuth = -deg_to_rad(d.az)
			observer.elevation = deg_to_rad(d.alt)
	elif tracking_dir != null and not picking:
		observer.azimuth = -EarthFrame.azimuth(frame, tracking_dir)
		observer.elevation = EarthFrame.altitude(frame, tracking_dir)
	observer.update_fixed(up.to_v3(), north.to_v3(), eye, camera)
	var u := up.to_v3().normalized()
	var nv := north.to_v3()
	nv = (nv - u * nv.dot(u)).normalized()
	_frame_basis = Basis(u.cross(nv).normalized(), u, nv)
	if picking:
		# The orrery's camera follows the film's, turned into orrery axes.
		camera.transform = Transform3D(_frame_basis * _local_basis, Vector3.ZERO)
		camera.fov = 42.0
	else:
		_local_basis = _frame_basis.transposed() * camera.transform.basis

## The flight pass's sky, ground and light, from the date and the site.
func _drive_local(dt: float) -> void:
	if site_scene == null or frame.is_empty(): return
	var local: LocalView = stage.flight.local
	var m: PackedFloat64Array = frame.npb
	# LocalView's frame: the equator with the pole on −Y.
	var to_flight := func(v: DVec3) -> DVec3:
		var t := EarthFrame.apply(m, v)
		return DVec3.new(t.x, -t.z, t.y)
	var up: DVec3 = to_flight.call(frame.up)
	var north: DVec3 = to_flight.call(frame.north)
	var sun_b: Body = stage.state.body_named("Sun")
	var earth: Body = stage.state.body_named("Earth")
	var sun: DVec3 = to_flight.call(EarthFrame.from_scene(sun_b.pos.sub(earth.pos)).normalized())
	var R: float = Rocketry.figure_radius(_env.get("figure"), float(_env.radius), up)
	var fr: Dictionary = local.update({"env": _env, "altitude": _local_pos.y, "surfaceR": R, "sunDirWorld": sun,
		"upWorld": up, "northWorld": north, "starFlux": 1.0, "padWorld": up.scaled(R), "anchorWorld": up.scaled(R),
		"mapSite": {"lat": lat, "lon": lon}, "planetSpin": 0.0, "dt": dt, "frame": Basis(), "cloudWind": Vector3.ZERO,
		"cloudCover": 0.0, "sunAngR": 0.00465, "sunTeff": 5772.0, "kp": 2.0, "sun2World": null, "sun2Flux": 0.0,
		"sun2Teff": 5772.0, "starlight": 0.0})
	local.place(local.ground, DVec3.new(0.0, site_scene.patch_y, 0.0))
	local.cam_pos.set_v(_local_pos.x, _local_pos.y, _local_pos.z)
	local.camera.fov = stage.cam_fov
	local.camera.far = 4.0e6
	local.camera.near = local.camera.far * 1.0e-7
	local.apply_origin(_local_basis)
	sun_local = fr.sun_local
	# LocalView's fill stands for a sunlit planet; after dark only the sky is left.
	local._set_ambient(lerpf(0.012, 0.75, smoothstep(-0.2, 0.1, sun_local.y)))
	site_scene.light(fr.sun_local, maxf(_local_pos.y - site_scene.patch_y, 1.0))
	site_scene.animate(dt)
	# The stars dim against the day as a camera's exposure closes, as in flight.
	var want := 1.0 / (1.0 + 400.0 * float(fr.get("sun_visible", 0.0)))
	_sky_gain += (want - _sky_gain) * (1.0 - exp(-maxf(dt, 0.0) / 0.8))
	SkyModel.apply_day_gain(stage.pipe.sky_materials, _sky_gain)

## Compass azimuth and altitude (degrees) of body `name` from scene position `eye`.
func target_azalt(name: String, eye: DVec3) -> Dictionary:
	var b: Body = stage.state.body_named(name)
	if b == null or frame.is_empty(): return {}
	var d := EarthFrame.from_scene(b.scene_pos.sub(eye)).normalized()
	return {"az": rad_to_deg(EarthFrame.azimuth(frame, d)), "alt": rad_to_deg(EarthFrame.altitude(frame, d))}

## Slew to `name` and follow it, its disc a third of the frame's height at most. Refuses
## a body below the horizon, with the reason as a toast.
func point_at(name: String) -> void:
	var d := target_azalt(name, stage.cam_pos)
	if d.is_empty(): return
	if float(d.alt) < 0.0:
		stage.toast("%s is below the horizon (%+.0f°) at this site and time." % [name, d.alt], 3500)
		return
	tracking = name
	tracking_dir = null
	var b: Body = stage.state.body_named(name)
	var dist: float = b.scene_pos.distance_to(stage.cam_pos) / stage.state.scene_scale
	var ang_deg := rad_to_deg(atan(b.radius / maxf(dist, 1e-9)))
	# Most planets stop at the camera's floor, where Jupiter's true disc is about 10 pixels.
	stage.observer.fov = clampf(ang_deg * 2.0 * 3.0, MIN_FOV, 70.0)

## Slew to J2000 direction `d` and follow it, at `fov_deg`. Refuses it below the horizon.
func point_dir(d: DVec3, fov_deg := 4.0) -> void:
	var a := rad_to_deg(EarthFrame.altitude(frame, d)) if not frame.is_empty() else 0.0
	if a < 0.0:
		stage.toast("That is below the horizon (%+.0f°) at this site and time." % a, 3500)
		return
	tracking = ""
	tracking_dir = d
	stage.observer.fov = clampf(fov_deg, MIN_FOV, 70.0)

## A click on the sky chooses what the telescope points at; the view stays where it is.
func sky_click(pos: Vector2, view: Vector2) -> void:
	if frame.is_empty() or not desk.has_instrument(): return
	var t := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var ray := Vector3((pos.x / view.x * 2.0 - 1.0) * t * view.x / view.y, (1.0 - pos.y / view.y * 2.0) * t, -1.0)
	var world: Vector3 = stage.cam_basis * ray.normalized()
	var d := EarthFrame.from_scene(DVec3.from_v3(world)).normalized()
	if EarthFrame.altitude(frame, d) < 0.0: return
	# About twelve pixels of slack, whatever the zoom.
	desk.pick(d, atan(t * 24.0 / view.y))

## Back to the wide view, still facing the same way.
func wide() -> void:
	tracking = ""
	tracking_dir = null
	stage.observer.fov = 70.0

## A scene direction's altitude (rad) at the site.
func altitude_of(d_scene: DVec3) -> float:
	return EarthFrame.altitude(frame, EarthFrame.from_scene(d_scene).normalized()) if not frame.is_empty() else NAN

func _refresh_stars() -> void:
	var y := EarthFrame.year_of(tt())
	# A star moves at most ~10″ a year (Barnard's), a pixel at most every ~20 years. A rebuilt
	# catalogue answers NaN here: its stars are at their catalogue epochs.
	if stage.bright_stars != null and not absf(y - stage.bright_stars.year) <= 0.5:
		stage.bright_stars.set_epoch(y)
	if overlay and not absf(y - overlay.year) <= 0.5: overlay.set_epoch(y)

## Per frame after the camera is placed.
func update(dt: float) -> void:
	if not active: return
	if _point_next != "" and not frame.is_empty():
		point_at(_point_next)
		_point_next = ""
	if not _desk_next.is_empty() and not frame.is_empty():
		desk.apply_cli(_desk_next)
		_desk_next = {}
	_camera_step(dt)
	if picking: _fade_step(dt)
	_drive_local(dt)
	var moon: Body = stage.state.body_named("Moon")
	var moon_viz = moon.viz if moon != null else null
	if moon_viz is Bodies.AccretionWrap: moon_viz = moon_viz.inner
	if moon_viz is RockyVisual.RockyViz:
		# The orrery's lock has no librations; the instrument frames use these axes.
		(moon_viz as RockyVisual.RockyViz).hold_surface(PlanetDisc.mesh_basis("Moon", tdb()))
	if not picking: desk.update(dt)
	if overlay:
		overlay.set_reticle(_reticle_dir(), String(desk.target.get("name", "")))
		overlay.show_lines = show_lines
		overlay.show_names = show_names
		overlay.show_bounds = show_bounds
		overlay.place(stage.cam_basis, stage.cam_fov, stage.observer.up, stage.state.cam_mode == "surface" and not picking)
	_hud_acc += dt
	if _hud_acc < 0.2: return
	_hud_acc = 0.0
	_refresh_stars()
	_readouts()

## The desk's target in scene axes, or null with none.
func _reticle_dir():
	var d = desk.target_dir()
	return null if d == null or picking else EarthFrame.to_scene(d).to_v3()

# THE PANEL

## Everything in the panel that is not a per-frame readout.
func sync_hud() -> void:
	var hud = stage.hud
	for k in ObservatorySites.ORDER + ["custom"]:
		hud.set_active("[data-obs-site=%s]" % k, k == site_key)
	var where := "Custom site" if site_key == "custom" else "%s · %s" % [ObservatorySites.SITES[site_key].name, ObservatorySites.SITES[site_key].where]
	hud.set_text("obsSite", "%s — %s" % [where, ObservatorySites.describe(lat, lon, h)])
	hud.set_slider("obsLat", lat, "%.2f°" % lat)
	hud.set_slider("obsLon", lon, "%.2f°" % lon)
	hud.set_slider("obsElev", h, "%d m" % int(roundf(h)))
	for k in ["lines", "names", "bounds"]:
		hud.set_active("[data-obs-view=%s]" % k, get("show_" + k))
	var c := TimeScales.calendar(civil())
	var date_box: LineEdit = hud.get_el("obsDate")
	if date_box != null and not date_box.has_focus():
		date_box.text = "%04d-%02d-%02d" % [c[0], c[1], c[2]]
	hud.set_slider("obsYear", float(c[0]), str(c[0]))
	var doy := civil() - julian_day(int(c[0]), 1, 1) + 0.5
	hud.set_slider("obsDay", floorf(doy) + 1.0, "%d" % (int(floorf(doy)) + 1))
	var hours := fposmod(civil() + 0.5, 1.0) * 24.0
	hud.set_slider("obsTime", hours, "%02d:%02d" % [int(hours), int(fposmod(hours * 60.0, 60.0))])
	_readouts()

func _readouts() -> void:
	var hud = stage.hud
	var t := tt()
	var y := EarthFrame.year_of(t)
	var jd := civil()
	var scale := "UTC" if EarthFrame.civil_is_utc(jd) else "UT"
	hud.set_text("obsClock", "%s %s" % [TimeScales.stamp(jd), scale])
	var hours := fposmod(jd + 0.5, 1.0) * 24.0
	hud.set_slider("obsTime", hours, "%02d:%02d" % [int(hours), int(fposmod(hours * 60.0, 60.0))])
	var dt_s := EarthFrame.delta_t(y)
	var era := EarthFrame.era(y)
	hud.set_text("obsDeltaT", "%.1f s %s" % [dt_s, "measured" if era == "measured" else "± %s s" % _sig(EarthFrame.delta_t_sigma(y))])
	hud.set_text("obsTT", TimeScales.stamp(t) + " TT")
	if not frame.is_empty():
		var lst := rad_to_deg(float(frame.last)) / 15.0
		hud.set_text("obsLST", "%02dh %02dm %02ds" % [int(lst), int(fposmod(lst * 60.0, 60.0)), int(fposmod(lst * 3600.0, 60.0))])
	for n in ["Sun", "Moon"]:
		var b: Body = stage.state.body_named(n)
		if b == null or frame.is_empty(): continue
		var d: DVec3 = b.scene_pos.sub(stage.cam_pos).normalized()
		hud.set_text("obs" + n, "%+.1f°" % rad_to_deg(altitude_of(d)))
	_badge(y, era)

## Two significant figures.
static func _sig(x: float) -> String:
	if x >= 100.0: return str(int(roundf(x / 10.0) * 10.0))
	if x >= 10.0: return str(int(roundf(x)))
	return "%.1f" % x if x >= 1.0 else "%.2f" % x

## The accuracy badge: the date's era, and the error that dominates outside the range.
func _badge(y: float, era: String) -> void:
	var hud = stage.hud
	var sig := EarthFrame.delta_t_sigma(y)
	var turn := sig * 15.0   # arcseconds of sky rotation
	var angle := "%.1f°" % (turn / 3600.0) if turn >= 3600.0 else "%d′" % int(roundf(turn / 60.0)) if turn >= 60.0 else "%s″" % _sig(turn)
	var last: float = DeltaT.TABLE[-1][0]
	var label := "Measured"
	var note := "Earth's rotation from measured ΔT (%s). Precession IAU 2006, nutation IAU 2000B, proper motion from the catalogues." % DeltaT.SOURCE
	if era == "extrapolated":
		label = "Extrapolated"
		note = "ΔT after %.1f is a forecast (Espenak & Meeus, EclipseWise 2014): ± %s s, so the sky's turn is uncertain by ± %s." % [last, _sig(sig), angle]
	elif era == "outside":
		label = "Heavy approximation"
		note = "Outside %d–%d. Main error: Earth's rotation, ΔT ± %s s, turns the whole sky by ± %s. Planets come from JPL mean elements fitted to 1800–2050, and proper motion is linear." % [
			int(EarthFrame.RANGE[0]), int(EarthFrame.RANGE[1]) - 1, _sig(sig), angle]
	hud.set_obs_badge(era, label, note)
