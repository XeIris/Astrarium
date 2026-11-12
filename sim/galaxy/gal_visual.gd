class_name GalaxyVisual
extends RefCounted

# How a modelled galaxy is drawn, at every distance, from its model alone: the glow
# (galaxy_glow.gdshader) integrates the light of its disc and spheroid along each
# ray; near the camera the star lattice (galaxy_stars.gdshader) draws the brighter
# stars one by one from the same density; the tracers are an overlay. The owner
# places `group` at the galaxy's centre relative to the camera (floating origin).

const GLOW_SHADER := preload("res://shaders/galaxy/galaxy_glow.gdshader")
const STAR_SHADER := preload("res://shaders/galaxy/galaxy_stars.gdshader")
const TRACER_SHADER := preload("res://shaders/galaxy/galaxy_tracers.gdshader")
const CATALOGUE_SHADER := preload("res://shaders/galaxy/galaxy_catalogue.gdshader")
const HII_SHADER := preload("res://shaders/galaxy/galaxy_hii.gdshader")

## The sky's star calibration (SkyModel.STAR_FLUX is a V = 2.5 star) applied to a star
## of L L☉ at d kpc, taking the Sun's absolute V as 4.83: sky flux = K·L/(4πd²).
const K := SkyModel.STAR_FLUX * 0.11695 * 4.0 * PI * 1e-4    # 10^(−0.4·(4.83 − 2.5)) = 0.11695

## The star lattice: cells of CELL kpc, SPAN per side around the camera, SLOTS each.
const CELL := 0.01
const SPAN := 9
const SLOTS := 128
const RES_MAX := CELL * float(SPAN - 1) * 0.5
const TRACER_COLORS := {"gas": Color(0.25, 0.75, 1.0), "disc": Color(1.0, 0.62, 0.28)}

var group: Node3D
var glow: MeshInstance3D
var glow_mat: ShaderMaterial
var stars: MeshInstance3D
var star_mat: ShaderMaterial
var tracers: MeshInstance3D = null
var tracer_mat: ShaderMaterial
var _tracer_mesh: ArrayMesh = null
var _tracer_xyz := PackedVector3Array()
var pot: GalPotential
var sense := 1.0
var disc_pop: GalPopulation
var sphere_pop: GalPopulation
var young_pop: GalPopulation = null
var patterns: Array = []
## The arms (uArmA, uArmB as gal_model.gdshaderinc reads them), the young stars'
## luminosity-density scale and layer height, the bulge's light axes, and the dust.
var arm_a := PackedVector4Array()
var arm_b := PackedVector4Array()
var young_k := 0.0
var young_h := 0.05
## The arms: width growth per kpc (Reid et al.'s 0.042 in the Milky Way), each arm's light
## falling as exp(−R/h_s) where given, the radii they span, and the star-forming
## envelope (h_r, hole radius) the young light and disc dust share.
var arm_growth := 0.042
var arm_decay := PackedFloat64Array()
var arm_rmin := 2.0
var arm_rmax := 18.0
## How many windings either side each arm's locus is followed through.
var arm_turns := 1
## Where the arms' light starts and over how many kpc it rises; mirrored arms wind the
## other way on the sky; how far past their ends (rad) arms fade out.
var arm_rise := Vector2(0.0, 0.0)
var arm_mirror := false
var arm_fade := SPUR_FADE
var env_hr := 2.26
var env_hole := 4.0
var bulge_axes := Vector2(1.0, 1.0)
var dust := {}
## Dust as a face-on surface density (M☉ kpc⁻², the arm map's g), exp(−|y|/z) above the plane:
## a measured axisymmetric profile with a share gathered into lanes (GalModels.M51_DUST).
var dust_map := {}
## Each lane: [anchor R, β there, tan pitch inside and beyond the break], from its arm.
var lanes: Array = []
## The old disc's and young disc's light as measured profiles in the map (GalModels.M51_LIGHT):
## b the old disc's bolometric surface luminosity, axisymmetric; r the young's, a share of each
## ring gathered into the arms; exp(−|y|/z)/2z above the plane. The old disc's scale on the
## map (≈ 1: the map holds L☉ kpc⁻²).
var disc_map := {}
var thin_map := {}
var disc_k := 0.0
var _l_disc := 0.0
## H II regions (GalHII), drawn as blobs; their catalogue after apply_arms, for checks.
var hii_spec := {}
var hii_d := 0.0
var hii: MeshInstance3D = null
var hii_mat: ShaderMaterial = null
var hii_cat := {}
## Checks hide the H II regions while comparing the glow with its CPU integral, and show them
## alone (hii_with_glow false) to compare theirs; the user's glow toggle hides them too.
var show_hii := true
var hii_with_glow := true
## The smooth young light's colour (visible per bolometric L☉): the young population's, less
## what the H II regions take and with the diffuse gas's lines.
var young_col := Color(1, 1, 1)
var _model_for_uniforms := {}
## Dust rings: each [R, σ, peak V optical depth per kpc], sech² in height with ring_h (kpc);
## and the thinnest dust layer, which sets the glow's sampling about the plane.
var rings: Array = []
var ring_h := 0.01
var thin := 1e9
## The arms' map in their own frame (gal_model.gdshaderinc, uArmMap): r the young
## arms' Σ exp(−d²/2w²), g the arm dust's cutoff · exp(−(d/w)²), on ARM_N² texels over
## ±ARM_HALF kpc (52 pc texels, under half the narrowest arm's width). Baked once per
## model and process.
const ARM_N := 384
const ARM_HALF := 20.0
## A spur (Reid et al.'s Local and Outer segments) fades out over this many radians
## past its measured ends, continuing at its own pitch; a rendering choice, not a measurement.
const SPUR_FADE := 0.15
static var _arm_cache := {}
static var _cache_mutex := Mutex.new()
var _l_young := 0.0
var _model_key := ""
var arm_img: Image = null
var arm_tex: ImageTexture = null
var bar_angle := 0.0
var arm_turn := 0.0
var spiral := {}
var edge := 30.0
var spiral_k := 0.0
## The resolved radius this frame, kpc.
var res := RES_MAX
## The user's exposure, times the eye's adaptation (adapt()).
var exposure := 1.0
var adaptation := 1.0
## Checks pin the exposure (galaxylookcheck) and the resolved radius (≥ 0 overrides).
var adapt_enabled := true
var res_override := -1.0
var show_tracers := true
var show_stars := true
var show_glow := true
## The real stars around the Sun (GalNeighbourhood), for the Milky Way when the asset is
## there; `join_enabled` false leaves the model alone everywhere (the hand-over check).
var join_enabled := true
## Checks hide the drawn real stars while the glow still gives up their light.
var show_catalogue := true
var neighbourhood := {}
var catalogue: MeshInstance3D = null
var catalogue_mat: ShaderMaterial = null
var has_sun := false
var sun_r0 := 8.0
var sun_omega := 0.0
## This frame: the Sun (galaxy-local kpc), its axes, the camera's distance from it (kpc)
## and the far set's weight.
var sun_pos := Vector3.ZERO
var sun_basis := Basis()
var sun_dist := INF
var far_w := 0.0
## The star gain (pixel value per Sun-luminance kpc⁻² per pixel solid angle) and the pixel
## solid angle of the last update, for checks.
var last_gain := 0.0
var last_pix_sr := 1e-6

