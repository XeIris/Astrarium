class_name GalaxyScene
extends RefCounted

# The galactic scene: a mode of its own, entered from the scenario list's Galaxies
# group. Its world is galaxy-local kpc (scene units = kpc, the galaxy's centre at
# the origin), its clock is Myr, and it has no bodies: the orrery's state is cleared
# on the way in and nothing of this scene survives the way out. It borrows the
# stage's orbit camera within its own distance interval. docs/physics/galaxies.md.

## The camera's interval here, kpc: a few hundred AU to the Local Group.
const MIN_RADIUS := 1e-3
const MAX_RADIUS := 2000.0
## Leapfrog steps per frame at most; past it the clock runs slower than asked, and
## the HUD says so.
const STEP_BUDGET := 6
const RATES := [0.0, 0.1, 1.0, 5.0, 20.0]

var stage
var active := false
var key := ""
var preset: Dictionary = {}
var model: Dictionary = {}
var visual: GalaxyVisual = null
var tracers: GalTracers = null
var t_myr := 0.0
var rate := 5.0
## Accepted Myr per wall second over the last frames, for the readout.
var achieved := 0.0
var limited := false
var _pending := 0.0
var _task := -1
var _built: GalTracers = null
var _arm_task := -1
var _arms_baked := {}
var _mutex := Mutex.new()
var _hud_acc := 0.0
var _adapted := false
var curve_chart = null      # GalCurveChart, owned by the HUD
## The "sun" framing keeps the camera's target on the Sun as it orbits, exactly.
var follow_sun := false
## The model's landmarks (GalLandmarks), their labels on screen behind the HUD, and the
## one last flown to.
var landmarks: Array = []
## The Milky Way's neighbours (GalModels.LOCAL_GROUP), each {key, visual, centre (DVec3),
## basis, extent}, drawn at the main visual's exposure; `hide` leaves one's glow out (checks).
var neighbours: Array = []
var landmark := ""
var _lm_layer: Control = null
var _lm_labels := {}
var _nb_baked := {}

func _init(main) -> void:
	stage = main

static func has_preset(k: String) -> bool:
	return GalModels.PRESETS.has(k)

func enter(k: String) -> void:
	if active: leave()
	active = true
	key = k
	preset = GalModels.PRESETS[k]
	model = GalModels.build(String(preset.model), int(stage._cmd.get("seed", 1)))
	t_myr = 0.0
	_adapted = false
	rate = float(preset.get("rateMyrS", 5.0))
	_pending = 0.0
	visual = GalaxyVisual.new(model, true)
	stage.pipe.world_root.add_child(visual.group)
	# The arms' map bakes on a worker too; they light up when it is done.
	_arms_baked = {}
	var v := visual
	# The real stars around the Sun load and bake their light map on the same worker.
	_nb_baked = {}
	_arm_task = WorkerThreadPool.add_task(func():
		var b := v.bake_arms()
		var nb := GalNeighbourhood.bake() if v.has_sun else {}
		_mutex.lock()
		_arms_baked = b
		_nb_baked = nb
		_mutex.unlock(), false, "galaxy arms")
	# Built off the main thread: drawing the Shu distribution takes about a second, and
	# a model with a bar and arms then runs from its tStart, while they grow, to today.
	_built = null
	var m := model
	_task = WorkerThreadPool.add_task(func():
		var t := GalTracers.new(m)
		t.step(int(round(-t.t / GalTracers.DT)))
		_mutex.lock()
		_built = t
		_mutex.unlock(), false, "galaxy tracers")
	_build_neighbours()
	frame("whole")
	_build_landmarks()
	sync_hud()

## Block until the tracers exist (checks, screenshots).
func wait_tracers() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_adopt()
	if _arm_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_arm_task)
		_arm_task = -1
	_adopt_arms()

func _adopt_arms() -> void:
	_mutex.lock()
	var b := _arms_baked
	var nb := _nb_baked
	_arms_baked = {}
	_nb_baked = {}
	_mutex.unlock()
	if not b.is_empty() and visual != null: visual.apply_arms(b)
	if not nb.is_empty() and visual != null: visual.apply_neighbourhood(nb)

