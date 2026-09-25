class_name Foundry
extends RefCounted

# ============================================================================
# THE OBJECT FOUNDRY — building a body out of physics rather than out of a menu
# ----------------------------------------------------------------------------
# The point of this panel is that it has no catalogue of outcomes in it. There
# is no rule anywhere saying "if mass > X show the explosion". There are four
# inputs — mass, spin, composition, and how much of its life it has burned —
# and everything you see is what sim/structure.gd derives from them. Which is
# why dragging one slider produces behaviour that was never scripted:
#
#   MASS on a rocky planet. The radius grows as M^⅓, flattens, and then at
#   about 300 M⊕ it STOPS and starts falling: electron degeneracy stiffens
#   faster than gravity loads it, so past one Jupiter mass a ball of rock gets
#   smaller the more rock you add. Keep going and at 13 M_J it lights
#   deuterium and the panel stops calling it a planet; at 0.075 M☉ it lights
#   hydrogen and it is a star.
#
#   MASS on a star. Colour tracks temperature all the way from a 2800 K red
#   dwarf to a 45 000 K O star, because both come from the same L and R. Past
#   ~150 M☉ its own radiation is pushing its outer layers off; between 140 and
#   260 M☉ the pair instability disassembles it completely, leaving nothing;
#   above that it collapses straight to a black hole without exploding at all.
#
#   MASS on a neutron star. Nothing happens, and then at the TOV mass
#   everything does — there is no pressure left anywhere in physics to hold it
#   up, and it becomes a black hole. Spin it first and the limit moves, because
#   centrifugal support is real support.
#
#   SPIN, on anything. The body flattens along the Roche sequence and its
#   equator cools relative to its poles, and at Ω = Ω_crit the equator is in
#   orbit and material leaves. That limit is R_eq/R_pol = 3/2 exactly, for
#   every object, which is why the slider can stop somewhere principled.
#
#   LIFE BURNED, on a star. The core hydrogen fraction falls, the mean
#   molecular weight rises, and the star brightens and swells along its track —
#   then leaves the main sequence entirely and becomes a subgiant, a red giant
#   with a degenerate helium core, and finally an onion of burning shells
#   around iron.
#
# PORT NOTES. The web built this panel as an HTML string and wired it with
# listeners; here it is built from El nodes (ui/widgets/el.gd) carrying the
# CSS's own computed styles — the `.fd-*`, `.le-*`, `.xsec-*` and `.row` rules
# of blackhole_sim.css — so the HUD's CSS layout places them exactly as the
# page did. The three factories keep their shape: create_foundry,
# create_inspector and create_live_editor each return an object (a class here,
# PORT_GUIDE.md §1) with the same members the JS returned.
# ============================================================================

const T = preload("res://ui/theme.gd")
const C = preload("res://ui/hud_css.gd")

# Slider range in log10(M☉) per type, chosen to run comfortably PAST the
# boundary in both directions — the thresholds are the interesting part, so
# every range has to be able to reach one.
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

# Mass readout picks its unit from the value, not from the type — a "rocky
# planet" dragged past 13 M_J is being reported in the units of what it has
# become.
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

# ============================================================================
# THE SHARED PIECES — every one an El with the page's computed style.
# ============================================================================
static func E(parent: Node, style: Dictionary = {}, text = null, vars: Array = []) -> El:
	var e := El.new(style, vars)
	if text is String:
		e.runs = [{"t": text}]
	elif text is Array:
		e.runs = text
	if parent != null:
		parent.add_child(e)
	return e

static func B(parent: Node, style: Dictionary, text, vars: Array = [], tip := "") -> El:
	var e := E(parent, style, text, vars)
	e.make_clickable(tip)
	return e

static func show_el(e: Control, on: bool) -> void:
	if e.visible == on:
		return
	e.visible = on
	if e is El:
		(e as El).touch()
	El.any_dirty = true

## A .row: label (with its title as a tooltip and the dotted underline
## `label[title]` draws), the control, and the `.val` readout.
static func _row(parent: El, label: String, tip: String, control: Control, val_text = null) -> Dictionary:
	var row := E(parent, C.ROW)
	var ls := C.ROW_LABEL.duplicate()
	if tip != "":
		ls.merge(C.ROW_LABEL_TITLE, true)
	var lab := E(row, ls, label)
	if tip != "":
		lab.tooltip_text = tip
		lab.mouse_filter = Control.MOUSE_FILTER_PASS
		lab.mouse_default_cursor_shape = Control.CURSOR_HELP
	row.add_child(control)
	var val: El = null
	if val_text != null:
		val = E(row, C.ROW_VAL, str(val_text))
	return {"row": row, "label": lab, "val": val}

