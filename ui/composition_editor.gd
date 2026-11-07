class_name CompositionEditor
extends HudStack

# The air-and-water controls, one set for the Foundry and the live editor: a mix, the pie, a row
# per gas with a slider and a typed value, the sea and the surface, and what the model expects.
# Owners hand it a preview (Composition) and take patches from `edited`; `validate` says whether
# a patch is inside the model's domain, and one that is not never leaves here.

const T = preload("res://ui/theme.gd")

signal edited(patch: Dictionary)

## patch -> reason; "" when the model takes it.
var validate: Callable
var mix: HudSelect
var pie: CompositionPie
var limit_el: Label
var era_el: Label
var era_note: Label
var sky_swatch: ColorRect
var facts: Foundry.Facts
var note_el: Label
var add_gas: HudSelect
var oceans_btn: HudButton
var land: HudSlider
var land_val: Label
var depth: HudSlider
var depth_val: Label
var salinity: HudSlider
var salinity_val: Label
var albedo: HudSlider
var albedo_val: Label
var layer: HudSlider
var layer_val: Label
var water_box: Control
# The gases' rows by key: {row, slider, field}.
var gases := {}
var last_preview := {}
var _gas_stack: HudStack
# The control under the pointer, which a sync must leave alone.
var _held := ""
var _added := []

func _init() -> void:
	super(false)
	Hud.m(Hud.label(self, "Air and water", {"fs": 10.0, "ls": 1.4, "up": true, "c": T.ACCENT_2}), 4.0, 6.0)
	mix = HudSelect.new("FdSelect")
	mix.set_options(Composition.options(), Composition.DRAWN)
	mix.chosen.connect(_on_mix)
	Hud.range_row(self, "Mix", "A starting mix of gases and water. Seeded draw lets this world's mass, radius and sunlight decide, from the same seed each time; edit anything and it becomes Custom.", mix, null, 8.0)
	pie = CompositionPie.new()
	add_child(Hud.m(pie, 0.0, 6.0))
	_gas_stack = Hud.stack(self)
	for key in Atmosphere.GASES: _build_gas(key)
	add_gas = HudSelect.new("FdSelect")
	add_gas.chosen.connect(_on_add_gas)
	Hud.range_row(self, "Add gas", "Add a gas this mix does not have yet. Water is not here: it follows temperature, and the sea below sets how much there is.", add_gas, null, 8.0)
	_build_water()
	limit_el = Hud.label(self, "", {"fs": 10.0, "c": T.WARN, "lh": 1.45}, true)
	Hud.m(limit_el, 0.0, 8.0)
	limit_el.visible = false
	_build_expected()

func _build_gas(key: String) -> void:
	var gas: Dictionary = Atmosphere.GASES[key]
	var top: float = ClimateInputs.DOMAIN[key][1]
	var slider := Foundry._slider(float(gas.foot), U.log10(top), 0.01, float(gas.foot))
	var row := Hud.hbox(_gas_stack, 6.0, 0.0, 7.0)
	var lab := Hud.tip_label(row, str(gas.label), Hud.ROW_LABEL, "Partial pressure of %s. Domain: none to %s; the gases together stop at %s. Type a value, in bar, mbar or µbar." \
		% [gas.label, Hud.format_bar(top), Hud.format_bar(ClimateInputs.MAX_AIR_BAR)])
	lab.custom_minimum_size.x = 26.0
	lab.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	var field := LineEdit.new()
	field.theme_type_variation = "RowField"
	field.custom_minimum_size.x = 70.0
	field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	field.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	field.text_submitted.connect(func(t: String):
		field.release_focus()
		_on_typed(key, t))
	row.add_child(field)
	var del := HudButton.new("Remove", "×", "Remove %s from the air." % gas.label)
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	del.pressed.connect(func(): _on_remove(key))
	row.add_child(del)
	slider.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			_held = key if e.pressed else "")
	slider.moved.connect(func(v: float): _on_slider(key, v))
	gases[key] = {"row": row, "slider": slider, "field": field}

func _slider_row(text: String, tip: String, mn: float, mx: float, st: float, key: String) -> Dictionary:
	var s := Foundry._slider(mn, mx, st, mn)
	var parts := Hud.range_row(water_box, text, tip, s, "—", 7.0)
	s.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			_held = key if e.pressed else "")
	return {"slider": s, "val": parts.val}

