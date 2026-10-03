extends Node

# Physics continues through the kernel; streams may change only their own pool.
const Catch = preload("res://tools/coursecheck.gd").Catch

class MutatingVisual extends RefCounted:
	var inner
	var body: Body
	func _init(viz, b: Body) -> void:
		inner = viz
		body = b
	func update(dt: float, ctx: VisualCtx) -> void:
		inner.update(dt, ctx)
		if dt > 0.0:
			body.mass *= 1.0 - 0.18 * dt
			body.vel.scale_in(1.0 - 0.06 * dt)
			inner.group.scale *= 0.9
	func _get(property: StringName):
		return inner.get(property)
	func _set(property: StringName, value) -> bool:
		inner.set(property, value)
		return true

var stage: Node
var checks := 0
var failures := 0
var catcher := Catch.new()
var inject_mutation := false

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func fixture(true_scale := false, scene_scale := 1.0, body_scale := 1.0) -> Array:
	stage.clear_bodies()
	stage.state.true_scale = true_scale
	stage.state.scene_scale = scene_scale
	stage.state.body_scale = body_scale
	stage.state.speed = 0.0
	stage.state.paused = false
	stage.state.time_scale = 1.0
	stage.state.max_step = 1e-4
	stage.state.gw_boost = 0.0
	var hole: Body = stage.spawn_body({"type": "bh", "name": "hole", "mass": 12.0,
		"pos": [0.0, 0.0, 0.0], "vel": [0.1, -0.2, 0.3]})
	var donor: Body = stage.spawn_body({"type": "star", "name": "donor", "mass": 1.0,
		"radiusSun": 1.0, "pos": [0.1, 0.0, 0.0], "vel": [-0.3, 0.4, 0.2]})
	if inject_mutation: donor.viz = MutatingVisual.new(donor.viz, donor)
	check("fixture separated at physical contact", donor.pos.distance_to(hole.pos) > donor.contact_au + hole.rs)
	return [hole, donor]

func totals(bodies: Array) -> Dictionary:
	var mass := 0.0
	var momentum := DVec3.new()
	for b: Body in bodies:
		if not b.alive: continue
		mass += b.mass
		momentum.add_scaled_in(b.vel, b.mass)
	return {"mass": mass, "momentum": momentum}

func physical(bodies: Array) -> Array:
	var result := []
	for b: Body in bodies:
		result.append({"mass": b.mass, "pos": b.pos.clone(), "vel": b.vel.clone(), "alive": b.alive})
	return result

func unchanged(label: String, bodies: Array, before: Array) -> void:
	for i in bodies.size():
		var b: Body = bodies[i]
		check(label + " body %d mass/position/velocity" % i,
			b.mass == before[i].mass and b.pos.distance_to(before[i].pos) == 0.0
			and b.vel.distance_to(before[i].vel) == 0.0 and b.alive == before[i].alive)

func pool(stream: Bodies.AccretionStream) -> Dictionary:
	return {"head": stream.head, "pos": stream.pos_arr.duplicate(), "vel": stream.vel_arr.duplicate(),
		"life": stream.life_arr.duplicate(), "alpha": stream.alpha_arr.duplicate(),
		"live": stream._live, "shown": stream.points.visible, "surfaces": stream.mesh.get_surface_count()}

func frozen_frames() -> void:
	for true_scale in [false, true]:
		for scene_scale in [1.0, 3.0]:
			for body_scale in [1.0, 4.0]:
				var bodies := fixture(true_scale, scene_scale, body_scale)
				var label := "sizes=%s scene=%s bodies=%s" % [true_scale, scene_scale, body_scale]
				var before := physical(bodies)
				var conserved := totals(bodies)
				var scale: Vector3 = bodies[1].viz.group.scale
				var years: float = stage.state.sim_years
				for i in 8: stage.animate(1.0 / 60.0)
				check(label + " accepts zero world time", stage.state.sim_years == years and stage.state.last_steps == 0)
				unchanged(label + " positive visual time", bodies, before)
				var after := totals(stage.state.bodies)
				check(label + " total mass/momentum", after.mass == conserved.mass and after.momentum.distance_to(conserved.momentum) == 0.0)
				check(label + " orchestrator scale retained", bodies[1].viz.group.scale == scale)
				stage.state.paused = true
				var stream: Bodies.AccretionStream = bodies[1].viz.stream
				var stopped := pool(stream)
				stage.animate(0.25)
				unchanged(label + " paused", bodies, before)
				check(label + " paused stream unchanged", pool(stream) == stopped)
				stage.state.paused = false
				stage.animate(0.0)
				check(label + " zero-dt stream unchanged", pool(stream) == stopped)
				await get_tree().process_frame

