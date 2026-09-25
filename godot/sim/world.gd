class_name WorldVisual
extends RefCounted

# ============================================================================
# THE LIVING WORLD
# ----------------------------------------------------------------------------
# A rocky planet whose APPEARANCE IS DRIVEN BY THE CLIMATE MODEL: ice caps
# advance and retreat with the glaciated fraction the EBM is integrating, seas
# shrink as they boil away, cloud decks thicken with humidity, and the ground
# glows when it is hot enough to.
#
# It is lit by every star at once. That is the whole point — a Trisolaran
# sunset has two or three terminators crossing the disc at different angles,
# in different colours, and you can see it directly here.
#
# The terrain, the biomes and the atmosphere are the SAME ones every other
# solid planet gets (sim/rocky_visual.gd, over sim/terrain.gd). This file is
# only the wiring between the energy-balance model and those uniforms: a
# second terrain model here would be a second answer to what a rocky planet
# looks like, and the two would drift apart.
# ============================================================================

# Re-exported, as the web build re-exported them from sim/suns.js.
const MAX_SUNS := Suns.MAX_SUNS

static func apply_suns(materials: Array, suns: Array, target_rel: Vector3) -> void:
	Suns.apply_suns(materials, suns, target_rel)

static func create_world_visual(b: Body, opts: Dictionary = {}) -> WorldViz:
	return WorldViz.new(b, opts)

## The visual object (PORT_GUIDE.md §7): group, core, surface, clouds, atmo,
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

		# The spin axis is tilted — obliquity is what gives a world seasons on top of
		# whatever its orbit is already doing, and it also sets how steep the
		# pole-to-equator insolation gradient is (see RockyVisual.insolation_s2).
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
		# Both phases wrap. At system speeds this advances hundreds of radians per
		# frame, and the rotation reaches the GPU as a float32 matrix entry: once
		# the magnitude passes ~1e5 the per-frame increment is under one ulp and
		# the spin quantises and then stops. A rotation is exactly 2π-periodic, so
		# wrapping is free of artefacts — but the cloud deck super-rotates at 0.985
		# of the surface, so it needs its own accumulator rather than a scaled read
		# of spin_phase, which would jump at every wrap.
		b.spin_phase = fmod(b.spin_phase + (sim_dt / day) * TAU, TAU)
		b.cloud_phase = fmod(b.cloud_phase + (sim_dt / day) * TAU * 0.985, TAU)
		surface.rotation.y = b.spin_phase
		clouds.rotation.y = b.cloud_phase          # super-rotating cloud deck

		surf_mat.set_shader_parameter("uTime", _u(surf_mat, "uTime") + dt)
		# The cloud shader feeds uTime into fbm/ridged domains, which are not
		# periodic — wrapping it would pop the cloud field. Bound the sim-time term
		# instead: it is a drift cue, and above a few radians per frame the deck is
		# a blur anyway, so capping it costs nothing visually and keeps the uniform
		# growing at real-time rates.
		cloud_mat.set_shader_parameter("uTime", _u(cloud_mat, "uTime") + dt + minf(sim_dt * 40.0, 2.0))

		var cl = ctx.get("climate")
		if cl != null:
			# The EBM owns the global mean temperature AND the glaciated fraction.
			# Handing over both is deliberate: the shader would reach its own ice
			# line from the temperature alone, but the ice-albedo feedback means the
			# fraction is a state variable with hysteresis in it — a snowballed
			# planet stays snowballed at a temperature it would never have frozen
			# at. The picture has to show the state, not re-derive it.
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

		# feed the multi-star lighting. Through lit_by, so a climate world beside a
		# black hole in a starless scene is lit by the disc stand-in rather than
		# rendering as a flat silhouette — the same fallback the rocky and giant
		# visuals already take.
		var suns = Suns.lit_by(ctx)
		if suns != null:
			Suns.apply_suns([surf_mat, cloud_mat, atmo_mat], suns, group.position)
