class_name StarVisual
extends RefCounted

# Photosphere, corona and activity pools driven by the canonical body.
# Physical temperatures stay separate from HDR display gain.
# Shader contracts: shaders/AGENTS.md; models: docs/physics/structure.md.

const MAX_SPOTS := 8
const MAX_FLARES := 4
const MAX_QUIESCENT := 3

## The continuum's display level: under 1, so ACES keeps the disc's colour, limb
## darkening and spots instead of rolling them into white; bloom carries the glare. A
## disc that carries a chromosphere is drawn lower, because the chromosphere adds.
const DISC_LEVEL := 0.42
const DISC_LEVEL_BARE := 0.8
## The chromosphere's line emission is ~10⁻⁴ of the continuum in broadband light; it is
## drawn at this weight relative to the disc so the layer narrowband imagers see (H-α,
## He II 304 Å) is legible, the way bodies are drawn magnified.
const CHROMO_GAIN := 0.5
## Glare for a star brighter than the Sun, the exposure's reference (which has none). The
## disc is held under ACES's shoulder to keep its colour, so what it cannot carry goes round
## it as glare. Its peak stays under the bare disc's limb, so the disc is still the brightest
## thing drawn, and a brighter star spreads its glare wider instead.
const GLARE_GAIN := 0.35
const GLARE_PEAK := 0.8
const GLARE_WIDTH_PX := 40.0
## The fraction of the continuum the chromosphere hides when it is drawn.
const CHROMO_VEIL := 0.45
## H-α (656 nm) blended with He I D3 and the Ca II lines, as linear sRGB.
const CHROMO_COLOR := Color(1.0, 0.30, 0.09)

const PHOTO_SHADER := preload("res://shaders/bodies/star_photo.gdshader")
const CORONA_SHADER := preload("res://shaders/bodies/star_corona.gdshader")
const CME_SHADER := preload("res://shaders/bodies/star_cme.gdshader")
const ENVELOPE_SHADER := preload("res://shaders/bodies/star_envelope.gdshader")
## Dust scatters ~10⁻³ of the starlight it intercepts toward an observer at a few
## stellar radii; drawn at this gain so the shell around a dusty giant is legible.
const DUST_GAIN := 2.5
## A hot wind's line emission relative to the starlight it scatters, as drawn.
const WIND_GAIN := 1.5
const MAX_PUFFS := 4
const PUFF_CONDENSE := 0.6
## Grain opacity over the molecular opacity of the same gas, in the visible.
const DUST_BOOST := 8.0

## The corona is a screen-space billboard; its quad carries no shape the
## culler could reason about.
const NO_CULL_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

