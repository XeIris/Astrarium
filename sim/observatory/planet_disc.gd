class_name PlanetDisc
extends RefCounted

# A solar-system body's lit disc at the plate scale, in the sky's own orientation. Its total
# light is fixed by its V magnitude; maps and phase only decide where that light falls.
# Rotation: IAU WGCCRE (Archinal et al. 2018), with Rocketry.POLES. Runs off the main thread.

## [W at J2000 (°), rate (°/day)]
const ROTATION := {
	"Mercury": [329.5988, 6.1385108], "Venus": [160.20, -1.4813688], "Moon": [38.3213, 13.17635815],
	"Mars": [176.049863, 350.891982443297], "Jupiter": [284.95, 870.5360000], "Saturn": [38.90, 810.7939024],
	"Uranus": [203.81, -501.1600928], "Neptune": [249.978, 541.1397757], "Pluto": [302.695, 56.3625225],
}
const MAPS := {"Moon": "moon-lro.jpg", "Mars": "mars-viking.jpg", "Jupiter": "jupiter-cassini.jpg"}
static var _maps := {}
static var _lut := PackedFloat32Array()

## A map as linear luminance rows: {"d": PackedFloat32Array, "w", "h"}, or {} without one.
static func _map(body_name: String) -> Dictionary:
	if _maps.has(body_name): return _maps[body_name]
	var out := {}
	if MAPS.has(body_name):
		var img := Image.new()
		var bytes := FileAccess.get_file_as_bytes(PlanetMaps.DIR + str(MAPS[body_name]))
		var ok := not bytes.is_empty() and img.load_jpg_from_buffer(bytes) == OK
		# An exported build has only the imported texture.
		if not ok and ResourceLoader.exists(PlanetMaps.DIR + str(MAPS[body_name])):
			var tex := load(PlanetMaps.DIR + str(MAPS[body_name])) as Texture2D
			if tex != null:
				img = tex.get_image()
				ok = img != null
		if ok:
			if img.is_compressed(): img.decompress()
			img.convert(Image.FORMAT_L8)
			if _lut.is_empty():
				_lut.resize(256)
				for i in 256: _lut[i] = pow(i / 255.0, 2.2)
			var raw := img.get_data()
			var d := PackedFloat32Array()
			d.resize(raw.size())
			for i in raw.size(): d[i] = _lut[raw[i]]
			out = {"d": d, "w": img.get_width(), "h": img.get_height()}
	_maps[body_name] = out
	return out

## The IAU pole and prime meridian (deg) at `tdb`: fixed for most bodies, and for the Moon
## with the largest periodic terms, the 18.6-year nodal circle worth about 4°.
static func orientation(body_name: String, tdb: float) -> Array:
	var d := tdb - EarthFrame.J2000
	var pole: Array = Rocketry.POLES.get(body_name, [0.0, 90.0])
	var r: Array = ROTATION.get(body_name, [0.0, 0.0])
	var w: float = float(r[0]) + float(r[1]) * d
	if body_name == "Moon":
		var t := d / 36525.0
		var e1 := deg_to_rad(125.045 - 0.0529921 * d)
		var e2 := deg_to_rad(250.089 - 0.1059842 * d)
		return [269.9949 + 0.0031 * t - 3.8787 * sin(e1) - 0.1204 * sin(e2),
			66.5392 + 0.0130 * t + 1.5419 * cos(e1) + 0.0239 * cos(e2),
			w + 3.5610 * sin(e1) + 0.1208 * sin(e2)]
	return [float(pole[0]), float(pole[1]), w]

## Body-fixed axes as GCRS vectors at TDB Julian date `tdb`: [x (0° longitude), y, z (north)].
static func axes(body_name: String, tdb: float) -> Array:
	var o := orientation(body_name, tdb)
	var a0 := deg_to_rad(float(o[0]))
	var w := deg_to_rad(float(o[2]))
	var z := EarthFrame.radec_vec(a0, deg_to_rad(float(o[1])))
	# The IAU node lies at α0 + 90°; W runs east along the equator from it.
	var node := DVec3.new(-sin(a0), cos(a0), 0.0)
	var x := node.scaled(cos(w)).add(z.cross(node).scaled(sin(w)))
	return [x, z.cross(x), z]

## The orrery-axes basis that puts a RockyVisual.sphere_geometry mesh's map on `axes`: the mesh
## has 0° longitude on +X, north on +Y and 90° E on −Z.
static func mesh_basis(body_name: String, tdb: float) -> Basis:
	var ax := axes(body_name, tdb)
	return Basis(EarthFrame.to_scene(ax[0]).to_v3(), EarthFrame.to_scene(ax[2]).to_v3(), EarthFrame.to_scene(ax[1]).scaled(-1.0).to_v3())

## A surface point's GCRS unit vector from planetocentric latitude and east longitude (rad).
static func surface(ax: Array, lat: float, lon: float) -> DVec3:
	var c := cos(lat)
	return (ax[0] as DVec3).scaled(c * cos(lon)).add((ax[1] as DVec3).scaled(c * sin(lon))).add((ax[2] as DVec3).scaled(sin(lat)))

