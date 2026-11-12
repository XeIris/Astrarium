class_name GalISM
extends RefCounted

# The interstellar medium below the arm map's 104 pc texels: turbulent structure that
# multiplies a galaxy's dust and, independently, its young light, with mean one at every
# resolution, so the dust's mass and the young stars' light are unchanged.
#
# Both come from a Gaussian field in the plane with Kolmogorov's scaling, in octaves from
# 800 pc down to 3 pc; octaves finer than the galaxy's layer are averaged through it, the
# break Elmegreen et al. (2001) and Combes et al. (2012) measure. The field is the same
# through the layer, and each ray from a camera outside it takes it where it crosses the
# plane, so a tilted layer does not smear it and the march adds no grain. Supersonic turbulence gathers
# gas into shock-compressed sheets, so the dust's structured half (Pety et al. 2013's compact
# half of M51's gas) lies in sheets where the field crosses zero; the young light is a
# log-normal. Each octave is sheared by the rotation curve over its eddy's lifetime, so large
# eddies trail. See docs/physics/galaxies.md#the-medium-below-the-map.
#
# shaders/galaxy/gal_model.gdshaderinc (gal_ism) is this file on the GPU; multipliers() here
# matches it sample for sample.

## The octave field: N² texels, periodic, two independent unit-variance Gaussian channels:
## white noise filtered in Fourier space to wavelengths of 16–32 texels, so bilinear filtering
## draws each wave smoothly, with a slice of Kolmogorov's spectrum, amplitude ∝ k^(−4/3). Built
## once per process (~2 s), on the arms' worker in the scene.
const N := 512
const BAND := Vector2i(16, 32)
## Octave o spans wavelengths λ_o/2 to λ_o, λ_o = TOP / 2^o (kpc).
const TOP := 0.8
const OCTAVES := 9
## The dust: each octave multiplies it by exp(−βn²) over its mean, a sheet where the field
## crosses zero, β = AMP·shape(o). Set against Hubble's image of M51 (heic0506a): registered and
## tone-matched, the drawn galaxy's band power of log brightness at 36–289 pc comes within a
## factor 2 of Hubble's at every band (galaxies.md has the table); larger AMP darkens the 36–72 pc
## bands past it. The dust column's 40 pc width this gives between the arms, 0.12 dex, is half
## of what Hughes et al. (2013) find for CO (0.22–0.25 dex), which traces only the dense phase.
const AMP := 0.1
## The structured share of the dust: Pety et al.'s (2013) compact half of M51's CO.
const COMPACT := 0.5
## A camera further than this (kpc) from the plane sees the medium from outside its layer, and
## each ray takes it where it crosses the plane. From within, a jittered march samples the
## field along the ray finer than its step and draws grain, so the medium is not drawn there.
const OUTSIDE := 1.0
## The young light's log-normal width (dex) at 40 pc, set on Hubble's image of M51 with AMP and
## FEATHER_AMP: M51's band power of log brightness at 36–289 pc then comes within 30 % of
## Hubble's (galaxies.md has the table). Grasha et al. (2019) find M51's clusters' 1 + ω(θ) ∝ θ^−0.28
## against the molecular clouds' θ^−0.09; a log-normal raised to n steepens ln(1 + ξ) by n², so
## against Hughes et al.'s (2013) CO widths that would be √(0.28/0.09) × 0.235 = 0.41 dex,
## which draws more band power than Hubble's image holds.
const YOUNG_WIDTH := 0.15
## A 40 pc beam resolves waves longer than 80 pc, which weight() passes at a 20 pc footprint.
const WIDTH_FOOT := 0.02
## Checks and the fidelity measurement vary it; the constant otherwise.
static var amp := AMP

## The young light is a log-normal in its own realization: Grasha et al. (2019) find most
## clusters have left their gas by ~6 Myr, and the young light is dominated by older ones.
## Larson's size–linewidth relation, δv = 0.90 km/s (ℓ/pc)^0.56 (Heyer & Brunt 2004), held
## below a disc's gas velocity dispersion, ~10 km/s (Tamburro et al. 2009): an octave's eddies
## live ℓ/δv, and are sheared that long, but no longer than the shear time |dΩ/dln R|⁻¹ that
## tears clouds apart (Meidt et al. 2015 find M51's clouds live 20–30 Myr, about that): the
## strain is at most SHEAR_MAX.
const LARSON_KMS := 0.90
const LARSON_EXP := 0.56
const SIGMA_GAS_KMS := 10.0
const SHEAR_MAX := 1.0

