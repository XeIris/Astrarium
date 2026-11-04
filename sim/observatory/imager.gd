class_name Imager
extends RefCounted

# Synthesises a detector frame on the CPU, so a headless check sees the same numbers the
# screen does: sources through the air and the PSF, then sky, dark, Poisson and read noise,
# clipped at the full well. Images are north up, east left. Pure data in, pure data out; the
# caller may run expose() on a worker. docs/physics/instruments.md.

const AS := PI / 648000.0
## A star's stamp stops where it would add under this many electrons to a pixel.
const STAMP_FLOOR := 0.02
const MAX_KERNEL := 32
## How far a bright star's wings may reach, pixels.
const MAX_WING := 400.0
static var _psfs := {}
static var _kernels := {}

## The instrument's PSF at this seeing (arcsec at 500 nm and the zenith; 0 = no air).
static func psf_for(row: Dictionary, seeing: float, x: float) -> Dictionary:
	var key := [row.d, row.eps, row.lambda, snappedf(seeing, 0.001), snappedf(x, 0.01)]
	if not _psfs.has(key):
		if _psfs.size() > 16: _psfs.clear()
		var r0: float = INF if seeing <= 0.0 else Optics.r0_of(seeing * AS, float(row.lambda), x)
		_psfs[key] = Optics.psf(float(row.d), float(row.eps), float(row.lambda), r0)
	return _psfs[key]

## East and north on the sky at unit vector `c`.
static func sky_axes(c: DVec3) -> Array:
	var e := DVec3.new(0.0, 0.0, 1.0).cross(c)
	if e.length_sq() < 1e-14: e = DVec3.new(0.0, 1.0, 0.0)
	e = e.normalized()
	return [e, c.cross(e).normalized()]

## The CCD equation.
static func snr(n: float, npix: float, sky: float, dark: float, read: float) -> float:
	return n / sqrt(maxf(n + npix * (sky + dark + read * read), 1e-30))

## The V that reaches SNR 5 in the aperture, given its background per pixel. `t` is the air's
## transmission and `ee` the aperture's share of the light.
static func limit_mag(row: Dictionary, t: float, texp: float, ee: float, npix: float, sky: float, dark: float, read: float) -> float:
	var b := npix * (sky + dark + read * read)
	var n := (25.0 + sqrt(625.0 + 100.0 * b)) * 0.5
	return Telescopes.zero_point(row) - 2.5 * U.log10(n / (texp * ee * t))

## Pixel-integrated copies of the PSF, one per quarter-pixel offset of the star.
static func _kernel(psf: Dictionary, p: float) -> Dictionary:
	var key := [psf.dr, psf.fwhm, p]
	if _kernels.has(key): return _kernels[key]
	if _kernels.size() > 8: _kernels.clear()
	var fwhm: float = psf.fwhm
	var tab: PackedFloat64Array = psf.p
	var dr: float = psf.dr
	var reach: float = dr * (tab.size() - 1)
	var kr := clampi(ceili(reach / p) + 1, 1, MAX_KERNEL)
	var dim := 2 * kr + 1
	var out: Array[PackedFloat32Array] = []
	# Much under a pixel: the light simply lands in the pixel the star is in.
	var point := fwhm * 4.0 < p
	var ss := clampi(ceili(3.0 * p / fwhm), 1, 4)
	var cell := p / ss
	var area := cell * cell
	var rmax := PackedFloat32Array()
	rmax.resize(kr + 1)
	for qy in 4:
		for qx in 4:
			var k := PackedFloat32Array()
			k.resize(dim * dim)
			if point:
				k[kr * dim + kr] = 1.0
				rmax[0] = 1.0
				out.append(k)
				continue
			var ox := (qx + 0.5) / 4.0
			var oy := (qy + 0.5) / 4.0
			var total := 0.0
			for j in dim:
				for i in dim:
					var s := 0.0
					for b in ss:
						var dy := (j - kr + (b + 0.5) / ss - oy) * p
						for a in ss:
							var dx := (i - kr + (a + 0.5) / ss - ox) * p
							var f := sqrt(dx * dx + dy * dy) / dr
							var ix := int(f)
							if ix < tab.size() - 1: s += lerpf(tab[ix], tab[ix + 1], f - ix)
					s *= area
					k[j * dim + i] = s
					total += s
			# Only numerical rounding: the table's reach holds the energy it was normalised to.
			if total > 0.0:
				for n in k.size(): k[n] /= total
			for j in dim:
				for i in dim:
					var r := maxi(absi(i - kr), absi(j - kr))
					rmax[r] = maxf(rmax[r], k[j * dim + i])
			out.append(k)
	var d := {"k": out, "r": kr, "rmax": rmax}
	_kernels[key] = d
	return d