## `defer_arms`: leave the arms' map to bake_arms() on a worker and apply_arms() after
## (the scene); otherwise it is baked here (checks).
func _init(model: Dictionary, defer_arms := false) -> void:
	pot = model.potential
	sense = float(model.get("sense", 1.0))
	group = Node3D.new()
	group.name = "Galaxy_" + String(model.key)
	patterns = model.get("patterns", [])
	edge = float(model.get("extent", 30.0))
	# A thin disc forms continuously; the bulge formed early (Bland-Hawthorn & Gerhard 2016).
	# With arms, stars under 100 Myr are theirs and the disc's start at that age.
	var arms: Array = model.get("arms", [])
	var young_gyr: float = float(model.get("youngGyr", GalModels.MW_YOUNG_GYR)) if not arms.is_empty() else 0.0
	disc_pop = GalPopulation.build(model.get("discPop", {"kind": "constant", "gyr": 10.0, "fromGyr": young_gyr}))
	sphere_pop = GalPopulation.build(model.get("spherePop", {"kind": "burst", "gyr": 10.0}))
	var axes: Array = model.get("bulgeAxes", [1.0, 1.0])
	bulge_axes = Vector2(axes[0], axes[1])
	dust = (model.get("dust", {}) as Dictionary).duplicate()
	rings = model.get("dustRing", [])
	ring_h = float(model.get("dustRingH", 0.01))
	if not rings.is_empty(): thin = ring_h
	if not dust.is_empty() and float(dust.h0) < 0.05: thin = minf(thin, float(dust.h0))
	dust_map = model.get("dustMap", {})
	sphere_tab = model.get("sphereTable", {})
	if not sphere_tab.is_empty():
		var lnj: PackedFloat32Array = sphere_tab.lnj
		var img := Image.create_from_data(lnj.size(), 1, false, Image.FORMAT_RF, lnj.to_byte_array())
		_sphere_tex = ImageTexture.create_from_image(img)
	disc_map = model.get("discMap", {})
	thin_map = model.get("thinMap", {})
	if not disc_map.is_empty():
		var dd: Dictionary = pot.part("disc")
		_l_disc = float(dd.gm) / GalUnits.G * GalUnits.MASS_UNIT_SUN * _visible(model, "disc") * disc_pop.mean_l / disc_pop.mean_mass
	if not thin_map.is_empty(): thin = minf(thin, float(thin_map.z))
	hii_spec = model.get("hii", {})
	if not hii_spec.is_empty(): hii_d = float(model.sky.d)
	if not dust_map.is_empty(): thin = minf(thin, float(dust_map.z))
	var env: Array = [dust.hr, dust.hole] if not dust.is_empty() else model.get("envelope", [2.26, 4.0])
	env_hr = float(env[0])
	env_hole = float(env[1])
	if not arms.is_empty():
		young_pop = GalPopulation.build({"kind": "constant", "gyr": young_gyr})
		young_col = young_pop.color
		young_h = float(model.get("armH", GalModels.MW_YOUNG_H))
		arm_growth = float(model.get("armWidthGrowth", 0.042))
		arm_decay = PackedFloat64Array(model.get("armDecay", []))
		arm_turns = int(model.get("armTurns", 1))
		var rise: Array = model.get("armRise", [0.0, 0.0])
		arm_rise = Vector2(rise[0], rise[1])
		arm_mirror = bool(model.get("armMirror", false))
		arm_fade = float(model.get("armEndFade", SPUR_FADE))
		var lim: Array = model.get("armR", [2.0, 18.0])
		arm_rmin = float(lim[0])
		arm_rmax = float(lim[1])
		var ext := tan(deg_to_rad(GalModels.MW_SPIRAL_PITCH_DEG))
		for a in arms:
			arm_a.append(Vector4(a[1], deg_to_rad(a[2]), tan(deg_to_rad(a[3])), tan(deg_to_rad(a[4]))))
			# w = 0 marks a spur: it fades out past its measured azimuths (SPUR_FADE).
			arm_b.append(Vector4(a[5], deg_to_rad(a[6]), deg_to_rad(a[7]), ext if a[8] else 0.0))
		# A measured light along the arms wins over the star formation rate's.
		_l_young = float(model.armLight) if model.has("armLight") else float(model.sfr) * young_gyr * 1e9 * young_pop.light_per_formed
		if not dust_map.is_empty(): _build_lanes()
	_model_key = String(model.key)
	_model_for_uniforms = model
	_build_glow(model)
	_build_stars(model)
	if not defer_arms and has_map(): apply_arms(bake_arms())
	has_sun = String(model.key) == "milky_way" and GalNeighbourhood.available()
	if has_sun:
		sun_r0 = float(model.get("r0", 8.0))
		sun_omega = sense * pot.vc(sun_r0) / sun_r0
		if not defer_arms: apply_neighbourhood(GalNeighbourhood.bake())

func _visible(model: Dictionary, part: String) -> float:
	for l in model.light:
		if l.part == part: return float(l.visible)
	return 0.0

func _light_uniforms(model: Dictionary, mat: ShaderMaterial) -> void:
	var g := GalUnits.G
	var d: Dictionary = pot.part("disc")
	var l_m_disc := disc_pop.mean_l / disc_pop.mean_mass
	var l_m_sph := sphere_pop.mean_l / sphere_pop.mean_mass
	if not d.is_empty() and not disc_map.is_empty():
		mat.set_shader_parameter("uDisc", Vector3(0.0, d.a, float(disc_map.z)))
	elif not d.is_empty():
		var m_sun: float = d.gm / g * GalUnits.MASS_UNIT_SUN
		mat.set_shader_parameter("uDisc", Vector3(_visible(model, "disc") * l_m_disc * m_sun * d.b * d.b / (4.0 * PI), d.a, d.b))
	else:
		mat.set_shader_parameter("uDisc", Vector3(0.0, 1.0, 1.0))
	var b: Dictionary = pot.part("bulge")
	if not sphere_tab.is_empty():
		mat.set_shader_parameter("uSphere", Vector4(2.0, 1.0, float(sphere_tab.lnr0), float(sphere_tab.dlnr)))
		mat.set_shader_parameter("uSphereTab", _sphere_tex)
	elif not b.is_empty() and b.kind == GalPotential.Kind.POWER_CUTOFF:
		mat.set_shader_parameter("uSphere", Vector4(0.0, _visible(model, "bulge") * l_m_sph * b.amp / g * GalUnits.MASS_UNIT_SUN, b.alpha, b.rc))
	elif not b.is_empty():
		mat.set_shader_parameter("uSphere", Vector4(1.0, _visible(model, "bulge") * l_m_sph * b.gm / g * GalUnits.MASS_UNIT_SUN, b.a, 0.0))
	else:
		mat.set_shader_parameter("uSphere", Vector4(0.0, 0.0, 1.0, 1.0))
	mat.set_shader_parameter("uBar", Vector4(1.0, 0.0, bulge_axes.x, bulge_axes.y))
	mat.set_shader_parameter("uEdge", edge)
	for p in patterns:
		if p.kind == GalPattern.Kind.SPIRAL:
			# ρ0 back from amp = 4πGHρ0, in M☉ kpc⁻³.
			var rho0: float = p.amp / (4.0 * PI * GalUnits.G * float(p.h)) * GalUnits.MASS_UNIT_SUN
			spiral_k = _visible(model, "disc") * disc_pop.mean_l / disc_pop.mean_mass * rho0
			spiral = p
	if not spiral.is_empty():
		mat.set_shader_parameter("uSpiral", Vector4(spiral_k, spiral.r0, spiral.rs, spiral.h))
	mat.set_shader_parameter("uYoung", Vector4(young_k, young_h, 0.0, 1.0 if arm_tex != null else 0.0))
	if arm_tex != null:
		mat.set_shader_parameter("uArmMap", arm_tex)
		mat.set_shader_parameter("uArmHalf", ARM_HALF)
	mat.set_shader_parameter("uEnvelope", Vector2(env_hr, env_hole))
	if not dust.is_empty():
		var k: float = dust.kappa
		mat.set_shader_parameter("uDust", Vector4(k * dust.rhoDisc, dust.hr, dust.h0, dust.h1))
		mat.set_shader_parameter("uDustArm", Vector4(k * dust.rhoArm, dust.rm, dust.ra, dust.ca))
		mat.set_shader_parameter("uDustB", Vector4(dust.rf, dust.h0a, dust.rfa, dust.h1a))
	else:
		mat.set_shader_parameter("uDust", Vector4(0.0, 1.0, 1.0, 0.0))
		mat.set_shader_parameter("uDustArm", Vector4(0.0, 1.0, 1.0, 0.0))
	mat.set_shader_parameter("uDustMap", Vector2(float(dust_map.kappa), float(dust_map.z)) if not dust_map.is_empty() else Vector2(0.0, 1.0))
	mat.set_shader_parameter("uDiscMap", Vector2(disc_k, float(disc_map.z)) if not disc_map.is_empty() else Vector2(0.0, 1.0))
	var ring_u := PackedVector4Array()
	for i in 4:
		var r: Array = rings[i] if i < rings.size() else [0.0, 1.0, 0.0]
		ring_u.append(Vector4(r[0], r[1], r[2], 0.0))
	mat.set_shader_parameter("uRing", ring_u)
	mat.set_shader_parameter("uRingH", ring_h)
	mat.set_shader_parameter("uThin", thin)