static var _field := PackedFloat32Array()
static var _tex: ImageTexture = null
static var _mutex := Mutex.new()

## Octave o's turn (rad) and offset in the field, so octaves of one tile never line up.
static func octave_angle(o: int) -> float:
	return 2.39996323 * float(o + 1)

static func octave_offset(o: int) -> Vector2:
	return Vector2(fposmod(0.618034 * float(o + 1), 1.0), fposmod(0.414214 * float(o + 1), 1.0))

static func wavelength(o: int) -> float:
	return TOP / pow(2.0, float(o))

## Octave o's shape in a layer `layer` kpc thick: Kolmogorov gives each octave a variance ∝
## λ^(2/3) in three dimensions, and a column through the layer averages layer/λ independent
## eddies of the finer ones, whose amplitude falls by √(λ/layer): the break Elmegreen et al.
## (2001) and Combes et al. (2012) measure. The slice in the plane draws the column this way.
static func shape(o: int, layer: float) -> float:
	var l := wavelength(o)
	return pow(l / 0.1, 1.0 / 3.0) * minf(1.0, sqrt(l / layer))

## The dust's sheet contrast β of octave o in a dust layer `layer` kpc thick.
static func amplitude(o: int, layer: float) -> float:
	return amp * shape(o, layer)

## Octaves whose dust contrast and young log-amplitude are both below these are not drawn: a
## few per cent of a pixel's brightness at most, and the fine end of a thick layer's spectrum.
const MIN_AMP := Vector2(0.01, 0.03)

## How many octaves, from the largest, a galaxy with these layers draws.
static func count(layers: Vector2) -> int:
	var n := 0
	for o in OCTAVES:
		if amplitude(o, layers.x) >= MIN_AMP.x or young_amplitude(o, layers.y) >= MIN_AMP.y: n = o + 1
	return n

## The young light's log-amplitude of octave o in a layer `layer` kpc thick: YOUNG_WIDTH at
## 40 pc, shared over the octaves a 40 pc beam resolves.
static func young_amplitude(o: int, layer: float) -> float:
	var s := 0.0
	for k in OCTAVES: s += pow(weight(k, WIDTH_FOOT) * shape(k, layer), 2.0)
	return YOUNG_WIDTH * log(10.0) / sqrt(s) * shape(o, layer)

## An octave's eddy lifetime (Myr).
static func lifetime(o: int) -> float:
	var l := wavelength(o)
	var dv := minf(LARSON_KMS * pow(l * 1000.0, LARSON_EXP), SIGMA_GAS_KMS) * GalUnits.KMS
	return l / dv

## How much of octave o a footprint of `foot` kpc resolves: all of it below an eighth of its
## longest wavelength, none past a quarter, where a pixel steps half its shortest wave (8 of the
## field's 16 texels): finer, the octave would alias and miss the texture cache.
static func weight(o: int, foot: float) -> float:
	var l := wavelength(o)
	return clampf((0.25 * l - foot) / (0.125 * l), 0.0, 1.0)

const SEED := 25

## The two channels interleaved (dust, young), x fastest, rounded to half floats: the GPU's
## texture holds exactly these values.
static func field() -> PackedFloat32Array:
	_mutex.lock()
	if _field.is_empty():
		var f := PackedFloat32Array()
		var h := PackedByteArray()
		f.resize(N * N * 2)
		h.resize(N * N * 4)
		for ch in 2:
			var c := _channel(SEED + ch)
			for i in N * N:
				h.encode_half((2 * i + ch) * 2, c[i])
				f[2 * i + ch] = h.decode_half((2 * i + ch) * 2)
		_half = h
		_field = f
	_mutex.unlock()
	return _field

static var _half := PackedByteArray()

static func _channel(seed: int) -> PackedFloat64Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var m := N * N
	var re := PackedFloat64Array()
	var im := PackedFloat64Array()
	re.resize(m)
	im.resize(m)
	for i in m: re[i] = rng.randfn()
	_fft2(re, im, false)
	for y in N:
		var ky := y if y <= N / 2 else y - N
		for x in N:
			var kx := x if x <= N / 2 else x - N
			var k := sqrt(float(kx * kx + ky * ky))
			var g := pow(k, -4.0 / 3.0) if k >= BAND.x and k < BAND.y else 0.0
			re[y * N + x] *= g
			im[y * N + x] *= g
	_fft2(re, im, true)
	var mean := 0.0
	for i in m: mean += re[i]
	mean /= float(m)
	var v := 0.0
	for i in m: v += (re[i] - mean) * (re[i] - mean)
	var sd := sqrt(v / float(m))
	for i in m: re[i] = (re[i] - mean) / sd
	return re

