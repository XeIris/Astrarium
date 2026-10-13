extends SceneTree

var failures := []
var checks := 0

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func material_probes() -> void:
	for culling in [BaseMaterial3D.CULL_BACK, BaseMaterial3D.CULL_DISABLED]:
		var node := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		var material := StandardMaterial3D.new()
		material.cull_mode = culling
		mesh.material = material
		node.mesh = mesh
		CraftAssets._prepare(node)
		expect(material.cull_mode == culling, "authored culling overwritten")
		expect(material.diffuse_mode == BaseMaterial3D.DIFFUSE_LAMBERT, "authored diffuse preparation skipped")
		node.free()

func part_errors(craft, vehicle: Dictionary) -> Array:
	var errors := []
	for st in craft.stages:
		var expected := CraftAssets.part_counts(st.spec, vehicle)
		var limits := CraftAssets.gimbal_limits(st.spec, vehicle)
		for role in expected:
			if st.parts[role].size() != expected[role]: errors.append("%s/%s %s count" % [vehicle.id, st.key, role])
		for i in st.parts.gimbals.size():
			var pivot: Node3D = st.parts.gimbals[i]
			if not pivot.has_meta("gimbal_deg") or i >= limits.size() or not is_equal_approx(float(pivot.get_meta("gimbal_deg", -1.0)), float(limits[i])):
				errors.append("%s/%s gimbal %d missing or wrong authority" % [vehicle.id, st.key, i])
	return errors

func pose(craft, vehicle: Dictionary, deployed: bool) -> void:
	var before := {}
	for st in craft.stages:
		for role in ["legs", "fins", "arrays", "flaps", "doors", "gimbals"]:
			for pivot: Node3D in st.parts[role]:
				before[pivot] = {"rotation": pivot.rotation, "point": mesh_point(pivot)}
	var deploy := {}
	var attached := {}
	for st in craft.stages:
		deploy[st.key] = 1.0 if deployed else 0.0
		var cover := str(st.spec.get("look", {}).get("arrayCover", ""))
		if cover != "": attached[cover] = not deployed
	var command := 100.0 if deployed else -100.0
	craft.update({"dt": 4.0, "attached": attached, "deploy": deploy, "gear": deploy, "gimbal": {"x": command, "z": command}, "flap": command / 100.0})
	for st in craft.stages:
		for role in ["legs", "fins", "arrays", "flaps", "doors"]:
			var swing := float(st.spec.get("look", {}).get("gearSwing", 1.15))
			var angle: float = {"legs": -swing if deployed else 0.0, "fins": -1.35 if deployed else 0.0,
				"arrays": 0.0 if deployed else PI / 2.0, "flaps": 0.6 if deployed else -0.6,
				"doors": CraftModel.DOOR_OPEN if deployed else 0.0}[role]
			for pivot: Node3D in st.parts[role]:
				expect(absf(pivot.rotation.z - angle) < 1e-4, "%s/%s %s failed articulation" % [vehicle.id, st.key, role])
				check_geometry_motion(pivot, before[pivot], vehicle.id + "/" + st.key + "/" + role)
		for pivot: Node3D in st.parts.gimbals:
			var limit := deg_to_rad(float(pivot.get_meta("gimbal_deg", -1.0)))
			var wanted := limit if deployed else -limit
			expect(absf(pivot.rotation.x - wanted) < 1e-4 and absf(pivot.rotation.z + wanted) < 1e-4,
				"%s/%s gimbal failed clamp/fixed pose" % [vehicle.id, st.key])
			check_geometry_motion(pivot, before[pivot], vehicle.id + "/" + st.key + "/gimbal")

