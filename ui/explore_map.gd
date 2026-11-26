class_name ExploreMap
extends Control

# Planetary exploration's front door: the system drawn flat from above the ecliptic, as
# the space map draws it, but with no vessel. Scroll zooms about the pointer, a drag
# pans, a click centres a body, and a right click on a world with ground offers to
# explore it (Showcase). The list down the left names those worlds.

signal explore(body: Body)
signal back()

const BG := Color(0.012, 0.016, 0.026)
const ORBIT := Color(1, 1, 1, 0.13)
const GROUND := Color(0.66, 0.79, 0.95)
const ZOOM_MIN := 1e-3          # px per AU
const ZOOM_MAX := 1e9
const MENU_EXPLORE := 1
const MENU_FOCUS := 2

var state: SimState
var center := DVec3.new()       # AU
var k := 300.0                  # px per AU
var _k_goal := 300.0
var follow: Body = null
var hover: Body = null
var _press := Vector2.ZERO
var _dragging := false
var _menu: PopupMenu
var _menu_body: Body = null
var _primary := {}              # body id → the body it orbits, or null
var _primary_age := 99.0
var _stars := PackedVector2Array()
var _f_small: Font
var _f_label: Font
var _f_title: Font
var list: HudPanel
var _list_key := ""
var back_b: TitleItem
var title := ""

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	visible = false
	_f_small = HudTheme.text_font({"fs": 8.0, "ls": 1.6})
	_f_label = HudTheme.text_font({"fs": 9.0, "ls": 1.8})
	_f_title = HudTheme.text_font({"fs": 11.0, "ls": 4.0})
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 420: _stars.append(Vector2(rng.randf(), rng.randf()))
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	list = HudPanel.new([14, 14, 14, 14])
	add_child(list)
	back_b = TitleItem.new("Back")
	back_b.pressed.connect(func(): back.emit())
	add_child(back_b)

## Open on `s`'s bodies, framing the inner worlds with ground.
func open(s: SimState, scene_name: String) -> void:
	state = s
	title = scene_name
	visible = true
	grab_focus()
	follow = null
	hover = null
	_refresh_primaries()
	_frame_system()
	_list_key = ""
	_sync_list()
	_layout()

func close() -> void:
	visible = false
	_menu.hide()

static func explorable(b: Body) -> bool:
	return b != null and b.alive and b.climate != null

func worlds() -> Array:
	return state.bodies.filter(func(b): return explorable(b)) if state != null else []

# GEOMETRY

func to_screen(p: DVec3) -> Vector2:
	return size * 0.5 + Vector2(float(p.x - center.x), -float(p.z - center.z)) * k

func to_world(s: Vector2) -> DVec3:
	var d := (s - size * 0.5) / k
	return DVec3.new(center.x + d.x, center.y, center.z - d.y)

## Each body's primary: the nearest more massive body whose Hill sphere holds it.
func _refresh_primaries() -> void:
	_primary_age = 0.0
	_primary.clear()
	var by_mass: Array = state.bodies.filter(func(b): return b.alive)
	by_mass.sort_custom(func(a, b): return a.mass > b.mass)
	var hill := {}
	for i in by_mass.size():
		var b: Body = by_mass[i]
		var best: Body = null
		var best_d := INF
		for j in i:
			var c: Body = by_mass[j]
			var d := b.pos.distance_to(c.pos)
			if d < float(hill.get(c.id, INF)) and d < best_d:
				best = c
				best_d = d
		_primary[b.id] = best
		hill[b.id] = INF if best == null else best_d * pow(b.mass / (3.0 * best.mass), 1.0 / 3.0)

func primary_of(b: Body) -> Body:
	return _primary.get(b.id)

func _dot_radius(b: Body) -> float:
	var base := 6.0 if b.type == "star" else (4.0 if primary_of(b) == null or primary_of(b).type == "star" else 2.6)
	return maxf(b.radius * k, base)

func _color(b: Body) -> Color:
	if SpaceMap.COLORS.has(b.name): return SpaceMap.COLORS[b.name]
	return Color(1.0, 0.9, 0.72) if b.type == "star" else Color(0.78, 0.8, 0.84)

