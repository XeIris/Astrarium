class_name SurfaceSite
extends RefCounted

# Standing at a pin: the ground, the sea, the weather and the sky of one world, in the flight
# pass (LocalView), in metres with y up and height from the sea. Built when someone arrives and freed
# when they leave. The stage hands it the world; it reads the climate and writes nothing back.
# docs/physics/surface.md.

const OCEAN_SHADER := preload("res://shaders/surface/ocean.gdshader")
const WATER_SHADER := preload("res://shaders/surface/water.gdshader")
## A new wind redraws the FFT sea's amplitudes when it differs by this fraction or this bearing, rad.
const SEA_REWIND := 0.15
const SEA_REBEAR := 0.2
const RAIN_SHADER := preload("res://shaders/surface/rain.gdshader")
const TERRAIN_SHADER := preload("res://shaders/surface/ground.gdshader")
# Below the grid on a world without a measured cell (SurfaceRelief.HURST): ν at 1 km and H, scaled by
# strength over ρg as the grid's own roughness is. Estimates, for a ground that is neither flat nor a
# measured world's.
const ROUGH_1KM := 30.0
const HURST_DEFAULT := 0.8
# Grid sizes by render quality; the near grid and the far are the same size.
const CELLS := {"low": 65, "medium": 97, "high": 129, "ultra": 161}
# A sea's fetch, m, where the wind has room, and where it only has the view: JONSWAP needs one, and
# a pin has no coasts mapped beyond its far grid, so the open sea's is a long one (an estimate).
const FETCH_OPEN := 6.0e5
const FETCH_MIN := 1.0e4
# On a low rise, where the country can be seen; the terrain has no detail for a walker yet.
const EYE_LAND := 18.0
const EYE_SEA := 8.0
const OCEAN_RINGS := 110
const OCEAN_SEGS := 96
const OCEAN_REACH := 90000.0
const RAIN_DROPS := {"low": 600, "medium": 1800, "high": 3000, "ultra": 5000}
const RAIN_BOX := 14.0
const OVERCAST_FILL := 2.4

var local: LocalView
var body: Body
var climate: Climate
var pin: PlanetPin
var quality := "medium"
var group: Node3D
var relief: SurfaceRelief
var weather := SurfaceWeather.new()
var sea_trains: Array = []
var sea := {}
## The FFT sea, where a RenderingDevice draws it (otherwise the trains): its field, its GPU half, the liquid
## and the field's clock, s. A SurfaceSea in flight hands its own field in and runs the clock and the wind.
var ocean: OceanField = null
var ocean_gpu: OceanGPU = null
var liquid := Liquid.SEAWATER
var sea_time := 0.0
var _sea_owned := true
var tide := {"height": 0.0, "rows": []}
## A sea in view: under the pin, or in the far grid's low ground.
var has_sea := false
var frozen_sea := false
## The crust and the climate's look, as the pin read them.
var crust: PlanetRelief
var patch_y := 0.0
var built := false
var eye_y := 2.0
var ground_y := 0.0
var temp_here := 288.0
var pressure_here := 1.0
var lapse := 0.0065
var air: Variant = null
var _task := -1
var _mat: ShaderMaterial
var _ocean: MeshInstance3D = null
var _ocean_mat: ShaderMaterial = null
var _rain: GPUParticles3D = null
var _rain_mat: ShaderMaterial = null
var _time := 0.0
var _wind_t := Vector3.ZERO
var _sea_acc := 99.0
var _depth_tex: ImageTexture = null

func _init(view: LocalView, b: Body, where: PlanetPin, render_quality: String, run_seed: int, surveyed: SurfaceRelief = null) -> void:
	SurfaceStats.count("site_init")
	local = view
	body = b
	climate = b.climate
	pin = where
	quality = render_quality
	group = Node3D.new()
	group.name = "SurfaceSite"
	local.root.add_child(group)
	local.place(group, DVec3.new())
	var seed_ := site_seed(b, where, run_seed)
	weather.setup(b, climate, where.lat, where.lon, seed_)
	crust = PlanetRelief.of_body(b)
	# A relief already surveyed (a landing's, SurfaceGround) is the ground the vehicle stands on; carving
	# another would move it.
	relief = surveyed if surveyed != null else plan_relief(b, where, crust, int(CELLS.get(quality, 97)), seed_)
	# On a map, the sea is where the map says, not wherever the ground is low: Qattara is dry.
	_map_sea = crust.map_kind != 1 or _map_has_sea(b, where, relief.radius_m)
	if surveyed == null: _task = WorkerThreadPool.add_task(relief.build, false, "surface relief")

