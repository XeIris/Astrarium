class_name GalCurve
extends RefCounted

# A rotation curve measured from the live tracers, the way surveys measure one:
# binned mean azimuthal speeds, and for a warm stellar population the circular
# speed recovered with the Jeans equation as Eilers et al. (2019, ApJ 871, 120,
# their eq. 4) did, assuming exponential profiles for ν and ⟨vR²⟩.

const BIN := 1.0          # kpc

## Eilers et al. (2019) Table 1: R (kpc), vc (km/s), and its −/+ errors. Measured
## from 23 000 APOGEE/Gaia red giants with R0 = 8.122 kpc; the curve the model is
## compared with, never fitted to.
const EILERS_2019 := [
	[5.27, 226.83, 1.91, 1.90], [5.74, 230.80, 1.43, 1.35], [6.23, 231.20, 1.70, 1.10],
	[6.73, 229.88, 1.44, 1.32], [7.22, 229.61, 1.37, 1.11], [7.82, 229.91, 0.92, 0.88],
	[8.19, 228.86, 0.80, 0.67], [8.78, 226.50, 1.07, 0.95], [9.27, 226.20, 0.72, 0.62],
	[9.76, 225.94, 0.42, 0.52], [10.26, 225.68, 0.44, 0.40], [10.75, 224.73, 0.38, 0.41],
	[11.25, 224.02, 0.33, 0.54], [11.75, 223.86, 0.40, 0.39], [12.25, 222.23, 0.51, 0.37],
	[12.74, 220.77, 0.54, 0.46], [13.23, 220.92, 0.57, 0.40], [13.74, 217.47, 0.64, 0.51],
	[14.24, 217.31, 0.77, 0.66], [14.74, 217.60, 0.65, 0.68], [15.22, 217.07, 1.06, 0.80],
	[15.74, 217.38, 0.84, 1.07], [16.24, 216.14, 1.20, 1.48], [16.74, 212.52, 1.39, 1.43],
	[17.25, 216.41, 1.44, 1.85], [17.75, 213.70, 2.22, 1.65], [18.24, 207.89, 1.76, 1.88],
	[18.74, 209.60, 2.31, 2.77], [19.22, 206.45, 2.54, 2.36], [19.71, 201.91, 2.99, 2.26],
	[20.27, 199.84, 3.15, 2.89], [20.78, 198.14, 3.33, 3.37], [21.24, 195.30, 5.99, 6.50],
	[21.80, 213.67, 15.38, 12.18], [22.14, 176.97, 28.58, 18.57], [22.73, 193.11, 27.64, 19.05],
	[23.66, 176.63, 18.67, 16.74], [24.82, 198.42, 6.50, 6.12],
]

## Per bin of one population: centre R, count, mean vφ and its standard error (km/s),
## and the moments the Jeans correction needs. Bins with fewer than `min_n` are left out.
static func measure(tr: GalTracers, pop_index: int, rmin: float, rmax: float, min_n := 8) -> Dictionary:
	var nb := int(ceil((rmax - rmin) / BIN))
	var cnt := PackedInt32Array(); cnt.resize(nb)
	var s1 := PackedFloat64Array(); s1.resize(nb)
	var s2 := PackedFloat64Array(); s2.resize(nb)
	var r2 := PackedFloat64Array(); r2.resize(nb)
	var rs := PackedFloat64Array(); rs.resize(nb)
	for i in tr.n:
		if tr.pop[i] != pop_index: continue
		var k := i * 3
		var x := tr.pos[k]
		var z := tr.pos[k + 2]
		var R := sqrt(x * x + z * z)
		var b := int(floor((R - rmin) / BIN))
		if b < 0 or b >= nb: continue
		var vphi := (x * tr.vel[k + 2] - z * tr.vel[k]) / R * tr.sense
		var vr := (x * tr.vel[k] + z * tr.vel[k + 2]) / R
		cnt[b] += 1
		s1[b] += vphi
		s2[b] += vphi * vphi
		r2[b] += vr * vr
		rs[b] += R
	var out := {"R": PackedFloat64Array(), "n": PackedInt32Array(), "v": PackedFloat64Array(),
		"err": PackedFloat64Array(), "vphi2": PackedFloat64Array(), "vr2": PackedFloat64Array(), "nu": PackedFloat64Array()}
	for b in nb:
		if cnt[b] < min_n: continue
		var c := float(cnt[b])
		var m := s1[b] / c
		var var_ := maxf(s2[b] / c - m * m, 0.0)
		var rc := rs[b] / c
		out.R.append(rc)
		out.n.append(cnt[b])
		out.v.append(GalUnits.kms(m))
		out.err.append(GalUnits.kms(sqrt(var_ / maxf(c - 1.0, 1.0))))
		out.vphi2.append(s2[b] / c)
		out.vr2.append(r2[b] / c)
		# Number per unit area in the annulus.
		var r_in := rmin + BIN * float(b)
		out.nu.append(c / (PI * (pow(r_in + BIN, 2.0) - r_in * r_in)))
	return out

## The circular speed recovered from a warm population by the Jeans equation, with
## ν and ⟨vR²⟩ fitted as exponentials in R (Eilers et al. 2019, §3):
## vc² = ⟨vφ²⟩ − ⟨vR²⟩(1 + ∂lnν/∂lnR + ∂ln⟨vR²⟩/∂lnR). Returns km/s per bin.
static func jeans_vc(m: Dictionary) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var R: PackedFloat64Array = m.R
	if R.size() < 3: return out
	var k_nu := GalCurve.log_slope(R, m.nu)
	var k_vr := GalCurve.log_slope(R, m.vr2)
	for i in R.size():
		var vc2: float = m.vphi2[i] - m.vr2[i] * (1.0 + k_nu * R[i] + k_vr * R[i])
		out.append(GalUnits.kms(sqrt(maxf(vc2, 0.0))))
	return out

## d ln y / dR of a least-squares exponential fit (−1/scale length).
static func log_slope(x: PackedFloat64Array, y: PackedFloat64Array) -> float:
	var n := 0.0
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var sxy := 0.0
	for i in x.size():
		if y[i] <= 0.0: continue
		var ly := log(y[i])
		n += 1.0
		sx += x[i]
		sy += ly
		sxx += x[i] * x[i]
		sxy += x[i] * ly
	var d := n * sxx - sx * sx
	return (n * sxy - sx * sy) / d if d != 0.0 else 0.0
