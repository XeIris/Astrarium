class_name LocalView
extends RefCounted

# ============================================================================
# LOCAL SPACE — port of sim/flight/localview.js.
# ----------------------------------------------------------------------------
# The orrery draws in scene units where one unit is an AU. A rocket is 100 m —
# 7e-10 AU — so at the camera distances a launch is watched from, the near
# plane, the depth buffer and float32 vertex precision all fail at once. This is
# not a tuning problem; it is eleven orders of magnitude and no single
# projection covers it.
#
# So spaceflight is drawn in a SECOND pass with its own scene and its own
# camera, in metres, and composited over the orrery's frame. Every space
# simulator that has ever worked does this — KSP calls the two halves "scaled
# space" and "local space" — and the split is clean here because the two never
# need to see each other: from a hundred metres the whole rest of the universe
# is background, and from a hundred kilometres the vehicle is a point.
#
# What local space contains:
#   · the vehicle and its plumes (sim/flight/craftmodel.gd, plume.gd)
#   · a GROUND PATCH with real planetary curvature, so the horizon sits where
#     it belongs: √(2Rh) away, 35.7 km from a 100 m tower, 357 km from 10 km up
#   · an ATMOSPHERE that thins with altitude on the body's own scale height, so
#     the sky goes from blue to black over exactly the range it should
#
# The ground is a parabolic sheet, y = −r²/2R, not a piece of a sphere. Over a
# few hundred kilometres the two are identical to well under a metre, and the
# sphere would put 6.4e6 into a float32 vertex where the resolution is already
# 0.4 m before the rocket's own geometry gets a look in.
#
# GODOT NOTES
#   · The pass is render/pipeline.gd's local_vp: its own World3D, its own
#     camera (pipe.local_cam), a transparent background, composited by
#     compose.glsl premultiplied over the orrery exactly as the web build drew
#     it over the orrery's frame with its own depth. Nothing here renders; the
#     pipeline draws local_vp whenever it is in Mode.FLIGHT.
#   · A FLOATING ORIGIN, one level down. The local frame's origin is the ground
#     point under the vehicle, and in a chase view at 400 km the camera and the
#     vehicle are both 4e5 m from it — where float32 is 3 cm and Godot forms
#     model × view on the GPU from two float32 matrices. So the local camera
#     sits at the origin too (rotation only), its position `cam_pos` is a DVec3,
#     and every top-level object here is placed at (its local position −
#     cam_pos), subtracted in double, by place()/apply_origin(). THREE built the
#     modelView on the CPU in float64 and never needed this.
#   · Lights: Godot's light energies already carry the π that three's Lambert
#     divides out, so every three intensity is divided by π (measured — see
#     sim/flight/modelviewer.gd). THREE.AmbientLight and THREE.HemisphereLight
#     become the environment's ambient term (the fill plus the hemisphere's
#     mean) and two diffuse-only directional lights along ±Y, one of them
#     NEGATIVE — which is exactly the hemisphere's irradiance, mix(ground, sky,
#     ½ + ½ n·y), rewritten as a constant plus ±(sky − ground)/2 · max(0, ±n·y).
# ============================================================================

# ---------------------------------------------------------------------------
# THE TRANSPARENT QUEUE, DECLARED RATHER THAN SORTED.
# ----------------------------------------------------------------------------
# Everything left transparent in this pass overlaps everything else transparent
# within a few metres of the nozzle, and a back-to-front sort by object centre
# is noise at those separations. So the order is stated, and it is the
# physical stack at the base of a rocket, read from the outside in:
#
#   sky       the background, behind everything, and depth-tested so the ground
#             occludes it rather than the other way round
#   smoke     the ground cloud and the deluge — real droplets and real alumina,
#             which genuinely scatter and genuinely hide what is behind them
#   flame     the plume and the entry sheath, LAST, because they are additive
#             emitters: a flame seen through a cloud of steam still lights the
#             steam up, and drawing it first meant the cloud painted it out.
# In Godot this is render_priority, which — like three's renderOrder — only
# sorts within the transparent list.
# ---------------------------------------------------------------------------
const ORDER := {"sky": -10, "clouds": -8, "sun": -6, "smoke": 10, "flame": 20, "flare": 40}

var pipe: RenderPipeline
var root: Node3D                 # everything in local space hangs under here
var camera: Camera3D             # pipe.local_cam — at the origin, rotation only
var sun: DirectionalLight3D
var hemi: Array = []             # the hemisphere's ±Y pair
var ground: MeshInstance3D
var sky: MeshInstance3D
var ground_mat: ShaderMaterial
var sky_mat: ShaderMaterial
## The sun as the vehicle sees it (shaders/flight/sun_disc.gdshader): its own
## sprite, because the orrery's Sun is calibrated for looking at a solar system
## and the dome's disc only existed while there was air to draw it in.
var sun_disc: MeshInstance3D
var sun_mat: ShaderMaterial
var _sun_l := Vector3.UP
var _sun_rgb := Vector3.ONE        # the star's colour, luminance 1
var _tau0 := Vector3.ZERO          # sea-level zenith optical depth, per channel
var _airmass := 1.0                # along the sun line, from the observer
const SUN_DIST := 3.0e6
## The lens's ghosts (shaders/flight/lens_flare.gdshader), and the sun's
## radiance entering the lens before the clouds, which it is fed.
var flare: MeshInstance3D
var flare_mat: ShaderMaterial
var _sun_entering := Vector3.ZERO
var reflection_sky: Sky
var reflection_material: PhysicalSkyMaterial
## The cloud field's three noise volumes (shaders/flight/clouds.gdshaderinc)
## and the pass that marches them (shaders/flight/clouds.gdshader).
var cloud_shape: NoiseTexture3D
var cloud_worley: NoiseTexture3D
var cloud_detail: NoiseTexture3D
var clouds: MeshInstance3D
var cloud_mat: ShaderMaterial
## The same field on the CPU, for what the DirectionalLight cannot know: how
## much of the sun reaches the vehicle (CloudField's header).
var cloud_field: CloudField
## That fraction, eased, and applied to the sun light's energy.
var sun_through := 1.0
## The planet's rotation since the flight began, rad, and the local frame's
## axes in world coordinates: together, the local → planet-fixed transform
## every cloud sample (and the ground's own detail) is taken in.
var _to_planet := Basis()
const CLOUD_BASE := 1500.0
const CLOUD_TOP := 4600.0
const CLOUD_SIGMA := 0.03
var render_quality := "medium"
var _reflection_body := ""
var _has_air := true
## Everything that belongs to the vehicle hangs off here, so the whole craft
## can be swapped without touching the world.
var craft_root: Node3D

