class_name RockyVisual
extends RefCounted

# Mission geography and procedural terrain share lighting/climate shaders.
# Sphere UV orientation puts the +X meridian toward a tidally locked parent, with the map's
# north on the orbit's north.
# The stage owns group position/scale; this visual owns obliquity and inner nodes.
# See shaders/AGENTS.md for physical albedo, volatiles and surface datum.

const SURFACE_SHADER := preload("res://shaders/bodies/rocky_surface.gdshader")
const CLOUD_SHADER := preload("res://shaders/bodies/cloud_deck.gdshader")
const ATMO_SHADER := preload("res://shaders/bodies/rocky_atmosphere.gdshader")

const TAU_ := PI * 2.0
const SEED_WRAP := 10000.0
## The shared surface exposure (uGain), as a camera exposes for the planet.
const EXPOSURE := 1.95

## A half turn about the mesh's +X meridian. A map has north on the mesh's +Y, and orbits here
## turn about −Y (spin_step), as `Rocketry.spin_frame` has it.
const NORTH_ON_ORBIT_POLE := Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, -1))

## The surface shader's sunlit share of a disc at phase angle `alpha` (rad): the mean over
## the disc of its soft terminator, which is broader than a sphere's Lambert cosine.
static func lit_fraction(alpha: float) -> float:
	var sum := 0.0
	var n := 0
	var m := 32
	for j in m:
		var y := -1.0 + (j + 0.5) * 2.0 / m
		for i in m:
			var x := -1.0 + (i + 0.5) * 2.0 / m
			var q := x * x + y * y
			if q >= 1.0: continue
			n += 1
			sum += smoothstep(-0.08, 0.22, x * sin(alpha) + sqrt(1.0 - q) * cos(alpha))
	return sum / n

# option helpers
## Truthiness of an option value (null/false/0/"" are false).
static func truthy(v) -> bool:
	if v == null: return false
	if v is bool: return v
	if v is int or v is float: return v != 0
	if v is String: return v != ""
	return true

static func v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

## `A colour` for an option that may be a hex int or already a Color.
static func lin_of(x) -> Color:
	if x is Color: return x
	return U.lin(int(x))

## Knuth multiplicative hash of a body id, mod 2^32.
static func id_hash(id: int) -> int:
	return (id * 2654435761) & 0xFFFFFFFF

## A world's crust key: FNV-1a of its name, so a reload, a rebuild or another session draws the same
## ground, where a body id counts every spawn since start.
static func name_hash(name: String) -> int:
	var h := 2166136261
	for byte in name.to_utf8_buffer():
		h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
	return h

# UV sphere parameterization: x = −r cos φ sin θ,
# y = r cos θ, z = r sin φ sin θ, seam and pole rows duplicated. UVs in Godot's
# convention (v = 0 at north), winding reversed for Godot's CW front faces.
static var _sphere_cache := {}

static func sphere_geometry(radius: float, wseg: int, hseg: int) -> ArrayMesh:
	var key := "%s|%d|%d" % [radius, wseg, hseg]
	if _sphere_cache.has(key):
		return _sphere_cache[key]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var grid := []
	var vi := 0
	for iy in hseg + 1:
		var row := []
		var v := float(iy) / float(hseg)
		# poles: Offset the pole row UV by half a segment
		var u_off := 0.0
		if iy == 0: u_off = 0.5 / float(wseg)
		elif iy == hseg: u_off = -0.5 / float(wseg)
		for ix in wseg + 1:
			var u := float(ix) / float(wseg)
			var phi := u * TAU_
			var theta := v * PI
			var p := Vector3(-radius * cos(phi) * sin(theta), radius * cos(theta), radius * sin(phi) * sin(theta))
			verts.append(p)
			norms.append(p.normalized() if p.length() > 0.0 else Vector3.UP)
			uvs.append(Vector2(u + u_off, v))
			row.append(vi)
			vi += 1
		grid.append(row)
	for iy in hseg:
		for ix in wseg:
			var a: int = grid[iy][ix + 1]
			var b: int = grid[iy][ix]
			var c: int = grid[iy + 1][ix]
			var d: int = grid[iy + 1][ix + 1]
			# (a, b, d) and (b, c, d), counter-clockwise; reversed here
			if iy != 0: idx.append_array([a, d, b])
			if iy != hseg - 1: idx.append_array([b, d, c])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_sphere_cache[key] = m
	return m

