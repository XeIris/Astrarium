extends Node

# ============================================================================
# THE COURSE HARNESS — the Godot half of the course's side-by-side check.
#
#   Godot --path godot res://tools/coursetest.tscn -- lesson=lives/giants steps=1 \
#       frames=30 out=/abs/x.png [dump=/abs/x.json] [w=1280 h=720] [dt=0.016667]
#
# It runs the REAL orchestrator (main.tscn) in Learn mode at CSS-pixel scale
# (content scale 1, the window at the page's size), resets the progress, opens
# the lesson and presses Next `steps` times — exactly what the web reference
# does with SIM.lessons.openLesson(key) and .next() — then runs `frames` fixed
# steps through main.frame(dt), so the instruments sample the live scene, and
# writes the root viewport. `dump` writes the instruments' own numbers and the
# card's measured rect beside it.
#
# The web side is godot/tools/course.shots.json through godot/tools/webref.mjs.
# ============================================================================

var args := {}
var main: Node
var n := 0
var frames := 30
var dt := 1.0 / 60.0
var _t0 := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	frames = int(args.get("frames", "30"))
	dt = float(args.get("dt", str(1.0 / 60.0)))
	main = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	var w := int(args.get("w", "1280")); var h := int(args.get("h", "720"))
	var win := get_window()
	win.content_scale_factor = 1.0
	win.size = Vector2i(w, h)
	HudBlur.enabled = args.get("blur", "1") != "0"
	El.scrollbars = args.get("sb", "0") == "1"
	await get_tree().process_frame
	main.resize()
	main._start("learn")
	var L = main.lessons
	L.store = ""
	L.progress = {"done": {}, "last": null}
	L.open = {}
	L.render_panel()
	if args.has("lesson"):
		L.open_lesson(args.lesson)
		for i in int(args.get("steps", "0")):
			L.next()
	_t0 = Time.get_ticks_msec()

func _process(_d: float) -> void:
	if main == null or _t0 == 0: return
	if n < frames:
		main.frame(dt)
		n += 1
		return
	if n == frames:
		n += 1
		_finish.call_deferred()

func _finish() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var out := str(args.get("out", "/tmp/coursetest.png"))
	img.save_png(out)
	if args.has("dump"):
		var L = main.lessons
		var d := {"lesson": L.key, "step": L.step_ix, "instrument": L.instrument, "preset": main.state.preset_key}
		if L.built.has("photometer"):
			var p = L.built.photometer
			d.photometer = {"depthPPM": p.depth_ppm(), "amplitude": p.amplitude(), "n": p.t.size(),
				"rel": p.last.rel, "rv": p.last.rv}
		if L.built.has("gw") and L.built.gw.last != null:
			var g: Dictionary = L.built.gw.last
			d.gw = {"fGW": g.fGW, "h0": g.h0, "Mc": g.Mc, "rSchwarz": g.rSchwarz, "n": L.built.gw.hs.size()}
		var card: Control = main.hud.lesson_card
		d.card = [card.position.x, card.position.y, card.size.x, card.size.y]
		var cp: Control = main.hud.course_panel
		d.panel = [cp.position.x, cp.position.y, cp.size.x, cp.size.y]
		var f := FileAccess.open(str(args.dump), FileAccess.WRITE)
		f.store_string(JSON.stringify(d, " "))
	print("coursetest: wrote ", out)
	get_tree().quit()
