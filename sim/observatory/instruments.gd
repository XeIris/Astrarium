class_name ObservatoryInstruments
extends RefCounted

# The Observatory's instrument desk: what to observe, whether the telescope can, and taking
# frames off the main thread (Imager). Holds a frame to compare against a later one.

## The mount's on-screen speed against its published rate: a Lovell slew is ten minutes.
const SLEW_SPEEDUP := 30.0
## Under this angle from the Sun an optical telescope refuses: an estimate, listed in the doc.
const SUN_LIMIT := 30.0
const FIELDS := {"pixels": "Pixels", "wide": "Wider", "full": "Full field"}
const W_OPTICAL := 256
const W_RADIO := 128

## The Observatory, which owns this desk: weak, or neither would ever be freed.
var _owner: WeakRef
var obs: Observatory:
	get: return _owner.get_ref() as Observatory
var key := ""
## {name, kind ("body", "star", "radio", "sky"), dir (DVec3, J2000; absent for a body), v}
var target := {}
var exposure := 30.0
## Seeing in arcsec; NAN follows the site's median.
var seeing := NAN
var field := "pixels"
## Neutral density, magnitudes (Telescopes.ND).
var nd := 0.0
var frame := {}
var held := {}
var frame_image: Image = null
var held_image: Image = null
var frame_tex: ImageTexture = null
var held_tex: ImageTexture = null
var _task := -1
var _pending := {}
var _seed := 1
var _acc := 0.0
var _aim := {}

func _init(o: Observatory) -> void:
	_owner = weakref(o)

func has_instrument() -> bool:
	return key != ""

func is_exposing() -> bool:
	return _task >= 0

## Choose an instrument, moving to its site.
func set_instrument(k: String) -> void:
	if not Telescopes.INSTRUMENTS.has(k): return
	key = k
	var site: String = Telescopes.INSTRUMENTS[k].site
	if obs.site_key != site: obs.set_site(site)
	seeing = NAN
	sync()

func row() -> Dictionary:
	return Telescopes.INSTRUMENTS.get(key, {})

## The site's instrument, when the current one is elsewhere.
func follow_site() -> void:
	if not row().is_empty() and row().site == obs.site_key:
		sync()
		return
	var here := Telescopes.at_site(obs.site_key)
	key = here[0] if not here.is_empty() else ""
	seeing = NAN
	sync()

func site_seeing() -> float:
	return float(SkyConditions.SITES.get(obs.site_key, SkyConditions.SITES.custom).seeing)

func seeing_now() -> float:
	return site_seeing() if is_nan(seeing) else seeing

# TARGET

## RA and Dec (degrees) from "HH MM SS ±DD MM SS" or decimal degrees; [] if not coordinates.
static func parse_radec(text: String) -> Array:
	var parts := text.strip_edges().replace(",", " ").replace(":", " ").split(" ", false)
	for p in parts:
		if not p.is_valid_float(): return []
	var ra := NAN
	var dec := NAN
	if parts.size() == 2:
		ra = float(parts[0])
		dec = float(parts[1])
	elif parts.size() == 6:
		ra = 15.0 * (float(parts[0]) + float(parts[1]) / 60.0 + float(parts[2]) / 3600.0)
		var sign := -1.0 if parts[3].begins_with("-") else 1.0
		dec = sign * (absf(float(parts[3])) + float(parts[4]) / 60.0 + float(parts[5]) / 3600.0)
	else:
		return []
	if ra < 0.0 or ra >= 360.0 or absf(dec) > 90.0: return []
	return [ra, dec]

## Aim at a body, named star, radio source or coordinates. Returns false for unknown text.
func set_target_text(text: String) -> bool:
	var t := text.strip_edges()
	if t == "": return false
	var year := EarthFrame.year_of(obs.tt())
	for n: String in ["Moon", "Sun", "Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"]:
		if n.to_lower() == t.to_lower():
			_set_target({"name": n, "kind": "body"})
			return true
	for n: String in Telescopes.STARS:
		if n.to_lower() == t.to_lower():
			var at: Array = Telescopes.STARS[n]
			_set_target(_star_at(n, EarthFrame.radec_vec(deg_to_rad(float(at[0])), deg_to_rad(float(at[1]))), year))
			return true
	for n: String in Telescopes.RADIO:
		if n.to_lower() == t.to_lower():
			var s: Dictionary = Telescopes.RADIO[n]
			_set_target({"name": n, "kind": "radio", "dir": EarthFrame.radec_vec(deg_to_rad(float(s.ra)), deg_to_rad(float(s.dec))), "v": NAN})
			return true
	var rd := parse_radec(t)
	if rd.is_empty(): return false
	_set_target(_star_at(t, EarthFrame.radec_vec(deg_to_rad(float(rd[0])), deg_to_rad(float(rd[1]))), year, 5.0 * Imager.AS))
	return true