static func _range(mn: float, mx: float, st: float, v: float) -> RangeInput:
	var r := RangeInput.new(C.ROW_RANGE)
	r.setup(mn, mx, st, v)
	return r

# The parameter rows, shared verbatim between the Foundry (building a body) and
# the live editor (changing one that already exists). They are the same four
# inputs in both places on purpose: editing an object in flight is not a
# different, weaker operation than making one — it runs the same interior model
# and reaches the same thresholds.
class ControlRows extends RefCounted:
	var mass: RangeInput
	var mass_val: El
	var spin_row: El
	var spin_label: El
	var spin: RangeInput
	var spin_val: El
	var comp_row: El
	var comp: SelectEl
	var phase_row: El
	var phase: RangeInput
	var phase_val: El
	var z_row: El
	var z: RangeInput
	var z_val: El

	func _init(parent: El) -> void:
		mass = Foundry._range(-8.5, -1.6, 0.01, -5.52)
		var r := Foundry._row(parent, "Mass", "Dragged far enough, this stops being a size control and starts being an identity control: mass is what decides whether an object is a planet, a brown dwarf, a star or a hole.", mass, "1.00 M⊕")
		mass_val = r.val
		spin = Foundry._range(0.0, 1.0, 0.005, 0.0)
		r = Foundry._row(parent, "Spin", "As a fraction of the speed at which the body's own equator would be in orbit. 1.0 is mass shedding, and no rotating body can be flatter than R_eq/R_pol = 3/2.", spin, "0%")
		spin_row = r.row; spin_label = r.label; spin_val = r.val
		comp = SelectEl.new()
		var opts: Array = []
		for k in Structure.ROCK_COMPOSITIONS:
			opts.append([k, Structure.ROCK_COMPOSITIONS[k].label])
		comp.set_options(opts)
		r = Foundry._row(parent, "Composition", "What the planet is made of. Every solid composition follows the same scaled mass-radius curve (Seager et al. 2007) and differs only in where it sits on it.", comp)
		comp_row = r.row
		phase = Foundry._range(-0.15, 1.95, 0.01, 0.5)
		r = Foundry._row(parent, "Life burned", "How far through its life. Core hydrogen falls from 0.71 to zero across the main sequence, then burning moves to a shell and the star leaves it altogether.", phase, "Mid MS")
		phase_row = r.row; phase_val = r.val
		z = Foundry._range(0.0001, 0.04, 0.0005, 0.014)
		r = Foundry._row(parent, "Metallicity Z", "Mass fraction in elements heavier than helium. Metal-poor gas is more transparent, so a metal-poor star is hotter and brighter — and needs slightly more mass to ignite at all.", z, "0.014")
		z_row = r.row; z_val = r.val

	## A black hole has no surface to shed from, so its spin is the Kerr a*
	## rather than a fraction of break-up.
	func set_spin_label(bh: bool) -> void:
		spin_label.set_text("Spin a*" if bh else "Spin")

# ---- the verdict banner, the facts grid, the layer notes -------------------------
# The verdict banner. Colour carries the same four states sim/structure.gd
# returns — stable, a warning, a transformation, or destruction — so the panel
# never has to editorialise beyond what the physics said.
const VERDICT_STYLE := {"b": [1, T.TEXT], "p": [8, 9], "m": [10, 0, 8, 0], "fs": 10.0, "lh": 1.55, "c": T.TEXT}
static var VERDICT_VARS := [
	["v-ok", {"c": T.hexc(0x4ee39a), "bcol": T.hexc(0x4ee39a)}],
	["v-warn", {"c": T.hexc(0xffab52), "bcol": T.hexc(0xffab52)}],
	["v-bad", {"c": T.hexc(0xff5a4a), "bcol": T.hexc(0xff5a4a), "bg": T.rgba(255, 70, 50, 0.08)}],
	["v-info", {"c": T.hexc(0x6fb6ff), "bcol": T.hexc(0x6fb6ff), "bg": T.rgba(110, 180, 255, 0.07)}],
]

