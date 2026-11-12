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
	_arm_task = WorkerThreadPool.add_task(func():
		var b := v.bake_arms()
		_mutex.lock()
		_arms_baked = b
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
	frame("whole")
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
	_arms_baked = {}
	_mutex.unlock()
	if not b.is_empty() and visual != null: visual.apply_arms(b)

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
	active = false
	if visual != null: visual.dispose()
	visual = null
	tracers = null
	model = {}
	preset = {}
	key = ""

## One frame of the scene's physics: the tracers advance by rate × dt within the
## step budget. Returns the Myr accepted.
func step(dt: float) -> float:
	if not active: return 0.0
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
			# The solar neighbourhood (Bennett & Bovy 2019: 20.8 pc above the plane).
			cam.target.set_v(-r0, 0.0208, 0.0)
			cam.theta = PI / 2.0 - 0.25
			cam.phi = PI
			stage.jump_cam_radius(0.03)
		"centre":
			cam.target.set_v(0, 0, 0)
			cam.theta = PI / 2.0 - 0.3
			stage.jump_cam_radius(8.0)
	stage.update_orbit_cam()

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
