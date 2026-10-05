extends Node

# Rendered sky checks: the point-source neighbour cull must match an exhaustive
# 3x3 walk exactly, and the diffuse cache must stay within the stated error of live
# evaluation. Options:
#   timing=1            native-size frame medians for exhaustive, culled and cached skies
#   reference=/abs.inc  another revision of sky.gdshaderinc, e.g.
#                       `git show HEAD:shaders/sky/sky.gdshaderinc > /tmp/sky.inc`;
#                       the live sky must match it within REFERENCE_MAX_LEVELS
#   dump=/abs/dir       save each case's live and cached images, and the cache atlas
const Catch = preload("res://tools/coursecheck.gd").Catch
var logger := Catch.new()
var stage: Node
var failures := 0
var checks := 0
var timing := false
var reference: Shader
var dump := ""
signal captured(img: Image)

## Final 8-bit image: at most this fraction of pixels may differ by more than 2/255.
const CACHE_OUTLIER_FRACTION := 1e-4
## No cached pixel may differ by more than this many 8-bit levels.
const CACHE_MAX_LEVELS := 8
## Reassociation in the shader compiler may move a pixel by one level.
const REFERENCE_MAX_LEVELS := 1

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func capture() -> Image:
	stage.pipe.capture_next(func(img: Image): captured.emit.call_deferred(img))
	stage.animate(0.0)
	return await captured

func settle(cache: bool, exhaustive: bool) -> void:
	stage.pipe.sky_cache.enabled = cache
	stage.pipe.sky_set("uSkyExhaustive", exhaustive)
	for i in 4:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
	var want := SkyCache.READY if cache else SkyCache.STALE
	if stage.pipe.sky_cache.state != want:
		check("sky cache reached state %d" % want, false)

func compare(a: Image, b: Image) -> Dictionary:
	var pa := a.get_data()
	var pb := b.get_data()
	var worst := 0
	var outliers := 0
	var differing := 0
	for i in range(0, pa.size(), 4):
		var d := maxi(maxi(absi(pa[i] - pb[i]), absi(pa[i + 1] - pb[i + 1])), absi(pa[i + 2] - pb[i + 2]))
		if d > 0: differing += 1
		if d > 2: outliers += 1
		worst = maxi(worst, d)
	var n := pa.size() / 4
	return {"max": worst, "differing": differing, "outlier_fraction": float(outliers) / n, "pixels": n}

func frame_median(n: int) -> float:
	for i in 30:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
	var times := []
	var prev := Time.get_ticks_usec()
	for i in n:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		times.append((now - prev) / 1000.0)
		prev = now
	times.sort()
	return times[times.size() / 2]

func run_case(label: String, setup: Callable) -> void:
	var view: Vector2i = stage.pipe.view_size
	var scale: float = stage.pipe.render_scale
	await setup.call()
	await settle(false, true)
	var exhaustive := await capture()
	var repeat := await capture()
	await settle(false, false)
	var culled := await capture()
	stage.pipe.sky_cache.enabled = true
	for i in 8:
		if stage.pipe.sky_cache.state == SkyCache.RENDERING: break
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
	# This frame publishes the cache rendered by the previous one and samples it.
	var first := await capture()
	check("%s cache ready on its first sampled frame" % label, stage.pipe.sky_cache.state == SkyCache.READY)
	await settle(true, false)
	var cached := await capture()
	var first_cmp := compare(first, cached)
	check("%s first cached frame complete %s" % [label, first_cmp], first_cmp.max == 0)
	var noise := compare(exhaustive, repeat)
	var cull := compare(exhaustive, culled)
	var cache := compare(culled, cached)
	check("%s deterministic capture %s" % [label, noise], noise.max == 0)
	check("%s neighbour cull is exact %s" % [label, cull], cull.max == 0)
	check("%s diffuse cache within tolerance %s" % [label, cache],
		cache.outlier_fraction <= CACHE_OUTLIER_FRACTION and cache.max <= CACHE_MAX_LEVELS)
	if reference != null:
		await settle(false, false)
		var production: Shader = stage.pipe.sky_mat.shader
		stage.pipe.sky_mat.shader = reference
		for i in 3:
			stage.animate(0.0)
			await RenderingServer.frame_post_draw
		var ref_cmp := compare(culled, await capture())
		stage.pipe.sky_mat.shader = production
		check("%s live sky matches reference %s" % [label, ref_cmp], ref_cmp.max <= REFERENCE_MAX_LEVELS)
	if not dump.is_empty():
		var stem := dump.path_join(label.replace(" ", "-"))
		check("%s images saved" % label, culled.save_png(stem + "-live.png") == OK and cached.save_png(stem + "-cached.png") == OK)
	if timing:
		stage.pipe.set_view_size(Vector2i(1512, 982))
		stage.pipe.set_render_scale(2.0)
		await settle(false, true)
		var t_exhaustive := await frame_median(90)
		await settle(false, false)
		var t_culled := await frame_median(90)
		await settle(true, false)
		var t_cached := await frame_median(90)
		print("SKYCACHECHECK TIMING %s render=%s exhaustive=%.3f culled=%.3f cached=%.3f ms" % [label, stage.pipe.render_size, t_exhaustive, t_culled, t_cached])
		stage.pipe.set_view_size(view)
		stage.pipe.set_render_scale(scale)

