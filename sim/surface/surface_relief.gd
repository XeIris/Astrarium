class_name SurfaceRelief
extends RefCounted

# The ground at a pin: the crust the planet is drawn with, its local roughness scaled to the world's
# gravity, then carved by the stream-power law with the world's rain and gravity, or left to impacts
# and creep if nothing flows. Grids in SiteScene's form, [{n, half, h}], near first, so its sample and
# mesh serve both. Runs on a worker thread and allocates only there.
# docs/physics/surface.md#terrain. SI. Exists only while someone stands on the world.

# Reach of the far and near grids, m, on an Earth; smaller worlds' far grid shrinks with them.
const FAR_HALF := 60000.0
const NEAR_HALF := 3200.0
# Coarse samples of the true crust across the far grid. One costs about 0.5 ms in GDScript; what it
# adds is up to the shader's highest octave, about 40 km on an Earth.
const CRUST_SAMPLES := 21
# dz/dt = U − K A^m S^n + D∇²z. m/n ≈ 0.5 is the concavity rivers show (Whipple & Tucker 1999), and
# n = 1 is specific stream power (Howard 1994). K is an estimate: about 1 mm/yr at 100 km² on a 5%
# slope under Earth's rain, a typical active range.
const STREAM_M := 0.5
const K_EARTH := 2.0e-6              # m^(1 − 2m) yr⁻¹
const G_EARTH := 9.82
const RAIN_EARTH := 990.0            # mm/yr
# Soil creep, m²/yr: field values run 1e-3 to 1e-2 (MIT 12.163 notes, after Dietrich and others).
const CREEP := 5.0e-3
const CREEP_DRY := 1.0e-4            # gardening alone; an estimate
# A landscape's worth of work: long against a hillslope's response, short against tectonics.
const SPAN_YEARS := 2.0e6
const STEPS := 20
const ROUTE_EVERY := 4
# Earth's mountains stand 9 km; strength over ρg caps them (Mars's 22 km ÷ Earth's 8.8 km = 2.5,
# gravity's ratio is 2.6). Local roughness scales with it.
const ROUGH_M := 900.0
const MAX_ROUGH := 4.0
# How far to the map's side of a coast the pin is put when a measured cell says otherwise, m.
const COAST_M := 5.0
# A measured world with nothing flowing: the Hurst exponent H of its height increments, ν(L) ∝ L^H,
# carries the measured cell's own roughness down below the cell, instead of an Earth-scaled field drawn
# on top of relief the cell already holds. The Moon: Rosenburg et al. 2011 (LOLA, 17 m–2.7 km baselines)
# give medians of 0.76 in the maria and 0.95 in the highlands; 0.85 is between. Mars: Orosei et al. 2003
# (MOLA) find H > 0.5 over most of the surface; 0.8 is an estimate within that.
const HURST := {"Moon": 0.85, "Mars": 0.80}
# The lag the added field is calibrated at, in its grid's cells.
const CAL_LAG := 2

# Inputs.
var relief: PlanetRelief
var center := Vector3.UP            # unit, mesh frame
var east := Vector3.RIGHT
var north := Vector3.FORWARD
var radius_m := 6.371e6
var g := 9.82
var sea_m := 0.0                    # m above the crust's datum
var has_sea := false                # whether anything is base level but the rim
var rain_mm := 0.0                  # mm/yr, 0 for no running water
var flowing := false
var crater := 0.0
var map_land := -1                  # 1 land, 0 sea when a map says, else the crust does
## The world's stated land relief against the crust's default 3.2 km, or < 0 where it is not stated. A stated
## relief already holds what strength and erosion made of a world, so its roughness scales with it, not with
## 1/g (Titan's 1 km is far gentler than its gravity alone would allow).
var relief_scale := -1.0
## A stated dune field ({height, width, spacing, bearing, band}: m, m, m, degrees from north, degrees of latitude),
## or empty.
var dunes := {}
## The pin's latitude, rad, for the dune band.
var lat := 0.0
## A world whose seas are stated (StatedSeas), or "": under a mare the floor is its depth, off it the land
## the crust has, kept above the datum.
var stated := ""
## Measured height in place of the crust's, m from sea level (or the datum on a dry world); loaded
## by the caller on the main thread.
var elevation: PlanetElevation = null
## Whether the map's coast is within a measured cell of the pin; only there does the grid bend to it.
var map_coastal := false
var rain_index := -1.0              # the pin's precipitation(), 0..1, or < 0 for none
## HURST's for a measured dry world, else 0 and the gravity-scaled roughness.
var hurst := 0.0
var seed := 0
var cells := 129
# Outputs.
var grids: Array = []
var channel_far := PackedFloat32Array()
var channel_near := PackedFloat32Array()