## The whole of the inner worlds with ground, about the most massive body.
func _frame_system() -> void:
	var top: Body = null
	for b: Body in state.bodies:
		if b.alive and (top == null or b.mass > top.mass): top = b
	if top == null: return
	var d := []
	for w in worlds(): d.append(w.pos.distance_to(top.pos))
	d.sort()
	# The inner worlds, not a Pluto that would shrink them to a point.
	var reach: float = (d[mini(4, d.size() - 1)] * 1.15) if not d.is_empty() else 2.0
	center.copy_from(top.pos)
	_k_goal = clampf(minf(size.x, size.y) * 0.42 / maxf(reach, 1e-9), ZOOM_MIN, ZOOM_MAX)
	k = _k_goal

## Centre on a body and zoom to its system: its moons' orbits, or a few radii.
func frame_on(b: Body) -> void:
	follow = b
	var reach := b.radius * 12.0
	for c: Body in state.bodies:
		if c != b and c.alive and primary_of(c) == b: reach = maxf(reach, c.pos.distance_to(b.pos) * 1.25)
	_k_goal = clampf(minf(size.x, size.y) * 0.42 / maxf(reach, 1e-12), ZOOM_MIN, ZOOM_MAX)

# FRAME

func _process(dt: float) -> void:
	if not visible or state == null: return
	_primary_age += dt
	if _primary_age > 0.5: _refresh_primaries()
	k = exp(lerpf(log(k), log(_k_goal), 1.0 - exp(-dt * 10.0)))
	if follow != null and follow.alive:
		center = center.lerp_in(follow.pos, 1.0 - exp(-dt * 10.0)) if center.distance_to(follow.pos) * k > 1.0 else follow.pos.clone()
	_sync_list()
	queue_redraw()

func _draw() -> void:
	if state == null: return
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	for s in _stars:
		draw_rect(Rect2(s * size, Vector2(1, 1)), Color(1, 1, 1, 0.05 + 0.1 * fmod(s.x * 37.0, 1.0)))
	for b: Body in state.bodies:
		var c := primary_of(b) if b.alive else null
		if c == null: continue
		var r_px: float = b.pos.distance_to(c.pos) * k
		if r_px < 5.0 or r_px > 4e5: continue
		draw_arc(to_screen(c.pos), r_px, 0.0, TAU, clampi(int(r_px * 0.5), 32, 256), ORBIT, 1.0, true)
	var fs := HudTheme.px(9.0 * HudTheme.UI_SCALE)
	for b: Body in state.bodies:
		if not b.alive: continue
		var p := to_screen(b.pos)
		if p.x < -40.0 or p.y < -40.0 or p.x > size.x + 40.0 or p.y > size.y + 40.0: continue
		var r := _dot_radius(b)
		var col := _color(b)
		# Moons crowd their planet until zoomed in: only named once apart.
		var c := primary_of(b)
		var apart := c == null or b.pos.distance_to(c.pos) * k > 18.0
		if not apart and b != hover: continue
		draw_circle(p, r, col)
		if explorable(b): draw_arc(p, r + 3.5, 0.0, TAU, 24, Color(GROUND, 0.75 if b == hover else 0.4), 1.2, true)
		if b == hover: draw_arc(p, r + 7.0, 0.0, TAU, 32, Color(1, 1, 1, 0.8), 1.0, true)
		draw_string(_f_label, p + Vector2(r + 6.0, 4.0), b.name.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			Color(1, 1, 1, 0.85 if b == hover or explorable(b) else 0.5))
	_draw_header()

