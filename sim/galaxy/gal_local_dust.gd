class_name GalLocalDust
extends RefCounted

# The measured dust around the Sun (assets/galaxy/local_dust.bin, built by
# tools/build_local_dust.py from Edenhofer et al. 2024): density on shells about the Sun, in
# cells even in galactic l and sin b (a quarter degree square in the plane), out to 1.25 kpc.
# Within it the map replaces the model's dust shell by shell (weight `wt`); the model's carries on
# beyond, so nothing is counted twice. The shells ride with the Sun (GalNeighbourhood.sun_frame).
# It is drawn as the far stars are, as seen from the Sun, and fades with them as the camera
# leaves it (GalNeighbourhood.FAR_FADE). GPU twin: gal_ld_at and step_through
# (shaders/galaxy/). docs/physics/galaxies.md.

const DATA := "res://assets/galaxy/local_dust.bin"
const VERSION := 1
## Zhang, Green & Rix (2023)'s extinction curve at 551 nm is 2.67 mag per unit E (their
## extinction_curve.txt, between its 542 and 552 nm rows); τ = A / 1.0857. E pc⁻¹ → τ_V kpc⁻¹.
const TAU_PER_E := 2.67 / 1.0857 * 1000.0
## The map's weight falls from 1 to 0 over the shells whose middles lie between these radii
## (kpc): its last fifth, where Edenhofer et al. trust it less, gives way to the model's.
const BLEND := Vector2(1.0, 1.25)

static var _cache := {}
static var _cache_mutex := Mutex.new()

static func available() -> bool:
	return FileAccess.file_exists(DATA)

## The map: w × h cells per shell, `r` the shells' outer radii (kpc), `wt` each shell's
## weight, `enc` (ln of the least density, its range) in τ_V kpc⁻¹, `q` the bytes with one
## column wrapped onto each side. Pure data, read once; empty without the asset.
static func bake() -> Dictionary:
	_cache_mutex.lock()
	var hit: Dictionary = _cache
	_cache_mutex.unlock()
	if not hit.is_empty(): return hit
	var out := _read()
	if out.is_empty(): return out
	_cache_mutex.lock()
	_cache = out
	_cache_mutex.unlock()
	return out

static func _read() -> Dictionary:
	if not available(): return {}
	var f := FileAccess.open(DATA, FileAccess.READ)
	if f == null or f.get_length() < 20 or f.get_buffer(4).get_string_from_ascii() != "ASLD": return {}
	if f.get_32() != VERSION: return {}
	var w := f.get_32()
	var h := f.get_32()
	var k := f.get_32()
	if w <= 0 or h <= 0 or k <= 0 or k > 32: return {}
	var r := PackedFloat32Array()
	for i in k: r.append(f.get_float() * 1e-3)
	var lnmin := f.get_float() + log(TAU_PER_E)
	var lnrange := f.get_float()
	var raw := f.get_buffer(f.get_length() - f.get_position()).decompress(w * h * k, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != w * h * k: return {}
	var q := PackedByteArray()
	for row in h * k:
		var src := row * w
		q.append(raw[src + w - 1])
		q.append_array(raw.slice(src, src + w))
		q.append(raw[src])
	var wt := PackedFloat32Array()
	for i in k:
		var mid := 0.5 * ((r[i - 1] if i > 0 else 0.0) + r[i])
		wt.append(1.0 - smoothstep(BLEND.x, BLEND.y, mid))
	return {"w": w, "h": h, "k": k, "r": r, "wt": wt, "enc": Vector2(lnmin, lnrange), "q": q}

## The shells as a texture array for the shaders: R8, one layer a shell, so a read filters
## within its shell only.
static func texture(m: Dictionary) -> Texture2DArray:
	var wp: int = int(m.w) + 2
	var h: int = m.h
	var layers: Array[Image] = []
	for s in int(m.k):
		layers.append(Image.create_from_data(wp, h, false, Image.FORMAT_R8, (m.q as PackedByteArray).slice(s * wp * h, (s + 1) * wp * h)))
	var t := Texture2DArray.new()
	t.create_from_images(layers)
	return t

## The map's share at a camera `dist` kpc from the Sun: the far stars' fade.
static func fade(dist: float) -> float:
	return 1.0 - smoothstep(GalNeighbourhood.FAR_FADE.x, GalNeighbourhood.FAR_FADE.y, dist)

## The shell holding radius `r` (kpc), or −1 beyond the map.
static func shell(m: Dictionary, r: float) -> int:
	var rs: PackedFloat32Array = m.r
	for i in rs.size():
		if r < rs[i]: return i
	return -1

## The map's density (τ_V kpc⁻¹) at `s`, a point in the Sun's frame (kpc).
static func density(m: Dictionary, s: Vector3) -> float:
	var r := s.length()
	var k := shell(m, r)
	if k < 0: return 0.0
	return density_toward(m, s / maxf(r, 1e-12), k)

## Shell k's density (τ_V kpc⁻¹) toward the unit direction `u` in the Sun's frame, as the shader's
## bilinear lookup reads it: linear in the cell's byte across l and sin b, then decoded.
static func density_toward(m: Dictionary, u: Vector3, k: int) -> float:
	var w: int = m.w
	var h: int = m.h
	var wp := w + 2
	var l := fposmod(atan2(-u.z, u.x), TAU) / TAU
	var x := l * float(w) + 0.5
	var y := 0.5 * (1.0 - clampf(u.y, -1.0, 1.0)) * float(h) - 0.5
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var fx := x - float(x0)
	var fy := y - float(y0)
	var q: PackedByteArray = m.q
	var base := k * wp * h
	var ya := clampi(y0, 0, h - 1)
	var yb := clampi(y0 + 1, 0, h - 1)
	var xa := clampi(x0, 0, wp - 1)
	var xb := clampi(x0 + 1, 0, wp - 1)
	var top := lerpf(float(q[base + ya * wp + xa]), float(q[base + ya * wp + xb]), fx)
	var bot := lerpf(float(q[base + yb * wp + xa]), float(q[base + yb * wp + xb]), fx)
	var v := lerpf(top, bot, fy) / 255.0
	var enc: Vector2 = m.enc
	return exp(enc.x + enc.y * v)
