class_name SpaceMap
extends Control

# The space map (M): the system drawn flat from above the ecliptic, cheap enough that
# the 3D frame stops rendering behind it. Scroll zooms about the pointer, a drag pans,
# a click follows a body, a right click offers it as a destination. The route card
# prices the trip with Mission.plan_route and flies it or skips to the arrival.

signal fly(dest: String, goal: String)
signal skip(dest: String, goal: String)
signal abort()
signal closed()

const BG := Color(0.012, 0.016, 0.026)
const ORBIT := Color(1, 1, 1, 0.13)
const ORBIT_LIT := Color(1, 1, 1, 0.42)
const ROUTE := Color(0.66, 0.79, 0.95, 0.85)
const SHIP := Color(0.66, 0.79, 0.95)
const COLORS := {
	"Sun": Color(1.0, 0.9, 0.7), "Mercury": Color(0.66, 0.62, 0.58), "Venus": Color(0.93, 0.84, 0.66),
	"Earth": Color(0.48, 0.66, 0.92), "Moon": Color(0.7, 0.7, 0.7), "Mars": Color(0.86, 0.5, 0.36),
	"Jupiter": Color(0.86, 0.76, 0.62), "Saturn": Color(0.9, 0.82, 0.62), "Uranus": Color(0.62, 0.84, 0.88),
	"Neptune": Color(0.46, 0.6, 0.92), "Pluto": Color(0.8, 0.74, 0.66),
}
const ZOOM_MIN := 1e-2          # px per AU
const ZOOM_MAX := 1e9

var flight                      # Spaceflight
var center := DVec3.new()       # AU, world frame
var k := 300.0                  # px per AU
var _k_goal := 300.0
var follow: Body = null
var follow_ship := true
var dest: Body = null
var goal := "orbit"
var plan := {}
var _plan_age := 99.0
var hover: Body = null
var _press := Vector2.ZERO
var _dragging := false
var _menu: PopupMenu
var _menu_body: Body = null
var card: HudPanel
var _card_key := ""
var _stars := PackedVector2Array()
var _f_small: Font
var _f_label: Font
var _f_title: Font

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	visible = false
	_f_small = HudTheme.text_font({"fs": 8.0, "ls": 1.6})
	_f_label = HudTheme.text_font({"fs": 9.0, "ls": 1.8})
	_f_title = HudTheme.text_font({"fs": 11.0, "ls": 4.0})
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 420: _stars.append(Vector2(rng.randf(), rng.randf()))
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	card = HudPanel.new([18, 20, 18, 20], false)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(card)

func open(f) -> void:
	flight = f
	visible = true
	grab_focus()
	follow_ship = true
	follow = null
	if flight.vessel != null:
		_frame_on(flight.vessel.parent, true)
	if flight.mission != null and dest == null:
		dest = flight.mission.dest
		goal = flight.mission.goal
	_plan_age = 99.0
	_card_key = ""

func close() -> void:
	visible = false
	closed.emit()

# GEOMETRY

func _au(b: Body) -> DVec3: return b.pos
func ship_pos() -> DVec3:
	return (flight.vessel as Vessel).world_pos()

## World AU → screen px. The view looks down on the ecliptic with prograde
## counter-clockwise.
func to_screen(p: DVec3) -> Vector2:
	return size * 0.5 + Vector2(float(p.x - center.x), -float(p.z - center.z)) * k

func to_world(s: Vector2) -> DVec3:
	var d := (s - size * 0.5) / k
	return DVec3.new(center.x + d.x, center.y, center.z - d.y)

func _primary(b: Body):
	return flight.vessel.primary_of(b) if flight.vessel != null else null

