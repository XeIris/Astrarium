class_name RockyVisual
extends RefCounted

# ============================================================================
# SOLID-SURFACE WORLDS
# ----------------------------------------------------------------------------
# Every planet that is not a gas giant is drawn by this file: Earth, Mars, the
# Moon, Mercury, Pluto, and whatever the Object Foundry makes. Named Earth,
# Mars and Moon bodies use measured imagery for their geography; invented
# worlds and other bodies keep the procedural terrain. Both paths use the same
# shader, lighting, volatile and climate uniforms:
#
#   S        insolation, which the body works out for itself from wherever it
#            happens to be and whatever stars happen to be lighting it. Move a
#            planet and its ice line moves; there is nothing written down.
#   eps      the greenhouse, i.e. how far the surface runs above equilibrium.
#   T_frost  the condensation temperature of its dominant volatile. 273 K is a
#            water world; 148 K is Mars, which grows and loses CO2 caps every
#            winter; 63 K is Pluto, frosted with nitrogen. ONE uniform is the
#            difference between a polar cap of water ice and one of dry ice.
#   crater   whether anything erases impacts. With an atmosphere and plate
#            tectonics, nothing survives; with neither, the surface is a
#            four-billion-year integral of everything that ever hit it.
#
# The procedural terrain and climate belts come from sim/terrain.gd (and its
# shader include). The map path replaces only surface geography and base
# color, not the atmosphere or the response to extreme heating and cooling.
#
# The three shaders are shaders/bodies/rocky_surface.gdshader,
# cloud_deck.gdshader and rocky_atmosphere.gdshader; their comment blocks are
# the web build's, ported with the GLSL.
#
# PORT NOTES
#   · The JS factory returned a closure; here it is the RockyViz class (a
#     GDScript lambda captures by value, PORT_GUIDE.md §1).
#   · The sphere is built by sphere_geometry(), a vertex-for-vertex copy of
#     THREE.SphereGeometry, not Godot's SphereMesh: the mission maps are
#     sampled through the mesh's UVs, and the tidally-locked moon keeps its
#     +X meridian toward its parent, so both the UV layout and which meridian
#     sits at +X have to be THREE's.
#   · The orchestrator owns group.position and group.scale (floating origin,
#     size ease, oblateness); this visual owns group.rotation (the obliquity)
#     and everything under the group.
# ============================================================================

const SURFACE_SHADER := preload("res://shaders/bodies/rocky_surface.gdshader")
const CLOUD_SHADER := preload("res://shaders/bodies/cloud_deck.gdshader")
const ATMO_SHADER := preload("res://shaders/bodies/rocky_atmosphere.gdshader")

const TAU_ := PI * 2.0

# ---------------------------------------------------------------------------
# small helpers for the JS idioms the options use
# ---------------------------------------------------------------------------
## JS truthiness of an option value (undefined/null/false/0/"" are false).
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

## The web build's seed hash: ((id * 2654435761) >>> 0) — a Knuth
## multiplicative hash, taken mod 2^32 exactly as ToUint32 does.
static func id_hash(id: int) -> int:
	return (id * 2654435761) & 0xFFFFFFFF

# ---------------------------------------------------------------------------
# THREE.SphereGeometry(radius, widthSegments, heightSegments), vertex for
# vertex: positions x = -r cos(φ) sin(θ), y = r cos(θ), z = r sin(φ) sin(θ),
# normals the normalised position, and the seam and pole rows duplicated.
# UVs are in GODOT's convention (v = 0 at the TOP of the image, i.e. north),
# which is THREE's (1 - v) — THREE flipped the image on upload instead. The
# triangle winding is reversed, because Godot's front faces are clockwise.
# ---------------------------------------------------------------------------
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

## Seed every sun uniform so a material that has not yet seen a star renders
## as the web build's did (count 0) rather than with Godot's zeroed arrays.
static func _init_suns(m: ShaderMaterial) -> void:
	Suns.apply_suns([m], [], Vector3.ZERO)

