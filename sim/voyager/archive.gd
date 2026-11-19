class_name VoyagerArchive
extends Resource

## Each row is a UTC Unix second, heliocentric ecliptic J2000 XYZ in AU, and AU/day.
@export var tracks: Dictionary
const STRIDE := 7
const DAY := 86400.0

func position_at(body: String, utc: float) -> DVec3:
	var rows: PackedFloat64Array = tracks[body]
	var last := rows.size() - STRIDE
	if utc < rows[0] or utc > rows[last]: return null
	var lo := 0
	var hi := floori(float(last) / STRIDE)
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if rows[mid * STRIDE] <= utc: lo = mid
		else: hi = mid
	var a := lo * STRIDE
	var b := hi * STRIDE
	var seconds := rows[b] - rows[a]
	var t := (utc - rows[a]) / seconds
	# Hermite interpolation preserves the incoming and outgoing velocity around an assist.
	var t2 := t * t
	var blend := t2 * (3.0 - 2.0 * t)
	var va := t * (1.0 - t) * (1.0 - t) * seconds / DAY
	var vb := t2 * (t - 1.0) * seconds / DAY
	return DVec3.new(lerpf(rows[a+1], rows[b+1], blend) + va*rows[a+4] + vb*rows[b+4],
		lerpf(rows[a+2], rows[b+2], blend) + va*rows[a+5] + vb*rows[b+5],
		lerpf(rows[a+3], rows[b+3], blend) + va*rows[a+6] + vb*rows[b+6])
