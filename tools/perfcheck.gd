extends Node

# Rendered measurements and the opt-in M5 native frame gate. See docs/performance.md.
const Catch = preload("res://tools/coursecheck.gd").Catch
var stage: Node
var logger := Catch.new()
var failures := 0
var results := []
var compute := {}
var report := ""
var samples := 180
var require_gpu := false
var gpu_available := true
var studio_abba := false
var m5_native := false
var native_screen := -1
var native_window_pixels := Vector2i.ZERO
var native_frame_pixels := Vector2i.ZERO
const M5_PIXELS := Vector2i(3024, 1964)
const M5_QUALITY := "low"
const M5_LENS_SCALE := 0.35
const M5_LENS_PIXELS := Vector2i(1058, 687)
const FRAME_BUDGET_MS := 1000.0 / 30.0
signal model_sample(data: Dictionary)
signal studio_capture_done

# Match the viewport span and frame ID in one completed render-thread batch.
func capture_model(rid: RID) -> void:
	var dev := RDU.rd()
	if dev == null:
		call_deferred("acknowledge_model", {"frame": -1, "valid": false})
		return
	var begin := -1
	var end := -1
	for i in dev.get_captured_timestamps_count():
		var name := dev.get_captured_timestamp_name(i)
		if name == "vp_begin_%d" % rid.get_id(): begin = i
		elif name == "vp_end_%d" % rid.get_id(): end = i
	var data := {"frame": dev.get_captured_timestamps_frame(), "valid": begin >= 0 and end > begin}
	if data.valid:
		data["cpu_ms"] = float(dev.get_captured_timestamp_cpu_time(end) - dev.get_captured_timestamp_cpu_time(begin)) / 1000.0
		data["gpu_ms"] = float(dev.get_captured_timestamp_gpu_time(end) - dev.get_captured_timestamp_gpu_time(begin)) / 1000000.0
	call_deferred("acknowledge_model", data)

func acknowledge_model(data: Dictionary) -> void:
	model_sample.emit(data)

func stable_studio(baseline: Dictionary) -> bool:
	return stage.state.time == baseline.time and stage.model_view.camera.transform == baseline.camera \
		and not baseline.pose.keys().any(func(node: Node3D): return node.transform != baseline.pose[node])

func measure_studio_block(label: String, bias: float, baseline: Dictionary) -> void:
	meshes(stage.model_view.craft.group, bias)
	for i in 90:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
	var cpu := []
	var gpu := []
	var frames := []
	var rid: RID = stage.pipe.model_vp.get_viewport_rid()
	if not stable_studio(baseline): failures += 1
	for attempt in samples * 2:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
		RenderingServer.call_on_render_thread(capture_model.bind(rid))
		var data: Dictionary = await model_sample
		if not data.valid or (not frames.is_empty() and data.frame <= frames.back()): continue
		cpu.append(data.cpu_ms); gpu.append(data.gpu_ms); frames.append(data.frame)
		if frames.size() == samples: break
	if frames.size() != samples or not stable_studio(baseline) \
			or not cpu.all(func(value: float): return is_finite(value) and value >= 0.0):
		failures += 1
	var available := not gpu.is_empty() and gpu.all(func(value: float): return is_finite(value) and value > 0.0)
	if not available:
		gpu_available = false
		if gpu.any(func(value: float): return value != 0.0): failures += 1
		if require_gpu: failures += 1
		print("PERFCHECK GPU unavailable: ", label)
	var row := {"case": label, "lod_bias": bias, "distance": stage.model_view.cam.dist,
		"model_cpu_ms": summary(cpu), "model_gpu_ms": summary(gpu), "distinct_frames": frames.size(),
		"first_frame": frames.front() if not frames.is_empty() else -1, "last_frame": frames.back() if not frames.is_empty() else -1,
		"primitives": RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)}
	results.append(row)
	print("PERFCHECK METRIC ", JSON.stringify(row))

func capture_frame(label: String) -> void:
	stage.pipe.capture_next(func(img: Image):
		call_deferred("save_studio_capture", img, label))
	stage.animate(0.0)
	await studio_capture_done

