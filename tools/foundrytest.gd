extends Node

# ============================================================================
# THE FOUNDRY / CROSS-SECTION HARNESS — the Godot half of the side-by-side.
#
#   node tools/foundrytest.shots.mjs /tmp/fd/shots.json
#   PORT=8803 WEB_ROOT=<checkout> node tools/webref.mjs /tmp/fd/shots.json /tmp/fd/web
#   Godot --path . res://tools/foundrytest.tscn -- fix=/tmp/fd/web state=xsec_sun out=/tmp/fd/godot/xsec_sun.png
#
# The web shots isolate one panel at (20, 20) on the page background; this
# builds the same panel around the same component, fed from the fixture the
# web page dumped (<state>.json):
#   xsec_*  the cross-section panel exactly as ui/hud.gd builds it, with the
#           inspector created the way main.gd creates it (ONE mount, the
#           xsecCanvas slot) and the live editor synced to a Body carrying
#           the web body's fields. The structure is recomputed HERE from the
#           same structureOf query refreshStructure built on the web, so the
#           diagram is also a check on sim/structure.gd.
#   fd_*    a 300 px .panel with the Foundry in it, driven to the same type
#           and slider values.
# It prints the facts and verdict text beside the web's, the Foundry's spawn
# spec beside the one the web actually spawned, and the measured rects. The
# picture is rendered in a fixed 400 × 1400 SubViewport (the window may be
# smaller than the page) and saved to `out`.
#
#   behave=1   also runs the behaviour checks: dragging the mass-curve handle
#              past the TOV / Chandrasekhar limits must call on_edit with the
#              picked mass, and the slider drag must coalesce into one patch.
# ============================================================================

const T = preload("res://ui/theme.gd")
const C = preload("res://ui/hud_css.gd")

var args := {}
var d: Dictionary
var vp: SubViewport
var panel: El
var frame := 0
var frames := 6
var edits: Array = []
var foundry = null
var inspector = null
var live = null
var body: Body = null
var mounts := {}

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	frames = int(args.get("frames", "6"))
	if args.has("mid"): CrossSection.MIDDLE_EM = float(args.mid)
	if args.has("roundy"): CrossSection.ROUND_Y = args.roundy == "1"
	var state := str(args.get("state", "xsec_sun"))
	var f := FileAccess.open(str(args.get("fix", "")).path_join(state + ".json"), FileAccess.READ)
	if f == null:
		push_error("foundrytest: no fixture for " + state)
		get_tree().quit(1)
		return
	d = JSON.parse_string(f.get_as_text())
	HudBlur.enabled = false
	El.scrollbars = false
	get_window().content_scale_factor = 1.0

	vp = SubViewport.new()
	vp.size = Vector2i(400, 1400)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	add_child(vp)
	var root := Control.new()
	root.size = Vector2(vp.size)
	root.theme = T.theme()
	vp.add_child(root)
	var bg := ColorRect.new()
	bg.color = T.BG
	bg.size = Vector2(vp.size)
	root.add_child(bg)

	if state.begins_with("xsec"):
		_build_xsec(root)
	elif state.begins_with("cut"):
		_build_cut(root)
	else:
		_build_foundry(root)
	if args.get("behave", "0") == "1":
		_behaviour.call_deferred()

# ---- the cross-section panel, as ui/hud.gd's _build_xsec_panel -----------------
func _E(parent: Node, style: Dictionary = {}, text = null) -> El:
	return Foundry.E(parent, style, text)

