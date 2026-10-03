class_name Foundry
extends RefCounted

# THE OBJECT FOUNDRY: four inputs (mass, spin, composition, life burned) and
# everything shown is what sim/structure.gd derives from them. No outcome is
# scripted: a rocky planet's radius turns over near 300 M⊕; 13 M_J lights
# deuterium and 0.075 M☉ hydrogen; stars pass the Eddington, pair-instability and
# direct-collapse limits; a neutron star collapses at TOV (moved by spin); spin
# flattens anything along the Roche sequence to R_eq/R_pol = 3/2; life burned walks
# a star along its track to the onion.
#
# Built from HUD controls (ui/hud.gd's static builders). create_foundry,
# create_inspector and create_live_editor each return a class instance.

const T = preload("res://ui/theme.gd")

# Slider range in log10(M☉) per type, running past the thresholds both ways.
const MASS_RANGE := {
	"planet":      [-8.5, -1.6, -5.52],    # 0.01 M⊕ … 25 M_J   (default 1 M⊕)
	"gas-giant":   [-5.5, -0.7, -3.02],    # 0.3 M⊕  … 200 M_J  (default 1 M_J)
	"star":        [-1.4,  2.6,  0.0],     # 0.04    … 400 M☉   (default 1 M☉)
	"neutron":     [-0.5,  0.62, 0.146],   # 0.32    … 4.2 M☉   (default 1.4)
	"white-dwarf": [-1.1,  0.25, -0.22],   # 0.08    … 1.8 M☉   (default 0.6)
	"bh":          [ 0.0,  9.0,  1.0],     # 1       … 1e9 M☉   (default 10)
}

const TYPES := [
	{"id": "planet", "label": "Rocky planet", "sym": "·"},
	{"id": "gas-giant", "label": "Gas giant", "sym": "○"},
	{"id": "star", "label": "Star", "sym": "☉"},
	{"id": "neutron", "label": "Neutron star", "sym": "◉"},
	{"id": "white-dwarf", "label": "White dwarf", "sym": "◇"},
	{"id": "bh", "label": "Black hole", "sym": "●"},
]

# The unit follows the value, not the type (a "planet" past 13 M_J reads as what it
# has become).
static func mass_label(m: float) -> String:
	if m >= 0.02: return "%s M☉" % (U.fixed(m, 3) if m < 10.0 else U.prec(m, 3))
	if m / Structure.M_JUP_SUN >= 0.3: return "%s M_J" % U.fixed(m / Structure.M_JUP_SUN, 2)
	var me := m / Structure.M_EARTH_SUN
	return "%s M⊕" % (U.fixed(me, 2) if me < 10.0 else U.prec(me, 3))

# Every type the sim can hold maps onto one of the Foundry's mass ranges. A
# `world` is a rocky planet that happens to be the one you can stand on.
static func range_for(t) -> Array:
	var k: String = "planet" if t == "world" else str(t)
	return MASS_RANGE.get(k, MASS_RANGE.planet)

static func _type_label(id) -> String:
	for t in TYPES:
		if t.id == id: return t.label
	return str(id)

static func _slider(mn: float, mx: float, st: float, v: float) -> HudSlider:
	var r := HudSlider.new(mn, mx, st, v)
	r.inset = 2.0
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return r

