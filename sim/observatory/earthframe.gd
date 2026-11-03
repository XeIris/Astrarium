class_name EarthFrame
extends RefCounted

# Earth's orientation on a date, for a ground observer: ΔT, IAU 2006 precession,
# IAU 2000B nutation and Greenwich apparent sidereal time, ending in a site's zenith,
# north and east in the GCRS (≈ J2000 equatorial) frame the orrery and the star
# catalogues share. Polar motion (≲ 0.3″) is ignored. Derivation and error budget:
# docs/physics/observatory.md.

const J2000 := 2451545.0
const DAY_S := 86400.0
const AS2R := PI / 648000.0
const TURNAS := 1296000.0
# The supported date range (issue 23): the years 1926 to 2126, both whole.
const RANGE := [1926.0, 2127.0]

## ΔT = TT − UT1 (s) at decimal year `y`: the measured table inside it, else the
## EclipseWise polynomials shifted to meet the table's nearest end.
static func delta_t(y: float) -> float:
	var t: Array = DeltaT.TABLE
	var first: float = t[0][0]
	var last: float = t[-1][0]
	# The polynomials' own pieces need not meet (1920: 0.013 s), so the offset is
	# taken on the outer side of each seam.
	if y >= last: return float(t[-1][1]) + _poly(y) - _poly(last + 1e-9)
	if y <= first: return float(t[0][1]) + _poly(y) - _poly(first - 1e-9)
	var lo := 0
	var hi := t.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if float(t[mid][0]) <= y: lo = mid
		else: hi = mid
	var f := (y - float(t[lo][0])) / (float(t[hi][0]) - float(t[lo][0]))
	return lerpf(float(t[lo][1]), float(t[hi][1]), f)

## "measured", "extrapolated" (after the table) or "outside" (beyond RANGE).
static func era(y: float) -> String:
	if y < RANGE[0] or y >= RANGE[1]: return "outside"
	if y > float(DeltaT.TABLE[-1][0]): return "extrapolated"
	return "measured"

## 1σ uncertainty of ΔT (s): the measured table's own inside it; after it, Huber's
## random walk from its last row; before it, NASA's (Espenak & Meeus) values, which
## are Huber's walk back from −500.
static func delta_t_sigma(y: float) -> float:
	var t: Array = DeltaT.TABLE
	if y >= float(t[-1][0]): return maxf(float(t[-1][2]), huber_sigma(y - float(t[-1][0])))
	if y < -500.0: return maxf(431.0, huber_sigma(-500.0 - y))
	if y < float(t[0][0]):
		var pts := [[-500.0, 431.0], [0.0, 265.0], [500.0, 139.0], [1000.0, 54.0], [1200.0, 31.0], [float(t[0][0]), float(t[0][2])]]
		for i in pts.size() - 1:
			if y < float(pts[i + 1][0]):
				var f := (y - float(pts[i][0])) / (float(pts[i + 1][0]) - float(pts[i][0]))
				return exp(lerpf(log(float(pts[i][1])), log(float(pts[i + 1][1])), f))
	var i := t.bsearch_custom(y, func(row, v): return float(row[0]) < v)
	return float(t[clampi(i, 0, t.size() - 1)][2])

## Huber (2000), as NASA's uncertainty table uses it: a random walk in the length of
## day, Q = 0.058 ms²/yr over a 2500-year calibration, `n` years from the last measurement.
static func huber_sigma(n: float) -> float:
	return 365.25 * n * sqrt(n * 0.058 / 3.0 * (1.0 + n / 2500.0)) / 1000.0