## The seed a site's roughness, weather and waves are drawn from.
static func site_seed(b: Body, where: PlanetPin, run_seed: int) -> int:
	return hash([str(U.nz(b.spec.get("seed"), b.name)), run_seed, where.n])

## The survey of the ground at a pin, not yet run: `build()` carves it. `cells` a side on each grid.
static func plan_relief(b: Body, where: PlanetPin, r: PlanetRelief, cells: int, seed_: int) -> SurfaceRelief:
	var climate: Climate = b.climate
	var relief := SurfaceRelief.new()
	relief.relief = r
	relief.center = where.p
	# East and north on the mesh's own ball, with its pole on +Y.
	var ref := Vector3.UP if absf(where.p.y) < 0.999 else Vector3.RIGHT
	relief.east = ref.cross(where.p).normalized()
	relief.north = where.p.cross(relief.east).normalized()
	relief.radius_m = b.radius * Rocketry.AU_M
	relief.g = climate.gravity
	relief.seed = seed_ & 0x7fffffff
	relief.cells = cells
	relief.crater = r.crater
	relief.lat = where.lat
	if b.spec.get("landRelief") != null: relief.relief_scale = float(b.spec.landRelief) / 3.2
	relief.dunes = b.spec.get("dunes", {}) if b.spec.get("dunes") != null else {}
	# Heights count from the world's sea, if it has one; whether one is in view waits for the grid.
	relief.has_sea = str(where.ground.kind) in ["sea", "sea ice"] or (climate.wet and climate.ocean > 0.0 and r.sea_km > -30.0)
	relief.sea_m = r.sea_km * 1000.0 if relief.has_sea else 0.0
	# A stated sea's level is the datum, its shores wherever a mare comes within the far grid.
	if StatedSeas.has(b.name) and not StatedSeas.at(b.name, where.lat, where.lon, relief.radius_m, 2.0 * SurfaceRelief.FAR_HALF).is_empty():
		relief.stated = b.name
		relief.has_sea = true
		relief.sea_m = 0.0
	relief.rain_index = float(where.ground.get("rain", -1.0)) if climate.wet else -1.0
	var melt := float(where.ground.temp_k) > climate.freezing_point(climate.salinity) - 5.0
	relief.flowing = climate.wet and climate.ocean > 0.0 and melt
	relief.rain_mm = ClimateLook.precipitation_mm(climate)
	if r.map_kind == 1: relief.map_land = 0 if str(where.ground.kind) in ["sea", "sea ice"] else 1
	elif r.map_kind == 2: relief.map_land = 1
	if r.map_kind > 0: relief.elevation = PlanetElevation.of(b.name)
	if relief.elevation != null and not relief.flowing: relief.hurst = float(SurfaceRelief.HURST.get(b.name, 0.0))
	if r.map_kind == 1 and relief.elevation != null:
		relief.map_coastal = PlanetPin.coastal(b.name, where.lat, where.lon, relief.elevation.cell_rad())
	return relief

## The level the planet's patch is dropped to under a site's grids, m: under the sea, which is opaque and
## has the same level, or under the lowest of the far grid, or the patch comes up through the valleys.
static func patch_level(grids: Array, has_sea: bool) -> float:
	if has_sea: return -30.0
	var lowest := INF
	for v in (grids[1].h as PackedFloat32Array): lowest = minf(lowest, v)
	return lowest - 30.0

var _map_sea := true

# Whether the map has sea anywhere across the far grid, on a 9 × 9 lattice of it.
static func _map_has_sea(b: Body, where: PlanetPin, radius_m: float) -> bool:
	var half := minf(SurfaceRelief.FAR_HALF, radius_m * 0.08) / radius_m
	var ref := Vector3.UP if absf(where.p.y) < 0.999 else Vector3.RIGHT
	var east := ref.cross(where.p).normalized()
	var north := where.p.cross(east).normalized()
	for j in 9:
		for i in 9:
			var d := (where.p + east * half * (i / 4.0 - 1.0) + north * half * (j / 4.0 - 1.0)).normalized()
			var ll := PlanetPin.lat_lon(d)
			if not PlanetPin.land_at(b.name, ll.x, ll.y): return true
	return false

