extends Node

# Frame cost of each sky component: the live sky with one component removed at a
# time, the cached path, and a constant sky. Differences from "live" attribute
# cost; docs/performance.md#sky-shader-cost. Edits are applied to the shader
# source, so a renamed component fails instead of silently measuring nothing.
# Options: preset=solar band=3 samples=120 view=1512x982 scale=2.0
var stage: Node
var failures := 0
var samples := 120
var preset := "solar"
var band := Spectrum.VISIBLE_BAND
var view := Vector2i(1512, 982)
var render_scale := 2.0

const INCLUDE := "res://shaders/sky/sky.gdshaderinc"
const VARIANTS := [
	["no point sources", [["#define SKY_TIERS 6", "#define SKY_TIERS 0"]]],
	["star tiers 0-2 only", [["#define SKY_TIERS 6", "#define SKY_TIERS 3"]]],
	["no dust", [["return sky_dustTau(dir);", "return 0.0;"]]],
	["no clusters", [["vec2 clus = sky_clusterField(dir, face, g);", "vec2 clus = vec2(0.0);"]]],
	["no galaxies", [["float gal = sky_galaxies(dir, face, g, w2) * uGalaxies;", "float gal = 0.0;"]]],
	["no nebulae", [["if (uwHii > wEps) {", "if (false) {"], ["if (uwRefl > wEps) {", "if (false) {"]]],
]

func median_frame_ms() -> float:
	for i in 40:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
	var times := []
	var previous := Time.get_ticks_usec()
	for i in samples:
		stage.animate(0.0)
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		times.append((now - previous) / 1000.0)
		previous = now
	times.sort()
	return times[times.size() / 2]

## The colour-pass sky shader with `edits` applied to its include, inlined.
func variant(edits: Array) -> Shader:
	var include := FileAccess.get_file_as_string(INCLUDE)
	for edit in edits:
		if include.count(edit[0]) != 1:
			failures += 1
			printerr("SKYCOST edit target not found exactly once: ", edit[0])
		include = include.replace(edit[0], edit[1])
	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string("res://shaders/sky/background.gdshader") \
		.replace('#include "%s"' % INCLUDE, include)
	return shader

func measure(label: String, shader: Shader, cached: bool) -> float:
	stage.pipe.sky_mat.shader = shader
	stage.pipe.sky_cache.enabled = cached
	var ms: float = await median_frame_ms()
	if cached and stage.pipe.sky_cache.state != SkyCache.READY: failures += 1
	print("SKYCOST %-22s %8.3f ms" % [label, ms])
	return ms

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("SKYCOST requires graphical rendering")
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		match kv[0] if kv.size() == 2 else "":
			"preset": preset = kv[1]
			"band": band = int(kv[1])
			"samples": samples = int(kv[1])
			"scale": render_scale = float(kv[1])
			"view":
				var wh := kv[1].split("x")
				view = Vector2i(int(wh[0]), int(wh[1])) if wh.size() == 2 else Vector2i.ZERO
			_:
				printerr("SKYCOST unknown option ", arg)
				get_tree().quit(1)
				return
	if samples < 30 or view.x <= 0 or view.y <= 0 or render_scale <= 0.0:
		printerr("SKYCOST needs samples>=30 and a positive view and scale")
		get_tree().quit(1)
		return
	get_tree().create_timer(600.0).timeout.connect(func():
		printerr("SKYCOST timed out")
		get_tree().quit(1))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	stage.set_process(false)
	stage._start("sandbox")
	stage.lessons.store = ""
	stage.set_render_quality("low")
	stage.pipe.set_view_size(view)
	stage.pipe.set_render_scale(render_scale)
	if not stage.load_preset(preset):
		printerr("SKYCOST unknown preset ", preset)
		get_tree().quit(1)
		return
	stage.state.paused = true
	stage.set_band(band)
	print("SKYCOST preset=%s band=%d render=%s device=%s" % [preset, band, stage.pipe.render_size, RenderingServer.get_video_adapter_name()])
	var production: Shader = stage.pipe.sky_mat.shader
	var live: float = await measure("live", production, false)
	await measure("cached", production, true)
	for v in VARIANTS:
		var ms: float = await measure(v[0], variant(v[1]), false)
		print("SKYCOST   saves %7.3f ms" % (live - ms))
	var flat := Shader.new()
	flat.code = "shader_type sky;\nvoid sky() { COLOR = vec3(0.0); }\n"
	var floor_ms: float = await measure("constant sky", flat, false)
	print("SKYCOST   live sky total %7.3f ms" % (live - floor_ms))
	var repeat: float = await measure("live (repeat)", production, false)
	print("SKYCOST   repeat drift %+.3f ms" % (repeat - live))
	stage.pipe.sky_mat.shader = production
	print("SKYCOST DONE variants=%d failures=%d" % [VARIANTS.size() + 4, failures])
	get_tree().quit(1 if failures else 0)
