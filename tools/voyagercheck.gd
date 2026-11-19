extends Node

const Catch = preload("res://tools/coursecheck.gd").Catch
var stage: Node
var errors := 0
var output := ""

func expect(ok: bool, message: String) -> void:
	if not ok:
		printerr("VOYAGER FAIL ", message)
		errors += 1

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("shots="): output = arg.trim_prefix("shots=")
	if output != "" and (DisplayServer.get_name() == "headless" or DirAccess.make_dir_recursive_absolute(output) != OK):
		get_tree().quit(1)
		return
	var logger := Catch.new()
	OS.add_logger(logger)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	stage.set_process(false)
	stage._start("flight")
	stage.configure_window_scale(1.0)
	get_window().size = Vector2i(1280, 760)
	var archive: VoyagerArchive = load("res://assets/voyager/trajectory.tres")
	for name_ in archive.tracks:
		var rows: PackedFloat64Array = archive.tracks[name_]
		expect(rows.size() % 7 == 0 and rows.size() >= 14, name_ + " complete state rows")
		for j in range(0, rows.size(), 7):
			if j > 0 and rows[j] <= rows[j-7]:
				expect(false, name_ + " chronological records")
				break
	# Independent Horizons queries between stored samples, heliocentric ecliptic AU.
	for fixture in [["Voyager 1", 833587200, DVec3.new(-18.72785456968551, -48.87463041996793, 35.44596631451457)],
			["Voyager 2", 447984000, DVec3.new(-6.42795299513381, -12.0967313271127, 0.1702161991328135)]]:
		expect(archive.position_at(fixture[0], fixture[1]).sub(fixture[2]).length() < 1e-6, "off-grid position of " + fixture[0])
	# Project closest-approach tables use planetary centres. The PDS Triton
	# pass and Saturn's moon distinguish the encounter kernels from cruise conics.
	for event in [["Voyager 2", "Neptune", "1989-08-25T03:56:36", 29240, 150],
			["Voyager 2", "Triton", "1989-08-25T09:10", 39790, 150],
			["Voyager 1", "Titan", "1980-11-12T05:41", 6490, 150],
			["Voyager 2", "Uranus", "1986-01-24T17:59:47", 107000, 300]]:
		var when := VoyagerMissions.epoch(event[2])
		var relative := archive.position_at(event[0], when).sub(archive.position_at(event[1], when))
		expect(absf(relative.length() * VoyagerChart.AU_KM - event[3]) < event[4], "navigation range at " + event[1])
	var t := VoyagerMissions.epoch(VoyagerMissions.LIGHT_DAY)
	var v1 := archive.position_at("Voyager 1", t)
	var range_au := v1.sub(archive.position_at("Earth", t)).length()
	expect(absf(range_au * Rocketry.AU_M / Rocketry.C_MS - 86400.0) < 1, "Earth range at NASA light-day event")
	expect(absf(v1.length() - 172.3893) < 0.001, "separate Sun range at the milestone")
	for key in VoyagerMissions.PROBES:
		enter(key)
		var replay: VoyagerReplay = stage.voyager_replay
		if replay == null: break
		var name_: String = VoyagerMissions.PROBES[key]
		expect(replay.utc == t and replay.probe == name_, "hangar opens the selected mission at the commemorative date")
		if key == "voyager1":
			check_geometry(stage.model_view.craft.group)
			if output != "": await get_tree().create_timer(0.5).timeout
			await shot("light-day")
			replay.views[1].pressed.emit()
			replay.poses.select(1)
			replay.poses.item_selected.emit(1)
			await shot("spacecraft-reference")
			replay.poses.select(0)
			replay.poses.item_selected.emit(0)
			await shot("deployed")
			stage.model_view.cam.yaw += PI
			stage.model_view.cam.pitch = 0.7
			await shot("reverse")
			replay.poses.select(5)
			replay.poses.item_selected.emit(5)
			expect(replay.ref_select.value == "3" and replay.picture.texture != null, "engraved cover comparison")
			expect(stage.model_view.cam.dist * stage.model_view.span < 2, "record is framed in metres")
			await shot("golden-record")
			replay.views[0].pressed.emit()
		for i in replay.stamps.size():
			replay.landmark.chosen.emit(str(i))
			expect(replay.utc == replay.stamps[i] and replay.landmark.value == str(i), "jump " + str(replay.events[i][1]))
			expect(i == 0 or replay.stamps[i] > replay.stamps[i-1], "chronological landmark")
			expect(replay.chart.center_body == replay.events[i][2], "encounter frame")
			if replay.chart.center_body != "":
				var from := archive.position_at(name_, replay.utc)
				var target := archive.position_at(replay.chart.center_body, replay.utc)
				expect(from.sub(target).length() < 0.006, "close approach to " + replay.chart.center_body)
				if replay.chart.center_body == "Neptune":
					await shot("neptune")
					replay.local_slider.value = replay.stamps[i] + 3600
					expect(absf(replay.utc - replay.stamps[i] - 3600) < 60 and replay.chart.center_body == "Neptune", "fine encounter scrub")
					replay.frame_button.pressed.emit()
					expect(replay.chart.center_body == "", "return to Sun-centred frame")
		replay.clock_field.text_submitted.emit("1984-02-29 11:22:33")
		expect(replay.utc == VoyagerMissions.epoch("1984-02-29T11:22:33"), "typed UTC timestamp")
		replay.clock_field.text_submitted.emit("1985-02-29")
		expect(replay.utc == VoyagerMissions.epoch("1984-02-29T11:22:33"), "invalid date preserves the clock")
		replay.clock_field.text_submitted.emit("1977")
		expect(archive.position_at(name_, replay.utc) == null and "Launch at Earth" in replay.info.text, "launch gap is identified")
		var world_time: float = stage.state.sim_years
		replay.play.pressed.emit()
		stage.animate(0.05)
		expect(replay.utc > replay.stamps[0] and stage.state.sim_years == world_time, "replay has its own clock")
		replay.slider.value = replay.slider.max_value
		expect(not replay.playing and replay.utc == replay.slider.max_value, "scrub reaches endpoint and pauses")
		replay.selector.chosen.emit("Voyager 2" if key == "voyager1" else "Voyager 1")
		expect(replay.probe != name_ and replay.utc == replay.slider.max_value, "switch probes at same epoch")
		replay.closed.emit()
		await get_tree().process_frame
		expect(stage.voyager_replay == null and stage.hangar.visible, "returns to the hangar")
		stage.close_hangar()
		expect(stage.model_view.craft == null, "probe released when leaving the hangar")
		stage.open_hangar()
	await stage._select_hangar("saturnv")
	expect(stage.model_view.vehicle.key == "saturnv" and stage.model_view.grid.visible, "regular turntable restored")
	stage.quit_to_start()
	for msg in logger.take():
		errors += 1
		printerr("VOYAGER ENGINE ", msg)
	OS.remove_logger(logger)
	print("VOYAGER DONE failures=", errors)
	get_tree().quit(1 if errors else 0)