## Give an element the .fd-verdict rule (a mount the HUD made, or our own).
static func verdict_box(e: El) -> El:
	e.set_style(VERDICT_STYLE)
	e.variants = []
	for v in VERDICT_VARS:
		e.variants.append([v[0], El._expand(v[1])])
	e._recompute()
	return e

static func fill_verdict(e: El, v, became := "") -> void:
	for c in e.get_children():
		if c is El:
			e.remove_child(c)
			c.queue_free()
	var state = v.get("state") if v is Dictionary else Structure.VERDICT.ok
	var cls: String = CrossSection.VERDICT_CLASS.get(state, "v-ok")
	for vv in VERDICT_VARS:
		e.set_state(vv[0], vv[0] == cls)
	E(e, {"fs": 10.0, "ls": C.em(0.14, 10), "up": true, "mb": 4.0}, str(v.get("label", "")) if v is Dictionary else "")
	if became != "":
		E(e, {"fs": 9.0, "ls": C.em(0.1, 9), "up": true, "op": 0.75, "mb": 5.0}, became)
	E(e, {"c": T.TEXT, "op": 0.82}, str(v.get("detail", "")) if v is Dictionary else "")
	e.touch()

const FACTS_STYLE := {"display": "grid", "cols": [1.0, 1.0], "gapr": 4.0, "gapc": 10.0, "mb": 10.0}

static func fill_facts(e: El, facts: Array) -> void:
	for c in e.get_children():
		if c is El:
			e.remove_child(c)
			c.queue_free()
	for kv in facts:
		var cell := E(e, {"display": "flex", "jc": "space-between", "ai": "baseline", "gapc": 6.0})
		E(cell, {"fs": 9.0, "c": T.TEXT_DIM, "nw": true}, kv[0])
		E(cell, {"fs": 10.0, "c": T.ACCENT, "ta": "right"}, kv[1])
	e.touch()

const NOTE_STYLE := {"fs": 9.0, "c": T.TEXT_DIM, "lh": 1.6, "mb": 12.0}

static func fill_notes(e: El, layers: Array) -> void:
	for c in e.get_children():
		if c is El:
			e.remove_child(c)
			c.queue_free()
	for L in layers:
		E(e, {"mb": 5.0}, [{"t": str(L.get("name", "")), "c": T.TEXT, "fw": 500}, {"t": " — " + str(L.get("note", ""))}])
	e.touch()

# ============================================================================
# THE FOUNDRY
# ============================================================================
## createFoundry({ mount, onSpawn }). `on_spawn` is called with (spec, structure).
static func create_foundry(opts: Dictionary) -> FoundryPanel:
	return FoundryPanel.new(opts.get("mount"), opts.get("on_spawn", Callable()))