## The two boosters leave on their own paths, each with its own nozzle: apart, aft,
## below the orbiter, and turning differently; the stage frame itself stays put.
func booster_pieces(craft) -> void:
	var st = craft.stage("srb")
	expect(st.parts.pieces.size() == 2, "shuttle boosters are not separate pieces")
	if st.parts.pieces.size() != 2: return
	for pivot: Node3D in st.parts.gimbals:
		expect(st.parts.pieces.any(func(p): return p.is_ancestor_of(pivot)), "booster nozzle does not ride its booster")
	var start: Array = st.parts.pieces.map(func(p): return (p as Node3D).position)
	var stage_at: Vector3 = st.group.position
	craft.separate("srb")
	for i in 30: craft.update({"dt": 0.1, "attached": {"srb": false}, "accel": 9.0})
	var a: Node3D = st.parts.pieces[0]
	var b: Node3D = st.parts.pieces[1]
	# Each booster's centre of mass: its nozzle end swings toward the orbiter as it tumbles.
	var cg := Vector3(0.0, float(st.spec.look.sep.cgY), 0.0)
	var da: Vector3 = a.transform * cg - (start[0] + cg)
	var db: Vector3 = b.transform * cg - (start[1] + cg)
	expect(st.group.visible and st.group.position == stage_at, "booster stage frame moved or hid while its pieces fly")
	expect(da.x * signf(start[0].x) > 3.0 and db.x * signf(start[1].x) > 3.0, "boosters did not move apart: %s %s" % [da, db])
	expect(da.y < -30.0 and db.y < -30.0, "boosters did not fall behind the stack: %s %s" % [da, db])
	expect(da.z < 0.0 and db.z < 0.0, "boosters moved toward the orbiter: %s %s" % [da, db])
	expect(not a.basis.is_equal_approx(Basis()) and not a.basis.is_equal_approx(b.basis), "boosters do not tumble on their own")

## Every droppable stage leaves the way the physics says, measured on the built nodes
## alone: a stage dropped under thrust falls behind at least at the stack's
## acceleration plus its own motors' and the stack's authored pushes, and doesn't
## drift sideways unless it is a piece moving off the axis; a stage dropped in a coast
## (the Shuttle's tank) doesn't slide along the axis and moves away from the stages
## still flying.
func stage_separations(vehicle: Dictionary) -> void:
	const A := 9.0
	for spec: Dictionary in vehicle.stages:
		if spec.sep == "none": continue
		var craft = CraftModel.build_craft(vehicle)
		var st = craft.stage(spec.key)
		var coast: bool = spec.has("sepAfterCutoff")
		var T := 6.0 if coast else 3.0
		var nodes: Array = st.parts.pieces if not st.parts.pieces.is_empty() else st.parts.halves
		if nodes.is_empty(): nodes = [st.group]
		var pieces: bool = nodes[0] != st.group
		# Staging drops the stack bottom first: the stages below this one are gone.
		var rest := 0.0
		var toward := Vector3.ZERO
		var below := true
		for o in craft.stages:
			if o == st: below = false; continue
			if below: o.group.visible = false; continue
			rest += float(o.spec.dry) + float(o.spec.prop)
			toward += Vector3(o.group.position.x, 0.0, o.group.position.z) - Vector3(st.group.position.x, 0.0, st.group.position.z)
		var marks := []
		for n: Node3D in nodes:
			var acc := [false, AABB()]
			CraftModel._measure_into(n, n.transform, acc, null)
			var c: Vector3 = (acc[1] as AABB).get_center()
			marks.append({"node": n, "local": n.transform.affine_inverse() * c, "at": c, "out": Vector3(c.x, 0.0, c.z)})
		craft.separate(spec.key)
		for i in int(T / 0.1): craft.update({"dt": 0.1, "attached": {spec.key: false}, "accel": 0.0 if coast else A})
		var sep: Dictionary = spec.get("look", {}).get("sep", {})
		# What the authored pushes are worth along the axis by T: the motors' impulse
		# (aft by the cant) and the stack's own push, each from where it acts.
		var aft := 0.0 if coast else 0.5 * A * T * T
		var m = sep.get("motors")
		if m != null:
			var dv := float(m.thrust) * (float(m.web) + 0.5 * float(m.get("tail", 0.0))) * (m.sites as Array).size() \
				/ (float(spec.dry) / nodes.size()) * cos(deg_to_rad(float(m.cant)))
			aft += dv * (T - float(m.get("ignite", 0.0)) - 0.5 * float(m.web))
		var stack = sep.get("stack")
		var lateral := Vector3.ZERO
		if stack != null:
			var a_s := float(stack.thrust) / rest
			var t0 := float(stack.get("start", 0.0))
			var t1 := maxf(t0, 0.0)
			var t2 := minf(t0 + (float(stack.time) if stack.has("time") else float(stack.dv) / a_s), T)
			var dir := Vector3(float(stack.dir[0]), float(stack.dir[1]), float(stack.dir[2])).normalized()
			# A push on [t1, t2] is worth a·(t2 − t1)·(T − mid-time) by T.
			var d_stack: Vector3 = dir * a_s * maxf(t2 - t1, 0.0) * (T - 0.5 * (t1 + t2))
			aft += d_stack.y
			lateral = Vector3(d_stack.x, 0.0, d_stack.z)
		for mk: Dictionary in marks:
			var n: Node3D = mk.node
			var d: Vector3 = n.transform * (mk.local as Vector3) - (mk.at as Vector3)
			var h := Vector3(d.x, 0.0, d.z)
			var tag := "%s/%s %s" % [vehicle.id, spec.key, d]
			expect(st.group.visible, tag + ": separated stage hidden early")
			if coast:
				expect(absf(d.y) < 0.5, tag + ": coasting stage slid along the stack axis")
				expect(h.dot(toward.normalized()) < -0.8 * lateral.length(), tag + ": coasting stage did not move away from the stack")
			else:
				expect(d.y < -0.95 * aft and d.y > -1.2 * aft, tag + ": did not fall behind at the stack's acceleration (want %.1f m aft)" % aft)
				if pieces:
					expect(h.dot(mk.out) > 0.0, tag + ": piece moved in toward the stack's axis")
				else:
					expect(h.length() < 0.5, tag + ": whole stage drifted sideways")
		craft.group.free()