## Done surveying? Builds the scene on the first call that finds it finished.
func poll() -> bool:
	if built: return true
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task): return false
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if relief.grids.is_empty(): return false
	_build_scene()
	built = true
	return true

## Wait for the survey, on this thread. A check's path; the stage polls.
func finish_now() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		if not relief.grids.is_empty():
			_build_scene()
			built = true

func dispose() -> void:
	if _task >= 0:
		relief.cancelled = true
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	local.unplace(group)
	if ocean_gpu != null: ocean_gpu.dispose()
	if _rain != null: local.unplace(_rain)
	if is_instance_valid(group): group.queue_free()
	SurfaceStats.count("site_dispose")

func height_at(e: float, n: float) -> float:
	return SiteScene.sample(relief.grids, e, n)

# Ground colours as the planet's biome() draws them: physical albedos, read off the pin's biome. A preset's
# regolith is that world's rock. Vegetation only where the pin says something grows.
const BIOMES := {
	"desert": {"a": 0xa08a68, "b": 0x8c7656, "soil": 0xc4a878, "green": 0xb0a070, "grow": 0.0},
	"grassland": {"a": 0x7a725f, "b": 0x6a6450, "soil": 0x8d8058, "green": 0x6c7440, "grow": 0.9},
	"forest": {"a": 0x62604f, "b": 0x54523f, "soil": 0x6a5e42, "green": 0x35492c, "grow": 1.0},
	"jungle": {"a": 0x5c5a48, "b": 0x4c4c3a, "soil": 0x5e5236, "green": 0x2a4c2a, "grow": 1.0},
	"tundra": {"a": 0x76746a, "b": 0x66645a, "soil": 0x75705a, "green": 0x6a6c50, "grow": 0.6},
	"bare rock": {"a": 0x6e6a60, "b": 0x5a564c, "soil": 0x7a7264, "green": 0x6e6a60, "grow": 0.0},
	"bare ground": {"a": 0x8d8478, "b": 0x6f675c, "soil": 0xa39887, "green": 0x8d8478, "grow": 0.0},
}

func _palette() -> Dictionary:
	var biome: String = pin.ground.get("biome", "")
	var row: Dictionary = BIOMES.get(biome, BIOMES["bare ground"]).duplicate()
	var regolith = body.spec.get("regolith")
	if regolith != null and float(row.grow) == 0.0:
		row.a = int(regolith)
		row.b = _shade(int(regolith), 0.8)
		row.soil = _shade(int(regolith), 1.15)
	row.biota = crust.biota * float(row.grow)
	return row

# The sky's colour, for what it lights: a Venus's fill is orange. Bright channel at one.
func fill_tint() -> Vector3:
	var own = climate.flight_atmosphere()
	if own == null: return Vector3.ONE
	var c := SiteScene._lin(int(own.haze))
	return c / maxf(maxf(c.x, c.y), maxf(c.z, 1e-3))

static func _shade(hex: int, k: float) -> int:
	var r := mini(int(((hex >> 16) & 255) * k), 255)
	var g := mini(int(((hex >> 8) & 255) * k), 255)
	var b := mini(int((hex & 255) * k), 255)
	return (r << 16) | (g << 8) | b