## The local camera's position in the local frame, metres, DOUBLE. The render
## camera itself is at the origin; see the header.
var cam_pos := DVec3.new()
## The ground patch's own vertical offset (the web build's ground.position.y).
var ground_y := 0.0
var _placed: Array = []          # [Node3D, DVec3]
var _earth_requested := false
var _earth_color: Texture2D = null
var _earth_land: Texture2D = null

const _POLE := Vector3(0, -1, 0)

## Build the local-space scene inside pipe.local_root.
static func create_local_view(p: RenderPipeline) -> LocalView:
	return LocalView.new(p)

func _init(p: RenderPipeline) -> void:
	pipe = p
	camera = pipe.local_cam
	camera.fov = 55.0
	camera.near = 0.05
	camera.far = 4.0e6
	camera.transform = Transform3D.IDENTITY
	# The vehicle meshes carry authored LODs nothing asked for; the web build
	# drew every triangle at every range.
	pipe.local_vp.mesh_lod_threshold = 0.0
	root = Node3D.new()
	root.name = "LocalView"
	pipe.local_root.add_child(root)

	# Lights. A directional sun (parallel rays: the real thing is 1.5e11 m away),
	# a dim fill for the shadowed side, and a hemisphere term standing in for
	# light bounced off the planet — which is a large part of what actually
	# lights a spacecraft in low orbit.
	sun = DirectionalLight3D.new()
	sun.name = "sun"
	sun.light_color = Color.hex(0xfff4e2ff)
	sun.light_energy = 3.1 / PI
	sun.light_angular_distance = 0.53
	sun.shadow_enabled = false
	root.add_child(sun)
	# The visible dome is custom because this pass is transparent, but a
	# separate physical sky can still light PBR metal through its radiance map.
	# Without it the reflection source is black and metal reads as paint.
	reflection_sky = Sky.new()
	reflection_sky.radiance_size = Sky.RADIANCE_SIZE_64
	reflection_material = PhysicalSkyMaterial.new()
	reflection_material.turbidity = 3.0
	reflection_material.energy_multiplier = 0.7
	reflection_sky.sky_material = reflection_material
	pipe.env_local.sky = reflection_sky
	for s in [1.0, -1.0]:
		var l := DirectionalLight3D.new()
		l.name = "bounce_up" if s > 0.0 else "bounce_down"
		l.light_negative = s < 0.0
		l.light_specular = 0.0
		l.shadow_enabled = false
		# s = +1 shines DOWN (lights n·y > 0); s = −1 shines UP, negative.
		l.basis = Basis.looking_at(Vector3(0, -s, 0), Vector3(0, 0, 1))
		root.add_child(l)
		hemi.append(l)
	_set_ambient(0.55)

	# ---- ground: a unit disc re-tessellated radially so there are rings, not
	# one fan — 90 rings of 128.
	var rings := 90
	var segs := 128
	var pos := PackedVector3Array()
	var idx := PackedInt32Array()
	for r in rings + 1:
		var u := float(r) / rings
		for s in segs:
			var a := float(s) / segs * PI * 2.0
			pos.append(Vector3(cos(a) * u, 0.0, sin(a) * u))
	for r in rings:
		for s in segs:
			var a := r * segs + s
			var b := r * segs + (s + 1) % segs
			var c := (r + 1) * segs + s
			var d := (r + 1) * segs + (s + 1) % segs
			# three: (a, c, b), (b, c, d) — swapped once for Godot's winding
			idx.append_array([a, b, c, b, d, c])
	var nrm := PackedVector3Array()
	nrm.resize(pos.size())
	nrm.fill(Vector3.UP)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_NORMAL] = nrm
	arr[Mesh.ARRAY_INDEX] = idx
	var gm := ArrayMesh.new()
	gm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	ground_mat = ShaderMaterial.new()
	ground_mat.shader = load("res://shaders/flight/ground.gdshader")
	var gu := {
		"uRadius": 6.371e6, "uPatch": 4e4, "uEye": 0.0,
		"uGround": _v3(0x4a6b3f), "uRock": _v3(0x6b5a45), "uHaze": _v3(0x8fb6e8), "uSea": _v3(0x1b3a6b),
		"uSunDir": Vector3(0, 1, 0), "uScaleH": 8500.0, "uDensity": 2.4e-5, "uHasAir": 1.0,
		"uSeaLevel": 0.42, "uOceans": 1.0, "uSunI": 3.0, "uSkyI": 0.35, "uTemp": 288.0,
		"uGeoReady": 0.0, "uGeoFrame": Basis(), "uPadLocal": Vector2.ZERO,
	}
	for k in gu: ground_mat.set_shader_parameter(k, gu[k])
	# OPAQUE. It was transparent once, and being transparent is what put it in
	# the wrong queue: sorted against the plumes by centroid, it won the coin
	# toss on some frames and — writing depth — stamped the plume out. Nothing
	# about this surface was ever transparent. It is dirt.
	ground = MeshInstance3D.new()
	ground.name = "ground"
	ground.mesh = gm
	ground.material_override = ground_mat
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# frustumCulled = false: the vertex shader stretches the unit disc to the
	# patch radius (up to 1.2e6 m) and drops it by the curvature.
	ground.custom_aabb = AABB(Vector3(-1.3e6, -2.0e5, -1.3e6), Vector3(2.6e6, 2.1e5, 2.6e6))
	root.add_child(ground)

	# ---- sky dome. Drawn after the ground with no depth write, so it tints the
	# ground near the horizon as well as filling the sky. Depth-TESTED (see
	# shaders/flight/sky_dome.gdshader). Its radius is larger than the ground
	# patch can ever be (1.2e6) so the two never intersect, and comfortably
	# inside the camera's far plane.
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/flight/sky_dome.gdshader")
	sky_mat.set_shader_parameter("uSunDir", Vector3(0, 1, 0))
	sky_mat.set_shader_parameter("uTint", _v3(0x4a7fd0))
	sky_mat.set_shader_parameter("uHaze", _v3(0x8fb6e8))
	sky_mat.set_shader_parameter("uEye", 0.0)
	sky_mat.set_shader_parameter("uScaleH", 8500.0)
	sky_mat.set_shader_parameter("uHasAir", 1.0)
	sky_mat.set_shader_parameter("uThick", 1.05)
	sky_mat.render_priority = ORDER.sky
	sky = MeshInstance3D.new()
	sky.name = "sky"
	sky.mesh = CraftModel._to_mesh(CraftModel._sphere(3.0e6, 48, 28), sky_mat)
	sky.material_override = sky_mat
	sky.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sky.custom_aabb = AABB(Vector3(-3.1e6, -3.1e6, -3.1e6), Vector3(6.2e6, 6.2e6, 6.2e6))
	root.add_child(sky)

	# ---- the cloud layer: a sphere round the camera, drawn after the sky,
	# marching the field per pixel and stopping at the depth buffer. Only its
	# direction matters, so its size is anything comfortably past the near
	# plane and inside the far one.
	cloud_mat = ShaderMaterial.new()
	cloud_mat.shader = load("res://shaders/flight/clouds.gdshader")
	cloud_mat.render_priority = ORDER.clouds
	clouds = MeshInstance3D.new()
	clouds.name = "clouds"
	clouds.mesh = CraftModel._to_mesh(CraftModel._sphere(3000.0, 32, 16), cloud_mat)
	clouds.material_override = cloud_mat
	clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	clouds.custom_aabb = AABB(Vector3(-3100, -3100, -3100), Vector3(6200, 6200, 6200))
	clouds.visible = false
	root.add_child(clouds)

	# ---- the sun. After the sky and the clouds, before the smoke and flames,
	# so a launch cloud still passes in front of it.
	sun_mat = ShaderMaterial.new()
	sun_mat.shader = load("res://shaders/flight/sun_disc.gdshader")
	sun_mat.render_priority = ORDER.sun
	var sq := QuadMesh.new()
	sq.size = Vector2(1, 1)
	sun_disc = MeshInstance3D.new()
	sun_disc.name = "sun_disc"
	sun_disc.mesh = sq
	sun_disc.material_override = sun_mat
	sun_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the vertex shader turns and sizes it; never cull it
	sun_disc.custom_aabb = AABB(Vector3(-2.0e6, -2.0e6, -2.0e6), Vector3(4.0e6, 4.0e6, 4.0e6))
	root.add_child(sun_disc)
	# ---- its ghosts: a full-screen pass, last of all, since they are in the
	# lens and in front of everything
	flare_mat = ShaderMaterial.new()
	flare_mat.shader = load("res://shaders/flight/lens_flare.gdshader")
	flare_mat.render_priority = ORDER.flare
	flare_mat.set_shader_parameter("uDist", SUN_DIST)
	flare = MeshInstance3D.new()
	flare.name = "lens_flare"
	flare.mesh = sq
	flare.material_override = flare_mat
	flare.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flare.custom_aabb = AABB(Vector3(-4.0e6, -4.0e6, -4.0e6), Vector3(8.0e6, 8.0e6, 8.0e6))
	root.add_child(flare)

	craft_root = Node3D.new()
	craft_root.name = "craft_root"
	root.add_child(craft_root)

	place(ground, DVec3.new())
	place(sky, DVec3.new())

