class_name VoyagerChart
extends Control

const AMBER := Color("#f5c780")
const BLUE := Color("#87cee6")
const INK := Color("#a4b3bc")
const GRID := Color("#263943")
const PLANETS := ["Earth", "Jupiter", "Saturn", "Uranus", "Neptune", "Mars", "Venus", "Mercury"]
const MOON_SYSTEM := {"Io": "Jupiter", "Titan": "Saturn", "Miranda": "Uranus", "Triton": "Neptune"}
const AU_KM := Rocketry.AU_M / 1000.0
var archive: VoyagerArchive
var probe := "Voyager 1"
var utc := 0.0
var center_body := ""
var azimuth := -0.75
var elevation := 0.46
var zoom := 1.0
var pan := Vector2.ZERO
var pixels_per_au := 1.0
var origin := Vector2.ZERO
var labels: Array[Rect2] = []

func _ready() -> void:
	clip_contents = true
	mouse_force_pass_scroll_events = false

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
		reset_frame()
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		pan += event.relative
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		azimuth -= event.relative.x * 0.008
		elevation = clampf(elevation + event.relative.y * 0.007, -PI/2, PI/2)
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var old_zoom := zoom
		zoom = clampf(zoom * (1.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8), 0.25, 30.0)
		var pivot: Vector2 = event.position - size * 0.5
		pan = pivot + (pan - pivot) * zoom / old_zoom
	else:
		return
	queue_redraw()
	accept_event()

func reset_frame() -> void:
	pan = Vector2.ZERO
	zoom = 1
	queue_redraw()

func _plane(p: DVec3) -> Vector2:
	var along := p.x * cos(azimuth) + p.y * sin(azimuth)
	var across := -p.x * sin(azimuth) + p.y * cos(azimuth)
	return Vector2(along, -across * sin(elevation) - p.z * cos(elevation))

func _screen(p: DVec3) -> Vector2:
	return origin + _plane(p) * pixels_per_au

func _text(pos: Vector2, value: String, height: int, color: Color) -> void:
	draw_string(HudTheme.font("disp"), pos, value, HORIZONTAL_ALIGNMENT_LEFT, -1, height, color)

func _mark(pos: Vector2, title: String, color: Color, radius: float) -> void:
	if not Rect2(Vector2.ZERO, size).grow(-4).has_point(pos): return
	draw_circle(pos, radius, color, true, -1, true)
	var width := HudTheme.font("disp").get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	for offset in [Vector2(8, -6), Vector2(8, 16), Vector2(-width-8, -6), Vector2(-width-8, 16)]:
		var box := Rect2(pos + offset - Vector2(0, 13), Vector2(width, 17))
		if not Rect2(Vector2.ZERO, size).encloses(box) or labels.any(func(r): return r.intersects(box)): continue
		labels.append(box)
		_text(pos + offset, title, 13, color)
		break

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0b1218"))
	if archive == null or size.x < 90 or size.y < 150: return
	labels.clear()
	if center_body.is_empty(): _system()
	else: _encounter()
	var room := minf(size.x * 0.25, 115.0)
	var units := 1.0 if center_body == "" else AU_KM
	var raw := room / pixels_per_au * units
	var mag := pow(10.0, floorf(log(raw) / log(10.0)))
	var scale_value := (5.0 if raw >= 5*mag else (2.0 if raw >= 2*mag else 1.0)) * mag
	var stroke := scale_value / units * pixels_per_au
	var start := Vector2(24, size.y - 40)
	draw_line(start, start + Vector2(stroke, 0), INK, 1)
	for x in [0.0, stroke]:
		draw_line(start + Vector2(x, -3), start + Vector2(x, 3), INK, 1)
	_text(start + Vector2(0, -8), "%s %s" % [U.grouped(roundi(scale_value)) if scale_value >= 1 else str(scale_value), "AU" if center_body == "" else "km"], 12, INK)
	_text(start + Vector2(0, 24), "Drag to rotate   ·   Scroll to zoom   ·   Double-click to fit", 12, INK)

