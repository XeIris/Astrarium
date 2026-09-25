class_name SkyView
extends RefCounted

# ============================================================================
# SURFACE VIEW — standing on the planet, looking up.
# ----------------------------------------------------------------------------
# Rendered as a full-screen composite pass (same structure as the lensing pass)
# rather than as dome geometry, so there are no depth-precision or draw-order
# fights between a sky that spans 5 orders of magnitude and stars 30 AU away.
#
# The sky is single-scattering Rayleigh + Mie, evaluated INDEPENDENTLY FOR
# EVERY SUN and summed:
#
#   L(v) = Σ_i  I_i · T(m_sun,i) · (β_s·P(θ_i)/β_e) · (1 − exp(−β_e·m_view))
#
#   β_R ∝ 1/λ⁴  → the sky is blue, and a low sun is red because its light has
#                 crossed a long air mass and lost the blue end.
#   P_M          Henyey–Greenstein, g = 0.76 → the bright aureole hugging each sun.
#   m            Kasten–Young air mass, so the reddening is driven by real
#                 geometry: each sun reddens on its own schedule as it sets.
#
# Because the terms are per-sun, a Trisolaran sky does what the books describe:
# one sun can be setting red on one horizon while another burns white overhead,
# the shadows cross, and the sky colour is the sum of all of them.
#
# IN GODOT. The web build's createSkyPass() was a ShaderMaterial on a quad that
# read `tScene` and wrote postfx's HDR target. Here the fragment shader is the
# compute kernel shaders/sky/surface.glsl, and SkyPass (below) is the object
# render/pipeline.gd calls as `pipe.surface_pass`: PostFX.render_rt runs it ON
# THE RENDER THREAD between compose and the band remap, with the composed HDR
# buffer (scene colour + temperature alpha) as tScene. Its uniforms are the
# web build's set, by name, in `SkyPass.u`; the orchestrator writes them on the
# main thread and calls commit(), which packs them into the std140 block the
# kernel reads (or calls update_frame(), which is the web render loop's whole
# surface-view block and commits at the end).
# ============================================================================

const MAX_SUNS := Suns.MAX_SUNS

## Create the surface-view composite (the web build's createSkyPass()).
static func create_sky_pass() -> SkyPass:
	return SkyPass.new()

