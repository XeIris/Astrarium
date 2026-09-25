class_name LessonUI
extends RefCounted

# ============================================================================
# THE COURSE, AS AN INTERFACE
# ----------------------------------------------------------------------------
# sim/lessons.gd is data and knows nothing about the page. This file is the
# other half: it renders the course, and it EXECUTES a step's `do` block
# against a small stage API that the orchestrator hands in. The split matters
# more than it looks — it is what stops the curriculum from turning into a
# pile of DOM code, and it means a lesson can ask for something the stage does
# not implement yet and simply not get it, instead of throwing.
#
# TWO SURFACES, ON PURPOSE:
#
#   THE PANEL (left column) is the map. Modules, lessons, what you have done,
#   and how far through you are. It takes the scenario list's slot because in
#   this mode the course IS how you choose what to look at.
#
#   THE CARD (bottom centre) is the lesson itself. It is wide rather than tall
#   because it is prose and prose needs a measure, and it is at the BOTTOM
#   because the thing it is talking about is the thing behind it — a panel
#   over the middle of the screen would be covering the argument.
#
# A step that carries an instrument gets a two-column card: the instrument on
# the left at a fixed 340 px, the text beside it. The instruments are live and
# are driven from the orchestrator's own frame loop through update(), because a
# light curve that only advances when you press Next is a picture of a light
# curve.
#
# PROGRESS IS PER-LESSON AND LIVES IN localStorage. A lesson counts as done
# when its last step has been seen. It is deliberately not a score: there is
# nothing to get wrong here, and the only thing the tick is for is finding
# your way back.
#
# THE PORT. The web card was markup in blackhole_sim.html filled through
# innerHTML; here the card's FRAME is built by ui/hud.gd (its `lc` parts — the
# crumb, count, title, text, media column, back / dots / next), and this file
# fills it, exactly as lessonui.js filled the page's elements. Everything is
# an El (ui/widgets/el.gd) styled from blackhole_sim.css's `.course-*` and
# `.lc-*` rules, so the card wraps, scrolls and measures as the page did.
#
# RICH TEXT. The bodies are HTML fragments, set with innerHTML. They use four
# tags — <p>, <em>, <strong>, <kbd> — and the card adds a <b> in the myth and
# look-for boxes; that is the whole of what is interpreted (`_html_blocks`).
# A <p> is a block El and `p + p` its 8 px; the inline tags become El runs
# (italic in the lighter colour, bold, and <kbd> as an inline-block box in the
# mono face), so line breaking and line boxes follow the same rules as every
# other line of text in the HUD. The FIGURES are SVG: Godot's loader draws the
# shapes, but has no <text>, so the labels are pulled out and set here in the
# page's own font (`Fig`).
#
# localStorage becomes a JSON file under user:// (opts.store; "" keeps the
# progress in memory only, which the checks use).
# ============================================================================

const T = preload("res://ui/theme.gd")
const C = preload("res://ui/hud_css.gd")
const STORE := "user://bh.course.v1.json"

static func create_lessons(opts: Dictionary) -> Course:
	return Course.new(opts)

# ----------------------------------------------------------------------------
# HTML → El runs. A fragment is a sequence of blocks (<p> or bare text), each a
# list of runs; whitespace collapses as HTML's does.
# ----------------------------------------------------------------------------
const EM := {"fi": true, "c": Color(0xe6 / 255.0, 0xec / 255.0, 0xf6 / 255.0)}
const STRONG := {"fw": 700}
# .lc-text kbd { font: 11px mono; padding: 1px 4px; border: 1px solid --border-strong; color: --text }
const KBD := {"ff": "mono", "fs": 11.0, "c": T.TEXT, "box": {"pt": 1, "pb": 1, "pl": 4, "pr": 4, "bw": 1, "bc": T.BORDER_STRONG}}

static func _decode(s: String) -> String:
	return s.replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&amp;", "&")

