class_name SurfaceSite
extends RefCounted

# Standing at a pin: the ground, the sea, the weather and the sky of one world, in the flight
# pass (LocalView), in metres with y up and height from the sea. Built when someone arrives and freed
# when they leave. The stage hands it the world; it reads the climate and writes nothing back.
# docs/physics/surface.md.

const OCEAN_SHADER := preload("res://shaders/surface/ocean.gdshader")
const RAIN_SHADER := preload("res://shaders/surface/rain.gdshader")
const TERRAIN_SHADER := preload("res://shaders/observatory/site_terrain.gdshader")
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

func _init(view: LocalView, b: Body, where: PlanetPin, render_quality: String, run_seed: int) -> void:
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
	var seed_ := hash([str(U.nz(b.spec.get("seed"), b.name)), run_seed, where.n])
	weather.setup(b, climate, where.lat, where.lon, seed_)
	var r := PlanetRelief.of_body(b)
	crust = r
	relief = SurfaceRelief.new()
	relief.relief = r
	relief.center = where.p
	# East and north on the mesh's own ball, with its pole on +Y.
	var ref := Vector3.UP if absf(where.p.y) < 0.999 else Vector3.RIGHT
	relief.east = ref.cross(where.p).normalized()
	relief.north = where.p.cross(relief.east).normalized()
	relief.radius_m = b.radius * Rocketry.AU_M
	relief.g = climate.gravity
	relief.seed = seed_ & 0x7fffffff
	relief.cells = int(CELLS.get(quality, 97))
	relief.crater = r.crater
	# Heights count from the world's sea, if it has one; whether one is in view waits for the grid.
	relief.has_sea = str(where.ground.kind) in ["sea", "sea ice"] or (climate.wet and climate.ocean > 0.0 and r.sea_km > -30.0)
	relief.sea_m = r.sea_km * 1000.0 if relief.has_sea else 0.0
	relief.rain_index = float(where.ground.get("rain", -1.0)) if climate.wet else -1.0
	var melt := float(where.ground.temp_k) > climate.freezing_point(climate.salinity) - 5.0
	relief.flowing = climate.wet and climate.ocean > 0.0 and melt
	relief.rain_mm = ClimateLook.precipitation_mm(climate)
	if r.map_kind == 1: relief.map_land = 0 if str(where.ground.kind) in ["sea", "sea ice"] else 1
	elif r.map_kind == 2: relief.map_land = 1
	if r.map_kind > 0: relief.elevation = PlanetElevation.of(b.name)
	_task = WorkerThreadPool.add_task(relief.build, false, "surface relief")

## Done surveying? Builds the scene on the first call that finds it finished.
func poll() -> bool:
	if built: return true
	if _task < 0 or not WorkerThreadPool.is_task_completed(_task): return false
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
	if _ocean != null: local.unplace(_ocean)
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
func _fill_tint() -> Vector3:
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
	var far: Dictionary = grids[1]
	var h: PackedFloat32Array = far.h
	# Under the sea, which is opaque and has the same level; or under the lowest of the far grid, or
	# the planet's patch comes up through the valleys.
	var lowest := INF
	for v in h: lowest = minf(lowest, v)
	var at_sea: bool = str(pin.ground.kind) in ["sea", "sea ice"]
	has_sea = at_sea or (relief.has_sea and lowest < 0.0)
	patch_y = -30.0 if has_sea else lowest - 30.0
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
	_mat.set_shader_parameter("uFields", 0.0)
	var frost := crust.frost_k
	var snow_line: float = (temp_here - frost) / maxf(lapse, 1e-5) + ground_y if frost > 0.0 else 1.0e9
	_mat.set_shader_parameter("uSnowLine", snow_line)
	_mat.set_shader_parameter("uRivers", 1.0 if relief.flowing else 0.0)
	_mat.set_shader_parameter("uFillTint", _fill_tint())
	var R: float = relief.radius_m
	for gi in 2:
		var channel: PackedFloat32Array = relief.channel_near if gi == 0 else relief.channel_far
		group.add_child(SiteScene.terrain_mesh(grids, gi, patch_y, R, _mat, has_sea, channel))
	# The sea's own temperature, at its level here, not the mountain's.
	frozen_sea = has_sea and crust.temperature(sin(pin.lat), 0.0) < Climate.freezing_point(climate.salinity) - 4.0
	if has_sea: _build_ocean(at_sea)
	_build_rain()

