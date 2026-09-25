extends RefCounted

# ============================================================================
# Stand-ins for the modules main.gd names that have not landed on this branch
# yet (the course UI, the Foundry, the cross-section formatter). The flight
# harness patches main.gd's source to call these instead, so the REAL
# orchestrator can be driven before its neighbours exist. Nothing here draws.
# When LessonUI / Foundry / CrossSection exist, tools/flighttest.gd stops
# patching and this file is unused.
# ============================================================================

class Lessons extends RefCounted:
	var active := false
	func close() -> void: pass
	func resume() -> void: pass
	func update(_dt: float) -> void: pass
	func open_lesson(_id) -> void: pass

class Anything extends RefCounted:
	func show(_a = null, _b = null) -> void: pass
	func sync(_b = null) -> void: pass

static func create_lessons(_o = null) -> Lessons: return Lessons.new()
static func create_foundry(_o = null) -> Anything: return Anything.new()
static func create_inspector(_o = null) -> Anything: return Anything.new()
static func create_live_editor(_o = null) -> Anything: return Anything.new()
static func fmt_mass(m: float) -> String: return "%s M☉" % U.fixed(m, 2)
