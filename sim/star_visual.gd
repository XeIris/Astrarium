class_name StarVisual
extends RefCounted

# ============================================================================
# HIGH-FIDELITY STAR RENDERING
# ----------------------------------------------------------------------------
# The photosphere shader (shaders/bodies/star_photo.gdshader) models, in one
# pass:
#   · granulation — convective cells, two octaves of fBm advected in time
#   · differential rotation — the equator laps the poles (real: Sun 25 d vs 34 d)
#   · starspots — dark umbra + warm penumbra + bright surrounding faculae,
#     placed at the ActivityModel's live active regions
#   · flare ribbons — the TWO ribbons that straddle a flare's neutral line
#     and separate as reconnection climbs (see sim/prominence.gd)
#   · limb darkening — the physically correct I(μ)/I(0) = 1 − u(1 − μ) law
#   · a chromospheric H-α rim glowing just past the limb
# Everything is driven by mass → Teff → colour, so an M dwarf and a B star look
# genuinely different rather than being recoloured copies.
#
# PORT NOTES.
#   · createStarVisual's closure is the StarViz class below (PORT_GUIDE.md §1:
#     a GDScript lambda captures by value). Its fields are the web viz's in
#     snake_case: group, core, mat, corona, base_r, r, color_hex, is_star,
#     activity — plus stream, which sim/bodies.gd attaches.
#   · Uniform clocks (uTime on each material) are accumulated in members and
#     pushed, never read back from the material.
#   · Colours: the photosphere colours are Planck-fit colours built from
#     FLOATS in the web build, so they are linear and passed raw; the one hex
#     here (the H-α prominence colour 0xff6a44) went through THREE.Color and
#     is U.lin().
# ============================================================================

const MAX_SPOTS := 8
const MAX_FLARES := 4

const PHOTO_SHADER := preload("res://shaders/bodies/star_photo.gdshader")
const CORONA_SHADER := preload("res://shaders/bodies/star_corona.gdshader")
const CME_SHADER := preload("res://shaders/bodies/star_cme.gdshader")

## The corona is a screen-space billboard; its quad carries no shape the
## culler could reason about (web: frustumCulled = false).
const NO_CULL_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