func payload_cover(craft) -> void:
	var payload = craft.stage("f9pl")
	var cover = craft.stage("f9fair")
	var state := {"dt": 4.0, "deploy": {"f9pl": 1.0}}
	craft.update(state)
	expect(payload.deploy == 0.0, "Falcon payload deployed inside an attached fairing")
	for array: Node3D in payload.parts.arrays:
		expect(is_equal_approx(array.rotation.z, PI / 2.0), "Falcon enclosed panel is not folded")
	state.attached = {"f9fair": false}
	craft.separate("f9fair")
	# The halves stay drawn for Separation.SHOWN s: fly to 0.1 s short of it, then past.
	var whole := int(Separation.SHOWN) - 1
	for step: Array in [[1.0, whole], [0.1, 9]]:
		state.dt = step[0]
		for i in step[1]:
			craft.update(state)
			expect(cover.group.visible and payload.deploy == 0.0, "Falcon panels opened during fairing separation")
	state.dt = 0.2
	craft.update(state)
	expect(not cover.group.visible and is_equal_approx(payload.deploy, 0.11), "Falcon clear panels did not begin eased deployment")
	state.dt = 2.0
	craft.update(state)
	for array: Node3D in payload.parts.arrays:
		expect(is_zero_approx(array.rotation.z), "Falcon clear panel did not fully deploy")
	state.attached = {}
	state.dt = 0.0
	craft.update(state)
	expect(payload.deploy == 0.0, "Falcon reassembled studio kept payload panels deployed")

func mesh_point(node: Node) -> Variant:
	if node is MeshInstance3D and node.mesh != null:
		return CraftModel.world_xform(node) * node.get_aabb().get_endpoint(7)
	for child in node.get_children():
		var point = mesh_point(child)
		if point != null: return point
	return null

func check_geometry_motion(pivot: Node3D, before: Dictionary, label: String) -> void:
	if pivot.rotation.distance_to(before.rotation) < 1e-4: return
	var after = mesh_point(pivot)
	expect(after != null and before.point != null and after.distance_to(before.point) > 1e-5,
		label + " rotates without moving geometry")

