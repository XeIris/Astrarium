class_name TimeScales
extends RefCounted

# Dates for a preset with an epoch. The orrery integrates in barycentric coordinate
# time, so its clock is TDB: epoch + sim_years orrery years. TT differs from TDB by
# the periodic terms below, TAI = TT − 32.184 s, and UTC = TAI − ΔAT from the IERS
# leap-second table. Derivation: docs/physics/time.md.

const DAY_S := 86400.0
const J2000 := 2451545.0
const TT_TAI := 32.184
# TAI − UTC from 1972 (Bulletin C 70, the last leap second 2016 Dec 31): the UTC JD
# from which each offset holds. Before 1972 UTC had rubber seconds and is not shown;
# after the table, the last offset holds, since no leap second is announced.
const LEAPS := [
	[2441317.5, 10.0], [2441499.5, 11.0], [2441683.5, 12.0], [2442048.5, 13.0], [2442413.5, 14.0],
	[2442778.5, 15.0], [2443144.5, 16.0], [2443509.5, 17.0], [2443874.5, 18.0], [2444239.5, 19.0],
	[2444786.5, 20.0], [2445151.5, 21.0], [2445516.5, 22.0], [2446247.5, 23.0], [2447161.5, 24.0],
	[2447892.5, 25.0], [2448257.5, 26.0], [2448804.5, 27.0], [2449169.5, 28.0], [2449534.5, 29.0],
	[2450083.5, 30.0], [2450630.5, 31.0], [2451179.5, 32.0], [2453736.5, 33.0], [2454832.5, 34.0],
	[2456109.5, 35.0], [2457204.5, 36.0], [2457754.5, 37.0],
]

## TDB as a Julian date for `sim_years` orrery years after `epoch_jd` (TDB).
static func tdb_jd(epoch_jd: float, sim_years: float) -> float:
	return epoch_jd + sim_years * Rocketry.YR_S / DAY_S

## TDB − TT, s: the two leading periodic terms (USNO Circular 179, eq. 2.6), good to
## ~10 µs; g is the Earth–Moon barycentre's mean anomaly.
static func tdb_minus_tt(jd: float) -> float:
	var g := deg_to_rad(357.53 + 0.98560028 * (jd - J2000))
	return 0.001657 * sin(g) + 0.000014 * sin(2.0 * g)

## TAI − UTC (s) at UTC Julian date `jd_utc`, or NAN before 1972.
static func tai_minus_utc(jd_utc: float) -> float:
	if jd_utc < float(LEAPS[0][0]): return NAN
	var d := 10.0
	for row: Array in LEAPS:
		if jd_utc >= float(row[0]): d = float(row[1])
	return d

## UTC Julian date for TDB `jd`, or NAN outside the leap-second era.
static func utc_jd(jd: float) -> float:
	var tt := jd - tdb_minus_tt(jd) / DAY_S
	var tai := tt - TT_TAI / DAY_S
	# ΔAT is looked up at the UTC instant; one correction converges except within
	# a leap second.
	var d := tai_minus_utc(tai - 37.0 / DAY_S)
	if is_nan(d): return NAN
	return tai - tai_minus_utc(tai - d / DAY_S) / DAY_S

## [year, month, day, hour, minute, second] of Julian date `jd`: Gregorian from
## 1582 Oct 15, Julian before (Meeus, Astronomical Algorithms ch. 7). Years are
## astronomical (0 = 1 BC).
static func calendar(jd: float) -> Array:
	var z := floorf(jd + 0.5)
	var f := jd + 0.5 - z
	var a := z
	if z >= 2299161.0:
		var al := floorf((z - 1867216.25) / 36524.25)
		a = z + 1.0 + al - floorf(al / 4.0)
	var b := a + 1524.0
	var c := floorf((b - 122.1) / 365.25)
	var d := floorf(365.25 * c)
	var e := floorf((b - d) / 30.6001)
	var day := b - d - floorf(30.6001 * e)
	var month := e - 1.0 if e < 14.0 else e - 13.0
	var year := c - 4716.0 if month > 2.0 else c - 4715.0
	var s := f * DAY_S
	var hh := floorf(s / 3600.0)
	var mm := floorf((s - hh * 3600.0) / 60.0)
	return [int(year), int(month), int(day), int(hh), int(mm), s - hh * 3600.0 - mm * 60.0]

static func stamp(jd: float, seconds := true) -> String:
	var c := calendar(jd)
	var t := "%04d-%02d-%02d %02d:%02d" % [c[0], c[1], c[2], c[3], c[4]]
	return t + (":%02d" % int(floorf(float(c[5])))) if seconds else t

## "2000-01-01 11:58:55 UTC · 12:00:00 TDB", TDB alone outside UTC's era.
static func readout(epoch_jd: float, sim_years: float) -> String:
	var tdb := tdb_jd(epoch_jd, sim_years)
	var c := calendar(tdb)
	var tdb_s := "%02d:%02d:%02d TDB" % [c[3], c[4], int(floorf(float(c[5])))]
	var utc := utc_jd(tdb)
	if is_nan(utc): return "%s TDB" % stamp(tdb)
	return "%s UTC · %s" % [stamp(utc), tdb_s]
