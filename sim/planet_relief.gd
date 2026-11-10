class_name PlanetRelief
extends RefCounted

# The drawn crust on the CPU: what shaders/bodies/terrain.gdshaderinc computes, with its integer
# lattice hash, so a pin, a site and the planet seen from orbit are the same ground. Vector3 is
# float32, as the shader is, so high octaves round the same way. tools/pincheck.tscn renders the
# shader's height and compares. Change both together.

const M32 := 0xFFFFFFFF

# The uniforms terrain() reads, off a visual's material.
var seed := 0.0
var crust_t := 0.54
var land_relief := 3.2
var ocean_depth := 4.6
var plate_scale := 2.6
var crater := 0.0
var sea_km := 0.0
var map_kind := 0
var mean_k := 288.0
var s2 := -0.477
var transport := 0.42
var arid := 0.0
var frost_k := 273.0
var ice := 0.0
var season := 8.0
var biota := 0.0
var lapse := 6.5

## The crust a body's visual draws, with its climate's look: what the material eases to, not where
## it is this frame, since an undrawn stage never updates a material.
static func of_body(b: Body) -> PlanetRelief:
	var r := of_visual(PlanetPin._viz(b))
	if b.climate == null: return r
	var t := ClimateLook.targets(b.climate, b.spec)
	r.mean_k = float(t.uMeanK)
	r.ice = float(t.uIce)
	r.sea_km = float(t.uSeaKm)
	r.arid = float(t.uArid)
	r.frost_k = float(t.uFrostK)
	r.crater = float(t.uCrater)
	r.biota = float(t.uBiota)
	r.lapse = float(t.uLapse)
	if t.has("uCrustT"): r.crust_t = float(t.uCrustT)
	if t.has("uOceanDepth"): r.ocean_depth = float(t.uOceanDepth)
	return r

## The crust as a visual's material holds it now. `viz` is a RockyViz or a WorldViz.
static func of_visual(viz) -> PlanetRelief:
	var r := PlanetRelief.new()
	var m: ShaderMaterial = viz.surf_mat
	var read := func(key: String, fallback: float) -> float:
		var v = m.get_shader_parameter(key)
		return float(v) if v != null else fallback
	r.seed = read.call("uSeed", 0.0)
	r.crust_t = read.call("uCrustT", 0.54)
	r.land_relief = read.call("uLandRelief", 3.2)
	r.ocean_depth = read.call("uOceanDepth", 4.6)
	r.plate_scale = read.call("uPlateScale", 2.6)
	r.crater = read.call("uCrater", 0.0)
	r.sea_km = read.call("uSeaKm", 0.0)
	# What it will draw, even while the map is still loading.
	r.map_kind = int(PlanetMaps.SOURCES[viz.body.name].kind) if PlanetMaps.has_map(viz.body.name) else 0
	r.mean_k = read.call("uMeanK", 288.0)
	r.s2 = read.call("uS2", -0.477)
	r.transport = read.call("uTransport", 0.42)
	r.arid = read.call("uArid", 0.0)
	r.frost_k = read.call("uFrostK", 273.0)
	r.ice = read.call("uIce", 0.0)
	r.season = read.call("uSeason", 8.0)
	r.biota = read.call("uBiota", 0.0)
	r.lapse = read.call("uLapse", 6.5)
	return r

# PCG3D (Jarzynski & Olano 2020). Integers are exact on both sides of the GPU.
static func _pcg_x(ix: int, iy: int, iz: int) -> int:
	var x := ((ix & M32) * 1664525 + 1013904223) & M32
	var y := ((iy & M32) * 1664525 + 1013904223) & M32
	var z := ((iz & M32) * 1664525 + 1013904223) & M32
	x = (x + y * z) & M32
	y = (y + z * x) & M32
	z = (z + x * y) & M32
	x ^= x >> 16; y ^= y >> 16; z ^= z >> 16
	x = (x + y * z) & M32
	return x

static func hash33(p: Vector3) -> Vector3:
	var f := p.floor()
	var x := ((int(f.x) & M32) * 1664525 + 1013904223) & M32
	var y := ((int(f.y) & M32) * 1664525 + 1013904223) & M32
	var z := ((int(f.z) & M32) * 1664525 + 1013904223) & M32
	x = (x + y * z) & M32
	y = (y + z * x) & M32
	z = (z + x * y) & M32
	x ^= x >> 16; y ^= y >> 16; z ^= z >> 16
	x = (x + y * z) & M32
	y = (y + z * x) & M32
	z = (z + x * y) & M32
	return Vector3(float(x >> 8), float(y >> 8), float(z >> 8)) / 16777216.0