# Smoothstep on the CPU side, for driving the eruption timeline.
static func smoothstep01(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

## A puff's column through its centre relative to its launch, at width `sg` and distance
## `r`, holding its mass fixed. star_envelope.gdshader's density is n₀ exp(−d²) with a
## centre column τ = 1.77 σ n₀, transverse width σ, width σ ahead and s_l = σ + 0.7(r − 1)
## behind, where it also falls to 0.45 by one s_l. Its mass is then ∝ τ σ (0.886 σ +
## 0.636 s_l), the second being ∫₀^∞ e^−u² (1 − 0.55 min(u, 1)) du.
static func puff_column(sg: float, r: float) -> float:
	const SG0 := 0.18
	var sl := sg + 0.7 * (r - 1.0)
	return SG0 * SG0 * (0.886 + 0.636) / (sg * (0.886 * sg + 0.636 * sl))

## A photosphere at `teff` (K): x the glare at its limb, y the wing's width in pixels.
static func glare_of(teff: float) -> Vector2:
	var excess := GLARE_GAIN * maxf(Structure.surface_brightness(teff) - 1.0, 0.0)
	return Vector2(GLARE_PEAK * tanh(excess / GLARE_PEAK), GLARE_WIDTH_PX * sqrt(1.0 + excess))

static func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

static func _photosphere_material(color: Color, hot_color: Color, teff: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PHOTO_SHADER
	m.set_shader_parameter("uColor", _v3(color))
	m.set_shader_parameter("uHot", _v3(hot_color))
	var ld := Stellar.limb_darkening(teff)
	m.set_shader_parameter("uLimbA", ld[0])
	m.set_shader_parameter("uLimbB", ld[1])
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
	var loops: Array = []             # [{holder, arcade}], one per active region
	var corona_t := 2.0e6             # K, of the active-region loops
	var cmes: Array = []              # [{holder, front, core, front_mat, core_mat, seed, time}]
	var quiescent: Array = []         # [{holder, arcade, lat, lon, tilt, len, height}]
	## 1 with a convective envelope, 0 without; the chromosphere's display weight.
	var conv := 1.0
	var chromo_w := 0.0
	## 1 on a dwarf, 0 on a giant (by log g).
	var dwarf := 1.0
	## StarVisual.glare_of for this photosphere, the temperature it was taken at, and
	## whether the visible band is being imaged.
	var glare := Vector2.ZERO
	var glare_teff := NAN
	var glare_on := true
	## 1 with a hot corona, 0 past the Linsky–Haisch dividing line.
	var hotc := 1.0
	## Stellar.envelope_of, and the sphere it is marched through (null without one).
	var env: Dictionary = {}
	var envelope: MeshInstance3D = null
	var env_mat: ShaderMaterial = null
	## Ejected puffs: [{dir, r, speed (R/yr), tau, seed}]; the next one, in sim years.
	var ejecta: Array = []
	var eject_next := INF
	var env_rng := RandomNumberGenerator.new()


	## Ageing moves Teff without a rebuild.
	func _refresh_glare(teff: float) -> void:
		glare_teff = teff
		glare = StarVisual.glare_of(teff)
		corona_mat.set_shader_parameter("uGlareW", glare.y)
		set_band_visible(glare_on)

	## Glare stands in for visible light the disc can't carry; in another band the band
	## image's own bloom is the PSF.
	func set_band_visible(on: bool) -> void:
		glare_on = on
		corona_mat.set_shader_parameter("uGlare", glare.x if on else 0.0)

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
		corona_mat.set_shader_parameter("uFlat", flattening)
		corona_mat.set_shader_parameter("uSpin", clampf(body.spin_frac, 0.0, 1.0))

	func _init(b: Body, opts: VisualOpts) -> void:
		body = b
		group = Node3D.new()
		var R: float = opts.radius_scene
		var teff: float = float(U.nz(opts.teff, 5772.0))
		var photo: Color = opts.color if opts.color is Color else Stellar.blackbody_color(teff)
		hot = Stellar.corona_color(teff)

		mat = StarVisual._photosphere_material(photo, hot, teff)
		mat.set_shader_parameter("uTeff", teff)
		omega = Stellar.rotation_rate(b.mass) * 0.02   # slowed for legibility
		mat.set_shader_parameter("uOmega", omega)
		# Granule size from the pressure scale height (a red supergiant has a few vast cells).
		var rad_sun: float = float(U.nz(opts.radius_sun, (b.radius / 0.00465047) if b.radius > 0.0 else 1.0))
		mat.set_shader_parameter("uGranScale", Structure.granule_frequency(teff, rad_sun, b.mass))
		# Disc brightness from Stefan–Boltzmann (0.15 to 200 across the sim's stars), carried
		# in HDR and rolled off once.
		mat.set_shader_parameter("uGain", Structure.surface_brightness(teff))
		# No convective envelope, no granules, spots or chromosphere: an A or B star is a
		# smooth limb-darkened disc.
		conv = Structure.envelope_convection(teff)
		mat.set_shader_parameter("uConv", conv)
		var logg := Stellar.log_g(b.mass, rad_sun)
		mat.set_shader_parameter("uGranContrast", Stellar.granulation_contrast(teff, logg))
		# A giant's disc is its few vast convection cells; the network belongs to dwarfs.
		dwarf = StarVisual.smoothstep01(1.5, 3.5, logg)
		mat.set_shader_parameter("uSpotDT", Stellar.spot_temperature_drop(teff))
		mat.set_shader_parameter("uChromoCol", StarVisual._v3(StarVisual.CHROMO_COLOR))
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
		_refresh_glare(teff)
		corona_mat.set_shader_parameter("uGlareCol", StarVisual._v3(photo))
		group.add_child(corona)
		refresh_rotation()

		# Prominence pool, two arcades per concurrent flare (sim/prominence.gd): the erupting
		# flux rope, which rises and fades, and the post-flare arcade, which stays, grows and
		# cools. Chromospheric plasma is the same colour on any star; only the footpoints take
		# the star's colour.
		var chromo := StarVisual.CHROMO_COLOR
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

		# Active-region loops, one arcade per spot group: the hot (1–3 MK) closed field
		# over every bipole, there between flares too. Nearly invisible in white light,
		# they are what an X-ray or EUV image of the star is made of (TRACE, SDO 171 Å).
		var loop_col := StarVisual.CHROMO_COLOR.lerp(U.lin(0xffd9a0), 0.6)
		for i in StarVisual.MAX_SPOTS:
			var holder := Node3D.new()
			var arc := Prominence.create_arcade(loop_col, U.lin(0xffffff))
			arc.set_absorbs(false)
			holder.add_child(arc.group)
			holder.visible = false
			group.add_child(holder)
			loops.append({"holder": holder, "arcade": arc})

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
		# Coronal temperature rises with magnetic activity: ~2 MK on the Sun, several MK
		# on an active M dwarf (Güdel 2004). The active-region loops carry it.
		corona_t = minf(1.0e6 * (1.0 + activity.activity), 6.0e6)
		# Degenerate stars have no dynamo: no spots, no flares.
		if opts.quiet:
			activity.regions.clear()
			activity.next = INF
		b.activity = activity
		# Spots grow with activity: the Sun's largest groups span a few hundredths of a
		# radius, an active M dwarf's much of a hemisphere (Berdyugina 2005).
		var act_rel: float = activity.activity / Stellar.activity_level(1.0)
		mat.set_shader_parameter("uSpotSize", clampf(0.045 * pow(act_rel, 0.6), 0.02, 0.14))
		chromo_w = 0.0 if opts.quiet else StarVisual.CHROMO_GAIN * conv * clampf(sqrt(act_rel), 0.5, 2.0)
		var carried := dwarf if chromo_w > 0.0 else 0.0
		mat.set_shader_parameter("uChromo", chromo_w * (0.3 + 0.7 * dwarf))
		mat.set_shader_parameter("uVeil", StarVisual.CHROMO_VEIL * carried)
		# Under ACES a dim orange reads as brown, so a bare disc gives back part of the
		# surface-brightness compression; the order of the stars' brightness is kept.
		var bare := StarVisual.DISC_LEVEL_BARE / pow(maxf(Structure.surface_brightness(teff), 0.05), 0.7)
		mat.set_shader_parameter("uDisc", lerpf(bare, StarVisual.DISC_LEVEL, carried))
		# Past the dividing line a giant has no hot corona, spicules or hot loops.
		hotc = Stellar.hot_corona(teff, dwarf)
		corona_mat.set_shader_parameter("uChromoW", chromo_w * hotc)
		corona_mat.set_shader_parameter("uChromo", StarVisual._v3(StarVisual.CHROMO_COLOR))
		_build_envelope(b, R, teff, photo, float(mat.get_shader_parameter("uDisc")))

		# Quiescent prominences: long-lived hedgerows over the filament channels decayed
		# regions leave behind, and the polar crown at high latitude. Against the disc they
		# are filaments. Only a star with a chromosphere has them.
		if chromo_w > 0.0 and Stellar.hot_corona(teff, dwarf) > 0.5:
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(b.id) ^ 0x51f15e
			for i in StarVisual.MAX_QUIESCENT:
				var holder := Node3D.new()
				var arc := Prominence.create_arcade(StarVisual.CHROMO_COLOR, foot)
				holder.add_child(arc.group)
				holder.visible = false
				group.add_child(holder)
				var polar := i == 0
				var hemi := 1.0 if rng.randf() < 0.5 else -1.0
				quiescent.append({"holder": holder, "arcade": arc,
					"lat": hemi * (rng.randf_range(0.9, 1.1) if polar else rng.randf_range(0.25, 0.65)),
					"lon": rng.randf() * TAU, "tilt": 0.0 if polar else rng.randf_range(-0.8, 0.8),
					"len": rng.randf_range(0.40, 0.60) if polar else rng.randf_range(0.20, 0.34),
					"height": rng.randf_range(0.08, 0.15)})

		base_r = R
		r = R
		color_hex = U.hex_of(photo)

	## The envelope (Stellar.envelope_of): a sphere about the star marched by
	## star_envelope.gdshader, when there is a layer, dust or a hot wind to draw.
	func _build_envelope(b: Body, R: float, teff: float, photo: Color, disc: float) -> void:
		env = Stellar.envelope_of(b.structure, b.wind_mdot)
		var dusty: bool = float(env.dustTau) > 0.02
		var windy: bool = float(env.windTau) > 0.05
		if float(env.layerH) <= 0.0 and not dusty and not windy:
			return
		var reach := 1.0 + 8.0 * float(env.layerH)
		if dusty: reach = maxf(reach, float(env.dustR) * 2.0)
		# A star that ejects puffs needs room for them to condense, even when its steady
		# wind is too thin to draw dust: past where they finish turning (1.1 r_c).
		var ejects: bool = float(env.layerH) > 0.02 and float(env.ejectYr) < INF
		if ejects and float(env.dustR) > 0.0:
			reach = maxf(reach, float(env.dustR) * StarVisual.PUFF_CONDENSE * 1.5)
		if windy: reach = maxf(reach, 3.0)
		reach = clampf(reach, 1.2, 10.0)
		env_mat = ShaderMaterial.new()
		env_mat.shader = StarVisual.ENVELOPE_SHADER
		var ld := Stellar.limb_darkening(teff)
		var surf := StarVisual._v3(photo) * (Structure.surface_brightness(teff) * disc)
		for kv in [["uR", R], ["uEnv", reach], ["uTeff", teff], ["uSurf", surf],
				["uLimbA", ld[0]], ["uLimbB", ld[1]], ["uLayerH", env.layerH], ["uLayerTau", env.layerTau],
				["uCellK", mat.get_shader_parameter("uGranScale")], ["uDustR", env.dustR],
				["uDustTau", env.dustTau if dusty else 0.0], ["uDustGain", StarVisual.DUST_GAIN],
				["uWindTau", env.windTau if windy else 0.0], ["uWindGain", StarVisual.WIND_GAIN],
				["uNoise", Prominence.plasma_noise()]]:
			env_mat.set_shader_parameter(kv[0], kv[1])
		var z4 := PackedVector4Array(); z4.resize(StarVisual.MAX_PUFFS)
		env_mat.set_shader_parameter("uPuffA", z4)
		env_mat.set_shader_parameter("uPuffB", z4)
		envelope = MeshInstance3D.new()
		envelope.name = "Envelope"
		# Back faces of a sphere that circumscribes the envelope; the shader does the rest.
		envelope.mesh = StarVisual._sphere(R * reach * 1.06, 32, 16)
		envelope.material_override = env_mat
		envelope.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		group.add_child(envelope)
		env_rng.seed = hash(b.id) ^ 0x3e1f
		if ejects:
			eject_next = float(env.ejectYr) * env_rng.randf_range(0.2, 1.0)

	## Launch a puff of the envelope from direction `dir` (in the star's frame).
	func eject(dir: Vector3) -> Dictionary:
		var p := {"dir": dir.normalized(), "r": 1.0, "tau": 6.0, "seed": env_rng.randf() * 17.0,
			# km/s → stellar radii per year
			"speed": 45.4 * float(env.ejectKms) / maxf(float(body.structure.get("radiusSun", 1.0)), 1e-3) * env_rng.randf_range(0.6, 1.3)}
		ejecta.append(p)
		if ejecta.size() > StarVisual.MAX_PUFFS: ejecta.pop_front()
		return p

	## Puffs ride the sim clock, like the flares: they rise, spread, keep their mass
	## (puff_column) and turn to dust past the condensation radius.
	func _update_envelope(sim_dt: float) -> void:
		var reach: float = env_mat.get_shader_parameter("uEnv")
		eject_next -= sim_dt
		if eject_next <= 0.0:
			eject_next = float(env.ejectYr) * env_rng.randf_range(0.5, 1.6)
			eject(Vector3(env_rng.randfn(), env_rng.randfn(), env_rng.randfn()))
		var pa := PackedVector4Array(); pa.resize(StarVisual.MAX_PUFFS)
		var pb := PackedVector4Array(); pb.resize(StarVisual.MAX_PUFFS)
		var n := 0
		for i in range(ejecta.size() - 1, -1, -1):
			var p: Dictionary = ejecta[i]
			p.r = float(p.r) + float(p.speed) * sim_dt
			var sg := 0.18 + 0.16 * (float(p.r) - 1.0)
			# A puff's gas is denser than the wind's and condenses hotter, so closer in
			# (r ∝ T_c^−5/2: ~0.6 of the wind's radius for 1600 K against 1300 K). Once it
			# has, its opacity is the grains', several times the molecules': the Great
			# Dimming of Betelgeuse (Montargès et al. 2021). No grains form without a
			# condensation radius.
			var dusty := 0.0
			if float(env.dustR) > 0.0:
				var rc: float = float(env.dustR) * StarVisual.PUFF_CONDENSE
				dusty = StarVisual.smoothstep01(0.8 * rc, 1.1 * rc, float(p.r))
			var tau := float(p.tau) * StarVisual.puff_column(sg, float(p.r)) * lerpf(1.0, StarVisual.DUST_BOOST, dusty)
			if p.r > reach or tau < 0.02:
				ejecta.remove_at(i)
				continue
			var d: Vector3 = p.dir
			pa[n] = Vector4(d.x, d.y, d.z, p.r)
			pb[n] = Vector4(sg, tau, dusty, p.seed)
			n += 1
		env_mat.set_shader_parameter("uPuffA", pa)
		env_mat.set_shader_parameter("uPuffB", pb)
		env_mat.set_shader_parameter("uPuffCount", n)
		env_mat.set_shader_parameter("uTime", time)

	## A region's local vertical at display time t, turning with the surface's
	## differential rotation.
	func _region_up(reg: Dictionary, t: float) -> Vector3:
		var lat: float = reg.lat
		var lon: float = reg.lon + omega * (1.0 - 0.19 * pow(sin(lat), 2.0)) * t
		var cl := cos(lat)
		return Vector3(cl * cos(lon), sin(lat), cl * sin(lon))

	## JOY'S LAW: a bipole lies near east-west, tilted by about half the latitude with
	## the leading polarity equatorward, so every arcade in a hemisphere leans the same
	## way. Returns Basis(neutral line, local vertical, bipole axis): the arcade's own
	## frame (sim/prominence.gd).
	func _bipole(reg: Dictionary, t: float) -> Basis:
		var v := _region_up(reg, t)
		var east := Vector3.UP.cross(v)
		if east.length_squared() < 1e-8: east = Vector3(1, 0, 0)   # straight over a pole
		east = east.normalized()
		var north := v.cross(east).normalized()
		var joy := 0.5 * float(reg.lat)
		var bip := (east * cos(joy) + north * sin(joy)).normalized()
		return Basis(v.cross(bip).normalized(), v, bip)

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

		# --- active-region loops over each spot group, sized and lit by its strength
		var li := 0
		for reg in activity.regions:
			if li >= loops.size(): break
			var age: float = reg.age / reg.life
			var s: float = reg.strength * pow(sin(minf(age, 1.0) * PI), 0.5)
			var L: Dictionary = loops[li]
			var lh: Node3D = L.holder
			# A radiative envelope has no dynamo, and no loops over its regions.
			lh.visible = s > 0.02 and conv > 0.01 and hotc > 0.05
			if lh.visible:
				lh.transform = Transform3D(_bipole(reg, t), _region_up(reg, t) * R)
				var arc: Prominence.Arcade = L.arcade
				arc.group.visible = true
				var span := 0.035 + 0.05 * float(reg.strength)
				arc.set_params({
					"R": R, "span": span, "len": span * 1.6, "height": span * 1.1,
					"shear": 0.18, "twist": 0.15, "erupt": 0.0, "width": 0.005,
					"amp": minf(0.35 + s, 1.0) * conv, "plasmaT": corona_t, "apex": 1.0, "glow": 0.035, "dt": dt,
				})
			li += 1
		for i in range(li, loops.size()): loops[i].holder.visible = false

		# --- flares: the two ribbons on the surface, and the two arcades over it
		var fu := PackedVector4Array(); fu.resize(StarVisual.MAX_FLARES)
		var fa := PackedVector4Array(); fa.resize(StarVisual.MAX_FLARES)
		var fc := 0
		for e in erupt: e.holder.visible = false
		for f in activity.flares:
			if fc >= StarVisual.MAX_FLARES: break
			var reg: Dictionary = f.region
			var frame := _bipole(reg, t)
			var v := frame.y
			var bip := frame.z
			var nl := frame.x

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
			holder.transform = Transform3D(frame, v * R)

			# The rope: already there, torn loose early, gone by mid-event. Its
			# shear relaxes as it goes, because the shear is what is being spent.
			var rise := StarVisual.smoothstep01(0.02, 0.5, x)
			var rope_amp: float = minf(0.55 + f.amp * 0.9, 1.5) * (1.0 - StarVisual.smoothstep01(0.22, 0.62, x))
			var rope: Prominence.Arcade = E2.rope
			# Past the dividing line there is no hot corona to hold a rope or fill an arcade.
			rope.group.visible = rope_amp > 0.01 and hotc > 0.05
			# An arcade runs many loop spans along its neutral line, or the loops pile into a ball.
			rope.set_params({
				"R": R, "span": 0.075 * scl, "len": 0.30 * scl, "height": 0.17 * scl,
				"shear": 0.95 - 0.55 * x, "twist": 0.8 + 1.1 * rise, "erupt": rise,
				"width": 0.0055, "amp": rope_amp, "plasmaT": 1.2e4 + 2e6 * rise, "dt": dt,
				"kind": Prominence.ROPE, "flow": 0.25 + 0.5 * rise,
			})

			# The post-flare arcade forms under the rope, rises with the reconnection point, and
			# cools. Square across the neutral line: the field has relaxed.
			var arc_amp: float = StarVisual.smoothstep01(0.05, 0.15, x) * minf(f.amp * 1.3 + 0.15, 1.4)
			var arcade: Prominence.Arcade = E2.arcade
			arcade.group.visible = arc_amp > 0.01 and hotc > 0.05
			# Post-flare loops are filled at ~10⁷ K, invisible in white light, and appear in
			# H-α and He II only as they cool. Below ~2 MK they go thermally unstable and
			# strands condense into 10⁴ K rain (Antolin 2020): only that cool fraction
			# absorbs, while the loops' own plasma stays hot and transparent.
			var arc_t: float = 1.5e7 * exp(-x * 2.6) + 4e5
			var cooled := StarVisual.smoothstep01(6e6, 1.5e6, arc_t)
			var rain := StarVisual.smoothstep01(2.5e6, 1.5e6, arc_t)
			arcade.set_params({
				"R": R, "span": (0.045 + 0.055 * minf(x * 2.0, 1.0)) * scl, "len": 0.34 * scl,
				"height": (0.040 + 0.095 * minf(x * 2.0, 1.0)) * scl,
				"shear": 0.30 * (1.0 - x), "twist": 0.22, "erupt": 0.0,
				"width": 0.0075, "amp": arc_amp, "plasmaT": arc_t, "dt": dt,
				# Post-flare loops fill from the feet up (chromospheric evaporation), so the
				# tops brighten as the event goes on.
				"apex": minf(x * 2.5, 0.8), "glow": lerpf(0.25, 1.0, cooled), "cooled": cooled,
				"opacity": 0.35 * rain,
			})
			fc += 1
		# --- quiescent prominences, carried round by the differential rotation
		for q in quiescent:
			var v := _region_up(q, t)
			var east := Vector3.UP.cross(v)
			if east.length_squared() < 1e-8: east = Vector3(1, 0, 0)
			east = east.normalized()
			var nl := (east * cos(q.tilt) + v.cross(east).normalized() * sin(q.tilt)).normalized()
			var qh: Node3D = q.holder
			qh.visible = true
			qh.transform = Transform3D(Basis(nl, v, nl.cross(v)), v * R)
			var qa: Prominence.Arcade = q.arcade
			qa.group.visible = true
			qa.set_params({
				"R": R, "span": 0.02, "len": q.len, "height": q.height, "shear": 0.0, "twist": 0.0,
				"erupt": 0.0, "width": 0.0026, "amp": 1.0, "plasmaT": 8000.0, "dt": dt,
				"kind": Prominence.HEDGEROW, "flow": 0.10, "glow": 0.9,
			})

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
		corona_mat.set_shader_parameter("uRScale", pulse)
		mat.set_shader_parameter("uPulse", activity.flux)
		# The corona billboard carries only streamers and the inner aureole; bloom makes the
		# soft halo.
		corona_mat.set_shader_parameter("uFlux", (0.15 + (activity.flux - 1.0) * 0.8) * hotc)
		var teff_now := float(U.nz(body.teff, glare_teff))
		if teff_now != glare_teff: _refresh_glare(teff_now)
		if ctx.visible_band != glare_on: set_band_visible(ctx.visible_band)
		corona_mat.set_shader_parameter("uViewH", ctx.viewport_h)
		if envelope != null:
			# The envelope's photosphere breathes with the drawn one, or the depth test
			# that finds the star behind a ray misses it by the pulse.
			env_mat.set_shader_parameter("uR", R * pulse)
			_update_envelope(ctx.sim_dt)

		if stream != null:
			Bodies.update_accretion_stream(body, ctx, stream, dt)