func scene_probes() -> void:
	CraftAssets.clear()
	var ps = load(CraftAssets.CRAFT_ASSETS.falcon9)
	if not ps is PackedScene: return
	for probe in ["rename", "drop", "scope", "index", "duplicate", "rotation", "geometry", "nested", "grouping"]:
		var root: Node = ps.instantiate()
		var pivot: Node = root.find_child("leg_f9s1_0", true, false)
		var vehicle: Dictionary = Vehicles.get_vehicle("falcon9").duplicate(true)
		match probe:
			"rename": pivot.name = "renamed_leg"
			"drop": pivot.free()
			"scope": pivot.name = "leg_wrong_0"
			"index": pivot.name = "leg_f9s1_99"
			"duplicate": root.find_child("leg_f9s1_1", true, false).name = "leg_f9s1_00"
			"rotation": (pivot as Node3D).rotation.x = 0.3
			"geometry":
				for child in pivot.get_children(): child.free()
			"nested":
				var stage: Node = root.find_child("stage_f9s2", true, false)
				stage.owner = null
				stage.reparent(root.find_child("stage_f9s1", true, false), false)
			"grouping": vehicle.stages[0].look.enginesPerPivot = 2
		expect(not CraftAssets.validate_scene(root, vehicle).is_empty(), "malformed scene accepted: " + probe)
		root.free()
	CraftAssets._settle("falcon9", broken_falcon())
	expect(CraftAssets.VALIDATION_ERRORS.has("falcon9") and not CraftAssets.has_model("falcon9"),
		"present invalid asset was hidden by procedural fallback")
	CraftAssets._fallback("ioncruiser", "missing optional asset probe")
	var fallback = CraftModel.build_craft(Vehicles.get_vehicle("ioncruiser"))
	expect(not fallback.authored and not CraftAssets.VALIDATION_ERRORS.has("ioncruiser"),
		"missing optional asset must use a valid procedural fallback")
	failures.append_array(part_errors(fallback, Vehicles.get_vehicle("ioncruiser")))
	fallback.group.free()

func broken_falcon() -> PackedScene:
	var ps: PackedScene = load(CraftAssets.CRAFT_ASSETS.falcon9)
	var malformed: Node = ps.instantiate()
	malformed.find_child("leg_f9s1_0", true, false).free()
	var invalid_scene := PackedScene.new()
	expect(invalid_scene.pack(malformed) == OK, "malformed rig probe could not be packed")
	malformed.free()
	return invalid_scene

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var authored: bool = args.get("assets", "1") != "0"
	if authored: CraftAssets.craft_models_ready()
	if args.get("inject_invalid", "0") == "1":
		CraftAssets.clear()
		CraftAssets._settle("falcon9", broken_falcon())
	for id in CraftAssets.VALIDATION_ERRORS:
		failures.append("invalid authored %s: %s" % [id, CraftAssets.VALIDATION_ERRORS[id]])
	var used := 0
	for id in Vehicles.VEHICLE_ORDER:
		var vehicle: Dictionary = Vehicles.get_vehicle(id)
		var craft = CraftModel.build_craft(vehicle)
		if craft.authored: used += 1
		expect(craft.stages.size() == vehicle.stages.size(), id + " stage count")
		failures.append_array(part_errors(craft, vehicle))
		pose(craft, vehicle, true)
		pose(craft, vehicle, false)
		stage_separations(vehicle)
		if id == "shuttle":
			booster_pieces(craft)
		if id == "falcon9":
			payload_cover(craft)
			var pivot: Node3D = craft.stages[0].parts.gimbals[0]
			pivot.remove_meta("gimbal_deg")
			expect(not part_errors(craft, vehicle).is_empty(), "missing swing metadata accepted")
		craft.group.free()
	material_probes()
	if authored: scene_probes()
	CraftAssets.clear()
	for error in failures: printerr("ASSETCHECK FAIL ", error)
	print("ASSETCHECK DONE %d checks, %d authored, %d failures" % [checks, used, failures.size()])
	quit(1 if not failures.is_empty() else 0)