# The parameter rows, shared by the Foundry and the live editor: editing runs the
# same model and reaches the same thresholds as building.
class ControlRows extends RefCounted:
	var mass: HudSlider
	var mass_val: Label
	var spin_row: Control
	var spin_label: Label
	var spin: HudSlider
	var spin_val: Label
	var comp_row: Control
	var comp: HudSelect
	var phase_row: Control
	var phase: HudSlider
	var phase_val: Label
	var z_row: Control
	var z: HudSlider
	var z_val: Label

	func _init(parent: Node, row_mb := 10.0) -> void:
		mass = Foundry._slider(-8.5, -1.6, 0.01, -5.52)
		var r := Hud.range_row(parent, "Mass", "Dragged far enough, this stops being a size control and starts being an identity control: mass is what decides whether an object is a planet, a brown dwarf, a star or a hole.", mass, "1.00 M⊕", row_mb)
		mass_val = r.val
		spin = Foundry._slider(0.0, 1.0, 0.005, 0.0)
		r = Hud.range_row(parent, "Spin", "As a fraction of the speed at which the body's own equator would be in orbit. 1.0 is mass shedding, and no rotating body can be flatter than R_eq/R_pol = 3/2.", spin, "0%", row_mb)
		spin_row = r.row; spin_label = r.label; spin_val = r.val
		comp = HudSelect.new("FdSelect")
		comp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var opts: Array = []
		for k in Structure.ROCK_COMPOSITIONS:
			opts.append([k, Structure.ROCK_COMPOSITIONS[k].label])
		comp.set_options(opts, "earth")
		r = Hud.range_row(parent, "Composition", "What the planet is made of. Every solid composition follows the same scaled mass-radius curve (Seager et al. 2007) and differs only in where it sits on it.", comp, null, row_mb)
		comp_row = r.row
		phase = Foundry._slider(-0.15, 1.95, 0.01, 0.5)
		r = Hud.range_row(parent, "Life burned", "How far through its life. Core hydrogen falls from 0.71 to zero across the main sequence, then burning moves to a shell and the star leaves it altogether.", phase, "Mid MS", row_mb)
		phase_row = r.row; phase_val = r.val
		z = Foundry._slider(0.0001, 0.04, 0.0005, 0.014)
		r = Hud.range_row(parent, "Metallicity Z", "Mass fraction in elements heavier than helium. Metal-poor gas is more transparent, so a metal-poor star is hotter and brighter — and needs slightly more mass to ignite at all.", z, "0.014", row_mb)
		z_row = r.row; z_val = r.val

	## A black hole has no surface to shed from, so its spin is the Kerr a*
	## rather than a fraction of break-up.
	func set_spin_label(bh: bool) -> void:
		spin_label.text = "Spin a*" if bh else "Spin"

# THE VERDICT BANNER, facts grid and layer notes. The banner's colour carries
# structure.gd's four states.
const VERDICT_LOOK := {
	"v-ok": {"c": 0x4ee39a},
	"v-warn": {"c": 0xffab52},
	"v-bad": {"c": 0xff5a4a, "bg": [255, 70, 50, 0.08]},
	"v-info": {"c": 0x6fb6ff, "bg": [110, 180, 255, 0.07]},
}

## The verdict banner: a bordered box in the state's colour, holding the label,
## what the body became, and the detail.
class Verdict extends PanelContainer:
	var label: Label
	var became: Label
	var detail: Label
	var _sig := ""
	var _cls := ""

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		Hud.m(self, 10.0, 8.0)
		var col := HudStack.new(false)
		add_child(col)
		label = Hud.m(Hud.label(col, "", {"fs": 10.0, "ls": 1.4, "up": true}, true), 0.0, 4.0)
		became = Hud.m(Hud.label(col, "", {"fs": 9.0, "ls": 0.9, "up": true}, true), 0.0, 5.0)
		became.modulate.a = 0.75
		detail = Hud.label(col, "", {"fs": 10.0, "lh": 1.55, "c": T.TEXT}, true)
		detail.modulate.a = 0.82
		set_state("v-ok")

	func set_state(cls: String) -> void:
		if cls == _cls: return
		_cls = cls
		var look: Dictionary = VERDICT_LOOK.get(cls, VERDICT_LOOK["v-ok"])
		var c := T.hexc(look.c)
		var bg := T.CLEAR
		if look.has("bg"): bg = T.rgba(look.bg[0], look.bg[1], look.bg[2], look.bg[3])
		add_theme_stylebox_override("panel", T.stylebox({"bg": bg, "bc": c, "pad": [8, 9, 8, 9]}))
		T.apply_label(label, {"fs": 10.0, "ls": 1.4, "up": true, "c": c, "lh": 1.55})
		T.apply_label(became, {"fs": 9.0, "ls": 0.9, "up": true, "c": c, "lh": 1.55})

	## Fill it from a structure verdict; an identical one rebuilds nothing.
	func show_verdict(v, became_text := "") -> void:
		var sig := var_to_str([v, became_text])
		if sig == _sig: return
		_sig = sig
		var state = v.get("state") if v is Dictionary else Structure.VERDICT.ok
		set_state(CrossSection.VERDICT_CLASS.get(state, "v-ok"))
		(label as Prose).say(str(v.get("label", "")) if v is Dictionary else "")
		(became as Prose).say(became_text)
		became.visible = became_text != ""
		(detail as Prose).say(str(v.get("detail", "")) if v is Dictionary else "")