var cancelled := false
var progress := 0.0
var stats := {}
## The world's mean precipitation(), for the pin's share of its rain; < 0 until built.
var rain_index_mean := -1.0
# Work arrays, kept while a grid is carved.
var _n := 0
var _dx := 0.0
var _h := PackedFloat32Array()
var _recv := PackedInt32Array()
var _stack := PackedInt32Array()
var _area := PackedFloat32Array()
var _base := PackedByteArray()
var _kids := PackedInt32Array()
var _kid_n := PackedInt32Array()

## What K is here: Earth's, by the gravity in stream power (ω = ρgQS/W) and the rain in its discharge.
func erodibility() -> float:
	if not flowing or rain_mm <= 0.0: return 0.0
	return K_EARTH * (g / G_EARTH) * pow(rain_mm / RAIN_EARTH, STREAM_M)

## All of it. Safe on a worker thread: reads its inputs and writes its outputs.
func build() -> void:
	SurfaceStats.count("relief_build")
	var far_half := minf(FAR_HALF, radius_m * 0.08)
	var near_half := minf(NEAR_HALF, far_half * 0.25)
	if rain_index >= 0.0 and relief != null: rain_index_mean = relief.mean_precipitation(elevation)
	var far := _grid_from_crust(far_half)
	if cancelled: return
	progress = 0.1
	var measured := hurst > 0.0 and elevation != null
	var cell := elevation.cell_rad() * radius_m if measured else 0.0
	if measured:
		stats.cell_m = cell
		stats.cell_roughness_m = cell_roughness()
		_add_fractal(far, far_half, cell, seed)
		# Craters wider than a cell are in the measured grid already.
		if crater > 0.02: _stamp_craters(far, far_half, seed + 1, cell * 0.5)
	else:
		# Strength over ρg, up to where a small world's own size has more to say than its gravity.
		var strength := strength()
		_add_roughness(far, far_half, far_half / 6.0, ROUGH_M * strength, seed)
		if crater > 0.02: _stamp_craters(far, far_half, seed + 1)
	_add_dunes(far, far_half)
	channel_far = _carve(far, far_half, 0.1, 0.55, true)
	if cancelled: return
	var near := _grid_inside(far, far_half, near_half)
	if measured:
		_add_fractal(near, near_half, 2.0 * far_half / (cells - 1), seed + 7)
	else:
		_add_roughness(near, near_half, near_half / 4.0, 0.1 * ROUGH_M * strength(), seed + 7)
	if crater > 0.02: _stamp_craters(near, near_half, seed + 11)
	# The near grid is drawn from the far one, dunes and all: its own at full resolution replace them.
	_add_dunes(near, near_half, far_half)
	channel_near = _carve(near, near_half, 0.55, 1.0, false)
	if cancelled: return
	if not has_sea: _ramp_rim(far)
	grids = [{"n": cells, "half": near_half, "h": near}, {"n": cells, "half": far_half, "h": far}]
	progress = 1.0

# Unit direction at metres east and north of the pin, on the ball.
func _dir(e: float, n: float) -> Vector3:
	return (center * radius_m + east * e + north * n).normalized()