## A measured spheroid's j at r, as gal_sphere_j reads its table.
func _sphere_table(r: float) -> float:
	var lnj: PackedFloat32Array = sphere_tab.lnj
	var n := lnj.size()
	var x := maxf((log(r) - float(sphere_tab.lnr0)) / float(sphere_tab.dlnr), 0.0)
	if x >= float(n - 1): return 0.0
	var i := int(x)
	return exp(lerpf(lnj[i], lnj[i + 1], x - float(i)))

## The spheroid's marched radius (kpc, GalModels.sphere_reach): no spheroid light beyond it,
## here or in the shader.
var sphere_r := 8.0
## A measured spheroid (GalModels.sphereTable): ln j on radii even in ln r, as a 1-row texture.
var sphere_tab := {}
var _sphere_tex: ImageTexture = null
## The core scale the glow samples a measured spheroid about (kpc).
const SPHERE_CORE := 0.5

func _build_glow(model: Dictionary) -> void:
	var ext: float = model.get("extent", 30.0)
	sphere_r = GalModels.sphere_reach(model)
	var h := GalModels.glow_half_height(model)
	var box := BoxMesh.new()
	box.size = Vector3(ext, h, ext) * 2.0
	glow_mat = ShaderMaterial.new()
	glow_mat.shader = GLOW_SHADER
	_light_uniforms(model, glow_mat)
	glow_mat.set_shader_parameter("uBox", Vector3(ext, h, ext))
	glow_mat.set_shader_parameter("uSphereR", sphere_r)
	glow_mat.set_shader_parameter("uSphereCore", SPHERE_CORE)
	glow_mat.set_shader_parameter("uDiscCol", Vector3(disc_pop.color.r, disc_pop.color.g, disc_pop.color.b))
	glow_mat.set_shader_parameter("uSphereCol", Vector3(sphere_pop.color.r, sphere_pop.color.g, sphere_pop.color.b))
	glow_mat.set_shader_parameter("uFaint", Vector2(disc_pop.faint_light, sphere_pop.faint_light))
	if young_pop != null:
		glow_mat.set_shader_parameter("uYoungCol", Vector3(young_col.r, young_col.g, young_col.b))
	var e: Array = GalModels.EXTINCTION_RGB
	glow_mat.set_shader_parameter("uExt", Vector3(e[0], e[1], e[2]))
	glow = MeshInstance3D.new()
	glow.name = "Glow"
	glow.mesh = box
	glow.material_override = glow_mat
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Drawn from inside too: never culled by its own box.
	glow.extra_cull_margin = 16384.0
	group.add_child(glow)

func _build_stars(model: Dictionary) -> void:
	var count := SPAN * SPAN * SPAN * SLOTS
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	var v := PackedVector3Array()
	v.resize(count)
	arr[Mesh.ARRAY_VERTEX] = v
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr)
	star_mat = ShaderMaterial.new()
	star_mat.shader = STAR_SHADER
	_light_uniforms(model, star_mat)
	star_mat.set_shader_parameter("uSpan", SPAN)
	star_mat.set_shader_parameter("uSlots", SLOTS)
	star_mat.set_shader_parameter("uCell", CELL)
	star_mat.set_shader_parameter("uDiscPerJ", disc_pop.resolved_per_l)
	star_mat.set_shader_parameter("uSpherePerJ", sphere_pop.resolved_per_l)
	star_mat.set_shader_parameter("uDiscQ", disc_pop.quantiles)
	star_mat.set_shader_parameter("uSphereQ", sphere_pop.quantiles)
	star_mat.set_shader_parameter("uMS", GalPopulation.main_sequence())
	star_mat.set_shader_parameter("uMSRange", Vector2(GalPopulation.LM_MIN, GalPopulation.LM_MAX))
	star_mat.set_shader_parameter("uProfilePx2", BrightStars.PROFILE_PX2)
	var e: Array = GalModels.EXTINCTION_RGB
	star_mat.set_shader_parameter("uExt", Vector3(e[0], e[1], e[2]))
	star_mat.set_shader_parameter("uSeed", int(model.get("seed", 1)) * 2654435761 & 0x7fffffff)
	stars = MeshInstance3D.new()
	stars.name = "Stars"
	stars.mesh = mesh
	stars.material_override = star_mat
	stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Positions are made in the shader around the camera.
	stars.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	group.add_child(stars)

## Draw these tracers from now on, coloured by population.
func set_tracers(tr: GalTracers) -> void:
	if tracers != null:
		tracers.queue_free()
		tracers = null
	if tr == null or tr.n == 0: return
	_tracer_xyz.resize(tr.n)
	var cols := PackedColorArray()
	cols.resize(tr.n)
	for i in tr.n:
		var kind := String(tr.populations[tr.pop[i]].kind)
		cols[i] = TRACER_COLORS.get(kind, Color(1, 1, 1))
		_tracer_xyz[i] = Vector3(tr.pos[i * 3], tr.pos[i * 3 + 1], tr.pos[i * 3 + 2])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = _tracer_xyz
	arr[Mesh.ARRAY_COLOR] = cols
	_tracer_mesh = ArrayMesh.new()
	_tracer_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr, [], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
	tracer_mat = ShaderMaterial.new()
	tracer_mat.shader = TRACER_SHADER
	tracers = MeshInstance3D.new()
	tracers.name = "Tracers"
	tracers.mesh = _tracer_mesh
	tracers.material_override = tracer_mat
	tracers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tracers.custom_aabb = AABB(Vector3(-100, -100, -100), Vector3(200, 200, 200))
	group.add_child(tracers)

## Per frame. `cam_local`: the camera in galaxy-local kpc (double); `t_myr`: the
## scene's time; `tr`: the tracers, drawn `ahead` Myr past their last step.
## `view_r`: the camera's distance from what it looks at; the tracer overlay fades
## out below half a kpc, where it would be dots in the sky rather than a map.
func update(cam_local: DVec3, t_myr: float, tr: GalTracers, ahead: float, fov_rad: float, viewport_h: float, star_gain: float, view_r := 60.0) -> void:
	var pix := 2.0 * tan(fov_rad * 0.5) / maxf(viewport_h, 1.0)
	var pix_sr := pix * pix
	var gain := K * star_gain * exposure * adaptation
	last_gain = gain
	last_pix_sr = pix_sr
	var cl := Vector3(cam_local.x, cam_local.y, cam_local.z)
	_turn_patterns(t_myr)
	glow.visible = show_glow
	stars.visible = show_stars
	# The resolved sphere shrinks with the camera's height off the plane, where there
	# are no stars to resolve, so the glow alone draws the galaxy from outside: above it, or
	# in its plane but past its edge (a neighbour seen from inside another galaxy).
	var in_disc := absf(cam_local.y) < 2.0 and Vector2(cam_local.x, cam_local.z).length() < edge
	res = RES_MAX if in_disc else 0.0
	if not show_stars: res = 0.0
	if res_override >= 0.0: res = res_override
	glow_mat.set_shader_parameter("uCamLocal", cl)
	glow_mat.set_shader_parameter("uGain", gain / (4.0 * PI))
	if hii != null:
		hii.visible = show_hii and (show_glow or not hii_with_glow)
		hii_mat.set_shader_parameter("uCamLocal", cl)
		hii_mat.set_shader_parameter("uGain", gain / (4.0 * PI))
		hii_mat.set_shader_parameter("uPix", pix)
	glow_mat.set_shader_parameter("uRes", res)
	if show_stars and res > 0.0: _place_lattice(cam_local, t_myr, gain, pix_sr)
	stars.visible = show_stars and res > 0.0
	if has_sun: _place_neighbourhood(cam_local, t_myr, gain, pix_sr)
	if tracers != null:
		var fade := clampf((view_r - 0.5) / 1.5, 0.0, 1.0)
		tracers.visible = show_tracers and fade > 0.0
		tracer_mat.set_shader_parameter("uOpacity", fade)
		if tracers.visible and tr != null:
			for i in tr.n:
				var c := i * 3
				_tracer_xyz[i] = Vector3(tr.pos[c] + tr.vel[c] * ahead, tr.pos[c + 1] + tr.vel[c + 1] * ahead, tr.pos[c + 2] + tr.vel[c + 2] * ahead)
			RenderingServer.mesh_surface_update_vertex_region(_tracer_mesh.get_rid(), 0, 0, _tracer_xyz.to_byte_array())