## A place's nearest catalogue star inside `tol` (rad), carried to `year`, else the bare place.
static func _star_at(label: String, d: DVec3, year: float, tol := deg_to_rad(0.1)) -> Dictionary:
	var best = null
	var best_v := 99.0
	for h: Array in SkyField.catalogue(d, tol, year):
		if float(h[1]) < best_v:
			best = h
			best_v = float(h[1])
	if best != null: return {"name": label, "kind": "star", "dir": best[0], "v": best_v}
	return {"name": label, "kind": "sky", "dir": d, "v": NAN}

## Take a sky click: `d` is the J2000 direction, `tol` the click's slack (rad).
func pick(d: DVec3, tol: float) -> void:
	var best := ""
	var best_c := cos(tol)
	for n: String in ["Moon", "Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"]:
		var b: Body = obs.stage.state.body_named(n)
		if b == null: continue
		var c := body_dir(b).dot(d)
		if c > best_c:
			best_c = c
			best = n
	if best != "":
		_set_target({"name": best, "kind": "body"}, false)
		return
	var year := EarthFrame.year_of(obs.tt())
	var hit = null
	var hit_v := 99.0
	for h: Array in SkyField.catalogue(d, tol, year):
		if float(h[1]) < hit_v:
			hit = h
			hit_v = float(h[1])
	for n: String in Telescopes.RADIO:
		var s: Dictionary = Telescopes.RADIO[n]
		if row().get("kind") == "radio" and EarthFrame.radec_vec(deg_to_rad(float(s.ra)), deg_to_rad(float(s.dec))).dot(d) > cos(tol):
			_set_target({"name": n, "kind": "radio", "dir": EarthFrame.radec_vec(deg_to_rad(float(s.ra)), deg_to_rad(float(s.dec))), "v": NAN}, false)
			return
	if hit != null:
		_set_target({"name": _name_star(hit[0]), "kind": "star", "dir": hit[0], "v": hit_v}, false)
	else:
		_set_target({"name": _radec_text(d), "kind": "sky", "dir": d, "v": NAN}, false)

static func _name_star(d: DVec3) -> String:
	for n: String in Telescopes.STARS:
		var at: Array = Telescopes.STARS[n]
		if EarthFrame.radec_vec(deg_to_rad(float(at[0])), deg_to_rad(float(at[1]))).dot(d) > cos(deg_to_rad(0.1)): return n
	return _radec_text(d)

## "05h34m +22°01′".
static func _radec_text(d: DVec3) -> String:
	var ra := fposmod(rad_to_deg(atan2(d.y, d.x)), 360.0) / 15.0
	var dec := rad_to_deg(asin(clampf(d.z, -1.0, 1.0)))
	return "%02dh%02dm %s%d°%02d′" % [int(ra), int(fposmod(ra * 60.0, 60.0)), "+" if dec >= 0.0 else "−", int(absf(dec)), int(fposmod(absf(dec) * 60.0, 60.0))]

func _set_target(t: Dictionary, move_view := true) -> void:
	target = t
	var box: LineEdit = obs.stage.hud.get_el("obsTarget")
	if box != null and not box.has_focus(): box.text = String(t.name)
	# The view follows the target, as Point at does.
	if move_view:
		if t.kind == "body":
			obs.point_at(String(t.name))
		else:
			obs.point_dir(t.dir)
	sync()

## The J2000 direction from the site to a body now.
func body_dir(b: Body) -> DVec3:
	var k: float = obs.stage.state.scene_scale / Rocketry.AU_M
	var earth: Body = obs.stage.state.body_named("Earth")
	var eye: DVec3 = earth.scene_pos.add(EarthFrame.to_scene(obs.frame.offset).scaled(k))
	return EarthFrame.from_scene(b.scene_pos.sub(eye)).normalized()

## The target's direction now, or null with no target.
func target_dir():
	if target.is_empty() or obs.frame.is_empty(): return null
	if target.kind == "body":
		var b: Body = obs.stage.state.body_named(String(target.name))
		return body_dir(b) if b != null else null
	return target.dir