## A bright star's light past its kernel: the PSF's table, then Kolmogorov's θ^(−11/3) tail.
## Diffraction alone stops at the table, since its rings are not a power law worth drawing.
static func _wings(e: PackedFloat32Array, w: int, psf: Dictionary, p: float, kr: int, cx: float, cy: float, n: float) -> void:
	var tab: PackedFloat64Array = psf.p
	var dr: float = psf.dr
	var reach: float = dr * (tab.size() - 1)
	var tail: float = tab[tab.size() - 1]
	var seeing_limited: bool = psf.get("air", false)
	var unit := n * p * p
	if unit * tail < STAMP_FLOOR: return
	var far := reach
	if seeing_limited and tail > 0.0:
		far = reach * pow(unit * tail / STAMP_FLOOR, 3.0 / 11.0)
	var rp := minf(far / p, MAX_WING)
	if rp <= kr: return
	var ix := floori(cx)
	var iy := floori(cy)
	var r0 := ceili(rp)
	for j in range(maxi(iy - r0, 0), mini(iy + r0, w - 1) + 1):
		var dy := j + 0.5 - cy
		for i in range(maxi(ix - r0, 0), mini(ix + r0, w - 1) + 1):
			var dx := i + 0.5 - cx
			var r := sqrt(dx * dx + dy * dy) * p
			if r >= far: continue
			# The kernel already holds what the table reaches inside its box.
			if r < reach and absi(i - ix) <= kr and absi(j - iy) <= kr: continue
			if r < reach:
				var f := r / dr
				var k := int(f)
				e[j * w + i] += unit * lerpf(tab[k], tab[k + 1], f - k)
			elif seeing_limited:
				e[j * w + i] += unit * tail * pow(reach / r, 11.0 / 3.0)

## Charge past a full well runs along its CCD column until a pixel has room, half each way.
## What runs off the frame is lost.
static func _bleed(e: PackedFloat32Array, w: int, full: float) -> void:
	var over := PackedFloat64Array()
	over.resize(w)
	for i in w:
		var any := false
		for j in w:
			var at := j * w + i
			over[j] = maxf(e[at] - full, 0.0)
			if over[j] > 0.0:
				e[at] = full
				any = true
		if not any: continue
		var down := 0.0
		for j in w:
			down += over[j] * 0.5
			var take := minf(down, full - e[j * w + i])
			e[j * w + i] += take
			down -= take
		var up := 0.0
		for j in range(w - 1, -1, -1):
			up += over[j] * 0.5
			var take := minf(up, full - e[j * w + i])
			e[j * w + i] += take
			up -= take

## Add a star of `n` electrons at (cx, cy) px.
static func _stamp(e: PackedFloat32Array, w: int, kern: Dictionary, cx: float, cy: float, n: float) -> void:
	var ix := floori(cx)
	var iy := floori(cy)
	var kr: int = kern.r
	if ix < -kr or iy < -kr or ix >= w + kr or iy >= w + kr: return
	var rmax: PackedFloat32Array = kern.rmax
	var r := kr
	while r > 0 and rmax[r] * n < STAMP_FLOOR: r -= 1
	var q := clampi(int((cy - iy) * 4.0), 0, 3) * 4 + clampi(int((cx - ix) * 4.0), 0, 3)
	var k: PackedFloat32Array = (kern.k as Array)[q]
	var dim := 2 * kr + 1
	for j in range(maxi(-r, -iy), mini(r, w - 1 - iy) + 1):
		var row := (j + kr) * dim + kr
		var out := (iy + j) * w + ix
		for i in range(maxi(-r, -ix), mini(r, w - 1 - ix) + 1):
			e[out + i] += n * k[row + i]

