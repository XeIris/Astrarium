extends Harness
# ============================================================================
# ISOLATED SKY VIEWER — the port of .claude/skytest.html. Not part of the sim:
# it renders the sky (shaders/sky/sky.gdshaderinc via the pipeline's
# background shaders) on its own, through the full post chain, with a camera
# you can aim exactly, so the background can be judged without a scene, a mesh
# or a black hole in front of it. Hunting for the galactic band inside a live
# preset wastes a lot of time; here it is always in the same place.
#
#   keys   1-7 band   e environment   arrows aim   z/x zoom   (as skytest.html)
#
#   Godot --path godot res://tools/skytest.tscn -- out=/abs/x.png \
#         band=3 env=disc yaw=0 pitch=0 fov=50 tilt=0 roll=0 w=1280 h=720
#
# yaw/pitch are RADIANS (skytest.html's aim(y, p)), fov is degrees, and the
# galactic frame is skytest.html's { tilt: 0, roll: 0 } unless tilt/roll are
# given. `env` takes a name or a comma list (blended at weight 1 each).
#
# SURFACE MODE (`surface=/abs/state.json`): the atmosphere composite of
# sim/skyview.gd over this sky, driven by a SurfaceObserver standing on a
# stand-in home world. The JSON is a web-build state dump (see
# godot/tools/ref/sky/README.md for the webref shot that writes it): the home
# world's scene position, radius, spin phase and group quaternion, the suns'
# scene positions/colours/intensities/angular radii, the observer's
# latitude/azimuth/elevation/fov, the eye-adaptation exposure, the climate
# numbers and the sky spec. The stand-in is a Body with that scene_pos and a
# Node3D "group" carrying that quaternion — exactly what SurfaceObserver reads
# — and nothing is drawn for the world itself (the web build hides it too).
# The observer's frame is then compared against the web's own (printed).
# ============================================================================

var yaw := 0.0
var pitch := 0.0
var band := 3
var fov := 50.0
var env_keys: Array = SkyModel.SKY_ENVIRONMENTS.keys()
var env_i := 0
var env_override = null
var tilt := 0.0
var roll := 0.0
var hud: Label

# surface mode
var surface := false
var state_dump := {}
var observer: SkyView.SurfaceObserver
var sky_pass: SkyView.SkyPass
var home: Body
var home_viz: _StandIn
var suns: Array = []
var sky_spec := {}

## The stand-in home world's visual: exactly the fields SurfaceObserver reads.
class _StandIn extends RefCounted:
	var group := Node3D.new()
	var R := 1.0

func _setup() -> void:
	SkyModel.init_sky_materials(pipe.sky_materials)
	yaw = float(args.get("yaw", "0"))
	pitch = float(args.get("pitch", "0"))
	fov = float(args.get("fov", "50"))
	band = int(args.get("band", "3"))
	tilt = float(args.get("tilt", "0"))
	roll = float(args.get("roll", "0"))
	if args.has("env"):
		var names: PackedStringArray = str(args.env).split(",")
		if names.size() == 1 and env_keys.has(names[0]):
			env_i = env_keys.find(names[0])
		else:
			env_override = Array(names)
	if args.has("surface"):
		_setup_surface(str(args.surface))
	if not args.has("out"):
		var layer := CanvasLayer.new()
		layer.layer = 10
		add_child(layer)
		hud = Label.new()
		hud.position = Vector2(8, 8)
		hud.add_theme_color_override("font_color", Color.hex(0x88aaffff))
		hud.add_theme_font_size_override("font_size", 11)
		layer.add_child(hud)
	apply()

func apply() -> void:
	if surface:
		SkyModel.apply_sky_environment(pipe.sky_materials, sky_spec)
	else:
		var env = env_override if env_override != null else env_keys[env_i]
		SkyModel.apply_sky_environment(pipe.sky_materials, {"env": env, "tilt": tilt, "roll": roll})
	SkyModel.apply_sky_band(pipe.sky_materials, band)
	pipe.set_band(band)
	if hud:
		var envs := str(env_override) if env_override != null else str(env_keys[env_i])
		hud.text = "env %s   band %s   yaw %d  pitch %d  fov %d\n[1-7] band   [e] env   [arrows] aim   [z/x] zoom" % [
			envs, Spectrum.BANDS[band].short, int(round(yaw * 57.3)), int(round(pitch * 57.3)), int(round(fov))]

# skytest.html: camera.rotation.set(0,0,0,'YXZ'); rotateY(yaw); rotateX(pitch)
# — a yaw about world Y, then a pitch about the camera's own X.
func update_camera() -> void:
	if surface:
		observer.update(home, pipe.scene_cam)
		cam_pos.copy_from(observer.eye)
		return
	cam_pos.set_v(0, 0, 0)
	pipe.scene_cam.fov = fov
	pipe.scene_cam.transform = Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch), Vector3.ZERO)