# REACH

## When `d` next crosses altitude `limit` (deg) at `s` (an EarthFrame.site): hours from then,
## {state: "both"|"up"|"down", rise_h, set_h}. Fixed in right ascension, so a moving body's
## times are for its present place.
static func rise_set(s: Dictionary, d: DVec3, lat: float, limit: float) -> Dictionary:
	var t := EarthFrame.apply(s.npb, d)
	var alpha := atan2(t.y, t.x)
	var delta := asin(clampf(t.z, -1.0, 1.0))
	var cos_h := (sin(deg_to_rad(limit)) - sin(lat) * sin(delta)) / (cos(lat) * cos(delta))
	if cos_h <= -1.0: return {"state": "up"}
	if cos_h >= 1.0: return {"state": "down"}
	var h0 := acos(cos_h)
	var ha: float = fposmod(float(s.last) - alpha, TAU)
	# Sidereal hours per mean solar hour.
	var rate := TAU / 24.0 * 1.00273790935
	return {"state": "both", "rise_h": fposmod(-h0 - ha, TAU) / rate, "set_h": fposmod(h0 - ha, TAU) / rate}

## Whether the instrument may take this target: {ok, why}. Angles in degrees.
static func reachable(r: Dictionary, alt: float, sun_alt: float, sun_angle: float) -> Dictionary:
	if alt < float(r.min_alt):
		return {"ok": false, "why": "Below the %s's limit of %d°." % [r.telescope, int(r.min_alt)]}
	if r.kind == "radio":
		return {"ok": true, "why": ""}
	if sun_alt > 0.0:
		return {"ok": false, "why": "The Sun is up: the enclosure stays shut."}
	if sun_angle < SUN_LIMIT:
		return {"ok": false, "why": "Within %d° of the Sun." % int(SUN_LIMIT)}
	return {"ok": true, "why": ""}

## Seconds to slew between two pointings, each axis at its published rate, the short way round.
static func slew_seconds(r: Dictionary, az0: float, el0: float, az1: float, el1: float) -> float:
	var daz := absf(wrapf(az1 - az0, -180.0, 180.0))
	return maxf(daz / float(r.az_rate), absf(el1 - el0) / float(r.el_rate))

## Everything the panel reports about the target now, or {} with none.
func status() -> Dictionary:
	var d = target_dir()
	if d == null or row().is_empty(): return {}
	var f: Dictionary = obs.frame
	var alt := rad_to_deg(EarthFrame.altitude(f, d))
	var az := rad_to_deg(EarthFrame.azimuth(f, d))
	var sun := body_dir(obs.stage.state.body_named("Sun"))
	var sun_alt := rad_to_deg(EarthFrame.altitude(f, sun))
	var sun_angle: float = rad_to_deg(acos(clampf((d as DVec3).dot(sun), -1.0, 1.0)))
	var r := row()
	var la := deg_to_rad(float(obs.lat))
	var out := reachable(r, alt, sun_alt, sun_angle)
	out.alt = alt
	out.az = az
	out.x = SkyConditions.airmass(alt)
	out.sun_alt = sun_alt
	out.sun_angle = sun_angle
	out.rs = rise_set(f, d, la, float(r.min_alt))
	var a: Dictionary = _aim.get(key, {"az": az, "el": alt})
	out.slew = slew_seconds(r, float(a.az), float(a.el), az, alt)
	return out

# EXPOSING

## The pixel size multiple for the field setting.
func binning() -> int:
	var r := row()
	if r.is_empty(): return 1
	var w: int = W_RADIO if r.kind == "radio" else W_OPTICAL
	if field == "pixels": return 1
	if r.kind == "radio": return 2 if field == "wide" else 4
	var full := maxi(ceili(float(r.fov) / (float(r.pixel) * w)), 1)
	return maxi(full / 4, 2) if field == "wide" else full

