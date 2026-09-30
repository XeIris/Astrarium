class_name CloudField
extends RefCounted

# THE CLOUD FIELD ON THE CPU — the same density shaders/flight/clouds.gdshaderinc
# computes, evaluated in GDScript at a handful of points a frame.
# The cloud pass shades the clouds and the ground shader darkens the ground
# under them, but the vehicle, the tower and the pad are lit by Godot's own
# DirectionalLight3D, which knows nothing about either. So a rocket standing
# under a cumulus was lit by full sun on a ground in shadow — the concrete
# glaring white inside a dark field, which reads as a pasted-in object. The
# fix is the obvious one: ask the same field how much of the sun reaches the
# vehicle, and dim the light by that. Climbing through a deck, the vehicle
# then goes grey inside it and bursts back into sunlight above it.
#
# It has to be the SAME field, sample for sample, or the vehicle's light and
# the shadow on the ground under it disagree. So this reads the three noise
# volumes' own texels (NoiseTexture3D.get_data) and filters them trilinearly
# with wrap-around, which is what the GPU does at mip 0; the bulk density
# (no erosion) is what the light march and the ground shadows use too.
#
# The volumes are generated on a worker thread; until they exist this reports
# a clear sky.

var _tex: Array = []        # [NoiseTexture3D] × 3: shape, worley, detail
var _vol: Array = []        # [{w, h, d, data: PackedByteArray}] once read
var coverage := 0.0
var base := 1500.0
var top := 4600.0
var sigma := 0.03
var radius := 6.371e6
var wind := Vector3.ZERO
const TURN := Basis(Vector3(0.843228, 0.450325, -0.293553), Vector3(-0.293553, 0.843228, 0.450325), Vector3(0.450325, -0.293553, 0.843228))   # clouds.gdshaderinc's CLOUD_TURN
var clear_at := Vector3.ZERO
var clear_r := 0.0

func _init(shape: NoiseTexture3D, worley: NoiseTexture3D, detail: NoiseTexture3D) -> void:
	_tex = [shape, worley, detail]

## True once the volumes have been generated and read back.
func ready() -> bool:
	if _vol.size() == 2: return true
	var got: Array = []
	for i in 2:
		var t: NoiseTexture3D = _tex[i]
		if t == null: return false
		var imgs: Array = t.get_data()
		if imgs.size() != t.depth: return false
		var data := PackedByteArray()
		for im: Image in imgs:
			var c := im.duplicate() as Image
			if c.get_format() != Image.FORMAT_L8: c.convert(Image.FORMAT_L8)
			data.append_array(c.get_data())
		got.append({"w": t.width, "h": t.height, "d": t.depth, "data": data})
	_vol = got
	return true

## Trilinear, repeating, in texture coordinates (1 = one tile) — sampler3D
## with filter_linear and repeat_enable, at mip 0. Godot samples texel centres
## at (i + 0.5) / n, as every GPU does.
func _sample(v: Dictionary, uvw: Vector3) -> float:
	var w: int = v.w; var h: int = v.h; var d: int = v.d
	var data: PackedByteArray = v.data
	var x := uvw.x * w - 0.5; var y := uvw.y * h - 0.5; var z := uvw.z * d - 0.5
	var x0 := floori(x); var y0 := floori(y); var z0 := floori(z)
	var fx := x - x0; var fy := y - y0; var fz := z - z0
	var acc := 0.0
	for k in 2:
		var zi := posmod(z0 + k, d) * w * h
		var wz := fz if k == 1 else 1.0 - fz
		for j in 2:
			var yi := posmod(y0 + j, h) * w
			var wy := fy if j == 1 else 1.0 - fy
			var a := float(data[zi + yi + posmod(x0, w)])
			var b := float(data[zi + yi + posmod(x0 + 1, w)])
			acc += wz * wy * (a + (b - a) * fx)
	return acc / 255.0

static func _remap(v: float, lo: float, hi: float, a: float, b: float) -> float:
	return a + (v - lo) * (b - a) / maxf(hi - lo, 1e-5)

## Extinction (1/m) at a planet-fixed point, without the erosion: the bulk of
## the cloud, as clouds.gdshaderinc's cloud_density_fp(pp, 0.0, 0.0).
func density(pp: Vector3) -> float:
	var hf := (pp.length() - radius - base) / (top - base)
	if hf <= 0.0 or hf >= 1.0 or coverage <= 0.0 or not ready(): return 0.0
	var q := pp + wind
	var weather := _sample(_vol[0], q / 41000.0 + Vector3(0.31, 0.17, 0.83))
	var synoptic := _sample(_vol[0], q / 420000.0 + Vector3(0.71, 0.43, 0.05))
	var cov := clampf(coverage + (weather - 0.5) * 0.9 + (synoptic - 0.5) * 1.3, 0.0, 1.0)
	if clear_r > 0.0:   # the launch commit criteria — see clouds.gdshaderinc
		cov *= lerpf(0.2, 1.0, U.smooth(pp.distance_to(clear_at), clear_r * 0.35, clear_r * 1.4))
	var tp := lerpf(0.45, 1.0, clampf(cov * 1.3 - 0.1, 0.0, 1.0))
	var profile := U.smooth(hf, 0.0, 0.06) * (1.0 - U.smooth(hf, tp * 0.55, tp))
	var s := TURN * q / 6200.0
	var perlin := _sample(_vol[0], s)
	var worley := _sample(_vol[1], s * 0.9 + Vector3(0.5, 0.2, 0.7))
	var shape := _remap(perlin, -(1.0 - worley) * 0.9, 1.0, 0.0, 1.0)
	var dd := _remap(shape * profile, 1.0 - cov, 1.0, 0.0, 1.0)
	if dd <= 0.0: return 0.0
	return dd * U.smooth(hf + 0.1, 0.0, 0.3) * sigma

## How much of the sun reaches a planet-fixed point from direction `dir`
## (planet-fixed, unit): the layer's optical depth along the sun line in
## `n` samples, then the direct beam or the diffused light, whichever is more
## — the ground shader's own rule, so the two agree.
func sun_transmittance(pp: Vector3, dir: Vector3, n: int = 8) -> float:
	if coverage <= 0.0 or not ready(): return 1.0
	# where the sun line crosses the base and top spheres
	var seg := _shell(pp, dir)
	if seg.y <= seg.x: return 1.0
	var ds := (seg.y - seg.x) / n
	var od := 0.0
	for i in n:
		od += density(pp + dir * (seg.x + (i + 0.5) * ds)) * ds
	return maxf(exp(-od), 1.0 / (1.0 + 0.11 * od))

## The stretch of the ray from `p` along `dir` that is inside the layer.
func _shell(p: Vector3, dir: Vector3) -> Vector2:
	var h := p.length() - radius
	var b := p.dot(dir)
	var roots := func(rr: float) -> Vector2:
		var cc := (p.length() - rr) * (p.length() + rr)
		var disc := b * b - cc
		if disc < 0.0: return Vector2(-1.0, -1.0)
		var s := sqrt(disc)
		return Vector2(-b - s, -b + s)
	var tb: Vector2 = roots.call(radius + base)
	var tt: Vector2 = roots.call(radius + top)
	if h < base: return Vector2(maxf(tb.y, 0.0), tt.y)
	if h > top: return Vector2(maxf(tt.x, 0.0), tb.x if tb.x > 0.0 else tt.y)
	return Vector2(0.0, tb.x if tb.x > 0.0 else tt.y)