## The glow's luminance (Sun-luminance kpc⁻² sr⁻¹) along a ray from `o` in local
## direction `d`, integrated as the shader does but in double: what the eye adapts to.
## The spheroid's cusp is cut at `r_floor`, so a patch, not one pixel, sets the level.
func ray_luminance(o: Vector3, d: Vector3, r_floor := 1e-3, n := 160) -> float:
	var cols := [disc_pop.color, sphere_pop.color, young_col if young_pop != null else Color(0, 0, 0)]
	var e: Array = GalModels.EXTINCTION_RGB
	var dv: Vector3 = glow_mat.get_shader_parameter("uDisc")
	var box: Vector3 = glow_mat.get_shader_parameter("uBox")
	var reach: float = glow_mat.get_shader_parameter("uSphereR")
	var sv: Vector4 = glow_mat.get_shader_parameter("uSphere")
	# As the shader marches them: the disc and its dust within the box, the spheroid
	# within its sphere; one march spans both.
	var t1 := INF
	var t0 := 0.0
	for a in 3:
		if absf(d[a]) < 1e-12:
			if absf(o[a]) > box[a]: t1 = -INF
			continue
		var ta := (-box[a] - o[a]) / d[a]
		var tb := (box[a] - o[a]) / d[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t1 <= t0:
		t0 = INF
		t1 = -INF
	if sv.y > 0.0:
		var hb := o.dot(d)
		var hh := hb * hb - (o.dot(o) - reach * reach)
		if hh > 0.0 and -hb + sqrt(hh) > 0.0:
			t0 = minf(t0, maxf(-hb - sqrt(hh), 0.0))
			t1 = maxf(t1, -hb + sqrt(hh))
	if t1 <= t0: return 0.0
	var acc := [0.0, 0.0, 0.0]
	var tau := 0.0
	# Uniform in asinh about the plane crossing, as the shader samples the disc.
	var sc := maxf(minf(dv.z, thin), 0.005) / maxf(absf(d.y), 1e-4)
	var tc := clampf(-o.y / d.y if absf(d.y) > 1e-9 else t0, t0, t1)
	var u0 := asinh((t0 - tc) / sc)
	var u1 := asinh((t1 - tc) / sc)
	var du := (u1 - u0) / float(n)
	for i in n:
		var u := u0 + (float(i) + 0.5) * du
		var t := tc + sc * sinh(u)
		var p := o + d * t
		var ds := sc * cosh(u) * du
		var j := light_density(p, r_floor)
		var in_box := absf(p.x) <= box.x and absf(p.y) <= box.y and absf(p.z) <= box.z
		if not in_box:
			j[0] = 0.0
			j[2] = 0.0
		var k := dust_density(p.x, p.y, p.z) * ds if in_box else 0.0
		for ch in 3:
			var kc := k * float(e[ch])
			var within := (1.0 - exp(-kc)) / kc if kc > 1e-4 else 1.0 - 0.5 * kc
			var att := exp(-tau * float(e[ch])) * within
			acc[ch] += (j[0] * cols[0][ch] + j[1] * cols[1][ch] + j[2] * cols[2][ch]) * ds * att
		tau += k
	return (0.2126 * acc[0] + 0.7152 * acc[1] + 0.0722 * acc[2]) / (4.0 * PI)

## Bolometric luminosity density (L☉ kpc⁻³) of the disc, the spheroid (in the bar's
## frame) and the young arms at a local point, as gal_model.gdshaderinc computes it.
func light_density(p: Vector3, r_floor := 1e-3) -> PackedFloat64Array:
	var dv: Vector3 = glow_mat.get_shader_parameter("uDisc")
	var sv: Vector4 = glow_mat.get_shader_parameter("uSphere")
	var x: float = p.x
	var y: float = p.y
	var z: float = p.z
	var R2 := x * x + z * z
	var zb := sqrt(y * y + dv.z * dv.z)
	var s := dv.y + zb
	var q := R2 + s * s
	var jd := dv.x * (dv.y * R2 + (dv.y + 3.0 * zb) * s * s) / (q * q * sqrt(q) * zb * zb * zb)
	if disc_k > 0.0:
		var zs: float = disc_map.z
		jd = disc_k * _arm_sample(x, z)[2] * exp(-absf(y) / zs) / (2.0 * zs)
	if spiral_k > 0.0 and arm_img != null:
		jd += spiral_k * _arm_sample(x, z)[2] * GalaxyVisual._sech2(y / float(spiral.h))
	jd = maxf(jd, 0.0) * smoothstep(edge, 0.8 * edge, sqrt(R2))
	var cb := cos(bar_angle)
	var sb := sin(bar_angle)
	var u := x * cb + z * sb
	var v := -x * sb + z * cb
	var r := maxf(sqrt(u * u + (y / bulge_axes.y) * (y / bulge_axes.y) + (v / bulge_axes.x) * (v / bulge_axes.x)), r_floor)
	var k := 1.0 / (bulge_axes.x * bulge_axes.y)
	var js := 0.0
	if sv.y > 0.0 and p.length() <= sphere_r:
		if sv.x > 1.5: js = k * sv.y * _sphere_table(r)
		else: js = k * (sv.y * pow(r, -sv.z) * exp(-r * r / (sv.w * sv.w)) if sv.x < 0.5 else sv.y * sv.z / (TAU * r * pow(r + sv.z, 3.0)))
	var jy := 0.0
	if young_k > 0.0:
		var R := sqrt(R2)
		jy = young_k * _envelope(R) * _arm_sample(x, z)[0] * exp(-absf(y) / young_h) / (2.0 * young_h)
	return PackedFloat64Array([jd, js, jy])

## The spheroid's share of the resolved stars at a local point.
static func sphere_share(v: GalaxyVisual, p: Vector3) -> float:
	var j := v.light_density(p)
	var nd := j[0] * v.disc_pop.resolved_per_l
	var ns := j[1] * v.sphere_pop.resolved_per_l
	return ns / maxf(nd + ns, 1e-300)

## Adapt like an eye. Within the disc, to the brightest of the given local rays (a
## patch about 5° across at the centre's distance), held near KEY. From outside, to the
## mean of the disc at DISC_R in eight directions, held near DISC_KEY, as a photograph
## of a galaxy is exposed for its disc and lets the bulge burn out. Among the stars the
## gain never rises past the night-sky calibration (1×); from outside, where no star is
## resolved, it may open to OUTSIDE_MAX. The user's exposure applies on top.
const KEY := 1.5
const DISC_KEY := 0.8
const DISC_R := 6.0
const OUTSIDE_MAX := 100.0
## The eye needs a level, not a measurement: fewer samples, and a fresh one every
## ADAPT_EVERY seconds (the ease spans the rest).
const ADAPT_SAMPLES := 48
const ADAPT_EVERY := 0.2
var _adapt_wait := 0.0
var _adapt_want := 1.0
func adapt(rays: Array, cam_local: Vector3, star_gain: float, dt: float) -> void:
	if not adapt_enabled: return
	if dt > 0.0:
		adaptation = exp(lerpf(log(adaptation), log(_adapt_want), 1.0 - exp(-dt * 3.0)))
		_adapt_wait -= dt
		if _adapt_wait > 0.0: return
	_adapt_wait = ADAPT_EVERY
	var level := 0.0
	var key := KEY
	var outside := absf(cam_local.y) > 2.0 or Vector2(cam_local.x, cam_local.z).length() > edge
	if outside:
		for k in 8:
			var a := TAU * float(k) / 8.0
			var target := Vector3(DISC_R * cos(a), 0.0, DISC_R * sin(a))
			level += ray_luminance(cam_local, (target - cam_local).normalized(), 1e-3, ADAPT_SAMPLES) / 8.0
		key = DISC_KEY
	else:
		var r_floor := maxf(cam_local.length() * 0.08, 1e-3)
		for d in rays: level = maxf(level, ray_luminance(cam_local, d, r_floor, ADAPT_SAMPLES))
	# Pixel luminance of a ray is its luminance × K × gain (the shader's uGain is K/4π
	# per ∫j ds, and ray_luminance already divides by 4π).
	var cap := OUTSIDE_MAX if outside else 1.0
	_adapt_want = 1.0 if level <= 0.0 else minf(cap, key / (level * K * maxf(star_gain, 1e-9)))
	if dt <= 0.0: adaptation = _adapt_want

## The bar's light and the arms turn with their patterns.
func _turn_patterns(t_myr: float) -> void:
	for p in patterns:
		if p.kind == GalPattern.Kind.BAR: bar_angle = fposmod(GalPattern.angle(p, t_myr), TAU)
		else:
			arm_turn = fposmod(float(p.omega) * t_myr, TAU)
	var bar := Vector4(cos(bar_angle), sin(bar_angle), bulge_axes.x, bulge_axes.y)
	for mat in [glow_mat, star_mat]:
		mat.set_shader_parameter("uBar", bar)
		mat.set_shader_parameter("uYoung", Vector4(young_k, young_h, arm_turn, 1.0 if arm_tex != null else 0.0))

# ---- the CPU's copy of gal_model.gdshaderinc, in double

func _arm_radius(i: int, beta: float) -> PackedFloat64Array:
	var A := arm_a[i]
	var B := arm_b[i]
	var b := clampf(beta, B.y, B.z)
	var t := A.z if b <= A.y else A.w
	var R := A.x * exp(-(b - A.y) * t)
	var weight := 1.0
	if beta != b:
		if B.w > 0.0:
			t = B.w
		else:
			weight = exp(-0.5 * pow((beta - b) / arm_fade, 2.0))
		R *= exp(-(beta - b) * t)
	return PackedFloat64Array([R, t, weight])

## Σ over arms of exp(−d²/2w²) at (R, φ) with the arms turned by `turn`, w Reid's.
func _arms(R: float, phi: float, turn: float) -> float:
	var beta := phi - PI - turn
	if arm_mirror: beta = -beta
	beta = beta - TAU * floor((beta + PI) / TAU)
	var acc := 0.0
	for i in arm_a.size():
		var w := maxf(arm_b[i].x + arm_growth * (R - arm_a[i].x), 0.05)
		var best := 0.0
		for k in range(-arm_turns, arm_turns + 1):
			var at := _arm_radius(i, beta + TAU * float(k))
			if at[0] < arm_rmin or at[0] > arm_rmax: continue
			var d := absf(R - at[0]) * cos(atan(at[1]))
			best = maxf(best, at[2] * exp(-0.5 * d * d / (w * w)))
		# An arm's own light rising from its start and then falling outward (Marchuk et
		# al. 2024's h_s), where measured.
		if i < arm_decay.size(): best *= exp(-R / arm_decay[i]) * smoothstep(arm_rise.x, arm_rise.x + arm_rise.y, R)
		acc += best
	return acc

func _envelope(R: float) -> float:
	var hr := env_hr
	var rh := env_hole
	if R >= rh: return exp(-R / hr)
	var x := R / (2.0 * rh) - 0.5
	return exp(-rh / hr) * exp(-x * x / 0.0625)

## ∫∫ envelope · arms over the plane, for the young light's scale: the map's texels,
## as the shader reads them.
func _arm_integral(img: Image) -> float:
	var s := 0.0
	var px := 2.0 * ARM_HALF / float(ARM_N)
	for j in ARM_N:
		for i in ARM_N:
			var x := -ARM_HALF + (float(i) + 0.5) * px
			var z := -ARM_HALF + (float(j) + 0.5) * px
			s += _envelope(sqrt(x * x + z * z)) * img.get_pixel(i, j).r
	return s * px * px

## Whether the visual draws from a baked map (bake_arms), arms or a disc's.
func has_map() -> bool:
	return young_pop != null or not disc_map.is_empty()

## The arms' map and its integral: pure data, safe on a worker thread, cached per model.
func bake_arms() -> Dictionary:
	_cache_mutex.lock()
	var hit: Dictionary = _arm_cache.get(_model_key, {})
	_cache_mutex.unlock()
	if not hit.is_empty(): return hit
	var img := Image.create_empty(ARM_N, ARM_N, false, Image.FORMAT_RGBF)
	var px := 2.0 * ARM_HALF / float(ARM_N)
	for j in ARM_N:
		for i in ARM_N:
			var x := -ARM_HALF + (float(i) + 0.5) * px
			var z := -ARM_HALF + (float(j) + 0.5) * px
			var R := sqrt(x * x + z * z)
			var phi := atan2(z, x)
			var g := _dust_surface(R, phi) if not dust_map.is_empty() else _dust_arm(R, phi)
			var b := _disc_surface(R) if not disc_map.is_empty() else _spiral_plane(R, phi)
			img.set_pixel(i, j, Color(_arms(R, phi, 0.0), g, b))
	if not thin_map.is_empty(): _gather_light(img)
	var share := _add_bar(img) if disc_map.has("bar") else 0.0
	var out := {"img": img, "integral": _arm_integral(img), "disc": _map_integral(img, 2), "bar": share}
	if not hii_spec.is_empty(): out.hii = GalHII.build(hii_spec, hii_d, img, ARM_HALF, _l_young, young_h, 51)
	_cache_mutex.lock()
	_arm_cache[_model_key] = out
	_cache_mutex.unlock()
	return out

## On the main thread: the real stars as points and their far light as the glow's map.
func apply_neighbourhood(baked: Dictionary) -> void:
	if baked.is_empty() or not has_sun or catalogue != null: return
	neighbourhood = baked
	var n: int = int(baked.n_near) + int(baked.n_far)
	# Colour per unit luminance exceeds 1 in a channel for blue and red stars, and vertex
	# COLOR is 8-bit unorm: it goes in floats, (r, g, b, luminosity), and the set apart.
	var custom := PackedFloat32Array()
	var sets := PackedFloat32Array()
	custom.resize(4 * n)
	sets.resize(4 * n)
	for i in n:
		var c := GalNeighbourhood.colour(baked.bv[i])
		custom[4 * i] = c.r
		custom[4 * i + 1] = c.g
		custom[4 * i + 2] = c.b
		custom[4 * i + 3] = GalNeighbourhood.l_vis(baked.mv[i])
		sets[4 * i] = 0.0 if i < int(baked.n_near) else 1.0
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = baked.pos
	arr[Mesh.ARRAY_CUSTOM0] = custom
	arr[Mesh.ARRAY_CUSTOM1] = sets
	var mesh := ArrayMesh.new()
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr, [], {}, fmt)
	catalogue_mat = ShaderMaterial.new()
	catalogue_mat.shader = CATALOGUE_SHADER
	catalogue_mat.set_shader_parameter("uProfilePx2", BrightStars.PROFILE_PX2)
	catalogue = MeshInstance3D.new()
	catalogue.name = "Neighbourhood"
	catalogue.mesh = mesh
	catalogue.material_override = catalogue_mat
	catalogue.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	catalogue.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	group.add_child(catalogue)
	glow_mat.set_shader_parameter("uCatMap", ImageTexture.create_from_image(baked.map))

