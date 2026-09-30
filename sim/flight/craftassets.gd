class_name CraftAssets
extends RefCounted

# CRAFT ASSETS: the authored Blender models. A lathe can't bevel an edge or cut a
# recessed panel line, so vehicles are authored in model_sources/blender/*.py (the
# script is the model). The .glb files are build artifacts: build.sh makes them,
# tools/sync_assets.sh copies them to res://assets/craft/, and a fresh clone runs
# without them.
#
# Godot imports a .glb as a PackedScene and exports the imported scene, so models
# are reached by load("res://assets/craft/<id>.glb") (runtime GLTFDocument on the
# raw file would fail in an export). The .glb must be imported before exporting, or
# every vehicle flies its procedural build. "Not synced", "not imported" and "no
# stage_ nodes" all fall back silently.
#
# Rules (see model_sources/blender/AGENTS.md):
#   · build_craft() stays synchronous; assets are preloaded into a cache.
#   · A missing asset is not an error: one push_warning per vehicle, then fallback.
#   · Load one vehicle, not nine (the set is ~12 MB, two thirds Hail Mary):
#     preload_craft(id) starts a threaded load of one.
#   · Moving parts are bound by name, and the patterns below must match common.py's
#     prefixes. The importer keeps them verbatim (naming_version=2 only touches
#     '.', ':' and '@').

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
	["gimbals", "^gimbal_[A-Za-z0-9]+_\\d+(_fixed)?$"],
	["legs", "^leg_[A-Za-z0-9]+_\\d+$"],
	["fins", "^fin_[A-Za-z0-9]+_\\d+$"],
	["arrays", "^array_[A-Za-z0-9]+_\\d+$"],
	["flaps", "^flap_[A-Za-z0-9]+_\\d+$"],
	["halves", "^half_[A-Za-z0-9]+_\\d+$"],
]

static var _re := []
## id -> {stageKey: Node3D template} once settled, or null when there is no
## authored model (missing, failed, or carrying no stage_ nodes).
static var CACHE := {}
## id -> resource path of a threaded load in flight.
static var PENDING := {}

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
		# Hold the top LOD at any distance: bevels are what a decimator removes first.
		mi.lod_bias = 128.0
		var mesh := mi.mesh
		if mesh != null:
			for s in mesh.get_surface_count():
				var m := mesh.surface_get_material(s) as BaseMaterial3D
				if m == null: continue
				# Double-sided: most of the set is open shells.
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
				# three's MeshStandardMaterial is Lambert + GGX; Godot's
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

static func _fallback(id: String, why: String) -> void:
	push_warning("[craftassets] %s unavailable (%s), using the procedural build" % [id, why])
	CACHE[id] = null

## Settle one vehicle's model from a loaded PackedScene.
static func _settle(id: String, ps: Resource) -> void:
	if not (ps is PackedScene):
		_fallback(id, "not an imported scene")
		return
	var inst := (ps as PackedScene).instantiate()
	_prepare(inst)
	var stages := _split_stages(inst)
	inst.free()
	# A file that loads but carries no stage_ node would otherwise settle as an
	# empty model and every stage would silently fall back anyway; say so once.
	if stages.is_empty():
		_fallback(id, "no stage_ nodes")
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
		_fallback(id, "no imported " + (path if path != "" else "model"))
		return false
	var err := ResourceLoader.load_threaded_request(path, "PackedScene")
	if err != OK:
		_fallback(id, "load request failed (%d)" % err)
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
		_fallback(id, "load failed")
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
	for id in want:
		preload_craft(str(id))
	for id in want:
		var k := str(id)
		if CACHE.has(k) or not PENDING.has(k):
			continue
		var path: String = PENDING[k]
		PENDING.erase(k)
		var res := ResourceLoader.load_threaded_get(path)   # joins the worker
		if res == null: _fallback(k, "load failed")
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
static func bind_parts(root: Node, parts: Dictionary, spec: Dictionary) -> int:
	var n := 0
	for role in _roles():
		var bucket: String = role[0]
		var re: RegEx = role[1]
		var found := []
		_match(root, re, found)
		found.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
		for p: Node3D in found:
			if bucket == "gimbals":
				# Per-pivot swing: `_fixed` pivots get zero, the rest the engine's published gimbal.
				var eng = spec.get("engine")
				var g := 0.0 if String(p.name).ends_with("_fixed") else \
					(float(U.nz(eng.get("gimbal"), 0.0)) if eng != null else 0.0)
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

## Did this built craft (its root group) use an authored mesh anywhere?
static func is_authored(craft_root: Node) -> bool:
	for st in craft_root.get_children():
		for c in st.get_children():
			if String(c.name).begins_with("stage_"):
				return true
	return false
