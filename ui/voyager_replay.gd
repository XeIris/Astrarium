class_name VoyagerReplay
extends Control

signal view_changed(spacecraft: bool)
signal closed
signal model_drag(delta: Vector2)
signal model_zoom(delta: float)
signal model_pose(view: String)
signal model_center(fraction: float)

const CAPTION := {"fs": 10, "ls": 1.6, "up": true, "c": HudTheme.TEXT_DIM}
const BODY := {"fs": 13, "c": HudTheme.TEXT, "lh": 1.4}
const REFERENCES := [
	["JPL spacecraft rendering", "pia14111.jpg", "NASA/JPL-Caltech · PIA14111"],
	["Instrument drawing", "instruments.jpg", "NASA/JPL-Caltech · Voyager instrument guide"],
	["Golden Record installation", "pia21740.jpg", "NASA/JPL-Caltech · Voyager 1, 1977 · PIA21740"],
	["Engraved cover", "record-cover.jpg", "NASA/JPL · Golden Record cover"],
]
var archive: VoyagerArchive
var probe := "Voyager 1"
var utc := 0.0
var events: Array
var stamps := PackedInt64Array()
var encounter := ""
var inspecting := false
var playing := false
var rate := VoyagerArchive.DAY * 365.25
var chart := VoyagerChart.new()
var studio := Control.new()
var panel := HudPanel.new([22, 20, 22, 20], true, Color("#101920"), HudTheme.BORDER, 0.0)
var selector := HudSelect.new()
var landmark := HudSelect.new()
var slider := HSlider.new()
var legend: Prose
var clock_field := LineEdit.new()
var date_pattern := RegEx.new()
var age: Label
var info: Label
var next_event: HudButton
var previous: HudButton
var play: HudButton
var timeline: HudStack
var references: HudStack
var views: Array[HudButton] = []
var frame_button: HudButton
var picture := TextureRect.new()
var poses := HudSelect.new()
var ref_select := HudSelect.new()
var hardware: Prose
var credit: Prose
var rates := HudSelect.new()
var local_clock: HudStack
var local_slider := HSlider.new()
var encounter_stamp := 0

func _ready() -> void:
	archive = load("res://assets/voyager/trajectory.tres")
	chart.archive = archive
	add_child(chart)
	add_child(studio)
	studio.gui_input.connect(_inspect_input)
	add_child(panel)
	var body := panel.body
	Hud.label(body, "Voyager mission archive", CAPTION)
	selector.focus_mode = Control.FOCUS_ALL
	selector.set_options([["Voyager 1", "Voyager 1"], ["Voyager 2", "Voyager 2"]])
	body.add_child(Hud.m(selector, 6, 10))
	selector.chosen.connect(func(p): select_probe(p, utc))
	var tabs := Hud.grid(body, [1, 1], 6, 0, 4, 12)
	views.append(_button(tabs, "Flight path", func(): set_view(false)))
	views.append(_button(tabs, "Spacecraft", func(): set_view(true)))
	timeline = Hud.stack(body)
	Hud.label(timeline, "Mission clock · UTC", CAPTION)
	timeline.add_child(Hud.m(clock_field, 4, 3))
	clock_field.theme_type_variation = "FdInput"
	clock_field.tooltip_text = "Enter a year, YYYY-MM-DD, or YYYY-MM-DD HH:MM:SS in UTC"
	clock_field.select_all_on_focus = true
	clock_field.focus_entered.connect(_stop)
	clock_field.text_submitted.connect(_enter_date)
	clock_field.focus_exited.connect(func(): if not stamps.is_empty(): _refresh())
	date_pattern.compile(r"^(\d{4})(?:-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?)?$")
	age = Hud.label(timeline, "", {"fs": 11, "c": HudTheme.TEXT_DIM})
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.y = 26
	slider.tooltip_text = "Scrub the mission. Arrow keys step one day."
	slider.step = 1
	slider.gui_input.connect(func(e):
		if e is InputEventKey and e.pressed and e.keycode in [KEY_LEFT, KEY_RIGHT]:
			_manual_seek(utc + VoyagerArchive.DAY * (-1 if e.keycode == KEY_LEFT else 1))
			slider.accept_event())
	timeline.add_child(Hud.m(slider, 8, 2))
	slider.value_changed.connect(func(t): _manual_seek(t))
	var controls := Hud.grid(timeline, [1, 1.45], 6, 0, 3, 16)
	play = _button(controls, "Play", _toggle_play)
	controls.add_child(rates)
	rates.focus_mode = Control.FOCUS_ALL
	rates.set_options([["3600", "1 hour / sec"], ["86400", "1 day / sec"], ["31557600", "1 year / sec"]], "31557600")
	rates.chosen.connect(func(r): rate = float(r))
	Hud.label(timeline, "Mission landmarks", CAPTION)
	timeline.add_child(Hud.m(landmark, 6, 4))
	landmark.focus_mode = Control.FOCUS_ALL
	landmark.chosen.connect(func(idx): jump(int(idx)))
	var jumps := Hud.grid(timeline, [1, 1], 6, 0, 2, 10)
	previous = _button(jumps, "Previous", func(): jump(stamps.bsearch(int(utc)) - 1))
	next_event = _button(jumps, "Next", func(): jump(stamps.bsearch(int(utc), false)))
	legend = Hud.label(timeline, "", BODY, true)
	info = Hud.m(Hud.label(timeline, "", {"fs": 15, "c": HudTheme.ACCENT}), 14, 6)
	frame_button = _button(timeline, "Solar System view", _switch_frame)
	local_clock = Hud.stack(timeline, 8, 8)
	Hud.label(local_clock, "Encounter clock · ±12 h", CAPTION)
	local_slider.tooltip_text = "Scrub by the minute around the selected encounter"
	local_slider.step = 60
	local_slider.custom_minimum_size.y = 22
	local_clock.add_child(local_slider)
	local_slider.value_changed.connect(_manual_seek)
	references = Hud.stack(body)
	Hud.label(references, "Spacecraft reference", CAPTION)
	references.add_child(Hud.m(ref_select, 6, 10))
	ref_select.focus_mode = Control.FOCUS_ALL
	var opts := []
	for i in REFERENCES.size(): opts.append([str(i), REFERENCES[i][0]])
	ref_select.set_options(opts)
	ref_select.chosen.connect(func(i): _reference(int(i)))
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	references.add_child(picture)
	credit = Hud.label(references, "", {"fs": 10, "c": HudTheme.TEXT_DIM}, true)
	Hud.m(Hud.label(references, "Inspect hardware", CAPTION), 14, 6)
	var components := []
	for view in VoyagerSpacecraft.VIEWS: components.append([view, view])
	poses.set_options(components)
	poses.focus_mode = Control.FOCUS_ALL
	references.add_child(poses)
	hardware = Hud.m(Hud.label(references, VoyagerSpacecraft.VIEWS["Full span"][4], BODY, true), 10, 8)
	poses.chosen.connect(func(view):
		model_pose.emit(view)
		hardware.say(VoyagerSpacecraft.VIEWS[view][4])
		var ref_id := 3 if view == "Golden Record" else 1 if view in ["Science platform", "Radioisotope generators"] else 0
		ref_select.set_value(str(ref_id))
		_reference(ref_id))
	Hud.m(Hud.label(references, "Drag the model to orbit · Scroll to zoom", CAPTION, true), 12, 6)
	_button(body, "Return to hangar", func(): closed.emit())
	_reference(0)
	resized.connect(_layout)
	set_view(false)
	_layout()

