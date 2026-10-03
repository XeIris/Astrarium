class_name LessonUI
extends RefCounted

# THE COURSE, AS AN INTERFACE. sim/lessons.gd is data; this renders it and executes
# a step's `do` block against the stage API the orchestrator hands in. A directive
# the stage doesn't implement is skipped, not thrown.
#
#   THE PANEL (left column) is the map: modules, lessons, progress. It takes the
#   scenario list's slot.
#   THE CARD (bottom centre) is the lesson: wide for prose, at the bottom so it
#   doesn't cover what it describes. A step with an instrument gets an instrument
#   column, driven every frame through update().
#
# Progress is per lesson (done once its last step is seen), stored as JSON under
# user:// (opts.store; "" keeps it in memory, for the checks).
#
# The card's frame is built by ui/hud.gd (`lc` parts); this fills it with HUD
# controls. Bodies are HTML fragments using <p>, <em>, <strong>, <kbd> (and <b> in
# the myth and look-for boxes), turned into BBCode by `html_bbcode`. Figures are
# SVG; Godot's loader has no <text>, so labels are pulled out and set here (`Fig`).

const T = preload("res://ui/theme.gd")
const JsonFile = preload("res://core/json_file.gd")
const STORE := "user://bh.course.v1.json"
const EM_COL := "e6ecf6"
const PROSE := {"ff": "disp", "fs": 13.5, "lh": 1.62}
# Authored requests are checked separately from optional runtime stage support.
const DO_KEYS := ["preset", "mesh", "sky", "trueScale", "paused", "focus", "cam",
	"timeScale", "band", "control", "localTime", "panel", "flare", "collapse"]

static func create_lessons(opts: Dictionary) -> Course:
	return Course.new(opts)

static func _decode(s: String) -> String:
	return s.replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&amp;", "&")

## An HTML fragment as paragraphs of BBCode: [{p: bool, bb: String}]. Whitespace
## collapses as HTML's does; <em> is italic in the light ink, <strong>/<b> bold,
## <kbd> a small mono key on a faint ground.
static func html_bbcode(html: String) -> Array:
	var blocks: Array = []
	var cur = null
	var re := RegEx.create_from_string("<(/?)([a-zA-Z0-9]+)[^>]*>|[^<]+")
	var ws := RegEx.create_from_string("\\s+")
	var open := {"em": "[i][color=#%s]" % EM_COL, "i": "[i][color=#%s]" % EM_COL, "strong": "[b]", "b": "[b]",
		"kbd": "[bgcolor=#ffffff14][code][font_size=11][color=#%s]" % T.TEXT.to_html(false)}
	var close := {"em": "[/color][/i]", "i": "[/color][/i]", "strong": "[/b]", "b": "[/b]",
		"kbd": "[/color][/font_size][/code][/bgcolor]"}
	var prev_space := true
	for m in re.search_all(html):
		var tag := m.get_string(2).to_lower()
		if tag != "":
			var closing := m.get_string(1) == "/"
			if tag == "p":
				if not closing:
					cur = {"p": true, "bb": ""}
					blocks.append(cur)
					prev_space = true
				else:
					cur = null
			elif tag == "br":
				if cur != null: cur.bb += "\n"; prev_space = true
			elif open.has(tag):
				if cur == null:
					cur = {"p": false, "bb": ""}
					blocks.append(cur)
				cur.bb += close[tag] if closing else open[tag]
			continue
		var text := ws.sub(_decode(m.get_string(0)), " ", true)
		if cur == null:
			if text.strip_edges() == "": continue
			cur = {"p": false, "bb": ""}
			blocks.append(cur)
			prev_space = true
		if prev_space and text.begins_with(" "): text = text.substr(1)
		if text != "": prev_space = text.ends_with(" ")
		cur.bb += Hud.esc(text)
	for b in blocks:
		b.bb = (b.bb as String).strip_edges(false, true)
	return blocks

# A figure, at most 340 px wide. Shapes are rasterised by the SVG loader at display
# scale; the <text> labels are set here in the mono face at the same coordinates.
class Fig extends HudCanvas:
	var svg := ""
	var vb := Vector2(320, 150)
	var texts: Array = []
	var _tex: Texture2D = null
	var _tex_w := -1.0

	func _init(src: String) -> void:
		super()
		clip_contents = true
		var cur := "#%s" % T.TEXT_DIM.to_html(false)
		var m := RegEx.create_from_string("viewBox=\"([^\"]+)\"").search(src)
		if m:
			var p := m.get_string(1).split(" ", false)
			vb = Vector2(float(p[2]), float(p[3]))
		set_aspect(vb.y / vb.x)
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

	func _draw_content() -> void:
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