## The derived-quantities grid: name and value per cell, two columns.
class Facts extends HudGrid:
	var _sig := ""
	func _init() -> void:
		super([1.0, 1.0], 10.0, 4.0)
		Hud.m(self, 0.0, 10.0)
	func show_facts(facts: Array) -> void:
		var sig := var_to_str(facts)
		if sig == _sig: return
		_sig = sig
		Hud._clear(self)
		for kv in facts:
			var cell := Hud.hbox(self, 6.0)
			# level with the value's first line when the value wraps
			var k := Hud.label(cell, kv[0], {"fs": 9.0, "c": T.TEXT_DIM, "lh": 11.0})
			k.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			var v := Hud.label(cell, kv[1], {"fs": 10.0, "c": T.ACCENT}, true)
			v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			T.unhang(v)

## The layer notes: each layer's name and what is known about it.
class Notes extends HudStack:
	var _sig := ""
	func _init() -> void:
		super(false)
		Hud.m(self, 0.0, 12.0)
	func show_notes(layers: Array) -> void:
		var sig: Array = []
		for L in layers: sig.append([L.get("name"), L.get("note")])
		var s := var_to_str(sig)
		if s == _sig: return
		_sig = s
		Hud._clear(self)
		var name_col := "#" + T.TEXT.to_html(false)
		for L in layers:
			var text := "[color=%s]%s[/color] — %s" % [name_col, Hud.esc(str(L.get("name", ""))), Hud.esc(str(L.get("note", "")))]
			Hud.m(Hud.rich_in(self, text, {"fs": 9.0, "c": T.TEXT_DIM, "lh": 1.6}), 0.0, 5.0)

# THE FOUNDRY
## createFoundry({ mount, onSpawn }). `on_spawn` is called with (spec, structure).
static func create_foundry(opts: Dictionary) -> FoundryPanel:
	return FoundryPanel.new(opts.get("mount"), opts.get("on_spawn", Callable()))

