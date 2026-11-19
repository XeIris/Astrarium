class_name GalLocalDust
extends RefCounted

# The measured dust around the Sun (assets/galaxy/local_dust.bin, built by
# tools/build_local_dust.py from Edenhofer et al. 2024): density on shells about the Sun, in
# cells even in galactic l and sin b (a quarter degree square in the plane), out to 1.25 kpc.
# Within it the map replaces the model's dust shell by shell (weight `wt`); the model's carries on
# beyond, so nothing is counted twice. The shells ride with the Sun (GalNeighbourhood.sun_frame).
# It is drawn as the far stars are, as seen from the Sun, and fades with them as the camera
# leaves it (GalNeighbourhood.FAR_FADE); from there on the same map on a 3D grid (GRID_DATA)
# takes over. GPU twin: gal_ld_at, gal_ld3 (shaders/galaxy/). docs/physics/galaxies.md.

const DATA := "res://assets/galaxy/local_dust.bin"
const VERSION := 1
## The same map on a 3D grid in the Sun's frame (tools/build_local_dust_grid.py), for cameras
## away from the Sun, where the shells' view from it no longer holds.
const GRID_DATA := "res://assets/galaxy/local_dust_grid.bin"
const GRID_VERSION := 1
## Zhang, Green & Rix (2023)'s extinction curve at 551 nm is 2.67 mag per unit E (their
## extinction_curve.txt, between its 542 and 552 nm rows); τ = A / 1.0857. E pc⁻¹ → τ_V kpc⁻¹.
const TAU_PER_E := 2.67 / 1.0857 * 1000.0
## The map's weight falls from 1 to 0 over the shells whose middles lie between these radii
## (kpc): its last fifth, where Edenhofer et al. trust it less, gives way to the model's.
const BLEND := Vector2(1.0, 1.25)

## The most shells the shaders hold (gal_model.gdshaderinc LD_MAX), and bounds on what a file
## may ask to be decompressed.
const MAX_SHELLS := 17
const MAX_CELLS := 1 << 26
const MAX_GRID_LEVELS := 2

static var _cache := {}
static var _tried := false
static var _cache_mutex := Mutex.new()

static func available() -> bool:
	return FileAccess.file_exists(DATA)

## The map: w × h cells per shell, `r` the shells' outer radii (kpc), `wt` each shell's
## weight, `enc` (ln of the least density, its range) in τ_V kpc⁻¹, `q` the bytes with one
## column wrapped onto each side. Pure data, read once; empty without the asset.
static func bake() -> Dictionary:
	_cache_mutex.lock()
	var hit: Dictionary = _cache
	var tried := _tried
	_cache_mutex.unlock()
	# A missing or malformed file is read once, not again on every visit.
	if tried: return hit
	var out := _read()
	_cache_mutex.lock()
	_cache = out
	_tried = true
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
	if w <= 0 or h <= 0 or k <= 0 or k > MAX_SHELLS or w > 16384 or h > 16384 or w * h * k > MAX_CELLS: return {}
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
	return {"w": w, "h": h, "k": k, "r": r, "wt": wt, "enc": Vector2(lnmin, lnrange), "q": q, "grid": _read_grid()}

