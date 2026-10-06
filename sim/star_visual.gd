class_name StarVisual
extends RefCounted

# Photosphere, corona and activity pools driven by the canonical body.
# Physical temperatures stay separate from HDR display gain.
# Shader contracts: shaders/AGENTS.md; models: docs/physics/structure.md.

const MAX_SPOTS := 8
const MAX_FLARES := 4

const PHOTO_SHADER := preload("res://shaders/bodies/star_photo.gdshader")
const CORONA_SHADER := preload("res://shaders/bodies/star_corona.gdshader")
const CME_SHADER := preload("res://shaders/bodies/star_cme.gdshader")

## The corona is a screen-space billboard; its quad carries no shape the
## culler could reason about.
const NO_CULL_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

# Smoothstep on the CPU side, for driving the eruption timeline.
static func smoothstep01(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

static func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

static func _photosphere_material(color: Color, hot_color: Color, limb_u: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PHOTO_SHADER
	m.set_shader_parameter("uColor", _v3(color))
	m.set_shader_parameter("uHot", _v3(hot_color))
	m.set_shader_parameter("uLimbU", limb_u)
	# Gain just past 1.0, so the disc sits on the tone curve's shoulder and keeps its
	# limb darkening, granulation and spots. Bloom and lights carry the brightness.
	m.set_shader_parameter("uGain", 1.0)
	m.set_shader_parameter("uGranScale", 9.0)
	var z4 := PackedVector4Array(); z4.resize(MAX_SPOTS)
	m.set_shader_parameter("uSpots", z4)
	var f4 := PackedVector4Array(); f4.resize(MAX_FLARES)
	m.set_shader_parameter("uFlares", f4)
	m.set_shader_parameter("uFlareAxis", f4)
	return m

# Corona / aureole: a CAMERA-FACING BILLBOARD rather than a sphere shell — see
# shaders/bodies/star_corona.gdshader.
static func _corona_material(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = CORONA_SHADER
	m.set_shader_parameter("uColor", _v3(color))
	return m

# A CORONAL MASS EJECTION's three parts: a bright swept-up leading edge, a dark
# cavity (the erupting flux rope), and a bright prominence core. Two additive shells
# with a gap; the gap is the cavity. Weighted by path length through the shell, so
# it renders as an arc with legs rather than a hard crescent.
static func _cme_material(color: Color, rim_pow: float, fil_scale: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = CME_SHADER
	m.set_shader_parameter("uColor", _v3(color))
	m.set_shader_parameter("uRimPow", rim_pow)
	m.set_shader_parameter("uFil", fil_scale)
	m.set_shader_parameter("uPlasmaT", 1.6e6)
	return m

static func _sphere(radius: float, radial: int, rings: int) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	s.radial_segments = radial
	s.rings = rings
	return s

## opts from attach_visual: radiusScene, teff, color (linear Color or null), oblate,
## spinFrac, tPole, tEq, gdBeta, radiusSun, quiet.
static func create_star_visual(b: Body, opts: VisualOpts) -> StarViz:
	var viz := StarViz.new(b, opts)
	b.viz = viz
	return viz

class StarViz:
	extends RefCounted
	var body: Body
	var group: Node3D
	var core: MeshInstance3D
	var mat: ShaderMaterial
	var corona: MeshInstance3D
	var corona_mat: ShaderMaterial
	var base_r: float
	var r: float
	var color_hex: int
	var is_star := true
	var is_hole := false
	var is_neutron := false
	var activity: Stellar.ActivityModel
	var stream = null                 # AccretionStream, attached by sim/bodies.gd
	var hot: Color
	var omega: float
	## uTime of the photosphere and of the corona (they advance together).
	var time := 0.0
	var corona_time := 0.0
	var erupt: Array = []             # [{holder, rope, arcade}]
	var cmes: Array = []              # [{holder, front, core, front_mat, core_mat, seed, time}]


	## Spin edits change shader deformation and colours; the flare pools retain their lifetime.
	func refresh_rotation() -> void:
		var teff := float(body.teff)
		var temps := Structure.gravity_darkened_temps(teff, body.spin_frac)
		mat.set_shader_parameter("uSpin", clampf(body.spin_frac, 0.0, 1.0))
		mat.set_shader_parameter("uGdBeta", temps.beta)
		mat.set_shader_parameter("uTpole", temps.tPole)
		mat.set_shader_parameter("uColPole", StarVisual._v3(Stellar.blackbody_color(temps.tPole)))
		mat.set_shader_parameter("uColEq", StarVisual._v3(Stellar.blackbody_color(temps.tEq)))
		var flattening := float(body.structure.get("flattening", 0.0))
		corona_mat.set_shader_parameter("uSize", core.mesh.radius * 4.0 / (1.0 - flattening))

	func _init(b: Body, opts: VisualOpts) -> void:
		body = b
		group = Node3D.new()
		var R: float = opts.radius_scene
		var teff: float = float(U.nz(opts.teff, 5772.0))
		var photo: Color = opts.color if opts.color is Color else Stellar.blackbody_color(teff)
		hot = Stellar.corona_color(teff)

		# Limb darkening is stronger for cool stars, weaker for hot ones.
		var limb_u := clampf(0.85 - (teff - 3000.0) / 22000.0, 0.32, 0.85)

		mat = StarVisual._photosphere_material(photo, hot, limb_u)
		mat.set_shader_parameter("uTeff", teff)
		omega = Stellar.rotation_rate(b.mass) * 0.02   # slowed for legibility
		mat.set_shader_parameter("uOmega", omega)
		# Granule size from the pressure scale height (a red supergiant has a few vast cells).
		var rad_sun: float = float(U.nz(opts.radius_sun, (b.radius / 0.00465047) if b.radius > 0.0 else 1.0))
		mat.set_shader_parameter("uGranScale", Structure.granule_frequency(teff, rad_sun, b.mass))
		# Disc brightness from Stefan–Boltzmann (0.15 to 200 across the sim's stars), carried
		# in HDR and rolled off once.
		mat.set_shader_parameter("uGain", Structure.surface_brightness(teff))
		core = MeshInstance3D.new()
		core.name = "Photosphere"
		core.mesh = StarVisual._sphere(R, 64, 48)
		core.material_override = mat
		core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The Roche surface reaches 1.5 R at the equator; the mesh's own AABB is
		# the sphere, so give the culler the spheroid's extent.
		core.extra_cull_margin = R * 0.5
		group.add_child(core)

		# Corona billboard: the quad spans ±1 and uCore is the photosphere's radius in quad
		# units. Sized to the largest radius (up to 1.5 R at the equator), not the polar one.
		var Rmax: float = R * float(U.nz(opts.oblate, 1.0))
		var CORONA_SPAN := 4.0                       # in stellar radii
		corona_mat = StarVisual._corona_material(hot)
		corona_mat.set_shader_parameter("uSize", Rmax * CORONA_SPAN)
		corona_mat.set_shader_parameter("uCore", 1.0 / CORONA_SPAN)
		corona = MeshInstance3D.new()
		corona.name = "Corona"
		var quad := QuadMesh.new()
		quad.size = Vector2(2, 2)
		corona.mesh = quad
		corona.material_override = corona_mat
		corona.custom_aabb = StarVisual.NO_CULL_AABB
		corona.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		corona_mat.render_priority = -1
		group.add_child(corona)
		refresh_rotation()

		# Prominence pool, two arcades per concurrent flare (sim/prominence.gd): the erupting
		# flux rope, which rises and fades, and the post-flare arcade, which stays, grows and
		# cools. H-α is the same red-orange on any star; only the footpoints take the star's
		# colour.
		var chromo := U.lin(0xff6a44)
		var foot := hot.lerp(U.lin(0xffffff), 0.55)
		for i in StarVisual.MAX_FLARES:
			var holder := Node3D.new()
			var rope := Prominence.create_arcade(chromo, foot)
			var arcade := Prominence.create_arcade(chromo, foot)
			holder.add_child(rope.group)
			holder.add_child(arcade.group)
			holder.visible = false
			group.add_child(holder)
			erupt.append({"holder": holder, "rope": rope, "arcade": arcade})

		# CME pool — a leading edge and a core per event, with the cavity between
		# them left empty because that is what a cavity is.
		var cme_geo := StarVisual._sphere(1.0, 40, 28)
		for i in 3:
			var front_mat := StarVisual._cme_material(hot, 1.7, 5.0)
			var core_mat := StarVisual._cme_material(chromo, 1.25, 8.0)
			core_mat.set_shader_parameter("uPlasmaT", 1.2e4)
			var front := MeshInstance3D.new()
			front.mesh = cme_geo
			front.material_override = front_mat
			front.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var cm := MeshInstance3D.new()
			cm.mesh = cme_geo
			cm.material_override = core_mat
			cm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var holder := Node3D.new()
			holder.add_child(front)
			holder.add_child(cm)
			holder.visible = false
			group.add_child(holder)
			cmes.append({"holder": holder, "front": front, "core": cm, "front_mat": front_mat,
				"core_mat": core_mat, "seed": randf() * 40.0, "time": 0.0})

		activity = Stellar.ActivityModel.new(b.mass)
		# Degenerate stars have no dynamo: no spots, no flares.
		if opts.quiet:
			activity.regions.clear()
			activity.next = INF
		b.activity = activity

		base_r = R
		r = R
		color_hex = U.hex_of(photo)

	func update(dt: float, ctx: VisualCtx) -> void:
		var sim_dt: float = ctx.sim_dt
		time += dt
		corona_time += dt
		mat.set_shader_parameter("uTime", time)
		corona_mat.set_shader_parameter("uTime", corona_time)

		activity.step(sim_dt)
		var R := r

		# --- publish live starspots (rotated to their current longitude)
		var spots := PackedVector4Array(); spots.resize(StarVisual.MAX_SPOTS)
		var sc := 0
		var t := time
		for reg in activity.regions:
			if sc >= StarVisual.MAX_SPOTS: break
			var lat: float = reg.lat
			var om := omega * (1.0 - 0.19 * pow(sin(lat), 2.0))
			var lon: float = reg.lon + om * t
			var cl := cos(lat)
			# spots grow then decay over their lifetime
			var age: float = reg.age / reg.life
			var s: float = reg.strength * pow(sin(minf(age, 1.0) * PI), 0.5)
			spots[sc] = Vector4(cl * cos(lon), sin(lat), cl * sin(lon), s)
			sc += 1
		mat.set_shader_parameter("uSpots", spots)
		mat.set_shader_parameter("uSpotCount", sc)

		# --- flares: the two ribbons on the surface, and the two arcades over it
		var fu := PackedVector4Array(); fu.resize(StarVisual.MAX_FLARES)
		var fa := PackedVector4Array(); fa.resize(StarVisual.MAX_FLARES)
		var fc := 0
		for e in erupt: e.holder.visible = false
		for f in activity.flares:
			if fc >= StarVisual.MAX_FLARES: break
			var reg: Dictionary = f.region
			var lat: float = reg.lat
			var om := omega * (1.0 - 0.19 * pow(sin(lat), 2.0))
			var lon: float = reg.lon + om * t
			var cl := cos(lat)
			var v := Vector3(cl * cos(lon), sin(lat), cl * sin(lon))

			# JOY'S LAW: a bipole lies near east-west, tilted by about half the latitude with
			# the leading polarity equatorward, so every arcade in a hemisphere leans the same
			# way. The neutral line across it is the eruption's axis.
			var east := Vector3.UP.cross(v)
			if east.length_squared() < 1e-8: east = Vector3(1, 0, 0)   # straight over a pole
			east = east.normalized()
			var north := v.cross(east).normalized()
			var joy := 0.5 * lat
			var bip := (east * cos(joy) + north * sin(joy)).normalized()
			var nl := v.cross(bip).normalized()

			var x: float = minf(f.t / f.duration, 1.0)
			var E: float = minf(f.energy, 2.5)
			var scl := 0.55 + E * 0.42

			fu[fc] = Vector4(v.x, v.y, v.z, f.amp * minf(f.energy, 2.0))
			# The ribbons start almost on top of each other and draw apart as the
			# reconnection point climbs into higher, wider field.
			fa[fc] = Vector4(bip.x, bip.y, bip.z, (0.045 + 0.13 * minf(x * 2.2, 1.0)) * scl)

			var E2: Dictionary = erupt[fc]
			var holder: Node3D = E2.holder
			holder.visible = true
			# makeBasis(nl, v, bip): the columns are x = neutral line, y = local
			# vertical, z = bipole axis — exactly the arcade's own frame.
			holder.transform = Transform3D(Basis(nl, v, bip), v * R)

			# The rope: already there, torn loose early, gone by mid-event. Its
			# shear relaxes as it goes, because the shear is what is being spent.
			var rise := StarVisual.smoothstep01(0.02, 0.5, x)
			var rope_amp: float = minf(0.55 + f.amp * 0.9, 1.5) * (1.0 - StarVisual.smoothstep01(0.22, 0.62, x))
			var rope: Prominence.Arcade = E2.rope
			rope.group.visible = rope_amp > 0.01
			# An arcade runs many loop spans along its neutral line, or the loops pile into a ball.
			rope.set_params({
				"R": R, "span": 0.075 * scl, "len": 0.30 * scl, "height": 0.17 * scl,
				"shear": 0.95 - 0.55 * x, "twist": 0.8 + 1.1 * rise, "erupt": rise,
				"width": 0.011, "amp": rope_amp, "plasmaT": 1.2e4 + 2e6 * rise, "dt": dt,
			})

			# The post-flare arcade forms under the rope, rises with the reconnection point, and
			# cools. Square across the neutral line: the field has relaxed.
			var arc_amp: float = StarVisual.smoothstep01(0.05, 0.15, x) * minf(f.amp * 1.3 + 0.15, 1.4)
			var arcade: Prominence.Arcade = E2.arcade
			arcade.group.visible = arc_amp > 0.01
			arcade.set_params({
				"R": R, "span": (0.045 + 0.055 * minf(x * 2.0, 1.0)) * scl, "len": 0.34 * scl,
				"height": (0.040 + 0.095 * minf(x * 2.0, 1.0)) * scl,
				"shear": 0.30 * (1.0 - x), "twist": 0.22, "erupt": 0.0,
				"width": 0.009, "amp": arc_amp, "plasmaT": 1.5e7 * exp(-x * 1.6) + 3e5, "dt": dt,
			})
			fc += 1
		mat.set_shader_parameter("uFlares", fu)
		mat.set_shader_parameter("uFlareAxis", fa)
		mat.set_shader_parameter("uFlareCount", fc)

		# --- CMEs
		for i in cmes.size():
			var slot: Dictionary = cmes[i]
			if i >= activity.cmes.size():
				slot.holder.visible = false
				continue
			var c: Dictionary = activity.cmes[i]
			slot.holder.visible = true
			# The core trails the front: the rope is inside the shell it is
			# driving, and the gap between them widens as the whole thing expands.
			(slot.front as Node3D).scale = Vector3.ONE * (c.radius * R)
			(slot.core as Node3D).scale = Vector3.ONE * (c.radius * R * 0.58)
			slot.time += dt
			var cdir: Vector3 = c.dir
			for pair in [[slot.front_mat, 0.5], [slot.core_mat, 0.75]]:
				var m: ShaderMaterial = pair[0]
				m.set_shader_parameter("uAlpha", c.alpha * pair[1])
				m.set_shader_parameter("uDir", cdir)
				m.set_shader_parameter("uSeed", slot.seed)
				m.set_shader_parameter("uTime", slot.time)
			# The core occupies the inner part of the same cone.
			slot.front_mat.set_shader_parameter("uWidth", c.width)
			slot.core_mat.set_shader_parameter("uWidth", c.width * 0.55)

		# --- brightness: slow pulsation + flare contribution
		var pulse := 1.0 + sin(ctx.time * 0.6 + body.id) * 0.02
		core.scale = Vector3.ONE * pulse
		mat.set_shader_parameter("uPulse", activity.flux)
		# The corona billboard carries only streamers and the inner aureole; bloom makes the
		# soft halo.
		corona_mat.set_shader_parameter("uFlux", 0.15 + (activity.flux - 1.0) * 0.8)

		if stream != null:
			Bodies.update_accretion_stream(body, ctx, stream, dt)
