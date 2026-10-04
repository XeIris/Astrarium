class_name CraftAssets
extends RefCounted

# Imported PackedScenes survive export; loading raw glTF does not. Templates are
# validated once before caching so malformed rigs cannot silently lose motion.
# A missing optional model uses the procedural build. Present invalid models also
# fall back with a warning, while checks reject VALIDATION_ERRORS.

const DIR := "res://assets/craft/"
## Keys are vehicle ids from sim/flight/vehicles.
const CRAFT_ASSETS := {
	"saturnv": DIR + "saturnv.glb",
	"falcon9": DIR + "falcon9.glb",
	"shuttle": DIR + "shuttle.glb",
	"starship": DIR + "starship.glb",
	"lm": DIR + "lm.glb",
	"skycrane": DIR + "skycrane.glb",
	"ioncruiser": DIR + "ioncruiser.glb",
	"hailmary": DIR + "hailmary.glb",
	"beetle": DIR + "beetle.glb",
}

## Emissive strength floors, keyed by exact material name: a no-op when
## KHR_materials_emissive_strength loaded, a rescue when it didn't.
const EMISSIVE := {"emitPlate": 2.0, "emitCell": 6.0}

## Driven node names → `parts` bucket. Anchored and digit-terminated, so helpers like
## `gimbal_beetle_0_mount` aren't collected. `_fixed` is the one permitted suffix.
const ROLES := [
	["gimbals", "^gimbal_([A-Za-z0-9]+)_(\\d+)(_fixed)?$"],
	["legs", "^leg_([A-Za-z0-9]+)_(\\d+)$"],
	["fins", "^fin_([A-Za-z0-9]+)_(\\d+)$"],
	["arrays", "^array_([A-Za-z0-9]+)_(\\d+)$"],
	["flaps", "^flap_([A-Za-z0-9]+)_(\\d+)$"],
	["halves", "^half_([A-Za-z0-9]+)_(\\d+)$"],
]

static var _re := []
## id -> {stageKey: Node3D template} once settled, or null when there is no
## authored model (missing, failed, or carrying no stage_ nodes).
static var CACHE := {}
## id -> resource path of a threaded load in flight.
static var PENDING := {}
static var VALIDATION_ERRORS := {}

static func engine_owner(spec: Dictionary, vehicle: Dictionary) -> Dictionary:
	for other in vehicle.get("stages", []):
		if str(other.get("engineOn", "")) == str(spec.key): return other
	return spec

static func gimbal_limits(spec: Dictionary, vehicle: Dictionary) -> Array:
	if spec.get("engineOn", "") != "": return []
	var owner := engine_owner(spec, vehicle)
	var look: Dictionary = spec.get("look", {})
	var eng = owner.get("engine")
	var limits := []
	if eng != null and not (owner == spec and look.get("staticEngines", false)):
		var grouped := int(look.get("enginesPerPivot", 1))
		var count := int(owner.get("count", 0))
		if grouped < 1 or count % grouped != 0: return []
		for i in count / grouped:
			limits.append(0.0 if look.get("fixedGimbals", []).has(i) else float(eng.get("gimbal", 0.0)))
	var vac = owner.get("vacEngine")
	if vac != null:
		for i in int(owner.get("vacCount", 0)): limits.append(float(vac.get("gimbal", 0.0)))
	return limits

static func part_counts(spec: Dictionary, vehicle: Dictionary) -> Dictionary:
	var look: Dictionary = spec.get("look", {})
	return {"gimbals": gimbal_limits(spec, vehicle).size(), "fins": int(spec.get("gridFins", 0)),
		"legs": 0 if look.get("fixedLegs", false) else int(spec.get("legs", 0)),
		"arrays": int(look.get("arrays", 0)), "flaps": int(spec.get("flaps", look.get("flaps", 0))),
		"halves": 2 if look.get("fairing", false) else 0}