static func html_blocks(html: String) -> Array:
	var blocks: Array = []          # [{p: bool, runs: []}]
	var cur = null
	var stack: Array = []           # open inline tags
	var re := RegEx.create_from_string("<(/?)([a-zA-Z0-9]+)[^>]*>|[^<]+")
	var ws := RegEx.create_from_string("\\s+")
	for m in re.search_all(html):
		var tag := m.get_string(2)
		if tag != "":
			var closing := m.get_string(1) == "/"
			var t := tag.to_lower()
			if t == "p":
				if not closing:
					cur = {"p": true, "runs": []}
					blocks.append(cur)
				else:
					cur = null
			elif t == "br":
				if cur != null: cur.runs.append({"br": true})
			elif closing:
				var i := stack.rfind(t)
				if i >= 0: stack.remove_at(i)
			else:
				stack.append(t)
			continue
		var text := ws.sub(_decode(m.get_string(0)), " ", true)
		if cur == null:
			if text.strip_edges() == "": continue
			cur = {"p": false, "runs": []}
			blocks.append(cur)
		var run := {"t": text}
		for s in stack:
			match s:
				"em", "i": run.merge(EM, true)
				"strong", "b": run.merge(STRONG, true)
				"kbd": run.merge(KBD, true)
		cur.runs.append(run)
	# collapse: no leading space in a block, no double space across runs, no
	# trailing space at the end (it would hang anyway)
	for b in blocks:
		var prev_space := true
		for r in b.runs:
			if not r.has("t"): prev_space = true; continue
			var t: String = r.t
			if prev_space and t.begins_with(" ") and not r.has("box"): t = t.substr(1)
			r.t = t
			if t != "": prev_space = t.ends_with(" ")
		while not b.runs.is_empty() and b.runs[-1].has("t") and str(b.runs[-1].t).strip_edges() == "" and not b.runs[-1].has("box"):
			b.runs.pop_back()
		if not b.runs.is_empty() and b.runs[-1].has("t") and not b.runs[-1].has("box"):
			b.runs[-1].t = str(b.runs[-1].t).rstrip(" ")
	return blocks

# ----------------------------------------------------------------------------
# A FIGURE: `.lfig { width: 100%; max-width: 340px; height: auto; color:
# var(--text-dim) }`. The shapes are rasterised by Godot's SVG loader at the
# size the figure is drawn (× the display scale); the <text> elements, which
# the loader does not draw, are taken out first and set here, in the mono face
# the SVG inherits from the page, at the same user-unit coordinates.
# ----------------------------------------------------------------------------
class Fig extends El:
	var svg := ""
	var vb := Vector2(320, 150)
	var texts: Array = []
	var _tex: Texture2D = null
	var _tex_w := -1.0

	func _init(src: String) -> void:
		super({"maxw": 340.0, "clip": true})
		var cur := "#%s" % T.TEXT_DIM.to_html(false)
		var m := RegEx.create_from_string("viewBox=\"([^\"]+)\"").search(src)
		if m:
			var p := m.get_string(1).split(" ", false)
			vb = Vector2(float(p[2]), float(p[3]))
		set_style({"aspect": vb.y / vb.x})
		var tre := RegEx.create_from_string("<text([^>]*)>([\\s\\S]*?)</text>")
		for tm in tre.search_all(src):
			texts.append(_parse_text(tm.get_string(1), tm.get_string(2), cur))
		svg = tre.sub(src, "", true).replace("currentColor", cur)

	static func _attr(a: String, k: String, d: String = "") -> String:
		var m := RegEx.create_from_string("(?:^|\\s)" + k + "=\"([^\"]*)\"").search(a)
		return m.get_string(1) if m else d

	static func _parse_text(a: String, body: String, cur: String) -> Dictionary:
		var fill := _attr(a, "fill", "#000").replace("currentColor", cur)
		var col := Color.html(fill)
		col.a *= float(_attr(a, "opacity", "1"))
		var rot := 0.0
		var tr := _attr(a, "transform")
		if tr.begins_with("rotate("):
			rot = deg_to_rad(float(tr.substr(7).split(" ")[0]))
		var t := RegEx.create_from_string("\\s+").sub(body, " ", true).strip_edges()
		return {"x": float(_attr(a, "x", "0")), "y": float(_attr(a, "y", "0")), "t": LessonUI._decode(t),
			"anchor": _attr(a, "text-anchor", "start"), "c": col, "fs": float(_attr(a, "font-size", "16")), "rot": rot}

	func _draw_extra() -> void:
		if size.x <= 0.0: return
		var dpr := get_window().content_scale_factor if is_inside_tree() else 1.0
		var px := size.x * dpr
		if _tex == null or absf(px - _tex_w) > 0.5:
			var img := Image.new()
			if img.load_svg_from_string(svg, px / vb.x) == OK:
				_tex = ImageTexture.create_from_image(img)
			_tex_w = px
		Canvas2D.begin(self, vb.x)
		if _tex:
			draw_texture_rect(_tex, Rect2(Vector2.ZERO, vb), false)
		for t in texts:
			if t.rot != 0.0:
				Canvas2D.fill_text_rotated(self, t.t, t.x, t.y, t.rot, t.fs, t.c)
			else:
				var al: String = {"middle": "center", "end": "right"}.get(t.anchor, "left")
				Canvas2D.fill_text(self, t.t, t.x, t.y, t.fs, t.c, al)
		Canvas2D.end(self)