func _grid_from_crust(half: float) -> PackedFloat32Array:
	var m := CRUST_SAMPLES
	var coarse := PackedFloat32Array()
	coarse.resize(m * m)
	for j in m:
		for i in m:
			if cancelled: return coarse
			var e := -half + 2.0 * half * i / (m - 1)
			var n := -half + 2.0 * half * j / (m - 1)
			if elevation != null:
				var ll := PlanetPin.lat_lon(_dir(e, n))
				coarse[j * m + i] = elevation.at(ll.x, ll.y)
			else:
				coarse[j * m + i] = (relief.height(_dir(e, n)).x * 1000.0) - sea_m
				if stated != "": coarse[j * m + i] = _stated_height(_dir(e, n), coarse[j * m + i])
		progress = 0.1 * float(j + 1) / m
	if elevation != null:
		_keep_map_coast(coarse, m, 2.0 * half / (m - 1))
	# A map's coast says which side of the sea this is, whatever the crust does.
	elif map_land >= 0:
		for k in coarse.size():
			coarse[k] = absf(coarse[k]) * (1.0 if map_land == 1 else -1.0)
	var out := PackedFloat32Array()
	out.resize(cells * cells)
	var scale := float(m - 1) / float(cells - 1)
	for j in cells:
		var v := j * scale
		var j0 := mini(int(v), m - 2)
		var ty := v - j0
		ty = ty * ty * (3.0 - 2.0 * ty)
		for i in cells:
			var u := i * scale
			var i0 := mini(int(u), m - 2)
			var tx := u - i0
			tx = tx * tx * (3.0 - 2.0 * tx)
			out[j * cells + i] = lerpf(lerpf(coarse[j0 * m + i0], coarse[j0 * m + i0 + 1], tx), lerpf(coarse[(j0 + 1) * m + i0], coarse[(j0 + 1) * m + i0 + 1], tx), ty)
	return out

# On a world with stated seas: the mare's floor under it, and off it the crust's land, rising from the shore
# over SHORE_RISE so a coast is a beach, not the crust's height cut off.
const SHORE_RISE := 20.0e3

func _stated_height(d: Vector3, crust_m: float) -> float:
	var ll := PlanetPin.lat_lon(d)
	var mare := StatedSeas.at(stated, ll.x, ll.y, radius_m, INF)
	if mare.is_empty(): return absf(crust_m) + COAST_M
	var inside := float(mare.inside)
	if inside > 0.0: return -maxf(float(mare.depth), COAST_M)
	return absf(crust_m) * (1.0 - exp(inside / SHORE_RISE)) + COAST_M

# A measured cell averages across a coast; the map, which is finer, says which side the pin is on.
# Only the pin's own neighbourhood moves, over one measured cell, to a few metres on the map's side.
func _keep_map_coast(coarse: PackedFloat32Array, m: int, step: float) -> void:
	if map_land < 0 or not has_sea or not map_coastal: return
	var c := m / 2
	var here := coarse[c * m + c]
	var want := maxf(here, COAST_M) if map_land == 1 else minf(here, -COAST_M)
	if want == here: return
	var reach := elevation.cell_rad() * radius_m
	for j in m:
		for i in m:
			var d2 := (pow((i - c) * step, 2.0) + pow((j - c) * step, 2.0)) / (reach * reach)
			coarse[j * m + i] += (want - here) * exp(-d2)

func _grid_inside(far: PackedFloat32Array, far_half: float, half: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(cells * cells)
	var step := 2.0 * half / (cells - 1)
	var cf := float(cells - 1) / (2.0 * far_half)
	for j in cells:
		var fy := (-half + j * step + far_half) * cf
		var j0 := mini(int(fy), cells - 2)
		var ty := fy - j0
		for i in cells:
			var fx := (-half + i * step + far_half) * cf
			var i0 := mini(int(fx), cells - 2)
			var tx := fx - i0
			out[j * cells + i] = lerpf(lerpf(far[j0 * cells + i0], far[j0 * cells + i0 + 1], tx), lerpf(far[(j0 + 1) * cells + i0], far[(j0 + 1) * cells + i0 + 1], tx), ty)
	return out

## A dune's crest factor, 0–1, at (east, north) `p` m: the profile ground.gdshader shades past the near grid,
## its meander the same gradient noise on the same hash, so the carved crests and the shaded ones are one field.
static func dune_ridge(p: Vector2, across: Vector2, spacing: float, half_w: float) -> float:
	var meander := 0.25 * gnoise(p / (spacing * 12.0), 61) * spacing
	var u := (p.dot(across) + meander) / spacing
	var d := absf(u - floorf(u) - 0.5) / half_w
	return 0.0 if d >= 1.0 else pow(cos(d * PI * 0.5), 2.0)

const _M32 := 0xFFFFFFFF

# ground.gdshader's pcg2d (Jarzynski & Olano 2020), in 32-bit unsigned arithmetic.
static func _pcg_x(vx: int, vy: int) -> int:
	vx = (vx * 1664525 + 1013904223) & _M32
	vy = (vy * 1664525 + 1013904223) & _M32
	vx = (vx + vy * 1664525) & _M32
	vy = (vy + vx * 1664525) & _M32
	vx ^= vx >> 16
	vy ^= vy >> 16
	vx = (vx + vy * 1664525) & _M32
	vx ^= vx >> 16
	return vx

static func _hash2(cx: int, cy: int, s: int) -> float:
	return float(_pcg_x((cx + s) & _M32, (cy + s * 747796405) & _M32)) / 4294967295.0

## ground.gdshader's gnoise: Perlin's gradient noise, quintic, in [−1, 1].
static func gnoise(p: Vector2, s: int) -> float:
	var ix := floori(p.x); var iy := floori(p.y)
	var fx := p.x - ix; var fy := p.y - iy
	var ux := fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
	var uy := fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0)
	var v := [0.0, 0.0, 0.0, 0.0]
	for k in 4:
		var ox := k & 1; var oy := k >> 1
		var a := _hash2(ix + ox, iy + oy, s) * TAU
		v[k] = cos(a) * (fx - ox) + sin(a) * (fy - oy)
	return 1.414 * lerpf(lerpf(v[0], v[1], ux), lerpf(v[2], v[3], ux), uy)

