class_name GalHII
extends RefCounted

# A galaxy's H II regions, drawn by shaders/galaxy/galaxy_hii.gdshader: each a nebula, a
# Gaussian blob of its recombination and [N II] lines, around its ionising cluster, a point of
# its young stars' light. How many, how bright and how large follow the measured luminosity
# function (GalModels.M51_HII). They stand in complexes along the young disc's light in the
# arm map, each a hierarchy (Soneira & Peebles 1978) of three per halving of scale on average,
# a fractal of dimension log 3/log 2 = 1.585 in the plane. docs/physics/galaxies.md#h-ii-regions.

## IAU 2015 nominal solar luminosity, erg/s.
const ERG_LSUN := 3.828e33
## Air wavelengths (nm): Hα, [N II] λ6583 and λ6548, Hβ.
const HA := 656.28
const NII_R := 658.35
const NII_B := 654.80
const HB := 486.13
## A region's blob: σ = D/4, so its effective diameter holds 95 % of its light.
const SIGMA_PER_D := 0.25

## The catalogue for a galaxy `d_kpc` away, from the arm map `img` (young light in r) over
## ±`half` kpc, the young disc's bolometric light `young_l` and layer height `young_h`. Returns
## pos (galaxy-local kpc), sigma (kpc), col (visible light per channel, Sun-luminances), the
## regions' Hα (erg/s), and what the young disc gives up or gains: its continuum in the regions
## (bolometric, with its colour) and the diffuse gas's lines (bolometric, visible).
static func build(spec: Dictionary, d_kpc: float, img: Image, half: float, young_l: float, young_h: float, seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	# Luminosities scale as distance², sizes as distance.
	var f2 := pow(d_kpc / (float(spec.d) * 1000.0), 2.0)
	var fd := d_kpc / (float(spec.d) * 1000.0)
	var l_all := pow(10.0, log(float(spec.sfr)) / log(10.0) + float(spec.logC))
	var l_regions := l_all * (1.0 - float(spec.dig))
	var lo := pow(10.0, float(spec.logL[0])) * f2
	var lb := pow(10.0, float(spec.logL[1])) * f2
	var hi := pow(10.0, float(spec.logL[2])) * f2
	var a_hi := float(spec.alpha[0])
	var a_lo := float(spec.alpha[1])
	# dN/dL = (L/L_b)^α, α by side of the break: count and light of each side per unit A.
	var n_lo := _power_int(lo / lb, 1.0, a_lo) * lb
	var n_hi := _power_int(1.0, hi / lb, a_hi) * lb
	var s_lo := _power_int(lo / lb, 1.0, a_lo + 1.0) * lb * lb
	var s_hi := _power_int(1.0, hi / lb, a_hi + 1.0) * lb * lb
	var amp := l_regions / (s_lo + s_hi)
	var n := int(round(amp * (n_lo + n_hi)))
	var lum := PackedFloat64Array()
	lum.resize(n)
	var total := 0.0
	for i in n:
		var u := rng.randf()
		if u < n_lo / (n_lo + n_hi): lum[i] = lb * _power_draw(lo / lb, 1.0, a_lo, u * (n_lo + n_hi) / n_lo)
		else: lum[i] = lb * _power_draw(1.0, hi / lb, a_hi, (u * (n_lo + n_hi) - n_lo) / n_hi)
		total += lum[i]
	# The draw's sum moves by √N; the regions keep the star formation rate's Hα exactly.
	for i in n: lum[i] *= l_regions / total
	# Regions fainter than drawLogL are left in the smooth young light, which keeps their stars'
	# light and gains their lines: too small to see apart at a galaxy's scale, and most of them.
	var l_draw := pow(10.0, float(spec.drawLogL)) * f2
	var drawn := PackedFloat64Array()
	var folded := 0.0
	for i in n:
		if lum[i] >= l_draw: drawn.append(lum[i])
		else: folded += lum[i]
	var nd := drawn.size()
	_shuffle(drawn, rng)
	var pos := _positions(img, half, young_h, nd, float(spec.top), int(spec.levels), rng)
	var young := GalPopulation.build({"kind": "constant", "gyr": GalModels.MW_YOUNG_GYR})
	var newborn := GalPopulation.build({"kind": "constant", "gyr": float(spec.tGyr)})
	# At one formation rate a population's light is its light per mass formed times its span.
	var share := (1.0 - float(spec.dig)) * newborn.light_per_formed * float(spec.tGyr) / (young.light_per_formed * GalModels.MW_YOUNG_GYR)
	var cont := share * young_l
	var line := _line_colour(spec)
	var seen := line * line_transmission(spec)
	var l0 := pow(10.0, float(spec.logL[0])) * f2
	var d0 := float(spec.size[0]) * fd * 1e-3
	var sigma := PackedFloat32Array()
	var stars := PackedColorArray()
	var lines := PackedColorArray()
	sigma.resize(nd)
	stars.resize(nd)
	lines.resize(nd)
	for i in nd:
		stars[i] = newborn.color * (cont * drawn[i] / l_regions)
		# Unclipped: Hα lies outside sRGB, so the shader clips the sum per pixel.
		lines[i] = seen * (drawn[i] / ERG_LSUN)
		sigma[i] = SIGMA_PER_D * d0 * pow(drawn[i] / l0, 1.0 / float(spec.size[1]))
	var diffuse := (l_all * float(spec.dig) + folded) / ERG_LSUN
	var dig_vis := line * (l_all * float(spec.dig) / ERG_LSUN) + seen * (folded / ERG_LSUN)
	return {"pos": pos, "sigma": sigma, "stars": stars, "lines": lines, "lum": drawn, "n": nd, "n_all": n, "ha_regions": l_regions,
		"ha_drawn": l_regions - folded, "ha_all": l_all, "cont_bol": cont * (l_regions - folded) / l_regions,
		"cont_col": newborn.color, "dig_bol": diffuse * (1.0 + float(spec.nii) + 1.0 / float(spec.hahb)), "dig_vis": dig_vis}

## What of the regions' lines leaves their own clouds, per channel (spec "avLines", V mag).
static func line_transmission(spec: Dictionary) -> Color:
	var e: Array = GalModels.EXTINCTION_RGB
	var av := float(spec.get("avLines", 0.0))
	return Color(pow(10.0, -0.4 * av * float(e[0])), pow(10.0, -0.4 * av * float(e[1])), pow(10.0, -0.4 * av * float(e[2])))

## The lines' light per unit Hα power (visible()'s units): Hα, [N II] in 3 : 1, Hβ.
static func _line_colour(spec: Dictionary) -> Color:
	var nii := float(spec.nii)
	return GalPopulation.visible_line(HA) + GalPopulation.visible_line(NII_R) * (0.75 * nii) \
		+ GalPopulation.visible_line(NII_B) * (0.25 * nii) + GalPopulation.visible_line(HB) * (1.0 / float(spec.hahb))

## ∫ x^α dx from a to b.
static func _power_int(a: float, b: float, alpha: float) -> float:
	if absf(alpha + 1.0) < 1e-9: return log(b / a)
	return (pow(b, alpha + 1.0) - pow(a, alpha + 1.0)) / (alpha + 1.0)

## x on [a, b] with density ∝ x^α at cumulative fraction u.
static func _power_draw(a: float, b: float, alpha: float, u: float) -> float:
	var k := alpha + 1.0
	if absf(k) < 1e-9: return a * pow(b / a, u)
	return pow(pow(a, k) + u * (pow(b, k) - pow(a, k)), 1.0 / k)

## Where the regions stand. Complex centres are texels drawn in proportion to the young light
## (r) they hold, a point uniform within each; within a complex each node holds a Poisson
## number of children, three on average and at least one, offset by a Gaussian of σ half its own,
## `levels` times from `top` (kpc); heights from the young layer's exp(−|y|/h).
static func _positions(img: Image, half: float, h: float, n: int, top: float, levels: int, rng: RandomNumberGenerator) -> PackedVector3Array:
	var size := img.get_width()
	var px := 2.0 * half / float(size)
	var cdf := PackedFloat64Array()
	cdf.resize(size * size)
	var acc := 0.0
	for j in size:
		for i in size:
			acc += maxf(img.get_pixel(i, j).r, 0.0)
			cdf[j * size + i] = acc
	var out := PackedVector3Array()
	out.resize(n)
	var k := 0
	while k < n:
		var t := mini(cdf.bsearch(rng.randf() * acc), size * size - 1)
		var centre := Vector2(-half + (float(t % size) + rng.randf()) * px, -half + (floorf(float(t) / float(size)) + rng.randf()) * px)
		var nodes := [centre]
		var r := top
		for lv in levels:
			var next := []
			for p in nodes:
				for c in maxi(_poisson(3.0, rng), 1): next.append((p as Vector2) + Vector2(rng.randfn(), rng.randfn()) * r)
			nodes = next
			r *= 0.5
		for p in nodes:
			if k >= n: break
			var y := -h * log(maxf(rng.randf(), 1e-12)) * (1.0 if rng.randf() < 0.5 else -1.0)
			out[k] = Vector3((p as Vector2).x, y, (p as Vector2).y)
			k += 1
	return out

static func _poisson(mean: float, rng: RandomNumberGenerator) -> int:
	var l := exp(-mean)
	var k := 0
	var p := rng.randf()
	while p > l:
		k += 1
		p *= rng.randf()
	return k

## Fisher–Yates, so the brightest regions do not all fall in the first complex.
static func _shuffle(a: PackedFloat64Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := a[i]
		a[i] = a[j]
		a[j] = t