func save_studio_capture(img: Image, label: String) -> void:
	if img == null or img.is_empty() or img.save_png(report.get_basename() + "-" + label + ".png") != OK: failures += 1
	studio_capture_done.emit()

func measure_studio_abba() -> void:
	stage.state.paused = true
	CraftAssets.craft_models_ready(["saturnv"])
	stage.show_model("saturnv")
	if not stage.model_view.craft.authored: failures += 1
	stage.model_view.cam.spin = 0.0
	stage.model_view.cam.held = true
	for i in 90:
		stage.animate(1.0 / 60.0)
		await RenderingServer.frame_post_draw
	for distance in [1.95, 30.0]:
		stage.model_view.cam.dist = distance
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
		var baseline := {"time": stage.state.time, "camera": stage.model_view.camera.transform, "pose": {}}
		baseline.pose[stage.model_view.craft.group] = stage.model_view.craft.group.transform
		for node: Node3D in stage.model_view.craft.group.find_children("*", "Node3D", true, false): baseline.pose[node] = node.transform
		for cycle in 2:
			for block in 4:
				var bias := 128.0 if block == 0 or block == 3 else 1.0
				var label := "studio-%s-cycle-%d-block-%d" % [distance, cycle, block]
				await measure_studio_block(label, bias, baseline)
				if cycle == 0 and block < 2 and not report.is_empty(): await capture_frame(label)

func summary(values: Array) -> Dictionary:
	if values.is_empty(): return {}
	values.sort()
	return {"samples": values.size(), "median": values[values.size() / 2],
		"p95": values[mini(values.size() - 1, int(values.size() * 0.95))], "max": values.back()}

func meshes(node: Node, bias: float) -> void:
	if node is MeshInstance3D: node.lod_bias = bias
	for child in node.get_children(): meshes(child, bias)

func capture_compute(label: String) -> void:
	var dev := RDU.rd()
	var pending := {}
	var totals := {}
	for i in dev.get_captured_timestamps_count():
		var name := dev.get_captured_timestamp_name(i)
		if name.begins_with("astrarium:start:"):
			pending[name.trim_prefix("astrarium:start:")] = [dev.get_captured_timestamp_cpu_time(i), dev.get_captured_timestamp_gpu_time(i)]
		elif name.begins_with("astrarium:end:"):
			var key := name.trim_prefix("astrarium:end:")
			if not pending.has(key): continue
			# Godot 4.7.2 driver GPU timestamps are nanoseconds; CPU timestamps are microseconds.
			var duration := [float(dev.get_captured_timestamp_cpu_time(i) - pending[key][0]) / 1000.0,
				float(dev.get_captured_timestamp_gpu_time(i) - pending[key][1]) / 1000000.0]
			var total: Array = totals.get(key, [0.0, 0.0])
			total[0] += duration[0]; total[1] += duration[1]
			totals[key] = total
	call_deferred("record_compute", label, totals)

func record_compute(label: String, totals: Dictionary) -> void:
	if not compute.has(label): compute[label] = {}
	for key in totals:
		if not compute[label].has(key): compute[label][key] = {"cpu_ms": [], "gpu_ms": []}
		compute[label][key].cpu_ms.append(totals[key][0])
		compute[label][key].gpu_ms.append(totals[key][1])

func native_display_extent() -> bool:
	var client := get_window().size
	return client == M5_PIXELS or get_window().get_size_with_decorations() == M5_PIXELS or client == DisplayServer.screen_get_usable_rect(native_screen).size