## The far grid's outer RIM of its half-width eased down to its lowest point, where SurfaceSite.patch_level
## lays the planet's patch, so the site meets the patch as a slope, not a cliff standing out of it. A dry world's
## only: under a sea the patch is below the water anyway. Contact reads the eased grid, as it is drawn.
const RIM := 0.15

func _ramp_rim(h: PackedFloat32Array) -> void:
	var lowest := INF
	for v in h: lowest = minf(lowest, v)
	var c := (cells - 1) * 0.5
	for j in cells:
		for i in cells:
			var r := maxf(absf(i - c), absf(j - c)) / c
			var t := clampf((r - (1.0 - RIM)) / RIM, 0.0, 1.0)
			if t <= 0.0: continue
			var k := j * cells + i
			h[k] = lerpf(h[k], lowest, t * t * (3.0 - 2.0 * t))

## How much rougher than Earth's this world's ground is: its stated relief's scale, or strength over ρg (the
## ratio of gravities), up to where a small world's own size has more to say than its gravity.
func strength() -> float:
	return relief_scale if relief_scale > 0.0 else minf(G_EARTH / g, MAX_ROUGH)

## Linear dunes across the grid (`dunes`): ridges `spacing` apart running along `bearing`, meandering a little,
## each a rounded crest `width` across with flat interdunes between, `height` at the crest.
## They thin out to nothing at the band's edge in latitude and do not climb out of a sea. Where the grid is too
## coarse to hold a ridge (under 6 cells to a spacing) they are left to the finer grid. `far_half` > 0 is the
## grid this one was drawn from, whose dunes it replaces.
func _add_dunes(h: PackedFloat32Array, half: float, far_half := 0.0) -> void:
	if dunes.is_empty(): return
	var spacing := float(dunes.spacing)
	var band := absf(rad_to_deg(lat)) / float(dunes.band)
	var amp := float(dunes.height) * clampf((1.0 - band) * 3.0, 0.0, 1.0)
	if amp <= 0.0: return
	var step := 2.0 * half / (cells - 1)
	var keep := 1.0 if spacing / step >= 6.0 else 0.0
	var took := 0.0
	if far_half > 0.0:
		took = 1.0 if spacing / (2.0 * far_half / (cells - 1)) >= 6.0 else 0.0
	if keep == took: return
	var b := deg_to_rad(float(dunes.bearing))
	# Across the crests: the grid's (east, north) onto the bearing's normal.
	var across := Vector2(cos(b), -sin(b))
	var half_w := 0.5 * float(dunes.width) / spacing
	for j in cells:
		var y := -half + j * step
		for i in cells:
			var x := -half + i * step
			var k := j * cells + i
			var base: float = h[k]
			if has_sea and base <= 0.0: continue
			var ridge := dune_ridge(Vector2(x, y), across, spacing, half_w)
			h[k] = base + amp * ridge * (keep - took)


