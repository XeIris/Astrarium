class_name OceanField
extends RefCounted

# A sea as Tessendorf's FFT ocean: SurfaceWaves' JONSWAP with Donelan–Banner spreading, sampled on four
# square lattices (cascades), each tile L metres across and owning one band of wavenumbers so no wave is counted
# twice. The GPU draws all four (OceanGPU); the CPU runs the two long ones, which carry what moves a hull, on
# the same amplitudes, phases and clock, so a floating body reads the height that is drawn.
# Site frame: x west, z north, y up; SI. docs/physics/ocean.md.

const CASCADES := 4
## The two long cascades are the CPU's; their lattice is the same size on both sides.
const PHYSICS := 2
const N_PHYS := 64
const N_DETAIL := 128
## The longest tile, in peak wavelengths: long enough that the spectrum's low side is sampled.
const PEAK_TILES := 6.0
const L_MIN := 12.0
const L_MAX := 3000.0
## Each tile is this much smaller than the one before it.
const RATIOS := [1.0, 5.0, 5.0, 8.0]
## A cascade's band ends at half its lattice's Nyquist wavenumber: four texels a wavelength. The last keeps
## its own Nyquist's half too; shorter waves are the glint's roughness (unresolved_slope).
const BAND := 0.5

var g := 9.81
var depth := 4000.0
var liquid: Dictionary = Liquid.SEAWATER
var wind := 5.0
var bearing := 0.0
var fetch := 6.0e5
var peak_omega := 1.0
var peak_k := 0.1
## Tile sizes, lattice sizes and the band each owns, rad/m.
var L := PackedFloat64Array()
var n := PackedInt32Array()
var k_lo := PackedFloat64Array()
var k_hi := PackedFloat64Array()
## Per cascade, per mode (row-major, z row, x column): h̃₀'s real and imaginary parts, ω, and the unit
## normals ξ that drew it (kept, so a change of wind rescales a mode and never redraws its phase).
var h0r: Array[PackedFloat64Array] = []
var h0i: Array[PackedFloat64Array] = []
var omega: Array[PackedFloat64Array] = []
var _xr: Array[PackedFloat64Array] = []
var _xi: Array[PackedFloat64Array] = []
## Variance each cascade carries, m², and its mean-square slope.
var variance := PackedFloat64Array()
var slope_var := PackedFloat64Array()
## The CPU's grids for the physics cascades at `t_snap`: horizontal displacement and height, m.
var t_snap := -INF
var dx: Array[PackedFloat64Array] = []
var hy: Array[PackedFloat64Array] = []
var dz: Array[PackedFloat64Array] = []
var _fft := {}
## Per physics cascade, which lattice rows hold any mode: an empty row's transform is zero, so it is skipped.
var _live: Array[PackedByteArray] = []

func _init(gravity: float, sea_depth: float, liq: Dictionary, wind_ms: float, bearing_rad: float, fetch_m: float, seed_: int) -> void:
	g = gravity
	depth = maxf(sea_depth, 1.0)
	liquid = liq
	fetch = fetch_m
	wind = maxf(wind_ms, SurfaceWaves.MIN_WIND)
	bearing = bearing_rad
	peak_omega = SurfaceWaves.peak_omega(wind, g, fetch)
	peak_k = SurfaceWaves.wavenumber(peak_omega, g, depth, float(liq.rho), float(liq.sigma))
	_lay_out()
	var rng := RandomNumberGenerator.new()
	for c in CASCADES:
		rng.seed = hash([seed_, c])
		var m := n[c] * n[c]
		var xr := PackedFloat64Array(); xr.resize(m)
		var xi := PackedFloat64Array(); xi.resize(m)
		for i in m:
			xr[i] = rng.randfn(0.0, 1.0)
			xi[i] = rng.randfn(0.0, 1.0)
		_xr.append(xr); _xi.append(xi)
		var hr := PackedFloat64Array(); hr.resize(m)
		var hi := PackedFloat64Array(); hi.resize(m)
		var w := PackedFloat64Array(); w.resize(m)
		h0r.append(hr); h0i.append(hi); omega.append(w)
		if c < PHYSICS:
			var a := PackedFloat64Array(); a.resize(m)
			dx.append(a.duplicate()); hy.append(a.duplicate()); dz.append(a.duplicate())
	variance.resize(CASCADES)
	slope_var.resize(CASCADES)
	_fill()

const REPEAT_TILE := 1.5