func _adopt() -> void:
	_mutex.lock()
	var t := _built
	_built = null
	_mutex.unlock()
	if t == null: return
	tracers = t
	# The clock ran while they were drawn; they catch up rather than the clock going back.
	var k := int(floor((t_myr - tracers.t) / GalTracers.DT))
	if k > 0: tracers.step(k)
	_pending = maxf(t_myr - tracers.t, 0.0)
	if visual != null: visual.set_tracers(tracers)

func leave() -> void:
	if not active: return
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _arm_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_arm_task)
		_arm_task = -1
	_built = null
	_arms_baked = {}
	_nb_baked = {}
	follow_sun = false
	_clear_landmarks()
	for nb in neighbours: nb.visual.dispose()
	neighbours = []
	active = false
	if visual != null: visual.dispose()
	visual = null
	tracers = null
	model = {}
	preset = {}
	key = ""

## One frame of the scene's physics: the tracers advance by rate × dt within the
## step budget. Returns the Myr accepted. Runs before the camera, so a followed Sun
## is where the camera looks this frame.
func step(dt: float) -> float:
	if not active: return 0.0
	var accepted := _advance(dt)
	_track_sun()
	_track_landmark(dt)
	return accepted

func _track_sun() -> void:
	if not follow_sun or visual == null or not visual.has_sun: return
	var p: Vector3 = GalNeighbourhood.sun_frame(visual.sun_r0, visual.sun_omega, t_myr)[0]
	stage.cam.target.set_v(p.x, p.y, p.z)

## The landmark last flown to, where it is now (it may turn with the bar or the arms).
func _track_landmark(dt: float) -> void:
	if follow_sun or landmark == "": return
	var lm := GalLandmarks.find(String(model.get("key", "")), landmark)
	if lm.is_empty() or lm.at == "sun": return
	stage.cam.track_point(DVec3.from_v3(GalLandmarks.position(lm, model, t_myr)), dt)

func _advance(dt: float) -> float:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_adopt()
	if _arm_task >= 0 and WorkerThreadPool.is_task_completed(_arm_task):
		WorkerThreadPool.wait_for_task_completion(_arm_task)
		_arm_task = -1
		_adopt_arms()
	if stage.state.paused or rate <= 0.0:
		achieved = 0.0
		limited = false
		return 0.0
	var want := rate * dt
	_pending += want
	var k := int(floor(_pending / GalTracers.DT))
	limited = k > STEP_BUDGET
	k = mini(k, STEP_BUDGET)
	var accepted := 0.0
	if tracers != null:
		tracers.step(k)
		_pending -= float(k) * GalTracers.DT
		# A clock held back by the budget drops what it could not do.
		if limited: _pending = 0.0
		accepted = float(k) * GalTracers.DT
		t_myr = tracers.t + _pending
	elif model.has("populations"):
		# The tracers are still being built: the clock waits for them rather than run ahead
		# and jump back when they arrive.
		_pending = 0.0
	else:
		t_myr += want
		_pending = 0.0
		accepted = want
	achieved = lerpf(achieved, accepted / maxf(dt, 1e-6), 0.1)
	return accepted

## Per frame, after the camera: place and update the drawing.
func update(dt: float) -> void:
	if not active or visual == null: return
	var cam_pos: DVec3 = stage.cam_pos
	visual.group.position = DVec3.new().rel_v3(cam_pos)
	visual.group.basis = Basis()
	var ahead := t_myr - tracers.t if tracers != null else 0.0
	# The eye adapts to the brightest of the view's centre and the galaxy's own centre.
	var fwd: Vector3 = -(stage.cam_basis as Basis).z
	var to_centre := DVec3.new().rel_v3(cam_pos)
	var rays := [fwd.normalized()]
	if to_centre.length() > 1e-6 and fwd.angle_to(to_centre) < deg_to_rad(stage.cam_fov) * 0.6:
		rays.append(to_centre.normalized())
	visual.adapt(rays, cam_pos.to_v3(), SkyModel.star_gain(), dt if _adapted else 0.0)
	_adapted = true
	visual.update(cam_pos, t_myr, tracers, ahead, deg_to_rad(stage.cam_fov), float(stage.pipe.render_size.y), SkyModel.star_gain(), stage.cam.radius)
	_update_neighbours(cam_pos)
	if _objects_mat != null:
		_objects.visible = visual.show_stars and visual.show_catalogue
		_objects_mat.set_shader_parameter("uSunRel", DVec3.new().rel_v3(cam_pos))
		_objects_mat.set_shader_parameter("uFarW", 1.0)
		_objects_mat.set_shader_parameter("uGain", visual.last_gain)
		_objects_mat.set_shader_parameter("uPixSr", visual.last_pix_sr)
	_place_labels(cam_pos)
	_hud_acc += dt
	if _hud_acc >= 0.25:
		_hud_acc = 0.0
		sync_hud()