static func _fft2(re: PackedFloat64Array, im: PackedFloat64Array, inverse: bool) -> void:
	var lr := PackedFloat64Array()
	var li := PackedFloat64Array()
	lr.resize(N)
	li.resize(N)
	for axis in 2:
		var stride := 1 if axis == 0 else N
		for a in N:
			var base := a * N if axis == 0 else a
			for i in N:
				lr[i] = re[base + i * stride]
				li[i] = im[base + i * stride]
			_fft1(lr, li, inverse)
			for i in N:
				re[base + i * stride] = lr[i]
				im[base + i * stride] = li[i]

## Radix 2 in place; the inverse is unnormalised (the channel is normalised after).
static func _fft1(re: PackedFloat64Array, im: PackedFloat64Array, inverse: bool) -> void:
	var j := 0
	for i in range(1, N):
		var bit := N >> 1
		while j & bit:
			j ^= bit
			bit >>= 1
		j |= bit
		if i < j:
			var t := re[i]
			re[i] = re[j]
			re[j] = t
			t = im[i]
			im[i] = im[j]
			im[j] = t
	var size := 2
	var sgn := 1.0 if inverse else -1.0
	while size <= N:
		var half := size / 2
		for k in half:
			var c := cos(TAU * float(k) / float(size))
			var s := sgn * sin(TAU * float(k) / float(size))
			for start in range(0, N, size):
				var a := start + k
				var b := a + half
				var tr := re[b] * c - im[b] * s
				var ti := re[b] * s + im[b] * c
				re[b] = re[a] - tr
				im[b] = im[a] - ti
				re[a] += tr
				im[a] += ti
		size *= 2

## The field as the GPU samples it.
static func texture() -> ImageTexture:
	field()
	_mutex.lock()
	if _tex == null:
		_tex = ImageTexture.create_from_image(Image.create_from_data(N, N, false, Image.FORMAT_RGH, _half))
	_mutex.unlock()
	return _tex

## Bilinear between texel centres, wrapped, as a repeating linear sampler reads it.
static func sample(f: PackedFloat32Array, uv: Vector2) -> Vector2:
	var x := uv.x * float(N) - 0.5
	var y := uv.y * float(N) - 0.5
	var fx := floorf(x)
	var fy := floorf(y)
	var tx := x - fx
	var ty := y - fy
	var x0 := posmod(int(fx), N)
	var y0 := posmod(int(fy), N)
	var x1 := (x0 + 1) % N
	var y1 := (y0 + 1) % N
	var out := Vector2.ZERO
	for c in 2:
		var a := lerpf(f[(y0 * N + x0) * 2 + c], f[(y0 * N + x1) * 2 + c], tx)
		var b := lerpf(f[(y1 * N + x0) * 2 + c], f[(y1 * N + x1) * 2 + c], tx)
		out[c] = lerpf(a, b, ty)
	return out

## Each octave's turn back to where its gas was (rad, signed by the galaxy's sense, φ growing
## at +Ω) on TURN_N radii evenly from 0 to `r_max`: Ω(R)·t, with its slope in ln R held to
## ±SHEAR_MAX, integrated inward from the edge. Row o is octave o (texels x along R).
const TURN_N := 64

static func turn_table(pot: GalPotential, r_max: float, sense: float) -> PackedFloat32Array:
	var om := PackedFloat64Array()
	var rr := PackedFloat64Array()
	for i in TURN_N:
		var r := maxf(r_max * float(i) / float(TURN_N - 1), 0.02)
		rr.append(r)
		om.append(sense * pot.vc(r) / r)
	var t := PackedFloat32Array()
	t.resize(TURN_N * OCTAVES)
	for o in OCTAVES:
		var life := lifetime(o)
		var th := om[TURN_N - 1] * life
		t[o * TURN_N + TURN_N - 1] = th
		for i in range(TURN_N - 2, -1, -1):
			var lim := SHEAR_MAX * log(rr[i + 1] / rr[i])
			th -= clampf((om[i + 1] - om[i]) * life, -lim, lim)
			t[o * TURN_N + i] = th
	return t