static func noise(p: Vector3) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector3(3.0, 3.0, 3.0) - 2.0 * f)
	var ix := int(i.x); var iy := int(i.y); var iz := int(i.z)
	var c000 := float(_pcg_x(ix, iy, iz) >> 8)
	var c100 := float(_pcg_x(ix + 1, iy, iz) >> 8)
	var c010 := float(_pcg_x(ix, iy + 1, iz) >> 8)
	var c110 := float(_pcg_x(ix + 1, iy + 1, iz) >> 8)
	var c001 := float(_pcg_x(ix, iy, iz + 1) >> 8)
	var c101 := float(_pcg_x(ix + 1, iy, iz + 1) >> 8)
	var c011 := float(_pcg_x(ix, iy + 1, iz + 1) >> 8)
	var c111 := float(_pcg_x(ix + 1, iy + 1, iz + 1) >> 8)
	var a := lerpf(lerpf(c000, c100, f.x), lerpf(c010, c110, f.x), f.y)
	var b := lerpf(lerpf(c001, c101, f.x), lerpf(c011, c111, f.x), f.y)
	return lerpf(a, b, f.z) / 16777216.0

static func fbm(p: Vector3, oct: int) -> float:
	var v := 0.0
	var a := 0.5
	var q := p
	for i in oct:
		v += a * noise(q)
		q *= 2.03
		a *= 0.5
	return v

static func ridged(p: Vector3, oct: int) -> float:
	var v := 0.0
	var a := 0.5
	var q := p
	for i in oct:
		v += a * (1.0 - absf(noise(q) * 2.0 - 1.0))
		q *= 2.11
		a *= 0.5
	return v

static func warp(p: Vector3, amt: float) -> Vector3:
	return p + amt * Vector3(fbm(p + Vector3(19.3, 19.3, 19.3), 4), fbm(p + Vector3(41.7, 41.7, 41.7), 4), fbm(p + Vector3(73.1, 73.1, 73.1), 4))

