extends Node

const Catch = preload("res://tools/coursecheck.gd").Catch
var stage: Node
var failures := 0
var missions := 0
var movie := ""
var profile := false
var fallback := false
var frame := 0

func expect(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("DOCKINGMISSIONS FAIL ", label)

func _ready() -> void:
	var only := ""
	profile = OS.get_cmdline_user_args().has("profile=1")
	fallback = OS.get_cmdline_user_args().has("assets=0")
	if fallback:
		for key in ["evapod","ranger","lander","endurance","discovery"]: CraftAssets.CACHE[key] = null
	if profile and DisplayServer.get_name() == "headless":
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("movie="): movie = arg.substr(6)
		if arg.begins_with("only="): only = arg.substr(5)
	if movie != "":
		if DisplayServer.get_name() == "headless" or DirAccess.make_dir_recursive_absolute(movie) != OK:
			get_tree().quit(1)
			return
	var logger := Catch.new()
	OS.add_logger(logger)
	PlanetMaps.synchronous = true
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	stage.set_process(false)
	for i in 4: await get_tree().process_frame
	stage._start("flight")
	stage.configure_window_scale(1.0)
	get_window().size = Vector2i(1280,720) if movie != "" or profile else Vector2i(900,600)
	stage.set_render_quality("medium")
	stage.pipe.postfx.grain = 0.0
	for key in ["evapod","ranger","lander"]:
		if only == "" or only == key: await fly(key)
	for error in logger.take():
		failures += 1
		printerr("DOCKINGMISSIONS ENGINE ", error)
	OS.remove_logger(logger)
	print("DOCKINGMISSIONS DONE missions=%d failures=%d" % [missions,failures])
	get_tree().quit(1 if failures else 0)

func fly(key: String) -> void:
	missions += 1
	stage.open_hangar()
	await stage._select_hangar(key)
	var hangar: Hangar = stage.hangar
	for i in 3: await get_tree().process_frame
	var viewport := hangar.list_scroll.get_global_rect()
	var chosen: Rect2 = hangar.items[key].get_global_rect()
	expect(chosen.position.y >= viewport.position.y-1 and chosen.end.y <= viewport.end.y+1,
		key + " is reachable above Back in the hangar list")
	var entry: Dictionary = hangar.info[key].missions[hangar.mission]
	expect(entry.goal == "dock" and entry.ok, key + " offers its approach in the hangar")
	if movie != "":
		for i in 72:
			stage.animate(1.0/24)
			await RenderingServer.frame_post_draw
			if not save_frame(): return
	await stage.hangar_start(key,entry.dest,entry.goal)
	var f: Spaceflight = stage.flight
	var dock := f.docking
	expect(dock != null and dock.holding and f.camera_mode() == "berth", key + " hands control over outside capture")
	if dock == null: return
	if fallback: expect(not f.craft.authored and not dock.craft.authored,key + " flies the fallback meshes")
	var clock := f.vessel.coord
	var prop := float(f.vessel._first_attached().rcs_prop)
	stage.state.paused = true
	stage.animate(.05)
	expect(clock == f.vessel.coord and prop == f.vessel._first_attached().rcs_prop, key + " pause freezes both clock and jets")
	stage.state.paused = false
	f.set_warp(5)
	expect(f.warp() == 1 and not f.key_action("stage") and not f.key_action("throttle_full"), key + " docking interlocks")
	var initial := float(dock.readout.gap)
	var dt := 1.0 / 24.0 if movie != "" else (1.0 / 60.0 if profile else .05)
	stage.animate(0.0)
	var sweep = preload("res://tools/dockingclearance.gd").new(f.craft.group,dock.craft.group) if movie == "" and not profile else null
	var stations := [10.0,8.0,6.0,5.0,4.0,3.0,2.5]
	for decimetre in range(20,0,-1): stations.append(decimetre*.1)
	stations.append(.05)
	if sweep != null: expect(not sweep.visitor.is_empty() and not sweep.carrier.is_empty(),key + " visible geometry for clearance")
	var frame_ms := PackedFloat64Array()
	var last_frame := 0
	var held := false
	var resumed := false
	var hold_time := 0.0
	var capture_time := -1.0
	var tested_retreat := false
	var retreat_started := false
	var braking_range := 0.0
	var t := 0.0
	var last_used := 0.0
	var max_hold_error := 0.0
	var console: FlightConsole = f.console
	var persistent_state: bool = key != "lander" or Vehicles.get_vehicle("endurance").stages[0].centrifuge.rpm == 5.0
	expect(persistent_state, "recovery spin belongs to the mission instance")
	while t < 200.0:
		if not dock.cleared_once and t >= 6.0:
			expect(absf(dock.readout.gap-initial)<.1 and not dock.latched, key + " waits for clearance")
			var command: Rect2 = console.buttons.dock_command.get_global_rect()
			expect(get_viewport().get_visible_rect().encloses(command),key+" approach action fits the window")
			console.buttons.dock_command.pressed.emit()
			expect(not dock.holding, key + " console clears approach")
		if not tested_retreat and movie == "" and not profile and dock.cleared_once:
			if not retreat_started and dock.readout.gap < initial-1.0:
				console.buttons.dock_retreat.pressed.emit()
				retreat_started = true
				expect(dock.retreating,key+" accepts a wave-off")
			elif retreat_started and dock.holding:
				expect(absf(dock.readout.gap-initial)<.04,key+" reacquires the initial stand-off")
				console.buttons.dock_command.pressed.emit()
				tested_retreat = true
		if not held and dock.readout.gap < 5.0 and dock.cleared_once:
			var event := InputEventKey.new()
			event.physical_keycode = stage.controls.bindings.dock_command[0]
			event.pressed = true
			event.shift_pressed = stage.controls.bindings.dock_command[1]
			event.ctrl_pressed = stage.controls.bindings.dock_command[2]
			event.alt_pressed = stage.controls.bindings.dock_command[3]
			stage._key(event)
			braking_range = dock.readout.gap
			held = true
			hold_time = t
			expect(dock.holding, key + " mapped key interrupts closure")
		if held and not resumed:
			max_hold_error = maxf(max_hold_error,absf(dock.readout.gap-dock.hold_gap))
			if t-hold_time >= 8.0:
				expect(not dock.braking and absf(dock.readout.gap-dock.hold_gap)<.10 and not dock.latched, key + " jets settle at commanded hold range")
				console.buttons.dock_command.pressed.emit()
				resumed = true
		stage.animate(dt)
		t += dt
		if dock.failure != "": break
		if sweep != null and not stations.is_empty() and dock.readout.gap <= stations[0]:
			var crossing: String = sweep.interference()
			expect(crossing == "", "%s at %.2f m: %s" % [key,dock.readout.gap,crossing])
			stations.pop_front()
		if dock.latched and capture_time < 0.0: capture_time = t
		if dock.readout.rcsUsed < last_used or not is_finite(dock.readout.gap):
			expect(false, key + " finite approach and monotonic propellant")
			break
		last_used = dock.readout.rcsUsed
		if movie != "":
			await RenderingServer.frame_post_draw
			if not save_frame(): break
		elif profile:
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec()
			if t > 6.0: frame_ms.append((now-last_frame)*.001)
			last_frame = now
		elif int(t / dt) % 100 == 0:
			await get_tree().process_frame
		if capture_time >= 0.0 and t > capture_time+3.0: break
	expect(dock.latched and resumed and dock.failure == "", "%s completes — %s" % [key,dock.failure])
	if sweep != null: expect(tested_retreat,key+" completes wave-off and re-clearance")
	if dock.latched:
		if movie != "": print("MOVIE hold=%.2f resume=%.2f capture=%.2f" % [hold_time+3,hold_time+11,capture_time+3])
		if sweep != null:
			expect(stations.is_empty(), key + " traverses the sampled clearance stations")
			var crossing: String = sweep.interference()
			expect(crossing == "", key + " latched geometry: " + crossing)
		var live := dock.measure(f.vessel,dock.port_pose())
		expect(live.cross < 1e-5 and absf(live.gap)<1e-5 and live.rate<1e-6 and live.speed<1e-5, key + " stays rigid after capture")
		expect(not console.buttons.dock_command.visible, key + " ends approach controls at capture")
		print("DOCKINGMISSIONS %s t=%.2f s capture=%.4f m/s lateral=%.4f m attitude=%.3f deg RCS=%.3f kg braking distance=%.3f m hold error=%.3f m" % [
			key,capture_time,dock.capture.speed,dock.capture.cross,rad_to_deg(dock.capture.angle),dock.capture.rcsUsed,braking_range-dock.hold_gap,max_hold_error])
	if sweep != null and dock.latched: check_refusals(f)
	if not frame_ms.is_empty():
		frame_ms.sort()
		print("DOCKINGMISSIONS FRAME %s n=%d p50=%.2f ms p95=%.2f ms" % [key,frame_ms.size(),
			frame_ms[frame_ms.size()/2],frame_ms[int(frame_ms.size()*.95)]])
	stage.end_flight()


func check_refusals(f: Spaceflight) -> void:
	var dock := f.docking
	dock.latched = false
	var pose := dock.port_pose()
	f.vessel.v.add_scaled_in(pose.axis,-.5)
	dock.after_step(f.vessel)
	expect(not dock.latched,"capture refuses excessive relative speed")
	f.vessel.v.copy_from(pose.v)
	f.vessel.q.premultiply(DQuat.new().set_from_axis_angle(pose.axis,.2))
	dock.after_step(f.vessel)
	expect(not dock.latched,"capture refuses angular misalignment")
	f.vessel._first_attached().rcs_prop = 0.0
	stage.step_flight(.05)
	expect(dock.failure != "" and not dock.latched and stage.state.paused,"fuel exhaustion stops the approach")
	stage.state.paused = false

func save_frame() -> bool:
	var img := get_viewport().get_texture().get_image()
	if img.save_jpg(movie.path_join("%05d.jpg" % frame),.92) != OK:
		expect(false,"recording frame")
		return false
	frame += 1
	return true