## A body's conic about its primary, as world points: [points (AU), closed].
func _conic(r: DVec3, v: DVec3, mu: float, origin: DVec3, soi := INF) -> Array:
	var h := DVec3.new().cross_vectors(r, v)
	var hl := h.length()
	if hl <= 0.0: return [PackedVector2Array(), false]
	var e_vec := DVec3.new().cross_vectors(v, h).scale_in(1.0 / mu).sub_in(r.clone().scale_in(1.0 / r.length()))
	var e := e_vec.length()
	var p := hl * hl / mu
	var P := e_vec.scaled(1.0 / e) if e > 1e-7 else r.scaled(1.0 / r.length())
	var Q := DVec3.new().cross_vectors(h.scaled(1.0 / hl), P)
	var pts := PackedVector2Array()
	var lo := 0.0
	var hi := TAU
	var closed := e < 1.0
	if not closed:
		var nu_max := acos(DQuat.jclamp(-1.0 / e, -1.0, 1.0)) - 0.02
		if is_finite(soi): nu_max = minf(nu_max, acos(DQuat.jclamp((p / soi - 1.0) / e, -1.0, 1.0)))
		lo = -nu_max; hi = nu_max
	elif is_finite(soi) and p / (1.0 - e) > soi:
		# An ellipse that leaves the sphere: only the part inside it.
		var nu_max := acos(DQuat.jclamp((p / soi - 1.0) / e, -1.0, 1.0))
		lo = -nu_max; hi = nu_max
		closed = false
	var n := 120
	for i in n + 1:
		var nu := lerpf(lo, hi, float(i) / n)
		var rr := p / (1.0 + e * cos(nu))
		var w := P.scaled(rr * cos(nu)).add_in(Q.scaled(rr * sin(nu))).scale_in(1.0 / Rocketry.AU_M).add_in(origin)
		pts.append(to_screen(w))
	return [pts, closed]

func _dot_radius(b: Body) -> float:
	var true_r := b.radius * k
	var base := 6.0 if b.type == "star" else (4.0 if _primary(b) != null and _primary(b).type == "star" else 2.6)
	return maxf(true_r, base)

func _color(b: Body) -> Color:
	if COLORS.has(b.name): return COLORS[b.name]
	return Color(1.0, 0.9, 0.72) if b.type == "star" else Color(0.78, 0.8, 0.84)

## Centre on a body and zoom to its system: its moons' orbits, or a few radii.
func _frame_on(b: Body, instant := false) -> void:
	follow = b
	follow_ship = false
	var reach := b.radius * 12.0
	for c in flight.bodies():
		if c != b and _primary(c) == b:
			reach = maxf(reach, c.pos.distance_to(b.pos) * 1.25)
	if flight.vessel != null and flight.vessel.parent == b:
		reach = maxf(reach, flight.vessel.r.length() / Rocketry.AU_M * 2.4)
	_k_goal = clampf(minf(size.x, size.y) * 0.42 / maxf(reach, 1e-12), ZOOM_MIN, ZOOM_MAX)
	if instant: k = _k_goal
	center.copy_from(b.pos)

# FRAME

func _process(dt: float) -> void:
	if not visible or flight == null or flight.vessel == null: return
	k = exp(lerpf(log(k), log(_k_goal), 1.0 - exp(-dt * 10.0)))
	if follow != null and follow.alive:
		center = center.lerp_in(follow.pos, 1.0 - exp(-dt * 10.0)) if center.distance_to(follow.pos) * k > 1.0 else follow.pos.clone()
	elif follow_ship:
		center.copy_from(ship_pos())
	_plan_age += dt
	if dest != null and _plan_age > 0.5:
		_plan_age = 0.0
		plan = Mission.plan_route(flight.vessel, dest, goal) if dest.alive else {}
	_update_card()
	queue_redraw()

