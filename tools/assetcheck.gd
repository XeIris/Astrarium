extends SceneTree

var failures := []
var checks := 0

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

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
		for role in ["legs", "fins", "arrays", "flaps", "gimbals"]:
			for pivot: Node3D in st.parts[role]:
				before[pivot] = {"rotation": pivot.rotation, "point": mesh_point(pivot)}
	var deploy := {}
	for st in craft.stages: deploy[st.key] = 1.0 if deployed else 0.0
	var command := 100.0 if deployed else -100.0
	craft.update({"dt": 4.0, "attached": {}, "deploy": deploy, "gimbal": {"x": command, "z": command}, "flap": command / 100.0})
	for st in craft.stages:
		for role in ["legs", "fins", "arrays", "flaps"]:
			var angle: float = {"legs": -1.15 if deployed else 0.0, "fins": -1.35 if deployed else 0.0,
				"arrays": 0.0 if deployed else PI / 2.0, "flaps": 0.6 if deployed else -0.6}[role]
			for pivot: Node3D in st.parts[role]:
				expect(absf(pivot.rotation.z - angle) < 1e-4, "%s/%s %s failed articulation" % [vehicle.id, st.key, role])
				check_geometry_motion(pivot, before[pivot], vehicle.id + "/" + st.key + "/" + role)
		for pivot: Node3D in st.parts.gimbals:
			var limit := deg_to_rad(float(pivot.get_meta("gimbal_deg", -1.0)))
			var wanted := limit if deployed else -limit
			expect(absf(pivot.rotation.x - wanted) < 1e-4 and absf(pivot.rotation.z + wanted) < 1e-4,
				"%s/%s gimbal failed clamp/fixed pose" % [vehicle.id, st.key])
			check_geometry_motion(pivot, before[pivot], vehicle.id + "/" + st.key + "/gimbal")

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
		if id == "falcon9":
			var pivot: Node3D = craft.stages[0].parts.gimbals[0]
			pivot.remove_meta("gimbal_deg")
			expect(not part_errors(craft, vehicle).is_empty(), "missing swing metadata accepted")
		craft.group.free()
	if authored: scene_probes()
	CraftAssets.clear()
	for error in failures: printerr("ASSETCHECK FAIL ", error)
	print("ASSETCHECK DONE %d checks, %d authored, %d failures" % [checks, used, failures.size()])
	quit(1 if not failures.is_empty() else 0)
