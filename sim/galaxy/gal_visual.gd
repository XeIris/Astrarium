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

func _init(model: Dictionary) -> void:
	pot = model.potential
	sense = float(model.get("sense", 1.0))
	group = Node3D.new()
	group.name = "Galaxy_" + String(model.key)
	# A thin disc forms continuously; the bulge formed early (Bland-Hawthorn & Gerhard 2016).
	disc_pop = GalPopulation.build({"kind": "constant", "gyr": 10.0})
	sphere_pop = GalPopulation.build({"kind": "burst", "gyr": 10.0})
	_build_glow(model)
	_build_stars(model)

func _visible(model: Dictionary, part: String) -> float:
	for l in model.light:
		if l.part == part: return float(l.visible)
	return 0.0

func _light_uniforms(model: Dictionary, mat: ShaderMaterial) -> void:
	var g := GalUnits.G
	var d: Dictionary = pot.part("disc")
	var l_m_disc := disc_pop.mean_l / disc_pop.mean_mass
	var l_m_sph := sphere_pop.mean_l / sphere_pop.mean_mass
	if not d.is_empty():
		var m_sun: float = d.gm / g * GalUnits.MASS_UNIT_SUN
		mat.set_shader_parameter("uDisc", Vector3(_visible(model, "disc") * l_m_disc * m_sun * d.b * d.b / (4.0 * PI), d.a, d.b))
	else:
		mat.set_shader_parameter("uDisc", Vector3(0.0, 1.0, 1.0))
	var b: Dictionary = pot.part("bulge")
	if not b.is_empty() and b.kind == GalPotential.Kind.POWER_CUTOFF:
		mat.set_shader_parameter("uSphere", Vector4(0.0, _visible(model, "bulge") * l_m_sph * b.amp / g * GalUnits.MASS_UNIT_SUN, b.alpha, b.rc))
	elif not b.is_empty():
		mat.set_shader_parameter("uSphere", Vector4(1.0, _visible(model, "bulge") * l_m_sph * b.gm / g * GalUnits.MASS_UNIT_SUN, b.a, 0.0))
	else:
		mat.set_shader_parameter("uSphere", Vector4(0.0, 0.0, 1.0, 1.0))