## The Sun and the real stars this frame: where they are, the lattice's hole, and how much
## of the far set (and its light in the glow) is shown.
func _place_neighbourhood(cam_local: DVec3, t_myr: float, gain: float, pix_sr: float) -> void:
	var f := GalNeighbourhood.sun_frame(sun_r0, sun_omega, t_myr)
	sun_pos = f[0]
	sun_basis = f[1]
	var sun := DVec3.new(sun_pos.x, sun_pos.y, sun_pos.z)
	var rel := sun.rel_v3(cam_local)
	sun_dist = rel.length()
	var on := join_enabled and catalogue != null
	far_w = 1.0 - smoothstep(GalNeighbourhood.FAR_FADE.x, GalNeighbourhood.FAR_FADE.y, sun_dist) if on else 0.0
	var near := on and res > 0.0 and sun_dist < res + GalNeighbourhood.NEAR_KPC
	if catalogue != null:
		catalogue.visible = on and show_stars and show_catalogue and (near or far_w > 0.0)
		catalogue_mat.set_shader_parameter("uSunRel", rel)
		catalogue_mat.set_shader_parameter("uSunBasis", sun_basis)
		catalogue_mat.set_shader_parameter("uRes", res)
		catalogue_mat.set_shader_parameter("uNearW", 1.0 if near else 0.0)
		catalogue_mat.set_shader_parameter("uFarW", far_w)
		catalogue_mat.set_shader_parameter("uGain", gain)
		catalogue_mat.set_shader_parameter("uPixSr", pix_sr)
	star_mat.set_shader_parameter("uHole", Vector4(rel.x, rel.y, rel.z, GalNeighbourhood.NEAR_KPC if near else 0.0))
	glow_mat.set_shader_parameter("uSunBasis", sun_basis)
	glow_mat.set_shader_parameter("uCatGain", gain * far_w if show_stars else 0.0)