# ----------------------------------------------------------------------------
# An instrument's canvas: `.lc-canvas { width: 100%; max-width: 340px; height:
# auto; background: rgba(4,6,10,.55); border: 1px solid var(--border) }` over a
# backing store of w × h. The instrument paints into `plot`, a plain Control
# over the content box, because a signal-connected draw runs BEFORE the El's
# own _draw and the background would cover it.
# ----------------------------------------------------------------------------
class InstrCanvas extends El:
	var plot := Control.new()
	var bw := 340.0
	var bh := 210.0

	func _init(w: float, h: float) -> void:
		bw = w; bh = h
		super({"maxw": 340.0, "aspect": h / w, "bg": T.rgba(4, 6, 10, 0.55), "b": [1, T.BORDER]})
		plot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(plot)
		resized.connect(_fit)

	func _fit() -> void:
		plot.position = Vector2(1, 1)
		plot.size = size - Vector2(2, 2)
		plot.queue_redraw()

# A step dot: `.lc-dots > i { 7 × 7; border: 1px solid --border-strong;
# border-radius: 50% }`, `.seen` filled faintly, `.on` in the accent. Painted as
# a disc and a ring rather than through a 3.5 px-radius StyleBox, which at this
# size breaks its own anti-aliased border into dashes.
class Dot extends El:
	func _init() -> void:
		super({"w": 7.0, "h": 7.0})
		make_clickable()

	func _draw() -> void:
		var c := size * 0.5
		var fill := T.CLEAR
		var ring := T.BORDER_STRONG
		if has_state("seen"): fill = T.rgba(180, 200, 230, 0.35)
		if has_state("on"):
			fill = T.ACCENT; ring = T.ACCENT
		if fill.a > 0.0:
			draw_circle(c, 3.5, fill, true, -1.0, true)
		draw_arc(c, 3.0, 0.0, TAU, 32, ring, 1.0, true)

# An El whose text is underlined (`text-decoration: underline`, the reset link).
class Underlined extends El:
	func _draw_extra() -> void:
		var f := HudTheme.font(g("ff"), int(g("fw")), bool(g("fi")))
		var fs := gf("fs")
		var col: Color = g("c")
		var gp := get_global_transform().origin
		for ln in _lines:
			var w := 0.0
			for it in ln.items:
				if not it.a.get("sp", false): w = it.x + it.a.w
			var y := roundf(gp.y + gf("pt") + ln.top + ln.base) - gp.y + maxf(1.0, roundf(fs * 0.12))
			draw_rect(Rect2(gf("pl") + ln.off, y, w, 1.0), col)