func _draw() -> void:
	if flight == null or flight.vessel == null: return
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	for s in _stars:
		draw_rect(Rect2(s * size, Vector2(1, 1)), Color(1, 1, 1, 0.05 + 0.1 * fmod(s.x * 37.0, 1.0)))
	_draw_scale()
	var v: Vessel = flight.vessel
	var bodies: Array = flight.bodies()
	# Orbits first, under everything.
	for b in bodies:
		var c = _primary(b)
		if c == null: continue
		var a_px: float = b.pos.distance_to(c.pos) * k
		if a_px < 5.0 or a_px > 4e5: continue
		var r := DVec3.new().sub_vectors(b.pos, c.pos).scale_in(Rocketry.AU_M)
		var vv := DVec3.new().sub_vectors(b.vel, c.vel).scale_in(Rocketry.AU_M / Rocketry.YR_S)
		var cn := _conic(r, vv, Rocketry.GM_SUN * (c.mass + b.mass), c.pos)
		var lit: bool = b == dest or b == hover
		_polyline(cn[0], ORBIT_LIT if lit else ORBIT, 1.0, cn[1])
	_draw_route()
	# The vessel's own conic about its parent, clipped to the sphere it is in.
	var mu := Rocketry.GM_SUN * v.parent.mass
	var cn := _conic(v.to_world(v.r, DVec3.new()), v.to_world(v.v, DVec3.new()), mu, v.parent.pos, v.soi_of(v.parent))
	_polyline(cn[0], Color(SHIP, 0.8), 1.4, cn[1])
	# Bodies, then labels on top.
	var labels: Array = []
	for b in bodies:
		var p := to_screen(b.pos)
		if p.x < -60 or p.y < -60 or p.x > size.x + 60 or p.y > size.y + 60: continue
		var rr := _dot_radius(b)
		var col := _color(b)
		if b.type == "star":
			for i in 4: draw_circle(p, rr * (1.6 + i * 0.9), Color(col, 0.05), true, -1.0, true)
		draw_circle(p, rr, col, true, -1.0, true)
		if b == dest:
			draw_circle(p, rr + 7.0, ROUTE, false, 1.2, true)
			_pin(p - Vector2(0, rr + 9.0))
		elif b == hover:
			draw_circle(p, rr + 5.0, Color(1, 1, 1, 0.5), false, 1.0, true)
		var c = _primary(b)
		var shown: bool = b == dest or b == hover or b == v.parent or c == null or c.type == "star" \
			or (c != null and b.pos.distance_to(c.pos) * k > 34.0)
		if shown: labels.append([b.name.to_upper(), p + Vector2(rr + 6.0, 3.0), b == dest or b == hover])
	var sp := to_screen(ship_pos())
	_ship_marker(sp, v)
	for l in labels:
		draw_string(_f_label, l[1], l[0], HORIZONTAL_ALIGNMENT_LEFT, -1, HudTheme.px(9.0 * HudTheme.UI_SCALE), Color(1, 1, 1, 0.92 if l[2] else 0.55))
	_draw_header()

func _polyline(pts: PackedVector2Array, col: Color, w: float, closed: bool) -> void:
	if pts.size() < 2: return
	if closed: pts.append(pts[0])
	draw_polyline(pts, col, w, true)

func _pin(p: Vector2) -> void:
	draw_line(p, p - Vector2(0, 14), ROUTE, 1.2, true)
	draw_circle(p - Vector2(0, 17), 3.5, ROUTE, true, -1.0, true)

func _ship_marker(p: Vector2, v: Vessel) -> void:
	var dir := Vector2(float(v.v.x), -float(v.v.z))
	dir = dir.normalized() if dir.length() > 1e-6 else Vector2.UP
	var n := Vector2(-dir.y, dir.x)
	var tri := PackedVector2Array([p + dir * 8.0, p - dir * 5.0 + n * 5.0, p - dir * 2.5, p - dir * 5.0 - n * 5.0])
	draw_circle(p, 13.0, Color(SHIP, 0.08), true, -1.0, true)
	draw_colored_polygon(tri, SHIP)
	# Left of the marker, clear of the parent's label on its right.
	var t := v.name.to_upper()
	var fs := HudTheme.px(8.0 * HudTheme.UI_SCALE)
	var w := _f_small.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_f_small, p + Vector2(-w - 14.0, -8.0), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(SHIP, 0.9))