## Espenak & Meeus (2006), with the 2005–3000 terms of the 2014 EclipseWise update.
static func _poly(y: float) -> float:
	if y < -500.0 or y >= 3000.0:
		var u := (y - 1820.0) / 100.0
		return -20.0 + 32.0 * u * u
	if y < 500.0:
		var u := y / 100.0
		return 10583.6 + u * (-1014.41 + u * (33.78311 + u * (-5.952053 + u * (-0.1798452 + u * (0.022174192 + u * 0.0090316521)))))
	if y < 1600.0:
		var u := (y - 1000.0) / 100.0
		return 1574.2 + u * (-556.01 + u * (71.23472 + u * (0.319781 + u * (-0.8503463 + u * (-0.005050998 + u * 0.0083572073)))))
	if y < 1700.0:
		var t := y - 1600.0
		return 120.0 + t * (-0.9808 + t * (-0.01532 + t / 7129.0))
	if y < 1800.0:
		var t := y - 1700.0
		return 8.83 + t * (0.1603 + t * (-0.0059285 + t * (0.00013336 - t / 1174000.0)))
	if y < 1860.0:
		var t := y - 1800.0
		return 13.72 + t * (-0.332447 + t * (0.0068612 + t * (0.0041116 + t * (-0.00037436 + t * (0.0000121272 + t * (-0.0000001699 + t * 0.000000000875))))))
	if y < 1900.0:
		var t := y - 1860.0
		return 7.62 + t * (0.5737 + t * (-0.251754 + t * (0.01680668 + t * (-0.0004473624 + t / 233174.0))))
	if y < 1920.0:
		var t := y - 1900.0
		return -2.79 + t * (1.494119 + t * (-0.0598939 + t * (0.0061966 - t * 0.000197)))
	if y < 1941.0:
		var t := y - 1920.0
		return 21.20 + t * (0.84493 + t * (-0.076100 + t * 0.0020936))
	if y < 1961.0:
		var t := y - 1950.0
		return 29.07 + t * (0.407 + t * (-1.0 / 233.0 + t / 2547.0))
	if y < 1986.0:
		var t := y - 1975.0
		return 45.45 + t * (1.067 + t * (-1.0 / 260.0 - t / 718.0))
	if y < 2005.0:
		var t := y - 2000.0
		return 63.86 + t * (0.3345 + t * (-0.060374 + t * (0.0017275 + t * (0.000651814 + t * 0.00002373599))))
	if y < 2015.0:
		return 64.69 + 0.2930 * (y - 2005.0)
	var t := y - 2015.0
	return 67.62 + t * (0.3645 + t * 0.0039755)

# TIME SCALES

static func year_of(jd: float) -> float:
	return 2000.0 + (jd - J2000) / 365.25

static func tt_of_tdb(tdb: float) -> float:
	return tdb - TimeScales.tdb_minus_tt(tdb) / DAY_S

static func tdb_of_tt(tt: float) -> float:
	return tt + TimeScales.tdb_minus_tt(tt) / DAY_S

static func ut1_of_tt(tt: float) -> float:
	return tt - delta_t(year_of(tt)) / DAY_S

## Whether a civil date at `jd` is UTC (from 1972, the leap-second era) or UT1.
static func civil_is_utc(jd: float) -> bool:
	return jd >= float(TimeScales.LEAPS[0][0])

## TT for a civil Julian date: UTC from 1972 (through the leap-second table, whose
## last offset holds after it), UT1 before.
static func tt_of_civil(jd: float) -> float:
	if civil_is_utc(jd): return jd + (TimeScales.tai_minus_utc(jd) + TimeScales.TT_TAI) / DAY_S
	# UT1 → TT needs ΔT at TT; ΔT changes by well under a second per day.
	return jd + delta_t(year_of(jd)) / DAY_S

## The civil Julian date for TT `tt` (UTC or UT1, as civil_is_utc decides).
static func civil_of_tt(tt: float) -> float:
	var ut1 := ut1_of_tt(tt)
	if not civil_is_utc(ut1): return ut1
	var tai := tt - TimeScales.TT_TAI / DAY_S
	var d := TimeScales.tai_minus_utc(tai - 37.0 / DAY_S)
	return tai - TimeScales.tai_minus_utc(tai - d / DAY_S) / DAY_S

# PRECESSION AND NUTATION. Matrices are 9 doubles, row-major.

static func _rx(a: float) -> PackedFloat64Array:
	var c := cos(a); var s := sin(a)
	return PackedFloat64Array([1, 0, 0, 0, c, s, 0, -s, c])

static func _rz(a: float) -> PackedFloat64Array:
	var c := cos(a); var s := sin(a)
	return PackedFloat64Array([c, s, 0, -s, c, 0, 0, 0, 1])