static func turn_at(t: PackedFloat32Array, o: int, r_max: float, R: float) -> float:
	var x := clampf(R / r_max, 0.0, 1.0) * float(TURN_N - 1)
	var i := mini(int(x), TURN_N - 2)
	return lerpf(t[o * TURN_N + i], t[o * TURN_N + i + 1], x - float(i))

## The dust's and the young light's multipliers at p's place in the plane (galaxy-local kpc;
## the field turns with the arms by `turn`) for a footprint `foot` kpc, each of mean one.
## `layers`: the dust's and the young light's layer thicknesses (kpc).
## `norms` (norms()) divides each by its realised mean over the galaxy at this footprint.
## `fth` (feather_frame) gathers the dust's structured share into feathers off its lanes.
static func multipliers(f: PackedFloat32Array, p: Vector3, foot: float, turns: PackedFloat32Array, r_max: float, turn: float, layers: Vector2, norms := PackedVector2Array(), fth := {}) -> Vector2:
	var ct := cos(turn)
	var st := sin(turn)
	var q0 := Vector3(p.x * ct + p.z * st, p.y, p.z * ct - p.x * st)
	var R := sqrt(q0.x * q0.x + q0.z * q0.z)
	var ld := 0.0
	var ly := 0.0
	for o in count(layers):
		var w := weight(o, foot)
		if w <= 0.0: break
		var b := amplitude(o, layers.x) * w
		var a := young_amplitude(o, layers.y) * w
		# Where this gas was an eddy lifetime ago.
		var ang := -turn_at(turns, o, r_max, R)
		var c := cos(ang)
		var s := sin(ang)
		var qx := q0.x * c - q0.z * s
		var qz := q0.x * s + q0.z * c
		var n := sample(f, octave_matrix(o) * Vector2(qx, qz) + octave_offset(o))
		# A sheet where the field crosses zero, exp(−βn²) over its mean (1 + 2β)^(−1/2).
		ld += -b * n.x * n.x + 0.5 * log(1.0 + 2.0 * b)
		ly += a * n.y - 0.5 * a * a
	var nm := norm_at(norms, foot)
	return Vector2(exp(ld) * feather(fth, Vector2(q0.x, q0.z), foot) / nm.x, exp(ly) / nm.y)

## Feathers (La Vigne et al. 2006): thin dust lanes that leave a spiral arm's primary dust lane
## at regular spacings, cross the luminous arm and wind into the interarm. M51's are spaced
## ~200 pc in the inner disc and 500–1000 pc in the outer, with the gas's Jeans length: about
## FEATHER_SPACING of R along the lane. Spurs and feathers leave the arm at ~50° (Elmegreen
## 1980, via La Vigne et al.). Downstream each is a material line in the gas's shear: with a flat
## rotation curve, a parcel u rad downstream of the lane in the arms' frame left it Ω u/(Ω − Ω_p)
## ago, so the line's pitch goes as cot i = cot i₀ + k u, k = 1/(1 − R/R_CR). Followed outward
## from where it left the lane (x = ln R/R_e), u' = cot p − cot i, so u = (a/k)(1 − e^(−kx)),
## a = cot p − cot i₀: it crosses the arm and winds until it lies along it at u = a/k, merging
## as La Vigne et al. see them reach the next arm's lane; its contrast falls to nothing there.
## They are quasi-regular and come in groups (La Vigne et al.): each is moved by up to
## FEATHER_JITTER of the spacing and given an exponentially distributed share of the dust,
## seeded by its index along the lane. Its profile is a Gaussian FEATHER_WIDTH of the spacing,
## widened to the footprint; past FEATHER_BLUR the feathers are drawn as their mean, one. How
## much of the structured dust they gather, FEATHER_AMP, and their width are not measured: they
## are set with YOUNG_WIDTH on Hubble's image (at 1, M51's bands at 36–72 pc reach twice Hubble's).
const FEATHER_SPACING := 0.125
## 50° (rad).
const FEATHER_ANGLE := 0.8727
const FEATHER_WIDTH := 0.15
const FEATHER_AMP := 0.5
const FEATHER_JITTER := 0.3
const FEATHER_BLUR := 0.35
static var feather_amp := FEATHER_AMP