## The planned transfer as a dashed half-ellipse, from where the vehicle leaves to
## where the destination will be.
func _draw_route() -> void:
	if dest == null or plan.is_empty() or not plan.get("ok", false): return
	var v: Vessel = flight.vessel
	var C: Body = null
	var r0 := 0.0
	var r2 := 0.0
	var ang0 := 0.0
	match str(plan.case):
		"moon":
			C = v.parent
			r0 = maxf(v.r.length(), Mission.park_radius(C))
			r2 = Mission._rel_pos(dest, C).length()
			var rw := v.to_world(v.r, DVec3.new())
			ang0 = atan2(-float(rw.z), float(rw.x)) if v.phase == Vessel.PHASE.ORBIT else atan2(-float(Mission._rel_pos(dest, C).z), float(Mission._rel_pos(dest, C).x)) + PI
		"planet":
			C = plan.primary
			var rp := Mission._rel_pos(v.parent, C)
			r0 = rp.length(); r2 = Mission._rel_pos(dest, C).length()
			# From where the planet will be when the window opens.
			var re := DVec3.new(); var ve := DVec3.new()
			if Orbit.propagate(rp, Mission._rel_vel(v.parent, C), Rocketry.GM_SUN * C.mass, float(plan.wait), re, ve): rp = re
			ang0 = atan2(-float(rp.z), float(rp.x))
			_ghost(C.pos.clone().add_scaled_in(rp, 1.0 / Rocketry.AU_M), "Departure")
		"parent":
			C = dest
			var rp := Mission._rel_pos(v.parent, C)
			r0 = rp.length(); r2 = float(plan.r_cap)
			ang0 = atan2(-float(rp.z), float(rp.x))
		_:
			return
	var a := (r0 + r2) * 0.5
	var e := absf(r2 - r0) / (r2 + r0)
	var o := to_screen(C.pos)
	var pts := PackedVector2Array()
	for i in 361:
		var nu := PI * float(i) / 360.0
		var rr := a * (1.0 - e * e) / (1.0 + e * cos(nu)) if r2 >= r0 else a * (1.0 - e * e) / (1.0 - e * cos(nu))
		var th := ang0 + nu
		pts.append(o + Vector2(cos(th), -sin(th)) * rr / Rocketry.AU_M * k)
	_dashed(pts, ROUTE, 1.4, 7.0, 5.0)
	# the arrival orbit
	var cap_px := float(plan.r_cap) / Rocketry.AU_M * k
	if cap_px > 3.0: draw_circle(to_screen(dest.pos), cap_px, Color(ROUTE, 0.5), false, 1.0, true)

## Where something will be: an open ring and a small label.
func _ghost(p: DVec3, label: String) -> void:
	var q := to_screen(p)
	draw_circle(q, 4.0, Color(ROUTE, 0.9), false, 1.0, true)
	draw_string(_f_small, q + Vector2(8, 14), label.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, HudTheme.px(7.5 * HudTheme.UI_SCALE), Color(ROUTE, 0.8))

## A polyline dashed by length along it, so the dashes stay even where the points crowd.
func _dashed(pts: PackedVector2Array, col: Color, w: float, on: float, off: float) -> void:
	var s := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var seg := a.distance_to(b)
		var t := 0.0
		while t < seg:
			var period := on + off
			var ph := fmod(s + t, period)
			var step := minf((on - ph) if ph < on else (period - ph), seg - t)
			if ph < on:
				draw_line(a.lerp(b, t / seg), a.lerp(b, (t + step) / seg), col, w, true)
			t += maxf(step, 0.01)
		s += seg

## Frame the trip: the body the transfer goes round, so both ends are in view.
func frame_route() -> void:
	if dest == null or flight.vessel == null: return
	var v: Vessel = flight.vessel
	var p := Mission.plan_route(v, dest, goal)
	match str(p.get("case", "")):
		"planet", "other":
			var C: Body = p.get("primary", v.parent)
			follow = C
			follow_ship = false
			var reach := maxf(C.pos.distance_to(dest.pos), C.pos.distance_to(v.parent.pos)) * 1.3
			_k_goal = clampf(minf(size.x, size.y) * 0.45 / reach, ZOOM_MIN, ZOOM_MAX)
		"moon", "parent":
			var C2: Body = v.parent if p.case == "moon" else dest
			_frame_on(C2)