## Camera framings: "whole", "face", "edge", "sun", "centre".
func frame(kind: String) -> void:
	var cam = stage.cam
	var r0: float = model.get("r0", 8.0)
	_adapted = false
	stage.state.follow_id = null
	cam.offset.set_v(0, 0, 0)
	follow_sun = kind == "sun" and visual != null and visual.has_sun
	landmark = ""
	match kind:
		"whole":
			cam.target.set_v(0, 0, 0)
			cam.theta = float(preset.get("camTheta", 0.95))
			cam.phi = PI / 2.0
			stage.jump_cam_radius(float(preset.get("camRadius", 60.0)))
		"face":
			cam.target.set_v(0, 0, 0)
			cam.theta = 0.03
			stage.jump_cam_radius(float(preset.get("camRadius", 60.0)))
		"edge":
			cam.target.set_v(0, 0, 0)
			cam.theta = PI / 2.0 - 0.02
			stage.jump_cam_radius(float(preset.get("camRadius", 60.0)))
		"sun":
			# From the Sun itself, toward the centre, the camera on the Sun as it orbits
			# (Bennett & Bovy 2019: 20.8 pc above the plane).
			cam.target.set_v(-r0, GalNeighbourhood.SUN_HEIGHT, 0.0)
			_track_sun()
			cam.theta = PI / 2.0 - 0.25
			cam.phi = PI
			stage.jump_cam_radius(MIN_RADIUS)
		"centre":
			cam.target.set_v(0, 0, 0)
			cam.theta = PI / 2.0 - 0.3
			stage.jump_cam_radius(8.0)
	stage.update_orbit_cam()

## Fly to a landmark and show its card: the Sun is the "sun" framing; anything else is a
## glide to where it is now, at its own viewing distance.
func fly(id: String) -> void:
	var lm := GalLandmarks.find(String(model.get("key", "")), id)
	if lm.is_empty(): return
	if lm.at == "sun":
		frame("sun")
	else:
		follow_sun = false
		stage.state.follow_id = null
		_adapted = false
		var p := GalLandmarks.position(lm, model, t_myr)
		stage.glide_target_to(DVec3.from_v3(p))
		stage.jump_cam_radius(float(lm.view[0]))
		stage.cam.theta = float(lm.view[1])
		if lm.at == "sky":
			# From the Sun's side, as we see it.
			var back := (GalLandmarks.position(GalLandmarks.MILKY_WAY[0], model, 0.0) - p).normalized()
			stage.cam.theta = acos(clampf(back.y, -1.0, 1.0))
			stage.cam.phi = atan2(back.z, back.x)
	landmark = id
	stage.hud.set_prose("galCard", String(lm.card))
	sync_hud()

func _build_landmarks() -> void:
	_clear_landmarks()
	landmarks = GalLandmarks.of(String(model.get("key", "")))
	var hud = stage.hud
	var grid: Control = hud.mount("galLandmarks")
	_lm_layer = Control.new()
	_lm_layer.name = "GalaxyLandmarks"
	_lm_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lm_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Behind the HUD's panels but styled by its Theme (the kinds are type variations).
	_lm_layer.theme = hud.theme
	hud.get_parent().add_child(_lm_layer)
	hud.get_parent().move_child(_lm_layer, 0)
	for lm in landmarks:
		var id: String = lm.id
		hud.B(grid, "Toggle", String(lm.get("short", lm.name)), "[data-gal-lm=%s]" % id, String(lm.name) + ". " + String(lm.card)).pressed.connect(func(): fly(id))
		var label: Control = hud.B(_lm_layer, "Landmark", "◦ " + String(lm.name), "", String(lm.card))
		label.pressed.connect(func(): fly(id))
		_lm_labels[id] = label
	hud.set_prose("galCard", "")
	_build_objects()

