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
const ORDER := {"sky": -10, "smoke": 10, "flame": 20}

var pipe: RenderPipeline
var root: Node3D                 # everything in local space hangs under here
var camera: Camera3D             # pipe.local_cam — at the origin, rotation only
var sun: DirectionalLight3D
var hemi: Array = []             # the hemisphere's ±Y pair
var ground: MeshInstance3D
var sky: MeshInstance3D
var ground_mat: ShaderMaterial
var sky_mat: ShaderMaterial
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
	sun.shadow_enabled = false
	root.add_child(sun)
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
	sky_mat.set_shader_parameter("uHasAir", has_air)
	# Irradiance falls as 1/r² from the star; the local sun light and the
	# ground shader are driven from the same number so they cannot disagree.
	var flux := clampf(3.0 * float(U.nz(o.get("starFlux"), 1.0)), 0.05, 12.0)
	ground_mat.set_shader_parameter("uSunI", flux)
	ground_mat.set_shader_parameter("uTemp", maxf(float(env.get("teq", 255.0)), 30.0))
	sun.light_energy = flux / PI
	# Skylight only exists where there is air to scatter in.
	ground_mat.set_shader_parameter("uSkyI", 0.42 * exp(-h / maxf(sh * 2.0, 1.0)) if atm != null else 0.03)
	# Ground fades out entirely once the orrery's planet takes over.
	ground.visible = h < 4.0e5
	sky.visible = atm != null and h < (float(atm.top) * 1.6 if atm != null else 0.0)

	# Sun direction expressed in the local frame: its component along the local
	# up is what decides day, night and the colour of both.
	var up: DVec3 = DQuat.nrm((o.upWorld as DVec3).clone())
	var east := DQuat.nrm(DVec3.new().cross_vectors(up, o.northWorld))
	var north := DQuat.nrm(DVec3.new().cross_vectors(east, up))
	ground_mat.set_shader_parameter("uGeoReady", 0.0)
	var pad = o.get("padWorld")
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
	ground_mat.set_shader_parameter("uSunDir", sun_l)
	sky_mat.set_shader_parameter("uSunDir", sun_l)
	# A DirectionalLight3D shines along its own −Z; three's shines from its
	# position toward its target (the origin).
	if sun_l.length_squared() > 0.0:
		var ref := Vector3(0, 0, 1) if absf(sun_l.y) > 0.99 else Vector3.UP
		sun.basis = Basis.looking_at(-sun_l, ref)
	# Planetshine: strong in low orbit over a bright planet, gone in deep space.
	_set_ambient(clampf(0.75 * (1.0 - h / 8e5), 0.04, 0.75))
	return {"east": east, "north": north, "up": up.clone(), "sun_local": sun_l}

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