# Fractal detail with the world's strength behind it, on land only: a sea bed under sediment is smooth.
func _add_roughness(h: PackedFloat32Array, half: float, wavelength: float, amp: float, s: int) -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.5
	noise.seed = s
	noise.frequency = 1.0 / wavelength
	var step := 2.0 * half / (cells - 1)
	for j in cells:
		var y := -half + j * step
		for i in cells:
			var x := -half + i * step
			var k := j * cells + i
			var base: float = h[k]
			# Fade in over the first few hundred metres, so a coast is a beach, not a wall.
			var land := clampf(base / 300.0, 0.0, 1.0) if has_sea else 1.0
			if land > 0.0:
				h[k] = base + noise.get_noise_2d(x, y) * 0.5 * amp * land

## RMS height difference between neighbouring measured cells about the pin, m: the measured relief's
## own roughness at the cell's scale, over a 7 × 7 patch of them.
func cell_roughness() -> float:
	var L := elevation.cell_rad() * radius_m
	var sum := 0.0
	var n := 0
	for j in range(-3, 4):
		for i in range(-3, 4):
			var here := _measured(i * L, j * L)
			for d in [Vector2(1, 0), Vector2(0, 1)]:
				var dh := _measured((i + d.x) * L, (j + d.y) * L) - here
				sum += dh * dh
				n += 1
	return sqrt(sum / n)

func _measured(e: float, n: float) -> float:
	var ll := PlanetPin.lat_lon(_dir(e, n))
	return elevation.at(ll.x, ll.y)

# Relief below `top` m: fBm whose octaves each fall by 2^−H as their wavelength halves, scaled so the
# grid's height increments at CAL_LAG cells reach the measured cell's extended there,
# ν(ℓ) = ν_cell (ℓ / L_cell)^H. What the grid already holds at that lag counts toward it.
func _add_fractal(h: PackedFloat32Array, half: float, top: float, s: int) -> void:
	var step := 2.0 * half / (cells - 1)
	var lag := CAL_LAG * step
	var want := float(stats.cell_roughness_m) * pow(lag / float(stats.cell_m), hurst)
	var have := _increments(h, CAL_LAG)
	var need := sqrt(maxf(want * want - have * have, 0.0))
	if need <= 0.0 or top <= lag: return
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = clampi(int(ceil(log(top / step) / log(2.0))) + 1, 1, 9)
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = pow(2.0, -hurst)
	noise.seed = s
	noise.frequency = 1.0 / top
	var f := PackedFloat32Array()
	f.resize(cells * cells)
	for j in cells:
		for i in cells:
			f[j * cells + i] = noise.get_noise_2d(-half + i * step, -half + j * step)
	var scale := need / maxf(_increments(f, CAL_LAG), 1e-9)
	for k in h.size(): h[k] += f[k] * scale

# RMS of height differences `lag` cells apart along both axes.
func _increments(h: PackedFloat32Array, lag: int) -> float:
	var sum := 0.0
	var n := 0
	for j in range(0, cells - lag):
		for i in range(0, cells - lag):
			var a := h[j * cells + i]
			var dx := h[j * cells + i + lag] - a
			var dy := h[(j + lag) * cells + i] - a
			sum += dx * dx + dy * dy
			n += 2
	return sqrt(sum / maxf(n, 1.0))

# Saturated cratering: bowls and rims, with counts falling as D⁻² (the power law crater counts
# show). Density and depth/diameter of 0.2 are typical fresh values (estimates). `largest` caps the
# radius, m.
func _stamp_craters(h: PackedFloat32Array, half: float, s: int, largest := INF) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = s
	var step := 2.0 * half / (cells - 1)
	var r_max := minf(half * 0.35, largest)
	var r_min := step * 2.0
	var count := int(60.0 * crater)
	for c in count:
		# Inverse CDF of N(>D) ∝ D⁻²: small ones are many.
		var r := r_min / sqrt(lerpf(1.0, pow(r_min / r_max, 2.0), rng.randf()))
		var cx := rng.randf_range(-half, half)
		var cy := rng.randf_range(-half, half)
		var depth := 0.4 * r * crater
		var reach := int(ceil(r * 1.7 / step))
		var ic := int((cx + half) / step)
		var jc := int((cy + half) / step)
		for j in range(maxi(jc - reach, 0), mini(jc + reach + 1, cells)):
			for i in range(maxi(ic - reach, 0), mini(ic + reach + 1, cells)):
				var dx := -half + i * step - cx
				var dy := -half + j * step - cy
				var t := sqrt(dx * dx + dy * dy) / r
				if t > 1.7: continue
				var profile := -1.0 + t * t if t < 1.0 else 0.0
				var rim_dt := (t - 1.0) * 4.0
				profile += 0.25 * exp(-rim_dt * rim_dt)
				h[j * cells + i] += depth * profile

