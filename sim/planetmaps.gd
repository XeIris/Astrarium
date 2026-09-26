class_name PlanetMaps
extends RefCounted

# ============================================================================
# PLANET MAPS — mission imagery for the three bodies we have it for.
# ----------------------------------------------------------------------------
# These are offline copies of mission maps (assets/planet-maps/, credits in
# the README there), not network dependencies at run time. Only real Solar
# System bodies use them; invented worlds keep terrain(). The maps supply
# colour and mapped features; the simulator supplies lighting, atmosphere,
# clouds and the extreme-climate overlays (shaders/bodies/rocky_surface
# .gdshader reads them through uMapKind / uColorMap / uLandMask).
#
#   kind 1  Earth: a colour composite AND a land/water mask, because the sea
#           is still a sea — it glints, and it can boil away.
#   kind 2  a dry mission mosaic (Mars, the Moon): colour only, scaled by
#           `scale` into an albedo.
#
# All three colour maps have north at the top, 0° longitude in the middle and
# cover 360° × 180°, which is exactly the UV layout of the THREE-compatible
# sphere in RockyVisual.sphere_geometry (0° longitude at +X).
#
# THE API is the web build's, so the flight view's ground patch can reuse it:
#   PlanetMaps.load_planet_map(name, ready: Callable) -> bool
#     false  → no map for this body (or it failed to load): use terrain().
#     true   → ready({color, mask, kind, scale}) is called once the textures
#              are resident — immediately if they already are, otherwise on
#              the main thread a frame or two later.
# Loads are THREADED (ResourceLoader.load_threaded_request, polled from the
# SceneTree's process_frame), because a 4096×2048 map decoded synchronously is
# a visible hitch the moment Earth spawns — the web build's TextureLoader was
# asynchronous for the same reason. `synchronous = true` makes every load
# blocking, for harnesses that must have the map in the first frame.
# ============================================================================

const DIR := "res://assets/planet-maps/"

const SOURCES := {
	"Earth": {"color": "earth-july.jpg", "mask": "earth-land.png", "kind": 1, "scale": 1.0},
	"Mars":  {"color": "mars-viking.jpg", "kind": 2, "scale": 1.5},
	"Moon":  {"color": "moon-lro.jpg", "kind": 2, "scale": 0.24},
}

static var synchronous := false
static var _cache := {}
static var _polling := false

static func has_map(body_name: String) -> bool:
	return SOURCES.has(body_name)

static func load_planet_map(body_name: String, ready: Callable) -> bool:
	if not SOURCES.has(body_name):
		return false
	var source: Dictionary = SOURCES[body_name]
	var entry: Dictionary
	if not _cache.has(body_name):
		entry = {
			"kind": source.kind, "scale": source.scale, "color": null, "mask": null,
			"waiting": [], "failed": false, "pending": [],
		}
		_cache[body_name] = entry
		var paths := [DIR + str(source.color)]
		if source.has("mask"):
			paths.append(DIR + str(source.mask))
		for p in paths:
			if not ResourceLoader.exists(p):
				entry.failed = true
		if entry.failed:
			push_warning("Planet map for %s could not be loaded; using procedural surface" % body_name)
			return false
		if synchronous:
			entry.color = load(paths[0])
			if paths.size() > 1: entry.mask = load(paths[1])
			if entry.color == null or (paths.size() > 1 and entry.mask == null):
				entry.failed = true
				push_warning("Planet map for %s could not be loaded; using procedural surface" % body_name)
				return false
		else:
			for p in paths:
				ResourceLoader.load_threaded_request(p, "Texture2D")
			entry.pending = paths
			_start_polling()
	entry = _cache[body_name]
	if entry.failed:
		return false
	if _complete(entry):
		ready.call(entry)
	else:
		entry.waiting.append(ready)
	return true

static func _complete(entry: Dictionary) -> bool:
	return entry.color != null and (not _has_mask(entry) or entry.mask != null)

static func _has_mask(entry: Dictionary) -> bool:
	return int(entry.kind) == 1

static func _start_polling() -> void:
	if _polling: return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return
	_polling = true
	tree.process_frame.connect(_poll)

static func _poll() -> void:
	var busy := false
	for body_name in _cache:
		var entry: Dictionary = _cache[body_name]
		if entry.failed or entry.pending.is_empty():
			continue
		var paths: Array = entry.pending
		var done := true
		for i in paths.size():
			var st := ResourceLoader.load_threaded_get_status(paths[i])
			if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				done = false
			elif st != ResourceLoader.THREAD_LOAD_LOADED:
				entry.failed = true
		if entry.failed:
			entry.pending = []
			entry.waiting.clear()
			push_warning("Planet map for %s could not be loaded; using procedural surface" % body_name)
			continue
		if not done:
			busy = true
			continue
		entry.color = ResourceLoader.load_threaded_get(paths[0])
		if paths.size() > 1:
			entry.mask = ResourceLoader.load_threaded_get(paths[1])
		entry.pending = []
		var cbs: Array = entry.waiting.duplicate()
		entry.waiting.clear()
		for cb in cbs:
			if (cb as Callable).is_valid():
				cb.call(entry)
	if not busy:
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.process_frame.is_connected(_poll):
			tree.process_frame.disconnect(_poll)
		_polling = false
