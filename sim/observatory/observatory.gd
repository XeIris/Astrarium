class_name Observatory
extends RefCounted

# The Observatory mode: the solar preset seen from a site on Earth on a civil date.
# The stage keeps the bodies, physics and sky; this sets the date, stands the
# camera on the WGS-84 surface and turns the observer with Earth's orientation on
# that date (EarthFrame). Accuracy by date: docs/physics/observatory.md.

## Clock rates, simulated seconds per real second.
const RATES := {"pause": 0.0, "1x": 1.0, "60x": 60.0, "3600x": 3600.0}
const JD_UNIX := 2440587.5
## Simulated days the integration runs before the bodies are restated from their sources.
## Unchecked, the Moon leaves LunarTheory by 0.18° in 30 days; a day leaves 0.003° at most.
const RESTATE_DAYS := 1.0

var stage   # main.gd
var active := false
var site_key := "paranal"
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
var _hud_acc := 0.0
var _prev_home = null
## The stage's clock and observer settings as the mode found them, restored by leave().
var _prev_clock := {}
var _prev_fov := 0.0
var _restated_tt := NAN

func _init(main) -> void:
	stage = main
	set_site("paranal")

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
	set_site(String(opts.get("site", site_key)))
	set_civil(float(opts.jd) if opts.get("jd") != null else now_jd())
	if opts.has("date") and not set_date_text(String(opts.date)):
		push_error("observatory: not a date: %s" % opts.date)
	stage.set_cam_mode("surface")
	set_rate(String(opts.get("rate", rate)))
	if opts.has("view"):
		for k in ["lines", "names", "bounds"]: set("show_" + k, (opts.view as Array).has(k))
	stage.observer.fov = 70.0
	look(float(opts.get("az", 180.0 if lat >= 0.0 else 0.0)), float(opts.get("alt", 28.0)))
	if overlay: overlay.visible = true
	sync_hud()

func leave() -> void:
	active = false
	# Only while it is the home world does the stage hide or show it.
	var earth: Body = stage.state.body_named("Earth")
	if earth != null and earth.viz != null: earth.viz.group.visible = true
	if stage.state.preset_key == "solar": stage.state.home_id = _prev_home
	for k in _prev_clock: stage.state.set(k, _prev_clock[k])
	stage.observer.fov = _prev_fov
	if overlay: overlay.visible = false

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
	if active: sync_hud()

## A custom site; NaN keeps that coordinate.
func set_custom(la: float, lo: float, he: float) -> void:
	site_key = "custom"
	if not is_nan(la): lat = clampf(la, -90.0, 90.0)
	if not is_nan(lo): lon = wrapf(lo, -180.0, 180.0)
	if not is_nan(he): h = clampf(he, -500.0, 9000.0)
	if active: sync_hud()

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
	observer.update_fixed(up.to_v3(), north.to_v3(), eye, camera)

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
	if overlay:
		overlay.show_lines = show_lines
		overlay.show_names = show_names
		overlay.show_bounds = show_bounds
		overlay.place(stage.cam_basis, stage.cam_fov, stage.observer.up, stage.state.cam_mode == "surface")
	_hud_acc += dt
	if _hud_acc < 0.2: return
	_hud_acc = 0.0
	_refresh_stars()
	_readouts()

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