# An instrument canvas (dark ground, border, the bitmap's aspect). Painting goes into
# `plot`, a Control over the content box.
class InstrCanvas extends HudCanvas:
	var plot := Control.new()

	func _init(w: float, h: float) -> void:
		super(h / w, -1.0, T.rgba(4, 6, 10, 0.55), T.BORDER)
		plot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(plot)
		resized.connect(_fit)

	func _fit() -> void:
		plot.position = Vector2(1, 1)
		plot.size = size - Vector2(2, 2)
		plot.queue_redraw()

# A step dot, 7 × 7: seen ones faint, the current one accent; pressing one goes to
# its step.
class Dot extends Control:
	signal pressed
	var on := false
	var seen := false

	func _init() -> void:
		custom_minimum_size = Vector2(7, 7)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			if not e.pressed and Rect2(Vector2.ZERO, size).has_point(e.position):
				pressed.emit()

	func _draw() -> void:
		var c := size * 0.5
		var fill := T.CLEAR
		var ring := T.BORDER_STRONG
		if seen: fill = T.rgba(180, 200, 230, 0.35)
		if on:
			fill = T.ACCENT; ring = T.ACCENT
		if fill.a > 0.0:
			draw_circle(c, 3.5, fill, true, -1.0, true)
		draw_arc(c, 3.0, 0.0, TAU, 32, ring, 1.0, true)

# A button whose text is underlined (the reset link).
class Underlined extends HudButton:
	func _draw() -> void:
		var f := get_theme_font("font")
		var fs := get_theme_font_size("font_size")
		var col := get_theme_color("font_hover_color" if is_hovered() else "font_color")
		var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var y := roundf((size.y + f.get_ascent(fs) - f.get_descent(fs)) * 0.5) + maxf(1.0, roundf(fs * 0.12))
		draw_rect(Rect2(0, y, w, 1.0), col)

## The course's progress bar: a 4 px track and its accent fill.
class Progress extends Control:
	var frac := 0.0
	func _init(f: float) -> void:
		frac = f
		custom_minimum_size.y = 4.0
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), T.rgba(180, 200, 230, 0.12))
		draw_rect(Rect2(0, 0, size.x * frac, size.y), T.ACCENT)