func preset(key: String, band := Spectrum.VISIBLE_BAND, follow_hole := false, beta := Vector3.ZERO) -> Callable:
	return func():
		stage.load_preset(key)
		stage.state.paused = true
		stage.set_band(band)
		if follow_hole:
			var holes: Array = stage.state.bodies.filter(func(b: Body): return b.type == "bh")
			check("%s has a black hole" % key, not holes.is_empty())
			if not holes.is_empty(): stage.set_follow(holes[0])
			for i in 240:
				stage.animate(1.0 / 60.0)
		stage.apply_sky_boost_all(beta)

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("SKYCACHECHECK requires graphical rendering")
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg == "timing=1": timing = true
		elif arg.begins_with("dump=") and arg.trim_prefix("dump=").is_absolute_path():
			dump = arg.trim_prefix("dump=")
		elif arg.begins_with("reference=") and FileAccess.file_exists(arg.trim_prefix("reference=")):
			reference = Shader.new()
			reference.code = FileAccess.get_file_as_string("res://shaders/sky/background.gdshader").replace(
				'#include "res://shaders/sky/sky.gdshaderinc"', FileAccess.get_file_as_string(arg.trim_prefix("reference=")))
		else:
			printerr("SKYCACHECHECK unknown option or missing file ", arg)
			get_tree().quit(1)
			return
	if not dump.is_empty() and DirAccess.make_dir_recursive_absolute(dump) != OK:
		printerr("SKYCACHECHECK cannot create ", dump)
		get_tree().quit(1)
		return
	OS.add_logger(logger)
	get_tree().create_timer(300.0).timeout.connect(func():
		printerr("SKYCACHECHECK timed out")
		get_tree().quit(1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("sandbox")
	stage.lessons.store = ""
	await run_case("solar visible", preset("solar"))
	await run_case("solar x-ray", preset("solar", 5))
	await run_case("solar radio", preset("solar", 0))
	await run_case("solar boosted", preset("solar", Spectrum.VISIBLE_BAND, false, Vector3(0.0, 0.0, -0.6)))
	await run_case("sandbox lensed", preset("sandbox", Spectrum.VISIBLE_BAND, true))
	await run_case("bhmerger lensed", preset("bhmerger", Spectrum.VISIBLE_BAND, true))
	await run_case("bhmerger lensed x-ray", preset("bhmerger", 5, true))
	if not dump.is_empty():
		var atlas: Image = stage.pipe.sky_cache.viewport.get_texture().get_image()
		atlas.convert(Image.FORMAT_RGBA8)
		check("cache atlas saved", atlas.save_png(dump.path_join("cache-atlas.png")) == OK)
	for error in logger.take():
		failures += 1
		printerr("SKYCACHECHECK ENGINE ", error)
	OS.remove_logger(logger)
	print("SKYCACHECHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