## The bodies near `c`, with what the imager wants of each.
func _bodies(c: DVec3, r: Dictionary) -> Array:
	var out := []
	var st = obs.stage.state
	var earth: Body = st.body_named("Earth")
	var sun: Body = st.body_named("Sun")
	var w: int = W_RADIO if r.kind == "radio" else W_OPTICAL
	var field_r: float = float(r.pixel) * binning() * w * Imager.AS
	for n: String in ["Sun", "Moon", "Mercury", "Venus", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"]:
		var b: Body = st.body_named(n)
		if b == null: continue
		var d := body_dir(b)
		var dist := EarthFrame.from_scene(b.pos.sub(earth.pos)).length()
		var radius := asin(clampf(b.radius / dist, 0.0, 1.0))
		if d.dot(c) < cos(field_r + radius): continue
		if n == "Sun" and r.kind != "radio": continue
		var e := {"name": n, "dir": d, "radius": radius, "o": d.scaled(-1.0), "to_sun": EarthFrame.from_scene(sun.pos.sub(b.pos)).normalized(),
			"jy": Telescopes.body_jy(n, radius, dist, float(r.get("freq", 1.5e9)))}
		if n != "Sun":
			var alpha := rad_to_deg(acos(clampf(float((e.to_sun as DVec3).dot(e.o)), -1.0, 1.0)))
			e.v = SkyConditions.moon_v(alpha, dist) if n == "Moon" else float(Marker.apparent_magnitude(b, earth.pos, sun))
		out.append(e)
	return out

## The sky's V at the target, with today's Sun and Moon.
func sky_now(st: Dictionary) -> float:
	var f: Dictionary = obs.frame
	var d: DVec3 = target_dir()
	var moon: Body = obs.stage.state.body_named("Moon")
	var sun: Body = obs.stage.state.body_named("Sun")
	var md := body_dir(moon)
	var moon_alt := rad_to_deg(EarthFrame.altitude(f, md))
	var rho: float = rad_to_deg(acos(clampf(d.dot(md), -1.0, 1.0)))
	var alpha: float = rad_to_deg(acos(clampf(EarthFrame.from_scene(sun.pos.sub(moon.pos)).normalized().dot(md.scaled(-1.0)), -1.0, 1.0)))
	var c: Dictionary = SkyConditions.SITES.get(obs.site_key, SkyConditions.SITES.custom)
	return SkyConditions.sky_v(c, float(st.alt), float(st.sun_alt), alpha, rho, moon_alt)

## Take a frame. Returns the reason if it can't.
func expose() -> String:
	if _task >= 0: return ""
	if row().is_empty(): return "There is no instrument at this site."
	var st := status()
	if st.is_empty(): return "Choose a target first."
	if not st.ok: return String(st.why)
	var r := row()
	var c: DVec3 = target_dir()
	var c_site: Dictionary = SkyConditions.SITES.get(obs.site_key, SkyConditions.SITES.custom)
	_seed += 1
	var bodies := _bodies(c, r)
	var tv := float(target.get("v", NAN))
	# A resolved disc over the frame's centre has no star's aperture to report.
	var ext := false
	for b: Dictionary in bodies:
		if not b.has("v"): continue
		var resolved: bool = float(b.radius) / (float(r.get("pixel", 1.0)) * binning() * Imager.AS) >= 2.0
		if resolved and (b.dir as DVec3).dot(c) > cos(float(b.radius)): ext = true
		if target.kind == "body" and b.name == target.name: tv = float(b.v)
	var c_stamp := "%s UTC" % TimeScales.stamp(obs.civil())
	var req := {"row": r, "centre": c, "x": st.x, "k_v": float(c_site.k_v), "sky_v": sky_now(st), "seeing": seeing_now(), "exposure": exposure, "nd": nd,
		"bin": binning(), "w": W_RADIO if r.kind == "radio" else W_OPTICAL, "seed": _seed, "year": EarthFrame.year_of(obs.tt()), "tdb": obs.tdb(), "bodies": bodies,
		"target_v": NAN if ext else tv, "extended": ext, "target_name": String(target.name), "stamp": c_stamp, "alt": st.alt}
	_pending = {"req": req}
	_task = WorkerThreadPool.add_task(_work.bind(_pending), false, "Imager frame")
	sync()
	return ""

static func _work(job: Dictionary) -> void:
	var out := Imager.expose(job.req)
	out.image = Imager.to_image(out)
	job.out = out

## Wait out a frame in flight.
func finish() -> void:
	if _task < 0: return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_pending = {}

## Wait out a frame in flight and show it.
func finish_into_frame() -> void:
	if _task < 0: return
	WorkerThreadPool.wait_for_task_completion(_task)
	_collect()

func _collect() -> void:
	_task = -1
	var out: Dictionary = _pending.get("out", {})
	_pending = {}
	if not out.is_empty():
		frame = out
		frame_image = out.image
		frame_tex = ImageTexture.create_from_image(frame_image)
	sync()

## Keep this frame for comparing against the next.
func hold() -> void:
	if frame.is_empty(): return
	held = frame
	held_image = frame_image
	held_tex = frame_tex
	sync()

func release_hold() -> void:
	held = {}
	held_image = null
	held_tex = null
	sync()

## The command line's instrument options, once the frame exists: inst, target, exposure,
## seeing, field, nd, hold (a frame first, then release the clock on a second) and expose.
func apply_cli(o: Dictionary) -> void:
	if o.has("inst"): set_instrument(String(o.inst))
	if o.has("exposure"): exposure = float(o.exposure)
	if o.has("seeing"): seeing = float(o.seeing)
	if o.has("field"): field = String(o.field)
	if o.has("nd"): nd = float(o.nd)
	if o.has("target") and not set_target_text(String(o.target)): push_error("observatory: no such target: %s" % o.target)
	if o.get("expose", false): expose()
	sync()

# PER FRAME

func update(dt: float) -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_collect()
	_aim_step(dt)
	_acc += dt
	if _acc >= 0.2:
		_acc = 0.0
		sync_status()

## Drive the telescope on the ground toward the target, faster than life by SLEW_SPEEDUP.
func _aim_step(dt: float) -> void:
	var r := row()
	if r.is_empty() or obs.site_scene == null: return
	var a: Dictionary = _aim.get(key, {})
	var d = target_dir()
	if d == null: return
	var az := rad_to_deg(EarthFrame.azimuth(obs.frame, d))
	var alt: float = rad_to_deg(EarthFrame.altitude(obs.frame, d))
	alt = maxf(alt, float(r.min_alt))
	if a.is_empty():
		a = {"az": az, "el": alt}
		_aim[key] = a
	var daz := wrapf(az - float(a.az), -180.0, 180.0)
	var step_az := float(r.az_rate) * SLEW_SPEEDUP * dt
	var step_el := float(r.el_rate) * SLEW_SPEEDUP * dt
	a.az = fposmod(float(a.az) + clampf(daz, -step_az, step_az), 360.0)
	a.el = float(a.el) + clampf(alt - float(a.el), -step_el, step_el)
	obs.site_scene.aim(int(r.part), float(a.az), float(a.el))

# THE PANEL

## The controls and frames; the per-frame readouts are in sync_status.
func sync() -> void:
	var hud = obs.stage.hud
	var here := Telescopes.at_site(obs.site_key)
	for k: String in Telescopes.ORDER:
		hud.set_active("[data-obs-inst=%s]" % k, k == key)
	for f: String in FIELDS:
		hud.set_active("[data-obs-field=%s]" % f, f == field)
	for v: float in Telescopes.ND:
		hud.set_active("[data-obs-nd=%d]" % int(v), v == nd)
	hud.set_shown("obsNdRow", row().get("kind", "optical") != "radio")
	hud.set_button_text("obsHold", "Release" if not held.is_empty() else "Hold")
	var r := row()
	if here.is_empty() and key != "":
		key = ""
		r = {}
	hud.set_text("obsInstNote", String(r.get("note", "No instrument at this site yet: the desk needs Jodrell Bank, Mauna Kea or Paranal." if here.is_empty() else "")))
	hud.set_slider("obsExposure", U.log10(exposure), _time_text(exposure))
	var see := seeing_now()
	hud.set_slider("obsSeeing", see, "no air" if see <= 0.0 else "%.2f″%s" % [see, " median" if is_nan(seeing) else ""])
	hud.set_shown("obsSeeingRow", r.get("kind", "optical") != "radio")
	hud.set_button_text("obsExpose", "Exposing…" if _task >= 0 else ("Integrate" if r.get("kind") == "radio" else "Expose"))
	hud.show_plates(frame, frame_tex, held, held_tex)
	hud.set_text("obsFrameStats", _frame_text(frame))
	hud.set_text("obsHeldStats", _frame_text(held))
	sync_status()

func sync_status() -> void:
	var hud = obs.stage.hud
	var st := status()
	if st.is_empty():
		for id in ["obsTAlt", "obsTAz", "obsTAir", "obsTRise", "obsTSet", "obsTSlew"]: hud.set_text(id, "—")
		hud.set_text("obsReach", "Choose a target: type a name or coordinates, use Point at or click the sky.")
		return
	hud.set_text("obsTAlt", "%+.1f°" % st.alt)
	hud.set_text("obsTAz", "%.1f°" % st.az)
	hud.set_text("obsTAir", "%.2f" % st.x if st.alt > 0.0 else "—")
	var rs: Dictionary = st.rs
	var r := row()
	match rs.state:
		"up":
			hud.set_text("obsTRise", "always up")
			hud.set_text("obsTSet", "always up")
		"down":
			hud.set_text("obsTRise", "never")
			hud.set_text("obsTSet", "never")
		_:
			hud.set_text("obsTRise", _clock(float(rs.rise_h)))
			hud.set_text("obsTSet", _clock(float(rs.set_h)))
	hud.set_text("obsTSlew", _time_text(float(st.slew)))
	var note := "Rises and sets past the mount's %d°; times in UTC." % int(r.min_alt)
	if not st.ok:
		note = String(st.why)
	elif r.kind == "radio" and target.get("kind") in ["star", "sky"]:
		note = "A star is far below this receiver: expect confusion and noise, no source."
	hud.set_text("obsReach", note)
	hud.set_warn("obsReach", not st.ok)

func _clock(hours: float) -> String:
	var t := fposmod(obs.civil() + 0.5, 1.0) * 24.0 + hours
	t = fposmod(t, 24.0)
	return "%02d:%02d" % [int(t), int(fposmod(t * 60.0, 60.0))]

static func _time_text(s: float) -> String:
	if s < 1.0: return "%d ms" % roundi(s * 1000.0)
	if s < 60.0: return "%.1f s" % s if s < 10.0 else "%d s" % roundi(s)
	if s < 3600.0: return "%d m %02d s" % [int(s / 60.0), int(fposmod(s, 60.0))]
	return "%.1f h" % (s / 3600.0)

## A frame's readouts, one line each.
static func _frame_text(f: Dictionary) -> String:
	if f.is_empty(): return ""
	var lines := ["%s · %s" % [f.instrument, f.target], "%s · %s" % [_time_text(float(f.exposure)), f.stamp]]
	if f.kind == "radio":
		lines.append("Beam %.1f′ · σ %s" % [float(f.fwhm) / 60.0, _jy(float(f.sigma))])
		lines.append("5σ limit %s · confusion %s" % [_jy(float(f.limit_jy)), _jy(float(f.confusion))])
		lines.append("Source %s · SNR %s" % [_jy(float(f.centre_jy)), _num(float(f.snr))] if float(f.centre_jy) > 0.0 else "No source at the centre")
		return "\n".join(lines)
	lines.append("FWHM %.2f″ · %.3f″/px · airmass %.2f" % [f.fwhm, f.pixel, f.x])
	lines.append("The sky alone fills the wells: shorten it" if f.get("sky_full", false) else "V limit %.1f at SNR 5 · sky %.1f mag/″²" % [f.limit, f.sky_v])
	lines.append("Peak %s e⁻ · sky %s e⁻/px · %s" % [_num(float(f.peak)), _num(float(f.sky_e)), "none saturated" if int(f.saturated) == 0 else "%s px saturated" % _num_int(int(f.saturated))])
	if f.has("snr"):
		var what := "SNR %s per pixel at the centre" % _num(float(f.snr)) if f.get("extended", false) else "V %.1f: SNR %s" % [f.get("target_v", 0.0), _num(float(f.snr))]
		if f.get("target_saturated", false): what += " · saturated"
		lines.append(what)
	return "\n".join(lines)

static func _num_int(n: int) -> String:
	return "%.1fk" % (n / 1000.0) if n >= 10000 else str(n)

static func _jy(s: float) -> String:
	if s >= 1e4: return "%s Jy" % String.num_scientific(snappedf(s, s / 100.0))
	if s >= 1.0: return "%.1f Jy" % s
	if s >= 1e-3: return "%.1f mJy" % (s * 1e3)
	return "%.0f µJy" % (s * 1e6)

## Three significant figures, or thousands with k, M.
static func _num(x: float) -> String:
	if not is_finite(x): return "—"
	if absf(x) >= 1e6: return "%.1fM" % (x / 1e6)
	if absf(x) >= 1e4: return "%.0fk" % (x / 1e3)
	if absf(x) >= 100.0: return str(roundi(x))
	if absf(x) >= 10.0: return "%.1f" % x
	return "%.2f" % x