## The H II regions on the main thread: the smooth young light gives up their stars' light and
## gains the diffuse gas's lines, and each region becomes a quad of four corners.
func _apply_hii(cat: Dictionary) -> void:
	hii_cat = cat
	var cont: float = cat.cont_bol
	var dig: float = cat.dig_bol
	var vis: Color = young_pop.color * _l_young - (cat.cont_col as Color) * cont + (cat.dig_vis as Color)
	_l_young += dig - cont
	young_col = vis / _l_young
	glow_mat.set_shader_parameter("uYoungCol", Vector3(young_col.r, young_col.g, young_col.b))
	var n: int = cat.n
	var verts := PackedVector3Array()
	var c0 := PackedFloat32Array()
	var c1 := PackedFloat32Array()
	var c2 := PackedFloat32Array()
	var idx := PackedInt32Array()
	verts.resize(4 * n)
	c0.resize(16 * n)
	c1.resize(16 * n)
	c2.resize(16 * n)
	idx.resize(6 * n)
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for i in n:
		var st: Color = cat.stars[i]
		var ln: Color = cat.lines[i]
		for k in 4:
			var v := 4 * i + k
			verts[v] = cat.pos[i]
			c0[4 * v] = st.r
			c0[4 * v + 1] = st.g
			c0[4 * v + 2] = st.b
			c1[4 * v] = (corners[k] as Vector2).x
			c1[4 * v + 1] = (corners[k] as Vector2).y
			c1[4 * v + 2] = cat.sigma[i]
			c2[4 * v] = ln.r
			c2[4 * v + 1] = ln.g
			c2[4 * v + 2] = ln.b
		for k in 6: idx[6 * i + k] = 4 * i + [0, 1, 2, 0, 2, 3][k]
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_CUSTOM0] = c0
	arr[Mesh.ARRAY_CUSTOM1] = c1
	arr[Mesh.ARRAY_CUSTOM2] = c2
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	var fmt := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, fmt)
	hii_mat = ShaderMaterial.new()
	hii_mat.shader = HII_SHADER
	_light_uniforms(_model_for_uniforms, hii_mat)
	var e: Array = GalModels.EXTINCTION_RGB
	hii_mat.set_shader_parameter("uExt", Vector3(e[0], e[1], e[2]))
	hii = MeshInstance3D.new()
	hii.name = "HII"
	hii.mesh = mesh
	hii.material_override = hii_mat
	hii.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hii.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	group.add_child(hii)

## On the main thread: the map's texture, and the young arms' scale from its integral.
func apply_arms(baked: Dictionary) -> void:
	if baked.is_empty(): return
	arm_img = baked.img
	bar_share = float(baked.get("bar", 0.0))
	arm_tex = ImageTexture.create_from_image(arm_img)
	if baked.has("hii") and hii == null: _apply_hii(baked.hii)
	young_k = _l_young / float(baked.integral) if float(baked.integral) > 0.0 else 0.0
	if not disc_map.is_empty():
		disc_k = _l_disc / float(baked.disc)
		for mat in [glow_mat, star_mat]:
			mat.set_shader_parameter("uDiscMap", Vector2(disc_k, float(disc_map.z)))
	for mat in [glow_mat, star_mat, hii_mat]:
		if mat == null: continue
		mat.set_shader_parameter("uArmMap", arm_tex)
		mat.set_shader_parameter("uArmHalf", ARM_HALF)
		mat.set_shader_parameter("uYoung", Vector4(young_k, young_h, arm_turn, 1.0))

## The map at a point, as the GPU samples it: turned into the arms' frame, bilinear
## between texel centres, zero outside.
func _arm_sample(x: float, z: float) -> PackedFloat64Array:
	if arm_img == null: return PackedFloat64Array([0.0, 0.0, 0.0])
	var c := cos(arm_turn)
	var sn := sin(arm_turn)
	var qx := (x * c + z * sn) / (2.0 * ARM_HALF) + 0.5
	var qz := (z * c - x * sn) / (2.0 * ARM_HALF) + 0.5
	if qx <= 0.0 or qz <= 0.0 or qx >= 1.0 or qz >= 1.0: return PackedFloat64Array([0.0, 0.0, 0.0])
	var fx := qx * float(ARM_N) - 0.5
	var fz := qz * float(ARM_N) - 0.5
	var i0 := clampi(int(floor(fx)), 0, ARM_N - 1)
	var j0 := clampi(int(floor(fz)), 0, ARM_N - 1)
	var i1 := mini(i0 + 1, ARM_N - 1)
	var j1 := mini(j0 + 1, ARM_N - 1)
	var wx := clampf(fx - float(i0), 0.0, 1.0)
	var wz := clampf(fz - float(j0), 0.0, 1.0)
	var a := arm_img.get_pixel(i0, j0).lerp(arm_img.get_pixel(i1, j0), wx)
	var b := arm_img.get_pixel(i0, j1).lerp(arm_img.get_pixel(i1, j1), wx)
	var v := a.lerp(b, wz)
	return PackedFloat64Array([v.r, v.g, v.b])

## The stellar spiral's in-plane factor e^{−(R−r0)/Rs} cos γ at (R, φ) in the arms'
## frame: its angle at t = 0, as the map turns with it by Ωp t from there. The factor is
## still ~0.2 at 20 kpc, so it fades out over the map's last fifth in radius; otherwise
## the map's square border shows face-on. The potential is not windowed.
func _spiral_plane(R: float, phi: float) -> float:
	if spiral.is_empty() or R < 1e-3: return 0.0
	var gam: float = float(spiral.n) * (phi - float(spiral.angle0) + log(R / float(spiral.r0)) / tan(float(spiral.pitch)))
	var window := smoothstep(ARM_HALF, 0.8 * ARM_HALF, R)
	return exp(-(R - float(spiral.r0)) / float(spiral.rs)) * cos(gam) * window

## Drimmel & Spergel's arm-dust factor at (R, φ) in the arms' frame: the cutoff outside
## r_m times exp(−(d/w)²) to the nearest arm, w = ca·R.
func _dust_arm(R: float, phi: float) -> float:
	if dust.is_empty(): return 0.0
	var cut: float = exp(-pow((R - dust.rm) / dust.ra, 2.0)) if R > dust.rm else 1.0
	var w: float = dust.ca * maxf(R, 1.0)
	var beta := phi - PI
	beta = beta - TAU * floor((beta + PI) / TAU)
	var best := 0.0
	for i in arm_a.size():
		for k in range(-arm_turns, arm_turns + 1):
			var at := _arm_radius(i, beta + TAU * float(k))
			if at[0] < arm_rmin or at[0] > arm_rmax: continue
			var d := absf(R - at[0]) * cos(atan(at[1]))
			best = maxf(best, at[2] * exp(-d * d / (w * w)))
	return cut * best

