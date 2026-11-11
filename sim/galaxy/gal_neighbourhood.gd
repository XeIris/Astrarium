class_name GalNeighbourhood
extends RefCounted

# The real stars around the Sun, in three dimensions (assets/sky/neighbourhood.bin, built
# by tools/build_neighbourhood.py from Gaia DR3, Hipparcos and BSC5). Two sets:
# - near: every star within NEAR_KPC of the Sun brighter than the scene's resolved limit,
#   M_V_RESOLVED. Where the camera's resolved sphere overlaps it, these replace the
#   procedural lattice; the glow already gives up the resolved stars' light there.
# - far: the rest of the Solar System sky's own stars (V ≤ 8 from the Sun), at their
#   measured distances, a few faint red dwarfs within 40 pc among them. The glow gives up their light as a map smoothed over SMOOTH_DEG,
#   seen from the Sun; both fade out as the camera leaves the Sun (FAR_FADE), because
#   a sample complete to V = 8 from the Sun is not one from anywhere else.
# The set rides with the Sun, which turns with its ring of the lattice at Ω(R0).
# docs/physics/galaxies.md.

const DATA := "res://assets/sky/neighbourhood.bin"
const VERSION := 1
const NEAR_KPC := 0.04
## tools/build_neighbourhood.py's cut: the model's 0.5 M☉ main-sequence star.
const M_V_RESOLVED := 8.541
## Bennett & Bovy (2019): the Sun stands 20.8 pc above the Galactic mid-plane.
const SUN_HEIGHT := 0.0208
## The far set's weight falls from 1 to 0 as the camera goes from 10 to 30 pc from the Sun.
const FAR_FADE := Vector2(0.01, 0.03)
## The far set's light map: galactic (l, b) on MAP_W × MAP_H, smoothed with a Gaussian of
## SMOOTH_DEG. Real bright stars clump more than the model's light: at 4° the glow ran out
## around Orion and went dark, at 12° it never does (galaxycheck).
const MAP_W := 256
const MAP_H := 128
const SMOOTH_DEG := 12.0

static var _cache := {}
static var _cache_mutex := Mutex.new()

static func available() -> bool:
	return FileAccess.file_exists(DATA)

## A V magnitude's visible luminosity in Sun-luminances (M_V☉ = 4.83, the K calibration's).
static func l_vis(mv: float) -> float:
	return pow(10.0, -0.4 * (mv - 4.83))

## The stars and the far set's light map: pure data, safe on a worker, read once.
## Empty without the asset or with a malformed one.
static func bake() -> Dictionary:
	_cache_mutex.lock()
	var hit: Dictionary = _cache
	_cache_mutex.unlock()
	if not hit.is_empty(): return hit
	var out := _read()
	if out.is_empty(): return out
	out.map = _far_map(out)
	_cache_mutex.lock()
	_cache = out
	_cache_mutex.unlock()
	return out

static func _read() -> Dictionary:
	if not available(): return {}
	var f := FileAccess.open(DATA, FileAccess.READ)
	if f == null or f.get_length() < 16 or f.get_buffer(4).get_string_from_ascii() != "ASNB": return {}
	var version := f.get_32()
	var n_near := f.get_32()
	var n_far := f.get_32()
	var n := n_near + n_far
	if version != VERSION or n <= 0 or f.get_length() != 16 + n * 24: return {}
	var pos := PackedVector3Array()
	var mv := PackedFloat32Array()
	var bv := PackedFloat32Array()
	var src := PackedByteArray()
	pos.resize(n)
	mv.resize(n)
	bv.resize(n)
	src.resize(n)
	for i in n:
		# pc on disk, kpc here.
		pos[i] = Vector3(f.get_float(), f.get_float(), f.get_float()) * 1e-3
		mv[i] = f.get_float()
		bv[i] = f.get_float()
		src[i] = int(f.get_float())
	return {"n_near": n_near, "n_far": n_far, "pos": pos, "mv": mv, "bv": bv, "src": src}

## A star's colour as the scene draws light: visible light per unit luminance.
static func colour(bv: float) -> Color:
	var c := GalPopulation.visible(BrightStars.bv_teff(bv if is_finite(bv) else 0.65))
	var y := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	return c / maxf(y, 1e-6)

## Galactic (l, b) in radians of a direction on the Sun's axes (+x the centre, +y the
## pole, +z toward l = 270°).
static func galactic(d: Vector3) -> Vector2:
	var u := d.normalized()
	return Vector2(fposmod(atan2(-u.z, u.x), TAU), asin(clampf(u.y, -1.0, 1.0)))

