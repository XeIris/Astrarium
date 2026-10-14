class_name FlightConsole
extends Control

# The flight console along the bottom of the frame: what flying needs at a glance —
# altitude, speed, the orbit, the attitude ball with its throttle and climb tapes,
# propellant, time warp — and the mission's legs as a route. Everything else is in
# the Systems panel (FlightUI). Built in the title screen's language: tracked small
# capitals over light figures, hairlines, glass.

signal action(name: String)

const VALUE := {"fs": 15.0, "c": HudTheme.TEXT}
const KEY := {"fs": 7.5, "ls": 1.8, "up": true, "c": HudTheme.TEXT_DIM, "fw": 500}
const SUB := {"fs": 8.5, "c": HudTheme.TEXT_DIM}
const BALL := 0.66

var panel: HudPanel
var nav: FlightUI.Navball
var thr: FlightUI.Tape
var vs: FlightUI.Tape
var route: Route
var mission_l: Label
var status_l: Label
var warp_l: Label
var prop_bar: PropBar
var cells := {}
var buttons := {}

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel = HudPanel.new([10, 20, 12, 20], false)
	add_child(panel)
	var col := panel.body

	# The mission: its name, the route of legs, and what it is doing now.
	var top := Hud.hbox(col, 14.0, 0.0, 8.0)
	mission_l = Hud.label(top, "Manual flight", {"fs": 8.5, "ls": 2.4, "up": true, "c": HudTheme.ACCENT, "fw": 500})
	mission_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	route = Route.new()
	route.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(route)
	status_l = Hud.label(top, "", {"fs": 9.0, "c": HudTheme.TEXT_DIM})
	status_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_l.clip_text = true
	status_l.custom_minimum_size.x = 300.0
	status_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var row := Hud.hbox(col, 22.0)
	row.add_child(_spring())
	var left := Hud.grid(row, [1.0, 1.0], 22.0, 8.0)
	left.custom_minimum_size.x = 250.0
	left.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for k in [["alt", "Altitude"], ["speed", "Speed"], ["apo", "Apoapsis"], ["peri", "Periapsis"]]:
		cells[k[0]] = _cell(left, k[1])

	# The ball, scaled into the strip, between its two tapes.
	var mid := Hud.hbox(row, 8.0)
	thr = FlightUI.Tape.new("THR", false)
	thr.custom_minimum_size = Vector2(14, 124)
	thr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mid.add_child(thr)
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(FlightUI.Navball.W, FlightUI.Navball.H) * BALL
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nav = FlightUI.Navball.new()
	nav.scale = Vector2(BALL, BALL)
	holder.add_child(nav)
	mid.add_child(holder)
	vs = FlightUI.Tape.new("V/S", true)
	vs.custom_minimum_size = Vector2(14, 124)
	vs.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	mid.add_child(vs)

	var right := Hud.grid(row, [1.0, 1.0], 22.0, 8.0)
	right.custom_minimum_size.x = 250.0
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cells["dv"] = _cell(right, "Δv left")
	cells["met"] = _cell(right, "Mission time")
	var pcell := Hud.stack(right)
	Hud.label(pcell, "Stage", KEY)
	cells["stage"] = Hud.label(pcell, "—", {"fs": 11.0, "c": HudTheme.TEXT})
	(cells["stage"] as Label).clip_text = true
	prop_bar = PropBar.new()
	pcell.add_child(Hud.m(prop_bar, 4.0))
	var wcell := Hud.stack(right)
	Hud.label(wcell, "Time warp", KEY)
	var wr := Hud.hbox(wcell, 4.0, 2.0)
	var wd := _btn(wr, "◂", "warp-", "Slow time (,)")
	wd.custom_minimum_size = Vector2(20, 18)
	warp_l = Hud.label(wr, "1×", {"fs": 11.0, "c": HudTheme.TEXT})
	warp_l.custom_minimum_size.x = 64.0
	warp_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var wu := _btn(wr, "▸", "warp+", "Speed time (.)")
	wu.custom_minimum_size = Vector2(20, 18)
	row.add_child(_spring())

	var foot := Hud.hbox(col, 6.0, 10.0)
	foot.add_child(_spring())
	for b in [["map", "Map  ·  M", "The space map: pick a destination and fly there"],
			["systems", "Systems", "Telemetry, stages, autopilot programs and the flight log"],
			["camera", "Camera  ·  C", "Cycle the flight camera"],
			["autowarp", "Auto warp", "Let the mission choose the time warp"],
			["abort", "Abort mission", "Stop the mission; the vehicle keeps its course under manual control"],
			["hangar", "Hangar", "Back to the craft selection"],
			["exit", "Exit", "Leave spaceflight"]]:
		buttons[b[0]] = _btn(foot, b[1], b[0], b[2], "Console")
	foot.add_child(_spring())

static func _spring() -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

func _btn(parent: Node, text: String, id: String, tip: String, kind := "Warp") -> HudButton:
	var b := HudButton.new(kind, text, tip)
	parent.add_child(b)
	b.pressed.connect(func(): action.emit(id))
	return b

func _cell(parent: Node, key: String) -> Array:
	var st := Hud.stack(parent)
	Hud.label(st, key, KEY)
	var v := Hud.label(st, "—", VALUE)
	return [v]

