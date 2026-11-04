class_name SkyField
extends RefCounted

# The stars an instrument sees: the catalogues to V ≈ 8, then a statistical field below
# them, seeded per patch of sky so every telescope sees the same stars on the same spot.
# The faint field is modelled, not observed. docs/physics/instruments.md.

## Sky-averaged stars per square degree brighter than V: approximate, to shape the field.
const COUNTS := [[8.0, 1.0], [10.0, 8.0], [12.0, 85.0], [13.0, 175.0], [15.0, 730.0], [18.0, 7700.0], [20.0, 31000.0], [22.0, 70000.0], [25.0, 130000.0]]
const PATCH := 0.25          # degrees
const STOP := 25.0

static var _unit := PackedFloat32Array()
static var _v := PackedFloat32Array()
static var _rows: PackedFloat64Array = PackedFloat64Array()

static func _load() -> void:
	if not _v.is_empty(): return
	var rows := []
	for path in [BrightStars.DATA, BrightStars.DATA_FAINT]:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null: continue
		var ep: float = BrightStars.EPOCHS[path]
		while f.get_position() + BrightStars.RECORD <= f.get_length():
			var ra := deg_to_rad(f.get_float())
			var dec := deg_to_rad(f.get_float())
			var v := f.get_float()
			f.get_float()
			var pa := f.get_float()
			var pd := f.get_float()
			rows.append([ra, dec, v, pa, pd, ep])
	_unit.resize(rows.size() * 3)
	_v.resize(rows.size())
	_rows.resize(rows.size() * 5)
	for i in rows.size():
		var r: Array = rows[i]
		var cd := cos(r[1])
		_unit[i * 3] = cd * cos(r[0]); _unit[i * 3 + 1] = cd * sin(r[0]); _unit[i * 3 + 2] = sin(r[1])
		_v[i] = r[2]
		_rows[i * 5] = r[0]; _rows[i * 5 + 1] = r[1]; _rows[i * 5 + 2] = r[3]; _rows[i * 5 + 3] = r[4]; _rows[i * 5 + 4] = r[5]

## Catalogue stars within `radius` (rad) of unit vector `c` at Julian year `year`:
## [[DVec3, V]], carried by their proper motion.
static func catalogue(c: DVec3, radius: float, year: float) -> Array:
	_load()
	var out := []
	# Single precision, so a little slack on a tiny radius.
	var cm := cos(radius + 2e-4)
	for i in _v.size():
		if _unit[i * 3] * c.x + _unit[i * 3 + 1] * c.y + _unit[i * 3 + 2] * c.z < cm: continue
		var d := EarthFrame.proper_motion(_rows[i * 5], _rows[i * 5 + 1], _rows[i * 5 + 2], _rows[i * 5 + 3], _rows[i * 5 + 4], year)
		if d.dot(c) >= cos(radius): out.append([d, float(_v[i])])
	return out

## Galactic latitude (rad) of J2000 unit vector `d`, from the north galactic pole.
static func galactic_lat(d: DVec3) -> float:
	var ngp := EarthFrame.radec_vec(deg_to_rad(192.85948), deg_to_rad(27.12825))
	return asin(clampf(d.dot(ngp), -1.0, 1.0))

## Stars per square degree brighter than V at latitude `b`: the sky average, then a disc
## that is about ten times denser at the plane than at the poles (average ≈ 1).
static func density(v: float, b: float) -> float:
	var g := _lat_gain(b)
	var t: Array = COUNTS
	if v <= float(t[0][0]): return float(t[0][1]) * pow(10.0, 0.44 * (v - float(t[0][0]))) * g
	for i in t.size() - 1:
		if v < float(t[i + 1][0]):
			var f := (v - float(t[i][0])) / (float(t[i + 1][0]) - float(t[i][0]))
			return exp(lerpf(log(float(t[i][1])), log(float(t[i + 1][1])), f)) * g
	return float(t[-1][1]) * g

static func _lat_gain(b: float) -> float:
	return 3.0 * exp(-absf(rad_to_deg(b)) / 12.0) + 0.35

## Modelled stars between V ≈ 8 and `v_max` within `radius` (rad) of `c`: [[DVec3, V]],
## brightest kept if more than `cap`. Patches are fixed to the sky, so they repeat.
static func faint(c: DVec3, radius: float, v_max: float, cap := 30000) -> Array:
	var out := []
	var vm := minf(v_max, STOP)
	if vm <= 8.0: return out
	var dec := asin(clampf(c.z, -1.0, 1.0))
	var ra := fposmod(atan2(c.y, c.x), TAU)
	var cos_r := cos(radius)
	var step := deg_to_rad(PATCH)
	var row0 := int(floorf((dec - radius) / step))
	var row1 := int(floorf((dec + radius) / step))
	for row in range(row0, row1 + 1):
		var d0 := row * step
		var d1 := d0 + step
		if d0 >= PI * 0.5 or d1 <= -PI * 0.5: continue
		var cos_mid := maxf(cos(clampf(d0 + step * 0.5, -1.5, 1.5)), 0.02)
		var cells := maxi(int(TAU * cos_mid / step), 1)
		var dra := TAU / cells
		var span := radius / maxf(cos(clampf(absf(dec) + radius, 0.0, 1.55)), 0.02)
		var col0 := int(floorf((ra - span) / dra))
		var col1 := int(floorf((ra + span) / dra))
		if col1 - col0 >= cells: col1 = col0 + cells - 1
		for col in range(col0, col1 + 1):
			var cm := posmod(col, cells)
			var rng := RandomNumberGenerator.new()
			rng.seed = hash([row, cm, 7919])
			var a0 := cm * dra
			var centre := EarthFrame.radec_vec(a0 + dra * 0.5, d0 + step * 0.5)
			var area: float = rad_to_deg(rad_to_deg(dra * (sin(d1) - sin(d0))))
			var b := galactic_lat(centre)
			# Draw to the faint limit in fixed order, so a longer exposure only adds stars.
			var n := int(density(STOP, b) * area)
			var drawn := density(vm, b) * area
			for k in mini(n, 1 << 18):
				if float(k) > drawn: break
				var s := EarthFrame.radec_vec(a0 + rng.randf() * dra, asin(lerpf(sin(d0), sin(d1), rng.randf())))
				# Invert the cumulative count, each star at its rank.
				var v := _rank_mag((k + rng.randf()) / area, b)
				if v < 8.0 or v > vm or s.dot(c) < cos_r: continue
				out.append([s, v])
	if out.size() > cap:
		out.sort_custom(func(p, q): return p[1] < q[1])
		out.resize(cap)
	return out

## The magnitude at which `per_deg2` stars per square degree are brighter, at latitude `b`.
static func _rank_mag(per_deg2: float, b: float) -> float:
	var n := per_deg2 / _lat_gain(b)
	var t: Array = COUNTS
	if n <= float(t[0][1]): return 8.0
	for i in t.size() - 1:
		if n < float(t[i + 1][1]):
			var f := log(n / float(t[i][1])) / log(float(t[i + 1][1]) / float(t[i][1]))
			return lerpf(float(t[i][0]), float(t[i + 1][0]), f)
	return STOP
