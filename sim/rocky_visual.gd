class_name RockyVisual
extends RefCounted

# SOLID-SURFACE WORLDS: every non-giant planet (Earth, Mars, the Moon, Mercury,
# Pluto, Foundry bodies). Earth, Mars and the Moon use mission imagery for
# geography; everything else uses procedural terrain (sim/terrain.gd). Both share
# the shader, lighting, volatile and climate uniforms:
#   S        insolation, derived from wherever the body is and whatever lights it
#   eps      the greenhouse (how far the surface runs above equilibrium)
#   T_frost  the dominant volatile's condensation temperature (273 K water,
#            148 K Mars's CO₂, 37 K Pluto's N₂)
#   crater   whether anything erases impacts
# Shaders: rocky_surface, cloud_deck and rocky_atmosphere.gdshader.
#
# sphere_geometry() copies THREE.SphereGeometry vertex for vertex (not SphereMesh):
# the maps sample its UVs, and a tidally locked moon keeps its +X meridian toward its
# parent. The orchestrator owns group.position and group.scale; this owns
# group.rotation (obliquity) and everything under it.

const SURFACE_SHADER := preload("res://shaders/bodies/rocky_surface.gdshader")
const CLOUD_SHADER := preload("res://shaders/bodies/cloud_deck.gdshader")
const ATMO_SHADER := preload("res://shaders/bodies/rocky_atmosphere.gdshader")

const TAU_ := PI * 2.0

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

## `new THREE.Color(x)` for an option that may be a hex int or already a Color.
static func lin_of(x) -> Color:
	if x is Color: return x
	return U.lin(int(x))

## Knuth multiplicative hash of a body id, mod 2^32.
static func id_hash(id: int) -> int:
	return (id * 2654435761) & 0xFFFFFFFF