func _build_glow(model: Dictionary) -> void:
	var ext: float = model.get("extent", 30.0)
	var h := 4.0
	var box := BoxMesh.new()
	box.size = Vector3(ext, h, ext) * 2.0
	glow_mat = ShaderMaterial.new()
	glow_mat.shader = GLOW_SHADER
	_light_uniforms(model, glow_mat)
	glow_mat.set_shader_parameter("uBox", Vector3(ext, h, ext))
	glow_mat.set_shader_parameter("uSphereR", 8.0)
	glow_mat.set_shader_parameter("uDiscCol", Vector3(disc_pop.color.r, disc_pop.color.g, disc_pop.color.b))
	glow_mat.set_shader_parameter("uSphereCol", Vector3(sphere_pop.color.r, sphere_pop.color.g, sphere_pop.color.b))
	glow_mat.set_shader_parameter("uFaint", Vector2(disc_pop.faint_light, sphere_pop.faint_light))
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
	var cl := Vector3(cam_local.x, cam_local.y, cam_local.z)
	glow.visible = show_glow
	stars.visible = show_stars
	# The resolved sphere shrinks with the camera's height off the plane, where there
	# are no stars to resolve, so the glow alone draws the galaxy from outside.
	res = RES_MAX if absf(cam_local.y) < 2.0 else 0.0
	if not show_stars: res = 0.0
	if res_override >= 0.0: res = res_override
	glow_mat.set_shader_parameter("uCamLocal", cl)
	glow_mat.set_shader_parameter("uGain", gain / (4.0 * PI))
	glow_mat.set_shader_parameter("uRes", res)
	if show_stars and res > 0.0: _place_lattice(cam_local, t_myr, gain, pix_sr)
	stars.visible = show_stars and res > 0.0
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
func ray_luminance(o: Vector3, d: Vector3, r_floor := 1e-3) -> float:
	var y_d := disc_pop.color.r * 0.2126 + disc_pop.color.g * 0.7152 + disc_pop.color.b * 0.0722
	var y_s := sphere_pop.color.r * 0.2126 + sphere_pop.color.g * 0.7152 + sphere_pop.color.b * 0.0722
	var dv: Vector3 = glow_mat.get_shader_parameter("uDisc")
	var box: Vector3 = glow_mat.get_shader_parameter("uBox")
	var t1 := INF
	var t0 := 0.0
	for a in 3:
		if absf(d[a]) < 1e-12:
			if absf(o[a]) > box[a]: return 0.0
			continue
		var ta := (-box[a] - o[a]) / d[a]
		var tb := (box[a] - o[a]) / d[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t1 <= t0: return 0.0
	var n := 96
	var acc := 0.0
	# Uniform in asinh about the plane crossing, as the shader samples.
	var sc := maxf(dv.z, 0.05) / maxf(absf(d.y), 1e-4)
	var tc := clampf(-o.y / d.y if absf(d.y) > 1e-9 else t0, t0, t1)
	var u0 := asinh((t0 - tc) / sc)
	var u1 := asinh((t1 - tc) / sc)
	var du := (u1 - u0) / float(n)
	for i in n:
		var u := u0 + (float(i) + 0.5) * du
		var t := tc + sc * sinh(u)
		var j := light_density(o + d * t, r_floor)
		acc += (j.x * y_d + j.y * y_s) * sc * cosh(u)
	return acc * du / (4.0 * PI)

## Bolometric luminosity density (L☉ kpc⁻³) of the disc and the spheroid at a local
## point, as gal_model.gdshaderinc computes it.
func light_density(p: Vector3, r_floor := 1e-3) -> Vector2:
	var dv: Vector3 = glow_mat.get_shader_parameter("uDisc")
	var sv: Vector4 = glow_mat.get_shader_parameter("uSphere")
	var R2 := p.x * p.x + p.z * p.z
	var zb := sqrt(p.y * p.y + dv.z * dv.z)
	var s := dv.y + zb
	var q := R2 + s * s
	var jd := dv.x * (dv.y * R2 + (dv.y + 3.0 * zb) * s * s) / (q * q * sqrt(q) * zb * zb * zb)
	var r := maxf(p.length(), r_floor)
	var js := 0.0
	if sv.y > 0.0:
		js = sv.y * pow(r, -sv.z) * exp(-r * r / (sv.w * sv.w)) if sv.x < 0.5 else sv.y * sv.z / (TAU * r * pow(r + sv.z, 3.0))
	return Vector2(jd, js)

## The spheroid's share of the resolved stars at a local point.
static func sphere_share(v: GalaxyVisual, p: Vector3) -> float:
	var j := v.light_density(p)
	var nd := j.x * v.disc_pop.resolved_per_l
	var ns := j.y * v.sphere_pop.resolved_per_l
	return ns / maxf(nd + ns, 1e-300)

## Adapt like an eye to the brightest of the given local rays: that glow is held
## near KEY on screen, and the gain never rises past the night-sky calibration (1×).
## The user's exposure applies on top.
const KEY := 1.5
func adapt(rays: Array, cam_local: Vector3, star_gain: float, dt: float) -> void:
	if not adapt_enabled: return
	var peak := 0.0
	# A degree or so at the centre's distance.
	var r_floor := maxf(cam_local.length() * 0.02, 1e-3)
	for d in rays: peak = maxf(peak, ray_luminance(cam_local, d, r_floor))
	# Pixel luminance of a ray is its luminance × K × gain (the shader's uGain is K/4π
	# per ∫j ds, and ray_luminance already divides by 4π).
	var want := 1.0 if peak <= 0.0 else minf(1.0, KEY / (peak * K * maxf(star_gain, 1e-9)))
	adaptation = exp(lerpf(log(adaptation), log(want), 1.0 - exp(-dt * 3.0))) if dt > 0.0 else want

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