func _build_xsec(root: Control) -> void:
	panel = _E(root, C.merge(C.panel(348.0), {"scroll": false}))
	panel.is_root = true
	var head := _E(panel, C.PANEL_HEAD)
	_E(head, C.merge(C.h3(true), {"grow": 1.0, "basis": 0.0, "minw": 0.0}), "Cross-section")
	Foundry.B(head, C.panel_close(), "✕")
	var name_el := _E(panel, {"fs": 11.0, "c": T.ACCENT, "ls": C.em(0.08, 11), "mb": 8.0, "up": true}, "—")
	var ed := _E(panel, {"b": [1, T.BORDER], "bl": 2.0, "bcl": T.ACCENT, "bg": Color(1, 1, 1, 0.02), "p": [9, 10, 2, 10], "mb": 10.0})
	_E(ed, C.merge(C.section_note(), {"mb": 9.0}), "Editing is the same operation as building — the object is re-derived and its limits rechecked immediately. The curve is R(M) for this body's own composition and spin; drag the handle along it. Dashed lines are where the model changes its mind about what this is.")
	mounts.liveEdit = _E(ed)
	for id in ["xsecCanvas", "xsecLegend", "xsecVerdict", "xsecFacts", "xsecNotes"]:
		var st := {}
		if id == "xsecCanvas": st = {"aspect": 260.0 / 330.0, "b": [1, T.BORDER], "bg": T.rgba(0, 0, 0, 0.42)}
		if id == "xsecLegend": st = {"aspect": 26.0 / 330.0, "m": [4, 0, 8, 0]}
		var e := _E(panel, st)
		e.el_id = id
		mounts[id] = e

	# exactly main.gd's calls
	inspector = Foundry.create_inspector({"mount": mounts.xsecCanvas})
	live = Foundry.create_live_editor({"mount": mounts.liveEdit, "on_edit": func(b, patch): edits.append(patch)})

	var q: Dictionary = d.q
	var st := Structure.structure_of(q)
	body = Body.new()
	var bd: Dictionary = d.body
	body.id = int(bd.id); body.name = str(bd.name); body.type = str(bd.type); body.mass = float(bd.mass)
	body.spin_frac = float(U.nz(bd.get("spinFrac"), 0.0))
	body.phase = bd.get("phase")
	body.composition = bd.get("composition")
	body.Z = float(U.nz(bd.get("Z"), 0.014))
	body.structure = st
	name_el.set_text("#%d %s" % [body.id, body.name])
	inspector.show(st, st.get("label"))
	if d.get("focus", false):
		live._toggle_focus()
	live.sync(body)

	print("label  web=%s  godot=%s" % [d.get("label"), st.get("label")])
	_compare_text("facts", d.facts, _facts_text(CrossSection.structure_facts(st)))
	var v = st.get("verdict")
	var vt := ""
	if v is Dictionary: vt = str(v.label).to_upper() + str(v.detail)
	_compare_text("verdict", [str(d.verdict).to_upper()], [vt.to_upper()])
	_compare_text("near", [str(d.near).replace("\n", " ").replace("  ", " ")], [live.near_el.get_text()])

static func _facts_text(F: Array) -> Array:
	var o: Array = []
	for kv in F: o.append(str(kv[0]) + str(kv[1]))
	return o

func _compare_text(what: String, web: Array, gd: Array) -> void:
	var ok := web.size() == gd.size()
	var W: Array = []
	for s in web:
		W.append(" ".join(str(s).split(" ", false)))
	var G: Array = []
	for s in gd:
		G.append(" ".join(str(s).split(" ", false)))
	for i in mini(W.size(), G.size()):
		if W[i] != G[i]:
			ok = false
			print("  %s[%d] web=%s | godot=%s" % [what, i, W[i], G[i]])
	print("%s %s (%d web / %d godot)" % [what, "MATCH" if ok else "DIFF", W.size(), G.size()])

# ---- the 3D cutaway ----------------------------------------------------------------
var cut: Cutaway
var cut_legend: El

func _build_cut(root: Control) -> void:
	# the same fixed canvas and legend the web shot places at (20, 20)
	panel = _E(root, {"w": 320.0})
	panel.is_root = true
	cut = Cutaway.create_cutaway({"style": {"bg": T.rgba(4, 6, 10, 0.55)}})
	panel.add_child(cut)
	cut_legend = _E(panel, {"fs": 12.0})
	cut.set_spin(false)
	cut.nudge(0.6)
	cut.show_structure(Structure.structure_of(d.q))
	cut.render(0.0)
	cut.build_legend(cut_legend)
	var mine: Array = []
	for r in cut.legend(): mine.append("%s %s" % [r.name, r.num])
	_compare_text("legend", d.legend, mine)