func _build_water() -> void:
	oceans_btn = HudButton.new("Toggle", "Oceans", "Whether this world has water to freeze, boil and lose. Without it there is no water greenhouse and no ice.")
	oceans_btn.pressed.connect(func(): _emit({"oceans": not bool(_inputs().get("oceans", false))}))
	add_child(Hud.m(oceans_btn, 2.0, 8.0))
	water_box = Hud.stack(self)
	var d := ClimateInputs.DOMAIN
	var r := _slider_row("Land", "The fraction of the surface above the sea. Under 5% this world reads as a global ocean, or an ice shell when frozen.", d.land[0], d.land[1], 0.01, "land")
	land = r.slider; land_val = r.val
	land.moved.connect(func(v: float): _emit({"land": v}))
	r = _slider_row("Sea depth", "Mean depth of the sea. With the land fraction, this is how much water the world has: a tenth of Earth's boils ten times as fast.", -2.0, U.log10(d.oceanDepth[1]), 0.01, "oceanDepth")
	depth = r.slider; depth_val = r.val
	depth.moved.connect(func(v: float): _emit({"oceanDepth": pow(10.0, v)}))
	r = _slider_row("Salinity", "Grams of salt per kilogram of sea. Salt lowers the freezing point: −1.9 °C at Earth's 35, about −19 °C near the brine limit.", d.salinity[0], d.salinity[1], 1.0, "salinity")
	salinity = r.slider; salinity_val = r.val
	salinity.moved.connect(func(v: float): _emit({"salinity": v}))
	var surface := Hud.stack(self)
	var keep := water_box
	water_box = surface
	r = _slider_row("Albedo", "The ice-free Bond albedo: how much sunlight the world reflects before any ice forms.", d.albedoBase[0], d.albedoBase[1], 0.01, "albedoBase")
	albedo = r.slider; albedo_val = r.val
	albedo.moved.connect(func(v: float): _emit({"albedoBase": v}))
	r = _slider_row("Flywheel", "How much heat the surface stores, as metres of water: shallow worlds swing with their orbits, deep ones damp them. On a wet world it is capped by the sea.", -1.0, U.log10(d.mixedLayer[1]), 0.01, "mixedLayer")
	layer = r.slider; layer_val = r.val
	layer.moved.connect(func(v: float): _emit({"mixedLayer": pow(10.0, v)}))
	water_box = keep

func _build_expected() -> void:
	Hud.m(Hud.label(self, "Expected", {"fs": 10.0, "ls": 1.4, "up": true, "c": T.ACCENT_2}), 6.0, 5.0)
	var head := Hud.hbox(self, 8.0, 0.0, 4.0)
	era_el = Hud.label(head, "", {"fs": 11.0, "ls": 1.2, "up": true, "c": T.ACCENT})
	era_el.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	era_el.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	Hud.label(head, "sky", {"fs": 9.0, "c": T.TEXT_DIM}).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sky_swatch = ColorRect.new()
	sky_swatch.custom_minimum_size = Vector2(34, 12)
	sky_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sky_swatch.tooltip_text = "The colour a clear sky takes from this column's Rayleigh scattering. Dust and sulphuric haze are not in it."
	sky_swatch.mouse_filter = Control.MOUSE_FILTER_PASS
	head.add_child(sky_swatch)
	era_note = Hud.label(self, "", {"fs": 9.5, "c": T.TEXT_DIM, "lh": 1.45}, true)
	Hud.m(era_note, 0.0, 6.0)
	facts = Foundry.Facts.new()
	add_child(facts)
	note_el = Hud.label(self, "", Hud.NOTE, true)
	Hud.m(note_el, 0.0, 6.0)

func _inputs() -> Dictionary:
	return last_preview.get("inputs", {})

func _on_mix(value: String) -> void:
	if value == Composition.CUSTOM: return
	_emit(Composition.mix_patch(value), value)

func _on_add_gas(key: String) -> void:
	if key == "": return
	# Enough to see on its log bar, without claiming to be most of the air.
	var top: float = ClimateInputs.DOMAIN[key][1]
	var start := minf(1e-3, top * 0.01)
	add_gas.set_value("")
	_emit({key: start})

func _on_remove(key: String) -> void:
	_emit({key: 0.0})

func _on_slider(key: String, v: float) -> void:
	var gas: Dictionary = Atmosphere.GASES[key]
	# The foot of a slider is none at all.
	_emit({key: 0.0 if v <= float(gas.foot) else pow(10.0, v)})

func _on_typed(key: String, text: String) -> void:
	var bar := Composition.parse_bar(text)
	if is_nan(bar):
		show_limit("“%s” is not a pressure. Try 0.2, 6 mbar or 426 µbar." % text)
		_refresh_fields()
		return
	_emit({key: bar})

func _emit(patch: Dictionary, picked := Composition.CUSTOM) -> void:
	var reason: String = validate.call(patch) if validate.is_valid() else ""
	if reason != "":
		show_limit(reason)
		_refresh_fields()
		return
	show_limit("")
	mix.set_value(picked)
	edited.emit(patch)

func show_limit(reason: String) -> void:
	(limit_el as Prose).say(reason)
	limit_el.visible = reason != ""

## Everything the panel shows, from a preview. The sliders follow unless one is held.
func show_preview(p: Dictionary) -> void:
	if p.has("error"):
		show_limit(str(p.error))
		return
	if p.is_empty(): return
	last_preview = p
	pie.show_composition(p.rows, p.surface)
	_refresh_fields()
	_show_expected(p)