static func _v3(hex: int) -> Vector3:
	var c := U.lin(hex)
	return Vector3(c.r, c.g, c.b)

## THREE.AmbientLight(0x223044, 0.30) + THREE.HemisphereLight(0x8899aa,
## 0x33302c, bounce): the ambient term is the fill plus the hemisphere's mean,
## the ±Y pair carries its half-difference. See the header.
func _set_ambient(bounce: float) -> void:
	var fill := U.lin(0x223044)
	var skyc := U.lin(0x8899aa)
	var gnd := U.lin(0x33302c)
	var amb := Color(fill.r * 0.30 + (skyc.r + gnd.r) * 0.5 * bounce,
		fill.g * 0.30 + (skyc.g + gnd.g) * 0.5 * bounce,
		fill.b * 0.30 + (skyc.b + gnd.b) * 0.5 * bounce)
	var env := pipe.env_local
	# High uses the sky's directional diffuse irradiance. The old constant
	# colour left backlit vehicles almost black in bright daylight.
	if render_quality == "high" and _has_air:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_energy = 0.7
		for l: DirectionalLight3D in hemi: l.light_energy = 0.0
		return
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var am := maxf(maxf(amb.r, amb.g), maxf(amb.b, 1e-6))
	# Environment colours are sRGB and converted like three's hex; these are
	# linear sums, so they go back through linear_to_srgb first.
	env.ambient_light_color = Color(amb.r / am, amb.g / am, amb.b / am).linear_to_srgb()
	env.ambient_light_energy = am / PI
	var half := Color((skyc.r - gnd.r) * 0.5, (skyc.g - gnd.g) * 0.5, (skyc.b - gnd.b) * 0.5)
	var hm := maxf(maxf(absf(half.r), absf(half.g)), maxf(absf(half.b), 1e-6))
	var hc := Color(absf(half.r) / hm, absf(half.g) / hm, absf(half.b) / hm).linear_to_srgb()
	for l: DirectionalLight3D in hemi:
		l.light_color = hc
		l.light_energy = hm * bounce / PI