class FoundryPanel extends RefCounted:
	var mount: Control
	var on_spawn: Callable
	var draft := {
		"type": "planet",
		"mass": pow(10.0, Foundry.MASS_RANGE.planet[2]),
		"spinFrac": 0.0,
		"composition": "earth",
		"phase": 0.5,
		"Z": 0.014,
	}
	# Remember where the mass slider was left for each type, so flipping between
	# Star and Rocky planet does not silently reset a mass you chose.
	var last_mass := {}
	var structure: Dictionary = {}
	var type_btns := {}
	var rows: ControlRows
	var verdict: Verdict
	var facts: Facts
	var xsec: CrossSection.XsecCanvas
	var legend: CrossSection.LegendCanvas
	var notes: Notes
	var spawn_btn: HudButton

	func _init(m: Control, cb: Callable) -> void:
		mount = m
		on_spawn = cb
		for k in Foundry.MASS_RANGE:
			last_mass[k] = Foundry.MASS_RANGE[k][2]
		var grid := Hud.grid(mount, [1.0, 1.0, 1.0], 4.0, 4.0, 0.0, 12.0)
		for t in Foundry.TYPES:
			var col := VBoxContainer.new()
			col.add_theme_constant_override("separation", 3)
			var b := BoxButton.new("FdType", col)
			var sym := b.tint(Hud.label(col, t.sym, {"fs": 13.0, "lh": 1.0, "c": T.TEXT_DIM}))
			sym.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			var lab := b.tint(Hud.label(col, t.label, {"fs": 8.5, "ls": 0.34, "c": T.TEXT_DIM}))
			lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			grid.add_child(b)
			var id: String = t.id
			b.pressed.connect(set_type.bind(id))
			type_btns[id] = b
		rows = ControlRows.new(mount)
		verdict = Verdict.new()
		mount.add_child(verdict)
		facts = Facts.new()
		mount.add_child(facts)
		xsec = CrossSection.XsecCanvas.new(300.0, 230.0, T.rgba(0, 0, 0, 0.42), T.BORDER)
		mount.add_child(xsec)
		legend = CrossSection.LegendCanvas.new(300.0, 26.0)
		mount.add_child(Hud.m(legend, 4.0, 8.0))
		notes = Notes.new()
		mount.add_child(notes)
		spawn_btn = Hud.m(HudButton.new("Action", "Spawn into orbit"), 8.0)
		mount.add_child(spawn_btn)
		spawn_btn.pressed.connect(spawn)
		for r in [rows.mass, rows.spin, rows.phase, rows.z]:
			r.moved.connect(_on_moved)
		rows.comp.chosen.connect(_on_moved)
		set_type("planet")

	func _on_moved(_v) -> void:
		update()

	func set_type(id: String) -> void:
		last_mass[draft.type] = U.log10(draft.mass)
		draft.type = id
		var lo: float = Foundry.MASS_RANGE[id][0]
		var hi: float = Foundry.MASS_RANGE[id][1]
		var el := rows.mass
		el.min_value = lo; el.max_value = hi
		# Carry the mass across if the new type's range holds it (so a 0.01 M☉ "star"
		# is rejected on screen).
		var keep := minf(maxf(float(last_mass[id]), lo), hi)
		el.set_v(keep)
		draft.mass = pow(10.0, keep)
		for k in type_btns:
			type_btns[k].set_active(k == id)
		# Rows that only mean something for some types.
		rows.comp_row.visible = id == "planet"
		rows.phase_row.visible = id == "star"
		rows.z_row.visible = id == "star"
		rows.set_spin_label(id == "bh")
		update()

	func update() -> void:
		draft.mass = pow(10.0, rows.mass.value)
		draft.spinFrac = rows.spin.value
		draft.composition = rows.comp.value
		draft.phase = rows.phase.value
		draft.Z = rows.z.value

		rows.mass_val.text = Foundry.mass_label(draft.mass)
		rows.spin_val.text = U.fixed(draft.spinFrac, 3) if draft.type == "bh" else "%s%%" % U.fixed(draft.spinFrac * 100.0, 0)
		rows.phase_val.text = str(Structure.phase_at(draft.phase).label)
		rows.z_val.text = U.fixed(draft.Z, 4)

		structure = Structure.structure_of(draft)
		spawn_btn.disabled = not Structure.input_error(draft).is_empty()

		var v = structure.get("verdict")
		if not (v is Dictionary): v = {"state": Structure.VERDICT.ok, "label": "", "detail": ""}
		var became := ""
		if structure.get("type") != draft.type:
			became = "now a %s" % Foundry._type_label(structure.get("type"))
		verdict.show_verdict(v, became)
		facts.show_facts(CrossSection.structure_facts(structure))
		xsec.set_structure(structure, {"title": structure.get("label")})
		notes.show_notes(structure.get("layers", []))

	## The spec Spawn hands on, as the physics classified it (a 20 M_J "planet"
	## spawns as a brown dwarf).
	func spawn_spec() -> Dictionary:
		var s := {
			"type": structure.get("type"),
			"mass": structure.get("mass"),
			"spinFrac": draft.spinFrac,
			"composition": draft.composition,
			"Z": draft.Z,
			"name": str(structure.get("label")),
		}
		# Keep the phase for a derived star, so the spawned star is the one previewed.
		if structure.get("type") == "star": s["phase"] = draft.phase
		if structure.get("radiusKm") != null: s["radiusKm"] = structure.get("radiusKm")
		return s

	func spawn() -> void:
		if not Structure.input_error(draft).is_empty(): return
		if on_spawn.is_valid():
			on_spawn.call(spawn_spec(), structure)

	func refresh() -> void:
		update()

# An inspector for a live body: the canvas, legend, verdict, facts and notes, built
# in the one container it is given ({mount}).
static func create_inspector(opts: Dictionary) -> Inspector:
	return Inspector.new(opts.get("mount"))