## The grid: `levels`, outermost first, each with `n` its cubes along x, y, z, `cell` their side
## (kpc), `half` its box's half extents (kpc) and `rho` its density (τ_V kpc⁻¹; z slab by slab, y
## rows from the south, x fastest), decoded here so that it is interpolated linearly: in ln ρ
## the steep contrasts between cubes would lose 5 % of the dust. Empty without the asset or with
## a malformed one.
static func _read_grid() -> Dictionary:
	if not FileAccess.file_exists(GRID_DATA): return {}
	var f := FileAccess.open(GRID_DATA, FileAccess.READ)
	if f == null or f.get_length() < 32 or f.get_buffer(4).get_string_from_ascii() != "ASLG": return {}
	if f.get_32() != GRID_VERSION: return {}
	var nl := f.get_32()
	if nl <= 0 or nl > MAX_GRID_LEVELS: return {}
	var levels := []
	var size := 0
	for i in nl:
		var n := Vector3i(f.get_32(), f.get_32(), f.get_32())
		var cell := f.get_float() * 1e-3
		if n.x <= 0 or n.y <= 0 or n.z <= 0 or n.x > 4096 or n.y > 4096 or n.z > 4096 or not (cell > 0.0): return {}
		levels.append({"n": n, "cell": cell, "half": Vector3(n) * cell * 0.5, "at": size})
		size += n.x * n.y * n.z
		if size > MAX_CELLS: return {}
	var lnmin := f.get_float() + log(TAU_PER_E)
	var lnrange := f.get_float()
	var raw := f.get_buffer(f.get_length() - f.get_position()).decompress(size, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != size: return {}
	# Byte 0 is the least density, as the shells' bytes decode.
	var lut := PackedFloat32Array()
	for q in 256: lut.append(exp(lnmin + lnrange * q / 255.0))
	for lv in levels:
		var n: Vector3i = lv.n
		var rho := PackedFloat32Array()
		rho.resize(n.x * n.y * n.z)
		var at: int = lv.at
		for c in rho.size(): rho[c] = lut[raw[at + c]]
		lv.erase("at")
		lv.mips = _mips(n, rho)
	return {"levels": levels}

## A level's mipmaps as a GPU builds them, each halving every axis (rounding down) and averaging
## the density over the 2×2×2 cubes it keeps: [{n, rho}], the full level first.
static func _mips(n: Vector3i, rho: PackedFloat32Array) -> Array:
	var out := [{"n": n, "rho": rho}]
	while n != Vector3i.ONE:
		var h := Vector3i(maxi(n.x / 2, 1), maxi(n.y / 2, 1), maxi(n.z / 2, 1))
		var half := PackedFloat32Array()
		half.resize(h.x * h.y * h.z)
		for k in h.z:
			for j in h.y:
				for i in h.x:
					var acc := 0.0
					var cnt := 0
					for c in 8:
						var x := 2 * i + (c & 1)
						var y := 2 * j + ((c >> 1) & 1)
						var z := 2 * k + ((c >> 2) & 1)
						if x < n.x and y < n.y and z < n.z:
							acc += rho[(z * n.y + y) * n.x + x]
							cnt += 1
					half[(k * h.y + j) * h.x + i] = acc / cnt
		rho = half
		n = h
		out.append({"n": n, "rho": rho})
	return out

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

## Each grid level as the shaders read it: half floats, filtered on any GPU, one image a z slab,
## with its mipmaps, so that a step reads the grid averaged over its own length; empty without
## the grid.
static func grid_textures(m: Dictionary) -> Array[ImageTexture3D]:
	var out: Array[ImageTexture3D] = []
	for lv: Dictionary in (m.get("grid", {}) as Dictionary).get("levels", []):
		var slabs: Array[Image] = []
		for mp: Dictionary in lv.mips:
			var n: Vector3i = mp.n
			var bytes := (mp.rho as PackedFloat32Array).to_byte_array()
			for k in n.z:
				var img := Image.create_from_data(n.x, n.y, false, Image.FORMAT_RF, bytes.slice(4 * k * n.x * n.y, 4 * (k + 1) * n.x * n.y))
				img.convert(Image.FORMAT_RH)
				slabs.append(img)
		var t := ImageTexture3D.new()
		var nn: Vector3i = lv.n
		t.create(Image.FORMAT_RH, nn.x, nn.y, nn.z, true, slabs)
		out.append(t)
	return out

## The grid's weight against the model's dust at `r` kpc from the Sun: the shells' blend, by the
## point's own radius. With `foot`, widened by it: what the glow's jittered steps that long give
## on average, where a step past the blend falls wholly in or out of the map.
static func grid_weight(r: float, foot := 0.0) -> float:
	return 1.0 - smoothstep(BLEND.x - 0.5 * foot, BLEND.y + 0.5 * foot, r)

## A finer level gives way to the next over this margin inside its box (kpc), so its edge
## draws no seam.
const GRID_MARGIN := 0.025

## The grid's density (τ_V kpc⁻¹) at `s`, a point in the Sun's frame (kpc), as the shader reads
## it for a step `foot` kpc long: each level at the mipmap whose cubes are that long, trilinear
## within and linear between mipmaps; the finest level holding `s`, blended into the next over
## GRID_MARGIN; 0 outside the outermost box.
static func grid_density(m: Dictionary, s: Vector3, foot := 0.0) -> float:
	var levels: Array = (m.get("grid", {}) as Dictionary).get("levels", [])
	if levels.is_empty(): return 0.0
	var v := _grid_lod(levels[0], s, foot)
	if v < 0.0: return 0.0
	for i in range(1, levels.size()):
		var half: Vector3 = levels[i].half
		var t := clampf(minf(minf(half.x - absf(s.x), half.y - absf(s.y)), half.z - absf(s.z)) / GRID_MARGIN, 0.0, 1.0)
		if t <= 0.0: break
		v = lerpf(v, _grid_lod(levels[i], s, foot), t)
	return v

## A level read for a step `foot` kpc long; −1 outside it.
static func _grid_lod(lv: Dictionary, s: Vector3, foot: float) -> float:
	var half: Vector3 = lv.half
	if absf(s.x) > half.x or absf(s.y) > half.y or absf(s.z) > half.z: return -1.0
	var mips: Array = lv.mips
	var lod := clampf(log(maxf(foot, 1e-12) / float(lv.cell)) / log(2.0), 0.0, float(mips.size() - 1))
	var l0 := int(floor(lod))
	var a := _grid_at(mips[l0], half, s)
	if l0 + 1 >= mips.size() or lod == float(l0): return a
	return lerpf(a, _grid_at(mips[l0 + 1], half, s), lod - float(l0))

## A mipmap's density at `s` (kpc, Sun frame), trilinear as a GPU's filter reads it.
static func _grid_at(lv: Dictionary, half: Vector3, s: Vector3) -> float:
	var n: Vector3i = lv.n
	var u := (s / (2.0 * half) + Vector3(0.5, 0.5, 0.5)) * Vector3(n) - Vector3(0.5, 0.5, 0.5)
	var i0 := Vector3i(int(floor(u.x)), int(floor(u.y)), int(floor(u.z)))
	var fr := u - Vector3(i0)
	var q: PackedFloat32Array = lv.rho
	var v := 0.0
	for c in 8:
		var dx := c & 1
		var dy := (c >> 1) & 1
		var dz := (c >> 2) & 1
		var ix := clampi(i0.x + dx, 0, n.x - 1)
		var iy := clampi(i0.y + dy, 0, n.y - 1)
		var iz := clampi(i0.z + dz, 0, n.z - 1)
		v += (fr.x if dx else 1.0 - fr.x) * (fr.y if dy else 1.0 - fr.y) * (fr.z if dz else 1.0 - fr.z) * float(q[(iz * n.y + iy) * n.x + ix])
	return v

## The dust's shares at a point (model, shells, grid) from the shells' weight there (f W) and the
## grid's ((1 − f) W_r): the measured dust takes its own, and the model's has what is left, so no
## point counts any twice. The glow's march and gal_dust_joined compose the same way.
static func shares(w_shell: float, w_grid: float) -> Vector3:
	return Vector3(maxf(1.0 - w_shell - w_grid, 0.0), w_shell, w_grid)

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