static func validate_scene(scene: Node, vehicle: Dictionary) -> Array:
	var issues := []
	var found := []
	_collect(scene, found)
	var stages := {}
	for node in found:
		var key := str(node.name).substr(6)
		if stages.has(key): issues.append("duplicate stage_" + key)
		stages[key] = node
		var parent: Node = node.get_parent()
		while parent != null:
			if str(parent.name).begins_with("stage_"): issues.append("nested stage_%s under %s" % [key, parent.name])
			parent = parent.get_parent()
	for spec in vehicle.stages:
		var key := str(spec.key)
		if not stages.has(key):
			issues.append("missing stage_" + key)
			continue
		var root: Node = stages[key]
		var grouped := int(spec.get("look", {}).get("enginesPerPivot", 1))
		var owner := engine_owner(spec, vehicle)
		if grouped < 1 or int(owner.get("count", 0)) % maxi(grouped, 1) != 0:
			issues.append("stage_%s engine count must be divisible by positive enginesPerPivot" % key)
		if not root is Node3D or not _has_mesh(root): issues.append("stage_%s requires 3D geometry" % key)
		var required := part_counts(spec, vehicle)
		var limits := gimbal_limits(spec, vehicle)
		for role in _roles():
			var nodes := []
			var re: RegEx = role[1]
			_match(root, re, nodes)
			var bucket: String = role[0]
			if nodes.size() != required[bucket]:
				issues.append("stage_%s %s: expected %d, found %d" % [key, bucket, required[bucket], nodes.size()])
			var indices := {}
			for node: Node in nodes:
				var match_name := re.search(str(node.name))
				var index := int(match_name.get_string(2))
				if match_name.get_string(1) != key or indices.has(index) or index >= required[bucket]:
					issues.append("%s has wrong stage scope, duplicate or out-of-range index" % node.name)
				indices[index] = true
				if not node is Node3D or not _has_mesh(node):
					issues.append("%s requires 3D geometry" % node.name)
					continue
				if (node as Node3D).quaternion.angle_to(Quaternion.IDENTITY) > 1e-4:
					issues.append("%s driven rotation must be identity; put fixed orientation on its mount" % node.name)
				if bucket == "gimbals" and index < limits.size():
					var fixed := str(node.name).ends_with("_fixed")
					if fixed and limits[index] > 0.0 or (spec.get("look", {}).get("fixedGimbals", []).has(index) and not fixed):
						issues.append("%s fixed suffix disagrees with configured gimbal authority" % node.name)
	for key in stages:
		if not vehicle.stages.any(func(spec): return str(spec.key) == key): issues.append("unexpected stage_" + key)
	return issues

static func _has_mesh(node: Node) -> bool:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null: return true
	for child in node.get_children():
		if _has_mesh(child): return true
	return false

static func _roles() -> Array:
	if _re.is_empty():
		for r in ROLES:
			var re := RegEx.new()
			re.compile(r[1])
			_re.append([r[0], re])
	return _re

## Make an imported scene draw like craftmodel's own materials.
static func _prepare(root: Node) -> void:
	if root is Node3D:
		# XYZ Euler order, matching the procedural build (driven nodes carry identity).
		(root as Node3D).rotation_order = EULER_ORDER_XYZ
	if root is MeshInstance3D:
		var mi := root as MeshInstance3D
		# Preserve imported screen-space LOD selection as craft recede.
		mi.lod_bias = 1.0
		var mesh := mi.mesh
		if mesh != null:
			for s in mesh.get_surface_count():
				var m := mesh.surface_get_material(s) as BaseMaterial3D
				if m == null: continue
				# The craft material is Lambert + GGX; Godot's
				# importer leaves Burley diffuse, which is not.
				m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
				m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
				var want = EMISSIVE.get(m.resource_name)
				if want != null and m.emission_enabled:
					m.emission_energy_multiplier = maxf(m.emission_energy_multiplier, want)
				MaterialDetail.register(m)
	for c in root.get_children():
		_prepare(c)

## Split a loaded scene into per-stage subtrees (one `stage_<key>` each), since
## build_craft positions each stage itself.
static func _split_stages(scene: Node) -> Dictionary:
	var found := []
	_collect(scene, found)
	var stages := {}
	for s: Node in found:
		stages[String(s.name).substr(6)] = s
		if s.get_parent() != null:
			s.get_parent().remove_child(s)
	return stages

static func _collect(n: Node, out: Array) -> void:
	if String(n.name).begins_with("stage_"):
		out.append(n)
	for c in n.get_children():
		_collect(c, out)

static func _fallback(id: String, why: String, invalid := false) -> void:
	push_warning("[craftassets] %s unavailable (%s), using the procedural build" % [id, why])
	if invalid and not VALIDATION_ERRORS.has(id): VALIDATION_ERRORS[id] = [why]
	CACHE[id] = null

## Settle one vehicle's model from a loaded PackedScene.
static func _settle(id: String, ps: Resource) -> void:
	if not (ps is PackedScene):
		_fallback(id, "not an imported scene", true)
		return
	var inst := (ps as PackedScene).instantiate()
	var issues := validate_scene(inst, Vehicles.get_vehicle(id))
	if not issues.is_empty():
		inst.free()
		VALIDATION_ERRORS[id] = issues
		_fallback(id, "invalid rig: " + "; ".join(issues))
		return
	_prepare(inst)
	var stages := _split_stages(inst)
	inst.free()
	# A file that loads but carries no stage_ node would otherwise settle as an
	# empty model and every stage would silently fall back anyway; say so once.
	if stages.is_empty():
		_fallback(id, "no stage_ nodes", true)
		return
	CACHE[id] = stages