func _tile() -> float:
	return clampf(PEAK_TILES * TAU / maxf(peak_k, 1e-6), L_MIN, L_MAX)

# The longest tile from the peak; the rest from it, each band starting where the last ended.
func _lay_out() -> void:
	for a in [L, n, k_lo, k_hi]: a.clear()
	var at := _tile()
	var lo := 0.0
	for c in CASCADES:
		at /= float(RATIOS[c])
		var nn := N_PHYS if c < PHYSICS else N_DETAIL
		L.append(at); n.append(nn)
		var hi := BAND * PI * nn / at
		k_lo.append(lo); k_hi.append(hi)
		lo = hi

## Every wave's ω is a whole number of turns in this long, s: the sea repeats after two hours and a quarter, and
## the GPU's float32 phase is taken from a time that never grows past it. It moves ω by 4e-4 rad/s at most.
const PERIOD := 8192.0

## ω of a wave of wavenumber k on this sea: gravity and the liquid's surface tension, over its depth.
func dispersion(k: float) -> float:
	var s := float(liquid.sigma) / float(liquid.rho)
	return sqrt((g * k + s * k * k * k) * tanh(minf(k * depth, 20.0)))

## dω/dk, from the same relation.
func group_speed(k: float) -> float:
	var s := float(liquid.sigma) / float(liquid.rho)
	var th := tanh(minf(k * depth, 20.0))
	var f := g * k + s * k * k * k
	var w := sqrt(f * th)
	return ((g + 3.0 * s * k * k) * th + f * depth * (1.0 - th * th)) / (2.0 * maxf(w, 1e-12))

## Donelan et al. 1985's sech² spreading with Banner 1990's tail, normalised over a full turn: D(θ) at an
## angle θ from the wind, for a wave at ω.
static func spreading(theta: float, w: float, wp: float) -> float:
	var r := w / wp
	var beta := 2.61 * pow(r, 1.3) if r < 0.95 else (2.28 * pow(r, -1.3) if r < 1.6 else pow(10.0, -0.4 + 0.8393 * exp(-0.567 * log(r * r))))
	if r < 0.56: beta = 2.61 * pow(0.56, 1.3)
	var c := cosh(beta * theta)
	return beta / (2.0 * tanh(beta * PI)) / (c * c)

## The wavenumber spectrum per mode area, m⁴: S(ω)D(θ)(dω/dk)/k, for a wave vector (kx west, kz north).
func spectrum_k(kx: float, kz: float) -> float:
	var k := sqrt(kx * kx + kz * kz)
	if k <= 0.0: return 0.0
	var w := dispersion(k)
	var theta := wrapf(atan2(-kx, kz) - bearing, -PI, PI)
	return SurfaceWaves.spectrum(w, wind, g, fetch) * spreading(theta, w, peak_omega) * group_speed(k) / k

## Re-draw the amplitudes for a new wind, keeping every mode's random draw.
func set_wind(wind_ms: float, bearing_rad: float) -> void:
	wind = maxf(wind_ms, SurfaceWaves.MIN_WIND)
	bearing = bearing_rad
	peak_omega = SurfaceWaves.peak_omega(wind, g, fetch)
	peak_k = SurfaceWaves.wavenumber(peak_omega, g, depth, float(liquid.rho), float(liquid.sigma))
	# A wind that has outgrown the longest tile by this much needs longer ones: its peak would be cut off.
	if _tile() > REPEAT_TILE * L[0]: _lay_out()
	_fill()
	t_snap = -INF

## Whether the wind is under the liquid's onset for waves (Liquid's `onset`): then the sea lies flat.
func calm() -> bool:
	return wind < float(liquid.get("onset", 0.0))

func _fill() -> void:
	var still := calm()
	for c in CASCADES:
		var nn := n[c]
		var dk := TAU / L[c]
		var var_c := 0.0
		var sl_c := 0.0
		for iz in nn:
			var kz := dk * float(_signed(iz, nn))
			for ix in nn:
				var kx := dk * float(_signed(ix, nn))
				var i := iz * nn + ix
				var k := sqrt(kx * kx + kz * kz)
				var a := 0.0
				# The Nyquist row and column stay empty, so every mode has its −k partner on the lattice.
				if not still and k >= k_lo[c] and k < k_hi[c] and ix != nn / 2 and iz != nn / 2:
					var e := spectrum_k(kx, kz) * dk * dk
					var_c += e
					sl_c += e * k * k
					# ⟨|h̃₀|²⟩ = e/2: a mode and its −k partner each give |h̃₀|² of variance.
					a = sqrt(0.25 * e)
				h0r[c][i] = _xr[c][i] * a
				h0i[c][i] = _xi[c][i] * a
				omega[c][i] = roundf(dispersion(k) * PERIOD / TAU) * TAU / PERIOD
		variance[c] = var_c
		slope_var[c] = sl_c
		if c < PHYSICS:
			var live := PackedByteArray(); live.resize(nn)
			for iz in nn:
				for ix in nn:
					if h0r[c][iz * nn + ix] != 0.0 or h0r[c][((nn - iz) % nn) * nn + (nn - ix) % nn] != 0.0:
						live[iz] = 1
						break
			if _live.size() <= c: _live.append(live)
			else: _live[c] = live