# ============================================================================
# THE CONTROLLER — createLessons()'s closure, as an object
# ============================================================================
class Course extends RefCounted:
	var panel: El
	var card: El
	var stage: Dictionary
	var hud = null
	var lc: Dictionary = {}
	var store := LessonUI.STORE
	var progress := {"done": {}, "last": null}
	var key = null          # 'moduleId/lessonId'
	var step_ix := 0
	var instrument = null   # the name the current step asked for
	var open := {}          # which module accordions are open
	var built := {}
	var media_note: El = null
	var _mods: Array = []   # [{id, summary, blurb, items}]

	func _init(opts: Dictionary) -> void:
		panel = opts.get("panel")
		card = opts.get("card")
		stage = opts.get("stage", {})
		store = str(opts.get("store", LessonUI.STORE))
		hud = opts.get("hud", card.get_parent() if card else null)
		if hud != null and "lc" in hud:
			lc = hud.lc
		# .lc-text { max-width: 68ch } — `ch` is the advance of "0" in the text's
		# OWN face and size (the display stack at 13.5 px), measured, not assumed.
		if lc.has("text"):
			var disp := HudTheme.font_sized("disp", 400, false, 13.5)
			(lc.text as El).set_style({"maxw": 68.0 * HudTheme.adv_em(disp, "0".unicode_at(0)) * 13.5})
		_load_progress()

		# ---- the curriculum's own consistency check. No test runner exists here, so
		# this is it: a lesson that names a scenario nobody has written is a silent
		# dead end, and a console warning at boot is cheap.
		var missing: Array = []
		for k in Lessons.presets_used():
			if _has("has_preset") and not stage.has_preset.call(k): missing.append(k)
		if not missing.is_empty():
			push_warning("[course] lessons reference unknown scenarios: " + ", ".join(missing))

		if hud != null:
			if hud.has_signal("lesson_next"): hud.lesson_next.connect(next)
			if hud.has_signal("lesson_back"): hud.lesson_back.connect(prev)
			if hud.has_signal("lesson_close"): hud.lesson_close.connect(close)
		render_panel()
		_set_card_hidden(true)

	# ---- progress ----------------------------------------------------------------
	func _load_progress() -> void:
		progress = {"done": {}, "last": null}
		if store == "" or not FileAccess.file_exists(store): return
		var f := FileAccess.open(store, FileAccess.READ)
		if f == null: return
		var p = JSON.parse_string(f.get_as_text())
		if not (p is Dictionary): return
		var d = p.get("done")
		for e in Lessons.LESSON_ORDER:
			if d is Dictionary and d.get(e.key) == true: progress.done[e.key] = true
		var last = p.get("last")
		progress.last = last if last != null and Lessons.find_lesson(last) != null else null

	func _save_progress() -> void:
		if store == "": return
		var f := FileAccess.open(store, FileAccess.WRITE)
		if f: f.store_string(JSON.stringify(progress))

	# ---- the stage: a directive it does not implement is ignored, not thrown ------
	func _has(k: String) -> bool:
		return stage.has(k) and stage[k] is Callable and (stage[k] as Callable).is_valid()

	func _st(k: String, args: Array = []):
		if not _has(k): return null
		return (stage[k] as Callable).callv(args)

	# =========================================================================
	# THE PANEL
	# =========================================================================
	func _E(parent: Node, style: Dictionary = {}, text = null, vars: Array = []) -> El:
		var e := El.new(style, vars)
		if text is String: e.runs = [{"t": text}]
		elif text is Array: e.runs = text
		parent.add_child(e)
		return e

	func render_panel() -> void:
		if panel == null: return
		var done_count: int = progress.done.size()
		var pct := int(U.jround(100.0 * done_count / Lessons.LESSON_COUNT))
		var cur = Lessons.find_lesson(key) if key != null else null
		panel.touch()
		for k in panel.get_children():
			panel.remove_child(k)
			k.queue_free()
		_mods.clear()
		# A <details> parsed with `open` fires its own `toggle` event, and the
		# page's listener adds it to the set — so a module the learner has been
		# taken into STAYS open after they move on to another one. But the event
		# is a queued TASK: a panel re-rendered again in the same task (resume()
		# and then openLesson() from one script, say) replaces those elements
		# before it fires, and only the last render's modules join. So the join
		# is deferred to the end of the frame and made only by the latest render.
		var rendered_open: Array = []
		_render_gen += 1
		_commit_open.call_deferred(_render_gen, rendered_open)

		# .course-progress
		var prog := _E(panel, {"mb": 10.0})
		var bar := _E(prog, {"h": 4.0, "bg": T.rgba(180, 200, 230, 0.12)})
		_E(bar, {"wp": pct / 100.0, "h": 4.0, "bg": T.ACCENT})
		_E(prog, {"mt": 5.0, "fs": 10.0, "c": T.TEXT_DIM}, "%d of %d lessons · %d%%" % [done_count, Lessons.LESSON_COUNT, pct])

		# .course-continue
		var cont := _E(panel, C.button({"display": "block", "ib": false, "fit": false, "wp": 1.0, "mb": 10.0, "p": 7,
			"bg": T.ACCENT, "c": T.hexc(0x0a0c12), "b": [0, T.CLEAR], "ff": "mono", "fs": 11.0, "ls": C.em(0.04, 11)}),
			"Continue" if done_count > 0 else "Start the course", [["hover", {"bg": _bright(T.ACCENT)}]])
		cont.make_clickable()
		cont.pressed.connect(resume)

		# .course-mods
		var mods := _E(panel, {"display": "grid", "cols": [1.0], "gapr": 5.0})
		for m in Lessons.MODULES:
			var dn := 0
			for l in m.lessons:
				if progress.done.has("%s/%s" % [m.id, l.id]): dn += 1
			var is_open: bool = open.has(m.id) or (cur != null and cur.module.id == m.id)
			if is_open: rendered_open.append(m.id)
			var det := _E(mods, {"b": [1, T.BORDER], "minw": 0.0})
			var summ := _E(det, {"display": "flex", "ai": "center", "gapc": 7.0, "p": [6, 8], "c": T.TEXT_DIM, "fs": 11.0},
				null, [["hover", {"c": T.TEXT, "bg": T.rgba(180, 200, 230, 0.06)}],
					["open", {"c": T.TEXT, "bb": 1.0, "bcb": T.BORDER}], ["openhover", {"c": T.TEXT, "bg": T.rgba(180, 200, 230, 0.06)}]])
			summ.make_clickable()
			_E(summ, {"c": T.ACCENT, "w": 12.0, "ta": "center"}, str(m.icon))
			_E(summ, {"grow": 1.0, "shrink": 1.0, "basis": -1.0, "minw": 0.0}, str(m.title))
			_E(summ, {"fs": 9.0, "c": T.TEXT_DIM}, "%d/%d" % [dn, m.lessons.size()])
			var blurb := _E(det, {"p": [7, 9, 3, 9], "fs": 10.0, "lh": 1.5, "c": T.TEXT_DIM}, str(m.blurb))
			var items := _E(det, {"display": "grid", "cols": [1.0], "gapr": 3.0, "p": 5})
			for l in m.lessons:
				var k := "%s/%s" % [m.id, l.id]
				var d: bool = progress.done.has(k)
				var st := C.button({"display": "flex", "ib": false, "fit": false, "vc": false, "ai": "baseline", "gapc": 6.0,
					"wp": 1.0, "p": [5, 7], "bg": T.CLEAR, "b": [1, T.CLEAR], "c": T.TEXT_DIM, "ff": "mono", "fs": 11.0, "ta": "left"})
				if d: st.c = T.rgba(143, 224, 192, 0.85)
				var vars: Array = [["hover", {"c": T.TEXT, "bcol": T.BORDER_STRONG}],
					["active", {"bg": T.ACCENT_2, "c": Color.BLACK, "bcol": T.ACCENT_2}]]
				var btn := _E(items, st, null, vars)
				btn.make_clickable()
				btn.set_state("active", k == key)
				_E(btn, {"w": 9.0}, "✓" if d else "·")
				_E(btn, {"grow": 1.0, "shrink": 1.0, "basis": -1.0, "minw": 0.0}, str(l.title))
				_E(btn, {"fs": 9.0, "op": 0.7}, "%dm" % int(l.mins))
				btn.pressed.connect(open_lesson.bind(k))
			var rec := {"id": m.id, "summary": summ, "blurb": blurb, "items": items}
			_mods.append(rec)
			_set_mod_open(rec, is_open)
			summ.pressed.connect(func():
				var now := not bool(summ.has_state("open"))
				_set_mod_open(rec, now)
				if now: open[rec.id] = true
				else: open.erase(rec.id))

		# .course-reset
		var reset := Underlined.new(C.button({"display": "block", "ib": false, "fit": true, "ta": "left", "vc": false,
			"mt": 10.0, "bg": T.CLEAR, "b": [0, T.CLEAR], "p": 0, "c": T.TEXT_DIM, "ff": "mono", "fs": 9.0}),
			[["hover", {"c": T.WARN}]])
		reset.runs = [{"t": "reset progress"}]
		panel.add_child(reset)
		reset.make_clickable()
		reset.pressed.connect(func():
			progress.done = {}; progress.last = null; _save_progress(); render_panel())

	var _render_gen := 0

	func _commit_open(gen: int, ids: Array) -> void:
		if gen != _render_gen: return
		for id in ids: open[id] = true

	static func _bright(c: Color) -> Color:
		# filter: brightness(1.12)
		return Color(minf(c.r * 1.12, 1.0), minf(c.g * 1.12, 1.0), minf(c.b * 1.12, 1.0), c.a)

	func _set_mod_open(rec: Dictionary, on: bool) -> void:
		(rec.summary as El).set_state("open", on)
		(rec.blurb as El).visible = on
		(rec.items as El).visible = on
		(rec.summary as El).touch()

	# =========================================================================
	# THE CARD
	# =========================================================================
	func _set_card_hidden(h: bool) -> void:
		if hud != null and hud.has_method("set_shown"):
			hud.set_shown("lessonCard", not h)
		elif card:
			card.visible = not h

	func card_hidden() -> bool:
		return card == null or not card.visible

	func render_card() -> void:
		var found = Lessons.find_lesson(key) if key != null else null
		if found == null:
			_set_card_hidden(true)
			return
		var mod: Dictionary = found.module
		var lesson: Dictionary = found.lesson
		var step: Dictionary = lesson.steps[step_ix]
		var n: int = lesson.steps.size()
		var nb := Lessons.neighbours(key)

		_set_card_hidden(false)
		if hud != null and hud.has_method("set_lesson_media"):
			hud.set_lesson_media(step.get("instrument") != null or step.get("fig") != null)
		if lc.is_empty(): return

		lc.crumb.set_text("%s · %s" % [mod.title, lesson.title])
		lc.count.set_text("%d / %d" % [step_ix + 1, n])
		lc.title.set_text(str(step.title))

		var text: El = lc.text
		text.touch()
		for k in text.get_children():
			text.remove_child(k)
			k.queue_free()
		if step_ix == 0 and lesson.get("myth"):
			_E(text, {"bl": 2.0, "bcl": T.WARN, "p": [5, 0, 5, 9], "mb": 9.0, "fs": 12.5, "c": T.hexc(0xf2c2cc)},
				[{"t": "Commonly believed, and wrong:", "fw": 700, "c": T.WARN}, {"t": " " + str(lesson.myth)}])
		var first := true
		for b in LessonUI.html_blocks(str(step.get("body", ""))):
			# .lc-text p + p { margin-top: 8px }
			var st := {}
			if b.p and not first: st = {"mt": 8.0}
			first = false
			_E(text, st, b.runs)
		if step.get("look"):
			_E(text, {"bl": 2.0, "bcl": T.ACCENT_2, "p": [5, 0, 5, 9], "mt": 9.0, "fs": 12.5, "c": T.hexc(0xbcd8f5)},
				[{"t": "Look for", "fw": 700, "c": T.ACCENT_2}, {"t": " " + str(step.look)}])
		if step.get("act"):
			var act: Dictionary = step.act
			var ab := _E(text, C.button({"mt": 10.0, "p": [6, 14], "bg": T.WARN, "c": T.hexc(0x12070a), "b": [0, T.CLEAR],
				"ff": "mono", "fs": 11.0, "ls": C.em(0.04, 11)}), str(act.label), [["hover", {"bg": _bright(T.WARN)}]])
			ab.make_clickable()
			ab.pressed.connect(run_act.bind(act))
		(lc.cols as El).scroll_y = 0.0

		var dots: El = lc.dots
		dots.touch()
		for k in dots.get_children():
			dots.remove_child(k)
			k.queue_free()
		for i in n:
			var dot := LessonUI.Dot.new()
			dot.set_state("on", i == step_ix)
			dot.set_state("seen", i < step_ix)
			dots.add_child(dot)
			dot.pressed.connect(go_step.bind(i))

		(lc.back as El).set_state("disabled", step_ix == 0 and nb.prev == null)
		(lc.next as El).set_text("Next →" if step_ix < n - 1 else ("Next lesson →" if nb.next != null else "Finish"))

		set_media(step)

	# ---- the media column: an instrument, a diagram, or nothing at all
	func set_media(step: Dictionary) -> void:
		instrument = step.get("instrument")
		_drop_cutaway()
		media_note = null
		if lc.is_empty(): return
		var media: El = lc.media
		media.touch()
		for k in media.get_children():
			media.remove_child(k)
			k.queue_free()
		var fig = step.get("fig")
		if fig != null and Lessons.FIGURES.has(fig):
			media.add_child(LessonUI.Fig.new(Lessons.FIGURES[fig]))
			return
		if instrument == null: return

		var wrap := _E(media, {})
		# A new card owns a new canvas; readings restart with that step's view.
		var W := 340.0
		var H := 210.0
		if instrument == "cutaway":
			W = 320.0
		elif instrument == "hr":
			H = 260.0
		var cv: El
		if instrument == "cutaway":
			# A WebGLRenderer was bound to one canvas for life and this card builds
			# a fresh one per step, so the cutaway is rebuilt rather than
			# re-parented. Here the cutaway IS the canvas: an El carrying its own
			# SubViewport (sim/cutaway.gd), styled as the card's `.lc-canvas`.
			var cut := Cutaway.create_cutaway({"w": W, "h": H,
				"style": {"maxw": 340.0, "bg": T.rgba(4, 6, 10, 0.55), "b": [1, T.BORDER]}})
			wrap.add_child(cut)
			built.cutaway = cut
			cv = cut
		else:
			cv = LessonUI.InstrCanvas.new(W, H)
			wrap.add_child(cv)
		# The note is text for the 2D instruments, and for the cutaway a
		# container: the `.cut-legend` the frame hook fills once the body is
		# known (an El that carries text lays out only that text).
		var note := _E(wrap, {"mt": 5.0, "fs": 9.5, "c": T.TEXT_DIM, "lh": 1.45}, null if instrument == "cutaway" else "")
		if instrument == "cutaway":
			pass
		elif instrument == "photometer":
			built.photometer = LightCurve.create_photometer({"canvas": (cv as LessonUI.InstrCanvas).plot, "width": W, "height": H})
			note.set_text("")
		elif instrument == "gw":
			built.gw = GWDetector.create_gw_detector({"canvas": (cv as LessonUI.InstrCanvas).plot, "width": W, "height": H, "distMpc": 410.0})
			note.set_text("rescaled inspiral · ideal orientation at 410 Mpc · arm motion exaggerated")
		elif instrument == "hr":
			built.hr = HRDiagram.create_hr_diagram({"canvas": (cv as LessonUI.InstrCanvas).plot, "width": W, "height": H})
			note.set_text("the band is sampled from the interior model, not drawn")
		media_note = note

	# =========================================================================
	# EXECUTING A STEP
	# =========================================================================
	func apply_do(d) -> void:
		if not (d is Dictionary): return
		# Order matters and is not arbitrary. Loading a scenario resets the camera
		# and the focus, so anything that sets either must come after it; and
		# following a body reframes the view, so an explicit radius must come
		# after THAT. Getting this order wrong is invisible on the first frame and
		# obvious by the second.
		if d.get("preset") and _st("current_preset") != d.preset: _st("load_preset", [d.preset])
		# The curvature grid is OFF in the course unless a lesson asks for it. It
		# is a good picture of one specific idea and unexplained scenery in every
		# other lesson, and several scenarios switch it on by default — so the
		# course states what it wants rather than inheriting it.
		_st("set_mesh", [bool(d.get("mesh", false))])
		if d.get("sky"): _st("set_sky", [d.sky])
		if d.has("trueScale"): _st("set_true_scale", [bool(d.trueScale)])

		if d.has("paused"): _st("set_paused", [bool(d.paused)])
		if d.get("focus"): _st("set_focus", [d.focus])
		if d.get("cam"): _st("set_cam", [d.cam])
		# Entering surface mode chooses a default pace; the lesson overrides it.
		if d.has("timeScale"): _st("set_time_scale", [float(d.timeScale)])
		if d.has("band"): _st("set_band", [int(d.band)])
		if d.get("control"):
			for id in d.control: _st("set_control", [id, float(d.control[id])])
		# AFTER the controls, not before: `control: { lat: 66 }` moves the observer
		# to the Arctic Circle, and where noon is depends on the latitude it is
		# being asked about. Setting the time first put the Sun overhead for a
		# place the lesson was about to stop standing in.
		if d.has("localTime"):
			var lt = d.localTime
			_st("set_local_time", [float(lt) if (lt is int or lt is float) else lt])
		if d.get("panel"):
			for id in d.panel: _st("set_panel", [id, bool(d.panel[id])])
		if d.get("flare"): _st("flare", [d.flare])
		if d.get("collapse"): _st("collapse", [d.collapse])
		# A fresh scenario invalidates whatever the instruments had collected.
		if built.has("photometer"): built.photometer.reset()
		if built.has("gw"): built.gw.reset()

	# built.cutaway?.dispose(): its SubViewport renders every frame, so a card
	# that no longer shows it must free it rather than just forget it.
	func _drop_cutaway() -> void:
		if built.has("cutaway") and is_instance_valid(built.cutaway):
			built.cutaway.dispose()
		built.erase("cutaway")

	func run_act(act) -> void:
		if not (act is Dictionary): return
		if act.get("collapse"): _st("collapse", [act.collapse])
		if act.get("flare"): _st("flare", [act.flare])
		if act.get("preset"): _st("load_preset", [act.preset])

	# =========================================================================
	# NAVIGATION
	# =========================================================================
	func open_lesson(k, step: int = 0) -> void:
		var found = Lessons.find_lesson(k)
		if found == null: return
		key = k; step_ix = -1
		progress.last = k; _save_progress()
		go_step(step)
		render_panel()

	func go_step(i: int) -> void:
		var found = Lessons.find_lesson(key)
		if found == null: return
		var steps: Array = found.lesson.steps
		var target := maxi(0, mini(i, steps.size() - 1))
		# Forward steps preserve a running experiment. Back, dots and direct links
		# reconstruct its prerequisites, since each do block is only a patch.
		if step_ix < 0 or target != step_ix + 1:
			var d0 = steps[0].get("do")
			var initial: String = d0.get("preset") if d0 is Dictionary and d0.get("preset") else "edu_galaxy"
			_st("load_preset", [initial])
			_st("set_band", [3])
			_st("set_paused", [false])
			_st("set_control", ["speed", 1.0])
			_st("set_control", ["lat", 22.0])
			_st("set_panel", ["xsecPanel", false])
			_st("set_panel", ["coursePanel", true])
			for j in target + 1: apply_do(steps[j].get("do"))
		else:
			apply_do(steps[target].get("do"))
		step_ix = target
		render_card()
		if step_ix == steps.size() - 1 and not progress.done.has(key):
			progress.done[key] = true; _save_progress(); render_panel()

	func next() -> void:
		var found = Lessons.find_lesson(key)
		if found == null: return
		if step_ix < found.lesson.steps.size() - 1:
			go_step(step_ix + 1)
			return
		var nb := Lessons.neighbours(key)
		if nb.next != null: open_lesson(nb.next)
		else:
			_st("toast", ["That is the end of the course. Everything in it is still in the sandbox."])
			close()

	func prev() -> void:
		if step_ix > 0:
			go_step(step_ix - 1)
			return
		var nb := Lessons.neighbours(key)
		if nb.prev != null:
			var f = Lessons.find_lesson(nb.prev)
			open_lesson(nb.prev, f.lesson.steps.size() - 1)

	func close() -> void:
		key = null; instrument = null
		_set_card_hidden(true)
		_drop_cutaway()
		render_panel()

	# Where the course picks up. The lesson you were last on if you did not
	# finish it, otherwise the first one you have not done, otherwise the start.
	func resume() -> void:
		var unfinished = progress.last if progress.last != null and not progress.done.has(progress.last) else null
		var next_up = null
		for e in Lessons.LESSON_ORDER:
			if not progress.done.has(e.key):
				next_up = e; break
		if next_up == null: next_up = Lessons.LESSON_ORDER[0]
		open_lesson(unfinished if unfinished != null else next_up.key)

	var active: bool:
		get: return key != null
	var lesson_key:
		get: return key

	# =========================================================================
	# THE FRAME HOOK — the instruments are live, and have to be
	# =========================================================================
	func update(_dt: float) -> void:
		if instrument == null or card_hidden(): return
		var bodies: Array = _st("bodies") if _has("bodies") else []

		if instrument == "photometer" and built.has("photometer"):
			# The observer is the camera — see the header of sim/lightcurve.gd for
			# why that is the lesson rather than a shortcut. The camera lives in
			# scene units and the bodies in AU, so it is converted rather than
			# compared.
			var s: float = _st("scene_scale") if _has("scene_scale") else 1.0
			if not s: s = 1.0
			var cp = _st("cam_pos")
			var c := (cp as DVec3).scaled(1.0 / s) if cp is DVec3 else DVec3.new()
			var star = null
			for b in bodies:
				if b.luminosity != null and float(b.luminosity) > 0.0:
					star = b; break
			var u := c.clone()
			if star != null: u.sub_in(star.pos)
			if u.length_sq() < 1e-18: u.set_v(0.0, 0.0, 1.0)
			u.normalize_in()
			var ph = built.photometer
			var m: Dictionary = ph.sample(bodies, u, float(_st("sim_years") if _has("sim_years") else 0.0))
			ph.draw()
			if media_note:
				var a: float = ph.amplitude()
				media_note.set_text("deepest dip %d ppm · RV swing ±%s m/s" % [ph.depth_ppm(), U.fixed(a, 2) if a < 1.0 else U.fixed(a, 1)]
					+ (" · TRANSIT NOW" if not m.events.is_empty() else ""))
		elif instrument == "gw" and built.has("gw"):
			built.gw.sample(bodies)
			built.gw.draw()
		elif instrument == "hr" and built.has("hr"):
			built.hr.draw(bodies)
		elif instrument == "cutaway" and built.has("cutaway") and is_instance_valid(built.cutaway):
			var b = _st("focus_body") if _has("focus_body") else null
			if b == null:
				for x in bodies:
					if not x.structure.is_empty(): b = x; break
			var st: Dictionary = b.structure if b != null else {}
			if not st.is_empty() and not is_same(st, built.cutaway.structure):
				built.cutaway.show_structure(st)
				if media_note: built.cutaway.build_legend(media_note)
			built.cutaway.render(_dt)