static func mesh_instance(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi

## Seed every sun uniform, so a material that hasn't seen a star yet renders with
## count 0 rather than zeroed arrays.
static func _init_suns(m: ShaderMaterial) -> void:
	Suns.apply_suns([m], [], Vector3.ZERO)

# SURFACE MATERIAL. See rocky_surface.gdshader for the model.
static func surface_material(seed: float, opts: VisualOpts) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	_init_suns(m)
	var tu := Terrain.terrain_uniforms(opts)
	for k in tu:
		m.set_shader_parameter(k, tu[k])
	m.set_shader_parameter("uSeed", seed)
	# Sea-level datum height, km. −60 means no liquid at all (airless or boiled dry).
	m.set_shader_parameter("uSeaKm", float(U.nz(opts.sea_km, 0.0)))
	m.set_shader_parameter("uIce", 0.0)        # glaciated fraction FORCED by an EBM, if any
	m.set_shader_parameter("uScorch", 0.0)
	# Annual-mean insolation's second Legendre coefficient. See create_rocky_visual.
	m.set_shader_parameter("uS2", -0.477)
	m.set_shader_parameter("uFrostK", float(U.nz(opts.frost_k, 273.0)))
	m.set_shader_parameter("uBiota", float(U.nz(opts.biota, 0.0)))
	m.set_shader_parameter("uCrater", float(U.nz(opts.crater, 0.0)))
	m.set_shader_parameter("uRegolith", v3(lin_of(U.nz(opts.regolith, 0x8b8178))))
	m.set_shader_parameter("uHaze", float(U.nz(opts.haze, 0.0)))
	m.set_shader_parameter("uAmbient", v3(U.lin(0x070b14)))
	m.set_shader_parameter("uTime", 0.0)
	# Exposure: one shared constant, as a camera exposes for the planet (albedos are
	# real reflectances), so worlds side by side stay comparable.
	m.set_shader_parameter("uGain", EXPOSURE)
	# Seasons, in K of pole-to-pole swing. The annual mean can't grow Mars's 148 K CO₂
	# cap; winter does. uDecl is the sine of the sub-solar latitude; uSeason is how far
	# the surface follows it (small under an ocean, large on bare rock).
	m.set_shader_parameter("uSeason", float(U.nz(opts.season, 8.0)))
	m.set_shader_parameter("uDecl", 0.0)
	m.set_shader_parameter("uMapKind", 0.0)   # 0 procedural, 1 Earth land/water, 2 dry mission mosaic
	m.set_shader_parameter("uMapScale", 1.0)
	return m

## Hook a surface material up to a body's mission imagery, if it has any
## (PlanetMaps.load_planet_map calls back once the textures are in).
static func bind_planet_map(m: ShaderMaterial, body_name: String) -> void:
	PlanetMaps.load_planet_map(body_name, func(e: Dictionary) -> void:
		m.set_shader_parameter("uColorMap", e.color)
		m.set_shader_parameter("uLandMask", e.mask)
		m.set_shader_parameter("uMapScale", float(e.scale))
		m.set_shader_parameter("uMapKind", float(e.kind)))

## The cloud deck reads Earth's map for its deserts (cloud_deck.gdshader).
static func bind_cloud_map(m: ShaderMaterial, body_name: String) -> void:
	PlanetMaps.load_planet_map(body_name, func(e: Dictionary) -> void:
		if int(e.kind) != 1: return
		m.set_shader_parameter("uColorMap", e.color)
		m.set_shader_parameter("uLandMask", e.mask)
		m.set_shader_parameter("uMapKind", float(e.kind)))

# CLOUDS. Not a noise field wrapped round a ball — see cloud_deck.gdshader.
static func cloud_material(seed: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = CLOUD_SHADER
	_init_suns(m)
	m.set_shader_parameter("uTime", 0.0)
	m.set_shader_parameter("uCover", 0.5)
	m.set_shader_parameter("uCloudZ", Terrain.cloud_global_z(0.5))
	m.set_shader_parameter("uStorm", 0.25)
	m.set_shader_parameter("uSeed", seed)
	m.set_shader_parameter("uTint", Vector3(1, 1, 1))
	return m

# ATMOSPHERE. Rayleigh scattering — see rocky_atmosphere.gdshader.
static func atmosphere_material(tint = null) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ATMO_SHADER
	_init_suns(m)
	m.set_shader_parameter("uThick", 1.0)
	m.set_shader_parameter("uTint", v3(lin_of(U.nz(tint, 0xffffff))))
	return m

# Annual-mean insolation's second Legendre coefficient:
#   S(φ)/S̄ = 1 + s2·P2(sin φ),  s2 = −(5/8)(1 − (3/2) sin²ε)
# −0.477 at Earth's 23.44°. It changes sign at ε = 54.7°, past which the poles get
# more annual sunlight and ice forms at the equator (Uranus).
static func insolation_s2(obliquity: float) -> float:
	var s := sin(obliquity)
	return -0.625 * (1.0 - 1.5 * s * s)

## Surface temperature in radiative balance, with eps the effective emissivity (0.61
## puts Earth at 288 K; 1.0 is an airless rock).
## Sidereal rotation period in years, 0 when unknown: a spec's `dayLength`, then the
## flight surface table. Unsigned: here an obliquity past 90° is what makes Venus,
## Uranus and Pluto turn backwards (the flight frame has no tilt, so it signs `day`).
static func sidereal_period_yr(b: Body) -> float:
	# Tides evolve the spin the kernel carries (Physics.apply_secular).
	if b.spin_tracked and b.spin_omega != 0.0: return TAU_ / absf(b.spin_omega)
	var stated = b.spec.get("dayLength")
	if stated != null and float(stated) != 0.0: return absf(float(stated))
	var surf: Dictionary = Rocketry.SURFACES.get(b.name, {})
	return absf(float(surf.day)) / Rocketry.YR_S if surf.has("day") else 0.0

## Rotation this frame, rad, for a body turning `factor` times its sidereal rate (a
## cloud deck's super-rotation). It follows simulated time; past
## SPIN_CAP rad per render second it is drawn at the cap, so a 6 yr/s orrery shows
## which way a world turns instead of strobing. An explicit visualSpinRadS wins, and
## a body with no known period keeps its display rate. Orbits turn about −y (r × v),
## so callers subtract the step: prograde is a falling rotation.y.
const SPIN_CAP := 1.2
static func spin_step(b: Body, factor: float, dt: float, sim_dt: float) -> float:
	var period := sidereal_period_yr(b)
	if b.spec.get("visualSpinRadS") != null or period == 0.0:
		return float(b.visual_spin_rad_s) * factor * dt
	var turn := TAU_ * sim_dt * factor / period
	var cap := SPIN_CAP * dt
	return turn if absf(turn) <= cap else signf(turn) * cap

static func surface_temp_k(S: float, albedo: float, eps: float) -> float:
	var Teq := 278.6 * pow(maxf(S, 1e-9) * (1.0 - albedo), 0.25)
	return Teq / pow(maxf(eps, 1e-3), 0.25)

static func create_rocky_visual(b: Body, opts: VisualOpts) -> RockyViz:
	return RockyViz.new(b, opts)

## The visual object: group, core, surface, clouds, atmo, surf_mat, cloud_mat,
## atmo_mat, base_r, R, is_rocky, and update(dt, ctx).
class RockyViz extends RefCounted:
	var group: Node3D
	var core: MeshInstance3D
	var surface: MeshInstance3D
	var clouds: MeshInstance3D = null
	var atmo: MeshInstance3D = null
	var surf_mat: ShaderMaterial
	var cloud_mat: ShaderMaterial = null
	var atmo_mat: ShaderMaterial = null
	var base_r: float
	var R: float
	var is_rocky := true
	var body: Body
	var opts: VisualOpts
	var tilt_q := Quaternion()
	var _cover := -1.0
	var _cloud_seed := 0.0
	var _look := ClimateLook.Binder.new()
	## The surface's world orientation while its owner sets it each frame: LocalView, so
	## the map under a vehicle is the ground it launched from, and the Observatory, so the
	## Moon faces as it does on the date. Lapses a frame after the owner stops.
	var surface_world := Basis()
	var _surface_world_frame := -10
	## A display turn on top of a tidal lock, so a visit can bring its star up. Nothing physical moves.
	var display_turn := 0.0
	var _sky_serial := -1

	func _init(b: Body, o: VisualOpts) -> void:
		body = b
		opts = o
		group = Node3D.new()
		group.name = "Rocky_%s" % b.name
		R = float(o.radius_scene)
		base_r = R
		# A preset's seed nudges the terrain without re-rolling it. Wrapped, because this ends up in float32
		# noise coordinates: a spawn's nine-digit seed would leave no bits for the noise, and blocks for continents.
		var seed_opt := fposmod(float(o.spec_seed), RockyVisual.SEED_WRAP) if RockyVisual.truthy(o.spec_seed) else 0.0
		var seed := float(RockyVisual.name_hash(b.name) % 1000) / 7.3 + seed_opt * 0.017

		# A world with no liquid at all is expressed by putting the sea-level datum
		# below the deepest point there is, not by a second branch in the shader.
		var dry := RockyVisual.truthy(o.hot)
		var atm := RockyVisual.truthy(o.atmosphere)
		var surf_opts := o.copy()
		var land = o.land
		if land == null:
			land = (1.0 - float(o.sea_level) * 0.72) if o.sea_level != null else 0.34
		surf_opts.continent = land
		surf_opts.sea_km = -60.0 if dry else float(U.nz(o.sea_km, 0.0))
		surf_opts.crater = U.nz(o.crater, 0.0 if atm else 0.85)
		surf_opts.biota = U.nz(o.biota, 0.0)
		surf_opts.haze = U.nz(o.haze, 0.45 if atm else 0.0)
		surf_opts.regolith = U.nz(o.regolith, 0xb08058 if RockyVisual.truthy(o.hot) else 0x8d8478)
		surf_opts.frost_k = U.nz(o.frost_k, 273.0)

		surf_mat = RockyVisual.surface_material(seed, surf_opts)
		RockyVisual.bind_planet_map(surf_mat, b.name)
		surface = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R, 96, 64), surf_mat)
		surface.name = "Surface"
		group.add_child(surface)
		core = surface

		_cloud_seed = seed + 3.7
		if atm:
			_add_clouds()
			_add_atmosphere()

		# Obliquity is what gives a world seasons on top of whatever its orbit is
		# already doing, and it also sets the insolation profile below.
		var obliquity := float(U.nz(o.obliquity, 0.35))
		group.rotation.z = obliquity
		tilt_q = Quaternion(Vector3(0, 0, 1), obliquity)
		surf_mat.set_shader_parameter("uS2", RockyVisual.insolation_s2(obliquity))

		if b.visual_spin_rad_s == null:
			if b.default_visual_spin_rad_s == null:
				b.default_visual_spin_rad_s = 0.4 + randf() * 1.2
			b.visual_spin_rad_s = b.default_visual_spin_rad_s
		b.viz = self
		# A rebuild must not spend a frame on defaults: a pin or a site may read this at once.
		if b.climate != null:
			_sync_air(b.climate)
			_follow_climate(b.climate, 0.0)

	## Draw the climate now, without the ease: it has just been given one.
	func snap_climate() -> void:
		if body.climate == null: return
		_look = ClimateLook.Binder.new()
		_sync_air(body.climate)
		_follow_climate(body.climate, 0.0)

	func _add_clouds() -> void:
		cloud_mat = RockyVisual.cloud_material(_cloud_seed)
		if RockyVisual.truthy(opts.cloud_color):
			cloud_mat.set_shader_parameter("uTint", RockyVisual.v3(RockyVisual.lin_of(opts.cloud_color)))
		_set_cover(float(U.nz(opts.cloud_cover, 0.5)))
		RockyVisual.bind_cloud_map(cloud_mat, body.name)
		clouds = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R * 1.008, 64, 48), cloud_mat)
		clouds.name = "Clouds"
		group.add_child(clouds)

	func _add_atmosphere() -> void:
		atmo_mat = RockyVisual.atmosphere_material(opts.atm_color)
		atmo_mat.set_shader_parameter("uThick", float(U.nz(opts.atm_thick, 1.0)))
		atmo = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R * 1.035, 72, 48), atmo_mat)
		atmo.name = "Atmosphere"
		group.add_child(atmo)

	## What the gas column says about the shell, on a change. A stated colour or depth wins, and
	## a stated `atmosphere` decides whether there is a shell at all.
	func _sync_air(cl: Climate) -> void:
		_sky_serial = cl.sky_serial
		var thick := float(cl.sky.get("thick", 0.0))
		if atmo == null:
			if opts.atmosphere != null or thick < Climate.AIR_SHOWS: return
			_add_atmosphere()
		var tint: Vector3 = cl.sky.get("tint", Vector3.ONE)
		if opts.atm_thick == null: atmo_mat.set_shader_parameter("uThick", thick)
		if opts.atm_color == null:
			atmo_mat.set_shader_parameter("uTint", tint)
			surf_mat.set_shader_parameter("uAirTint", tint)

	## The deck's global opaque fraction and its probit offset, written only on change.
	func _set_cover(c: float) -> void:
		if c == _cover: return
		_cover = c
		cloud_mat.set_shader_parameter("uCover", c)
		cloud_mat.set_shader_parameter("uCloudZ", Terrain.cloud_z_table(c))

	# The climate's look, eased onto the materials. The materials exist first: a world that has
	# gained air grows its deck here.
	func _follow_climate(cl: Climate, dt: float) -> void:
		var want := ClimateLook.targets(cl, body.spec)
		if clouds == null and float(want.cover) > 0.0 and opts.atmosphere != false: _add_clouds()
		for key in _look.ease_to(want):
			var v: float = _look.value[key]
			match key:
				"cover": if cloud_mat != null: _set_cover(v)
				"storm": if cloud_mat != null: cloud_mat.set_shader_parameter("uStorm", v)
				_: surf_mat.set_shader_parameter(key, v)

	func hold_surface(world: Basis) -> void:
		surface_world = world
		_surface_world_frame = Engine.get_process_frames()

	func _u(m: ShaderMaterial, k: String) -> float:
		return float(m.get_shader_parameter(k))

	func update(dt: float, ctx: VisualCtx) -> void:
		var b := body
		# Wrap both phases: past ~1e5 a float32 rotation stops advancing.
		var parent: Body = null
		var tl = opts.tidal_lock
		if RockyVisual.truthy(tl):
			for x: Body in ctx.bodies:
				if x.name == tl:
					parent = x
					break
		if parent != null:
			# A synchronously rotating moon keeps its local +X meridian toward its
			# parent. Transform into the tilted body frame before reading longitude.
			var d := parent.pos.sub(b.pos)
			var toward := tilt_q.inverse() * Vector3(d.x, d.y, d.z)
			b.spin_phase = atan2(-toward.z, toward.x) + display_turn
			surface.basis = Basis(Vector3.UP, b.spin_phase) * RockyVisual.NORTH_ON_ORBIT_POLE
		else:
			b.spin_phase = fmod(b.spin_phase - RockyVisual.spin_step(b, 1.0, dt, ctx.sim_dt), TAU)
			# The whole basis: the seasons read its pole, and a held surface may have left it tilted.
			surface.basis = Basis(Vector3.UP, b.spin_phase)
		var held := Engine.get_process_frames() - _surface_world_frame <= 1
		if held:
			# The group carries the obliquity and the size ease; undo only its rotation.
			surface.basis = Basis(group.quaternion.inverse()) * surface_world
		if clouds != null:
			# The deck turns `cloudSpin` times the surface (Venus's cloud tops lap it in
			# four days, ~60×); its own accumulator, as a scaled read of spinPhase would
			# jump at each wrap.
			var cloud_spin := float(U.nz(b.spec.get("cloudSpin"), 1.0))
			b.cloud_phase = fmod(b.cloud_phase - RockyVisual.spin_step(b, cloud_spin, dt, ctx.sim_dt), TAU)
			clouds.rotation.y = b.cloud_phase
			cloud_mat.set_shader_parameter("uSurfTurn", b.cloud_phase - b.spin_phase)
			if held:
				# Over a flight the deck turns with the ground, so its deserts stay put.
				clouds.basis = surface.basis
				cloud_mat.set_shader_parameter("uSurfTurn", 0.0)
			cloud_mat.set_shader_parameter("uTime", _u(cloud_mat, "uTime") + dt)
		surf_mat.set_shader_parameter("uTime", _u(surf_mat, "uTime") + dt)

		var cl: Climate = b.climate
		if cl != null:
			if cl.sky_serial != _sky_serial: _sync_air(cl)
			_follow_climate(cl, dt)
		var suns = Suns.lit_by(ctx)
		if suns != null:
			# Season from the star's direction relative to the spin axis (sine of the sub-solar
			# latitude), so any orbit gets its own seasons.
			var pole := tilt_q * surface.basis.y
			var sun_dir: Vector3 = (suns[0].pos_rel - group.position).normalized()
			surf_mat.set_shader_parameter("uDecl", pole.dot(sun_dir))
			if cloud_mat != null:
				# The ITCZ follows the sub-solar latitude at about 0.4 of its swing.
				cloud_mat.set_shader_parameter("uItcz", 0.4 * asin(clampf(pole.dot(sun_dir), -1.0, 1.0)))
			var mats := [surf_mat]
			if cloud_mat != null: mats.append(cloud_mat)
			if atmo_mat != null: mats.append(atmo_mat)
			Suns.apply_suns(mats, suns, group.position)
			Suns.apply_occluders(mats, b, ctx.bodies, suns)
			Suns.apply_shine([surf_mat], b, ctx.bodies, suns)
