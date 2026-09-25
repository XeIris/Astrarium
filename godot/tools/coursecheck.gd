extends Node

# ============================================================================
# COURSE WALK — the regression check for the education mode
# ----------------------------------------------------------------------------
# The port of .claude/coursecheck.js. There is no test runner in this repo, so
# this is it: it brings up the REAL orchestrator (main.tscn), opens EVERY
# lesson, steps through EVERY step, runs frames at each one, and reports
# anything that raised an error, any scenario that came up empty when it
# should not have, and any body a lesson asked to focus on that does not
# exist in the scenario it opened.
#
# That last check is the one worth having. A lesson naming `focus: 'Sol'` in a
# scenario whose star is called 'Sun' fails silently — the camera simply does
# not move — and it is invisible in a screenshot.
#
#   Godot --path godot --resolution 1280x720 res://tools/coursecheck.tscn -- \
#         [report=/abs/report.json] [only=<module>/<lesson>,...] [selftest=1]
#
# `selftest=1` plants a script error, a push_error and a push_warning in the
# first step walked, to prove the logger is catching what it claims to — a
# check that cannot fail is not a check. It must report 2 errors, 1 warning.
#
# It prints one line per problem and a summary (`COURSE 35L 170S 0E`), writes
# the report as JSON if asked, and exits 1 if there were errors.
#
# THE PORT. The web version caught `window.onerror`, i.e. anything that
# THREW. A GDScript runtime error does not throw: it prints, abandons the
# function it happened in and carries on — so the equivalent is a Logger
# (OS.add_logger), which sees every script error, shader error and engine
# error as it is reported, and each is attributed to the step that was running
# when it arrived. push_warning() lands in the warnings list, as console.warn
# did. `document.getElementById` becomes the HUD's own id registry
# (hud.get_el), which is what the stage's set_control / set_panel resolve
# against, so "no such control" here means the stage would have ignored it.
# SIM.frame(dt) is main.animate(dt), as tools/presetcheck.sh's walk uses; the
# engine is then given two real frames so each step is also DRAWN, which is
# where a shader that fails to compile would show itself.
# ============================================================================

class Catch extends Logger:
	var mutex := Mutex.new()
	var errors: Array = []
	var warnings: Array = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var what := rationale if rationale != "" else code
		var kind: String = ["ERROR", "WARNING", "SCRIPT ERROR", "SHADER ERROR"][clampi(error_type, 0, 3)]
		var msg := "%s: %s @ %s:%d (%s)" % [kind, what, file, line, function]
		mutex.lock()
		if error_type == ERROR_TYPE_WARNING: warnings.append(msg)
		else: errors.append(msg)
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func take() -> Array:
		mutex.lock()
		var e := errors.duplicate()
		errors.clear()
		mutex.unlock()
		return e

const DT := 1.0 / 60.0

var args := {}
var main: Node
var catch := Catch.new()
var report := {"steps": 0, "lessons": 0, "errors": [], "warnings": []}

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	OS.add_logger(catch)
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	var boot := catch.take()
	for e in boot: report.errors.append("boot: " + str(e))
	_walk()

func _walk() -> void:
	var only: PackedStringArray = String(args.get("only", "")).split(",", false)
	main.hud.dismiss_start()
	main.set_app_mode("learn", {"quiet": true})
	var L = main.lessons
	# The walk must not write the learner's progress file, and must start from
	# nothing: a lesson marked done changes what resume() and the panel do.
	L.store = ""
	L.progress = {"done": {}, "last": null}

	for mod in Lessons.MODULES:
		for lesson in mod.lessons:
			var key := "%s/%s" % [mod.id, lesson.id]
			if not only.is_empty() and not only.has(key): continue
			report.lessons += 1
			# Walked IN ORDER with next(), not jumped to. A step's `do` block is a
			# patch on whatever the previous step left behind — "same scenario,
			# closer camera" is the normal case — so checking a step in isolation
			# would be checking something no learner ever sees.
			L.open_lesson(key)
			var steps: Array = lesson.steps
			for i in steps.size():
				var step: Dictionary = steps[i]
				var where := "%s#%d \"%s\"" % [key, i + 1, step.title]
				if i > 0: L.next()
				main.animate(DT)
				main.animate(DT)
				report.steps += 1
				_check(where, step)
				if args.get("selftest", "0") == "1" and report.steps == 1:
					push_warning("coursecheck selftest warning")
					push_error("coursecheck selftest push_error")
					_selftest_throw()
				# Two real frames, at the same fixed step, so the step is drawn too.
				main.frame(DT)
				await get_tree().process_frame
				main.frame(DT)
				await get_tree().process_frame
				for e in catch.take():
					report.errors.append("%s: %s" % [where, e])

	report.warnings = catch.warnings.duplicate()
	report.ok = report.errors.is_empty()
	for e in report.errors: print("COURSECHECK ERROR ", e)
	for w in report.warnings: print("COURSECHECK WARN  ", w)
	print("COURSE %dL %dS %dE" % [report.lessons, report.steps, report.errors.size()])
	if args.has("report"):
		var f := FileAccess.open(String(args.report), FileAccess.WRITE)
		if f: f.store_string(JSON.stringify(report, " "))
	OS.remove_logger(catch)
	get_tree().quit(0 if report.ok else 1)

func _selftest_throw() -> void:
	var nothing = null
	nothing.no_such_method()

func _check(where: String, step: Dictionary) -> void:
	var state = main.state
	var hud = main.hud
	var d: Dictionary = step.get("do", {}) if step.get("do") is Dictionary else {}
	if d.get("preset") and state.preset_key != d.preset:
		report.errors.append("%s: asked for scenario \"%s\", got \"%s\"" % [where, d.preset, state.preset_key])
	if d.get("focus"):
		var b = state.body_named(d.focus)
		if b == null:
			report.errors.append("%s: no body named \"%s\" in %s" % [where, d.focus, state.preset_key])
		elif state.focus_id != b.id:
			report.errors.append("%s: focus did not take" % where)
		# Is the camera actually OUTSIDE the thing the lesson is pointing at? A
		# viewing distance written for one size convention puts the camera
		# inside the planet under the other, and the symptom is a screen of flat
		# colour that looks like a shader bug.
		elif state.cam_mode == "orbit" and float(main.cam.radius) < b.radius_scene * 1.15:
			report.errors.append("%s: camera at %s is inside %s (drawn radius %s)" % [where,
				U.expo(float(main.cam.radius), 2), d.focus, U.expo(b.radius_scene, 2)])
	var act = step.get("act")
	if act is Dictionary and act.get("collapse") and state.body_named(act.collapse) == null:
		report.errors.append("%s: act targets missing body \"%s\"" % [where, act.collapse])
	if d.get("control") is Dictionary:
		for id in d.control:
			if hud.get_el(id) == null: report.errors.append("%s: no control \"%s\"" % [where, id])
	if d.get("panel") is Dictionary:
		for id in d.panel:
			if hud.get_el(id) == null: report.errors.append("%s: no panel \"%s\"" % [where, id])
	if d.get("preset") and not (d.preset in ["edu_galaxy", "edu_cluster", "blank"]) and state.bodies.is_empty():
		report.errors.append("%s: scenario \"%s\" built no bodies" % [where, d.preset])