## Blur `e` in place by a Gaussian of `sigma` pixels, separably. Edges repeat.
static func _blur(e: PackedFloat32Array, w: int, sigma: float) -> void:
	if sigma < 0.3: return
	var rad := ceili(sigma * 3.0)
	var taps := PackedFloat32Array()
	taps.resize(2 * rad + 1)
	var sum := 0.0
	for i in taps.size():
		var d := float(i - rad) / sigma
		taps[i] = exp(-0.5 * d * d)
		sum += taps[i]
	for i in taps.size(): taps[i] /= sum
	var tmp := PackedFloat32Array()
	tmp.resize(e.size())
	for j in w:
		var row := j * w
		for i in w:
			var s := 0.0
			for t in taps.size(): s += taps[t] * e[row + clampi(i + t - rad, 0, w - 1)]
			tmp[row + i] = s
	for j in w:
		var row := j * w
		for i in w:
			var s := 0.0
			for t in taps.size(): s += taps[t] * tmp[clampi(j + t - rad, 0, w - 1) * w + i]
			e[row + i] = s

## A draw from a Poisson distribution of mean `mean`: Knuth's product below 30, a rounded
## Gaussian above, where the two are indistinguishable at the frame's precision.
static func poisson(rng: RandomNumberGenerator, mean: float) -> float:
	if mean <= 0.0: return 0.0
	if mean > 30.0: return roundf(maxf(rng.randfn(mean, sqrt(mean)), 0.0))
	var l := exp(-mean)
	var k := 0
	var p := 1.0
	while true:
		p *= rng.randf()
		if p <= l: return float(k)
		k += 1
	return 0.0

## Take a frame. `req`: row (Telescopes row), centre (unit DVec3, J2000), x (airmass), k_v,
## sky_v (mag/arcsec²), seeing (″), exposure (s), nd (mag, optional), bin, w (pixels square),
## seed, year, tdb,
## bodies ([{name, dir, radius (rad), v, o, to_sun, jy}]), target_v (NAN = none), and for a
## check stars ([[DVec3, V]], replacing the sky's).
static func expose(req: Dictionary) -> Dictionary:
	var row: Dictionary = req.row
	if row.kind == "radio": return _expose_radio(req)
	var bin: int = req.get("bin", 1)
	var w: int = req.get("w", 256)
	var texp: float = req.exposure
	var x: float = req.x
	var pixel: float = float(row.pixel) * bin
	var p := pixel * AS
	# A neutral-density filter dims everything, sky included, ahead of the detector.
	var nd := pow(10.0, -0.4 * float(req.get("nd", 0.0)))
	var t := SkyConditions.transmission(float(req.k_v), x) * nd
	var psf := psf_for(row, float(req.seeing), x)
	var fwhm: float = psf.fwhm
	var sky_e := Telescopes.electrons_per_s(row, float(req.sky_v)) * pixel * pixel * texp * nd
	var dark_e: float = float(row.dark) * bin * bin * texp
	var read: float = float(row.read) * bin
	var full: float = float(row.full) * bin * bin
	var r_ap := maxf(fwhm, p)
	var npix := PI * pow(r_ap / p, 2.0)
	var ee := Optics.encircled(psf, r_ap)
	# With the sky alone over the well, nothing is left to measure a star against.
	var lim := limit_mag(row, t, texp, ee, npix, sky_e, dark_e, read) if sky_e + dark_e < full else NAN
	var rate := func(v: float) -> float: return Telescopes.electrons_per_s(row, v) * t * texp
	var c: DVec3 = req.centre
	var axes := sky_axes(c)
	var east: DVec3 = axes[0]
	var north: DVec3 = axes[1]
	var half := w * 0.5
	var e := PackedFloat32Array()
	e.resize(w * w)
	var bodies: Array = req.get("bodies", [])
	var kern := _kernel(psf, p)
	var points := []
	var resolved := false
	for b: Dictionary in bodies:
		var d: DVec3 = b.dir
		var k := d.dot(c)
		if k <= 0.0: continue
		var cx: float = half - d.dot(east) / k / p
		var cy: float = half - d.dot(north) / k / p
		var r: float = b.radius
		if r / p < 0.7 or fwhm * 4.0 > r * 8.0 and r / p < 2.0:
			points.append([cx, cy, rate.call(float(b.v))])
		else:
			PlanetDisc.paint(e, w, cx, cy, p, b.name, r, rate.call(float(b.v)), b.o, b.to_sun, east, north, float(req.tdb))
			resolved = true
	_blur(e, w, fwhm / 2.3548 / p)
	for q: Array in points:
		_stamp(e, w, kern, q[0], q[1], q[2])
		_wings(e, w, psf, p, kern.r, q[0], q[1], q[2])
	var stars: Array
	if req.has("stars"):
		stars = req.stars
	else:
		var radius: float = (half + float(kern.r)) * p * 1.4143
		stars = SkyField.catalogue(c, radius, float(req.year))
		stars.append_array(SkyField.faint(c, radius, lim + 1.5 if is_finite(lim) else 16.0))
	var drawn := 0
	for s: Array in stars:
		var d: DVec3 = s[0]
		var k := d.dot(c)
		if k <= 0.0: continue
		var behind := false
		for b: Dictionary in bodies:
			if (b.dir as DVec3).dot(d) > cos(float(b.radius)):
				behind = true
				break
		if behind: continue
		var sx: float = half - d.dot(east) / k / p
		var sy: float = half - d.dot(north) / k / p
		var sn: float = rate.call(float(s[1]))
		_stamp(e, w, kern, sx, sy, sn)
		_wings(e, w, psf, p, kern.r, sx, sy, sn)
		drawn += 1
	var clean := e[(w / 2) * w + w / 2]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(req.get("seed", 1))
	var saturated := 0
	var peak := 0.0
	var back := sky_e + dark_e
	var overflow := false
	for i in e.size():
		var v := poisson(rng, e[i] + back) + rng.randfn(0.0, read)
		if v >= full:
			saturated += 1
			overflow = true
		e[i] = v
	if overflow: _bleed(e, w, full)
	for i in e.size():
		if e[i] > peak: peak = e[i]
	var out := {
		"kind": "optical", "e": e, "w": w, "pixel": pixel, "field": pixel * w, "fwhm": fwhm / AS, "sky_e": sky_e,
		"dark_e": dark_e, "read": read, "full": full, "saturated": saturated, "peak": peak, "limit": lim,
		"transmission": t, "nd": req.get("nd", 0.0), "sky_v": req.sky_v, "sky_full": sky_e + dark_e >= full, "x": x, "exposure": texp, "stars": drawn, "seeing": req.seeing,
		"instrument": row.name, "target": req.get("target_name", ""), "stamp": req.get("stamp", ""), "resolved": resolved,
	}
	var tv: float = req.get("target_v", NAN)
	if is_finite(tv):
		var n: float = rate.call(tv)
		out.target_v = tv
		out.target_e = n * ee
		out.snr = snr(n * ee, npix, sky_e, dark_e, read)
		out.target_saturated = n * float((kern.rmax as PackedFloat32Array)[0]) + back >= full
	# A resolved body has no one aperture: the frame's centre pixel says how well it is exposed.
	if bool(req.get("extended", false)):
		out.snr = snr(clean, 1.0, sky_e, dark_e, read)
		out.extended = true
		out.target_saturated = clean + back >= full
	return out

