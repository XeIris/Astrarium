class_name WorldVisual
extends RefCounted

# THE LIVING WORLD: a rocky planet whose appearance follows the climate model (ice
# caps with the EBM's glaciated fraction, seas boiling away, cloud with humidity,
# glowing ground when hot), lit by every star at once. Terrain, biomes and
# atmosphere are rocky_visual.gd's; this file only wires the EBM into those uniforms.

# Re-exported from sim/suns.gd.
const MAX_SUNS := Suns.MAX_SUNS

static func apply_suns(materials: Array, suns: Array, target_rel: Vector3) -> void:
	Suns.apply_suns(materials, suns, target_rel)

static func create_world_visual(b: Body, opts: Dictionary = {}) -> WorldViz:
	return WorldViz.new(b, opts)

## The visual object (docs/godot.md): group, core, surface, clouds, atmo,
## surf_mat, cloud_mat, atmo_mat, base_r, R, is_world; plus update(dt, ctx).
class WorldViz extends RefCounted:
	var group: Node3D
	var core: MeshInstance3D
	var surface: MeshInstance3D
	var clouds: MeshInstance3D
	var atmo: MeshInstance3D
	var surf_mat: ShaderMaterial
	var cloud_mat: ShaderMaterial
	var atmo_mat: ShaderMaterial
	var base_r: float
	var R: float
	var is_world := true
	var body: Body

	func _init(b: Body, opts: Dictionary) -> void:
		body = b
		group = Node3D.new()
		group.name = "World_%s" % b.name
		R = float(opts.get("radiusScene", 1.0))
		base_r = R
		var seed := float(RockyVisual.id_hash(b.id) % 1000) / 7.3

		surf_mat = RockyVisual.surface_material(seed, {
			# A world the climate model is standing on is by construction one with
			# oceans, air and life on it.
			"continent": U.nz(opts.get("land"), 0.34),
			"biota": 1.0,
			"crater": 0.0,
			"haze": 0.45,
			"frostK": 273.0,
			"transport": 0.42,
		})
		RockyVisual.bind_planet_map(surf_mat, b.name)
		surface = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R, 96, 64), surf_mat)
		surface.name = "Surface"
		group.add_child(surface)
		core = surface

		cloud_mat = RockyVisual.cloud_material(seed + 3.7)
		clouds = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R * 1.008, 64, 48), cloud_mat)
		clouds.name = "Clouds"
		group.add_child(clouds)

		atmo_mat = RockyVisual.atmosphere_material(opts.get("atmColor"))
		atmo = RockyVisual.mesh_instance(RockyVisual.sphere_geometry(R * 1.035, 72, 48), atmo_mat)
		atmo.name = "Atmosphere"
		group.add_child(atmo)

		# Obliquity: seasons, and the pole-to-equator gradient (RockyVisual.insolation_s2).
		var tilt := float(U.nz(opts.get("obliquity"), 0.35))
		group.rotation.z = tilt
		surf_mat.set_shader_parameter("uS2", RockyVisual.insolation_s2(tilt))

		b.spin_phase = 0.0
		b.cloud_phase = 0.0
		b.viz = self

	func _u(m: ShaderMaterial, k: String) -> float:
		return float(m.get_shader_parameter(k))

	func update(dt: float, ctx: Dictionary) -> void:
		var b := body
		var sim_dt := float(U.nz(ctx.get("sim_dt"), 0.0))
		# planet rotation — b.day_length is in years
		var day := b.day_length if b.day_length != 0.0 else 0.01
		# Wrap both phases (float32 rotation stops advancing past ~1e5). The cloud deck
		# super-rotates at 0.985, so it has its own accumulator.
		b.spin_phase = fmod(b.spin_phase + (sim_dt / day) * TAU, TAU)
		b.cloud_phase = fmod(b.cloud_phase + (sim_dt / day) * TAU * 0.985, TAU)
		surface.rotation.y = b.spin_phase
		clouds.rotation.y = b.cloud_phase          # super-rotating cloud deck

		surf_mat.set_shader_parameter("uTime", _u(surf_mat, "uTime") + dt)
		# uTime feeds non-periodic noise, so cap the sim-time term instead of wrapping it.
		cloud_mat.set_shader_parameter("uTime", _u(cloud_mat, "uTime") + dt + minf(sim_dt * 40.0, 2.0))

		var cl = ctx.get("climate")
		if cl != null:
			# The EBM owns both mean temperature and glaciated fraction: the ice-albedo
			# hysteresis means ice is state (a snowball stays frozen), not derivable from T.
			var T := float(cl.get("T"))
			surf_mat.set_shader_parameter("uMeanK", T)
			surf_mat.set_shader_parameter("uIce", float(cl.get("ice")))
			# Oceans retreat as the world bakes past the boiling point: the datum
			# drops, in kilometres, until the abyssal plains are dry land.
			var boil := clampf((T - 350.0) / 90.0, 0.0, 1.0)
			surf_mat.set_shader_parameter("uSeaKm", -boil * 5.0)
			surf_mat.set_shader_parameter("uScorch", clampf((T - 330.0) / 140.0, 0.0, 1.0))
			surf_mat.set_shader_parameter("uArid", clampf((T - 310.0) / 80.0, 0.0, 0.8))
			cloud_mat.set_shader_parameter("uCover", float(cl.get("clouds")))
			cloud_mat.set_shader_parameter("uStorm", float(U.nz(cl.get("storm"), 0.2)))
			atmo_mat.set_shader_parameter("uThick", 0.6 + float(cl.get("humidity")) * 0.8)

		# Through lit_by, so a starless scene uses the disc stand-in light.
		var suns = Suns.lit_by(ctx)
		if suns != null:
			Suns.apply_suns([surf_mat, cloud_mat, atmo_mat], suns, group.position)