# THE CONTROLLER — createLessons()'s closure, as an object
class Course extends RefCounted:
	var panel: Control
	var card: Control
	var stage: Dictionary
	var hud = null
	var lc: Dictionary = {}
	var store := LessonUI.STORE
	var progress := {"done": {}, "last": null}
	var last_error := ""
	var _save_blocked := false
	var _blocked_reason := ""
	var key = null          # 'moduleId/lessonId'
	var step_ix := 0
	var instrument = null   # the name the current step asked for
	var open := {}          # which module accordions are open
	var built := {}
	## The instrument's caption (a Prose), or the cutaway's legend box.
	var media_note: Control = null
	var _mods: Array = []   # [{id, summary, body}]

	func _init(opts: Dictionary) -> void:
		panel = opts.get("panel")
		card = opts.get("card")
		stage = opts.get("stage", {})
		store = str(opts.get("store", LessonUI.STORE))
		hud = opts.get("hud", card.get_parent() if card else null)
		if hud != null and "lc" in hud:
			lc = hud.lc
		# a 68-character measure: `ch` is the advance of "0" in the prose face
		if lc.has("text"):
			var disp := T.font_sized("disp", 400, false, 13.5)
			lc.text.set_meta("maxw", 68.0 * T.adv_em(disp, "0".unicode_at(0)) * 13.5)
		_load_progress()

		# the curriculum's own consistency check: warn at boot about lessons naming
		# scenarios that don't exist
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

	# progress
	func _load_progress() -> void:
		progress = {"done": {}, "last": null}
		last_error = ""
		_save_blocked = false
		_blocked_reason = ""
		if store == "": return
		var result := JsonFile.read_dict(store, _valid_progress)
		if result.error == ERR_FILE_NOT_FOUND: return
		if result.error != OK:
			_progress_error(result.message + " Repair the file or Reset progress; automatic saving is paused.", true)
			return
		var p: Dictionary = result.data
		var unavailable: Array = []
		for key in p.done:
			if Lessons.find_lesson(key) == null: unavailable.append(str(key))
			elif p.done[key]: progress.done[key] = true
		var last = p.get("last")
		progress.last = last if last != null and Lessons.find_lesson(last) != null else null
		if last != null and progress.last == null: unavailable.append(str(last))
		_save_blocked = result.pending
		if result.pending: _blocked_reason = result.message + " Repair the file or Reset progress; automatic saving is paused."
		if result.message != "": _progress_error(result.message)
		if not result.pending and JsonFile.finish_recovery(store) != OK:
			_progress_error("Progress loaded, but recovery file %s.bak could not be removed; make its folder writable." % store)
		if not unavailable.is_empty(): _progress_error("Unavailable lessons in %s were ignored: %s." % [store, ", ".join(unavailable)])

	func _valid_progress(data: Dictionary) -> bool:
		if not data.get("done") is Dictionary or not data.has("last") or not (data.last == null or data.last is String): return false
		for value in data.done.values():
			if not value is bool: return false
		return true

	func _save_progress(reset_file := false) -> bool:
		if store == "": return true
		if _save_blocked:
			_progress_error(_blocked_reason)
			return false
		var result := JsonFile.write_dict(store, progress, false, Callable(), reset_file, _valid_progress)
		if result.error != OK:
			_progress_error(result.message)
			return false
		last_error = ""
		if result.message != "": _progress_error(result.message)
		return true

	func _progress_error(message: String, block: bool = false) -> void:
		_save_blocked = _save_blocked or block
		if block: _blocked_reason = message
		if last_error == message: return
		last_error = message
		push_warning(message)
		_st("toast", [message])

	# the stage: a directive it does not implement is ignored, not thrown
	func _has(k: String) -> bool:
		return stage.has(k) and stage[k] is Callable and (stage[k] as Callable).is_valid()

	func _st(k: String, args: Array = []):
		if not _has(k): return null
		return (stage[k] as Callable).callv(args)

	# THE PANEL
	func render_panel() -> void:
		if panel == null: return
		var done_count: int = progress.done.size()
		var pct := int(U.jround(100.0 * done_count / Lessons.LESSON_COUNT))
		var cur = Lessons.find_lesson(key) if key != null else null
		Hud._clear(panel)
		_mods.clear()
		# Modules the learner was taken into stay open. The join is deferred to the end
		# of the frame and done only by the latest render, since a re-render in the
		# same frame replaces the controls.
		var rendered_open: Array = []
		_render_gen += 1
		_commit_open.call_deferred(_render_gen, rendered_open)

		var prog := Hud.stack(panel, 0.0, 10.0)
		prog.add_child(LessonUI.Progress.new(pct / 100.0))
		Hud.m(Hud.label(prog, "%d of %d lessons · %d%%" % [done_count, Lessons.LESSON_COUNT, pct], {"fs": 10.0, "c": T.TEXT_DIM}), 5.0)

		var cont := HudButton.new("Continue", "Continue" if done_count > 0 else "Start the course")
		cont.set_meta("block", true)
		panel.add_child(Hud.m(cont, 0.0, 10.0))
		cont.pressed.connect(resume)

		var mods := VBoxContainer.new()
		mods.add_theme_constant_override("separation", 5)
		mods.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(mods)
		for m in Lessons.MODULES:
			var dn := 0
			for l in m.lessons:
				if progress.done.has("%s/%s" % [m.id, l.id]): dn += 1
			var is_open: bool = open.has(m.id) or (cur != null and cur.module.id == m.id)
			if is_open: rendered_open.append(m.id)
			var det := VBoxContainer.new()
			det.add_theme_constant_override("separation", 0)
			mods.add_child(Hud.frame(det, {"bc": T.BORDER}))
			var row := Hud.hbox(null, 7.0)
			var summ := BoxButton.new("ModHead", row)
			var icon := Hud.label(row, str(m.icon), {"fs": 11.0, "c": T.ACCENT})
			icon.custom_minimum_size.x = 12.0
			icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var tl := summ.tint(Hud.label(row, str(m.title), {"fs": 11.0, "c": T.TEXT_DIM}, true))
			tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var cnt := Hud.label(row, "%d/%d" % [dn, m.lessons.size()], {"fs": 9.0, "c": T.TEXT_DIM})
			cnt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			det.add_child(summ)
			var body := HudStack.new(false)
			det.add_child(body)
			var blurb := Hud.label(null, str(m.blurb), {"fs": 10.0, "lh": 1.5, "c": T.TEXT_DIM}, true)
			body.add_child(Hud.frame(blurb, {"bw": 0, "pad": [7, 9, 3, 9]}))
			var items := VBoxContainer.new()
			items.add_theme_constant_override("separation", 3)
			items.mouse_filter = Control.MOUSE_FILTER_IGNORE
			body.add_child(Hud.frame(items, {"bw": 0, "pad": [5, 5, 5, 5]}))
			for l in m.lessons:
				var k := "%s/%s" % [m.id, l.id]
				var d: bool = progress.done.has(k)
				var lrow := Hud.hbox(null, 6.0)
				var btn := BoxButton.new("LessonDone" if d else "LessonItem", lrow)
				var look: Dictionary = T.kind_look(btn.kind, "normal")
				var mark := btn.tint(Hud.label(lrow, "✓" if d else "·", {"fs": 11.0, "c": look.c}))
				mark.custom_minimum_size.x = 9.0
				mark.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
				var title := btn.tint(Hud.label(lrow, str(l.title), {"fs": 11.0, "c": look.c}, true))
				title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				title.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
				var mins := btn.tint(Hud.label(lrow, "%dm" % int(l.mins), {"fs": 9.0, "c": look.c}))
				mins.modulate.a = 0.7
				mins.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
				# the minutes sit on the title's first baseline
				Hud.m(mins, 2.0)
				btn.set_active(k == key)
				items.add_child(btn)
				btn.pressed.connect(open_lesson.bind(k))
			var rec := {"id": m.id, "summary": summ, "body": body}
			_mods.append(rec)
			_set_mod_open(rec, is_open)
			summ.pressed.connect(_toggle_mod.bind(rec))

		var reset := LessonUI.Underlined.new("Reset", "reset progress")
		reset.set_meta("block", true)
		reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		panel.add_child(Hud.m(reset, 10.0))
		reset.pressed.connect(_reset_progress)

	func _toggle_mod(rec: Dictionary) -> void:
		var now := not (rec.summary as BoxButton).active
		_set_mod_open(rec, now)
		if now: open[rec.id] = true
		else: open.erase(rec.id)

	func _reset_progress() -> void:
		var previous := progress.duplicate(true)
		var blocked := _save_blocked
		progress.done = {}; progress.last = null
		_save_blocked = false
		if not _save_progress(true):
			progress = previous
			_save_blocked = blocked
		else:
			_blocked_reason = ""
		render_panel()

	var _render_gen := 0

	func _commit_open(gen: int, ids: Array) -> void:
		if gen != _render_gen: return
		for id in ids: open[id] = true

	func _set_mod_open(rec: Dictionary, on: bool) -> void:
		(rec.summary as BoxButton).set_active(on)
		(rec.body as Control).visible = on

	# THE CARD
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

		(lc.crumb as Label).text = "%s · %s" % [mod.title, lesson.title]
		(lc.count as Label).text = "%d / %d" % [step_ix + 1, n]
		(lc.title as Prose).say(str(step.title))

		var text: Control = lc.text
		Hud._clear(text)
		var prose := LessonUI.PROSE.duplicate()
		prose.c = T.TEXT
		if step_ix == 0 and lesson.get("myth"):
			var myth := Hud.rich("[b][color=#%s]Commonly believed, and wrong:[/color][/b] %s" % [T.WARN.to_html(false), Hud.esc(str(lesson.myth))],
				{"ff": "disp", "fs": 12.5, "lh": 1.62, "c": T.hexc(0xf2c2cc)})
			text.add_child(Hud.m(Hud.frame(myth, {"bw": 0, "bl": 2, "bc": T.WARN, "pad": [5, 0, 5, 9]}), 0.0, 9.0))
		var first := true
		for b in LessonUI.html_bbcode(str(step.get("body", ""))):
			var r := Hud.rich_in(text, b.bb, prose)
			# a paragraph after a paragraph is 8 px down
			if b.p and not first: Hud.m(r, 8.0)
			first = false
		if step.get("look"):
			var look := Hud.rich("[b][color=#%s]Look for[/color][/b] %s" % [T.ACCENT_2.to_html(false), Hud.esc(str(step.look))],
				{"ff": "disp", "fs": 12.5, "lh": 1.62, "c": T.hexc(0xbcd8f5)})
			text.add_child(Hud.m(Hud.frame(look, {"bw": 0, "bl": 2, "bc": T.ACCENT_2, "pad": [5, 0, 5, 9]}), 9.0))
		if step.get("act"):
			var act: Dictionary = step.act
			var ab := HudButton.new("Act", str(act.label))
			ab.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			text.add_child(Hud.m(ab, 10.0))
			ab.pressed.connect(run_act.bind(act))
		if hud != null and hud.has_method("lesson_scroll_top"):
			hud.lesson_scroll_top()

		var dots: Control = lc.dots
		Hud._clear(dots)
		for i in n:
			var dot := LessonUI.Dot.new()
			dot.on = i == step_ix
			dot.seen = i < step_ix
			dots.add_child(dot)
			dot.pressed.connect(go_step.bind(i))

		(lc.back as HudButton).set_enabled(not (step_ix == 0 and nb.prev == null))
		(lc.next as HudButton).set_label("Next →" if step_ix < n - 1 else ("Next lesson →" if nb.next != null else "Finish"))

		set_media(step)

	# the media column: an instrument, a diagram, or nothing at all
	func set_media(step: Dictionary) -> void:
		instrument = step.get("instrument")
		_drop_cutaway()
		media_note = null
		if lc.is_empty(): return
		var media: Control = lc.media
		Hud._clear(media)
		var fig = step.get("fig")
		if fig != null and Lessons.FIGURES.has(fig):
			var fg := LessonUI.Fig.new(Lessons.FIGURES[fig])
			fg.set_meta("maxw", 340.0)
			media.add_child(fg)
			return
		if instrument == null: return

		var wrap := Hud.stack(media)
		# A new card owns a new canvas; readings restart with that step's view.
		var W := 340.0
		var H := 210.0
		if instrument == "cutaway":
			W = 320.0
		elif instrument == "hr":
			H = 260.0
		if instrument == "cutaway":
			# rebuilt per step; it carries its own SubViewport (sim/cutaway.gd)
			var cut := Cutaway.create_cutaway({"w": W, "h": H, "bg": T.rgba(4, 6, 10, 0.55), "border": T.BORDER})
			cut.set_meta("maxw", 340.0)
			wrap.add_child(cut)
			built.cutaway = cut
			media_note = Hud.stack(wrap, 4.0)
			return
		var cv := LessonUI.InstrCanvas.new(W, H)
		cv.set_meta("maxw", 340.0)
		wrap.add_child(cv)
		var note := Hud.m(Hud.label(wrap, "", {"fs": 9.5, "c": T.TEXT_DIM, "lh": 1.45}, true), 5.0) as Prose
		if instrument == "photometer":
			built.photometer = LightCurve.create_photometer({"canvas": cv.plot, "width": W, "height": H})
		elif instrument == "gw":
			built.gw = GWDetector.create_gw_detector({"canvas": cv.plot, "width": W, "height": H, "distMpc": 410.0})
			note.say("circular strain estimate · ideal orientation at 410 Mpc · arm motion exaggerated")
		elif instrument == "hr":
			built.hr = HRDiagram.create_hr_diagram({"canvas": cv.plot, "width": W, "height": H})
			note.say("the band is sampled from the interior model, not drawn")
		media_note = note

	# EXECUTING A STEP
	func apply_do(d) -> void:
		if not (d is Dictionary): return
		# Order matters: loading resets the camera and focus, and following a body reframes
		# the view, so an explicit radius comes after both.
		if d.get("preset") and _st("current_preset") != d.preset: _st("load_preset", [d.preset])
		# The curvature grid is off in the course unless a lesson asks for it.
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
		# Local time after the controls: noon depends on the latitude just set.
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

	# NAVIGATION
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

	# THE FRAME HOOK — the instruments are live, and have to be
	func update(_dt: float) -> void:
		if instrument == null or card_hidden(): return
		var bodies: Array = _st("bodies") if _has("bodies") else []

		if instrument == "photometer" and built.has("photometer"):
			# The observer is the camera (sim/lightcurve.gd); convert scene units to AU.
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
			if media_note is Prose:
				var a: float = ph.amplitude()
				(media_note as Prose).say("deepest dip %d ppm · RV swing ±%s m/s" % [ph.depth_ppm(), U.fixed(a, 2) if a < 1.0 else U.fixed(a, 1)]
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