func _build_scene() -> void:
	SurfaceStats.count("site_build")
	var grids: Array = relief.grids
	ground_y = height_at(0.0, 0.0)
	var lowest := patch_level(grids, false) + 30.0
	var at_sea: bool = str(pin.ground.kind) in ["sea", "sea ice"]
	has_sea = at_sea or (relief.has_sea and lowest < 0.0 and _map_sea)
	patch_y = patch_level(grids, has_sea)
	eye_y = EYE_SEA if at_sea else ground_y + EYE_LAND
	lapse = ClimateLook.lapse_k_m(climate)
	temp_here = float(pin.ground.temp_k)
	# The air at the ground, which may be below the datum or the sea; at sea, the sea's surface.
	pressure_here = weather.air_bar * exp(-(0.0 if at_sea else ground_y) / maxf(weather.scale_h, 1.0))
	var share := relief.rain_index / relief.rain_index_mean if relief.rain_index >= 0.0 and relief.rain_index_mean > 0.0 else 1.0
	weather.place(temp_here, weather.rain_mm_yr * share, at_sea)
	_mat = ShaderMaterial.new()
	_mat.shader = TERRAIN_SHADER
	var pal := _palette()
	_mat.set_shader_parameter("uRockA", SiteScene._lin(int(pal.a)))
	_mat.set_shader_parameter("uRockB", SiteScene._lin(int(pal.b)))
	_mat.set_shader_parameter("uSoil", SiteScene._lin(int(pal.soil)))
	_mat.set_shader_parameter("uGreen", SiteScene._lin(int(pal.green)))
	# Vegetation stops where it is too cold: 10 °C-ish above the frost line, in the world's own lapse.
	var tree_top := (temp_here - 263.0) / maxf(lapse, 1e-5) + ground_y if float(pal.biota) > 0.1 else -1.0
	_mat.set_shader_parameter("uGreenTop", tree_top)
	_set_ground_uniforms()
	var frost := crust.frost_k
	var snow_line: float = (temp_here - frost) / maxf(lapse, 1e-5) + ground_y if frost > 0.0 else 1.0e9
	_mat.set_shader_parameter("uSnowLine", snow_line)
	_mat.set_shader_parameter("uRivers", 1.0 if relief.flowing else 0.0)
	_mat.set_shader_parameter("uFillTint", fill_tint())
	var R: float = relief.radius_m
	for gi in 2:
		var channel: PackedFloat32Array = relief.channel_near if gi == 0 else relief.channel_far
		group.add_child(SiteScene.terrain_mesh(grids, gi, patch_y, R, _mat, has_sea, channel))
	# The sea's own temperature, at its level here, not the mountain's.
	var freeze := float(Liquid.of(body.name).get("freeze_k", Climate.freezing_point(climate.salinity)))
	frozen_sea = has_sea and crust.temperature(sin(pin.lat), 0.0) < freeze - 4.0
	if has_sea: _build_ocean(at_sea)
	_build_rain()

# What the ground shader reads beyond the palette: the grids' heights for the Sun's march, the
# world's roughness below the grid, and whether a regolith lies under no air.
func _set_ground_uniforms() -> void:
	var grids: Array = relief.grids
	_mat.set_shader_parameter("uNearH", _height_texture(grids[0]))
	_mat.set_shader_parameter("uFarH", _height_texture(grids[1]))
	_mat.set_shader_parameter("uNearHalf", float(grids[0].half))
	_mat.set_shader_parameter("uFarHalf", float(grids[1].half))
	_mat.set_shader_parameter("uRadius", relief.radius_m)
	var top := -INF
	for v in (grids[1].h as PackedFloat32Array): top = maxf(top, v)
	_mat.set_shader_parameter("uTop", top + 50.0)
	if relief.hurst > 0.0 and relief.stats.has("cell_roughness_m"):
		_mat.set_shader_parameter("uRoughCell", float(relief.stats.cell_roughness_m))
		_mat.set_shader_parameter("uCellM", float(relief.stats.cell_m))
		_mat.set_shader_parameter("uHurst", relief.hurst)
	else:
		_mat.set_shader_parameter("uRoughCell", ROUGH_1KM * relief.strength())
		_mat.set_shader_parameter("uCellM", 1000.0)
		_mat.set_shader_parameter("uHurst", HURST_DEFAULT)
	_mat.set_shader_parameter("uAirless", 1.0 if climate.flight_atmosphere() == null else 0.0)

static func _height_texture(g: Dictionary) -> ImageTexture:
	var n: int = g.n
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RF, (g.h as PackedFloat32Array).to_byte_array())
	return ImageTexture.create_from_image(img)