## Map the beam across the sky: sources and thermal bodies in Jy, confusion fixed to the sky,
## radiometer noise per pointing. `exposure` is the integration at each one.
static func _expose_radio(req: Dictionary) -> Dictionary:
	var row: Dictionary = req.row
	var bin: int = req.get("bin", 1)
	var w: int = mini(int(req.get("w", 128)), 128)
	var pixel: float = float(row.pixel) * bin
	var p := pixel * AS
	var c: DVec3 = req.centre
	var axes := sky_axes(c)
	var east: DVec3 = axes[0]
	var north: DVec3 = axes[1]
	var half := w * 0.5
	var beam := Telescopes.beam_fwhm(row)
	var sigma := beam / 2.3548 / p
	# _blur keeps the integral; dividing by this makes the beam's peak 1, so a delta of S Jy
	# reads S Jy/beam at its centre.
	var norm := 1.0 / (TAU * sigma * sigma)
	var map := PackedFloat32Array()
	map.resize(w * w)
	var add := func(d: DVec3, jy: float) -> void:
		var k := d.dot(c)
		if k <= 0.0: return
		var cx := half - d.dot(east) / k / p
		var cy := half - d.dot(north) / k / p
		var i := floori(cx); var j := floori(cy)
		if i >= 0 and j >= 0 and i < w and j < w: map[j * w + i] += jy
	var flux_at_centre := 0.0
	for s: Dictionary in Telescopes.RADIO.values():
		var d := EarthFrame.radec_vec(deg_to_rad(float(s.ra)), deg_to_rad(float(s.dec)))
		var jy := Telescopes.radio_jy(s, float(row.freq), float(req.year))
		add.call(d, jy)
		if d.dot(c) > cos(beam * 0.5): flux_at_centre += jy
	for b: Dictionary in req.get("bodies", []):
		var r: float = b.radius
		var d: DVec3 = b.dir
		var jy: float = b.jy
		if r / p < 0.7:
			add.call(d, jy)
		else:
			# A uniform disc, as its thermal emission nearly is at this wavelength.
			var k := d.dot(c)
			if k > 0.0:
				var cx := half - d.dot(east) / k / p
				var cy := half - d.dot(north) / k / p
				var xr := r / p
				var per := jy / (PI * xr * xr)
				for j in range(clampi(int(cy - xr), 0, w), clampi(int(cy + xr) + 1, 0, w)):
					for i in range(clampi(int(cx - xr), 0, w), clampi(int(cx + xr) + 1, 0, w)):
						if pow(i + 0.5 - cx, 2.0) + pow(j + 0.5 - cy, 2.0) < xr * xr: map[j * w + i] += per
		if d.dot(c) > cos(beam * 0.5): flux_at_centre += jy
	_blur(map, w, sigma)
	var conf := Telescopes.confusion_jy(row)
	var rms := Telescopes.radiometer_jy(row, float(req.exposure), flux_at_centre)
	# Each noise field is white, then smoothed by the beam and rescaled to its rms.
	var q := 1.0 / sqrt(4.0 * PI * sigma * sigma)
	var conf_rng := RandomNumberGenerator.new()
	var cell := deg_to_rad(5.0)
	conf_rng.seed = hash([roundi(c.x / cell), roundi(c.y / cell), roundi(c.z / cell), bin])
	var noise_rng := RandomNumberGenerator.new()
	noise_rng.seed = int(req.get("seed", 1))
	var cf := PackedFloat32Array(); cf.resize(w * w)
	var nf := PackedFloat32Array(); nf.resize(w * w)
	for i in w * w:
		cf[i] = conf_rng.randfn(0.0, 1.0)
		nf[i] = noise_rng.randfn(0.0, 1.0)
	_blur(cf, w, sigma)
	_blur(nf, w, sigma)
	var peak := -INF
	for i in w * w:
		var v := map[i] / norm + conf * cf[i] / q + rms * nf[i] / q
		map[i] = v
		if v > peak: peak = v
	var total := sqrt(conf * conf + rms * rms)
	var out := {
		"kind": "radio", "e": map, "w": w, "pixel": pixel, "field": pixel * w, "fwhm": beam / AS, "sigma": total, "rms": rms,
		"confusion": conf, "peak": peak, "limit_jy": 5.0 * total, "exposure": req.exposure, "x": req.x,
		"instrument": row.name, "target": req.get("target_name", ""), "stamp": req.get("stamp", ""), "centre_jy": flux_at_centre,
		"snr": flux_at_centre / total,
	}
	return out