# THREE.SphereGeometry(radius, widthSegments, heightSegments): x = −r cos φ sin θ,
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
		# poles: THREE offsets the u of the pole row by half a segment
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
			# THREE: (a, b, d) and (b, c, d), counter-clockwise; reversed here
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
static func surface_material(seed: float, opts: Dictionary = {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	_init_suns(m)
	var tu := Terrain.terrain_uniforms(opts)
	for k in tu:
		m.set_shader_parameter(k, tu[k])
	m.set_shader_parameter("uSeed", seed)
	# Sea-level datum height, km. −60 means no liquid at all (airless or boiled dry).
	m.set_shader_parameter("uSeaKm", float(U.nz(opts.get("seaKm"), 0.0)))
	m.set_shader_parameter("uIce", 0.0)        # glaciated fraction FORCED by an EBM, if any
	m.set_shader_parameter("uScorch", 0.0)
	# Annual-mean insolation's second Legendre coefficient. See create_rocky_visual.
	m.set_shader_parameter("uS2", -0.477)
	m.set_shader_parameter("uFrostK", float(U.nz(opts.get("frostK"), 273.0)))
	m.set_shader_parameter("uBiota", float(U.nz(opts.get("biota"), 0.0)))
	m.set_shader_parameter("uCrater", float(U.nz(opts.get("crater"), 0.0)))
	m.set_shader_parameter("uRegolith", v3(lin_of(U.nz(opts.get("regolith"), 0x8b8178))))
	m.set_shader_parameter("uHaze", float(U.nz(opts.get("haze"), 0.0)))
	m.set_shader_parameter("uAmbient", v3(lin_of(U.nz(opts.get("ambient"), 0x070b14))))
	m.set_shader_parameter("uTime", 0.0)
	# Exposure: one shared constant, as a camera exposes for the planet (albedos are
	# real reflectances), so worlds side by side stay comparable.
	m.set_shader_parameter("uGain", 1.95)
	# Seasons, in K of pole-to-pole swing. The annual mean can't grow Mars's 148 K CO₂
	# cap; winter does. uDecl is the sine of the sub-solar latitude; uSeason is how far
	# the surface follows it (small under an ocean, large on bare rock).
	m.set_shader_parameter("uSeason", float(U.nz(opts.get("season"), 8.0)))
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

# CLOUDS. Not a noise field wrapped round a ball — see cloud_deck.gdshader.
static func cloud_material(seed: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = CLOUD_SHADER
	_init_suns(m)
	m.set_shader_parameter("uTime", 0.0)
	m.set_shader_parameter("uCover", 0.45)
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
static func surface_temp_k(S: float, albedo: float, eps: float) -> float:
	var Teq := 278.6 * pow(maxf(S, 1e-9) * (1.0 - albedo), 0.25)
	return Teq / pow(maxf(eps, 1e-3), 0.25)

static func create_rocky_visual(b: Body, opts: Dictionary = {}) -> RockyViz:
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
	var opts: Dictionary
	var albedo: float
	var eps: float
	var sea_km0: float
	var tilt_q := Quaternion()

	func _init(b: Body, o: Dictionary) -> void:
		body = b
		opts = o
		group = Node3D.new()
		group.name = "Rocky_%s" % b.name
		R = float(o.get("radiusScene", 1.0))
		base_r = R
		# (opts.seed || 0): a preset's seed nudges the terrain without re-rolling it
		var seed_opt := float(o.seed) if RockyVisual.truthy(o.get("seed")) else 0.0
		var seed := float(RockyVisual.id_hash(b.id) % 1000) / 7.3 + seed_opt * 0.017

		# A world with no liquid at all is expressed by putting the sea-level datum
		# below the deepest point there is, not by a second branch in the shader.
		var dry := RockyVisual.truthy(o.get("hot")) or RockyVisual.truthy(o.get("airless")) \
				or float(U.nz(o.get("water"), 1.0)) <= 0.0
		var atm := RockyVisual.truthy(o.get("atmosphere"))
		var surf_opts := o.duplicate()
		var land = o.get("land")
		if land == null:
			land = (1.0 - float(o.seaLevel) * 0.72) if o.get("seaLevel") != null else 0.34
		surf_opts["continent"] = land
		surf_opts["seaKm"] = -60.0 if dry else float(U.nz(o.get("seaKm"), 0.0))
		surf_opts["crater"] = U.nz(o.get("crater"), 0.0 if atm else 0.85)
		surf_opts["biota"] = U.nz(o.get("biota"), 0.0)
		surf_opts["haze"] = U.nz(o.get("haze"), 0.45 if atm else 0.0)
		surf_opts["regolith"] = U.nz(o.get("regolith"), 0xb08058 if RockyVisual.truthy(o.get("hot")) else 0x8d8478)
		surf_opts["frostK"] = U.nz(o.get("frostK"), 273.0)

		surf_mat = RockyVisual.surface_material(seed, surf_opts)
		RockyVisual.bind_planet_map(surf_mat, b.name)
		surface = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R, 96, 64), surf_mat)
		surface.name = "Surface"
		group.add_child(surface)
		core = surface

		if atm:
			cloud_mat = RockyVisual.cloud_material(seed + 3.7)
			if RockyVisual.truthy(o.get("cloudColor")):
				cloud_mat.set_shader_parameter("uTint", RockyVisual.v3(RockyVisual.lin_of(o.cloudColor)))
			cloud_mat.set_shader_parameter("uCover", float(U.nz(o.get("cloudCover"), 0.45)))
			clouds = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R * 1.008, 64, 48), cloud_mat)
			clouds.name = "Clouds"
			group.add_child(clouds)

			atmo_mat = RockyVisual.atmosphere_material(o.get("atmColor"))
			atmo_mat.set_shader_parameter("uThick", float(U.nz(o.get("atmThick"), 1.0)))
			atmo = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R * 1.035, 72, 48), atmo_mat)
			atmo.name = "Atmosphere"
			group.add_child(atmo)

		# Obliquity is what gives a world seasons on top of whatever its orbit is
		# already doing, and it also sets the insolation profile below.
		var obliquity := float(U.nz(o.get("obliquity"), 0.35))
		group.rotation.z = obliquity
		tilt_q = Quaternion(Vector3(0, 0, 1), obliquity)
		surf_mat.set_shader_parameter("uS2", RockyVisual.insolation_s2(obliquity))

		albedo = float(U.nz(o.get("albedo"), 0.3))
		eps = float(U.nz(o.get("greenhouse"), 0.61 if atm else 1.0))
		# The sea datum as built, kept so a baked-dry world can refill when it cools.
		sea_km0 = float(surf_opts.seaKm)

		if b.spin == null:
			b.spin = (0.4 + randf() * 1.2) * (-1.0 if randf() < 0.1 else 1.0)
		b.viz = self

	func _u(m: ShaderMaterial, k: String) -> float:
		return float(m.get_shader_parameter(k))

	func update(dt: float, ctx: VisualCtx) -> void:
		var b := body
		# Wrap both phases: past ~1e5 a float32 rotation stops advancing.
		var parent: Body = null
		var tl = opts.get("tidalLock")
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
			b.spin_phase = atan2(-toward.z, toward.x)
		else:
			b.spin_phase = fmod(b.spin_phase + float(b.spin) * dt, TAU)
		surface.rotation.y = b.spin_phase
		if clouds != null:
			# The deck super-rotates slightly; it also needs its own accumulator
			# rather than a scaled read of spinPhase, which would jump at each wrap.
			b.cloud_phase = fmod(b.cloud_phase + float(b.spin) * dt * 0.985, TAU)
			clouds.rotation.y = b.cloud_phase
			cloud_mat.set_shader_parameter("uTime", _u(cloud_mat, "uTime") + dt)
		surf_mat.set_shader_parameter("uTime", _u(surf_mat, "uTime") + dt)

		# Temperature from where the body is now, so editing an orbit moves the ice line.
		var suns = Suns.lit_by(ctx)
		if suns != null:
			# Insolation from real stars, or the stand-in light's own intensity when there are
			# none, so temperature and lighting agree.
			var S: float = Suns.insolation_at(b, ctx.suns) if not ctx.suns.is_empty() else float(suns[0].intensity)
			var T: float
			if opts.get("surfaceK") != null:
				T = float(opts.surfaceK)
			elif S > 1e-8:
				T = RockyVisual.surface_temp_k(S, albedo, eps)
			else:
				T = float(U.nz(opts.get("meanK"), 60.0))
			var mk := _u(surf_mat, "uMeanK")
			surf_mat.set_shader_parameter("uMeanK", mk + (T - mk) * minf(1.0, dt * 2.0))

			# The hot end is derived too: uSeaKm, uScorch and uArid follow temperature, so a
			# 388 K planet inside its habitable zone's inner edge loses its oceans. Only for a
			# body with an atmosphere: an airless rock at 440 K is just warm. A stated surface
			# temperature counts (Venus's 737 K).
			if RockyVisual.truthy(opts.get("atmosphere")):
				# Near-Earth-pressure teaching model: dry out by water's boiling point.
				var boil := clampf((T - 350.0) / 23.15, 0.0, 1.0)
				surf_mat.set_shader_parameter("uSeaKm", sea_km0 + (-60.0 - sea_km0) * boil)
				surf_mat.set_shader_parameter("uScorch", clampf((T - 330.0) / 140.0, 0.0, 1.0))
				surf_mat.set_shader_parameter("uArid", minf(clampf((T - 310.0) / 80.0, 0.0, 1.0), 0.8))
				if cloud_mat != null:
					# A runaway greenhouse ends under more cloud, not less (Venus); only the fair-weather
					# structure goes.
					var base := float(U.nz(opts.get("cloudCover"), 0.45))
					cloud_mat.set_shader_parameter("uCover", base + (1.0 - base) * clampf((T - 340.0) / 110.0, 0.0, 1.0))
			# Season from the star's direction relative to the spin axis (sine of the sub-solar
			# latitude), so any orbit gets its own seasons.
			var pole := tilt_q * Vector3.UP
			var sun_dir: Vector3 = (suns[0].pos_rel - group.position).normalized()
			surf_mat.set_shader_parameter("uDecl", pole.dot(sun_dir))
			var mats := [surf_mat]
			if cloud_mat != null: mats.append(cloud_mat)
			if atmo_mat != null: mats.append(atmo_mat)
			Suns.apply_suns(mats, suns, group.position)