## The old disc's bolometric surface luminosity at R (L☉ kpc⁻²): Inman et al.'s discs, or an
## exponential of scale `exp` (its scale on the map comes from disc_k).
func _disc_surface(R: float) -> float:
	if disc_map.has("exp"): return exp(-R / float(disc_map.exp)) * float(disc_map.bol)
	return GalModels.inman_surface(disc_map.discs, float(disc_map.outerH), R) * float(disc_map.bol)

## The bar's share of the disc's light, from the applied map (_add_bar).
var bar_share := 0.0
## Rathore et al.'s (2024) annuli for A2, kpc.
const BAR_ANNULUS := 0.1

## A Ferrers (1 − m²)² bar of semi-major axis a, axis ratio q, at angle ψ from the line of
## nodes, gathered from the disc's light in b: its share f is solved so the map's peak
## bi-symmetric amplitude A2 = |Σ Σ e^{2iφ}| / Σ Σ over BAR_ANNULUS annuli is the measured one.
## The disc alone has no m = 2 term, so each annulus's A2 is f|c_bar| / ((1 − f)A0_disc + f A0_bar).
func _add_bar(img: Image) -> float:
	var bar: Array = disc_map.bar
	var a: float = bar[0]
	var q: float = bar[1]
	var c := cos(float(bar[2]))
	var sn := sin(float(bar[2]))
	var n := img.get_width()
	var px := 2.0 * ARM_HALF / float(n)
	var shape := PackedFloat64Array()
	shape.resize(n * n)
	var tot_d := 0.0
	var tot_b := 0.0
	for j in n:
		for i in n:
			var x := -ARM_HALF + (float(i) + 0.5) * px
			var z := -ARM_HALF + (float(j) + 0.5) * px
			var u := x * c + z * sn
			var v := -x * sn + z * c
			var m2 := (u / a) * (u / a) + (v / (q * a)) * (v / (q * a))
			shape[j * n + i] = pow(1.0 - m2, 2.0) if m2 < 1.0 else 0.0
			tot_b += shape[j * n + i]
			tot_d += img.get_pixel(i, j).b
	# Per annulus: the disc's and bar's A0, the bar's |c₂|, each per unit of its whole.
	var nb := int(ceil(2.0 * a / BAR_ANNULUS)) + 1
	var a0d := PackedFloat64Array()
	var a0b := PackedFloat64Array()
	var cr := PackedFloat64Array()
	var ci := PackedFloat64Array()
	for arr in [a0d, a0b, cr, ci]: arr.resize(nb)
	for j in n:
		for i in n:
			var x := -ARM_HALF + (float(i) + 0.5) * px
			var z := -ARM_HALF + (float(j) + 0.5) * px
			var k := int(sqrt(x * x + z * z) / BAR_ANNULUS)
			if k >= nb: continue
			var phi := atan2(z, x)
			var sb := shape[j * n + i] / tot_b
			a0d[k] += img.get_pixel(i, j).b / tot_d
			a0b[k] += sb
			cr[k] += sb * cos(2.0 * phi)
			ci[k] += sb * sin(2.0 * phi)
	var want: float = bar[3]
	var lo := 0.0
	var hi := 1.0
	for it in 60:
		var f := 0.5 * (lo + hi)
		if _peak_a2(f, a0d, a0b, cr, ci) < want: lo = f
		else: hi = f
	var f := 0.5 * (lo + hi)
	for j in n:
		for i in n:
			var col := img.get_pixel(i, j)
			col.b = (1.0 - f) * col.b + f * tot_d * shape[j * n + i] / tot_b
			img.set_pixel(i, j, col)
	return f

static func _peak_a2(f: float, a0d: PackedFloat64Array, a0b: PackedFloat64Array, cr: PackedFloat64Array, ci: PackedFloat64Array) -> float:
	var peak := 0.0
	for k in a0d.size():
		var a0 := (1.0 - f) * a0d[k] + f * a0b[k]
		if a0 > 0.0: peak = maxf(peak, f * sqrt(cr[k] * cr[k] + ci[k] * ci[k]) / a0)
	return peak

## ∫∫ of a map channel over the plane, as the shader reads it.
func _map_integral(img: Image, ch: int) -> float:
	var s := 0.0
	var px := 2.0 * ARM_HALF / float(ARM_N)
	for j in ARM_N:
		for i in ARM_N:
			s += img.get_pixel(i, j)[ch]
	return s * px * px

## The discs' light into the map, from the arms' profile in r: each ring keeps its measured
## mean (the young disc's in r, the old disc's in b). Of the young light, thin_map.share is
## gathered as the arms' profile has it where the arms are; the old disc is gathered to the
## peak-to-valley contrast disc_map.contrast. Rings are the map's texels binned by radius, so
## the means hold to the texel.
func _gather_light(img: Image) -> void:
	var px := 2.0 * ARM_HALF / float(ARM_N)
	var nb := int(ceil(ARM_HALF * sqrt(2.0) / px)) + 1
	var sum := PackedFloat64Array()
	var cnt := PackedFloat64Array()
	var top := PackedFloat64Array()
	sum.resize(nb)
	cnt.resize(nb)
	top.resize(nb)
	for j in ARM_N:
		for i in ARM_N:
			var x := -ARM_HALF + (float(i) + 0.5) * px
			var z := -ARM_HALF + (float(j) + 0.5) * px
			var k := int(sqrt(x * x + z * z) / px)
			var a := img.get_pixel(i, j).r
			sum[k] += a
			cnt[k] += 1.0
			top[k] = maxf(top[k], a)
	var share := float(thin_map.get("share", 1.0))
	if thin_map.has("a2"): share = _share_for_a2(img, sum, cnt, px)
	young_share = share
	for j in ARM_N:
		for i in ARM_N:
			var x := -ARM_HALF + (float(i) + 0.5) * px
			var z := -ARM_HALF + (float(j) + 0.5) * px
			var R := sqrt(x * x + z * z)
			var k := int(R / px)
			var mean := sum[k] / maxf(cnt[k], 1.0)
			var c := img.get_pixel(i, j)
			var rel := c.r / mean if mean > 1e-12 else 0.0
			var pres := _arm_presence(R)
			var t := _thin_surface(R)
			var fy := share * pres if mean > 1e-12 else 0.0
			c.r = t * ((1.0 - fy) + fy * rel)
			if disc_map.has("contrast"):
				# Peak to valley C = 1 + f·(max/mean)/(1 − f) for a ring whose arms vanish between.
				var cc := _contrast(R) - 1.0
				var peak := top[k] / mean if mean > 1e-12 else 0.0
				var fo := cc / (cc + peak) * pres if peak > 0.0 else 0.0
				c.b *= (1.0 - fo) + fo * rel
			img.set_pixel(i, j, c)

## The old disc's arm/interarm contrast at R, linear between the measured radii, held beyond.
func _contrast(R: float) -> float:
	var t: Array = disc_map.contrast
	if R <= float(t[0][0]): return float(t[0][1])
	for k in range(1, t.size()):
		if R <= float(t[k][0]):
			return lerpf(float(t[k - 1][1]), float(t[k][1]), (R - float(t[k - 1][0])) / (float(t[k][0]) - float(t[k - 1][0])))
	return float(t[t.size() - 1][1])

## The young disc's share gathered into its arms (after the bake).
var young_share := 0.0

## The young disc's bolometric surface luminosity at R: Inman et al.'s discs or an exponential.
func _thin_surface(R: float) -> float:
	if thin_map.has("exp"): return exp(-R / float(thin_map.exp)) * float(thin_map.bol)
	return GalModels.inman_surface(thin_map.discs, float(thin_map.outerH), R) * float(thin_map.bol)