class FoundryPanel extends RefCounted:
	var mount: El
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
	var verdict: El
	var facts: El
	var xsec: CrossSection.XsecCanvas
	var legend: CrossSection.LegendCanvas
	var notes: El
	var spawn_btn: El

	func _init(m: El, cb: Callable) -> void:
		mount = m
		on_spawn = cb
		for k in Foundry.MASS_RANGE:
			last_mass[k] = Foundry.MASS_RANGE[k][2]
		# --- type buttons
		var grid := Foundry.E(mount, {"display": "grid", "cols": [1.0, 1.0, 1.0], "gapc": 4.0, "gapr": 4.0, "mb": 12.0})
		for t in Foundry.TYPES:
			var b := Foundry.B(grid, C.button({"display": "flex", "dir": "column", "ai": "center", "gapr": 3.0,
				"p": [7, 2], "bg": T.CLEAR, "b": [1, T.BORDER], "c": T.TEXT_DIM, "ff": "mono", "fs": 8.5,
				"ls": C.em(0.04, 8.5), "ta": "center", "fit": false}), null,
				[["hover", {"c": T.TEXT, "bcol": T.BORDER_STRONG}],
				 ["active", {"bcol": T.ACCENT, "c": T.ACCENT, "bg": T.rgba(255, 140, 66, 0.08)}]])
			Foundry.E(b, {"fs": 13.0, "lh": 1.0}, t.sym)
			Foundry.E(b, {}, t.label)
			var id: String = t.id
			b.pressed.connect(func(): set_type(id))
			type_btns[id] = b
		rows = ControlRows.new(mount)
		verdict = Foundry.verdict_box(Foundry.E(mount))
		facts = Foundry.E(mount, Foundry.FACTS_STYLE)
		xsec = CrossSection.XsecCanvas.new(300.0, 230.0, {"b": [1, T.BORDER], "bg": T.rgba(0, 0, 0, 0.42)})
		mount.add_child(xsec)
		legend = CrossSection.LegendCanvas.new(300.0, 26.0, {"m": [4, 0, 8, 0]})
		mount.add_child(legend)
		notes = Foundry.E(mount, Foundry.NOTE_STYLE)
		spawn_btn = Foundry.B(mount, C.action_btn(), "Spawn into orbit", [["hover", C.ACTION_HOVER]])
		spawn_btn.pressed.connect(spawn)
		for r in [rows.mass, rows.spin, rows.phase, rows.z]:
			r.changed.connect(func(_v): update())
		rows.comp.changed.connect(func(_v): update())
		rows.comp.set_value("earth")
		set_type("planet")
		mount.touch()

	func set_type(id: String) -> void:
		last_mass[draft.type] = U.log10(draft.mass)
		draft.type = id
		var lo: float = Foundry.MASS_RANGE[id][0]
		var hi: float = Foundry.MASS_RANGE[id][1]
		var el := rows.mass
		el.vmin = lo; el.vmax = hi
		# Carry the mass across if the new type's range can hold it; this is what
		# makes "build a 0.01 M☉ planet, switch to Star, watch it be rejected"
		# work, which is a lesson rather than an error.
		var keep := minf(maxf(float(last_mass[id]), lo), hi)
		el.set_value(keep)
		draft.mass = pow(10.0, keep)
		for k in type_btns:
			type_btns[k].set_state("active", k == id)
		# Rows that only mean something for some types.
		Foundry.show_el(rows.comp_row, id == "planet")
		Foundry.show_el(rows.phase_row, id == "star")
		Foundry.show_el(rows.z_row, id == "star")
		rows.set_spin_label(id == "bh")
		update()

	func update() -> void:
		draft.mass = pow(10.0, rows.mass.value)
		draft.spinFrac = rows.spin.value
		draft.composition = rows.comp.value
		draft.phase = rows.phase.value
		draft.Z = rows.z.value

		rows.mass_val.set_text(Foundry.mass_label(draft.mass))
		rows.spin_val.set_text(U.fixed(draft.spinFrac, 3) if draft.type == "bh" else "%s%%" % U.fixed(draft.spinFrac * 100.0, 0))
		rows.phase_val.set_text(str(Structure.phase_at(draft.phase).label))
		rows.z_val.set_text(U.fixed(draft.Z, 4))

		structure = Structure.structure_of(draft)

		# --- verdict banner
		var v = structure.get("verdict")
		if not (v is Dictionary): v = {"state": Structure.VERDICT.ok, "label": "", "detail": ""}
		var became := ""
		if structure.get("type") != draft.type:
			became = "now a %s" % Foundry._type_label(structure.get("type"))
		Foundry.fill_verdict(verdict, v, became)

		# --- derived quantities
		Foundry.fill_facts(facts, CrossSection.structure_facts(structure))
		xsec.set_structure(structure, {"title": structure.get("label")})
		Foundry.fill_notes(notes, structure.get("layers", []))

	## The spec the Spawn button hands on_spawn — what it ACTUALLY IS, not what
	## the type buttons say. A 20 M_J "rocky planet" goes into the scene as a
	## brown dwarf, because that is what the physics returned.
	func spawn_spec() -> Dictionary:
		var s := {
			"type": structure.get("type"),
			"mass": structure.get("mass"),
			"spinFrac": draft.spinFrac,
			"composition": draft.composition,
			"Z": draft.Z,
			"name": str(structure.get("label")),
		}
		# The derived type, not the button: a gas giant dragged past the
		# hydrogen limit is previewed as a star AT THIS PHASE, and dropping the
		# phase here would spawn a different star from the one you were shown.
		if structure.get("type") == "star": s["phase"] = draft.phase
		if structure.get("radiusKm") != null: s["radiusKm"] = structure.get("radiusKm")
		return s

	func spawn() -> void:
		if on_spawn.is_valid():
			on_spawn.call(spawn_spec(), structure)

	func refresh() -> void:
		update()