func _build_ocean(at_sea: bool) -> void:
	_ocean_mat = ShaderMaterial.new()
	liquid = Liquid.of(body.name)
	var fetch := FETCH_OPEN if at_sea else maxf(FETCH_MIN, relief.grids[1].half)
	sea = {"fetch": fetch}
	if RDU.available() and not frozen_sea:
		if ocean == null:
			var w := weather.now()
			ocean = OceanField.new(climate.gravity, _site_depth(), liquid, Liquid.field_wind(liquid, float(w.wind)), float(w.wind_dir), fetch, hash(pin.n) & 0xffffff)
		ocean_gpu = OceanGPU.new(ocean)
		_ocean_mat.shader = WATER_SHADER
		_water_uniforms()
	else:
		_ocean_mat.shader = OCEAN_SHADER
		sea_trains = SurfaceWaves.make_trains(maxf(weather.wind_mean, 0.5), climate.gravity, _site_depth(), hash(pin.n) & 0xffffff)
		_ocean_mat.set_shader_parameter("uDeep", _water_colour(0.02))
		_ocean_mat.set_shader_parameter("uShallow", _water_colour(0.5))
	_ocean_mat.set_shader_parameter("uFrozen", 1.0 if frozen_sea else 0.0)
	_ocean_mat.set_shader_parameter("uRadius", relief.radius_m)
	_ocean_mat.set_shader_parameter("uOpen", 1.0 if at_sea else 0.0)
	_set_depth_tex()
	# A polar disc about the camera, so the vertex budget stays where the waves can be seen.
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for r in OCEAN_RINGS + 1:
		var u := float(r) / OCEAN_RINGS
		var dist := (exp(u * 5.5) - 1.0) / (exp(5.5) - 1.0) * OCEAN_REACH
		for s in OCEAN_SEGS:
			var a := TAU * s / OCEAN_SEGS
			verts.append(Vector3(cos(a) * dist, 0.0, sin(a) * dist))
	for r in OCEAN_RINGS:
		for s in OCEAN_SEGS:
			var p := r * OCEAN_SEGS + s
			var q := r * OCEAN_SEGS + (s + 1) % OCEAN_SEGS
			var t := (r + 1) * OCEAN_SEGS + s
			var v := (r + 1) * OCEAN_SEGS + (s + 1) % OCEAN_SEGS
			idx.append_array([p, q, t, q, v, t])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var nrm := PackedVector3Array()
	nrm.resize(verts.size())
	nrm.fill(Vector3.UP)
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_ocean = MeshInstance3D.new()
	_ocean.name = "ocean"
	_ocean.mesh = mesh
	_ocean.material_override = _ocean_mat
	_ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ocean.custom_aabb = AABB(Vector3(-OCEAN_REACH, -200.0, -OCEAN_REACH), Vector3(2.0 * OCEAN_REACH, 400.0, 2.0 * OCEAN_REACH))
	# A child of the site's group, so placed in the site's frame (light_sea), not against the camera.
	group.add_child(_ocean)

# The sea's depth under the pin, m: at least enough to read as deep, a shelf's if the crust says so.
func _site_depth() -> float:
	return maxf(-height_at(0.0, 0.0), 40.0)

# Clear water's colour: blue is what is left after the red has gone within metres
# (https://en.wikipedia.org/wiki/Color_of_water). Chlorophyll is not modelled.
func _water_colour(shallow: float) -> Vector3:
	return Vector3(0.012, 0.045, 0.105).lerp(Vector3(0.03, 0.22, 0.26), shallow)

# The FFT sea's textures, its lattices and the liquid's optics, for water.gdshader.
func _water_uniforms() -> void:
	var m := _ocean_mat
	for c in OceanField.CASCADES:
		m.set_shader_parameter("uDisp%d" % c, ocean_gpu.disp[c])
		m.set_shader_parameter("uDeriv%d" % c, ocean_gpu.deriv[c])
	m.set_shader_parameter("uTile", Vector4(ocean.L[0], ocean.L[1], ocean.L[2], ocean.L[3]))
	m.set_shader_parameter("uCells", Vector4(ocean.n[0], ocean.n[1], ocean.n[2], ocean.n[3]))
	m.set_shader_parameter("uSlopeVar", Vector4(ocean.slope_var[0], ocean.slope_var[1], ocean.slope_var[2], ocean.slope_var[3]))
	m.set_shader_parameter("uUnresolved", ocean.unresolved_slope())
	m.set_shader_parameter("uF0", Liquid.f0(float(liquid.n)))
	m.set_shader_parameter("uIor", float(liquid.n))
	m.set_shader_parameter("uAbsorb", liquid.absorb)
	m.set_shader_parameter("uBackscatter", liquid.backscatter)
	m.set_shader_parameter("uDeepR", Liquid.deep_reflectance(liquid))
	m.set_shader_parameter("uPatchY", patch_y)
	sea = {"fetch": float(sea.get("fetch", ocean.fetch)), "hs": ocean.hs(), "peak_period": TAU / ocean.peak_omega,
		"wind": ocean.wind, "wind_dir": ocean.bearing}