## Which mix the body or draft states; a body's own, on attach.
func set_mix_from(stated: Dictionary) -> void:
	mix.set_value(Composition.matching(stated))

func _refresh_fields() -> void:
	var inputs := _inputs()
	if inputs.is_empty(): return
	var pressures: Dictionary = inputs.pressures
	var absent := []
	for key in Atmosphere.GASES:
		var bar := float(pressures.get(key, 0.0))
		var row: Dictionary = gases[key]
		row.row.visible = bar > 0.0 or _held == key
		var gas: Dictionary = Atmosphere.GASES[key]
		if bar <= 0.0 and _held != key: absent.append([key, str(gas.label)])
		if _held != key:
			(row.slider as HudSlider).set_v(U.log10(bar) if bar > 0.0 else float(gas.foot))
		var field: LineEdit = row.field
		if not field.has_focus(): field.text = Hud.format_bar(bar)
	var opts := [["", "Choose…"]]
	opts.append_array(absent)
	if opts != add_gas.options: add_gas.set_options(opts, "")
	add_gas.get_parent().visible = not absent.is_empty()
	var wet: bool = inputs.oceans
	oceans_btn.set_active(wet)
	oceans_btn.set_label("Oceans: on" if wet else "Oceans: none")
	water_box.visible = wet
	if _held != "land": land.set_v(float(inputs.land))
	land_val.text = "%s %%" % U.fixed(float(inputs.land) * 100.0, 0)
	if _held != "oceanDepth": depth.set_v(U.log10(maxf(float(inputs.oceanDepth), 0.01)))
	depth_val.text = "%s km" % U.prec(float(inputs.oceanDepth), 2)
	if _held != "salinity": salinity.set_v(float(inputs.salinity))
	salinity_val.text = "%s ‰" % U.fixed(float(inputs.salinity), 0)
	if _held != "albedoBase": albedo.set_v(float(inputs.albedoBase))
	albedo_val.text = U.fixed(float(inputs.albedoBase), 2)
	if _held != "mixedLayer": layer.set_v(U.log10(float(inputs.mixedLayer)))
	layer_val.text = "%s m" % U.prec(float(inputs.mixedLayer), 2)

func _show_expected(p: Dictionary) -> void:
	var era: Dictionary = p.era
	era_el.text = str(era.label)
	T.apply_label(era_el, {"fs": 11.0, "ls": 1.2, "up": true, "c": Hud.ERA.get(era.cls, Hud.ERA["era-stable"]).c})
	(era_note as Prose).say(str(era.desc))
	sky_swatch.color = T.hexc(int(p.sky))
	facts.show_facts(expected_rows(p))
	var notes := PackedStringArray()
	if p.air > Climate.AIRLESS_BAR and p.retention < 0.0:
		notes.append("Below the cosmic shoreline: a world this small under this much sunlight would not keep this air for long. The model holds it anyway; nothing here removes it.")
	(note_el as Prose).say(" ".join(notes))
	note_el.visible = not notes.is_empty()

## The expected numbers, in reading order. Everything here is off the climate model.
static func expected_rows(p: Dictionary) -> Array:
	var rows := [
		["surface", "%s °C · %s K" % [U.fixed(float(p.T) - 273.15, 0), U.fixed(float(p.T), 0)]],
		["no-air balance", "%s K" % U.fixed(float(p.airlessT), 0)],
		["greenhouse", "%s%s K" % ["+" if float(p.T) >= float(p.airlessT) else "", U.fixed(float(p.T) - float(p.airlessT), 0)]],
		["sunlight", "%s S⊕" % U.prec(float(p.S), 3)],
		["air", Hud.format_bar(float(p.air))],
		["gravity", "%s m/s²" % U.prec(float(p.gravity), 3)],
	]
	if float(p.air) > Climate.AIRLESS_BAR:
		rows.append(["scale height", "%s km" % U.prec(float(p.scaleM) / 1000.0, 3)])
		rows.append(["sky depth τ", U.prec(float(p.tau), 2)])
	rows.append(["ice line", ice_text(p)])
	rows.append(["sea", str(p.sea)])
	if p.wet:
		rows.append(["water", "%s km deep, spread out" % U.prec(float(p.water) / Climate.RHO_SEA / 1000.0, 2)])
		rows.append(["freezes", "%s °C" % U.fixed(float(p.freeze) - 273.15, 1)])
		rows.append(["boils", "%s °C" % U.fixed(float(p.boil) - 273.15, 0)])
		rows.append(["cloud", "%s %%" % U.fixed(float(p.clouds) * 100.0, 0)])
	return rows

static func ice_text(p: Dictionary) -> String:
	if not p.wet: return "none"
	if p.snowball: return "to the equator"
	var edge := float(p.iceEdge)
	return "none" if edge >= 1.0 else "%d°" % int(round(rad_to_deg(asin(edge))))