func stream_checks() -> void:
	var bodies := fixture()
	var donor: Body = bodies[1]
	stage.animate(0.0)
	var ctx := VisualCtx.new()
	ctx.holes = [VisualCtx.Hole.of(bodies[0], bodies[0].scene_pos.rel_v3(stage.cam_pos))]
	var stream: Bodies.AccretionStream = donor.viz.stream
	stream.emit(Vector3.ONE, Vector3(0.2, 0.3, 0.4))
	var before := physical(bodies)
	var transform: Transform3D = donor.viz.group.transform
	var head := stream.head
	seed(7)
	for i in 20: Bodies.update_accretion_stream(donor, ctx, stream, 1.0 / 60.0)
	check("positive stream time moves particles", stream.pos_arr[0] != Vector3.ONE)
	check("positive stream time emits particles", stream.head != head)
	unchanged("direct cosmetic stream", bodies, before)
	check("direct cosmetic stream preserves group transform", donor.viz.group.transform == transform)
	for dt in [0.0, -0.25]:
		var stopped := pool(stream)
		Bodies.update_accretion_stream(donor, ctx, stream, dt)
		check("stream helper dt=%s is inert" % dt, pool(stream) == stopped)
		stream.step(dt)
		check("particle pool dt=%s is inert" % dt, pool(stream) == stopped)

func kernel_baseline() -> void:
	for true_scale in [false, true]:
		var bodies := fixture(true_scale)
		stage.state.speed = 1.0
		var baseline := []
		for b: Body in bodies:
			var copy := Derive.new_body(b.id, b.spec.duplicate(true))
			copy.pos.copy_from(b.pos)
			copy.vel.copy_from(b.vel)
			baseline.append(copy)
		var years: float = stage.state.sim_years
		var expected := NBody.step_physics(baseline, 1e-5, stage.state.max_step, 0.0)
		stage.animate(1e-5)
		check("accepted frame matches kernel clock sizes=%s" % true_scale,
			absf(stage.state.sim_years - years - float(expected.stepped)) < 1e-12 and float(expected.stepped) > 0.0)
		# Compact forces are approximate; compare with the same kernel, not a false
		# assumption that this black-hole pair has symmetric Newtonian acceleration.
		for i in bodies.size():
			check("accepted frame matches kernel body %d sizes=%s" % [i, true_scale],
				bodies[i].mass == baseline[i].mass and bodies[i].pos.distance_to(baseline[i].pos) < 1e-12
				and bodies[i].vel.distance_to(baseline[i].vel) < 1e-12)

func survival_and_contact() -> void:
	var bodies := fixture()
	var donor: Body = bodies[1]
	donor.mass = 0.011
	donor.mass0 = 1.0
	stage.animate(1.0 / 60.0)
	check("diminished separated donor is not synthetically removed", donor.alive and stage.state.bodies.has(donor) and stage.state.bodies.size() == 2)
	check("diminished donor retains physical mass", donor.mass == 0.011)
	bodies = fixture()
	var common := DVec3.new(0.3, -0.2, 0.1)
	for b: Body in bodies:
		b.pos.set_v(0.0, 0.0, 0.0)
		b.vel.copy_from(common)
	var before := totals(bodies)
	stage.state.speed = 1.0
	var years: float = stage.state.sim_years
	# Coincident equal-velocity bodies keep the force direction exactly zero,
	# isolating contact conservation from the compact-force approximation.
	stage.animate(1e-6)
	var after := totals(stage.state.bodies)
	check("real production contact accepts time and merges", stage.state.sim_years > years and stage.state.bodies.size() == 1)
	check("real production contact conserves mass", absf(after.mass - before.mass) < 1e-12)
	check("real production contact conserves momentum", after.momentum.distance_to(before.momentum) < 1e-12)

func _ready() -> void:
	inject_mutation = OS.get_cmdline_user_args().has("inject_mutation=1")
	if OS.get_cmdline_user_args().has("native=0"): NBody._native = 0
	print("ACCRETIONCHECK CONFIG native=%s inject_mutation=%s" % [NBody.native_available(), inject_mutation])
	OS.add_logger(catcher)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	stage.set_process(false)
	stage.set_process_input(false)
	stage.set_process_unhandled_input(false)
	await get_tree().process_frame
	stage._start("sandbox")
	stage.load_preset("blank")
	stage.lessons.store = ""
	await frozen_frames()
	stream_checks()
	kernel_baseline()
	survival_and_contact()
	for i in 3: await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var errors := catcher.take()
	for error in errors: print("ACCRETIONCHECK ENGINE ", error)
	check("no engine errors", errors.is_empty())
	print("ACCRETIONCHECK DONE checks=%d failures=%d" % [checks, failures])
	OS.remove_logger(catcher)
	get_tree().quit(1 if failures else 0)
