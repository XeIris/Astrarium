extends SceneTree

# The simulated instruments (sim/observatory/imager.gd, docs/physics/instruments.md):
#   Godot --headless --path . --script res://tools/imagingcheck.gd
# Diffraction against the Airy pattern in pixels, seeing against 0.98 λ/r0, the annular OTF
# against the pupil's autocorrelation, SNR against the CCD equation by Monte Carlo, noise
# statistics, saturation, zero points against published throughput, the sky models, radio
# fluxes and the radiometer equation, and which limb of the Moon is which.

const AS := PI / 648000.0

var checks := 0
var failures := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("IMAGINGCHECK FAIL ", what)

func near(a: float, b: float, tol: float, what: String) -> void:
	check(absf(a - b) <= tol, "%s: %s against %s ± %s" % [what, a, b, tol])

func _init() -> void:
	bessel()
	otf()
	airy()
	seeing()
	zero_points()
	flux()
	noise()
	ccd_equation()
	saturation()
	limits()
	air()
	stars()
	discs()
	radio()
	reach()
	determinism()
	print("IMAGINGCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

## A dark-sky exposure of one star at the frame's centre, on a test row.
func one_star(row: Dictionary, v: float, texp: float, seeing_as: float, w := 64, seed_v := 1, sky_v := 40.0) -> Dictionary:
	return Imager.expose({"row": row, "centre": DVec3.new(1.0, 0.0, 0.0), "x": 1.0, "k_v": 0.0, "sky_v": sky_v, "seeing": seeing_as,
		"exposure": texp, "w": w, "bin": 1, "seed": seed_v, "year": 2026.0, "tdb": EarthFrame.J2000,
		"stars": [[DVec3.new(1.0, 0.0, 0.0), v]], "target_v": v})

## J1 by its integral, for the Airy reference.
func j1(x: float) -> float:
	var s := 0.0
	var n := 400
	for i in n:
		var t := PI * (i + 0.5) / n
		s += cos(t - x * sin(t))
	return s / n

func bessel() -> void:
	near(Optics.j0(0.0), 1.0, 1e-6, "J0(0)")
	near(Optics.j0(2.404826), 0.0, 1e-5, "J0's first zero")
	near(Optics.j0(5.520078), 0.0, 1e-5, "J0's second zero")
	near(Optics.j0(10.0), -0.2459358, 1e-5, "J0(10)")

## The formula against a direct count of the overlap of two displaced annuli.
func otf() -> void:
	near(Optics.pupil_otf(0.0, 0.3), 1.0, 1e-9, "OTF at zero frequency")
	near(Optics.pupil_otf(1.0, 0.3), 0.0, 1e-9, "OTF at cutoff")
	near(Optics.pupil_otf(0.5, 0.0), 2.0 / PI * (acos(0.5) - 0.5 * sqrt(0.75)), 1e-9, "clear pupil's OTF")
	var n := 900
	var total := 0
	var eps := 0.3
	var count := {0.15: 0, 0.4: 0, 0.65: 0, 0.9: 0}
	for j in n:
		var y := -1.0 + (j + 0.5) * 2.0 / n
		for i in n:
			var x := -1.0 + (i + 0.5) * 2.0 / n
			var r2 := x * x + y * y
			if r2 > 1.0 or r2 < eps * eps: continue
			total += 1
			for v: float in count:
				# Displaced by v of the cutoff, which is the pupil's diameter.
				var q := pow(x - 2.0 * v, 2.0) + y * y
				if q <= 1.0 and q >= eps * eps: count[v] += 1
	for v: float in count:
		near(Optics.pupil_otf(v, eps), float(count[v]) / total, 0.004, "annular OTF at %.2f" % v)

## Diffraction with no air, measured from the frame's pixels: the first dark ring at 1.22 λ/D.
func airy() -> void:
	var row := Telescopes.INSTRUMENTS.fors2.duplicate()
	row.eps = 0.0
	row.pixel = 0.001
	row.read = 0.0
	row.dark = 0.0
	row.full = 1e30
	row.lambda = 550e-9
	var f := one_star(row, 0.0, 1000.0, 0.0, 80)
	var e: PackedFloat32Array = f.e
	var w: int = f.w
	var bins := PackedFloat64Array(); bins.resize(40)
	var hits := PackedInt32Array(); hits.resize(40)
	for j in w:
		for i in w:
			var b := int(sqrt(pow(i + 0.5 - w * 0.5, 2.0) + pow(j + 0.5 - w * 0.5, 2.0)))
			if b < 40:
				bins[b] += e[j * w + i]
				hits[b] += 1
	var first := -1.0
	for b in range(4, 38):
		var a := bins[b] / maxi(hits[b], 1)
		var lo := bins[b - 1] / maxi(hits[b - 1], 1)
		var hi := bins[b + 1] / maxi(hits[b + 1], 1)
		if a < lo and a < hi:
			first = b + 0.5 + 0.5 * (lo - hi) / (lo - 2.0 * a + hi)
			break
	var want: float = 1.21967 * 550e-9 / 8.2 / AS / 0.001
	print("IMAGINGCHECK Airy first null %.2f px, 1.22 λ/D = %.2f px" % [first, want])
	near(first, want, 0.6, "the first dark ring, in pixels")
	# The whole radial profile, not just its zero.
	var t := Optics.psf(8.2, 0.0, 550e-9, INF)
	for k: float in [1.0, 2.0, 5.0, 7.0156]:
		var x: float = k
		var theta := x * 550e-9 / (PI * 8.2)
		var airy_v: float = pow(2.0 * j1(x) / x, 2.0)
		near(Optics.psf_at(t, theta) / (t.p as PackedFloat64Array)[0], airy_v, 0.006, "Airy profile at x = %.2f" % x)
	near(Optics.first_null(t) * 8.2 / 550e-9, 1.21967, 0.02, "table's first null in λ/D")
	# An obstruction narrows the core: Keck's ε moves the null inward.
	var ring := Optics.psf(8.2, 0.5, 550e-9, INF)
	check(Optics.first_null(ring) < Optics.first_null(t), "a central obstruction draws the first null inward")
	near(float(t.fwhm) * 8.2 / 550e-9, 1.029, 0.01, "diffraction FWHM in λ/D")

func seeing() -> void:
	# D ≫ r0: the long-exposure limit, FWHM = 0.98 λ/r0, at each aperture and wavelength.
	for c: Array in [[10.0, 0.15, 500e-9], [8.2, 0.10, 550e-9], [8.2, 0.20, 800e-9]]:
		var t := Optics.psf(c[0], 0.14, c[2], c[1])
		var want: float = 0.98 * c[2] / c[1]
		print("IMAGINGCHECK seeing D=%.1f r0=%.2f: FWHM %.3f″, 0.98 λ/r0 = %.3f″" % [c[0], c[1], t.fwhm / AS, want / AS])
		near(t.fwhm / want, 1.0, 0.025, "seeing FWHM")
	near(Optics.r0_of(1.0 * AS, 500e-9, 1.0), 0.98 * 500e-9 / AS, 1e-9, "r0 from seeing")
	near(Optics.r0_of(1.0 * AS, 1000e-9, 1.0) / Optics.r0_of(1.0 * AS, 500e-9, 1.0), pow(2.0, 1.2), 1e-9, "r0 ∝ λ^(6/5)")
	near(Optics.r0_of(1.0 * AS, 500e-9, 2.0) / Optics.r0_of(1.0 * AS, 500e-9, 1.0), pow(2.0, -0.6), 1e-9, "r0 ∝ X^(−3/5)")
	# The wings against a much finer integral of the same transfer functions: 2.8″ and 5.6″
	# here are 3.5 and 7 FWHM (2.19e-4 and 1.43e-5 of the peak, 4096 frequency samples).
	var wings := Optics.psf(8.2, 0.14, 555e-9, Optics.r0_of(0.7 * AS, 555e-9, 1.0))
	var peak: float = (wings.p as PackedFloat64Array)[0]
	near(Optics.psf_at(wings, 1.4 * AS) / peak, 3.62e-3, 2e-4, "the PSF at 2 FWHM")
	check(Optics.psf_at(wings, 2.8 * AS) / peak > 1.5e-4 and Optics.psf_at(wings, 2.8 * AS) / peak < 3.5e-4, "the wing at 3.5 FWHM")
	check(Optics.psf_at(wings, 5.5 * AS) / peak > 1.0e-5 and Optics.psf_at(wings, 5.5 * AS) / peak < 3.0e-5, "the wing at 7 FWHM")
	# A small telescope is diffraction-limited in the same seeing; a big one is not.
	var small := Optics.psf(0.05, 0.0, 550e-9, 0.15)
	near(small.fwhm * 0.05 / 550e-9, 1.029, 0.08, "a 5 cm aperture sees its Airy disc")
	# And the frame's own pixels show it.
	var row := Telescopes.INSTRUMENTS.deimos.duplicate()
	row.read = 0.0
	row.dark = 0.0
	row.full = 1e30
	var f := one_star(row, 5.0, 10.0, 0.8, 64)
	near(measured_fwhm(f), f.fwhm, 0.08, "the frame's FWHM (″)")
	near(f.fwhm, 0.8 * pow(550.0 / 500.0, -0.2), 0.04, "FWHM at V through 0.8″ of seeing at 500 nm")

## The FWHM of the frame's central star (″) from where its radial profile crosses half.
func measured_fwhm(f: Dictionary) -> float:
	var e: PackedFloat32Array = f.e
	var w: int = f.w
	var bins := PackedFloat64Array(); bins.resize(w)
	var hits := PackedInt32Array(); hits.resize(w)
	for j in w:
		for i in w:
			var b := int(sqrt(pow(i + 0.5 - w * 0.5, 2.0) + pow(j + 0.5 - w * 0.5, 2.0)))
			bins[b] += e[j * w + i]
			hits[b] += 1
	var c := 0.0
	var peak := bins[0] / maxi(hits[0], 1)
	for j in w:
		for i in w:
			var r := sqrt(pow(i + 0.5 - w * 0.5, 2.0) + pow(j + 0.5 - w * 0.5, 2.0))
			if r < 1.0: c = maxf(c, e[j * w + i])
	peak = c
	for b in range(1, w):
		var a := bins[b] / maxi(hits[b], 1)
		if a < peak * 0.5:
			var a0 := bins[b - 1] / maxi(hits[b - 1], 1)
			var fb := (a0 - peak * 0.5) / maxf(a0 - a, 1e-9)
			return 2.0 * (float(b) - 0.5 + fb + 0.0) * float(f.pixel)
	return NAN

func zero_points() -> void:
	# Keck's DEIMOS page: 800 e⁻/s in V at V = 21.
	var d := Telescopes.electrons_per_s(Telescopes.INSTRUMENTS.deimos, 21.0)
	print("IMAGINGCHECK DEIMOS %.0f e⁻/s at V = 21 (Keck: 800)" % d)
	near(d, 800.0, 40.0, "DEIMOS's published rate")
	var zp := Telescopes.zero_point(Telescopes.INSTRUMENTS.fors2)
	print("IMAGINGCHECK FORS2 zero point %.2f above the air" % zp)
	near(zp - 0.12, 28.2, 0.2, "FORS2's V zero point at airmass 1")
	near(Telescopes.electrons_per_s(Telescopes.INSTRUMENTS.fors2, 10.0) / Telescopes.electrons_per_s(Telescopes.INSTRUMENTS.fors2, 15.0), 100.0, 1e-6, "5 mag is a factor of 100")
	for k: String in Telescopes.ORDER:
		var row: Dictionary = Telescopes.INSTRUMENTS[k]
		check(Facilities.DATA.has(row.site), "%s stands at a modelled site" % k)
		check(int(row.part) < (Facilities.DATA[row.site].parts as Array).size(), "%s names a part of its site" % k)
	check(Telescopes.at_site("paranal") == ["fors2", "omegacam"], "Paranal's instruments")
	check(Telescopes.at_site("custom").is_empty(), "no instrument at a custom site")

## Every electron is on the frame: a star's total against the rate, air included.
func flux() -> void:
	var row := Telescopes.INSTRUMENTS.fors2.duplicate()
	row.read = 0.0
	row.dark = 0.0
	row.full = 1e30
	var f := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.5, "k_v": 0.12, "sky_v": 40.0, "seeing": 0.7,
		"exposure": 100.0, "w": 96, "bin": 1, "seed": 3, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": [[DVec3.new(1, 0, 0), 12.0]]})
	var s := 0.0
	for v: float in f.e: s += v
	var want := Telescopes.electrons_per_s(row, 12.0) * 100.0 * pow(10.0, -0.4 * 0.12 * 1.5)
	near(s / want, 1.0, 0.01, "a star's electrons on the frame")
	near(float(f.transmission), pow(10.0, -0.4 * 0.18), 1e-9, "the air's transmission")
	# Binning keeps a star's light and widens its pixel.
	var g := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.5, "k_v": 0.12, "sky_v": 40.0, "seeing": 0.7,
		"exposure": 100.0, "w": 48, "bin": 2, "seed": 4, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": [[DVec3.new(1, 0, 0), 12.0]]})
	var s2 := 0.0
	for v: float in g.e: s2 += v
	near(s2 / want, 1.0, 0.01, "a binned star's electrons")
	near(float(g.pixel), 0.5, 1e-9, "a binned pixel")

func noise() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for mean: float in [0.5, 5.0, 25.0, 50.0, 2000.0]:
		var s := 0.0
		var q := 0.0
		var n := 40000
		for i in n:
			var k := Imager.poisson(rng, mean)
			s += k
			q += k * k
		var m := s / n
		near(m, mean, 4.0 * sqrt(mean / n) + 0.5 if mean > 30.0 else 4.0 * sqrt(mean / n), "Poisson mean at %s" % mean)
		near((q / n - m * m) / mean, 1.0, 0.05, "Poisson variance at %s" % mean)
	# A blank frame: mean = sky + dark, variance = sky + dark + read².
	var row: Dictionary = Telescopes.INSTRUMENTS.fors2
	var f := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.1, "sky_v": 21.6, "seeing": 0.7, "exposure": 60.0,
		"w": 128, "bin": 1, "seed": 21, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": []})
	var e: PackedFloat32Array = f.e
	var s := 0.0
	var q := 0.0
	for v in e:
		s += v
		q += v * v
	var mean := s / e.size()
	var back: float = float(f.sky_e) + float(f.dark_e)
	print("IMAGINGCHECK blank frame: mean %.2f, expected %.2f; variance %.2f, expected %.2f" % [mean, back, q / e.size() - mean * mean, back + pow(float(f.read), 2.0)])
	near(mean, back, 4.0 * sqrt((back + 8.0) / e.size()), "a blank frame's mean")
	near((q / e.size() - mean * mean) / (back + pow(float(f.read), 2.0)), 1.0, 0.03, "a blank frame's variance")
	# Binned read noise adds per physical pixel.
	var b := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.1, "sky_v": 40.0, "seeing": 0.7, "exposure": 0.001,
		"w": 96, "bin": 4, "seed": 22, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": []})
	near(float(b.read), 2.7 * 4.0, 1e-6, "binned read noise")

## The reported SNR against the scatter of many frames: the CCD equation's whole point.
func ccd_equation() -> void:
	for c: Array in [["fors2", 22.0, 60.0, 21.6], ["deimos", 24.0, 30.0, 21.9], ["omegacam", 19.0, 10.0, 21.6], ["fors2", 26.0, 300.0, 21.6]]:
		var row: Dictionary = Telescopes.INSTRUMENTS[c[0]]
		var mkreq := func(sd: int) -> Dictionary:
			return {"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.2, "k_v": 0.12, "sky_v": c[3], "seeing": 0.7, "exposure": c[2], "w": 32,
				"bin": 1, "seed": sd, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": [[DVec3.new(1, 0, 0), c[1]]], "target_v": c[1]}
		var r0 := Imager.expose(mkreq.call(1))
		var r_px: float = float(r0.fwhm) / float(r0.pixel)
		# The mask's own pixel count and captured share, so a discrete aperture is compared fairly.
		var mask := []
		for j in 32:
			for i in 32:
				if pow(i + 0.5 - 16.0, 2.0) + pow(j + 0.5 - 16.0, 2.0) <= r_px * r_px: mask.append(j * 32 + i)
		var back: float = float(r0.sky_e) + float(r0.dark_e)
		var runs := 400
		var s := 0.0
		var q := 0.0
		for k in runs:
			var e: PackedFloat32Array = Imager.expose(mkreq.call(100 + k)).e
			var a := 0.0
			for m: int in mask: a += e[m] - back
			s += a
			q += a * a
		var m := s / runs
		var sd := sqrt(q / runs - m * m)
		var want := Imager.snr(m, mask.size(), float(r0.sky_e), float(r0.dark_e), float(r0.read))
		print("IMAGINGCHECK %s V=%.0f %.0fs: measured SNR %.1f, CCD equation %.1f (reported in the panel %.1f)" % [c[0], c[1], c[2], m / sd, want, r0.snr])
		near((m / sd) / want, 1.0, 0.12, "SNR against the CCD equation, %s" % c[0])
		near(float(r0.snr) / want, 1.0, 0.12, "the panel's SNR, %s" % c[0])

func saturation() -> void:
	var row: Dictionary = Telescopes.INSTRUMENTS.fors2
	var f := one_star(row, 8.0, 60.0, 0.7, 48)
	var hi := 0.0
	for v: float in f.e: hi = maxf(hi, v)
	check(int(f.saturated) > 0, "a V = 8 star saturates FORS2 in a minute")
	near(hi, float(row.full), 0.0, "nothing exceeds the full well")
	check(bool(f.target_saturated), "the target's saturation is reported")
	var g := one_star(row, 20.0, 60.0, 0.7, 48)
	check(int(g.saturated) == 0 and not bool(g.target_saturated), "a V = 20 star does not saturate")
	# An overfull well bleeds along its column, not across rows.
	var bright := one_star(row, 6.0, 60.0, 0.7, 96)
	var be: PackedFloat32Array = bright.e
	var col := 0
	var across := 0
	for j in 96:
		if be[j * 96 + 48] >= float(row.full): col += 1
		if be[48 * 96 + j] >= float(row.full): across += 1
	check(col == 96 and across < 96 and across > 0, "a bright star bleeds down its column: %d along, %d across" % [col, across])
	# Its halo reaches past the PSF table, falling as Kolmogorov's tail.
	var dim := row.duplicate()
	dim.full = 1e30
	dim.read = 0.0
	dim.dark = 0.0
	var halo := Imager.expose({"row": dim, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.0, "sky_v": 40.0, "seeing": 0.7, "exposure": 60.0, "w": 256, "bin": 1, "seed": 1,
		"year": 2026.0, "tdb": EarthFrame.J2000, "stars": [[DVec3.new(1, 0, 0), -1.0]]})
	var he: PackedFloat32Array = halo.e
	var a1 := he[128 * 256 + 128 + 40]
	var a2 := he[128 * 256 + 128 + 80]
	near(a1 / a2, pow(2.0, 11.0 / 3.0), 1.0, "the wings fall as θ^(−11/3)")
	# A sky over the well has no limit to report.
	var over := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.1, "sky_v": 21.6, "seeing": 0.7, "exposure": 3600.0, "w": 16, "bin": 1, "seed": 1,
		"year": 2026.0, "tdb": EarthFrame.J2000, "stars": []})
	check(bool(over.sky_full) and is_nan(float(over.limit)), "a saturated sky reports no limit")
	# A binned pixel holds the well of each of its pixels.
	near(float(Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.1, "sky_v": 40.0, "seeing": 0.7, "exposure": 0.001,
		"w": 16, "bin": 2, "seed": 1, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": []}).full), float(row.full) * 4.0, 1e-3, "a binned full well")

func limits() -> void:
	var row: Dictionary = Telescopes.INSTRUMENTS.fors2
	var f := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.12, "sky_v": 21.6, "seeing": 0.7, "exposure": 1200.0,
		"w": 32, "bin": 1, "seed": 5, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": [], "target_v": NAN})
	print("IMAGINGCHECK FORS2 twenty minutes, dark, 0.7″: V limit %.2f at SNR 5" % f.limit)
	check(f.limit > 26.0 and f.limit < 28.0, "an 8 m's twenty minutes reach V ≈ 27: %s" % f.limit)
	var at := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.12, "sky_v": 21.6, "seeing": 0.7, "exposure": 1200.0,
		"w": 32, "bin": 1, "seed": 5, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": [], "target_v": f.limit})
	near(at.snr, 5.0, 1e-3, "a star at the limit has SNR 5")
	# Sky-limited: a quarter of the exposure, 0.75 mag shallower.
	var a4 := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.12, "sky_v": 21.6, "seeing": 0.7, "exposure": 300.0,
		"w": 32, "bin": 1, "seed": 5, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": [], "target_v": NAN})
	near(f.limit - a4.limit, 0.753, 0.03, "a quarter of the exposure in a sky-limited frame")
	# A bigger mirror and a smaller one on one sky.
	var v := Imager.expose({"row": Telescopes.INSTRUMENTS.omegacam, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.12, "sky_v": 21.6, "seeing": 0.7, "exposure": 1200.0,
		"w": 32, "bin": 1, "seed": 5, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": [], "target_v": NAN})
	check(f.limit > v.limit + 1.0, "the 8.2 m goes deeper than the 2.6 m: %s against %s" % [f.limit, v.limit])
	# Better seeing goes deeper.
	var poor := Imager.expose({"row": row, "centre": DVec3.new(1, 0, 0), "x": 1.0, "k_v": 0.12, "sky_v": 21.6, "seeing": 1.4, "exposure": 1200.0,
		"w": 32, "bin": 1, "seed": 5, "year": 2026.0, "tdb": EarthFrame.J2000, "stars": [], "target_v": NAN})
	check(f.limit > poor.limit + 0.4, "better seeing goes deeper")

func air() -> void:
	near(SkyConditions.airmass(90.0), 1.0, 1e-3, "airmass at the zenith")
	near(SkyConditions.airmass(30.0), 1.9943, 0.005, "airmass at 30°")
	near(SkyConditions.airmass(0.0), 38.0, 0.5, "airmass at the horizon")
	near(SkyConditions.transmission(0.12, 1.0), 0.8954, 1e-3, "V extinction")
	near(SkyConditions.v_of_nl(SkyConditions.nl_of_v(21.0)), 21.0, 1e-9, "surface brightness both ways")
	# The photometric scale, from outside Krisciunas & Schaefer: Crumey (2014, MNRAS 442, 2600,
	# §1.3) has μ_V = 2.5 log(60⁴(180/π)² Z_V / B) with Z_V = 2.54e-6 lx (Cox 1999), so 0 mag/arcsec²
	# is 1.0807e5 cd/m², and 22 is his 1.71e-4. 1 nL = 1e-5/π cd/m².
	var zero_mag := pow(60.0, 4.0) * pow(180.0 / PI, 2.0) * 2.54e-6
	near(zero_mag * pow(10.0, -0.4 * 22.0), 1.71e-4, 1e-6, "Crumey's zenith at 22 mag/arcsec²")
	near(SkyConditions.nl_of_v(22.0), zero_mag * pow(10.0, -0.4 * 22.0) / (1e-5 / PI), 0.3, "the nL scale at 22 mag/arcsec²")
	var c: Dictionary = SkyConditions.SITES.paranal
	var dark := SkyConditions.sky_v(c, 90.0, -40.0, 0.0, 90.0, -30.0)
	near(dark, 21.61, 1e-3, "Paranal's dark zenith")
	check(SkyConditions.sky_v(c, 30.0, -40.0, 0.0, 90.0, -30.0) < dark, "the sky brightens toward the horizon")
	var full := SkyConditions.sky_v(c, 60.0, -40.0, 0.0, 90.0, 45.0)
	var half := SkyConditions.sky_v(c, 60.0, -40.0, 90.0, 90.0, 45.0)
	var thin := SkyConditions.sky_v(c, 60.0, -40.0, 150.0, 90.0, 45.0)
	print("IMAGINGCHECK sky V with Moon at 90°: full %.2f, quarter %.2f, thin %.2f" % [full, half, thin])
	check(full > 17.0 and full < 19.5, "the full Moon's sky is ~18: %s" % full)
	check(full < half and half < thin and thin < dark, "the sky darkens as the Moon wanes")
	check(SkyConditions.sky_v(c, 60.0, -40.0, 0.0, 15.0, 45.0) < full, "closer to the Moon is brighter")
	near(SkyConditions.moon_v(0.0, 0.00256955), -12.73, 1e-6, "the full Moon's V")
	near(SkyConditions.twilight_v(-5.0), 11.84, 1e-9, "twilight's fit at 95°")
	near(SkyConditions.twilight_v(-15.0), 21.32, 1e-9, "twilight's fit at 105°")
	check(not is_finite(SkyConditions.twilight_v(-30.0)), "no twilight after astronomical dark")
	var tw := SkyConditions.sky_v(c, 60.0, -8.0, 0.0, 90.0, -30.0)
	check(tw < 18.0, "the sky at −8° is bright: %s" % tw)
	check(SkyConditions.sky_v(c, 60.0, 30.0, 0.0, 90.0, -30.0) < 6.0, "a day's sky is far too bright")
	near(SkyConditions.twilight_exposure(45.0), 1.0, 1e-9, "the day's sky keeps its exposure")
	near(SkyConditions.twilight_exposure(-40.0), SkyConditions.EXPOSURE_MAX, 1e-9, "the night's holds its cap")
	var last := 1.0
	var rising := true
	for alt in [10.0, 5.0, 1.0, -1.0, -3.0, -6.0, -9.0, -12.0, -18.0]:
		var e := SkyConditions.twilight_exposure(alt)
		rising = rising and e >= last
		last = e
	check(rising, "the exposure only opens as the Sun sinks")
	near(SkyConditions.star_gain(c, -40.0), 1.0, 1e-9, "the stars at full flux after dark")
	near(SkyConditions.star_gain(c, 40.0), SkyConditions.DAY_STAR_GAIN, 1e-9, "and at the flight view's gain by day")
	var civil := SkyConditions.star_gain(c, -6.0)
	check(civil > 0.01 and civil < 0.05, "the Sun at −6° leaves only the brightest stars: %.3f" % civil)

func stars() -> void:
	var y := 2026.0
	for n: String in Telescopes.STARS:
		var at: Array = Telescopes.STARS[n]
		var d := EarthFrame.radec_vec(deg_to_rad(float(at[0])), deg_to_rad(float(at[1])))
		var hits := SkyField.catalogue(d, deg_to_rad(0.1), y)
		var best := 99.0
		for h: Array in hits: best = minf(best, float(h[1]))
		check(best < 2.2, "%s lies on a bright catalogue star (V %s)" % [n, best])
	# Sirius, carried by its proper motion, at the frame's centre.
	var sirius := Telescopes.STARS.Sirius as Array
	var s0 := EarthFrame.radec_vec(deg_to_rad(float(sirius[0])), deg_to_rad(float(sirius[1])))
	var near_s := SkyField.catalogue(s0, deg_to_rad(0.1), 2000.0)
	var near_y := SkyField.catalogue(s0, deg_to_rad(0.1), y)
	check(near_s.size() > 0 and near_s.size() == near_y.size(), "Sirius is in the catalogue")
	var moved: float = rad_to_deg(acos(clampf((near_s[0][0] as DVec3).dot(near_y[0][0]), -1.0, 1.0))) * 3600.0
	near(moved, 1.339 * 26.0, 1.0, "Sirius's proper motion over 26 years (″)")
	# The faint field: fixed to the sky, deeper only adds, and at the expected density.
	var c := EarthFrame.radec_vec(deg_to_rad(120.0), deg_to_rad(40.0))
	var r := deg_to_rad(0.5)
	var a := SkyField.faint(c, r, 18.0, 1 << 20)
	var b := SkyField.faint(c, r, 18.0, 1 << 20)
	check(a.size() == b.size() and a.size() > 0 and (a[0][0] as DVec3).dot(b[0][0]) > 1.0 - 1e-14, "the faint field repeats")
	var deep := SkyField.faint(c, r, 19.0, 1 << 20)
	check(deep.size() > a.size(), "a deeper field holds more stars")
	var lat := SkyField.galactic_lat(c)
	var area: float = PI * 0.25
	var want := (SkyField.density(18.0, lat) - SkyField.density(8.0, lat)) * area
	print("IMAGINGCHECK faint field to V=18 at b=%.0f°: %d stars, expected %.0f" % [rad_to_deg(lat), a.size(), want])
	near(float(a.size()) / want, 1.0, 0.12, "the faint field's count")
	# A rank the catalogues already hold must not pile up at the boundary as a modelled star.
	var v_min := INF
	for s: Array in a: v_min = minf(v_min, s[1])
	check(v_min > 8.0, "the faint field stays below the catalogues: its brightest is V %s" % v_min)
	near(rad_to_deg(SkyField.galactic_lat(EarthFrame.radec_vec(deg_to_rad(266.405), deg_to_rad(-28.936)))), 0.0, 0.1, "the galactic centre's latitude")
	var v_max := 0.0
	for s: Array in a: v_max = maxf(v_max, s[1])
	check(v_max <= 18.0, "nothing past the requested depth")

## The real Moon on 2026-11-05 from Paranal, and which way it faces.
func discs() -> void:
	var jd := Observatory.julian_day(2026, 11, 5) + 8.5 / 24.0
	var tt := EarthFrame.tt_of_civil(jd)
	var tdb := EarthFrame.tdb_of_tt(tt)
	var at := Observatory.solar_state(tt)
	var earth: DVec3 = at.Earth[0]
	var rel := func(n: String) -> DVec3: return EarthFrame.from_scene((at[n][0] as DVec3).sub(earth))
	var mv: DVec3 = rel.call("Moon")
	var d := mv.normalized()
	var axes := Imager.sky_axes(d)
	var east: DVec3 = axes[0]
	var north: DVec3 = axes[1]
	check(east.cross(north).dot(d) > 0.99, "east × north points along the view, so east is on the left")
	var ax := PlanetDisc.axes("Moon", tdb)
	# Mare Crisium, 59° E: the Moon's own east limb, which is west on the sky.
	var cris := PlanetDisc.surface(ax, deg_to_rad(17.0), deg_to_rad(59.0))
	check(cris.dot(d.scaled(-1.0)) > 0.3, "Crisium faces us")
	check(cris.dot(east) < -0.5, "Crisium is on the Moon's sky-west side: %s" % cris.dot(east))
	# The near side faces us: sub-Earth point within the libration range.
	var sub := d.scaled(-1.0)
	var lat := asin(sub.dot(ax[2]))
	var lon := atan2(sub.dot(ax[1]), sub.dot(ax[0]))
	print("IMAGINGCHECK Moon's libration on 2026-11-05: %.2f° lat, %.2f° lon" % [rad_to_deg(lat), rad_to_deg(lon)])
	check(absf(rad_to_deg(lat)) < 7.5 and absf(rad_to_deg(lon)) < 8.5, "the sub-Earth point lies within the librations")
	# And the map agrees: the sea is dark against its surroundings.
	var map := PlanetDisc._map("Moon")
	check(not map.is_empty(), "the Moon's map loads headless")
	var sea := PlanetDisc.albedo(map, deg_to_rad(17.0), deg_to_rad(59.0))
	var land := 0.0
	for k in 8:
		var a := k * TAU / 8.0
		land += PlanetDisc.albedo(map, deg_to_rad(17.0 + 16.0 * sin(a)), deg_to_rad(59.0 + 18.0 * cos(a))) / 8.0
	check(sea < land * 0.7, "the map's 59° E 17° N is Crisium: %s against %s" % [sea, land])
	check(PlanetDisc.albedo(map, deg_to_rad(-43.3), deg_to_rad(-11.4)) > PlanetDisc.albedo(map, deg_to_rad(10.0), deg_to_rad(-20.0)), "Tycho's highlands are brighter than the Imbrium–Procellarum maria")
	# The waning crescent: lit on the Sun's side, east of the Moon, and the right fraction.
	var sun: DVec3 = rel.call("Sun")
	var to_sun := sun.sub(mv).normalized()
	var o := mv.scaled(-1.0).normalized()
	var w := 256
	var e := PackedFloat32Array()
	e.resize(w * w)
	var radius := 1737.4e3 / Rocketry.AU_M / mv.length()
	var p := radius / 100.0
	PlanetDisc.paint(e, w, 128.0, 128.0, p, "Moon", radius, 1e6, o, to_sun, east, north, tdb)
	var left := 0.0
	var right := 0.0
	var lit := 0
	var disc := 0
	for j in w:
		for i in w:
			var v := e[j * w + i]
			if pow(i + 0.5 - 128.0, 2.0) + pow(j + 0.5 - 128.0, 2.0) < 10000.0:
				disc += 1
				if v > 0.0: lit += 1
			if i < 128: left += v
			else: right += v
	near((left + right) / 1e6, 1.0, 0.03, "the disc holds its light")
	check(sun.normalized().dot(east) > 0.0 and left > right * 3.0, "a waning Moon is lit on its east limb, on the left")
	var alpha := acos(to_sun.dot(o))
	near(float(lit) / disc, (1.0 + cos(alpha)) * 0.5, 0.02, "the lit fraction")
	print("IMAGINGCHECK Moon 2026-11-05: phase angle %.1f°, lit %.1f%%, V %.2f" % [rad_to_deg(alpha), 100.0 * lit / disc, SkyConditions.moon_v(rad_to_deg(alpha), mv.length())])
	# A planet at the plate scale: its disc's width in pixels, and a star in front of nothing.
	var row: Dictionary = Telescopes.INSTRUMENTS.fors2.duplicate()
	row.full = 1e30
	var jv: DVec3 = rel.call("Jupiter")
	var jdir := jv.normalized()
	var jr := 69911e3 / Rocketry.AU_M / jv.length()
	var jo := jv.scaled(-1.0).normalized()
	var js := sun.sub(jv).normalized()
	var f := Imager.expose({"row": row, "centre": jdir, "x": 1.1, "k_v": 0.12, "sky_v": 21.6, "seeing": 0.7, "exposure": 0.001, "w": 256, "bin": 1,
		"seed": 9, "year": 2026.8, "tdb": tdb, "stars": [[jdir, 3.0]], "extended": true, "target_v": NAN,
		"bodies": [{"name": "Jupiter", "dir": jdir, "radius": jr, "v": -2.4, "o": jo, "to_sun": js, "jy": 1.0}]})
	var fe: PackedFloat32Array = f.e
	var edge0 := -1
	var edge1 := -1
	for i in 256:
		if fe[128 * 256 + i] > fe[128 * 256 + 128] * 0.25:
			if edge0 < 0: edge0 = i
			edge1 = i
	near(float(edge1 - edge0 + 1) * 0.25 / (2.0 * jr / AS), 1.0, 0.05, "Jupiter's width in pixels")
	# Its own V, whatever its map, comes out in the frame's total above the sky.
	var total := 0.0
	var back: float = float(f.sky_e) + float(f.dark_e)
	for v: float in fe: total += v - back
	var expect := Telescopes.electrons_per_s(row, -2.4) * 0.001 * float(f.transmission)
	print("IMAGINGCHECK Jupiter: %.1f″ wide, %d e⁻ (wanted %d), peak %d, saturated %d" % [2.0 * jr / AS, total, expect, f.peak, f.saturated])
	near(total / expect, 1.0, 0.05, "Jupiter's light on the frame")
	check(float(f.snr) > 10.0, "a resolved disc reports its centre's SNR")
	# Through the real well it saturates, and a neutral-density filter brings it back.
	var mk_j := func(nd: float) -> Dictionary:
		return Imager.expose({"row": Telescopes.INSTRUMENTS.fors2, "centre": jdir, "x": 1.1, "k_v": 0.12, "sky_v": 21.6, "seeing": 0.7, "exposure": 0.001, "w": 256, "bin": 1, "nd": nd,
			"seed": 9, "year": 2026.8, "tdb": tdb, "stars": [], "extended": true, "target_v": NAN,
			"bodies": [{"name": "Jupiter", "dir": jdir, "radius": jr, "v": -2.4, "o": jo, "to_sun": js, "jy": 1.0}]})
	check(int(mk_j.call(0.0).saturated) > 1000, "Jupiter saturates an 8 m in a millisecond")
	check(int(mk_j.call(5.0).saturated) == 0, "5 mag of neutral density clears it")
	# Saturn's rings reach past its globe in the frame.
	var sv: DVec3 = rel.call("Saturn")
	var sdir := sv.normalized()
	var sr := 58232e3 / Rocketry.AU_M / sv.length()
	var sa := Imager.sky_axes(sdir)
	var se := PackedFloat32Array()
	se.resize(w * w)
	var sp := sr / 40.0
	PlanetDisc.paint(se, w, 128.0, 128.0, sp, "Saturn", sr, 1e6, sv.scaled(-1.0).normalized(), sun.sub(sv).normalized(), sa[0], sa[1], tdb)
	var beyond := 0.0
	var pole_o: float = (PlanetDisc.axes("Saturn", tdb)[2] as DVec3).dot(sv.scaled(-1.0).normalized())
	print("IMAGINGCHECK Saturn's rings open %.1f° on 2026-11-05" % rad_to_deg(asin(pole_o)))
	for j in w:
		for i in w:
			var r := sqrt(pow(i + 0.5 - 128.0, 2.0) + pow(j + 0.5 - 128.0, 2.0)) / 40.0
			if r > 1.3 and r < 2.2: beyond += se[j * w + i]
	check(beyond > 0.0, "Saturn's rings show past its globe")

func radio() -> void:
	var y := 2026.0
	var row: Dictionary = Telescopes.INSTRUMENTS.lovell_l
	# Baars et al. 1977 at 1.4 GHz.
	near(Telescopes.radio_jy(Telescopes.RADIO["Cyg A"], 1.4e9, y), 1590.0, 80.0, "Cyg A at 1.4 GHz")
	near(Telescopes.radio_jy(Telescopes.RADIO["Tau A"], 1.4e9, y), 930.0, 50.0, "Tau A at 1.4 GHz")
	near(Telescopes.radio_jy(Telescopes.RADIO["Vir A"], 1.4e9, y), 212.0, 15.0, "Vir A at 1.4 GHz")
	near(Telescopes.radio_jy(Telescopes.RADIO["Cas A"], 1.4e9, 1965.0), 2500.0, 150.0, "Cas A at 1.4 GHz in 1965")
	check(Telescopes.radio_jy(Telescopes.RADIO["Cas A"], 1.4e9, y) < Telescopes.radio_jy(Telescopes.RADIO["Cas A"], 1.4e9, 1965.0) * 0.7, "Cas A fades")
	var beam: float = Telescopes.beam_fwhm(row) / AS / 60.0
	print("IMAGINGCHECK Lovell L-band: beam %.1f′, confusion %.1f mJy, radiometer 1 s %.2f mJy" % [beam, Telescopes.confusion_jy(row) * 1e3, Telescopes.radiometer_jy(row, 1.0) * 1e3])
	near(beam, 10.8, 1.0, "the Lovell's beam at 21 cm")
	near(Telescopes.radiometer_jy(row, 1.0), 36.0 / sqrt(2.0 * 512e6), 1e-9, "the radiometer equation")
	near(Telescopes.radiometer_jy(row, 4.0) / Telescopes.radiometer_jy(row, 1.0), 0.5, 1e-9, "noise falls as √τ")
	near(Telescopes.body_jy("Moon", deg_to_rad(0.259), 0.00257, 1.5e9), 1000.0, 300.0, "the Moon's thermal flux at L band")
	near(Telescopes.body_jy("Jupiter", 1e-4, 4.04, 1.5e9), 4.8, 1e-6, "Jupiter's L-band flux at 4 AU")
	var src: Dictionary = Telescopes.RADIO["Cyg A"]
	var c := EarthFrame.radec_vec(deg_to_rad(float(src.ra)), deg_to_rad(float(src.dec)))
	var f := Imager.expose({"row": row, "centre": c, "x": 1.2, "exposure": 1.0, "w": 128, "bin": 1, "seed": 31, "year": y, "tdb": EarthFrame.J2000, "bodies": []})
	var e: PackedFloat32Array = f.e
	var w: int = f.w
	var hi := -INF
	var hi_at := 0
	for i in e.size():
		if e[i] > hi:
			hi = e[i]
			hi_at = i
	var want := Telescopes.radio_jy(src, row.freq, y)
	print("IMAGINGCHECK Cyg A map: peak %.0f Jy/beam (source %.0f Jy), SNR %.0f" % [hi, want, f.snr])
	near(hi / want, 1.0, 0.04, "a point source's peak in Jy/beam")
	near(float(hi_at % w), w * 0.5, 1.5, "Cyg A at the frame's centre, x")
	near(float(hi_at / w), w * 0.5, 1.5, "Cyg A at the frame's centre, y")
	check(float(f.snr) > 1000.0, "Cyg A is a strong source")
	# A blank patch with long integration: down to confusion, whose rms the frame reproduces.
	var blank := EarthFrame.radec_vec(deg_to_rad(40.0), deg_to_rad(60.0))
	var g := Imager.expose({"row": row, "centre": blank, "x": 1.2, "exposure": 3600.0, "w": 128, "bin": 1, "seed": 32, "year": y, "tdb": EarthFrame.J2000, "bodies": []})
	var s := 0.0
	var q := 0.0
	for v: float in g.e:
		s += v
		q += v * v
	var rms := sqrt(q / (g.e as PackedFloat32Array).size() - pow(s / (g.e as PackedFloat32Array).size(), 2.0))
	print("IMAGINGCHECK blank L-band map: rms %.1f mJy, expected %.1f" % [rms * 1e3, g.sigma * 1e3])
	near(rms / float(g.sigma), 1.0, 0.25, "a blank map's rms")
	check(float(g.limit_jy) < 0.2, "a long map's limit reaches confusion: %s" % g.limit_jy)
	# A star makes no signal: the map on Sirius has nothing at its centre above the noise.
	var sir := Telescopes.STARS.Sirius as Array
	var h := Imager.expose({"row": row, "centre": EarthFrame.radec_vec(deg_to_rad(float(sir[0])), deg_to_rad(float(sir[1]))), "x": 1.2, "exposure": 10.0, "w": 128, "bin": 1, "seed": 33, "year": y, "tdb": EarthFrame.J2000, "bodies": []})
	near(float(h.centre_jy), 0.0, 0.0, "no star in the radio table")
	# A body's disc: the Moon across its beam-widths, its centre at the thermal brightness.
	var m := Imager.expose({"row": row, "centre": blank, "x": 1.2, "exposure": 1.0, "w": 128, "bin": 1, "seed": 34, "year": y, "tdb": EarthFrame.J2000,
		"bodies": [{"name": "Moon", "dir": blank, "radius": deg_to_rad(0.259), "jy": 1e6}]})
	var ctr: float = (m.e as PackedFloat32Array)[64 * 128 + 64]
	# A 31′ disc through an 11′ beam: nearly flat on top, at disc flux × beam area / disc area.
	var ratio := pow(Telescopes.beam_fwhm(row), 2.0) * PI / (4.0 * log(2.0)) / (PI * pow(deg_to_rad(0.259), 2.0))
	near(ctr / (1e6 * ratio), 1.0, 0.1, "the Moon's Jy/beam at L band")

func reach() -> void:
	var la := deg_to_rad(ObservatorySites.SITES.paranal.lat)
	var lo := deg_to_rad(ObservatorySites.SITES.paranal.lon)
	var jd := Observatory.julian_day(2026, 11, 5)
	var tt := EarthFrame.tt_of_civil(jd)
	var site := EarthFrame.site(tt, la, lo, 2635.0)
	var sirius := Telescopes.STARS.Sirius as Array
	var d := EarthFrame.radec_vec(deg_to_rad(float(sirius[0])), deg_to_rad(float(sirius[1])))
	var rs := ObservatoryInstruments.rise_set(site, d, la, 20.0)
	check(rs.state == "both", "Sirius crosses 20° at Paranal")
	# The analytic times against the altitude read directly at those moments.
	for k: String in ["rise_h", "set_h"]:
		var s2 := EarthFrame.site(EarthFrame.tt_of_civil(jd + float(rs[k]) / 24.0), la, lo, 2635.0)
		near(rad_to_deg(EarthFrame.altitude(s2, d)), 20.0, 0.25, "Sirius's altitude at its %s" % k)
	# Circumpolar and never-up cases.
	var pole := EarthFrame.radec_vec(0.0, deg_to_rad(-85.0))
	check(ObservatoryInstruments.rise_set(site, pole, la, 0.0).state == "up", "a south polar star never sets at Paranal")
	var north := EarthFrame.radec_vec(0.0, deg_to_rad(85.0))
	check(ObservatoryInstruments.rise_set(site, north, la, 0.0).state == "down", "a north polar star never rises at Paranal")
	# The reasons a telescope refuses.
	var row: Dictionary = Telescopes.INSTRUMENTS.fors2
	var r := ObservatoryInstruments.reachable(row, 60.0, -30.0, 100.0)
	check(r.ok, "a high star at night is reachable")
	check(not ObservatoryInstruments.reachable(row, 10.0, -30.0, 100.0).ok, "under the mount's limit")
	check(not ObservatoryInstruments.reachable(row, 60.0, 5.0, 100.0).ok, "an optical telescope stays shut by day")
	check(not ObservatoryInstruments.reachable(row, 60.0, -30.0, 10.0).ok, "too near the Sun")
	check(ObservatoryInstruments.reachable(row, 60.0, -8.0, 60.0).ok, "a twilight target is allowed")
	var lov: Dictionary = Telescopes.INSTRUMENTS.lovell_l
	check(ObservatoryInstruments.reachable(lov, 60.0, 30.0, 100.0).ok, "radio works by day")
	check(not ObservatoryInstruments.reachable(lov, 5.0, 30.0, 100.0).ok, "the Lovell's horizon limit")
	near(ObservatoryInstruments.slew_seconds(lov, 0.0, 30.0, 150.0, 30.0), 600.0, 1.0, "150° of azimuth at 15°/min")
	near(ObservatoryInstruments.slew_seconds(lov, 350.0, 30.0, 10.0, 30.0), 80.0, 1.0, "a slew takes the short way round")
	# Resolving what the target box accepts.
	check(ObservatoryInstruments.parse_radec("05 34 31.9 +22 00 52").size() == 2, "sexagesimal RA and Dec")
	near(float(ObservatoryInstruments.parse_radec("05 34 31.9 +22 00 52")[0]), 83.6329, 1e-3, "sexagesimal RA")
	near(float(ObservatoryInstruments.parse_radec("05 34 31.9 +22 00 52")[1]), 22.01444, 1e-3, "sexagesimal Dec")
	near(float(ObservatoryInstruments.parse_radec("83.63 -22.5")[1]), -22.5, 1e-9, "decimal degrees")
	check(ObservatoryInstruments.parse_radec("not a place").is_empty(), "nonsense is refused")
	check(ObservatoryInstruments.parse_radec("400 95").is_empty(), "out-of-range coordinates are refused")

func determinism() -> void:
	var row: Dictionary = Telescopes.INSTRUMENTS.deimos
	var mk := func(sd: int) -> PackedFloat32Array:
		return Imager.expose({"row": row, "centre": EarthFrame.radec_vec(1.0, 0.3), "x": 1.3, "k_v": 0.11, "sky_v": 21.9, "seeing": 0.6, "exposure": 60.0, "w": 64, "bin": 1,
			"seed": sd, "year": 2026.0, "tdb": EarthFrame.J2000}).e
	check(mk.call(7) == mk.call(7), "one seed, one frame")
	check(mk.call(7) != mk.call(8), "another seed, other noise")
	var img := Imager.to_image(Imager.expose({"row": row, "centre": EarthFrame.radec_vec(1.0, 0.3), "x": 1.3, "k_v": 0.11, "sky_v": 21.9, "seeing": 0.6, "exposure": 60.0, "w": 64, "bin": 1,
		"seed": 7, "year": 2026.0, "tdb": EarthFrame.J2000}))
	check(img != null and img.get_width() == 64 and img.get_format() == Image.FORMAT_RGB8, "a frame makes an image")