## The share that gives the young light a mean normalised m = 2 amplitude thin_map.a2 over the
## rings in thin_map.a2R: each ring's A2 is the share times its arm presence times the arms'
## own |Σ (A/⟨A⟩) e^{2iφ}| / N, the even part adding nothing.
func _share_for_a2(img: Image, sum: PackedFloat64Array, cnt: PackedFloat64Array, px: float) -> float:
	var nb := sum.size()
	var cr := PackedFloat64Array()
	var ci := PackedFloat64Array()
	cr.resize(nb)
	ci.resize(nb)
	for j in ARM_N:
		for i in ARM_N:
			var x := -ARM_HALF + (float(i) + 0.5) * px
			var z := -ARM_HALF + (float(j) + 0.5) * px
			var k := int(sqrt(x * x + z * z) / px)
			var mean := sum[k] / maxf(cnt[k], 1.0)
			if mean <= 1e-12: continue
			var rel := img.get_pixel(i, j).r / mean
			var phi := atan2(z, x)
			cr[k] += rel * cos(2.0 * phi)
			ci[k] += rel * sin(2.0 * phi)
	var lim: Array = thin_map.a2R
	var acc := 0.0
	var m := 0
	for k in nb:
		var R := (float(k) + 0.5) * px
		if R < float(lim[0]) or R > float(lim[1]) or cnt[k] <= 0.0: continue
		acc += _arm_presence(R) * sqrt(cr[k] * cr[k] + ci[k] * ci[k]) / cnt[k]
		m += 1
	return clampf(float(thin_map.a2) / (acc / float(maxi(m, 1))), 0.0, 1.0)

## How fully the arms are there at R: the strongest arm's weight past its measured span, times
## their rise.
func _arm_presence(R: float) -> float:
	var w := 0.0
	for i in arm_a.size(): w = maxf(w, _arm_beta(i, R)[1])
	return w * smoothstep(arm_rise.x, arm_rise.x + arm_rise.y, R)

## An arm's azimuth β at radius R, inverting its log spiral (Reid et al.'s form with a kink),
## and its weight there: 1 within the measured azimuths, fading past them as _arm_radius
## does. Arms that fade rather than extend (w = 0 in the table) only.
func _arm_beta(i: int, R: float) -> PackedFloat64Array:
	var A := arm_a[i]
	var B := arm_b[i]
	var beta := A.y - log(R / A.x) / (A.z if R >= A.x else A.w)
	var b := clampf(beta, B.y, B.z)
	var weight := exp(-0.5 * pow((beta - b) / arm_fade, 2.0))
	return PackedFloat64Array([beta, weight])

## The lanes from their arms: each anchored dust_map.anchor kpc out, ΔΘ upstream of its arm's
## ridge (against the rotation, toward lower β).
func _build_lanes() -> void:
	var ra: float = dust_map.anchor
	var dtheta: float = float(dust_map.omegaT) * (float(dust_map.rCR) / ra - 1.0)
	for i in arm_a.size():
		var beta := _arm_beta(i, ra)[0] - dtheta
		lanes.append([ra, beta, tan(deg_to_rad(float(dust_map.pitchIn[i]))), tan(deg_to_rad(float(dust_map.pitchOut[i])))])

## Lane i's azimuth at R: its inner pitch out to the break, its outer pitch beyond.
func _lane_beta(i: int, R: float) -> float:
	var ln: Array = lanes[i]
	var rb: float = dust_map.rBreak
	if R <= rb: return float(ln[1]) - log(R / float(ln[0])) / float(ln[2])
	return float(ln[1]) - log(rb / float(ln[0])) / float(ln[2]) - log(R / rb) / float(ln[3])

## The measured axisymmetric dust at R, M☉ kpc⁻² (Inman et al.'s eq. 1 per disc).
func _dust_axisym(R: float) -> float:
	var s := 0.0
	var discs: Array = dust_map.discs
	for k in discs.size():
		var c: Array = discs[k]
		var sigma0: float = float(c[5]) / GalModels.A_B_PER_A_V / float(dust_map.kappa)
		var rt: float = c[2]
		if R < float(c[0]): continue
		if R < float(c[1]): s += sigma0 * (R / float(c[1]) * (1.0 - float(c[4])) + float(c[4]))
		elif R <= rt: s += sigma0 * exp(-(R - float(c[1])) / float(c[3]))
		elif k == discs.size() - 1:
			s += sigma0 * exp(-(rt - float(c[1])) / float(c[3])) * exp(-(R - rt) / float(dust_map.outerH))
	return s

## Face-on dust surface density at (R, φ) in the arms' frame: each ring keeps its measured
## mean, a share of it gathered into Gaussian lanes in azimuth.
func _dust_surface(R: float, phi: float) -> float:
	var ax := _dust_axisym(R)
	if lanes.is_empty() or R < 1e-3: return ax
	var beta := phi - PI
	if arm_mirror: beta = -beta
	var fwhm: float = dust_map.fwhmIn if R <= float(dust_map.rBreak) else dust_map.fwhmOut
	var sig := deg_to_rad(fwhm) / 2.3548
	var rise := smoothstep(arm_rise.x, arm_rise.x + arm_rise.y, R)
	var acc := 0.0
	var mean := 0.0
	var wmax := 0.0
	for i in lanes.size():
		var w := _arm_beta(i, R)[1] * rise
		if w <= 0.0: continue
		var d := beta - _lane_beta(i, R)
		d -= TAU * floor((d + PI) / TAU)
		acc += w * exp(-0.5 * d * d / (sig * sig))
		# A Gaussian's mean over the circle, σ√(2π)/2π.
		mean += w * sig / sqrt(TAU)
		wmax = maxf(wmax, w)
	if mean <= 1e-12: return ax
	var f: float = float(dust_map.share) * wmax
	return ax * ((1.0 - f) + f * acc / mean)

static func _sech2(x: float) -> float:
	var e := exp(-2.0 * absf(x))
	return 4.0 * e / ((1.0 + e) * (1.0 + e))

## V optical depth per kpc at a local point.
func dust_density(x: float, y: float, z: float) -> float:
	if not dust_map.is_empty():
		var zd: float = dust_map.z
		return float(dust_map.kappa) * _arm_sample(x, z)[1] * exp(-absf(y) / zd) / (2.0 * zd)
	if dust.is_empty(): return 0.0
	var R := sqrt(x * x + z * z)
	var hd: float = dust.h0 + (dust.h1 * (R - dust.rf) if R > dust.rf else 0.0)
	var tau: float = dust.kappa * dust.rhoDisc * _envelope(R) * GalaxyVisual._sech2(y / hd)
	var ha: float = dust.h0a + (dust.h1a * (R - dust.rfa) * (R - dust.rfa) if R > dust.rfa else 0.0)
	tau += dust.kappa * dust.rhoArm * _arm_sample(x, z)[1] * exp(-y * y / (ha * ha))
	for r in rings:
		var u: float = (R - float(r[0])) / float(r[1])
		tau += float(r[2]) * exp(-0.5 * u * u) * GalaxyVisual._sech2(y / ring_h)
	return tau

func _place_lattice(cam: DVec3, t_myr: float, gain: float, pix_sr: float) -> void:
	var R := sqrt(cam.x * cam.x + cam.z * cam.z)
	var phi := atan2(cam.z, cam.x)
	var half := (SPAN - 1) / 2
	var ring0 := int(floor(R / CELL)) - half
	var turns := PackedFloat32Array()
	var firsts := PackedFloat32Array()
	turns.resize(15)
	firsts.resize(15)
	for i in SPAN:
		var ring := ring0 + i
		var rc := (float(ring) + 0.5) * CELL
		if ring < 0: continue
		var nphi := maxi(int(TAU * (float(ring) + 0.5)), 1)
		# The ring's rotation, reduced in double before it becomes a float.
		var turn := fposmod(sense * pot.vc(rc) / rc * t_myr, TAU)
		turns[i] = turn
		var j := int(floor(fposmod(phi - turn, TAU) / TAU * float(nphi))) - half
		firsts[i] = float(posmod(j, nphi))
	star_mat.set_shader_parameter("uRingBase", ring0)
	star_mat.set_shader_parameter("uHeightBase", int(floor(cam.y / CELL)) - half)
	star_mat.set_shader_parameter("uRingTurn", turns)
	star_mat.set_shader_parameter("uRingFirst", firsts)
	star_mat.set_shader_parameter("uCamLocal", Vector3(cam.x, cam.y, cam.z))
	star_mat.set_shader_parameter("uRes", res)
	star_mat.set_shader_parameter("uGain", gain)
	star_mat.set_shader_parameter("uPixSr", pix_sr)

func dispose() -> void:
	if is_instance_valid(group): group.queue_free()
	group = null
