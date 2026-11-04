class_name LunarTheory
extends RefCounted

# The Moon's geocentric place on a date from the leading periodic terms of ELP-2000/82
# (Chapront-Touzé & Chapront 1983), as Meeus truncates them (Astronomical Algorithms,
# 2nd ed., ch. 47, the largest rows of table 47.A/B and the additive A1–A3 terms).
# The solar preset's mean elements leave out evection, variation and the annual
# equation, up to 2° by 2126; the Observatory starts the Moon from this instead and
# lets the N-body integration carry it. Error against JPL Horizons: observatorycheck.

const DEG := PI / 180.0

# [D, M, M′, F, Σl (1e-6°), Σr (m)]
const LR := [
	[0, 0, 1, 0, 6288774, -20905355], [2, 0, -1, 0, 1274027, -3699111], [2, 0, 0, 0, 658314, -2955968],
	[0, 0, 2, 0, 213618, -569925], [0, 1, 0, 0, -185116, 48888], [0, 0, 0, 2, -114332, -3149],
	[2, 0, -2, 0, 58793, 246158], [2, -1, -1, 0, 57066, -152138], [2, 0, 1, 0, 53322, -170733],
	[2, -1, 0, 0, 45758, -204586], [0, 1, -1, 0, -40923, -129620], [1, 0, 0, 0, -34720, 108743],
	[0, 1, 1, 0, -30383, 104755], [2, 0, 0, -2, 15327, 10321], [0, 0, 1, 2, -12528, 0],
	[0, 0, 1, -2, 10980, 79661], [4, 0, -1, 0, 10675, -34782], [0, 0, 3, 0, 10034, -23210],
	[4, 0, -2, 0, 8548, -21636], [2, 1, -1, 0, -7888, 24208], [2, 1, 0, 0, -6766, 30824],
	[1, 0, -1, 0, -5163, -8379], [1, 1, 0, 0, 4987, -16675], [2, -1, 1, 0, 4036, -12831],
	[2, 0, 2, 0, 3994, -10445],
]
# [D, M, M′, F, Σb (1e-6°)]
const B := [
	[0, 0, 0, 1, 5128122], [0, 0, 1, 1, 280602], [0, 0, 1, -1, 277693], [2, 0, 0, -1, 173237],
	[2, 0, -1, 1, 55413], [2, 0, -1, -1, 46271], [2, 0, 0, 1, 32573], [0, 0, 2, 1, 17198],
	[2, 0, 1, -1, 9266], [0, 0, 2, -1, 8822], [2, -1, 0, -1, 8216], [2, 0, -2, -1, 4324],
	[2, 0, 1, 1, 4200], [2, 1, 0, -1, -3359], [2, -1, -1, 1, 2463],
]

## Geocentric position of the Moon (AU, orrery axes, J2000) at TT Julian date `tt`.
static func position(tt: float) -> DVec3:
	var t := (tt - EarthFrame.J2000) / 36525.0
	var lp := (218.3164477 + t * (481267.88123421 + t * (-0.0015786 + t * (1.0 / 538841.0 - t / 65194000.0)))) * DEG
	var d := (297.8501921 + t * (445267.1114034 + t * (-0.0018819 + t * (1.0 / 545868.0 - t / 113065000.0)))) * DEG
	var m := (357.5291092 + t * (35999.0502909 + t * (-0.0001536 + t / 24490000.0))) * DEG
	var mp := (134.9633964 + t * (477198.8675055 + t * (0.0087414 + t * (1.0 / 69699.0 - t / 14712000.0)))) * DEG
	var f := (93.2720950 + t * (483202.0175233 + t * (-0.0036539 + t * (-1.0 / 3526000.0 + t / 863310000.0)))) * DEG
	# Earth's orbital eccentricity is falling: terms in M carry E per power.
	var e := 1.0 - t * (0.002516 + t * 0.0000074)
	var sl := 0.0
	var sr := 0.0
	for x: Array in LR:
		var arg := float(x[0]) * d + float(x[1]) * m + float(x[2]) * mp + float(x[3]) * f
		var k := pow(e, absf(float(x[1])))
		sl += float(x[4]) * k * sin(arg)
		sr += float(x[5]) * k * cos(arg)
	var sb := 0.0
	for x: Array in B:
		var arg := float(x[0]) * d + float(x[1]) * m + float(x[2]) * mp + float(x[3]) * f
		sb += float(x[4]) * pow(e, absf(float(x[1]))) * sin(arg)
	# Venus, Jupiter and Earth's flattening.
	var a1 := (119.75 + 131.849 * t) * DEG
	var a2 := (53.09 + 479264.290 * t) * DEG
	var a3 := (313.45 + 481266.484 * t) * DEG
	sl += 3958.0 * sin(a1) + 1962.0 * sin(lp - f) + 318.0 * sin(a2)
	sb += -2235.0 * sin(lp) + 382.0 * sin(a3) + 175.0 * sin(a1 - f) + 175.0 * sin(a1 + f) + 127.0 * sin(lp - mp) - 115.0 * sin(lp + mp)
	var lam := lp + sl * 1e-6 * DEG
	var beta := sb * 1e-6 * DEG
	var r := (385000.56e3 + sr) / Rocketry.AU_M
	# Ecliptic and equinox of date → mean equator of date → GCRS → orrery axes.
	var ecl := DVec3.new(cos(beta) * cos(lam), cos(beta) * sin(lam), sin(beta)).scaled(r)
	var eps := EarthFrame.obliquity(t)
	var eq := DVec3.new(ecl.x, ecl.y * cos(eps) - ecl.z * sin(eps), ecl.y * sin(eps) + ecl.z * cos(eps))
	return EarthFrame.to_scene(EarthFrame.apply_t(EarthFrame.npb(t, PackedFloat64Array([0.0, 0.0])), eq))

## Geocentric velocity (AU per orrery year), by central difference over ±30 min.
static func velocity(tt: float) -> DVec3:
	var h := 1.0 / 48.0
	return position(tt + h).sub(position(tt - h)).scaled(Rocketry.YR_S / TimeScales.DAY_S / (2.0 * h))