# ============================================================================
# A standalone inspector for a body that already exists in the scene — the same
# diagram and the same facts, but reading a live body instead of a draft.
#
# The web wrote into five elements the page already had (canvas, legend,
# verdict, facts, notes). Pass them as {canvas, legend, verdict, facts, notes}
# — the HUD's mounts xsecCanvas / xsecLegend / xsecVerdict / xsecFacts /
# xsecNotes — or pass ONE {mount}: an empty container gets all five built
# inside it; the HUD's xsecCanvas slot (an El with an aspect ratio) is taken
# as the canvas and its siblings are found by those ids.
# ============================================================================
static func create_inspector(opts: Dictionary) -> Inspector:
	return Inspector.new(opts)

class Inspector extends RefCounted:
	var canvas: CrossSection.XsecCanvas
	var legend: CrossSection.LegendCanvas
	var facts_el: El
	var verdict_el: El
	var notes_el: El

	func _init(o: Dictionary) -> void:
		var slots := {"canvas": o.get("canvas"), "legend": o.get("legend"), "verdict": o.get("verdict"),
			"facts": o.get("facts"), "notes": o.get("notes")}
		var m = o.get("mount")
		if m is El and slots.canvas == null:
			if (m as El).gf("aspect") > 0.0 and m.get_parent() != null:
				slots.canvas = m
				for c in m.get_parent().get_children():
					if not (c is El): continue
					match (c as El).el_id:
						"xsecLegend": slots.legend = c
						"xsecVerdict": slots.verdict = c
						"xsecFacts": slots.facts = c
						"xsecNotes": slots.notes = c
			else:
				# build the page's own sequence inside the one container
				slots.canvas = Foundry.E(m, {"aspect": 260.0 / 330.0, "b": [1, T.BORDER], "bg": T.rgba(0, 0, 0, 0.42)})
				slots.legend = Foundry.E(m, {"aspect": 26.0 / 330.0, "m": [4, 0, 8, 0]})
				slots.verdict = Foundry.E(m)
				slots.facts = Foundry.E(m)
				slots.notes = Foundry.E(m)
		# The HUD's canvas slots already carry the canvas's border and sizing;
		# the bitmap goes inside, filling the content box.
		if slots.canvas != null:
			canvas = CrossSection.XsecCanvas.new(330.0, 260.0)
			slots.canvas.add_child(canvas)
		if slots.legend != null:
			legend = CrossSection.LegendCanvas.new(330.0, 26.0)
			slots.legend.add_child(legend)
		if slots.verdict != null:
			verdict_el = Foundry.verdict_box(slots.verdict)
		if slots.facts != null:
			facts_el = slots.facts
			facts_el.set_style(Foundry.FACTS_STYLE)
		if slots.notes != null:
			notes_el = slots.notes
			notes_el.set_style(Foundry.NOTE_STYLE)

	func show(st: Dictionary, title = null) -> void:
		if st.is_empty():
			return
		if canvas:
			canvas.set_structure(st, {"title": title if title != null else st.get("label")})
		if facts_el:
			Foundry.fill_facts(facts_el, CrossSection.structure_facts(st))
		if verdict_el and st.get("verdict") is Dictionary:
			Foundry.fill_verdict(verdict_el, st.verdict)
		if notes_el:
			Foundry.fill_notes(notes_el, st.get("layers", []))

# ============================================================================
# THE LIVE EDITOR — the same four inputs, pointed at a body already in flight
# ----------------------------------------------------------------------------
# Spawning and editing differ only in what is preserved. This panel holds no
# draft: it reads the focused body, and every slider move hands a patch back to
# the orchestrator, which re-derives the object and rebuilds its meshes in
# place. So the thresholds are all still live — drag a neutron star past the
# TOV mass and it collapses under you, spin a star to break-up and it flattens
# and its equator cools while it is still orbiting.
#
# Two details that are not obvious:
#
#   · The mass slider's range comes from the type, but a body can already sit
#     outside it (a catalogue supergiant, a body that has been eating). The
#     range is widened to contain what is actually there rather than snapping
#     the value — an editor that silently changed the thing you opened it on
#     would be worse than no editor.
#   · Mass changes continuously in this sim, because accretion is continuous.
#     The sliders re-read the body every refresh, EXCEPT the one being dragged:
#     nothing is more annoying than a control that fights your thumb.
# ============================================================================
static func create_live_editor(opts: Dictionary) -> LiveEditor:
	return LiveEditor.new(opts.get("mount"), opts.get("on_edit", Callable()))