# ============================================================================
# THE SKY PASS
# ============================================================================
class SkyPass extends RefCounted:
	## The web build's `skyPass.material.uniforms`, by name, with its defaults.
	## tScene is not here: the pipeline hands the source buffer to dispatch().
	## uCamMat is the camera's world Basis (the web's matrixWorld — only its
	## rotation was ever used, as a direction transform). uCamPos is carried for
	## parity; the shader never read it, in either build.
	var u := {
		"uCamPos": Vector3.ZERO,
		"uCamMat": Basis(),
		"uFov": 1.0, "uAspect": 1.0,
		"uUp": Vector3(0, 1, 0),
		"uNorth": Vector3(1, 0, 0),
		"uSunDir": [Vector3(0, 1, 0), Vector3(0, 1, 0), Vector3(0, 1, 0), Vector3(0, 1, 0)],
		"uSunColor": [Color(1, 1, 1), Color(1, 1, 1), Color(1, 1, 1), Color(1, 1, 1)],
		"uSunInt": PackedFloat32Array([0.0, 0.0, 0.0, 0.0]),
		"uSunAng": PackedFloat32Array([0.0, 0.0, 0.0, 0.0]),
		"uSunCount": 0,
		"uIce": 0.0, "uScorch": 0.0,
		"uClouds": 0.4, "uHumidity": 0.4, "uStorm": 0.2,
		"uTime": 0.0, "uNight": 0.0, "uExposure": 1.0,
	}
	## Surface-view eye adaptation — the web build's `state.exposure` (initially
	## 1, and kept across visits to the surface, as the web kept it on state).
	var exposure := 1.0

	const UBO_FLOATS := 4 * (2 * 4 + 8)
	var _bytes := PackedByteArray()
	var _kernel: RDU.Kernel
	var _ubo := RID()
	var _sampler := RID()

	func _init() -> void:
		commit()
		RenderingServer.call_on_render_thread(_init_rt)

	func _init_rt() -> void:
		_kernel = RDU.Kernel.new("res://shaders/sky/surface.glsl")
		_sampler = RDU.linear_sampler()
		var zero := PackedFloat32Array(); zero.resize(UBO_FLOATS)
		_ubo = RDU.rd().uniform_buffer_create(UBO_FLOATS * 4, zero.to_byte_array())

	## Pack `u` into the kernel's std140 block (MAIN THREAD). Call after writing
	## `u` each frame; update_frame() does it for you.
	func commit() -> void:
		var f := PackedFloat32Array(); f.resize(UBO_FLOATS)
		var dirs: Array = u.uSunDir
		var cols: Array = u.uSunColor
		var ints: PackedFloat32Array = u.uSunInt
		var angs: PackedFloat32Array = u.uSunAng
		for i in MAX_SUNS:
			var d: Vector3 = dirs[i]
			var c: Color = cols[i]
			f[i * 4 + 0] = d.x; f[i * 4 + 1] = d.y; f[i * 4 + 2] = d.z; f[i * 4 + 3] = angs[i]
			var o := 16 + i * 4
			f[o + 0] = c.r; f[o + 1] = c.g; f[o + 2] = c.b; f[o + 3] = ints[i]
		var up: Vector3 = u.uUp
		var north: Vector3 = u.uNorth
		var b: Basis = u.uCamMat
		var cp: Vector3 = u.uCamPos
		var vals := [
			up.x, up.y, up.z, float(u.uSunCount),
			north.x, north.y, north.z, float(u.uFov),
			b.x.x, b.x.y, b.x.z, float(u.uAspect),
			b.y.x, b.y.y, b.y.z, float(u.uTime),
			b.z.x, b.z.y, b.z.z, float(u.uExposure),
			cp.x, cp.y, cp.z, float(u.uNight),
			float(u.uIce), float(u.uScorch), float(u.uClouds), float(u.uHumidity),
			float(u.uStorm), 0.0, 0.0, 0.0,
		]
		for k in vals.size():
			f[32 + k] = vals[k]
		_bytes = f.to_byte_array()

	## The web render loop's surface-view block, verbatim in effect: sun
	## directions from the observer's eye, the eye adaptation, the observer
	## frame, the camera, the clock and the climate — then commit().
	##
	##   observer  SkyView.SurfaceObserver, already update()d this frame
	##   camera    the orrery camera it placed (pipe.scene_cam)
	##   suns      the frame's sun list (PORT_GUIDE.md ctx.suns), brightest
	##             first: {body: Body, color: Color (linear), intensity: float,
	##             ang_radius: float}; `pos_rel` is used only if `body` is absent
	##   climate   the home world's Climate (object or Dictionary) or null
	##   dt        the frame's wall-clock step, seconds
	##   aspect    render width / height
	func update_frame(observer, camera: Camera3D, suns: Array, climate, dt: float, aspect: float) -> void:
		var n := mini(suns.size(), MAX_SUNS)
		var illum := 0.0
		var dirs: Array = u.uSunDir
		var ints: PackedFloat32Array = u.uSunInt
		var angs: PackedFloat32Array = u.uSunAng
		for i in n:
			var s: Dictionary = suns[i]
			var d: Vector3
			if s.get("body") != null:
				# s.posScene − observer.eye, subtracted in double precision
				d = (s.body.scene_pos as DVec3).sub(observer.eye).normalized().to_v3()
			else:
				d = (s.pos_rel as Vector3).normalized()
			dirs[i] = d
			u.uSunColor[i] = s.color
			ints[i] = float(s.intensity)
			angs[i] = float(s.get("ang_radius", 0.0))
			# horizontal illuminance from this sun: flux × cos(zenith angle)
			illum += float(s.intensity) * maxf(d.dot(observer.up), 0.0)
		u.uSunInt = ints
		u.uSunAng = angs
		u.uSunCount = n

		# Eye adaptation. Without it the view is either a black night or a white
		# day: three suns of different luminosity crossing the sky span a huge
		# dynamic range. Target exposure falls as the ground gets brighter, and the
		# eye takes a moment to follow — so a sunrise dazzles briefly, then settles.
		# No daylight floor: close/multiple suns can exceed Earth's irradiance by
		# orders of magnitude. A fixed minimum would wash those skies out again.
		var target := minf(0.32 / (0.12 + illum), 1.9)
		var adapt := 1.0 - exp(-dt / 1.6)              # ~1.6 s time constant
		exposure += (target - exposure) * adapt
		u.uExposure = exposure
		u.uUp = observer.up
		u.uNorth = observer.north
		u.uCamPos = (observer.eye as DVec3).to_v3()
		u.uCamMat = camera.global_transform.basis if camera.is_inside_tree() else camera.transform.basis
		u.uFov = deg_to_rad(camera.fov)
		u.uAspect = aspect
		u.uTime = float(u.uTime) + dt
		if climate != null:
			u.uIce = float(_cget(climate, "ice", 0.0))
			u.uScorch = clampf((float(_cget(climate, "T", 288.0)) - 320.0) / 120.0, 0.0, 1.0)
			u.uClouds = float(_cget(climate, "clouds", 0.4))
			u.uHumidity = float(_cget(climate, "humidity", 0.4))
			u.uStorm = float(U.nz(_cget(climate, "storm", null), 0.2))
		commit()

	static func _cget(o, key: String, d):
		if o is Dictionary:
			return o.get(key, d)
		if o is Object:
			var v = o.get(key)
			return d if v == null else v
		return d

	## RENDER THREAD (PostFX.render_rt). Composite the atmosphere over `src`
	## (the composed HDR buffer) into `dst`, both w×h RGBA16F.
	func dispatch(src: RID, dst: RID, w: int, h: int) -> void:
		if _kernel == null or not _kernel.valid():
			return
		var bytes := _bytes
		RDU.rd().buffer_update(_ubo, 0, bytes.size(), bytes)
		RDU.dispatch(_kernel, [RDU.u_sampled(0, _sampler, src), RDU.u_image(1, dst), RDU.u_ubo(2, _ubo)], w, h)

	func free() -> void:
		var k := _kernel; var ubo := _ubo; var smp := _sampler
		RenderingServer.call_on_render_thread(func():
			RDU.free_rid(ubo); RDU.free_rid(smp)
			if k: k.free())