func _button(parent: Node, title: String, action: Callable) -> HudButton:
	var b := HudButton.new("Chip", title)
	b.focus_mode = Control.FOCUS_ALL
	parent.add_child(b)
	b.pressed.connect(action)
	return b

func _layout() -> void:
	var w := clampf(size.x * 0.33, 290, 435)
	var pad := clampf(size.y * 0.035, 10, 32)
	panel.size = Vector2(w, maxf(50, size.y - pad*2))
	panel.position = Vector2(size.x - w - pad, pad)
	chart.size = Vector2(maxf(1, panel.position.x), size.y)
	studio.size = chart.size
	picture.custom_minimum_size.y = clampf(size.y * 0.29, 120, 300)
	model_center.emit(chart.size.x * 0.5 / maxf(1.0, size.x))

func _inspect_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and e.button_mask & MOUSE_BUTTON_MASK_LEFT: model_drag.emit(e.relative)
	elif e is InputEventPanGesture: model_zoom.emit(e.delta.y * 12)
	elif e is InputEventMouseButton and e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		model_zoom.emit((-100.0 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 100.0) * e.factor)

func _reference(i: int) -> void:
	picture.texture = load("res://assets/voyager/" + str(REFERENCES[i][1]))
	credit.say(REFERENCES[i][2])

func set_view(spacecraft: bool) -> void:
	inspecting = spacecraft
	chart.visible = not spacecraft
	studio.visible = spacecraft
	timeline.visible = not spacecraft
	references.visible = spacecraft
	views[0].set_active(not spacecraft)
	views[1].set_active(spacecraft)
	if spacecraft: _stop()
	view_changed.emit(spacecraft)
	queue_redraw()

func _draw() -> void:
	if not inspecting:
		draw_rect(Rect2(Vector2.ZERO, size), Color("#0b1218"))

func select_probe(name_: String, time: float) -> void:
	probe = name_
	selector.set_value(probe)
	chart.center_body = ""
	events = VoyagerMissions.LOG[probe]
	stamps.clear()
	var opts := [["-1", "Jump to a landmark…"]]
	for i in events.size():
		stamps.append(VoyagerMissions.epoch(events[i][0]))
		opts.append([str(i), "%s   %s" % [str(events[i][0]).left(10), events[i][1]]])
	landmark.set_options(opts)
	slider.max_value = VoyagerMissions.epoch(VoyagerMissions.END)
	slider.min_value = stamps[0]
	chart.probe = probe
	chart.reset_frame()
	_manual_seek(time)