func check_geometry(group: Node3D) -> void:
	var dish := group.find_child("tex_02_AO", true, false) as MeshInstance3D
	var bus := group.find_child("tex_01", true, false) as MeshInstance3D
	expect(dish != null and bus != null, "VTAD dish and bus imported")
	if dish == null or bus == null: return
	expect(absf(CraftModel.measure(dish).size.x - 3.7) < 0.002, "3.7 metre reflector")
	var whips := -1
	var cover := -1
	for i in bus.mesh.get_surface_count():
		match bus.get_active_material(i).resource_name:
			"brass": whips = i
			"Engraved cover": cover = i
	expect(cover >= 0 and whips >= 0, "cover and whip surfaces")
	if whips < 0: return
	var vertices: PackedVector3Array = bus.mesh.surface_get_arrays(whips)[Mesh.ARRAY_VERTEX]
	var axes: Array[Vector3] = []
	for side in [-1.0, 1.0]:
		var root := Vector3.ZERO
		var tip := Vector3.ZERO
		var roots := 0
		var tips := 0
		for point in vertices:
			if point.x * side <= 0: continue
			if absf(point.x) > 1:
				tip += point
				tips += 1
			else:
				root += point
				roots += 1
		expect(roots > 0 and tips > 0, "two ends on each antenna")
		if roots == 0 or tips == 0: return
		var axis := bus.global_basis * (tip / tips - root / roots)
		expect(absf(axis.length() - 10) < 0.02, "ten metre antenna")
		axes.append(axis.normalized())
	expect(absf(axes[0].dot(axes[1])) < 0.005, "orthogonal plasma-wave antennas")

func enter(key: String) -> void:
	var hangar: Hangar = stage.hangar
	expect(hangar.items.has(key), "listed " + key)
	hangar.items[key].pressed.emit()
	var mission: Dictionary = hangar.info[key].missions[hangar.mission]
	expect(mission.goal == "voyager" and mission.ok, "historical mission offered")
	hangar.start.emit(key, mission.dest, mission.goal)

func shot(stem: String) -> void:
	if output == "": return
	for i in 6:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	expect(img != null and img.save_png(output.path_join(stem + ".png")) == OK, "capture " + stem)
