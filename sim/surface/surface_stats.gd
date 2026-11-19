class_name SurfaceStats
extends RefCounted

# How many times the surface has done anything, for surfacecheck's proof that outside a visit it
# never does. A static table of small counters: it costs nothing, and is the only state here.
static var calls := {}

static func count(what: String) -> void:
	calls[what] = int(calls.get(what, 0)) + 1

static func total() -> int:
	var n := 0
	for k in calls: n += int(calls[k])
	return n

static func reset() -> void:
	calls.clear()