## Hand a SurfaceSea's field in before the site is built: it then owns the field's clock and wind.
func use_ocean(f: OceanField) -> void:
	ocean = f
	_sea_owned = false

# Heights for the shader's shoreline and shallows, from the far grid.
func _set_depth_tex() -> void:
	var far: Dictionary = relief.grids[1]
	var n: int = far.n
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	var h: PackedFloat32Array = far.h
	for j in n:
		for i in n:
			img.set_pixel(i, j, Color(h[j * n + i], 0.0, 0.0))
	_depth_tex = ImageTexture.create_from_image(img)
	_ocean_mat.set_shader_parameter("uHeights", _depth_tex)
	_ocean_mat.set_shader_parameter("uHeightsHalf", float(far.half))

func _build_rain() -> void:
	_rain_mat = ShaderMaterial.new()
	_rain_mat.shader = RAIN_SHADER
	_rain = GPUParticles3D.new()
	_rain.name = "precipitation"
	_rain.amount = int(RAIN_DROPS.get(quality, 1800))
	_rain.lifetime = 2.0
	_rain.preprocess = 2.0
	_rain.local_coords = true
	_rain.visibility_aabb = AABB(Vector3(-RAIN_BOX, -RAIN_BOX, -RAIN_BOX), Vector3(2.0, 2.0, 2.0) * RAIN_BOX)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(RAIN_BOX, RAIN_BOX, RAIN_BOX)
	pm.direction = Vector3.DOWN
	pm.spread = 0.0
	pm.initial_velocity_min = 8.0
	pm.initial_velocity_max = 10.0
	pm.gravity = Vector3.ZERO
	_rain.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.022, 0.9)
	quad.material = _rain_mat
	_rain.draw_pass_1 = quad
	_rain.emitting = false
	_rain.visible = false
	_rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	group.add_child(_rain)
	local.place(_rain, DVec3.new())
	_rain_process = pm

var _rain_process: ParticleProcessMaterial

## One drawn frame. `sim_seconds` of the world's clock pass here; `up` is the site's zenith in orrery axes.
func update(dt: float, sim_seconds: float, up: Vector3, bodies: Array, cam_y: float, sun_l: Vector3, sun_rgb: Vector3, sky_top: Vector3, haze: Vector3, density: float, scale_h: float) -> void:
	SurfaceStats.count("site_update")
	_time += dt
	weather.step(sim_seconds)
	var w := weather.now()
	sky_cover = float(w.cover)
	# The cloud field moves with the column's mean wind, at the world's own rate on screen.
	var wind_dir := SurfaceSite.wind_vector(float(w.wind_dir))
	_wind_t += wind_dir * weather.drift * sim_seconds
	cloud_wind = _wind_t
	current = w
	tide = SurfaceWaves.tide(body, up, bodies) if has_sea else {"height": 0.0, "rows": []}
	if _ocean != null:
		if ocean_gpu != null:
			if _sea_owned:
				sea_time += dt
				_sea_acc += dt
				if _sea_acc > 2.0:
					_sea_acc = 0.0
					var wind := maxf(float(w.wind), 0.1)
					if absf(wind / ocean.wind - 1.0) > SEA_REWIND or absf(angle_difference(float(w.wind_dir), ocean.bearing)) > SEA_REBEAR:
						ocean.set_wind(wind, float(w.wind_dir))
						ocean_gpu.refill()
						_water_uniforms()
			ocean_gpu.run(sea_time, dt)
		else:
			_sea_acc += dt
			if _sea_acc > 0.5:
				_sea_acc = 0.0
				sea = SurfaceWaves.fill(sea_trains, maxf(float(w.wind), 0.1), float(w.wind_dir), climate.gravity, float(sea.fetch))
				var arrays := SurfaceWaves.shader_arrays(sea_trains)
				_ocean_mat.set_shader_parameter("uWaves", arrays.waves)
				_ocean_mat.set_shader_parameter("uPhases", arrays.phases)
		light_sea(sun_l, sun_rgb, sky_top, haze, density, scale_h, float(w.cover), float(tide.height), local.cam_pos.to_v3())
	_rain_tick(w, cam_y)
	light_terrain(sun_l, cam_y, float(w.cover))

