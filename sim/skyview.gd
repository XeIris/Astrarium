class_name SkyView
extends RefCounted

# SURFACE VIEW: standing on the planet looking up, as a full-screen composite pass
# (no depth or draw-order fights across the sky's dynamic range). Single-scattering
# Rayleigh + Mie, per sun, summed:
#   L(v) = Σ_i I_i · T(m_sun,i) · (β_s·P(θ_i)/β_e) · (1 − exp(−β_e·m_view))
#   β_R ∝ 1/λ⁴   blue sky, red low sun
#   P_M          Henyey–Greenstein, g = 0.76: the aureole round each sun
#   m            Kasten–Young air mass, so each sun reddens on its own schedule
# So one sun can set red while another burns white overhead.
#
# The kernel is shaders/sky/surface.glsl; SkyPass is `pipe.surface_pass`, run on the
# render thread by PostFX.render_rt between compose and the band remap, with the
# composed HDR buffer as tScene. The orchestrator writes `SkyPass.u` on the main
# thread and calls commit() (or update_frame(), which commits), packing the std140
# block.

const MAX_SUNS := Suns.MAX_SUNS

## Create the surface-view composite.
static func create_sky_pass() -> SkyPass:
	return SkyPass.new()

# THE SKY PASS
class SkyPass extends RefCounted:
	## The pass uniforms by name, with defaults (tScene comes via dispatch()). uCamMat is
	## the camera's world Basis (a direction transform); uCamPos is unused.
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
	## Surface-view eye adaptation (starts at 1, kept across visits to the surface).
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

	## The surface view's per-frame block: sun directions from the eye, eye adaptation,
	## observer frame, camera, clock and climate, then commit().
	##   observer  SkyView.SurfaceObserver, already update()d this frame
	##   camera    the orrery camera it placed (pipe.scene_cam)
	##   suns      the frame's VisualCtx.Sun list, brightest first (`pos_rel` is
	##             used only when `body` is null)
	##   climate   the home world's Climate (object or Dictionary) or null
	##   dt        wall-clock step, s
	##   aspect    render width / height
	func update_frame(observer, camera: Camera3D, suns: Array, climate, dt: float, aspect: float) -> void:
		var n := mini(suns.size(), MAX_SUNS)
		var illum := 0.0
		var dirs: Array = u.uSunDir
		var ints: PackedFloat32Array = u.uSunInt
		var angs: PackedFloat32Array = u.uSunAng
		for i in n:
			var s: VisualCtx.Sun = suns[i]
			var d: Vector3
			if s.body != null:
				# s.posScene − observer.eye, subtracted in double precision
				d = s.body.scene_pos.sub(observer.eye).normalized().to_v3()
			else:
				d = s.pos_rel.normalized()
			dirs[i] = d
			u.uSunColor[i] = s.color
			ints[i] = s.intensity
			angs[i] = s.ang_radius
			# horizontal illuminance from this sun: flux × cos(zenith angle)
			illum += s.intensity * maxf(d.dot(observer.up), 0.0)
		u.uSunInt = ints
		u.uSunAng = angs
		u.uSunCount = n

		# Eye adaptation: target exposure falls as the ground brightens, eased, so a sunrise
		# dazzles and settles. No daylight floor: close or multiple suns can exceed Earth's
		# irradiance by orders of magnitude.
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

	func release() -> void:
		var k := _kernel; var ubo := _ubo; var smp := _sampler
		RenderingServer.call_on_render_thread(func():
			RDU.free_rid(ubo); RDU.free_rid(smp)
			if k: k.release())

# SURFACE OBSERVER: the camera on the surface at a latitude, riding the planet's
# rotation, so suns rise because the ground turns. Under the floating origin it sets
# only orientation, fov and near, and publishes `eye` (absolute scene position, in
# double) as the frame's cam_pos. The body's tilt comes from its visual's `group`,
# its spin from `spin_phase` (applied here), its radius from `viz.R` (else
# b.radius_scene), its position from b.scene_pos.
class SurfaceObserver extends RefCounted:
	## The surface view's near plane, applied on every update.
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

	## The planet's orientation (rotation only; the node may also carry scale).
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

	func look(dx: float, dy: float) -> void:
		azimuth += dx
		elevation = clampf(elevation + dy, -1.35, 1.45)

	func zoom(f: float) -> void:
		fov = clampf(fov * f, 12.0, 100.0)
