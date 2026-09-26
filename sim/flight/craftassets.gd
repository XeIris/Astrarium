class_name CraftAssets
extends RefCounted

# ============================================================================
# CRAFT ASSETS — the authored models, and the rules that keep them honest.
# Port of sim/flight/craftassets.js.
# ----------------------------------------------------------------------------
# Every vehicle in sim/flight/craftmodel.gd can be built out of primitives at
# real dimensions, and that procedural build is still there and still works.
# What it cannot do is BEVEL AN EDGE. A perfectly sharp edge catches no
# specular highlight at all, which is why hard surface assembled from lathes
# and cylinders reads as cardboard however right its silhouette is, and there
# is no bevel modifier at runtime. Nor can a lathe cut a recessed panel line:
# a cylinder takes one radius, so a joint between barrel sections can only be
# a ring strapped round the outside.
#
# So the vehicles are authored in Blender — assets/blender/*.py, where the
# SCRIPT IS THE MODEL and nothing is clicked — and loaded here. The .glb files
# are build artifacts and are not in the repo; assets/blender/build.sh makes
# them, tools/sync_assets.sh copies them to res://assets/craft/, and a
# fresh clone runs without them.
#
# HOW THEY ARE LOADED, AND WHY THIS WAY. Godot's editor IMPORTS a .glb as a
# PackedScene (res://.godot/imported/<id>.glb-<hash>.scn) and an export packs
# that imported scene, not the .glb. So the file is reached with
# ResourceLoader.exists() + load() of "res://assets/craft/<id>.glb", which the
# import remap resolves in the editor and in an exported build alike. Runtime
# GLTFDocument on the raw file would work in the editor and then fail in an
# export, which strips non-resource files — a vehicle that draws only on the
# developer's machine. The consequences:
#   · the .glb has to be present (and imported: open the editor once, or run
#     `Godot --headless --path . --import`) BEFORE exporting, or the export
#     simply has no model and every vehicle flies its procedural build;
#   · nothing is fetched over a network, so "unreachable CDN" is gone as a
#     failure mode; "not synced", "not imported" and "no stage_ nodes" remain,
#     and all three fall back silently.
#
# FOUR RULES THIS MODULE EXISTS TO KEEP.
#
#   · build_craft() STAYS SYNCHRONOUS. Four call sites depend on it returning a
#     finished vehicle, one of them the studio's audit(). So assets are
#     preloaded into a cache and the builder reads the cache — a load is a
#     startup concern, not a per-build one.
#
#   · A MISSING ASSET IS NOT AN ERROR. If a .glb is absent or unimportable, the
#     stage falls back to its procedural build and the sim runs: one
#     push_warning per vehicle, nothing more. The fallback is kept working
#     rather than left to rot.
#
#   · LOAD ONE VEHICLE, NOT NINE. The set is about 12 MB and two thirds of that
#     is the Hail Mary alone; pulling all of it to fly a Falcon 9 would put a
#     multi-megabyte stall in front of a launch for eight models that will not
#     be drawn. preload_craft(id) starts a THREADED load of exactly one, and
#     everything that builds a craft asks for the one it is about to build.
#
#   · THE MOVING PARTS ARE BOUND BY NAME, and the names are an INTERFACE.
#     craftmodel's update() drives whatever is in `parts`, and spaceflight
#     hangs the plumes on the same objects. Rename a node in a .py file and the
#     legs stop deploying — silently, with no error anywhere — so the patterns
#     below and the prefixes in assets/blender/common.py are one agreement
#     written in two places. Godot's importer keeps these names verbatim
#     (measured on all nine files: `gltf/naming_version=2` changes only names
#     carrying '.', ':' or '@', and none of the interface names do).
# ============================================================================

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

## Emitters have to be scaled for an HDR pipeline. Blender writes the strength
## through KHR_materials_emissive_strength, which Godot's importer reads into
## `emission_energy_multiplier` — but if that extension is ever dropped the
## value silently comes back as 1.0 and a drive face renders as a dull red
## disc. Taking the max is idempotent: a no-op when the extension loaded, a
## rescue when it did not. Keyed by the EXACT material name, as the JS is (the
## Hail Mary's are `emitCell.001` and so are left at the file's value there
## too).
const EMISSIVE := {"emitPlate": 2.0, "emitCell": 6.0}