## The far set's radiance seen from the Sun (Sun-luminance kpc⁻² sr⁻¹ per channel),
## smoothed: binned, blurred along b and then along l with a width growing as 1/cos b.
## Both passes keep each bin's flux, so the map integrates to the set's flux.
static func _far_map(d: Dictionary) -> Image:
	var flux := []
	for c in 3:
		var a := PackedFloat64Array()
		a.resize(MAP_W * MAP_H)
		flux.append(a)
	var n0: int = d.n_near
	for i in range(n0, n0 + int(d.n_far)):
		var p: Vector3 = d.pos[i]
		var r2 := p.length_squared()
		if r2 <= 0.0: continue
		var lb := galactic(p)
		var ix := clampi(int(lb.x / TAU * MAP_W), 0, MAP_W - 1)
		var iy := clampi(int((0.5 - lb.y / PI) * MAP_H), 0, MAP_H - 1)
		var f := l_vis(d.mv[i]) / (4.0 * PI * r2)
		var col := colour(d.bv[i])
		for c in 3:
			flux[c][iy * MAP_W + ix] += f * col[c]
	var dl := TAU / MAP_W
	var db := PI / MAP_H
	var sig := deg_to_rad(SMOOTH_DEG)
	# Along b: a fixed kernel, reflected at the poles.
	var kb := _kernel(sig / db, MAP_H)
	for c in 3:
		var a: PackedFloat64Array = flux[c]
		var out := PackedFloat64Array()
		out.resize(MAP_W * MAP_H)
		for x in MAP_W:
			for y in MAP_H:
				var v: float = a[y * MAP_W + x]
				if v == 0.0: continue
				for k in kb.size():
					var yy := y + k - (kb.size() - 1) / 2
					if yy < 0: yy = -yy - 1
					if yy >= MAP_H: yy = 2 * MAP_H - yy - 1
					out[yy * MAP_W + x] += v * kb[k]
		flux[c] = out
	# Along l: the same angle on the sky is 1/cos b times as many bins, wrapped.
	var img := Image.create_empty(MAP_W, MAP_H, false, Image.FORMAT_RGBF)
	var rows := []
	for y in MAP_H:
		var b := (0.5 - (float(y) + 0.5) / MAP_H) * PI
		rows.append(_kernel(sig / (dl * maxf(cos(b), 1e-3)), MAP_W))
	var res := [PackedFloat64Array(), PackedFloat64Array(), PackedFloat64Array()]
	for c in 3:
		res[c].resize(MAP_W * MAP_H)
		var a: PackedFloat64Array = flux[c]
		for y in MAP_H:
			var kl: PackedFloat64Array = rows[y]
			var h := (kl.size() - 1) / 2
			for x in MAP_W:
				var v: float = a[y * MAP_W + x]
				if v == 0.0: continue
				for k in kl.size():
					var xx := posmod(x + k - h, MAP_W)
					res[c][y * MAP_W + xx] += v * kl[k]
	for y in MAP_H:
		var b := (0.5 - (float(y) + 0.5) / MAP_H) * PI
		var sr := dl * db * cos(b)
		for x in MAP_W:
			var i := y * MAP_W + x
			img.set_pixel(x, y, Color(res[0][i] / sr, res[1][i] / sr, res[2][i] / sr))
	return img

## A normalised Gaussian of `sigma` bins over at most `limit` bins.
static func _kernel(sigma: float, limit: int) -> PackedFloat64Array:
	var h := mini(int(ceil(3.0 * sigma)), (limit - 1) / 2)
	var k := PackedFloat64Array()
	k.resize(2 * h + 1)
	var s := 0.0
	for i in k.size():
		var x := float(i - h)
		k[i] = exp(-0.5 * x * x / maxf(sigma * sigma, 1e-12))
		s += k[i]
	for i in k.size(): k[i] /= s
	return k

## The far map's integral over the sky: the set's flux, for the checks.
static func map_flux(img: Image) -> Color:
	var s := Color(0, 0, 0)
	var dl := TAU / MAP_W
	var db := PI / MAP_H
	for y in MAP_H:
		var sr := dl * db * cos((0.5 - (float(y) + 0.5) / MAP_H) * PI)
		for x in MAP_W:
			s += img.get_pixel(x, y) * sr
	return s

## The Sun at t (galaxy-local kpc): it turns with its ring at Ω(R0) = vc(R0)/R0 from
## azimuth π, as the lattice's rings do. Returns [position, its axes' basis].
static func sun_frame(r0: float, omega: float, t_myr: float) -> Array:
	var phi := PI + omega * t_myr
	var pos := Vector3(r0 * cos(phi), SUN_HEIGHT, r0 * sin(phi))
	# +x toward the centre, +y the pole, +z against the rotation (the Galaxy turns toward −z).
	var ex := Vector3(-cos(phi), 0.0, -sin(phi))
	var ez := Vector3(sin(phi), 0.0, -cos(phi))
	return [pos, Basis(ex, Vector3.UP, ez)]
