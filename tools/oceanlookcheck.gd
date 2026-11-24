extends Node

# OCEAN LOOK CHECK: the FFT sea on the GPU against its CPU half (docs/physics/ocean.md#on-the-gpu). Windowed,
# because it reads the RenderingDevice's result: the long cascades OceanGPU drew must be OceanField.snapshot's,
# texel for texel, at the same time on the site's clock, so a floating hull reads the drawn sea. The water
# shader is drawn once, so a SHADER ERROR fails the run.
#   Godot --path . --resolution 640x360 res://tools/oceanlookcheck.tscn

var checks := 0
var failures := 0

func check(what: String, ok: bool) -> void:
	checks += 1
	if ok: print("OCEANLOOKCHECK ok   ", what)
	else:
		failures += 1
		printerr("OCEANLOOKCHECK FAIL ", what)

func _ready() -> void:
	if not RDU.available():
		check("a RenderingDevice to run the sea on", false)
		_done()
		return
	for case in [["Earth, 10 m/s", 9.81, Liquid.of("Earth"), 10.0, 6.0e5, 4000.0], ["Titan, 1 m/s", 1.352, Liquid.of("Titan"), 1.0, 1.0e5, 160.0]]:
		await _parity(case)
	await _draw_once()
	_done()

func _done() -> void:
	print("OCEANLOOKCHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures > 0 else 0)

func _parity(case: Array) -> void:
	var f := OceanField.new(case[1], case[5], case[2], case[3], 0.4, case[4], 21)
	var gpu := OceanGPU.new(f)
	await get_tree().process_frame
	var t := 0.0
	for i in 600:
		t += 0.1
		gpu.run(t, 0.1)
	RenderingServer.force_draw(false)
	f.snapshot(t)
	var worst := 0.0
	var scale := maxf(f.hs(OceanField.PHYSICS), 1e-6)
	for c in OceanField.PHYSICS:
		var got := gpu.read_back(c)
		var nn := f.n[c]
		if got.size() != nn * nn * 4:
			check("%s: cascade %d read back (%d floats)" % [case[0], c, got.size()], false)
			gpu.dispose()
			return
		for i in nn * nn:
			worst = maxf(worst, absf(got[i * 4] - f.dx[c][i]))
			worst = maxf(worst, absf(got[i * 4 + 1] - f.hy[c][i]))
			worst = maxf(worst, absf(got[i * 4 + 2] - f.dz[c][i]))
	# Float32 against double: ω·t at a minute of phase and 64-point sums, a few parts in a million of Hs.
	check("%s: the GPU's long cascades are the CPU's at t = %s s (worst %s m, %s of Hs %s m)" % [case[0], U.fixed(t, 1),
		U.expo(worst, 2), U.expo(worst / scale, 1), U.fixed(scale, 2)], worst < 1e-4 * scale + 1e-6)
	gpu.dispose()
	await get_tree().process_frame

func _draw_once() -> void:
	var f := OceanField.new(9.81, 4000.0, Liquid.of("Earth"), 8.0, 0.0, 6.0e5, 3)
	var gpu := OceanGPU.new(f)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/surface/water.gdshader")
	for c in OceanField.CASCADES:
		mat.set_shader_parameter("uDisp%d" % c, gpu.disp[c])
		mat.set_shader_parameter("uDeriv%d" % c, gpu.deriv[c])
	var cam := Camera3D.new()
	cam.position = Vector3(0, 6, 0)
	cam.rotation = Vector3(-0.3, 0, 0)
	add_child(cam)
	cam.current = true
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.4, 0.55, 0.8)
	add_child(env)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	pm.subdivide_width = 100
	pm.subdivide_depth = 100
	mi.mesh = pm
	mi.material_override = mat
	add_child(mi)
	for i in 6:
		gpu.run(i * 0.1, 0.1)
		await get_tree().process_frame
	RenderingServer.force_draw(false)
	var img := get_viewport().get_texture().get_image()
	var lit := 0
	for y in range(img.get_height() / 2, img.get_height(), 16):
		for x in range(0, img.get_width(), 16):
			if img.get_pixel(x, y).get_luminance() > 0.02: lit += 1
	check("the water shader draws (%d lit samples below the horizon)" % lit, lit > 10)
	gpu.dispose()