## Flow routing and the stream-power solve. Returns log₁₀ of drainage area per cell in m², for the
## shader's channels; a world with nothing flowing gets only creep.
func _carve(h: PackedFloat32Array, half: float, p0: float, p1: float, open_rim: bool) -> PackedFloat32Array:
	_n = cells
	_dx = 2.0 * half / (cells - 1)
	_h = h
	var size := _n * _n
	_recv.resize(size); _stack.resize(size); _area.resize(size); _base.resize(size)
	_kids.resize(size * 8); _kid_n.resize(size)
	for k in size:
		var rim := k < _n or k >= size - _n or k % _n == 0 or k % _n == _n - 1
		_base[k] = 1 if (has_sea and h[k] <= 0.0) or rim else 0
	var K := erodibility()
	var dt := SPAN_YEARS / STEPS
	var creep := CREEP if flowing else CREEP_DRY
	_fill_pits()
	_route()
	for it in STEPS:
		if cancelled: return PackedFloat32Array()
		if it > 0 and it % ROUTE_EVERY == 0: _route()
		if K > 0.0: _stream_step(K, dt)
		_creep_step(creep, dt)
		progress = lerpf(p0, p1, float(it + 1) / STEPS)
	# Creep swaps its working array, so the carved heights are copied back.
	for k in size: h[k] = _h[k]
	_route_on(h)
	var out := PackedFloat32Array()
	out.resize(size)
	for k in size: out[k] = U.log10(maxf(_area[k], 1.0))
	stats["max_area_km2"] = maxf(float(stats.get("max_area_km2", 0.0)), _max_of(_area) * 1e-6)
	return out

func _route_on(h: PackedFloat32Array) -> void:
	_h = h
	_route()