func measure(label: String, action := Callable()) -> void:
	for i in 90:
		stage.animate(get_process_delta_time() if m5_native else 1.0 / 60.0)
		await RenderingServer.frame_post_draw
	var animate_ms := []
	var action_ms := []
	var render_cpu_ms := []
	var render_gpu_ms := []
	var primitives := []
	var frame_ms := []
	var previous_draw := Time.get_ticks_usec()
	var previous_frame := Engine.get_frames_drawn()
	for i in samples:
		var start := Time.get_ticks_usec()
		if action.is_valid(): action.call(i)
		action_ms.append(float(Time.get_ticks_usec() - start) / 1000.0)
		start = Time.get_ticks_usec()
		stage.animate(get_process_delta_time() if m5_native else 1.0 / 60.0)
		animate_ms.append(float(Time.get_ticks_usec() - start) / 1000.0)
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		var drawn := Engine.get_frames_drawn()
		if drawn <= previous_frame: failures += 1
		frame_ms.append(float(now - previous_draw) / 1000.0)
		previous_draw = now
		previous_frame = drawn
		var cpu := RenderingServer.get_frame_setup_time_cpu()
		var gpu := 0.0
		var triangles := 0
		for vp in [get_viewport(), stage.pipe.hook_vp, stage.pipe.scene_vp, stage.pipe.temp_vp, stage.pipe.local_vp, stage.pipe.model_vp]:
			if vp is SubViewport and vp.render_target_update_mode == SubViewport.UPDATE_DISABLED: continue
			var rid: RID = vp.get_viewport_rid()
			cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
			triangles += RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
		render_cpu_ms.append(cpu); render_gpu_ms.append(gpu); primitives.append(triangles)
		RenderingServer.call_on_render_thread(capture_compute.bind(label))
	await get_tree().process_frame
	var row := {"case": label, "animate_ms": summary(animate_ms), "action_ms": summary(action_ms),
		"frame_ms": summary(frame_ms), "mean_fps": 1000.0 * samples / frame_ms.reduce(func(total: float, value: float): return total + value, 0.0),
		"viewport_cpu_ms": summary(render_cpu_ms), "viewport_gpu_ms": summary(render_gpu_ms), "primitives": summary(primitives)}
	if m5_native and (DisplayServer.window_get_current_screen() != native_screen \
			or get_window().mode != Window.MODE_FULLSCREEN or get_window().size != native_window_pixels \
			or get_window().get_size_with_decorations() != native_frame_pixels \
			or get_viewport().get_visible_rect().size != Vector2(native_window_pixels) / get_window().content_scale_factor \
			or DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED):
		failures += 1
		printerr("PERFCHECK native display configuration changed: ", label)
	if m5_native and (stage.render_quality != M5_QUALITY or stage.flight.local.render_quality != M5_QUALITY \
			or stage.lighting_quality != "low" or stage.pipe.render_scale != 2.0 \
			or stage.pipe.lens.get_scale() != M5_LENS_SCALE or stage.pipe.lens.march_size() != M5_LENS_PIXELS \
			or stage.pipe.local_vp.msaa_3d != Viewport.MSAA_DISABLED or stage.pipe.model_vp.msaa_3d != Viewport.MSAA_DISABLED \
			or [stage.pipe.scene_vp, stage.pipe.temp_vp, stage.pipe.local_vp, stage.pipe.model_vp].any(func(vp: SubViewport): return vp.size != M5_PIXELS)):
		failures += 1
		printerr("PERFCHECK named rendering configuration changed: ", label)
	if m5_native and (row.frame_ms.p95 > FRAME_BUDGET_MS or row.mean_fps < 30.0 or stage.pipe.render_size != M5_PIXELS):
		failures += 1
		printerr("PERFCHECK frame budget exceeded: ", label)
	if label.begins_with("lens-"):
		var hole: Body = stage.state.bodies.filter(func(b: Body): return b.type == "bh")[0]
		row["lens"] = {"camera_radius_scene": stage.cam.radius, "horizon_scene": hole.rs_scene, "following": stage.state.follow_id == hole.id}
		if label == "lens-focus" and (stage.state.follow_id != hole.id or stage.cam.radius > 8.0 * hole.rs_scene): failures += 1
	if label.begins_with("flight-"):
		row["flight"] = {"phase": stage.flight.vessel.phase, "met_s": stage.flight.vessel.met,
			"altitude_m": stage.flight.vessel.altitude()}
		if label == "flight-ascent" and stage.flight.vessel.phase != "ascent": failures += 1
	if row.viewport_gpu_ms.median <= 0.0:
		gpu_available = false
		if require_gpu: failures += 1
		print("PERFCHECK GPU unavailable: ", label)
	results.append(row)
	print("PERFCHECK METRIC ", JSON.stringify(row))

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("report="): report = arg.trim_prefix("report=")
		elif arg == "require_gpu=1": require_gpu = true
		elif arg == "uniform_cache=0": RDU.cache_uniforms = false
		elif arg.begins_with("samples="): samples = int(arg.trim_prefix("samples="))
		elif arg == "studio_abba=1": studio_abba = true
		elif arg == "m5_native=1": m5_native = true
		else: failures += 1
	if samples < 30 or (not report.is_empty() and not report.is_absolute_path()) or DisplayServer.get_name() == "headless":
		printerr("PERFCHECK requires graphical rendering, >=30 samples and an absolute report path")
		get_tree().quit(1)
		return
	if m5_native and (studio_abba or samples < 180 or not RenderingServer.get_video_adapter_name().contains("M5") or RenderingServer.get_current_rendering_driver_name() != "metal"):
		printerr("PERFCHECK M5 native gate requires Metal, Apple M5, >=180 samples and scenarios")
		get_tree().quit(1)
		return
	OS.add_logger(logger)
	get_tree().create_timer(240.0).timeout.connect(func():
		printerr("PERFCHECK timed out before completion")
		get_tree().quit(1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RDU.profiling = not studio_abba
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("sandbox")
	stage.lessons.store = ""
	stage.pipe.set_render_scale(1.0)
	stage.pipe.set_view_size(Vector2i(1280, 720))
	if m5_native:
		var screen := -1
		for candidate in DisplayServer.get_screen_count():
			if DisplayServer.screen_get_size(candidate) == M5_PIXELS: screen = candidate
		if screen < 0:
			printerr("PERFCHECK requires the built-in 3024x1964 display")
			get_tree().quit(1)
			return
		native_screen = screen
		get_window().current_screen = screen
		stage.configure_window_scale(DisplayServer.screen_get_scale(screen))
		stage.set_render_quality(M5_QUALITY)
		stage.set_lighting_quality("low")
		stage.pipe.lens.set_scale(M5_LENS_SCALE)
		for i in 10: await RenderingServer.frame_post_draw
		get_window().borderless = true
		get_window().size = M5_PIXELS
		get_window().mode = Window.MODE_FULLSCREEN
		# macOS applies display moves and fullscreen asynchronously.
		var display_deadline := Time.get_ticks_msec() + 5000
		var settled_frames := 0
		while Time.get_ticks_msec() < display_deadline:
			await RenderingServer.frame_post_draw
			var ready := DisplayServer.window_get_current_screen() == screen and get_window().mode == Window.MODE_FULLSCREEN and native_display_extent()
			settled_frames = settled_frames + 1 if ready else 0
			if settled_frames >= 10: break
		native_window_pixels = get_window().size
		native_frame_pixels = get_window().get_size_with_decorations()
		if settled_frames < 10:
			printerr("PERFCHECK unexpected built-in fullscreen extent: ", native_window_pixels)
			get_tree().quit(1)
			return
		stage.resize()
		stage.pipe.set_view_size(M5_PIXELS / int(DisplayServer.screen_get_scale(screen)))
		stage.pipe.set_render_scale(DisplayServer.screen_get_scale(screen))
		if stage.pipe.render_size != M5_PIXELS:
			printerr("PERFCHECK native backing targets differ: ", stage.pipe.render_size)
			get_tree().quit(1)
			return
	for vp in [get_viewport(), stage.pipe.hook_vp, stage.pipe.scene_vp, stage.pipe.temp_vp, stage.pipe.local_vp, stage.pipe.model_vp]:
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	if studio_abba:
		await measure_studio_abba()
		await get_tree().process_frame
		finish_report()
		return
	stage.load_preset("solar")
	stage.state.paused = true
	await measure("solar")
	var body: Body = stage.state.bodies[0]
	stage.state.focus_id = body.id
	stage.open_cross_section()
	await measure("editor-idle")
	await measure("editor-spin", func(i: int): stage._on_live_edit(body, {"spinFrac": 0.1 + float(i % 2) * 0.01}))
	stage.set_panel_open("xsecPanel", false)
	stage.load_preset("sandbox")
	if not stage.state.bodies.any(func(b: Body): return b.type == "bh"): failures += 1
	await measure("lens-wide")
	var hole: Body = stage.state.bodies.filter(func(b: Body): return b.type == "bh")[0]
	stage.set_follow(hole)
	await measure("lens-focus")
	if m5_native and not report.is_empty(): await capture_frame("native-lens-focus")
	CraftAssets.craft_models_ready(["saturnv"])
	stage.show_model("saturnv")
	if not stage.model_view.craft.authored: failures += 1
	stage.model_view.cam.spin = 0.0
	stage.model_view.cam.held = true
	for distance in [1.95, 30.0]:
		stage.model_view.cam.dist = distance
		for bias in [128.0, 1.0]:
			meshes(stage.model_view.craft.group, bias)
			await measure("studio-%s-lod-%s" % [distance, bias])
	stage.close_model_viewer()
	stage.load_preset("solar")
	await stage.launch_craft("falcon9")
	if stage.flight.vessel == null or not stage.flight.craft.authored:
		failures += 1
	else:
		stage.state.paused = true
		await measure("flight-pad")
		stage.state.paused = false
		stage.flight.start_count()
		for i in 900: stage.animate(1.0 / 60.0)
		if stage.flight.vessel.phase != "ascent": failures += 1
		await measure("flight-ascent")
	await get_tree().process_frame
	finish_report()

func finish_report() -> void:
	var profiles := {}
	for label in compute:
		profiles[label] = {}
		for key in compute[label]:
			profiles[label][key] = {"cpu_ms": summary(compute[label][key].cpu_ms), "gpu_ms": summary(compute[label][key].gpu_ms)}
	var errors := logger.take()
	if not errors.is_empty():
		failures += errors.size()
		for error in errors: printerr("PERFCHECK ENGINE ", error)
	var data := {"godot": Engine.get_version_info(), "device": RenderingServer.get_video_adapter_name(),
		"profile": "studio_abba" if studio_abba else "scenarios",
		"driver": RenderingServer.get_current_rendering_driver_name(), "method": RenderingServer.get_current_rendering_method(),
		"resolution": [stage.pipe.render_size.x, stage.pipe.render_size.y], "render_scale": stage.pipe.render_scale,
		"logical_resolution": [stage.pipe.view_size.x, stage.pipe.view_size.y],
		"window_pixels": [get_window().size.x, get_window().size.y],
		"window_frame_pixels": [get_window().get_size_with_decorations().x, get_window().get_size_with_decorations().y],
		"root_logical_resolution": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"lens_scale": stage.pipe.lens.get_scale(), "lens_field_pixels": [stage.pipe.lens.march_size().x, stage.pipe.lens.march_size().y], "msaa": stage.pipe.local_vp.msaa_3d,
		"render_quality": stage.render_quality, "lighting_quality": stage.lighting_quality,
		"frame_budget_ms": FRAME_BUDGET_MS if m5_native else null, "target_fps": 30 if m5_native else null,
		"simulation_dt": "elapsed process delta" if m5_native else "fixed 1/60 s", "gpu_available": gpu_available, "uniform_cache": RDU.cache_uniforms, "authored_craft": stage.model_view.craft != null and stage.model_view.craft.authored, "results": results, "compute": profiles, "failures": failures}
	if not report.is_empty():
		var file := FileAccess.open(report, FileAccess.WRITE)
		if file == null: failures += 1
		else:
			file.store_string(JSON.stringify(data, "\t"))
			if file.get_error() != OK: failures += 1
			file.close()
	RDU.profiling = false
	OS.remove_logger(logger)
	print("PERFCHECK DONE cases=%d failures=%d" % [results.size(), failures])
	get_tree().quit(1 if failures else 0)