func _draw_scale() -> void:
	# A bar of a round length, bottom left, and its label.
	var target_px := 140.0
	var au := target_px / k
	var m := au * Rocketry.AU_M
	var p10 := pow(10.0, floor(log(m) / log(10.0)))
	var nice := p10
	for f in [1.0, 2.0, 5.0, 10.0]:
		if p10 * f <= m: nice = p10 * f
	var w := nice / Rocketry.AU_M * k
	var y := size.y - 34.0
	var x := 28.0
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(1, 1, 1, 0.55), 1.0)
	draw_line(Vector2(x, y - 4), Vector2(x, y + 4), Color(1, 1, 1, 0.55), 1.0)
	draw_line(Vector2(x + w, y - 4), Vector2(x + w, y + 4), Color(1, 1, 1, 0.55), 1.0)
	draw_string(_f_small, Vector2(x, y - 9), FlightUI.fmt_dist(nice).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, HudTheme.px(8.0 * HudTheme.UI_SCALE), Color(1, 1, 1, 0.6))

func _draw_header() -> void:
	var fs := HudTheme.px(11.0 * HudTheme.UI_SCALE)
	draw_string(_f_title, Vector2(28, 40), "SPACE MAP", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.9))
	var v: Vessel = flight.vessel
	var sub := "%s · around %s · %s" % [v.name, v.parent.name, "T+ " + Guidance.fmt_dur(v.met)]
	draw_string(_f_small, Vector2(28, 58), sub.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, HudTheme.px(8.0 * HudTheme.UI_SCALE), Color(1, 1, 1, 0.5))
	var hint := "SCROLL ZOOM · DRAG PAN · CLICK FOLLOW · RIGHT-CLICK A WORLD TO GO THERE · F YOUR SHIP · M CLOSE"
	var hs := HudTheme.px(7.5 * HudTheme.UI_SCALE)
	var hw := _f_small.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs).x
	draw_string(_f_small, Vector2((size.x - hw) * 0.5, size.y - 18.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs, Color(1, 1, 1, 0.32))

# INPUT

func _body_at(p: Vector2) -> Body:
	var best: Body = null
	var best_d := 18.0
	for b in flight.bodies():
		var d := to_screen(b.pos).distance_to(p) - _dot_radius(b)
		if d < best_d:
			best_d = d; best = b
	return best

func _gui_input(e: InputEvent) -> void:
	if flight == null or flight.vessel == null: return
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if mm.position.distance_to(_press) > 4.0: _dragging = true
			if _dragging:
				follow = null; follow_ship = false
				center.x -= mm.relative.x / k
				center.z += mm.relative.y / k
		hover = _body_at(mm.position)
		accept_event()
	elif e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				var f := 1.18 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.18
				_zoom(f, mb.position)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press = mb.position; _dragging = false
			elif not _dragging:
				var b := _body_at(mb.position)
				if b != null: _frame_on(b)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_open_menu(_body_at(mb.position), mb.position)
			accept_event()
	elif e is InputEventKey:
		var ke := e as InputEventKey
		if ke.pressed and not ke.echo and ke.physical_keycode == KEY_F:
			follow = null; follow_ship = true
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
	if follow == null and not follow_ship:
		# Keep the point under the pointer still.
		var d := (about - size * 0.5) / _k_goal
		center.set_v(before.x - d.x, center.y, before.z + d.y)
		k = _k_goal


const MENU_ORBIT := 1
const MENU_LAND := 2
const MENU_FOCUS := 3
const MENU_SHIP := 4
const MENU_CLEAR := 5

func _open_menu(b: Body, at: Vector2) -> void:
	_menu.clear()
	_menu_body = b
	if b != null:
		_menu.add_item("Orbit %s" % b.name, MENU_ORBIT)
		var land := Mission.plan_route(flight.vessel, b, "land")
		if b.type != "star":
			_menu.add_item("Land on %s" % b.name, MENU_LAND)
			_menu.set_item_disabled(_menu.get_item_index(MENU_LAND), not land.ok or land.why != "")
			if land.why != "": _menu.set_item_tooltip(_menu.get_item_index(MENU_LAND), str(land.why))
		_menu.add_separator()
		_menu.add_item("Centre on %s" % b.name, MENU_FOCUS)
	_menu.add_item("Centre on your ship", MENU_SHIP)
	if dest != null: _menu.add_item("Clear destination", MENU_CLEAR)
	_menu.position = Vector2i(get_screen_position() + at)
	_menu.reset_size()
	_menu.popup()

func _on_menu(id: int) -> void:
	match id:
		MENU_ORBIT, MENU_LAND:
			dest = _menu_body
			goal = "land" if id == MENU_LAND else "orbit"
			_plan_age = 99.0
			_card_key = ""
			frame_route()
		MENU_FOCUS: if _menu_body != null: _frame_on(_menu_body)
		MENU_SHIP:
			follow = null; follow_ship = true
		MENU_CLEAR:
			dest = null; plan = {}; _card_key = ""

# THE ROUTE CARD

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED: _place_card()

func _place_card() -> void:
	var w := 340.0
	card.size = Vector2(w, 0)
	card.size = Vector2(w, card.natural_height())
	card.position = Vector2(size.x - w - 28.0, 28.0)

func _update_card() -> void:
	var m: Mission = flight.mission
	var running: bool = m != null and not m.done and m.failed == ""
	card.visible = dest != null or running
	if not card.visible: return
	var key := ""
	if running: key = "run|%s|%d|%s" % [m.title(), m.leg, m.status]
	else: key = JSON.stringify([dest.name if dest else "", goal, int(float(plan.get("dv", 0.0)) / 50.0), int(float(plan.get("wait", 0.0)) / 86400.0), plan.get("why", ""), plan.get("flyable", false)])
	if key == _card_key: return
	_card_key = key
	Hud._clear(card.body)
	if running: _card_running(m)
	elif not plan.is_empty(): _card_route()
	_place_card.call_deferred()

const H_BIG := {"fs": 17.0, "ls": 3.2, "up": true, "c": HudTheme.ACCENT}
const H_SUB := {"fs": 8.5, "ls": 1.8, "up": true, "c": HudTheme.TEXT_DIM}
const ROW_K := {"fs": 9.5, "c": HudTheme.TEXT_DIM}
const ROW_V := {"fs": 9.5, "c": HudTheme.TEXT}

func _card_route() -> void:
	var body := card.body
	Hud.label(body, ("Land on %s" if goal == "land" else "To %s") % dest.name, H_BIG)
	Hud.m(Hud.label(body, str(plan.type) if plan.type != "" else "—", H_SUB), 4.0, 14.0)
	var ok: bool = plan.flyable
	var spare: float = float(plan.dv_avail) - float(plan.dv)
	var verdict := ""
	if plan.why != "": verdict = str(plan.why)
	elif ok: verdict = "Within reach · %s to spare" % FlightUI.fmt_speed(spare)
	else: verdict = "Short by %s" % FlightUI.fmt_speed(float(plan.short))
	Hud.m(Hud.label(body, verdict, {"fs": 10.0, "c": HudTheme.ACCENT_2 if ok else HudTheme.WARN}, true), 0.0, 8.0)
	var bar := FuelBar.new(float(plan.dv), float(plan.dv_avail))
	body.add_child(Hud.m(bar, 2.0, 6.0))
	var g := Hud.grid(body, [1.0, 1.0], 10.0, 2.0, 0.0, 12.0)
	_kv(g, "Δv needed", FlightUI.fmt_speed(float(plan.dv)))
	_kv(g, "Δv on board", FlightUI.fmt_speed(float(plan.dv_avail)))
	_kv(g, "Propellant", FlightUI.fmt_mass_t(float(plan.prop)))
	_kv(g, "In the tanks", FlightUI.fmt_mass_t(float(plan.prop_avail)))
	var times := Hud.grid(body, [1.0, 1.0], 10.0, 2.0, 0.0, 12.0)
	_kv(times, "Window in", Guidance.fmt_dur(float(plan.wait)) if float(plan.wait) > 60.0 else "now")
	_kv(times, "En route", Guidance.fmt_dur(float(plan.tof)) if float(plan.tof) > 0.0 else "—")
	Hud.label(body, "Route", {"fs": 8.0, "ls": 2.2, "up": true, "c": HudTheme.TEXT_DIM, "fw": 500})
	var legs := Hud.stack(body, 6.0, 14.0)
	for l in plan.legs:
		var r := Hud.hbox(legs, 8.0, 0.0, 4.0)
		var n := Hud.label(r, str(l.label), ROW_V)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		Hud.label(r, FlightUI.fmt_speed(float(l.dv)), ROW_K)
	var btns := Hud.grid(body, [1.0, 1.0], 8.0, 0.0)
	var flyb := HudButton.new("Primary", "Fly mission", "The autopilot flies every leg; time warp is chosen for you")
	btns.add_child(flyb)
	var skipb := HudButton.new("Secondary", "Skip to arrival", "Charge the propellant and the time, and arrive in the parking orbit; the trajectory is not flown")
	btns.add_child(skipb)
	flyb.disabled = not ok
	skipb.disabled = not ok
	if not ok:
		flyb.modulate.a = 0.4; skipb.modulate.a = 0.4
	var d := dest.name
	var gl := goal
	flyb.pressed.connect(func(): fly.emit(d, gl))
	skipb.pressed.connect(func(): skip.emit(d, gl))

func _card_running(m: Mission) -> void:
	var body := card.body
	Hud.label(body, m.title(), H_BIG)
	Hud.m(Hud.label(body, "Mission in progress", H_SUB), 4.0, 12.0)
	var legs := Hud.stack(body, 0.0, 12.0)
	var ls: Array = m.legs()
	for i in ls.size():
		var r := Hud.hbox(legs, 8.0, 0.0, 4.0)
		var mark := "●" if i < m.leg else ("◉" if i == m.leg else "○")
		Hud.label(r, mark, {"fs": 9.0, "c": HudTheme.ACCENT_2 if i == m.leg else HudTheme.TEXT_DIM})
		var n := Hud.label(r, str(ls[i].label), ROW_V if i == m.leg else ROW_K)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	Hud.m(Hud.label(body, m.status, {"fs": 9.5, "c": HudTheme.TEXT}, true), 0.0, 12.0)
	var ab := HudButton.new("Secondary", "Abort mission", "Stop; the vehicle keeps its course under manual control")
	body.add_child(ab)
	ab.pressed.connect(func(): abort.emit())

func _kv(parent: Node, k_: String, v_: String) -> void:
	var st := Hud.stack(parent)
	Hud.label(st, k_, {"fs": 7.5, "ls": 1.6, "up": true, "c": HudTheme.TEXT_DIM})
	Hud.label(st, v_, {"fs": 12.0, "c": HudTheme.TEXT})

## Δv needed against Δv on board: the tank, and a tick where the trip ends.
class FuelBar extends Control:
	var need := 0.0
	var have := 0.0
	func _init(n: float, h: float) -> void:
		need = n; have = h
		custom_minimum_size = Vector2(100, 10)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var full := maxf(maxf(need, have), 1.0)
		var w := size.x
		draw_rect(Rect2(0, 3, w, 4), Color(1, 1, 1, 0.08))
		draw_rect(Rect2(0, 3, w * have / full, 4), Color(1, 1, 1, 0.35))
		var ok := need <= have
		draw_rect(Rect2(0, 3, w * minf(need, have) / full, 4), HudTheme.ACCENT_2 if ok else HudTheme.WARN)
		var x := w * need / full
		draw_line(Vector2(x, 0), Vector2(x, 10), HudTheme.ACCENT if ok else HudTheme.WARN, 1.5)