## Bilinear map albedo; 1 with no map.
static func albedo(map: Dictionary, lat: float, lon: float) -> float:
	if map.is_empty(): return 1.0
	var w: int = map.w
	var h: int = map.h
	var d: PackedFloat32Array = map.d
	var fu := fposmod(lon / TAU + 0.5, 1.0) * w - 0.5
	var fv := clampf((0.5 - lat / PI) * h - 0.5, 0.0, h - 1.001)
	var i := floori(fu)
	var j := int(fv)
	var tu := fu - i
	var tv := fv - j
	var i0 := posmod(i, w)
	var i1 := (i0 + 1) % w
	return maxf(lerpf(lerpf(d[j * w + i0], d[j * w + i1], tu), lerpf(d[(j + 1) * w + i0], d[(j + 1) * w + i1], tu), tv), 0.01)

static func _bands(body_name: String, lat: float) -> float:
	match body_name:
		"Saturn": return 0.85 + 0.15 * cos(lat * 14.0) * cos(lat * 3.0)
		"Uranus", "Neptune": return 0.95 + 0.05 * cos(lat * 6.0)
	return 1.0

## How a surface element sends sunlight to the observer: Lommel–Seeliger for the airless
## regolith of the Moon and Mercury, Minnaert (k = 0.75) for the others.
static func _law(airless: bool, mu0: float, mu: float) -> float:
	if mu0 <= 0.0 or mu <= 0.0: return 0.0
	return mu0 / (mu0 + mu) if airless else pow(mu0, 0.75) * pow(mu, -0.25)

## Paint the body into `e` (w × w, electrons), centred at (cx, cy) px of `p` rad per pixel,
## `electrons` in all. `o` is GCRS from the body toward the observer, `to_sun` from the body
## to the Sun, `east` and `north` the frame's sky axes.
static func paint(e: PackedFloat32Array, w: int, cx: float, cy: float, p: float, body_name: String, radius: float,
		electrons: float, o: DVec3, to_sun: DVec3, east: DVec3, north: DVec3, tdb: float) -> void:
	var ax := axes(body_name, tdb)
	var map := _map(body_name)
	var airless: bool = body_name in ["Moon", "Mercury"]
	var ring: bool = body_name == "Saturn"
	# Each body axis and the Sun in the frame (east, north, toward the observer).
	var xa: DVec3 = ax[0]; var ya: DVec3 = ax[1]; var za: DVec3 = ax[2]
	var xe := xa.dot(east); var xn := xa.dot(north); var xo := xa.dot(o)
	var ye := ya.dot(east); var yn := ya.dot(north); var yo := ya.dot(o)
	var ze := za.dot(east); var zn := za.dot(north); var zo := za.dot(o)
	var se := to_sun.dot(east); var sn := to_sun.dot(north); var so := to_sun.dot(o)
	# The whole disc's weight, coarsely, fixes the light per element.
	var m := 96
	var total := 0.0
	for j in m:
		var ny := -1.0 + (j + 0.5) * 2.0 / m
		for i in m:
			var nx := -1.0 + (i + 0.5) * 2.0 / m
			var q := nx * nx + ny * ny
			if q >= 1.0: continue
			var nz := sqrt(1.0 - q)
			var lat := asin(clampf(nx * ze + ny * zn + nz * zo, -1.0, 1.0))
			var lon := atan2(nx * ye + ny * yn + nz * yo, nx * xe + ny * xn + nz * xo)
			total += _law(airless, nx * se + ny * sn + nz * so, nz) * albedo(map, lat, lon) * _bands(body_name, lat)
	if total <= 0.0: return
	var per_px := electrons / total * pow((p / radius) / (2.0 / m), 2.0)
	var xr := radius / p
	var reach := xr * (2.3 if ring else 1.02)
	var j0 := clampi(int(cy - reach), 0, w)
	var j1 := clampi(int(cy + reach) + 1, 0, w)
	var i0 := clampi(int(cx - reach), 0, w)
	var i1 := clampi(int(cx + reach) + 1, 0, w)
	for j in range(j0, j1):
		var ny := (cy - (j + 0.5)) / xr
		for i in range(i0, i1):
			# East is to the left in a north-up sky.
			var nx := (cx - (i + 0.5)) / xr
			var q := nx * nx + ny * ny
			var v := 0.0
			var front := -INF
			if q < 1.0:
				var nz := sqrt(1.0 - q)
				front = nz
				var lat := asin(clampf(nx * ze + ny * zn + nz * zo, -1.0, 1.0))
				var lon := atan2(nx * ye + ny * yn + nz * yo, nx * xe + ny * xn + nz * xo)
				v = _law(airless, nx * se + ny * sn + nz * so, nz) * albedo(map, lat, lon) * _bands(body_name, lat) * per_px
			if ring and absf(zo) > 1e-3:
				# The ring plane along this line of sight, unless the globe is in front.
				var z := -(nx * ze + ny * zn) / zo
				var rr := sqrt(nx * nx + ny * ny + z * z)
				if rr > 1.235 and rr < 2.27 and not (rr > 1.95 and rr < 2.03) and z > front:
					# Relative C, B and A ring brightness, by eye from Cassini images.
					v = (0.15 if rr < 1.525 else (0.9 if rr < 1.95 else 0.6)) * per_px
			if v > 0.0: e[j * w + i] += v