func _system() -> void:
	var locations := {"Sun": DVec3.new()}
	var extent := Rect2(Vector2(-5, -4), Vector2(10, 8))
	for body in PLANETS + VoyagerMissions.PROBES.values():
		var p := archive.position_at(body, utc)
		if p == null: continue
		locations[body] = p
		extent = extent.expand(_plane(p))
	pixels_per_au = minf((size.x - 80) / extent.size.x, (size.y - 145) / extent.size.y) * zoom
	origin = size * 0.5 + pan - extent.get_center() * pixels_per_au
	_text(Vector2(24, 34), "SOLAR SYSTEM   /   HELIOCENTRIC", 14, INK)
	for r in [1, 5, 10, 20, 30, 50, 100, 150]:
		if r * pixels_per_au < 6 or r * pixels_per_au > size.length(): continue
		var ring := PackedVector2Array()
		for i in 129:
			var angle := TAU * i / 128.0
			ring.append(_screen(DVec3.new(r * cos(angle), r * sin(angle), 0)))
		draw_polyline(ring, GRID, 1.0, true)
	for name_ in VoyagerMissions.PROBES.values():
		if not locations.has(name_): continue
		var rows: PackedFloat64Array = archive.tracks[name_]
		var path := PackedVector2Array()
		for i in range(0, rows.size(), VoyagerArchive.STRIDE):
			if rows[i] >= utc: break
			var pt := _screen(DVec3.new(rows[i+1], rows[i+2], rows[i+3]))
			if path.is_empty() or pt.distance_squared_to(path[-1]) > 1: path.append(pt)
		var tip := _screen(locations[name_])
		path.append(tip)
		var color := AMBER if name_ == "Voyager 1" else BLUE
		var p: DVec3 = locations[name_]
		if absf(p.z) * pixels_per_au > 16:
			var foot := _screen(DVec3.new(p.x, p.y, 0))
			draw_dashed_line(tip, foot, color.darkened(0.68), 1, 5, true, true)
			draw_circle(foot, 2, color.darkened(0.45), false, 1, true)
		if path.size() > 1: draw_polyline(path, color, 1.8, true)
		if name_ == probe: draw_arc(tip, 9, 0, TAU, 36, color, 1, true)
		_mark(tip, name_, color, 4)
	if not locations.has(probe):
		_mark(_screen(locations.Earth), probe + " · launch", AMBER if probe == "Voyager 1" else BLUE, 4)
	_mark(origin, "Sun", AMBER.lightened(0.3), 4)
	for planet in PLANETS:
		_mark(_screen(locations[planet]), planet, INK, 2.8)

func _encounter() -> void:
	# Each point uses the target at the same instant as the probe. Holding the
	# planet at its present position would add its orbital velocity to the pass.
	var relative: Array[DVec3] = []
	var reach := 0.00001
	var step := 300.0 if MOON_SYSTEM.has(center_body) else 900.0
	for i in range(-72, 73):
		var t := utc + i * step
		var p := archive.position_at(probe, t)
		var target := archive.position_at(center_body, t)
		if p == null or target == null: return
		var diff := p.sub(target)
		relative.append(diff)
		reach = maxf(reach, _plane(diff).length())
	pixels_per_au = minf(size.x - 88, size.y - 134) * 0.5 / reach * zoom
	origin = size * 0.5 + pan
	_text(Vector2(24, 34), "%s   /   ENCOUNTER" % center_body.to_upper(), 14, INK)
	_text(Vector2(24, 56), "Arrival and departure tracks · ±%d h" % roundi(72 * step / 3600), 13, INK)
	var past := PackedVector2Array()
	var color := AMBER if probe == "Voyager 1" else BLUE
	for i in relative.size():
		var pt := _screen(relative[i])
		if i <= 72: past.append(pt)
		elif i % 2: draw_line(_screen(relative[i-1]), pt, color.darkened(0.32), 1.5, true)
	draw_polyline(past, color, 2.0, true)
	for moon in MOON_SYSTEM:
		if MOON_SYSTEM[moon] != center_body: continue
		var moon_pos := archive.position_at(moon, utc)
		if moon_pos != null:
			_mark(_screen(moon_pos.sub(archive.position_at(center_body, utc))), moon, INK.darkened(0.2), 3)
	_mark(origin, center_body, INK, 5)
	_mark(past[-1], probe, color, 4)