static func sstep(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

static func _powf(x: float, k: float) -> float:
	return pow(x, k) if x > 0.0 else 0.0

## Height in km against the datum, and ruggedness: terrain() and its craters at unit `p`.
func height(p: Vector3) -> Vector2:
	var s3 := Vector3(seed, seed, seed)
	var q := warp(p * 1.9 + s3, 0.55)
	var c := fbm(q, 7) - crust_t
	var y := signf(c) * pow(minf(absf(c) / 0.34, 1.0), 0.55)
	var h := y * land_relief if y >= 0.0 else y * ocean_depth
	var detail := 0.9 if y >= 0.0 else 0.25
	var fine := (fbm(q * 5.3 + Vector3(3.1, 3.1, 3.1), 5) - 0.5) * 2.0
	h += fine * detail
	# tectonics
	var d1 := 8.0
	var d2 := 8.0
	var pl := p * plate_scale + s3 * 0.7
	var ip := pl.floor()
	var fp := pl - ip
	var c1 := pl
	var c2 := pl
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var g := Vector3(i, j, k)
				var cell := ip + g
				var hc := hash33(cell)
				var ff := g + hc - fp
				var d := ff.dot(ff)
				if d < d1:
					d2 = d1; c2 = c1; d1 = d; c1 = cell + hc
				elif d < d2:
					d2 = d; c2 = cell + hc
	d1 = sqrt(d1); d2 = sqrt(d2)
	var edge := d2 - d1
	var on_edge := 1.0 - sstep(0.0, 0.42, edge)
	var dir := (c2 - c1 + Vector3(1e-5, 1e-5, 1e-5)).normalized()
	var closing := (_plate_vel(c1, p) - _plate_vel(c2, p)).dot(dir)
	var land := sstep(-0.2, 0.6, h)
	var belt := ridged(warp(p * 7.0 + s3, 0.2), 5)
	belt = _powf(clampf(belt, 0.0, 1.0), 1.6)
	var conv := maxf(closing, 0.0) * on_edge
	h += belt * conv * lerpf(2.2, 7.0, land)
	var trench := sstep(0.06, 0.0, edge) * conv * (1.0 - land)
	h -= trench * 5.0
	var div := maxf(-closing, 0.0) * on_edge * (1.0 - land)
	h += div * (1.6 - 1.1 * sstep(0.10, 0.0, edge))
	var rug := clampf(belt * conv * 1.6 + absf(fine) * 0.4, 0.0, 1.0)
	if crater > 0.002:
		var ch := _craters(p, seed, crater)
		var k := clampf(crater, 0.0, 1.0)
		h = lerpf(h, h * 0.30 + ch, k)
		rug = lerpf(rug, clampf(absf(ch) * 0.8, 0.0, 1.0), k)
	return Vector2(h, rug)

static func _plate_vel(cell: Vector3, p: Vector3) -> Vector3:
	var v := hash33(cell + Vector3(5.17, 5.17, 5.17)) * 2.0 - Vector3.ONE
	return (v - p * v.dot(p) + Vector3(1e-5, 1e-5, 1e-5)).normalized()

static func _crater_layer(p: Vector3, s: float) -> float:
	var ip := p.floor()
	var fp := p - ip
	var h := 0.0
	var sv := Vector3(s, s, s)
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var g := Vector3(i, j, k)
				var r := hash33(ip + g + sv)
				if r.z > 0.55: continue
				var d := (g + r - fp).length()
				var rad := 0.18 + 0.26 * r.z
				var t := d / rad
				if t > 2.0: continue
				var bowl := -(1.0 - t * t) * 0.85 if t < 1.0 else 0.0
				var dr := (t - 1.0) * 3.4
				var de := (t - 1.45) * 2.0
				h += bowl + exp(-dr * dr) * 0.55 + exp(-de * de) * 0.10
	return h

static func _craters(p: Vector3, s: float, density: float) -> float:
	var sv := Vector3(s, s, s)
	var h := _crater_layer(p * 7.0 + sv, s) \
		+ _crater_layer(p * 15.0 + sv + Vector3(3.0, 3.0, 3.0), s + 3.0) * 0.5 \
		+ _crater_layer(p * 31.0 + sv + Vector3(7.0, 7.0, 7.0), s + 7.0) * 0.25
	return h * 1.6 * density

## crustHeight() for the rain shadow.
func crust_height(p: Vector3) -> float:
	var q := warp(p * 1.9 + Vector3(seed, seed, seed), 0.55)
	var c := fbm(q, 5) - crust_t
	var y := signf(c) * pow(minf(absf(c) / 0.34, 1.0), 0.55)
	return y * land_relief if y >= 0.0 else y * ocean_depth

## The annual-mean surface temperature the shader draws here, K, without the season. `alt_km` is
## altitude()'s.
func temperature(sin_lat: float, alt_km: float) -> float:
	var ins := maxf(1.0 + s2 * 0.5 * (3.0 * sin_lat * sin_lat - 1.0), 0.02)
	return maxf(mean_k * lerpf(pow(ins, 0.25), 1.0, transport) - lapse * alt_km, 2.7)

## The shader's altitude for the lapse rate, km: none at sea, from the sea on a wet world, from the
## datum on a dry one, and below either where the ground is.
func altitude(h_km: float, sea: bool) -> float:
	if sea: return 0.0
	return h_km - (sea_km if sea_km > -30.0 else 0.0)

## precipitation()'s mean over the sphere, on a Fibonacci lattice of `n` points, against which one
## place's share of the climate's rain is read. The coarse crust stands in for the full height here.
func mean_precipitation(n := 400) -> float:
	var sum := 0.0
	for i in n:
		var y := 1.0 - 2.0 * (i + 0.5) / n
		var ring := sqrt(maxf(1.0 - y * y, 0.0))
		var a := i * 2.399963229728653
		var p := Vector3(cos(a) * ring, y, sin(a) * ring)
		var h := crust_height(p)
		sum += precipitation(p, temperature(y, altitude(h, h < sea_km)), h)
	return sum / n

## precipitation(), 0..1, as the surface's biomes read it.
func precipitation(p: Vector3, t: float, h_km: float) -> float:
	var lat := asin(clampf(p.y, -1.0, 1.0))
	var a := absf(lat)
	var zi := a / 0.30
	var zf := (a - 0.90) / 0.40
	var zh := (a - 0.55) / 0.22
	var pp := clampf(0.30 + 0.75 * exp(-zi * zi) + 0.42 * exp(-zf * zf) - 0.42 * exp(-zh * zh) - 0.45 * sstep(1.00, 1.45, a), 0.0, 1.0)
	pp *= clampf(exp((t - 288.0) / 20.0), 0.05, 1.6)
	var inland := sstep(sea_km + 0.05, sea_km + 1.4, h_km)
	pp *= lerpf(1.0, 0.45, inland)
	var east := (Vector3.UP.cross(p) + Vector3(1e-6, 1e-6, 1e-6)).normalized()
	var probe := (p + east * (-0.04 if a < 0.52 else 0.04)).normalized()
	var shadow := clampf((crust_height(probe) - crust_height(p)) * 0.6, 0.0, 1.0)
	pp *= lerpf(1.0, 0.45, shadow)
	return clampf(pp * (1.0 - arid), 0.0, 1.0)