class LiveEditor extends RefCounted:
	const MIN_MS := 16
	var mount: El
	var on_edit: Callable
	var curve: MassCurve
	var near_el: El
	var focus_btn: El
	var rows: ControlRows
	var body = null           # the body being edited
	var dragging := ""        # id of the control currently under the pointer
	var last_id = null        # which body the controls are currently showing
	var pending = null        # patch coalesced between applies
	var _timer: SceneTreeTimer = null
	var _last_apply := -1000000

	func _init(m: El, cb: Callable) -> void:
		mount = m
		on_edit = cb
		# The graph is a second view of the mass, not a second number: dragging
		# its handle emits exactly the patch the mass slider emits.
		curve = MassCurve.new({"b": [1, T.BORDER], "bg": T.rgba(0, 0, 0, 0.42)})
		curve.on_pick = func(mass: float) -> void:
			dragging = "leCurve"
			queue({"mass": mass})
		curve.gui_input.connect(func(e):
			if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
				dragging = "")
		mount.add_child(curve)
		var bar := Foundry.E(mount, {"display": "flex", "ai": "center", "jc": "space-between", "gapc": 8.0,
			"m": [5, 0, 9, 0], "fs": 9.0, "c": T.TEXT_DIM})
		near_el = Foundry.E(bar, {"lh": 1.4}, "")
		focus_btn = Foundry.B(bar, C.button({"grow": 0.0, "shrink": 0.0, "bg": T.CLEAR, "b": [1, T.BORDER_STRONG],
			"c": T.TEXT_DIM, "ff": "mono", "fs": 9.0, "p": [2, 6], "ls": C.em(0.08, 9)}), "focus limit",
			[["hover", {"c": T.TEXT, "bcol": T.ACCENT}], ["on", {"c": T.BG, "bg": T.ACCENT, "bcol": T.ACCENT}]],
			"Narrow the graph to the nearest threshold, so the transition takes a whole drag instead of one pixel.")
		focus_btn.pressed.connect(_toggle_focus)
		var holder := Foundry.E(mount)
		rows = ControlRows.new(holder)
		# `.xsec-edit .row { margin-bottom: 8px }`
		for r in holder.get_children():
			if r is El: r.set_style({"mb": 8.0})
		var ids := {"leMass": rows.mass, "leSpin": rows.spin, "lePhase": rows.phase, "leZ": rows.z}
		for id in ids:
			var el: RangeInput = ids[id]
			el.gui_input.connect(func(e):
				# pointerdown / pointerup: which control has hold of the thumb
				if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
					dragging = id if e.pressed else "")
			el.changed.connect(func(v: float):
				dragging = id
				readouts()
				if id == "leMass": queue({"mass": pow(10.0, v)})
				elif id == "leSpin": queue({"spinFrac": v})
				elif id == "lePhase": queue({"phase": v})
				else: queue({"Z": v}))
		rows.comp.changed.connect(func(v): queue({"composition": v}))
		mount.touch()

	# At most one apply per frame-length. A slider emits events far faster than a
	# visual can be torn down and rebuilt, and every patch is absolute rather
	# than incremental, so dropping the intermediate ones costs nothing — but the
	# LAST one must always land, hence the trailing timer.
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
		var m := pow(10.0, rows.mass.value)
		rows.mass_val.set_text(Foundry.mass_label(m))
		var sp := rows.spin.value
		rows.spin_val.set_text(U.fixed(sp, 3) if _btype() == "bh" else "%s%%" % U.fixed(sp * 100.0, 0))
		rows.phase_val.set_text(str(Structure.phase_at(rows.phase.value).label))
		rows.z_val.set_text(U.fixed(rows.z.value, 4))

	func _btype() -> String:
		return str(body.type) if body != null else ""

	static func _phase_f(ph) -> float:
		if ph == null: return 0.5
		if ph is String: return float(Structure.phase_by_id(ph).f)
		return float(ph)

	# Push the body's current state into the controls. Called on attach and on
	# every panel refresh; skips whatever the user has hold of.
	func sync(b) -> void:
		# Switching to a different body always loads that body's values, whatever
		# the pointer is doing — the alternative is a slider still holding the last
		# object's number while the panel names a new one.
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
		el.vmin = minf(rg[0], lm - 0.01)
		el.vmax = maxf(rg[1], lm + 0.01)
		# A black hole has no surface to shed from, so its spin is the Kerr a*
		# rather than a fraction of break-up, and it runs to the extremal limit.
		var bh := type == "bh"
		rows.spin.vmax = 0.998 if bh else 1.0
		if dragging != "leMass": el.set_value(lm)
		else: el.set_value(el.value)
		if dragging != "leSpin": rows.spin.set_value(float(b.spin_frac))
		if dragging != "lePhase": rows.phase.set_value(_phase_f(b.phase))
		if dragging != "leZ": rows.z.set_value(float(U.nz(b.Z, 0.014)))
		if dragging != "leComp": rows.comp.set_value(str(b.composition) if b.composition != null and str(b.composition) != "" else "earth")

		var rocky := type == "planet" or type == "world"
		Foundry.show_el(rows.comp_row, rocky)
		Foundry.show_el(rows.phase_row, type == "star")
		Foundry.show_el(rows.z_row, type == "star")
		rows.set_spin_label(bh)
		readouts()
		_draw_curve(b)

	# The graph reads the LIVE body, so a star being eaten walks its handle down
	# its own curve without anyone touching a control.
	func _draw_curve(b) -> void:
		curve.draw_curve({
			"type": "planet" if b.type == "world" else b.type,
			"mass": b.mass, "spinFrac": b.spin_frac,
			"composition": b.composition, "phase": b.phase, "Z": U.nz(b.Z, 0.014),
		}, Foundry.range_for(b.type))
		var near = curve.nearest(b.mass)
		if near != null:
			near_el.set_runs([{"t": near.label, "c": T.WARN} if near.bad else {"t": near.label},
				{"t": " at %s · %s dex %s" % [MassCurve.fmt_mass_short(near.mass),
					U.fixed(absf(U.log10(near.mass / b.mass)), 2), "below" if near.above else "away"]}])
		else:
			near_el.set_text("no threshold in range")

	func _toggle_focus() -> void:
		curve.set_focus(not curve.focus)
		focus_btn.set_state("on", curve.focus)
		focus_btn.set_text("full range" if curve.focus else "focus limit")
		if body != null: _draw_curve(body)