## A galaxy's lanes as feather() reads them: each Vector4(R₀, β₀, tan p in, tan p out) of
## GalaxyVisual._lane_beta with its arm's span [R_min, R_max] (kpc), the break and corotation radii (kpc),
## and whether the arms are mirrored.
static func feather_frame(lanes: Array, spans: Array, r_break: float, r_cr: float, mirror: bool) -> Dictionary:
	return {"lanes": lanes, "spans": spans, "rb": r_break, "rcr": r_cr, "mirror": mirror}

## The feathers' multiplier of the dust's structured share at q (the arms' frame, kpc) for a
## footprint `foot` kpc.
static func feather(fth: Dictionary, q: Vector2, foot: float) -> float:
	if fth.is_empty() or feather_amp <= 0.0: return 1.0
	var R := q.length()
	var rcr: float = fth.rcr
	if R < 0.05 or R > 0.9 * rcr: return 1.0
	var beta := atan2(q.y, q.x) - PI
	if fth.mirror: beta = -beta
	var lanes: Array = fth.lanes
	var u := INF
	var fade := 0.0
	var tp := 0.0
	for k in lanes.size():
		var ln: Vector4 = lanes[k]
		var span: Vector2 = fth.spans[k]
		var rb: float = fth.rb
		var lb := ln.y - log(R / ln.x) / ln.z if R <= rb else ln.y - log(rb / ln.x) / ln.z - log(R / rb) / ln.w
		var uk := fposmod(beta - lb, TAU)
		if uk < u:
			u = uk
			tp = ln.z if R <= rb else ln.w
			fade = smoothstep(span.x, span.x + 0.5, R) * smoothstep(span.y, span.y - 0.5, R)
	fade *= smoothstep(0.9 * rcr, 0.7 * rcr, R)
	if fade <= 0.0: return 1.0
	var p := atan(tp)
	var aa := 1.0 / tp - 1.0 / tan(minf(p + FEATHER_ANGLE, deg_to_rad(85.0)))
	var kk := 1.0 / (1.0 - R / rcr)
	var left := 1.0 - kk * u / aa
	if left <= 0.0: return 1.0
	# Where along the lane this line left it, in ln R: emergences FEATHER_SPACING·R apart along
	# a lane of pitch p are FEATHER_SPACING·sin p apart in ln R.
	var chi := (log(R) + log(left) / kk) / (FEATHER_SPACING * sin(p))
	var a := feather_amp * fade * left
	var sig := sqrt(FEATHER_WIDTH * FEATHER_WIDTH + pow(foot / (0.77 * FEATHER_SPACING * R), 2.0))
	if sig >= FEATHER_BLUR: return 1.0
	var n0 := int(floor(chi))
	var g := 0.0
	for m in range(n0 - 1, n0 + 3):
		var h := feather_hash(m)
		var x := chi - float(m) - FEATHER_JITTER * (2.0 * h.x - 1.0)
		g += -log(1.0 - 0.999 * h.y) * exp(-0.5 * x * x / (sig * sig))
	g /= sig * sqrt(TAU)
	return 1.0 + a * smoothstep(FEATHER_BLUR, 0.6 * FEATHER_BLUR, sig) * (g - 1.0)

## Two uniform numbers in [0, 1) for feather n: an integer hash, as the shader's.
static func feather_hash(n: int) -> Vector2:
	var h := (n * 1973 + 26699) & 0xffffffff
	h = ((h ^ (h >> 16)) * 2246822519) & 0xffffffff
	h = ((h ^ (h >> 13)) * 3266489917) & 0xffffffff
	h ^= h >> 16
	return Vector2(float(h & 0xffff) / 65536.0, float(h >> 16) / 65536.0)

## The realised means at a footprint: linear in log₂ between NORM_FEET, held beyond them.
static func norm_at(norms: PackedVector2Array, foot: float) -> Vector2:
	if norms.size() != NORM_FEET.size(): return Vector2.ONE
	var x := clampf(log(foot / NORM_FEET[0]) / log(2.0), 0.0, float(NORM_FEET.size() - 1) - 1e-6)
	var i := int(x)
	return norms[i].lerp(norms[i + 1], x - float(i))

## The multipliers' realised means over a galaxy's map (`img`, the arm map: dust in g, young
## light in r times `envelope`) at each of NORM_FEET (kpc): its few largest eddies do not average
## out over one galaxy (M51's young light by 6 %), so each galaxy's are divided by their own and
## its dust's mass and young light stay exact. The footprints are where octaves fade in, λ_o/8;
## finer than 12.5 pc the eddies added average out.
const NORM_FEET := [0.0125, 0.025, 0.05, 0.1, 0.2]