## Compact landmarks with a measured V drawn as one point of that light each, by the
## real stars' shader, in the galaxy's own frame. Their colour is the old spheroid's.
var _objects: MeshInstance3D = null
var _objects_mat: ShaderMaterial = null
func _build_objects() -> void:
	var pos := PackedVector3Array()
	var custom := PackedFloat32Array()
	var sets := PackedFloat32Array()
	var c := visual.sphere_pop.color
	c /= maxf(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b, 1e-6)
	var sun: Vector3 = GalLandmarks.position(GalLandmarks.MILKY_WAY[0], model, 0.0) if String(model.get("key", "")) == "milky_way" else Vector3.ZERO
	for lm in landmarks:
		if not lm.has("v"): continue
		var p := GalLandmarks.position(lm, model, 0.0)
		pos.append(p)
		# L from V at its distance from the Sun (M_V☉ = 4.83, the K calibration's).
		var d_pc := (p - sun).length() * 1000.0
		custom.append_array([c.r, c.g, c.b, GalNeighbourhood.l_vis(float(lm.v) - 5.0 * log(d_pc / 10.0) / log(10.0))])
		sets.append_array([1.0, 0.0, 0.0, 0.0])
	if pos.is_empty(): return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_CUSTOM0] = custom
	arr[Mesh.ARRAY_CUSTOM1] = sets
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arr, [], {},
		(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT))
	_objects_mat = ShaderMaterial.new()
	_objects_mat.shader = GalaxyVisual.CATALOGUE_SHADER
	_objects_mat.set_shader_parameter("uProfilePx2", BrightStars.PROFILE_PX2)
	_objects = MeshInstance3D.new()
	_objects.name = "Objects"
	_objects.mesh = mesh
	_objects.material_override = _objects_mat
	_objects.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_objects.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	visual.group.add_child(_objects)

func _build_neighbours() -> void:
	neighbours = []
	if String(model.get("key", "")) != "milky_way": return
	for k in GalModels.LOCAL_GROUP:
		var m := GalModels.neighbour(k)
		var f := GalLandmarks.neighbour_frame(m.sky, model)
		var v := GalaxyVisual.new(m)
		v.adapt_enabled = false
		stage.pipe.world_root.add_child(v.group)
		var c: Vector3 = f[0]
		neighbours.append({"key": k, "visual": v, "centre": DVec3.new(c.x, c.y, c.z), "basis": f[1], "extent": float(m.extent)})

## Each neighbour where it is relative to the camera, tilted, at the Milky Way's exposure.
## Its star lattice runs only with the camera inside its box.
func _update_neighbours(cam_pos: DVec3) -> void:
	for nb in neighbours:
		var v: GalaxyVisual = nb.visual
		var rel: Vector3 = (nb.centre as DVec3).rel_v3(cam_pos)
		var b: Basis = nb.basis
		v.group.position = rel
		v.group.basis = b
		var cl := b.inverse() * -rel
		v.exposure = visual.exposure
		v.adaptation = visual.adaptation
		v.show_glow = visual.show_glow and not nb.get("hide", false)
		v.show_stars = visual.show_stars
		v.res_override = -1.0 if cl.length() < float(nb.extent) else 0.0
		v.update(DVec3.new(cl.x, cl.y, cl.z), t_myr, null, 0.0, deg_to_rad(stage.cam_fov), float(stage.pipe.render_size.y), SkyModel.star_gain(), stage.cam.radius)