func _put(k: String, t: String) -> void:
	var l: Label = cells[k][0] if cells[k] is Array else cells[k]
	if l.text != t: l.text = t

func height() -> float:
	return panel.get_combined_minimum_size().y

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		panel.size = size

## `s`: FlightUI.update's dictionary, plus `mission` (Mission or null) and `skip`.
func update(s: Dictionary) -> void:
	var t: Dictionary = s.telemetry
	var v: Vessel = s.vessel
	nav.draw_ball(v.q.to_quaternion(), s.up, s.north, s.markers, {"roll": s.get("roll")})
	thr.set_frac(float(U.jround(v.throttle * 100.0)) / 100.0)
	var vsv := clampf(float(U.nz(t.get("vertical"), 0.0)) / 400.0, -1.0, 1.0)
	vs.set_frac(float(U.fixed(50.0 + vsv * 46.0, 1)) / 100.0)
	var tn := func(k: String) -> float: return float(U.nz(t.get(k), NAN))
	_put("alt", FlightUI.fmt_dist(tn.call("alt")))
	_put("speed", FlightUI.fmt_speed(tn.call("speed")))
	_put("apo", FlightUI.fmt_dist(t.apo) if is_finite(float(U.nz(t.get("apo"), INF))) else "escape")
	_put("peri", FlightUI.fmt_dist(tn.call("peri")))
	_put("dv", FlightUI.fmt_speed(float(U.nz(t.get("dv"), 0.0))))
	_put("met", Guidance.fmt_dur(v.met))
	var st = v.current_stage
	if st == null: st = v.next_stage
	if st == null:
		for x in v.stages:
			if x.attached: st = x; break
	if st != null:
		_put("stage", str(st.spec.name))
		prop_bar.set_frac(st.prop / st.prop0 if st.prop0 > 0.0 else 0.0)
	var w := "%s×" % U.grouped(float(s.warp))
	if s.get("skip"): w = "skipping"
	if warp_l.text != w: warp_l.text = w

	var m: Mission = s.get("mission")
	var flying := m != null and not m.done and m.failed == ""
	buttons.abort.visible = flying
	buttons.autowarp.visible = flying and not m.auto_warp
	if m == null:
		_say(mission_l, "Manual flight · %s" % str(s.parentName))
		route.set_legs([], -1)
		_say(status_l, str(s.status))
	else:
		_say(mission_l, ("Mission · " + m.title()) if m.failed == "" else "Mission ended")
		route.set_legs(m.legs(), m.leg if not m.done else m.legs().size())
		_say(status_l, m.failed if m.failed != "" else (m.status if m.status != "" else str(s.status)))

func _say(l: Label, t: String) -> void:
	if l.text != t: l.text = t

## The mission as a route: a dot per leg on a hairline, done legs filled, the current
## one ringed, with its name under it.
class Route extends Control:
	var legs: Array = []
	var at := -1
	func _init() -> void:
		custom_minimum_size = Vector2(200, 26)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func set_legs(l: Array, i: int) -> void:
		if l.size() == legs.size() and i == at: return
		legs = l.duplicate()
		at = i
		queue_redraw()
	func _draw() -> void:
		if legs.is_empty(): return
		var n := legs.size()
		var y := 8.0
		var x0 := 8.0
		var x1 := size.x - 8.0
		var step := (x1 - x0) / maxf(n - 1, 1)
		draw_line(Vector2(x0, y), Vector2(x1, y), Color(1, 1, 1, 0.16), 1.0)
		if at > 0:
			draw_line(Vector2(x0, y), Vector2(x0 + step * mini(at, n - 1), y), Color(1, 1, 1, 0.7), 1.0)
		var f := HudTheme.text_font({"fs": 7.0, "ls": 1.2})
		var fs := HudTheme.px(7.0 * HudTheme.UI_SCALE)
		for i in n:
			var p := Vector2(x0 + step * i, y)
			if i < at:
				draw_circle(p, 3.0, Color(1, 1, 1, 0.9), true, -1.0, true)
			elif i == at:
				draw_circle(p, 4.5, HudTheme.ACCENT_2, false, 1.2, true)
				draw_circle(p, 2.0, HudTheme.ACCENT_2, true, -1.0, true)
			else:
				draw_circle(p, 3.0, Color(0.05, 0.06, 0.08), true, -1.0, true)
				draw_circle(p, 3.0, Color(1, 1, 1, 0.35), false, 1.0, true)
			if i == at:
				var t := str(legs[i].label).to_upper()
				var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var tx := clampf(p.x - w * 0.5, 0.0, size.x - w)
				draw_string(f, Vector2(tx, y + 15.0), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
					Color(1, 1, 1, 0.85 if i == at else 0.38))

## The live stage's propellant: a hairline bar.
class PropBar extends Control:
	var frac := 0.0
	func _init() -> void:
		custom_minimum_size = Vector2(80, 3)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func set_frac(f: float) -> void:
		f = clampf(f, 0.0, 1.0)
		if absf(f - frac) > 0.002:
			frac = f
			queue_redraw()
	func _draw() -> void:
		draw_rect(Rect2(0, 1, size.x, 1), Color(1, 1, 1, 0.14))
		draw_rect(Rect2(0, 0, size.x * frac, 3), Color(1, 1, 1, 0.85) if frac > 0.12 else HudTheme.WARN)