class Inspector extends RefCounted:
	var canvas: CrossSection.XsecCanvas
	var legend: CrossSection.LegendCanvas
	var facts_el: Facts
	var verdict_el: Verdict
	var notes_el: Notes

	func _init(m: Control) -> void:
		canvas = CrossSection.XsecCanvas.new(330.0, 260.0, T.rgba(0, 0, 0, 0.42), T.BORDER)
		m.add_child(canvas)
		legend = CrossSection.LegendCanvas.new(330.0, 26.0)
		m.add_child(Hud.m(legend, 4.0, 8.0))
		verdict_el = Verdict.new()
		m.add_child(verdict_el)
		facts_el = Facts.new()
		m.add_child(facts_el)
		notes_el = Notes.new()
		m.add_child(notes_el)

	func show(st: Dictionary, title = null) -> void:
		if st.is_empty():
			return
		canvas.set_structure(st, {"title": title if title != null else st.get("label")})
		facts_el.show_facts(CrossSection.structure_facts(st))
		if st.get("verdict") is Dictionary:
			verdict_el.show_verdict(st.verdict)
		notes_el.show_notes(st.get("layers", []))

# THE LIVE EDITOR: the same inputs, on the focused body. Each move hands a patch to
# the orchestrator, which re-derives and rebuilds in place, so every threshold is
# live.
#   · The mass range widens to hold the body's actual value rather than snapping it.
#   · Sliders re-read the body each refresh, except the
#     one being dragged.
static func create_live_editor(opts: Dictionary) -> LiveEditor:
	return LiveEditor.new(opts.get("mount"), opts.get("on_edit", Callable()))