# Smoothstep on the CPU side, for driving the eruption timeline.
static func smoothstep01(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

static func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

# ----------------------------------------------------------------------------
# Two display relations from sim/structure.js. They belong to the structure
# model, and sim/structure.gd is being ported in parallel; until it exports
# them (granule_frequency / surface_brightness), these are exact copies. When
# it does, _structure() below routes to it and these become dead.
# ----------------------------------------------------------------------------
const _G_SI := 6.67430e-11
const _M_SUN := 1.98892e30      # kg
const _R_SUN := 6.957e8         # m
const _K_B := 1.380649e-23
const _M_H := 1.6735575e-27
const _HP_OVER_R_SUN := 4.16e-4

## Granule size from the pressure scale height H_p = kT/(μ m_H g) as a
## fraction of the radius — a noise frequency normalised so the Sun keeps
## the value that was tuned by eye for it.
static func _granule_frequency(teff: float, radius_sun: float, mass_sun: float) -> float:
	var R := maxf(radius_sun, 1e-6) * _R_SUN
	var M := maxf(mass_sun, 1e-6) * _M_SUN
	var hp := (_K_B * teff * R) / (0.62 * _M_H * _G_SI * M)
	var cells := _HP_OVER_R_SUN / maxf(hp, 1e-9)
	# The floor is not physical, it is the shader's: below ~1.5 the fBm has less
	# than one full period across the sphere and stops reading as cells at all.
	return minf(maxf(40.0 * cells, 1.5), 80.0)

## How bright to DRAW a photosphere: the eye's response to σT⁴, (T/T☉)^(4/3),
## capped where the bloom kernel runs out of extent (see sim/structure.js).
static func _surface_brightness(teff: float) -> float:
	return minf(pow(maxf(teff, 500.0) / 5772.0, 4.0 / 3.0), 12.0)

static func _structure(fn: String, args: Array, fallback: Callable) -> float:
	var S = load("res://sim/structure.gd")
	if S != null and fn in S.get_script_method_list().map(func(m): return m.name):
		return float(S.callv(fn, args))
	return float(fallback.callv(args))

# ---------------------------------------------------------------------------
static func _photosphere_material(color: Color, hot_color: Color, limb_u: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PHOTO_SHADER
	m.set_shader_parameter("uColor", _v3(color))
	m.set_shader_parameter("uHot", _v3(hot_color))
	m.set_shader_parameter("uLimbU", limb_u)
	# Just past 1.0. The disc has to land ON the tone curve's shoulder, not
	# beyond it: photograph the Sun in white light and you get an obviously
	# limb-darkened disc with granulation and spots on it, not a uniform
	# white circle. Overdrive it and ACES flattens every one of those
	# features into the same clipped white — which is exactly the look this
	# was meant to get rid of. Brightness is carried by the bloom halo and
	# by the real lights instead.
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

# ---------------------------------------------------------------------------
# A CORONAL MASS EJECTION.
# ----------------------------------------------------------------------------
# A CME has a three-part structure, and it has had one in every coronagraph
# image since OSO-7 saw the first of them in 1971:
#
#   · a BRIGHT LEADING EDGE — coronal material swept up and compressed ahead
#     of the eruption, a thin shell,
#   · a DARK CAVITY behind it — the evacuated flux rope itself, which is the
#     thing that is actually erupting, and
#   · a BRIGHT CORE inside that — the prominence material the rope is
#     carrying out with it, which is the same cool plasma that was hanging in
#     the arcade a few minutes earlier (see sim/prominence.gd).
#
# So it is drawn as two thin shells with a gap between them, additively, and
# the gap IS the cavity: nothing needs to darken anything.
#
# The other half of it is that a thin shell is brightest where you look ALONG
# it. Shaded as an ordinary surface, a shell renders as a solid crescent with
# a hard silhouette, which is what this used to be; weighted by the path
# length through it — long at the rim, short face-on — the same geometry
# renders as the arc-and-legs shape a CME actually has.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
## opts: the dictionary attachVisual builds — radiusScene, teff, color (a
## LINEAR Color for star-likes, or null), oblate, spinFrac, tPole, tEq,
## gdBeta, radiusSun, quiet.
static func create_star_visual(b: Body, opts: Dictionary) -> StarViz:
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

	func _init(b: Body, opts: Dictionary) -> void:
		body = b
		group = Node3D.new()
		var R: float = opts.radiusScene
		var teff: float = float(U.nz(opts.get("teff"), 5772.0))
		var photo: Color = opts.color if opts.get("color") is Color else Stellar.blackbody_color(teff)
		hot = Stellar.corona_color(teff)

		# Limb darkening is stronger for cool stars, weaker for hot ones.
		var limb_u := clampf(0.85 - (teff - 3000.0) / 22000.0, 0.32, 0.85)

		mat = StarVisual._photosphere_material(photo, hot, limb_u)
		mat.set_shader_parameter("uTeff", teff)
		# Rotation, from the structure model (sim/structure.gd) via sim/bodies.gd.
		var spin := clampf(float(U.nz(opts.get("spinFrac"), 0.0)), 0.0, 1.0)
		mat.set_shader_parameter("uSpin", spin)
		mat.set_shader_parameter("uGdBeta", float(U.nz(opts.get("gdBeta"), 0.25)))
		var t_pole = opts.get("tPole")
		var t_eq = opts.get("tEq")
		mat.set_shader_parameter("uTpole", float(U.nz(t_pole, teff)))
		# `opts.tPole ? … : photo` — a 0 or missing temperature falls back.
		mat.set_shader_parameter("uColPole", StarVisual._v3(Stellar.blackbody_color(t_pole) if (t_pole != null and t_pole > 0) else photo))
		mat.set_shader_parameter("uColEq", StarVisual._v3(Stellar.blackbody_color(t_eq) if (t_eq != null and t_eq > 0) else photo))
		omega = Stellar.rotation_rate(b.mass) * 0.02   # slowed for legibility
		mat.set_shader_parameter("uOmega", omega)
		# Granule size from the pressure scale height rather than from mass — see
		# granuleFrequency() in sim/structure.js. This is what turns a red supergiant
		# from a scaled-up Sun into a surface made of three or four vast cells.
		var rad_sun: float = float(U.nz(opts.get("radiusSun"), (b.radius / 0.00465047) if b.radius > 0.0 else 1.0))
		mat.set_shader_parameter("uGranScale", StarVisual._structure("granule_frequency",
			[teff, rad_sun, b.mass], StarVisual._granule_frequency))
		# Disc brightness from Stefan–Boltzmann. Every star used to be drawn at the
		# same surface brightness, which is why a 3600 K supergiant came out the same
		# white as a 10 000 K A star; the tone curve then finished the job. F ∝ T⁴
		# spans 0.15 to 200 over the stars in this sim, and the HDR buffer is there
		# precisely so that range can be carried and rolled off once at the end.
		mat.set_shader_parameter("uGain", StarVisual._structure("surface_brightness",
			[teff], StarVisual._surface_brightness))
		core = MeshInstance3D.new()
		core.name = "Photosphere"
		core.mesh = StarVisual._sphere(R, 64, 48)
		core.material_override = mat
		core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The Roche surface reaches 1.5 R at the equator; the mesh's own AABB is
		# the sphere, so give the culler the spheroid's extent.
		core.extra_cull_margin = R * 0.5
		group.add_child(core)

		# corona billboard. The quad spans ±1 and is scaled in the vertex shader, so
		# uCore is the photosphere's radius in quad units — the glow starts exactly
		# at the stellar limb however far away the camera is.
		# The photosphere is R at the pole but up to 1.5 R at the equator, and the
		# corona is a screen-space billboard with no idea about that — sized to the
		# polar radius it would cut across a fast rotator's own bulge. Size it to the
		# largest radius the star actually reaches.
		var Rmax: float = R * float(U.nz(opts.get("oblate"), 1.0))
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
		corona_mat.render_priority = -1              # the web's renderOrder = -1
		group.add_child(corona)

		# Prominence pool, two arcades per possible concurrent flare — see
		# sim/prominence.gd. They are two different things and both are always
		# present in a real event: the ERUPTING FLUX ROPE, which is the filament
		# that was sitting there beforehand tearing itself off and leaving, and the
		# POST-FLARE ARCADE, the row of hot loops that forms underneath it as the
		# field reconnects and closes back down. The rope rises and fades; the
		# arcade stays, grows taller, and cools.
		#
		# Halpha is Halpha whatever the star is, so the cool prominence material is
		# the same red-orange on a B star as on an M dwarf; only the footpoints,
		# heated by the beam, take the star's own hot continuum colour.
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
		# Degenerate stars have no convection zone to run a dynamo, so no spots and
		# no flares. Emptying the regions and pushing the next arrival past any
		# watchable timescale leaves the same object with its magnetism switched off.
		if opts.get("quiet", false):
			activity.regions.clear()
			activity.next = INF
		b.activity = activity

		base_r = R
		r = R
		color_hex = U.hex_of(photo)

	func update(dt: float, ctx: Dictionary) -> void:
		var sim_dt: float = float(U.nz(ctx.get("sim_dt"), dt))
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

			# JOY'S LAW. An active region is a bipole, and it is not oriented at
			# random: it lies very nearly east-west with a tilt that grows with
			# latitude — about half the latitude, leading polarity equatorward — so
			# every arcade in a given hemisphere leans the same way. The neutral
			# line runs across the bipole, and that is the axis the whole eruption
			# is built on.
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
			# An arcade is LONG compared with the loops in it — a neutral line runs
			# for many times a single loop's span, which is why the thing reads as a
			# row. Make it short and the loops pile up on each other into a ball of
			# wool, which is what one tube was trying to avoid in the first place.
			rope.set_params({
				"R": R, "span": 0.075 * scl, "len": 0.30 * scl, "height": 0.17 * scl,
				"shear": 0.95 - 0.55 * x, "twist": 0.8 + 1.1 * rise, "erupt": rise,
				"width": 0.011, "amp": rope_amp, "plasmaT": 1.2e4 + 2e6 * rise, "dt": dt,
			})

			# The post-flare arcade: forms under the rope once reconnection starts,
			# grows taller as the reconnection point rises, and cools for the rest
			# of the event. It is square across the neutral line, not sheared —
			# that is what it means for the field to have relaxed.
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
		var pulse := 1.0 + sin(float(ctx.get("time", 0.0)) * 0.6 + body.id) * 0.02
		core.scale = Vector3.ONE * pulse
		mat.set_shader_parameter("uPulse", activity.flux)
		# The corona billboard is now only the structured part — the streamers and
		# the tight inner aureole. The broad soft halo it used to have to fake is
		# produced for real by the bloom pass, so this is dialled well back to
		# stop the two stacking into a glowing ball.
		corona_mat.set_shader_parameter("uFlux", 0.15 + (activity.flux - 1.0) * 0.8)

		if stream != null:
			Bodies.accrete(body, ctx, stream, dt)