# ============================================================================
# SURFACE OBSERVER
# ----------------------------------------------------------------------------
# Places the camera on the planet's surface at a chosen latitude and rides the
# planet's rotation, so the suns rise and set because the ground is turning —
# not because anything is animating them.
#
# IN GODOT, under the floating origin. The camera sits at the origin, so this
# sets only the camera's ORIENTATION (plus fov and near) and publishes `eye`,
# the absolute scene position, in double precision: the orchestrator uses it as
# the frame's cam_pos and places every node relative to it. The home body's
# orientation comes from its visual's `group` (the node carrying the axial
# tilt, as the web build's viz.group did — the spin is NOT on it; it is
# `spin_phase`, applied here), its radius from `viz.R` (falling back to
# b.radius_scene), and its position from b.scene_pos.
# ============================================================================
class SurfaceObserver extends RefCounted:
	## The near plane the web build set on entering the surface view
	## (setCamMode('surface')), applied here on every update.
	const NEAR := 0.002

	var latitude := 0.38     # radians
	var azimuth := 0.0       # where the observer is looking
	var elevation := 0.25
	var fov := 62.0          # degrees, vertical
	var up := Vector3(0, 1, 0)
	var north := Vector3(1, 0, 0)
	## Absolute scene position of the eye (the frame's cam_pos).
	var eye := DVec3.new()
	## The look direction this update produced (world space).
	var look_dir := Vector3(0, 0, -1)

	## The planet's orientation as a quaternion: the web build's
	## g.getWorldQuaternion(). Rotation only — the orchestrator may put a scale
	## (oblateness, size ease) on the same node.
	static func home_quat(planet: Body) -> Quaternion:
		var g = planet.viz.group if planet.viz != null else null
		if g == null:
			return Quaternion()
		var b: Basis = (g as Node3D).global_basis if (g as Node3D).is_inside_tree() else (g as Node3D).basis
		return b.get_rotation_quaternion()

	## Recompute the observer frame from the planet's orientation and spin phase,
	## and aim `camera` (rotation, fov, near). The camera stays at the origin.
	func update(planet: Body, camera: Camera3D) -> void:
		var R: float = planet.radius_scene
		if planet.viz != null:
			var vr = planet.viz.get("R")
			if vr != null:
				R = float(vr)
		var phase := planet.spin_phase
		var q := home_quat(planet)

		# local vertical in the planet's own (untilted) frame
		var cl := cos(latitude); var sl := sin(latitude)
		up = Vector3(cl * cos(phase), sl, cl * sin(phase))
		# carry the axial tilt: the group holds the obliquity rotation
		up = q * up

		# north = component of the spin axis perpendicular to the local vertical
		var axis := q * Vector3(0, 1, 0)
		north = axis - up * axis.dot(up)
		if north.length_squared() < 1e-8:
			north = Vector3(1, 0, 0)
		north = north.normalized()

		# eye sits a hair above the surface (in double precision: the planet may
		# be tens of scene units out, and a 1e-5 radius has to survive the sum)
		eye = planet.scene_pos.add(DVec3.from_v3(up).scaled(R * 1.004))

		# build the look direction from azimuth (about the local vertical) and elevation
		var east := up.cross(north).normalized()
		var lk := north * cos(azimuth) + east * sin(azimuth)
		lk = (lk * cos(elevation) + up * sin(elevation)).normalized()
		look_dir = lk

		# camera.up = up; camera.lookAt(eye + look): Basis.looking_at builds the
		# same frame THREE's lookAt did (z = −look, x = up × z, y = z × x).
		camera.transform = Transform3D(Basis.looking_at(lk, up), Vector3.ZERO)
		camera.fov = fov
		camera.near = NEAR
		# (The web build had to call camera.updateMatrixWorld(true) here so the
		# sky pass would not build its rays from last frame's orientation. A
		# Godot transform is current the moment it is assigned.)

	func look(dx: float, dy: float) -> void:
		azimuth += dx
		elevation = clampf(elevation + dy, -1.35, 1.45)

	func zoom(f: float) -> void:
		fov = clampf(fov * f, 12.0, 100.0)