static func norms(img: Image, half: float, envelope: Callable, turns: PackedFloat32Array, r_max: float, layers: Vector2, fth := {}) -> PackedVector2Array:
	var f := field()
	var n := img.get_width()
	var px := 2.0 * half / float(n)
	var out := PackedVector2Array()
	for foot in NORM_FEET:
		var acc := Vector4.ZERO
		for j in range(0, n, 2):
			for i in range(0, n, 2):
				var x := -half + (float(i) + 0.5) * px
				var z := -half + (float(j) + 0.5) * px
				var c := img.get_pixel(i, j)
				var y: float = c.r * envelope.call(sqrt(x * x + z * z))
				if c.g <= 0.0 and y <= 0.0: continue
				var m := multipliers(f, Vector3(x, 0.0, z), foot, turns, r_max, 0.0, layers, PackedVector2Array(), fth)
				acc += Vector4(c.g * m.x, c.g, y * m.y, y)
		out.append(Vector2(acc.x / acc.y if acc.y > 0.0 else 1.0, acc.z / acc.w if acc.w > 0.0 else 1.0))
	return out

## The dust's multiplier from the field's D: the compact share is structured.
static func dust(d: float) -> float:
	return 1.0 + COMPACT * (d - 1.0)

## Whether a camera at height y sees the medium: from outside its layer only.
static func outside(y: float) -> bool:
	return absf(y) > OUTSIDE

## Octave o's turn and scale into the field: λ_o spans 32 texels, a sixteenth of the tile.
static func octave_matrix(o: int) -> Transform2D:
	var k := 1.0 / (16.0 * wavelength(o))
	var a := octave_angle(o)
	return Transform2D(Vector2(cos(a), sin(a)) * k, Vector2(-sin(a), cos(a)) * k, Vector2.ZERO)

## The uniforms gal_ism reads.
static func set_uniforms(mat: ShaderMaterial, turns: PackedFloat32Array, r_max: float, layers: Vector2, norms: PackedVector2Array, fth := {}) -> void:
	var oct := PackedFloat32Array()
	var young := PackedFloat32Array()
	var lam := PackedFloat32Array()
	var cols := PackedVector2Array()
	var off := PackedVector2Array()
	for o in OCTAVES:
		oct.append(amplitude(o, layers.x))
		young.append(young_amplitude(o, layers.y))
		lam.append(wavelength(o))
		var m := octave_matrix(o)
		cols.append_array([m.x, m.y])
		off.append(octave_offset(o))
	mat.set_shader_parameter("uISM", texture())
	mat.set_shader_parameter("uISMOct", oct)
	mat.set_shader_parameter("uISMLam", lam)
	mat.set_shader_parameter("uISMM", cols)
	mat.set_shader_parameter("uISMOff", off)
	mat.set_shader_parameter("uISMYoung", young)
	mat.set_shader_parameter("uISMLayer", Vector2(COMPACT, OUTSIDE))
	var lanes := []
	var spans := []
	for k in 2:
		var on: bool = not fth.is_empty() and k < (fth.lanes as Array).size()
		lanes.append(fth.lanes[k] if on else Vector4(1, 0, 1, 1))
		spans.append(fth.spans[k] if on else Vector2(0, 0))
	mat.set_shader_parameter("uFeather", Vector4(feather_amp if not fth.is_empty() else 0.0, FEATHER_SPACING, FEATHER_ANGLE, FEATHER_WIDTH))
	mat.set_shader_parameter("uFeatherR", Vector3(fth.get("rb", 1.0), fth.get("rcr", 1.0), 1.0 if fth.get("mirror", false) else 0.0))
	mat.set_shader_parameter("uLane", PackedVector4Array(lanes))
	mat.set_shader_parameter("uLaneSpan", PackedVector2Array(spans))
	mat.set_shader_parameter("uISMCount", count(layers))
	var nm := norms
	if nm.size() != NORM_FEET.size():
		nm = PackedVector2Array()
		for k in NORM_FEET.size(): nm.append(Vector2.ONE)
	mat.set_shader_parameter("uISMNorm", nm)
	mat.set_shader_parameter("uISMTurn", ImageTexture.create_from_image(Image.create_from_data(TURN_N, OCTAVES, false, Image.FORMAT_RF, turns.to_byte_array())))
	mat.set_shader_parameter("uISMTurnR", r_max)