# ---- the Foundry ------------------------------------------------------------------
func _build_foundry(root: Control) -> void:
	panel = _E(root, C.merge(C.panel(300.0), {"scroll": false}))
	panel.is_root = true
	var m := _E(panel)
	var spawned: Array = []
	foundry = Foundry.create_foundry({"mount": m, "on_spawn": func(spec, st): spawned.append(spec)})
	foundry.set_type(str(d.type))
	var sl: Dictionary = d.slider
	foundry.rows.mass.set_value(float(sl.mass))
	foundry.rows.spin.set_value(float(sl.spin))
	foundry.rows.phase.set_value(float(sl.phase))
	foundry.rows.z.set_value(float(sl.Z))
	foundry.rows.comp.set_value(str(sl.comp))
	foundry.update()
	_compare_text("facts", d.facts, _facts_text(CrossSection.structure_facts(foundry.structure)))
	var v = foundry.structure.get("verdict")
	var became: String = "" if foundry.structure.get("type") == foundry.draft.type else "now a " + Foundry._type_label(foundry.structure.get("type"))
	var vt: String = (str(v.label) + became + str(v.detail)) if v is Dictionary else ""
	_compare_text("verdict", [str(d.verdict).to_upper()], [vt.to_upper()])
	print("draft web=%s" % JSON.stringify(d.draft))
	print("draft gd =%s" % JSON.stringify(foundry.draft))
	foundry.spawn()
	if d.get("spawn") != null and not spawned.is_empty():
		var ws: Dictionary = d.spawn
		var gs: Dictionary = spawned[0]
		var ok := true
		for k in ws:
			if k == "color": continue
			var a = ws[k]; var b = gs.get(k)
			var same: bool = (a is float or a is int) and (b is float or b is int) and absf(float(a) - float(b)) <= 1e-9 * maxf(absf(float(a)), 1e-300) \
				or str(a) == str(b)
			if not same:
				ok = false
				print("  spawn.%s web=%s godot=%s" % [k, a, b])
		for k in gs:
			if not ws.has(k):
				ok = false
				print("  spawn.%s only in godot = %s" % [k, gs[k]])
		print("spawn spec %s" % ("MATCH" if ok else "DIFF"))

# ---- behaviour ----------------------------------------------------------------------
func _behaviour() -> void:
	if live == null:
		return
	var curve: MassCurve = live.curve
	await get_tree().process_frame
	await get_tree().process_frame
	# Drag the handle from where it is to the far right of the curve, in steps,
	# as a pointer would: press, moves, release.
	var sz := curve.size
	var y := sz.y * 0.5
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT; ev.pressed = true; ev.position = Vector2(sz.x * 0.5, y)
	curve._gui_input(ev)
	for i in 10:
		var mv := InputEventMouseMotion.new()
		mv.position = Vector2(sz.x * (0.5 + 0.05 * (i + 1)), y)
		curve._gui_input(mv)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT; up.pressed = false; up.position = Vector2(sz.x - 2.0, y)
	curve._gui_input(up)
	await get_tree().create_timer(0.1).timeout
	print("behave: drag produced %d edit(s); last patch = %s" % [edits.size(), JSON.stringify(edits[-1] if not edits.is_empty() else {})])
	if not edits.is_empty():
		var m := float(edits[-1].mass)
		var st := Structure.structure_of(U.merged(d.q, {"mass": m}))
		print("behave: at the dragged mass %s the model says %s (%s): %s" % [CrossSection.fmt_mass(m), st.get("type"),
			st.get("verdict", {}).get("state") if st.get("verdict") is Dictionary else "stable", st.get("verdict", {}).get("label") if st.get("verdict") is Dictionary else ""])
		print("behave: nearest mark from the start = %s" % JSON.stringify(curve.nearest(body.mass)))

func _process(_dt: float) -> void:
	if panel == null:
		return
	panel.position = Vector2(20, 20)
	panel.layout(panel.gf("w"))
	El.any_dirty = false
	El.dirty_roots.clear()
	frame += 1
	if frame == frames:
		_report_rects()
	if frame == frames + 2:
		var out := str(args.get("out", ""))
		if out != "":
			DirAccess.make_dir_recursive_absolute(out.get_base_dir())
			vp.get_texture().get_image().save_png(out)
			print("wrote ", out)
		if args.get("behave", "0") == "1":
			await get_tree().create_timer(0.5).timeout
		get_tree().quit()

func _report_rects() -> void:
	var R: Dictionary = d.get("rects", {})
	var mine := {"xsecPanel": panel, "fdTest": panel}
	for k in mounts: mine[k] = mounts[k]
	if live:
		mine["leCurve"] = live.curve; mine["leNear"] = live.near_el; mine["leFocus"] = live.focus_btn
		mine["leComp"] = live.rows.comp
	if foundry:
		mine["fdXsec"] = foundry.xsec; mine["fdLegend"] = foundry.legend; mine["fdVerdict"] = foundry.verdict
		mine["fdFacts"] = foundry.facts; mine["fdLayerNote"] = foundry.notes; mine["fdSpawn"] = foundry.spawn_btn
		mine["fdComp"] = foundry.rows.comp
	for k in mine:
		var w = R.get(k)
		if w == null or (w[2] == 0 and w[3] == 0): continue
		var e: Control = mine[k]
		var gp := e.get_global_transform().origin
		print("rect %-12s web [%6.1f %6.1f %6.1f %6.1f]  godot [%6.1f %6.1f %6.1f %6.1f]  dy %+5.1f dh %+5.1f" % [k,
			w[0], w[1], w[2], w[3], gp.x, gp.y, e.size.x, e.size.y, gp.y - float(w[1]), e.size.y - float(w[3])])