static func _signed(i: int, nn: int) -> int:
	return i if i < nn / 2 else i - nn

## Significant wave height the lattices carry, m: 4√m₀.
func hs(cascades := CASCADES) -> float:
	var m0 := 0.0
	for c in cascades: m0 += variance[c]
	return 4.0 * sqrt(m0)

## Mean-square slope of what no cascade draws, from the last band's top to where capillary waves take over
## (k = √(ρg/σ)), on the same spectrum along the wind: what the glint's roughness stands in for.
func unresolved_slope() -> float:
	var k0 := k_hi[CASCADES - 1]
	var k1 := sqrt(float(liquid.rho) * g / float(liquid.sigma))
	if k1 <= k0 or calm(): return 0.0
	var steps := 64
	var total := 0.0
	var r := pow(k1 / k0, 1.0 / steps)
	var k := k0
	for i in steps:
		var kn := k * r
		var km := sqrt(k * kn)
		# The omnidirectional spectrum: ∫D dθ = 1.
		var s := SurfaceWaves.spectrum(dispersion(km), wind, g, fetch) * group_speed(km)
		total += s * km * km * (kn - k)
		k = kn
	return total

## The CPU's grids at time t (s on the site's clock): h̃(k,t) = h̃₀(k)e^{−iωt} + h̃₀*(−k)e^{iωt}, then
## D̂ = i(k/|k|)h̃, through two inverse FFTs per cascade (the horizontal pair packed as one complex field).
func snapshot(t: float) -> void:
	if t == t_snap: return
	t_snap = t
	for c in PHYSICS:
		var nn := n[c]
		var dk := TAU / L[c]
		var ar := dx[c]; var ai := dz[c]
		var br := hy[c]
		var bi := PackedFloat64Array(); bi.resize(nn * nn)
		var hr := h0r[c]; var hi := h0i[c]; var w := omega[c]
		for iz in nn:
			var kz := dk * float(_signed(iz, nn))
			var mz := (nn - iz) % nn
			for ix in nn:
				var i := iz * nn + ix
				var j := mz * nn + (nn - ix) % nn
				var p := hr[i]; var q := hi[i]; var pm := hr[j]; var qm := hi[j]
				if p == 0.0 and q == 0.0 and pm == 0.0 and qm == 0.0:
					ar[i] = 0.0; ai[i] = 0.0; br[i] = 0.0
					continue
				var ph := w[i] * t
				var cs := cos(ph); var sn := sin(ph)
				var Hr := p * cs + q * sn + pm * cs + qm * sn
				var Hi := q * cs - p * sn + pm * sn - qm * cs
				var kx := dk * float(_signed(ix, nn))
				var k := sqrt(kx * kx + kz * kz)
				var ux := kx / k; var uz := kz / k
				# i·k̂·h̃ for x and for z, the z one times i again to pack the pair.
				ar[i] = -ux * Hi - uz * Hr
				ai[i] = ux * Hr - uz * Hi
				br[i] = Hr; bi[i] = Hi
		_ifft2(ar, ai, nn, _live[c])
		_ifft2(br, bi, nn, _live[c])