static func _mul(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var r := PackedFloat64Array(); r.resize(9)
	for i in 3:
		for j in 3:
			r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
	return r

static func apply(m: PackedFloat64Array, v: DVec3) -> DVec3:
	return DVec3.new(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z,
		m[6] * v.x + m[7] * v.y + m[8] * v.z)

static func apply_t(m: PackedFloat64Array, v: DVec3) -> DVec3:
	return DVec3.new(m[0] * v.x + m[3] * v.y + m[6] * v.z, m[1] * v.x + m[4] * v.y + m[7] * v.z,
		m[2] * v.x + m[5] * v.y + m[8] * v.z)

## Mean obliquity of the ecliptic, IAU 2006 (rad); `t` TT centuries from J2000.
static func obliquity(t: float) -> float:
	return (84381.406 + t * (-46.836769 + t * (-0.0001831 + t * (0.00200340 + t * (-0.000000576 - t * 0.0000000434))))) * AS2R

## IAU 2000B nutation [Δψ, Δε] (rad); `t` TT centuries from J2000.
static func nutation(t: float) -> PackedFloat64Array:
	# Delaunay arguments, Simon et al. (1994), as the 2000B model truncates them.
	var el := fmod(485868.249036 + 1717915923.2178 * t, TURNAS) * AS2R
	var elp := fmod(1287104.79305 + 129596581.0481 * t, TURNAS) * AS2R
	var f := fmod(335779.526232 + 1739527262.8478 * t, TURNAS) * AS2R
	var d := fmod(1072260.70369 + 1602961601.2090 * t, TURNAS) * AS2R
	var om := fmod(450160.398036 - 6962890.5431 * t, TURNAS) * AS2R
	var dp := 0.0
	var de := 0.0
	var terms: Array = Nutation2000B.TERMS
	for i in range(terms.size() - 1, -1, -1):
		var x: Array = terms[i]
		var arg := fmod(float(x[0]) * el + float(x[1]) * elp + float(x[2]) * f + float(x[3]) * d + float(x[4]) * om, TAU)
		var sa := sin(arg); var ca := cos(arg)
		dp += (float(x[5]) + float(x[6]) * t) * sa + float(x[7]) * ca
		de += (float(x[8]) + float(x[9]) * t) * ca + float(x[10]) * sa
	# 0.1 µas units, plus the fixed offsets standing in for the planetary terms.
	var u := AS2R / 1e7
	return PackedFloat64Array([dp * u + Nutation2000B.DPPLAN, de * u + Nutation2000B.DEPLAN])

## GCRS → true equator and equinox of date: the IAU 2006 Fukushima–Williams angles
## (frame bias included) with nutation added to ψ and ε.
static func npb(t: float, nut: PackedFloat64Array) -> PackedFloat64Array:
	var fw := fw_angles(t)
	return _mul(_rx(-(obliquity(t) + nut[1])), _mul(_rz(-(fw[2] + nut[0])), _mul(_rx(fw[1]), _rz(fw[0]))))

## The IAU 2006 Fukushima–Williams precession angles [γ̄, φ̄, ψ̄] (rad).
static func fw_angles(t: float) -> PackedFloat64Array:
	return PackedFloat64Array([
		(-0.052928 + t * (10.556378 + t * (0.4932044 + t * (-0.00031238 + t * (-0.000002788 + t * 0.0000000260))))) * AS2R,
		(84381.412819 + t * (-46.811016 + t * (0.0511268 + t * (0.00053289 + t * (-0.000000440 - t * 0.0000000176))))) * AS2R,
		(-0.041775 + t * (5038.481484 + t * (1.5584175 + t * (-0.00018522 + t * (-0.000026452 - t * 0.0000000148))))) * AS2R])

## Earth rotation angle (rad) at UT1 Julian date `ut1`.
static func era_angle(ut1: float) -> float:
	var du := ut1 - J2000
	return fposmod(TAU * (fposmod(du, 1.0) + 0.7790572732640 + 0.00273781191135448 * du), TAU)

## Greenwich apparent sidereal time (rad): GMST (IAU 2006) plus the equation of the
## equinoxes, Δψ cos ε_A with its two largest complementary terms.
static func gast(ut1: float, t: float, nut: PackedFloat64Array) -> float:
	var gmst := era_angle(ut1) + (0.014506 + t * (4612.156534 + t * (1.3915817 + t * (-0.00000044 + t * (-0.000029956 - t * 0.0000000368))))) * AS2R
	var om := fmod(450160.398036 - 6962890.5431 * t, TURNAS) * AS2R
	var eect := (0.00264096 * sin(om) + 0.00006352 * sin(2.0 * om)) * AS2R
	return fposmod(gmst + nut[0] * cos(obliquity(t)) + eect, TAU)

# THE SITE

## Everything a ground observer needs at TT `tt` (with UT1 from ΔT) for geodetic
## latitude `lat`, east longitude `lon` (rad) and height `h` (m) on `figure`
## (Rocketry.FIGURES row, or null for a sphere of `radius_m`). Vectors are GCRS
## unit vectors except `offset` (m, from the geocentre). Also returns `last` (local
## apparent sidereal time, rad), `nut` and `npb`.
static func site(tt: float, lat: float, lon: float, h: float, figure = Rocketry.FIGURES.Earth, radius_m := 6371008.8) -> Dictionary:
	var t := (tt - J2000) / 36525.0
	var nut := nutation(t)
	var m := npb(t, nut)
	var th := fposmod(gast(ut1_of_tt(tt), t, nut) + lon, TAU)
	var cl := cos(lat); var sl := sin(lat)
	var ct := cos(th); var st := sin(th)
	# Rocketry.geodetic_point's frame has the pole on −Y and longitude from +X to +Z.
	var p := Rocketry.geodetic_point({"radius": radius_m, "figure": figure}, lat, th, h, DVec3.new())
	return {
		"up": apply_t(m, DVec3.new(cl * ct, cl * st, sl)),
		"north": apply_t(m, DVec3.new(-sl * ct, -sl * st, cl)),
		"east": apply_t(m, DVec3.new(-st, ct, 0.0)),
		"offset": apply_t(m, DVec3.new(p.x, p.z, -p.y)),
		"last": th, "nut": nut, "npb": m,
	}

## A J2000 equatorial vector in orrery axes (Rocketry.equatorial_dir's convention).
static func to_scene(v: DVec3) -> DVec3:
	var eps := Rocketry.OBLIQUITY_J2000
	return DVec3.new(v.x, -(-v.y * sin(eps) + v.z * cos(eps)), v.y * cos(eps) + v.z * sin(eps))

## The inverse of to_scene.
static func from_scene(v: DVec3) -> DVec3:
	var eps := Rocketry.OBLIQUITY_J2000
	var ye := v.z
	var ze := -v.y
	return DVec3.new(v.x, ye * cos(eps) - ze * sin(eps), ye * sin(eps) + ze * cos(eps))

static func radec_vec(ra: float, dec: float) -> DVec3:
	return DVec3.new(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))