## An RGB8 image of a frame: asinh stretch from just under the background to the peak. The
## radio map has its own ramp, since its values are Jy and not light.
static func to_image(r: Dictionary) -> Image:
	var e: PackedFloat32Array = r.e
	var w: int = r.w
	var sample := PackedFloat32Array()
	var n := e.size()
	var step := maxi(n / 4096, 1)
	for i in range(0, n, step): sample.append(e[i])
	sample.sort()
	var med := sample[sample.size() / 2]
	var lo_q := sample[sample.size() / 6]
	var sd := maxf(med - lo_q, 1e-6)
	var hi: float = maxf(float(r.peak), med + sd)
	var radio: bool = r.kind == "radio"
	var lo := med - 1.5 * sd
	var soft := 3.0 * sd
	if r.get("resolved", false):
		# A disc's own contrast decides, so nearly linear from the sky to its bright end.
		lo = float(r.sky_e) + float(r.dark_e)
		hi = maxf(sample[int((sample.size() - 1) * 0.999)], lo + 1.0)
		soft = (hi - lo) * 2.0
	var range_a := asinh((hi - lo) / soft)
	var data := PackedByteArray()
	data.resize(n * 3)
	for i in n:
		var v := clampf(asinh(maxf(e[i] - lo, 0.0) / soft) / range_a, 0.0, 1.0)
		if radio:
			data[i * 3] = int(255.0 * minf(v * 1.6, 1.0))
			data[i * 3 + 1] = int(255.0 * clampf(v * 1.6 - 0.45, 0.0, 1.0))
			data[i * 3 + 2] = int(255.0 * clampf(0.35 * sin(v * PI) + maxf(v * 2.0 - 1.4, 0.0), 0.0, 1.0))
		else:
			var g := int(255.0 * v)
			data[i * 3] = g
			data[i * 3 + 1] = g
			data[i * 3 + 2] = g
	return Image.create_from_data(w, w, false, Image.FORMAT_RGB8, data)