func _step(step_dt: float) -> void:
	# The sky's footprint reference tracks the CURRENT fov, every frame.
	SkyModel.update_pix_angle(pipe.sky_materials, deg_to_rad(pipe.scene_cam.fov), float(pipe.render_size.y))
	if surface:
		var aspect := float(pipe.render_size.x) / float(pipe.render_size.y)
		sky_pass.update_frame(observer, pipe.scene_cam, suns, state_dump.get("climate"), step_dt, aspect)
		if state_dump.has("uTime"):
			# pin the cloud clock to the web frame's, for a like-for-like shot
			sky_pass.u.uTime = float(state_dump.uTime)
		if state_dump.has("exposure") and args.has("out"):
			sky_pass.exposure = float(state_dump.exposure)
			sky_pass.u.uExposure = sky_pass.exposure
		sky_pass.commit()
		if frame == 2:
			_report_frame()

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed):
		return
	var k: int = e.keycode
	if k >= KEY_1 and k <= KEY_7:
		band = k - KEY_1
	elif k == KEY_E:
		env_override = null
		env_i = (env_i + 1) % env_keys.size()
	elif k == KEY_LEFT:
		if surface: observer.look(-0.12, 0.0)
		else: yaw -= 0.12
	elif k == KEY_RIGHT:
		if surface: observer.look(0.12, 0.0)
		else: yaw += 0.12
	elif k == KEY_UP:
		if surface: observer.look(0.0, 0.1)
		else: pitch = minf(1.5, pitch + 0.1)
	elif k == KEY_DOWN:
		if surface: observer.look(0.0, -0.1)
		else: pitch = maxf(-1.5, pitch - 0.1)
	elif k == KEY_Z:
		if surface: observer.zoom(1.0 / 1.4)
		else: fov = maxf(2.0, fov / 1.4)
	elif k == KEY_X:
		if surface: observer.zoom(1.4)
		else: fov = minf(90.0, fov * 1.4)
	else:
		return
	apply()

# ---------------------------------------------------------------------------
# surface mode
# ---------------------------------------------------------------------------
func _setup_surface(path: String) -> void:
	var txt := FileAccess.get_file_as_string(path)
	var d = JSON.parse_string(txt)
	if not (d is Dictionary):
		push_error("skytest: cannot read surface state " + path)
		return
	state_dump = d
	surface = true
	sky_spec = d.get("sky", {})
	band = int(args.get("band", str(d.get("band", 3))))

	home = Body.new()
	home.name = "home"
	home.scene_pos = DVec3.from_array(d.home.scenePos)
	home.spin_phase = float(d.home.spinPhase)
	home_viz = _StandIn.new()
	home_viz.R = float(d.home.R)
	var q: Array = d.home.quat   # THREE quaternion x, y, z, w
	home_viz.group.quaternion = Quaternion(q[0], q[1], q[2], q[3])
	pipe.world_root.add_child(home_viz.group)
	home.viz = home_viz

	for s in d.suns:
		var b := Body.new()
		b.name = s.name
		b.scene_pos = DVec3.from_array(s.posScene)
		var c: Array = s.color
		suns.append({"body": b, "color": Color(c[0], c[1], c[2]), "intensity": float(s.intensity),
			"ang_radius": float(s.angRadius)})

	observer = SkyView.SurfaceObserver.new()
	var o: Dictionary = d.observer
	observer.latitude = float(o.latitude)
	observer.azimuth = float(o.azimuth)
	observer.elevation = float(o.elevation)
	observer.fov = float(o.fov)
	sky_pass = SkyView.create_sky_pass()
	sky_pass.exposure = float(d.get("exposure", 1.0))
	pipe.surface_pass = sky_pass

## Print the observer frame next to the web build's, and the sky-pass uniforms.
func _report_frame() -> void:
	var o: Dictionary = state_dump.observer
	var up_w := Vector3(o.up[0], o.up[1], o.up[2])
	var north_w := Vector3(o.north[0], o.north[1], o.north[2])
	var eye_w := DVec3.from_array(o.eye)
	var fwd_g := -pipe.scene_cam.transform.basis.z
	var fwd_w := Vector3(o.forward[0], o.forward[1], o.forward[2])
	print("surface: |up-web| %.2e  |north-web| %.2e  |eye-web| %.2e  |fwd-web| %.2e" % [
		(observer.up - up_w).length(), (observer.north - north_w).length(),
		observer.eye.distance_to(eye_w), (fwd_g - fwd_w).length()])
	print("surface: sun dirs ", sky_pass.u.uSunDir, " int ", sky_pass.u.uSunInt, " exposure ", sky_pass.u.uExposure)
