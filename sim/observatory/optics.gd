class_name Optics
extends RefCounted

# A telescope's point-spread function: the annular pupil's diffraction with long-exposure
# Kolmogorov seeing, as the Hankel transform of the product of their transfer functions.
# Angles are radians, spatial frequency cycles per radian. Derivation:
# docs/physics/instruments.md.

## J0(x), Abramowitz & Stegun 9.4.1 and 9.4.3.
static func j0(x: float) -> float:
	var a := absf(x)
	if a <= 3.0:
		var t := (a / 3.0) * (a / 3.0)
		return 1.0 + t * (-2.2499997 + t * (1.2656208 + t * (-0.3163866 + t * (0.0444479 + t * (-0.0039444 + t * 0.0002100)))))
	var u := 3.0 / a
	var f := 0.79788456 + u * (-0.00000077 + u * (-0.00552740 + u * (-0.00009512 + u * (0.00137237 + u * (-0.00072805 + u * 0.00014476)))))
	var th := a - 0.78539816 + u * (-0.04166397 + u * (-0.00003954 + u * (0.00262573 + u * (-0.00054125 + u * (-0.00029333 + u * 0.00013558)))))
	return f * cos(th) / sqrt(a)

## An annular pupil's incoherent transfer function at `v` of its cutoff D/λ, obstruction
## ratio `eps` (O'Neill 1956, in Mahajan's form).
static func pupil_otf(v: float, eps: float) -> float:
	if v >= 1.0: return 0.0
	var a := 2.0 / PI * (acos(v) - v * sqrt(1.0 - v * v))
	if eps <= 0.0: return a
	var e2 := eps * eps
	var b := 0.0
	if v < eps:
		var w := v / eps
		b = e2 * 2.0 / PI * (acos(w) - w * sqrt(1.0 - w * w))
	var c := 0.0
	if v <= (1.0 - eps) * 0.5:
		c = -2.0 * e2
	elif v < (1.0 + eps) * 0.5:
		var phi := acos(clampf((1.0 + e2 - 4.0 * v * v) / (2.0 * eps), -1.0, 1.0))
		c = 2.0 * eps / PI * sin(phi) + (1.0 + e2) / PI * phi \
			- 2.0 * (1.0 - e2) / PI * atan((1.0 + eps) / (1.0 - eps) * tan(phi * 0.5)) - 2.0 * e2
	return (a + b + c) / (1.0 - e2)

## Fried's r0 (m) at wavelength `lam` (m) and airmass `x`, from the seeing FWHM (rad) at
## 500 nm and the zenith: FWHM = 0.98 λ/r0, r0 ∝ λ^(6/5) X^(−3/5).
static func r0_of(fwhm_500: float, lam: float, x: float) -> float:
	var r0_500 := 0.98 * 500e-9 / fwhm_500
	return r0_500 * pow(lam / 500e-9, 1.2) * pow(x, -0.6)

## The radial PSF: {"dr": step (rad), "p": per-solid-angle values normalised so the
## integral over the plane is 1, "fwhm": rad, "ee": encircled energy per radius}.
## `r0` = INF for no atmosphere. The tail past the table's reach is the imager's.
static func psf(d: float, eps: float, lam: float, r0: float) -> Dictionary:
	var cut := d / lam
	var atm := 3.44 * pow(lam / r0, 5.0 / 3.0) if is_finite(r0) else 0.0
	# Above four times r0/λ the atmosphere's transfer is under 1e-6.
	var fmax := minf(cut, 4.0 * r0 / lam) if is_finite(r0) else cut
	var nf := 256
	var df := fmax / nf
	var mtf := PackedFloat64Array()
	mtf.resize(nf + 1)
	for i in nf + 1:
		var f := i * df
		var a := exp(-atm * pow(f, 5.0 / 3.0)) if atm > 0.0 else 1.0
		mtf[i] = pupil_otf(f / cut, eps) * a * f * df * (0.5 if i == 0 or i == nf else 1.0)
	# The narrowest core sets the step: 12 samples across it, out to about 5 seeing FWHM
	# or 30 λ/D, which is where the wings stop mattering on these frames.
	var core := 1.0 / fmax
	var dr := core / 12.0
	var nr := 384
	var p := PackedFloat64Array()
	p.resize(nr)
	for k in nr:
		var r := k * dr
		var s := 0.0
		for i in nf + 1:
			s += mtf[i] * j0(TAU * i * df * r)
		p[k] = maxf(TAU * s, 0.0)
	var half := p[0] * 0.5
	var fwhm := NAN
	for k in range(1, nr):
		if p[k] < half:
			fwhm = 2.0 * dr * (k - 1 + (p[k - 1] - half) / (p[k - 1] - p[k]))
			break
	# Past two FWHM this coarse integral loses the wing to rounding, so a seeing-limited
	# PSF continues as Kolmogorov's θ^(−11/3) from there.
	var seeing_limited := is_finite(r0) and d > 3.0 * r0
	if seeing_limited:
		var seam := int(2.0 * fwhm / dr)
		for k in range(seam + 1, nr):
			p[k] = p[seam] * pow(float(seam) / k, 11.0 / 3.0)
	# Normalise on the table's own reach, and accumulate the encircled energy.
	var ee := PackedFloat64Array()
	ee.resize(nr)
	var total := 0.0
	for k in nr:
		ee[k] = total
		total += p[k] * TAU * (k + 0.5) * dr * dr
	for k in nr:
		p[k] /= total
		ee[k] /= total
	return {"dr": dr, "p": p, "fwhm": fwhm, "ee": ee, "air": seeing_limited}

## The PSF's value (per steradian) at radius `r` (rad).
static func psf_at(t: Dictionary, r: float) -> float:
	var f: float = r / float(t.dr)
	var k := int(f)
	var p: PackedFloat64Array = t.p
	if k >= p.size() - 1: return 0.0
	return lerpf(p[k], p[k + 1], f - k)

## The fraction of the light inside radius `r` (rad).
static func encircled(t: Dictionary, r: float) -> float:
	var f: float = r / float(t.dr)
	var k := int(f)
	var e: PackedFloat64Array = t.ee
	if k >= e.size() - 1: return 1.0
	return lerpf(e[k], e[k + 1], f - k)

## The first dark ring's radius (rad), or NAN if the seeing has filled it in.
static func first_null(t: Dictionary) -> float:
	var p: PackedFloat64Array = t.p
	for k in range(1, p.size() - 1):
		if p[k] <= p[k - 1] and p[k] < p[k + 1] and p[k] < 0.02 * p[0]:
			# A parabola through the three samples, since the zero falls between them.
			var d: float = p[k - 1] - 2.0 * p[k] + p[k + 1]
			return (k + (0.5 * (p[k - 1] - p[k + 1]) / d if d > 0.0 else 0.0)) * float(t.dr)
	return NAN
