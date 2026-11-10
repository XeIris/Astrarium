class_name PlanetPin
extends RefCounted

# A random spot on a world and what is there. The draw is uniform on the sphere and reproducible
# from the world's seed, the run's seed= and the pin's number; what it lands on is read from the
# crust and climate the planet is drawn with, so the pin says what you can see. It does not hunt
# for land: a pin in the sea says so. docs/physics/surface.md#the-pin.

## Radians. `n` is its number in the sequence, from 1.
var lat := 0.0
var lon := 0.0
var n := 1
## Unit, in the surface mesh's frame.
var p := Vector3.UP
## {kind, biome, height_m, depth_m, temp_k, text}.
var ground := {}

## The pin numbered `n` on this world, read against what its visual draws now.
static func drop(b: Body, n: int, run_seed: int) -> PlanetPin:
	var pin := PlanetPin.new()
	pin.n = n
	var at := draw(str(U.nz(b.spec.get("seed"), b.name)), run_seed, n)
	pin.lat = at.x
	pin.lon = at.y
	pin.p = direction(pin.lat, pin.lon)
	pin.ground = read_ground(b, pin.p, pin.lat, pin.lon)
	return pin

## Pin `n`'s latitude and longitude, rad. Equal areas: uniform in sin(lat), uniform in longitude.
static func draw(key: String, run_seed: int, n: int) -> Vector2:
	return Vector2(asin(2.0 * ClimateInputs._uniform(key, run_seed, "pin%d.lat" % n) - 1.0),
		TAU * ClimateInputs._uniform(key, run_seed, "pin%d.lon" % n) - PI)

## A latitude and longitude as a unit vector in the surface mesh's frame; RockyVisual's sphere has
## 0° longitude at u = ½ and north on +Y.
static func direction(lat_r: float, lon_r: float) -> Vector3:
	var phi := lon_r + PI
	return Vector3(-cos(phi) * cos(lat_r), sin(lat_r), sin(phi) * cos(lat_r))

static func _viz(b: Body):
	return b.viz.inner if b.viz is Bodies.AccretionWrap else b.viz

## What the planet draws at unit `p`, once its look has caught up with its climate.
static func read_ground(b: Body, p: Vector3, lat_r: float, lon_r: float) -> Dictionary:
	var viz = _viz(b)
	if viz == null or not ("surf_mat" in viz) or viz.surf_mat == null:
		return {"kind": "unknown", "biome": "", "height_m": 0.0, "depth_m": 0.0, "temp_k": 0.0, "text": "No surface is drawn here."}
	var r := PlanetRelief.of_body(b)
	var hr := r.height(p)
	var h := hr.x
	var sea := h < r.sea_km
	# A map's own coast decides; the crust only says how high. A mapped world shows no relief, so
	# this height is the procedural crust's, not a measurement.
	if r.map_kind == 1:
		var on_land := land_at(b.name, lat_r, lon_r)
		sea = not on_land and r.sea_km > -2.0
		h = absf(h) * (1.0 if on_land else -1.0)
	elif r.map_kind == 2:
		sea = false
		h = absf(h)
	var sin_lat := clampf(p.y, -1.0, 1.0)
	var t := r.temperature(sin_lat, r.altitude(h, sea))
	var pr := r.precipitation(p, t, h)
	var frost := _frost(r, p, sin_lat, t, pr, sea)
	var biota := r.biota
	var out := {"height_m": (h - r.sea_km if sea or r.sea_km > -30.0 else h) * 1000.0,
		"depth_m": (r.sea_km - h) * 1000.0 if sea else 0.0, "temp_k": t, "rug": hr.y, "rain": pr, "frost": frost}
	var kind := "land"
	var biome := ""
	if sea and frost >= 0.5: kind = "sea ice"
	elif sea: kind = "sea"
	elif frost >= 0.5: kind = "ice sheet"
	else: biome = _biome(t, pr, hr.y, biota, r)
	out.kind = kind
	out.biome = biome
	out.text = describe(out, b)
	if r.map_kind > 0: out.text += " The map decides what is here; the height is modelled, not measured."
	return out

