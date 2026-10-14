class_name Hangar
extends Control

# Spaceflight's front door: the craft on the studio turntable (ModelViewer), the
# line-up down the left in the title screen's type, and a card with the craft's
# numbers, the missions it can fly and Start mission. A mission the craft cannot fly
# is listed with the reason, never hidden.

signal pick(key: String)
signal start(key: String, dest: String, goal: String)
signal back()
## The centre of the open floor between the line-up and the card, as a fraction of the
## width, whenever the layout changes; the turntable frames the craft there.
signal stage_moved(frac: float)

const NAME := {"fs": 24.0, "ls": 5.0, "up": true, "c": HudTheme.ACCENT, "lh": 1.25}
const KICK := {"fs": 8.5, "ls": 3.0, "up": true, "c": HudTheme.TEXT_DIM, "fw": 500}

## A mission offered in the hangar: [label, destination body ("" = free flight), goal].
const MISSIONS := [
	["Free flight", "", ""],
	["Earth orbit", "Earth", "orbit"],
	["Lunar orbit", "Moon", "orbit"],
	["Lunar landing", "Moon", "land"],
	["Mars orbit", "Mars", "orbit"],
	["Venus orbit", "Venus", "orbit"],
]

var shade: TextureRect
var list: VBoxContainer
var kicker: Label
var items := {}
var card: HudPanel
var selected := ""
var mission := 0
## {key: {name, role, blurb, rows: [[k, v]], missions: [{label, dest, goal, ok, why, dv}]}}
var info := {}

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	# The menu side darkened, as on the title screen.
	shade = TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0.78))
	g.set_color(1, Color(0, 0, 0, 0.0))
	g.set_offset(1, 0.62)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0); gt.fill_to = Vector2(1, 0)
	shade.texture = gt
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	kicker = Hud.label(self, "Spaceflight · Hangar", KICK)
	list = VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	add_child(list)
	var back_b := TitleItem.new("Back")
	back_b.set_meta("back", true)
	back_b.pressed.connect(func(): back.emit())
	add_child(back_b)
	card = HudPanel.new([20, 22, 20, 22], true)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(card)
	# Wrapped text settles its height a frame after it is built.
	card.pad.minimum_size_changed.connect(func(): _layout.call_deferred())

## rows: [{key, name, role}] in display order.
func set_crafts(rows: Array) -> void:
	for c in list.get_children(): c.queue_free()
	items.clear()
	for r in rows:
		var it := TitleItem.new(str(r.name))
		var k: String = r.key
		it.pressed.connect(func(): select(k); pick.emit(k))
		list.add_child(it)
		items[k] = it

func set_info(key: String, d: Dictionary) -> void:
	info[key] = d
	if key == selected: _build_card()

func select(key: String) -> void:
	selected = key
	for k in items:
		(items[k] as TitleItem).set_meta("on", k == key)
		(items[k] as TitleItem).modulate.a = 1.0 if k == key else 0.62
	# Keep the chosen mission if this craft can fly it; otherwise its first.
	mission = 0
	_build_card()

func _build_card() -> void:
	Hud._clear(card.body)
	var d: Dictionary = info.get(selected, {})
	if d.is_empty(): return
	var body := card.body
	Hud.label(body, str(d.name), NAME, true)
	Hud.m(Hud.label(body, str(d.role), KICK), 6.0, 14.0)
	var g := Hud.grid(body, [1.0, 1.0], 12.0, 10.0, 0.0, 14.0)
	for r in d.rows:
		var st := Hud.stack(g)
		Hud.label(st, str(r[0]), {"fs": 7.5, "ls": 1.6, "up": true, "c": HudTheme.TEXT_DIM}, true)
		Hud.label(st, str(r[1]), {"fs": 13.0, "c": HudTheme.TEXT}, true)
	Hud.m(Hud.label(body, str(d.blurb), {"fs": 9.5, "c": HudTheme.TEXT_DIM, "lh": 1.5}, true), 0.0, 16.0)
	Hud.label(body, "Mission", KICK)
	var ms: Array = d.missions
	var chips := Hud.grid(body, [1.0, 1.0], 6.0, 6.0, 8.0, 6.0)
	for i in ms.size():
		var mi: Dictionary = ms[i]
		var b := HudButton.new("Chip", str(mi.label), str(mi.why) if not mi.ok else ("Δv %s" % FlightUI.fmt_speed(float(mi.dv)) if float(mi.dv) > 0.0 else "Fly it yourself; the autopilot programs are under Systems"))
		chips.add_child(b)
		b.set_active(i == mission)
		if not mi.ok: b.modulate.a = 0.38
		var idx := i
		b.pressed.connect(func():
			if not ms[idx].ok: return
			mission = idx
			_build_card())
	var cur: Dictionary = ms[mission] if mission < ms.size() else {}
	var note := ""
	if not cur.is_empty():
		if cur.dest == "": note = "On the pad (or in orbit, for a lander), with every control yours. The map (M) can still plan a trip."
		else: note = "The autopilot flies the whole mission — launch, transfer, course corrections, capture%s — and chooses the time warp. Δv needed %s of %s on board." % [
			", landing" if cur.goal == "land" else "", FlightUI.fmt_speed(float(cur.dv)), FlightUI.fmt_speed(float(d.dv))]
	Hud.m(Hud.label(body, note, {"fs": 9.0, "c": HudTheme.TEXT_DIM, "lh": 1.5}, true), 4.0, 16.0)
	var go := HudButton.new("Primary", "Start mission")
	body.add_child(go)
	var k := selected
	go.pressed.connect(func():
		var m: Dictionary = ms[mission]
		start.emit(k, str(m.dest), str(m.goal)))
	_layout.call_deferred()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED: _layout()

func _layout() -> void:
	var W := size.x
	var H := size.y
	if W <= 0.0: return
	shade.position = Vector2.ZERO
	shade.size = Vector2(W * 0.62, H)
	var left := roundf(clampf(W * 0.055, 40.0, 110.0))
	var fs := int(clampf(H * 0.019, 14.0, 24.0))
	kicker.position = Vector2(left + 6.0, roundf(H * 0.08))
	for it in list.get_children():
		(it as TitleItem).set_font_size(fs)
	list.add_theme_constant_override("separation", int(H * 0.012))
	list.position = Vector2(left, roundf(H * 0.08) + 34.0)
	list.size = list.get_combined_minimum_size()
	for c in get_children():
		if c is TitleItem and c.has_meta("back"):
			(c as TitleItem).set_font_size(int(fs * 0.8))
			c.position = Vector2(left, H - roundf(H * 0.08) - c.get_combined_minimum_size().y)
			c.size = c.get_combined_minimum_size()
	var cw := clampf(W * 0.34, 300.0, 400.0)
	var margin := roundf(clampf(H * 0.05, 16.0, 60.0))
	card.size = Vector2(cw, 0)
	# A short window scrolls the card rather than pushing it off the frame.
	card.size = Vector2(cw, minf(card.natural_height(), H - 2.0 * margin))
	card.position = Vector2(W - cw - roundf(W * 0.035), H - card.size.y - margin)
	var menu_r := list.position.x + list.size.x
	stage_moved.emit(clampf((menu_r + card.position.x) * 0.5 / W, 0.35, 0.65))