## A catalogue position carried from epoch `epoch_yr` to `yr` (Julian years) by its
## proper motion (`pmra` = μα cos δ and `pmdec`, mas/yr) along a great circle. Linear
## in time: good for centuries, not for millennia of a nearby star.
static func proper_motion(ra: float, dec: float, pmra: float, pmdec: float, epoch_yr: float, yr: float) -> DVec3:
	var p := radec_vec(ra, dec)
	var dt := yr - epoch_yr
	if dt == 0.0 or (pmra == 0.0 and pmdec == 0.0): return p
	var e := DVec3.new(-sin(ra), cos(ra), 0.0)
	var n := DVec3.new(-sin(dec) * cos(ra), -sin(dec) * sin(ra), cos(dec))
	var k := AS2R / 1000.0 * dt
	var mu := e.scaled(pmra * k).add(n.scaled(pmdec * k))
	var a := mu.length()
	if a == 0.0: return p
	return p.scaled(cos(a)).add(mu.scaled(sin(a) / a))

## Altitude (rad) of GCRS direction `d` for a `site()` result.
static func altitude(s: Dictionary, d: DVec3) -> float:
	return asin(clampf(d.dot(s.up), -1.0, 1.0))

## Azimuth (rad, from north through east) of GCRS direction `d`.
static func azimuth(s: Dictionary, d: DVec3) -> float:
	return fposmod(atan2(d.dot(s.east), d.dot(s.north)), TAU)