func jump(i: int) -> void:
	if i < 0 or i >= stamps.size(): return
	_manual_seek(stamps[i])
	chart.reset_frame()
	chart.center_body = events[i][2]
	encounter_stamp = stamps[i]
	if chart.center_body != "" and rate > VoyagerArchive.DAY:
		rate = 3600
		rates.set_value("3600")
	_refresh()

func _enter_date(text: String) -> void:
	var found := date_pattern.search(text.strip_edges())
	if found:
		var year := found.get_string(1).to_int()
		var month := 1 if found.get_string(2) == "" else found.get_string(2).to_int()
		var day := 1 if found.get_string(3) == "" else found.get_string(3).to_int()
		var h := found.get_string(4).to_int()
		var m := found.get_string(5).to_int()
		var sec := found.get_string(6).to_int()
		if year in range(1977, 2027) and month in range(1, 13) and day in range(1, 32) and h < 24 and m < 60 and sec < 60:
			var first := VoyagerMissions.epoch("%04d-%02d-01" % [year, month])
			var t := first + (day-1)*86400 + h*3600 + m*60 + sec
			if found.get_string(2) == "": t = maxi(t, stamps[0])
			if Time.get_date_dict_from_unix_time(t).month == month or found.get_string(2) == "":
				if t >= stamps[0] and t <= slider.max_value:
					clock_field.release_focus()
					_manual_seek(t)
					return
	age.text = "Enter a valid UTC date within this mission."
	clock_field.select_all()

func _manual_seek(t: float) -> void:
	_stop()
	seek(t)

func seek(t: float) -> void:
	utc = clampf(t, slider.min_value, slider.max_value)
	if utc >= slider.max_value: _stop()
	_refresh()

func _refresh() -> void:
	slider.set_value_no_signal(utc)
	var i := maxi(0, stamps.bsearch(floori(utc), false) - 1)
	var exact := floori(utc) == stamps[i]
	landmark.set_value(str(i) if exact else "-1")
	var date := Time.get_datetime_string_from_unix_time(floori(utc), true)
	if not clock_field.has_focus():
		clock_field.text = date.left(10) if exact and str(events[i][0]).length() == 10 else date
	age.text = "%s days since launch" % U.grouped(floori((utc - stamps[0]) / VoyagerArchive.DAY))
	legend.say(("%s\n" if exact else "Last landmark · %s\n") % events[i][1] + str(events[i][3]))
	previous.set_enabled(utc > stamps[0])
	next_event.set_enabled(utc < stamps[-1])
	var p := archive.position_at(probe, utc)
	if p == null:
		info.text = "Launch at Earth\nFirst trajectory fix at %s UTC" % Time.get_time_string_from_unix_time(int(archive.tracks[probe][0]))
	else:
		var from_earth := p.sub(archive.position_at("Earth", utc)).length()
		var latitude := rad_to_deg(asin(p.z / p.length()))
		info.text = "From Sun     %.3f AU\nFrom Earth   %.3f AU\nLight time     %.3f h one way\nEcliptic latitude   %.1f° %s" % [p.length(), from_earth,
			from_earth * Rocketry.AU_M / Rocketry.C_MS / 3600.0, absf(latitude), "N" if latitude >= 0 else "S"]
	encounter = ""
	var nearest := INF
	for j in events.size():
		var delta := absf(utc - stamps[j])
		if events[j][2] != "" and delta < nearest and delta <= VoyagerArchive.DAY:
			nearest = delta
			encounter = events[j][2]
	if chart.center_body != "" and absf(utc - encounter_stamp) > VoyagerArchive.DAY:
		chart.center_body = ""
		chart.reset_frame()
	if chart.center_body != "" and p != null:
		var target := archive.position_at(chart.center_body, utc)
		info.text += "\n%s centre   ≈ %s km" % [chart.center_body, U.grouped(roundi(p.sub(target).length() * VoyagerChart.AU_KM / 100) * 100)]
	local_clock.visible = chart.center_body != ""
	if local_clock.visible:
		local_slider.set_block_signals(true)
		local_slider.max_value = encounter_stamp + VoyagerArchive.DAY / 2
		local_slider.min_value = encounter_stamp - VoyagerArchive.DAY / 2
		local_slider.set_value_no_signal(utc)
		local_slider.set_block_signals(false)
	frame_button.visible = encounter != "" or chart.center_body != ""
	frame_button.set_label("Solar System view" if chart.center_body != "" else "%s encounter view" % encounter)
	chart.utc = utc
	chart.queue_redraw()

func _switch_frame() -> void:
	if chart.center_body.is_empty():
		chart.center_body = encounter
		for i in events.size():
			if events[i][2] == encounter: encounter_stamp = stamps[i]
	else: chart.center_body = ""
	chart.reset_frame()
	_refresh()

func _toggle_play() -> void:
	if playing: _stop()
	else:
		if utc >= slider.max_value: seek(stamps[0])
		playing = true
		play.set_label("Pause")

func _stop() -> void:
	playing = false
	play.set_label("Play")

func advance(dt: float) -> void:
	if playing: seek(utc + dt * rate)
