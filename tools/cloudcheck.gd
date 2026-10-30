extends SceneTree

# Run with Godot --headless --path . --script res://tools/cloudcheck.gd.
# The flight cloud field's coverage is a physical quantity: the global fraction of
# columns under opaque cloud (vertical τ > 1) must match the world's cloudCover,
# and the zonal climatology must keep the subtropics clear and the storm tracks
# cloudy. Reads the same noise volumes LocalView builds, through CloudField.

var failures: Array[String] = []
var checks := 0

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

## CloudField.ready() reads the textures back after the worker thread builds them,
## which a headless run never does; build the same images here instead.
func field() -> CloudField:
	var shape := LocalView._noise3d(96, 2731, FastNoiseLite.TYPE_PERLIN, 0.035, 4, false)
	var worley := LocalView._noise3d(64, 977, FastNoiseLite.TYPE_CELLULAR, 0.05, 2, true)
	var detail := LocalView._noise3d(48, 4410, FastNoiseLite.TYPE_CELLULAR, 0.09, 3, true)
	var f := CloudField.new(shape, worley, detail)
	var vols := []
	for t: NoiseTexture3D in [shape, worley]:
		var imgs: Array = t.noise.get_seamless_image_3d(t.width, t.height, t.depth, t.invert,
			t.seamless_blend_skirt, t.normalize)
		var data := PackedByteArray()
		for im: Image in imgs:
			var c := im.duplicate() as Image
			if c.get_format() != Image.FORMAT_L8: c.convert(Image.FORMAT_L8)
			data.append_array(c.get_data())
		vols.append({"w": t.width, "h": t.height, "d": t.depth, "data": data})
	f._vol = vols
	f.base = LocalView.CLOUD_BASE; f.top = LocalView.CLOUD_TOP; f.sigma = LocalView.CLOUD_SIGMA
	return f

func opaque(f: CloudField, dir: Vector3) -> bool:
	var od := 0.0
	var n := 24
	var dh := (f.top - f.base) / n
	for j in n:
		od += f.density(dir * (f.radius + f.base + (j + 0.5) * dh)) * dh
	return od > 1.0

## Opaque fraction over random columns between |latitude| lo and hi (degrees),
## area-weighted (uniform on the sphere). North is −Y.
func fraction(f: CloudField, rng: RandomNumberGenerator, lo: float, hi: float, n: int) -> float:
	var hits := 0
	var got := 0
	var s0 := sin(deg_to_rad(lo)); var s1 := sin(deg_to_rad(hi))
	while got < n:
		var s := rng.randf_range(s0, s1) * (1.0 if rng.randf() < 0.5 else -1.0)
		var lon := rng.randf() * TAU
		var c := sqrt(1.0 - s * s)
		got += 1
		if opaque(f, Vector3(c * cos(lon), -s, c * sin(lon))): hits += 1
	return hits / float(n)

func _init() -> void:
	var f := field()
	expect(f.ready(), "cloud volumes were not built")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for cov in [0.3, 0.5, 0.7]:
		f.coverage = cov
		f.z_global = Terrain.cloud_global_z(cov)
		var g := fraction(f, rng, 0.0, 90.0, 3000)
		print("cloudCover %.2f → opaque %.3f" % [cov, g])
		expect(absf(g - cov) < 0.05, "cloudCover %.2f gives %.3f of the sky opaque" % [cov, g])
	f.coverage = 0.5
	f.z_global = Terrain.cloud_global_z(0.5)
	var itcz := fraction(f, rng, 0.0, 8.0, 1500)
	var sub := fraction(f, rng, 20.0, 32.0, 1500)
	var storm := fraction(f, rng, 50.0, 64.0, 1500)
	print("zonal at 0.5: ITCZ %.2f, subtropics %.2f, storm tracks %.2f" % [itcz, sub, storm])
	expect(sub < 0.40, "subtropical highs are %.2f cloudy" % sub)
	expect(storm > 0.62, "storm tracks are only %.2f cloudy" % storm)
	expect(itcz > sub + 0.15, "the ITCZ (%.2f) is not cloudier than the subtropics (%.2f)" % [itcz, sub])
	f.coverage = 0.0
	expect(f.density(Vector3(0.0, 0.0, f.radius + 3000.0)) == 0.0, "zero coverage still has cloud")
	for m in failures: printerr("CLOUDCHECK FAIL " + m)
	print("CLOUDCHECK DONE checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