class LiveEditor extends RefCounted:
	const MIN_MS := 16
	var mount: Control
	var on_edit: Callable
	var curve: MassCurve
	var near_el: RichTextLabel
	var focus_btn: HudButton
	var rows: ControlRows
	var body = null           # the body being edited
	var dragging := ""        # id of the control currently under the pointer
	var last_id = null        # which body the controls are currently showing
	var pending = null        # patch coalesced between applies
	var _timer: SceneTreeTimer = null
	var _last_apply := -1000000

	func _init(m: Control, cb: Callable) -> void:
		mount = m
		on_edit = cb
		# The graph is a second view of the mass, not a second number: dragging its
		# handle emits exactly the patch the mass slider emits.
		curve = MassCurve.new(T.rgba(0, 0, 0, 0.42), T.BORDER)
		curve.on_pick = _on_pick
		curve.gui_input.connect(_on_curve_input)
		mount.add_child(curve)
		var bar := Hud.hbox(mount, 8.0, 5.0, 9.0)
		near_el = Hud.rich_in(bar, "", {"fs": 9.0, "c": T.TEXT_DIM, "lh": 1.4})
		near_el.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		near_el.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		focus_btn = HudButton.new("FocusLimit", "focus limit",
			"Narrow the graph to the nearest threshold, so the transition takes a whole drag instead of one pixel.")
		focus_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.add_child(focus_btn)
		focus_btn.pressed.connect(_toggle_focus)
		var holder := Hud.stack(mount)
		rows = ControlRows.new(holder, 8.0)
		var ids := {"leMass": rows.mass, "leSpin": rows.spin, "lePhase": rows.phase, "leZ": rows.z}
		for id in ids:
			var el: HudSlider = ids[id]
			el.gui_input.connect(_on_slider_input.bind(id))
			el.moved.connect(_on_slider_moved.bind(id))
		rows.comp.chosen.connect(_on_comp)

	func _on_comp(v: String) -> void:
		queue({"composition": v})

	func _on_pick(mass: float) -> void:
		dragging = "leCurve"
		queue({"mass": mass})

	func _on_curve_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			dragging = ""

	# pointerdown / pointerup: which control has hold of the thumb
	func _on_slider_input(e: InputEvent, id: String) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			dragging = id if e.pressed else ""

	func _on_slider_moved(v: float, id: String) -> void:
		dragging = id
		readouts()
		if id == "leMass": queue({"mass": pow(10.0, v)})
		elif id == "leSpin": queue({"spinFrac": v})
		elif id == "lePhase": queue({"phase": v})
		else: queue({"Z": v})

	# At most one apply per frame; patches are absolute, so drop the intermediates
	# but always land the last (the trailing timer).
	func _flush() -> void:
		_timer = null
		_last_apply = Time.get_ticks_msec()
		var p = pending
		pending = null
		if body != null and p != null and on_edit.is_valid():
			on_edit.call(body, p)

	func queue(patch: Dictionary) -> void:
		var p: Dictionary = pending if pending != null else {}
		p.merge(patch, true)
		pending = p
		if _timer != null:
			return
		var wait := MIN_MS - (Time.get_ticks_msec() - _last_apply)
		if wait <= 0 or not mount.is_inside_tree():
			_flush()
		else:
			_timer = mount.get_tree().create_timer(wait / 1000.0, true, false, true)
			_timer.timeout.connect(_flush)

	func readouts() -> void:
		var mm := pow(10.0, rows.mass.value)
		rows.mass_val.text = Foundry.mass_label(mm)
		var sp := rows.spin.value
		rows.spin_val.text = U.fixed(sp, 3) if _btype() == "bh" else "%s%%" % U.fixed(sp * 100.0, 0)
		rows.phase_val.text = str(Structure.phase_at(rows.phase.value).label)
		rows.z_val.text = U.fixed(rows.z.value, 4)

	func _btype() -> String:
		return str(body.type) if body != null else ""

	static func _phase_f(ph) -> float:
		if ph == null: return 0.5
		if ph is String: return float(Structure.phase_by_id(ph).f)
		return float(ph)

	func reject_edit(b: Body) -> void:
		dragging = ""
		pending = null
		sync(b)

	# Push the body's current state into the controls. Called on attach and on every
	# panel refresh; skips whatever the user has hold of.
	func sync(b) -> void:
		# Switching bodies always loads the new body's values.
		if b != null and b.id != last_id:
			last_id = b.id
			dragging = ""
		body = b
		if b == null:
			return
		var type: String = b.type
		var rg := Foundry.range_for(type)
		var lm := U.log10(maxf(b.mass, 1e-12))
		var el := rows.mass
		el.min_value = minf(rg[0], lm - 0.01)
		el.max_value = maxf(rg[1], lm + 0.01)
		# A black hole has no surface to shed from, so its spin is the Kerr a* rather
		# than a fraction of break-up, and it runs to the extremal limit.
		var bh := type == "bh"
		rows.spin.max_value = 0.998 if bh else 1.0
		if dragging != "leMass": el.set_v(lm)
		else: el.set_v(el.value)
		if dragging != "leSpin": rows.spin.set_v(float(b.spin_frac))
		if dragging != "lePhase": rows.phase.set_v(_phase_f(b.phase))
		if dragging != "leZ": rows.z.set_v(float(U.nz(b.Z, 0.014)))
		if dragging != "leComp": rows.comp.set_value(str(b.composition) if b.composition != null and str(b.composition) != "" else "earth")

		var rocky := type == "planet" or type == "world"
		rows.comp_row.visible = rocky
		rows.phase_row.visible = type == "star"
		rows.z_row.visible = type == "star"
		rows.set_spin_label(bh)
		readouts()
		_draw_curve(b)

	# Re-read live mass after edits and physical events.
	func _draw_curve(b) -> void:
		curve.draw_curve({
			"type": "planet" if b.type == "world" else b.type,
			"mass": b.mass, "spinFrac": b.spin_frac,
			"composition": b.composition, "phase": b.phase, "Z": U.nz(b.Z, 0.014),
		}, Foundry.range_for(b.type))
		var near = curve.nearest(b.mass)
		var t := "no threshold in range"
		if near != null:
			var lab := Hud.esc(str(near.label))
			if near.bad: lab = "[color=#%s]%s[/color]" % [T.WARN.to_html(false), lab]
			t = lab + Hud.esc(" at %s · %s dex %s" % [MassCurve.fmt_mass_short(near.mass),
				U.fixed(absf(U.log10(near.mass / b.mass)), 2), "below" if near.above else "away"])
		(near_el as Prose.Rich).say(t)

	func _toggle_focus() -> void:
		curve.set_focus(not curve.focus)
		focus_btn.set_active(curve.focus)
		focus_btn.set_label("full range" if curve.focus else "focus limit")
		if body != null: _draw_curve(body)