## In flight: run the FFT sea on its owner's clock (`sea_time`, set first) and light it. `cam` is the eye in
## the site's frame.
func draw_sea(dt: float, sun_l: Vector3, sun_rgb: Vector3, sky_top: Vector3, haze: Vector3, density: float, scale_h: float, cover: float, cam: Vector3,
		light := Vector3.ONE) -> void:
	if _ocean == null: return
	if ocean_gpu != null: ocean_gpu.run(sea_time, dt)
	light_sea(sun_l, sun_rgb, sky_top, haze, density, scale_h, cover, 0.0, cam)
	_ocean_mat.set_shader_parameter("uLight", light)

## The sea's light and air for this frame, in the site's frame: `cam` the eye's place in it.
func light_sea(sun_l: Vector3, sun_rgb: Vector3, sky_top: Vector3, haze: Vector3, density: float, scale_h: float, cover: float, tide_h: float, cam: Vector3) -> void:
	if _ocean_mat == null: return
	# The disc follows the eye; its vertices take their place in the sea from uCamLocal.
	_ocean.position = Vector3(cam.x, tide_h, cam.z)
	for key_val in [["uTime", _time], ["uCamLocal", cam], ["uSunDir", sun_l], ["uSunRGB", sun_rgb], ["uSkyTop", sky_top],
			["uHaze", haze], ["uDensity", density], ["uScaleH", scale_h], ["uCover", cover], ["uTide", tide_h]]:
		_ocean_mat.set_shader_parameter(key_val[0], key_val[1])

## The ground's light and air for this frame: `sun_l` in the site's frame, `eye_y` the eye's height in it.
## The flight pass's ground material supplies the air, as it does for the planet's patch.
func light_terrain(sun_l: Vector3, eye_y: float, cover: float, sun_ang := 0.00465) -> void:
	if _mat == null: return
	_mat.set_shader_parameter("uSunDir", sun_l)
	_mat.set_shader_parameter("uSunAng", maxf(sun_ang, 1e-4))
	_mat.set_shader_parameter("uEye", maxf(eye_y - patch_y, 1.0))
	var gm := local.ground_mat
	for p in ["uHaze", "uDensity", "uScaleH", "uHasAir"]:
		_mat.set_shader_parameter(p, gm.get_shader_parameter(p))
	# Under cloud the sunlight has not gone, it has been scattered: the deck's bright underside lights
	# the ground from everywhere. A factor by eye; nothing here casts a shadow from the deck.
	var fill: float = float(gm.get_shader_parameter("uSkyI")) * (1.0 + OVERCAST_FILL * cover)
	_mat.set_shader_parameter("uSkyI", fill)
	# The planet's patch past the grids stands in the same light, or it reads as dark water. Its shading
	# divides by π; the site's emission does not.
	gm.set_shader_parameter("uSkyI", fill * PI)

var sky_cover := 0.0
var cloud_wind := Vector3.ZERO
var current := {}

func _rain_tick(w: Dictionary, cam_y: float) -> void:
	if _rain == null: return
	var rate := float(w.rain_mm_h)
	var on := rate > 0.05
	_rain.emitting = on
	_rain.visible = on
	if not on: return
	# Terminal speed scales as √(g/ρ) from 9 m/s for rain; snow falls at about 1 m/s.
	var speed: float = terminal_speed(float(weather.g), float(weather.rho), bool(w.snow))
	_rain_process.initial_velocity_min = speed * 0.9
	_rain_process.initial_velocity_max = speed * 1.1
	var slant := SurfaceSite.wind_vector(float(w.wind_dir)) * float(w.wind) * 0.12
	_rain_process.direction = (Vector3.DOWN + slant).normalized()
	_rain_mat.set_shader_parameter("uAlpha", clampf(0.28 + 0.12 * rate, 0.0, 0.7))
	_rain_mat.set_shader_parameter("uSnow", 1.0 if w.snow else 0.0)
	local.place(_rain, DVec3.new(local.cam_pos.x, cam_y + RAIN_BOX * 0.3, local.cam_pos.z))

## A wind bearing as a site-frame vector. Bearing is from north towards east; the frame's x runs west.
static func wind_vector(bearing: float) -> Vector3:
	return Vector3(-sin(bearing), 0.0, cos(bearing))

## How fast a drop or flake falls, m/s: v² ∝ g/ρ, from drag against weight.
static func terminal_speed(g: float, rho: float, snow: bool) -> float:
	return (1.0 if snow else 9.0) * sqrt(g / 9.81 * 1.225 / maxf(rho, 1e-3))