## The physics cascades' displacement at a lattice-frame point, m: (Dx, h, Dz), each bilinear between texels as
## the water shader fetches them.
func displacement(x: float, z: float) -> Vector3:
	var ox := 0.0; var oy := 0.0; var oz := 0.0
	for c in PHYSICS:
		var nn := n[c]
		var d := L[c] / float(nn)
		var u := x / d; var v := z / d
		var i0 := floori(u); var j0 := floori(v)
		var fu := u - float(i0); var fv := v - float(j0)
		var a := posmod(i0, nn); var b := posmod(i0 + 1, nn)
		var e := posmod(j0, nn) * nn; var f := posmod(j0 + 1, nn) * nn
		var w00 := (1.0 - fu) * (1.0 - fv); var w10 := fu * (1.0 - fv); var w01 := (1.0 - fu) * fv; var w11 := fu * fv
		ox += dx[c][e + a] * w00 + dx[c][e + b] * w10 + dx[c][f + a] * w01 + dx[c][f + b] * w11
		oy += hy[c][e + a] * w00 + hy[c][e + b] * w10 + hy[c][f + a] * w01 + hy[c][f + b] * w11
		oz += dz[c][e + a] * w00 + dz[c][e + b] * w10 + dz[c][f + a] * w01 + dz[c][f + b] * w11
	return Vector3(ox, oy, oz)

## The height of the drawn surface over the site point (x, z), m from the mean level: the lattice point whose
## displacement lands there, by fixed-point iteration (it converges while no wave folds over).
func height_at(x: float, z: float) -> float:
	var px := x; var pz := z
	var d := Vector3.ZERO
	for it in 5:
		d = displacement(px, pz)
		px = x - d.x
		pz = z - d.z
	return displacement(px, pz).y

## A direct sum over a physics cascade's modes at one point and time, m: what its FFT must equal on its
## lattice.
func direct_height(x: float, z: float, t: float, c: int) -> float:
	var total := 0.0
	if true:
		var nn := n[c]
		var dk := TAU / L[c]
		for iz in nn:
			for ix in nn:
				var i := iz * nn + ix
				var j := ((nn - iz) % nn) * nn + (nn - ix) % nn
				if h0r[c][i] == 0.0 and h0i[c][i] == 0.0 and h0r[c][j] == 0.0 and h0i[c][j] == 0.0: continue
				var ph := omega[c][i] * t
				var Hr := (h0r[c][i] + h0r[c][j]) * cos(ph) + (h0i[c][i] + h0i[c][j]) * sin(ph)
				var Hi := (h0i[c][i] - h0i[c][j]) * cos(ph) - (h0r[c][i] - h0r[c][j]) * sin(ph)
				var arg := dk * (float(_signed(ix, nn)) * x + float(_signed(iz, nn)) * z)
				total += Hr * cos(arg) - Hi * sin(arg)
	return total

# The 2D inverse DFT without normalisation, x_n = Σ F_m e^{+2πi mn/N}, rows then columns, in place.
func _ifft2(re: PackedFloat64Array, im: PackedFloat64Array, nn: int, live: PackedByteArray) -> void:
	if not _fft.has(nn): _fft[nn] = _plan(nn)
	var pl: Dictionary = _fft[nn]
	for row in nn:
		if live[row]: _fft1(re, im, nn, row * nn, 1, pl)
	for col in nn: _fft1(re, im, nn, col, nn, pl)

static func _plan(nn: int) -> Dictionary:
	var twr := PackedFloat64Array(); var twi := PackedFloat64Array()
	for k in nn / 2:
		twr.append(cos(TAU * k / nn)); twi.append(sin(TAU * k / nn))
	var bits := 0
	while (1 << bits) < nn: bits += 1
	var rev := PackedInt32Array(); rev.resize(nn)
	for i in nn:
		var r := 0
		for b in bits:
			if i & (1 << b): r |= 1 << (bits - 1 - b)
		rev[i] = r
	return {"twr": twr, "twi": twi, "rev": rev}

static func _fft1(re: PackedFloat64Array, im: PackedFloat64Array, nn: int, off: int, stride: int, pl: Dictionary) -> void:
	var rev: PackedInt32Array = pl.rev
	var twr: PackedFloat64Array = pl.twr
	var twi: PackedFloat64Array = pl.twi
	for i in nn:
		var j := rev[i]
		if j > i:
			var a := off + i * stride
			var b := off + j * stride
			var t := re[a]; re[a] = re[b]; re[b] = t
			t = im[a]; im[a] = im[b]; im[b] = t
	var size := 2
	while size <= nn:
		var half := size >> 1
		var step := nn / size
		var s := 0
		while s < nn:
			for k in half:
				var wr := twr[k * step]
				var wi := twi[k * step]
				var a := off + (s + k) * stride
				var b := a + half * stride
				var xr := re[b] * wr - im[b] * wi
				var xi := re[b] * wi + im[b] * wr
				re[b] = re[a] - xr; im[b] = im[a] - xi
				re[a] += xr; im[a] += xi
			s += size
		size <<= 1