func _draw_header() -> void:
	var x := list.position.x + list.size.x + 28.0 if list.visible else 28.0
	draw_string(_f_title, Vector2(x, 40), "PLANETARY EXPLORATION", HORIZONTAL_ALIGNMENT_LEFT, -1, HudTheme.px(11.0 * HudTheme.UI_SCALE), Color(1, 1, 1, 0.9))
	draw_string(_f_small, Vector2(x, 58), ("%s · %d worlds with ground" % [title, worlds().size()]).to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, HudTheme.px(8.0 * HudTheme.UI_SCALE), Color(1, 1, 1, 0.5))
	var hint := "SCROLL ZOOM · DRAG PAN · CLICK CENTRE · RIGHT-CLICK A WORLD TO EXPLORE IT · ESC BACK"
	var hs := HudTheme.px(7.5 * HudTheme.UI_SCALE)
	var hw := _f_small.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs).x
	draw_string(_f_small, Vector2((size.x - hw) * 0.5, size.y - 18.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs, Color(1, 1, 1, 0.32))

# THE LIST: the worlds with ground, each centring the map on itself.

func _sync_list() -> void:
	var ws := worlds()
	var key := ",".join(ws.map(func(b): return str(b.id)))
	if key == _list_key: return
	_list_key = key
	for c in list.body.get_children():
		list.body.remove_child(c)
		c.queue_free()
	HudStack.m(Hud.label(list.body, "Worlds with ground", Hud.H3), 0.0, 8.0)
	for b: Body in ws:
		var btn := HudButton.new("BodyItem", b.name, "Centre the map on %s. Right-click it there to explore." % b.name)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.set_meta("body", b.name)
		btn.pressed.connect(func(): frame_on(b))
		list.body.add_child(btn)
	_layout()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED: _layout()

func _layout() -> void:
	var W := size.x
	var H := size.y
	if W <= 0.0: return
	list.size = Vector2(190.0, 0.0)
	list.size = Vector2(190.0, minf(list.natural_height(), H - 160.0))
	list.position = Vector2(24.0, 84.0)
	var fs := int(clampf(H * 0.02, 14.0, 22.0))
	back_b.set_font_size(fs)
	back_b.size = back_b.get_combined_minimum_size()
	back_b.position = Vector2(W - 40.0 - back_b.size.x, H - 40.0 - back_b.size.y)

# INPUT

func body_at(p: Vector2) -> Body:
	var best: Body = null
	var best_d := 18.0
	for b: Body in state.bodies:
		if not b.alive: continue
		var d := to_screen(b.pos).distance_to(p) - _dot_radius(b)
		# A world with ground wins a tie with its star or planet beneath it.
		if d < best_d or (best != null and absf(d - best_d) < 1.0 and explorable(b) and not explorable(best)):
			best_d = d
			best = b
	return best

func _gui_input(e: InputEvent) -> void:
	if state == null: return
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if mm.position.distance_to(_press) > 4.0: _dragging = true
			if _dragging:
				follow = null
				center.x -= mm.relative.x / k
				center.z += mm.relative.y / k
		hover = body_at(mm.position)
		accept_event()
	elif e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed: _zoom(1.18 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.18, mb.position)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press = mb.position
				_dragging = false
			elif not _dragging:
				var b := body_at(mb.position)
				if b != null: frame_on(b)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			open_menu(body_at(mb.position), mb.position)
			accept_event()
	elif e is InputEventMagnifyGesture:
		_zoom((e as InputEventMagnifyGesture).factor, (e as InputEventMagnifyGesture).position)
		accept_event()
	elif e is InputEventPanGesture:
		_zoom(1.0 - (e as InputEventPanGesture).delta.y * 0.06, get_local_mouse_position())
		accept_event()

func _zoom(f: float, about: Vector2) -> void:
	var before := to_world(about)
	_k_goal = clampf(_k_goal * f, ZOOM_MIN, ZOOM_MAX)
	if follow == null:
		var d := (about - size * 0.5) / _k_goal
		center.set_v(before.x - d.x, center.y, before.z + d.y)
		k = _k_goal

## The right-click menu on `b`: explore it, if it has ground, or centre on it.
func open_menu(b: Body, at: Vector2) -> void:
	_menu.clear()
	_menu_body = b
	if b == null: return
	_menu.add_item("Explore %s" % b.name, MENU_EXPLORE)
	if not explorable(b):
		var i := _menu.get_item_index(MENU_EXPLORE)
		_menu.set_item_disabled(i, true)
		_menu.set_item_tooltip(i, "%s has no ground to stand on." % b.name)
	_menu.add_separator()
	_menu.add_item("Centre on %s" % b.name, MENU_FOCUS)
	_menu.position = Vector2i(get_screen_position() + at)
	_menu.reset_size()
	_menu.popup()

func _on_menu(id: int) -> void:
	var b := _menu_body
	if b == null or not b.alive: return
	match id:
		MENU_EXPLORE: if explorable(b): explore.emit(b)
		MENU_FOCUS: frame_on(b)