func _build_ocean(at_sea: bool) -> void:
	_ocean_mat = ShaderMaterial.new()
	_ocean_mat.shader = OCEAN_SHADER
	var fetch := FETCH_OPEN if at_sea else maxf(FETCH_MIN, relief.grids[1].half)
	sea_trains = SurfaceWaves.make_trains(maxf(weather.wind_mean, 0.5), climate.gravity, _site_depth(), hash(pin.n) & 0xffffff)
	sea = {"fetch": fetch}
	_ocean_mat.set_shader_parameter("uFrozen", 1.0 if frozen_sea else 0.0)
	_ocean_mat.set_shader_parameter("uRadius", relief.radius_m)
	_ocean_mat.set_shader_parameter("uOpen", 1.0 if at_sea else 0.0)
	_ocean_mat.set_shader_parameter("uDeep", _water_colour(0.02))
	_ocean_mat.set_shader_parameter("uShallow", _water_colour(0.5))
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
	group.add_child(_ocean)
	local.place(_ocean, DVec3.new())

# The sea's depth under the pin, m: at least enough to read as deep, a shelf's if the crust says so.
func _site_depth() -> float:
	return maxf(-height_at(0.0, 0.0), 40.0)

# Clear water's colour: blue is what is left after the red has gone within metres
# (https://en.wikipedia.org/wiki/Color_of_water). Chlorophyll is not modelled.
func _water_colour(shallow: float) -> Vector3:
	return Vector3(0.012, 0.045, 0.105).lerp(Vector3(0.03, 0.22, 0.26), shallow)

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
		_sea_acc += dt
		if _sea_acc > 0.5:
			_sea_acc = 0.0
			sea = SurfaceWaves.fill(sea_trains, maxf(float(w.wind), 0.1), float(w.wind_dir), climate.gravity, float(sea.fetch))
			var arrays := SurfaceWaves.shader_arrays(sea_trains)
			_ocean_mat.set_shader_parameter("uWaves", arrays.waves)
			_ocean_mat.set_shader_parameter("uPhases", arrays.phases)
		local.place(_ocean, DVec3.new(local.cam_pos.x, float(tide.height), local.cam_pos.z))
		for key_val in [["uTime", _time], ["uCamLocal", local.cam_pos.to_v3()], ["uSunDir", sun_l], ["uSunRGB", sun_rgb], ["uSkyTop", sky_top],
				["uHaze", haze], ["uDensity", density], ["uScaleH", scale_h], ["uCover", float(w.cover)], ["uTide", float(tide.height)]]:
			_ocean_mat.set_shader_parameter(key_val[0], key_val[1])
	_rain_tick(w, cam_y)
	if _mat != null:
		_mat.set_shader_parameter("uSunDir", sun_l)
		_mat.set_shader_parameter("uEye", maxf(cam_y - patch_y, 1.0))
		var gm := local.ground_mat
		for p in ["uHaze", "uDensity", "uScaleH", "uHasAir"]:
			_mat.set_shader_parameter(p, gm.get_shader_parameter(p))
		# Under cloud the sunlight has not gone, it has been scattered: the deck's bright underside lights
		# the ground from everywhere. A factor by eye; nothing here casts a shadow from the deck.
		var fill: float = float(gm.get_shader_parameter("uSkyI")) * (1.0 + OVERCAST_FILL * float(w.cover))
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