func set_render_quality(q: String) -> void:
	render_quality = q
	if q != "low" and cloud_shape == null:
		# Tiling volumes, generated once on Godot's worker thread. The large
		# scales (the weather, the turrets) are Perlin and big-celled Worley;
		# the erosion is small Worley. Each is inverted where it is Worley so
		# that the CELLS, not the edges between them, are the dense part —
		# which is the whole difference between billows and a honeycomb.
		cloud_shape = _noise3d(96, 2731, FastNoiseLite.TYPE_PERLIN, 0.035, 4, false)
		cloud_worley = _noise3d(64, 977, FastNoiseLite.TYPE_CELLULAR, 0.05, 2, true)
		cloud_detail = _noise3d(48, 4410, FastNoiseLite.TYPE_CELLULAR, 0.09, 3, true)
		cloud_field = CloudField.new(cloud_shape, cloud_worley, cloud_detail)
		for m in [cloud_mat, ground_mat, sun_mat]:
			m.set_shader_parameter("uCloudShape", cloud_shape)
			m.set_shader_parameter("uCloudWorley", cloud_worley)
			m.set_shader_parameter("uCloudDetail", cloud_detail)
	# High marches finely, with erosion and a long light march; Medium is the
	# same field, coarser; Low has no clouds.
	cloud_mat.set_shader_parameter("uSteps", 64 if q == "high" else 28)
	cloud_mat.set_shader_parameter("uLightSteps", 6 if q == "high" else 3)
	cloud_mat.set_shader_parameter("uDetail", 1.0 if q == "high" else 0.0)

static func _noise3d(size: int, seed: int, type: int, freq: float, octaves: int, invert: bool) -> NoiseTexture3D:
	var t := NoiseTexture3D.new()
	t.width = size; t.height = size; t.depth = size
	t.seamless = true
	t.invert = invert
	var n := FastNoiseLite.new()
	n.seed = seed
	n.noise_type = type
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	if type == FastNoiseLite.TYPE_CELLULAR:
		n.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
		n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	t.noise = n
	return t

## Keep `node` at local-frame position `p` (metres, double) under the local
## floating origin. `p` is held by reference: mutate it and the node follows.
func place(node: Node3D, p: DVec3) -> void:
	for pn in _placed:
		if pn[0] == node:
			pn[1] = p
			return
	_placed.append([node, p])

func unplace(node: Node3D) -> void:
	for i in range(_placed.size() - 1, -1, -1):
		if _placed[i][0] == node: _placed.remove_at(i)

## Put every placed node at (its local position − cam_pos), in double, and the
## render camera at the origin with the view's orientation.
func apply_origin(basis: Basis) -> void:
	camera.transform = Transform3D(basis, Vector3.ZERO)
	clouds.position = Vector3.ZERO
	var cl := cam_pos.to_v3()
	for m in [cloud_mat, ground_mat, sun_mat]: m.set_shader_parameter("uCamLocal", cl)
	# The EYE is the camera, not the vehicle. The sky's column and the ground's
	# haze both run from the eye's altitude, and on the pad the vehicle's is
	# zero while the camera stands tens of metres above the ground patch
	# (which lies grade_drop below the deck datum). From zero the sky's ground
	# root sat at t ≈ 0 for every ray below the horizontal, float rounding left
	# no path at all, and the patch's dithered rim showed black speckle through
	# a dome that had nothing to draw there.
	var gy := 0.0
	for pn in _placed:
		if pn[0] == ground: gy = float((pn[1] as DVec3).y)
	var eye := maxf(float(cam_pos.y) - gy, 1.0)
	sky_mat.set_shader_parameter("uEye", eye)
	ground_mat.set_shader_parameter("uEye", eye)
	# The sun is at infinity: a fixed distance from the camera, whatever the
	# camera's position — which, here, is always the origin.
	sun_disc.position = _sun_l * SUN_DIST
	for pn in _placed:
		var n: Node3D = pn[0]
		if is_instance_valid(n):
			n.position = (pn[1] as DVec3).rel_v3(cam_pos)