## Start a threaded load of one vehicle. Never blocks or throws; false when there's
## nothing to load.
static func preload_craft(id: String) -> bool:
	if CACHE.has(id):
		return CACHE[id] != null
	if PENDING.has(id):
		return true
	var path: String = CRAFT_ASSETS.get(id, "")
	if path == "" or not ResourceLoader.exists(path):
		_fallback(id, "no imported " + (path if path != "" else "model"), FileAccess.file_exists(path))
		return false
	var err := ResourceLoader.load_threaded_request(path, "PackedScene")
	if err != OK:
		_fallback(id, "load request failed (%d)" % err, true)
		return false
	PENDING[id] = path
	return true

## Non-blocking: move a finished threaded load into the cache. True once the
## vehicle is SETTLED — authored or fallen back — so a caller can rebuild.
static func poll(id: String) -> bool:
	if CACHE.has(id):
		return true
	if not PENDING.has(id):
		return false
	var path: String = PENDING[id]
	var st := ResourceLoader.load_threaded_get_status(path)
	if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return false
	PENDING.erase(id)
	if st == ResourceLoader.THREAD_LOAD_LOADED:
		_settle(id, ResourceLoader.load_threaded_get(path))
	else:
		_fallback(id, "load failed", true)
	return true

## True when this vehicle's authored model is in the cache.
static func has_model(id: String) -> bool:
	return CACHE.get(id) != null

## Settle the models for these ids (all if none), blocking until each has loaded or
## fallen back. Call before building, or audit() measures the fallback.
static func craft_models_ready(ids: Array = []) -> void:
	var want := ids.filter(func(x): return x != null and str(x) != "")
	if want.is_empty():
		want = CRAFT_ASSETS.keys()
	# DummyRenderer's mesh RID allocator races when headless workers load in parallel.
	if DisplayServer.get_name() == "headless":
		for id in want:
			var k := str(id)
			if CACHE.has(k): continue
			var path: String = CRAFT_ASSETS.get(k, "")
			if path == "" or not ResourceLoader.exists(path):
				_fallback(k, "no imported " + path, FileAccess.file_exists(path))
				continue
			if PENDING.has(k):
				PENDING.erase(k)
				_settle(k, ResourceLoader.load_threaded_get(path))
			else:
				_settle(k, ResourceLoader.load(path, "PackedScene"))
		return
	for id in want:
		preload_craft(str(id))
	for id in want:
		var k := str(id)
		if CACHE.has(k) or not PENDING.has(k):
			continue
		var path: String = PENDING[k]
		PENDING.erase(k)
		var res := ResourceLoader.load_threaded_get(path)   # joins the worker
		if res == null: _fallback(k, "load failed", true)
		else: _settle(k, res)

## A fresh instance of one authored stage, or null. duplicate() shares meshes and
## materials.
static func craft_stage(vehicle_id: String, stage_key: String) -> Node3D:
	var v = CACHE.get(vehicle_id)
	if v == null: return null
	var t = v.get(stage_key)
	if t == null: return null
	var n: Node3D = (t as Node3D).duplicate()
	return n

## Bind an authored stage's moving parts into `parts`, sorted by name so plume order
## is deterministic.
static func bind_parts(root: Node, parts: Dictionary, spec: Dictionary, vehicle: Dictionary = {}) -> int:
	var n := 0
	var limits := gimbal_limits(spec, vehicle)
	for role in _roles():
		var bucket: String = role[0]
		var re: RegEx = role[1]
		var found := []
		_match(root, re, found)
		found.sort_custom(func(a: Node, b: Node) -> bool: return int(re.search(str(a.name)).get_string(2)) < int(re.search(str(b.name)).get_string(2)))
		for p: Node3D in found:
			if bucket == "gimbals":
				var index := int(re.search(str(p.name)).get_string(2))
				var g := float(limits[index]) if index < limits.size() else 0.0
				p.set_meta("gimbal_deg", g)
			parts[bucket].append(p)
			n += 1
	return n

static func _match(n: Node, re: RegEx, out: Array) -> void:
	if re.search(String(n.name)) != null:
		out.append(n)
	for c in n.get_children():
		_match(c, re, out)

## Drop every cached template (they are orphan nodes, so they have to be freed
## by hand) and forget every load. For shutdown, and for tests.
static func clear() -> void:
	for id in CACHE.keys():
		var v = CACHE[id]
		if v != null:
			for t in v.values():
				(t as Node).free()
	CACHE.clear()
	PENDING.clear()
	VALIDATION_ERRORS.clear()

## Did this built craft (its root group) use an authored mesh anywhere?
static func is_authored(craft_root: Node) -> bool:
	for st in craft_root.get_children():
		for c in st.get_children():
			if String(c.name).begins_with("stage_"):
				return true
	return false