## The node names craftmodel drives, mapped to the `parts` bucket they belong
## in. Anchored and digit-terminated on purpose: a helper empty called
## `mount_gimbal_x` or `gimbal_beetle_0_mount` must NOT be collected as a
## pivot, and a loose begins_with() would collect both and drive the wrong
## node. `_fixed` is the one permitted suffix — see bind_parts.
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

## Make an imported scene draw the way the web build draws its GLTFLoader
## output, and the way craftmodel's own materials do.
static func _prepare(root: Node) -> void:
	if root is Node3D:
		# three's Euler is XYZ, and update() assigns rotation.z on the driven
		# nodes; they carry identity (the interface says so), so the order only
		# has to agree with the procedural build's.
		(root as Node3D).rotation_order = EULER_ORDER_XYZ
	if root is MeshInstance3D:
		var mi := root as MeshInstance3D
		# The importer generates LODs, and Godot swaps them in by screen size.
		# The web build draws the full mesh at every range, and a bevel is
		# exactly the detail an automatic decimator removes first; hold the top
		# level at any distance.
		mi.lod_bias = 128.0
		var mesh := mi.mesh
		if mesh != null:
			for s in mesh.get_surface_count():
				var m := mesh.surface_get_material(s) as BaseMaterial3D
				if m == null: continue
				# Most of this set is open shells — a lathed bell, an aft
				# skirt, an interstage, a fairing half — and a single-sided
				# shell has no inner wall: you look into an engine bell and see
				# sky. The exporter already writes doubleSided; this is the belt.
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
				# three's MeshStandardMaterial is Lambert + GGX; Godot's
				# importer leaves Burley diffuse, which is not.
				m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
				m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
				var want = EMISSIVE.get(m.resource_name)
				if want != null and m.emission_enabled:
					m.emission_energy_multiplier = maxf(m.emission_energy_multiplier, want)
	for c in root.get_children():
		_prepare(c)

## Split a loaded scene into its per-stage subtrees.
##
## A vehicle is one file with one `stage_<key>` node per stage, because
## build_craft positions each stage's group itself — a mounted stage does not
## even sit where the file has it (the Shuttle's orbiter is bolted to the side
## of the tank). So the subtrees are detached here and handed out one at a
## time, each still carrying its own internal offset.
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

## Start loading one vehicle's model on a worker thread. Never blocks, never
## throws: returns false when there is nothing to load (unknown id, or no
## imported .glb), in which case the fallback is already settled.
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

## Settle the models for the given vehicle ids, or for ALL of them if none is
## named — BLOCKING until each is loaded or has fallen back. Anything that
## builds a craft and cares which build it gets has to call this first or it
## silently measures the fallback — which for the studio's audit() means
## reporting the fallback's triangle count as the regression number. (The JS
## returns a Promise; here the wait is synchronous, because a load that has
## already been started on a thread is simply joined.)
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

## A fresh instance of one authored stage, or null if there isn't one.
## duplicate() shares meshes and materials with the template, so a second
## vehicle costs a hierarchy and nothing else.
static func craft_stage(vehicle_id: String, stage_key: String) -> Node3D:
	var v = CACHE.get(vehicle_id)
	if v == null: return null
	var t = v.get(stage_key)
	if t == null: return null
	var n: Node3D = (t as Node3D).duplicate()
	return n

## Bind an authored stage's moving parts into the `parts` record craftmodel
## keeps. Sorted by name so the order is deterministic across loads — the
## plumes are created in this order and an engine that swaps index between
## runs would swap its exhaust with its neighbour. (Plain code-point order;
## the JS's localeCompare agrees on every name in the set, which are all
## zero-padded where they run past 9.)
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
				# A PIVOT DECLARES HOW FAR IT MAY SWING and update() clamps to
				# it, because a cluster is not all one engine: Starship's three
				# vacuum Raptors are rigid and sit in the same list as its three
				# that steer, and twenty of Super Heavy's thirty-three are bolted
				# down. The model says which by suffixing the node `_fixed`;
				# everything else gets the engine's published authority. Without
				# this the Hail Mary's rigid spin drives sat visibly canted and
				# waggled once a second.
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