# rocky_surface.gdshader's frost, for the sum it draws.
static func _frost(r: PlanetRelief, p: Vector3, sin_lat: float, t: float, pr: float, sea: bool) -> float:
	var f := 0.0
	if r.map_kind == 0:
		var perm := PlanetRelief.sstep(r.frost_k - 5.0, r.frost_k - 17.0, t)
		var snow := PlanetRelief.sstep(r.frost_k + 4.0, r.frost_k - 5.0, t) * PlanetRelief.sstep(0.03, 0.28, pr)
		var sea_ice := PlanetRelief.sstep(r.frost_k + 0.5, r.frost_k - 4.0, t) if sea else 0.0
		f = clampf(maxf(maxf(perm, snow), sea_ice), 0.0, 1.0)
	elif r.map_kind == 1:
		var cold := 1.0 - PlanetRelief.sstep(245.0, 280.0, r.mean_k)
		f = cold * PlanetRelief.sstep(0.72 - 0.56 * cold, 0.92 - 0.35 * cold, absf(sin_lat))
	if r.ice > (0.15 if r.map_kind > 0 else 0.001):
		var cap_edge := 1.0 - r.ice * 1.05
		var jitter := (PlanetRelief.fbm(p * 3.0 + Vector3(11.0, 11.0, 11.0), 3) - 0.5) * 0.16
		f = maxf(f, PlanetRelief.sstep(cap_edge - 0.10, cap_edge + 0.06, absf(sin_lat) + jitter) * PlanetRelief.sstep(0.02, 0.18, r.ice))
	return f

# The Whittaker diagram's edges, as biome() blends them.
static func _biome(t: float, pr: float, rug: float, biota: float, r: PlanetRelief) -> String:
	if r.map_kind == 2: return "bare ground"
	if biota < 0.5: return "bare rock" if rug > 0.45 else "bare ground"
	if rug > 0.7: return "bare rock"
	var warm := clampf((t - 258.0) / 48.0, 0.0, 1.0)
	if warm < 0.09: return "tundra"
	if pr < 0.15: return "desert"
	if pr < 0.33: return "grassland"
	if pr > 0.62 and warm > 0.67: return "jungle"
	return "forest"

static func describe(g: Dictionary, b: Body) -> String:
	var c := "%s °C" % U.fixed(float(g.temp_k) - 273.15, 0)
	match g.kind:
		"sea": return "Open sea, %s deep, %s at the surface." % [_distance(float(g.depth_m)), c]
		"sea ice": return "Sea ice over %s of water, %s." % [_distance(float(g.depth_m)), c]
		"ice sheet": return "An ice sheet, %s, %s." % [_level(float(g.height_m), b), c]
		_:
			var what: String = g.biome
			return "%s, %s, %s." % [what.capitalize(), _level(float(g.height_m), b), c]

# Height against the sea, or a dry world's datum, with its side.
static func _level(m: float, b: Body) -> String:
	var wet: bool = b.climate == null or b.climate.wet
	if m >= 0.0: return "%s up" % _distance(m) if wet else "%s above the datum" % _distance(m)
	return "%s below %s" % [_distance(m), "sea level" if wet else "the datum"]

static func _distance(m: float) -> String:
	var a := absf(m)
	return "%s km" % U.prec(a / 1000.0, 2) if a >= 1000.0 else "%d m" % int(round(a))

# The map's land mask, read when a pin needs it; held only while a showcase is on.
static var _mask := {}

static func land_at(body_name: String, lat_r: float, lon_r: float) -> bool:
	if not _mask.has(body_name):
		var source: Dictionary = PlanetMaps.SOURCES.get(body_name, {})
		var img: Image = null
		if source.has("mask"):
			var tex := load(PlanetMaps.DIR + str(source.mask)) as Texture2D
			if tex != null:
				img = tex.get_image()
				if img != null and img.is_compressed(): img.decompress()
		_mask[body_name] = img
	var image: Image = _mask[body_name]
	if image == null: return true
	var u := fposmod((lon_r + PI) / TAU, 1.0)
	var v := clampf((PI * 0.5 - lat_r) / PI, 0.0, 1.0)
	var x := mini(int(u * image.get_width()), image.get_width() - 1)
	var y := mini(int(v * image.get_height()), image.get_height() - 1)
	return image.get_pixel(x, y).r >= 0.5

static func release_maps() -> void:
	_mask.clear()