func _clear_landmarks() -> void:
	if is_instance_valid(_lm_layer): _lm_layer.queue_free()
	_objects = null
	_objects_mat = null
	_lm_layer = null
	_lm_labels = {}
	landmarks = []
	landmark = ""
	var grid: Control = stage.hud.mount("galLandmarks") if stage.hud != null else null
	if grid != null:
		for c in grid.get_children(): c.queue_free()

## Each landmark's label beside where it is on screen, hidden behind the camera, off
## screen, or when the camera is closer to it than twice its viewing distance.
func _place_labels(cam_pos: DVec3) -> void:
	if not is_instance_valid(_lm_layer): return
	var size := _lm_layer.size
	var basis: Basis = stage.cam_basis
	var tan_h := tan(deg_to_rad(stage.cam_fov) * 0.5)
	var aspect := size.x / maxf(size.y, 1.0)
	for lm in landmarks:
		var label: Control = _lm_labels.get(lm.id)
		if label == null: continue
		var p := DVec3.from_v3(GalLandmarks.label_position(lm, model, t_myr))
		var rel := p.rel_v3(cam_pos)
		var q := basis.inverse() * rel
		var x := q.x / -q.z / (tan_h * aspect) if q.z < 0.0 else 9.0
		var y := q.y / -q.z / tan_h if q.z < 0.0 else 9.0
		var shown := q.z < 0.0 and absf(x) < 0.98 and absf(y) < 0.98 and rel.length() > 2.0 * float(lm.view[0])
		label.visible = shown
		if shown:
			label.position = Vector2((x + 1.0) * 0.5 * size.x, (1.0 - y) * 0.5 * size.y) - Vector2(6.0, label.size.y * 0.5)

func set_rate(r: float) -> void:
	rate = r
	_pending = 0.0
	sync_hud()

func clamp_radius() -> void:
	var cam = stage.cam
	cam.radius = clampf(cam.radius, MIN_RADIUS, MAX_RADIUS)

## The radius distance readout: pc below a kpc, kpc below a Mpc.
static func fmt_kpc(d: float) -> String:
	if d < 1e-3: return "%s AU" % U.fixed(d * GalUnits.AU_PER_KPC, 0)
	if d < 1.0: return "%s pc" % U.fixed(d * 1000.0, 1 if d < 0.01 else 0)
	if d < 1000.0: return "%s kpc" % U.fixed(d, 1 if d < 100.0 else 0)
	return "%s Mpc" % U.fixed(d / 1000.0, 2)

## sync_hud runs four times a second; the tracer measurements every MEASURE_EVERY-th of them.
const MEASURE_EVERY := 4
var _measure_tick := -1

func sync_hud() -> void:
	var hud = stage.hud
	if hud == null or not active: return
	for lm in landmarks:
		hud.set_active("[data-gal-lm=%s]" % lm.id, lm.id == landmark)
	hud.set_text("galName", String(preset.get("name", "")))
	hud.set_prose("galBlurb", String(preset.get("blurb", "")))
	hud.set_text("galTime", "%s Myr" % U.fixed(t_myr, 1))
	var asked := rate if not stage.state.paused else 0.0
	hud.set_text("galRate", ("%s Myr/s" % U.fixed(achieved, 1)) + (" (limited)" if limited else ""))
	hud.set_text("galTracers", str(tracers.n) if tracers != null else "drawing…")
	# The drift and the curve walk every tracer: about 9 ms between them, so once a second
	# and the curve only while its chart is on screen.
	_measure_tick += 1
	var measure := _measure_tick % MEASURE_EVERY == 0
	if measure: hud.set_text("galDrift", U.expo(tracers.energy_drift(20), 1) if tracers != null else "—")
	hud.set_text("galDist", fmt_kpc(stage.cam.radius))
	for r in RATES:
		hud.set_active("[data-gal-rate=%s]" % str(r), absf(asked - float(r)) < 1e-9 or (float(r) == 0.0 and stage.state.paused))
	if visual != null:
		hud.set_active("galShowTracers", visual.show_tracers)
		hud.set_active("galShowStars", visual.show_stars)
		hud.set_active("galShowGlow", visual.show_glow)
	if measure and curve_chart != null and tracers != null and curve_chart.is_visible_in_tree():
		curve_chart.measure(tracers, model.potential)