static func _max_of(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a: m = maxf(m, v)
	return m

# Priority-flood (Barnes et al. 2014): raise each pit to its spill, so all water reaches a base.
func _fill_pits() -> void:
	var size := _n * _n
	var seen := PackedByteArray()
	seen.resize(size)
	var heap_k := PackedInt32Array()
	var heap_h := PackedFloat32Array()
	var push := func(k: int, z: float) -> void:
		heap_k.append(k); heap_h.append(z)
		var i := heap_k.size() - 1
		while i > 0:
			var p := (i - 1) / 2
			if heap_h[p] <= z: break
			heap_k[i] = heap_k[p]; heap_h[i] = heap_h[p]
			i = p
		heap_k[i] = k; heap_h[i] = z
	var pop := func() -> int:
		var top := heap_k[0]
		var last_k := heap_k[heap_k.size() - 1]
		var last_h := heap_h[heap_h.size() - 1]
		heap_k.resize(heap_k.size() - 1); heap_h.resize(heap_h.size() - 1)
		var count := heap_k.size()
		if count > 0:
			var i := 0
			while true:
				var c := 2 * i + 1
				if c >= count: break
				if c + 1 < count and heap_h[c + 1] < heap_h[c]: c += 1
				if heap_h[c] >= last_h: break
				heap_k[i] = heap_k[c]; heap_h[i] = heap_h[c]
				i = c
			heap_k[i] = last_k; heap_h[i] = last_h
		return top
	for k in size:
		if _base[k] == 1:
			seen[k] = 1
			push.call(k, _h[k])
	var eps := 1e-3 * _dx
	while heap_k.size() > 0:
		var k: int = pop.call()
		var z := _h[k]
		var x := k % _n
		var y := k / _n
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				if dx == 0 and dy == 0: continue
				var nx: int = x + dx
				var ny: int = y + dy
				if nx < 0 or ny < 0 or nx >= _n or ny >= _n: continue
				var q := ny * _n + nx
				if seen[q] == 1: continue
				seen[q] = 1
				if _h[q] < z + eps: _h[q] = z + eps
				push.call(q, _h[q])

# D8 steepest descent, the stack base-first, and the area each cell gathers.
func _route() -> void:
	var size := _n * _n
	var n := _n
	var dx := _dx
	var diag := dx * 1.41421356
	var h := _h
	_kid_n.fill(0)
	for k in size:
		if _base[k] == 1:
			_recv[k] = k
			continue
		var x := k % n
		var y := k / n
		var z := h[k]
		var best := 0.0
		var to := k
		for j in range(maxi(y - 1, 0), mini(y + 2, n)):
			var row := j * n
			for i in range(maxi(x - 1, 0), mini(x + 2, n)):
				var q := row + i
				if q == k: continue
				var d := diag if i != x and j != y else dx
				var s := (z - h[q]) / d
				if s > best:
					best = s
					to = q
		_recv[k] = to
		if to != k:
			_kids[to * 8 + _kid_n[to]] = k
			_kid_n[to] += 1
	var w := 0
	var todo := PackedInt32Array()
	todo.resize(size)
	for k in size:
		if _recv[k] != k: continue
		var sp := 0
		todo[0] = k
		sp = 1
		while sp > 0:
			sp -= 1
			var c := todo[sp]
			_stack[w] = c
			w += 1
			for m in _kid_n[c]:
				todo[sp] = _kids[c * 8 + m]
				sp += 1
	var cell := dx * dx
	_area.fill(cell)
	for i in range(size - 1, -1, -1):
		var c := _stack[i]
		var r := _recv[c]
		if r != c: _area[r] += _area[c]

# Backward Euler in the stack's order, so each cell reads its receiver's new height: with n = 1
# it is direct, z = (z + F z_r)/(1 + F), and stable at any step (Braun & Willett 2013).
func _stream_step(K: float, dt: float) -> void:
	var size := _n * _n
	var dx := _dx
	var diag := dx * 1.41421356
	var n := _n
	for i in size:
		var c := _stack[i]
		var r := _recv[c]
		if r == c or _base[c] == 1: continue
		var d := dx if c % n == r % n or c / n == r / n else diag
		var f := K * sqrt(_area[c]) * dt / d
		_h[c] = (_h[c] + f * _h[r]) / (1.0 + f)

# One explicit step of creep, sub-stepped under the stability limit.
func _creep_step(D: float, dt: float) -> void:
	var k := D * dt / (_dx * _dx)
	if k <= 0.0: return
	var passes := mini(int(ceil(k / 0.2)), 40)
	var a := minf(k / passes, 0.2)
	var n := _n
	for pass_i in passes:
		var next := _h.duplicate()
		for y in range(1, n - 1):
			var row := y * n
			for x in range(1, n - 1):
				var c := row + x
				if _base[c] == 1: continue
				next[c] = _h[c] + a * (_h[c - 1] + _h[c + 1] + _h[c - n] + _h[c + n] - 4.0 * _h[c])
		_h = next

## A self-contained erosion run, for a check: a tilted noisy block carved with uplift `u` until it
## is steady. Returns the arrays a hydrology test reads.
func run_steady(n: int, dx: float, u: float, k_e: float, steps: int, dt: float, s: int) -> Dictionary:
	_n = n
	_dx = dx
	var size := n * n
	var rng := RandomNumberGenerator.new()
	rng.seed = s
	_h = PackedFloat32Array(); _h.resize(size)
	_recv.resize(size); _stack.resize(size); _area.resize(size); _base.resize(size)
	_kids.resize(size * 8); _kid_n.resize(size)
	for k in size:
		var x := k % n
		var y := k / n
		_base[k] = 1 if y == 0 or y == n - 1 or x == 0 or x == n - 1 else 0
		_h[k] = 0.0 if _base[k] == 1 else rng.randf() * 10.0
	_fill_pits()
	for it in steps:
		if it % 2 == 0: _route()
		for k in size:
			if _base[k] == 0: _h[k] += u * dt
		_stream_step(k_e, dt)
	_route()
	return {"h": _h, "recv": _recv, "area": _area, "stack": _stack, "base": _base}