# ---------------------------------------------------------------------------
# SURFACE MATERIAL. See rocky_surface.gdshader for the model.
# ---------------------------------------------------------------------------
static func surface_material(seed: float, opts: Dictionary = {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	_init_suns(m)
	var tu := Terrain.terrain_uniforms(opts)
	for k in tu:
		m.set_shader_parameter(k, tu[k])
	m.set_shader_parameter("uSeed", seed)
	# Height of the sea-level datum, in km. Raising it floods the world;
	# -60 is "there is no liquid at all", which is how an airless or a
	# boiled-dry body is expressed rather than by a second code path.
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
	# Exposure. A planet's albedo is a REFLECTANCE — 0.3 for land, 0.06 for
	# deep water — so lighting it at one solar constant and tone mapping
	# gives a disc near black, which is not what a photograph of a planet
	# looks like, because a camera exposes for the planet. This is that
	# exposure, and it is a constant rather than a per-body knob so two
	# worlds side by side are still comparable.
	m.set_shader_parameter("uGain", 1.95)
	# Seasons, in kelvin of swing between the poles. The annual MEAN
	# insolation profile cannot grow a winter cap: Mars's cap is CO2
	# freezing out at 148 K, and its annual mean polar temperature is
	# nowhere near that — it is the WINTER that gets there, and the cap
	# sublimes again by summer. uDecl is the sine of the sub-solar
	# latitude, which the sim already knows from the star direction and the
	# spin axis; uSeason is how far the surface follows it, which is small
	# under an ocean (Earth's thermal flywheel) and large on bare rock under
	# a thin atmosphere.
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

# ---------------------------------------------------------------------------
# CLOUDS. Not a noise field wrapped round a ball — see cloud_deck.gdshader.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# ATMOSPHERE. Rayleigh scattering — see rocky_atmosphere.gdshader.
# ---------------------------------------------------------------------------
static func atmosphere_material(tint = null) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ATMO_SHADER
	_init_suns(m)
	m.set_shader_parameter("uThick", 1.0)
	m.set_shader_parameter("uTint", v3(lin_of(U.nz(tint, 0xffffff))))
	return m

# ---------------------------------------------------------------------------
# Annual-mean insolation's second Legendre coefficient, from the obliquity.
#
#   S(phi)/Sbar = 1 + s2 * P2(sin phi),   s2 = -(5/8)(1 - (3/2) sin^2 eps)
#
# At Earth's 23.44 degrees this gives -0.477, which is the number every 1-D
# energy-balance model since Budyko uses. It is worth carrying the whole
# function rather than the constant, because it CHANGES SIGN at eps = 54.7
# degrees: past that tilt the poles receive more annual sunlight than the
# equator, the temperature gradient inverts, and the ice caps form around the
# EQUATOR. Uranus is over on its side like that, and so is anything the
# Foundry is asked to tip past 55 degrees.
# ---------------------------------------------------------------------------
static func insolation_s2(obliquity: float) -> float:
	var s := sin(obliquity)
	return -0.625 * (1.0 - 1.5 * s * s)

## Surface temperature of a body in radiative balance with its stars, warmed by
## whatever greenhouse it has. eps is the effective emissivity: 0.61 puts Earth
## at 288 K for S = 1 and an albedo of 0.3, and 1.0 is an airless rock.
static func surface_temp_k(S: float, albedo: float, eps: float) -> float:
	var Teq := 278.6 * pow(maxf(S, 1e-9) * (1.0 - albedo), 0.25)
	return Teq / pow(maxf(eps, 1e-3), 0.25)

# ---------------------------------------------------------------------------
static func create_rocky_visual(b: Body, opts: Dictionary = {}) -> RockyViz:
	return RockyViz.new(b, opts)

## The visual object (PORT_GUIDE.md §7). Fields mirror the web build's b.viz:
## group, core, surface, clouds, atmo, surf_mat, cloud_mat, atmo_mat, base_r,
## R, is_rocky; plus update(dt, ctx).
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
		# The sea-level datum this body was BUILT with. A world that bakes past the
		# boiling point loses its ocean, and the way that is expressed here is the
		# datum dropping (see the note on uSeaKm above) — so the undried value has
		# to be kept, or there is nothing to come back to when it cools.
		sea_km0 = float(surf_opts.seaKm)

		if b.spin == null:
			b.spin = (0.4 + randf() * 1.2) * (-1.0 if randf() < 0.1 else 1.0)
		b.viz = self

	func _u(m: ShaderMaterial, k: String) -> float:
		return float(m.get_shader_parameter(k))

	func update(dt: float, ctx: Dictionary) -> void:
		var b := body
		# Both phases wrap: the rotation reaches the GPU as a float32 matrix entry,
		# and once its magnitude passes ~1e5 the per-frame increment is under one
		# ulp and the spin quantises and then stops. A rotation is exactly
		# 2*pi-periodic, so wrapping costs nothing.
		var parent: Body = null
		var tl = opts.get("tidalLock")
		if RockyVisual.truthy(tl) and ctx.has("bodies") and ctx.bodies != null:
			for x in ctx.bodies:
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

		# The body works out its own temperature from where it currently is. This
		# is what makes the appearance a consequence rather than a setting: edit a
		# planet's orbit in flight and its ice line moves.
		var suns = Suns.lit_by(ctx)
		if suns != null:
			# Insolation from the real stars where there are any; where there are
			# none, the stand-in disc light's own intensity, so the body's
			# temperature and its lighting rest on the same assumption instead of
			# disagreeing (a lit planet at 0 K would frost over solid).
			var real_suns: bool = ctx.has("suns") and ctx.suns != null and not ctx.suns.is_empty()
			var S: float = Suns.insolation_at(b, ctx.suns) if real_suns else float(suns[0].intensity)
			var T: float
			if opts.get("surfaceK") != null:
				T = float(opts.surfaceK)
			elif S > 1e-8:
				T = RockyVisual.surface_temp_k(S, albedo, eps)
			else:
				T = float(U.nz(opts.get("meanK"), 60.0))
			var mk := _u(surf_mat, "uMeanK")
			surf_mat.set_shader_parameter("uMeanK", mk + (T - mk) * minf(1.0, dt * 2.0))

			# THE HOT END IS A CONSEQUENCE TOO. The cold end always was — everything
			# freezes out below its own condensation point, and the caps follow the
			# temperature this update already derives. The hot end was not: the
			# uniforms that dry a world out (uSeaKm, uScorch, uArid) were driven only
			# by the energy-balance model in sim/world.gd, which exists for the one
			# home world a scenario may have. So an ordinary planet at 388 K — inside
			# the inner edge of its star's habitable zone, past the runaway
			# greenhouse — was drawn with oceans and fair-weather cloud, which is the
			# one thing the habitable-zone lesson must not show.
			#
			# ONLY FOR A BODY THAT HAS WATER TO LOSE. An airless cratered rock at
			# 440 K (Mercury) is not "scorched", it is just warm: there is no ocean
			# to boil and no vegetation to bake, and tinting it ochre and giving it
			# a red glow would be inventing a phenomenon. The gate is the atmosphere,
			# which is also what `dry` above keys off. A STATED surface temperature
			# counts: Venus's 737 K is stated because no greenhouse parameter reaches
			# it, and a world at 737 K under 92 bar of CO2 is the archetype of this
			# branch rather than an exception to it.
			if RockyVisual.truthy(opts.get("atmosphere")):
				# Near-Earth-pressure teaching model: dry out by water's boiling point.
				var boil := clampf((T - 350.0) / 23.15, 0.0, 1.0)
				surf_mat.set_shader_parameter("uSeaKm", sea_km0 + (-60.0 - sea_km0) * boil)
				surf_mat.set_shader_parameter("uScorch", clampf((T - 330.0) / 140.0, 0.0, 1.0))
				surf_mat.set_shader_parameter("uArid", minf(clampf((T - 310.0) / 80.0, 0.0, 1.0), 0.8))
				if cloud_mat != null:
					# Cloud does not simply vanish — a runaway greenhouse ends up under
					# MORE of it, not less (Venus is the reference case and is completely
					# covered). What goes is the fair-weather structure in between.
					var base := float(U.nz(opts.get("cloudCover"), 0.45))
					cloud_mat.set_shader_parameter("uCover", base + (1.0 - base) * clampf((T - 340.0) / 110.0, 0.0, 1.0))
			# The season is just where the star is, relative to the spin axis: the
			# sine of the sub-solar latitude. It falls out of the geometry the orrery
			# is already integrating, so a world on an eccentric or a chaotic orbit
			# gets the seasons that orbit actually gives it.
			var pole := tilt_q * Vector3.UP
			var sun_dir: Vector3 = (suns[0].pos_rel - group.position).normalized()
			surf_mat.set_shader_parameter("uDecl", pole.dot(sun_dir))
			var mats := [surf_mat]
			if cloud_mat != null: mats.append(cloud_mat)
			if atmo_mat != null: mats.append(atmo_mat)
			Suns.apply_suns(mats, suns, group.position)