# ============================================================================
# <select class="fd-select"> — the composition picker. Drawn as Chrome draws a
# styled <select>: the chosen label, and a chevron in the right-hand padding;
# the list itself is a PopupMenu, as the browser's own is a native menu.
# ============================================================================
class SelectEl extends El:
	signal changed(value: String)
	var options: Array = []       # [[value, label], ...]
	var value := ""
	var _menu: PopupMenu = null

	func _init() -> void:
		# .fd-select: flex 1; bg rgba(0,0,0,.4); border; text; mono 10px;
		# padding 4px 6px — plus the UA's room for the arrow on the right.
		super({"grow": 1.0, "shrink": 1.0, "basis": 0.0, "bg": T.rgba(0, 0, 0, 0.4), "b": [1, T.BORDER],
			"c": T.TEXT, "ff": "mono", "fs": 10.0, "p": [4, 26, 4, 6], "nw": true, "clip": true, "lh": 13.0})
		make_clickable()
		pressed.connect(_open)

	func set_options(o: Array) -> void:
		options = o
		if value == "" and not o.is_empty():
			set_value(o[0][0])

	func set_value(v: String) -> void:
		value = v
		for o in options:
			if o[0] == v:
				set_text(o[1])
				return

	func _draw_extra() -> void:
		# the chevron, 7 × 4 px, 1.5 px stroke, centred in the arrow padding
		var cx := size.x - 12.5
		var cy := size.y * 0.5
		var col: Color = g("c")
		draw_polyline(PackedVector2Array([Vector2(cx - 3.5, cy - 1.75), Vector2(cx, cy + 1.75), Vector2(cx + 3.5, cy - 1.75)]), col, 1.5, true)

	func _open() -> void:
		if _menu == null:
			_menu = PopupMenu.new()
			_menu.add_theme_font_override("font", HudTheme.font("mono"))
			_menu.add_theme_font_size_override("font_size", 11)
			add_child(_menu, false, Node.INTERNAL_MODE_BACK)
			_menu.id_pressed.connect(func(i: int):
				var v: String = options[i][0]
				if v != value:
					set_value(v)
					changed.emit(v))
		_menu.clear()
		for i in options.size():
			_menu.add_radio_check_item(options[i][1], i)
			_menu.set_item_checked(i, options[i][0] == value)
		var gp := get_screen_transform().origin
		_menu.popup(Rect2i(Vector2i(gp + Vector2(0, size.y)), Vector2i(int(size.x), 0)))