## Point the local world at the vehicle's actual situation.
##
## The local frame is defined so that +Y is the vehicle's local UP and the
## origin is directly beneath it on the surface — which makes the ground patch
## a flat sheet in this frame, and makes the vehicle's height above it
## literally its altitude.
##
## `o`: {env, altitude, sunDirWorld: DVec3, upWorld: DVec3, northWorld: DVec3,
## starFlux, padWorld: DVec3|null, mapSite: {lat, lon}|null}. Returns
## {east, north, up} as DVec3.
func update(o: Dictionary) -> Dictionary:
	var env: Dictionary = o.env
	var atm = env.atm
	var has_air := 1.0 if atm != null else 0.0
	_has_air = atm != null
	pipe.env_local.reflected_light_source = Environment.REFLECTION_SOURCE_SKY \
		if render_quality == "high" and atm != null else Environment.REFLECTION_SOURCE_DISABLED
	# Near-field aerial perspective gives the tower and vehicle a shared air
	# volume. The long-range ground shader still handles the horizon.
	pipe.env_local.volumetric_fog_enabled = render_quality == "high" and atm != null \
		and float(o.altitude) < 3000.0
	pipe.env_local.volumetric_fog_density = 0.00018
	pipe.env_local.volumetric_fog_length = 1100.0
	pipe.env_local.volumetric_fog_albedo = Color(0.82, 0.88, 0.95)
	pipe.env_local.volumetric_fog_anisotropy = 0.55
	pipe.env_local.volumetric_fog_sky_affect = 0.0
	if atm != null and _reflection_body != str(env.name):
		_reflection_body = str(env.name)
		reflection_material.rayleigh_color = Color.hex((int(atm.tint) << 8) | 0xff)
		reflection_material.turbidity = clampf(float(atm.rho0) * 3.0, 1.0, 10.0)
	var h := maxf(float(o.altitude), 0.0)
	# Horizon distance √(2Rh), with a floor so there is always ground to see,
	# and a ceiling because past a few hundred km the orrery's own planet mesh
	# is the better picture.
	var horizon := sqrt(2.0 * float(env.radius) * maxf(h, 3.0)) * 1.35
	var patch := clampf(horizon, 2.5e4, 1.2e6)
	var sh := Rocketry.scale_height(atm, h) if atm != null else 1.0
	ground_mat.set_shader_parameter("uPatch", patch)
	ground_mat.set_shader_parameter("uRadius", float(env.radius))
	ground_mat.set_shader_parameter("uEye", h)
	ground_mat.set_shader_parameter("uHasAir", has_air)
	ground_mat.set_shader_parameter("uScaleH", sh)
	ground_mat.set_shader_parameter("uGround", _v3(int(env.ground)))
	ground_mat.set_shader_parameter("uRock", _v3(int(env.rock)))
	ground_mat.set_shader_parameter("uOceans", 1.0 if env.oceans else 0.0)
	ground_mat.set_shader_parameter("uSea", _v3(int(env.sea)))
	if atm != null:
		ground_mat.set_shader_parameter("uHaze", _v3(int(atm.haze)))
		sky_mat.set_shader_parameter("uTint", _v3(int(atm.tint)))
		sky_mat.set_shader_parameter("uHaze", _v3(int(atm.haze)))
		sky_mat.set_shader_parameter("uScaleH", sh)
		# Optical thickness scaled off the body's surface density, so Mars gets
		# its thin butterscotch sky and Venus a wall of it, from one number.
		sky_mat.set_shader_parameter("uThick", clampf(float(atm.rho0) * 0.9, 0.02, 6.0))
		ground_mat.set_shader_parameter("uDensity", 2.6e-5 * clampf(float(atm.rho0), 0.02, 4.0))
	sky_mat.set_shader_parameter("uEye", h)
	sky_mat.set_shader_parameter("uRadius", float(env.radius))
	sky_mat.set_shader_parameter("uHasAir", has_air)
	# Irradiance falls as 1/r² from the star; the local sun light and the
	# ground shader are driven from the same number so they cannot disagree.
	var flux := clampf(3.0 * float(U.nz(o.get("starFlux"), 1.0)), 0.05, 12.0)
	ground_mat.set_shader_parameter("uSunI", flux)
	ground_mat.set_shader_parameter("uTemp", maxf(float(env.get("teq", 255.0)), 30.0))
	sun.light_energy = flux / PI * sun_through
	# Skylight only exists where there is air to scatter in.
	ground_mat.set_shader_parameter("uSkyI", 0.42 * exp(-h / maxf(sh * 2.0, 1.0)) if atm != null else 0.03)
	# Ground fades out entirely once the orrery's planet takes over.
	ground.visible = h < 4.0e5
	# ...and the sky with it: the limb is the dome's (sky_dome.gdshader), and
	# it is most of what an ascent through 100–400 km looks like.
	sky.visible = atm != null and h < 4.0e5

	# Sun direction expressed in the local frame: its component along the local
	# up is what decides day, night and the colour of both.
	var up: DVec3 = DQuat.nrm((o.upWorld as DVec3).clone())
	var east := DQuat.nrm(DVec3.new().cross_vectors(up, o.northWorld))
	var north := DQuat.nrm(DVec3.new().cross_vectors(east, up))
	ground_mat.set_shader_parameter("uGeoReady", 0.0)
	var pad = o.get("padWorld")
	# The planet-fixed point the ground's detail is laid out about: the pad
	# when there is one, else wherever the flight began (spaceflight.gd).
	var anchor = pad if pad != null else o.get("anchorWorld")
	if anchor != null:
		ground_mat.set_shader_parameter("uAnchor", Vector2((anchor as DVec3).dot(east), (anchor as DVec3).dot(north)))
	ground_mat.set_shader_parameter("uHasPad", 1.0 if pad != null else 0.0)
	var map_site = o.get("mapSite")
	if env.name == "Earth" and pad != null and map_site != null:
		if not _earth_requested:
			_earth_requested = true
			PlanetMaps.load_planet_map("Earth", func(m: Dictionary) -> void:
				_earth_color = m.color
				_earth_land = m.mask
				ground_mat.set_shader_parameter("uEarthColor", m.color)
				ground_mat.set_shader_parameter("uEarthLand", m.mask))
		if _earth_color != null and _earth_land != null:
			var site_up := DQuat.nrm((pad as DVec3).clone())
			var pole := DVec3.new(0.0, -1.0, 0.0)
			var site_north := DQuat.nrm(pole.clone().add_scaled_in(site_up, -pole.dot(site_up)))
			var site_east := DQuat.nrm(site_north.cross(site_up))
			var lat: float = float(map_site.lat) * PI / 180.0
			var lon: float = float(map_site.lon) * PI / 180.0
			var geo_up := DVec3.new(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			var geo_north := DVec3.new(-sin(lat) * cos(lon), cos(lat), -sin(lat) * sin(lon))
			var geo_east := DVec3.new(-sin(lon), 0.0, cos(lon))
			var to_geo := func(v: DVec3) -> Vector3:
				return geo_east.scaled(v.dot(site_east)).add_scaled_in(geo_up, v.dot(site_up)) \
					.add_scaled_in(geo_north, v.dot(site_north)).to_v3()
			var gx: Vector3 = to_geo.call(east)
			var gy: Vector3 = to_geo.call(up)
			var gz: Vector3 = to_geo.call(north)
			# Matrix3.set() is row-major: its COLUMNS are gx, gy, gz.
			ground_mat.set_shader_parameter("uGeoFrame", Basis(gx, gy, gz))
			ground_mat.set_shader_parameter("uPadLocal", Vector2((pad as DVec3).dot(east), (pad as DVec3).dot(north)))
			ground_mat.set_shader_parameter("uGeoReady", 1.0)
	var sw: DVec3 = o.sunDirWorld
	var sun_l := Vector3(sw.dot(east), sw.dot(up), sw.dot(north)).normalized()
	pipe.postfx.flight_exposure = 1.10 if env.name == "Earth" and sun_l.y > 0.10 else 1.0
	var sun_vis := _update_sun(o, env, atm, h, sh, sun_l)
	_update_clouds(o, env, atm, h, sh, sun_l, east, up, north)
	flare.visible = sun_vis > 0.0
	flare_mat.set_shader_parameter("uSunLocal", sun_l)
	flare_mat.set_shader_parameter("uSunRGB", _sun_entering * sun_through)
	ground_mat.set_shader_parameter("uSunDir", sun_l)
	sky_mat.set_shader_parameter("uSunDir", sun_l)
	# A DirectionalLight3D shines along its own −Z; three's shines from its
	# position toward its target (the origin).
	if sun_l.length_squared() > 0.0:
		var ref := Vector3(0, 0, 1) if absf(sun_l.y) > 0.99 else Vector3.UP
		sun.basis = Basis.looking_at(-sun_l, ref)
	# Planetshine: strong in low orbit over a bright planet, gone in deep space.
	_set_ambient(clampf(0.75 * (1.0 - h / 8e5), 0.04, 0.75))
	return {"east": east, "north": north, "up": up.clone(), "sun_local": sun_l, "sun_visible": sun_vis}

## THE CLOUD LAYER, per frame: where it is (the planet-fixed frame), what
## lights it, and whether this world has one.
##
## Earth only: its fair-weather cumulus is what a launch is photographed
## against. Venus's cloud is a 20 km deck that starts 48 km up and the view
## under it is a uniform murk the sky dome already draws; Mars's water-ice
## clouds are thin cirrus at altitudes this layer does not model.
func _update_clouds(o: Dictionary, env: Dictionary, atm, h: float, sh: float, sun_l: Vector3,
		east: DVec3, up: DVec3, north: DVec3) -> void:
	var cover := 0.0
	if render_quality != "low" and env.name == "Earth" and atm != null and cloud_shape != null:
		# fair-weather cumulus, broken: what most launches are flown under
		cover = float(U.nz(o.get("cloudCover"), 0.30))
	# Past a few hundred kilometres the orrery's planet (with its own cloud
	# deck) is the picture; the local layer only exists over the ground patch.
	clouds.visible = cover > 0.0 and h < 4.0e5
	var R := float(env.radius)
	# local → world is the basis with columns (east, up, north); world →
	# planet-fixed undoes the planet's spin about its pole, which is −Y, so it
	# is a rotation about +Y by the angle turned (see spaceflight.gd).
	var fb := Basis(east.to_v3(), up.to_v3(), north.to_v3())
	_to_planet = Basis(Vector3.UP, float(U.nz(o.get("planetSpin"), 0.0))) * fb
	var wind: Vector3 = o.get("cloudWind", Vector3.ZERO)
	# the pad, planet-fixed, for the thinning round it
	var clear_at := Vector3.ZERO
	var clear_r := 0.0
	var pad = o.get("padWorld")
	if pad != null:
		clear_at = _to_planet * Vector3((pad as DVec3).dot(east), R, (pad as DVec3).dot(north))
		clear_r = 9000.0
	for m in [cloud_mat, ground_mat, sun_mat]:
		m.set_shader_parameter("uClearAt", clear_at)
		m.set_shader_parameter("uClearR", clear_r)
		m.set_shader_parameter("uCloudCoverage", cover)
		m.set_shader_parameter("uLocalToPlanet", _to_planet)
		m.set_shader_parameter("uPlanetR", R)
		m.set_shader_parameter("uCloudWind", wind)
		m.set_shader_parameter("uCloudBase", CLOUD_BASE)
		m.set_shader_parameter("uCloudTop", CLOUD_TOP)
		m.set_shader_parameter("uCloudSigma", CLOUD_SIGMA)
	# The vehicle's own sunlight, through the same field (see cloud_field):
	# sampled at the craft, the thing the camera is exposing for.
	var through := 1.0
	if cloud_field != null and cover > 0.0 and h < CLOUD_TOP + 2000.0:
		cloud_field.coverage = cover
		cloud_field.base = CLOUD_BASE; cloud_field.top = CLOUD_TOP
		cloud_field.sigma = CLOUD_SIGMA; cloud_field.radius = R
		cloud_field.wind = wind
		cloud_field.clear_at = clear_at; cloud_field.clear_r = clear_r
		var craft_local := Vector3(0.0, h, 0.0)
		var pp := _to_planet * (craft_local + Vector3(0.0, R, 0.0))
		through = cloud_field.sun_transmittance(pp, (_to_planet * sun_l).normalized())
	sun_through += (through - sun_through) * (1.0 - exp(-float(U.nz(o.get("dt"), 0.016)) / 0.35))
	if not clouds.visible: return
	# The sun as it arrives at the middle of the layer: the same extinction as
	# the disc's (see _update_sun), for the column above 3 km.
	var flux := clampf(3.0 * float(U.nz(o.get("starFlux"), 1.0)), 0.05, 12.0)
	var T := Vector3.ONE
	if atm != null:
		var dens := clampf(float(atm.rho0) / 1.225, 0.0, 6.0)
		T = Vector3(exp(-_tau0.x * dens * exp(-3000.0 / 8500.0) * _airmass),
			exp(-_tau0.y * dens * exp(-3000.0 / 8500.0) * _airmass),
			exp(-_tau0.z * dens * exp(-3000.0 / 8500.0) * _airmass))
	# day → twilight → night, as the dome's own "sun" factor
	var day := clampf(sun_l.y * 2.0 + 0.25, 0.0, 1.0)
	var sun_col := Vector3(_sun_rgb.x * T.x, _sun_rgb.y * T.y, _sun_rgb.z * T.z) * flux * day
	cloud_mat.set_shader_parameter("uSunDir", sun_l)
	cloud_mat.set_shader_parameter("uSunColor", sun_col)
	cloud_mat.set_shader_parameter("uPixAngle",
		2.0 * tan(deg_to_rad(camera.fov * 0.5)) / maxf(float(pipe.local_vp.size.y), 1.0))
	# Skylight on the upper faces (the dome's own tint, at the brightness of a
	# clear sky) and the ground's bounce on the lower ones.
	var tint := _v3(int(atm.tint))
	cloud_mat.set_shader_parameter("uSkyTop", tint * (0.55 * day + 0.01))
	var g := _v3(int(env.ground))
	cloud_mat.set_shader_parameter("uSkyBottom", g * flux * maxf(sun_l.y, 0.0) * 0.30 / PI + tint * 0.05 * day)
	cloud_mat.set_shader_parameter("uHaze", _v3(int(atm.haze)) * (0.35 + 0.75 * maxf(sun_l.y, 0.0)) * day)
	cloud_mat.set_shader_parameter("uHazeDensity", 2.6e-5 * clampf(float(atm.rho0), 0.02, 4.0))
	cloud_mat.set_shader_parameter("uHazeRho", exp(-h / maxf(sh, 1.0)))
	cloud_mat.set_shader_parameter("uMaxDist", clampf(sqrt(2.0 * R * maxf(h, 3000.0)) * 1.6, 60000.0, 1.2e6))

## Point and filter the sun sprite. Returns the fraction of the disc above the
## horizon, which is also what decides whether the camera is exposing for
## daylight (spaceflight.gd dims the stars by it).
##
## `o.sunAngR` is the star's angular radius from here and `o.sunTeff` its
## temperature; both default to the Sun from Earth.
func _update_sun(o: Dictionary, env: Dictionary, atm, h: float, sh: float, sun_l: Vector3) -> float:
	_sun_l = sun_l
	var R := float(env.radius)
	var ang_r := float(U.nz(o.get("sunAngR"), 0.00465))
	# The HORIZON, not the horizontal: from altitude h the limb is depressed by
	# acos(R / (R + h)) — 5° at 25 km, 20° at 400 km — and the sun is up until
	# it sets behind THAT. Beyond the ground patch there is nothing in this pass
	# to hide it, so the planet's occlusion has to be said here.
	var dip := acos(clampf(R / (R + h), -1.0, 1.0))
	var elev := asin(clampf(sun_l.y, -1.0, 1.0))
	var vis := U.smooth(elev, -dip - ang_r, -dip + ang_r)
	sun_disc.visible = vis > 0.0
	sun_mat.set_shader_parameter("uVisible", vis)
	sun_mat.set_shader_parameter("uAngR", ang_r)
	sun_mat.set_shader_parameter("uSunLocal", sun_l)

	sun_mat.set_shader_parameter("uDist", SUN_DIST)
	# Surface brightness is independent of distance (flux and solid angle both
	# go as 1/r²), so the disc's radiance goes only with the star's T⁴.
	var teff := float(U.nz(o.get("sunTeff"), 5772.0))
	var bb := Stellar.blackbody_color(teff)
	var lum := maxf(bb.r * 0.2126 + bb.g * 0.7152 + bb.b * 0.0722, 1e-4)
	sun_mat.set_shader_parameter("uColor", Vector3(bb.r, bb.g, bb.b) / lum)
	sun_mat.set_shader_parameter("uRadiance", 2400.0 * pow(teff / 5772.0, 4.0))
	# EXTINCTION. Zenith optical depths at sea level for 680 / 550 / 440 nm:
	# Rayleigh 0.042 / 0.097 / 0.235 (∝ λ⁻⁴) and a clear-day aerosol load of
	# 0.08 · (λ / 550)^-1.3. The column above the observer falls as e^(−h/H),
	# and the air mass along the sun line is Kasten & Young's (1989), which
	# stays finite at the horizon where 1/sin(e) does not.
	var tau := Vector3.ZERO
	var m := 1.0
	var aerosol := 0.0
	_sun_rgb = Vector3(bb.r, bb.g, bb.b) / lum
	_tau0 = Vector3(0.042, 0.097, 0.235) + Vector3(0.061, 0.080, 0.109)
	if atm != null:
		var col := exp(-h / maxf(sh, 1.0))
		var dens := clampf(float(atm.rho0) / 1.225, 0.0, 6.0)
		tau = _tau0 * dens * col
		var e_deg := rad_to_deg(elev + dip)
		m = 1.0 / (sin(maxf(elev + dip, -0.02)) + 0.50572 * pow(maxf(e_deg + 6.07995, 0.3), -1.6364))
		aerosol = col * dens * clampf(sqrt(m), 1.0, 6.0)
	_airmass = m
	sun_mat.set_shader_parameter("uTau", tau)
	sun_mat.set_shader_parameter("uAirMass", m)
	sun_mat.set_shader_parameter("uAureole", aerosol)
	var T := Vector3(exp(-tau.x * m), exp(-tau.y * m), exp(-tau.z * m))
	_sun_entering = _sun_rgb * T * 2400.0 * pow(teff / 5772.0, 4.0) * vis \
		* (ang_r * ang_r) / (0.00465 * 0.00465)
	return vis

func set_size(_w: float, _h: float) -> void:
	# The render camera keeps its aspect from the viewport (keep_height, as
	# THREE's vertical fov).
	pass

func dispose() -> void:
	if is_instance_valid(root): root.queue_free()

# ---------------------------------------------------------------------------
# THE FLIGHT CAMERA
# ----------------------------------------------------------------------------
# Four modes, and they exist because a launch, an orbit and a landing are
# looked at from completely different places:
#
#   CHASE   — behind and above, framing the vehicle against what it is flying
#             over. The distance follows the vehicle's own length, so a Saturn V
#             and a lunar module are both framed rather than one being a dot.
#   ORBIT   — a free turntable around the vehicle. This is the inspection mode.
#   COCKPIT — at the top of the stack looking along the thrust axis.
#   PAD     — fixed on the ground, watching it go. Only meaningful near a
#             surface, and it is the one that sells a launch.
#
# Positions are DVec3 in the local frame (see the header: the camera and the
# vehicle can both be 4e5 m from the origin); directions are Vector3.
# ---------------------------------------------------------------------------
class FlightCamera extends RefCounted:
	var state := {
		"mode": "chase", "dist": 1.0, "yaw": 2.2, "pitch": 0.28, "fov": 55.0, "userAimed": false,
		"padPos": DVec3.new(), "hasPad": false,
	}
	## The camera's pose after update(): position (local frame, DVec3), basis
	## (Godot: −Z forward), near plane.
	var pos := DVec3.new()
	var basis := Basis()
	var near := 0.05

	func set_mode(m: String) -> void:
		state.mode = m

	## THE NEAR PLANE IS WHAT SETS THE DEPTH RESOLUTION, and it was a constant.
	##
	## Nothing is ever 5 cm from this camera. The nearest thing in frame is at
	## worst a fraction of the vehicle's own length away, so the near plane is
	## derived from the shot rather than declared: a fixed fraction of the
	## distance to what is being looked at, which is the quantity the whole
	## framing is built on anyway. (Godot's depth buffer is reversed-Z float and
	## far less fragile than the web build's 24-bit one, but the frustum is
	## still built in float32, so the same near plane keeps far/near sane.)
	func depth_range(craft_pos: DVec3, L: float) -> void:
		var d := pos.distance_to(craft_pos)
		# Half a vehicle-length of headroom, so the camera can be inside the
		# stack (cockpit) without the nose clipping.
		var n := clampf(minf(d, maxf(d - L * 0.6, 0.05)) * 0.02, 0.05, 40.0)
		if absf(n / near - 1.0) > 0.02:
			near = n

	## THREE's Object3D.lookAt for a camera: z = eye − target, x = up × z,
	## y = z × x, with three's own nudge when up is parallel to the view.
	func look_at(target: DVec3, up: Vector3) -> void:
		var z := target.sub(pos).to_v3() * -1.0
		if z.length_squared() == 0.0: z = Vector3(0, 0, 1)
		z = z.normalized()
		var x := up.cross(z)
		if x.length_squared() == 0.0:
			if absf(up.z) == 1.0: z.x += 0.0001
			else: z.z += 0.0001
			z = z.normalized()
			x = up.cross(z)
		x = x.normalized()
		var y := z.cross(x)
		basis = Basis(x, y, z)

	## @param o {craftPos: DVec3 (local frame, m), craftBasis: Basis,
	##   length, up: Vector3, dt, sunLocal: Vector3}
	func update(o: Dictionary) -> void:
		place(o)
		depth_range(o.craftPos, maxf(float(o.length), 3.0))

	func place(o: Dictionary) -> void:
		var craft_pos: DVec3 = o.craftPos
		var cq: Basis = o.craftBasis
		var up: Vector3 = o.up
		var L := maxf(float(o.length), 3.0)
		var dt := float(o.dt)
		if state.mode == "pad" and state.hasPad:
			pos.copy_from(state.padPos)
			# Aim at the middle of the stack, not at its base. craftPos is the
			# vehicle's ORIGIN, which is where the engine bells are — pointing
			# the camera there puts the whole vehicle above the centre line and
			# runs most of it off the top of the frame.
			look_at(craft_pos.clone().add_in(DVec3.from_v3(up * (L * 0.45))), up)
			return
		if state.mode == "cockpit":
			var u := cq * Vector3(0, 1, 0)
			pos.copy_from(craft_pos).add_in(DVec3.from_v3(u * (L * 0.52)))
			look_at(pos.clone().add_in(DVec3.from_v3(u * L)), up)
			return
		# chase / orbit share a turntable; chase keeps the vehicle's own up.
		var d: float = state.dist * L
		# Basis from the vehicle's own axis, so the camera rolls with it in chase
		# mode and stays world-locked in orbit mode.
		var uu: Vector3 = (cq * Vector3(0, 1, 0)) if state.mode == "chase" else up
		uu = uu.normalized()
		var ref := Vector3(1, 0, 0) if absf(uu.y) > 0.95 else Vector3(0, 1, 0)
		var right := uu.cross(ref).normalized()
		var fwd := right.cross(uu).normalized()
		# Until the viewer takes the turntable themselves, stand on the SUNLIT
		# side. A vehicle photographed from its own shadow is a silhouette, and a
		# silhouette of a white rocket against a bright sky is the one thing that
		# makes all this modelling invisible. Eased rather than snapped, because
		# the sun's bearing swings as the vehicle flies round the planet.
		var sun_l = o.get("sunLocal")
		if sun_l != null and not state.userAimed:
			var want := atan2((sun_l as Vector3).dot(fwd), (sun_l as Vector3).dot(right))
			var e: float = want - state.yaw
			e = atan2(sin(e), cos(e))      # shortest way round
			state.yaw += e * (1.0 - exp(-maxf(dt, 0.0) * 1.2))
		var cy2 := cos(state.yaw); var sy2 := sin(state.yaw)
		var cp2 := cos(state.pitch); var sp2 := sin(state.pitch)
		var off := right * (d * cp2 * cy2) + fwd * (d * cp2 * sy2) + uu * (d * sp2)
		pos.copy_from(craft_pos).add_in(DVec3.from_v3(off))
		look_at(craft_pos, uu)

static func create_flight_camera() -> FlightCamera:
	return FlightCamera.new()
